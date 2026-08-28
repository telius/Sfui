local addonName, addon = ...
sfui = sfui or {}

local CharacterFrame = _G.CharacterFrame
local PaperDollFrame = _G.PaperDollFrame or _G.CharacterFrame

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
        if not widget_frame or not widget_frame:IsShown() then return end
        local source_data = {}
        local i = 1
        while true do
            local backpackCurrencyInfo = C_CurrencyInfo.GetBackpackCurrencyInfo(i)
            if not backpackCurrencyInfo then break end
            table.insert(source_data, backpackCurrencyInfo.currencyTypesID)
            i = i + 1
        end
        sfui.common.update_widget_bar(widget_frame, icons, value_labels, source_data, get_currency_details)
    end

    function sfui.create_currency_frame()
        if widget_frame or not CharacterFrame then return end
        local c = sfui.config.currency_frame
        widget_frame = CreateFrame("Frame", "sfui_currency_frame", CharacterFrame, "BackdropTemplate")
        widget_frame:SetSize(c.width, c.height)
        widget_frame:SetPoint("BOTTOMLEFT", CharacterFrame, "BOTTOMLEFT", 0, -110)
        widget_frame:SetFrameStrata("HIGH")
        widget_frame:SetFrameLevel(CharacterFrame:GetFrameLevel() + 5)
        widget_frame:SetBackdrop({ bgFile = sfui.config.textures.white, tile = true, tileSize = 32 })
        widget_frame:SetBackdropColor(0, 0, 0, 0.5)

        widget_frame:SetScript("OnShow", function()
            sfui.update_currency_display()
        end)

        sfui.events.RegisterEvent("CURRENCY_DISPLAY_UPDATE", function()
            if widget_frame and widget_frame:IsShown() then
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
        if not widget_frame or not widget_frame:IsShown() then return end
        sfui.common.update_widget_bar(widget_frame, icons, value_labels, SfuiDB.items, get_item_details)
    end

    function sfui.create_item_frame()
        if widget_frame or not CharacterFrame then return end
        local c = sfui.config.item_frame
        widget_frame = CreateFrame("Frame", "sfui_item_frame", CharacterFrame, "BackdropTemplate")
        widget_frame:SetSize(c.width, c.height)
        widget_frame:SetPoint("TOPLEFT", "sfui_currency_frame", "BOTTOMLEFT", 0, 0)
        widget_frame:SetFrameStrata("HIGH")
        widget_frame:SetFrameLevel(CharacterFrame:GetFrameLevel() + 5)
        widget_frame:SetBackdrop({ bgFile = sfui.config.textures.white, tile = true, tileSize = 32 })
        widget_frame:SetBackdropColor(0, 0, 0, 0.5)

        widget_frame:SetScript("OnShow", function()
            sfui.update_item_display()
        end)

        sfui.events.RegisterEvent("BAG_UPDATE", function()
            if widget_frame and widget_frame:IsShown() then
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
