local addonName, addon = ...
sfui = sfui or {}
sfui.logs = {}

-- Auto Combat Log
-- Automatically starts/stops combat logging when entering/leaving instanced content.
-- Controlled by SfuiDB.autoCombatLog (opt-in, default false).
-- API: LoggingCombat()        → returns true/false (current state)
--      LoggingCombat(true)    → starts logging
--      LoggingCombat(false)   → stops logging
--
-- Instance types that warrant logging:
--   "party"  → Mythic+ and normal/heroic dungeons
--   "raid"   → All raid difficulties
--   "pvp"    → Battlegrounds
--   "arena"  → Arenas
-- We log party + raid only (user intent: M+ and raids), not PvP.

local LOG_INSTANCE_TYPES = {
    party = true,
    raid  = true,
}

-- Track whether WE started logging, so we don't stop a log the user started manually.
local sfui_started_log = false

local function should_log()
    if not SfuiDB or not SfuiDB.autoCombatLog then return false end
    local _, instanceType = IsInInstance()
    return LOG_INSTANCE_TYPES[instanceType] == true
end

local function check_logging()
    if not SfuiDB or not SfuiDB.autoCombatLog then return end

    local _, instanceType = IsInInstance()
    local wantLog = LOG_INSTANCE_TYPES[instanceType] == true

    if wantLog then
        if not LoggingCombat() then
            LoggingCombat(true)
            sfui_started_log = true
            print("|cff9966ffSfui:|r Combat logging |cff00ff00started|r (" .. (instanceType or "?") .. ")")
        end
    else
        -- Only stop if we started it; don't interrupt a manually-started log.
        if LoggingCombat() and sfui_started_log then
            LoggingCombat(false)
            sfui_started_log = false
            print("|cff9966ffSfui:|r Combat logging |cffff4444stopped|r")
        end
    end
end

-- Expose for options panel and external toggles.
function sfui.logs.is_enabled()
    return SfuiDB and SfuiDB.autoCombatLog == true
end

function sfui.logs.set_enabled(enabled)
    SfuiDB = SfuiDB or {}
    SfuiDB.autoCombatLog = enabled
    if not enabled then
        -- User disabled: stop any log we started.
        if LoggingCombat() and sfui_started_log then
            LoggingCombat(false)
            sfui_started_log = false
        end
    else
        -- User enabled: check if we should be logging right now.
        check_logging()
    end
end

-- Fire on zone transitions.
sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    -- Short defer so GetInstanceInfo() is up-to-date.
    C_Timer.After(0.5, check_logging)
end)

sfui.events.RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    C_Timer.After(0.5, check_logging)
end)
