-- sfui by teli

-- addon table for scope
sfui = sfui or {}

-- We ensure the table exists and initialize default values at the global scope.
-- This guarantees that SfuiDB is available when other files (like options.lua) are parsed.
SfuiDB = SfuiDB or {}
if type(SfuiDB.barTexture) ~= "string" or SfuiDB.barTexture == "" then
    SfuiDB.barTexture = sfui.config.barTexture
end
SfuiDB.absorbBarColor = SfuiDB.absorbBarColor or sfui.config.absorbBarColor
if SfuiDB.minimap and type(SfuiDB.minimap) == "table" then
    SfuiDB.minimap_auto_zoom = SfuiDB.minimap.auto_zoom
    SfuiDB.minimap_square = SfuiDB.minimap.square
    SfuiDB.minimap_collect_buttons = SfuiDB.minimap.collect_buttons
    SfuiDB.minimap_masque = SfuiDB.minimap.masque
end
SfuiDB.minimap = nil -- Remove minimap saved data

SfuiDB.minimap_auto_zoom = SfuiDB.minimap_auto_zoom or sfui.config.minimap.auto_zoom
SfuiDB.minimap_square = SfuiDB.minimap_square or sfui.config.minimap.square
SfuiDB.minimap_collect_buttons = SfuiDB.minimap_collect_buttons or sfui.config.minimap.collect_buttons
SfuiDB.minimap_masque = SfuiDB.minimap_masque or sfui.config.minimap.masque

-- register slash command global variable (required by wow api)
SLASH_SFUI1 = "/sfui"
SLASH_RL1 = "/rl" -- New reload clash command

-- function to handle /sfui slash commands
function sfui.slash_command_handler(msg)
    if msg == "" then
        if sfui.toggle_options_panel then
            sfui.toggle_options_panel()
        else
            print("sfui: options panel not available.")
        end
    end
    -- you can add more commands here later, like /sfui help
end

-- function to handle /rl slash command
function sfui.reload_ui_handler(msg)
    C_UI.Reload()
end

-- register the slash command handlers (required by wow api)
SlashCmdList["SFUI"] = sfui.slash_command_handler
SlashCmdList["RL"] = sfui.reload_ui_handler -- Register the reload command

-- frame to listen for events
local event_frame = CreateFrame("Frame")
event_frame:RegisterEvent("ADDON_LOADED")
event_frame:RegisterEvent("PLAYER_LOGIN")

event_frame:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name == "sfui" then
            -- Set CVars on load
            if sfui.config and sfui.config.cvars_on_load then
                for _, cvar_data in ipairs(sfui.config.cvars_on_load) do
                    C_CVar.SetCVar(cvar_data.name, cvar_data.value)
                    print(string.format("sfui: Set CVar '%s' to '%s'", cvar_data.name, tostring(cvar_data.value)))
                end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        -- Create all our UI elements now that the player is in the world.
        if sfui.create_options_panel then
            sfui.create_options_panel()
        end
        if sfui.create_currency_frame then
            sfui.create_currency_frame()
        end
        if sfui.create_item_frame then
            sfui.create_item_frame()
        end
        if sfui.bars and sfui.bars.OnStateChanged then
            sfui.bars:OnStateChanged()
        end
        -- We only need this event once per session.
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)