local addonName, addon = ...
sfui = sfui or {}
sfui.season = {}

-- ============================================================================
-- SFUI Season & Expansion Database
--
-- Centralized configuration for expansion/season-specific definitions:
--   * Tracked currencies & item tokens (Crests, Sparks, Dust, Catalysts, Keys)
--   * Weekly quest pools, wrapper quests, and UI widget criteria
--   * Weekly quest block matrix and grouping for the Alts overview
--
-- Updating for a new season or major content patch requires updating this file
-- rather than modifying UI layout and rendering code in frames/alts.lua.
-- ============================================================================

sfui.season.expansion = 12 -- Midnight
sfui.season.season    = 2

-- ─── Seasonal Currencies & Tokens ───────────────────────────────────────────
sfui.season.CURRENCIES = {
    {
        isGroup = true,
        label = "Mistcrests",
        items = {
            { id = 3445, icon = 0 }, -- Hero Mistcrest
            { id = 3446, icon = 0 }, -- Myth Mistcrest
        }
    },
    {
        isGroup = true,
        label = "Spark",
        items = {
            { id = 274476, icon = 0, isItem = true },                           -- Spark of Tides
            { id = 3509,   icon = 0, showSeasonEarned = true, isSparkDust = true }, -- Tidal Spark Dust
        }
    },
    { id = 3465,   label = "Catalyst",       icon = 0 },                         -- Venomblight Manaflux
    { id = 3448,   label = "Corrosive Coin", icon = 0, fallbackIDs = { 3110 } }, -- Corrosive Coin
    {
        isGroup = true,
        label = "Keys",
        items = {
            { id = 3028, icon = 4622270 }, -- Restored Coffer Key
            { id = 3310, icon = 133016 },  -- Coffer Key Shard
        }
    },
    -- 12.0.5 / 12.1 Currencies and Items
    { id = 3418,   label = "VoidCore", icon = 0 },                         -- Nebulous Voidcore
    { id = 3405,   label = "Accolade", icon = 0 },                         -- Field Accolade
    { id = 3373,   label = "Pearl",    icon = 0 },                         -- Angler Pearls
    { id = 267051, label = "Particle", icon = 0, isItem = true },          -- Dark Particle
}

-- ─── Weekly Quest Definitions ───────────────────────────────────────────────
-- Each entry specifies:
--   key:                Identifier stored in alt.data.quests[key]
--   label:              Short name displayed in UI and tooltips
--   group:              "core" (purple highlight) or "bonus" (amber highlight)
--   wrapperID:          Optional main quest ID to check if active in log
--   questID:            Single quest ID for simple weeklies
--   pool:               Array of sub-quest IDs for rotating weekly pools
--   skipFlagCheck:      If true, do not use account-wide flag (use QUEST_TURNED_IN)
--   preserveCompleted:  If true, carry forward completed status across logins
--   targetTotal:        Target completion count (e.g. 2 for Special Assignment, 4 for Delve Stash)
--   isCount:            If true, displays numeric progress badge on block (e.g. 1/2)
--   widgetID:           UI Widget ID for visual visualization trackers (e.g. Delve Stash)
--   isAny:              If true, matches any single active/completed quest in pool
sfui.season.WEEKLY_QUESTS = {
    -- Core Pinnacle Weeklies (Champion track gear)
    {
        key       = "unity",
        label     = "Unity",
        group     = "core",
        wrapperID = 93744,
        pool      = {
            93766, 93767, 93769, 93889, 93890, 93891, 93892, 93909, 93910,
            93911, 93912, 93913, 94457, 95842, 95843, 96727, 98232
        },
    },
    {
        key     = "abundance",
        label   = "Abundance",
        group   = "core",
        questID = 89507,
    },
    {
        key               = "legends",
        label             = "Legends",
        group             = "core",
        wrapperID         = 92713,
        skipFlagCheck     = true,
        preserveCompleted = true,
        pool              = {
            92713, 92716, 92719, 92721, 92720, 92722, 92724, 92725,
            -- Legacy / Beta IDs
            89268, 88993, 88994, 88996, 88997, 88995,
        },
    },
    {
        key       = "runestones",
        label     = "Runestones",
        group     = "core",
        wrapperID = 91966,
        pool      = { 90573, 90574, 90575, 90576 },
    },
    {
        key     = "stormarion",
        label   = "Stormarion",
        group   = "core",
        questID = 90962,
    },
    {
        key   = "surges",
        label = "Surges",
        group = "core",
        pool  = { 96995, 98172 },
    },
    {
        key         = "specialAssignment",
        label       = "Special",
        group       = "core",
        isCount     = true,
        targetTotal = 2,
        pool        = { 92145, 92063, 93013, 93438, 93244, 91390, 91796, 92139 },
    },
    {
        key   = "worldBoss",
        label = "World Boss",
        group = "core",
        pool  = { 92123, 92560, 92636, 92034, 97128 },
    },

    -- High-Tier Delve / Prey / Event Weeklies (Champion / Hero track gear)
    {
        key     = "bounty",
        label   = "Bounty Map",
        group   = "bonus",
        questID = 86371,
    },
    {
        key         = "gildedStash",
        label       = "Stash (T11)",
        group       = "bonus",
        isCount     = true,
        widgetID    = 7591,
        targetTotal = 4,
    },
    {
        key   = "prey",
        label = "Prey",
        group = "bonus",
        pool  = { 94446, 91277, 96528 },
    },
    {
        key   = "voidAssaults",
        label = "Void",
        group = "bonus",
        pool  = { 94386, 94385 },
    },
    {
        key   = "bonusEvent",
        label = "Event",
        group = "bonus",
        pool  = { 93598, 93595, 93605, 93593, 93600 },
    },
    {
        key   = "twRaid",
        label = "TW Raid",
        group = "bonus",
        isAny = true,
        pool  = { 82817, 47523, 50316, 57637 },
    },
}

-- ─── Profession Weekly KP Sources & SkillLine Mappings (Midnight) ───────────
sfui.season.PROF_KP_SOURCES = {
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

-- Midnight expansion skillLine ID mappings
sfui.season.PROF_KP_SOURCES[2906] = sfui.season.PROF_KP_SOURCES[171] -- Alchemy
sfui.season.PROF_KP_SOURCES[2907] = sfui.season.PROF_KP_SOURCES[164] -- Blacksmithing
sfui.season.PROF_KP_SOURCES[2909] = sfui.season.PROF_KP_SOURCES[333] -- Enchanting
sfui.season.PROF_KP_SOURCES[2908] = sfui.season.PROF_KP_SOURCES[202] -- Engineering
sfui.season.PROF_KP_SOURCES[2905] = sfui.season.PROF_KP_SOURCES[182] -- Herbalism
sfui.season.PROF_KP_SOURCES[2911] = sfui.season.PROF_KP_SOURCES[773] -- Inscription
sfui.season.PROF_KP_SOURCES[2910] = sfui.season.PROF_KP_SOURCES[755] -- Jewelcrafting
sfui.season.PROF_KP_SOURCES[2912] = sfui.season.PROF_KP_SOURCES[165] -- Leatherworking
sfui.season.PROF_KP_SOURCES[2904] = sfui.season.PROF_KP_SOURCES[186] -- Mining
sfui.season.PROF_KP_SOURCES[2903] = sfui.season.PROF_KP_SOURCES[393] -- Skinning
sfui.season.PROF_KP_SOURCES[2913] = sfui.season.PROF_KP_SOURCES[197] -- Tailoring

-- ─── Great Vault Item Level Baselines & Upgrade Tracks (Midnight Season 2) ──
-- Returns: ilvl, trackString
function sfui.season.GetVaultBaseline(group, level)
    if group == "raid" then
        if level == 16 then return 318, "|cffff8000Myth 1/6|r" end
        if level == 15 then return 305, "|cffa335eeHero 1/6|r" end
        if level == 14 then return 292, "|cff0070ddChampion 1/6|r" end
        if level == 17 then return 279, "|cff1eff00Veteran 1/6|r" end
    elseif group == "dungeon" then
        if level >= 10 then return 318, "|cffff8000Myth 1/6|r" end
        if level >= 7  then return 315, "|cffa335eeHero 4/6|r" end
        if level == 6  then return 311, "|cffa335eeHero 3/6|r" end
        if level >= 4  then return 308, "|cffa335eeHero 2/6|r" end
        if level >= 2  then return 305, "|cffa335eeHero 1/6|r" end
        if level >= 0  then return 292, "|cff0070ddChampion 1/6|r" end
    elseif group == "world" then
        if level >= 8 then return 308, "|cffa335eeHero 2/6|r" end
        if level == 7 then return 305, "|cffa335eeHero 1/6|r" end
        if level == 6 then return 298, "|cff0070ddChampion 3/6|r" end
        if level == 5 then return 295, "|cff0070ddChampion 2/6|r" end
        if level == 4 then return 292, "|cff0070ddChampion 1/6|r" end
        if level == 3 then return 285, "|cff1eff00Veteran 3/6|r" end
        if level == 2 then return 282, "|cff1eff00Veteran 2/6|r" end
        if level >= 1 then return 279, "|cff1eff00Veteran 1/6|r" end
    end
    return nil, nil
end
