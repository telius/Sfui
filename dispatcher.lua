local addonName, addon = ...
sfui = sfui or {}

-- ============================================================================
-- SFUI Central Event Dispatcher
--
-- Single-frame event routing and throttled update management for the entire addon.
--
-- Usage:
--   sfui.events.RegisterEvent("EVENT_NAME", function(event, ...) end)
--   sfui.events.UnregisterEvent("EVENT_NAME", callback)
--   sfui.events.RegisterUnitEvent("UNIT_AURA", "player", callback)
--   sfui.events.RegisterUnitEvents({"UNIT_HEALTH", "UNIT_ABSORB_AMOUNT_CHANGED"}, "player", cb)
--   sfui.events.UnregisterUnitEvent("UNIT_AURA", "player", callback)
--   sfui.events.RegisterThrottledEvent("UPDATE_UI_WIDGET", 0.2, callback)
--   sfui.events.RegisterUpdate("name", interval, callback)
--
-- Architecture:
--   * Single Global Frame (`SfuiDispatcherFrame`) for non-unit game events.
--   * Isolated Per-Unit Frames (`SfuiDispatcherUnitFrame_<unit>`) for RegisterUnitEvent.
--   * Snapshot scratch table (`_snap`) prevents mid-dispatch mutation errors.
--   * Zero-overhead dispatch loop with conditional profiling (`_memActive`).
--   * Minimum update interval floor (0.016s ≈ 60fps) on all RegisterUpdate loops.
--
-- Subsystems & Routing Destinations:
--   Core & State:
--     • core.lua                    - Scale recalculation (UI_SCALE_CHANGED), master boot sequence.
--     • common.lua                  - Spec change cache, vehicle/flight state, out-of-combat queue.
--     • commands.lua                - Keybinding synchronization (UPDATE_BINDINGS).
--   Combat & UI Bars:
--     • frames/bars.lua             - Player health, absorbs, power, runes, vigor, form changes.
--     • frames/class/soulfragments.lua - Demon Hunter soul fragments, fury changes, void decay.
--     • frames/trackedbars.lua      - Cooldown & aura status bars, spellcast edge mirrors.
--     • frames/trackedicons.lua     - Cooldown & aura icon grid, charges, glow timeouts.
--     • frames/vehicle.lua          - Vehicle health/energy bars, action button keybinds.
--   Objectives & Dungeons:
--     • frames/quests.lua           - Quest log, objective tracker, scenario criteria, zone cache.
--     • frames/mythic.lua           - M+ & Delve HUD, keystone receptacle, deaths (UNIT_DIED).
--   Utilities & Automation:
--     • frames/alts.lua             - Warband alt sync, profession KP, trade skill updates.
--     • frames/automation.lua       - Master's Hammer repair popup, role checks, LFG auto-confirm.
--     • frames/merchant.lua         - Auto-junk selling & auto-repair vendor triggers.
--     • frames/transfer.lua         - Warband bank transfer helper window.
--     • frames/research.lua         - Trait tree & research currency updates.
--     • frames/compare.lua          - Equipment auto-comparison CVar tracking.
--     • frames/portals.lua          - Combat close & portal list synchronization.
--     • frames/mem.lua              - Real-time memory allocation profiling & watcher hooks.
-- ============================================================================

sfui.events = {}

-- ─── Locals ─────────────────────────────────────────────────────────────────

local eventCallbacks     = {}  -- [eventName] = { cb, cb, ... }
local updateCallbacks    = {}  -- { { name, interval, elapsed, callback }, ... }

local function _err(ctx, msg)
    print("|cff6600ffsfui|r dispatcher error (" .. ctx .. "): " .. tostring(msg))
end

-- ─── Memory profiling ───────────────────────────────────────────────────────
-- Checked lazily: _memActive is false unless sfui.mem turns on the watcher.
-- This avoids 3 table lookups + a function call on every single event fire.
local _memActive = false
local function _mem_tick()
    _memActive = sfui.mem and sfui.mem.IsWatcherActive and sfui.mem.IsWatcherActive() or false
end
local function _mem_after(key, before)
    local delta = collectgarbage("count") - before
    if delta > 0 then sfui.mem.RecordAllocation(key, delta) end
end

-- ─── Snapshot scratch table ─────────────────────────────────────────────────
-- Single pre-allocated table reused across all event dispatches.
-- A one-shot callback calls UnregisterEvent mid-loop, which mutates the live
-- `cbs` array; dispatching from a snapshot prevents nil-slot errors.
-- We nil-out slots after use so the table stays small (no strong references).
local _snap = {}

-- Minimum interval (seconds) enforced on all RegisterUpdate callbacks.
-- Prevents any update loop from running faster than ~60fps regardless of
-- the caller's requested interval (including interval=0).
local MIN_UPDATE_INTERVAL = 0.016

-- ─── Global event frame ─────────────────────────────────────────────────────
local ev_frame = CreateFrame("Frame", "SfuiDispatcherFrame")

ev_frame:SetScript("OnEvent", function(_, event, ...)
    local cbs = eventCallbacks[event]
    if not cbs then return end

    local n = #cbs
    for i = 1, n do _snap[i] = cbs[i] end  -- snapshot into scratch

    if _memActive then
        local before = collectgarbage("count")
        for i = 1, n do
            local ok, err = pcall(_snap[i], event, ...)
            if not ok then _err(event, err) end
            _snap[i] = nil
        end
        _mem_after(event, before)
    else
        for i = 1, n do
            local ok, err = pcall(_snap[i], event, ...)
            if not ok then _err(event, err) end
            _snap[i] = nil
        end
    end
end)

local function _OnDispatcherUpdate(_, elapsed)
    if _memActive then
        for i = 1, #updateCallbacks do
            local d = updateCallbacks[i]
            d.elapsed = d.elapsed + elapsed
            if d.elapsed >= d.interval then
                local label = d.name or "UpdateLoop"
                local before = collectgarbage("count")
                local ok, err = pcall(d.callback, d.elapsed)
                if not ok then _err(label, err) end
                _mem_after(label, before)
                d.elapsed = 0
            end
        end
    else
        for i = 1, #updateCallbacks do
            local d = updateCallbacks[i]
            d.elapsed = d.elapsed + elapsed
            if d.elapsed >= d.interval then
                local ok, err = pcall(d.callback, d.elapsed)
                if not ok then _err(d.name or "UpdateLoop", err) end
                d.elapsed = 0
            end
        end
    end
end

-- ─── Unit event frames (per-unit isolation) ─────────────────────────────────
-- Each unit token (e.g. "player", "vehicle") gets its own dedicated Frame.
-- This is critical: WoW's C-API Frame:RegisterUnitEvent(event, unit) replaces
-- the registered unit for that event on that frame. If multiple units shared
-- a single frame, registering "vehicle" for UNIT_POWER_UPDATE would overwrite
-- and silence "player" for UNIT_POWER_UPDATE across the addon!
local unitFrames = {}         -- [unit] = Frame
local unitEventCallbacks = {} -- [unit] = { [eventName] = { cb1, cb2, ... } }

local function get_or_create_unit_frame(unit)
    local f = unitFrames[unit]
    if not f then
        f = CreateFrame("Frame", "SfuiDispatcherUnitFrame_" .. tostring(unit))
        unitFrames[unit] = f
        f:SetScript("OnEvent", function(_, event, u, ...)
            local eventCbs = unitEventCallbacks[unit] and unitEventCallbacks[unit][event]
            if not eventCbs then return end
            local n = #eventCbs
            for i = 1, n do _snap[i] = eventCbs[i] end

            if _memActive then
                local before = collectgarbage("count")
                for i = 1, n do
                    local ok, err = pcall(_snap[i], event, u, ...)
                    if not ok then _err(event .. "/" .. tostring(u), err) end
                    _snap[i] = nil
                end
                _mem_after(event, before)
            else
                for i = 1, n do
                    local ok, err = pcall(_snap[i], event, u, ...)
                    if not ok then _err(event .. "/" .. tostring(u), err) end
                    _snap[i] = nil
                end
            end
        end)
    end
    return f
end

-- ─── Public API ─────────────────────────────────────────────────────────────

--- Register a callback for a global game event.
--- If event == "PLAYER_LOGIN" and the player is already logged in, fires immediately.
function sfui.events.RegisterEvent(event, callback)
    if event == "PLAYER_LOGIN" and IsLoggedIn() then
        local ok, err = pcall(callback, event)
        if not ok then _err("PLAYER_LOGIN immediate", err) end
        return
    end

    if not eventCallbacks[event] then
        local ok = pcall(ev_frame.RegisterEvent, ev_frame, event)
        if not ok then
            -- Unknown or deprecated event in current client build; ignore safely
            return
        end
        eventCallbacks[event] = {}
    end
    local cbs = eventCallbacks[event]
    for i = 1, #cbs do
        if cbs[i] == callback then return end
    end
    cbs[#cbs + 1] = callback
end

--- Unregister a previously-registered callback.
function sfui.events.UnregisterEvent(event, callback)
    local cbs = eventCallbacks[event]
    if not cbs then return end
    for i = #cbs, 1, -1 do
        if cbs[i] == callback then table.remove(cbs, i) end
    end
    if #cbs == 0 then
        pcall(ev_frame.UnregisterEvent, ev_frame, event)
        eventCallbacks[event] = nil
    end
end

--- Register a callback for a unit-filtered game event.
--- Only fires when the event's unit argument matches the registered unit.
--- @param event    string     e.g. "UNIT_AURA"
--- @param unit     string     e.g. "player"
--- @param callback function(event, unit, ...)
function sfui.events.RegisterUnitEvent(event, unit, callback)
    if not unit or not event or not callback then return end

    if not unitEventCallbacks[unit] then
        unitEventCallbacks[unit] = {}
    end
    if not unitEventCallbacks[unit][event] then
        unitEventCallbacks[unit][event] = {}
    end

    local cbs = unitEventCallbacks[unit][event]
    for i = 1, #cbs do
        if cbs[i] == callback then return end
    end
    cbs[#cbs + 1] = callback

    local f = get_or_create_unit_frame(unit)
    if #cbs == 1 then
        local ok = pcall(f.RegisterUnitEvent, f, event, unit)
        if not ok then
            table.remove(cbs)
            return
        end
    end
end

--- Register the same callback for multiple unit events in one call.
--- Equivalent to calling RegisterUnitEvent for each event individually.
--- Reduces boilerplate when several events share one handler and one unit.
--- @param events   table      e.g. {"UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED"}
--- @param unit     string     e.g. "player"
--- @param callback function(event, unit, ...)
function sfui.events.RegisterUnitEvents(events, unit, callback)
    for i = 1, #events do
        sfui.events.RegisterUnitEvent(events[i], unit, callback)
    end
end

--- Unregister a unit event callback.
function sfui.events.UnregisterUnitEvent(event, unit, callback)
    local cbs = unitEventCallbacks[unit] and unitEventCallbacks[unit][event]
    if not cbs then return end
    for i = #cbs, 1, -1 do
        if cbs[i] == callback then
            table.remove(cbs, i)
        end
    end
    if #cbs == 0 then
        if unitFrames[unit] then
            pcall(unitFrames[unit].UnregisterEvent, unitFrames[unit], event)
        end
        unitEventCallbacks[unit][event] = nil
    end
end

--- Register a throttled OnUpdate callback.
--- sfui.events.RegisterUpdate([name,] interval, callback)
--- Intervals below MIN_UPDATE_INTERVAL (0.016s ≈ 60fps) are clamped up.
function sfui.events.RegisterUpdate(arg1, arg2, arg3)
    local name, interval, callback
    if type(arg1) == "string" then
        name, interval, callback = arg1, arg2, arg3
    else
        interval, callback = arg1, arg2
    end
    interval = math.max(interval or 0, MIN_UPDATE_INTERVAL)
    updateCallbacks[#updateCallbacks + 1] = {
        name     = name,
        interval = interval,
        elapsed  = 0,
        callback = callback,
    }
    if #updateCallbacks == 1 then
        ev_frame:SetScript("OnUpdate", _OnDispatcherUpdate)
    end
end

--- Unregister an OnUpdate callback by name or function reference.
function sfui.events.UnregisterUpdate(target)
    if not target then return end
    for i = #updateCallbacks, 1, -1 do
        local d = updateCallbacks[i]
        if d.name == target or d.callback == target then
            table.remove(updateCallbacks, i)
        end
    end
    if #updateCallbacks == 0 then
        ev_frame:SetScript("OnUpdate", nil)
    end
end

--- Register an event callback that fires at most once every `interval` seconds.
--- If the event bursts (fires multiple times within the window), intermediate
--- fires are dropped — only the most-recent dispatch goes through.
--- Returns the wrapper function so the caller can pass it to UnregisterEvent.
---
--- Usage:
---   local handle = sfui.events.RegisterThrottledEvent("UNIT_AURA", 0.1, myFn)
---   sfui.events.UnregisterEvent("UNIT_AURA", handle)  -- to remove
function sfui.events.RegisterThrottledEvent(event, interval, callback)
    local lastFired = 0
    local wrapper = function(ev, ...)
        local now = GetTime()
        if now - lastFired >= interval then
            lastFired = now
            callback(ev, ...)
        end
    end
    sfui.events.RegisterEvent(event, wrapper)
    return wrapper
end

--- Called by sfui.mem when its watcher starts or stops, to update the hot-path flag.
function sfui.events.SetMemProfiling(active)
    _memActive = active and true or false
end

-- Sync flag once on login in case the watcher was enabled during init.
sfui.events.RegisterEvent("PLAYER_LOGIN", _mem_tick)
