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

function sfui.minimap.InitializeMasque()
    local Masque = LibStub("Masque", true)
    if not Masque then
        return
    end

    if SfuiDB.minimap_masque then
        sfui.minimap.masque_group = Masque:Group("sfui", "Minimap Buttons")
        if sfui.minimap.masque_group then
            sfui.minimap.masque_group:RegisterCallback("OnSkinChanged", function()
                ButtonManager:ArrangeButtons()
            end)
        end
    end
end


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
    if not frame or type(frame) ~= "table" then return false end

    -- Check if it has the GetName method
    if type(frame.GetName) ~= "function" then return false end

    local name = frame:GetName()
    if not name then return false end
    
    -- Exclude frames that are known not to be addon buttons
    if name:find("Minimap") or name:find("MinimapCluster") or name:find("GameTime") or name:find("QueueStatus") then
        return false
    end

    -- Check if it has the IsObjectType method
    if type(frame.IsObjectType) ~= "function" then return false end

    -- Check if it's a Button or CheckButton
    if not frame:IsObjectType("Button") and not frame:IsObjectType("CheckButton") then
        return false
    end

    -- Check for scripts
    if type(frame.GetScript) ~= "function" or (not frame:GetScript("OnClick") and not frame:GetScript("OnMouseDown") and not frame:GetScript("OnMouseUp")) then
        return false
    end

    -- Check for textures
    if type(frame.GetNumRegions) ~= "function" or frame:GetNumRegions() == 0 then
        return false
    end

    return true
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
    if not SfuiDB.minimap_masque then
        print("sfui: SkinButton for " .. (button:GetName() or "unknown") .. ": Masque not enabled in options.")
        return
    end
    if not sfui.minimap.masque_group then
        print("sfui: SkinButton for " .. (button:GetName() or "unknown") .. ": Masque group not found.")
        return
    end

    local Masque = LibStub("Masque", true)
    if not Masque then return end

    -- Based on HidingBar's Masque integration
    local isButton = button:IsObjectType("Button")
    local normal, isNormalIcon = isButton and button:GetNormalTexture()
    local icon, highlight, pushed, border, background, iconMask

    for _, region in ipairs({button:GetRegions()}) do
        if region:IsObjectType("Texture") then
            local name = region:GetDebugName()
            if name then
                name = name:gsub(".*%.", ""):lower()
            else
                name = ""
            end
            local texture = region:GetTexture()
            local tIsString = type(texture) == "string"
            if tIsString then texture = texture:lower() end
            local layer = region:GetDrawLayer()
            if texture == 136430 or tIsString and texture:find("minimap-trackingborder", 1, true) then
                border = region
            end
            if texture == 136467 or tIsString and texture:find("ui-minimap-background", 1, true) or name:find("background", 1, true) then
                background = region
            end
            if name:find("icon", 1, true) or not icon and tIsString and texture:find("icon", 1, true) then
                icon = region
            end
            if layer == "HIGHLIGHT" or not highlight and name:find("highlight", 1, true) then
                highlight = region
            end
        end
    end

    if normal and (not icon or icon ~= button.icon or icon == normal) then
        isNormalIcon = true
        icon = button:CreateTexture(nil, "BACKGROUND")
        local atlas = normal:GetAtlas()
        if atlas then
            icon:SetAtlas(atlas)
        else
            icon:SetTexture(normal:GetTexture())
        end
        icon:SetTexCoord(normal:GetTexCoord())
        icon:SetVertexColor(normal:GetVertexColor())
        icon:SetSize(normal:GetSize())
        for i = 1, normal:GetNumPoints() do
            icon:SetPoint(normal:GetPoint(i))
        end
    end

    local btnHighlight = isButton and button:GetHighlightTexture()
    if not highlight or highlight == btnHighlight then
        highlight = button:CreateTexture(nil, "HIGHLIGHT")
    end

    if icon then
        for i = 1, icon:GetNumMaskTextures() do
            local mask = icon:GetMaskTexture(i)
            local texture = mask:GetTexture()
            if texture == 130924 or type(texture) == "string" and texture:lower():find("tempportraitalphamask", 1, true) then
                iconMask = mask
                break
            end
        end
    else
        background = nil
    end

    local data = {
        Icon = icon,
        Highlight = highlight,
    }

    sfui.minimap.masque_group:AddButton(button, data, "Legacy", true)
    
    pushed = isButton and button:GetPushedTexture()
    if border or background or pushed or normal or btnHighlight or iconMask then
        if border then border:Hide() end
        if background then background:Hide() end
        if pushed then
            button.SetPushedTexture = function() end
            pushed:SetAlpha(0)
            pushed:SetTexture()
            pushed.SetAlpha = function() end
            pushed.SetAtlas = function() end
            pushed.SetTexture = function() end
        end
        if normal then
            if isNormalIcon then
                button.SetNormalTexture = function(_, value)
                    if not value then return end
                    if C_Texture.GetAtlasInfo(value) then
                        icon:SetAtlas(value)
                    else
                        icon:SetTexture(value)
                    end
                end
                button.SetNormalAtlas = function(_, atlas)
                    if atlas then
                        icon:SetAtlas(atlas)
                    end
                end
                normal.SetAtlas = function() end
                normal.SetTexture = function() end
            else
                button.SetNormalTexture = function() end
                button.SetNormalAtlas = function() end
                normal.SetAtlas = function() end
                normal.SetTexture = function() end
            end
        end
        if btnHighlight then
            button:UnlockHighlight()
            button.LockHighlight = function() end
            button.SetHighlightLocked = function() end
            button.SetHighlightTexture = function() end
            button.SetHighlightAtlas = function() end
            btnHighlight:SetAlpha(0)
            btnHighlight:SetTexture()
            btnHighlight.SetAlpha = function() end
            btnHighlight.SetAtlas = function() end
            btnHighlight.SetTexture = function() end
        end
        if iconMask then
            icon:RemoveMaskTexture(iconMask)
        end
    end
end

function ButtonManager:ArrangeButtons()
    if not button_bar then return end

    if SfuiDB.minimap_button_order == nil then
        SfuiDB.minimap_button_order = {}
    end

    -- Sort buttons based on saved order, or alphabetically if no order is saved
    if #SfuiDB.minimap_button_order > 0 then
        local order = {}
        for i, name in ipairs(SfuiDB.minimap_button_order) do
            order[name] = i
        end
        table.sort(self.collectedButtons, function(a, b)
            local aName = a:GetName() or ""
            local bName = b:GetName() or ""
            local aOrder = order[aName] or 999
            local bOrder = order[bName] or 999
            if aOrder == bOrder then
                return aName < bName
            else
                return aOrder < bOrder
            end
        end)
    else
        table.sort(self.collectedButtons, function(a, b)
            local aName = a:GetName() or ""
            local bName = b:GetName() or ""
            return aName < bName
        end)
    end

    local lastButton = nil
    local cfg = sfui.config.minimap.button_bar
    local size = cfg.button_size
    local spacing = cfg.spacing

    for i, button in ipairs(self.collectedButtons) do
        button:SetParent(button_bar)
        button:ClearAllPoints()
        button:SetSize(size, size)

        self:SkinButton(button)
        
        if SfuiDB.minimap_rearrange then
            button:SetMovable(true)
            button:RegisterForDrag("LeftButton")
            button:SetScript("OnDragStart", function(self)
                self:StartMoving()
                self.isMoving = true
            end)
            button:SetScript("OnDragStop", function(self)
                self:StopMovingOrSizing()
                self.isMoving = false

                -- Find the new position of the button
                local newIndex = 1
                for j, btn in ipairs(ButtonManager.collectedButtons) do
                    if self:GetCenter() > btn:GetCenter() then
                        newIndex = j + 1
                    end
                end
                
                -- Remove the button from its old position
                local oldIndex
                for j, btn in ipairs(ButtonManager.collectedButtons) do
                    if btn == self then
                        oldIndex = j
                        break
                    end
                end
                if oldIndex then
                    table.remove(ButtonManager.collectedButtons, oldIndex)
                end

                -- Insert the button at its new position
                table.insert(ButtonManager.collectedButtons, newIndex, self)

                -- Save the new order
                SfuiDB.minimap_button_order = {}
                for _, btn in ipairs(ButtonManager.collectedButtons) do
                    table.insert(SfuiDB.minimap_button_order, btn:GetName())
                end
                
                -- Redraw the buttons
                ButtonManager:ArrangeButtons()
            end)
        else
            button:SetMovable(false)
            button:RegisterForDrag()
            button:SetScript("OnDragStart", nil)
            button:SetScript("OnDragStop", nil)
        end
        
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
            button_bar:SetPoint("TOP", Minimap, "TOP", 0, 35)
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