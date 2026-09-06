local addonName, addon          = ...
---@diagnostic disable: undefined-global, undefined-field
sfui                            = sfui or {}
sfui.lootspec                   = {}

local GetSpecialization         = GetSpecialization
local GetSpecializationInfo     = GetSpecializationInfo
local GetSpecializationInfoByID = GetSpecializationInfoByID
local GetLootSpecialization     = GetLootSpecialization
local SetLootSpecialization     = SetLootSpecialization
local UnitClass                 = UnitClass
local _, ENGLISH_CLASS          = UnitClass("player")
local C_ChallengeMode           = C_ChallengeMode
local string                    = string
-- NOTE: EJ_* globals are NOT localized — they live in Blizzard_EncounterJournal
-- (lazy addon) and are nil at file-load time. Use them as raw globals in fns.

-- ─── DB helpers ───────────────────────────────────────────────────────────────
local dbCache                   = nil
local dbCacheClass              = nil
local function DB()
    if dbCache and dbCacheClass == ENGLISH_CLASS then return dbCache end

    SfuiDB.lootspec = SfuiDB.lootspec or {}
    SfuiDB.lootspec.classes = SfuiDB.lootspec.classes or {}

    -- Migration from legacy global data
    if SfuiDB.lootspec.bosses or SfuiDB.lootspec.dungeons then
        if not SfuiDB.lootspec.classes[ENGLISH_CLASS] then
            SfuiDB.lootspec.classes[ENGLISH_CLASS] = {
                enabled = SfuiDB.lootspec.enabled,
                defaultSpec = SfuiDB.lootspec.defaultSpec or 0,
                bosses = SfuiDB.lootspec.bosses or {},
                dungeons = SfuiDB.lootspec.dungeons or {}
            }
        end
        SfuiDB.lootspec.enabled = nil
        SfuiDB.lootspec.defaultSpec = nil
        SfuiDB.lootspec.bosses = nil
        SfuiDB.lootspec.dungeons = nil
    end

    -- Migration from recent per-spec implementation
    if SfuiDB.lootspec.specs then
        local specIdx = GetSpecialization()
        local specID = specIdx and GetSpecializationInfo(specIdx) or 0
        if specID ~= 0 and SfuiDB.lootspec.specs[specID] and not SfuiDB.lootspec.classes[ENGLISH_CLASS] then
            SfuiDB.lootspec.classes[ENGLISH_CLASS] = SfuiDB.lootspec.specs[specID]
        end
        SfuiDB.lootspec.specs = nil
    end

    local db = SfuiDB.lootspec.classes[ENGLISH_CLASS]
    if not db then
        db = {}
        SfuiDB.lootspec.classes[ENGLISH_CLASS] = db
    end

    db.enabled        = (db.enabled ~= false)
    db.defaultSpec    = db.defaultSpec or 0
    db.bosses         = db.bosses or {}
    db.dungeons       = db.dungeons or {}

    -- Migrate flat boss specIDs → nested { spec } tables.
    if not db._migrated then
        for k, v in pairs(db.bosses) do
            if type(v) == "number" then
                db.bosses[k] = { spec = v }
            end
        end
        db._migrated = true
    end

    dbCache        = db
    dbCacheClass   = ENGLISH_CLASS
    return db
end

sfui.lootspec.DB = DB

-- ─── Spec Helpers ─────────────────────────────────────────────────────────────
local function SpecName(specID)
    if not specID or specID == 0 then return "Current Spec" end
    local _, name = GetSpecializationInfoByID(specID)
    return name or ("Spec " .. specID)
end

-- ─── Auto-swap engine ─────────────────────────────────────────────────────────

local _dungeonToJournalEncounter = {}
local pendingSpec = nil

local function ApplyLootSpec(specID, reason)
    if specID == nil then return end
    local currentSpec = GetLootSpecialization()
    if (pendingSpec ~= nil and pendingSpec == specID) or (pendingSpec == nil and currentSpec == specID) then
        return
    end

    pendingSpec = specID
    SetLootSpecialization(specID)
    if reason then
        local displayName = (specID == 0) and "Current Spec" or SpecName(specID)
        sfui.common.print(string.format(
            "loot spec → |cff00ffff%s|r (%s)", displayName, reason))
    end
end

local function RestoreDefault(reason)
    local defSpec = DB().defaultSpec or 0
    ApplyLootSpec(defSpec, reason)
end

local function GetBossEntry(encounterID, db, encounterName)
    -- 1. Direct encounterID match
    local entry = db.bosses[encounterID]
    if entry then return entry end

    -- 2. Cached mapped journal encounterID
    local mappedID = _dungeonToJournalEncounter[encounterID]
    if mappedID and db.bosses[mappedID] then
        return db.bosses[mappedID]
    end

    -- 3. Dynamic lookup from EncounterJournal
    if EJ_GetEncounterInfo then
        for keyID, bEntry in pairs(db.bosses) do
            if type(keyID) == "number" then
                local bName, _, _, _, _, _, dID = EJ_GetEncounterInfo(keyID)
                if (dID and dID == encounterID) or (encounterName and bName and encounterName == bName) then
                    _dungeonToJournalEncounter[encounterID] = keyID
                    return bEntry
                end
            end
        end
    end

    return nil
end

-- Returns the configured specID for the current active dungeon / M+ instance, or nil.
local function GetActiveDungeonSpec()
    -- 1. Active Challenge Mode key
    local activeMapID = C_ChallengeMode.GetActiveChallengeMapID
        and C_ChallengeMode.GetActiveChallengeMapID()
    if activeMapID and activeMapID > 0 then
        local specID = DB().dungeons[activeMapID]
        if specID and specID ~= 0 then
            local mapName = C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(activeMapID)
            return specID, mapName or "M+ active"
        end
    end

    -- 2. Dungeon instance entry (match by instance name or uiMapID)
    local inInst, instType = IsInInstance()
    if inInst and (instType == "party" or instType == "scenario") then
        local instName = GetInstanceInfo()
        local currentMapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")

        local maps = C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()
        if maps then
            for _, cmMapID in ipairs(maps) do
                local name, _, _, _, _, uiMapID = C_ChallengeMode.GetMapUIInfo(cmMapID)
                if (instName and name and instName == name) or (currentMapID and uiMapID and currentMapID == uiMapID) then
                    local specID = DB().dungeons[cmMapID]
                    if specID and specID ~= 0 then
                        return specID, name
                    end
                end
            end
        end
    end

    return nil
end

local function GetActiveDelveSpec()
    local isInst, t = IsInInstance()
    local isDelve = (t == "scenario")
    if not isDelve and C_Scenario and C_Scenario.GetInfo then
        local _, _, _, _, _, _, _, _, _, _, scenType = C_Scenario.GetInfo()
        if scenType == 8 then isDelve = true end
    end
    if not isDelve and C_DelvesUI and C_DelvesUI.HasActiveDelve then
        if C_DelvesUI.HasActiveDelve() then isDelve = true end
    end
    if isDelve then
        local specID = DB().dungeons["delves"]
        return (specID and specID ~= 0) and specID or nil
    end
    return nil
end

-- True when we should hold the applied spec rather than restore on loot/zone.
-- Raid: hold until next encounter or leaving.
-- M+ / Dungeon: hold until leaving or end-of-run.
-- Delve: hold until leaving the scenario.
local function IsInManagedInstance()
    local _, t = IsInInstance()
    if t == "raid" then return true end
    if (t == "party" or t == "scenario") and GetActiveDungeonSpec() ~= nil then
        return true
    end
    if t == "scenario" or GetActiveDelveSpec() ~= nil then return true end
    return false
end

-- Set when we apply a non-default spec; cleared on restore.
-- Not persisted — resets to false on every reload/login (Lua state is fresh).
local specApplied = false

-- ─── Events ───────────────────────────────────────────────────────────────────

sfui.events.RegisterEvent("ENCOUNTER_START", function(_, encounterID, encounterName)
    local db = DB()
    if not db.enabled then return end
    local specID = 0
    local _, instanceType = IsInInstance()

    if instanceType == "none" then
        local wEntry = db.bosses["worldbosses"]
        if type(wEntry) == "table" and wEntry.spec and wEntry.spec ~= 0 then
            specID = wEntry.spec
        end
    end

    if specID == 0 then
        local entry = GetBossEntry(encounterID, db, encounterName)
        specID = (type(entry) == "table" and entry.spec) or (type(entry) == "number" and entry) or 0
    end

    if specID ~= 0 then
        specApplied = true
        ApplyLootSpec(specID, encounterName or "encounter")
    else
        local _, instanceType = IsInInstance()
        if instanceType == "raid" and (specApplied or GetLootSpecialization() ~= db.defaultSpec) then
            specApplied = false
            RestoreDefault("unconfigured encounter")
        end
    end
end)

sfui.events.RegisterEvent("ENCOUNTER_END", function(_, encounterID, encounterName, _, _, success)
    if success == 0 then return end -- wipe, don't warn
    local db = DB()
    local entry = GetBossEntry(encounterID, db, encounterName)

    if type(entry) == "table" and entry.warn then
        local bossName = encounterName
        if not bossName or bossName == "" then
            local jID = _dungeonToJournalEncounter[encounterID] or encounterID
            if EJ_GetEncounterInfo then
                bossName = EJ_GetEncounterInfo(jID)
            end
        end
        bossName = bossName or ("Boss " .. encounterID)
        sfui.common.print(string.format(
            "|cffcc44ff◆ Bonus Roll Reminder:|r %s — use your bonus roll item!", bossName))
    end
end)

sfui.events.RegisterEvent("LOOT_CLOSED", function()
    local db = DB()
    if not db.enabled then return end
    if IsInManagedInstance() then return end
    specApplied = false
    RestoreDefault("loot closed")
end)

sfui.events.RegisterEvent("PLAYER_LOOT_SPEC_UPDATED", function()
    pendingSpec = nil
end)

sfui.events.RegisterEvent("CHALLENGE_MODE_START", function()
    local db = DB()
    if not db.enabled then return end
    local specID, dungeonName = GetActiveDungeonSpec()
    if specID then
        specApplied = true
        ApplyLootSpec(specID, dungeonName or "M+ start")
    else
        C_Timer.After(0.2, function()
            local sID, dName = GetActiveDungeonSpec()
            if sID then
                specApplied = true
                ApplyLootSpec(sID, dName or "M+ start")
            end
        end)
    end
end)

local function CheckZoneLootSpec(reason)
    if not SfuiDB then return end
    local db = DB()
    if not db.enabled then return end

    local dungeonSpec, dungeonName = GetActiveDungeonSpec()
    if dungeonSpec then
        specApplied = true
        ApplyLootSpec(dungeonSpec, dungeonName or reason or "entered dungeon")
        return
    end

    local delveSpec = GetActiveDelveSpec()
    if delveSpec then
        specApplied = true
        ApplyLootSpec(delveSpec, reason or "entered delve")
        return
    end

    if not IsInManagedInstance() then
        if specApplied or (GetLootSpecialization() ~= db.defaultSpec and db.defaultSpec ~= nil) then
            specApplied = false
            RestoreDefault(reason or "left instance")
        end
    end
end

sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    CheckZoneLootSpec("entered zone")
end)

sfui.events.RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    CheckZoneLootSpec("zone changed")
end)

local function CheckDelveActive()
    local delveSpec = GetActiveDelveSpec()
    if delveSpec and not specApplied then
        specApplied = true
        ApplyLootSpec(delveSpec, "delve active")
    end
end

sfui.events.RegisterEvent("SCENARIO_UPDATE", CheckDelveActive)
sfui.events.RegisterEvent("ACTIVE_DELVE_DATA_UPDATE", CheckDelveActive)

-- ─── UI Delegation & Telemetry ────────────────────────────────────────────────
function sfui.lootspec.Toggle()
    if sfui.lootviewer and sfui.lootviewer.Toggle then
        sfui.lootviewer.Toggle()
    end
end
sfui.lootspec.toggle = sfui.lootspec.Toggle

function sfui.lootspec.Rebuild()
    if sfui.lootviewer and sfui.lootviewer.Rebuild then
        sfui.lootviewer.Rebuild()
    end
end

function sfui.lootspec.initialize()
    -- Automation engine is event-driven; UI is rendered by sfui.lootviewer
end

local _lootDebug = {}
function sfui.lootspec_debug_info()
    local db = SfuiDB and SfuiDB.lootspec and SfuiDB.lootspec.classes and SfuiDB.lootspec.classes[ENGLISH_CLASS]
    local lv = sfui.lootviewer_debug_info and sfui.lootviewer_debug_info()
    _lootDebug.frameCreated    = lv and lv.frameCreated or false
    _lootDebug.frameShown      = lv and lv.frameShown or false
    _lootDebug.enabled         = db and (db.enabled ~= false) or false
    _lootDebug.defaultSpec     = db and db.defaultSpec or 0
    _lootDebug.hasRaidCache    = lv and lv.hasRaidCache or false
    _lootDebug.hasDungeonCache = lv and lv.hasDungeonCache or false
    _lootDebug.cardPoolCount   = lv and lv.cardPoolTotal or 0
    _lootDebug.iconPoolCount   = lv and lv.iconPoolTotal or 0
    return _lootDebug
end
