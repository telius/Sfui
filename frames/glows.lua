-- sfui Glow Module - LibCustomGlow-1.0 Integration
-- Based on ArcUI's pattern with alpha hooks for smooth transitions

local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo

if not LCG then
    -- Fallback: LibCustomGlow not available
    sfui.common.print("|cff6600ffsfui|r: LibCustomGlow-1.0 not found, glow effects disabled")
    sfui.common.print("|cff6600ffsfui|r: LibStub available:", LibStub and "YES" or "NO")

    -- Create stub module to prevent errors
    sfui.glows = {
        start_glow = function() end,
        stop_glow = function() end,
        set_glow_alpha = function() end
    }
    return
end


sfui.glows = {}

-- Helper: Get value from entry → panel → global → hardcoded default
local function GetValue(entrySettings, panelConfig, key, default)
    if entrySettings and entrySettings[key] ~= nil then return entrySettings[key] end
    if panelConfig and panelConfig[key] ~= nil then return panelConfig[key] end

    local globalCfg = SfuiDB and SfuiDB.iconGlobalSettings
    if globalCfg and globalCfg[key] ~= nil then return globalCfg[key] end

    local g = sfui.config
    local configDefault = g and g.icon_panel_global_defaults
    if configDefault and configDefault[key] ~= nil then return configDefault[key] end

    return default
end

-- Shared resolver to ensure consistent visuals across active icons and global preview
function sfui.glows.resolve_config(entrySettings, panelConfig, targetTable)
    local cfg = targetTable or {}
    local defaults = sfui.config.icon_panel_global_defaults or {}

    cfg.glowType = GetValue(entrySettings, panelConfig, "glowType", "pixel")
    cfg.useSpecColor = GetValue(entrySettings, panelConfig, "useSpecColor", true)

    local color = GetValue(entrySettings, panelConfig, "glowColor", { 1, 0.85, 0.1, 1 })
    if cfg.useSpecColor then
        local specIndex = GetSpecialization()
        if specIndex and specIndex > 0 then
            local specID = GetSpecializationInfo(specIndex)
            if specID and sfui.config.spec_colors and sfui.config.spec_colors[specID] then
                color = sfui.config.spec_colors[specID]
            end
        end
    end
    cfg.glowColor = color

    cfg.glowScale = GetValue(entrySettings, panelConfig, "glowScale", defaults.glowScale or 1.0)
    cfg.glow_max_duration = GetValue(entrySettings, panelConfig, "glow_max_duration", defaults.glow_max_duration or 5.0)
    cfg.glowIntensity = GetValue(entrySettings, panelConfig, "glowIntensity", defaults.glowIntensity or 1.0)
    cfg.glowSpeed = GetValue(entrySettings, panelConfig, "glowSpeed", defaults.glowSpeed or 0.25)
    cfg.glowLines = GetValue(entrySettings, panelConfig, "glowLines", defaults.glowLines or 8)
    cfg.glowThickness = GetValue(entrySettings, panelConfig, "glowThickness", defaults.glowThickness or 2)
    cfg.glowParticles = GetValue(entrySettings, panelConfig, "glowParticles", defaults.glowParticles or 4)

    return cfg
end

-- Alpha hook system (prevents LCG from overriding our alpha)
local function HookGlowAlpha(glowFrame, parentIcon)
    if not glowFrame or glowFrame._sfuiAlphaHooked then return end

    -- Safely hook — LibCustomGlow internals may change between versions
    local ok, err = pcall(function()
        glowFrame._sfuiAlphaHooked = true

        local origSetAlpha = glowFrame.SetAlpha
        if not origSetAlpha then return end

        glowFrame.SetAlpha = function(self, alpha)
            local parent = self:GetParent()
            if parent and parent._sfuiForcedGlowAlpha then
                origSetAlpha(self, parent._sfuiForcedGlowAlpha)
            else
                origSetAlpha(self, alpha)
            end
        end
    end)

    if not ok then
        -- Silently fail — glow will work, just without alpha control
        glowFrame._sfuiAlphaHooked = false
    end
end

-- Start glow with specified configuration
function sfui.glows.start_glow(icon, config)
    if not icon or not config then
        sfui.common.print("|cff6600ffsfui|r: start_glow called with nil icon or config")
        return
    end

    local glowType = config.glowType or "pixel"
    local color = config.glowColor or { 1, 0.85, 0.1, 1 }
    local key = "sfui_ReadyGlow"

    -- Performance: Detect if we are already showing this EXACT glow to avoid pool thrashing
    local configHash = string.format("%s_%s_%s_%s_%s_%s_%s_%s_%s_%s",
        glowType,
        tostring(config.glowColor and table.concat(config.glowColor, ",") or "def"),
        tostring(config.glowScale or 1),
        tostring(config.glowSpeed or 0.25),
        tostring(config.glowIntensity or 1),
        tostring(config.glowLines or 8),
        tostring(config.glowParticles or 4),
        tostring(config.glowThickness or 2),
        tostring(config.glow_max_duration or 5),
        tostring(config.useSpecColor or "false")
    )

    if icon._glowActive and icon._lastGlowHash == configHash then
        return -- Already showing this exact glow, skip restart
    end

    -- Stop existing surgicaly
    sfui.glows.stop_glow(icon)

    -- Build color array for LCG
    local r, g, b, a = sfui.common.unpack_color(color)
    local colorArray = { r, g, b, 1.0 }

    local success, err
    -- Start appropriate glow type
    if glowType == "pixel" then
        success, err = pcall(LCG.PixelGlow_Start,
            icon,
            colorArray,
            config.glowLines or 8,
            config.glowSpeed or 0.25,
            nil,  -- length (nil = default)
            config.glowThickness or 2,
            0,    -- xOffset
            0,    -- yOffset
            true, -- border
            key
        )

        if not success then
            sfui.common.print("|cff6600ffsfui|r: PixelGlow_Start failed:", err)
            return
        end

        local glow = icon["_PixelGlow" .. key]
        if glow then
            HookGlowAlpha(glow, icon)
            if config.glowScale and config.glowScale ~= 1.0 then
                pcall(glow.SetScale, glow, config.glowScale)
            end
        else
            sfui.common.print("|cff6600ffsfui|r: PixelGlow started but frame not found")
        end
    elseif glowType == "autocast" then
        success, err = pcall(LCG.AutoCastGlow_Start,
            icon,
            colorArray,
            config.glowParticles or 4,
            config.glowSpeed or 0.25,
            config.glowScale or 1.0,
            0, -- xOffset
            0, -- yOffset
            key
        )

        if not success then
            sfui.common.print("|cff6600ffsfui|r: AutoCastGlow_Start failed:", err)
            return
        end

        local glow = icon["_AutoCastGlow" .. key]
        if glow then
            HookGlowAlpha(glow, icon)
        else
            sfui.common.print("|cff6600ffsfui|r: AutoCastGlow started but frame not found")
        end
    elseif glowType == "proc" then
        success, err = pcall(LCG.ProcGlow_Start, icon, {
            color = colorArray,
            startAnim = false,
            xOffset = 0,
            yOffset = 0,
            key = key
        })

        if not success then
            sfui.common.print("|cff6600ffsfui|r: ProcGlow_Start failed:", err)
            return
        end

        local glow = icon["_ProcGlow" .. key]
        if glow then
            HookGlowAlpha(glow, icon)
            if config.glowScale and config.glowScale ~= 1.0 then
                pcall(glow.SetScale, glow, config.glowScale)
            end
            -- Fix initial state
            if glow.ProcStart then glow.ProcStart:Hide() end
            if glow.ProcLoop then
                glow.ProcLoop:Show()
                glow.ProcLoop:SetAlpha(config.glowIntensity or 1.0)
            end
        else
            sfui.common.print("|cff6600ffsfui|r: ProcGlow started but frame not found")
        end
    else -- "button" (default)
        success, err = pcall(LCG.ButtonGlow_Start, icon, colorArray, config.glowSpeed or 0.25)

        if not success then
            sfui.common.print("|cff6600ffsfui|r: ButtonGlow_Start failed:", err)
            return
        end

        local glow = icon._ButtonGlow
        if glow then
            HookGlowAlpha(glow, icon)
            if config.glowScale and config.glowScale ~= 1.0 then
                pcall(glow.SetScale, glow, config.glowScale)
            end
        else
            sfui.common.print("|cff6600ffsfui|r: ButtonGlow started but frame not found")
        end
    end

    icon._glowActive = true
    icon._lastGlowType = glowType
    icon._lastGlowHash = configHash
    icon._sfuiForcedGlowAlpha = 1.0
end

-- Stop all glows on an icon
function sfui.glows.stop_glow(icon)
    if not icon then return end

    local key = "sfui_ReadyGlow"

    -- Stop all glow types (Surgical stop based on last state to prevent Blizzard Pool errors)
    local lastType = icon._lastGlowType
    if lastType == "pixel" then
        pcall(LCG.PixelGlow_Stop, icon, key)
    elseif lastType == "autocast" then
        pcall(LCG.AutoCastGlow_Stop, icon, key)
    elseif lastType == "proc" then
        pcall(LCG.ProcGlow_Stop, icon, key)
    elseif lastType == "button" then
        pcall(LCG.ButtonGlow_Stop, icon)
    else
        -- Fallback if type is unknown: stop all (pcall protected)
        pcall(LCG.PixelGlow_Stop, icon, key)
        pcall(LCG.AutoCastGlow_Stop, icon, key)
        pcall(LCG.ProcGlow_Stop, icon, key)
        pcall(LCG.ButtonGlow_Stop, icon)
    end

    icon._glowActive = false
    icon._lastGlowType = nil
    icon._lastGlowHash = nil
    icon._sfuiForcedGlowAlpha = nil
end

-- Set glow alpha (for fading effects)
function sfui.glows.set_glow_alpha(icon, alpha)
    if not icon then return end

    icon._sfuiForcedGlowAlpha = alpha

    -- Find active glow frame and trigger alpha update
    local key = "sfui_ReadyGlow"
    local glowFrame = icon["_PixelGlow" .. key]
        or icon["_AutoCastGlow" .. key]
        or icon["_ProcGlow" .. key]
        or icon._ButtonGlow

    if glowFrame then
        glowFrame:SetAlpha(alpha)
    end
end

function sfui.glows_debug_info()
    return {
        lcgAvailable = LCG ~= nil,
    }
end
