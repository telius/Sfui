-- frames/portals.lua
-- Portal panel. Data lives in portals_db.lua.
-- Clicking uses Scotty's InsecureActionButtonTemplate overlay pattern:
--   one shared action button moves onto each icon/row on hover.
local cfg = sfui.config
local addonName, addon  = ...
sfui                    = sfui or {}
sfui.portals            = {}

-- ========================
-- Localization (upvalue globals for faster access)
-- ========================
local math_floor        = math.floor
local str_format        = string.format
local CreateFrame       = _G.CreateFrame
local UIParent          = _G.UIParent
local C_Spell           = _G.C_Spell
local C_SpellBook       = _G.C_SpellBook
local C_Container       = _G.C_Container
local C_ToyBox          = _G.C_ToyBox
local GetProfessions    = _G.GetProfessions
local GetProfessionInfo = _G.GetProfessionInfo
local PlayerHasToy      = _G.PlayerHasToy
local GameTooltip       = sfui.tooltip or _G.GameTooltip
local GetTime           = _G.GetTime
local tinsert           = _G.tinsert
local select            = _G.select
local GetInstanceInfo   = _G.GetInstanceInfo
local C_ChallengeMode   = _G.C_ChallengeMode
local C_Secrets         = _G.C_Secrets
local C_MythicPlus      = _G.C_MythicPlus
-- ========================
-- Shared Backdrop Tables
-- Reuse the same table to avoid per-call allocation.
-- ========================
local BACKDROP_ICON     = {
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets   = { left = 0, right = 0, top = 0, bottom = 0 },
}
local BACKDROP_ROW      = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets   = { left = 0, right = 0, top = 0, bottom = 0 },
}
local BACKDROP_MENU     = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}
local C_Item            = _G.C_Item
-- ========================
-- Layout
-- ========================
local ICON_SIZE         = 48
local ICON_SPACING_X    = 4
local ICON_SPACING_Y    = 18 -- More padding for the text label
local ICONS_PER_ROW     = 4
local FRAME_WIDTH       = ICONS_PER_ROW * (ICON_SIZE + ICON_SPACING_X) + ICON_SPACING_X + 10 -- ~222

-- ========================
-- Shared overlay action button (Scotty's InsecureActionButtonTemplate pattern).
-- On hover, this button is moved on top of the icon/row and its attributes set.
-- The player clicks this button, which fires the spell/toy via Blizzard's input system.
-- This is the only reliable taint-free casting method from an addon frame.
-- ========================
local actionBtn         = CreateFrame("Button", "SfuiPortalsActionBtn", UIParent, "InsecureActionButtonTemplate")
actionBtn:RegisterForClicks("AnyDown", "AnyUp")
actionBtn:SetPropagateMouseMotion(true)
actionBtn:SetFrameStrata("TOOLTIP")
actionBtn:Hide()

-- ========================
-- Helpers
-- ========================
local portalFrame    = nil
local openLegacyMenu = nil -- track currently-open legacy dropdown menu

local function sort_portals_by_name(a, b)
    return (a.name or ""):lower() < (b.name or ""):lower()
end

local function is_engineer()
    local prof1, prof2 = GetProfessions()
    local function check(slot)
        if not slot then return false end
        return select(7, GetProfessionInfo(slot)) == 202
    end
    return check(prof1) or check(prof2)
end

local function player_has_spell(spellID)
    if not spellID then return false end
    if C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook and C_SpellBook.IsSpellKnownOrInSpellBook(spellID) then
        return true
    end
    if _G.IsPlayerSpell and _G.IsPlayerSpell(spellID) then
        return true
    end
    if C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(spellID, Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 1) then
        return true
    end
    if C_SpellBook and C_SpellBook.IsSpellInSpellBook and C_SpellBook.IsSpellInSpellBook(spellID) then
        return true
    end
    if C_Spell and C_Spell.IsSpellKnown and C_Spell.IsSpellKnown(spellID) then
        return true
    end
    if C_Spell and C_Spell.IsSpellKnownOrOverridesKnown and C_Spell.IsSpellKnownOrOverridesKnown(spellID) then
        return true
    end
    return false
end

-- Engineering toy visibility: just check toybox ownership.
local function toy_is_accessible(toyID)
    return PlayerHasToy(toyID)
end

local function is_restricted_content()
    -- 12.0.5+: use the engine's own secrecy predicate, which covers BG, Arena,
    -- M+ active runs, AND raid encounter phases in one authoritative call.
    if C_Secrets and C_Secrets.ShouldCooldownsBeSecret then
        return C_Secrets.ShouldCooldownsBeSecret()
    end
    -- Fallback for pre-12.0.5 builds: check instance type + M+ directly.
    local _, instanceType = GetInstanceInfo()
    if instanceType == "pvp" or instanceType == "arena" then return true end
    if C_MythicPlus and C_MythicPlus.IsMythicPlusActive and C_MythicPlus.IsMythicPlusActive() then return true end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then return true end
    return false
end

local function spell_cd_remaining(spellID)
    if not spellID then return 0 end
    if is_restricted_content() then return 0 end

    -- 12.0.5+: LuaDurationObject API returns a plain number from GetRemainingDuration()
    -- that is never a secret value — sidesteps field-level taint completely.
    if C_Spell.GetSpellCooldownDuration then
        local durObj = C_Spell.GetSpellCooldownDuration(spellID, true) -- ignoreGCD = true
        if durObj and not durObj:IsZero() and not durObj:HasSecretValues() then
            return durObj:GetRemainingDuration()
        end
        return 0
    end

    -- Fallback: raw table API (pre-12.0.5)
    local cd = C_Spell.GetSpellCooldown(spellID)
    if cd and cd.startTime and cd.startTime > 0 and cd.duration and cd.duration > 1.5 then
        return cd.startTime + cd.duration - GetTime()
    end
    return 0
end

local function toy_cd_remaining(toyID)
    if is_restricted_content() then return 0 end

    local start, dur = C_Container.GetItemCooldown(toyID)
    if start and start > 0 and dur and dur > 0 then
        return start + dur - GetTime()
    end
    return 0
end


-- Scotty's BuildCooldownString logic
local function fmt_cd(secs)
    if secs <= 0 then return "" end
    if secs > 3600 then
        return str_format("%.1fh", secs / 3600)
    elseif secs > 60 then
        return str_format("%dm", secs / 60)
    else
        return str_format("%ds", secs)
    end
end

local function make_section_header(parent, text, yOffset)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 5, yOffset)
    fs:SetText("|cff6600ff" .. text .. "|r")
    return fs
end

local function make_divider(parent, yOffset)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetSize(FRAME_WIDTH - 14, 1)
    line:SetPoint("TOPLEFT", 7, yOffset)
    line:SetColorTexture(unpack(cfg.colors.gray))
    return line
end

local currentHoverFrame = nil

-- arm_spell: left-click = spellID, right-click = portalID (optional, e.g. mage group portals)
local function arm_spell(spellID, portalID, frame)
    if InCombatLockdown() then return end
    currentHoverFrame = frame
    actionBtn:SetAttribute("type", "spell")
    actionBtn:SetAttribute("spell", spellID)
    if portalID and player_has_spell(portalID) then
        actionBtn:SetAttribute("type2", "spell")
        actionBtn:SetAttribute("spell2", portalID)
    else
        actionBtn:SetAttribute("type2", nil)
        actionBtn:SetAttribute("spell2", nil)
    end
    actionBtn:SetParent(frame)
    actionBtn:ClearAllPoints()
    actionBtn:SetAllPoints(frame)
    actionBtn:Show()
end

local function arm_toy(toyID, frame)
    if InCombatLockdown() then return end
    currentHoverFrame = frame
    actionBtn:SetAttribute("type", "toy")
    actionBtn:SetAttribute("toy", toyID)
    actionBtn:SetAttribute("type2", nil)
    actionBtn:SetAttribute("spell2", nil)
    actionBtn:SetParent(frame)
    actionBtn:ClearAllPoints()
    actionBtn:SetAllPoints(frame)
    actionBtn:Show()
end

local function disarm()
    if currentHoverFrame and currentHoverFrame.resetHover then
        currentHoverFrame.resetHover()
    end
    currentHoverFrame = nil
    if not InCombatLockdown() then
        actionBtn:Hide()
        actionBtn:SetParent(UIParent)
        actionBtn:ClearAllPoints()
    end
end

local function show_tooltip(owner, spellID, toyID, label, portalID, cdRem)
    if not GameTooltip or not owner then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if spellID then
        GameTooltip:SetSpellByID(spellID)
        if cdRem and cdRem > 0 then
            GameTooltip:AddLine("|cffff4444CD: " .. fmt_cd(cdRem) .. "|r")
        end
        if portalID and player_has_spell(portalID) then
            GameTooltip:AddLine("Right-click: group portal", 0.6, 0.6, 0.6)
        end
    elseif toyID then
        if GameTooltip.SetToyByItemID then
            GameTooltip:SetToyByItemID(toyID)
        else
            GameTooltip:SetItemByID(toyID)
        end
        if cdRem and cdRem > 0 then
            GameTooltip:AddLine("|cffff4444CD: " .. fmt_cd(cdRem) .. "|r")
        end
    end
    if label then
        GameTooltip:AddLine(label, 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function hide_tooltip()
    if GameTooltip and GameTooltip:IsShown() then
        GameTooltip:Hide()
    end
end

-- Close portal frame after a cast
actionBtn:HookScript("PostClick", function(self, button)
    if button == "LeftButton" or button == "RightButton" then
        _G.C_Timer.After(0.05, function()
            disarm()
            hide_tooltip()
            if portalFrame then portalFrame:Hide() end
            if openLegacyMenu then
                openLegacyMenu:Hide()
                openLegacyMenu = nil
            end
        end)
    end
end)

-- Safety: always clear highlight when mouse leaves the overlay button
actionBtn:SetScript("OnLeave", function()
    disarm()
    hide_tooltip()
end)

-- ========================
-- Widget: M+ portal icon (48x48)
-- ========================
local function make_spell_icon(parent, spellID, label, x, y)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(ICON_SIZE, ICON_SIZE)
    frame:SetPoint("TOPLEFT", x, y)
    frame:EnableMouse(true)

    frame:SetBackdrop(BACKDROP_ICON)
    frame:SetBackdropBorderColor(unpack(cfg.colors.black))

    -- Spell icon
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    local function update_icon()
        local iconID = nil
        if C_Spell and C_Spell.GetSpellTexture then
            iconID = C_Spell.GetSpellTexture(spellID)
        end
        if not iconID and C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spellID)
            iconID = info and info.iconID
        end
        if iconID then
            tex:SetTexture(iconID)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end
    update_icon()
    frame.tex = tex

    -- Native cooldown sweep
    local cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawSwipe(true)
    cd:SetDrawEdge(true)
    cd:SetHideCountdownNumbers(false)

    -- Unusable grey overlay
    local grey = frame:CreateTexture(nil, "OVERLAY")
    grey:SetAllPoints()
    grey:SetColorTexture(0, 0, 0, 0.5)
    grey:Hide()

    local shortStr = sfui.common.get_short_string(label)
    if shortStr and shortStr ~= "" then
        local text = frame:CreateFontString(nil, "OVERLAY")
        local fontFile = _G.GameFontNormal:GetFont()
        text:SetFont(fontFile, 9, "OUTLINE")
        text:SetPoint("TOP", frame, "BOTTOM", 0, -2)
        text:SetText(shortStr)
        text:SetTextColor(0.9, 0.9, 0.9)
    end

    local function refresh()
        if not tex:GetTexture() then
            update_icon()
        end
        local rem = spell_cd_remaining(spellID)
        if rem > 0 then
            local cdInfo = C_Spell.GetSpellCooldown(spellID)
            if cdInfo then cd:SetCooldown(cdInfo.startTime, cdInfo.duration) end
            grey:Show()
            frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        else
            cd:Clear()
            grey:Hide()
            frame:SetBackdropBorderColor(unpack(cfg.colors.black))
        end
    end
    frame.refresh = refresh
    refresh()

    frame.resetHover = refresh -- direct ref, no wrapper closure

    frame:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(cfg.colors.cyan))
        arm_spell(spellID, nil, self) -- no portal for M+ icons
        local rem = spell_cd_remaining(spellID)
        show_tooltip(self, spellID, nil, label, nil, rem)
    end)
    frame:SetScript("OnLeave", function(self)
        if not actionBtn:IsShown() or actionBtn:GetParent() ~= self then
            refresh()
            disarm()
            hide_tooltip()
        end
    end)

    return frame
end

-- ========================
-- Widget: flat row button (wormholes, personal portals)
-- portalID: optional secondary spell for right-click (mage portals)
-- ========================
local function make_action_row(parent, spellID, portalID, toyID, name, icon, yPos)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(FRAME_WIDTH - 10, 22)
    frame:SetPoint("TOPLEFT", 5, yPos)
    frame:EnableMouse(true)
    frame:SetBackdrop(BACKDROP_ROW)
    frame:SetBackdropColor(unpack(cfg.colors.black))
    frame:SetBackdropBorderColor(unpack(cfg.colors.black))

    local ic = frame:CreateTexture(nil, "ARTWORK")
    ic:SetSize(14, 14)
    ic:SetPoint("LEFT", 4, 0)
    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", 22, 0)
    label:SetPoint("RIGHT", -36, 0)
    label:SetJustifyH("LEFT")
    label:SetText(name)
    frame.label = label

    local function update_row_icon()
        local iconID = icon
        if not iconID and spellID then
            if C_Spell and C_Spell.GetSpellTexture then
                iconID = C_Spell.GetSpellTexture(spellID)
            end
            if not iconID and C_Spell and C_Spell.GetSpellInfo then
                local info = C_Spell.GetSpellInfo(spellID)
                iconID = info and info.iconID
            end
        elseif not iconID and toyID then
            iconID = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(toyID)
        end
        if iconID then
            ic:SetTexture(iconID)
            ic:Show()
            label:SetPoint("LEFT", 22, 0)
        else
            ic:Hide()
            label:SetPoint("LEFT", 6, 0)
        end
    end
    update_row_icon()

    local cdLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cdLabel:SetPoint("RIGHT", -4, 0)
    cdLabel:SetTextColor(1, 0.55, 0.1, 1)
    cdLabel:SetText("")

    local grey = frame:CreateTexture(nil, "OVERLAY")
    grey:SetAllPoints()
    grey:SetColorTexture(0, 0, 0, 0.5)
    grey:Hide()

    local function refresh()
        if not ic:GetTexture() then
            update_row_icon()
        end
        local rem = spellID and spell_cd_remaining(spellID) or toy_cd_remaining(toyID)
        -- For toys, grey out if on cooldown only (IsToyUsable skipped — checks transient state)
        if rem > 0 then
            grey:Show()
            cdLabel:SetText("[" .. fmt_cd(rem) .. "]")
            label:SetTextColor(0.6, 0.6, 0.6, 1)
            frame:SetBackdropBorderColor(unpack(cfg.colors.black))
        else
            grey:Hide()
            cdLabel:SetText("")
            label:SetTextColor(unpack(cfg.colors.white))
            frame:SetBackdropBorderColor(unpack(cfg.colors.black))
        end
    end
    frame.refresh = refresh
    refresh()

    frame.resetHover = refresh -- direct ref, no wrapper closure

    frame:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(cfg.colors.cyan))
        label:SetTextColor(unpack(cfg.colors.cyan))
        if spellID then arm_spell(spellID, portalID, self) end
        if toyID then arm_toy(toyID, self) end
        local rem = spellID and spell_cd_remaining(spellID) or toy_cd_remaining(toyID)
        show_tooltip(self, spellID, toyID, nil, portalID, rem)
    end)
    frame:SetScript("OnLeave", function(self)
        if not actionBtn:IsShown() or actionBtn:GetParent() ~= self then
            refresh()
            disarm()
            hide_tooltip()
        end
    end)

    return frame
end

-- ========================
-- Widget: legacy portal dropdown (secure rows)
-- ========================
local function make_legacy_dropdown(parent, group, yPos)
    local menuWidth = FRAME_WIDTH - 10
    local opts = {}
    for _, e in ipairs(group.portals) do
        if player_has_spell(e.spell) then
            tinsert(opts, e)
        end
    end
    if #opts == 0 then return nil end

    table.sort(opts, sort_portals_by_name)

    -- Header
    local header = sfui.common.create_flat_button(parent, group.label, menuWidth, 20)
    header:SetPoint("TOPLEFT", 5, yPos)

    -- Menu (parented to UIParent so it floats above our frame)
    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    parent.legacyMenus = parent.legacyMenus or {}
    tinsert(parent.legacyMenus, menu)
    menu:SetSize(menuWidth, 6 + #opts * 20)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetBackdrop(BACKDROP_MENU)
    menu:SetBackdropColor(0, 0, 0, 0.92)
    menu:SetBackdropBorderColor(unpack(cfg.colors.gray))
    menu:Hide()
    menu:EnableMouse(true)

    local rowY = -4
    for _, opt in ipairs(opts) do
        local spellID = opt.spell
        local row = CreateFrame("Frame", nil, menu, "BackdropTemplate")
        row:SetSize(menuWidth - 8, 18)
        row:SetPoint("TOPLEFT", 4, rowY)
        row:EnableMouse(true)

        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 4, 0)
        fs:SetPoint("RIGHT", -36, 0)
        fs:SetJustifyH("LEFT")

        local cdFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cdFs:SetPoint("RIGHT", -2, 0)
        cdFs:SetTextColor(1, 0.55, 0.1, 1)

        local function refresh_row()
            local rem = spell_cd_remaining(spellID)
            if rem > 0 then
                fs:SetTextColor(0.6, 0.6, 0.6, 1)
                cdFs:SetText("[" .. fmt_cd(rem) .. "]")
            else
                fs:SetTextColor(unpack(cfg.colors.white))
                cdFs:SetText("")
            end
            fs:SetText(opt.name)
        end
        row.refresh = refresh_row
        refresh_row()

        row.resetHover = refresh_row

        row:SetScript("OnEnter", function(self)
            fs:SetTextColor(unpack(cfg.colors.cyan))
            arm_spell(spellID, nil, self) -- no portal for legacy dropdown rows
            local rem = spell_cd_remaining(spellID)
            show_tooltip(self, spellID, nil, nil, nil, rem)
        end)
        row:SetScript("OnLeave", function(self)
            if not actionBtn:IsShown() or actionBtn:GetParent() ~= self then
                refresh_row()
                disarm()
                hide_tooltip()
            end
        end)

        rowY = rowY - 20
    end

    -- Menus stay open until: header click, option click, or portal frame closed.
    -- No auto-close timer needed.
    header:SetScript("OnClick", function(self)
        if menu:IsShown() then
            menu:Hide()
            openLegacyMenu = nil
        else
            if openLegacyMenu then openLegacyMenu:Hide() end
            menu:ClearAllPoints()
            menu:SetPoint("TOPRIGHT", self, "BOTTOMRIGHT", 0, -2)
            -- Refresh row states on open
            local children = { menu:GetChildren() }
            for _, child in ipairs(children) do
                if child.refresh then child.refresh() end
            end
            menu:Show()
            openLegacyMenu = menu
        end
    end)

    return header
end

-- ========================
-- Frame builder (lazy)
-- ========================
local function build_portals_frame()
    if portalFrame then return end
    local db = sfui.portals_db

    portalFrame = CreateFrame("Frame", "SfuiPortalsFrame", UIParent, "BackdropTemplate")
    portalFrame:SetFrameStrata("HIGH")
    portalFrame:SetClampedToScreen(true)
    portalFrame:SetMovable(true)
    portalFrame:EnableMouse(true)
    portalFrame:RegisterForDrag("LeftButton")
    portalFrame:SetScript("OnDragStart", portalFrame.StartMoving)
    portalFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, relativeTo, relativePoint, x, y = self:GetPoint()
        SfuiDB.portals_point = point
        SfuiDB.portals_relativePoint = relativePoint
        SfuiDB.portals_x = x
        SfuiDB.portals_y = y
    end)
    portalFrame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    portalFrame:SetBackdropColor(unpack(cfg.appearance.backdropColor))
    portalFrame:SetBackdropBorderColor(unpack(cfg.colors.black))
    tinsert(UISpecialFrames, "SfuiPortalsFrame")

    portalFrame.refreshable = {}

    local curY = -6

    -- ── M+ Current Season Portals (12.1 Midnight Season 2) ───────
    local seasonSpellMap = {}
    local seasonKnown = {}
    for _, e in ipairs(db.SEASON_PORTALS or {}) do
        if player_has_spell(e.spell) then
            tinsert(seasonKnown, e)
            seasonSpellMap[e.spell] = true
        end
    end
    table.sort(seasonKnown, sort_portals_by_name)

    if #seasonKnown > 0 then
        local col, row = 0, 0
        for _, e in ipairs(seasonKnown) do
            local x = ICON_SPACING_X + col * (ICON_SIZE + ICON_SPACING_X)
            local y = curY - row * (ICON_SIZE + ICON_SPACING_Y)
            local btn = make_spell_icon(portalFrame, e.spell, e.name, x, y)
            tinsert(portalFrame.refreshable, btn)
            col = col + 1
            if col >= ICONS_PER_ROW then
                col = 0; row = row + 1
            end
        end
        local usedRows = math_floor((#seasonKnown - 1) / ICONS_PER_ROW) + 1
        curY = curY - usedRows * (ICON_SIZE + ICON_SPACING_Y) - 8
        make_divider(portalFrame, curY)
        curY = curY - 6
    end

    -- ── Midnight Expansion Portals ───────────────────────────────
    local midnightKnown = {}
    for _, e in ipairs(db.MIDNIGHT_PORTALS or {}) do
        if not seasonSpellMap[e.spell] and player_has_spell(e.spell) then
            tinsert(midnightKnown, e)
        end
    end
    table.sort(midnightKnown, sort_portals_by_name)

    if #midnightKnown > 0 then
        local col, row = 0, 0
        for _, e in ipairs(midnightKnown) do
            local x = ICON_SPACING_X + col * (ICON_SIZE + ICON_SPACING_X)
            local y = curY - row * (ICON_SIZE + ICON_SPACING_Y)
            local btn = make_spell_icon(portalFrame, e.spell, e.name, x, y)
            tinsert(portalFrame.refreshable, btn)
            col = col + 1
            if col >= ICONS_PER_ROW then
                col = 0; row = row + 1
            end
        end
        local usedRows = math_floor((#midnightKnown - 1) / ICONS_PER_ROW) + 1
        curY = curY - usedRows * (ICON_SIZE + ICON_SPACING_Y) - 8
        make_divider(portalFrame, curY)
        curY = curY - 6
    end


    -- ── Personal / Class Portals ─────────────────────────────────
    local personalKnown = {}
    for _, e in ipairs(db.PERSONAL_PORTALS or {}) do
        if player_has_spell(e.spell) then
            tinsert(personalKnown, e)
        end
    end
    table.sort(personalKnown, sort_portals_by_name)

    if #personalKnown > 0 then
        for _, e in ipairs(personalKnown) do
            local info   = C_Spell.GetSpellInfo(e.spell)
            local iconID = info and info.iconID
            -- Pass portal ID (e.portal) for right-click if defined
            local btn    = make_action_row(portalFrame, e.spell, e.portal, nil, e.name, iconID, curY)
            tinsert(portalFrame.refreshable, btn)
            curY = curY - 23
        end
        make_divider(portalFrame, curY - 2)
        curY = curY - 8
    end

    -- ── Engineering Wormholes ────────────────────────────────────
    local wormbolesKnown = {}
    if is_engineer() then
        for _, w in ipairs(db.WORMHOLE_TOYS or {}) do
            -- Show toy only if player has it AND can actually use it
            -- (toy_is_accessible hides skill-locked toys but keeps on-CD ones)
            if toy_is_accessible(w.toy) then
                tinsert(wormbolesKnown, w)
            end
        end
    end

    if #wormbolesKnown > 0 then
        for _, w in ipairs(wormbolesKnown) do
            local icon = C_Item.GetItemIconByID(w.toy)
            local displayName = w.name
                :gsub("Wormhole Generator: ", "")
                :gsub("Wormhole Centrifuge: ", "")
                :gsub("Wyrmhole Generator: ", "")
            local btn = make_action_row(portalFrame, nil, nil, w.toy, displayName, icon, curY)
            tinsert(portalFrame.refreshable, btn)
            curY = curY - 23
        end
        make_divider(portalFrame, curY - 2)
        curY = curY - 8
    end

    -- ── Legacy Portals (Dropdowns) ───────────────────────────────
    local hasLegacy = false
    for _, g in ipairs(db.LEGACY_GROUPS or {}) do
        for _, e in ipairs(g.portals) do
            if player_has_spell(e.spell) then
                hasLegacy = true; break
            end
        end
        if hasLegacy then break end
    end

    if hasLegacy then
        for _, g in ipairs(db.LEGACY_GROUPS or {}) do
            local h = make_legacy_dropdown(portalFrame, g, curY)
            if h then curY = curY - 24 end
        end
    end

    portalFrame:SetSize(FRAME_WIDTH, math.abs(curY) + 4)

    -- Refresh states on every open
    portalFrame:SetScript("OnShow", function(self)
        for _, btn in ipairs(self.refreshable) do
            if btn.refresh then btn.refresh() end
        end
    end)

    -- Live throttled ticker for real-time cooldown sweeps and countdowns
    local updateElapsed = 0
    portalFrame:SetScript("OnUpdate", function(self, elapsed)
        updateElapsed = updateElapsed + elapsed
        if updateElapsed >= 1.0 then
            updateElapsed = 0
            if self.refreshable then
                for _, btn in ipairs(self.refreshable) do
                    if btn.refresh then btn.refresh() end
                end
            end
            if openLegacyMenu and openLegacyMenu:IsShown() then
                for i = 1, select("#", openLegacyMenu:GetChildren()) do
                    local child = select(i, openLegacyMenu:GetChildren())
                    if child and child.refresh then child.refresh() end
                end
            end
        end
    end)

    -- Close any open legacy dropdown when portal window is dismissed
    portalFrame:SetScript("OnHide", function()
        if openLegacyMenu then
            openLegacyMenu:Hide()
            openLegacyMenu = nil
        end
    end)

    portalFrame:ClearAllPoints()
    if SfuiDB.portals_point and SfuiDB.portals_x and SfuiDB.portals_y then
        portalFrame:SetPoint(SfuiDB.portals_point, UIParent, SfuiDB.portals_relativePoint or "CENTER", SfuiDB.portals_x, SfuiDB.portals_y)
    elseif SfuiDB.portals_x and SfuiDB.portals_y then
        -- Backwards compatibility with just x/y
        portalFrame:SetPoint("CENTER", UIParent, "CENTER", SfuiDB.portals_x, SfuiDB.portals_y)
    else
        portalFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    portalFrame:Hide()
end

-- ========================
-- Public API
-- ========================
function sfui.portals.Toggle()
    if InCombatLockdown() then return end
    if not portalFrame then build_portals_frame() end
    if portalFrame:IsShown() then
        portalFrame:Hide()
    else
        portalFrame:Show()
    end
end

local function invalidate_portals_frame()
    -- Nil out the cached frame so it fully rebuilds next open,
    -- picking up any newly learned spells or acquired toys.
    if portalFrame then
        if portalFrame.legacyMenus then
            for _, m in ipairs(portalFrame.legacyMenus) do
                m:Hide()
                m:SetParent(nil)
            end
        end
        portalFrame:Hide()
        portalFrame:SetParent(nil)
        portalFrame = nil
    end
end

function sfui.portals.initialize()
    -- Rebuild the portals frame when the player's spells change
    -- (learns a new portal spell via training, quest reward, etc.)
    sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        -- Always rebuild on login/reload to reflect current character
        invalidate_portals_frame()
    end)
    sfui.events.RegisterEvent("SPELLS_CHANGED", function()
        -- Only invalidate if already built (avoids work before first open)
        if portalFrame then
            invalidate_portals_frame()
        end
    end)
    sfui.events.RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if portalFrame and portalFrame:IsShown() then
            portalFrame:Hide()
        end
        disarm()
        hide_tooltip()
    end)
end

function sfui.portals_debug_info()
    return {
        frameCreated = portalFrame ~= nil,
        frameShown = portalFrame and portalFrame:IsShown() or false,
    }
end
