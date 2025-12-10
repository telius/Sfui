-- options.lua for sfui
-- author: teli

-- shortcuts for the config tables
local c = sfui.config.options_panel
local g = sfui.config

local frame -- this will hold our main frame once it's created

-- this function is now local to the file and shared by all other functions here
local function select_tab(selected_tab_button)
    if not frame or not frame.tabs then return end

    for _, tab_data in ipairs(frame.tabs) do
        tab_data.button:GetFontString():SetTextColor(c.tabs.color.r, c.tabs.color.g, c.tabs.color.b)
        tab_data.panel:Hide()
    end
    selected_tab_button.panel:Show()
    selected_tab_button:GetFontString():SetTextColor(c.tabs.selected_color.r, c.tabs.selected_color.g, c.tabs.selected_color.b)
    frame.selected_tab = selected_tab_button
end

function sfui.create_options_panel()
    if frame then return end

    frame = CreateFrame("Frame", "sfui_options_frame", UIParent, "BackdropTemplate")
    frame:SetSize(c.width, c.height)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = g.textures.white,
        tile = true, tileSize = 32,
    })
    frame:SetBackdropColor(c.backdrop_color.r, c.backdrop_color.g, c.backdrop_color.b, c.backdrop_color.a)
    frame:Hide()
    frame.tabs = {}

    local header_text = frame:CreateFontString(nil, "OVERLAY", g.font_large)
    header_text:SetPoint("TOP", frame, "TOP", 0, -10)
    header_text:SetTextColor(g.header_color[1], g.header_color[2], g.header_color[3])
    header_text:SetText(g.title .. " v" .. g.version)

    -- Add Close Button
    local close_button = CreateFrame("Button", "sfui_options_close_button", frame, "UIPanelButtonTemplate")
    close_button:SetSize(24, 24)
    close_button:SetPoint("TOPRIGHT", -5, -5)
    close_button:SetNormalFontObject(g.font_large)
    close_button:SetText("X")
    close_button:SetScript("OnClick", function()
        frame:Hide()
    end)
    close_button:SetScript("OnEnter", function(self)
        self:GetFontString():SetTextColor(1, 0, 0) -- Red on hover
    end)
    close_button:SetScript("OnLeave", function(self)
        self:GetFontString():SetTextColor(1, 1, 1) -- White normally
    end)

    local function CreateCheckbox(parent, label, dbKey, onClickFunc, tooltip)
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetHitRectInsets(0, -100, 0, 0)
        cb.text:SetText(label)
        cb:SetScript("OnClick", function(self)
            local checked = self:GetChecked()
            SfuiDB[dbKey] = checked
            if onClickFunc then onClickFunc(checked) end
        end)
        cb:SetScript("OnShow", function(self)
            self:SetChecked(SfuiDB[dbKey])
        end)
        if tooltip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(tooltip)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
        end
        return cb
    end

    local function CreateSlider(parent, label, dbKey, minVal, maxVal, step, onValueChangedFunc)
        local name = "sfui_option_slider_" .. dbKey
        local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
        slider:SetOrientation("HORIZONTAL")
        slider:SetHeight(20)
        slider:SetWidth(150)
        slider:SetMinMaxValues(minVal, maxVal)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true)
        
        getglobal(slider:GetName() .. 'Low'):SetText(minVal)
        getglobal(slider:GetName() .. 'High'):SetText(maxVal)
        getglobal(slider:GetName() .. 'Text'):SetText(label)

        slider:SetScript("OnValueChanged", function(self, value)
            SfuiDB[dbKey] = value
            if onValueChangedFunc then onValueChangedFunc(value) end
        end)
        
        slider:SetScript("OnShow", function(self)
            self:SetValue(SfuiDB[dbKey] or minVal) -- Default to minVal if nil, or handle specifically
        end)
        return slider
    end

    local function OnTabClick(self)
        select_tab(self)
    end

    local function OnTabEnter(self)
        self:GetFontString():SetTextColor(c.tabs.highlight_color.r, c.tabs.highlight_color.g, c.tabs.highlight_color.b)
    end

    local function OnTabLeave(self)
        if self == frame.selected_tab then
            self:GetFontString():SetTextColor(c.tabs.selected_color.r, c.tabs.selected_color.g, c.tabs.selected_color.b)
        else
            self:GetFontString():SetTextColor(c.tabs.color.r, c.tabs.color.g, c.tabs.color.b)
        end
    end

    local function create_tab(name)
        local tab_button = CreateFrame("Button", "sfui_options_tab_" .. name, frame)
        tab_button:SetSize(c.tabs.width, c.tabs.height)
        tab_button:SetText(name)
        
        local font_string = tab_button:GetFontString()
        font_string:SetFontObject(g.font)
        font_string:SetJustifyH("LEFT")
        font_string:SetJustifyV("MIDDLE")
        font_string:SetPoint("LEFT", tab_button, "LEFT", 5, 0)
        font_string:SetTextColor(c.tabs.color.r, c.tabs.color.g, c.tabs.color.b)

        local content_panel = CreateFrame("Frame", "sfui_options_panel_" .. name, frame, "BackdropTemplate")
        content_panel:SetPoint("TOPLEFT", frame, "TOPLEFT", c.tabs.width + 20, -40)
        content_panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 5)
        content_panel:SetBackdrop({ bgFile = g.textures.white, tile = true, tileSize = 32 })
        content_panel:SetBackdropColor(0, 0, 0, 0.5)
        content_panel:Hide()

        tab_button.panel = content_panel
        
        tab_button:SetScript("OnClick", OnTabClick)
        tab_button:SetScript("OnEnter", OnTabEnter)
        tab_button:SetScript("OnLeave", OnTabLeave)

        table.insert(frame.tabs, { button = tab_button, panel = content_panel })
        return content_panel, tab_button
    end

    -- Create tabs in desired order
    local last_tab_button
    local main_panel, main_tab_button = create_tab("main")
    main_tab_button:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -40)
    last_tab_button = main_tab_button

    local currency_items_panel, currency_tab_button = create_tab("currency/items")
    currency_tab_button:SetPoint("TOPLEFT", last_tab_button, "BOTTOMLEFT", 0, 5)
    last_tab_button = currency_tab_button

    local bars_panel, bars_tab_button = create_tab("bars")
    bars_tab_button:SetPoint("TOPLEFT", last_tab_button, "BOTTOMLEFT", 0, 5)
    last_tab_button = bars_tab_button

    local minimap_panel, minimap_tab_button = create_tab("minimap") -- New Minimap Tab
    minimap_tab_button:SetPoint("TOPLEFT", last_tab_button, "BOTTOMLEFT", 0, 5)
    last_tab_button = minimap_tab_button

    local debug_panel, debug_tab_button = create_tab("debug") -- Debug Tab at bottom
    debug_tab_button:SetPoint("TOPLEFT", last_tab_button, "BOTTOMLEFT", 0, 5)
    last_tab_button = debug_tab_button
    
    -- populate main panel
    local main_text = main_panel:CreateFontString(nil, "OVERLAY", g.font)
    main_text:SetPoint("TOPLEFT", 15, -15)
    main_text:SetTextColor(1, 1, 1)
    main_text:SetText("welcome to sfui. please select a category on the left.")



    -- Reload UI button
    local reload_button = CreateFrame("Button", nil, main_panel, "UIPanelButtonTemplate")
    reload_button:SetSize(100, 22)
    reload_button:SetPoint("TOPLEFT", main_text, "BOTTOMLEFT", 0, -20)
    reload_button:SetText("Reload UI")
    reload_button:SetScript("OnClick", function()
        C_UI.Reload()
    end)

    -- Memory and CPU Usage Display

    -- populate minimap panel
    local minimap_header = minimap_panel:CreateFontString(nil, "OVERLAY", g.font)
    minimap_header:SetPoint("TOPLEFT", 15, -15)
    minimap_header:SetTextColor(1, 1, 1)
    minimap_header:SetText("Minimap Settings")

    local show_gametime_checkbox = CreateCheckbox(minimap_panel, "Show Calendar / Game Time", "minimap_show_gametime", function(checked)
        if GameTimeFrame then
            if checked then GameTimeFrame:Show() else GameTimeFrame:Hide() end
        end
    end, "Toggles the display of the game time and calendar button on the minimap.")
    show_gametime_checkbox:SetPoint("TOPLEFT", minimap_header, "BOTTOMLEFT", 0, -10)

    local show_clock_checkbox = CreateCheckbox(minimap_panel, "Show Clock", "minimap_show_clock", function(checked)
        if TimeManagerClockButton then
            if checked then TimeManagerClockButton:Show() else TimeManagerClockButton:Hide() end
        end
    end, "Toggles the display of the clock under the minimap.")
    show_clock_checkbox:SetPoint("TOPLEFT", show_gametime_checkbox, "BOTTOMLEFT", 0, -10)

    local square_cb = CreateCheckbox(minimap_panel, "Square Minimap", "minimap_square", function(checked)
        if sfui.minimap and sfui.minimap.SetSquareMinimap then
            sfui.minimap.SetSquareMinimap(checked)
        end
    end, "Toggles between square and round minimap.")
    square_cb:SetPoint("TOPLEFT", show_clock_checkbox, "BOTTOMLEFT", 0, -10)

    local collect_cb = CreateCheckbox(minimap_panel, "Collect Buttons", "minimap_collect_buttons", function(checked)
        if sfui.minimap and sfui.minimap.EnableButtonManager then
            sfui.minimap.EnableButtonManager(checked)
        end
    end, "Collects minimap buttons into a bar.")
    collect_cb:SetPoint("TOPLEFT", square_cb, "BOTTOMLEFT", 0, -10)

    local mouseover_cb = CreateCheckbox(minimap_panel, "Mouseover Only", "minimap_buttons_mouseover", function(checked)
        if sfui.minimap and sfui.minimap.EnableButtonManager and SfuiDB.minimap_collect_buttons then
             -- Re-enable to refresh logic
             sfui.minimap.EnableButtonManager(false)
             sfui.minimap.EnableButtonManager(true)
        end
    end, "Only show the button bar when hovering the minimap. Also moves Group Finder eye to Top Left.")
    mouseover_cb:SetPoint("TOPLEFT", collect_cb, "BOTTOMLEFT", 0, -10)

    local autozoom_cb = CreateCheckbox(minimap_panel, "Auto Zoom", "minimap_auto_zoom", nil, "Automatically zooms out the minimap.")
    autozoom_cb:SetPoint("TOPLEFT", mouseover_cb, "BOTTOMLEFT", 0, -10)
    
    local masque_cb = CreateCheckbox(minimap_panel, "Use Masque", "minimap_masque", function(checked)
         print("sfui: Please reload UI (/rl) for Masque changes to fully apply.")
    end, "Enables Masque support for minimap buttons (requires Reload).")
    masque_cb:SetPoint("TOPLEFT", autozoom_cb, "BOTTOMLEFT", 0, -10)

    local spacing_slider = CreateSlider(minimap_panel, "Button Spacing", "minimap_button_spacing", 0, 10, 1, function(value)
        -- Assuming we need to re-arrange to see changes
        if sfui.minimap and sfui.minimap.EnableButtonManager and SfuiDB.minimap_collect_buttons then
            sfui.minimap.EnableButtonManager(true)
        end
    end)
    spacing_slider:SetPoint("TOPLEFT", masque_cb, "BOTTOMLEFT", 0, -20) -- More padding for slider text

    -- (removed font size input section)

    -- populate combined currency/items panel

                
        -- populate debug panel
    
    
    local spec_id_label = debug_panel:CreateFontString(nil, "OVERLAY", g.font)
    spec_id_label:SetPoint("TOPLEFT", 15, -15)
    spec_id_label:SetText("Spec ID:")
    local spec_id_value = debug_panel:CreateFontString(nil, "OVERLAY", g.font)
    spec_id_value:SetPoint("LEFT", spec_id_label, "RIGHT", 5, 0)

    local color_swatch = debug_panel:CreateTexture(nil, "ARTWORK")
    color_swatch:SetSize(20, 20)
    color_swatch:SetPoint("LEFT", spec_id_value, "RIGHT", 10, 0)
    color_swatch:SetTexture("Interface/Buttons/WHITE8X8")

    local primary_power_label = debug_panel:CreateFontString(nil, "OVERLAY", g.font)
    primary_power_label:SetPoint("TOPLEFT", spec_id_label, "BOTTOMLEFT", 0, -15)
    primary_power_label:SetText("Primary Power:")
    local primary_power_value = debug_panel:CreateFontString(nil, "OVERLAY", g.font)
    primary_power_value:SetPoint("LEFT", primary_power_label, "RIGHT", 5, 0)

    local secondary_power_label = debug_panel:CreateFontString(nil, "OVERLAY", g.font)
    secondary_power_label:SetPoint("TOPLEFT", primary_power_label, "BOTTOMLEFT", 0, -15)
    secondary_power_label:SetText("Secondary Power:")
    local secondary_power_value = debug_panel:CreateFontString(nil, "OVERLAY", g.font)
    secondary_power_value:SetPoint("LEFT", secondary_power_label, "RIGHT", 5, 0)
    
    local function get_power_type_name(power_enum)
        if not power_enum then return "None" end
        if type(power_enum) ~= "number" then return tostring(power_enum) end
        for name, value in pairs(Enum.PowerType) do
            if value == power_enum then return name end
        end
        return "Unknown"
    end

    local function update_debug_info()
        local spec = C_SpecializationInfo.GetSpecialization()
        local specID = spec and C_SpecializationInfo.GetSpecializationInfo(spec) or "N/A"
        spec_id_value:SetText(tostring(specID))

        local color
        if specID and g.spec_colors[specID] then
            local c = g.spec_colors[specID]
            color = { r = c.r, g = c.g, b = c.b }
        elseif specID then
            local _, _, _, r, g, b = C_SpecializationInfo.GetSpecializationInfo(specID)
            if r then color = { r = r, g = g, b = b } end
        end
        if not color then local _, class = UnitClass("player"); color = RAID_CLASS_COLORS[class] end
        if color then color_swatch:SetColorTexture(color.r, color.g, color.b) end
        
        -- Need to get these functions from common.lua
        if sfui.common.GetPrimaryResource then
            primary_power_value:SetText(get_power_type_name(sfui.common.GetPrimaryResource()))
        end
        if sfui.common.GetSecondaryResource then
            secondary_power_value:SetText(get_power_type_name(sfui.common.GetSecondaryResource()))
        end
    end

    local debug_refresh_button = CreateFrame("Button", nil, debug_panel, "UIPanelButtonTemplate")
    debug_refresh_button:SetSize(100, 22)
    debug_refresh_button:SetPoint("BOTTOM", debug_panel, "BOTTOM", 0, 10)
    debug_refresh_button:SetText("Refresh")
    debug_refresh_button:SetScript("OnClick", update_debug_info)

    -- Hook into the debug tab's OnClick to refresh info when selected
    local original_on_click_debug = debug_tab_button:GetScript("OnClick")
    debug_tab_button:SetScript("OnClick", function(self)
        original_on_click_debug(self) -- Call original select_tab logic
        update_debug_info()
    end)
    
    update_debug_info()

    -- populate combined currency/items panel
    -- Currency Section
    local currency_header = currency_items_panel:CreateFontString(nil, "OVERLAY", g.font)
    currency_header:SetPoint("TOPLEFT", 15, -15)
    currency_header:SetTextColor(1, 1, 1)
    currency_header:SetText("Currency Display Settings")

    local currency_info_text = currency_items_panel:CreateFontString(nil, "OVERLAY", g.font)
    currency_info_text:SetPoint("TOPLEFT", currency_header, "BOTTOMLEFT", 0, -10)
    currency_info_text:SetPoint("RIGHT", -15, 0)
    currency_info_text:SetJustifyH("LEFT")
    currency_info_text:SetText("The currency display is automatic. To add or remove currencies, open the default Character panel, go to the Currencies tab, and check 'Show on Backpack' for any currency you wish to track. Opening and closing the Character Panel will also update the display.")

    -- Items Section
    local item_header = currency_items_panel:CreateFontString(nil, "OVERLAY", g.font)
    item_header:SetPoint("TOPLEFT", currency_info_text, "BOTTOMLEFT", 0, -20)
    item_header:SetTextColor(1, 1, 1)
    item_header:SetText("Item Tracking Settings")

    local item_id_label = currency_items_panel:CreateFontString(nil, "OVERLAY", g.font)
    item_id_label:SetPoint("TOPLEFT", item_header, "BOTTOMLEFT", 0, -10)
    item_id_label:SetText("Add Item by ID:")

    local item_id_input = CreateFrame("EditBox", nil, currency_items_panel, "InputBoxTemplate")
    item_id_input:SetPoint("LEFT", item_id_label, "RIGHT", 10, 0)
    item_id_input:SetSize(100, 32)
    item_id_input:SetAutoFocus(false)

    local add_button = CreateFrame("Button", nil, currency_items_panel, "UIPanelButtonTemplate")
    add_button:SetPoint("LEFT", item_id_input, "RIGHT", 5, 0)
    add_button:SetSize(50, 22)
    add_button:SetText("Add")
    add_button:SetScript("OnClick", function()
        local id = tonumber(item_id_input:GetText())
        if id and sfui.add_item then
            sfui.add_item(id)
            item_id_input:SetText("")
        end
    end)

    local drop_frame = CreateFrame("Frame", "sfui_item_drop_frame", currency_items_panel, "BackdropTemplate")
    drop_frame:SetPoint("TOPLEFT", item_id_label, "BOTTOMLEFT", 0, -20)
    drop_frame:SetSize(250, 50)
    local drop_frame_backdrop = {
        bgFile = g.textures.tooltip, tile = true, tileSize = 16,
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border", edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    }
    drop_frame:SetBackdrop(drop_frame_backdrop)
    drop_frame:SetBackdropColor(0.3, 0.3, 0.3, 0.7) -- Lighter background
    drop_frame:SetBackdropBorderColor(0, 0, 0, 1) -- 100% black border

    local drop_label = drop_frame:CreateFontString(nil, "OVERLAY", g.font)
    drop_label:SetAllPoints()
    drop_label:SetText("Drop Item Here")
    drop_label:EnableMouse(false)

    drop_frame:EnableMouse(true)
    drop_frame:RegisterForDrag("LeftButton")
    drop_frame:SetScript("OnReceiveDrag", function(self)
        local type, id, link = GetCursorInfo()
        if type == "item" and link then
            local itemID = GetItemInfoFromHyperlink(link)
            if itemID and sfui.add_item then
                sfui.add_item(itemID)
            end
        end
    end)



    -- populate bars panel
    local bars_header = bars_panel:CreateFontString(nil, "OVERLAY", g.font)
    bars_header:SetPoint("TOPLEFT", 15, -15)
    bars_header:SetTextColor(1, 1, 1)
    bars_header:SetText("Bar Settings")

    local texture_label = bars_panel:CreateFontString(nil, "OVERLAY", g.font)
    texture_label:SetPoint("TOPLEFT", bars_header, "BOTTOMLEFT", 0, -10)
    texture_label:SetText("Bar Texture:")

    local dropdown = CreateFrame("Frame", "sfui_options_texture_dropdown", bars_panel, "UIDropDownMenuTemplate")
    dropdown:SetPoint("LEFT", texture_label, "RIGHT", 10, 0)

    local function OnTextureSelect(self)
        local textureName = self.value
        SfuiDB.barTexture = textureName
        
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local texturePath = LSM and LSM:Fetch("statusbar", textureName) or "Interface/Buttons/WHITE8X8"

        if sfui.bars and sfui.bars.SetBarTexture then
            sfui.bars:SetBarTexture(texturePath)
        end
        UIDropDownMenu_SetSelectedValue(dropdown, textureName)
    end

    local function InitializeTextureDropdown(self, level)
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local info = UIDropDownMenu_CreateInfo()
        
        local sortedTextures = {}
        -- Ensure Flat is always available
        local seen = { ["Flat"] = true }
        table.insert(sortedTextures, "Flat")
        
        if LSM then
            local textures = LSM:HashTable("statusbar")
            for name, _ in pairs(textures) do
                if not seen[name] then
                    table.insert(sortedTextures, name)
                    seen[name] = true
                end
            end
        end
        table.sort(sortedTextures)

        for _, name in ipairs(sortedTextures) do
            info.text = name
            info.value = name
            info.func = OnTextureSelect
            info.checked = (SfuiDB.barTexture == name)
            UIDropDownMenu_AddButton(info)
        end
    end

    UIDropDownMenu_Initialize(dropdown, InitializeTextureDropdown)
    UIDropDownMenu_SetSelectedValue(dropdown, SfuiDB.barTexture)
    UIDropDownMenu_SetWidth(dropdown, 150)




end




-- global toggle function
function sfui.toggle_options_panel()
    if not frame then return end

    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        if not frame.selected_tab then
            select_tab(frame.tabs[1].button)
        end
    end
end