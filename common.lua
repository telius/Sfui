local addonName, addon = ...
sfui = sfui or {}
sfui.common = {}

function sfui.common.print(msg, ...)
    if sfui.config and sfui.config.prefix then
        print(sfui.config.prefix .. " " .. tostring(msg), ...)
    else
        print("|cff6600ffsfui:|r " .. tostring(msg), ...)
    end
end

-- Static pcall targets (Performance optimization: no closures in hot paths)
local function pcall_issecret(val)
    if type(val) == "number" then
        return val + 0 == val
    end
    return val == val
end
local function pcall_num_pos(val) return type(val) == "number" and val > 0 end
local function pcall_gt(v1, v2) return v1 > (v2 or 0) end
local function pcall_identity(val) return val end

local function pcall_math_probe(val)
    -- This operation will explicitly crash if 'val' is a Mythic+ Private Aura 'Secret Value' (userdata)
    return val + 0
end

local function issecretvalue(val)
    if val == nil then return false end

    if _G.issecretvalue and _G.issecretvalue(val) then return true end

    -- Fast early exit: if the engine reports no secret restrictions are active at all
    -- (12.0.5+ C_Secrets API), there's no need to run the expensive arithmetic probe.
    -- HasSecretRestrictions() covers cooldown/aura secrets; ShouldUnitStatsBeSecret()
    -- (new in 12.0.5) covers stat/power queries (e.g. UnitPower in PvP/M+).
    local C_Secrets = _G.C_Secrets
    if C_Secrets then
        local noAuraSecrets = C_Secrets.HasSecretRestrictions and not C_Secrets.HasSecretRestrictions()
        local noStatSecrets = C_Secrets.ShouldUnitStatsBeSecret == nil
                           or not C_Secrets.ShouldUnitStatsBeSecret()
        if noAuraSecrets and noStatSecrets then
            return false
        end
    end

    -- Deeper check: force an arithmetic mutation safely inside a protected call.
    -- If 'val' is a secure userdata (Secret Value), this math evaluation throws a C++ exception internally
    local success = pcall(pcall_math_probe, val)
    if not success then return true end

    return false
end
sfui.common.issecretvalue = issecretvalue

-- Standard Tooltip Reference (Dedicated isolated frame to prevent UIWidgetManager taint on global GameTooltip)
local sfuiTooltip = CreateFrame("GameTooltip", "SfuiGameTooltip", UIParent, "GameTooltipTemplate")
sfui.tooltip = sfuiTooltip
sfui.common.tooltip = sfuiTooltip

-- Robust helper to check if an aura/ID is present, even if it's a secret value
function sfui.common.HasAuraInstanceID(value)
    if value == nil then return false end
    if issecretvalue(value) then return true end
    if type(value) == "number" and value == 0 then return false end
    return true
end

-- Safe numeric comparison
function sfui.common.IsNumericAndPositive(value)
    if value == nil then return false end
    local ok, result = pcall(pcall_num_pos, value)
    return ok and result
end

-- ────────────────────────────────────────────────────────────────────────────
-- Pre-computed String Lookup Tables (Zero-Allocation Hot Path)
-- ────────────────────────────────────────────────────────────────────────────
local INT_STR_LUT = {}
for i = 0, 200 do
    INT_STR_LUT[i] = tostring(i)
end

local DEC_STR_LUT = {}
for i = 1, 50 do
    DEC_STR_LUT[i] = string.format("%.1f", i / 10)
end

local FMT_PATTERNS = {
    [0] = "%.0f",
    [1] = "%.1f",
    [2] = "%.2f",
}

--- Fast zero-allocation integer-to-string lookup for numbers 0-200.
--- Falls back to tostring for larger values and handles secret values safely.
function sfui.common.get_cached_int_string(val)
    if val == nil then return "" end
    local t = type(val)
    if t == "number" then
        local floorVal = math.floor(val)
        return INT_STR_LUT[floorVal] or tostring(floorVal)
    elseif t == "string" then
        return val
    end
    local ok, str = pcall(tostring, val)
    return ok and str or ""
end

--- Safe zero-allocation duration formatting.
--- Utilizes pre-computed LUT for integer seconds (0-200s) and fast sub-5s decimals (0.1-5.0s).
function sfui.common.SafeFormatDuration(value, decimals)
    if value == nil then return "" end
    if issecretvalue(value) then return value end

    local num = tonumber(value)
    if not num then return tostring(value) end

    decimals = decimals or 0
    if decimals == 0 then
        local intVal = math.floor(num + 0.5)
        if intVal >= 0 and intVal <= 200 then
            return INT_STR_LUT[intVal]
        end
    elseif decimals == 1 and num >= 0.1 and num <= 5.0 then
        local decKey = math.floor(num * 10 + 0.5)
        if decKey >= 1 and decKey <= 50 then
            return DEC_STR_LUT[decKey]
        end
    end

    local fmt = FMT_PATTERNS[decimals] or ("%." .. decimals .. "f")
    local ok, formatted = pcall(string.format, fmt, num)
    return ok and formatted or tostring(value)
end

-- Helper: Check if Mounted OR in Druid Travel Form (Spell 783)
function sfui.common.is_mounted_or_travel_form()
    if IsMounted() then return true end
    if sfui.common.get_player_class() == "DRUID" and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        return C_UnitAuras.GetPlayerAuraBySpellID(783) ~= nil
    end
    return false
end

-- Helper: Check for Dragonriding state (Vigor)
function sfui.common.IsDragonriding()
    if not sfui.common.is_mounted_or_travel_form() then return false end

    -- Check for Vigor (Enum.PowerType.AlternateMount = 29)
    -- This resource is only active/max > 0 when on a Dragonriding/Skyriding mount
    if UnitPowerMax("player", 29) > 0 then
        return true
    end

    -- Fallback: Check for Gliding Info
    local isDragonriding = false
    pcall(function()
        if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
            local _, canGlide = C_PlayerInfo.GetGlidingInfo()
            if canGlide then isDragonriding = true end
        end
    end)
    return isDragonriding
end

-- Safe helper to check if player is on GCD and get the duration
function sfui.common.GetGCDInfo()
    local ok, ci = pcall(C_Spell.GetSpellCooldown, 61304)
    if ok and ci and ci.duration and ci.duration > 0 then
        return true, ci.duration
    end
    return false, 0
end

-- Reusable cooldown lookups
local function pcall_charge_dur(id) return C_Spell.GetSpellChargeDuration(id) end
local function pcall_spell_dur(id) return C_Spell.GetSpellCooldownDuration(id) end

-- Safe helper to get a duration object for a spell (nil check is non-secret)
function sfui.common.GetCooldownDurationObj(spellID)
    if not spellID then return nil end
    local ok, obj
    if C_Spell.GetSpellChargeDuration then
        ok, obj = pcall(pcall_charge_dur, spellID)
    end
    if not ok or not obj then
        if C_Spell.GetSpellCooldownDuration then
            ok, obj = pcall(pcall_spell_dur, spellID)
        end
    end
    -- Return object as-is, let caller handle GCD
    return obj
end

local function _get_cooldown_duration(frame)
    return frame:GetCooldownDuration()
end

local function _gt(v1, v2)
    return v1 > v2
end

local function _lt(v1, v2)
    return v1 < v2
end

local function _arithmetic(op, v1, v2)
    if op == "+" then return v1 + v2 end
    if op == "-" then return v1 - v2 end
    if op == "*" then return v1 * v2 end
    if op == "/" then return (v2 ~= 0) and (v1 / v2) or 0 end
end

-- Check if a cooldown frame is showing an active cooldown
-- Uses frame methods that work with secret values
function sfui.common.IsCooldownFrameActive(cooldownFrame)
    if not cooldownFrame then return false end

    -- GetCooldownDuration returns duration in milliseconds
    -- Can be secret, but we can pass it to comparison via pcall
    local ok, duration = pcall(_get_cooldown_duration, cooldownFrame)

    if not ok then return false end

    -- If duration is secret, check if it's just GCD
    if issecretvalue(duration) then
        local onGCD, gcdDur = sfui.common.GetGCDInfo()
        -- If player is on GCD, assume this is GCD and not a real cooldown
        if onGCD then return false end
        -- Otherwise assume it's a real cooldown (secret in M+)
        return true
    end

    -- Non-secret: check if > 1510ms (exclude GCD + small buffer)
    if not duration or duration == 0 then
        return false
    end

    local onGCD, gcdDur = sfui.common.GetGCDInfo()
    if onGCD and duration <= (gcdDur * 1000 + 10) then
        return false
    end

    return duration > (sfui.config.castBar.gcdThreshold or 1510)
end

-- Safe comparison helpers (Crash-proof against Secret Values in M+)
function sfui.common.SafeGT(val, target)
    if val == nil or target == nil then return false end
    local ok, result = pcall(_gt, val, target)
    return ok and result or false
end

-- Safe comparison helpers (Crash-proof against Secret Values in M+)
function sfui.common.SafeLT(val, target)
    if val == nil or target == nil then return false end
    local ok, result = pcall(_lt, val, target)
    return ok and result or false
end

-- Safe arithmetic to bypass "arithmetic on secret number" errors when tainted.
function sfui.common.SafeArithmetic(op, v1, v2)
    if v1 == nil or v2 == nil then return 0 end
    local ok, res = pcall(_arithmetic, op, v1, v2)
    return ok and res or 0
end

function sfui.common.SafeValue(val, fallback)
    if val == nil then return fallback end
    if issecretvalue(val) then return val end
    local ok, result = pcall(pcall_identity, val)
    if ok then return result else return fallback end
end

function sfui.common.SafeNotFalse(val)
    if val == nil then return true end
    if issecretvalue(val) then return true end
    return val ~= false
end

-- Safely set text on a fontstring (SetText accepts secret values)
function sfui.common.SafeSetText(fontString, text, decimals)
    if not fontString then return end
    -- if decimals is nil and text is a string, skip duration formatting to avoid 0.0 suffix
    if decimals == nil and type(text) == "string" then
        fontString:SetText(text)
    else
        fontString:SetText(sfui.common.SafeFormatDuration(text, decimals) or "")
    end
end

-- Safely set value on a statusbar (SetValue accepts secret values)
function sfui.common.SafeSetValue(bar, value)
    if not bar or not bar.SetValue then return end
    bar:SetValue(value or 0)
end

-- Safely set money display in a tooltip using securecall to avoid arithmetic taint.
function sfui.common.SafeSetTooltipMoney(tooltip, amount, label)
    if not tooltip or amount == nil then return end

    -- Use securecall to get a safe coin string.
    -- Constructing the tooltip line manually with strings avoids triggering
    -- arithmetic in the MoneyFrame widget during GameTooltip:Show().
    local coinStr = sfui.common.SafeGetCoinTextureString(amount)

    if label then
        tooltip:AddDoubleLine(label, coinStr, 1, 1, 1, 1, 1, 1)
    else
        tooltip:AddLine(coinStr)
    end
end

-- Safely add a money line using GetCoinTextureString via securecall
function sfui.common.SafeAddMoneyLine(tooltip, label, amount)
    if not tooltip or amount == nil then return end

    local ok, coinStr = securecall(pcall, GetCoinTextureString, amount)
    if ok and coinStr then
        tooltip:AddLine((label or "") .. coinStr)
    else
        tooltip:AddLine((label or "") .. "|cff00ffff[Protected Data]|r")
    end
end

-- Safely get a coin texture string using securecall
function sfui.common.SafeGetCoinTextureString(amount)
    if amount == nil then return "" end
    local ok, coinStr = securecall(pcall, GetCoinTextureString, amount)
    if ok and coinStr then
        return coinStr
    else
        return "|cff00ffff[Protected]|r"
    end
end

-- Safely compare units (UnitIsUnit crashes on secret values if execution is tainted)
function sfui.common.SafeUnitIsUnit(unit1, unit2)
    if not unit1 or not unit2 then return false end
    if issecretvalue(unit1) or issecretvalue(unit2) then
        -- In secret context, we can't safely use UnitIsUnit.
        -- We fall back to direct string comparison if they are strings.
        if type(unit1) == "string" and type(unit2) == "string" then
            return unit1 == unit2
        end
        return false
    end
    local success, result = pcall(UnitIsUnit, unit1, unit2)
    return success and result
end

function sfui.common.copy(t)
    if type(t) ~= "table" then return t end
    local res = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            res[k] = sfui.common.copy(v)
        else
            res[k] = v
        end
    end
    return res
end

local _, playerClass, playerClassID = UnitClass("player")

local wipe = wipe
local C_Timer = C_Timer

-- Returns the cached player class (e.g., "WARRIOR", "MAGE")
function sfui.common.get_player_class()
    return playerClass, playerClassID
end

-- Helper to safely ensure tracked bar DB structure exists
-- Returns the tracked bar entry for the given cooldownID, or the trackedBarsBySpec table if no ID provided
function sfui.common.ensure_tracked_bar_db(cooldownID)
    SfuiDB = SfuiDB or {}
    SfuiDB.trackedBars = SfuiDB.trackedBars or {}

    local specID = sfui.common.get_current_spec_id() or 0
    SfuiDB.trackedBarsBySpec = SfuiDB.trackedBarsBySpec or {}
    SfuiDB.trackedBarsBySpec[specID] = SfuiDB.trackedBarsBySpec[specID] or {}

    local specBars = SfuiDB.trackedBarsBySpec[specID]

    if cooldownID then
        specBars[cooldownID] = specBars[cooldownID] or {}
        return specBars[cooldownID]
    end
    return specBars
end

function sfui.common.get_tracked_bars()
    local specID = sfui.common.get_current_spec_id() or 0
    SfuiDB = SfuiDB or {}
    SfuiDB.trackedBarsBySpec = SfuiDB.trackedBarsBySpec or {}
    SfuiDB.trackedBarsBySpec[specID] = SfuiDB.trackedBarsBySpec[specID] or {}
    return SfuiDB.trackedBarsBySpec[specID]
end

-- ========================================
-- Per-Spec Configuration Migrations
-- ========================================

function sfui.common.migrate_tracked_bars_to_spec()
    SfuiDB = SfuiDB or {}
    SfuiDB.trackedBars = SfuiDB.trackedBars or {}

    local specID = sfui.common.get_current_spec_id() or 0
    SfuiDB.trackedBarsBySpec = SfuiDB.trackedBarsBySpec or {}

    -- If current spec is already populated, assume migration ran previously for this spec
    if SfuiDB.trackedBarsBySpec[specID] and next(SfuiDB.trackedBarsBySpec[specID]) then
        return
    end

    SfuiDB.trackedBarsBySpec[specID] = {}
    local specBars = SfuiDB.trackedBarsBySpec[specID]
    local keysToRemove = {}

    -- Extract numeric IDs (Population) to the per-Spec array
    for k, v in pairs(SfuiDB.trackedBars) do
        if type(k) == "number" then
            specBars[k] = v
            table.insert(keysToRemove, k)
        end
    end

    -- Remove the numeric IDs from the global settings root
    for _, k in ipairs(keysToRemove) do
        SfuiDB.trackedBars[k] = nil
    end
end

-- ========================================
-- Per-Spec Panel Configuration Helpers
-- ========================================

-- One-time migration from old flat array to per-spec structure
function sfui.common.migrate_cooldown_panels_to_spec()
    -- Skip if already migrated or nothing to migrate
    if SfuiDB.cooldownPanelsBySpec or not SfuiDB.cooldownPanels then
        return
    end

    -- Get current spec
    local currentSpecID = sfui.common.get_current_spec_id()
    if not currentSpecID or currentSpecID == 0 then
        -- No spec yet (low level character), defer migration
        return
    end

    -- Migrate existing panels to current spec
    SfuiDB.cooldownPanelsBySpec = {
        [currentSpecID] = SfuiDB.cooldownPanels
    }

    -- Mark old format as migrated (keep for reference but don't use)
    SfuiDB._cooldownPanelsMigrated = true
end

-- Shared helper to get categorized CDM entries
local function get_all_cdm_entries()
    local cat0 = {} -- Essential
    local cat1 = {} -- Utility

    local function categorize(cooldownID, info)
        if not info or not info.isKnown then return end
        local entry = {
            type = "cooldown",
            cooldownID = cooldownID,
            spellID = info.spellID,
            id = info.spellID,
            settings = { showText = true }
        }
        if info.category == 0 or not info.category then
            table.insert(cat0, entry)
        elseif info.category == 1 then
            table.insert(cat1, entry)
        end
    end

    -- Try using CooldownViewerSettings DataProvider
    if CooldownViewerSettings and CooldownViewerSettings.GetDataProvider then
        local dataProvider = CooldownViewerSettings:GetDataProvider()
        local cooldownIDs = dataProvider and dataProvider:GetOrderedCooldownIDs()
        if cooldownIDs then
            for _, cooldownID in ipairs(cooldownIDs) do
                if not sfui.common.issecretvalue(cooldownID) then
                    categorize(cooldownID, dataProvider:GetCooldownInfoForID(cooldownID))
                end
            end
        end
    end

    -- Fallback: use C_CooldownViewer direct API if provider not ready or empty
    if #cat0 == 0 and #cat1 == 0 and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
        for cat = 0, 1 do
            local cooldownIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)
            if cooldownIDs then
                for _, cooldownID in ipairs(cooldownIDs) do
                    categorize(cooldownID, C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID))
                end
            end
        end
    end

    return cat0, cat1
end

-- Populate CENTER panel with cooldowns from CDM Essential Cooldowns (category 0)
function sfui.common.populate_center_panel_from_cdm()
    local cat0, _ = get_all_cdm_entries()
    local entries = {}
    -- CENTER holds 7 max
    for i = 1, math.min(7, #cat0) do
        table.insert(entries, cat0[i])
    end
    return entries
end

-- Populate UTILITY panel with cooldowns from CDM Group 1 (Category 1) + overflow
function sfui.common.populate_utility_panel_from_cdm()
    local cat0, cat1 = get_all_cdm_entries()
    local entries = {}

    -- 1. Add overflow from cat 0 (index 8+)
    if #cat0 > 7 then
        for i = 8, #cat0 do
            table.insert(entries, cat0[i])
        end
    end

    -- 2. Add cat 1
    for _, entry in ipairs(cat1) do
        table.insert(entries, entry)
    end

    return entries
end

-- Cached panels reference (invalidated on spec change or panel modification)
local _cachedPanels = nil
local _cachedPanelsSpecID = nil

-- Get panels for current spec (Pure accessor, hot-path safe)
function sfui.common.get_cooldown_panels()
    local specID = sfui.common.get_current_spec_id() or 0

    -- Return cached if valid
    if _cachedPanels and _cachedPanelsSpecID == specID and #_cachedPanels > 0 then
        return _cachedPanels
    end

    if not SfuiDB.cooldownPanelsBySpec or not SfuiDB.cooldownPanelsBySpec[specID] or #SfuiDB.cooldownPanelsBySpec[specID] == 0 or ((sfui.common.get_player_class() == "DRUID" or sfui.common.get_player_class() == "ROGUE") and not SfuiDB.druidMigrationV7) then
        _cachedPanels = sfui.common.ensure_panels_initialized()
    else
        _cachedPanels = SfuiDB.cooldownPanelsBySpec[specID]
    end
    _cachedPanelsSpecID = specID
    return _cachedPanels
end

-- Invalidate panels cache (call when panels are modified)
function sfui.common.invalidate_panels_cache()
    _cachedPanels = nil
    _cachedPanelsSpecID = nil
end

-- Get only the active (available) entries for a panel (reusable destination table support)
function sfui.common.get_active_panel_entries(panelConfig, outTable)
    local activeEntries = outTable or {}
    _G.wipe(activeEntries)
    if not panelConfig or type(panelConfig.entries) ~= "table" then return activeEntries end
    for _, entry in ipairs(panelConfig.entries) do
        local isKnown = true
        local typeHint = (type(entry) == "table" and entry.type) or "spell"

        if (typeHint == "spell" or typeHint == "cooldown") and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
            local id = (type(entry) == "table" and entry.id) or entry
            local cdID = (type(entry) == "table" and entry.cooldownID) or id
            local cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
            if cdInfo and cdInfo.isKnown == false then
                isKnown = false
            end
        end

        -- Hero Talent Filter logic
        -- Hero Talent Filter logic
        if isKnown and type(entry) == "table" and entry.settings then
            -- Fallback for legacy single-item filter setting to new table format
            if entry.settings.heroTalentFilter and entry.settings.heroTalentFilter ~= "Any" and entry.settings.heroTalentFilter ~= 0 then
                if not entry.settings.heroTalentWhitelist then
                    entry.settings.heroTalentWhitelist = {}
                end
                entry.settings.heroTalentWhitelist[entry.settings.heroTalentFilter] = true
                entry.settings.heroTalentFilter = nil
            end

            if entry.settings.heroTalentsDisabled then
                entry.settings.heroTalentsDisabled = nil
            end

            if entry.settings.heroTalentWhitelist then
                local hasWhitelistItems = false
                for k, v in pairs(entry.settings.heroTalentWhitelist) do
                    if v then
                        hasWhitelistItems = true
                        break
                    end
                end

                if hasWhitelistItems then
                    local activeHeroSpec = C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec and
                        C_ClassTalents.GetActiveHeroTalentSpec()
                    if not activeHeroSpec or not entry.settings.heroTalentWhitelist[activeHeroSpec] then
                        isKnown = false
                    end
                end
            end
        end

        if isKnown then
            table.insert(activeEntries, entry)
        end
    end
    return activeEntries
end

-- Ensure panels exist and are populated (Called once on load/spec/talent change)
function sfui.common.ensure_panels_initialized()
    local specID = sfui.common.get_current_spec_id() or 0
    local playerClass = sfui.common.get_player_class()

    SfuiDB.cooldownPanelsBySpec = SfuiDB.cooldownPanelsBySpec or {}
    SfuiDB.cooldownPanelsBySpec[specID] = SfuiDB.cooldownPanelsBySpec[specID] or {}

    local panels = SfuiDB.cooldownPanelsBySpec[specID]
    local changed = false

    SfuiDB.iconsInitializedBySpec = SfuiDB.iconsInitializedBySpec or {}

    local defaultPanelSpecs = {
        { key = "center_panel", name = "CENTER",  populateFunc = sfui.common.populate_center_panel_from_cdm },
        { key = "utility",      name = "UTILITY", populateFunc = sfui.common.populate_utility_panel_from_cdm },
        { key = "left",         name = "Left" },
        { key = "right",        name = "Right" },
    }

    if playerClass == "DRUID" or playerClass == "ROGUE" then
        -- Inject druid/rogue specific default forms immediately after the base CENTER panel (index 1)
        defaultPanelSpecs[1].requiredForm = 0
    end

    if playerClass == "DRUID" then
        table.insert(defaultPanelSpecs, 2, { key = "center_panel", name = "CAT", requiredForm = 1 })
        table.insert(defaultPanelSpecs, 3, { key = "center_panel", name = "BEAR", requiredForm = 5 })
        table.insert(defaultPanelSpecs, 4, { key = "center_panel", name = "MOONKIN", requiredForm = { 31, 35 } })
        table.insert(defaultPanelSpecs, 5, { key = "center_panel", name = "STEALTH", requiredForm = "stealth" })
    end

    -- Migrate legacy trackedIcons if not already done for this spec
    local migratedEntries = nil
    if not SfuiDB.iconsInitializedBySpec[specID] and SfuiDB.trackedIcons then
        migratedEntries = {}
        for id, cfg in pairs(SfuiDB.trackedIcons) do
            if type(id) == "number" then
                table.insert(migratedEntries, { id = id, settings = cfg, type = "spell" })
            end
        end
    end

    for _, spec in ipairs(defaultPanelSpecs) do
        local panelIdx = nil
        local uSpecName = string.upper(spec.name)
        for i, panel in ipairs(panels) do
            local uPanelName = string.upper(panel.name or "")
            if uPanelName == uSpecName then
                panelIdx = i
                break
                -- Also match if the database name is "CENTER" but we are looking for "CENTER" (we rename visually only in cdm)
            elseif uPanelName == "CENTER" and uSpecName == "CENTER" and spec.requiredForm == 0 then
                panelIdx = i
                break
            end
        end

        if not panelIdx then
            local newPanel = sfui.common.copy(sfui.config.cooldown_panel_defaults[spec.key])
            if spec.populateFunc then
                if not SfuiDB.iconsInitializedBySpec[specID] then
                    newPanel.entries = spec.populateFunc()
                else
                    newPanel.entries = {}
                end
            elseif spec.name == "Left" and migratedEntries then
                newPanel.entries = migratedEntries
            else
                newPanel.entries = {}
            end
            if spec.requiredForm ~= nil then
                newPanel.requiredForm = spec.requiredForm
            end
            newPanel.name = spec.name
            newPanel.specID = specID
            table.insert(panels, newPanel)

            -- Ensure "utility" and "center_panel" get their specific defaults applied robustly
            if spec.key == "utility" or spec.key == "center_panel" then
                local defaults = sfui.config.cooldown_panel_defaults[spec.key]
                for k, v in pairs(defaults) do
                    if newPanel[k] == nil then newPanel[k] = v end
                end
            end
            changed = true
        else
            -- Ensure all default keys exist in existing panel (merge missing)
            local panel = panels[panelIdx]
            local default = sfui.config.cooldown_panel_defaults[spec.key]
            if type(default) == "table" then
                for k, v in pairs(default) do
                    if panel[k] == nil then
                        panel[k] = v
                        changed = true
                    end
                end
            end

            -- Removing automatic population of existing empty panels to give user full control.
        end
    end

    -- Fast migration fallback and cleanup
    if (playerClass == "DRUID" or playerClass == "ROGUE") and not SfuiDB.druidMigrationV7 then
        local hasBareCenter = false
        local upper = string.upper
        for _, p in ipairs(panels) do
            if p.name and upper(p.name) == "CENTER" then
                hasBareCenter = true; break
            end
        end

        for i = #panels, 1, -1 do
            local p = panels[i]
            local uname = upper(p.name)
            -- Retroactively apply requiredForm to bare 'CENTER' panels if missing
            if uname == "CENTER" and p.requiredForm == nil then
                p.requiredForm = 0
                changed = true
            end

            if playerClass == "DRUID" then
                -- Rename legacy named panels if we don't have a bare CENTER yet, otherwise purge ghosts
                if uname == "CENTER (BASE FORM)" then
                    if not hasBareCenter then
                        p.name = "CENTER"
                        p.requiredForm = 0
                        hasBareCenter = true
                        changed = true
                    else
                        table.remove(panels, i)
                        changed = true
                    end
                elseif uname == "CENTER (CAT FORM)" or uname == "CENTER (BEAR FORM)" or uname == "CENTER (MOONKIN FORM)" then
                    table.remove(panels, i)
                    changed = true
                end
            end
        end
        SfuiDB.druidMigrationV7 = true
    end

    -- Cleanup duplicates generated by bug for the exact target names (case-insensitive)
    local seenUpperNames = {}
    local upper = string.upper
    local builtins = {
        CENTER = true,
        UTILITY = true,
        LEFT = true,
        RIGHT = true,
        CAT = true,
        BEAR = true,
        MOONKIN = true,
        STEALTH = true
    }

    for i = #panels, 1, -1 do
        local pName = panels[i].name
        if pName then
            local uName = upper(pName)
            if builtins[uName] then
                if seenUpperNames[uName] then
                    table.remove(panels, i)
                    changed = true
                else
                    seenUpperNames[uName] = true
                end
            end
        end
    end

    if not SfuiDB.iconsInitializedBySpec[specID] then
        SfuiDB.iconsInitializedBySpec[specID] = true
        if migratedEntries then SfuiDB.trackedIcons = nil end -- Clear global migration source once first spec consumes it
        changed = true
    end

    if changed then
        sfui.common.set_cooldown_panels(panels)
    else
        -- If no entries were found but population was expected, retry once after a short delay
        -- This handles the race condition on fresh installations/characters
        if not SfuiDB._populationRetryDone then
            local needsRetry = false
            for _, panel in ipairs(panels) do
                if (panel.name == "CENTER" or panel.name == "UTILITY") and (#panel.entries == 0) then
                    needsRetry = true
                    break
                end
            end

            if needsRetry then
                SfuiDB._populationRetryDone = true
                C_Timer.After(2, function()
                    sfui.common.ensure_panels_initialized()
                end)
            end
        end
    end

    return panels
end

function sfui.common.add_custom_panel(name)
    if not name or name == "" then return end
    local panels = sfui.common.get_cooldown_panels()

    -- Prevent creating duplicate builtin panels
    if name == "CENTER" or name == "UTILITY" or name == "Left" or name == "Right" or name == "CAT" or name == "BEAR" or name == "MOONKIN" or name == "STEALTH" then
        for _, p in ipairs(panels) do
            if p.name == name then return #panels end
        end
    end

    -- Use 'utility' as a template for custom panels since it's a good middle ground
    local newPanel = sfui.common.copy(sfui.config.cooldown_panel_defaults.utility)
    newPanel.name = name
    newPanel.entries = {}
    newPanel.specID = sfui.common.get_current_spec_id()

    table.insert(panels, newPanel)
    return #panels
end

function sfui.common.delete_custom_panel(index)
    local panels = sfui.common.get_cooldown_panels()
    if panels[index] then
        table.remove(panels, index)
        return true
    end
    return false
end

-- Set panels for current spec
function sfui.common.set_cooldown_panels(panels)
    local specID = sfui.common.get_current_spec_id()
    if not specID or specID == 0 then return end

    SfuiDB.cooldownPanelsBySpec = SfuiDB.cooldownPanelsBySpec or {}
    SfuiDB.cooldownPanelsBySpec[specID] = panels
    sfui.common.invalidate_panels_cache()
end

-- Get all available anchor targets for icon panels
function sfui.common.get_all_anchor_targets(excludeName)
    local targets = {
        { text = "Screen (UIParent)", value = "UIParent" },
        { text = "Health Bar",        value = "Health Bar" },
        { text = "Tracked Bars",      value = "Tracked Bars" },
    }

    -- Add all panels as potential targets
    local panels = sfui.common.get_cooldown_panels()
    if panels then
        for _, p in ipairs(panels) do
            if p.name and p.name ~= excludeName then
                table.insert(targets, { text = "Panel: " .. p.name, value = p.name })
            end
        end
    end

    return targets
end

-- Get panel at index for current spec
function sfui.common.get_cooldown_panel(index)
    local panels = sfui.common.get_cooldown_panels()
    return panels[index]
end

-- Backwards compatibility wrapper - now returns per-spec panels
function sfui.common.ensure_tracked_icon_db()
    return sfui.common.get_cooldown_panels()
end

local powerTypeToName = {}
for name, value in pairs(Enum.PowerType) do
    powerTypeToName[value] = name
end

local primaryResourcesCache = {
    DEATHKNIGHT = Enum.PowerType.RunicPower,
    DEMONHUNTER = Enum.PowerType.Fury,
    DRUID = { [0] = Enum.PowerType.Mana, [1] = Enum.PowerType.Energy, [5] = Enum.PowerType.Rage, [27] = Enum.PowerType.Mana, [31] = Enum.PowerType.LunarPower, [35] = Enum.PowerType.LunarPower },
    EVOKER = Enum.PowerType.Mana,
    HUNTER = Enum.PowerType.Focus,
    MAGE = Enum.PowerType.Mana,
    MONK = { [268] = Enum.PowerType.Energy, [269] = Enum.PowerType.Energy, [270] = Enum.PowerType.Mana },
    PALADIN = Enum.PowerType.Mana,
    PRIEST = { [256] = Enum.PowerType.Mana, [257] = Enum.PowerType.Mana, [258] = Enum.PowerType.Insanity },
    ROGUE = Enum.PowerType.Energy,
    SHAMAN = { [262] = Enum.PowerType.Maelstrom, [263] = Enum.PowerType.Mana, [264] = Enum.PowerType.Mana },
    WARLOCK = Enum.PowerType.Mana,
    WARRIOR = Enum.PowerType.Rage
}

local secondaryResourcesCache = {
    DEATHKNIGHT = Enum.PowerType.Runes,
    DEMONHUNTER = nil,
    DRUID = { [1] = Enum.PowerType.ComboPoints },
    EVOKER = Enum.PowerType.Essence,
    HUNTER = nil,
    MAGE = { [62] = Enum.PowerType.ArcaneCharges },
    MONK = { [268] = "STAGGER", [269] = Enum.PowerType.Chi, [270] = nil },
    PALADIN = Enum.PowerType.HolyPower,
    PRIEST = { [258] = Enum.PowerType.Mana },
    ROGUE = Enum.PowerType.ComboPoints,
    SHAMAN = { [262] = Enum.PowerType.Mana },
    WARLOCK = Enum.PowerType.SoulShards,
    WARRIOR = nil
}

local resourceColorsCache = {
    ["STAGGER"] = { r = 1, g = 0.5, b = 0 },
    ["SOUL_SHARDS"] = { r = 0.58, g = 0.51, b = 0.79 },
    ["RUNES"] = { r = 0.77, g = 0.12, b = 0.23 },
    ["ESSENCE"] = { r = 0.20, g = 0.58, b = 0.50 },
    ["COMBO_POINTS"] = { r = 1.00, g = 0.96, b = 0.41 },
    ["CHI"] = { r = 0.00, g = 1.00, b = 0.59 },
    ["HOLY_POWER"] = { r = 0.96, g = 0.91, b = 0.55 },
    ["ARCANE_CHARGES"] = { r = 0.6, g = 0.8, b = 1.0 },
}

local cachedSpecID = 0
-- sfui.events is defined in dispatcher.lua (loaded before common.lua)

local function update_cached_spec_id()
    local spec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization and C_SpecializationInfo.GetSpecialization()) or (GetSpecialization and GetSpecialization())
    if spec then
        local specID = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo and select(1, C_SpecializationInfo.GetSpecializationInfo(spec))) or (GetSpecializationInfo and select(1, GetSpecializationInfo(spec)))
        if specID and specID > 0 and specID ~= cachedSpecID then
            cachedSpecID = specID
            sfui.common.invalidate_spec_color_cache()
        end
    end
end

sfui.events.RegisterEvent("PLAYER_LOGIN", function()
    update_cached_spec_id()
    sfui.common.invalidate_panels_cache()
end)

sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
    update_cached_spec_id()
    sfui.common.invalidate_panels_cache()
    if SfuiDB then SfuiDB._populationRetryDone = nil end
end)

-- 12.0.5+: fires when the system forces a spec change (arena PvP loadout lock,
-- talent reset, etc.) — distinct from PLAYER_SPECIALIZATION_CHANGED which only
-- fires for player-initiated changes.
sfui.events.RegisterEvent("SPEC_INVOLUNTARILY_CHANGED", function()
    update_cached_spec_id()
    sfui.common.invalidate_panels_cache()
end)

sfui.events.RegisterEvent("PLAYER_TALENT_UPDATE", function()
    update_cached_spec_id()
    sfui.common.invalidate_panels_cache()
end)

function sfui.common.get_current_spec_id()
    if cachedSpecID == 0 then update_cached_spec_id() end
    return cachedSpecID
end

-- ────────────────────────────────────────────────────────────────────────────
-- Central Out-of-Combat Action Queue
-- ────────────────────────────────────────────────────────────────────────────
local _oocQueue = {}
local _oocProcessing = false

--- Enqueue a callback to be executed when the player is out of combat lockdown.
--- If not currently in combat lockdown, the callback executes immediately.
--- Callbacks are executed inside pcall to prevent errors from breaking the queue.
--- @param callback function
function sfui.common.run_after_combat(callback)
    if type(callback) ~= "function" then return end
    if not InCombatLockdown() then
        local ok, err = pcall(callback)
        if not ok then
            print("|cff6600ffsfui|r run_after_combat error: " .. tostring(err))
        end
    else
        _oocQueue[#_oocQueue + 1] = callback
    end
end

local function flush_ooc_queue()
    if _oocProcessing or #_oocQueue == 0 then return end
    _oocProcessing = true
    local count = #_oocQueue
    for i = 1, count do
        local fn = _oocQueue[i]
        _oocQueue[i] = nil
        if fn then
            local ok, err = pcall(fn)
            if not ok then
                print("|cff6600ffsfui|r ooc callback error: " .. tostring(err))
            end
        end
    end
    -- Compact any items enqueued during callback execution
    local remaining = #_oocQueue
    if remaining > 0 then
        local writeIdx = 1
        for i = count + 1, remaining do
            _oocQueue[writeIdx] = _oocQueue[i]
            _oocQueue[i] = nil
            writeIdx = writeIdx + 1
        end
    end
    _oocProcessing = false
end

sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED", flush_ooc_queue)

-- ------------------------------------------------------------
-- Central Vehicle and Dragonflying / Skyriding State Cache
-- ------------------------------------------------------------
local _dragonflyingCache = nil
local _getBonusIdx = C_ActionBar and C_ActionBar.GetBonusBarIndex or GetBonusBarIndex
local _getBonusOff = C_ActionBar and C_ActionBar.GetBonusBarOffset or GetBonusBarOffset

function sfui.common.invalidate_dragonflying_cache()
    _dragonflyingCache = nil
end

function sfui.common.is_dragonflying()
    if _dragonflyingCache ~= nil then return _dragonflyingCache end
    local ok, isFlying, canGlide = pcall(C_PlayerInfo.GetGlidingInfo)
    if not ok then
        _dragonflyingCache = false
        return false
    end
    local hasSkyridingBar = _getBonusIdx and _getBonusOff and
        (_getBonusIdx() == 11 and _getBonusOff() == 5) or false
    _dragonflyingCache = (isFlying or (canGlide and hasSkyridingBar)) and true or false
    return _dragonflyingCache
end

function sfui.common.is_in_vehicle()
    if sfui.common.is_dragonflying() then return false end
    if UnitInVehicle("player") or UnitHasVehicleUI("player") then return true end
    if UnitExists("vehicle") and UnitVehicleSkin and UnitVehicleSkin("player") ~= nil then return true end
    if C_ActionBar and C_ActionBar.HasVehicleActionBar and C_ActionBar.HasVehicleActionBar() then return true end
    return false
end

local function on_glide_or_vehicle_event()
    sfui.common.invalidate_dragonflying_cache()
end

sfui.events.RegisterEvent("PLAYER_CAN_GLIDE_CHANGED",     on_glide_or_vehicle_event)
sfui.events.RegisterEvent("PLAYER_IS_GLIDING_CHANGED",    on_glide_or_vehicle_event)
sfui.events.RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED", on_glide_or_vehicle_event)
sfui.events.RegisterEvent("UPDATE_SHAPESHIFT_FORM",       on_glide_or_vehicle_event)
sfui.events.RegisterEvent("UNIT_ENTERED_VEHICLE",         on_glide_or_vehicle_event)
sfui.events.RegisterEvent("UNIT_EXITED_VEHICLE",          on_glide_or_vehicle_event)
sfui.events.RegisterEvent("VEHICLE_UPDATE",               on_glide_or_vehicle_event)
sfui.events.RegisterEvent("UPDATE_VEHICLE_ACTIONBAR",     on_glide_or_vehicle_event)
sfui.events.RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR",    on_glide_or_vehicle_event)
sfui.events.RegisterEvent("UPDATE_POSSESS_BAR",           on_glide_or_vehicle_event)
sfui.events.RegisterEvent("UPDATE_BONUS_ACTIONBAR",       on_glide_or_vehicle_event)
sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD",        on_glide_or_vehicle_event)


function sfui.common.update_widget_bar(widget_frame, icons_pool, labels_pool, source_data, get_details_func)
    if not widget_frame then return end
    local cfg = sfui.config.widget_bar
    local last_icon = nil
    local i = 1
    for _, itemID in ipairs(source_data) do
        local details = get_details_func(itemID)
        if details then
            local icon = icons_pool[i]
            if not icon then
                icon = CreateFrame("Button", nil, widget_frame)
                icon:SetSize(cfg.icon_size, cfg.icon_size)
                local texture = icon:CreateTexture(nil, "ARTWORK")
                texture:SetAllPoints(icon)
                icon.texture = texture
                icon:SetScript("OnEnter", details.on_enter)
                icon:SetScript("OnLeave", details.on_leave)
                icon:SetScript("OnMouseUp", details.on_mouseup)
                icons_pool[i] = icon
            end
            local label = labels_pool[i]
            if not label then
                label = widget_frame:CreateFontString(nil, "OVERLAY", sfui.config.font_small)
                label:SetPoint("TOP", icon, "BOTTOM", 0, cfg.label_offset_y)
                label:SetTextColor(cfg.label_color[1], cfg.label_color[2], cfg.label_color[3])
                labels_pool[i] = label
            end
            icon.id = itemID
            icon.texture:SetTexture(details.texture or sfui.config.textures.gold_icon)
            label:SetText(details.quantity)
            if i == 1 then
                icon:SetPoint("TOPLEFT", cfg.spacing or 5, -(cfg.spacing or 5))
            elseif last_icon then
                icon:SetPoint("TOPLEFT", last_icon, "TOPRIGHT", cfg.icon_spacing, 0)
            end
            icon:Show()
            label:Show()
            last_icon = icon
            i = i + 1
        end
    end
    for j = i, #icons_pool do icons_pool[j]:Hide() end
    for j = i, #labels_pool do labels_pool[j]:Hide() end
    if last_icon and not InCombatLockdown() then
        local left = widget_frame:GetLeft()
        if left then
            widget_frame:SetWidth(last_icon:GetRight() - left + (cfg.spacing or 5))
        end
        if CharacterFrame:IsShown() then widget_frame:Show() end
    else
        widget_frame:Hide()
    end
end

function sfui.common.get_primary_resource()
    if playerClass == "DRUID" then return primaryResourcesCache[playerClass][GetShapeshiftFormID() or 0] end
    local cache = primaryResourcesCache[playerClass]
    if type(cache) == "table" then return cache[cachedSpecID] else return cache end
end

function sfui.common.get_secondary_resource()
    local res
    if playerClass == "DRUID" then
        res = secondaryResourcesCache[playerClass][GetShapeshiftFormID() or 0]
    else
        local cache = secondaryResourcesCache[playerClass]
        if type(cache) == "table" then
            res = cache[cachedSpecID]
        else
            res = cache
        end
    end

    if sfui.bars then
        sfui.bars.bar1_in_use = (res ~= nil)
    end
    return res
end

-- Reuse table to avoid per-call allocations in bar update loops.
-- Rebuilt lazily when spec/class changes via invalidate_spec_color_cache().
local _specColorCache = { 1, 1, 1, 1 }
local _specColorDirty = true

function sfui.common.invalidate_spec_color_cache()
    _specColorDirty = true
end

function sfui.common.get_class_or_spec_color()
    -- Global Override: if spec colors are disabled, use the fallback color
    if SfuiDB and SfuiDB.useSpecColor == false then
        return SfuiDB.specColorFallback or { 1, 1, 1, 1 }
    end

    if not _specColorDirty then
        return _specColorCache
    end

    -- Rebuild the cached table in-place (no new allocation)
    _specColorCache[1], _specColorCache[2], _specColorCache[3], _specColorCache[4] = 1, 1, 1, 1
    if cachedSpecID and sfui.config.spec_colors[cachedSpecID] then
        local c = sfui.config.spec_colors[cachedSpecID]
        _specColorCache[1], _specColorCache[2], _specColorCache[3], _specColorCache[4] = c[1], c[2], c[3], 1
    elseif playerClass then
        local classColor = C_ClassColor and C_ClassColor.GetClassColor(playerClass) or
            (RAID_CLASS_COLORS and RAID_CLASS_COLORS[playerClass])
        if classColor then
            _specColorCache[1], _specColorCache[2], _specColorCache[3], _specColorCache[4] =
                classColor.r, classColor.g, classColor.b, 1
        end
    end

    _specColorDirty = false
    return _specColorCache
end

function sfui.common.unpack_color(color, defaultR, defaultG, defaultB, defaultA)
    if not color then return defaultR or 1, defaultG or 1, defaultB or 1, defaultA or 1 end
    local r = color[1] or color.r or defaultR or 1
    local g = color[2] or color.g or defaultG or 1
    local b = color[3] or color.b or defaultB or 1
    local a = color[4] or color.a or defaultA or 1
    return r, g, b, a
end

function sfui.common.create_bar(name, frameType, parent, template, configName)
    local cfg = sfui.config[configName or name]
    local mult = sfui.pixelScale or 1
    local backdrop = CreateFrame("Frame", "sfui_" .. name .. "_Backdrop", parent, "BackdropTemplate")
    backdrop:SetFrameStrata("MEDIUM")
    local padding = cfg.backdrop.padding * mult
    backdrop:SetSize(cfg.width + padding * 2, cfg.height + padding * 2)

    backdrop:SetBackdrop({
        bgFile = sfui.config.textures.white,
        tile = true,
        tileSize = 32,
    })
    backdrop:SetBackdropColor(cfg.backdrop.color[1], cfg.backdrop.color[2], cfg.backdrop.color[3], cfg.backdrop.color[4])
    local bar = CreateFrame(frameType, "sfui_" .. name, backdrop, template)
    bar:SetSize(cfg.width, cfg.height)
    bar:SetPoint("CENTER")
    if bar.SetStatusBarTexture then
        local textureName = SfuiDB.barTexture
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local texturePath
        if LSM then
            texturePath = LSM:Fetch("statusbar", textureName)
        end

        if not texturePath or texturePath == "" then
            texturePath = sfui.config.barTexture
        end
        bar:SetStatusBarTexture(texturePath)
    end
    bar.backdrop = backdrop
    bar.fadeInAnim, bar.fadeOutAnim = sfui.common.create_fade_animations(backdrop)
    return bar
end

function sfui.common.create_fade_animations(frame)
    local fadeInGroup = frame:CreateAnimationGroup()
    local fadeIn = fadeInGroup:CreateAnimation("Alpha")
    fadeIn:SetDuration(0.5)
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetScript("OnPlay", function() frame:Show() end)
    local fadeOutGroup = frame:CreateAnimationGroup()
    local fadeOut = fadeOutGroup:CreateAnimation("Alpha")
    fadeOut:SetDuration(0.5)
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetScript("OnFinished", function() frame:Hide() end)
    return fadeInGroup, fadeOutGroup
end

function sfui.common.get_resource_color(resource)
    local colorInfo = GetPowerBarColor(resource)
    if colorInfo then return colorInfo end
    local powerName = ""
    if type(resource) == "number" then
        powerName = powerTypeToName[resource]
    end
    return resourceColorsCache[powerName] or GetPowerBarColor("MANA")
end

function sfui.common.create_border(frame, thickness, color)
    local mult = sfui.pixelScale or 1
    thickness = (thickness or 1) * mult

    if not frame.borders then
        frame.borders = {}
        for i = 1, 4 do
            frame.borders[i] = frame:CreateTexture(nil, "BACKGROUND")
            frame.borders[i]:SetTexture("Interface\\Buttons\\WHITE8x8")
        end
    end

    local top, bottom, left, right = unpack(frame.borders)
    local r, g, b, a = 0, 0, 0, 1
    if color then r, g, b, a = unpack(color) end

    for _, border in ipairs(frame.borders) do
        border:SetVertexColor(r, g, b, a)
    end

    top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0); top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0); top:SetHeight(
        thickness)
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0); bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0); bottom
        :SetHeight(thickness)
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0); left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0); left
        :SetWidth(thickness)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0); right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0); right
        :SetWidth(thickness)
end

function sfui.common.apply_square_icon_style(frame, texture)
    if not frame or not texture then return end

    -- Crop WoW's default rounded edges to make it a perfect square
    texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Inset the texture slightly off the frame edges
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    texture:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)

    -- Create a solid black backdrop to serve as the border behind the inset texture
    if not frame.borderBackdrop then
        frame.borderBackdrop = _G.CreateFrame("Frame", nil, frame, "BackdropTemplate")
        frame.borderBackdrop:SetAllPoints(frame)
        -- Ensure it renders strictly behind the texture
        frame.borderBackdrop:SetFrameLevel(math.max(1, frame:GetFrameLevel() - 1))

        frame.borderBackdrop:SetBackdrop({
            bgFile = sfui.config.textures.white,
            edgeFile = "",
            tile = false,
            tileSize = 0,
            edgeSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        frame.borderBackdrop:SetBackdropColor(0, 0, 0, 1)
    end
    frame.borderBackdrop:Show()
end

function sfui.common.create_flat_button(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width, height)

    local mult = sfui.pixelScale or 1
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = mult,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    btn:SetBackdropColor(0, 0, 0, 1)
    local gray = sfui.config.colors.gray
    btn:SetBackdropBorderColor(gray[1], gray[2], gray[3], 1)

    btn:SetNormalFontObject("GameFontHighlightSmall")
    btn:SetText(text)
    local fs = btn:GetFontString()
    local white = sfui.config.colors.white
    if fs then fs:SetTextColor(white[1], white[2], white[3], 1) end

    local cyan = sfui.config.colors.cyan
    btn:SetScript("OnEnter", function(self)
        if self:GetFontString() then
            self:GetFontString():SetTextColor(cyan[1], cyan[2], cyan[3], 1)
        end
        self:SetBackdropBorderColor(cyan[1], cyan[2], cyan[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        if self:GetFontString() then
            self:GetFontString():SetTextColor(white[1], white[2], white[3], 1)
        end
        self:SetBackdropBorderColor(gray[1], gray[2], gray[3], 1)
    end)

    return btn
end

function sfui.common.create_checkbox(parent, label, dbKeyOrGetter, onClickFunc, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    cb:SetSize(20, 20)

    -- Custom Backdrop
    cb:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    local app = sfui.config.appearance
    cb:SetBackdropColor(app.widgetBackdropColor[1], app.widgetBackdropColor[2], app.widgetBackdropColor[3],
        app.widgetBackdropColor[4])
    cb:SetBackdropBorderColor(0, 0, 0, 1)

    -- Checked Texture (Highlight Purple/Custom)
    cb:SetCheckedTexture("Interface/Buttons/WHITE8X8")
    cb:GetCheckedTexture():SetVertexColor(app.highlightColor[1], app.highlightColor[2], app.highlightColor[3], 1)
    cb:GetCheckedTexture():SetPoint("TOPLEFT", 2, -2)
    cb:GetCheckedTexture():SetPoint("BOTTOMRIGHT", -2, 2)

    -- Highlight
    cb:SetHighlightTexture("Interface/Buttons/WHITE8X8")
    cb:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.1)

    -- Text
    cb.text = cb:CreateFontString(nil, "OVERLAY", sfui.config.font)
    cb.text:SetPoint("LEFT", cb, "RIGHT", 5, 0)
    cb.text:SetText(label)
    cb.label = cb.text -- Alias for consistency

    local function updateChecked()
        if type(dbKeyOrGetter) == "string" then
            if SfuiDB[dbKeyOrGetter] ~= nil then cb:SetChecked(SfuiDB[dbKeyOrGetter]) end
        elseif type(dbKeyOrGetter) == "function" then
            cb:SetChecked(dbKeyOrGetter())
        end
    end

    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        if type(dbKeyOrGetter) == "string" then SfuiDB[dbKeyOrGetter] = checked end
        if onClickFunc then onClickFunc(checked) end
    end)
    cb:SetScript("OnShow", updateChecked)
    updateChecked() -- Initialize state immediately

    if tooltip then
        cb:SetScript("OnEnter", function(self)
            local tip = sfui.tooltip or _G.GameTooltip
            if tip then
                pcall(function()
                    tip:SetOwner(self, "ANCHOR_RIGHT")
                    tip:SetText(tooltip)
                    tip:Show()
                end)
            end
        end)
        cb:SetScript("OnLeave", function(self)
            local tip = sfui.tooltip or _G.GameTooltip
            if tip then tip:Hide() end
        end)
    end
    return cb
end

function sfui.common.style_text(fs, fontObj, size, flags)
    if not fs then return end
    if fontObj then fs:SetFontObject(fontObj) end
    if size or flags then
        local font, curSize, curFlags = fs:GetFont()
        fs:SetFont(font, size or curSize, flags or "")
    end
    -- Standard Shadow
    fs:SetShadowOffset(0, 0)
    fs:SetTextColor(1, 1, 1, 1)
end

function sfui.common.create_color_swatch(parent, initialColor, onSetFunc)
    local swatch = CreateFrame("Button", nil, parent, "BackdropTemplate")
    swatch:SetSize(16, 16)

    swatch:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    swatch:SetBackdropBorderColor(0, 0, 0, 1)

    local function SetColor(r, g, b)
        swatch:SetBackdropColor(r, g, b, 1)
        if onSetFunc then onSetFunc(r, g, b) end
    end

    local app = sfui.config.appearance
    if initialColor then
        local r = initialColor.r or initialColor[1] or app.highlightColor[1]
        local g = initialColor.g or initialColor[2] or app.highlightColor[2]
        local b = initialColor.b or initialColor[3] or app.highlightColor[3]
        swatch:SetBackdropColor(r, g, b, 1)
    else
        swatch:SetBackdropColor(app.highlightColor[1], app.highlightColor[2], app.highlightColor[3], 1)
    end

    swatch:SetScript("OnClick", function()
        local r, g, b = swatch:GetBackdropColor()

        if ColorPickerFrame.SetupColorPickerAndShow then
            local info = {
                r = r,
                g = g,
                b = b,
                hasOpacity = false,
                swatchFunc = function()
                    local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                    SetColor(nr, ng, nb)
                end,
                cancelFunc = function() SetColor(r, g, b) end,
            }
            ColorPickerFrame:SetupColorPickerAndShow(info)
        else
            ColorPickerFrame:SetColorRGB(r, g, b)
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.func = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                SetColor(nr, ng, nb)
            end
            ColorPickerFrame.cancelFunc = function() SetColor(r, g, b) end
            ColorPickerFrame:Hide()
            ColorPickerFrame:Show()
        end
    end)
    return swatch
end

function sfui.common.create_cvar_checkbox(parent, label, cvar, tooltip)
    return sfui.common.create_checkbox(parent, label, function()
        if SfuiDB[cvar] ~= nil then
            return SfuiDB[cvar]
        else
            return C_CVar.GetCVarBool(cvar)
        end
    end, function(checked)
        C_CVar.SetCVar(cvar, checked and "1" or "0")
        SfuiDB[cvar] = checked
    end, tooltip)
end

function sfui.common.create_slider_input(parent, label, dbKeyOrGetter, minVal, maxVal, step, onValueChangedFunc, tooltip,
                                         width)
    local container = CreateFrame("Frame", nil, parent)

    -- Detect if 'tooltip' was actually 'width' (legacy support check)
    local w = 160
    if type(width) == "number" then
        w = width
    elseif type(tooltip) == "number" then
        w = tooltip
        tooltip = nil
    end

    container:SetSize(w, 40) -- Compact height

    if tooltip then
        container:SetScript("OnEnter", function(self)
            local tip = sfui.tooltip or _G.GameTooltip
            if tip then
                pcall(function()
                    tip:SetOwner(self, "ANCHOR_RIGHT")
                    tip:SetText(tooltip)
                    tip:Show()
                end)
            end
        end)
        container:SetScript("OnLeave", function(self)
            local tip = sfui.tooltip or _G.GameTooltip
            if tip then tip:Hide() end
        end)
    end

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(label)
    title:SetTextColor(1, 1, 1, 0.8)

    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    slider:SetSize(w - 60, 10) -- Dynamic width
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local app = sfui.config.appearance
    slider:SetBackdropColor(app.sliderBackdropColor[1], app.sliderBackdropColor[2], app.sliderBackdropColor[3],
        app.sliderBackdropColor[4])
    slider:SetBackdropBorderColor(0, 0, 0, 1)

    -- Thumb
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(6, 10)
    thumb:SetColorTexture(app.highlightColor[1], app.highlightColor[2], app.highlightColor[3], 1)
    slider:SetThumbTexture(thumb)

    -- EditBox (Square, Flat, RIGHT of Slider)
    local editbox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    editbox:SetSize(45, 16)
    editbox:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    editbox:SetAutoFocus(false)
    editbox:SetFontObject("GameFontHighlightSmall")
    editbox:SetJustifyH("CENTER")

    editbox:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    editbox:SetBackdropColor(app.editBoxColor[1], app.editBoxColor[2], app.editBoxColor[3], app.editBoxColor[4])
    editbox:SetBackdropBorderColor(0, 0, 0, 1)

    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            if val < minVal then val = minVal end
            if val > maxVal then val = maxVal end
            slider:SetValue(val)
            if type(dbKeyOrGetter) == "string" then SfuiDB[dbKeyOrGetter] = val end
            if onValueChangedFunc then onValueChangedFunc(val) end
        end
        self:ClearFocus()
    end)
    editbox:SetScript("OnEditFocusGained",
        function(self) self:SetBackdropBorderColor(app.highlightColor[1], app.highlightColor[2], app.highlightColor[3], 1) end)
    editbox:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(0, 0, 0, 1) end)


    local lastUpdate = 0
    local throttle = 0.05 -- 50ms throttle

    slider:SetScript("OnValueChanged", function(self, value)
        local stepped = math.floor((value - minVal) / step + 0.5) * step + minVal
        if type(dbKeyOrGetter) == "string" then SfuiDB[dbKeyOrGetter] = stepped end
        -- Clean number display
        local displayVal = math.floor(stepped * 100) / 100
        editbox:SetText(tostring(displayVal))

        local now = GetTime()
        if now - lastUpdate > throttle then
            lastUpdate = now
            if onValueChangedFunc then onValueChangedFunc(stepped) end
        end
    end)

    -- Ensure final value is sent on mouse up and persisted
    slider:SetScript("OnMouseUp", function(self)
        local value = self:GetValue()
        local stepped = math.floor((value - minVal) / step + 0.5) * step + minVal
        if type(dbKeyOrGetter) == "string" then SfuiDB[dbKeyOrGetter] = stepped end
        if onValueChangedFunc then onValueChangedFunc(stepped) end
        lastUpdate = GetTime() -- Prevent immediate double-fire from Drag logic
    end)

    -- Expose components for pooling
    container.slider = slider
    container.editbox = editbox
    container.label = title

    slider:SetScript("OnShow", function(self)
        local val
        if type(dbKeyOrGetter) == "string" then
            val = SfuiDB[dbKeyOrGetter]
        elseif type(dbKeyOrGetter) == "function" then
            val = dbKeyOrGetter()
        end
        if val == nil then val = minVal end
        self:SetValue(val)
        editbox:SetText(math.floor(val * 100) / 100)
    end)

    -- Expose method to set value programmatically
    function container:SetSliderValue(val)
        slider:SetValue(val)
        editbox:SetText(tostring(val))
    end

    return container
end

function sfui.common.create_input_field(parent, label, dbKeyOrGetter, width, onValueChangedFunc, tooltip)
    local container = CreateFrame("Frame", nil, parent)
    local w = width or 100
    container:SetSize(w, 40)

    if tooltip then
        container:SetScript("OnEnter", function(self)
            local tip = sfui.tooltip or _G.GameTooltip
            if tip then
                pcall(function()
                    tip:SetOwner(self, "ANCHOR_RIGHT")
                    tip:SetText(tooltip)
                    tip:Show()
                end)
            end
        end)
        container:SetScript("OnLeave", function(self)
            local tip = sfui.tooltip or _G.GameTooltip
            if tip then tip:Hide() end
        end)
    end

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(label)
    title:SetTextColor(1, 1, 1, 0.8)

    local editbox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    editbox:SetSize(w - 10, 20)
    editbox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    editbox:SetAutoFocus(false)
    editbox:SetFontObject("GameFontHighlightSmall")
    editbox:SetJustifyH("LEFT")
    editbox:SetTextInsets(5, 0, 0, 0)

    local app = sfui.config.appearance
    editbox:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    editbox:SetBackdropColor(app.editBoxColor[1], app.editBoxColor[2], app.editBoxColor[3], app.editBoxColor[4])
    editbox:SetBackdropBorderColor(0, 0, 0, 1)

    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            if type(dbKeyOrGetter) == "string" then
                -- Support nested keys like "healthBarX"
                local keys = {}
                for key in string.gmatch(dbKeyOrGetter, "([^.]+)") do
                    table.insert(keys, key)
                end

                local current = SfuiDB
                for i = 1, #keys - 1 do
                    if not current[keys[i]] then current[keys[i]] = {} end
                    current = current[keys[i]]
                end
                current[keys[#keys]] = val
            end
            if onValueChangedFunc then onValueChangedFunc(val) end
        end
        self:ClearFocus()
    end)
    editbox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(app.highlightColor[1], app.highlightColor[2], app.highlightColor[3], 1)
    end)
    editbox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(0, 0, 0, 1)
        -- Reset value to DB on focus lost and invalid input
        local val = tonumber(self:GetText())
        if not val then
            if type(dbKeyOrGetter) == "string" then
                local keys = {}
                for key in string.gmatch(dbKeyOrGetter, "([^.]+)") do
                    table.insert(keys, key)
                end
                local current = SfuiDB
                for i = 1, #keys do
                    if current then current = current[keys[i]] end
                end
                self:SetText(tostring(current or 0))
            elseif type(dbKeyOrGetter) == "function" then
                self:SetText(tostring(dbKeyOrGetter() or 0))
            end
        end
    end)

    editbox:SetScript("OnShow", function(self)
        local val
        if type(dbKeyOrGetter) == "string" then
            val = SfuiDB[dbKeyOrGetter]
        elseif type(dbKeyOrGetter) == "function" then
            val = dbKeyOrGetter()
        end
        self:SetText(tostring(val or 0))
    end)

    container.editbox = editbox
    container.label = title
    return container
end

function sfui.common.set_color(element, colorName, alpha)
    local color = sfui.config.colors[colorName]
    if not color then return end
    alpha = alpha or 1

    if element.SetTextColor then
        element:SetTextColor(color[1], color[2], color[3], alpha)
    elseif element.SetBackdropBorderColor then
        element:SetBackdropBorderColor(color[1], color[2], color[3], alpha)
    elseif element.SetBackdropColor then
        element:SetBackdropColor(color[1], color[2], color[3], alpha)
    end
end

function sfui.common.create_font_string(parent, font, point, x, y, colorName)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    if point then
        fs:SetPoint(point, x or 0, y or 0)
    end
    if colorName then
        sfui.common.set_color(fs, colorName)
    end
    return fs
end

function sfui.common.is_item_known(itemLink)
    if not itemLink then return false end

    local data = C_TooltipInfo.GetHyperlink(itemLink)
    if data and data.lines then
        for _, line in ipairs(data.lines) do
            local text = line.leftText
            if text then
                if text == ITEM_SPELL_KNOWN or text == "Already known" then
                    return true
                end
                if string.find(text, "You've collected this appearance") then
                    return true
                end
            end
        end
    end

    local itemID = tonumber(string.match(itemLink, "item:(%d+)"))
    if itemID then
        local appearanceID, sourceID = C_TransmogCollection.GetItemInfo(itemID)
        if sourceID then
            local categoryID, visualID, canEnchant, icon, isCollected = C_TransmogCollection.GetAppearanceSourceInfo(
                sourceID)
            if isCollected then
                return true
            end
        end

        if C_ToyBox and C_ToyBox.GetToyInfo then
            local toyID = C_ToyBox.GetToyInfo(itemID)
            if toyID and PlayerHasToy(itemID) then return true end
        end
    end

    return false
end

function sfui.common.shorten_name(name, length)
    if not name or type(name) ~= "string" then return "" end
    length = length or 25
    if string.len(name) <= length then return name end
    return string.sub(name, 1, length - 3) .. "..."
end

-- Shared Masque group for all sfui buttons
function sfui.common.get_masque_group()
    -- Check global setting
    local enabled = sfui.config.icon_panel_global_defaults.enableMasque
    if SfuiDB and SfuiDB.iconGlobalSettings and SfuiDB.iconGlobalSettings.enableMasque ~= nil then
        enabled = SfuiDB.iconGlobalSettings.enableMasque
    end

    if not enabled then
        return nil
    end

    local Masque = LibStub and LibStub("Masque", true)
    if not Masque then return nil end
    local group = Masque:Group("sfui")
    if group and not group._sfui_init then
        -- Set "Dream" as the preferred default skin with safety checks
        if group.Skin then
            group:Skin("Dream")
        elseif group.SetSkin then
            group:SetSkin("Dream")
        end
        group._sfui_init = true
    end
    return group
end

-- Centralized Helper to Sync Frame with Masque State
function sfui.common.sync_masque(frame, subElements)
    if not frame then return end
    local Masque = LibStub and LibStub("Masque", true)
    if not Masque then return end
    local group = Masque:Group("sfui")
    if not group then return end

    local enabled = sfui.config.icon_panel_global_defaults.enableMasque
    if SfuiDB and SfuiDB.iconGlobalSettings and SfuiDB.iconGlobalSettings.enableMasque ~= nil then
        enabled = SfuiDB.iconGlobalSettings.enableMasque
    end

    if enabled then
        if not frame._isMasqued then
            group:AddButton(frame, subElements)
            frame._isMasqued = true
        end
    else
        if frame._isMasqued then
            group:RemoveButton(frame)
            frame._isMasqued = false
        end
    end
end

-- ========================
-- Item Utilities
-- ========================

-- Checks if an item link corresponds to a housing decor item
function sfui.common.is_housing_decor(link)
    local itemID = sfui.common.get_item_id_from_link(link)
    if itemID and C_HousingCatalog and C_HousingCatalog.GetCatalogEntryInfoByItem then
        local info = C_HousingCatalog.GetCatalogEntryInfoByItem(itemID, false)
        return info and info.entryID and info.entryID.entryType == 1
    end
    return false
end

-- Extracts the item ID from an item link
-- @param link: Item link string (e.g., "|cff0070dd|Hitem:12345:0:0:0|h[Item Name]|h|r")
-- @return: Item ID as a number, or nil if not found
function sfui.common.get_item_id_from_link(link)
    if not link then return nil end
    return tonumber(link:match("item:(%d+)"))
end

-- ========================
-- Utility Helpers
-- ========================



-- @param parent: Parent frame
-- @param text: Button text
-- @param width: Button width
-- @param height: Button height
-- @return: Button frame
function sfui.common.create_styled_button(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 120, height or 25)
    btn:SetBackdrop({
        bgFile = sfui.config.textures.white,
        edgeFile = sfui.config.textures.white,
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    btn:SetBackdropColor(0.2, 0.2, 0.2, 1)
    btn:SetBackdropBorderColor(0, 0, 0, 1)

    -- Hover effect
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(sfui.config.colors.purple[1], sfui.config.colors.purple[2],
            sfui.config.colors.purple[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0, 0, 0, 1)
    end)

    -- Text
    btn.text = btn:CreateFontString(nil, "OVERLAY", sfui.config.font)
    btn.text:SetPoint("CENTER")
    btn.text:SetText(text or "")
    sfui.common.style_text(btn.text)

    return btn
end

-- Moved from config.lua to clean up that file
function sfui.initialize_database()
    if type(SfuiDB) ~= "table" then SfuiDB = {} end
    if type(SfuiDecorDB) ~= "table" then SfuiDecorDB = {} end
    SfuiDecorDB.items = SfuiDecorDB.items or {}
    SfuiDB.iconGlobalSettings = SfuiDB.iconGlobalSettings or {}
    local igs = SfuiDB.iconGlobalSettings
    local g = sfui.config.icon_panel_global_defaults
    if igs.enableMasque == nil then igs.enableMasque = g.enableMasque end
    if igs.readyGlow == nil then igs.readyGlow = g.readyGlow end
    if igs.glowType == nil then igs.glowType = g.glowType or "pixel" end

    if type(SfuiDB.barTexture) ~= "string" or SfuiDB.barTexture == "" then SfuiDB.barTexture = "Flat" end
    SfuiDB.absorbBarColor = SfuiDB.absorbBarColor or sfui.config.absorbBarColor

    SfuiDB.minimap_icon = SfuiDB.minimap_icon or { hide = false }
    SfuiDB.minimap_collect_buttons = (SfuiDB.minimap_collect_buttons == nil) and true or SfuiDB.minimap_collect_buttons
    if SfuiDB.minimap_rearrange == nil then SfuiDB.minimap_rearrange = true end
    SfuiDB.minimap_buttons_mouseover = (SfuiDB.minimap_buttons_mouseover == nil) and false or
        SfuiDB.minimap_buttons_mouseover
    if SfuiDB.minimap_masque == nil then SfuiDB.minimap_masque = true end
    if SfuiDB.minimap_auto_zoom == nil then SfuiDB.minimap_auto_zoom = true end
    if SfuiDB.minimap_auto_zoom_delay == nil then SfuiDB.minimap_auto_zoom_delay = 5 end
    if SfuiDB.minimap_button_x == nil then SfuiDB.minimap_button_x = sfui.config.minimap.button_bar.defaultX end
    if SfuiDB.minimap_button_y == nil then SfuiDB.minimap_button_y = sfui.config.minimap.button_bar.defaultY end
    if SfuiDB.autoSellGreys == nil then SfuiDB.autoSellGreys = true end
    if SfuiDB.autoRepair == nil then SfuiDB.autoRepair = true end
    if SfuiDB.repairThreshold == nil then SfuiDB.repairThreshold = 90 end
    if SfuiDB.enableMasterHammer == nil then SfuiDB.enableMasterHammer = true end
    if SfuiDB.enableMerchant == nil then SfuiDB.enableMerchant = true end
    if SfuiDB.enableDecor == nil then SfuiDB.enableDecor = false end -- Opt-in feature
    if SfuiDB.repairIconColor == nil then SfuiDB.repairIconColor = sfui.config.masterHammer.defaultColor end
    if SfuiDB.enableCursorRing == nil then SfuiDB.enableCursorRing = true end
    if SfuiDB.cursorRingScale == nil then SfuiDB.cursorRingScale = 1.0 end
    if SfuiDB.useSpecColor == nil then SfuiDB.useSpecColor = true end
    if SfuiDB.specColorFallback == nil then SfuiDB.specColorFallback = { 1, 1, 1, 1 } end

    -- Bar settings
    if SfuiDB.healthBarX == nil then SfuiDB.healthBarX = 0 end
    if SfuiDB.healthBarY == nil then SfuiDB.healthBarY = 300 end
    if SfuiDB.enableHealthBar == nil then SfuiDB.enableHealthBar = true end
    if SfuiDB.enablePowerBar == nil then SfuiDB.enablePowerBar = true end
    if SfuiDB.enableSecondaryPowerBar == nil then SfuiDB.enableSecondaryPowerBar = true end
    if SfuiDB.enableVigorBar == nil then SfuiDB.enableVigorBar = true end
    if SfuiDB.enableMountSpeedBar == nil then SfuiDB.enableMountSpeedBar = true end

    -- Castbar settings
    if SfuiDB.castBarEnabled == nil then SfuiDB.castBarEnabled = sfui.config.castBar.enabled end
    if SfuiDB.castBarX == nil then SfuiDB.castBarX = sfui.config.castBar.pos.x end
    if SfuiDB.castBarY == nil then SfuiDB.castBarY = sfui.config.castBar.pos.y end
    sfui.config.castBar.enabled = SfuiDB.castBarEnabled
    sfui.config.castBar.pos.x = SfuiDB.castBarX
    sfui.config.castBar.pos.y = SfuiDB.castBarY

    if SfuiDB.targetCastBarEnabled == nil then SfuiDB.targetCastBarEnabled = sfui.config.targetCastBar.enabled end
    if SfuiDB.targetCastBarX == nil then SfuiDB.targetCastBarX = sfui.config.targetCastBar.pos.x end
    if SfuiDB.targetCastBarY == nil then SfuiDB.targetCastBarY = sfui.config.targetCastBar.pos.y end
    sfui.config.targetCastBar.enabled = SfuiDB.targetCastBarEnabled
    sfui.config.targetCastBar.pos.x = SfuiDB.targetCastBarX
    sfui.config.targetCastBar.pos.y = SfuiDB.targetCastBarY

    -- automation settings
    if SfuiDB.auto_role_check == nil then SfuiDB.auto_role_check = true end
    if SfuiDB.auto_sign_lfg == nil then SfuiDB.auto_sign_lfg = true end

    -- Tracked Bars
    SfuiDB.trackedBars = SfuiDB.trackedBars or {}
    if SfuiDB.trackedBarsX == nil then SfuiDB.trackedBarsX = -300 end
    if SfuiDB.trackedBarsY == nil then SfuiDB.trackedBarsY = 300 end
end

-- Helper to systematically hide specific Blizzard CooldownViewer frames
function sfui.common.hide_blizzard_cooldown_viewers()
    -- Ensure the addon is loaded first
    if not C_AddOns.IsAddOnLoaded("Blizzard_CooldownViewer") then
        C_AddOns.LoadAddOn("Blizzard_CooldownViewer")
    end

    local viewers = {
        "EssentialCooldownViewer",
        "UtilityCooldownViewer",
    }

    for _, viewerName in ipairs(viewers) do
        local viewer = _G[viewerName]
        if viewer then
            viewer:SetAlpha(0)
            viewer:EnableMouse(false)
            viewer:Hide()
            viewer:UnregisterAllEvents()

            if not viewer._sfui_hooked then
                hooksecurefunc(viewer, "Show", function(self)
                    self:SetAlpha(0)
                    self:EnableMouse(false)
                    self:Hide()
                end)
                viewer._sfui_hooked = true
            end
        end
    end
    -- Ensure the CVar is set to 1 so Blizzard's internal data systems are active.
    -- We hide the frames visually, but we need the data provider to function.
    if GetCVar("cooldownViewerEnabled") == "0" then
        SetCVar("cooldownViewerEnabled", 1)
    end
end

-- Centralized Dropdown Menu Widget
local activeDropdown = nil
function sfui.common.create_dropdown(parent, width, options, onSelectFunc, initialValue, fixedText, menuWidth)
    local actualOptions = (type(options) == "function") and options() or options
    local initialText = fixedText or "Select..."
    if not fixedText then
        if initialValue ~= nil then
            for _, opt in ipairs(actualOptions) do
                if opt.value == initialValue then
                    initialText = opt.text
                    break
                end
            end
        elseif actualOptions and #actualOptions > 0 then
            -- Default to the first option if no initial value provided
            initialText = actualOptions[1].text
        end
    end

    local btn = sfui.common.create_flat_button(parent, initialText, width or 80, 18)

    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetFrameLevel(100)
    menu:Hide()

    local function updateMenuSize()
        local currentOptions = (type(options) == "function") and options() or options
        local maxW = menuWidth or width or 80

        -- If no menuWidth, try to estimate from text if not using onRender
        if not menuWidth then
            for _, opt in ipairs(currentOptions) do
                if opt.text then
                    local textWidth = #opt.text * 7 -- Rough estimate
                    if textWidth > maxW then maxW = textWidth end
                end
            end
        end

        local totalH = 5
        for _, opt in ipairs(currentOptions) do
            totalH = totalH + 20
        end
        menu:SetSize(maxW + 20, totalH + 5)
    end

    menu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(0, 0, 0, 0.9)
    menu:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)

    local function fillOptions()
        local currentOptions = (type(options) == "function") and options() or options
        local y = -5

        menu.buttons = menu.buttons or {}
        for _, optBtn in ipairs(menu.buttons) do
            optBtn:Hide()
        end

        for i, opt in ipairs(currentOptions) do
            local optBtn = menu.buttons[i]
            if not optBtn then
                optBtn = CreateFrame("Button", nil, menu)
                menu.buttons[i] = optBtn
                optBtn.textString = optBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                optBtn.textString:SetPoint("LEFT", 5, 0)
            end

            optBtn:SetSize(menu:GetWidth() - 10, 20)
            optBtn:SetPoint("TOPLEFT", 5, y)

            if opt.onRender then
                opt.onRender(optBtn, opt)
            else
                local t = optBtn.textString
                t:SetText(opt.text)

                optBtn:SetScript("OnEnter", function(self) t:SetTextColor(0, 1, 1) end)
                optBtn:SetScript("OnLeave", function(self) t:SetTextColor(1, 1, 1) end)

                optBtn:SetScript("OnClick", function()
                    if not fixedText then
                        btn:GetFontString():SetText(opt.text) -- Update displayed text
                    end
                    if onSelectFunc then onSelectFunc(opt.value) end

                    if not opt.keepOpen then
                        menu:Hide()
                        activeDropdown = nil
                    end
                end)
            end
            optBtn:Show()
            y = y - 20
        end
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
            activeDropdown = nil
        else
            if activeDropdown then activeDropdown:Hide() end
            updateMenuSize()
            fillOptions()
            menu:Show()
            activeDropdown = menu
        end
    end)

    return btn
end

function sfui.common.create_panel(parent, width, height)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetSize(width, height)
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
    panel:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    return panel
end

function sfui.common.create_label(parent, text, font, r, g, b)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    label:SetText(text)
    if r and g and b then
        label:SetTextColor(r, g, b)
    else
        label:SetTextColor(1, 1, 1)
    end
    label:SetShadowOffset(0, 0)
    return label
end

function sfui.common.get_short_string(name)
    if not name then return "" end

    local overrides = sfui.portals_db and sfui.portals_db.SHORT_STRINGS or {}

    if overrides[name] then return overrides[name] end

    local abbrev = ""
    for word in name:gmatch("%a+") do
        if word:upper() ~= "OF" and word:upper() ~= "THE" then
            local first = word:sub(1, 1)
            if first == first:upper() then
                abbrev = abbrev .. first
            end
        end
    end
    if abbrev:len() > 0 and abbrev:len() <= 4 then return abbrev end

    return name:sub(1, 4):upper()
end

function sfui.common.get_short_map_name(mapID)
    if not mapID then return nil end
    local name = C_ChallengeMode.GetMapUIInfo(mapID)
    if not name then return nil end
    return sfui.common.get_short_string(name)
end
