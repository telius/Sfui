local scanQueue = {}
local processingTicker
local targetExpac = -1

local function Process()
    local processed = false
    while #scanQueue > 0 and not processed do
        local task = scanQueue[1]
        local l = C_Container.GetContainerItemLink(task.c, task.s)

        if not l then
            table.remove(scanQueue, 1)
        else
            local itemID = GetItemInfoInstant(l)
            local exp = select(15, GetItemInfo(l))

            if exp == nil then
                if itemID and C_Item and C_Item.RequestLoadItemData then
                    C_Item.RequestLoadItemData(ItemLocation:CreateFromBagAndSlot(task.c, task.s))
                end
                processed = true -- yield to wait for server info
            else
                table.remove(scanQueue, 1)
                if exp == targetExpac then
                    C_Container.UseContainerItem(task.c, task.s)
                    processed = true -- yield to safely stagger transfers
                end
            end
        end
    end

    if #scanQueue == 0 and processingTicker then
        processingTicker:Cancel()
        processingTicker = nil
    end
end

local function Action(expTarget)
    if processingTicker then return end

    targetExpac = expTarget
    scanQueue = {}
    -- Character Bank (-1), Legacy Reagent Bank (-3), ReagentBag (5), Bank Bags (6-11), Warband Banks (12-16)
    local bags = { -1, -3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
    for _, c in ipairs(bags) do
        local n = C_Container.GetContainerNumSlots(c)
        if n and n > 0 then
            for s = 1, n do
                table.insert(scanQueue, { c = c, s = s })
            end
        end
    end

    if #scanQueue > 0 then
        processingTicker = C_Timer.NewTicker(0.1, Process)
    end
end

local expacs = {
    { id = 0,  name = "Vanilla" },
    { id = 1,  name = "TBC" },
    { id = 2,  name = "WotLK" },
    { id = 3,  name = "Cata" },
    { id = 4,  name = "MoP" },
    { id = 5,  name = "WoD" },
    { id = 6,  name = "Legion" },
    { id = 7,  name = "BfA" },
    { id = 8,  name = "SL" },
    { id = 9,  name = "DF" },
    { id = 10, name = "TWW" },
    { id = 11, name = "Mid" }
}

local function SetupUI()
    if not sfui or not sfui.common then return end

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
        local rows = 2
        local cols = 6
        local btnW, btnH, padding = 50, 24, 4
        sfui.transferContainer:SetSize((btnW + padding) * cols + padding, (btnH + padding) * rows + padding)
        sfui.transferContainer:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        sfui.transferContainer:SetBackdropColor(0, 0, 0, 0.8)
        sfui.transferContainer:SetBackdropBorderColor(0, 0, 0, 1)

        sfui.transferBtns = {}
        for i, exp in ipairs(expacs) do
            local btn = sfui.common.create_flat_button(sfui.transferContainer, exp.name, btnW, btnH)
            local row = math.floor((i - 1) / cols)
            local col = (i - 1) % cols
            btn:SetPoint("TOPLEFT", padding + col * (btnW + padding), -(padding + row * (btnH + padding)))
            btn:SetScript("OnClick", function() Action(exp.id) end)
            table.insert(sfui.transferBtns, btn)
        end
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
        C_Timer.After(0.5, SetupUI)
        C_Timer.After(1.5, SetupUI)
        C_Timer.After(3.0, SetupUI)
    end
end)
