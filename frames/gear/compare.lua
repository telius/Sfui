local addonName, addon = ...
sfui = sfui or {}
sfui.compare = {}

local active = false

local function update_cvar()
    if not SfuiDB.enableAutoCompare then
        if active then
            C_CVar.SetCVar("alwaysCompareItems", "0")
            active = false
        end
        return
    end

    if not active then
        C_CVar.SetCVar("alwaysCompareItems", "1")
        active = true
    end
end

function sfui.compare.init()
    if SfuiDB.enableAutoCompare == nil then
        SfuiDB.enableAutoCompare = true
    end

    update_cvar()

    -- Hook into equipment events to ensure the CVar stays set
    sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", update_cvar)
    sfui.events.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", update_cvar)
end
