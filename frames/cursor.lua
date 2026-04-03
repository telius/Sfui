local addonName, addon = ...
sfui = sfui or {}
sfui.cursor = {}

local f -- specific frame reference
local lastX, lastY = 0, 0
local uiparent

function sfui.cursor.initialize()
    if _G.SfuiCursor then return end

    -- Cache UIParent reference
    uiparent = UIParent
    local GetCursorPosition = GetCursorPosition
    local GetEffectiveScale = uiparent.GetEffectiveScale

    -- Create Frame
    f = CreateFrame("Frame", "SfuiCursor", uiparent)
    f:SetSize(64, 64)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(9999)
    f:EnableMouse(false)
    f:SetClampedToScreen(false)
    -- Set initial anchor once (never cleared)
    f:SetPoint("CENTER", uiparent, "BOTTOMLEFT", 0, 0)

    -- Create Texture
    local ring = f:CreateTexture(nil, "OVERLAY")
    ring:SetAllPoints(f)
    ring:SetTexture("Interface\\AddOns\\sfui\\ring.tga")

    -- Helper: Update Color
    local function UpdateColor()
        local spec = GetSpecialization()
        local specID = spec and GetSpecializationInfo(spec) or 0
        local color = sfui.config.spec_colors[specID] or { 1, 1, 1, 1 }
        ring:SetVertexColor(color[1], color[2], color[3], 0.8)
    end

    -- Event Handler
    f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("UI_SCALE_CHANGED")

    local cachedScale = GetEffectiveScale(uiparent)

    f:SetScript("OnEvent", function(_, event)
        if event == "UI_SCALE_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
            cachedScale = GetEffectiveScale(uiparent)
        end
        if event ~= "UI_SCALE_CHANGED" then
            UpdateColor()
        end
    end)

    -- Optimized Update Loop - uses SetPoint offset instead of ClearAllPoints
    f.OnUpdate = function(self, elapsed)
        local x, y = GetCursorPosition()
        local cx = x / cachedScale
        local cy = y / cachedScale

        -- Only update if position changed (already doing this optimization)
        if cx ~= lastX or cy ~= lastY then
            lastX, lastY = cx, cy
            -- SetPoint with changed offset is faster than ClearAllPoints + SetPoint
            self:SetPoint("CENTER", uiparent, "BOTTOMLEFT", cx, cy)
        end
    end

    -- Initialize Color
    UpdateColor()

    -- Apply initial state
    sfui.cursor.toggle(SfuiDB.enableCursorRing)
end

function sfui.cursor.update_scale()
    if not f then return end
    local scale = SfuiDB.cursorRingScale or 1.0
    f:SetSize(64 * scale, 64 * scale)
end

function sfui.cursor.toggle(enabled)
    SfuiDB.enableCursorRing = enabled
    if not f then return end

    if enabled then
        f:Show()
        sfui.cursor.update_scale() -- Ensure scale is correct when shown
        f:SetScript("OnUpdate", f.OnUpdate)
    else
        f:Hide()
        f:SetScript("OnUpdate", nil)
    end
end
