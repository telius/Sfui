local addonName, addon                               = ...
sfui                                                 = sfui or {}
sfui.mythic                                          = sfui.mythic or {}

-- ─── Config ────────────────────────────────────────────────
local g                                              = sfui.config
local mcfg                                           = g.mythic or {}

-- ─── Localize C-APIs ──────────────────────────────────────
local CreateFrame                                    = _G.CreateFrame
local UIParent                                       = _G.UIParent
local C_Timer                                        = _G.C_Timer
local C_ChallengeMode                                = _G.C_ChallengeMode
local C_Scenario                                     = _G.C_Scenario
local C_ScenarioInfo                                 = _G.C_ScenarioInfo
local C_DelvesUI                                     = _G.C_DelvesUI
local C_UIWidgetManager                              = _G.C_UIWidgetManager
local C_Spell                                        = _G.C_Spell
local C_GossipInfo                                   = _G.C_GossipInfo
local C_Reputation                                   = _G.C_Reputation
local C_MajorFactions                                = _G.C_MajorFactions
local BreakUpLargeNumbers                            = _G.BreakUpLargeNumbers or function(n) return tostring(n) end
local GetWorldElapsedTime                            = _G.GetWorldElapsedTime
local GameTooltip                                    = sfui.tooltip or _G.GameTooltip
local issecretvalue                                  = _G.issecretvalue or function() return false end
local math_max, math_min, math_floor, math_ceil, math_abs = math.max, math.min, math.floor, math.ceil, math.abs
local string_format                                  = string.format
local table_insert, table_sort, wipe                 = table.insert, table.sort, wipe
local date                                           = _G.date
local pcall, ipairs, pairs, type, tonumber, tostring =
    pcall, ipairs, pairs, type, tonumber, tostring

-- ─── Layout Constants ─────────────────────────────────────
local HUD_W                                          = mcfg.width or 280
local HUD_PAD                                        = 8
local TICKER_RATE                                    = 0.5 -- 2 Hz relaxed timer ticker

-- ─── Color Table (used only in BuildHUDFrame — unpack is fine there) ─
local COLORS                                         = {
    cyan      = { 0.00, 1.00, 1.00, 1 },
    white     = { 1.00, 1.00, 1.00, 1 },
    dim       = { 0.50, 0.50, 0.50, 1 },
    bg        = { 0.05, 0.05, 0.05, 0.88 },
    bar_fill  = { 0.00, 1.00, 1.00, 0.80 },
    bar_bg    = { 0.10, 0.10, 0.10, 0.90 },
    forces    = { 0.40, 0.00, 1.00, 0.85 },
    companion = { 0.90, 0.65, 0.20, 0.85 }, -- Amber/gold for Delve Companion EXP
}

-- ─── Pre-unpacked Color Scalars ───────────────────────────
-- Avoids unpack() vararg allocation on every hot-path call.
-- Named with a CLR_ prefix to distinguish from the COLORS table.
local CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B          = 0.20, 1.00, 0.40
local CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B          = 1.00, 1.00, 1.00
local CLR_DIM_R, CLR_DIM_G, CLR_DIM_B                = 0.50, 0.50, 0.50
local CLR_ONTIME_R, CLR_ONTIME_G, CLR_ONTIME_B       = 0.00, 1.00, 1.00
local CLR_YELLOW_R, CLR_YELLOW_G, CLR_YELLOW_B       = 1.00, 0.82, 0.00
local CLR_RED_R, CLR_RED_G, CLR_RED_B                = 1.00, 0.25, 0.25
local CLR_OVTM_R, CLR_OVTM_G, CLR_OVTM_B             = 1.00, 0.20, 0.20

-- ─── Hoisted Constants ────────────────────────────────────
-- Difficulty abbreviation map — allocated once, reused in InitDungeon.
local DIFF_ABBR                                      = { Mythic = "M", Heroic = "H", Normal = "N", Timewalking = "TW" }
local EMPTY_TABLE                                    = {}

-- ─── Helpers ──────────────────────────────────────────────
local function DeathSortComparator(a, b)
    return a.count > b.count
end
local function FormatTime(secs)
    if not secs or secs < 0 then secs = 0 end
    secs        = math_floor(secs)
    local hours = math_floor(secs / 3600)
    local mins  = math_floor((secs % 3600) / 60)
    local s     = secs % 60
    if hours > 0 then
        return string_format("%d:%02d:%02d", hours, mins, s)
    else
        return string_format("%d:%02d", mins, s)
    end
end

local function MakeText(parent, fontObj, r, g2, b, a, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormal")
    fs:SetShadowOffset(0, 0)
    fs:SetShadowColor(0, 0, 0, 0)
    if r then fs:SetTextColor(r, g2, b, a or 1) end
    if justify then fs:SetJustifyH(justify) end
    return fs
end

local function MakeStatusBar(parent, fill, bg)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture("Interface/Buttons/WHITE8X8")
    bar:SetStatusBarColor(unpack(fill or COLORS.bar_fill))
    local bgT = bar:CreateTexture(nil, "BACKGROUND")
    bgT:SetTexture("Interface/Buttons/WHITE8X8")
    bgT:SetVertexColor(unpack(bg or COLORS.bar_bg))
    bgT:SetAllPoints(bar)
    bar.bgT = bgT
    return bar
end

local function MakeSep(parent)
    local sep = parent:CreateTexture(nil, "ARTWORK")
    sep:SetTexture("Interface/Buttons/WHITE8X8")
    sep:SetVertexColor(0.3, 0.3, 0.3, 0.6)
    sep:SetHeight(1)
    return sep
end

-- ─── State ────────────────────────────────────────────────
-- _mode: nil = hidden, "mythic" = M+, "dungeon" = dungeon/delve/scenario
local _mode           = nil
local _isPreview      = false
local _ticker         = nil
local _timerID        = nil
local _timeLimit      = 0
local _bossSplits     = {}
local _forcesSplitTime = nil
local _currentMapID    = nil
local _currentLevel    = nil
local _currentBestRun  = nil
local _runCompleted    = false

-- ─── Objective Description Cleaning ──────────────────────
local function CleanObjectiveName(rawName)
    if not rawName or rawName == "" then return "" end
    if issecretvalue and issecretvalue(rawName) then return rawName end

    -- Strip trailing " defeated", " slain", " killed", " completed"
    local cleaned = rawName:gsub("%s+[Dd]efeated%s*$", "")
    cleaned = cleaned:gsub("%s+[Ss]lain%s*$", "")
    cleaned = cleaned:gsub("%s+[Kk]illed%s*$", "")
    cleaned = cleaned:gsub("%s+[Cc]ompleted%s*$", "")

    -- Strip leading "Defeat ", "Slay ", "Kill ", "Complete "
    cleaned = cleaned:gsub("^[Dd]efeat%s+", "")
    cleaned = cleaned:gsub("^[Ss]lay%s+", "")
    cleaned = cleaned:gsub("^[Kk]ill%s+", "")
    cleaned = cleaned:gsub("^[Cc]omplete%s+", "")

    -- Strip trailing whitespace
    cleaned = cleaned:gsub("%s+$", "")
    return (cleaned ~= "" and cleaned) or rawName
end

-- ─── Personal Best (PB) & Target Time Helpers ────────────
local function GetCurrentSeasonID()
    if C_MythicPlus and C_MythicPlus.GetCurrentSeason then
        local ok, sID = pcall(C_MythicPlus.GetCurrentSeason)
        if ok and sID and sID > 0 then return sID end
    end
    return 1
end

local function SyncBlizzardRunHistory()
    if not C_MythicPlus or not C_MythicPlus.GetRunHistory then return end
    local ok, history = pcall(C_MythicPlus.GetRunHistory, true, true)
    if not ok or not history or #history == 0 then return end

    local seasonID = GetCurrentSeasonID()
    SfuiDB = SfuiDB or {}
    SfuiDB.mythicBestTimes = SfuiDB.mythicBestTimes or {}
    SfuiDB.mythicBestTimes[seasonID] = SfuiDB.mythicBestTimes[seasonID] or {}

    for _, run in ipairs(history) do
        local mapID = run.mapChallengeModeID
        local level = run.level
        local duration = run.durationSec
        local completed = run.completed
        if mapID and level and duration and duration > 0 and completed then
            local mapData = SfuiDB.mythicBestTimes[seasonID][mapID]
            if not mapData then
                mapData = {}
                SfuiDB.mythicBestTimes[seasonID][mapID] = mapData
            end
            local existing = mapData[level]
            if not existing or not existing.duration or (duration < existing.duration) then
                mapData[level] = {
                    duration = duration,
                    level = level,
                    splits = existing and existing.splits or nil,
                    forces = existing and existing.forces or nil,
                }
            end
        end
    end
end

local function SaveCompletedRunRecord()
    if not _currentMapID or not _currentLevel then return end
    local seasonID = GetCurrentSeasonID()
    SfuiDB = SfuiDB or {}
    SfuiDB.mythicBestTimes = SfuiDB.mythicBestTimes or {}
    SfuiDB.mythicBestTimes[seasonID] = SfuiDB.mythicBestTimes[seasonID] or {}
    SfuiDB.mythicBestTimes[seasonID][_currentMapID] = SfuiDB.mythicBestTimes[seasonID][_currentMapID] or {}

    local mapData = SfuiDB.mythicBestTimes[seasonID][_currentMapID]
    local existing = mapData[_currentLevel] or {}

    local savedSplits = {}
    for k, v in pairs(_bossSplits) do
        savedSplits[k] = v
    end

    local curDur = existing.duration or (_totalTime and _totalTime > 0 and _totalTime) or nil

    mapData[_currentLevel] = {
        duration = curDur,
        level = _currentLevel,
        splits = savedSplits,
        forces = _forcesSplitTime or existing.forces,
    }
end

local function GetBestRun(mapID, currentLevel)
    if not mapID or mapID <= 0 then return nil end
    local seasonID = GetCurrentSeasonID()
    if not SfuiDB or not SfuiDB.mythicBestTimes or not SfuiDB.mythicBestTimes[seasonID] then
        return nil
    end
    local mapData = SfuiDB.mythicBestTimes[seasonID][mapID]
    if not mapData then return nil end

    -- 1. Exact level match
    if currentLevel and mapData[currentLevel] and mapData[currentLevel].duration then
        return mapData[currentLevel]
    end

    -- 2. Lower key levels (descending from currentLevel - 1 down to 2)
    if currentLevel and currentLevel > 2 then
        for lvl = currentLevel - 1, 2, -1 do
            if mapData[lvl] and mapData[lvl].duration then
                return mapData[lvl]
            end
        end
    end

    -- 3. Any best run for this map (overall fastest in-time)
    local best = nil
    for lvl, data in pairs(mapData) do
        if type(data) == "table" and data.duration then
            if not best or data.duration < best.duration then
                best = data
            end
        end
    end
    return best
end

-- Per-run cached values — reset in InitRun/InitDungeon
local _lastBossCount  = 0  -- for HideExtraBossRows: iterate only to last count
local _lastTimerPhase = -1 -- 0=ontime(>25%), 1=yellow, 2=red, 3=overtime
local _lastTimerText  = "" -- skip SetText when string unchanged
local _lastChestText  = "" -- skip SetText when string unchanged
local _lastDeathText  = "" -- skip SetText when string unchanged
local _lastDeaths     = -1
local _lastTimeLost   = -1

local _playerList     = {} -- list of { unit = ..., guid = ..., name = ..., class = ... }
local _playerClasses  = {} -- Name -> Class
local _playerDeaths   = {} -- Name -> deathCount

local function CacheGroupMembers()
    wipe(_playerClasses)
    local idx = 0

    local pGUID = UnitGUID("player")
    local pName = UnitName("player")
    local _, pClass = UnitClass("player")
    if pGUID and pName then
        idx = idx + 1
        local entry = _playerList[idx]
        if not entry then
            entry = {}; _playerList[idx] = entry
        end
        entry.unit = "player"; entry.guid = pGUID; entry.name = pName; entry.class = pClass
        _playerClasses[pName] = pClass
    end
    for i = 1, 4 do
        local unit = "party" .. i
        local guid = UnitGUID(unit)
        local name = UnitName(unit)
        local _, class = UnitClass(unit)
        if guid and name then
            idx = idx + 1
            local entry = _playerList[idx]
            if not entry then
                entry = {}; _playerList[idx] = entry
            end
            entry.unit = unit; entry.guid = guid; entry.name = name; entry.class = class
            _playerClasses[name] = class
        end
    end
    -- Nil out stale entries beyond current count
    for i = idx + 1, #_playerList do
        _playerList[i] = nil
    end
end

local MF = nil -- main frame handle

-- ─── Public API ───────────────────────────────────────────
function sfui.mythic.IsActive() return _mode ~= nil end

function sfui.mythic.IsMythicMode() return _mode == "mythic" end

function sfui.mythic.IsDungeonMode() return _mode == "dungeon" end

function sfui.mythic.IsEnabled()
    if SfuiDB and SfuiDB.mythicHudEnabled ~= nil then
        return SfuiDB.mythicHudEnabled
    end
    return mcfg.enabled ~= false
end

-- ─── Static Pools for Delve / Nemesis Structures ─────────
local staticDelveInfo      = {
    isDelve = true,
    name = nil,
    tierText = nil,
    isBountiful = false,
    bountyTooltip = nil,
    livesText = nil,
    livesRemaining = nil,
    livesTooltip = nil,
    livesIcon = nil,
    currencies = {},
    spells = {},
}
local staticNemesisInfo    = {
    hasNemesis = false,
    isDone = false,
    text = nil,
    current = nil,
    total = nil,
    tooltip = nil,
    icon = nil,
}
local staticWidgetSetIDs   = {}
local staticWidgetIDs      = {}
local currencyPool         = {}
local spellPool            = {}
local staticDeathBreakdown = {}
local deathBreakdownPool   = {}
local staticForcesInfo     = {}
local MAX_DELVE_POOL_SIZE  = 30

local function ReleaseDelveSubTables(info)
    for i = #info.currencies, 1, -1 do
        local c = table.remove(info.currencies, i)
        wipe(c)
        if #currencyPool < MAX_DELVE_POOL_SIZE then
            table.insert(currencyPool, c)
        end
    end
    for i = #info.spells, 1, -1 do
        local s = table.remove(info.spells, i)
        wipe(s)
        if #spellPool < MAX_DELVE_POOL_SIZE then
            table.insert(spellPool, s)
        end
    end
end

-- ─── Delve Info Extraction ────────────────────────────────
local function GetSpellTooltipText(spellID)
    if not spellID then return "" end
    if C_TooltipInfo and C_TooltipInfo.GetSpellByID then
        local ok, data = pcall(C_TooltipInfo.GetSpellByID, spellID)
        if ok and data and data.lines then
            local textParts = {}
            for _, line in ipairs(data.lines) do
                if line.leftText and not issecretvalue(line.leftText) and line.leftText ~= "" then
                    table.insert(textParts, line.leftText)
                end
            end
            if #textParts > 0 then
                return table.concat(textParts, " ")
            end
        end
    end
    if C_Spell and C_Spell.GetSpellDescription then
        local ok, desc = pcall(C_Spell.GetSpellDescription, spellID)
        if ok and desc and not issecretvalue(desc) and desc ~= "" then return desc end
    end
    return ""
end

local function GetDelveInfo()
    local scenName, scenType = nil, nil
    if C_Scenario and C_Scenario.GetInfo then
        local ok, n, _, _, _, _, _, _, _, _, t = pcall(C_Scenario.GetInfo)
        if ok then scenName, scenType = n, t end
    end

    local inDelve = (scenType == 8) or (C_DelvesUI and C_DelvesUI.HasActiveDelve and C_DelvesUI.HasActiveDelve())
    if not inDelve then
        return nil
    end

    local delveInfo = staticDelveInfo
    ReleaseDelveSubTables(delveInfo)
    delveInfo.name = scenName or "Delve"
    delveInfo.tierText = nil
    delveInfo.isBountiful = false
    delveInfo.bountyTooltip = nil
    delveInfo.livesText = nil
    delveInfo.livesRemaining = nil
    delveInfo.livesTooltip = nil
    delveInfo.livesIcon = nil

    wipe(staticWidgetSetIDs)
    if C_Scenario and C_Scenario.GetStepInfo then
        local ok, _, _, _, _, _, _, _, _, _, _, _, stepWidgetSetID = pcall(C_Scenario.GetStepInfo)
        if ok and stepWidgetSetID and stepWidgetSetID > 0 then
            table.insert(staticWidgetSetIDs, stepWidgetSetID)
        end
    end
    table.insert(staticWidgetSetIDs, 252)
    table.insert(staticWidgetSetIDs, 514)
    if C_DelvesUI and C_DelvesUI.GetDelveEntranceBackgroundWidgetSetID then
        local ok, bgSet = pcall(C_DelvesUI.GetDelveEntranceBackgroundWidgetSetID)
        if ok and bgSet then table.insert(staticWidgetSetIDs, bgSet) end
    end
    if C_UIWidgetManager then
        if C_UIWidgetManager.GetObjectiveTrackerWidgetSetID then
            local ok, id = pcall(C_UIWidgetManager.GetObjectiveTrackerWidgetSetID)
            if ok and id then table.insert(staticWidgetSetIDs, id) end
        end
        if C_UIWidgetManager.GetTopCenterWidgetSetID then
            local ok, id = pcall(C_UIWidgetManager.GetTopCenterWidgetSetID)
            if ok and id then table.insert(staticWidgetSetIDs, id) end
        end
        if C_UIWidgetManager.GetBelowMinimapWidgetSetID then
            local ok, id = pcall(C_UIWidgetManager.GetBelowMinimapWidgetSetID)
            if ok and id then table.insert(staticWidgetSetIDs, id) end
        end
    end

    wipe(staticWidgetIDs)
    local foundWidget = nil
    if C_UIWidgetManager then
        for _, setID in ipairs(staticWidgetSetIDs) do
            local ok, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
            if ok and widgets then
                for _, w in ipairs(widgets) do
                    local wID = (type(w) == "table" and w.widgetID) or w
                    if wID then
                        table.insert(staticWidgetIDs, wID)
                        if not foundWidget and C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo then
                            local okVis, vis = pcall(C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo,
                                wID)
                            if okVis and vis and vis.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                                foundWidget = vis
                            end
                        end
                    end
                end
            end
        end
    end

    if foundWidget then
        if foundWidget.headerText and not issecretvalue(foundWidget.headerText) and foundWidget.headerText ~= "" then
            delveInfo.name = foundWidget.headerText
        end
        if foundWidget.tierText and not issecretvalue(foundWidget.tierText) then
            delveInfo.tierText = foundWidget.tierText
        end

        if foundWidget.rewardInfo and foundWidget.rewardInfo.shownState ~= (_G.Enum and _G.Enum.UIWidgetRewardShownState and _G.Enum.UIWidgetRewardShownState.Hidden) then
            delveInfo.isBountiful = true
            local rTooltip = (foundWidget.rewardInfo.shownState == 1) and foundWidget.rewardInfo.earnedTooltip or
                foundWidget.rewardInfo.unearnedTooltip
            if rTooltip and not issecretvalue(rTooltip) then
                delveInfo.bountyTooltip = rTooltip
            end
        end

        if foundWidget.currencies then
            for _, c in ipairs(foundWidget.currencies) do
                local cText = (c.text and not issecretvalue(c.text)) and c.text or nil
                local cTooltip = (c.tooltip and not issecretvalue(c.tooltip)) and c.tooltip or ""
                local cLeading = (c.leadingText and not issecretvalue(c.leadingText)) and c.leadingText or ""
                if (cText and cText ~= "") or (c.iconFileID and c.iconFileID > 0) then
                    local isLives = false
                    local tt = cTooltip:lower()
                    if tt:find("reinforcement") or tt:find("live") or tt:find("revive") or tt:find("death") or tt:find("life") then
                        isLives = true
                    elseif cText and tonumber(cText) and not tostring(cText):find("/") and tonumber(cText) <= 5 and not delveInfo.livesText then
                        isLives = true
                    end

                    if isLives then
                        delveInfo.livesText = cText
                        delveInfo.livesRemaining = cText and tonumber(tostring(cText):match("(%d+)")) or nil
                        delveInfo.livesTooltip = cTooltip ~= "" and cTooltip or nil
                        delveInfo.livesIcon = c.iconFileID
                    else
                        local curObj = table.remove(currencyPool) or {}
                        curObj.icon = c.iconFileID
                        curObj.text = cText or ""
                        curObj.leadingText = cLeading
                        curObj.tooltip = cTooltip ~= "" and cTooltip or nil
                        table.insert(delveInfo.currencies, curObj)
                    end
                end
            end
        end

        if foundWidget.spells then
            for _, s in ipairs(foundWidget.spells) do
                if s.spellID and s.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                    local spObj = table.remove(spellPool) or {}
                    spObj.spellID = s.spellID
                    spObj.text = (s.text and not issecretvalue(s.text)) and s.text or ""
                    spObj.stack = (s.stackDisplay and s.stackDisplay > 0 and s.stackDisplay) or nil
                    spObj.showAsEarned = s.showAsEarned
                    local sTooltip = (s.tooltip and not issecretvalue(s.tooltip) and s.tooltip ~= "") and s.tooltip or nil
                    local tt = sTooltip or GetSpellTooltipText(s.spellID)
                    spObj.tooltip = (tt and not issecretvalue(tt) and tt ~= "") and tt or nil
                    table.insert(delveInfo.spells, spObj)
                end
            end
        end
    end

    -- Fallbacks for Tier
    if not delveInfo.tierText and C_DelvesUI then
        if C_DelvesUI.GetActiveDelveTier then
            local ok, tierInfo = pcall(C_DelvesUI.GetActiveDelveTier)
            if ok and tierInfo and tierInfo.tier then
                delveInfo.tierText = tostring(tierInfo.tier)
            end
        end
        if not delveInfo.tierText and C_DelvesUI.GetWorldTierDifficultyForActivePlayer then
            local ok, tier = pcall(C_DelvesUI.GetWorldTierDifficultyForActivePlayer)
            if ok and tier and tier > 0 then
                delveInfo.tierText = tostring(tier)
            end
        end
    end

    -- Fallback active spells
    if #delveInfo.spells == 0 and C_ScenarioInfo and C_ScenarioInfo.GetTieredEntranceActiveSpells then
        local ok, activeSpells = pcall(C_ScenarioInfo.GetTieredEntranceActiveSpells)
        if ok and activeSpells then
            for _, sID in ipairs(activeSpells) do
                local spObj = table.remove(spellPool) or {}
                spObj.spellID = sID
                spObj.tooltip = GetSpellTooltipText(sID)
                table.insert(delveInfo.spells, spObj)
            end
        end
    end

    return delveInfo
end

-- ─── Delve Companion Information ──────────────────────────
local staticCompanionInfo = {
    name = "",
    factionID = 0,
    level = 0,
    maxLevel = 0,
    currentXP = 0,
    nextLevelXP = 0,
    isMaxLevel = false,
    pct = 0,
    description = nil,
}

local function GetDelveCompanionInfo()
    if not (C_DelvesUI or C_GossipInfo or C_MajorFactions or C_Reputation) then return nil end

    local companionID = nil
    local companionFactionID = nil

    -- 1. Primary: Delves Season Faction -> playerCompanionID -> GetFactionForCompanion
    if C_DelvesUI and C_DelvesUI.GetDelvesFactionForSeason and C_MajorFactions and C_MajorFactions.GetMajorFactionData then
        local okS, seasonFactionID = pcall(C_DelvesUI.GetDelvesFactionForSeason)
        if okS and seasonFactionID and seasonFactionID > 0 then
            local okD, mData = pcall(C_MajorFactions.GetMajorFactionData, seasonFactionID)
            if okD and mData and mData.playerCompanionID and mData.playerCompanionID > 0 then
                companionID = mData.playerCompanionID
                if C_DelvesUI.GetFactionForCompanion then
                    local okF, fID = pcall(C_DelvesUI.GetFactionForCompanion, companionID)
                    if okF and fID and fID > 0 then
                        companionFactionID = fID
                    end
                end
            end
        end
    end

    -- 2. Secondary: Scan MajorFactions with active Journey Tracks
    if not companionFactionID and C_MajorFactions and C_MajorFactions.GetMajorFactionIDs then
        local ok, fIDs = pcall(C_MajorFactions.GetMajorFactionIDs)
        if ok and fIDs then
            for _, mfID in ipairs(fIDs) do
                local isJourney = C_MajorFactions.ShouldUseJourneyRewardTrack and C_MajorFactions.ShouldUseJourneyRewardTrack(mfID)
                if isJourney then
                    local okD, data = pcall(C_MajorFactions.GetMajorFactionData, mfID)
                    if okD and data and data.playerCompanionID and data.playerCompanionID > 0 then
                        companionID = data.playerCompanionID
                        if C_DelvesUI and C_DelvesUI.GetFactionForCompanion then
                            local okF, fID = pcall(C_DelvesUI.GetFactionForCompanion, companionID)
                            if okF and fID and fID > 0 then
                                companionFactionID = fID
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3. Tertiary: C_DelvesUI.GetCompanionInfoForActivePlayer
    if not companionFactionID and C_DelvesUI and C_DelvesUI.GetCompanionInfoForActivePlayer then
        local ok, cID = pcall(C_DelvesUI.GetCompanionInfoForActivePlayer)
        if ok and cID and cID > 0 then
            companionID = cID
            if C_DelvesUI.GetFactionForCompanion then
                local okF, fID = pcall(C_DelvesUI.GetFactionForCompanion, cID)
                if okF and fID and fID > 0 then companionFactionID = fID end
            end
        end
    end

    -- 4. Quaternary: Call GetFactionForCompanion with nil (engine defaults to active season companion)
    if not companionFactionID and C_DelvesUI and C_DelvesUI.GetFactionForCompanion then
        local okF, fID = pcall(C_DelvesUI.GetFactionForCompanion)
        if okF and fID and fID > 0 then
            companionFactionID = fID
        end
    end

    if not companionFactionID and not companionID then return nil end

    local name, currentLevel, maxLevel, currentXP, nextLevelXP, isMaxLevel, description = "companion", 0, 0, 0, 1, false, nil

    -- Check Friendship Reputation
    if companionFactionID and C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
        local repInfo = C_GossipInfo.GetFriendshipReputation(companionFactionID)
        local rankInfo = C_GossipInfo.GetFriendshipReputationRanks and C_GossipInfo.GetFriendshipReputationRanks(companionFactionID)
        if repInfo and repInfo.friendshipFactionID and repInfo.friendshipFactionID > 0 then
            currentLevel = rankInfo and rankInfo.currentLevel or (repInfo.reaction or 0)
            maxLevel = rankInfo and rankInfo.maxLevel or 0
            if repInfo.nextThreshold and repInfo.nextThreshold > 0 then
                currentXP = math_max(0, (repInfo.standing or 0) - (repInfo.reactionThreshold or 0))
                nextLevelXP = math_max(1, (repInfo.nextThreshold or 0) - (repInfo.reactionThreshold or 0))
                isMaxLevel = false
            else
                isMaxLevel = true
                currentXP = 1
                nextLevelXP = 1
            end
            local fData = C_Reputation and C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(companionFactionID)
            name = fData and fData.name or (rankInfo and rankInfo.name) or repInfo.name or name
            description = fData and fData.description or nil
        end
    end

    -- Check Major Faction / Renown if level is still 0
    if currentLevel == 0 and companionFactionID and C_MajorFactions and C_MajorFactions.IsMajorFaction and C_MajorFactions.IsMajorFaction(companionFactionID) then
        local mData = C_MajorFactions.GetMajorFactionData(companionFactionID)
        if mData then
            name = mData.name or name
            currentLevel = mData.renownLevel or 0
            maxLevel = mData.maxLevel or 0
            currentXP = mData.renownReputationEarned or 0
            nextLevelXP = mData.renownLevelThreshold or 2500
            isMaxLevel = mData.renownLevel >= mData.maxLevel
        end
    end

    if currentLevel == 0 and currentXP == 0 and not isMaxLevel then
        return nil
    end

    local c = staticCompanionInfo
    c.name = string.lower(name)
    c.factionID = companionFactionID or 0
    c.level = currentLevel
    c.maxLevel = maxLevel
    c.currentXP = currentXP
    c.nextLevelXP = nextLevelXP
    c.isMaxLevel = isMaxLevel
    c.pct = isMaxLevel and 100 or math_min(100, math_max(0, (currentXP / nextLevelXP) * 100))
    c.description = description

    return c
end

local function GetCriteriaInfoSafe(criteriaIndex, stepID)
    if stepID and C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfoByStep then
        local info = C_ScenarioInfo.GetCriteriaInfoByStep(stepID, criteriaIndex)
        if info then
            info.description = info.description or info.criteriaString or info.string
            return info
        end
    end
    if C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo then
        local info = C_ScenarioInfo.GetCriteriaInfo(criteriaIndex)
        if info then
            info.description = info.description or info.criteriaString or info.string
            return info
        end
    end
    if C_Scenario and C_Scenario.GetCriteriaInfo then
        local desc, cType, comp, quant, totQuant, flags, assetID, quantStr, critID, dur, el, isWeight = C_Scenario.GetCriteriaInfo(criteriaIndex)
        if desc and desc ~= "" then
            return {
                description = desc,
                criteriaType = cType,
                completed = comp,
                quantity = quant,
                totalQuantity = totQuant,
                flags = flags,
                assetID = assetID,
                quantityString = quantStr,
                criteriaID = critID,
                duration = dur,
                elapsed = el,
                isWeightedProgress = isWeight,
            }
        end
    end
    if stepID and C_Scenario and C_Scenario.GetCriteriaInfoByStep then
        local desc, cType, comp, quant, totQuant, flags, assetID, quantStr, critID, dur, el, isWeight = C_Scenario.GetCriteriaInfoByStep(stepID, criteriaIndex)
        if desc and desc ~= "" then
            return {
                description = desc,
                criteriaType = cType,
                completed = comp,
                quantity = quant,
                totalQuantity = totQuant,
                flags = flags,
                assetID = assetID,
                quantityString = quantStr,
                criteriaID = critID,
                duration = dur,
                elapsed = el,
                isWeightedProgress = isWeight,
            }
        end
    end
    return nil
end

-- ─── Nemesis Info Extraction ──────────────────────────────
local function GetNemesisInfo(delveInfo)
    local nemesis = staticNemesisInfo
    nemesis.hasNemesis = false
    nemesis.isDone = false
    nemesis.text = nil
    nemesis.current = nil
    nemesis.total = nil
    nemesis.tooltip = nil
    nemesis.icon = nil

    -- 1. Check Scenario criteria
    if C_Scenario and C_Scenario.GetStepInfo and C_ScenarioInfo then
        local ok, _, _, numCriteria, _, _, _, _, _, _, stepID = pcall(C_Scenario.GetStepInfo)
        if (not ok or not numCriteria or numCriteria == 0) and C_ScenarioInfo.GetScenarioStepInfo then
            local okStep, sInfo = pcall(C_ScenarioInfo.GetScenarioStepInfo)
            if okStep and sInfo and sInfo.numCriteria and sInfo.numCriteria > 0 then
                numCriteria = sInfo.numCriteria
                stepID = stepID or sInfo.stepID
                ok = true
            end
        end
        if ok and numCriteria and numCriteria > 0 then
            for i = 1, numCriteria do
                local info = GetCriteriaInfoSafe(i, stepID)
                local descText = (info and info.description and not issecretvalue(info.description) and info.description ~= "") and info.description or nil
                if descText then
                    local descLower = descText:lower()
                    if descLower:find("nemesis") or descLower:find("zekvir") or descLower:find("influence") or
                        descLower:find("empowered") or descLower:find("underpin") or descLower:find("ky'veza") then
                        nemesis.hasNemesis = true
                        nemesis.tooltip = descText
                        local tot = (info.totalQuantity and info.totalQuantity > 0) and info.totalQuantity or 4
                        nemesis.total = tot
                        if info.completed then
                            nemesis.isDone  = true
                            nemesis.current = tot
                        else
                            local cur       = info.quantity or 0
                            nemesis.current = cur
                            if cur >= tot and tot > 0 then
                                nemesis.isDone = true
                            end
                        end
                        break
                    end
                end
            end
        end
    end

    -- 2. Check Delve Spells / Affixes (Highest dynamic fidelity)
    if delveInfo and delveInfo.spells then
        for _, s in ipairs(delveInfo.spells) do
            local sTooltip = (s.tooltip and not issecretvalue(s.tooltip) and s.tooltip ~= "") and s.tooltip or nil
            local tt = (sTooltip or GetSpellTooltipText(s.spellID) or "")
            if issecretvalue(tt) then tt = "" end
            tt = tt:lower()
            
            local spellName = ""
            if s.spellID then
                local n = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(s.spellID)) or
                    (_G.GetSpellInfo and _G.GetSpellInfo(s.spellID))
                if n and not issecretvalue(n) then spellName = n:lower() end
            end

            if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or tt:find("empowered") or
                tt:find("underpin") or tt:find("ky'veza") or spellName:find("nemesis") or spellName:find("zekvir") or
                spellName:find("influence") or spellName:find("empowered") then
                nemesis.hasNemesis = true
                if s.spellID then
                    nemesis.icon = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(s.spellID)) or
                        (_G.GetSpellTexture and _G.GetSpellTexture(s.spellID)) or nemesis.icon
                end
                nemesis.tooltip = s.tooltip or nemesis.tooltip

                -- Determine total count (default 4)
                local totMatch = tt:match("(%d+)%s*empowered") or tt:match("(%d+)%s*groups?") or
                    tt:match("(%d+)%s*packs?") or tt:match("defeat (%d+)")
                if totMatch then
                    nemesis.total = tonumber(totMatch)
                end
                local tot = nemesis.total or 4
                nemesis.total = tot

                if s.showAsEarned then
                    nemesis.isDone = true
                    nemesis.current = tot
                end

                -- A. Primary: Tooltip remaining / progress string
                local cM, tM = tt:match("(%d+)%s*/%s*(%d+)")
                if cM and tM then
                    local c = tonumber(cM)
                    local t = tonumber(tM)
                    if c and t then
                        nemesis.current = c
                        nemesis.total   = t
                        if c >= t and t > 0 then nemesis.isDone = true end
                    end
                else
                    local remainMatch = tt:match("(%d+)%s*remain") or tt:match("remain%a*%s*:%s*(%d+)")
                    if remainMatch then
                        local rem = tonumber(remainMatch)
                        if rem and tot then
                            if rem == 0 then
                                nemesis.isDone = true
                                nemesis.current = tot
                            else
                                -- E.g. 3 remaining out of 4 -> 1 defeated!
                                nemesis.current = math_max(0, tot - rem)
                                if nemesis.current >= tot and tot > 0 then
                                    nemesis.isDone = true
                                end
                            end
                        end
                    end
                end

                -- B. Secondary: Dynamic live progress from direct spell text / stack count
                if not nemesis.current then
                    local cText, tText = (s.text or ""):match("(%d+)%s*/%s*(%d+)")
                    if cText and tText then
                        local c = tonumber(cText)
                        local t = tonumber(tText)
                        if c and t then
                            nemesis.current = c
                            nemesis.total   = t
                            if c >= t and t > 0 then nemesis.isDone = true end
                        end
                    elseif s.text and tonumber(s.text) and tonumber(s.text) > 0 then
                        local stNum = tonumber(s.text)
                        nemesis.current = stNum
                        if stNum >= tot and tot > 0 then
                            nemesis.isDone = true
                        end
                    elseif s.stack and tonumber(s.stack) and tonumber(s.stack) > 0 then
                        local st = tonumber(s.stack)
                        nemesis.current = st
                        if st >= tot and tot > 0 then
                            nemesis.isDone = true
                        end
                    end
                end

                -- Check player aura stack count if still nil
                if not nemesis.current and s.spellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                    local okA, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, s.spellID)
                    if okA and aura then
                        if aura.applications and aura.applications > 0 then
                            nemesis.current = aura.applications
                        elseif aura.points and aura.points[1] and aura.points[1] > 0 then
                            nemesis.current = aura.points[1]
                        end
                    end
                end
                break
            end
        end
    end

    -- 3. Check Delve Currencies
    if not nemesis.current and delveInfo and delveInfo.currencies then
        for _, c in ipairs(delveInfo.currencies) do
            local cTooltip = (c.tooltip and not issecretvalue(c.tooltip)) and c.tooltip or ""
            local cLeading = (c.leadingText and not issecretvalue(c.leadingText)) and c.leadingText or ""
            local tt = cTooltip:lower()
            local lt = cLeading:lower()
            if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or tt:find("empowered") or
                tt:find("underpin") or tt:find("ky'veza") or lt:find("nemesis") or lt:find("zekvir") or lt:find("influence") then
                nemesis.hasNemesis = true
                nemesis.icon = c.icon or nemesis.icon
                nemesis.tooltip = cTooltip ~= "" and cTooltip or nemesis.tooltip

                local valStr = (c.text and not issecretvalue(c.text) and c.text) or (c.leadingText and not issecretvalue(c.leadingText) and c.leadingText) or ""
                local cM, tM = valStr:match("(%d+)%s*/%s*(%d+)")
                if cM and tM then
                    nemesis.current = tonumber(cM)
                    nemesis.total   = tonumber(tM)
                elseif tonumber(valStr) then
                    nemesis.current = tonumber(valStr)
                end
                break
            end
        end
    end

    -- 4. Check UI Widgets in active sets
    if not nemesis.current and C_UIWidgetManager then
        for _, wID in ipairs(staticWidgetIDs) do
            if C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo then
                local okVis, vis = pcall(C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo, wID)
                if okVis and vis and vis.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                    local vTooltip = (vis.tooltip and not issecretvalue(vis.tooltip)) and vis.tooltip or ""
                    local vText = (vis.text and not issecretvalue(vis.text)) and vis.text or ""
                    local tt = vTooltip:lower()
                    local txt = vText:lower()
                    if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or txt:find("nemesis") or txt:find("zekvir") then
                        nemesis.hasNemesis = true
                        nemesis.tooltip = vTooltip ~= "" and vTooltip or nemesis.tooltip
                        local cW, tW = vText:match("(%d+)%s*/%s*(%d+)")
                        if cW and tW then
                            nemesis.current = tonumber(cW)
                            nemesis.total   = tonumber(tW)
                        elseif tonumber(vText) then
                            nemesis.current = tonumber(vText)
                        end
                        break
                    end
                end
            end
            if not nemesis.current and C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
                local okVis, vis = pcall(C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo, wID)
                if okVis and vis and vis.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                    local vTooltip = (vis.tooltip and not issecretvalue(vis.tooltip)) and vis.tooltip or ""
                    local vText = (vis.text and not issecretvalue(vis.text)) and vis.text or ""
                    local tt = vTooltip:lower()
                    local txt = vText:lower()
                    if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or txt:find("nemesis") or txt:find("zekvir") then
                        nemesis.hasNemesis = true
                        nemesis.tooltip = vTooltip ~= "" and vTooltip or nemesis.tooltip
                        local cW, tW = vText:match("(%d+)%s*/%s*(%d+)")
                        if cW and tW then
                            nemesis.current = tonumber(cW)
                            nemesis.total   = tonumber(tW)
                        elseif tonumber(vText) then
                            nemesis.current = tonumber(vText)
                        end
                        break
                    end
                end
            end
            if nemesis.current and nemesis.total then break end
        end
    end

    -- Ensure final format is always accurate
    if nemesis.hasNemesis then
        local tot = nemesis.total or 4
        local cur = nemesis.current

        if nemesis.isDone or (cur and cur >= tot and tot > 0) then
            nemesis.isDone  = true
            nemesis.current = tot
            nemesis.total   = tot
            nemesis.text    = string_format("%d/%d", tot, tot)
        elseif cur and cur >= 0 then
            nemesis.current = cur
            nemesis.total   = tot
            nemesis.text    = string_format("%d/%d", cur, tot)
        else
            nemesis.current = 0
            nemesis.total   = tot
            nemesis.text    = string_format("0/%d", tot)
        end
    end

    return nemesis
end

-- ─── Frame Construction ───────────────────────────────────
local function BuildHUDFrame()
    if MF then return end

    MF = CreateFrame("Frame", "SfuiMythicHUD", UIParent, "BackdropTemplate")
    MF:SetSize(HUD_W, 10)
    MF:SetClampedToScreen(true)
    MF:SetMovable(true)
    MF:EnableMouse(false)
    local posX = (SfuiDB and (SfuiDB.mythicHudX or SfuiDB.questlogX)) or mcfg.posX or -10
    local posY = (SfuiDB and (SfuiDB.mythicHudY or SfuiDB.questlogY)) or mcfg.posY or -10
    MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)

    MF:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    MF:SetBackdropColor(0.06, 0.06, 0.08, 0.88)
    MF:SetBackdropBorderColor(0, 0, 0, 0.9)

    -- Header: dungeon name + key/diff label
    local hdr = CreateFrame("Frame", nil, MF)
    hdr:SetPoint("TOPLEFT", MF, "TOPLEFT", HUD_PAD, -HUD_PAD)
    hdr:SetPoint("TOPRIGHT", MF, "TOPRIGHT", -HUD_PAD, -HUD_PAD)
    hdr:SetHeight(24)
    MF.header = hdr

    MF.dungeonText = MakeText(hdr, "GameFontNormal", unpack(COLORS.cyan))
    MF.dungeonText:SetPoint("TOPLEFT", hdr, "TOPLEFT", 0, 0)
    MF.dungeonText:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -60, 0)
    MF.dungeonText:SetJustifyH("LEFT")
    MF.dungeonText:SetText("Mythic+")

    MF.pbText = MakeText(hdr, "GameFontNormalSmall", CLR_DIM_R, CLR_DIM_G, CLR_DIM_B, 1, "LEFT")
    MF.pbText:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 0, 0)
    MF.pbText:SetText("")
    MF.pbText:Hide()

    MF.levelText = MakeText(hdr, "GameFontNormalLarge", 1, 0.82, 0, 1)
    MF.levelText:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", 0, 2)
    MF.levelText:SetJustifyH("RIGHT")
    MF.levelText:SetText("+?")

    -- Delve badges row (Currencies: Nemesis 3/4, Keys 1, Bountiful, Spells + Lives on Far Right)
    local delveRow = CreateFrame("Frame", nil, MF)
    delveRow:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    delveRow:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, -2)
    delveRow:SetHeight(18)
    delveRow:EnableMouse(false)
    MF.delveRow = delveRow
    MF.delveBadges = {}

    -- Dedicated Lives counter anchored all the way to the right
    local delveLivesFrame = CreateFrame("Frame", nil, delveRow)
    delveLivesFrame:SetPoint("TOPRIGHT", delveRow, "TOPRIGHT", 0, 0)
    delveLivesFrame:SetHeight(18)
    delveLivesFrame:EnableMouse(true)
    MF.delveLivesFrame = delveLivesFrame

    MF.delveLivesText = MakeText(delveLivesFrame, "GameFontNormalSmall", 0.3, 1, 0.3, 1, "RIGHT")
    MF.delveLivesText:SetPoint("RIGHT", delveLivesFrame, "RIGHT", 0, 0)
    MF.delveLivesText:SetJustifyH("RIGHT")
    MF.delveLivesText:SetText("")

    delveLivesFrame:SetScript("OnEnter", function(self)
        if GameTooltip and self.tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Delve Lives Remaining", 0.4, 1, 0.4)
            GameTooltip:AddLine(self.tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    delveLivesFrame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- Dedicated Nemesis counter next to Lives
    local delveNemesisFrame = CreateFrame("Frame", nil, delveRow)
    delveNemesisFrame:SetHeight(18)
    delveNemesisFrame:EnableMouse(true)
    MF.delveNemesisFrame = delveNemesisFrame

    MF.delveNemesisText = MakeText(delveNemesisFrame, "GameFontNormalSmall", 0.75, 0.40, 1.00, 1, "RIGHT")
    MF.delveNemesisText:SetPoint("RIGHT", delveNemesisFrame, "RIGHT", 0, 0)
    MF.delveNemesisText:SetJustifyH("RIGHT")
    MF.delveNemesisText:SetText("")

    delveNemesisFrame:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Nemesis Progress", 0.75, 0.35, 1)
            GameTooltip:AddLine(self.tooltip or "Nemesis Influence: Defeat empowered enemies to draw out the Nemesis.", 1,
                1, 1, true)
            GameTooltip:Show()
        end
    end)
    delveNemesisFrame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    delveRow:Hide()

    -- Affix icon row (M+ only)
    MF.affixRow = CreateFrame("Frame", nil, MF)
    MF.affixRow:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -4)
    MF.affixRow:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, -4)
    MF.affixRow:SetHeight(22)
    MF.affixes = {} -- pooled affix entries: { frame, icon, stackText }

    -- Timer bar (M+ only)
    local timerSection = CreateFrame("Frame", nil, MF)
    timerSection:SetPoint("TOPLEFT", MF.affixRow, "BOTTOMLEFT", 0, -6)
    timerSection:SetPoint("TOPRIGHT", MF.affixRow, "BOTTOMRIGHT", 0, -6)
    timerSection:SetHeight(16)
    timerSection:Hide()
    MF.timerSection = timerSection

    MF.timerBar = MakeStatusBar(timerSection, COLORS.bar_fill, COLORS.bar_bg)
    MF.timerBar:SetAllPoints(timerSection)
    MF.timerBar:SetMinMaxValues(0, 1)
    MF.timerBar:SetValue(0)

    -- Dedicated overlay frame above StatusBar fill
    local timerOverlay = CreateFrame("Frame", nil, MF.timerBar)
    timerOverlay:SetAllPoints(MF.timerBar)
    timerOverlay:SetFrameLevel(MF.timerBar:GetFrameLevel() + 5)
    MF.timerOverlay = timerOverlay

    MF.timerText = MakeText(timerOverlay, "GameFontHighlightSmall", 1, 1, 1, 1, "LEFT")
    MF.timerText:SetPoint("LEFT", timerOverlay, "LEFT", 4, 0)
    MF.timerText:SetJustifyH("LEFT")
    MF.timerText:SetText("--:-- / --:--")

    MF.chestText = MakeText(timerOverlay, "GameFontHighlightSmall", 0.20, 1.00, 0.40, 1, "CENTER")
    MF.chestText:SetPoint("CENTER", timerOverlay, "CENTER", 0, 0)
    MF.chestText:SetJustifyH("CENTER")
    MF.chestText:SetText("+3 --:--")

    -- Chest tick marks (+3 green, +2 yellow)
    MF.tick3 = timerOverlay:CreateTexture(nil, "OVERLAY")
    MF.tick3:SetTexture("Interface/Buttons/WHITE8X8")
    MF.tick3:SetVertexColor(0.20, 1.00, 0.40, 1)
    MF.tick3:SetSize(2, 16)
    MF.tick3:Hide()

    MF.tick2 = timerOverlay:CreateTexture(nil, "OVERLAY")
    MF.tick2:SetTexture("Interface/Buttons/WHITE8X8")
    MF.tick2:SetVertexColor(0.80, 0.80, 0.00, 1)
    MF.tick2:SetSize(2, 16)
    MF.tick2:Hide()

    -- Death counter frame with tooltip
    local deathFrame = CreateFrame("Frame", nil, timerOverlay)
    deathFrame:SetPoint("RIGHT", timerOverlay, "RIGHT", -4, 0)
    deathFrame:SetHeight(16)
    deathFrame:EnableMouse(true)
    deathFrame:SetFrameLevel(timerOverlay:GetFrameLevel() + 2)
    MF.deathFrame = deathFrame

    MF.deathText = MakeText(deathFrame, "GameFontHighlightSmall", 1, 0.25, 0.25, 1, "RIGHT")
    MF.deathText:SetPoint("RIGHT", deathFrame, "RIGHT", 0, 0)
    MF.deathText:SetJustifyH("RIGHT")
    MF.deathText:SetText("")

    deathFrame:SetScript("OnEnter", function(self)
        local okd, deaths, timeLostSec = pcall(C_ChallengeMode.GetDeathCount)
        if okd and deaths and deaths > 0 then
            local tl = timeLostSec or (deaths * 5)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(string_format("Deaths: %d", deaths), 1, 0.3, 0.3)
                GameTooltip:AddLine(string_format("Time lost: %s", FormatTime(tl)), 0.8, 0.8, 0.8)

                if _playerDeaths and next(_playerDeaths) then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Player Breakdown:", 1, 0.82, 0)
                    for i = #staticDeathBreakdown, 1, -1 do
                        local obj = table.remove(staticDeathBreakdown, i)
                        wipe(obj)
                        if #deathBreakdownPool < 20 then
                            table.insert(deathBreakdownPool, obj)
                        end
                    end
                    for name, count in pairs(_playerDeaths) do
                        local obj = table.remove(deathBreakdownPool) or {}
                        obj.name = name
                        obj.count = count
                        obj.class = _playerClasses[name]
                        table.insert(staticDeathBreakdown, obj)
                    end
                    table.sort(staticDeathBreakdown, DeathSortComparator)
                    for _, p in ipairs(staticDeathBreakdown) do
                        local colorCode = "ffffffff"
                        if p.class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[p.class] then
                            colorCode = _G.RAID_CLASS_COLORS[p.class].colorStr or "ffffffff"
                        end
                        GameTooltip:AddDoubleLine(string_format("|c%s%s|r", colorCode, p.name),
                            string_format("%d death%s", p.count, p.count > 1 and "s" or ""), 1, 1, 1, 0.7, 0.7, 0.7)
                    end
                end
                GameTooltip:Show()
            end
        end
    end)
    deathFrame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)


    -- Separator 1 (between header/delve/timer and bosses)
    local sep1 = MakeSep(MF)
    sep1:SetPoint("TOPLEFT", timerSection, "BOTTOMLEFT", 0, -4)
    sep1:SetPoint("TOPRIGHT", timerSection, "BOTTOMRIGHT", 0, -4)
    MF.sep1 = sep1

    -- Boss / objectives container
    MF.bossContainer = CreateFrame("Frame", nil, MF)
    MF.bossContainer:SetPoint("TOPLEFT", sep1, "BOTTOMLEFT", 0, -4)
    MF.bossContainer:SetPoint("TOPRIGHT", sep1, "BOTTOMRIGHT", 0, -4)
    MF.bossContainer:SetHeight(10)
    MF.bossRows = {}

    -- Separator 2 (between bosses and forces)
    local sep2 = MakeSep(MF)
    sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
    sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
    MF.sep2 = sep2

    -- Enemy Forces bar
    local forcesSection = CreateFrame("Frame", nil, MF)
    forcesSection:SetPoint("TOPLEFT", sep2, "BOTTOMLEFT", 0, -4)
    forcesSection:SetPoint("TOPRIGHT", sep2, "BOTTOMRIGHT", 0, -4)
    forcesSection:SetHeight(14)
    MF.forcesSection = forcesSection

    MF.forcesBar = MakeStatusBar(forcesSection, COLORS.forces, COLORS.bar_bg)
    MF.forcesBar:SetAllPoints(forcesSection)
    MF.forcesBar:SetMinMaxValues(0, 1)
    MF.forcesBar:SetValue(0)

    -- Dedicated overlay frame above Forces StatusBar fill
    local forcesOverlay = CreateFrame("Frame", nil, MF.forcesBar)
    forcesOverlay:SetAllPoints(MF.forcesBar)
    forcesOverlay:SetFrameLevel(MF.forcesBar:GetFrameLevel() + 5)
    MF.forcesOverlay = forcesOverlay

    MF.forcesText = MakeText(forcesOverlay, "GameFontHighlightSmall", 1, 1, 1, 1, "LEFT")
    MF.forcesText:SetPoint("LEFT", forcesOverlay, "LEFT", 4, 0)
    MF.forcesText:SetJustifyH("LEFT")
    MF.forcesText:SetText("0.00%")

    MF.forcesCountText = MakeText(forcesOverlay, "GameFontHighlightSmall", 0.95, 0.95, 0.95, 1, "RIGHT")
    MF.forcesCountText:SetPoint("RIGHT", forcesOverlay, "RIGHT", -4, 0)
    MF.forcesCountText:SetText("")

    -- Separator 3 (between forces/objectives and companion bar)
    local sep3 = MakeSep(MF)
    sep3:SetPoint("TOPLEFT", forcesSection, "BOTTOMLEFT", 0, -4)
    sep3:SetPoint("TOPRIGHT", forcesSection, "BOTTOMRIGHT", 0, -4)
    MF.sep3 = sep3

    -- Delve Companion Experience Bar
    local companionSection = CreateFrame("Frame", nil, MF)
    companionSection:SetPoint("TOPLEFT", sep3, "BOTTOMLEFT", 0, -4)
    companionSection:SetPoint("TOPRIGHT", sep3, "BOTTOMRIGHT", 0, -4)
    companionSection:SetHeight(14)
    MF.companionSection = companionSection

    MF.companionBar = MakeStatusBar(companionSection, COLORS.companion, COLORS.bar_bg)
    MF.companionBar:SetAllPoints(companionSection)
    MF.companionBar:SetMinMaxValues(0, 100)
    MF.companionBar:SetValue(0)

    local companionOverlay = CreateFrame("Frame", nil, MF.companionBar)
    companionOverlay:SetAllPoints(MF.companionBar)
    companionOverlay:SetFrameLevel(MF.companionBar:GetFrameLevel() + 5)
    companionOverlay:EnableMouse(true)
    MF.companionOverlay = companionOverlay

    MF.companionLeftText = MakeText(companionOverlay, "GameFontHighlightSmall", 1, 1, 1, 1, "LEFT")
    MF.companionLeftText:SetPoint("LEFT", companionOverlay, "LEFT", 4, 0)
    MF.companionLeftText:SetJustifyH("LEFT")
    MF.companionLeftText:SetText("")

    MF.companionRightText = MakeText(companionOverlay, "GameFontHighlightSmall", 0.95, 0.95, 0.95, 1, "RIGHT")
    MF.companionRightText:SetPoint("RIGHT", companionOverlay, "RIGHT", -4, 0)
    MF.companionRightText:SetText("")

    companionOverlay:SetScript("OnEnter", function(self)
        local info = GetDelveCompanionInfo()
        if info and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(info.name or "companion", 1, 0.82, 0)
            if info.isMaxLevel then
                GameTooltip:AddLine(string_format("level %d (max level)", info.level), 0.20, 1.00, 0.40)
            else
                GameTooltip:AddLine(string_format("level %d", info.level), 1, 1, 1)
                local curFmt = BreakUpLargeNumbers(info.currentXP)
                local maxFmt = BreakUpLargeNumbers(info.nextLevelXP)
                GameTooltip:AddDoubleLine("experience:", string_format("%s / %s (%.1f%%)", curFmt, maxFmt, info.pct), 0.7, 0.7, 0.7, 1, 1, 1)
            end
            if info.description and info.description ~= "" then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(info.description, 0.6, 0.6, 0.6, true)
            end
            GameTooltip:Show()
        end
    end)
    companionOverlay:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- Drag handle (shown only when unlocked)
    MF.dragBar = CreateFrame("Frame", nil, MF, "BackdropTemplate")
    MF.dragBar:SetPoint("TOPLEFT", MF, "TOPLEFT", 0, 0)
    MF.dragBar:SetPoint("TOPRIGHT", MF, "TOPRIGHT", 0, 0)
    MF.dragBar:SetHeight(4)
    MF.dragBar:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
    MF.dragBar:SetBackdropColor(0.4, 0.0, 1.0, 0.6)
    MF.dragBar:SetScript("OnMouseDown", function() MF:StartMoving() end)
    MF.dragBar:SetScript("OnMouseUp", function()
        MF:StopMovingOrSizing()
        if SfuiDB then
            local _, _, _, x, y = MF:GetPoint()
            SfuiDB.mythicHudX   = x
            SfuiDB.mythicHudY   = y
            SfuiDB.questlogX    = x
            SfuiDB.questlogY    = y
        end
        if sfui.questlog and sfui.questlog.UpdateAnchor then
            sfui.questlog.UpdateAnchor()
        end
    end)
    MF.dragBar:Hide()

    MF:Hide()
end

-- ─── Delve Badge Pool ─────────────────────────────────────
-- Renders badges for Delve currencies (Nemesis 3/4, Lives 4, Keys 1),
-- Bountiful status, and active Delve spells.
local function GetOrCreateDelveBadge(idx)
    local badges = MF.delveBadges
    if badges[idx] then
        badges[idx].frame:Show()
        return badges[idx]
    end

    local frame = CreateFrame("Frame", nil, MF.delveRow)
    frame:SetHeight(18)
    frame:EnableMouse(true)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", frame, "LEFT", 0, 0)

    local text = MakeText(frame, "GameFontNormalSmall", 1, 1, 1, 1, "LEFT")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)

    local stackText = MakeText(frame, "GameFontNormalSmall", 1, 1, 1, 1, "RIGHT")
    stackText:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -1)

    frame:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        if self.title then
            GameTooltip:AddLine(self.title, 1, 0.82, 0)
        end
        if self.customTooltip and self.customTooltip ~= "" then
            GameTooltip:AddLine(self.customTooltip, 1, 1, 1, true)
        elseif self.spellID then
            if GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(self.spellID)
            else
                local spellName = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(self.spellID)) or
                    (_G.GetSpellInfo and _G.GetSpellInfo(self.spellID))
                if spellName then GameTooltip:AddLine(spellName, 1, 1, 1) end
            end
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    badges[idx] = { frame = frame, icon = icon, text = text, stackText = stackText }
    return badges[idx]
end

local function HideExtraDelveBadges(count)
    for i = count + 1, #MF.delveBadges do
        MF.delveBadges[i].frame:Hide()
    end
end

-- ─── Boss Row Pool ────────────────────────────────────────
local bossRowH = 18

local function GetOrCreateBossRow(idx)
    local rows = MF.bossRows
    if rows[idx] then
        rows[idx].row:Show()
        return rows[idx]
    end

    local row = CreateFrame("Frame", nil, MF.bossContainer)
    row:SetHeight(bossRowH)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(14, 14)
    icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)

    local checkTex = row:CreateTexture(nil, "OVERLAY")
    checkTex:SetSize(14, 14)
    checkTex:SetTexture("Interface/RaidFrame/ReadyCheck-Ready")
    checkTex:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    checkTex:Hide()

    local nameText = MakeText(row, "GameFontNormalSmall", CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
    nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 4, 0)
    nameText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(true)

    local splitText = MakeText(row, "GameFontNormalSmall", CLR_DIM_R, CLR_DIM_G, CLR_DIM_B)
    splitText:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    splitText:SetJustifyH("RIGHT")
    splitText:SetText("")

    rows[idx] = { row = row, icon = icon, check = checkTex, name = nameText, split = splitText }
    return rows[idx]
end

-- Only iterate from count+1 to _lastBossCount — not a hard-coded 20.
local function HideExtraBossRows(count)
    for i = count + 1, _lastBossCount do
        if MF.bossRows[i] then
            MF.bossRows[i].row:Hide()
        end
    end
    _lastBossCount = count
end

-- ─── Affix Frame Pool (M+ only) ───────────────────────────
local function BuildAffixRow(affixes)
    local n    = affixes and #affixes or 0
    local size = 20
    local gap  = 4

    for i = n + 1, #MF.affixes do
        MF.affixes[i].frame:Hide()
    end

    if n == 0 then
        MF.affixRow:Hide()
        MF.affixRow:SetHeight(0)
        return
    end

    MF.affixRow:Show()
    local xOff = 0
    for i = 1, n do
        local affixID = affixes[i]
        local af = MF.affixes[i]

        if not af then
            local frame = CreateFrame("Frame", nil, MF.affixRow)
            frame:SetSize(size, size)
            frame:EnableMouse(true)
            local icon = frame:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints(frame)
            frame:SetScript("OnLeave", function()
                if GameTooltip then GameTooltip:Hide() end
            end)
            frame:SetScript("OnEnter", function(self)
                if GameTooltip then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.affixName then GameTooltip:SetText(self.affixName) end
                    if self.affixDesc then GameTooltip:AddLine(self.affixDesc, nil, nil, nil, true) end
                    GameTooltip:Show()
                end
            end)
            af = { frame = frame, icon = icon }
            MF.affixes[i] = af
        end

        af.frame:SetSize(size, size)
        af.frame:ClearAllPoints()
        af.frame:SetPoint("LEFT", MF.affixRow, "LEFT", xOff, 0)
        af.frame:Show()

        local ok, name, desc, fileDataID = pcall(C_ChallengeMode.GetAffixInfo, affixID)
        af.icon:SetTexture(ok and fileDataID or nil)
        af.frame.affixName = ok and name or nil
        af.frame.affixDesc = ok and desc or nil

        xOff = xOff + size + gap
    end

    MF.affixRow:SetHeight(n > 0 and (size + 2) or 0)
end

-- ─── Chest Tick Placement ─────────────────────────────────
local function PlaceChestTicks()
    if _timeLimit <= 0 or not MF or not MF.timerOverlay then return end
    local barW = MF.timerSection:GetWidth()
    if barW <= 0 then barW = (HUD_W or 280) - (HUD_PAD * 2) end
    -- +3 chest = 60% of time limit, +2 chest = 80% of time limit
    MF.tick3:ClearAllPoints()
    MF.tick3:SetPoint("LEFT", MF.timerOverlay, "LEFT", barW * 0.60, 0)
    MF.tick2:ClearAllPoints()
    MF.tick2:SetPoint("LEFT", MF.timerOverlay, "LEFT", barW * 0.80, 0)
end

-- ─── Layout ───────────────────────────────────────────────
local function RelayoutHUD(numBoss, isDelve, delveRowH, hasForces, hasCompanion)
    local isMythic = (_mode == "mythic")
    local totalBossH = 0

    for i = 1, numBoss do
        local r = MF.bossRows[i]
        if r and r.row:IsShown() then
            local rH = r.row:GetHeight() or 16
            r.row:ClearAllPoints()
            r.row:SetPoint("LEFT", MF.bossContainer, "LEFT", 0, 0)
            r.row:SetPoint("RIGHT", MF.bossContainer, "RIGHT", 0, 0)
            r.row:SetPoint("TOP", MF.bossContainer, "TOP", 0, -totalBossH)
            totalBossH = totalBossH + rH + 3
        end
    end
    if totalBossH > 0 then
        totalBossH = totalBossH - 3
    end
    local bossH = totalBossH
    MF.bossContainer:SetHeight(bossH)

    if isMythic then
        MF.delveRow:Hide()
        MF.affixRow:ClearAllPoints()
        MF.affixRow:SetPoint("TOPLEFT", MF.header, "BOTTOMLEFT", 0, -4)
        MF.affixRow:SetPoint("TOPRIGHT", MF.header, "BOTTOMRIGHT", 0, -4)
        MF.affixRow:SetShown(#MF.affixes > 0)

        MF.timerSection:Show()
        MF.timerSection:SetHeight(16)
        PlaceChestTicks()
        MF.deathText:Show()
        MF.sep1:SetShown(bossH > 0)
        MF.sep1:ClearAllPoints()
        MF.sep1:SetPoint("TOPLEFT", MF.timerSection, "BOTTOMLEFT", 0, -4)
        MF.sep1:SetPoint("TOPRIGHT", MF.timerSection, "BOTTOMRIGHT", 0, -4)

        MF.bossContainer:ClearAllPoints()
        MF.bossContainer:SetPoint("TOPLEFT", MF.sep1, "BOTTOMLEFT", 0, -4)
        MF.bossContainer:SetPoint("TOPRIGHT", MF.sep1, "BOTTOMRIGHT", 0, -4)

        MF.sep2:ClearAllPoints()
        MF.sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
        MF.sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
        MF.sep2:Show()
        MF.forcesSection:Show()

        MF.sep3:Hide()
        MF.companionSection:Hide()

        local hdrH = (MF.header and MF.header:GetHeight()) or 24
        local affixH = MF.affixRow:IsShown() and (4 + MF.affixRow:GetHeight()) or 0
        local totalH = HUD_PAD + hdrH + affixH + (6 + 16) + (bossH > 0 and (4 + 1 + 4 + bossH) or 0) + (4 + 1 + 4 + 14) +
            HUD_PAD
        MF:SetHeight(math_max(60, totalH))
    elseif isDelve then
        MF.delveRow:SetShown(delveRowH > 0)
        MF.affixRow:Hide()
        MF.timerSection:Hide()
        MF.timerSection:SetHeight(0)
        MF.tick2:Hide()
        MF.tick3:Hide()
        MF.deathText:Hide()

        local topAnchor = (delveRowH > 0) and MF.delveRow or MF.header

        MF.sep1:SetShown(bossH > 0)
        MF.sep1:ClearAllPoints()
        MF.sep1:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -4)
        MF.sep1:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -4)

        MF.bossContainer:ClearAllPoints()
        if bossH > 0 then
            MF.bossContainer:SetPoint("TOPLEFT", MF.sep1, "BOTTOMLEFT", 0, -4)
            MF.bossContainer:SetPoint("TOPRIGHT", MF.sep1, "BOTTOMRIGHT", 0, -4)
        else
            MF.bossContainer:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -2)
            MF.bossContainer:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -2)
        end

        MF.sep2:ClearAllPoints()
        MF.sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
        MF.sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
        MF.sep2:SetShown(hasForces)
        MF.forcesSection:SetShown(hasForces)

        local prevSec = hasForces and MF.forcesSection or (bossH > 0 and MF.bossContainer or topAnchor)
        if hasCompanion then
            MF.sep3:ClearAllPoints()
            MF.sep3:SetPoint("TOPLEFT", prevSec, "BOTTOMLEFT", 0, -4)
            MF.sep3:SetPoint("TOPRIGHT", prevSec, "BOTTOMRIGHT", 0, -4)
            MF.sep3:Show()

            MF.companionSection:ClearAllPoints()
            MF.companionSection:SetPoint("TOPLEFT", MF.sep3, "BOTTOMLEFT", 0, -4)
            MF.companionSection:SetPoint("TOPRIGHT", MF.sep3, "BOTTOMRIGHT", 0, -4)
            MF.companionSection:Show()
        else
            MF.sep3:Hide()
            MF.companionSection:Hide()
        end

        local dRowGap = delveRowH > 0 and (4 + delveRowH) or 0
        local sep1H   = bossH > 0 and (4 + 1 + 4) or 0
        local bossGap = bossH > 0 and bossH or 0
        local forcesH = hasForces and (4 + 1 + 4 + 14) or 0
        local compH   = hasCompanion and (4 + 1 + 4 + 14) or 0
        local totalH  = HUD_PAD + 24 + dRowGap + sep1H + bossGap + forcesH + compH + HUD_PAD
        MF:SetHeight(math_max(50, totalH))
    else
        -- Regular Dungeon / Scenario
        MF.delveRow:Hide()
        MF.affixRow:Hide()
        MF.timerSection:Hide()
        MF.timerSection:SetHeight(0)
        MF.tick2:Hide()
        MF.tick3:Hide()
        MF.deathText:Hide()

        MF.sep1:SetShown(bossH > 0)
        MF.sep1:ClearAllPoints()
        MF.sep1:SetPoint("TOPLEFT", MF.header, "BOTTOMLEFT", 0, -4)
        MF.sep1:SetPoint("TOPRIGHT", MF.header, "BOTTOMRIGHT", 0, -4)

        MF.bossContainer:ClearAllPoints()
        if bossH > 0 then
            MF.bossContainer:SetPoint("TOPLEFT", MF.sep1, "BOTTOMLEFT", 0, -4)
            MF.bossContainer:SetPoint("TOPRIGHT", MF.sep1, "BOTTOMRIGHT", 0, -4)
        else
            MF.bossContainer:SetPoint("TOPLEFT", MF.header, "BOTTOMLEFT", 0, -6)
            MF.bossContainer:SetPoint("TOPRIGHT", MF.header, "BOTTOMRIGHT", 0, -6)
        end

        MF.sep2:ClearAllPoints()
        MF.sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
        MF.sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
        MF.sep2:SetShown(hasForces)
        MF.forcesSection:SetShown(hasForces)

        MF.sep3:Hide()
        MF.companionSection:Hide()

        local sep1H   = bossH > 0 and (4 + 1 + 4) or 0
        local bossGap = bossH > 0 and bossH or 0
        local forcesH = hasForces and (4 + 1 + 4 + 14) or 0
        local totalH  = HUD_PAD + 24 + sep1H + bossGap + forcesH + HUD_PAD
        MF:SetHeight(math_max(50, totalH))
    end
end

-- ─── Core Update: merged boss + forces in one GetStepInfo call ───
local function UpdateInstanceState()
    if not (C_Scenario and C_ScenarioInfo) then return end
    local ok, stepName, stepDesc, numCriteria, _, _, _, _, _, _, stepID, stepWidgetSetID, _, isWorldEvent = pcall(C_Scenario.GetStepInfo)
    if (not ok or not numCriteria or numCriteria == 0) and C_ScenarioInfo.GetScenarioStepInfo then
        local okStep, sInfo = pcall(C_ScenarioInfo.GetScenarioStepInfo)
        if okStep and sInfo then
            numCriteria = (sInfo.numCriteria and sInfo.numCriteria > 0) and sInfo.numCriteria or (numCriteria or 0)
            stepID = stepID or sInfo.stepID
            stepName = stepName or sInfo.title
            stepDesc = stepDesc or sInfo.description
            stepWidgetSetID = stepWidgetSetID or sInfo.stepWidgetSetID
            if sInfo.isWorldEvent ~= nil then isWorldEvent = sInfo.isWorldEvent end
            ok = true
        end
    end
    numCriteria = numCriteria or 0

    -- Delve state update
    local delveInfo = GetDelveInfo()
    local delveRowH = 0
    if delveInfo then
        MF.dungeonText:SetText(delveInfo.name or "Delve")
        local tStr = delveInfo.tierText
        if tStr and not tostring(tStr):lower():find("tier") then
            tStr = "Tier " .. tostring(tStr)
        end
        MF.levelText:SetText(tStr and string_format("|cffa864ff%s|r", tStr) or "|cffa864ffDelve|r")

        -- 1. Lives remaining pinned all the way to the right
        local livesW = 0
        if delveInfo.livesText and delveInfo.livesText ~= "" then
            if delveInfo.livesRemaining == 0 then
                MF.delveLivesText:SetText("|cffff44440 Lives|r")
            else
                MF.delveLivesText:SetText(string_format("|cff44ff44%s Lives|r", delveInfo.livesText))
            end
            livesW = MF.delveLivesText:GetStringWidth() + 4
            MF.delveLivesFrame:SetWidth(livesW)
            MF.delveLivesFrame:Show()

            MF.delveLivesFrame.tooltip = delveInfo.livesTooltip or
                ("Reinforcements remaining: " .. delveInfo.livesText .. " lives.\nRunning out forfeits the Heavy Bountiful Coffer.")
        else
            MF.delveLivesText:SetText("")
            MF.delveLivesFrame.tooltip = nil
            MF.delveLivesFrame:Hide()
        end

        -- 1b. Standalone Nemesis text is disabled (progress is displayed directly on the Nemesis affix icon badge)
        if MF.delveNemesisFrame then
            MF.delveNemesisText:SetText("")
            MF.delveNemesisFrame.tooltip = nil
            MF.delveNemesisFrame:Hide()
        end
        local nemesis = GetNemesisInfo(delveInfo)

        local badgeIdx = 0

        -- 2. Bountiful Badge
        if delveInfo.isBountiful then
            badgeIdx = badgeIdx + 1
            local b = GetOrCreateDelveBadge(badgeIdx)
            b.icon:SetTexture(413571)
            b.icon:SetSize(16, 16)
            b.stackText:Hide()
            b.text:SetText("|cffffd100Bountiful|r")
            b.text:Show()
            local w = 16 + 4 + b.text:GetStringWidth()
            b.frame:SetSize(w, 18)
            b.frame.title = "Bountiful Delve"
            b.frame.customTooltip = delveInfo.bountyTooltip or
                "Heavy Bountiful Coffer available upon delve completion with a Restored Coffer Key."
            b.frame.spellID = nil
        end

        -- 3. Currencies (Nemesis 3/4, Keys 1, etc. — matching default UI)
        if delveInfo.currencies then
            for _, c in ipairs(delveInfo.currencies) do
                badgeIdx = badgeIdx + 1
                local b = GetOrCreateDelveBadge(badgeIdx)
                b.icon:SetTexture(c.icon or 134400)
                b.icon:SetSize(16, 16)
                b.stackText:Hide()

                local cText = c.text or ""
                local cLeading = (c.leadingText and not issecretvalue(c.leadingText)) and c.leadingText or ""
                local cTooltip = (c.tooltip and not issecretvalue(c.tooltip)) and c.tooltip or ""
                local valStr = cText
                if not issecretvalue(valStr) then
                    if valStr == "" and cLeading ~= "" then
                        valStr = cLeading
                    end
                    if valStr == "" and cTooltip ~= "" then
                        valStr = cTooltip:match("(%d+/%d+)") or cTooltip:match("(%d+ of %d+)") or
                            cTooltip:match("(%d+ remaining)") or ""
                    end

                    local isNemCurr = (cTooltip ~= "" and cTooltip:lower():find("nemesis")) or
                        (cLeading ~= "" and cLeading:lower():find("nemesis"))
                    if valStr == "" and isNemCurr and nemesis.text and not issecretvalue(nemesis.text) then
                        valStr = nemesis.text
                    end
                end

                if issecretvalue(valStr) then
                    b.text:SetText(valStr)
                    b.text:Show()
                elseif valStr ~= "" then
                    local isNemCurr = (cTooltip ~= "" and cTooltip:lower():find("nemesis")) or
                        (cLeading ~= "" and cLeading:lower():find("nemesis"))
                    if isNemCurr then
                        b.text:SetText(string_format("|cffa335ee%s|r", valStr))
                    elseif valStr:find("/") then
                        b.text:SetText(string_format("|cffffcc00%s|r", valStr))
                    else
                        b.text:SetText(string_format("|cffffffff%s|r", valStr))
                    end
                    b.text:Show()
                else
                    b.text:Hide()
                    b.text:SetText("")
                end

                local w = 16 + (b.text:IsShown() and (4 + b.text:GetStringWidth()) or 0)
                b.frame:SetSize(w, 18)
                b.frame.title = nil
                b.frame.customTooltip = (c.tooltip and c.tooltip ~= "") and c.tooltip or nil
                b.frame.spellID = nil
            end
        end

        -- 4. Active Delve Spells / Affixes (matching default UI with stack / count display)
        if delveInfo.spells then
            for _, s in ipairs(delveInfo.spells) do
                badgeIdx = badgeIdx + 1
                local b = GetOrCreateDelveBadge(badgeIdx)
                local tex = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(s.spellID)) or
                    (_G.GetSpellTexture and _G.GetSpellTexture(s.spellID)) or 134400
                b.icon:SetTexture(tex)
                b.icon:SetSize(16, 16)
                b.stackText:Hide()

                local sText = s.text or ""
                local sTooltip = (s.tooltip and not issecretvalue(s.tooltip)) and s.tooltip or ""
                local displayNum = nil
                if s.stack and not issecretvalue(s.stack) and tostring(s.stack) ~= "" and tostring(s.stack) ~= "0" then
                    displayNum = tostring(s.stack)
                elseif issecretvalue(sText) then
                    displayNum = sText
                elseif sText ~= "" then
                    displayNum = sText:match("(%d+/%d+)") or sText:match("(%d+)") or sText
                end

                if not displayNum and s.spellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                    local okA, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, s.spellID)
                    if okA and aura then
                        if aura.applications and not issecretvalue(aura.applications) and aura.applications > 0 then
                            displayNum = tostring(aura.applications)
                        elseif aura.points and aura.points[1] and not issecretvalue(aura.points[1]) and aura.points[1] > 0 then
                            displayNum = tostring(aura.points[1])
                        end
                    end
                end

                if not displayNum and sTooltip ~= "" then
                    local match = sTooltip:match("(%d+/%d+)") or sTooltip:match("(%d+ of %d+)") or
                        sTooltip:match("(%d+ remaining)") or sTooltip:match("(%d+) groups?") or
                        sTooltip:match("(%d+) packs?")
                    if match then displayNum = match end
                end

                if not issecretvalue(displayNum) then
                    local isNemSpell = (sTooltip ~= "" and (sTooltip:lower():find("nemesis") or sTooltip:lower():find("zekvir") or sTooltip:lower():find("influence")))
                    if (not displayNum or displayNum == "") and isNemSpell and nemesis.text and not issecretvalue(nemesis.text) then
                        displayNum = nemesis.text
                    end
                end

                if issecretvalue(displayNum) then
                    b.text:SetText(displayNum)
                    b.text:Show()
                    local w = 16 + 4 + b.text:GetStringWidth()
                    b.frame:SetSize(w, 18)
                elseif displayNum and displayNum ~= "" then
                    local isNemSpell = (sTooltip ~= "" and (sTooltip:lower():find("nemesis") or sTooltip:lower():find("zekvir") or sTooltip:lower():find("influence")))
                    if isNemSpell then
                        b.text:SetText(string_format("|cffa335ee%s|r", displayNum))
                    elseif displayNum:find("/") then
                        b.text:SetText(string_format("|cffffcc00%s|r", displayNum))
                    else
                        b.text:SetText(string_format("|cffffffff%s|r", displayNum))
                    end
                    b.text:Show()
                    local w = 16 + 4 + b.text:GetStringWidth()
                    b.frame:SetSize(w, 18)
                else
                    b.text:Hide()
                    b.text:SetText("")
                    b.frame:SetSize(16, 18)
                end

                b.frame.title = nil
                b.frame.customTooltip = s.tooltip
                b.frame.spellID = s.spellID
            end
        end

        HideExtraDelveBadges(badgeIdx)

        -- 5. Flow Layout for Left-side Badges
        local xOff = 0
        local yOff = 0
        local gap = 6
        local rowH = 18
        local totalW = HUD_W - (HUD_PAD * 2)
        local rightPinnedW = (livesW > 0 and livesW + 6 or 0)
        local firstRowMaxW = (rightPinnedW > 0) and (totalW - rightPinnedW) or totalW

        for i = 1, badgeIdx do
            local b = MF.delveBadges[i]
            local bW = b.frame:GetWidth()
            local allowedW = (yOff == 0) and firstRowMaxW or totalW

            if xOff + bW > allowedW and xOff > 0 then
                xOff = 0
                yOff = yOff + rowH + 2
            end
            b.frame:ClearAllPoints()
            b.frame:SetPoint("TOPLEFT", MF.delveRow, "TOPLEFT", xOff, -yOff)
            xOff = xOff + bW + gap
        end

        delveRowH = (badgeIdx > 0 or livesW > 0) and (yOff + rowH) or 0
        MF.delveRow:SetHeight(delveRowH)
        MF.delveRow:SetShown(delveRowH > 0)
    else
        HideExtraDelveBadges(0)
        MF.delveLivesText:SetText("")
        MF.delveLivesFrame:Hide()
        MF.delveNemesisText:SetText("")
        MF.delveNemesisFrame:Hide()
        MF.delveRow:Hide()
        MF.delveRow:SetHeight(0)

        -- For non-delve scenarios and world events, update stage progression if multi-stage
        if _mode == "dungeon" and C_Scenario and C_Scenario.GetInfo then
            local okScen, sName, curStage, numStages = pcall(C_Scenario.GetInfo)
            if okScen and sName and sName ~= "" then
                MF.dungeonText:SetText(sName)
                if numStages and numStages > 1 and curStage and curStage > 0 then
                    MF.levelText:SetText(string_format("|cff00ffccStage %d/%d|r", curStage, numStages))
                end
            end
        end
    end

    -- Helper to test if a criteria is a progress/percentage bar objective
    local function IsProgressCriteria(info)
        if not info then return false end
        if info.isWeightedProgress or info.weightedProgress then return true end
        if info.criteriaType == 8 then return true end
        local total = info.totalQuantity
        if total and not issecretvalue(total) and (total == 100 or total == 1000) then return true end
        local qStr = info.quantityString
        if qStr and not issecretvalue(qStr) and qStr:find("%%") then return true end
        local desc = info.description or info.criteriaString or info.string
        if desc and not issecretvalue(desc) then
            local lower = desc:lower()
            if lower:find("%%") or lower:find("forces") or lower:find("enemy forces") or
               lower:find("streitkräfte") or lower:find("troupes") or lower:find("fuerzas") or
               lower:find("tropas") or lower:find("сила") then
                return true
            end
        end
        return false
    end

    -- Find forces / progress bar criteria: prioritize active (uncompleted) progress criteria first.
    local forcesIdx  = nil
    local forcesInfo = nil
    if numCriteria and numCriteria > 0 then
        for i = 1, numCriteria do
            local info = GetCriteriaInfoSafe(i, stepID)
            if info and IsProgressCriteria(info) and not info.completed then
                forcesIdx  = i
                forcesInfo = info
                break
            end
        end
        -- Fallback 1: if all progress criteria are completed, pick the last progress criteria (e.g. M+ 100% forces)
        if not forcesInfo then
            for i = numCriteria, 1, -1 do
                local info = GetCriteriaInfoSafe(i, stepID)
                if info and IsProgressCriteria(info) then
                    forcesIdx  = i
                    forcesInfo = info
                    break
                end
            end
        end
    end
    -- Fallback 2: scenario step level weightedProgress (some Delves / instanced scenarios attach progress to the step)
    if not forcesInfo and C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
        local okStep, sInfo = pcall(C_ScenarioInfo.GetScenarioStepInfo)
        if okStep and sInfo and sInfo.weightedProgress and sInfo.weightedProgress > 0 then
            wipe(staticForcesInfo)
            staticForcesInfo.quantity = sInfo.weightedProgress
            staticForcesInfo.totalQuantity = 100
            staticForcesInfo.quantityString = string_format("%d%%", sInfo.weightedProgress)
            staticForcesInfo.completed = false
            staticForcesInfo.isWeightedProgress = true
            forcesInfo = staticForcesInfo
        end
    end

    -- Forward scan: populate boss rows (skip forces index).
    local isMythic = (_mode == "mythic")
    local bossCount = 0
    if numCriteria and numCriteria > 0 then
        for i = 1, numCriteria do
            if i ~= forcesIdx then
                local info = GetCriteriaInfoSafe(i, stepID)
                local rawDesc = info and (info.description or info.criteriaString or info.string)
                if rawDesc and rawDesc ~= "" then
                    bossCount        = bossCount + 1
                    local r          = GetOrCreateBossRow(bossCount)
                    local isComplete = info.completed == true
                    local elapsedAt  = info.elapsed

                    if isComplete then
                        r.icon:Hide()
                        r.check:Show()
                        r.name:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B)
                    else
                        r.check:Hide()
                        r.icon:Show()
                        r.name:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
                    end

                    -- Split timer (M+ only)
                    local splitStr = ""
                    local rightOffset = 0
                    if isMythic then
                        local pbSplit = (_currentBestRun and _currentBestRun.splits) and _currentBestRun.splits[bossCount] or nil
                        if isComplete then
                            if not _bossSplits[bossCount] then
                                local currentRunElapsed = 0
                                if _timerID then
                                    local okEl, _, el = pcall(GetWorldElapsedTime, _timerID)
                                    if okEl and el and el > 0 then currentRunElapsed = el end
                                end
                                if currentRunElapsed == 0 then
                                    for t = 1, 5 do
                                        local okEl, _, el = pcall(GetWorldElapsedTime, t)
                                        if okEl and el and el > 0 then
                                            currentRunElapsed = el
                                            break
                                        end
                                    end
                                end
                                local elapsedSinceKill = elapsedAt or 0
                                local killTime = math_max(0, currentRunElapsed - elapsedSinceKill)
                                if killTime > 0 then
                                    _bossSplits[bossCount] = killTime
                                end
                            end

                            local actualKillTime = _bossSplits[bossCount]
                            if actualKillTime and actualKillTime > 0 then
                                if pbSplit and pbSplit > 0 then
                                    local delta = actualKillTime - pbSplit
                                    if delta < 0 then
                                        splitStr = string_format("[%s] |cff00ff88-%s|r", FormatTime(actualKillTime), FormatTime(math_abs(delta)))
                                    elseif delta > 0 then
                                        splitStr = string_format("[%s] |cffff4444+%s|r", FormatTime(actualKillTime), FormatTime(delta))
                                    else
                                        splitStr = string_format("[%s] |cffffffaa±0|r", FormatTime(actualKillTime))
                                    end
                                    rightOffset = -95
                                else
                                    splitStr = string_format("[%s]", FormatTime(actualKillTime))
                                    rightOffset = -55
                                end
                            end
                        else
                            -- Boss is alive: show target milestone from PB in dim text
                            if pbSplit and pbSplit > 0 then
                                splitStr = string_format("|cff555555[%s]|r", FormatTime(pbSplit))
                                rightOffset = -55
                            end
                        end
                    end

                    if splitStr ~= "" then
                        r.split:SetTextColor(CLR_DIM_R, CLR_DIM_G, CLR_DIM_B)
                        r.split:SetText(splitStr)
                        r.split:Show()
                        r.name:ClearAllPoints()
                        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
                        r.name:SetPoint("RIGHT", r.row, "RIGHT", rightOffset, 0)
                    else
                        r.split:SetText("")
                        r.split:Hide()
                        r.name:ClearAllPoints()
                        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
                        r.name:SetPoint("RIGHT", r.row, "RIGHT", 0, 0)
                    end

                    local nameStr = CleanObjectiveName(rawDesc)
                    if not isComplete and info.quantity and info.totalQuantity and info.totalQuantity > 1 then
                        if IsProgressCriteria(info) then
                            local raw = info.quantityString and info.quantityString:gsub("%%", "") or info.quantity
                            local cur = tonumber(raw) or 0
                            local pct = (info.totalQuantity > 0) and math_floor((cur / info.totalQuantity) * 100) or cur
                            nameStr = nameStr .. " " .. string_format("|cff777777(%d%%)|r", pct)
                        else
                            nameStr = nameStr .. " " .. string_format("|cff777777(%s/%s)|r", tostring(info.quantity), tostring(info.totalQuantity))
                        end
                    end
                    r.name:SetText(nameStr)

                    local textH = r.name:GetStringHeight() or 14
                    local rowH = math_max(16, math_ceil(textH + 2))
                    r.row:SetHeight(rowH)
                end
            end
        end
    end

    -- Check Bonus Steps for additional scenario / world event objectives
    if C_Scenario and C_Scenario.GetBonusSteps then
        local okB, bonusSteps = pcall(C_Scenario.GetBonusSteps)
        if okB and bonusSteps and #bonusSteps > 0 then
            for _, bStepID in ipairs(bonusSteps) do
                local okBS, _, _, bNum = pcall(C_Scenario.GetStepInfo, bStepID)
                if okBS and bNum and bNum > 0 then
                    for bi = 1, bNum do
                        local bInfo = GetCriteriaInfoSafe(bi, bStepID)
                        local bDesc = bInfo and (bInfo.description or bInfo.criteriaString or bInfo.string)
                        if bDesc and bDesc ~= "" and not IsProgressCriteria(bInfo) then
                            bossCount        = bossCount + 1
                            local r          = GetOrCreateBossRow(bossCount)
                            local isComplete = bInfo.completed == true
                            if isComplete then
                                r.icon:Hide()
                                r.check:Show()
                                r.name:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B)
                            else
                                r.check:Hide()
                                r.icon:Show()
                                r.name:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
                            end
                            r.split:SetText("")
                            r.split:Hide()
                            r.name:ClearAllPoints()
                            r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
                            r.name:SetPoint("RIGHT", r.row, "RIGHT", 0, 0)

                            local nameStr = CleanObjectiveName(bDesc)
                            if not isComplete and bInfo.quantity and bInfo.totalQuantity and bInfo.totalQuantity > 1 then
                                if IsProgressCriteria(bInfo) then
                                    local raw = bInfo.quantityString and bInfo.quantityString:gsub("%%", "") or bInfo.quantity
                                    local cur = tonumber(raw) or 0
                                    local pct = (bInfo.totalQuantity > 0) and math_floor((cur / bInfo.totalQuantity) * 100) or cur
                                    nameStr = nameStr .. " " .. string_format("|cff777777(%d%%)|r", pct)
                                else
                                    nameStr = nameStr .. " " .. string_format("|cff777777(%s/%s)|r", tostring(bInfo.quantity), tostring(bInfo.totalQuantity))
                                end
                            end
                            r.name:SetText(nameStr)
                            local textH = r.name:GetStringHeight() or 14
                            r.row:SetHeight(math_max(16, math_ceil(textH + 2)))
                        end
                    end
                end
            end
        end
    end

    -- Fallback 1: If no criteria rows were found, display the stage description
    if bossCount == 0 and stepDesc and stepDesc ~= "" and not delveInfo then
        bossCount = bossCount + 1
        local r = GetOrCreateBossRow(bossCount)
        r.check:Hide()
        r.icon:Show()
        r.name:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
        r.split:SetText("")
        r.split:Hide()
        r.name:ClearAllPoints()
        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
        r.name:SetPoint("RIGHT", r.row, "RIGHT", 0, 0)
        r.name:SetText(CleanObjectiveName(stepDesc))
        local textH = r.name:GetStringHeight() or 14
        r.row:SetHeight(math_max(16, math_ceil(textH + 2)))
    end

    -- Fallback 2: Instanced Scenario UI Widgets extraction (TextWithState, StatusBar)
    if not delveInfo and C_UIWidgetManager then
        wipe(staticWidgetSetIDs)
        if stepWidgetSetID and stepWidgetSetID > 0 then
            table.insert(staticWidgetSetIDs, stepWidgetSetID)
        end
        if C_UIWidgetManager.GetObjectiveTrackerWidgetSetID then
            local okId, id = pcall(C_UIWidgetManager.GetObjectiveTrackerWidgetSetID)
            if okId and id and id > 0 then table.insert(staticWidgetSetIDs, id) end
        end

        for _, setID in ipairs(staticWidgetSetIDs) do
            local okW, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
            if okW and widgets then
                for _, w in ipairs(widgets) do
                    local wID = (type(w) == "table" and w.widgetID) or w
                    if wID then
                        -- TextWithState
                        if C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
                            local okVis, vis = pcall(C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo, wID)
                            if okVis and vis and vis.shownState ~= 0 and vis.text and vis.text ~= "" and not issecretvalue(vis.text) then
                                bossCount = bossCount + 1
                                local r = GetOrCreateBossRow(bossCount)
                                r.check:Hide()
                                r.icon:Show()
                                r.name:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
                                r.split:SetText("")
                                r.split:Hide()
                                r.name:ClearAllPoints()
                                r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
                                r.name:SetPoint("RIGHT", r.row, "RIGHT", 0, 0)
                                r.name:SetText(vis.text)
                                local textH = r.name:GetStringHeight() or 14
                                r.row:SetHeight(math_max(16, math_ceil(textH + 2)))
                            end
                        end
                        -- StatusBar
                        if not forcesInfo and C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
                            local okBar, bar = pcall(C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo, wID)
                            if okBar and bar and bar.shownState ~= 0 and bar.barValue and not issecretvalue(bar.barValue) then
                                wipe(staticForcesInfo)
                                staticForcesInfo.quantity = bar.barValue
                                staticForcesInfo.totalQuantity = (bar.barMax and bar.barMax > 0) and bar.barMax or 100
                                staticForcesInfo.quantityString = bar.overrideBarText or string_format("%d%%", bar.barValue)
                                staticForcesInfo.completed = false
                                staticForcesInfo.isWeightedProgress = true
                                forcesInfo = staticForcesInfo
                            end
                        end
                    end
                end
            end
        end
    end

    HideExtraBossRows(bossCount)

    -- Forces bar (Direct API info forwarding matching MPlusTimer)
    if forcesInfo then
        local total = forcesInfo.totalQuantity or 100
        local rawCurrent = forcesInfo.quantityString and forcesInfo.quantityString:gsub("%%", "") or forcesInfo.quantity
        local current = tonumber(rawCurrent) or 0
        local percent = (total and total > 0) and (current / total) * 100 or current

        local isCompleted = (forcesInfo.completed == true) or (percent >= 100)
        MF.forcesBar:SetMinMaxValues(0, total)
        MF.forcesBar:SetValue(isCompleted and total or current)

        if isCompleted then
            MF.forcesBar:SetStatusBarColor(0.20, 1.00, 0.40, 0.90)

            local splitStr = ""
            local forcesElapsed = forcesInfo.elapsed
            if isMythic and isCompleted and not _forcesSplitTime then
                local currentRunElapsed = 0
                if _timerID then
                    local _, curRunElapsed = GetWorldElapsedTime(_timerID)
                    if curRunElapsed and curRunElapsed > 0 then
                        currentRunElapsed = curRunElapsed
                    end
                end
                local elapsedSinceForces = forcesElapsed or 0
                if currentRunElapsed > 0 then
                    _forcesSplitTime = math_max(0, currentRunElapsed - elapsedSinceForces)
                end
            end

            if isMythic and _forcesSplitTime and _forcesSplitTime > 0 then
                local pbForces = _currentBestRun and _currentBestRun.forces or nil
                if pbForces and pbForces > 0 then
                    local fDelta = _forcesSplitTime - pbForces
                    if fDelta < 0 then
                        splitStr = string_format(" [%s] |cff00ff88-%s|r", FormatTime(_forcesSplitTime), FormatTime(math_abs(fDelta)))
                    elseif fDelta > 0 then
                        splitStr = string_format(" [%s] |cffff4444+%s|r", FormatTime(_forcesSplitTime), FormatTime(fDelta))
                    else
                        splitStr = string_format(" [%s] |cffffffaa±0|r", FormatTime(_forcesSplitTime))
                    end
                else
                    splitStr = string_format(" [%s]", FormatTime(_forcesSplitTime))
                end
            end

            MF.forcesText:SetText("100% / 100%" .. splitStr)
            MF.forcesCountText:SetText("")
        else
            MF.forcesBar:SetStatusBarColor(0.40, 0.00, 1.00, 0.85)
            MF.forcesText:SetText(string_format("%.2f%% / 100%%", percent))
            if total > 100 then
                MF.forcesCountText:SetText(string_format("%s/%s", current, total))
            else
                MF.forcesCountText:SetText("")
            end
        end
    else
        MF.forcesText:SetText("—")
        MF.forcesCountText:SetText("")
    end

    -- Companion Bar update (Delve only)
    local compInfo = (delveInfo ~= nil) and GetDelveCompanionInfo() or nil
    if compInfo then
        MF.companionBar:SetMinMaxValues(0, 100)
        MF.companionBar:SetValue(compInfo.pct)
        MF.companionLeftText:SetText(string_format("lvl %d", compInfo.level))
        if compInfo.isMaxLevel then
            MF.companionRightText:SetText("|cff44ff44max level|r")
        else
            MF.companionRightText:SetText(string_format("%.1f%%", compInfo.pct))
        end
    else
        MF.companionLeftText:SetText("")
        MF.companionRightText:SetText("")
    end

    RelayoutHUD(bossCount, delveInfo ~= nil, delveRowH, forcesInfo ~= nil, compInfo ~= nil)
end

-- ─── Timer Update (10 Hz ticker — optimized) ──────────────
local function UpdateTimer()
    local elapsed = 0
    if _timerID then
        local ok, _, el = pcall(GetWorldElapsedTime, _timerID)
        if ok and el and el > 0 then elapsed = el end
    end
    if elapsed == 0 then
        for i = 1, 5 do
            local ok, _, el = pcall(GetWorldElapsedTime, i)
            if ok and el and el > 0 then
                _timerID = i
                elapsed = el
                break
            end
        end
    end

    if _timeLimit <= 0 then
        local ok1, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
        if ok1 and mapID and mapID > 0 then
            local ok2, name, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
            if ok2 and timeLimit and timeLimit > 0 then
                _timeLimit = timeLimit
                MF.dungeonText:SetText(name or "Mythic+")
                MF.timerBar:SetMinMaxValues(0, _timeLimit)
                PlaceChestTicks()
            end
        end
    end

    if _timeLimit <= 0 then return end

    local time3 = _timeLimit * 0.60
    local time2 = _timeLimit * 0.80

    -- Bar fills from 0 to _timeLimit
    MF.timerBar:SetValue(math_min(_timeLimit, elapsed))

    -- Calculate chest countdown & phase
    local chestTier, chestRem, phase
    if elapsed < time3 then
        chestTier = 3
        chestRem = time3 - elapsed
        phase = 0 -- +3 on time (Green)
    elseif elapsed < time2 then
        chestTier = 2
        chestRem = time2 - elapsed
        phase = 1 -- +2 on time (Yellow)
    elseif elapsed < _timeLimit then
        chestTier = 1
        chestRem = _timeLimit - elapsed
        phase = 2 -- +1 on time (Cyan)
    else
        chestTier = 0
        chestRem = elapsed - _timeLimit
        phase = 3 -- Overtime (Red)
    end

    if MF.tick3 then MF.tick3:SetShown(chestTier >= 3) end
    if MF.tick2 then MF.tick2:SetShown(chestTier >= 2) end

    if phase ~= _lastTimerPhase then
        _lastTimerPhase = phase
        if phase == 0 then
            MF.timerBar:SetStatusBarColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B, 0.85)
            MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B) end
        elseif phase == 1 then
            MF.timerBar:SetStatusBarColor(CLR_YELLOW_R, CLR_YELLOW_G, CLR_YELLOW_B, 0.85)
            MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_YELLOW_R, CLR_YELLOW_G, CLR_YELLOW_B) end
        elseif phase == 2 then
            MF.timerBar:SetStatusBarColor(CLR_ONTIME_R, CLR_ONTIME_G, CLR_ONTIME_B, 0.85)
            MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_ONTIME_R, CLR_ONTIME_G, CLR_ONTIME_B) end
        else -- overtime
            MF.timerBar:SetStatusBarColor(CLR_OVTM_R, CLR_OVTM_G, CLR_OVTM_B, 0.90)
            MF.timerText:SetTextColor(CLR_RED_R, CLR_RED_G, CLR_RED_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_RED_R, CLR_RED_G, CLR_RED_B) end
        end
    end

    -- Timer text: Elapsed / Total
    local newTimerStr = string_format("%s / %s", FormatTime(elapsed), FormatTime(_timeLimit))
    if newTimerStr ~= _lastTimerText then
        _lastTimerText = newTimerStr
        MF.timerText:SetText(newTimerStr)
    end

    -- Chest countdown text
    if MF.chestText then
        local newChestStr
        if chestTier == 3 then
            newChestStr = string_format("+3 %s", FormatTime(chestRem))
        elseif chestTier == 2 then
            newChestStr = string_format("+2 %s", FormatTime(chestRem))
        elseif chestTier == 1 then
            newChestStr = string_format("+1 %s", FormatTime(chestRem))
        else
            newChestStr = string_format("+%s", FormatTime(chestRem))
        end
        if newChestStr ~= _lastChestText then
            _lastChestText = newChestStr
            MF.chestText:SetText(newChestStr)
        end
    end

    -- Death counter (only format and resize when count or time lost changes)
    local okd, deaths, timeLost = pcall(C_ChallengeMode.GetDeathCount)
    if okd and deaths and deaths > 0 then
        local tl = timeLost or (deaths * 5)
        if deaths ~= _lastDeaths or tl ~= _lastTimeLost then
            _lastDeaths = deaths
            _lastTimeLost = tl
            local lostMin = math_floor(tl / 60)
            local lostSec = tl % 60
            local lostStr = (lostMin > 0 and (lostSec > 0 and string_format("+%dm %ds", lostMin, lostSec) or string_format("+%dm", lostMin))) or
                string_format("+%ds", lostSec)
            local newDeathStr = string_format(
                "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12:0:0|t |cffff4444%d (%s)|r", deaths, lostStr)
            _lastDeathText = newDeathStr
            MF.deathText:SetText(newDeathStr)
            if MF.deathFrame then
                MF.deathFrame:SetWidth(MF.deathText:GetStringWidth() + 16)
                MF.deathFrame:Show()
            end
        end
    else
        if _lastDeaths ~= 0 then
            _lastDeaths = 0
            _lastTimeLost = 0
            _lastDeathText = ""
            MF.deathText:SetText("")
            if MF.deathFrame then MF.deathFrame:Hide() end
        end
    end
end

-- ─── ReinitTimer ──────────────────────────────────────────
local function ReinitTimer()
    _timerID = nil
    for i = 1, 10 do
        local okT, _, _, timerType = pcall(GetWorldElapsedTime, i)
        if okT and timerType == (_G.Enum and _G.Enum.WorldElapsedTimerTypes
                and _G.Enum.WorldElapsedTimerTypes.ChallengeMode) then
            _timerID = i
            break
        end
    end
    if not _timerID then _timerID = 1 end
    UpdateTimer()
end

-- ─── Initialize M+ Run ───────────────────────────────────
local function InitRun()
    if not MF then BuildHUDFrame() end
    wipe(_bossSplits)
    _lastBossCount  = 0
    _lastTimerPhase = -1
    _lastTimerText  = ""
    _lastChestText  = ""
    _lastDeathText  = ""
    _lastDeaths     = -1
    _lastTimeLost   = -1
    CacheGroupMembers()

    local ok1, mapID          = pcall(C_ChallengeMode.GetActiveChallengeMapID)
    local ok2, level, affixes = pcall(C_ChallengeMode.GetActiveKeystoneInfo)

    if ok1 and mapID and mapID > 0 then
        local ok3, name, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
        MF.dungeonText:SetText((ok3 and name) or "Mythic+")
        _timeLimit = (ok3 and timeLimit) or 0
    else
        MF.dungeonText:SetText("Mythic+")
        _timeLimit = 0
    end

    MF.levelText:SetTextColor(1, 0.82, 0, 1)
    if ok2 and level and level > 0 then
        MF.levelText:SetText(string_format("+%d", level))
        BuildAffixRow(affixes or EMPTY_TABLE)
    else
        MF.levelText:SetText("+?")
        BuildAffixRow(EMPTY_TABLE)
    end

    _forcesSplitTime = nil
    _runCompleted    = false
    _currentMapID = (ok1 and mapID and mapID > 0) and mapID or nil
    _currentLevel = (ok2 and level and level > 0) and level or nil
    _currentBestRun = GetBestRun(_currentMapID, _currentLevel)

    if _currentBestRun and _currentBestRun.duration and _currentBestRun.duration > 0 then
        local pbLvl = _currentBestRun.level or _currentLevel
        if pbLvl and pbLvl > 0 then
            MF.pbText:SetText(string_format("best: %s (+%d)", FormatTime(_currentBestRun.duration), pbLvl))
        else
            MF.pbText:SetText(string_format("best: %s", FormatTime(_currentBestRun.duration)))
        end
        MF.pbText:Show()
        MF.header:SetHeight(28)
    else
        MF.pbText:SetText("")
        MF.pbText:Hide()
        MF.header:SetHeight(24)
    end

    -- Detect active timer ID
    _timerID = nil
    for i = 1, 10 do
        local okT, _, _, timerType = pcall(GetWorldElapsedTime, i)
        if okT and timerType == (_G.Enum and _G.Enum.WorldElapsedTimerTypes
                and _G.Enum.WorldElapsedTimerTypes.ChallengeMode) then
            _timerID = i
            break
        end
    end
    if not _timerID then _timerID = 1 end

    MF.timerBar:SetMinMaxValues(0, math_max(1, _timeLimit))
    MF.timerBar:SetValue(0)

    UpdateInstanceState()
    UpdateTimer()
    C_Timer.After(0.05, PlaceChestTicks)
end

-- ─── Initialize Dungeon/Delve/Scenario ────────────────────
local function InitDungeon()
    if not MF then BuildHUDFrame() end
    wipe(_bossSplits)
    _forcesSplitTime = nil
    _runCompleted    = false
    _currentMapID    = nil
    _currentLevel    = nil
    _currentBestRun  = nil
    if MF.pbText then
        MF.pbText:SetText("")
        MF.pbText:Hide()
    end
    MF.header:SetHeight(24)
    _lastBossCount  = 0
    _lastTimerPhase = -1
    _lastTimerText  = ""
    _lastDeathText  = ""
    _lastDeaths     = -1
    _lastTimeLost   = -1

    -- Instance info
    local instName, _, _, diffName
    if _G.GetInstanceInfo then
        instName, _, _, diffName = _G.GetInstanceInfo()
    end

    -- Scenario info (overrides raw instance name if available)
    local scenName, scenType
    if C_Scenario and C_Scenario.GetInfo then
        local ok, n, _, _, _, _, _, _, _, _, t = pcall(C_Scenario.GetInfo)
        if ok then scenName, scenType = n, t end
    end

    local displayName = scenName or instName or "Dungeon"

    -- Determine difficulty label using hoisted DIFF_ABBR table (no per-call allocation)
    -- instName:lower():find("delve") removed — rely on scenType == 8 instead
    local typeLabel
    if scenType == 1 then
        typeLabel = "|cffff7700M+|r" -- safety net; should be caught by CHALLENGE_MODE_START
    elseif scenType == 8 then
        typeLabel = "|cffa864ffDelve|r"
    elseif diffName and diffName ~= "" then
        typeLabel = DIFF_ABBR[diffName] or diffName
    else
        typeLabel = ""
    end

    MF.dungeonText:SetText(displayName)
    MF.levelText:SetText(typeLabel)
    MF.levelText:SetTextColor(1, 0.82, 0, 1)

    _timerID   = nil
    _timeLimit = 0

    UpdateInstanceState()
end

-- ─── Ticker ───────────────────────────────────────────────
local function _OnMythicTicker()
    if _mode == nil or not MF or not MF:IsShown() then
        if _ticker then _ticker:Cancel() end
        _ticker = nil
        return
    end
    if _mode == "mythic" then UpdateTimer() end
end

local function StartTicker()
    if _ticker then return end
    _ticker = C_Timer.NewTicker(TICKER_RATE, _OnMythicTicker)
end

local function StopTicker()
    if _ticker then
        _ticker:Cancel()
        _ticker = nil
    end
end

-- ─── Show / Hide ──────────────────────────────────────────
local function ShowHUD(forceDungeon)
    if not sfui.mythic.IsEnabled() then return end
    if not MF then BuildHUDFrame() end

    -- Restore saved position (matches objective tracker position)
    local posX = (SfuiDB and (SfuiDB.mythicHudX or SfuiDB.questlogX)) or mcfg.posX or -10
    local posY = (SfuiDB and (SfuiDB.mythicHudY or SfuiDB.questlogY)) or mcfg.posY or -10
    MF:ClearAllPoints()
    MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)

    if sfui.SuppressBlizzardTracker then
        sfui.SuppressBlizzardTracker()
    end

    -- Apply lock state
    local isLocked = not (SfuiDB and SfuiDB.mythicHudUnlocked)
    MF.dragBar:SetShown(not isLocked)
    MF:EnableMouse(not isLocked)

    local isMPlus = false
    local okM, isActive = pcall(C_ChallengeMode.IsChallengeModeActive)
    if okM and isActive then isMPlus = true end

    if isMPlus and not forceDungeon then
        _mode = "mythic"
        InitRun()
        StartTicker()
    else
        _mode = "dungeon"
        InitDungeon()
    end
    MF:Show()
end

local function HideHUD()
    StopTicker()
    _mode = nil
    if MF then MF:Hide() end
end

-- ─── Public Helpers for Options Tab ───────────────────────
function sfui.mythic.SetEnabled(val)
    SfuiDB = SfuiDB or {}
    SfuiDB.mythicHudEnabled = val
    if not val then
        HideHUD() -- HideHUD already sets _mode = nil
    end
end

function sfui.mythic.SetLocked(locked)
    SfuiDB = SfuiDB or {}
    SfuiDB.mythicHudUnlocked = not locked
    if MF then
        MF.dragBar:SetShown(not locked)
        MF:EnableMouse(not locked)
    end
end

function sfui.mythic.ResetPosition()
    if SfuiDB then
        SfuiDB.mythicHudX = nil
        SfuiDB.mythicHudY = nil
        SfuiDB.questlogX  = nil
        SfuiDB.questlogY  = nil
    end
    if MF then
        MF:ClearAllPoints()
        MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", mcfg.posX or -10, mcfg.posY or -10)
    end
    if sfui.questlog and sfui.questlog.reset_position then
        sfui.questlog.reset_position()
    end
end

local function _OnInitRunDeferred()
    if _mode == "mythic" and MF and MF:IsShown() then
        InitRun()
    end
end

local function CheckScenarioState()
    if _isPreview then return end
    local isMPlus = false
    local okM, isActive = pcall(C_ChallengeMode.IsChallengeModeActive)
    if okM and isActive then isMPlus = true end

    local inInst = false
    if _G.IsInInstance then
        local okI, inI = pcall(_G.IsInInstance)
        if okI and inI then inInst = true end
    end

    if isMPlus or (_runCompleted and _mode == "mythic" and inInst) then
        if _mode ~= "mythic" then
            _mode = "mythic"
            if C_MythicPlus and C_MythicPlus.RequestMapInfo then
                C_MythicPlus.RequestMapInfo()
            end
            if sfui.questlog and sfui.questlog.on_mythic_start then
                sfui.questlog.on_mythic_start()
            end
            ShowHUD()
            C_Timer.After(0.4, _OnInitRunDeferred)
        else
            UpdateInstanceState()
        end
        return
    end

    -- If run was completed but player is no longer inside the instance, clean up and hide
    if _runCompleted and not inInst then
        _runCompleted = false
        _mode = nil
        HideHUD()
        if sfui.questlog and sfui.questlog.on_mythic_end then
            sfui.questlog.on_mythic_end()
        end
        return
    end

    local inScenario = false
    if inInst then
        if C_Scenario and C_Scenario.IsInScenario then
            local ok, inScen = pcall(C_Scenario.IsInScenario)
            if ok and inScen then inScenario = true end
        end
        if not inScenario and C_DelvesUI and C_DelvesUI.HasActiveDelve then
            local ok, hasDelve = pcall(C_DelvesUI.HasActiveDelve)
            if ok and hasDelve then inScenario = true end
        end
        if not inScenario and _G.IsInInstance then
            local ok, _, instType = pcall(_G.IsInInstance)
            if ok and instType == "scenario" then inScenario = true end
        end
    end

    if inScenario then
        if _mode ~= "dungeon" then
            _mode = "dungeon"
            if sfui.questlog and sfui.questlog.on_mythic_start then
                sfui.questlog.on_mythic_start()
            end
            ShowHUD(true)
        else
            UpdateInstanceState()
        end
    else
        if _mode ~= nil then
            _mode = nil
            HideHUD()
            if sfui.questlog and sfui.questlog.on_mythic_end then
                sfui.questlog.on_mythic_end()
            end
        end
    end
end

function sfui.mythic.ShowPreview()
    if not MF then BuildHUDFrame() end

    _isPreview = true

    if sfui.questlog and sfui.questlog.on_mythic_start then
        sfui.questlog.on_mythic_start()
    end

    -- Restore saved position (matches objective tracker position)
    local posX = (SfuiDB and (SfuiDB.mythicHudX or SfuiDB.questlogX)) or mcfg.posX or -10
    local posY = (SfuiDB and (SfuiDB.mythicHudY or SfuiDB.questlogY)) or mcfg.posY or -10
    MF:ClearAllPoints()
    MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)

    -- Set mode to mythic for preview rendering
    _mode = "mythic"

    MF.dungeonText:SetText("Burial Grounds")
    MF.levelText:SetText("+12")
    MF.levelText:SetTextColor(1, 0.82, 0, 1)

    if MF.pbText then
        MF.pbText:SetText("best: 18:20 (+12)")
        MF.pbText:Show()
        MF.header:SetHeight(28)
    end

    BuildAffixRow({ 9, 10, 135 })

    _timeLimit      = 1980
    _lastTimerPhase = -1
    _lastTimerText  = ""
    _lastChestText  = ""
    MF.timerBar:SetMinMaxValues(0, _timeLimit)
    MF.timerBar:SetValue(1100)
    MF.timerBar:SetStatusBarColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B, 0.85)
    MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
    MF.timerText:SetText("18:20 / 33:00")
    if MF.chestText then
        MF.chestText:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B)
        MF.chestText:SetText("+3 01:28")
        MF.chestText:Show()
    end
    if MF.deathFrame then
        MF.deathText:SetText("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12:0:0|t |cffff44441 (+5s)|r")
        MF.deathFrame:SetWidth(MF.deathText:GetStringWidth() + 16)
        MF.deathFrame:Show()
    end

    PlaceChestTicks()

    local fakes = {
        { name = "Corpsefire",  done = true,  split = "[04:12] |cff00ff88-0:28|r", offset = -95 },
        { name = "Bishibosh",   done = true,  split = "[08:55] |cffff4444+0:15|r", offset = -95 },
        { name = "Coldcrow",    done = false, split = "|cff555555[12:40]|r",       offset = -55 },
        { name = "Blood Raven", done = false, split = "|cff555555[18:20]|r",       offset = -55 },
    }
    for i, f in ipairs(fakes) do
        local r = GetOrCreateBossRow(i)
        r.row:Show()
        if f.done then
            r.icon:Hide(); r.check:Show()
            r.name:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B)
            r.split:SetTextColor(CLR_DIM_R, CLR_DIM_G, CLR_DIM_B)
            r.split:SetText(f.split)
            r.name:ClearAllPoints()
            r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
            r.name:SetPoint("RIGHT", r.row, "RIGHT", f.offset, 0)
        else
            r.check:Hide(); r.icon:Show()
            r.name:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            r.split:SetTextColor(CLR_DIM_R, CLR_DIM_G, CLR_DIM_B)
            r.split:SetText(f.split)
            r.name:ClearAllPoints()
            r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
            r.name:SetPoint("RIGHT", r.row, "RIGHT", f.offset, 0)
        end
        r.name:SetText(f.name)
    end
    HideExtraBossRows(#fakes)
    RelayoutHUD(#fakes)

    MF.forcesBar:SetMinMaxValues(0, 100)
    MF.forcesBar:SetValue(61.79)
    MF.forcesBar:SetStatusBarColor(0.40, 0.00, 1.00, 0.85)
    MF.forcesText:SetText("61.79% / 100%")
    MF.forcesCountText:SetText("")

    local isLocked = not (SfuiDB and SfuiDB.mythicHudUnlocked)
    MF.dragBar:SetShown(not isLocked)
    MF:EnableMouse(not isLocked)
    MF:Show()
    MF:SetAlpha(1)
end

function sfui.mythic.HidePreview()
    _isPreview = false
    _mode = nil
    if MF and MF.pbText then
        MF.pbText:SetText("")
        MF.pbText:Hide()
        MF.header:SetHeight(24)
    end
    HideHUD()
    if sfui.questlog and sfui.questlog.on_mythic_end then
        sfui.questlog.on_mythic_end()
    end
    CheckScenarioState()
end

-- ─── Event-Driven State Update (Coalesced & Throttled) ────
local _stateUpdatePending = false
-- Named callback to avoid closure allocation on every C_Timer.After call.
-- UPDATE_UI_WIDGET fires very frequently (even in cities), so each expiry
-- would otherwise create a new closure.
local function _OnStateUpdateTimer()
    _stateUpdatePending = false
    CheckScenarioState()
end
local function RequestStateUpdate(delay)
    if _stateUpdatePending then return end
    _stateUpdatePending = true
    C_Timer.After(delay or 0.4, _OnStateUpdateTimer)
end

-- ─────────────────────────────────────────────────────────
--  EVENTS (Central Dispatcher)
-- ─────────────────────────────────────────────────────────
local function on_mythic_event(event, ...)
    if event == "CHALLENGE_MODE_START" then
        _mode = "mythic"
        _runCompleted = false
        wipe(_playerDeaths)
        CacheGroupMembers()
        SyncBlizzardRunHistory()
        -- Register UNIT_DIED dynamically: only needed during an active M+ run
        -- to count player deaths per name. Avoids open-world / raid / Delve
        -- UNIT_DIED traffic being dispatched outside active runs.
        sfui.events.RegisterEvent("UNIT_DIED", on_mythic_event)
        if sfui.questlog and sfui.questlog.on_mythic_start then
            sfui.questlog.on_mythic_start()
        end
        ShowHUD()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        StopTicker()
        -- UNIT_DIED no longer needed once the run ends.
        sfui.events.UnregisterEvent("UNIT_DIED", on_mythic_event)
        if _mode == "mythic" then
            _runCompleted = true
            UpdateTimer()
            UpdateInstanceState()
            SaveCompletedRunRecord()
            SyncBlizzardRunHistory()
        end
    elseif event == "CHALLENGE_MODE_RESET" then
        _runCompleted = false
        _mode = nil
        -- Unregister UNIT_DIED: no active run to track deaths for.
        sfui.events.UnregisterEvent("UNIT_DIED", on_mythic_event)
        HideHUD()
        if sfui.questlog and sfui.questlog.on_mythic_end then
            sfui.questlog.on_mythic_end()
        end
    elseif event == "SCENARIO_CRITERIA_UPDATE" or event == "SCENARIO_UPDATE" or
        event == "ACTIVE_DELVE_DATA_UPDATE" or
        event == "SCENARIO_COMPLETED" or
        event == "SCENARIO_SPELL_UPDATE" then
        if sfui.SuppressBlizzardTracker then
            sfui.SuppressBlizzardTracker()
        end
        if _mode == nil then
            local okInst, inInst = pcall(_G.IsInInstance)
            if not (okInst and inInst) then return end
            CheckScenarioState()
        end
        RequestStateUpdate(0.4)
    elseif event == "CHALLENGE_MODE_DEATH_COUNT_UPDATED" then
        if _mode == "mythic" then UpdateTimer() end
    elseif event == "UNIT_DIED" and _mode == "mythic" then
        local destGUID = select(1, ...)
        if destGUID then
            if issecretvalue and issecretvalue(destGUID) then return end
            for _, p in ipairs(_playerList) do
                if p.guid == destGUID then
                    if not (UnitIsFeignDeath and UnitIsFeignDeath(p.unit)) then
                        _playerDeaths[p.name] = (_playerDeaths[p.name] or 0) + 1
                    end
                    break
                end
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        CacheGroupMembers()
    elseif event == "CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN" then
        if C_Container and C_Container.GetContainerNumSlots and C_Item and C_Item.IsItemKeystoneByID then
            for bagID = 0, (_G.NUM_BAG_SLOTS or 4) do
                local numSlots = C_Container.GetContainerNumSlots(bagID) or 0
                for invID = 1, numSlots do
                    local itemID = C_Container.GetContainerItemID(bagID, invID)
                    if itemID and C_Item.IsItemKeystoneByID(itemID) then
                        C_Container.UseContainerItem(bagID, invID)
                        break
                    end
                end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        CacheGroupMembers()
        SyncBlizzardRunHistory()
        CheckScenarioState()
        RequestStateUpdate(0.6)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        RequestStateUpdate(0.4)
    elseif event == "UPDATE_FACTION" then
        if _mode == "dungeon" then RequestStateUpdate(0.2) end
    elseif event == "WORLD_STATE_TIMER_START" or event == "WORLD_STATE_TIMER_STOP" then
        if _mode == "mythic" then ReinitTimer() end
    end
end

local function Reg(e) sfui.events.RegisterEvent(e, on_mythic_event) end
Reg("CHALLENGE_MODE_START")
Reg("CHALLENGE_MODE_COMPLETED")
Reg("CHALLENGE_MODE_RESET")
Reg("CHALLENGE_MODE_DEATH_COUNT_UPDATED")
Reg("CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN")
-- UNIT_DIED is registered dynamically inside CHALLENGE_MODE_START and unregistered on COMPLETED/RESET.
Reg("GROUP_ROSTER_UPDATE")
Reg("SCENARIO_UPDATE")
Reg("SCENARIO_CRITERIA_UPDATE")
Reg("SCENARIO_COMPLETED")
Reg("SCENARIO_SPELL_UPDATE")
Reg("ACTIVE_DELVE_DATA_UPDATE")
Reg("UPDATE_FACTION")
Reg("PLAYER_ENTERING_WORLD")
Reg("ZONE_CHANGED_NEW_AREA")
Reg("WORLD_STATE_TIMER_START")
Reg("WORLD_STATE_TIMER_STOP")

-- UPDATE_UI_WIDGET: throttled at 0.2s via the central dispatcher.
-- Replaces Reg("UPDATE_UI_WIDGET") which would fire 10-20x/sec in city hubs.
do
    local function _on_widget_update()
        if sfui.SuppressBlizzardTracker then
            sfui.SuppressBlizzardTracker()
        end
        if _mode == nil then
            local okInst, inInst = pcall(_G.IsInInstance)
            if not (okInst and inInst) then return end
            CheckScenarioState()
        end
        RequestStateUpdate(0.4)
    end
    sfui.events.RegisterThrottledEvent("UPDATE_UI_WIDGET", 0.2, _on_widget_update)
end

function sfui.mythic_debug_info()
    local deathCount = 0
    for _ in pairs(_playerDeaths) do deathCount = deathCount + 1 end

    return {
        spellPool    = #spellPool,
        currencyPool = #currencyPool,
        deathPool    = #deathBreakdownPool,
        playerList   = #_playerList,
        playerDeaths = deathCount,
        badgePool    = (MF and MF.delveBadges and #MF.delveBadges) or 0,
        bossRowPool  = (MF and MF.bossRows and #MF.bossRows) or 0,
    }
end
