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
        { id = "scenario",   label = "objectives",       color = { 0.85, 0.40, 1.00 } },
        { id = "important",  label = "important",        color = { 1.00, 0.40, 0.35 } },
        { id = "campaign",   label = "campaign",         color = { 0.90, 0.75, 0.10 } },
        { id = "world",      label = "world quests",     color = { 0.20, 0.85, 0.95 } },
        { id = "activities", label = "activities",       color = { 0.35, 0.90, 0.40 } },
        { id = "zone",       label = "quests",           color = { 1.00, 1.00, 1.00 } },
    },
}

--[[
    SFUI Quest Log (Midnight Edition)
    Collapsible quest log panel with integrated World Quests on top.
    Sections: important | campaign | world quests | activities | quests (white)
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
local tostring, tonumber, pcall = _G.tostring, _G.tonumber, _G.pcall
local wipe = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local issecretvalue = _G.issecretvalue or function() return false end
local QuestMapFrame_OpenToQuestDetails = _G.QuestMapFrame_OpenToQuestDetails
local ShowUIPanel, WorldMapFrame = _G.ShowUIPanel, _G.WorldMapFrame
local GetTasksTable = _G.GetTasksTable
local GetQuestLogSpecialItemInfo = _G.GetQuestLogSpecialItemInfo
local print = _G.print

-- Isolated Tooltip Frame (Zero global GameTooltip taint, zero UIWidgetManager registration)
local SfuiQuestTooltip = sfui.tooltip

-- Cache Enum Constants
local QC = Enum and Enum.QuestClassification
local QC_Campaign  = QC and QC.Campaign
local QC_Calling   = QC and QC.Calling
local QC_Important = QC and QC.Important
local QC_Legendary = QC and QC.Legendary
local QC_Recurring = QC and QC.Recurring

local QR = Enum and Enum.QuestRepeatability
local QR_Daily  = (QR and QR.Daily) or 1
local QR_Weekly = (QR and QR.Weekly) or 2

-- Layout constants from config
local FRAME_W    = qcfg.width or 280
local SECT_H     = qcfg.sectionHeight or 20
local QUEST_H    = qcfg.questHeight or 17
local OBJ_H      = qcfg.objectiveHeight or 13
local PAD_X      = 8
local OBJ_INDENT = 14
local THROTTLE   = qcfg.throttle or 0.05
local SECT_GAP   = 2
local QUEST_PAD  = 2

-- Pre-cached Formatting Strings
local ITEM_TAG_STRING   = "|TInterface\\Buttons\\WHITE8x8:6:6:0:0:8:8:0:8:0:8:102:0:255|t "
local COMPLETE_SUFFIX   = " |cff44cc44[Complete]|r"
local COLOR_SUPERTRACK  = "|cffffff00"
local COLOR_WARBAND     = "|cffa02020"
local COLOR_FAILED      = "|cffff4444"
local COLOR_DONE_CNT    = "|cff44cc44"
local COLOR_UNDONE_CNT  = "|cff777777"
local COLOR_TIME        = "|cff33d9f2"
local COLOR_RESET       = "|r"

-- Section definitions (display order)
local SECTION_DEFS = qcfg.sections or {
    { id = "scenario",   label = "objectives",       color = { 0.85, 0.40, 1.00 } },
    { id = "important",  label = "important",        color = { 1.00, 0.40, 0.35 } },
    { id = "campaign",   label = "campaign",         color = { 0.90, 0.75, 0.10 } },
    { id = "world",      label = "world quests",     color = { 0.20, 0.85, 0.95 } },
    { id = "activities", label = "activities",       color = { 0.35, 0.90, 0.40 } },
    { id = "zone",       label = "quests",           color = { 1.00, 1.00, 1.00 } },
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

function State:Update()
    local ok1, cm = pcall(function()
        return _G.C_ChallengeMode
            and _G.C_ChallengeMode.IsChallengeModeActive
            and _G.C_ChallengeMode.IsChallengeModeActive()
    end)
    if ok1 and cm then self._active = true; return end

    if _G.GetInstanceInfo then
        local ok2, _, _, difficultyID = pcall(_G.GetInstanceInfo)
        if ok2 and difficultyID == 8 then self._active = true; return end
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

function Refresh:Request()
    if _G.InCombatLockdown() or State:IsActive() then return end
    if _refreshPending then return end
    _refreshPending = true
    C_Timer.After(THROTTLE, function()
        _refreshPending = false
        if _G.InCombatLockdown() or State:IsActive() then return end
        if QL and QL.IsShown and QL:IsShown() then
            QL:DoRefresh()
        end
    end)
end

-- ─── Blizzard Root Tracker Hook ───────────────────────────
-- Following MidnightObjective (Tracker.lua:1686-1708):
-- Synchronous hook on ROOT ObjectiveTrackerFrame OnShow.
-- Keeps all module update cycles (ScenarioObjectiveTracker, ShouldShowMawBuffs,
-- GetAuraDataByIndex) 100% taint-free.
local _blizzardHookApplied = false
local _hidePending = false

local function ApplyBlizzardTrackerVisibility()
    if State:IsActive() then return end

    local root = _G.ObjectiveTrackerFrame
    if not root then return end
    if root.SetAlpha then root:SetAlpha(0) end
    if root.Hide then root:Hide() end
    if root.EnableMouse then root:EnableMouse(false) end
end

-- Install the OnShow hook exactly once so Blizzard can't re-show the tracker.
local function EnsureBlizzardTrackerHook()
    local root = _G.ObjectiveTrackerFrame
    if not root or _blizzardHookApplied then return end
    _blizzardHookApplied = true
    root:HookScript("OnShow", function(f)
        if not (sfui.questlog and sfui.questlog.is_enabled and sfui.questlog.is_enabled()) then return end
        if State:IsActive() then return end
        if _hidePending then return end
        _hidePending = true
        -- Defer re-hide by 1 tick so Blizzard's QuestSuperTracking and MapCanvas pin
        -- acquisition (SetPassThroughButtons) finish in a 100% untainted context.
        C_Timer.After(0, function()
            _hidePending = false
            if not (sfui.questlog and sfui.questlog.is_enabled and sfui.questlog.is_enabled()) then return end
            if State:IsActive() then return end
            if not f:IsShown() then return end
            if f.SetAlpha then f:SetAlpha(0) end
            f:Hide()
            if f.EnableMouse then f:EnableMouse(false) end
        end)
    end)
    if sfui.questlog and sfui.questlog.is_enabled and sfui.questlog.is_enabled() then
        ApplyBlizzardTrackerVisibility()
    end
end

-- Called every time we show our tracker — actively enforces suppression.
local function SuppressBlizzardTracker()
    EnsureBlizzardTrackerHook()
    ApplyBlizzardTrackerVisibility()
end

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
        if fn then pcall(fn) end
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

local tablePool = {}
local function AcquireTable()
    local t = table.remove(tablePool) or {}
    wipe(t)
    return t
end
local function ReleaseTable(t)
    if type(t) ~= "table" then return end
    if t.isScenario and t.objectives and type(t.objectives) == "table" then
        for i = #t.objectives, 1, -1 do
            local obj = table.remove(t.objectives, i)
            if type(obj) == "table" then
                wipe(obj)
                table.insert(tablePool, obj)
            end
        end
        wipe(t.objectives)
        table.insert(tablePool, t.objectives)
        t.objectives = nil
    end
    wipe(t)
    table.insert(tablePool, t)
end

-- Static section lists to eliminate table allocation on refresh
local sectionLists = {
    scenario   = {},
    world      = {},
    campaign   = {},
    important  = {},
    activities = {},
    zone       = {},
}
local renderedSectionQuests = {
    scenario   = {},
    world      = {},
    campaign   = {},
    important  = {},
    activities = {},
    zone       = {},
}
local processedQuests = {}

-- Saved state
local function GetQLState()
    if not SfuiDB then SfuiDB = {} end
    if not SfuiDB.questlog then
        SfuiDB.questlog = {
            collapsed      = {},
            expandedQuests = {},
            hidden         = false,
        }
    end
    SfuiDB.questlog.expandedQuests = SfuiDB.questlog.expandedQuests or {}
    SfuiDB.questlog.collapsed      = SfuiDB.questlog.collapsed or {}
    -- Wipe legacy hiddenQuests if present from old sessions
    SfuiDB.questlog.hiddenQuests   = nil
    if SfuiDB.questlog.hidden == nil then SfuiDB.questlog.hidden = false end
    return SfuiDB.questlog
end

local function UntrackQuest(questID)
    if not questID or questID <= 0 then return end

    -- Remove from Blizzard's watch list (source of truth).
    -- DoRefresh will see IsQuestWatched = false and drop it from the panel.
    if InCombat() then
        QueueOutOfCombatAction("untrack_" .. tostring(questID), function()
            if C_QuestLog.RemoveQuestWatch then
                pcall(C_QuestLog.RemoveQuestWatch, questID)
            end
            if C_QuestLog.RemoveWorldQuestWatch then
                pcall(C_QuestLog.RemoveWorldQuestWatch, questID)
            end
        end)
    else
        if C_QuestLog.RemoveQuestWatch then
            pcall(C_QuestLog.RemoveQuestWatch, questID)
        end
        if C_QuestLog.RemoveWorldQuestWatch then
            pcall(C_QuestLog.RemoveWorldQuestWatch, questID)
        end
        -- QUEST_WATCH_LIST_CHANGED fires immediately; DoRefresh picks up the change.
        -- No need to call DoRefresh manually.
    end
end

-- Check if a quest is a World Quest
local function IsWorldQuest(questID)
    if C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(questID) then
        return true
    end
    if _G.QuestUtils_IsQuestWorldQuest and _G.QuestUtils_IsQuestWorldQuest(questID) then
        return true
    end
    return false
end

-- Check if a quest is actively watched in Blizzard's quest watch system
local function IsQuestWatched(questID)
    if not questID or questID <= 0 then return false end
    if C_QuestLog.GetQuestWatchType then
        local ok, wt = pcall(C_QuestLog.GetQuestWatchType, questID)
        if ok and wt ~= nil then return true end
    end
    if C_QuestLog.IsQuestWatched then
        local ok, w = pcall(C_QuestLog.IsQuestWatched, questID)
        if ok and w then return true end
        if C_QuestLog.GetLogIndexForQuestID then
            local lIndex = C_QuestLog.GetLogIndexForQuestID(questID)
            if lIndex then
                local ok2, w2 = pcall(C_QuestLog.IsQuestWatched, lIndex)
                if ok2 and w2 then return true end
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
        local ok, v = pcall(C_QuestLog.IsQuestFlaggedCompletedOnAccount, questID)
        if ok and v then completed = true end
    end
    warbandCompleteCache[questID] = completed
    return completed
end

-- Classify standard quest → section ID (Fast Cached Enums)
local function ClassifyQuest(info, questID)
    if info.isTask or info.isBounty or IsWorldQuest(questID) then
        return "world"
    end
    if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification then
        local ok, cls = pcall(C_QuestInfoSystem.GetQuestClassification, questID)
        if ok and cls then
            if cls == QC_Campaign or cls == QC_Calling    then return "campaign"   end
            if cls == QC_Important or cls == QC_Legendary then return "important"  end
            if cls == QC_Recurring                        then return "activities" end
        end
    end
    if info.campaignID and info.campaignID > 0 then return "campaign" end
    if C_QuestLog.IsImportantQuest then
        local ok, v = pcall(C_QuestLog.IsImportantQuest, questID)
        if ok and v then return "important" end
    end
    local freq = info.frequency
    if freq == QR_Daily or freq == QR_Weekly or (freq and freq > 0) then
        return "activities"
    end
    return "zone"
end

local function UntrackSectionQuests(sectionID)
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
QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
QL:EnableMouse(true)
QL:SetFrameStrata("MEDIUM")
QL:SetFrameLevel(10)

-- Fully transparent outer backdrop
QL:SetBackdrop({ bgFile = [[Interface\ChatFrame\ChatFrameBackground]] })
QL:SetBackdropColor(0, 0, 0, 0)

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
    hdr:SetScript("OnEnter", function(s)
        s:SetBackdropColor(0.08, 0.08, 0.08, 0.65)
        SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
        SfuiQuestTooltip:ClearLines()
        SfuiQuestTooltip:AddLine(defLabel, def.color[1], def.color[2], def.color[3])
        SfuiQuestTooltip:AddLine("|cff888888Left-click: Collapse/Expand section|r", 1, 1, 1)
        SfuiQuestTooltip:AddLine("|cff888888Shift-click: Untrack all quests in category|r", 1, 1, 1)
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

        -- Title
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject("GameFontHighlightSmall")
        fs:SetPoint("LEFT",  row, "LEFT",  PAD_X + 11, 0)
        fs:SetPoint("RIGHT", row, "RIGHT", -PAD_X,     0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        row.TitleFS = fs

        -- Find Group Eye Button (Right edge)
        local findGroupBtn = CreateFrame("Button", nil, row)
        findGroupBtn:SetSize(14, 14)
        findGroupBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

        local eyeIcon = findGroupBtn:CreateTexture(nil, "ARTWORK")
        eyeIcon:SetSize(12, 12)
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
            if row.questID and _G.LFGListUtil_FindQuestGroup then
                pcall(_G.LFGListUtil_FindQuestGroup, row.questID, true)
            end
        end)
        findGroupBtn:Hide()
        row.FindGroupBtn = findGroupBtn

        row:SetScript("OnEnter", function(s)
            s.HLTex:SetColorTexture(1, 1, 1, 0.05)
            if s.questID then
                SfuiQuestTooltip:SetOwner(s, "ANCHOR_LEFT")
                SfuiQuestTooltip:ClearLines()

                if s.questID == -1 then
                    SfuiQuestTooltip:AddLine(s.questTitle or "Delve / Scenario", 1, 1, 1)
                    if s.scenarioCategory then
                        SfuiQuestTooltip:AddLine(s.scenarioCategory, 0.85, 0.40, 1.00)
                    end
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
                    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, s.questID)
                    if ok and objs and #objs > 0 then
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
                SfuiQuestTooltip:AddLine("|cff888888Shift-click: Untrack from Quest Log|r", 1, 1, 1)
                if s.canFindGroup then
                    SfuiQuestTooltip:AddLine("|cff00ff88Eye Button: Find Group in Group Finder|r", 1, 1, 1)
                end
                if not s.isWorldQuest then
                    SfuiQuestTooltip:AddLine("|cff888888Alt-click: Share Quest with Party|r", 1, 1, 1)
                    SfuiQuestTooltip:AddLine("|cff888888Ctrl-click: Abandon Quest|r", 1, 1, 1)
                end
                SfuiQuestTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(s)
            s.HLTex:SetColorTexture(1, 1, 1, 0)
            SfuiQuestTooltip:Hide()
        end)
        row:SetScript("OnClick", function(s, btn)
            if not s.questID then return end

            if s.questID == -1 then
                if btn == "RightButton" then
                    local state = GetQLState()
                    state.expandedQuests = state.expandedQuests or {}
                    state.expandedQuests[-1] = not state.expandedQuests[-1]
                    Refresh:Request()
                elseif _G.ToggleWorldMap then
                    if not InCombat() then
                        pcall(_G.ToggleWorldMap)
                    end
                end
                return
            end

            if btn == "RightButton" then
                -- Right-click: toggle collapse/expand of objectives
                local state = GetQLState()
                state.expandedQuests = state.expandedQuests or {}
                state.expandedQuests[s.questID] = not state.expandedQuests[s.questID]
                Refresh:Request()
                return
            end

            -- Alt-Click: Share Quest with Party (standard quests only)
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

            -- Ctrl-Click: Abandon Quest (standard quests only)
            local IsControlKeyDown = _G.IsControlKeyDown
            if IsControlKeyDown and IsControlKeyDown() and not s.isWorldQuest then
                if InCombat() then return end
                local QuestMapQuestOptions_AbandonQuest = _G.QuestMapQuestOptions_AbandonQuest
                if C_QuestLog.CanAbandonQuest and C_QuestLog.CanAbandonQuest(s.questID) then
                    pcall(C_QuestLog.SetSelectedQuest, s.questID)
                    pcall(C_QuestLog.AbandonQuest)
                end
                return
            end

            -- Shift-Click: Untrack / Hide quest (or insert link if chat editbox has focus)
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
                local ok, v = pcall(C_QuestLog.IsComplete, s.questID)
                if ok then isComplete = v end
            end

            local popUpType = nil
            if C_QuestLog.GetAutoQuestPopUpType then
                local ok, pt = pcall(C_QuestLog.GetAutoQuestPopUpType, s.questID)
                if ok then popUpType = pt end
            end

            if popUpType == "OFFER" and _G.ShowQuestOffer then
                pcall(_G.ShowQuestOffer, s.questID)
                return
            elseif (popUpType == "COMPLETE" or (isAutoComplete and isComplete)) and _G.ShowQuestComplete then
                pcall(_G.ShowQuestComplete, s.questID)
                return
            end

            -- 2. Standard Quest: Open in Map & Quest Log details + SuperTrack
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
                pcall(function() C_SuperTrack.SetSuperTrackedQuestID(s.questID) end)
            end
            if C_QuestLog.SetSelectedQuest then
                pcall(C_QuestLog.SetSelectedQuest, s.questID)
            end
            if QuestMapFrame_OpenToQuestDetails then
                pcall(QuestMapFrame_OpenToQuestDetails, s.questID)
            elseif ShowUIPanel and WorldMapFrame then
                ShowUIPanel(WorldMapFrame)
            end
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
        local fs = obj:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject("GameFontHighlightSmall")
        fs:SetPoint("LEFT",  obj, "LEFT",  2,      0)
        fs:SetPoint("RIGHT", obj, "RIGHT", -PAD_X, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        obj.FS = fs
    end
    obj:Show()
    table.insert(activeObjs, obj)
    return obj
end

local function ClearRows()
    for i = #activeRows, 1, -1 do
        local r = table.remove(activeRows, i)
        r:Hide()
        r:ClearAllPoints()
        table.insert(rowPool, r)
    end
    for i = #activeObjs, 1, -1 do
        local r = table.remove(activeObjs, i)
        r:Hide()
        r:ClearAllPoints()
        table.insert(objPool, r)
    end
end

-- ─── Panel Anchor (Clean, isolated, zero-taint anchor) ────
UpdateQuestLogAnchor = function()
    if not QL then return 758 end
    if InCombat() or State:IsActive() then return QL.lastTop or 758 end

    local parentTop = (UIParent and UIParent:GetTop()) or 768
    QL:ClearAllPoints()
    QL:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
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
        local ok, v = pcall(C_QuestLog.IsComplete, questID)
        if ok then isComplete = v end
    end
    if C_QuestLog.IsFailed then
        local ok, v = pcall(C_QuestLog.IsFailed, questID)
        if ok then isFailed = v end
    end

    local objs = nil
    if C_QuestLog.GetQuestObjectives then
        local ok, v = pcall(C_QuestLog.GetQuestObjectives, questID)
        if ok and v and #v > 0 then objs = v end
    end

    if not objs or #objs == 0 then
        if C_TaskQuest and C_TaskQuest.GetQuestProgressBarInfo then
            local ok, pct = pcall(C_TaskQuest.GetQuestProgressBarInfo, questID)
            if ok and pct and pct > 0 then
                objs = { { text = string.format("%d%%", pct), finished = (pct >= 100), numFulfilled = pct, numRequired = 100 } }
            end
        end
    end

    local done, total = 0, 0
    local singleCountStr = nil
    local progressHash = (isComplete and 1 or 0) * 10000000

    if objs and #objs == 1 then
        local obj = objs[1]
        total = 1
        if obj.finished then done = 1 end

        local cur = obj.numFulfilled or 0
        local req = obj.numRequired or 0
        progressHash = progressHash + (cur * 1000) + req + (obj.finished and 1 or 0)

        if req > 1 then
            singleCountStr = tostring(cur) .. "/" .. tostring(req)
        elseif obj.text and obj.text ~= "" then
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
            progressHash = progressHash + (idx * 10000) + (cur * 100) + req + (obj.finished and 1 or 0)
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

        if state.hiddenQuests then
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
            local ok, t = pcall(C_TaskQuest.GetQuestInfoByQuestID, questID)
            if ok and t and t ~= "" then title = t end
        end
        if (not title or title == "") and C_QuestLog.GetTitleForQuestID then
            local ok, t = pcall(C_QuestLog.GetTitleForQuestID, questID)
            if ok and t and t ~= "" then title = t end
        end
        if (not title or title == "") and _G.QuestUtils_GetQuestName then
            local ok, t = pcall(_G.QuestUtils_GetQuestName, questID)
            if ok and t and t ~= "" then title = t end
        end
    end
    title = title or "Unknown Quest"

    local timeLeftText = nil
    local isWorld = (forcedSectionID == "world" or IsWorldQuest(questID))

    if isWorld then
        if C_TaskQuest and C_TaskQuest.GetQuestTimeLeftMinutes then
            local ok, mins = pcall(C_TaskQuest.GetQuestTimeLeftMinutes, questID)
            if ok and mins and mins > 0 then
                if mins >= 1440 then
                    local d = math_floor(mins / 1440)
                    local h = math_floor((mins % 1440) / 60)
                    if h > 0 then
                        timeLeftText = string.format("%dd %dh", d, h)
                    else
                        timeLeftText = string.format("%dd", d)
                    end
                elseif mins >= 60 then
                    local h = math_floor(mins / 60)
                    local m = mins % 60
                    if m > 0 then
                        timeLeftText = string.format("%dh %dm", h, m)
                    else
                        timeLeftText = string.format("%dh", h)
                    end
                else
                    timeLeftText = string.format("%dm", mins)
                end
            end
        end
    end

    local hasItem = false
    local logIndex = defaultInfo and defaultInfo.questLogIndex
    if not logIndex and C_QuestLog.GetLogIndexForQuestID then
        logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
    end
    if logIndex and GetQuestLogSpecialItemInfo then
        local ok, l, tex = pcall(GetQuestLogSpecialItemInfo, logIndex)
        if ok and (tex or l) then
            hasItem = true
        end
    end

    local isAutoComplete = defaultInfo and defaultInfo.isAutoComplete
    if isAutoComplete == nil and C_QuestLog.GetInfo then
        local lIndex = logIndex or (C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID))
        if lIndex then
            local ok, info = pcall(C_QuestLog.GetInfo, lIndex)
            if ok and info then isAutoComplete = info.isAutoComplete end
        end
    end
    if isAutoComplete == nil and _G.QuestCache and _G.QuestCache.Get then
        local ok, qObj = pcall(_G.QuestCache.Get, _G.QuestCache, questID)
        if ok and qObj then isAutoComplete = qObj.isAutoComplete end
    end

    local isWarbandCompleted = IsQuestWarbandCompleted(questID)
    local canFindGroup = (defaultInfo and defaultInfo.suggestedGroup and defaultInfo.suggestedGroup > 1) or false

    local entry = AcquireTable()
    entry.questID            = questID
    entry.title              = title
    entry.isComplete         = isComplete
    entry.isFailed           = isFailed
    entry.isAutoComplete     = isAutoComplete
    entry.isWarbandCompleted = isWarbandCompleted
    entry.canFindGroup       = canFindGroup
    entry.objectives         = objs
    entry.done               = done
    entry.total              = total
    entry.singleCountStr     = singleCountStr
    entry.isWorldQuest       = isWorld
    entry.timeLeftText       = timeLeftText
    entry.hasItem            = hasItem
    entry.isScenario         = false
    return entry
end

-- ─── SCENARIO / DELVE HELPER ─────────────────────────────
local function BuildScenarioEntry()
    if not (C_Scenario and C_Scenario.IsInScenario and C_Scenario.IsInScenario()) then
        return nil
    end

    local scenarioName, currentStage, numStages, _, _, _, _, _, _, scenarioType, _, textureKit = C_Scenario.GetInfo()
    if not (scenarioName and currentStage and currentStage > 0) then
        return nil
    end

    local stageName, stageDesc, numCriteria
    if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
        local step = C_ScenarioInfo.GetScenarioStepInfo()
        if type(step) == "table" then
            stageName = step.title
            stageDesc = step.description
            numCriteria = step.numCriteria
        end
    elseif C_Scenario.GetStepInfo then
        stageName, stageDesc, numCriteria = C_Scenario.GetStepInfo()
    end

    local isDelve = (scenarioType == 8) or (textureKit and textureKit:lower():find("delve"))
    local category = "Scenario"
    if isDelve then
        category = "Delve"
    elseif scenarioType == 1 then
        category = "Mythic+"
    elseif scenarioType == 5 then
        category = "Dungeon"
    end

    local title = stageName or scenarioName or "Objective"
    if numStages and numStages > 1 then
        title = string.format("Stage %d/%d: %s", currentStage, numStages, stageName or scenarioName)
    end

    local objs = AcquireTable()
    local done, total = 0, 0
    local getCriteria = (C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo) or (C_Scenario and C_Scenario.GetCriteriaInfo)

    if getCriteria and numCriteria and numCriteria > 0 then
        for i = 1, numCriteria do
            local ok, result = pcall(getCriteria, i)
            if ok and result then
                local desc, completed, quantity, totalQuantity, failed, isWeighted
                if type(result) == "table" then
                    desc = result.description or result.criteriaString or ""
                    completed = result.completed
                    quantity = result.quantity or 0
                    totalQuantity = result.totalQuantity or 0
                    failed = result.failed
                    isWeighted = result.isWeightedProgress
                else
                    desc, _, completed, quantity, totalQuantity, _, _, _, _, _, _, failed = getCriteria(i)
                end

                if desc and desc ~= "" then
                    total = total + 1
                    if completed then done = done + 1 end
                    local countStr = nil
                    if isWeighted then
                        countStr = string.format("%d%%", quantity)
                    elseif totalQuantity and totalQuantity > 1 then
                        countStr = string.format("%d/%d", quantity, totalQuantity)
                    end

                    local fullText = desc
                    if countStr and not desc:find(countStr, 1, true) then
                        fullText = desc .. " (" .. countStr .. ")"
                    end

                    local objEntry = AcquireTable()
                    objEntry.text = fullText
                    objEntry.finished = completed and true or false
                    objEntry.numFulfilled = quantity
                    objEntry.numRequired = totalQuantity
                    table.insert(objs, objEntry)
                end
            end
        end
    end

    local entry = AcquireTable()
    entry.questID            = -1
    entry.title              = title
    entry.isComplete         = (total > 0 and done == total)
    entry.isFailed           = false
    entry.isAutoComplete     = false
    entry.isWarbandCompleted = false
    entry.canFindGroup       = false
    entry.objectives         = objs
    entry.done               = done
    entry.total              = total
    entry.singleCountStr     = nil
    entry.isWorldQuest       = false
    entry.timeLeftText       = nil
    entry.hasItem            = false
    entry.isScenario         = true
    entry.scenarioCategory   = category
    return entry
end

-- ─────────────────────────────────────────────────────────
--  REFRESH (Zero Allocation Loop)
-- ─────────────────────────────────────────────────────────
function QL:DoRefresh()
    if not self:IsShown() or State:IsActive() then return end

    local savedScroll = scrollBar:GetValue()
    ClearRows()

    local state        = GetQLState()
    local superTracked = (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and
                          C_SuperTrack.GetSuperTrackedQuestID()) or 0
    currentSuperTrackedID = superTracked

    for _, def in ipairs(SECTION_DEFS) do
        wipe(sectionLists[def.id])
    end
    wipe(processedQuests)

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

    -- Helper: add a world quest/task to the world section (only if tracked or has progress)
    local function AddWorldQuest(qID, isExplicitlyWatched)
        if qID and qID > 0 and not processedQuests[qID] then
            local entry = BuildQuestEntry(qID, "world", nil)
            if entry then
                local isWatched = isExplicitlyWatched or (superTracked and superTracked == qID)
                if isWatched or QuestHasProgress(entry) then
                    processedQuests[qID] = true
                    table.insert(sectionLists["world"], entry)
                else
                    ReleaseTable(entry)
                end
            end
        end
    end

    -- 1. Delve / Scenario objectives
    local scenEntry = BuildScenarioEntry()
    if scenEntry then
        table.insert(sectionLists["scenario"], scenEntry)
    end

    -- 2. Active local-area tasks & world events (GetTasksTable) — only if has progress
    if GetTasksTable then
        local ok, tasks = pcall(GetTasksTable)
        if ok and tasks then
            for i = 1, #tasks do
                AddWorldQuest(tasks[i], false)
            end
        end
    end

    -- 3. In-zone World Quests and Bonus Objectives from current map (Outdoors only) — only if has progress
    local inInstance = _G.IsInInstance and _G.IsInInstance()
    if not inInstance and cachedCurrentMapID and C_TaskQuest then
        UpdateMapCache()
        local taskQuests = nil
        if C_TaskQuest.GetQuestsOnMap then
            taskQuests = C_TaskQuest.GetQuestsOnMap(cachedCurrentMapID)
        elseif C_TaskQuest.GetQuestsForPlayerByMapID then
            taskQuests = C_TaskQuest.GetQuestsForPlayerByMapID(cachedCurrentMapID)
        end
        if taskQuests then
            for _, task in ipairs(taskQuests) do
                local qID = task.questID or task
                if qID and type(qID) == "number" and qID > 0 then
                    if C_TaskQuest.IsActive and C_TaskQuest.IsActive(qID) then
                        AddWorldQuest(qID, false)
                    end
                end
            end
        end
    end

    -- 4. Explicitly watched world quests (always shown)
    if C_QuestLog.GetNumWorldQuestWatches then
        local numW = C_QuestLog.GetNumWorldQuestWatches() or 0
        for w = 1, numW do
            local qID = C_QuestLog.GetQuestIDForWorldQuestWatchIndex(w)
            if qID and qID > 0 then
                AddWorldQuest(qID, true)
            end
        end
    end

    -- 5. Watched standard quests from Blizzard watch index
    if C_QuestLog.GetNumQuestWatches then
        local numW = C_QuestLog.GetNumQuestWatches() or 0
        for w = 1, numW do
            local qID = C_QuestLog.GetQuestIDForQuestWatchIndex(w)
            if qID and qID > 0 and not processedQuests[qID] then
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

    -- 6. Standard quest log scan — show any quest that is watched or supertracked
    local numEntries = C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, numEntries do
        if not C_QuestLog.GetInfo then break end
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden then
            local questID = info.questID
            if questID and questID > 0 and not processedQuests[questID] then
                local isTask = info.isTask or info.isBounty or IsWorldQuest(questID) or (C_QuestLog.IsQuestTask and C_QuestLog.IsQuestTask(questID))
                if isTask then
                    AddWorldQuest(questID, IsQuestWatched(questID))
                elseif IsQuestWatched(questID) or (superTracked and superTracked == questID) then
                    processedQuests[questID] = true
                    local sid = ClassifyQuest(info, questID)
                    local entry = BuildQuestEntry(questID, sid, info)
                    table.insert(sectionLists[sid], entry)
                end
            end
        end
    end

    -- Smart Priority Sort within each active section
    for _, def in ipairs(SECTION_DEFS) do
        local list = sectionLists[def.id]
        if #list > 1 and def.id ~= "scenario" then
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
                    row.questTitle         = entry.title
                    row.isWorldQuest       = entry.isWorldQuest
                    row.timeLeftText       = entry.timeLeftText
                    row.isWarbandCompleted = entry.isWarbandCompleted
                    row.isAutoComplete     = entry.isAutoComplete
                    row.isComplete         = entry.isComplete
                    row.canFindGroup       = entry.canFindGroup

                    if entry.canFindGroup then
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

                    local itemTag = entry.hasItem and ITEM_TAG_STRING or ""
                    local titleColor
                    if isSuperTracked then
                        titleColor = COLOR_SUPERTRACK
                    elseif entry.isWarbandCompleted then
                        titleColor = COLOR_WARBAND
                    end
                    local rawTitle = entry.title or "Unknown Quest"
                    local titleText = titleColor and (titleColor .. rawTitle .. COLOR_RESET) or rawTitle
                    local timeTag = (entry.isWorldQuest and entry.timeLeftText) and (" " .. COLOR_TIME .. "[" .. entry.timeLeftText .. "]" .. COLOR_RESET) or ""

                    local titleStr
                    if entry.isFailed then
                        titleStr = itemTag .. COLOR_FAILED .. rawTitle .. COLOR_RESET .. timeTag
                    elseif entry.isComplete and entry.isAutoComplete then
                        titleStr = itemTag .. titleText .. timeTag .. " |cff00ff00[Click to Complete]|r"
                    elseif entry.isComplete then
                        titleStr = itemTag .. titleText .. timeTag .. COMPLETE_SUFFIX
                    elseif entry.singleCountStr then
                        local isFin = (entry.done == entry.total)
                        local col = isFin and COLOR_DONE_CNT or COLOR_UNDONE_CNT
                        titleStr = itemTag .. titleText .. timeTag .. " " .. col .. "[" .. entry.singleCountStr .. "]" .. COLOR_RESET
                    elseif entry.total > 0 then
                        local col = (entry.done == entry.total) and COLOR_DONE_CNT or COLOR_UNDONE_CNT
                        titleStr = itemTag .. titleText .. timeTag .. " " .. col .. "[" .. entry.done .. "/" .. entry.total .. "]" .. COLOR_RESET
                    else
                        titleStr = itemTag .. titleText .. timeTag
                    end

                    if row.lastTitleStr ~= titleStr then
                        row.lastTitleStr = titleStr
                        row.TitleFS:SetText(titleStr)
                    end
                    y = y + QUEST_H

                    local hasObjectives = (entry.objectives and #entry.objectives > 0 and not entry.isComplete)
                    local isQuestExpanded = state.expandedQuests and state.expandedQuests[entry.questID]
                    if isQuestExpanded == nil and entry.isScenario then
                        isQuestExpanded = true
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
                                orow:SetHeight(OBJ_H)
                                local r, g, b = 0.45, 0.45, 0.45
                                if obj.finished then r, g, b = 0.25, 0.70, 0.25 end
                                local objStr = "- " .. obj.text
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
        local root = _G.ObjectiveTrackerFrame
        if root then
            if root.SetAlpha then root:SetAlpha(1) end
            if root.Show then root:Show() end
            if root.EnableMouse then root:EnableMouse(true) end
        end
    end
end

function sfui.questlog.toggle()
    if not sfui.questlog.is_enabled() then return end
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

function sfui.questlog.unhide_all()
    local state = GetQLState()
    state.hiddenQuests = {}
    Refresh:Request()
end

function sfui.questlog.initialize()
    if not sfui.questlog.is_enabled() then
        QL:Hide()
        local root = _G.ObjectiveTrackerFrame
        if root then
            if root.SetAlpha then root:SetAlpha(1) end
            if root.Show then root:Show() end
            if root.EnableMouse then root:EnableMouse(true) end
        end
        return
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
local function CheckVisibilityAndRefresh()
    if not sfui.questlog.is_enabled() then
        if QL:IsShown() then QL:Hide() end
        return
    end

    State:Update()
    if State:IsActive() then
        if QL:IsShown() then QL:Hide() end
        return
    end

    SuppressBlizzardTracker()
    UpdateQuestLogAnchor()
    local state = GetQLState()

    if not state.hidden then
        QL:Show()
        Refresh:Request()
    else
        QL:Hide()
    end
end

QL:SetScript("OnEvent", function(_, event, arg1, arg2)
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
        UpdateQuestLogAnchor()
        Refresh:Request()

    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        cachedCurrentMapID = nil
        cachedParentMapID  = nil
        UpdateMapCache()
        for qID in pairs(questProgressCache) do
            if IsWorldQuest(qID) or (C_QuestLog.IsQuestTask and C_QuestLog.IsQuestTask(qID)) then
                questProgressCache[qID] = nil
            end
        end
        CheckVisibilityAndRefresh()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        _refreshPending = false  -- cancel any queued refresh

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        FlushOutOfCombatQueue()
        SuppressBlizzardTracker()
        CheckVisibilityAndRefresh()

    elseif event == "SCENARIO_UPDATE" or event == "SCENARIO_CRITERIA_UPDATE" or event == "SCENARIO_POI_UPDATE"
        or event == "SCENARIO_SPELL_UPDATE" or event == "SCENARIO_CRITERIA_SHOW_STATE_UPDATE"
        or event == "SCENARIO_COMPLETED" or event == "ACTIVE_DELVE_DATA_UPDATE" then
        Refresh:Request()

    else
        Refresh:Request()
    end
end)

-- pcall-wrapped registration (safe against removed/renamed events per MidnightObjective pattern)
local function Reg(e) pcall(QL.RegisterEvent, QL, e) end

Reg("PLAYER_LOGIN")
Reg("PLAYER_REGEN_DISABLED")
Reg("PLAYER_REGEN_ENABLED")
Reg("ADDON_LOADED")
Reg("QUEST_LOG_UPDATE")
Reg("QUEST_WATCH_LIST_CHANGED")
Reg("QUEST_ACCEPTED")
Reg("QUEST_TURNED_IN")
Reg("QUEST_REMOVED")
Reg("TASK_PROGRESS_UPDATE")
Reg("SCENARIO_UPDATE")
Reg("SCENARIO_CRITERIA_UPDATE")
Reg("SCENARIO_POI_UPDATE")
Reg("SCENARIO_SPELL_UPDATE")
Reg("SCENARIO_CRITERIA_SHOW_STATE_UPDATE")
Reg("SCENARIO_COMPLETED")
Reg("ACTIVE_DELVE_DATA_UPDATE")
Reg("CHALLENGE_MODE_START")
Reg("CHALLENGE_MODE_COMPLETED")
Reg("CHALLENGE_MODE_RESET")
Reg("ZONE_CHANGED_NEW_AREA")
Reg("ZONE_CHANGED")
Reg("ZONE_CHANGED_INDOORS")
Reg("SUPER_TRACKING_CHANGED")
Reg("PLAYER_ENTERING_WORLD")

-- ─────────────────────────────────────────────────────────
--  SLASH COMMAND
-- ─────────────────────────────────────────────────────────
SLASH_SFQL1 = "/sfql"
SLASH_SFQL2 = "/sfquestlog"
SlashCmdList["SFQL"] = function(msg)
    local clean = msg and _G.strtrim and _G.strtrim(msg):lower() or (msg and msg:lower() or "")
    if clean == "reset" or clean == "unhide" then
        sfui.questlog.unhide_all()
        return
    end
    sfui.questlog.toggle()
end
