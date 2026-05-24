local addonName, addon = ...
sfui = sfui or {}
sfui.castbar = {}
local cfg = sfui.config
local common = sfui.common

local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local UnitName = UnitName
local UnitSpellHaste = UnitSpellHaste
local UnitCastingDuration = UnitCastingDuration
local UnitChannelDuration = UnitChannelDuration
local GetTime = GetTime
local C_Spell = C_Spell
local C_Timer = C_Timer
local Enum = Enum
local LibStub = LibStub
local UIParent = UIParent
local CreateFrame = CreateFrame
local C_CurveUtil = C_CurveUtil
local IsPlayerSpell = IsPlayerSpell

-- ========================
-- helpers for basic checks
-- ========================
local DEFAULT_INTERRUPTED_COLOR = { 1, 0, 0 }
local DEFAULT_EMPOWERED_COLOR = { 0.4, 0, 1 }
local DEFAULT_CHANNEL_COLOR = { 0, 1, 0 }
local DEFAULT_NORMAL_COLOR = { 1, 1, 1 }
local DEFAULT_SHIELDED_COLOR = { 0.2, 0.2, 0.2 }

-- ========================
-- helpers for instant cast
-- ========================
local lastKnownHaste = 0

local function apply_haste_to_gcd(base)
    local hasteprocent = UnitSpellHaste("player") or 0
    if issecretvalue and issecretvalue(hasteprocent) then
        hasteprocent = lastKnownHaste
    else
        lastKnownHaste = hasteprocent
    end
    local haste = hasteprocent / 100
    local gcd = base / (1 + haste)
    if base >= 1.5 then
        if gcd < 0.75 then gcd = 0.75 end
    else
        if gcd < 1.0 then gcd = 1.0 end
    end
    return gcd
end

local function is_instant_spell(spellID)
    if not spellID then return false, nil end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    if not info then return false, nil end

    if info.castTime and info.castTime == 0 then
        -- Filter out hidden aura triggers (like Frailty) and passives
        if IsPlayerSpell(spellID) then
            if C_Spell and C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(spellID) then
                return false, nil
            end
            return true, info.name
        end
    end
    return false, nil
end

local function CreateCastBar(configName, unit)
    local bar = common.create_bar(configName, "StatusBar", UIParent)
    bar.unit, bar.configName = unit, configName

    bar.backdrop:SetScript("OnShow", function(self) self:SetAlpha(1) end)

    bar.Text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.Text:SetPoint("CENTER", 0, 0)

    bar.TimerText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.TimerText:SetPoint("RIGHT", -5, 0)

    bar.Spark = bar:CreateTexture(nil, "OVERLAY")
    bar.Spark:SetTexture("Interface/CastingBar/UI-CastingBar-Spark")
    bar.Spark:SetBlendMode("ADD")

    local cfg = sfui.config[configName]
    local sparkCfg = cfg and cfg.spark or { width = 20, heightMultiplier = 2.5 }
    bar.Spark:SetSize(sparkCfg.width, bar:GetHeight() * sparkCfg.heightMultiplier)

    local cfg = sfui.config[configName]
    bar.IconFrame = CreateFrame("Frame", nil, bar.backdrop, "BackdropTemplate")
    local iconSize = cfg and cfg.iconSize or (bar:GetHeight() + 4)
    bar.IconFrame:SetSize(iconSize, iconSize)
    local iconCfg = cfg and cfg.icon or { offset = -5 }
    bar.IconFrame:SetPoint("RIGHT", bar.backdrop, "LEFT", iconCfg.offset, 0)

    bar.Icon = bar.IconFrame:CreateTexture(nil, "ARTWORK")
    bar.Icon:SetAllPoints()

    common.apply_square_icon_style(bar.IconFrame, bar.Icon)

    -- Setup Texture (Inherit from Options Panel)
    local textureName = SfuiDB.barTexture
    local LSM = LibStub("LibSharedMedia-3.0", true)
    local texturePath
    if LSM then
        texturePath = LSM:Fetch("statusbar", textureName)
    end
    if not texturePath or texturePath == "" then
        texturePath = cfg.barTexture -- Defaults to Flat (WHITE8X8)
    end
    bar:SetStatusBarTexture(texturePath)

    bar.backdrop:ClearAllPoints()
    bar.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", cfg.pos.x, cfg.pos.y)
    bar.backdrop:Hide()
    return bar
end

local function UpdateCastBarColor(bar, state)
    -- determine base color
    local color

    if state == "INTERRUPTED" then
        local cfg = sfui.config[bar.configName]
        color = cfg.interruptedColor or DEFAULT_INTERRUPTED_COLOR
    elseif state == "EMPOWER" then
        -- empower uses its own color system
        local cfg = sfui.config[bar.configName]
        color = cfg.empoweredColor or DEFAULT_EMPOWERED_COLOR
    else
        -- INSTANT, CAST, CHANNEL
        -- Logic: If player, try spec color. Else fallback to config color.
        -- For INSTANT/CHANNEL, if fallback needed, use channelColor.

        local specColor = nil
        if bar.unit == "player" then
            specColor = common.get_class_or_spec_color()
        end

        if specColor then
            color = specColor
        else
            -- Fallback
            local cfg = sfui.config[bar.configName]
            color = cfg.color

            if state == "CHANNEL" or state == "INSTANT" then
                color = cfg.channelColor or DEFAULT_CHANNEL_COLOR
            end
        end
    end

    bar:SetStatusBarColor(color[1], color[2], color[3])
end

local function ResetBar(self)
    self.casting = nil
    self.channeling = nil
    self.empowering = nil
    self.instant = nil -- Reset instant state
    self.backdrop:Hide()
end

local function CreateStageDividers(bar, numStages)
    if not bar.stageDividers then bar.stageDividers = {} end

    -- Hide all existing
    for _, div in ipairs(bar.stageDividers) do div:Hide() end

    if numStages and numStages > 0 then
        local width = bar:GetWidth()
        local step = width / numStages

        for i = 1, numStages - 1 do
            local div = bar.stageDividers[i]
            if not div then
                div = bar:CreateTexture(nil, "OVERLAY")
                div:SetColorTexture(0, 0, 0, 0.8)
                div:SetSize(1, bar:GetHeight())
                bar.stageDividers[i] = div
            end

            div:ClearAllPoints()
            div:SetPoint("LEFT", bar, "LEFT", step * i, 0)
            div:Show()
        end
    end
end

local function OnUpdate(self, elapsed)
    if not self.casting and not self.channeling and not self.empowering and not self.instant then
        if self.backdrop:IsShown() then
            self.value = 0
            self.backdrop:Hide()
            self.backdrop:SetAlpha(1)
        end
        return
    end

    -- Throttle text updates to ~20fps (configurable)
    self.throttle = (self.throttle or 0) + elapsed
    local updateText = false
    local cfg = sfui.config[self.configName]
    local throttleValue = cfg and cfg.updateThrottle or 0.05
    if self.throttle > throttleValue then
        updateText = true
        self.throttle = 0
    end

    if self.casting then
        self.value = self.value + elapsed
        if self.value >= self.maxValue then
            ResetBar(self)
            return
        end
        self:SetValue(self.value)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", self.maxValue - self.value)
        end

        -- Spark Logic
        local sparkPosition = (self.value / self.maxValue) * self:GetWidth()
        self.Spark:SetPoint("CENTER", self, "LEFT", sparkPosition, 0)
    elseif self.channeling then
        self.value = self.value - elapsed
        if self.value <= 0 then
            ResetBar(self)
            return
        end
        self:SetValue(self.value)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", self.value)
        end

        -- Spark Logic
        local sparkPosition = (self.value / self.maxValue) * self:GetWidth()
        self.Spark:SetPoint("CENTER", self, "LEFT", sparkPosition, 0)
    elseif self.empowering then
        self.value = self.value + elapsed
        if self.value >= self.maxValue then
            ResetBar(self)
            return
        end
        self:SetValue(self.value)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", self.maxValue - self.value)
        end

        if self.numStages and self.numStages > 0 then
            local progress = self.value / self.maxValue
            local currentStage = math.min(math.floor(progress * self.numStages) + 1, self.numStages)

            if currentStage ~= self.empowerStage then
                self.empowerStage = currentStage
                local stageColors = cfg.empoweredStageColors
                local c = stageColors and stageColors[currentStage]
                if c then self:SetStatusBarColor(c[1], c[2], c[3]) end
            end
        end
        local sparkPosition = (self.value / self.maxValue) * self:GetWidth()
        self.Spark:SetPoint("CENTER", self, "LEFT", sparkPosition, 0)
    elseif self.instant then
        -- Handle Instant Cast Bar Logic
        local t = GetTime() - self.instant_t0
        if t >= self.instant_dur then
            ResetBar(self)
            return
        end

        local remaining = self.instant_dur - t
        if remaining < 0 then remaining = 0 end

        self:SetValue(remaining)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", remaining)
        end

        local sparkPosition = (remaining / self.instant_dur) * self:GetWidth()
        self.Spark:SetPoint("CENTER", self, "LEFT", sparkPosition, 0)
    end
end


local function OnEvent(self, event, ...)
    local cfg = sfui.config[self.configName]
    if not cfg or not cfg.enabled then
        self.backdrop:Hide()
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit ~= self.unit then return end

        -- Don't override if casting/channeling
        if self.casting or self.channeling or self.empowering then return end

        local isInstant, name = is_instant_spell(spellID)
        if isInstant then
            -- 12.0.5: UnitSpellHaste is SecretWhenUnitStatsRestricted.
            -- When stats are secret (M+ combat), we use the cached out-of-combat
            -- haste value to safely display the instant cast bar.

            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
            local texture = info and info.iconID

            -- Precise API GCD Logic
            local onGCD, gcdDuration = common.GetGCDInfo()
            local duration = (onGCD and gcdDuration > 0) and gcdDuration or apply_haste_to_gcd(1.5)

            self.instant = true
            self.casting = nil
            self.channeling = nil
            self.empowering = nil

            self.instant_t0 = GetTime()
            self.instant_dur = duration

            self.backdrop:Show()
            self.backdrop:SetAlpha(1)
            self:SetMinMaxValues(0, duration)
            self:SetValue(duration)

            self.Text:SetText(name or "GCD")
            if texture then
                self.Icon:SetTexture(texture)
            end

            UpdateCastBarColor(self, "INSTANT")
            self.Spark:Show()
            CreateStageDividers(self, 0)
        end
        return
    end

    -- UNIT arg handling for other events
    local unit = ...
    if unit ~= self.unit then return end

    if event == "UNIT_SPELLCAST_START" then
        local name, text, texture, startTime, endTime, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo(
            unit)
        if not name or not startTime or not endTime or not castID then return end

        self.backdrop:Show()
        self.backdrop:SetAlpha(1)
        self.value = (GetTime() - (startTime / 1000))
        self.maxValue = (endTime - startTime) / 1000
        self:SetMinMaxValues(0, self.maxValue)
        self:SetValue(self.value)

        self.Text:SetText(text)
        self.Icon:SetTexture(texture)

        self.casting = true
        self.channeling = nil
        self.empowering = nil
        self.instant = nil -- Clear instant state
        self.castID = castID

        UpdateCastBarColor(self, "CAST")
        self.Spark:Show()
        CreateStageDividers(self, 0)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_EMPOWER_START" then
        local name, text, texture, startTime, endTime, isTradeSkill, notInterruptible, spellID, _, numStages =
            UnitChannelInfo(unit)
        if not name or not startTime or not endTime or not spellID then return end

        self.backdrop:Show()
        self.backdrop:SetAlpha(1)
        self.Icon:SetTexture(texture)
        self.Text:SetText(name)

        local isEmpowered = numStages and numStages > 0
        if isEmpowered then
            local holdTime = GetUnitEmpowerHoldAtMaxTime and GetUnitEmpowerHoldAtMaxTime(unit) or 0
            endTime = endTime + holdTime
            self.value = (GetTime() - (startTime / 1000))
            self.maxValue = (endTime - startTime) / 1000
            self.casting, self.channeling, self.empowering = nil, nil, true
            self.instant = nil
            self.numStages, self.empowerStage = numStages, 0

            local stageColors = cfg.empoweredStageColors
            local c = stageColors and stageColors[1]
            if c then self:SetStatusBarColor(c[1], c[2], c[3]) else UpdateCastBarColor(self, "EMPOWER") end
            CreateStageDividers(self, numStages)
        else
            self.value = ((endTime / 1000) - GetTime())
            self.maxValue = (endTime - startTime) / 1000
            self.casting, self.channeling, self.empowering = nil, true, nil
            self.instant = nil
            UpdateCastBarColor(self, "CHANNEL"); CreateStageDividers(self, 0)
        end

        self:SetMinMaxValues(0, self.maxValue)
        self:SetValue(self.value)
        self.Spark:Show()
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        if self.casting and event == "UNIT_SPELLCAST_STOP" then
            local castGUID = select(2, ...)
            if castGUID ~= self.castID then return end
            self.casting = nil
        end

        if event == "UNIT_SPELLCAST_EMPOWER_STOP" then
            self.empowering = nil
        end

        if event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            self.channeling = nil
        end

        if not self.casting and not self.channeling and not self.empowering then
            ResetBar(self)
        end

        if not UnitCastingInfo(unit) and not UnitChannelInfo(unit) then
            if not self.instant then
                ResetBar(self)
            end
        end
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        local castGUID = select(2, ...)

        -- Only process if it matches our current cast
        if self.casting and castGUID == self.castID then
            UpdateCastBarColor(self, "INTERRUPTED")
            self.Text:SetText(FAILED)
            if event == "UNIT_SPELLCAST_INTERRUPTED" then
                self.Text:SetText(INTERRUPTED)
            end

            if not self.resetTimerObj then
                self.resetTimerObj = function()
                    if not self.casting and not self.channeling and not self.empowering and not self.instant then
                        ResetBar(self)
                    end
                end
            end

            self.casting = nil
            self.channeling = nil
            self.empowering = nil
            self.instant = nil

            C_Timer.After(0.5, self.resetTimerObj)
        elseif (self.channeling or self.empowering) and (event == "UNIT_SPELLCAST_INTERRUPTED") then
            if not UnitChannelInfo(unit) then
                UpdateCastBarColor(self, "INTERRUPTED")
                self.Text:SetText(INTERRUPTED)

                if not self.resetTimerObj then
                    self.resetTimerObj = function()
                        if not self.casting and not self.channeling and not self.empowering and not self.instant then
                            ResetBar(self)
                        end
                    end
                end

                self.casting = nil
                self.channeling = nil
                self.empowering = nil
                self.instant = nil

                C_Timer.After(0.5, self.resetTimerObj)
            end
        end
    elseif event == "UNIT_SPELLCAST_DELAYED" then
        local name, _, _, startTime, endTime, _, castID = UnitCastingInfo(unit)
        if not name or not startTime or not endTime or not castID then return end
        self.value = (GetTime() - (startTime / 1000))
        self.maxValue = (endTime - startTime) / 1000
        self:SetMinMaxValues(0, self.maxValue)
    end
end



local function SetupBar(configName, unit)
    local bar = CreateCastBar(configName, unit)
    sfui.castbar.bars = sfui.castbar.bars or {}
    sfui.castbar.bars[unit] = bar
    bar:SetScript("OnUpdate", OnUpdate)

    bar:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_STOP", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", unit)

    bar:SetScript("OnEvent", OnEvent)
    return bar
end

-- ========================
-- Target CastBar Logic
-- ========================

local function UpdateTargetCastBarColor(bar, notInterruptible)
    local cfg = sfui.config[bar.configName]
    local color

    -- Direct boolean check
    local normal = cfg.color or DEFAULT_NORMAL_COLOR
    local shielded = cfg.nonInterruptibleColor or DEFAULT_SHIELDED_COLOR

    if notInterruptible ~= nil then
        local r = C_CurveUtil.EvaluateColorValueFromBoolean(notInterruptible, shielded[1], normal[1])
        local g = C_CurveUtil.EvaluateColorValueFromBoolean(notInterruptible, shielded[2], normal[2])
        local b = C_CurveUtil.EvaluateColorValueFromBoolean(notInterruptible, shielded[3], normal[3])
        bar:GetStatusBarTexture():SetVertexColor(r, g, b)
    else
        bar:SetStatusBarColor(normal[1], normal[2], normal[3])
    end
end

local function Target_StartCast(self, unit)
    local name, text, texture, startTime, endTime, isTradeSkill, castID, notInterruptible = UnitCastingInfo(unit)

    if not name then
        self.backdrop:Hide()
        return
    end

    self.casting = true
    self.channeling = nil
    self.castID = castID

    -- Use duration object API (works with secret values)
    local duration = UnitCastingDuration(unit)

    if duration then
        local StatusBarTimerDirection = Enum.StatusBarTimerDirection
        local StatusBarInterpolation = Enum.StatusBarInterpolation
        self:SetTimerDuration(duration, StatusBarInterpolation.Linear, StatusBarTimerDirection.ElapsedTime)
    end

    self.Icon:SetTexture(texture)
    UpdateTargetCastBarColor(self, notInterruptible)

    local targetName = UnitName("targettarget")
    if targetName then
        self.Text:SetText(text .. " > " .. targetName)
    else
        self.Text:SetText(text)
    end

    self.backdrop:Show()
end

local function Target_StartChannel(self, unit)
    local name, text, texture, startTime, endTime, isTradeSkill, notInterruptible = UnitChannelInfo(unit)

    if not name then
        return
    end

    self.casting = nil
    self.channeling = true

    -- Use duration object API (works with secret values)
    local duration = UnitChannelDuration(unit)
    if duration then
        local StatusBarTimerDirection = Enum.StatusBarTimerDirection
        local StatusBarInterpolation = Enum.StatusBarInterpolation
        self:SetTimerDuration(duration, StatusBarInterpolation.Linear, StatusBarTimerDirection.RemainingTime)
    end

    self.Icon:SetTexture(texture)
    UpdateTargetCastBarColor(self, notInterruptible)

    local targetName = UnitName("targettarget")
    if targetName then
        self.Text:SetText(name .. " > " .. targetName)
    else
        self.Text:SetText(name)
    end

    self.backdrop:Show()
end

local function Target_OnEvent(self, event, ...)
    local cfg = sfui.config[self.configName]
    if not cfg or not cfg.enabled then
        self.backdrop:Hide()
        return
    end

    local unit = ...
    if unit and unit ~= self.unit and event ~= "PLAYER_TARGET_CHANGED" then return end

    if event == "PLAYER_TARGET_CHANGED" then
        if UnitCastingInfo("target") then
            Target_StartCast(self, "target")
        elseif UnitChannelInfo("target") then
            Target_StartChannel(self, "target")
        else
            self.casting = nil
            self.channeling = nil
            self.backdrop:Hide()
        end
    elseif event == "UNIT_SPELLCAST_START" then
        Target_StartCast(self, unit)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        Target_StartChannel(self, unit)
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if event == "UNIT_SPELLCAST_STOP" then self.casting = nil end
        if event == "UNIT_SPELLCAST_CHANNEL_STOP" then self.channeling = nil end

        if not self.casting and not self.channeling then
            self.backdrop:Hide()
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        local _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo(unit)
        if notInterruptible == nil then
            local _, _, _, _, _, _, notInterruptibleChannel = UnitChannelInfo(unit)
            if notInterruptibleChannel ~= nil then
                notInterruptible = notInterruptibleChannel
            end
        end
        UpdateTargetCastBarColor(self, notInterruptible)
    end
end



local function SetupTargetBar(configName, unit)
    local cfg = sfui.config[configName]
    -- if not cfg or not cfg.enabled then return end -- Removed to allow runtime toggling

    local bar = CreateCastBar(configName, unit)
    sfui.castbar.bars = sfui.castbar.bars or {}
    sfui.castbar.bars[unit] = bar
    -- Target specific setup
    bar:RegisterEvent("PLAYER_TARGET_CHANGED")
    bar:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_STOP", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTIBLE", unit)
    bar:RegisterUnitEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", unit)

    bar:SetScript("OnEvent", Target_OnEvent)
    bar:SetScript("OnUpdate", nil)
    if bar.Spark then bar.Spark:Hide() end

    return bar
end

function sfui.castbar.update_settings()
    -- Sync config from DB
    if SfuiDB.castBarEnabled ~= nil then cfg.castBar.enabled = SfuiDB.castBarEnabled end
    if SfuiDB.castBarX ~= nil then cfg.castBar.pos.x = SfuiDB.castBarX end
    if SfuiDB.castBarY ~= nil then cfg.castBar.pos.y = SfuiDB.castBarY end

    if SfuiDB.targetCastBarEnabled ~= nil then cfg.targetCastBar.enabled = SfuiDB.targetCastBarEnabled end
    if SfuiDB.targetCastBarX ~= nil then cfg.targetCastBar.pos.x = SfuiDB.targetCastBarX end
    if SfuiDB.targetCastBarY ~= nil then cfg.targetCastBar.pos.y = SfuiDB.targetCastBarY end

    -- Apply to active bars
    if sfui.castbar.bars then
        local playerBar = sfui.castbar.bars["player"]
        if playerBar then
            local cfg = sfui.config.castBar
            if not cfg.enabled then
                playerBar.backdrop:Hide()
                ResetBar(playerBar)
            else
                playerBar.backdrop:ClearAllPoints()
                playerBar.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", cfg.pos.x, cfg.pos.y)
            end
        end

        local targetBar = sfui.castbar.bars["target"]
        if targetBar then
            local cfg = sfui.config.targetCastBar
            if not cfg.enabled then
                targetBar.backdrop:Hide()
                targetBar.casting = nil
                targetBar.channeling = nil
            else
                targetBar.backdrop:ClearAllPoints()
                targetBar.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", cfg.pos.x, cfg.pos.y)
            end
        end
    end
end

function sfui.castbar.set_bar_texture(texturePath)
    if sfui.castbar.bars then
        for _, bar in pairs(sfui.castbar.bars) do
            bar:SetStatusBarTexture(texturePath)
        end
    end
end

sfui.events.RegisterEvent("PLAYER_LOGIN", function()
    SetupBar("castBar", "player")
    SetupTargetBar("targetCastBar", "target")

    if _G.PlayerCastingBarFrame then
        _G.PlayerCastingBarFrame:SetAlpha(0)
        _G.PlayerCastingBarFrame:UnregisterAllEvents()
        _G.PlayerCastingBarFrame:Hide()
    end

    if _G.OverlayPlayerCastingBarFrame then
        _G.OverlayPlayerCastingBarFrame:SetAlpha(0)
        _G.OverlayPlayerCastingBarFrame:UnregisterAllEvents()
        _G.OverlayPlayerCastingBarFrame:Hide()
    end
end)
