local addonName, addon = ...
sfui = sfui or {}
sfui.is_ready_for_vendor_frame = false

-- Localize Globals
local _G = _G
local print = print
local type = type
local tonumber = tonumber
local string_lower = string.lower
local string_match = string.match
local string_gmatch = string.gmatch

local CreateFrame = CreateFrame
local UIParent = UIParent
local IsShiftKeyDown = IsShiftKeyDown
local GetCVar = GetCVar
local C_CVar = C_CVar
local C_UI = C_UI
local C_AddOns = C_AddOns
local LibStub = LibStub

BINDING_HEADER_SFUI = "SFUI"
_G["BINDING_NAME_CLICK SfuiHammerPopup:LeftButton"] = "Master's Hammer Repair"
_G["BINDING_NAME_SFUI_MATCHMOUNT"] = "Match Target Mount"
_G["BINDING_NAME_SFUI_PORTALS"] = "Portals"


local SLASH_SFUI1 = "/sfui"
local SLASH_RL1 = "/rl"

local function update_pixel_scale()
    local resolution = GetCVar("gxWindowedResolution")
    if resolution then
        local height = tonumber(string_match(resolution, "%d+x(%d+)"))
        if height then sfui.pixelScale = 768 / (height * UIParent:GetScale()) end
    end
end
sfui.update_pixel_scale = update_pixel_scale

-- Event frame for scale updates
local scale_event_frame = CreateFrame("Frame")
scale_event_frame:RegisterEvent("UI_SCALE_CHANGED")
scale_event_frame:SetScript("OnEvent", update_pixel_scale)


function sfui.slash_command_handler(msg)
    if msg == "" then
        if sfui.toggle_options_panel then sfui.toggle_options_panel() else print("sfui: options panel not available.") end
    elseif msg == "research" then
        if sfui.research and sfui.research.toggle_selection then
            sfui.research.toggle_selection()
        else
            print("sfui: research viewer not available.")
        end
    elseif msg == "cv" then
        if sfui.trackedoptions and sfui.trackedoptions.toggle_viewer then
            sfui.trackedoptions.toggle_viewer()
        else
            print("sfui: cooldown viewer not available.")
        end
    end
end

-- function to handle /rl slash command
function sfui.reload_ui_handler(msg)
    C_UI.Reload()
end

SlashCmdList["SFUI"] = sfui.slash_command_handler
SlashCmdList["RL"] = sfui.reload_ui_handler
local event_frame = CreateFrame("Frame")
event_frame:RegisterEvent("ADDON_LOADED")
event_frame:RegisterEvent("PLAYER_LOGIN")


local ipairs = ipairs

event_frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if string_lower(name) == "sfui" then
            local LSM = LibStub("LibSharedMedia-3.0", true)
            if LSM then
                LSM:Register("statusbar", "Flat", "Interface/Buttons/WHITE8X8")
                LSM:Register("statusbar", "Blizzard", "Interface/TargetingFrame/UI-StatusBar")
                LSM:Register("statusbar", "Raid", "Interface/RaidFrame/Raid-Bar-Hp-Fill")
                LSM:Register("statusbar", "Spark", "Interface/CastingBar/UI-CastingBar-Spark")
            end

            -- Database & Config Sync
            SfuiDB = SfuiDB or {}
            SfuiDB.alts = SfuiDB.alts or {}
            SfuiDB.minimap_icon = SfuiDB.minimap_icon or {}
            SfuiDB.gear = SfuiDB.gear or {}
            SfuiDecorDB = SfuiDecorDB or {}
            SfuiDecorDB.items = SfuiDecorDB.items or {}

            if sfui.initialize_database then
                sfui.initialize_database()
            end

            -- Migrate cooldown panels to per-spec structure
            if sfui.common and sfui.common.migrate_cooldown_panels_to_spec then
                sfui.common.migrate_cooldown_panels_to_spec()
            end

            local tocVersion = C_AddOns.GetAddOnMetadata("sfui", "Version")
            if tocVersion then
                sfui.config.version = tocVersion
            end

            if sfui.config and sfui.config.cvars_on_load then
                for _, cvar_data in ipairs(sfui.config.cvars_on_load) do
                    C_CVar.SetCVar(cvar_data.name, cvar_data.value)
                end
            end

            -- Enforce Combat Text Settings from DB
            local combatTextCVars = {
                "enableFloatingCombatText",
                "floatingCombatTextCombatDamage",
                "floatingCombatTextCombatLogPeriodicSpells",
                "floatingCombatTextCombatHealing",
                "floatingCombatTextPetMeleeDamage",
                "floatingCombatTextPetSpellDamage",
                "floatingCombatTextDodgeParryMiss",
                "floatingCombatTextDamageReduction",
                "floatingCombatTextEnergyGains",
                "floatingCombatTextAuras",
                "floatingCombatTextCombatState"
            }
            for _, cvar in ipairs(combatTextCVars) do
                if SfuiDB[cvar] ~= nil then
                    C_CVar.SetCVar(cvar, SfuiDB[cvar] and "1" or "0")
                end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        if sfui.update_pixel_scale then sfui.update_pixel_scale() end

        if sfui.create_currency_frame then
            sfui.create_currency_frame()
        end
        if sfui.create_item_frame then
            sfui.create_item_frame()
        end
        if sfui.bars and sfui.bars.on_state_changed then
            sfui.bars:on_state_changed()
        end
        if sfui.research and sfui.research.initialize then
            sfui.research.initialize()
        end
        if sfui.automation and sfui.automation.initialize then
            sfui.automation.initialize()
        end
        if sfui.cursor and sfui.cursor.initialize then
            sfui.cursor.initialize()
        end
        if sfui.trackedbars and sfui.trackedbars.initialize then
            sfui.trackedbars.initialize()
        end
        if sfui.trackedicons and sfui.trackedicons.initialize then
            sfui.trackedicons.initialize()
        end
        if sfui.trackedoptions and sfui.trackedoptions.initialize then
            sfui.trackedoptions.initialize()
        end
        if sfui.alts and sfui.alts.initialize then
            sfui.alts.initialize()
        end
        if sfui.portals and sfui.portals.initialize then
            sfui.portals.initialize()
        end



        if not LibStub then
            print("|cffff0000SFUI Error:|r LibStub global not found!")
            return
        end

        -- Initialize Minimap Menu
        if not SfuiMinimapMenu then
            SfuiMinimapMenu = CreateFrame("Frame", "SfuiMinimapMenu", UIParent, "BackdropTemplate")
            SfuiMinimapMenu:SetSize(160, 130)
            SfuiMinimapMenu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
            SfuiMinimapMenu:SetBackdropColor(0, 0, 0, 0.5)
            SfuiMinimapMenu:SetFrameStrata("TOOLTIP")
            SfuiMinimapMenu:SetClampedToScreen(true)

            local function AddMenuButton(text, func, y)
                local btn = sfui.common.create_flat_button(SfuiMinimapMenu, text, 150, 20)
                btn:SetPoint("TOP", 0, y)
                btn:SetScript("OnClick", function()
                    SfuiMinimapMenu:Hide()
                    if func then func() end
                end)
            end

            AddMenuButton("|cff00ffffOptions|r", function() sfui.toggle_options_panel() end, -5)
            AddMenuButton("|cff00ff00Tracking Manager|r", function()
                if sfui.trackedoptions and sfui.trackedoptions.toggle_viewer then
                    sfui.trackedoptions.toggle_viewer()
                end
            end, -30)
            AddMenuButton("|cff9966ffAlts|r", function()
                if sfui.alts and sfui.alts.Toggle then
                    sfui.alts.Toggle()
                end
            end, -55)
            AddMenuButton("|cff99ccffResearch Viewer|r", function()
                if sfui.research and sfui.research.toggle_selection then
                    sfui.research.toggle_selection()
                end
            end, -80)
            AddMenuButton("|cffff9900Portals|r", function()
                if sfui.portals and sfui.portals.Toggle then
                    sfui.portals.Toggle()
                end
            end, -105)

            SfuiMinimapMenu.throttle = 0
            SfuiMinimapMenu.hideTimer = 0
            SfuiMinimapMenu:SetScript("OnUpdate", function(self, elapsed)
                self.throttle = self.throttle + elapsed
                if self.throttle < 0.5 then return end
                self.throttle = 0

                if self:IsMouseOver() or (self.anchor and self.anchor:IsMouseOver()) then
                    self.hideTimer = 0
                else
                    self.hideTimer = (self.hideTimer or 0) + 0.5
                    if self.hideTimer > 0.5 then
                        self:Hide()
                    end
                end
            end)
            SfuiMinimapMenu:Hide()
        end

        local ldb, icon = LibStub("LibDataBroker-1.1", true), LibStub("LibDBIcon-1.0", true)
        if ldb and icon then
            local broker = ldb:NewDataObject("sfui", {
                type = "launcher",
                text = "sfui",
                icon = sfui.config.appearance.addonIcon,
                OnClick = function(self, button)
                    if button == "LeftButton" then
                        if SfuiMinimapMenu:IsShown() then
                            SfuiMinimapMenu:Hide()
                        else
                            SfuiMinimapMenu.anchor = self
                            SfuiMinimapMenu.throttle = 0
                            SfuiMinimapMenu.hideTimer = 0
                            SfuiMinimapMenu:ClearAllPoints()
                            SfuiMinimapMenu:SetPoint("TOPRIGHT", self, "BOTTOMRIGHT", 0, -5)
                            SfuiMinimapMenu:Show()
                        end
                    elseif button == "RightButton" then
                        if IsShiftKeyDown() then
                            C_UI.Reload()
                        elseif sfui.alts and sfui.alts.Toggle then
                            sfui.alts.Toggle()
                        end
                    end
                end,
                OnTooltipShow = function(tooltip)
                    tooltip:AddLine("sfui")
                    tooltip:AddLine("Left-click for Menu", 0.2, 1, 0.2)
                    tooltip:AddLine("Right-click for Alts", 0.4, 0.7, 1)
                    tooltip:AddLine("Shift+Right-click to Reload UI", 1, 0.2, 0.2)
                end,
            })
            icon:Register("sfui", broker, SfuiDB.minimap_icon)
        end
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)
