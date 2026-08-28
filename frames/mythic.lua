local addonName, addon                          = ...
sfui                                            = sfui or {}
sfui.mythic                                     = sfui.mythic or {}

-- ─── Config ────────────────────────────────────────────────
local g                                         = sfui.config
local mcfg                                      = g.mythic or {}

-- ─── Localize C-APIs ──────────────────────────────────────
local CreateFrame                               = _G.CreateFrame
local UIParent                                  = _G.UIParent
local C_Timer                                   = _G.C_Timer
local C_ChallengeMode                           = _G.C_ChallengeMode
local C_Scenario                                = _G.C_Scenario
local C_ScenarioInfo                            = _G.C_ScenarioInfo
local C_DelvesUI                                = _G.C_DelvesUI
local C_UIWidgetManager                         = _G.C_UIWidgetManager
local C_Spell                                   = _G.C_Spell
local GetWorldElapsedTime                       = _G.GetWorldElapsedTime
local GameTooltip                               = _G.GameTooltip
local issecretvalue                             = _G.issecretvalue
local math_max, math_min, math_floor, math_ceil = math.max, math.min, math.floor, math.ceil
local string_format                             = string.format
local table_insert, table_sort, wipe            = table.insert, table.sort, wipe
local pcall, ipairs, pairs, type, tonumber, tostring =
    pcall, ipairs, pairs, type, tonumber, tostring

-- ─── Layout Constants ─────────────────────────────────────
local HUD_W                                     = mcfg.width or 280
local HUD_PAD                                   = 8
local TICKER_RATE                               = 0.5 -- 2 Hz relaxed timer ticker

-- ─── Color Table (used only in BuildHUDFrame — unpack is fine there) ─
local COLORS                                    = {
    cyan     = { 0.00, 1.00, 1.00, 1 },
    white    = { 1.00, 1.00, 1.00, 1 },
    dim      = { 0.50, 0.50, 0.50, 1 },
    bg       = { 0.05, 0.05, 0.05, 0.88 },
    bar_fill = { 0.00, 1.00, 1.00, 0.80 },
    bar_bg   = { 0.10, 0.10, 0.10, 0.90 },
    forces   = { 0.40, 0.00, 1.00, 0.85 },
}

-- ─── Pre-unpacked Color Scalars ───────────────────────────
-- Avoids unpack() vararg allocation on every hot-path call.
-- Named with a CLR_ prefix to distinguish from the COLORS table.
local CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B     = 0.20, 1.00, 0.40
local CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B     = 1.00, 1.00, 1.00
local CLR_DIM_R, CLR_DIM_G, CLR_DIM_B           = 0.50, 0.50, 0.50
local CLR_ONTIME_R, CLR_ONTIME_G, CLR_ONTIME_B  = 0.00, 1.00, 1.00
local CLR_YELLOW_R, CLR_YELLOW_G, CLR_YELLOW_B  = 1.00, 0.82, 0.00
local CLR_RED_R, CLR_RED_G, CLR_RED_B           = 1.00, 0.25, 0.25
local CLR_OVTM_R, CLR_OVTM_G, CLR_OVTM_B        = 1.00, 0.20, 0.20

-- ─── Hoisted Constants ────────────────────────────────────
-- Difficulty abbreviation map — allocated once, reused in InitDungeon.
local DIFF_ABBR                                 = { Mythic = "M", Heroic = "H", Normal = "N", Timewalking = "TW" }

-- ─── Helpers ──────────────────────────────────────────────
local function FormatTime(secs)
    if not secs or secs < 0 then secs = 0 end
    secs        = math_floor(secs)
    local hours = math_floor(secs / 3600)
    local mins  = math_floor((secs % 3600) / 60)
    local s     = secs % 60
    if hours > 0 then
        return string_format("%d:%02d:%02d", hours, mins, s)
    else
        return string_format("%d:%02d", mins, s)
    end
end

local function MakeText(parent, fontObj, r, g2, b, a, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormal")
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    if r then fs:SetTextColor(r, g2, b, a or 1) end
    if justify then fs:SetJustifyH(justify) end
    return fs
end

local function MakeStatusBar(parent, fill, bg)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture("Interface/Buttons/WHITE8X8")
    bar:SetStatusBarColor(unpack(fill or COLORS.bar_fill))
    local bgT = bar:CreateTexture(nil, "BACKGROUND")
    bgT:SetTexture("Interface/Buttons/WHITE8X8")
    bgT:SetVertexColor(unpack(bg or COLORS.bar_bg))
    bgT:SetAllPoints(bar)
    bar.bgT = bgT
    return bar
end

local function MakeSep(parent)
    local sep = parent:CreateTexture(nil, "ARTWORK")
    sep:SetTexture("Interface/Buttons/WHITE8X8")
    sep:SetVertexColor(0.3, 0.3, 0.3, 0.6)
    sep:SetHeight(1)
    return sep
end

-- ─── State ────────────────────────────────────────────────
-- _mode: nil = hidden, "mythic" = M+, "dungeon" = dungeon/delve/scenario
local _mode           = nil
local _isPreview      = false
local _ticker         = nil
local _timerID        = nil
local _timeLimit      = 0
local _bossSplits     = {}

-- Per-run cached values — reset in InitRun/InitDungeon
local _lastBossCount  = 0  -- for HideExtraBossRows: iterate only to last count
local _lastTimerPhase = -1 -- 0=ontime(>25%), 1=yellow, 2=red, 3=overtime
local _lastTimerText  = "" -- skip SetText when string unchanged
local _lastChestText  = "" -- skip SetText when string unchanged
local _lastDeathText  = "" -- skip SetText when string unchanged
local _lastDeaths     = -1
local _lastTimeLost   = -1

local _playerList     = {} -- list of { unit = ..., guid = ..., name = ..., class = ... }
local _playerClasses  = {} -- Name -> Class
local _playerDeaths   = {} -- Name -> deathCount

local function CacheGroupMembers()
    wipe(_playerClasses)
    local idx = 0

    local pGUID = UnitGUID("player")
    local pName = UnitName("player")
    local _, pClass = UnitClass("player")
    if pGUID and pName then
        idx = idx + 1
        local entry = _playerList[idx]
        if not entry then entry = {}; _playerList[idx] = entry end
        entry.unit = "player"; entry.guid = pGUID; entry.name = pName; entry.class = pClass
        _playerClasses[pName] = pClass
    end
    for i = 1, 4 do
        local unit = "party" .. i
        local guid = UnitGUID(unit)
        local name = UnitName(unit)
        local _, class = UnitClass(unit)
        if guid and name then
            idx = idx + 1
            local entry = _playerList[idx]
            if not entry then entry = {}; _playerList[idx] = entry end
            entry.unit = unit; entry.guid = guid; entry.name = name; entry.class = class
            _playerClasses[name] = class
        end
    end
    -- Nil out stale entries beyond current count
    for i = idx + 1, #_playerList do
        _playerList[i] = nil
    end
end

local MF = nil -- main frame handle

-- ─── Public API ───────────────────────────────────────────
function sfui.mythic.IsActive() return _mode ~= nil end

function sfui.mythic.IsMythicMode() return _mode == "mythic" end

function sfui.mythic.IsDungeonMode() return _mode == "dungeon" end

function sfui.mythic.IsEnabled()
    if SfuiDB and SfuiDB.mythicHudEnabled ~= nil then
        return SfuiDB.mythicHudEnabled
    end
    return mcfg.enabled ~= false
end

-- ─── Static Pools for Delve / Nemesis Structures ─────────
local staticDelveInfo = {
    isDelve = true,
    name = nil,
    tierText = nil,
    isBountiful = false,
    bountyTooltip = nil,
    livesText = nil,
    livesRemaining = nil,
    livesTooltip = nil,
    livesIcon = nil,
    currencies = {},
    spells = {},
}
local staticNemesisInfo = {
    hasNemesis = false,
    isDone = false,
    text = nil,
    current = nil,
    total = nil,
    tooltip = nil,
    icon = nil,
}
local staticWidgetSetIDs   = {}
local staticWidgetIDs      = {}
local currencyPool         = {}
local spellPool            = {}
local staticDeathBreakdown = {}
local deathBreakdownPool   = {}
local MAX_DELVE_POOL_SIZE  = 30

local function ReleaseDelveSubTables(info)
    for i = #info.currencies, 1, -1 do
        local c = table.remove(info.currencies, i)
        wipe(c)
        if #currencyPool < MAX_DELVE_POOL_SIZE then
            table.insert(currencyPool, c)
        end
    end
    for i = #info.spells, 1, -1 do
        local s = table.remove(info.spells, i)
        wipe(s)
        if #spellPool < MAX_DELVE_POOL_SIZE then
            table.insert(spellPool, s)
        end
    end
end

-- ─── Delve Info Extraction ────────────────────────────────
local function GetDelveInfo()
    local scenName, scenType = nil, nil
    if C_Scenario and C_Scenario.GetInfo then
        local ok, n, _, _, _, _, _, _, _, _, t = pcall(C_Scenario.GetInfo)
        if ok then scenName, scenType = n, t end
    end

    local inDelve = (scenType == 8) or (C_DelvesUI and C_DelvesUI.HasActiveDelve and C_DelvesUI.HasActiveDelve())
    if not inDelve then
        return nil
    end

    local delveInfo = staticDelveInfo
    ReleaseDelveSubTables(delveInfo)
    delveInfo.name = scenName or "Delve"
    delveInfo.tierText = nil
    delveInfo.isBountiful = false
    delveInfo.bountyTooltip = nil
    delveInfo.livesText = nil
    delveInfo.livesRemaining = nil
    delveInfo.livesTooltip = nil
    delveInfo.livesIcon = nil

    wipe(staticWidgetSetIDs)
    if C_Scenario and C_Scenario.GetStepInfo then
        local ok, _, _, _, _, _, _, _, _, _, _, _, stepWidgetSetID = pcall(C_Scenario.GetStepInfo)
        if ok and stepWidgetSetID and stepWidgetSetID > 0 then
            table.insert(staticWidgetSetIDs, stepWidgetSetID)
        end
    end
    table.insert(staticWidgetSetIDs, 252)
    table.insert(staticWidgetSetIDs, 514)
    if C_UIWidgetManager then
        if C_UIWidgetManager.GetObjectiveTrackerWidgetSetID then
            local ok, id = pcall(C_UIWidgetManager.GetObjectiveTrackerWidgetSetID)
            if ok and id then table.insert(staticWidgetSetIDs, id) end
        end
        if C_UIWidgetManager.GetTopCenterWidgetSetID then
            local ok, id = pcall(C_UIWidgetManager.GetTopCenterWidgetSetID)
            if ok and id then table.insert(staticWidgetSetIDs, id) end
        end
    end

    wipe(staticWidgetIDs)
    local foundWidget = nil
    if C_UIWidgetManager then
        for _, setID in ipairs(staticWidgetSetIDs) do
            local ok, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
            if ok and widgets then
                for _, w in ipairs(widgets) do
                    local wID = (type(w) == "table" and w.widgetID) or w
                    if wID then
                        table.insert(staticWidgetIDs, wID)
                        if not foundWidget and C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo then
                            local okVis, vis = pcall(C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo, wID)
                            if okVis and vis and vis.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                                foundWidget = vis
                            end
                        end
                    end
                end
            end
        end
    end

    if foundWidget then
        if foundWidget.headerText and foundWidget.headerText ~= "" then
            delveInfo.name = foundWidget.headerText
        end
        delveInfo.tierText = foundWidget.tierText

        if foundWidget.rewardInfo and foundWidget.rewardInfo.shownState ~= (_G.Enum and _G.Enum.UIWidgetRewardShownState and _G.Enum.UIWidgetRewardShownState.Hidden) then
            delveInfo.isBountiful = true
            delveInfo.bountyTooltip = (foundWidget.rewardInfo.shownState == 1) and foundWidget.rewardInfo.earnedTooltip or
            foundWidget.rewardInfo.unearnedTooltip
        end

        if foundWidget.currencies then
            for _, c in ipairs(foundWidget.currencies) do
                if (c.text and c.text ~= "") or (c.iconFileID and c.iconFileID > 0) then
                    local isLives = false
                    local tt = (c.tooltip or ""):lower()
                    if tt:find("reinforcement") or tt:find("live") or tt:find("revive") or tt:find("death") or tt:find("life") then
                        isLives = true
                    elseif tonumber(c.text) and not tostring(c.text):find("/") and tonumber(c.text) <= 5 and not delveInfo.livesText then
                        isLives = true
                    end

                    if isLives then
                        delveInfo.livesText = c.text
                        delveInfo.livesRemaining = tonumber(tostring(c.text):match("(%d+)"))
                        delveInfo.livesTooltip = c.tooltip
                        delveInfo.livesIcon = c.iconFileID
                    else
                        local curObj = table.remove(currencyPool) or {}
                        curObj.icon = c.iconFileID
                        curObj.text = c.text or ""
                        curObj.leadingText = c.leadingText or ""
                        curObj.tooltip = c.tooltip
                        table.insert(delveInfo.currencies, curObj)
                    end
                end
            end
        end

        if foundWidget.spells then
            for _, s in ipairs(foundWidget.spells) do
                if s.spellID and s.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                    local spObj = table.remove(spellPool) or {}
                    spObj.spellID = s.spellID
                    spObj.text = s.text or ""
                    spObj.stack = (s.stackDisplay and s.stackDisplay > 0 and s.stackDisplay) or
                    (s.text and s.text:match("(%d+)"))
                    spObj.tooltip = s.tooltip
                    table.insert(delveInfo.spells, spObj)
                end
            end
        end
    end

    -- Fallbacks for Tier
    if not delveInfo.tierText and C_DelvesUI then
        if C_DelvesUI.GetActiveDelveTier then
            local ok, tierInfo = pcall(C_DelvesUI.GetActiveDelveTier)
            if ok and tierInfo and tierInfo.tier then
                delveInfo.tierText = tostring(tierInfo.tier)
            end
        end
        if not delveInfo.tierText and C_DelvesUI.GetWorldTierDifficultyForActivePlayer then
            local ok, tier = pcall(C_DelvesUI.GetWorldTierDifficultyForActivePlayer)
            if ok and tier and tier > 0 then
                delveInfo.tierText = tostring(tier)
            end
        end
    end

    -- Fallback active spells
    if #delveInfo.spells == 0 and C_ScenarioInfo and C_ScenarioInfo.GetTieredEntranceActiveSpells then
        local ok, activeSpells = pcall(C_ScenarioInfo.GetTieredEntranceActiveSpells)
        if ok and activeSpells then
            for _, sID in ipairs(activeSpells) do
                local spObj = table.remove(spellPool) or {}
                spObj.spellID = sID
                table.insert(delveInfo.spells, spObj)
            end
        end
    end

    return delveInfo
end

-- ─── Nemesis Info Extraction ──────────────────────────────
local function GetNemesisInfo(delveInfo)
    local nemesis = staticNemesisInfo
    nemesis.hasNemesis = false
    nemesis.isDone = false
    nemesis.text = nil
    nemesis.current = nil
    nemesis.total = nil
    nemesis.tooltip = nil
    nemesis.icon = nil

    -- 1. Check Scenario criteria
    if C_Scenario and C_Scenario.GetStepInfo and C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo then
        local ok, _, _, numCriteria = pcall(C_Scenario.GetStepInfo)
        if ok and numCriteria and numCriteria > 0 then
            for i = 1, numCriteria do
                local okC, info = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
                if okC and info and info.description and info.description ~= "" then
                    local descLower = info.description:lower()
                    if descLower:find("nemesis") or descLower:find("zekvir") or descLower:find("influence") or
                       descLower:find("empowered") or descLower:find("underpin") or descLower:find("ky'veza") then
                        nemesis.hasNemesis = true
                        nemesis.tooltip = info.description
                        if info.completed then
                            nemesis.isDone = true
                            nemesis.current = info.totalQuantity or 4
                            nemesis.total   = info.totalQuantity or 4
                        else
                            local cur = info.quantity or 0
                            local tot = (info.totalQuantity and info.totalQuantity > 0) and info.totalQuantity or 4
                            nemesis.current = cur
                            nemesis.total   = tot
                            if cur >= tot and tot > 0 then
                                nemesis.isDone = true
                            end
                        end
                        break
                    end
                end
            end
        end
    end

    -- 2. Check Delve Spells / Affixes
    if delveInfo and delveInfo.spells then
        for _, s in ipairs(delveInfo.spells) do
            local tt = (s.tooltip or ""):lower()
            local spellName = ""
            if s.spellID then
                local n = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(s.spellID)) or
                          (_G.GetSpellInfo and _G.GetSpellInfo(s.spellID))
                if n then spellName = n:lower() end
            end

            if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or tt:find("empowered") or
               tt:find("underpin") or tt:find("ky'veza") or spellName:find("nemesis") or spellName:find("zekvir") or
               spellName:find("influence") or spellName:find("empowered") then
                nemesis.hasNemesis = true
                if s.spellID then
                    nemesis.icon = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(s.spellID)) or
                                   (_G.GetSpellTexture and _G.GetSpellTexture(s.spellID)) or nemesis.icon
                end
                nemesis.tooltip = s.tooltip or nemesis.tooltip

                -- Extract total / remain from tooltip
                local cM, tM = tt:match("(%d+)%s*/%s*(%d+)")
                if cM and tM then
                    nemesis.current = tonumber(cM)
                    nemesis.total   = tonumber(tM)
                else
                    local totMatch = tt:match("defeat (%d+)") or tt:match("(%d+)%s*empowered") or tt:match("(%d+)%s*groups?") or tt:match("(%d+)%s*packs?")
                    if totMatch then
                        nemesis.total = tonumber(totMatch)
                    end
                    local remainMatch = tt:match("(%d+)%s*remain") or tt:match("remain%a*%s*:%s*(%d+)")
                    if remainMatch then
                        nemesis.current = tonumber(remainMatch)
                    end
                end

                if not nemesis.current and s.stack and tostring(s.stack) ~= "" and tostring(s.stack) ~= "0" then
                    local st = tonumber(s.stack)
                    if st then nemesis.current = st end
                elseif not nemesis.current and s.text and s.text ~= "" then
                    local cText, tText = s.text:match("(%d+)%s*/%s*(%d+)")
                    if cText and tText then
                        nemesis.current = tonumber(cText)
                        nemesis.total   = tonumber(tText)
                    elseif tonumber(s.text) then
                        nemesis.current = tonumber(s.text)
                    end
                end

                if not nemesis.current and s.spellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                    local okA, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, s.spellID)
                    if okA and aura then
                        if aura.applications and aura.applications > 0 then
                            nemesis.current = aura.applications
                        elseif aura.points and aura.points[1] and aura.points[1] > 0 then
                            nemesis.current = aura.points[1]
                        end
                    end
                end
            end
        end
    end

    -- 3. Check Delve Currencies
    if delveInfo and delveInfo.currencies then
        for _, c in ipairs(delveInfo.currencies) do
            local tt = (c.tooltip or ""):lower()
            local lt = (c.leadingText or ""):lower()
            if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or tt:find("empowered") or
               tt:find("underpin") or tt:find("ky'veza") or lt:find("nemesis") or lt:find("zekvir") or lt:find("influence") then
                nemesis.hasNemesis = true
                nemesis.icon = c.icon or nemesis.icon
                nemesis.tooltip = c.tooltip or nemesis.tooltip

                local valStr = c.text or c.leadingText or ""
                local cM, tM = valStr:match("(%d+)%s*/%s*(%d+)")
                if cM and tM then
                    nemesis.current = tonumber(cM)
                    nemesis.total   = tonumber(tM)
                elseif tonumber(valStr) then
                    nemesis.current = tonumber(valStr)
                end

                if not nemesis.current and c.tooltip then
                    local cT, tT = c.tooltip:match("(%d+)%s*/%s*(%d+)")
                    if cT and tT then
                        nemesis.current = tonumber(cT)
                        nemesis.total   = tonumber(tT)
                    end
                end
            end
        end
    end

    -- 4. Check UI Widgets in active sets
    if C_UIWidgetManager then
        for _, wID in ipairs(staticWidgetIDs) do
            -- Check StatusBar widgets
            if C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
                local okVis, vis = pcall(C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo, wID)
                if okVis and vis and vis.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                    local tt = (vis.tooltip or ""):lower()
                    local txt = (vis.text or ""):lower()
                    if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or txt:find("nemesis") or txt:find("zekvir") then
                        nemesis.hasNemesis = true
                        nemesis.tooltip = vis.tooltip or nemesis.tooltip
                        if vis.barValue and vis.barMax and vis.barMax > 0 then
                            nemesis.current = vis.barValue
                            nemesis.total   = vis.barMax
                        end
                        break
                    end
                end
            end
            -- Check IconAndText / TextWithState widgets
            if not nemesis.current and C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo then
                local okVis, vis = pcall(C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo, wID)
                if okVis and vis and vis.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                    local tt = (vis.tooltip or ""):lower()
                    local txt = (vis.text or ""):lower()
                    if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or txt:find("nemesis") or txt:find("zekvir") then
                        nemesis.hasNemesis = true
                        nemesis.tooltip = vis.tooltip or nemesis.tooltip
                        local cW, tW = (vis.text or ""):match("(%d+)%s*/%s*(%d+)")
                        if cW and tW then
                            nemesis.current = tonumber(cW)
                            nemesis.total   = tonumber(tW)
                        end
                        break
                    end
                end
            end
            if not nemesis.current and C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
                local okVis, vis = pcall(C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo, wID)
                if okVis and vis and vis.shownState ~= (_G.Enum and _G.Enum.WidgetShownState and _G.Enum.WidgetShownState.Hidden) then
                    local tt = (vis.tooltip or ""):lower()
                    local txt = (vis.text or ""):lower()
                    if tt:find("nemesis") or tt:find("zekvir") or tt:find("influence") or txt:find("nemesis") or txt:find("zekvir") then
                        nemesis.hasNemesis = true
                        nemesis.tooltip = vis.tooltip or nemesis.tooltip
                        local cW, tW = (vis.text or ""):match("(%d+)%s*/%s*(%d+)")
                        if cW and tW then
                            nemesis.current = tonumber(cW)
                            nemesis.total   = tonumber(tW)
                        end
                        break
                    end
                end
            end
            if nemesis.current and nemesis.total then break end
        end
    end

    -- Ensure final format is always accurate
    if nemesis.hasNemesis then
        local tot = nemesis.total or 4
        local cur = nemesis.current or tot
        nemesis.current = cur
        nemesis.total   = tot
        if nemesis.isDone or (cur == 0 and tot > 0 and (nemesis.tooltip and nemesis.tooltip:lower():find("remain"))) then
            nemesis.isDone = true
            nemesis.text = "Done"
        else
            nemesis.text = string_format("%d/%d", cur, tot)
        end
    end

    return nemesis
end

-- ─── Frame Construction ───────────────────────────────────
local function BuildHUDFrame()
    if MF then return end

    MF = CreateFrame("Frame", "SfuiMythicHUD", UIParent, "BackdropTemplate")
    MF:SetSize(HUD_W, 10)
    MF:SetClampedToScreen(true)
    MF:SetMovable(true)
    MF:EnableMouse(false)
    MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", mcfg.posX or -10, mcfg.posY or -10)

    MF:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    MF:SetBackdropColor(0.06, 0.06, 0.08, 0.88)
    MF:SetBackdropBorderColor(0, 0, 0, 0.9)

    -- Header: dungeon name + key/diff label
    local hdr = CreateFrame("Frame", nil, MF)
    hdr:SetPoint("TOPLEFT", MF, "TOPLEFT", HUD_PAD, -HUD_PAD)
    hdr:SetPoint("TOPRIGHT", MF, "TOPRIGHT", -HUD_PAD, -HUD_PAD)
    hdr:SetHeight(24)
    MF.header = hdr

    MF.dungeonText = MakeText(hdr, "GameFontNormal", unpack(COLORS.cyan))
    MF.dungeonText:SetPoint("TOPLEFT", hdr, "TOPLEFT", 0, 0)
    MF.dungeonText:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -60, 0)
    MF.dungeonText:SetJustifyH("LEFT")
    MF.dungeonText:SetText("Mythic+")

    MF.levelText = MakeText(hdr, "GameFontNormalLarge", 1, 0.82, 0, 1)
    MF.levelText:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", 0, 2)
    MF.levelText:SetJustifyH("RIGHT")
    MF.levelText:SetText("+?")

    -- Delve badges row (Currencies: Nemesis 3/4, Keys 1, Bountiful, Spells + Lives on Far Right)
    local delveRow = CreateFrame("Frame", nil, MF)
    delveRow:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    delveRow:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, -2)
    delveRow:SetHeight(18)
    delveRow:EnableMouse(false)
    MF.delveRow = delveRow
    MF.delveBadges = {}

    -- Dedicated Lives counter anchored all the way to the right
    local delveLivesFrame = CreateFrame("Frame", nil, delveRow)
    delveLivesFrame:SetPoint("TOPRIGHT", delveRow, "TOPRIGHT", 0, 0)
    delveLivesFrame:SetHeight(18)
    delveLivesFrame:EnableMouse(true)
    MF.delveLivesFrame = delveLivesFrame

    MF.delveLivesText = MakeText(delveLivesFrame, "GameFontNormalSmall", 0.3, 1, 0.3, 1, "RIGHT")
    MF.delveLivesText:SetPoint("RIGHT", delveLivesFrame, "RIGHT", 0, 0)
    MF.delveLivesText:SetJustifyH("RIGHT")
    MF.delveLivesText:SetText("")

    delveLivesFrame:SetScript("OnEnter", function(self)
        if GameTooltip and self.tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Delve Lives Remaining", 0.4, 1, 0.4)
            GameTooltip:AddLine(self.tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    delveLivesFrame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- Dedicated Nemesis counter next to Lives
    local delveNemesisFrame = CreateFrame("Frame", nil, delveRow)
    delveNemesisFrame:SetHeight(18)
    delveNemesisFrame:EnableMouse(true)
    MF.delveNemesisFrame = delveNemesisFrame

    MF.delveNemesisText = MakeText(delveNemesisFrame, "GameFontNormalSmall", 0.75, 0.40, 1.00, 1, "RIGHT")
    MF.delveNemesisText:SetPoint("RIGHT", delveNemesisFrame, "RIGHT", 0, 0)
    MF.delveNemesisText:SetJustifyH("RIGHT")
    MF.delveNemesisText:SetText("")

    delveNemesisFrame:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Nemesis Progress", 0.75, 0.35, 1)
            GameTooltip:AddLine(self.tooltip or "Nemesis Influence: Defeat empowered enemies to draw out the Nemesis.", 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    delveNemesisFrame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    delveRow:Hide()

    -- Affix icon row (M+ only)
    MF.affixRow = CreateFrame("Frame", nil, MF)
    MF.affixRow:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -4)
    MF.affixRow:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, -4)
    MF.affixRow:SetHeight(22)
    MF.affixes = {} -- pooled affix entries: { frame, icon, stackText }

    -- Timer bar (M+ only)
    local timerSection = CreateFrame("Frame", nil, MF)
    timerSection:SetPoint("TOPLEFT", MF.affixRow, "BOTTOMLEFT", 0, -6)
    timerSection:SetPoint("TOPRIGHT", MF.affixRow, "BOTTOMRIGHT", 0, -6)
    timerSection:SetHeight(16)
    timerSection:Hide()
    MF.timerSection = timerSection

    MF.timerBar = MakeStatusBar(timerSection, COLORS.bar_fill, COLORS.bar_bg)
    MF.timerBar:SetAllPoints(timerSection)
    MF.timerBar:SetMinMaxValues(0, 1)
    MF.timerBar:SetValue(0)

    -- Dedicated overlay frame above StatusBar fill
    local timerOverlay = CreateFrame("Frame", nil, MF.timerBar)
    timerOverlay:SetAllPoints(MF.timerBar)
    timerOverlay:SetFrameLevel(MF.timerBar:GetFrameLevel() + 5)
    MF.timerOverlay = timerOverlay

    MF.timerText = MakeText(timerOverlay, "GameFontHighlightSmall", 1, 1, 1, 1, "LEFT")
    MF.timerText:SetPoint("LEFT", timerOverlay, "LEFT", 4, 0)
    MF.timerText:SetJustifyH("LEFT")
    MF.timerText:SetText("--:-- / --:--")

    MF.chestText = MakeText(timerOverlay, "GameFontHighlightSmall", 0.20, 1.00, 0.40, 1, "CENTER")
    MF.chestText:SetPoint("CENTER", timerOverlay, "CENTER", 0, 0)
    MF.chestText:SetJustifyH("CENTER")
    MF.chestText:SetText("+3 --:--")

    -- Chest tick marks (+3 green, +2 yellow)
    MF.tick3 = timerOverlay:CreateTexture(nil, "OVERLAY")
    MF.tick3:SetTexture("Interface/Buttons/WHITE8X8")
    MF.tick3:SetVertexColor(0.20, 1.00, 0.40, 1)
    MF.tick3:SetSize(2, 16)
    MF.tick3:Hide()

    MF.tick2 = timerOverlay:CreateTexture(nil, "OVERLAY")
    MF.tick2:SetTexture("Interface/Buttons/WHITE8X8")
    MF.tick2:SetVertexColor(0.80, 0.80, 0.00, 1)
    MF.tick2:SetSize(2, 16)
    MF.tick2:Hide()

    -- Death counter frame with tooltip
    local deathFrame = CreateFrame("Frame", nil, timerOverlay)
    deathFrame:SetPoint("RIGHT", timerOverlay, "RIGHT", -4, 0)
    deathFrame:SetHeight(16)
    deathFrame:EnableMouse(true)
    deathFrame:SetFrameLevel(timerOverlay:GetFrameLevel() + 2)
    MF.deathFrame = deathFrame

    MF.deathText = MakeText(deathFrame, "GameFontHighlightSmall", 1, 0.25, 0.25, 1, "RIGHT")
    MF.deathText:SetPoint("RIGHT", deathFrame, "RIGHT", 0, 0)
    MF.deathText:SetJustifyH("RIGHT")
    MF.deathText:SetText("")

    local function deathSortComparator(a, b) return a.count > b.count end

    deathFrame:SetScript("OnEnter", function(self)
        local okd, deaths, timeLostSec = pcall(C_ChallengeMode.GetDeathCount)
        if okd and deaths and deaths > 0 then
            local tl = timeLostSec or (deaths * 5)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(string_format("Deaths: %d", deaths), 1, 0.3, 0.3)
                GameTooltip:AddLine(string_format("Time lost: %s", FormatTime(tl)), 0.8, 0.8, 0.8)

                if _playerDeaths and next(_playerDeaths) then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Player Breakdown:", 1, 0.82, 0)
                    for i = #staticDeathBreakdown, 1, -1 do
                        local obj = table.remove(staticDeathBreakdown, i)
                        wipe(obj)
                        if #deathBreakdownPool < 20 then
                            table.insert(deathBreakdownPool, obj)
                        end
                    end
                    for name, count in pairs(_playerDeaths) do
                        local obj = table.remove(deathBreakdownPool) or {}
                        obj.name = name
                        obj.count = count
                        obj.class = _playerClasses[name]
                        table.insert(staticDeathBreakdown, obj)
                    end
                    table.sort(staticDeathBreakdown, deathSortComparator)
                    for _, p in ipairs(staticDeathBreakdown) do
                        local colorCode = "ffffffff"
                        if p.class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[p.class] then
                            colorCode = _G.RAID_CLASS_COLORS[p.class].colorStr or "ffffffff"
                        end
                        GameTooltip:AddDoubleLine(string_format("|c%s%s|r", colorCode, p.name),
                            string_format("%d death%s", p.count, p.count > 1 and "s" or ""), 1, 1, 1, 0.7, 0.7, 0.7)
                    end
                end
                GameTooltip:Show()
            end
        end
    end)
    deathFrame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)


    -- Separator 1 (between header/delve/timer and bosses)
    local sep1 = MakeSep(MF)
    sep1:SetPoint("TOPLEFT", timerSection, "BOTTOMLEFT", 0, -4)
    sep1:SetPoint("TOPRIGHT", timerSection, "BOTTOMRIGHT", 0, -4)
    MF.sep1 = sep1

    -- Boss / objectives container
    MF.bossContainer = CreateFrame("Frame", nil, MF)
    MF.bossContainer:SetPoint("TOPLEFT", sep1, "BOTTOMLEFT", 0, -4)
    MF.bossContainer:SetPoint("TOPRIGHT", sep1, "BOTTOMRIGHT", 0, -4)
    MF.bossContainer:SetHeight(10)
    MF.bossRows = {}

    -- Separator 2 (between bosses and forces)
    local sep2 = MakeSep(MF)
    sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
    sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
    MF.sep2 = sep2

    -- Enemy Forces bar
    local forcesSection = CreateFrame("Frame", nil, MF)
    forcesSection:SetPoint("TOPLEFT", sep2, "BOTTOMLEFT", 0, -4)
    forcesSection:SetPoint("TOPRIGHT", sep2, "BOTTOMRIGHT", 0, -4)
    forcesSection:SetHeight(14)
    MF.forcesSection = forcesSection

    MF.forcesBar = MakeStatusBar(forcesSection, COLORS.forces, COLORS.bar_bg)
    MF.forcesBar:SetAllPoints(forcesSection)
    MF.forcesBar:SetMinMaxValues(0, 1)
    MF.forcesBar:SetValue(0)

    -- Dedicated overlay frame above Forces StatusBar fill
    local forcesOverlay = CreateFrame("Frame", nil, MF.forcesBar)
    forcesOverlay:SetAllPoints(MF.forcesBar)
    forcesOverlay:SetFrameLevel(MF.forcesBar:GetFrameLevel() + 5)
    MF.forcesOverlay = forcesOverlay

    MF.forcesText = MakeText(forcesOverlay, "GameFontHighlightSmall", 1, 1, 1, 1, "LEFT")
    MF.forcesText:SetPoint("LEFT", forcesOverlay, "LEFT", 4, 0)
    MF.forcesText:SetJustifyH("LEFT")
    MF.forcesText:SetText("0.00%")

    MF.forcesCountText = MakeText(forcesOverlay, "GameFontHighlightSmall", 0.95, 0.95, 0.95, 1, "RIGHT")
    MF.forcesCountText:SetPoint("RIGHT", forcesOverlay, "RIGHT", -4, 0)
    MF.forcesCountText:SetText("")

    -- Drag handle (shown only when unlocked)
    MF.dragBar = CreateFrame("Frame", nil, MF, "BackdropTemplate")
    MF.dragBar:SetPoint("TOPLEFT", MF, "TOPLEFT", 0, 0)
    MF.dragBar:SetPoint("TOPRIGHT", MF, "TOPRIGHT", 0, 0)
    MF.dragBar:SetHeight(4)
    MF.dragBar:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8" })
    MF.dragBar:SetBackdropColor(0.4, 0.0, 1.0, 0.6)
    MF.dragBar:SetScript("OnMouseDown", function() MF:StartMoving() end)
    MF.dragBar:SetScript("OnMouseUp", function()
        MF:StopMovingOrSizing()
        if SfuiDB then
            local _, _, _, x, y = MF:GetPoint()
            SfuiDB.mythicHudX   = x
            SfuiDB.mythicHudY   = y
            SfuiDB.questlogX    = x
            SfuiDB.questlogY    = y
        end
    end)
    MF.dragBar:Hide()

    MF:Hide()
end

-- ─── Delve Badge Pool ─────────────────────────────────────
-- Renders badges for Delve currencies (Nemesis 3/4, Lives 4, Keys 1),
-- Bountiful status, and active Delve spells.
local function GetOrCreateDelveBadge(idx)
    local badges = MF.delveBadges
    if badges[idx] then
        badges[idx].frame:Show()
        return badges[idx]
    end

    local frame = CreateFrame("Frame", nil, MF.delveRow)
    frame:SetHeight(18)
    frame:EnableMouse(true)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", frame, "LEFT", 0, 0)

    local text = MakeText(frame, "GameFontNormalSmall", 1, 1, 1, 1, "LEFT")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)

    local stackText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stackText:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -1)
    stackText:SetTextColor(1, 1, 1, 1)

    frame:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        if self.title then
            GameTooltip:AddLine(self.title, 1, 0.82, 0)
        end
        if self.customTooltip and self.customTooltip ~= "" then
            GameTooltip:AddLine(self.customTooltip, 1, 1, 1, true)
        elseif self.spellID then
            if GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(self.spellID)
            else
                local spellName = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(self.spellID)) or
                                  (_G.GetSpellInfo and _G.GetSpellInfo(self.spellID))
                if spellName then GameTooltip:AddLine(spellName, 1, 1, 1) end
            end
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    badges[idx] = { frame = frame, icon = icon, text = text, stackText = stackText }
    return badges[idx]
end

local function HideExtraDelveBadges(count)
    for i = count + 1, #MF.delveBadges do
        MF.delveBadges[i].frame:Hide()
    end
end

-- ─── Boss Row Pool ────────────────────────────────────────
local bossRowH = 18

local function GetOrCreateBossRow(idx)
    local rows = MF.bossRows
    if rows[idx] then
        rows[idx].row:Show()
        return rows[idx]
    end

    local row = CreateFrame("Frame", nil, MF.bossContainer)
    row:SetHeight(bossRowH)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(14, 14)
    icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)

    local checkTex = row:CreateTexture(nil, "OVERLAY")
    checkTex:SetSize(14, 14)
    checkTex:SetTexture("Interface/RaidFrame/ReadyCheck-Ready")
    checkTex:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    checkTex:Hide()

    local nameText = MakeText(row, "GameFontNormalSmall", CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
    nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 4, 0)
    nameText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(true)

    local splitText = MakeText(row, "GameFontNormalSmall", CLR_DIM_R, CLR_DIM_G, CLR_DIM_B)
    splitText:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    splitText:SetJustifyH("RIGHT")
    splitText:SetText("")

    rows[idx] = { row = row, icon = icon, check = checkTex, name = nameText, split = splitText }
    return rows[idx]
end

-- Only iterate from count+1 to _lastBossCount — not a hard-coded 20.
local function HideExtraBossRows(count)
    for i = count + 1, _lastBossCount do
        if MF.bossRows[i] then
            MF.bossRows[i].row:Hide()
        end
    end
    _lastBossCount = count
end

-- ─── Affix Frame Pool (M+ only) ───────────────────────────
local function BuildAffixRow(affixes)
    local n    = affixes and #affixes or 0
    local size = 20
    local gap  = 4

    for i = n + 1, #MF.affixes do
        MF.affixes[i].frame:Hide()
    end

    if n == 0 then
        MF.affixRow:Hide()
        MF.affixRow:SetHeight(0)
        return
    end

    MF.affixRow:Show()
    local xOff = 0
    for i = 1, n do
        local affixID = affixes[i]
        local af = MF.affixes[i]

        if not af then
            local frame = CreateFrame("Frame", nil, MF.affixRow)
            frame:SetSize(size, size)
            frame:EnableMouse(true)
            local icon = frame:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints(frame)
            frame:SetScript("OnLeave", function()
                if GameTooltip then GameTooltip:Hide() end
            end)
            frame:SetScript("OnEnter", function(self)
                if GameTooltip then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.affixName then GameTooltip:SetText(self.affixName) end
                    if self.affixDesc then GameTooltip:AddLine(self.affixDesc, nil, nil, nil, true) end
                    GameTooltip:Show()
                end
            end)
            af = { frame = frame, icon = icon }
            MF.affixes[i] = af
        end

        af.frame:SetSize(size, size)
        af.frame:ClearAllPoints()
        af.frame:SetPoint("LEFT", MF.affixRow, "LEFT", xOff, 0)
        af.frame:Show()

        local ok, name, desc, fileDataID = pcall(C_ChallengeMode.GetAffixInfo, affixID)
        af.icon:SetTexture(ok and fileDataID or nil)
        af.frame.affixName = ok and name or nil
        af.frame.affixDesc = ok and desc or nil


        xOff = xOff + size + gap
    end

    MF.affixRow:SetHeight(n > 0 and (size + 2) or 0)
end

-- ─── Chest Tick Placement ─────────────────────────────────
local function PlaceChestTicks()
    if _timeLimit <= 0 or not MF or not MF.timerOverlay then return end
    local barW = MF.timerSection:GetWidth()
    if barW <= 0 then barW = (HUD_W or 280) - (HUD_PAD * 2) end
    -- +3 chest = 60% of time limit, +2 chest = 80% of time limit
    MF.tick3:ClearAllPoints()
    MF.tick3:SetPoint("LEFT", MF.timerOverlay, "LEFT", barW * 0.60, 0)
    MF.tick2:ClearAllPoints()
    MF.tick2:SetPoint("LEFT", MF.timerOverlay, "LEFT", barW * 0.80, 0)
end

-- ─── Layout ───────────────────────────────────────────────
local function RelayoutHUD(numBoss, isDelve, delveRowH, hasForces)
    local isMythic = (_mode == "mythic")
    local totalBossH = 0

    for i = 1, numBoss do
        local r = MF.bossRows[i]
        if r and r.row:IsShown() then
            local rH = r.row:GetHeight() or 16
            r.row:ClearAllPoints()
            r.row:SetPoint("LEFT", MF.bossContainer, "LEFT", 0, 0)
            r.row:SetPoint("RIGHT", MF.bossContainer, "RIGHT", 0, 0)
            r.row:SetPoint("TOP", MF.bossContainer, "TOP", 0, -totalBossH)
            totalBossH = totalBossH + rH + 3
        end
    end
    if totalBossH > 0 then
        totalBossH = totalBossH - 3
    end
    local bossH = totalBossH
    MF.bossContainer:SetHeight(bossH)

    if isMythic then
        MF.delveRow:Hide()
        MF.affixRow:ClearAllPoints()
        MF.affixRow:SetPoint("TOPLEFT", MF.header, "BOTTOMLEFT", 0, -4)
        MF.affixRow:SetPoint("TOPRIGHT", MF.header, "BOTTOMRIGHT", 0, -4)
        MF.affixRow:SetShown(#MF.affixes > 0)

        MF.timerSection:Show()
        MF.timerSection:SetHeight(16)
        PlaceChestTicks()
        MF.deathText:Show()
        MF.sep1:SetShown(bossH > 0)
        MF.sep1:ClearAllPoints()
        MF.sep1:SetPoint("TOPLEFT", MF.timerSection, "BOTTOMLEFT", 0, -4)
        MF.sep1:SetPoint("TOPRIGHT", MF.timerSection, "BOTTOMRIGHT", 0, -4)

        MF.bossContainer:ClearAllPoints()
        MF.bossContainer:SetPoint("TOPLEFT", MF.sep1, "BOTTOMLEFT", 0, -4)
        MF.bossContainer:SetPoint("TOPRIGHT", MF.sep1, "BOTTOMRIGHT", 0, -4)

        MF.sep2:ClearAllPoints()
        MF.sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
        MF.sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
        MF.sep2:Show()
        MF.forcesSection:Show()

        local affixH = MF.affixRow:IsShown() and (4 + MF.affixRow:GetHeight()) or 0
        local totalH = HUD_PAD + 24 + affixH + (6 + 16) + (bossH > 0 and (4 + 1 + 4 + bossH) or 0) + (4 + 1 + 4 + 14) +
        HUD_PAD
        MF:SetHeight(math_max(60, totalH))
    elseif isDelve then
        MF.delveRow:SetShown(delveRowH > 0)
        MF.affixRow:Hide()
        MF.timerSection:Hide()
        MF.timerSection:SetHeight(0)
        MF.tick2:Hide()
        MF.tick3:Hide()
        MF.deathText:Hide()

        local topAnchor = (delveRowH > 0) and MF.delveRow or MF.header

        MF.sep1:SetShown(bossH > 0)
        MF.sep1:ClearAllPoints()
        MF.sep1:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -4)
        MF.sep1:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -4)

        MF.bossContainer:ClearAllPoints()
        if bossH > 0 then
            MF.bossContainer:SetPoint("TOPLEFT", MF.sep1, "BOTTOMLEFT", 0, -4)
            MF.bossContainer:SetPoint("TOPRIGHT", MF.sep1, "BOTTOMRIGHT", 0, -4)
        else
            MF.bossContainer:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -2)
            MF.bossContainer:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -2)
        end

        MF.sep2:ClearAllPoints()
        MF.sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
        MF.sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
        MF.sep2:SetShown(hasForces)
        MF.forcesSection:SetShown(hasForces)

        local dRowGap = delveRowH > 0 and (4 + delveRowH) or 0
        local sep1H   = bossH > 0 and (4 + 1 + 4) or 0
        local bossGap = bossH > 0 and bossH or 0
        local forcesH = hasForces and (4 + 1 + 4 + 14) or 0
        local totalH  = HUD_PAD + 24 + dRowGap + sep1H + bossGap + forcesH + HUD_PAD
        MF:SetHeight(math_max(50, totalH))
    else
        -- Regular Dungeon / Scenario
        MF.delveRow:Hide()
        MF.affixRow:Hide()
        MF.timerSection:Hide()
        MF.timerSection:SetHeight(0)
        MF.tick2:Hide()
        MF.tick3:Hide()
        MF.deathText:Hide()

        MF.sep1:SetShown(bossH > 0)
        MF.sep1:ClearAllPoints()
        MF.sep1:SetPoint("TOPLEFT", MF.header, "BOTTOMLEFT", 0, -4)
        MF.sep1:SetPoint("TOPRIGHT", MF.header, "BOTTOMRIGHT", 0, -4)

        MF.bossContainer:ClearAllPoints()
        if bossH > 0 then
            MF.bossContainer:SetPoint("TOPLEFT", MF.sep1, "BOTTOMLEFT", 0, -4)
            MF.bossContainer:SetPoint("TOPRIGHT", MF.sep1, "BOTTOMRIGHT", 0, -4)
        else
            MF.bossContainer:SetPoint("TOPLEFT", MF.header, "BOTTOMLEFT", 0, -6)
            MF.bossContainer:SetPoint("TOPRIGHT", MF.header, "BOTTOMRIGHT", 0, -6)
        end

        MF.sep2:ClearAllPoints()
        MF.sep2:SetPoint("TOPLEFT", MF.bossContainer, "BOTTOMLEFT", 0, -4)
        MF.sep2:SetPoint("TOPRIGHT", MF.bossContainer, "BOTTOMRIGHT", 0, -4)
        MF.sep2:SetShown(hasForces)
        MF.forcesSection:SetShown(hasForces)

        local sep1H   = bossH > 0 and (4 + 1 + 4) or 0
        local bossGap = bossH > 0 and bossH or 0
        local forcesH = hasForces and (4 + 1 + 4 + 14) or 0
        local totalH  = HUD_PAD + 24 + sep1H + bossGap + forcesH + HUD_PAD
        MF:SetHeight(math_max(50, totalH))
    end
end

-- ─── Core Update: merged boss + forces in one GetStepInfo call ───
local function UpdateInstanceState()
    if not (C_Scenario and C_ScenarioInfo) then return end
    local ok, _, _, numCriteria = pcall(C_Scenario.GetStepInfo)
    if not ok or not numCriteria then return end

    -- Delve state update
    local delveInfo = GetDelveInfo()
    local delveRowH = 0
    if delveInfo then
        MF.dungeonText:SetText(delveInfo.name or "Delve")
        local tStr = delveInfo.tierText
        if tStr and not tostring(tStr):lower():find("tier") then
            tStr = "Tier " .. tostring(tStr)
        end
        MF.levelText:SetText(tStr and string_format("|cffa864ff%s|r", tStr) or "|cffa864ffDelve|r")

        -- 1. Lives remaining pinned all the way to the right
        local livesW = 0
        if delveInfo.livesText and delveInfo.livesText ~= "" then
            if delveInfo.livesRemaining == 0 then
                MF.delveLivesText:SetText("|cffff44440 Lives|r")
            else
                MF.delveLivesText:SetText(string_format("|cff44ff44%s Lives|r", delveInfo.livesText))
            end
            livesW = MF.delveLivesText:GetStringWidth() + 4
            MF.delveLivesFrame:SetWidth(livesW)
            MF.delveLivesFrame:Show()

            MF.delveLivesFrame.tooltip = delveInfo.livesTooltip or
            ("Reinforcements remaining: " .. delveInfo.livesText .. " lives.\nRunning out forfeits the Heavy Bountiful Coffer.")
        else
            MF.delveLivesText:SetText("")
            MF.delveLivesFrame.tooltip = nil
            MF.delveLivesFrame:Hide()
        end

        -- 1b. Nemesis progress pinned next to Lives
        local nemesis = GetNemesisInfo(delveInfo)
        local nemesisW = 0
        if nemesis.hasNemesis then
            local nText = nemesis.text
            if nemesis.isDone or nText == "Done" then
                MF.delveNemesisText:SetText("|cffa335eeNemesis:|r |cff44ff44Done|r")
            elseif nText and nText ~= "" then
                MF.delveNemesisText:SetText(string_format("|cffa335eeNemesis: %s|r", nText))
            else
                local cur = nemesis.current or (nemesis.total or 4)
                local tot = nemesis.total or 4
                MF.delveNemesisText:SetText(string_format("|cffa335eeNemesis: %d/%d|r", cur, tot))
            end
            nemesisW = MF.delveNemesisText:GetStringWidth() + 4
            MF.delveNemesisFrame:SetWidth(nemesisW)
            MF.delveNemesisFrame:ClearAllPoints()
            if livesW > 0 then
                MF.delveNemesisFrame:SetPoint("RIGHT", MF.delveLivesFrame, "LEFT", -8, 0)
            else
                MF.delveNemesisFrame:SetPoint("TOPRIGHT", MF.delveRow, "TOPRIGHT", 0, 0)
            end
            MF.delveNemesisFrame.tooltip = nemesis.tooltip or "Nemesis Influence: Defeat empowered enemies to draw out the Nemesis."
            MF.delveNemesisFrame:Show()
        else
            MF.delveNemesisText:SetText("")
            MF.delveNemesisFrame.tooltip = nil
            MF.delveNemesisFrame:Hide()
        end

        local badgeIdx = 0

        -- 2. Bountiful Badge
        if delveInfo.isBountiful then
            badgeIdx = badgeIdx + 1
            local b = GetOrCreateDelveBadge(badgeIdx)
            b.icon:SetTexture(413571)
            b.icon:SetSize(16, 16)
            b.stackText:Hide()
            b.text:SetText("|cffffd100Bountiful|r")
            b.text:Show()
            local w = 16 + 4 + b.text:GetStringWidth()
            b.frame:SetSize(w, 18)
            b.frame.title = "Bountiful Delve"
            b.frame.customTooltip = delveInfo.bountyTooltip or
            "Heavy Bountiful Coffer available upon delve completion with a Restored Coffer Key."
            b.frame.spellID = nil
        end

        -- 3. Currencies (Nemesis 3/4, Keys 1, etc. — matching default UI)
        if delveInfo.currencies then
            for _, c in ipairs(delveInfo.currencies) do
                badgeIdx = badgeIdx + 1
                local b = GetOrCreateDelveBadge(badgeIdx)
                b.icon:SetTexture(c.icon or 134400)
                b.icon:SetSize(16, 16)
                b.stackText:Hide()

                local valStr = c.text or ""
                if (not valStr or valStr == "") and c.leadingText and c.leadingText ~= "" then
                    valStr = c.leadingText
                end
                if (not valStr or valStr == "") and c.tooltip then
                    valStr = c.tooltip:match("(%d+/%d+)") or c.tooltip:match("(%d+ of %d+)") or
                    c.tooltip:match("(%d+ remaining)") or ""
                end

                local isNemCurr = (c.tooltip and c.tooltip:lower():find("nemesis")) or (c.leadingText and c.leadingText:lower():find("nemesis"))
                if (not valStr or valStr == "") and isNemCurr and nemesis.text then
                    valStr = nemesis.text
                end

                if valStr ~= "" then
                    if isNemCurr then
                        b.text:SetText(string_format("|cffa335ee%s|r", valStr))
                    elseif valStr:find("/") then
                        b.text:SetText(string_format("|cffffcc00%s|r", valStr))
                    else
                        b.text:SetText(string_format("|cffffffff%s|r", valStr))
                    end
                    b.text:Show()
                else
                    b.text:Hide()
                    b.text:SetText("")
                end

                local w = 16 + (b.text:IsShown() and (4 + b.text:GetStringWidth()) or 0)
                b.frame:SetSize(w, 18)
                b.frame.title = nil
                b.frame.customTooltip = c.tooltip
                b.frame.spellID = nil
            end
        end

        -- 4. Active Delve Spells / Affixes (matching default UI with stack / count display)
        if delveInfo.spells then
            for _, s in ipairs(delveInfo.spells) do
                badgeIdx = badgeIdx + 1
                local b = GetOrCreateDelveBadge(badgeIdx)
                local tex = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(s.spellID)) or
                (_G.GetSpellTexture and _G.GetSpellTexture(s.spellID)) or 134400
                b.icon:SetTexture(tex)
                b.icon:SetSize(16, 16)
                b.stackText:Hide()

                local displayNum = nil
                if s.stack and tostring(s.stack) ~= "" and tostring(s.stack) ~= "0" then
                    displayNum = tostring(s.stack)
                elseif s.text and s.text ~= "" then
                    displayNum = s.text:match("(%d+/%d+)") or s.text:match("(%d+)") or s.text
                end

                if not displayNum and s.spellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                    local aura = C_UnitAuras.GetPlayerAuraBySpellID(s.spellID)
                    if aura and aura.applications and aura.applications > 0 then
                        displayNum = tostring(aura.applications)
                    elseif aura and aura.points and aura.points[1] and aura.points[1] > 0 then
                        displayNum = tostring(aura.points[1])
                    end
                end

                if not displayNum and s.tooltip then
                    local match = s.tooltip:match("(%d+/%d+)") or s.tooltip:match("(%d+ of %d+)") or
                    s.tooltip:match("(%d+ remaining)") or s.tooltip:match("(%d+) groups?") or
                    s.tooltip:match("(%d+) packs?")
                    if match then displayNum = match end
                end

                local isNemSpell = (s.tooltip and (s.tooltip:lower():find("nemesis") or s.tooltip:lower():find("zekvir") or s.tooltip:lower():find("influence")))
                if (not displayNum or displayNum == "") and isNemSpell and nemesis.text then
                    displayNum = nemesis.text
                end

                if displayNum and displayNum ~= "" then
                    if isNemSpell then
                        b.text:SetText(string_format("|cffa335ee%s|r", displayNum))
                    elseif displayNum:find("/") then
                        b.text:SetText(string_format("|cffffcc00%s|r", displayNum))
                    else
                        b.text:SetText(string_format("|cffffffff%s|r", displayNum))
                    end
                    b.text:Show()
                    local w = 16 + 4 + b.text:GetStringWidth()
                    b.frame:SetSize(w, 18)
                else
                    b.text:Hide()
                    b.text:SetText("")
                    b.frame:SetSize(16, 18)
                end

                b.frame.title = nil
                b.frame.customTooltip = s.tooltip
                b.frame.spellID = s.spellID
            end
        end

        HideExtraDelveBadges(badgeIdx)

        -- 5. Flow Layout for Left-side Badges
        local xOff = 0
        local yOff = 0
        local gap = 6
        local rowH = 18
        local totalW = HUD_W - (HUD_PAD * 2)
        local rightPinnedW = (livesW > 0 and livesW + 6 or 0) + (nemesisW > 0 and nemesisW + 8 or 0)
        local firstRowMaxW = (rightPinnedW > 0) and (totalW - rightPinnedW) or totalW

        for i = 1, badgeIdx do
            local b = MF.delveBadges[i]
            local bW = b.frame:GetWidth()
            local allowedW = (yOff == 0) and firstRowMaxW or totalW

            if xOff + bW > allowedW and xOff > 0 then
                xOff = 0
                yOff = yOff + rowH + 2
            end
            b.frame:ClearAllPoints()
            b.frame:SetPoint("TOPLEFT", MF.delveRow, "TOPLEFT", xOff, -yOff)
            xOff = xOff + bW + gap
        end

        delveRowH = (badgeIdx > 0 or livesW > 0 or nemesisW > 0) and (yOff + rowH) or 0
        MF.delveRow:SetHeight(delveRowH)
        MF.delveRow:SetShown(delveRowH > 0)
    else
        HideExtraDelveBadges(0)
        MF.delveLivesText:SetText("")
        MF.delveLivesFrame:Hide()
        MF.delveNemesisText:SetText("")
        MF.delveNemesisFrame:Hide()
        MF.delveRow:Hide()
        MF.delveRow:SetHeight(0)
    end

    -- Backward scan: find forces criteria (last isWeightedProgress) — break early.
    local forcesIdx  = nil
    local forcesInfo = nil
    for i = numCriteria, 1, -1 do
        local oki, info = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
        if oki and info and info.isWeightedProgress then
            forcesIdx  = i
            forcesInfo = info
            break
        end
    end

    -- Forward scan: populate boss rows (skip forces index).
    local isMythic = (_mode == "mythic")
    local bossCount = 0
    for i = 1, numCriteria do
        if i ~= forcesIdx then
            local oki, info = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
            if oki and info and info.description and info.description ~= "" then
                bossCount        = bossCount + 1
                local r          = GetOrCreateBossRow(bossCount)
                local isComplete = info.completed == true
                local elapsedAt  = info.elapsed

                if isComplete then
                    r.icon:Hide()
                    r.check:Show()
                    r.name:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B)
                else
                    r.check:Hide()
                    r.icon:Show()
                    r.name:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
                end

                -- Split timer (M+ only)
                if isMythic and isComplete then
                    if not _bossSplits[bossCount] then
                        local currentRunElapsed = 0
                        if _timerID then
                            local okEl, _, el = pcall(GetWorldElapsedTime, _timerID)
                            if okEl and el and el > 0 then currentRunElapsed = el end
                        end
                        if currentRunElapsed == 0 then
                            for t = 1, 5 do
                                local okEl, _, el = pcall(GetWorldElapsedTime, t)
                                if okEl and el and el > 0 then
                                    currentRunElapsed = el
                                    break
                                end
                            end
                        end
                        local elapsedSinceKill = elapsedAt or 0
                        local killTime = math_max(0, currentRunElapsed - elapsedSinceKill)
                        if killTime > 0 then
                            _bossSplits[bossCount] = killTime
                        end
                    end
                end

                local splitStr = (isMythic and _bossSplits[bossCount]) and FormatTime(_bossSplits[bossCount]) or ""
                if splitStr ~= "" then
                    r.split:SetTextColor(CLR_DIM_R, CLR_DIM_G, CLR_DIM_B)
                    r.split:SetText(string_format("[%s]", splitStr))
                    r.split:Show()
                    r.name:ClearAllPoints()
                    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
                    r.name:SetPoint("RIGHT", r.row, "RIGHT", -55, 0)
                else
                    r.split:SetText("")
                    r.split:Hide()
                    r.name:ClearAllPoints()
                    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 0)
                    r.name:SetPoint("RIGHT", r.row, "RIGHT", 0, 0)
                end

                local nameStr = info.description or ("Objective " .. bossCount)
                if not isComplete and info.quantity and info.totalQuantity and info.totalQuantity > 1 then
                    nameStr = nameStr .. " " .. string_format("|cff777777(%d/%d)|r", info.quantity, info.totalQuantity)
                end
                r.name:SetText(nameStr)

                local textH = r.name:GetStringHeight() or 14
                local rowH = math_max(16, math_ceil(textH + 2))
                r.row:SetHeight(rowH)
            end
        end
    end

    HideExtraBossRows(bossCount)

    -- Forces bar — info already in hand from the backward scan above.
    if forcesInfo then
        local rawStr   = forcesInfo.quantityString or ""
        local current  = forcesInfo.quantity or 0
        local total    = forcesInfo.totalQuantity or 100
        local pct      = 0

        -- Check if quantityString contains fractional count "186/301"
        local curMatch, totMatch = rawStr:match("(%d+)/(%d+)")
        if curMatch and totMatch then
            current = tonumber(curMatch) or current
            total   = tonumber(totMatch) or total
        end

        local pctMatch = rawStr:match("(%d+%.?%d*)")
        if total > 0 and current > 0 then
            pct = (current / total) * 100
        elseif pctMatch and rawStr:find("%%") then
            pct = tonumber(pctMatch) or 0
        elseif pctMatch then
            pct = tonumber(pctMatch) or 0
        end

        local isCompleted = forcesInfo.completed or (pct >= 100) or (current >= total and total > 0)
        MF.forcesBar:SetMinMaxValues(0, math_max(1, total))
        MF.forcesBar:SetValue(isCompleted and total or (current > 0 and current or pct))

        if isCompleted then
            MF.forcesBar:SetStatusBarColor(0.20, 1.00, 0.40, 0.90)

            local splitStr = ""
            local forcesElapsed = forcesInfo.elapsed
            if forcesElapsed and forcesElapsed > 0 and _timerID then
                local okE, _, curRunElapsed = pcall(GetWorldElapsedTime, _timerID)
                if okE and curRunElapsed and curRunElapsed > forcesElapsed then
                    splitStr = string_format(" |cff888888[%s]|r", FormatTime(curRunElapsed - forcesElapsed))
                end
            end

            MF.forcesText:SetText("100% |cff44ff44(Done)|r" .. splitStr)
            if total > 100 and current > 0 then
                MF.forcesCountText:SetText(string_format("%d/%d", current, total))
            else
                MF.forcesCountText:SetText("")
            end
        else
            MF.forcesBar:SetStatusBarColor(0.40, 0.00, 1.00, 0.85)
            MF.forcesText:SetText(string_format("%.2f%%", pct))
            if total > 100 and current > 0 then
                local needed = math_max(0, total - current)
                MF.forcesCountText:SetText(string_format("%d/%d (-%d)", current, total, needed))
            else
                MF.forcesCountText:SetText("")
            end
        end
    else
        MF.forcesText:SetText("—")
        MF.forcesCountText:SetText("")
    end

    RelayoutHUD(bossCount, delveInfo ~= nil, delveRowH, forcesInfo ~= nil)
end

-- ─── Timer Update (10 Hz ticker — optimized) ──────────────
local function UpdateTimer()
    local elapsed = 0
    if _timerID then
        local ok, _, el = pcall(GetWorldElapsedTime, _timerID)
        if ok and el and el > 0 then elapsed = el end
    end
    if elapsed == 0 then
        for i = 1, 5 do
            local ok, _, el = pcall(GetWorldElapsedTime, i)
            if ok and el and el > 0 then
                _timerID = i
                elapsed = el
                break
            end
        end
    end

    if _timeLimit <= 0 then
        local ok1, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
        if ok1 and mapID and mapID > 0 then
            local ok2, name, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
            if ok2 and timeLimit and timeLimit > 0 then
                _timeLimit = timeLimit
                MF.dungeonText:SetText(name or "Mythic+")
                MF.timerBar:SetMinMaxValues(0, _timeLimit)
                PlaceChestTicks()
            end
        end
    end

    if _timeLimit <= 0 then return end

    local time3 = _timeLimit * 0.60
    local time2 = _timeLimit * 0.80

    -- Bar fills from 0 to _timeLimit
    MF.timerBar:SetValue(math_min(_timeLimit, elapsed))

    -- Calculate chest countdown & phase
    local chestTier, chestRem, phase
    if elapsed < time3 then
        chestTier = 3
        chestRem = time3 - elapsed
        phase = 0 -- +3 on time (Green)
    elseif elapsed < time2 then
        chestTier = 2
        chestRem = time2 - elapsed
        phase = 1 -- +2 on time (Yellow)
    elseif elapsed < _timeLimit then
        chestTier = 1
        chestRem = _timeLimit - elapsed
        phase = 2 -- +1 on time (Cyan)
    else
        chestTier = 0
        chestRem = elapsed - _timeLimit
        phase = 3 -- Overtime (Red)
    end

    if MF.tick3 then MF.tick3:SetShown(chestTier >= 3) end
    if MF.tick2 then MF.tick2:SetShown(chestTier >= 2) end

    if phase ~= _lastTimerPhase then
        _lastTimerPhase = phase
        if phase == 0 then
            MF.timerBar:SetStatusBarColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B, 0.85)
            MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B) end
        elseif phase == 1 then
            MF.timerBar:SetStatusBarColor(CLR_YELLOW_R, CLR_YELLOW_G, CLR_YELLOW_B, 0.85)
            MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_YELLOW_R, CLR_YELLOW_G, CLR_YELLOW_B) end
        elseif phase == 2 then
            MF.timerBar:SetStatusBarColor(CLR_ONTIME_R, CLR_ONTIME_G, CLR_ONTIME_B, 0.85)
            MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_ONTIME_R, CLR_ONTIME_G, CLR_ONTIME_B) end
        else -- overtime
            MF.timerBar:SetStatusBarColor(CLR_OVTM_R, CLR_OVTM_G, CLR_OVTM_B, 0.90)
            MF.timerText:SetTextColor(CLR_RED_R, CLR_RED_G, CLR_RED_B)
            if MF.chestText then MF.chestText:SetTextColor(CLR_RED_R, CLR_RED_G, CLR_RED_B) end
        end
    end

    -- Timer text: Elapsed / Total
    local newTimerStr = string_format("%s / %s", FormatTime(elapsed), FormatTime(_timeLimit))
    if newTimerStr ~= _lastTimerText then
        _lastTimerText = newTimerStr
        MF.timerText:SetText(newTimerStr)
    end

    -- Chest countdown text
    if MF.chestText then
        local newChestStr
        if chestTier == 3 then
            newChestStr = string_format("+3 %s", FormatTime(chestRem))
        elseif chestTier == 2 then
            newChestStr = string_format("+2 %s", FormatTime(chestRem))
        elseif chestTier == 1 then
            newChestStr = string_format("+1 %s", FormatTime(chestRem))
        else
            newChestStr = string_format("+%s", FormatTime(chestRem))
        end
        if newChestStr ~= _lastChestText then
            _lastChestText = newChestStr
            MF.chestText:SetText(newChestStr)
        end
    end

    -- Death counter (only format and resize when count or time lost changes)
    local okd, deaths, timeLost = pcall(C_ChallengeMode.GetDeathCount)
    if okd and deaths and deaths > 0 then
        local tl = timeLost or (deaths * 5)
        if deaths ~= _lastDeaths or tl ~= _lastTimeLost then
            _lastDeaths = deaths
            _lastTimeLost = tl
            local lostMin = math_floor(tl / 60)
            local lostSec = tl % 60
            local lostStr = (lostMin > 0 and (lostSec > 0 and string_format("+%dm %ds", lostMin, lostSec) or string_format("+%dm", lostMin))) or
            string_format("+%ds", lostSec)
            local newDeathStr = string_format("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12:0:0|t |cffff4444%d (%s)|r", deaths, lostStr)
            _lastDeathText = newDeathStr
            MF.deathText:SetText(newDeathStr)
            if MF.deathFrame then
                MF.deathFrame:SetWidth(MF.deathText:GetStringWidth() + 16)
                MF.deathFrame:Show()
            end
        end
    else
        if _lastDeaths ~= 0 then
            _lastDeaths = 0
            _lastTimeLost = 0
            _lastDeathText = ""
            MF.deathText:SetText("")
            if MF.deathFrame then MF.deathFrame:Hide() end
        end
    end
end

-- ─── ReinitTimer ──────────────────────────────────────────
local function ReinitTimer()
    _timerID = nil
    for i = 1, 10 do
        local okT, _, _, timerType = pcall(GetWorldElapsedTime, i)
        if okT and timerType == (_G.Enum and _G.Enum.WorldElapsedTimerTypes
                and _G.Enum.WorldElapsedTimerTypes.ChallengeMode) then
            _timerID = i
            break
        end
    end
    if not _timerID then _timerID = 1 end
    UpdateTimer()
end

-- ─── Initialize M+ Run ───────────────────────────────────
local function InitRun()
    if not MF then BuildHUDFrame() end
    wipe(_bossSplits)
    _lastBossCount  = 0
    _lastTimerPhase = -1
    _lastTimerText  = ""
    _lastChestText  = ""
    _lastDeathText  = ""
    _lastDeaths     = -1
    _lastTimeLost   = -1
    CacheGroupMembers()

    local ok1, mapID          = pcall(C_ChallengeMode.GetActiveChallengeMapID)
    local ok2, level, affixes = pcall(C_ChallengeMode.GetActiveKeystoneInfo)

    if ok1 and mapID and mapID > 0 then
        local ok3, name, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
        MF.dungeonText:SetText((ok3 and name) or "Mythic+")
        _timeLimit = (ok3 and timeLimit) or 0
    else
        MF.dungeonText:SetText("Mythic+")
        _timeLimit = 0
    end

    local EMPTY_TABLE = {}
    MF.levelText:SetTextColor(1, 0.82, 0, 1)
    if ok2 and level and level > 0 then
        MF.levelText:SetText(string_format("+%d", level))
        BuildAffixRow(affixes or EMPTY_TABLE)
    else
        MF.levelText:SetText("+?")
        BuildAffixRow(EMPTY_TABLE)
    end

    -- Detect active timer ID
    _timerID = nil
    for i = 1, 10 do
        local okT, _, _, timerType = pcall(GetWorldElapsedTime, i)
        if okT and timerType == (_G.Enum and _G.Enum.WorldElapsedTimerTypes
                and _G.Enum.WorldElapsedTimerTypes.ChallengeMode) then
            _timerID = i
            break
        end
    end
    if not _timerID then _timerID = 1 end

    MF.timerBar:SetMinMaxValues(0, math_max(1, _timeLimit))
    MF.timerBar:SetValue(0)

    UpdateInstanceState()
    UpdateTimer()
    C_Timer.After(0.05, PlaceChestTicks)
end

-- ─── Initialize Dungeon/Delve/Scenario ────────────────────
local function InitDungeon()
    if not MF then BuildHUDFrame() end
    wipe(_bossSplits)
    _lastBossCount  = 0
    _lastTimerPhase = -1
    _lastTimerText  = ""
    _lastDeathText  = ""
    _lastDeaths     = -1
    _lastTimeLost   = -1


    -- Instance info
    local instName, _, _, diffName
    if _G.GetInstanceInfo then
        instName, _, _, diffName = _G.GetInstanceInfo()
    end

    -- Scenario info (overrides raw instance name if available)
    local scenName, scenType
    if C_Scenario and C_Scenario.GetInfo then
        local ok, n, _, _, _, _, _, _, _, _, t = pcall(C_Scenario.GetInfo)
        if ok then scenName, scenType = n, t end
    end

    local displayName = scenName or instName or "Dungeon"

    -- Determine difficulty label using hoisted DIFF_ABBR table (no per-call allocation)
    -- instName:lower():find("delve") removed — rely on scenType == 8 instead
    local typeLabel
    if scenType == 1 then
        typeLabel = "|cffff7700M+|r" -- safety net; should be caught by CHALLENGE_MODE_START
    elseif scenType == 8 then
        typeLabel = "|cffa864ffDelve|r"
    elseif diffName and diffName ~= "" then
        typeLabel = DIFF_ABBR[diffName] or diffName
    else
        typeLabel = ""
    end

    MF.dungeonText:SetText(displayName)
    MF.levelText:SetText(typeLabel)
    MF.levelText:SetTextColor(1, 0.82, 0, 1)

    _timerID   = nil
    _timeLimit = 0

    UpdateInstanceState()
end

-- ─── Ticker ───────────────────────────────────────────────
local function _OnMythicTicker()
    if _mode == nil or not MF or not MF:IsShown() then
        if _ticker then _ticker:Cancel() end
        _ticker = nil
        return
    end
    if _mode == "mythic" then UpdateTimer() end
end

local function StartTicker()
    if _ticker then return end
    _ticker = C_Timer.NewTicker(TICKER_RATE, _OnMythicTicker)
end

local function StopTicker()
    if _ticker then
        _ticker:Cancel()
        _ticker = nil
    end
end

-- ─── Show / Hide ──────────────────────────────────────────
local function ShowHUD(forceDungeon)
    if not sfui.mythic.IsEnabled() then return end
    if not MF then BuildHUDFrame() end

    -- Restore saved position (matches objective tracker position)
    local posX = (SfuiDB and (SfuiDB.mythicHudX or SfuiDB.questlogX)) or mcfg.posX or -10
    local posY = (SfuiDB and (SfuiDB.mythicHudY or SfuiDB.questlogY)) or mcfg.posY or -10
    MF:ClearAllPoints()
    MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)

    if sfui.SuppressBlizzardTracker then
        sfui.SuppressBlizzardTracker()
    end

    -- Apply lock state
    local isLocked = not (SfuiDB and SfuiDB.mythicHudUnlocked)
    MF.dragBar:SetShown(not isLocked)
    MF:EnableMouse(not isLocked)

    local isMPlus = false
    local okM, isActive = pcall(C_ChallengeMode.IsChallengeModeActive)
    if okM and isActive then isMPlus = true end

    if isMPlus and not forceDungeon then
        _mode = "mythic"
        InitRun()
        StartTicker()
    else
        _mode = "dungeon"
        InitDungeon()
    end
    MF:Show()
end

local function HideHUD()
    StopTicker()
    _mode = nil
    if MF then MF:Hide() end
end

-- ─── Public Helpers for Options Tab ───────────────────────
function sfui.mythic.SetEnabled(val)
    SfuiDB = SfuiDB or {}
    SfuiDB.mythicHudEnabled = val
    if not val then
        HideHUD() -- HideHUD already sets _mode = nil
    end
end

function sfui.mythic.SetLocked(locked)
    SfuiDB = SfuiDB or {}
    SfuiDB.mythicHudUnlocked = not locked
    if MF then
        MF.dragBar:SetShown(not locked)
        MF:EnableMouse(not locked)
    end
end

function sfui.mythic.ResetPosition()
    if SfuiDB then
        SfuiDB.mythicHudX = nil
        SfuiDB.mythicHudY = nil
        SfuiDB.questlogX  = nil
        SfuiDB.questlogY  = nil
    end
    if MF then
        MF:ClearAllPoints()
        MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", mcfg.posX or -10, mcfg.posY or -10)
    end
end

local function _OnInitRunDeferred()
    if _mode == "mythic" and MF and MF:IsShown() then
        InitRun()
    end
end

local function CheckScenarioState()
    if _isPreview then return end
    local isMPlus = false
    local okM, isActive = pcall(C_ChallengeMode.IsChallengeModeActive)
    if okM and isActive then isMPlus = true end

    if isMPlus then
        if _mode ~= "mythic" then
            _mode = "mythic"
            if C_MythicPlus and C_MythicPlus.RequestMapInfo then
                C_MythicPlus.RequestMapInfo()
            end
            if sfui.questlog and sfui.questlog.on_mythic_start then
                sfui.questlog.on_mythic_start()
            end
            ShowHUD()
            C_Timer.After(0.4, _OnInitRunDeferred)
        else
            UpdateInstanceState()
        end
        return
    end

    local inScenario = false
    if C_Scenario and C_Scenario.IsInScenario then
        local ok, inScen = pcall(C_Scenario.IsInScenario)
        if ok and inScen then inScenario = true end
    end
    if not inScenario and C_DelvesUI and C_DelvesUI.HasActiveDelve then
        local ok, hasDelve = pcall(C_DelvesUI.HasActiveDelve)
        if ok and hasDelve then inScenario = true end
    end
    if not inScenario and _G.IsInInstance then
        local ok, _, instType = pcall(_G.IsInInstance)
        if ok and instType == "scenario" then inScenario = true end
    end

    if inScenario then
        if _mode ~= "dungeon" then
            _mode = "dungeon"
            if sfui.questlog and sfui.questlog.on_mythic_start then
                sfui.questlog.on_mythic_start()
            end
            ShowHUD(true)
        else
            UpdateInstanceState()
        end
    else
        if _mode ~= nil then
            _mode = nil
            HideHUD()
            if sfui.questlog and sfui.questlog.on_mythic_end then
                sfui.questlog.on_mythic_end()
            end
        end
    end
end

function sfui.mythic.ShowPreview()
    if not MF then BuildHUDFrame() end

    _isPreview = true

    -- Restore saved position (matches objective tracker position)
    local posX = (SfuiDB and (SfuiDB.mythicHudX or SfuiDB.questlogX)) or mcfg.posX or -10
    local posY = (SfuiDB and (SfuiDB.mythicHudY or SfuiDB.questlogY)) or mcfg.posY or -10
    MF:ClearAllPoints()
    MF:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", posX, posY)

    -- Set mode to mythic for preview rendering
    _mode = "mythic"

    MF.dungeonText:SetText("Darkflame Cleft")
    MF.levelText:SetText("+12")
    MF.levelText:SetTextColor(1, 0.82, 0, 1)

    BuildAffixRow({ 9, 10, 135 })

    _timeLimit      = 1980
    _lastTimerPhase = -1
    _lastTimerText  = ""
    _lastChestText  = ""
    MF.timerBar:SetMinMaxValues(0, _timeLimit)
    MF.timerBar:SetValue(1100)
    MF.timerBar:SetStatusBarColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B, 0.85)
    MF.timerText:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
    MF.timerText:SetText("18:20 / 33:00")
    if MF.chestText then
        MF.chestText:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B)
        MF.chestText:SetText("+3 01:28")
        MF.chestText:Show()
    end
    if MF.deathFrame then
        MF.deathText:SetText("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12:0:0|t |cffff44441 (+5s)|r")
        MF.deathFrame:SetWidth(MF.deathText:GetStringWidth() + 16)
        MF.deathFrame:Show()
    end

    PlaceChestTicks()

    -- Fake bosses
    local fakes = {
        { name = "Ol' Waxbeard",    done = true,  split = "[04:12]" },
        { name = "Blazikon",        done = true,  split = "[08:55]" },
        { name = "The Candle King", done = false, split = "" },
        { name = "The Darkness",    done = false, split = "" },
    }
    for i, f in ipairs(fakes) do
        local r = GetOrCreateBossRow(i)
        r.row:Show()
        if f.done then
            r.icon:Hide(); r.check:Show()
            r.name:SetTextColor(CLR_GREEN_R, CLR_GREEN_G, CLR_GREEN_B)
            r.split:SetTextColor(CLR_DIM_R, CLR_DIM_G, CLR_DIM_B)
            r.split:SetText(f.split)
        else
            r.check:Hide(); r.icon:Hide()
            r.name:SetTextColor(CLR_WHITE_R, CLR_WHITE_G, CLR_WHITE_B)
            r.split:SetText("")
        end
        r.name:SetText(f.name)
    end
    HideExtraBossRows(#fakes)
    RelayoutHUD(#fakes)

    MF.forcesBar:SetMinMaxValues(0, 301)
    MF.forcesBar:SetValue(186)
    MF.forcesBar:SetStatusBarColor(0.40, 0.00, 1.00, 0.85)
    MF.forcesText:SetText("Forces: 61.79%")
    MF.forcesCountText:SetText("186/301 (-115)")

    local isLocked = not (SfuiDB and SfuiDB.mythicHudUnlocked)
    MF.dragBar:SetShown(not isLocked)
    MF:EnableMouse(not isLocked)
    MF:Show()
    MF:SetAlpha(1)
end

function sfui.mythic.HidePreview()
    _isPreview = false
    _mode = nil
    HideHUD()
    CheckScenarioState()
end

-- ─── Event-Driven State Update (Coalesced & Throttled) ────
local _stateUpdatePending = false
-- Named callback to avoid closure allocation on every C_Timer.After call.
-- UPDATE_UI_WIDGET fires very frequently (even in cities), so each expiry
-- would otherwise create a new closure.
local function _OnStateUpdateTimer()
    _stateUpdatePending = false
    CheckScenarioState()
end
local function RequestStateUpdate(delay)
    if _stateUpdatePending then return end
    _stateUpdatePending = true
    C_Timer.After(delay or 0.4, _OnStateUpdateTimer)
end

-- ─── Event Frame ──────────────────────────────────────────
local ev = CreateFrame("Frame")

ev:SetScript("OnEvent", function(self, event, ...)
    if event == "CHALLENGE_MODE_START" then
        _mode = "mythic"
        wipe(_playerDeaths)
        CacheGroupMembers()
        if sfui.questlog and sfui.questlog.on_mythic_start then
            sfui.questlog.on_mythic_start()
        end
        ShowHUD()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        StopTicker()
        if _mode == "mythic" then
            local okM, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
            if okM and mapID and mapID > 0 then
                local _, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
                local _, el = GetWorldElapsedTime(_timerID or 1)
                local onTime = el and timeLimit and (el <= timeLimit)
                local upgrades = 0
                if onTime then
                    if el <= timeLimit * 0.60 then upgrades = 3
                    elseif el <= timeLimit * 0.80 then upgrades = 2
                    else upgrades = 1 end
                end
                if MF and MF.timerBar then
                    local r, g2, b = unpack(onTime and COLORS.cyan or { 1, 0.2, 0.2, 1 })
                    MF.timerBar:SetStatusBarColor(r, g2, b, 0.9)
                    MF.chestText:SetText(onTime and string_format("+%d In Time", upgrades) or "Depleted")
                    MF.chestText:SetTextColor(r, g2, b)
                end
                _lastTimerPhase = -1 -- invalidate so next UpdateTimer resets color
            end
        end
    elseif event == "CHALLENGE_MODE_RESET" then
        _mode = nil
        HideHUD()
        if sfui.questlog and sfui.questlog.on_mythic_end then
            sfui.questlog.on_mythic_end()
        end
    elseif event == "SCENARIO_CRITERIA_UPDATE" or event == "SCENARIO_UPDATE" or
        event == "ACTIVE_DELVE_DATA_UPDATE" or event == "UPDATE_UI_WIDGET" or
        event == "SCENARIO_COMPLETED" then
        if event == "UPDATE_UI_WIDGET" and _mode == nil then return end
        RequestStateUpdate(0.4)
    elseif event == "CHALLENGE_MODE_DEATH_COUNT_UPDATED" then
        if _mode == "mythic" then UpdateTimer() end
    elseif event == "UNIT_DIED" and _mode == "mythic" then
        local destGUID = select(1, ...)
        if destGUID then
            if issecretvalue and issecretvalue(destGUID) then return end
            for _, p in ipairs(_playerList) do
                if p.guid == destGUID then
                    if not (UnitIsFeignDeath and UnitIsFeignDeath(p.unit)) then
                        _playerDeaths[p.name] = (_playerDeaths[p.name] or 0) + 1
                    end
                    break
                end
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        CacheGroupMembers()
    elseif event == "CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN" then
        if C_Container and C_Container.GetContainerNumSlots and C_Item and C_Item.IsItemKeystoneByID then
            for bagID = 0, (_G.NUM_BAG_SLOTS or 4) do
                local numSlots = C_Container.GetContainerNumSlots(bagID) or 0
                for invID = 1, numSlots do
                    local itemID = C_Container.GetContainerItemID(bagID, invID)
                    if itemID and C_Item.IsItemKeystoneByID(itemID) then
                        C_Container.UseContainerItem(bagID, invID)
                        break
                    end
                end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        CacheGroupMembers()
        CheckScenarioState()
        RequestStateUpdate(0.6)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        RequestStateUpdate(0.4)
    elseif event == "WORLD_STATE_TIMER_START" or event == "WORLD_STATE_TIMER_STOP" then
        if _mode == "mythic" then ReinitTimer() end
    end
end)

local function Reg(e) pcall(ev.RegisterEvent, ev, e) end
Reg("CHALLENGE_MODE_START")
Reg("CHALLENGE_MODE_COMPLETED")
Reg("CHALLENGE_MODE_RESET")
Reg("CHALLENGE_MODE_DEATH_COUNT_UPDATED")
Reg("CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN")
Reg("UNIT_DIED")
Reg("GROUP_ROSTER_UPDATE")
Reg("SCENARIO_UPDATE")
Reg("SCENARIO_CRITERIA_UPDATE")
Reg("SCENARIO_COMPLETED")
Reg("ACTIVE_DELVE_DATA_UPDATE")
Reg("UPDATE_UI_WIDGET")
Reg("PLAYER_ENTERING_WORLD")
Reg("ZONE_CHANGED_NEW_AREA")
Reg("WORLD_STATE_TIMER_START")
Reg("WORLD_STATE_TIMER_STOP")

function sfui.mythic_debug_info()
    local deathCount = 0
    for _ in pairs(_playerDeaths) do deathCount = deathCount + 1 end

    return {
        spellPool    = #spellPool,
        currencyPool = #currencyPool,
        deathPool    = #deathBreakdownPool,
        playerList   = #_playerList,
        playerDeaths = deathCount,
        badgePool    = (MF and MF.delveBadges and #MF.delveBadges) or 0,
        bossRowPool  = (MF and MF.bossRows and #MF.bossRows) or 0,
    }
end

