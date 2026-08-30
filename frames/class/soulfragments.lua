local _, ns = ...
-- Use the richer issecretvalue from common (includes C_Secrets.HasSecretRestrictions short-circuit)
local common = sfui.common
local issecretvalue = common.issecretvalue

-- Class Gate: Demon Hunter only
local _, playerClass = UnitClass("player")
if playerClass ~= "DEMONHUNTER" then return end

sfui.soulfragments = {}

-- ------------------------------------------------------------
-- Constants & Spec Configurations
-- ------------------------------------------------------------
local SPEC_HAVOC     = 577
local SPEC_VENGEANCE = 581
local SPEC_DEVOURER  = 1480

-- Aura root spell IDs for Demon Hunter Soul Fragments
local SF_ROOTS = {
    [203981]  = true,  -- Vengeance Soul Fragments
    [1245577] = true,  -- Devourer Soul Fragments
    [1245584] = true,  -- Devourer Shattered Souls
    [210788]  = true,  -- Lesser Soul Fragments (Havoc)
    [1227619] = true,  -- Shattered Souls (CDM entry)
    [20811]   = true,
}

-- Ordered list for direct aura reads
local SF_SPELLS = { 203981, 1245577, 1245584, 210788 }

-- Native action bar spells that mirror Soul Fragment display count
local ACTION_DISPLAY_SPELLS = {
    228477,  -- Soul Cleave (Vengeance)
    247454,  -- Spirit Bomb (Vengeance)
    1226019, -- Reap (Devourer)
}

local SPEC_CONFIGS = {
    [SPEC_VENGEANCE] = {
        cap = 6,
        primaryAura = 203981,
        color = { 0.4, 0.0, 1.0, 1.0 }, -- #6600ff Cosmic Purple
        reapThreshold = 4,
    },
    [SPEC_DEVOURER] = {
        cap = 10,
        primaryAura = 1245577,
        color = { 0.451, 0.353, 0.749, 1.0 }, -- Void Violet
        reapThreshold = 4,
    },
    [SPEC_HAVOC] = {
        cap = 5,
        primaryAura = 210788,
        color = { 0.000, 0.596, 0.424, 1.0 }, -- Fel Emerald
        reapThreshold = nil,
    },
}

-- ------------------------------------------------------------
-- Module State
-- ------------------------------------------------------------
local container        = nil
local bar              = nil
local countText        = nil
local dividers         = {}
local thresholdTick    = nil
local currentSpecConfig = nil
local cachedMaxCells   = 0

-- HOLD state: held indefinitely only while engine restrictions actively hide auras
local lastKnownStacks = 0

-- Init guard: prevents stacking RegisterUpdate/hooksecurefunc on every reload
local _initialized = false

-- ------------------------------------------------------------
-- Engine Auras Restriction & Template Detection
-- ------------------------------------------------------------
local function EngineAurasRestricted()
    return not not (C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret())
end

local function IsCustomAuraContainerAvailable()
    return C_XMLUtil ~= nil and C_XMLUtil.GetTemplateInfo ~= nil
       and C_XMLUtil.GetTemplateInfo("CustomAuraContainerTemplate") ~= nil
end

-- ------------------------------------------------------------
-- Native C++ Engine Aura Container Binding (ReapMeter AuraBind Pattern)
-- ------------------------------------------------------------
local auraContainer   = nil
local auraSlotButton  = nil
local isBoundToEngine = false
local boundCap        = nil

local function DropAuraContainer()
    if auraContainer then
        pcall(auraContainer.Hide, auraContainer)
        auraContainer   = nil
        auraSlotButton  = nil
        isBoundToEngine = false
        boundCap        = nil
    end
end

local function BuildAuraContainer(specCap)
    if not IsCustomAuraContainerAvailable() or InCombatLockdown() or not container then
        return false
    end

    if auraContainer and boundCap == specCap then
        return isBoundToEngine
    end

    DropAuraContainer()

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not ok or not c then return false end

    c:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    c:SetSize(1, 1)
    pcall(c.SetFrameStrata, c, container:GetFrameStrata())

    local slotFilters = { includeSpellIDs = SF_ROOTS }

    local okSlot, btn = pcall(c.AddAuraSlot, c, "vsf", "HELPFUL|PLAYER", {
        candidateFilters = slotFilters,
        initializeFrame = function(b)
            auraSlotButton = b
            b:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
            b:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
            pcall(b.SetFrameStrata, b, container:GetFrameStrata())
            b:SetFrameLevel(container:GetFrameLevel() + 2)
            if b.SetMouseMotionEnabled then b:SetMouseMotionEnabled(false) end

            local pad = (sfui.config.trackedBars and sfui.config.trackedBars.backdrop and sfui.config.trackedBars.backdrop.padding) or 1
            if bar then
                pcall(bar.Hide, bar)
            end

            -- Must be parented to b for SetApplicationBar to accept it without errors
            local engineBar = CreateFrame("StatusBar", "SfuiSoulFragmentsStatusBar", b)
            engineBar:SetPoint("TOPLEFT", container, "TOPLEFT", pad, -pad)
            engineBar:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -pad, pad)
            engineBar:SetStatusBarTexture(sfui.config.textures.white)
            local specCfg = SPEC_CONFIGS[common.get_current_spec_id() or 0] or SPEC_CONFIGS[SPEC_VENGEANCE]
            local cfg = sfui.config.soulFragments or {}
            local fillColor = cfg.color or (specCfg and specCfg.color) or { 0.4, 0.0, 1.0, 1.0 }
            engineBar:SetStatusBarColor(fillColor[1], fillColor[2], fillColor[3], fillColor[4] or 1.0)
            engineBar:SetMinMaxValues(0, specCap or 6)
            engineBar:SetValue(0)
            engineBar:SetFrameLevel(b:GetFrameLevel() + 1)
            bar = engineBar

            if b.SetApplicationBar then
                b:SetApplicationBar(engineBar, { maxApplications = specCap or 6 })
                isBoundToEngine = true
            end

            -- Centered Stack Count Number (same format, size, and no shadow as trackedbars.lua)
            local carrier = CreateFrame("Frame", nil, b)
            carrier:SetAllPoints(b)
            carrier:SetFrameLevel(b:GetFrameLevel() + 7)

            local fs = carrier:CreateFontString(nil, "OVERLAY")
            fs:SetDrawLayer("OVERLAY", 7)
            fs:SetFontObject(sfui.config.font_small)
            fs:SetPoint("CENTER", b, "CENTER", 0, 0)
            common.style_text(fs, nil, nil, "")

            if b.SetApplicationCount then
                local fmt = nil
                if C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
                    local okF, f = pcall(C_StringUtil.CreateNumericRuleFormatter)
                    if okF and f then
                        local r = (Enum and Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Nearest) or 0
                        if pcall(f.SetBreakpoints, f, { { threshold = 0, rounding = r, format = "%d" } }) then
                            fmt = f
                        end
                    end
                end
                if fmt then
                    b:SetApplicationCount(fs, { formatter = fmt })
                else
                    b:SetApplicationCount(fs)
                end
            end
        end,
    })

    if not okSlot then
        pcall(c.Hide, c)
        return false
    end

    c:SetEnabled(true)
    c:SetUnit("player")
    pcall(c.UpdateAllAuras, c)

    auraContainer = c
    boundCap      = specCap
    return isBoundToEngine
end

-- ------------------------------------------------------------
-- Fallback Cooldown Manager frame identification
-- ------------------------------------------------------------
local sfCDMFrame   = nil
local lastScanFail = nil
local SCAN_BACKOFF = 2
local scanFrames   = {}

local function frameMatchesSF(frame)
    if not frame then return false end
    local cdID = frame.cooldownID
    local sID = frame.spellID or (frame.info and frame.info.spellID)

    if cdID and not issecretvalue(cdID) and SF_ROOTS[cdID] then
        return true
    end
    if sID and not issecretvalue(sID) and SF_ROOTS[sID] then
        return true
    end

    -- Only call GetCooldownViewerCooldownInfo when safe (out of combat)
    if not InCombatLockdown() and frame.GetCooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local ok, id = pcall(frame.GetCooldownID, frame)
        if ok and id and not issecretvalue(id) then
            local okI, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
            if okI and type(info) == "table" then
                if not issecretvalue(info.spellID) and info.spellID and SF_ROOTS[info.spellID] then
                    return true
                end
                if type(info.linkedSpellIDs) == "table" then
                    for i = 1, #info.linkedSpellIDs do
                        local sid = info.linkedSpellIDs[i]
                        if not issecretvalue(sid) and sid and SF_ROOTS[sid] then return true end
                    end
                end
            end
        end
    end

    return false
end

local function scanPool(viewer, out)
    if viewer and viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
        for frame in viewer.itemFramePool:EnumerateActive() do
            out[#out + 1] = frame
        end
    end
end

local function GetSFCacheFrame()
    if sfCDMFrame then return sfCDMFrame end
    if lastScanFail and (GetTime() - lastScanFail) < SCAN_BACKOFF then return nil end

    wipe(scanFrames)
    scanPool(_G["BuffBarCooldownViewer"],  scanFrames)
    scanPool(_G["BuffIconCooldownViewer"], scanFrames)

    for i = 1, #scanFrames do
        if frameMatchesSF(scanFrames[i]) then
            sfCDMFrame   = scanFrames[i]
            lastScanFail = nil
            wipe(scanFrames)
            return sfCDMFrame
        end
    end

    wipe(scanFrames)
    lastScanFail = GetTime()
    return nil
end

-- ------------------------------------------------------------
-- Multi-tier stack reader (Fallback when C++ engine binder is absent):
--   Tier 1: Direct Player Aura query (0ms latency, always fresh)
--   Tier 2: Action Bar Display Count (Soul Cleave / Spirit Bomb native counter)
--   Tier 3: Blizzard Cooldown Viewer cached aura data
--   Tier 4: Genuine 0 vs Engine Restriction HOLD
-- ------------------------------------------------------------
local function GetSFApplications(specCfg)
    -- 1. Primary Direct Aura Check (Instant, 0ms latency)
    if specCfg and specCfg.primaryAura and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, specCfg.primaryAura)
        if ok and aura then
            local apps = aura.applications
            if issecretvalue(apps) then return apps end
            if type(apps) == "number" then return apps end
            return 1 -- Aura exists without explicit count -> 1 stack
        end
    end

    -- 2. Fallback Root Auras Check
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        for i = 1, #SF_SPELLS do
            local sID = SF_SPELLS[i]
            if not specCfg or sID ~= specCfg.primaryAura then
                local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sID)
                if ok and aura then
                    local apps = aura.applications
                    if issecretvalue(apps) then return apps end
                    if type(apps) == "number" then return apps end
                    return 1
                end
            end
        end
    end

    -- 3. Actionbar / Native Display Count Fallback (Soul Cleave / Spirit Bomb show live soul count)
    if C_Spell and C_Spell.GetSpellDisplayCount then
        for i = 1, #ACTION_DISPLAY_SPELLS do
            local sID = ACTION_DISPLAY_SPELLS[i]
            local ok, dc = pcall(C_Spell.GetSpellDisplayCount, sID)
            if ok and dc ~= nil then
                if issecretvalue(dc) or (type(dc) == "number" and dc > 0) then
                    return dc
                end
            end
        end
    end

    -- 4. Blizzard Cooldown Viewer cached auraData
    local frame = GetSFCacheFrame()
    if frame then
        local cache = rawget(frame, "auraDataCached") or frame.auraDataCached
        if type(cache) == "table" and cache.applications ~= nil then
            return cache.applications
        end
    end

    -- 5. Secrecy determination:
    -- If engine actively restricts auras right now (M+ key), a missing read means HOLD.
    -- Otherwise, in normal gameplay, absence is genuine 0.
    if EngineAurasRestricted() then
        return nil
    end

    return 0
end

-- ------------------------------------------------------------
-- Stack engine
-- ------------------------------------------------------------
local function GetSoulFragmentStacks()
    local spec    = common.get_current_spec_id and common.get_current_spec_id() or 0
    local specCfg = SPEC_CONFIGS[spec] or SPEC_CONFIGS[SPEC_VENGEANCE]

    local apps = GetSFApplications(specCfg)

    if apps == nil then
        -- Engine restriction active and no source spoke -> HOLD last known
        return lastKnownStacks, specCfg.cap
    end

    if issecretvalue(apps) then
        lastKnownStacks = apps
        return apps, specCfg.cap
    end

    local n = type(apps) == "number" and apps or (tonumber(apps) or 0)
    if n > 0 then
        lastKnownStacks = n
    else
        lastKnownStacks = 0
    end
    return n, specCfg.cap
end

-- ------------------------------------------------------------
-- Vehicle / Dragonflying Helpers
-- Mirrors bars.lua logic with event-driven cache invalidation.
-- ------------------------------------------------------------
local _getBonusIdx = C_ActionBar and C_ActionBar.GetBonusBarIndex or GetBonusBarIndex
local _getBonusOff = C_ActionBar and C_ActionBar.GetBonusBarOffset or GetBonusBarOffset
local _dragonflyingCache = nil

local function invalidate_dragonflying_cache()
    _dragonflyingCache = nil
end

local function is_dragonflying()
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

local function is_in_vehicle()
    if is_dragonflying() then return false end
    if UnitInVehicle("player") or UnitHasVehicleUI("player") then return true end
    if UnitExists("vehicle") and UnitVehicleSkin
            and UnitVehicleSkin("player") ~= nil then return true end
    if C_ActionBar and C_ActionBar.HasVehicleActionBar
            and C_ActionBar.HasVehicleActionBar() then return true end
    return false
end



-- ------------------------------------------------------------
-- UI Layout & Grid Builder
-- ------------------------------------------------------------
local function RebuildDividers(maxCap)
    if not container then return end
    cachedMaxCells = maxCap

    local width  = container:GetWidth()
    local height = container:GetHeight()
    if width  <= 0 then width  = 220 end
    if height <= 0 then height = 10  end

    local tbCfg  = sfui.config.trackedBars
    local pad    = (tbCfg and tbCfg.backdrop and tbCfg.backdrop.padding) or 1
    local innerW = width - 2 * pad
    local innerH = height - 2 * pad

    local numDividers = maxCap - 1
    local cellWidth   = innerW / maxCap

    for i = 1, math.max(numDividers, #dividers) do
        local div = dividers[i]
        if i <= numDividers then
            if not div then
                div = container:CreateTexture(nil, "OVERLAY", nil, 6)
                div:SetColorTexture(0.051, 0.059, 0.090, 1.0)  -- #0d0f17
                dividers[i] = div
            end
            div:SetSize(1, innerH)
            div:ClearAllPoints()
            div:SetPoint("LEFT", container, "LEFT", pad + i * cellWidth, 0)
            div:Show()
        elseif div then
            div:Hide()
        end
    end

    if thresholdTick then
        local specCfg = currentSpecConfig
        if specCfg and specCfg.reapThreshold and specCfg.reapThreshold < maxCap then
            thresholdTick:ClearAllPoints()
            thresholdTick:SetPoint("LEFT", container, "LEFT", pad + specCfg.reapThreshold * cellWidth, 0)
            thresholdTick:SetHeight(innerH)
            thresholdTick:Show()
        else
            thresholdTick:Hide()
        end
    end
end

-- ------------------------------------------------------------
-- Frame Initialization
-- ------------------------------------------------------------
local function CreateSoulFragmentsFrame()
    if container then return container end

    local cfg    = sfui.config.soulFragments or {}
    local tbCfg  = sfui.config.trackedBars
    local width  = (sfui.config.healthBar and sfui.config.healthBar.width) or 220
    local height = cfg.height or tbCfg.attachedHeight or 10

    -- Container: same BackdropTemplate + SetBackdrop as CreateBar() in trackedbars.lua.
    local bgColor = tbCfg.backdrop.color
    local pad     = tbCfg.backdrop.padding

    container = CreateFrame("Frame", "SfuiSoulFragmentsBar", UIParent, "BackdropTemplate")
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(15)
    container:SetSize(width, height)
    container:SetBackdrop({
        bgFile = sfui.config.textures.white,
        tile   = true,
        tileSize = 32,
    })
    container:SetBackdropColor(unpack(bgColor))

    -- Fallback StatusBar (used when CustomAuraContainer is unavailable)
    bar = CreateFrame("StatusBar", "SfuiSoulFragmentsStatusBar", container)
    bar:SetPoint("TOPLEFT",     container, "TOPLEFT",     pad, -pad)
    bar:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -pad, pad)
    bar:SetStatusBarTexture(sfui.config.textures.white)
    bar:SetMinMaxValues(0, 6)
    bar:SetValue(0)
    bar:SetFrameLevel(container:GetFrameLevel() + 1)

    -- Threshold landmark tick (e.g. 4-soul Reap)
    local tick = container:CreateTexture(nil, "OVERLAY", nil, 7)
    tick:SetWidth(1)
    tick:SetColorTexture(0.925, 0.878, 0.800, 0.9)  -- Cream
    tick:Hide()
    thresholdTick = tick

    -- Fallback Centered Stack Count Number (when CustomAuraContainer is unavailable)
    countText = container:CreateFontString(nil, "OVERLAY")
    countText:SetDrawLayer("OVERLAY", 7)
    countText:SetFontObject(sfui.config.font_small)
    countText:SetPoint("CENTER", container, "CENTER", 0, 0)
    common.style_text(countText, nil, nil, "")

    return container
end

-- ------------------------------------------------------------
-- Main Render Loop
-- ------------------------------------------------------------
local function UpdateDisplay()
    if not container or not bar then return end

    -- Exact same visibility conditions as bars.lua health bar (bar0)
    local isDragonflying = is_dragonflying()
    local inVehicle      = is_in_vehicle()
    local inCombat       = UnitAffectingCombat("player")
    local hasEnemyTarget = UnitCanAttack("player", "target")
    local showCoreBars   = (not inVehicle) and (not isDragonflying) and (inCombat or hasEnemyTarget)

    local cfg     = sfui.config.soulFragments or {}
    local enabled = (cfg.enabled ~= false) and (SfuiDB == nil or SfuiDB.enableSoulFragments ~= false)

    local shouldShow = enabled and showCoreBars
    local wasShown   = container:IsShown()

    if not shouldShow then
        if wasShown then
            container:Hide()
            if auraContainer then auraContainer:Hide() end
            if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
                sfui.trackedbars.ForceLayoutUpdate()
            end
        end
        return
    end

    if not wasShown then
        container:Show()
        if auraContainer then auraContainer:Show() end
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
            sfui.trackedbars.ForceLayoutUpdate()
        end
    end

    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    currentSpecConfig = SPEC_CONFIGS[spec] or SPEC_CONFIGS[SPEC_VENGEANCE]
    local cap = currentSpecConfig.cap

    if cachedMaxCells ~= cap then
        RebuildDividers(cap)
        if not InCombatLockdown() then
            BuildAuraContainer(cap)
        end
    end

    -- If C++ engine is not driving the bar via CustomAuraContainer, fallback to Lua update
    if not isBoundToEngine and bar then
        local stacks, maxCap = GetSoulFragmentStacks()

        bar:SetMinMaxValues(0, maxCap)
        local val = 0
        if stacks == nil then
            bar:SetValue(0)
            if countText then countText:SetText("") end
        elseif issecretvalue(stacks) then
            pcall(bar.SetValue, bar, stacks)
            if countText then countText:SetText("") end
        else
            local num = type(stacks) == "number" and stacks or tonumber(stacks)
            if num and num == num and num >= -3.4e38 and num <= 3.4e38 then
                val = num
                bar:SetValue(val)
            else
                bar:SetValue(0)
                val = 0
            end
            if countText then
                countText:SetText(val > 0 and tostring(val) or "")
            end
        end

        local fillColor = cfg.color or (currentSpecConfig and currentSpecConfig.color) or { 0.4, 0.0, 1.0, 1.0 }
        bar:SetStatusBarColor(fillColor[1], fillColor[2], fillColor[3], fillColor[4] or 1.0)
    else
        if countText then countText:SetText("") end
    end
end

-- ------------------------------------------------------------
-- Positioning & Layout Sync with SFUI Health Bar (bar0)
-- ------------------------------------------------------------
function sfui.soulfragments:UpdatePosition()
    if not container then
        CreateSoulFragmentsFrame()
    end
    if not container then return end

    local bar0    = (sfui.bars and sfui.bars.get_bar0 and sfui.bars.get_bar0()) or _G["sfui_bar0"]
    local target  = (bar0 and bar0.backdrop) or bar0 or _G["sfui_bar0_Backdrop"]

    local cfg     = sfui.config.soulFragments or {}
    local spacing = (sfui.config.barLayout and sfui.config.barLayout.spacing)
                    or (sfui.config.bars and sfui.config.bars.spacing) or 2
    local healthWidth     = (sfui.config.healthBar and sfui.config.healthBar.width)
                           or (bar0 and bar0:GetWidth()) or 220
    local widthMultiplier = (sfui.config.trackedBars
                             and sfui.config.trackedBars.attachedWidthMultiplier) or 0.8
    local width  = healthWidth * widthMultiplier
    local height = cfg.height or 10

    container:SetSize(width, height)
    container:ClearAllPoints()
    if target then
        container:SetPoint("BOTTOM", target, "TOP", 0, spacing)
    else
        local posY = (SfuiDB and SfuiDB.healthBarY)
                     or (sfui.config.bars and sfui.config.bars.pos and sfui.config.bars.pos.y)
                     or -150
        container:SetPoint("BOTTOM", UIParent, "CENTER", 0, posY + 20)
    end

    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    currentSpecConfig = SPEC_CONFIGS[spec] or SPEC_CONFIGS[SPEC_VENGEANCE]
    RebuildDividers(currentSpecConfig.cap)
    BuildAuraContainer(currentSpecConfig.cap)

    if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
        sfui.trackedbars.ForceLayoutUpdate()
    end
end

-- ------------------------------------------------------------
-- Initialization
-- Called by PLAYER_ENTERING_WORLD on every login/reload.
-- Frame creation is idempotent (container guard). Everything that
-- must only run ONCE (RegisterUpdate, hooks) is guarded by _initialized.
-- ------------------------------------------------------------
function sfui.soulfragments:Initialize()
    CreateSoulFragmentsFrame()

    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    currentSpecConfig = SPEC_CONFIGS[spec] or SPEC_CONFIGS[SPEC_VENGEANCE]
    self:UpdatePosition()
    BuildAuraContainer(currentSpecConfig.cap)

    if _initialized then
        UpdateDisplay()
        return
    end
    _initialized = true

    -- Unit events: require RegisterUnitEvent for player-only filtering.
    -- UNIT_AURA / UNIT_SPELLCAST_SUCCEEDED / UNIT_POWER_UPDATE fire for every
    -- nearby unit on the central frame — we only want the player's.
    local unitFrame = CreateFrame("Frame")
    unitFrame:RegisterUnitEvent("UNIT_AURA",               "player")
    unitFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    unitFrame:RegisterUnitEvent("UNIT_POWER_UPDATE",        "player")
    unitFrame:SetScript("OnEvent", function() UpdateDisplay() end)

    -- 20 FPS update loop — registered once via the shared dispatcher.
    -- sfui.events.RegisterUpdate has no dedup, so the _initialized guard above
    -- is essential to prevent stacking callbacks on every PLAYER_ENTERING_WORLD.
    sfui.events.RegisterUpdate("SoulFragments", 0.05, function()
        UpdateDisplay()
    end)

    UpdateDisplay()
end

-- ------------------------------------------------------------
-- Module-scope event registrations
-- These run once at addon load time. Named local functions are used
-- so sfui.events' identity-dedup correctly prevents any double-binding
-- if this file were somehow evaluated twice.
-- Mirrors the pattern in bars.lua (end-of-do-block registrations).
-- ------------------------------------------------------------
local function onSpecChanged()
    local sp = common.get_current_spec_id and common.get_current_spec_id() or 0
    currentSpecConfig = SPEC_CONFIGS[sp] or SPEC_CONFIGS[SPEC_VENGEANCE]
    invalidate_dragonflying_cache()
    if not InCombatLockdown() then
        BuildAuraContainer(currentSpecConfig.cap)
    end
    if container then sfui.soulfragments:UpdatePosition() end
    UpdateDisplay()
end

local function onCombatOrTarget() UpdateDisplay() end

local function onGlideOrVehicle()
    invalidate_dragonflying_cache()
    UpdateDisplay()
end

local function onEncounterBoundary()
    -- Aura instance IDs re-randomize between pulls; drop the cached CDM
    -- frame pointer. lastKnownStacks is preserved so the bar HOLDs.
    sfCDMFrame   = nil
    lastScanFail = nil
    UpdateDisplay()
end

local function onAuraDataProviderSwitch(useRealDataProvider)
    sfCDMFrame   = nil
    lastScanFail = nil
    if not useRealDataProvider then
        -- Entering secret-aura mode: clear stale OOC hold state so a clean
        -- CDM read (not a stale OOC count) drives the bar during the M+ key.
        lastKnownStacks = 0
    end
    UpdateDisplay()
end

sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", onSpecChanged)

sfui.events.RegisterEvent("PLAYER_REGEN_DISABLED", onCombatOrTarget)
sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED",  onCombatOrTarget)
sfui.events.RegisterEvent("PLAYER_TARGET_CHANGED", onCombatOrTarget)

sfui.events.RegisterEvent("PLAYER_CAN_GLIDE_CHANGED",     onGlideOrVehicle)
sfui.events.RegisterEvent("PLAYER_IS_GLIDING_CHANGED",    onGlideOrVehicle)
sfui.events.RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED", onGlideOrVehicle)
sfui.events.RegisterEvent("UPDATE_SHAPESHIFT_FORM",       onGlideOrVehicle)
sfui.events.RegisterEvent("UNIT_ENTERED_VEHICLE",         onGlideOrVehicle)
sfui.events.RegisterEvent("UNIT_EXITED_VEHICLE",          onGlideOrVehicle)
sfui.events.RegisterEvent("VEHICLE_UPDATE",               onGlideOrVehicle)

sfui.events.RegisterEvent("ENCOUNTER_START", onEncounterBoundary)
sfui.events.RegisterEvent("ENCOUNTER_END",   onEncounterBoundary)

sfui.events.RegisterEvent("AURA_DATA_PROVIDER_SWITCH", onAuraDataProviderSwitch)

-- Diagnostics & Memory Profiling Integration
function sfui.soulfragments_debug_info()
    return {
        frameCreated = container ~= nil,
        frameShown   = container and container:IsShown() or false,
        engineBound  = isBoundToEngine,
        cdmCached    = sfCDMFrame ~= nil,
        lastStacks   = lastKnownStacks,
        maxCap       = currentSpecConfig and currentSpecConfig.cap or 0,
        dividers     = #dividers,
    }
end

-- PLAYER_ENTERING_WORLD triggers Initialize on every login/reload.
-- Routes through sfui.events, same as bars.lua.
sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    invalidate_dragonflying_cache()
    sfui.soulfragments:Initialize()
end)
