local addonName, addon = ...
sfui.gear = {}

local cfg = sfui.config
local common = sfui.common
local _G = _G
local CreateFrame = _G.CreateFrame
local InCombatLockdown = _G.InCombatLockdown
local UnitCastingInfo = _G.UnitCastingInfo
local UnitChannelInfo = _G.UnitChannelInfo
local UnitIsDeadOrGhost = _G.UnitIsDeadOrGhost
local C_EquipmentSet = _G.C_EquipmentSet
local GetInstanceInfo = _G.GetInstanceInfo
local C_PvP = _G.C_PvP
local C_Timer = _G.C_Timer
local GetNumSpecializations = _G.GetNumSpecializations
local GetSpecializationInfo = _G.GetSpecializationInfo
local UIParent = _G.UIParent
local CharacterFrame = _G.CharacterFrame
local CharacterFrameCloseButton = _G.CharacterFrameCloseButton
local print = _G.print
local ipairs = _G.ipairs
local type = _G.type
local table = _G.table
local GetInventoryItemLink = _G.GetInventoryItemLink
local GetItemInfoInstant = _G.GetItemInfoInstant
local IsShiftKeyDown = _G.IsShiftKeyDown

local function show_tooltip(owner, anchor, title, lines)
    local tip = sfui.tooltip or _G.GameTooltip
    if not tip or not owner then return end
    tip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    if title then
        tip:SetText(title)
    end
    if lines then
        for _, line in ipairs(lines) do
            if type(line) == "table" then
                tip:AddLine(line[1], line[2], line[3], line[4], line[5])
            else
                tip:AddLine(line)
            end
        end
    end
    tip:Show()
end

local function show_item_tooltip(owner, itemID, anchor, extraLines)
    local tip = sfui.tooltip or _G.GameTooltip
    if not tip or not owner or not itemID then return end
    tip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    tip:SetItemByID(itemID)
    if extraLines then
        for _, line in ipairs(extraLines) do
            if type(line) == "table" then
                tip:AddLine(line[1], line[2], line[3], line[4], line[5])
            else
                tip:AddLine(line)
            end
        end
    end
    tip:Show()
end

local function hide_tooltip()
    if sfui.tooltip then sfui.tooltip:Hide() end
    if _G.GameTooltip and _G.GameTooltip:IsShown() then
        _G.GameTooltip:Hide()
    end
end



local gearEquipQueue = nil
-- P1: debounce BAG_UPDATE_DELAYED so rapid bag changes don't fire full scans repeatedly
local bagUpdatePending = false
local zoneUpdateQueue = false
-- Guard: prevents stacking C_Timer.After(Update) calls during prolonged casts
local updateScheduled = false
-- Counter: caps PLAYER_REGEN_ENABLED retry depth after combat
local regenRetries = 0

-- Manual-edit protection: suppress BAG_UPDATE auto-equip while player is managing gear
local manualEditUntil = 0
local GetTime = _G.GetTime

--- Call this to pause automatic equipping from bag changes for `sec` seconds (default 60).
--- Opening the CharacterFrame also triggers this automatically.
sfui.gear.pauseAutoEquip = function(sec)
    manualEditUntil = GetTime() + (sec or 10)
end

local function autoEquipPaused()
    return GetTime() < manualEditUntil or (CharacterFrame and CharacterFrame:IsShown() == true)
end

local function isCurrentlyPvP()
    local _, instanceType = GetInstanceInfo()
    local isWarMode = C_PvP.IsWarModeDesired()
    return (instanceType == "pvp" or instanceType == "arena")
        or (instanceType == "none" and isWarMode)
end

-- Returns true if the correct gear set for the current zone/spec is already equipped,
-- meaning EquipHighestILvl must NOT override it.
local function isGearSetEquipped()
    if not SfuiDB.gear then return false end
    local spec = common and common.get_current_spec_id and common.get_current_spec_id()
    if not spec or spec == 0 then return false end
    local db = SfuiDB.gear[spec]
    if not db then return false end

    local _, instanceType = GetInstanceInfo()
    local isWarMode = C_PvP.IsWarModeDesired()
    local targetSet
    if instanceType == "pvp" or instanceType == "arena" then
        targetSet = db.pvp_set
    elseif instanceType == "party" or instanceType == "raid" or instanceType == "scenario" or instanceType == "delve" then
        targetSet = db.pve_set
    elseif instanceType == "none" then
        targetSet = isWarMode and db.pvp_set or db.pve_set
    end
    if not targetSet or targetSet == "" then return false end

    local setID = C_EquipmentSet.GetEquipmentSetID(targetSet)
    if not setID then return false end
    local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
    return isEquipped == true
end

-- Unified auto-equip enable check.
-- Reads from the global SfuiDB.gear.auto_equip_highest toggle (set by both
-- the gear manager "Enable" checkbox and the options panel checkbox).
-- Defaults to true when nil (first-time users get auto-equip enabled).
local function isAutoEquipEnabled()
    if not SfuiDB or not SfuiDB.gear then return false end
    local v = SfuiDB.gear.auto_equip_highest
    if v == nil then return true end -- default: enabled
    return v
end

local function setAutoEquipEnabled(val)
    SfuiDB = SfuiDB or {}
    SfuiDB.gear = SfuiDB.gear or {}
    SfuiDB.gear.auto_equip_highest = val
end

local function _OnUpdateCastTimer()
    updateScheduled = false
    if sfui.gear and sfui.gear.Update then
        sfui.gear.Update()
    end
end

local function TryEquipSet(setName)
    if not setName or setName == "" then return false end
    local setID = C_EquipmentSet.GetEquipmentSetID(setName)
    if setID then
        local name, icon, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if isEquipped then return false end
        if InCombatLockdown() then
            if not gearEquipQueue then
                -- We only register this transiently when an equip is queued
                sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED", sfui.gear.handle_player_regen)
            end
            gearEquipQueue = setID
            return false
        end
        if UnitCastingInfo("player") or UnitChannelInfo("player") then
            -- Defers the update; guard prevents stacking timers during casts
            if not updateScheduled then
                updateScheduled = true
                C_Timer.After(0.25, _OnUpdateCastTimer)
            end
            return false
        end
        if UnitIsDeadOrGhost("player") then
            return false
        end
        C_EquipmentSet.UseEquipmentSet(setID)
        if common and common.print then
            common.print("Automatically equipped set: " .. name)
        else
            print("|cff6600ffsfui:|r Automatically equipped set: " .. name)
        end
        return true
    end
    return false
end

-- P4: pre-allocated scratch list with 4 fixed sub-tables; reused to avoid per-call allocation
local pawnScratchList = {
    { stat = "", weight = 0 }, { stat = "", weight = 0 },
    { stat = "", weight = 0 }, { stat = "", weight = 0 },
}
local function pawnSortDesc(a, b) return a.weight > b.weight end

local statAbbrv    = { Haste = "H", Mastery = "M", Versatility = "V", Crit = "C", H = "H", M = "M", V = "V", C = "C" }
local statPool     = { "H", "M", "V", "C" }
local statBgColors = {
    Haste = { 0.05, 0.40, 0.05, 0.9 },
    H = { 0.05, 0.40, 0.05, 0.9 },
    Mastery = { 0.45, 0.38, 0.02, 0.9 },
    M = { 0.45, 0.38, 0.02, 0.9 },
    Versatility = { 0.03, 0.40, 0.48, 0.9 },
    V = { 0.03, 0.40, 0.48, 0.9 },
    Crit = { 0.48, 0.04, 0.04, 0.9 },
    C = { 0.48, 0.04, 0.04, 0.9 },
    None = { 0.12, 0.12, 0.12, 0.9 },
}

-- Unified PvE / PvP lock colors (used for labels, buttons, tooltips)
local PVE_COLOR  = { 0.45, 0.65, 1.0 }  -- blue
local PVP_COLOR  = { 1.0,  0.4,  0.4 }  -- red
local BOTH_COLOR = { 0.72, 0.52, 1.0 }  -- purple

sfui.gear.TANK_SPECS = {
    [250] = true, -- Blood DK
    [581] = true, -- Vengeance DH
    [104] = true, -- Guardian Druid
    [268] = true, -- Brewmaster Monk
    [66]  = true, -- Protection Paladin
    [73]  = true, -- Protection Warrior
}

local claimedItemIDs = {}
local columnOccupied = {}
local pawnOrderScratch = {}
local curOrderScratch = {}

local function updateIconRow(icons, lockTbl, forPvP)
    if not icons then return end

    -- Initialize all icons to hidden and nil
    for _, ico in ipairs(icons) do
        ico.tex:SetTexture(nil)
        ico.itemID = nil
        ico:Hide()
    end

    if not lockTbl then return end

    local slotOrder = { 13, 14, 11, 12, 2, 16, 17 }
    _G.wipe(claimedItemIDs)
    _G.wipe(columnOccupied)

    -- Step 1: Populate currently equipped locked items in their respective columns
    for colIdx, slotID in ipairs(slotOrder) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local itemID = GetItemInfoInstant(link)
            if itemID and lockTbl[itemID] then
                local ico = icons[colIdx]
                if ico then
                    local nativeIcon = select(5, GetItemInfoInstant(link))
                    local tex = nativeIcon or
                        ((_G.C_Item and _G.C_Item.GetItemIconByID) and _G.C_Item.GetItemIconByID(itemID)) or
                        _G.GetItemIcon(itemID)
                    ico.tex:SetTexture(tex)
                    ico.itemID = itemID
                    ico:Show()

                    claimedItemIDs[itemID] = true
                    columnOccupied[colIdx] = true
                end
            end
        end
    end

    -- Step 2: Populate remaining locked items (in bags) to empty columns of the same category
    local function getSlotCategory(slotID)
        if slotID == 13 or slotID == 14 then return "TRINKET"
        elseif slotID == 11 or slotID == 12 then return "FINGER"
        elseif slotID == 2 then return "NECK"
        elseif slotID == 16 then return "MAINHAND"
        elseif slotID == 17 then return "OFFHAND"
        end
        return "UNKNOWN"
    end

    local function matchesSlotCategory(equipLoc, category)
        if category == "TRINKET" then
            return equipLoc == "INVTYPE_TRINKET"
        elseif category == "FINGER" then
            return equipLoc == "INVTYPE_FINGER"
        elseif category == "NECK" then
            return equipLoc == "INVTYPE_NECK"
        elseif category == "MAINHAND" then
            return equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND" 
                or equipLoc == "INVTYPE_2HWEAPON" or equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT"
        elseif category == "OFFHAND" then
            return equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND" 
                or equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE"
        end
        return false
    end

    for lockedID in pairs(lockTbl) do
        if not claimedItemIDs[lockedID] then
            local _, _, _, equipLoc, nativeIcon = GetItemInfoInstant(lockedID)
            if equipLoc then
                -- Find an empty column that matches this category
                for colIdx, slotID in ipairs(slotOrder) do
                    if not columnOccupied[colIdx] then
                        local category = getSlotCategory(slotID)
                        if matchesSlotCategory(equipLoc, category) then
                            local ico = icons[colIdx]
                            if ico then
                                local tex = nativeIcon or
                                    ((_G.C_Item and _G.C_Item.GetItemIconByID) and _G.C_Item.GetItemIconByID(lockedID)) or
                                    _G.GetItemIcon(lockedID)
                                ico.tex:SetTexture(tex)
                                ico.itemID = lockedID
                                ico:Show()

                                claimedItemIDs[lockedID] = true
                                columnOccupied[colIdx] = true
                                break -- move to next locked item
                            end
                        end
                    end
                end
            end
        end
    end
end

-- -------------------------------------------------------------------------
-- UPDATE STAT UI
-- -------------------------------------------------------------------------
function sfui.gear.UpdateStatUI()
    if not SfuiGearManagerFrame or not SfuiGearManagerFrame:IsShown() then return end

    if SfuiGearManagerFrame.maxLvlChk then
        SfuiGearManagerFrame.maxLvlChk:SetChecked(isAutoEquipEnabled())
    end

    -- Status label: shows what gear mode is currently active
    if SfuiGearManagerFrame.statusLabel then
        local lbl = SfuiGearManagerFrame.statusLabel
        local spec = common and common.get_current_spec_id and common.get_current_spec_id()
        local db = spec and spec ~= 0 and SfuiDB.gear and SfuiDB.gear[spec]
        local _, instanceType = GetInstanceInfo()
        local isWarMode = C_PvP and C_PvP.IsWarModeDesired and C_PvP.IsWarModeDesired()

        local isPvP = (instanceType == "pvp" or instanceType == "arena")
            or (instanceType == "none" and isWarMode)
        local targetSet = nil
        if db then
            if instanceType == "pvp" or instanceType == "arena" then
                targetSet = db.pvp_set
            elseif instanceType == "party" or instanceType == "raid" or instanceType == "scenario" or instanceType == "delve" then
                targetSet = db.pve_set
            elseif instanceType == "none" then
                targetSet = isWarMode and db.pvp_set or db.pve_set
            end
        end

        local text, r, g, b
        if targetSet and targetSet ~= "" then
            local setID = C_EquipmentSet.GetEquipmentSetID(targetSet)
            local isEquipped = setID and select(4, C_EquipmentSet.GetEquipmentSetInfo(setID))
            local checkmark = isEquipped and " \xE2\x9C\x93" or ""
            text = (isPvP and "PvP" or "PvE") .. ": " .. targetSet .. checkmark
            local baseColor = isPvP and PVP_COLOR or PVE_COLOR
            r, g, b = isEquipped and 0 or baseColor[1], isEquipped and 1 or baseColor[2], isEquipped and 1 or baseColor[3]
        else
            text = isPvP and "PvP" or "PvE"
            r, g, b = 0.55, 0.55, 0.55
        end

        lbl:SetText(text)
        lbl:SetTextColor(r, g, b)
    end

    local numSpecs = GetNumSpecializations()
    if numSpecs == 0 then numSpecs = 1 end

    for i = 1, numSpecs do
        local specID = GetSpecializationInfo(i)
        if specID and SfuiGearManagerFrame.specUIs and SfuiGearManagerFrame.specUIs[specID] then
            local ui = SfuiGearManagerFrame.specUIs[specID]
            local db = SfuiDB.gear[specID] or {}
            SfuiDB.gear[specID] = db

            if ui.pawnEdit then ui.pawnEdit:SetText(db.pawn_string or "") end

            -- locked item icons: PvE (above) and PvP (underneath), persisting even when unequipped
            updateIconRow(ui.pveLockIcons, db.locked_items_pve, false)
            updateIconRow(ui.pvpLockIcons, db.locked_items_pvp, true)

            -- update lock button border, backdrop & text color based on PvE/PvP lock state
            if ui.lockBtns then
                for _, entry in ipairs(ui.lockBtns) do
                    local btn, slotID = entry.btn, entry.slotID
                    local link = GetInventoryItemLink("player", slotID)
                    local pveLocked, pvpLocked = false, false
                    if link then
                        local iid = GetItemInfoInstant(link)
                        if iid then
                            pveLocked = db.locked_items_pve and db.locked_items_pve[iid] or false
                            pvpLocked = db.locked_items_pvp and db.locked_items_pvp[iid] or false
                        end
                    end
                    local c = nil
                    if pveLocked and pvpLocked then
                        c = BOTH_COLOR
                    elseif pveLocked then
                        c = PVE_COLOR
                    elseif pvpLocked then
                        c = PVP_COLOR
                    end
                    btn.lockColor = c
                    local fs = btn:GetFontString()
                    if c then
                        btn:SetBackdropBorderColor(c[1], c[2], c[3], 1.0)
                        btn:SetBackdropColor(c[1] * 0.25, c[2] * 0.25, c[3] * 0.25, 0.9)
                        if fs then fs:SetTextColor(c[1], c[2], c[3], 1.0) end
                    else
                        local gray = cfg.colors.gray
                        btn:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.6)
                        btn:SetBackdropColor(0, 0, 0, 0.8)
                        local white = cfg.colors.white
                        if fs then fs:SetTextColor(white[1], white[2], white[3], 0.85) end
                    end
                end
            end

            -- tier force button coloring (cyan backdrop = enabled)
            if ui.btn2S then
                local on = db.force_2set
                if on then
                    ui.btn2S:SetBackdropColor(0, 0.5, 0.5, 1)
                else
                    ui.btn2S:SetBackdropColor(unpack(cfg.colors.black))
                end
            end
            if ui.btn4S then
                local on = (db.force_4set ~= false) and not db.force_2set
                if on then
                    ui.btn4S:SetBackdropColor(0, 0.5, 0.5, 1)
                else
                    ui.btn4S:SetBackdropColor(unpack(cfg.colors.black))
                end
            end
            if ui.btnILvl then
                local isTank = (sfui.gear.TANK_SPECS and sfui.gear.TANK_SPECS[specID]) or false
                local on = db.armor_ilvl_prio
                if on == nil then on = isTank end
                if on then
                    ui.btnILvl:SetBackdropColor(0, 0.5, 0.5, 1)
                else
                    ui.btnILvl:SetBackdropColor(unpack(cfg.colors.black))
                end
            end

            -- stat priority
            if ui.manBtns then
                local hasSet   = db.pve_set and db.pve_set ~= ""
                local alpha    = hasSet and 0.35 or 1.0

                local targetDB = db
                local pawnOrder
                if targetDB.pawn_weights and not hasSet then
                    -- P4: reuse pre-allocated sub-tables; no allocation in hot path
                    local n = 0
                    for k, v in pairs(targetDB.pawn_weights) do
                        local sName = k:gsub("Rating", "")
                        if sName == "Haste" or sName == "Mastery" or sName == "Versatility" or sName == "Crit" then
                            n = n + 1
                            local e = pawnScratchList[n]
                            if not e then e = { stat = "", weight = 0 }; pawnScratchList[n] = e end
                            e.stat = sName; e.weight = v
                        end
                    end
                    for i = n + 1, #pawnScratchList do pawnScratchList[i] = nil end
                    table.sort(pawnScratchList, pawnSortDesc)
                    _G.wipe(pawnOrderScratch)
                    for j = 1, math.min(4, n) do table.insert(pawnOrderScratch, pawnScratchList[j].stat) end
                    pawnOrder = #pawnOrderScratch > 0 and pawnOrderScratch or nil
                end

                local order  = pawnOrder or targetDB.stat_order or db.stat_order or
                (sfui.default_stats and sfui.default_stats[tonumber(specID)]) or { "H", "M", "V", "C" }
                local equals = targetDB.stat_equals or db.stat_equals or { true, false, false }

                for j = 1, 4 do
                    local st = order[j] or "None"
                    ui.manBtns[j]:SetText(statAbbrv[st] or st:sub(1, 1))
                    local c = statBgColors[st]
                    if c then ui.manBtns[j]:SetBackdropColor(c[1], c[2], c[3], c[4]) end
                    ui.manBtns[j]:SetAlpha(alpha)
                    if j < 4 then
                        if ui.manTgls[j] and ui.manTgls[j].SetText then
                            ui.manTgls[j]:SetText(equals[j] and "=" or ">")
                        end
                    end
                end

                if ui.setActiveLabel then ui.setActiveLabel:SetShown(hasSet) end
            end
        end
    end
end

-- -------------------------------------------------------------------------
-- GEAR UPDATE (AUTO EQUIP)
-- -------------------------------------------------------------------------
function sfui.gear.Update(force)
    if not SfuiDB.gear then return end
    local spec = common.get_current_spec_id()
    if spec == 0 then return end
    local db = SfuiDB.gear[spec] -- may be nil if never configured

    local pveSet = db and db.pve_set or ""
    local pvpSet = db and db.pvp_set or ""
    local _, instanceType = GetInstanceInfo()
    local isWarMode = C_PvP.IsWarModeDesired()

    -- Authoritative isPvP: derived from zone + war mode, not from set names
    local isPvP = (instanceType == "pvp" or instanceType == "arena")
        or (instanceType == "none" and isWarMode)

    -- Which configured named set should be active in this context (nil = none configured)
    local targetSet = nil
    if instanceType == "pvp" or instanceType == "arena" then
        targetSet = pvpSet ~= "" and pvpSet or nil
    elseif instanceType == "party" or instanceType == "raid" or instanceType == "scenario" or instanceType == "delve" then
        targetSet = pveSet ~= "" and pveSet or nil
    elseif instanceType == "none" then
        targetSet = isPvP and (pvpSet ~= "" and pvpSet or nil) or (pveSet ~= "" and pveSet or nil)
    end

    -- PvE/PvP set swap: ALWAYS active regardless of the max-level auto-equip toggle.
    -- TryEquipSet returns true when it actually triggered an equip.
    local setEquipped = false
    if targetSet then
        setEquipped = TryEquipSet(targetSet)
    end

    -- If we just triggered a set equip, bail — EquipHighestILvl would conflict.
    if setEquipped then return end

    -- If the correct set is already equipped, also skip EquipHighestILvl UNLESS forced.
    if not force and isGearSetEquipped() then return end

    -- EquipHighestILvl is gated by the manual-edit pause UNLESS forced (e.g. spec change).
    if not force and autoEquipPaused() then return end

    if UnitCastingInfo("player") or UnitChannelInfo("player") then
        if not updateScheduled then
            updateScheduled = true
            C_Timer.After(0.25, _OnUpdateCastTimer)
        end
        return
    end

    if sfui.highest and sfui.highest.EquipHighestILvl
        and not InCombatLockdown()
        and not UnitIsDeadOrGhost("player") then
        local shouldEquip = isAutoEquipEnabled()
        if shouldEquip or force then
            sfui.highest.EquipHighestILvl(isPvP, true)
        end
    end
end

-- P5: cache equipment set options; invalidated when sets change
local equipSetOptionsCache = nil

-- -------------------------------------------------------------------------
-- EVENT HANDLERS
-- -------------------------------------------------------------------------
sfui.events.RegisterEvent("EQUIPMENT_SETS_CHANGED", function()
    equipSetOptionsCache = nil
end)

local lastEquippedItems = {}

local function scanEquippedForChanges()
    if not SfuiDB or not SfuiDB.gear then return end

    local spec = common and common.get_current_spec_id and common.get_current_spec_id()
    if not spec or spec == 0 then return end

    for slotID = 1, 17 do
        if slotID ~= 4 then
            local link = GetInventoryItemLink("player", slotID)
            local currentID = link and GetItemInfoInstant(link)
            lastEquippedItems[slotID] = currentID
        end
    end

    if sfui.gear.UpdateStatUI then
        sfui.gear.UpdateStatUI()
    end
end

sfui.events.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function()
    equipSetOptionsCache = nil
    scanEquippedForChanges()
end)

local function _OnRegenRetryTimer()
    if gearEquipQueue and not InCombatLockdown() then
        sfui.gear.handle_player_regen()
    end
end

function sfui.gear.handle_player_regen()
    if gearEquipQueue then
        if not UnitCastingInfo("player") and not UnitChannelInfo("player") and not UnitIsDeadOrGhost("player") then
            local name = C_EquipmentSet.GetEquipmentSetInfo(gearEquipQueue)
            C_EquipmentSet.UseEquipmentSet(gearEquipQueue)
            if name and common and common.print then
                common.print("Equipped queued set: " .. name)
            end
            gearEquipQueue = nil
            regenRetries = 0
            sfui.events.UnregisterEvent("PLAYER_REGEN_ENABLED", sfui.gear.handle_player_regen)
        elseif regenRetries < 5 then
            -- Still casting post-combat: retry up to 5 times (10 s total) then give up
            regenRetries = regenRetries + 1
            C_Timer.After(2, _OnRegenRetryTimer)
        else
            -- Give up: discard the queued set equip
            gearEquipQueue = nil
            regenRetries = 0
            sfui.events.UnregisterEvent("PLAYER_REGEN_ENABLED", sfui.gear.handle_player_regen)
        end
    end
end

local function _OnBagUpdateTimer()
    bagUpdatePending = false
    -- Fix 1: respect manual-edit pause (CharacterFrame open / explicit pause)
    if autoEquipPaused() then return end
    -- Fix 2: if a gear set is configured AND equipped, don't override it
    if isGearSetEquipped() then return end
    
    local shouldEquip = isAutoEquipEnabled()
    if shouldEquip and sfui.highest and sfui.highest.EquipHighestILvl
        and not InCombatLockdown()
        and not UnitCastingInfo("player")
        and not UnitChannelInfo("player")
        and not UnitIsDeadOrGhost("player") then
        local isPvP = false
        local _, instanceType = GetInstanceInfo()
        if instanceType == "pvp" or instanceType == "arena" or (instanceType == "none" and C_PvP.IsWarModeDesired()) then
            isPvP = true
        end
        sfui.highest.EquipHighestILvl(isPvP, true)
    end
    -- UpdateStatUI shifted securely into the debounce block
    if sfui.gear.UpdateStatUI then sfui.gear.UpdateStatUI() end
end

sfui.events.RegisterEvent("BAG_UPDATE_DELAYED", function()
    -- [BAG_UPDATE_DELAYED Throttle Lock]
    -- Why lock for 2 seconds?
    -- This event fires violently rapidly when moving items, looting multiple items, or sorting bags.
    -- We lock (debounce) the auto-equip queue here for precisely 2 seconds so the inventory
    -- state can fully settle. This strictly prevents the CPU from re-scanning all 144 bag slots
    -- repeatedly every micro-second, and stops the UI from aggressively swapping gear while
    -- you are actively trying to organize your inventory.
    if not bagUpdatePending then
        bagUpdatePending = true
        C_Timer.After(2, _OnBagUpdateTimer)
    end
end)

local function _OnPlayerFlagsTimer()
    if sfui.gear and sfui.gear.Update then
        sfui.gear.Update()
    end
end

sfui.events.RegisterEvent("PLAYER_FLAGS_CHANGED", function(event, unit)
    if unit ~= "player" then return end
    local delay = (cfg and cfg.gear and cfg.gear.updateDelay) or 3
    C_Timer.After(delay, _OnPlayerFlagsTimer)
end)

local function doSpecSwap()
    if InCombatLockdown and InCombatLockdown() then return end
    local _, instanceType = GetInstanceInfo()
    local isWarMode = C_PvP.IsWarModeDesired()
    local isPvP = (instanceType == "pvp" or instanceType == "arena") or (instanceType == "none" and isWarMode)

    sfui.gear.Update(true)
    if sfui.highest and sfui.highest.EquipHighestILvl then
        sfui.highest.EquipHighestILvl(isPvP, true)
    end
end

local function handle_spec_change(event, unit)
    if (event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UNIT_SPELLCAST_SUCCEEDED") and unit and unit ~= "player" then return end
    
    -- Clear validity cache on specialization change
    if sfui.highest and sfui.highest.ClearCache then
        sfui.highest.ClearCache()
    end
    
    -- Force clear manual edit pause
    manualEditUntil = 0

    -- Execute immediately and schedule staggered sync ticks
    doSpecSwap()
    C_Timer.After(0.15, doSpecSwap)
    C_Timer.After(0.40, doSpecSwap)

    if SfuiGearManagerFrame and SfuiGearManagerFrame.SelectSpecTab then
        local specIdx = GetSpecialization()
        local specId = specIdx and GetSpecializationInfo(specIdx)
        if specId then SfuiGearManagerFrame:SelectSpecTab(specId) end
    end
end
sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", handle_spec_change)
sfui.events.RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", handle_spec_change)
sfui.events.RegisterEvent("TRAIT_CONFIG_UPDATED", handle_spec_change)
sfui.events.RegisterEvent("SPEC_INVOLUNTARILY_CHANGED", handle_spec_change)
sfui.events.RegisterEvent("PLAYER_TALENT_UPDATE", function()
    if sfui.highest and sfui.highest.ClearCache then
        sfui.highest.ClearCache()
    end
end)

local function _OnZoneChangeTimer()
    zoneUpdateQueue = false
    if sfui.gear and sfui.gear.Update then
        sfui.gear.Update()
    end
end

local function handle_zone_change()
    if not zoneUpdateQueue then
        zoneUpdateQueue = true
        C_Timer.After(0.5, _OnZoneChangeTimer)
    end
end
sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", handle_zone_change)
sfui.events.RegisterEvent("ZONE_CHANGED_NEW_AREA", handle_zone_change)


-- B2: ADDON_LOADED registration removed (InitToggleHook called at login via PLAYER_LOGIN)

-- -------------------------------------------------------------------------
-- GEAR MANAGER FRAME
-- -------------------------------------------------------------------------
local gearFrame = CreateFrame("Frame", "SfuiGearManagerFrame", UIParent, "BackdropTemplate")
gearFrame:SetPoint("CENTER")
gearFrame:SetMovable(true)
gearFrame:EnableMouse(true)
gearFrame:RegisterForDrag("LeftButton")
gearFrame:SetScript("OnDragStart", gearFrame.StartMoving)
gearFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Force TOPLEFT absolute anchoring so the frame always unfolds downwards
    local left = self:GetLeft()
    local top = self:GetTop()
    if left and top then
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
    SfuiDB = SfuiDB or {}
    SfuiDB.gear_pos = {
        point = point,
        relativePoint = relativePoint,
        x = xOfs,
        y = yOfs
    }
end)
gearFrame:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
gearFrame:SetBackdropColor(0.055, 0.055, 0.055, 0.97)
gearFrame:Hide()
gearFrame:SetFrameStrata("DIALOG")

local closeBtn = common.create_flat_button(gearFrame, "X", 20, 20)
closeBtn:SetPoint("TOPRIGHT", gearFrame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() gearFrame:Hide() end)

local collapseBtn = common.create_flat_button(gearFrame, "-", 20, 20)
collapseBtn:SetPoint("TOPRIGHT", gearFrame, "TOPRIGHT", -30, -5)
collapseBtn:SetScript("OnClick", function()
    -- Lock header rigidly in place by migrating active anchor to TOPLEFT on first collapse
    local left = gearFrame:GetLeft()
    local top = gearFrame:GetTop()
    if left and top then
        gearFrame:ClearAllPoints()
        gearFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end

    gearFrame.collapsed = not gearFrame.collapsed
    SfuiDB = SfuiDB or {}
    SfuiDB.gear_collapsed = gearFrame.collapsed

    if gearFrame.collapsed then
        collapseBtn:SetText("+")
        if gearFrame.content then gearFrame.content:Hide() end
        gearFrame:SetHeight(42) -- specific header height
    else
        collapseBtn:SetText("-")
        if gearFrame.content then gearFrame.content:Show() end
        gearFrame:SetHeight(gearFrame.expandedHeight or 162)
    end
end)

-- Main content container for body children
gearFrame.content = CreateFrame("Frame", nil, gearFrame, "BackdropTemplate")
gearFrame.content:SetPoint("TOPLEFT", gearFrame, "TOPLEFT", 0, -42)
gearFrame.content:SetPoint("BOTTOMRIGHT", gearFrame, "BOTTOMRIGHT")
gearFrame.content:Show()

local function GetEquipmentSetOptions()
    if equipSetOptionsCache then return equipSetOptionsCache end
    local options = { { text = "None", value = "" } }
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if setIDs then
        for _, id in ipairs(setIDs) do
            local name = C_EquipmentSet.GetEquipmentSetInfo(id)
            if name then table.insert(options, { text = name, value = name }) end
        end
    end
    equipSetOptionsCache = options
    return options
end


-- -------------------------------------------------------------------------
-- HELPER: styled edit box (no border)
-- -------------------------------------------------------------------------
local function makeEditBox(parent, w, h)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(w, h)
    eb:SetAutoFocus(false)
    eb:SetNumeric(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(4, 4, 0, 0)
    local app = cfg.appearance
    eb:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
    eb:SetBackdropColor(app.editBoxColor[1], app.editBoxColor[2], app.editBoxColor[3], app.editBoxColor[4])
    eb:SetScript("OnEditFocusGained", function(s)
        s:SetBackdropColor(app.highlightColor[1] * 0.3, app.highlightColor[2] * 0.3, app.highlightColor[3] * 0.3, 0.9)
    end)
    eb:SetScript("OnEditFocusLost", function(s)
        s:SetBackdropColor(app.editBoxColor[1], app.editBoxColor[2], app.editBoxColor[3], app.editBoxColor[4])
    end)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    return eb
end

-- -------------------------------------------------------------------------
-- HELPER: small font string label
-- -------------------------------------------------------------------------
local function mkLabel(parent, txt, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(txt)
    fs:SetShadowOffset(0, 0)
    fs:SetTextColor(r or 0.55, g or 0.55, b or 0.55)
    return fs
end

-- Global Header UI Configuration
gearFrame.highPvE = common.create_flat_button(gearFrame, "PvE", 40, 18)
gearFrame.highPvE:SetPoint("TOPLEFT", gearFrame, "TOPLEFT", 150, -11)
gearFrame.highPvE:SetScript("OnClick", function()
    if sfui.highest and sfui.highest.EquipHighestILvl then sfui.highest.EquipHighestILvl(false) end
end)

gearFrame.highPvP = common.create_flat_button(gearFrame, "PvP", 40, 18)
gearFrame.highPvP:SetPoint("TOPLEFT", gearFrame, "TOPLEFT", 195, -11)
gearFrame.highPvP:SetScript("OnClick", function()
    if sfui.highest and sfui.highest.EquipHighestILvl then sfui.highest.EquipHighestILvl(true) end
end)

gearFrame.statusLabel = gearFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
gearFrame.statusLabel:SetPoint("LEFT", gearFrame.highPvP, "RIGHT", 10, 0)
gearFrame.statusLabel:SetJustifyH("LEFT")
gearFrame.statusLabel:SetShadowOffset(0, 0)
gearFrame.statusLabel:SetText("")

gearFrame.maxLvlChk = common.create_checkbox(gearFrame, "Enable",
    function() return isAutoEquipEnabled() end,
    function(c)
        setAutoEquipEnabled(c)
        if c then sfui.gear.Update() end
    end)
gearFrame.maxLvlChk:SetPoint("TOPLEFT", gearFrame, "TOPLEFT", 360, -9)
gearFrame.maxLvlChk.text:SetShadowOffset(0, 0)

-- -------------------------------------------------------------------------
-- ON SHOW: build per-spec cards
-- -------------------------------------------------------------------------
gearFrame:SetScript("OnShow", function(self)
    if not self.posLoaded then
        self.posLoaded = true
        if SfuiDB.gear_pos then
            self:ClearAllPoints()
            self:SetPoint(SfuiDB.gear_pos.point, UIParent, SfuiDB.gear_pos.relativePoint, SfuiDB.gear_pos.x, SfuiDB.gear_pos.y)
            
            -- Convert legacy positional saves cleanly to TOPLEFT bounds if needed
            if SfuiDB.gear_pos.point ~= "TOPLEFT" then
                local left = self:GetLeft()
                local top = self:GetTop()
                if left and top then
                    self:ClearAllPoints()
                    self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
                end
            end
        end
    end
    if sfui.gear.UpdateStatUI then sfui.gear.UpdateStatUI() end
    if self.initialized then
        if self.SelectSpecTab then
            local specIdx = GetSpecialization()
            local specId = specIdx and GetSpecializationInfo(specIdx)
            if specId then self:SelectSpecTab(specId) end
        end
        return
    end
    self.initialized = true
    self.specUIs = {}

    local numSpecs = GetNumSpecializations()
    if numSpecs == 0 then numSpecs = 1 end

    local HEADER_H = 42
    local CARD_H   = 142
    self.expandedHeight = HEADER_H + CARD_H
    
    if SfuiDB and SfuiDB.gear_collapsed ~= nil then
        self.collapsed = SfuiDB.gear_collapsed
    end
    
    if self.collapsed then
        collapseBtn:SetText("+")
        if self.content then self.content:Hide() end
        self:SetSize(490, HEADER_H)
    else
        collapseBtn:SetText("-")
        if self.content then self.content:Show() end
        self:SetSize(490, self.expandedHeight)
    end

    self.tabBtns = self.tabBtns or {}
    local activeSpecId = GetSpecializationInfo(GetSpecialization() or 1)

    self.SelectSpecTab = function(f, specID)
        f.activeSpecID = specID
        for id, ui in pairs(f.specUIs) do
            if id == specID then
                if ui.card then ui.card:Show() end
                if f.tabBtns[id] then f.tabBtns[id]:SetAlpha(1.0) end
            else
                if ui.card then ui.card:Hide() end
                if f.tabBtns[id] then f.tabBtns[id]:SetAlpha(0.3) end
            end
        end
        if sfui.gear.UpdateStatUI then sfui.gear.UpdateStatUI() end
    end

    -- icon helper: clicking unlocks the slot in the respective context
    local function createLockIcon(parent, specId, forPvP)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(22, 22)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(); btn.tex = tex
        btn:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
            edgeFile = "Interface/Buttons/WHITE8X8",
            edgeSize = 1,
        })
        if forPvP then
            btn:SetBackdropBorderColor(PVP_COLOR[1], PVP_COLOR[2], PVP_COLOR[3], 0.7)
        else
            btn:SetBackdropBorderColor(PVE_COLOR[1], PVE_COLOR[2], PVE_COLOR[3], 0.7)
        end
        btn:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(b)
            if b.itemID and SfuiDB.gear[specId] then
                local sdb = SfuiDB.gear[specId]
                local key = forPvP and "locked_items_pvp" or "locked_items_pve"
                if sdb[key] then
                    sdb[key][b.itemID] = nil
                    if common and common.print then
                        local itemLink = select(2, _G.GetItemInfo(b.itemID)) or ("Item " .. b.itemID)
                        common.print(string.format("Unlocked (%s): %s", forPvP and "PvP" or "PvE", itemLink))
                    end
                end
                hide_tooltip()
                sfui.gear.UpdateStatUI()
            end
        end)
        btn:SetScript("OnEnter", function(b)
            if b.itemID then
                local extra = {
                    { string.format("Click to unlock (%s)", forPvP and "PvP" or "PvE"), 1, 0.4, 0.4 }
                }
                show_item_tooltip(b, b.itemID, "ANCHOR_RIGHT", extra)
            end
        end)
        btn:SetScript("OnLeave", function() hide_tooltip() end)
        return btn
    end

    local startX = 10
    for i = 1, numSpecs do
        local id, _, _, icon = GetSpecializationInfo(i)
        if id then
            local btn = CreateFrame("Button", nil, self, "BackdropTemplate")
            btn:SetSize(28, 28)
            btn:SetPoint("TOPLEFT", self, "TOPLEFT", startX, -7)
            local t = btn:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints()
            t:SetTexture(icon)
            t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            btn:SetScript("OnClick", function() self:SelectSpecTab(id) end)
            self.tabBtns[id] = btn
            startX = startX + 32
        end
    end

    local yOff = -5
    for i = 1, numSpecs do
        local id, specName, _, icon = GetSpecializationInfo(i)
        if not id then return end

        self.specUIs[id] = {}
        local ui = self.specUIs[id]

        -- Card (no border, subtle background)
        local card = CreateFrame("Frame", nil, self.content, "BackdropTemplate")
        card:SetSize(470, CARD_H - 4)
        card:SetPoint("TOPLEFT", self.content, "TOPLEFT", 10, yOff)
        card:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
        card:SetBackdropColor(0.09, 0.09, 0.09, 0.88)
        ui.card = card

        local CX = 12 -- left margin for rows

        -- ROW 1: PvE / PvP labels inline with dropdowns
        -- Labels sit at y=-9 (text), dropdowns at y=-5 (slightly taller button)
        local pveTag = mkLabel(card, "PvE", 0.45, 0.65, 1.0)
        pveTag:SetPoint("TOPLEFT", card, "TOPLEFT", CX, -9)

        local pveDrop = common.create_dropdown(card, 120, GetEquipmentSetOptions, function(val)
            SfuiDB.gear[id] = SfuiDB.gear[id] or { pve_set = "", pvp_set = "" }
            SfuiDB.gear[id].pve_set = val
            sfui.gear.Update()
            sfui.gear.UpdateStatUI()
        end, "")
        pveDrop:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 28, -5)
        ui.pveDrop = pveDrop

        local pvpTag = mkLabel(card, "PvP", 1.0, 0.4, 0.4)
        pvpTag:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 165, -9)

        local pvpDrop = common.create_dropdown(card, 120, GetEquipmentSetOptions, function(val)
            SfuiDB.gear[id] = SfuiDB.gear[id] or { pve_set = "", pvp_set = "" }
            SfuiDB.gear[id].pvp_set = val
            sfui.gear.Update()
            sfui.gear.UpdateStatUI()
        end, "")
        pvpDrop:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 193, -5)
        ui.pvpDrop       = pvpDrop
        
        -- ROW 2: Lock section (2 sub-rows)
        -- Sub-row A (icons, y=-38): slot icons shown when locked; click to unlock
        -- Sub-row B (buttons, y=-63): lock toggle buttons, one per slot
        -- Slots: T1(13), T2(14), R1(11), R2(12), A(2), W1(16), W2(17)
        local lockSlots  = {
            { label = "T1", slot = 13 },
            { label = "T2", slot = 14 },
            { label = "R1", slot = 11 },
            { label = "R2", slot = 12 },
            { label = "A", slot = 2 },
            { label = "W1", slot = 16 },
            { label = "W2", slot = 17 },
        }
        local LOCK_COL_W = 26  -- px per column
        local LOCK_START = CX  -- x of first column
        local ICON_ROW_Y = -35 -- y for icon sub-row
        local BTN_ROW_Y  = -60 -- y for button sub-row

        -- "Lock:" label left of first button column
        local lockLabel  = mkLabel(card, "Lock:", 0.50, 0.50, 0.50)
        lockLabel:SetPoint("TOPLEFT", card, "TOPLEFT", CX, BTN_ROW_Y - 1)

        -- lockSlot: toggle lock for the equipped item in the given slot
        local function lockSlot(slot, forPvP)
            local link = GetInventoryItemLink("player", slot)
            if link then
                local itemID = GetItemInfoInstant(link)
                if itemID then
                    SfuiDB.gear[id] = SfuiDB.gear[id] or {}
                    local ldb = SfuiDB.gear[id]
                    ldb.locked_items_pve = ldb.locked_items_pve or {}
                    ldb.locked_items_pvp = ldb.locked_items_pvp or {}
                    local key = forPvP and "locked_items_pvp" or "locked_items_pve"
                    ldb[key] = ldb[key] or {}
                    if ldb[key][itemID] then
                        ldb[key][itemID] = nil
                    else
                        ldb[key][itemID] = true
                    end
                    sfui.gear.UpdateStatUI()
                end
            end
        end

        ui.lockBtns        = {}
        ui.pveLockIcons    = {}
        ui.pvpLockIcons    = {}
        local LOCK_LABEL_W = 38 -- approximate width of "Lock:" label
        for k, def in ipairs(lockSlots) do
            local colX = LOCK_START + LOCK_LABEL_W + (k - 1) * LOCK_COL_W

            -- PvE Icon (above the button, at ICON_ROW_Y = -35)
            local pveIco = createLockIcon(card, id, false)
            pveIco:SetPoint("TOPLEFT", card, "TOPLEFT", colX, -35)
            pveIco:Hide()
            table.insert(ui.pveLockIcons, pveIco)

            -- PvP Icon (below the button, at -82)
            local pvpIco = createLockIcon(card, id, true)
            pvpIco:SetPoint("TOPLEFT", card, "TOPLEFT", colX, -82)
            pvpIco:Hide()
            table.insert(ui.pvpLockIcons, pvpIco)

            -- Button (sub-row B): directly below icon
            local btn = common.create_flat_button(card, def.label, 22, 18)
            btn:SetPoint("TOPLEFT", card, "TOPLEFT", colX, BTN_ROW_Y)
            local capturedSlot = def.slot
            btn:SetScript("OnClick", function() lockSlot(capturedSlot, IsShiftKeyDown()) end)
            btn:SetScript("OnEnter", function(b)
                local cyan = cfg.colors.cyan
                b:SetBackdropBorderColor(cyan[1], cyan[2], cyan[3], 1)
                local link = GetInventoryItemLink("player", capturedSlot)
                if link then
                    local _, itemName = GetItemInfo(link)
                    local iid = GetItemInfoInstant(link)
                    local pveL = iid and SfuiDB.gear[id] and SfuiDB.gear[id].locked_items_pve
                        and SfuiDB.gear[id].locked_items_pve[iid]
                    local pvpL = iid and SfuiDB.gear[id] and SfuiDB.gear[id].locked_items_pvp
                        and SfuiDB.gear[id].locked_items_pvp[iid]
                    local tag = ""
                    if pveL and pvpL then tag = string.format("|cff%02x%02x%02x[PvE+PvP]|r ", BOTH_COLOR[1]*255, BOTH_COLOR[2]*255, BOTH_COLOR[3]*255)
                    elseif pveL then tag = string.format("|cff%02x%02x%02x[PvE]|r ", PVE_COLOR[1]*255, PVE_COLOR[2]*255, PVE_COLOR[3]*255)
                    elseif pvpL then tag = string.format("|cff%02x%02x%02x[PvP]|r ", PVP_COLOR[1]*255, PVP_COLOR[2]*255, PVP_COLOR[3]*255)
                    end
                    show_tooltip(b, "ANCHOR_TOP", tag .. (itemName or link), {
                        { "Click = toggle PvE lock", PVE_COLOR[1], PVE_COLOR[2], PVE_COLOR[3] },
                        { "Shift+Click = toggle PvP lock", PVP_COLOR[1], PVP_COLOR[2], PVP_COLOR[3] },
                    })
                else
                    show_tooltip(b, "ANCHOR_TOP", "Nothing equipped in " .. def.label, {
                        { "Equip an item to toggle its lock state.", 0.6, 0.6, 0.6 }
                    })
                end
            end)
            btn:SetScript("OnLeave", function(b)
                hide_tooltip()
                if b.lockColor then
                    local c = b.lockColor
                    b:SetBackdropBorderColor(c[1], c[2], c[3], 1.0)
                    b:SetBackdropColor(c[1] * 0.25, c[2] * 0.25, c[3] * 0.25, 0.9)
                else
                    local gray = cfg.colors.gray
                    b:SetBackdropBorderColor(gray[1], gray[2], gray[3], 0.6)
                    b:SetBackdropColor(0, 0, 0, 0.8)
                end
            end)
            table.insert(ui.lockBtns, { btn = btn, slotID = def.slot })
        end

        local setActiveLabel = mkLabel(card, "Set active", 0.85, 0.65, 0.1)
        setActiveLabel:SetPoint("TOPLEFT", card, "TOPLEFT",
            LOCK_START + LOCK_LABEL_W + #lockSlots * LOCK_COL_W + 5, BTN_ROW_Y - 1)
        setActiveLabel:Hide()
        ui.setActiveLabel = setActiveLabel

        -- Tier Force Buttons & Armor iLvl Button
        local btn2S = common.create_flat_button(card, "2S", 22, 18)
        btn2S:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 270, BTN_ROW_Y)
        btn2S:SetScript("OnClick", function()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            SfuiDB.gear[id].force_2set = not SfuiDB.gear[id].force_2set
            if SfuiDB.gear[id].force_2set then SfuiDB.gear[id].force_4set = false end -- Mutually exclusive
            sfui.gear.UpdateStatUI()
            sfui.gear.Update()
        end)
        btn2S:SetScript("OnEnter", function(b)
            show_tooltip(b, "ANCHOR_TOP", "Force 2-Piece Tier Set", {
                { "Drafts 2 set pieces into your highest ilvl build, prioritizing lowest ilvl sacrifice.", 0.8, 0.8, 0.8, true }
            })
        end)
        btn2S:SetScript("OnLeave", function() hide_tooltip() end)
        ui.btn2S = btn2S

        local btn4S = common.create_flat_button(card, "4S", 22, 18)
        btn4S:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 295, BTN_ROW_Y)
        btn4S:SetScript("OnClick", function()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            local current = (SfuiDB.gear[id].force_4set ~= false) and not SfuiDB.gear[id].force_2set
            SfuiDB.gear[id].force_4set = not current
            if SfuiDB.gear[id].force_4set then SfuiDB.gear[id].force_2set = false end -- Mutually exclusive
            sfui.gear.UpdateStatUI()
            sfui.gear.Update()
        end)
        btn4S:SetScript("OnEnter", function(b)
            show_tooltip(b, "ANCHOR_TOP", "Force 4-Piece Tier Set", {
                { "Drafts 4 set pieces into your highest ilvl build, prioritizing lowest ilvl sacrifice.", 0.8, 0.8, 0.8, true }
            })
        end)
        btn4S:SetScript("OnLeave", function() hide_tooltip() end)
        ui.btn4S = btn4S

        -- Armor iLvl Force Button (Tanks / General)
        local btnILvl = common.create_flat_button(card, "iLvl", 28, 18)
        btnILvl:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 320, BTN_ROW_Y)
        btnILvl:SetScript("OnClick", function()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            local isTank = (sfui.gear.TANK_SPECS and sfui.gear.TANK_SPECS[id]) or false
            local current = SfuiDB.gear[id].armor_ilvl_prio
            if current == nil then current = isTank end
            SfuiDB.gear[id].armor_ilvl_prio = not current
            sfui.gear.UpdateStatUI()
            sfui.gear.Update()
        end)
        btnILvl:SetScript("OnEnter", function(b)
            show_tooltip(b, "ANCHOR_TOP", "Prioritize Armor Item Level (Tanks)", {
                { "Prioritizes highest Item Level on Armor slots (Head, Shoulders, Chest, Wrist, Hands, Waist, Legs, Feet) for maximum Armor, Stamina, and Primary Stat.", 0.8, 0.8, 0.8, true },
                { "Jewelry, Cloak, and Trinkets continue using your secondary stat priority / Pawn weights.", 0.6, 0.9, 0.6, true },
                { "Enabled by default for Tank specializations.", 0.5, 0.8, 1.0, true },
            })
        end)
        btnILvl:SetScript("OnLeave", function() hide_tooltip() end)
        ui.btnILvl = btnILvl

        -- ROW 3 (y=-110): Stat priority (LEFT) | Pawn string (RIGHT)
        local R3Y = -110

        -- Small reset button in front of Priority
        local resetBtn = common.create_flat_button(card, "R", 18, 18)
        resetBtn:SetPoint("TOPLEFT", card, "TOPLEFT", CX, R3Y + 1)
        resetBtn:SetScript("OnEnter", function(b)
            show_tooltip(b, "ANCHOR_TOP", "Reset stat priority & Pawn")
        end)
        resetBtn:SetScript("OnLeave", function() hide_tooltip() end)
        resetBtn:SetScript("OnClick", function()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            local targetDB = SfuiDB.gear[id]
            targetDB.stat_order   = nil
            targetDB.stat_equals  = nil
            targetDB.pawn_weights = nil
            targetDB.pawn_string  = nil
            sfui.gear.UpdateStatUI()
        end)

        -- --- Stat priority buttons (left side) ---
        local prioTag = mkLabel(card, "Prio:", 0.50, 0.50, 0.50)
        prioTag:SetPoint("LEFT", resetBtn, "RIGHT", 4, -1)

        ui.manBtns = {}
        ui.manTgls = {}
        local btnAnchor = prioTag

        local function getCurrentOrder()
            local db = SfuiDB.gear[id] or {}
            local targetDB = db
            if targetDB.pawn_weights then
                -- Reuse pre-allocated sub-tables; indexed write avoids table.wipe allocation churn
                local m = 0
                for k, v in pairs(targetDB.pawn_weights) do
                    local st = statAbbrv[k]
                    if st then
                        m = m + 1
                        local e = pawnScratchList[m]
                        if not e then e = { stat = "", weight = 0 }; pawnScratchList[m] = e end
                        e.stat = st; e.weight = v
                    end
                end
                for i = m + 1, #pawnScratchList do pawnScratchList[i] = nil end
                table.sort(pawnScratchList, pawnSortDesc)
                _G.wipe(curOrderScratch)
                for i = 1, 4 do curOrderScratch[i] = pawnScratchList[i] and pawnScratchList[i].stat or statPool[i] end
                return curOrderScratch
            end
            return targetDB.stat_order
                or db.stat_order
                or (sfui.default_stats and sfui.default_stats[tonumber(id)])
                or { "H", "M", "V", "C" }
        end

        for j = 1, 4 do
            local btn = common.create_flat_button(card, "?", 22, 18)
            btn:SetPoint("LEFT", btnAnchor, "RIGHT", j == 1 and 4 or 8, 0)
            btn:SetPoint("TOP", card, "TOP", 0, R3Y + 1)
            btn.idx = j
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn:SetScript("OnClick", function(b, mouseBtn)
                SfuiDB.gear[id] = SfuiDB.gear[id] or {}
                local targetDB = SfuiDB.gear[id]

                if targetDB.pawn_weights then
                    targetDB.pawn_weights = nil
                    targetDB.pawn_string = nil
                    if ui.pawnEdit then ui.pawnEdit:SetText("") end
                end
                local order = getCurrentOrder()
                local newOrder = {}
                for k = 1, 4 do newOrder[k] = order[k] end
                if mouseBtn == "LeftButton" and b.idx > 1 then
                    newOrder[b.idx] = order[b.idx - 1]
                    newOrder[b.idx - 1] = order[b.idx]
                    targetDB.stat_order = newOrder
                    sfui.gear.UpdateStatUI()
                elseif mouseBtn == "RightButton" and b.idx < 4 then
                    newOrder[b.idx] = order[b.idx + 1]
                    newOrder[b.idx + 1] = order[b.idx]
                    targetDB.stat_order = newOrder
                    sfui.gear.UpdateStatUI()
                end
            end)
            btn:SetScript("OnEnter", function(b)
                local order = getCurrentOrder()
                local st = order[b.idx] or "?"
                show_tooltip(b, "ANCHOR_TOP", st, {
                    { "Left-click: increase priority", 0.7, 0.7, 0.7 },
                    { "Right-click: decrease priority", 0.7, 0.7, 0.7 }
                })
            end)
            btn:SetScript("OnLeave", function() hide_tooltip() end)
            ui.manBtns[j] = btn
            btnAnchor = btn

            if j < 4 then
                local sep = common.create_flat_button(card, ">", 14, 18)
                if sep.text then sep.text:SetTextColor(0.8, 0.8, 0.8) end
                sep:SetPoint("LEFT", btnAnchor, "RIGHT", 1, 0)
                sep:SetPoint("TOP", card, "TOP", 0, R3Y + 1)

                sep.idx = j
                sep:SetScript("OnClick", function(b)
                    SfuiDB.gear[id] = SfuiDB.gear[id] or {}
                    local targetDB = SfuiDB.gear[id]
                    local eq = targetDB.stat_equals or { true, false, false }
                    eq[b.idx] = not eq[b.idx]
                    targetDB.stat_equals = eq
                    sfui.gear.UpdateStatUI()
                end)

                ui.manTgls[j] = sep
                btnAnchor = sep
            end
        end

        -- --- Pawn string input (right side, anchored to card TOPRIGHT) ---
        local pawnSaveBtn = common.create_flat_button(card, "Save", 32, 18)
        pawnSaveBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, R3Y + 1)

        local pawnEdit = makeEditBox(card, 120, 18)
        pawnEdit:SetPoint("RIGHT", pawnSaveBtn, "LEFT", -3, 0)
        pawnEdit:SetPoint("TOP", card, "TOP", 0, R3Y + 1)
        pawnEdit:SetScript("OnEnterPressed", function(b) b:ClearFocus() end)
        ui.pawnEdit = pawnEdit

        local pawnTag = mkLabel(card, "Pawn:", 0.50, 0.50, 0.50)
        pawnTag:SetPoint("RIGHT", pawnEdit, "LEFT", -5, 0)
        pawnTag:SetPoint("TOP", card, "TOP", 0, R3Y)

        pawnSaveBtn:SetScript("OnClick", function()
            local text = pawnEdit:GetText()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            local weights = {}
            for stat, val in text:gmatch("(%a+)=(%-?[%d%.]+)") do
                weights[stat:gsub("Rating", "")] = tonumber(val)
            end
            SfuiDB.gear[id].pawn_weights = next(weights) and weights or nil
            SfuiDB.gear[id].pawn_string  = text ~= "" and text or nil
            if common and common.print then common.print("Pawn saved for " .. specName) end
            sfui.gear.UpdateStatUI()
        end)

        -- yOff = yOff - CARD_H -- Disabled due to tab layout
    end
    self:SelectSpecTab(activeSpecId)

    if sfui.gear.UpdateStatUI then sfui.gear.UpdateStatUI() end
end)

sfui.gear.Frame = gearFrame

-- -------------------------------------------------------------------------
-- CHARACTER FRAME TOGGLE BUTTON
-- -------------------------------------------------------------------------
local function InitToggleHook()
    if sfui.gear.toggle_hooked then return end
    if not CharacterFrame or not CharacterFrameCloseButton then return end
    sfui.gear.toggle_hooked = true

    local toggleBtn = CreateFrame("Button", "SfuiGearToggleBtn", CharacterFrame)
    toggleBtn:SetSize(22, 22)
    toggleBtn:SetPoint("RIGHT", CharacterFrameCloseButton, "LEFT", -5, 0)
    toggleBtn:SetNormalTexture("Interface\\Icons\\inv_misc_gear_01")
    toggleBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    if toggleBtn:GetNormalTexture() then
        toggleBtn:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    toggleBtn:SetScript("OnEnter", function(self)
        show_tooltip(self, "ANCHOR_RIGHT", "sfui gear manager")
    end)
    toggleBtn:SetScript("OnLeave", function() hide_tooltip() end)
    toggleBtn:SetScript("OnClick", function()
        if SfuiGearManagerFrame:IsShown() then
            SfuiGearManagerFrame:Hide()
        else
            SfuiGearManagerFrame:Show()
        end
    end)

    toggleBtn:SetScript("OnShow", function()
        if sfui.gear.pauseAutoEquip then sfui.gear.pauseAutoEquip(10) end
        if SfuiGearManagerFrame and SfuiDB.gear and SfuiDB.gear.auto_open ~= false then
            SfuiGearManagerFrame:Show()
        end
    end)
    toggleBtn:SetScript("OnHide", function()
        if SfuiGearManagerFrame and SfuiDB.gear and SfuiDB.gear.auto_open ~= false then
            SfuiGearManagerFrame:Hide()
        end
    end)
end

if CharacterFrame then InitToggleHook() end

-- -------------------------------------------------------------------------
-- PAPERDOLL ITEM LOCK (Shift+Right-click)
-- -------------------------------------------------------------------------
local function InitPaperDollLockHook()
    if sfui.gear.paperdoll_hooked then return end
    sfui.gear.paperdoll_hooked = true

    local function onPaperDollClick(self, button)
        if button == "RightButton" and IsShiftKeyDown() then
            local slot = self:GetID()
            local link = GetInventoryItemLink("player", slot)
            if link then
                local itemID = GetItemInfoInstant(link)
                local specID = common.get_current_spec_id()
                if itemID and specID then
                    SfuiDB.gear[specID] = SfuiDB.gear[specID] or {}
                    local ctxPvP = isCurrentlyPvP()
                    local key = ctxPvP and "locked_items_pvp" or "locked_items_pve"
                    SfuiDB.gear[specID][key] = SfuiDB.gear[specID][key] or {}
                    
                    local slotName = "Item"
                    if slot == 13 or slot == 14 then slotName = "Trinket"
                    elseif slot == 11 or slot == 12 then slotName = "Ring"
                    elseif slot == 2 then slotName = "Neck"
                    elseif slot == 16 then slotName = "Main Hand"
                    elseif slot == 17 then slotName = "Off Hand"
                    end

                    if SfuiDB.gear[specID][key][itemID] then
                        SfuiDB.gear[specID][key][itemID] = nil
                        if common and common.print then
                            common.print(string.format("%s unlocked (%s): %s", slotName, ctxPvP and "PvP" or "PvE", link))
                        end
                    else
                        SfuiDB.gear[specID][key][itemID] = true
                        if common and common.print then
                            common.print(string.format("%s locked (%s): %s", slotName, ctxPvP and "PvP" or "PvE", link))
                        end
                    end
                    sfui.gear.UpdateStatUI()
                end
            end
        end
    end

    local slotsToHook = {
        "CharacterTrinket0Slot",
        "CharacterTrinket1Slot",
        "CharacterFinger0Slot",
        "CharacterFinger1Slot",
        "CharacterNeckSlot",
        "CharacterMainHandSlot",
        "CharacterSecondaryHandSlot",
    }
    for _, slotName in ipairs(slotsToHook) do
        local slotFrame = _G[slotName]
        if slotFrame then
            slotFrame:HookScript("OnClick", onPaperDollClick)
        end
    end
end

sfui.events.RegisterEvent("PLAYER_LOGIN", function()
    -- Global single-pass legacy DB migration
    if SfuiDB and SfuiDB.gear then
        for specID, db in pairs(SfuiDB.gear) do
            if type(specID) == "number" and db.locked_items then
                db.locked_items_pve = db.locked_items_pve or {}
                db.locked_items_pvp = db.locked_items_pvp or {}
                for k in pairs(db.locked_items) do
                    db.locked_items_pve[k] = true
                    db.locked_items_pvp[k] = true
                end
                db.locked_items = nil
            end
        end
    end
    -- Migrate legacy per-character autoequip_enabled → unified SfuiDB.gear.auto_equip_highest
    if SfuiDB and SfuiDB.gear_char and SfuiDB.gear then
        if SfuiDB.gear.auto_equip_highest == nil then
            -- Check if ANY character had autoequip_enabled = true; if so, carry it over
            for _, charData in pairs(SfuiDB.gear_char) do
                if charData.autoequip_enabled then
                    SfuiDB.gear.auto_equip_highest = true
                    break
                end
            end
        end
    end
    
    InitToggleHook()
    InitPaperDollLockHook()

    -- Populate initial equipped items to track changes
    for slotID = 1, 17 do
        if slotID ~= 4 then
            local link = GetInventoryItemLink("player", slotID)
            lastEquippedItems[slotID] = link and GetItemInfoInstant(link)
        end
    end
end)

function sfui.gear_debug_info()
    local eqCount = 0
    for _ in pairs(lastEquippedItems) do eqCount = eqCount + 1 end

    return {
        equippedCache = eqCount,
        lastEquipped  = eqCount,
    }
end

