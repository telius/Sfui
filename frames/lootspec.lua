local addonName, addon = ...
---@diagnostic disable: undefined-global, undefined-field
sfui = sfui or {}
sfui.lootspec = {}

-- ─── Localized APIs ──────────────────────────────────────────────────────────
local CreateFrame               = CreateFrame
local UIParent                  = UIParent
local GameTooltip               = GameTooltip
local GetNumSpecializations     = GetNumSpecializations
local GetSpecializationInfo     = GetSpecializationInfo
local GetSpecializationInfoByID = GetSpecializationInfoByID
local GetLootSpecialization     = GetLootSpecialization
local SetLootSpecialization     = SetLootSpecialization
local C_ChallengeMode           = C_ChallengeMode
local table                     = table
local math                      = math
local string                    = string
-- NOTE: EJ_* globals are NOT localized — they live in Blizzard_EncounterJournal
-- (lazy addon) and are nil at file-load time. Use them as raw globals in fns.

-- ─── Layout constants ─────────────────────────────────────────────────────────
local ROW_H       = 24
local ICON_SIZE   = 18
local PAD         = 8
local COL_W       = 170   -- spec button width
local FRAME_W     = 560
local HEADER_H    = 82    -- pixels occupied by title/controls/tabs
local FOOTER_H    = 24
local MIN_FRAME_H = 160
local MAX_FRAME_H = 860

-- ─── DB helpers ───────────────────────────────────────────────────────────────
local dbCache = nil
local function DB()
    if dbCache then return dbCache end
    SfuiDB.lootspec = SfuiDB.lootspec or {}
    local db = SfuiDB.lootspec
    db.enabled     = (db.enabled ~= false)
    db.defaultSpec = db.defaultSpec or 0
    db.bosses      = db.bosses   or {}
    db.dungeons    = db.dungeons or {}
    dbCache = db
    return db
end

-- ─── Spec helpers ─────────────────────────────────────────────────────────────
local specsCache = nil
local function BuildSpecList()
    if specsCache then return specsCache end
    specsCache = { { specID = 0, name = "— off —", icon = nil } }
    local n = GetNumSpecializations()
    for i = 1, n do
        local id, name, _, icon = GetSpecializationInfo(i)
        if id then
            table.insert(specsCache, { specID = id, name = name, icon = icon })
        end
    end
    return specsCache
end

local function InvalidateSpecCache() specsCache = nil end

local function SpecName(specID)
    if specID == 0 then return "— off —" end
    local _, name = GetSpecializationInfoByID(specID)
    return name or ("Spec " .. specID)
end

local function SpecIcon(specID)
    if specID == 0 then return nil end
    local _, _, _, icon = GetSpecializationInfoByID(specID)
    return icon
end

local function CycleSpec(currentID)
    local list = BuildSpecList()
    for i, entry in ipairs(list) do
        if entry.specID == currentID then
            return list[(i % #list) + 1].specID
        end
    end
    return list[1].specID
end

-- ─── Auto-swap engine ─────────────────────────────────────────────────────────
local inMPlusSpec = false

local function ApplyLootSpec(specID, reason)
    if specID == nil then return end
    if GetLootSpecialization() == specID then return end
    SetLootSpecialization(specID)
    if reason then
        sfui.common.print(string.format(
            "loot spec → |cff00ffff%s|r (%s)", SpecName(specID), reason))
    end
end

local function RestoreDefault(reason)
    ApplyLootSpec(DB().defaultSpec, reason)
end

-- ─── Events ───────────────────────────────────────────────────────────────────
sfui.events.RegisterEvent("ENCOUNTER_START", function(_, encounterID)
    local db = DB()
    if not db.enabled then return end
    local specID = db.bosses[encounterID]
    if specID and specID ~= 0 then
        ApplyLootSpec(specID, "encounter")
    end
end)

sfui.events.RegisterEvent("LOOT_CLOSED", function()
    local db = DB()
    if not db.enabled then return end
    if not inMPlusSpec then RestoreDefault("loot closed") end
end)

sfui.events.RegisterEvent("CHALLENGE_MODE_START", function()
    local db = DB()
    if not db.enabled then return end
    local mapID = C_ChallengeMode.GetActiveChallengeMapID
        and C_ChallengeMode.GetActiveChallengeMapID()
    if not mapID then return end
    local specID = db.dungeons[mapID]
    if specID and specID ~= 0 then
        inMPlusSpec = true
        ApplyLootSpec(specID, "M+")
    end
end)

sfui.events.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if inMPlusSpec then
        inMPlusSpec = false
        RestoreDefault("left instance")
    end
end)

sfui.events.RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
    InvalidateSpecCache()
    if sfui.lootspec.frame and sfui.lootspec.frame:IsShown() then
        sfui.lootspec.Rebuild()
    end
end)

-- ─── EJ data ──────────────────────────────────────────────────────────────────
local raidDataCache = nil
local function GetRaidData()
    if raidDataCache then return raidDataCache end

    if not EJ_GetInstanceByIndex then
        local loaded, reason = C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
        if not loaded then
            sfui.common.print("|cffff8800lootspec:|r EJ unavailable: " .. tostring(reason))
            return {}
        end
    end
    local raids = {}
    local instIdx = 1
    while true do
        local instanceID, name = EJ_GetInstanceByIndex(instIdx, true)
        if not instanceID then break end
        local raid = { name = name, instanceID = instanceID, bosses = {} }
        EJ_SelectInstance(instanceID)
        local encIdx = 1
        while true do
            -- EJ_GetEncounterInfoByIndex: name, description, bossID, rootSectionID, link
            local encName, _, bossID = EJ_GetEncounterInfoByIndex(encIdx)
            if not bossID or bossID == 0 then break end
            -- EJ_GetCreatureInfo: id, name, description, displayInfo, iconImage, uiModelSceneID
            local _, _, _, _, iconImage = EJ_GetCreatureInfo(1, bossID)
            table.insert(raid.bosses, {
                name        = encName,
                encounterID = bossID,
                icon        = iconImage,
            })
            encIdx = encIdx + 1
        end
        if #raid.bosses > 0 then table.insert(raids, raid) end
        instIdx = instIdx + 1
    end
    raidDataCache = raids
    return raids
end

local dungeonDataCache = nil
local function GetDungeonData()
    if dungeonDataCache then return dungeonDataCache end

    if not EJ_GetInstanceByIndex then C_AddOns.LoadAddOn("Blizzard_EncounterJournal") end

    local nameToInstance = {}
    local instIdx = 1
    while true do
        local instanceID, name = EJ_GetInstanceByIndex(instIdx, false)
        if not instanceID then break end
        nameToInstance[name] = instanceID
        instIdx = instIdx + 1
    end

    local dungeons = {}
    local maps = C_ChallengeMode.GetMapTable()
    if not maps then return dungeons end
    for _, mapID in ipairs(maps) do
        -- GetMapUIInfo returns: name, id, timeLimit, texture, backgroundTexture, mapID
        local name, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
        if name then
            if texture == 0 then texture = nil end
            table.insert(dungeons, {
                mapID = mapID,
                name = name,
                texture = texture,
                instanceID = nameToInstance[name],
            })
        end
    end
    table.sort(dungeons, function(a, b) return a.name < b.name end)
    dungeonDataCache = dungeons
    return dungeons
end

-- ─── Row pool ─────────────────────────────────────────────────────────────────
local rowPool  = {}
local rowCount = 0

local function AcquireRow(parent)
    rowCount = rowCount + 1
    local r = rowPool[rowCount]
    if not r then
        r = CreateFrame("Frame", nil, parent)

        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()

        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(ICON_SIZE, ICON_SIZE)
        r.icon:SetPoint("LEFT", PAD, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        r.nameFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.nameFS:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
        r.nameFS:SetJustifyH("LEFT")
        r.nameFS:SetWordWrap(false)
        r.nameFS:SetTextColor(0.85, 0.85, 0.85, 1)

        r.linkBtn = CreateFrame("Button", nil, r)
        r.linkBtn:SetPoint("TOPLEFT", r.nameFS, "TOPLEFT")
        r.linkBtn:SetPoint("BOTTOMRIGHT", r.nameFS, "BOTTOMRIGHT")
        r.linkBtn:SetScript("OnEnter", function(self)
            if self.encounterID or self.instanceID then
                r.nameFS:SetTextColor(1, 0.82, 0, 1)
            end
        end)
        r.linkBtn:SetScript("OnLeave", function(self)
            r.nameFS:SetTextColor(0.85, 0.85, 0.85, 1)
        end)
        r.linkBtn:SetScript("OnClick", function(self)
            if not C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
                C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
            end
            if EncounterJournal_OpenJournal then
                EncounterJournal_OpenJournal(nil, self.instanceID, self.encounterID)
            end
        end)

        -- Pre-allocate spec button
        local btn = CreateFrame("Button", nil, r, "BackdropTemplate")
        btn:SetSize(COL_W, ROW_H - 4)
        btn:SetPoint("RIGHT", -PAD, 0)
        btn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(0.05, 0.05, 0.05, 1)
        btn:SetBackdropBorderColor(0.13, 0.13, 0.13, 1)

        local specIconTex = btn:CreateTexture(nil, "ARTWORK")
        specIconTex:SetSize(ICON_SIZE - 2, ICON_SIZE - 2)
        specIconTex:SetPoint("LEFT", 3, 0)
        specIconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        btn.iconTex = specIconTex

        local specLbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        specLbl:SetPoint("LEFT", specIconTex, "RIGHT", 4, 0)
        specLbl:SetPoint("RIGHT", -4, 0)
        specLbl:SetJustifyH("LEFT")
        specLbl:SetWordWrap(false)
        btn.lbl = specLbl

        btn.Refresh = function(self)
            if not self.storageKey or not self.keyID then return end
            local store = DB()[self.storageKey]
            local specID = store and store[self.keyID] or 0
            local icon = SpecIcon(specID)
            if icon then specIconTex:SetTexture(icon) specIconTex:Show() else specIconTex:Hide() end

            if specID == 0 then
                specLbl:SetText("— off —")
                specLbl:SetTextColor(0.3, 0.3, 0.3, 1)
                btn:SetBackdropBorderColor(0.1, 0.1, 0.1, 1)
            else
                local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
                local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
                if cc then
                    specLbl:SetTextColor(cc.r, cc.g, cc.b, 1)
                    btn:SetBackdropBorderColor(cc.r * 0.4, cc.g * 0.4, cc.b * 0.4, 1)
                else
                    specLbl:SetTextColor(0.0, 0.8, 1.0, 1)
                    btn:SetBackdropBorderColor(0.0, 0.35, 0.5, 1)
                end
                specLbl:SetText(SpecName(specID))
            end
        end

        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, mouseBtn)
            if not self.storageKey or not self.keyID then return end
            local db = DB()
            db[self.storageKey] = db[self.storageKey] or {}
            local current = db[self.storageKey][self.keyID] or 0
            if mouseBtn == "RightButton" then
                db[self.storageKey][self.keyID] = nil
            else
                db[self.storageKey][self.keyID] = CycleSpec(current)
            end
            self:Refresh()
        end)
        btn:SetScript("OnEnter", function(self)
            if not self.storageKey or not self.keyID then return end
            local store = DB()[self.storageKey]
            local specID = store and store[self.keyID] or 0
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(specID == 0 and "no swap configured" or SpecName(specID))
            GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle spec", 1, 1, 1)
            GameTooltip:AddLine("|cffaaaaaaright-click|r to clear", 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        r.specBtn = btn
        rowPool[rowCount] = r
    end
    r:SetParent(parent)
    r:ClearAllPoints()
    r:Show()
    return r
end

local function ReleaseRows()
    for i = 1, rowCount do
        local r = rowPool[i]
        if r then
            r.linkBtn.encounterID = nil
            r.linkBtn.instanceID = nil
            r:Hide()
            -- do NOT SetParent(nil) — keeps the frame in its pool correctly
            if r.specBtn then r.specBtn:Hide() end
        end
    end
    rowCount = 0
end

-- Pool helpers for non-frame regions (FontStrings, Textures) on the content frame.
-- These can't be destroyed so we create once and reuse.
local function AcquireFontString(pool, parent, layer, fontObj)
    for _, fs in ipairs(pool) do
        if not fs.inUse then
            fs.inUse = true
            fs:Show()
            return fs
        end
    end
    local fs = parent:CreateFontString(nil, layer, fontObj)
    fs.inUse = true
    pool[#pool + 1] = fs
    return fs
end

local function AcquireTexture(pool, parent, layer)
    for _, tx in ipairs(pool) do
        if not tx.inUse then
            tx.inUse = true
            tx:Show()
            return tx
        end
    end
    local tx = parent:CreateTexture(nil, layer)
    tx.inUse = true
    pool[#pool + 1] = tx
    return tx
end

local function ReleaseRegionPool(pool)
    for _, r in ipairs(pool) do
        r.inUse = false
        r:Hide()
    end
end

-- ─── Content builders ─────────────────────────────────────────────────────────
-- Both return the pixel height consumed so the frame can auto-size.

local function BuildRaidContent(content, width)
    -- Init per-content region pools (created once, reused across tab switches)
    content.fsPool  = content.fsPool  or {}
    content.sepPool = content.sepPool or {}

    ReleaseRows()
    ReleaseRegionPool(content.fsPool)
    ReleaseRegionPool(content.sepPool)

    local raids = GetRaidData()
    local nameColW = width - COL_W - PAD * 3 - ICON_SIZE
    local y = -PAD

    -- column headers
    local h1 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h1:ClearAllPoints()
    h1:SetPoint("TOPLEFT", PAD + ICON_SIZE + 5, y)
    h1:SetText("boss")
    h1:SetTextColor(0.45, 0.45, 0.45, 1)

    local h2 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h2:ClearAllPoints()
    h2:SetPoint("TOPRIGHT", -PAD, y)
    h2:SetText("loot spec")
    h2:SetTextColor(0.45, 0.45, 0.45, 1)
    y = y - 18

    if #raids == 0 then
        local msg = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        msg:ClearAllPoints()
        msg:SetPoint("TOPLEFT", PAD, y - 8)
        msg:SetText("no raids found for current tier")
        msg:SetTextColor(0.4, 0.4, 0.4, 1)
        return 60
    end

    for _, raid in ipairs(raids) do
        local sh = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        sh:ClearAllPoints()
        sh:SetPoint("TOPLEFT", PAD, y - 4)
        sh:SetText(raid.name)
        sh:SetTextColor(0.4, 0.0, 1.0, 1)
        y = y - ROW_H - 2

        local sep = AcquireTexture(content.sepPool, content, "ARTWORK")
        sep:SetHeight(1)
        sep:ClearAllPoints()
        sep:SetPoint("TOPLEFT", 0, y + 2)
        sep:SetPoint("TOPRIGHT", 0, y + 2)
        sep:SetColorTexture(0.2, 0.0, 0.5, 0.5)

        for i, boss in ipairs(raid.bosses) do
            local row = AcquireRow(content)
            row:SetSize(width, ROW_H)
            row:SetPoint("TOPLEFT", 0, y)
            row.bg:SetColorTexture(0.05, 0.05, 0.05, (i % 2 == 0) and 0.0 or 0.35)

            if boss.icon then row.icon:SetTexture(boss.icon) row.icon:Show()
            else row.icon:Hide() end

            row.linkBtn.encounterID = boss.encounterID
            row.linkBtn.instanceID = raid.instanceID

            row.nameFS:SetText(boss.name)
            row.nameFS:SetWidth(nameColW)

            row.specBtn.storageKey = "bosses"
            row.specBtn.keyID = boss.encounterID
            row.specBtn:Refresh()
            row.specBtn:Show()

            y = y - ROW_H
        end
        y = y - 8
    end

    return math.abs(y) + PAD
end

local function BuildDungeonContent(content, width)
    content.fsPool  = content.fsPool  or {}
    content.sepPool = content.sepPool or {}

    ReleaseRows()
    ReleaseRegionPool(content.fsPool)
    ReleaseRegionPool(content.sepPool)

    local dungeons = GetDungeonData()
    local nameColW = width - COL_W - PAD * 3 - ICON_SIZE
    local y = -PAD

    local h1 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h1:ClearAllPoints()
    h1:SetPoint("TOPLEFT", PAD + ICON_SIZE + 5, y)
    h1:SetText("dungeon")
    h1:SetTextColor(0.45, 0.45, 0.45, 1)

    local h2 = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormalSmall")
    h2:ClearAllPoints()
    h2:SetPoint("TOPRIGHT", -PAD, y)
    h2:SetText("loot spec")
    h2:SetTextColor(0.45, 0.45, 0.45, 1)
    y = y - 18

    if #dungeons == 0 then
        local msg = AcquireFontString(content.fsPool, content, "OVERLAY", "GameFontNormal")
        msg:ClearAllPoints()
        msg:SetPoint("TOPLEFT", PAD, y - 8)
        msg:SetText("no M+ dungeons found")
        msg:SetTextColor(0.4, 0.4, 0.4, 1)
        return 60
    end

    for i, dung in ipairs(dungeons) do
        local row = AcquireRow(content)
        row:SetSize(width, ROW_H)
        row:SetPoint("TOPLEFT", 0, y)
        row.bg:SetColorTexture(0.05, 0.05, 0.05, (i % 2 == 0) and 0.0 or 0.35)

        if dung.texture then row.icon:SetTexture(dung.texture) row.icon:Show()
        else row.icon:Hide() end

        row.linkBtn.instanceID = dung.instanceID
        row.linkBtn.encounterID = nil

        row.nameFS:SetText(dung.name)
        row.nameFS:SetWidth(nameColW)

        row.specBtn.storageKey = "dungeons"
        row.specBtn.keyID = dung.mapID
        row.specBtn:Refresh()
        row.specBtn:Show()

        y = y - ROW_H
    end

    return math.abs(y) + PAD
end

-- ─── Frame ────────────────────────────────────────────────────────────────────
local frame = nil

function sfui.lootspec.CreateFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "SfuiLootSpecFrame", UIParent, "BackdropTemplate")
    table.insert(UISpecialFrames, "SfuiLootSpecFrame")
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(FRAME_W, 400)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
    frame:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)

    local MkBtn = sfui.common.create_flat_button

    -- row 1: title / close
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("|cff6600ffsfui|r loot spec")

    local closeBtn = MkBtn(frame, "x", 20, 20)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- row 2: default spec label  [spec button]  [auto-swap cb]
    local defLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    defLabel:SetPoint("TOPLEFT", 10, -33)
    defLabel:SetText("default spec:")
    defLabel:SetTextColor(0.5, 0.5, 0.5, 1)

    local defBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    defBtn:SetSize(COL_W, 18)
    defBtn:SetPoint("LEFT", defLabel, "RIGHT", 6, 0)
    defBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    defBtn:SetBackdropColor(0.05, 0.05, 0.05, 1)
    defBtn:SetBackdropBorderColor(0.13, 0.13, 0.13, 1)
    local defIcon = defBtn:CreateTexture(nil, "ARTWORK")
    defIcon:SetSize(14, 14)
    defIcon:SetPoint("LEFT", 3, 0)
    defIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local defLbl = defBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    defLbl:SetPoint("LEFT", defIcon, "RIGHT", 4, 0)
    defLbl:SetJustifyH("LEFT")

    local function RefreshDefBtn()
        local specID = DB().defaultSpec or 0
        if specID == 0 then
            defIcon:Hide()
            defLbl:SetText("current spec")
            defLbl:SetTextColor(0.35, 0.35, 0.35, 1)
        else
            local icon = SpecIcon(specID)
            if icon then defIcon:SetTexture(icon) defIcon:Show() else defIcon:Hide() end
            defLbl:SetText(SpecName(specID))
            defLbl:SetTextColor(0.0, 0.8, 1.0, 1)
        end
    end
    defBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    defBtn:SetScript("OnClick", function(_, btn)
        local db = DB()
        db.defaultSpec = (btn == "RightButton") and 0 or CycleSpec(db.defaultSpec or 0)
        RefreshDefBtn()
    end)
    defBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("spec restored after boss loot")
        GameTooltip:AddLine("|cffaaaaaaleft-click|r to cycle", 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaright-click|r to reset", 1, 1, 1)
        GameTooltip:Show()
    end)
    defBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- inline auto-swap checkbox
    local enableCB = sfui.common.create_checkbox(frame, "auto-swap",
        function() return DB().enabled end,
        function(val) DB().enabled = val end,
        "enable/disable automatic loot spec swaps")
    enableCB:SetSize(14, 14)
    enableCB:SetPoint("LEFT", defBtn, "RIGHT", 14, 0)
    -- label already set by create_checkbox; just ensure font is small
    if enableCB.text then
        enableCB.text:SetFontObject("GameFontNormalSmall")
        enableCB.text:SetTextColor(0.5, 0.5, 0.5, 1)
    end

    -- row 3: tabs
    local TAB_Y    = -57
    local tabRaid  = MkBtn(frame, "raids",    68, 20)
    local tabDung  = MkBtn(frame, "dungeons", 68, 20)
    tabRaid:SetPoint("TOPLEFT", 10, TAB_Y)
    tabDung:SetPoint("LEFT", tabRaid, "RIGHT", 4, 0)

    -- subtle separator under tabs
    local sepTex = frame:CreateTexture(nil, "ARTWORK")
    sepTex:SetHeight(1)
    sepTex:SetPoint("TOPLEFT",  0, TAB_Y - 24)
    sepTex:SetPoint("TOPRIGHT", 0, TAB_Y - 24)
    sepTex:SetColorTexture(0.2, 0.0, 0.5, 0.5)

    -- content area — no scrollframe; resized dynamically
    local CONTENT_Y = TAB_Y - 28
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT",  0, CONTENT_Y)
    content:SetPoint("TOPRIGHT", 0, CONTENT_Y)
    content:SetHeight(1)
    frame.content = content

    -- footer hint
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", 10, 8)
    hint:SetText("left-click to cycle spec  ·  right-click to clear")
    hint:SetTextColor(0.28, 0.28, 0.28, 1)

    -- auto-size helper
    local function FitFrame(contentH)
        contentH = math.max(contentH, 1)
        content:SetHeight(contentH)
        local total = math.max(MIN_FRAME_H, math.min(MAX_FRAME_H, HEADER_H + contentH + FOOTER_H))
        frame:SetHeight(total)
    end

    -- tab switching
    local activeTab = "raids"

    local function SetActiveTab(tab)
        activeTab = tab

        -- clean up previous content
        -- Rows are hidden via ReleaseRows() inside BuildXContent.
        -- We must NOT call SetParent(nil) on content children — that permanently
        -- orphans pooled frames. Only hide orphaned non-pool children.
        for i = content:GetNumChildren(), 1, -1 do
            local c = select(i, content:GetChildren())
            -- Only orphan frames we don't own in our pool
            if c and c ~= rowPool[1] then -- skip pool frames
                local inPool = false
                for _, pr in ipairs(rowPool) do
                    if c == pr then inPool = true; break end
                end
                if not inPool then c:Hide() end
            end
        end
        -- FontStrings and Textures are released via ReleaseRegionPool inside BuildXContent.

        if tab == "raids" then
            tabRaid:SetBackdropColor(0.14, 0.0, 0.38, 1)
            tabRaid:SetBackdropBorderColor(0.4, 0.0, 1.0, 1)
            tabDung:SetBackdropColor(0.0, 0.0, 0.0, 1)
            tabDung:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
            FitFrame(BuildRaidContent(content, FRAME_W - 10))
        else
            tabDung:SetBackdropColor(0.14, 0.0, 0.38, 1)
            tabDung:SetBackdropBorderColor(0.4, 0.0, 1.0, 1)
            tabRaid:SetBackdropColor(0.0, 0.0, 0.0, 1)
            tabRaid:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
            FitFrame(BuildDungeonContent(content, FRAME_W - 10))
        end
    end

    tabRaid:SetScript("OnClick", function() SetActiveTab("raids") end)
    tabDung:SetScript("OnClick", function() SetActiveTab("dungeons") end)

    frame:SetScript("OnShow", function()
        RefreshDefBtn()
        SetActiveTab(activeTab)
    end)

    function sfui.lootspec.Rebuild()
        if frame and frame:IsShown() then
            RefreshDefBtn()
            local t = activeTab; activeTab = nil
            SetActiveTab(t)
        end
    end

    frame:Hide()
    sfui.lootspec.frame = frame
    return frame
end

-- ─── Toggle / Initialize ──────────────────────────────────────────────────────
function sfui.lootspec.Toggle()
    if not frame then frame = sfui.lootspec.CreateFrame() end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function sfui.lootspec.initialize()
    -- DB schema initialized lazily via DB() on first access
end
