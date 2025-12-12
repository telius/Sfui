local _, sfui = ...
sfui = sfui or {}
sfui.vendor = {}

-- Forward declaration
local UpdateList

-- ============================================================================
-- Configuration & Constants
-- ============================================================================
local CFG = (sfui.config and sfui.config.vendor) or {
    frame_width = 800,
    frame_height = 480,
    item_width = 190,
    item_height = 58,
    rows_per_column = 6,
    icon_size = 46,
}

local TEXTURE_WHITE = "Interface/Buttons/WHITE8X8"
if sfui.config and sfui.config.textures then
    TEXTURE_WHITE = sfui.config.textures.white
end

local FILTER_ALL = LE_LOOT_FILTER_ALL or 1
local FILTER_CLASS = LE_LOOT_FILTER_CLASS or 2
local FILTER_SPEC = LE_LOOT_FILTER_SPEC or 3

-- State
local currentMode = "MERCHANT" -- "MERCHANT" or "BUYBACK"
local hideKnown = true
local itemButtons = {}
local currencyButtons = {}

-- ============================================================================
-- Frame Creation
-- ============================================================================
local frame = CreateFrame("Frame", "sfui_vendor_frame", UIParent, "BackdropTemplate")
frame:SetSize(CFG.frame_width, CFG.frame_height)
frame:SetPoint("CENTER")
frame:SetFrameStrata("HIGH")
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetBackdrop({
    bgFile = TEXTURE_WHITE,
    edgeFile = TEXTURE_WHITE,
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 }
})
frame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
frame:SetBackdropBorderColor(0, 0, 0, 1)
frame:Hide()

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
closeBtn:SetScript("OnClick", function()
    CloseMerchant()
end)

-- Filter Button (Header)
local filterBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
filterBtn:SetSize(120, 22)
filterBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -5, -5)
filterBtn:SetText("Filter: All")

local filterMenu = CreateFrame("Frame", nil, frame, "BackdropTemplate")
filterMenu:SetSize(120, 70)
filterMenu:SetPoint("TOP", filterBtn, "BOTTOM", 0, -2)
filterMenu:SetBackdrop({
    bgFile = TEXTURE_WHITE,
    edgeFile = TEXTURE_WHITE,
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
})
filterMenu:SetBackdropColor(0.1, 0.1, 0.1, 1)
filterMenu:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
filterMenu:SetFrameStrata("DIALOG")
filterMenu:Hide()

local function SelectFilter(id, text)
    SetMerchantFilter(id)
    filterBtn:SetText("Filter: " .. text)
    filterMenu:Hide()
    UpdateList()
end

local function CreateFilterOption(text, id, index)
    local btn = CreateFrame("Button", nil, filterMenu, "UIPanelButtonTemplate")
    btn:SetSize(110, 20)
    btn:SetPoint("TOP", filterMenu, "TOP", 0, -5 - ((index-1)*22))
    btn:SetText(text)
    btn:SetScript("OnClick", function() SelectFilter(id, text) end)
    return btn
end

CreateFilterOption("All Items", FILTER_ALL, 1)
CreateFilterOption("My Class", FILTER_CLASS, 2)
CreateFilterOption("My Spec", FILTER_SPEC, 3)

filterBtn:SetScript("OnClick", function()
    if filterMenu:IsShown() then filterMenu:Hide() else filterMenu:Show() end
end)

-- Portrait & Title
local portrait = frame:CreateTexture(nil, "OVERLAY")
portrait:SetSize(60, 60)
portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", -5, 5)
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
title:SetPoint("LEFT", portrait, "RIGHT", 5, 10)
title:SetPoint("TOP", frame, "TOP", 0, -10)
title:SetText("Merchant")
local subTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
subTitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)

-- ScrollFrame (Container)
local scrollFrame = CreateFrame("ScrollFrame", "sfui_vendor_scroll", frame)
scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -50)
scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 80)
scrollFrame:EnableMouse(true)

local scrollChild = CreateFrame("Frame")
scrollChild:SetSize(1, 1) 
scrollFrame:SetScrollChild(scrollChild)

-- Horizontal Slider
local slider = CreateFrame("Slider", "sfui_vendor_hslider", frame, "BackdropTemplate")
sfui.vendor.slider = slider
slider:SetOrientation("HORIZONTAL")
slider:SetHeight(12)
slider:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -5)
slider:SetPoint("TOPRIGHT", scrollFrame, "BOTTOMRIGHT", 0, -5)
slider:SetBackdrop({ bgFile = TEXTURE_WHITE, edgeFile = TEXTURE_WHITE, edgeSize = 1, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
slider:SetBackdropColor(0.1, 0.1, 0.1, 1)
slider:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

local thumb = slider:CreateTexture(nil, "OVERLAY")
thumb:SetTexture(TEXTURE_WHITE)
thumb:SetSize(24, 12)
thumb:SetVertexColor(0.6, 0.6, 0.6, 1)
slider:SetThumbTexture(thumb)

slider:SetMinMaxValues(0, 1)
slider:SetValue(0)
slider:SetScript("OnValueChanged", function(self, value)
    scrollFrame:SetHorizontalScroll(value)
end)

-- Mouse Wheel Scroll
scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local cur = slider:GetValue()
    local min, max = slider:GetMinMaxValues()
    local step = 60
    local newVal = cur - (delta * step)
    if newVal < min then newVal = min end
    if newVal > max then newVal = max end
    slider:SetValue(newVal)
end)

-- ============================================================================
-- Custom Quantity Input Frame
-- ============================================================================
local inputFrame = CreateFrame("Frame", "sfui_vendor_buy_input", frame, "BackdropTemplate")
inputFrame:SetSize(200, 100)
inputFrame:SetPoint("CENTER")
inputFrame:SetBackdrop({
    bgFile = TEXTURE_WHITE,
    edgeFile = TEXTURE_WHITE,
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 }
})
inputFrame:SetBackdropColor(0.1, 0.1, 0.1, 1)
inputFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
inputFrame:SetFrameStrata("DIALOG")
inputFrame:Hide()

local inputLabel = inputFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
inputLabel:SetPoint("TOP", 0, -10)
inputLabel:SetText("Enter Quantity:")

local editBox = CreateFrame("EditBox", nil, inputFrame, "InputBoxTemplate")
editBox:SetSize(100, 20)
editBox:SetPoint("CENTER", 0, 5)
editBox:SetAutoFocus(true)
editBox:SetNumeric(true)
editBox:SetMaxLetters(4)

local activeIndex = nil

local function Buy()
    local qty = tonumber(editBox:GetText())
    if qty and qty > 0 and activeIndex then
        BuyMerchantItem(activeIndex, qty)
    end
    inputFrame:Hide()
end

editBox:SetScript("OnEnterPressed", Buy)
editBox:SetScript("OnEscapePressed", function() inputFrame:Hide() end)

local okBtn = CreateFrame("Button", nil, inputFrame, "UIPanelButtonTemplate")
okBtn:SetText("Buy")
okBtn:SetSize(60, 22)
okBtn:SetPoint("BOTTOMLEFT", 30, 15)
okBtn:SetScript("OnClick", Buy)

local cancelBtn = CreateFrame("Button", nil, inputFrame, "UIPanelButtonTemplate")
cancelBtn:SetText("Cancel")
cancelBtn:SetSize(60, 22)
cancelBtn:SetPoint("BOTTOMRIGHT", -30, 15)
cancelBtn:SetScript("OnClick", function() inputFrame:Hide() end)

function inputFrame:Open(index)
    activeIndex = index
    editBox:SetText("1")
    editBox:HighlightText()
    self:Show()
end

-- ============================================================================
-- Footer
-- ============================================================================
local footer = CreateFrame("Frame", nil, frame)
footer:SetHeight(30)
footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)

-- Mode Button (Toggle)
local modeBtn = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
modeBtn:SetSize(100, 22)
modeBtn:SetPoint("LEFT", footer, "LEFT", 0, 0)
modeBtn:SetText("Buyback")

-- Hide Known Button
local hideKnownBtn = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
hideKnownBtn:SetSize(100, 22)
hideKnownBtn:SetPoint("LEFT", modeBtn, "RIGHT", 10, 0)
hideKnownBtn:SetText("Hide Known: On")
hideKnownBtn:SetScript("OnClick", function(self)
    hideKnown = not hideKnown
    if hideKnown then
        self:SetText("Hide Known: On")
    else
        self:SetText("Hide Known: Off")
    end
    UpdateList()
end)

-- Repair / Sell
local repairBtn = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
repairBtn:SetSize(80, 22)
repairBtn:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
repairBtn:SetText("Repair All")

local guildRepairBtn = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
guildRepairBtn:SetSize(80, 22)
guildRepairBtn:SetPoint("RIGHT", repairBtn, "LEFT", -5, 0)
guildRepairBtn:SetText("Guild Rep")

local sellJunkBtn = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
sellJunkBtn:SetSize(80, 22)
sellJunkBtn:SetPoint("RIGHT", guildRepairBtn, "LEFT", -5, 0)
sellJunkBtn:SetText("Sell Junk")

local currencyContainer = CreateFrame("Frame", nil, footer)
currencyContainer:SetPoint("LEFT", hideKnownBtn, "RIGHT", 10, 0)
currencyContainer:SetPoint("RIGHT", sellJunkBtn, "LEFT", -10, 0)
currencyContainer:SetHeight(24)

-- Set footer buttons to white text
local footerBtns = {modeBtn, hideKnownBtn, repairBtn, guildRepairBtn, sellJunkBtn}
for _, b in ipairs(footerBtns) do
    b:GetFontString():SetTextColor(1, 1, 1)
end

-- ============================================================================
-- Helper Functions
-- ============================================================================
local function GetPlayerFunds(link)
    if not link then return 0 end
    if link:find("currency:") then
        local id = link:match("currency:(%d+)")
        if id then
            local info = C_CurrencyInfo.GetCurrencyInfo(tonumber(id))
            return info and info.quantity or 0
        end
    elseif link:find("item:") then
        local id = link:match("item:(%d+)")
        if id then
            return GetItemCount(tonumber(id), true)
        end
    end
    return 0
end

local function IsItemKnown(index, isBuyback)
    local link = isBuyback and GetBuybackItemLink(index) or GetMerchantItemLink(index)
    if not link then return false end
    
    local itemID = GetItemInfoInstant(link)
    
    -- Transmog Check
    if itemID then
        local isTransmog = C_TransmogCollection.GetItemInfo(itemID)
        if isTransmog then
            if C_TransmogCollection.PlayerHasTransmog(itemID) then
                return true
            end
        end
    end

    local tooltipData = isBuyback and C_TooltipInfo.GetBuybackItem(index) or C_TooltipInfo.GetMerchantItem(index)
    
    if tooltipData then
        for _, line in ipairs(tooltipData.lines) do
            local text = line.leftText
            if text then
                if text == ITEM_SPELL_KNOWN or text == "Already known" then
                    return true
                end
                if text:find("Collected %(") then
                    return true
                end
                if text:find("collected this appearance") then
                    return true
                end
            end
        end
    end
    return false
end

local function GetUpgradeInfo(index, isBuyback, isPurchasable, isUsable)
    local link = isBuyback and GetBuybackItemLink(index) or GetMerchantItemLink(index)
    if not link or not IsEquippableItem(link) then return nil end
    
    local iLevel = GetDetailedItemLevelInfo(link)
    
    local track = ""
    local tooltipData = isBuyback and C_TooltipInfo.GetBuybackItem(index) or C_TooltipInfo.GetMerchantItem(index)
    
    local isLocked = (not isPurchasable) or (not isUsable)
    
    if tooltipData then
        for _, line in ipairs(tooltipData.lines) do
            local text = line.leftText
            if text then
                local tName, cur, max = text:match("(%a+) (%d+)/(%d+)")
                if tName and cur and max then
                    local color = "|cffffffff" -- Default White
                    
                    if isLocked then
                        color = "|cff808080"
                    else
                        if tName == "Explorer" then tName = "Exp"
                        elseif tName == "Adventurer" then tName = "Adv"
                        elseif tName == "Veteran" then tName = "Vet"
                        elseif tName == "Champion" then tName = "Champ"; color = "|cff1eff00" -- Green
                        elseif tName == "Hero" then tName = "Hero"; color = "|cff0070dd" -- Blue
                        elseif tName == "Myth" then tName = "Myth"; color = "|cffa335ee" -- Purple
                        elseif tName == "Awakened" then tName = "Awk"; color = "|cffff8000" -- Orange
                        end
                    end
                    
                    track = color .. tName .. " " .. cur .. "/" .. max .. "|r"
                    break
                end
            end
        end
    end
    
    local parts = {}
    if iLevel then 
        local lvlColor = isLocked and "|cff808080" or "|cff6600ff"
        table.insert(parts, lvlColor .. iLevel .. "|r") 
    end
    if track ~= "" then table.insert(parts, track) end
    
    if #parts > 0 then
        return table.concat(parts, " ")
    end
    return nil
end

local function GetCostString(index, isPurchasable, isUsable)
    local parts = {}
    
    local upgradeInfo = GetUpgradeInfo(index, false, isPurchasable, isUsable)
    local upgradeStr = upgradeInfo
    
    local price = select(3, GetMerchantItemInfo(index))
    if price and price > 0 then
        local afford = GetMoney() >= price
        local text = GetCoinTextureString(price)
        if not afford then text = "|cffff0000" .. text .. "|r" end
        table.insert(parts, text)
    end
    
    local extendedCost = select(8, GetMerchantItemInfo(index))
    if extendedCost then
        local count = GetMerchantItemCostInfo(index)
        for i = 1, count do
            local texture, value, link, name = GetMerchantItemCostItem(index, i)
            if texture and value then
                local playerAmount = GetPlayerFunds(link)
                local color = (playerAmount >= value) and "|cffffffff" or "|cffff0000"
                table.insert(parts, color .. BreakUpLargeNumbers(value) .. "|r |T" .. texture .. ":12:12|t")
            end
        end
    end
    
    local costStr = table.concat(parts, "  ")
    if upgradeStr then costStr = costStr .. "  " .. upgradeStr end
    return costStr
end

-- ============================================================================
-- Update Logic
-- ============================================================================
local function UpdateCurrencyDisplay()
    -- Hide all
    for _, btn in ipairs(currencyButtons) do btn:Hide() end
    
    if currentMode ~= "MERCHANT" then return end
    
    local usedCurrencies = {}
    local numItems = GetMerchantNumItems()
    for i = 1, numItems do
        local extendedCost = select(8, GetMerchantItemInfo(i))
        if extendedCost then
            local count = GetMerchantItemCostInfo(i)
            for j = 1, count do
                local texture, value, link, name = GetMerchantItemCostItem(i, j)
                if link and not usedCurrencies[link] then
                     usedCurrencies[link] = { texture = texture, amount = GetPlayerFunds(link) }
                end
            end
        end
    end
    
    local prev = nil
    local i = 1
    for link, data in pairs(usedCurrencies) do
        local btn = currencyButtons[i]
        if not btn then
            btn = CreateFrame("Button", nil, currencyContainer)
            btn:SetSize(80, 24)
            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetSize(16, 16)
            btn.icon:SetPoint("LEFT", 0, 0)
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetHyperlink(self.link)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            currencyButtons[i] = btn
        end
        
        btn.link = link
        btn.icon:SetTexture(data.texture)
        btn.text:SetText(BreakUpLargeNumbers(data.amount))
        btn:Show()
        
        local w = btn.text:GetStringWidth() + 24
        btn:SetWidth(w)
        
        btn:ClearAllPoints()
        if not prev then
            btn:SetPoint("RIGHT", currencyContainer, "RIGHT", 0, 0)
        else
            btn:SetPoint("RIGHT", prev, "LEFT", -10, 0)
        end
        prev = btn
        i = i + 1
    end
end

local function GetItemButton(i)
    if not itemButtons[i] then
        local btn = CreateFrame("Button", "sfui_vendor_item_"..i, scrollChild, "BackdropTemplate")
        btn:SetSize(CFG.item_width - 5, CFG.item_height - 5)
        
        btn:SetBackdrop({
            bgFile = TEXTURE_WHITE,
            edgeFile = nil,
            tile = false,
        })
        btn:SetBackdropColor(0.15, 0.15, 0.15, 0.4)
        
        -- Icon
        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetSize(CFG.icon_size, CFG.icon_size)
        btn.icon:SetPoint("LEFT", 4, 0)
        
        -- Name
        btn.name = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        btn.name:SetPoint("TOPLEFT", btn.icon, "TOPRIGHT", 8, 0)
        btn.name:SetJustifyH("LEFT")
        btn.name:SetSize(125, 24)
        btn.name:SetWordWrap(true)
        
        -- Price/Cost
        btn.price = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.price:SetPoint("BOTTOMLEFT", btn.icon, "BOTTOMRIGHT", 8, 4)
        btn.price:SetJustifyH("LEFT")
        
        -- Click Logic
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                if currentMode == "MERCHANT" then
                    if IsShiftKeyDown() then
                         local maxStack = GetMerchantItemMaxStack(self.index)
                         if maxStack > 1 then
                             inputFrame:Open(self.index)
                         else
                             BuyMerchantItem(self.index)
                         end
                    else
                         BuyMerchantItem(self.index)
                    end
                else
                    BuybackItem(self.index)
                end
            end
        end)
        
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if currentMode == "MERCHANT" then
                GameTooltip:SetMerchantItem(self.index)
                GameTooltip_ShowCompareItem(GameTooltip)
            else
                GameTooltip:SetBuybackItem(self.index)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        btn:SetHighlightTexture("Interface/Buttons/UI-Listbox-Highlight2")
        itemButtons[i] = btn
    end
    return itemButtons[i]
end

UpdateList = function()
    for _, btn in ipairs(itemButtons) do btn:Hide() end
    local numItems = 0
    if currentMode == "MERCHANT" then numItems = GetMerchantNumItems() else numItems = GetNumBuybackItems() end
    
    local visibleIndices = {}
    for i = 1, numItems do
        local show = true
        if hideKnown then
            if IsItemKnown(i, currentMode == "BUYBACK") then show = false end
        end
        if show then table.insert(visibleIndices, i) end
    end
    
    local rows = CFG.rows_per_column
    local row = 0
    local col = 0
    
    for _, index in ipairs(visibleIndices) do
        local btn = GetItemButton(_) 
        btn.index = index
        btn:Show()
        
        local name, texture, price, quantity, numAvailable, isPurchasable, isUsable
        if currentMode == "MERCHANT" then
            name, texture, price, quantity, numAvailable, isPurchasable, isUsable = GetMerchantItemInfo(index)
        else
            name, texture, price, quantity, numAvailable, isPurchasable = GetBuybackItemInfo(index)
            isUsable = true
        end

        if name then
            btn.icon:SetTexture(texture)
            btn.name:SetText(name)
            
            -- Colorize Name by Quality
            local link = nil
            if currentMode == "MERCHANT" then link = GetMerchantItemLink(index)
            else link = GetBuybackItemLink(index) end
            
            local r, g, b = 1, 1, 1
            if link then
                local _, _, quality = GetItemInfo(link)
                if quality then
                    r, g, b = GetItemQualityColor(quality)
                end
            end
            
            if not isPurchasable and currentMode == "MERCHANT" then
                btn.icon:SetVertexColor(0.5, 0.5, 0.5)
                btn.name:SetTextColor(0.5, 0.5, 0.5)
            else
                btn.icon:SetVertexColor(1, 1, 1)
                btn.name:SetTextColor(r, g, b)
            end
            
            if currentMode == "MERCHANT" then
                btn.price:SetText(GetCostString(index, isPurchasable, isUsable))
            else
                if price and price > 0 then
                    btn.price:SetText(GetCoinTextureString(price))
                else
                     btn.price:SetText("")
                end
            end
            
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", col * CFG.item_width, -row * CFG.item_height)
            
            row = row + 1
            if row >= rows then
                row = 0
                col = col + 1
            end
        end
    end
    
    local totalCols = col
    if row > 0 then totalCols = totalCols + 1 end
    
    local contentWidth = totalCols * CFG.item_width
    scrollChild:SetSize(math.max(contentWidth, 1), rows * CFG.item_height)
    
    local visibleWidth = scrollFrame:GetWidth()
    local maxScroll = math.max(0, contentWidth - visibleWidth)
    slider:SetMinMaxValues(0, maxScroll)
    if slider:GetValue() > maxScroll then slider:SetValue(maxScroll) end
    
    UpdateCurrencyDisplay()
end

-- ============================================================================
-- Interactions
-- ============================================================================
modeBtn:SetScript("OnClick", function(self)
    if currentMode == "MERCHANT" then
        currentMode = "BUYBACK"
        title:SetText("Buyback")
        self:SetText("Merchant")
        filterBtn:Hide()
    else
        currentMode = "MERCHANT"
        title:SetText("Merchant")
        self:SetText("Buyback")
        filterBtn:Show()
    end
    slider:SetValue(0)
    UpdateList()
end)

repairBtn:SetScript("OnClick", function()
    RepairAllItems()
    PlaySound(SOUNDKIT.ITEM_REPAIR)
end)

guildRepairBtn:SetScript("OnClick", function()
    RepairAllItems(true)
    PlaySound(SOUNDKIT.ITEM_REPAIR)
end)

sellJunkBtn:SetScript("OnClick", function()
    if C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
        C_MerchantFrame.SellAllJunkItems()
    else
        for bag = 0, 4 do
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.hyperlink then
                    local _, _, quality, _, _, _, _, _, _, _, price = GetItemInfo(info.hyperlink)
                    if quality == 0 and price and price > 0 then
                        C_Container.UseContainerItem(bag, slot)
                    end
                end
            end
        end
    end
end)

local function UpdateRepairButtons()
    local canRepair = CanMerchantRepair()
    local repairCost, canRepairItems = GetRepairAllCost()
    if canRepair and canRepairItems then
        repairBtn:Enable(); repairBtn:GetFontString():SetTextColor(1,1,1)
        if CanGuildBankRepair() then guildRepairBtn:Enable(); guildRepairBtn:GetFontString():SetTextColor(1,1,1)
        else guildRepairBtn:Disable(); guildRepairBtn:GetFontString():SetTextColor(0.5,0.5,0.5) end
    else
        repairBtn:Disable(); repairBtn:GetFontString():SetTextColor(0.5,0.5,0.5)
        guildRepairBtn:Disable(); guildRepairBtn:GetFontString():SetTextColor(0.5,0.5,0.5)
    end
end

-- ============================================================================
-- Event Handling
-- ============================================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")

eventFrame:SetScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" then
        MerchantFrame:SetAlpha(0) 
        MerchantFrame:EnableMouse(false)
        
        -- Auto Sell Junk (Trigger button click)
        sellJunkBtn:Click()
        
        if CanMerchantRepair() then
            repairBtn:Enable()
            if CanGuildBankRepair() then
                guildRepairBtn:Enable()
            else
                guildRepairBtn:Disable()
            end
        else
            repairBtn:Disable()
            guildRepairBtn:Disable()
        end
        
        frame:Show()
        currentMode = "MERCHANT"
        
        filterBtn:Show()
        filterBtn:SetText("Filter: All")
        SetMerchantFilter(FILTER_ALL)
        
        SetPortraitTexture(portrait, "npc")
        title:SetText(UnitName("npc"))
        
        -- Get Title
        subTitle:SetText("")
        if C_TooltipInfo and C_TooltipInfo.GetUnit then
            local data = C_TooltipInfo.GetUnit("npc")
            if data and data.lines and data.lines[2] then
                local text = data.lines[2].leftText
                if text and not text:find("Level") then
                    subTitle:SetText("<" .. text .. ">")
                end
            end
        end
        
        slider:SetValue(0)
        UpdateList()
        UpdateRepairButtons()
    elseif event == "MERCHANT_CLOSED" then
        frame:Hide()
        MerchantFrame:SetAlpha(1)
        MerchantFrame:EnableMouse(true)
    elseif event == "MERCHANT_UPDATE" or event == "CURRENCY_DISPLAY_UPDATE" or event == "BAG_UPDATE" or event == "UPDATE_INVENTORY_DURABILITY" then
        if frame:IsShown() then
            UpdateList()
            UpdateRepairButtons()
        end
    end
end)