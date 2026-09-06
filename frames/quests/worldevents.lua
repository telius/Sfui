local addonName, addon = ...
sfui = sfui or {}
sfui.worldevents = sfui.worldevents or {}

local g      = sfui.config
local common = sfui.common
local cfg    = g.worldevents or {}

-- ─── Localize Globals for Zero-Taint & High Performance ─────────────────────
local _G                   = _G
local C_EventScheduler     = _G.C_EventScheduler
local C_AreaPoiInfo        = _G.C_AreaPoiInfo
local C_SuperTrack         = _G.C_SuperTrack
local C_Map                = _G.C_Map
local C_Timer              = _G.C_Timer
local Enum                 = _G.Enum
local InCombatLockdown     = _G.InCombatLockdown
local time                 = _G.time
local wipe                 = _G.wipe
local ipairs, pairs        = _G.ipairs, _G.pairs
local type                 = _G.type
local tostring, tonumber   = _G.tostring, _G.tonumber
local math_min, math_max   = math.min, math.max
local math_floor           = math.floor
local table_insert         = table.insert
local table_sort           = table.sort
local table_remove         = table.remove
local string_format        = string.format
local issecretvalue        = (common and common.issecretvalue) or function() return false end

-- ─── Zero-Allocation Table Pool ─────────────────────────────────────────────
local MAX_TABLE_POOL = 30
local tablePool      = {}

local function AcquireTable()
    local t = table_remove(tablePool) or {}
    wipe(t)
    return t
end

local function ReleaseTable(t)
    if type(t) ~= "table" then return end
    wipe(t)
    if #tablePool < MAX_TABLE_POOL then
        tablePool[#tablePool + 1] = t
    end
end

-- ─── Module State & Caching ─────────────────────────────────────────────────
local cachedEvents    = {}
local seenPoi         = {}
local poiNameCache    = {}
local poiAtlasCache   = {}
local poiZoneCache    = {}
local poiMapCache     = {}
local isDirty         = true
local lastUpdateTime  = 0
local reminderCount   = 0

local function FormatTimerSeconds(sec)
    if not sec or sec <= 0 then return "now" end
    sec = math_floor(sec)
    if sec >= 3600 then
        local h = math_floor(sec / 3600)
        local m = math_floor((sec % 3600) / 60)
        return (m > 0) and string_format("%dh %dm", h, m) or string_format("%dh", h)
    elseif sec >= 60 then
        return string_format("%dm", math_floor(sec / 60))
    else
        return string_format("%ds", sec)
    end
end

local function FormatEventTime(ev, now)
    now = now or time()
    if ev.isOngoing then
        if ev.endTime and ev.endTime > now then
            local rem = ev.endTime - now
            local formatted = FormatTimerSeconds(rem)
            ev.remText = formatted
            return "Ends in " .. formatted, rem
        else
            ev.remText = "now"
            return "Active Now", 0
        end
    else
        local toStart = (ev.startTime or now) - now
        if toStart <= 0 then
            ev.remText = "now"
            return "Active Now", 0
        else
            local formatted = FormatTimerSeconds(toStart)
            ev.remText = formatted
            return "Starts in " .. formatted, toStart
        end
    end
end

function sfui.worldevents.is_enabled()
    if SfuiDB and SfuiDB.worldevents and SfuiDB.worldevents.enabled ~= nil then
        return SfuiDB.worldevents.enabled
    end
    return cfg.enabled ~= false
end

-- ─── POI & Event Info Resolver (Zero-Allocation Flat Cache) ─────────────────
local function ResolvePoiDetails(areaPoiID, displayInfo)
    if not areaPoiID or areaPoiID <= 0 then return nil end

    local name = poiNameCache[areaPoiID]
    if name then
        local atlas = (displayInfo and displayInfo.overrideAtlas and not issecretvalue(displayInfo.overrideAtlas) and displayInfo.overrideAtlas) or poiAtlasCache[areaPoiID]
        return name, atlas, poiZoneCache[areaPoiID], poiMapCache[areaPoiID]
    end

    local uiMapID = C_EventScheduler and C_EventScheduler.GetEventUiMapID and C_EventScheduler.GetEventUiMapID(areaPoiID)
    local poiInfo = nil
    if C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo then
        if uiMapID then
            poiInfo = C_AreaPoiInfo.GetAreaPOIInfo(uiMapID, areaPoiID)
        end
        if not poiInfo then
            poiInfo = C_AreaPoiInfo.GetAreaPOIInfo(nil, areaPoiID)
        end
    end

    name = (poiInfo and poiInfo.name and not issecretvalue(poiInfo.name) and poiInfo.name)
    local atlas = (displayInfo and displayInfo.overrideAtlas and not issecretvalue(displayInfo.overrideAtlas) and displayInfo.overrideAtlas)
               or (poiInfo and poiInfo.atlasName and not issecretvalue(poiInfo.atlasName) and poiInfo.atlasName)

    local zoneName = C_EventScheduler and C_EventScheduler.GetEventZoneName and C_EventScheduler.GetEventZoneName(areaPoiID)
    if not zoneName and uiMapID and C_Map and C_Map.GetMapInfo then
        local mapInfo = C_Map.GetMapInfo(uiMapID)
        zoneName = mapInfo and mapInfo.name
    end

    name = name or zoneName or "World Event"

    poiNameCache[areaPoiID]  = name
    poiAtlasCache[areaPoiID] = atlas
    poiZoneCache[areaPoiID]  = zoneName
    poiMapCache[areaPoiID]   = uiMapID

    return name, atlas, zoneName, uiMapID
end

-- ─── Event Sort Comparator ──────────────────────────────────────────────────
local function EventSortComparator(a, b)
    -- 1. Ongoing active events first
    if a.isOngoing ~= b.isOngoing then
        return a.isOngoing == true
    end

    -- 2. Within ongoing, nearest ending time first
    if a.isOngoing and b.isOngoing then
        local aEnd = a.endTime or 0
        local bEnd = b.endTime or 0
        if aEnd ~= bEnd then return aEnd < bEnd end
    end

    -- 3. Reminders take precedence
    if a.hasReminder ~= b.hasReminder then
        return a.hasReminder == true
    end

    -- 4. Upcoming events sort by start time ascending
    local aStart = a.startTime or 0
    local bStart = b.startTime or 0
    if aStart ~= bStart then return aStart < bStart end

    return (a.name or "") < (b.name or "")
end

-- ─── Update Events Cache ────────────────────────────────────────────────────
function sfui.worldevents.UpdateEventsData()
    if not sfui.worldevents.is_enabled() then
        for i = #cachedEvents, 1, -1 do
            ReleaseTable(table_remove(cachedEvents, i))
        end
        reminderCount = 0
        isDirty = false
        return
    end

    if not C_EventScheduler or not C_EventScheduler.CanShowEvents or not C_EventScheduler.CanShowEvents() then
        for i = #cachedEvents, 1, -1 do
            ReleaseTable(table_remove(cachedEvents, i))
        end
        reminderCount = 0
        isDirty = false
        return
    end

    -- Request events from server if data isn't ready
    if C_EventScheduler.HasData and not C_EventScheduler.HasData() and C_EventScheduler.RequestEvents then
        C_EventScheduler.RequestEvents()
    end

    local remindersOnly = (cfg.show_reminders_only ~= false)
    if SfuiDB and SfuiDB.worldevents and SfuiDB.worldevents.show_reminders_only ~= nil then
        remindersOnly = SfuiDB.worldevents.show_reminders_only
    end

    local now = time()
    reminderCount = 0

    -- Clear old cached items back into pool
    for i = #cachedEvents, 1, -1 do
        ReleaseTable(table_remove(cachedEvents, i))
    end

    -- Check if player has focused an event on the map
    local superTrackedPOI = 0
    if C_SuperTrack and C_SuperTrack.GetSuperTrackedMapPin and Enum and Enum.SuperTrackingMapPinType and Enum.SuperTrackingMapPinType.AreaPOI then
        local _, pID = C_SuperTrack.GetSuperTrackedMapPin(Enum.SuperTrackingMapPinType.AreaPOI)
        superTrackedPOI = pID or 0
    end

    local showOngoing    = not remindersOnly and (cfg.show_ongoing ~= false)
    local maxUpcomingSec = (cfg.max_upcoming_minutes or 60) * 60
    local maxLimit       = cfg.max_events or 5
    wipe(seenPoi)

    -- 1. Ongoing Events
    if C_EventScheduler.GetOngoingEvents then
        local ongoingList = C_EventScheduler.GetOngoingEvents()
        if ongoingList then
            for _, oEvent in ipairs(ongoingList) do
                local pID = oEvent.areaPoiID
                if pID and not seenPoi[pID] then
                    local isFocused = (superTrackedPOI > 0 and pID == superTrackedPOI)
                    local isEligible = showOngoing or isFocused
                    if isEligible then
                        local name, atlas, zoneName, uiMapID = ResolvePoiDetails(pID, oEvent.displayInfo)
                        if name then
                            seenPoi[pID] = true
                            local item = AcquireTable()
                            item.eventKey     = "ongoing_" .. tostring(pID)
                            item.areaPoiID    = pID
                            item.uiMapID      = uiMapID
                            item.name         = name
                            item.atlasName    = atlas
                            item.zoneName     = zoneName
                            item.isOngoing    = true
                            item.hasReminder  = false
                            item.startTime    = now
                            item.endTime      = 0
                            item.timeLeftText = "Active Now"
                            item.remText      = "now"
                            table_insert(cachedEvents, item)
                        end
                    end
                end
            end
        end
    end

    -- 2. Scheduled Events (Upcoming & Reminded & Focused)
    if C_EventScheduler.GetScheduledEvents then
        local scheduledList = C_EventScheduler.GetScheduledEvents()
        if scheduledList then
            for _, sEvent in ipairs(scheduledList) do
                local hasReminder = (sEvent.hasReminder == true)
                if hasReminder then
                    reminderCount = reminderCount + 1
                end

                local toStart = (sEvent.startTime or now) - now
                local toEnd   = (sEvent.endTime or now) - now
                local isCurrentlyActive = (toStart <= 0 and toEnd > 0)
                local isFocused = (superTrackedPOI > 0 and sEvent.areaPoiID == superTrackedPOI)

                local isEligible = false
                if remindersOnly then
                    isEligible = hasReminder or isFocused
                else
                    isEligible = hasReminder or isFocused or isCurrentlyActive or (toStart > 0 and toStart <= maxUpcomingSec)
                end

                local pID = sEvent.areaPoiID
                if isEligible and pID and not seenPoi[pID] then
                    local name, atlas, zoneName, uiMapID = ResolvePoiDetails(pID, sEvent.displayInfo)
                    if name then
                        seenPoi[pID] = true
                        local item = AcquireTable()
                        item.eventKey     = sEvent.eventKey or ("sched_" .. tostring(sEvent.eventID or pID))
                        item.areaPoiID    = pID
                        item.uiMapID      = uiMapID
                        item.name         = name
                        item.atlasName    = atlas
                        item.zoneName     = zoneName
                        item.startTime    = sEvent.startTime
                        item.endTime      = sEvent.endTime
                        item.hasReminder  = hasReminder
                        item.isOngoing    = isCurrentlyActive
                        item.timeLeftText = FormatEventTime(item, now)
                        table_insert(cachedEvents, item)
                    end
                end
            end
        end
    end

    -- 3. Sort & Trim
    if #cachedEvents > 1 then
        table_sort(cachedEvents, EventSortComparator)
    end

    while #cachedEvents > maxLimit do
        ReleaseTable(table_remove(cachedEvents))
    end

    lastUpdateTime = now
    isDirty = false
end

function sfui.worldevents.RequestUpdate()
    isDirty = true
    sfui.worldevents.UpdateEventsData()
    if sfui.questlog and sfui.questlog.RequestRefresh then
        sfui.questlog.RequestRefresh()
    end
end

-- ─── Throttled Update Loop (5-Second Timer Countdown Ticks) ─────────────────
function sfui.worldevents.OnTimerTick(elapsed)
    if not sfui.worldevents.is_enabled() or #cachedEvents == 0 then return end

    local now = time()
    local needsRebuild = false
    local anyTextChanged = false

    for _, ev in ipairs(cachedEvents) do
        local oldText = ev.timeLeftText
        local newText, remSec = FormatEventTime(ev, now)
        if oldText ~= newText then
            ev.timeLeftText = newText
            anyTextChanged = true
        end

        -- If an event transitions from upcoming to started, or ongoing to expired
        if ev.isOngoing and ev.endTime and ev.endTime > 0 and (ev.endTime - now <= 0) then
            needsRebuild = true
        elseif not ev.isOngoing and ev.startTime and ev.startTime > 0 and (ev.startTime - now <= 0) then
            needsRebuild = true
        end
    end

    if needsRebuild or isDirty then
        sfui.worldevents.RequestUpdate()
    elseif anyTextChanged and sfui.questlog and sfui.questlog.RequestRefresh then
        sfui.questlog.RequestRefresh()
    end
end

-- ─── Public Section Population for quests.lua ───────────────────────────────
function sfui.worldevents.ScanEvents(targetList, acquireFunc)
    if not sfui.worldevents.is_enabled() then return end
    if isDirty or (time() - lastUpdateTime > 30) then
        sfui.worldevents.UpdateEventsData()
    end

    if #cachedEvents == 0 then return end

    local Alloc = acquireFunc or AcquireTable

    for idx, ev in ipairs(cachedEvents) do
        local entry = Alloc()
        entry.questID      = 99980000 + idx
        entry.isWorldEvent = true
        entry.eventKey     = ev.eventKey
        entry.areaPoiID    = ev.areaPoiID
        entry.uiMapID      = ev.uiMapID
        entry.title        = ev.name
        entry.zoneName     = ev.zoneName
        entry.atlasName    = ev.atlasName
        entry.hasReminder  = ev.hasReminder
        entry.isOngoing    = ev.isOngoing
        entry.timeLeftText = ev.timeLeftText
        entry.isComplete   = false
        entry.isFailed     = false
        entry.done         = 0
        entry.total        = 1

        -- Sub-objectives: Location & Time Remaining (quests.lua prepends "- ")
        local objs = Alloc()

        local locObj = Alloc()
        locObj.text = ev.zoneName or "World Event"
        locObj.finished = false
        table_insert(objs, locObj)

        local timeObj = Alloc()
        local timeCol = ev.isOngoing and "|cff00ff88" or "|cff33d9f2"
        local remStr  = ev.remText or "now"
        timeObj.text = string_format("%sTime remaining: %s|r", timeCol, remStr)
        timeObj.finished = false
        table_insert(objs, timeObj)

        entry.objectives = objs
        entry._syntheticObjs = true

        table_insert(targetList, entry)
    end
end

-- ─── Profiler Support for mem.lua ───────────────────────────────────────────
function sfui.worldevents_debug_info()
    local poiCount = 0
    for _ in pairs(poiNameCache) do poiCount = poiCount + 1 end
    return {
        activeEvents = #cachedEvents,
        tablePool    = #tablePool,
        reminders    = reminderCount,
        cachedPois   = poiCount,
        isDirty      = isDirty,
        lastUpdate   = lastUpdateTime,
    }
end

-- ─── Central Dispatcher Registration ────────────────────────────────────────
if sfui.events then
    sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if C_EventScheduler and C_EventScheduler.RequestEvents then
            C_EventScheduler.RequestEvents()
        end
        C_Timer.After(2.0, sfui.worldevents.RequestUpdate)
    end)

    sfui.events.RegisterEvent("EVENT_SCHEDULER_UPDATE", function()
        sfui.worldevents.RequestUpdate()
    end)

    sfui.events.RegisterEvent("SUPER_TRACKING_CHANGED", function()
        sfui.worldevents.RequestUpdate()
    end)

    sfui.events.RegisterUpdate("WorldEvents", 5.0, function(elapsed)
        sfui.worldevents.OnTimerTick(elapsed)
    end)
end
