local addonName, addon = ...
sfui = sfui or {}
sfui.location = {}

-- ============================================================
-- Keystone Location Reminder
-- Prints the dungeon name and keystone level to chat when a
-- Mythic+ group invitation is accepted, then re-announces once
-- the group reaches 5 members so you never forget where to go.
--
-- Opt-out via: SfuiDB.keystoneReminder = false  (default true)
-- Options panel toggle in the "automation" tab.
-- ============================================================

-- Local aliases – avoids repeated global lookups in hot path
local sfui_common   = sfui.common
local sfui_config   = sfui.config
local sfui_events   = sfui.events

-- -------------------------------------------------------
-- Config defaults (merged into sfui.config.location)
-- -------------------------------------------------------
sfui_config.location = sfui_config.location or {
    -- Sound played when the group fills (ID 10157 = "A_HELL_Bldgrd_Ready01",
    -- same as the reference addon).  0 = silent.
    fillSound  = 10157,
    -- Whether to print on invite acceptance (before group is full)
    printOnInvite = true,
}

-- -------------------------------------------------------
-- Module state – intentionally minimal, no heap churn
-- -------------------------------------------------------
local pendingDungeon  = nil   -- string: "Dungeon Name [+level]" or nil
local pendingLeader   = nil   -- string: leader name or nil
local watchingRoster  = false -- true while GROUP_ROSTER_UPDATE is live

-- -------------------------------------------------------
-- Helpers
-- -------------------------------------------------------
local function is_enabled()
    -- opt-in by default (nil → true)
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
local cc      = string.format("|cff%02x%02x%02xff", cyan[1]*255, cyan[2]*255, cyan[3]*255)
local pc      = string.format("|cff%02x%02x%02xff", purple[1]*255, purple[2]*255, purple[3]*255)
local reset_c = "|r"

-- -------------------------------------------------------
-- Core: group-filled handler
-- -------------------------------------------------------
function sfui.location.on_roster_update()
    if GetNumGroupMembers() >= 5 then
        -- Announce fill
        if sfui_config.location.fillSound > 0 then
            PlaySound(sfui_config.location.fillSound, "Dialog")
        end

        sfui_common.print(
            pc .. "★ GROUP FILLED" .. reset_c
            .. " → " .. cc .. (pendingDungeon or "unknown dungeon") .. reset_c
            .. " | leader: " .. tostring(pendingLeader)
        )

        reset_state()
    end
end

-- -------------------------------------------------------
-- Core: invite-accepted handler
-- -------------------------------------------------------
local function on_application_status(event, searchResultID, newStatus)
    if not is_enabled() then return end
    -- If we receive an invite, print it immediately so the user can see what they are accepting
    if newStatus == "invited" then
        local resultData = C_LFGList.GetSearchResultInfo(searchResultID)
        if not resultData then return end
        local activityInfo = C_LFGList.GetActivityInfoTable(resultData.activityIDs and resultData.activityIDs[1])
        if not activityInfo or activityInfo.categoryID ~= 2 then return end

        local dungeonName = activityInfo.fullName or "?"
        local keyLevel    = resultData.name or ""
        local leader      = resultData.leaderName or ""

        sfui_common.print(
            pc .. "Keystone invite received" .. reset_c
            .. " → " .. cc .. dungeonName .. " " .. tostring(keyLevel) .. reset_c
            .. " | leader: " .. tostring(leader)
        )
        return
    end

    if newStatus ~= "inviteaccepted" then return end

    -- Pull LFG data – both calls can return nil if data hasn't loaded yet.
    local resultData = C_LFGList.GetSearchResultInfo(searchResultID)
    if not resultData then return end

    local activityInfo = C_LFGList.GetActivityInfoTable(
        resultData.activityIDs and resultData.activityIDs[1]
    )
    if not activityInfo then return end

    -- categoryID 2 = dungeon (mirrors reference addon logic)
    if activityInfo.categoryID ~= 2 then
        reset_state()
        return
    end

    local dungeonName = activityInfo.fullName or "?"
    local keyLevel    = resultData.name or ""
    local leader      = resultData.leaderName or ""

    -- Build strings carefully to avoid comparing SecretValues (which throws errors)
    -- LFG names and leaders are often protected payload objects in Mythic+.
    pendingDungeon = dungeonName .. " " .. tostring(keyLevel)
    pendingLeader  = leader

    if sfui_config.location.printOnInvite then
        sfui_common.print(
            pc .. "Keystone accepted" .. reset_c
            .. " → " .. cc .. pendingDungeon .. reset_c
            .. " | leader: " .. tostring(pendingLeader)
            .. " (waiting for group to fill…)"
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
