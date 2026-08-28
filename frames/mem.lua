local addonName, addon = ...
sfui = sfui or {}
sfui.mem = {}

local cfg = sfui.config
local common = sfui.common

local _G = _G
local print = print
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber
local string_format = string.format
local table_sort = table.sort
local table_insert = table.insert
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local math_ceil = math.ceil
local GetTime = GetTime
local collectgarbage = collectgarbage
local UpdateAddOnMemoryUsage = UpdateAddOnMemoryUsage
local GetAddOnMemoryUsage = GetAddOnMemoryUsage
local CreateFrame = CreateFrame
local UIParent = UIParent
local UISpecialFrames = UISpecialFrames
local C_Timer = C_Timer

local PREFIX = "|cff6600ff[sfui memory]|r "

-- Helper: Format memory size in lowercase
local function FormatKB(kb)
    if not kb then return "0 kb" end
    if kb >= 1024 then
        return string_format("%.2f mb", kb / 1024)
    else
        return string_format("%.1f kb", kb)
    end
end

-- ---------------------------------------------------------------------------
-- 1. COMPREHENSIVE MODULE POOL & CACHE INSPECTOR (All Lowercase)
-- ---------------------------------------------------------------------------
function sfui.mem.GetModuleStats()
    local stats = {}

    -- Quests Module
    local qlTablePool, qlRowPool, qlObjPool = 0, 0, 0
    local qlActiveRows, qlActiveObjs = 0, 0
    local qlProgCache, qlWbCache, qlWqCache = 0, 0, 0
    if sfui.questlog_debug_info then
        local q = sfui.questlog_debug_info()
        qlTablePool = q.tablePool or 0
        qlRowPool = q.rowPool or 0
        qlObjPool = q.objPool or 0
        qlActiveRows = q.activeRows or 0
        qlActiveObjs = q.activeObjs or 0
        qlProgCache = q.progCache or 0
        qlWbCache = q.wbCache or 0
        qlWqCache = q.wqCache or 0
    end
    stats["quests"] = {
        name = "quests tracker",
        status = qlActiveRows > 0 and "|cff00ff88active|r" or "|cff888888idle|r",
        line1 = string_format("rows: %d act / %d pool • objs: %d act / %d pool", qlActiveRows, qlRowPool, qlActiveObjs, qlObjPool),
        line2 = string_format("tables: %d/100 pool • caches: p=%d, w=%d", qlTablePool, qlProgCache, qlWbCache),
    }

    -- Mythic & Delves Module
    local mythicStats = {
        name = "mythic+ & delves",
        status = "|cff888888idle|r",
        line1 = "pools: spell=0, curr=0, death=0",
        line2 = "roster: 0 tracked • badges: 0 pool",
    }
    if sfui.mythic_debug_info then
        local m = sfui.mythic_debug_info()
        local inDungeon = (m.playerList or 0) > 0
        mythicStats.status = inDungeon and "|cff00ff88in instance|r" or "|cff888888idle|r"
        mythicStats.line1 = string_format("pools: spell=%d, curr=%d, death=%d", m.spellPool or 0, m.currencyPool or 0, m.deathPool or 0)
        mythicStats.line2 = string_format("roster: %d players • badges: %d pool", m.playerList or 0, m.badgePool or 0)
    end
    stats["mythic"] = mythicStats

    -- Tracked Bars Module
    local tbStats = {
        name = "tracked bars",
        status = "|cff888888idle|r",
        line1 = "bars: 0 active / 0 shown",
        line2 = "pools: 0 frames, 0 configs",
    }
    if sfui.trackedbars_debug_info then
        local tb = sfui.trackedbars_debug_info()
        tbStats.status = (tb.shownBars or 0) > 0 and "|cff00ff88active|r" or "|cff8888880 shown|r"
        tbStats.line1 = string_format("bars: %d active / %d shown", tb.activeBars or 0, tb.shownBars or 0)
        tbStats.line2 = string_format("pools: frames=%d, cfg=%d • dirty=%s", tb.barPool or 0, tb.configPool or 0, tb.isDirty and "yes" or "no")
    end
    stats["trackedbars"] = tbStats

    -- Tracked Icons Module
    local tiStats = {
        name = "tracked icons",
        status = "|cff888888idle|r",
        line1 = "panels: 0 • icons: 0",
        line2 = "glows: 0 • cd cache: 0",
    }
    if sfui.trackedicons_debug_info then
        local ti = sfui.trackedicons_debug_info()
        tiStats.status = (ti.icons or 0) > 0 and "|cff00ff88active|r" or "|cff888888idle|r"
        tiStats.line1 = string_format("panels: %d • total icons: %d", ti.panels or 0, ti.icons or 0)
        tiStats.line2 = string_format("glows: %d • cd cache: %d • dirty=%s", ti.activeGlows or 0, ti.cdCache or 0, (ti.needsState or ti.needsLayout) and "yes" or "no")
    end
    stats["trackedicons"] = tiStats

    -- Unit Bars Module
    local barsStats = {
        name = "unit health & power",
        status = "|cff00ff88active|r",
        line1 = "health: shown • power: shown",
        line2 = "mount ticker: idle • events: filtered",
    }
    if sfui.bars_debug_info then
        local b = sfui.bars_debug_info()
        barsStats.line1 = string_format("bar0: %s • bar1: %s • runes: %s", b.bar0Shown and "shown" or "off", b.bar1Shown and "shown" or "off", b.runeBarCreated and "ready" or "off")
        barsStats.line2 = string_format("mount ticker: %s • unit filtered", b.mountSpeedActive and "|cff00ff88gliding|r" or "sleeping")
    end
    stats["bars"] = barsStats

    -- World Quests Module
    local wqsStats = {
        name = "world quests",
        status = "|cff888888idle|r",
        line1 = "rows: 0 act / 0 pool",
        line2 = "reward cache: 0 • table pool: 0",
    }
    if sfui.wqs_debug_info then
        local w = sfui.wqs_debug_info()
        wqsStats.status = (w.activeFrames or 0) > 0 and "|cff00ff88active|r" or "|cff888888idle|r"
        wqsStats.line1 = string_format("rows: %d act / %d pool", w.activeFrames or 0, w.framePool or 0)
        wqsStats.line2 = string_format("reward cache: %d • tables: %d pool", w.rewardCache or 0, w.tablePool or 0)
    end
    stats["wqs"] = wqsStats

    -- Gear Manager Module
    local gearStats = {
        name = "gear manager",
        status = "|cff00ff88active|r",
        line1 = "equipped cache: 18 slots",
        line2 = "tracked items: 18 • zero churn",
    }
    if sfui.gear_debug_info then
        local gInfo = sfui.gear_debug_info()
        gearStats.line1 = string_format("equipped cache: %d slots", gInfo.equippedCache or 0)
        gearStats.line2 = string_format("tracked items: %d • static closures", gInfo.lastEquipped or 0)
    end
    stats["gear"] = gearStats

    -- Stats Module
    local statsMod = {
        name = "stat summary",
        status = "|cff00ff88ready|r",
        line1 = "spec priority caches: 0",
        line2 = "pawn stat strings: 0",
    }
    if sfui.stats_debug_info then
        local s = sfui.stats_debug_info()
        statsMod.line1 = string_format("spec priority caches: %d", s.cachedSpecOrders or 0)
        statsMod.line2 = string_format("pawn stat strings: %d", s.pawnOrders or 0)
    end
    stats["stats"] = statsMod

    -- Alts Manager Module
    local altsMod = {
        name = "alts & vault",
        status = "|cff888888closed|r",
        line1 = "tracked characters: 0",
        line2 = "pools: col=0, cell=0, tab=0",
    }
    if sfui.alts_debug_info then
        local a = sfui.alts_debug_info()
        altsMod.status = a.frameShown and "|cff00ff88open|r" or "|cff888888closed|r"
        altsMod.line1 = string_format("tracked characters: %d", a.trackedAlts or 0)
        altsMod.line2 = string_format("pools: col=%d, cell=%d, tab=%d", a.columnPool or 0, a.cellPool or 0, a.tablePool or 0)
    end
    stats["alts"] = altsMod

    -- Merchant & Junk Module
    local merchMod = {
        name = "merchant 4x7 grid",
        status = "|cff888888closed|r",
        line1 = "frame: ready",
        line2 = "table pool: 0",
    }
    if sfui.merchant_debug_info then
        local m = sfui.merchant_debug_info()
        merchMod.status = m.frameShown and "|cff00ff88open|r" or "|cff888888closed|r"
        merchMod.line1 = string_format("frame: %s", m.frameCreated and "ready" or "none")
        merchMod.line2 = string_format("table pool: %d tables", m.tablePool or 0)
    end
    stats["merchant"] = merchMod

    -- Portals Module
    local portMod = {
        name = "portals & flyouts",
        status = "|cff888888closed|r",
        line1 = "panel: ready",
        line2 = "action overlays: static",
    }
    if sfui.portals_debug_info then
        local p = sfui.portals_debug_info()
        portMod.status = p.frameShown and "|cff00ff88open|r" or "|cff888888closed|r"
        portMod.line1 = string_format("panel: %s", p.frameCreated and "ready" or "none")
        portMod.line2 = "overlays: static shared frame"
    end
    stats["portals"] = portMod

    -- Castbars Module
    local cbMod = {
        name = "castbars",
        status = "|cff00ff88ready|r",
        line1 = "player: idle • target: idle",
        line2 = "engine: curve animation",
    }
    if sfui.castbar_debug_info then
        local cb = sfui.castbar_debug_info()
        cbMod.line1 = string_format("player: %s • target: %s", cb.playerBarShown and "|cff00ff88casting|r" or "idle", cb.targetBarShown and "|cff00ff88casting|r" or "idle")
        cbMod.line2 = "haste cache: secret-safe"
    end
    stats["castbars"] = cbMod

    -- Minimap Module
    local miniMod = {
        name = "minimap collector",
        status = "|cff00ff88active|r",
        line1 = "buttons collected: 0",
        line2 = "auto-zoom: idle",
    }
    if sfui.minimap_debug_info then
        local mm = sfui.minimap_debug_info()
        miniMod.line1 = string_format("buttons collected: %d", mm.buttonCount or 0)
        miniMod.line2 = string_format("auto-zoom: %s", mm.autoZoomActive and "|cff00ff88running|r" or "idle")
    end
    stats["minimap"] = miniMod

    -- Glow Effects Module
    local glowMod = {
        name = "glow engine",
        status = "|cff00ff88ready|r",
        line1 = "libcustomglow: ready",
        line2 = "active glow tracker: gated",
    }
    if sfui.glows_debug_info then
        local gInfo = sfui.glows_debug_info()
        glowMod.line1 = string_format("libcustomglow-1.0: %s", gInfo.lcgAvailable and "|cff00ff88ok|r" or "|cffff0000missing|r")
        glowMod.line2 = "idle loop gating: enabled"
    end
    stats["glows"] = glowMod

    -- Automation Module
    local autoMod = {
        name = "automation",
        status = "|cff00ff88active|r",
        line1 = "auto-release: off • auto-role: off",
        line2 = "auto-sign: off • skip cine: off",
    }
    if sfui.automation_debug_info then
        local a = sfui.automation_debug_info()
        autoMod.line1 = string_format("auto-release: %s • auto-role: %s", a.autoRelease and "|cff00ff88on|r" or "off", a.autoRoleCheck and "|cff00ff88on|r" or "off")
        autoMod.line2 = string_format("auto-sign: %s • skip cine: %s", a.autoSignLfg and "|cff00ff88on|r" or "off", a.skipCinematics and "|cff00ff88on|r" or "off")
    end
    stats["automation"] = autoMod

    -- Cursor Ring Module
    local curMod = {
        name = "cursor ring",
        status = "|cff888888disabled|r",
        line1 = "frame: none",
        line2 = "scale: 1.0",
    }
    if sfui.cursor_debug_info then
        local cur = sfui.cursor_debug_info()
        curMod.status = cur.enabled and "|cff00ff88enabled|r" or "|cff888888disabled|r"
        curMod.line1 = string_format("frame: %s (shown: %s)", cur.frameCreated and "ready" or "none", cur.frameShown and "yes" or "no")
        curMod.line2 = "scale cache: cached uiparent"
    end
    stats["cursor"] = curMod

    -- Vehicle Module
    local vehMod = {
        name = "vehicle action bar",
        status = "|cff888888idle|r",
        line1 = "frame: ready • btns: 0",
        line2 = "health: off • power: off • cast: off",
    }
    if sfui.vehicle_debug_info then
        local v = sfui.vehicle_debug_info()
        vehMod.status = v.frameShown and "|cff00ff88active|r" or "|cff888888idle|r"
        vehMod.line1 = string_format("frame: %s • btns: %d • unit: %s", v.frameCreated and "ready" or "none", v.visibleButtons or 0, v.currentUnit or "none")
        vehMod.line2 = string_format("health: %s • power: %s • cast: %s", v.healthShown and "|cff00ff88on|r" or "off", v.powerShown and "|cff00ff88on|r" or "off", v.castShown and "|cff00ff88on|r" or "off")
    end
    stats["vehicle"] = vehMod

    -- Currency Transfer Module
    local transMod = {
        name = "currency transfer",
        status = "|cff888888idle|r",
        line1 = "queue: 0 tasks",
        line2 = "ticker: inactive",
    }
    if sfui.transfer_debug_info then
        local t = sfui.transfer_debug_info()
        transMod.status = t.active and "|cff00ff88active|r" or "|cff888888idle|r"
        transMod.line1 = string_format("scan queue: %d tasks", t.queueSize or 0)
        transMod.line2 = string_format("ticker: %s", t.active and "|cff00ff88processing|r" or "inactive")
    end
    stats["transfer"] = transMod

    return stats
end

-- ---------------------------------------------------------------------------
-- 2. REAL-TIME ALLOCATION WATCHER BACKEND
-- ---------------------------------------------------------------------------
local watcherActive = false
local watcherTimer = nil
local watcherData = {}
local watcherStartTime = 0
local watcherDuration = 10
local watcherStartAddonMem = 0
local watcherStartLuaMem = 0
local watcherLastReport = nil

local function RecordAllocation(sourceName, kbDelta)
    if not watcherActive then return end
    local rec = watcherData[sourceName]
    if not rec then
        rec = { count = 0, totalKB = 0, maxKB = 0 }
        watcherData[sourceName] = rec
    end
    rec.count = rec.count + 1
    if kbDelta > 0 then
        rec.totalKB = rec.totalKB + kbDelta
        if kbDelta > rec.maxKB then
            rec.maxKB = kbDelta
        end
    end
end
sfui.mem.RecordAllocation = RecordAllocation

local function StopWatcher()
    if not watcherActive then return end
    watcherActive = false
    if watcherTimer then
        watcherTimer:Cancel()
        watcherTimer = nil
    end

    local duration = GetTime() - watcherStartTime
    UpdateAddOnMemoryUsage()
    local endAddonMem = GetAddOnMemoryUsage("sfui")
    local endLuaMem = collectgarbage("count")

    local addonDelta = endAddonMem - watcherStartAddonMem
    local luaDelta = endLuaMem - watcherStartLuaMem
    local addonRate = duration > 0 and (addonDelta / duration) or 0

    local list = {}
    for name, data in pairs(watcherData) do
        table_insert(list, { name = name, count = data.count, totalKB = data.totalKB, maxKB = data.maxKB })
    end

    table_sort(list, function(a, b)
        if a.totalKB ~= b.totalKB then
            return a.totalKB > b.totalKB
        end
        return a.count > b.count
    end)

    watcherLastReport = {
        duration = duration,
        addonDelta = addonDelta,
        luaDelta = luaDelta,
        addonRate = addonRate,
        list = list,
        timestamp = GetTime()
    }

    if sfui.mem.gui and sfui.mem.gui:IsShown() then
        sfui.mem.UpdateGUI()
        if sfui.mem.SelectTab then
            sfui.mem.SelectTab("profiler")
        end
    end

    print(" ")
    print(PREFIX .. "|cffffffff========================================|r")
    print(PREFIX .. string_format("|cff00ffffallocation profiling report (%d seconds)|r", math_floor(duration + 0.5)))
    print(PREFIX .. string_format("addon delta: |cffffffff%s|r (rate: |cff%s%.2f kb/s|r)",
        FormatKB(addonDelta),
        addonRate > 10 and "ff4444" or (addonRate > 1 and "ffaa00" or "00ff88"),
        addonRate
    ))
    print(PREFIX .. string_format("lua memory delta: |cffffffff%s|r", FormatKB(luaDelta)))
    print(PREFIX .. "|cffffffff----------------------------------------|r")

    if #list == 0 then
        print(PREFIX .. "|cff00ff88zero events / updates recorded during sample! perfectly idle.|r")
    else
        print(PREFIX .. "|cff00fffftop dispatched events & allocation leaderboard:|r")
        local count = 0
        for _, item in ipairs(list) do
            count = count + 1
            if count <= 10 then
                local color = "00ff88"
                if item.totalKB > 50 then color = "ff4444"
                elseif item.totalKB > 5 then color = "ffaa00"
                elseif item.totalKB > 0 then color = "ffffaa" end

                print(string_format("  #%d |cffffffff%s|r: |cff%s%s|r (|cffaaaaaa%d calls|r, max: %.1f kb)",
                    count, item.name:lower(), color, FormatKB(item.totalKB), item.count, item.maxKB
                ))
            end
        end
    end
    print(PREFIX .. "|cffffffff========================================|r")
    print(" ")
end
sfui.mem.StopWatcher = StopWatcher

function sfui.mem.StartWatcher(duration)
    if watcherActive then
        StopWatcher()
        return
    end

    duration = tonumber(duration) or 10
    if duration < 3 then duration = 3 end
    if duration > 120 then duration = 120 end
    watcherDuration = duration

    wipe(watcherData)
    UpdateAddOnMemoryUsage()
    watcherStartAddonMem = GetAddOnMemoryUsage("sfui")
    watcherStartLuaMem = collectgarbage("count")
    watcherStartTime = GetTime()
    watcherActive = true

    print(PREFIX .. string_format("|cff00ff88starting memory allocation watcher for %d seconds...|r", duration))

    watcherTimer = C_Timer.NewTimer(duration, StopWatcher)

    if sfui.mem.gui and sfui.mem.gui:IsShown() then
        sfui.mem.UpdateGUI()
    end
end

function sfui.mem.IsWatcherActive()
    return watcherActive
end

-- ---------------------------------------------------------------------------
-- 3. FORCED GARBAGE COLLECTION
-- ---------------------------------------------------------------------------
function sfui.mem.RunGC()
    UpdateAddOnMemoryUsage()
    local beforeAddon = GetAddOnMemoryUsage("sfui")
    local beforeLua = collectgarbage("count")

    collectgarbage("collect")

    UpdateAddOnMemoryUsage()
    local afterAddon = GetAddOnMemoryUsage("sfui")
    local afterLua = collectgarbage("count")

    local freedAddon = math_max(0, beforeAddon - afterAddon)
    local freedLua = math_max(0, beforeLua - afterLua)

    local msg = string_format("freed %s (addon: %s -> %s)", FormatKB(freedAddon), FormatKB(beforeAddon), FormatKB(afterAddon))
    print(PREFIX .. "|cff00ff88" .. msg .. "|r")

    if sfui.mem.gui and sfui.mem.gui:IsShown() then
        if sfui.mem.gui.actionStatusText then
            sfui.mem.gui.actionStatusText:SetText("|cff00ff88" .. msg .. "|r")
        end
        sfui.mem.UpdateGUI()
    end
end

-- ---------------------------------------------------------------------------
-- 4. SLEEK, FLAT & MINIMALIST MEMORY GUI (All Lowercase)
-- ---------------------------------------------------------------------------
local frame
local moduleCards = {}
local leaderboardRows = {}
local activeTab = "modules"

local MODULE_ORDER = {
    "quests", "mythic", "trackedbars", "trackedicons", "bars",
    "wqs", "gear", "stats", "alts", "merchant",
    "portals", "castbars", "minimap", "glows", "automation",
    "cursor", "vehicle", "transfer"
}

function sfui.mem.create_mem_panel()
    if frame then return frame end

    local CreateFlatButton = common.create_flat_button
    local FRAME_W, FRAME_H = 650, 460

    frame = CreateFrame("Frame", "sfui_mem_frame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    -- Flat minimalist backdrop without outer border
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        tile = true,
        tileSize = 32,
    })
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.94)
    frame:Hide()
    table_insert(UISpecialFrames, "sfui_mem_frame")

    -- Header Title (Lowercase)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
    title:SetPoint("TOPLEFT", 12, -8)
    title:SetText("|cff6600ffsfui|r  |cffffffffmemory & diagnostics|r")

    -- Close Button
    local close_btn = CreateFlatButton(frame, "✕", 20, 20)
    close_btn:SetPoint("TOPRIGHT", -6, -6)
    close_btn:SetScript("OnClick", function() frame:Hide() end)

    -- -----------------------------------------------------------------------
    -- Row 1: 3 Flat Metric KPI Cards (Lowercase)
    -- -----------------------------------------------------------------------
    local cardW = (FRAME_W - 20 - 12) / 3
    local cardH = 42

    local function CreateKPICard(xOffset, titleText)
        local card = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        card:SetSize(cardW, cardH)
        card:SetPoint("TOPLEFT", 10 + xOffset, -32)
        card:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        card:SetBackdropColor(0.08, 0.08, 0.11, 0.8)
        card:SetBackdropBorderColor(0.18, 0.18, 0.24, 0.7)

        local lbl = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", 8, -5)
        lbl:SetText(titleText:lower())
        lbl:SetTextColor(0.55, 0.55, 0.62, 1)

        local val = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("BOTTOMLEFT", 8, 5)
        val:SetText("--")

        card.valText = val
        return card
    end

    local cardAddon = CreateKPICard(0, "addon memory")
    local cardLua = CreateKPICard(cardW + 6, "lua environment")
    local cardRate = CreateKPICard((cardW + 6) * 2, "allocation rate")
    frame.val_addon = cardAddon.valText
    frame.val_lua = cardLua.valText
    frame.val_rate = cardRate.valText

    -- -----------------------------------------------------------------------
    -- Row 2: Dedicated Button Action Bar (All Lowercase)
    -- -----------------------------------------------------------------------
    local tab_modules = CreateFlatButton(frame, "modules & pools (18)", 135, 22)
    tab_modules:SetPoint("TOPLEFT", 10, -78)

    local tab_profiler = CreateFlatButton(frame, "allocation leaderboard", 135, 22)
    tab_profiler:SetPoint("LEFT", tab_modules, "RIGHT", 4, 0)

    local btn_refresh = CreateFlatButton(frame, "refresh", 60, 22)
    btn_refresh:SetPoint("TOPRIGHT", -10, -78)
    btn_refresh:SetScript("OnClick", function() sfui.mem.UpdateGUI() end)

    local btn_gc = CreateFlatButton(frame, "collect gc", 76, 22)
    btn_gc:SetPoint("RIGHT", btn_refresh, "LEFT", -4, 0)
    btn_gc:SetScript("OnClick", function() sfui.mem.RunGC() end)

    local btn_watch30 = CreateFlatButton(frame, "watch 30s", 70, 22)
    btn_watch30:SetPoint("RIGHT", btn_gc, "LEFT", -4, 0)
    btn_watch30:SetScript("OnClick", function() sfui.mem.StartWatcher(30) end)

    local btn_watch10 = CreateFlatButton(frame, "watch 10s", 70, 22)
    btn_watch10:SetPoint("RIGHT", btn_watch30, "LEFT", -4, 0)
    btn_watch10:SetScript("OnClick", function() sfui.mem.StartWatcher(10) end)

    -- -----------------------------------------------------------------------
    -- Row 3: Dedicated Full-Width Status Bar (Unobstructed Room for GC & Profiler Logs)
    -- -----------------------------------------------------------------------
    local statusBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    statusBar:SetPoint("TOPLEFT", 10, -104)
    statusBar:SetPoint("TOPRIGHT", -10, -104)
    statusBar:SetHeight(20)
    statusBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    statusBar:SetBackdropColor(0.06, 0.06, 0.09, 0.85)
    statusBar:SetBackdropBorderColor(0.16, 0.16, 0.22, 0.6)

    local statusPrefix = statusBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusPrefix:SetPoint("LEFT", 8, 0)
    statusPrefix:SetText("status:")
    statusPrefix:SetTextColor(0.55, 0.55, 0.62, 1)

    local actionStatus = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    actionStatus:SetPoint("LEFT", statusPrefix, "RIGHT", 6, 0)
    actionStatus:SetPoint("RIGHT", -8, 0)
    actionStatus:SetJustifyH("LEFT")
    actionStatus:SetText("|cff00ff88ready|r")
    frame.actionStatusText = actionStatus

    -- -----------------------------------------------------------------------
    -- Row 4: Main Content Area (Flat Cards Grid & Flat Table)
    -- -----------------------------------------------------------------------
    local contentBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    contentBox:SetPoint("TOPLEFT", 10, -128)
    contentBox:SetPoint("BOTTOMRIGHT", -10, 10)
    contentBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    contentBox:SetBackdropColor(0.06, 0.06, 0.08, 0.85)
    contentBox:SetBackdropBorderColor(0.14, 0.14, 0.18, 0.7)

    -- -----------------------------------------------------------------------
    -- View 1: Modules Grid (2 Columns, Clean Compact Cards)
    -- -----------------------------------------------------------------------
    local modScroll = CreateFrame("ScrollFrame", "SfuiMemScroll", contentBox, "UIPanelScrollFrameTemplate")
    modScroll:SetPoint("TOPLEFT", 4, -4)
    modScroll:SetPoint("BOTTOMRIGHT", -22, 4)

    local modChild = CreateFrame("Frame", nil, modScroll)
    local cardGridW = FRAME_W - 48
    modChild:SetSize(cardGridW, 600)
    modScroll:SetScrollChild(modChild)
    contentBox.modView = modScroll

    local cardW = (cardGridW - 6) / 2
    local cardH = 58

    for idx, key in ipairs(MODULE_ORDER) do
        local card = CreateFrame("Frame", nil, modChild, "BackdropTemplate")
        local col = (idx - 1) % 2
        local row = math_floor((idx - 1) / 2)
        card:SetSize(cardW, cardH)
        card:SetPoint("TOPLEFT", col * (cardW + 6), -row * (cardH + 4))
        card:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        card:SetBackdropColor(0.09, 0.09, 0.12, 0.7)
        card:SetBackdropBorderColor(0.18, 0.18, 0.22, 0.6)

        card.title = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.title:SetPoint("TOPLEFT", 6, -4)

        card.status = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        card.status:SetPoint("TOPRIGHT", -6, -4)

        card.line1 = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        card.line1:SetPoint("TOPLEFT", 6, -20)
        card.line1:SetTextColor(0.8, 0.8, 0.85, 1)

        card.line2 = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        card.line2:SetPoint("TOPLEFT", 6, -36)
        card.line2:SetTextColor(0.55, 0.55, 0.6, 1)

        moduleCards[key] = card
    end
    modChild:SetHeight(math_ceil(#MODULE_ORDER / 2) * (cardH + 4) + 10)

    -- -----------------------------------------------------------------------
    -- View 2: Leaderboard View (Lowercase Headers)
    -- -----------------------------------------------------------------------
    local lbFrame = CreateFrame("Frame", nil, contentBox)
    lbFrame:SetAllPoints(contentBox)
    lbFrame:Hide()
    contentBox.lbView = lbFrame

    -- Table Header
    local th = CreateFrame("Frame", nil, lbFrame, "BackdropTemplate")
    th:SetPoint("TOPLEFT", 4, -4)
    th:SetPoint("TOPRIGHT", -4, -4)
    th:SetHeight(22)
    th:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    th:SetBackdropColor(0.12, 0.12, 0.16, 0.9)

    local hRank = th:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hRank:SetPoint("LEFT", 8, 0)
    hRank:SetText("#")
    hRank:SetTextColor(0.6, 0.6, 0.65, 1)

    local hSource = th:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hSource:SetPoint("LEFT", 36, 0)
    hSource:SetText("event / update loop")
    hSource:SetTextColor(0.6, 0.6, 0.65, 1)

    local hCalls = th:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hCalls:SetPoint("LEFT", 260, 0)
    hCalls:SetText("calls")
    hCalls:SetTextColor(0.6, 0.6, 0.65, 1)

    local hTotal = th:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hTotal:SetPoint("LEFT", 380, 0)
    hTotal:SetText("total allocated")
    hTotal:SetTextColor(0.6, 0.6, 0.65, 1)

    local hMax = th:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hMax:SetPoint("LEFT", 510, 0)
    hMax:SetText("max spike")
    hMax:SetTextColor(0.6, 0.6, 0.65, 1)

    for i = 1, 12 do
        local row = CreateFrame("Frame", nil, lbFrame, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 4, -28 - ((i - 1) * 22))
        row:SetPoint("TOPRIGHT", -4, -28 - ((i - 1) * 22))
        row:SetHeight(20)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        row:SetBackdropColor(i % 2 == 0 and 0.08 or 0.06, i % 2 == 0 and 0.08 or 0.06, i % 2 == 0 and 0.1 or 0.08, 0.7)

        row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.rank:SetPoint("LEFT", 8, 0)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 36, 0)

        row.calls = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.calls:SetPoint("LEFT", 260, 0)

        row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.total:SetPoint("LEFT", 380, 0)

        row.max = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.max:SetPoint("LEFT", 510, 0)

        leaderboardRows[i] = row
    end

    -- Tab Switching
    local function SelectTab(tabName)
        activeTab = tabName
        if tabName == "modules" then
            contentBox.modView:Show()
            contentBox.lbView:Hide()
            tab_modules:SetBackdropColor(0.4, 0.0, 1.0, 0.9)
            tab_profiler:SetBackdropColor(0.12, 0.12, 0.16, 0.8)
        else
            contentBox.modView:Hide()
            contentBox.lbView:Show()
            tab_profiler:SetBackdropColor(0.4, 0.0, 1.0, 0.9)
            tab_modules:SetBackdropColor(0.12, 0.12, 0.16, 0.8)
        end
        sfui.mem.UpdateGUI()
    end
    sfui.mem.SelectTab = SelectTab

    tab_modules:SetScript("OnClick", function() SelectTab("modules") end)
    tab_profiler:SetScript("OnClick", function() SelectTab("profiler") end)
    SelectTab("modules")

    -- Periodic Refresh (1Hz)
    local refreshTimer = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        refreshTimer = refreshTimer + elapsed
        if refreshTimer >= 1.0 then
            refreshTimer = 0
            sfui.mem.UpdateGUI()
        end
    end)

    frame:SetScript("OnShow", function()
        sfui.mem.UpdateGUI()
    end)

    sfui.mem.gui = frame
    return frame
end

function sfui.mem.UpdateGUI()
    if not frame or not frame:IsShown() then return end

    UpdateAddOnMemoryUsage()
    local addonMem = GetAddOnMemoryUsage("sfui")
    local totalLua = collectgarbage("count")

    local memColor = addonMem < 3072 and "|cff00ff88" or (addonMem < 6144 and "|cffffaa00" or "|cffff4444")
    if frame.val_addon then
        frame.val_addon:SetText(memColor .. FormatKB(addonMem) .. "|r")
    end
    if frame.val_lua then
        frame.val_lua:SetText("|cffffffff" .. FormatKB(totalLua) .. "|r")
    end

    if watcherActive then
        local elapsed = GetTime() - watcherStartTime
        local remain = math_max(0, watcherDuration - elapsed)
        if frame.val_rate then frame.val_rate:SetText(string_format("|cff00ffffprofiling (%ds)...|r", math_ceil(remain))) end
        if frame.actionStatusText then frame.actionStatusText:SetText(string_format("|cff00ffffprofiling in progress (%ds left)...|r", math_ceil(remain))) end
    elseif watcherLastReport then
        local rate = watcherLastReport.addonRate
        local rateColor = rate > 10 and "ff4444" or (rate > 1 and "ffaa00" or "00ff88")
        if frame.val_rate then frame.val_rate:SetText(string_format("|cff%s%.2f kb/s|r", rateColor, rate)) end
        if frame.actionStatusText then frame.actionStatusText:SetText(string_format("|cffaaaaaalast sample: %ds duration|r", math_floor(watcherLastReport.duration + 0.5))) end
    else
        if frame.val_rate then frame.val_rate:SetText("|cff00ff880.00 kb/s|r") end
    end

    -- Update Modules Grid (Lowercase)
    local modStats = sfui.mem.GetModuleStats()
    for _, key in ipairs(MODULE_ORDER) do
        local card = moduleCards[key]
        local data = modStats[key]
        if card and data then
            card.title:SetText("|cff00ffff" .. key .. "|r " .. (data.name and data.name:lower() or ""))
            card.status:SetText(data.status or "")
            card.line1:SetText(data.line1 or "")
            card.line2:SetText(data.line2 or "")
        end
    end

    -- Update Leaderboard (Lowercase)
    local list = watcherLastReport and watcherLastReport.list or {}
    for i = 1, 12 do
        local row = leaderboardRows[i]
        local item = list[i]
        if item then
            row.rank:SetText("#" .. i)
            row.name:SetText(item.name and item.name:lower() or "")
            row.calls:SetText(string_format("%d", item.count))

            local color = "00ff88"
            if item.totalKB > 50 then color = "ff4444"
            elseif item.totalKB > 5 then color = "ffaa00"
            elseif item.totalKB > 0 then color = "ffffaa" end

            row.total:SetText(string_format("|cff%s%s|r", color, FormatKB(item.totalKB)))
            row.max:SetText(string_format("%.1f kb", item.maxKB))
            row:Show()
        else
            row:Hide()
        end
    end
end

function sfui.mem.ToggleGUI()
    local f = sfui.mem.create_mem_panel()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

-- ---------------------------------------------------------------------------
-- 5. SLASH COMMAND HANDLER
-- ---------------------------------------------------------------------------
SLASH_SFMEM1 = "/sfmem"
SlashCmdList["SFMEM"] = function(msg)
    local clean = msg and _G.strtrim and _G.strtrim(msg):lower() or (msg and msg:lower() or "")
    local cmd, arg = clean:match("^(%S+)%s*(.*)$")
    cmd = cmd or clean

    if cmd == "gc" or cmd == "clean" or cmd == "collect" then
        sfui.mem.RunGC()
    elseif cmd == "watch" or cmd == "profile" or cmd == "trace" then
        sfui.mem.StartWatcher(arg)
        local f = sfui.mem.create_mem_panel()
        f:Show()
        if sfui.mem.SelectTab then sfui.mem.SelectTab("profiler") end
    elseif cmd == "stop" then
        if watcherActive then StopWatcher() else print(PREFIX .. "watcher is not running.") end
    elseif cmd == "print" or cmd == "dump" then
        UpdateAddOnMemoryUsage()
        local addonMem = GetAddOnMemoryUsage("sfui")
        local totalLuaMem = collectgarbage("count")
        print(" ")
        print(PREFIX .. "|cffffffff========================================|r")
        print(PREFIX .. string_format("|cff00ffffaddon total memory:|r |cffffffff%s|r", FormatKB(addonMem)))
        print(PREFIX .. string_format("|cffaaaaaatotal lua environment:|r |cffffffff%s|r", FormatKB(totalLuaMem)))
        print(PREFIX .. "|cffffffff----------------------------------------|r")
        local modStats = sfui.mem.GetModuleStats()
        for _, key in ipairs(MODULE_ORDER) do
            local info = modStats[key]
            if info then
                print(string_format("|cff6600ff[%s]|r |cffffffff%s|r (%s)", key, info.name and info.name:lower() or "", info.status or ""))
                if info.line1 then print("   |cff888888•|r " .. info.line1) end
                if info.line2 then print("   |cff888888•|r " .. info.line2) end
            end
        end
        print(PREFIX .. "|cffffffff========================================|r")
        print(" ")
    else
        sfui.mem.ToggleGUI()
    end
end
