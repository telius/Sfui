local addonName, addon = ...
sfui.vehicle = {}

-- ============================================================================
-- SFUI Vehicle Bar
--
-- Displays up to 6 action buttons for the current vehicle/override/possess bar,
-- positioned cleanly relative to UIParent using the exact screen coordinates
-- of SfuiIconPanel_1 / player health & power bars.
--
-- DESIGN PRINCIPLES (combat / M+ safe & zero-allocation):
--   * Visibility driven ONLY via RegisterStateDriver — no Lua Hide/Show from
--     event callbacks (prevents ADDON_ACTION_BLOCKED on protected frames).
--   * Zero-allocation 20Hz OnUpdate ticker: uses stored button references
--     (no string concatenations or table instantiations in hot path).
--   * Secure attributes set out-of-combat / deferred via pendingUpdate.
--   * No EnableMouse() or Show()/Hide() calls on any Blizzard protected frame.
-- ============================================================================

local common = sfui.common
local g      = sfui.config

-- Upvalue localization for hot path performance
local GetActionCooldown     = GetActionCooldown
local GetActionInfo         = GetActionInfo
local GetBindingKey         = GetBindingKey
local HasAction             = HasAction
local IsUsableAction        = C_ActionBar and C_ActionBar.IsUsableAction
local IsActionInRange       = C_ActionBar and C_ActionBar.IsActionInRange
local GetActionTexture      = C_ActionBar and C_ActionBar.GetActionTexture
local issecretvalue         = common.issecretvalue

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
local BTN_SIZE    = 54   -- 1.5× the trackedicons default of 36
local BTN_GAP     = 4
local MAX_BUTTONS = 6   -- OverrideActionBar uses SpellButton1..6
local TICK_RATE   = 0.05

-- ─── Locals (zero-allocation tick) ───────────────────────────────────────────
local _start, _duration, _enable

-- ─── Secure container ────────────────────────────────────────────────────────
local frame = CreateFrame("Frame", "SfuiVehicleBar", UIParent, "SecureHandlerStateTemplate")
frame:SetFrameStrata("MEDIUM")
frame:SetSize(MAX_BUTTONS * BTN_SIZE + (MAX_BUTTONS - 1) * BTN_GAP, BTN_SIZE)
frame:SetPoint("BOTTOM", UIParent, "CENTER", 0, -200) -- overwritten by UpdateAnchor
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
    sfui.common.sync_masque(btn, btn.masqueSubElements)
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

-- ─── Anchor ──────────────────────────────────────────────────────────────────
-- Calculates the exact screen position of SfuiIconPanel_1 (or Power/Health bar)
-- and anchors SfuiVehicleBar directly to UIParent. Anchoring directly to UIParent
-- with absolute coordinates prevents any layout dependency or taint issues.
local function UpdateAnchor()
    frame:ClearAllPoints()

    -- Find reference frame to position beneath
    local target = nil
    local centerPanel = _G["SfuiIconPanel_1"]
    if centerPanel and centerPanel:IsShown() then
        target = centerPanel
    else
        local powerBar = _G["sfui_bar-1_Backdrop"] or _G["sfui_bar_minus_1_Backdrop"]
        if powerBar and powerBar:IsShown() then
            target = powerBar
        else
            local hpBar = _G["sfui_bar0_Backdrop"]
            if hpBar and hpBar:IsShown() then
                target = hpBar
            end
        end
    end

    if target then
        local cx, _ = target:GetCenter()
        local b     = target:GetBottom()
        if cx and b then
            local scale = (target:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
            cx = cx * scale
            b  = b  * scale
            frame:SetPoint("TOP", UIParent, "BOTTOMLEFT", cx, b - 4)
            return
        end
    end

    -- Fallback: center of screen above bottom action bars
    frame:SetPoint("BOTTOM", UIParent, "CENTER", 0, -180)
end

-- ─── Bar-page resolver ───────────────────────────────────────────────────────
local function GetVehicleBarIndex()
    if C_ActionBar.HasVehicleActionBar()        then return C_ActionBar.GetVehicleBarIndex()          end
    if C_ActionBar.HasOverrideActionBar()       then return C_ActionBar.GetOverrideBarIndex()          end
    if C_ActionBar.HasTempShapeshiftActionBar() then return C_ActionBar.GetTempShapeshiftBarIndex()    end
    if C_ActionBar.HasBonusActionBar()          then return C_ActionBar.GetBonusBarIndex()             end
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

    local barIndex = GetVehicleBarIndex()
    if not barIndex or barIndex == 0 then
        for i = 1, MAX_BUTTONS do buttons[i]:SetAlpha(0) end
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

        -- Keybind label
        local key = GetBindingKey(BINDING_NAMES[i])
        if key then
            key = key:gsub("SHIFT%-","S-"):gsub("CTRL%-","C-"):gsub("ALT%-","A-"):gsub("NUMPAD","N")
        end
        btn.kb:SetText(key or "")

        -- Masque re-sync
        sfui.common.sync_masque(btn, btn.masqueSubElements)
        if btn._isMasqued and btn.borderBackdrop then btn.borderBackdrop:Hide() end
    end

    -- Resize frame to fit only visible buttons
    local w = math.max(1, lastVisible * BTN_SIZE + math.max(0, lastVisible - 1) * BTN_GAP)
    frame:SetSize(w, BTN_SIZE)
    UpdateAnchor()
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

-- ─── UpdateUsable — icon tinting for usability / range ───────────────────────
local function UpdateUsable()
    if not frame:IsShown() then return end
    for i = 1, MAX_BUTTONS do
        local btn = buttons[i]
        if btn:GetAlpha() > 0 then
            local actionID = btn:GetAttribute("action")
            if actionID then
                local usable, noMana = IsUsableAction and IsUsableAction(actionID)
                local inRange = IsActionInRange and IsActionInRange(actionID)
                if issecretvalue(usable) then
                    btn.icon:SetVertexColor(1, 1, 1)
                elseif not usable then
                    if noMana then
                        btn.icon:SetVertexColor(0.4, 0.4, 1.0) -- out of resource
                    else
                        btn.icon:SetVertexColor(0.4, 0.4, 0.4) -- unusable
                    end
                elseif inRange == false then
                    btn.icon:SetVertexColor(0.8, 0.2, 0.2)     -- out of range
                else
                    btn.icon:SetVertexColor(1, 1, 1)
                end
            end
        end
    end
end

-- ─── OnUpdate ticker (non-secure) ────────────────────────────────────────────
local ticker = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    ticker = ticker + elapsed
    if ticker >= TICK_RATE then
        ticker = 0
        UpdateCooldowns()
        UpdateUsable()
    end
end)

-- ─── OnShow — refresh everything when state driver shows us ──────────────────
frame:SetScript("OnShow", function()
    UpdateBar()
end)

-- ─── Events ──────────────────────────────────────────────────────────────────
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("UNIT_ENTERED_VEHICLE")
frame:RegisterEvent("UNIT_EXITED_VEHICLE")
frame:RegisterEvent("VEHICLE_UPDATE")
frame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
frame:RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR")
frame:RegisterEvent("UPDATE_POSSESS_BAR")
frame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
frame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
frame:RegisterEvent("UPDATE_BINDINGS")

frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingUpdate then UpdateBar() end
    else
        UpdateBar()
    end
end)

function sfui.vehicle_debug_info()
    return {
        frameCreated = frame ~= nil,
        frameShown = frame and frame:IsShown() or false,
    }
end
