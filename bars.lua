-- bars.lua for sfui
-- author: teli
-- Adapted from NephUI's resource bar implementation.

sfui = sfui or {}
sfui.bars = {}

do
    local primary_power_bar
    local secondary_power_bar
    local health_bar
    local vigor_bar
    local mount_speed_bar

    local function GetSecondaryResourceValue(resource)
        if not resource then return nil, nil end
        if resource == "STAGGER" then
            local stagger = UnitStagger("player") or 0
            local maxHealth = UnitHealthMax("player") or 1
            return maxHealth, stagger
        end
        -- For Runes, we just show the count, not individual cooldowns.
        if resource == Enum.PowerType.Runes then
            local current, max = 0, UnitPowerMax("player", resource)
            if max <= 0 then return nil, nil end
            for i=1, max do
                local _, _, ready = GetRuneCooldown(i)
                if ready then current = current + 1 end
            end
            return max, current
        end
        local current = UnitPower("player", resource)
        local max = UnitPowerMax("player", resource)
        if max <= 0 then return nil, nil end
        return max, current
    end

    local function IsDragonflying()
        local isFlying, canGlide, _ = C_PlayerInfo.GetGlidingInfo()
        local hasSkyridingBar = (GetBonusBarIndex() == 11 and GetBonusBarOffset() == 5)
        return isFlying or (canGlide and hasSkyridingBar)
    end

    local function UpdateBarPositions()
        if health_bar and health_bar.backdrop then
            health_bar.backdrop:ClearAllPoints()
            health_bar.backdrop:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 300)
        end

        if IsDragonflying() then
            if mount_speed_bar and mount_speed_bar.backdrop and vigor_bar and vigor_bar.backdrop then
                mount_speed_bar.backdrop:ClearAllPoints()
                mount_speed_bar.backdrop:SetPoint("TOP", vigor_bar.backdrop, "BOTTOM", 0, -5) -- Stack under and center with vigor bar
            end
            if vigor_bar and vigor_bar.backdrop and health_bar and health_bar.backdrop then
                vigor_bar.backdrop:ClearAllPoints()
                vigor_bar.backdrop:SetPoint("BOTTOM", health_bar.backdrop, "TOP", 0, 5)
            end
        else
            if primary_power_bar and primary_power_bar.backdrop and health_bar and health_bar.backdrop then
                primary_power_bar.backdrop:ClearAllPoints()
                primary_power_bar.backdrop:SetPoint("TOP", health_bar.backdrop, "BOTTOM", 0, -5)
            end
            if secondary_power_bar and secondary_power_bar.backdrop and health_bar and health_bar.backdrop then
                secondary_power_bar.backdrop:ClearAllPoints()
                secondary_power_bar.backdrop:SetPoint("BOTTOM", health_bar.backdrop, "TOP", 0, 5)
            end
        end
    end

    local function UpdateBarVisibility()
        local isDragonflying = IsDragonflying()
        local inCombat = UnitAffectingCombat("player")
        local hasEnemyTarget = UnitCanAttack("player", "target")
        local showCoreBars = inCombat or hasEnemyTarget

        -- Vigor and Mount Speed bars (instant show/hide)
        if isDragonflying then
            if vigor_bar then vigor_bar.backdrop:Show() end
            if mount_speed_bar then mount_speed_bar.backdrop:Show() end
        else
            if vigor_bar then vigor_bar.backdrop:Hide() end
            if mount_speed_bar then mount_speed_bar.backdrop:Hide() end
        end

        -- Core bars (health, primary, secondary)
        if isDragonflying then
            -- When dragonflying, core bars are always hidden.
            if health_bar then health_bar.backdrop:Hide() end
            if primary_power_bar then primary_power_bar.backdrop:Hide() end
            if secondary_power_bar then secondary_power_bar.backdrop:Hide() end
        else
            local spec = C_SpecializationInfo.GetSpecialization()
            local specID = 0
            if spec then
                specID = select(1, C_SpecializationInfo.GetSpecializationInfo(spec))
            end

            -- Secondary Power Bar visibility for non-dragonflying
            if secondary_power_bar then
                if specID == 270 then -- Mistweaver Monk
                    secondary_power_bar.backdrop:Hide()
                elseif showCoreBars then
                    secondary_power_bar.backdrop:Show()
                else
                    secondary_power_bar.backdrop:Hide()
                end
            end

            -- Health and Primary Power Bar visibility for non-dragonflying
            if showCoreBars then
                if health_bar then health_bar.backdrop:Show() end
                if primary_power_bar then primary_power_bar.backdrop:Show() end
            else
                if health_bar then health_bar.backdrop:Hide() end
                if primary_power_bar then primary_power_bar.backdrop:Hide() end
            end
        end

        UpdateBarPositions()
    end

    local function GetPrimaryPowerBar()
        if primary_power_bar then return primary_power_bar end
        local bar = sfui.common.CreateBar("powerBar", "StatusBar", UIParent)
        bar:GetStatusBarTexture():SetHorizTile(true)
        primary_power_bar = bar
        return bar
    end

    local function UpdatePrimaryPowerBar()
        local cfg = sfui.config.powerBar
        if not cfg.enabled then return end
        local bar = GetPrimaryPowerBar()
        local resource = sfui.common.GetPrimaryResource()
        if not resource then return end
        local max, current = UnitPowerMax("player", resource), UnitPower("player", resource)
        if not max or max <= 0 then return end
        bar:SetMinMaxValues(0, max)
        bar:SetValue(current)
        local color = sfui.common.GetClassOrSpecColor()
        if color then bar:SetStatusBarColor(color.r, color.g, color.b) end
    end

    local function GetHealthBar()
        if health_bar then return health_bar end
        local bar = sfui.common.CreateBar("healthBar", "StatusBar", UIParent)
        bar:GetStatusBarTexture():SetHorizTile(true)
        health_bar = bar

        local cfg = sfui.config.healthBar -- Need this to get height

        local healPredBar = CreateFrame("StatusBar", "sfui_HealthBar_HealPred", health_bar)
        healPredBar:SetHeight(cfg.height / 2)
        healPredBar:SetPoint("TOPLEFT")
        healPredBar:SetPoint("TOPRIGHT") -- Anchored top-right
        healPredBar:SetStatusBarTexture(sfui.config.barTexture)
        healPredBar:SetStatusBarColor(0.5, 1.0, 0.5, 0.5) -- Light-soft-green
        healPredBar:SetFrameLevel(bar:GetFrameLevel() + 1)
        healPredBar:SetReverseFill(true)
        bar.healPredBar = healPredBar

        local absorbBar = CreateFrame("StatusBar", "sfui_HealthBar_Absorb", health_bar)
        absorbBar:SetHeight(cfg.height / 2)
        absorbBar:SetPoint("BOTTOMLEFT")
        absorbBar:SetPoint("BOTTOMRIGHT") -- Anchored bottom-right
        absorbBar:SetStatusBarTexture(sfui.config.barTexture)
        absorbBar:SetFrameLevel(bar:GetFrameLevel() + 2) -- On top of heal prediction
        absorbBar:SetReverseFill(true)
        bar.absorbBar = absorbBar

        return bar
    end

    local function UpdateHealthBar(current, max)
        local cfg = sfui.config.healthBar
        if not cfg.enabled then return end
        local bar = GetHealthBar()
        -- current and max are passed in now
        if not max or max <= 0 then return end
        bar:SetMinMaxValues(0, max)
        bar:SetValue(current)
        bar:SetStatusBarColor(1, 1, 1)

        -- Heal prediction logic
        local incomingHeals = UnitGetIncomingHeals("player") or 0
        bar.healPredBar:SetMinMaxValues(0, max)
        bar.healPredBar:SetValue(incomingHeals)

        -- Absorb bar logic
        local absorbAmount = UnitGetTotalAbsorbs("player")
        bar.absorbBar:SetMinMaxValues(0, max)
        bar.absorbBar:SetValue(absorbAmount)
        local color = SfuiDB.absorbBarColor or (sfui.config and sfui.config.absorbBarColor)
        if color then
            bar.absorbBar:SetStatusBarColor(color[1], color[2], color[3], color[4]) -- Use configurable color
        end
    end

    local function GetSecondaryPowerBar()
        if secondary_power_bar then return secondary_power_bar end
        local bar = sfui.common.CreateBar("secondaryPowerBar", "StatusBar", UIParent)
        bar.TextValue = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bar.TextValue:SetFont("Fonts\FRIZQT__.TTF", sfui.config.secondaryPowerBar.fontSize, "NONE")
        bar.TextValue:SetPoint("CENTER")
        secondary_power_bar = bar
        return bar
    end

    local function UpdateSecondaryPowerBar()
        local cfg = sfui.config.secondaryPowerBar
        if not cfg.enabled then
            if secondary_power_bar and secondary_power_bar.backdrop then secondary_power_bar.backdrop:Hide() end
            return
        end

        local bar = GetSecondaryPowerBar()
        -- The primary resource is determined in common.lua. If it's nil, we hide.
        local resource = sfui.common.GetSecondaryResource()
        if not resource then
            if bar.backdrop then bar.backdrop:Hide() end
            return
        else
            if bar.backdrop then bar.backdrop:Show() end -- Ensure it's shown if resource exists
        end

        local max, current = GetSecondaryResourceValue(resource)
        if not max or max <= 0 then return end
        bar.TextValue:SetText(current)
        bar:SetMinMaxValues(0, max)
        bar:SetValue(current)
        local color
        if cfg.useClassColor then
            color = sfui.common.GetClassOrSpecColor()
        else
            color = sfui.common.GetResourceColor(resource)
        end
        if color then
            bar:SetStatusBarColor(color.r, color.g, color.b)
        end
    end

    local function GetVigorBar()
        if vigor_bar then return vigor_bar end
        local bar = sfui.common.CreateBar("vigorBar", "StatusBar", UIParent)
        bar.TextValue = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bar.TextValue:SetFont("Fonts\FRIZQT__.TTF", sfui.config.secondaryPowerBar.fontSize, "NONE")
        bar.TextValue:SetPoint("CENTER")
        vigor_bar = bar
        return bar
    end

    local function UpdateVigorBar()
        local cfg = sfui.config.vigorBar
        if not cfg.enabled or not IsDragonflying() then if vigor_bar then vigor_bar.backdrop:Hide() end return end
        local bar = GetVigorBar()
        local chargesInfo = C_Spell.GetSpellCharges(372608)
        if not chargesInfo then return end
        bar:SetMinMaxValues(0, chargesInfo.maxCharges)
        bar:SetValue(chargesInfo.currentCharges)
        bar.TextValue:SetText(chargesInfo.currentCharges)
        if cfg.color then
            bar:SetStatusBarColor(cfg.color[1], cfg.color[2], cfg.color[3])
        end
    end

    local function GetMountSpeedBar()
        if mount_speed_bar then return mount_speed_bar end
        local bar = sfui.common.CreateBar("mountSpeedBar", "StatusBar", UIParent)
        bar.TextValue = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bar.TextValue:SetFont("Fonts\FRIZQT__.TTF", 10, "NONE")
        bar.TextValue:SetPoint("CENTER")
        bar:SetScript("OnUpdate", function(self, elapsed)
            sfui.bars:UpdateMountSpeedBar()
        end)
        mount_speed_bar = bar
        return bar
    end

    function sfui.bars:UpdateMountSpeedBar()
        local cfg = sfui.config.mountSpeedBar
        if not cfg.enabled or not IsDragonflying() then if mount_speed_bar then mount_speed_bar.backdrop:Hide() end return end
        local bar = GetMountSpeedBar()
        local _, _, forwardSpeed = C_PlayerInfo.GetGlidingInfo()
        if not forwardSpeed then return end
        local speed = forwardSpeed * 14.286
        local maxSpeed = 1200
        bar:SetMinMaxValues(0, maxSpeed)
        bar:SetValue(speed)
        bar.TextValue:SetFormattedText("%d", speed)
    end


    function sfui.bars:SetBarTexture(texturePath)
        if primary_power_bar then primary_power_bar:SetStatusBarTexture(texturePath) end
        if health_bar then health_bar:SetStatusBarTexture(texturePath) end
        if secondary_power_bar then secondary_power_bar:SetStatusBarTexture(texturePath) end
        if vigor_bar then vigor_bar:SetStatusBarTexture(texturePath) end
        if mount_speed_bar then mount_speed_bar:SetStatusBarTexture(texturePath) end
    end



    function sfui.bars:OnStateChanged()
        UpdatePrimaryPowerBar()
        local max, current = UnitHealthMax("player"), UnitHealth("player")
        UpdateHealthBar(current, max)
        UpdateSecondaryPowerBar()
        UpdateVigorBar()
        sfui.bars:UpdateMountSpeedBar() -- this one is public for the OnUpdate script
        UpdateBarVisibility()
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

    event_frame:SetScript("OnEvent", function(self, event, unit, ...)
        if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM" or event == "PLAYER_CAN_GLIDE_CHANGED" or event == "PLAYER_IS_GLIDING_CHANGED" then
            sfui.bars:OnStateChanged()
        elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_TARGET_CHANGED" then
            UpdateBarVisibility()
        elseif event == "UNIT_POWER_UPDATE" and (not unit or unit == "player") then
            UpdatePrimaryPowerBar()
            UpdateSecondaryPowerBar()
        elseif (event == "UNIT_HEALTH" or event == "UNIT_ABSORB_AMOUNT_CHANGED") and (not unit or unit == "player") then
            local max, current = UnitHealthMax("player"), UnitHealth("player")
            UpdateHealthBar(current, max)
        elseif event == "SPELL_UPDATE_CHARGES" then
            UpdateVigorBar()
        end
    end)
end
