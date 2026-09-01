local addonName, addon = ...
sfui.trackedicons = {}

local C_Spell = C_Spell
local C_Item = C_Item
local C_CooldownViewer = C_CooldownViewer
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local CreateFrame = CreateFrame
local UIParent = UIParent
local GameTooltip = sfui.tooltip or _G.GameTooltip
local hooksecurefunc = hooksecurefunc
local C_Timer = C_Timer
local IsMounted = IsMounted
local wipe = wipe
local pairs = pairs
local ipairs = ipairs
local tinsert = table.insert

local panels = {} -- Active icon panels
local _needsStateUpdate = true -- Start dirty for initial render
local _needsLayoutUpdate = true
local _layoutCooldown = 0

-- Helper: Mark icons as needing a state refresh
local function MarkDirty(needsLayout)
    _needsStateUpdate = true
    if needsLayout then
        _needsLayoutUpdate = true
    end
end
sfui.trackedicons.MarkDirty = MarkDirty
local issecretvalue = sfui.common.issecretvalue
-- STATIC REUSE (Memory Optimization)
local _tempGlowCfg = {}
local _defaultColor = { 1, 1, 0, 1 }
local _defaultTextColor = { 1, 1, 1, 1 } -- Reuse to avoid per-call allocation
local _emptyTable = {}
local _iconCounter = 0
local _staticActiveEntries = {}
local _staticActiveIcons = {}

local _iconConfigCache = setmetatable({}, { __mode = "k" })
function sfui.trackedicons.InvalidateConfigCache()
    for k in pairs(_iconConfigCache) do
        _iconConfigCache[k] = nil
    end
end

-- Helper: Get value from entry → panel → global → hardcoded default (M+ safe)
-- All sources are safe tables (user config, SfuiDB, config.lua) - no secret values
local function GetIconValue(entrySettings, panelConfig, key, default)
    local cacheKey = entrySettings or panelConfig or "global"
    local cache = _iconConfigCache[cacheKey]
    if not cache then
        cache = {}
        _iconConfigCache[cacheKey] = cache
    end

    local val = cache[key]
    if val ~= nil then
        if val == "__NIL__" then return default end
        return val
    end

    if entrySettings and entrySettings[key] ~= nil then
        val = entrySettings[key]
    elseif panelConfig and panelConfig[key] ~= nil then
        val = panelConfig[key]
    else
        local globalCfg = SfuiDB and SfuiDB.iconGlobalSettings
        if globalCfg and globalCfg[key] ~= nil then
            val = globalCfg[key]
        else
            local g = sfui.config
            local configDefault = g and g.icon_panel_global_defaults
            if configDefault and configDefault[key] ~= nil then
                val = configDefault[key]
            end
        end
    end

    if val == nil then
        cache[key] = "__NIL__"
        return default
    end

    cache[key] = val
    return val
end

local function update_item_cd(icon)
    local s, d, e = C_Item.GetItemCooldown(icon.id)
    icon._start, icon._duration, icon._isEnabled = s, d, e
    CooldownFrame_Set(icon.cooldown, s, d, e)
    
    if icon.shadowCooldown then
        if not issecretvalue(s) and not issecretvalue(d) then
            icon.shadowCooldown:SetCooldown(s, d)
        else
            icon.shadowCooldown:Clear()
        end
    end
    return C_Item.GetItemCount(icon.id)
end

-- pcall_spell_cd and pcall_sync_swipe removed — no longer needed
-- SetCooldown handles secret values natively at C++ level

sfui.trackedicons.StopGlow = sfui.glows.stop_glow

local _activeGlowCount = 0

-- Local wrapper to ensure state cleanup
local function StopGlow(icon)
    if icon._glowActive then
        if _activeGlowCount > 0 then
            _activeGlowCount = _activeGlowCount - 1
        end
    end
    sfui.glows.stop_glow(icon)
    -- Do NOT clear _glowStartTime here, as it breaks the timeout logic (infinite restart loop)
    -- _glowStartTime is cleared explicitly when the icon is no longer ready.
    icon._lastGlowCfg = nil
    icon._glowActive = false
end


local function StartGlow(icon, cfg)
    if not icon._glowActive then
        _activeGlowCount = _activeGlowCount + 1
    end
    sfui.glows.start_glow(icon, cfg)
    icon._glowActive = true
    -- Track config for comparison without allocating a new table
    if not icon._lastGlowCfg then icon._lastGlowCfg = {} end
    local t = icon._lastGlowCfg
    t.glowType = cfg.glowType
    t.glowColor = cfg.glowColor -- Shared ref is fine for comparison
    t.glowScale = cfg.glowScale
    t.glowIntensity = cfg.glowIntensity
    t.glowSpeed = cfg.glowSpeed
    t.glowLines = cfg.glowLines
    t.glowThickness = cfg.glowThickness
    t.glowParticles = cfg.glowParticles
end
sfui.trackedicons.StartGlow = StartGlow



-- Helper to create count text (stacks/charges)
local function CreateCountText(icon)
    if icon.count then return end
    -- Match Blizzard ActionButton.Count exactly:
    --   Font:     NumberFontNormal (ActionButton.lua layout template)
    --   Position: BOTTOMRIGHT -3, 1  (ActionButton.lua:1633-1634)
    local count = icon:CreateFontString(nil, "OVERLAY")
    if NumberFontNormal then
        count:SetFontObject(NumberFontNormal)
    else
        -- Fallback if NumberFontNormal unavailable
        count:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    end
    count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -3, 1)
    count:SetJustifyH("RIGHT")
    icon.count = count
end


-- Helper to update count text value.
-- Mirrors Blizzard's CooldownViewer (CooldownViewer.lua:1057) and ActionButton (ActionButton.lua:809):
-- pass the count value directly to SetText — NEVER compare it in Lua when it may be secret.
local function UpdateCountText(icon, displayStr)
    if not icon.count then CreateCountText(icon) end

    if issecretvalue(displayStr) then
        -- Secret value (M+ cooldown-restricted): SafeSetText handles the
        -- LuaDurationObject transparently without triggering taint on comparison.
        sfui.common.SafeSetText(icon.count, displayStr, 0)
        icon.count:Show()
    else
        -- Non-secret: safe to branch. Convert to string for uniform dirty-check.
        -- "" or "0" hides the badge (no display count, or items with stack=0).
        local str = (displayStr ~= nil and displayStr ~= 0) and sfui.common.get_cached_int_string(displayStr) or ""
        if str ~= "" and str ~= "0" then
            if icon._lastCount ~= str then
                icon._lastCount = str
                icon.count:SetText(str)
            end
            icon.count:Show()
        else
            if icon._lastCount ~= nil then icon._lastCount = nil end
            icon.count:Hide()
        end
    end
end

-- IsDragonriding: use sfui.common.IsDragonriding() (single source of truth)

-- Lightweight cooldown logic:
--   • SetCooldown() accepts secret values natively (C++ level)
--   • isOnGCD is NeverSecret — always safe to branch on
local scratchParent = CreateFrame("Frame")
scratchParent:Hide()
local scratchCooldown = CreateFrame("Cooldown", nil, scratchParent, "CooldownFrameTemplate")

local function IsFallbackNeeded(val)
    -- Secret values can sometimes be "secret strings" in 11.0.
    -- issecretvalue provides the official C++ level check. If it is secret,
    -- it is a valid value, not an empty string, and must not be compared.
    if issecretvalue(val) then return false end
    return val == ""
end

local function UpdateIconCooldown(icon, activeID, resolvedType)
    -- count starts as "" for spells (GetSpellDisplayCount returns "") and as 0
    -- for items (GetItemCount returns a number). Use type-appropriate default.
    local count = (resolvedType == "item") and 0 or ""
    local isEnabled = true
    local isUsable, notEnoughPower = true, false
    local isOnCooldown = false

    if resolvedType == "item" then
        local countVal = update_item_cd(icon)
        count = countVal or 0
        isEnabled = icon._isEnabled
        local d = icon._duration
        if d ~= nil and d > 0 then isOnCooldown = true end
    else
        -- Spell: officially supports tainted spellIdentifiers
        local cdInfo = C_Spell.GetSpellCooldown(activeID)

        if cdInfo ~= nil then
            -- 12.0.1 Hotfix: 'SetCooldown' no longer legally accepts Secret Values.
            -- Addons MUST acquire a DurationObject and pass it to 'SetCooldownFromDurationObject'.
            if icon.cooldown.SetCooldownFromDurationObject and C_Spell.GetSpellCooldownDuration then
                -- ignoreGCD=true (12.0.5+): skip GCD-only cooldowns to avoid phantom swipe
                local durationObj = C_Spell.GetSpellCooldownDuration(activeID, true)
                if durationObj then
                    icon.cooldown:SetCooldownFromDurationObject(durationObj)
                    if icon.shadowCooldown then
                        icon.shadowCooldown:SetCooldownFromDurationObject(durationObj)
                    end
                else
                    icon.cooldown:Clear()
                    if icon.shadowCooldown then icon.shadowCooldown:Clear() end
                end
            else
                -- Pre-12.0.1 Legacy Fallback
                local isEnabled = cdInfo.isEnabled
                if isEnabled == nil then isEnabled = true end
                
                if not (issecretvalue and (issecretvalue(cdInfo.startTime) or issecretvalue(cdInfo.duration))) then
                    icon.cooldown:SetCooldown(cdInfo.startTime, cdInfo.duration)
                    if icon.shadowCooldown then
                        icon.shadowCooldown:SetCooldown(cdInfo.startTime, cdInfo.duration)
                    end
                else
                    icon.cooldown:Clear()
                    if icon.shadowCooldown then icon.shadowCooldown:Clear() end
                end
            end

            -- cdInfo.isActive and cdInfo.isOnGCD are designated "NeverSecret=true" in 12.0.1.
            local isActive = cdInfo.isActive
            local isOnGCD = cdInfo.isOnGCD
            
            -- If it's active but it's ONLY a GCD, we treat it as not on cooldown and wipe it.
            if isActive and not isOnGCD then
                isOnCooldown = true
                icon._secretGCDDropTime = nil
            elseif isOnGCD then
                -- It's solely the GCD. Hide the visual swipe.
                isOnCooldown = false
                icon._secretGCDDropTime = nil
                icon.cooldown:Clear()
                if icon.shadowCooldown then icon.shadowCooldown:Clear() end
            else
                -- Not active at all
                isOnCooldown = false
                icon._secretGCDDropTime = nil
            end

            -- isEnabled is NeverSecret
            local en = cdInfo.isEnabled
            if en == false then
                isEnabled = false
            else
                isEnabled = true
            end
        else
            icon.cooldown:Clear()
            if icon.shadowCooldown then icon.shadowCooldown:Clear() end
        end

        local displayStr = ""
        
        -- 1. Try GetSpellDisplayCount (Actionbar native representation & Soul Fragments)
        if C_Spell.GetSpellDisplayCount then
            local dc = C_Spell.GetSpellDisplayCount(activeID)
            if dc ~= nil then
                displayStr = dc
            end
        end

        -- 2. Try SpellChargeInfo (CooldownViewer priority for >1 charge spells)
        if IsFallbackNeeded(displayStr) and C_Spell.GetSpellCharges then
            local ch = C_Spell.GetSpellCharges(activeID)
            if ch and ch.currentCharges and sfui.common.SafeGT(ch.maxCharges, 1) then
                displayStr = ch.currentCharges or ""
            end
        end

        -- 3. Try GetSpellCastCount (CooldownViewer fallback)
        if IsFallbackNeeded(displayStr) and C_Spell.GetSpellCastCount then
            local cc = C_Spell.GetSpellCastCount(activeID)
            if cc ~= nil then
                if issecretvalue(cc) then
                    displayStr = cc
                elseif type(cc) == "number" and cc > 0 then
                    displayStr = cc
                end
            end
        end

        count = displayStr  -- passed to UpdateCountText; never compared in Lua
    end

    -- Glow arming
    if icon._wasOnCooldown and not isOnCooldown then
        icon._pendingGlow = true
    end
    icon._wasOnCooldown = isOnCooldown

    -- Usability: supports tainted activeID
    if icon.type ~= "item" then
        if C_Spell and C_Spell.IsSpellUsable then
            local u, p = C_Spell.IsSpellUsable(activeID)
            isUsable = sfui.common.SafeValue(u, true)
            notEnoughPower = sfui.common.SafeValue(p, false)
        end
        if not HasFullControl() and not isUsable then isUsable = true end
    end

    -- Readiness: use only NeverSecret fields for branching.
    -- cdInfo.isActive (= isOnCooldown) already correctly handles charge-based spells:
    -- when a spell has multiple charges and at least one is available, isActive=false
    -- so isOnCooldown=false and the spell is considered ready naturally.
    -- GetSpellCastCount/GetSpellCharges are SecretWhenSpellCooldownRestricted in M+
    -- and must NOT be compared in Lua.
    local isReady
    if icon.type == "item" then
        isReady = not isOnCooldown and (isEnabled ~= false)
    else
        isReady = not isOnCooldown and (isEnabled ~= false) and isUsable
    end

    return count, isReady, isUsable, notEnoughPower, isOnCooldown
end

-- Visuals: desaturation, alpha, resource tint
local function UpdateIconVisuals(icon, entrySettings, panelConfig, isUsable, isOnCooldown, notEnoughPower)
    if not icon.texture then return end

    -- Unusable usually means genuinely invalid (wrong stance, dead)
    -- Lacking power (Rage/Energy) sets notEnoughPower, so we spare it from full grey-out/dim.
    local actuallyUnusable = (not isUsable) and not notEnoughPower

    -- Desaturate during cooldowns OR when genuinely unusable
    local useDesat = GetIconValue(entrySettings, panelConfig, "cooldownDesat", true)
    local desaturate = (useDesat and isOnCooldown) or actuallyUnusable
    if icon._currentDesaturated ~= desaturate then
        icon.texture:SetDesaturated(desaturate)
        icon._currentDesaturated = desaturate
    end

    -- Alpha: dim during cooldowns OR when genuinely unusable
    local baseAlpha = actuallyUnusable and 0.5 or 1.0
    local alpha = isOnCooldown and GetIconValue(entrySettings, panelConfig, "alphaOnCooldown", 0.5) or baseAlpha
    if icon._currentAlpha ~= alpha then
        icon:SetAlpha(alpha)
        icon._currentAlpha = alpha
    end

    -- Resource check: blue tint when out of power
    local useResourceCheck = GetIconValue(entrySettings, panelConfig, "useResourceCheck", true)
    local targetColor = (notEnoughPower and useResourceCheck) and "blue" or "white"
    if icon._currentVertexColor ~= targetColor then
        if targetColor == "blue" then
            icon.texture:SetVertexColor(0.5, 0.5, 1.0)
        else
            local textColor = GetIconValue(entrySettings, panelConfig, "textColor", _defaultTextColor)
            if type(textColor) == "table" then
                icon.texture:SetVertexColor(textColor[1] or 1, textColor[2] or 1, textColor[3] or 1)
            else
                icon.texture:SetVertexColor(1, 1, 1)
            end
        end
        icon._currentVertexColor = targetColor
    end
end

-- Helper: Update Glows
local function UpdateIconGlow(icon, entrySettings, panelConfig, isReady)
    local showGlow = GetIconValue(entrySettings, panelConfig, "readyGlow", true)

    -- Glow Logic (Permanent while ready)
    -- Logic:
    -- 1. Trigger if _pendingGlow is set (armed by previous valid cooldown)
    -- 2. Sustain if already active (and duration not exceeded)

    local shouldGlow = false
    if isReady and showGlow then
        if icon._pendingGlow then
            -- Trigger!
            shouldGlow = true
            icon._pendingGlow = false       -- Consume the trigger
            icon._glowStartTime = GetTime() -- Reset timer for new glow
        elseif icon._glowActive then
            -- Sustain
            shouldGlow = true
        end
    end

    if shouldGlow then
        -- Check if glow has been active for too long
        local maxDuration = GetIconValue(entrySettings, panelConfig, "glow_max_duration", 5.0)
        local now = GetTime()

        if not icon._glowStartTime then
            icon._glowStartTime = now
        end

        local elapsed = now - icon._glowStartTime

        if elapsed < maxDuration then
            -- Resolve glow configuration (Shared central logic)
            sfui.glows.resolve_config(entrySettings, panelConfig, _tempGlowCfg)
            local glowType = _tempGlowCfg.glowType

            local needsRestart = false
            if not icon._glowActive then
                needsRestart = true
            elseif icon._lastGlowType ~= glowType then
                needsRestart = true
            else
                local prev = icon._lastGlowCfg
                if prev and prev.glowColor and _tempGlowCfg.glowColor then
                    if math.abs(prev.glowColor[1] - _tempGlowCfg.glowColor[1]) > 0.01 or
                        math.abs(prev.glowColor[2] - _tempGlowCfg.glowColor[2]) > 0.01 or
                        math.abs(prev.glowColor[3] - _tempGlowCfg.glowColor[3]) > 0.01 or
                        math.abs(prev.glowScale - _tempGlowCfg.glowScale) > 0.01 or
                        math.abs(prev.glowIntensity - _tempGlowCfg.glowIntensity) > 0.01 or
                        math.abs(prev.glowSpeed - _tempGlowCfg.glowSpeed) > 0.01 or
                        math.abs((prev.glowLines or 8) - _tempGlowCfg.glowLines) > 0.01 or
                        math.abs((prev.glowThickness or 2) - _tempGlowCfg.glowThickness) > 0.01 or
                        math.abs((prev.glowParticles or 4) - _tempGlowCfg.glowParticles) > 0.01 then
                        needsRestart = true
                    end
                end
            end

            if needsRestart then
                if icon._glowActive then StopGlow(icon) end
                StartGlow(icon, _tempGlowCfg)
            end
        else
            -- Duration exceeded - stop glow (keep timer to prevent restart)
            if icon._glowActive then
                StopGlow(icon)
            end
        end
    else
        -- Reset start time when not ready (ensures it triggers fresh next time)
        icon._glowStartTime = nil
        if icon._glowActive then
            StopGlow(icon)
        end
    end
end

local _cdInfoCache = {}
local _cdInfoCacheCount = 0

local function SafeGetCooldownViewerCooldownInfo(id)
    if not id or not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then return nil end
    local cid = tonumber(id)
    if cid and cid >= -2147483648 and cid <= 2147483647 then
        if not _cdInfoCache[cid] then
            _cdInfoCacheCount = _cdInfoCacheCount + 1
            -- Wipe cache if it grows too large (e.g. 500 entries)
            if _cdInfoCacheCount > 500 then
                wipe(_cdInfoCache)
                _cdInfoCacheCount = 1
            end
            local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cid)
            _cdInfoCache[cid] = info or false
        end
        return _cdInfoCache[cid] or nil
    end
    return nil
end

-- Helper to update icon state (visibility, cooldown, charges)
local function UpdateIconState(icon, panelConfig)
    if not icon.id or not icon.entry then return false end
    local entrySettings = icon.entry.settings or _emptyTable

    local activeID = icon._lastActiveID or icon.id
    local resolvedType = icon._resolvedType or icon.type
    local linkedSpellIDs = icon._linkedSpellIDs

    -- If not resolved yet (e.g. fresh icon), resolve once
    if not icon._lastActiveID then
        local iconTexture, aID, rType, lIDs = sfui.trackedicons.GetIconTexture(icon.id, icon.type, icon.entry)
        activeID = aID or icon.id
        resolvedType = rType or icon.type
        linkedSpellIDs = lIDs
        icon._lastActiveID = activeID
        icon._resolvedType = resolvedType
        icon._linkedSpellIDs = linkedSpellIDs
        if icon.texture and iconTexture and icon._currentTexture ~= iconTexture then
            icon.texture:SetTexture(iconTexture)
            icon._currentTexture = iconTexture
        end
    end

    -- 3. Update Cooldown & Logic
    local count, isReady, isUsable, notEnoughPower, isOnCooldown = UpdateIconCooldown(icon, activeID, resolvedType)

    -- 4. Visibility Decision
    local shouldShow = true

    -- Visibility overrides
    local hideOOC = GetIconValue(nil, panelConfig, "hideOOC", false)
    local hideMounted = GetIconValue(nil, panelConfig, "hideMounted", false)
    local hideInVehicle = GetIconValue(nil, panelConfig, "hideInVehicle", true)

    if hideOOC and not InCombatLockdown() then shouldShow = false end
    if hideMounted and sfui.common.is_mounted_or_travel_form() then shouldShow = false end
    if hideInVehicle and (UnitHasVehicleUI("player") or UnitInVehicle("player")) then shouldShow = false end

    if panelConfig then
        -- Legacy dropdown support (optional/fallback)
        if panelConfig.visibility == "combat" and not InCombatLockdown() then shouldShow = false end
        if panelConfig.visibility == "noCombat" and InCombatLockdown() then shouldShow = false end
    end

    local isVisible = shouldShow -- In simple panel mode, all icons are visible holders

    if isVisible then
        if not icon:IsShown() then
            -- Non-protected frames can Show() freely during combat
            icon:Show()
        end

        -- Update Count Text.
        local displayCount = count
        local isAuraType = (icon.type == "buff" or icon.type == "debuff" or (icon.entry and (icon.entry.type == "buff" or icon.entry.type == "debuff")))
        if (isAuraType or linkedSpellIDs) and icon.type ~= "item" and activeID and activeID ~= 0 and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
            local aura = nil
            if isAuraType then
                local baseAura = C_UnitAuras.GetPlayerAuraBySpellID(activeID)
                if baseAura then
                    aura = baseAura
                end
            end

            if not aura and linkedSpellIDs then
                -- Try resolving linked auras (e.g., Marrowrend tracking -> Bone Shield aura)
                for _, linkedID in ipairs(linkedSpellIDs) do
                    local linkedAura = C_UnitAuras.GetPlayerAuraBySpellID(linkedID)
                    if linkedAura then
                        aura = linkedAura
                        break
                    end
                end
            end

            if aura and aura.applications and (issecretvalue(aura.applications) or (type(aura.applications) == "number" and aura.applications > 1)) then
                displayCount = aura.applications
            end
        end
        UpdateCountText(icon, displayCount)

        -- Visibility / Settings check
        icon.cooldown:SetHideCountdownNumbers(not GetIconValue(entrySettings, panelConfig, "textEnabled", true))

        -- 5. Update Visuals
        UpdateIconVisuals(icon, entrySettings, panelConfig, isUsable, isOnCooldown, notEnoughPower)

        -- 6. Update Glows
        UpdateIconGlow(icon, entrySettings, panelConfig, isReady)
    else
        -- Icon is not visible - hide it
        icon:Hide()
        if icon._glowActive then
            StopGlow(icon)
        end
    end

    return isVisible
end

-- Shared Helper for Texture Resolution
function sfui.trackedicons.GetIconTexture(id, type, entry)
    local activeID = id
    local iconTexture
    local resolvedType = type
    local linkedSpellIDs = nil

    if type == "cooldown" and entry and entry.cooldownID then
        -- Get cooldown info from Blizzard's CDM
        local cdInfo = SafeGetCooldownViewerCooldownInfo(entry.cooldownID)
        if cdInfo then
            linkedSpellIDs = cdInfo.linkedSpellIDs
            if cdInfo.spellID and cdInfo.spellID > 0 then
                activeID = cdInfo.overrideSpellID or cdInfo.spellID
                iconTexture = C_Spell.GetSpellTexture(activeID)
                resolvedType = "spell"
            elseif cdInfo.itemID and cdInfo.itemID > 0 then
                activeID = cdInfo.itemID
                iconTexture = C_Item.GetItemIconByID(activeID)
                resolvedType = "item"
            end
        else
            -- Fallback if cooldown no longer exists
            activeID = entry.spellID or id
            iconTexture = C_Spell.GetSpellTexture(activeID)
            resolvedType = "spell"
        end
    elseif type == "item" then
        iconTexture = C_Item.GetItemIconByID(activeID)
        resolvedType = "item"
    else
        -- Smart Detection: if it's a simple ID, check if it exists in CooldownViewer categories
        local cdInfo = SafeGetCooldownViewerCooldownInfo(activeID)
        if cdInfo then
            if cdInfo.spellID and cdInfo.spellID > 0 then
                activeID = cdInfo.overrideSpellID or cdInfo.spellID
                iconTexture = C_Spell.GetSpellTexture(activeID)
                resolvedType = "spell"
            elseif cdInfo.itemID and cdInfo.itemID > 0 then
                activeID = cdInfo.itemID
                iconTexture = C_Item.GetItemIconByID(activeID)
                resolvedType = "item"
            end
        else
            iconTexture = C_Spell.GetSpellTexture(activeID)
            resolvedType = "spell"
            if not iconTexture then
                iconTexture = C_Item.GetItemIconByID(activeID)
                resolvedType = "item"
            end
        end
    end

    return iconTexture, activeID, resolvedType, linkedSpellIDs
end

-- Apply square icon + border style from config
function sfui.trackedicons.ApplyIconBorderStyle(icon, panelConfig)
    if not icon or not icon.texture then return end

    if icon._isMasqued then
        if icon.borderBackdrop then icon.borderBackdrop:Hide() end
        return
    end

    local showBorder = GetIconValue(nil, panelConfig, "showBorder", false)
    local squareIcons = GetIconValue(nil, panelConfig, "squareIcons", false)

    if icon._lastShowBorder == showBorder and icon._lastSquareIcons == squareIcons then
        return
    end
    icon._lastShowBorder = showBorder
    icon._lastSquareIcons = squareIcons

    -- TexCoord: square crops the round WoW icon edges
    if squareIcons then
        icon.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    else
        icon.texture:SetTexCoord(0, 1, 0, 1)
    end

    -- Border backdrop (2px black behind icon)
    if icon.borderBackdrop then
        if showBorder then
            icon.borderBackdrop:Show()
            icon.texture:ClearAllPoints()
            icon.texture:SetPoint("TOPLEFT", icon, "TOPLEFT", 2, -2)
            icon.texture:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -2, 2)
        else
            icon.borderBackdrop:Hide()
            icon.texture:ClearAllPoints()
            icon.texture:SetAllPoints()
        end

        -- Explicitly re-anchor cooldowns whenever we shift the primary texture,
        -- otherwise CooldownFrames bleed out beyond borders when layout updates.
        if icon.cooldown then
            icon.cooldown:ClearAllPoints()
            icon.cooldown:SetAllPoints(icon.texture)
        end
        if icon.shadowCooldown then
            icon.shadowCooldown:ClearAllPoints()
            icon.shadowCooldown:SetAllPoints(icon.texture)
        end
    end
end



-- Shared Helper for Masque Sync
local function SyncIconMasque(icon)
    sfui.common.sync_masque(icon, { Icon = icon.texture, Cooldown = icon.cooldown })
end

-- Create a single icon frame (Standard Button for Taint Isolation)
local function CreateIconFrame(parent, id, entry, panelConfig)
    -- Normalize numeric entry (from new CDM) to table
    if type(entry) == "number" then
        entry = { id = entry, type = "spell" }
    end

    _iconCounter = _iconCounter + 1
    local name = "SfuiIcon" .. _iconCounter
    local f = CreateFrame("Button", name, parent)
    local initialSize = 40
    if panelConfig then
        initialSize = tonumber(panelConfig.size) or 40
    end
    f:SetSize(initialSize, initialSize)

    -- Border backdrop (black 2px behind icon, controlled by showBorder config)
    f.borderBackdrop = f:CreateTexture(nil, "BACKGROUND")
    f.borderBackdrop:SetAllPoints()
    f.borderBackdrop:SetColorTexture(0, 0, 0, 1)
    f.borderBackdrop:Hide() -- Hidden by default, shown via ApplyIconBorderStyle

    -- Icon Texture
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    f.texture = tex

    local iconTexture = sfui.trackedicons.GetIconTexture(id, entry.type, entry)
    tex:SetTexture(iconTexture or 134400)

    -- Apply initial border/square style
    sfui.trackedicons.ApplyIconBorderStyle(f, panelConfig)

    -- Main Cooldown Frame (Blizzard Native Countdown)
    local cd = CreateFrame("Cooldown", name .. "_CD", f, "CooldownFrameTemplate")
    cd:SetAllPoints(tex)
    cd:SetDrawEdge(true)
    cd:SetHideCountdownNumbers(false) -- SHOW NATIVE COUNTDOWN
    f.cooldown = cd

    -- Shadow Cooldown Frame (Invisible, drives desaturation safely)
    local shadow = CreateFrame("Cooldown", name .. "_ShadowCD", f, "CooldownFrameTemplate")
    shadow:SetAllPoints(tex)
    shadow:SetDrawSwipe(false)
    shadow:SetDrawEdge(false)
    shadow:SetDrawBling(false)
    shadow:SetHideCountdownNumbers(true)
    shadow:SetAlpha(0)
    f.shadowCooldown = shadow

    -- Main cooldown frames handle countdown numbers natively



    -- Border/Overlay (optional visual polish)
    f.PushedTexture = f:CreateTexture(nil, "OVERLAY")
    f.PushedTexture:SetTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    f.PushedTexture:SetAllPoints()
    f:SetPushedTexture(f.PushedTexture)

    f.HighlightTexture = f:CreateTexture(nil, "HIGHLIGHT")
    f.HighlightTexture:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    f.HighlightTexture:SetAllPoints()
    f:SetHighlightTexture(f.HighlightTexture)

    f.id = id
    f.entry = entry

    -- DO NOT register for clicks - this makes frames "protected" and causes combat taint
    -- User doesn't need clickable icons, just visibility and cooldown tracking
    -- Tooltips still work via OnEnter/OnLeave scripts below

    f:SetScript("OnEnter", function(self)
        local showTooltips = GetIconValue(self.entry.settings, panelConfig, "showTooltips", false)
        if showTooltips and GameTooltip and self.id and not issecretvalue(self.id) then
            GameTooltip:SetOwner(self:GetParent(), "ANCHOR_RIGHT")
            if self.entry.type == "item" then
                GameTooltip:SetItemByID(self.id)
            else
                GameTooltip:SetSpellByID(self.id)
            end
            GameTooltip:Show()
        end
    end)
    f:SetScript("OnLeave", function(self)
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- Initial State: Show immediately
    -- Non-protected frames can be shown/hidden freely even during combat
    f:SetScript("OnUpdate", nil)

    local msq = sfui.common.get_masque_group()
    if msq then
        msq:AddButton(f, { Icon = tex, Cooldown = cd })
        f._isMasqued = true
    end

    return f
end

local function CheckPanelVisibility(panelConfig, event)
    if not panelConfig or not panelConfig.enabled then return false end

    -- Helper: Robust Combat Status
    local inCombat = InCombatLockdown()
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
    end

    -- OVERRIDE: Always show if Options Panel is open on relevant tabs
    if _G["SfuiCooldownsViewer"] and _G["SfuiCooldownsViewer"]:IsShown() then
        local tabId = _G["SfuiCooldownsViewer"].selectedTabId
        if tabId == 1 or tabId == 3 then
            return true
        end
    end

    -- 1. Per-Panel Conditionals (Using GetIconValue for nested/global inheritance)
    -- Hide if Out of Combat enabled
    if GetIconValue(nil, panelConfig, "hideOOC", false) and not inCombat then return false end

    -- Priority: Combat status always overrides mount/vehicle hide conditions
    if not inCombat then
        -- Hide while Mounted enabled
        if GetIconValue(nil, panelConfig, "hideMounted", false) and sfui.common.is_mounted_or_travel_form() then return false end
        -- Hide while in Vehicle UI enabled
        if GetIconValue(nil, panelConfig, "hideInVehicle", true) and (UnitHasVehicleUI("player") or UnitInVehicle("player")) then return false end
    end

    -- 2. Global Visibility Settings
    local globalVis = SfuiDB and SfuiDB.iconGlobalSettings
    if globalVis then
        -- Legacy Global Hide OOC
        if globalVis.hideOOC and not inCombat then return false end
        -- Dragonriding
        if globalVis.hideDragonriding and sfui.common.IsDragonriding() and not inCombat then return false end
    end

    -- 3. Visibility Mode (Dropdown Toggle: Always, Combat, NoCombat)
    local visMode = panelConfig.visibility
    if not visMode and globalVis then visMode = globalVis.visibility end
    visMode = visMode or "always"

    if visMode == "combat" then
        if not inCombat then return false end
    elseif visMode == "noCombat" then
        if inCombat then return false end
    end

    return true
end

-- Visibility Event Handler (Triggered centrally now)
function sfui.trackedicons.OnVisibilityEvent(_, event)
    for _, panelFrame in pairs(panels) do
        if panelFrame.config then
            local shouldShow = CheckPanelVisibility(panelFrame.config, event)
            if shouldShow then
                if not panelFrame:IsShown() then panelFrame:Show() end
            else
                if panelFrame:IsShown() then panelFrame:Hide() end
            end
        end
    end
end

-- Helper: Apply Auto-Span Logic to fit width
local function ApplyAutoSpan(panelConfig, activeIcons, size, spacing, numColumns, growthH, targetFrame)
    local spanWidth = GetIconValue(nil, panelConfig, "spanWidth", false)
    if spanWidth and #activeIcons > 0 then
        local targetWidth = 300
        if targetFrame and targetFrame.GetWidth then
            targetWidth = targetFrame:GetWidth()
        elseif _G["sfui_bar0_Backdrop"] then
            targetWidth = _G["sfui_bar0_Backdrop"]:GetWidth()
        end

        local iconsPerRow = math.min(numColumns, #activeIcons)
        if iconsPerRow <= 0 then return size, spacing end

        -- Calculate current width with configured size/spacing
        local currentWidth = (iconsPerRow * size) + (math.max(0, iconsPerRow - 1) * spacing)

        if currentWidth < targetWidth then
            -- Expand spacing to fill width
            if iconsPerRow > 1 then
                spacing = (targetWidth - (iconsPerRow * size)) / (iconsPerRow - 1)
            end
        else
            -- Shrink size to fit width (keeping spacing fixed)
            local newSize = (targetWidth - (math.max(0, iconsPerRow - 1) * spacing)) / iconsPerRow
            if newSize < 10 then newSize = 10 end -- Hard min size
            size = newSize
        end
    end
    return size, spacing
end

function sfui.trackedicons.UpdatePanelLayout(panelFrame, panelConfig)
    if not panelFrame or not panelConfig then return end
    panelFrame.config = panelConfig


    -- Register Event-Driven Visibility Handlers (once central hook)
    if not sfui.trackedicons._eventsRegistered then
        sfui.trackedicons._eventsRegistered = true
        sfui.events.RegisterEvent("PLAYER_REGEN_DISABLED",
            function(...) sfui.trackedicons.OnVisibilityEvent(nil, "PLAYER_REGEN_DISABLED", ...) end)
        sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED",
            function(...) sfui.trackedicons.OnVisibilityEvent(nil, "PLAYER_REGEN_ENABLED", ...) end)
        sfui.events.RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED",
            function(...) sfui.trackedicons.OnVisibilityEvent(nil, "PLAYER_MOUNT_DISPLAY_CHANGED", ...) end)
        sfui.events.RegisterUnitEvent("UNIT_POWER_BAR_SHOW", "player",
            function(...) sfui.trackedicons.OnVisibilityEvent(nil, "UNIT_POWER_BAR_SHOW", ...) end)
        sfui.events.RegisterUnitEvent("UNIT_POWER_BAR_HIDE", "player",
            function(...) sfui.trackedicons.OnVisibilityEvent(nil, "UNIT_POWER_BAR_HIDE", ...) end)
    end



    -- Trigger initial visibility check IMMEDIATELY
    if panelFrame.visHandler then
        local onEvent = panelFrame.visHandler:GetScript("OnEvent")
        if onEvent then onEvent(panelFrame.visHandler) end
    end



    -- Ensure panel position is updated from Config with Dynamic Anchoring
    panelFrame:ClearAllPoints()

    local anchorTo = panelConfig.anchorTo or "UIParent"
    local targetFrame = UIParent
    local targetPoint = "BOTTOM"
    local anchorPoint = panelConfig.anchorPoint or "BOTTOM"

    if anchorTo == "Health Bar" and _G["sfui_bar0_Backdrop"] then
        targetFrame = _G["sfui_bar0_Backdrop"]
        targetPoint = "BOTTOM"
        anchorPoint = "TOP"

        -- Smart Anchoring: Check if Power Bar (bar_minus_1) EXISTS and IS SHOWN
        local powerBar = _G["sfui_bar-1_Backdrop"] or _G["sfui_bar_minus_1_Backdrop"]
        if powerBar and powerBar:IsShown() then
            targetFrame = powerBar
            targetPoint = "BOTTOM"
        end
    elseif anchorTo == "Tracked Bars" and _G["SfuiTrackedBarsContainer"] then
        targetFrame = _G["SfuiTrackedBarsContainer"]
        targetPoint = "TOP"
        anchorPoint = "BOTTOM"
    elseif anchorTo ~= "UIParent" then
        -- Dynamic Anchor Resolution:
        -- If we are anchoring to "CENTER" and it is hidden, we search for a "replacement" panel
        -- (usually CAT, BEAR, STEALTH etc) that is currently visible.
        local searchTarget = anchorTo
        local resolvedTarget = nil

        -- Initial search for the specific named target
        for _, otherPanel in pairs(panels) do
            if otherPanel.config and otherPanel.config.name == searchTarget then
                if otherPanel:IsShown() then
                    resolvedTarget = otherPanel
                    break
                else
                    -- Target found but hidden. If it's "CENTER", we look for any visible
                    -- "center-style" panel (one that anchors to Health Bar).
                    if searchTarget == "CENTER" then
                        for _, p in pairs(panels) do
                            if p:IsShown() and p.config and p.config.anchorTo == "Health Bar" then
                                resolvedTarget = p
                                break
                            end
                        end
                    end
                end
            end
        end

        if resolvedTarget and resolvedTarget ~= panelFrame then
            targetFrame = resolvedTarget
            targetPoint = "BOTTOM"
            anchorPoint = "TOP"
        else
            -- Fallback or static search if dynamic resolution failed or wasn't "CENTER"
            for _, otherPanel in pairs(panels) do
                if otherPanel.config and otherPanel.config.name == anchorTo then
                    -- SAFETY: Ensure we are not anchoring to ourselves
                    if otherPanel ~= panelFrame then
                        targetFrame = otherPanel
                        targetPoint = "BOTTOM"
                        anchorPoint = "TOP"
                    else
                        -- Fallback to UIParent if self-anchoring detected
                        targetFrame = UIParent
                        targetPoint = "BOTTOM"
                        anchorPoint = "BOTTOM"
                    end
                    break
                end
            end
        end
    end

    -- Default local anchor for icon placement relative to panel
    local anchor = anchorPoint
    panelFrame:SetPoint(anchorPoint, targetFrame, targetPoint, panelConfig.x or 0, panelConfig.y or 0)

    -- Hide all icons first (full redraw of state)
    -- Non-protected frames can be manipulated freely during combat
    if panelFrame.icons then
        for _, icon in pairs(panelFrame.icons) do
            if icon._glowActive then StopGlow(icon) end
            icon:Hide()
            icon:ClearAllPoints()
        end
    else
        panelFrame.icons = {}
    end

    local activeIcons = _staticActiveIcons
    wipe(activeIcons)
    local entries = sfui.common.get_active_panel_entries(panelConfig, _staticActiveEntries)

    for i, entry in ipairs(entries) do
        -- Handle both new simple numeric IDs and legacy table entries
        local id = (type(entry) == "table" and entry.id) or entry
        if id then
            if not panelFrame.icons[i] then
                panelFrame.icons[i] = CreateIconFrame(panelFrame, id, entry, panelConfig)
            end

            local icon = panelFrame.icons[i]
            if icon then
                -- Update attributes (safe out of combat)
                icon.id = id
                if type(entry) == "table" then
                    icon.type = entry.type
                    icon.entry = entry
                else
                    icon.type = "spell" -- Default for simple IDs
                    icon.entry = { id = id, type = "spell" }
                end

                local iconTexture, activeID, resolvedType, linkedSpellIDs = sfui.trackedicons.GetIconTexture(id, icon.type, icon.entry)
                icon._lastActiveID = activeID or id
                icon._resolvedType = resolvedType or icon.type
                icon._linkedSpellIDs = linkedSpellIDs
                if icon.texture and iconTexture then
                    if icon._currentTexture ~= iconTexture then
                        icon.texture:SetTexture(iconTexture)
                        icon._currentTexture = iconTexture
                    end
                end
                sfui.trackedicons.ApplyIconBorderStyle(icon, panelConfig)

                -- Sync Masque state
                SyncIconMasque(icon)
                UpdateIconState(icon, panelConfig)
                table.insert(activeIcons, icon)
            end
        end
    end

    -- Cleanup stale icons (from previous specs/layouts) that exceed the current entry count
    -- CRITICAL MEMORY OPTIMIZATION: Do not set panelFrame.icons[x] to nil, or we permanently
    -- leak frames on every resize. Hide them and wipe references, keeping them pooled for reuse.
    if panelFrame.icons then
        for x = #entries + 1, #panelFrame.icons do
            local oldIcon = panelFrame.icons[x]
            if oldIcon then
                if oldIcon._glowActive then StopGlow(oldIcon) end
                oldIcon:Hide()
                oldIcon.id = nil
                oldIcon.entry = nil
            end
        end
    end

    -- Layout Active Icons
    local numColumns = panelConfig.columns or #activeIcons
    if numColumns < 1 then numColumns = 1 end

    -- Force Single Row ONLY for the main CENTER panel
    if panelConfig.name == "CENTER" then
        numColumns = #activeIcons
    end

    local growthH = panelConfig.growthH or "Right"
    local growthV = panelConfig.growthV or "Down"
    local hSign = (growthH == "Left") and -1 or 1
    local vSign = (growthV == "Up") and 1 or -1

    -- Ensure spacing is a number and size is a number
    local size = GetIconValue(nil, panelConfig, "size", 40)
    local spacing = GetIconValue(nil, panelConfig, "spacing", 2)
    size = tonumber(size) or 40
    spacing = tonumber(spacing) or 2

    local maxWidth, maxHeight = 0, 0

    -- Auto-Span Width Logic
    size, spacing = ApplyAutoSpan(panelConfig, activeIcons, size, spacing, numColumns, growthH, targetFrame)

    -- Layout icons based on growth mode
    -- Non-protected frames can be positioned freely even during combat
    if growthH == "Center" then
        local totalIcons = #activeIcons
        for i, icon in ipairs(activeIcons) do
            icon:ClearAllPoints()
            icon:SetSize(size, size)

            local row = math.floor((i - 1) / numColumns)
            local colInRow = (i - 1) % numColumns

            -- Calculate icons in this specific row for centering
            local startIdx = row * numColumns + 1
            local endIdx = math.min((row + 1) * numColumns, totalIcons)
            local numInRow = endIdx - startIdx + 1

            local centerOffset = colInRow - (numInRow - 1) / 2
            local ox = centerOffset * (size + spacing)
            local oy = row * (size + spacing) * vSign

            -- Centered icons always use the panel's main anchor point as their 0,0 reference
            icon:SetPoint(anchor, panelFrame, anchor, ox, oy)

            local rowWidth = numInRow * size + math.max(0, numInRow - 1) * spacing
            maxWidth = math.max(maxWidth, rowWidth)
            maxHeight = math.max(maxHeight, (row + 1) * (size + spacing) - spacing)
        end
    else
        -- Standard growth
        for idx, icon in ipairs(activeIcons) do
            icon:ClearAllPoints()
            icon:SetSize(size, size)

            local col = (idx - 1) % numColumns
            local row = math.floor((idx - 1) / numColumns)

            local ox = col * (size + spacing) * hSign
            local oy = row * (size + spacing) * vSign

            icon:SetPoint(anchor, panelFrame, anchor, ox, oy)

            maxWidth = math.max(maxWidth, (col + 1) * size + col * spacing)
            maxHeight = math.max(maxHeight, (row + 1) * size + row * spacing)
        end
    end

    -- Background Frame Logic (Universal for all panels)
    local showBG = GetIconValue(nil, panelConfig, "showBackground", true)
    local bgAlpha = GetIconValue(nil, panelConfig, "backgroundAlpha", 0.5)

    local anyVisible = false
    for _, icon in ipairs(activeIcons) do
        if icon:IsShown() then
            anyVisible = true
            break
        end
    end

    if showBG and anyVisible then
        if not panelFrame.bg then
            panelFrame.bg = CreateFrame("Frame", nil, panelFrame, "BackdropTemplate")
            panelFrame.bg:SetFrameStrata("BACKGROUND")
            panelFrame.bg:SetBackdrop({
                bgFile = "Interface/Buttons/WHITE8X8",
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            panelFrame.bg:SetBackdropColor(0, 0, 0, bgAlpha)
        else
            panelFrame.bg:SetBackdropColor(0, 0, 0, bgAlpha)
            panelFrame.bg:Show()
        end

        panelFrame.bg:ClearAllPoints()
        panelFrame.bg:SetAllPoints(panelFrame)
    elseif panelFrame.bg then
        panelFrame.bg:Hide()
    end

    panelFrame:SetSize(math.max(maxWidth, 1), math.max(maxHeight, 1))
end

-- Force refresh all glows (called when global settings change)
function sfui.trackedicons.ForceRefreshGlows()
    for _, panel in pairs(panels) do
        if panel.icons then
            for _, icon in pairs(panel.icons) do
                if icon._glowActive then
                    StopGlow(icon)
                end
            end
        end
    end
end

-- Visibility Logic check per panel
local function CheckPanelVisibility(panelConfig)
    if not panelConfig then return false end

    -- Check Form Specificity (Druid CENTER panels mostly)
    local isStealthed = IsStealthed()
    local currentForm = GetShapeshiftFormID() or 0
    local playerClass = sfui.common.get_player_class()

    if panelConfig.requiredForm ~= nil then
        if panelConfig.requiredForm == "stealth" then
            if not isStealthed then return false end

            -- If we are a Druid in Bear or Moonkin form, we prioritize the form-specific bar over Stealth.
            if playerClass == "DRUID" and currentForm ~= 0 and currentForm ~= 1 then
                return false
            end
        else
            -- Non-stealth form panel logic
            local matchesForm = false
            if type(panelConfig.requiredForm) == "table" then
                for _, id in ipairs(panelConfig.requiredForm) do
                    if currentForm == id then
                        matchesForm = true; break
                    end
                end
            elseif currentForm == panelConfig.requiredForm then
                matchesForm = true
            end

            if not matchesForm then return false end
        end
    end

    -- If we are stealthed, we usually want the STEALTH bar to take priority for Human and Cat.
    -- This hides ALL base bars to prevent overlap, even if requiredForm matches.
    if isStealthed and (currentForm == 0 or currentForm == 1) then
        if panelConfig.requiredForm ~= "stealth" then
            return false
        end
    end

    -- Removed legacy always/combat visibility override checks

    -- Hide OOC (Out of Combat)
    if panelConfig.hideOOC and not InCombatLockdown() then
        return false
    end

    -- Priority: Combat status always overrides mount/vehicle hide conditions
    if not InCombatLockdown() then
        -- Hide Mounted
        if panelConfig.hideMounted and IsMounted() then
            return false
        end

        -- Hide in Dragonriding
        if panelConfig.hideDragonriding and C_MountJournal.IsDragonRidingActive() then
            return false
        end
    end

    -- Hide if no active icons
    if panelConfig.hideIfEmpty then
        local activeEntries = sfui.common.get_active_panel_entries(panelConfig, _staticActiveEntries)
        if #activeEntries == 0 then
            return false
        end
    end

    return true
end

-- Helper to remove legacy defaults from panels so they use global settings
local function SanitizePanelConfig(panelConfig)
    if not panelConfig then return end

    -- Keys to purge from panel config (ensures fallback to Global settings)
    local keysToPurge = {
        "readyGlow", "useSpecColor", "glowType", "glowColor",
        "glowScale", "glowSpeed", "glowIntensity", "glow_max_duration",
        "glowLines", "glowParticles", "glowThickness",
        "cooldownDesat", "useResourceCheck",
        "textEnabled", "alphaOnCooldown",
        "textColor", "squareIcons", "showBorder"
    }

    -- Global Protection: Ensure Global Settings aren't corrupted
    local igs = SfuiDB and SfuiDB.iconGlobalSettings
    if igs and igs.alphaOnCooldown == 0 then
        igs.alphaOnCooldown = 1.0
    end

    for _, key in ipairs(keysToPurge) do
        panelConfig[key] = nil
    end

    -- ALSO purge per-entry settings (legacy icon-specific overrides)
    if panelConfig.entries then
        for _, entry in ipairs(panelConfig.entries) do
            if type(entry) == "table" and entry.settings then
                for _, key in ipairs(keysToPurge) do
                    entry.settings[key] = nil
                end
            end
        end
    end
end

function sfui.trackedicons.Update()
    sfui.trackedicons.InvalidateConfigCache()
    local panelConfigs = sfui.common.get_cooldown_panels()
    if not panelConfigs or #panelConfigs == 0 then return end


    -- Render Panels
    for i, panelConfig in ipairs(panelConfigs) do
        if panelConfig.enabled then
            if not panels[i] then
                panels[i] = CreateFrame("Frame", "SfuiIconPanel_" .. i, UIParent)
            end

            local shouldShow = CheckPanelVisibility(panelConfig)
            if shouldShow then
                panels[i]:Show()
                sfui.trackedicons.UpdatePanelLayout(panels[i], panelConfig)
            else
                panels[i]:Hide()
            end
        elseif panels[i] then
            if not InCombatLockdown() then
                panels[i]:Hide()
            end
        end
    end
end

local function VisibilitySyncHelper()
    for blizzFrame in BuffBarCooldownViewer.itemFramePool:EnumerateActive() do
        if blizzFrame.cooldownID then
            local shouldHide = false
            -- Check category via C_CooldownViewer (if available)
            if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(blizzFrame.cooldownID)
                if info then
                    -- Category 0 = Essential, 1 = Utility
                    -- Hide these as we track them with icons
                    if info.category == 0 or info.category == 1 then
                        shouldHide = true
                    end
                end
            end

            if shouldHide then
                blizzFrame:SetAlpha(0)
                if blizzFrame.SetAlpha then -- Ensure interaction is disabled too?
                    blizzFrame:EnableMouse(false)
                end
            end
        end
    end
end

-- Hook to hide specific categories from Blizzard's CooldownViewer
local function ProcessBlizzardVisibilitySync()
    if not BuffBarCooldownViewer or not BuffBarCooldownViewer.itemFramePool then return end
    VisibilitySyncHelper()
end

local function SyncBlizzardVisibility()
    sfui.trackedicons.blizzSyncDirty = true
end

function sfui.trackedicons.initialize()
    -- Ensure Blizzard addon is loaded so we can hook it
    local loaded, reason = C_AddOns.LoadAddOn("Blizzard_CooldownViewer")

    -- Register hooks if available
    if BuffBarCooldownViewer then
        if BuffBarCooldownViewer.RefreshData then
            hooksecurefunc(BuffBarCooldownViewer, "RefreshData", SyncBlizzardVisibility)
        end
        if BuffBarCooldownViewer.RefreshApplications then
            hooksecurefunc(BuffBarCooldownViewer, "RefreshApplications", SyncBlizzardVisibility)
        end
        if BuffBarCooldownViewer.SetAuraInstanceInfo then
            hooksecurefunc(BuffBarCooldownViewer, "SetAuraInstanceInfo", SyncBlizzardVisibility)
        end
        -- Initial sync
        SyncBlizzardVisibility()
    end

    -- Hide Blizzard Cooldown Frames
    if sfui.common.hide_blizzard_cooldown_viewers then
        sfui.common.hide_blizzard_cooldown_viewers()
    end

    -- Helper: Update only icon states (no layout rebuild) using cached panel.config
    local function UpdateAllIconStates()
        for _, panel in pairs(panels) do
            local config = panel.config
            if panel.icons and config then
                for _, icon in pairs(panel.icons) do
                    UpdateIconState(icon, config)
                end
            end
        end
    end

    -- Helper: Update only cooldown-type icon states
    local function UpdateCooldownIconStates()
        for _, panel in pairs(panels) do
            local config = panel.config
            if panel.icons and config then
                for _, icon in pairs(panel.icons) do
                    if icon.entry and icon.entry.type == "cooldown" then
                        UpdateIconState(icon, config)
                    end
                end
            end
        end
    end

    -- Event handling
    sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED", function()
        sfui.trackedicons.Update()
        MarkDirty()
    end)
    sfui.events.RegisterEvent("PLAYER_REGEN_DISABLED", function()
        sfui.trackedicons.Update()
        MarkDirty()
    end)
    sfui.events.RegisterEvent("PLAYER_TARGET_CHANGED", function()
        MarkDirty(true)
    end)
    sfui.events.RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED", function()
        sfui.trackedicons.Update()
        MarkDirty()
    end)
    sfui.events.RegisterEvent("UPDATE_SHAPESHIFT_FORM", function()
        sfui.trackedicons.Update()
        MarkDirty()
    end)
    sfui.events.RegisterEvent("UPDATE_STEALTH", function()
        sfui.trackedicons.Update()
        MarkDirty()
    end)

    sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        sfui.common.ensure_panels_initialized()
        if sfui.common.SyncTrackedSpells then
            sfui.common.SyncTrackedSpells()
        end
        sfui.trackedicons.Update()
        MarkDirty(true)
    end)
    sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
        sfui.common.ensure_panels_initialized()
        if sfui.common.SyncTrackedSpells then
            sfui.common.SyncTrackedSpells()
        end
        sfui.trackedicons.Update()
        MarkDirty(true)
    end)
    sfui.events.RegisterEvent("PLAYER_TALENT_UPDATE", function()
        sfui.common.ensure_panels_initialized()
        if sfui.common.SyncTrackedSpells then
            sfui.common.SyncTrackedSpells()
        end
        sfui.trackedicons.Update()
        MarkDirty(true)
    end)
    -- 12.0.5+: fires when the system forces a spec change (arena PvP loadout lock,
    -- talent reset, etc.) — treat identically to PLAYER_SPECIALIZATION_CHANGED.
    sfui.events.RegisterEvent("SPEC_INVOLUNTARILY_CHANGED", function()
        sfui.common.ensure_panels_initialized()
        if sfui.common.SyncTrackedSpells then
            sfui.common.SyncTrackedSpells()
        end
        sfui.trackedicons.Update()
        MarkDirty(true)
    end)
    sfui.events.RegisterEvent("SPELLS_CHANGED", function() MarkDirty(true) end)

    -- Soul fragments, charges, resource-gated display counts.
    sfui.events.RegisterEvent("SPELL_UPDATE_CHARGES", function()
        _needsStateUpdate = true
    end)

    -- UNIT_POWER_UPDATE covers resource pools (throttled out of combat to avoid mana/energy tick churn)
    local _lastOOCPowerTime = 0
    sfui.events.RegisterUnitEvent("UNIT_POWER_UPDATE", "player", function(event, unit)
        if InCombatLockdown() then
            _needsStateUpdate = true
        else
            local now = GetTime()
            if (now - _lastOOCPowerTime) >= 1.0 then
                _lastOOCPowerTime = now
                _needsStateUpdate = true
            end
        end
    end)

    -- Real-time events that require immediate structural/GCD sync
    sfui.events.RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(event, unit)
        _needsStateUpdate = true
    end)

    sfui.events.RegisterEvent("SPELL_UPDATE_COOLDOWN", function()
        _needsStateUpdate = true
    end)

    sfui.events.RegisterEvent("BAG_UPDATE_COOLDOWN", function()
        _needsStateUpdate = true
    end)

    -- 11.0+ C_UnitAuras Event Migration (throttled out of combat to prevent background tick churn)
    local _lastOOCAuraTime = 0
    sfui.events.RegisterUnitEvent("UNIT_AURA", "player", function(event, unit, updateInfo)
        if InCombatLockdown() then
            _needsStateUpdate = true
        else
            local now = GetTime()
            if (now - _lastOOCAuraTime) >= 1.0 then
                _lastOOCAuraTime = now
                _needsStateUpdate = true
            end
        end
    end)

    sfui.events.RegisterEvent("TRAIT_CONFIG_UPDATED", function()
        MarkDirty(not InCombatLockdown())
    end)

    -- 12.0.5+: fires when Blizzard switches the aura data provider (e.g. into M+ obfuscated
    -- mode). When useRealDataProvider=false, all aura queries will return secret/fake data.
    -- We reset all icon states immediately so stale cooldown/stack data is cleared before
    -- the next proper UNIT_AURA fires. When returning to real data we also force a refresh.
    sfui.events.RegisterEvent("AURA_DATA_PROVIDER_SWITCH", function(useRealDataProvider)
        if not useRealDataProvider then
            -- Entering secret/fake aura mode (M+ key started, etc.)
            -- Clear all icon cooldown frames and count badges to avoid stale display.
            for _, panel in pairs(panels) do
                if panel.icons then
                    for _, icon in pairs(panel.icons) do
                        if icon.cooldown then
                            icon.cooldown:Clear()
                        end
                        if icon.shadowCooldown then
                            icon.shadowCooldown:Clear()
                        end
                        if icon.count then
                            icon.count:Hide()
                        end
                        icon._lastCount = nil
                        icon._wasOnCooldown = false
                        icon._pendingGlow = false
                    end
                end
            end
        end
        -- Force a full update on both entry and exit so icons reflect real state ASAP.
        MarkDirty(true)
    end)

    -- OnUpdate: Only process when dirty (zero CPU/allocations when idle)
    local blizzSyncTimer = 0
    local function _OnTrackedIconsUpdate(elapsed)
        if sfui.trackedicons.blizzSyncDirty then
            blizzSyncTimer = blizzSyncTimer + elapsed
            if blizzSyncTimer > 0.1 then
                blizzSyncTimer = 0
                sfui.trackedicons.blizzSyncDirty = false
                ProcessBlizzardVisibilitySync()
            end
        end

        if _layoutCooldown > 0 then
            _layoutCooldown = _layoutCooldown - elapsed
        end

        -- Only update when explicitly dirty
        if _needsLayoutUpdate and _layoutCooldown <= 0 then
            _needsLayoutUpdate = false
            _needsStateUpdate = false
            _layoutCooldown = 0.5 -- 500ms throttle for layout updates
            wipe(_cdInfoCache)
            sfui.trackedicons.Update()
        elseif _needsStateUpdate then
            _needsStateUpdate = false
            UpdateAllIconStates()
        elseif _activeGlowCount > 0 then
            -- Even when idle, check icons with active glows for timeout (skip when no glows active)
            for _, panel in pairs(panels) do
                if panel.icons then
                    for _, icon in pairs(panel.icons) do
                        if icon._glowActive then
                            local config = panel.config
                            if config then
                                UpdateIconGlow(icon, icon.entry and icon.entry.settings or _emptyTable, config, true)
                            end
                        end
                    end
                end
            end
        end
    end

    sfui.events.RegisterUpdate("TrackedIcons", 0.1, _OnTrackedIconsUpdate)

    -- Initial setup
    sfui.common.ensure_panels_initialized()

    -- Sanitize all panels once (skip if already done)
    if not SfuiDB._panelsSanitizedV2 then
        local panelConfigs = sfui.common.get_cooldown_panels()
        if panelConfigs then
            for _, panelConfig in ipairs(panelConfigs) do
                SanitizePanelConfig(panelConfig)
            end
        end
        SfuiDB._panelsSanitizedV2 = true
    end

    sfui.trackedicons.Update()
end

function sfui.trackedicons_debug_info()
    local pCount = 0
    local iCount = 0
    for _, p in pairs(panels) do
        pCount = pCount + 1
        if p.icons then
            for _ in pairs(p.icons) do iCount = iCount + 1 end
        end
    end
    return {
        panels = pCount,
        icons = iCount,
        activeGlows = _activeGlowCount,
        cdCache = _cdInfoCacheCount,
        needsState = _needsStateUpdate,
        needsLayout = _needsLayoutUpdate,
    }
end
