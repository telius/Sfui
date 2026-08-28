local addonName, addon = ...
local _G = _G
local select, unpack, ipairs, pairs, type, tostring, table, print = _G.select, _G.unpack, _G.ipairs, _G.pairs, _G.type,
    _G.tostring, _G.table, _G.print
local CreateFrame = _G.CreateFrame
local C_Garrison, C_Traits, C_AddOns, C_Covenants = _G.C_Garrison, _G.C_Traits, _G.C_AddOns, _G.C_Covenants
local GameTooltip = sfui.tooltip or _G.GameTooltip
local ShowUIPanel, HideUIPanel = _G.ShowUIPanel, _G.HideUIPanel
local GenericTraitUI_LoadUI, OrderHall_LoadUI = _G.GenericTraitUI_LoadUI, _G.OrderHall_LoadUI

sfui = sfui or {}
sfui.research = {}



sfui.research.talentTrees = {
    ["Midnight"] = {
        { isTraitTree = true, id = 1191, name = "Altar of Corrosion" },
        { isTraitTree = true, id = 1186, name = "Omnium Folio" },
        { isTraitTree = true, id = 1166, name = "Zul'Aman Loa Blessing" },
        { isTraitTree = true, id = 1192, name = "Coiled Isle System (1192)" },
        { isTraitTree = true, id = 1190, name = "Atal'Utek Vaults (1190)" },
        { isTraitTree = true, id = 1185, name = "Companion Perks (1185)" },
        { isTraitTree = true, id = 1182, name = "Class Talents Primary (1182)" },
        { isTraitTree = true, id = 1181, name = "Class Talents Secondary (1181)" },
        { isTraitTree = true, id = 1180, name = "Void Research (1180)" },
        { isTraitTree = true, id = 1179, name = "Void Research Aux (1179)" },
        { isTraitTree = true, id = 1177, name = "Valeera Delve Season 2 (1177)" },
        { isTraitTree = true, id = 1176, name = "Delve Companion Abilities (1176)" },
        { isTraitTree = true, id = 1175, name = "Delve Combat Spec (1175)" },
        { isTraitTree = true, id = 1173, name = "Delve Utility Spec (1173)" },
        { isTraitTree = true, id = 1168, name = "Valeera Delve Season 1 (1168)" },
        { type = 111,         id = 499,  name = "Loa Blessings" },
    },
    ["The War Within"] = {
        { isTraitTree = true, id = 1115, name = "Reshii Wraps" },
        { isTraitTree = true, id = 672,  name = "Dragonriding" },
        { isTraitTree = true, id = 1151, name = "Brann Delve Season 3" },
        { isTraitTree = true, id = 1061, name = "Titan Console" },
        { isTraitTree = true, id = 1057, name = "Visions" },
        { isTraitTree = true, id = 1056, name = "Drive" },
        { isTraitTree = true, id = 1060, name = "Brann Delve Season 2" },
        { isTraitTree = true, id = 1046, name = "The Vizier" },
        { isTraitTree = true, id = 1045, name = "The General" },
        { isTraitTree = true, id = 1042, name = "The Weaver" },
        { isTraitTree = true, id = 874,  name = "Brann Delve Season 1" },
    },
    ["Dragonflight"] = {
        { isTraitTree = true, id = 672, name = "Dragonriding" },
        { type = 111,         id = 489, name = "Expedition Supplies" },
        { type = 111,         id = 493, name = "Cobalt Assembly Arcana" },
        { type = 111,         id = 486, name = "Select Your Companion" },
        { type = 111,         id = 491, name = "Hunting Party Loadout" },
    },
    ["Shadowlands"] = {
        { type = 111, id = 461, name = "The Box of Many Things" },
        { type = 111, id = 474, name = "Cypher Research Console" },
        { type = 111, id = 476, name = "Pocopoc Customization" },
        ["Kyrian"] = {
            covenantID = 1,
            { type = 111, id = 308, name = "Transport Network" },
            { type = 111, id = 312, name = "Anima Conductor" },
            { type = 111, id = 316, name = "Command Table" },
            { type = 111, id = 320, name = "Path of Ascension" },
            { type = 111, id = 357, name = "Pelagos" },
            { type = 111, id = 360, name = "Kleia" },
            { type = 111, id = 365, name = "Mikanikos" },
        },
        ["Venthyr"] = {
            covenantID = 2,
            { type = 111, id = 309, name = "Transport Network" },
            { type = 111, id = 314, name = "Anima Conductor" },
            { type = 111, id = 317, name = "Command Table" },
            { type = 111, id = 324, name = "The Ember Court" },
            { type = 111, id = 368, name = "Nadjia the Mistblade" },
            { type = 111, id = 392, name = "Theotar the Mad Duke" },
            { type = 111, id = 304, name = "General Draven" },
        },
        ["Night Fae"] = {
            covenantID = 3,
            { type = 111, id = 307, name = "Transport Network" },
            { type = 111, id = 311, name = "Anima Conductor" },
            { type = 111, id = 315, name = "Command Table" },
            { type = 111, id = 319, name = "The Queen's Conservatory" },
            { type = 111, id = 275, name = "Dreamweaver" },
            { type = 111, id = 276, name = "Niya" },
            { type = 111, id = 334, name = "Korayn" },
        },
        ["Necrolord"] = {
            covenantID = 4,
            { type = 111, id = 310, name = "Transport Network" },
            { type = 111, id = 313, name = "Anima Conductor" },
            { type = 111, id = 318, name = "Command Table" },
            { type = 111, id = 321, name = "Abomination Factory" },
            { type = 111, id = 325, name = "Plague Deviser Marileth" },
            { type = 111, id = 330, name = "Emeni" },
            { type = 111, id = 349, name = "Bonesmith Heirmir" },
        },
    },
}

local selectedTreeInfo = nil

function sfui.research.initialize()
    local original = C_Garrison.GetCurrentGarrTalentTreeID
    C_Garrison.GetCurrentGarrTalentTreeID = function()
        if selectedTreeInfo and not selectedTreeInfo.isTraitTree then
            return selectedTreeInfo.id
        end
        return original()
    end

    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(_, _, addonName)
        if addonName == "Blizzard_OrderHallUI" then
            sfui.research.apply_side_buttons(OrderHallTalentFrame)
        elseif addonName == "Blizzard_GenericTraitUI" then
            sfui.research.apply_side_buttons(GenericTraitFrame)
        end
    end)

    if C_AddOns.IsAddOnLoaded("Blizzard_OrderHallUI") then
        sfui.research.apply_side_buttons(OrderHallTalentFrame)
    end
    if C_AddOns.IsAddOnLoaded("Blizzard_GenericTraitUI") then
        sfui.research.apply_side_buttons(GenericTraitFrame)
    end
end

function sfui.research.open_tree(data)
    if not data then return end
    selectedTreeInfo = data
    SfuiDB.last_research_tree = data

    if data.isTraitTree then
        GenericTraitUI_LoadUI()
        local systemID = C_Traits.GetSystemIDByTreeID(data.id)
        if not systemID then return end

        GenericTraitFrame:Hide()
        if GenericTraitFrame.SetConfigIDBySystemID then
            GenericTraitFrame:SetConfigIDBySystemID(systemID)
        else
            GenericTraitFrame:SetSystemID(systemID)
        end
        GenericTraitFrame:SetTreeID(data.id)
        ShowUIPanel(GenericTraitFrame)
    else
        OrderHall_LoadUI()
        OrderHallTalentFrame:SetGarrisonType(data.type, data.id)
        ShowUIPanel(OrderHallTalentFrame)
    end
end

function sfui.research.toggle_selection()
    if not selectedTreeInfo then
        selectedTreeInfo = SfuiDB.last_research_tree or sfui.research.talentTrees["The War Within"][1]
    end

    local frame = OrderHallTalentFrame or GenericTraitFrame
    if frame and frame:IsShown() then
        HideUIPanel(frame)
    else
        sfui.research.open_tree(selectedTreeInfo)
    end
end

local function create_sfui_button(parent, text, width, height, tooltip)
    local btn = sfui.common.create_styled_button(parent, text, width, height)
    btn:SetBackdropColor(0.05, 0.05, 0.05, 0.9)

    btn.text:ClearAllPoints()
    btn.text:SetPoint("LEFT", 5, 0)
    btn.text:SetPoint("RIGHT", -5, 0)
    btn.text:SetWordWrap(false)

    function btn:SetSelected(selected)
        self.isSelected = selected
        if selected then
            self:SetBackdropBorderColor(unpack(sfui.config.colors.purple))
        else
            self:SetBackdropBorderColor(unpack(sfui.config.colors.black))
        end
    end

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.15, 0.15, 0.15, 1)
        if not self.isSelected then
            self:SetBackdropBorderColor(unpack(sfui.config.colors.cyan))
        end
        if tooltip or (self.text.IsTruncated and self.text:IsTruncated()) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip or self.text:GetText(), 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        if self.isSelected then
            self:SetBackdropBorderColor(unpack(sfui.config.colors.purple))
        else
            self:SetBackdropBorderColor(unpack(sfui.config.colors.black))
        end
        GameTooltip:Hide()
    end)
    return btn
end

function sfui.research.apply_side_buttons(parent)
    if not parent or parent.sfui_side_buttons then return end

    local side_frame = CreateFrame("Frame", nil, parent)
    side_frame:SetSize(130, 400)
    side_frame:SetPoint("TOPLEFT", parent, "TOPRIGHT", 10, -30)
    side_frame:SetFrameStrata("HIGH")
    side_frame:SetFrameLevel(parent:GetFrameLevel() + 10)
    parent.sfui_side_buttons = side_frame

    -- Custom ID Input Box
    local custom_input = CreateFrame("EditBox", nil, side_frame, "InputBoxTemplate")
    custom_input:SetSize(60, 20)
    custom_input:SetPoint("TOPLEFT", 5, -5)
    custom_input:SetAutoFocus(false)
    custom_input:SetText("")

    local trait_btn = create_sfui_button(side_frame, "T", 25, 20, "Trait Tree (Dragonriding, Delves, etc.)")
    trait_btn:SetPoint("LEFT", custom_input, "RIGHT", 5, 0)
    trait_btn:SetScript("OnClick", function()
        local id = tonumber(custom_input:GetText())
        if id then sfui.research.open_tree({ id = id, isTraitTree = true, name = "Custom " .. id }) end
    end)

    local garr_btn = create_sfui_button(side_frame, "G", 25, 20, "Garrison Tree (Class Halls, Covenants, etc.)")
    garr_btn:SetPoint("LEFT", trait_btn, "RIGHT", 5, 0)
    garr_btn:SetScript("OnClick", function()
        local id = tonumber(custom_input:GetText())
        if id then sfui.research.open_tree({ id = id, isTraitTree = false, type = 111, name = "Custom " .. id }) end
    end)

    local tree_frame = CreateFrame("Frame", nil, side_frame)
    tree_frame:SetSize(180, 500)
    tree_frame:SetPoint("TOPLEFT", side_frame, "TOPRIGHT", 10, 0)
    tree_frame:Hide()

    local activeExpBtn, activeTreeBtn

    local function clear_tree_buttons()
        if tree_frame.labels then
            for _, el in ipairs(tree_frame.labels) do el:Hide() end
        end
        if tree_frame.buttons then
            for _, el in ipairs(tree_frame.buttons) do el:Hide() end
        end
        tree_frame.labels = tree_frame.labels or {}
        tree_frame.buttons = tree_frame.buttons or {}
        activeTreeBtn = nil
    end

    local function show_expansion_trees(list)
        clear_tree_buttons()
        tree_frame:Show()

        local yOffset = 0
        local labelIndex = 1
        local buttonIndex = 1

        local playerCovenant = C_Covenants.GetActiveCovenantID()

        local function populate(items)
            local keys = {}
            for k in pairs(items) do table.insert(keys, k) end
            table.sort(keys, function(a, b)
                if type(a) == "number" and type(b) == "number" then return a < b end
                return tostring(a) < tostring(b)
            end)

            for _, k in ipairs(keys) do
                local v = items[k]
                if type(v) == "table" and v.covenantID and v.covenantID ~= playerCovenant then
                    -- Skip
                elseif type(v) == "table" and not v.id then
                    -- Category Label
                    local label = tree_frame.labels[labelIndex]
                    if not label then
                        label = tree_frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                        tree_frame.labels[labelIndex] = label
                    end
                    label:ClearAllPoints()
                    label:SetPoint("TOPLEFT", 5, yOffset - 5)
                    label:SetText("|cff00ffff" .. k .. "|r")
                    label:Show()
                    yOffset = yOffset - 20
                    labelIndex = labelIndex + 1
                    populate(v)
                elseif type(v) == "table" and v.id then
                    -- Tree Button
                    local btn = tree_frame.buttons[buttonIndex]
                    if not btn then
                        btn = create_sfui_button(tree_frame, "", 170, 24)
                        tree_frame.buttons[buttonIndex] = btn
                    end
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", 0, yOffset)
                    btn.text:SetText(v.name or "Tree " .. v.id)
                    btn:SetSelected(activeTreeBtn == btn)

                    local isAvailable = true
                    if v.isTraitTree then
                        local systemID = C_Traits.GetSystemIDByTreeID(v.id)
                        if not systemID then isAvailable = false end
                    end

                    if not isAvailable then
                        btn.text:SetTextColor(0.5, 0.5, 0.5)
                        btn:SetScript("OnClick",
                            function() sfui.common.print("Tree " .. v.id .. " is not available on this character.") end)
                    else
                        btn.text:SetTextColor(1, 1, 1)
                        btn:SetScript("OnClick", function()
                            if activeTreeBtn then activeTreeBtn:SetSelected(false) end
                            activeTreeBtn = btn
                            btn:SetSelected(true)
                            sfui.research.open_tree(v)
                        end)
                    end

                    btn:Show()
                    yOffset = yOffset - 26
                    buttonIndex = buttonIndex + 1
                end
            end
        end
        populate(list)
    end

    local expansions = { "Midnight", "The War Within", "Dragonflight", "Shadowlands" }
    local yOffset = -35
    for _, exp in ipairs(expansions) do
        local btn = create_sfui_button(side_frame, exp, 120, 30)
        btn:SetPoint("TOPLEFT", 0, yOffset)
        btn.text:SetPoint("CENTER")
        btn:SetScript("OnClick", function()
            if activeExpBtn then activeExpBtn:SetSelected(false) end
            activeExpBtn = btn
            btn:SetSelected(true)
            show_expansion_trees(sfui.research.talentTrees[exp])
        end)
        yOffset = yOffset - 35
    end
end
