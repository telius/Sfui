-- common.lua for sfui
-- author: teli
-- This file will hold shared functions to reduce code duplication.

sfui.common = {}

local primaryResourcesCache = {
    DEATHKNIGHT = Enum.PowerType.RunicPower,
    DEMONHUNTER = Enum.PowerType.Fury,
    DRUID = {[0]=Enum.PowerType.Mana,[1]=Enum.PowerType.Energy,[5]=Enum.PowerType.Rage,[27]=Enum.PowerType.Mana,[31]=Enum.PowerType.LunarPower},
    EVOKER = Enum.PowerType.Mana,
    HUNTER = Enum.PowerType.Focus,
    MAGE = Enum.PowerType.Mana,
    MONK = {[268]=Enum.PowerType.Energy,[270]=Enum.PowerType.Energy,[269]=Enum.PowerType.Mana},
    PALADIN = Enum.PowerType.Mana,
    PRIEST = {[256]=Enum.PowerType.Mana,[257]=Enum.PowerType.Mana,[258]=Enum.PowerType.Insanity},
    ROGUE = Enum.PowerType.Energy,
    SHAMAN = {[262]=Enum.PowerType.Maelstrom,[263]=Enum.PowerType.Mana,[264]=Enum.PowerType.Mana},
    WARLOCK = Enum.PowerType.Mana,
    WARRIOR = Enum.PowerType.Rage
}

local secondaryResourcesCache = {
    DEATHKNIGHT = Enum.PowerType.Runes,
    DEMONHUNTER = nil,
    DRUID = {[1]=Enum.PowerType.ComboPoints,[31]=Enum.PowerType.Mana},
    EVOKER = Enum.PowerType.Essence,
    HUNTER = nil,
    MAGE = {[62]=Enum.PowerType.ArcaneCharges},
    MONK = {[268]="STAGGER",[269]=Enum.PowerType.Chi,[270]=nil},
    PALADIN = Enum.PowerType.HolyPower,
    PRIEST = {[258]=Enum.PowerType.Mana},
    ROGUE = Enum.PowerType.ComboPoints,
    SHAMAN = {[262]=Enum.PowerType.Mana},
    WARLOCK = Enum.PowerType.SoulShards,
    WARRIOR = nil
}

local resourceColorsCache = {
    ["STAGGER"] = {r=1,g=0.5,b=0},
    ["SOUL_SHARDS"] = {r=0.58,g=0.51,b=0.79},
    ["RUNES"] = {r=0.77,g=0.12,b=0.23},
    ["ESSENCE"] = {r=0.20,g=0.58,b=0.50},
    ["COMBO_POINTS"] = {r=1.00,g=0.96,b=0.41},
    ["CHI"] = {r=0.00,g=1.00,b=0.59},
    ["HOLY_POWER"] = {r=0.96,g=0.91,b=0.55},
    ["ARCANE_CHARGES"] = {r=0.6,g=0.8,b=1.0},
}


function sfui.common.update_widget_bar(widget_frame, icons_pool, labels_pool, source_data, get_details_func)
    if not widget_frame then return end
    local cfg = sfui.config.widget_bar
    local last_icon = nil
    local i = 1
    for _, itemID in ipairs(source_data) do
        local details = get_details_func(itemID)
        if details then
            local icon = icons_pool[i]
            if not icon then
                icon = CreateFrame("Button", nil, widget_frame)
                icon:SetSize(cfg.icon_size, cfg.icon_size)
                local texture = icon:CreateTexture(nil, "ARTWORK")
                texture:SetAllPoints(icon)
                icon.texture = texture
                icon:SetScript("OnEnter", details.on_enter)
                icon:SetScript("OnLeave", details.on_leave)
                icon:SetScript("OnMouseUp", details.on_mouseup)
                icons_pool[i] = icon
            end
            local label = labels_pool[i]
            if not label then
                label = widget_frame:CreateFontString(nil, "OVERLAY", sfui.config.font_small)
                label:SetPoint("TOP", icon, "BOTTOM", 0, cfg.label_offset_y)
                label:SetTextColor(cfg.label_color[1], cfg.label_color[2], cfg.label_color[3])
                labels_pool[i] = label
            end
            icon.id = itemID
            icon.texture:SetTexture(details.texture or sfui.config.textures.gold_icon)
            label:SetText(details.quantity)
            if i == 1 then
                icon:SetPoint("TOPLEFT", 5, -5)
            elseif last_icon then
                icon:SetPoint("TOPLEFT", last_icon, "TOPRIGHT", cfg.icon_spacing, 0)
            end
            icon:Show()
            label:Show()
            last_icon = icon
            i = i + 1
        end
    end
    for j = i, #icons_pool do icons_pool[j]:Hide() end
    for j = i, #labels_pool do labels_pool[j]:Hide() end
    if last_icon then
        local left = widget_frame:GetLeft()
        if left then
            widget_frame:SetWidth(last_icon:GetRight() - left + 5)
        end
        if CharacterFrame:IsShown() then widget_frame:Show() end
    else
        widget_frame:Hide()
    end
end

function sfui.common.GetPrimaryResource()
    local playerClass = select(2, UnitClass("player"))
    local spec = C_SpecializationInfo.GetSpecialization()
    local specID
    if spec then
        specID = select(1, C_SpecializationInfo.GetSpecializationInfo(spec))
    else
        specID = 0
    end
    if playerClass == "DRUID" then return primaryResourcesCache[playerClass][GetShapeshiftFormID() or 0] end
    if type(primaryResourcesCache[playerClass]) == "table" then return primaryResourcesCache[playerClass][specID] else return primaryResourcesCache[playerClass] end
end

function sfui.common.GetSecondaryResource()
    local playerClass = select(2, UnitClass("player"))
    local spec = C_SpecializationInfo.GetSpecialization()
    local specID
    if spec then
        specID = select(1, C_SpecializationInfo.GetSpecializationInfo(spec))
    else
        specID = 0
    end
    if playerClass == "DRUID" then return secondaryResourcesCache[playerClass][GetShapeshiftFormID() or 0] end
    if type(secondaryResourcesCache[playerClass]) == "table" then return secondaryResourcesCache[playerClass][specID] else return secondaryResourcesCache[playerClass] end
end

function sfui.common.GetClassOrSpecColor()
    local color
    local spec = C_SpecializationInfo.GetSpecialization()
    local specID
    if spec then
        specID = select(1, C_SpecializationInfo.GetSpecializationInfo(spec))
    end
    if specID and sfui.config.spec_colors[specID] then
        local custom_color = sfui.config.spec_colors[specID]
        color = { r = custom_color[1], g = custom_color[2], b = custom_color[3] }
    end
    return color
end

function sfui.common.CreateBar(name, frameType, parent, template)
    local cfg = sfui.config[name]
    local backdrop = CreateFrame("Frame", "sfui_"..name.."_Backdrop", parent, "BackdropTemplate")
    backdrop:SetFrameStrata("MEDIUM")
    backdrop:SetSize(cfg.width + cfg.backdrop.padding * 2, cfg.height + cfg.backdrop.padding * 2)
    backdrop:SetBackdrop({
        bgFile = sfui.config.textures.white,
        tile = true,
        tileSize = 32,
    })
    backdrop:SetBackdropColor(cfg.backdrop.color[1], cfg.backdrop.color[2], cfg.backdrop.color[3], cfg.backdrop.color[4])
    local bar = CreateFrame(frameType, "sfui_"..name, backdrop, template)
    bar:SetSize(cfg.width, cfg.height)
    bar:SetPoint("CENTER")
    if bar.SetStatusBarTexture then
        bar:SetStatusBarTexture(SfuiDB.barTexture)
    end
    bar.backdrop = backdrop
    bar.fadeInAnim, bar.fadeOutAnim = sfui.common.CreateFadeAnimations(backdrop)
    return bar
end

function sfui.common.CreateFadeAnimations(frame)
    local fadeInGroup = frame:CreateAnimationGroup()
    local fadeIn = fadeInGroup:CreateAnimation("Alpha")
    fadeIn:SetDuration(0.5)
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetScript("OnPlay", function() frame:Show() end)
    local fadeOutGroup = frame:CreateAnimationGroup()
    local fadeOut = fadeOutGroup:CreateAnimation("Alpha")
    fadeOut:SetDuration(0.5)
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetScript("OnFinished", function() frame:Hide() end)
    return fadeInGroup, fadeOutGroup
end

function sfui.common.GetResourceColor(resource)
    local colorInfo = GetPowerBarColor(resource)
    if colorInfo then return colorInfo end
    local powerName = ""
    if type(resource) == "number" then
        for name, value in pairs(Enum.PowerType) do
            if value == resource then
                powerName = name
                break
            end
        end
    end
    return resourceColorsCache[powerName] or GetPowerBarColor("MANA")
end