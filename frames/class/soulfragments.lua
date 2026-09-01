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
    [1227619] = true,  -- Shattered Souls (CDM entry)
    [20811]   = true,
}

-- Ordered list for direct aura reads
local SF_SPELLS = { 203981, 1245577, 1245584 }

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
        color = { 0.4, 0.0, 1.0, 1.0 }, -- #6600ff Cosmic Purple
        reapThreshold = 4,
    },
}

-- ------------------------------------------------------------
-- Module State
-- ------------------------------------------------------------
local container        = nil
local bar              = nil
local countText        = nil
local thresholdTick    = nil
local currentSpecConfig = nil
local cachedMaxCells   = 0

-- Devourer Void Metamorphosis Secondary Bar
local metaContainer    = nil
local metaBar          = nil
local metaText         = nil
local metaTimerText    = nil
local metaTick         = nil
local metaHasTimerText = false
local metaHasText      = false

-- Talent check helper
local function IsTalentKnown(spellID)
    local book = C_SpellBook
    if book and book.IsSpellKnownOrInSpellBook then
        local isKnown = book.IsSpellKnownOrInSpellBook(spellID)
        if isKnown then return true end
    elseif book and book.IsSpellKnown then
        local isKnown = book.IsSpellKnown(spellID)
        if isKnown then return true end
    elseif IsPlayerSpell and IsPlayerSpell(spellID) then
        return true
    end
    return false
end

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
        auraContainer:Hide()
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

    local c = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not c then return false end

    c:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    c:SetSize(1, 1)
    c:SetFrameStrata(container:GetFrameStrata())

    local slotFilters = { includeSpellIDs = SF_ROOTS }

    local btn = c:AddAuraSlot("vsf", "HELPFUL|PLAYER", {
        candidateFilters = slotFilters,
        initializeFrame = function(b)
            auraSlotButton = b
            b:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
            b:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
            b:SetFrameStrata(container:GetFrameStrata())
            b:SetFrameLevel(container:GetFrameLevel() + 2)
            if b.SetMouseMotionEnabled then b:SetMouseMotionEnabled(false) end

            local pad = (sfui.config.trackedBars and sfui.config.trackedBars.backdrop and sfui.config.trackedBars.backdrop.padding) or 1
            if bar then
                bar:Hide()
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
            fs:SetFontObject(sfui.config.font)
            fs:SetPoint("CENTER", b, "CENTER", 0, 0)
            common.style_text(fs, sfui.config.font, 12, "")

            if b.SetApplicationCount then
                local fmt = nil
                if C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
                    local f = C_StringUtil.CreateNumericRuleFormatter()
                    if f then
                        local r = (Enum and Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Nearest) or 0
                        f:SetBreakpoints({ { threshold = 0, rounding = r, format = "%d" } })
                        fmt = f
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

    if not btn then
        c:Hide()
        return false
    end

    c:SetEnabled(true)
    c:SetUnit("player")
    if c.UpdateAllAuras then c:UpdateAllAuras() end

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

    if type(cdID) == "number" and SF_ROOTS[cdID] then
        return true
    end
    if type(sID) == "number" and SF_ROOTS[sID] then
        return true
    end

    -- Only call GetCooldownViewerCooldownInfo when safe (out of combat)
    if not InCombatLockdown() and frame.GetCooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local id = frame:GetCooldownID()
        if type(id) == "number" then
            local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(id)
            if type(info) == "table" then
                if type(info.spellID) == "number" and SF_ROOTS[info.spellID] then
                    return true
                end
                if type(info.linkedSpellIDs) == "table" then
                    for i = 1, #info.linkedSpellIDs do
                        local sid = info.linkedSpellIDs[i]
                        if type(sid) == "number" and SF_ROOTS[sid] then return true end
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
            if frameMatchesSF(frame) then
                table.insert(out, frame)
            end
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
-- Live Multi-tier Stack Aggregator
-- ------------------------------------------------------------
-- Multi-tier stack reader (Fallback when C++ engine binder is absent):
--   Tier 1: Direct Player Aura query (0ms latency, always fresh)
--   Tier 2: Action Bar Display Count (Soul Cleave / Spirit Bomb native counter)
--   Tier 3: Blizzard Cooldown Viewer cached aura data
--   Tier 4: Genuine 0 vs Engine Restriction HOLD
-- ------------------------------------------------------------
local function GetSFApplications(specCfg)
    local restricted = EngineAurasRestricted()

    -- 1. Primary Direct Aura Check (Instant, 0ms latency)
    if specCfg and specCfg.primaryAura and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(specCfg.primaryAura)
        if aura then
            local apps = aura.applications
            if type(apps) == "number" then return apps end
            if restricted and issecretvalue(apps) then return apps end
            return 1 -- Aura exists without explicit count -> 1 stack
        end
    end

    -- 2. Fallback Root Auras Check
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        for i = 1, #SF_SPELLS do
            local sID = SF_SPELLS[i]
            if not specCfg or sID ~= specCfg.primaryAura then
                local aura = C_UnitAuras.GetPlayerAuraBySpellID(sID)
                if aura then
                    local apps = aura.applications
                    if type(apps) == "number" then return apps end
                    if restricted and issecretvalue(apps) then return apps end
                    return 1
                end
            end
        end
    end

    -- 3. Actionbar / Native Display Count Fallback (Soul Cleave / Spirit Bomb show live soul count)
    if C_Spell and C_Spell.GetSpellDisplayCount then
        for i = 1, #ACTION_DISPLAY_SPELLS do
            local sID = ACTION_DISPLAY_SPELLS[i]
            local dc = C_Spell.GetSpellDisplayCount(sID)
            if dc ~= nil then
                if type(dc) == "number" and dc > 0 then
                    return dc
                elseif restricted and issecretvalue(dc) then
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
    if restricted then
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
-- Vehicle / Dragonflying Helpers (Centralized via common.lua)
-- ------------------------------------------------------------
local is_dragonflying = common.is_dragonflying
local is_in_vehicle   = common.is_in_vehicle



-- ------------------------------------------------------------
-- UI Layout & Grid Builder
-- ------------------------------------------------------------
local function UpdateThresholdTick(specCfg, maxCap, currentStacks)
    if not container or not thresholdTick then return end
    local reapThreshold = specCfg and specCfg.reapThreshold
    if not reapThreshold then
        thresholdTick:Hide()
        return
    end

    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    local hasMoC = false
    if spec == SPEC_DEVOURER and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(1238495) -- Moment of Craving
        if aura then hasMoC = true end
    end

    local activeThreshold = hasMoC and 10 or reapThreshold
    local width  = container:GetWidth()
    local height = container:GetHeight()
    if width  <= 0 then width  = 220 end
    if height <= 0 then height = 14  end

    local tbCfg  = sfui.config.trackedBars
    local pad    = (tbCfg and tbCfg.backdrop and tbCfg.backdrop.padding) or 1
    local innerW = width - 2 * pad
    local innerH = height - 2 * pad
    local cellWidth = innerW / maxCap

    if activeThreshold and activeThreshold <= maxCap then
        thresholdTick:ClearAllPoints()
        thresholdTick:SetPoint("LEFT", container, "LEFT", pad + activeThreshold * cellWidth, 0)
        thresholdTick:SetHeight(innerH)

        if hasMoC then
            thresholdTick:SetColorTexture(1.0, 0.85, 0.2, 1.0) -- Gold for 10-soul MoC
        else
            local n = (type(currentStacks) == "number" and currentStacks) or 0
            if n >= activeThreshold then
                thresholdTick:SetColorTexture(0.2, 1.0, 0.85, 0.95) -- Primed (bright emerald/cyan accent)
            else
                thresholdTick:SetColorTexture(0.925, 0.878, 0.800, 0.6) -- Muted cream
            end
        end
        thresholdTick:Show()
    else
        thresholdTick:Hide()
    end
end

local function RebuildDividers(maxCap)
    if not container then return end
    cachedMaxCells = maxCap
    UpdateThresholdTick(currentSpecConfig, maxCap, lastKnownStacks)
end

-- ------------------------------------------------------------
-- Frame Initialization
-- ------------------------------------------------------------
local function CreateSoulFragmentsFrame()
    if container then return container end

    local cfg    = sfui.config.soulFragments or {}
    local tbCfg  = sfui.config.trackedBars
    local width  = (sfui.config.healthBar and sfui.config.healthBar.width) or 220
    local height = cfg.height or 14

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
    container:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.9)

    -- Fallback StatusBar (used when CustomAuraContainer is unavailable)
    bar = CreateFrame("StatusBar", "SfuiSoulFragmentsStatusBar", container)
    bar:SetPoint("TOPLEFT",     container, "TOPLEFT",     pad, -pad)
    bar:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -pad, pad)
    bar:SetStatusBarTexture(sfui.config.textures.white)
    bar:SetMinMaxValues(0, 6)
    bar:SetValue(0)
    bar:SetFrameLevel(container:GetFrameLevel() + 1)

    -- Threshold landmark tick (e.g. 4-soul Reap / 10-soul MoC)
    local tick = container:CreateTexture(nil, "OVERLAY", nil, 7)
    tick:SetWidth(1)
    tick:SetColorTexture(0.925, 0.878, 0.800, 0.9)  -- Cream
    tick:Hide()
    thresholdTick = tick

    -- Fallback Centered Stack Count Number (when CustomAuraContainer is unavailable)
    countText = container:CreateFontString(nil, "OVERLAY")
    countText:SetDrawLayer("OVERLAY", 7)
    countText:SetFontObject(sfui.config.font)
    countText:SetPoint("CENTER", container, "CENTER", 0, 0)
    common.style_text(countText, sfui.config.font, 12, "")

    return container
end

-- ------------------------------------------------------------
-- Devourer Void Metamorphosis Frame Initialization
-- ------------------------------------------------------------
local function CreateVoidMetaFrame()
    if metaContainer then return metaContainer end

    local tbCfg      = sfui.config.trackedBars
    local width      = (sfui.config.healthBar and sfui.config.healthBar.width) or 220
    local metaHeight = 12

    local bgColor = tbCfg.backdrop.color
    local pad     = tbCfg.backdrop.padding

    metaContainer = CreateFrame("Frame", "SfuiVoidMetaBar", UIParent, "BackdropTemplate")
    metaContainer:SetFrameStrata("MEDIUM")
    metaContainer:SetFrameLevel(15)
    metaContainer:SetSize(width, metaHeight)
    metaContainer:SetBackdrop({
        bgFile = sfui.config.textures.white,
        tile   = true,
        tileSize = 32,
    })
    metaContainer:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.9)

    metaBar = CreateFrame("StatusBar", "SfuiVoidMetaStatusBar", metaContainer)
    metaBar:SetPoint("TOPLEFT",     metaContainer, "TOPLEFT",     pad, -pad)
    metaBar:SetPoint("BOTTOMRIGHT", metaContainer, "BOTTOMRIGHT", -pad, pad)
    metaBar:SetStatusBarTexture(sfui.config.textures.white)
    metaBar:SetMinMaxValues(0, 50)
    metaBar:SetValue(0)
    metaBar:SetStatusBarColor(0.000, 0.553, 0.745, 1.0) -- ReapMeter Devourer Build Azure (#008dbe)
    metaBar:SetFrameLevel(metaContainer:GetFrameLevel() + 1)

    local tick = metaContainer:CreateTexture(nil, "OVERLAY", nil, 7)
    tick:SetWidth(1)
    tick:SetColorTexture(0.925, 0.878, 0.800, 0.9)
    tick:Hide()
    metaTick = tick

    -- Dedicated text carrier frame above the status bar fill
    local textCarrier = CreateFrame("Frame", nil, metaContainer)
    textCarrier:SetAllPoints(metaContainer)
    textCarrier:SetFrameLevel(metaBar:GetFrameLevel() + 5)

    metaText = textCarrier:CreateFontString(nil, "OVERLAY")
    metaText:SetDrawLayer("OVERLAY", 7)
    metaText:SetFontObject(sfui.config.font)
    metaText:SetPoint("CENTER", textCarrier, "CENTER", 0, 0)
    common.style_text(metaText, sfui.config.font, 11, "")

    metaTimerText = textCarrier:CreateFontString(nil, "OVERLAY")
    metaTimerText:SetDrawLayer("OVERLAY", 7)
    metaTimerText:SetFontObject(sfui.config.font)
    metaTimerText:SetPoint("RIGHT", textCarrier, "RIGHT", -pad - 4, 0)
    common.style_text(metaTimerText, sfui.config.font, 10, "")

    return metaContainer
end

-- ------------------------------------------------------------
-- Devourer Void Metamorphosis Render Loop
-- ------------------------------------------------------------
local function UpdateVoidMetaDisplay(shouldShow)
    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    if spec ~= SPEC_DEVOURER or not shouldShow then
        if metaContainer and metaContainer:IsShown() then
            metaContainer:Hide()
        end
        return
    end

    if not metaContainer then
        CreateVoidMetaFrame()
    end
    if not metaContainer:IsShown() then
        metaContainer:Show()
    end

    local VOID_META_ID        = 1217607
    local DARK_HEART_ID       = 1225789
    local SILENCE_WHISPERS_ID = 1227702
    local SOUL_GLUTTON_ID     = 1247534

    local inVoidMeta = false
    local metaExpiration = 0
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(VOID_META_ID)
        if aura then
            inVoidMeta = true
            metaExpiration = aura.expirationTime or 0
        end
    end

    local tbCfg = sfui.config.trackedBars
    local pad   = (tbCfg and tbCfg.backdrop and tbCfg.backdrop.padding) or 1
    local width = metaContainer:GetWidth()
    if width <= 0 then width = 220 end
    local innerW = width - 2 * pad
    local innerH = (metaContainer:GetHeight() > 0 and metaContainer:GetHeight() or 12) - 2 * pad

    if inVoidMeta then
        -- In Void Metamorphosis: Collapsing Star build (0 to 30) - ReapMeter Form Violet (#735abf)
        local starStacks = 0
        if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
            local aura = C_UnitAuras.GetPlayerAuraBySpellID(SILENCE_WHISPERS_ID)
            if aura and aura.applications then
                starStacks = aura.applications
            end
        end

        local maxStar = 30
        metaBar:SetMinMaxValues(0, maxStar)
        metaBar:SetValue(math.min(starStacks, maxStar))
        metaBar:SetStatusBarColor(0.0, 0.40, 1.0, 1.0) -- Cosmic Blue (#0066ff)

        metaText:SetText(starStacks > 0 and (starStacks .. " / " .. maxStar) or "META")

        if metaExpiration and metaExpiration > 0 then
            local rem = math.max(0, metaExpiration - GetTime())
            metaTimerText:SetText(string.format("%.1fs", rem))
            metaHasTimerText = true
        else
            if metaHasTimerText then
                metaTimerText:SetText("")
                metaHasTimerText = false
            end
        end

        if metaTick then
            metaTick:Hide()
        end
    else
        -- Out of Void Metamorphosis: Dark Heart build (0 to 50, or 35 with Soul Glutton)
        local darkHeartStacks = 0
        if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
            local aura = C_UnitAuras.GetPlayerAuraBySpellID(DARK_HEART_ID)
            if aura and aura.applications then
                darkHeartStacks = aura.applications
            end
        end

        local hasSG = IsTalentKnown(SOUL_GLUTTON_ID)
        local maxStacks = hasSG and 35 or 50

        metaBar:SetMinMaxValues(0, maxStacks)
        metaBar:SetValue(math.min(darkHeartStacks, maxStacks))

        if darkHeartStacks >= maxStacks then
            metaText:SetText("|cffedcd4eMETA READY|r")
            metaBar:SetStatusBarColor(0.929, 0.804, 0.306, 1.0) -- ReapMeter GOLD
            metaHasText = true
        elseif darkHeartStacks > 0 then
            metaText:SetText(darkHeartStacks .. " / " .. maxStacks)
            metaBar:SetStatusBarColor(0.000, 0.553, 0.745, 1.0) -- ReapMeter Devourer Build Azure (#008dbe)
            metaHasText = true
        else
            if metaHasText then
                metaText:SetText("")
                metaHasText = false
            end
            metaBar:SetStatusBarColor(0.000, 0.553, 0.745, 1.0)
        end

        if metaHasTimerText then
            metaTimerText:SetText("")
            metaHasTimerText = false
        end

        if metaTick then
            metaTick:Hide()
        end
    end
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

    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    currentSpecConfig = SPEC_CONFIGS[spec]

    local shouldShow = enabled and showCoreBars and (currentSpecConfig ~= nil)
    local wasShown   = container:IsShown()

    if not shouldShow then
        if wasShown then
            container:Hide()
            if auraContainer then auraContainer:Hide() end
            if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
                sfui.trackedbars.ForceLayoutUpdate()
            end
        end
        UpdateVoidMetaDisplay(false)
        return
    end

    if not wasShown then
        container:Show()
        if auraContainer then auraContainer:Show() end
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
            sfui.trackedbars.ForceLayoutUpdate()
        end
    end

    local cap = currentSpecConfig.cap

    if cachedMaxCells ~= cap then
        RebuildDividers(cap)
        if not InCombatLockdown() then
            BuildAuraContainer(cap)
        end
    end

    -- Feature 1 & 2: Dynamic Threshold (MoC 10 vs 4) and Spender Primed status
    UpdateThresholdTick(currentSpecConfig, cap, lastKnownStacks)

    -- Feature 2 & 3: Metamorphosis State Tint & Overcap Warning
    local inMeta = false
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local metaID = (spec == SPEC_DEVOURER and 1217607) or (spec == SPEC_VENGEANCE and 187827) or 162264
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(metaID)
        if aura then inMeta = true end
    end

    local currentCount = (type(lastKnownStacks) == "number" and lastKnownStacks) or 0
    local isOvercapping = (currentCount >= cap)
    local tbCfg = sfui.config.trackedBars
    local defBg = (tbCfg and tbCfg.backdrop and tbCfg.backdrop.color) or { 0.051, 0.059, 0.090, 0.9 }

    if isOvercapping then
        container:SetBackdropColor(0.28, 0.08, 0.05, 0.95) -- Alert amber-red backdrop
    elseif inMeta then
        if spec == SPEC_DEVOURER then
            container:SetBackdropColor(0.18, 0.05, 0.32, 0.95) -- Ethereal void purple backdrop
        elseif spec == SPEC_VENGEANCE then
            container:SetBackdropColor(0.15, 0.0, 0.28, 0.95) -- Cosmic purple backdrop
        else
            container:SetBackdropColor(0.0, 0.18, 0.10, 0.95) -- Fel green backdrop
        end
    else
        container:SetBackdropColor(defBg[1], defBg[2], defBg[3], defBg[4] or 0.9)
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
            bar:SetValue(stacks)
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

    UpdateVoidMetaDisplay(shouldShow)
end

-- ------------------------------------------------------------
-- Positioning & Layout Sync with SFUI Health Bar (bar0)
-- ------------------------------------------------------------
function sfui.soulfragments:UpdatePosition()
    if not container then
        CreateSoulFragmentsFrame()
    end
    if not container then return end

    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    currentSpecConfig = SPEC_CONFIGS[spec]

    if not currentSpecConfig then
        if container then container:Hide() end
        if auraContainer then auraContainer:Hide() end
        if metaContainer then metaContainer:Hide() end
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
            sfui.trackedbars.ForceLayoutUpdate()
        end
        return
    end

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
    local height = cfg.height or 14

    if spec == SPEC_DEVOURER then
        if not metaContainer then
            CreateVoidMetaFrame()
        end
        if metaContainer then
            metaContainer:SetSize(width, 12)
            metaContainer:ClearAllPoints()
            if target then
                metaContainer:SetPoint("BOTTOM", target, "TOP", 0, spacing)
            else
                local posY = (SfuiDB and SfuiDB.healthBarY)
                             or (sfui.config.bars and sfui.config.bars.pos and sfui.config.bars.pos.y)
                             or -150
                metaContainer:SetPoint("BOTTOM", UIParent, "CENTER", 0, posY + 20)
            end
        end

        container:SetSize(width, height)
        container:ClearAllPoints()
        if metaContainer then
            container:SetPoint("BOTTOM", metaContainer, "TOP", 0, spacing)
        elseif target then
            container:SetPoint("BOTTOM", target, "TOP", 0, spacing)
        end
    else
        if metaContainer then
            metaContainer:Hide()
        end
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
    end

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
    local spec = common.get_current_spec_id and common.get_current_spec_id() or 0
    currentSpecConfig = SPEC_CONFIGS[spec]

    if not currentSpecConfig then
        if container then container:Hide() end
        if metaContainer then metaContainer:Hide() end
        sfui.events.UnregisterUpdate("SoulFragments")
        return
    end

    CreateSoulFragmentsFrame()
    if spec == SPEC_DEVOURER then
        CreateVoidMetaFrame()
    end

    self:UpdatePosition()
    BuildAuraContainer(currentSpecConfig.cap)

    if _initialized then
        sfui.events.RegisterUpdate("SoulFragments", 0.05, function()
            UpdateDisplay()
        end)
        UpdateDisplay()
        return
    end
    _initialized = true

    -- Unit events: player-only via the central unit-event frame.
    local function onUnitEvent() UpdateDisplay() end
    sfui.events.RegisterUnitEvents(
        {"UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_POWER_UPDATE"},
        "player", onUnitEvent
    )

    -- 20 FPS update loop — registered once via the shared dispatcher.
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
    currentSpecConfig = SPEC_CONFIGS[sp]
    if currentSpecConfig then
        CreateSoulFragmentsFrame()
        if sp == SPEC_DEVOURER then CreateVoidMetaFrame() end
        if not InCombatLockdown() then
            BuildAuraContainer(currentSpecConfig.cap)
        end
        if container then sfui.soulfragments:UpdatePosition() end
        sfui.events.RegisterUpdate("SoulFragments", 0.05, function()
            UpdateDisplay()
        end)
    else
        DropAuraContainer()
        if container then container:Hide() end
        if metaContainer then metaContainer:Hide() end
        sfui.events.UnregisterUpdate("SoulFragments")
        if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
            sfui.trackedbars.ForceLayoutUpdate()
        end
    end
    UpdateDisplay()
end

local function onCombatOrTarget() UpdateDisplay() end

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

sfui.events.RegisterEvent("ENCOUNTER_START", onEncounterBoundary)
sfui.events.RegisterEvent("ENCOUNTER_END",   onEncounterBoundary)

sfui.events.RegisterEvent("AURA_DATA_PROVIDER_SWITCH", onAuraDataProviderSwitch)

-- Diagnostics & Memory Profiling Integration
function sfui.soulfragments_debug_info()
    return {
        frameCreated = container ~= nil,
        frameShown   = container and container:IsShown() or false,
        metaShown    = metaContainer and metaContainer:IsShown() or false,
        engineBound  = isBoundToEngine,
        cdmCached    = sfCDMFrame ~= nil,
        lastStacks   = lastKnownStacks,
        maxCap       = currentSpecConfig and currentSpecConfig.cap or 0,
        active       = currentSpecConfig ~= nil,
    }
end

-- PLAYER_ENTERING_WORLD triggers Initialize on every login/reload.
-- Routes through sfui.events, same as bars.lua.
sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    sfui.soulfragments:Initialize()
end)
