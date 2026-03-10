local function Move(c, s, isAcc)
    local l = isAcc and C_Bank.GetTabItemLink(c, s) or C_Container.GetContainerItemLink(c, s)
    if l and select(15, GetItemInfo(l)) == GetExpansionLevel() - 1 then
        if isAcc then
            C_Bank.WithdrawItem(3, { tabIndex = c, slotIndex = s })
        else
            C_Container.UseContainerItem(c, s)
        end
    end
end

local function Action()
    if AccountBankPanel and AccountBankPanel:IsShown() then
        for t = 1, (C_Bank.GetNumTabs(3) or 0) do
            local numSlots = 98 -- Warband Bank standard
            for s = 1, numSlots do Move(t, s, true) end
        end
    else
        for _, c in ipairs({ -1, select(1, GetContainerNumSlots(Enum.BagIndex.Bank)) > 0 and Enum.BagIndex.Bank or -1, 6, 7, 8, 9, 10, 11, 12 }) do
            if c ~= -1 then
                local n = C_Container.GetContainerNumSlots(c)
                if n > 0 then for s = 1, n do Move(c, s) end end
            end
        end
    end
end

local function SetupUI()
    if not sfui or not sfui.common then return end

    -- Detect active bank frame (Baganator or Default)
    local parent
    if Baganator then
        for k, v in pairs(_G) do
            if type(k) == "string" and string.match(k, "^Baganator_.*BankViewFrame") then
                if type(v) == "table" and type(v.IsShown) == "function" and type(v.GetParent) == "function" and v:GetParent() == UIParent and v:IsShown() then
                    parent = v
                    break
                end
            end
        end
    end
    
    if not parent and BankFrame and BankFrame:IsShown() then parent = BankFrame end
    if not parent then return end

    if not sfui.transferContainer then
        sfui.transferContainer = CreateFrame("Frame", "SfuiTransferContainer", UIParent, "BackdropTemplate")
        sfui.transferContainer:SetSize(130, 34)
        sfui.transferContainer:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        sfui.transferContainer:SetBackdropColor(0, 0, 0, 0.8)
        sfui.transferContainer:SetBackdropBorderColor(0, 0, 0, 1)

        sfui.transferBtn = sfui.common.create_flat_button(sfui.transferContainer, "Grab Prev Expac", 120, 24)
        sfui.transferBtn:SetPoint("CENTER")
        sfui.transferBtn:SetScript("OnClick", Action)
    end

    sfui.transferContainer:SetParent(parent)
    sfui.transferContainer:SetFrameStrata("HIGH")
    sfui.transferContainer:SetFrameLevel(parent:GetFrameLevel() + 50)
    sfui.transferContainer:ClearAllPoints()
    sfui.transferContainer:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", -5, -5)
    sfui.transferContainer:Show()
end

local f = CreateFrame("Frame", "SfuiTransferFrame", UIParent)
f:RegisterEvent("BANKFRAME_OPENED")
f:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
f:SetScript("OnEvent", function(_, event, type)
    if event == "BANKFRAME_OPENED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and type == 1) then
        -- Multiple polls since Baganator with ElvUI skins can spawn asynchronously
        C_Timer.After(0.5, SetupUI)
        C_Timer.After(1.5, SetupUI)
        C_Timer.After(3.0, SetupUI)
    end
end)

local f = CreateFrame("Frame", "SfuiTransferFrame", UIParent)
f:RegisterEvent("BANKFRAME_OPENED")
f:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
f:SetScript("OnEvent", function(_, event, type)
    if event == "BANKFRAME_OPENED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and type == 1) then
        -- Multiple polls since Baganator with ElvUI skins can spawn asynchronously
        C_Timer.After(0.5, SetupUI)
        C_Timer.After(1.5, SetupUI)
        C_Timer.After(3.0, SetupUI)
    end
end)
