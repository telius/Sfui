local addonName, addon = ...
sfui = sfui or {}
sfui.cdm = {}
local cfg = sfui.config
local common = sfui.common

local CreateFrame = CreateFrame
local GameTooltip = sfui.tooltip or _G.GameTooltip
local InCombatLockdown = InCombatLockdown
local GetCursorPosition = GetCursorPosition
local GetCursorInfo = GetCursorInfo
local ClearCursor = ClearCursor
local UIParent = UIParent
local C_Spell = C_Spell
local C_Item = C_Item
local C_Timer = C_Timer

local ReloadUI = _G.ReloadUI or (C_UI and C_UI.Reload)

StaticPopupDialogs["SFUI_RELOAD_UI"] = {
    text = "Tracked Bars modified. Reload UI to apply changes?",
    button1 = "Reload",
    button2 = "Later",
    OnAccept = function()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ShowReloadPrompt()
    if not StaticPopup_Visible("SFUI_RELOAD_UI") then
        StaticPopup_Show("SFUI_RELOAD_UI")
    end
end

-- Local references to common utilities
local CreateFlatButton = common.create_flat_button
local issecretvalue = common.issecretvalue
local g = cfg
local c = g.options_panel

local function AddVerticalAccent(frame)
    if not frame then return end
    local accent = frame:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("TOPLEFT", 0, 0)
    accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:SetWidth(3)
    accent:SetColorTexture(unpack(cfg.appearance.highlightColor)) -- Purple accent
    frame.accent = accent
end

local function IsValidID(id)
    if not id then return false end
    local nid = tonumber(id)
    return nid and nid >= -2147483648 and nid <= 2147483647
end

-- Layout Constants
local ICON_SIZE          = 30
local ICON_SPACING       = 2

-- Main Container
local cdmFrame           = nil
local poolFrame          = nil
local zonesFrame         = nil

-- Data Storage for Dragging
local draggedInfo        = nil
local selectedPanelIndex = nil -- Index of panel being edited in settings below
local selectedPanelData  = nil -- Data of selected panel (or true for Tracked Bars)

-- Frame Pools (avoid GC churn on refresh)
local zoneIconFrames     = {}
local zoneIconCount      = 0
local zoneFramePool      = {}
local zoneFrameCount     = 0
local previewBarPool     = {}
local previewBarCount    = 0

-- Forward Declarations (must be before AcquirePoolIcon closures)
local RefreshZones
local OnIconDragStart
local OnIconDragStop
local OnZoneReceiveDrag
local HandleExternalDrop

local function OnZoneIconDragStart(self)
    if OnIconDragStart then
        OnIconDragStart(self, self.isFromTrackedBars)
    end
end

local function OnZoneIconClick(self, button)
    local cdID = self.cdID or self.cooldownID or self.id or (self.entry and (self.entry.cooldownID or self.entry.id))
    if not cdID then return end

    if self.isRightSidePool then
        local entries = self.entries
        local dataProvider = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider and
            CooldownViewerSettings:GetDataProvider()
        local EnumCats = Enum and Enum.CooldownViewerCategory

        if entries[cdID] then
            entries[cdID] = nil
            if dataProvider and EnumCats then
                dataProvider:SetCooldownToCategory(cdID, EnumCats.HiddenAura or -2)
            end
        else
            entries[cdID] = { id = cdID, type = "cooldown", cooldownID = cdID }
            if dataProvider and EnumCats then
                dataProvider:SetCooldownToCategory(cdID, 3)
            end
        end

        -- Force save Blizzard CooldownViewer settings
        local layoutManager = CooldownViewerSettings and CooldownViewerSettings.GetLayoutManager and
            CooldownViewerSettings:GetLayoutManager()
        if layoutManager and layoutManager.SaveLayouts then
            layoutManager:SaveLayouts()
        end
        if ShowReloadPrompt then ShowReloadPrompt() end

        if not next(entries) then SfuiDB.trackedBars = {} end
        if sfui.trackedbars and sfui.trackedbars.UpdateVisibility then sfui.trackedbars.UpdateVisibility() end
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
        if RefreshZones then RefreshZones() end
    else
        -- Left-side zone click: remove on right click or when clicked
        if button == "RightButton" or not button then
            local isTrackedBars = self.isTrackedBars
            local entries = self.entries
            if isTrackedBars then
                local tBars = common.get_tracked_bars()
                tBars[cdID] = nil
                if not next(tBars) then
                    local specID = common.get_current_spec_id() or 0
                    SfuiDB.trackedBarsBySpec[specID] = {}
                end
                if sfui.trackedbars and sfui.trackedbars.UpdateVisibility then sfui.trackedbars.UpdateVisibility() end
                if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
            else
                if entries then
                    local targetId = (type(cdID) == "table" and (cdID.cooldownID or cdID.id)) or cdID
                    for i, val in ipairs(entries) do
                        local entryId = (type(val) == "table" and (val.cooldownID or val.id)) or val
                        if entryId == targetId then
                            table.remove(entries, i)
                            break
                        end
                    end
                end
                -- Update Panels
                if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
            end
            if sfui.cdm and sfui.cdm.RefreshLayout then sfui.cdm.RefreshLayout() end
            if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
            if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
            if RefreshZones then RefreshZones() end
        end
    end
end

local function OnZoneIconEnter(self)
    local tip = sfui.tooltip
    if not tip or not self.id then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    if self.info then
        if self.info.spellID then
            tip:SetSpellByID(self.info.spellID)
        elseif self.info.itemID then
            tip:SetItemByID(self.info.itemID)
        else
            tip:SetText(self.info.name or "Unknown")
        end

        tip:AddLine(" ")
        if self.cooldownID then
            tip:AddDoubleLine("Cooldown ID:", "|cffffffff" .. self.cooldownID .. "|r")
        end
        if self.info.spellID then
            tip:AddDoubleLine("Spell ID:", "|cffffffff" .. self.info.spellID .. "|r")
        end
        if self.info.itemID then
            tip:AddDoubleLine("Item ID:", "|cffffffff" .. self.info.itemID .. "|r")
        end
    elseif self.isRightSidePool then
        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(self.id)
        if cdInfo and cdInfo.spellID then
            tip:SetSpellByID(cdInfo.spellID)
        elseif cdInfo and cdInfo.itemID then
            tip:SetItemByID(cdInfo.itemID)
        else
            tip:SetText("Cooldown " .. self.id)
        end
        tip:AddLine(" ")
        tip:AddDoubleLine("Cooldown ID:", "|cffffffff" .. self.id .. "|r")
        if cdInfo and cdInfo.spellID then
            tip:AddDoubleLine("Spell ID:", "|cffffffff" .. cdInfo.spellID .. "|r")
        elseif cdInfo and cdInfo.itemID then
            tip:AddDoubleLine("Item ID:", "|cffffffff" .. cdInfo.itemID .. "|r")
        end
    else
        if self.isTrackedBars then
            local info = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(self.id)
            if info and info.itemID then
                tip:SetItemByID(info.itemID)
            elseif info and info.spellID then
                tip:SetSpellByID(info.spellID)
            else
                tip:SetSpellByID(self.id)
            end
        else
            local entryType = self.type or "spell"
            if entryType == "item" then
                tip:SetItemByID(self.id)
            else
                tip:SetSpellByID(self.id)
            end
        end
    end

    if not self.isRightSidePool then
        tip:AddLine(" ")
        tip:AddLine("|cffff4444Right-Click to remove from panel|r")
    end
    tip:Show()
end

local function OnZoneIconLeave()
    if sfui.tooltip then sfui.tooltip:Hide() end
end

local function OnPreviewBarUpClick(self)
    local bar = self:GetParent()
    local id = bar.id
    local i = bar.index
    local activeList = bar.activeList
    if not id or not i or not activeList then return end

    local swapTarget = activeList[i - 1]
    local pStore = common.ensure_tracked_bar_db(id)
    local currentP = pStore.priority or 0
    local prevPStore = common.ensure_tracked_bar_db(swapTarget)
    local prevP = prevPStore.priority or 0

    if currentP == prevP then
        pStore.priority = currentP - 1
        prevPStore.priority = currentP
    else
        pStore.priority = prevP
        prevPStore.priority = currentP
    end
    if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
    if RefreshZones then RefreshZones() end
end

local function OnPreviewBarDownClick(self)
    local bar = self:GetParent()
    local id = bar.id
    local i = bar.index
    local activeList = bar.activeList
    if not id or not i or not activeList then return end

    local swapTarget = activeList[i + 1]
    local pStore = common.ensure_tracked_bar_db(id)
    local currentP = pStore.priority or 0
    local nextPStore = common.ensure_tracked_bar_db(swapTarget)
    local nextP = nextPStore.priority or 0

    if currentP == nextP then
        pStore.priority = currentP + 1
        nextPStore.priority = currentP
    else
        pStore.priority = nextP
        nextPStore.priority = currentP
    end

    if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
    if RefreshZones then RefreshZones() end
end

local function AcquirePreviewBar(parent)
    previewBarCount = previewBarCount + 1
    local bar = previewBarPool[previewBarCount]
    if not bar then
        bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        bar:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })

        local iconFrame = CreateFrame("Button", nil, bar)
        iconFrame:SetSize(20, 20)
        iconFrame:SetPoint("LEFT", 2, 0)

        local icon = iconFrame:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        bar.iconFrame = iconFrame
        bar.icon = icon

        common.sync_masque(iconFrame, { Icon = icon })

        local label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", iconFrame, "RIGHT", 5, 0)
        bar.label = label

        local upBtn = CreateFrame("Button", nil, bar)
        upBtn:SetSize(20, 20)
        upBtn:SetPoint("RIGHT", -25, 0)
        upBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
        upBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Highlight")
        upBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Down")

        -- Fix "skin the up button properly like the down button is"
        -- Sometimes upBtn gets custom skinned by ElvUI/Aurora if it has a certain name or if we manually style it,
        -- but if the down button looks right, let's make sure they share identical dimensions/properties.
        if upBtn.GetNormalTexture and upBtn:GetNormalTexture() then
            upBtn:GetNormalTexture():SetTexCoord(0, 1, 0, 1)
        end
        upBtn:SetScript("OnClick", OnPreviewBarUpClick)
        bar.upBtn = upBtn

        local dnBtn = CreateFrame("Button", nil, bar)
        dnBtn:SetSize(20, 20)
        dnBtn:SetPoint("RIGHT", -2, 0)
        dnBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
        dnBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Highlight")
        dnBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
        dnBtn:SetScript("OnClick", OnPreviewBarDownClick)
        bar.dnBtn = dnBtn

        previewBarPool[previewBarCount] = bar
    end
    bar:SetParent(parent)
    bar:ClearAllPoints()
    bar:Show()
    return bar
end


local function AcquireZoneIcon(parent)
    zoneIconCount = zoneIconCount + 1
    local icon = zoneIconFrames[zoneIconCount]
    if not icon then
        icon = CreateFrame("Button", nil, parent)
        icon:SetSize(ICON_SIZE, ICON_SIZE)

        local bb = icon:CreateTexture(nil, "BACKGROUND")
        bb:SetAllPoints()
        bb:SetColorTexture(unpack(cfg.colors.black))
        bb:Hide()
        icon.borderBackdrop = bb

        local tex = icon:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        icon.texture = tex

        icon:RegisterForDrag("LeftButton")
        icon:SetScript("OnDragStart", OnZoneIconDragStart)
        icon:SetScript("OnDragStop", OnIconDragStop)
        icon:SetScript("OnClick", OnZoneIconClick)
        icon:SetScript("OnEnter", OnZoneIconEnter)
        icon:SetScript("OnLeave", OnZoneIconLeave)
        zoneIconFrames[zoneIconCount] = icon

        -- Dedicated selection highlight border
        common.create_border(icon, 2, { 0, 1, 0, 1 })
        if icon.borders then
            for _, b in ipairs(icon.borders) do
                b:SetDrawLayer("OVERLAY", 7)
                b:Hide()
            end
        end
    end

    if sfui.trackedicons and sfui.trackedicons.ApplyIconBorderStyle then
        sfui.trackedicons.ApplyIconBorderStyle(icon, SfuiDB.iconGlobalSettings)
    end
    -- Enforce borderless logic removed to respect user settings

    common.sync_masque(icon, { Icon = icon.texture })

    icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    icon:SetScript("OnClick", OnZoneIconClick)

    icon:SetParent(parent)
    icon:ClearAllPoints()
    icon:Show()
    return icon
end

-- ... (skipping to HandleExternalDrop updates)

local function ResetBucketPool()
    for i = 1, #zoneIconFrames do zoneIconFrames[i]:Hide() end
    zoneIconCount = 0
    for i = 1, #previewBarPool do previewBarPool[i]:Hide() end
    previewBarCount = 0
end

local function GetSharedIconTexture(cdID)
    local id = (type(cdID) == "table" and cdID.id) or cdID
    local typeStr = (type(cdID) == "table" and cdID.type) or "spell"

    local activeEntry = { id = id, type = typeStr }
    if type(cdID) == "table" then
        for k, v in pairs(cdID) do activeEntry[k] = v end
    end

    if activeEntry.type == "cooldown" or activeEntry.cooldownID then
        local searchId = activeEntry.cooldownID or activeEntry.id
        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(searchId)
        if cdInfo then
            if cdInfo.spellID then
                activeEntry.id = cdInfo.spellID
                activeEntry.type = "spell"
            elseif cdInfo.itemID then
                activeEntry.id = cdInfo.itemID
                activeEntry.type = "item"
            end
        end
    end

    if sfui.trackedicons and sfui.trackedicons.GetIconTexture then
        local tex, _ = sfui.trackedicons.GetIconTexture(activeEntry.id, activeEntry.type, activeEntry)
        return tex or 134400
    end
    return 134400
end

local function GetCooldownName(cdID, typeHint)
    local isCooldown = (typeHint == "cooldown")

    if isCooldown then
        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        if cdInfo then
            if cdInfo.spellID then
                return C_Spell.GetSpellName(cdInfo.spellID) or ("Spell: " .. cdInfo.spellID)
            elseif cdInfo.itemID then
                return C_Item.GetItemNameByID(cdInfo.itemID) or ("Item: " .. cdInfo.itemID)
            end
        end
    end

    if typeHint == "item" then
        return C_Item.GetItemNameByID(cdID) or ("Item: " .. cdID)
    end
    return C_Spell.GetSpellName(cdID) or ("ID: " .. cdID)
end

local function RenderTrackedBarsRightSide(parent, width)
    if parent and sfui.trackedoptions.ReleaseSettingsWidgets then
        sfui.trackedoptions.ReleaseSettingsWidgets(parent)
    end

    -- Reuse FontStrings across refreshes (FontStrings cannot be freed in WoW Lua)
    if not parent._poolTitle then
        parent._poolTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        parent._poolTitle:SetPoint("TOPLEFT", 0, -5)
    end
    parent._poolTitle:SetText("Tracked Buffs & Bars Pool (2, 3)")
    parent._poolTitle:Show()

    local yPos = -25
    local list = {}
    if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
        local cats = { 2, 3 }
        if Enum and Enum.CooldownViewerCategory then
            cats = {
                Enum.CooldownViewerCategory.TrackedBuff or 2,
                Enum.CooldownViewerCategory.TrackedBar or 3
            }
        end
        for _, cat in ipairs(cats) do
            -- Pass true to allowUnlearned to include unavailable spells gracefully
            if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
                local ids = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
                if ids then
                    for _, id in ipairs(ids) do
                        if not common.issecretvalue(id) and IsValidID(id) then
                            table.insert(list, id)
                        end
                    end
                end
            end
        end
    end

    local ICON_SIZE = 30
    local spacing = 2
    local cols = math.max(1, math.floor(width / (ICON_SIZE + spacing)))

    local entries = common.get_tracked_bars()
    local x, y = 0, yPos

    for i, cdID in ipairs(list) do
        local icon = AcquireZoneIcon(parent)
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        icon:SetPoint("TOPLEFT", col * (ICON_SIZE + spacing), y - row * (ICON_SIZE + spacing))

        -- Ensure cooldownID resolution for the pool icon
        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        local typeHint = "cooldown"
        if cdInfo then
            if cdInfo.spellID and cdInfo.spellID > 0 then
                typeHint = "spell"
            elseif cdInfo.itemID and cdInfo.itemID > 0 then
                typeHint = "item"
            end
        end

        icon.id = cdID
        icon.type = typeHint
        icon.cooldownID = cdID
        icon.entry = { id = cdID, type = typeHint, cooldownID = cdID }
        icon.texture:SetTexture(GetSharedIconTexture(icon.entry))

        -- Set attributes for shared interaction handlers
        icon.isFromTrackedBars = false
        icon.isTrackedBars = true
        icon.isRightSidePool = true
        icon.entries = entries

        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        local iconName = GetCooldownName(cdID, typeHint)
        if not iconName and typeHint == "spell" then
            iconName = C_Spell.GetSpellName(cdID)
        elseif not iconName and typeHint == "item" then
            iconName = C_Item.GetItemNameByID(cdID)
        end

        icon.info = {
            spellID = (cdInfo and cdInfo.spellID and cdInfo.spellID > 0) and cdInfo.spellID or nil,
            itemID = (cdInfo and cdInfo.itemID and cdInfo.itemID > 0) and cdInfo.itemID or nil,
            name = iconName or ("Unknown (" .. cdID .. ")")
        }

        if cdInfo and cdInfo.isKnown == false then
            icon.texture:SetDesaturated(true)
        else
            icon.texture:SetDesaturated(false)
        end

        -- Hide all borders initially
        if icon.borders then
            for _, b in ipairs(icon.borders) do b:Hide() end
        end
        if entries[cdID] then
            -- Show the green border if tracked
            if icon.borders then
                for _, b in ipairs(icon.borders) do
                    b:SetColorTexture(0, 1, 0, 1) -- Green
                    b:Show()
                end
            end
        end

        icon:RegisterForClicks("LeftButtonUp")

        if i == #list then
            yPos = y - row * (ICON_SIZE + spacing) - ICON_SIZE - 20
        end
    end

    if not parent._noIconsLabel then
        parent._noIconsLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        parent._noIconsLabel:SetText("No icons found in groups -2, 2, or 3.")
    end
    if #list == 0 then
        parent._noIconsLabel:ClearAllPoints()
        parent._noIconsLabel:SetPoint("TOPLEFT", 0, yPos)
        parent._noIconsLabel:Show()
        yPos = yPos - 20
    else
        parent._noIconsLabel:Hide()
    end

    if not parent._title2 then
        parent._title2 = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        parent._title2:SetText("Tracked Bars Preview (Active)")
    end
    parent._title2:ClearAllPoints()
    parent._title2:SetPoint("TOPLEFT", 0, yPos)
    parent._title2:Show()
    yPos = yPos - 25

    local activeList = {}
    for id, enabled in pairs(entries) do
        if enabled and IsValidID(id) then
            table.insert(activeList, tonumber(id))
        end
    end

    local function SimpleSort(a, b)
        local cA = sfui.trackedbars and sfui.trackedbars.GetConfig and sfui.trackedbars.GetConfig(a)
        local cB = sfui.trackedbars and sfui.trackedbars.GetConfig and sfui.trackedbars.GetConfig(b)
        local pA = (cA and cA.priority) or 0
        local pB = (cB and cB.priority) or 0
        if pA ~= pB then return pA < pB end

        local nA = GetCooldownName(a)
        local nB = GetCooldownName(b)
        return nA < nB
    end
    table.sort(activeList, SimpleSort)

    for i, id in ipairs(activeList) do
        local bar = AcquirePreviewBar(parent)
        bar:SetSize(width, 24)
        bar:SetPoint("TOPLEFT", 0, yPos)
        bar:SetBackdropColor(0.2, 0.2, 0.2, 0.8)

        -- Ensure cooldownID resolution for the preview bar
        local entry = common.get_tracked_bar_db and common.get_tracked_bar_db(id) or { id = id }
        local typeHint = entry.type or "cooldown"
        bar.icon:SetTexture(GetSharedIconTexture({ id = id, type = typeHint, cooldownID = id }))

        local name = GetCooldownName(id, typeHint)
        bar.label:SetText(name)

        bar.id = id
        bar.index = i
        bar.activeList = activeList

        if i > 1 then
            bar.upBtn:Show()
        else
            bar.upBtn:Hide()
        end

        if i < #activeList then
            bar.dnBtn:Show()
        else
            bar.dnBtn:Hide()
        end

        yPos = yPos - 26
    end
end


-- ----------------------------------------------------------------------------
-- Initialization & Layout
-- ----------------------------------------------------------------------------

function sfui.cdm.RefreshZones()
    if RefreshZones then RefreshZones() end
end

-- Layout Constants
local PANEL_LIST_W = 360 -- Left column: panel list
local SETTINGS_W = 370   -- Right column: settings
local GAP = 10

function sfui.cdm.create_panel(parent)
    if cdmFrame then
        cdmFrame:SetParent(parent)
        cdmFrame:SetAllPoints(parent)
        cdmFrame:Show()
        sfui.cdm.RefreshLayout()
        return cdmFrame
    end

    cdmFrame = CreateFrame("Frame", "SfuiCDMPanel", parent)
    cdmFrame:SetAllPoints(parent)

    -- Global Drag Cleanup
    cdmFrame:SetScript("OnMouseUp", function()
        if draggedInfo then
            if draggedInfo.cursor then draggedInfo.cursor:Hide() end
            draggedInfo = nil
        end
    end)

    -- ─── Left Column: Panel List ─────────────────────────────────────────────
    local leftScroll = CreateFrame("ScrollFrame", "SfuiCDMLeftScroll", cdmFrame, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 5, -5)
    leftScroll:SetPoint("BOTTOMLEFT", 5, 5)
    leftScroll:SetWidth(PANEL_LIST_W - 20) -- Move scrollbar 20px left by reducing width

    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(PANEL_LIST_W - 20, 2000)
    leftScroll:SetScrollChild(leftContent)
    cdmFrame.leftContent = leftContent

    -- ─── Right Column: Settings ───────────────────────────────────────────────
    local rightScroll = CreateFrame("ScrollFrame", "SfuiCDMRightScroll", cdmFrame, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT", 5 + PANEL_LIST_W + GAP, -5)
    rightScroll:SetPoint("BOTTOMRIGHT", -25, 5)

    local rightContent = CreateFrame("Frame", nil, rightScroll)
    rightContent:SetSize(SETTINGS_W, 3000)
    rightScroll:SetScrollChild(rightContent)
    cdmFrame.rightContent = rightContent

    -- ─── Divider ──────────────────────────────────────────────────────────────
    local divider = cdmFrame:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", 5 + PANEL_LIST_W + 5, -5)
    divider:SetPoint("BOTTOMLEFT", 5 + PANEL_LIST_W + 5, 5)
    divider:SetColorTexture(0.4, 0, 1, 0.5)

    function sfui.cdm.RefreshLayout()
        ResetBucketPool()
        RefreshZones()
        -- Resize left content to actual zone height
        local kids = { leftContent:GetChildren() }
        local maxBottom = 0
        for _, k in ipairs(kids) do
            if k:IsShown() then
                local _, _, _, _, y = k:GetPoint(1)
                maxBottom = math.max(maxBottom, math.abs(y or 0) + k:GetHeight())
            end
        end
        leftContent:SetHeight(math.max(maxBottom + 50, 200))
    end

    sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
        selectedPanelIndex = nil
        selectedPanelData = nil
        sfui.cdm.RefreshLayout()
    end)

    cdmFrame:SetScript("OnShow", sfui.cdm.RefreshLayout)
    cdmFrame:SetScript("OnHide", function()
        if draggedInfo then OnIconDragStop(draggedInfo.icon) end
    end)

    sfui.cdm.RefreshLayout()
    return cdmFrame
end

-- ----------------------------------------------------------------------------
-- Logic
-- ----------------------------------------------------------------------------

local function AcquireZoneFrame(parent, name, yPos, xPos, width, panelData, isTrackedBars, panelIndex)
    zoneFrameCount = zoneFrameCount + 1
    local zone = zoneFramePool[zoneFrameCount]
    if not zone then
        zone = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        zone:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
        })
        AddVerticalAccent(zone)

        local label = zone:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", 5, -5)
        zone.label = label

        -- Selection Checkbox (Right side)
        local sel = common.create_checkbox(zone, "Edit",
            function() return selectedPanelIndex == zone.panelIndex end,
            function(val)
                if val then
                    selectedPanelIndex = zone.panelIndex
                    selectedPanelData = zone.isTrackedBars and true or zone.panelData
                else
                    if selectedPanelIndex == zone.panelIndex then
                        selectedPanelIndex = nil
                        selectedPanelData = nil
                    end
                end
                sfui.cdm.RefreshLayout()
            end)
        sel:SetPoint("BOTTOMRIGHT", -5, 5)

        if sel.text then
            sel.text:ClearAllPoints()
            sel.text:SetPoint("BOTTOM", sel, "TOP", 0, 2)
            sel.text:SetTextColor(unpack(cfg.colors.white)) -- White
        end
        zone.selCheck = sel

        -- Delete Button for custom panels
        local del = CreateFrame("Button", nil, zone)
        del:SetSize(16, 16)
        del:SetPoint("TOPRIGHT", -5, -5)
        del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
        del:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
        del:SetScript("OnClick", function()
            if common.delete_custom_panel(zone.panelIndex) then
                sfui.cdm.RefreshLayout()
            end
        end)
        zone.deleteBtn = del

        -- Import Dropdown
        local options = {
            { text = "Import: Essential",    value = 0 },
            { text = "Import: Utility",      value = 1 },
            { text = "Import: Buffs",        value = 2 },
            { text = "Import: Tracked Bars", value = 3 },
        }
        local importBtn = common.create_dropdown(zone, 80, options, function(gId)
            if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then return end
            local list = C_CooldownViewer.GetCooldownViewerCategorySet(gId, true)
            if not list then return end

            local isList = (type(list) == "table")
            local entries = zone.isTrackedBars and common.get_tracked_bars() or
                (zone.panelData and zone.panelData.entries)
            if entries then
                for _, cooldownID in ipairs(list) do
                    if not common.issecretvalue(cooldownID) then
                        if not IsValidID(cooldownID) then
                            common.print("|cffff0000SFUI CDM Error:|r Skipping invalid ID " ..
                                tostring(cooldownID) .. " (outside 32-bit range)")
                        else
                            local entry = { id = cooldownID, type = "cooldown", cooldownID = cooldownID }
                            if zone.isTrackedBars then
                                entries[cooldownID] = entry
                            else
                                table.insert(entries, entry)
                            end
                        end
                    end
                end
            end
            sfui.cdm.RefreshLayout()
            if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
            if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
        end)
        importBtn:SetPoint("TOPRIGHT", -5, -5)
        zone.importBtn = importBtn

        -- Drop Indicator (DropLine)
        local dropLine = zone:CreateTexture(nil, "OVERLAY")
        dropLine:SetColorTexture(0, 1, 0.5, 1) -- Bright cyan-green
        dropLine:SetSize(4, ICON_SIZE)
        dropLine:Hide()
        zone.dropLine = dropLine

        -- Content Area for current icons
        local content = CreateFrame("Frame", nil, zone)
        content:SetPoint("TOPLEFT", 5, -25)
        content:SetPoint("BOTTOMRIGHT", -5, 5)
        zone.content = content

        -- Drop Handler & Hover Visuals
        zone:SetScript("OnUpdate", function(self, elapsed)
            self.throttle = (self.throttle or 0) + elapsed
            local threshold = draggedInfo and 0.05 or 1.0
            if self.throttle < threshold then return end
            self.throttle = 0

            if draggedInfo and self:IsMouseOver() then
                if not self._isHovered then
                    self:SetBackdropBorderColor(0, 1, 0, 1) -- Hover highlight
                    self._isHovered = true
                    self._isIdle = false
                end

                -- Determine closest icon index to insert before
                local mX, mY = GetCursorPosition()
                local sX = self:GetEffectiveScale()
                mX, mY = mX / sX, mY / sX

                local closestIcon = nil
                local closestDist = math.huge
                local insertIndex = 1

                if self.content.icons and #self.content.icons > 0 then
                    -- Tracked bars uses map, panels use array
                    local numIcons = #self.content.icons
                    for i, icon in ipairs(self.content.icons) do
                        if icon:IsShown() then
                            local x, y = icon:GetCenter()
                            if x and y then
                                -- Check distance to left edge of icon
                                local lX = icon:GetLeft()
                                local dist = math.abs(mX - lX)
                                if dist < closestDist then
                                    closestDist = dist
                                    closestIcon = icon
                                    insertIndex = i
                                end
                                -- Check distance to right edge if it's the last icon
                                if i == numIcons then
                                    local rX = icon:GetRight()
                                    local rdist = math.abs(mX - rX)
                                    if mX > x and rdist < closestDist then
                                        closestIcon = icon
                                        insertIndex = i + 1
                                        closestDist = rdist
                                    end
                                end
                            end
                        end
                    end
                end


                if closestIcon and insertIndex <= #self.content.icons then
                    self.dropLine:ClearAllPoints()
                    self.dropLine:SetPoint("LEFT", closestIcon, "LEFT", -3, 0)
                    self.dropLine:Show()
                elseif closestIcon and insertIndex > #self.content.icons then
                    self.dropLine:ClearAllPoints()
                    self.dropLine:SetPoint("RIGHT", closestIcon, "RIGHT", 3, 0)
                    self.dropLine:Show()
                else
                    -- Empty panel
                    self.dropLine:ClearAllPoints()
                    self.dropPoint = self.content:GetPoint(1)
                    self.dropLine:SetPoint("TOPLEFT", self.content, "TOPLEFT", 2, -2)
                    self.dropLine:Show()
                end

                if self.dropInsertIndex ~= insertIndex then
                    self.dropInsertIndex = insertIndex
                    self.dropTargetID = closestIcon and
                        (closestIcon.cooldownID or (closestIcon.info and (closestIcon.info.spellID or closestIcon.info.itemID))) or
                        nil

                    -- Re-render layout with a gap
                    local cx, cy = 0, 0
                    local drawIndex = 1
                    for i, icon in ipairs(self.content.icons) do
                        if i == insertIndex then
                            -- Insert gap
                            cx = cx + ICON_SIZE + 2
                            if cx > 300 then
                                cx = 0; cy = cy - ICON_SIZE - 2
                            end
                        end
                        icon:SetPoint("TOPLEFT", self.content, "TOPLEFT", cx, cy)
                        cx = cx + ICON_SIZE + 2
                        if cx > 300 then
                            cx = 0; cy = cy - ICON_SIZE - 2
                        end
                    end
                    -- Handle gap at the very end
                    if insertIndex > #self.content.icons then
                        cx = cx + ICON_SIZE + 2
                    end
                end
            else
                if not self._isIdle then
                    if self.isTrackedBars then
                        self:SetBackdropBorderColor(0.8, 0.4, 1.0, 0.8)
                    else
                        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
                    end
                    if self.dropInsertIndex then
                        self.dropLine:Hide()
                        self.dropInsertIndex = nil
                        self.dropTargetID = nil
                        -- Revert layout to normal
                        local cx, cy = 0, 0
                        for i, icon in ipairs(self.content.icons) do
                            icon:SetPoint("TOPLEFT", self.content, "TOPLEFT", cx, cy)
                            cx = cx + ICON_SIZE + 2
                            if cx > 300 then
                                cx = 0; cy = cy - ICON_SIZE - 2
                            end
                        end
                    end
                    self._isIdle = true
                    self._isHovered = false
                end
            end
        end)

        zone:SetScript("OnMouseUp", function(self)
            local cursorType = GetCursorInfo()
            if not draggedInfo and cursorType then
                HandleExternalDrop(self, self.panelData, self.isTrackedBars)
            else
                OnZoneReceiveDrag(self, self.panelData, self.isTrackedBars)
            end
        end)

        -- Accept spells/items dragged from Blizzard UI (spellbook, bags, character panel)
        zone:SetScript("OnReceiveDrag", function(self)
            HandleExternalDrop(self, self.panelData, self.isTrackedBars)
        end)

        zoneFramePool[zoneFrameCount] = zone
    end

    zone.panelData = panelData
    zone.isTrackedBars = isTrackedBars
    zone.panelIndex = panelIndex
    zone.panelEntries = isTrackedBars and common.get_tracked_bars() or (panelData and panelData.entries)

    zone:Show()
    zone:SetParent(parent)
    zone:SetPoint("TOPLEFT", xPos, yPos)
    zone:SetSize(width or 400, 92)

    -- Visual Style
    if isTrackedBars then
        zone:SetBackdropColor(0.06, 0, 0.12, 0.9) -- Dark Purple tint
        zone:SetBackdropBorderColor(0, 0, 0, 0)
        zone.label:SetText("Tracked Bars")
        zone.label:SetTextColor(unpack(cfg.appearance.highlightColor)) -- Purple accent
        zone.deleteBtn:Hide()
    else
        zone:SetBackdropColor(0.06, 0.06, 0.06, 0.9)
        zone:SetBackdropBorderColor(0, 0, 0, 0)
        local isBuiltIn = (name == "CENTER" or name == "UTILITY" or name == "Left" or name == "Right")
        if name and (name == "CAT" or name == "BEAR" or name == "MOONKIN" or name == "STEALTH") then isBuiltIn = true end

        local displayName = name or "Unnamed Panel"
        zone.label:SetText(displayName)
        if not isBuiltIn and panelIndex then
            zone.deleteBtn:Show()
        else
            zone.deleteBtn:Hide()
        end
    end

    zone.selCheck:SetChecked(selectedPanelIndex == panelIndex)

    -- Populate Existing Icons
    local entries = isTrackedBars and common.get_tracked_bars() or (panelData and panelData.entries)
    local x, y = 0, 0
    local icons = {}

    -- Helper to get texture
    local function GetIconTexture(cdID)
        return GetSharedIconTexture(cdID)
    end

    local content = zone.content
    content.icons = {}

    if entries then
        -- Handle TrackedBars structure (map[id] = true/table) vs Panel structure (list of ids)
        local list = {}
        if isTrackedBars then
            local tBars = common.get_tracked_bars()
            for id, enabled in pairs(tBars) do
                if enabled and IsValidID(id) then
                    table.insert(list, tonumber(id))
                end
            end
        else
            list = entries
        end

        for _, cdID in ipairs(list) do
            local icon = AcquireZoneIcon(content)
            icon:SetPoint("TOPLEFT", x, y)
            icon.texture:SetTexture(GetIconTexture(cdID))

            -- Restore default state for pooled icons
            if icon.borders then
                for _, b in ipairs(icon.borders) do b:Hide() end
            end
            -- Ensure it has the necessary info for dragging and clicking
            local iconId = (type(cdID) == "table" and cdID.id) or cdID
            local entry = (type(cdID) == "table") and cdID or
                { id = iconId, type = isTrackedBars and "cooldown" or "spell" }
            local cooldownID = entry.cooldownID or (entry.type == "cooldown" and iconId)

            local cdInfo = cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
            local spellID = cdInfo and cdInfo.spellID or (entry.type == "spell" and iconId)
            local itemID = cdInfo and cdInfo.itemID or (entry.type == "item" and iconId)

            if cdInfo and cdInfo.isKnown == false then
                icon.texture:SetDesaturated(true)
            else
                icon.texture:SetDesaturated(false)
            end

            -- Set attributes for the shared click/drag/tooltip handlers
            icon.id = iconId
            icon.cdID = cdID
            icon.cooldownID = cooldownID
            icon.entry = entry -- Store original entry for re-insertion
            icon.type = entry.type
            icon.isTrackedBars = isTrackedBars
            icon.isFromTrackedBars = zone.isTrackedBars
            icon.isRightSidePool = false
            icon.entries = entries

            icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            icon:SetScript("OnClick", OnZoneIconClick)

            table.insert(content.icons, icon)
            local iconName = GetCooldownName(cooldownID or iconId, entry.type)
            if not iconName and entry.type == "spell" then
                iconName = C_Spell.GetSpellName(iconId)
            elseif not iconName and entry.type == "item" then
                iconName = C_Item.GetItemNameByID(iconId)
            end

            icon.info = {
                spellID = spellID,
                itemID = itemID,
                name = iconName or ("Unknown (" .. iconId .. ")")
            }



            x = x + ICON_SIZE + 2
            if x > 300 then
                x = 0; y = y - ICON_SIZE - 2
            end
        end
    end

    return zone
end

local function RenderAssignmentsIconPool(parent, width, entries)
    if parent and sfui.trackedoptions.ReleaseSettingsWidgets then
        sfui.trackedoptions.ReleaseSettingsWidgets(parent)
    end

    -- Reuse FontString across refreshes (FontStrings cannot be freed in WoW Lua)
    if not parent._assignPoolTitle then
        parent._assignPoolTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        parent._assignPoolTitle:SetPoint("TOPLEFT", 0, -5)
    end
    parent._assignPoolTitle:SetText("Assignments Pool (-1, 0, 1)")
    parent._assignPoolTitle:Show()

    local yPos = -25
    local list = {}
    if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
        local cats = { -1, 0, 1 }
        if Enum and Enum.CooldownViewerCategory then
            cats = {
                Enum.CooldownViewerCategory.Disabled or -1,
                Enum.CooldownViewerCategory.Essential or 0,
                Enum.CooldownViewerCategory.Utility or 1
            }
        end
        for _, cat in ipairs(cats) do
            -- Pass false to allowUnlearned to skip most unlearned spells natively
            if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
                local ids = C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)
                if ids then
                    for _, id in ipairs(ids) do
                        if not common.issecretvalue(id) and IsValidID(id) then
                            local cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(id)
                            -- Only collect if it is explicitly known or has no restrictive known metadata
                            if not cdInfo or cdInfo.isKnown ~= false then
                                table.insert(list, id)
                            end
                        end
                    end
                end
            end
        end
    end

    local ICON_SIZE = 30
    local spacing = 2
    local cols = math.max(1, math.floor(width / (ICON_SIZE + spacing)))

    local x, y = 0, yPos

    for i, cdID in ipairs(list) do
        local icon = AcquireZoneIcon(parent)
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        icon:SetPoint("TOPLEFT", col * (ICON_SIZE + spacing), y - row * (ICON_SIZE + spacing))

        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        local typeHint = "cooldown"
        if cdInfo then
            if cdInfo.spellID and cdInfo.spellID > 0 then
                typeHint = "spell"
            elseif cdInfo.itemID and cdInfo.itemID > 0 then
                typeHint = "item"
            end
        end

        icon.id = cdID
        icon.type = typeHint
        icon.cooldownID = cdID
        icon.entry = { id = cdID, type = typeHint, cooldownID = cdID }
        icon.texture:SetTexture(GetSharedIconTexture(icon.entry))

        -- Set attributes for the shared click/drag/tooltip handlers
        icon.isTrackedBars = true
        icon.isFromTrackedBars = false
        icon.isRightSidePool = true

        local iconName = GetCooldownName(cdID, typeHint)
        if not iconName and typeHint == "spell" then
            iconName = C_Spell.GetSpellName(cdID)
        elseif not iconName and typeHint == "item" then
            iconName = C_Item.GetItemNameByID(cdID)
        end

        icon.info = {
            spellID = (cdInfo and cdInfo.spellID and cdInfo.spellID > 0) and cdInfo.spellID or nil,
            itemID = (cdInfo and cdInfo.itemID and cdInfo.itemID > 0) and cdInfo.itemID or nil,
            name = iconName or ("Unknown (" .. cdID .. ")")
        }

        -- Re-apply global border preferences, ensuring our green selection frame is hidden initially
        -- First, hide all borders to reset state
        if icon.borders then
            for _, b in ipairs(icon.borders) do b:Hide() end
        end
        -- Then apply global style, which might show some borders
        if sfui.trackedicons and sfui.trackedicons.ApplyIconBorderStyle then
            sfui.trackedicons.ApplyIconBorderStyle(icon, SfuiDB.iconGlobalSettings)
        end

        -- Check if it's currently assigned to THIS panel
        local isAssigned = false
        if entries then
            for _, val in ipairs(entries) do
                local existingId = (type(val) == "table" and (val.cooldownID or val.id)) or val
                if existingId == cdID then
                    isAssigned = true; break
                end
            end
        end

        if isAssigned then
            if icon.borders then
                for _, b in ipairs(icon.borders) do b:Show() end
            end
        end

        icon:RegisterForClicks("LeftButtonUp")
        icon:SetScript("OnClick", function()
            -- Same basic click-to-add/remove logic as Tracked Bars pool, but for a specific panel.
            local wasAssigned = false
            local existingIndex = nil
            if entries then
                for ei, val in ipairs(entries) do
                    local eId = (type(val) == "table" and (val.cooldownID or val.id)) or val
                    if eId == cdID then
                        wasAssigned = true
                        existingIndex = ei
                        break
                    end
                end
            end

            if wasAssigned and existingIndex then
                table.remove(entries, existingIndex)
            else
                if type(entries) == "table" then
                    table.insert(entries, { id = cdID, type = "cooldown", cooldownID = cdID })
                end
            end
            if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
            if sfui.trackedoptions and sfui.trackedoptions.UpdateSettings then sfui.trackedoptions.UpdateSettings() end -- NEW
            if RefreshZones then RefreshZones() end
        end)



        if i == #list then
            yPos = y - row * (ICON_SIZE + spacing) - ICON_SIZE - 20
        end
    end

    return yPos
end

RefreshZones = function()
    local leftContainer  = cdmFrame and cdmFrame.leftContent
    local rightContainer = cdmFrame and cdmFrame.rightContent
    if not leftContainer then return end

    -- ── Clear Left (panels list) ──────────────────────────────────────────────
    -- Reset Zone Pool (Optimization: Hide all, reuse in MakeZone)
    for i = 1, #zoneFramePool do
        zoneFramePool[i]:Hide()
        zoneFramePool[i]:ClearAllPoints()
    end
    zoneFrameCount = 0
    zoneIconCount = 0 -- Reset icon pool too

    if sfui.trackedoptions.ReleaseSettingsWidgets then
        sfui.trackedoptions.ReleaseSettingsWidgets(leftContainer)
    end
    leftContainer.zoneChildren = {}

    -- ── Clear Right (settings) ────────────────────────────────────────────────
    if rightContainer and sfui.trackedoptions.ReleaseSettingsWidgets then
        sfui.trackedoptions.ReleaseSettingsWidgets(rightContainer)
    end

    local currentY = -5
    local ZONE_H   = 92
    local ROW_GAP  = 8
    local ZONE_W   = PANEL_LIST_W - 22 -- leave room for scroll bar

    local function MakeZone(panelData, isTrackedBars, panelIndex)
        local zone = AcquireZoneFrame(leftContainer, isTrackedBars and "Tracked Bars" or (panelData and panelData.name),
            currentY, 0, ZONE_W, panelData, isTrackedBars, panelIndex)



        if not selectedPanelIndex then
            selectedPanelIndex = panelIndex
            selectedPanelData = panelData
            if isTrackedBars then selectedPanelIndex = "TRACKED_BARS" end
        end

        -- ── Accent colour based on selection ─────────────────────────────────
        local isSelected = (selectedPanelIndex == panelIndex)
        if zone.accent then
            if isSelected then
                zone.accent:SetColorTexture(unpack(cfg.colors.cyan))   -- Cyan #00FFFF
            else
                zone.accent:SetColorTexture(unpack(cfg.appearance.highlightColor)) -- Purple
            end
        end

        if not leftContainer.zoneChildren then leftContainer.zoneChildren = {} end
        table.insert(leftContainer.zoneChildren, zone)

        currentY = currentY - ZONE_H - ROW_GAP
    end

    -- 1. Tracked Bars
    MakeZone(nil, true, "TRACKED_BARS")

    -- 2. All Panels
    local panels = common.get_cooldown_panels()
    if panels then
        for i, panel in ipairs(panels) do
            MakeZone(panel, false, i)
        end
    end

    -- 3. Add Panel row
    local addFrame = CreateFrame("Frame", nil, leftContainer, "BackdropTemplate")
    addFrame:SetSize(ZONE_W, 30)
    addFrame:SetPoint("TOPLEFT", 0, currentY - 8)
    addFrame:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
    addFrame:SetBackdropColor(0.06, 0.06, 0.06, 0.9)
    addFrame:SetBackdropBorderColor(0, 0, 0, 0)
    AddVerticalAccent(addFrame)

    local eb = CreateFrame("EditBox", nil, addFrame)
    eb:SetSize(ZONE_W - 70, 20)
    eb:SetPoint("LEFT", 10, 0)
    eb:SetFontObject("ChatFontNormal")
    eb:SetTextColor(0.8, 0.8, 0.8)
    eb:SetMultiLine(false)
    eb:SetAutoFocus(false)
    eb:SetText("New Panel Name")
    eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    eb:SetScript("OnEnterPressed", function(self)
        local name = self:GetText()
        if name and name ~= "" and name ~= "New Panel Name" then
            common.add_custom_panel(name)
            sfui.cdm.RefreshLayout()
        end
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local addBtn = common.create_flat_button(addFrame, "Add", 55, 20)
    addBtn:SetPoint("RIGHT", -5, 0)
    addBtn:SetBackdropBorderColor(unpack(cfg.appearance.highlightColor))
    addBtn:SetScript("OnClick", function()
        local name = eb:GetText()
        if name and name ~= "" and name ~= "New Panel Name" then
            common.add_custom_panel(name)
            sfui.cdm.RefreshLayout()
        end
        eb:ClearFocus()
    end)
    currentY = currentY - 46

    leftContainer:SetHeight(math.abs(currentY) + 20)

    -- ── Render Settings on Right ──────────────────────────────────────────────
    if rightContainer then
        if selectedPanelIndex == "TRACKED_BARS" then
            RenderTrackedBarsRightSide(rightContainer, SETTINGS_W - 22)
        elseif selectedPanelData then
            local poolEndingY = RenderAssignmentsIconPool(rightContainer, SETTINGS_W - 22, selectedPanelData.entries)
            sfui.trackedoptions.RenderPanelSettings(rightContainer, selectedPanelData, 0, poolEndingY - 5,
                SETTINGS_W - 22)
        else
            -- Placeholder hint — guard to prevent a new FontString accumulating each render
            if not rightContainer._hint then
                rightContainer._hint = rightContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                rightContainer._hint:SetPoint("TOP", 0, -30)
                rightContainer._hint:SetWidth(SETTINGS_W - 40)
                rightContainer._hint:SetTextColor(0.4, 0.4, 0.4, 1)
                rightContainer._hint:SetText("← Select a panel to configure it")
            end
            rightContainer._hint:Show()
        end
    end
end


-- ----------------------------------------------------------------------------
-- Logic Helpers
-- ----------------------------------------------------------------------------

local function PurgeIconFromEverywhere(targetId)
    if not targetId then return end

    -- 1. Purge from Tracked Bars
    if SfuiDB.trackedBars then
        SfuiDB.trackedBars[targetId] = nil

        -- Update Blizzard backend and save
        local dp = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider and
            CooldownViewerSettings:GetDataProvider()
        if dp then
            dp:SetCooldownToCategory(targetId, -1) -- HiddenSpell
            local layoutManager = CooldownViewerSettings and CooldownViewerSettings.GetLayoutManager and
                CooldownViewerSettings:GetLayoutManager()
            if layoutManager and layoutManager.SaveLayouts then
                layoutManager:SaveLayouts()
            end
            ShowReloadPrompt()
        end
    end

    -- 2. Purge from Custom Panels
    local panels = common.get_cooldown_panels()
    if panels then
        for _, panel in ipairs(panels) do
            if panel.entries then
                for i = #panel.entries, 1, -1 do
                    local val = panel.entries[i]
                    local entryId = (type(val) == "table" and (val.cooldownID or val.id)) or val
                    if entryId == targetId then
                        table.remove(panel.entries, i)
                    end
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Drag Handlers
-- ----------------------------------------------------------------------------

OnIconDragStart = function(self, isFromTrackedBars)
    if InCombatLockdown() then return end

    if not cursor then
        cursor = CreateFrame("Frame", nil, UIParent)
        cursor:SetSize(ICON_SIZE, ICON_SIZE)
        cursor:SetFrameStrata("TOOLTIP")
        cursor.texture = cursor:CreateTexture(nil, "OVERLAY")
        cursor.texture:SetAllPoints()
        cursor:SetScript("OnUpdate", function(self, elapsed)
            self.throttle = (self.throttle or 0) + elapsed
            if self.throttle < 0.05 then return end
            self.throttle = 0

            if not self:IsShown() then return end
            local x, y = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
        end)
    end

    cursor.texture:SetTexture(self.texture:GetTexture())
    cursor.texture:SetAlpha(0.7)

    cursor:EnableMouse(false) -- CRITICAL: Ghost must not block MouseUp events

    draggedInfo = {
        icon = self, -- Original icon
        cursor = cursor,
        info = self.info,
        cooldownID = self.cooldownID,
        isFromTrackedBars = isFromTrackedBars, -- NEW
        entry = self.entry,
        originalPanelEntries = self:GetParent().panelEntries or
            (self:GetParent():GetParent() and self:GetParent():GetParent().panelEntries),
        -- Store original position to snap back if needed?
        originalParent = self:GetParent(),
        originalPoint = "TOPLEFT",
        originalRelative = nil,
        originalX = 0,
        originalY = 0
    }

    cursor:Show()

    -- Hide original? Or dim it?
    self:SetAlpha(0.5)
end

OnZoneReceiveDrag = function(zoneFrame, panelData, isTrackedBars)
    if not draggedInfo then return end

    local incomingId = draggedInfo.entry and (draggedInfo.entry.cooldownID or draggedInfo.entry.id)
    if not incomingId then
        incomingId = draggedInfo.cooldownID or
            (draggedInfo.info and (draggedInfo.info.spellID or draggedInfo.info.itemID))
    end

    if not incomingId then
        common.print("|cffFF0000SFUI Error:|r Invalid Icon ID")
        return
    end

    -- Prevent dragging from Cooldown Panels to Tracked Bars
    if isTrackedBars and draggedInfo.originalPanelEntries and not draggedInfo.isFromTrackedBars then
        common.print("|cffFF0000SFUI Error:|r Cannot drag icons from Cooldown Panels to Tracked Bars.")
        return
    end

    -- If moved from another panel, remove one instance from the source panel
    if draggedInfo.originalPanelEntries and not draggedInfo.isFromTrackedBars then
        local source = draggedInfo.originalPanelEntries
        for i = #source, 1, -1 do
            local val = source[i]
            local entryId = (type(val) == "table" and (val.cooldownID or val.id)) or val
            if entryId == incomingId then
                table.remove(source, i)
                break -- Only remove the dragged instance
            end
        end
    elseif draggedInfo.isFromTrackedBars and not isTrackedBars then
        -- Moving from Tracked Bars to a custom panel
        common.get_tracked_bars()[incomingId] = nil

        -- Move to a hidden category and save
        local dp = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider and
            CooldownViewerSettings:GetDataProvider()
        if dp then
            local hiddenCategory = -1 -- HiddenSpell
            dp:SetCooldownToCategory(incomingId, hiddenCategory)

            local layoutManager = CooldownViewerSettings and CooldownViewerSettings.GetLayoutManager and
                CooldownViewerSettings:GetLayoutManager()
            if layoutManager and layoutManager.SaveLayouts then
                layoutManager:SaveLayouts()
            end
            ShowReloadPrompt()
        end
    end

    if isTrackedBars then
        -- Add to tracked bars
        common.ensure_tracked_bar_db(incomingId)

        local dp = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider and
            CooldownViewerSettings:GetDataProvider()
        if dp and Enum and Enum.CooldownViewerCategory then
            dp:SetCooldownToCategory(incomingId, 3)
        end

        -- Update immediate
        if sfui.trackedbars and sfui.trackedbars.UpdateVisibility then sfui.trackedbars.UpdateVisibility() end
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end

        common.print("Added to Tracked Bars")
    else
        -- Add to panel
        if not panelData.entries then panelData.entries = {} end

        local entryType = "spell"
        if draggedInfo.cooldownID then
            entryType = "cooldown"
        elseif draggedInfo.info and draggedInfo.info.itemID and draggedInfo.info.itemID > 0 then
            entryType = "item"
        end

        local entry = draggedInfo.entry or {
            id = incomingId,
            type = entryType,
            cooldownID = draggedInfo.cooldownID
        }

        if zoneFrame.dropInsertIndex and zoneFrame.dropInsertIndex <= #panelData.entries then
            table.insert(panelData.entries, zoneFrame.dropInsertIndex, entry)
        else
            table.insert(panelData.entries, entry)
        end

        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
        common.print("Added to " .. (panelData.name or "panel"))
    end

    -- We don't call OnIconDragStop here because OnDragStop will trigger on the icon itself
end

-- Handle drops from Blizzard UI (spellbook, bags, character panel)
HandleExternalDrop = function(zoneFrame, panelData, isTrackedBars)
    -- If an internal drag is active, let OnZoneReceiveDrag handle it via OnMouseUp
    if draggedInfo then return end
    if InCombatLockdown() then return end

    local cursorType, arg1, arg2, arg3 = GetCursorInfo()
    if not cursorType then return end

    local entry = nil
    local draggedSpellID = nil
    local draggedItemID = nil

    if cursorType == "spell" then
        -- cursorType, slot, bookType, spellID
        local spellID = arg3
        if not spellID and type(arg1) == "number" then spellID = arg1 end
        draggedSpellID = spellID
        entry = { id = spellID, type = "spell" }
    elseif cursorType == "item" then
        -- cursorType, itemID, itemLink
        draggedItemID = arg1
        entry = { id = arg1, type = "item" }
    elseif cursorType == "cooldown" or cursorType == "cooldownItem" then
        -- Native 12.0 CooldownViewer drag payload
        entry = { id = arg1, type = "cooldown", cooldownID = arg1 }

        -- Try to resolve spell/item immediately for tooltip correctness
        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(arg1)
        if cdInfo then
            draggedSpellID = (cdInfo.spellID and cdInfo.spellID > 0) and cdInfo.spellID or nil
            draggedItemID = (cdInfo.itemID and cdInfo.itemID > 0) and cdInfo.itemID or nil
        end
    elseif cursorType == "petaction" or cursorType == "macro" then
        common.print("Macros and pet actions are not supported.")
        ClearCursor()
        return
    else
        ClearCursor()
        return
    end

    if not (entry and entry.id) then
        ClearCursor()
        return
    end

    -- Reverse lookup cooldownID from spellID or itemID
    if not entry.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
        local foundCooldownID = nil
        local cats = { -2, -1, 0, 1, 2, 3 }
        if Enum and Enum.CooldownViewerCategory then
            cats = {
                Enum.CooldownViewerCategory.HiddenAura or -2,
                Enum.CooldownViewerCategory.Disabled or -1,
                Enum.CooldownViewerCategory.Essential or 0,
                Enum.CooldownViewerCategory.Utility or 1,
                Enum.CooldownViewerCategory.TrackedBuff or 2,
                3
            }
        end
        for _, cat in ipairs(cats) do
            if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
                local ids = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
                if ids then
                    for _, cid in ipairs(ids) do
                        local cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(cid)
                        if cdInfo then
                            if draggedSpellID and cdInfo.spellID == draggedSpellID then
                                foundCooldownID = cid
                                break
                            elseif draggedItemID and cdInfo.itemID == draggedItemID then
                                foundCooldownID = cid
                                break
                            end
                        end
                    end
                end
            end
            if foundCooldownID then break end
        end
        if foundCooldownID then
            entry.cooldownID = foundCooldownID
            entry.type = "cooldown"
            entry.id = foundCooldownID -- Normalize ID to cooldownID for sfui backend
        end
    end

    local incomingId = entry.id

    -- Debug print to help user verify ID
    if entry.type == "spell" then
        local link = C_Spell.GetSpellLink(incomingId)
        common.print("Imported Spell: " .. (link or incomingId) .. " (ID: " .. incomingId .. ")")
    elseif entry.type == "item" then
        local link = (GetItemInfo and select(2, GetItemInfo(incomingId))) or C_Item.GetItemNameByID(incomingId) or
            incomingId
        common.print("Imported Item: " .. link .. " (ID: " .. incomingId .. ")")
    elseif entry.type == "cooldown" then
        local link = GetCooldownName(incomingId, "spell") or incomingId
        common.print("Imported Cooldown: " .. link .. " (ID: " .. incomingId .. ")")
    end

    if isTrackedBars then
        common.ensure_tracked_bar_db(incomingId)

        local dp = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider and
            CooldownViewerSettings:GetDataProvider()
        if dp and Enum and Enum.CooldownViewerCategory then
            dp:SetCooldownToCategory(incomingId, 3)

            -- Force save Blizzard CooldownViewer settings
            local layoutManager = CooldownViewerSettings and CooldownViewerSettings.GetLayoutManager and
                CooldownViewerSettings:GetLayoutManager()
            if layoutManager and layoutManager.SaveLayouts then
                layoutManager:SaveLayouts()
            end
            ShowReloadPrompt()
        end

        if sfui.trackedbars and sfui.trackedbars.UpdateVisibility then sfui.trackedbars.UpdateVisibility() end
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
        common.print("Added to Tracked Bars and Saved")
    else
        if not panelData.entries then panelData.entries = {} end

        table.insert(panelData.entries, entry)
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
        common.print("Added to " .. (panelData.name or "panel"))
    end

    ClearCursor()
    RefreshZones()
end

OnIconDragStop = function(self)
    if not draggedInfo then return end

    -- Capture info for cleanup
    local targetCursor = draggedInfo.cursor
    local targetIcon = draggedInfo.icon

    -- Hit-test Zones
    local dropTargetZone = nil
    local container = cdmFrame and cdmFrame.leftContent
    if container and container.zoneChildren then
        for _, zone in ipairs(container.zoneChildren) do
            if zone:IsVisible() and zone:IsMouseOver() then
                dropTargetZone = zone
                break
            end
        end
    end

    if dropTargetZone then
        local script = dropTargetZone:GetScript("OnMouseUp")
        if script then script(dropTargetZone) end
    else
        -- Dropped in empty space (Trash)
        if draggedInfo.originalPanelEntries then
            local source = draggedInfo.originalPanelEntries
            local targetId = draggedInfo.entry and (draggedInfo.entry.cooldownID or draggedInfo.entry.id)
            if not targetId then
                targetId = draggedInfo.cooldownID or
                    (draggedInfo.info and (draggedInfo.info.spellID or draggedInfo.info.itemID))
            end

            if targetId then
                if draggedInfo.isFromTrackedBars then
                    source[targetId] = nil

                    -- Move to a hidden category in Blizzard backend and force save
                    local dp = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider and
                        CooldownViewerSettings:GetDataProvider()
                    if dp then
                        -- Hidden categories are defined as: HiddenSpell = -1, HiddenAura = -2
                        -- We try to determine if it's a spell or aura
                        local hiddenCategory = -1 -- Default to HiddenSpell
                        local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(targetId)
                        if cdInfo and cdInfo.itemID and cdInfo.itemID > 0 then
                            -- Items are usually handled as spells/cooldowns, but if it's specifically an aura tracker
                            -- we might want HiddenAura. For now, HiddenSpell is the safest catch-all for bars.
                        end

                        dp:SetCooldownToCategory(targetId, hiddenCategory)

                        local layoutManager = CooldownViewerSettings and CooldownViewerSettings.GetLayoutManager and
                            CooldownViewerSettings:GetLayoutManager()
                        if layoutManager and layoutManager.SaveLayouts then
                            layoutManager:SaveLayouts()
                        end
                        ShowReloadPrompt()
                    end
                else
                    local entries = source -- Assuming 'entries' refers to 'source' in this context
                    local cdID = targetId  -- Assuming 'cdID' refers to 'targetId' in this context
                    for i = #entries, 1, -1 do
                        local val = entries[i]
                        local existingId = (type(val) == "table" and (val.cooldownID or val.id)) or val
                        if existingId == cdID then
                            table.remove(entries, i)
                            break -- Only remove one instance
                        end
                    end
                end

                if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
                common.print("Removed from Zone and Saved")
            end
        end
    end

    -- ALWAYS Cleanup drag
    if targetCursor then targetCursor:Hide() end
    if targetIcon then targetIcon:SetAlpha(1) end
    draggedInfo = nil

    RefreshZones()
end
sfui.cdm.activeZones = {}

function sfui.cdm.UpdateVisibility()
    if not sfui.cdm.activeZones then return end
    local inCombat = InCombatLockdown()
    local isMounted = IsMounted()

    for _, zone in ipairs(sfui.cdm.activeZones) do
        local shouldShow = true
        local panelData = zone.panelData

        if zone.isTrackedBars then
            -- Tracked Bars visibility logic (optional, currently always shown unless empty logic handled elsewhere)
        elseif panelData then
            if panelData.hideOOC and not inCombat then shouldShow = false end

            -- Priority: Combat status always overrides mount/vehicle hide conditions
            if not inCombat then
                if panelData.hideMounted and isMounted then shouldShow = false end
                if panelData.hideInVehicle and (UnitHasVehicleUI("player") or UnitInVehicle("player")) then shouldShow = false end
            end
        end

        if shouldShow then
            zone:Show()
        else
            zone:Hide()
        end
    end
end
