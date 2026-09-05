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

local SLOT_NAMES = {
    [1]  = "Head",
    [2]  = "Neck",
    [3]  = "Shoulders",
    [4]  = "Shirt",
    [5]  = "Chest",
    [6]  = "Waist",
    [7]  = "Legs",
    [8]  = "Feet",
    [9]  = "Wrists",
    [10] = "Hands",
    [11] = "Ring 1",
    [12] = "Ring 2",
    [13] = "Trinket 1",
    [14] = "Trinket 2",
    [15] = "Back",
    [16] = "Main Hand",
    [17] = "Off Hand",
    [19] = "Tabard",
}

local TANK_SPECS = {
    [250] = true, -- Blood DK
    [581] = true, -- Vengeance DH
    [104] = true, -- Guardian Druid
    [268] = true, -- Brewmaster Monk
    [66]  = true, -- Protection Paladin
    [73]  = true, -- Protection Warrior
}

local ARMOR_SLOTS = {
    [1]  = true, -- Head
    [3]  = true, -- Shoulder
    [5]  = true, -- Chest
    [6]  = true, -- Waist
    [7]  = true, -- Legs
    [8]  = true, -- Feet
    [9]  = true, -- Wrist
    [10] = true, -- Hands
}

local RAZORICE_SPELL_ID = 53343
local cachedRazoriceName = nil
local function HasRazoriceEnchant(itemData)
    if not itemData or not itemData.link then return false end
    local link = itemData.link

    -- 1. Direct enchantID check (3370 = Rune of Razorice, 6241 = scaling rank)
    local enchantID = tonumber(link:match("item:%d+:(%d+):"))
    if enchantID == 3370 or enchantID == 6241 or enchantID == 3368 then
        return true
    end

    if not cachedRazoriceName then
        local spellName = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(RAZORICE_SPELL_ID))
            or (_G.GetSpellInfo and _G.GetSpellInfo(RAZORICE_SPELL_ID))
            or "Razorice"
        if spellName and spellName ~= "" then
            cachedRazoriceName = spellName:lower()
        end
    end

    -- 2. Tooltip scan for Runeforged enchant text
    if C_TooltipInfo then
        local data
        if itemData.bag and itemData.slot then
            data = C_TooltipInfo.GetBagItem(itemData.bag, itemData.slot)
        elseif itemData.equippedSlot then
            data = C_TooltipInfo.GetInventoryItem("player", itemData.equippedSlot)
        else
            data = C_TooltipInfo.GetHyperlink(link)
        end
        if data and data.lines then
            for _, line in ipairs(data.lines) do
                local txt = line.leftText
                if txt and type(txt) == "string" and txt ~= "" then
                    local lowerTxt = txt:lower()
                    if (cachedRazoriceName and lowerTxt:find(cachedRazoriceName, 1, true)) or lowerTxt:find("razorice", 1, true) then
                        return true
                    end
                end
            end
        end
    end

    return false
end

local embellishCache = {}
local embellishCacheCount = 0
local EMBELLISH_CACHE_MAX = 300

local function HasEmbellishment(itemData)
    if not itemData or not itemData.link then return false end
    local link = itemData.link
    if embellishCache[link] ~= nil then
        return embellishCache[link]
    end

    local isEmbellished = false
    local embCat = _G["ITEM_LIMIT_CATEGORY_EMBELLISHED"]
    local embPattern = embCat and embCat:lower()

    if C_TooltipInfo then
        local data
        if itemData.bag and itemData.slot then
            data = C_TooltipInfo.GetBagItem(itemData.bag, itemData.slot)
        elseif itemData.equippedSlot then
            data = C_TooltipInfo.GetInventoryItem("player", itemData.equippedSlot)
        else
            data = C_TooltipInfo.GetHyperlink(link)
        end

        if data and data.lines then
            for _, line in ipairs(data.lines) do
                local txt = line.leftText
                if txt and type(txt) == "string" and txt ~= "" then
                    local ltxt = txt:lower()
                    if (embPattern and ltxt:find(embPattern, 1, true))
                        or ltxt:find("embellish", 1, true)
                        or ltxt:find("verziert", 1, true)
                        or ltxt:find("orné", 1, true)
                        or ltxt:find("adornad", 1, true)
                        or ltxt:find("украшен", 1, true)
                        or ltxt:find("美化", 1, true)
                        or ltxt:find("장식", 1, true) then
                        isEmbellished = true
                        break
                    end
                end
            end
        end
    end

    if embellishCacheCount >= EMBELLISH_CACHE_MAX then
        _G.wipe(embellishCache)
        embellishCacheCount = 0
    end
    embellishCacheCount = embellishCacheCount + 1
    embellishCache[link] = isEmbellished
    return isEmbellished
end

-- Weapon Subclasses (classID == 2, numeric subclassID)
-- 0: 1H Axe, 1: 2H Axe, 2: Bow, 3: Gun, 4: 1H Mace, 5: 2H Mace, 6: Polearm,
-- 7: 1H Sword, 8: 2H Sword, 9: Warglaive, 10: Staff, 13: Fist, 15: Dagger, 18: Crossbow, 19: Wand
local WEAPONS_DH               = { [0] = true, [7] = true, [9] = true, [13] = true } -- Havoc & Vengeance: 1H Axes, 1H Swords, Warglaives, Fist (CANNOT use Daggers [15] or 1H Maces [4]!)
local WEAPONS_DH_DEVOURER      = { [0] = true, [7] = true, [9] = true, [13] = true, [15] = true } -- Devourer: Warglaives, Swords, Axes, Fist Weapons, Daggers (Intellect)
local WEAPONS_DK               = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true }
local WEAPONS_DRUID            = { [4] = true, [5] = true, [6] = true, [10] = true, [13] = true, [15] = true }
local WEAPONS_EVOKER           = { [0] = true, [1] = true, [4] = true, [5] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true }
local WEAPONS_HUNTER_RANGED    = { [2] = true, [3] = true, [18] = true }
local WEAPONS_HUNTER_MELEE     = { [1] = true, [6] = true, [8] = true, [10] = true }
local WEAPONS_MAGE             = { [7] = true, [10] = true, [15] = true, [19] = true }
local WEAPONS_MONK             = { [0] = true, [4] = true, [6] = true, [7] = true, [10] = true, [13] = true }
local WEAPONS_PALADIN          = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true }
local WEAPONS_PRIEST           = { [4] = true, [10] = true, [15] = true, [19] = true }
local WEAPONS_ROGUE_ASSASSIN   = { [15] = true } -- Assassination requires Daggers in both hands
local WEAPONS_ROGUE_ALL        = { [0] = true, [4] = true, [7] = true, [13] = true, [15] = true }
local WEAPONS_SHAMAN_CASTER    = { [0] = true, [1] = true, [4] = true, [5] = true, [10] = true, [13] = true, [15] = true }
local WEAPONS_SHAMAN_ENH       = { [0] = true, [4] = true, [13] = true } -- Enhancement cannot use daggers for Stormstrike
local WEAPONS_WARLOCK          = { [7] = true, [10] = true, [15] = true, [19] = true }
local WEAPONS_WARRIOR          = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true }

sfui.highest.rules = {
    -- Death Knight
    [250] = { armor = 4, stat = 1, weaps = { ["2H"] = true }, allowedWeapons = WEAPONS_DK },
    [251] = { armor = 4, stat = 1, weaps = { ["2H"] = true, ["1H_Dual"] = true }, allowedWeapons = WEAPONS_DK },
    [252] = { armor = 4, stat = 1, weaps = { ["2H"] = true }, allowedWeapons = WEAPONS_DK },
    -- Demon Hunter
    [577] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true }, allowedWeapons = WEAPONS_DH },          -- Havoc (Agility; NO Daggers)
    [581] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true }, allowedWeapons = WEAPONS_DH },          -- Vengeance (Agility; NO Daggers)
    [1480] = { armor = 2, stat = 4, weaps = { ["1H_Dual"] = true }, allowedWeapons = WEAPONS_DH_DEVOURER }, -- Devourer (Intellect; CAN use Daggers)
    -- Druid
    [102] = { armor = 2, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_DRUID },
    [103] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_DRUID },
    [104] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_DRUID },
    [105] = { armor = 2, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_DRUID },
    -- Evoker
    [1467] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_EVOKER },
    [1468] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_EVOKER },
    [1473] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_EVOKER },
    -- Hunter
    [253] = { armor = 3, stat = 2, weaps = { ["Ranged"] = true }, allowedWeapons = WEAPONS_HUNTER_RANGED },
    [254] = { armor = 3, stat = 2, weaps = { ["Ranged"] = true }, allowedWeapons = WEAPONS_HUNTER_RANGED },
    [255] = { armor = 3, stat = 2, weaps = { ["2H"] = true }, allowedWeapons = WEAPONS_HUNTER_MELEE },
    -- Mage
    [62] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_MAGE },
    [63] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_MAGE },
    [64] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_MAGE },
    -- Monk
    [268] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true }, allowedWeapons = WEAPONS_MONK },
    [269] = { armor = 2, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true }, allowedWeapons = WEAPONS_MONK },
    [270] = { armor = 2, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_MONK },
    -- Paladin
    [65] = { armor = 4, stat = 4, weaps = { ["2H"] = true, ["1H_Shield"] = true }, allowedWeapons = WEAPONS_PALADIN },
    [66] = { armor = 4, stat = 1, weaps = { ["1H_Shield"] = true }, allowedWeapons = WEAPONS_PALADIN },
    [70] = { armor = 4, stat = 1, weaps = { ["2H"] = true }, allowedWeapons = WEAPONS_PALADIN },
    -- Priest
    [256] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_PRIEST },
    [257] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_PRIEST },
    [258] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_PRIEST },
    -- Rogue
    [259] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true }, allowedWeapons = WEAPONS_ROGUE_ASSASSIN },
    [260] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true }, allowedWeapons = WEAPONS_ROGUE_ALL },
    [261] = { armor = 2, stat = 2, weaps = { ["1H_Dual"] = true }, allowedWeapons = WEAPONS_ROGUE_ALL },
    -- Shaman
    [262] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Shield"] = true }, allowedWeapons = WEAPONS_SHAMAN_CASTER },
    [263] = { armor = 3, stat = 2, weaps = { ["2H"] = true, ["1H_Dual"] = true }, allowedWeapons = WEAPONS_SHAMAN_ENH },
    [264] = { armor = 3, stat = 4, weaps = { ["2H"] = true, ["1H_Shield"] = true }, allowedWeapons = WEAPONS_SHAMAN_CASTER },
    -- Warlock
    [265] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_WARLOCK },
    [266] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_WARLOCK },
    [267] = { armor = 1, stat = 4, weaps = { ["2H"] = true, ["1H_Off"] = true }, allowedWeapons = WEAPONS_WARLOCK },
    -- Warrior
    [71] = { armor = 4, stat = 1, weaps = { ["2H"] = true }, allowedWeapons = WEAPONS_WARRIOR },
    [72] = { armor = 4, stat = 1, weaps = { ["2H_Dual"] = true, ["1H_Dual"] = true }, allowedWeapons = WEAPONS_WARRIOR },
    [73] = { armor = 4, stat = 1, weaps = { ["1H_Shield"] = true }, allowedWeapons = WEAPONS_WARRIOR }
}

-- Checks if the item matches the primary stat
local function HasPrimaryStat(itemLink, primaryStatName)
    local stats = C_Item.GetItemStats(itemLink)
    -- Fast-path mathematically sound API match
    if stats and stats[primaryStatName] then return true end

    -- Tooltip Fallback Check for Deceptive Base Items or un-cached stat structures
    local tooltipData = C_TooltipInfo and C_TooltipInfo.GetHyperlink(itemLink)
    if tooltipData and tooltipData.lines then
        local primaryString = _G[primaryStatName] or ""
        if primaryStatName == "ITEM_MOD_INTELLECT_SHORT" then
            primaryString = primaryString ~= "" and primaryString or "Intellect"
        elseif primaryStatName == "ITEM_MOD_AGILITY_SHORT" then
            primaryString = primaryString ~= "" and primaryString or "Agility"
        elseif primaryStatName == "ITEM_MOD_STRENGTH_SHORT" then
            primaryString = primaryString ~= "" and primaryString or "Strength"
        end

        if primaryString ~= "" then
            for _, line in ipairs(tooltipData.lines) do
                local text = line.leftText
                if text and type(text) == "string" then
                    -- If the dynamic tooltip clearly broadcasts the primary stat or main stat, we know it's there
                    if text:find(primaryString, 1, true) or text:find("Agility", 1, true) or text:find("Primary Stat", 1, true) or text:find("Main Stat", 1, true) then
                        return true
                    end
                end
            end
        end
    end

    -- If there's literally NO primary stats on the item, we allow it (generic trinkets/rings/necks/cloaks)
    local classID = select(6, GetItemInfoInstant(itemLink))
    if classID ~= 2 then
        local hasAnyPrimary = stats and (stats["ITEM_MOD_STRENGTH_SHORT"] or stats["ITEM_MOD_AGILITY_SHORT"] or stats["ITEM_MOD_INTELLECT_SHORT"])
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

local validationCache = {}
local validationCacheCount = 0
local VALIDATION_CACHE_MAX = 300

function sfui.highest.ClearCache()
    _G.wipe(validationCache)
    validationCacheCount = 0
    _G.wipe(embellishCache)
    embellishCacheCount = 0
end

-- Returns true, itemLevel, statVal, itemEquipLoc if the item is valid for the spec rules
local function IsItemValidForSpec_Internal(itemLink, specID)
    local rule = sfui.highest.rules[specID]
    if not rule then return false end

    -- Dynamic Frost DK Talent Overrides
    if specID == 251 then
        local frostbane = IsPlayerSpell(455993)
        rule = { armor = rule.armor, stat = rule.stat, weaps = { ["1H_Dual"] = frostbane, ["2H"] = not frostbane }, allowedWeapons = rule.allowedWeapons }
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
        -- Enforce class/spec weapon proficiencies (e.g. Demon Hunters cannot use Daggers [15] or 1H Maces [4])
        if rule.allowedWeapons and subclassID and not rule.allowedWeapons[subclassID] then
            return false
        end

        if itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT" then
            if not rule.weaps["Ranged"] then return false end
        elseif itemEquipLoc == "INVTYPE_2HWEAPON" then
            if not rule.weaps["2H"] and not rule.weaps["2H_Dual"] then return false end
        elseif itemEquipLoc == "INVTYPE_WEAPON" or itemEquipLoc == "INVTYPE_WEAPONMAINHAND" then
            if not rule.weaps["1H_Dual"] and not rule.weaps["1H_Off"] and not rule.weaps["1H_Shield"] then return false end
        elseif itemEquipLoc == "INVTYPE_WEAPONOFFHAND" then
            if not rule.weaps["1H_Dual"] and not rule.weaps["1H_Off"] then return false end
        else
            return false
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

function sfui.highest.IsItemValidForSpec(itemLink, specID)
    local cacheKey = itemLink .. ":" .. tostring(specID)
    if validationCache[cacheKey] ~= nil then
        local c = validationCache[cacheKey]
        return c[1], c[2], c[3], c[4]
    end
    local isValid, itemLevel, statVal, itemEquipLoc = IsItemValidForSpec_Internal(itemLink, specID)
    if validationCacheCount >= VALIDATION_CACHE_MAX then
        _G.wipe(validationCache)
        validationCacheCount = 0
    end
    validationCacheCount = validationCacheCount + 1
    validationCache[cacheKey] = { isValid, itemLevel, statVal, itemEquipLoc }
    return isValid, itemLevel, statVal, itemEquipLoc
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
        rule = { armor = rule.armor, stat = rule.stat, weaps = { ["1H_Dual"] = frostbane, ["2H"] = not frostbane }, allowedWeapons = rule.allowedWeapons }
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

        -- Locked items retain their true ilvl; sorting priority is handled via itm.score

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
        itemData.equippedSlot   = isEquipped and slotOverride or nil
        itemData.physId         = isEquipped and (-slotOverride) or evaluateIndex
        itemData.itemEquipLoc   = itemEquipLoc
        itemData.bag            = bag
        itemData.slot           = slot
        itemData.score          = nil
        itemData.isEmbellished  = HasEmbellishment(itemData)
        itemData.isLockedItem   = isLockedItem
        itemData.isTier         = nil
        itemData.equipReason    = nil

        if isLockedItem then
            if itemEquipLoc == "INVTYPE_TRINKET" then
                itemData.equipReason = "Locked Trinket"
            elseif itemEquipLoc == "INVTYPE_FINGER" then
                itemData.equipReason = "Locked Ring"
            elseif itemEquipLoc == "INVTYPE_NECK" then
                itemData.equipReason = "Locked Neck"
            elseif itemEquipLoc == "INVTYPE_WEAPON" or itemEquipLoc == "INVTYPE_2HWEAPON" or itemEquipLoc == "INVTYPE_WEAPONMAINHAND" or itemEquipLoc == "INVTYPE_WEAPONOFFHAND" or itemEquipLoc == "INVTYPE_SHIELD" or itemEquipLoc == "INVTYPE_HOLDABLE" or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT" then
                itemData.equipReason = "Locked Weapon"
            else
                itemData.equipReason = "Locked Item"
            end
        end

        for i = 1, numSlots do
            local s = pooledTargetSlots[i]
            table.insert(best[s], itemData)
            if _G.SFUI_DEBUG_SLOT and s == _G.SFUI_DEBUG_SLOT then
                local nameStr = GetItemInfo(itemLink) or itemLink
                dbgSlotPrint(string.format("[slot%d] ADDED %s | ilvl=%.0f | emb=%s | equipped=%s | bag=%s,slot=%s",
                    s, tostring(nameStr), itemLevel, tostring(itemData.isEmbellished), tostring(isEquipped),
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

    local isTank = TANK_SPECS[specID] == true
    local armorIlvlPrio = (specDB and specDB.armor_ilvl_prio)
    if armorIlvlPrio == nil then
        armorIlvlPrio = isTank
    end

    -- Precalculate scores to avoid heavy math directly inside table.sort
    for slotID, items in pairs(best) do
        local isArmor = ARMOR_SLOTS[slotID] == true
        local isWeapon = (slotID == 16 or slotID == 17)
        local prioritizeIlvl = (isArmor and armorIlvlPrio) or isWeapon

        for _, itm in ipairs(items) do
            if itm.isLockedItem then
                itm.score = 9000000 + (itm.ilvl or 0)
            else
                local baseMultiplier = isPvP and 100 or (prioritizeIlvl and 1000 or 10)
                local score = itm.ilvl * baseMultiplier

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
                            score = score + (prioritizeIlvl and 500 or 150)
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
                                elseif statName == "ITEM_MOD_INTELLECT_SHORT" or statName == "ITEM_MOD_AGILITY_SHORT" or statName == "ITEM_MOD_STRENGTH_SHORT" then
                                    if rule.stat == 4 then
                                        simName = "Intellect"
                                    elseif rule.stat == 2 then
                                        simName = "Agility"
                                    elseif rule.stat == 1 then
                                        simName = "Strength"
                                    end
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
                                local mappedStatName = statName
                                if statName == "ITEM_MOD_INTELLECT_SHORT" or statName == "ITEM_MOD_AGILITY_SHORT" or statName == "ITEM_MOD_STRENGTH_SHORT" then
                                    mappedStatName = STAT_MAP[rule.stat] or statName
                                end

                                if statWeights[mappedStatName] then
                                    score = score + (statAmount * statWeights[mappedStatName])
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
    end

    -- Sort individual slots using the new score system
    for slotID, items in pairs(best) do
        table.sort(items, function(a, b) return a.score > b.score end)
        if _G.SFUI_DEBUG_SLOT and slotID == _G.SFUI_DEBUG_SLOT then
            dbgSlotPrint("=== Slot " .. slotID .. " candidates after scoring ===")
            for rank, itm in ipairs(items) do
                local nm = GetItemInfo(itm.link) or itm.link
                dbgSlotPrint(string.format("  #%d %s | ilvl=%.0f | emb=%s | score=%.1f | equipped=%s",
                    rank, tostring(nm), itm.ilvl, tostring(itm.isEmbellished), itm.score, tostring(itm.isEquipped)))
            end
            _G.SFUI_DEBUG_SLOT = nil -- auto-clear after one scan
        end
    end

    local finalPick = {}

    -- Protect locked slots: retain equipped locked items directly in finalPick so
    -- they are never replaced, and clear them from candidate consideration in best[slotID].
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
                local _, _, _, itemEquipLoc = GetItemInfoInstant(link)
                local effectiveILvl = GetDetailedItemLevelInfo(link) or 1
                local itmObj = {
                    link = link,
                    ilvl = effectiveILvl,
                    statVal = 0,
                    is2H = ((itemEquipLoc == "INVTYPE_2HWEAPON" and not rule.weaps["2H_Dual"]) or itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_RANGEDRIGHT"),
                    isEquipped = true,
                    equippedSlot = slotID,
                    physId = -slotID,
                    itemEquipLoc = itemEquipLoc,
                    score = 9999999,
                    isLockedItem = true,
                    equipReason = (slotID == 13 or slotID == 14) and "Locked Trinket"
                        or (slotID == 11 or slotID == 12) and "Locked Ring"
                        or (slotID == 2) and "Locked Neck"
                        or (slotID == 16 or slotID == 17) and "Locked Weapon"
                        or "Locked Item",
                }
                itmObj.isEmbellished = HasEmbellishment(itmObj)
                finalPick[slotID] = itmObj
                best[slotID] = nil
            end
        end
    end

    -- Feature: Dynamic Tier Set Drafting (Prioritizes Highest setID / Latest Tier)
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
                        if not setStats[setID] then setStats[setID] = { setID = setID, count = 0, totalIlvl = 0, pieces = {} } end
                        if not setStats[setID].pieces[s] or itm.score > setStats[setID].pieces[s].score then
                            setStats[setID].pieces[s] = itm
                        end
                    end
                end
            end
        end

        -- Rank candidate sets prioritizing newest tier (highest setID), with totalIlvl as tiebreaker
        local sortedSets = {}
        for setID, data in pairs(setStats) do
            local count = 0
            local totalIlvl = 0
            for s, itm in pairs(data.pieces) do
                count = count + 1
                totalIlvl = totalIlvl + itm.ilvl
            end
            data.count = count
            data.totalIlvl = totalIlvl
            table.insert(sortedSets, data)
        end

        table.sort(sortedSets, function(a, b)
            if a.setID ~= b.setID then
                return a.setID > b.setID
            end
            return a.totalIlvl > b.totalIlvl
        end)

        -- 1. Find the newest tier set (highest setID) that meets targetCount (4 or 2)
        local bestSet = nil
        local effectiveTargetCount = targetCount
        for _, data in ipairs(sortedSets) do
            if data.count >= targetCount then
                bestSet = data
                break
            end
        end

        -- 2. Fallback: if forcing 4-set but no single set has 4 pieces, fallback to the
        -- newest tier set with at least 2 pieces so the player still gets their 2-set bonus
        if not bestSet and targetCount == 4 then
            for _, data in ipairs(sortedSets) do
                if data.count >= 2 then
                    bestSet = data
                    effectiveTargetCount = 2
                    break
                end
            end
        end

        if bestSet and bestSet.pieces then
            local costList = {}
            for s, tierItm in pairs(bestSet.pieces) do
                local bestOverallScore = (best[s] and best[s][1] and best[s][1].score) or 0
                local cost = bestOverallScore - tierItm.score
                if cost < 0 then cost = 0 end
                table.insert(costList, { slot = s, itm = tierItm, cost = cost })
            end

            table.sort(costList, function(a, b) return a.cost < b.cost end)

            for i = 1, effectiveTargetCount do
                if costList[i] then
                    finalPick[costList[i].slot] = costList[i].itm
                    costList[i].itm.isTier = true
                    costList[i].itm.equipReason = (effectiveTargetCount >= 4) and "4-Set" or "2-Set"
                end
            end
        end
    end

    -- Resolve Weapons (combinatorics based on primary stat)
    if not finalPick[16] and not finalPick[17] then
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
            score2H = score2H + (best2H.ilvl * (isPvP and 100 or 1000))
        end
        local scoreDual = (best1H and best1H.score or 0) + (bestOH and bestOH.score or 0)

        local prioMH_OH = (specID == 62 or specID == 63 or specID == 64 or specID == 265 or specID == 266 or specID == 267 or specID == 258)
        local choose2H = false

        if best2H and (not best1H or not bestOH) then
            choose2H = true
        elseif best2H and best1H and bestOH then
            if prioMH_OH then
                -- For Mage, Warlock & Shadow Priest: prioritize MH + OH if stats/score are equal or better
                -- 2H is only chosen if it genuinely beats the combined dual set beyond rounding margin
                if score2H > (scoreDual + 1.0) then
                    choose2H = true
                else
                    choose2H = false
                end
            else
                if score2H > scoreDual then
                    choose2H = true
                else
                    choose2H = false
                end
            end
        end

        if choose2H then
            finalPick[16] = best2H
            local currentOffhand = GetInventoryItemLink("player", 17)
            if currentOffhand then
                finalPick[17] = { isUnequip = true, isEquipped = false }
            end
        else
            if best1H and bestOH then
                local canOHGoMainHand = (bestOH.itemEquipLoc == "INVTYPE_WEAPON" or bestOH.itemEquipLoc == "INVTYPE_WEAPONMAINHAND" or (bestOH.itemEquipLoc == "INVTYPE_2HWEAPON" and rule.weaps["2H_Dual"]))
                local can1HGoOffHand = (best1H.itemEquipLoc == "INVTYPE_WEAPON" or best1H.itemEquipLoc == "INVTYPE_WEAPONOFFHAND" or (best1H.itemEquipLoc == "INVTYPE_2HWEAPON" and rule.weaps["2H_Dual"]))

                if canOHGoMainHand and can1HGoOffHand then
                    -- Dual Wielding two weapons
                    if specID == 251 then
                        -- Frost DK: Always put Rune of Razorice in Main Hand
                        local w1Razor = HasRazoriceEnchant(best1H)
                        local w2Razor = HasRazoriceEnchant(bestOH)
                        if w2Razor and not w1Razor then
                            finalPick[16] = bestOH
                            finalPick[17] = best1H
                        elseif w1Razor and not w2Razor then
                            finalPick[16] = best1H
                            finalPick[17] = bestOH
                        else
                            -- Both or neither have Razorice: put highest ilvl weapon in Main Hand
                            if bestOH.ilvl > best1H.ilvl then
                                finalPick[16] = bestOH
                                finalPick[17] = best1H
                            else
                                finalPick[16] = best1H
                                finalPick[17] = bestOH
                            end
                        end
                    else
                        -- General Dual Wield: Always put highest ilvl weapon in Main Hand
                        if bestOH.ilvl > best1H.ilvl then
                            finalPick[16] = bestOH
                            finalPick[17] = best1H
                        else
                            finalPick[16] = best1H
                            finalPick[17] = bestOH
                        end
                    end
                else
                    finalPick[16] = best1H
                    finalPick[17] = bestOH
                end
            else
                if best1H then finalPick[16] = best1H end
                if bestOH then finalPick[17] = bestOH end
            end
        end
    elseif finalPick[16] and not finalPick[17] then
        -- Main hand is locked; resolve offhand if mainhand is not 2H
        if not finalPick[16].is2H and best[17] then
            for _, itm in ipairs(best[17]) do
                if not itm.is2H and (finalPick[16].physId ~= itm.physId) then
                    local itemID = GetItemInfoInstant and GetItemInfoInstant(itm.link)
                    local pickedID = finalPick[16].link and GetItemInfoInstant and GetItemInfoInstant(finalPick[16].link)
                    local isUnique = false
                    if itemID and pickedID and itemID == pickedID then
                        local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, unique = GetItemInfo(itm.link)
                        isUnique = unique or false
                    end
                    if not isUnique then
                        finalPick[17] = itm
                        break
                    end
                end
            end
        end
    elseif not finalPick[16] and finalPick[17] then
        -- Offhand is locked; resolve 1H mainhand
        if best[16] then
            for _, itm in ipairs(best[16]) do
                if not itm.is2H and (finalPick[17].physId ~= itm.physId) then
                    local itemID = GetItemInfoInstant and GetItemInfoInstant(itm.link)
                    local pickedID = finalPick[17].link and GetItemInfoInstant and GetItemInfoInstant(finalPick[17].link)
                    local isUnique = false
                    if itemID and pickedID and itemID == pickedID then
                        local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, unique = GetItemInfo(itm.link)
                        isUnique = unique or false
                    end
                    if not isUnique then
                        finalPick[16] = itm
                        break
                    end
                end
            end
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

    -- Feature: Dynamic Embellishment Drafting (force_2emb)
    local force_2emb = specDB and (specDB.force_2emb == true or specDB.force_2embellishments == true)
    if force_2emb then
        local currentEmbCount = 0
        for _, itm in pairs(finalPick) do
            if itm.isEmbellished then
                currentEmbCount = currentEmbCount + 1
            end
        end
        local embNeeded = 2 - currentEmbCount
        if embNeeded > 0 then
            local embCandidates = {}
            for s = 1, 15 do
                if not finalPick[s] and best[s] then
                    local bestOverallScore = (best[s][1] and best[s][1].score) or 0
                    for _, itm in ipairs(best[s]) do
                        if itm.isEmbellished then
                            local cost = bestOverallScore - itm.score
                            if cost < 0 then cost = 0 end
                            table.insert(embCandidates, { slot = s, itm = itm, cost = cost })
                        end
                    end
                end
            end

            table.sort(embCandidates, function(a, b) return a.cost < b.cost end)

            local embAssigned = 0
            for _, cand in ipairs(embCandidates) do
                if embAssigned >= embNeeded then break end
                if not finalPick[cand.slot] then
                    local conflict = false
                    local itemID = GetItemInfoInstant and GetItemInfoInstant(cand.itm.link)
                    for _, picked in pairs(finalPick) do
                        if picked.physId == cand.itm.physId then
                            conflict = true; break
                        end
                        if itemID and GetItemInfoInstant and picked.link and GetItemInfoInstant(picked.link) == itemID then
                            local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, isUnique = GetItemInfo(cand.itm.link)
                            if isUnique then
                                conflict = true; break
                            end
                        end
                    end
                    if not conflict then
                        finalPick[cand.slot] = cand.itm
                        if not cand.itm.equipReason then
                            cand.itm.equipReason = "Embellishment"
                        end
                        embAssigned = embAssigned + 1
                    end
                end
            end
        end
    end

    -- Process all other slots
    local totalEmbCount = 0
    for _, itm in pairs(finalPick) do
        if itm.isEmbellished then
            totalEmbCount = totalEmbCount + 1
        end
    end

    for slotID = 1, 15 do
        if not finalPick[slotID] then -- Skip slots already claimed
            local items = best[slotID]
            if items then
                for _, itm in ipairs(items) do
                    local alreadyPicked = false
                    local itemID = GetItemInfoInstant and GetItemInfoInstant(itm.link)

                    -- Hard game limit: maximum 2 active embellishments allowed
                    if itm.isEmbellished and totalEmbCount >= 2 then
                        alreadyPicked = true
                    end

                    if not alreadyPicked then
                        for _, picked in pairs(finalPick) do
                            if picked.physId == itm.physId then
                                alreadyPicked = true; break
                            end
                            if itemID and GetItemInfoInstant and picked.link and GetItemInfoInstant(picked.link) == itemID then
                                local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, isUnique = GetItemInfo(itm.link)
                                if isUnique then
                                    alreadyPicked = true; break
                                end
                            end
                        end
                    end

                    if not alreadyPicked then
                        finalPick[slotID] = itm
                        if itm.isEmbellished then
                            totalEmbCount = totalEmbCount + 1
                        end
                        break
                    end
                end
            end
        end
    end

    return finalPick
end

local isEquippingInProgress = false
local pendingEquipRequest   = nil

function sfui.highest.EquipHighestILvl(isPvP, silent)
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        if not silent then sfprint("Cannot equip gear while in combat.") end
        return
    end

    -- Mutex lock: if an equip sequence is already actively swapping items, queue a follow-up request instead of spawning parallel loops
    if isEquippingInProgress then
        pendingEquipRequest = { isPvP = isPvP, silent = silent }
        return
    end

    local best = sfui.highest.GetBestItems(isPvP)
    if not best then return end

    local equipQueue = {}
    for slotID, item in pairs(best) do
        local isAlreadyEquippedHere = (item.isEquipped and item.equippedSlot == slotID)
        if not isAlreadyEquippedHere then
            local oldLink = _G.GetInventoryItemLink("player", slotID)
            local oldIlvl = oldLink and (GetDetailedItemLevelInfo(oldLink) or select(4, _G.GetItemInfo(oldLink))) or 0
            local oldScore = 0
            if sfui.highest.pooledBest and sfui.highest.pooledBest[slotID] then
                for _, itm in ipairs(sfui.highest.pooledBest[slotID]) do
                    if itm.isEquipped and itm.equippedSlot == slotID then
                        oldScore = itm.score or 0
                        break
                    end
                end
            end
            table.insert(equipQueue, {
                slotID   = slotID,
                item     = item,
                oldLink  = oldLink,
                oldIlvl  = oldIlvl,
                oldScore = oldScore,
            })
        end
    end

    -- Ensure deterministic equip order (Main Hand 16 before Off Hand 17) Titan's Grip constraints
    table.sort(equipQueue, function(a, b) return a.slotID < b.slotID end)

    local totalToEquip = #equipQueue
    if totalToEquip == 0 then
        if not silent then sfprint("Already wearing your best gear.") end
        return
    end

    isEquippingInProgress = true

    local function onEquipFinished()
        isEquippingInProgress = false
        if pendingEquipRequest then
            local req = pendingEquipRequest
            pendingEquipRequest = nil
            sfui.highest.EquipHighestILvl(req.isPvP, req.silent)
        end
    end

    -- Equip sequentially with lock detection to avoid dropped items or cursor collisions.
    local function equipNext(index, retryCount)
        if index > #equipQueue then
            if totalToEquip > 0 then
                if not silent then sfprint("Equipped " .. totalToEquip .. " upgrade(s)!") end
            end
            onEquipFinished()
            return
        end

        if InCombatLockdown() then
            if not silent then sfprint("Equip canceled: cannot change equipment in combat.") end
            onEquipFinished()
            return
        end

        local entry = equipQueue[index]
        local slotID, item = entry.slotID, entry.item
        local oldLink = entry.oldLink
        local oldIlvl = entry.oldIlvl or 0
        local newLink = item.link
        local newIlvl = item.effectiveIlvl or item.ilvl or (newLink and (GetDetailedItemLevelInfo(newLink) or select(4, _G.GetItemInfo(newLink)))) or 0
        if oldIlvl == 0 and oldLink then
            oldIlvl = GetDetailedItemLevelInfo(oldLink) or select(4, _G.GetItemInfo(oldLink)) or 0
        end
        if newIlvl == 0 and newLink then
            newIlvl = GetDetailedItemLevelInfo(newLink) or select(4, _G.GetItemInfo(newLink)) or 0
        end
        local slotName = SLOT_NAMES[slotID] or ("Slot " .. tostring(slotID))
        retryCount = retryCount or 0

        if item.isUnequip then
            if retryCount == 0 and not silent then
                sfprint(string.format("-> %s (%d) to Empty (2H Weapon)",
                    oldLink or "Item", oldIlvl))
            end
            if _G.ClearCursor then _G.ClearCursor() end
            if _G.PickupInventoryItem then _G.PickupInventoryItem(slotID) end
            _G.C_Timer.After(0.08, function()
                if _G.PutItemInBackpack then _G.PutItemInBackpack() end
                _G.C_Timer.After(0.05, function() equipNext(index + 1) end)
            end)
            return
        end

        -- Print swap details on first attempt of each queued upgrade
        if retryCount == 0 and not silent then
            local reason = ""
            if oldLink and oldLink ~= "" then
                local diff = newIlvl - oldIlvl
                if item.equipReason then
                    if diff > 0 then
                        reason = string.format("%s (+%d ilvl)", item.equipReason, diff)
                    elseif diff < 0 then
                        reason = string.format("%s (%d ilvl)", item.equipReason, diff)
                    else
                        reason = item.equipReason
                    end
                else
                    if diff > 0 then
                        reason = string.format("+%d ilvl", diff)
                    elseif diff < 0 then
                        reason = string.format("%d ilvl, Stat Weights", diff)
                    else
                        reason = "Stat Weights"
                    end
                end
                sfprint(string.format("-> %s (%d) to %s (%d) (%s)",
                    oldLink, oldIlvl, newLink, newIlvl, reason))
            else
                if item.equipReason then
                    reason = string.format("%s (+%d ilvl)", item.equipReason, newIlvl)
                else
                    reason = string.format("+%d ilvl", newIlvl)
                end
                sfprint(string.format("-> Empty to %s (%d) (%s)",
                    newLink, newIlvl, reason))
            end
        end

        if item.bag and item.slot then
            local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
            if info and info.isLocked and retryCount < 10 then
                -- Container slot is locked by a previous item swap in flight: wait 50ms and retry
                _G.C_Timer.After(0.05, function() equipNext(index, retryCount + 1) end)
                return
            end

            -- Ensure container item still matches what we expect
            local currentLink = _G.C_Container.GetContainerItemLink(item.bag, item.slot)
            if currentLink and currentLink == item.link then
                if _G.ClearCursor then _G.ClearCursor() end
                C_Container.PickupContainerItem(item.bag, item.slot)
                if _G.CursorHasItem and _G.CursorHasItem() then
                    if _G.EquipCursorItem then _G.EquipCursorItem(slotID) end
                else
                    EquipItemByName(item.link, slotID)
                end
                boeAttemptedAt[item.link] = _G.GetTime()
                local watchBag, watchSlot, watchLink = item.bag, item.slot, item.link
                _G.C_Timer.After(2, function()
                    local stillThere = _G.C_Container.GetContainerItemLink(watchBag, watchSlot)
                    if stillThere == watchLink then
                        boeAttemptedAt[watchLink] = _G.GetTime() + 3570
                    end
                end)
            else
                -- Bag slot contents shifted: equip by item link directly
                EquipItemByName(item.link, slotID)
            end
        else
            EquipItemByName(item.link, slotID)
        end

        _G.C_Timer.After(0.08, function() equipNext(index + 1) end)
    end

    equipNext(1)
end
