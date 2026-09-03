local addonName, addon = ...
sfui = sfui or {}
sfui.questlog = sfui.questlog or {}
sfui.questlog.scenarios = sfui.questlog.scenarios or {}

-- Localize Globals & Core C-APIs
local _G = _G
local C_Scenario               = _G.C_Scenario
local C_ScenarioInfo           = _G.C_ScenarioInfo
local C_UIWidgetManager        = _G.C_UIWidgetManager
local C_DelvesUI               = _G.C_DelvesUI
local C_ChallengeMode          = _G.C_ChallengeMode
local Enum                     = _G.Enum
local bit                      = _G.bit
local ipairs, type, tonumber   = _G.ipairs, _G.type, _G.tonumber
local math_min, math_max, math_floor = _G.math.min, _G.math.max, _G.math.floor
local tostring, string_format  = _G.tostring, string.format
local wipe                     = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local issecretvalue            = _G.issecretvalue or function() return false end
local table_insert             = _G.table.insert

-- Reuse table: avoids per-call allocation on the legacy C_Scenario multi-return path.
-- Safe because callers consume the table immediately and never store the reference.
local _criteriaReuseTable = {}

local function GetScenarioCriteriaSafe(criteriaIndex, stepID)
    -- 1. Query active scenario step criteria first (always current for active stage)
    if C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo then
        local info = C_ScenarioInfo.GetCriteriaInfo(criteriaIndex)
        if info and type(info) == "table" and (info.description or info.criteriaString or info.string) then
            info.description = info.description or info.criteriaString or info.string
            return info
        end
    end
    if C_Scenario and C_Scenario.GetCriteriaInfo then
        local desc, cType, comp, quant, totQuant, flags, assetID, quantStr, critID, dur, el, isWeight = C_Scenario.GetCriteriaInfo(criteriaIndex)
        if desc and desc ~= "" then
            local t = _criteriaReuseTable
            t.description       = desc
            t.criteriaType      = cType
            t.completed         = comp
            t.quantity          = quant
            t.totalQuantity     = totQuant
            t.flags             = flags
            t.assetID           = assetID
            t.quantityString    = quantStr
            t.criteriaID        = critID
            t.duration          = dur
            t.elapsed           = el
            t.isWeightedProgress = isWeight
            return t
        end
    end

    -- 2. Fallback to step-specific criteria if stepID / stepIndex provided (used for bonus steps)
    if stepID and C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfoByStep then
        local info = C_ScenarioInfo.GetCriteriaInfoByStep(stepID, criteriaIndex)
        if info and type(info) == "table" and (info.description or info.criteriaString or info.string) then
            info.description = info.description or info.criteriaString or info.string
            return info
        end
    end
    if stepID and C_Scenario and C_Scenario.GetCriteriaInfoByStep then
        local desc, cType, comp, quant, totQuant, flags, assetID, quantStr, critID, dur, el, isWeight = C_Scenario.GetCriteriaInfoByStep(stepID, criteriaIndex)
        if desc and desc ~= "" then
            local t = _criteriaReuseTable
            t.description       = desc
            t.criteriaType      = cType
            t.completed         = comp
            t.quantity          = quant
            t.totalQuantity     = totQuant
            t.flags             = flags
            t.assetID           = assetID
            t.quantityString    = quantStr
            t.criteriaID        = critID
            t.duration          = dur
            t.elapsed           = el
            t.isWeightedProgress = isWeight
            return t
        end
    end
    return nil
end

local function FormatTimerSeconds(sec)
    if not sec or sec <= 0 then return nil end
    sec = math_floor(sec)
    if sec >= 3600 then
        local h = math_floor(sec / 3600)
        local m = math_floor((sec % 3600) / 60)
        local s = sec % 60
        return string_format("%d:%02d:%02d", h, m, s)
    else
        local m = math_floor(sec / 60)
        local s = sec % 60
        return string_format("%d:%02d", m, s)
    end
end

local staticScannedWidgets = {}
local staticWidgetIDList   = {}

local function AddWidgetIDToScan(wID)
    if wID and type(wID) == "number" and wID > 0 and not staticScannedWidgets[wID] then
        staticScannedWidgets[wID] = true
        staticWidgetIDList[#staticWidgetIDList + 1] = wID
    end
end

local function CollectWidgetsFromSet(setID)
    if not setID or setID <= 0 or not C_UIWidgetManager or not C_UIWidgetManager.GetAllWidgetsBySetID then return end
    local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setID)
    if widgets and type(widgets) == "table" then
        for _, w in ipairs(widgets) do
            local wID = (type(w) == "table" and w.widgetID) or (type(w) == "number" and w)
            if wID then AddWidgetIDToScan(wID) end
        end
    end
end

local function ScanWorldEventScenario(list, AcquireTable, ReleaseTable)
    -- mythic.lua owns dungeons, delves, mythic+, and instance scenarios.
    -- quests.lua strictly only tracks outdoor world events (e.g. Dundun, Community Feast, Time Rifts, etc.)
    if sfui.mythic and sfui.mythic.IsActive and sfui.mythic.IsActive() then return end

    local inInst, instType = false, "none"
    if _G.IsInInstance then
        local resInst, resType = _G.IsInInstance()
        if resInst ~= nil then inInst, instType = resInst, resType end
    end
    if inInst and instType ~= "none" then return end

    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then return end
    if C_DelvesUI and C_DelvesUI.HasActiveDelve and C_DelvesUI.HasActiveDelve() then return end

    local C_Sc = _G.C_Scenario
    if not C_Sc or not C_Sc.IsInScenario or not C_Sc.IsInScenario() then return end

    local name, currentStage, numStages, flags, isComplete, _, _, scenarioType = C_Sc.GetInfo()
    if not name or name == "" or isComplete then return end

    -- Filter out Delves (8), Dungeons (1), Raids (2), Challenge Mode (5), or instance-flagged scenarios
    if scenarioType == 8 or scenarioType == 1 or scenarioType == 2 or scenarioType == 5 then return end
    if flags and bit and bit.band and bit.band(flags, 0x01) ~= 0 and inInst then return end

    local stepInfo = nil
    if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
        local sInfo = C_ScenarioInfo.GetScenarioStepInfo()
        if sInfo and type(sInfo) == "table" then
            stepInfo = sInfo
        end
    end

    local stageName = (stepInfo and (stepInfo.name or stepInfo.title or stepInfo.stageName))
    local stageDescription = (stepInfo and stepInfo.description)
    local numCriteria = (stepInfo and stepInfo.numCriteria)
    local weightedProgress = (stepInfo and stepInfo.weightedProgress)
    local widgetSetID = (stepInfo and stepInfo.widgetSetID)

    if not stepInfo and C_Sc.GetStepInfo then
        local sName, sDesc, nCrit, _, _, _, _, _, _, wProg, _, wSetID = C_Sc.GetStepInfo()
        stageName = stageName or sName
        stageDescription = stageDescription or sDesc
        numCriteria = numCriteria or nCrit
        if weightedProgress == nil then weightedProgress = wProg end
        widgetSetID = widgetSetID or wSetID
    end

    local title
    if numStages and numStages > 1 and currentStage and currentStage > 0 then
        title = string_format("%s (Stage %d/%d)", stageName or name, currentStage, numStages)
    else
        title = stageName or name
    end

    local objs = AcquireTable()
    local done, total = 0, 0
    local scTimeLeft = nil

    -- 1. Criteria scan
    if numCriteria and numCriteria > 0 then
        for i = 1, numCriteria do
            local info = GetScenarioCriteriaSafe(i, stepInfo and stepInfo.stepID)
            local desc = info and (info.description or info.criteriaString or info.string)
            if desc and desc ~= "" and not issecretvalue(desc) then
                local sObj = AcquireTable()
                local isComp = info.completed == true
                sObj.finished = isComp
                if isComp then done = done + 1 end
                total = total + 1

                local timeTag = nil
                if info.duration and info.duration > 0 then
                    local rem = math_max(0, info.duration - (info.elapsed or 0))
                    if rem > 0 then
                        local tStr = FormatTimerSeconds(rem)
                        if tStr then
                            timeTag = "[" .. tStr .. "]"
                            if not scTimeLeft then scTimeLeft = tStr end
                        end
                    end
                end

                -- Fallback quantity extraction if Blizzard didn't populate raw numeric fields
                if (not info.quantity or info.quantity == 0) and info.quantityString and not issecretvalue(info.quantityString) then
                    local q, t = info.quantityString:match("(%d+)%s*/%s*(%d+)")
                    if q and t then
                        info.quantity = tonumber(q)
                        info.totalQuantity = tonumber(t)
                    else
                        local p = info.quantityString:match("(%d+)%%")
                        if p then
                            info.quantity = tonumber(p)
                            info.totalQuantity = 100
                            info.isWeightedProgress = true
                        end
                    end
                end
                if (not info.quantity or info.quantity == 0) and desc and not issecretvalue(desc) then
                    local q, t = desc:match("%((%d+)%s*/%s*(%d+)%)")
                    if q and t then
                        info.quantity = tonumber(q)
                        info.totalQuantity = tonumber(t)
                    else
                        local p = desc:match("%((%d+)%%%)")
                        if p then
                            info.quantity = tonumber(p)
                            info.totalQuantity = 100
                            info.isWeightedProgress = true
                        end
                    end
                end

                local isWeighted = info.isWeightedProgress
                    or info.weightedProgress
                    or (info.criteriaType == 8)
                    or (weightedProgress == true)
                    or (info.totalQuantity == 100)
                    or (info.totalQuantity == 1000)
                    or (info.quantityString and not issecretvalue(info.quantityString) and info.quantityString:find("%%"))
                    or (desc and not issecretvalue(desc) and desc:find("%%"))

                if isWeighted then
                    local cleanDesc = desc
                    if not issecretvalue(desc) then
                        cleanDesc = desc:gsub("%s*%(?%d+%%%)?", ""):gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                    end
                    sObj.text = timeTag and (cleanDesc .. " " .. timeTag) or cleanDesc
                    sObj.type = "progressbar"

                    local cur = info.quantity or 0
                    local totalQ = (info.totalQuantity and not issecretvalue(info.totalQuantity) and info.totalQuantity > 0) and info.totalQuantity or 100
                    local pct = 0
                    if totalQ == 1000 then
                        pct = math_min(100, math_max(0, math_floor(cur / 10)))
                    elseif totalQ == 10000 then
                        pct = math_min(100, math_max(0, math_floor(cur / 100)))
                    elseif totalQ > 0 then
                        pct = math_min(100, math_max(0, math_floor((cur / totalQ) * 100)))
                    end

                    sObj.numFulfilled = pct
                    sObj.numRequired = 100

                    local barTxt = (info.quantityString and not issecretvalue(info.quantityString) and not info.quantityString:find("%d%d%d%d%%") and not info.quantityString:find("1000%%") and info.quantityString)
                    if not barTxt or barTxt == "" then
                        barTxt = tostring(pct) .. "%"
                    end
                    sObj.barText = barTxt
                    sObj.finished = isComp
                elseif info.quantity and info.totalQuantity and not issecretvalue(info.totalQuantity) and info.totalQuantity > 1 then
                    local cleanDesc = desc
                    if not issecretvalue(desc) then
                        cleanDesc = desc:gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                    end
                    local baseText = cleanDesc
                    if not issecretvalue(info.quantity) then
                        baseText = string_format("%s (%s/%s)", cleanDesc, tostring(info.quantity), tostring(info.totalQuantity))
                    end
                    sObj.text = timeTag and (baseText .. " " .. timeTag) or baseText
                    sObj.numFulfilled = info.quantity
                    sObj.numRequired = info.totalQuantity
                    sObj.finished = isComp
                else
                    sObj.text = timeTag and (desc .. " " .. timeTag) or desc
                    sObj.finished = isComp
                end
                table_insert(objs, sObj)
            end
        end
    end

    -- 2. Scenario & World Event Widgets Scan (Timers, Progress / Abundance Bars, Captures)
    wipe(staticScannedWidgets)
    wipe(staticWidgetIDList)

    if widgetSetID and widgetSetID > 0 then
        CollectWidgetsFromSet(widgetSetID)
    end

    if C_UIWidgetManager then
        if C_UIWidgetManager.GetTopCenterWidgetSetID then
            local sID = C_UIWidgetManager.GetTopCenterWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
        if C_UIWidgetManager.GetBelowMinimapWidgetSetID then
            local sID = C_UIWidgetManager.GetBelowMinimapWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
        if C_UIWidgetManager.GetObjectiveTrackerWidgetSetID then
            local sID = C_UIWidgetManager.GetObjectiveTrackerWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
        if C_UIWidgetManager.GetPowerBarWidgetSetID then
            local sID = C_UIWidgetManager.GetPowerBarWidgetSetID()
            if sID and sID > 0 then CollectWidgetsFromSet(sID) end
        end
    end

    for _, wID in ipairs(staticWidgetIDList) do
        -- A. ScenarioHeaderTimer
        if C_UIWidgetManager and C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo then
            local tInfo = C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo(wID)
            if tInfo and tInfo.shownState ~= 0 and tInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local tMin = tInfo.timerMin or 0
                local tMax = tInfo.timerMax or 0
                local tVal = tInfo.timerValue or 0
                local rem = 0
                if tMax > tMin and tVal >= tMin then
                    rem = math_max(0, tVal - tMin)
                elseif tVal > 0 then
                    rem = tVal
                end
                local tStr = FormatTimerSeconds(rem)
                if tStr then
                    if not scTimeLeft then scTimeLeft = tStr end
                    local lbl = (tInfo.headerText and tInfo.headerText ~= "" and not issecretvalue(tInfo.headerText) and tInfo.headerText)
                             or (tInfo.timerTooltip and tInfo.timerTooltip ~= "" and not issecretvalue(tInfo.timerTooltip) and tInfo.timerTooltip:match("^[^\n]+"))
                             or "Time Remaining"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s: %s", lbl, tStr)
                    sObj.finished = (rem <= 0)
                    table_insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- B. StatusBar (Abundance, Event Progress, Delve Progress)
        if C_UIWidgetManager and C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
            local sInfo = C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo(wID)
            if sInfo and sInfo.shownState ~= 0 and sInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local minVal = sInfo.barMin or 0
                local maxVal = sInfo.barMax or 0
                local curVal = sInfo.barValue or 0
                local range = maxVal - minVal
                if range > 0 or curVal > 0 then
                    local pct = (range > 0) and math_min(100, math_max(0, math_floor(((curVal - minVal) / range) * 100))) or 0
                    
                    local valText = nil
                    if sInfo.overrideBarText and sInfo.overrideBarText ~= "" and not issecretvalue(sInfo.overrideBarText) then
                        valText = sInfo.overrideBarText
                    elseif sInfo.barValueText and sInfo.barValueText ~= "" and not issecretvalue(sInfo.barValueText) then
                        valText = sInfo.barValueText
                    elseif maxVal > 0 then
                        valText = string_format("%d/%d", curVal, maxVal)
                    else
                        valText = tostring(curVal)
                    end

                    local barLabel = (sInfo.text and sInfo.text ~= "" and not issecretvalue(sInfo.text) and sInfo.text)
                                  or (sInfo.tooltip and sInfo.tooltip ~= "" and not issecretvalue(sInfo.tooltip) and sInfo.tooltip:match("^[^\n]+"))
                                  or (stageName and stageName ~= "" and stageName)
                                  or name
                                  or "Progress"

                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", barLabel, pct)
                    sObj.barText = valText and string_format("%s (%d%%)", valText, pct) or (pct .. "%")
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table_insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- C. DoubleStatusBar
        if C_UIWidgetManager and C_UIWidgetManager.GetDoubleStatusBarWidgetVisualizationInfo then
            local dInfo = C_UIWidgetManager.GetDoubleStatusBarWidgetVisualizationInfo(wID)
            if dInfo and dInfo.shownState ~= 0 and dInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local lMin = dInfo.leftBarMin or 0
                local lMax = dInfo.leftBarMax or 100
                local lCur = dInfo.leftBarValue or 0
                local lRange = lMax - lMin
                if lRange > 0 or lCur > 0 then
                    local pct = (lRange > 0) and math_min(100, math_max(0, math_floor(((lCur - lMin) / lRange) * 100))) or 0
                    local lbl = (dInfo.text and dInfo.text ~= "" and not issecretvalue(dInfo.text) and dInfo.text)
                             or (dInfo.leftBarTooltip and not issecretvalue(dInfo.leftBarTooltip) and dInfo.leftBarTooltip:match("^[^\n]+"))
                             or "Progress"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = (lMax > 0) and string_format("%d/%d (%d%%)", lCur, lMax, pct) or (pct .. "%")
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table_insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- D. FillUpFrames
        if C_UIWidgetManager and C_UIWidgetManager.GetFillUpFramesWidgetVisualizationInfo then
            local fInfo = C_UIWidgetManager.GetFillUpFramesWidgetVisualizationInfo(wID)
            if fInfo and fInfo.shownState ~= 0 and fInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local full = fInfo.numFullFrames or 0
                local totalF = fInfo.numTotalFrames or 0
                local val = fInfo.fillValue or full
                local maxV = fInfo.fillMax or totalF
                if maxV > 0 then
                    local pct = math_min(100, math_max(0, math_floor((val / maxV) * 100)))
                    local lbl = (fInfo.tooltip and not issecretvalue(fInfo.tooltip) and fInfo.tooltip:match("^[^\n]+")) or "Abundance"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = string_format("%d/%d (%d%%)", val, maxV, pct)
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table_insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- E. DiscreteProgressSteps
        if C_UIWidgetManager and C_UIWidgetManager.GetDiscreteProgressStepsVisualizationInfo then
            local dpInfo = C_UIWidgetManager.GetDiscreteProgressStepsVisualizationInfo(wID)
            if dpInfo and dpInfo.shownState ~= 0 and dpInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local pVal = dpInfo.progressVal or 0
                local pMax = dpInfo.progressMax or dpInfo.numSteps or 0
                if pMax > 0 then
                    local pct = math_min(100, math_max(0, math_floor((pVal / pMax) * 100)))
                    local lbl = (dpInfo.tooltip and not issecretvalue(dpInfo.tooltip) and dpInfo.tooltip:match("^[^\n]+")) or "Progress"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = string_format("%d/%d (%d%%)", pVal, pMax, pct)
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table_insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- F. TextWithState
        if C_UIWidgetManager and C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo(wID)
            if wInfo and wInfo.shownState ~= 0 and wInfo.shownState ~= Enum.WidgetShownState.Hidden and wInfo.text and wInfo.text ~= "" and not issecretvalue(wInfo.text) then
                local sObj = AcquireTable()
                sObj.text = wInfo.text
                sObj.finished = false
                table_insert(objs, sObj)
                total = total + 1
            end
        end

        -- G. TextWithSubtext
        if C_UIWidgetManager and C_UIWidgetManager.GetTextWithSubtextWidgetVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetTextWithSubtextWidgetVisualizationInfo(wID)
            if wInfo and wInfo.shownState ~= 0 and wInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local txt = (wInfo.title and wInfo.title ~= "" and not issecretvalue(wInfo.title) and wInfo.title)
                if wInfo.subtext and wInfo.subtext ~= "" and not issecretvalue(wInfo.subtext) then
                    txt = txt and (txt .. ": " .. wInfo.subtext) or wInfo.subtext
                end
                if txt and txt ~= "" then
                    local sObj = AcquireTable()
                    sObj.text = txt
                    sObj.finished = false
                    table_insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- H. TextureAndText
        if C_UIWidgetManager and C_UIWidgetManager.GetTextureAndTextVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetTextureAndTextVisualizationInfo(wID)
            if wInfo and wInfo.shownState ~= 0 and wInfo.shownState ~= Enum.WidgetShownState.Hidden and wInfo.text and wInfo.text ~= "" and not issecretvalue(wInfo.text) then
                local sObj = AcquireTable()
                sObj.text = wInfo.text
                sObj.finished = false
                table_insert(objs, sObj)
                total = total + 1
            end
        end

        -- I. IconAndText
        if C_UIWidgetManager and C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo then
            local wInfo = C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo(wID)
            if wInfo and wInfo.state ~= 0 and wInfo.text and wInfo.text ~= "" and not issecretvalue(wInfo.text) then
                local sObj = AcquireTable()
                sObj.text = wInfo.text
                sObj.finished = false
                table_insert(objs, sObj)
                total = total + 1
            end
        end

        -- J. StackedResourceTracker
        if C_UIWidgetManager and C_UIWidgetManager.GetStackedResourceTrackerWidgetVisualizationInfo then
            local rInfo = C_UIWidgetManager.GetStackedResourceTrackerWidgetVisualizationInfo(wID)
            if rInfo and rInfo.shownState ~= 0 and rInfo.shownState ~= Enum.WidgetShownState.Hidden and rInfo.resources then
                for _, res in ipairs(rInfo.resources) do
                    if res.text and res.text ~= "" and not issecretvalue(res.text) then
                        local sObj = AcquireTable()
                        sObj.text = res.text
                        sObj.finished = false
                        table_insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- K. BulletTextList
        if C_UIWidgetManager and C_UIWidgetManager.GetBulletTextListWidgetVisualizationInfo then
            local bInfo = C_UIWidgetManager.GetBulletTextListWidgetVisualizationInfo(wID)
            if bInfo and bInfo.shownState ~= 0 and bInfo.shownState ~= Enum.WidgetShownState.Hidden and bInfo.lines then
                for _, line in ipairs(bInfo.lines) do
                    if line and line ~= "" and not issecretvalue(line) then
                        local sObj = AcquireTable()
                        sObj.text = line
                        sObj.finished = false
                        table_insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- L. CaptureBar
        if C_UIWidgetManager and C_UIWidgetManager.GetCaptureBarWidgetVisualizationInfo then
            local cbInfo = C_UIWidgetManager.GetCaptureBarWidgetVisualizationInfo(wID)
            if cbInfo and cbInfo.shownState ~= 0 and cbInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local minV = cbInfo.barMinValue or 0
                local maxV = cbInfo.barMaxValue or 100
                local val = cbInfo.barValue or 0
                local range = maxV - minV
                if range > 0 then
                    local pct = math_min(100, math_max(0, math_floor(((val - minV) / range) * 100)))
                    local lbl = (cbInfo.tooltip and not issecretvalue(cbInfo.tooltip) and cbInfo.tooltip:match("^[^\n]+")) or "Control"
                    local sObj = AcquireTable()
                    sObj.text = string_format("%s (%d%%)", lbl, pct)
                    sObj.barText = string_format("%d%%", pct)
                    sObj.type = "progressbar"
                    sObj.numFulfilled = pct
                    sObj.numRequired = 100
                    sObj.finished = (pct >= 100)
                    table_insert(objs, sObj)
                    total = total + 1
                end
            end
        end

        -- M. TextColumnRow & TextureAndTextRow
        if C_UIWidgetManager and C_UIWidgetManager.GetTextColumnRowVisualizationInfo then
            local tcInfo = C_UIWidgetManager.GetTextColumnRowVisualizationInfo(wID)
            if tcInfo and tcInfo.shownState ~= 0 and tcInfo.shownState ~= Enum.WidgetShownState.Hidden and tcInfo.entries then
                for _, ent in ipairs(tcInfo.entries) do
                    if ent.text and ent.text ~= "" and not issecretvalue(ent.text) then
                        local sObj = AcquireTable()
                        sObj.text = ent.text
                        sObj.finished = false
                        table_insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end
        if C_UIWidgetManager and C_UIWidgetManager.GetTextureAndTextRowVisualizationInfo then
            local trInfo = C_UIWidgetManager.GetTextureAndTextRowVisualizationInfo(wID)
            if trInfo and trInfo.shownState ~= 0 and trInfo.shownState ~= Enum.WidgetShownState.Hidden and trInfo.entries then
                for _, ent in ipairs(trInfo.entries) do
                    if ent.text and ent.text ~= "" and not issecretvalue(ent.text) then
                        local sObj = AcquireTable()
                        sObj.text = ent.text
                        sObj.finished = false
                        table_insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- N. HorizontalCurrencies & ScenarioHeaderCurrenciesAndBackground
        if C_UIWidgetManager and C_UIWidgetManager.GetHorizontalCurrenciesWidgetVisualizationInfo then
            local hcInfo = C_UIWidgetManager.GetHorizontalCurrenciesWidgetVisualizationInfo(wID)
            if hcInfo and hcInfo.shownState ~= 0 and hcInfo.shownState ~= Enum.WidgetShownState.Hidden and hcInfo.currencies then
                for _, cur in ipairs(hcInfo.currencies) do
                    local txt = (cur.leadingText and cur.leadingText ~= "" and not issecretvalue(cur.leadingText) and cur.leadingText)
                    if cur.text and cur.text ~= "" and not issecretvalue(cur.text) then
                        txt = txt and (txt .. ": " .. cur.text) or cur.text
                    end
                    if txt and txt ~= "" then
                        local sObj = AcquireTable()
                        sObj.text = txt
                        sObj.finished = (cur.isCurrencyMaxed == true)
                        table_insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end
        if C_UIWidgetManager and C_UIWidgetManager.GetScenarioHeaderCurrenciesAndBackgroundWidgetVisualizationInfo then
            local shcInfo = C_UIWidgetManager.GetScenarioHeaderCurrenciesAndBackgroundWidgetVisualizationInfo(wID)
            if shcInfo and shcInfo.shownState ~= 0 and shcInfo.shownState ~= Enum.WidgetShownState.Hidden and shcInfo.currencies then
                for _, cur in ipairs(shcInfo.currencies) do
                    local txt = (cur.leadingText and cur.leadingText ~= "" and not issecretvalue(cur.leadingText) and cur.leadingText)
                    if cur.text and cur.text ~= "" and not issecretvalue(cur.text) then
                        txt = txt and (txt .. ": " .. cur.text) or cur.text
                    end
                    if txt and txt ~= "" then
                        local sObj = AcquireTable()
                        sObj.text = txt
                        sObj.finished = (cur.isCurrencyMaxed == true)
                        table_insert(objs, sObj)
                        total = total + 1
                    end
                end
            end
        end

        -- O. IconTextAndCurrencies
        if C_UIWidgetManager and C_UIWidgetManager.GetIconTextAndCurrenciesWidgetVisualizationInfo then
            local itcInfo = C_UIWidgetManager.GetIconTextAndCurrenciesWidgetVisualizationInfo(wID)
            if itcInfo and itcInfo.shownState ~= 0 and itcInfo.shownState ~= Enum.WidgetShownState.Hidden then
                local txt = (itcInfo.text and itcInfo.text ~= "" and not issecretvalue(itcInfo.text) and itcInfo.text)
                if itcInfo.description and itcInfo.description ~= "" and not issecretvalue(itcInfo.description) then
                    txt = txt and (txt .. ": " .. itcInfo.description) or itcInfo.description
                end
                if txt and txt ~= "" then
                    local sObj = AcquireTable()
                    sObj.text = txt
                    sObj.finished = false
                    table_insert(objs, sObj)
                    total = total + 1
                end
                if itcInfo.currencies then
                    for _, cur in ipairs(itcInfo.currencies) do
                        local cTxt = (cur.leadingText and cur.leadingText ~= "" and not issecretvalue(cur.leadingText) and cur.leadingText)
                        if cur.text and cur.text ~= "" and not issecretvalue(cur.text) then
                            cTxt = cTxt and (cTxt .. ": " .. cur.text) or cur.text
                        end
                        if cTxt and cTxt ~= "" then
                            local sObj = AcquireTable()
                            sObj.text = cTxt
                            sObj.finished = (cur.isCurrencyMaxed == true)
                            table_insert(objs, sObj)
                            total = total + 1
                        end
                    end
                end
            end
        end

        -- P. ButtonHeader
        if C_UIWidgetManager and C_UIWidgetManager.GetButtonHeaderWidgetVisualizationInfo then
            local bhInfo = C_UIWidgetManager.GetButtonHeaderWidgetVisualizationInfo(wID)
            if bhInfo and bhInfo.shownState ~= 0 and bhInfo.shownState ~= Enum.WidgetShownState.Hidden and bhInfo.headerText and bhInfo.headerText ~= "" and not issecretvalue(bhInfo.headerText) then
                local sObj = AcquireTable()
                sObj.text = bhInfo.headerText
                sObj.finished = false
                table_insert(objs, sObj)
                total = total + 1
            end
        end
    end

    -- 3. Bonus Steps Scan (Bonus Objectives in Scenario / World Event)
    if C_Scenario and C_Scenario.GetBonusSteps then
        local steps = C_Scenario.GetBonusSteps()
        if steps and #steps > 0 then
            for _, bIdx in ipairs(steps) do
                local bName, bDesc, bNumCrit, _, _, _, bShouldShow = C_Scenario.GetStepInfo(bIdx)
                if bShouldShow then
                    local bTitle = (bName and bName ~= "" and bName) or bDesc or "Bonus Objective"
                    local sObjHeader = AcquireTable()
                    sObjHeader.text = string_format("|cff33d9f2%s|r", bTitle)
                    sObjHeader.finished = false
                    table_insert(objs, sObjHeader)
                    total = total + 1

                    if bNumCrit and bNumCrit > 0 then
                        for c = 1, bNumCrit do
                            local cInfo = GetScenarioCriteriaSafe(c, bIdx)
                            local cDesc = cInfo and (cInfo.description or cInfo.criteriaString or cInfo.string)
                            if cDesc and cDesc ~= "" and not issecretvalue(cDesc) then
                                local bObj = AcquireTable()
                                local isComp = cInfo.completed == true
                                bObj.finished = isComp
                                if isComp then done = done + 1 end
                                total = total + 1

                                local isWeighted = cInfo.isWeightedProgress
                                    or (cInfo.criteriaType == 8)
                                    or (cInfo.totalQuantity == 100)
                                    or (cInfo.totalQuantity == 1000)
                                    or (cInfo.quantityString and not issecretvalue(cInfo.quantityString) and cInfo.quantityString:find("%%"))

                                if isWeighted then
                                    local cleanDesc = cDesc
                                    if not issecretvalue(cDesc) then
                                        cleanDesc = cDesc:gsub("%s*%(?%d+%%%)?", ""):gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                                    end
                                    bObj.text = cleanDesc
                                    bObj.type = "progressbar"

                                    local cur = cInfo.quantity or 0
                                    local totalQ = (cInfo.totalQuantity and not issecretvalue(cInfo.totalQuantity) and info.totalQuantity > 0) and info.totalQuantity or 100
                                    local pct = 0
                                    if totalQ == 1000 then
                                        pct = math_min(100, math_max(0, math_floor(cur / 10)))
                                    elseif totalQ == 10000 then
                                        pct = math_min(100, math_max(0, math_floor(cur / 100)))
                                    elseif totalQ > 0 then
                                        pct = math_min(100, math_max(0, math_floor((cur / totalQ) * 100)))
                                    end

                                    bObj.numFulfilled = pct
                                    bObj.numRequired = 100

                                    local barTxt = (cInfo.quantityString and not issecretvalue(cInfo.quantityString) and not cInfo.quantityString:find("%d%d%d%d%%") and not cInfo.quantityString:find("1000%%") and cInfo.quantityString)
                                    if not barTxt or barTxt == "" then
                                        barTxt = tostring(pct) .. "%"
                                    end
                                    bObj.barText = barTxt
                                    bObj.finished = isComp
                                elseif cInfo.quantity and cInfo.totalQuantity and not issecretvalue(cInfo.totalQuantity) and cInfo.totalQuantity > 1 then
                                    local cleanDesc = cDesc
                                    if not issecretvalue(cDesc) then
                                        cleanDesc = cDesc:gsub("%s*%(?%d+/%d+%)?", ""):gsub("%s*:%s*$", "")
                                    end
                                    local baseText = cleanDesc
                                    if not issecretvalue(cInfo.quantity) then
                                        baseText = string_format("%s (%s/%s)", cleanDesc, tostring(cInfo.quantity), tostring(cInfo.totalQuantity))
                                    end
                                    bObj.text = baseText
                                    bObj.numFulfilled = cInfo.quantity
                                    bObj.numRequired = cInfo.totalQuantity
                                    bObj.finished = isComp
                                else
                                    bObj.text = cDesc
                                    bObj.finished = isComp
                                end
                                table_insert(objs, bObj)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 4. Fallback: Stage Description if no criteria or widgets found
    if #objs == 0 and stageDescription and stageDescription ~= "" and not issecretvalue(stageDescription) then
        local sObj = AcquireTable()
        sObj.text = stageDescription
        sObj.finished = false
        if weightedProgress then
            sObj.type = "progressbar"
            sObj.numFulfilled = 0
            sObj.numRequired = 100
            sObj.barText = ""
        end
        table_insert(objs, sObj)
        total = 1
    end

    if #objs > 0 and name and name ~= "" then
        local entry = AcquireTable()
        entry.questID            = 99990000 + (currentStage or 1)
        entry.questLogIndex      = nil
        entry.title              = title
        entry.isComplete         = (isComplete == true)
        entry.isFailed           = false
        entry.isAutoComplete     = false
        entry.isAutoTurnIn       = false
        entry.isWarbandCompleted = false
        entry.isMeta             = false
        entry.canFindGroup       = false
        entry.objectives         = objs
        entry._syntheticObjs     = true
        entry.done               = done
        entry.total              = total
        entry.singleCountStr     = nil
        entry.isWorldQuest       = false
        entry.timeLeftText       = scTimeLeft
        entry.isScenario         = true

        table_insert(list, entry)
    else
        ReleaseTable(objs)
    end
end

local defaultAcquire = function() return {} end
local defaultRelease = function(t) if type(t) == "table" then wipe(t) end end

function sfui.questlog.scenarios.Scan(list, acquireFunc, releaseFunc)
    if not list then return end
    acquireFunc = acquireFunc or defaultAcquire
    releaseFunc = releaseFunc or defaultRelease
    ScanWorldEventScenario(list, acquireFunc, releaseFunc)
end
