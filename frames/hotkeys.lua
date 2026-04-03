--[[
    SFUI - hotkeys.lua
    Scans action bars to detect hotkeys bound to spells/items.
    Ported from CDMx HotkeyDetection + UI:FormatHotkey.

    Architecture:
    1. Build slot→binding map from action button frames
    2. Scan all action slots, resolve spell/item IDs, cache hotkeys
    3. Provide lookup by spell ID or item ID
    4. Event-driven rescans on bar/binding/spec changes
]] --

local addonName, addon = ...
sfui = sfui or {}
sfui.hotkeys = {}

local GetTime = GetTime
local GetBindingKey = GetBindingKey
local GetActionInfo = GetActionInfo
local GetMacroSpell = GetMacroSpell
local GetMacroItem = GetMacroItem
local C_Spell = C_Spell
local C_ActionBar = C_ActionBar
local C_Timer = C_Timer
local wipe = wipe

-- Cache: "spell:12345" -> "S1", "item:67890" -> "CM4"
local cache = {}

-- Runtime slot→binding map
local slotToBinding = {}

--============================================================================
-- HOTKEY FORMATTING
--============================================================================

--- Format a raw keybinding string for compact display on icons.
--- e.g. "SHIFT-1" -> "S1", "CTRL-BUTTON4" -> "CM4"
function sfui.hotkeys.format(key)
    if not key then return nil end
    key = key:upper()
    key = key:gsub("SHIFT%-", "S")
    key = key:gsub("CTRL%-", "C")
    key = key:gsub("ALT%-", "A")
    key = key:gsub("BUTTON", "M")
    key = key:gsub("MOUSEWHEELUP", "MwU")
    key = key:gsub("MOUSEWHEELDOWN", "MwD")
    key = key:gsub("NUMPAD", "N")
    return key
end

--============================================================================
-- SLOT → BINDING MAP
--============================================================================

local blizzardButtonSets = {
    { frame = "ActionButton",              binding = "ACTIONBUTTON" },
    { frame = "MultiBarBottomLeftButton",  binding = "MULTIACTIONBAR1BUTTON" },
    { frame = "MultiBarBottomRightButton", binding = "MULTIACTIONBAR2BUTTON" },
    { frame = "MultiBarRightButton",       binding = "MULTIACTIONBAR3BUTTON" },
    { frame = "MultiBarLeftButton",        binding = "MULTIACTIONBAR4BUTTON" },
    { frame = "MultiBar5Button",           binding = "MULTIACTIONBAR5BUTTON" },
    { frame = "MultiBar6Button",           binding = "MULTIACTIONBAR6BUTTON" },
    { frame = "MultiBar7Button",           binding = "MULTIACTIONBAR7BUTTON" },
    { frame = "MultiBar8Button",           binding = "MULTIACTIONBAR8BUTTON" },
}

local function BuildSlotBindingMap()
    wipe(slotToBinding)

    for _, set in ipairs(blizzardButtonSets) do
        for i = 1, 12 do
            local frame = _G[set.frame .. i]
            if frame then
                local slot = nil

                if set.frame == "ActionButton" then
                    slot = i
                else
                    if frame.GetAttribute then
                        local ok, action = pcall(frame.GetAttribute, frame, "action")
                        if ok and action and type(action) == "number" and action > 0 then
                            slot = action
                        end
                    end
                    if not slot and frame.action and type(frame.action) == "number" then
                        slot = frame.action
                    end
                end

                if slot then
                    slotToBinding[slot] = set.binding .. i
                end
            end
        end
    end
end

--============================================================================
-- SLOT HELPERS
--============================================================================

local function GetHotkeyForSlot(slot)
    local bindingName = slotToBinding[slot]
    if bindingName then
        local key = GetBindingKey(bindingName)
        if key then
            return sfui.hotkeys.format(key)
        end
    end
    return nil
end

local function GetSpellFromSlot(slot)
    local actionType, id = GetActionInfo(slot)
    if actionType == "spell" then
        return id, nil
    elseif actionType == "item" then
        return nil, id
    elseif actionType == "macro" and id then
        local spellID = GetMacroSpell(id)
        if spellID then
            return spellID, nil
        end
        local itemName, itemLink = GetMacroItem(id)
        if itemLink then
            local itemID = tonumber(itemLink:match("item:(%d+)"))
            if itemID then return nil, itemID end
        end
    end
    return nil, nil
end

--============================================================================
-- FULL SCAN
--============================================================================

function sfui.hotkeys.scan()
    wipe(cache)
    BuildSlotBindingMap()

    -- Scan slots 1-180 (main bar, pages, multi-bars)
    for slot = 1, 180 do
        local spellID, itemID = GetSpellFromSlot(slot)
        if spellID or itemID then
            local hotkey = GetHotkeyForSlot(slot)
            if hotkey then
                local cacheKey = spellID and ("spell:" .. spellID) or ("item:" .. itemID)
                cache[cacheKey] = hotkey
            end
        end
    end

    -- ElvUI action bar support
    if ElvUI then
        local ok, E = pcall(unpack, ElvUI)
        if ok and E and E.ActionBars then
            for _, bar in pairs(E.ActionBars.handledBars or {}) do
                if bar.buttons then
                    for _, button in pairs(bar.buttons) do
                        if button.action then
                            local spellID, itemID = GetSpellFromSlot(button.action)
                            if spellID or itemID then
                                local bindTarget = button.keyBoundTarget or button.bindName
                                if bindTarget then
                                    local rawKey = GetBindingKey(bindTarget)
                                    if rawKey then
                                        local hotkey = sfui.hotkeys.format(rawKey)
                                        local cacheKey = spellID and ("spell:" .. spellID) or ("item:" .. itemID)
                                        if not cache[cacheKey] then
                                            cache[cacheKey] = hotkey
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

--============================================================================
-- LOOKUP
--============================================================================

function sfui.hotkeys.get_for_spell(spellID)
    if not spellID then return nil end

    -- Direct cache hit
    local cacheKey = "spell:" .. spellID
    if cache[cacheKey] then
        return cache[cacheKey]
    end

    -- Check talent replacement via GetOverrideSpell
    if C_Spell and C_Spell.GetOverrideSpell then
        local ok, overrideID = pcall(C_Spell.GetOverrideSpell, spellID)
        if ok and overrideID and overrideID ~= spellID then
            local overrideKey = "spell:" .. overrideID
            if cache[overrideKey] then
                cache[cacheKey] = cache[overrideKey]
                return cache[cacheKey]
            end
        end
    end

    -- Fallback: FindSpellActionButtons API
    local idsToCheck = { spellID }
    if C_Spell and C_Spell.GetOverrideSpell then
        local ok, overrideID = pcall(C_Spell.GetOverrideSpell, spellID)
        if ok and overrideID and overrideID ~= spellID then
            table.insert(idsToCheck, overrideID)
        end
    end

    if C_ActionBar and C_ActionBar.FindSpellActionButtons then
        for _, checkID in ipairs(idsToCheck) do
            local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, checkID)
            if ok and slots then
                for _, slot in ipairs(slots) do
                    local hotkey = GetHotkeyForSlot(slot)
                    if hotkey then
                        cache[cacheKey] = hotkey
                        return hotkey
                    end
                end
            end
        end
    end

    -- Last resort: JIT scan
    for slot = 1, 180 do
        local resolvedSpell = GetSpellFromSlot(slot)
        if resolvedSpell then
            for _, targetID in ipairs(idsToCheck) do
                if resolvedSpell == targetID then
                    local hotkey = GetHotkeyForSlot(slot)
                    if hotkey then
                        cache[cacheKey] = hotkey
                        return hotkey
                    end
                end
            end
        end
    end

    -- ElvUI fallback
    if ElvUI then
        local ok, E = pcall(unpack, ElvUI)
        if ok and E and E.ActionBars then
            for _, bar in pairs(E.ActionBars.handledBars or {}) do
                if bar.buttons then
                    for _, button in pairs(bar.buttons) do
                        if button.action then
                            local resolvedSpell = GetSpellFromSlot(button.action)
                            if resolvedSpell then
                                for _, targetID in ipairs(idsToCheck) do
                                    if resolvedSpell == targetID then
                                        local bindTarget = button.keyBoundTarget or button.bindName
                                        if bindTarget then
                                            local rawKey = GetBindingKey(bindTarget)
                                            if rawKey then
                                                local hotkey = sfui.hotkeys.format(rawKey)
                                                cache[cacheKey] = hotkey
                                                return hotkey
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

function sfui.hotkeys.get_for_item(itemID)
    if not itemID then return nil end
    return cache["item:" .. itemID]
end

--============================================================================
-- EVENT HANDLING
--============================================================================

local pendingScanTimer = nil

-- Debounced scan: cancels any pending scan and schedules a new one
local function ScheduleScan(delay)
    if pendingScanTimer then
        pendingScanTimer:Cancel()
    end
    pendingScanTimer = C_Timer.NewTimer(delay, function()
        pendingScanTimer = nil
        sfui.hotkeys.scan()
    end)
end

sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    ScheduleScan(2)
end)

sfui.events.RegisterEvent("ACTIONBAR_SLOT_CHANGED", function()
    ScheduleScan(0.3)
end)

sfui.events.RegisterEvent("UPDATE_BINDINGS", function()
    ScheduleScan(0.3)
end)

sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
    ScheduleScan(1)
end)

sfui.events.RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", function()
    ScheduleScan(1)
end)
