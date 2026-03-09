local addonName, addon = ...
sfui = sfui or {}

--[[
    SFUI World Quest Summary (Midnight Edition)
    STRICTLY MIDNIGHT ONLY
    Optimized for performance with frame pooling and throttled updates.
]]

-- Localize Globals (Lints)
local CreateFrame, UIParent = _G.CreateFrame, _G.UIParent
local WorldFrame = _G.WorldFrame
local table, ipairs, pairs, type, Enum, string, math = _G.table, _G.ipairs, _G.pairs, _G.type, _G.Enum, _G.string, _G.math
local GetNumQuestLogRewardFactions = _G.GetNumQuestLogRewardFactions
local GetQuestLogRewardFaction = _G.GetQuestLogRewardFaction
local C_QuestLog, C_TaskQuest, C_Item, C_CurrencyInfo, C_Map = _G.C_QuestLog, _G.C_TaskQuest, _G.C_Item, _G.C_CurrencyInfo, _G.C_Map
local C_Timer, C_Reputation = _G.C_Timer, _G.C_Reputation
local C_AreaPoiInfo = _G.C_AreaPoiInfo
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetQuestsForPlayerByMapID = C_TaskQuest.GetQuestsForPlayerByMapID
local GetQuestsOnMap = C_TaskQuest.GetQuestsOnMap
local GetQuestTimeLeftMinutes = C_TaskQuest.GetQuestTimeLeftMinutes
local GetQuestLogRewardMoney = _G.GetQuestLogRewardMoney or function(...) return 0 end
local GetNumQuestLogRewards = _G.GetNumQuestLogRewards or function(...) return 0 end
local GetQuestLogRewardInfo = _G.GetQuestLogRewardInfo or function(...) end
local GetInventoryItemLink = _G.GetInventoryItemLink or function(...) end
local GetMoneyString = _G.GetMoneyString or tostring
local GetQuestLogLeaderBoard = _G.GetQuestLogLeaderBoard or function(...) end
local GetNumQuestLeaderBoards = _G.GetNumQuestLeaderBoards or function(...) return 0 end
local IsShiftKeyDown, ShowUIPanel = _G.IsShiftKeyDown, _G.ShowUIPanel
local WorldMapFrame = _G.WorldMapFrame
local GameTooltip, ITEM_QUALITY_COLORS = _G.GameTooltip, _G.ITEM_QUALITY_COLORS
local C_SuperTrack = _G.C_SuperTrack
local wipe = _G.wipe or (_G.table and _G.table.wipe)
local ITEM_LEVEL_PLUS = _G.ITEM_LEVEL_PLUS or "Item Level %d"
local STAT_AVERAGE_ITEM_LEVEL = _G.STAT_AVERAGE_ITEM_LEVEL or "Item Level"

-- Advance Localization (Speed)
local tonumber, tostring, math_floor, math_min, math_max = _G.tonumber, _G.tostring, _G.math.floor, _G.math.min, _G.math.max
local string_find, string_format, string_match, string_sub = _G.string.find, _G.string.format, _G.string.match, _G.string.sub
local pcall, select, unpack = _G.pcall, _G.select, _G.unpack

-- Performance Cache
local zoneCache = {}
local warbandBonusCache = {}
local equippedCache = {}
local requestCache = {}
local rewardDataCache = {} -- Persistent cache for reward strings/values
local refreshTimer

-- Slot mapping for upgrade detection
local SLOT_IDS = {
    ["INVTYPE_HEAD"] = 1, ["INVTYPE_NECK"] = 2, ["INVTYPE_SHOULDER"] = 3, ["INVTYPE_BODY"] = 4,
    ["INVTYPE_CHEST"] = 5, ["INVTYPE_ROBE"] = 5, ["INVTYPE_WAIST"] = 6, ["INVTYPE_LEGS"] = 7,
    ["INVTYPE_FEET"] = 8, ["INVTYPE_WRIST"] = 9, ["INVTYPE_HAND"] = 10, ["INVTYPE_FINGER"] = {11, 12},
    ["INVTYPE_TRINKET"] = {13, 14}, ["INVTYPE_CLOAK"] = 15, ["INVTYPE_WEAPON"] = {16, 17},
    ["INVTYPE_SHIELD"] = 17, ["INVTYPE_2HWEAPON"] = 16, ["INVTYPE_WEAPONMAINHAND"] = 16,
    ["INVTYPE_WEAPONOFFHAND"] = 17, ["INVTYPE_HOLDABLE"] = 17, ["INVTYPE_RANGED"] = 16,
    ["INVTYPE_RANGEDRIGHT"] = 16, ["INVTYPE_THROWN"] = 16, ["INVTYPE_RELIC"] = 16,
}

local function UpdateEquippedCache()
    wipe(equippedCache)
    for loc, slots in pairs(SLOT_IDS) do
        if type(slots) == "table" then
            for _, slotID in ipairs(slots) do
                local link = GetInventoryItemLink("player", slotID)
                equippedCache[slotID] = link and C_Item.GetDetailedItemLevelInfo(link) or 0
            end
        else
            local link = GetInventoryItemLink("player", slots)
            equippedCache[slots] = link and C_Item.GetDetailedItemLevelInfo(link) or 0
        end
    end
    -- Invalidate reward cache for items when gear changes (upgrades might look different)
    for qID, data in pairs(rewardDataCache) do
        if data.hasIlvl then rewardDataCache[qID] = nil end
    end
end

local function IsUpgrade(itemLink)
    if not itemLink then return false end
    local ilvl = C_Item.GetDetailedItemLevelInfo(itemLink)
    if not ilvl or ilvl <= 1 then return false end
    
    local _, _, _, _, _, _, _, _, equipLoc = C_Item.GetItemInfo(itemLink)
    local slots = SLOT_IDS[equipLoc]
    if not slots then return false end
    
    if type(slots) == "table" then
        local minIlvl = 9999
        for _, slotID in ipairs(slots) do
            local slotIlvl = equippedCache[slotID] or 0
            if slotIlvl < minIlvl then minIlvl = slotIlvl end
        end
        return ilvl > minIlvl
    else
        local slotIlvl = equippedCache[slots] or 0
        return ilvl > slotIlvl
    end
end

-- Warband Bonus Marker (Cyan Square) - Shrunk to 12x6
local WARBAND_BONUS_TEXT = " |TInterface\\Buttons\\WHITE8x8:12:6:0:0:1:1:0:1:0:1:0:255:255|t"

-- Constants (Strict Midnight Zones)
local MIDNIGHT_ZONES = {
    2393, -- Silvermoon City
    2395, -- Eversong Woods
    2437, -- Zul'Aman
    2413, -- Harandar
    2405, -- Voidstorm
    2444, -- Slayer's Rise
}

local WQS = CreateFrame("Frame", "SfuiWQS", UIParent, "BackdropTemplate")
sfui.wqs = WQS
addon.wqs = WQS
WQS:Hide() -- Hide initially, will be shown by WorldMap interaction

-- Pooling
local framePool = {}
local activeFrames = {} -- Track active rows for fast clearing
local tablePool = {}

local function AcquireTable()
    local t = table.remove(tablePool) or {}
    wipe(t) -- Ensure fresh table
    return t
end

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

local function ReleaseTable(t)
    if not t or type(t) ~= "table" then return end
    wipe(t)
    table.insert(tablePool, t)
end

-- UI Setup
function WQS:Initialize()
    self:SetSize(620, 450) -- Adjusted to fit 100/100/300 layout comfortably
    self:SetMovable(false)
    self:EnableMouse(true)
    
    self.sortMode = "reward" -- Default to Rewards
    self.sortOrder = -1      -- Highest value first
    
    local purple = sfui.config and sfui.config.colors and sfui.config.colors.purple or {0.7, 0.4, 1}
    local cyan = sfui.config and sfui.config.colors and sfui.config.colors.cyan or {0, 1, 1}
    local white = sfui.config and sfui.config.colors and sfui.config.colors.white or {1, 1, 1}

    -- Interaction handling for WorldMap
    if WorldMapFrame then
        WorldMapFrame:HookScript("OnShow", function() 
            self:Show()
            self:Refresh()
            -- Second refresh after a short delay for data loading
            C_Timer.After(1, function() if self:IsShown() then self:Refresh() end end)
        end)
        WorldMapFrame:HookScript("OnHide", function() self:Hide() end)
    end

    -- Filter State initialization (Safe Global Access)
    local function GetFilters()
        SfuiDB = SfuiDB or {}
        SfuiDB.wqsFilters = SfuiDB.wqsFilters or {
            reputation = false, items = false, gold = false, zone = false
        }
        return SfuiDB.wqsFilters
    end

    -- Footer for Filters
    local footer = CreateFrame("Frame", nil, self)
    footer:SetPoint("BOTTOMLEFT", 10, 5)
    footer:SetPoint("BOTTOMRIGHT", -10, 5)
    footer:SetHeight(26)
    self.Footer = footer

    local function CreateFilterBtn(text, key, xOffset, tooltipText)
        local btn = sfui.common.create_flat_button(footer, text, 20, 20)
        btn:SetPoint("LEFT", xOffset, 0)
        
        function btn:updateBtnStyle()
            local filters = GetFilters()
            local active = filters[key]
            local color = active and {0, 1, 1} or {0.5, 0.5, 0.5} -- Cyan if active, Gray if not
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

    function self:UpdateFilterStyles()
        if self.FilterReputation then self.FilterReputation:updateBtnStyle() end
        if self.FilterItems then self.FilterItems:updateBtnStyle() end
        if self.FilterGold then self.FilterGold:updateBtnStyle() end
    end

    self.FilterZone = sfui.common.create_checkbox(footer, "Local", function() return GetFilters().zone end, function(val)
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
    for i = 1, 10 do
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
        SetFontStyle(btn.Text, sfui.config and sfui.config.font, 11)
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

    self.SortTitle = createSortBtn("Quest Name", 100, "title")
    self.SortZone = createSortBtn("Zone", 100, "zone")
    self.SortReward = createSortBtn("Rewards / Rep / ilvl", 300, "reward")
    self.SortTime = createSortBtn("Time Left", 60, "time", "RIGHT")
    
    -- Grid Alignment
    self.SortTitle:SetPoint("LEFT", sortHeader, "LEFT", 5, 0)
    self.SortZone:SetPoint("LEFT", self.SortTitle, "RIGHT", 10, 0)
    self.SortReward:SetPoint("LEFT", self.SortZone, "RIGHT", 10, 0)
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
    content:SetSize(580, 500) -- Matches frame width minus scrollbar and padding
    content:SetPoint("TOPLEFT", 0, 0)
    content:SetPoint("TOPRIGHT", 0, 0)
    self.Content = content

    self.ScrollChild:SetScript("OnMouseWheel", function(_, delta)
        local cur = self.ScrollBar:GetValue()
        local min, max = self.ScrollBar:GetMinMaxValues()
        if delta > 0 then
            self.ScrollBar:SetValue(math.max(min, cur - 30))
        else
            self.ScrollBar:SetValue(math.min(max, cur + 30))
        end
    end)
    
    scrollBar:SetScript("OnValueChanged", function(_, value)
        self.Content:SetPoint("TOPLEFT", 0, value)
    end)

    -- Events
    self:RegisterEvent("QUEST_LOG_UPDATE")
    self:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
    self:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    self:RegisterEvent("UNIT_INVENTORY_CHANGED")
    
    self:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" and arg1 == "Blizzard_WorldMap" then
            self:AttachToMap()
            self:UnregisterEvent("ADDON_LOADED")
        elseif event == "PLAYER_EQUIPMENT_CHANGED" or (event == "UNIT_INVENTORY_CHANGED" and arg1 == "player") then
            UpdateEquippedCache()
            if self:IsShown() then self:Refresh() end
        elseif self:IsShown() then
            -- Wipe request cache on data load events to retry
            if event == "QUEST_DATA_LOAD_RESULT" or event == "ITEM_DATA_LOAD_RESULT" then
                wipe(requestCache)
            end
            self:Refresh()
        end
    end)

    if WorldMapFrame then 
        self:AttachToMap() 
        if WorldMapFrame:IsShown() then
            self:Show()
            self:Refresh()
        end
    end
end

function WQS:AttachToMap()
    if not WorldMapFrame then return end
    self:SetParent(WorldMapFrame)
    self:SetFrameStrata("HIGH")
    self:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 2)
    -- Correct positioning (Bottom Right of World Map)
    self:ClearAllPoints()
    self:SetPoint("TOPRIGHT", WorldMapFrame, "BOTTOMRIGHT", 5, -13) -- Shifted 5 right, 13 down
    -- Initial size, will be adjusted in Refresh
    self:SetSize(620, 200) 
end

function WQS:CreateRow()
    local row = table.remove(framePool)
    if not row then
        row = CreateFrame("Button", nil, self.Content)
        row:SetHeight(18) -- Compacted height
        row:SetPoint("LEFT", 0, 0)
        row:SetPoint("RIGHT", 0, 0)
        
        row.Stripe = row:CreateTexture(nil, "BACKGROUND")
        row.Stripe:SetAllPoints()
        row.Stripe:SetColorTexture(1, 1, 1, 0.03)
        row.Stripe:Hide()

        local font = sfui.config and sfui.config.font
        row.Text = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Text, font, 12)
        row.Text:SetPoint("LEFT", 5, 0)
        row.Text:SetWidth(100)
        row.Text:SetJustifyH("LEFT")
        row.Text:SetWordWrap(false)
        
        row.Zone = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Zone, font, 12)
        row.Zone:SetPoint("LEFT", 115, 0) -- Quest(5 + 100) + gap(10)
        row.Zone:SetWidth(100)
        row.Zone:SetJustifyH("LEFT")
        row.Zone:SetTextColor(0.6, 0.6, 0.6)
        
        row.Reward = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Reward, font, 12)
        row.Reward:SetPoint("LEFT", 225, 0) -- Zone(115 + 100) + gap(10)
        row.Reward:SetWidth(300)
        row.Reward:SetJustifyH("LEFT")
        row.Reward:SetWordWrap(false) -- Crop instead of wrap
        
        row.Time = row:CreateFontString(nil, "OVERLAY")
        SetFontStyle(row.Time, font, 12)
        row.Time:SetPoint("RIGHT", -5, 0) 
        row.Time:SetWidth(60)
        row.Time:SetJustifyH("RIGHT")
        
        row.Highlight = row:CreateTexture(nil, "ARTWORK")
        row.Highlight:SetAllPoints()
        row.Highlight:SetColorTexture(1, 1, 1, 0.05)
        row.Highlight:Hide()
        
        row:SetScript("OnEnter", function(s) s.Highlight:Show() end)
        row:SetScript("OnLeave", function(s) s.Highlight:Hide() end)
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

function WQS:Refresh()
    if refreshTimer then return end
    refreshTimer = C_Timer.After(0.3, function()
        self:DoRefresh()
        refreshTimer = nil
    end)
end

function WQS:DoRefresh()
    self:UpdateFilterStyles()
    self:ClearRows()
    local offset = 0
    local stripeCount = 0
    
    local questsByZone = AcquireTable()
    local seenQuests = AcquireTable()
    
    -- Hardcoded Midnight Discovery
    if not zoneCache["midnight"] then
        zoneCache["midnight"] = {}
        for _, zoneID in ipairs(MIDNIGHT_ZONES) do
            local info = C_Map.GetMapInfo(zoneID)
            if info then 
                local name = info.name or ("Map " .. zoneID)
                
                -- Zone Merging Overrides
                if zoneID == 2393 then -- Silvermoon City
                    name = "Eversong Woods"
                elseif zoneID == 2444 then -- Slayer's Rise
                    name = "Voidstorm"
                end
                
                zoneCache["midnight"][zoneID] = name
            end
        end
    end
    
    local midnightZones = zoneCache["midnight"]
    -- UpdateEquippedCache() -- Removed from refresh loop, now event-driven
    
    -- Scan World Quests on these specific Midnight zones
    for mapID, zoneName in pairs(midnightZones) do
        local quests = (C_TaskQuest.GetQuestsForPlayerByMapID and C_TaskQuest.GetQuestsForPlayerByMapID(mapID)) or C_TaskQuest.GetQuestsOnMap(mapID)
        if quests and #quests > 0 then
            questsByZone[mapID] = questsByZone[mapID] or AcquireTable()
            for _, q in ipairs(quests) do
                        local questID = q.questID or q.questId
                if questID and not seenQuests[questID] then
                    seenQuests[questID] = true
                    
                    local cached = rewardDataCache[questID]
                    local title = C_TaskQuest.GetQuestInfoByQuestID(questID)
                    if not title then
                        if not requestCache[questID] then
                            C_QuestLog.RequestLoadQuestByID(questID)
                            requestCache[questID] = true
                        end
                    end
                    
                    if title then
                        local rewardText, sortRewardValue
                        local hasWarbandBonus, numItems, money
                        
                        -- CRITICAL: If cached is missing reputation tag, force a rescan
                        if cached and cached.title == title and cached.hasReputationBonus == nil then
                            cached = nil
                            rewardDataCache[questID] = nil
                        end

                        if cached and cached.title == title then
                            rewardText = cached.text
                            sortRewardValue = cached.sortValue or 0
                        else
                            local timeLeft = C_TaskQuest.GetQuestTimeLeftMinutes(questID) or 0
                            local rewardParts = AcquireTable()
                            sortRewardValue = 0 
                            local hasIlvlIndicator = false
                            
                            -- Warband Check
                            hasWarbandBonus = warbandBonusCache[questID]
                            if hasWarbandBonus == nil then
                                hasWarbandBonus = C_QuestLog.QuestContainsFirstTimeRepBonusForPlayer and C_QuestLog.QuestContainsFirstTimeRepBonusForPlayer(questID)
                                if not hasWarbandBonus and self.ScanTooltip then
                                    self.ScanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
                                    if self.ScanTooltip.SetWorldQuestByID then self.ScanTooltip:SetWorldQuestByID(questID) else self.ScanTooltip:SetQuestLogItem("reward", 1, questID) end
                                    local lines = self.ScanTooltip.leftLines
                                    for i = 2, math_min(self.ScanTooltip:NumLines(), 10) do
                                        local leftLine = lines[i]
                                        local text = leftLine and leftLine:GetText()
                                        if text and (string_find(text, "Warband reputation bonus") or string_find(text, "one%-time bonus")) then
                                            hasWarbandBonus = true; break
                                        end
                                    end
                                end
                                warbandBonusCache[questID] = hasWarbandBonus or false
                            end

                            local isWarbound = C_QuestLog.IsQuestWarbound and C_QuestLog.IsQuestWarbound(questID)
                            local marker = (hasWarbandBonus or isWarbound) and WARBAND_BONUS_TEXT or ""
                            
                            -- Currencies
                            local rewardCurrencies = C_QuestLog.GetQuestRewardCurrencies(questID)
                            if rewardCurrencies then
                                for _, currency in ipairs(rewardCurrencies) do
                                    local currencyInfo = C_CurrencyInfo.GetCurrencyInfo(currency.currencyID)
                                    local currentMarker = (marker ~= "" or (currency.currencyID >= 2800)) and WARBAND_BONUS_TEXT or ""
                                    local isRep = (currencyInfo and (currencyInfo.categoryID == 2112 or currencyInfo.maxQuantity == 0))
                                    
                                    if isRep then 
                                        table.insert(rewardParts, "+" .. currency.totalRewardAmount .. " |T" .. currency.texture .. ":12:12:0:0:64:64:4:60:4:60|t" .. currentMarker)
                                        sortRewardValue = sortRewardValue + (currency.totalRewardAmount / 10)
                                    else
                                        table.insert(rewardParts, "|T" .. currency.texture .. ":12:12:0:0:64:64:4:60:4:60|t " .. currency.totalRewardAmount .. currentMarker)
                                        sortRewardValue = sortRewardValue + 100000 + currency.totalRewardAmount
                                    end
                                end
                            end
                            
                            -- Items
                            numItems = GetNumQuestLogRewards(questID)
                            for i = 1, numItems do
                                local itemName, itemTexture, quantity, quality, _, itemID = GetQuestLogRewardInfo(i, questID)
                                if itemTexture then
                                    local itemLink = (C_QuestLog.GetQuestRewardLink and C_QuestLog.GetQuestRewardLink(questID, i)) or ("item:" .. (itemID or 0))
                                    local ilvl = 0
                                    if self.ScanTooltip then
                                        self.ScanTooltip:SetOwner(self, "ANCHOR_NONE")
                                        self.ScanTooltip:SetQuestLogItem("reward", i, questID)
                                        local lines = self.ScanTooltip.leftLines
                                        for lineIdx = 2, math_min(self.ScanTooltip:NumLines(), 10) do
                                            local leftLine = lines[lineIdx]
                                            local text = leftLine and leftLine:GetText()
                                            if text then
                                                local foundIlvl = string_match(text, "(%d+)%+?")
                                                if foundIlvl and (string_find(text, string_sub(ITEM_LEVEL_PLUS, 1, 5)) or string_find(text, STAT_AVERAGE_ITEM_LEVEL)) then
                                                    ilvl = tonumber(foundIlvl); break
                                                end
                                            end
                                        end
                                    end

                                    if ilvl < 200 then
                                        local detailed = C_Item.GetDetailedItemLevelInfo(itemLink)
                                        if detailed and detailed > ilvl then ilvl = detailed end
                                    end

                                    local ilvlText = ""
                                    if ilvl and ilvl > 0 then
                                        local isUpgrade = IsUpgrade(itemLink)
                                        ilvlText = "|c" .. (isUpgrade and "ff00ffff" or "ffffffff") .. "(" .. ilvl .. ")|r " 
                                        sortRewardValue = sortRewardValue + 1000000 + (ilvl * 10)
                                        hasIlvlIndicator = true
                                    end
                                    
                                    local color = ITEM_QUALITY_COLORS[quality or 1].hex
                                    local qtyCleanText = (quantity and quantity > 1) and (quantity .. " ") or ""
                                    table.insert(rewardParts, "|T" .. itemTexture .. ":12:12:0:0:64:64:4:60:4:60|t " .. ilvlText .. color .. "[" .. qtyCleanText .. itemName .. "]|r" .. marker)
                                end
                            end
                            
                            -- Money
                            money = GetQuestLogRewardMoney(questID)
                            if money > 0 then 
                                table.insert(rewardParts, GetMoneyString(money))
                                sortRewardValue = sortRewardValue + (money / 10000)
                            end

                            rewardText = table.concat(rewardParts, " | ")
                            ReleaseTable(rewardParts)
                            
                            -- Persist in cache (Only if we found something, otherwise rescan next time)
                            if rewardText ~= "" then
                                rewardDataCache[questID] = {
                                    title = title,
                                    text = rewardText,
                                    sortValue = sortRewardValue,
                                    hasIlvl = hasIlvlIndicator,
                                    isWarbound = (hasWarbandBonus or isWarbound),
                                    hasItems = (numItems > 0),
                                    hasGold = (money > 0),
                                    hasReputationBonus = hasWarbandBonus
                                }
                            end
                        end

                        if rewardText == "" then
                            if not requestCache[questID] then
                                C_QuestLog.RequestLoadQuestByID(questID)
                                requestCache[questID] = true
                            end
                        end
                        
                        local qData = AcquireTable()
                        qData.questID = questID
                        qData.title = title
                        qData.zoneName = zoneName
                        qData.rewardText = rewardText
                        qData.timeLeft = GetQuestTimeLeftMinutes(questID) or 0
                        qData.sortRewardValue = sortRewardValue
                        qData.mapID = mapID
                        
                        -- Apply tags from cache or current scan local variables
                        if cached and cached.title == title then
                            qData.hasReputationBonus = cached.hasReputationBonus
                            qData.hasItems = cached.hasItems
                            qData.hasGold = cached.hasGold
                        else
                            -- We just scanned these, use the local variables from the current loop
                            qData.hasReputationBonus = hasWarbandBonus
                            qData.hasItems = (numItems and numItems > 0)
                            qData.hasGold = (money and money > 0)
                        end
                        
                        questsByZone[mapID] = questsByZone[mapID] or AcquireTable()
                        table.insert(questsByZone[mapID], qData)
                    end
                end
            end
        end

    end

    local sortedMaps = AcquireTable()
    for mapID in pairs(questsByZone) do table.insert(sortedMaps, mapID) end
    table.sort(sortedMaps, function(a, b) return (midnightZones[a] or "") < (midnightZones[b] or "") end)

    local allQuests = AcquireTable()
    
    -- Ensure filters exist
    SfuiDB = SfuiDB or {}
    SfuiDB.wqsFilters = SfuiDB.wqsFilters or {
        reputation = false, items = false, gold = false, zone = false
    }
    local filters = SfuiDB.wqsFilters
    local currentMap = C_Map.GetBestMapForUnit("player")

    for _, mapID in ipairs(sortedMaps) do
        for _, qData in ipairs(questsByZone[mapID]) do
            local skip = false
            if filters.reputation and not qData.hasReputationBonus then skip = true end
            if not skip and filters.items and not qData.hasItems then skip = true end
            if not skip and filters.gold and not qData.hasGold then skip = true end
            if not skip and filters.zone and qData.mapID ~= currentMap then skip = true end
            
            if not skip then
                table.insert(allQuests, qData)
            end
        end
    end
    
    table.sort(allQuests, function(a, b)

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
        if a.title ~= b.title then
            if self.sortOrder == 1 then return a.title < b.title else return a.title > b.title end
        end
        return false
    end)

    if #allQuests == 0 then
        local row = self:CreateRow()
        row:SetPoint("TOPLEFT", 0, 0)
        row.Text:SetText("|cffaaaaaaNo world quests found for Midnight.|r")
        row.Zone:SetText("")
        row.Reward:SetText("")
        row.Time:SetText("")
        offset = 18
    else
        for _, qData in ipairs(allQuests) do
            offset = self:DisplayQuestRow(qData, offset, stripeCount, qData.mapID)
            stripeCount = stripeCount + 1
        end
    end

    self.Content:SetHeight(offset)
    
    -- Stable Frame Height (Fixed to 10 rows to prevent jumping)
    local headerGap = 35 -- Space for headers
    local footerGap = 30 -- Space for footer
    local rowHeight = 18
    local maxLines = 10
    local frameHeight = (maxLines * rowHeight) + headerGap + footerGap
    
    self:SetHeight(frameHeight)
    
    local maxScroll = math.max(0, offset - self.ScrollChild:GetHeight())
    self.ScrollBar:SetMinMaxValues(0, maxScroll)

    -- Release Pooled Tables (Explicitly release nested items first)
    for _, qData in ipairs(allQuests) do ReleaseTable(qData) end
    ReleaseTable(allQuests)
    
    for mapID, quests in pairs(questsByZone) do
        -- We don't release qData here because they were already released in allQuests
        ReleaseTable(quests)
    end
    ReleaseTable(questsByZone)
    ReleaseTable(sortedMaps)
    ReleaseTable(seenQuests)

    local function updateHeader(btn, mode, text)
        local indicator = ""
        local purple = sfui.config.colors.purple
        local white = sfui.config.colors.white
        if self.sortMode == mode then
            indicator = self.sortOrder == 1 and "  ▼" or "  ▲"
            btn.Text:SetTextColor(white[1], white[2], white[3])
        else
            btn.Text:SetTextColor(purple[1], purple[2], purple[3])
        end
        btn.Text:SetText(text .. indicator)
    end

    updateHeader(self.SortTitle, "title", "Quest Name")
    updateHeader(self.SortZone, "zone", "Zone")
    updateHeader(self.SortReward, "reward", "Rewards / Rep / ilvl")
    updateHeader(self.SortTime, "time", "Time Left")
end

function WQS:DisplayQuestRow(qData, offset, stripeCount, mapID)
    local questID = qData.questID
    local timeLeft = qData.timeLeft
    
    local row = self:CreateRow()
    row:SetPoint("TOPLEFT", 0, -offset)
    row.questID = questID
    
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
    
    row.Reward:SetText(qData.rewardText)
    
    row:SetScript("OnEnter", function(s)
        s.Highlight:Show()
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        
        local success = false
        if GameTooltip.SetWorldQuestByID then
            success = pcall(function() GameTooltip:SetWorldQuestByID(s.questID) end)
        end
        if not success then
            success = pcall(function() GameTooltip:SetQuestLogItem("reward", 1, s.questID) end)
        end
        
        local numObjs = GetNumQuestLeaderBoards(s.questID)
        if numObjs > 0 then
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
    end)
    row:SetScript("OnLeave", function(s) s.Highlight:Hide() GameTooltip:Hide() end)

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
            WorldMapFrame:SetMapID(mapID)
            if WorldMapFrame.ScrollToQuest then WorldMapFrame:ScrollToQuest(s.questID) end
        end
    end)
    
    return offset + 18
end

WQS:Initialize()
