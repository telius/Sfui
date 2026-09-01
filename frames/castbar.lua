local addonName, addon = ...
sfui = sfui or {}
sfui.castbar = sfui.castbar or {}

local common = sfui.common
local g      = sfui.config

-- ─── Upvalue Localizations ──────────────────────────────────────────────────
local _G = _G
local CreateFrame                 = _G.CreateFrame
local UIParent                    = _G.UIParent
local C_Timer                     = _G.C_Timer
local GetTime                     = _G.GetTime
local UnitCastingInfo             = _G.UnitCastingInfo
local UnitChannelInfo             = _G.UnitChannelInfo
local UnitName                    = _G.UnitName
local UnitSpellHaste              = _G.UnitSpellHaste
local UnitCastingDuration         = _G.UnitCastingDuration
local UnitChannelDuration         = _G.UnitChannelDuration
local IsPlayerSpell               = _G.IsPlayerSpell
local GetUnitEmpowerHoldAtMaxTime = _G.GetUnitEmpowerHoldAtMaxTime
local C_Spell                     = _G.C_Spell
local C_CurveUtil                 = _G.C_CurveUtil
local Enum                        = _G.Enum
local FAILED                      = _G.FAILED
local INTERRUPTED                 = _G.INTERRUPTED
local wipe                        = _G.wipe
local pairs                       = _G.pairs
local math_min                    = math.min
local math_max                    = math.max
local math_floor                  = math.floor
local issecretvalue               = common.issecretvalue or _G.issecretvalue
local unpack_color                = common.unpack_color
local EvaluateColorValueFromBoolean = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean

-- ─── Color & Styling Defaults ───────────────────────────────────────────────
local DEFAULT_INTERRUPTED_COLOR = { 1, 0, 0 }
local DEFAULT_EMPOWERED_COLOR   = { 0.4, 0, 1 }
local DEFAULT_CHANNEL_COLOR     = { 0, 1, 0 }
local DEFAULT_NORMAL_COLOR      = { 1, 1, 1 }
local DEFAULT_SHIELDED_COLOR    = { 0.2, 0.2, 0.2 }
local DEFAULT_STAGE_COLORS = {
    { 0, 1,   0 }, -- stage 1: green
    { 1, 1,   0 }, -- stage 2: yellow
    { 1, 0.5, 0 }, -- stage 3: orange
    { 1, 0,   0 }, -- stage 4: red
}

-- ─── Instant Cast & GCD Helpers ─────────────────────────────────────────────
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

local instant_cache_valid = {}
local instant_cache_name  = {}

local function clear_spell_cache()
    wipe(instant_cache_valid)
    wipe(instant_cache_name)
end

local function is_instant_spell(spellID)
    if not spellID then return false, nil end
    local cached = instant_cache_valid[spellID]
    if cached ~= nil then
        return cached, instant_cache_name[spellID]
    end

    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    if info and info.castTime and info.castTime == 0 then
        -- Filter out hidden aura triggers (like Frailty) and passives
        if IsPlayerSpell(spellID) then
            if not (C_Spell and C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(spellID)) then
                instant_cache_valid[spellID] = true
                instant_cache_name[spellID]  = info.name
                return true, info.name
            end
        end
    end

    instant_cache_valid[spellID] = false
    return false, nil
end

-- ─── Bar Construction ───────────────────────────────────────────────────────
local function on_backdrop_show(self)
    self:SetAlpha(1)
end

local function CreateCastBar(configName, unit)
    -- common.create_bar handles frame creation, statusbar, LSM texture, backdrop & pixel scaling
    local bar = common.create_bar(configName, "StatusBar", UIParent)
    bar.unit       = unit
    bar.configName = configName
    bar.cfg        = g[configName] or {}

    bar.backdrop:SetScript("OnShow", on_backdrop_show)

    local fontObject = g.font_highlight or "GameFontHighlight"
    bar.Text = bar:CreateFontString(nil, "OVERLAY", fontObject)
    bar.Text:SetPoint("CENTER", 0, 0)

    bar.TimerText = bar:CreateFontString(nil, "OVERLAY", fontObject)
    bar.TimerText:SetPoint("RIGHT", -5, 0)

    bar.Spark = bar:CreateTexture(nil, "OVERLAY")
    bar.Spark:SetTexture("Interface/CastingBar/UI-CastingBar-Spark")
    bar.Spark:SetBlendMode("ADD")

    local sparkCfg = bar.cfg.spark or { width = 20, heightMultiplier = 2.5 }
    bar.Spark:SetSize(sparkCfg.width or 20, bar:GetHeight() * (sparkCfg.heightMultiplier or 2.5))

    bar.IconFrame = CreateFrame("Frame", nil, bar.backdrop, "BackdropTemplate")
    local iconSize = bar.cfg.iconSize or (bar:GetHeight() + 4)
    bar.IconFrame:SetSize(iconSize, iconSize)
    local iconCfg = bar.cfg.icon or { offset = -5 }
    bar.IconFrame:SetPoint("RIGHT", bar.backdrop, "LEFT", iconCfg.offset or -5, 0)

    bar.Icon = bar.IconFrame:CreateTexture(nil, "ARTWORK")
    bar.Icon:SetAllPoints()

    common.apply_square_icon_style(bar.IconFrame, bar.Icon)

    local posX = (bar.cfg.pos and bar.cfg.pos.x) or 0
    local posY = (bar.cfg.pos and bar.cfg.pos.y) or 0
    bar.backdrop:ClearAllPoints()
    bar.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", posX, posY)
    bar.backdrop:Hide()

    return bar
end

-- ─── Color Management ───────────────────────────────────────────────────────
local function UpdateCastBarColor(bar, state)
    local color
    local barCfg = bar.cfg or g[bar.configName] or {}

    if state == "INTERRUPTED" then
        color = barCfg.interruptedColor or DEFAULT_INTERRUPTED_COLOR
    elseif state == "EMPOWER" then
        color = barCfg.empoweredColor or DEFAULT_EMPOWERED_COLOR
    else
        local specColor = nil
        if bar.unit == "player" then
            specColor = common.get_class_or_spec_color()
        end

        if specColor then
            color = specColor
        else
            color = barCfg.color or DEFAULT_NORMAL_COLOR
            if state == "CHANNEL" or state == "INSTANT" then
                color = barCfg.channelColor or DEFAULT_CHANNEL_COLOR
            end
        end
    end

    local r, g, b = unpack_color(color)
    bar:SetStatusBarColor(r, g, b)
end

local function UpdateTargetCastBarColor(bar, notInterruptible)
    if not bar then return end
    local barCfg = bar.cfg or g[bar.configName] or {}
    local normal = barCfg.color or DEFAULT_NORMAL_COLOR
    local shielded = barCfg.nonInterruptibleColor or DEFAULT_SHIELDED_COLOR

    local normalR, normalG, normalB = unpack_color(normal, 1, 1, 1)
    local shieldedR, shieldedG, shieldedB = unpack_color(shielded, 0.2, 0.2, 0.2)

    if notInterruptible ~= nil and EvaluateColorValueFromBoolean then
        local r = EvaluateColorValueFromBoolean(notInterruptible, shieldedR, normalR)
        local g = EvaluateColorValueFromBoolean(notInterruptible, shieldedG, normalG)
        local b = EvaluateColorValueFromBoolean(notInterruptible, shieldedB, normalB)
        bar:SetStatusBarColor(r, g, b)

        if bar.backdrop then
            local borderCol = EvaluateColorValueFromBoolean(notInterruptible, 0.25, 0.0)
            bar.backdrop:SetBackdropBorderColor(borderCol, borderCol, borderCol, 1)
        end
    else
        bar:SetStatusBarColor(normalR, normalG, normalB)
        if bar.backdrop then
            bar.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
        end
    end

    bar.notInterruptible = notInterruptible
end

local function ResetBar(self)
    self.casting          = nil
    self.channeling       = nil
    self.empowering       = nil
    self.instant          = nil
    self.notInterruptible = nil
    self.castID           = nil
    self.empowerStage     = nil
    if self.backdrop then
        self.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
        self.backdrop:Hide()
    end
    self:SetScript("OnUpdate", nil)
end

local function CreateStageDividers(bar, numStages)
    local dividers = bar.stageDividers
    if not dividers then
        dividers = {}
        bar.stageDividers = dividers
    end

    for i = 1, #dividers do
        dividers[i]:Hide()
    end

    if numStages and numStages > 0 then
        local width = bar:GetWidth()
        local step = width / numStages
        local barHeight = bar:GetHeight()

        for i = 1, numStages - 1 do
            local div = dividers[i]
            if not div then
                div = bar:CreateTexture(nil, "OVERLAY")
                div:SetColorTexture(0, 0, 0, 0.8)
                div:SetSize(1, barHeight)
                dividers[i] = div
            end

            div:ClearAllPoints()
            div:SetPoint("LEFT", bar, "LEFT", step * i, 0)
            div:Show()
        end
    end
end

-- ─── Player CastBar Update Loop ─────────────────────────────────────────────
local function Player_OnUpdate(self, elapsed)
    if not self.casting and not self.channeling and not self.empowering and not self.instant then
        if self.backdrop:IsShown() then
            self.value = 0
            self.backdrop:Hide()
            self.backdrop:SetAlpha(1)
        end
        self:SetScript("OnUpdate", nil)
        return
    end

    self.throttle = (self.throttle or 0) + elapsed
    local updateText = false
    local barCfg = self.cfg or g[self.configName] or {}
    local throttleValue = barCfg.updateThrottle or 0.05
    if self.throttle > throttleValue then
        updateText = true
        self.throttle = 0
    end

    local barWidth = self:GetWidth()

    if self.casting then
        local val = self.value + elapsed
        self.value = val
        local maxVal = self.maxValue or 1
        if val >= maxVal then
            ResetBar(self)
            return
        end
        self:SetValue(val)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", maxVal - val)
        end
        if maxVal > 0 then
            self.Spark:SetPoint("CENTER", self, "LEFT", (val / maxVal) * barWidth, 0)
        end
    elseif self.channeling then
        local val = self.value - elapsed
        self.value = val
        if val <= 0 then
            ResetBar(self)
            return
        end
        self:SetValue(val)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", val)
        end
        local maxVal = self.maxValue or 1
        if maxVal > 0 then
            self.Spark:SetPoint("CENTER", self, "LEFT", (val / maxVal) * barWidth, 0)
        end
    elseif self.empowering then
        local val = self.value + elapsed
        self.value = val
        local maxVal = self.maxValue or 1
        if val >= maxVal then
            ResetBar(self)
            return
        end
        self:SetValue(val)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", maxVal - val)
        end

        if self.numStages and self.numStages > 0 and maxVal > 0 then
            local progress = val / maxVal
            local currentStage = math_min(math_floor(progress * self.numStages) + 1, self.numStages)

            if currentStage ~= self.empowerStage then
                self.empowerStage = currentStage
                local stageColors = barCfg.empoweredStageColors or DEFAULT_STAGE_COLORS
                local c = stageColors[currentStage]
                if c then
                    local r, g, b = unpack_color(c)
                    self:SetStatusBarColor(r, g, b)
                end
            end
        end
        if maxVal > 0 then
            self.Spark:SetPoint("CENTER", self, "LEFT", (val / maxVal) * barWidth, 0)
        end
    elseif self.instant then
        local t = GetTime() - self.instant_t0
        local dur = self.instant_dur or 1
        if t >= dur then
            ResetBar(self)
            return
        end

        local remaining = dur - t
        if remaining < 0 then remaining = 0 end

        self:SetValue(remaining)
        if updateText then
            self.TimerText:SetFormattedText("%.1f", remaining)
        end

        if dur > 0 then
            self.Spark:SetPoint("CENTER", self, "LEFT", (remaining / dur) * barWidth, 0)
        end
    end
end

-- ─── Player Event Handling ──────────────────────────────────────────────────
local function on_reset_timer(bar)
    if not bar.casting and not bar.channeling and not bar.empowering and not bar.instant then
        ResetBar(bar)
    end
end

local function Player_OnEvent(event, unit, ...)
    local bar = sfui.castbar.bars and sfui.castbar.bars["player"]
    if not bar then return end

    local barCfg = bar.cfg or g[bar.configName]
    if not barCfg or not barCfg.enabled then
        bar.backdrop:Hide()
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local castGUID, spellID = ...
        if unit ~= bar.unit then return end

        -- Don't override if currently casting/channeling/empowering
        if bar.casting or bar.channeling or bar.empowering then return end

        local isInstant, name = is_instant_spell(spellID)
        if isInstant then
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
            local texture = info and info.iconID

            local onGCD, gcdDuration = common.GetGCDInfo()
            local duration = (onGCD and gcdDuration > 0) and gcdDuration or apply_haste_to_gcd(1.5)

            bar.instant    = true
            bar.casting    = nil
            bar.channeling = nil
            bar.empowering = nil

            bar.instant_t0  = GetTime()
            bar.instant_dur = duration

            bar.backdrop:Show()
            bar.backdrop:SetAlpha(1)
            bar:SetMinMaxValues(0, duration)
            bar:SetValue(duration)

            bar.Text:SetText(name or "GCD")
            if texture then
                bar.Icon:SetTexture(texture)
            end

            UpdateCastBarColor(bar, "INSTANT")
            bar.Spark:Show()
            CreateStageDividers(bar, 0)
            bar:SetScript("OnUpdate", Player_OnUpdate)
        end
        return
    end

    if unit ~= bar.unit then return end

    if event == "UNIT_SPELLCAST_START" then
        local name, text, texture, startTime, endTime, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo(unit)
        if not name or not startTime or not endTime or not castID then return end

        bar.backdrop:Show()
        bar.backdrop:SetAlpha(1)
        bar.value = (GetTime() - (startTime / 1000))
        bar.maxValue = (endTime - startTime) / 1000
        bar:SetMinMaxValues(0, bar.maxValue)
        bar:SetValue(bar.value)

        bar.Text:SetText(text)
        bar.Icon:SetTexture(texture)

        bar.casting          = true
        bar.channeling       = nil
        bar.empowering       = nil
        bar.instant          = nil
        bar.castID           = castID
        bar.notInterruptible = notInterruptible

        UpdateCastBarColor(bar, "CAST")
        bar.Spark:Show()
        CreateStageDividers(bar, 0)
        bar:SetScript("OnUpdate", Player_OnUpdate)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_EMPOWER_START" then
        local name, text, texture, startTime, endTime, isTradeSkill, notInterruptible, spellID, _, numStages = UnitChannelInfo(unit)
        if not name or not startTime or not endTime or not spellID then return end

        bar.backdrop:Show()
        bar.backdrop:SetAlpha(1)
        bar.Icon:SetTexture(texture)
        bar.Text:SetText(name)
        bar.notInterruptible = notInterruptible

        local isEmpowered = numStages and numStages > 0
        if isEmpowered then
            local holdTime = GetUnitEmpowerHoldAtMaxTime and GetUnitEmpowerHoldAtMaxTime(unit) or 0
            endTime = endTime + holdTime
            bar.value = (GetTime() - (startTime / 1000))
            bar.maxValue = (endTime - startTime) / 1000
            bar.casting, bar.channeling, bar.empowering = nil, nil, true
            bar.instant = nil
            bar.numStages, bar.empowerStage = numStages, 0

            local stageColors = barCfg.empoweredStageColors or DEFAULT_STAGE_COLORS
            local c = stageColors[1]
            if c then
                local r, g, b = unpack_color(c)
                bar:SetStatusBarColor(r, g, b)
            else
                UpdateCastBarColor(bar, "EMPOWER")
            end
            CreateStageDividers(bar, numStages)
        else
            bar.value = ((endTime / 1000) - GetTime())
            bar.maxValue = (endTime - startTime) / 1000
            bar.casting, bar.channeling, bar.empowering = nil, true, nil
            bar.instant = nil
            UpdateCastBarColor(bar, "CHANNEL")
            CreateStageDividers(bar, 0)
        end

        bar:SetMinMaxValues(0, bar.maxValue)
        bar:SetValue(bar.value)
        bar.Spark:Show()
        bar:SetScript("OnUpdate", Player_OnUpdate)
    elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        local name, text, texture, startTime, endTime, isTradeSkill, notInterruptible, spellID, _, numStages = UnitChannelInfo(unit)
        if not name or not startTime or not endTime then return end
        local isEmpowered = numStages and numStages > 0
        if isEmpowered then
            local holdTime = GetUnitEmpowerHoldAtMaxTime and GetUnitEmpowerHoldAtMaxTime(unit) or 0
            endTime = endTime + holdTime
            bar.value = (GetTime() - (startTime / 1000))
            bar.maxValue = (endTime - startTime) / 1000
        else
            bar.value = ((endTime / 1000) - GetTime())
            bar.maxValue = (endTime - startTime) / 1000
        end
        bar:SetMinMaxValues(0, bar.maxValue)
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        if bar.casting and event == "UNIT_SPELLCAST_STOP" then
            local castGUID = ...
            if castGUID ~= bar.castID then return end
            bar.casting = nil
        end

        if event == "UNIT_SPELLCAST_EMPOWER_STOP" then
            bar.empowering = nil
        end

        if event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            bar.channeling = nil
        end

        if not bar.casting and not bar.channeling and not bar.empowering then
            ResetBar(bar)
        end

        if not UnitCastingInfo(unit) and not UnitChannelInfo(unit) then
            if not bar.instant then
                ResetBar(bar)
            end
        end
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        local castGUID = ...

        if bar.casting and castGUID == bar.castID then
            UpdateCastBarColor(bar, "INTERRUPTED")
            bar.Text:SetText(event == "UNIT_SPELLCAST_INTERRUPTED" and INTERRUPTED or FAILED)

            bar.casting    = nil
            bar.channeling = nil
            bar.empowering = nil
            bar.instant    = nil

            C_Timer.After(0.5, bar.resetTimerCallback)
        elseif (bar.channeling or bar.empowering) and (event == "UNIT_SPELLCAST_INTERRUPTED") then
            if not UnitChannelInfo(unit) then
                UpdateCastBarColor(bar, "INTERRUPTED")
                bar.Text:SetText(INTERRUPTED)

                bar.casting    = nil
                bar.channeling = nil
                bar.empowering = nil
                bar.instant    = nil

                C_Timer.After(0.5, bar.resetTimerCallback)
            end
        end
    elseif event == "UNIT_SPELLCAST_DELAYED" then
        local name, _, _, startTime, endTime, _, castID = UnitCastingInfo(unit)
        if not name or not startTime or not endTime or not castID then return end
        bar.value = (GetTime() - (startTime / 1000))
        bar.maxValue = (endTime - startTime) / 1000
        bar:SetMinMaxValues(0, bar.maxValue)
    end
end

-- ─── Target CastBar Logic ───────────────────────────────────────────────────
local function Target_StartCast(self, unit)
    local name, text, texture, startTime, endTime, isTradeSkill, castID, notInterruptible = UnitCastingInfo(unit)

    if not name then
        self.notInterruptible = nil
        if self.backdrop then
            self.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
            self.backdrop:Hide()
        end
        return
    end

    self.casting    = true
    self.channeling = nil
    self.castID     = castID

    local duration = UnitCastingDuration and UnitCastingDuration(unit)
    if duration and self.SetTimerDuration then
        self:SetTimerDuration(duration, Enum.StatusBarInterpolation.Linear, Enum.StatusBarTimerDirection.ElapsedTime)
    elseif startTime and endTime then
        local dur = (endTime - startTime) / 1000
        self:SetMinMaxValues(0, dur)
        self:SetValue(GetTime() - (startTime / 1000))
    end

    self.Icon:SetTexture(texture)
    UpdateTargetCastBarColor(self, notInterruptible)

    local targetName = UnitName("targettarget")
    if targetName then
        self.Text:SetFormattedText("%s > %s", text, targetName)
    else
        self.Text:SetText(text)
    end

    self.backdrop:Show()
end

local function Target_StartChannel(self, unit)
    local name, text, texture, startTime, endTime, isTradeSkill, notInterruptible = UnitChannelInfo(unit)

    if not name then
        self.notInterruptible = nil
        if self.backdrop then
            self.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
            self.backdrop:Hide()
        end
        return
    end

    self.casting    = nil
    self.channeling = true

    local duration = UnitChannelDuration and UnitChannelDuration(unit)
    if duration and self.SetTimerDuration then
        self:SetTimerDuration(duration, Enum.StatusBarInterpolation.Linear, Enum.StatusBarTimerDirection.RemainingTime)
    elseif startTime and endTime then
        local dur = (endTime - startTime) / 1000
        self:SetMinMaxValues(0, dur)
        self:SetValue((endTime / 1000) - GetTime())
    end

    self.Icon:SetTexture(texture)
    UpdateTargetCastBarColor(self, notInterruptible)

    local targetName = UnitName("targettarget")
    if targetName then
        self.Text:SetFormattedText("%s > %s", name, targetName)
    else
        self.Text:SetText(name)
    end

    self.backdrop:Show()
end

local function Target_OnPlayerTargetChanged(event)
    local bar = sfui.castbar.bars and sfui.castbar.bars["target"]
    if not bar then return end

    local barCfg = bar.cfg or g[bar.configName]
    if not barCfg or not barCfg.enabled then
        bar.backdrop:Hide()
        return
    end

    if UnitCastingInfo("target") then
        Target_StartCast(bar, "target")
    elseif UnitChannelInfo("target") then
        Target_StartChannel(bar, "target")
    else
        bar.casting          = nil
        bar.channeling       = nil
        bar.notInterruptible = nil
        if bar.backdrop then
            bar.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
            bar.backdrop:Hide()
        end
    end
end

local function Target_OnUnitEvent(event, unit, ...)
    local bar = sfui.castbar.bars and sfui.castbar.bars["target"]
    if not bar then return end

    local barCfg = bar.cfg or g[bar.configName]
    if not barCfg or not barCfg.enabled then
        bar.backdrop:Hide()
        return
    end

    if unit and unit ~= bar.unit then return end

    if event == "UNIT_SPELLCAST_START" then
        Target_StartCast(bar, unit)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        Target_StartChannel(bar, unit)
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if event == "UNIT_SPELLCAST_STOP" then bar.casting = nil end
        if event == "UNIT_SPELLCAST_CHANNEL_STOP" then bar.channeling = nil end

        if not bar.casting and not bar.channeling then
            bar.notInterruptible = nil
            if bar.backdrop then
                bar.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
                bar.backdrop:Hide()
            end
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        local _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo(unit)
        if notInterruptible == nil then
            local _, _, _, _, _, _, notInterruptibleChannel = UnitChannelInfo(unit)
            if notInterruptibleChannel ~= nil then
                notInterruptible = notInterruptibleChannel
            end
        end
        UpdateTargetCastBarColor(bar, notInterruptible)
    end
end

-- ─── Setup & Initialization ─────────────────────────────────────────────────
local function SetupBar(configName, unit)
    local bar = CreateCastBar(configName, unit)
    sfui.castbar.bars = sfui.castbar.bars or {}
    sfui.castbar.bars[unit] = bar
    bar.resetTimerCallback = function() on_reset_timer(bar) end
    return bar
end

local function SetupTargetBar(configName, unit)
    local bar = CreateCastBar(configName, unit)
    sfui.castbar.bars = sfui.castbar.bars or {}
    sfui.castbar.bars[unit] = bar
    if bar.Spark then bar.Spark:Hide() end
    return bar
end

function sfui.castbar.update_settings()
    -- Sync config from DB
    if SfuiDB.castBarEnabled ~= nil then g.castBar.enabled = SfuiDB.castBarEnabled end
    if SfuiDB.castBarX ~= nil then g.castBar.pos.x = SfuiDB.castBarX end
    if SfuiDB.castBarY ~= nil then g.castBar.pos.y = SfuiDB.castBarY end

    if SfuiDB.targetCastBarEnabled ~= nil then g.targetCastBar.enabled = SfuiDB.targetCastBarEnabled end
    if SfuiDB.targetCastBarX ~= nil then g.targetCastBar.pos.x = SfuiDB.targetCastBarX end
    if SfuiDB.targetCastBarY ~= nil then g.targetCastBar.pos.y = SfuiDB.targetCastBarY end

    -- Apply to active bars
    if sfui.castbar.bars then
        local playerBar = sfui.castbar.bars["player"]
        if playerBar then
            local pCfg = g.castBar
            playerBar.cfg = pCfg
            if not pCfg.enabled then
                playerBar.backdrop:Hide()
                ResetBar(playerBar)
            else
                playerBar.backdrop:ClearAllPoints()
                playerBar.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", pCfg.pos.x, pCfg.pos.y)
            end
        end

        local targetBar = sfui.castbar.bars["target"]
        if targetBar then
            local tCfg = g.targetCastBar
            targetBar.cfg = tCfg
            if not tCfg.enabled then
                targetBar.backdrop:Hide()
                targetBar.casting = nil
                targetBar.channeling = nil
            else
                targetBar.backdrop:ClearAllPoints()
                targetBar.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", tCfg.pos.x, tCfg.pos.y)
            end
        end
    end
end

function sfui.castbar.set_bar_texture(texturePath)
    if sfui.castbar.bars and texturePath and texturePath ~= "" then
        for _, bar in pairs(sfui.castbar.bars) do
            bar:SetStatusBarTexture(texturePath)
        end
    end
end

local _initialized = false

function sfui.castbar.initialize()
    if _initialized then return end
    _initialized = true

    SetupBar("castBar", "player")
    SetupTargetBar("targetCastBar", "target")

    sfui.events.RegisterEvent("PLAYER_TALENT_UPDATE", clear_spell_cache)
    sfui.events.RegisterEvent("SPELLS_CHANGED", clear_spell_cache)

    -- Register Player Unit Events via central dispatcher
    sfui.events.RegisterUnitEvents({
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED",
        "UNIT_SPELLCAST_DELAYED",
        "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_CHANNEL_UPDATE",
        "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_EMPOWER_START",
        "UNIT_SPELLCAST_EMPOWER_UPDATE",
        "UNIT_SPELLCAST_EMPOWER_STOP",
        "UNIT_SPELLCAST_SUCCEEDED",
    }, "player", Player_OnEvent)

    -- Register Target Events via central dispatcher
    sfui.events.RegisterEvent("PLAYER_TARGET_CHANGED", Target_OnPlayerTargetChanged)
    sfui.events.RegisterUnitEvents({
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_INTERRUPTIBLE",
        "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    }, "target", Target_OnUnitEvent)

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
end

-- ─── Memory Profiler Integration (mem.lua) ─────────────────────────────────
local _debugInfo = {
    playerBarCreated = false,
    playerBarShown   = false,
    targetBarCreated = false,
    targetBarShown   = false,
}

function sfui.castbar_debug_info()
    local pBar = sfui.castbar.bars and sfui.castbar.bars["player"]
    local tBar = sfui.castbar.bars and sfui.castbar.bars["target"]

    _debugInfo.playerBarCreated = pBar ~= nil
    _debugInfo.playerBarShown   = (pBar and pBar.backdrop and pBar.backdrop:IsShown()) and true or false
    _debugInfo.targetBarCreated = tBar ~= nil
    _debugInfo.targetBarShown   = (tBar and tBar.backdrop and tBar.backdrop:IsShown()) and true or false

    return _debugInfo
end

sfui.castbar.get_debug_info = sfui.castbar_debug_info

