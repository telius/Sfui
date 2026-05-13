local addonName, addon = ...
sfui                   = sfui or {}
sfui.location          = {}
local sfui_common      = sfui.common
local sfui_config      = sfui.config
local sfui_events      = sfui.events

sfui_config.location   = sfui_config.location or {
    fillSound     = 10157,
    printOnInvite = true,
}

-- -------------------------------------------------------
-- Module state
-- -------------------------------------------------------
local pendingDungeon   = nil
local pendingLeader    = nil
local watchingRoster   = false

local function is_enabled()
    return SfuiDB and SfuiDB.keystoneReminder ~= false
end

local function reset_state()
    pendingDungeon = nil
    pendingLeader  = nil
    if watchingRoster then
        sfui_events.UnregisterEvent("GROUP_ROSTER_UPDATE", sfui.location.on_roster_update)
        watchingRoster = false
    end
end

local cyan    = sfui_config.colors.cyan
local purple  = sfui_config.colors.purple
local cc      = string.format("|cff%02x%02x%02x", cyan[1] * 255, cyan[2] * 255, cyan[3] * 255)
local pc      = string.format("|cff%02x%02x%02x", purple[1] * 255, purple[2] * 255, purple[3] * 255)
local reset_c = "|r"

-- -------------------------------------------------------
-- Core: group-filled handler
-- -------------------------------------------------------
function sfui.location.on_roster_update()
    if GetNumGroupMembers() >= 5 then
        if sfui_config.location.fillSound > 0 then
            PlaySound(sfui_config.location.fillSound, "Dialog")
        end

        sfui_common.print(
            pc .. "{rt3} GROUP FILLED" .. reset_c
            .. " -> " .. cc .. (pendingDungeon or "unknown dungeon") .. reset_c
            .. " | leader: " .. tostring(pendingLeader)
        )

        reset_state()
    end
end

local function on_application_status(event, searchResultID, newStatus)
    if not is_enabled() then return end
    if newStatus ~= "invited" and newStatus ~= "inviteaccepted" then return end

    local resultData = C_LFGList.GetSearchResultInfo(searchResultID)
    if not resultData then return end

    local activityInfo = C_LFGList.GetActivityInfoTable(resultData.activityIDs and resultData.activityIDs[1])
    if not activityInfo or activityInfo.categoryID ~= 2 then
        if newStatus == "inviteaccepted" then reset_state() end
        return
    end

    local dungeonName = activityInfo.fullName or "?"
    local keyLevel    = resultData.name or ""
    local leader      = resultData.leaderName or ""
    local pendingDgn  = dungeonName .. " " .. tostring(keyLevel)

    -- Handle initial invite pop-up
    if newStatus == "invited" then
        sfui_common.print(
            pc .. "Keystone invite received" .. reset_c
            .. " -> " .. cc .. pendingDgn .. reset_c
            .. " | leader: " .. tostring(leader)
        )
        return
    end

    -- Fall-through: newStatus == "inviteaccepted"
    pendingDungeon = pendingDgn
    pendingLeader  = leader

    if sfui_config.location.printOnInvite then
        sfui_common.print(
            pc .. "Keystone accepted" .. reset_c
            .. " -> " .. cc .. pendingDungeon .. reset_c
            .. " | leader: " .. tostring(pendingLeader)
            .. " (waiting for group to fill...)"
        )
    end

    -- Register roster watcher only now (transient; unregistered on fill or reset)
    if not watchingRoster then
        sfui_events.RegisterEvent("GROUP_ROSTER_UPDATE", sfui.location.on_roster_update)
        watchingRoster = true
    end

    -- Immediate check in case we're the last to accept
    sfui.location.on_roster_update()
end

-- -------------------------------------------------------
-- Cleanup: leaving a party mid-queue cancels the reminder
-- -------------------------------------------------------
local function on_party_leave()
    reset_state()
end

-- -------------------------------------------------------
-- Event wiring via sfui.events (shared multiplexer)
-- -------------------------------------------------------
sfui_events.RegisterEvent("LFG_LIST_APPLICATION_STATUS_UPDATED", on_application_status)
sfui_events.RegisterEvent("GROUP_LEFT", on_party_leave)
