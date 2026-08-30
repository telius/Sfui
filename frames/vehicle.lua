local addonName, addon = ...
sfui = sfui or {}
sfui.vehicle = sfui.vehicle or {}

-- ============================================================================
-- SFUI Vehicle Bar
--
-- Displays up to 6 action buttons, health bar, power bar, and cast bar for the
-- current vehicle/override/possess bar, positioned cleanly relative to UIParent
-- using the player health & power bar coordinates.
--
-- DESIGN PRINCIPLES (combat / M+ safe & zero-allocation):
--   * Visibility driven ONLY via RegisterStateDriver — no Lua Hide/Show from
--     event callbacks (prevents ADDON_ACTION_BLOCKED on protected frames).
--   * Zero-allocation 20Hz OnUpdate ticker: uses stored button references,
--     state transition caches, and dirty checking.
--   * Secure attributes set out-of-combat / deferred via pendingUpdate.
--   * No EnableMouse() or Show()/Hide() calls on any Blizzard protected frame.
-- ============================================================================

local common = sfui.common
local g      = sfui.config
local GameTooltip = sfui.tooltip or _G.GameTooltip

-- ─── Upvalue Localization ───────────────────────────────────────────────────
local CreateFrame         = _G.CreateFrame
local UIParent            = _G.UIParent
local InCombatLockdown    = _G.InCombatLockdown
local RegisterStateDriver = _G.RegisterStateDriver
local GetTime             = _G.GetTime
local pcall               = _G.pcall
local type                = _G.type
local tostring            = _G.tostring
local math_min            = _G.math.min
local math_max            = _G.math.max
local math_floor          = _G.math.floor
local string_format       = _G.string.format
local issecretvalue       = common.issecretvalue
local PowerBarColor       = _G.PowerBarColor

local UnitHealth          = _G.UnitHealth
local UnitHealthMax       = _G.UnitHealthMax
local UnitPower           = _G.UnitPower
local UnitPowerMax        = _G.UnitPowerMax
local UnitPowerType       = _G.UnitPowerType
local UnitCastingInfo     = _G.UnitCastingInfo
local UnitChannelInfo     = _G.UnitChannelInfo
local UnitExists          = _G.UnitExists
local UnitInVehicle       = _G.UnitInVehicle
local UnitHasVehicleUI    = _G.UnitHasVehicleUI
local UnitIsUnit          = _G.UnitIsUnit

local GetActionCooldown   = _G.GetActionCooldown
local GetActionInfo       = _G.GetActionInfo
local GetBindingKey       = _G.GetBindingKey
local HasAction           = _G.HasAction

local C_ActionBar         = _G.C_ActionBar
local IsUsableAction      = C_ActionBar and C_ActionBar.IsUsableAction
local IsActionInRange     = C_ActionBar and C_ActionBar.IsActionInRange
local GetActionTexture    = C_ActionBar and C_ActionBar.GetActionTexture
local HasVehicleActionBar = C_ActionBar and C_ActionBar.HasVehicleActionBar
local GetVehicleBarIndex  = C_ActionBar and C_ActionBar.GetVehicleBarIndex
local HasOverrideActionBar = C_ActionBar and C_ActionBar.HasOverrideActionBar
local GetOverrideBarIndex = C_ActionBar and C_ActionBar.GetOverrideBarIndex
local HasTempShapeshiftActionBar = C_ActionBar and C_ActionBar.HasTempShapeshiftActionBar
local GetTempShapeshiftBarIndex = C_ActionBar and C_ActionBar.GetTempShapeshiftBarIndex
local HasBonusActionBar   = C_ActionBar and C_ActionBar.HasBonusActionBar
local GetBonusBarIndex    = C_ActionBar and C_ActionBar.GetBonusBarIndex

local C_Spell             = _G.C_Spell

-- Pre-allocated binding string lookup (prevents string allocation per refresh)
local BINDING_NAMES = {
    "ACTIONBUTTON1",
    "ACTIONBUTTON2",
    "ACTIONBUTTON3",
    "ACTIONBUTTON4",
    "ACTIONBUTTON5",
    "ACTIONBUTTON6",
}

-- ─── Constants ───────────────────────────────────────────────────────────────
local BTN_SIZE    = 54
local BTN_GAP     = 4
local MAX_BUTTONS = 6
local TICK_RATE   = 0.05
local STACK_OFFSET_Y = 69 -- 54 + 4 + 8 + 3 = 69px offset to align health bar at (hx, hy)

-- ─── Locals (zero-allocation tick & state tracking) ──────────────────────────
local _start, _duration, _enable
local _lastHealthCur, _lastHealthMax
local _lastPowerCur, _lastPowerMax, _lastPowerType
local _lastVisibleButtons = 0
local _lastUnit = "none"
local _btnUsableState = { 0, 0, 0, 0, 0, 0 }

local _casting = false
local _channeling = false
local _castStart = 0
local _castEnd = 0
local _castDuration = 0

-- ─── Secure Container ────────────────────────────────────────────────────────
local frame = CreateFrame("Frame", "SfuiVehicleBar", UIParent, "SecureHandlerStateTemplate")
frame:SetFrameStrata("MEDIUM")
frame:SetSize(MAX_BUTTONS * BTN_SIZE + (MAX_BUTTONS - 1) * BTN_GAP, BTN_SIZE)
local _hcfg = sfui.config and sfui.config.healthBar
local _hx = (_hcfg and _hcfg.pos and _hcfg.pos.x) or 0
local _hy = (_hcfg and _hcfg.pos and _hcfg.pos.y) or 300
frame:SetPoint("BOTTOM", UIParent, "BOTTOM", _hx, _hy - STACK_OFFSET_Y)
sfui.vehicle.frame = frame

-- State driver: same conditions Blizzard uses for OverrideActionBar.
-- Petbattle / skyriding stay hidden; quest vehicles, follower-dungeon
-- controllers, possess bars, bonus bar 5 all show.
local visString =
    "[petbattle] hide; " ..
    "[mounted,bonusbar:5] hide; " ..
    "[vehicleui][possessbar][overridebar][bonusbar:5] show; " ..
    "hide"
if common.get_player_class() == "DRUID" then
    visString = "[form:3,bonusbar:5] hide; [form:4,bonusbar:5] hide; " .. visString
end
RegisterStateDriver(frame, "visibility", visString)

-- ─── Buttons ─────────────────────────────────────────────────────────────────
local buttons = {}

for i = 1, MAX_BUTTONS do
    local btn = CreateFrame(
        "CheckButton",
        "SfuiVehicleBtn" .. i,
        frame,
        "SecureActionButtonTemplate"
    )
    btn:SetSize(BTN_SIZE, BTN_SIZE)
    btn:SetID(i)
    btn:SetAttribute("type",   "action")
    btn:SetAttribute("action", i) -- initial; real value set in UpdateBar()

    -- Black border: plain BACKGROUND texture (matches trackedicons CreateIconFrame)
    btn.borderBackdrop = btn:CreateTexture(nil, "BACKGROUND")
    btn.borderBackdrop:SetAllPoints()
    btn.borderBackdrop:SetColorTexture(0, 0, 0, 1)

    -- Custom square icon — same layer approach as trackedicons.lua
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon:SetPoint("TOPLEFT",     btn, "TOPLEFT",      2, -2)
    btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2,  2)

    -- Cooldown (anchored to inset icon)
    local cd = CreateFrame("Cooldown", "SfuiVehicleBtn" .. i .. "Cooldown", btn, "CooldownFrameTemplate")
    cd:SetPoint("TOPLEFT",     btn.icon, "TOPLEFT",     0, 0)
    cd:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 0, 0)
    cd:SetDrawEdge(true)
    cd:SetHideCountdownNumbers(false)
    cd:SetFrameLevel(btn:GetFrameLevel() + 2)
    btn.cooldown = cd

    -- Keybind label
    btn.kb = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.kb:SetPoint("TOPRIGHT", -2, -2)

    -- Highlight & Pushed textures (matching trackedicons style)
    btn.HighlightTexture = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.HighlightTexture:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    btn.HighlightTexture:SetAllPoints()
    btn:SetHighlightTexture(btn.HighlightTexture)

    btn.PushedTexture = btn:CreateTexture(nil, "OVERLAY")
    btn.PushedTexture:SetTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    btn.PushedTexture:SetAllPoints()
    btn:SetPushedTexture(btn.PushedTexture)

    -- Position
    if i == 1 then
        btn:SetPoint("LEFT", frame, "LEFT", 0, 0)
    else
        btn:SetPoint("LEFT", buttons[i - 1], "RIGHT", BTN_GAP, 0)
    end

    -- Pre-allocated Masque sub-elements table (zero allocation on refresh)
    btn.masqueSubElements = { Icon = btn.icon, Cooldown = cd }
    common.sync_masque(btn, btn.masqueSubElements)
    if btn._isMasqued and btn.borderBackdrop then btn.borderBackdrop:Hide() end

    btn:SetScript("OnEnter", function(self)
        local action = self:GetAttribute("action")
        if GameTooltip and action and HasAction(action) then
            pcall(function()
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetAction(action)
                GameTooltip:Show()
            end)
        end
    end)
    btn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    buttons[i] = btn
end
sfui.vehicle.buttons = buttons

-- ─── Vehicle Unit Resolver ───────────────────────────────────────────────────
local function GetVehicleUnit()
    if UnitExists("vehicle") then
        return "vehicle"
    elseif UnitExists("pet") and (UnitInVehicle("player") or UnitHasVehicleUI("player") or (HasOverrideActionBar and HasOverrideActionBar()) or (HasVehicleActionBar and HasVehicleActionBar())) then
        return "pet"
    elseif UnitExists("pet") and not UnitIsUnit("pet", "player") then
        return "pet"
    end
    return "player"
end

-- ─── Texture Helper ─────────────────────────────────────────────────────────
local function GetBarTexture()
    local textureName = SfuiDB and SfuiDB.barTexture
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    local texturePath
    if LSM and textureName then
        texturePath = LSM:Fetch("statusbar", textureName)
    end
    if not texturePath or texturePath == "" then
        texturePath = (sfui.config and sfui.config.barTexture) or "Interface\\Buttons\\WHITE8X8"
    end
    return texturePath
end

-- ─── Vehicle Health Bar ──────────────────────────────────────────────────────
local healthBackdrop = CreateFrame("Frame", "SfuiVehicleHealthBackdrop", frame, "BackdropTemplate")
healthBackdrop:SetHeight(16)
healthBackdrop:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 15)
healthBackdrop:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 15)
healthBackdrop:SetBackdrop({
    bgFile = (sfui.config and sfui.config.textures and sfui.config.textures.white) or "Interface\\Buttons\\WHITE8X8",
    tile = true,
    tileSize = 32,
})
healthBackdrop:Show()

local healthStatusBar = CreateFrame("StatusBar", "SfuiVehicleHealthBar", healthBackdrop)
healthStatusBar:SetPoint("TOPLEFT", healthBackdrop, "TOPLEFT", 1, -1)
healthStatusBar:SetPoint("BOTTOMRIGHT", healthBackdrop, "BOTTOMRIGHT", -1, 1)
healthStatusBar:SetStatusBarTexture(GetBarTexture())

local function UpdateVehicleHealth(force)
    if not frame:IsShown() then return end
    local unit = GetVehicleUnit()
    _lastUnit = unit
    local cur = (UnitExists(unit) and UnitHealth(unit)) or UnitHealth("player") or 100
    local maxVal = (UnitExists(unit) and UnitHealthMax(unit)) or UnitHealthMax("player") or 100

    if issecretvalue(cur) or issecretvalue(maxVal) or not maxVal or maxVal <= 0 then
        cur = 100
        maxVal = 100
    end

    if not force and cur == _lastHealthCur and maxVal == _lastHealthMax then
        return
    end
    _lastHealthCur = cur
    _lastHealthMax = maxVal

    healthBackdrop:Show()
    healthStatusBar:SetMinMaxValues(0, maxVal)
    healthStatusBar:SetValue(cur)

    local fgColor = SfuiDB and SfuiDB.healthBarColor or (sfui.config and sfui.config.healthBar and sfui.config.healthBar.color) or { 0, 0.8, 0.067, 1 }
    if SfuiDB and SfuiDB.useSpecColor and common.get_spec_color then
        fgColor = common.get_spec_color() or fgColor
    end
    healthStatusBar:SetStatusBarColor(fgColor[1], fgColor[2], fgColor[3], fgColor[4] or 1)

    local bgColor = SfuiDB and SfuiDB.healthBarBackdropColor or (sfui.config and sfui.config.healthBar and sfui.config.healthBar.backdrop and sfui.config.healthBar.backdrop.color) or { 0, 0, 0, 0.7 }
    healthBackdrop:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.7)
end

-- ─── Vehicle Power Bar ───────────────────────────────────────────────────────
local powerBackdrop = CreateFrame("Frame", "SfuiVehiclePowerBackdrop", frame, "BackdropTemplate")
powerBackdrop:SetHeight(8)
powerBackdrop:SetPoint("TOPLEFT", healthBackdrop, "BOTTOMLEFT", 15, -3)
powerBackdrop:SetPoint("TOPRIGHT", healthBackdrop, "BOTTOMRIGHT", -15, -3)
powerBackdrop:SetBackdrop({
    bgFile = (sfui.config and sfui.config.textures and sfui.config.textures.white) or "Interface\\Buttons\\WHITE8X8",
    tile = true,
    tileSize = 32,
})
powerBackdrop:Hide()

local powerStatusBar = CreateFrame("StatusBar", "SfuiVehiclePowerBar", powerBackdrop)
powerStatusBar:SetPoint("TOPLEFT", powerBackdrop, "TOPLEFT", 1, -1)
powerStatusBar:SetPoint("BOTTOMRIGHT", powerBackdrop, "BOTTOMRIGHT", -1, 1)
powerStatusBar:SetStatusBarTexture(GetBarTexture())

local function UpdateVehiclePower(force)
    if not frame:IsShown() then return end
    local unit = GetVehicleUnit()
    local powerType, powerToken = UnitPowerType(unit)
    local cur = (UnitExists(unit) and UnitPower(unit, powerType)) or UnitPower("player") or 0
    local maxVal = (UnitExists(unit) and UnitPowerMax(unit, powerType)) or UnitPowerMax("player") or 0

    if issecretvalue(cur) or issecretvalue(maxVal) or not maxVal or maxVal <= 0 then
        powerBackdrop:Hide()
        _lastPowerCur, _lastPowerMax, _lastPowerType = nil, nil, nil
        return
    end

    if not force and cur == _lastPowerCur and maxVal == _lastPowerMax and powerType == _lastPowerType then
        return
    end
    _lastPowerCur = cur
    _lastPowerMax = maxVal
    _lastPowerType = powerType

    powerBackdrop:Show()
    powerStatusBar:SetMinMaxValues(0, maxVal)
    powerStatusBar:SetValue(cur)

    local pColor = nil
    if powerToken and PowerBarColor and PowerBarColor[powerToken] then
        pColor = PowerBarColor[powerToken]
    end
    if not pColor and common.get_resource_color then
        pColor = common.get_resource_color(powerType)
    end
    if not pColor then
        pColor = { r = 0, g = 0.5, b = 1 }
    end

    powerStatusBar:SetStatusBarColor(pColor.r or pColor[1], pColor.g or pColor[2], pColor.b or pColor[3], pColor.a or pColor[4] or 1)

    local bgColor = SfuiDB and SfuiDB.healthBarBackdropColor or (sfui.config and sfui.config.healthBar and sfui.config.healthBar.backdrop and sfui.config.healthBar.backdrop.color) or { 0, 0, 0, 0.7 }
    powerBackdrop:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.7)
end

-- ─── Vehicle Cast Bar ────────────────────────────────────────────────────────
local castBackdrop = CreateFrame("Frame", "SfuiVehicleCastBackdrop", frame, "BackdropTemplate")
castBackdrop:SetHeight(16)
castBackdrop:SetPoint("BOTTOMLEFT", healthBackdrop, "TOPLEFT", 0, 4)
castBackdrop:SetPoint("BOTTOMRIGHT", healthBackdrop, "TOPRIGHT", 0, 4)
castBackdrop:SetBackdrop({
    bgFile = (sfui.config and sfui.config.textures and sfui.config.textures.white) or "Interface\\Buttons\\WHITE8X8",
    tile = true,
    tileSize = 32,
})
castBackdrop:Hide()

local castStatusBar = CreateFrame("StatusBar", "SfuiVehicleCastBar", castBackdrop)
castStatusBar:SetPoint("TOPLEFT", castBackdrop, "TOPLEFT", 1, -1)
castStatusBar:SetPoint("BOTTOMRIGHT", castBackdrop, "BOTTOMRIGHT", -1, 1)
castStatusBar:SetStatusBarTexture(GetBarTexture())

local castIconFrame = CreateFrame("Frame", nil, castBackdrop, "BackdropTemplate")
castIconFrame:SetSize(16, 16)
castIconFrame:SetPoint("RIGHT", castBackdrop, "LEFT", -4, 0)
castIconFrame:SetBackdrop({
    bgFile = (sfui.config and sfui.config.textures and sfui.config.textures.white) or "Interface\\Buttons\\WHITE8X8",
    tile = true,
    tileSize = 32,
})
castIconFrame:SetBackdropColor(0, 0, 0, 1)

local castIcon = castIconFrame:CreateTexture(nil, "ARTWORK")
castIcon:SetPoint("TOPLEFT", 1, -1)
castIcon:SetPoint("BOTTOMRIGHT", -1, 1)
castIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

local castNameText = castStatusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
castNameText:SetPoint("LEFT", 4, 0)
castNameText:SetPoint("RIGHT", castStatusBar, "RIGHT", -40, 0)
castNameText:SetJustifyH("LEFT")

local castTimerText = castStatusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
castTimerText:SetPoint("RIGHT", -4, 0)
castTimerText:SetJustifyH("RIGHT")

local castSpark = castStatusBar:CreateTexture(nil, "OVERLAY")
castSpark:SetTexture("Interface/CastingBar/UI-CastingBar-Spark")
castSpark:SetBlendMode("ADD")
castSpark:SetSize(16, 32)
castSpark:Hide()

local function StopCastBar()
    _casting = false
    _channeling = false
    castBackdrop:Hide()
    castSpark:Hide()
end

local function StartCast(unit)
    if not frame:IsShown() then return end
    local vUnit = GetVehicleUnit()
    if unit and unit ~= vUnit and unit ~= "vehicle" and unit ~= "pet" and unit ~= "player" then
        return
    end
    unit = vUnit

    local name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo(unit)
    if name and startTimeMS and endTimeMS then
        _casting = true
        _channeling = false
        _castStart = startTimeMS / 1000
        _castEnd = endTimeMS / 1000
        _castDuration = _castEnd - _castStart
        if _castDuration <= 0 then _castDuration = 0.001 end

        castStatusBar:SetMinMaxValues(0, _castDuration)
        castStatusBar:SetValue(0)
        castNameText:SetText(name or "")

        local cbColor = (sfui.config and sfui.config.castBar and sfui.config.castBar.color) or { 1, 1, 1 }
        castStatusBar:SetStatusBarColor(cbColor[1], cbColor[2], cbColor[3], 1)

        local bgColor = (sfui.config and sfui.config.castBar and sfui.config.castBar.backdrop and sfui.config.castBar.backdrop.color) or { 0, 0, 0, 0.7 }
        castBackdrop:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.7)

        if texture then
            castIcon:SetTexture(texture)
            castIconFrame:Show()
        else
            castIconFrame:Hide()
        end

        castSpark:Show()
        castBackdrop:Show()
        return
    end

    local cName, cText, cTexture, cStartMS, cEndMS = UnitChannelInfo(unit)
    if cName and cStartMS and cEndMS then
        _casting = false
        _channeling = true
        _castStart = cStartMS / 1000
        _castEnd = cEndMS / 1000
        _castDuration = _castEnd - _castStart
        if _castDuration <= 0 then _castDuration = 0.001 end

        castStatusBar:SetMinMaxValues(0, _castDuration)
        castStatusBar:SetValue(_castDuration)
        castNameText:SetText(cName or "")

        local chColor = (sfui.config and sfui.config.castBar and sfui.config.castBar.channelColor) or { 0, 1, 0 }
        castStatusBar:SetStatusBarColor(chColor[1], chColor[2], chColor[3], 1)

        local bgColor = (sfui.config and sfui.config.castBar and sfui.config.castBar.backdrop and sfui.config.castBar.backdrop.color) or { 0, 0, 0, 0.7 }
        castBackdrop:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.7)

        if cTexture then
            castIcon:SetTexture(cTexture)
            castIconFrame:Show()
        else
            castIconFrame:Hide()
        end

        castSpark:Show()
        castBackdrop:Show()
        return
    end

    StopCastBar()
end

local function UpdateCastProgress()
    if not (_casting or _channeling) then return end
    local now = GetTime()
    if _casting then
        if now >= _castEnd then
            StopCastBar()
        else
            local elapsed = now - _castStart
            castStatusBar:SetValue(elapsed)
            local remaining = math_max(0, _castEnd - now)
            castTimerText:SetText(string_format("%.1f", remaining))
            if _castDuration > 0 then
                local w = castStatusBar:GetWidth()
                local prog = math_min(1, math_max(0, elapsed / _castDuration))
                castSpark:ClearAllPoints()
                castSpark:SetPoint("CENTER", castStatusBar, "LEFT", w * prog, 0)
            end
        end
    elseif _channeling then
        if now >= _castEnd then
            StopCastBar()
        else
            local remaining = math_max(0, _castEnd - now)
            castStatusBar:SetValue(remaining)
            castTimerText:SetText(string_format("%.1f", remaining))
            if _castDuration > 0 then
                local w = castStatusBar:GetWidth()
                local prog = math_min(1, math_max(0, remaining / _castDuration))
                castSpark:ClearAllPoints()
                castSpark:SetPoint("CENTER", castStatusBar, "LEFT", w * prog, 0)
            end
        end
    end
end

function sfui.vehicle.set_bar_texture(texturePath)
    if healthStatusBar then healthStatusBar:SetStatusBarTexture(texturePath) end
    if powerStatusBar then powerStatusBar:SetStatusBarTexture(texturePath) end
    if castStatusBar then castStatusBar:SetStatusBarTexture(texturePath) end
end

-- ─── Anchor ──────────────────────────────────────────────────────────────────
-- The entire stack is positioned matching the player health bar position (hx, hy).
-- The health bar sits at (hx, hy), the power bar directly underneath, and the buttons 69px underneath.
local function UpdateAnchor()
    frame:ClearAllPoints()
    local hcfg = (g and g.healthBar) or (sfui.config and sfui.config.healthBar)
    local hx = (SfuiDB and SfuiDB.healthBarX) or (hcfg and hcfg.pos and hcfg.pos.x) or 0
    local hy = (SfuiDB and SfuiDB.healthBarY) or (hcfg and hcfg.pos and hcfg.pos.y) or 300
    frame:SetPoint("BOTTOM", UIParent, "BOTTOM", hx, hy - STACK_OFFSET_Y)
end

-- ─── Bar-page resolver ───────────────────────────────────────────────────────
local function GetResolvedVehicleBarIndex()
    if HasVehicleActionBar and HasVehicleActionBar()        then return GetVehicleBarIndex()          end
    if HasOverrideActionBar and HasOverrideActionBar()       then return GetOverrideBarIndex()         end
    if HasTempShapeshiftActionBar and HasTempShapeshiftActionBar() then return GetTempShapeshiftBarIndex()   end
    if HasBonusActionBar and HasBonusActionBar()          then return GetBonusBarIndex()            end
    return nil
end

-- ─── UpdateBar — sets secure attributes (must be out-of-combat) ──────────────
local pendingUpdate = false

local function UpdateBar()
    if InCombatLockdown() then
        pendingUpdate = true
        return
    end
    pendingUpdate = false

    local barIndex = GetResolvedVehicleBarIndex()
    if not barIndex or barIndex == 0 then
        for i = 1, MAX_BUTTONS do buttons[i]:SetAlpha(0) end
        healthBackdrop:Hide()
        powerBackdrop:Hide()
        StopCastBar()
        _lastVisibleButtons = 0
        return
    end

    local lastVisible = 0
    for i = 1, MAX_BUTTONS do
        local btn = buttons[i]
        local actionID = (barIndex - 1) * 12 + i
        btn:SetAttribute("action", actionID)

        local tex = GetActionTexture and GetActionTexture(actionID)
        if tex then
            btn.icon:SetTexture(tex)
            btn:SetAlpha(1)
            lastVisible = i
        else
            btn:SetAlpha(0)
        end

        -- Keybind label (centralized formatter)
        local keyText = sfui.keybinds and sfui.keybinds.get_action_key and sfui.keybinds.get_action_key(BINDING_NAMES[i])
            or (GetBindingKey and GetBindingKey(BINDING_NAMES[i])) or ""
        btn.kb:SetText(keyText)

        -- Masque re-sync
        common.sync_masque(btn, btn.masqueSubElements)
        if btn._isMasqued and btn.borderBackdrop then btn.borderBackdrop:Hide() end
    end

    _lastVisibleButtons = lastVisible
    -- Resize frame to fit only visible buttons
    local w = math_max(1, lastVisible * BTN_SIZE + math_max(0, lastVisible - 1) * BTN_GAP)
    frame:SetSize(w, BTN_SIZE)
    UpdateAnchor()

    UpdateVehicleHealth(true)
    UpdateVehiclePower(true)
    StartCast(GetVehicleUnit())
end
sfui.vehicle.UpdateBar = UpdateBar

-- ─── UpdateCooldowns — safe every tick, handles 12.1 secret values ───────────
local function UpdateCooldowns()
    if not frame:IsShown() then return end
    for i = 1, MAX_BUTTONS do
        local btn = buttons[i]
        if btn:GetAlpha() > 0 then
            local actionID = btn:GetAttribute("action")
            if actionID then
                local cd = btn.cooldown
                if cd then
                    _start, _duration, _enable = GetActionCooldown(actionID)
                    local isSecret = issecretvalue(_start) or issecretvalue(_duration)
                    if isSecret then
                        local ok = pcall(cd.SetCooldown, cd, _start, _duration)
                        if not ok then
                            local atype, spellID = GetActionInfo(actionID)
                            if atype == "spell" and spellID
                                and cd.SetCooldownFromDurationObject
                                and C_Spell and C_Spell.GetSpellCooldownDuration then
                                local ok2, obj = pcall(C_Spell.GetSpellCooldownDuration, spellID, true)
                                if ok2 and obj then
                                    cd:SetCooldownFromDurationObject(obj)
                                else
                                    cd:Clear()
                                end
                            else
                                cd:Clear()
                            end
                        end
                    else
                        if not _enable or _enable == 0 or not _duration or _duration == 0 then
                            cd:Clear()
                        else
                            cd:SetCooldown(_start, _duration)
                        end
                    end
                end
            end
        end
    end
end

-- ─── UpdateUsable — icon tinting for usability / range with state caching ───
local function UpdateUsable()
    if not frame:IsShown() then return end
    for i = 1, MAX_BUTTONS do
        local btn = buttons[i]
        if btn:GetAlpha() > 0 then
            local actionID = btn:GetAttribute("action")
            if actionID then
                local usable, noMana = IsUsableAction and IsUsableAction(actionID)
                local inRange = IsActionInRange and IsActionInRange(actionID)
                local state = 1
                if issecretvalue(usable) then
                    state = 1
                elseif not usable then
                    state = noMana and 2 or 3
                elseif inRange == false then
                    state = 4
                else
                    state = 1
                end

                if _btnUsableState[i] ~= state then
                    _btnUsableState[i] = state
                    if state == 1 then
                        btn.icon:SetVertexColor(1, 1, 1)
                    elseif state == 2 then
                        btn.icon:SetVertexColor(0.4, 0.4, 1.0)
                    elseif state == 3 then
                        btn.icon:SetVertexColor(0.4, 0.4, 0.4)
                    elseif state == 4 then
                        btn.icon:SetVertexColor(0.8, 0.2, 0.2)
                    end
                end
            end
        end
    end
end

-- ─── OnUpdate Ticker (non-secure) ────────────────────────────────────────────
local ticker = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    UpdateCastProgress()
    ticker = ticker + elapsed
    if ticker >= TICK_RATE then
        ticker = 0
        UpdateCooldowns()
        UpdateUsable()
        UpdateVehicleHealth()
        UpdateVehiclePower()
    end
end)

-- ─── OnShow / OnHide ─────────────────────────────────────────────────────────
frame:SetScript("OnShow", function()
    UpdateBar()
end)
frame:SetScript("OnHide", function()
    StopCastBar()
end)

-- ─── Events (via sfui.events — global + unit-filtered) ───────────────────────
-- Global lifecycle events
local function on_vehicle_global(event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingUpdate then UpdateBar() end
    else
        UpdateBar()
    end
end
sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD",    on_vehicle_global)
sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED",     on_vehicle_global)
sfui.events.RegisterEvent("UNIT_ENTERED_VEHICLE",     on_vehicle_global)
sfui.events.RegisterEvent("UNIT_EXITED_VEHICLE",      on_vehicle_global)
sfui.events.RegisterEvent("VEHICLE_UPDATE",           on_vehicle_global)
sfui.events.RegisterEvent("UPDATE_VEHICLE_ACTIONBAR", on_vehicle_global)
sfui.events.RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR",on_vehicle_global)
sfui.events.RegisterEvent("UPDATE_POSSESS_BAR",       on_vehicle_global)
sfui.events.RegisterEvent("UPDATE_BONUS_ACTIONBAR",   on_vehicle_global)
sfui.events.RegisterEvent("ACTIONBAR_UPDATE_STATE",   on_vehicle_global)
sfui.events.RegisterEvent("UPDATE_BINDINGS",          on_vehicle_global)

-- Unit-filtered health/power: only fire for player or vehicle unit, never for
-- Unit-filtered health/power: only fire for player or vehicle unit, never for
-- every friendly unit in a raid.
local function on_unit_health(_, unit)
    if not frame:IsShown() then return end
    local vUnit = GetVehicleUnit()
    if unit == "player" or unit == "vehicle" or unit == "pet" or unit == vUnit then
        UpdateVehicleHealth()
    end
end
local function on_unit_power(_, unit)
    if not frame:IsShown() then return end
    local vUnit = GetVehicleUnit()
    if unit == "player" or unit == "vehicle" or unit == "pet" or unit == vUnit then
        UpdateVehiclePower()
    end
end
sfui.events.RegisterUnitEvent("UNIT_HEALTH",       "player",  on_unit_health)
sfui.events.RegisterUnitEvent("UNIT_HEALTH",       "vehicle", on_unit_health)
sfui.events.RegisterUnitEvent("UNIT_MAXHEALTH",    "player",  on_unit_health)
sfui.events.RegisterUnitEvent("UNIT_MAXHEALTH",    "vehicle", on_unit_health)
sfui.events.RegisterUnitEvent("UNIT_POWER_UPDATE", "player",  on_unit_power)
sfui.events.RegisterUnitEvent("UNIT_POWER_UPDATE", "vehicle", on_unit_power)
sfui.events.RegisterUnitEvent("UNIT_MAXPOWER",     "player",  on_unit_power)
sfui.events.RegisterUnitEvent("UNIT_MAXPOWER",     "vehicle", on_unit_power)
sfui.events.RegisterUnitEvent("UNIT_DISPLAYPOWER", "player",  on_unit_power)
sfui.events.RegisterUnitEvent("UNIT_DISPLAYPOWER", "vehicle", on_unit_power)

-- Unit-filtered spellcast events
local CAST_STOP_EVENTS = {
    UNIT_SPELLCAST_STOP        = true,
    UNIT_SPELLCAST_FAILED      = true,
    UNIT_SPELLCAST_INTERRUPTED = true,
    UNIT_SPELLCAST_CHANNEL_STOP= true,
    UNIT_SPELLCAST_EMPOWER_STOP= true,
}
local function on_unit_cast(event, unit)
    if not frame:IsShown() then return end
    local vUnit = GetVehicleUnit()
    if unit == "player" or unit == "vehicle" or unit == "pet" or unit == vUnit then
        if CAST_STOP_EVENTS[event] then
            StopCastBar()
        else
            StartCast(unit)
        end
    end
end
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_START",          "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_START",          "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_STOP",           "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_STOP",           "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_FAILED",         "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_FAILED",         "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED",    "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED",    "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_DELAYED",        "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_DELAYED",        "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START",  "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START",  "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP",   "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP",   "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START",  "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START",  "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE", "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE", "vehicle", on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP",   "player",  on_unit_cast)
sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP",   "vehicle", on_unit_cast)

function sfui.vehicle_debug_info()
    return {
        frameCreated = frame ~= nil,
        frameShown = frame and frame:IsShown() or false,
        healthShown = healthBackdrop and healthBackdrop:IsShown() or false,
        powerShown = powerBackdrop and powerBackdrop:IsShown() or false,
        castShown = castBackdrop and castBackdrop:IsShown() or false,
        visibleButtons = _lastVisibleButtons or 0,
        currentUnit = _lastUnit or "none",
    }
end
