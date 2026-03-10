local addonName, addon = ...
sfui.vehicle = {}

local frame = CreateFrame("Frame", "SfuiVehicleBar", UIParent, "SecureHandlerStateTemplate")
sfui.vehicle.frame = frame

local GetActionCooldown = GetActionCooldown
local GetActionCount = GetActionCount
local GetActionCharges = GetActionCharges

local cfg = sfui.config.vehicle
local g = sfui.config
local mult = sfui.pixelScale or 1

frame:SetSize(cfg.width, cfg.height)
frame:SetPoint(cfg.anchor.point, cfg.anchor.x, cfg.anchor.y)

-- Reuse locals
local _v_start, _v_duration, _v_enable, _v_count, _v_charges, _v_maxCharges, _v_chargeStart, _v_chargeDuration, _v_displayCount, _v_isSecret, _v_actionID, _v_icon, _v_barIndex

local debounceFrame = CreateFrame("Frame")
debounceFrame:Hide()
debounceFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    sfui.vehicle.UpdateActionButtons()
end)

local function RequestUpdate()
    debounceFrame:Show()
end

local function OnEnter(self)
    local action = self:GetAttribute("action")
    if action then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetAction(action)
        GameTooltip:Show()
    end
end

local function OnLeave() GameTooltip:Hide() end

local function LeaveOnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(LEAVE_VEHICLE)
    GameTooltip:Show()
end

-- Background
frame.bg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
frame.bg:SetAllPoints()
frame.bg:SetBackdrop({
    bgFile = g.textures.white,
    edgeFile = g.textures.white,
    edgeSize = mult,
})
frame.bg:SetBackdropColor(0, 0, 0, 0.5)
frame.bg:SetBackdropBorderColor(g.colors.gray[1], g.colors.gray[2], g.colors.gray[3], 1)

-- Buttons
local buttons = {}
for i = 1, 12 do
    local btn = CreateFrame("CheckButton", "SfuiVehicleButton" .. i, frame,
        "SecureActionButtonTemplate, ActionButtonTemplate")
    btn:SetSize(cfg.button_size, cfg.button_size)
    btn:SetID(i)

    -- Style
    if _G[btn:GetName() .. "Icon"] then _G[btn:GetName() .. "Icon"]:SetAlpha(0) end
    if btn.Flash then btn.Flash:SetAlpha(0) end
    if btn.NewActionTexture then btn.NewActionTexture:SetAlpha(0) end
    if btn.Border then btn.Border:SetAlpha(0) end
    if btn.HotKey then btn.HotKey:SetAlpha(0) end

    if btn.Count then
        btn.Count:ClearAllPoints()
        btn.Count:SetPoint("BOTTOMRIGHT", -2, 2)
        btn.Count:SetFontObject("GameFontHighlight")
        btn.Count:SetJustifyH("RIGHT")
        btn.Count:SetAlpha(1)
    end

    btn:SetNormalTexture("")
    btn:SetPushedTexture("")
    btn:SetHighlightTexture("")
    btn:SetCheckedTexture("")

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()

    sfui.common.apply_square_icon_style(btn, btn.icon)

    local cd = _G[btn:GetName() .. "Cooldown"] or btn.cooldown
    if cd then
        cd:SetDrawEdge(true)
        cd:SetHideCountdownNumbers(false)
    end

    local shadow = CreateFrame("Cooldown", "$parentShadowCD", btn, "CooldownFrameTemplate")
    shadow:SetAllPoints(btn.icon)
    shadow:SetDrawSwipe(false)
    shadow:SetDrawEdge(false)
    shadow:SetDrawBling(false)
    shadow:SetHideCountdownNumbers(true)
    shadow:SetAlpha(0)
    btn.shadowCooldown = shadow

    -- Keybind
    btn.kb = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.kb:SetPoint("TOPRIGHT", -2, -2)
    local kbText = sfui.common.VEHICLE_KEYBIND_MAP[i] or tostring(i)
    btn.kb:SetText(kbText)

    if i == 1 then
        btn:SetPoint("LEFT", cfg.button_spacing, 0)
    else
        btn:SetPoint("LEFT", buttons[i - 1], "RIGHT", cfg.button_spacing, 0)
    end

    sfui.common.sync_masque(btn)

    btn:SetScript("OnEnter", OnEnter)
    btn:SetScript("OnLeave", OnLeave)

    buttons[i] = btn
end

-- Leave Button
local leaveBtn = CreateFrame("Button", "SfuiVehicleLeaveButton", frame, "SecureActionButtonTemplate")
leaveBtn:SetSize(cfg.button_size, cfg.button_size) -- Match size for consistency
leaveBtn:SetPoint("LEFT", buttons[12], "RIGHT", cfg.button_spacing * 2, 0)
leaveBtn:RegisterForClicks("AnyUp")

local leaveIcon = leaveBtn:CreateTexture(nil, "ARTWORK")
leaveIcon:SetAllPoints()
-- Use the standard modern Atlas for vehicle exit
if not leaveIcon:SetAtlas("actionbar-vehicle-exit") then
    leaveIcon:SetTexture("Interface\\Buttons\\UI-Panel-ExitButton-Up")
end
leaveBtn.Icon = leaveIcon
leaveBtn.icon = leaveIcon -- For internal script compatibility if needed

sfui.common.apply_square_icon_style(leaveBtn, leaveBtn.icon)

-- Keybind for Leave
leaveBtn.kb = leaveBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
leaveBtn.kb:SetPoint("TOPRIGHT", -2, -2)
leaveBtn.kb:SetText("=")

sfui.common.sync_masque(leaveBtn)

leaveBtn:SetScript("OnEnter", LeaveOnEnter)
leaveBtn:SetScript("OnLeave", OnLeave)

leaveBtn:SetScript("OnClick", function()
    if UnitOnTaxi("player") then
        TaxiRequestEarlyLanding()
    else
        VehicleExit()
    end
end)

-- Handle Vehicle State
-- Suppress during Dragonriding (skyriding) but only when on a mount
-- This avoids suppressing quest vehicles that might trigger dragonriding
local visString = "[petbattle] hide; [mounted,bonusbar:5] hide; "
if sfui.common.get_player_class() == "DRUID" then
    visString = visString ..
        "[form:3,bonusbar:5] hide; [form:4,bonusbar:5] hide; " -- Form 3 & 4 catches Travel/Moonkin edge cases
end
visString = visString .. "[vehicleui][possessbar][overridebar][bonusbar:5] show; hide"

RegisterStateDriver(frame, "visibility", visString)

local function UpdateCooldowns()
    if not frame:IsVisible() then return end
    for i = 1, 12 do
        local btn = buttons[i]
        if btn:IsVisible() then
            _v_actionID = btn:GetAttribute("action")
            if _v_actionID then
                _v_start, _v_duration, _v_enable = GetActionCooldown(_v_actionID)

                -- Gating: Cooldown
                if _v_start ~= btn._lastStart or _v_duration ~= btn._lastDuration then
                    local cd = _G[btn:GetName() .. "Cooldown"] or btn.cooldown
                    if cd then cd:SetCooldown(_v_start, _v_duration) end
                    if btn.shadowCooldown then btn.shadowCooldown:SetCooldown(_v_start, _v_duration) end
                    btn._lastStart = _v_start
                    btn._lastDuration = _v_duration
                end

                _v_count = GetActionCount(_v_actionID)
                _v_charges, _v_maxCharges, _v_chargeStart, _v_chargeDuration = GetActionCharges(_v_actionID)
                _v_displayCount = _v_charges or _v_count or 0

                -- Gating: Count
                if _v_displayCount ~= btn._lastCount or _v_maxCharges ~= btn._lastMaxCharges then
                    _v_isSecret = sfui.common.issecretvalue(_v_displayCount) or sfui.common.issecretvalue(_v_maxCharges)
                    if btn.Count then
                        if not _v_isSecret and (_v_displayCount > 0 or (_v_maxCharges and _v_maxCharges > 1)) then
                            btn.Count:SetText(tostring(_v_displayCount))
                            btn.Count:Show()
                        else
                            btn.Count:Hide()
                        end
                    end
                    btn._lastCount = _v_displayCount
                    btn._lastMaxCharges = _v_maxCharges
                end
            end
        end
    end
end
sfui.vehicle.UpdateCooldowns = UpdateCooldowns

local function UpdateActionButtons()
    if InCombatLockdown() then
        frame.needsUpdate = true
        return
    end
    frame.needsUpdate = false

    if C_ActionBar.HasVehicleActionBar() then
        _v_barIndex = C_ActionBar.GetVehicleBarIndex()
    elseif C_ActionBar.HasOverrideActionBar() then
        _v_barIndex = C_ActionBar.GetOverrideBarIndex()
    elseif C_ActionBar.HasTempShapeshiftActionBar() then
        _v_barIndex = C_ActionBar.GetTempShapeshiftBarIndex()
    elseif C_ActionBar.HasBonusActionBar() then
        _v_barIndex = C_ActionBar.GetBonusBarIndex()
    else
        _v_barIndex = C_ActionBar.GetActionBarPage()
    end

    if not _v_barIndex or _v_barIndex == 0 then _v_barIndex = 1 end

    local lastIdx = 0
    for i = 1, 12 do
        local btn = buttons[i]
        _v_actionID = (_v_barIndex - 1) * 12 + i
        btn:SetAttribute("action", _v_actionID)

        _v_icon = C_ActionBar.GetActionTexture(_v_actionID)
        if _v_icon then
            if btn.icon:GetTexture() ~= _v_icon then
                btn.icon:SetTexture(_v_icon)
            end
            if not btn:IsShown() then btn:Show() end
            lastIdx = i
            -- Sync Masque state
            sfui.common.sync_masque(btn)
        else
            if btn:IsShown() then btn:Hide() end
        end
    end

    -- Ensure Leave button is visible and correctly anchored
    if lastIdx > 0 then
        local totalWidth = (cfg.button_size + cfg.button_spacing) * (lastIdx + 1) + cfg.button_spacing
        if frame:GetWidth() ~= totalWidth then frame:SetWidth(totalWidth) end
        leaveBtn:SetPoint("LEFT", buttons[lastIdx], "RIGHT", cfg.button_spacing, 0)
        if not leaveBtn:IsShown() then leaveBtn:Show() end
    end

    UpdateCooldowns()
end
sfui.vehicle.UpdateActionButtons = UpdateActionButtons

frame:RegisterEvent("UNIT_ENTERED_VEHICLE")
frame:RegisterEvent("UNIT_EXITED_VEHICLE")
frame:RegisterEvent("VEHICLE_UPDATE")
frame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
frame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
frame:RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR")
frame:RegisterEvent("UPDATE_POSSESS_BAR")
frame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
frame:RegisterEvent("SPELL_UPDATE_CHARGES")
frame:RegisterEvent("SPELL_UPDATE_USABLE")

frame:SetScript("OnEvent", function(self, event, ...)
    if not SfuiDB.enableVehicle then
        self:Hide()
        if UnregisterStateDriver then UnregisterStateDriver(self, "visibility") end
        if OverrideActionBar then
            OverrideActionBar:SetAlpha(1); OverrideActionBar:EnableMouse(true)
        end
        if MainMenuBarVehicleLeaveButton then
            MainMenuBarVehicleLeaveButton:SetAlpha(1); MainMenuBarVehicleLeaveButton:EnableMouse(true)
        end
        return
    end

    if event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" or event == "SPELL_UPDATE_USABLE" then
        UpdateCooldowns()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "UPDATE_BONUS_ACTIONBAR" or event == "VEHICLE_UPDATE"
        or event == "UPDATE_VEHICLE_ACTIONBAR" or event == "UPDATE_OVERRIDE_ACTIONBAR" or event == "UPDATE_POSSESS_BAR"
        or event == "UNIT_ENTERED_VEHICLE" or (event == "PLAYER_REGEN_ENABLED" and self.needsUpdate) then
        RequestUpdate()
    end
end)

-- Suppress Blizzard
if OverrideActionBar then
    OverrideActionBar:SetAlpha(0)
    OverrideActionBar:EnableMouse(false)
end
if MainMenuBarVehicleLeaveButton then
    MainMenuBarVehicleLeaveButton:SetAlpha(0)
    MainMenuBarVehicleLeaveButton:EnableMouse(false)
end
