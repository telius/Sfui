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

-- ============================================================================
-- Button Manager
-- ============================================================================
local ButtonManager = {
    collectedButtons = {},
    processedButtons = {},
}

function ButtonManager:StoreOriginalState(button)
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

function ButtonManager:RestoreButton(button)
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

function ButtonManager:RestoreAll()
    for _, button in ipairs(self.collectedButtons) do
        self:RestoreButton(button)
    end
    wipe(self.collectedButtons)
    wipe(self.processedButtons)
end

function ButtonManager:IsButton(frame)
    if not frame or type(frame) ~= "table" or not frame.IsObjectType then return false end
    if not frame:IsObjectType("Frame") then return false end
    
    local name = frame:GetName()
    if not name then return false end
    
    -- Exclude frames that are known not to be addon buttons
    if name:find("Minimap") or name:find("MinimapCluster") or name:find("GameTime") or name:find("QueueStatus") then
        return false
    end

    -- A simple check for now: if it has "Button" in its object type, it's a button.
    return frame:IsObjectType("Button")
end


function ButtonManager:AddButton(button)
    if not self:IsButton(button) then return end

    local name = button:GetName()
    if not name or self.processedButtons[name] then return end

    self:StoreOriginalState(button)
    table.insert(self.collectedButtons, button)
    self.processedButtons[name] = true
end

function ButtonManager:CollectButtons()
    local ldbi = LibStub("LibDBIcon-1.0", true)
    if ldbi then
        for _, buttonName in ipairs(ldbi:GetButtonList()) do
            local button = _G[buttonName]
            if button then self:AddButton(button) end
        end
    end

    for i = 1, Minimap:GetNumChildren() do
        self:AddButton(select(i, Minimap:GetChildren()))
    end
    
    if MinimapCluster then
        for i = 1, MinimapCluster:GetNumChildren() do
            self:AddButton(select(i, MinimapCluster:GetChildren()))
        end
    end
end

function ButtonManager:SkinButton(button)
    if not SfuiDB.minimap_masque or not sfui.minimap.masque_group then return end

    local buttonData = {}
    local icon, highlight, background, border

    -- Find the icon, highlight, background and border textures
    for _, region in ipairs({button:GetRegions()}) do
        if region and region:IsObjectType("Texture") then
            local texture = region:GetTexture()
            local tIsString = type(texture) == "string"
            if tIsString then texture = texture:lower() end
            local layer = region:GetDrawLayer()

            if texture == 136430 or (tIsString and texture:find("minimap-trackingborder", 1, true)) then
                border = region
            elseif texture == 136467 or (tIsString and texture:find("ui-minimap-background", 1, true)) then
                background = region
            elseif layer == "HIGHLIGHT" then
                highlight = region
            else
                icon = region
            end
        end
    end
    
    if button:GetNormalTexture() then
        icon = button:GetNormalTexture()
    end
    
    if button:GetHighlightTexture() then
        highlight = button:GetHighlightTexture()
    end

    if icon then buttonData.Icon = icon end
    if highlight then buttonData.Highlight = highlight end
    if background then buttonData.Background = background end
    if border then buttonData.Border = border end

    sfui.minimap.masque_group:AddButton(button, buttonData)
end

function ButtonManager:ArrangeButtons()
    if not button_bar then return end

    local lastButton = nil
    local cfg = sfui.config.minimap.button_bar
    local size = cfg.button_size
    local spacing = cfg.spacing

    for _, button in ipairs(self.collectedButtons) do
        button:SetParent(button_bar)
        button:ClearAllPoints()
        button:SetSize(size, size)

        self:SkinButton(button)
        
        if not lastButton then
            button:SetPoint("LEFT", button_bar, "LEFT", 5, 0)
        else
            button:SetPoint("LEFT", lastButton, "RIGHT", spacing, 0)
        end
        lastButton = button
    end
end

function sfui.minimap.EnableButtonManager(enabled)
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
        ButtonManager:CollectButtons()
        ButtonManager:ArrangeButtons()
    else
        ButtonManager:RestoreAll()
        if button_bar then
            button_bar:Hide()
        end
    end
end

-- ============================================================================
-- Original Minimap functions
-- ============================================================================

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
    sfui.minimap.EnableButtonManager(SfuiDB.minimap_collect_buttons)

    if Masque and SfuiDB.minimap_masque then
        sfui.minimap.masque_group = Masque:Group("sfui", "Minimap Buttons")
        if sfui.minimap.masque_group then
            sfui.minimap.masque_group:RegisterCallback("OnSkinChanged", function()
                ButtonManager:ArrangeButtons()
            end)
        end
    end

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