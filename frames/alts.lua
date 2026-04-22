local addonName, addon = ...
---@diagnostic disable: undefined-global, undefined-field
sfui = sfui or {}
sfui.alts = {}

local cfg = sfui.config.alts
-- SfuiDB is global, do not shadow it locally

-- Localized APIs
local CreateFrame = CreateFrame
local UIParent = UIParent
local UnitGUID = UnitGUID
local UnitName = UnitName
local UnitClass = UnitClass
local UnitRace = UnitRace
local UnitLevel = UnitLevel
local GetAverageItemLevel = GetAverageItemLevel
local GetServerTime = GetServerTime
local GetMoney = GetMoney
local AbbreviateLargeNumbers = AbbreviateLargeNumbers
local table = table
local wipe = wipe
local C_Timer = C_Timer
local unpack = unpack or table.unpack

-- Frame Pooling
local columnPool = {}
local cellPool = {}
local tablePool = {}

local function AcquireTable()
    local t = table.remove(tablePool) or {}
    t.isDynamic = true
    return t
end

local function ReleaseTable(t)
    if not t then return end
    wipe(t)
    table.insert(tablePool, t)
end

local function ReleaseTableRecursive(t)
    if not t then return end
    for k, v in pairs(t) do
        if type(v) == "table" then
            ReleaseTableRecursive(v)
        end
    end
    ReleaseTable(t)
end

local function AcquireColumn(parent)
    local f = table.remove(columnPool)
    if not f then
        f = CreateFrame("Frame", nil, parent)
    else
        f:SetParent(parent)
        f:Show()
    end
    return f
end

local function ReleaseColumn(f)
    f:Hide()
    f:SetParent(nil)
    f:ClearAllPoints()
    table.insert(columnPool, f)
end

local function AcquireCell(parent)
    local f = table.remove(cellPool)
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.text:SetPoint("CENTER")
    else
        f:SetParent(parent)
        f:Show()
        if f.text then
            f.text:Show()
            f.text:ClearAllPoints()
            f.text:SetText("")
            f.text:SetTextColor(unpack(sfui.config.colors.white))
            f.text:SetFontObject("GameFontHighlightSmall")
            f.text:SetPoint("CENTER")
        end
        if f.rightText then
            f.rightText:Hide()
        end
        -- Hide any extra textures, fonts, or buttons that might have been added
        -- OPTIMIZATION: Avoid { f:GetRegions() } which creates a temporary table
        local numRegions = f:GetNumRegions()
        for i = 1, numRegions do
            local r = select(i, f:GetRegions())
            if r and r ~= f.text then
                if r:IsObjectType("Texture") or r:IsObjectType("FontString") then
                    r:Hide()
                end
            end
        end
        local numChildren = f:GetNumChildren()
        for i = 1, numChildren do
            local c = select(i, f:GetChildren())
            if c then c:Hide() end
        end
    end
    return f
end

local function ReleaseCell(f)
    f:Hide()
    f:SetParent(nil)
    f:ClearAllPoints()
    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)
    -- Clear the delete button's stale OnClick closure so the previous
    -- alt's data table can be garbage-collected.
    if f.del then
        f.del:SetScript("OnClick", nil)
        f.del:SetScript("OnEnter", nil)
        f.del:SetScript("OnLeave", nil)
        f.del:Hide()
    end
    table.insert(cellPool, f)
end

-- Professional Weekly KP Sources (TWW & Midnight Combined)
local PROF_KP_SOURCES = {
    [171] = { treatise = { 95127 }, quest = { 93690 }, treasures = { { 93528 }, { 93529 } }, catchup = 3189 },                                                                 -- Alchemy
    [164] = { treatise = { 95128 }, quest = { 93691 }, treasures = { { 93530 }, { 93531 } }, catchup = 3199 },                                                                 -- Blacksmithing
    [333] = { treatise = { 95129 }, quest = { 93699, 93698, 93697 }, treasures = { { 95048, 95049, 95050, 95051, 95052 }, { 95053 }, { 93532 }, { 93533 } }, catchup = 3198 }, -- Enchanting
    [202] = { treatise = { 95138 }, quest = { 93692 }, treasures = { { 93534 }, { 93535 } }, catchup = 3197 },                                                                 -- Engineering
    [182] = { treatise = { 95130 }, quest = { 93700, 93701, 93702, 93703, 93704 }, treasures = { { 81425, 81426, 81427, 81428, 81429 }, { 81430 } }, catchup = 3196 },         -- Herbalism
    [773] = { treatise = { 95131 }, quest = { 93693 }, treasures = { { 93536 }, { 93537 } }, catchup = 3195 },                                                                 -- Inscription
    [755] = { treatise = { 95133 }, quest = { 93694 }, treasures = { { 93539 }, { 93538 } }, catchup = 3194 },                                                                 -- Jewelcrafting
    [165] = { treatise = { 95134 }, quest = { 93695 }, treasures = { { 93540 }, { 93541 } }, catchup = 3193 },                                                                 -- Leatherworking
    [186] = { treatise = { 95135 }, quest = { 93705, 93706, 93707, 93708, 93709 }, treasures = { { 88673, 88674, 88675, 88676, 88677 }, { 88678 } }, catchup = 3192 },         -- Mining
    [393] = { treatise = { 95136 }, quest = { 93710, 93711, 93712, 93713, 93714 }, treasures = { { 88534, 88549, 88536, 88537, 88530 }, { 88529 } }, catchup = 3191 },         -- Skinning
    [197] = { treatise = { 95137 }, quest = { 93696 }, treasures = { { 93542 }, { 93543 } }, catchup = 3190 },                                                                 -- Tailoring
}

-- Configuration & Data Tables
local CATEGORIES = {}

local CURRENCIES = {
    { isGroup = true, label = "Crests", items = {
        { id = 3345, icon = 7639521 },                       -- Hero Dawncrest
        { id = 3347, icon = 7639523 },                       -- Gilded Dawncrest
    }},
    { id = 3212, label = "Spark",    icon = 7551418, displayItem = 232875 }, -- Spark of Fortune / Spark of Radiance (item: usable count)
    { id = 3378, label = "Catalyst", icon = 4622294 },                       -- Catalyst Charges
    { isGroup = true, label = "Keys", items = {
        { id = 3028, icon = 4622270 },                       -- Restored Coffer Key
        { id = 3310, icon = 133016 },                        -- Coffer Key Shard
    }},
    -- 12.0.5 Currencies and Items
    { isGroup = true, label = "VoidCore", items = {
        { id = 3418,   icon = 0 },                             -- Nebulous Voidcore
        { id = 268650, icon = 0, isItem = true },              -- Ascendant Voidshard
        { id = 268552, icon = 0, isItem = true },              -- Ascendant Voidcore
    }},
    { id = 3405,   label = "Accolade", icon = 0 },                             -- Field Accolade
    { id = 3373,   label = "Pearl",    icon = 0 },                             -- Angler Pearls
    { id = 267051, label = "Particle", icon = 0, isItem = true },              -- Dark Particle
}

-- Warband pool quests: IsQuestFlaggedCompleted is account-wide for these,
-- so we track per-character completion via QUEST_TURNED_IN events.
local LEGENDS_POOL = { 88993, 88994, 88996, 88997, 88995 }

local BASE_CATEGORIES = {
    { name = "GENERAL",       label = "Character",     type = "header" },
    { name = "ILVL",          label = "Level / iLvl",  type = "stat",       key = "iLvl",     format = "%.1f" },
    { name = "RATING",        label = "M+ Rating",     type = "stat",       key = "rating" },
    { name = "KEystone",      label = "Current Key",   type = "keystone" },

    { name = "QUESTS_HEADER", label = "Weekly Quests", type = "header" },
    { name = "QUESTS_GRID",   label = "Quests",        type = "quests_grid" },
    { name = "PREY",          label = "Hunt Progress", type = "prey" },

    { name = "VAULT_HEADER",  label = "Great Vault",   type = "header" },
    { name = "VAULT_RAID",    label = "Raid",          type = "vault_row",  group = "raid" },
    { name = "VAULT_DUNGEON", label = "Dungeon",       type = "vault_row",  group = "dungeon" },
    { name = "VAULT_WORLD",   label = "World/Delve",   type = "vault_row",  group = "world" },

    { name = "RAID_HEADER",   label = "Raid Progress", type = "header" },
    { name = "RAID_M",        label = "Mythic",        type = "raid_grid",  difficulty = 16 },
    { name = "RAID_H",        label = "Heroic",        type = "raid_grid",  difficulty = 15 },
    { name = "RAID_N",        label = "Normal",        type = "raid_grid",  difficulty = 14 },
}

local function ReleaseDynamicCategories()
    for i = #CATEGORIES, 1, -1 do
        local cat = table.remove(CATEGORIES, i)
        if cat.isDynamic then
            ReleaseTableRecursive(cat)
        end
    end
end

local categoriesBuilt = false
function sfui.alts.RefreshDynamicCategories(force)
    if categoriesBuilt and not force then
        -- Standard incremental update (professions only)
        for i = #CATEGORIES, 1, -1 do
            if CATEGORIES[i].type == "prof_slot" or CATEGORIES[i].name == "PROFESSION_HEADER" then
                local cat = table.remove(CATEGORIES, i)
                if cat.isDynamic then
                    ReleaseTable(cat)
                end
            end
        end

        local hasProf = false
        for guid, data in pairs(SfuiDB.alts or {}) do
            if data.profKP and next(data.profKP) then
                hasProf = true
                break
            end
        end

        if hasProf then
            local h = AcquireTable()
            h.name, h.label, h.type = "PROFESSION_HEADER", "Professions", "header"
            table.insert(CATEGORIES, h)

            local p1 = AcquireTable()
            p1.name, p1.label, p1.type, p1.slot = "PROFESSION_1", "", "prof_slot", 1
            table.insert(CATEGORIES, p1)

            local p2 = AcquireTable()
            p2.name, p2.label, p2.type, p2.slot = "PROFESSION_2", "", "prof_slot", 2
            table.insert(CATEGORIES, p2)
        end
        return
    end

    -- Full rebuild
    ReleaseDynamicCategories()
    wipe(CATEGORIES)
    for i, cat in ipairs(BASE_CATEGORIES) do
        CATEGORIES[i] = cat
    end

    local maps = C_ChallengeMode.GetMapTable()
    if maps and #maps > 0 then
        local dh = AcquireTable()
        dh.name, dh.label, dh.type = "DUNGEONS_HEADER", "Dungeons", "header"
        table.insert(CATEGORIES, dh)

        if SfuiDB.showM0Dungeons ~= false then
            local m0 = AcquireTable()
            m0.name, m0.label, m0.type = "M0_GRID", "Mythic 0", "m0_grid"
            table.insert(CATEGORIES, m0)
        end

        for _, mapID in ipairs(maps) do
            local name = C_ChallengeMode.GetMapUIInfo(mapID)
            if name then
                local dc = AcquireTable()
                dc.name, dc.label, dc.type, dc.mapID = "DUNGEON_" .. mapID, name, "dungeon", mapID
                table.insert(CATEGORIES, dc)
            end
        end
    end

    -- Add Currencies from hardcoded list
    local ch = AcquireTable()
    ch.name, ch.label, ch.type = "CURRENCY_HEADER", "Currency", "header"
    table.insert(CATEGORIES, ch)

    for _, currencyDef in ipairs(CURRENCIES) do
        local cc = AcquireTable()
        if currencyDef.isGroup then
            cc.name = "CURRENCY_GROUP_" .. currencyDef.items[1].id
            cc.label = currencyDef.label
            cc.type = "currency_group"
            cc.items = AcquireTable()
            for _, itemDef in ipairs(currencyDef.items) do
                local itemConfig = AcquireTable()
                itemConfig.id = itemDef.id
                itemConfig.isItem = itemDef.isItem
                local icon = itemDef.icon
                if not icon or icon == 0 then
                    if itemConfig.isItem then
                        icon = C_Item.GetItemIconByID(itemConfig.id) or 134400
                    else
                        local info = C_CurrencyInfo.GetCurrencyInfo(itemConfig.id)
                        icon = (info and info.iconFileID) or 134400
                    end
                end
                itemConfig.icon = icon
                table.insert(cc.items, itemConfig)
            end
        else
            cc.name, cc.label, cc.type = "CURRENCY_" .. currencyDef.id, currencyDef.label, "currency"
            cc.id = currencyDef.id
            cc.isItem = currencyDef.isItem
            
            local icon = currencyDef.icon
            if not icon or icon == 0 then
                if cc.isItem then
                    icon = C_Item.GetItemIconByID(cc.id) or 134400
                else
                    local info = C_CurrencyInfo.GetCurrencyInfo(cc.id)
                    icon = (info and info.iconFileID) or 134400
                end
            end
            cc.icon = icon
        end
        
        table.insert(CATEGORIES, cc)
    end

    local hasProf = false
    for guid, data in pairs(SfuiDB.alts or {}) do
        if data.profKP and next(data.profKP) then
            hasProf = true
            break
        end
    end

    if hasProf then
        local h = AcquireTable()
        h.name, h.label, h.type = "PROFESSION_HEADER", "Professions", "header"
        table.insert(CATEGORIES, h)

        local p1 = AcquireTable()
        p1.name, p1.label, p1.type, p1.slot = "PROFESSION_1", "", "prof_slot", 1
        table.insert(CATEGORIES, p1)

        local p2 = AcquireTable()
        p2.name, p2.label, p2.type, p2.slot = "PROFESSION_2", "", "prof_slot", 2
        table.insert(CATEGORIES, p2)
    end

    categoriesBuilt = true
end

-- Character data collection
local function GetCurrentCharacterGUID()
    return UnitGUID("player")
end

local syncTimer = nil
local needsSync = false
local leavingWorld = false

function sfui.alts.SyncCurrentCharacter()
    if leavingWorld or InCombatLockdown() then
        needsSync = true
        return
    end


    if syncTimer then return end
    syncTimer = C_Timer.NewTimer(10.0, function()
        syncTimer = nil
        needsSync = false
        sfui.alts.PerformSync()
        sfui.alts.UpdateUI()
    end)
end

local preyLogDirty = true

local ejInstanceCache = nil
local function GetEJInstanceCache()
    if ejInstanceCache then return ejInstanceCache end
    ejInstanceCache = {}
    local currentTier = EJ_GetCurrentTier()
    local index = 1
    while true do
        local instanceID, name = EJ_GetInstanceByIndex(index, false)
        if not instanceID then break end
        ejInstanceCache[name] = instanceID
        index = index + 1
    end
    return ejInstanceCache
end


function sfui.alts.CheckWeeklyResets()
    local now = GetServerTime()
    local thirtyDaysSecs = 30 * 24 * 60 * 60
    local secondsToReset = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and
        C_DateAndTime.GetSecondsUntilWeeklyReset() or 0
    local currentNextReset = secondsToReset > 0 and (now + secondsToReset) or nil

    for g, d in pairs(SfuiDB.alts or {}) do
        if d.lastUpdate and (now - d.lastUpdate > thirtyDaysSecs) then
            SfuiDB.alts[g] = nil
        elseif d.nextWeeklyReset and now > d.nextWeeklyReset then
            if d.quests then wipe(d.quests) end
            if d.prey then wipe(d.prey) end
            if d.profKP then
                for _, pData in pairs(d.profKP) do
                    if type(pData) == "table" then
                        pData.done = 0
                        if pData.details then
                            pData.details.treatise = false
                            pData.details.quest = false
                            pData.details.treasures = 0
                        end
                    end
                end
            end
            if d.vault then
                -- Check if any slot was completed before wiping, so we can
                -- flag the character as having a claimable reward.
                local groups = { "raid", "dungeon", "world" }
                for _, group in ipairs(groups) do
                    if d.vault[group] then
                        for _, slot in pairs(d.vault[group]) do
                            if slot.progress and slot.threshold and slot.threshold > 0 and slot.progress >= slot.threshold then
                                d.vault.hasReward = true
                                break
                            end
                        end
                    end
                    if d.vault.hasReward then break end
                end
                -- Always clear stale progress from last week so offline
                -- characters don't display old filled vault boxes.
                if d.vault.raid then wipe(d.vault.raid) end
                if d.vault.dungeon then wipe(d.vault.dungeon) end
                if d.vault.world then wipe(d.vault.world) end
            end
            if d.m0 then wipe(d.m0) end
            if d.raids then wipe(d.raids) end

            d.nextWeeklyReset = currentNextReset
        end
    end

    -- Return the current next reset so PerformSync can save it
    return currentNextReset
end

function sfui.alts.PerformSync(isLogout)
    if not isLogout and leavingWorld then return end

    -- Cancel any pending timer if we just performed a sync (manual or logout)
    if syncTimer then
        syncTimer:Cancel()
        syncTimer = nil
    end

    sfui.alts.RefreshDynamicCategories()

    local currentNextReset = sfui.alts.CheckWeeklyResets()

    local guid = GetCurrentCharacterGUID()
    local name = UnitName("player")
    local level = UnitLevel("player")

    -- VALIDATION GUARD: Do not sync if character and level data are not yet available
    -- Also guard against iLvl being 0 during logout transitions to prevent data wiping
    local _, avgItemLevelEquipped = GetAverageItemLevel()
    if not guid or not name or name == "Unknown Entity" or not level or level <= 0 or avgItemLevelEquipped <= 0 then
        return
    end

    SfuiDB.alts[guid] = SfuiDB.alts[guid] or {}
    local data = SfuiDB.alts[guid]

    if currentNextReset then
        data.nextWeeklyReset = currentNextReset
    end

    local _, realm = UnitName("player")
    data.name = name
    data.realm = realm or GetRealmName()

    local _, class = UnitClass("player")
    data.class = class

    local _, race = UnitRace("player")
    data.race = race

    data.level = level
    data.iLvl = avgItemLevelEquipped

    data.lastUpdate = GetServerTime()

    -- Mythic+ Rating and Keystone
    local rating = C_ChallengeMode.GetOverallDungeonScore()
    data.rating = rating

    local mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    local keystoneLevel = C_MythicPlus.GetOwnedKeystoneLevel()
    if mapID and keystoneLevel then
        if not data.keystone then
            data.keystone = AcquireTable()
            data.keystone.isDynamic = nil
        end
        data.keystone.mapID = mapID
        data.keystone.level = keystoneLevel
    else
        if data.keystone then
            ReleaseTable(data.keystone)
            data.keystone = nil
        end
    end

    -- Mythic+ Dungeon Best Scores
    data.dungeons = data.dungeons or {}
    data.m0 = data.m0 or {}
    local maps = C_ChallengeMode.GetMapTable()

    local seasonDungeonNames = {}
    if maps and #maps > 0 then
        local currentRuns = C_MythicPlus.GetRunHistory(false, true) or {}
        for _, mID in ipairs(maps) do
            local intimeInfo, overtimeInfo = C_MythicPlus.GetSeasonBestForMap(mID)
            local bestLevel = 0
            local bestTimed = 0
            if intimeInfo then
                bestLevel = intimeInfo.level
                bestTimed = intimeInfo.level
            end
            if overtimeInfo and overtimeInfo.level > bestLevel then
                bestLevel = overtimeInfo.level
            end

            -- GetRunHistory updates faster than GetSeasonBestForMap directly after completing a dungeon
            for _, run in ipairs(currentRuns) do
                if run.mapChallengeModeID == mID then
                    if run.level > bestLevel then
                        bestLevel = run.level
                    end
                    if run.completed and run.level > bestTimed then
                        bestTimed = run.level
                    end
                end
            end

            data.dungeons[mID] = data.dungeons[mID] or {}
            data.dungeons[mID].level = bestLevel
            data.dungeons[mID].timed = bestTimed
        end
    end

    -- Cross-reference current expansion M0s using Encounter Journal
    local instanceCache = GetEJInstanceCache()
    for name, instanceID in pairs(instanceCache) do
        data.m0[instanceID] = false -- Default available
    end

    local numSaved = GetNumSavedInstances()
    for i = 1, numSaved do
        local name, _, _, difficulty, locked, _, _, isRaid = GetSavedInstanceInfo(i)
        if difficulty == 23 and locked and not isRaid then
            local instanceID = instanceCache[name]
            if instanceID then
                data.m0[instanceID] = true
            end
        end
    end

    data.vault = data.vault or {}
    data.vault.hasReward = C_WeeklyRewards and C_WeeklyRewards.HasAvailableRewards()
    data.vault.raid = data.vault.raid or {}
    data.vault.dungeon = data.vault.dungeon or {}
    data.vault.world = data.vault.world or {}
    wipe(data.vault.raid)
    wipe(data.vault.dungeon)
    wipe(data.vault.world)
    local activities = C_WeeklyRewards.GetActivities()

    for _, activity in ipairs(activities) do
        local group = "world"
        if activity.type == Enum.WeeklyRewardChestThresholdType.Raid then
            group = "raid"
        elseif activity.type == Enum.WeeklyRewardChestThresholdType.Activities then
            group = "dungeon"
        end

        if activity.index >= 1 and activity.index <= 3 then
            data.vault[group][activity.index] = data.vault[group][activity.index] or {}
            data.vault[group][activity.index].progress = activity.progress or 0
            data.vault[group][activity.index].threshold = activity.threshold or 0
            data.vault[group][activity.index].level = activity.level or 0
        end
    end

    -- Raid Progress (Boss Kills)
    data.raids = data.raids or {}
    local difficulties = { 14, 15, 16 } -- Normal, Heroic, Mythic
    for _, diff in ipairs(difficulties) do
        data.raids[diff] = data.raids[diff] or {}
        wipe(data.raids[diff])
    end

    local numSaved = GetNumSavedInstances()
    for i = 1, numSaved do
        local name, _, _, difficulty, _, _, _, _, _, _, numEncounters = GetSavedInstanceInfo(i)
        -- Only track difficulties 14, 15, 16 (Normal, Heroic, Mythic)
        if difficulty >= 14 and difficulty <= 16 then
            for q = 1, numEncounters do
                local _, _, isKilled = GetSavedInstanceEncounterInfo(i, q)
                data.raids[difficulty][q] = isKilled
            end
        end
    end

    -- PvP and Expansion Currencies
    data.currencies = data.currencies or {}
    local function SyncCurrency(cDef)
        if cDef.isItem then
            local count = C_Item.GetItemCount(cDef.id, true) or 0
            data.currencies[cDef.id] = count
        else
            local info = C_CurrencyInfo.GetCurrencyInfo(cDef.id)
            if info then
                data.currencies[cDef.id] = data.currencies[cDef.id] or {}
                local c = data.currencies[cDef.id]
                -- If the currency has a linked displayItem, show item bag count instead of currency quantity.
                -- e.g. Spark of Fortune accumulates as total earned; the spendable Spark of Radiance is an item.
                if cDef.displayItem then
                    c.val = C_Item.GetItemCount(cDef.displayItem, false) or 0
                else
                    c.val = info.quantity
                end
                c.earned = info.quantityEarnedThisWeek
                c.max = info.maxWeeklyQuantity
                c.maxQuantity = info.maxQuantity
                c.totalEarned = info.totalEarned
                c.useTotalEarned = info.useTotalEarnedForMaxQty

                if info.maxQuantity and info.maxQuantity > 0 then
                    local currentGlobalMax = SfuiDB.currencyCaps and SfuiDB.currencyCaps[cDef.id] or 0
                    if info.maxQuantity > currentGlobalMax then
                        SfuiDB.currencyCaps[cDef.id] = info.maxQuantity
                    end
                end
            end
        end
    end

    for _, currencyDef in ipairs(CURRENCIES) do
        if currencyDef.isGroup then
            for _, itemDef in ipairs(currencyDef.items) do
                SyncCurrency(itemDef)
            end
        else
            SyncCurrency(currencyDef)
        end
    end

    -- Quests tracking (Midnight expansion)
    data.quests = data.quests or {}
    local q = data.quests

    -- Store Quest Details
    -- Matches WeeklyRewards Progress.Init() logic:
    -- For pool-choice quests (e.g. Legends, Runestones):
    --   - completion = IsQuestFlaggedCompleted on POOL sub-quest IDs (these reset weekly)
    --   - active/in-progress = IsOnQuest on pool sub-quest IDs
    --   - The main wrapper quest ID (e.g. 89268) is NEVER checked with IsQuestFlaggedCompleted
    --     because wrapper quests often persist across resets permanently.
    -- For simple weekly quests (no pool): IsQuestFlaggedCompleted on the quest itself is reliable.
    -- skipFlagCheck: When true, do NOT use IsQuestFlaggedCompleted for pool quests.
    --   Use this for warband quests where the flag is account-wide but rewards
    --   are per-character. Completion is tracked locally via QUEST_TURNED_IN.
    local function GetQuestStatus(questID, pool, skipFlagCheck)
        if not questID then return { completed = false, progress = 0, active = false } end
        local progress = 0
        local progressText = nil
        local isActive = false
        local isCompleted = false

        if pool then
            -- Pool-choice weekly: check pool sub-quest IDs only (not the main wrapper quest).
            for _, pID in ipairs(pool) do
                if not skipFlagCheck and C_QuestLog.IsQuestFlaggedCompleted(pID) then
                    -- Pool sub-quest flagged completed this week → entire quest is done.
                    isCompleted = true
                    break
                elseif C_QuestLog.IsOnQuest(pID) then
                    -- Picked sub-quest is currently in the log → in progress.
                    isActive = true
                    local pProgress = C_TaskQuest.GetQuestProgressBarInfo(pID)
                    if pProgress then progress = pProgress end
                    local pobjs = C_QuestLog.GetQuestObjectives(pID)
                    if pobjs and #pobjs > 0 then
                        local done, total = 0, #pobjs
                        for _, obj in ipairs(pobjs) do
                            if obj.finished then done = done + 1 end
                        end
                        progressText = string.format("%d/%d", done, total)
                    end
                    break
                end
            end
            -- Also check if the main wrapper is in the log but no sub-quest picked yet.
            if not isActive and not isCompleted and C_QuestLog.IsOnQuest(questID) then
                isActive = true
            end
        else
            -- Simple weekly quest: the quest ID itself resets properly each week.
            isCompleted = C_QuestLog.IsQuestFlaggedCompleted(questID)

            if not isCompleted then
                if C_TaskQuest.GetQuestProgressBarInfo(questID) then
                    progress = C_TaskQuest.GetQuestProgressBarInfo(questID) or 0
                    isActive = true
                end

                local numLeaderBoards = GetNumQuestLeaderBoards(questID)
                if numLeaderBoards > 0 then
                    isActive = true
                    local finishedCount = 0
                    for i = 1, numLeaderBoards do
                        local _, _, finished = GetQuestLogLeaderBoard(i, questID)
                        if finished then finishedCount = finishedCount + 1 end
                    end
                    progressText = string.format("%d/%d", finishedCount, numLeaderBoards)
                end
            end
        end

        return { completed = isCompleted, progress = progress, progressText = progressText, active = isActive }
    end

    -- Abundance
    q.abundance = GetQuestStatus(89507)

    -- Legends (warband quest: IsQuestFlaggedCompleted is account-wide,
    -- but rewards are per-character — track completion via QUEST_TURNED_IN)
    local prevLegendsCompleted = q.legends and q.legends.completed
    q.legends = GetQuestStatus(89268, LEGENDS_POOL, true)
    if prevLegendsCompleted and not q.legends.completed then
        q.legends.completed = true
    end

    -- Runestones
    local runestonesPool = { 90573, 90574, 90575, 90576 }
    q.runestones = GetQuestStatus(91966, runestonesPool)

    -- Stormarion
    q.stormarion = GetQuestStatus(90962)

    -- Trovehunter's Bounty
    q.bounty = GetQuestStatus(86371)

    -- Timewalking Raid (one active per TW event week: Classic, TBC, WotLK, Cata/Firelands)
    local twRaidQuests = { 82817, 47523, 50316, 57637 }
    q.twRaid = { completed = false, progress = 0, active = false }
    for _, qID in ipairs(twRaidQuests) do
        local s = GetQuestStatus(qID)
        if s.completed or s.active then
            q.twRaid = s
            break
        end
    end

    -- Gilded Stash: Tier 11 Delve weekly cap (0-4), tracked via UI Widget 7591.
    -- Widget only populates near Silvermoon City / Delve hub; alts not yet visited show 0/4.
    q.gildedStash = q.gildedStash or { done = 0, total = 4, completed = false, active = false }
    
    local stashWidget = C_UIWidgetManager and C_UIWidgetManager.GetSpellDisplayVisualizationInfo(7591)
    if stashWidget and stashWidget.spellInfo and stashWidget.spellInfo.tooltip then
        local _, fulfilled = stashWidget.spellInfo.tooltip:match("COLOR:([^%d]*(%d)/4)")
        local n = tonumber(fulfilled)
        if n then
            q.gildedStash.done      = n
            q.gildedStash.active    = n > 0
            q.gildedStash.completed = n >= 4
        end
    end

    q.lastUpdate = GetServerTime()

    -- Prey tracking (Midnight expansion)
    data.prey = data.prey or {}
    local p = data.prey

    -- Season 1 Progress (ID 2764 from HomeworkTracker)
    local progInfo = C_MajorFactions.GetMajorFactionData(cfg.expansion and cfg.expansion.preyFactionID or 2764)
    if progInfo then
        p.rank = progInfo.renownLevel
        if progInfo.renownLevelThreshold and progInfo.renownLevelThreshold > 0 then
            p.rankProgress = math.floor((progInfo.renownReputationEarned or 0) / progInfo.renownLevelThreshold * 100)
        else
            p.rankProgress = 0
        end
    end

    -- Weekly Hunts (x/4) using specific completion quest IDs for Midnight Prey
    local huntNormal = {
        91098, 91099, 91096, 91104, 91105, 91106, 91107, 91108, 91109, 91110,
        91111, 91112, 91113, 91114, 91115, 91116, 91117, 91118, 91119, 91120,
        91121, 91122, 91123, 91124, 91095, 91097, 91100, 91101, 91102, 91103
    }
    local huntHard = {
        91210, 91212, 91214, 91216, 91218, 91220, 91222, 91224, 91226, 91228,
        91230, 91232, 91234, 91236, 91238, 91240, 91242, 91243, 91244, 91245,
        91246, 91247, 91248, 91249, 91250, 91251, 91252, 91253, 91254, 91255
    }
    local huntMythic = {
        91211, 91213, 91215, 91217, 91219, 91221, 91223, 91225, 91227, 91229,
        91231, 91233, 91235, 91237, 91239, 91241, 91256, 91257, 91258, 91259,
        91260, 91261, 91262, 91263, 91264, 91265, 91266, 91267, 91268, 91269
    }

    p.normal = 0
    p.hard = 0
    p.mythic = 0
    for _, qID in ipairs(huntNormal) do
        if C_QuestLog.IsQuestFlaggedCompleted(qID) then p.normal = p.normal + 1 end
    end
    for _, qID in ipairs(huntHard) do
        if C_QuestLog.IsQuestFlaggedCompleted(qID) then p.hard = p.hard + 1 end
    end
    for _, qID in ipairs(huntMythic) do
        if C_QuestLog.IsQuestFlaggedCompleted(qID) then p.mythic = p.mythic + 1 end
    end
    p.weekly = p.normal + p.hard + p.mythic

    -- Active Hunt Quests
    p.isQuestActive = false
    if C_QuestLog.GetActivePreyQuest then
        local questID = C_QuestLog.GetActivePreyQuest()
        if questID then
            p.title = C_QuestLog.GetTitleForQuestID(questID)
            p.activeHuntProgress = C_TaskQuest.GetQuestProgressBarInfo(questID) or 0
            p.isQuestActive = true
        end
    end

    p.lastUpdate = GetServerTime()

    -- Professions Knowledge Points
    data.profKP = data.profKP or {}
    ReleaseTableRecursive(data.profKP)
    data.profKP = AcquireTable()
    data.profKP.isDynamic = nil -- Remove pollution for storage
    local prof1, prof2 = GetProfessions()
    local profsToCheck = {}
    if prof1 then table.insert(profsToCheck, prof1) end
    if prof2 then table.insert(profsToCheck, prof2) end

    for _, pIndex in ipairs(profsToCheck) do
        local name, icon, skillLevel, _, _, _, skillLine = GetProfessionInfo(pIndex)
        local tracking = PROF_KP_SOURCES[skillLine]

        local pData = data.profKP[skillLine]
        if not pData then
            pData = AcquireTable()
            pData.isDynamic = nil
        end
        pData.name = name
        pData.icon = icon
        pData.skill = skillLevel
        pData.done = 0
        pData.total = 0
        pData.catchUp = 0
        if not pData.details then
            pData.details = AcquireTable()
            pData.details.isDynamic = nil
        end
        local d = pData.details
        d.treatise = false
        d.quest = false
        d.treasures = 0
        d.treasuresMax = 0

        -- Only track KP for characters in the Midnight expansion (Level 81+)
        if tracking and level >= 80 then
            d.treasuresMax = #tracking.treasures

            pData.total = pData.total + 1
            for _, qid in ipairs(tracking.treatise) do
                if C_QuestLog.IsQuestFlaggedCompleted(qid) then
                    pData.done = pData.done + 1
                    pData.details.treatise = true
                    break
                end
            end

            pData.total = pData.total + 1
            for _, qid in ipairs(tracking.quest) do
                if C_QuestLog.IsQuestFlaggedCompleted(qid) then
                    pData.done = pData.done + 1
                    pData.details.quest = true
                    break
                end
            end

            pData.total = pData.total + #tracking.treasures
            for _, tList in ipairs(tracking.treasures) do
                for _, qid in ipairs(tList) do
                    if C_QuestLog.IsQuestFlaggedCompleted(qid) then
                        pData.done = pData.done + 1
                        pData.details.treasures = pData.details.treasures + 1
                        break
                    end
                end
            end


            -- Catchup tracking (Midnight Only)
            if tracking.catchup then
                local currencyInfo = C_CurrencyInfo.GetCurrencyInfo(tracking.catchup)
                if currencyInfo and currencyInfo.maxQuantity and currencyInfo.quantity then
                    local remaining = currencyInfo.maxQuantity - currencyInfo.quantity
                    if remaining > 0 then
                        pData.catchUp = pData.catchUp + remaining
                    end
                end
            end
        end
        data.profKP[skillLine] = pData
    end

    if frame and frame:IsVisible() then
        sfui.alts.UpdateUI(true)
    end
end

-- Confirmation Dialog for Removing Characters
StaticPopupDialogs["SFUI_ALTS_REMOVE_CHARACTER"] = {
    text =
    "Are you sure you want to remove |cff9966ff%s|r from the Alts list? This will delete all saved data for this character.",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if SfuiDB.alts and data.guid then
            SfuiDB.alts[data.guid] = nil
            sfui.alts.UpdateUI()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- UI Implementation
local frame = nil

function sfui.alts.CreateFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "SfuiAltsFrame", UIParent, "BackdropTemplate")
    table.insert(UISpecialFrames, "SfuiAltsFrame")
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(cfg.width, cfg.height)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnHide", function() CloseDropDownMenus() end)

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(unpack(cfg.backdropColor))
    frame:SetBackdropBorderColor(unpack(cfg.borderColor))

    local CreateFlatButton = sfui.common.create_flat_button

    local close = CreateFlatButton(frame, "X", 24, 24)
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function() frame:Hide() end)

    -- Sort Dropdown
    local sortOptions = {
        { text = "Name (A-Z)", value = "name" },
        { text = "Item Level", value = "ilvl" },
        { text = "M+ Rating",  value = "rating" },
    }
    local sortDropdown = sfui.common.create_dropdown(frame, 24, sortOptions, function(val)
        SfuiDB.altsSort = val
        sfui.alts.UpdateUI()
    end, SfuiDB.altsSort or "name", "≣")
    sortDropdown:SetPoint("TOPRIGHT", close, "TOPLEFT", -5, 0)

    -- Character Manager Dropdown
    local function populateManagerOptions()
        local options = {}
        for guid, data in pairs(SfuiDB.alts) do
            table.insert(options, {
                guid = guid,
                data = data,
                keepOpen = true,
                onRender = function(parent, opt)
                    local name = opt.data.name or "Unknown"
                    local classColor = RAID_CLASS_COLORS[opt.data.class] or NORMAL_FONT_COLOR

                    local t = parent.textString
                    t:SetText(string.format("|c%s%s|r", classColor.colorStr, name))

                    -- Remove button [X]
                    parent.xBtn = parent.xBtn or sfui.common.create_flat_button(parent, "X", 18, 16)
                    local xBtn = parent.xBtn
                    xBtn:Show()
                    xBtn:SetPoint("RIGHT", -5, 0)
                    xBtn:SetScript("OnClick", function()
                        StaticPopup_Show("SFUI_ALTS_REMOVE_CHARACTER", name, nil, { guid = opt.guid })
                    end)

                    -- Hide button [H]
                    parent.hBtn = parent.hBtn or sfui.common.create_flat_button(parent, "", 18, 16)
                    local hBtn = parent.hBtn
                    hBtn:Show()
                    local hStatus = opt.data.isHidden and "|cff00ff00H|r" or "|cffccccccH|r"
                    hBtn:SetText(hStatus)
                    hBtn:SetPoint("RIGHT", xBtn, "LEFT", -2, 0)
                    hBtn:SetScript("OnClick", function()
                        opt.data.isHidden = not opt.data.isHidden
                        sfui.alts.UpdateUI()
                        hBtn:SetText(opt.data.isHidden and "|cff00ff00H|r" or "|cffccccccH|r")
                    end)
                end
            })
        end
        return options
    end

    local managerDropdown = sfui.common.create_dropdown(frame, 24, populateManagerOptions, nil, nil, "=", 200)
    managerDropdown:SetPoint("RIGHT", sortDropdown, "LEFT", -5, 0)

    -- Section Manager Dropdown
    local function populateSectionsOptions()
        local options = {}
        for _, cat in ipairs(CATEGORIES) do
            if cat.type == "header" and cat.name ~= "GENERAL" then
                table.insert(options, {
                    catName = cat.name,
                    label = cat.label,
                    keepOpen = true,
                    onRender = function(parent, opt)
                        local t = parent.textString
                        t:SetText(opt.label)

                        if parent.xBtn then parent.xBtn:Hide() end

                        local isHidden = SfuiDB.altsHiddenSections[opt.catName]
                        local hStatus = isHidden and "|cffff0000H|r" or "|cff00ff00V|r"
                        parent.hBtn = parent.hBtn or sfui.common.create_flat_button(parent, "", 18, 16)
                        local hBtn = parent.hBtn
                        hBtn:Show()
                        hBtn:SetText(hStatus)
                        hBtn:SetPoint("RIGHT", -5, 0)
                        hBtn:SetScript("OnClick", function()
                            SfuiDB.altsHiddenSections[opt.catName] = not SfuiDB.altsHiddenSections[opt.catName]
                            sfui.alts.UpdateUI()
                            hBtn:SetText(SfuiDB.altsHiddenSections[opt.catName] and "|cffff0000H|r" or
                                "|cff00ff00V|r")
                        end)
                    end
                })
            end
        end

        -- Add M0 Toggle manually
        table.insert(options, {
            label = "M0 Dungeons",
            keepOpen = true,
            onRender = function(parent, opt)
                local t = parent.textString
                t:SetText(opt.label)
                if parent.xBtn then parent.xBtn:Hide() end

                local isHidden = SfuiDB.showM0Dungeons == false
                local hStatus = isHidden and "|cffff0000H|r" or "|cff00ff00V|r"
                parent.hBtn = parent.hBtn or sfui.common.create_flat_button(parent, "", 18, 16)
                local hBtn = parent.hBtn
                hBtn:Show()
                hBtn:SetText(hStatus)
                hBtn:SetPoint("RIGHT", -5, 0)
                hBtn:SetScript("OnClick", function()
                    SfuiDB.showM0Dungeons = not (SfuiDB.showM0Dungeons ~= false)
                    sfui.alts.RefreshDynamicCategories(true)
                    sfui.alts.UpdateUI()
                    hBtn:SetText(SfuiDB.showM0Dungeons == false and "|cffff0000H|r" or "|cff00ff00V|r")
                end)
            end
        })

        return options
    end

    local sectionsDropdown = sfui.common.create_dropdown(frame, 24, populateSectionsOptions, nil, nil, "⚙", 150)
    sectionsDropdown:SetPoint("RIGHT", managerDropdown, "LEFT", -5, 0)

    -- Sidebar for row labels
    local sidebar = CreateFrame("Frame", nil, frame)
    sidebar:SetPoint("TOPLEFT", 10, -35)
    sidebar:SetPoint("BOTTOMLEFT", 10, 10)
    sidebar:SetWidth(140)
    frame.sidebar = sidebar



    frame.content = CreateFrame("Frame", nil, frame)
    frame.content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 10, 0)
    frame.content:SetPoint("BOTTOMRIGHT", -10, 0)

    frame:Hide()
    return frame
end

local PROF_SHORT_NAMES = {
    ["Blacksmithing"] = "BS",
    ["Alchemy"] = "Alc",
    ["Enchanting"] = "Enc",
    ["Engineering"] = "Eng",
    ["Herbalism"] = "Herb",
    ["Inscription"] = "Insc",
    ["Jewelcrafting"] = "JC",
    ["Leatherworking"] = "LW",
    ["Mining"] = "Min",
    ["Skinning"] = "Skin",
    ["Tailoring"] = "Tail",
}

-- Optimization: Static tables and sort function to avoid garbage collection
local visibleCats = {}
local altsList = {}

local function SortAlts(a, b)
    local sortMethod = SfuiDB.altsSort or "name"
    if sortMethod == "ilvl" then
        local aLevel, bLevel = a.data.level or 0, b.data.level or 0
        local aILvl, bILvl = a.data.iLvl or 0, b.data.iLvl or 0
        if aLevel ~= bLevel then return aLevel > bLevel end
        if aILvl ~= bILvl then return aILvl > bILvl end
    elseif sortMethod == "rating" then
        local aRating, bRating = a.data.rating or 0, b.data.rating or 0
        if aRating ~= bRating then return aRating > bRating end
        
        -- Tie-breaker: Level > iLvl
        local aLevel, bLevel = a.data.level or 0, b.data.level or 0
        local aILvl, bILvl = a.data.iLvl or 0, b.data.iLvl or 0
        if aLevel ~= bLevel then return aLevel > bLevel end
        if aILvl ~= bILvl then return aILvl > bILvl end
    end
    return (a.data.name or "") < (b.data.name or "")
end

local updateRequested = false
function sfui.alts.UpdateUI(force)
    if not frame or (not force and not frame:IsVisible()) then return end

    if not force then
        if updateRequested then return end
        updateRequested = true
        C_Timer.After(0, function()
            updateRequested = false
            -- Re-check visibility: frame may have hidden between schedule and fire
            if frame and frame:IsVisible() then
                sfui.alts.UpdateUI(true)
            end
        end)
        return
    end


    wipe(visibleCats)
    local currentHeader = nil
    for _, cat in ipairs(CATEGORIES) do
        if cat.type == "header" then
            if not SfuiDB.altsHiddenSections[cat.name] then
                currentHeader = cat.name
                table.insert(visibleCats, cat)
            else
                currentHeader = nil
            end
        else
            if currentHeader and not SfuiDB.altsCollapsed[currentHeader] then
                table.insert(visibleCats, cat)
            end
        end
    end

    -- Update sidebar
    if frame.sidebar then
        -- OPTIMIZATION: Avoid { GetChildren() } and iterate backwards to safely orphan children
        for i = frame.sidebar:GetNumChildren(), 1, -1 do
            local cell = select(i, frame.sidebar:GetChildren())
            if cell then ReleaseCell(cell) end
        end
        local visY = 0
        for _, cat in ipairs(visibleCats) do
            local row = AcquireCell(frame.sidebar)
            row:SetSize(140, cfg.rowHeight)
            row:SetPoint("TOPLEFT", 0, -visY)

            local text = row.text
            text:Show()
            text:ClearAllPoints()
            text:SetPoint("LEFT", 5, 0)

            if cat.type == "header" then
                text:SetFontObject("GameFontNormal")
                text:SetTextColor(unpack(sfui.config.appearance.highlightColor)) -- Purple
                text:SetText(cat.label)

                row:EnableMouse(true)
                row:SetScript("OnMouseUp", function()
                    SfuiDB.altsCollapsed[cat.name] = not SfuiDB.altsCollapsed[cat.name]
                    sfui.alts.UpdateUI(true)
                end)
            else
                text:SetFontObject("GameFontHighlightSmall")
                text:SetTextColor(unpack(sfui.config.colors.white))
                text:SetText(cat.label)
                row:EnableMouse(false)
                row:SetScript("OnMouseUp", nil)
            end
            visY = visY + cfg.rowHeight
        end

        -- Adjust frame height dynamically based on visible categories
        frame:SetHeight(visY + 45) -- 35 for top offset + 10 for bottom offset
    end

    -- Release existing content to pools
    if not frame.content then return end
    -- OPTIMIZATION: Avoid temporary tables and iterate backwards to safely orphan children
    for i = frame.content:GetNumChildren(), 1, -1 do
        local col = select(i, frame.content:GetChildren())
        if col then
            for j = col:GetNumChildren(), 1, -1 do
                local cell = select(j, col:GetChildren())
                if cell then ReleaseCell(cell) end
            end
            ReleaseColumn(col)
        end
    end

    wipe(altsList)
    for guid, data in pairs(SfuiDB.alts) do
        if not data.isHidden then
            table.insert(altsList, { guid = guid, data = data })
        end
    end

    table.sort(altsList, SortAlts)

    local xOffset = 0
    for i, alt in ipairs(altsList) do
        local col = AcquireColumn(frame.content)
        col:SetSize(cfg.columnWidth, #visibleCats * cfg.rowHeight)
        col:SetPoint("TOPLEFT", xOffset, 0)

        local classColor = RAID_CLASS_COLORS[alt.data.class] or NORMAL_FONT_COLOR

        local y = 0
        for _, cat in ipairs(visibleCats) do
            local cell = AcquireCell(col)
            cell:SetSize(cfg.columnWidth, cfg.rowHeight)
            cell:SetPoint("TOPLEFT", 0, -y)

            local text = cell.text
            text:ClearAllPoints()
            text:SetPoint("CENTER")
            text:Show()

            if cat.type == "header" then
                if cat.name == "GENERAL" then
                    text:SetFontObject("GameFontNormal")
                    text:SetText(alt.data.name)
                    text:SetTextColor(classColor.r, classColor.g, classColor.b)

                    if cell.del then cell.del:Hide() end
                    cell:SetScript("OnEnter", nil)
                    cell:SetScript("OnLeave", nil)
                elseif cat.name == "VAULT_HEADER" and alt.data.vault and alt.data.vault.hasReward then
                    -- Show green "Loot!" inline text instead of golden glow on vault boxes
                    text:Show()
                    text:SetFontObject("GameFontNormal")
                    text:SetText("Loot!")
                    text:SetTextColor(0.2, 1.0, 0.2)
                    -- Still draw divider
                    local line = cell.line or cell:CreateTexture(nil, "BACKGROUND")
                    cell.line = line
                    line:Show()
                    line:SetHeight(1)
                    line:SetPoint("LEFT", 5, -5)
                    line:SetPoint("RIGHT", -5, -5)
                    line:SetColorTexture(0.2, 0.2, 0.2, 0.5)
                else
                    text:Hide()
                    -- Divider underline
                    local line = cell.line or cell:CreateTexture(nil, "BACKGROUND")
                    cell.line = line
                    line:Show()
                    line:SetHeight(1)
                    line:SetPoint("LEFT", 5, -5)
                    line:SetPoint("RIGHT", -5, -5)
                    line:SetColorTexture(0.2, 0.2, 0.2, 0.5)
                end
            elseif cat.type == "stat" then
                local val = alt.data[cat.key] or 0
                if cat.key == "iLvl" and (alt.data.level or 0) < 90 then
                    text:SetText(alt.data.level or "-")
                    text:SetTextColor(unpack(sfui.config.colors.white)) -- White for level
                else
                    text:SetText(cat.format and string.format(cat.format, val) or val)
                    if cat.key == "rating" and val > 0 then
                        local color = C_ChallengeMode.GetDungeonScoreRarityColor(val)
                        if color then
                            text:SetTextColor(color.r, color.g, color.b)
                        end
                    end
                end
            elseif cat.type == "keystone" then
                if alt.data.keystone then
                    local name = sfui.common.get_short_map_name(alt.data.keystone.mapID)
                    if name then
                        text:SetText(string.format("%s - %d", name, alt.data.keystone.level))

                        local mapID = alt.data.keystone.mapID
                        cell:SetScript("OnEnter", function(self)
                            local fullName = C_ChallengeMode.GetMapUIInfo(mapID)
                            if fullName then
                                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                                GameTooltip:SetText(fullName)
                                GameTooltip:Show()
                            end
                        end)
                        cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    else
                        text:SetText(string.format("%d", alt.data.keystone.level))
                    end
                    local color = C_ChallengeMode.GetKeystoneLevelRarityColor(alt.data.keystone.level)
                    if alt.data.keystone.level >= 12 then
                        text:SetTextColor(1, 0.5, 0) -- Orange for 12+
                    elseif color then
                        text:SetTextColor(color.r, color.g, color.b)
                    else
                        text:SetTextColor(unpack(sfui.config.colors.white))
                    end
                else
                    text:SetText("-")
                    text:SetTextColor(0.5, 0.5, 0.5)
                end
            elseif cat.type == "dungeon" then
                local best = alt.data.dungeons and alt.data.dungeons[cat.mapID]
                if best and best.level > 0 then
                    local timed = best.timed or 0
                    local overall = best.level
                    local isDepleted = overall > timed

                    if isDepleted then
                        -- Best run was depleted: show level in grey with † marker
                        text:SetText(overall .. "†")
                        text:SetTextColor(0.5, 0.5, 0.5)
                    else
                        -- Best run was timed: show with rarity color
                        text:SetText(tostring(timed))
                        local color = C_ChallengeMode.GetKeystoneLevelRarityColor(timed)
                        if timed >= 12 then
                            text:SetTextColor(1, 0.5, 0) -- Orange for 12+
                        elseif color then
                            text:SetTextColor(color.r, color.g, color.b)
                        else
                            text:SetTextColor(unpack(sfui.config.colors.white))
                        end
                    end

                    -- Tooltip with timed vs overall breakdown
                    local mapID = cat.mapID
                    cell:SetScript("OnEnter", function(self)
                        local fullName = C_ChallengeMode.GetMapUIInfo(mapID)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(fullName or "Dungeon")
                        if timed > 0 then
                            local timedColor = C_ChallengeMode.GetKeystoneLevelRarityColor(timed)
                            local tr, tg, tb = 1, 1, 1
                            if timed >= 12 then
                                tr, tg, tb = 1, 0.5, 0
                            elseif timedColor then
                                tr, tg, tb = timedColor.r, timedColor.g, timedColor.b
                            end
                            GameTooltip:AddDoubleLine("Timed:", "+" .. timed, 1, 1, 1, tr, tg, tb)
                        end
                        if isDepleted then
                            GameTooltip:AddDoubleLine("Best (depleted):", "+" .. overall, 1, 1, 1, 0.5, 0.5, 0.5)
                        end
                        GameTooltip:Show()
                    end)
                    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
                else
                    text:SetText("-")
                    text:SetTextColor(0.5, 0.5, 0.5)
                    cell:SetScript("OnEnter", nil)
                    cell:SetScript("OnLeave", nil)
                end
            elseif cat.type == "currency" or cat.type == "currency_group" then
                local isGroup = (cat.type == "currency_group")
                local items = isGroup and cat.items or { cat }
                
                local displayText = ""
                local tooltipLines = {}
                local anyCapped = false
                
                for _, itemConfig in ipairs(items) do
                    local cData = alt.data.currencies[itemConfig.id]
                    -- Check weekly cap
                    local isCapped = false
                    local displayMaxQuantity = cData and type(cData) == "table" and cData.maxQuantity or 0
                    if SfuiDB.currencyCaps and SfuiDB.currencyCaps[itemConfig.id] and SfuiDB.currencyCaps[itemConfig.id] > displayMaxQuantity then
                        displayMaxQuantity = SfuiDB.currencyCaps[itemConfig.id]
                    end

                    if cData and type(cData) == "table" then
                        if cData.max and cData.max > 0 and cData.earned and cData.earned >= cData.max then
                            isCapped = true
                        elseif displayMaxQuantity > 0 then
                            if cData.useTotalEarned and cData.totalEarned and cData.totalEarned >= displayMaxQuantity then
                                isCapped = true
                            elseif not cData.useTotalEarned and cData.val and cData.val >= displayMaxQuantity then
                                isCapped = true
                            end
                        end
                    end
                    
                    local val = cData and (type(cData) == "table" and cData.val or cData) or 0
                    local displayVal
                    if val >= 1000 then
                        displayVal = string.format("%.1fk", val / 1000)
                    else
                        displayVal = tostring(val)
                    end
                    
                    if displayText ~= "" then
                        displayText = displayText .. "  "
                    end
                    
                    if isCapped then
                        local r, g, b = unpack(sfui.config.appearance.errorColor)
                        local colorCode = string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
                        displayText = displayText .. string.format("|T%d:12:12:0:0|t %s%s|r", itemConfig.icon, colorCode, displayVal)
                    else
                        displayText = displayText .. string.format("|T%d:12:12:0:0|t %s", itemConfig.icon, displayVal)
                    end
                    
                    table.insert(tooltipLines, {
                        itemConfig = itemConfig,
                        cData = cData,
                        isCapped = isCapped,
                        displayMaxQuantity = displayMaxQuantity
                    })
                end

                text:SetText(displayText)
                text:SetTextColor(unpack(sfui.config.colors.white)) -- Base color is white, overrides are embedded

                -- Add tooltip for currency
                cell:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if not isGroup then
                        local tLine = tooltipLines[1]
                        if tLine.itemConfig.isItem then
                            GameTooltip:SetItemByID(tLine.itemConfig.id)
                        else
                            GameTooltip:SetCurrencyByID(tLine.itemConfig.id)
                            if tLine.cData and type(tLine.cData) == "table" then
                                GameTooltip:AddLine(" ")
                                if tLine.cData.max and tLine.cData.max > 0 then
                                    GameTooltip:AddDoubleLine("Weekly Earned:",
                                        string.format("%d / %d", tLine.cData.earned or 0, tLine.cData.max), 1, 1, 1, 1, 1, 1)
                                elseif tLine.displayMaxQuantity > 0 then
                                    local currentAmount = tLine.cData.useTotalEarned and tLine.cData.totalEarned or tLine.cData.val
                                    GameTooltip:AddDoubleLine("Season Earned:",
                                        string.format("%d / %d", currentAmount or 0, tLine.displayMaxQuantity), 1, 1, 1, 1, 1, 1)
                                end
                                if tLine.isCapped then
                                    GameTooltip:AddLine("Season/Weekly cap reached!", 1, 0, 0)
                                end
                            end
                        end
                        GameTooltip:Show()
                        return
                    end
                    
                    -- Group tooltip
                    GameTooltip:AddLine(cat.label, 1, 1, 1)
                    for _, tLine in ipairs(tooltipLines) do
                        local name
                        if tLine.itemConfig.isItem then
                            name = C_Item.GetItemInfo(tLine.itemConfig.id) or "Item"
                        else
                            local info = C_CurrencyInfo.GetCurrencyInfo(tLine.itemConfig.id)
                            name = info and info.name or "Currency"
                        end
                        
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine(string.format("|T%d:16:16:0:0|t %s", tLine.itemConfig.icon, name))
                        
                        if tLine.cData and type(tLine.cData) == "table" then
                            if tLine.cData.max and tLine.cData.max > 0 then
                                GameTooltip:AddDoubleLine("Weekly Earned:",
                                    string.format("%d / %d", tLine.cData.earned or 0, tLine.cData.max), 1, 1, 1, 1, 1, 1)
                            elseif tLine.displayMaxQuantity > 0 then
                                local currentAmount = tLine.cData.useTotalEarned and tLine.cData.totalEarned or tLine.cData.val
                                GameTooltip:AddDoubleLine("Season Earned:",
                                    string.format("%d / %d", currentAmount or 0, tLine.displayMaxQuantity), 1, 1, 1, 1, 1, 1)
                            else
                                local val = tLine.cData.val or 0
                                GameTooltip:AddDoubleLine("Total:", tostring(val), 1, 1, 1, 1, 1, 1)
                            end
                            if tLine.isCapped then
                                GameTooltip:AddLine("Season/Weekly cap reached!", 1, 0, 0)
                            end
                        else
                            local val = tLine.cData or 0
                            GameTooltip:AddDoubleLine("Total:", tostring(val), 1, 1, 1, 1, 1, 1)
                        end
                    end
                    GameTooltip:Show()
                end)
                cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
            elseif cat.type == "quests_grid" then
                local isMaxLevel = true
                if alt.data.level and _G.GetMaxPlayerLevel and alt.data.level < _G.GetMaxPlayerLevel() then
                    isMaxLevel = false
                end

                if not isMaxLevel then
                    text:Show()
                    text:SetText("-")
                    text:SetTextColor(0.4, 0.4, 0.4)
                    for bIdx = 1, 7 do
                        if cell["qRect" .. bIdx] then cell["qRect" .. bIdx]:Hide() end
                        if cell["qCount" .. bIdx] then cell["qCount" .. bIdx]:Hide() end
                    end
                    cell:SetScript("OnEnter", nil)
                    cell:SetScript("OnLeave", nil)
                else
                    -- Layout: [Abund][Legend][Runes][Storm] · [Bounty][TW Raid][Stash N/4]
                    text:Hide()
                    local q           = alt.data.quests

                -- Block definitions: core group (purple) then bonus group (amber)
                local BLOCKS      = {
                    -- Core Pinnacle weeklies
                    { key = "abundance",   label = "Abundance",  group = "core" },
                    { key = "legends",     label = "Legends",    group = "core" },
                    { key = "runestones",  label = "Runestones", group = "core" },
                    { key = "stormarion",  label = "Stormarion", group = "core" },
                    -- Bonus / event weeklies
                    { key = "bounty",      label = "Bounty",     group = "bonus" },
                    { key = "gildedStash", label = "Stash",      group = "bonus", isCount = true },
                    { key = "twRaid",      label = "TW Raid",    group = "bonus" },
                }
                -- Colours: completed / inProgress / available — per group
                local CORE_DONE   = { 0.40, 0.00, 1.00, 0.85 }  -- #6600ff vivid purple
                local CORE_PROG   = { 0.18, 0.00, 0.45, 0.85 }  -- dark purple
                local BONUS_DONE  = { 0.90, 0.52, 0.00, 0.85 }  -- #e68500 amber/gold
                local BONUS_PROG  = { 0.40, 0.22, 0.00, 0.85 }  -- dark amber
                local AVAIL_COLOR = { 0.06, 0.06, 0.07, 0.60 }  -- near-black

                local CORE_TEXT   = "|cffaa66ff"                -- light purple for tooltip
                local BONUS_TEXT  = "|cffffaa44"                -- light amber for tooltip

                local GAP         = 7                           -- px gap between group 1 and group 2
                local totalW      = cfg.columnWidth - 10
                local blockW      = (totalW - GAP) / 7

                for bIdx, block in ipairs(BLOCKS) do
                    local rect = cell["qRect" .. bIdx] or cell:CreateTexture(nil, "ARTWORK")
                    cell["qRect" .. bIdx] = rect
                    rect:Show()
                    rect:SetSize(blockW - 2, cfg.rowHeight - 12)

                    -- Offset: blocks 5-7 get extra GAP nudge
                    local xOff = (bIdx - 1) * blockW + 5 + (bIdx >= 5 and GAP or 0)
                    rect:SetPoint("LEFT", xOff, 0)

                    local status   = q and q[block.key]
                    local isDone   = status and status.completed
                    local isActive = status and (status.active or (status.progress and status.progress > 0))

                    if block.group == "core" then
                        if isDone then
                            rect:SetColorTexture(unpack(CORE_DONE))
                        elseif isActive then
                            rect:SetColorTexture(unpack(CORE_PROG))
                        else
                            rect:SetColorTexture(unpack(AVAIL_COLOR))
                        end
                    else -- bonus
                        if isDone then
                            rect:SetColorTexture(unpack(BONUS_DONE))
                        elseif isActive then
                            rect:SetColorTexture(unpack(BONUS_PROG))
                        else
                            rect:SetColorTexture(unpack(AVAIL_COLOR))
                        end
                    end

                    -- Stash: overlay N/4 text centred in block
                    if block.isCount then
                        local lbl = cell["qCount" .. bIdx]
                        if not lbl then
                            lbl = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                            cell["qCount" .. bIdx] = lbl
                        end
                        if isDone then
                            lbl:Hide()
                        else
                            lbl:ClearAllPoints()
                            lbl:SetPoint("CENTER", rect, "CENTER")
                            lbl:Show()
                            local done  = (status and status.done) or 0
                            local total = (status and status.total) or 4
                            lbl:SetText(done .. "/" .. total)
                            lbl:SetTextColor(unpack(sfui.config.colors.white))
                        end
                    else
                        local lbl = cell["qCount" .. bIdx]
                        if lbl then lbl:Hide() end
                    end
                end

                cell:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Weekly Quests")

                    -- Core group header
                    GameTooltip:AddLine("|cffaa66ffPinnacle Weeklies|r", 1, 1, 1)
                    for _, block in ipairs(BLOCKS) do
                        if block.group ~= "core" then break end
                        local status = q and q[block.key]
                        local color  = "|cff555555"
                        local valStr = "Not Started"
                        if status then
                            if status.completed then
                                color  = CORE_TEXT
                                valStr = "Completed"
                            elseif status.progressText then
                                color  = "|cff886699"
                                valStr = status.progressText
                            elseif status.progress and status.progress > 0 then
                                color  = "|cff886699"
                                valStr = status.progress .. "%"
                            elseif status.active then
                                color  = "|cff886699"
                                valStr = "In Progress"
                            end
                        end
                        GameTooltip:AddDoubleLine(block.label, color .. valStr .. "|r", 1, 1, 1, 1, 1, 1)
                    end

                    -- Bonus group header
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("|cffffaa44Bonus Weeklies|r", 1, 1, 1)
                    for _, block in ipairs(BLOCKS) do
                        if block.group == "bonus" then
                            local status = q and q[block.key]
                            local color  = "|cff555555"
                            local valStr = "Not Started"
                            if block.key == "twRaid" and not (status and (status.completed or status.active)) then
                                valStr = "No TW Event Active"
                            end
                            if status then
                                if status.completed then
                                    color  = BONUS_TEXT
                                    valStr = "Completed"
                                elseif block.isCount and status.done and status.done > 0 then
                                    color  = "|cffcc8833"
                                    valStr = string.format("%d / %d", status.done, status.total or 4)
                                elseif status.active or (status.progress and status.progress > 0) then
                                    color  = "|cffcc8833"
                                    valStr = "In Progress"
                                end
                            end
                            GameTooltip:AddDoubleLine(block.label, color .. valStr .. "|r", 1, 1, 1, 1, 1, 1)
                        end
                    end

                    if q and q.gildedStash and not q.gildedStash.active and not q.gildedStash.completed then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("|cff888888Stash updates near Silvermoon Delve hub|r")
                    end
                    GameTooltip:Show()
                end)
                cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
            elseif cat.type == "prey" then
                local isMaxLevel = true
                if alt.data.level and _G.GetMaxPlayerLevel and alt.data.level < _G.GetMaxPlayerLevel() then
                    isMaxLevel = false
                end

                if not isMaxLevel then
                    text:Show()
                    text:SetText("-")
                    text:SetTextColor(0.4, 0.4, 0.4)
                    cell:SetScript("OnEnter", nil)
                    cell:SetScript("OnLeave", nil)
                else
                    if alt.data.prey then
                        local p = alt.data.prey
                    local sColors = cfg.statusColors
                    local normal = p.normal or 0
                    local hard = p.hard or 0
                    local mythic = p.mythic or 0
                    text:SetText(string.format("%d/%d/%d", normal, hard, mythic))
                    -- Completed ONLY if a specific category is 4
                    local isCompleted = (p.normal and p.normal >= 4) or (p.hard and p.hard >= 4) or
                        (p.mythic and p.mythic >= 4)
                    if isCompleted then
                        text:SetTextColor(unpack(sColors and sColors.completed or { 0, 1, 1 }))
                    elseif p.weekly and p.weekly > 0 then
                        text:SetTextColor(unpack(sColors and sColors.inProgress or { 0, 0.2, 0.2 }))
                    else
                        text:SetTextColor(unpack(sColors and sColors.available or { 0, 0, 0 }))
                    end
                else
                    text:SetText("0 / 4")
                    text:SetTextColor(0.5, 0.5, 0.5)
                end

                cell:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Hunt Progress (Weekly)")
                    if alt.data.prey then
                        GameTooltip:AddDoubleLine("Progress:", string.format("%d / 4", alt.data.prey.weekly or 0), 1, 1,
                            1, 1,
                            1, 1)
                        if alt.data.prey.isQuestActive then
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine("Active: " .. (alt.data.prey.title or "Unknown"), 1, 0.82, 0)
                            GameTooltip:AddDoubleLine("Quest Progress:", (alt.data.prey.activeHuntProgress or 0) .. "%",
                                1, 1,
                                1, 1, 1, 1)
                        end
                        if alt.data.prey.rank then
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddDoubleLine("Renown Rank:", alt.data.prey.rank, 1, 1, 1, 1, 1, 1)
                            GameTooltip:AddDoubleLine("Rank Progress:", (alt.data.prey.rankProgress or 0) .. "%", 1, 1, 1,
                                1, 1,
                                1)
                        end
                    end
                    GameTooltip:Show()
                end)
                cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
            elseif cat.type == "prof_slot" then
                local pData
                local profs = {}
                if alt.data.profKP then
                    for skillLine, data in pairs(alt.data.profKP) do
                        if type(data) == "table" then
                            table.insert(profs, data)
                        end
                    end
                end
                table.sort(profs, function(a, b) return (a.name or "") < (b.name or "") end)
                pData = profs[cat.slot]

                if pData then
                    local shortName = PROF_SHORT_NAMES[pData.name] or pData.name

                    text:ClearAllPoints()
                    text:SetPoint("LEFT", 15, 0)
                    text:SetText(string.format("%s - %d", shortName, pData.skill or 0))
                    text:SetTextColor(unpack(sfui.config.colors.white))

                    local rightText = cell.rightText
                    if not rightText then
                        rightText = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                        cell.rightText = rightText
                    end
                    rightText:Show()
                    rightText:ClearAllPoints()
                    rightText:SetPoint("RIGHT", -15, 0)

                    if pData.total > 0 then
                        rightText:SetText(string.format("%d/%d", pData.done, pData.total))

                        local sColors = cfg.statusColors
                        if pData.done >= pData.total then
                            rightText:SetTextColor(unpack(sfui.config.colors.cyan)) -- Cyan
                        elseif pData.done > 0 then
                            local c = sColors and sColors.inProgress or { 0, 0.2, 0.2 }
                            rightText:SetTextColor(c[1], c[2], c[3])
                        else
                            rightText:SetTextColor(unpack(sfui.config.colors.white))
                        end
                    else
                        rightText:SetText("")
                    end

                    cell:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(pData.name .. " Knowledge")
                        GameTooltip:AddDoubleLine("Skill Level:", string.format("%d", pData.skill or 0), 1, 1, 1, 1, 1, 1)
                        if pData.catchUp and pData.catchUp > 0 then
                            GameTooltip:AddDoubleLine("Catch-up Available:", pData.catchUp, 1, 0.82, 0, 1, 0.82, 0)
                        end

                        if pData.total > 0 then
                            GameTooltip:AddLine("Weekly Progress", 1, 1, 1)
                            local tStr = pData.details.treatise and "|cff00ff00Done|r" or "|cffff0000Missing|r"
                            GameTooltip:AddDoubleLine("Treatise:", tStr, 1, 1, 1, 1, 1, 1)
                            local qStr = pData.details.quest and "|cff00ff00Done|r" or "|cffff0000Missing|r"
                            GameTooltip:AddDoubleLine("Weekly Quest/Patron:", qStr, 1, 1, 1, 1, 1, 1)
                            if pData.details.treasuresMax > 0 then
                                local gColor = pData.details.treasures >= pData.details.treasuresMax and "|cff00ff00" or
                                    "|cffff0000"
                                GameTooltip:AddDoubleLine("Treasures/Drops:",
                                    string.format("%s%d / %d|r", gColor, pData.details.treasures,
                                        pData.details.treasuresMax), 1, 1, 1, 1, 1, 1)
                            end
                        end
                        GameTooltip:Show()
                    end)
                    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
                else
                    text:SetText("-")
                    text:SetTextColor(0.5, 0.5, 0.5)
                end
            elseif cat.type == "vault_row" then
                text:Hide()
                local group = cat.group
                local squareSize = (cfg.columnWidth - 10) / 3

                local GetVaultColor = function(g, l)
                    if g == "raid" then
                        if l == 16 then return { 1.0, 0.5, 0.0, 0.8 } end
                        if l == 15 then return { 0.64, 0.21, 0.93, 0.8 } end
                        if l == 14 then return { 0.0, 0.44, 0.87, 0.8 } end
                        return { 0.12, 1.0, 0.0, 0.8 }
                    elseif g == "world" then
                        if l >= 8 then return { 1.0, 0.5, 0.0, 0.8 } end
                        if l >= 6 then return { 0.64, 0.21, 0.93, 0.8 } end
                        if l >= 4 then return { 0.0, 0.44, 0.87, 0.8 } end
                        return { 0.12, 1.0, 0.0, 0.8 }
                    else
                        if l >= 10 then return { 1.0, 0.5, 0.0, 0.8 } end
                        if l >= 7 then return { 0.64, 0.21, 0.93, 0.8 } end
                        if l >= 4 then return { 0.0, 0.44, 0.87, 0.8 } end
                        return { 0.12, 1.0, 0.0, 0.8 }
                    end
                end

                local GetDifficultyName = function(l)
                    if l == 17 then return "LFR" end
                    if l == 14 then return "Normal" end
                    if l == 15 then return "Heroic" end
                    if l == 16 then return "Mythic" end
                    return tostring(l)
                end

                for slotIdx = 1, 3 do
                    local rect = cell["rect" .. slotIdx] or cell:CreateTexture(nil, "ARTWORK")
                    cell["rect" .. slotIdx] = rect
                    rect:Show()
                    rect:SetSize(squareSize - 4, cfg.rowHeight - 12)
                    rect:SetPoint("LEFT", (slotIdx - 1) * squareSize + 5, 0)

                    local vData = alt.data.vault and alt.data.vault[group] and alt.data.vault[group][slotIdx]
                    if vData and vData.progress >= vData.threshold and vData.threshold > 0 then
                        rect:SetColorTexture(unpack(GetVaultColor(group, vData.level)))
                    else
                        local sColors = cfg.statusColors
                        rect:SetColorTexture(unpack(sColors and sColors.available or { 0, 0, 0, 0.5 }))
                    end

                    -- Hide any stale glow texture from previous renders
                    if cell["vaultGlow" .. slotIdx] then
                        cell["vaultGlow" .. slotIdx]:Hide()
                    end
                end

                cell:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Great Vault: " .. cat.label)
                    local vGroup = alt.data.vault and alt.data.vault[group]

                    if alt.data.vault and alt.data.vault.hasReward then
                        GameTooltip:AddLine("✨ Reward Ready to Claim!", 1, 0.82, 0)
                        GameTooltip:AddLine(" ")
                    end

                    for idx = 1, 3 do
                        local v = vGroup and vGroup[idx]
                        if v and v.threshold > 0 then
                            local status = v.progress >= v.threshold and "|cff00ff00Unlocked|r" or
                                string.format("%d/%d", v.progress, v.threshold)
                            local levelStr = ""
                            if v.level > 0 then
                                levelStr = group == "raid" and string.format(" (%s)", GetDifficultyName(v.level)) or
                                string.format(" (Level: %d)", v.level)
                            end
                            GameTooltip:AddDoubleLine("Slot " .. idx .. ":", status .. levelStr, 1, 1, 1, 1, 1, 1)
                        end
                    end
                    GameTooltip:Show()
                end)
                cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
            elseif cat.type == "m0_grid" then
                text:Hide()
                local m0Data = alt.data.m0
                local instanceCache = GetEJInstanceCache()
                local ejInstances = {}
                for name, id in pairs(instanceCache) do
                    table.insert(ejInstances, { id = id, name = name })
                end
                table.sort(ejInstances, function(a, b) return a.id < b.id end)

                local numDungeons = #ejInstances > 0 and #ejInstances or 8
                local squareSize = (cfg.columnWidth - 10) / numDungeons

                for bIdx, inst in ipairs(ejInstances) do
                    local rect = cell["m0Rect" .. bIdx] or cell:CreateTexture(nil, "ARTWORK")
                    cell["m0Rect" .. bIdx] = rect
                    rect:Show()
                    rect:SetSize(squareSize - 2, cfg.rowHeight - 12)
                    rect:SetPoint("LEFT", (bIdx - 1) * squareSize + 5, 0)

                    local sColors = cfg.statusColors
                    if m0Data and m0Data[inst.id] then
                        rect:SetColorTexture(unpack(sColors and sColors.completed or { 0, 1, 1, 0.8 }))
                    else
                        rect:SetColorTexture(unpack(sColors and sColors.available or { 0, 0, 0, 0.5 }))
                    end
                end

                cell:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Mythic 0 Lockouts")
                    for _, inst in ipairs(ejInstances) do
                        local isLocked = m0Data and m0Data[inst.id]
                        local status = isLocked and "|cff00ffffCompleted|r" or "|cff888888Available|r"
                        GameTooltip:AddDoubleLine(inst.name, status, 1, 1, 1, 1, 1, 1)
                    end
                    GameTooltip:Show()
                end)
                cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
            elseif cat.type == "raid_grid" then
                text:Hide()
                local difficulty = cat.difficulty
                local bossData = alt.data.raids and alt.data.raids[difficulty]
                local numBosses = 8 -- Hardcoded for current raid context
                local squareSize = (cfg.columnWidth - 10) / numBosses

                local r, g, b = 1, 0.8, 0      -- Default gold
                if difficulty == 16 then
                    r, g, b = 0.64, 0.21, 0.93 -- Mythic Purple
                elseif difficulty == 15 then
                    r, g, b = 0, 0.44, 1       -- Heroic Blue
                elseif difficulty == 14 then
                    r, g, b = 0.12, 1, 0       -- Normal Green
                end

                for bIdx = 1, numBosses do
                    local rect = cell["raidRect" .. bIdx] or cell:CreateTexture(nil, "ARTWORK")
                    cell["raidRect" .. bIdx] = rect
                    rect:Show()
                    rect:SetSize(squareSize - 2, cfg.rowHeight - 12)
                    rect:SetPoint("LEFT", (bIdx - 1) * squareSize + 5, 0)

                    if bossData and bossData[bIdx] then
                        rect:SetColorTexture(r, g, b, 0.8)
                    else
                        local sColors = cfg.statusColors
                        rect:SetColorTexture(unpack(sColors and sColors.available or { 0, 0, 0, 0.5 }))
                    end
                end
            end

            y = y + cfg.rowHeight
        end

        xOffset = xOffset + cfg.columnWidth
    end

    -- Adjust frame size to fit content
    local totalWidth = 140 + 20 + xOffset + 10                   -- sidebar + padding + columns + padding
    local totalHeight = 35 + (#visibleCats * cfg.rowHeight) + 10 -- padding + rows + padding
    frame:SetSize(totalWidth, totalHeight)
end

function sfui.alts.Toggle()
    sfui.alts.RefreshDynamicCategories()
    if not frame then
        frame = sfui.alts.CreateFrame()
    end
    if frame:IsShown() then
        frame:Hide()
    else
        sfui.alts.CheckWeeklyResets()
        -- Force a server sync for the latest Vault data before making the UI visible
        if C_WeeklyRewards and C_WeeklyRewards.OnUIInteract then C_WeeklyRewards.OnUIInteract() end
        frame:Show()
        if needsSync then
            sfui.alts.PerformSync()
            needsSync = false
        end
        sfui.alts.UpdateUI(true)
    end
end

function sfui.alts.initialize()
    sfui.alts.RefreshDynamicCategories()
    sfui.alts.SyncCurrentCharacter()

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    eventFrame:RegisterEvent("WEEKLY_REWARDS_UPDATE")
    eventFrame:RegisterEvent("QUEST_TURNED_IN")
    eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
    eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    eventFrame:RegisterEvent("SKILL_LINES_CHANGED")
    eventFrame:RegisterEvent("CHAT_MSG_SKILL")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
    eventFrame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
    eventFrame:RegisterEvent("MYTHIC_PLUS_NEW_WEEKLY_RECORD")

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_ENTERING_WORLD" then
            leavingWorld = false
        end

        if event == "QUEST_LOG_UPDATE" then
            preyLogDirty = true
        end

        if event == "CHALLENGE_MODE_COMPLETED" then
            -- Force the server to sync Vault and M+ run structures immediately
            if C_MythicPlus and C_MythicPlus.RequestMapInfo then C_MythicPlus.RequestMapInfo() end
            if C_MythicPlus and C_MythicPlus.RequestRewards then C_MythicPlus.RequestRewards() end
            if C_WeeklyRewards and C_WeeklyRewards.OnUIInteract then C_WeeklyRewards.OnUIInteract() end
        end

        -- Track per-character completion of warband pool quests.
        -- IsQuestFlaggedCompleted is account-wide for these, so we must
        -- record turn-ins locally. The flag is wiped on weekly reset.
        if event == "QUEST_TURNED_IN" then
            local questID = ...
            if questID then
                for _, pID in ipairs(LEGENDS_POOL) do
                    if questID == pID then
                        local guid = GetCurrentCharacterGUID()
                        if guid and SfuiDB.alts[guid] then
                            SfuiDB.alts[guid].quests = SfuiDB.alts[guid].quests or {}
                            SfuiDB.alts[guid].quests.legends = SfuiDB.alts[guid].quests.legends or {}
                            SfuiDB.alts[guid].quests.legends.completed = true
                        end
                        break
                    end
                end
            end
        end

        if event == "PLAYER_LEAVING_WORLD" then
            -- Sync immediately on logout to catch final changes, protected by validation guards in PerformSync
            leavingWorld = true
            sfui.alts.PerformSync(true)
        else
            sfui.alts.SyncCurrentCharacter()
        end
    end)

    SlashCmdList["SFUIALTS"] = function(msg)
        if msg == "resetweeklies" then
            for _, d in pairs(SfuiDB.alts or {}) do
                if d.quests then wipe(d.quests) end
                if d.prey then wipe(d.prey) end
                if d.profKP then
                    for _, pData in pairs(d.profKP) do
                        if type(pData) == "table" then
                            pData.done = 0
                            if pData.details then
                                pData.details.treatise = false
                                pData.details.quest = false
                                pData.details.treasures = 0
                            end
                        end
                    end
                end
                if d.vault then
                    d.vault.hasReward = nil
                    if d.vault.raid then wipe(d.vault.raid) end
                    if d.vault.dungeon then wipe(d.vault.dungeon) end
                    if d.vault.world then wipe(d.vault.world) end
                end
                if d.m0 then wipe(d.m0) end
                if d.raids then wipe(d.raids) end
            end
            sfui.alts.UpdateUI(true)
            sfui.common.print("Manually reset all weekly data for alts.")
        else
            sfui.alts.Toggle()
        end
    end
    SLASH_SFUIALTS1 = "/alts"
end
