local addonName, addon = ...
sfui = sfui or {}
sfui.questlog = sfui.questlog or {}

local scenarios = sfui.questlog.scenarios
local providers = sfui.questlog.providers

local IsWorldQuest            = providers.IsWorldQuest
local IsQuestWatched          = providers.IsQuestWatched
local IsQuestWarbandCompleted = providers.IsQuestWarbandCompleted
local IsMetaQuest             = providers.IsMetaQuest
local ClassifyQuest           = providers.ClassifyQuest
local BuildQuestEntry         = providers.BuildQuestEntry
local QuestHasProgress        = providers.QuestHasProgress
local UntrackAchievement      = providers.UntrackAchievement

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
local C_QuestLog                 = _G.C_QuestLog
local C_TaskQuest                = _G.C_TaskQuest
local C_Map                      = _G.C_Map
-- C_QuestInfoSystem: reserved (unused; Blizzard API not yet stable)
local C_Timer                    = _G.C_Timer
local C_SuperTrack               = _G.C_SuperTrack
local C_PerksActivities          = _G.C_PerksActivities
local C_NeighborhoodInitiative   = _G.C_NeighborhoodInitiative
local C_TradeSkillUI             = _G.C_TradeSkillUI
local C_Item                     = _G.C_Item
local Enum                       = _G.Enum
local table, ipairs, pairs, type =
    _G.table, _G.ipairs, _G.pairs, _G.type
local math_min, math_max, math_floor = _G.math.min, _G.math.max, _G.math.floor
local tostring, tonumber = _G.tostring, _G.tonumber
local wipe = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local issecretvalue = _G.issecretvalue or function() return false end
local QuestMapFrame_OpenToQuestDetails = _G.QuestMapFrame_OpenToQuestDetails
local GetTasksTable = _G.GetTasksTable
local GetQuestProgressBarPercent = _G.GetQuestProgressBarPercent
local GetNumAutoQuestPopUps = _G.GetNumAutoQuestPopUps
local GetAutoQuestPopUp = _G.GetAutoQuestPopUp
local IsInGroup = _G.IsInGroup
local print = _G.print
local string_format = string.format  -- localize alias (avoids global table lookup on every call)

-- Isolated Tooltip Frame (Zero global GameTooltip taint, zero UIWidgetManager registration)
local SfuiQuestTooltip = sfui.tooltip

-- Layout constants from config
local FRAME_W    = qcfg.width or 280
local SECT_H     = qcfg.sectionHeight or 20
local QUEST_H    = qcfg.questHeight or 20
local OBJ_H      = qcfg.objectiveHeight or 13
local PAD_X      = 8
local OBJ_INDENT = 14
local THROTTLE   = qcfg.throttle or 0.35
local SECT_GAP   = 2
local QUEST_PAD  = 2

-- Pre-cached Formatting Strings & Colors (Table-packed to conserve upvalues)
local C = {
    ITEM_TAG      = "|TInterface\\Buttons\\WHITE8x8:6:6:0:0:8:8:0:8:0:8:102:0:255|t ",
    COMPLETE      = "|cffff00ff",
    COMPLETE_SUF  = " |cff44cc44[Complete]|r",
    SUPERTRACK    = "|cffffff00",
    WARBAND       = "|cffa02020",
    META          = "|cff00ffff",
    FAILED        = "|cffff4444",
    DONE_CNT      = "|cff44cc44",
    UNDONE_CNT    = "|cff777777",
    TIME          = "|cff33d9f2",
    TIME_CRITICAL = "|cffff5533",
    PARTY_COUNT   = "|cff33d9f2",
    OFFER         = "|cff00ff88",
    PERK          = "|cff33d9f2",
    HOUSE         = "|cff88d055",
    RECIPE        = "|cffe0a050",
    RESET         = "|r",
}

-- Section definitions (display order)
local SECTION_DEFS = qcfg.sections or {
    { id = "scenario",     label = "world event",      color = { 1.00, 0.60, 0.10 } },
    { id = "events",       label = "events",           color = { 0.90, 0.45, 0.90 } },
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
    -- Housing zones (Razorwind Shores, Founder's Point, houses, plots, neighborhoods)
    -- are instanced environments, but must NOT hide the quest log.
    if common.is_housing_zone and common.is_housing_zone() then
        self._active = false
        return
    end

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
    events       = {},
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
    events       = {},
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
sfui.questlog.GetState = GetQLState

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

local function UntrackSectionQuests(sectionID)
    if sectionID == "achievements" then
        providers.UntrackAllAchievements()
        return
    end

    if sectionID == "activities" then
        providers.UntrackAllActivities()
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

            if row.activityID then
                local state = GetQLState()
                state.expandedQuests = state.expandedQuests or {}
                local key = "perk_" .. tostring(row.activityID)
                state.expandedQuests[key] = not state.expandedQuests[key]
                Refresh:Request()
                return
            end

            if row.housingTaskID then
                local state = GetQLState()
                state.expandedQuests = state.expandedQuests or {}
                local key = "house_" .. tostring(row.housingTaskID)
                state.expandedQuests[key] = not state.expandedQuests[key]
                Refresh:Request()
                return
            end

            if row.recipeID then
                local state = GetQLState()
                state.expandedQuests = state.expandedQuests or {}
                local key = "rec_" .. tostring(row.recipeID) .. (row.isRecraft and "_r" or "")
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

        -- Find Group Eye Button (Right edge) - 100% custom non-tainting button
        local findGroupBtn = CreateFrame("Button", nil, row)
        local eyeIcon = findGroupBtn:CreateTexture(nil, "ARTWORK")
        eyeIcon:SetSize(14, 14)
        eyeIcon:SetPoint("CENTER", findGroupBtn, "CENTER", 0, 0)
        eyeIcon:SetAtlas("socialqueuing-icon-eye")
        eyeIcon:SetVertexColor(0.85, 0.85, 0.85, 0.85)
        findGroupBtn.EyeIcon = eyeIcon

        findGroupBtn:SetScript("OnEnter", function(btn)
            eyeIcon:SetVertexColor(1, 1, 1, 1)
            SfuiQuestTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            SfuiQuestTooltip:ClearLines()
            SfuiQuestTooltip:AddLine(TOOLTIP_TRACKER_FIND_GROUP_BUTTON or "Find Group", 1, 1, 1)
            if row.questTitle then
                SfuiQuestTooltip:AddLine(row.questTitle, 0.20, 0.85, 0.95)
            end
            SfuiQuestTooltip:AddLine("Click to search for or create a group in Group Finder.", 0.7, 0.7, 0.7, true)
            SfuiQuestTooltip:Show()
        end)
        findGroupBtn:SetScript("OnLeave", function(btn)
            eyeIcon:SetVertexColor(0.85, 0.85, 0.85, 0.85)
            SfuiQuestTooltip:Hide()
        end)
        findGroupBtn:SetScript("OnClick", function(btn)
            if InCombat() then return end
            local qID = btn.questID or row.questID
            if qID and _G.LFGListUtil_FindQuestGroup then
                C_Timer.After(0, function()
                    if not InCombat() and _G.LFGListUtil_FindQuestGroup and qID then
                        _G.LFGListUtil_FindQuestGroup(qID, true)
                    end
                end)
            end
        end)

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

            if s.isAutoQuestOffer and s.questID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()
                SfuiQuestTooltip:AddLine(s.questTitle or "Quest Offer", 0.00, 1.00, 0.50)
                SfuiQuestTooltip:AddLine("Incoming Remote Quest Offer", 0.85, 0.85, 0.85)
                SfuiQuestTooltip:AddLine(" ")
                SfuiQuestTooltip:AddLine("|cff888888Left-click: Accept Quest Offer|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Shift-click: Dismiss Offer|r", 1, 1, 1)
                SfuiQuestTooltip:Show()
                return
            end

            if s.isPerksActivity and s.activityID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()
                SfuiQuestTooltip:AddLine(s.questTitle or "Traveler's Log", 0.20, 0.85, 0.95)
                if s.description and s.description ~= "" then
                    SfuiQuestTooltip:AddLine(s.description, 0.85, 0.85, 0.85, true)
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
                SfuiQuestTooltip:AddLine("|cff888888Left-click: Open Traveler's Log|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Right-click / Arrow: Collapse/Expand requirements|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Shift-click: Untrack Activity|r", 1, 1, 1)
                SfuiQuestTooltip:Show()
                return
            end

            if s.isHousingTask and s.housingTaskID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()
                SfuiQuestTooltip:AddLine(s.questTitle or "Housing Endeavor", 0.55, 0.85, 0.35)
                SfuiQuestTooltip:AddLine("Player Housing Neighborhood Initiative", 0.85, 0.85, 0.85)
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
                SfuiQuestTooltip:AddLine("|cff888888Left-click: Open Endeavors Tab|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Right-click / Arrow: Collapse/Expand requirements|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Shift-click: Untrack Task|r", 1, 1, 1)
                SfuiQuestTooltip:Show()
                return
            end

            if s.isRecipe and s.recipeID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()
                SfuiQuestTooltip:AddLine(s.questTitle or "Tracked Recipe", 0.90, 0.65, 0.30)
                SfuiQuestTooltip:AddLine(s.isRecraft and "Recrafting Recipe" or "Crafting Recipe", 0.85, 0.85, 0.85)
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
                SfuiQuestTooltip:AddLine("|cff888888Left-click: Open Recipe in Profession Window|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Right-click / Arrow: Collapse/Expand reagents|r", 1, 1, 1)
                SfuiQuestTooltip:AddLine("|cff888888Shift-click: Untrack Recipe|r", 1, 1, 1)
                SfuiQuestTooltip:Show()
                return
            end

            if s.questID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()

                if s.isWorldEvent then
                    local r, g, b = 0.90, 0.45, 0.90
                    if s.isOngoing then r, g, b = 1.00, 0.75, 0.10 end
                    SfuiQuestTooltip:AddLine(s.questTitle or "World Event", r, g, b)
                    if s.zoneName and s.zoneName ~= "" then
                        SfuiQuestTooltip:AddLine(s.zoneName, 0.85, 0.85, 0.85)
                    end
                    if s.timeLeftText then
                        SfuiQuestTooltip:AddLine(s.timeLeftText, 0.20, 0.85, 0.95)
                    end
                    if s.hasReminder then
                        SfuiQuestTooltip:AddLine("Event Reminder: ACTIVE", 0.0, 1.0, 0.8)
                    end
                    SfuiQuestTooltip:AddLine(" ")
                    SfuiQuestTooltip:AddLine("|cff888888Left-click: Track & Show on Map|r", 1, 1, 1)
                    SfuiQuestTooltip:AddLine("|cff888888Right-click: Toggle Reminder|r", 1, 1, 1)
                    SfuiQuestTooltip:Show()
                    return
                end

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
                    if s.isCriticalTime then
                        SfuiQuestTooltip:AddLine(s.timeLeftText .. " (Expiring Soon!)", 1.0, 0.35, 0.2)
                    else
                        SfuiQuestTooltip:AddLine(s.timeLeftText, 0.20, 0.85, 0.95)
                    end
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

                if IsInGroup and IsInGroup() and s.questID and s.questID > 0 and SfuiQuestTooltip.SetQuestPartyProgress then
                    SfuiQuestTooltip:AddLine(" ")
                    SfuiQuestTooltip:SetQuestPartyProgress(s.questID)
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
            if s.isWorldEvent and s.areaPoiID then
                if btn == "RightButton" then
                    if s.eventKey and C_EventScheduler then
                        if s.hasReminder then
                            if C_EventScheduler.ClearReminder then
                                C_EventScheduler.ClearReminder(s.eventKey)
                            end
                        else
                            if C_EventScheduler.SetReminder then
                                C_EventScheduler.SetReminder(s.eventKey)
                            end
                        end
                    end
                    if sfui.worldevents and sfui.worldevents.RequestUpdate then
                        sfui.worldevents.RequestUpdate()
                    else
                        Refresh:Request()
                    end
                    return
                end

                if C_SuperTrack and C_SuperTrack.SetSuperTrackedMapPin and Enum.SuperTrackingMapPinType and Enum.SuperTrackingMapPinType.AreaPOI then
                    local _, curPoiID = C_SuperTrack.GetSuperTrackedMapPin(Enum.SuperTrackingMapPinType.AreaPOI)
                    if curPoiID == s.areaPoiID then
                        C_SuperTrack.ClearSuperTrackedMapPin(Enum.SuperTrackingMapPinType.AreaPOI)
                    else
                        C_SuperTrack.SetSuperTrackedMapPin(Enum.SuperTrackingMapPinType.AreaPOI, s.areaPoiID)
                        if not InCombat() and _G.OpenMapToEventPoi then
                            _G.OpenMapToEventPoi(s.areaPoiID)
                        end
                    end
                    Refresh:Request()
                end
                return
            end

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

            if s.isAutoQuestOffer and s.questID then
                local IsShiftKeyDown = _G.IsShiftKeyDown
                if IsShiftKeyDown and IsShiftKeyDown() then
                    if _G.RemoveAutoQuestPopUp then
                        _G.RemoveAutoQuestPopUp(s.questID)
                        Refresh:Request()
                    end
                    return
                end
                if _G.ShowQuestOffer then
                    _G.ShowQuestOffer(s.questID)
                end
                return
            end

            if s.isPerksActivity and s.activityID then
                local IsShiftKeyDown = _G.IsShiftKeyDown
                if IsShiftKeyDown and IsShiftKeyDown() then
                    local ChatEdit_GetActiveWindow = _G.ChatEdit_GetActiveWindow
                    local ChatEdit_InsertLink = _G.ChatEdit_InsertLink
                    local activeChat = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                    if activeChat and activeChat:IsShown() and activeChat:HasFocus() then
                        if C_PerksActivities and C_PerksActivities.GetPerksActivityChatLink and ChatEdit_InsertLink then
                            local link = C_PerksActivities.GetPerksActivityChatLink(s.activityID)
                            if link and ChatEdit_InsertLink(link) then return end
                        end
                    end
                    if C_PerksActivities and C_PerksActivities.RemoveTrackedPerksActivity then
                        C_PerksActivities.RemoveTrackedPerksActivity(s.activityID)
                        Refresh:Request()
                    end
                    return
                end

                if btn == "RightButton" then
                    local state = GetQLState()
                    state.expandedQuests = state.expandedQuests or {}
                    local key = "perk_" .. tostring(s.activityID)
                    state.expandedQuests[key] = not state.expandedQuests[key]
                    Refresh:Request()
                    return
                end

                if not InCombat() then
                    if not _G.EncounterJournal and _G.EncounterJournal_LoadUI then
                        _G.EncounterJournal_LoadUI()
                    end
                    if _G.MonthlyActivitiesFrame_OpenFrameToActivity then
                        _G.MonthlyActivitiesFrame_OpenFrameToActivity(s.activityID)
                    end
                end
                return
            end

            if s.isHousingTask and s.housingTaskID then
                local IsShiftKeyDown = _G.IsShiftKeyDown
                if IsShiftKeyDown and IsShiftKeyDown() then
                    local ChatEdit_GetActiveWindow = _G.ChatEdit_GetActiveWindow
                    local ChatEdit_InsertLink = _G.ChatEdit_InsertLink
                    local activeChat = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                    if activeChat and activeChat:IsShown() and activeChat:HasFocus() then
                        if C_NeighborhoodInitiative and C_NeighborhoodInitiative.GetInitiativeTaskChatLink and ChatEdit_InsertLink then
                            local link = C_NeighborhoodInitiative.GetInitiativeTaskChatLink(s.housingTaskID)
                            if link and ChatEdit_InsertLink(link) then return end
                        end
                    end
                    if C_NeighborhoodInitiative and C_NeighborhoodInitiative.RemoveTrackedInitiativeTask then
                        C_NeighborhoodInitiative.RemoveTrackedInitiativeTask(s.housingTaskID)
                        Refresh:Request()
                    end
                    return
                end

                if btn == "RightButton" then
                    local state = GetQLState()
                    state.expandedQuests = state.expandedQuests or {}
                    local key = "house_" .. tostring(s.housingTaskID)
                    state.expandedQuests[key] = not state.expandedQuests[key]
                    Refresh:Request()
                    return
                end

                if not InCombat() and _G.HousingFramesUtil and _G.HousingFramesUtil.OpenFrameToTaskID then
                    _G.HousingFramesUtil.OpenFrameToTaskID(s.housingTaskID)
                end
                return
            end

            if s.isRecipe and s.recipeID then
                local IsShiftKeyDown = _G.IsShiftKeyDown
                if IsShiftKeyDown and IsShiftKeyDown() then
                    if C_TradeSkillUI and C_TradeSkillUI.SetRecipeTracked then
                        C_TradeSkillUI.SetRecipeTracked(s.recipeID, false, s.isRecraft == true)
                        Refresh:Request()
                    end
                    return
                end

                if btn == "RightButton" then
                    local state = GetQLState()
                    state.expandedQuests = state.expandedQuests or {}
                    local key = "rec_" .. tostring(s.recipeID) .. (s.isRecraft and "_r" or "")
                    state.expandedQuests[key] = not state.expandedQuests[key]
                    Refresh:Request()
                    return
                end

                if not InCombat() then
                    if _G.ProfessionsUtil and _G.ProfessionsUtil.OpenProfessionFrameToRecipe then
                        _G.ProfessionsUtil.OpenProfessionFrameToRecipe(s.recipeID)
                    elseif C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then
                        C_TradeSkillUI.OpenRecipe(s.recipeID)
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
        bar:Hide()
        obj.Bar = bar
        obj.BarFS = barCenterFS
    end
    if not obj.BarFS and obj.Bar and obj.Bar.CenterFS then
        obj.BarFS = obj.Bar.CenterFS
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

        local entry = BuildQuestEntry(qID, "world", nil, AcquireTable, state)
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

-- ─────────────────────────────────────────────────────────
--  DATA COLLECTION & SCANNING (Zero Allocation)
-- ─────────────────────────────────────────────────────────
local function CollectTrackedQuests(superTracked)
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
        scenarios.Scan(sectionLists["scenario"], AcquireTable, ReleaseTable)
    end

    -- 0b. Scheduled & Ongoing World Events (Event Scheduler)
    if not inRaid and sectionLists["events"] and sfui.worldevents and sfui.worldevents.is_enabled and sfui.worldevents.is_enabled() then
        sfui.worldevents.ScanEvents(sectionLists["events"], AcquireTable)
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

    -- 2. Explicitly watched world quests
    if C_QuestLog.GetNumWorldQuestWatches then
        local numW = C_QuestLog.GetNumWorldQuestWatches() or 0
        for w = 1, numW do
            local qID = C_QuestLog.GetQuestIDForWorldQuestWatchIndex(w)
            if qID and qID > 0 and (not inRaid or IsRaidQuest(qID)) then
                AddWorldQuest(qID, true)
            end
        end
    end

    -- 3. Watched standard quests from Blizzard watch index
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
                        local entry = BuildQuestEntry(qID, sid, info, AcquireTable)
                        table.insert(sectionLists[sid], entry)
                    end
                end
            end
        end
    end

    -- 4. Standard quest log scan — show any quest that is watched, supertracked, or belongs to current raid
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
                        local entry = BuildQuestEntry(questID, sid, info, AcquireTable)
                        table.insert(sectionLists[sid], entry)
                    end
                end
            end
        end
    end

    -- 5. Tracked achievements scan
    if sectionLists["achievements"] then
        providers.ScanAchievements(sectionLists["achievements"], AcquireTable)
    end

    -- 6. Auto-Quest Offers (remote popups)
    if not inRaid and sectionLists["important"] then
        providers.ScanAutoQuestPopUps(sectionLists["important"], AcquireTable, processedQuests)
    end

    -- 7. Modern Trackables (Traveler's Log, Housing Endeavors, Recipes)
    if not inRaid and sectionLists["activities"] then
        providers.ScanPerksActivities(sectionLists["activities"], AcquireTable)
        providers.ScanHousingInitiatives(sectionLists["activities"], AcquireTable)
        providers.ScanRecipes(sectionLists["activities"], AcquireTable)
    end

    -- Smart Priority Sort within each active section
    for _, def in ipairs(SECTION_DEFS) do
        local list = sectionLists[def.id]
        if #list > 1 then
            table.sort(list, QuestSortComparator)
        end
    end
end

-- ─────────────────────────────────────────────────────────
--  ROW & OBJECTIVE RENDERING LOOP
-- ─────────────────────────────────────────────────────────
local function RenderSections(state, superTracked)
    local y = 0
    local superTrackedPOI = 0
    if C_SuperTrack and C_SuperTrack.GetSuperTrackedMapPin and Enum.SuperTrackingMapPinType and Enum.SuperTrackingMapPinType.AreaPOI then
        local _, pID = C_SuperTrack.GetSuperTrackedMapPin(Enum.SuperTrackingMapPinType.AreaPOI)
        superTrackedPOI = pID or 0
    end

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
                elseif entry.activityID then
                    table.insert(rendered, entry.activityID)
                elseif entry.housingTaskID then
                    table.insert(rendered, entry.housingTaskID)
                elseif entry.recipeID then
                    table.insert(rendered, entry.recipeID)
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
                    row:Show()
                    row:SetHeight(QUEST_H)
                    row.questID            = entry.questID
                    row.achievementID      = entry.achievementID
                    row.isAchievement      = entry.isAchievement
                    row.activityID         = entry.activityID
                    row.isPerksActivity    = entry.isPerksActivity
                    row.housingTaskID      = entry.housingTaskID
                    row.isHousingTask      = entry.isHousingTask
                    row.recipeID           = entry.recipeID
                    row.isRecraft          = entry.isRecraft
                    row.isRecipe           = entry.isRecipe
                    row.isAutoQuestOffer   = entry.isAutoQuestOffer
                    row.questTitle         = entry.title
                    row.description        = entry.description
                    row.points             = entry.points
                    row.objectives         = entry.objectives
                    row.isWorldQuest       = entry.isWorldQuest
                    row.timeLeftText       = entry.timeLeftText
                    row.isCriticalTime     = entry.isCriticalTime
                    row.isWarbandCompleted = entry.isWarbandCompleted
                    row.isMeta             = entry.isMeta
                    row.isAutoComplete     = entry.isAutoComplete
                    row.isComplete         = entry.isComplete
                    row.canFindGroup       = entry.canFindGroup
                    row.isScenario         = entry.isScenario
                    row.isWorldEvent       = entry.isWorldEvent
                    row.eventKey           = entry.eventKey
                    row.areaPoiID          = entry.areaPoiID
                    row.zoneName           = entry.zoneName
                    row.hasReminder        = entry.hasReminder
                    row.isOngoing          = entry.isOngoing

                    if entry.canFindGroup then
                        row.FindGroupBtn.questID = entry.questID
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

                    if row.LeftFS then
                        row.LeftFS:ClearAllPoints()
                        row.LeftFS:SetPoint("RIGHT", row, "LEFT", -6, 0)
                        row.LeftFS:SetText("")
                        row.LeftFS:Hide()
                    end

                    if entry.isAutoQuestOffer and row.LeftFS then
                        row.LeftFS:SetText(C.OFFER .. "[Offer]" .. C.RESET)
                        row.LeftFS:Show()
                    elseif entry.isComplete and row.LeftFS then
                        if entry.isAutoTurnIn then
                            row.LeftFS:SetText("|cffff00ff[Turn In]|r")
                        else
                            row.LeftFS:SetText("|cff44cc44[Complete]|r")
                        end
                        row.LeftFS:Show()
                    end

                    local rawTitle = entry.title or "Unknown"
                    local timeCol = entry.isCriticalTime and C.TIME_CRITICAL or C.TIME
                    local timeTag = (entry.isWorldQuest and entry.timeLeftText) and (" " .. timeCol .. "[" .. entry.timeLeftText .. "]" .. C.RESET) or ""
                    local partyTag = (entry.partyCount and entry.partyCount > 0) and (" " .. C.PARTY_COUNT .. "[P:" .. entry.partyCount .. "]" .. C.RESET) or ""

                    local titleStr
                    if entry.isAutoQuestOffer then
                        titleStr = C.OFFER .. "[Offer] " .. C.RESET .. rawTitle
                    elseif entry.isPerksActivity then
                        local pCol = entry.isComplete and "|cff44cc44" or C.PERK
                        local baseText = pCol .. "[Traveler] " .. C.RESET .. rawTitle
                        if entry.isComplete then
                            titleStr = baseText .. C.COMPLETE_SUF
                        elseif entry.singleCountStr then
                            local isFin = (entry.done == entry.total)
                            local col = isFin and C.DONE_CNT or C.UNDONE_CNT
                            titleStr = baseText .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. C.RESET
                        else
                            titleStr = baseText
                        end
                    elseif entry.isHousingTask then
                        local hCol = entry.isComplete and "|cff44cc44" or C.HOUSE
                        local baseText = hCol .. "[Housing] " .. C.RESET .. rawTitle
                        if entry.isComplete then
                            titleStr = baseText .. C.COMPLETE_SUF
                        elseif entry.singleCountStr then
                            local isFin = (entry.done == entry.total)
                            local col = isFin and C.DONE_CNT or C.UNDONE_CNT
                            titleStr = baseText .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. C.RESET
                        else
                            titleStr = baseText
                        end
                    elseif entry.isRecipe then
                        local rCol = entry.isComplete and "|cff44cc44" or C.RECIPE
                        local recLabel = entry.isRecraft and "[Recraft] " or "[Recipe] "
                        local baseText = rCol .. recLabel .. C.RESET .. rawTitle
                        if entry.isComplete then
                            titleStr = baseText .. C.COMPLETE_SUF
                        elseif entry.singleCountStr then
                            local isFin = (entry.done == entry.total)
                            local col = isFin and C.DONE_CNT or C.UNDONE_CNT
                            titleStr = baseText .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. C.RESET
                        else
                            titleStr = baseText
                        end
                    elseif entry.isAchievement then
                        local achCol = entry.isComplete and "|cff44cc44" or "|cffe0a050"
                        local baseText = achCol .. strlower(rawTitle) .. C.RESET
                        if entry.isComplete then
                            titleStr = baseText .. C.COMPLETE_SUF
                        elseif entry.singleCountStr then
                            local isFin = (entry.done == entry.total)
                            local col = isFin and C.DONE_CNT or C.UNDONE_CNT
                            titleStr = baseText .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. C.RESET
                        elseif entry.total > 0 then
                            local col = (entry.done == entry.total) and C.DONE_CNT or C.UNDONE_CNT
                            titleStr = baseText .. " " .. col .. "[" .. entry.done .. "/" .. entry.total .. "]" .. C.RESET
                        else
                            titleStr = baseText
                        end
                    elseif entry.isScenario then
                        local scTimeTag = (entry.timeLeftText) and (" " .. C.TIME .. "[" .. entry.timeLeftText .. "]" .. C.RESET) or ""
                        titleStr = "|cffffaa00" .. rawTitle .. C.RESET .. scTimeTag
                    elseif entry.isWorldEvent then
                        local evColor = entry.isOngoing and "|cffffcc00" or "|cffe0a0ff"
                        local timeCol = entry.isOngoing and "|cff00ff88" or C.TIME
                        local evTimeTag = (entry.timeLeftText) and (" " .. timeCol .. "[" .. entry.timeLeftText .. "]" .. C.RESET) or ""
                        titleStr = evColor .. rawTitle .. C.RESET .. evTimeTag
                    elseif entry.isFailed then
                        titleStr = C.FAILED .. rawTitle .. C.RESET .. timeTag
                    elseif entry.isComplete and entry.isAutoTurnIn then
                        titleStr = C.COMPLETE .. rawTitle .. " [Turn In]" .. C.RESET .. timeTag
                    elseif entry.isComplete then
                        local compTitle = entry.isMeta and (C.META .. rawTitle .. C.RESET) or rawTitle
                        titleStr = compTitle .. timeTag .. C.COMPLETE_SUF
                    else
                        local titleColor
                        if isSuperTracked then
                            titleColor = C.SUPERTRACK
                        elseif entry.isMeta then
                            titleColor = C.META
                        elseif entry.isWarbandCompleted then
                            titleColor = C.WARBAND
                        end
                        local titleText = titleColor and (titleColor .. rawTitle .. C.RESET) or rawTitle

                        if entry.singleCountStr then
                            local isFin = (entry.done == entry.total)
                            local col = isFin and C.DONE_CNT or C.UNDONE_CNT
                            titleStr = titleText .. timeTag .. partyTag .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. C.RESET
                        elseif entry.total > 0 then
                            local col = (entry.done == entry.total) and C.DONE_CNT or C.UNDONE_CNT
                            titleStr = titleText .. timeTag .. partyTag .. " " .. col .. "[" .. entry.done .. "/" .. entry.total .. "]" .. C.RESET
                        else
                            titleStr = titleText .. timeTag .. partyTag
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
                    elseif entry.isPerksActivity then
                        local key = "perk_" .. tostring(entry.activityID)
                        isQuestExpanded = state.expandedQuests and state.expandedQuests[key]
                        if isQuestExpanded == nil then isQuestExpanded = true end
                    elseif entry.isHousingTask then
                        local key = "house_" .. tostring(entry.housingTaskID)
                        isQuestExpanded = state.expandedQuests and state.expandedQuests[key]
                        if isQuestExpanded == nil then isQuestExpanded = true end
                    elseif entry.isRecipe then
                        local key = "rec_" .. tostring(entry.recipeID) .. (entry.isRecraft and "_r" or "")
                        isQuestExpanded = state.expandedQuests and state.expandedQuests[key]
                        if isQuestExpanded == nil then isQuestExpanded = true end
                    elseif entry.isWorldEvent then
                        local key = "we_" .. tostring(entry.eventKey or entry.areaPoiID)
                        isQuestExpanded = state.expandedQuests and state.expandedQuests[key]
                        if isQuestExpanded == nil then isQuestExpanded = true end
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
                        local objX = OBJ_INDENT or 14
                        for _, obj in ipairs(entry.objectives) do
                            if obj.text and obj.text ~= "" then
                                local orow = AcquireObjRow()
                                orow:ClearAllPoints()
                                orow:SetPoint("TOPLEFT",  content, "TOPLEFT",  objX, -y)
                                orow:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0,    -y)

                                local isBar = (obj.type == "progressbar" or obj.type == 8 or (obj.objectiveType and (obj.objectiveType == 8 or obj.objectiveType == "progressbar")))

                                if isBar and not obj.finished then
                                    local BAR_H = 18
                                    local totalH = OBJ_H + 2 + BAR_H
                                    orow:SetHeight(totalH)

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

                                    orow.Bar:Show()
                                    local maxVal = obj.numRequired or 100
                                    if issecretvalue(maxVal) or maxVal <= 0 then maxVal = 100 end
                                    local curVal = obj.numFulfilled or 0
                                    if issecretvalue(curVal) or curVal < 0 then curVal = 0 end

                                    -- Handle fixed-point 1000 (tenths of a %) or 10000 (hundredths of a %)
                                    if maxVal == 1000 then
                                        curVal = math_floor(curVal / 10)
                                        maxVal = 100
                                    elseif maxVal == 10000 then
                                        curVal = math_floor(curVal / 100)
                                        maxVal = 100
                                    elseif obj.type == "progressbar" or isBar then
                                        if maxVal == 100 and curVal > 100 then
                                            if curVal <= 1000 then
                                                curVal = math_floor(curVal / 10)
                                            elseif curVal <= 10000 then
                                                curVal = math_floor(curVal / 100)
                                            else
                                                curVal = 100
                                            end
                                        end
                                    end
                                    curVal = math_min(maxVal, math_max(0, curVal))

                                    orow.Bar:SetMinMaxValues(0, maxVal)
                                    orow.Bar:SetValue(curVal)

                                    local r, g, b = def.color[1], def.color[2], def.color[3]
                                    if entry.isMeta then
                                        r, g, b = 0.0, 1.0, 1.0
                                    end
                                    orow.Bar:SetStatusBarColor(r * 0.75, g * 0.75, b * 0.75, 0.80)

                                    local barTxt = obj.barText
                                    local isHighPct = false
                                    if barTxt and type(barTxt) == "string" then
                                        local pctNum = barTxt:match("(%d+)%%")
                                        if pctNum and tonumber(pctNum) > 100 then
                                            isHighPct = true
                                        end
                                    end

                                    if not barTxt or barTxt == "" or isHighPct then
                                        if maxVal == 100 or obj.type == "progressbar" or isBar then
                                            local pct = (maxVal > 0) and math_floor((curVal / maxVal) * 100) or 0
                                            barTxt = tostring(math_min(100, math_max(0, pct))) .. "%"
                                        elseif maxVal > 1 then
                                            barTxt = tostring(curVal) .. "/" .. tostring(maxVal)
                                        else
                                            barTxt = tostring(curVal) .. "%"
                                        end
                                    end
                                    local barFS = orow.BarFS or (orow.Bar and orow.Bar.CenterFS)
                                    if barFS then
                                        barFS:SetText(barTxt)
                                    end
                                    y = y + totalH
                                else
                                    if orow.Bar then orow.Bar:Hide() end
                                    local barFS = orow.BarFS or (orow.Bar and orow.Bar.CenterFS)
                                    if barFS then
                                        barFS:SetText("")
                                    end
                                    orow:SetHeight(OBJ_H)

                                    local objStr = "- " .. (obj.text or "")
                                    local isFin = (obj.finished == true)
                                    if orow.lastObjStr ~= objStr or orow.lastFinished ~= isFin then
                                        orow.lastObjStr = objStr
                                        orow.lastFinished = isFin
                                        local r, g, b = 0.65, 0.65, 0.65
                                        if isFin then r, g, b = 0.35, 0.80, 0.35 end
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

    return y
end

-- ─────────────────────────────────────────────────────────
--  LAYOUT & SCROLLBAR SIZING
-- ─────────────────────────────────────────────────────────
local function UpdateScrollLayout(y, savedScroll)
    local qlTop = UpdateQuestLogAnchor()
    local screenH = (UIParent and UIParent:GetHeight()) or 768
    local bottomPhysicalLimit = (screenH * 0.50) + 50
    local availableHeight = (qlTop or (screenH - 10)) - bottomPhysicalLimit
    local maxAllowedH = math_max(60, availableHeight)

    local contentH  = math_max(y, 20)
    content:SetHeight(contentH)
    local clipH = math_min(contentH, maxAllowedH)
    QL:SetHeight(clipH)
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
--  REFRESH ENTRY POINT
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

    CollectTrackedQuests(superTracked)
    local y = RenderSections(state, superTracked)
    UpdateScrollLayout(y, savedScroll)
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

function sfui.questlog.RequestRefresh()
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
            providers.ClearQuestCache(qID)
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
        providers.ClearWorldQuestCache()
        providers.ClearWarbandCache()
        UpdateMapCache()
        providers.PruneProgressCacheForWorldQuests()
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
        or event == "SCENARIO_CRITERIA_PROGRESS_UPDATE" or event == "SCENARIO_STAGE_UPDATE" then
        CheckVisibilityAndRefresh()

    elseif event == "UPDATE_UI_WIDGET" or event == "UPDATE_ALL_UI_WIDGETS" then
        local C_Sc = _G.C_Scenario
        if C_Sc and C_Sc.IsInScenario and C_Sc.IsInScenario() then
            CheckVisibilityAndRefresh()
        end

    elseif event == "QUEST_AUTOCOMPLETE" then
        local qID = arg1
        if qID and type(qID) == "number" and qID > 0 then
            local state = GetQLState()
            state.expandedQuests = state.expandedQuests or {}
            state.expandedQuests[qID] = true
        end
        CheckVisibilityAndRefresh()

    elseif event == "PERKS_ACTIVITIES_TRACKED_UPDATED" or event == "PERKS_ACTIVITIES_TRACKED_LIST_CHANGED" or event == "PERKS_ACTIVITY_COMPLETED"
        or event == "INITIATIVE_TASKS_TRACKED_UPDATED" or event == "INITIATIVE_TASKS_TRACKED_LIST_CHANGED" or event == "NEIGHBORHOOD_INITIATIVE_UPDATED"
        or event == "TRACKED_RECIPE_UPDATE" or event == "BAG_UPDATE_DELAYED" or event == "GROUP_ROSTER_UPDATE" or event == "QUEST_WATCH_UPDATE" then
        Refresh:Request()

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
Reg("QUEST_AUTOCOMPLETE")
Reg("QUEST_TURNED_IN")
Reg("QUEST_REMOVED")
Reg("QUEST_WATCH_UPDATE")
Reg("GROUP_ROSTER_UPDATE")
Reg("PERKS_ACTIVITIES_TRACKED_UPDATED")
Reg("PERKS_ACTIVITIES_TRACKED_LIST_CHANGED")
Reg("PERKS_ACTIVITY_COMPLETED")
Reg("INITIATIVE_TASKS_TRACKED_UPDATED")
Reg("INITIATIVE_TASKS_TRACKED_LIST_CHANGED")
Reg("NEIGHBORHOOD_INITIATIVE_UPDATED")
Reg("TRACKED_RECIPE_UPDATE")
Reg("BAG_UPDATE_DELAYED")
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
Reg("EVENT_SCHEDULER_UPDATE")
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
    local pCount, wCount, wqCount = providers.GetCacheCounts()

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

