local addonName, addon = ...
sfui.highest = {}

-- BoE items: track last attempt time so we don't spam the bind dialog
local boeAttemptedAt = {}
local BOE_RETRY_DELAY = 30 -- seconds before re-offering the bind dialog

local _G = _G
local GetItemInfo = _G.GetItemInfo
local GetDetailedItemLevelInfo = _G.GetDetailedItemLevelInfo
local GetItemInfoInstant = _G.GetItemInfoInstant
local C_Item = _G.C_Item
local GetItemStats = (C_Item and C_Item.GetItemStats) or _G.GetItemStats
local C_TooltipInfo = _G.C_TooltipInfo
local GetSpecialization = _G.GetSpecialization
local GetSpecializationInfo = _G.GetSpecializationInfo
local GetInventoryItemLink = _G.GetInventoryItemLink
local C_Container = _G.C_Container
local EquipItemByName = _G.EquipItemByName
local tonumber = _G.tonumber
local UnitLevel = _G.UnitLevel
local pairs = _G.pairs
local ipairs = _G.ipairs
local print = _G.print
local string = _G.string
local table = _G.table

-- Cached print helper — avoids repeated nil-checks on sfui.common.print throughout
local function sfprint(msg)
    if sfui.common and sfui.common.print then
        sfui.common.print(msg)
    else
        print("|cff6600ffsfui:|r " .. msg)
    end
end

-- Debug helper: set _G.SFUI_DEBUG_SLOT = <inventory slot number> in-game
-- to see a full score/validation breakdown for that slot.
-- Example: /run SFUI_DEBUG_SLOT = 3   (shoulders)
local function dbgSlotPrint(msg)
    sfprint("|cffffff00[SFUI DBG]|r " .. tostring(msg))
end


local STAT_MAP = {
    [1] = "ITEM_MOD_STRENGTH_SHORT",
    [2] = "ITEM_MOD_AGILITY_SHORT",
    [4] = "ITEM_MOD_INTELLECT_SHORT",
}

sfui.highest.rules = {
    -- Death Knight
    [250] = { armor = 4, stat = 1, weaps = { ["2H"] = true } },
    [251] = { armor = 4, stat = 1, weaps = { ["2H"] = true, ["1H_Dual"] = true } },
    [252] = { armor = 4, stat = 1, weaps = { ["2H"] = true } },
    -- Demon Hunter
    [577] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true } },
    [581] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true } },
    [1480] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true } },
    -- Druid
    [102] = { armor = 2, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [103] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [104] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [105] = { armor = 2, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    -- Evoker
    [1467] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [1468] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [1473] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    -- Hunter
    [253] = { armor = 3, stat = 2, weaps = { ["Ranged"] = true } },
    [254] = { armor = 3, stat = 2, weaps = { ["Ranged"] = true } },
    [255] = { armor = 3, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true } },
    -- Mage
    [62] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [63] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [64] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    -- Monk
    [268] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true } },
    [269] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true } },
    [270] = { armor = 2, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    -- Paladin
    [65] = { armor = 4, stat = 4, weaps = { ["2H"] = true, ["1H_Shield"] = true } },
    [66] = { armor = 4, stat = 1, weaps = { ["1H_Shield"] = true } },
    [70] = { armor = 4, stat = 1, weaps = { ["2H"] = true } },
    -- Priest
    [256] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [257] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [258] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    -- Rogue
    [259] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true } },
    [260] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true } },
    [261] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true } },
    -- Shaman
    [262] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Shield"] = true } },
    [263] = { armor = 3, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true } },
    [264] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Shield"] = true } },
    -- Warlock
    [265] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [266] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [267] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    -- Warrior
    [71] = { armor = 4, stat = 1, weaps = { ["2H"] = true } },
    [72] = { armor = 4, stat = 1, weaps = { ["2H_Dual"] = true, ["1H_Dual"] = true } },
    [73] = { armor = 4, stat = 1, weaps = { ["1H_Shield"] = true } }
}

-- Checks if the item matches the primary stat
local function HasPrimaryStat(itemLink, primaryStatName)
    local stats = C_Item.GetItemStats(itemLink)
    if not stats then return false end

    -- Fast-path mathematically sound API match
    if stats[primaryStatName] then return true end

    -- Tooltip Fallback Check for Deceptive Base Items
    -- (Items like event staves drop dynamically modified to intellect, but the base API forcibly returns agility)
    local tooltipData = C_TooltipInfo and C_TooltipInfo.GetHyperlink(itemLink)
    if tooltipData and tooltipData.lines then
        local primaryString = ""
        if primaryStatName == "ITEM_MOD_INTELLECT_SHORT" then
            primaryString = "Intellect"
        elseif primaryStatName == "ITEM_MOD_AGILITY_SHORT" then
            primaryString = "Agility"
        elseif primaryStatName == "ITEM_MOD_STRENGTH_SHORT" then
            primaryString = "Strength"
        end

        if primaryString ~= "" then
            for _, line in ipairs(tooltipData.lines) do
                local text = line.leftText
                if text and type(text) == "string" then
                    -- If the dynamic tooltip clearly broadcasts the primary stat, we know it's there
                    if text:find(primaryString, 1, true) then
                        return true
                    end
                end
            end
        end
    end

    -- If there's literally NO primary stats on the item, we allow it (generic trinkets/rings)
    -- We restrict this bypass to non-weapons, so casters don't equip old classic weapons equipped with only stamina/haste
    local classID = select(6, GetItemInfoInstant(itemLink))
    if classID ~= 2 then
        local hasAnyPrimary = stats["ITEM_MOD_STRENGTH_SHORT"] or stats["ITEM_MOD_AGILITY_SHORT"] or
            stats["ITEM_MOD_INTELLECT_SHORT"]
        if not hasAnyPrimary then return true end
    end

    return false
end


local function GetPrimaryStatValue(itemLink, primaryStatName)
    local stats = C_Item.GetItemStats(itemLink)
    if not stats then return 0 end
    return stats[primaryStatName] or 0
end

local pvpIlvlCache = {}
local pvpIlvlCacheCount = 0
local PVP_CACHE_MAX = 200

local function pvpCacheSet(link, val)
    if not pvpIlvlCache[link] then
        pvpIlvlCacheCount = pvpIlvlCacheCount + 1
        if pvpIlvlCacheCount > PVP_CACHE_MAX then
            -- Evict: wipe and restart
            pvpIlvlCache = {}
            pvpIlvlCacheCount = 1
        end
    end
    pvpIlvlCache[link] = val
end

-- Returns true, itemLevel, statVal, itemEquipLoc if the item is valid for the spec rules
function sfui.highest.IsItemValidForSpec(itemLink, specID)
    local rule = sfui.highest.rules[specID]
    if not rule then return false end

    -- Dynamic Frost DK Talent Overrides
    if specID == 251 then
        local frostbane = IsPlayerSpell(455993)
        rule = { armor = rule.armor, stat = rule.stat, weaps = { ["1H_Dual"] = frostbane, ["2H"] = not frostbane } }
    end

    local primaryStatName = STAT_MAP[rule.stat]
    local optimalArmor = rule.armor

    local itemID, itemType, itemSubType, itemEquipLoc, _, classID, subclassID = GetItemInfoInstant(itemLink)
    if not itemEquipLoc or itemEquipLoc == "" then return false end

    local itemName, _, itemQuality, baseLevel, itemMinLevel = GetItemInfo(itemLink)
    local itemLevel = GetDetailedItemLevelInfo(itemLink) or baseLevel or 1

    -- Never auto-equip grey (0) or white (1) quality items — these are cosmetic,
    -- transmog pieces, or vendor junk and should never beat real gear in scoring.
    if itemQuality and itemQuality < 2 then return false end

    -- Check if the player meets the required level for the item
    if itemMinLevel and itemMinLevel > UnitLevel("player") then return false end

    -- Use robust numeric ID checks instead of localized strings. classID 4 = Armor
    if classID == 4 then
        if itemEquipLoc ~= "INVTYPE_CLOAK" and itemEquipLoc ~= "INVTYPE_FINGER" and itemEquipLoc ~= "INVTYPE_TRINKET" and itemEquipLoc ~= "INVTYPE_NECK" and itemEquipLoc ~= "INVTYPE_HOLDABLE" and itemEquipLoc ~= "INVTYPE_SHIELD" then
            if subclassID ~= optimalArmor and subclassID ~= 5 then return false end -- subclassID 5 is Cosmetic
        end
    end

    -- Weapon restriction rules
    if classID == 2 then
        if itemEquipLoc == "INVTYPE_2HWEAPON" or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT" then
            if not rule.weaps["2H"] and not rule.weaps["2H_Dual"] and not rule.weaps["Ranged"] then return false end
        elseif itemEquipLoc == "INVTYPE_WEAPON" or itemEquipLoc == "INVTYPE_WEAPONMAINHAND" then
            if not rule.weaps["1H_Dual"] and not rule.weaps["1H_Off"] and not rule.weaps["1H_Shield"] then return false end
        end
    elseif classID == 4 then
        if itemEquipLoc == "INVTYPE_SHIELD" then
            if not rule.weaps["1H_Shield"] then return false end
        elseif itemEquipLoc == "INVTYPE_HOLDABLE" or itemEquipLoc == "INVTYPE_WEAPONOFFHAND" then
            if not rule.weaps["1H_Off"] and not rule.weaps["1H_Dual"] then return false end
        end
    end

    local isNonDynamicStatPiece = (classID == 2 or itemEquipLoc == "INVTYPE_TRINKET" or itemEquipLoc == "INVTYPE_CLOAK" or itemEquipLoc == "INVTYPE_NECK" or itemEquipLoc == "INVTYPE_FINGER" or itemEquipLoc == "INVTYPE_HOLDABLE" or itemEquipLoc == "INVTYPE_SHIELD")

    if isNonDynamicStatPiece then
        if not HasPrimaryStat(itemLink, primaryStatName) then return false end
    end

    local statVal = GetPrimaryStatValue(itemLink, primaryStatName)
    return true, itemLevel, statVal, itemEquipLoc
end

-- Returns: isUpgrade, isOffSpec
function sfui.highest.EvaluateItemUpgrade(itemLink, overrideIlvl, currentEquippedIlvl)
    if not itemLink then return false, false end
    local specIndex = GetSpecialization()
    if not specIndex then return false, false end
    local activeSpecID = GetSpecializationInfo(specIndex)

    local function CheckSpecUpgrade(specID)
        local isValid, baseIlvl = sfui.highest.IsItemValidForSpec(itemLink, specID)
        if not isValid then return false end

        local itemLevel = overrideIlvl or baseIlvl
        local effectiveILvl = GetDetailedItemLevelInfo(itemLink)
        if effectiveILvl and not overrideIlvl then itemLevel = effectiveILvl end

        -- Tooltip override for heavily scaled Event/Timewalking items
        if not overrideIlvl and C_TooltipInfo and C_TooltipInfo.GetHyperlink then
            local tooltipData = C_TooltipInfo.GetHyperlink(itemLink)
            if tooltipData and tooltipData.lines then
                for _, line in ipairs(tooltipData.lines) do
                    local text = line.leftText
                    if text and type(text) == "string" then
                        local tVal = tonumber(text:match("Item Level (%d+)"))
                        if tVal and tVal > itemLevel then
                            itemLevel = tVal
                        end
                        if tVal then break end
                    end
                end
            end
        end

        if itemLevel and itemLevel > currentEquippedIlvl then
            return true
        end
        return false
    end

    -- Check Main Spec
    if CheckSpecUpgrade(activeSpecID) then return true, false end

    -- Check Off Specs
    local numSpecs = _G["GetNumSpecializations"] and _G["GetNumSpecializations"]() or 0
    if numSpecs > 1 then
        for i = 1, numSpecs do
            if i ~= specIndex then
                local offSpecID = GetSpecializationInfo(i)
                if CheckSpecUpgrade(offSpecID) then return true, true end
            end
        end
    end
    return false, false
end

-- Scan bags and return a table mapping slotId -> {link, ilvl} of best possible items
function sfui.highest.GetBestItems(isPvP)
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = GetSpecializationInfo(specIndex)
    local rule = sfui.highest.rules[specID]
    if not rule then return nil end

    -- Dynamic Frost DK Talent Overrides
    if specID == 251 then
        local frostbane = IsPlayerSpell(455993) or
            (IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(455993)) or
            (IsSpellKnown and IsSpellKnown(455993))
        rule = { armor = rule.armor, stat = rule.stat, weaps = { ["1H_Dual"] = frostbane, ["2H"] = not frostbane } }
    end

    local primaryStatName = STAT_MAP[rule.stat]
    local optimalArmor = rule.armor

    -- Persistent GC Table Pooling
    sfui.highest.itemDataPool = sfui.highest.itemDataPool or {}
    sfui.highest.pooledBest = sfui.highest.pooledBest or {}
    local itemDataPool = sfui.highest.itemDataPool
    local poolIndex = 0

    local best = sfui.highest.pooledBest
    for i = 1, 19 do
        best[i] = best[i] or {}
        wipe(best[i])
    end

    local pooledTargetSlots = {}
    local evaluateIndex = 0

    local function evaluate(itemLink, isEquipped, slotOverride, bag, slot)
        evaluateIndex = evaluateIndex + 1
        local isValid, baseIlvl, statVal, itemEquipLoc = sfui.highest.IsItemValidForSpec(itemLink, specID)
        if not isValid then return end

        -- Slot lock evaluation (context-aware: PvE / PvP dual tables)
        local isLockedItem = false
        do
            local itemID = GetItemInfoInstant and GetItemInfoInstant(itemLink)
            local specGear = itemID and SfuiDB and SfuiDB.gear and SfuiDB.gear[specID]
            local lockTable = specGear and (isPvP and specGear.locked_items_pvp or specGear.locked_items_pve)
            -- Legacy fallback: old unified locked_items table
            if not lockTable and specGear then lockTable = specGear.locked_items end
            if lockTable and lockTable[itemID] then
                if isEquipped then
                    return -- skip: prevent equipped locked items from being mathematically duplicated into alternate slots
                else
                    isLockedItem = true
                end
            end
        end

        local itemLevel = baseIlvl

        -- Use true effective item level from the server
        local effectiveILvl = GetDetailedItemLevelInfo(itemLink)
        if effectiveILvl then itemLevel = effectiveILvl end

        -- Tooltip override for heavily scaled Event/Timewalking items
        if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
            local tooltipData = C_TooltipInfo.GetHyperlink(itemLink)
            if tooltipData and tooltipData.lines then
                for _, line in ipairs(tooltipData.lines) do
                    local text = line.leftText
                    if text and type(text) == "string" then
                        local tVal = tonumber(text:match("Item Level (%d+)"))
                        if tVal and tVal > itemLevel then
                            itemLevel = tVal
                        end
                        if tVal then break end
                    end
                end
            end
        end

        -- Forcefully bypass sorting priority for locked items sitting in inventory bags
        if isLockedItem then
            itemLevel = 9999
        end

        -- PvP Tooltip parsing for scaled ilvls
        if isPvP then
            local cachedIlvl = pvpIlvlCache[itemLink]
            if cachedIlvl then
                if cachedIlvl > 0 and cachedIlvl > itemLevel then
                    itemLevel = cachedIlvl
                end
            else
                local foundScaling = false
                local tooltipData = C_TooltipInfo.GetHyperlink(itemLink)
                if tooltipData then
                    for _, line in ipairs(tooltipData.lines) do
                        local leftText = line.leftText
                        if leftText then
                            local cleanText = leftText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                            local ltext = cleanText:lower()
                            if ltext:find("level") and (ltext:find("pvp") or ltext:find("arena") or ltext:find("battleground")) then
                                local pvpMatch = cleanText:match("(%d%d%d)")
                                if pvpMatch then
                                    local scaledIlvl = tonumber(pvpMatch)
                                    local maxScaled = (sfui.config and sfui.config.gear and sfui.config.gear.maxScaledILvl) or
                                        1000
                                    if scaledIlvl and scaledIlvl > itemLevel and scaledIlvl < maxScaled then
                                        itemLevel = scaledIlvl
                                        pvpCacheSet(itemLink, scaledIlvl)
                                        foundScaling = true
                                    end
                                end
                            end
                        end
                    end
                end

                if not foundScaling and tooltipData and tooltipData.lines and #tooltipData.lines > 1 then
                    pvpCacheSet(itemLink, -1)
                end
            end
        end

        local numSlots = 0
        if slotOverride then
            numSlots = 1
            pooledTargetSlots[1] = slotOverride
        else
            if itemEquipLoc == "INVTYPE_HEAD" then
                numSlots = 1; pooledTargetSlots[1] = 1
            elseif itemEquipLoc == "INVTYPE_NECK" then
                numSlots = 1; pooledTargetSlots[1] = 2
            elseif itemEquipLoc == "INVTYPE_SHOULDER" then
                numSlots = 1; pooledTargetSlots[1] = 3
            elseif itemEquipLoc == "INVTYPE_CHEST" or itemEquipLoc == "INVTYPE_ROBE" then
                numSlots = 1; pooledTargetSlots[1] = 5
            elseif itemEquipLoc == "INVTYPE_WAIST" then
                numSlots = 1; pooledTargetSlots[1] = 6
            elseif itemEquipLoc == "INVTYPE_LEGS" then
                numSlots = 1; pooledTargetSlots[1] = 7
            elseif itemEquipLoc == "INVTYPE_FEET" then
                numSlots = 1; pooledTargetSlots[1] = 8
            elseif itemEquipLoc == "INVTYPE_WRIST" then
                numSlots = 1; pooledTargetSlots[1] = 9
            elseif itemEquipLoc == "INVTYPE_HAND" then
                numSlots = 1; pooledTargetSlots[1] = 10
            elseif itemEquipLoc == "INVTYPE_FINGER" then
                numSlots = 2; pooledTargetSlots[1] = 11; pooledTargetSlots[2] = 12
            elseif itemEquipLoc == "INVTYPE_TRINKET" then
                numSlots = 2; pooledTargetSlots[1] = 13; pooledTargetSlots[2] = 14
            elseif itemEquipLoc == "INVTYPE_CLOAK" then
                numSlots = 1; pooledTargetSlots[1] = 15
            elseif itemEquipLoc == "INVTYPE_WEAPON" then
                if rule.weaps["1H_Dual"] then
                    numSlots = 2; pooledTargetSlots[1] = 16; pooledTargetSlots[2] = 17
                else
                    numSlots = 1; pooledTargetSlots[1] = 16
                end
            elseif itemEquipLoc == "INVTYPE_SHIELD" or itemEquipLoc == "INVTYPE_HOLDABLE" or itemEquipLoc == "INVTYPE_WEAPONOFFHAND" then
                numSlots = 1; pooledTargetSlots[1] = 17
            elseif itemEquipLoc == "INVTYPE_2HWEAPON" or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT" then
                if itemEquipLoc == "INVTYPE_2HWEAPON" and rule.weaps["2H_Dual"] then
                    numSlots = 2; pooledTargetSlots[1] = 16; pooledTargetSlots[2] = 17
                else
                    numSlots = 1; pooledTargetSlots[1] = 16
                end
            elseif itemEquipLoc == "INVTYPE_WEAPONMAINHAND" then
                numSlots = 1; pooledTargetSlots[1] = 16
            end
        end

        poolIndex               = poolIndex + 1
        itemDataPool[poolIndex] = itemDataPool[poolIndex] or {}
        local itemData          = itemDataPool[poolIndex]

        itemData.link           = itemLink
        itemData.ilvl           = itemLevel
        itemData.statVal        = statVal
        itemData.is2H           = ((itemEquipLoc == "INVTYPE_2HWEAPON" and not rule.weaps["2H_Dual"]) or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT")
        itemData.isEquipped     = isEquipped
        itemData.physId         = isEquipped and (-slotOverride) or evaluateIndex
        itemData.itemEquipLoc   = itemEquipLoc
        itemData.bag            = bag
        itemData.slot           = slot
        itemData.score          = nil

        for i = 1, numSlots do
            local s = pooledTargetSlots[i]
            table.insert(best[s], itemData)
            if _G.SFUI_DEBUG_SLOT and s == _G.SFUI_DEBUG_SLOT then
                local nameStr = GetItemInfo(itemLink) or itemLink
                dbgSlotPrint(string.format("[slot%d] ADDED %s | ilvl=%.0f | equipped=%s | bag=%s,slot=%s",
                    s, tostring(nameStr), itemLevel, tostring(isEquipped),
                    tostring(bag), tostring(slot)))
            end
        end
    end

    -- 1. Scan equipped
    for slotID = 1, 17 do
        if slotID ~= 4 then -- skip shirt
            local link = GetInventoryItemLink("player", slotID)
            if link then evaluate(link, true, slotID) end
        end
    end

    -- 2. Scan bags
    for bag = 0, 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local link = C_Container.GetContainerItemLink(bag, slot)
            if link then evaluate(link, false, nil, bag, slot) end
        end
    end

    -- Protect locked slots: remove them from consideration so the equipped item
    -- is never touched by EquipHighestILvl regardless of what's in bags.
    -- Covers trinkets (13,14), rings (11,12), neck (2), weapons (16,17).
    local lockedSlotIDs = { 2, 11, 12, 13, 14, 16, 17 }
    for _, slotID in ipairs(lockedSlotIDs) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local itemID = GetItemInfoInstant and GetItemInfoInstant(link)
            local specGear = itemID and SfuiDB and SfuiDB.gear and SfuiDB.gear[specID]
            local lockTable = specGear and (isPvP and specGear.locked_items_pvp or specGear.locked_items_pve)
            -- Legacy fallback
            if not lockTable and specGear then lockTable = specGear.locked_items end
            if lockTable and lockTable[itemID] then
                best[slotID] = nil
            end
        end
    end

    -- Quad-Tier Engine: Hero Spec -> Pawn Math -> Manual Priority -> Default DB Priority
    local specDB = SfuiDB and SfuiDB.gear and SfuiDB.gear[specID]
    local hd = nil
    if specDB and C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec then
        local activeHero = C_ClassTalents.GetActiveHeroTalentSpec()
        if activeHero and specDB.hero and specDB.hero[activeHero] then
            hd = specDB.hero[activeHero]
        end
    end

    local pweights = (hd and hd.pawn_weights) or (specDB and specDB.pawn_weights)
    local statWeights = nil

    if pweights then
        -- Auto-inject main stats equal to highest secondary stat if missing
        local maxW = 0
        for _, w in pairs(pweights) do
            if w > maxW then maxW = w end
        end
        if maxW > 0 then
            local activePWeights = sfui.highest.activePWeights or {}
            sfui.highest.activePWeights = activePWeights
            for k in pairs(activePWeights) do activePWeights[k] = nil end
            for k, v in pairs(pweights) do activePWeights[k] = v end

            activePWeights["Intellect"] = activePWeights["Intellect"] or (maxW * 2.0)
            activePWeights["Agility"]   = activePWeights["Agility"] or (maxW * 2.0)
            activePWeights["Strength"]  = activePWeights["Strength"] or (maxW * 2.0)
            pweights                    = activePWeights
        end
    else
        -- P1 fallback hierarchy: pawn weights > explicitly saved manual stats > stats.lua default dictionary stats > hardcoded generic "H,M,V,C" fallback failover
        local order = (hd and hd.stat_order) or (specDB and specDB.stat_order) or
            (sfui.default_stats and sfui.default_stats[tonumber(specID)]) or
            { "H", "M", "V", "C" }
        local equals = (hd and hd.stat_equals) or (specDB and specDB.stat_equals) or { true, false, false }

        local statKeys = sfui.highest.statKeys
        if not statKeys then
            statKeys = {
                ["Crit"] = "ITEM_MOD_CRIT_RATING_SHORT",
                ["C"] = "ITEM_MOD_CRIT_RATING_SHORT",
                ["Haste"] = "ITEM_MOD_HASTE_RATING_SHORT",
                ["H"] = "ITEM_MOD_HASTE_RATING_SHORT",
                ["Mastery"] = "ITEM_MOD_MASTERY_RATING_SHORT",
                ["M"] = "ITEM_MOD_MASTERY_RATING_SHORT",
                ["Versatility"] = "ITEM_MOD_VERSATILITY",
                ["V"] = "ITEM_MOD_VERSATILITY",
            }
            sfui.highest.statKeys = statKeys
        end

        statWeights = sfui.highest.statWeights or {}
        sfui.highest.statWeights = statWeights
        for k in pairs(statWeights) do statWeights[k] = nil end

        statWeights["ITEM_MOD_INTELLECT_SHORT"] = 6.0
        statWeights["ITEM_MOD_AGILITY_SHORT"] = 6.0
        statWeights["ITEM_MOD_STRENGTH_SHORT"] = 6.0

        local curWeight = 4.0
        for i = 1, 4 do
            local stat = order[i]
            if stat and statKeys[stat] then
                statWeights[statKeys[stat]] = curWeight
            end
            if i < 4 and not equals[i] then
                curWeight = curWeight - 1.0
            end
        end
    end

    -- Precalculate scores to avoid heavy math directly inside table.sort
    for slotID, items in pairs(best) do
        for _, itm in ipairs(items) do
            local score = itm.ilvl * 10
            if isPvP then
                score = itm.ilvl *
                    100 -- PvP gear tooltips return massive ilvls, this ensures it overrides base stat arrays
            end

            -- Feature 1: Tier Set Protection
            if itm.isEquipped then
                local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = _G.GetItemInfo(itm.link)
                if setID and setID > 0 then
                    score = score + 150 -- +150 score protection for equipped tier sets to dissuade breaking sets
                end
            end

            -- Feature 2: Socket Valuation & Stat Priority
            if GetItemStats then
                local itemStats = GetItemStats(itm.link)
                if itemStats then
                    -- Prismatic socket bonus
                    if itemStats["EMPTY_SOCKET_PRISMATIC"] then
                        score = score + 150 -- +15 ilvl equivalent score for empty socket
                    end

                    -- Secondary stat weights derived directly from Pawn string parsing, or fallback to relative Tier weights
                    if pweights then
                        for statName, statAmount in pairs(itemStats) do
                            local simName = "None"
                            if statName == "ITEM_MOD_CRIT_RATING_SHORT" then
                                simName = "Crit"
                            elseif statName == "ITEM_MOD_HASTE_RATING_SHORT" then
                                simName = "Haste"
                            elseif statName == "ITEM_MOD_MASTERY_RATING_SHORT" then
                                simName = "Mastery"
                            elseif statName == "ITEM_MOD_VERSATILITY" then
                                simName = "Versatility"
                            elseif statName == "ITEM_MOD_INTELLECT_SHORT" then
                                simName = "Intellect"
                            elseif statName == "ITEM_MOD_AGILITY_SHORT" then
                                simName = "Agility"
                            elseif statName == "ITEM_MOD_STRENGTH_SHORT" then
                                simName = "Strength"
                            end

                            if simName ~= "None" and pweights[simName] then
                                score = score + (statAmount * pweights[simName])
                            end

                            -- Tertiary stat modifiers
                            if statName == "ITEM_MOD_CR_LIFESTEAL_SHORT" or statName == "ITEM_MOD_CR_SPEED_SHORT" then
                                score = score + statAmount
                            end
                        end
                    elseif statWeights then
                        for statName, statAmount in pairs(itemStats) do
                            if statWeights[statName] then
                                score = score + (statAmount * statWeights[statName])
                            end

                            -- Tertiary stat modifiers
                            if statName == "ITEM_MOD_CR_LIFESTEAL_SHORT" or statName == "ITEM_MOD_CR_SPEED_SHORT" then
                                score = score + statAmount
                            end
                        end
                    end
                end
            end
            itm.score = score
        end
    end

    -- Sort individual slots using the new score system
    for slotID, items in pairs(best) do
        table.sort(items, function(a, b) return a.score > b.score end)
        if _G.SFUI_DEBUG_SLOT and slotID == _G.SFUI_DEBUG_SLOT then
            dbgSlotPrint("=== Slot " .. slotID .. " candidates after scoring ===")
            for rank, itm in ipairs(items) do
                local nm = GetItemInfo(itm.link) or itm.link
                dbgSlotPrint(string.format("  #%d %s | ilvl=%.0f | score=%.1f | equipped=%s",
                    rank, tostring(nm), itm.ilvl, itm.score, tostring(itm.isEquipped)))
            end
            _G.SFUI_DEBUG_SLOT = nil -- auto-clear after one scan
        end
    end

    local finalPick = {}

    -- Feature: Dynamic Tier Set Drafting
    local force_2set = specDB and specDB.force_2set
    local force_4set = specDB and (specDB.force_4set ~= false) and not specDB.force_2set
    if force_2set or force_4set then
        local targetCount = force_4set and 4 or 2
        local tierSlots = sfui.highest.tierSlots or { 1, 3, 5, 7, 10 } -- Head, Shoulder, Chest, Legs, Hands
        sfui.highest.tierSlots = tierSlots
        local setStats = {}

        for _, s in ipairs(tierSlots) do
            if best[s] then
                for _, itm in ipairs(best[s]) do
                    local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = _G.GetItemInfo(itm.link)
                    if setID and setID > 0 then
                        if not setStats[setID] then setStats[setID] = { totalIlvl = 0, pieces = {} } end
                        if not setStats[setID].pieces[s] or itm.score > setStats[setID].pieces[s].score then
                            setStats[setID].pieces[s] = itm
                        end
                    end
                end
            end
        end

        local bestSetID = nil
        local bestSetIlvl = -1
        local bestSetPieces = nil

        for setID, data in pairs(setStats) do
            local count = 0
            data.totalIlvl = 0
            for s, itm in pairs(data.pieces) do
                count = count + 1
                data.totalIlvl = data.totalIlvl + itm.ilvl
            end
            if count >= targetCount then
                if data.totalIlvl > bestSetIlvl then
                    bestSetIlvl = data.totalIlvl
                    bestSetID = setID
                    bestSetPieces = data.pieces
                end
            end
        end

        if bestSetID and bestSetPieces then
            local costList = {}
            for s, tierItm in pairs(bestSetPieces) do
                local bestOverallScore = (best[s] and best[s][1] and best[s][1].score) or 0
                local cost = bestOverallScore - tierItm.score
                if cost < 0 then cost = 0 end
                table.insert(costList, { slot = s, itm = tierItm, cost = cost })
            end

            table.sort(costList, function(a, b) return a.cost < b.cost end)

            for i = 1, targetCount do
                if costList[i] then
                    finalPick[costList[i].slot] = costList[i].itm
                end
            end
        end
    end

    -- Resolve Weapons first (combinatorics based on primary stat)
    local best2H = nil
    local best1H = nil
    local bestOH = nil

    if best[16] then
        for _, itm in ipairs(best[16]) do
            if itm.is2H and not best2H then best2H = itm end
            if not itm.is2H and not best1H then best1H = itm end
        end
    end
    if best[17] then
        for _, itm in ipairs(best[17]) do
            if not itm.is2H then
                if not best1H or (best1H.physId ~= itm.physId) then
                    bestOH = itm; break
                end
            end
        end
    end

    local score2H = best2H and best2H.score or 0
    if best2H then
        -- A 2H weapon occupies two slots, so its base ilvl component must be doubled to compare
        -- against the sum of a 1H + OH score (which organically adds two item levels together).
        score2H = score2H + (best2H.ilvl * (isPvP and 100 or 10))
    end
    local scoreDual = (best1H and best1H.score or 0) + (bestOH and bestOH.score or 0)

    if score2H > 0 or scoreDual > 0 then
        if score2H > scoreDual then
            finalPick[16] = best2H
            local currentOffhand = GetInventoryItemLink("player", 17)
            if currentOffhand then
                finalPick[17] = { isUnequip = true, isEquipped = false }
            end
        else
            if best1H then finalPick[16] = best1H end
            if bestOH then finalPick[17] = bestOH end
        end
    end

    if _G.SFUI_DEBUG_WEAPONS and best[16] then
        sfui.common.print("|cffffff00[SFUI Debug] Slot 16 evaluated:|r")
        for i, itm in ipairs(best[16]) do
            sfui.common.print("  [" .. i .. "]", itm.link, "Score:", math.floor(itm.score), "is2H:", tostring(itm.is2H))
        end
        if best2H then sfui.common.print("  best2H:", best2H.link) end
        if finalPick[16] then sfui.common.print("  WINNER:", finalPick[16].link) else sfui.common.print("  WINNER: None") end
        _G.SFUI_DEBUG_WEAPONS = false
    end


    -- Process all other slots
    for slotID = 1, 15 do
        if not finalPick[slotID] then -- Skip slots already claimed by Tier Drafting
            local items = best[slotID]
            if items then
                for _, itm in ipairs(items) do
                    local alreadyPicked = false
                    local itemID = GetItemInfoInstant and GetItemInfoInstant(itm.link)

                    for _, picked in pairs(finalPick) do
                        if picked.physId == itm.physId then
                            alreadyPicked = true; break
                        end
                        if itemID and GetItemInfoInstant and picked.link and GetItemInfoInstant(picked.link) == itemID then
                            alreadyPicked = true; break
                        end
                    end

                    if not alreadyPicked then
                        finalPick[slotID] = itm
                        break
                    end
                end
            end
        end
    end

    return finalPick
end

function sfui.highest.EquipHighestILvl(isPvP, silent)
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        if not silent then sfprint("Cannot equip gear while in combat.") end
        return
    end

    if not silent then
        sfprint(string.format("Scanning bags for best %s gear...", isPvP and "PvP" or "PvE"))
    end

    local best = sfui.highest.GetBestItems(isPvP)
    if not best then return end

    local equipQueue = {}
    for slotID, item in pairs(best) do
        if not item.isEquipped then
            table.insert(equipQueue, { slotID = slotID, item = item })
        end
    end

    -- Ensure deterministic equip order (Main Hand 16 before Off Hand 17) Titan's Grip constraints
    table.sort(equipQueue, function(a, b) return a.slotID < b.slotID end)

    local totalToEquip = #equipQueue

    -- Equip sequentially with small delays to avoid cursor collisions.
    -- We do NOT call ClearCursor after EquipCursorItem: if the item triggers a
    -- bind/tradeable confirmation dialog, Blizzard holds the item on the cursor
    -- until the player confirms. Calling ClearCursor would dismiss the dialog.
    local function equipNext(index)
        if index > #equipQueue then
            if totalToEquip > 0 then
                if not silent then sfprint("Equipped " .. totalToEquip .. " upgrade(s)!") end
            else
                if not silent then sfprint("Already wearing your best gear.") end
            end
            return
        end
        local entry = equipQueue[index]
        local slotID, item = entry.slotID, entry.item
        if item.isUnequip then
            if _G.ClearCursor then _G.ClearCursor() end
            if _G.PickupInventoryItem then _G.PickupInventoryItem(slotID) end
            _G.C_Timer.After(0.1, function()
                if _G.PutItemInBackpack then _G.PutItemInBackpack() end
            end)
        elseif item.bag and item.slot then
            if _G.ClearCursor then _G.ClearCursor() end
            C_Container.PickupContainerItem(item.bag, item.slot)
            if _G.EquipCursorItem then _G.EquipCursorItem(slotID) end
            boeAttemptedAt[item.link] = _G.GetTime()
            local watchBag, watchSlot, watchLink = item.bag, item.slot, item.link
            _G.C_Timer.After(2, function()
                local stillThere = _G.C_Container.GetContainerItemLink(watchBag, watchSlot)
                if stillThere == watchLink then
                    boeAttemptedAt[watchLink] = _G.GetTime() + 3570
                end
            end)
        else
            EquipItemByName(item.link, slotID)
        end
        _G.C_Timer.After(0.15, function() equipNext(index + 1) end)
    end

    if totalToEquip > 0 then
        equipNext(1)
    else
        if not silent then sfprint("Already wearing your highest gear.") end
    end
end
