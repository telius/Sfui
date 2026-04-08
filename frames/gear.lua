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
local GameTooltip = _G.GameTooltip
local print = _G.print
local ipairs = _G.ipairs
local type = _G.type
local table = _G.table
local GetInventoryItemLink = _G.GetInventoryItemLink
local GetItemInfoInstant = _G.GetItemInfoInstant
local IsShiftKeyDown = _G.IsShiftKeyDown
-- P6: localize level APIs used in the hot BAG_UPDATE path
local UnitLevel = _G.UnitLevel
local GetMaxPlayerLevel = _G.GetMaxLevelForPlayerExpansion or _G.GetMaxPlayerLevel


local event_frame = CreateFrame("Frame")
event_frame:RegisterEvent("PLAYER_ENTERING_WORLD")
event_frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
event_frame:RegisterEvent("PLAYER_FLAGS_CHANGED")
event_frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
event_frame:RegisterEvent("SPEC_INVOLUNTARILY_CHANGED") -- 12.0.5+: system-forced spec changes
event_frame:RegisterEvent("BAG_UPDATE_DELAYED")
event_frame:RegisterEvent("EQUIPMENT_SETS_CHANGED") -- P5: invalidate set options cache
event_frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED") -- 12.0.5+: immediate gear slot cache bust

local gearEquipQueue = nil
-- P1: debounce BAG_UPDATE_DELAYED so rapid bag changes don't fire full scans repeatedly
local bagUpdatePending = false

-- Manual-edit protection: suppress BAG_UPDATE auto-equip while player is managing gear
local manualEditUntil = 0
local GetTime = _G.GetTime

--- Call this to pause automatic equipping from bag changes for `sec` seconds (default 60).
--- Opening the CharacterFrame also triggers this automatically.
sfui.gear.pauseAutoEquip = function(sec)
    manualEditUntil = GetTime() + (sec or 10)
end

local function autoEquipPaused()
    return GetTime() < manualEditUntil
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

-- Per-character settings helper.
-- Returns (and auto-creates) SfuiDB.gear_char["Name-Realm"] for the logged-in character.
local function charDB()
    local key = (_G.UnitName and _G.UnitName("player") or "?") .. "-" .. (_G.GetRealmName and _G.GetRealmName() or "?")
    SfuiDB.gear_char[key] = SfuiDB.gear_char[key] or {}
    return SfuiDB.gear_char[key]
end

local function TryEquipSet(setName)
    if not setName or setName == "" then return false end
    local setID = C_EquipmentSet.GetEquipmentSetID(setName)
    if setID then
        local name, icon, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if isEquipped then return false end
        if InCombatLockdown() then
            gearEquipQueue = setID
            event_frame:RegisterEvent("PLAYER_REGEN_ENABLED")
            return false
        end
        if UnitCastingInfo("player") or UnitChannelInfo("player") then
            -- Defers the update down the chain so it doesn't fail silently
            C_Timer.After(2.0, function() sfui.gear.Update() end)
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

-- P4: module-level scratch list reused across UpdateStatUI calls to avoid per-call allocation
local pawnScratchList = {}
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

-- -------------------------------------------------------------------------
-- UPDATE STAT UI
-- -------------------------------------------------------------------------
function sfui.gear.UpdateStatUI()
    if not SfuiGearManagerFrame or not SfuiGearManagerFrame:IsShown() then return end

    if SfuiGearManagerFrame.maxLvlChk then
        SfuiGearManagerFrame.maxLvlChk:SetChecked(charDB().max_level_autoequip or false)
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
            r, g, b = isEquipped and 0 or 1, isEquipped and 1 or 0.85, isEquipped and 1 or 0.2
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

            if ui.pveDrop then
                ui.pveDrop:SetText(db.pve_set ~= "" and db.pve_set or "None")
                local pveActive = db.pve_set and db.pve_set ~= ""
                    and C_EquipmentSet.GetEquipmentSetID(db.pve_set)
                    and select(4, C_EquipmentSet.GetEquipmentSetInfo(C_EquipmentSet.GetEquipmentSetID(db.pve_set)))
                local pt = ui.pveDrop:GetNormalTexture()
                if pt then
                    if pveActive then pt:SetVertexColor(0, 1, 1) else pt:SetVertexColor(PVE_COLOR[1], PVE_COLOR[2], PVE_COLOR[3]) end
                end
                local pfs = ui.pveDrop:GetFontString()
                if pfs then pfs:SetTextColor(PVE_COLOR[1], PVE_COLOR[2], PVE_COLOR[3]) end
            end
            if ui.pvpDrop then
                ui.pvpDrop:SetText(db.pvp_set ~= "" and db.pvp_set or "None")
                local pvpActive = db.pvp_set and db.pvp_set ~= ""
                    and C_EquipmentSet.GetEquipmentSetID(db.pvp_set)
                    and select(4, C_EquipmentSet.GetEquipmentSetInfo(C_EquipmentSet.GetEquipmentSetID(db.pvp_set)))
                local vt = ui.pvpDrop:GetNormalTexture()
                if vt then
                    if pvpActive then vt:SetVertexColor(0, 1, 1) else vt:SetVertexColor(PVP_COLOR[1], PVP_COLOR[2], PVP_COLOR[3]) end
                end
                local vfs = ui.pvpDrop:GetFontString()
                if vfs then vfs:SetTextColor(PVP_COLOR[1], PVP_COLOR[2], PVP_COLOR[3]) end
            end
            if ui.pawnEdit then ui.pawnEdit:SetText(db.pawn_string or "") end


            -- locked item icons (per slot, in lockSlots column order: T1,T2,R1,R2,A,W1,W2)
            if ui.lockIcons then
                local ctxPvP = isCurrentlyPvP()
                local lockTbl = ctxPvP and db.locked_items_pvp or db.locked_items_pve
                if not lockTbl then lockTbl = db.locked_items end -- legacy fallback
                local slotOrder = { 13, 14, 11, 12, 2, 16, 17 }
                for k, ico in ipairs(ui.lockIcons) do
                    ico.tex:SetTexture(nil); ico.itemID = nil; ico:Hide()
                    local slotID = slotOrder[k]
                    if slotID then
                        local link = GetInventoryItemLink("player", slotID)
                        if link and lockTbl then
                            local itemID, _, _, _, nativeIcon = GetItemInfoInstant(link)
                            if itemID and lockTbl[itemID] then
                                local tex = nativeIcon or
                                ((_G.C_Item and _G.C_Item.GetItemIconByID) and _G.C_Item.GetItemIconByID(itemID)) or
                                _G.GetItemIcon(itemID)
                                ico.tex:SetTexture(tex)
                                ico.itemID = itemID
                                ico:Show()
                            end
                        end
                    end
                end
            end

            -- update lock button tint + text color based on PvE/PvP lock state
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
                            -- Legacy fallback
                            if not db.locked_items_pve and not db.locked_items_pvp and db.locked_items and db.locked_items[iid] then
                                pveLocked, pvpLocked = true, true
                            end
                        end
                    end
                    local c
                    if pveLocked and pvpLocked then
                        c = BOTH_COLOR
                    elseif pveLocked then
                        c = PVE_COLOR
                    elseif pvpLocked then
                        c = PVP_COLOR
                    end
                    local t = btn:GetNormalTexture()
                    if t then
                        if c then
                            t:SetVertexColor(c[1], c[2], c[3])
                        else
                            t:SetVertexColor(1, 1, 1)
                        end
                    end
                    local fs = btn:GetFontString()
                    if fs then
                        if c then
                            fs:SetTextColor(c[1], c[2], c[3])
                        else
                            fs:SetTextColor(1, 1, 1)
                        end
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

            -- stat priority
            if ui.manBtns then
                local hasSet   = db.pve_set and db.pve_set ~= ""
                local alpha    = hasSet and 0.35 or 1.0

                local targetDB = db
                if ui.activeHero and db.hero and db.hero[ui.activeHero] then
                    targetDB = db.hero[ui.activeHero]
                end
                local pawnOrder
                if targetDB.pawn_weights and not hasSet then
                    -- P4: reuse scratch list instead of allocating a new table every call
                    local n = 0
                    for k, v in pairs(targetDB.pawn_weights) do
                        local sName = k:gsub("Rating", "")
                        if sName == "Haste" or sName == "Mastery" or sName == "Versatility" or sName == "Crit" then
                            n = n + 1
                            pawnScratchList[n] = { stat = sName, weight = v }
                        end
                    end
                    -- Clear any leftover entries from a previous longer list
                    for i = n + 1, #pawnScratchList do pawnScratchList[i] = nil end
                    table.sort(pawnScratchList, pawnSortDesc)
                    pawnOrder = {}
                    for j = 1, math.min(4, n) do table.insert(pawnOrder, pawnScratchList[j].stat) end
                    if #pawnOrder == 0 then pawnOrder = nil end
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
function sfui.gear.Update()
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

    -- If the correct set is already equipped, also skip EquipHighestILvl.
    if isGearSetEquipped() then return end

    -- EquipHighestILvl is gated by the manual-edit pause AND the per-character max-level toggle.
    if autoEquipPaused() then return end

    if UnitCastingInfo("player") or UnitChannelInfo("player") then
        C_Timer.After(2.0, function() sfui.gear.Update() end)
        return
    end

    if sfui.highest and sfui.highest.EquipHighestILvl
        and not InCombatLockdown()
        and not UnitIsDeadOrGhost("player") then
        local atMax = UnitLevel and GetMaxPlayerLevel
            and UnitLevel("player") >= GetMaxPlayerLevel()
        local shouldEquip = (not atMax) or charDB().max_level_autoequip
        if shouldEquip then
            sfui.highest.EquipHighestILvl(isPvP, true)
        end
    end
end

-- P5: cache equipment set options; invalidated when sets change
local equipSetOptionsCache = nil

-- -------------------------------------------------------------------------
-- EVENT HANDLER
-- -------------------------------------------------------------------------
event_frame:SetScript("OnEvent", function(self, event, arg1, unit)
    -- P5: invalidate set options cache when sets change
    if event == "EQUIPMENT_SETS_CHANGED" then
        equipSetOptionsCache = nil
        return
    end

    -- 12.0.5+: a gear slot changed — immediately invalidate the isGearSetEquipped cache
    -- so the next auto-equip check sees the real state rather than stale data.
    -- This closes the spec-swap gear lag (e.g. switching from Frost DK to Unholy while
    -- 2H weapons are equipped: the cache now resets the moment slot 16/17 change).
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        equipSetOptionsCache = nil
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if gearEquipQueue then
            if not UnitCastingInfo("player") and not UnitChannelInfo("player") and not UnitIsDeadOrGhost("player") then
                local name = C_EquipmentSet.GetEquipmentSetInfo(gearEquipQueue)
                C_EquipmentSet.UseEquipmentSet(gearEquipQueue)
                if name then
                    if common and common.print then
                        common.print("Equipped queued set: " .. name)
                    end
                end
            end
            gearEquipQueue = nil
            event_frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
        return
    end

    if event == "BAG_UPDATE_DELAYED" then
        -- [BAG_UPDATE_DELAYED Throttle Lock]
        -- Why lock for 2 seconds?
        -- This event fires violently rapidly when moving items, looting multiple items, or sorting bags.
        -- We lock (debounce) the auto-equip queue here for precisely 2 seconds so the inventory
        -- state can fully settle. This strictly prevents the CPU from re-scanning all 144 bag slots
        -- repeatedly every micro-second, and stops the UI from aggressively swapping gear while
        -- you are actively trying to organize your inventory.
        if not bagUpdatePending then
            bagUpdatePending = true
            C_Timer.After(2, function()
                bagUpdatePending = false
                -- Fix 1: respect manual-edit pause (CharacterFrame open / explicit pause)
                if autoEquipPaused() then return end
                -- Fix 2: if a gear set is configured AND equipped, don't override it
                if isGearSetEquipped() then return end
                local atMax = UnitLevel and GetMaxPlayerLevel
                    and UnitLevel("player") >= GetMaxPlayerLevel()
                local shouldEquip = (not atMax) or charDB().max_level_autoequip
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
            end)
        end
        if sfui.gear.UpdateStatUI then sfui.gear.UpdateStatUI() end
        return
    end

    if event == "PLAYER_FLAGS_CHANGED" and arg1 ~= "player" then return end

    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "SPEC_INVOLUNTARILY_CHANGED" then
        if arg1 ~= "player" and event == "PLAYER_SPECIALIZATION_CHANGED" then return end
        C_Timer.After(1.5, function() sfui.gear.Update() end)
        if SfuiGearManagerFrame and SfuiGearManagerFrame.SelectSpecTab then
            local specIdx = GetSpecialization()
            local specId = specIdx and GetSpecializationInfo(specIdx)
            if specId then SfuiGearManagerFrame:SelectSpecTab(specId) end
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        C_Timer.After(0.5, function() sfui.gear.Update() end)
        return
    end

    local delay = (cfg and cfg.gear and cfg.gear.updateDelay) or 3
    C_Timer.After(delay, function() sfui.gear.Update() end)
end)
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
gearFrame:SetScript("OnDragStop", gearFrame.StopMovingOrSizing)
gearFrame:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
gearFrame:SetBackdropColor(0.055, 0.055, 0.055, 0.97)
gearFrame:Hide()
gearFrame:SetFrameStrata("DIALOG")

local closeBtn = common.create_flat_button(gearFrame, "X", 20, 20)
closeBtn:SetPoint("TOPRIGHT", gearFrame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() gearFrame:Hide() end)



-- P5: cache equipment set options; rebuilt only when equipSetOptionsCache is nil
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

-- -------------------------------------------------------------------------
-- ON SHOW: build per-spec cards
-- -------------------------------------------------------------------------
gearFrame:SetScript("OnShow", function(self)
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

    local CARD_H  = 120
    local PAD_TOP = 50
    local BOT_H   = 52
    self:SetSize(490, PAD_TOP + CARD_H + BOT_H)

    self.tabBtns = self.tabBtns or {}
    local activeSpecId = GetSpecializationInfo(GetSpecialization() or 1)

    self.SelectSpecTab = function(f, specID)
        for id, ui in pairs(f.specUIs) do
            if id == specID then
                if ui.card then ui.card:Show() end
                if f.tabBtns[id] then f.tabBtns[id]:SetAlpha(1.0) end
            else
                if ui.card then ui.card:Hide() end
                if f.tabBtns[id] then f.tabBtns[id]:SetAlpha(0.3) end
            end
        end
    end

    -- icon helper: clicking (left OR right) unlocks the slot
    local function createTrinketIcon(parent, specId)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(22, 22)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(); btn.tex = tex
        btn:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(b)
            if b.itemID and SfuiDB.gear[specId] then
                local sdb = SfuiDB.gear[specId]
                local ctxPvP = isCurrentlyPvP()
                local key = ctxPvP and "locked_items_pvp" or "locked_items_pve"
                if sdb[key] then
                    sdb[key][b.itemID] = nil
                end
                -- Legacy cleanup
                if sdb.locked_items then sdb.locked_items[b.itemID] = nil end
                sfui.gear.UpdateStatUI()
            end
        end)
        btn:SetScript("OnEnter", function(b)
            if b.itemID then
                GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(b.itemID)
                local ctx = isCurrentlyPvP() and "PvP" or "PvE"
                GameTooltip:AddLine("Click to unlock (" .. ctx .. ")", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return btn
    end

    local startX = 10
    for i = 1, numSpecs do
        local id, _, _, icon = GetSpecializationInfo(i)
        if id then
            local btn = CreateFrame("Button", nil, self, "BackdropTemplate")
            btn:SetSize(28, 28)
            btn:SetPoint("TOPLEFT", self, "TOPLEFT", startX, -10)
            local t = btn:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints()
            t:SetTexture(icon)
            t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            btn:SetScript("OnClick", function() self:SelectSpecTab(id) end)
            self.tabBtns[id] = btn
            startX = startX + 32
        end
    end

    local yOff = -PAD_TOP
    for i = 1, numSpecs do
        local id, specName, _, icon = GetSpecializationInfo(i)
        if not id then return end

        self.specUIs[id] = {}
        local ui = self.specUIs[id]

        -- Card (no border, subtle background)
        local card = CreateFrame("Frame", nil, self, "BackdropTemplate")
        card:SetSize(470, CARD_H - 4)
        card:SetPoint("TOPLEFT", self, "TOPLEFT", 10, yOff)
        card:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
        card:SetBackdropColor(0.09, 0.09, 0.09, 0.88)
        ui.card = card

        ui.heroBtns = {}

        -- Helper to style flat radio buttons
        local function styleRadioBtn(btn, tex, isBase)
            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(btn.tInfoName or (isBase and "Base Spec" or "Hero Spec"))
                GameTooltip:AddLine(
                isBase and "Click to configure default stat weights." or
                "Click to configure stat weights specifically for this hero talent tree.", 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            btn.UpdateVisuals = function()
                local isActive = (isBase and not ui.activeHero) or (not isBase and ui.activeHero == btn.hID)
                if isActive then
                    tex:SetDesaturated(false)
                    tex:SetVertexColor(1, 1, 1)
                    tex:SetAlpha(1.0)
                else
                    tex:SetDesaturated(true)
                    tex:SetVertexColor(0.6, 0.6, 0.6)
                    tex:SetAlpha(0.35)
                end
            end

            btn:SetScript("OnClick", function()
                ui.activeHero = isBase and nil or btn.hID
                if ui.activeHero then
                    SfuiDB.gear[id] = SfuiDB.gear[id] or {}
                    SfuiDB.gear[id].hero = SfuiDB.gear[id].hero or {}
                    SfuiDB.gear[id].hero[ui.activeHero] = SfuiDB.gear[id].hero[ui.activeHero] or {}
                end
                for _, otherBtn in ipairs(ui.heroBtns) do
                    if otherBtn.UpdateVisuals then otherBtn.UpdateVisuals() end
                end
                sfui.gear.UpdateStatUI()
            end)
            table.insert(ui.heroBtns, btn)
            btn.UpdateVisuals()
        end

        local baseBtn = CreateFrame("Button", nil, card)
        baseBtn:SetSize(30, 30)
        baseBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 7, -8)
        local baseTex = baseBtn:CreateTexture(nil, "ARTWORK")
        baseTex:SetAllPoints()
        baseTex:SetTexture(icon)
        baseTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        baseBtn.tInfoName = specName .. " (Base)"
        styleRadioBtn(baseBtn, baseTex, true)

        local heroSpecs = C_ClassTalents and C_ClassTalents.GetHeroTalentSpecsForClassSpec(nil, id) or {}
        for hIdx, hID in ipairs(heroSpecs) do
            local btn = CreateFrame("Button", nil, card)
            btn:SetSize(30, 30)
            btn:SetPoint("TOPLEFT", card, "TOPLEFT", 7, -8 - (hIdx * 36))
            btn.hID = hID

            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexture(134400) -- fallback

            local function TrySetTexture()
                local configs = C_ClassTalents and C_ClassTalents.GetConfigIDsBySpecID and
                C_ClassTalents.GetConfigIDsBySpecID(id)
                local configID = (configs and configs[1]) or
                (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID())

                if configID and C_Traits and C_Traits.GetSubTreeInfo then
                    local tInfo = C_Traits.GetSubTreeInfo(configID, hID)
                    if tInfo and tInfo.iconElementID then
                        if type(tInfo.iconElementID) == "number" then
                            tex:SetTexture(tInfo.iconElementID)
                        else
                            tex:SetAtlas(tInfo.iconElementID)
                        end
                        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                        btn.tInfoName = tInfo.name
                    end
                end
            end
            TrySetTexture()
            styleRadioBtn(btn, tex, false)
        end


        local CX = 50 -- left margin for rows

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
                    -- Migrate legacy format on first interaction
                    if ldb.locked_items then
                        ldb.locked_items_pve = ldb.locked_items_pve or {}
                        ldb.locked_items_pvp = ldb.locked_items_pvp or {}
                        for k in pairs(ldb.locked_items) do
                            ldb.locked_items_pve[k] = true
                            ldb.locked_items_pvp[k] = true
                        end
                        ldb.locked_items = nil
                    end
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
        ui.lockIcons       = {}
        local LOCK_LABEL_W = 38 -- approximate width of "Lock:" label
        for k, def in ipairs(lockSlots) do
            local colX = LOCK_START + LOCK_LABEL_W + (k - 1) * LOCK_COL_W

            -- Icon (sub-row A): shown when slot is locked, click to unlock
            local ico = createTrinketIcon(card, id)
            ico:SetPoint("TOPLEFT", card, "TOPLEFT", colX, ICON_ROW_Y)
            ico:Hide()
            table.insert(ui.lockIcons, ico)

            -- Button (sub-row B): directly below icon
            local btn = common.create_flat_button(card, def.label, 22, 18)
            btn:SetPoint("TOPLEFT", card, "TOPLEFT", colX, BTN_ROW_Y)
            local capturedSlot = def.slot
            btn:SetScript("OnClick", function() lockSlot(capturedSlot, IsShiftKeyDown()) end)
            btn:SetScript("OnEnter", function(b)
                local link = GetInventoryItemLink("player", capturedSlot)
                GameTooltip:SetOwner(b, "ANCHOR_TOP")
                if link then
                    local _, itemName = GetItemInfo(link)
                    local iid = GetItemInfoInstant(link)
                    local pveL = iid and SfuiDB.gear[id] and SfuiDB.gear[id].locked_items_pve
                        and SfuiDB.gear[id].locked_items_pve[iid]
                    local pvpL = iid and SfuiDB.gear[id] and SfuiDB.gear[id].locked_items_pvp
                        and SfuiDB.gear[id].locked_items_pvp[iid]
                    -- Legacy fallback
                    if not pveL and not pvpL and iid and SfuiDB.gear[id] and SfuiDB.gear[id].locked_items
                        and SfuiDB.gear[id].locked_items[iid] then
                        pveL, pvpL = true, true
                    end
                    local tag = ""
                    if pveL and pvpL then tag = string.format("|cff%02x%02x%02x[PvE+PvP]|r ", BOTH_COLOR[1]*255, BOTH_COLOR[2]*255, BOTH_COLOR[3]*255)
                    elseif pveL then tag = string.format("|cff%02x%02x%02x[PvE]|r ", PVE_COLOR[1]*255, PVE_COLOR[2]*255, PVE_COLOR[3]*255)
                    elseif pvpL then tag = string.format("|cff%02x%02x%02x[PvP]|r ", PVP_COLOR[1]*255, PVP_COLOR[2]*255, PVP_COLOR[3]*255)
                    end
                    GameTooltip:SetText(tag .. (itemName or link))
                    GameTooltip:AddLine("Click = toggle PvE lock", PVE_COLOR[1], PVE_COLOR[2], PVE_COLOR[3])
                    GameTooltip:AddLine("Shift+Click = toggle PvP lock", PVP_COLOR[1], PVP_COLOR[2], PVP_COLOR[3])
                else
                    GameTooltip:SetText("Nothing equipped")
                end
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            table.insert(ui.lockBtns, { btn = btn, slotID = def.slot })
        end

        local setActiveLabel = mkLabel(card, "Set active", 0.85, 0.65, 0.1)
        setActiveLabel:SetPoint("TOPLEFT", card, "TOPLEFT",
            LOCK_START + LOCK_LABEL_W + #lockSlots * LOCK_COL_W + 5, BTN_ROW_Y - 1)
        setActiveLabel:Hide()
        ui.setActiveLabel = setActiveLabel

        -- Tier Force Buttons
        local btn2S = common.create_flat_button(card, "2S", 22, 18)
        btn2S:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 295, BTN_ROW_Y)
        btn2S:SetScript("OnClick", function()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            SfuiDB.gear[id].force_2set = not SfuiDB.gear[id].force_2set
            if SfuiDB.gear[id].force_2set then SfuiDB.gear[id].force_4set = false end -- Mutually exclusive
            sfui.gear.UpdateStatUI()
            sfui.gear.Update()
        end)
        btn2S:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText("Force 2-Piece Tier Set")
            GameTooltip:AddLine("Drafts 2 set pieces into your highest ilvl build, prioritizing lowest ilvl sacrifice.",
                0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        btn2S:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ui.btn2S = btn2S

        local btn4S = common.create_flat_button(card, "4S", 22, 18)
        btn4S:SetPoint("TOPLEFT", card, "TOPLEFT", CX + 320, BTN_ROW_Y)
        btn4S:SetScript("OnClick", function()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            local current = (SfuiDB.gear[id].force_4set ~= false) and not SfuiDB.gear[id].force_2set
            SfuiDB.gear[id].force_4set = not current
            if SfuiDB.gear[id].force_4set then SfuiDB.gear[id].force_2set = false end -- Mutually exclusive
            sfui.gear.UpdateStatUI()
            sfui.gear.Update()
        end)
        btn4S:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText("Force 4-Piece Tier Set")
            GameTooltip:AddLine("Drafts 4 set pieces into your highest ilvl build, prioritizing lowest ilvl sacrifice.",
                0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        btn4S:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ui.btn4S = btn4S

        -- ROW 3 (y=-85): Stat priority (LEFT) | Pawn string (RIGHT)
        local R3Y = -85

        -- Small reset button in front of Priority
        local resetBtn = common.create_flat_button(card, "R", 18, 18)
        resetBtn:SetPoint("TOPLEFT", card, "TOPLEFT", CX, R3Y + 1)
        resetBtn:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText("Reset stat priority & Pawn")
            GameTooltip:Show()
        end)
        resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        resetBtn:SetScript("OnClick", function()
            SfuiDB.gear[id] = SfuiDB.gear[id] or {}
            local targetDB = SfuiDB.gear[id]
            if ui.activeHero then
                SfuiDB.gear[id].hero = SfuiDB.gear[id].hero or {}
                SfuiDB.gear[id].hero[ui.activeHero] = SfuiDB.gear[id].hero[ui.activeHero] or {}
                targetDB = SfuiDB.gear[id].hero[ui.activeHero]
            end
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
            if ui.activeHero and db.hero and db.hero[ui.activeHero] then
                targetDB = db.hero[ui.activeHero]
            end
            if targetDB.pawn_weights then
                table.wipe(pawnScratchList)
                for k, v in pairs(targetDB.pawn_weights) do
                    local st = statAbbrv[k]
                    if st then table.insert(pawnScratchList, { s = st, weight = v }) end
                end
                table.sort(pawnScratchList, pawnSortDesc)
                local cur = {}
                for i = 1, 4 do cur[i] = pawnScratchList[i] and pawnScratchList[i].s or statPool[i] end
                return cur
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
                if ui.activeHero then
                    SfuiDB.gear[id].hero = SfuiDB.gear[id].hero or {}
                    SfuiDB.gear[id].hero[ui.activeHero] = SfuiDB.gear[id].hero[ui.activeHero] or {}
                    targetDB = SfuiDB.gear[id].hero[ui.activeHero]
                end

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
                GameTooltip:SetOwner(b, "ANCHOR_TOP")
                GameTooltip:AddLine(st, 1, 1, 1)
                GameTooltip:AddLine("Left-click: increase priority", 0.7, 0.7, 0.7)
                GameTooltip:AddLine("Right-click: decrease priority", 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
                    if ui.activeHero then
                        SfuiDB.gear[id].hero = SfuiDB.gear[id].hero or {}
                        SfuiDB.gear[id].hero[ui.activeHero] = SfuiDB.gear[id].hero[ui.activeHero] or {}
                        targetDB = SfuiDB.gear[id].hero[ui.activeHero]
                    end
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

    -- Bottom strip
    self.maxLvlChk = common.create_checkbox(self, "Auto Equip at Max Level",
        function() return charDB().max_level_autoequip end,
        function(c)
            charDB().max_level_autoequip = c
            if c then sfui.gear.Update() end
        end)
    self.maxLvlChk:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 15, 28)
    self.maxLvlChk.text:SetShadowOffset(0, 0)

    local highPvE = common.create_flat_button(self, "PvE", 115, 22)
    highPvE:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 15, 5)
    highPvE:SetScript("OnClick", function()
        if sfui.highest and sfui.highest.EquipHighestILvl then sfui.highest.EquipHighestILvl(false) end
    end)

    local highPvP = common.create_flat_button(self, "PvP", 115, 22)
    highPvP:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -5, 5)
    highPvP:SetScript("OnClick", function()
        if sfui.highest and sfui.highest.EquipHighestILvl then sfui.highest.EquipHighestILvl(true) end
    end)

    -- Status label centred between the two buttons
    local statusLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusLabel:SetPoint("BOTTOM", self, "BOTTOM", 0, 10)
    statusLabel:SetJustifyH("CENTER")
    statusLabel:SetShadowOffset(0, 0)
    self.statusLabel = statusLabel

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
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("sfui gear manager")
        GameTooltip:Show()
    end)
    toggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    toggleBtn:SetScript("OnClick", function()
        if SfuiGearManagerFrame:IsShown() then
            SfuiGearManagerFrame:Hide()
        else
            SfuiGearManagerFrame:Show()
        end
    end)

    CharacterFrame:HookScript("OnShow", function()
        -- Fix 1: pause auto-equip for 10s so player can edit gear sets without interference
        if sfui.gear.pauseAutoEquip then sfui.gear.pauseAutoEquip(10) end
        if SfuiGearManagerFrame and SfuiDB.gear and SfuiDB.gear.auto_open ~= false then
            SfuiGearManagerFrame:Show()
        end
    end)
    CharacterFrame:HookScript("OnHide", function()
        if SfuiGearManagerFrame and SfuiDB.gear and SfuiDB.gear.auto_open ~= false then
            SfuiGearManagerFrame:Hide()
        end
    end)
end

if CharacterFrame then InitToggleHook() end

-- -------------------------------------------------------------------------
-- PAPERDOLL TRINKET LOCK (Shift+Right-click)
-- -------------------------------------------------------------------------
local function InitPaperDollTrinketHook()
    if sfui.gear.paperdoll_hooked then return end
    sfui.gear.paperdoll_hooked = true

    local function onTrinketClick(self, button)
        if button == "RightButton" and IsShiftKeyDown() then
            local slot = self:GetID()
            local link = GetInventoryItemLink("player", slot)
            if link then
                local itemID = GetItemInfoInstant(link)
                local specID = common.get_current_spec_id()
                if itemID and specID then
                    SfuiDB.gear[specID] = SfuiDB.gear[specID] or {}
                    SfuiDB.gear[specID].locked_trinkets = SfuiDB.gear[specID].locked_trinkets or {}
                    if SfuiDB.gear[specID].locked_trinkets[itemID] then
                        SfuiDB.gear[specID].locked_trinkets[itemID] = nil
                        if common and common.print then common.print("Trinket unlocked: " .. link) end
                    else
                        SfuiDB.gear[specID].locked_trinkets[itemID] = true
                        if common and common.print then common.print("Trinket locked: " .. link) end
                    end
                    sfui.gear.UpdateStatUI()
                end
            end
        end
    end

    local t0 = _G.CharacterTrinket0Slot
    local t1 = _G.CharacterTrinket1Slot
    if t0 then t0:HookScript("OnClick", onTrinketClick) end
    if t1 then t1:HookScript("OnClick", onTrinketClick) end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    InitToggleHook()
    InitPaperDollTrinketHook()
end)
