local addonName, addon = ...
sfui = sfui or {}
sfui.bars = {}
local cfg = sfui.config
local common = sfui.common

do
    local bar_minus_1
    local bar1
    local bar0
    local vigor_bar
    local mount_speed_bar
    local rune_bar
    local update_mount_speed_bar_internal

    -- Throttling system for high-frequency events
    local tCfg = cfg.throttle
    local throttle = {
        bar0 = { lastUpdate = 0, interval = tCfg.health },
        bar_minus_1 = { lastUpdate = 0, interval = tCfg.power },
        absorb = { lastUpdate = 0, interval = tCfg.absorb },
        visibility = { lastUpdate = 0, interval = tCfg.visibility },
        runes = { lastUpdate = 0, interval = 0.05 },
    }

    local function should_throttle(key)
        local now = GetTime()
        local t = throttle[key]
        if now - t.lastUpdate >= t.interval then
            t.lastUpdate = now
            return false
        end
        return true
    end

    local function get_secondary_resource_value(resource)
        if not resource then return nil, nil end
        if resource == "STAGGER" then
            local stagger = UnitStagger("player") or 0
            local maxHealth = UnitHealthMax("player") or 1
            return maxHealth, stagger
        end
        if resource == Enum.PowerType.Runes then
            local current, max = 0, UnitPowerMax("player", resource)
            if max <= 0 then return nil, nil end
            for i = 1, max do
                local _, _, ready = GetRuneCooldown(i)
                if ready then current = current + 1 end
            end
            return max, current
        end
        if resource == "FURY" then
            local current = UnitPower("player", Enum.PowerType.Fury)
            local max = UnitPowerMax("player", Enum.PowerType.Fury)
            if max <= 0 then return nil, nil end
            return max, current
        end
        if resource == "DEVOURER_FRAGMENTS" then
            -- Spell IDs verified from 12.0.1.64914 dump
            local VOID_META_ID = 1217607
            local DARK_HEART_ID = 1225789
            local SILENCE_WHISPERS_ID = 1227702

            local inVoidMeta = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(VOID_META_ID)
            local current, max = 0, 5

            if inVoidMeta then
                local aura = C_UnitAuras.GetPlayerAuraBySpellID(SILENCE_WHISPERS_ID)
                if aura then current = aura.applications end
                -- Try new API for max cost, fallback to 5
                if GetCollapsingStarCost then
                    max = GetCollapsingStarCost()
                else
                    max = 5
                end
            else
                local aura = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(DARK_HEART_ID)
                if aura then current = aura.applications end
                if C_Spell and C_Spell.GetSpellMaxCumulativeAuraApplications then
                    max = C_Spell.GetSpellMaxCumulativeAuraApplications(DARK_HEART_ID)
                else
                    max = 5
                end
            end
            return max, current
        end
        local current = UnitPower("player", resource)
        local max = UnitPowerMax("player", resource)
        if max <= 0 then return nil, nil end
        return max, current
    end

    -- Resolve C_ActionBar references once at module load (they never change)
    local _getBonusIdx = C_ActionBar and C_ActionBar.GetBonusBarIndex or GetBonusBarIndex
    local _getBonusOff = C_ActionBar and C_ActionBar.GetBonusBarOffset or GetBonusBarOffset

    -- Cached dragonflying state — invalidated only when glide state changes
    local _dragonflyingCache = nil

    local function invalidate_dragonflying_cache()
        _dragonflyingCache = nil
    end

    local function is_dragonflying()
        if _dragonflyingCache ~= nil then return _dragonflyingCache end
        local isFlying, canGlide, _ = C_PlayerInfo.GetGlidingInfo()
        local hasSkyridingBar = _getBonusIdx and _getBonusOff and
            (_getBonusIdx() == 11 and _getBonusOff() == 5) or false
        _dragonflyingCache = isFlying or (canGlide and hasSkyridingBar)
        return _dragonflyingCache
    end

    local function update_bar_positions()
        local spacing = cfg.barLayout.spacing

        if bar0 and bar0.backdrop then
            bar0.backdrop:ClearAllPoints()
            local cfg = sfui.config.healthBar
            bar0.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", SfuiDB.healthBarX or cfg.pos.x,
                SfuiDB.healthBarY or cfg.pos.y)
        end

        if is_dragonflying() then
            if mount_speed_bar and mount_speed_bar.backdrop and vigor_bar and vigor_bar.backdrop then
                mount_speed_bar.backdrop:ClearAllPoints()
                mount_speed_bar.backdrop:SetPoint("TOP", vigor_bar.backdrop, "BOTTOM", 0, -spacing) -- Stack under and center with vigor bar

                if vigor_bar.whirlingSurgeIcon and vigor_bar.secondWindIcon then
                    local iconCfg = cfg.vigorBar.icons
                    local gap = iconCfg.gap
                    vigor_bar.whirlingSurgeIcon:ClearAllPoints()
                    vigor_bar.whirlingSurgeIcon:SetPoint("TOPRIGHT", mount_speed_bar.backdrop, "BOTTOM", -gap / 2,
                        iconCfg.offsetY)
                    vigor_bar.secondWindIcon:ClearAllPoints()
                    vigor_bar.secondWindIcon:SetPoint("TOPLEFT", mount_speed_bar.backdrop, "BOTTOM", gap / 2,
                        iconCfg.offsetY)

                    if vigor_bar.staticChargeIcon then
                        vigor_bar.staticChargeIcon:ClearAllPoints()
                        vigor_bar.staticChargeIcon:SetPoint("LEFT", vigor_bar.backdrop, "RIGHT", iconCfg.sideOffset, 0)
                    end
                end
            end
            if vigor_bar and vigor_bar.backdrop and bar0 and bar0.backdrop then
                vigor_bar.backdrop:ClearAllPoints()
                vigor_bar.backdrop:SetPoint("BOTTOM", bar0.backdrop, "TOP", 0, spacing)
            end
        else
            if bar_minus_1 and bar_minus_1.backdrop and bar0 and bar0.backdrop then
                bar_minus_1.backdrop:ClearAllPoints()
                bar_minus_1.backdrop:SetPoint("TOP", bar0.backdrop, "BOTTOM", 0, -spacing)
            end
            if bar1 and bar1.backdrop and bar0 and bar0.backdrop then
                bar1.backdrop:ClearAllPoints()
                bar1.backdrop:SetPoint("BOTTOM", bar0.backdrop, "TOP", 0, spacing)
            end
            if rune_bar and bar0 and bar0.backdrop then
                rune_bar:ClearAllPoints()
                rune_bar:SetPoint("BOTTOM", bar0.backdrop, "TOP", 0, spacing)
            end
        end
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
            sfui.trackedbars.ForceLayoutUpdate()
        end
        if sfui.trackedicons and sfui.trackedicons.MarkDirty then
            sfui.trackedicons.MarkDirty(0.5, true)
        end
    end

    local function update_bar_visibility()
        local isDragonflying = is_dragonflying()
        local inCombat = UnitAffectingCombat("player")
        local hasEnemyTarget = UnitCanAttack("player", "target")
        local showCoreBars = inCombat or hasEnemyTarget

        if isDragonflying then
            if vigor_bar and SfuiDB.enableVigorBar then
                vigor_bar.backdrop:Show()
            else
                if vigor_bar then
                    vigor_bar.backdrop:Hide()
                end
            end
            if mount_speed_bar and SfuiDB.enableMountSpeedBar then
                mount_speed_bar.backdrop:Show()
            else
                if mount_speed_bar then
                    mount_speed_bar.backdrop:Hide()
                end
            end
            if bar0 then bar0.backdrop:Hide() end
            if bar_minus_1 then bar_minus_1.backdrop:Hide() end
            if bar1 then bar1.backdrop:Hide() end
            if rune_bar then rune_bar:Hide() end
        else
            local specID = common.get_current_spec_id()

            -- Core Bars Visibility (Health, Power, Secondary Power)
            if showCoreBars then
                -- Health Bar (bar0)
                if bar0 and SfuiDB.enableHealthBar then
                    bar0.backdrop:Show()
                elseif bar0 then
                    bar0.backdrop:Hide()
                end

                -- Primary Power Bar (bar_minus_1)
                local hidePower = cfg.powerBar.hiddenSpecs and cfg.powerBar.hiddenSpecs[specID]
                if bar_minus_1 and SfuiDB.enablePowerBar and not hidePower then
                    bar_minus_1.backdrop:Show()
                elseif bar_minus_1 then
                    bar_minus_1.backdrop:Hide()
                end

                -- Secondary Power Bar (bar1)
                local hideSecondary = cfg.secondaryPowerBar.hiddenSpecs and
                    cfg.secondaryPowerBar.hiddenSpecs[specID]
                local secResource = common.get_secondary_resource()

                if bar1 and SfuiDB.enableSecondaryPowerBar and not hideSecondary and secResource and secResource ~= Enum.PowerType.Runes then
                    bar1.backdrop:Show()
                elseif bar1 then
                    bar1.backdrop:Hide()
                end

                -- Rune Bar
                local isRune = (secResource == Enum.PowerType.Runes)
                if rune_bar and isRune and SfuiDB.enableSecondaryPowerBar then
                    rune_bar:Show()
                elseif rune_bar then
                    rune_bar:Hide()
                end
            else
                if bar0 then bar0.backdrop:Hide() end
                if bar_minus_1 then bar_minus_1.backdrop:Hide() end
                if bar1 then bar1.backdrop:Hide() end
                if rune_bar then rune_bar:Hide() end
            end
        end

        update_bar_positions()
    end

    local function get_bar_minus_1()
        if bar_minus_1 then return bar_minus_1 end
        local bar = common.create_bar("bar_minus_1", "StatusBar", UIParent, nil, "powerBar")
        bar:GetStatusBarTexture():SetHorizTile(true)

        local marker = bar:CreateTexture(nil, "OVERLAY")
        marker:SetColorTexture(1, 1, 1, 0.8)
        marker:SetWidth(2)
        marker:SetPoint("TOP", bar, "TOP")
        marker:SetPoint("BOTTOM", bar, "BOTTOM")
        marker:Hide()
        bar.marker = marker

        bar_minus_1 = bar
        return bar
    end

    local function update_bar_minus_1()
        local cfg = sfui.config.powerBar
        local specID = common.get_current_spec_id()
        local hide = cfg.hiddenSpecs and cfg.hiddenSpecs[specID]

        if not cfg.enabled or is_dragonflying() or hide then
            if bar_minus_1 and bar_minus_1.backdrop then bar_minus_1.backdrop:Hide() end
            return
        end
        local bar = get_bar_minus_1()
        local resource = common.get_primary_resource()
        if not resource then return end
        local max, current = UnitPowerMax("player", resource), UnitPower("player", resource)
        if not max or max <= 0 then return end
        bar:SetMinMaxValues(0, max)
        bar:SetValue(current)
        local color = common.get_class_or_spec_color()
        if color then bar:SetStatusBarColor(color[1], color[2], color[3]) end

        -- Marker logic
        if specID == 258 then -- Shadow Priest (55% threshold)
            bar.marker:ClearAllPoints()
            bar.marker:SetPoint("LEFT", bar, "LEFT", bar:GetWidth() * 0.55, 0)
            bar.marker:SetHeight(bar:GetHeight())
            bar.marker:Show()
        elseif specID == 1480 and max >= 100 then -- Devourer Demon Hunter (100 value)
            bar.marker:ClearAllPoints()
            local width = bar:GetWidth()
            local pct = 100 / max
            bar.marker:SetPoint("LEFT", bar, "LEFT", width * pct, 0)
            bar.marker:SetHeight(bar:GetHeight())
            bar.marker:Show()
        else
            bar.marker:Hide()
        end
    end

    -- UpdateFillPosition removed (Secret Values cannot be used in arithmetic).
    -- We rely on StatusBar:SetValue() to handle secure values internally.

    local function get_bar0()
        if bar0 then return bar0 end
        local bar = common.create_bar("bar0", "StatusBar", UIParent, nil, "healthBar")
        bar:GetStatusBarTexture():SetHorizTile(true)
        bar0 = bar

        local textureName = SfuiDB.barTexture
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local texturePath
        if LSM then
            texturePath = LSM:Fetch("statusbar", textureName)
        end
        if not texturePath or texturePath == "" then
            texturePath = cfg.barTexture
        end

        local healPredBar = CreateFrame("StatusBar", nil, bar)
        healPredBar:SetFrameLevel(bar:GetFrameLevel() + 1)
        healPredBar:SetStatusBarTexture(texturePath)
        healPredBar:SetStatusBarColor(0.0, 0.8, 0.6, 0.5)
        healPredBar:GetStatusBarTexture():SetBlendMode("ADD")
        bar.healPredBar = healPredBar

        local absorbBar = CreateFrame("StatusBar", nil, bar)
        absorbBar:SetFrameLevel(bar:GetFrameLevel() + 2)
        absorbBar:SetStatusBarTexture(texturePath)
        absorbBar:GetStatusBarTexture():SetBlendMode("ADD")
        bar.absorbBar = absorbBar

        return bar
    end

    local function update_bar0(current, maxVal)
        local cfg = sfui.config.healthBar
        if not cfg.enabled then return end
        local bar = get_bar0()
        -- current and max are passed in now
        if not maxVal or maxVal <= 0 then return end
        bar:SetMinMaxValues(0, maxVal)
        bar:SetValue(current)

        local fgColor = SfuiDB.healthBarColor or cfg.color
        if fgColor then
            bar:SetStatusBarColor(fgColor[1], fgColor[2], fgColor[3], fgColor[4] or 1)
        end

        local bgColor = SfuiDB.healthBarBackdropColor or cfg.backdrop.color
        if bgColor and bar.backdrop then
            bar.backdrop:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.5)
        end

        local width, height = bar:GetSize()
        local healPred = bar.healPredBar
        healPred:SetSize(width, height)
        healPred:SetMinMaxValues(0, maxVal)
        healPred:ClearAllPoints()
        healPred:SetPoint("TOPLEFT", bar:GetStatusBarTexture(), "TOPRIGHT", 0, 0)

        local incomingHeals = UnitGetIncomingHeals("player") or 0
        healPred:SetValue(incomingHeals)

        local absorbBar = bar.absorbBar
        absorbBar:SetSize(width, height); absorbBar:SetMinMaxValues(0, maxVal)
        absorbBar:ClearAllPoints()
        absorbBar:SetPoint("TOPLEFT", healPred:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
        local absorbAmount = UnitGetTotalAbsorbs("player") or 0
        absorbBar:SetValue(absorbAmount)
        local color = SfuiDB.absorbBarColor or (cfg and cfg.absorbBarColor)
        absorbBar:SetStatusBarColor(common.unpack_color(color))
    end

    local function get_rune_bar()
        if rune_bar then return rune_bar end
        local container = CreateFrame("Frame", "sfui_runeBar", UIParent)
        container:SetHeight(20)

        container.runes = {}

        -- Resolve texture once
        local textureName = SfuiDB.barTexture
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local texturePath
        if LSM then
            texturePath = LSM:Fetch("statusbar", textureName)
        end
        if not texturePath or texturePath == "" then
            texturePath = cfg.barTexture
        end

        for i = 1, 6 do
            local rune = CreateFrame("StatusBar", nil, container, "BackdropTemplate")
            rune:SetStatusBarTexture(texturePath)
            rune:SetStatusBarColor(1, 1, 1) -- Set later

            rune:SetBackdrop({
                bgFile = "Interface/Buttons/WHITE8X8",
                edgeFile = "Interface/Buttons/WHITE8X8",
                edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            rune:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            rune:SetBackdropBorderColor(0, 0, 0, 1)

            container.runes[i] = rune
        end

        -- Rune updates are handled by RUNE_POWER_UPDATE event (line 716, 737-740)
        -- OnUpdate removed to eliminate 20fps polling overhead

        rune_bar = container
        return rune_bar
    end

    local function update_rune_bar()
        local secResource = common.get_secondary_resource()
        if secResource ~= Enum.PowerType.Runes then
            if rune_bar then rune_bar:Hide() end
            return
        end

        local bar = get_rune_bar()

        local healthWidth = cfg.healthBar.width
        local maxTotalWidth = healthWidth * 0.8
        local spacing = 2
        local numRunes = 6

        -- Integer division for perfect pixel alignment
        local runeWidth = math.floor((maxTotalWidth - (spacing * (numRunes - 1))) / numRunes)
        local usedWidth = (runeWidth * numRunes) + (spacing * (numRunes - 1))

        local runeHeight = 10

        bar:SetSize(usedWidth, runeHeight)

        -- Update tracked bars layout to respect Rune Bar presence
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
            sfui.trackedbars.ForceLayoutUpdate()
        end

        -- Sorting Logic — reuse pre-allocated table to avoid GC pressure
        local runeInfo = bar._runeInfo
        if not runeInfo then
            runeInfo = {}
            for i = 1, 6 do runeInfo[i] = { id = i, ready = false, expiration = 0, start = 0, duration = 0 } end
            bar._runeInfo = runeInfo
        end
        for i = 1, 6 do
            local start, duration, ready = GetRuneCooldown(i)
            local entry = runeInfo[i]
            entry.id = i
            entry.ready = ready
            entry.start = start or 0
            entry.duration = duration or 0
            entry.expiration = (not ready) and (start + duration) or 0
        end

        table.sort(runeInfo, function(a, b)
            if a.ready and not b.ready then return true end
            if not a.ready and b.ready then return false end
            if not a.ready and not b.ready then
                return a.expiration < b.expiration
            end
            -- Both ready, order by ID to keep stable
            return a.id < b.id
        end)

        local specColor = common.get_class_or_spec_color()

        -- Position frames according to sorted order
        for pos = 1, 6 do
            local info = runeInfo[pos]
            local rune = bar.runes[info.id] -- Get the actual frame for this rune ID

            rune:SetSize(runeWidth, runeHeight)
            rune:ClearAllPoints()
            if pos == 1 then
                rune:SetPoint("LEFT", bar, "LEFT", 0, 0)
            else
                -- Point to the previously positioned rune
                local prevInfo = runeInfo[pos - 1]
                local prevRune = bar.runes[prevInfo.id]
                rune:SetPoint("LEFT", prevRune, "RIGHT", spacing, 0)
            end

            -- Store state on the frame for OnUpdate
            rune.start = info.start
            rune.duration = info.duration
            rune.ready = info.ready

            -- Set Colors
            if info.ready then
                if specColor then
                    rune:SetStatusBarColor(specColor[1], specColor[2], specColor[3])
                else
                    rune:SetStatusBarColor(1, 0.2, 0.3)
                end
                rune:SetMinMaxValues(0, 1)
                rune:SetValue(1)
            else
                -- Charging: #444444 (Lighter Grey)
                rune:SetStatusBarColor(0.266, 0.266, 0.266)
                rune:SetMinMaxValues(0, info.duration)
                local current = GetTime() - info.start
                rune:SetValue(current)
            end
        end
    end

    local function get_bar1()
        if bar1 then return bar1 end
        local bar = common.create_bar("bar1", "StatusBar", UIParent, nil, "secondaryPowerBar")
        bar.TextValue = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bar.TextValue:SetFont("Fonts\\FRIZQT__.TTF", cfg.secondaryPowerBar.fontSize, "NONE")
        bar.TextValue:SetShadowOffset(1, -1)
        bar.TextValue:SetPoint("CENTER")
        bar1 = bar
        return bar
    end

    local function update_bar1()
        local cfg = sfui.config.secondaryPowerBar
        local specID = common.get_current_spec_id()
        local hide = cfg.hiddenSpecs and cfg.hiddenSpecs[specID]

        if not cfg.enabled or is_dragonflying() or hide then
            if bar1 and bar1.backdrop then bar1.backdrop:Hide() end
            return
        end

        local resource = common.get_secondary_resource()

        if resource == Enum.PowerType.Runes then
            if bar1 and bar1.backdrop then bar1.backdrop:Hide() end
            return
        end

        if not resource then
            if bar1 and bar1.backdrop then bar1.backdrop:Hide() end
            return
        end

        local max, current = get_secondary_resource_value(resource)
        if not max or max <= 0 then
            if bar1 and bar1.backdrop then bar1.backdrop:Hide() end
            return
        end

        local bar = get_bar1()
        bar.TextValue:SetText(current)
        bar:SetMinMaxValues(0, max)
        bar:SetValue(current)

        -- Devourer Customization
        if specID == 1480 then
            -- Cosmic Purple (#6600FF)
            bar:SetStatusBarColor(0.4, 0.0, 1.0)
        else
            local color
            if cfg.useClassColor then
                color = common.get_class_or_spec_color()
            else
                color = common.get_resource_color(resource)
            end
            if color then
                bar:SetStatusBarColor(color[1], color[2], color[3])
            end
        end
    end

    local function create_icon(parent, name, size, spellID)
        local frame = CreateFrame("Frame", name, parent)
        frame:SetSize(size, size)

        local texture = frame:CreateTexture(nil, "BACKGROUND")
        texture:SetAllPoints()
        local spellTexture = C_Spell.GetSpellTexture(spellID)
        texture:SetTexture(spellTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- Zoom in slightly to remove borders
        frame.texture = texture

        local cd = CreateFrame("Cooldown", name .. "Cooldown", frame, "CooldownFrameTemplate")
        cd:SetAllPoints()
        frame.cooldown = cd

        local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        text:SetPoint("TOP", frame, "BOTTOM", 0, -2)
        frame.countText = text

        return frame
    end

    local function get_vigor_bar()
        if vigor_bar then return vigor_bar end
        local bar = common.create_bar("vigorBar", "StatusBar", UIParent)
        bar.TextValue = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bar.TextValue:SetFont("Fonts\\FRIZQT__.TTF", cfg.secondaryPowerBar.fontSize, "NONE")
        bar.TextValue:SetShadowOffset(1, -1); bar.TextValue:SetPoint("CENTER")
        local iconSize = 40
        bar.whirlingSurgeIcon = create_icon(bar, "sfui_WhirlingSurgeIcon", iconSize, 361584)
        bar.secondWindIcon = create_icon(bar, "sfui_SecondWindIcon", iconSize, 425782)
        bar.staticChargeIcon = create_icon(bar, "sfui_StaticChargeIcon", iconSize, 418590)
        bar.staticChargeIcon.countText:ClearAllPoints()
        bar.staticChargeIcon.countText:SetPoint("CENTER", bar.staticChargeIcon, "CENTER", 0, 0)
        bar.staticChargeIcon:Hide()
        vigor_bar = bar
        return bar
    end

    local function update_vigor_bar()
        local cfg = sfui.config.vigorBar
        if not cfg.enabled or not is_dragonflying() then
            if vigor_bar then
                vigor_bar.backdrop:Hide()
            end
            return
        end
        local bar = get_vigor_bar()
        local chargesInfo = C_Spell.GetSpellCharges(372608)
        if chargesInfo then
            bar:SetMinMaxValues(0, chargesInfo.maxCharges)
            bar:SetValue(chargesInfo.currentCharges)
            bar.TextValue:SetText(chargesInfo.currentCharges)
        end

        if cfg.color then
            bar:SetStatusBarColor(cfg.color[1], cfg.color[2], cfg.color[3])
        end

        local isPlayerSpell = IsPlayerSpell or
            function(id) return C_SpellBook and C_SpellBook.IsSpellKnown(id, Enum.SpellBookSpellBank.Player) end
        local surgeSpellID = isPlayerSpell(418592) and 418592 or 361584

        local surgeTexture = C_Spell.GetSpellTexture(surgeSpellID)
        bar.whirlingSurgeIcon.texture:SetTexture(surgeTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
        bar.whirlingSurgeIcon.texture:SetDesaturated(false)
        bar.whirlingSurgeIcon.countText:SetText("")

        local wsInfo = C_Spell.GetSpellCooldown(surgeSpellID)
        if wsInfo then
            bar.whirlingSurgeIcon.cooldown:SetCooldown(wsInfo.startTime, wsInfo.duration)
        end

        local scAura = C_UnitAuras.GetPlayerAuraBySpellID(418590)
        if scAura and scAura.applications > 0 then
            bar.staticChargeIcon:Show(); bar.staticChargeIcon.countText:SetText(scAura.applications)
        else
            bar.staticChargeIcon:Hide()
        end

        local swInfo = C_Spell.GetSpellCooldown(425782)
        local swCharges = C_Spell.GetSpellCharges(425782)
        if swInfo then bar.secondWindIcon.cooldown:SetCooldown(swInfo.startTime, swInfo.duration) end
        bar.secondWindIcon.countText:SetText(swCharges and swCharges.currentCharges or "")
    end

    local function get_mount_speed_bar()
        if mount_speed_bar then return mount_speed_bar end
        local bar = common.create_bar("mountSpeedBar", "StatusBar", UIParent)
        bar.TextValue = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bar.TextValue:SetFont("Fonts\\FRIZQT__.TTF", 12, "NONE")
        bar.TextValue:SetShadowOffset(1, -1)
        bar.TextValue:SetPoint("CENTER")
        bar.lastSpeed = 0 -- Cache for change detection

        -- Speed requires polling as there is no gliding speed event
        bar:SetScript("OnUpdate", function(self, elapsed)
            self.timer = (self.timer or 0) + elapsed
            if self.timer > 0.05 then -- Throttled to 20fps
                self.timer = 0
                update_mount_speed_bar_internal()
            end
        end)

        mount_speed_bar = bar
        return bar
    end

    update_mount_speed_bar_internal = function()
        local cfg = sfui.config.mountSpeedBar
        if not cfg.enabled or not is_dragonflying() then
            if mount_speed_bar then mount_speed_bar.backdrop:Hide() end
            return
        end
        local bar = mount_speed_bar or get_mount_speed_bar()
        local _, _, forwardSpeed = C_PlayerInfo.GetGlidingInfo()
        if not forwardSpeed then return end
        local speed = forwardSpeed * 14.286
        local maxSpeed = 1200
        bar:SetMinMaxValues(0, maxSpeed)
        bar:SetValue(speed)

        -- Only update text if speed changed significantly (>5 units)
        if math.abs(speed - bar.lastSpeed) > 5 then
            bar.TextValue:SetFormattedText("%d", speed)
            bar.lastSpeed = speed
        end

        local aura = C_UnitAuras.GetPlayerAuraBySpellID(377234)
        if aura then
            bar:SetStatusBarColor(1, 0, 1)
        else
            if cfg.color then
                bar:SetStatusBarColor(cfg.color[1], cfg.color[2], cfg.color[3])
            else
                bar:SetStatusBarColor(1, 1, 1) -- Default to White
            end
        end
    end

    sfui.bars.update_mount_speed_bar = update_mount_speed_bar_internal

    function sfui.bars.set_bar_texture(arg1, arg2)
        local texturePath = (type(arg1) == "string") and arg1 or arg2
        if not texturePath then return end

        if bar_minus_1 then bar_minus_1:SetStatusBarTexture(texturePath) end
        if bar0 then
            bar0:SetStatusBarTexture(texturePath)
            if bar0.healPredBar then bar0.healPredBar:SetStatusBarTexture(texturePath) end
            if bar0.absorbBar then bar0.absorbBar:SetStatusBarTexture(texturePath) end
            if bar0.lossBar then bar0.lossBar:SetStatusBarTexture(texturePath) end
        end
        if bar1 then bar1:SetStatusBarTexture(texturePath) end
        if vigor_bar then vigor_bar:SetStatusBarTexture(texturePath) end
        if mount_speed_bar then mount_speed_bar:SetStatusBarTexture(texturePath) end
    end

    function sfui.bars:on_state_changed()
        update_bar_minus_1()
        local max, current = UnitHealthMax("player"), UnitHealth("player")
        update_bar0(current, max)
        update_bar1()
        update_vigor_bar()
        update_rune_bar()
        update_mount_speed_bar_internal()
        update_bar_visibility()
    end

    function sfui.bars:update_health_bar_position()
        update_bar_positions()
    end

    local event_frame = CreateFrame("Frame")
    event_frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    event_frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    event_frame:RegisterEvent("UNIT_POWER_UPDATE")
    event_frame:RegisterEvent("UNIT_HEALTH")
    event_frame:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")
    event_frame:RegisterEvent("PLAYER_CAN_GLIDE_CHANGED")
    event_frame:RegisterEvent("PLAYER_IS_GLIDING_CHANGED")
    event_frame:RegisterEvent("SPELL_UPDATE_CHARGES")
    event_frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    event_frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    event_frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    event_frame:RegisterEvent("RUNE_POWER_UPDATE")
    event_frame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
    event_frame:RegisterEvent("PLAYER_ENTERING_WORLD")

    event_frame:SetScript("OnEvent", function(self, event, unit, ...)
        if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM" or event == "PLAYER_CAN_GLIDE_CHANGED" or event == "PLAYER_IS_GLIDING_CHANGED" or event == "PLAYER_MOUNT_DISPLAY_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
            invalidate_dragonflying_cache()
            sfui.bars:on_state_changed()
        elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_TARGET_CHANGED" then
            if not should_throttle("visibility") then
                update_bar_visibility()
            end
        elseif event == "UNIT_POWER_UPDATE" and (not unit or unit == "player") then
            if not should_throttle("bar_minus_1") then
                update_bar_minus_1()
                update_bar1()
            end
        elseif (event == "UNIT_HEALTH" or event == "UNIT_ABSORB_AMOUNT_CHANGED") and (not unit or unit == "player") then
            if not should_throttle("bar0") then
                local max, current = UnitHealthMax("player"), UnitHealth("player")
                update_bar0(current, max)
            end
        elseif event == "SPELL_UPDATE_CHARGES" then
            update_vigor_bar()
        elseif event == "RUNE_POWER_UPDATE" then
            if not should_throttle("runes") then
                update_rune_bar()
            end
        end
    end)
end
