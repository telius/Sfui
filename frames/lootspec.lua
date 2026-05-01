local addonName, addon          = ...
---@diagnostic disable: undefined-global, undefined-field
sfui                            = sfui or {}
sfui.lootspec                   = {}

local CreateFrame               = CreateFrame
local UIParent                  = UIParent
local GameTooltip               = GameTooltip
local GetNumSpecializations     = GetNumSpecializations
local GetSpecialization         = GetSpecialization
local GetSpecializationInfo     = GetSpecializationInfo
local GetSpecializationInfoByID = GetSpecializationInfoByID
local GetLootSpecialization     = GetLootSpecialization
local SetLootSpecialization     = SetLootSpecialization
local UnitClass                 = UnitClass
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
local CB_COL_W                  = 28  -- bonus roll checkbox column width
local FRAME_W                   = 620
local HEADER_H                  = 82 -- pixels occupied by title/controls/tabs
local FOOTER_H                  = 24
local MIN_FRAME_H               = 160
local MAX_FRAME_H               = 860
-- Pre-computed name column width (constant since all terms are constants).
-- width passed to builders is always FRAME_W-10.
local NAME_COL_W = (FRAME_W - 10) - COL_W - CB_COL_W - PAD * 4 - ICON_SIZE

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
    db.bonusDungeons  = db.bonusDungeons or {}

    -- Migrate flat boss specIDs → nested { spec, bonus } tables.
    -- bonus is boolean: true = use voidcore, false/nil = suppress BonusRollFrame.
    -- _migrated sentinel prevents re-running this loop on every session start.
    if not db._migrated then
        for k, v in pairs(db.bosses) do
            if type(v) == "number" then
                db.bosses[k] = { spec = v, bonus = false }
            elseif type(v) == "table" and type(v.bonus) == "number" then
                v.bonus = (v.bonus ~= 0)
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

local function SpecName(specID)
    if specID == 0 then return "— off —" end
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

local function ApplyLootSpec(specID, reason)
    if specID == nil then return end
    if GetLootSpecialization() == specID then return end
    SetLootSpecialization(specID)
    if reason then
        sfui.common.print(string.format(
            "loot spec → |cff00ffff%s|r (%s)", SpecName(specID), reason))
    end
end

local function RestoreDefault(reason)
    ApplyLootSpec(DB().defaultSpec, reason)
end

-- Returns the configured specID for the current active M+ dungeon, or nil.
local function GetActiveMPlusSpec()
    local mapID = C_ChallengeMode.GetActiveChallengeMapID
        and C_ChallengeMode.GetActiveChallengeMapID()
    if not mapID then return nil end
    local specID = DB().dungeons[mapID]
    return (specID and specID ~= 0) and specID or nil
end

-- True when we should hold the applied spec rather than restore on loot/zone.
-- Raid: hold until next encounter or leaving.
-- M+:  hold until the end-of-run chest is looted or the player leaves.
--      After CHALLENGE_MODE_COMPLETED, GetActiveChallengeMapID() returns nil
--      so IsInActiveMPlus() becomes false — chest LOOT_CLOSED restores correctly.
local function IsInManagedInstance()
    local _, t = IsInInstance()
    if t == "raid" then return true end
    -- Active M+: "party" instance with a running challenge map
    if t == "party" and C_ChallengeMode.GetActiveChallengeMapID
        and C_ChallengeMode.GetActiveChallengeMapID() then
        return true
    end
    return false
end

local GetRaidData
local GetDungeonData

-- Tracks the encounterID of the currently active boss encounter.
local currentEncounterID   = nil
local currentEncounterName = nil
local currentChallengeMapID = nil

-- Set when we apply a non-default spec; cleared on restore.
-- Not persisted — resets to false on every reload/login (Lua state is fresh).
local specApplied = false

-- ─── Events ───────────────────────────────────────────────────────────────────

sfui.events.RegisterEvent("ENCOUNTER_START", function(_, encounterID, encounterName)
    currentEncounterID   = encounterID
    currentEncounterName = encounterName
    local db = DB()
    if not db.enabled then return end
    local entry  = db.bosses[encounterID]
    local specID = type(entry) == "table" and entry.spec or (type(entry) == "number" and entry) or 0
    if specID ~= 0 then
        specApplied = true
        ApplyLootSpec(specID, "encounter")
    else
        local _, instanceType = IsInInstance()
        if instanceType == "raid" and specApplied then
            specApplied = false
            RestoreDefault("unconfigured encounter")
        end
    end
end)

sfui.events.RegisterEvent("ENCOUNTER_END", function()
    currentEncounterID   = nil
    currentEncounterName = nil
end)

sfui.events.RegisterEvent("CHALLENGE_MODE_START", function()
    currentChallengeMapID = C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
end)

sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(1, function()
        currentChallengeMapID = C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
    end)
end)

-- ─── Bonus-roll checkbox suppression ─────────────────────────────────────────
-- Global guard: if no boss/dungeon has the checkbox enabled, never suppress.
-- Per-entry: checkbox ON → let BonusRollFrame show; OFF → hide it.
local suppressBonusUntil = 0
sfui.events.RegisterEvent("BONUS_ROLL_ACTIVATE", function()
    local db = DB()
    if not db.enabled then return end

    -- Global guard: if nobody has a checkbox ticked, never suppress.
    local anyBonus = false
    for _, entry in pairs(db.bosses) do
        if type(entry) == "table" and entry.bonus == true then anyBonus = true ; break end
    end
    if not anyBonus then
        for _, v in pairs(db.bonusDungeons) do
            if v == true then anyBonus = true ; break end
        end
    end
    if not anyBonus then return end

    local wantBonus = false
    if currentEncounterID then
        local entry = db.bosses[currentEncounterID]
        wantBonus = type(entry) == "table" and entry.bonus == true
    else
        local mapID = C_ChallengeMode.GetActiveChallengeMapID
            and C_ChallengeMode.GetActiveChallengeMapID()
        if not mapID then mapID = currentChallengeMapID end
        if mapID then wantBonus = db.bonusDungeons[mapID] == true end
    end

    if not wantBonus then
        suppressBonusUntil = GetTime() + 10
        if BonusRollFrame then
            BonusRollFrame:Hide()
            if not BonusRollFrame.sfuiHooked then
                BonusRollFrame.sfuiHooked = true
                hooksecurefunc(BonusRollFrame, "Show", function(self)
                    if GetTime() < suppressBonusUntil then
                        self:Hide()
                    end
                end)
            end
        end
        -- Notify the player that the voidcore prompt was suppressed.
        local ctx
        if currentEncounterName then
            ctx = currentEncounterName
        else
            local mapID = C_ChallengeMode.GetActiveChallengeMapID
                and C_ChallengeMode.GetActiveChallengeMapID()
            if not mapID then mapID = currentChallengeMapID end
            ctx = mapID and (C_ChallengeMode.GetMapUIInfo(mapID)) or "unknown"
        end
        sfui.common.print(string.format(
            "bonus roll suppressed |cffaaaaaa(%s)|r", ctx or "?"))
    end
end)


sfui.events.RegisterEvent("LOOT_CLOSED", function()
    local db = DB()
    if not db.enabled then return end
    -- Inside a managed instance (raid or active M+) hold the spec so it is
    -- correct for every subsequent loot window (trash, coins, boss body).
    -- After the M+ timer ends IsInManagedInstance() becomes false, so closing
    -- the end-of-run chest lands here and correctly restores the default.
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
    end
end)

-- CHALLENGE_MODE_COMPLETED is intentionally NOT hooked: it fires when the
-- timer stops, before the end-of-run chest is available. Restore is deferred
-- to LOOT_CLOSED (chest opened) or PLAYER_ENTERING_WORLD (left without looting).

sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if not SfuiDB then return end   -- saved-variables not yet loaded
    local db = DB()
    if not db.enabled then return end
    local mplusSpec = GetActiveMPlusSpec()
    if mplusSpec then
        specApplied = true
        ApplyLootSpec(mplusSpec, "entered M+ instance")
        return
    end
    if not IsInManagedInstance() and specApplied then
        specApplied = false
        RestoreDefault("left instance")
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
GetRaidData = function()
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

        -- MUST use securecall to prevent our addon from silently hijacking the
        -- Encounter Journal C++ state. If we do this unsecurely, the next time
        -- the user hovers an EJ Item Button, the tooltip will spread our taint
        -- directly into the GameTooltip money frame processor and crash.
        securecall(EJ_SelectInstance, instanceID)
        local encIdx = 1
        while true do
            -- EJ_GetEncounterInfoByIndex: name, description, bossID, rootSectionID, link
            local encName, _, bossID = EJ_GetEncounterInfoByIndex(encIdx)
            if not bossID or bossID == 0 then break end
            -- EJ_GetCreatureInfo: id, name, description, displayInfo, iconImage, uiModelSceneID
            local _, _, _, _, iconImage = EJ_GetCreatureInfo(1, bossID)
            table.insert(raid.bosses, {
                name        = encName,
                encounterID = bossID,
                icon        = iconImage,
            })
            encIdx = encIdx + 1
        end
        if #raid.bosses > 0 then table.insert(raids, raid) end
        instIdx = instIdx + 1
    end
    if oldInstance then securecall(EJ_SelectInstance, oldInstance) end
    raidDataCache = raids

    -- Option A: Prune orphaned data from previous seasons
    local db = DB()
    if db then
        local validBosses = {}
        for _, raid in ipairs(raids) do
            for _, boss in ipairs(raid.bosses) do
                validBosses[boss.encounterID] = true
            end
        end
        for encID in pairs(db.bosses) do
            if not validBosses[encID] then
                db.bosses[encID] = nil
            end
        end
    end

    return raids
end

local dungeonDataCache = nil
GetDungeonData = function()
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

    -- Option A: Prune orphaned M+ data from previous seasons
    local db = DB()
    if db then
        local validDungs = {}
        for _, dung in ipairs(dungeons) do
            validDungs[dung.mapID] = true
        end
        for mapID in pairs(db.dungeons) do
            if not validDungs[mapID] then db.dungeons[mapID] = nil end
        end
        for mapID in pairs(db.bonusDungeons) do
            if not validDungs[mapID] then db.bonusDungeons[mapID] = nil end
        end
    end

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
                        entry = { spec = (type(entry) == "number" and entry or 0), bonus = false }
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
                local specID = GetSpecID(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(specID == 0 and "no swap configured" or SpecName(specID))
                GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle spec", 1, 1, 1)
                GameTooltip:AddLine("|cffaaaaaaright-click|r to clear", 1, 1, 1)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return b
        end

        -- loot spec picker (anchored right, single column)
        r.specBtn = MakeSpecButton(-PAD)

        -- bonus roll checkbox (centered in CB_COL_W, to the LEFT of specBtn)
        local cb = CreateFrame("CheckButton", nil, r, "BackdropTemplate")
        cb:SetSize(14, 14)
        cb:SetPoint("RIGHT", r.specBtn, "LEFT", -(PAD), 0)
        local app = sfui.config and sfui.config.appearance
        local hi  = app and app.highlightColor or { 0.4, 0.0, 1.0 }
        cb:SetBackdrop({
            bgFile   = "Interface/Buttons/WHITE8X8",
            edgeFile = "Interface/Buttons/WHITE8X8",
            edgeSize = 1,
        })
        cb:SetBackdropColor(0.05, 0.05, 0.05, 1)
        cb:SetBackdropBorderColor(0, 0, 0, 1)
        cb:SetCheckedTexture("Interface/Buttons/WHITE8X8")
        cb:GetCheckedTexture():SetVertexColor(hi[1], hi[2], hi[3], 1)
        cb:GetCheckedTexture():SetPoint("TOPLEFT",     2, -2)
        cb:GetCheckedTexture():SetPoint("BOTTOMRIGHT", -2, 2)
        cb:SetHighlightTexture("Interface/Buttons/WHITE8X8")
        cb:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)

        -- Refresh reads from encID/mapID stored on the widget — no closure allocation.
        cb.Refresh = function(self)
            local val
            if self.encID then
                local entry = DB().bosses[self.encID]
                val = type(entry) == "table" and entry.bonus == true
            elseif self.mapID then
                val = DB().bonusDungeons[self.mapID] == true
            else
                val = false
            end
            self:SetChecked(val)
        end
        cb:SetScript("OnClick", function(self)
            local checked = self:GetChecked() == true
            if self.encID then
                local db    = DB()
                local entry = db.bosses[self.encID]
                if type(entry) ~= "table" then
                    entry = { spec = (type(entry) == "number" and entry or 0), bonus = false }
                    db.bosses[self.encID] = entry
                end
                entry.bonus = checked
            elseif self.mapID then
                DB().bonusDungeons[self.mapID] = checked
            end
        end)
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("use Nebulous Voidcore on this boss/dungeon")
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.bonusCB = cb

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
            if r.specBtn  then r.specBtn:Hide()  end
            if r.bonusCB  then r.bonusCB:Hide()  end
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
    h2:SetPoint("TOPRIGHT", -(CB_COL_W + PAD * 2), y)
    h2:SetText("loot spec")
    h2:SetTextColor(0.45, 0.45, 0.45, 1)

    local h3 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h3:ClearAllPoints()
    h3:SetPoint("TOPRIGHT", -PAD, y)
    h3:SetText("roll")
    h3:SetTextColor(0.45, 0.45, 0.45, 1)
    y = y - 18

    if #raids == 0 then
        local msg = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        msg:ClearAllPoints()
        msg:SetPoint("TOPLEFT", PAD, y - 8)
        msg:SetText("no raids found for current tier")
        msg:SetTextColor(0.4, 0.4, 0.4, 1)
        return 60
    end

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

            -- P2: store encID on the widget; shared getter/setter reads it.
            row.bonusCB.encID  = encID
            row.bonusCB.mapID  = nil
            row.bonusCB:Refresh()
            row.bonusCB:Show()

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
    h2:SetPoint("TOPRIGHT", -(CB_COL_W + PAD * 2), y)
    h2:SetText("loot spec")
    h2:SetTextColor(0.45, 0.45, 0.45, 1)

    local h3 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h3:ClearAllPoints()
    h3:SetPoint("TOPRIGHT", -PAD, y)
    h3:SetText("roll")
    h3:SetTextColor(0.45, 0.45, 0.45, 1)
    y = y - 18

    if #dungeons == 0 then
        local msg = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        msg:ClearAllPoints()
        msg:SetPoint("TOPLEFT", PAD, y - 8)
        msg:SetText("no M+ dungeons found")
        msg:SetTextColor(0.4, 0.4, 0.4, 1)
        return 60
    end

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

        -- P2: store mapID on the widget; shared getter/setter reads it.
        row.bonusCB.encID = nil
        row.bonusCB.mapID = mapID
        row.bonusCB:Refresh()
        row.bonusCB:Show()

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
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("spec restored after boss loot")
        GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle", 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaright-click|r to reset", 1, 1, 1)
        GameTooltip:Show()
    end)
    defBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    hint:SetText("left-click to cycle  ·  right-click to clear  ·  loot spec | bonus roll (raid only)")
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
