local addonName, addon = ...
---@diagnostic disable: undefined-global, undefined-field
sfui            = sfui or {}
sfui.lootviewer = {}

local CreateFrame               = CreateFrame
local UIParent                  = UIParent
local GameTooltip               = sfui.tooltip or _G.GameTooltip
local GetNumSpecializations     = GetNumSpecializations
local GetSpecializationInfo     = GetSpecializationInfo
local GetSpecializationInfoByID = GetSpecializationInfoByID
local UnitClass                 = UnitClass
local string                    = string
local math                      = math
local table                     = table

-- ─── Constants ────────────────────────────────────────────────────────────────
local FRAME_W    = 780
local FRAME_H    = 600
local PAD        = 8
local ICON_SZ    = 32
local ICON_PAD   = 3
local ROW_H      = 52
local BOSS_ICO   = 36
local SCROLL_W       = FRAME_W - 4

-- ─── Class / spec helpers ─────────────────────────────────────────────────────
local _, ENGLISH_CLASS, PLAYER_CLASS_ID = UnitClass("player")
if not PLAYER_CLASS_ID or PLAYER_CLASS_ID == 0 then
    local _, _, cid = UnitClass("player")
    PLAYER_CLASS_ID = cid or 0
end

local playerSpecs   = {}
local playerSpecIDs = {}

local function InitPlayerSpecs()
    if not PLAYER_CLASS_ID or PLAYER_CLASS_ID == 0 then
        local _, _, cid = UnitClass("player")
        PLAYER_CLASS_ID = cid or 0
    end
    if #playerSpecIDs > 0 then return end
    local n = GetNumSpecializations() or 0
    for i = 1, n do
        local specID, name, desc, icon, role, primaryStat = GetSpecializationInfo(i)
        if specID and specID > 0 then
            playerSpecs[specID] = {
                id          = specID,
                name        = name,
                icon        = icon,
                role        = role,
                primaryStat = primaryStat,
                index       = i,
            }
            playerSpecIDs[#playerSpecIDs + 1] = specID
        end
    end
end

local function DB()
    if sfui.lootspec and sfui.lootspec.DB then
        return sfui.lootspec.DB()
    end
    SfuiDB.lootspec = SfuiDB.lootspec or {}
    SfuiDB.lootspec.classes = SfuiDB.lootspec.classes or {}
    local db = SfuiDB.lootspec.classes[ENGLISH_CLASS]
    if not db then
        db = { enabled = true, defaultSpec = 0, bosses = {}, dungeons = {} }
        SfuiDB.lootspec.classes[ENGLISH_CLASS] = db
    end
    db.bosses   = db.bosses or {}
    db.dungeons = db.dungeons or {}
    return db
end

local function SpecName(specID)
    if specID == 0 then return "— off —" end
    local _, name = GetSpecializationInfoByID(specID)
    return name or ("Spec "..specID)
end

local function SpecIcon(specID)
    if specID == 0 then return nil end
    local _, _, _, icon = GetSpecializationInfoByID(specID)
    return icon
end

local function GetSpecColor(specID)
    if sfui.common and sfui.common.get_spec_color then
        return sfui.common.get_spec_color(specID)
    end
    if sfui.config and sfui.config.spec_colors and sfui.config.spec_colors[specID] then
        local c = sfui.config.spec_colors[specID]
        return c[1], c[2], c[3], c[4] or 1
    end
    return 0.0, 0.8, 1.0, 1
end

local function CycleSpec(currentID)
    InitPlayerSpecs()
    if currentID == 0 then
        return playerSpecIDs[1] or 0
    end
    for i, id in ipairs(playerSpecIDs) do
        if id == currentID then
            return playerSpecIDs[i + 1] or 0
        end
    end
    return 0
end

-- ─── EJ data helpers ─────────────────────────────────────────────────────────
-- Mirrors lootspec.lua's GetRaidData/GetDungeonData, but also fetches loot
-- per encounter via EJ_SelectEncounter → EJ_GetNumLoot → GetLootInfoByIndex.

local EQUIP_LOC_TO_SLOT = {
    INVTYPE_HEAD           = "head",
    INVTYPE_NECK           = "neck",
    INVTYPE_SHOULDER       = "shoulder",
    INVTYPE_CLOAK          = "back",
    INVTYPE_CHEST          = "chest",
    INVTYPE_ROBE           = "chest",
    INVTYPE_WRIST          = "wrist",
    INVTYPE_HAND           = "hands",
    INVTYPE_WAIST          = "waist",
    INVTYPE_LEGS           = "legs",
    INVTYPE_FEET           = "feet",
    INVTYPE_FINGER         = "ring",
    INVTYPE_TRINKET        = "trinket",
    INVTYPE_WEAPON         = "weapon",
    INVTYPE_2HWEAPON       = "weapon",
    INVTYPE_WEAPONMAINHAND = "weapon",
    INVTYPE_WEAPONOFFHAND  = "weapon",
    INVTYPE_SHIELD         = "weapon",
    INVTYPE_HOLDABLE       = "weapon",
    INVTYPE_RANGED         = "weapon",
    INVTYPE_RANGEDRIGHT    = "weapon",
    INVTYPE_THROWN         = "weapon",
}

local function IsSetItemToken(itemID, itemLink, filterType, name)
    if not itemID then return false end
    if _G.TokenTooltip and _G.TokenTooltip.TokenItems and _G.TokenTooltip.TokenItems[itemID] then
        return true
    end
    local _, _, _, itemEquipLoc, _, classID, subclassID = GetItemInfoInstant(itemLink or itemID)
    if classID == 5 and subclassID == 2 then
        return true
    end
    local isNonEquip = (not itemEquipLoc or itemEquipLoc == "" or itemEquipLoc == "INVTYPE_NON_EQUIP_IGNORE")
    if isNonEquip then
        -- In Dungeon Journal, slot filters 1 (head), 3 (shoulder), 4 (chest), 6 (legs), 9 (hands)
        if filterType and (filterType == 1 or filterType == 3 or filterType == 4 or filterType == 6 or filterType == 9) then
            return true
        end
        if name and (name:find("Curio") or name:find("Omnipotence") or name:find("Token") or name:find("Mark of") or name:find("Trophy of") or name:find("Zenith") or name:find("Dreadful") or name:find("Mystic") or name:find("Venerated") or name:find("Blazing") or name:find("Idol")) then
            return true
        end
    end
    return false
end

local function ResolveItemSlot(itemID, itemLink, filterType)
    local _, _, _, equipLoc = GetItemInfoInstant(itemLink or itemID)
    if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" and EQUIP_LOC_TO_SLOT[equipLoc] then
        return EQUIP_LOC_TO_SLOT[equipLoc]
    end
    return "other"
end

local SLOT_LABELS = {
    head = "head", neck = "neck", shoulder = "shldr", back = "back",
    chest = "chest", wrist = "wrist", hands = "hands", waist = "waist",
    legs = "legs", feet = "feet", weapon = "wpn", ring = "ring",
    trinket = "trnk", other = "other", token = "other",
}

local SLOT_NAMES = {
    head = "Head", neck = "Neck", shoulder = "Shoulder", back = "Back",
    chest = "Chest", wrist = "Wrist", hands = "Hands", waist = "Waist",
    legs = "Legs", feet = "Feet", weapon = "Weapon", ring = "Ring",
    trinket = "Trinket", other = "Other", token = "Other",
}

local function EnsureEJ()
    if EJ_GetInstanceByIndex then return true end
    local loaded = C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
    return EJ_GetInstanceByIndex ~= nil
end

local itemClassCache = {}
local scanTip = nil

local function GetScanTooltip()
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "SfuiLootClassScanTooltip", nil, "GameTooltipTemplate")
        scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    return scanTip
end

local function IsItemForPlayerClass(itemID, itemLink)
    if not itemID or itemID <= 0 then return true end
    if itemClassCache[itemID] ~= nil then
        return itemClassCache[itemID]
    end

    local link = itemLink or ("item:" .. itemID)

    -- 1. Check C_Item.GetItemSpecInfo if available
    if C_Item and C_Item.GetItemSpecInfo then
        local specList = C_Item.GetItemSpecInfo(link)
        if specList and #specList > 0 then
            InitPlayerSpecs()
            local foundMySpec = false
            for _, sID in ipairs(specList) do
                if playerSpecs[sID] then
                    foundMySpec = true
                    break
                end
            end
            if not foundMySpec then
                itemClassCache[itemID] = false
                return false
            end
        end
    end

    -- 2. Tooltip inspection via C_TooltipInfo and hidden GameTooltip
    local localizedClassName = UnitClass("player")
    local locClassLower = localizedClassName and localizedClassName:lower()

    local classPattern = ITEM_CLASSES_ALLOWED and ITEM_CLASSES_ALLOWED:gsub("%%s", ".*")
    local classPrefix = ITEM_CLASSES_ALLOWED and ITEM_CLASSES_ALLOWED:match("^([^:%%]+)")
    if classPrefix then
        classPrefix = classPrefix:trim():lower()
    else
        classPrefix = "classes"
    end

    local foundRestriction = nil -- nil = not found yet, false = not for player, true = for player
    local dataReady = false

    -- Method A: C_TooltipInfo
    if C_TooltipInfo then
        local tData = (link and C_TooltipInfo.GetHyperlink and C_TooltipInfo.GetHyperlink(link))
                   or (C_TooltipInfo.GetItemByID and C_TooltipInfo.GetItemByID(itemID))
        if tData and tData.lines and #tData.lines > 1 then
            dataReady = true
            if TooltipUtil and TooltipUtil.SurfaceArgs then
                TooltipUtil.SurfaceArgs(tData)
            end
            for _, line in ipairs(tData.lines) do
                local lineType = line.type
                local isRestrictedClassType = (lineType and Enum.TooltipDataLineType and lineType == Enum.TooltipDataLineType.RestrictedRaceClass)
                local txt = line.leftText
                local txtLower = (txt and type(txt) == "string") and txt:lower() or ""

                local isClassLine = isRestrictedClassType
                    or (classPattern and txt and txt:match(classPattern))
                    or (classPrefix and txtLower ~= "" and txtLower:find(classPrefix, 1, true))
                    or (txtLower ~= "" and (txtLower:find("classes:", 1, true) or txtLower:find("klassen:", 1, true)))

                if isClassLine then
                    local isRed = false
                    local clr = line.leftColor
                    if clr and clr.r and clr.g and clr.b then
                        if clr.r > 0.9 and clr.g < 0.25 and clr.b < 0.25 then
                            isRed = true
                        end
                    end

                    local matchesMyClass = locClassLower and txtLower ~= "" and txtLower:find(locClassLower, 1, true)

                    if isRed or (txtLower ~= "" and not matchesMyClass) then
                        foundRestriction = false
                        break
                    else
                        foundRestriction = true
                    end
                end
            end
        end
    end

    -- Method B: Hidden GameTooltip scanner (if C_TooltipInfo didn't find a restriction or lines were unformatted)
    if foundRestriction == nil then
        local tip = GetScanTooltip()
        if tip then
            tip:ClearLines()
            tip:SetHyperlink(link)
            local numLines = tip:NumLines()
            if numLines and numLines > 1 then
                dataReady = true
                for i = 1, numLines do
                    local fs = _G["SfuiLootClassScanTooltipTextLeft" .. i]
                    if fs then
                        local txt = fs:GetText()
                        local txtLower = (txt and type(txt) == "string") and txt:lower() or ""
                        local isClassLine = (classPattern and txt and txt:match(classPattern))
                            or (classPrefix and txtLower ~= "" and txtLower:find(classPrefix, 1, true))
                            or (txtLower ~= "" and (txtLower:find("classes:", 1, true) or txtLower:find("klassen:", 1, true)))

                        if isClassLine then
                            local r, g, b = fs:GetTextColor()
                            local isRed = (r and g and b and r > 0.9 and g < 0.25 and b < 0.25)
                            local matchesMyClass = locClassLower and txtLower ~= "" and txtLower:find(locClassLower, 1, true)

                            if isRed or (txtLower ~= "" and not matchesMyClass) then
                                foundRestriction = false
                                break
                            else
                                foundRestriction = true
                            end
                        end
                    end
                end
            end
            tip:Hide()
        end
    end

    if foundRestriction == false then
        itemClassCache[itemID] = false
        return false
    elseif foundRestriction == true then
        itemClassCache[itemID] = true
        return true
    end

    -- If the item is a set token and data isn't ready yet:
    -- Don't allow uncached tokens through until tooltip data confirms they match player class.
    local isToken = IsSetItemToken(itemID, link)
    if isToken and not dataReady then
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return false
    end

    -- If the item data is confirmed cached and has no class restriction lines, it's usable
    if dataReady or (C_Item and C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(itemID)) then
        itemClassCache[itemID] = true
        return true
    end

    -- Item data not yet in cache: request load, do not cache boolean yet
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
    return true
end

local function GetValidPlayerSpecsForItem(itemID, link)
    if not itemID or itemID <= 0 then return nil end
    local itemLink = link or ("item:" .. itemID)

    if not IsItemForPlayerClass(itemID, itemLink) then
        return nil
    end

    -- 1. Check KeystoneLoot (official KeystoneLootAPI or global table)
    local klSpecs = nil
    if _G.KeystoneLootAPI and _G.KeystoneLootAPI.GetItemInfo then
        local ok, klInfo = pcall(_G.KeystoneLootAPI.GetItemInfo, _G.KeystoneLootAPI, itemID)
        if ok and klInfo and klInfo.classes then
            klSpecs = klInfo.classes[PLAYER_CLASS_ID]
            if not klSpecs or #klSpecs == 0 then
                return nil -- KeystoneLoot curated database confirms: item does not drop for this class!
            end
        end
    elseif _G.KeystoneLoot and _G.KeystoneLoot.ItemDatabase then
        local klItem = _G.KeystoneLoot.ItemDatabase[itemID]
        if klItem and klItem.classes then
            klSpecs = klItem.classes[PLAYER_CLASS_ID]
            if not klSpecs or #klSpecs == 0 then
                return nil
            end
        end
    end

    if klSpecs then
        local validSpecs = {}
        for _, sID in ipairs(klSpecs) do
            if playerSpecs[sID] then
                validSpecs[sID] = true
            end
        end
        return next(validSpecs) and validSpecs or nil
    end

    -- 2. Check Blizzard native spec info API
    if C_Item and C_Item.GetItemSpecInfo then
        local specList = C_Item.GetItemSpecInfo(itemLink)
        if specList and #specList > 0 then
            local validSpecs = {}
            for _, sID in ipairs(specList) do
                if playerSpecs[sID] then
                    validSpecs[sID] = true
                end
            end
            if next(validSpecs) then
                return validSpecs
            else
                return nil
            end
        end
    end

    -- 3. Integrate sfui gear rules (from frames/gear/highest.lua, ignoring combat talent overrides)
    if sfui.highest and sfui.highest.IsItemValidForSpec then
        local validSpecs = {}
        for _, specID in ipairs(playerSpecIDs) do
            local isValid = sfui.highest.IsItemValidForSpec(itemLink, specID, true, true)
            if isValid then
                validSpecs[specID] = true
            end
        end
        if next(validSpecs) then
            return validSpecs
        end
    end

    -- 4. Fallback: all player specs
    local allSpecs = {}
    for _, sID in ipairs(playerSpecIDs) do
        allSpecs[sID] = true
    end
    return allSpecs
end

-- Sort loot items: Trinkets first (1), Weapons second (2), Gear (3), Other items last (4)
local function SortLootItems(items)
    if not items or #items <= 1 then return items end
    for idx = 1, #items do
        items[idx]._sortIdx = idx
    end
    table.sort(items, function(a, b)
        local pa = (a.slot == "trinket" and 1) or (a.slot == "weapon" and 2) or (a.slot == "other" and 4) or (a.slot == "token" and 4) or 3
        local pb = (b.slot == "trinket" and 1) or (b.slot == "weapon" and 2) or (b.slot == "other" and 4) or (b.slot == "token" and 4) or 3
        if pa ~= pb then
            return pa < pb
        end
        return (a._sortIdx or 0) < (b._sortIdx or 0)
    end)
    for idx = 1, #items do
        items[idx]._sortIdx = nil
    end
    return items
end

-- Fetches loot for the currently-selected EJ encounter, filtered for the player's class.
-- Populates item.specs with the set of specIDs for which the item drops.
local function FetchEncounterLoot(bossID)
    InitPlayerSpecs()
    local lootMap   = {}
    local lootOrder = {}

    if C_EncounterJournal and C_EncounterJournal.ResetSlotFilter then
        C_EncounterJournal.ResetSlotFilter()
    end

    -- 1. Query for each specialization of the player's class
    for _, specID in ipairs(playerSpecIDs) do
        if bossID then securecall(EJ_SelectEncounter, bossID) end
        securecall(EJ_SetLootFilter, PLAYER_CLASS_ID, specID)
        local n = EJ_GetNumLoot and EJ_GetNumLoot() or 0
        for i = 1, n do
            local info = C_EncounterJournal.GetLootInfoByIndex(i)
            if info and info.itemID and info.itemID > 0 then
                local itemID = info.itemID
                if IsItemForPlayerClass(itemID, info.link) then
                    local entry = lootMap[itemID]
                    if not entry then
                        local isToken = IsSetItemToken(itemID, info.link, info.filterType, info.name)
                        local resolvedSlot = ResolveItemSlot(itemID, info.link, info.filterType)
                        entry = {
                            id         = itemID,
                            name       = info.name,
                            slot       = resolvedSlot,
                            icon       = info.icon,
                            quality    = (C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID))
                                          or (select(3, GetItemInfo(info.link or itemID)))
                                          or 4,
                            link       = info.link,
                            specs      = {},
                            filterType = info.filterType,
                            isSetToken = isToken,
                        }
                        lootMap[itemID] = entry
                        lootOrder[#lootOrder + 1] = entry
                    end
                    entry.specs[specID] = true
                end
            end
        end
    end

    -- 2. Query class-wide with all specializations (specID = 0)
    -- to catch any class-wide or general drops (tokens, cosmetics, generic trinkets)
    if bossID then securecall(EJ_SelectEncounter, bossID) end
    securecall(EJ_SetLootFilter, PLAYER_CLASS_ID, 0)
    local nAll = EJ_GetNumLoot and EJ_GetNumLoot() or 0
    for i = 1, nAll do
        local info = C_EncounterJournal.GetLootInfoByIndex(i)
        if info and info.itemID and info.itemID > 0 then
            local itemID = info.itemID
            local entry = lootMap[itemID]
            -- Only process if this item was NOT already added from spec queries
            if not entry and IsItemForPlayerClass(itemID, info.link) then
                local specificSpecs = GetValidPlayerSpecsForItem(itemID, info.link)
                if specificSpecs and next(specificSpecs) then
                    local isToken = IsSetItemToken(itemID, info.link, info.filterType, info.name)
                    local resolvedSlot = ResolveItemSlot(itemID, info.link, info.filterType)
                    entry = {
                        id         = itemID,
                        name       = info.name,
                        slot       = resolvedSlot,
                        icon       = info.icon,
                        quality    = (C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID))
                                      or (select(3, GetItemInfo(info.link or itemID)))
                                      or 4,
                        link       = info.link,
                        specs      = {},
                        filterType = info.filterType,
                        isSetToken = isToken,
                    }
                    lootMap[itemID] = entry
                    lootOrder[#lootOrder + 1] = entry
                    for sID in pairs(specificSpecs) do
                        entry.specs[sID] = true
                    end
                end
            end
        end
    end

    -- 3. Query all-loot (class = 0, spec = 0) specifically for non-equipment "other" items
    -- that may drop for multiple classes (e.g. tier tokens, curios, omni-tokens)
    if bossID then securecall(EJ_SelectEncounter, bossID) end
    securecall(EJ_SetLootFilter, 0, 0)
    local nRoot = EJ_GetNumLoot and EJ_GetNumLoot() or 0
    for i = 1, nRoot do
        local info = C_EncounterJournal.GetLootInfoByIndex(i)
        if info and info.itemID and info.itemID > 0 then
            local itemID = info.itemID
            if not lootMap[itemID] then
                local resolvedSlot = ResolveItemSlot(itemID, info.link, info.filterType)
                if resolvedSlot == "other" then
                    local _, _, _, itemEquipLoc, _, classID, subclassID = GetItemInfoInstant(info.link or itemID)
                    local isMountOrPet = (classID == 15 and (subclassID == 5 or subclassID == 2))
                    local isRecipe = (classID == 9)
                    local isCosmetic = (C_Item and C_Item.IsCosmeticItem and C_Item.IsCosmeticItem(itemID)) or (classID == 4 and subclassID == 5)
                    local q = (C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(itemID)) or 4
                    local isJunk = q and q < 2

                    if not isMountOrPet and not isRecipe and not isCosmetic and not isJunk then
                        if IsItemForPlayerClass(itemID, info.link) then
                            local isToken = IsSetItemToken(itemID, info.link, info.filterType, info.name)
                            local entry = {
                                id         = itemID,
                                name       = info.name,
                                slot       = "other",
                                icon       = info.icon,
                                quality    = q,
                                link       = info.link,
                                specs      = {},
                                filterType = info.filterType,
                                isSetToken = isToken,
                            }
                            lootMap[itemID] = entry
                            lootOrder[#lootOrder + 1] = entry
                            for _, sID in ipairs(playerSpecIDs) do
                                entry.specs[sID] = true
                            end
                        end
                    end
                end
            end
        end
    end
    securecall(EJ_SetLootFilter, PLAYER_CLASS_ID, 0)

    return SortLootItems(lootOrder)
end

local raidDataCache    = nil
local dungeonDataCache = nil

local function GetRaidData()
    if raidDataCache then return raidDataCache end
    if not EnsureEJ() then return {} end
    InitPlayerSpecs()

    local oldInstance = EJ_GetCurrentInstance and EJ_GetCurrentInstance()
    local oldClass, oldSpec = EJ_GetLootFilter and EJ_GetLootFilter()
    local oldDiff = EJ_GetDifficulty and EJ_GetDifficulty()
    local raids = {}
    local instIdx = 1
    while true do
        local instanceID, name, _, _, _, _, _, _, _, shouldDisplayDifficulty = EJ_GetInstanceByIndex(instIdx, true)
        if not instanceID then break end

        local isWorldBoss = (shouldDisplayDifficulty == false)
            or (name and (name:lower():find("world boss") or name:lower():find("weltboss")))

        if not isWorldBoss then
            local raid = { name = name, instanceID = instanceID, bosses = {} }
            securecall(EJ_SelectInstance, instanceID)

            -- Check if this instance has valid raid difficulties
            local hasRaidDiff = true
            if EJ_IsValidInstanceDifficulty then
                hasRaidDiff = EJ_IsValidInstanceDifficulty(14)
                           or EJ_IsValidInstanceDifficulty(15)
                           or EJ_IsValidInstanceDifficulty(16)
                           or EJ_IsValidInstanceDifficulty(17)
            end

            if hasRaidDiff then
                -- Set Mythic difficulty (16 = Mythic Raid) for highest ilvl
                if EJ_IsValidInstanceDifficulty and EJ_IsValidInstanceDifficulty(16) then
                    securecall(EJ_SetDifficulty, 16)
                elseif EJ_IsValidInstanceDifficulty and EJ_IsValidInstanceDifficulty(15) then
                    securecall(EJ_SetDifficulty, 15)
                end

                local encIdx = 1
                while true do
                    local encName, _, bossID, _, _, _, dungeonEncounterID = EJ_GetEncounterInfoByIndex(encIdx)
                    if not bossID or bossID == 0 then break end

                    -- Fetch creature portrait icon
                    local _, _, _, _, iconImage = EJ_GetCreatureInfo(1, bossID)

                    -- Fetch loot for this encounter (class & spec aware)
                    securecall(EJ_SelectEncounter, bossID)
                    local loot = FetchEncounterLoot(bossID)

                    table.insert(raid.bosses, {
                        name               = encName,
                        encounterID        = bossID,
                        dungeonEncounterID = dungeonEncounterID,
                        icon               = iconImage,
                        loot               = loot,
                    })
                    encIdx = encIdx + 1
                end

                if #raid.bosses > 0 then
                    table.insert(raids, raid)
                end
            end
        end
        instIdx = instIdx + 1
    end

    if oldInstance then securecall(EJ_SelectInstance, oldInstance) end
    if oldDiff and EJ_SetDifficulty then securecall(EJ_SetDifficulty, oldDiff) end
    if oldClass then
        securecall(EJ_SetLootFilter, oldClass, oldSpec)
    else
        securecall(EJ_SetLootFilter, PLAYER_CLASS_ID, 0)
    end
    raidDataCache = raids
    return raids
end

local function GetDungeonData()
    if dungeonDataCache then return dungeonDataCache end
    if not EnsureEJ() then return {} end
    InitPlayerSpecs()

    local oldInstance = EJ_GetCurrentInstance and EJ_GetCurrentInstance()
    local oldClass, oldSpec = EJ_GetLootFilter and EJ_GetLootFilter()
    local oldDiff = EJ_GetDifficulty and EJ_GetDifficulty()
    local oldTier = EJ_GetCurrentTier and EJ_GetCurrentTier()

    -- Build EJ instance name → instanceID map for dungeons across ALL expansion tiers
    local nameToInstance = {}
    local numTiers = EJ_GetNumTiers and EJ_GetNumTiers() or 1
    for t = 1, numTiers do
        securecall(EJ_SelectTier, t)
        local instIdx = 1
        while true do
            local instanceID, name = EJ_GetInstanceByIndex(instIdx, false)
            if not instanceID then break end
            nameToInstance[name] = instanceID
            if name then
                nameToInstance[string.lower(name)] = instanceID
            end
            instIdx = instIdx + 1
        end
    end
    if oldTier then securecall(EJ_SelectTier, oldTier) end

    -- Fallback map from KeystoneLoot database if available
    local klMapToInstance = {}
    if _G.KeystoneLoot and _G.KeystoneLoot.DungeonDatabase then
        for _, d in ipairs(_G.KeystoneLoot.DungeonDatabase) do
            if d.challengeModeId and d.instanceId then
                klMapToInstance[d.challengeModeId] = d.instanceId
            end
        end
    end

    local dungeons = {}
    local maps = C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()
    if not maps then return dungeons end

    for _, mapID in ipairs(maps) do
        local name, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
        if name then
            if texture == 0 then texture = nil end
            local instanceID = nameToInstance[name]
                            or (name and nameToInstance[string.lower(name)])
                            or klMapToInstance[mapID]
            local bosses     = {}
            local allLoot    = {}
            local seenItem   = {}

            -- Walk all encounters in this EJ instance for loot
            if instanceID then
                securecall(EJ_SelectInstance, instanceID)

                -- Set Mythic difficulty (23 = Mythic Dungeon) for highest ilvl and M+ loot tables
                if EJ_IsValidInstanceDifficulty and EJ_IsValidInstanceDifficulty(23) then
                    securecall(EJ_SetDifficulty, 23)
                elseif EJ_IsValidInstanceDifficulty and EJ_IsValidInstanceDifficulty(2) then
                    securecall(EJ_SetDifficulty, 2)
                elseif EJ_IsValidInstanceDifficulty and EJ_IsValidInstanceDifficulty(1) then
                    securecall(EJ_SetDifficulty, 1)
                end

                local encIdx = 1
                while true do
                    local encName, _, bossID = EJ_GetEncounterInfoByIndex(encIdx, instanceID)
                    if not bossID or bossID == 0 then break end

                    local _, _, _, _, iconImage = EJ_GetCreatureInfo(1, bossID)
                    securecall(EJ_SelectEncounter, bossID)
                    local loot = FetchEncounterLoot(bossID)

                    for _, item in ipairs(loot) do
                        if not seenItem[item.id] then
                            seenItem[item.id] = true
                            item.bossName = encName
                            allLoot[#allLoot + 1] = item
                        end
                    end

                    bosses[#bosses + 1] = {
                        name        = encName,
                        encounterID = bossID,
                        icon        = iconImage,
                        loot        = loot,
                    }
                    encIdx = encIdx + 1
                end
            end

            SortLootItems(allLoot)

            -- Fall back to EJ button texture if mapUI texture is missing
            if (not texture or texture == 0) and instanceID then
                local _, _, _, btnImg, _, btnSmall = EJ_GetInstanceInfo(instanceID)
                texture = (btnSmall and btnSmall ~= 0 and btnSmall)
                       or (btnImg and btnImg ~= 0 and btnImg)
            end

            dungeons[#dungeons + 1] = {
                mapID      = mapID,
                name       = name,
                texture    = texture,
                instanceID = instanceID,
                loot       = allLoot,
                bosses     = bosses,
            }
        end
    end

    if oldInstance then securecall(EJ_SelectInstance, oldInstance) end
    if oldDiff and EJ_SetDifficulty then securecall(EJ_SetDifficulty, oldDiff) end
    if oldClass then
        securecall(EJ_SetLootFilter, oldClass, oldSpec)
    else
        securecall(EJ_SetLootFilter, PLAYER_CLASS_ID, 0)
    end

    table.sort(dungeons, function(a, b) return a.name < b.name end)
    dungeonDataCache = dungeons
    return dungeons
end

-- Invalidate when EJ loads/reloads
sfui.events.RegisterEvent("ADDON_LOADED", function(_, addonLoaded)
    if addonLoaded == "Blizzard_EncounterJournal" then
        raidDataCache    = nil
        dungeonDataCache = nil
        if sfui.lootviewer and sfui.lootviewer.frame and sfui.lootviewer.frame:IsShown() then
            sfui.lootviewer.Rebuild()
        end
    end
end)

-- ─── Filter state ─────────────────────────────────────────────────────────────
local filterSlot   = "all"
local filterSpec   = 0
local filterSearch = ""

local highlightStats = {
    haste       = false,
    crit        = false,
    mastery     = false,
    versatility = false,
}

local STAT_COLORS = (sfui.config and sfui.config.stat_colors) or {
    haste       = { 0.2,  0.85, 0.3,  1.0 },
    crit        = { 1.0,  0.45, 0.1,  1.0 },
    mastery     = { 0.75, 0.4,  1.0,  1.0 },
    versatility = { 0.2,  0.65, 1.0,  1.0 },
}

-- ─── Non-equippable / Cosmetic Helpers ───────────────────────────────────────
local function IsNonEquippableOrCosmetic(item)
    if not item or not item.id then return true end
    local itemID = item.id

    local _, _, _, itemEquipLoc, _, classID, subclassID = GetItemInfoInstant(item.link or itemID)

    -- Tabards and shirts are non-combat cosmetic
    if itemEquipLoc == "INVTYPE_TABARD" or itemEquipLoc == "INVTYPE_BODY" then
        return true
    end

    -- Blizzard API: is it marked as cosmetic?
    if (C_Item and C_Item.IsCosmeticItem and C_Item.IsCosmeticItem(itemID)) or (classID == 4 and subclassID == 5) then
        return true
    end

    -- Mounts (class 15, sub 5) and Pets (class 15, sub 2)
    if classID == 15 and (subclassID == 5 or subclassID == 2) then
        return true
    end

    -- Recipes (class 9)
    if classID == 9 then
        return true
    end

    -- Items with quality 0 (poor) or 1 (common) are cosmetic / transmog / junk
    local q = tonumber(item.quality)
    if q and q < 2 then
        return true
    end

    return false
end

local function GetItemBadgeText(item)
    if not item then return "" end
    if item.isSetToken or item.slot == "other" or item.slot == "token" then
        return ""
    end

    if item.slot then
        local s = SLOT_LABELS[item.slot] or item.slot
        return string.lower(s)
    end

    -- Tokens and other non-equippables have no text overlay on their icons
    return ""
end

local function MatchesFilter(item, bossName, instanceName)
    -- Hide non-combat cosmetics (mounts, pets, recipes, tabards, shirts, etc.)
    if IsNonEquippableOrCosmetic(item) then
        return false
    end

    -- Hide tier tokens or items for other classes
    if not IsItemForPlayerClass(item.id, item.link) then
        return false
    end
    if filterSlot == "other" or filterSlot == "token" then
        if item.slot ~= "other" and item.slot ~= "token" and not item.isSetToken then
            return false
        end
    elseif filterSlot ~= "all" then
        if item.isSetToken and (item.slot == "other" or item.slot == "token") then
            -- Omni-token (Curio): matches any tier armor slot filter
            if filterSlot ~= "head" and filterSlot ~= "shoulder" and filterSlot ~= "chest"
               and filterSlot ~= "hands" and filterSlot ~= "legs" then
                return false
            end
        elseif item.slot ~= filterSlot then
            return false
        end
    end
    if filterSpec ~= 0 and item.specs and next(item.specs) then
        if not item.specs[filterSpec] then
            return false
        end
    end

    if filterSearch ~= "" then
        local bossMatches = (bossName and string.find(string.lower(bossName), filterSearch, 1, true))
            or (instanceName and string.find(string.lower(instanceName), filterSearch, 1, true))
        if not bossMatches then
            local itemMatches = (item.name and string.find(string.lower(item.name), filterSearch, 1, true))
                or (item.bossName and string.find(string.lower(item.bossName), filterSearch, 1, true))
            if not itemMatches then
                return false
            end
        end
    end

    return true
end

-- ─── Icon button pool ─────────────────────────────────────────────────────────
local iconPool      = {}
local iconPoolCount = 0

local ITEM_BORDER_SZ = 4

local function CreateButtonBorders(b)
    if b.borders then return end
    b.borders = {}
    for i = 1, 4 do
        local t = b:CreateTexture(nil, "OVERLAY", nil, 6)
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        b.borders[i] = t
    end
    local top, bottom, left, right = unpack(b.borders)
    top:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
    top:SetHeight(ITEM_BORDER_SZ)

    bottom:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
    bottom:SetHeight(ITEM_BORDER_SZ)

    left:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    left:SetWidth(ITEM_BORDER_SZ)

    right:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(ITEM_BORDER_SZ)
end

local function AcquireIconBtn(parent)
    iconPoolCount = iconPoolCount + 1
    local b = iconPool[iconPoolCount]
    if not b then
        b = CreateFrame("Button", nil, parent, "BackdropTemplate")
        b:SetSize(ICON_SZ, ICON_SZ)
        b:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
        })
        b:SetBackdropColor(0.08, 0.08, 0.08, 1)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetPoint("TOPLEFT", 0, 0)
        b.tex:SetPoint("BOTTOMRIGHT", 0, 0)
        b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        CreateButtonBorders(b)
        b.badge = b:CreateFontString(nil, "OVERLAY")
        b.badge:SetDrawLayer("OVERLAY", 7)
        b.badge:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
        b.badge:SetShadowOffset(0, 0)
        b.badge:SetShadowColor(0, 0, 0, 0)
        b.badge:SetPoint("BOTTOMRIGHT", -2, 2)
        b.badge:SetJustifyH("RIGHT")
        b.badge:SetTextColor(1, 1, 1, 1)
        iconPool[iconPoolCount] = b
    else
        CreateButtonBorders(b)
        b.tex:ClearAllPoints()
        b.tex:SetPoint("TOPLEFT", 0, 0)
        b.tex:SetPoint("BOTTOMRIGHT", 0, 0)
        if b.badge then
            b.badge:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
            b.badge:SetShadowOffset(0, 0)
            b.badge:SetShadowColor(0, 0, 0, 0)
            b.badge:SetTextColor(1, 1, 1, 1)
        end
    end
    b:SetParent(parent)
    b:ClearAllPoints()
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:Show()
    return b
end

local function ReleaseIconPool()
    for i = 1, iconPoolCount do
        local b = iconPool[i]
        if b then
            b:Hide()
            b:SetScript("OnEnter", nil)
            b:SetScript("OnLeave", nil)
            b:SetScript("OnClick", nil)
            if sfui.glows and sfui.glows.stop_glow then
                sfui.glows.stop_glow(b)
            end
            if b.borders then
                for _, border in ipairs(b.borders) do
                    border:Hide()
                end
            end
        end
    end
    iconPoolCount = 0
end

local STRIP_LEFT = PAD + BOSS_ICO + 8 + 144

-- ─── Card pool ────────────────────────────────────────────────────────────────
local cardPool      = {}
local cardPoolCount = 0

local function AcquireCard(parent)
    cardPoolCount = cardPoolCount + 1
    local c = cardPool[cardPoolCount]
    if not c then
        local mult = sfui.pixelScale or 1
        local gray = (sfui.config and sfui.config.colors and sfui.config.colors.gray) or { 0.2, 0.2, 0.2 }
        local cyan = (sfui.config and sfui.config.colors and sfui.config.colors.cyan) or { 0.0, 1.0, 1.0 }

        c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        c:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = mult,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        c:SetBackdropColor(0.05, 0.05, 0.06, 0.95)
        c:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.5)

        c.portrait = c:CreateTexture(nil, "ARTWORK")
        c.portrait:SetSize(BOSS_ICO, BOSS_ICO)
        c.portrait:SetPoint("LEFT", PAD, 0)
        c.portrait:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        c.nameFS = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        c.nameFS:SetPoint("TOPLEFT", c.portrait, "TOPRIGHT", 6, -3)
        c.nameFS:SetWidth(140)
        c.nameFS:SetJustifyH("LEFT")
        c.nameFS:SetWordWrap(false)
        c.nameFS:SetTextColor(0.9, 0.9, 0.9, 1)

        -- Spec badge button
        local specBtn = CreateFrame("Button", nil, c, "BackdropTemplate")
        specBtn:SetSize(130, 18)
        specBtn:SetPoint("BOTTOMLEFT", c.portrait, "BOTTOMRIGHT", 6, 3)
        specBtn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = mult,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        specBtn:SetBackdropColor(0.07, 0.07, 0.07, 1)
        specBtn:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.6)

        local sIcon = specBtn:CreateTexture(nil, "ARTWORK")
        sIcon:SetSize(13, 13)
        sIcon:SetPoint("LEFT", 3, 0)
        sIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        specBtn.iconTex = sIcon

        local sLbl = specBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sLbl:SetPoint("LEFT", sIcon, "RIGHT", 4, 0)
        sLbl:SetPoint("RIGHT", -4, 0)
        sLbl:SetJustifyH("LEFT")
        sLbl:SetWordWrap(false)
        specBtn.lbl = sLbl

        specBtn.Refresh = function(self)
            if not self.keyID then return end
            local db = DB()
            local specID = 0
            if self.isBoss then
                local entry = db.bosses[self.keyID]
                specID = (type(entry) == "table" and entry.spec) or
                         (type(entry) == "number" and entry) or 0
            else
                specID = (db.dungeons and db.dungeons[self.keyID]) or 0
            end
            local icon = SpecIcon(specID)
            if icon then sIcon:SetTexture(icon) ; sIcon:Show() else sIcon:Hide() end
            if specID == 0 then
                sLbl:SetText("— off —") ; sLbl:SetTextColor(0.28, 0.28, 0.28, 1)
            else
                sLbl:SetTextColor(GetSpecColor(specID))
                sLbl:SetText(SpecName(specID))
            end
        end

        specBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        specBtn:SetScript("OnClick", function(self, btn)
            if not self.keyID then return end
            local db = DB()
            if self.isBoss then
                local entry = db.bosses[self.keyID]
                if type(entry) ~= "table" then
                    entry = { spec = (type(entry) == "number" and entry or 0) }
                    db.bosses[self.keyID] = entry
                end
                if btn == "RightButton" then entry.spec = 0
                else entry.spec = CycleSpec(entry.spec or 0) end
            else
                db.dungeons = db.dungeons or {}
                local cur = db.dungeons[self.keyID] or 0
                if btn == "RightButton" then db.dungeons[self.keyID] = 0
                else db.dungeons[self.keyID] = CycleSpec(cur) end
            end
            self:Refresh()
        end)
        specBtn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(cyan[1], cyan[2], cyan[3], 1)
            if not self.keyID or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("loot spec — " .. (self.isBoss and "boss" or "dungeon"))
            GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle spec", 1, 1, 1)
            GameTooltip:AddLine("|cffaaaaaaright-click|r to clear", 1, 1, 1)
            GameTooltip:Show()
        end)
        specBtn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.6)
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        c.specBtn = specBtn

        c.iconStrip = CreateFrame("Frame", nil, c)

        c.noLootFS = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.noLootFS:SetPoint("LEFT", c, "LEFT", STRIP_LEFT, 0)
        c.noLootFS:SetJustifyH("LEFT")
        c.noLootFS:SetTextColor(0.35, 0.35, 0.38, 1)

        cardPool[cardPoolCount] = c
    end
    c:SetParent(parent)
    c:ClearAllPoints()
    c:Show()
    return c
end

local function ReleaseCards()
    ReleaseIconPool()
    for i = 1, cardPoolCount do
        if cardPool[i] then cardPool[i]:Hide() end
    end
    cardPoolCount = 0
end

-- ─── Spec lines in tooltip (matches KeystoneLoot style) ──────────────────────
local function AddSpecLinesToTooltip(item)
    if not item then return end
    InitPlayerSpecs()

    if item.bossName then
        GameTooltip:AddLine("|cff888888Boss:|r " .. item.bossName, 0.85, 0.85, 0.85)
    end

    local isWeaponOrTrinket = (item.slot == "weapon" or item.slot == "trinket")

    -- Suppress specialization requirement line when viewing a specific spec (unless weapon or trinket)
    if not isWeaponOrTrinket and filterSpec ~= 0 then return end
    if not item.specs then return end

    local specNames = {}
    for _, specID in ipairs(playerSpecIDs) do
        if item.specs[specID] then
            local specInfo = playerSpecs[specID]
            if specInfo and specInfo.name and specInfo.name ~= "" then
                local r, g, b = GetSpecColor(specID)
                local colStr = string.format("|cff%02x%02x%02x%s|r",
                    math.min(255, math.max(0, math.floor(r * 255 + 0.5))),
                    math.min(255, math.max(0, math.floor(g * 255 + 0.5))),
                    math.min(255, math.max(0, math.floor(b * 255 + 0.5))),
                    specInfo.name)
                specNames[#specNames + 1] = colStr
            end
        end
    end

    local num = #specNames
    if num == 0 then return end
    -- If available to all specs, only show for weapons and trinkets
    if not isWeaponOrTrinket and (#playerSpecIDs > 0 and num >= #playerSpecIDs) then return end

    local line
    if num == 1 then
        line = string.format(FOR_SPECIALIZATION or "For %s specialization.", specNames[1])
    elseif num == 2 then
        line = string.format(FOR_OR_SPECIALIZATIONS or "For %s or %s specialization.", specNames[1], specNames[2])
    else
        line = string.format(FOR_SPECIALIZATION or "For %s specialization.", table.concat(specNames, " / "))
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|A:quest-important-available:18:18:0:0|a " .. line, nil, nil, nil, true)
end

-- ─── Highest item level link helper ───────────────────────────────────────────
local function GetHighestItemLink(item)
    if not item then return nil end
    local itemID = item.id

    -- 1. If KeystoneLoot is loaded, use its Upgrade module to get the highest upgrade track link
    if _G.KeystoneLoot and _G.KeystoneLoot.Upgrade and _G.KeystoneLoot.Upgrade.BuildItemLink then
        local ok, klLink = pcall(_G.KeystoneLoot.Upgrade.BuildItemLink, _G.KeystoneLoot.Upgrade, itemID)
        if ok and klLink and klLink ~= ("item:" .. itemID) then
            return klLink
        end
    end

    -- 2. Use the Mythic item link fetched from EJ with EJ_SetDifficulty(23 / 16)
    if item.link then
        return item.link
    end

    return "item:" .. itemID
end

local STAT_KEYS = {
    haste       = { "ITEM_MOD_HASTE_RATING_SHORT", "ITEM_MOD_HASTE_RATING", "ITEM_MOD_HASTE" },
    crit        = { "ITEM_MOD_CRIT_RATING_SHORT", "ITEM_MOD_CRIT_RATING", "ITEM_MOD_CRIT" },
    mastery     = { "ITEM_MOD_MASTERY_RATING_SHORT", "ITEM_MOD_MASTERY_RATING", "ITEM_MOD_MASTERY" },
    versatility = { "ITEM_MOD_VERSATILITY", "ITEM_MOD_VERSATILITY_RATING" },
}

local function ItemHasStat(item, statKey)
    if not item then return false end
    if not item._stats then
        item._stats = {}
    end
    if item._stats[statKey] ~= nil then
        return item._stats[statKey]
    end

    local link = GetHighestItemLink(item) or item.link or (item.id and ("item:" .. item.id))
    if not link then
        return false
    end

    -- 1. Check C_Item.GetItemStats
    local stats = (C_Item and C_Item.GetItemStats and C_Item.GetItemStats(link)) or (GetItemStats and GetItemStats(link))
    local modKeys = STAT_KEYS[statKey]
    if stats and modKeys then
        for _, k in ipairs(modKeys) do
            if stats[k] and stats[k] > 0 then
                item._stats[statKey] = true
                return true
            end
        end
    end

    -- 2. Tooltip fallback (for gems, special items, or before stats table is populated)
    local tooltipData = C_TooltipInfo and (C_TooltipInfo.GetHyperlink(link) or (item.id and C_TooltipInfo.GetItemByID(item.id)))
    if tooltipData and tooltipData.lines then
        local globalKey = "ITEM_MOD_" .. string.upper(statKey) .. "_RATING_SHORT"
        if statKey == "versatility" then
            globalKey = "ITEM_MOD_VERSATILITY"
        end
        local localizedStatName = _G[globalKey]
        for _, line in ipairs(tooltipData.lines) do
            local text = line.leftText
            if text and type(text) == "string" then
                if localizedStatName and localizedStatName ~= "" and text:find(localizedStatName, 1, true) then
                    item._stats[statKey] = true
                    return true
                end
                if statKey == "haste" and text:find("Haste", 1, true) then item._stats[statKey] = true ; return true end
                if statKey == "crit" and (text:find("Critical Strike", 1, true) or text:find("Crit", 1, true)) then item._stats[statKey] = true ; return true end
                if statKey == "mastery" and text:find("Mastery", 1, true) then item._stats[statKey] = true ; return true end
                if statKey == "versatility" and (text:find("Versatility", 1, true) or text:find("Vers", 1, true)) then item._stats[statKey] = true ; return true end
            end
        end
    end

    if stats or (tooltipData and tooltipData.lines and #tooltipData.lines > 1) then
        item._stats[statKey] = false
    end
    return false
end

local function SetupItemButton(b, curItem, keyID, isBoss, card)
    local itemID = curItem.id

    -- Icon: prefer what EJ gave us, fall back to C_Item
    local iconTex = curItem.icon
    if not iconTex or iconTex == 0 then
        iconTex = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
    end
    b.tex:SetTexture(iconTex and iconTex ~= 0 and iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")

    InitPlayerSpecs()
    local maxSpecs = #playerSpecIDs > 0 and #playerSpecIDs or (GetNumSpecializations and GetNumSpecializations()) or 3
    local singleSpecID = nil
    local specCount = 0
    if curItem.specs then
        for sID, v in pairs(curItem.specs) do
            if v then
                specCount = specCount + 1
                singleSpecID = sID
            end
        end
    end

    CreateButtonBorders(b)
    if specCount == 1 and singleSpecID then
        local r, g, bl = GetSpecColor(singleSpecID)
        for _, border in ipairs(b.borders) do
            border:SetVertexColor(r or 0.64, g or 0.21, bl or 0.93, 1)
            border:Show()
        end
    elseif specCount > 1 and specCount < maxSpecs then
        for _, border in ipairs(b.borders) do
            border:SetVertexColor(1, 1, 1, 1)
            border:Show()
        end
    else
        for _, border in ipairs(b.borders) do
            border:Hide()
        end
    end
    b:SetBackdropBorderColor(0, 0, 0, 0)

    -- Stat highlight glow using sfui.glows (all selected stats must match)
    local activeCount = 0
    local matchCount = 0
    local matchedColor = nil

    for statKey, isActive in pairs(highlightStats) do
        if isActive then
            activeCount = activeCount + 1
            if ItemHasStat(curItem, statKey) then
                matchCount = matchCount + 1
                matchedColor = STAT_COLORS[statKey]
            end
        end
    end

    if activeCount > 0 and matchCount == activeCount and sfui.glows and sfui.glows.start_glow then
        local glowColor = (activeCount > 1) and { 1.0, 0.85, 0.2, 1.0 } or (matchedColor or { 1.0, 0.85, 0.2, 1.0 })
        sfui.glows.start_glow(b, {
            glowType      = "pixel",
            glowColor     = glowColor,
            glowLines     = 6,
            glowThickness = 2,
            glowSpeed     = 0.35,
        })
    else
        if sfui.glows and sfui.glows.stop_glow then
            sfui.glows.stop_glow(b)
        end
    end

    local badgeText = GetItemBadgeText(curItem)
    b.badge:SetText(badgeText)
    b.badge:SetTextColor(1, 1, 1, 1)

    b:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local bestLink = GetHighestItemLink(curItem)
        if bestLink then
            GameTooltip:SetHyperlink(bestLink)
        else
            GameTooltip:SetItemByID(itemID)
        end
        AddSpecLinesToTooltip(curItem)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    b:SetScript("OnClick", function(_, mouseBtn)
        local bestLink = GetHighestItemLink(curItem)
        if mouseBtn == "LeftButton" then
            if IsModifiedClick("CHATLINK") and bestLink then
                ChatEdit_InsertLink(bestLink)
                return
            elseif IsModifiedClick("DRESSUP") and bestLink then
                DressUpItemLink(bestLink)
                return
            end
        elseif mouseBtn == "RightButton" then
            -- Right-click: advance loot spec one step for this boss/dungeon
            local db  = DB()
            local cur = 0
            if isBoss then
                local e = db.bosses[keyID]
                cur = (type(e) == "table" and e.spec) or (type(e) == "number" and e) or 0
            else
                cur = (db.dungeons and db.dungeons[keyID]) or 0
            end
            local nxt = CycleSpec(cur)
            if isBoss then
                local e = db.bosses[keyID]
                if type(e) ~= "table" then
                    e = { spec = (type(e) == "number" and e or 0) }
                    db.bosses[keyID] = e
                end
                e.spec = nxt
            else
                db.dungeons = db.dungeons or {}
                db.dungeons[keyID] = nxt
            end
            card.specBtn:Refresh()
        end
    end)
end

-- ─── Card population ──────────────────────────────────────────────────────────

local function PopulateCard(card, entry, keyID, isBoss, parentName)
    local loot = entry.loot or {}

    local tex = entry.icon or entry.texture
    if tex and tex ~= 0 then
        card.portrait:SetTexture(tex)
        card.portrait:Show()
    else
        card.portrait:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        card.portrait:Show()
    end

    card.nameFS:SetText(entry.name or "")

    card.specBtn.keyID  = keyID
    card.specBtn.isBoss = isBoss
    card.specBtn:Refresh()
    card.specBtn:Show()

    local strip  = card.iconStrip
    local stripW = SCROLL_W - STRIP_LEFT - PAD * 2 - 6
    strip:SetPoint("TOPLEFT",  STRIP_LEFT, -4)
    strip:SetPoint("TOPRIGHT", -PAD,       -4)
    strip:SetHeight(1)

    local x, y, count = 0, 0, 0
    local lineH = ICON_SZ + ICON_PAD
    local iconsPerRow = math.max(1, math.floor(stripW / (ICON_SZ + ICON_PAD)))

    for _, item in ipairs(loot) do
        if MatchesFilter(item, entry.name, parentName) then
            if x + ICON_SZ > stripW and x > 0 then
                x = 0
                y = y - lineH
            end
            local b = AcquireIconBtn(strip)
            b:SetSize(ICON_SZ, ICON_SZ)
            b:SetPoint("TOPLEFT", strip, "TOPLEFT", x, y)
            SetupItemButton(b, item, keyID, isBoss, card)
            x = x + ICON_SZ + ICON_PAD
            count = count + 1
        end
    end

    if count == 0 then
        if filterSpec ~= 0 and filterSlot ~= "all" then
            local sInfo = playerSpecs[filterSpec]
            local sName = sInfo and sInfo.name:lower() or "spec"
            card.noLootFS:SetText("— no " .. sName .. " " .. (SLOT_NAMES[filterSlot] or filterSlot):lower() .. " drops —")
        elseif filterSpec ~= 0 then
            local sInfo = playerSpecs[filterSpec]
            local sName = sInfo and sInfo.name:lower() or "spec"
            card.noLootFS:SetText("— no " .. sName .. " drops —")
        elseif filterSlot ~= "all" then
            card.noLootFS:SetText("— no " .. (SLOT_NAMES[filterSlot] or filterSlot):lower() .. " drops —")
        else
            card.noLootFS:SetText("— no loot entries —")
        end
        card.noLootFS:Show()
    else
        card.noLootFS:Hide()
    end

    local rowsUsed = (count > 0) and math.ceil(count / iconsPerRow) or 0
    local stripH   = (count > 0) and (rowsUsed * lineH) or 0
    strip:SetHeight(math.max(stripH, 1))
    card:SetHeight(math.max(ROW_H, stripH + 12))
    return card:GetHeight()
end

-- ─── Section header pool ─────────────────────────────────────────────────────
-- FontStrings/Textures on scrollChild can't be destroyed; pool and reuse them.
local hdrPool      = {}  -- FontStrings
local sepPool      = {}  -- Textures
local hdrPoolCount = 0
local sepPoolCount = 0

local function AcquireHdr(parent)
    hdrPoolCount = hdrPoolCount + 1
    local fs = hdrPool[hdrPoolCount]
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hdrPool[hdrPoolCount] = fs
    end
    fs:Show()
    return fs
end

local function AcquireSep(parent)
    sepPoolCount = sepPoolCount + 1
    local tx = sepPool[sepPoolCount]
    if not tx then
        tx = parent:CreateTexture(nil, "ARTWORK")
        tx:SetHeight(1)
        tx:SetColorTexture(0.25, 0.0, 0.6, 0.5)
        sepPool[sepPoolCount] = tx
    end
    tx:Show()
    return tx
end

local function ReleaseHdrSep()
    for i = 1, hdrPoolCount do if hdrPool[i] then hdrPool[i]:Hide() end end
    for i = 1, sepPoolCount  do if sepPool[i]  then sepPool[i]:Hide()  end end
    hdrPoolCount = 0
    sepPoolCount = 0
end

-- ─── Content builders ─────────────────────────────────────────────────────────

local function BossMatchesSearch(boss, instanceName)
    if filterSearch == "" then return true end
    if instanceName and string.find(string.lower(instanceName), filterSearch, 1, true) then
        return true
    end
    if boss.name and string.find(string.lower(boss.name), filterSearch, 1, true) then
        return true
    end
    if boss.loot then
        for _, item in ipairs(boss.loot) do
            if item.name and string.find(string.lower(item.name), filterSearch, 1, true) then
                return true
            end
            if item.bossName and string.find(string.lower(item.bossName), filterSearch, 1, true) then
                return true
            end
        end
    end
    if boss.bosses then
        for _, b in ipairs(boss.bosses) do
            if b.name and string.find(string.lower(b.name), filterSearch, 1, true) then
                return true
            end
        end
    end
    return false
end

local function PlaceCards(scrollChild, entries, isBoss, y, parentName)
    for _, entry in ipairs(entries) do
        local keyID   = isBoss and entry.encounterID or entry.mapID
        local nameOk  = BossMatchesSearch(entry, parentName)
        if nameOk then
            local card = AcquireCard(scrollChild)
            card:SetPoint("TOPLEFT", 0, y)
            card:SetWidth(SCROLL_W - 4)
            local cardH = PopulateCard(card, entry, keyID, isBoss, parentName)
            y = y - cardH - PAD
        end
    end
    return y
end

local function RebuildContent(scrollChild, tab)
    ReleaseCards()
    ReleaseHdrSep()

    local y = -PAD

    if tab == "dungeons" then
        local data = GetDungeonData()
        if #data == 0 then
            scrollChild:SetHeight(60)
            return
        end
        y = PlaceCards(scrollChild, data, false, y)
    else -- raids
        local data = GetRaidData()
        if #data == 0 then
            scrollChild:SetHeight(60)
            return
        end
        for _, raid in ipairs(data) do
            local bosses = raid.bosses or {}

            local hasMatch = false
            if filterSearch == "" then
                hasMatch = true
            else
                for _, b in ipairs(bosses) do
                    if BossMatchesSearch(b, raid.name) then
                        hasMatch = true
                        break
                    end
                end
            end

            if hasMatch then
                local hdr = AcquireHdr(scrollChild)
                hdr:ClearAllPoints()
                hdr:SetPoint("TOPLEFT", PAD, y)
                hdr:SetText("|cff9966ff" .. raid.name .. "|r")
                y = y - 22

                local sep = AcquireSep(scrollChild)
                sep:ClearAllPoints()
                sep:SetPoint("TOPLEFT",  0, y + 2)
                sep:SetPoint("TOPRIGHT", 0, y + 2)

                y = PlaceCards(scrollChild, bosses, true, y, raid.name)
                y = y - PAD
            end
        end
    end

    scrollChild:SetHeight(math.max(-y + PAD, 1))
end

-- ─── Main frame ───────────────────────────────────────────────────────────────
local frame           = nil
local activeTab       = "dungeons"
local scrollChild_ref = nil
local RefreshDefBtn   = nil
local enableCB_ref    = nil

local function DoRebuild()
    if frame and frame:IsShown() and scrollChild_ref then
        RebuildContent(scrollChild_ref, activeTab)
    end
end

function sfui.lootviewer.CreateFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "SfuiLootViewerFrame", UIParent, "BackdropTemplate")
    table.insert(UISpecialFrames, "SfuiLootViewerFrame")
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)

    local mult   = sfui.pixelScale or 1
    local app    = sfui.config and sfui.config.appearance
    local bgCol  = (app and app.backdropColor)  or { 0.04, 0.04, 0.05, 0.97 }
    local gray   = (sfui.config and sfui.config.colors and sfui.config.colors.gray) or { 0.2, 0.2, 0.2 }
    local purple = (app and app.highlightColor) or { 0.4, 0.0, 1.0 }

    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = mult,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    frame:SetBackdropColor(bgCol[1], bgCol[2], bgCol[3], bgCol[4] or 0.95)
    frame:SetBackdropBorderColor(gray[1], gray[2], gray[3], 1)

    local function MkBtn(parent, text, width, height)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(width, height)
        btn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = mult,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        btn:SetBackdropColor(0, 0, 0, 1)
        btn:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.8)

        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetText(text)
        local fs = btn:GetFontString()
        if fs then
            fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
            fs:SetTextColor(1, 1, 1, 1)
        end
        btn.text = fs
        return btn
    end

    -- ── Title + close ────────────────────────────────────────────────────────
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("|cff6600ffsfui|r loot & spec browser")

    local closeBtn = sfui.common.create_flat_button(frame, "✕", 20, 20)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- ── Slot filter row ───────────────────────────────────────────────────────
    local filterY = -32

    local slotOptions = {
        { text = "All Slots",   value = "all" },
        { text = "Trinket",     value = "trinket" },
        { text = "Weapon",      value = "weapon" },
        { text = "Ring",        value = "ring" },
        { text = "Neck",        value = "neck" },
        { text = "Back",        value = "back" },
        { text = "Head",        value = "head" },
        { text = "Shoulder",    value = "shoulder" },
        { text = "Chest",       value = "chest" },
        { text = "Wrist",       value = "wrist" },
        { text = "Hands",       value = "hands" },
        { text = "Waist",       value = "waist" },
        { text = "Legs",        value = "legs" },
        { text = "Feet",        value = "feet" },
        { text = "Other",       value = "other" },
    }

    local slotDropdown = sfui.common.create_dropdown(frame, 100, slotOptions, function(val)
        filterSlot = val
        DoRebuild()
    end, "all", nil, 80)
    slotDropdown:SetPoint("TOPLEFT", 44, filterY)
    if slotDropdown.menu then
        slotDropdown.menu:ClearAllPoints()
        slotDropdown.menu:SetPoint("TOPLEFT", slotDropdown, "BOTTOMLEFT", 0, -2)
    end

    local slotLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slotLabel:SetPoint("RIGHT", slotDropdown, "LEFT", -6, 0)
    slotLabel:SetText("slot:")
    slotLabel:SetTextColor(0.4, 0.4, 0.4, 1)

    -- ── Default spec toggle ──────────────────────────────────────────────────
    local defLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    defLabel:SetPoint("LEFT", slotDropdown, "RIGHT", 14, 0)
    defLabel:SetText("default:")
    defLabel:SetTextColor(0.4, 0.4, 0.4, 1)

    local defBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    defBtn:SetSize(110, 18)
    defBtn:SetPoint("LEFT", defLabel, "RIGHT", 6, 0)
    defBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = mult,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    defBtn:SetBackdropColor(0.05, 0.05, 0.05, 1)
    defBtn:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.8)

    local defIcon = defBtn:CreateTexture(nil, "ARTWORK")
    defIcon:SetSize(14, 14)
    defIcon:SetPoint("LEFT", 3, 0)
    defIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local defLbl = defBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    defLbl:SetPoint("LEFT", defIcon, "RIGHT", 4, 0)
    defLbl:SetPoint("RIGHT", defBtn, "RIGHT", -2, 0)
    defLbl:SetJustifyH("LEFT")

    RefreshDefBtn = function()
        local specID = DB().defaultSpec or 0
        if specID == 0 then
            defIcon:Hide()
            defLbl:ClearAllPoints()
            defLbl:SetPoint("LEFT", defBtn, "LEFT", 6, 0)
            defLbl:SetPoint("RIGHT", defBtn, "RIGHT", -2, 0)
            defLbl:SetText("current spec")
            defLbl:SetTextColor(0.35, 0.35, 0.35, 1)
        else
            local icon = SpecIcon(specID)
            if icon then
                defIcon:SetTexture(icon)
                defIcon:Show()
                defLbl:ClearAllPoints()
                defLbl:SetPoint("LEFT", defIcon, "RIGHT", 4, 0)
                defLbl:SetPoint("RIGHT", defBtn, "RIGHT", -2, 0)
            else
                defIcon:Hide()
                defLbl:ClearAllPoints()
                defLbl:SetPoint("LEFT", defBtn, "LEFT", 6, 0)
                defLbl:SetPoint("RIGHT", defBtn, "RIGHT", -2, 0)
            end
            local r, g, b = GetSpecColor(specID)
            defLbl:SetTextColor(r, g, b, 1)
            defLbl:SetText(SpecName(specID))
        end
    end

    defBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    defBtn:SetScript("OnClick", function(_, btn)
        local db = DB()
        db.defaultSpec = (btn == "RightButton") and 0 or CycleSpec(db.defaultSpec or 0)
        RefreshDefBtn()
    end)
    defBtn:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("spec restored after boss loot")
            GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle", 1, 1, 1)
            GameTooltip:AddLine("|cffaaaaaaright-click|r to reset to current spec", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    defBtn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- ── Auto-swap toggle ─────────────────────────────────────────────────────
    local enableCB = sfui.common.create_checkbox(frame, "auto-swap",
        function() return DB().enabled end,
        function(val) DB().enabled = val end,
        "enable/disable automatic loot spec swaps")
    enableCB:SetSize(14, 14)
    enableCB:SetPoint("LEFT", defBtn, "RIGHT", 14, 0)
    if enableCB.text then
        enableCB.text:SetFontObject("GameFontNormalSmall")
        enableCB.text:SetTextColor(0.4, 0.4, 0.4, 1)
    end
    enableCB_ref = enableCB

    -- Search box
    local searchBox = CreateFrame("EditBox", "SfuiLootViewerSearch", frame, "BackdropTemplate")
    searchBox:SetSize(130, 18)
    searchBox:SetPoint("TOPRIGHT", -30, filterY)
    searchBox:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = mult,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    searchBox:SetBackdropColor(0.08, 0.08, 0.08, 1)
    searchBox:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.8)
    searchBox:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    searchBox:SetTextColor(0.85, 0.85, 0.85, 1)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(40)
    searchBox:SetTextInsets(4, 4, 2, 2)
    searchBox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(purple[1], purple[2], purple[3], 1)
    end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.8)
    end)

    local searchHint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchHint:SetPoint("RIGHT", searchBox, "LEFT", -3, 0)
    searchHint:SetText("search:")
    searchHint:SetTextColor(0.4, 0.4, 0.4, 1)

    searchBox:SetScript("OnTextChanged", function(self)
        filterSearch = string.lower(self:GetText() or "")
        DoRebuild()
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("") ; self:ClearFocus()
    end)

    -- ── Tabs ─────────────────────────────────────────────────────────────────
    local tabY    = filterY - 24
    local tabDung = MkBtn(frame, "Mythic+ Dungeons", 130, 20)
    local tabRaid = MkBtn(frame, "Raids", 68, 20)
    tabDung:SetPoint("TOPLEFT", 10, tabY)
    tabRaid:SetPoint("LEFT", tabDung, "RIGHT", 4, 0)

    local sepTex = frame:CreateTexture(nil, "ARTWORK")
    sepTex:SetHeight(1)
    sepTex:SetPoint("TOPLEFT",  0, tabY - 24)
    sepTex:SetPoint("TOPRIGHT", 0, tabY - 24)
    sepTex:SetColorTexture(purple[1] * 0.5, purple[2] * 0.5, purple[3] * 0.5, 0.5)

    -- ── Spec filter row (all specs / per-spec) ───────────────────────────────
    InitPlayerSpecs()
    local specLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    specLabel:SetPoint("LEFT", tabRaid, "RIGHT", 14, 0)
    specLabel:SetText("spec:")
    specLabel:SetTextColor(0.4, 0.4, 0.4, 1)

    local specBtns = {}
    local allSpecBtn = MkBtn(frame, "All Specs", 64, 20)
    allSpecBtn:SetPoint("LEFT", specLabel, "RIGHT", 4, 0)
    allSpecBtn._specID = 0
    specBtns[#specBtns + 1] = allSpecBtn

    local prevBtn = allSpecBtn
    for _, sID in ipairs(playerSpecIDs) do
        local sInfo = playerSpecs[sID]
        if sInfo then
            local name = sInfo.name or ("Spec " .. sID)
            local w = math.max(48, #name * 6 + 14)
            local sb = MkBtn(frame, name, w, 20)
            sb:SetPoint("LEFT", prevBtn, "RIGHT", 3, 0)
            sb._specID = sID
            specBtns[#specBtns + 1] = sb
            prevBtn = sb
        end
    end

    local function RefreshSpecBtns()
        for _, b in ipairs(specBtns) do
            local active = (b._specID == filterSpec)
            if active then
                b:SetBackdropColor(purple[1] * 0.35, purple[2] * 0.35, purple[3] * 0.35, 1)
                b:SetBackdropBorderColor(purple[1], purple[2], purple[3], 1)
            else
                b:SetBackdropColor(0.0, 0.0, 0.0, 1)
                b:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.8)
            end
        end
    end

    for _, b in ipairs(specBtns) do
        local sID = b._specID
        b:SetScript("OnClick", function()
            filterSpec = sID
            RefreshSpecBtns()
            DoRebuild()
        end)
    end

    -- ── Stat highlight toggles (inline of spec filter) ───────────────────────
    local statLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statLabel:SetPoint("LEFT", prevBtn, "RIGHT", 14, 0)
    statLabel:SetText("stats:")
    statLabel:SetTextColor(0.4, 0.4, 0.4, 1)

    local statDefs = {
        { key = "haste",       label = "Haste",   color = STAT_COLORS.haste },
        { key = "crit",        label = "Crit",    color = STAT_COLORS.crit },
        { key = "mastery",     label = "Mastery", color = STAT_COLORS.mastery },
        { key = "versatility", label = "Vers",    color = STAT_COLORS.versatility },
    }

    local statBtns = {}
    local prevStat = statLabel
    for _, def in ipairs(statDefs) do
        local sb = MkBtn(frame, def.label, 48, 20)
        sb:SetPoint("LEFT", prevStat, "RIGHT", 3, 0)
        sb._statKey = def.key
        sb._color   = def.color
        statBtns[#statBtns + 1] = sb
        prevStat = sb

        local k = def.key
        local col = def.color
        sb:SetScript("OnClick", function()
            highlightStats[k] = not highlightStats[k]
            if highlightStats[k] then
                sb:SetBackdropColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 1)
                sb:SetBackdropBorderColor(col[1], col[2], col[3], 1)
                if sb.text then sb.text:SetTextColor(col[1], col[2], col[3], 1) end
            else
                sb:SetBackdropColor(0.0, 0.0, 0.0, 1)
                sb:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.8)
                if sb.text then sb.text:SetTextColor(1, 1, 1, 1) end
            end
            DoRebuild()
        end)
    end

    local function RefreshTabs()
        local isDung = (activeTab == "dungeons")
        local dR, dG, dB = isDung and (purple[1] * 0.35) or 0.0, isDung and (purple[2] * 0.35) or 0.0, isDung and (purple[3] * 0.35) or 0.0
        local rR, rG, rB = (not isDung) and (purple[1] * 0.35) or 0.0, (not isDung) and (purple[2] * 0.35) or 0.0, (not isDung) and (purple[3] * 0.35) or 0.0
        tabDung:SetBackdropColor(dR, dG, dB, 1)
        tabDung:SetBackdropBorderColor(isDung and purple[1] or gray[1], isDung and purple[2] or gray[2], isDung and purple[3] or gray[3], isDung and 1 or 0.8)
        tabRaid:SetBackdropColor(rR, rG, rB, 1)
        tabRaid:SetBackdropBorderColor((not isDung) and purple[1] or gray[1], (not isDung) and purple[2] or gray[2], (not isDung) and purple[3] or gray[3], (not isDung) and 1 or 0.8)
    end

    tabDung:SetScript("OnClick", function() activeTab = "dungeons" ; RefreshTabs() ; DoRebuild() end)
    tabRaid:SetScript("OnClick", function() activeTab = "raids"    ; RefreshTabs() ; DoRebuild() end)

    -- ── Scroll frame ──────────────────────────────────────────────────────────
    local CONTENT_Y = tabY - 28

    local sf = CreateFrame("ScrollFrame", "SfuiLootViewerScroll", frame, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     4, CONTENT_Y)
    sf:SetPoint("BOTTOMRIGHT", -24, 4)
    sf:EnableMouseWheel(true)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(SCROLL_W - 4)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    scrollChild_ref   = sc
    frame.scrollChild = sc
    frame.scrollFrame = sf

    -- ── Footer hint ───────────────────────────────────────────────────────────
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", 10, 8)
    hint:SetText("hover: tooltip  ·  right-click item: cycle loot spec  ·  click badge: cycle spec  ·  right-click badge: clear")
    hint:SetTextColor(0.22, 0.22, 0.22, 1)

    frame:SetScript("OnShow", function()
        filterSlot   = "all"
        filterSpec   = 0
        filterSearch = ""
        searchBox:SetText("")
        activeTab = "dungeons"
        RefreshTabs()
        RefreshSpecBtns()
        if RefreshDefBtn then RefreshDefBtn() end
        if enableCB_ref and enableCB_ref.SetChecked then
            enableCB_ref:SetChecked(DB().enabled)
        end
        if slotDropdown and slotDropdown.SetSelectedValue then
            slotDropdown:SetSelectedValue("all")
        elseif slotDropdown and slotDropdown.GetFontString and slotDropdown:GetFontString() then
            slotDropdown:GetFontString():SetText("All Slots")
        end
        DoRebuild()
    end)

    frame:HookScript("OnHide", function()
        if slotDropdown and slotDropdown.menu and slotDropdown.menu:IsShown() then
            slotDropdown.menu:Hide()
        end
    end)

    frame:Hide()
    sfui.lootviewer.frame = frame
    return frame
end

function sfui.lootviewer.Toggle()
    if not frame then frame = sfui.lootviewer.CreateFrame() end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function sfui.lootviewer.Rebuild()
    DoRebuild()
end

function sfui.lootviewer.initialize()
    -- lazy — frame created on first Toggle()
end

-- ─── Spec change invalidation ─────────────────────────────────────────────────
sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
    if RefreshDefBtn then RefreshDefBtn() end
    if frame and frame:IsShown() then DoRebuild() end
end)

local itemDataTimer = nil
sfui.events.RegisterEvent("ITEM_DATA_LOAD_RESULT", function(_, itemID, success)
    if success and frame and frame:IsShown() then
        if not itemDataTimer then
            itemDataTimer = C_Timer.NewTimer(0.15, function()
                itemDataTimer = nil
                if frame and frame:IsShown() then
                    DoRebuild()
                end
            end)
        end
    end
end)

-- ─── Diagnostics & Memory Watcher Telemetry ──────────────────────────────────
local _lvDebug = {}
function sfui.lootviewer_debug_info()
    _lvDebug.frameCreated    = frame ~= nil
    _lvDebug.frameShown      = (frame and frame:IsShown()) and true or false
    _lvDebug.activeTab       = activeTab or "none"
    _lvDebug.cardPoolTotal   = #cardPool
    _lvDebug.cardPoolActive  = cardPoolCount
    _lvDebug.iconPoolTotal   = #iconPool
    _lvDebug.iconPoolActive  = iconPoolCount
    _lvDebug.hasRaidCache    = raidDataCache ~= nil
    _lvDebug.hasDungeonCache = dungeonDataCache ~= nil
    _lvDebug.filterSpec      = filterSpec or 0
    _lvDebug.filterSlot      = filterSlot or "all"
    return _lvDebug
end
sfui.lootviewer.debug_info = sfui.lootviewer_debug_info

