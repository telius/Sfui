local addonName, addon = ...
sfui = sfui or {}

local cfg = sfui.config
local common = sfui.common
--[[
    SFUI World Quest Summary (Midnight Edition)
    STRICTLY MIDNIGHT ONLY
    Optimized for performance with frame pooling and throttled updates.
]]

-- Localize Globals (Lints)
local CreateFrame, UIParent = _G.CreateFrame, _G.UIParent
local WorldFrame = _G.WorldFrame
local table, ipairs, pairs, type, Enum, string, math = _G.table, _G.ipairs, _G.pairs, _G.type, _G.Enum, _G.string,
    _G.math
local GetTime = _G.GetTime
local GetNumQuestLogRewardFactions = _G.GetNumQuestLogRewardFactions
local GetQuestLogRewardFaction = _G.GetQuestLogRewardFaction
local C_QuestLog, C_TaskQuest, C_Item, C_CurrencyInfo, C_Map = _G.C_QuestLog, _G.C_TaskQuest, _G.C_Item,
    _G.C_CurrencyInfo, _G.C_Map
local C_Timer, C_Reputation = _G.C_Timer, _G.C_Reputation
local C_AreaPoiInfo = _G.C_AreaPoiInfo
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetQuestsForPlayerByMapID = C_TaskQuest.GetQuestsForPlayerByMapID
local GetQuestsOnMap = C_TaskQuest.GetQuestsOnMap
local GetQuestTimeLeftMinutes = C_TaskQuest.GetQuestTimeLeftMinutes
local RequestLoadQuestByID = C_QuestLog.RequestLoadQuestByID
local GetQuestInfoByQuestID = C_TaskQuest.GetQuestInfoByQuestID
local GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo
local GetQuestRewardCurrencies = C_QuestLog.GetQuestRewardCurrencies
local GetCurrencyInfo = C_CurrencyInfo.GetCurrencyInfo
local GetQuestRewardLink = C_QuestLog.GetQuestLogRewardLink or C_QuestLog.GetQuestRewardLink or _G.GetQuestLogRewardLink
local IsQuestWarbound = C_QuestLog.IsQuestWarbound
local QuestContainsFirstTimeRepBonusForPlayer = C_QuestLog.QuestContainsFirstTimeRepBonusForPlayer
local GetQuestLogRewardMoney = _G.GetQuestLogRewardMoney or function(...) return 0 end
local GetNumQuestLogRewards = _G.GetNumQuestLogRewards or function(...) return 0 end
local GetQuestLogRewardInfo = _G.GetQuestLogRewardInfo or function(...) end
local GetItemInfo = _G.GetItemInfo or function(...) end
local GetInventoryItemLink = _G.GetInventoryItemLink or function(...) end
local GetMoneyString = _G.GetMoneyString or tostring
local GetQuestLogLeaderBoard = _G.GetQuestLogLeaderBoard or function(...) end
local GetNumQuestLeaderBoards = _G.GetNumQuestLeaderBoards or function(...) return 0 end
local IsShiftKeyDown, ShowUIPanel = _G.IsShiftKeyDown, _G.ShowUIPanel
local WorldMapFrame = _G.WorldMapFrame
local GameTooltip, ITEM_QUALITY_COLORS = _G.GameTooltip, _G.ITEM_QUALITY_COLORS
local C_SuperTrack = _G.C_SuperTrack
local wipe = _G.wipe or (_G.table and _G.table.wipe)
local STAT_AVERAGE_ITEM_LEVEL = _G.STAT_AVERAGE_ITEM_LEVEL or "Item Level"

-- Advance Localization (Speed)
local tonumber, tostring, math_floor, math_min, math_max = _G.tonumber, _G.tostring, _G.math.floor, _G.math.min,
    _G.math.max
local string_find, string_format, string_match, string_sub = _G.string.find, _G.string.format, _G.string.match,
    _G.string.sub
local pcall, select, unpack, securecall = _G.pcall, _G.select, _G.unpack, _G.securecall

-- Performance Cache
local zoneCache = {}
local warbandBonusCache = {}
local equippedCache = {}
local requestCache = {}
local rewardDataCache = {} -- Persistent cache for reward strings/values
local refreshTimer
local refreshCount = 0
local WARBAND_BONUS_TEXT = " |TInterface\\Buttons\\WHITE8x8:12:6:0:0:1:1:0:1:0:1:0:255:255|t"
local UPGRADE_ICON_TEXT = " |TInterface\\OptionsFrame\\UI-OptionsFrame-NewFeatureIcon:12:12:0:0|t"

-- Pooling
local framePool = {}
local activeFrames = {} -- Track active rows for fast clearing
local tablePool = {}

local function AcquireTable()
    local t = table.remove(tablePool) or {}
    wipe(t) -- Ensure fresh table
    return t
end

local function ReleaseTable(t)
    if not t or type(t) ~= "table" then return end
    wipe(t)
    table.insert(tablePool, t)
end

-- State Management Helpers
local function GetFilters()
    SfuiDB.wqsFilters = SfuiDB.wqsFilters or {
        reputation = false, items = false, gold = false, zone = false
    }
    return SfuiDB.wqsFilters
end

local function GetWQSState()
    SfuiDB.wqsState = SfuiDB.wqsState or {
        detached = false,
        pos = nil
    }
    return SfuiDB.wqsState
end

-- Slot mapping for upgrade detection
local SLOT_IDS = {
    ["INVTYPE_HEAD"] = 1,
    ["INVTYPE_NECK"] = 2,
    ["INVTYPE_SHOULDER"] = 3,
    ["INVTYPE_BODY"] = 4,
    ["INVTYPE_CHEST"] = 5,
    ["INVTYPE_ROBE"] = 5,
    ["INVTYPE_WAIST"] = 6,
    ["INVTYPE_LEGS"] = 7,
    ["INVTYPE_FEET"] = 8,
    ["INVTYPE_WRIST"] = 9,
    ["INVTYPE_HAND"] = 10,
    ["INVTYPE_FINGER"] = { 11, 12 },
    ["INVTYPE_TRINKET"] = { 13, 14 },
    ["INVTYPE_CLOAK"] = 15,
    ["INVTYPE_WEAPON"] = { 16, 17 },
    ["INVTYPE_SHIELD"] = 17,
    ["INVTYPE_2HWEAPON"] = 16,
    ["INVTYPE_WEAPONMAINHAND"] = 16,
    ["INVTYPE_WEAPONOFFHAND"] = 17,
    ["INVTYPE_HOLDABLE"] = 17,
    ["INVTYPE_RANGED"] = 16,
    ["INVTYPE_RANGEDRIGHT"] = 16,
    ["INVTYPE_THROWN"] = 16,
    ["INVTYPE_RELIC"] = 16,
}

local function GetEquippedIlvl(slots)
    if not slots then return 0 end
    if type(slots) == "number" then
        return equippedCache[slots] or 0
    end
    local minIlvl = 9999
    for _, slotID in ipairs(slots) do
        local slotIlvl = equippedCache[slotID] or 0
        if slotIlvl < minIlvl then minIlvl = slotIlvl end
    end
    return minIlvl
end

local function UpdateGearCache()
    wipe(equippedCache)
    for _, slots in pairs(SLOT_IDS) do
        if type(slots) == "table" then
            for _, slotID in ipairs(slots) do
                local link = GetInventoryItemLink("player", slotID)
                equippedCache[slotID] = link and GetDetailedItemLevelInfo(link) or 0
            end
        else
            local link = GetInventoryItemLink("player", slots)
            equippedCache[slots] = link and GetDetailedItemLevelInfo(link) or 0
        end
    end
    -- Invalidate reward cache for items when gear changes
    for qID, data in pairs(rewardDataCache) do
        if data.hasIlvl then
            rewardDataCache[qID] = nil
            ReleaseTable(data)
        end
    end
end

local function IsUpgrade(itemLink, overrideIlvl)
    if not itemLink then return false end
    local ilvl = overrideIlvl or GetDetailedItemLevelInfo(itemLink)
    if not ilvl or ilvl <= 1 then return false end

    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemLink)
    local slots = equipLoc and SLOT_IDS[equipLoc]
    if not slots then return false end

    local equippedIlvl = GetEquippedIlvl(slots)
    
    -- Use highest.lua robust scaling/class-validation if available
    if sfui.highest and sfui.highest.EvaluateItemUpgrade then
        return sfui.highest.EvaluateItemUpgrade(itemLink, ilvl, equippedIlvl)
    end

    return common.SafeGT(ilvl, equippedIlvl), false
end

local function ScanQuestRewards(self, questID)
    local rewardParts = AcquireTable()
    local sortRewardValue = 0
    local isWarbound = IsQuestWarbound and IsQuestWarbound(questID)
    local questHasReputation = isWarbound
    local questHasUpgrade = false
    local allRewardsCached = true
    local hasItems, hasGold = false, false

    -- Currencies
    local rewardCurrencies = GetQuestRewardCurrencies(questID)
    if rewardCurrencies then
        for _, currency in ipairs(rewardCurrencies) do
            local currencyInfo = GetCurrencyInfo(currency.currencyID)
            local isWarboundCurrency = (currency.currencyID >= 2800)
            local isRep = (currencyInfo and (currencyInfo.categoryID == 2112 or currencyInfo.maxQuantity == 0))
            if isWarboundCurrency then isWarbound = true end
            local currentMarker = isWarbound and WARBAND_BONUS_TEXT or ""

            if isRep or isWarboundCurrency then
                questHasReputation = true
                table.insert(rewardParts,
                    "+" .. currency.totalRewardAmount .. " |T" .. currency.texture .. ":12:12:0:0:64:64:4:60:4:60|t" ..
                    currentMarker)
                sortRewardValue = common.SafeArithmetic("+", sortRewardValue, common.SafeArithmetic("/", currency.totalRewardAmount, 10))
            else
                table.insert(rewardParts,
                    "|T" .. currency.texture .. ":12:12:0:0:64:64:4:60:4:60|t " ..
                    currency.totalRewardAmount .. currentMarker)
                sortRewardValue = common.SafeArithmetic("+", sortRewardValue, common.SafeArithmetic("+", 100000, currency.totalRewardAmount))
            end
        end
    end

    -- Items
    local numItems = GetNumQuestLogRewards(questID)
    if numItems > 0 then
        hasItems = true
        for i = 1, numItems do
            local itemName, itemTexture, quantity, quality, _, itemID = GetQuestLogRewardInfo(i, questID)
            if itemTexture then
                local itemLink = (GetQuestRewardLink and GetQuestRewardLink(questID, i)) or ("item:" .. (itemID or 0))
                local ilvl = GetDetailedItemLevelInfo(itemLink) or 0
                local upgradeIcon = ""

                -- Cache check
                if itemID and GetItemInfo then
                    if not GetItemInfo(itemID) then
                        allRewardsCached = false
                        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
                    else
                        local info = { GetItemInfo(itemID) }
                        if info[14] == 4 then isWarbound = true end -- LE_ITEM_BIND_TO_BNET
                    end
                end

                -- Tooltip Scan for scaling/warband
                if self.ScanTooltip then
                    securecall(pcall, self.ScanTooltip.SetOwner, self.ScanTooltip, WorldFrame, "ANCHOR_NONE")
                    securecall(pcall, self.ScanTooltip.SetQuestLogItem, self.ScanTooltip, "reward", i, questID)
                    local lines = self.ScanTooltip.leftLines
                    for lineIdx = 2, math_min(self.ScanTooltip:NumLines(), 20) do
                        local text = lines[lineIdx] and lines[lineIdx]:GetText()
                        if text then
                            if string_find(text, STAT_AVERAGE_ITEM_LEVEL) then
                                local foundIlvl = string_match(text, "(%d+)")
                                if foundIlvl then ilvl = math_max(ilvl, tonumber(foundIlvl) or 0) end
                            end
                            if string_find(text, "Warband reputation bonus") or string_find(text, "Account Bound") or string_find(text, "Warband Soulbound") then
                                isWarbound = true
                            end
                        end
                    end
                end

                local ilvlText = ""
                if common.SafeGT(ilvl, 1) then
                    local info = { GetItemInfo(itemID) }
                    if info[12] == 2 or info[12] == 4 then -- Weapon or Armor
                        local isUpgrade, isOffSpec = IsUpgrade(itemLink, ilvl)
                        if isUpgrade then
                            questHasUpgrade = true
                            upgradeIcon = UPGRADE_ICON_TEXT
                        end
                        local colorHex = "ffffffff"
                        if isUpgrade then
                            colorHex = isOffSpec and "ffffff00" or "ff00ff00"
                        end
                        ilvlText = "|c" .. colorHex .. "(" .. ilvl .. ")|r "
                        sortRewardValue = common.SafeArithmetic("+", sortRewardValue, common.SafeArithmetic("+", 1000000, common.SafeArithmetic("*", ilvl, 10)))
                    end
                end

                local color = (ITEM_QUALITY_COLORS[quality or 1] and ITEM_QUALITY_COLORS[quality or 1].hex) or "|cffffffff"
                local qtyText = (common.SafeGT(quantity, 1)) and (quantity .. " ") or ""
                local currentMarker = isWarbound and WARBAND_BONUS_TEXT or ""
                table.insert(rewardParts,
                    "|T" .. itemTexture .. ":12:12:0:0:64:64:4:60:4:60|t " ..
                    ilvlText .. color .. "[" .. qtyText .. (itemName or "Unknown") .. "]|r" .. currentMarker .. upgradeIcon)
                if isWarbound then questHasReputation = true end
            end
        end
    end

    -- Money
    local money = GetQuestLogRewardMoney(questID)
    if common.SafeGT(money, 0) then
        hasGold = true
        table.insert(rewardParts, common.SafeGetCoinTextureString(money))
        sortRewardValue = common.SafeArithmetic("+", sortRewardValue, common.SafeArithmetic("/", money, 10000))
    end

    local rewardText = table.concat(rewardParts, " | ")
    ReleaseTable(rewardParts)

    return rewardText, sortRewardValue, isWarbound, allRewardsCached, hasItems, hasGold, questHasReputation,
        questHasUpgrade, hasItems -- Return hasItems as hasIlvl indicator for caching
end



-- Constants (Strict Midnight Zones)
local MIDNIGHT_ZONES = {
    2393, -- Silvermoon City
    2395, -- Eversong Woods
    2437, -- Zul'Aman
    2413, -- Harandar
    2405, -- Voidstorm
    2444, -- Slayer's Rise
}
local function UpdateZoneCache()
    if zoneCache["midnight"] then return zoneCache["midnight"] end
    zoneCache["midnight"] = {}
    for _, zoneID in ipairs(MIDNIGHT_ZONES) do
        local info = C_Map.GetMapInfo(zoneID)
        if info then
            local name = info.name or ("Map " .. zoneID)
            zoneCache["midnight"][zoneID] = name
        end
    end
    return zoneCache["midnight"]
end

local WQS = CreateFrame("Frame", "SfuiWQS", UIParent, "BackdropTemplate")
sfui.wqs = WQS
addon.wqs = WQS
WQS:Hide() -- Hide initially, will be shown by WorldMap interaction

local function SetFontStyle(fs, fontObject, size)
    if not fs then return end
    fs:SetFontObject(fontObject or "GameFontNormal")
    local font = fs:GetFont()
    if font then
        fs:SetFont(font, size or 12, "") -- Increased from 11
    else
        fs:SetFont([[Fonts\FRIZQT__.TTF]], size or 12, "")
    end
end

-- Interaction handling for WorldMap
function WQS:Initialize()
    UpdateZoneCache()
    UpdateGearCache()
    self:SetSize(620, 450) -- Adjusted to fit 100/100/300 layout comfortably
    self:SetMovable(false)
    self:EnableMouse(true)

    self.sortMode = "reward" -- Default to Rewards
    self.sortOrder = -1      -- Highest value first

    local purple = cfg and cfg.colors and cfg.colors.purple or { 0.7, 0.4, 1 }
    local cyan = cfg and cfg.colors and cfg.colors.cyan or { 0, 1, 1 }
    local white = cfg and cfg.colors and cfg.colors.white or { 1, 1, 1 }

    -- SetupMapHooks will be called later to handle late-loading WorldMap

    -- Interaction handling for WorldMap

    -- Footer for Filters
    local footer = CreateFrame("Frame", nil, self)
    footer:SetPoint("BOTTOMLEFT", 10, 5)
    footer:SetPoint("BOTTOMRIGHT", -10, 5)
    footer:SetHeight(26)
    self.Footer = footer

    local function CreateFilterBtn(text, key, xOffset, tooltipText)
        local btn = common.create_flat_button(footer, text, 20, 20)
        btn:SetPoint("LEFT", xOffset, 0)

        function btn:updateBtnStyle()
            local filters = GetFilters()
            local active = filters[key]
            local color = active and { 0, 1, 1 } or { 0.5, 0.5, 0.5 } -- Cyan if active, Gray if not
            btn:SetBackdropBorderColor(color[1], color[2], color[3], 1)
            btn:GetFontString():SetTextColor(color[1], color[2], color[3], 1)
        end

        btn:SetScript("OnClick", function()
            local filters = GetFilters()
            local newState = not filters[key]

            -- Make Reward filters mutually exclusive
            filters.reputation = false
            filters.items = false
            filters.gold = false

            filters[key] = newState
            self:UpdateFilterStyles()
            self:Refresh()
        end)

        btn:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_TOP")
            GameTooltip:SetText(tooltipText)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        btn:updateBtnStyle()
        return btn
    end

    self.FilterReputation = CreateFilterBtn("R", "reputation", 0, "Reputation Reward Available")
    self.FilterItems = CreateFilterBtn("I", "items", 25, "Item/Gear Reward Available")
    self.FilterGold = CreateFilterBtn("G", "gold", 50, "Gold Reward Available")

    -- Pin Toggle
    local pinBtn = common.create_flat_button(footer, "P", 20, 20)
    pinBtn:SetPoint("LEFT", 75, 0)
    function pinBtn:updateBtnStyle()
        local state = GetWQSState()
        local color = state.detached and { 0, 1, 1 } or { 0.5, 0.5, 0.5 }
        pinBtn:SetBackdropBorderColor(color[1], color[2], color[3], 1)
        pinBtn:GetFontString():SetTextColor(color[1], color[2], color[3], 1)
    end

    pinBtn:SetScript("OnClick", function()
        local state = GetWQSState()
        state.detached = not state.detached
        self:UpdateAttachment()
        pinBtn:updateBtnStyle()
    end)
    pinBtn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:SetText("Toggle Detach/Pin Frame")
        GameTooltip:AddLine("When detached, frame stays visible and can be dragged.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pinBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pinBtn:updateBtnStyle()
    self.PinButton = pinBtn

    function self:UpdateFilterStyles()
        if self.FilterReputation then self.FilterReputation:updateBtnStyle() end
        if self.FilterItems then self.FilterItems:updateBtnStyle() end
        if self.FilterGold then self.FilterGold:updateBtnStyle() end
    end

    self.FilterZone = common.create_checkbox(footer, "Local", function() return GetFilters().zone end, function(val)
        GetFilters().zone = val
        self:Refresh()
    end, "Only show quests in your current zone.")
    self.FilterZone:SetPoint("RIGHT", 0, 0)
    -- Shrink checkbox a bit to match footer
    self.FilterZone:SetSize(16, 16)
    self.FilterZone.text:SetFontObject("GameFontHighlightSmall")
    self.FilterZone.text:ClearAllPoints()
    self.FilterZone.text:SetPoint("RIGHT", self.FilterZone, "LEFT", -5, 0)

    -- Styling (SFUI standard)
    self:SetBackdrop({
        bgFile = [[Interface\ChatFrame\ChatFrameBackground]],
    })
    self:SetBackdropColor(0, 0, 0, 0.7)

    -- Expansion Dropdown Removed (Strictly Midnight)

    self.ScanTooltip = CreateFrame("GameTooltip", "SfuiWQSScanTooltip", nil, "GameTooltipTemplate")
    self.ScanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    -- Cache high-frequency tooltip lines
    self.ScanTooltip.leftLines = {}
    for i = 1, 30 do
        self.ScanTooltip.leftLines[i] = _G["SfuiWQSScanTooltipTextLeft" .. i]
    end

    -- Sort Headers
    local sortHeader = CreateFrame("Frame", nil, self)
    sortHeader:SetPoint("TOPLEFT", 10, -5)
    sortHeader:SetPoint("TOPRIGHT", -10, -5)
    sortHeader:SetHeight(20)
    self.SortHeader = sortHeader

    local createSortBtn = function(text, width, mode, align)
        local btn = CreateFrame("Button", nil, sortHeader)
        btn:SetSize(width, 20)

        btn.Text = btn:CreateFontString(nil, "OVERLAY")
        SetFontStyle(btn.Text, cfg and cfg.font, 11)
        btn.Text:SetPoint(align or "LEFT", 0, 0)
        btn.Text:SetText(text)
        btn.Text:SetTextColor(purple[1], purple[2], purple[3])

        btn:SetScript("OnEnter", function() btn.Text:SetTextColor(cyan[1], cyan[2], cyan[3]) end)
        btn:SetScript("OnLeave", function()
            if self.sortMode == mode then
                btn.Text:SetTextColor(white[1], white[2], white[3])
            else
                btn.Text:SetTextColor(purple[1], purple[2], purple[3])
            end
        end)

        btn:SetScript("OnClick", function()
            if self.sortMode == mode then
                self.sortOrder = self.sortOrder * -1
            else
                self.sortMode = mode
                self.sortOrder = 1
            end
            self:Refresh()
        end)
        return btn
    end

    self.SortTitle = createSortBtn("Quest Name", 120, "title")
    self.SortZone = createSortBtn("Zone", 100, "zone")
    self.SortReward = createSortBtn("Rewards / Rep / ilvl", 270, "reward")
    self.SortTime = createSortBtn("Time Left", 60, "time", "RIGHT")

    -- Grid Alignment
    self.SortTitle:SetPoint("LEFT", sortHeader, "LEFT", 5, 0)
    self.SortZone:SetPoint("LEFT", self.SortTitle, "RIGHT", 5, 0)
    self.SortReward:SetPoint("LEFT", self.SortZone, "RIGHT", 5, 0)
    self.SortTime:SetPoint("RIGHT", sortHeader, "RIGHT", -5, 0)

    -- ScrollBar
    local scrollBar = CreateFrame("Slider", nil, self, "BackdropTemplate")
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetPoint("TOPRIGHT", -1, -30) -- Align with content start
    scrollBar:SetPoint("BOTTOMRIGHT", -1, 5)
    scrollBar:SetWidth(12)
    scrollBar:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8x8]] })
    scrollBar:SetBackdropColor(0, 0, 0, 0.3)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValue(0)

    local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(8, 30)
    thumb:SetColorTexture(1, 1, 1, 0.5)
    scrollBar:SetThumbTexture(thumb)
    self.ScrollBar = scrollBar

    -- Content area (Proper Anchoring)
    local scrollChild = CreateFrame("Frame", nil, self)
    scrollChild:SetPoint("TOPLEFT", 10, -30)
    scrollChild:SetPoint("BOTTOMRIGHT", -20, 35) -- Space for scrollbar and footer
    scrollChild:SetClipsChildren(true)
    self.ScrollChild = scrollChild

    local content = CreateFrame("Frame", nil, scrollChild)
    content:SetSize(570, 500) -- Matches scrollChild width (600 - 30 padding)
    content:SetPoint("TOPLEFT", 0, 0)
    content:SetPoint("TOPRIGHT", 0, 0)
    self.Content = content

    self.ScrollChild:SetScript("OnMouseWheel", function(_, delta)
        local cur = self.ScrollBar:GetValue()
        local min, max = self.ScrollBar:GetMinMaxValues()
        if delta > 0 then
            self.ScrollBar:SetValue(math_max(min, cur - 30))
        else
            self.ScrollBar:SetValue(math_min(max, cur + 30))
        end
    end)

    scrollBar:SetScript("OnValueChanged", function(_, value)
        self.Content:SetPoint("TOPLEFT", 0, value)
    end)

    -- Drag Handling
    self:SetMovable(true)
    self:RegisterForDrag("LeftButton")
    self:SetScript("OnDragStart", function(s)
        if GetWQSState().detached then
            s:StartMoving()
        end
    end)
    self:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        if GetWQSState().detached then
            local state = GetWQSState()
            local point, _, _, x, y = s:GetPoint()
            state.pos = { point, x, y }
        end
    end)

    self:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" and arg1 == "Blizzard_WorldMap" then
            self:SetupMapHooks()
            self:AttachToMap()
            self:UnregisterEvent("ADDON_LOADED")
        elseif event == "PLAYER_EQUIPMENT_CHANGED" or (event == "UNIT_INVENTORY_CHANGED" and arg1 == "player") then
            UpdateGearCache()
            self:Refresh()
        elseif event == "QUEST_DATA_LOAD_RESULT" or event == "ITEM_DATA_LOAD_RESULT" then
            -- Wipe request cache on data load events to retry
            wipe(requestCache)
            self:Refresh()
        else
            self:Refresh()
        end
    end)

    self:RegisterEvents() -- Enable background listening immediately

    if WorldMapFrame then
        self:UpdateAttachment()
        if WorldMapFrame:IsShown() and not GetWQSState().detached then
            self:Show()
            self:Refresh()
        end
    end
end

function WQS:RegisterEvents()
    self:RegisterEvent("QUEST_LOG_UPDATE")
    self:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
    self:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    self:RegisterEvent("UNIT_INVENTORY_CHANGED")
end

function WQS:UnregisterEvents()
    self:UnregisterEvent("QUEST_LOG_UPDATE")
    self:UnregisterEvent("QUEST_WATCH_LIST_CHANGED")
    self:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
    self:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
    self:UnregisterEvent("UNIT_INVENTORY_CHANGED")
end

function WQS:AttachToMap()
    if not WorldMapFrame then return end
    self:SetupMapHooks()
    self:ClearAllPoints()
    self:SetParent(WorldMapFrame)
    self:SetFrameStrata("HIGH")
    self:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 2)
    -- Correct positioning (Bottom Right of World Map)
    self:SetPoint("TOPRIGHT", WorldMapFrame, "BOTTOMRIGHT", 5, -13) -- Shifted 5 right, 13 down
    self:SetSize(620, 200)
end

function WQS:SetupMapHooks()
    if not WorldMapFrame or self.mapHooksDone then return end
    self.mapHooksDone = true

    WorldMapFrame:HookScript("OnShow", function()
        if not (SfuiDB and SfuiDB.wqsState and SfuiDB.wqsState.detached) then
            self:Show()
            self:Refresh()
        end
        -- Second refresh after a short delay for data loading
        C_Timer.After(1, function() if self:IsShown() then self:Refresh() end end)
    end)
    WorldMapFrame:HookScript("OnHide", function()
        if not (SfuiDB and SfuiDB.wqsState and SfuiDB.wqsState.detached) then
            self:Hide()
        end
    end)

    -- Map Highlight Frame (Red Ring)
    if not self.MapHighlight then
        local canvas = WorldMapFrame:GetCanvas() or WorldMapFrame.ScrollContainer.Child or WorldMapFrame
        local hl = CreateFrame("Frame", "SfuiWQSMapHighlight", canvas)
        hl:SetSize(128, 128)
        hl:SetFrameStrata("TOOLTIP")
        hl:Hide()

        -- Inner Ring
        local tex = hl:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("CENTER")
        tex:SetSize(160, 160)
        tex:SetTexture("Interface\\AddOns\\sfui\\ring.tga")
        tex:SetVertexColor(1, 0, 0, 1)

        -- Outer Glow Ring
        local glow = hl:CreateTexture(nil, "BACKGROUND")
        glow:SetPoint("CENTER")
        glow:SetSize(128, 128)
        glow:SetTexture("Interface\\AddOns\\sfui\\ring.tga")
        glow:SetVertexColor(1, 0.2, 0, 0.6) -- Slightly orange-red glow

        -- Pulse Animation
        local ag = hl:CreateAnimationGroup()

        local scale = ag:CreateAnimation("Scale")
        scale:SetScale(1.1, 1.1)
        scale:SetDuration(0.8)
        scale:SetSmoothing("IN_OUT")
        scale:SetOrder(1)

        local alpha = ag:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0.6)
        alpha:SetToAlpha(1)
        alpha:SetDuration(0.8)
        alpha:SetSmoothing("IN_OUT")
        alpha:SetOrder(1)

        ag:SetLooping("BOUNCE")
        hl.Pulse = ag

        hl:SetScript("OnShow", function(s) if s.Pulse then s.Pulse:Play() end end)
        hl:SetScript("OnHide", function(s) if s.Pulse then s.Pulse:Stop() end end)

        self.MapHighlight = hl
    end
end

function WQS:UpdateAttachment()
    local state = GetWQSState()
    if state.detached then
        self:SetParent(UIParent)
        self:SetFrameStrata("MEDIUM")
        self:ClearAllPoints()
        if state.pos then
            self:SetPoint(unpack(state.pos))
        else
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        self:Show()
        self:Refresh()
    else
        self:AttachToMap()
        if not WorldMapFrame:IsShown() then
            self:Hide()
        else
            self:Show()
            self:Refresh()
        end
    end
end

function WQS:CreateRow()
    local row = table.remove(framePool)
    if not row then
        row = CreateFrame("Button", nil, self.Content)
        row:SetSize(570, 20) -- Compacted height
        row:SetPoint("LEFT", 0, 0)
        row:SetPoint("RIGHT", 0, 0)

        row.Stripe = row:CreateTexture(nil, "BACKGROUND")
        row.Stripe:SetAllPoints()
        row.Stripe:SetColorTexture(1, 1, 1, 0.03)
        row.Stripe:Hide()

        local font = cfg and cfg.font
        row.Text = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Text, font, 12, "OUTLINE")
        row.Text:SetPoint("LEFT", 5, 0)
        row.Text:SetWidth(120)
        row.Text:SetJustifyH("LEFT")
        row.Text:SetWordWrap(false)

        row.Zone = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Zone, font, 12)
        row.Zone:SetPoint("LEFT", 130, 0)
        row.Zone:SetWidth(100)
        row.Zone:SetJustifyH("LEFT")
        row.Zone:SetTextColor(0.6, 0.6, 0.6)

        row.Reward = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Reward, font, 12)
        row.Reward:SetPoint("LEFT", 235, 0) 
        row.Reward:SetWidth(270)
        row.Reward:SetJustifyH("LEFT")
        row.Reward:SetWordWrap(false)

        row.Time = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Time, font, 12)
        row.Time:SetPoint("RIGHT", -5, 0)
        row.Time:SetWidth(60)
        row.Time:SetJustifyH("RIGHT")

        row.UpgradeGlow = row:CreateTexture(nil, "OVERLAY")
        row.UpgradeGlow:SetAllPoints()
        row.UpgradeGlow:SetColorTexture(0, 1, 0, 0.15) -- Increased visibility
        row.UpgradeGlow:Hide()

        row.Highlight = row:CreateTexture(nil, "ARTWORK")
        row.Highlight:SetAllPoints()
        row.Highlight:SetColorTexture(1, 1, 1, 0.05)
        row.Highlight:Hide()

        row:SetScript("OnEnter", function(s)
            s.Highlight:Show()
            securecall(pcall, GameTooltip.SetOwner, GameTooltip, s, "ANCHOR_RIGHT")

            local success = false
            if GameTooltip.SetWorldQuestByID then
                success = securecall(pcall, GameTooltip.SetWorldQuestByID, GameTooltip, s.questID)
            end
            if not success then
                success = securecall(pcall, GameTooltip.SetQuestLogItem, GameTooltip, "reward", 1, s.questID)
            end

            local numObjs = GetNumQuestLeaderBoards(s.questID)
            if common.SafeGT(numObjs, 0) then
                GameTooltip:AddLine(" ")
                for i = 1, numObjs do
                    local text, _, finished = GetQuestLogLeaderBoard(i, s.questID)
                    if text then
                        local r, g, b = 1, 1, 1
                        if finished then r, g, b = 0.5, 0.5, 0.5 end
                        GameTooltip:AddLine("- " .. text, r, g, b, true)
                    end
                end
            end
            GameTooltip:Show()

            -- Map Highlight
            if WorldMapFrame and sfui.wqs.MapHighlight and s.posX and s.posY and WorldMapFrame:GetMapID() == s.mapID then
                local canvas = WorldMapFrame:GetCanvas() or WorldMapFrame.ScrollContainer.Child
                if canvas then
                    local mapWidth = canvas:GetWidth()
                    local mapHeight = canvas:GetHeight()
                    if mapWidth > 0 and mapHeight > 0 then
                        sfui.wqs.MapHighlight:SetParent(canvas)
                        sfui.wqs.MapHighlight:ClearAllPoints()
                        -- Explicitly anchor to TopLeft of canvas using physical pixel distances derived from percentage
                        sfui.wqs.MapHighlight:SetPoint("CENTER", canvas, "TOPLEFT", s.posX * mapWidth, -s.posY * mapHeight)
                        sfui.wqs.MapHighlight:Show()
                    end
                end
            end
        end)
        row:SetScript("OnLeave", function(s)
            s.Highlight:Hide()
            GameTooltip:Hide()
            if sfui.wqs.MapHighlight then sfui.wqs.MapHighlight:Hide() end
        end)
        row:SetScript("OnClick", function(s, button)
            if IsShiftKeyDown() then
                if C_QuestLog.GetQuestWatchType(s.questID) == Enum.QuestWatchType.Manual then
                    C_QuestLog.RemoveWorldQuestWatch(s.questID)
                else
                    C_QuestLog.AddWorldQuestWatch(s.questID, Enum.QuestWatchType.Manual)
                end
            else
                C_QuestLog.SetSelectedQuest(s.questID)
                C_SuperTrack.SetSuperTrackedQuestID(s.questID)
                if not WorldMapFrame:IsShown() then ShowUIPanel(WorldMapFrame) end
                WorldMapFrame:SetMapID(s.mapID)
                if WorldMapFrame.ScrollToQuest then WorldMapFrame:ScrollToQuest(s.questID) end
            end
        end)
    end
    row:Show()
    table.insert(activeFrames, row)
    return row
end

function WQS:ClearRows()
    for i = #activeFrames, 1, -1 do
        local row = table.remove(activeFrames, i)
        row:Hide()
        table.insert(framePool, row)
    end
end

local lastBackgroundRefresh = 0
function WQS:Refresh()
    if refreshTimer then return end
    
    -- Significant throttle for background scanning
    if not self:IsShown() then
        local now = GetTime()
        if now - lastBackgroundRefresh < 10 then return end
        lastBackgroundRefresh = now
    end

    refreshTimer = C_Timer.After(0.3, function()
        self:DoRefresh()
        refreshTimer = nil
    end)
end

local function UpdateHeader(btn, mode, text)
    local indicator = ""
    local purple = cfg.colors.purple
    local white = cfg.colors.white
    local wqs = sfui.wqs
    if wqs.sortMode == mode then
        indicator = wqs.sortOrder == 1 and "  ▼" or "  ▲"
        btn.Text:SetTextColor(white[1], white[2], white[3])
    else
        btn.Text:SetTextColor(purple[1], purple[2], purple[3])
    end
    btn.Text:SetText(text .. indicator)
end

local function QuestSorter(a, b)
    local self = sfui.wqs
    if self.sortMode == "reward" then
        if a.sortRewardValue ~= b.sortRewardValue then
            if self.sortOrder == 1 then return a.sortRewardValue < b.sortRewardValue else return a.sortRewardValue > b.sortRewardValue end
        end
    elseif self.sortMode == "time" then
        if a.timeLeft ~= b.timeLeft then
            if self.sortOrder == 1 then return a.timeLeft < b.timeLeft else return a.timeLeft > b.timeLeft end
        end
    elseif self.sortMode == "zone" then
        if a.zoneName ~= b.zoneName then
            if self.sortOrder == 1 then return a.zoneName < b.zoneName else return a.zoneName > b.zoneName end
        end
    end
    if self.sortOrder == 1 then return a.title < b.title else return a.title > b.title end
end

function WQS:DoRefresh()
    refreshCount = refreshCount + 1
    if refreshCount > 300 then
        refreshCount = 0
        local now = GetTime()
        for qID, data in pairs(rewardDataCache) do
            if not GetQuestTimeLeftMinutes(qID) or (data.lastSeen and (now - data.lastSeen > 600)) then
                rewardDataCache[qID] = nil
                ReleaseTable(data)
            end
        end
        for qID in pairs(warbandBonusCache) do
            if not GetQuestTimeLeftMinutes(qID) then warbandBonusCache[qID] = nil end
        end
        wipe(requestCache)
    end

    if self:IsShown() then
        self:UpdateFilterStyles()
        self:ClearRows()
    end

    local questsByZone = AcquireTable()
    local seenQuests = AcquireTable()
    local currentMap = GetBestMapForUnit("player")
    local midnightZones = UpdateZoneCache()
    local now = GetTime()

    for mapID, zoneName in pairs(midnightZones) do
        local quests = (C_TaskQuest.GetQuestsForPlayerByMapID and C_TaskQuest.GetQuestsForPlayerByMapID(mapID)) or
            C_TaskQuest.GetQuestsOnMap(mapID)
        if quests and #quests > 0 then
            questsByZone[mapID] = questsByZone[mapID] or AcquireTable()
            for _, q in ipairs(quests) do
                local questID = q.questID or q.questId
                if questID and not seenQuests[questID] then
                    seenQuests[questID] = true
                    local title = GetQuestInfoByQuestID(questID)
                    if not title then
                        if not requestCache[questID] then
                            RequestLoadQuestByID(questID)
                            requestCache[questID] = true
                        end
                    else
                        local cached = rewardDataCache[questID]
                        local rewardText, sortRewardValue, isWarbound, allRewardsCached
                        local hasItems, hasGold, questHasReputation, questHasUpgrade

                        if cached and cached.title == title then
                            rewardText, sortRewardValue = cached.text, cached.sortValue
                            isWarbound, questHasReputation = cached.isWarbound, cached.hasReputationBonus
                            hasItems, hasGold, questHasUpgrade = cached.hasItems, cached.hasGold, cached.isUpgrade
                        else
                            if cached then
                                rewardDataCache[questID] = nil
                                ReleaseTable(cached)
                            end
                            rewardText, sortRewardValue, isWarbound, allRewardsCached, hasItems, hasGold, questHasReputation, questHasUpgrade =
                                ScanQuestRewards(self, questID)

                            if rewardText ~= "" and allRewardsCached then
                                local c = AcquireTable()
                                c.title, c.text, c.sortValue = title, rewardText, sortRewardValue
                                c.isWarbound, c.hasReputationBonus = isWarbound, questHasReputation
                                c.hasItems, c.hasGold, c.isUpgrade = hasItems, hasGold, questHasUpgrade
                                c.hasIlvl = hasItems -- Mark for gear-change invalidation
                                c.lastSeen = now
                                rewardDataCache[questID] = c
                            end
                        end

                        if rewardText == "" and not requestCache[questID] then
                            RequestLoadQuestByID(questID)
                            requestCache[questID] = true
                        end

                        local qData = AcquireTable()
                        qData.questID, qData.title, qData.zoneName = questID, title, zoneName
                        qData.rewardText, qData.timeLeft = rewardText, (GetQuestTimeLeftMinutes(questID) or 0)
                        qData.sortRewardValue, qData.mapID = sortRewardValue, mapID
                        qData.posX, qData.posY = q.x, q.y
                        qData.hasReputationBonus = questHasReputation
                        qData.hasItems, qData.hasGold, qData.isUpgrade = hasItems, hasGold, questHasUpgrade

                        table.insert(questsByZone[mapID], qData)
                    end
                end
            end
        end
    end

    if self:IsShown() then
        local filters = SfuiDB.wqsFilters
        local allQuests = AcquireTable()

        for mapID, qList in pairs(questsByZone) do
            for _, qData in ipairs(qList) do
                local skip = false
                if filters.reputation and not qData.hasReputationBonus then skip = true end
                if not skip and filters.items and not qData.hasItems then skip = true end
                if not skip and filters.gold and not qData.hasGold then skip = true end
                if not skip and filters.zone and qData.mapID ~= currentMap then skip = true end
                if not skip then table.insert(allQuests, qData) end
            end
        end

        table.sort(allQuests, QuestSorter)

        local offset = 0
        if #allQuests == 0 then
            local row = self:CreateRow()
            row:SetPoint("TOPLEFT", 0, 0)
            row.Text:SetText("|cffaaaaaaNo quests found in these zones.|r")
            row.Zone:SetText("")
            row.Reward:SetText("")
            row.Time:SetText("")
            offset = 18
        else
            for i, qData in ipairs(allQuests) do
                offset = self:DisplayQuestRow(qData, offset, i)
            end
        end

        self.Content:SetHeight(offset)
        self:SetHeight(math_min((10 * 18) + 65, offset + 65))
        self.ScrollBar:SetMinMaxValues(0, math_max(0, offset - self.ScrollChild:GetHeight()))

        UpdateHeader(self.SortTitle, "title", "Quest Name")
        UpdateHeader(self.SortZone, "zone", "Zone")
        UpdateHeader(self.SortReward, "reward", "Rewards / Rep / ilvl")
        UpdateHeader(self.SortTime, "time", "Time Left")

        ReleaseTable(allQuests)
    end

    -- Cleanup
    for _, qList in pairs(questsByZone) do
        for _, qData in ipairs(qList) do ReleaseTable(qData) end
        ReleaseTable(qList)
    end
    ReleaseTable(questsByZone)
    ReleaseTable(seenQuests)
end

function WQS:DisplayQuestRow(qData, offset, stripeCount, mapID)
    local questID = qData.questID
    local timeLeft = qData.timeLeft

    local row = self:CreateRow()
    row:SetPoint("TOPLEFT", 0, -offset)
    row.questID = questID
    row.mapID = qData.mapID
    row.posX = qData.posX
    row.posY = qData.posY

    if stripeCount % 2 == 0 then row.Stripe:Show() else row.Stripe:Hide() end

    row.Text:SetText(qData.title)
    row.Zone:SetText(qData.zoneName)

    if timeLeft and timeLeft > 0 then
        local timeStr = ""
        local r, g, b = 0.8, 0.8, 0.8
        if timeLeft > 1440 then
            timeStr = string_format("%dd %dh", math_floor(timeLeft / 1440), math_floor((timeLeft % 1440) / 60))
        elseif timeLeft > 60 then
            timeStr = string_format("%dh %dm", math_floor(timeLeft / 60), timeLeft % 60)
            if timeLeft < 360 then r, g, b = 1, 0.5, 0 end
        else
            timeStr = timeLeft .. "m"
            r, g, b = 1, 0.2, 0.2
        end
        row.Time:SetText(timeStr)
        row.Time:SetTextColor(r, g, b)
    else
        row.Time:SetText("")
    end

    if qData.isUpgrade then
        row.UpgradeGlow:Show()
    else
        row.UpgradeGlow:Hide()
    end

    row.Reward:SetText(qData.rewardText)

    return offset + 18
end

WQS:Initialize()
