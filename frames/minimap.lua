local addonName, addon = ...
sfui = sfui or {}
sfui.minimap = {}

-- ========================
-- Localization
-- ========================
local _G = _G
local type = type
local select = select
local ipairs = ipairs
local pairs = pairs
local unpack = unpack
local table_insert = _G.table.insert
local table_sort = _G.table.sort
local table_wipe = _G.wipe
local string_lower = _G.string.lower
local string_find = _G.string.find
local string_match = _G.string.match
local string_gsub = _G.string.gsub
local tostring = _G.tostring
local math_floor = _G.math.floor

local C_Timer = _G.C_Timer
local C_ActionBar = _G.C_ActionBar
local C_Texture = _G.C_Texture
local Minimap = _G.Minimap
local MinimapCluster = _G.MinimapCluster
local CreateFrame = _G.CreateFrame
local InCombatLockdown = _G.InCombatLockdown
local hooksecurefunc = _G.hooksecurefunc
local GetTime = _G.GetTime
local UnitOnTaxi = _G.UnitOnTaxi
local VehicleExit = _G.VehicleExit
local TaxiRequestEarlyLanding = _G.TaxiRequestEarlyLanding
local LibStub = _G.LibStub

-- ========================
-- Local Variables
-- ========================
local isInitialized = false
local collectAttempts = 0

local frame = CreateFrame("Frame", "SfuiMinimapFrame")

local zoom_timer = nil
local DEFAULT_ZOOM = sfui.config.minimap.defaultZoom or 0
local button_bar = nil

local function set_default_zoom()
    if zoom_timer then
        zoom_timer:Cancel()
        zoom_timer = nil
    end
    Minimap:SetZoom(DEFAULT_ZOOM)
end

function sfui.minimap.reset_zoom_timer()
    if zoom_timer then
        zoom_timer:Cancel()
        zoom_timer = nil
    end
    if SfuiDB.minimap_auto_zoom and Minimap:GetZoom() ~= DEFAULT_ZOOM then
        zoom_timer = C_Timer.NewTimer(SfuiDB.minimap_auto_zoom_delay or 5, set_default_zoom)
    end
end

local ButtonManager = {
    collectedButtons = {},
    processedButtons = {},
}

function sfui.minimap.initialize_masque()
    -- Global and local check handled by common.get_masque_group()
    sfui.minimap.masque_group = sfui.common.get_masque_group()
end

function ButtonManager:store_original_state(button)
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
        table_insert(orig.points, { button:GetPoint(i) })
    end
    button.sfuiOriginalState = orig
end

function ButtonManager:restore_button(button)
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

function ButtonManager:restore_all()
    for _, button in ipairs(self.collectedButtons) do
        self:restore_button(button)
    end
    table_wipe(self.collectedButtons)
    table_wipe(self.processedButtons)
end

local ignoreNameCache = {}
local validNameCache = {}

function ButtonManager:is_button(frame)
    if not frame or type(frame) ~= "table" then return false end

    -- Quick cache check first
    local name = frame.GetName and frame:GetName()
    if name then
        if ignoreNameCache[name] then return false end
        if validNameCache[name] then return true end
    end

    -- NEVER touch forbidden/protected frames or those with unit attributes (POIs)
    if frame.IsForbidden and frame:IsForbidden() then return false end
    if frame.IsProtected and frame:IsProtected() then return false end

    if not name then
        -- Check if it's a generic child we should ignore
        if frame.IsObjectType and frame:IsObjectType("Button") then
            -- POI and World Quest buttons often have no name in Dragonflight/TWW
            return false
        end
        return false
    end

    if ignoreNameCache[name] then return false end
    if validNameCache[name] then return true end

    -- Filter out Blizzard internal/protected buttons with surgical patterns
    -- We use specific prefixes instead of broad substrings like "poi" or "quest"
    -- to avoid clobbering addons like "MyusKnowledgePointsTracker".
    local lowerName = name:lower()
    if lowerName:find("^minimap") or lowerName:find("^areapoi") or lowerName:find("^minimappoi") then
        ignoreNameCache[name] = true; return false
    end
    if lowerName:find("^worldquest") or lowerName:find("^warband") or lowerName:find("^scenario") then
        ignoreNameCache[name] = true; return false
    end
    if lowerName:find("cluster") or lowerName:find("gametime") or lowerName:find("micro") then
        ignoreNameCache[name] = true; return false
    end
    if lowerName:find("flight") or lowerName:find("garrison") then
        ignoreNameCache[name] = true; return false
    end
    if lowerName:find("actionbar") or lowerName:find("petbattle") then
        ignoreNameCache[name] = true; return false
    end
    if lowerName:find("^blizzard_") or lowerName:find("^blizzard") then
        ignoreNameCache[name] = true; return false
    end

    if type(frame.IsObjectType) ~= "function" then return false end
    if not frame:IsObjectType("Button") and not frame:IsObjectType("CheckButton") then return false end
    if type(frame.GetScript) ~= "function" or (not frame:GetScript("OnClick") and not frame:GetScript("OnMouseDown") and not frame:GetScript("OnMouseUp")) then
        return false
    end

    validNameCache[name] = true
    return true
end

function ButtonManager:add_button(button)
    if not self:is_button(button) then return false end

    local name = button:GetName()
    if not name or self.processedButtons[name] then return false end

    self:store_original_state(button)
    table_insert(self.collectedButtons, button)
    self.processedButtons[name] = true

    if not button.sfuiLayoutHooked then
        hooksecurefunc(button, "Show", function() ButtonManager:arrange_buttons() end)
        hooksecurefunc(button, "Hide", function() ButtonManager:arrange_buttons() end)
        button.sfuiLayoutHooked = true
    end
    return true
end

function ButtonManager:collect_buttons()
    local foundNew = false
    local ldbi = LibStub("LibDBIcon-1.0", true)
    if ldbi then
        for _, buttonName in ipairs(ldbi:GetButtonList()) do
            local button = _G[buttonName]
            if button and self:add_button(button) then foundNew = true end
        end
    end

    for i = 1, Minimap:GetNumChildren() do
        local child = select(i, Minimap:GetChildren())
        if self:add_button(child) then foundNew = true end
    end

    if MinimapCluster then
        for i = 1, MinimapCluster:GetNumChildren() do
            local child = select(i, MinimapCluster:GetChildren())
            if self:add_button(child) then foundNew = true end
        end
    end
    return foundNew
end

function ButtonManager:skin_button(button)
    if button.sfuiSkinned then return end

    if not SfuiDB.minimap_masque then
        -- Standard square styling if Masque is disabled
        local regions = { button:GetRegions() }
        local icon
        for _, region in ipairs(regions) do
            if region:IsObjectType("Texture") then
                local texture = region:GetTexture()
                if texture and type(texture) == "string" and texture:lower():find("icon") then
                    icon = region
                    break
                end
            end
        end
        if icon then
            sfui.common.apply_square_icon_style(button, icon)
        end
        button.sfuiSkinned = true
        return
    end

    if button.SetBackdrop then button:SetBackdrop(nil) end

    local Masque = LibStub("Masque", true)
    if not Masque then return end

    -- Based on HidingBar's Masque integration
    local isButton = button:IsObjectType("Button")
    local normal, isNormalIcon = isButton and button:GetNormalTexture()
    local icon, highlight, pushed, border, background, iconMask

    local regions = { button:GetRegions() }

    for _, region in ipairs(regions) do
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

    sfui.common.sync_masque(button, { Icon = icon, Highlight = highlight, Border = border })

    for _, region in ipairs(regions) do
        if region:IsObjectType("Texture") and region ~= icon then region:SetTexture(nil) end
    end

    pushed = isButton and button:GetPushedTexture()
    if background or pushed or normal or btnHighlight or iconMask then
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

    button.sfuiSkinned = true
end

function ButtonManager:arrange_buttons()
    if InCombatLockdown() then return end
    if not button_bar then return end

    if SfuiDB.minimap_button_order == nil then
        SfuiDB.minimap_button_order = {}
    end

    local orderCache = {}
    if #SfuiDB.minimap_button_order > 0 then
        for i, name in ipairs(SfuiDB.minimap_button_order) do
            orderCache[name] = i
        end
    end

    table_sort(self.collectedButtons, function(a, b)
        local aName = a:GetName() or ""
        local bName = b:GetName() or ""

        if aName == "LibDBIcon_sfui" then return false end
        if bName == "LibDBIcon_sfui" then return true end

        if #SfuiDB.minimap_button_order > 0 then
            local aOrder = orderCache[aName] or 999
            local bOrder = orderCache[bName] or 999
            if aOrder == bOrder then
                return aName < bName
            else
                return aOrder < bOrder
            end
        else
            return aName < bName
        end
    end)

    local lastButton = nil
    local cfg = sfui.config.minimap.button_bar
    local size = cfg.button_size
    local spacing = cfg.spacing

    for i, button in ipairs(self.collectedButtons) do
        button:SetParent(button_bar)
        if not button.isMoving then
            button:ClearAllPoints()
        end
        button:SetSize(size, size)

        self:skin_button(button)

        if not SfuiDB.minimap_masque and button.SetBackdrop then
            button:SetBackdrop({ edgeFile = sfui.config.textures.white, edgeSize = 1, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
            sfui.common.set_color(button, "black")
        end

        if SfuiDB.minimap_rearrange then
            button:SetMovable(true)
            button:RegisterForDrag("LeftButton")
            button:SetScript("OnDragStart", function(self)
                self.isMoving = true
                self:StartMoving()
                ButtonManager:arrange_buttons()
            end)
            button:SetScript("OnDragStop", function(self)
                self:StopMovingOrSizing(); self.isMoving = false
                local newIndex = 1
                for j, btn in ipairs(ButtonManager.collectedButtons) do
                    if self:GetCenter() > btn:GetCenter() then
                        newIndex =
                            j + 1
                    end
                end
                local oldIndex
                for j, btn in ipairs(ButtonManager.collectedButtons) do
                    if btn == self then
                        oldIndex = j; break
                    end
                end
                if oldIndex then
                    table.remove(ButtonManager.collectedButtons, oldIndex)
                    if newIndex > oldIndex then newIndex = newIndex - 1 end
                    if newIndex > #ButtonManager.collectedButtons + 1 then newIndex = #ButtonManager.collectedButtons + 1 end
                    if newIndex < 1 then newIndex = 1 end
                    table_insert(ButtonManager.collectedButtons, newIndex, self)
                    SfuiDB.minimap_button_order = {}
                    for _, btn in ipairs(ButtonManager.collectedButtons) do
                        table_insert(SfuiDB.minimap_button_order,
                            btn:GetName())
                    end
                    ButtonManager:arrange_buttons()
                else
                    ButtonManager:arrange_buttons()
                end
            end)
        else
            button:SetMovable(false)
            button:RegisterForDrag()
            button:SetScript("OnDragStart", nil)
            button:SetScript("OnDragStop", nil)
        end

        if not button.isMoving then
            if button:IsShown() then
                if not lastButton then
                    button:SetPoint("LEFT", button_bar, "LEFT", 5, 0)
                    lastButton = button
                elseif button ~= lastButton then
                    button:SetPoint("LEFT", lastButton, "RIGHT", spacing, 0)
                    lastButton = button
                end
            else
                button:SetPoint("LEFT", button_bar, "LEFT", 0, 0)
            end
        end
    end
end

function sfui.minimap.enable_button_manager(enabled)
    if enabled then
        if not button_bar then
            -- Parent to MinimapCluster instead of Minimap to avoid protected frame taint
            button_bar = CreateFrame("Frame", "sfui_minimap_button_bar", MinimapCluster, "BackdropTemplate")
            button_bar:SetSize(sfui.config.minimap.default_size, 30)
            button_bar:SetBackdrop({
                bgFile = "Interface/Buttons/WHITE8X8",
                tile = true,
                tileSize = 16,
            })
            button_bar:SetBackdropColor(0, 0, 0, 0.5) -- Semi-transparent black
        end

        -- Update position from saved coordinates
        button_bar:ClearAllPoints()
        button_bar:SetPoint(SfuiDB.minimap_button_point or "TOP", Minimap,
            SfuiDB.minimap_button_relative_point or "BOTTOM", SfuiDB.minimap_button_x or 0,
            SfuiDB.minimap_button_y or sfui.config.minimap.button_bar.defaultY)

        button_bar:Show()

        -- Mouseover logic
        if not button_bar.sfuiMouseoverHooked then
            -- Create an invisible detector frame over the Minimap to avoid HookScript on a secure frame
            if not sfui.minimap.detector then
                -- Parent to MinimapCluster instead of Minimap
                sfui.minimap.detector = CreateFrame("Frame", nil, MinimapCluster)
                sfui.minimap.detector:SetAllPoints(Minimap)
                sfui.minimap.detector:SetFrameLevel(Minimap:GetFrameLevel() + 1)
                sfui.minimap.detector:EnableMouse(false) -- Pass through by default
            end

            local function update_alpha()
                if SfuiDB.minimap_buttons_mouseover then
                    local isHovering = button_bar:IsMouseOver() or Minimap:IsMouseOver()
                    if isHovering then
                        button_bar:SetAlpha(1)
                        if not sfui.minimap.ldbi then
                            sfui.minimap.ldbi = LibStub("LibDBIcon-1.0", true)
                        end
                        if sfui.minimap.ldbi and sfui.minimap.ldbi.OnMinimapEnter then
                            pcall(sfui.minimap.ldbi.OnMinimapEnter)
                        end
                    else
                        button_bar:SetAlpha(0)
                        if not sfui.minimap.ldbi then
                            sfui.minimap.ldbi = LibStub("LibDBIcon-1.0", true)
                        end
                        if sfui.minimap.ldbi and sfui.minimap.ldbi.OnMinimapLeave then
                            pcall(sfui.minimap.ldbi.OnMinimapLeave)
                        end
                    end
                else
                    button_bar:SetAlpha(1)
                end
            end

            button_bar:SetScript("OnEnter", update_alpha)
            button_bar:SetScript("OnLeave", function() C_Timer.After(0.1, update_alpha) end)

            -- Event-driven mouseover detection using Minimap frame
            -- This eliminates the 10Hz OnUpdate polling
            if Minimap then
                Minimap:HookScript("OnEnter", update_alpha)
                Minimap:HookScript("OnLeave", function() C_Timer.After(0.1, update_alpha) end)
            end

            button_bar.sfuiMouseoverHooked = true
        end

        -- Apply initial state
        if SfuiDB.minimap_buttons_mouseover then
            button_bar:SetAlpha(0)
        else
            button_bar:SetAlpha(1)
        end

        ButtonManager:collect_buttons()
        ButtonManager:arrange_buttons()

        if AddonCompartmentFrame then AddonCompartmentFrame:Hide() end
    else
        ButtonManager:restore_all()
        if button_bar then button_bar:Hide() end
        if AddonCompartmentFrame then AddonCompartmentFrame:Show() end
    end
end

function sfui.minimap.update_button_bar_position()
    if button_bar then
        button_bar:ClearAllPoints()
        button_bar:SetPoint(SfuiDB.minimap_button_point or "TOP", Minimap,
            SfuiDB.minimap_button_relative_point or "BOTTOM", SfuiDB.minimap_button_x or 0,
            SfuiDB.minimap_button_y or sfui.config.minimap.button_bar.defaultY)
    end
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
frame:RegisterEvent("ADDON_LOADED")

local startup_scans = 0
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        sfui.minimap.initialize_masque()
        if SfuiDB.minimap_auto_zoom then
            set_default_zoom()
        end
        sfui.minimap.enable_button_manager(SfuiDB.minimap_collect_buttons)

        if MinimapCluster and MinimapCluster.IndicatorFrame then
            MinimapCluster.IndicatorFrame:Hide(); MinimapCluster.IndicatorFrame:SetAlpha(0)
        end
        if MinimapCluster and MinimapCluster.BorderTop then
            MinimapCluster.BorderTop:Hide(); MinimapCluster.BorderTop:SetAlpha(0)
        end

        -- Startup timer to catch late-loading buttons
        if SfuiDB.minimap_collect_buttons then
            C_Timer.NewTicker(2, function(self)
                startup_scans = startup_scans + 1
                if startup_scans > 5 then
                    self:Cancel()
                else
                    if ButtonManager:collect_buttons() then
                        ButtonManager:arrange_buttons()
                    end
                end
            end)
        end

        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        return
    end

    if event == "ADDON_LOADED" then
        if SfuiDB.minimap_collect_buttons then
            if ButtonManager:collect_buttons() then
                ButtonManager:arrange_buttons()
            end
        end
        return
    end

    -- Autozoom on manual zoom changes
    if event == "MINIMAP_UPDATE_ZOOM" then
        if SfuiDB.minimap_auto_zoom and Minimap:GetZoom() ~= DEFAULT_ZOOM then
            if zoom_timer then
                zoom_timer:Cancel()
            end
            zoom_timer = C_Timer.NewTimer(SfuiDB.minimap_auto_zoom_delay or 5, set_default_zoom)
        end
    end
end)
