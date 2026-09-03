local addonName, addon = ...
sfui = sfui or {}
sfui.questlog = sfui.questlog or {}
sfui.questlog.providers = sfui.questlog.providers or {}

-- Localize Globals & Core C-APIs
local _G = _G
local C_QuestLog                 = _G.C_QuestLog
local C_TaskQuest                = _G.C_TaskQuest
local C_Map                      = _G.C_Map
local C_PerksActivities          = _G.C_PerksActivities
local C_NeighborhoodInitiative   = _G.C_NeighborhoodInitiative
local C_TradeSkillUI             = _G.C_TradeSkillUI
local C_Item                     = _G.C_Item
local C_CurrencyInfo             = _G.C_CurrencyInfo
local C_ContentTracking          = _G.C_ContentTracking
local C_QuestInfoSystem          = _G.C_QuestInfoSystem
local Enum                       = _G.Enum

local select, ipairs, pairs, type = _G.select, _G.ipairs, _G.pairs, _G.type
local math_min, math_max, math_floor = _G.math.min, _G.math.max, _G.math.floor
local tostring, tonumber = _G.tostring, _G.tonumber
local string_format = string.format
local wipe = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local issecretvalue = _G.issecretvalue or function() return false end
local table_insert = _G.table.insert

local GetTrackedAchievements       = _G.GetTrackedAchievements
local GetAchievementInfo           = _G.GetAchievementInfo
local GetAchievementNumCriteria    = _G.GetAchievementNumCriteria
local GetAchievementCriteriaInfo   = _G.GetAchievementCriteriaInfo
local GetNumAutoQuestPopUps        = _G.GetNumAutoQuestPopUps
local GetAutoQuestPopUp            = _G.GetAutoQuestPopUp
local GetQuestProgressBarPercent   = _G.GetQuestProgressBarPercent
local IsInGroup                    = _G.IsInGroup

-- Cache Enum Constants
local QC = Enum and Enum.QuestClassification
local QC_Campaign  = QC and QC.Campaign
local QC_Calling   = QC and QC.Calling
local QC_Important = QC and QC.Important
local QC_Legendary = QC and QC.Legendary
local QC_Recurring = QC and QC.Recurring
local QC_Meta      = (QC and QC.Meta) or 6

local QR = Enum and Enum.QuestRepeatability
local QR_Daily  = (QR and QR.Daily) or 1
local QR_Weekly = (QR and QR.Weekly) or 2

local TRACKING_TYPE_ACHIEVEMENT = (Enum and Enum.ContentTrackingType and Enum.ContentTrackingType.Achievement) or 2
local TRACKING_STOP_TYPE_MANUAL = (Enum and Enum.ContentTrackingStopType and Enum.ContentTrackingStopType.Manual) or 0

-- State Helper
local function GetQLState()
    if sfui.questlog and sfui.questlog.GetState then
        return sfui.questlog.GetState()
    end
    if not SfuiDB then SfuiDB = {} end
    if not SfuiDB.questlog then
        SfuiDB.questlog = {
            collapsed      = {},
            expandedQuests = {},
            hiddenQuests   = {},
            hidden         = false,
        }
    end
    return SfuiDB.questlog
end

-- Internal Caches
local worldQuestCache      = {}
local warbandCompleteCache = {}
local questProgressCache   = {}

-- ─── Untrack Helpers ─────────────────────────────────────
local function UntrackAchievement(achievementID)
    if not achievementID or achievementID <= 0 then return end

    if _G.RemoveTrackedAchievement then
        _G.RemoveTrackedAchievement(achievementID)
    end

    if C_ContentTracking and C_ContentTracking.StopTracking then
        C_ContentTracking.StopTracking(TRACKING_TYPE_ACHIEVEMENT, achievementID, TRACKING_STOP_TYPE_MANUAL)
    end
end

local function UntrackAllAchievements()
    if _G.RemoveTrackedAchievement and GetTrackedAchievements then
        local tracked = { GetTrackedAchievements() }
        for _, id in ipairs(tracked) do
            if id and type(id) == "number" and id > 0 then
                _G.RemoveTrackedAchievement(id)
            end
        end
    end
    if C_ContentTracking and C_ContentTracking.GetTrackedIDs and C_ContentTracking.StopTracking then
        local ids = C_ContentTracking.GetTrackedIDs(TRACKING_TYPE_ACHIEVEMENT)
        if ids and type(ids) == "table" then
            for _, id in ipairs(ids) do
                C_ContentTracking.StopTracking(TRACKING_TYPE_ACHIEVEMENT, id, TRACKING_STOP_TYPE_MANUAL)
            end
        end
    end
end

local function UntrackAllActivities()
    if C_PerksActivities and C_PerksActivities.RemoveTrackedPerksActivity then
        local tracked = C_PerksActivities.GetTrackedPerksActivities()
        if tracked and tracked.trackedIDs then
            for _, id in ipairs(tracked.trackedIDs) do
                C_PerksActivities.RemoveTrackedPerksActivity(id)
            end
        end
    end
    if C_NeighborhoodInitiative and C_NeighborhoodInitiative.RemoveTrackedInitiativeTask then
        local tracked = C_NeighborhoodInitiative.GetTrackedInitiativeTasks()
        if tracked and tracked.trackedIDs then
            for _, id in ipairs(tracked.trackedIDs) do
                C_NeighborhoodInitiative.RemoveTrackedInitiativeTask(id)
            end
        end
    end
    if C_TradeSkillUI and C_TradeSkillUI.SetRecipeTracked then
        for _, isRecraft in ipairs({ false, true }) do
            local recipes = C_TradeSkillUI.GetRecipesTracked(isRecraft)
            if recipes then
                for _, rID in ipairs(recipes) do
                    C_TradeSkillUI.SetRecipeTracked(rID, false, isRecraft)
                end
            end
        end
    end
end

-- ─── Achievements Scanner ────────────────────────────────
local staticAchMap = {}
local staticAchList = {}

local function GetAchievementCriteriaList(achievementID, AcquireTable)
    local numCriteria = 0
    if GetAchievementNumCriteria then
        local n = GetAchievementNumCriteria(achievementID)
        if type(n) == "number" then numCriteria = n end
    end

    if numCriteria > 0 and GetAchievementCriteriaInfo then
        local objectives = nil
        for i = 1, numCriteria do
            local cString, cType, completed, qty, reqQty, _, _, _, qtyString = GetAchievementCriteriaInfo(achievementID, i)
            local finished = (completed == true) or (completed == 1)
            local txt = cString
            if not txt or txt == "" then txt = qtyString end
            if txt and txt ~= "" then
                qty = tonumber(qty)
                reqQty = tonumber(reqQty)
                if qty and reqQty and reqQty > 1 then
                    txt = txt .. " (" .. tostring(qty) .. "/" .. tostring(reqQty) .. ")"
                end
                if not objectives then objectives = AcquireTable() end
                local sObj = AcquireTable()
                sObj.text = txt
                sObj.finished = finished
                objectives[#objectives + 1] = sObj
            end
        end
        return objectives
    end
    return nil
end

local function ScanTrackedAchievements(intoList, AcquireTable)
    wipe(staticAchMap)
    wipe(staticAchList)

    local function addID(id)
        if type(id) == "number" and id > 0 and not staticAchMap[id] then
            staticAchMap[id] = true
            staticAchList[#staticAchList + 1] = id
        end
    end

    if GetTrackedAchievements then
        local nTracked = select("#", GetTrackedAchievements())
        for i = 1, nTracked do
            local id = select(i, GetTrackedAchievements())
            if id then addID(id) end
        end
    end

    if C_ContentTracking and C_ContentTracking.GetTrackedIDs then
        local ids = C_ContentTracking.GetTrackedIDs(TRACKING_TYPE_ACHIEVEMENT)
        if ids and type(ids) == "table" then
            for _, id in ipairs(ids) do
                addID(id)
            end
        end
    end

    if #staticAchList == 0 then return end

    for _, achievementID in ipairs(staticAchList) do
        if type(achievementID) == "number" and achievementID > 0 then
            local id, name, points, completed, month, day, year, description, flags, icon = GetAchievementInfo(achievementID)
            if name and name ~= "" then
                local isComplete = (completed == true) or (completed == 1)
                local objs = GetAchievementCriteriaList(achievementID, AcquireTable)
                if (not objs or #objs == 0) and description and description ~= "" then
                    if not objs then objs = AcquireTable() end
                    local sObj = AcquireTable()
                    sObj.text = description
                    sObj.finished = isComplete
                    objs[#objs + 1] = sObj
                end

                local done, total = 0, (objs and #objs or 0)
                if objs then
                    for _, obj in ipairs(objs) do
                        if obj.finished then done = done + 1 end
                    end
                end

                local entry = AcquireTable()
                entry.achievementID      = achievementID
                entry.questID            = nil
                entry.title              = name
                entry.description        = description
                entry.points             = points
                entry.icon               = icon
                entry.isComplete         = isComplete
                entry.isAchievement      = true
                entry.objectives         = objs
                entry._syntheticObjs     = (objs ~= nil)
                entry.done               = done
                entry.total              = total
                entry.singleCountStr     = (total > 0) and (done .. "/" .. total) or nil
                intoList[#intoList + 1] = entry
            end
        end
    end
end

-- ─── Activity Scanners (Traveler's Log, Housing, Recipes, Popups) ──
local function ScanTrackedPerksActivities(intoList, AcquireTable)
    if not C_PerksActivities or not C_PerksActivities.GetTrackedPerksActivities or not C_PerksActivities.GetPerksActivityInfo then return end
    local tracked = C_PerksActivities.GetTrackedPerksActivities()
    local ids = tracked and tracked.trackedIDs
    if not ids or #ids == 0 then return end

    for _, actID in ipairs(ids) do
        if type(actID) == "number" and actID > 0 then
            local info = C_PerksActivities.GetPerksActivityInfo(actID)
            if info and not info.completed and info.activityName and info.activityName ~= "" then
                local objs = nil
                local done, total = 0, 0
                if info.requirementsList then
                    for _, req in ipairs(info.requirementsList) do
                        if req.requirementText and req.requirementText ~= "" and not issecretvalue(req.requirementText) then
                            if not objs then objs = AcquireTable() end
                            local sObj = AcquireTable()
                            local cleanReq = req.requirementText:gsub(" / ", "/")
                            sObj.text = cleanReq
                            sObj.finished = (req.completed == true)
                            objs[#objs + 1] = sObj
                            total = total + 1
                            if req.completed then done = done + 1 end
                        end
                    end
                end

                local entry = AcquireTable()
                entry.activityID         = actID
                entry.isPerksActivity    = true
                entry.title              = info.activityName
                entry.description        = info.description
                entry.isComplete         = (info.completed == true)
                entry.objectives         = objs
                entry._syntheticObjs     = (objs ~= nil)
                entry.done               = done
                entry.total              = total
                entry.singleCountStr     = (total > 0) and (done .. "/" .. total) or nil
                intoList[#intoList + 1]  = entry
            end
        end
    end
end

local function ScanTrackedHousingInitiatives(intoList, AcquireTable)
    if not C_NeighborhoodInitiative or not C_NeighborhoodInitiative.GetTrackedInitiativeTasks or not C_NeighborhoodInitiative.GetInitiativeTaskInfo then return end
    local tracked = C_NeighborhoodInitiative.GetTrackedInitiativeTasks()
    local ids = tracked and tracked.trackedIDs
    if not ids or #ids == 0 then return end

    for _, taskID in ipairs(ids) do
        if type(taskID) == "number" and taskID > 0 then
            local info = C_NeighborhoodInitiative.GetInitiativeTaskInfo(taskID)
            if info and not info.completed and info.taskName and info.taskName ~= "" then
                local objs = nil
                local done, total = 0, 0
                if info.requirementsList then
                    for _, req in ipairs(info.requirementsList) do
                        if req.requirementText and req.requirementText ~= "" and not issecretvalue(req.requirementText) then
                            if not objs then objs = AcquireTable() end
                            local sObj = AcquireTable()
                            local cleanReq = req.requirementText:gsub(" / ", "/")
                            sObj.text = cleanReq
                            sObj.finished = (req.completed == true)
                            objs[#objs + 1] = sObj
                            total = total + 1
                            if req.completed then done = done + 1 end
                        end
                    end
                end

                local entry = AcquireTable()
                entry.housingTaskID      = taskID
                entry.isHousingTask      = true
                entry.title              = info.taskName
                entry.isComplete         = (info.completed == true)
                entry.objectives         = objs
                entry._syntheticObjs     = (objs ~= nil)
                entry.done               = done
                entry.total              = total
                entry.singleCountStr     = (total > 0) and (done .. "/" .. total) or nil
                intoList[#intoList + 1]  = entry
            end
        end
    end
end

local function ScanTrackedRecipes(intoList, AcquireTable)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipesTracked or not C_TradeSkillUI.GetRecipeSchematic then return end
    for _, isRecraft in ipairs({ false, true }) do
        local recipes = C_TradeSkillUI.GetRecipesTracked(isRecraft)
        if recipes and #recipes > 0 then
            for _, recipeID in ipairs(recipes) do
                if type(recipeID) == "number" and recipeID > 0 then
                    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, isRecraft)
                    if schematic and schematic.name and schematic.name ~= "" then
                        local objs = nil
                        local done, total = 0, 0
                        if schematic.reagentSlotSchematics then
                            for _, slot in ipairs(schematic.reagentSlotSchematics) do
                                local req = slot.quantityRequired or 1
                                local reagent = slot.reagents and slot.reagents[1]
                                if reagent then
                                    local itemID = reagent.itemID
                                    local currencyID = reagent.currencyID
                                    local rName = nil
                                    local curCount = 0
                                    if itemID then
                                        curCount = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID)) or (_G.GetItemCount and _G.GetItemCount(itemID)) or 0
                                        if C_Item and C_Item.GetItemNameByID then
                                            rName = C_Item.GetItemNameByID(itemID)
                                        end
                                        if not rName and _G.GetItemInfo then
                                            rName = _G.GetItemInfo(itemID)
                                        end
                                        rName = rName or ("Item #" .. tostring(itemID))
                                    elseif currencyID and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                                        local cInfo = C_CurrencyInfo.GetCurrencyInfo(currencyID)
                                        if cInfo then
                                            rName = cInfo.name
                                            curCount = cInfo.quantity or 0
                                        end
                                    end

                                    if rName and rName ~= "" then
                                        if not objs then objs = AcquireTable() end
                                        local isFin = (curCount >= req)
                                        local sObj = AcquireTable()
                                        sObj.text = string_format("%s (%d/%d)", rName, curCount, req)
                                        sObj.finished = isFin
                                        objs[#objs + 1] = sObj
                                        total = total + 1
                                        if isFin then done = done + 1 end
                                    end
                                end
                            end
                        end

                        local isComplete = (total > 0 and done == total)
                        local entry = AcquireTable()
                        entry.recipeID           = recipeID
                        entry.isRecraft          = isRecraft
                        entry.isRecipe           = true
                        entry.title              = schematic.name
                        entry.isComplete         = isComplete
                        entry.objectives         = objs
                        entry._syntheticObjs     = (objs ~= nil)
                        entry.done               = done
                        entry.total              = total
                        entry.singleCountStr     = (total > 0) and (done .. "/" .. total) or nil
                        intoList[#intoList + 1]  = entry
                    end
                end
            end
        end
    end
end

local function ScanAutoQuestPopUps(intoList, AcquireTable, processedQuests)
    if not GetNumAutoQuestPopUps or not GetAutoQuestPopUp then return end
    local num = GetNumAutoQuestPopUps() or 0
    if num == 0 then return end

    for i = 1, num do
        local questID, popUpType = GetAutoQuestPopUp(i)
        if questID and questID > 0 and popUpType == "OFFER" and (not processedQuests or not processedQuests[questID]) then
            local title = (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
                       or (C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(questID))
                       or "Quest Offer"

            local entry = AcquireTable()
            entry.questID            = questID
            entry.title              = title
            entry.isAutoQuestOffer   = true
            entry.isComplete         = false
            entry.isFailed           = false
            entry.done               = 0
            entry.total              = 0
            if processedQuests then
                processedQuests[questID] = true
            end
            intoList[#intoList + 1]  = entry
        end
    end
end

-- ─── Classification & Cache Queries ───────────────────────
local function IsWorldQuest(questID)
    local cached = worldQuestCache[questID]
    if cached ~= nil then return cached end
    local result = false
    if C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(questID) then
        result = true
    elseif _G.QuestUtils_IsQuestWorldQuest and _G.QuestUtils_IsQuestWorldQuest(questID) then
        result = true
    end
    worldQuestCache[questID] = result
    return result
end

local function IsQuestWatched(questID)
    if not questID or questID <= 0 then return false end
    if C_QuestLog.GetQuestWatchType then
        local wt = C_QuestLog.GetQuestWatchType(questID)
        if wt ~= nil then return true end
    end
    if C_QuestLog.IsQuestWatched then
        local w = C_QuestLog.IsQuestWatched(questID)
        if w then return true end
        if C_QuestLog.GetLogIndexForQuestID then
            local lIndex = C_QuestLog.GetLogIndexForQuestID(questID)
            if lIndex then
                local w2 = C_QuestLog.IsQuestWatched(lIndex)
                if w2 then return true end
            end
        end
    end
    return false
end

local function IsQuestWarbandCompleted(questID)
    local cached = warbandCompleteCache[questID]
    if cached ~= nil then return cached end

    local completed = false
    if C_QuestLog.IsQuestFlaggedCompletedOnAccount then
        completed = C_QuestLog.IsQuestFlaggedCompletedOnAccount(questID) or false
    end
    warbandCompleteCache[questID] = completed
    return completed
end

local function IsMetaQuest(questID, defaultInfo)
    if not questID or questID <= 0 then return false end
    if defaultInfo and (defaultInfo.isMeta or defaultInfo.questClassification == QC_Meta) then return true end

    if C_QuestLog.IsMetaQuest then
        local v = C_QuestLog.IsMetaQuest(questID)
        if v then return true end
    end

    if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification then
        local cls = C_QuestInfoSystem.GetQuestClassification(questID)
        if cls and (cls == QC_Meta or (QC and QC.Meta and cls == QC.Meta)) then
            return true
        end
    end

    if C_QuestLog.GetQuestTagInfo then
        local tag = C_QuestLog.GetQuestTagInfo(questID)
        if tag then
            if type(tag) == "table" then
                if tag.isMeta or tag.tagName == "Meta" or tag.tagID == (Enum.QuestTag and Enum.QuestTag.Meta) or tag.tagID == 128 then
                    return true
                end
            elseif tag == (Enum.QuestTag and Enum.QuestTag.Meta) or tag == 128 then
                return true
            end
        end
    end

    if C_QuestLog.GetInfo then
        local lIndex = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
        if lIndex then
            local info = C_QuestLog.GetInfo(lIndex)
            if info and (info.isMeta or info.questClassification == QC_Meta) then
                return true
            end
        end
    end

    return false
end

local function ClassifyQuest(info, questID)
    if info.isTask or info.isBounty or IsWorldQuest(questID) then
        return "world"
    end
    if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification then
        local cls = C_QuestInfoSystem.GetQuestClassification(questID)
        if cls then
            if cls == QC_Campaign or cls == QC_Calling    then return "campaign"   end
            if cls == QC_Meta                             then return "meta"       end
            if cls == QC_Important or cls == QC_Legendary then return "important"  end
            if cls == QC_Recurring                        then return "activities" end
        end
    end
    if info.campaignID and info.campaignID > 0 then return "campaign" end
    if IsMetaQuest(questID, info) then return "meta" end
    if C_QuestLog.IsImportantQuest then
        local v = C_QuestLog.IsImportantQuest(questID)
        if v then return "important" end
    end
    local freq = info.frequency
    if freq == QR_Daily or freq == QR_Weekly or (freq and freq > 0) then
        return "activities"
    end
    return "zone"
end

-- ─── Build Quest Entry ────────────────────────────────────
local function BuildQuestEntry(questID, forcedSectionID, defaultInfo, AcquireTable, state)
    AcquireTable = AcquireTable or function() return {} end

    local isComplete, isFailed = false, false
    if C_QuestLog.IsComplete then
        isComplete = C_QuestLog.IsComplete(questID) or false
    end
    if C_QuestLog.IsFailed then
        isFailed = C_QuestLog.IsFailed(questID) or false
    end

    local objs = nil
    if C_QuestLog.GetQuestObjectives then
        local v = C_QuestLog.GetQuestObjectives(questID)
        if v and #v > 0 then objs = v end
    end

    local isSynthetic = false
    local qProgressBarPct = nil
    if GetQuestProgressBarPercent then
        local p = GetQuestProgressBarPercent(questID)
        if p and p > 0 then qProgressBarPct = p end
    end
    if not qProgressBarPct and C_TaskQuest and C_TaskQuest.GetQuestProgressBarInfo then
        local val = C_TaskQuest.GetQuestProgressBarInfo(questID)
        if val and val > 0 then qProgressBarPct = val end
    end
    if not qProgressBarPct and _G.GetQuestProgressBarInfo then
        local val = _G.GetQuestProgressBarInfo(questID)
        if val and val > 0 then qProgressBarPct = val end
    end

    if not objs or #objs == 0 then
        if qProgressBarPct and qProgressBarPct > 0 then
            local sObj = AcquireTable()
            sObj.text = tostring(qProgressBarPct) .. "%"
            sObj.barText = tostring(qProgressBarPct) .. "%"
            sObj.finished = (qProgressBarPct >= 100)
            sObj.numFulfilled = qProgressBarPct
            sObj.numRequired = 100
            sObj.type = "progressbar"
            local sList = AcquireTable()
            table_insert(sList, sObj)
            objs = sList
            isSynthetic = true
        end
    elseif objs then
        for _, obj in ipairs(objs) do
            local isBarType = (obj.type == "progressbar" or obj.type == 8 or (obj.objectiveType and (obj.objectiveType == 8 or obj.objectiveType == "progressbar")))

            if isBarType then
                obj.type = "progressbar"
                if (not obj.numFulfilled or obj.numFulfilled == 0) and qProgressBarPct then
                    obj.numFulfilled = qProgressBarPct
                end
                if not obj.numRequired or obj.numRequired <= 1 then
                    obj.numRequired = 100
                end
                if not obj.barText or obj.barText == "" then
                    if obj.numFulfilled and not issecretvalue(obj.numFulfilled) then
                        obj.barText = tostring(obj.numFulfilled) .. "%"
                    end
                end
            end
        end
    end

    local done, total = 0, 0
    local singleCountStr = nil
    local progressHash = (isComplete and "1" or "0")

    if objs and #objs == 1 then
        local obj = objs[1]
        total = 1
        if obj.finished then done = 1 end

        local cur = obj.numFulfilled or 0
        local req = obj.numRequired or 0
        local curStr = issecretvalue(cur) and "S" or tostring(cur)
        local reqStr = issecretvalue(req) and "S" or tostring(req)
        progressHash = progressHash .. "_" .. curStr .. "/" .. reqStr .. (obj.finished and "D" or "U")

        if not issecretvalue(cur) and not issecretvalue(req) and req > 1 then
            singleCountStr = tostring(cur) .. "/" .. tostring(req)
        elseif obj.text and obj.text ~= "" and not issecretvalue(obj.text) then
            local pCur, pReq = obj.text:match("(%d+)/(%d+)")
            if pCur and pReq and tonumber(pReq) and tonumber(pReq) > 1 then
                singleCountStr = pCur .. "/" .. pReq
            else
                local pct = obj.text:match("(%d+)%%")
                if pct then
                    singleCountStr = pct .. "%"
                end
            end
        end
    elseif objs and #objs > 1 then
        for idx, obj in ipairs(objs) do
            total = total + 1
            if obj.finished then done = done + 1 end
            local cur = obj.numFulfilled or 0
            local req = obj.numRequired or 0
            local curStr = issecretvalue(cur) and "S" or tostring(cur)
            local reqStr = issecretvalue(req) and "S" or tostring(req)
            progressHash = progressHash .. "_" .. tostring(idx) .. ":" .. curStr .. "/" .. reqStr .. (obj.finished and "D" or "U")
        end
    end

    -- Fast numeric change detection
    if questProgressCache[questID] and questProgressCache[questID] ~= progressHash then
        local st = state or GetQLState()
        st.expandedQuests = st.expandedQuests or {}
        if not isComplete then
            st.expandedQuests[questID] = true
        else
            st.expandedQuests[questID] = false
        end

        if st.hiddenQuests and isComplete then
            st.hiddenQuests[questID] = nil
        end
        if forcedSectionID and st.collapsed then
            st.collapsed[forcedSectionID] = false
        end
    end
    questProgressCache[questID] = progressHash

    local title = defaultInfo and defaultInfo.title
    if not title or title == "" then
        if C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID then
            local t = C_TaskQuest.GetQuestInfoByQuestID(questID)
            if t and t ~= "" then title = t end
        end
        if (not title or title == "") and C_QuestLog.GetTitleForQuestID then
            local t = C_QuestLog.GetTitleForQuestID(questID)
            if t and t ~= "" then title = t end
        end
        if (not title or title == "") and _G.QuestUtils_GetQuestName then
            local t = _G.QuestUtils_GetQuestName(questID)
            if t and t ~= "" then title = t end
        end
    end
    title = title or "Unknown Quest"

    local timeLeftText = nil
    local isCriticalTime = false
    local isWorld = (forcedSectionID == "world" or IsWorldQuest(questID))

    if isWorld then
        if C_TaskQuest and C_TaskQuest.GetQuestTimeLeftMinutes then
            local mins = C_TaskQuest.GetQuestTimeLeftMinutes(questID)
            if mins and mins > 0 then
                if mins <= 15 then
                    isCriticalTime = true
                end
                if mins >= 1440 then
                    local d = math_floor(mins / 1440)
                    local h = math_floor((mins % 1440) / 60)
                    if h > 0 then
                        timeLeftText = string_format("%dd %dh", d, h)
                    else
                        timeLeftText = string_format("%dd", d)
                    end
                elseif mins >= 60 then
                    local h = math_floor(mins / 60)
                    local m = mins % 60
                    if m > 0 then
                        timeLeftText = string_format("%dh %dm", h, m)
                    else
                        timeLeftText = string_format("%dh", h)
                    end
                else
                    timeLeftText = string_format("%dm", mins)
                end
            end
        end
    end

    local partyCount = 0
    if IsInGroup and IsInGroup() and C_QuestLog and C_QuestLog.GetNumPartyMembersOnQuest then
        local numP = C_QuestLog.GetNumPartyMembersOnQuest(questID)
        if numP and numP > 0 then
            partyCount = numP
        end
    end

    local lIndex = nil
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        lIndex = C_QuestLog.GetLogIndexForQuestID(questID)
    end

    local isAutoComplete = defaultInfo and defaultInfo.isAutoComplete
    if isAutoComplete == nil and lIndex and C_QuestLog and C_QuestLog.GetInfo then
        local info = C_QuestLog.GetInfo(lIndex)
        if info then isAutoComplete = info.isAutoComplete end
    end
    if isAutoComplete == nil and _G.QuestCache and _G.QuestCache.Get then
        local qObj = _G.QuestCache:Get(questID)
        if qObj then isAutoComplete = qObj.isAutoComplete end
    end

    local isWarbandCompleted = IsQuestWarbandCompleted(questID)
    local isMeta = IsMetaQuest(questID, defaultInfo)
    local canFindGroup = (defaultInfo and defaultInfo.suggestedGroup and defaultInfo.suggestedGroup > 1) or false

    local isAutoTurnIn = (isAutoComplete and isComplete)
    if not isAutoTurnIn and C_QuestLog and C_QuestLog.GetAutoQuestPopUpType then
        local pt = C_QuestLog.GetAutoQuestPopUpType(questID)
        if pt == "COMPLETE" then isAutoTurnIn = true end
    end

    local entry = AcquireTable()
    entry.questID            = questID
    entry.questLogIndex      = lIndex
    entry.title              = title
    entry.isComplete         = isComplete
    entry.isFailed           = isFailed
    entry.isAutoComplete     = isAutoComplete
    entry.isAutoTurnIn       = isAutoTurnIn
    entry.isWarbandCompleted = isWarbandCompleted
    entry.isMeta             = isMeta
    entry.canFindGroup       = canFindGroup
    entry.objectives         = objs
    entry._syntheticObjs     = isSynthetic
    entry.done               = done
    entry.total              = total
    entry.singleCountStr     = singleCountStr
    entry.isWorldQuest       = isWorld
    entry.timeLeftText       = timeLeftText
    entry.isCriticalTime     = isCriticalTime
    entry.partyCount         = partyCount
    entry.isScenario         = false
    return entry
end

-- ─── Quest Progress Check ─────────────────────────────────
local function QuestHasProgress(entry)
    if not entry then return false end
    if entry.isComplete then return true end
    if entry.done and entry.done > 0 then return true end
    if entry.singleCountStr then
        local cur = entry.singleCountStr:match("(%d+)/%d+") or entry.singleCountStr:match("(%d+)%%")
        if cur and tonumber(cur) and tonumber(cur) > 0 then return true end
    end
    if entry.objectives then
        for _, obj in ipairs(entry.objectives) do
            if obj.finished then return true end
            if obj.numFulfilled and obj.numFulfilled > 0 then return true end
            if obj.text then
                local cur = obj.text:match("(%d+)/%d+") or obj.text:match("(%d+)%%")
                if cur and tonumber(cur) and tonumber(cur) > 0 then return true end
            end
        end
    end
    return false
end

-- ─── Cache Management ────────────────────────────────────
local function ClearQuestCache(questID)
    if not questID then return end
    questProgressCache[questID]  = nil
    warbandCompleteCache[questID] = nil
    worldQuestCache[questID]     = nil
end

local function ClearWorldQuestCache()
    wipe(worldQuestCache)
end

local function ClearWarbandCache()
    wipe(warbandCompleteCache)
end

local function PruneProgressCacheForWorldQuests()
    for qID in pairs(questProgressCache) do
        if IsWorldQuest(qID) or (C_QuestLog and C_QuestLog.IsQuestTask and C_QuestLog.IsQuestTask(qID)) then
            questProgressCache[qID] = nil
        end
    end
end

local function GetCacheCounts()
    local pCount, wCount, wqCount = 0, 0, 0
    for _ in pairs(questProgressCache) do pCount = pCount + 1 end
    for _ in pairs(warbandCompleteCache) do wCount = wCount + 1 end
    for _ in pairs(worldQuestCache) do wqCount = wqCount + 1 end
    return pCount, wCount, wqCount
end

-- ─── Public Module Exports ───────────────────────────────
sfui.questlog.providers.UntrackAchievement               = UntrackAchievement
sfui.questlog.providers.UntrackAllAchievements           = UntrackAllAchievements
sfui.questlog.providers.UntrackAllActivities             = UntrackAllActivities
sfui.questlog.providers.ScanAchievements                 = ScanTrackedAchievements
sfui.questlog.providers.ScanPerksActivities              = ScanTrackedPerksActivities
sfui.questlog.providers.ScanHousingInitiatives           = ScanTrackedHousingInitiatives
sfui.questlog.providers.ScanRecipes                      = ScanTrackedRecipes
sfui.questlog.providers.ScanAutoQuestPopUps              = ScanAutoQuestPopUps
sfui.questlog.providers.IsWorldQuest                     = IsWorldQuest
sfui.questlog.providers.IsQuestWatched                   = IsQuestWatched
sfui.questlog.providers.IsWarbandCompleted               = IsQuestWarbandCompleted
sfui.questlog.providers.IsMetaQuest                      = IsMetaQuest
sfui.questlog.providers.ClassifyQuest                    = ClassifyQuest
sfui.questlog.providers.BuildQuestEntry                  = BuildQuestEntry
sfui.questlog.providers.QuestHasProgress                 = QuestHasProgress
sfui.questlog.providers.ClearQuestCache                  = ClearQuestCache
sfui.questlog.providers.ClearWorldQuestCache             = ClearWorldQuestCache
sfui.questlog.providers.ClearWarbandCache                = ClearWarbandCache
sfui.questlog.providers.PruneProgressCacheForWorldQuests = PruneProgressCacheForWorldQuests
sfui.questlog.providers.GetCacheCounts                   = GetCacheCounts
