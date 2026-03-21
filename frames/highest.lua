local addonName, addon = ...
sfui.highest = {}

local _G = _G
local GetItemInfo = _G.GetItemInfo
local GetDetailedItemLevelInfo = _G.GetDetailedItemLevelInfo
local C_TooltipInfo = _G.C_TooltipInfo
local C_Item = _G.C_Item
local GetSpecialization = _G.GetSpecialization
local GetSpecializationInfo = _G.GetSpecializationInfo
local GetInventoryItemLink = _G.GetInventoryItemLink
local C_Container = _G.C_Container
local EquipItemByName = _G.EquipItemByName
local NUM_BAG_SLOTS = tonumber(_G.NUM_BAG_SLOTS) or 4
local tonumber = _G.tonumber
local pairs = _G.pairs
local ipairs = _G.ipairs
local print = _G.print
local string = _G.string
local table = _G.table

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
    [269] = { armor = 2, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true } },
    [270] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true } },
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

-- Checks if the item matches the primary stat (e.g. Intellect)
local function HasPrimaryStat(itemLink, primaryStatName)
    local stats = C_Item.GetItemStats(itemLink)
    if not stats then return false end
    
    -- If there's literally NO primary stats on the item, we allow it (generic trinkets/rings)
    local hasAnyPrimary = stats["ITEM_MOD_STRENGTH_SHORT"] or stats["ITEM_MOD_AGILITY_SHORT"] or stats["ITEM_MOD_INTELLECT_SHORT"]
    if not hasAnyPrimary then return true end
    
    -- But if it DOES have primary stats, it must have OUR primary stat
    if stats[primaryStatName] then return true end
    
    return false
end

local function GetPrimaryStatValue(itemLink, primaryStatName)
    local stats = C_Item.GetItemStats(itemLink)
    if not stats then return 0 end
    return stats[primaryStatName] or 0
end

-- Scan bags and return a table mapping slotId -> {link, ilvl} of best possible items
function sfui.highest.GetBestItems(isPvP)
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = GetSpecializationInfo(specIndex)
    local rule = sfui.highest.rules[specID]
    if not rule then return nil end

    local primaryStatName = STAT_MAP[rule.stat]
    local optimalArmor = rule.armor

    local best = {}
    local pooledTargetSlots = {}

    local function evaluate(itemLink, isEquipped, slotOverride)
        local itemName, _, _, itemLevel, _, itemType, itemSubType, _, itemEquipLoc, _, _, classID, subclassID = GetItemInfo(itemLink)
        if not itemEquipLoc or itemEquipLoc == "" then return end
        
        -- Use true effective item level from the server
        local effectiveILvl = GetDetailedItemLevelInfo(itemLink)
        if effectiveILvl then itemLevel = effectiveILvl end
        
        -- PvP Tooltip parsing for scaled ilvls
        if isPvP then
            local tooltipData = C_TooltipInfo.GetHyperlink(itemLink)
            if tooltipData then
                for _, line in ipairs(tooltipData.lines) do
                    local leftText = line.leftText
                    if leftText then
                        -- Strip UI color escapes
                        local cleanText = leftText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                        local ltext = cleanText:lower()
                        
                        -- Match flexibly for ANY line indicating PvP level scaling (ignores exact localized strings)
                        if ltext:find("level") and (ltext:find("pvp") or ltext:find("arena") or ltext:find("battleground")) then
                            local pvpMatch = cleanText:match("(%d%d%d)")
                            if pvpMatch then
                                local scaledIlvl = tonumber(pvpMatch)
                                if scaledIlvl and scaledIlvl > itemLevel and scaledIlvl < 1000 then
                                    itemLevel = scaledIlvl
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Use robust numeric ID checks instead of localized strings. classID 4 = Armor
        if classID == 4 then
            if itemEquipLoc ~= "INVTYPE_CLOAK" and itemEquipLoc ~= "INVTYPE_FINGER" and itemEquipLoc ~= "INVTYPE_TRINKET" and itemEquipLoc ~= "INVTYPE_NECK" and itemEquipLoc ~= "INVTYPE_HOLDABLE" and itemEquipLoc ~= "INVTYPE_SHIELD" then
                if subclassID ~= optimalArmor and subclassID ~= 5 then return end -- subclassID 5 is Cosmetic
            end
        end
        
        -- Weapon restriction rules
        if classID == 2 then
            if itemEquipLoc == "INVTYPE_2HWEAPON" or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT" then
                if not rule.weaps["2H"] and not rule.weaps["2H_Dual"] and not rule.weaps["Ranged"] then return end
            elseif itemEquipLoc == "INVTYPE_WEAPON" or itemEquipLoc == "INVTYPE_WEAPONMAINHAND" then
                if not rule.weaps["1H_Dual"] and not rule.weaps["1H_Off"] and not rule.weaps["1H_Shield"] then return end
            end
        elseif classID == 4 then
            if itemEquipLoc == "INVTYPE_SHIELD" then
                if not rule.weaps["1H_Shield"] then return end
            elseif itemEquipLoc == "INVTYPE_HOLDABLE" or itemEquipLoc == "INVTYPE_WEAPONOFFHAND" then
                if not rule.weaps["1H_Off"] and not rule.weaps["1H_Dual"] then return end
            end
        end

        local isNonDynamicStatPiece = (classID == 2 or itemEquipLoc == "INVTYPE_TRINKET" or itemEquipLoc == "INVTYPE_CLOAK" or itemEquipLoc == "INVTYPE_NECK" or itemEquipLoc == "INVTYPE_FINGER" or itemEquipLoc == "INVTYPE_HOLDABLE" or itemEquipLoc == "INVTYPE_SHIELD")
        
        if isNonDynamicStatPiece then
            if not HasPrimaryStat(itemLink, primaryStatName) then return end
        end
        
        local statVal = GetPrimaryStatValue(itemLink, primaryStatName)

        local numSlots = 0
        if slotOverride then
            numSlots = 1
            pooledTargetSlots[1] = slotOverride
        else
            if itemEquipLoc == "INVTYPE_HEAD" then numSlots = 1; pooledTargetSlots[1] = 1
            elseif itemEquipLoc == "INVTYPE_NECK" then numSlots = 1; pooledTargetSlots[1] = 2
            elseif itemEquipLoc == "INVTYPE_SHOULDER" then numSlots = 1; pooledTargetSlots[1] = 3
            elseif itemEquipLoc == "INVTYPE_CHEST" or itemEquipLoc == "INVTYPE_ROBE" then numSlots = 1; pooledTargetSlots[1] = 5
            elseif itemEquipLoc == "INVTYPE_WAIST" then numSlots = 1; pooledTargetSlots[1] = 6
            elseif itemEquipLoc == "INVTYPE_LEGS" then numSlots = 1; pooledTargetSlots[1] = 7
            elseif itemEquipLoc == "INVTYPE_FEET" then numSlots = 1; pooledTargetSlots[1] = 8
            elseif itemEquipLoc == "INVTYPE_WRIST" then numSlots = 1; pooledTargetSlots[1] = 9
            elseif itemEquipLoc == "INVTYPE_HAND" then numSlots = 1; pooledTargetSlots[1] = 10
            elseif itemEquipLoc == "INVTYPE_FINGER" then numSlots = 2; pooledTargetSlots[1] = 11; pooledTargetSlots[2] = 12
            elseif itemEquipLoc == "INVTYPE_TRINKET" then numSlots = 2; pooledTargetSlots[1] = 13; pooledTargetSlots[2] = 14
            elseif itemEquipLoc == "INVTYPE_CLOAK" then numSlots = 1; pooledTargetSlots[1] = 15
            elseif itemEquipLoc == "INVTYPE_WEAPON" then numSlots = 2; pooledTargetSlots[1] = 16; pooledTargetSlots[2] = 17
            elseif itemEquipLoc == "INVTYPE_SHIELD" or itemEquipLoc == "INVTYPE_HOLDABLE" or itemEquipLoc == "INVTYPE_WEAPONOFFHAND" then numSlots = 1; pooledTargetSlots[1] = 17
            elseif itemEquipLoc == "INVTYPE_2HWEAPON" or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT" then numSlots = 1; pooledTargetSlots[1] = 16
            elseif itemEquipLoc == "INVTYPE_WEAPONMAINHAND" then numSlots = 1; pooledTargetSlots[1] = 16
            end
        end

        for i = 1, numSlots do
            local s = pooledTargetSlots[i]
            if not best[s] then best[s] = {} end
            table.insert(best[s], { link = itemLink, ilvl = itemLevel, statVal = statVal, is2H = (itemEquipLoc == "INVTYPE_2HWEAPON" or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT"), isEquipped = isEquipped })
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
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local link = C_Container.GetContainerItemLink(bag, slot)
            if link then evaluate(link, false) end
        end
    end

    -- Sort individual slots
    for slotID, items in pairs(best) do
        table.sort(items, function(a, b) return a.ilvl > b.ilvl end)
    end
    
    local finalPick = {}

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
            if not itm.is2H then bestOH = itm; break end
        end
    end

    local stat2H = best2H and best2H.statVal or 0
    local statDual = (best1H and best1H.statVal or 0) + (bestOH and bestOH.statVal or 0)

    if stat2H > 0 or statDual > 0 then
        if stat2H > statDual then
            finalPick[16] = best2H
            -- finalPick[17] intentionally left empty so 2H is equipped
        else
            if best1H then finalPick[16] = best1H end
            if bestOH then finalPick[17] = bestOH end
        end
    end

    -- Process all other slots
    for slotID = 1, 15 do
        local items = best[slotID]
        if items then
            for _, itm in ipairs(items) do
                local alreadyPicked = false
                for _, picked in pairs(finalPick) do
                    if picked.link == itm.link and not picked.isEquipped then
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
    
    return finalPick
end

function sfui.highest.EquipHighestILvl(isPvP)
    local modeText = isPvP and "PvP" or "PvE"
    print(string.format("|cff6600ffsfui:|r Scanning bags for highest %s gear...", modeText))
    
    local best = sfui.highest.GetBestItems(isPvP)
    if not best then return end

    local equipCount = 0
    for slotID, item in pairs(best) do
        if not item.isEquipped then
            EquipItemByName(item.link, slotID)
            equipCount = equipCount + 1
        end
    end
    
    if equipCount > 0 then
        print("|cff6600ffsfui:|r Automatically equipped " .. equipCount .. " upgrades!")
    else
        print("|cff6600ffsfui:|r You are already wearing your highest item level gear.")
    end
end
