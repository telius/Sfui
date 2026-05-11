local addonName, addon = ...
sfui = sfui or {}
sfui.automation = {}

local function on_role_check_show()
    if not SfuiDB.auto_role_check then return end
    if CompleteLFGRoleCheck then
        pcall(CompleteLFGRoleCheck, true)
    end
end

local function on_lfg_double_click(self)
    if not SfuiDB.auto_sign_lfg then return end
    if IsShiftKeyDown() then return end

    local result_exists = not LFGListFrame.SearchPanel.SignUpButton.tooltip
    if result_exists then
        LFGListSearchPanel_SignUp(self:GetParent():GetParent():GetParent())
    end
end

local function initialize_lfg_buttons()
    if not LFGListFrame or not LFGListFrame.SearchPanel or not LFGListFrame.SearchPanel.ScrollBox then
        return
    end

    local scroll_target = LFGListFrame.SearchPanel.ScrollBox:GetScrollTarget()
    if not scroll_target then return end

    local buttons = { scroll_target:GetChildren() }
    for _, child in ipairs(buttons) do
        if child and child:GetObjectType() == "Button" and not child.sfui_automation_init then
            child:SetScript("OnDoubleClick", on_lfg_double_click)
            child:RegisterForClicks("AnyUp")
            child.sfui_automation_init = true
        end
    end
end

local currentTargetSlot = nil
local SLOT_ORDER = { 16, 17, 1, 3, 5, 9, 10, 8, 7, 6 }
local rotationIndex = 1

local update_hammer_popup -- Forward declaration

local function setup_lfg_dialog()
    if LFGListApplicationDialog then
        if LFGListApplicationDialog.Show then
            hooksecurefunc(LFGListApplicationDialog, "Show", function(self)
                if not SfuiDB.auto_sign_lfg then return end
                if IsShiftKeyDown() then return end

                if self.SignUpButton and self.SignUpButton:IsEnabled() then
                    self.SignUpButton:Click()
                end
            end)
        end
    end
end

local function auto_sell_greys()
    if not SfuiDB.autoSellGreys then return end

    local totalPrice = 0
    for bag = 0, 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and info.quality == 0 then
                local price = info.noValue and 0 or (select(11, C_Item.GetItemInfo(info.hyperlink)) or 0)
                if price > 0 then
                    totalPrice = totalPrice + (price * info.stackCount)
                    C_Container.UseContainerItem(bag, slot)
                end
            end
        end
    end
    if totalPrice > 0 then
        sfui.common.print("|cff00ff00Auto-sold greys for " .. sfui.common.SafeGetCoinTextureString(totalPrice) .. ".|r")
    end
end

local profConfigIDs = nil
local function get_all_prof_configs()
    if profConfigIDs then return profConfigIDs end

    local configs = {}
    local skillLines = C_TradeSkillUI.GetAllProfessionTradeSkillLines()
    if skillLines then
        for _, skillLineID in ipairs(skillLines) do
            local cfgID = C_ProfSpecs.GetConfigIDForSkillLine(skillLineID)
            if cfgID and cfgID > 0 then
                table.insert(configs, cfgID)
            end
        end
    end
    profConfigIDs = configs
    return configs
end

local hammerCache = {
    found = false,
    name = nil,
    icon = nil,
    itemID = nil,
    checked = false
}

function sfui.automation.has_repair_hammer()
    -- If we've already checked this session (or since last BAG_UPDATE), return cached result
    if hammerCache.checked then
        return hammerCache.found, hammerCache.name, hammerCache.icon, hammerCache.itemID
    end

    -- Restriction: Only scan if we have a valid BS config
    -- This prevents scanning on characters that can't possibly use it
    local cfgs = get_all_prof_configs()
    if not cfgs or #cfgs == 0 then
        hammerCache.checked = true
        hammerCache.found = false
        return false
    end

    for bag = 0, 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink then
                local itemID = C_Item.GetItemInfoInstant(info.hyperlink)

                -- Fast check against known IDs first to avoid expensive GetItemInfo calls
                if itemID and sfui.config.masterHammer[itemID] then
                    local name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(info.hyperlink)
                    hammerCache.found = true
                    hammerCache.name = name
                    hammerCache.icon = icon
                    hammerCache.itemID = itemID
                    hammerCache.checked = true
                    return true, name, icon, itemID
                end

                -- Fallback for older/unknown hammers (matches "Master's Hammer")
                -- We only do this if it's NOT a known ID but might be a hammer string match
                local name = C_Item.GetItemNameByID(info.hyperlink)
                if name and name:find("Master.s Hammer") then
                    local _, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(info.hyperlink)
                    hammerCache.found = true
                    hammerCache.name = name
                    hammerCache.icon = icon
                    hammerCache.itemID = itemID
                    hammerCache.checked = true
                    return true, name, icon, itemID
                end
            end
        end
    end

    -- If we finished a full scan and found nothing, mark as checked but not found
    -- If user picks one up later, BAG_UPDATE should clear this flag
    hammerCache.found = false
    hammerCache.checked = true
    return false
end

local ARMOR_LOC_MAP = {
    ["INVTYPE_HEAD"] = "HEAD",
    ["INVTYPE_SHOULDER"] = "SHOULDER",
    ["INVTYPE_CHEST"] = "CHEST",
    ["INVTYPE_ROBE"] = "CHEST",
    ["INVTYPE_WAIST"] = "WAIST",
    ["INVTYPE_LEGS"] = "LEGS",
    ["INVTYPE_FEET"] = "FEET",
    ["INVTYPE_WRIST"] = "WRIST",
    ["INVTYPE_HANDS"] = "HANDS",
    ["INVTYPE_HAND"] = "HANDS"
}

local function has_repair_perk(nodeID)
    if not nodeID then return false end
    local cfgs = get_all_prof_configs()
    if not cfgs or #cfgs == 0 then return true end

    for _, cfgID in ipairs(cfgs) do
        local nodeInfo = C_Traits.GetNodeInfo(cfgID, nodeID)
        if nodeInfo and nodeInfo.ID == nodeID then
            local requiredRank = sfui.config.masterHammer.requiredRank or 26
            if (nodeInfo.currentRank or 0) >= requiredRank then
                return true
            end
            return false -- Found the node in this tree, but rank is too low
        end
    end
    return false
end

local function check_repair_eligibility(slot)
    local itemLink = GetInventoryItemLink("player", slot)
    if not itemLink then return false end

    local _, _, _, _, _, _, _, _, equipLoc, _, _, classID, subClassID, _, expacID = C_Item.GetItemInfo(itemLink)
    if not classID then return false end

    local hasHammer, _, _, hammerItemID = sfui.automation.has_repair_hammer()
    if not hasHammer or not hammerItemID then return false end

    -- Get nodes from config
    local nodes = sfui.config.masterHammer[hammerItemID] and sfui.config.masterHammer[hammerItemID].nodes
    if not nodes then return true end -- No restrictions defined? Allow.

    -- Weapon (Class 2)
    if classID == 2 then
        local node = nodes[subClassID]
        if node then return has_repair_perk(node) end
        return false
    end

    -- Armor (Class 4)
    if classID == 4 then
        if subClassID == 6 then -- Shield
            if nodes["SHIELD"] then return has_repair_perk(nodes["SHIELD"]) end
            return false
        end
        if subClassID == 4 then -- Plate (4)
            local key = ARMOR_LOC_MAP[equipLoc]
            if key and nodes[key] then return has_repair_perk(nodes[key]) end
            -- If plate but no node map?
            return false
        end
        return false -- Non-plate/shield
    end

    return false
end

local function create_hammer_popup()
    if hammerPopup then return hammerPopup end
    hammerPopup = CreateFrame("Button", "SfuiHammerPopup", UIParent, "SecureActionButtonTemplate, BackdropTemplate")
    hammerPopup:SetSize(64, 64)
    -- Point set below dynamically based on settings
    hammerPopup:SetFrameStrata("DIALOG")              -- Ensure it's on top
    hammerPopup:RegisterForClicks("AnyUp", "AnyDown") -- Ensure it accepts clicks
    hammerPopup:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    hammerPopup:SetBackdropColor(0, 0, 0, 0.8)

    local icon = hammerPopup:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture(134376)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    hammerPopup.icon = icon

    local highlight = hammerPopup:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(icon)
    highlight:SetColorTexture(1, 1, 1, 0.2)
    hammerPopup:SetHighlightTexture(highlight)

    local pushed = hammerPopup:CreateTexture(nil, "BACKGROUND")
    pushed:SetAllPoints(icon)
    pushed:SetColorTexture(0, 0, 0, 0.3)
    hammerPopup:SetPushedTexture(pushed)


    local text = hammerPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("BOTTOM", 0, -20)
    text:SetText("repair")
    hammerPopup.text = text

    -- Apply Aesthetics from DB
    hammerPopup:Hide()

    hammerPopup:SetScript("PostClick", function(self, button, down)
        if down then return end
        if InCombatLockdown() then return end
        -- Move to the next slot in the rotation immediately
        rotationIndex = (rotationIndex % #SLOT_ORDER) + 1
        update_hammer_popup()
    end)

    hammerPopup:SetScript("PreClick", function(self)
        if InCombatLockdown() then return end
        -- Listen for the cast result only when we actually use the tool
        sfui.automation.register_transient_listeners()
    end)

    -- Make Movable
    hammerPopup:SetMovable(true)
    hammerPopup:RegisterForDrag("LeftButton")
    hammerPopup:SetScript("OnDragStart", function(self)
        if not SfuiDB.lockRepairIcon then
            self:StartMoving()
        end
    end)
    hammerPopup:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position relative to center
        local center_x, center_y = self:GetCenter()
        local uip_x, uip_y = UIParent:GetCenter()
        if not center_x or not center_y or not uip_x or not uip_y then return end

        local x = math.floor(center_x - uip_x)
        local y = math.floor(center_y - uip_y)

        SfuiDB.repairIconX = x
        SfuiDB.repairIconY = y

        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", x, y)
    end)

    sfui.automation.update_popup_style() -- Apply initial style
    return hammerPopup
end

function sfui.automation.update_popup_style()
    if not hammerPopup then return end

    -- Apply position from DB or config defaults
    local defaultPos = sfui.config.masterHammer.defaultPosition
    local x = SfuiDB.repairIconX or defaultPos.x
    local y = SfuiDB.repairIconY or defaultPos.y
    hammerPopup:ClearAllPoints()
    hammerPopup:SetPoint("CENTER", UIParent, "CENTER", x, y)

    -- Apply color from DB or config default
    local hex = SfuiDB.repairIconColor or sfui.config.masterHammer.defaultColor
    if hex:sub(1, 1) == "#" then hex = hex:sub(2) end
    local r = tonumber("0x" .. hex:sub(1, 2)) or 255
    local g = tonumber("0x" .. hex:sub(3, 4)) or 0
    local b = tonumber("0x" .. hex:sub(5, 6)) or 255

    hammerPopup:SetBackdropBorderColor(r / 255, g / 255, b / 255, 1)
    if hammerPopup.text then
        hammerPopup.text:SetTextColor(r / 255, g / 255, b / 255, 1)
    end
end

update_hammer_popup = function()
    if InCombatLockdown() then return end

    local hasHammer, hammerName, hammerIcon, hammerItemID = sfui.automation.has_repair_hammer()
    if not hasHammer then
        if hammerPopup then hammerPopup:Hide() end
        return
    end

    local popup = create_hammer_popup()
    if hammerIcon then popup.icon:SetTexture(hammerIcon) end

    local damagedFound = false
    local targetSlot = nil
    local totalBroken = 0
    local displayPct = 0

    -- 1. Count total broken and find lowest for display purposes
    local lowestDur = 100
    local threshold = SfuiDB.repairThreshold or 90
    for _, slot in ipairs(SLOT_ORDER) do
        local cur, max = GetInventoryItemDurability(slot)
        if cur and max and cur < max then
            local pct = (cur / max) * 100
            if pct <= threshold then
                totalBroken = totalBroken + 1
            end
            if pct < lowestDur then lowestDur = pct end
        end
    end
    displayPct = math.floor(lowestDur)

    -- 2. Find the NEXT target in the rotation
    for i = 0, #SLOT_ORDER - 1 do
        local idx = ((rotationIndex + i - 1) % #SLOT_ORDER) + 1
        local slot = SLOT_ORDER[idx]
        local cur, max = GetInventoryItemDurability(slot)

        if cur and max and cur < max then
            local pct = (cur / max) * 100
            if pct <= threshold then
                local eligible = check_repair_eligibility(slot)
                if eligible then
                    targetSlot = slot
                    rotationIndex = idx
                    damagedFound = true
                    break
                end
            end
        end
    end

    if damagedFound and targetSlot then
        local macro = string.format("/use %s\n/use %d", hammerName, targetSlot)
        popup:SetAttribute("type", "macro")
        popup:SetAttribute("macrotext", macro)

        if popup.text then
            popup.text:SetText(string.format("%d%% (%d)", displayPct, totalBroken))
        end

        popup:Show()
        -- Respect enable setting (defaults to true if nil)
        if SfuiDB.enableMasterHammer == false then
            popup:SetAlpha(0)
            popup:EnableMouse(false)
        else
            popup:SetAlpha(1)
            popup:EnableMouse(true)
        end
        currentTargetSlot = targetSlot
    else
        popup:Hide()
    end
end

local function auto_repair()
    if not SfuiDB.autoRepair then return end
    if not CanMerchantRepair() then return end

    local hasHammer, hammerName = sfui.automation.has_repair_hammer()
    if hasHammer then
        -- Only skip auto-repair if the hammer can actually repair at least one damaged item
        local threshold = SfuiDB.repairThreshold or 90
        local hammerCanFix = false
        for _, slot in ipairs(SLOT_ORDER) do
            local cur, max = GetInventoryItemDurability(slot)
            if cur and max and cur < max then
                local pct = (cur / max) * 100
                if pct <= threshold and check_repair_eligibility(slot) then
                    hammerCanFix = true
                    break
                end
            end
        end
        if hammerCanFix then
            sfui.common.print(string.format("|cffff9900Auto-repair skipped: %s detected.|r", hammerName))
            update_hammer_popup()
            return
        end
    end

    local repairAllCost, canRepair = GetRepairAllCost()
    if not canRepair or repairAllCost == 0 then return end

    if CanGuildBankRepair() then
        RepairAllItems(true)
        sfui.common.print("|cff00ff00Auto-repaired using guild funds for " ..
            sfui.common.SafeGetCoinTextureString(repairAllCost) .. ".|r")
    else
        RepairAllItems(false)
        sfui.common.print("|cff00ff00Auto-repaired for " .. sfui.common.SafeGetCoinTextureString(repairAllCost) .. ".|r")
    end
end

function sfui.automation.match_mount()
    if InCombatLockdown() then return end

    local target = "target"
    if UnitExists(target) then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(target, i, "HELPFUL")
            if not aura then break end

            local spellID = aura.spellId
            -- C_MountJournal.GetMountFromSpell was added in 10.0
            if C_MountJournal.GetMountFromSpell then
                local mountID = C_MountJournal.GetMountFromSpell(spellID)
                if mountID then
                    local _, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
                    if isCollected then
                        C_MountJournal.SummonByID(mountID)
                        return
                    end
                end
            end
        end
    end

    -- Fallback: Summon Random Favorite
    C_MountJournal.SummonByID(0)
end

_G["SFUI_MATCHMOUNT"] = sfui.automation.match_mount

sfui.events.RegisterEvent("LFG_ROLE_CHECK_SHOW", function()
    C_Timer.After(0.1, on_role_check_show)
end)
sfui.events.RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED", function()
    C_Timer.After(0.1, initialize_lfg_buttons)
end)
sfui.events.RegisterEvent("PLAYER_LOGIN", function()
    setup_lfg_dialog()
end)
sfui.events.RegisterEvent("BAG_UPDATE", function()
    hammerCache.checked = false
    hammerCache.found = false
    profConfigIDs = nil
    update_hammer_popup()
end)
sfui.events.RegisterEvent("MERCHANT_SHOW", function()
    rotationIndex = 1
    auto_sell_greys()
    auto_repair()
    update_hammer_popup()
end)
sfui.events.RegisterEvent("MERCHANT_CLOSED", function() end)

local function on_hammer_cast_finished(unit, _, spellID)
    if unit == "player" and (spellID == 382404 or spellID == 382403) then
        currentTargetSlot = nil
        update_hammer_popup()
        sfui.automation.unregister_transient_listeners()
    end
end

local function on_hammer_cast_interrupted(unit, _, spellID)
    if unit == "player" and (spellID == 382404 or spellID == 382403) then
        currentTargetSlot = nil
        update_hammer_popup()
        sfui.automation.unregister_transient_listeners()
    end
end

function sfui.automation.register_transient_listeners()
    sfui.events.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", on_hammer_cast_finished)
    sfui.events.RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", on_hammer_cast_interrupted)

    -- Auto-cleanup after 5 seconds if for some reason we don't catch the event
    C_Timer.After(5, sfui.automation.unregister_transient_listeners)
end

function sfui.automation.unregister_transient_listeners()
    sfui.events.UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED", on_hammer_cast_finished)
    sfui.events.UnregisterEvent("UNIT_SPELLCAST_INTERRUPTED", on_hammer_cast_interrupted)
end

local function refreshHammer()
    update_hammer_popup()
end

sfui.events.RegisterEvent("UPDATE_INVENTORY_DURABILITY", refreshHammer)
sfui.events.RegisterEvent("PLAYER_REGEN_ENABLED", refreshHammer)

sfui.events.RegisterEvent("GET_ITEM_INFO_RECEIVED", function(itemID, success)
    if not success or not itemID then return end

    -- Only refresh if the received item is a known Master's Hammer
    if sfui.config.masterHammer[itemID] then
        refreshHammer()
    end
end)

local function auto_slot_keystone()
    local ReagentClass, KeystoneClass = Enum.ItemClass.Reagent, Enum.ItemReagentSubclass.Keystone
    local GetContainerItemID, GetContainerNumSlots, GetItemInfo = C_Container.GetContainerItemID, C_Container.GetContainerNumSlots, C_Item.GetItemInfo
    local NUM_BAG_FRAMES = NUM_BAG_FRAMES or 4

    for bag = 0, NUM_BAG_FRAMES do
        for slot = 1, GetContainerNumSlots(bag) do
            local ID = GetContainerItemID(bag, slot)
            if ID then
                local Class, SubClass = select(12, GetItemInfo(ID))
                if Class == ReagentClass and SubClass == KeystoneClass then
                    C_Container.PickupContainerItem(bag, slot)
                    if C_Cursor.GetCursorItem() then
                        C_ChallengeMode.SlotKeystone()
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function init_keystone_automation()
    local Frame = ChallengesKeystoneFrame
    if not Frame or Frame.sfui_keystone_init then return end
    Frame.sfui_keystone_init = true

    Frame:HookScript("OnShow", function()
        if SfuiDB.autoKeystone ~= false then
            auto_slot_keystone()
        end
    end)

    if not Frame:IsMovable() then
        Frame:SetMovable(true)
        Frame:SetClampedToScreen(true)
        Frame:RegisterForDrag("LeftButton")
        Frame:SetScript("OnDragStart", Frame.StartMoving)
        Frame:SetScript("OnDragStop", Frame.StopMovingOrSizing)
    end
end

sfui.events.RegisterEvent("PLAYER_LOGIN", function()
    init_keystone_automation()
end)

sfui.events.RegisterEvent("ADDON_LOADED", function(event, addon)
    if addon == "Blizzard_ChallengesUI" then
        init_keystone_automation()
    end

    if addon == "Blizzard_AuctionHouseUI" then
        -- AuctionHouseSearchBarMixin:OnShow calls FilterButton:Reset() each time the
        -- AH opens, which wipes all filters back to AUCTION_HOUSE_DEFAULT_FILTERS
        -- (CurrentExpansionOnly = false). We hook Reset to re-assert the flag after
        -- Blizzard's own reset runs, so the filter is always on by default.
        local fb = AuctionHouseFrame and AuctionHouseFrame.SearchBar and AuctionHouseFrame.SearchBar.FilterButton
        if fb then
            hooksecurefunc(fb, "Reset", function(self)
                if SfuiDB.ahCurrentExpansionFilter ~= false then
                    self.filters[Enum.AuctionHouseFilter.CurrentExpansionOnly] = true
                end
            end)
        end
    end
end)
