local addonName, addon = ...
sfui.gear = {}

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

local event_frame = CreateFrame("Frame")
event_frame:RegisterEvent("PLAYER_ENTERING_WORLD")
event_frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
event_frame:RegisterEvent("PLAYER_FLAGS_CHANGED")
event_frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
event_frame:RegisterEvent("BAG_UPDATE_DELAYED")

local gearEquipQueue = nil

local function TryEquipSet(setName)
    if not setName or setName == "" then return false end
    local setID = C_EquipmentSet.GetEquipmentSetID(setName)
    if setID then
        local name, icon, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if isEquipped then return false end

        -- Don't equip if fighting, casting, or dead
        if InCombatLockdown() then
            gearEquipQueue = setID
            event_frame:RegisterEvent("PLAYER_REGEN_ENABLED")
            return false
        end
        if UnitCastingInfo("player") or UnitChannelInfo("player") or UnitIsDeadOrGhost("player") then
            return false
        end

        C_EquipmentSet.UseEquipmentSet(setID)
        if sfui.common and sfui.common.print then
            sfui.common.print("Automatically equipped set: " .. name)
        else
            print("|cff6600ffsfui:|r Automatically equipped set: " .. name)
        end
        return true
    end
    return false
end

function sfui.gear.Update()
    if not SfuiDB.gear then return end

    local spec = sfui.common.get_current_spec_id()
    if spec == 0 then return end

    local db = SfuiDB.gear[spec]
    if not db then return end

    local pveSet = db.pve_set
    local pvpSet = db.pvp_set

    local _, instanceType = GetInstanceInfo()
    local isWarMode = C_PvP.IsWarModeDesired()

    -- Determine which set to wear
    local targetSet = nil
    if instanceType == "pvp" or instanceType == "arena" then
        targetSet = pvpSet
    elseif instanceType == "party" or instanceType == "raid" or instanceType == "scenario" then
        targetSet = pveSet
    elseif instanceType == "none" then
        if isWarMode then
            targetSet = pvpSet
        else
            targetSet = pveSet
        end
    end

    if targetSet and targetSet ~= "" then
        TryEquipSet(targetSet)
    end
end

event_frame:SetScript("OnEvent", function(self, event, arg1, unit)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_UIPanels_Game" or arg1 == "Blizzard_CharacterFrame" then
            if type(InitToggleHook) == "function" then InitToggleHook() end
        end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if gearEquipQueue then
            if not UnitCastingInfo("player") and not UnitChannelInfo("player") and not UnitIsDeadOrGhost("player") then
                local name = C_EquipmentSet.GetEquipmentSetInfo(gearEquipQueue)
                C_EquipmentSet.UseEquipmentSet(gearEquipQueue)
                if name then
                    if sfui.common and sfui.common.print then
                        sfui.common.print("Automatically equipped queued set: " .. name)
                    else
                        print("|cff6600ffsfui:|r Automatically equipped queued set: " .. name)
                    end
                end
            end
            gearEquipQueue = nil
            event_frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
        return
    end

    if event == "BAG_UPDATE_DELAYED" then
        if SfuiDB.gear and SfuiDB.gear.auto_equip_highest ~= false then
            local UnitLevel = _G["UnitLevel"]
            local GetMaxPlayerLevel = _G["GetMaxLevelForPlayerExpansion"] or _G["GetMaxPlayerLevel"]
            if UnitLevel and GetMaxPlayerLevel and UnitLevel("player") < GetMaxPlayerLevel() then
                if sfui.highest and sfui.highest.EquipHighestILvl and not InCombatLockdown() and not UnitCastingInfo("player") and not UnitChannelInfo("player") and not UnitIsDeadOrGhost("player") then
                    local isPvP = false
                    local _, instanceType = GetInstanceInfo()
                    if instanceType == "pvp" or instanceType == "arena" or C_PvP.IsWarModeDesired() then
                        isPvP = true
                    end
                    sfui.highest.EquipHighestILvl(isPvP, true)
                end
            end
        end
        return
    end

    if event == "PLAYER_FLAGS_CHANGED" and arg1 ~= "player" then return end
    if event == "PLAYER_SPECIALIZATION_CHANGED" and arg1 ~= "player" then return end
    
    -- Slight delay to ensure InstanceInfo and WarMode state is accurate on load
    local delay = (sfui.config and sfui.config.gear and sfui.config.gear.updateDelay) or 3
    C_Timer.After(delay, function() sfui.gear.Update() end)
end)
event_frame:RegisterEvent("ADDON_LOADED")

-- ---------------------------------------------------------------------
-- CREATE STANDALONE GEAR MANAGER FRAME
-- ---------------------------------------------------------------------
local gearFrame = CreateFrame("Frame", "SfuiGearManagerFrame", UIParent, "BackdropTemplate")
gearFrame:SetPoint("CENTER")
gearFrame:SetMovable(true)
gearFrame:EnableMouse(true)
gearFrame:RegisterForDrag("LeftButton")
gearFrame:SetScript("OnDragStart", gearFrame.StartMoving)
gearFrame:SetScript("OnDragStop", gearFrame.StopMovingOrSizing)
gearFrame:Hide()
gearFrame:SetFrameStrata("DIALOG")

-- Styling to match options
gearFrame:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
gearFrame:SetBackdropColor(0, 0, 0, 0.5)

-- Title removed for sleek aesthetic

local closeBtn = sfui.common.create_flat_button(gearFrame, "X", 20, 20)
closeBtn:SetPoint("TOPRIGHT", gearFrame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() gearFrame:Hide() end)

local function GetEquipmentSetOptions()
    local options = { { text = "None", value = "" } }
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if setIDs then
        for _, id in ipairs(setIDs) do
            local name = C_EquipmentSet.GetEquipmentSetInfo(id)
            if name then table.insert(options, { text = name, value = name }) end
        end
    end
    return options
end

-- Initialize Rows Dynamically
gearFrame:SetScript("OnShow", function(self)
    if self.initialized then
        if self.updateFuncs then
            for _, f in ipairs(self.updateFuncs) do f() end
        end
        return
    end
    self.initialized = true
    self.updateFuncs = {}

    local numSpecs = GetNumSpecializations()
    if numSpecs == 0 then numSpecs = 1 end -- Fallback

    local headerHeight = 35
    local rowHeight = 40
    local padding = 15
    local bottomPadding = 45
    self:SetSize(280, headerHeight + (numSpecs * rowHeight) + bottomPadding)

    local pveHeader = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pveHeader:SetPoint("TOPLEFT", self, "TOPLEFT", 65, -15)
    pveHeader:SetText("PvE Set")

    local pvpHeader = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pvpHeader:SetPoint("TOPLEFT", self, "TOPLEFT", 175, -15)
    pvpHeader:SetText("PvP Set")

    -- Dynamic Rows
    local yOffset = -headerHeight
    for i = 1, numSpecs do
        local id, name, _, icon = GetSpecializationInfo(i)
        if not id then return end -- Failsafe
        
        local iconTex = self:CreateTexture(nil, "ARTWORK")
        iconTex:SetSize(32, 32)
        iconTex:SetPoint("TOPLEFT", 15, yOffset)
        iconTex:SetTexture(icon)

        local pveDrop = sfui.common.create_dropdown(self, 100, GetEquipmentSetOptions, function(val)
            SfuiDB.gear[id] = SfuiDB.gear[id] or { pve_set = "", pvp_set = "" }
            SfuiDB.gear[id].pve_set = val
            sfui.gear.Update()
        end, "")
        pveDrop:SetPoint("BOTTOMLEFT", iconTex, "BOTTOMRIGHT", 5, -5)

        local pvpDrop = sfui.common.create_dropdown(self, 100, GetEquipmentSetOptions, function(val)
            SfuiDB.gear[id] = SfuiDB.gear[id] or { pve_set = "", pvp_set = "" }
            SfuiDB.gear[id].pvp_set = val
            sfui.gear.Update()
        end, "")
        pvpDrop:SetPoint("LEFT", pveDrop, "RIGHT", 10, 0)

        table.insert(self.updateFuncs, function()
            local db = SfuiDB.gear[id]
            if db then
                pveDrop:SetText(db.pve_set ~= "" and db.pve_set or "None")
                pvpDrop:SetText(db.pvp_set ~= "" and db.pvp_set or "None")
            end
        end)
        
        -- Initial Text population
        self.updateFuncs[#self.updateFuncs]()
        
        yOffset = yOffset - rowHeight
    end

    -- High ilvl buttons
    local highestBtnWidth = 115
    local highestPveBtn = sfui.common.create_flat_button(self, "Highest PvE", highestBtnWidth, 25)
    highestPveBtn:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 15, 10)
    highestPveBtn:SetScript("OnClick", function()
        if sfui.highest and sfui.highest.EquipHighestILvl then
            sfui.highest.EquipHighestILvl(false)
        else
            if sfui.common and sfui.common.print then
                sfui.common.print("'Equip Highest' module failed to load.")
            else
                print("|cff6600ffsfui:|r 'Equip Highest' module failed to load.")
            end
        end
    end)

    local highestPvpBtn = sfui.common.create_flat_button(self, "Highest PvP", highestBtnWidth, 25)
    highestPvpBtn:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -15, 10)
    highestPvpBtn:SetScript("OnClick", function()
        if sfui.highest and sfui.highest.EquipHighestILvl then
            sfui.highest.EquipHighestILvl(true)
        end
    end)
end)

sfui.gear.Frame = gearFrame


-- ---------------------------------------------------------------------
-- CHARACTER FRAME TOGGLE BUTTON
-- ---------------------------------------------------------------------
function InitToggleHook()
    if sfui.gear.toggle_hooked then return end
    if not CharacterFrame or not CharacterFrameCloseButton then return end
    sfui.gear.toggle_hooked = true

    local toggleBtn = CreateFrame("Button", "SfuiGearToggleBtn", CharacterFrame)
    toggleBtn:SetSize(22, 22)
    -- Anchors robustly just to the left of the standard character frame close button
    toggleBtn:SetPoint("RIGHT", CharacterFrameCloseButton, "LEFT", -5, 0)
    
    toggleBtn:SetNormalTexture("Interface\\Icons\\inv_misc_gear_01")
    toggleBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    
    -- Clean up texture borders
    if toggleBtn:GetNormalTexture() then
        toggleBtn:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    toggleBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("SFUI Gear Manager")
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

-- Fallback initialization if CharacterFrame is already loaded by other addons
if CharacterFrame then
    InitToggleHook()
end
