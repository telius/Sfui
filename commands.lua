local addonName, addon = ...
sfui = sfui or {}
sfui.commands = sfui.commands or {}
sfui.keybinds = sfui.keybinds or {}

-- Localize Globals
local _G = _G
local print = print
local type = type
local tostring = tostring
local string_lower = string.lower
local string_format = string.format
local C_UI = C_UI
local GetBindingKey = _G.GetBindingKey

-- ────────────────────────────────────────────────────────────────────────────
-- 1. BLIZZARD KEYBINDINGS MENU DEFINITIONS
-- ────────────────────────────────────────────────────────────────────────────
BINDING_HEADER_SFUI = "SFUI"
_G["BINDING_NAME_CLICK SfuiHammerPopup:LeftButton"] = "master's hammer repair"
_G["BINDING_NAME_SFUI_MATCHMOUNT"] = "match target mount"
_G["BINDING_NAME_SFUI_PORTALS"] = "portals"
_G["BINDING_NAME_SFUI_ALTS"] = "alts / warband"

-- ────────────────────────────────────────────────────────────────────────────
-- 2. KEYBIND RESOLUTION & FORMATTING HELPERS
-- ────────────────────────────────────────────────────────────────────────────
--- Formats a raw key string with standard abbreviated modifier prefixes.
--- @param key string
--- @return string
function sfui.keybinds.format_key(key)
    if not key or key == "" then return "" end
    return key:gsub("SHIFT%-", "S-")
              :gsub("CTRL%-", "C-")
              :gsub("ALT%-", "A-")
              :gsub("NUMPAD", "N")
              :gsub("MOUSEWHEELUP", "WU")
              :gsub("MOUSEWHEELDOWN", "WD")
end

--- Returns the primary bound key for a given action string, formatted for UI labels.
--- @param action string e.g. "ACTIONBUTTON1", "SFUI_PORTALS", "SFUI_ALTS"
--- @return string
function sfui.keybinds.get_action_key(action)
    if not action then return "" end
    local key = GetBindingKey and GetBindingKey(action)
    return sfui.keybinds.format_key(key)
end

-- Export aliases to sfui.common for cross-module convenience
sfui.common = sfui.common or {}
sfui.common.format_keybind = sfui.keybinds.format_key
sfui.common.get_binding_text = sfui.keybinds.get_action_key

-- ────────────────────────────────────────────────────────────────────────────
-- 3. SLASH COMMAND HANDLERS
-- ────────────────────────────────────────────────────────────────────────────

-- Quick UI Reload
SLASH_RL1 = "/rl"
SlashCmdList["RL"] = function()
    C_UI.Reload()
end

-- Memory Profiler & Garbage Collection
SLASH_SFMEM1 = "/sfmem"
SlashCmdList["SFMEM"] = function(msg)
    if sfui.mem and sfui.mem.HandleSlash then
        sfui.mem.HandleSlash(msg)
    else
        local clean = msg and _G.strtrim and _G.strtrim(msg):lower() or (msg and msg:lower() or "")
        local cmd, arg = clean:match("^(%S+)%s*(.*)$")
        cmd = cmd or clean
        if cmd == "gc" or cmd == "clean" or cmd == "collect" then
            if sfui.mem and sfui.mem.RunGC then sfui.mem.RunGC() end
        else
            if sfui.mem and sfui.mem.ToggleGUI then sfui.mem.ToggleGUI() end
        end
    end
end

-- Quest Log HUD
SLASH_SFQL1 = "/sfql"
SLASH_SFQL2 = "/sfquestlog"
SlashCmdList["SFQL"] = function(msg)
    local clean = msg and _G.strtrim and _G.strtrim(msg):lower() or (msg and msg:lower() or "")
    if clean == "reset" or clean == "unhide" then
        if sfui.questlog and sfui.questlog.unhide_all then
            sfui.questlog.unhide_all()
        end
        return
    end
    if sfui.questlog and sfui.questlog.toggle then
        sfui.questlog.toggle()
    else
        if sfui.common and sfui.common.print then
            sfui.common.print("sfui: quest log not available.")
        end
    end
end

-- Alts & Warband Dashboard
SLASH_SFUIALTS1 = "/alts"
SLASH_SFUIALTS2 = "/sfalts"
SlashCmdList["SFUIALTS"] = function(msg)
    local clean = msg and _G.strtrim and _G.strtrim(msg):lower() or (msg and msg:lower() or "")
    if clean == "resetweeklies" then
        if sfui.alts and sfui.alts.ResetWeeklies then
            sfui.alts.ResetWeeklies()
        end
        return
    end
    if sfui.alts and sfui.alts.Toggle then
        sfui.alts.Toggle()
    else
        if sfui.common and sfui.common.print then
            sfui.common.print("sfui: alts viewer not available.")
        end
    end
end

-- Master SFUI Slash Command Router
SLASH_SFUI1 = "/sfui"
SlashCmdList["SFUI"] = function(msg)
    local raw = msg and _G.strtrim and _G.strtrim(msg) or (msg or "")
    local clean = raw:lower()
    local cmd, arg = clean:match("^(%S+)%s*(.*)$")
    cmd = cmd or clean

    if cmd == "" then
        if sfui.toggle_options_panel then
            sfui.toggle_options_panel()
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: options panel not available.")
            end
        end
    elseif cmd == "alts" or cmd == "warband" then
        SlashCmdList["SFUIALTS"](arg)
    elseif cmd == "ql" or cmd == "quests" or cmd == "questlog" then
        SlashCmdList["SFQL"](arg)
    elseif cmd == "mem" or cmd == "memory" or cmd == "gc" then
        local sub = (cmd == "gc" and "gc") or arg
        SlashCmdList["SFMEM"](sub)
    elseif cmd == "cv" or cmd == "cooldowns" then
        if sfui.trackedoptions and sfui.trackedoptions.toggle_viewer then
            sfui.trackedoptions.toggle_viewer()
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: cooldown viewer not available.")
            end
        end
    elseif cmd == "portals" or cmd == "portal" then
        if sfui.portals and sfui.portals.Toggle then
            sfui.portals.Toggle()
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: portals menu not available.")
            end
        end
    elseif cmd == "gear" then
        if sfui.gear and sfui.gear.toggle then
            sfui.gear.toggle()
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: gear manager not available.")
            end
        end
    elseif cmd == "highest" then
        if sfui.highest and sfui.highest.toggle then
            sfui.highest.toggle()
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: highest ilvl viewer not available.")
            end
        end
    elseif cmd == "lootspec" or cmd == "spec" then
        if sfui.lootspec and sfui.lootspec.toggle then
            sfui.lootspec.toggle()
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: loot spec manager not available.")
            end
        end
    elseif cmd == "research" then
        if sfui.research and sfui.research.toggle_selection then
            sfui.research.toggle_selection()
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: research viewer not available.")
            end
        end
    elseif cmd == "mythic" or cmd == "m+" or cmd == "delve" or cmd == "dungeon" then
        if sfui.mythic and sfui.mythic.ShowPreview and sfui.mythic.HidePreview then
            if sfui.mythic.previewActive then
                sfui.mythic.HidePreview()
            else
                sfui.mythic.ShowPreview()
            end
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("sfui: mythic/delve tracker not available.")
            end
        end
    elseif cmd == "rl" or cmd == "reload" then
        C_UI.Reload()
    elseif cmd == "help" or cmd == "?" then
        if sfui.common and sfui.common.print then
            sfui.common.print("Commands: /sfui [options | alts | ql | portals | cv | gear | highest | lootspec | research | mythic | mem | rl]")
        end
    else
        if sfui.common and sfui.common.print then
            sfui.common.print("Unknown command: /sfui " .. cmd .. ". Type /sfui help for a list of commands.")
        end
    end
end
