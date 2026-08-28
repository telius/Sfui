local addonName, addon          = ...
---@diagnostic disable: undefined-global, undefined-field
sfui                            = sfui or {}
sfui.lootspec                   = {}

local CreateFrame               = CreateFrame
local UIParent                  = UIParent
local GameTooltip               = _G.GameTooltip
local GetNumSpecializations     = GetNumSpecializations
local GetSpecialization         = GetSpecialization
local GetSpecializationInfo     = GetSpecializationInfo
local GetSpecializationInfoByID = GetSpecializationInfoByID
local GetLootSpecialization     = GetLootSpecialization
local SetLootSpecialization     = SetLootSpecialization
local UnitClass                 = UnitClass
local UnitGUID                  = UnitGUID
local _, ENGLISH_CLASS          = UnitClass("player")
local C_ChallengeMode           = C_ChallengeMode
local table                     = table
local math                      = math
local string                    = string
-- NOTE: EJ_* globals are NOT localized — they live in Blizzard_EncounterJournal
-- (lazy addon) and are nil at file-load time. Use them as raw globals in fns.

-- ─── Layout constants ─────────────────────────────────────────────────────────
local ROW_H                     = 24
local ICON_SIZE                 = 18
local PAD                       = 8
local COL_W                     = 170 -- loot spec button width
local FRAME_W                   = 620
local HEADER_H                  = 82 -- pixels occupied by title/controls/tabs
local FOOTER_H                  = 24
local MIN_FRAME_H               = 160
local MAX_FRAME_H               = 860
-- Pre-computed name column width (constant since all terms are constants).
-- width passed to builders is always FRAME_W-10.
local WARN_BTN_W = 22 -- 20px diamond button + 2px gap
local NAME_COL_W = (FRAME_W - 10) - COL_W - PAD * 3 - ICON_SIZE - WARN_BTN_W

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

-- ─── Spec helpers ─────────────────────────────────────────────────────────────
local specsCache = nil
local function BuildSpecList()
    if specsCache then return specsCache end
    -- Flat array of specIDs: [1] = 0 ("off"), [2..n] = actual spec IDs.
    specsCache = { 0 }
    local n = GetNumSpecializations()
    for i = 1, n do
        local id = GetSpecializationInfo(i)
        if id then specsCache[#specsCache + 1] = id end
    end
    return specsCache
end

local function InvalidateSpecCache() specsCache = nil end

local function SpecName(specID, isDefault)
    if specID == 0 then return isDefault and "Current Specialization" or "— off —" end
    local _, name = GetSpecializationInfoByID(specID)
    return name or ("Spec " .. specID)
end

local function SpecIcon(specID)
    if specID == 0 then return nil end
    local _, _, _, icon = GetSpecializationInfoByID(specID)
    return icon
end

local function CycleSpec(currentID)
    local list = BuildSpecList()
    for i, id in ipairs(list) do
        if id == currentID then
            return list[(i % #list) + 1]
        end
    end
    return list[1]  -- 0 = off
end

-- ─── Auto-swap engine ─────────────────────────────────────────────────────────

local _dungeonToJournalEncounter = {}
local _journalToDungeonEncounter = {}

local function ApplyLootSpec(specID, reason)
    if specID == nil then return end
    if GetLootSpecialization() == specID then return end
    SetLootSpecialization(specID)
    if reason then
        local displayName = (specID == 0) and "Current Spec" or SpecName(specID)
        sfui.common.print(string.format(
            "loot spec → |cff00ffff%s|r (%s)", displayName, reason))
    end
end

local function RestoreDefault(reason)
    ApplyLootSpec(DB().defaultSpec, reason)
end

-- Returns the configured specID for the current active M+ dungeon, or nil.
local function GetActiveMPlusSpec()
    local mapID = C_ChallengeMode.GetActiveChallengeMapID
        and C_ChallengeMode.GetActiveChallengeMapID()
    if mapID and mapID > 0 then
        local specID = DB().dungeons[mapID]
        return (specID and specID ~= 0) and specID or nil
    end
    return nil
end

local function GetActiveDelveSpec()
    local isInst, t = IsInInstance()
    local isDelve = (t == "scenario")
    if not isDelve and C_Scenario and C_Scenario.GetInfo then
        local ok, _, _, _, _, _, _, _, _, _, scenType = pcall(C_Scenario.GetInfo)
        if ok and scenType == 8 then isDelve = true end
    end
    if not isDelve and C_DelvesUI and C_DelvesUI.HasActiveDelve then
        local ok, hasDelve = pcall(C_DelvesUI.HasActiveDelve)
        if ok and hasDelve then isDelve = true end
    end
    if isDelve then
        local specID = DB().dungeons["delves"]
        return (specID and specID ~= 0) and specID or nil
    end
    return nil
end

-- True when we should hold the applied spec rather than restore on loot/zone.
-- Raid: hold until next encounter or leaving.
-- M+:  hold until the end-of-run chest is looted or the player leaves.
-- Delve: hold until leaving the scenario.
local function IsInManagedInstance()
    local _, t = IsInInstance()
    if t == "raid" then return true end
    if t == "party" and C_ChallengeMode.GetActiveChallengeMapID
        and (C_ChallengeMode.GetActiveChallengeMapID() or 0) > 0 then
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
        -- 1. Check direct encounterID
        local entry = db.bosses[encounterID]
        -- 2. Check mapped journal encounterID
        if not entry and _dungeonToJournalEncounter[encounterID] then
            entry = db.bosses[_dungeonToJournalEncounter[encounterID]]
        end
        -- 3. Dynamic lookup from EncounterJournal if mapping cache is cold
        if not entry then
            for keyID, bEntry in pairs(db.bosses) do
                if type(keyID) == "number" then
                    local ok, _, _, _, _, _, _, dID = pcall(EJ_GetEncounterInfo, keyID)
                    if ok and dID and dID == encounterID then
                        entry = bEntry
                        _dungeonToJournalEncounter[encounterID] = keyID
                        _journalToDungeonEncounter[keyID] = encounterID
                        break
                    end
                end
            end
        end

        specID = type(entry) == "table" and entry.spec or (type(entry) == "number" and entry) or 0
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
    local entry = db.bosses[encounterID]
    if not entry and _dungeonToJournalEncounter[encounterID] then
        entry = db.bosses[_dungeonToJournalEncounter[encounterID]]
    end
    if not entry then
        for keyID, bEntry in pairs(db.bosses) do
            if type(keyID) == "number" then
                local ok, _, _, _, _, _, _, dID = pcall(EJ_GetEncounterInfo, keyID)
                if ok and dID and dID == encounterID then
                    entry = bEntry
                    break
                end
            end
        end
    end

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

sfui.events.RegisterEvent("CHALLENGE_MODE_START", function()
    local db = DB()
    if not db.enabled then return end
    local specID = GetActiveMPlusSpec()
    if specID then
        specApplied = true
        ApplyLootSpec(specID, "M+ start")
    else
        C_Timer.After(0.2, function()
            local sID = GetActiveMPlusSpec()
            if sID then
                specApplied = true
                ApplyLootSpec(sID, "M+ start")
            end
        end)
    end
end)

local function CheckZoneLootSpec(reason)
    if not SfuiDB then return end
    local db = DB()
    if not db.enabled then return end

    local mplusSpec = GetActiveMPlusSpec()
    if mplusSpec then
        specApplied = true
        ApplyLootSpec(mplusSpec, reason or "entered M+ instance")
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
    C_Timer.After(0.5, function()
        CheckZoneLootSpec("entered zone")
    end)
end)

sfui.events.RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    CheckZoneLootSpec("zone changed")
end)

sfui.events.RegisterEvent("SCENARIO_UPDATE", function()
    local delveSpec = GetActiveDelveSpec()
    if delveSpec and not specApplied then
        specApplied = true
        ApplyLootSpec(delveSpec, "delve active")
    end
end)

sfui.events.RegisterEvent("ACTIVE_DELVE_DATA_UPDATE", function()
    local delveSpec = GetActiveDelveSpec()
    if delveSpec and not specApplied then
        specApplied = true
        ApplyLootSpec(delveSpec, "delve active")
    end
end)

sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
    InvalidateSpecCache()
    if sfui.lootspec.frame and sfui.lootspec.frame:IsShown() then
        sfui.lootspec.Rebuild()
    end
end)

-- ─── EJ data ──────────────────────────────────────────────────────────────────
local raidDataCache = nil
local function GetRaidData()
    if raidDataCache then return raidDataCache end

    if not EJ_GetInstanceByIndex then
        local loaded, reason = C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
        if not loaded then
            sfui.common.print("|cffff8800lootspec:|r EJ unavailable: " .. tostring(reason))
            return {}
        end
    end
    local oldInstance = EJ_GetCurrentInstance and EJ_GetCurrentInstance()
    local raids = {}
    local instIdx = 1
    while true do
        local instanceID, name = EJ_GetInstanceByIndex(instIdx, true)
        if not instanceID then break end
        local raid = { name = name, instanceID = instanceID, bosses = {} }

        securecall(EJ_SelectInstance, instanceID)
        local encIdx = 1
        while true do
            -- EJ_GetEncounterInfoByIndex: name, description, bossID, rootSectionID, link, instanceID, dungeonEncounterID, instanceImage
            local encName, _, bossID, _, _, _, dungeonEncounterID = EJ_GetEncounterInfoByIndex(encIdx)
            if not bossID or bossID == 0 then break end

            if not dungeonEncounterID or dungeonEncounterID == 0 then
                local _, _, _, _, _, _, dID = EJ_GetEncounterInfo(bossID)
                dungeonEncounterID = dID
            end

            if dungeonEncounterID and dungeonEncounterID > 0 then
                _dungeonToJournalEncounter[dungeonEncounterID] = bossID
                _journalToDungeonEncounter[bossID] = dungeonEncounterID
            end

            -- EJ_GetCreatureInfo: id, name, description, displayInfo, iconImage, uiModelSceneID
            local _, _, _, _, iconImage = EJ_GetCreatureInfo(1, bossID)
            table.insert(raid.bosses, {
                name               = encName,
                encounterID        = bossID,
                dungeonEncounterID = dungeonEncounterID,
                icon               = iconImage,
            })
            encIdx = encIdx + 1
        end
        if #raid.bosses > 0 then table.insert(raids, raid) end
        instIdx = instIdx + 1
    end
    if oldInstance then securecall(EJ_SelectInstance, oldInstance) end
    raidDataCache = raids

    return raids
end

local dungeonDataCache = nil
local function GetDungeonData()
    if dungeonDataCache then return dungeonDataCache end

    if not EJ_GetInstanceByIndex then
        local loaded, reason = C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
        if not loaded then
            sfui.common.print("|cffff8800lootspec:|r EJ unavailable: " .. tostring(reason))
            return dungeonDataCache or {}
        end
    end

    local nameToInstance = {}
    local instIdx = 1
    while true do
        local instanceID, name = EJ_GetInstanceByIndex(instIdx, false)
        if not instanceID then break end
        nameToInstance[name] = instanceID
        instIdx = instIdx + 1
    end

    local dungeons = {}
    local maps = C_ChallengeMode.GetMapTable()
    if not maps then return dungeons end
    for _, mapID in ipairs(maps) do
        -- GetMapUIInfo returns: name, id, timeLimit, texture, backgroundTexture, mapID
        local name, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
        if name then
            if texture == 0 then texture = nil end
            table.insert(dungeons, {
                mapID = mapID,
                name = name,
                texture = texture,
                instanceID = nameToInstance[name],
            })
        end
    end
    table.sort(dungeons, function(a, b) return a.name < b.name end)
    dungeonDataCache = dungeons

    return dungeons
end

-- Invalidate EJ caches when Blizzard_EncounterJournal is (re)loaded.
sfui.events.RegisterEvent("ADDON_LOADED", function(_, name)
    if name == "Blizzard_EncounterJournal" then
        raidDataCache   = nil
        dungeonDataCache = nil
    end
end)

-- ─── Row pool ─────────────────────────────────────────────────────────────────
local rowPool  = {}
local rowCount = 0

local function AcquireRow(parent)
    rowCount = rowCount + 1
    local r = rowPool[rowCount]
    if not r then
        r = CreateFrame("Frame", nil, parent)

        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()

        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(ICON_SIZE, ICON_SIZE)
        r.icon:SetPoint("LEFT", PAD, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        r.nameFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.nameFS:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
        r.nameFS:SetJustifyH("LEFT")
        r.nameFS:SetWordWrap(false)
        r.nameFS:SetTextColor(0.85, 0.85, 0.85, 1)

        r.linkBtn = CreateFrame("Button", nil, r)
        r.linkBtn:SetPoint("TOPLEFT", r.nameFS, "TOPLEFT")
        r.linkBtn:SetPoint("BOTTOMRIGHT", r.nameFS, "BOTTOMRIGHT")
        r.linkBtn:SetScript("OnEnter", function(self)
            if self.encounterID or self.instanceID then
                r.nameFS:SetTextColor(1, 0.82, 0, 1)
            end
        end)
        r.linkBtn:SetScript("OnLeave", function(self)
            r.nameFS:SetTextColor(0.85, 0.85, 0.85, 1)
        end)
        r.linkBtn:SetScript("OnClick", function(self)
            if not C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
                C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
            end
            if EncounterJournal_OpenJournal then
                EncounterJournal_OpenJournal(nil, self.instanceID, self.encounterID)
            end
        end)

        -- ── Spec button builder (loot-spec picker per boss/dungeon row) ─────
        -- self.field = "spec"|"bonus"  → reads nested DB().bosses[keyID][field]
        -- self.field = nil             → reads flat DB()[storageKey][keyID]
        local function MakeSpecButton(xRight)
            local b = CreateFrame("Button", nil, r, "BackdropTemplate")
            b:SetSize(COL_W, ROW_H - 4)
            b:SetPoint("RIGHT", xRight, 0)
            b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
            b:SetBackdropColor(0.05, 0.05, 0.05, 1)

            local bIcon = b:CreateTexture(nil, "ARTWORK")
            bIcon:SetSize(ICON_SIZE - 2, ICON_SIZE - 2)
            bIcon:SetPoint("LEFT", 3, 0)
            bIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            b.iconTex = bIcon

            local bLbl = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            bLbl:SetPoint("LEFT", bIcon, "RIGHT", 4, 0)
            bLbl:SetPoint("RIGHT", -4, 0)
            bLbl:SetJustifyH("LEFT")
            bLbl:SetWordWrap(false)
            b.lbl = bLbl

            local function GetSpecID(self)
                if not self.keyID then return 0 end
                if self.field then
                    local entry = DB().bosses[self.keyID]
                    return (type(entry) == "table" and entry[self.field]) or 0
                else
                    local store = DB()[self.storageKey]
                    return (store and store[self.keyID]) or 0
                end
            end

            b.Refresh = function(self)
                if not self.keyID then return end
                local specID = GetSpecID(self)
                local icon   = SpecIcon(specID)
                if icon then bIcon:SetTexture(icon) ; bIcon:Show()
                else bIcon:Hide() end
                if specID == 0 then
                    bLbl:SetText("— off —")
                    bLbl:SetTextColor(0.3, 0.3, 0.3, 1)
                else
                    local specColor = sfui.config and sfui.config.spec_colors and sfui.config.spec_colors[specID]
                    if specColor then
                        bLbl:SetTextColor(specColor[1], specColor[2], specColor[3], 1)
                    else
                        local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
                        local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
                        if cc then bLbl:SetTextColor(cc.r, cc.g, cc.b, 1)
                        else bLbl:SetTextColor(0.0, 0.8, 1.0, 1) end
                    end
                    bLbl:SetText(SpecName(specID))
                end
            end

            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b:SetScript("OnClick", function(self, mouseBtn)
                if not self.keyID then return end
                local db = DB()
                if self.field then
                    -- nested boss entry
                    local entry = db.bosses[self.keyID]
                    if type(entry) ~= "table" then
                        entry = { spec = (type(entry) == "number" and entry or 0) }
                        db.bosses[self.keyID] = entry
                    end
                    if mouseBtn == "RightButton" then entry[self.field] = 0
                    else entry[self.field] = CycleSpec(entry[self.field] or 0) end
                else
                    -- flat dungeon entry
                    db[self.storageKey] = db[self.storageKey] or {}
                    local cur = db[self.storageKey][self.keyID] or 0
                    if mouseBtn == "RightButton" then db[self.storageKey][self.keyID] = nil
                    else db[self.storageKey][self.keyID] = CycleSpec(cur) end
                end
                self:Refresh()
            end)
            b:SetScript("OnEnter", function(self)
                if not self.keyID then return end
                if GameTooltip then
                    local specID = GetSpecID(self)
                    pcall(function()
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(specID == 0 and "no swap configured" or SpecName(specID))
                        GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle spec", 1, 1, 1)
                        GameTooltip:AddLine("|cffaaaaaaright-click|r to clear", 1, 1, 1)
                        GameTooltip:Show()
                    end)
                end
            end)
            b:SetScript("OnLeave", function()
                if GameTooltip then GameTooltip:Hide() end
            end)
            return b
        end

        -- loot spec picker (anchored right, single column)
        r.specBtn = MakeSpecButton(-PAD)

        -- ── Warn/diamond button (bonus roll reminder toggle) ───────────────
        local w = CreateFrame("Button", nil, r)
        w:SetSize(20, ROW_H - 4)
        w:SetPoint("RIGHT", r.specBtn, "LEFT", -2, 0)

        w.icon = w:CreateTexture(nil, "ARTWORK")
        w.icon:SetSize(14, 14)
        w.icon:SetPoint("CENTER")
        w.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_3")

        local function IsWarned(btn)
            if not btn.keyID then return false end
            if btn.mode == "boss" then
                local entry = DB().bosses[btn.keyID]
                return type(entry) == "table" and entry.warn
            elseif btn.mode == "dungeon" then
                local guid = UnitGUID("player")
                local altData = guid and SfuiDB.alts and SfuiDB.alts[guid]
                return altData and altData.voidcoreTargets
                    and altData.voidcoreTargets[btn.keyID]
            end
            return false
        end

        w.Refresh = function(self)
            if not self.keyID then
                self.icon:SetAlpha(0)
                return
            end
            if IsWarned(self) then
                self.icon:SetVertexColor(0.8, 0.4, 1.0, 1)
                self.icon:SetAlpha(1.0)
            else
                self.icon:SetVertexColor(0.3, 0.3, 0.3, 1)
                self.icon:SetAlpha(0.25)
            end
        end

        w:SetScript("OnClick", function(self)
            if not self.keyID then return end
            if self.mode == "boss" then
                local db = DB()
                local entry = db.bosses[self.keyID]
                if type(entry) ~= "table" then
                    entry = { spec = (type(entry) == "number" and entry or 0) }
                    db.bosses[self.keyID] = entry
                end
                entry.warn = not entry.warn
            elseif self.mode == "dungeon" then
                local guid = UnitGUID("player")
                if not guid then return end
                SfuiDB.alts = SfuiDB.alts or {}
                SfuiDB.alts[guid] = SfuiDB.alts[guid] or {}
                SfuiDB.alts[guid].voidcoreTargets = SfuiDB.alts[guid].voidcoreTargets or {}
                local targets = SfuiDB.alts[guid].voidcoreTargets
                targets[self.keyID] = not targets[self.keyID]
                -- Sync alts panel if visible
                if sfui.alts and sfui.alts.UpdateUI then sfui.alts.UpdateUI() end
            end
            self:Refresh()
        end)

        w:SetScript("OnEnter", function(self)
            if not self.keyID then return end
            if GameTooltip then
                pcall(function()
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if IsWarned(self) then
                        GameTooltip:SetText("bonus roll reminder |cff00ff00enabled|r")
                        GameTooltip:AddLine("|cffaaaaaaleft-click|r to disable", 1, 1, 1)
                    else
                        GameTooltip:SetText("bonus roll reminder |cffff0000disabled|r")
                        GameTooltip:AddLine("|cffaaaaaaleft-click|r to enable", 1, 1, 1)
                    end
                    GameTooltip:Show()
                end)
            end
        end)
        w:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)

        r.warnBtn = w

        rowPool[rowCount] = r
    end
    r:SetParent(parent)
    r:ClearAllPoints()
    r:Show()
    return r
end

local function ReleaseRows()
    for i = 1, rowCount do
        local r = rowPool[i]
        if r then
            r.linkBtn.encounterID = nil
            r.linkBtn.instanceID  = nil
            r:Hide()
            -- do NOT SetParent(nil) — keeps the frame in its pool correctly
            if r.specBtn then
                r.specBtn:Hide()
                r.specBtn.keyID      = nil
                r.specBtn.field      = nil
                r.specBtn.storageKey = nil
            end
            if r.warnBtn then
                r.warnBtn:Hide()
                r.warnBtn.keyID = nil
                r.warnBtn.mode  = nil
            end
        end
    end
    rowCount = 0
end

-- Pool helpers for non-frame regions (FontStrings, Textures) on the content frame.
-- These can't be destroyed so we create once and reuse.
local function AcquireFontString(pool, parent, layer, fontObj)
    for _, fs in ipairs(pool) do
        if not fs.inUse then
            fs.inUse = true
            fs:Show()
            return fs
        end
    end
    local fs = parent:CreateFontString(nil, layer, fontObj)
    fs.inUse = true
    pool[#pool + 1] = fs
    return fs
end

local function AcquireTexture(pool, parent, layer)
    for _, tx in ipairs(pool) do
        if not tx.inUse then
            tx.inUse = true
            tx:Show()
            return tx
        end
    end
    local tx = parent:CreateTexture(nil, layer)
    tx.inUse = true
    pool[#pool + 1] = tx
    return tx
end

local function ReleaseRegionPool(pool)
    for _, r in ipairs(pool) do
        r.inUse = false
        r:Hide()
    end
end

-- ─── Content builders ─────────────────────────────────────────────────────────
-- Both return the pixel height consumed so the frame can auto-size.

local function BuildRaidContent(content, width)
    content.fsPool  = content.fsPool or {}
    content.sepPool = content.sepPool or {}

    ReleaseRows()
    ReleaseRegionPool(content.fsPool)
    ReleaseRegionPool(content.sepPool)

    local raids = GetRaidData()
    local y = -PAD

    local h1 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h1:ClearAllPoints()
    h1:SetPoint("TOPLEFT", PAD + ICON_SIZE + 5, y)
    h1:SetText("boss")
    h1:SetTextColor(0.45, 0.45, 0.45, 1)

    local h2 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h2:ClearAllPoints()
    h2:SetPoint("TOPRIGHT", -PAD, y)
    h2:SetText("loot spec")
    h2:SetTextColor(0.45, 0.45, 0.45, 1)
    y = y - 18

    if #raids == 0 then
        local msg = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        msg:ClearAllPoints()
        msg:SetPoint("TOPLEFT", PAD, y - 8)
        msg:SetText("no raids found for current tier")
        msg:SetTextColor(0.4, 0.4, 0.4, 1)
        return 60
    end

    -- Special Global Row for World Bosses
    local wbRow = AcquireRow(content)
    wbRow:SetSize(width, ROW_H)
    wbRow:SetPoint("TOPLEFT", 0, y)
    wbRow.bg:SetColorTexture(0.05, 0.05, 0.05, 0.35)
    wbRow.icon:SetTexture(132049) -- INV_Misc_Map_01 or similar world icon
    wbRow.icon:Show()
    wbRow.nameFS:SetText("All World Bosses")
    wbRow.nameFS:SetTextColor(1.0, 0.8, 0.0, 1)

    wbRow.specBtn.keyID = "worldbosses"
    wbRow.specBtn.field = "spec"
    wbRow.specBtn:Refresh()
    wbRow.specBtn:Show()

    wbRow.warnBtn:Hide() -- no warning for world bosses

    y = y - ROW_H - 16 -- Extra padding before the first raid section

    for _, raid in ipairs(raids) do
        local sh = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        sh:ClearAllPoints()
        sh:SetPoint("TOPLEFT", PAD, y - 4)
        sh:SetText(raid.name)
        sh:SetTextColor(0.4, 0.0, 1.0, 1)
        y = y - ROW_H - 2

        local sep = AcquireTexture(content.sepPool, content, "ARTWORK")
        sep:SetHeight(1)
        sep:ClearAllPoints()
        sep:SetPoint("TOPLEFT",  0, y + 2)
        sep:SetPoint("TOPRIGHT", 0, y + 2)
        sep:SetColorTexture(0.2, 0.0, 0.5, 0.5)

        for i, boss in ipairs(raid.bosses) do
            local encID = boss.encounterID
            local row   = AcquireRow(content)
            row:SetSize(width, ROW_H)
            row:SetPoint("TOPLEFT", 0, y)
            row.bg:SetColorTexture(0.05, 0.05, 0.05, (i % 2 == 0) and 0.0 or 0.35)

            if boss.icon then row.icon:SetTexture(boss.icon) ; row.icon:Show()
            else row.icon:Hide() end

            row.linkBtn.encounterID = encID
            row.linkBtn.instanceID  = raid.instanceID
            row.nameFS:SetText(boss.name)
            row.nameFS:SetWidth(NAME_COL_W)

            row.specBtn.field  = "spec"
            row.specBtn.keyID  = encID
            row.specBtn:Refresh()
            row.specBtn:Show()

            row.warnBtn.mode  = "boss"
            row.warnBtn.keyID = encID
            row.warnBtn:Refresh()
            row.warnBtn:Show()

            y = y - ROW_H
        end
        y = y - 8
    end

    return -y + PAD
end

local function BuildDungeonContent(content, width)
    content.fsPool  = content.fsPool or {}
    content.sepPool = content.sepPool or {}

    ReleaseRows()
    ReleaseRegionPool(content.fsPool)
    ReleaseRegionPool(content.sepPool)

    local dungeons = GetDungeonData()
    local y = -PAD

    local h1 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h1:ClearAllPoints()
    h1:SetPoint("TOPLEFT", PAD + ICON_SIZE + 5, y)
    h1:SetText("dungeon")
    h1:SetTextColor(0.45, 0.45, 0.45, 1)

    local h2 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h2:ClearAllPoints()
    h2:SetPoint("TOPRIGHT", -PAD, y)
    h2:SetText("loot spec")
    h2:SetTextColor(0.45, 0.45, 0.45, 1)
    y = y - 18

    if #dungeons == 0 then
        local msg = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        msg:ClearAllPoints()
        msg:SetPoint("TOPLEFT", PAD, y - 8)
        msg:SetText("no M+ dungeons found")
        msg:SetTextColor(0.4, 0.4, 0.4, 1)
        return 60
    end

    -- Special Global Row for Delves
    local delveRow = AcquireRow(content)
    delveRow:SetSize(width, ROW_H)
    delveRow:SetPoint("TOPLEFT", 0, y)
    delveRow.bg:SetColorTexture(0.05, 0.05, 0.05, 0.35)
    delveRow.icon:SetTexture(5286915) -- UI-Delves-Icon or similar
    delveRow.icon:Show()
    delveRow.nameFS:SetText("All Scenarios (including Delves)")
    delveRow.nameFS:SetTextColor(1.0, 0.8, 0.0, 1)

    delveRow.specBtn.keyID = "delves"
    delveRow.specBtn.storageKey = "dungeons"
    delveRow.specBtn.field = nil
    delveRow.specBtn:Refresh()
    delveRow.specBtn:Show()

    delveRow.warnBtn:Hide() -- no warning for delves

    y = y - ROW_H - 16

    for i, dung in ipairs(dungeons) do
        local mapID = dung.mapID
        local row   = AcquireRow(content)
        row:SetSize(width, ROW_H)
        row:SetPoint("TOPLEFT", 0, y)
        row.bg:SetColorTexture(0.05, 0.05, 0.05, (i % 2 == 0) and 0.0 or 0.35)

        if dung.texture then row.icon:SetTexture(dung.texture) ; row.icon:Show()
        else row.icon:Hide() end

        row.linkBtn.instanceID  = dung.instanceID
        row.linkBtn.encounterID = nil
        row.nameFS:SetText(dung.name)
        row.nameFS:SetWidth(NAME_COL_W)

        row.specBtn.field      = nil
        row.specBtn.storageKey = "dungeons"
        row.specBtn.keyID      = mapID
        row.specBtn:Refresh()
        row.specBtn:Show()

        row.warnBtn.mode  = "dungeon"
        row.warnBtn.keyID = mapID
        row.warnBtn:Refresh()
        row.warnBtn:Show()

        y = y - ROW_H
    end

    return -y + PAD
end


-- ─── Frame ────────────────────────────────────────────────────────────────────
local frame = nil

function sfui.lootspec.CreateFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "SfuiLootSpecFrame", UIParent, "BackdropTemplate")
    table.insert(UISpecialFrames, "SfuiLootSpecFrame")
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(FRAME_W, 400)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
    frame:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)

    local MkBtn = sfui.common.create_flat_button

    -- row 1: title / close
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("|cff6600ffsfui|r loot spec")

    local closeBtn = MkBtn(frame, "x", 20, 20)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- row 2: default spec label  [spec button]  [auto-swap cb]
    local defLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    defLabel:SetPoint("TOPLEFT", 10, -33)
    defLabel:SetText("default spec:")
    defLabel:SetTextColor(0.5, 0.5, 0.5, 1)

    local defBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    defBtn:SetSize(COL_W, 18)
    defBtn:SetPoint("LEFT", defLabel, "RIGHT", 6, 0)
    defBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    defBtn:SetBackdropColor(0.05, 0.05, 0.05, 1)
    local defIcon = defBtn:CreateTexture(nil, "ARTWORK")
    defIcon:SetSize(14, 14)
    defIcon:SetPoint("LEFT", 3, 0)
    defIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local defLbl = defBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    defLbl:SetPoint("LEFT", defIcon, "RIGHT", 4, 0)
    defLbl:SetJustifyH("LEFT")

    local function RefreshDefBtn()
        local specID = DB().defaultSpec or 0
        if specID == 0 then
            defIcon:Hide()
            defLbl:SetText("current spec")
            defLbl:SetTextColor(0.35, 0.35, 0.35, 1)
        else
            local icon = SpecIcon(specID)
            if icon then
                defIcon:SetTexture(icon)
                defIcon:Show()
            else defIcon:Hide() end

            local specColor = sfui.config and sfui.config.spec_colors and sfui.config.spec_colors[specID]
            if specColor then
                defLbl:SetTextColor(specColor[1], specColor[2], specColor[3], 1)
            else
                local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
                local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
                if cc then
                    defLbl:SetTextColor(cc.r, cc.g, cc.b, 1)
                else
                    defLbl:SetTextColor(0.0, 0.8, 1.0, 1)
                end
            end

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
            pcall(function()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("spec restored after boss loot")
                GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle", 1, 1, 1)
                GameTooltip:AddLine("|cffaaaaaaright-click|r to reset", 1, 1, 1)
                GameTooltip:Show()
            end)
        end
    end)
    defBtn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- inline auto-swap checkbox
    local enableCB = sfui.common.create_checkbox(frame, "auto-swap",
        function() return DB().enabled end,
        function(val) DB().enabled = val end,
        "enable/disable automatic loot spec swaps")
    enableCB:SetSize(14, 14)
    enableCB:SetPoint("LEFT", defBtn, "RIGHT", 14, 0)
    -- label already set by create_checkbox; just ensure font is small
    if enableCB.text then
        enableCB.text:SetFontObject("GameFontNormalSmall")
        enableCB.text:SetTextColor(0.5, 0.5, 0.5, 1)
    end

    -- row 3: tabs
    local TAB_Y   = -57
    local tabRaid = MkBtn(frame, "raids", 68, 20)
    local tabDung = MkBtn(frame, "dungeons", 68, 20)
    tabRaid:SetPoint("TOPLEFT", 10, TAB_Y)
    tabDung:SetPoint("LEFT", tabRaid, "RIGHT", 4, 0)

    -- subtle separator under tabs
    local sepTex = frame:CreateTexture(nil, "ARTWORK")
    sepTex:SetHeight(1)
    sepTex:SetPoint("TOPLEFT", 0, TAB_Y - 24)
    sepTex:SetPoint("TOPRIGHT", 0, TAB_Y - 24)
    sepTex:SetColorTexture(0.2, 0.0, 0.5, 0.5)

    -- content area — no scrollframe; resized dynamically
    local CONTENT_Y = TAB_Y - 28
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 0, CONTENT_Y)
    content:SetPoint("TOPRIGHT", 0, CONTENT_Y)
    content:SetHeight(1)
    frame.content = content

    -- footer hint
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", 10, 8)
    hint:SetText("left-click to cycle  ·  right-click to clear")
    hint:SetTextColor(0.28, 0.28, 0.28, 1)

    -- auto-size helper
    local function FitFrame(contentH)
        contentH = math.max(contentH, 1)
        content:SetHeight(contentH)
        local total = math.max(MIN_FRAME_H, math.min(MAX_FRAME_H, HEADER_H + contentH + FOOTER_H))
        frame:SetHeight(total)
    end

    -- tab switching
    local activeTab = "raids"

    local function SetActiveTab(tab)
        activeTab = tab

        if tab == "raids" then
            tabRaid:SetBackdropColor(0.14, 0.0, 0.38, 1)
            tabRaid:SetBackdropBorderColor(0.4, 0.0, 1.0, 1)
            tabDung:SetBackdropColor(0.0, 0.0, 0.0, 1)
            tabDung:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
            FitFrame(BuildRaidContent(content, FRAME_W - 10))
        else
            tabDung:SetBackdropColor(0.14, 0.0, 0.38, 1)
            tabDung:SetBackdropBorderColor(0.4, 0.0, 1.0, 1)
            tabRaid:SetBackdropColor(0.0, 0.0, 0.0, 1)
            tabRaid:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
            FitFrame(BuildDungeonContent(content, FRAME_W - 10))
        end
    end

    tabRaid:SetScript("OnClick", function() SetActiveTab("raids") end)
    tabDung:SetScript("OnClick", function() SetActiveTab("dungeons") end)

    frame:SetScript("OnShow", function()
        RefreshDefBtn()
        SetActiveTab(activeTab)
    end)

    function sfui.lootspec.Rebuild()
        if frame and frame:IsShown() then
            RefreshDefBtn()
            local t = activeTab; activeTab = nil
            SetActiveTab(t)
        end
    end

    frame:Hide()
    sfui.lootspec.frame = frame
    return frame
end

-- ─── Toggle / Initialize ──────────────────────────────────────────────────────
function sfui.lootspec.Toggle()
    if not frame then frame = sfui.lootspec.CreateFrame() end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function sfui.lootspec.initialize()
    -- DB schema initialized lazily via DB() on first access
end
