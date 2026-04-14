local addonName, addon = ...
sfui.trackedbars = {}

local cfg = sfui.config
local common = sfui.common
local bars = {} -- Active sfui bars
local container
local issecretvalue = common.issecretvalue
local CreateFrame = CreateFrame
local UIParent = UIParent
local GameTooltip = GameTooltip
local C_Spell = C_Spell
local InCombatLockdown = InCombatLockdown
local wipe = table.wipe or wipe
local hooksecurefunc = hooksecurefunc
local C_UnitAuras = C_UnitAuras
local BuffBarCooldownViewer = BuffBarCooldownViewer
local C_CooldownViewer = C_CooldownViewer
local IsInInstance = IsInInstance
local C_Timer = C_Timer
local GetTime = GetTime
local C_Secrets = _G.C_Secrets -- 12.0.5+: secrecy predicate API

local unpack = unpack

-- Reusable tables (performance optimization)
local standardBars = {}
local activeCooldownIDs = {}

-- Helper to get tracking config for a specific ID
local configCache = {}
local function GetTrackedBarConfig(cooldownID)
    if not cooldownID then return nil end
    local cached = configCache[cooldownID]
    if cached then return cached end

    local cfg = { _id = cooldownID }

    -- 1. Base Defaults (lowest priority)
    if cfg.trackedBars and cfg.trackedBars.defaults then
        local defaults = cfg.trackedBars.defaults
        local entry = defaults[cooldownID] or defaults[tonumber(cooldownID)]
        if entry then
            local match = true
            if entry.specID then
                local currentSpec = common.get_current_spec_id and common.get_current_spec_id()
                if currentSpec and entry.specID ~= currentSpec then
                    match = false
                end
            end
            if match then
                for k, v in pairs(entry) do cfg[k] = v end
            end
        end
    end

    -- 2. User DB Overrides (highest priority)
    local specBars = common.get_tracked_bars()
    if specBars then
        local entry = specBars[cooldownID] or specBars[tonumber(cooldownID)]
        if type(entry) == "table" then
            for k, v in pairs(entry) do cfg[k] = v end
        end
    end

    configCache[cooldownID] = cfg
    return cfg
end
sfui.trackedbars.GetConfig = GetTrackedBarConfig

-- Public: Get all known spells (active or configured) for the settings panel
function sfui.trackedbars.GetKnownSpells()
    local known = {}

    local function GetInfo(id)
        local name, icon
        if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
            local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(id)
            if info then
                if info.spellID then
                    name = C_Spell.GetSpellName(info.spellID)
                    icon = C_Spell.GetSpellTexture(info.spellID)
                elseif info.itemID then
                    name = C_Item.GetItemNameByID(info.itemID)
                    icon = C_Item.GetItemIconByID(info.itemID)
                end
            end
        end
        -- Fallback to direct spell lookup if info failed
        if not name then name = C_Spell.GetSpellName(id) end
        if not icon then icon = C_Spell.GetSpellTexture(id) end

        return name or ("Unknown (" .. id .. ")"), icon or cfg.textures.white
    end

    -- Only add configured bars from DB to ensure synchronization with assignments
    local specBars = common.get_tracked_bars()
    if specBars then
        for id, cfg in pairs(specBars) do
            if type(id) == "number" and not known[id] then
                local n, i = GetInfo(id)
                known[id] = {
                    id = id,
                    name = n,
                    icon = i,
                    active = bars[id] ~= nil
                }
            end
        end
    end

    -- Sort by name
    local sorted = {}
    for _, info in pairs(known) do table.insert(sorted, info) end
    table.sort(sorted, function(a, b) return (a.name or "") < (b.name or "") end)

    return sorted
end

-- Cache invalidation (call when settings change)
function sfui.trackedbars.InvalidateConfigCache()
    wipe(configCache)
end

-- Helper to determine max stacks for a bar
-- Checks in order: special cases -> user config -> charge info -> default
local function GetMaxStacksForBar(cooldownID, config, spellID)
    local cfg = sfui.config.trackedBars
    local maxStacks = cfg.defaultMaxStacks

    -- 1. Check user config override (highest priority)
    if config and config.maxStacks then
        return config.maxStacks
    end

    -- 2. Check for special case overrides
    if cfg.specialCases and cfg.specialCases[cooldownID] and cfg.specialCases[cooldownID].maxStacks then
        return cfg.specialCases[cooldownID].maxStacks
    end

    -- 3. Try to get from charge info (for charge-based abilities)
    if spellID and not issecretvalue(spellID) then
        local ok, chargeInfo = pcall(C_Spell.GetSpellCharges, spellID)
        if ok and chargeInfo and chargeInfo.maxCharges then
            maxStacks = chargeInfo.maxCharges
        end
    end

    return maxStacks
end
sfui.trackedbars.GetMaxStacks = GetMaxStacksForBar

-- Helper for Masque Sync
local function SyncBarMasque(bar)
    common.sync_masque(bar.iconFrame, { Icon = bar.icon })
end



local function CreateBar(cooldownID)
    local cfg = sfui.config.trackedBars
    -- Frame is the Backdrop/Container
    local barName = "sfui_bar" .. tostring(cooldownID) .. "_Backdrop"
    local bar = CreateFrame("Frame", barName, container, "BackdropTemplate")
    bar:SetSize(cfg.width, cfg.height)

    -- Backdrop styling (Flat, no border)
    bar:SetBackdrop({
        bgFile = sfui.config.textures.white,
        tile = true,
        tileSize = 32,
    })

    -- Status Bar
    local defaultColor = cfg.backdrop.color
    bar:SetBackdropColor(unpack(defaultColor))

    -- Status Bar
    bar.status = CreateFrame("StatusBar", nil, bar)
    local pad = cfg.backdrop.padding
    bar.status:SetPoint("TOPLEFT", bar, "TOPLEFT", pad, -pad)
    bar.status:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -pad, pad)
    bar.status:SetStatusBarTexture(sfui.config.textures.white)
    bar.status:SetStatusBarColor(unpack(sfui.config.colors.purple))

    -- Icon
    bar.iconFrame = CreateFrame("Button", nil, bar)
    bar.iconFrame:SetSize(cfg.icon_size, cfg.icon_size)
    bar.iconFrame:SetPoint("RIGHT", bar, "LEFT", cfg.icon_offset, 0)

    bar.icon = bar.iconFrame:CreateTexture(nil, "ARTWORK")
    bar.icon:SetAllPoints()

    common.apply_square_icon_style(bar.iconFrame, bar.icon)

    local msq = common.get_masque_group()
    if msq then
        msq:AddButton(bar.iconFrame, { Icon = bar.icon })
        bar._isMasqued = true
    end

    -- Text
    bar.name = bar.status:CreateFontString(nil, "OVERLAY")
    bar.name:SetDrawLayer("OVERLAY", 7)
    bar.name:SetFontObject(sfui.config.font_small)
    bar.name:SetPoint("LEFT", cfg.spacing or 5, 0)
    common.style_text(bar.name, nil, nil, "")

    bar.time = bar.status:CreateFontString(nil, "OVERLAY")
    bar.time:SetDrawLayer("OVERLAY", 7)
    bar.time:SetFontObject(sfui.config.font_small)
    bar.time:SetPoint("CENTER", bar.status, "CENTER", 0, 0)
    common.style_text(bar.time, nil, nil, "")

    -- Stack Count
    bar.count = bar.status:CreateFontString(nil, "OVERLAY")
    bar.count:SetDrawLayer("OVERLAY", 7)
    bar.count:SetFontObject(sfui.config.font_small)
    bar.count:SetPoint("CENTER", bar.icon, "CENTER", 0, 0)
    common.style_text(bar.count, nil, nil, "")

    -- Stack Segments (for stack mode display)
    bar.segments = {}
    for i = 1, cfg.maxSegments do
        local seg = CreateFrame("StatusBar", nil, bar)
        seg:SetStatusBarTexture(sfui.config.textures.white)
        seg:SetStatusBarColor(unpack(sfui.config.colors.purple))
        seg:SetMinMaxValues(0, 1)
        seg:SetValue(1)
        seg:Hide()

        -- Segment background
        seg.bg = seg:CreateTexture(nil, "BACKGROUND")
        seg.bg:SetAllPoints(seg)
        seg.bg:SetColorTexture(unpack(cfg.backdrop.color))

        bar.segments[i] = seg
    end

    bar.cooldownID = cooldownID

    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function(self)
        if self.spellID then
            if C_Spell and C_Spell.PickupSpell then
                C_Spell.PickupSpell(self.spellID)
            else
                PickupSpell(self.spellID)
            end
        elseif self.itemID then
            PickupItem(self.itemID)
        end
    end)
    bar:SetScript("OnEnter", function(self)
        if GameTooltip and self.spellID then
            local secureSpell = self.spellID
            
            -- Passing a Secret Value pointer to the global GameTooltip violently escalates 
            -- the entire UI tooltip renderer into a deep C++ Secrecy Context, causing future 
            -- string-width evaluations (like MoneyFrame coin positioning) to fail and crash!
            if issecretvalue(secureSpell) then
                if type(self.cooldownID) == "number" then
                    secureSpell = self.cooldownID
                else
                    return -- Abort safely to preserve the global UI state
                end
            end
            -- Anchor to the parent container instead of the bar itself!
            -- Anchoring to a StatusBar that holds a secret value (like duration) mathematically
            -- taints the entire GameTooltip's localized dimensions, crashing future money scans.
            GameTooltip:SetOwner(self:GetParent(), "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(secureSpell)
            GameTooltip:Show()
        end
    end)
    bar:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    return bar
end

-- Helper function to setup bar content (text, icons, stack mode logic)
local function SetupBarState(bar, config, cfg)
    local isStackMode = config and config.stackMode or false
    local isAttached = config and config.stackAboveHealth or false
    local showStacksText = config and config.showStacksText or false

    if isStackMode then
        for i = 1, cfg.maxSegments do bar.segments[i]:Hide() end
        bar.status:Show(); bar.name:Show(); bar.time:Show(); bar.icon:Show(); bar.count:Hide()

        -- Center time in Stack Mode
        bar.time:ClearAllPoints()
        bar.time:SetPoint("CENTER", bar.status, "CENTER", 0, 0)
        common.style_text(bar.time, nil, cfg.fonts.stackModeDurationSize, "")

        if config and config.showName == false then bar.name:Hide() end
    else
        for i = 1, cfg.maxSegments do bar.segments[i]:Hide() end
        -- Standard Mode
        bar.status:Show(); bar.name:Show(); bar.time:Show(); bar.icon:Show()
        bar.count:ClearAllPoints()
        bar.count:SetPoint("CENTER", bar.icon, "CENTER", 0, 0)
        common.style_text(bar.count, nil, nil)

        if config and config.showName == false then bar.name:Hide() end
        if config and config.showDuration == false then bar.time:Hide() end
        if config and config.showStacks == false then bar.count:Hide() end

        -- Text Position Logic: Center if Attached or Stacks Text, Right if Standard
        bar.time:ClearAllPoints()
        if isAttached or showStacksText then
            bar.time:SetPoint("CENTER", bar.status, "CENTER", 0, 0)
            common.style_text(bar.time, nil, cfg.fonts.stackModeDurationSize, "")
        else
            bar.time:SetPoint("RIGHT", -(cfg.spacing or 5), 0)
            -- Use default small font style implicitly or re-apply if needed (assuming CreateBar set it)
        end
    end

    -- Icon Visibility Override for Attached bars
    if isAttached then
        bar.icon:Hide()
        bar.count:Hide()                            -- Hide count on icon position
    else
        if not isStackMode then bar.icon:Show() end -- Restore
    end

    -- Hide count if showing stacks as main text (redundant)
    if showStacksText then
        bar.count:Hide()
    end

    -- Color Logic
    local color = sfui.config.colors.purple -- ultimate fallback
    if config then
        if config.customColor then
            color = config.customColor
        elseif config.useSpecColor then
            local specID = GetSpecializationInfo(GetSpecialization())
            local c = sfui.config.spec_colors[specID]
            if c then color = c end
        elseif SfuiDB and SfuiDB.trackedBars and SfuiDB.trackedBars.defaultBarColor then
            color = SfuiDB.trackedBars.defaultBarColor
        elseif config.color then
            color = config.color
        end
    elseif SfuiDB and SfuiDB.trackedBars and SfuiDB.trackedBars.defaultBarColor then
        color = SfuiDB.trackedBars.defaultBarColor
    end

    bar.status:SetStatusBarColor(common.unpack_color(color))

    -- If the bar is currently in the pandemic window, restore the pandemic color.
    -- This ensures UpdateLayout (called on any visibility change) doesn't stomp it.
    if config and config.pandemicEnabled and bar._inPandemic then
        local pColor = config.pandemicColor or { 1, 0, 1, 1 }
        bar.status:SetStatusBarColor(common.unpack_color(pColor))
    end
end

-- Helper for Standard Bar Positioning
local function ApplyBarStyling(bar, yOffset, config, cfg, globalDB)
    local width = globalDB.width or cfg.width
    local height = globalDB.height or cfg.height
    local spacing = globalDB.spacing or cfg.spacing or 5

    bar:SetSize(width, height)
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOM", container, "BOTTOM", 0, yOffset)
    local pad = cfg.backdrop.padding
    bar.status:ClearAllPoints()
    bar.status:SetPoint("TOPLEFT", pad, -pad)
    bar.status:SetPoint("BOTTOMRIGHT", -pad, pad)
    bar:SetBackdropColor(unpack(cfg.backdrop.color))
    return yOffset + (height + spacing)
end


local function UpdateLayout()
    local cfg = sfui.config.trackedBars
    local globalDB = SfuiDB and SfuiDB.trackedBars or {}
    wipe(standardBars)
    local attachedBars = {}

    for _, bar in pairs(bars) do
        if bar:IsShown() then
            local config = GetTrackedBarConfig(bar.cooldownID)
            SetupBarState(bar, config, cfg)
            SyncBarMasque(bar)

            if config and config.stackAboveHealth then
                table.insert(attachedBars, bar)
            else
                table.insert(standardBars, bar)
            end
        end
    end

    -- Update container/child icon sizes if changed globally
    local iconSize = globalDB.iconSize or cfg.icon_size or 20

    -- Normal Sort (Normal Index > Name)
    local function NormalSort(a, b)
        local cA = GetTrackedBarConfig(a.cooldownID)
        local cB = GetTrackedBarConfig(b.cooldownID)
        
        -- Default to 100 or legacy priority if unassigned, so they sit below manually bumped bars.
        local nA = (cA and cA.normalIndex) or (cA and cA.priority) or 100
        local nB = (cB and cB.normalIndex) or (cB and cB.priority) or 100

        if nA ~= nB then return nA < nB end

        local nA_name = C_Spell.GetSpellName(a.cooldownID) or ""
        local nB_name = C_Spell.GetSpellName(b.cooldownID) or ""
        return nA_name < nB_name
    end

    -- Attached Sort (Attached Index > Name)
    local function AttachedSort(a, b)
        local cA = GetTrackedBarConfig(a.cooldownID)
        local cB = GetTrackedBarConfig(b.cooldownID)
        
        local aA = (cA and cA.attachedIndex) or (cA and cA.priority) or 100
        local aB = (cB and cB.attachedIndex) or (cB and cB.priority) or 100

        if aA ~= aB then return aA < aB end

        local nA_name = C_Spell.GetSpellName(a.cooldownID) or ""
        local nB_name = C_Spell.GetSpellName(b.cooldownID) or ""
        return nA_name < nB_name
    end

    -- 1. Standard Layout
    table.sort(standardBars, NormalSort)
    local yOffset = 0
    for _, bar in ipairs(standardBars) do
        local config = GetTrackedBarConfig(bar.cooldownID)
        bar:SetParent(container)
        bar.iconFrame:Show()
        bar.iconFrame:SetSize(iconSize, iconSize) -- Apply global icon size override
        if bar.iconFrame.borderBackdrop then bar.iconFrame.borderBackdrop:Show() end
        yOffset = ApplyBarStyling(bar, yOffset, config, cfg, globalDB)
    end

    -- 2. Attached Layout
    if #attachedBars > 0 then
        table.sort(attachedBars, AttachedSort)

        local spacing = sfui.config.barLayout.spacing or 1
        local anchor = _G["sfui_bar0_Backdrop"]
        local isBar1 = false

        if _G["sfui_bar1_Backdrop"] and _G["sfui_bar1_Backdrop"]:IsShown() then
            anchor = _G["sfui_bar1_Backdrop"]
            isBar1 = true
        elseif _G["sfui_runeBar"] then
            anchor = _G["sfui_runeBar"]
            isBar1 = true
        end

        if anchor then
            for _, bar in ipairs(attachedBars) do
                bar:SetParent(UIParent)
                bar:ClearAllPoints()

                local width = sfui.config.healthBar.width * (cfg.attachedWidthMultiplier or 0.8)
                local height = cfg.attachedHeight or 20

                bar:SetSize(width, height)
                bar:SetPoint("BOTTOM", anchor, "TOP", 0, spacing)

                -- Style Fix
                local pad = cfg.backdrop.padding
                bar.status:ClearAllPoints()
                bar.status:SetPoint("TOPLEFT", pad, -pad)
                bar.status:SetPoint("BOTTOMRIGHT", -pad, pad)
                bar:SetBackdropColor(unpack(cfg.backdrop.color))

                -- Hide Icon for Attached Bars
                bar.iconFrame:Hide()
                if bar.iconFrame.borderBackdrop then bar.iconFrame.borderBackdrop:Hide() end

                -- Re-anchor name to the far left since icon is hidden
                bar.name:ClearAllPoints()
                bar.name:SetPoint("LEFT", cfg.spacing or 5, 0)

                anchor = bar
            end
        end
    end
end

-- Update Position External Reference
function sfui.trackedbars.UpdatePosition()
    if not container then return end
    local db = SfuiDB and SfuiDB.trackedBars
    local x = (db and db.anchor and db.anchor.x) or (SfuiDB and SfuiDB.trackedBarsX) or
        (cfg.trackedBars.anchor and cfg.trackedBars.anchor.x) or -300
    local y = (db and db.anchor and db.anchor.y) or (SfuiDB and SfuiDB.trackedBarsY) or
        (cfg.trackedBars.anchor and cfg.trackedBars.anchor.y) or 300

    container:ClearAllPoints()
    container:SetPoint("BOTTOM", UIParent, "BOTTOM", x, y)
end

function sfui.trackedbars.SetColor(cooldownID, r, g, b)
    local barDB = common.ensure_tracked_bar_db(cooldownID)
    barDB.color = { r = r, g = g, b = b }
    UpdateLayout() -- Refresh to apply color
end

local barPool = {}

local function RecycleBar(bar)
    bar:Hide()
    bar:ClearAllPoints()
    bar:SetParent(nil)
    bar.cooldownID = nil
    table.insert(barPool, bar)
end

local function GetBarFromPool(cooldownID)
    local bar = table.remove(barPool)
    if bar then
        bar:SetParent(container)
        bar.cooldownID = cooldownID
        return bar
    end
    return nil
end

function sfui.trackedbars.RemoveBar(cooldownID, suppressLayout)
    if bars and bars[cooldownID] then
        RecycleBar(bars[cooldownID])
        bars[cooldownID] = nil
        if not suppressLayout then
            UpdateLayout()
        end
    end
end

-- Helper: Determine if bar should be visible based on settings
local function ShouldBarBeVisible(config, blizzFrame, isStackModeWithStacks, hideInactive)
    if isStackModeWithStacks then
        -- Always show stack mode bars with active stacks
        return true
    elseif hideInactive then
        -- Only show if Blizzard shows it (it's active)
        return blizzFrame:IsShown()
    else
        -- Show all bars regardless of active state
        return true
    end
end

-- Helper: Perform protected blizzard frame scraping
local function _pcall_get_app_text(blizzFrame)
    if blizzFrame.Icon and blizzFrame.Icon.Applications then
        return blizzFrame.Icon.Applications:GetText()
    end
    return nil
end

local function _pcall_get_duration_text(blizzFrame)
    if blizzFrame.Bar and blizzFrame.Bar.Duration then
        return blizzFrame.Bar.Duration:GetText() or ""
    end
    return ""
end

local function _pcall_sync_bar_values(blizzFrame, status, timeString, config, currentStacks)
    local min, max = blizzFrame.Bar:GetMinMaxValues()
    local val = blizzFrame.Bar:GetValue()
    status:SetMinMaxValues(min, max)
    common.SafeSetValue(status, val)

    local barText = _pcall_get_duration_text(blizzFrame)
    if config and config.showStacksText then
        if type(currentStacks) == "number" or (not issecretvalue(currentStacks)) then
            barText = tostring(currentStacks)
        else
            barText = currentStacks
        end
    end
    timeString:SetText(barText)
end

-- Helper: Sync bar data from Blizzard frame
local function SyncBarData(myBar, blizzFrame, config, isStackMode, id)
    local cfg = sfui.config.trackedBars

    myBar.spellID = blizzFrame.spellID or (blizzFrame.info and blizzFrame.info.spellID)
    
    if not myBar.spellID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
        if ok and info and info.spellID then
            myBar.spellID = info.spellID
        end
    end

    -- Mirror Icon and Desaturation
    if blizzFrame.Icon and blizzFrame.Icon.Icon then
        myBar.icon:SetTexture(blizzFrame.Icon.Icon:GetTexture())

        -- Detect Desaturation (Inactive State)
        if blizzFrame.Icon.Icon.GetDesaturated and blizzFrame.Icon.Icon:GetDesaturated() then
            myBar.icon:SetDesaturated(true)
        else
            myBar.icon:SetDesaturated(false)
        end
    end

    -- Stack data gathering
    local currentStacks = nil
    local maxStacks = GetMaxStacksForBar(id, config, myBar.spellID)

    -- 0. DIRECT UNRESTRICTED PLAYER AURA (Strongest Architecture for Player Buffs like Bone Shield)
    -- This totally bypasses the CooldownViewer encryption pipeline. By natively asking
    -- the UnitAuras API for our *own* buff, it hands us a completely unrestricted pure Lua
    -- integer securely, avoiding any C++ Secret Value pointer quirks during rendering.
    if myBar.spellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(myBar.spellID)
        if auraData and type(auraData.applications) == "number" then
            currentStacks = auraData.applications
            if auraData.name then myBar.name:SetText(auraData.name) end
        end
    end

    -- 1. Try Aura Data via Instance ID (If not resolved by Tier 0)
    if not currentStacks and common.HasAuraInstanceID(blizzFrame.auraInstanceID) then
        local unit = blizzFrame.auraDataUnit or "player"
        local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, blizzFrame.auraInstanceID)
        if auraData then
            -- Accept both plain numbers and Secret Values natively. A Secret Value here
            -- is a memory-encrypted number that is safe to pass directly to SetValue().
            if type(auraData.applications) == "number" or issecretvalue(auraData.applications) then
                currentStacks = auraData.applications
            end
            -- Update name safely
            if auraData.name then myBar.name:SetText(auraData.name) end
        end
    end

    -- 2. Try Spell Charges (for abilities with charges, mostly missing auraInstanceID)
    if not currentStacks and myBar.spellID then
        local ok, chargeInfo = pcall(C_Spell.GetSpellCharges, myBar.spellID)
        if ok and chargeInfo and chargeInfo.currentCharges then
            -- Accept secret numeric charges too
            local cc = chargeInfo.currentCharges
            if type(cc) == "number" or issecretvalue(cc) then
                currentStacks = cc
            end
        end
    end

    -- 3. Fallback to Text (Blizzard's Display) - UNRESTRICTED
    if not currentStacks then
        local ok, text = pcall(_pcall_get_app_text, blizzFrame)
        if ok and text then
            if issecretvalue(text) then
                currentStacks = text
            elseif text ~= "" then
                currentStacks = text
            end
        end
    end

    -- 4. Apply Cache Debounce to prevent 1-frame combat flicker
    -- When abilities like Bone Shield refresh, the Aura API can briefly report nil stacks.
    if currentStacks then
        myBar._auraStackCache = currentStacks
        myBar._auraStackTimer = GetTime()
    elseif myBar._auraStackCache and myBar._auraStackTimer then
        if GetTime() - myBar._auraStackTimer < 0.2 then
            currentStacks = myBar._auraStackCache -- Sustain previous stack count momentarily
        else
            myBar._auraStackCache = nil           -- Expire cache
        end
    end

    local db = SfuiDB and SfuiDB.trackedBars or {}

    -- Handle text visibility toggles (Global and Per-Bar options)
    local showName = db.showName
    if config and config.showName ~= nil then
        showName = config.showName
    end

    if showName == false then
        myBar.name:Hide()
    else
        myBar.name:Show()
    end

    if db.showDuration == false or (config and config.showDuration == false) then
        myBar.time:Hide()
    else
        myBar.time:Show()
    end

    local isAttached = config and config.stackAboveHealth or false
    local showStacksText = config and config.showStacksText or false

    if db.showStacks == false or (config and config.showStacks == false) or isStackMode or isAttached or showStacksText then
        myBar.count:Hide()
    else
        myBar.count:Show()
    end

    -- Set Name (Config > Aura Data > Blizzard Text)
    if config and config.name then
        common.SafeSetText(myBar.name, config.name)
    elseif not blizzFrame.auraInstanceID and blizzFrame.Bar and blizzFrame.Bar.Name then -- Only use blizz text if no aura data
        local bName = blizzFrame.Bar.Name:GetText()
        if bName and not issecretvalue(bName) then
            common.SafeSetText(myBar.name, bName)
        end
    end

    -- Default to 0 and Ensure Safety
    -- Allow strings to pass through natively (e.g. "150k" absorbs)
    if currentStacks == nil then
        currentStacks = 0
    end

    -- Peak Sustain Guard (Stack Mode only):
    -- The aura API transiently reports applications=0 for ~1 frame when a charge
    -- is consumed and the refreshed aura instance hasn't been registered yet. We
    -- intercept this 0 here and sustain the previous non-zero value for up to 0.2s.
    -- This protects both the bar width (SetValue) AND the visibility logic (Hide)
    -- from interpreting the transient drop as the buff falling off.
    local tempVal = nil
    local isSecret = issecretvalue(currentStacks)
    if not isSecret then
        tempVal = tonumber(currentStacks)
    end
    
    local skipSetValue = false
    
    if isStackMode then
        if isSecret then
            -- Secret Values inherently mean >0 active stacks; safe to cache directly.
            myBar._stackPeakVal   = currentStacks
            myBar._stackPeakTimer = GetTime()
        elseif tempVal and tempVal > 0 then
            myBar._stackPeakVal   = tempVal
            myBar._stackPeakTimer = GetTime()
        elseif tempVal == 0 and myBar._stackPeakVal and myBar._stackPeakTimer then
            if GetTime() - myBar._stackPeakTimer < 0.2 then
                currentStacks = myBar._stackPeakVal  -- sustain through transient zero
                skipSetValue = true                  -- freeze physical bar width
            else
                myBar._stackPeakVal = nil            -- genuinely zero — allow falloff
            end
        end
    end

    myBar.currentStacks = currentStacks -- Store for visibility checks and OnUpdate

    -- MAIN BAR UPDATE LOGIC
    local barText = ""
    if isStackMode then
        -- STACK MODE: Bar represents Stack Count
        local maxVal = type(maxStacks) == "number" and maxStacks or 10
        myBar.status:SetMinMaxValues(0, maxVal)

        local currentVal = currentStacks
        if not issecretvalue(currentStacks) and type(currentStacks) ~= "number" then
            currentVal = tonumber(currentStacks) or 0
        end

        if not skipSetValue then
            myBar.status:SetValue(currentVal)
        end

        if type(currentStacks) == "number" or not issecretvalue(currentStacks) then
            myBar.count:SetText(tostring(currentStacks)) -- Hidden but used for visibility logic
        else
            myBar.count:SetText(currentStacks)
        end

        -- FORCE HIDE BLIZZ BAR COMPONENTS if strict
        if blizzFrame.Bar then blizzFrame.Bar:SetAlpha(0) end

        -- Sync Time Text
        if blizzFrame.Bar then
            local ok, txt = pcall(_pcall_get_duration_text, blizzFrame)
            if ok and txt then barText = txt end

            if config and config.showStacksText then
                barText = tostring(currentStacks)
            end
            myBar.time:SetText(barText)
        end
    else
        -- NORMAL MODE: Bar represents Duration
        if blizzFrame.Bar then
            pcall(_pcall_sync_bar_values, blizzFrame, myBar.status, myBar.time, config, currentStacks)
        end

        if common.IsNumericAndPositive(currentStacks) then
            myBar.count:SetText(tostring(currentStacks))
        else
            if issecretvalue(currentStacks) then
                myBar.count:SetText(currentStacks)
            elseif currentStacks ~= 0 and currentStacks ~= "" then
                myBar.count:SetText(currentStacks)
            else
                myBar.count:SetText("")
            end
        end
    end

    -- Pandemic recolor: entirely pcall-wrapped so any error is safely swallowed.
    if config and config.pandemicEnabled then
        -- Reset to false BEFORE the pcall: if detection errors, we never leave stale
        -- "true" state that would permanently color the bar with the pandemic color.
        myBar._inPandemic = false
        pcall(function()
            local inPandemic = false

            -- Primary: blizzFrame.PandemicIcon is set (not nil) by Blizzard while in
            -- pandemic. Reading nil vs non-nil is safe -- no arithmetic, no secrets.
            -- NOTE: CooldownViewerBuffBarItemMixin (category-3 bars) does NOT call
            -- CheckSetPandemicAlertTiggerTime, so PandemicIcon is always nil there.
            -- We still check it first for any future Blizzard changes or non-buffbar items.
            if blizzFrame.PandemicIcon ~= nil then
                inPandemic = true
            else
                -- 12.0.5+ path: use GetAuraBaseDuration + GetRefreshExtendedDuration for a
                -- clean, arithmetic-free pandemic calculation. No string parsing required.
                local auraUnit = blizzFrame.auraDataUnit or "player"
                local auraInstanceID = blizzFrame.auraInstanceID
                if auraInstanceID and common.HasAuraInstanceID(auraInstanceID)
                    and C_UnitAuras.GetAuraBaseDuration and C_UnitAuras.GetRefreshExtendedDuration
                    and not (C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret())
                then
                    local baseDur = C_UnitAuras.GetAuraBaseDuration(auraUnit, auraInstanceID)
                    -- GetAuraDuration returns a LuaDurationObject \u2014 GetRemainingDuration()
                    -- yields a plain taint-free number.
                    if baseDur and baseDur > 0 and C_UnitAuras.GetAuraDuration then
                        local durObj = C_UnitAuras.GetAuraDuration(auraUnit, auraInstanceID)
                        if durObj and not durObj:HasSecretValues() then
                            local remaining = durObj:GetRemainingDuration()
                            -- Pandemic window = last 30% of base duration (standard WoW rule)
                            inPandemic = remaining <= (baseDur * 0.3)
                        end
                    end
                else
                    -- Fallback: text-parse approach for older builds or bars without auraInstanceID.
                    -- Use the text already synced to myBar.time -- same source as
                    -- _pcall_get_duration_text but avoids a second blizzFrame read.
                    local text = myBar.time and myBar.time:GetText()
                    if text and text ~= "" then
                        -- Parse common WoW timer formats:
                        --   "5.3s"  "12s"  "1m"  "1m 30s"  "1:30"  "60"
                        local secs = nil
                        local plain = text:match("^(%d+%.?%d*)%s*s?$")
                        if plain then
                            secs = tonumber(plain)
                        else
                            local m, s = text:match("^(%d+)m%s*(%d*)%s*s?$")
                            if m then secs = tonumber(m) * 60 + (tonumber(s) or 0) end
                            if not secs then
                                local mm, ss = text:match("^(%d+):(%d+)$")
                                if mm then secs = tonumber(mm) * 60 + (tonumber(ss) or 0) end
                            end
                        end

                        if secs and secs >= 0 then
                            -- Track the max observed remaining duration as a proxy for total
                            -- duration. Reset (clamp) when secs has jumped up again (fresh
                            -- application or talent change) to avoid an inflated threshold.
                            -- Hard-cap at 600s (10 min) to guard against transient bad reads.
                            local prevMax = myBar._cachedMaxDur or 0
                            if secs > prevMax then
                                myBar._cachedMaxDur = math.min(secs, 600)
                            end
                            local maxDur = myBar._cachedMaxDur
                            -- Pandemic window = last 30% of total duration (standard WoW rule)
                            if maxDur and maxDur > 0 then
                                inPandemic = (secs / maxDur) <= 0.3
                            end
                        end
                    end
                end
            end

            -- Persist state so SetupBarState re-applies the right color if
            -- UpdateLayout fires after this point in the same tick.
            myBar._inPandemic = inPandemic

            if inPandemic then
                local pColor = config.pandemicColor or { 1, 0, 1, 1 } -- default #ff00ff
                myBar.status:SetStatusBarColor(common.unpack_color(pColor))
            end
            -- No else needed: SetupBarState handles normal color restoration via
            -- _inPandemic=false.  If UpdateLayout hasn't fired this tick the bar keeps
            -- its color from the previous tick (imperceptible for a single frame).
        end)
    else
        -- Pandemic was disabled (or toggled off); clear any stale state.
        myBar._inPandemic = false
    end

end

local function SyncWithBlizzard()
    sfui.trackedbars.isDirty = true
end

local function ProcessBlizzardSync()
    if not BuffBarCooldownViewer or not BuffBarCooldownViewer.itemFramePool then return end

    wipe(activeCooldownIDs)
    local layoutNeeded = false

    -- Global Hide Check
    -- We use our own OOC logic to avoid touching Blizzard's protected viewer state if it's crashing.
    local mustHide = false
    local db = SfuiDB and SfuiDB.trackedBars or
        (cfg and cfg.trackedBars and cfg.trackedBars.defaults) or {}

    if db.hideOOC and not InCombatLockdown() then
        mustHide = true
    elseif not InCombatLockdown() then
        if db.hideMounted and common.is_mounted_or_travel_form() then
            mustHide = true
        elseif db.hideInVehicle and (UnitHasVehicleUI("player") or UnitInVehicle("player")) then
            mustHide = true
        elseif SfuiDB and SfuiDB.hideDragonriding and common.IsDragonriding() then
            mustHide = true
        end
    end

    if mustHide then
        for id, bar in pairs(bars) do
            if bar:IsShown() then
                bar:Hide()
                layoutNeeded = true
            end
        end
        if layoutNeeded then UpdateLayout() end
        return -- Skip processing updates if everything is hidden globally
    end

    -- Process Blizzard Frames
    local function processBlizzardFramesInternal()
        for blizzFrame in BuffBarCooldownViewer.itemFramePool:EnumerateActive() do
            if blizzFrame.cooldownID then
                blizzFrame:SetAlpha(0) -- Hide Blizzard frame regardless

                local id = blizzFrame.cooldownID
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(id)

                -- ONLY sync Native Blizzard Tracked Bars (Category 3)
                -- We manage this category directly in cdm.lua via CooldownViewerSettings
                local specBars = common.get_tracked_bars()
                local isManuallyTracked = specBars and specBars[id]

                local isValidTrackedBar = false
                if isManuallyTracked then
                    isValidTrackedBar = true
                elseif info and info.category == 3 then
                    isValidTrackedBar = true
                elseif info and Enum and Enum.CooldownViewerCategory and info.category == Enum.CooldownViewerCategory.TrackedBar then
                    isValidTrackedBar = true
                end

                if not isValidTrackedBar then
                    -- Skip anything else entirely
                else
                    local isSpecRestricted = false

                    if info and info.isKnown == false then
                        isSpecRestricted = true
                    end

                    if not isSpecRestricted and not isManuallyTracked and cfg.trackedBars and cfg.trackedBars.defaults then
                        local def = cfg.trackedBars.defaults[id]
                        if def and def.specID then
                            local currentSpec = common.get_current_spec_id and common.get_current_spec_id()
                            if currentSpec and def.specID ~= currentSpec then
                                isSpecRestricted = true
                            end
                        end
                    end

                    if not isSpecRestricted then
                        activeCooldownIDs[id] = true

                        if not bars[id] then
                            local pooledBar = GetBarFromPool(id)
                            if pooledBar then
                                bars[id] = pooledBar
                            else
                                bars[id] = CreateBar(id)
                            end
                            layoutNeeded = true
                        end

                        local myBar = bars[id]
                        -- Retroactive global name assignment for existing bars
                        if not myBar:GetName() then
                            local globalName = "sfui_bar" .. tostring(id) .. "_Backdrop"
                            if id == 1 or id == -1 or id == 0 then
                                _G[globalName] = myBar
                            end
                        end

                        local config = GetTrackedBarConfig(id) -- Cache config lookup once
                        local isStackMode = config and config.stackMode or false

                        -- IMPORTANT: Sync bar data BEFORE the visibility check so that
                        -- stack count text is always fresh. If we check isStackModeWithStacks
                        -- on stale count text (from the previous tick) we get a Hide→SyncData→Show
                        -- sequence on every aura refresh, which is exactly the Bone Shield flash.
                        SyncBarData(myBar, blizzFrame, config, isStackMode, id)

                        -- Sync Visibility
                        local db = SfuiDB and SfuiDB.trackedBars or {}
                        local hideInactive = db.hideInactive ~= false -- Default to True if nil

                        -- Check if this is a stack mode bar with active stacks
                        -- (count state is now populated by SyncBarData above)
                        local isStackModeWithStacks = false
                        if isStackMode then
                            local cStacks = myBar.currentStacks
                            if issecretvalue(cStacks) then
                                isStackModeWithStacks = true
                            else
                                local nStacks = tonumber(cStacks) or 0
                                if nStacks > 0 then
                                    isStackModeWithStacks = true
                                end
                            end
                        end

                        local shouldShow = ShouldBarBeVisible(config, blizzFrame, isStackModeWithStacks, hideInactive)

                        if shouldShow then
                            if not myBar:IsShown() then
                                myBar:Show()
                                layoutNeeded = true
                            end
                        else
                            if myBar:IsShown() then
                                myBar:Hide()
                                layoutNeeded = true
                            end
                        end
                    end
                end
            end
        end
    end
    pcall(processBlizzardFramesInternal)

    -- Cleanup with 0.25s graceful death to absorb Blizzard UI frame recreation blinking
    for id, bar in pairs(bars) do
        if not activeCooldownIDs[id] then
            if not bar._missingTime then
                bar._missingTime = GetTime()
            end
            if GetTime() - bar._missingTime > 0.25 then
                sfui.trackedbars.RemoveBar(id, true)
                layoutNeeded = true
            end
        else
            bar._missingTime = nil
        end
    end

    if layoutNeeded then
        UpdateLayout()
    end
end



-- Public function to trigger visibility update from options panel
function sfui.trackedbars.UpdateVisibility()
    if SyncWithBlizzard then
        SyncWithBlizzard()
    end
end

-- Hook-based updates
local hookedFrames = setmetatable({}, { __mode = "k" }) -- weak keys: stale frame userdata auto-collected
local function HookBlizzardFrame(frame)
    if not frame or hookedFrames[frame] then return end
    hookedFrames[frame] = true

    if frame.RefreshData then
        hooksecurefunc(frame, "RefreshData", function() SyncWithBlizzard() end)
    end
    if frame.RefreshApplications then
        hooksecurefunc(frame, "RefreshApplications", function() SyncWithBlizzard() end)
    end
    if frame.SetAuraInstanceInfo then
        hooksecurefunc(frame, "SetAuraInstanceInfo", function() SyncWithBlizzard() end)
    end
end

-- Public function to force layout update (e.g., when settings change)
function sfui.trackedbars.ForceLayoutUpdate()
    UpdateLayout()
end

-- Static update loop for bars (Eliminates OnUpdate closure churn)
local function UpdateBarsState()
    if not BuffBarCooldownViewer or not BuffBarCooldownViewer.itemFramePool then return end

    for blizzFrame in BuffBarCooldownViewer.itemFramePool:EnumerateActive() do
        if blizzFrame.cooldownID then
            -- Persistent Hide
            if blizzFrame.SetAlpha then blizzFrame:SetAlpha(0) end

            local myBar = bars[blizzFrame.cooldownID]
            -- Only update if bar exists AND is shown (performance optimization)
            if myBar and myBar:IsShown() and blizzFrame.Bar then
                -- Check Stack Mode
                local config = GetTrackedBarConfig(blizzFrame.cooldownID)
                local isStackMode = config and config.stackMode or false

                -- Only copy bar animation values if NOT in stack mode
                if not isStackMode then
                    local val = blizzFrame.Bar:GetValue()
                    common.SafeSetValue(myBar.status, val)
                end

                -- Update duration/name text
                if blizzFrame.Bar.Duration then
                    local text = blizzFrame.Bar.Duration:GetText() or ""
                    if config and config.showStacksText then
                        if myBar.currentStacks then
                            if type(myBar.currentStacks) == "number" or not issecretvalue(myBar.currentStacks) then
                                text = tostring(myBar.currentStacks)
                            else
                                text = myBar.currentStacks
                            end
                        end
                    end

                    if issecretvalue(text) then
                        myBar.time:SetText(text)
                    else
                        common.SafeSetText(myBar.time, text)
                    end
                end
            end
        end
    end
end

-- Event-driven stack count updates using new UNIT_AURA updateInfo (12.0.1.65867+)


function sfui.trackedbars.initialize()
    if container then return end
    local loaded, reason = C_AddOns.LoadAddOn("Blizzard_CooldownViewer")
    container = CreateFrame("Frame", "SfuiTrackedBarsContainer", UIParent)
    local cfg = sfui.config.trackedBars
    container:SetSize(cfg.width, cfg.height)

    common.ensure_tracked_bar_db() -- Initialize DB structure

    -- Set visibility defaults from config if not already set
    if SfuiDB.trackedBars.hideOOC == nil then
        SfuiDB.trackedBars.hideOOC = cfg.hideOOC ~= nil and cfg.hideOOC or false
    end
    if SfuiDB.trackedBars.hideInactive == nil then
        SfuiDB.trackedBars.hideInactive = cfg.hideInactive ~= nil and cfg.hideInactive or false
    end
    if SfuiDB.trackedBars.hideMounted == nil then
        SfuiDB.trackedBars.hideMounted = cfg.hideMounted ~= nil and cfg.hideMounted or true
    end

    -- Position
    sfui.trackedbars.UpdatePosition()

    -- Event listener for visibility updates
    sfui.events.RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if SyncWithBlizzard then SyncWithBlizzard() end
    end)
    sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if SyncWithBlizzard then SyncWithBlizzard() end
    end)
    sfui.events.RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED", function()
        if SyncWithBlizzard then SyncWithBlizzard() end
    end)

    -- Throttled OnUpdate for smooth bar progress AND structure updates
    local syncThrottle = 0
    sfui.events.RegisterUpdate(cfg.updateThrottle or 0.05, function(elapsed)
        -- 1. Visual Updates (Smooth, higher frequency based on config)
        if BuffBarCooldownViewer and BuffBarCooldownViewer.itemFramePool then
            pcall(UpdateBarsState)
        end

        -- 2. Structure/Visibility Sync (Throttled, lower frequency)
        if sfui.trackedbars.isDirty then
            syncThrottle = syncThrottle + elapsed
            -- 0.05s delay allows grouping multiple events (e.g. entering world/combat) into one redraw
            if syncThrottle > 0.05 then
                sfui.trackedbars.isDirty = false
                syncThrottle = 0
                ProcessBlizzardSync()
            end
        end
    end)

    -- Event-driven updates
    -- Hook into Blizzard's frames for instant updates (ArcUI approach)
    if BuffBarCooldownViewer and BuffBarCooldownViewer.itemFramePool then
        hooksecurefunc(BuffBarCooldownViewer.itemFramePool, "Acquire", function(_, frame)
            HookBlizzardFrame(frame)
        end)
        -- Hook existing frames
        for frame in BuffBarCooldownViewer.itemFramePool:EnumerateActive() do
            HookBlizzardFrame(frame)
        end
    end

    -- Register UNIT_AURA event for instant stack updates (12.0.1.65867+)


    -- Hide Blizzard Frame
    if BuffBarCooldownViewer then
        -- Only hide, don't aggressively move/scale/strata it.
        -- The alpha(0) is enough to make it invisible.
        BuffBarCooldownViewer:SetAlpha(0)
        BuffBarCooldownViewer:EnableMouse(false)
        hooksecurefunc(BuffBarCooldownViewer, "Show", function(self)
            self:SetAlpha(0)
            self:EnableMouse(false)
        end)
        if BuffBarCooldownViewer:IsShown() then
            BuffBarCooldownViewer:SetAlpha(0)
            BuffBarCooldownViewer:EnableMouse(false)
        end
    end

    -- Hide Blizzard Cooldown Frames
    if common.hide_blizzard_cooldown_viewers then
        common.hide_blizzard_cooldown_viewers()
    end

    -- Hook into bars state for attachment updates
    if sfui.bars then
        local _pendingLayoutTimer = false
        hooksecurefunc(sfui.bars, "on_state_changed", function()
            if _pendingLayoutTimer then return end
            _pendingLayoutTimer = true
            -- Delay slightly to ensure bars have hidden/shown
            C_Timer.After(0.05, function()
                _pendingLayoutTimer = false
                if sfui.trackedbars and sfui.trackedbars.ForceLayoutUpdate then
                    sfui.trackedbars.ForceLayoutUpdate()
                end
            end)
        end)
    end
end
