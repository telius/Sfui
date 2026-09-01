local addonName, addon = ...
sfui = sfui or {}
sfui.questlog = sfui.questlog or {}

local g = sfui.config
local common = sfui.common
local qcfg = g.questlog or {
    width = 280,
    sectionHeight = 20,
    questHeight = 17,
    objectiveHeight = 13,
    throttle = 0.35,
    defaultHidden = false,
    sections = {
        { id = "important",  label = "important",        color = { 1.00, 0.40, 0.35 } },
        { id = "campaign",   label = "campaign",         color = { 0.90, 0.75, 0.10 } },
        { id = "meta",       label = "meta",             color = { 0.00, 1.00, 1.00 } },
        { id = "world",      label = "world quests",     color = { 0.20, 0.85, 0.95 } },
        { id = "activities", label = "activities",       color = { 0.35, 0.90, 0.40 } },
        { id = "zone",       label = "quests",           color = { 1.00, 1.00, 1.00 } },
    },
}

--[[
    SFUI Quest Log (Midnight Edition)
    Collapsible quest log panel with integrated World Quests on top.
    Sections: important | campaign | meta | world quests | activities | quests (white)
    Features:
      - 100% Non-secure lightweight architecture (zero combat taint / restrictions)
      - Smart Priority Sorting (SuperTrack > Ready for Turn-in > In-Progress > Failed)
      - Auto-Collapse on Complete to conserve vertical screen space
      - Instant Zero-Redraw SuperTrack waypoint indicator synchronization
      - Auto-hide during Raid Boss Encounters, Mythic+, and Delves
      - Shift-Click: Untrack all quests in category or individual quest
      - Ctrl-Click: Abandon quest
      - Alt-Click: Share quest with party
      - Left-Click: Open in Map & Quest Log details + SuperTrack
      - Right-Click / Arrow: Collapse/Expand objectives
      - Dynamic anchor: snaps below event widgets or Blizzard bonus/scenario objectives
      - Physical bottom boundary cutoff (50% screen height + 50px)
      - Zero-Allocation refresh loop, string-buffer reuse, and C-API caching
]]

-- Localize Globals & Core C-APIs
local CreateFrame, UIParent = _G.CreateFrame, _G.UIParent
local C_QuestLog        = _G.C_QuestLog
local C_TaskQuest       = _G.C_TaskQuest
local C_Map             = _G.C_Map
local C_QuestInfoSystem = _G.C_QuestInfoSystem
local C_Timer           = _G.C_Timer
local C_SuperTrack      = _G.C_SuperTrack
local Enum              = _G.Enum
local table, ipairs, pairs, type, math =
    _G.table, _G.ipairs, _G.pairs, _G.type, _G.math
local math_min, math_max, math_floor = _G.math.min, _G.math.max, _G.math.floor
local tostring, tonumber = _G.tostring, _G.tonumber
local wipe = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local issecretvalue = _G.issecretvalue or function() return false end
local QuestMapFrame_OpenToQuestDetails = _G.QuestMapFrame_OpenToQuestDetails
local GetTasksTable = _G.GetTasksTable
local print = _G.print
local string_format = string.format  -- localize alias (avoids global table lookup on every call)

-- Isolated Tooltip Frame (Zero global GameTooltip taint, zero UIWidgetManager registration)
local SfuiQuestTooltip = sfui.tooltip

-- Cache Enum Constants
local QC = Enum and Enum.QuestClassification
local QC_Campaign  = QC and QC.Campaign
local QC_Calling   = QC and QC.Calling
local QC_Important = QC and QC.Important
local QC_Legendary = QC and QC.Legendary
local QC_Recurring = QC and QC.Recurring
local QC_Meta      = (QC and QC.Meta) or 6

local QR = Enum and Enum.QuestRepeatability
local QR_Daily  = (QR and QR.Daily) or 1
local QR_Weekly = (QR and QR.Weekly) or 2

-- Layout constants from config
local FRAME_W    = qcfg.width or 280
local SECT_H     = qcfg.sectionHeight or 20
local QUEST_H    = qcfg.questHeight or 20
local OBJ_H      = qcfg.objectiveHeight or 13
local PAD_X      = 8
local OBJ_INDENT = 14
local THROTTLE   = qcfg.throttle or 0.5
local SECT_GAP   = 2
local QUEST_PAD  = 2

-- Pre-cached Formatting Strings
local ITEM_TAG_STRING   = "|TInterface\\Buttons\\WHITE8x8:6:6:0:0:8:8:0:8:0:8:102:0:255|t "
local COLOR_COMPLETE    = "|cffff00ff"
local COMPLETE_SUFFIX   = " |cff44cc44[Complete]|r"
local COLOR_SUPERTRACK  = "|cffffff00"
local COLOR_WARBAND     = "|cffa02020"
local COLOR_META        = "|cff00ffff"
local COLOR_FAILED      = "|cffff4444"
local COLOR_DONE_CNT    = "|cff44cc44"
local COLOR_UNDONE_CNT  = "|cff777777"
local COLOR_TIME        = "|cff33d9f2"
local COLOR_RESET       = "|r"

-- Section definitions (display order)
local SECTION_DEFS = qcfg.sections or {
    { id = "scenario",     label = "world event",      color = { 1.00, 0.60, 0.10 } },
    { id = "important",    label = "important",        color = { 1.00, 0.40, 0.35 } },
    { id = "campaign",     label = "campaign",         color = { 0.90, 0.75, 0.10 } },
    { id = "meta",         label = "meta",             color = { 0.00, 1.00, 1.00 } },
    { id = "world",        label = "world quests",     color = { 0.20, 0.85, 0.95 } },
    { id = "activities",   label = "activities",       color = { 0.35, 0.90, 0.40 } },
    { id = "zone",         label = "quests",           color = { 1.00, 1.00, 1.00 } },
    { id = "achievements", label = "achievements",     color = { 0.85, 0.65, 0.35 } },
}

-- Row & Table pools (Zero-Allocation Architecture)
local rowPool             = {}
local activeRows          = {}
local objPool             = {}
local activeObjs          = {}
local questProgressCache  = {}
local warbandCompleteCache = {}
local inCombat            = false
local currentSuperTrackedID = 0
local QL

local function InCombat()
    return _G.InCombatLockdown() or inCombat
end

-- ─── State ────────────────────────────────────────────────
-- Single-evaluation per refresh cycle. Avoids re-calling
-- C_ChallengeMode on every guard site in the file.
local State = {}
State._active = false

-- Named helper: avoids anonymous closure allocation on every State:Update() call.
local function _IsChallengeActive()
    return _G.C_ChallengeMode
        and _G.C_ChallengeMode.IsChallengeModeActive
        and _G.C_ChallengeMode.IsChallengeModeActive()
end

local function IsRaidQuest(questID, info)
    if not questID then return false end
    if not info and C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetInfo then
        local lIndex = C_QuestLog.GetLogIndexForQuestID(questID)
        info = lIndex and C_QuestLog.GetInfo(lIndex)
    end

    if info and (info.isOnMap or info.hasLocalPOI) then
        return true
    end

    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local tagInfo = C_QuestLog.GetQuestTagInfo(questID)
        if tagInfo then
            local tID = tagInfo.tagID
            local wqType = tagInfo.worldQuestType
            local eq = Enum and Enum.QuestTag
            local eqt = Enum and Enum.QuestTagType
            if (eq and (tID == eq.Raid or tID == eq.Raid10 or tID == eq.Raid25))
                or tID == 89 or tID == 109 or tID == 110
                or (eqt and wqType == eqt.Raid) then
                return true
            end
        end
    end

    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID then
        if C_QuestLog and C_QuestLog.GetQuestsOnMap then
            local qOnMap = C_QuestLog.GetQuestsOnMap(mapID)
            if qOnMap then
                for i = 1, #qOnMap do
                    if qOnMap[i].questID == questID then return true end
                end
            end
        end
        if C_TaskQuest and C_TaskQuest.GetQuestsOnMap then
            local tOnMap = C_TaskQuest.GetQuestsOnMap(mapID)
            if tOnMap then
                for i = 1, #tOnMap do
                    if tOnMap[i].questID == questID then return true end
                end
            end
        end
    end

    return false
end

local function HasRaidQuest()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID then
        if C_QuestLog and C_QuestLog.GetQuestsOnMap then
            local qOnMap = C_QuestLog.GetQuestsOnMap(mapID)
            if qOnMap and #qOnMap > 0 then return true end
        end
        if C_TaskQuest and C_TaskQuest.GetQuestsOnMap then
            local tOnMap = C_TaskQuest.GetQuestsOnMap(mapID)
            if tOnMap and #tOnMap > 0 then return true end
        end
    end

    local numEntries = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries()) or 0
    for i = 1, numEntries do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden then
            if IsRaidQuest(info.questID, info) then
                return true
            end
        end
    end
    return false
end

function State:Update()
    -- mythic.lua owns the display whenever it is active in an instance (M+, dungeon, delve).
    -- Check this first so we never race against mythic.lua's event registration order.
    if sfui.mythic and sfui.mythic.IsActive and sfui.mythic.IsActive() then
        self._active = true; return
    end

    local cm = _IsChallengeActive and _IsChallengeActive()
    if cm then self._active = true; return end

    if C_DelvesUI and C_DelvesUI.HasActiveDelve then
        local hasDelve = C_DelvesUI.HasActiveDelve()
        if hasDelve then self._active = true; return end
    end

    if _G.IsInInstance then
        local inInst, instType = _G.IsInInstance()
        if inInst and instType ~= "none" then
            if instType == "raid" and HasRaidQuest() then
                self._active = false
                return
            end
            self._active = true; return
        end
    end

    if _G.GetInstanceInfo then
        local _, _, _, difficultyID = _G.GetInstanceInfo()
        if difficultyID == 8 or difficultyID == 208 then self._active = true; return end
    end

    self._active = false
end

function State:IsActive() return self._active end

-- ─── Refresh ──────────────────────────────────────────────
-- Coalescing timer: all event-driven refreshes collapse into
-- one C_Timer.After(THROTTLE). Matches MidnightObjective's
-- Refresh:Request() pattern.
local Refresh = {}
local _refreshPending = false

-- Named callback to avoid closure allocation on every C_Timer.After.
-- QUEST_LOG_UPDATE fires frequently (even idle), so each expiry would
-- otherwise create a new closure.
local function _OnRefreshTimer()
    _refreshPending = false
    State:Update()
    if State:IsActive() then return end
    if QL and QL.IsShown and QL:IsShown() then
        QL:DoRefresh()
    end
end

function Refresh:Request()
    State:Update()
    if State:IsActive() then return end
    if _refreshPending then return end
    _refreshPending = true
    C_Timer.After(THROTTLE, _OnRefreshTimer)
end


-- ─── Blizzard Root Tracker Suppression (Strictly Taint-Free) ─────────
-- Never reparent, never call UnregisterAllEvents(), never overwrite SetScript("OnShow").
-- Suppress cleanly via Alpha and EnableMouse without script hooks.

local function ApplyBlizzardTrackerSuppression()
    local root = _G.ObjectiveTrackerFrame
    if not root then return end

    if root.SetAlpha then root:SetAlpha(0) end
    if root.EnableMouse then root:EnableMouse(false) end
end

local function SuppressBlizzardTracker()
    ApplyBlizzardTrackerSuppression()
end

local function RestoreBlizzardTracker()
    local root = _G.ObjectiveTrackerFrame
    if not root then return end
    if InCombat() then return end

    if root.SetAlpha then root:SetAlpha(1) end
    if root.EnableMouse then root:EnableMouse(true) end
    if root.Show then root:Show() end
end

sfui.SuppressBlizzardTracker = SuppressBlizzardTracker
sfui.RestoreBlizzardTracker  = RestoreBlizzardTracker

local outOfCombatQueue = {}
local function QueueOutOfCombatAction(key, fn)
    if not InCombat() then
        fn()
        return
    end
    outOfCombatQueue[key] = fn
end

local function FlushOutOfCombatQueue()
    for key, fn in pairs(outOfCombatQueue) do
        outOfCombatQueue[key] = nil
        if fn then
            if sfui.common and sfui.common.safecall then
                sfui.common.safecall(fn)
            else
                fn()
            end
        end
    end
end

-- Map Cache
local cachedCurrentMapID = nil
local cachedParentMapID  = nil

local function UpdateMapCache()
    if not C_Map or not C_Map.GetBestMapForUnit then return end
    local curMap = C_Map.GetBestMapForUnit("player")
    if curMap ~= cachedCurrentMapID then
        cachedCurrentMapID = curMap
        cachedParentMapID = nil
        if curMap and C_Map.GetMapInfo then
            local info = C_Map.GetMapInfo(curMap)
            if info and info.parentMapID and info.parentMapID > 0 and info.parentMapID ~= curMap then
                cachedParentMapID = info.parentMapID
            end
        end
    end
end

local MAX_TABLE_POOL = 300
local tablePool = {}
local function AcquireTable()
    local t = table.remove(tablePool) or {}
    wipe(t)
    return t
end

local function ReleaseTable(t)
    if type(t) ~= "table" then return end
    if t.objectives then
        if type(t.objectives) == "table" then
            for i = #t.objectives, 1, -1 do
                local obj = table.remove(t.objectives, i)
                if type(obj) == "table" then
                    wipe(obj)
                    if #tablePool < MAX_TABLE_POOL then
                        tablePool[#tablePool + 1] = obj
                    end
                end
            end
            wipe(t.objectives)
            if #tablePool < MAX_TABLE_POOL then
                tablePool[#tablePool + 1] = t.objectives
            end
        end
        t.objectives = nil
    end
    t._syntheticObjs = nil
    wipe(t)
    if #tablePool < MAX_TABLE_POOL then
        tablePool[#tablePool + 1] = t
    end
end

-- Static section lists to eliminate table allocation on refresh
local sectionLists = {
    scenario     = {},
    world        = {},
    campaign     = {},
    meta         = {},
    important    = {},
    activities   = {},
    zone         = {},
    achievements = {},
}

local renderedSectionQuests = {
    scenario     = {},
    world        = {},
    campaign     = {},
    meta         = {},
    important    = {},
    activities   = {},
    zone         = {},
    achievements = {},
}
local processedQuests = {}

local function ClearSectionLists()
    for _, def in ipairs(SECTION_DEFS) do
        local list = sectionLists[def.id]
        if list then
            for i = #list, 1, -1 do
                local entry = table.remove(list, i)
                ReleaseTable(entry)
            end
        else
            sectionLists[def.id] = {}
        end
        if not renderedSectionQuests[def.id] then renderedSectionQuests[def.id] = {} end
    end
end

-- Saved state
local function GetQLState()
    if not SfuiDB then SfuiDB = {} end
    if not SfuiDB.questlog then
        SfuiDB.questlog = {
            collapsed      = {},
            expandedQuests = {},
            hiddenQuests   = {},
            hidden         = false,
        }
    end
    SfuiDB.questlog.expandedQuests = SfuiDB.questlog.expandedQuests or {}
    SfuiDB.questlog.hiddenQuests   = SfuiDB.questlog.hiddenQuests or {}
    SfuiDB.questlog.collapsed      = SfuiDB.questlog.collapsed or {}
    if SfuiDB.questlog.hidden == nil then SfuiDB.questlog.hidden = false end
    return SfuiDB.questlog
end

local function UntrackQuest(questID)
    if not questID or questID <= 0 then return end

    local state = GetQLState()
    if state.hiddenQuests then
        state.hiddenQuests[questID] = true
    end

    -- Remove from Blizzard's watch list (source of truth).
    -- DoRefresh will see IsQuestWatched = false and drop it from the panel.
    if InCombat() then
        QueueOutOfCombatAction("untrack_" .. tostring(questID), function()
            if C_QuestLog.RemoveQuestWatch then
                C_QuestLog.RemoveQuestWatch(questID)
            end
            if C_QuestLog.RemoveWorldQuestWatch then
                C_QuestLog.RemoveWorldQuestWatch(questID)
            end
        end)
    else
        if C_QuestLog.RemoveQuestWatch then
            C_QuestLog.RemoveQuestWatch(questID)
        end
        if C_QuestLog.RemoveWorldQuestWatch then
            C_QuestLog.RemoveWorldQuestWatch(questID)
        end
    end
end

local TRACKING_TYPE_ACHIEVEMENT = (Enum and Enum.ContentTrackingType and Enum.ContentTrackingType.Achievement) or 2
local TRACKING_STOP_TYPE_MANUAL = (Enum and Enum.ContentTrackingStopType and Enum.ContentTrackingStopType.Manual) or 0

local function UntrackAchievement(achievementID)
    if not achievementID or achievementID <= 0 then return end

    if _G.RemoveTrackedAchievement then
        _G.RemoveTrackedAchievement(achievementID)
    end

    if C_ContentTracking and C_ContentTracking.StopTracking then
        C_ContentTracking.StopTracking(TRACKING_TYPE_ACHIEVEMENT, achievementID, TRACKING_STOP_TYPE_MANUAL)
    end
end

local staticAchMap = {}
local staticAchList = {}

local function GetAchievementCriteriaList(achievementID)
    local numCriteria = 0
    if GetAchievementNumCriteria then
        local n = GetAchievementNumCriteria(achievementID)
        if type(n) == "number" then numCriteria = n end
    end

    if numCriteria > 0 and GetAchievementCriteriaInfo then
        local objectives = nil
        for i = 1, numCriteria do
            local cString, cType, completed, qty, reqQty, _, _, _, qtyString = GetAchievementCriteriaInfo(achievementID, i)
            local finished = (completed == true) or (completed == 1)
            local txt = cString
            if not txt or txt == "" then txt = qtyString end
            if txt and txt ~= "" then
                qty = tonumber(qty)
                reqQty = tonumber(reqQty)
                if qty and reqQty and reqQty > 1 then
                    txt = txt .. " (" .. tostring(qty) .. "/" .. tostring(reqQty) .. ")"
                end
                if not objectives then objectives = AcquireTable() end
                local sObj = AcquireTable()
                sObj.text = txt
                sObj.finished = finished
                objectives[#objectives + 1] = sObj
            end
        end
        return objectives
    end
    return nil
end

local function ScanTrackedAchievements(intoList)
    wipe(staticAchMap)
    wipe(staticAchList)

    local function addID(id)
        if type(id) == "number" and id > 0 and not staticAchMap[id] then
            staticAchMap[id] = true
            staticAchList[#staticAchList + 1] = id
        end
    end

    if GetTrackedAchievements then
        local nTracked = select("#", GetTrackedAchievements())
        for i = 1, nTracked do
            local id = select(i, GetTrackedAchievements())
            if id then addID(id) end
        end
    end

    if C_ContentTracking and C_ContentTracking.GetTrackedIDs then
        local ids = C_ContentTracking.GetTrackedIDs(TRACKING_TYPE_ACHIEVEMENT)
        if ids and type(ids) == "table" then
            for _, id in ipairs(ids) do
                addID(id)
            end
        end
    end

    if #staticAchList == 0 then return end

    for _, achievementID in ipairs(staticAchList) do
        if type(achievementID) == "number" and achievementID > 0 then
            local id, name, points, completed, month, day, year, description, flags, icon = GetAchievementInfo(achievementID)
            if name and name ~= "" then
                local isComplete = (completed == true) or (completed == 1)
                local objs = GetAchievementCriteriaList(achievementID)
                if (not objs or #objs == 0) and description and description ~= "" then
                    if not objs then objs = AcquireTable() end
                    local sObj = AcquireTable()
                    sObj.text = description
                    sObj.finished = isComplete
                    objs[#objs + 1] = sObj
                end

                local done, total = 0, (objs and #objs or 0)
                if objs then
                    for _, obj in ipairs(objs) do
                        if obj.finished then done = done + 1 end
                    end
                end

                local entry = AcquireTable()
                entry.achievementID      = achievementID
                entry.questID            = nil
                entry.title              = name
                entry.description        = description
                entry.points             = points
                entry.icon               = icon
                entry.isComplete         = isComplete
                entry.isAchievement      = true
                entry.objectives         = objs
                entry._syntheticObjs     = (objs ~= nil)
                entry.done               = done
                entry.total              = total
                entry.singleCountStr     = (total > 0) and (done .. "/" .. total) or nil
                intoList[#intoList + 1] = entry
            end
        end
    end
end

-- World Quest cache — invalidated on zone change.
local worldQuestCache = {}

-- Check if a quest is a World Quest (cached per session)
local function IsWorldQuest(questID)
    local cached = worldQuestCache[questID]
    if cached ~= nil then return cached end
    local result = false
    if C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(questID) then
        result = true
    elseif _G.QuestUtils_IsQuestWorldQuest and _G.QuestUtils_IsQuestWorldQuest(questID) then
        result = true
    end
    worldQuestCache[questID] = result
    return result
end

-- Check if a quest is actively watched in Blizzard's quest watch system
local function IsQuestWatched(questID)
    if not questID or questID <= 0 then return false end
    if C_QuestLog.GetQuestWatchType then
        local wt = C_QuestLog.GetQuestWatchType(questID)
        if wt ~= nil then return true end
    end
    if C_QuestLog.IsQuestWatched then
        local w = C_QuestLog.IsQuestWatched(questID)
        if w then return true end
        if C_QuestLog.GetLogIndexForQuestID then
            local lIndex = C_QuestLog.GetLogIndexForQuestID(questID)
            if lIndex then
                local w2 = C_QuestLog.IsQuestWatched(lIndex)
                if w2 then return true end
            end
        end
    end
    return false
end

-- Check if a quest is completed by Warband (with session caching)
local function IsQuestWarbandCompleted(questID)
    local cached = warbandCompleteCache[questID]
    if cached ~= nil then return cached end

    local completed = false
    if C_QuestLog.IsQuestFlaggedCompletedOnAccount then
        completed = C_QuestLog.IsQuestFlaggedCompletedOnAccount(questID) or false
    end
    warbandCompleteCache[questID] = completed
    return completed
end

-- Helper: determine if a quest is a Meta quest
local function IsMetaQuest(questID, defaultInfo)
    if not questID or questID <= 0 then return false end
    if defaultInfo and (defaultInfo.isMeta or defaultInfo.questClassification == QC_Meta) then return true end

    if C_QuestLog.IsMetaQuest then
        local v = C_QuestLog.IsMetaQuest(questID)
        if v then return true end
    end

    if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification then
        local cls = C_QuestInfoSystem.GetQuestClassification(questID)
        if cls and (cls == QC_Meta or (QC and QC.Meta and cls == QC.Meta)) then
            return true
        end
    end

    if C_QuestLog.GetQuestTagInfo then
        local tag = C_QuestLog.GetQuestTagInfo(questID)
        if tag then
            if type(tag) == "table" then
                if tag.isMeta or tag.tagName == "Meta" or tag.tagID == (Enum.QuestTag and Enum.QuestTag.Meta) or tag.tagID == 128 then
                    return true
                end
            elseif tag == (Enum.QuestTag and Enum.QuestTag.Meta) or tag == 128 then
                return true
            end
        end
    end

    if C_QuestLog.GetInfo then
        local lIndex = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
        if lIndex then
            local info = C_QuestLog.GetInfo(lIndex)
            if info and (info.isMeta or info.questClassification == QC_Meta) then
                return true
            end
        end
    end

    return false
end

-- Classify standard quest → section ID (Fast Cached Enums)
local function ClassifyQuest(info, questID)
    if info.isTask or info.isBounty or IsWorldQuest(questID) then
        return "world"
    end
    if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification then
        local cls = C_QuestInfoSystem.GetQuestClassification(questID)
        if cls then
            if cls == QC_Campaign or cls == QC_Calling    then return "campaign"   end
            if cls == QC_Meta                             then return "meta"       end
            if cls == QC_Important or cls == QC_Legendary then return "important"  end
            if cls == QC_Recurring                        then return "activities" end
        end
    end
    if info.campaignID and info.campaignID > 0 then return "campaign" end
    if IsMetaQuest(questID, info) then return "meta" end
    if C_QuestLog.IsImportantQuest then
        local v = C_QuestLog.IsImportantQuest(questID)
        if v then return "important" end
    end
    local freq = info.frequency
    if freq == QR_Daily or freq == QR_Weekly or (freq and freq > 0) then
        return "activities"
    end
    return "zone"
end

local function UntrackSectionQuests(sectionID)
    if sectionID == "achievements" then
        if _G.RemoveTrackedAchievement and _G.GetTrackedAchievements then
            local tracked = { _G.GetTrackedAchievements() }
            for _, id in ipairs(tracked) do
                if id and type(id) == "number" and id > 0 then
                    _G.RemoveTrackedAchievement(id)
                end
            end
        end
        if C_ContentTracking and C_ContentTracking.GetTrackedIDs and C_ContentTracking.StopTracking then
            local ids = C_ContentTracking.GetTrackedIDs(TRACKING_TYPE_ACHIEVEMENT)
            if ids and type(ids) == "table" then
                for _, id in ipairs(ids) do
                    C_ContentTracking.StopTracking(TRACKING_TYPE_ACHIEVEMENT, id, TRACKING_STOP_TYPE_MANUAL)
                end
            end
        end
        return
    end

    -- 1. Untrack all currently rendered quests for this section
    local rendered = renderedSectionQuests[sectionID]
    if rendered then
        for _, qID in ipairs(rendered) do
            UntrackQuest(qID)
        end
    end

    -- 2. Untrack Watched World Quests
    if sectionID == "world" and C_QuestLog.GetNumWorldQuestWatches then
        local numW = C_QuestLog.GetNumWorldQuestWatches() or 0
        for w = numW, 1, -1 do
            local qID = C_QuestLog.GetQuestIDForWorldQuestWatchIndex(w)
            if qID and qID > 0 then
                UntrackQuest(qID)
            end
        end
    end

    -- 3. Local tasks / World Quests
    if sectionID == "world" and GetTasksTable then
        local tasks = GetTasksTable()
        if tasks then
            for i = 1, #tasks do
                if tasks[i] and tasks[i] > 0 then
                    UntrackQuest(tasks[i])
                end
            end
        end
    end

    -- 4. Standard Quest Log entries that classify under this section
    local numEntries = C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, numEntries do
        local info = C_QuestLog.GetInfo and C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden and info.questID and info.questID > 0 then
            local sid = ClassifyQuest(info, info.questID)
            if sid == sectionID then
                UntrackQuest(info.questID)
            end
        end
    end
end

-- ─── Smart Sorting Comparator (Zero-Allocation) ───────────
local function QuestSortComparator(a, b)
    if not a or not b then return false end

    -- 1. Super-tracked quest always on top
    local aTrack = (a.questID == currentSuperTrackedID)
    local bTrack = (b.questID == currentSuperTrackedID)
    if aTrack ~= bTrack then return aTrack end

    -- 2. Completed quests on top (ready for turn-in)
    if a.isComplete ~= b.isComplete then
        return a.isComplete
    end

    -- 3. Failed quests placed at bottom
    if a.isFailed ~= b.isFailed then
        return not a.isFailed
    end

    -- 4. Alphabetical by quest title
    return (a.title or "") < (b.title or "")
end

-- ─────────────────────────────────────────────────────────
--  MAIN FRAME  (fixed top-right, transparent, no drag)
-- ─────────────────────────────────────────────────────────
QL = CreateFrame("Frame", "SfuiQuestLog", UIParent, "BackdropTemplate")
sfui.questlog.frame = QL
addon.questlog = QL

QL:Hide()
QL:SetSize(FRAME_W, 400)
QL:SetMovable(true)
QL:SetClampedToScreen(true)
QL:EnableMouse(true)
QL:SetFrameStrata("MEDIUM")
QL:SetFrameLevel(10)

-- Fully transparent outer backdrop
QL:SetBackdrop({ bgFile = [[Interface\ChatFrame\ChatFrameBackground]] })
QL:SetBackdropColor(0, 0, 0, 0)

-- ─── Position helpers ─────────────────────────────────────
-- Returns true if the quest log is currently unlocked for dragging.
local function QL_IsUnlocked()
    return SfuiDB.questlogUnlocked == true
end

-- Persist current anchor to SfuiDB.
local function QL_SavePosition()
    local _, _, _, x, y = QL:GetPoint()
    SfuiDB.questlogX  = x
    SfuiDB.questlogY  = y
    SfuiDB.mythicHudX = x
    SfuiDB.mythicHudY = y
    if SfuiMythicHUD then
        SfuiMythicHUD:ClearAllPoints()
        SfuiMythicHUD:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x, y)
    end
end

-- Restore saved position, or keep default TOPRIGHT anchor.
local function QL_RestorePosition()
    local posX = SfuiDB and (SfuiDB.questlogX or SfuiDB.mythicHudX)
    local posY = SfuiDB and (SfuiDB.questlogY or SfuiDB.mythicHudY)
    if posX and posY then
        QL:ClearAllPoints()
        QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)
    end
end
QL._RestorePosition = QL_RestorePosition

-- ─── Scrollbar ───────────────────────────────────────────
local scrollBar = CreateFrame("Slider", nil, QL, "BackdropTemplate")
scrollBar:SetOrientation("VERTICAL")
scrollBar:SetPoint("TOPRIGHT",    QL, "TOPRIGHT",    -1, 0)
scrollBar:SetPoint("BOTTOMRIGHT", QL, "BOTTOMRIGHT", -1, 1)
scrollBar:SetWidth(6)
scrollBar:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8x8]] })
scrollBar:SetBackdropColor(0, 0, 0, 0.15)
scrollBar:SetMinMaxValues(0, 0)
scrollBar:SetValue(0)
local sbThumb = scrollBar:CreateTexture(nil, "ARTWORK")
sbThumb:SetSize(3, 36)
sbThumb:SetColorTexture(102/255, 0/255, 255/255, 1.0)
scrollBar:SetThumbTexture(sbThumb)
QL.ScrollBar = scrollBar

-- ─── Scroll clip + content ───────────────────────────────
local scrollClip = CreateFrame("Frame", nil, QL)
scrollClip:SetPoint("TOPLEFT",     QL, "TOPLEFT",     0, 0)
scrollClip:SetPoint("BOTTOMRIGHT", QL, "BOTTOMRIGHT", -7, 0)
scrollClip:SetClipsChildren(true)
QL.ScrollClip = scrollClip

local content = CreateFrame("Frame", nil, scrollClip)
content:SetPoint("TOPLEFT", scrollClip, "TOPLEFT", 0, 0)
content:SetWidth(FRAME_W - 7)
content:SetHeight(100)
QL.Content = content

scrollClip:EnableMouseWheel(true)
scrollClip:SetScript("OnMouseWheel", function(_, delta)
    local cur    = scrollBar:GetValue()
    local lo, hi = scrollBar:GetMinMaxValues()
    scrollBar:SetValue(math_max(lo, math_min(hi, cur - delta * 20)))
end)
scrollBar:SetScript("OnValueChanged", function(_, val)
    content:SetPoint("TOPLEFT", scrollClip, "TOPLEFT", 0, val)
end)

-- ─── Section Headers (Lowercase, 50% transparent, colored text) ─
local sectionHdrs = {}
for _, def in ipairs(SECTION_DEFS) do
    local hdr = CreateFrame("Button", nil, content, "BackdropTemplate")
    hdr:SetHeight(SECT_H)
    hdr:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, 0)
    hdr:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    hdr:Hide()

    local mult = sfui.pixelScale or 1
    hdr:SetBackdrop({
        bgFile   = [[Interface\Buttons\WHITE8x8]],
        edgeFile = [[Interface\Buttons\WHITE8x8]],
        edgeSize = mult,
    })
    hdr:SetBackdropColor(0, 0, 0, 0.50)
    hdr:SetBackdropBorderColor(0, 0, 0, 0.50)

    -- Left color bar (3px)
    local accent = hdr:CreateTexture(nil, "ARTWORK")
    accent:SetWidth(3)
    accent:SetPoint("TOPLEFT",    hdr, "TOPLEFT",    0, 0)
    accent:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 0, 0)
    accent:SetColorTexture(def.color[1], def.color[2], def.color[3], 1)

    -- Label (lowercase, anchored directly from left)
    local lbl = hdr:CreateFontString(nil, "OVERLAY")
    lbl:SetFontObject("GameFontNormal")
    lbl:SetPoint("LEFT", hdr, "LEFT", PAD_X, 0)
    lbl:SetTextColor(def.color[1], def.color[2], def.color[3])
    lbl:SetText(def.label)

    -- Count badge
    local badge = hdr:CreateFontString(nil, "OVERLAY")
    badge:SetFontObject("GameFontHighlightSmall")
    badge:SetPoint("RIGHT", hdr, "RIGHT", -PAD_X, 0)
    badge:SetTextColor(def.color[1]*0.50, def.color[2]*0.50, def.color[3]*0.50)
    hdr.Badge = badge

    local defID = def.id
    local defLabel = def.label
    hdr:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    hdr:RegisterForDrag("LeftButton")

    hdr:SetScript("OnClick", function()
        local IsShiftKeyDown = _G.IsShiftKeyDown
        if IsShiftKeyDown and IsShiftKeyDown() then
            UntrackSectionQuests(defID)
            Refresh:Request()
            return
        end
        local state = GetQLState()
        state.collapsed[defID] = not state.collapsed[defID]
        Refresh:Request()
    end)

    -- Drag to reposition the whole QL frame when unlocked.
    hdr:SetScript("OnDragStart", function()
        if QL_IsUnlocked() then
            QL:StartMoving()
            SfuiQuestTooltip:Hide()
        end
    end)
    hdr:SetScript("OnDragStop", function()
        QL:StopMovingOrSizing()
        QL_SavePosition()
    end)

    hdr:SetScript("OnEnter", function(s)
        s:SetBackdropColor(0.08, 0.08, 0.08, 0.65)
        SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
        SfuiQuestTooltip:ClearLines()
        SfuiQuestTooltip:AddLine(defLabel, def.color[1], def.color[2], def.color[3])
        SfuiQuestTooltip:AddLine("|cff888888Left-click: Collapse/Expand section|r", 1, 1, 1)
        SfuiQuestTooltip:AddLine("|cff888888Shift-click: Untrack all quests in category|r", 1, 1, 1)
        if QL_IsUnlocked() then
            SfuiQuestTooltip:AddLine("|cff6600ffDrag: Move the tracker|r", 1, 1, 1)
        end
        SfuiQuestTooltip:Show()
    end)
    hdr:SetScript("OnLeave", function(s)
        s:SetBackdropColor(0, 0, 0, 0.50)
        SfuiQuestTooltip:Hide()
    end)

    sectionHdrs[def.id] = hdr
end

-- ─── Quest Row Factory (no background) ───────────────────
local function AcquireRow()
    local row = table.remove(rowPool)
    if not row then
        row = CreateFrame("Button", nil, content)
        row:SetHeight(QUEST_H)
        row:SetHitRectInsets(0, 0, -1, -1)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Hover-only tint (subtle)
        local hl = row:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0)
        row.HLTex = hl

        -- Supertrack dot (purple)
        local dot = row:CreateTexture(nil, "OVERLAY")
        dot:SetSize(4, 4)
        dot:SetPoint("LEFT", row, "LEFT", 2, 0)
        dot:SetColorTexture(0.55, 0.35, 1.0, 1)
        dot:Hide()
        row.Dot = dot

        -- Collapse arrow for quest objectives
        local toggleBtn = CreateFrame("Button", nil, row)
        toggleBtn:SetSize(12, QUEST_H)
        toggleBtn:SetPoint("LEFT", row, "LEFT", 6, 0)
        local arrowFS = toggleBtn:CreateFontString(nil, "OVERLAY")
        arrowFS:SetFontObject("GameFontHighlightSmall")
        arrowFS:SetPoint("CENTER", 0, 0)
        arrowFS:SetTextColor(0.55, 0.55, 0.55)
        toggleBtn.Arrow = arrowFS
        toggleBtn:SetScript("OnClick", function()
            local achID = row.achievementID
            if achID then
                local state = GetQLState()
                state.expandedQuests = state.expandedQuests or {}
                local key = "ach_" .. tostring(achID)
                state.expandedQuests[key] = not state.expandedQuests[key]
                Refresh:Request()
                return
            end

            local qID = row.questID
            if qID then
                local state = GetQLState()
                state.expandedQuests = state.expandedQuests or {}
                state.expandedQuests[qID] = not state.expandedQuests[qID]
                Refresh:Request()
            end
        end)
        toggleBtn:SetScript("OnEnter", function()
            arrowFS:SetTextColor(1, 1, 1)
        end)
        toggleBtn:SetScript("OnLeave", function()
            arrowFS:SetTextColor(0.55, 0.55, 0.55)
        end)
        row.ToggleBtn = toggleBtn

        -- Left indicator / complete text (outside window on the left of dropdown icon)
        local leftFS = row:CreateFontString(nil, "OVERLAY")
        leftFS:SetFontObject("GameFontHighlightSmall")
        leftFS:SetPoint("RIGHT", row, "LEFT", -6, 0)
        leftFS:SetJustifyH("RIGHT")
        leftFS:SetWordWrap(false)
        leftFS:Hide()
        row.LeftFS = leftFS

        -- Title
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject("GameFontHighlightSmall")
        fs:SetPoint("LEFT",  row, "LEFT",  PAD_X + 11, 0)
        fs:SetPoint("RIGHT", row, "RIGHT", -PAD_X,     0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        row.TitleFS = fs

        -- Find Group Eye Button (Right edge)
        local findGroupBtn
        local hasTemplate = (C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("QuestObjectiveFindGroupButtonTemplate")) ~= nil
        if hasTemplate then
            findGroupBtn = CreateFrame("Button", nil, row, "QuestObjectiveFindGroupButtonTemplate")
        end
        if not findGroupBtn then
            findGroupBtn = CreateFrame("Button", nil, row)
            local eyeIcon = findGroupBtn:CreateTexture(nil, "ARTWORK")
            eyeIcon:SetSize(14, 14)
            eyeIcon:SetPoint("CENTER", findGroupBtn, "CENTER", 0, 0)
            eyeIcon:SetAtlas("socialqueuing-icon-eye")
            eyeIcon:SetVertexColor(0.85, 0.85, 0.85, 0.85)
            findGroupBtn.EyeIcon = eyeIcon

            findGroupBtn:SetScript("OnClick", function(btn)
                if InCombat() then return end
                local qID = btn:GetAttribute("questID") or row.questID
                if qID and _G.LFGListUtil_FindQuestGroup then
                    C_Timer.After(0, function()
                        if not InCombat() and _G.LFGListUtil_FindQuestGroup and qID then
                            _G.LFGListUtil_FindQuestGroup(qID, true)
                        end
                    end)
                end
            end)
        else
            if findGroupBtn.Icon then
                findGroupBtn.Icon:SetSize(14, 14)
                findGroupBtn.Icon:ClearAllPoints()
                findGroupBtn.Icon:SetPoint("CENTER", findGroupBtn, "CENTER", 0, 0)
            end
            if findGroupBtn.GetNormalTexture and findGroupBtn:GetNormalTexture() then
                findGroupBtn:GetNormalTexture():SetAlpha(0)
            end
            if findGroupBtn.GetPushedTexture and findGroupBtn:GetPushedTexture() then
                findGroupBtn:GetPushedTexture():SetAlpha(0)
            end
            if findGroupBtn.GetHighlightTexture and findGroupBtn:GetHighlightTexture() then
                findGroupBtn:GetHighlightTexture():SetAlpha(0)
            end
        end

        findGroupBtn:SetSize(18, 18)
        findGroupBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        findGroupBtn:Hide()
        row.FindGroupBtn = findGroupBtn

        row:SetScript("OnEnter", function(s)
            s.HLTex:SetColorTexture(1, 1, 1, 0.10)
            if s.isAchievement and s.achievementID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()
                SfuiQuestTooltip:AddLine(s.questTitle or "Achievement", 0.95, 0.75, 0.3)
                if s.description and s.description ~= "" then
                    SfuiQuestTooltip:AddLine(s.description, 0.85, 0.85, 0.85, true)
                end
                if s.points and s.points > 0 then
                    SfuiQuestTooltip:AddLine(tostring(s.points) .. " Achievement Points", 0.3, 0.9, 0.4)
                end
                if s.objectives and #s.objectives > 0 then
                    SfuiQuestTooltip:AddLine(" ")
                    for _, obj in ipairs(s.objectives) do
                        if obj.text and obj.text ~= "" then
                            local r, g, b = 0.75, 0.75, 0.75
                            if obj.finished then r, g, b = 0.30, 0.80, 0.30 end
                            SfuiQuestTooltip:AddLine("  - " .. obj.text, r, g, b, true)
                        end
                    end
                end
                SfuiQuestTooltip:AddLine(" ")
                SfuiQuestTooltip:AddLine("|cff888888Left-click: Open Achievement Panel|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Right-click / Arrow: Collapse/Expand criteria|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Shift-click: Untrack Achievement|r", 1, 1, 1)
                SfuiQuestTooltip:Show()
                return
            end

            if s.questID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()

                if s.isScenario or s.questID == -1 then
                    SfuiQuestTooltip:AddLine(s.questTitle or "World Event", 1.00, 0.60, 0.10)
                    SfuiQuestTooltip:AddLine("Active World Event / Scenario", 0.85, 0.85, 0.85)
                    SfuiQuestTooltip:AddLine(" ")
                    SfuiQuestTooltip:AddLine("|cff888888Right-click / Arrow: Collapse/Expand objectives|r", 1, 1, 1)
                    SfuiQuestTooltip:Show()
                    return
                end

                SfuiQuestTooltip:AddLine(s.questTitle or "Quest", 1, 1, 1)

                if s.timeLeftText then
                    SfuiQuestTooltip:AddLine(s.timeLeftText, 0.20, 0.85, 0.95)
                end

                if s.isWarbandCompleted then
                    SfuiQuestTooltip:AddLine("Warband Completed", 0.65, 0.25, 0.25)
                end

                if C_QuestLog.GetQuestObjectives then
                    local objs = C_QuestLog.GetQuestObjectives(s.questID)
                    if objs and #objs > 0 then
                        SfuiQuestTooltip:AddLine(" ")
                        for _, obj in ipairs(objs) do
                            if obj.text and obj.text ~= "" then
                                local r, g, b = 0.75, 0.75, 0.75
                                if obj.finished then r, g, b = 0.30, 0.80, 0.30 end
                                SfuiQuestTooltip:AddLine("  - " .. obj.text, r, g, b, true)
                            end
                        end
                    end
                end
                SfuiQuestTooltip:AddLine(" ")
                SfuiQuestTooltip:AddLine("|cff888888Left-click: Track & Show on Map|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Right-click / Arrow: Collapse/Expand objectives|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Shift-click: Link Quest to Chat / Untrack|r", 1, 1, 1)
                if s.canFindGroup then
                    SfuiQuestTooltip:AddLine("|cff00ff88Eye Button: Find Group in Group Finder|r", 1, 1, 1)
                end
                if not s.isWorldQuest then
                    SfuiQuestTooltip:AddLine("|cff888888Alt-click: Share Quest with Party|r", 1, 1, 1)
                    SfuiQuestTooltip:AddLine("|cff888888Ctrl-Right-click: Abandon Quest|r", 1, 1, 1)
                end
                SfuiQuestTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(s)
            s.HLTex:SetColorTexture(1, 1, 1, 0)
            SfuiQuestTooltip:Hide()
        end)
        row:SetScript("OnClick", function(s, btn)
            if s.isAchievement and s.achievementID then
                local IsShiftKeyDown = _G.IsShiftKeyDown
                if IsShiftKeyDown and IsShiftKeyDown() then
                    local ChatEdit_GetActiveWindow = _G.ChatEdit_GetActiveWindow
                    local ChatEdit_InsertLink = _G.ChatEdit_InsertLink
                    local activeChat = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                    if activeChat and activeChat:IsShown() and activeChat:HasFocus() then
                        if _G.GetAchievementLink and ChatEdit_InsertLink then
                            local link = _G.GetAchievementLink(s.achievementID)
                            if link and ChatEdit_InsertLink(link) then return end
                        end
                    end

                    UntrackAchievement(s.achievementID)
                    Refresh:Request()
                    return
                end

                if btn == "RightButton" then
                    local state = GetQLState()
                    state.expandedQuests = state.expandedQuests or {}
                    local key = "ach_" .. tostring(s.achievementID)
                    state.expandedQuests[key] = not state.expandedQuests[key]
                    Refresh:Request()
                    return
                end

                if not InCombat() then
                    if _G.OpenAchievementFrameToAchievement then
                        _G.OpenAchievementFrameToAchievement(s.achievementID)
                    elseif _G.ToggleAchievementFrame then
                        _G.ToggleAchievementFrame()
                    end
                end
                return
            end

            if not s.questID then return end

            if s.isScenario or s.questID == -1 then
                if btn == "RightButton" then
                    local state = GetQLState()
                    state.expandedQuests = state.expandedQuests or {}
                    local k = s.questID or -1
                    state.expandedQuests[k] = not state.expandedQuests[k]
                    Refresh:Request()
                elseif _G.ToggleWorldMap then
                    if not InCombat() then
                        C_Timer.After(0, function()
                            if not InCombat() and _G.ToggleWorldMap then
                                _G.ToggleWorldMap()
                            end
                        end)
                    end
                end
                return
            end

            -- 1. Ctrl-Click / Ctrl-Right-Click: Abandon Quest (standard quests only)
            local IsControlKeyDown = _G.IsControlKeyDown
            if IsControlKeyDown and IsControlKeyDown() and not s.isWorldQuest then
                if InCombat() then return end
                if C_QuestLog.CanAbandonQuest and C_QuestLog.CanAbandonQuest(s.questID) then
                    if C_QuestLog.SetSelectedQuest then
                        C_QuestLog.SetSelectedQuest(s.questID)
                    end
                    if C_QuestLog.SetAbandonQuest then
                        C_QuestLog.SetAbandonQuest()
                    end
                    if _G.QuestMapQuestOptions_AbandonQuest then
                        _G.QuestMapQuestOptions_AbandonQuest(s.questID)
                        return
                    end

                    local title = s.questTitle or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(s.questID)) or "Quest"
                    local items = (C_QuestLog.GetAbandonQuestItems and C_QuestLog.GetAbandonQuestItems()) or nil
                    if items and _G.StaticPopup_Show then
                        _G.StaticPopup_Show("ABANDON_QUEST_WITH_ITEMS", title, items)
                    elseif _G.StaticPopup_Show then
                        _G.StaticPopup_Show("ABANDON_QUEST", title)
                    elseif C_QuestLog.AbandonQuest then
                        C_QuestLog.AbandonQuest()
                    end
                else
                    print("|cff8888ff[SFUI]|r Quest cannot be abandoned.")
                end
                return
            end

            -- 2. Alt-Click: Share Quest with Party (standard quests only)
            local IsAltKeyDown = _G.IsAltKeyDown
            if IsAltKeyDown and IsAltKeyDown() and not s.isWorldQuest then
                if InCombat() then return end
                if C_QuestLog.IsPushableQuest and C_QuestLog.IsPushableQuest(s.questID) then
                    C_QuestLog.PushQuestToParty(s.questID)
                    print("|cff8888ff[SFUI]|r Shared quest: " .. (s.questTitle or "Quest"))
                else
                    print("|cff8888ff[SFUI]|r Quest cannot be shared.")
                end
                return
            end

            -- 3. Shift-Click: Untrack / Hide quest (or insert link if chat editbox has focus)
            local IsShiftKeyDown = _G.IsShiftKeyDown
            if IsShiftKeyDown and IsShiftKeyDown() then
                local ChatEdit_GetActiveWindow = _G.ChatEdit_GetActiveWindow
                local ChatEdit_InsertLink = _G.ChatEdit_InsertLink
                local ChatFrameUtil = _G.ChatFrameUtil
                local activeChat = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                if activeChat and activeChat:IsShown() and activeChat:HasFocus() then
                    if ChatFrameUtil and ChatFrameUtil.TryInsertQuestLinkForQuestID and ChatFrameUtil.TryInsertQuestLinkForQuestID(s.questID) then
                        return
                    end
                    if _G.GetQuestLink and ChatEdit_InsertLink then
                        local link = _G.GetQuestLink(s.questID)
                        if link and ChatEdit_InsertLink(link) then return end
                    end
                end

                UntrackQuest(s.questID)
                Refresh:Request()
                return
            end

            -- 4. Plain Right-Click: Toggle collapse/expand of objectives
            if btn == "RightButton" then
                local state = GetQLState()
                state.expandedQuests = state.expandedQuests or {}
                state.expandedQuests[s.questID] = not state.expandedQuests[s.questID]
                Refresh:Request()
                return
            end

            -- Default Left-Click:
            if InCombat() then
                return
            end

            -- 1. Check for Autocomplete / Remote Turn-in (e.g. Delves, breadcrumbs, auto-quests)
            local isAutoComplete = s.isAutoComplete
            if isAutoComplete == nil and _G.QuestCache and _G.QuestCache.Get then
                local qObj = _G.QuestCache:Get(s.questID)
                if qObj then isAutoComplete = qObj.isAutoComplete end
            end

            local isComplete = s.isComplete
            if isComplete == nil and C_QuestLog.IsComplete then
                isComplete = C_QuestLog.IsComplete(s.questID)
            end

            local popUpType = nil
            if C_QuestLog.GetAutoQuestPopUpType then
                popUpType = C_QuestLog.GetAutoQuestPopUpType(s.questID)
            end

            if popUpType == "OFFER" and _G.ShowQuestOffer then
                _G.ShowQuestOffer(s.questID)
                return
            elseif (popUpType == "COMPLETE" or (isAutoComplete and isComplete)) and _G.ShowQuestComplete then
                _G.ShowQuestComplete(s.questID)
                return
            end

            -- 2. Standard Quest: Open in Map & Quest Log details + SuperTrack
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
                C_SuperTrack.SetSuperTrackedQuestID(s.questID)
            end

            if InCombatLockdown and InCombatLockdown() then return end

            if s.isWorldQuest then
                if C_TaskQuest and C_TaskQuest.GetQuestZoneID and C_Map and C_Map.OpenWorldMap then
                    local zoneMapID = C_TaskQuest.GetQuestZoneID(s.questID)
                    if zoneMapID and zoneMapID ~= 0 then
                        C_Timer.After(0, function()
                            if not InCombatLockdown or not InCombatLockdown() then
                                C_Map.OpenWorldMap(zoneMapID)
                            end
                        end)
                        return
                    end
                end
            end

            local targetQuestID = s.questID
            C_Timer.After(0, function()
                if InCombatLockdown and InCombatLockdown() then return end
                if C_QuestLog and C_QuestLog.SetSelectedQuest and targetQuestID then
                    C_QuestLog.SetSelectedQuest(targetQuestID)
                end
                if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID and targetQuestID then
                    C_SuperTrack.SetSuperTrackedQuestID(targetQuestID)
                end

                if QuestMapFrame_OpenToQuestDetails and targetQuestID then
                    QuestMapFrame_OpenToQuestDetails(targetQuestID)
                elseif _G.OpenWorldMap then
                    _G.OpenWorldMap()
                end
            end)
            Refresh:Request()
        end)
    end
    row:Show()
    table.insert(activeRows, row)
    return row
end

-- ─── Objective Row Factory ───────────────────────────────
local function AcquireObjRow()
    local obj = table.remove(objPool)
    if not obj then
        obj = CreateFrame("Frame", nil, content)
        obj:SetHeight(OBJ_H)
        obj:EnableMouse(false)

        -- Text objective FontString (top)
        local fs = obj:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject("GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT",  obj, "TOPLEFT",  2,      0)
        fs:SetPoint("TOPRIGHT", obj, "TOPRIGHT", -PAD_X, 0)
        fs:SetHeight(OBJ_H)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        obj.FS = fs

        -- Sleek borderless flat progress bar (positioned underneath objective text)
        local bar = CreateFrame("StatusBar", nil, obj, "BackdropTemplate")
        bar:EnableMouse(false)
        bar:SetPoint("TOPLEFT",     fs,  "BOTTOMLEFT",  0, -2)
        bar:SetPoint("BOTTOMRIGHT", obj, "BOTTOMRIGHT", -PAD_X, 0)
        bar:SetStatusBarTexture([[Interface\Buttons\WHITE8x8]])
        bar:SetMinMaxValues(0, 100)

        bar:SetBackdrop({
            bgFile = [[Interface\Buttons\WHITE8x8]],
        })
        bar:SetBackdropColor(0, 0, 0, 0.45)

        local barCenterFS = bar:CreateFontString(nil, "OVERLAY")
        barCenterFS:SetFontObject("GameFontHighlightSmall")
        barCenterFS:SetPoint("CENTER", bar, "CENTER", 0, 0)
        barCenterFS:SetJustifyH("CENTER")
        barCenterFS:SetWordWrap(false)
        bar.CenterFS = barCenterFS

        bar:Hide()
        obj.Bar = bar
    end
    obj:Show()
    table.insert(activeObjs, obj)
    return obj
end

local function ClearRows()
    for i = #activeRows, 1, -1 do
        local r = table.remove(activeRows, i)
        r:Hide()
        table.insert(rowPool, r)
    end
    for i = #activeObjs, 1, -1 do
        local r = table.remove(activeObjs, i)
        r:Hide()
        table.insert(objPool, r)
    end
end

-- ─── Panel Anchor ────────────────────────────────────────
-- Respects saved drag position so the frame isn't silently reset after
-- combat ends or CheckVisibilityAndRefresh() calls this function.
UpdateQuestLogAnchor = function()
    if not QL then return 758 end
    if InCombat() or State:IsActive() then return QL.lastTop or 758 end

    local parentTop = (UIParent and UIParent:GetTop()) or 768
    QL:ClearAllPoints()
    local posX = SfuiDB and (SfuiDB.questlogX or SfuiDB.mythicHudX)
    local posY = SfuiDB and (SfuiDB.questlogY or SfuiDB.mythicHudY)
    if posX and posY then
        QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)
    else
        QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
    end
    local qlTop = parentTop - 10
    QL.lastTop = qlTop
    return qlTop
end
sfui.questlog.UpdateAnchor = UpdateQuestLogAnchor

-- ─── Instant SuperTrack Sync (Zero-Redraw) ───────────────
-- FIX #3: Removed QL:Refresh() — the dot loop already updates all rows
-- in-place with zero allocation. Scheduling a full rebuild via Refresh()
-- was wasteful and caused unnecessary ClearRows() + row recreation.
local function SyncSuperTrackIndicator()
    local superTracked = (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and
                          C_SuperTrack.GetSuperTrackedQuestID()) or 0
    currentSuperTrackedID = superTracked
    for _, row in ipairs(activeRows) do
        if row:IsShown() and row.questID then
            if row.questID == superTracked then
                row.Dot:Show()
            else
                row.Dot:Hide()
            end
        end
    end
    -- No QL:Refresh() here — dot sync is already zero-redraw
end

-- ─────────────────────────────────────────────────────────
--  PROCESS QUEST HELPER (Zero-Allocation Hashing)
-- ─────────────────────────────────────────────────────────
local function BuildQuestEntry(questID, forcedSectionID, defaultInfo)
    local isComplete, isFailed = false, false
    if C_QuestLog.IsComplete then
        isComplete = C_QuestLog.IsComplete(questID) or false
    end
    if C_QuestLog.IsFailed then
        isFailed = C_QuestLog.IsFailed(questID) or false
    end

    local objs = nil
    if C_QuestLog.GetQuestObjectives then
        local v = C_QuestLog.GetQuestObjectives(questID)
        if v and #v > 0 then objs = v end
    end

    local isSynthetic = false
    local qProgressBarPct = nil
    if C_TaskQuest and C_TaskQuest.GetQuestProgressBarInfo then
        local val = C_TaskQuest.GetQuestProgressBarInfo(questID)
        if val and val > 0 then qProgressBarPct = val end
    end
    if not qProgressBarPct and _G.GetQuestProgressBarInfo then
        local val = _G.GetQuestProgressBarInfo(questID)
        if val and val > 0 then qProgressBarPct = val end
    end

    if not objs or #objs == 0 then
        if qProgressBarPct and qProgressBarPct > 0 then
            local sObj = AcquireTable()
            sObj.text = tostring(qProgressBarPct) .. "%"
            sObj.barText = tostring(qProgressBarPct) .. "%"
            sObj.finished = (qProgressBarPct >= 100)
            sObj.numFulfilled = qProgressBarPct
            sObj.numRequired = 100
            sObj.type = "progressbar"
            local sList = AcquireTable()
            table.insert(sList, sObj)
            objs = sList
            isSynthetic = true
        end
    elseif objs then
        for _, obj in ipairs(objs) do
            local hasPctText = obj.text and not issecretvalue(obj.text) and obj.text:find("%%")
            local isBarType = (obj.type == "progressbar" or obj.type == 8 or qProgressBarPct ~= nil or hasPctText or (obj.numRequired and not issecretvalue(obj.numRequired) and obj.numRequired == 100))

            if isBarType then
                obj.type = "progressbar"
                if not obj.numFulfilled or obj.numFulfilled == 0 then
                    if qProgressBarPct then
                        obj.numFulfilled = qProgressBarPct
                    elseif hasPctText then
                        local p = obj.text:match("(%d+)%%")
                        if p then obj.numFulfilled = tonumber(p) end
                    end
                end
                if not obj.numRequired or obj.numRequired <= 1 then
                    obj.numRequired = 100
                end
                if not obj.barText or obj.barText == "" then
                    if obj.numFulfilled and not issecretvalue(obj.numFulfilled) then
                        obj.barText = tostring(obj.numFulfilled) .. "%"
                    end
                end
            end
        end
    end

    local done, total = 0, 0
    local singleCountStr = nil
    local progressHash = (isComplete and "1" or "0")

    if objs and #objs == 1 then
        local obj = objs[1]
        total = 1
        if obj.finished then done = 1 end

        local cur = obj.numFulfilled or 0
        local req = obj.numRequired or 0
        local curStr = issecretvalue(cur) and "S" or tostring(cur)
        local reqStr = issecretvalue(req) and "S" or tostring(req)
        progressHash = progressHash .. "_" .. curStr .. "/" .. reqStr .. (obj.finished and "D" or "U")

        if not issecretvalue(cur) and not issecretvalue(req) and req > 1 then
            singleCountStr = tostring(cur) .. "/" .. tostring(req)
        elseif obj.text and obj.text ~= "" and not issecretvalue(obj.text) then
            local pCur, pReq = obj.text:match("(%d+)/(%d+)")
            if pCur and pReq and tonumber(pReq) and tonumber(pReq) > 1 then
                singleCountStr = pCur .. "/" .. pReq
            else
                local pct = obj.text:match("(%d+)%%")
                if pct then
                    singleCountStr = pct .. "%"
                end
            end
        end
    elseif objs and #objs > 1 then
        for idx, obj in ipairs(objs) do
            total = total + 1
            if obj.finished then done = done + 1 end
            local cur = obj.numFulfilled or 0
            local req = obj.numRequired or 0
            local curStr = issecretvalue(cur) and "S" or tostring(cur)
            local reqStr = issecretvalue(req) and "S" or tostring(req)
            progressHash = progressHash .. "_" .. tostring(idx) .. ":" .. curStr .. "/" .. reqStr .. (obj.finished and "D" or "U")
        end
    end

    -- Fast numeric change detection
    if questProgressCache[questID] and questProgressCache[questID] ~= progressHash then
        local state = GetQLState()
        state.expandedQuests = state.expandedQuests or {}
        if not isComplete then
            state.expandedQuests[questID] = true
        else
            state.expandedQuests[questID] = false
        end

        if state.hiddenQuests and isComplete then
            state.hiddenQuests[questID] = nil
        end
        if forcedSectionID and state.collapsed then
            state.collapsed[forcedSectionID] = false
        end
    end
    questProgressCache[questID] = progressHash

    local title = defaultInfo and defaultInfo.title
    if not title or title == "" then
        if C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID then
            local t = C_TaskQuest.GetQuestInfoByQuestID(questID)
            if t and t ~= "" then title = t end
        end
        if (not title or title == "") and C_QuestLog.GetTitleForQuestID then
            local t = C_QuestLog.GetTitleForQuestID(questID)
            if t and t ~= "" then title = t end
        end
        if (not title or title == "") and _G.QuestUtils_GetQuestName then
            local t = _G.QuestUtils_GetQuestName(questID)
            if t and t ~= "" then title = t end
        end
    end
    title = title or "Unknown Quest"

    local timeLeftText = nil
    local isWorld = (forcedSectionID == "world" or IsWorldQuest(questID))

    if isWorld then
        if C_TaskQuest and C_TaskQuest.GetQuestTimeLeftMinutes then
            local mins = C_TaskQuest.GetQuestTimeLeftMinutes(questID)
            if mins and mins > 0 then
                if mins >= 1440 then
                    local d = math_floor(mins / 1440)
                    local h = math_floor((mins % 1440) / 60)
                    if h > 0 then
                        timeLeftText = string_format("%dd %dh", d, h)
                    else
                        timeLeftText = string_format("%dd", d)
                    end
                elseif mins >= 60 then
                    local h = math_floor(mins / 60)
                    local m = mins % 60
                    if m > 0 then
                        timeLeftText = string_format("%dh %dm", h, m)
                    else
                        timeLeftText = string_format("%dh", h)
                    end
                else
                    timeLeftText = string_format("%dm", mins)
                end
            end
        end
    end

    local isAutoComplete = defaultInfo and defaultInfo.isAutoComplete
    if isAutoComplete == nil and C_QuestLog.GetInfo then
        local lIndex = logIndex or (C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID))
        if lIndex then
            local info = C_QuestLog.GetInfo(lIndex)
            if info then isAutoComplete = info.isAutoComplete end
        end
    end
    if isAutoComplete == nil and _G.QuestCache and _G.QuestCache.Get then
        local qObj = _G.QuestCache:Get(questID)
        if qObj then isAutoComplete = qObj.isAutoComplete end
    end

    local isWarbandCompleted = IsQuestWarbandCompleted(questID)
    local isMeta = IsMetaQuest(questID, defaultInfo)
    local canFindGroup = (defaultInfo and defaultInfo.suggestedGroup and defaultInfo.suggestedGroup > 1) or false

    local isAutoTurnIn = (isAutoComplete and isComplete)
    if not isAutoTurnIn and C_QuestLog.GetAutoQuestPopUpType then
        local pt = C_QuestLog.GetAutoQuestPopUpType(questID)
        if pt == "COMPLETE" then isAutoTurnIn = true end
    end

    local entry = AcquireTable()
    entry.questID            = questID
    entry.questLogIndex      = logIndex
    entry.title              = title
    entry.isComplete         = isComplete
    entry.isFailed           = isFailed
    entry.isAutoComplete     = isAutoComplete
    entry.isAutoTurnIn       = isAutoTurnIn
    entry.isWarbandCompleted = isWarbandCompleted
    entry.isMeta             = isMeta
    entry.canFindGroup       = canFindGroup
    entry.objectives         = objs
    entry._syntheticObjs     = isSynthetic
    entry.done               = done
    entry.total              = total
    entry.singleCountStr     = singleCountStr
    entry.isWorldQuest       = isWorld
    entry.timeLeftText       = timeLeftText
    entry.isScenario         = false
    return entry

end

-- Helper: check if a quest has any active progress
local function QuestHasProgress(entry)
    if not entry then return false end
    if entry.isComplete then return true end
    if entry.done and entry.done > 0 then return true end
    if entry.singleCountStr then
        local cur = entry.singleCountStr:match("(%d+)/%d+") or entry.singleCountStr:match("(%d+)%%")
        if cur and tonumber(cur) and tonumber(cur) > 0 then return true end
    end
    if entry.objectives then
        for _, obj in ipairs(entry.objectives) do
            if obj.finished then return true end
            if obj.numFulfilled and obj.numFulfilled > 0 then return true end
            if obj.text then
                local cur = obj.text:match("(%d+)/%d+") or obj.text:match("(%d+)%%")
                if cur and tonumber(cur) and tonumber(cur) > 0 then return true end
            end
        end
    end
    return false
end

-- Helper: add a world quest/task to the world section (only if tracked or has progress, respecting hidden state)
local function AddWorldQuest(qID, isExplicitlyWatched)
    if qID and qID > 0 and not processedQuests[qID] then
        local state = GetQLState()
        local isSuperTracked = (currentSuperTrackedID and currentSuperTrackedID == qID)

        -- Explicit manual watching or supertracking unhides the quest
        if isExplicitlyWatched or isSuperTracked then
            if state.hiddenQuests then state.hiddenQuests[qID] = nil end
        end

        -- If explicitly hidden and not watched/supertracked, skip it
        if state.hiddenQuests and state.hiddenQuests[qID] then
            return
        end

        local entry = BuildQuestEntry(qID, "world", nil)
        if entry then
            local isWatched = isExplicitlyWatched or isSuperTracked
            if isWatched or QuestHasProgress(entry) then
                processedQuests[qID] = true
                table.insert(sectionLists["world"], entry)
            else
                ReleaseTable(entry)
            end
        end
    end
end

local function GetScenarioCriteriaSafe(criteriaIndex, stepID)
    -- 1. Query active scenario step criteria first (always current for active stage)
    if C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo then
        local info = C_ScenarioInfo.GetCriteriaInfo(criteriaIndex)
        if info and type(info) == "table" and (info.description or info.criteriaString or info.string) then
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

    -- 2. Fallback to step-specific criteria if stepID / stepIndex provided (used for bonus steps)
    if stepID and C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfoByStep then
        local info = C_ScenarioInfo.GetCriteriaInfoByStep(stepID, criteriaIndex)
        if info and type(info) == "table" and (info.description or info.criteriaString or info.string) then
            info.description = info.description or info.criteriaString or info.string
            return info
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

local function FormatTimerSeconds(sec)
    if not sec or sec <= 0 then return nil end
    sec = math_floor(sec)
    if sec >= 3600 then
        local h = math_floor(sec / 3600)
        local m = math_floor((sec % 3600) / 60)
        local s = sec % 60
        return string_format("%d:%02d:%02d", h, m, s)
    else
        local m = math_floor(sec / 60)
        local s = sec % 60
        return string_format("%d:%02d", m, s)
    end
end

local staticScannedWidgets = {}
local staticWidgetIDList   = {}

local function AddWidgetIDToScan(wID)
    if wID and type(wID) == "number" and wID > 0 and not staticScannedWidgets[wID] then
        staticScannedWidgets[wID] = true
        staticWidgetIDList[#staticWidgetIDList + 1] = wID
    end
end

local function CollectWidgetsFromSet(setID)
    if not setID or setID <= 0 or not C_UIWidgetManager or not C_UIWidgetManager.GetAllWidgetsBySetID then return end
    local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setID)
    if widgets and type(widgets) == "table" then
        for _, w in ipairs(widgets) do
            local wID = (type(w) == "table" and w.widgetID) or (type(w) == "number" and w)
            if wID then AddWidgetIDToScan(wID) end
        end
    end
end

local function ScanWorldEventScenario(list)
    -- mythic.lua owns dungeons, delves, mythic+, and instance scenarios.
    -- quests.lua strictly only tracks outdoor world events (e.g. Dundun, Community Feast, Time Rifts, etc.)
    if sfui.mythic and sfui.mythic.IsActive and sfui.mythic.IsActive() then return end

    local inInst, instType = false, "none"
    if _G.IsInInstance then
        local resInst, resType = _G.IsInInstance()
        if resInst ~= nil then inInst, instType = resInst, resType end
    end
    if inInst and instType ~= "none" then return end

    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then return end
    if C_DelvesUI and C_DelvesUI.HasActiveDelve and C_DelvesUI.HasActiveDelve() then return end

    local C_Sc = _G.C_Scenario
    if not C_Sc or not C_Sc.IsInScenario or not C_Sc.IsInScenario() then return end

    local name, currentStage, numStages, flags, isComplete, _, _, scenarioType = C_Sc.GetInfo()
    if not name or name == "" or isComplete then return end

    -- Filter out Delves (8), Dungeons (1), Raids (2), Challenge Mode (5), or instance-flagged scenarios
    if scenarioType == 8 or scenarioType == 1 or scenarioType == 2 or scenarioType == 5 then return end
    if flags and bit and bit.band and bit.band(flags, 0x01) ~= 0 and inInst then return end

    local stepInfo = nil
    if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
        local sInfo = C_ScenarioInfo.GetScenarioStepInfo()
        if sInfo and type(sInfo) == "table" then
            stepInfo = sInfo
        end
    end

    local stageName = (stepInfo and (stepInfo.name or stepInfo.title or stepInfo.stageName))
    local stageDescription = (stepInfo and stepInfo.description)
    local numCriteria = (stepInfo and stepInfo.numCriteria)
    local weightedProgress = (stepInfo and stepInfo.weightedProgress)
    local widgetSetID = (stepInfo and stepInfo.widgetSetID)

    if not stepInfo and C_Sc.GetStepInfo then
        local sName, sDesc, nCrit, _, _, _, _, _, _, wProg, _, wSetID = C_Sc.GetStepInfo()
        stageName = stageName or sName
        stageDescription = stageDescription or sDesc
        numCriteria = numCriteria or nCrit
        if weightedProgress == nil then weightedProgress = wProg end
        widgetSetID = widgetSetID or wSetID
    end

    local title
    if numStages and numStages > 1 and currentStage and currentStage > 0 then
        title = string_format("%s (Stage %d/%d)", stageName or name, currentStage, numStages)
    else
        title = stageName or name
    end

    local objs = AcquireTable()
    local done, total = 0, 0
    local scTimeLeft = nil

    -- 1. Criteria scan
    if numCriteria and numCriteria > 0 then
        for i = 1, numCriteria do
            local info = GetScenarioCriteriaSafe(i, stepInfo and stepInfo.stepID)
            local desc = info and (info.description or info.criteriaString or info.string)
            if desc and desc ~= "" and not issecretvalue(desc) then
                local sObj = AcquireTable()
                local isComp = info.completed == true
                sObj.finished = isComp
                if isComp then done = done + 1 end
                total = total + 1

                local timeTag = nil
                if info.duration and info.duration > 0 then
                    local rem = math_max(0, info.duration - (info.elapsed or 0))
                    if rem > 0 then
                        local tStr = FormatTimerSeconds(rem)
                        if tStr then
                            timeTag = "[" .. tStr .. "]"
                            if not scTimeLeft then scTimeLeft = tStr end
                        end
                    end
                end

                -- Fallback quantity extraction if Blizzard didn't populate raw numeric fields
                if (not info.quantity or info.quantity == 0) and info.quantityString and not issecretvalue(info.quantityString) then
                    local q, t = info.quantityString:match("(%d+)%s*/%s*(%d+)")
                    if q and t then
                        info.quantity = tonumber(q)
                        info.totalQuantity = tonumber(t)
                    else
                        local p = info.quantityString:match("(%d+)%%")
                        if p then
                            info.quantity = tonumber(p)
                            info.totalQuantity = 100
                            info.isWeightedProgress = true
                        end
                    end
                end
                if (not info.quantity or info.quantity == 0) and desc and not issecretvalue(desc) then
                    local q, t = desc:match("%((%d+)%s*/%s*(%d+)%)")
                    if q and t then
                        info.quantity = tonumber(q)
                        info.totalQuantity = tonumber(t)
                    else
                        local p = desc:match("%((%d+)%%%)")
                        if p then
                            info.quantity = tonumber(p)
                            info.totalQuantity = 100
                            info.isWeightedProgress = true
                        end
                    end
                end

                local isWeighted = info.isWeightedProgress
                    or info.weightedProgress
                    or (info.criteriaType == 8)
                    or (weightedProgress == true)
                    or (info.totalQuantity == 100)
                    or (info.totalQuantity == 1000)
                    or (info.quantityString and not issecretvalue(info.quantityString) and info.quantityString:find("%%"))
                    or (desc and not issecretvalue(desc) and desc:find("%%"))

                if isWeighted then
                    local cleanDesc = desc
                    if not issecretvalue(desc) then
                        cleanDesc = desc:gsub("%s*%(?%d+%%%)?", ""):gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                    end
                    sObj.text = timeTag and (cleanDesc .. " " .. timeTag) or cleanDesc
                    sObj.type = "progressbar"
                    sObj.numFulfilled = info.quantity or 0
                    sObj.numRequired = 100
                    sObj.barText = (info.quantityString and not issecretvalue(info.quantityString) and info.quantityString)
                                or (not issecretvalue(info.quantity) and (tostring(info.quantity) .. "%"))
                                or nil
                    sObj.finished = isComp
                elseif info.quantity and info.totalQuantity and not issecretvalue(info.totalQuantity) and info.totalQuantity > 1 then
                    local cleanDesc = desc
                    if not issecretvalue(desc) then
                        cleanDesc = desc:gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                    end
                    local baseText = cleanDesc
                    if not issecretvalue(info.quantity) then
                        baseText = string_format("%s (%s/%s)", cleanDesc, tostring(info.quantity), tostring(info.totalQuantity))
                    end
                    sObj.text = timeTag and (baseText .. " " .. timeTag) or baseText
                    sObj.numFulfilled = info.quantity
                    sObj.numRequired = info.totalQuantity
                    sObj.finished = isComp
                else
                    sObj.text = timeTag and (desc .. " " .. timeTag) or desc
                    sObj.finished = isComp
                end
                table.insert(objs, sObj)
            end
        end
    end

    -- 2. Scenario & World Event Widgets Scan (Timers, Progress / Abundance Bars, Captures)
    wipe(staticScannedWidgets)
    wipe(staticWidgetIDList)

    if widgetSetID and widgetSetID > 0 then
        CollectWidgetsFromSet(widgetSetID)
    end

    if C_UIWidgetManager then
        if C_UIWidgetManager.GetTopCenterWidgetSetID then
            local sID = C_UIWidgetManager.GetTopCenterWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
        if C_UIWidgetManager.GetBelowMinimapWidgetSetID then
            local sID = C_UIWidgetManager.GetBelowMinimapWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
        if C_UIWidgetManager.GetObjectiveTrackerWidgetSetID then
            local sID = C_UIWidgetManager.GetObjectiveTrackerWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
        if C_UIWidgetManager.GetPowerBarWidgetSetID then
            local sID = C_UIWidgetManager.GetPowerBarWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
    end

    for _, wID in ipairs(staticWidgetIDList) do
        -- A. ScenarioHeaderTimer
        if C_UIWidgetManager and C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo then
            local tInfo = C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo(wID)
            if tInfo and tInfo.shownState ~= 0 and tInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local tMin = tInfo.timerMin or 0
                local tMax = tInfo.timerMax or 0
                local tVal = tInfo.timerValue or 0
                local rem = 0
                if tMax > tMin and tVal >= tMin then
                    rem = math_max(0, tVal - tMin)
                elseif tVal > 0 then
                    rem = tVal
                end
                local tStr = FormatTimerSeconds(rem)
                if tStr then
                    if not scTimeLeft then scTimeLeft = tStr end
                    local lbl = (tInfo.headerText and tInfo.headerText ~= "" and not issecretvalue(tInfo.headerText) and tInfo.headerText)
                             or (tInfo.timerTooltip and tInfo.timerTooltip ~= "" and not issecretvalue(tInfo.timerTooltip) and tInfo.timerTooltip:match("^[^\n]+"))
                             or "Time Remaining"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s: %s", lbl, tStr)
                    sObj.finished = (rem <= 0)
                    table.insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- B. StatusBar (Abundance, Event Progress, Delve Progress)
        if C_UIWidgetManager and C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
            local sInfo = C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo(wID)
            if sInfo and sInfo.shownState ~= 0 and sInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local minVal = sInfo.barMin or 0
                local maxVal = sInfo.barMax or 0
                local curVal = sInfo.barValue or 0
                local range = maxVal - minVal
                if range > 0 or curVal > 0 then
                    local pct = (range > 0) and math_min(100, math_max(0, math_floor(((curVal - minVal) / range) * 100))) or 0
                    
                    local valText = nil
                    if sInfo.overrideBarText and sInfo.overrideBarText ~= "" and not issecretvalue(sInfo.overrideBarText) then
                        valText = sInfo.overrideBarText
                    elseif sInfo.barValueText and sInfo.barValueText ~= "" and not issecretvalue(sInfo.barValueText) then
                        valText = sInfo.barValueText
                    elseif maxVal > 0 then
                        valText = string_format("%d/%d", curVal, maxVal)
                    else
                        valText = tostring(curVal)
                    end

                    local barLabel = (sInfo.text and sInfo.text ~= "" and not issecretvalue(sInfo.text) and sInfo.text)
                                  or (sInfo.tooltip and sInfo.tooltip ~= "" and not issecretvalue(sInfo.tooltip) and sInfo.tooltip:match("^[^\n]+"))
                                  or (stageName and stageName ~= "" and stageName)
                                  or name
                                  or "Progress"

                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", barLabel, pct)
                    sObj.barText = valText and string_format("%s (%d%%)", valText, pct) or (pct .. "%")
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table.insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- C. DoubleStatusBar
        if C_UIWidgetManager and C_UIWidgetManager.GetDoubleStatusBarWidgetVisualizationInfo then
            local dInfo = C_UIWidgetManager.GetDoubleStatusBarWidgetVisualizationInfo(wID)
            if dInfo and dInfo.shownState ~= 0 and dInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local lMin = dInfo.leftBarMin or 0
                local lMax = dInfo.leftBarMax or 100
                local lCur = dInfo.leftBarValue or 0
                local lRange = lMax - lMin
                if lRange > 0 or lCur > 0 then
                    local pct = (lRange > 0) and math_min(100, math_max(0, math_floor(((lCur - lMin) / lRange) * 100))) or 0
                    local lbl = (dInfo.text and dInfo.text ~= "" and not issecretvalue(dInfo.text) and dInfo.text)
                             or (dInfo.leftBarTooltip and not issecretvalue(dInfo.leftBarTooltip) and dInfo.leftBarTooltip:match("^[^\n]+"))
                             or "Progress"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = (lMax > 0) and string_format("%d/%d (%d%%)", lCur, lMax, pct) or (pct .. "%")
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table.insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- D. FillUpFrames
        if C_UIWidgetManager and C_UIWidgetManager.GetFillUpFramesWidgetVisualizationInfo then
            local fInfo = C_UIWidgetManager.GetFillUpFramesWidgetVisualizationInfo(wID)
            if fInfo and fInfo.shownState ~= 0 and fInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local full = fInfo.numFullFrames or 0
                local totalF = fInfo.numTotalFrames or 0
                local val = fInfo.fillValue or full
                local maxV = fInfo.fillMax or totalF
                if maxV > 0 then
                    local pct = math_min(100, math_max(0, math_floor((val / maxV) * 100)))
                    local lbl = (fInfo.tooltip and not issecretvalue(fInfo.tooltip) and fInfo.tooltip:match("^[^\n]+")) or "Abundance"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = string_format("%d/%d (%d%%)", val, maxV, pct)
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table.insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- E. DiscreteProgressSteps
        if C_UIWidgetManager and C_UIWidgetManager.GetDiscreteProgressStepsVisualizationInfo then
            local dpInfo = C_UIWidgetManager.GetDiscreteProgressStepsVisualizationInfo(wID)
            if dpInfo and dpInfo.shownState ~= 0 and dpInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local pVal = dpInfo.progressVal or 0
                local pMax = dpInfo.progressMax or dpInfo.numSteps or 0
                if pMax > 0 then
                    local pct = math_min(100, math_max(0, math_floor((pVal / pMax) * 100)))
                    local lbl = (dpInfo.tooltip and not issecretvalue(dpInfo.tooltip) and dpInfo.tooltip:match("^[^\n]+")) or "Progress"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = string_format("%d/%d (%d%%)", pVal, pMax, pct)
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table.insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- F. TextWithState
        if C_UIWidgetManager and C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo(wID)
            if wInfo and wInfo.shownState ~= 0 and wInfo.shownState ~= Enum.WidgetShownState.Hidden and wInfo.text and wInfo.text ~= "" and not issecretvalue(wInfo.text) then
                local sObj = AcquireTable()
                sObj.text = wInfo.text
                sObj.finished = false
                table.insert(objs, sObj)
                total = total + 1
            end
        end

        -- G. TextWithSubtext
        if C_UIWidgetManager and C_UIWidgetManager.GetTextWithSubtextWidgetVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetTextWithSubtextWidgetVisualizationInfo(wID)
            if wInfo and wInfo.shownState ~= 0 and wInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local txt = (wInfo.title and wInfo.title ~= "" and not issecretvalue(wInfo.title) and wInfo.title)
                if wInfo.subtext and wInfo.subtext ~= "" and not issecretvalue(wInfo.subtext) then
                    txt = txt and (txt .. ": " .. wInfo.subtext) or wInfo.subtext
                end
                if txt and txt ~= "" then
                    local sObj = AcquireTable()
                    sObj.text = txt
                    sObj.finished = false
                    table.insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- H. TextureAndText
        if C_UIWidgetManager and C_UIWidgetManager.GetTextureAndTextVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetTextureAndTextVisualizationInfo(wID)
            if wInfo and wInfo.shownState ~= 0 and wInfo.shownState ~= Enum.WidgetShownState.Hidden and wInfo.text and wInfo.text ~= "" and not issecretvalue(wInfo.text) then
                local sObj = AcquireTable()
                sObj.text = wInfo.text
                sObj.finished = false
                table.insert(objs, sObj)
                total = total + 1
            end
        end

        -- I. IconAndText
        if C_UIWidgetManager and C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo(wID)
            if wInfo and wInfo.state ~= 0 and wInfo.text and wInfo.text ~= "" and not issecretvalue(wInfo.text) then
                local sObj = AcquireTable()
                sObj.text = wInfo.text
                sObj.finished = false
                table.insert(objs, sObj)
                total = total + 1
            end
        end

        -- J. StackedResourceTracker
        if C_UIWidgetManager and C_UIWidgetManager.GetStackedResourceTrackerWidgetVisualizationInfo then
            local rInfo = C_UIWidgetManager.GetStackedResourceTrackerWidgetVisualizationInfo(wID)
            if rInfo and rInfo.shownState ~= 0 and rInfo.shownState ~= Enum.WidgetShownState.Hidden and rInfo.resources then
                for _, res in ipairs(rInfo.resources) do
                    if res.text and res.text ~= "" and not issecretvalue(res.text) then
                        local sObj = AcquireTable()
                        sObj.text = res.text
                        sObj.finished = false
                        table.insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- K. BulletTextList
        if C_UIWidgetManager and C_UIWidgetManager.GetBulletTextListWidgetVisualizationInfo then
            local bInfo = C_UIWidgetManager.GetBulletTextListWidgetVisualizationInfo(wID)
            if bInfo and bInfo.shownState ~= 0 and bInfo.shownState ~= Enum.WidgetShownState.Hidden and bInfo.lines then
                for _, line in ipairs(bInfo.lines) do
                    if line and line ~= "" and not issecretvalue(line) then
                        local sObj = AcquireTable()
                        sObj.text = line
                        sObj.finished = false
                        table.insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- L. CaptureBar
        if C_UIWidgetManager and C_UIWidgetManager.GetCaptureBarWidgetVisualizationInfo then
            local cbInfo = C_UIWidgetManager.GetCaptureBarWidgetVisualizationInfo(wID)
            if cbInfo and cbInfo.shownState ~= 0 and cbInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local minV = cbInfo.barMinValue or 0
                local maxV = cbInfo.barMaxValue or 100
                local val = cbInfo.barValue or 0
                local range = maxV - minV
                if range > 0 then
                    local pct = math_min(100, math_max(0, math_floor(((val - minV) / range) * 100)))
                    local lbl = (cbInfo.tooltip and not issecretvalue(cbInfo.tooltip) and cbInfo.tooltip:match("^[^\n]+")) or "Control"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = string_format("%d%%", pct)
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table.insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- M. TextColumnRow & TextureAndTextRow
        if C_UIWidgetManager and C_UIWidgetManager.GetTextColumnRowVisualizationInfo then
            local tcInfo = C_UIWidgetManager.GetTextColumnRowVisualizationInfo(wID)
            if tcInfo and tcInfo.shownState ~= 0 and tcInfo.shownState ~= Enum.WidgetShownState.Hidden and tcInfo.entries then
                for _, ent in ipairs(tcInfo.entries) do
                    if ent.text and ent.text ~= "" and not issecretvalue(ent.text) then
                        local sObj = AcquireTable()
                        sObj.text = ent.text
                        sObj.finished = false
                        table.insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end
        if C_UIWidgetManager and C_UIWidgetManager.GetTextureAndTextRowVisualizationInfo then
            local trInfo = C_UIWidgetManager.GetTextureAndTextRowVisualizationInfo(wID)
            if trInfo and trInfo.shownState ~= 0 and trInfo.shownState ~= Enum.WidgetShownState.Hidden and trInfo.entries then
                for _, ent in ipairs(trInfo.entries) do
                    if ent.text and ent.text ~= "" and not issecretvalue(ent.text) then
                        local sObj = AcquireTable()
                        sObj.text = ent.text
                        sObj.finished = false
                        table.insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- N. HorizontalCurrencies & ScenarioHeaderCurrenciesAndBackground
        if C_UIWidgetManager and C_UIWidgetManager.GetHorizontalCurrenciesWidgetVisualizationInfo then
            local hcInfo = C_UIWidgetManager.GetHorizontalCurrenciesWidgetVisualizationInfo(wID)
            if hcInfo and hcInfo.shownState ~= 0 and hcInfo.shownState ~= Enum.WidgetShownState.Hidden and hcInfo.currencies then
                for _, cur in ipairs(hcInfo.currencies) do
                    local txt = (cur.leadingText and cur.leadingText ~= "" and not issecretvalue(cur.leadingText) and cur.leadingText)
                    if cur.text and cur.text ~= "" and not issecretvalue(cur.text) then
                        txt = txt and (txt .. ": " .. cur.text) or cur.text
                    end
                    if txt and txt ~= "" then
                        local sObj = AcquireTable()
                        sObj.text = txt
                        sObj.finished = (cur.isCurrencyMaxed == true)
                        table.insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end
        if C_UIWidgetManager and C_UIWidgetManager.GetScenarioHeaderCurrenciesAndBackgroundWidgetVisualizationInfo then
            local shcInfo = C_UIWidgetManager.GetScenarioHeaderCurrenciesAndBackgroundWidgetVisualizationInfo(wID)
            if shcInfo and shcInfo.shownState ~= 0 and shcInfo.shownState ~= Enum.WidgetShownState.Hidden and shcInfo.currencies then
                for _, cur in ipairs(shcInfo.currencies) do
                    local txt = (cur.leadingText and cur.leadingText ~= "" and not issecretvalue(cur.leadingText) and cur.leadingText)
                    if cur.text and cur.text ~= "" and not issecretvalue(cur.text) then
                        txt = txt and (txt .. ": " .. cur.text) or cur.text
                    end
                    if txt and txt ~= "" then
                        local sObj = AcquireTable()
                        sObj.text = txt
                        sObj.finished = (cur.isCurrencyMaxed == true)
                        table.insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- O. IconTextAndCurrencies
        if C_UIWidgetManager and C_UIWidgetManager.GetIconTextAndCurrenciesWidgetVisualizationInfo then
            local itcInfo = C_UIWidgetManager.GetIconTextAndCurrenciesWidgetVisualizationInfo(wID)
            if itcInfo and itcInfo.shownState ~= 0 and itcInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local txt = (itcInfo.text and itcInfo.text ~= "" and not issecretvalue(itcInfo.text) and itcInfo.text)
                if itcInfo.description and itcInfo.description ~= "" and not issecretvalue(itcInfo.description) then
                    txt = txt and (txt .. ": " .. itcInfo.description) or itcInfo.description
                end
                if txt and txt ~= "" then
                    local sObj = AcquireTable()
                    sObj.text = txt
                    sObj.finished = false
                    table.insert(objs, sObj)
                    total = total + 1
                end
                if itcInfo.currencies then
                    for _, cur in ipairs(itcInfo.currencies) do
                        local cTxt = (cur.leadingText and cur.leadingText ~= "" and not issecretvalue(cur.leadingText) and cur.leadingText)
                        if cur.text and cur.text ~= "" and not issecretvalue(cur.text) then
                            cTxt = cTxt and (cTxt .. ": " .. cur.text) or cur.text
                        end
                        if cTxt and cTxt ~= "" then
                            local sObj = AcquireTable()
                            sObj.text = cTxt
                            sObj.finished = (cur.isCurrencyMaxed == true)
                            table.insert(objs, sObj)
                            total = total + 1
                        end
                    end
                end
            end
        end

        -- P. ButtonHeader
        if C_UIWidgetManager and C_UIWidgetManager.GetButtonHeaderWidgetVisualizationInfo then
            local bhInfo = C_UIWidgetManager.GetButtonHeaderWidgetVisualizationInfo(wID)
            if bhInfo and bhInfo.shownState ~= 0 and bhInfo.shownState ~= Enum.WidgetShownState.Hidden and bhInfo.headerText and bhInfo.headerText ~= "" and not issecretvalue(bhInfo.headerText) then
                local sObj = AcquireTable()
                sObj.text = bhInfo.headerText
                sObj.finished = false
                table.insert(objs, sObj)
                total = total + 1
            end
        end
    end

    -- 3. Bonus Steps Scan (Bonus Objectives in Scenario / World Event)
    if C_Scenario and C_Scenario.GetBonusSteps then
        local steps = C_Scenario.GetBonusSteps()
        if steps and #steps > 0 then
            for _, bIdx in ipairs(steps) do
                local bName, bDesc, bNumCrit, _, _, _, bShouldShow = C_Scenario.GetStepInfo(bIdx)
                if bShouldShow then
                    local bTitle = (bName and bName ~= "" and bName) or bDesc or "Bonus Objective"
                    local sObjHeader = AcquireTable()
                    sObjHeader.text = string_format("|cff33d9f2%s|r", bTitle)
                    sObjHeader.finished = false
                    table.insert(objs, sObjHeader)
                    total = total + 1

                    if bNumCrit and bNumCrit > 0 then
                        for c = 1, bNumCrit do
                            local cInfo = GetScenarioCriteriaSafe(c, bIdx)
                            local cDesc = cInfo and (cInfo.description or cInfo.criteriaString or cInfo.string)
                            if cDesc and cDesc ~= "" and not issecretvalue(cDesc) then
                                local bObj = AcquireTable()
                                local isComp = cInfo.completed == true
                                bObj.finished = isComp
                                if isComp then done = done + 1 end
                                total = total + 1

                                local isWeighted = cInfo.isWeightedProgress
                                    or (cInfo.criteriaType == 8)
                                    or (cInfo.totalQuantity == 100)
                                    or (cInfo.totalQuantity == 1000)
                                    or (cInfo.quantityString and not issecretvalue(cInfo.quantityString) and cInfo.quantityString:find("%%"))

                                if isWeighted then
                                    local cleanDesc = cDesc
                                    if not issecretvalue(cDesc) then
                                        cleanDesc = cDesc:gsub("%s*%(?%d+%%%)?", ""):gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                                    end
                                    bObj.text = cleanDesc
                                    bObj.type = "progressbar"
                                    bObj.numFulfilled = cInfo.quantity or 0
                                    bObj.numRequired = cInfo.totalQuantity or 100
                                    bObj.barText = (cInfo.quantityString and not issecretvalue(cInfo.quantityString) and cInfo.quantityString)
                                                or (not issecretvalue(cInfo.quantity) and (tostring(cInfo.quantity) .. "%"))
                                                or nil
                                    bObj.finished = isComp
                                elseif cInfo.quantity and cInfo.totalQuantity and not issecretvalue(cInfo.totalQuantity) and cInfo.totalQuantity > 1 then
                                    local cleanDesc = cDesc
                                    if not issecretvalue(cDesc) then
                                        cleanDesc = cDesc:gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                                    end
                                    local baseText = cleanDesc
                                    if not issecretvalue(cInfo.quantity) then
                                        baseText = string_format("%s (%s/%s)", cleanDesc, tostring(cInfo.quantity), tostring(cInfo.totalQuantity))
                                    end
                                    bObj.text = baseText
                                    bObj.numFulfilled = cInfo.quantity
                                    bObj.numRequired = cInfo.totalQuantity
                                    bObj.finished = isComp
                                else
                                    bObj.text = cDesc
                                    bObj.finished = isComp
                                end
                                table.insert(objs, bObj)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3. Fallback: Stage Description if no criteria or widgets found
    if #objs == 0 and stageDescription and stageDescription ~= "" and not issecretvalue(stageDescription) then
        local sObj = AcquireTable()
        sObj.text = stageDescription
        sObj.finished = false
        if weightedProgress then
            sObj.type = "progressbar"
            sObj.numFulfilled = 0
            sObj.numRequired = 100
            sObj.barText = ""
        end
        table.insert(objs, sObj)
        total = 1
    end

    if #objs > 0 and name and name ~= "" then
        local entry = AcquireTable()
        entry.questID            = 99990000 + (currentStage or 1)
        entry.questLogIndex      = nil
        entry.title              = title
        entry.isComplete         = (isComplete == true)
        entry.isFailed           = false
        entry.isAutoComplete     = false
        entry.isAutoTurnIn       = false
        entry.isWarbandCompleted = false
        entry.isMeta             = false
        entry.canFindGroup       = false
        entry.objectives         = objs
        entry._syntheticObjs     = true
        entry.done               = done
        entry.total              = total
        entry.singleCountStr     = nil
        entry.isWorldQuest       = false
        entry.timeLeftText       = scTimeLeft
        entry.isScenario         = true

        table.insert(list, entry)
    else
        ReleaseTable(objs)
    end
end

-- ─────────────────────────────────────────────────────────
--  REFRESH (Zero Allocation Loop)
-- ─────────────────────────────────────────────────────────
function QL:DoRefresh()
    State:Update()
    if State:IsActive() then
        if self:IsShown() then self:Hide() end
        return
    end
    if not self:IsShown() then return end

    local savedScroll = scrollBar:GetValue()
    ClearRows()

    local state        = GetQLState()
    local superTracked = (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and
                          C_SuperTrack.GetSuperTrackedQuestID()) or 0
    currentSuperTrackedID = superTracked

    ClearSectionLists()
    wipe(processedQuests)

    local inRaid = false
    if _G.IsInInstance then
        local inInst, instType = _G.IsInInstance()
        if inInst and instType == "raid" then
            inRaid = true
        end
    end

    -- 0. Active Outdoor World Event / Scenario (skipped in raids)
    if not inRaid and sectionLists["scenario"] then
        ScanWorldEventScenario(sectionLists["scenario"])
    end

    -- 1. Active local-area tasks & bonus objectives in player's immediate area (GetTasksTable)
    if not inRaid and GetTasksTable then
        local tasks = GetTasksTable()
        if tasks then
            for i = 1, #tasks do
                AddWorldQuest(tasks[i], false)
            end
        end
    end

    -- 4. Explicitly watched world quests
    if C_QuestLog.GetNumWorldQuestWatches then
        local numW = C_QuestLog.GetNumWorldQuestWatches() or 0
        for w = 1, numW do
            local qID = C_QuestLog.GetQuestIDForWorldQuestWatchIndex(w)
            if qID and qID > 0 and (not inRaid or IsRaidQuest(qID)) then
                AddWorldQuest(qID, true)
            end
        end
    end

    -- 5. Watched standard quests from Blizzard watch index
    if C_QuestLog.GetNumQuestWatches then
        local numW = C_QuestLog.GetNumQuestWatches() or 0
        for w = 1, numW do
            local qID = C_QuestLog.GetQuestIDForQuestWatchIndex(w)
            if qID and qID > 0 and not processedQuests[qID] and (not inRaid or IsRaidQuest(qID)) then
                if C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetInfo then
                    local lIndex = C_QuestLog.GetLogIndexForQuestID(qID)
                    local info = lIndex and C_QuestLog.GetInfo(lIndex)
                    if info and not info.isHeader and not info.isHidden then
                        processedQuests[qID] = true
                        local sid = ClassifyQuest(info, qID)
                        local entry = BuildQuestEntry(qID, sid, info)
                        table.insert(sectionLists[sid], entry)
                    end
                end
            end
        end
    end

    -- 6. Standard quest log scan — show any quest that is watched, supertracked, or belongs to current raid
    local numEntries = C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, numEntries do
        if not C_QuestLog.GetInfo then break end
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden then
            local questID = info.questID
            if questID and questID > 0 and not processedQuests[questID] then
                local isTask = info.isTask or info.isBounty or IsWorldQuest(questID) or (C_QuestLog.IsQuestTask and C_QuestLog.IsQuestTask(questID))
                if isTask then
                    if not inRaid or IsRaidQuest(questID, info) then
                        AddWorldQuest(questID, IsQuestWatched(questID))
                    end
                else
                    local shouldShow = false
                    if inRaid then
                        shouldShow = IsRaidQuest(questID, info)
                    else
                        shouldShow = IsQuestWatched(questID) or (superTracked and superTracked == questID)
                    end
                    if shouldShow then
                        processedQuests[questID] = true
                        local sid = ClassifyQuest(info, questID)
                        local entry = BuildQuestEntry(questID, sid, info)
                        table.insert(sectionLists[sid], entry)
                    end
                end
            end
        end
    end

    -- 7. Tracked achievements scan
    if sectionLists["achievements"] then
        ScanTrackedAchievements(sectionLists["achievements"])
    end

    -- Smart Priority Sort within each active section
    for _, def in ipairs(SECTION_DEFS) do
        local list = sectionLists[def.id]
        if #list > 1 then
            table.sort(list, QuestSortComparator)
        end
    end

    local y = 0

    for _, def in ipairs(SECTION_DEFS) do
        local hdr  = sectionHdrs[def.id]
        local list = sectionLists[def.id]
        local n    = #list
        local rendered = renderedSectionQuests[def.id]
        wipe(rendered)

        if n > 0 then
            for _, entry in ipairs(list) do
                if entry.questID then
                    table.insert(rendered, entry.questID)
                elseif entry.achievementID then
                    table.insert(rendered, entry.achievementID)
                end
            end

            hdr:Show()
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, -y)
            hdr:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
            local collapsed = state.collapsed[def.id]
            hdr.Badge:SetText(tostring(n))
            y = y + SECT_H + 1

            if not collapsed then
                for _, entry in ipairs(list) do
                    local row = AcquireRow()
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, -y)
                    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
                    row:SetHeight(QUEST_H)
                    row.questID            = entry.questID
                    row.achievementID      = entry.achievementID
                    row.isAchievement      = entry.isAchievement
                    row.questTitle         = entry.title
                    row.description        = entry.description
                    row.points             = entry.points
                    row.objectives         = entry.objectives
                    row.isWorldQuest       = entry.isWorldQuest
                    row.timeLeftText       = entry.timeLeftText
                    row.isWarbandCompleted = entry.isWarbandCompleted
                    row.isMeta             = entry.isMeta
                    row.isAutoComplete     = entry.isAutoComplete
                    row.isComplete         = entry.isComplete
                    row.canFindGroup       = entry.canFindGroup
                    row.isScenario         = entry.isScenario

                    if entry.canFindGroup then
                        row.FindGroupBtn:SetAttribute("questID", entry.questID)
                        row.FindGroupBtn:ClearAllPoints()
                        row.FindGroupBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
                        row.FindGroupBtn:Show()
                        row.TitleFS:SetPoint("RIGHT", row.FindGroupBtn, "LEFT", -2, 0)
                    else
                        row.FindGroupBtn:Hide()
                        row.TitleFS:SetPoint("RIGHT", row, "RIGHT", -PAD_X, 0)
                    end

                    local isSuperTracked = (superTracked == entry.questID)
                    if isSuperTracked then
                        row.Dot:Show()
                    else
                        row.Dot:Hide()
                    end

                    -- Left-side popout indicators (outside window on the left of dropdown icon)
                    if row.LeftFS then
                        row.LeftFS:ClearAllPoints()
                        row.LeftFS:SetPoint("RIGHT", row, "LEFT", -6, 0)
                        row.LeftFS:SetText("")
                        row.LeftFS:Hide()
                    end

                    if entry.isComplete and row.LeftFS then
                        if entry.isAutoTurnIn then
                            row.LeftFS:SetText("|cffff00ff[Turn In]|r")
                        else
                            row.LeftFS:SetText("|cff44cc44[Complete]|r")
                        end
                        row.LeftFS:Show()
                    end

                    local rawTitle = entry.title or "Unknown"
                    local timeTag = (entry.isWorldQuest and entry.timeLeftText) and (" " .. COLOR_TIME .. "[" .. entry.timeLeftText .. "]" .. COLOR_RESET) or ""

                    local titleStr
                    if entry.isAchievement then
                        local achCol = entry.isComplete and "|cff44cc44" or "|cffe0a050"
                        local baseText = achCol .. strlower(rawTitle) .. COLOR_RESET
                        if entry.isComplete then
                            titleStr = baseText .. COMPLETE_SUFFIX
                        elseif entry.singleCountStr then
                            local isFin = (entry.done == entry.total)
                            local col = isFin and COLOR_DONE_CNT or COLOR_UNDONE_CNT
                            titleStr = baseText .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. COLOR_RESET
                        elseif entry.total > 0 then
                            local col = (entry.done == entry.total) and COLOR_DONE_CNT or COLOR_UNDONE_CNT
                            titleStr = baseText .. " " .. col .. "[" .. entry.done .. "/" .. entry.total .. "]" .. COLOR_RESET
                        else
                            titleStr = baseText
                        end
                    elseif entry.isScenario then
                        local scTimeTag = (entry.timeLeftText) and (" " .. COLOR_TIME .. "[" .. entry.timeLeftText .. "]" .. COLOR_RESET) or ""
                        titleStr = "|cffffaa00" .. rawTitle .. COLOR_RESET .. scTimeTag
                    elseif entry.isFailed then
                        titleStr = COLOR_FAILED .. rawTitle .. COLOR_RESET .. timeTag
                    elseif entry.isComplete and entry.isAutoTurnIn then
                        titleStr = COLOR_COMPLETE .. rawTitle .. " [Turn In]" .. COLOR_RESET .. timeTag
                    elseif entry.isComplete then
                        local compTitle = entry.isMeta and (COLOR_META .. rawTitle .. COLOR_RESET) or rawTitle
                        titleStr = compTitle .. timeTag .. COMPLETE_SUFFIX
                    else
                        local titleColor
                        if isSuperTracked then
                            titleColor = COLOR_SUPERTRACK
                        elseif entry.isMeta then
                            titleColor = COLOR_META
                        elseif entry.isWarbandCompleted then
                            titleColor = COLOR_WARBAND
                        end
                        local titleText = titleColor and (titleColor .. rawTitle .. COLOR_RESET) or rawTitle

                        if entry.singleCountStr then
                            local isFin = (entry.done == entry.total)
                            local col = isFin and COLOR_DONE_CNT or COLOR_UNDONE_CNT
                            titleStr = titleText .. timeTag .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. COLOR_RESET
                        elseif entry.total > 0 then
                            local col = (entry.done == entry.total) and COLOR_DONE_CNT or COLOR_UNDONE_CNT
                            titleStr = titleText .. timeTag .. " " .. col .. "[" .. entry.done .. "/" .. entry.total .. "]" .. COLOR_RESET
                        else
                            titleStr = titleText .. timeTag
                        end
                    end

                    if row.lastTitleStr ~= titleStr then
                        row.lastTitleStr = titleStr
                        row.TitleFS:SetText(titleStr)
                    end
                    y = y + QUEST_H

                    local hasObjectives = (entry.objectives and #entry.objectives > 0 and not entry.isComplete)
                    local isQuestExpanded
                    if entry.isAchievement then
                        local key = "ach_" .. tostring(entry.achievementID)
                        isQuestExpanded = state.expandedQuests and state.expandedQuests[key]
                    else
                        isQuestExpanded = state.expandedQuests and state.expandedQuests[entry.questID]
                        if isQuestExpanded == nil and entry.isScenario then
                            isQuestExpanded = true
                        end
                    end

                    if hasObjectives then
                        row.ToggleBtn:Show()
                        row.ToggleBtn.Arrow:SetText(isQuestExpanded and "v" or ">")
                    else
                        row.ToggleBtn:Hide()
                    end

                    if isQuestExpanded and hasObjectives then
                        local objX = OBJ_INDENT
                        for _, obj in ipairs(entry.objectives) do
                            if obj.text and obj.text ~= "" then
                                local orow = AcquireObjRow()
                                orow:ClearAllPoints()
                                orow:SetPoint("TOPLEFT",  content, "TOPLEFT",  objX, -y)
                                orow:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0,    -y)

                                -- Check if this objective qualifies for a statusbar (% objectives only):
                                local isBar = (obj.type == "progressbar" or obj.type == 8)
                                if not isBar and obj.text and not issecretvalue(obj.text) and obj.text:find("%%") then
                                    isBar = true
                                end
                                if not isBar and obj.numRequired and not issecretvalue(obj.numRequired) and obj.numRequired == 100 then
                                    isBar = true
                                end

                                if isBar and not obj.finished then
                                    local BAR_H = 18
                                    local totalH = OBJ_H + 2 + BAR_H
                                    orow:SetHeight(totalH)

                                    -- 1. Objective Text on top
                                    orow.FS:Show()
                                    local cleanText = obj.text
                                    if cleanText and not issecretvalue(cleanText) then
                                        cleanText = cleanText:gsub("%s*%(?%d+%%%)?", ""):gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", ""):gsub("^%s*-%s*", "")
                                    end
                                    if not cleanText or cleanText == "" then cleanText = rawTitle end
                                    local objStr = "- " .. cleanText
                                    if orow.lastObjStr ~= objStr or orow.lastFinished ~= false then
                                        orow.lastObjStr = objStr
                                        orow.lastFinished = false
                                        orow.FS:SetText(objStr)
                                        orow.FS:SetTextColor(0.85, 0.85, 0.85)
                                    end

                                    -- 2. Status Bar underneath (zero Lua arithmetic)
                                    orow.Bar:Show()
                                    local maxVal = 100
                                    if obj.type ~= "progressbar" and obj.numRequired and not issecretvalue(obj.numRequired) and obj.numRequired > 1 then
                                        maxVal = obj.numRequired
                                    end
                                    orow.Bar:SetMinMaxValues(0, maxVal)
                                    orow.Bar:SetValue(obj.numFulfilled or 0)

                                    local r, g, b = def.color[1], def.color[2], def.color[3]
                                    if entry.isMeta then
                                        r, g, b = 0.0, 1.0, 1.0
                                    end
                                    orow.Bar:SetStatusBarColor(r * 0.75, g * 0.75, b * 0.75, 0.80)

                                    local barTxt = obj.barText
                                    if not barTxt or barTxt == "" then
                                        if obj.numFulfilled and not issecretvalue(obj.numFulfilled) then
                                            if obj.numRequired and not issecretvalue(obj.numRequired) and obj.numRequired == 100 then
                                                barTxt = tostring(obj.numFulfilled) .. "%"
                                            elseif obj.numRequired and not issecretvalue(obj.numRequired) and obj.numRequired > 1 then
                                                barTxt = tostring(obj.numFulfilled) .. "/" .. tostring(obj.numRequired)
                                            else
                                                barTxt = tostring(obj.numFulfilled) .. "%"
                                            end
                                        end
                                    end
                                    orow.Bar.CenterFS:SetText(barTxt or "")
                                    orow.Bar.CenterFS:SetTextColor(1, 1, 1)

                                    y = y + totalH + 2
                                else
                                    orow.Bar:Hide()
                                    orow.FS:Show()
                                    orow:SetHeight(OBJ_H)
                                    local r, g, b = 0.45, 0.45, 0.45
                                    if obj.finished then r, g, b = 0.25, 0.70, 0.25 end
                                    local objStr = "- " .. (obj.text or "")
                                    if orow.lastObjStr ~= objStr or orow.lastFinished ~= obj.finished then
                                        orow.lastObjStr = objStr
                                        orow.lastFinished = obj.finished
                                        orow.FS:SetText(objStr)
                                        orow.FS:SetTextColor(r, g, b)
                                    end
                                    y = y + OBJ_H
                                end
                            end
                        end
                    end

                    y = y + QUEST_PAD
                end
                y = y + SECT_GAP
            end
        else
            hdr:Hide()
        end

        for _, entry in ipairs(list) do ReleaseTable(entry) end
        wipe(list)
    end

    local qlTop = UpdateQuestLogAnchor()
    local screenH = (UIParent and UIParent:GetHeight()) or 768
    local bottomPhysicalLimit = (screenH * 0.50) + 50
    local availableHeight = (qlTop or (screenH - 10)) - bottomPhysicalLimit
    local maxAllowedH = math_max(60, availableHeight)

    local contentH  = math_max(y, 20)
    content:SetHeight(contentH)
    local clipH = math_min(contentH, maxAllowedH)
    self:SetHeight(clipH)
    scrollClip:SetHeight(clipH)

    local scrollMax = math_max(0, contentH - clipH)
    scrollBar:SetMinMaxValues(0, scrollMax)
    scrollBar:SetValue(math_min(savedScroll, scrollMax))
    if scrollMax == 0 then
        content:SetPoint("TOPLEFT", scrollClip, "TOPLEFT", 0, 0)
        scrollBar:Hide()
        scrollClip:SetPoint("BOTTOMRIGHT", QL, "BOTTOMRIGHT", 0, 0)
        content:SetWidth(FRAME_W)
    else
        scrollBar:Show()
        scrollClip:SetPoint("BOTTOMRIGHT", QL, "BOTTOMRIGHT", -7, 0)
        content:SetWidth(FRAME_W - 7)
    end
end

-- ─────────────────────────────────────────────────────────
--  PUBLIC API
-- ─────────────────────────────────────────────────────────
function sfui.questlog.is_enabled()
    if SfuiDB and SfuiDB.enableQuestLog ~= nil then
        return SfuiDB.enableQuestLog
    end
    if SfuiDB and SfuiDB.questlog and SfuiDB.questlog.enabled ~= nil then
        return SfuiDB.questlog.enabled
    end
    if qcfg and qcfg.enabled ~= nil then
        return qcfg.enabled
    end
    return true
end

function sfui.questlog.set_enabled(enabled)
    if not SfuiDB then SfuiDB = {} end
    SfuiDB.enableQuestLog = enabled
    if SfuiDB.questlog then SfuiDB.questlog.enabled = enabled end

    if enabled then
        sfui.questlog.initialize()
    else
        QL:Hide()
        RestoreBlizzardTracker()
    end
end

-- ─── Mythic+ Handoff ─────────────────────────────────────
-- Called by frames/mythic.lua when a M+ key starts so the quest log
-- immediately hides and Blizzard's tracker remains suppressed.
function sfui.questlog.on_mythic_start()
    State._active = true
    if not InCombat() and QL:IsShown() then QL:Hide() end
    if sfui.SuppressBlizzardTracker then
        sfui.SuppressBlizzardTracker()
    end
end

-- Forward-declare so on_mythic_end (defined here) can call it before line 1785.
local CheckVisibilityAndRefresh

-- Called by frames/mythic.lua when the key resets or the run ends.
function sfui.questlog.on_mythic_end()
    State._active = false
    CheckVisibilityAndRefresh()
end

function sfui.questlog.toggle()
    if InCombat() or not sfui.questlog.is_enabled() then return end
    State:Update()
    if State:IsActive() then return end
    local state = GetQLState()
    if QL:IsShown() then
        QL:Hide()
        state.hidden = true
    else
        state.hidden = false
        SuppressBlizzardTracker()
        UpdateQuestLogAnchor()
        QL:Show()
        Refresh:Request()
    end
end

-- Toggle drag-to-move on section headers.
-- locked = true  → headers only collapse/expand (default, position saved).
-- locked = false → headers also start QL:StartMoving() on drag.
function sfui.questlog.set_locked(locked)
    SfuiDB.questlogUnlocked = not locked
    -- Nothing else to do — QL_IsUnlocked() is checked live in OnDragStart.
end

function sfui.questlog.reset_position()
    if InCombat() then return end
    if SfuiDB then
        SfuiDB.questlogX  = nil
        SfuiDB.questlogY  = nil
        SfuiDB.mythicHudX = nil
        SfuiDB.mythicHudY = nil
    end
    if QL then
        QL:ClearAllPoints()
        QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
        UpdateQuestLogAnchor()
    end
    if SfuiMythicHUD then
        SfuiMythicHUD:ClearAllPoints()
        SfuiMythicHUD:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
    end
end

function sfui.questlog.unhide_all()
    local state = GetQLState()
    if state.hiddenQuests then
        wipe(state.hiddenQuests)
    end
    Refresh:Request()
end

function sfui.questlog.initialize()
    if InCombat() then return end
    if not sfui.questlog.is_enabled() then
        QL:Hide()
        RestoreBlizzardTracker()
        return
    end


    -- Restore saved drag position (default: TOPRIGHT -10, -10 from UIParent).
    local posX = SfuiDB and (SfuiDB.questlogX or SfuiDB.mythicHudX)
    local posY = SfuiDB and (SfuiDB.questlogY or SfuiDB.mythicHudY)
    QL:ClearAllPoints()
    if posX and posY then
        QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)
    else
        QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
    end

    State:Update()
    local state = GetQLState()
    state.hidden = false

    if State:IsActive() then
        if QL:IsShown() then QL:Hide() end
        return
    end

    SuppressBlizzardTracker()
    UpdateQuestLogAnchor()
    QL:Show()
    Refresh:Request()
end

-- ─────────────────────────────────────────────────────────
--  EVENTS
-- ─────────────────────────────────────────────────────────
CheckVisibilityAndRefresh = function()
    if not InCombat() then
        SuppressBlizzardTracker()
    end

    if not sfui.questlog.is_enabled() then
        if not InCombat() and QL:IsShown() then QL:Hide() end
        return
    end

    State:Update()
    if State:IsActive() then
        if not InCombat() and QL:IsShown() then QL:Hide() end
        return
    end

    if not InCombat() then
        UpdateQuestLogAnchor()
    end

    local state = GetQLState()

    if not state.hidden then
        if not InCombat() and not QL:IsShown() then
            QL:Show()
        end
        Refresh:Request()
    else
        if not InCombat() and QL:IsShown() then
            QL:Hide()
        end
    end
end

-- ─────────────────────────────────────────────────────────
--  EVENTS
-- ─────────────────────────────────────────────────────────
-- Migrated from QL:SetScript("OnEvent") + per-event QL:RegisterEvent() to
-- the central sfui.events dispatcher. Benefits:
--   * Shares the same OnEvent dispatch pass as mythic.lua, eliminating the
--     C_Timer.After(0) ordering workaround on PLAYER_ENTERING_WORLD.
--   * UPDATE_UI_WIDGET, UPDATE_ALL_UI_WIDGETS, and zone transitions get
--     RegisterThrottledEvent to absorb burst traffic before Lua is entered.
--   * ADDON_LOADED is handled via the central frame (QL itself does not need
--     to be an event frame at all — it remains purely a visual root panel).
local function on_ql_event(event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        sfui.questlog.initialize()

    elseif event == "ADDON_LOADED" and arg1 == "Blizzard_ObjectiveTracker" then
        -- Blizzard tracker just loaded — install root hook immediately
        SuppressBlizzardTracker()
        CheckVisibilityAndRefresh()

    elseif event == "CHALLENGE_MODE_START" or event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
        CheckVisibilityAndRefresh()

    elseif event == "PLAYER_ENTERING_WORLD" then
        local state = GetQLState()
        state.hidden = false
        -- No C_Timer.After(0) needed: the central dispatcher fires all
        -- PLAYER_ENTERING_WORLD handlers in the same pass, so mythic.lua's
        -- _mode is already set before CheckVisibilityAndRefresh runs here.
        CheckVisibilityAndRefresh()

    elseif event == "SUPER_TRACKING_CHANGED" then
        SyncSuperTrackIndicator()
        local superTracked = (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and
                              C_SuperTrack.GetSuperTrackedQuestID()) or 0
        if superTracked and superTracked > 0 then
            local state = GetQLState()
            local sid = "zone"
            if C_QuestLog.GetInfo then
                local lIndex = C_QuestLog.GetLogIndexForQuestID(superTracked)
                if lIndex then
                    local info = C_QuestLog.GetInfo(lIndex)
                    if info then sid = ClassifyQuest(info, superTracked) end
                end
            end
            if state.collapsed then state.collapsed[sid] = false end
            state.hidden = false
        end
        CheckVisibilityAndRefresh()

    elseif event == "QUEST_ACCEPTED" or event == "TASK_PROGRESS_UPDATE" then
        local qID = arg1
        if qID and type(qID) == "number" and qID > 0 then
            local state = GetQLState()
            state.expandedQuests = state.expandedQuests or {}
            state.expandedQuests[qID] = true
            local sid = "zone"
            if C_QuestLog.GetInfo then
                local lIndex = C_QuestLog.GetLogIndexForQuestID(qID)
                if lIndex then
                    local info = C_QuestLog.GetInfo(lIndex)
                    if info then sid = ClassifyQuest(info, qID) end
                end
            end
            if state.collapsed then state.collapsed[sid] = false end
            state.hidden = false
        end
        CheckVisibilityAndRefresh()

    elseif event == "QUEST_WATCH_LIST_CHANGED" then
        -- Blizzard's watch list changed — it is now the source of truth.
        -- If a quest was added, expand its section and ensure panel is visible.
        local qID, added = arg1, arg2
        if qID and type(qID) == "number" and qID > 0 and added then
            local state = GetQLState()
            state.expandedQuests = state.expandedQuests or {}
            state.expandedQuests[qID] = true
            local sid = "zone"
            if C_QuestLog.GetInfo then
                local lIndex = C_QuestLog.GetLogIndexForQuestID(qID)
                if lIndex then
                    local info = C_QuestLog.GetInfo(lIndex)
                    if info then sid = ClassifyQuest(info, qID) end
                end
            end
            if state.collapsed then state.collapsed[sid] = false end
            state.hidden = false
        end
        CheckVisibilityAndRefresh()

    elseif event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED" then
        local qID = arg1
        if qID and type(qID) == "number" then
            questProgressCache[qID] = nil
            warbandCompleteCache[qID] = nil
            local state = GetQLState()
            if state.expandedQuests then state.expandedQuests[qID] = nil end
        end
        if not InCombat() then
            UpdateQuestLogAnchor()
        end
        Refresh:Request()

    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        cachedCurrentMapID = nil
        cachedParentMapID  = nil
        wipe(worldQuestCache)      -- world quest classification may change on zone transition
        wipe(warbandCompleteCache) -- warband completion status cleared on zone transition
        UpdateMapCache()
        for qID in pairs(questProgressCache) do
            if IsWorldQuest(qID) or (C_QuestLog.IsQuestTask and C_QuestLog.IsQuestTask(qID)) then
                questProgressCache[qID] = nil
            end
        end
        CheckVisibilityAndRefresh()


    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        FlushOutOfCombatQueue()
        SuppressBlizzardTracker()
        CheckVisibilityAndRefresh()

    elseif event == "SCENARIO_UPDATE" or event == "SCENARIO_CRITERIA_UPDATE" or event == "SCENARIO_POI_UPDATE"
        or event == "SCENARIO_SPELL_UPDATE" or event == "SCENARIO_CRITERIA_SHOW_STATE_UPDATE"
        or event == "SCENARIO_COMPLETED" or event == "ACTIVE_DELVE_DATA_UPDATE"
        or event == "CRITERIA_UPDATE" or event == "CRITERIA_COMPLETE"
        or event == "QUEST_CRITERIA_UPDATE" or event == "QUEST_POI_UPDATE"
        or event == "SCENARIO_CRITERIA_PROGRESS_UPDATE" or event == "SCENARIO_STAGE_UPDATE"
        or event == "UPDATE_UI_WIDGET" or event == "UPDATE_ALL_UI_WIDGETS" then
        CheckVisibilityAndRefresh()

    elseif event == "TRACKED_ACHIEVEMENT_LIST_CHANGED" or event == "TRACKED_ACHIEVEMENT_UPDATE" or event == "ACHIEVEMENT_EARNED" then
        Refresh:Request()

    else
        Refresh:Request()
    end
end  -- on_ql_event

-- ─────────────────────────────────────────────────────────
--  EVENT REGISTRATION (central dispatcher)
-- ─────────────────────────────────────────────────────────
-- All events previously registered via QL:RegisterEvent are now routed
-- through sfui.events so they share the global dispatcher frame.
-- High-burst events use RegisterThrottledEvent to avoid redundant Lua calls.

-- Helper: Event registration helper.
local function Reg(e) sfui.events.RegisterEvent(e, on_ql_event) end

Reg("PLAYER_REGEN_DISABLED")
Reg("PLAYER_REGEN_ENABLED")
Reg("ADDON_LOADED")
Reg("QUEST_ACCEPTED")
Reg("QUEST_TURNED_IN")
Reg("QUEST_REMOVED")
Reg("TRACKED_ACHIEVEMENT_LIST_CHANGED")
Reg("TRACKED_ACHIEVEMENT_UPDATE")
Reg("ACHIEVEMENT_EARNED")
Reg("SCENARIO_UPDATE")
Reg("SCENARIO_CRITERIA_UPDATE")
Reg("SCENARIO_POI_UPDATE")
Reg("SCENARIO_SPELL_UPDATE")
Reg("SCENARIO_CRITERIA_SHOW_STATE_UPDATE")
Reg("SCENARIO_CRITERIA_PROGRESS_UPDATE")
Reg("SCENARIO_STAGE_UPDATE")
Reg("SCENARIO_COMPLETED")
Reg("CRITERIA_UPDATE")
Reg("CRITERIA_COMPLETE")
Reg("QUEST_CRITERIA_UPDATE")
Reg("QUEST_POI_UPDATE")
Reg("ACTIVE_DELVE_DATA_UPDATE")
Reg("CHALLENGE_MODE_START")
Reg("CHALLENGE_MODE_COMPLETED")
Reg("CHALLENGE_MODE_RESET")
Reg("SUPER_TRACKING_CHANGED")
Reg("PLAYER_ENTERING_WORLD")

-- Quest log and task updates fire in micro-bursts during quest acceptance/turn-in.
-- Throttle to 0.2s to collapse multi-event bursts into a single refresh pass.
do
    local function _on_quest_log_burst(event, a1, a2)
        on_ql_event(event, a1, a2)
    end
    sfui.events.RegisterThrottledEvent("QUEST_LOG_UPDATE",         0.2, _on_quest_log_burst)
    sfui.events.RegisterThrottledEvent("QUEST_WATCH_LIST_CHANGED", 0.2, _on_quest_log_burst)
    sfui.events.RegisterThrottledEvent("TASK_PROGRESS_UPDATE",      0.2, _on_quest_log_burst)
end

-- Zone change events fire simultaneously in triplicate on zone transitions.
-- Throttle to 0.3s so the three events collapse into a single handler call.
do
    local function _on_zone_change(event, a1, a2)
        on_ql_event(event, a1, a2)
    end
    sfui.events.RegisterThrottledEvent("ZONE_CHANGED_NEW_AREA",  0.3, _on_zone_change)
    sfui.events.RegisterThrottledEvent("ZONE_CHANGED",           0.3, _on_zone_change)
    sfui.events.RegisterThrottledEvent("ZONE_CHANGED_INDOORS",   0.3, _on_zone_change)
end

-- UPDATE_UI_WIDGET and UPDATE_ALL_UI_WIDGETS fire very frequently during
-- Delve/M+ objective progression and in city hubs with widget boards.
-- Throttle to 0.2s to absorb bursts before Lua dispatch is entered at all.
do
    local function _on_widget_update(event, a1, a2)
        on_ql_event(event, a1, a2)
    end
    sfui.events.RegisterThrottledEvent("UPDATE_UI_WIDGET",      0.2, _on_widget_update)
    sfui.events.RegisterThrottledEvent("UPDATE_ALL_UI_WIDGETS", 0.2, _on_widget_update)
end


function sfui.questlog_debug_info()
    local pCount, wCount, wqCount = 0, 0, 0
    for _ in pairs(questProgressCache) do pCount = pCount + 1 end
    for _ in pairs(warbandCompleteCache) do wCount = wCount + 1 end
    for _ in pairs(worldQuestCache) do wqCount = wqCount + 1 end

    return {
        tablePool  = #tablePool,
        rowPool    = #rowPool,
        objPool    = #objPool,
        activeRows = #activeRows,
        activeObjs = #activeObjs,
        progCache  = pCount,
        wbCache    = wCount,
        wqCache    = wqCount,
    }
end

