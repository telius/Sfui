local addonName, addon = ...
sfui = sfui or {}

local CharacterFrame = _G.CharacterFrame
local GameTooltip = sfui.tooltip or _G.GameTooltip

local function UpdateCurrencyAnchors()
    local cFrame = _G.sfui_currency_frame
    local iFrame = _G.sfui_item_frame
    if not CharacterFrame then return end

    local isChonky = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("ChonkyCharacterSheet")
    local anchorParent = isChonky and (_G.CharacterFrameBgbg or _G.CharacterFrameBg or CharacterFrame) or CharacterFrame
    local offsetY = isChonky and -54 or -110

    if cFrame then
        cFrame:ClearAllPoints()
        cFrame:SetPoint("TOPLEFT", anchorParent, "BOTTOMLEFT", 0, offsetY)
    end

    if iFrame then
        iFrame:ClearAllPoints()
        if cFrame and cFrame:IsShown() then
            iFrame:SetPoint("TOPLEFT", cFrame, "BOTTOMLEFT", 0, -2)
        else
            iFrame:SetPoint("TOPLEFT", anchorParent, "BOTTOMLEFT", 0, offsetY)
        end
    end
end

if CharacterFrame and CharacterFrame.HookScript then
    CharacterFrame:HookScript("OnShow", function()
        UpdateCurrencyAnchors()
        if sfui.update_currency_display then sfui.update_currency_display() end
        if sfui.update_item_display then sfui.update_item_display() end
    end)
end

do
    local widget_frame, icons, value_labels = nil, {}, {}

    local function get_currency_details(currency_id)
        local info = C_CurrencyInfo.GetCurrencyInfo(currency_id)
        if not info then return nil end
        return {
            texture = info.iconFileID,
            quantity = info.quantity,
            on_enter = function(self)
                if not GameTooltip then return end
                pcall(function()
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetCurrencyByID(currency_id)
                    GameTooltip:Show()
                end)
            end,
            on_leave = function()
                if GameTooltip then GameTooltip:Hide() end
            end
        }
    end

    function sfui.update_currency_display()
        if not widget_frame then return end
        UpdateCurrencyAnchors()
        local source_data = {}
        local i = 1
        while true do
            local backpackCurrencyInfo = C_CurrencyInfo.GetBackpackCurrencyInfo(i)
            if not backpackCurrencyInfo then break end
            table.insert(source_data, backpackCurrencyInfo.currencyTypesID)
            i = i + 1
        end
        sfui.common.update_widget_bar(widget_frame, icons, value_labels, source_data, get_currency_details)
        UpdateCurrencyAnchors()
    end

    function sfui.create_currency_frame()
        if widget_frame or not CharacterFrame then return end
        local c = sfui.config.currency_frame
        widget_frame = CreateFrame("Frame", "sfui_currency_frame", CharacterFrame, "BackdropTemplate")
        widget_frame:SetSize(c.width, c.height)
        widget_frame:SetFrameStrata("HIGH")
        widget_frame:SetFrameLevel(CharacterFrame:GetFrameLevel() + 5)
        widget_frame:SetBackdrop({ bgFile = sfui.config.textures.white, tile = true, tileSize = 32 })
        widget_frame:SetBackdropColor(0, 0, 0, 0.5)

        UpdateCurrencyAnchors()

        widget_frame:SetScript("OnShow", function()
            UpdateCurrencyAnchors()
            sfui.update_currency_display()
        end)

        sfui.events.RegisterEvent("CURRENCY_DISPLAY_UPDATE", function()
            if widget_frame and (CharacterFrame:IsShown() or widget_frame:IsShown()) then
                sfui.update_currency_display()
            end
        end)
    end
end

do
    local widget_frame, icons, value_labels = nil, {}, {}
    local function remove_item(itemID)
        if not SfuiDB or not SfuiDB.items then return end
        for i, id in ipairs(SfuiDB.items) do
            if id == itemID then
                table.remove(SfuiDB.items, i)
                sfui.update_item_display()
                return
            end
        end
    end

    local function OnIconLeave(self)
        if GameTooltip then GameTooltip:Hide() end
    end

    local function OnItemIconEnter(self)
        if not GameTooltip or not self.id then return end
        pcall(function()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.id)
            GameTooltip:Show()
        end)
    end

    local function OnItemIconMouseUp(self, button)
        if button == "RightButton" then
            remove_item(self.id)
        end
    end

    local function get_item_details(itemID)
        local _, _, _, _, _, _, _, _, _, texture = C_Item.GetItemInfo(itemID)
        if not texture then return nil end
        return {
            texture = texture,
            quantity = C_Item.GetItemCount(itemID),
            on_enter = OnItemIconEnter,
            on_leave = OnIconLeave,
            on_mouseup = OnItemIconMouseUp,
        }
    end

    function sfui.add_item(itemID)
        if not itemID then return end
        for _, id in ipairs(SfuiDB.items) do
            if id == itemID then return end
        end
        table.insert(SfuiDB.items, itemID)
        sfui.update_item_display()
    end

    function sfui.update_item_display()
        if not widget_frame then return end
        UpdateCurrencyAnchors()
        sfui.common.update_widget_bar(widget_frame, icons, value_labels, SfuiDB.items, get_item_details)
        UpdateCurrencyAnchors()
    end

    function sfui.create_item_frame()
        if widget_frame or not CharacterFrame then return end
        local c = sfui.config.item_frame
        widget_frame = CreateFrame("Frame", "sfui_item_frame", CharacterFrame, "BackdropTemplate")
        widget_frame:SetSize(c.width, c.height)
        widget_frame:SetFrameStrata("HIGH")
        widget_frame:SetFrameLevel(CharacterFrame:GetFrameLevel() + 5)
        widget_frame:SetBackdrop({ bgFile = sfui.config.textures.white, tile = true, tileSize = 32 })
        widget_frame:SetBackdropColor(0, 0, 0, 0.5)

        UpdateCurrencyAnchors()

        widget_frame:SetScript("OnShow", function()
            UpdateCurrencyAnchors()
            sfui.update_item_display()
        end)

        sfui.events.RegisterEvent("BAG_UPDATE", function()
            if widget_frame and (CharacterFrame:IsShown() or widget_frame:IsShown()) then
                sfui.update_item_display()
            end
        end)
    end

    function sfui.currency_debug_info()
        return {
            currencyFrameCreated = _G.sfui_currency_frame ~= nil,
            itemFrameCreated = _G.sfui_item_frame ~= nil,
        }
    end
end
