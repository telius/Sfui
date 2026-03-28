local addonName, addon = ...
---@diagnostic disable: undefined-global
-- frames/merchant.lua
-- Custom 4x7 grid merchant frame for sfui

sfui = sfui or {}
sfui.merchant = {}

local colors = sfui.config.colors

local cfg = sfui.config.merchant
local NUM_ROWS = cfg.grid.rows
local NUM_COLS = cfg.grid.cols
local ITEMS_PER_PAGE = NUM_ROWS * NUM_COLS

sfui.merchant.lootFilterState = 0 -- 0=All, 1=Class, 2=Spec

-- Cache player data for filtering (Performance optimization)
local playerClass, playerClassID = sfui.common.get_player_class()
local playerSpecID = sfui.common.get_current_spec_id() -- Cache spec ID
local classArmor = {
    ["WARRIOR"] = 4,
    ["PALADIN"] = 4,
    ["DEATHKNIGHT"] = 4,
    ["HUNTER"] = 3,
    ["SHAMAN"] = 3,
    ["EVOKER"] = 3,
    ["DRUID"] = 2,
    ["MONK"] = 2,
    ["ROGUE"] = 2,
    ["DEMONHUNTER"] = 2,
    ["MAGE"] = 1,
    ["PRIEST"] = 1,
    ["WARLOCK"] = 1,
}
local preferredArmor = classArmor[playerClass]

-- Update spec cache when spec changes
local specUpdateFrame = CreateFrame("Frame")
specUpdateFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
specUpdateFrame:SetScript("OnEvent", function()
    playerSpecID = sfui.common.get_current_spec_id()
end)

-- Memory optimization: Table pooling and scratch tables
local tablePool = {}
local function getTable()
    local t = next(tablePool)
    if t then
        tablePool[t] = nil
        return t
    end
    return {}
end

local function releaseTable(t)
    if not t then return end
    wipe(t)
    tablePool[t] = true
end

local function releaseCache(cache)
    if not cache then return end
    for k, t in pairs(cache) do
        releaseTable(t)
        cache[k] = nil
    end
end

local scratchItemData = {}
local sortedCurrencyItems = {}

local frame = CreateFrame("Frame", "SfuiMerchantFrame", UIParent, "BackdropTemplate")
frame:SetSize(cfg.frame.width, cfg.frame.height)
frame:SetPoint("CENTER")
frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = nil,
    tile = true,
    tileSize = 32,
    edgeSize = 0,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
})
frame:SetBackdropColor(unpack(sfui.config.appearance.backdropColor))
frame:Hide()
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

frame.itemHover = nil
sfui.merchant.frame = frame

frame.portrait = frame:CreateTexture(nil, "OVERLAY")
frame.portrait:SetSize(60, 60)
frame.portrait:SetPoint("TOPLEFT", 10, 30)

frame.merchantName = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.merchantName:SetPoint("TOPLEFT", frame, "TOPLEFT", 80, -4)
frame.merchantName:SetJustifyH("LEFT")

frame.merchantTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
frame.merchantTitle:SetPoint("TOPLEFT", frame.merchantName, "BOTTOMLEFT", 0, -2)
frame.merchantTitle:SetJustifyH("LEFT")

local CreateFlatButton = sfui.common.create_flat_button

local closeBtn = CreateFlatButton(frame, "X", 20, 20)
closeBtn:SetPoint("TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() frame:Hide() end)

local filterDropdownBtn = CreateFlatButton(frame, "showing all", 100, 20)
filterDropdownBtn:SetPoint("RIGHT", closeBtn, "LEFT", -5, 0)
filterDropdownBtn:SetScript("OnClick", function(self)
    MenuUtil.CreateContextMenu(self, function(owner, rootDescription)
        rootDescription:SetTag("MENU_MERCHANT_FILTER");

        rootDescription:CreateButton("All Items", function()
            sfui.merchant.lootFilterState = 0
            if SfuiDB.merchant then SfuiDB.merchant.lootFilterState = 0 end
            self:SetText("showing all")
            sfui.merchant.reset_scroll_and_rebuild()
        end);
        rootDescription:CreateButton("Current Class", function()
            sfui.merchant.lootFilterState = 1
            if SfuiDB.merchant then SfuiDB.merchant.lootFilterState = 1 end
            self:SetText("current class")
            sfui.merchant.reset_scroll_and_rebuild()
        end);
        rootDescription:CreateButton("Current Specialization", function()
            sfui.merchant.lootFilterState = 2
            if SfuiDB.merchant then SfuiDB.merchant.lootFilterState = 2 end
            self:SetText("current spec")
            sfui.merchant.reset_scroll_and_rebuild()
        end);
    end);
end)

-- Initialize filter state from DB on load
frame:HookScript("OnShow", function()
    if SfuiDB and SfuiDB.merchant and SfuiDB.merchant.lootFilterState then
        sfui.merchant.lootFilterState = SfuiDB.merchant.lootFilterState
        if sfui.merchant.lootFilterState == 0 then
            filterDropdownBtn:SetText("showing all")
        elseif sfui.merchant.lootFilterState == 1 then
            filterDropdownBtn:SetText("current class")
        elseif sfui.merchant.lootFilterState == 2 then
            filterDropdownBtn:SetText("current spec")
        end
    end
end)

sfui.merchant.scrollOffset = 0
sfui.merchant.totalMerchantItems = 0

function sfui.merchant.reset_scroll_and_rebuild()
    sfui.merchant.scrollOffset = 0
    wipe(sfui.merchant.lockCache)
    if frame.scrollBar then
        frame.scrollBar:SetValue(0)
    end
    sfui.merchant.build_item_list()
end

-- (Moved above)
local buttons = {}

local get_item_id = sfui.common.get_item_id_from_link


sfui.merchant.housingDecorFilter = sfui.merchant.housingDecorFilter or 0

function sfui.merchant.create_stack_split_frame(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(180, 110)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    local app = sfui.config.appearance
    f:SetBackdropColor(app.backdropColor[1], app.backdropColor[2], app.backdropColor[3], 0.95)
    f:SetBackdropBorderColor(0, 0, 0, 1)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOP", 0, -8)
    f.title:SetText("Enter Quantity")

    local eb = CreateFrame("EditBox", nil, f)
    eb:SetSize(80, 24)
    eb:SetPoint("TOP", 0, -30)
    eb:SetFontObject("ChatFontNormal")
    eb:SetJustifyH("CENTER")
    eb:SetNumeric(true)
    eb:SetAutoFocus(true)

    local eb_bg = eb:CreateTexture(nil, "BACKGROUND")
    eb_bg:SetAllPoints()
    eb_bg:SetColorTexture(app.widgetBackdropColor[1], app.widgetBackdropColor[2], app.widgetBackdropColor[3], 1)

    eb:SetScript("OnEnterPressed", function() f.buyBtn:Click() end)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    f.editBox = eb

    f.maxBtn = sfui.common.create_flat_button(f, "Max", 40, 24)
    f.maxBtn:SetPoint("LEFT", eb, "RIGHT", 5, 0)
    sfui.common.set_color(f.maxBtn, "black")
    f.maxBtn:SetScript("OnClick", function()
        local maxStack = f.maxStack or 1
        local price = f.price or 0
        local money = GetMoney()
        local affordable = price > 0 and math.floor(money / price) or maxStack

        local stackSize = f.stackCount or 1
        local maxPurchases = math.floor(maxStack / stackSize)
        local canBuy = math.min(affordable, maxPurchases)
        if canBuy < 1 then canBuy = 1 end

        eb:SetText(canBuy)
        eb:SetFocus()
    end)

    f.buyBtn = sfui.common.create_flat_button(f, "Buy", 70, 24)
    f.buyBtn:SetPoint("BOTTOMLEFT", 10, 10)
    sfui.common.set_color(f.buyBtn, "black")
    f.buyBtn:SetScript("OnClick", function()
        local val = tonumber(eb:GetText()) or 1
        if val > 0 then
            BuyMerchantItem(f.index, val)
        end
        f:Hide()
    end)

    f.cancelBtn = sfui.common.create_flat_button(f, "Cancel", 70, 24)
    f.cancelBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    sfui.common.set_color(f.cancelBtn, "black")
    f.cancelBtn:SetScript("OnClick", function() f:Hide() end)

    return f
end

local function open_stack_split(index)
    if not sfui.merchant.stackSplitFrame then
        sfui.merchant.stackSplitFrame = sfui.merchant.create_stack_split_frame(sfui.merchant.frame)
    end

    local f = sfui.merchant.stackSplitFrame
    f.index = index
    f.editBox:SetText("1")

    local info = C_MerchantFrame.GetItemInfo(index)
    local name, price, stackCount, link
    if info then
        name = info.name
        price = info.price
        stackCount = info.stackCount
        link = info.hyperlink
    end
    -- local link = GetMerchantItemLink(index) -- Removed
    if link then
        local _, _, _, _, _, _, _, itemStackCount = C_Item.GetItemInfo(link)
        f.maxStack = itemStackCount
    else
        f.maxStack = 9999
    end
    f.price = price
    f.stackCount = stackCount -- Amount received per buy

    f:Show()
    f.editBox:SetFocus()
end

function sfui.merchant.create_item_button(id, parent)
    local btn = CreateFrame("Button", "SfuiMerchantItem" .. id, parent, "BackdropTemplate")
    btn:SetSize(190, 45)

    local iconWrap = CreateFrame("Button", nil, btn, "BackdropTemplate")
    iconWrap:SetSize(40, 40)
    iconWrap:SetPoint("LEFT", 2, 0)
    iconWrap:EnableMouse(false)
    btn.iconWrap = iconWrap
    btn.icon = iconWrap:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints(iconWrap)

    sfui.common.apply_square_icon_style(iconWrap, btn.icon)

    btn.nameStub = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.nameStub:SetPoint("TOPLEFT", iconWrap, "TOPRIGHT", 5, 2)
    btn.nameStub:SetJustifyH("LEFT")

    local app = sfui.config.appearance
    btn.subName = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.subName:SetPoint("TOPLEFT", btn.nameStub, "BOTTOMLEFT", 0, -1)
    btn.subName:SetJustifyH("LEFT")
    btn.subName:SetTextColor(app.dimTextColor[1], app.dimTextColor[2], app.dimTextColor[3], 1)

    btn.price = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.price:SetPoint("BOTTOMLEFT", iconWrap, "BOTTOMRIGHT", 5, 0)
    btn.price:SetJustifyH("LEFT")

    btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    btn.count:SetPoint("BOTTOMRIGHT", iconWrap, -2, 2)

    btn.lockBackground = btn:CreateTexture(nil, "BACKGROUND")
    btn.lockBackground:SetAllPoints(btn)
    btn.lockBackground:SetColorTexture(app.lockColor[1], app.lockColor[2], app.lockColor[3], app.lockColor[4])
    btn.lockBackground:Hide()

    btn.lockReason = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.lockReason:SetPoint("TOPLEFT", btn.nameStub, "BOTTOMLEFT", 0, -1)
    btn.lockReason:SetWidth(145)
    btn.lockReason:SetMaxLines(1)
    btn.lockReason:SetWordWrap(false)
    btn.lockReason:SetJustifyH("LEFT")
    btn.lockReason:SetTextColor(app.errorColor[1], app.errorColor[2], app.errorColor[3], 1)
    btn.lockReason:Hide()

    btn.check = btn:CreateTexture(nil, "OVERLAY")
    btn.check:SetSize(20, 20)
    btn.check:SetPoint("TOPRIGHT", -2, -2)
    btn.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    btn.check:Hide()

    btn.unknownDecor = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    btn.unknownDecor:SetPoint("TOPRIGHT", -6, -4)
    btn.unknownDecor:SetText("!")
    btn.unknownDecor:SetTextColor(app.goldColor[1], app.goldColor[2], app.goldColor[3], 1)
    btn.unknownDecor:Hide()

    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    btn:SetScript("OnEnter", function(self)
        securecall(pcall, GameTooltip.SetOwner, GameTooltip, self, "ANCHOR_RIGHT")
        if self.link then
            securecall(pcall, GameTooltip.SetHyperlink, GameTooltip, self.link)
        elseif self.hasItem then
            securecall(pcall, GameTooltip.SetMerchantItem, GameTooltip, self:GetID())
        end
        GameTooltip:Show()
        if self.hasItem then
            frame.itemHover = self:GetID()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
        ResetCursor()
        frame.itemHover = nil
    end)

    btn:SetScript("OnClick", function(self, button)
        if self.hasItem then
            if IsModifiedClick() then
                if sfui.merchant.mode == "buyback" then
                    local link = GetBuybackItemLink(self:GetID())
                    if link then HandleModifiedItemClick(link) end
                else
                    local link = GetMerchantItemLink(self:GetID())
                    if link and HandleModifiedItemClick(link) then return end

                    if IsModifiedClick("SPLITSTACK") and button == "RightButton" then
                        open_stack_split(self:GetID())
                        return
                    end
                end
                return
            end

            if sfui.merchant.mode == "buyback" then
                BuybackItem(self:GetID())
            else
                if button == "RightButton" then
                    BuyMerchantItem(self:GetID())
                else
                    PickupMerchantItem(self:GetID())
                end
            end
        end
    end)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    sfui.common.sync_masque(iconWrap, { Icon = btn.icon })

    return btn
end

for i = 1, ITEMS_PER_PAGE do
    local btn = sfui.merchant.create_item_button(i, frame)
    local row = math.floor((i - 1) / NUM_COLS)
    local col = (i - 1) % NUM_COLS

    btn:SetPoint("TOPLEFT", cfg.grid.offset_x + (col * cfg.grid.spacing_x),
        cfg.grid.offset_y - (row * cfg.grid.spacing_y))
    buttons[i] = btn
end

local app = sfui.config.appearance
local scrollBar = CreateFrame("Slider", nil, frame, "BackdropTemplate")
scrollBar:SetOrientation("VERTICAL")
scrollBar:SetPoint("TOPRIGHT", -cfg.scrollbar.right_offset, cfg.grid.offset_y)
scrollBar:SetPoint("BOTTOMRIGHT", -cfg.scrollbar.right_offset, 65)
scrollBar:SetWidth(cfg.scrollbar.width)
scrollBar:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
})
scrollBar:SetBackdropColor(0, 0, 0, 0.3)
scrollBar:SetMinMaxValues(0, 0)
scrollBar:SetValue(0)
scrollBar:SetScript("OnValueChanged", function(self, value)
    local newOffset = math.floor(value) * NUM_COLS

    if sfui.merchant.scrollOffset ~= newOffset then
        sfui.merchant.scrollOffset = newOffset
        sfui.merchant.update_merchant()
    end
end)

local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
thumb:SetSize(6, 30)
thumb:SetColorTexture(app.white[1], app.white[2], app.white[3], 1) -- Flat white
scrollBar:SetThumbTexture(thumb)
frame.scrollBar = scrollBar



-- Update Currency Display
function sfui.merchant.update_currency_display(frame)
    frame.currencyDisplays = frame.currencyDisplays or {}
    local displays = frame.currencyDisplays

    for _, f in pairs(displays) do f:Hide() end

    local cache = sfui.merchant.currencyCache or {}

    -- Memory optimization: Reuse sorted table and pool its entries
    releaseCache(sortedCurrencyItems)
    wipe(sortedCurrencyItems)

    for name, data in pairs(cache) do
        local entry = getTable()
        entry.name = name
        entry.data = data
        table.insert(sortedCurrencyItems, entry)
    end

    table.sort(sortedCurrencyItems, function(a, b)
        if a.name == "Gold" then return false end -- Gold always last (greater)
        if b.name == "Gold" then return true end
        return a.name < b.name
    end)

    if #sortedCurrencyItems == 0 then return end

    if not frame.currencyContainer then
        frame.currencyContainer = CreateFrame("Frame", nil, frame)
        frame.currencyContainer:SetHeight(cfg.currency.height)
        frame.currencyContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, cfg.currency.bottom_offset)
    end
    local container = frame.currencyContainer
    container:Show()

    frame._activeCurrencyDisplays = frame._activeCurrencyDisplays or {}
    local activeDisplays = frame._activeCurrencyDisplays
    wipe(activeDisplays)
    local totalWidth = 0

    for i, item in ipairs(sortedCurrencyItems) do
        local idx = i
        local data = item.data

        local display = displays[idx]
        if not display then
            display = CreateFrame("Frame", nil, container)
            display:SetSize(100, 20)

            display.icon = display:CreateTexture(nil, "ARTWORK")
            display.icon:SetSize(16, 16)
            display.icon:SetPoint("LEFT")

            display.text = display:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            display.text:SetPoint("LEFT", display.icon, "RIGHT", 5, 0)

            display:EnableMouse(true)
            display:SetScript("OnEnter", function(self)
                securecall(pcall, GameTooltip.SetOwner, GameTooltip, self, "ANCHOR_RIGHT")
                if self.type == "item" then
                    securecall(pcall, GameTooltip.SetItemByID, GameTooltip, self.currencyID)
                elseif self.currencyID then
                    securecall(pcall, GameTooltip.SetCurrencyByID, GameTooltip, self.currencyID)
                elseif self.currencyName == "Gold" then
                    GameTooltip:SetText("Gold")
                    GameTooltip:AddLine("Total money on character", 1, 1, 1)
                else
                    GameTooltip:SetText(self.currencyName or "Currency")
                end
                GameTooltip:Show()
            end)
            display:SetScript("OnLeave", GameTooltip_Hide)

            displays[idx] = display
        end

        display.icon:SetTexture(data.texture)
        display.currencyID = data.id     -- Store ID for tooltip
        display.currencyName = item.name -- Store Name for fallback
        display.type = data.type         -- Store Type for tooltip

        local count = data.count
        local displayText
        if count >= 1000000 then
            displayText = string.format("%.1fM", count / 1000000)
        elseif count >= 1000 then
            displayText = string.format("%.1fK", count / 1000)
        else
            displayText = tostring(count)
        end
        display.text:SetText(displayText)

        local textWidth = display.text:GetStringWidth()
        local width = 16 + 5 + textWidth + 2
        display:SetWidth(width)
        display:Show()

        activeDisplays[i] = display

        if totalWidth > 0 then totalWidth = totalWidth + 15 end -- Gap
        totalWidth = totalWidth + width
    end

    container:SetWidth(totalWidth)

    local prev
    for i, display in ipairs(activeDisplays) do
        display:ClearAllPoints()
        if i == 1 then
            display:SetPoint("LEFT", container, "LEFT", 0, 0)
        else
            display:SetPoint("LEFT", prev, "RIGHT", 15, 0)
        end
        prev = display
    end
end

sfui.merchant.mode = "merchant" -- "merchant" or "buyback"
sfui.merchant.filterKnown = true

local utilityBar = CreateFrame("Frame", nil, frame)
utilityBar:SetHeight(cfg.utility_bar.height)
utilityBar:SetPoint("BOTTOMLEFT", 10, cfg.utility_bar.bottom_offset)
utilityBar:SetPoint("BOTTOMRIGHT", -10, cfg.utility_bar.bottom_offset)

sfui.merchant.buybackBtn = CreateFlatButton(utilityBar, "buyback", cfg.utility_bar.button_small,
    cfg.utility_bar.button_height)
sfui.merchant.buybackBtn:SetPoint("LEFT", 0, 0)
sfui.merchant.buybackBtn:SetScript("OnClick", function(self)
    if sfui.merchant.mode == "merchant" then
        sfui.merchant.mode = "buyback"
        self:SetText("merchant")
    else
        sfui.merchant.mode = "merchant"
        self:SetText("buyback")
    end
    sfui.merchant.reset_scroll_and_rebuild()
end)

sfui.merchant.filterBtn = CreateFlatButton(utilityBar, "hide known", cfg.utility_bar.button_small,
    cfg.utility_bar.button_height)
sfui.merchant.filterBtn:SetPoint("LEFT", sfui.merchant.buybackBtn, "RIGHT", 5, 0)

local function update_filter_button_style(self)
    if sfui.merchant.filterKnown then
        self:SetText("hiding known")
        sfui.common.set_color(self, sfui.config.merchant.button_colors.filter_active)
    else
        self:SetText("showing known")
        sfui.common.set_color(self, sfui.config.merchant.button_colors.filter_inactive)
    end
end
update_filter_button_style(sfui.merchant.filterBtn)

sfui.merchant.filterBtn:SetScript("OnClick", function(self)
    sfui.merchant.filterKnown = not sfui.merchant.filterKnown
    update_filter_button_style(self)
    sfui.merchant.reset_scroll_and_rebuild()
end)

sfui.merchant.filterBtn:SetScript("OnEnter", function(self)
    if not sfui.merchant.filterKnown then
        sfui.common.set_color(self, sfui.config.merchant.button_colors.filter_hover)
    end
end)


sfui.merchant.filterBtn:SetScript("OnLeave", function(self)
    update_filter_button_style(self) -- Revert to state color
end)

sfui.merchant.housingFilterBtn = CreateFlatButton(utilityBar, "decor: all", cfg.utility_bar.button_large,
    cfg.utility_bar.button_height)
sfui.merchant.housingFilterBtn:SetPoint("LEFT", sfui.merchant.filterBtn, "RIGHT", 5, 0)

local function update_housing_filter_button_style(self)
    if sfui.merchant.housingDecorFilter == 1 then
        self:SetText("decor: hide known")
        sfui.common.set_color(self, sfui.config.merchant.button_colors.decor_hide_owned)
    else
        self:SetText("decor: show all")
        sfui.common.set_color(self, sfui.config.merchant.button_colors.decor_show_all)
    end
end
update_housing_filter_button_style(sfui.merchant.housingFilterBtn)

sfui.merchant.housingFilterBtn:SetScript("OnClick", function(self)
    -- Cycle through states: 0 -> 1 -> 0
    sfui.merchant.housingDecorFilter = (sfui.merchant.housingDecorFilter + 1) % 2
    update_housing_filter_button_style(self)
    sfui.merchant.reset_scroll_and_rebuild()
end)

sfui.merchant.housingFilterBtn:SetScript("OnEnter", function(self)
    if sfui.merchant.housingDecorFilter == 0 then
        sfui.common.set_color(self, sfui.config.merchant.button_colors.filter_hover)
    end
end)

sfui.merchant.housingFilterBtn:SetScript("OnLeave", function(self)
    update_housing_filter_button_style(self) -- Revert to state color
end)

local guildRepairBtn = CreateFrame("Button", nil, utilityBar, "BackdropTemplate")
guildRepairBtn:SetSize(22, 22); guildRepairBtn:SetPoint("RIGHT", 0, 0)
local grIcon = guildRepairBtn:CreateTexture(nil, "ARTWORK")
grIcon:SetAllPoints()
grIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02") -- Coin icon
grIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
guildRepairBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local repairAllCost, canRepair = GetRepairAllCost()

    if canRepair and (sfui.common.issecretvalue(repairAllCost) or sfui.common.SafeGT(repairAllCost, 0)) then
        sfui.common.SafeSetTooltipMoney(GameTooltip, repairAllCost, "Guild Repair")

        local amount = GetGuildBankMoney()
        local withdrawLimit = GetGuildBankWithdrawMoney()
        local isSecretAmount = sfui.common.issecretvalue(amount)

        if not isSecretAmount and withdrawLimit >= 0 then
            amount = math.min(amount, withdrawLimit)
        end

        sfui.common.SafeAddMoneyLine(GameTooltip, "Guild Funds: ", amount)
    else
        GameTooltip:SetText("No Repair Needed")
    end
    securecall(pcall, GameTooltip.Show, GameTooltip)
end)
guildRepairBtn:SetScript("OnLeave", GameTooltip_Hide)
guildRepairBtn:SetScript("OnClick", function()
    if CanMerchantRepair() and CanGuildBankRepair() then
        RepairAllItems(true)
        grIcon:SetDesaturated(true) -- Temp feedback
    end
end)

local repairBtn = CreateFrame("Button", nil, utilityBar, "BackdropTemplate")
repairBtn:SetSize(22, 22); repairBtn:SetPoint("RIGHT", guildRepairBtn, "LEFT", -5, 0)
local rIcon = repairBtn:CreateTexture(nil, "ARTWORK")
rIcon:SetAllPoints()
rIcon:SetTexture("Interface\\Icons\\Trade_BlackSmithing") -- Anvil/Hammer
rIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
repairBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local repairAllCost, canRepair = GetRepairAllCost()
    local isSecret = sfui.common.issecretvalue(repairAllCost)

    if canRepair and (isSecret or sfui.common.SafeGT(repairAllCost, 0)) then
        sfui.common.SafeSetTooltipMoney(GameTooltip, repairAllCost, "Repair All")
    else
        GameTooltip:SetText("No Repair Needed")
    end
    securecall(pcall, GameTooltip.Show, GameTooltip)
end)
repairBtn:SetScript("OnLeave", GameTooltip_Hide)
repairBtn:SetScript("OnClick", function()
    if CanMerchantRepair() then
        RepairAllItems(false)
        rIcon:SetDesaturated(true)
    end
end)

local sellJunkBtn = CreateFlatButton(utilityBar, "sell greys", cfg.utility_bar.button_medium,
    cfg.utility_bar.button_height)
sellJunkBtn:SetPoint("RIGHT", repairBtn, "LEFT", -5, 0)

sellJunkBtn:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Sell All Greys")
    GameTooltip:Show()
end)
sellJunkBtn:HookScript("OnLeave", GameTooltip_Hide)
sellJunkBtn:SetScript("OnClick", function()
    local totalPrice = 0
    for bag = 0, 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and info.quality == 0 then
                local price = info.noValue and 0 or (select(11, C_Item.GetItemInfo(info.hyperlink)) or 0)
                if price > 0 then
                    totalPrice = totalPrice + (price * info.stackCount)
                    C_Container.UseContainerItem(bag, slot)
                end
            end
        end
    end
    if totalPrice > 0 then
        print("|cff00ff00Sold greys for " .. sfui.common.SafeGetCoinTextureString(totalPrice) .. ".|r")
    else
        print("|cffff0000No greys to sell.|r")
    end
end)



local function update_repair_buttons()
    local canRepair = CanMerchantRepair()
    local repairAllCost, canRepairItems = GetRepairAllCost()
    local needsRepair = canRepairItems and repairAllCost > 0

    if canRepair and needsRepair and CanGuildBankRepair() then
        grIcon:SetDesaturated(false)
        guildRepairBtn:Enable()
    else
        grIcon:SetDesaturated(true)
        guildRepairBtn:Disable()
    end
end

frame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
frame:HookScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" or event == "UPDATE_INVENTORY_DURABILITY" then
        update_repair_buttons()
    end
end)


sfui.merchant.filteredIndices = {}

sfui.merchant.currencyCache = {}
sfui.merchant.lockCache = {} -- Persistent cache for lock reasons
sfui.merchant.decorCachePopulated = false

sfui.merchant.populate_decor_cache = function()
    if SfuiDB and not SfuiDB.enableDecor then return end
    if sfui.merchant.decorCachePopulated then return end
    if not (C_HousingCatalog and C_HousingCatalog.CreateCatalogSearcher) then return end

    local searcher = C_HousingCatalog.CreateCatalogSearcher()

    searcher:SetOwnedOnly(true)
    searcher:SetCollected(true)
    searcher:SetUncollected(false)
    searcher:SetAutoUpdateOnParamChanges(false)

    local function OnResults()
        local results = searcher:GetAllSearchItems()
        SfuiDecorDB.items = {}

        if results then
            for _, entryID in ipairs(results) do
                local info = C_HousingCatalog.GetCatalogEntryInfo(entryID)
                if info and info.itemID then
                    local subtype = info.entryID and info.entryID.entrySubtype or 0
                    if subtype ~= 1 then
                        local qty = (info.quantity or 0)
                        local redeem = (info.remainingRedeemable or 0)
                        local totalOwned = qty + redeem
                        local placed = info.numPlaced or 0
                        local storage = qty

                        if totalOwned > 0 or placed > 0 then
                            SfuiDecorDB.items[info.itemID] = {
                                o = totalOwned,
                                p = placed,
                                s = storage
                            }
                        end
                    end
                end
            end
        end
        sfui.merchant.decorCachePopulated = true
        sfui.merchant.decorCacheStatus = "Populated with " .. (results and #results or 0) .. " entries."
    end

    searcher:SetResultsUpdatedCallback(OnResults)
    searcher:RunSearch()
end



sfui.merchant.filteredIndices = sfui.merchant.filteredIndices or {}
sfui.merchant.currencyCache = sfui.merchant.currencyCache or {}

local function AddToCache(id, name, texture, count, type)
    if name and not sfui.merchant.currencyCache[name] then
        local t = getTable()
        t.id = id; t.texture = texture; t.count = count; t.type = type
        sfui.merchant.currencyCache[name] = t
    end
end

sfui.merchant.build_item_list = function()
    local mode = sfui.merchant.mode
    local numItemsRaw = (mode == "buyback") and GetNumBuybackItems() or GetMerchantNumItems()

    wipe(sfui.merchant.filteredIndices)
    releaseCache(sfui.merchant.currencyCache)
    local hasHousingItems = false
    local specID = sfui.common.get_current_spec_id() -- Optimization: Hoist out of loop

    for i = 1, numItemsRaw do
        local include, link = true, nil
        if mode == "merchant" then
            link = GetMerchantItemLink(i)
            if link and not hasHousingItems and sfui.common.is_housing_decor(link) then
                hasHousingItems = true
            end
        else
            link = GetBuybackItemLink(i)
        end

        local itemID = get_item_id(link)
        if include and mode == "merchant" and sfui.merchant.filterKnown and link then
            if sfui.common.is_item_known(link) then
                include = false
            elseif itemID then
                local _, _, _, _, _, _, _, _, _, _, _, _, speciesID = C_PetJournal.GetPetInfoByItemID(itemID)
                if speciesID and (C_PetJournal.GetNumCollectedInfo(speciesID) or 0) > 0 then
                    include = false
                end
            end
        end
        if include and mode == "merchant" and (SfuiDB and SfuiDB.enableDecor) and sfui.merchant.housingDecorFilter > 0 and sfui.common.is_housing_decor(link) then
            if SfuiDecorDB and SfuiDecorDB.items and SfuiDecorDB.items[itemID] then
                local cached = SfuiDecorDB.items[itemID]
                if sfui.merchant.housingDecorFilter == 1 and ((cached.o or 0) + (cached.p or 0) + (cached.s or 0)) > 0 then
                    include = false
                end
            end
        end

        if include and mode == "merchant" and sfui.merchant.lootFilterState > 0 and link then
            local isClassMatch = true
            local info = C_MerchantFrame.GetItemInfo(i)
            if not info or not info.isUsable then
                isClassMatch = false
            else
                local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
                -- If it's armor, check preferred armor type
                if classID == 4 and preferredArmor then
                    -- Subclasses: 0=Generic, 1=Cloth, 2=Leather, 3=Mail, 4=Plate, 5=Cosmetic, 6=Shield
                    if subclassID >= 1 and subclassID <= 4 and subclassID ~= preferredArmor then
                        isClassMatch = false
                    end
                end
            end

            if not isClassMatch then
                include = false
            elseif sfui.merchant.lootFilterState == 2 then
                -- Spec Filter (specID already fetched)
                if specID > 0 and not C_Item.DoesItemContainSpec(link, playerClassID, specID) then
                    include = false
                end
            end
        end

        if include then table.insert(sfui.merchant.filteredIndices, i) end
        if mode == "merchant" then
            local itemInfo = C_MerchantFrame.GetItemInfo(i)
            if itemInfo then
                if itemInfo.price and itemInfo.price > 0 and not sfui.merchant.currencyCache["Gold"] then
                    local t = getTable()
                    t.texture = 133784
                    t.count = math.floor(GetMoney() / 10000)
                    t.type = "gold"
                    sfui.merchant.currencyCache["Gold"] = t
                end

                if itemInfo.currencyID then
                    local info = C_CurrencyInfo.GetCurrencyInfo(itemInfo.currencyID)
                    if info then AddToCache(itemInfo.currencyID, info.name, info.iconFileID, info.quantity, "currency") end
                end

                if itemInfo.hasExtendedCost then
                    for j = 1, GetMerchantItemCostInfo(i) do
                        local texture, amount, costLink, currencyName = GetMerchantItemCostItem(i, j)
                        if costLink then
                            if not currencyName then
                                local cID = string.match(costLink, "currency:(%d+)")
                                currencyName = cID and (C_CurrencyInfo.GetCurrencyInfo(tonumber(cID)) or {}).name or
                                    C_Item.GetItemInfo(costLink)
                            end
                            local cID = tonumber(string.match(costLink, "currency:(%d+)"))
                            local count = cID and (C_CurrencyInfo.GetCurrencyInfo(cID) or {}).quantity or
                                C_Item.GetItemCount(costLink)
                            AddToCache(cID or get_item_id(costLink), currencyName, texture, count,
                                cID and "currency" or "item")
                        end
                    end
                end
            end
        end
    end



    if sfui.merchant.housingFilterBtn then
        if SfuiDB and not SfuiDB.enableDecor then
            sfui.merchant.housingFilterBtn:Hide()
        else
            sfui.merchant.housingFilterBtn:Show()
        end
    end

    sfui.merchant.totalMerchantItems = #sfui.merchant.filteredIndices

    local totalRows = math.ceil(sfui.merchant.totalMerchantItems / NUM_COLS)
    local maxOffset = math.max(0, totalRows - NUM_ROWS)
    frame.scrollBar:SetMinMaxValues(0, maxOffset)
    frame.scrollBar:SetValueStep(1)

    if maxOffset > 0 then
        frame.scrollBar:Show()
    else
        frame.scrollBar:Hide()
    end

    sfui.merchant.update_merchant()
    sfui.merchant.update_currency_display(frame)
end

local function get_merchant_item_data(index, mode)
    wipe(scratchItemData)
    local d = scratchItemData
    if mode == "buyback" then
        local name, texture, price, qty, _, usable = GetBuybackItemInfo(index)
        if not name then return nil end
        d.name, d.texture, d.price, d.stackCount, d.isUsable = name, texture, price, qty, usable
        d.link = GetBuybackItemLink(index)
    else
        local info = C_MerchantFrame.GetItemInfo(index)
        if not info or not info.name then return nil end
        -- Copy values from C_MerchantFrame result to avoid returning the internal table if it's protected or shared
        for k, v in pairs(info) do d[k] = v end
        d.link = info.hyperlink or GetMerchantItemLink(index)
    end
    if d.link then
        local _, _, q, _, _, _, st, _, el, _, _, ci, sci = C_Item.GetItemInfo(d.link)
        d.quality, d.subType, d.equipLoc, d.classID, d.subClassID = q, st, el, ci, sci
    end
    return d
end

sfui.merchant.update_merchant = function()
    local indices = sfui.merchant.filteredIndices or {}
    for i = 1, ITEMS_PER_PAGE do
        local btn, index = buttons[i], indices[sfui.merchant.scrollOffset + i]
        if index then
            local data = get_merchant_item_data(index, sfui.merchant.mode)
            if data then
                btn:SetID(index); btn.hasItem, btn.link = true, data.link
                btn.icon:SetTexture(data.texture or 134400)

                -- Sync Masque state
                sfui.common.sync_masque(btn.iconWrap, { Icon = btn.icon })

                local typeText, isDecor = "", sfui.common.is_housing_decor(data.link)
                if isDecor then
                    local id = get_item_id(data.link)
                    local cached = id and SfuiDecorDB and SfuiDecorDB.items and SfuiDecorDB.items[id]
                    local count = cached and ((cached.o or 0) + (cached.p or 0)) or 0
                    if count > 0 then
                        btn.check:Show(); btn.unknownDecor:Hide()
                    else
                        btn.check:Hide(); btn.unknownDecor:Show()
                    end
                else
                    btn.check:Hide(); btn.unknownDecor:Hide()
                    local slot = (data.equipLoc and data.equipLoc ~= "" and _G[data.equipLoc]) or ""
                    typeText = (slot ~= "" and slot) or data.subType or ""
                    if data.classID == 4 and data.subClassID and data.subClassID <= 4 and data.subType ~= slot then
                        typeText = slot .. (data.subType ~= "" and " - " .. data.subType or "")
                    end
                end
                btn.subName:SetText(typeText == "Other" and "" or typeText)

                local r, g, b = C_Item.GetItemQualityColor(data.quality or 1)
                btn.nameStub:SetTextColor(r, g, b); btn.nameStub:SetText(sfui.common.shorten_name(data.name, 22))

                local cost = (data.price > 0) and
                    ((GetMoney() < data.price and "|cffff0000" or "|cffffffff") .. sfui.common.SafeGetCoinTextureString(data.price) .. "|r") or
                    ""
                if data.hasExtendedCost then
                    for j = 1, GetMerchantItemCostInfo(index) do
                        local tex, val, clink = GetMerchantItemCostItem(index, j)
                        if tex and val then
                            local ok = true
                            if clink then
                                local cid = string.match(clink, "currency:(%d+)")
                                ok = cid and (C_CurrencyInfo.GetCurrencyInfo(tonumber(cid)) or {}).quantity >= val or
                                    C_Item.GetItemCount(clink) >= val
                            end
                            cost = cost ..
                                (cost ~= "" and " " or "") ..
                                (ok and "|cffffffff" or "|cffff0000") ..
                                BreakUpLargeNumbers(val) .. " |T" .. tex .. ":12:12:0:0|t|r"
                        end
                    end
                end
                btn.price:SetText(cost); btn.count:SetText(data.stackCount > 1 and data.stackCount or "")

                local id = get_item_id(data.link)
                local locked, reason
                local cachedLock = id and sfui.merchant.lockCache[id]

                if cachedLock then
                    locked, reason = cachedLock.locked, cachedLock.reason
                else
                    locked, reason = not data.isUsable, "Unusable"
                    local tip = C_TooltipInfo.GetMerchantItem(index)
                    if tip and tip.lines then
                        local reasons = getTable()
                        for _, line in ipairs(tip.lines) do
                            local clr = line.leftColor
                            if clr and clr.r > 0.9 and clr.g < 0.2 and clr.b < 0.2 and line.leftText then
                                local text = line.leftText
                                if not text:find("Already known") then
                                    text = text:gsub("Requires", "R"):gsub("Rank ", ""):gsub("Defeat ", ""):gsub(
                                        "Reputation ", "");
                                    table.insert(reasons, text)
                                    locked = true
                                end
                            end
                        end
                        if #reasons > 0 then
                            reason = table.concat(reasons, ", ")
                        end
                        releaseTable(reasons)
                    end
                    if id then
                        sfui.merchant.lockCache[id] = { locked = locked, reason = reason }
                    end
                end

                if locked then
                    btn.lockBackground:Show(); btn.lockReason:SetText(reason); btn.lockReason:Show(); btn.subName:Hide()
                    btn.icon:SetVertexColor(1, 0.1, 0.1); btn.icon:SetDesaturated(true)
                else
                    btn.lockBackground:Hide(); btn.lockReason:Hide(); btn.subName:Show()
                    btn.icon:SetVertexColor(1, 1, 1); btn.icon:SetDesaturated(false)
                end
                btn:Show()
            else
                btn.check:Hide(); btn.unknownDecor:Hide(); btn:Hide()
            end
        else
            btn.check:Hide(); btn.unknownDecor:Hide(); btn:Hide()
        end
    end
end

frame:SetScript("OnMouseWheel", function(self, delta)
    local min, max = scrollBar:GetMinMaxValues()
    local val = scrollBar:GetValue()
    local step = 1 -- Scroll 1 row
    if delta > 0 then
        val = val - step
    else
        val = val + step
    end

    if val < min then val = min end
    if val > max then val = max end

    scrollBar:SetValue(val)
end)

-- Cursor tracking is handled by item button OnEnter/OnLeave events (lines 302-309)
-- OnUpdate removed to eliminate 60-144fps polling overhead

local function update_header()
    local unit = "npc"
    if not UnitExists(unit) then unit = "target" end

    SetPortraitTexture(frame.portrait, unit)
    frame.merchantName:SetText(UnitName(unit) or "Merchant")

    local titleText = ""
    local data = C_TooltipInfo.GetUnit(unit)
    if data and data.lines then
        local line2 = data.lines[2] and data.lines[2].leftText
        if line2 then
            local ok, txt = pcall(function() return string.find(line2, "Level") and "" or line2 end)
            if ok and txt == "" then
                -- It had "Level", so check line 3
                local line3 = data.lines[3] and data.lines[3].leftText
                if line3 then
                    local ok3, txt3 = pcall(function() return tostring(line3) end)
                    if ok3 and type(txt3) == "string" then
                        titleText = txt3
                    end
                end
            elseif ok and type(txt) == "string" then
                titleText = txt
            end
        end
    end
    frame.merchantTitle:SetText(titleText)
end

local isSystemClose = false

frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")
frame:RegisterEvent("MERCHANT_UPDATE")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("HOUSING_STORAGE_UPDATED")
frame:RegisterEvent("HOUSING_STORAGE_ENTRY_UPDATED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2, function() sfui.merchant.populate_decor_cache() end)
    elseif event == "MERCHANT_SHOW" then
        wipe(sfui.merchant.lockCache)
        update_header()
        sfui.merchant.reset_scroll_and_rebuild()
        if not SfuiDB.enableMerchant then return end
        self:Show()
        sfui.merchant.build_item_list()

        if MerchantFrame then
            MerchantFrame:SetAlpha(0)
            C_Timer.After(0.01, function()
                MerchantFrame:SetAlpha(0)
                MerchantFrame:EnableMouse(false)
                MerchantFrame:SetFrameStrata("BACKGROUND")
                MerchantFrame:SetScale(0.001)
                MerchantFrame:ClearAllPoints()
                MerchantFrame:SetPoint("TOPRIGHT", UIParent, "TOPLEFT", -1000, 1000)
            end)
        end
    elseif event == "MERCHANT_CLOSED" then
        wipe(sfui.merchant.lockCache)
        isSystemClose = true
        self:Hide()
        isSystemClose = false
        if MerchantFrame then
            MerchantFrame:SetAlpha(1)
            MerchantFrame:EnableMouse(true)
            MerchantFrame:SetFrameStrata("HIGH")
            MerchantFrame:SetScale(1)
        end
    elseif event == "MERCHANT_UPDATE" or event == "GET_ITEM_INFO_RECEIVED"
        or event == "HOUSING_STORAGE_UPDATED" or event == "HOUSING_STORAGE_ENTRY_UPDATED" then
        if event == "GET_ITEM_INFO_RECEIVED" then
            local itemID, success = ...
            if not success or not itemID then return end

            -- Only rebuild if the item is actually in the merchant's current stock
            local found = false
            for i = 1, GetMerchantNumItems() do
                local link = GetMerchantItemLink(i)
                if link and get_item_id(link) == itemID then
                    found = true
                    break
                end
            end
            if not found then return end
        end

        if self:IsShown() then
            if not self.updatePending then
                self.updatePending = true
                C_Timer.After(0.05, function()
                    if self:IsShown() then sfui.merchant.build_item_list() end
                    self.updatePending = false
                end)
            end
        end

        if event == "HOUSING_STORAGE_ENTRY_UPDATED" then
            local entryID = ...
            if entryID and C_HousingCatalog.GetCatalogEntryInfo then
                local info = C_HousingCatalog.GetCatalogEntryInfo(entryID)
                if info and info.itemID and SfuiDecorDB and SfuiDecorDB.items then
                    SfuiDecorDB.items[info.itemID] = {
                        o = (info.quantity or 0) + (info.remainingRedeemable or 0),
                        p = info.numPlaced or 0,
                        s = info.quantity or 0
                    }
                end
            end
        end
    end
end)

tinsert(UISpecialFrames, "SfuiMerchantFrame")
frame:Hide()
