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

    local activityID = resultData.activityIDs[1]
    if not activityID then
        if newStatus == "inviteaccepted" then reset_state() end
        return
    end

    local activityInfo = C_LFGList.GetActivityInfoTable(activityID)
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

local function on_active_entry_update()
    if not is_enabled() then return end

    local hasActive = C_LFGList.HasActiveEntryInfo()
    if not hasActive then
        -- If entry is delisted before group is full, cancel the reminder
        if watchingRoster and pendingLeader == UnitName("player") and GetNumGroupMembers() < 5 then
            reset_state()
        end
        return
    end

    local entryInfo = C_LFGList.GetActiveEntryInfo()
    if not entryInfo then return end

    local activityID = entryInfo.activityIDs[1]
    if not activityID then return end

    local activityInfo = C_LFGList.GetActivityInfoTable(activityID)
    if not activityInfo or activityInfo.categoryID ~= 2 then return end

    local dungeonName = activityInfo.fullName or "?"
    local keyLevel    = entryInfo.name or ""
    local leader      = UnitName("player")
    local pendingDgn  = dungeonName .. " " .. tostring(keyLevel)

    pendingDungeon = pendingDgn
    pendingLeader  = leader

    if not watchingRoster then
        sfui_events.RegisterEvent("GROUP_ROSTER_UPDATE", sfui.location.on_roster_update)
        watchingRoster = true
        
        if sfui_config.location.printOnInvite then
            sfui_common.print(
                pc .. "Keystone group listed" .. reset_c
                .. " -> " .. cc .. pendingDungeon .. reset_c
                .. " (waiting for group to fill...)"
            )
        end
    end
end

-- -------------------------------------------------------
-- Instance & Difficulty Status Badge
-- -------------------------------------------------------
local lastInstancePrint = nil

local function print_instance_status()
    if not is_enabled() then return end
    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType == "none" then
        lastInstancePrint = nil
        return
    end

    local name, _, difficultyID, difficultyName = GetInstanceInfo()
    if not name or name == "" then return end

    local now = GetTime()
    if lastInstancePrint and (now - lastInstancePrint < 3) then return end
    lastInstancePrint = now

    local diffText = difficultyName or "Normal"
    local activeKey = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo()
    if activeKey and activeKey > 0 then
        diffText = "Mythic +" .. tostring(activeKey)
    end

    local specID = GetLootSpecialization and GetLootSpecialization() or 0
    local isDefault = (specID == 0)
    if isDefault and GetSpecialization and GetSpecializationInfo then
        local curIdx = GetSpecialization()
        if curIdx and curIdx > 0 then
            specID = GetSpecializationInfo(curIdx) or 0
        end
    end

    local specName = "Current Spec"
    local specColor = cc

    if specID and specID ~= 0 then
        local _, sName = GetSpecializationInfoByID(specID)
        if sName then
            specName = isDefault and (sName .. " (Default)") or sName
        end
        local sc = sfui_config.spec_colors and sfui_config.spec_colors[specID]
        if sc then
            specColor = string.format("|cff%02x%02x%02x", sc[1] * 255, sc[2] * 255, sc[3] * 255)
        end
    end

    sfui_common.print(
        pc .. name .. reset_c
        .. " (" .. cc .. diffText .. reset_c .. ")"
        .. " · loot spec: " .. specColor .. specName .. reset_c
    )
end

function sfui.location.PrintInstanceStatus()
    print_instance_status()
end

-- -------------------------------------------------------
-- Event wiring via sfui.events (shared multiplexer)
-- -------------------------------------------------------
sfui_events.RegisterEvent("LFG_LIST_APPLICATION_STATUS_UPDATED", on_application_status)
sfui_events.RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE", on_active_entry_update)
sfui_events.RegisterEvent("GROUP_LEFT", on_party_leave)
sfui_events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(0.5, print_instance_status)
end)
sfui_events.RegisterEvent("ZONE_CHANGED_NEW_AREA", print_instance_status)
sfui_events.RegisterEvent("CHALLENGE_MODE_START", function()
    lastInstancePrint = nil
    C_Timer.After(0.2, print_instance_status)
end)
