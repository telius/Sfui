local addonName, addon = ...
do
    local widget_frame, icons, value_labels = nil, {}, {}

    local function OnCurrencyIconEnter(self)
        securecall(pcall, GameTooltip.SetOwner, GameTooltip, self, "ANCHOR_RIGHT")
        securecall(pcall, GameTooltip.SetCurrencyByID, GameTooltip, self.id)
        GameTooltip:Show()
    end

    local function OnIconLeave(self)
        GameTooltip:Hide()
    end

    local function get_currency_details(currencyID)
        local currencyInfo = C_CurrencyInfo.GetCurrencyInfo(currencyID)
        if not currencyInfo then return nil end
        return {
            texture = currencyInfo.iconFileID,
            quantity = currencyInfo.quantity,
            on_mouseup = nil,
            on_enter = OnCurrencyIconEnter,
            on_leave = OnIconLeave,
        }
    end

    function sfui.update_currency_display()
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
        if widget_frame then return end
        local c = sfui.config.currency_frame
        widget_frame = CreateFrame("Frame", "sfui_currency_frame", UIParent, "BackdropTemplate")
        widget_frame:SetSize(c.width, c.height)
        widget_frame:SetPoint("BOTTOMLEFT", CharacterFrame, "BOTTOMLEFT", 0, -110)
        widget_frame:SetFrameStrata("HIGH")
        widget_frame:SetFrameLevel(CharacterFrame:GetFrameLevel() + 5)
        widget_frame:SetBackdrop({ bgFile = sfui.config.textures.white, tile = true, tileSize = 32 })
        widget_frame:SetBackdropColor(0, 0, 0, 0.5)

        local function update_visibility()
            if CharacterFrame:IsShown() then
                sfui.update_currency_display()
            else
                widget_frame:Hide()
            end
        end
        hooksecurefunc(CharacterFrame, "Show", update_visibility)
        hooksecurefunc(CharacterFrame, "Hide", update_visibility)

        local event_frame = CreateFrame("Frame")
        event_frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
        event_frame:SetScript("OnEvent", function()
            if widget_frame then
                sfui.update_currency_display()
            end
        end)
        update_visibility()
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
        GameTooltip:Hide()
    end

    local function OnItemIconEnter(self)
        securecall(pcall, GameTooltip.SetOwner, GameTooltip, self, "ANCHOR_RIGHT")
        securecall(pcall, GameTooltip.SetItemByID, GameTooltip, self.id)
        GameTooltip:Show()
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
        SfuiDB.items = SfuiDB.items or {}
        for _, id in ipairs(SfuiDB.items) do
            if id == itemID then return end
        end
        table.insert(SfuiDB.items, itemID)
        sfui.update_item_display()
    end

    function sfui.update_item_display()
        SfuiDB.items = SfuiDB.items or {}
        sfui.common.update_widget_bar(widget_frame, icons, value_labels, SfuiDB.items, get_item_details)
    end

    function sfui.create_item_frame()
        if widget_frame then return end
        local c = sfui.config.item_frame
        widget_frame = CreateFrame("Frame", "sfui_item_frame", UIParent, "BackdropTemplate")
        widget_frame:SetSize(c.width, c.height)
        widget_frame:SetPoint("TOPLEFT", "sfui_currency_frame", "BOTTOMLEFT", 0, 0)
        widget_frame:SetFrameStrata("HIGH")
        widget_frame:SetFrameLevel(sfui_currency_frame:GetFrameLevel())
        widget_frame:SetBackdrop({ bgFile = sfui.config.textures.white, tile = true, tileSize = 32 })
        widget_frame:SetBackdropColor(0, 0, 0, 0.5)

        local function update_visibility()
            if CharacterFrame:IsShown() then
                sfui.update_item_display()
            else
                widget_frame:Hide()
            end
        end
        hooksecurefunc(CharacterFrame, "Show", update_visibility)
        hooksecurefunc(CharacterFrame, "Hide", update_visibility)

        local event_frame = CreateFrame("Frame")
        event_frame:RegisterEvent("BAG_UPDATE")
        event_frame:SetScript("OnEvent", sfui.update_item_display)
        update_visibility()
    end
end
