sfui = sfui or {}
sfui.minimap = {}

-- Set up the addon's frame
local addonName, addon = ...
local frame = CreateFrame("Frame", addonName)

local zoom_timer = nil
local DEFAULT_ZOOM = 0
local custom_border = nil
local button_bar = nil

-- Store original minimap size
local original_width = Minimap:GetWidth()
local original_height = Minimap:GetHeight()

-- Button Collection
local ButtonCollection = {
    collectedButtons = {},
    processedButtons = {},
}

function ButtonCollection:StoreOriginalState(button)
    local name = button:GetName()
    if not name or self.processedButtons[name] then return end

    local orig = {
        parent = button:GetParent(),
        points = {},
        scale = button:GetScale(),
        strata = button:GetFrameStrata(),
        level = button:GetFrameLevel(),
    }
    for i = 1, button:GetNumPoints() do
        table.insert(orig.points, { button:GetPoint(i) })
    end
    button.sfuiOriginalState = orig
end

function ButtonCollection:RestoreButton(button)
    if button and button.sfuiOriginalState then
        local orig = button.sfuiOriginalState
        button:SetParent(orig.parent)
        button:ClearAllPoints()
        for _, pointData in ipairs(orig.points) do
            button:SetPoint(unpack(pointData))
        end
        button:SetScale(orig.scale)
        button:SetFrameStrata(orig.strata)
        button:SetFrameLevel(orig.level)
        button.sfuiOriginalState = nil
    end
end

function ButtonCollection:RestoreAll()
    for _, button in ipairs(self.collectedButtons) do
        self:RestoreButton(button)
    end
    wipe(self.collectedButtons)
    wipe(self.processedButtons)
end

function ButtonCollection:AddButton(button)
    local name = button:GetName()
    if not name or self.processedButtons[name] then return end

    self:StoreOriginalState(button)
    table.insert(self.collectedButtons, button)
    self.processedButtons[name] = true
end

function sfui.minimap.SetSquareMinimap(isSquare)
    if isSquare then
        if MinimapBorder then MinimapBorder:Hide() end
        if MinimapBackdrop then MinimapBackdrop:Hide() end

        if not custom_border then
            custom_border = CreateFrame("Frame", "sfui_minimap_border", Minimap, "BackdropTemplate")
            custom_border:SetAllPoints(Minimap)
        end
        
        local cfg = sfui.config.minimap.border
        custom_border:SetBackdrop({
            edgeFile = "Interface/Buttons/WHITE8X8",
            edgeSize = cfg.size,
        })
        custom_border:SetBackdropBorderColor(cfg.color[1], cfg.color[2], cfg.color[3], cfg.color[4])
        custom_border:Show()
        
        Minimap:SetMaskTexture("Interface/Buttons/WHITE8X8")
        Minimap:SetSize(sfui.config.minimap.default_size, sfui.config.minimap.default_size)
    else
        if MinimapBorder then MinimapBorder:Show() end
        if MinimapBackdrop then MinimapBackdrop:Show() end
        if custom_border then
            custom_border:Hide()
        end
        
        Minimap:SetMaskTexture("Interface/Minimap/Minimap-Circle-Mask")
        Minimap:SetSize(original_width, original_height)
    end
end

function sfui.minimap.ArrangeButtons()
    if not button_bar then return end

    local lastButton = nil
    for _, button in ipairs(ButtonCollection.collectedButtons) do
        button:SetParent(button_bar)
        button:ClearAllPoints()
        if not lastButton then
            button:SetPoint("LEFT", button_bar, "LEFT", 5, 0)
        else
            button:SetPoint("LEFT", lastButton, "RIGHT", 5, 0)
        end
        lastButton = button
    end
end

function sfui.minimap.CollectButtons()
    local ldbi = LibStub("LibDBIcon-1.0", true)
    if ldbi then
        local buttons = ldbi:GetButtonList()
        for _, buttonName in ipairs(buttons) do
            local button = _G[buttonName]
            if button then
                ButtonCollection:AddButton(button)
            end
        end
    end

    for i = 1, Minimap:GetNumChildren() do
        local child = select(i, Minimap:GetChildren())
        if child:IsObjectType("Button") and child:GetName() then
            ButtonCollection:AddButton(child)
        end
    end

    sfui.minimap.ArrangeButtons()
end

function sfui.minimap.SetButtonCollection(enabled)
    if enabled then
        if not button_bar then
            button_bar = CreateFrame("Frame", "sfui_minimap_button_bar", Minimap, "BackdropTemplate")
            button_bar:SetPoint("TOP", Minimap, "TOP", 0, 20)
            button_bar:SetSize(sfui.config.minimap.default_size, 30)
            button_bar:SetBackdrop({
                bgFile = "Interface/Buttons/WHITE8X8",
                tile = true,
                tileSize = 16,
            })
            button_bar:SetBackdropColor(0, 0, 0, 0.5) -- Semi-transparent black
        end
        button_bar:Show()
        sfui.minimap.CollectButtons()
    else
        ButtonCollection:RestoreAll()
        if button_bar then
            button_bar:Hide()
        end
    end
end

local function set_default_zoom()
    if zoom_timer then
        zoom_timer:Cancel()
        zoom_timer = nil
    end
    Minimap:SetZoom(DEFAULT_ZOOM)
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:RegisterEvent("MINIMAP_UPDATE_ZOOM")

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    SfuiDB.minimap_auto_zoom = SfuiDB.minimap_auto_zoom or false
    if SfuiDB.minimap_auto_zoom then
        set_default_zoom()
    end
    
    SfuiDB.minimap_square = SfuiDB.minimap_square or false
    sfui.minimap.SetSquareMinimap(SfuiDB.minimap_square)

    SfuiDB.minimap_collect_buttons = SfuiDB.minimap_collect_buttons or false
    sfui.minimap.SetButtonCollection(SfuiDB.minimap_collect_buttons)

    self:UnregisterEvent("PLAYER_ENTERING_WORLD") -- Only need this once
    return
  end
  
  if not SfuiDB.minimap_auto_zoom then
    if zoom_timer then
        zoom_timer:Cancel()
        zoom_timer = nil
    end
    return 
  end

  if event == "PLAYER_MOUNT_DISPLAY_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM" then
    set_default_zoom()
  elseif event == "MINIMAP_UPDATE_ZOOM" then
    if Minimap:GetZoom() ~= DEFAULT_ZOOM then
        if zoom_timer then
            zoom_timer:Cancel()
        end
        zoom_timer = C_Timer.NewTimer(5, set_default_zoom)
    end
  end
end)