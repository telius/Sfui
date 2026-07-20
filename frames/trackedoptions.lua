local addonName, addon = ...
local CreateFrame = CreateFrame
sfui = sfui or {}
local cfg = sfui.config
local common = sfui.common
sfui.trackedoptions = {}

local CreateFlatButton = common.create_flat_button
local g = cfg
local c = g.options_panel

-- Forward declarations
local select_tab
local UpdateCooldownsList
local wipe = wipe
local tinsert = tinsert
local _emptyTable = {}
local glowTypes = {
    { text = "Pixel",    value = "pixel" },
    { text = "Autocast", value = "autocast" },
    { text = "Action",   value = "proc" },
    { text = "Thick",    value = "proc" }
}
local ReloadUI = ReloadUI or C_UI.Reload
local C_AddOns = C_AddOns

-- Main Options Frame
local frame = CreateFrame("Frame", "SfuiCooldownsViewer", UIParent, "BackdropTemplate")
frame:SetSize(SfuiDB.trackedOptionsWindow and SfuiDB.trackedOptionsWindow.width or 800,
    SfuiDB.trackedOptionsWindow and SfuiDB.trackedOptionsWindow.height or 500)
frame:SetPoint("CENTER")
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Save Size
    if not SfuiDB.trackedOptionsWindow then SfuiDB.trackedOptionsWindow = {} end
    SfuiDB.trackedOptionsWindow.width = self:GetWidth()
    SfuiDB.trackedOptionsWindow.height = self:GetHeight()
end)

-- Custom ESC handler (replaces UISpecialFrames management to avoid closing on spellbook open)
frame:SetPropagateKeyboardInput(true)
frame:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
        if self:IsShown() then
            self:Hide()
        end
    end
end)

-- Make resizable
frame:SetResizable(true)
frame:SetResizeBounds(600, 400, 1200, 800)
local resizeBtn = CreateFrame("Button", nil, frame)
resizeBtn:SetSize(16, 16)
resizeBtn:SetPoint("BOTTOMRIGHT")
resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
resizeBtn:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
resizeBtn:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    if not SfuiDB.trackedOptionsWindow then SfuiDB.trackedOptionsWindow = {} end
    SfuiDB.trackedOptionsWindow.width = frame:GetWidth()
    SfuiDB.trackedOptionsWindow.height = frame:GetHeight()
end)

frame:SetBackdrop({
    bgFile = "Interface/Buttons/WHITE8X8",
    edgeFile = "Interface/Buttons/WHITE8X8",
    edgeSize = 1,
})
frame:SetBackdropColor(c.backdrop_color[1], c.backdrop_color[2], c.backdrop_color[3], c.backdrop_color[4])
frame:SetBackdropBorderColor(unpack(cfg.colors.black))
frame:Hide()
-- tinsert(UISpecialFrames, "SfuiCooldownsViewer") -- Removed to prevent closing when Spellbook/other panels open

-- (Title removed for better space efficiency)

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)

-- === UX Section Container ===
-- Creates a visually distinct section with dark bg, purple left accent, title, and content area.
-- Returns (section, contentFrame, sectionHeight) where contentFrame is the inner area for child widgets.
function sfui.trackedoptions.CreateSection(parent, title, subtitle, yOffset, width)
    local PADDING = 10
    local ACCENT_W = 3
    local TITLE_H = 18
    local SUB_H = subtitle and 14 or 0
    local HEADER_H = PADDING + TITLE_H + (SUB_H > 0 and (SUB_H + 4) or 0) + 4

    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    section:SetPoint("TOPLEFT", 0, yOffset)
    section:SetWidth(width or (parent:GetWidth() - 20))
    section:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
    })
    section:SetBackdropColor(0.06, 0.06, 0.06, 0.9)

    -- Purple left accent stripe
    local accent = section:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("TOPLEFT", 0, 0)
    accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:SetWidth(ACCENT_W)
    accent:SetColorTexture(unpack(cfg.appearance.highlightColor)) -- #6600FF

    -- Title
    local titleFS = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", ACCENT_W + PADDING, -PADDING)
    titleFS:SetTextColor(unpack(cfg.appearance.highlightColor)) -- Purple accent
    titleFS:SetText(title or "")

    -- Subtitle (optional dim description)
    if subtitle then
        local subFS = section:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        subFS:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -4)
        subFS:SetTextColor(0.5, 0.5, 0.5, 1)
        subFS:SetText(subtitle)
    end

    -- Content frame (where child widgets go) - fills section body
    local content = CreateFrame("Frame", nil, section)
    content:SetPoint("TOPLEFT", ACCENT_W + PADDING, -HEADER_H)
    content:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)
    section.content = content
    section._headerH = HEADER_H

    -- Auto-sizing: call section:SetHeight() after adding children
    return section, content, HEADER_H
end

-- Tactical UI Helpers
function sfui.trackedoptions.CreateAnchorGrid(parent, panel, key, onUpdate)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(75, 75)

    local points = {
        { "TOPLEFT",    "TOP",    "TOPRIGHT" },
        { "LEFT",       "CENTER", "RIGHT" },
        { "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }
    }

    container.btns = {}
    for r, row in ipairs(points) do
        for c, point in ipairs(row) do
            local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
            btn:SetSize(22, 22)
            btn:SetPoint("TOPLEFT", (c - 1) * 25, -(r - 1) * 25)
            btn:SetBackdrop({
                bgFile = "Interface/Buttons/WHITE8X8",
                edgeFile = "Interface/Buttons/WHITE8X8",
                edgeSize = 1,
            })
            btn:SetBackdropColor(0.1, 0.1, 0.1, 1)
            btn:SetBackdropBorderColor(unpack(cfg.colors.black))

            btn.point = point
            btn:SetScript("OnClick", function()
                panel[key] = point
                for _, b in ipairs(container.btns) do
                    if b.point == panel[key] then
                        b:SetBackdropBorderColor(unpack(cfg.colors.cyan))
                        b:SetBackdropColor(unpack(cfg.colors.gray))
                    else
                        b:SetBackdropBorderColor(unpack(cfg.colors.black))
                        b:SetBackdropColor(0.1, 0.1, 0.1, 1)
                    end
                end
                if onUpdate then onUpdate() end
            end)

            if panel[key] == point then
                btn:SetBackdropBorderColor(unpack(cfg.colors.cyan))
                btn:SetBackdropColor(unpack(cfg.colors.gray))
            end
            table.insert(container.btns, btn)
        end
    end
    return container
end

function sfui.trackedoptions.CreateGrowthCross(parent, panel, onUpdate)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(75, 75)

    local btns = {
        { point = "Up",     x = 25, y = 0,   label = "U" },
        { point = "Left",   x = 0,  y = -25, label = "L" },
        { point = "Center", x = 25, y = -25, label = "C" },
        { point = "Right",  x = 50, y = -25, label = "R" },
        { point = "Down",   x = 25, y = -50, label = "D" }
    }

    container.btnRefs = {}
    for _, info in ipairs(btns) do
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
        btn:SetSize(22, 22)
        btn:SetPoint("TOPLEFT", info.x, info.y)
        btn:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
            edgeFile = "Interface/Buttons/WHITE8X8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(0.1, 0.1, 0.1, 1)
        btn:SetBackdropBorderColor(unpack(cfg.colors.black))

        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("CENTER")
        text:SetText(info.label)

        btn.growth = info.point
        btn:SetScript("OnClick", function()
            if info.point == "Up" or info.point == "Down" then
                panel.growthV = info.point
            else
                panel.growthH = info.point
            end

            for _, b in ipairs(container.btnRefs) do
                local active = false
                if b.growth == "Up" or b.growth == "Down" then
                    active = (panel.growthV == b.growth)
                else
                    active = (panel.growthH == b.growth)
                end

                if active then
                    b:SetBackdropBorderColor(unpack(cfg.colors.cyan))
                    b:SetBackdropColor(unpack(cfg.colors.gray))
                else
                    b:SetBackdropBorderColor(unpack(cfg.colors.black))
                    b:SetBackdropColor(0.1, 0.1, 0.1, 1)
                end
            end
            if onUpdate then onUpdate() end
        end)

        local active = false
        if info.point == "Up" or info.point == "Down" then
            active = (panel.growthV == info.point)
        else
            active = (panel.growthH == info.point)
        end
        if active then
            btn:SetBackdropBorderColor(unpack(cfg.colors.cyan))
            btn:SetBackdropColor(unpack(cfg.colors.gray))
        end
        table.insert(container.btnRefs, btn)
    end
    return container
end

-- Top Left Buttons (Options & Blizzard)
local headerBtnX = 140
local optBtn = CreateFlatButton(frame, "Main Options", 100, 20)
optBtn:SetPoint("TOPLEFT", 10, -5)
optBtn:SetScript("OnClick", function()
    if sfui.toggle_options_panel then
        sfui.toggle_options_panel()

        -- Attach logic
        if _G.sfui_options_frame and _G.sfui_options_frame:IsShown() then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER") -- Back to center default before re-anchoring if needed

            _G.sfui_options_frame:ClearAllPoints()
            _G.sfui_options_frame:SetPoint("TOPRIGHT", frame, "TOPLEFT", -5, 0)
        end
    end
end)

local blizzBtn = CreateFlatButton(frame, "Blizzard Manager", 120, 20)
blizzBtn:SetPoint("LEFT", optBtn, "RIGHT", 5, 0)
blizzBtn:SetScript("OnClick", function()
    if _G.CooldownViewerSettings then
        if _G.CooldownViewerSettings:IsShown() then
            HideUIPanel(_G.CooldownViewerSettings)
        else
            ShowUIPanel(_G.CooldownViewerSettings)
        end
    end
end)


-- Tab logic
select_tab = function(frame, id)
    if not frame.tabs then return end
    for i, tab in ipairs(frame.tabs) do
        local btn = tab.button
        if i == id then
            -- Selected state
            tab.panel:Show()
            btn.text:SetTextColor(g.colors.cyan[1], g.colors.cyan[2], g.colors.cyan[3])

            -- Render Global Settings
            if id == 2 and sfui.trackedoptions.GenerateGlobalSettingsControls and sfui.trackedoptions.globContent then
                if not sfui.trackedoptions.globContent._generated then
                    sfui.trackedoptions.GenerateGlobalSettingsControls(sfui.trackedoptions.globContent)
                    sfui.trackedoptions.globContent._generated = true
                end
            end
            if id == 3 and sfui.trackedoptions.RenderBarsTab and sfui.trackedoptions.barsContent then
                local currentSpec = common.get_current_spec_id() or 0
                if not sfui.trackedoptions.barsContent._generated or sfui.trackedoptions.barsContent._lastSpec ~= currentSpec then
                    local finalY = sfui.trackedoptions.RenderBarsTab(sfui.trackedoptions.barsContent)
                    if finalY then
                        sfui.trackedoptions.barsContent:SetHeight(math.abs(finalY) + 40)
                    end
                    sfui.trackedoptions.barsContent._generated = true
                    sfui.trackedoptions.barsContent._lastSpec = currentSpec
                end
            end
        else
            -- Deselected state
            tab.panel:Hide()
            btn.text:SetTextColor(g.colors.purple[1], g.colors.purple[2], g.colors.purple[3])
            -- btn:SetBackdropColor(0, 0, 0, 0)
        end
    end
    frame.selectedTabId = id
    SfuiDB.lastSelectedTabId = id -- Persist tab selection
end

function sfui.trackedoptions.toggle_viewer()
    local isShown = frame:IsShown()
    if not isShown then
        frame:SetScript("OnShow", function()
            if InCombatLockdown() then
                common.print("Cannot configure tracked bars in combat.")
                frame:Hide()
                return
            end
            -- Default to Assignments tab
            select_tab(frame, 1)

            if not C_AddOns.IsAddOnLoaded("Blizzard_CooldownViewer") then C_AddOns.LoadAddOn("Blizzard_CooldownViewer") end
        end)
        frame:Show()
    else
        frame:Hide()
    end
end

-- Initialization
function sfui.trackedoptions.initialize()
    if sfui.trackedoptions.initialized then return end
    sfui.trackedoptions.initialized = true

    if not SfuiDB then SfuiDB = {} end
    if not SfuiDB.trackedBars then SfuiDB.trackedBars = {} end

    -- Load Saved Size
    if SfuiDB.trackedOptionsWindow and SfuiDB.trackedOptionsWindow.width and SfuiDB.trackedOptionsWindow.height then
        frame:SetSize(SfuiDB.trackedOptionsWindow.width, SfuiDB.trackedOptionsWindow.height)
    end

    -- Tab Container
    frame.tabs = {}
    local TAB_HEIGHT = 30
    local TAB_WIDTH = 120

    local g = cfg

    local lastBtn
    local function CreateTabButton(text, id)
        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetSize(TAB_WIDTH, TAB_HEIGHT)
        btn:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
        })
        btn:SetBackdropColor(0, 0, 0, 0)

        local t = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
        t:SetPoint("CENTER")
        t:SetText(text)
        btn.text = t

        btn:SetScript("OnClick", function() select_tab(frame, id) end)

        -- Positioning
        if not lastBtn then
            btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -30)
        else
            btn:SetPoint("LEFT", lastBtn, "RIGHT", 5, 0)
        end
        lastBtn = btn

        return btn
    end

    -- Create Tabs
    local assignBtn = CreateTabButton("Assignments", 1)
    local globalBtn = CreateTabButton("Global", 2)
    local barsBtn = CreateTabButton("Bars", 3)


    -- Content Panels
    local assignPanel = CreateFrame("Frame", "SfuiAssignmentsTab", frame)
    assignPanel:SetPoint("TOPLEFT", 10, -65)
    assignPanel:SetPoint("BOTTOMRIGHT", -10, 10)
    assignPanel:Hide()

    local globalPanel = CreateFrame("Frame", "SfuiGlobalTab", frame)
    globalPanel:SetPoint("TOPLEFT", 10, -65)
    globalPanel:SetPoint("BOTTOMRIGHT", -10, 10)
    globalPanel:Hide()

    local barsPanel = CreateFrame("Frame", "SfuiBarsTab", frame)
    barsPanel:SetPoint("TOPLEFT", 10, -65)
    barsPanel:SetPoint("BOTTOMRIGHT", -10, 10)
    barsPanel:Hide()

    -- Populate Tabs Table
    table.insert(frame.tabs, { button = assignBtn, panel = assignPanel })
    table.insert(frame.tabs, { button = globalBtn, panel = globalPanel })
    table.insert(frame.tabs, { button = barsBtn, panel = barsPanel })


    -- === TAB 1: ASSIGNMENTS (CDM) ===
    if sfui.cdm and sfui.cdm.create_panel then
        sfui.cdm.create_panel(assignPanel)
    end

    -- === TAB 2: GLOBAL SETTINGS ===
    local globScroll = CreateFrame("ScrollFrame", "SfuiGlobalScroll", globalPanel, "UIPanelScrollFrameTemplate")
    globScroll:SetPoint("TOPLEFT", 0, 0)
    globScroll:SetPoint("BOTTOMRIGHT", -25, 0)
    local globContent = CreateFrame("Frame", nil, globScroll)
    globContent:SetSize(750, 800)
    globScroll:SetScrollChild(globContent)
    sfui.trackedoptions.globContent = globContent

    local resetGlobalBtn = CreateFlatButton(globContent, "reset defaults", 100, 22)
    resetGlobalBtn:SetPoint("TOPRIGHT", globContent, "TOPRIGHT", -10, -10)
    resetGlobalBtn:SetScript("OnClick", function()
        if SfuiDB.iconGlobalSettings then wipe(SfuiDB.iconGlobalSettings) end
        if sfui.trackedoptions.globContent then sfui.trackedoptions.globContent._generated = nil end
        if sfui.trackedoptions.barsContent then
            sfui.trackedoptions.barsContent._generated = nil
            sfui.trackedoptions.barsContent._lastSpec = nil
        end
        sfui.trackedoptions.UpdateSettings() -- Re-init widgets
        if sfui.trackedicons and sfui.trackedicons.ForceRefreshGlows then sfui.trackedicons.ForceRefreshGlows() end
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
    end)

    -- === TAB 3: BARS SETTINGS ===
    -- Render directly into the bars panel (function handles its own scrolling if needed, or we might need a scrollframe here)
    -- RenderBarsTab uses CreateSection which just puts stuff on the parent.
    -- We probably need a scrollframe for TAB 3 as it's tall.

    local barsScroll = CreateFrame("ScrollFrame", "SfuiBarsScroll", barsPanel, "UIPanelScrollFrameTemplate")
    barsScroll:SetPoint("TOPLEFT", 0, 0)
    barsScroll:SetPoint("BOTTOMRIGHT", -25, 0)
    local barsContent = CreateFrame("Frame", nil, barsScroll)
    barsContent:SetSize(750, 1200) -- Plenty of height for the list
    barsScroll:SetScrollChild(barsContent)
    sfui.trackedoptions.barsContent = barsContent
end

function sfui.trackedoptions.RenderBarsTab(parent)
    if not parent then return end

    if sfui.trackedoptions.ReleaseSettingsWidgets then
        sfui.trackedoptions.ReleaseSettingsWidgets(parent)
    else
        local kids = { parent:GetChildren() }
        for _, kid in ipairs(kids) do kid:Hide() end
    end
    local regions = { parent:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    -- Checkbox list
    -- Build sorted list of trackable spells across supported categories
    local specBars = common.get_tracked_bars()

    local known = {}
    local cats = { 1, 2, 3 } -- Essential, Utility, TrackedBuff, TrackedBars
    local WIDTH = parent:GetWidth() - 40
    local yPos = -10

    local function Refresh()
        if sfui.trackedbars then
            if sfui.trackedbars.InvalidateConfigCache then sfui.trackedbars.InvalidateConfigCache() end
            if sfui.trackedbars.UpdateVisibility then sfui.trackedbars.UpdateVisibility() end
            if sfui.trackedbars.ForceLayoutUpdate then sfui.trackedbars.ForceLayoutUpdate() end
        end
    end

    -- Reuse helpers
    local function BCheck(secContent, label, getter, setter, tooltip, x, y)
        local cb = common.create_checkbox(secContent, label, getter, function(val)
            setter(val)
            Refresh()
        end, tooltip)
        cb:SetPoint("TOPLEFT", x or 0, y)
        return cb
    end

    local function BSlider(secContent, label, getter, minV, maxV, step, setter, x, y, w)
        local s = common.create_slider_input(secContent, label, getter, minV, maxV, step, function(val)
            setter(val)
            Refresh()
        end)
        if w then s:SetWidth(w) end
        s:SetPoint("TOPLEFT", x or 0, y)
        return s
    end

    -- ═══════════════════════════════════
    -- SECTION 1: GLOBAL SETTINGS (2 Columns)
    -- ═══════════════════════════════════
    local db = SfuiDB.trackedBars
    local bar_cfg = sfui.config.trackedBars or {}

    local sec1, sec1c, h1 = sfui.trackedoptions.CreateSection(parent, "Global Bar Settings",
        "Configure defaults for all tracked bars.", yPos, WIDTH)
    sec1:SetPoint("TOPLEFT", 10, yPos)
    local s1y = 0

    -- Col 1: Visibility
    local lVis = sec1c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lVis:SetPoint("TOPLEFT", 0, s1y)
    lVis:SetText("Visibility & Behaviour")

    local function GetB(k, d)
        if db[k] ~= nil then return db[k] end
        if bar_cfg[k] ~= nil then return bar_cfg[k] end
        return d
    end

    BCheck(sec1c, "Hide Out of Combat", function() return GetB("hideOOC", false) end, function(v) db.hideOOC = v end, nil,
        0,
        s1y - 20)
    BCheck(sec1c, "Hide Inactive Bars", function() return GetB("hideInactive", true) end,
        function(v) db.hideInactive = v end, nil,
        0, s1y - 50)
    BCheck(sec1c, "Hide While Mounted", function() return GetB("hideMounted", false) end,
        function(v) db.hideMounted = v end, nil, 0,
        s1y - 80)
    BCheck(sec1c, "Hide While in Vehicle UI", function() return GetB("hideInVehicle", true) end,
        function(v) db.hideInVehicle = v end, nil, 0,
        s1y - 110)

    BCheck(sec1c, "Show Bar Name", function() return GetB("showName", true) end, function(v) db.showName = v end, nil,
        160,
        s1y - 20)
    BCheck(sec1c, "Show Duration", function() return GetB("showDuration", true) end, function(v) db.showDuration = v end,
        nil, 160, s1y - 50)
    BCheck(sec1c, "Show Stack Count", function() return GetB("showStacks", false) end, function(v) db.showStacks = v end, "Show stack counts on the bar icons by default.", 160, s1y - 80)

    -- Col 2: Position & Size
    local col2x = 350
    local lPos = sec1c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lPos:SetPoint("TOPLEFT", col2x, s1y)
    lPos:SetText("Position & Size")

    if not db.anchor then db.anchor = { x = 0, y = 0 } end

    BSlider(sec1c, "X", function() return (db.anchor and db.anchor.x) or (bar_cfg.anchor and bar_cfg.anchor.x) or 0 end, -1000,
        1000, 1,
        function(v)
            if not db.anchor then db.anchor = {} end
            db.anchor.x = v; if sfui.trackedbars.UpdatePosition then sfui.trackedbars.UpdatePosition() end
        end, col2x, s1y - 20, 120)
    BSlider(sec1c, "Y", function() return (db.anchor and db.anchor.y) or (bar_cfg.anchor and bar_cfg.anchor.y) or 0 end, -1000,
        1000, 1,
        function(v)
            if not db.anchor then db.anchor = {} end
            db.anchor.y = v; if sfui.trackedbars.UpdatePosition then sfui.trackedbars.UpdatePosition() end
        end, col2x + 130, s1y - 20, 120)

    BSlider(sec1c, "Width", function() return db.width or bar_cfg.width or 200 end, 50, 600, 1, function(v) db.width = v end,
        col2x, s1y - 60, 120)
    BSlider(sec1c, "Height", function() return db.height or bar_cfg.height or 20 end, 10, 60, 1,
        function(v) db.height = v end, col2x + 130, s1y - 60, 120)

    BSlider(sec1c, "Icon Size", function() return db.iconSize or bar_cfg.icon_size or 20 end, 10, 60, 1,
        function(v) db.iconSize = v end, col2x, s1y - 100, 120)
    BSlider(sec1c, "Spacing", function() return db.spacing or bar_cfg.spacing or 5 end, 0, 30, 1,
        function(v) db.spacing = v end, col2x + 130, s1y - 100, 120)

    sec1:SetHeight(h1 + 150)
    yPos = yPos - sec1:GetHeight() - 20


    -- ═══════════════════════════════════
    -- SECTION 2: APPEARANCE
    -- ═══════════════════════════════════
    local sec2, sec2c, h2 = sfui.trackedoptions.CreateSection(parent, "Appearance",
        "Customize colors and textures.", yPos, WIDTH)
    sec2:SetPoint("TOPLEFT", 10, yPos)
    local s2y = 0

    -- Texture
    local lTex = sec2c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lTex:SetPoint("TOPLEFT", 0, s2y); lTex:SetText("Bar Texture:")
    local barTextures = bar_cfg.barTextures or { { text = "Flat", value = "Interface/Buttons/WHITE8X8" } }
    local texDropDown = common.create_dropdown(sec2c, 160, barTextures,
        function(val)
            db.barTexture = val; Refresh()
        end, db.barTexture or bar_cfg.barTexture)
    texDropDown:SetPoint("LEFT", lTex, "RIGHT", 5, 0)

    -- Backdrop Alpha
    BSlider(sec2c, "Backdrop Alpha", function() return (db.backdropAlpha or 0.5) * 100 end, 0, 100, 1,
        function(v)
            db.backdropAlpha = v / 100; Refresh()
        end, 350, s2y + 10, 200)

    local lCol = sec2c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lCol:SetPoint("TOPLEFT", 0, s2y - 40); lCol:SetText("Default Bar Color:")

    local function CS(l, idx, x)
        return BSlider(sec2c, l, function() return ((db.defaultBarColor or cfg.colors.purple)[idx]) * 255 end, 0,
            255, 1,
            function(v)
                if not db.defaultBarColor then
                    db.defaultBarColor = { cfg.colors.purple[1], cfg.colors
                        .purple[2], cfg.colors.purple[3], 1 }
                end
                db.defaultBarColor[idx] = v / 255; Refresh()
            end, x, s2y - 55, 100)
    end
    CS("R", 1, 0)
    CS("G", 2, 110)
    CS("B", 3, 220)

    sec2:SetHeight(h2 + 100)
    yPos = yPos - sec2:GetHeight() - 20

    -- ═══════════════════════════════════
    -- SECTION 3: INDIVIDUAL BARS (Table Layout)
    -- ═══════════════════════════════════
    local sec3, sec3c, h3 = sfui.trackedoptions.CreateSection(parent, "Individual Bar Settings",
        "Configure specific bars. These settings override globals.", yPos, WIDTH)
    sec3:SetPoint("TOPLEFT", 10, yPos)
    local s3y = 0

    -- Column Headers
    local headerY = s3y
    local function Header(text, x, width)
        local h = sec3c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        h:SetPoint("TOPLEFT", x, headerY)
        if width then h:SetWidth(width) end
        h:SetJustifyH("LEFT")
        h:SetText(text)
        return h
    end

    Header("Spell / Icon", 5, 130)
    Header("Order", 135, 40)
    Header("Show Name", 185, 75)
    Header("Stack Mode", 265, 75)
    Header("Show Stacks", 345, 75)
    Header("To Health", 425, 75)
    Header("Timer", 505, 75)
    Header("Spec Color", 585, 75)
    Header("Custom Color", 665, 80)
    Header("Pandemic", 745, 60)
    Header("P.Col", 815, 60)

    s3y = s3y - 25

    local spells = sfui.trackedbars.GetKnownSpells and sfui.trackedbars.GetKnownSpells()
    
    if spells then
        table.sort(spells, function(a, b)
            local cA = sfui.trackedbars.GetConfig and sfui.trackedbars.GetConfig(a.id) or {}
            local cB = sfui.trackedbars.GetConfig and sfui.trackedbars.GetConfig(b.id) or {}
            local hA = cA.stackAboveHealth and 1 or 0
            local hB = cB.stackAboveHealth and 1 or 0

            -- Group Attached vs Normal first
            if hA ~= hB then return hA > hB end

            -- Then sort by index
            if hA == 1 then
                local idxA = cA.attachedIndex or cA.priority or 100
                local idxB = cB.attachedIndex or cB.priority or 100
                if idxA ~= idxB then return idxA < idxB end
            else
                local idxA = cA.normalIndex or cA.priority or 100
                local idxB = cB.normalIndex or cB.priority or 100
                if idxA ~= idxB then return idxA < idxB end
            end

            return (a.name or "") < (b.name or "")
        end)
    end
    
    local ly = s3y
    if spells then
        for i, info in ipairs(spells) do
            local id = info.id
            local name = info.name or "Unknown"
            local icon = info.icon

            local row = CreateFrame("Frame", nil, sec3c, "BackdropTemplate")
            row:SetSize(WIDTH - 10, 44)
            row:SetPoint("TOPLEFT", 0, ly)
            row:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
            row:SetBackdropColor(0.1, 0.1, 0.1, (i % 2 == 0) and 0.5 or 0.3)

            -- Icon & Name
            local iconTex = row:CreateTexture(nil, "ARTWORK"); iconTex:SetSize(32, 32); iconTex:SetPoint("LEFT", 4, 0); iconTex:SetTexture(icon)
            local lName = row:CreateFontString(nil, "OVERLAY", "GameFontNormal");
            lName:SetPoint("LEFT", iconTex, "RIGHT", 4, 0);
            lName:SetWidth(95); lName:SetWordWrap(false); lName:SetJustifyH("LEFT");
            lName:SetText(name)

            -- Order controls
            local btnUp = CreateFrame("Button", nil, row)
            btnUp:SetSize(16, 16)
            btnUp:SetPoint("LEFT", 140, 6)
            btnUp:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
            btnUp:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up", "ADD")
            
            local btnDown = CreateFrame("Button", nil, row)
            btnDown:SetSize(16, 16)
            btnDown:SetPoint("LEFT", 140, -8)
            btnDown:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
            btnDown:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up", "ADD")

            local function BumpIndex(direction)
                local cfg = sfui.trackedbars.GetConfig and sfui.trackedbars.GetConfig(id) or {}
                local isAttached = cfg.stackAboveHealth
                local curIdx = 100
                
                if isAttached then
                    curIdx = cfg.attachedIndex or cfg.priority or 100
                else
                    curIdx = cfg.normalIndex or cfg.priority or 100
                end
                
                local dbEntry = common.ensure_tracked_bar_db(id)
                if isAttached then
                    dbEntry.attachedIndex = curIdx + direction
                else
                    dbEntry.normalIndex = curIdx + direction
                end
                
                sfui.trackedoptions.RenderBarsTab(parent) 
                Refresh() 
            end
            
            btnUp:SetScript("OnClick", function() BumpIndex(-1) end)
            btnDown:SetScript("OnClick", function() BumpIndex(1) end)

            -- Checkboxes (No labels, centered under headers)
            local function RC(k, tip, x)
                local cb = common.create_checkbox(row, "",
                    function()
                        local dbEntry = specBars and specBars[id]
                        if dbEntry and dbEntry[k] ~= nil then return dbEntry[k] end
                        local cfgEntry = cfg.trackedBars and cfg.trackedBars.defaults and
                            cfg.trackedBars.defaults[id]
                        if cfgEntry and cfgEntry[k] ~= nil then return cfgEntry[k] end
                        -- Defaults for specific keys
                        if k == "showName" then return true end
                        return false
                    end,
                    function(v)
                        common.ensure_tracked_bar_db(id)[k] = v; Refresh()
                    end, tip)
                cb:SetScale(1.0)
                cb:SetPoint("LEFT", x, 0)
                return cb
            end

            -- Helper: determine whether stack+timer mode is active for this bar
            -- (stackMode OR showStacksText is ON, and showDuration not explicitly false)
            local function IsStackTimerMode()
                local dbEntry = specBars and specBars[id]
                local isAttached = (dbEntry and dbEntry.stackAboveHealth) or false
                if isAttached then return false end
                
                local isStack = (dbEntry and (dbEntry.stackMode or dbEntry.showStacksText)) or false
                local timerOff = dbEntry and (dbEntry.showDuration == false)
                return isStack and not timerOff
            end

            -- showName checkbox — greyed-out and forced off in stack+timer mode
            local showNameCB = common.create_checkbox(row, "",
                function()
                    if IsStackTimerMode() then return false end
                    local dbEntry = specBars and specBars[id]
                    if dbEntry and dbEntry.showName ~= nil then return dbEntry.showName end
                    local cfgEntry = cfg.trackedBars and cfg.trackedBars.defaults and cfg.trackedBars.defaults[id]
                    if cfgEntry and cfgEntry.showName ~= nil then return cfgEntry.showName end
                    return true -- default on
                end,
                function(v)
                    if IsStackTimerMode() then return end -- locked out
                    common.ensure_tracked_bar_db(id).showName = v; Refresh()
                end,
                "Show spell name on bar.\nDisabled when Stack Mode + Timer are both active\n(timer is shown in the name slot instead).")
            showNameCB:SetScale(1.0)
            showNameCB:SetPoint("LEFT", 185, 0)

            -- Dim the showName checkbox label/check when locked out
            local function UpdateNameCheckState()
                if IsStackTimerMode() then
                    showNameCB:SetAlpha(0.35)
                    showNameCB:SetEnabled(false)
                else
                    showNameCB:SetAlpha(1.0)
                    showNameCB:SetEnabled(true)
                end
            end
            UpdateNameCheckState()

            -- stackMode checkbox — also triggers showName lock update
            local stackModeCB = common.create_checkbox(row, "",
                function()
                    local dbEntry = specBars and specBars[id]
                    if dbEntry and dbEntry.stackMode ~= nil then return dbEntry.stackMode end
                    return false
                end,
                function(v)
                    common.ensure_tracked_bar_db(id).stackMode = v
                    UpdateNameCheckState()
                    Refresh()
                end,
                "Bar becomes a stack counter\nWhen combined with Timer, the remaining time\nis shown on the left instead of the spell name.")
            stackModeCB:SetScale(1.0)
            stackModeCB:SetPoint("LEFT", 265, 0)
            -- showStacksText checkbox — also triggers showName lock update
            local showStacksTextCB = common.create_checkbox(row, "",
                function()
                    local dbEntry = specBars and specBars[id]
                    if dbEntry and dbEntry.showStacksText ~= nil then return dbEntry.showStacksText end
                    return false
                end,
                function(v)
                    common.ensure_tracked_bar_db(id).showStacksText = v
                    UpdateNameCheckState()
                    Refresh()
                end,
                "Show stack count as text")
            showStacksTextCB:SetScale(1.0)
            showStacksTextCB:SetPoint("LEFT", 345, 0)
            local stackAboveHealthCB = common.create_checkbox(row, "",
                function()
                    local dbEntry = specBars and specBars[id]
                    if dbEntry and dbEntry.stackAboveHealth ~= nil then return dbEntry.stackAboveHealth end
                    return false
                end,
                function(v)
                    common.ensure_tracked_bar_db(id).stackAboveHealth = v
                    UpdateNameCheckState()
                    Refresh()
                end,
                "Attach to Health Bar")
            stackAboveHealthCB:SetScale(1.0)
            stackAboveHealthCB:SetPoint("LEFT", 425, 0)

            -- showDuration (Timer) — update showName lock state when toggled
            local timerCB = common.create_checkbox(row, "",
                function()
                    local dbEntry = specBars and specBars[id]
                    if dbEntry and dbEntry.showDuration ~= nil then return dbEntry.showDuration end
                    return false
                end,
                function(v)
                    common.ensure_tracked_bar_db(id).showDuration = v
                    UpdateNameCheckState()
                    Refresh()
                end,
                "Show cooldown timer.\nWhen combined with Stack Mode, the timer appears\non the left side instead of the spell name.")
            timerCB:SetScale(1.0)
            timerCB:SetPoint("LEFT", 505, 0)

            -- Keep state in sync when the row re-renders (e.g. after RenderBarsTab is called).
            row:SetScript("OnShow", function() UpdateNameCheckState() end)

            RC("useSpecColor", "Use Spec Color (from config)", 585)

            -- Custom Color Swatch
            local swatch = CreateFrame("Button", nil, row, "BackdropTemplate")
            swatch:SetSize(20, 20)
            swatch:SetPoint("LEFT", 665, 0)
            swatch:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8", edgeFile = "Interface/Buttons/WHITE8X8", edgeSize = 1 })
            swatch:SetBackdropBorderColor(unpack(cfg.colors.black))

            local function UpdateSwatch()
                local entry = specBars and specBars[id]
                local cfgEntry = cfg.trackedBars and cfg.trackedBars.defaults and
                    cfg.trackedBars.defaults[id]

                if entry and entry.customColor then
                    swatch:SetBackdropColor(common.unpack_color(entry.customColor))
                elseif cfgEntry and cfgEntry.color then
                    swatch:SetBackdropColor(common.unpack_color(cfgEntry.color))
                else
                    swatch:SetBackdropColor(0.5, 0.5, 0.5, 0.5) -- Grey if no custom color
                end
            end
            UpdateSwatch()

            swatch:SetScript("OnClick", function()
                local entry = common.ensure_tracked_bar_db(id)
                local cfgEntry = cfg.trackedBars and cfg.trackedBars.defaults and
                    cfg.trackedBars.defaults[id]

                local r, g, b, a
                if entry.customColor then
                    r, g, b, a = common.unpack_color(entry.customColor)
                elseif cfgEntry and cfgEntry.color then
                    r, g, b, a = common.unpack_color(cfgEntry.color)
                else
                    r, g, b, a = 1, 1, 1, 1
                end

                local oldColor = { r, g, b, a }
                ColorPickerFrame:SetupColorPickerAndShow({
                    swatchFunc = function()
                        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                        local na = ColorPickerFrame:GetColorAlpha()
                        entry.customColor = { nr, ng, nb, na }
                        UpdateSwatch()
                        Refresh()
                    end,
                    opacityFunc = function()
                        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                        local na = ColorPickerFrame:GetColorAlpha()
                        entry.customColor = { nr, ng, nb, na }
                        UpdateSwatch()
                        Refresh()
                    end,
                    cancelFunc = function()
                        entry.customColor = oldColor
                        UpdateSwatch()
                        Refresh()
                    end,
                    r = r,
                    g = g,
                    b = b,
                    opacity = a,
                    hasOpacity = true,
                })
            end)

            -- Pandemic checkbox
            RC("pandemicEnabled", "Recolor bar when debuff is in pandemic refresh window (≤30% duration left)", 748)

            -- Pandemic Color Swatch (default #ff00ff magenta)
            local DEFAULT_PANDEMIC = { 1, 0, 1, 1 }
            local pSwatch = CreateFrame("Button", nil, row, "BackdropTemplate")
            pSwatch:SetSize(20, 20)
            pSwatch:SetPoint("LEFT", 815, 0)
            pSwatch:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8", edgeFile = "Interface/Buttons/WHITE8X8", edgeSize = 1 })
            pSwatch:SetBackdropBorderColor(unpack(cfg.colors.black))

            local function UpdatePSwatch()
                local entry = specBars and specBars[id]
                local col = (entry and entry.pandemicColor) or DEFAULT_PANDEMIC
                pSwatch:SetBackdropColor(common.unpack_color(col))
            end
            UpdatePSwatch()

            pSwatch:SetScript("OnClick", function()
                local entry = common.ensure_tracked_bar_db(id)
                local r, g, b, a
                if entry.pandemicColor then
                    r, g, b, a = common.unpack_color(entry.pandemicColor)
                else
                    r, g, b, a = common.unpack_color(DEFAULT_PANDEMIC)
                end
                local oldColor = { r, g, b, a }
                ColorPickerFrame:SetupColorPickerAndShow({
                    swatchFunc = function()
                        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                        local na = ColorPickerFrame:GetColorAlpha()
                        entry.pandemicColor = { nr, ng, nb, na }
                        UpdatePSwatch(); Refresh()
                    end,
                    opacityFunc = function()
                        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                        local na = ColorPickerFrame:GetColorAlpha()
                        entry.pandemicColor = { nr, ng, nb, na }
                        UpdatePSwatch(); Refresh()
                    end,
                    cancelFunc = function()
                        entry.pandemicColor = oldColor
                        UpdatePSwatch(); Refresh()
                    end,
                    r = r, g = g, b = b, opacity = a, hasOpacity = true,
                })
            end)

            ly = ly - 46
        end
    end
    sec3:SetHeight(h3 + math.abs(ly - s3y) + 40)

    return yPos
end

-- === SETTINGS GENERATORS ===

function sfui.trackedoptions.UpdateEditor()
    if sfui.trackedoptions.globContent then
        sfui.trackedoptions.GenerateGlobalSettingsControls(sfui.trackedoptions.globContent)
    end
end

function sfui.trackedoptions.GenerateGlobalSettingsControls(parent)
    if not parent then return end

    -- Clear frames and regions to prevent font string accumulation
    if sfui.trackedoptions.ReleaseSettingsWidgets then
        sfui.trackedoptions.ReleaseSettingsWidgets(parent)
    else
        local kids = { parent:GetChildren() }
        for _, kid in ipairs(kids) do kid:Hide() end
    end
    local regions = { parent:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    local igs = SfuiDB.iconGlobalSettings
    local defaults = cfg.icon_panel_global_defaults
    local yPos = -10
    local SEC_W = 520

    -- Global Glow Preview Logic
    local function UpdateGlobalGlowPreview()
        local pf = parent.glowPreview
        if not pf or not pf.icon then return end

        -- Apply square/border style
        if sfui.trackedicons and sfui.trackedicons.ApplyIconBorderStyle then
            sfui.trackedicons.ApplyIconBorderStyle(pf.icon, igs)
        end

        -- Use shared resolver for perfect parity with active icons
        local config = sfui.glows.resolve_config(nil, igs)

        -- Resolve the toggle state (not handled by the visual resolver)
        local isEnabled = igs.readyGlow
        if isEnabled == nil then isEnabled = defaults.readyGlow end

        if isEnabled then
            sfui.glows.start_glow(pf.icon, config)
        else
            sfui.glows.stop_glow(pf.icon)
        end
    end

    local function UpdateAll()
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
        UpdateGlobalGlowPreview()
    end

    -- Reusable factories scoped to current section content frame
    local function MakeCheck(secContent, label, key, tooltip, x, y)
        local cb = common.create_checkbox(secContent, label, function()
            if igs[key] ~= nil then return igs[key] else return defaults[key] end
        end, function(val)
            igs[key] = val
            UpdateAll()
        end, tooltip)
        cb:SetPoint("TOPLEFT", x or 0, y)
        return cb
    end

    local function MakeSlider(secContent, label, key, minVal, maxVal, step, x, y, w)
        local s = common.create_slider_input(secContent, label, function()
            if igs[key] ~= nil then return igs[key] else return defaults[key] end
        end, minVal, maxVal, step or 1, function(val)
            igs[key] = val
            UpdateAll()
        end)
        if w then s:SetWidth(w) end
        s:SetPoint("TOPLEFT", x or 0, y)
        return s
    end

    -- ═══════════════════════════════════
    -- SECTION 1: GLOW EFFECTS
    -- ═══════════════════════════════════
    local sec1, s1c, h1 = sfui.trackedoptions.CreateSection(parent, "Glow Effects",
        "Configure the ready glow animation on icons.", yPos,
        SEC_W)
    local s1y = 0

    MakeCheck(s1c, "Enable Ready Glow", "readyGlow", "Play a glow effect when a cooldown finishes.", 0, s1y)
    MakeCheck(s1c, "Use Spec Color", "useSpecColor", "Use specialization-based color for glows.", 240, s1y)
    s1y = s1y - 30

    -- Glow Type & Color inline
    local lGT = s1c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lGT:SetPoint("TOPLEFT", 0, s1y); lGT:SetText("Type:")
    local gtDropDown = common.create_dropdown(s1c, 100, glowTypes, function(val)
        igs.glowType = val
        UpdateAll()
    end, igs.glowType or defaults.glowType)
    gtDropDown:SetPoint("LEFT", lGT, "RIGHT", 5, 0)

    local lGC = s1c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lGC:SetPoint("LEFT", gtDropDown, "RIGHT", 15, 0); lGC:SetText("Color:")
    local gcSwatch = common.create_color_swatch(s1c, igs.glowColor or defaults.glowColor, function(r, g, b)
        igs.glowColor = { r, g, b, 1 }
        UpdateAll()
    end)
    gcSwatch:SetPoint("LEFT", lGC, "RIGHT", 5, 0)
    s1y = s1y - 35

    -- Sliders in 2-column grid
    MakeSlider(s1c, "Duration (max)", "glow_max_duration", 1, 30, 0.5, 0, s1y, 230)
    MakeSlider(s1c, "Scale", "glowScale", 0.5, 3.0, 0.1, 250, s1y, 230)
    s1y = s1y - 48
    MakeSlider(s1c, "Intensity", "glowIntensity", 0.1, 2.0, 0.1, 0, s1y, 230)
    MakeSlider(s1c, "Speed", "glowSpeed", 0.1, 2.0, 0.1, 250, s1y, 230)
    s1y = s1y - 48
    MakeSlider(s1c, "Lines (Pixel)", "glowLines", 1, 10, 1, 0, s1y, 150)
    MakeSlider(s1c, "Particles", "glowParticles", 1, 10, 1, 170, s1y, 150)
    MakeSlider(s1c, "Thickness", "glowThickness", 1, 5, 1, 340, s1y, 140)
    s1y = s1y - 48

    sec1:SetHeight(h1 + math.abs(s1y) + 8)
    yPos = yPos - sec1:GetHeight() - 10

    -- ═══════════════════════════════════
    -- SECTION 2: VISUAL STATES
    -- ═══════════════════════════════════
    local sec2, s2c, h2 = sfui.trackedoptions.CreateSection(parent, "Visual States",
        "How icons look when on cooldown or unusable.", yPos,
        SEC_W)
    local s2y = 0

    MakeCheck(s2c, "Desaturate on Cooldown", "cooldownDesat", "Turn icons black and white while on cooldown.", 0, s2y)
    MakeCheck(s2c, "Resource Check Tint", "useResourceCheck", "Tint icons blue when out of mana/power.", 240, s2y)
    s2y = s2y - 28

    -- Global Visibility Options
    MakeCheck(s2c, "Hide Out of Combat", "hideOOC", "Global default: Hide panels when out of combat.", 0, s2y)
    MakeCheck(s2c, "Hide While Mounted", "hideMounted", "Global default: Hide panels while mounted.", 240, s2y)
    s2y = s2y - 28
    MakeCheck(s2c, "Hide While in Vehicle UI", "hideInVehicle", "Global default: Hide panels while using vehicle UI.", 0,
        s2y)
    s2y = s2y - 28

    MakeCheck(s2c, "Show Background", "showBackground", "Show a dark background behind the icon panel.", 0, s2y)
    s2y = s2y - 35

    MakeSlider(s2c, "Alpha on Cooldown", "alphaOnCooldown", 0, 1, 0.05, 0, s2y, 230)
    MakeSlider(s2c, "Background Alpha", "backgroundAlpha", 0, 1, 0.05, 250, s2y, 230)
    s2y = s2y - 48

    sec2:SetHeight(h2 + math.abs(s2y) + 8)
    yPos = yPos - sec2:GetHeight() - 10

    -- ═══════════════════════════════════
    -- SECTION 3: TEXT & MISC
    -- ═══════════════════════════════════
    local sec3, s3c, h3 = sfui.trackedoptions.CreateSection(parent, "Text & Misc",
        "Countdown text, Masque support, and text color.", yPos,
        SEC_W)
    local s3y = 0

    MakeCheck(s3c, "Show Cooldown Text", "textEnabled", "Show the numerical countdown on icons.", 0, s3y)
    MakeCheck(s3c, "Enable Masque Support", "enableMasque", "Requires Masque addon and reload.", 240, s3y)
    s3y = s3y - 28
    MakeCheck(s3c, "Enable Tooltips", "showTooltips", "Show tooltips when hovering over icons.", 0, s3y)
    s3y = s3y - 35

    local lTC = s3c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lTC:SetPoint("TOPLEFT", 0, s3y); lTC:SetText("Text Color:")
    local tcSwatch = common.create_color_swatch(s3c, igs.textColor or defaults.textColor, function(r, g, b)
        igs.textColor = { r, g, b, 1 }
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
    end)
    tcSwatch:SetPoint("LEFT", lTC, "RIGHT", 5, 0)
    s3y = s3y - 28

    sec3:SetHeight(h3 + math.abs(s3y) + 8)
    yPos = yPos - sec3:GetHeight() - 10

    -- ═══════════════════════════════════
    -- SECTION 4: STYLE
    -- ═══════════════════════════════════
    local sec4, s4c, h4 = sfui.trackedoptions.CreateSection(parent, "Style",
        "Icon shape and borders.", yPos, SEC_W)
    local s4y = 0

    -- Icon Style checkboxes
    MakeCheck(s4c, "Square Icons", "squareIcons", "Crop round icon edges to make them square.", 0, s4y)
    MakeCheck(s4c, "Show Border", "showBorder", "Show a 2px black border around each icon.", 240, s4y)
    s4y = s4y - 28

    sec4:SetHeight(h4 + math.abs(s4y) + 8)
    yPos = yPos - sec4:GetHeight() - 10

    -- ═══════════════════════════════════
    -- GLOW PREVIEW FRAME (Right Side)
    -- ═══════════════════════════════════
    if not parent.glowPreview then
        local pf = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        pf:SetSize(150, 150)
        pf:SetPoint("TOPLEFT", SEC_W + 30, -40)
        pf:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
        })
        pf:SetBackdropColor(0, 0, 0, 0.5)

        local iconFrame = CreateFrame("Button", nil, pf)
        iconFrame:SetSize(64, 64)
        iconFrame:SetPoint("CENTER")
        iconFrame:EnableMouse(false)

        -- Standard border backdrop (Texture on BACKGROUND layer for correct Z-order)
        local bb = iconFrame:CreateTexture(nil, "BACKGROUND")
        bb:SetAllPoints()
        bb:SetColorTexture(unpack(cfg.colors.black))
        bb:Hide()
        iconFrame.borderBackdrop = bb

        local tex = iconFrame:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(cfg.appearance.addonIcon or "Interface/Icons/Spell_Holy_FlashHeal")
        iconFrame.texture = tex

        -- Masque Support for Glow Preview
        if common.sync_masque then
            common.sync_masque(iconFrame, { Icon = tex })
        end

        pf.icon = iconFrame

        local label = pf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("BOTTOM", 0, 10)
        label:SetText("GLOW PREVIEW")

        parent.glowPreview = pf
    end
    parent.glowPreview:Show()
    UpdateGlobalGlowPreview()
end

local function CreatePreviewGrid(parent, panel)
    if not parent or not panel then return end

    -- Clear preview
    if parent.icons then
        for _, icon in pairs(parent.icons) do icon:Hide() end
    else
        parent.icons = {}
    end

    local numMockIcons = 12
    local size = panel.size or 40
    local spacing = panel.spacing or 2
    local numColumns = panel.columns or 4
    local growthH = panel.growthH or "Right"
    local growthV = panel.growthV or "Down"
    local spanWidth = panel.spanWidth

    -- Mock AutoSpan for preview (use parent width)
    if spanWidth then
        local targetWidth = parent:GetWidth() - 20
        local iconsPerRow = math.min(numColumns, numMockIcons)
        if iconsPerRow > 0 then
            local currentWidth = (iconsPerRow * size) + (math.max(0, iconsPerRow - 1) * spacing)
            if currentWidth < targetWidth then
                if iconsPerRow > 1 then spacing = (targetWidth - (iconsPerRow * size)) / (iconsPerRow - 1) end
            else
                size = (targetWidth - (math.max(0, iconsPerRow - 1) * spacing)) / iconsPerRow
            end
        end
    end

    local hSign = (growthH == "Left") and -1 or 1
    local vSign = (growthV == "Up") and 1 or -1

    for i = 1, numMockIcons do
        if not parent.icons[i] then
            local f = CreateFrame("Button", nil, parent, "BackdropTemplate")
            f:EnableMouse(false)

            -- Standard border backdrop (Texture on BACKGROUND layer for correct Z-order)
            local bb = f:CreateTexture(nil, "BACKGROUND")
            bb:SetAllPoints()
            bb:SetColorTexture(unpack(cfg.colors.black))
            bb:Hide()
            f.borderBackdrop = bb

            f.texture = f:CreateTexture(nil, "OVERLAY")
            f.texture:SetAllPoints()
            f.texture:SetTexture("Interface\\Icons\\Spell_Holy_FlashHeal")
            parent.icons[i] = f
        end
        local icon = parent.icons[i]
        icon:Show()
        icon:SetSize(size, size)

        -- Apply square/border style
        if sfui.trackedicons and sfui.trackedicons.ApplyIconBorderStyle then
            sfui.trackedicons.ApplyIconBorderStyle(icon, panel)
        end

        -- Mirror visual states in preview
        local mockOnCD = (i > (numMockIcons / 2))   -- Half icons "on cooldown"
        local useDesat = panel.cooldownDesat
        if useDesat == nil then useDesat = true end -- fallback same as icon_panel_global_defaults
        icon.texture:SetDesaturated(mockOnCD and useDesat)

        local alpha = 1.0
        if mockOnCD then
            alpha = tonumber(panel.alphaOnCooldown) or 1.0
        end
        icon:SetAlpha(alpha)

        -- Masque Support for Preview
        if common.sync_masque then
            common.sync_masque(icon, { Icon = icon.texture })
        end

        local col = (i - 1) % numColumns
        local row = math.floor((i - 1) / numColumns)

        icon:ClearAllPoints()
        if growthH == "Center" then
            local startIdx = row * numColumns + 1
            local endIdx = math.min((row + 1) * numColumns, numMockIcons)
            local numInRow = endIdx - startIdx + 1
            local colInRow = (i - 1) % numColumns
            local centerOffset = colInRow - (numInRow - 1) / 2
            icon:SetPoint("CENTER", parent, "CENTER", centerOffset * (size + spacing), -row * (size + spacing) * vSign)
        else
            icon:SetPoint("TOPLEFT", parent, "TOPLEFT", 10 + col * (size + spacing) * hSign,
                -10 + row * (size + spacing) * vSign)
        end
    end
end


function sfui.trackedoptions.RenderPanelSettings(parent, panel, xOffset, yOffset, width)
    if not parent or not panel then return 0 end

    local SEC_W = width or 350
    local yPos = yOffset or -5

    -- Reusable factories for panel-specific controls
    local function PCheck(secContent, label, key, tooltip, x, y)
        local cb = common.create_checkbox(secContent, label, function() return panel[key] end, function(val)
            panel[key] = val
            if sfui.trackedoptions.UpdatePreview then sfui.trackedoptions.UpdatePreview() end
            if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
        end, tooltip)
        cb:SetPoint("TOPLEFT", x or 0, y)
        return cb
    end

    local function PSlider(secContent, label, key, minVal, maxVal, step, x, y, w)
        local s = common.create_slider_input(secContent, label, function()
            if panel[key] ~= nil then return panel[key] end
            local igs = SfuiDB.iconGlobalSettings or {}
            if igs[key] ~= nil then return igs[key] end
            local defaults = cfg.icon_panel_global_defaults or {}
            return defaults[key] or 0
        end, minVal, maxVal, step or 1, function(val)
            panel[key] = val
            if sfui.trackedoptions.UpdatePreview then sfui.trackedoptions.UpdatePreview() end
            if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
        end)
        if w then s:SetWidth(w) end
        s:SetPoint("TOPLEFT", x or 0, y)
        return s
    end

    -- ═══════════════════════════════════
    -- SECTION 1: GENERAL
    -- ═══════════════════════════════════
    local sec1, s1c, h1 = sfui.trackedoptions.CreateSection(parent, panel.name or "Panel",
        "Enable, size, and visibility mode.", yPos, SEC_W)
    if xOffset then sec1:SetPoint("TOPLEFT", xOffset, yPos) end
    local s1y = 0

    PCheck(s1c, "Enabled", "enabled", "Enable or disable this icon panel.", 0, s1y)
    PSlider(s1c, "Icon Size", "size", 10, 100, 1, 150, s1y, 140)
    s1y = s1y - 48

    PCheck(s1c, "Hide Out of Combat", "hideOOC", "Hide this panel when not in combat.", 0, s1y)
    PCheck(s1c, "Hide While Mounted", "hideMounted", "Hide this panel when mounted (including Dragonriding).", 150, s1y)
    s1y = s1y - 28
    PCheck(s1c, "Hide While in Vehicle UI", "hideInVehicle", "Hide this panel when using vehicle UI.", 0, s1y)
    s1y = s1y - 28



    PCheck(s1c, "Show Background", "showBackground", "Show a background behind the icons.", 0, s1y)
    PSlider(s1c, "BG Opacity", "backgroundAlpha", 0, 1, 0.05, 150, s1y, 140)
    s1y = s1y - 35

    sec1:SetHeight(h1 + math.abs(s1y) + 10)
    yPos = yPos - sec1:GetHeight() - 8

    -- ═══════════════════════════════════
    -- SECTION 2: LAYOUT
    -- ═══════════════════════════════════
    local sec2, s2c, h2 = sfui.trackedoptions.CreateSection(parent, "Layout", "Grid size, spacing, and growth direction.",
        yPos, SEC_W)
    if xOffset then sec2:SetPoint("TOPLEFT", xOffset, yPos) end
    local s2y = 0

    PSlider(s2c, "Spacing", "spacing", -20, 40, 1, 0, s2y, 140)
    PSlider(s2c, "Columns", "columns", 1, 20, 1, 155, s2y, 140)
    s2y = s2y - 48

    PCheck(s2c, "Span Width", "spanWidth", "Auto-scale icons to fill the target frame width.", 0, s2y)
    s2y = s2y - 35

    local lG = s2c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lG:SetPoint("TOPLEFT", 0, s2y); lG:SetText("Growth:")
    local lAP = s2c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lAP:SetPoint("TOPLEFT", 130, s2y); lAP:SetText("Anchor Point:")
    s2y = s2y - 18

    local growthCross = sfui.trackedoptions.CreateGrowthCross(s2c, panel, function()
        if sfui.trackedoptions.UpdatePreview then sfui.trackedoptions.UpdatePreview() end
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
    end)
    growthCross:SetPoint("TOPLEFT", 0, s2y)

    local anchorGrid = sfui.trackedoptions.CreateAnchorGrid(s2c, panel, "anchorPoint", function()
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
    end)
    anchorGrid:SetPoint("TOPLEFT", 130, s2y)
    s2y = s2y - 85

    sec2:SetHeight(h2 + math.abs(s2y) + 8)
    yPos = yPos - sec2:GetHeight() - 8

    -- ═══════════════════════════════════
    -- SECTION 3: ANCHORING
    -- ═══════════════════════════════════
    local sec3, s3c, h3 = sfui.trackedoptions.CreateSection(parent, "Anchoring",
        "Where this panel attaches and its offset.", yPos, SEC_W)
    if xOffset then sec3:SetPoint("TOPLEFT", xOffset, yPos) end
    local s3y = 0

    local lA = s3c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lA:SetPoint("TOPLEFT", 0, s3y); lA:SetText("Anchor To:")
    local anchorTargets = common.get_all_anchor_targets(panel.name)
    local anchorTo = common.create_dropdown(s3c, 130, anchorTargets, function(val)
        panel.anchorTo = val
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
    end, panel.anchorTo)
    anchorTo:SetPoint("LEFT", lA, "RIGHT", 5, 0)

    local lRP = s3c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lRP:SetPoint("TOPLEFT", 0, s3y - 30); lRP:SetText("Relative Pt:")
    local points = {
        { text = "Top",  value = "TOP" }, { text = "Bottom", value = "BOTTOM" },
        { text = "Left", value = "LEFT" }, { text = "Right", value = "RIGHT" },
        { text = "Center",   value = "CENTER" }, { text = "TopLeft", value = "TOPLEFT" },
        { text = "TopRight", value = "TOPRIGHT" }, { text = "BottomLeft", value = "BOTTOMLEFT" },
        { text = "BottomRight", value = "BOTTOMRIGHT" }
    }
    local rPoint = common.create_dropdown(s3c, 130, points, function(val)
        panel.relativePoint = val
        if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
    end, panel.relativePoint)
    rPoint:SetPoint("LEFT", lRP, "RIGHT", 5, 0)
    s3y = s3y - 65

    PSlider(s3c, "Offset X", "x", -1000, 1000, 1, 0, s3y, 140)
    PSlider(s3c, "Offset Y", "y", -1000, 1000, 1, 155, s3y, 140)
    s3y = s3y - 48

    sec3:SetHeight(h3 + math.abs(s3y) + 8)
    yPos = yPos - sec3:GetHeight() - 8

    -- ═══════════════════════════════════
    -- SECTION 4: INDIVIDUAL ICON OVERRIDES
    -- ═══════════════════════════════════
    if panel.entries and #(panel.entries) > 0 then
        local sec4, s4c, h4 = sfui.trackedoptions.CreateSection(parent, "Hero Talent Overrides",
            "Show these assigned icons ONLY when a specific Hero Talent is active.", yPos, SEC_W)
        if xOffset then sec4:SetPoint("TOPLEFT", xOffset, yPos) end
        local s4y = 0

        local _, _, classID = UnitClass("player")
        -- Per Blizzard source, calling without args defaults to player config/spec
        local heroSpecs = C_ClassTalents and C_ClassTalents.GetHeroTalentSpecsForClassSpec() or {}

        -- Draw Header
        local hIcon = s4c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hIcon:SetPoint("TOPLEFT", 10, s4y); hIcon:SetWidth(150); hIcon:SetJustifyH("LEFT"); hIcon:SetText(
            "Assigned Spell")

        local hFilter = s4c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hFilter:SetPoint("TOPLEFT", 170, s4y); hFilter:SetWidth(150); hFilter:SetJustifyH("LEFT"); hFilter:SetText(
            "Filter")
        s4y = s4y - 25

        for i, entry in ipairs(panel.entries) do
            local id = (type(entry) == "table" and entry.id) or entry
            local typeHint = (type(entry) == "table" and entry.type) or "spell"

            -- Ensure entry is a table to store settings
            if type(entry) ~= "table" then
                entry = { id = id, type = typeHint, cooldownID = id }
                panel.entries[i] = entry
            end
            if not entry.settings then entry.settings = {} end

            local name = ""
            local nid = tonumber(id)

            if nid then
                if typeHint == "item" then
                    name = C_Item.GetItemNameByID(nid) or ("Item: " .. nid)
                elseif typeHint == "spell" then
                    name = C_Spell.GetSpellName(nid) or ("Spell: " .. nid)
                else
                    -- Resolve 'cooldown' type to its underlying name
                    local cdInfo = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo(nid)
                    if cdInfo then
                        if cdInfo.spellID and cdInfo.spellID > 0 then
                            name = C_Spell.GetSpellName(cdInfo.spellID) or ("Spell: " .. cdInfo.spellID)
                        elseif cdInfo.itemID and cdInfo.itemID > 0 then
                            name = C_Item.GetItemNameByID(cdInfo.itemID) or ("Item: " .. cdInfo.itemID)
                        end
                    end
                end
            end
            if not name or name == "" then name = "Unknown (" .. (id or "nil") .. ")" end

            local row = CreateFrame("Frame", nil, s4c, "BackdropTemplate")
            row:SetSize(SEC_W - 10, 36)
            row:SetPoint("TOPLEFT", 0, s4y)
            row:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
            row:SetBackdropColor(0.1, 0.1, 0.1, (i % 2 == 0) and 0.5 or 0.3)

            -- Icon
            local iconTex = row:CreateTexture(nil, "ARTWORK")
            iconTex:SetSize(24, 24)
            iconTex:SetPoint("LEFT", 4, 0)
            local tex, _ = sfui.trackedicons.GetIconTexture(id, typeHint, entry)
            iconTex:SetTexture(tex or 134400)

            local lName = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lName:SetPoint("LEFT", iconTex, "RIGHT", 8, 0)
            lName:SetWidth(120); lName:SetJustifyH("LEFT")
            lName:SetText(name)

            -- Hero Talent buttons
            local bx = 165
            if not entry.settings.heroTalentWhitelist then entry.settings.heroTalentWhitelist = {} end
            local whitelist = entry.settings.heroTalentWhitelist

            -- Migrate old generic setting to the whitelist
            if entry.settings.heroTalentFilter and entry.settings.heroTalentFilter ~= "Any" and entry.settings.heroTalentFilter ~= 0 then
                whitelist[entry.settings.heroTalentFilter] = true
                entry.settings.heroTalentFilter = nil
            end

            -- Migrate old disabled setting to whitelist
            if entry.settings.heroTalentsDisabled then
                for _, hInfo in ipairs(heroSpecs) do
                    if not entry.settings.heroTalentsDisabled[hInfo] then
                        local allEnabled = true
                        for _, h in ipairs(heroSpecs) do
                            if entry.settings.heroTalentsDisabled[h] then allEnabled = false end
                        end
                        if not allEnabled then
                            whitelist[hInfo] = true
                        end
                    end
                end
                entry.settings.heroTalentsDisabled = nil
            end

            local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()

            local function CreateHeroBtn(heroInfo, xPos)
                local btn = CreateFrame("Button", nil, row, "BackdropTemplate")
                btn:SetSize(24, 24)
                btn:SetPoint("LEFT", xPos, 0)

                local tex = btn:CreateTexture(nil, "ARTWORK")
                tex:SetAllPoints()
                local traitInfo = configID and C_Traits and C_Traits.GetSubTreeInfo and
                    C_Traits.GetSubTreeInfo(configID, heroInfo)
                if traitInfo and traitInfo.iconElementID then
                    if type(traitInfo.iconElementID) == "number" then
                        tex:SetTexture(traitInfo.iconElementID)
                    else
                        tex:SetAtlas(traitInfo.iconElementID)
                    end
                else
                    tex:SetTexture(134400)
                end

                -- Inside border to indicate selection like tracked icon pool
                btn:SetBackdrop({
                    edgeFile = "Interface/Buttons/WHITE8X8",
                    edgeSize = 2,
                })

                local function UpdateVisuals()
                    if whitelist[heroInfo] then
                        btn:SetBackdropBorderColor(unpack(cfg.colors.cyan)) -- Active = Cyan
                        tex:SetDesaturated(false)
                        tex:SetVertexColor(1, 1, 1)
                    else
                        btn:SetBackdropBorderColor(unpack(cfg.colors.black)) -- Inactive = Black
                        tex:SetDesaturated(true)
                        tex:SetVertexColor(0.5, 0.5, 0.5)
                    end
                end
                UpdateVisuals()

                btn:SetScript("OnClick", function()
                    whitelist[heroInfo] = not whitelist[heroInfo]
                    UpdateVisuals()
                    if sfui.trackedicons and sfui.trackedicons.Update then sfui.trackedicons.Update() end
                end)

                btn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    local tInfo = configID and C_Traits and C_Traits.GetSubTreeInfo and
                        C_Traits.GetSubTreeInfo(configID, heroInfo)
                    GameTooltip:SetText(tInfo and tInfo.name or "Unknown Spec")
                    if whitelist[heroInfo] then
                        GameTooltip:AddLine("Filter: ENABLED (Only show in this spec)", 0, 1, 0)
                    else
                        GameTooltip:AddLine("Filter: DISABLED (Always show)", 0.6, 0.6, 0.6)
                    end
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Masque sync just to make it square if the user prefers, but left as default works too
                if common.sync_masque then
                    common.sync_masque(btn, { Icon = tex, Border = nil })
                end

                return btn
            end

            -- Hero Talent Buttons
            for _, hID in ipairs(heroSpecs) do
                CreateHeroBtn(hID, bx)
                bx = bx + 30
            end

            s4y = s4y - 38
        end

        sec4:SetHeight(h4 + math.abs(s4y) + 8)
        yPos = yPos - sec4:GetHeight() - 8
    end

    return yPos
end

function sfui.trackedoptions.ReleaseSettingsWidgets(parent)
    if not parent then return end
    local kids = { parent:GetChildren() }
    for _, kid in ipairs(kids) do
        kid:Hide()
    end
    local regions = { parent:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end
end

sfui.trackedoptions.UpdateSettings = sfui.trackedoptions.UpdateEditor
