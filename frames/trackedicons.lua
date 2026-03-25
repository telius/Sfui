local addonName, addon = ...
sfui.trackedicons = {}

local C_Spell = C_Spell
local C_Item = C_Item
local C_CooldownViewer = C_CooldownViewer
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local CreateFrame = CreateFrame
local UIParent = UIParent
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
local _burstTimer = 0          -- Brief burst period after events for smooth transitions
local _layoutCooldown = 0

-- Helper: Mark icons as needing a state refresh
local function MarkDirty(burstDuration, needsLayout)
    _needsStateUpdate = true
    if needsLayout then
        _needsLayoutUpdate = true
    end
    _burstTimer = math.max(_burstTimer, burstDuration or 0.5)
end
sfui.trackedicons.MarkDirty = MarkDirty
local issecretvalue = sfui.common.issecretvalue
-- STATIC REUSE (Memory Optimization)
local _tempGlowCfg = {}
local _defaultColor = { 1, 1, 0, 1 }
local _defaultTextColor = { 1, 1, 1, 1 } -- Reuse to avoid per-call allocation
local _emptyTable = {}
local _iconCounter = 0

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

-- Static pcall targets
local function pcall_item_cd(icon)
    local s, d, e = C_Item.GetItemCooldown(icon.id)
    icon._start, icon._duration, icon._isEnabled = s, d, e
    -- CooldownFrame_Set natively bypasses secret value locks inside its C++ widget
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

-- Local wrapper to ensure state cleanup
local function StopGlow(icon)
    sfui.glows.stop_glow(icon)
    -- Do NOT clear _glowStartTime here, as it breaks the timeout logic (infinite restart loop)
    -- _glowStartTime is cleared explicitly when the icon is no longer ready.
    icon._lastGlowCfg = nil
    icon._glowActive = false
end


local function StartGlow(icon, cfg)
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

    local count = icon:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    count:SetPoint("BOTTOMRIGHT", -2, 2)
    count:SetJustifyH("RIGHT")
    icon.count = count
end


-- Helper to update count text value
local function UpdateCountText(icon, count)
    if not icon.count then CreateCountText(icon) end

    local isSecret = issecretvalue(count)

    if isSecret then
        sfui.common.SafeSetText(icon.count, count, 0)
        icon.count:Show()
    elseif type(count) == "number" and count > 0 then
        icon.count:SetText(tostring(count))
        icon.count:Show()
    else
        icon.count:Hide()
    end
end

-- IsDragonriding: use sfui.common.IsDragonriding() (single source of truth)

-- Lightweight cooldown logic (CooldownCompanion + TweaksUI pattern):
--   • SetCooldown() accepts secret values natively (C++ level)
--   • isOnGCD is NeverSecret — always safe to branch on
--   • Scratch cooldown probe only when values are secret (M+ combat)
--   • Zero closures — all pcall uses the no-allocation form
local scratchParent = CreateFrame("Frame")
scratchParent:Hide()
local scratchCooldown = CreateFrame("Cooldown", nil, scratchParent, "CooldownFrameTemplate")

local function UpdateIconCooldown(icon, activeID, resolvedType)
    local count = 0
    local isEnabled = true
    local isUsable, notEnoughPower = true, false
    local isOnCooldown = false

    if resolvedType == "item" then
        local ok, countVal = pcall(pcall_item_cd, icon)
        if ok then
            count = countVal or 0
            isEnabled = icon._isEnabled
            local d = icon._duration
            if d ~= nil and d > 0 then isOnCooldown = true end
        end
    else
        -- Spell: officially supports tainted spellIdentifiers
        local ok_cd, cdInfo = pcall(C_Spell.GetSpellCooldown, activeID)

        if ok_cd and cdInfo ~= nil then
            -- 12.0.1 Hotfix: 'SetCooldown' no longer legally accepts Secret Values.
            -- Addons MUST acquire a DurationObject and pass it to 'SetCooldownFromDurationObject'.
            if icon.cooldown.SetCooldownFromDurationObject and C_Spell.GetSpellCooldownDuration then
                local ok_dur, durationObj = pcall(C_Spell.GetSpellCooldownDuration, activeID)
                if ok_dur and durationObj then
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
                local modRate = cdInfo.modRate or 1
                local isEnabled = cdInfo.isEnabled
                if isEnabled == nil then isEnabled = true end
                
                local ok_set = pcall(icon.cooldown.SetCooldown, icon.cooldown, cdInfo.startTime, cdInfo.duration)
                if ok_set then
                    if icon.shadowCooldown then
                        icon.shadowCooldown:SetCooldown(cdInfo.startTime, cdInfo.duration)
                    end
                else
                    icon.cooldown:Clear()
                    if icon.shadowCooldown then icon.shadowCooldown:Clear() end
                end
            end

            -- cdInfo.isActive and cdInfo.isOnGCD are designated "NeverSecret=true" in 12.0.1.
            -- We securely branch on these to determine visual wipe conditions without comparing durations.
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

        -- Charges: supports tainted activeID
        local ok_ch, charges = pcall(C_Spell.GetSpellCharges, activeID)
        if ok_ch and charges ~= nil then
            local cc = charges.currentCharges
            if cc ~= nil then
                count = cc
            end
        end
    end

    -- Glow arming
    if icon._wasOnCooldown and not isOnCooldown then
        icon._pendingGlow = true
    end
    icon._wasOnCooldown = isOnCooldown

    -- Usability: supports tainted activeID
    if icon.type ~= "item" then
        local ok_u, u, p = pcall(C_Spell.IsSpellUsable, activeID)
        if ok_u then
            -- Guard results: if secret, assume true so we don't hide spells blindly
            isUsable = sfui.common.SafeValue(u, true)
            notEnoughPower = sfui.common.SafeValue(p, false)
        end
        if not HasFullControl() and not isUsable then isUsable = true end
    end

    -- Readiness
    local isReady
    if icon.type == "item" then
        isReady = not isOnCooldown and (isEnabled ~= false)
    else
        isReady = (not isOnCooldown or sfui.common.SafeGT(count, 0)) and (isEnabled ~= false) and isUsable
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
        if _cdInfoCache[cid] == nil then
            _cdInfoCacheCount = _cdInfoCacheCount + 1
            -- Wipe cache if it grows too large (e.g. 500 entries)
            if _cdInfoCacheCount > 500 then
                wipe(_cdInfoCache)
                _cdInfoCacheCount = 1
            end
            local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cid)
            _cdInfoCache[cid] = ok and info or false
        end
        return _cdInfoCache[cid] or nil
    end
    return nil
end

-- Helper to update icon state (visibility, cooldown, charges)
local function UpdateIconState(icon, panelConfig)
    if not icon.id or not icon.entry then return false end
    local entrySettings = icon.entry.settings or _emptyTable

    -- 1. Determine the Correct Spell/Item ID and Texture
    local iconTexture, activeID, resolvedType = sfui.trackedicons.GetIconTexture(icon.id, icon.type, icon.entry)

    -- 2. FORCE TEXTURE REFRESH (Fixes "Reload Required" for reordering)
    if icon.texture and iconTexture then
        if icon._currentTexture ~= iconTexture then
            icon.texture:SetTexture(iconTexture)
            icon._currentTexture = iconTexture
        end
    end
    icon._lastActiveID = activeID
    icon._resolvedType = resolvedType

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

        -- Update Count Text
        UpdateCountText(icon, count)

        -- Visibility / Settings check
        icon.cooldown:SetHideCountdownNumbers(not GetIconValue(entrySettings, panelConfig, "textEnabled", true))

        -- 5. Update Visuals
        UpdateIconVisuals(icon, entrySettings, panelConfig, isUsable, isOnCooldown, notEnoughPower)

        -- 5b. Update Border Style (Force re-apply in case Masque overrode anchors)
        sfui.trackedicons.ApplyIconBorderStyle(icon, panelConfig)

        -- 5c. Update Hotkey Text
        sfui.trackedicons.UpdateIconHotkey(icon, panelConfig)

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

    if type == "cooldown" and entry and entry.cooldownID then
        -- Get cooldown info from Blizzard's CDM
        local cdInfo = SafeGetCooldownViewerCooldownInfo(entry.cooldownID)
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

    return iconTexture, activeID, resolvedType
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

-- Update hotkey text on an icon from the hotkey cache
function sfui.trackedicons.UpdateIconHotkey(icon, panelConfig)
    if not icon or not icon.hotkeyText then return end

    local showHotkeys = GetIconValue(nil, panelConfig, "showHotkeys", false)
    if not showHotkeys or not sfui.hotkeys then
        icon.hotkeyText:Hide()
        return
    end

    -- Update font/anchor in case config changed
    local hkSize = GetIconValue(nil, panelConfig, "hotkeyFontSize", 12)
    local hkOutline = GetIconValue(nil, panelConfig, "hotkeyOutline", "OUTLINE")
    local hkAnchor = GetIconValue(nil, panelConfig, "hotkeyAnchor", "TOPLEFT")
    icon.hotkeyText:SetFont("Fonts\\FRIZQT__.TTF", hkSize, hkOutline)
    icon.hotkeyText:ClearAllPoints()
    icon.hotkeyText:SetPoint(hkAnchor, icon, hkAnchor, 2, -2)

    -- Lookup hotkey
    local hotkey = nil
    local activeID = icon._lastActiveID or icon.id
    if icon.entry and icon.entry.type == "item" then
        hotkey = sfui.hotkeys.get_for_item(activeID)
    else
        hotkey = sfui.hotkeys.get_for_spell(activeID)
    end

    if hotkey then
        icon.hotkeyText:SetText(hotkey)
        icon.hotkeyText:Show()
    else
        icon.hotkeyText:Hide()
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

    -- Hotkey text (keybinding display)
    f.hotkeyText = f:CreateFontString(nil, "OVERLAY")
    local hkSize = GetIconValue(nil, panelConfig, "hotkeyFontSize", 12)
    local hkOutline = GetIconValue(nil, panelConfig, "hotkeyOutline", "OUTLINE")
    local hkAnchor = GetIconValue(nil, panelConfig, "hotkeyAnchor", "TOPLEFT")
    f.hotkeyText:SetFont("Fonts\\FRIZQT__.TTF", hkSize, hkOutline)
    f.hotkeyText:SetPoint(hkAnchor, f, hkAnchor, 2, -2)
    f.hotkeyText:SetTextColor(1, 1, 1, 1)
    f.hotkeyText:Hide()

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
            pcall(function()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.entry.type == "item" then
                    GameTooltip:SetItemByID(self.id)
                else
                    GameTooltip:SetSpellByID(self.id)
                end
                GameTooltip:Show()
            end)
        end
    end)
    f:SetScript("OnLeave", function(self)
        local showTooltips = GetIconValue(self.entry.settings, panelConfig, "showTooltips", false)
        if showTooltips and GameTooltip then pcall(GameTooltip.Hide, GameTooltip) end
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
        sfui.events.RegisterEvent("UNIT_POWER_BAR_SHOW",
            function(...) sfui.trackedicons.OnVisibilityEvent(nil, "UNIT_POWER_BAR_SHOW", ...) end)
        sfui.events.RegisterEvent("UNIT_POWER_BAR_HIDE",
            function(...) sfui.trackedicons.OnVisibilityEvent(nil, "UNIT_POWER_BAR_HIDE", ...) end)
    end



    -- Trigger initial visibility check IMMEDIATELY
    if panelFrame.visHandler then
        pcall(panelFrame.visHandler:GetScript("OnEvent"), panelFrame.visHandler)
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

    local activeIcons = {}
    local entries = sfui.common.get_active_panel_entries(panelConfig)

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

                -- Sync Masque state
                SyncIconMasque(icon)

                -- Always add icons to layout; errors in state update should not hide them
                local ok, isVisibleValue = pcall(UpdateIconState, icon, panelConfig)
                if not ok then
                    -- UpdateIconState errored — show icon anyway to prevent disappearing
                    icon:Show()
                    print("|cff6600ffsfui|r: UpdateIconState error:", isVisibleValue)
                end

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
        local activeEntries = sfui.common.get_active_panel_entries(panelConfig)
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

-- Hook to hide specific categories from Blizzard's CooldownViewer
local function ProcessBlizzardVisibilitySync()
    if not BuffBarCooldownViewer or not BuffBarCooldownViewer.itemFramePool then return end

    pcall(function()
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
    end)
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

    -- (State variables and MarkDirty moved to module level)
    local _burstTimer = 0          -- Brief burst period after events for smooth transitions

    -- Helper: Mark icons as needing a state refresh
    -- Helper: Mark icons as needing a state refresh
    local _layoutCooldown = 0
    local function MarkDirty(burstDuration, needsLayout)
        _needsStateUpdate = true
        if needsLayout then
            _needsLayoutUpdate = true
        end
        _burstTimer = math.max(_burstTimer, burstDuration or 0.5)
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
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED", function()
        sfui.trackedicons.Update()
        MarkDirty(1.0) -- Longer burst for combat transitions
    end)
    sfui.events.RegisterEvent("PLAYER_REGEN_DISABLED", function()
        sfui.trackedicons.Update()
        MarkDirty(1.0) -- Longer burst for combat transitions
    end)
    sfui.events.RegisterEvent("PLAYER_TARGET_CHANGED", function()
        MarkDirty(0.5, true)
    end)
    sfui.events.RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED", function()
        sfui.trackedicons.Update()
        MarkDirty(1.0) -- Longer burst for combat transitions
    end)
    sfui.events.RegisterEvent("UPDATE_SHAPESHIFT_FORM", function()
        sfui.trackedicons.Update()
        MarkDirty(1.0) -- Longer burst for combat transitions
    end)
    sfui.events.RegisterEvent("UPDATE_STEALTH", function()
        sfui.trackedicons.Update()
        MarkDirty(1.0) -- Longer burst for combat transitions
    end)

    sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        sfui.common.ensure_panels_initialized()
        if sfui.common.SyncTrackedSpells then
            sfui.common.SyncTrackedSpells()
        end
        sfui.trackedicons.Update()
        MarkDirty(2.0) -- Longer burst for world entry
    end)
    sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
        sfui.common.ensure_panels_initialized()
        if sfui.common.SyncTrackedSpells then
            sfui.common.SyncTrackedSpells()
        end
        sfui.trackedicons.Update()
        MarkDirty(2.0) -- Longer burst for world entry
    end)
    sfui.events.RegisterEvent("PLAYER_TALENT_UPDATE", function()
        sfui.common.ensure_panels_initialized()
        if sfui.common.SyncTrackedSpells then
            sfui.common.SyncTrackedSpells()
        end
        sfui.trackedicons.Update()
        MarkDirty(2.0) -- Longer burst for world entry
    end)
    sfui.events.RegisterEvent("SPELLS_CHANGED", function() MarkDirty() end)

    -- Real-time events that require immediate structural/GCD sync
    sfui.events.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(unit)
        if unit == "player" then
            MarkDirty(0.5, true)
        end
    end)

    sfui.events.RegisterEvent("SPELL_UPDATE_COOLDOWN", function()
        -- Only mark state dirty — do NOT extend the burst timer.
        -- SPELL_UPDATE_COOLDOWN fires on every GCD tick while idle.
        -- Extending _burstTimer here keeps UpdateAllIconStates running
        -- at 10fps continuously while out of combat, causing ~0.2MB/s GC pressure.
        _needsStateUpdate = true
    end)

    sfui.events.RegisterEvent("BAG_UPDATE_COOLDOWN", function()
        _needsStateUpdate = true
    end)

    -- 11.0 C_UnitAuras Event Migration
    sfui.events.RegisterEvent("UNIT_AURA", function(unit, updateInfo)
        if unit == "player" and updateInfo then
            local needsFullUpdate = false

            if updateInfo.addedAuras and #updateInfo.addedAuras > 0 then
                needsFullUpdate = true
            end
            if updateInfo.removedAuraInstanceIDs and #updateInfo.removedAuraInstanceIDs > 0 then
                needsFullUpdate = true
            end

            MarkDirty(0.5, needsFullUpdate)
        else
            MarkDirty(0.5, not InCombatLockdown())
        end
    end)

    sfui.events.RegisterEvent("TRAIT_CONFIG_UPDATED", function()
        MarkDirty(0.5, not InCombatLockdown())
    end)

    -- OnUpdate: Only process when dirty or during burst period (for smooth glow/alpha transitions)
    local blizzSyncTimer = 0
    sfui.events.RegisterUpdate(0.1, function(elapsed)
        if sfui.trackedicons.blizzSyncDirty then
            blizzSyncTimer = blizzSyncTimer + elapsed
            if blizzSyncTimer > 0.1 then
                blizzSyncTimer = 0
                sfui.trackedicons.blizzSyncDirty = false
                ProcessBlizzardVisibilitySync()
            end
        end

        -- Decrement burst and layout timers
        if _burstTimer > 0 then
            _burstTimer = _burstTimer - 0.1
        end
        if _layoutCooldown > 0 then
            _layoutCooldown = _layoutCooldown - 0.1
        end

        -- Only update if dirty flag set or burst timer active or any glows are running
        if _needsLayoutUpdate and _layoutCooldown <= 0 then
            _needsLayoutUpdate = false
            _needsStateUpdate = false
            _layoutCooldown = 0.5 -- 500ms throttle for layout updates
            wipe(_cdInfoCache)
            sfui.trackedicons.Update()
        elseif _needsStateUpdate or _burstTimer > 0 then
            _needsStateUpdate = false
            wipe(_cdInfoCache)
            UpdateAllIconStates()
        else
            -- Even when idle, check icons with active glows for timeout
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
    end)

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
