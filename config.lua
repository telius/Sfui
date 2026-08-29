local addonName, addon = ...
sfui = sfui or {}
SfuiDB = SfuiDB or {}
SfuiDecorDB = SfuiDecorDB or {}

sfui.config = {
    -- addon metadata
    title = "|cff6600FFSTF|rui |cff6600FFGFY|r edition",
    version = "0.0.0", -- Set dynamically from TOC during ADDON_LOADED
    prefix = "|cff6600ffsfui:|r",

    -- general appearance
    font = "GameFontNormal",
    font_small = "GameFontNormalSmall",
    font_large = "GameFontNormalLarge",
    font_highlight = "GameFontHighlight",
    header_color = { 1, 1, 1 },
    throttle = {
        health = 0.05,
        power = 0.05,
        absorb = 0.1,
        visibility = 0.1,
    },
    textures = {
        white = "Interface/Buttons/WHITE8X8",
        tooltip = "Interface/Tooltips/UI-Tooltip-Background",
        gold_icon = "Interface\\MoneyFrame\\UI-GoldIcon",
    },

    -- addon-wide color palette
    colors = {
        purple = { 0.4, 0, 1 }, -- #6600FF (Highlight Color)
        cyan = { 0, 1, 1 },     -- #00FFFF (Text Color)
        magenta = { 1, 0, 1 },  -- #FF00FF
        white = { 1, 1, 1 },
        black = { 0, 0, 0 },
        gray = { 0.2, 0.2, 0.2 }, -- Dark gray for borders
    },

    appearance = {
        highlightColor = { 0.4, 0.0, 1.0, 1 }, -- #6600FF
        accentColor = { 0, 1, 1, 1 },          -- #00FFFF
        white = { 1, 1, 1, 1 },
        backdropColor = { 0.05, 0.05, 0.05, 0.8 },
        widgetBackdropColor = { 0.2, 0.2, 0.2, 1 }, -- For checkboxes/buttons
        editBoxColor = { 0.15, 0.15, 0.15, 1 },
        sliderBackdropColor = { 0.1, 0.1, 0.1, 1 },
        lockColor = { 0.5, 0, 0, 0.5 },
        errorColor = { 1, 0.2, 0.2, 1 },
        goldColor = { 1, 0.82, 0, 1 },
        dimTextColor = { 0.6, 0.6, 0.6, 1 },
        addonIcon = "Interface/AddOns/sfui/icon.png",
    },

    -- shared settings for icon bars
    widget_bar = {
        icon_size = 32,
        icon_spacing = 5,
        label_offset_y = -2,
        label_color = { 1, 1, 1 },
    },

    spec_colors = {
        -- Death Knight
        [250] = { 0.77, 0.12, 0.23, 1 },     -- Blood
        [251] = { 0.0, 1.0, 1.0, 1 },        -- Frost
        [252] = { 0.0, 1.0, 0.0, 1 },        -- Unholy
        -- Demon Hunter
        [577] = { 0.635, 1.0, 0.0, 1 },      -- Havoc
        [581] = { 0.635, 1.0, 0.0, 1 },      -- Vengeance
        [1480] = { 0.788, 0.259, 0.992, 1 }, -- Devourer
        -- Druid
        [102] = { 0.2, 0.0, 0.8, 1 },        -- Balance
        [103] = { 1.00, 0.49, 0.04, 1 },     -- Feral
        [104] = { 1.00, 0.49, 0.04, 1 },     -- Guardian
        [105] = { 0.2, 0.8, 0.2, 1 },        -- Restoration
        -- Evoker
        [1467] = { 0.20, 0.58, 0.50, 1 },    -- Devastation
        [1468] = { 0.20, 0.58, 0.50, 1 },    -- Preservation
        [1473] = { 0.81, 0.54, 0.27, 1 },    -- Augmentation
        -- Hunter
        [253] = { 0.67, 0.83, 0.45, 1 },     -- Beast Mastery
        [254] = { 0.67, 0.83, 0.45, 1 },     -- Marksmanship
        [255] = { 0.67, 0.83, 0.45, 1 },     -- Survival
        -- Mage
        [62] = { 0.25, 0.78, 0.92, 1 },      -- Arcane
        [63] = { 0.25, 0.78, 0.92, 1 },      -- Fire
        [64] = { 0.25, 0.78, 0.92, 1 },      -- Frost
        -- Monk
        [268] = { 0.90, 0.60, 0.15, 1 },     -- Brewmaster
        [269] = { 0.00, 1.00, 0.59, 1 },     -- Mistweaver
        [270] = { 0.00, 1.00, 0.59, 1 },     -- Windwalker
        -- Paladin
        [65] = { 0.96, 0.55, 0.73, 1 },      -- Holy
        [66] = { 1.00, 0.75, 0.20, 1 },      -- Protection
        [70] = { 0.96, 0.55, 0.73, 1 },      -- Retribution
        -- Priest
        [256] = { 1.00, 1.00, 1.00, 1 },     -- Discipline
        [257] = { 1.00, 1.00, 1.00, 1 },     -- Holy
        [258] = { 0.40, 0.00, 1.00, 1 },     -- Shadow
        -- Rogue
        [259] = { 1.00, 0.96, 0.41, 1 },     -- Assassination
        [260] = { 1.00, 0.96, 0.41, 1 },     -- Outlaw
        [261] = { 1.00, 0.96, 0.41, 1 },     -- Subtlety
        -- Shaman
        [262] = { 0.00, 0.44, 0.87, 1 },     -- Elemental
        [263] = { 0.00, 0.44, 0.87, 1 },     -- Enhancement
        [264] = { 0.00, 0.44, 0.87, 1 },     -- Restoration
        -- Warlock
        [265] = { 0.53, 0.53, 0.93, 1 },     -- Affliction
        [266] = { 0.53, 0.53, 0.93, 1 },     -- Demonology
        [267] = { 0.635, 1.0, 0.0, 1 },      -- Destruction
        -- Warrior
        [71] = { 1.00, 0.00, 0.00, 1 },      -- Arms
        [72] = { 1.00, 0.00, 0.00, 1 },      -- Fury
        [73] = { 1.00, 0.00, 0.00, 1 },      -- Protection
    },

    -- Default panel settings for tracked icons
    cooldown_panel_defaults = {
        left = {
            name = "Left",
            anchorPoint = "TOPLEFT",
            growthH = "Right",
            growthV = "Down",
            x = -425,
            y = 295,
            size = 40,
            spacing = 0,
            columns = 4,
            enabled = true,
            hideMounted = true,
        },
        right = {
            name = "Right",
            anchorPoint = "TOPRIGHT",
            growthH = "Left",
            growthV = "Down",
            x = 425,
            y = 295,
            size = 40,
            spacing = 0,
            columns = 4,
            enabled = true,
            hideMounted = true,
        },
        center_panel = {
            name = "CENTER",
            enabled = true,
            showBackground = true,
            backgroundAlpha = 0.5,
            x = 0,
            y = 0,
            size = 50,
            columns = 7,
            spacing = 4,
            spanWidth = true,
            placement = "center",
            growthH = "Center",
            anchorPoint = "TOP",
            growthV = "Down",
            anchorTo = "Health Bar",
            hideMounted = true,
        },
        utility = {
            name = "UTILITY",
            enabled = true,
            anchorPoint = "TOP", -- Anchors top of this panel to bottom of target
            growthH = "Center",
            growthV = "Down",
            x = 0,
            y = 0, -- Default position
            size = 32,
            spacing = 0,
            columns = 9,
            placement = "center",
            anchorTo = "CENTER",
            hideMounted = true,
        },
        -- Glow duration limit (seconds)
        glow_max_duration = 5.0,
    },

    -- Global defaults for icon panels (can be overridden per-panel or per-icon)
    -- These provide fallback values for visual effect settings (like glows)
    icon_panel_global_defaults = {
        enableMasque = false,
        -- Visibility
        hideOOC = false,
        hideMounted = true,
        hideInVehicle = true,
        showTooltips = false, -- Default to false as per user request

        -- Ready Glow (when spell is off cooldown/available)
        readyGlow = true,           -- Enable glow when ready
        glowType = "autocast",      -- Options: pixel, autocast, proc, button
        useSpecColor = true,        -- Use specialization-based color for glows
        glowColor = { 1, 1, 0, 1 }, -- Yellow by default
        glowScale = 2.0,
        glowIntensity = 1.0,
        glowSpeed = 0.5,         -- User request: 0.5
        glowLines = 4,           -- Pixel glow: number of particles
        glowThickness = 1,       -- Pixel glow: line thickness
        glowParticles = 4,       -- Autocast glow: particle count
        glow_max_duration = 5.0, -- Max seconds to show glow

        -- Cooldown Visual State
        cooldownDesat = true,    -- Desaturate while on cooldown
        alphaOnCooldown = 1.0,   -- Alpha transparency while on cooldown (1.0 = Opaque)
        useResourceCheck = true, -- Enable mana/power based tinting
        showBackground = false,  -- Default backgrounds to OFF
        backgroundAlpha = 0.5,   -- 50% transparency for the background

        -- Text Display
        textEnabled = true,         -- Show countdown numbers on icons
        textColor = { 1, 1, 1, 1 }, -- White text

        -- Hotkey Display
        showHotkeys = false,       -- Show keybinding text on icons
        hotkeyFontSize = 12,       -- Font size for hotkey text
        hotkeyAnchor = "TOPLEFT",  -- Anchor point (TOPLEFT, TOPRIGHT, BOTTOMLEFT, BOTTOMRIGHT, CENTER)
        hotkeyOutline = "OUTLINE", -- Font outline (OUTLINE, THICKOUTLINE, or "")

        -- Icon Style
        showBorder = true,  -- Show 2px black border around icons
        squareIcons = true, -- Crop round icon edges to square

        -- Panel Visibility
        visibility = "always", -- "always", "combat", "noCombat"
    },

    options_panel = {
        width = 500,
        height = 500,
        backdrop_color = { 0.05, 0.05, 0.05, 0.8 },
        tabs = {
            width = 100,
            height = 30,
            color = { 0.4, 0.0, 1.0, 1 },           -- #6600FF for unselected tabs
            selected_color = { 0, 1, 1, 1 },        -- #00FFFF for selected tab
            highlight_color = { 0.6, 0.6, 0.6, 1 }, -- Medium gray for hover
        },
        icon_border_color = { 0.4, 0.4, 0.4, 1 },
    },

    tracked_options_layout = {
        ROW_HEIGHT = 30,
        COL_WIDTH = 135,
        PADDING = 5,
        HEADER_Y = 20,
    },

    currency_frame = {
        width = 200,
        height = 70,
    },

    gear = {
        updateDelay = 3,
        maxScaledILvl = 1000,
    },

    item_frame = {
        width = 200,
        height = 70,
    },

    cvars_on_load = {
        { name = "autoLootDefault", value = 1 },
    },

    powerBar = {
        enabled = true,
        width = 300,
        height = 10,
        pos = { x = 0, y = 285 },
        useClassColor = true,
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.5 },
        },
        hiddenSpecs = {
            [1467] = true, -- Devastation Evoker
            [1473] = true, -- Augmentation Evoker
            [265] = true,  -- Affliction Warlock
            [266] = true,  -- Demonology Warlock
            [267] = true,  -- Destruction Warlock
            [63] = true,   -- Fire Mage
            [64] = true,   -- Frost Mage
            [269] = true,  -- Windwalker Monk
            [70] = true,   -- Retribution Paladin
        },
    },

    castBar = {
        enabled = true,
        width = 300,
        height = 20,
        pos = { x = 0, y = 150 },
        color = { 1, 1, 1 },
        channelColor = { 0, 1, 0 },
        empoweredColor = { 0.4, 0, 1 },
        interruptedColor = { 1, 0, 0 },
        empoweredStageColors = {
            { 0, 1,   0 }, -- stage 1: green
            { 1, 1,   0 }, -- stage 2: yellow
            { 1, 0.5, 0 }, -- stage 3: orange
            { 1, 0,   0 }, -- stage 4: red
        },
        alpha = 1,
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.7 },
        },
        updateThrottle = 0.05,
        spark = {
            width = 20,
            heightMultiplier = 2.5
        },
        iconSize = 24,
        icon = {
            offset = -5
        }
    },

    targetCastBar = {
        enabled = true,
        width = 300,
        height = 50,
        pos = { x = 0, y = 480 },
        color = { 1, 1, 1 },                       -- Interruptible (White)
        nonInterruptibleColor = { 0.2, 0.2, 0.2 }, -- Dark Grey
        interruptedColor = { 1, 0, 0 },
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.5 },
        },
    },

    instantCastBar = {
        enabled = true,
        width = 300,
        height = 15,
        channelColor = { 0, 1, 0 }, -- Green for GCD
        iconSize = 19,
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.5 },
        },
    },

    healthBar = {
        enabled = true,
        width = 300,
        height = 20,
        color = { 0.2, 0.2, 0.2 }, -- Dark Grey
        pos = { x = 0, y = 300 },
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.5 }, -- Black/Transparent
        },
    },

    secondaryPowerBar = {
        enabled = true,
        width = 240,
        height = 15,
        useClassColor = true,
        fontSize = 18,
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.5 },
        },
        hiddenSpecs = {
            [258] = true, -- Shadow Priest
            [270] = true, -- Mistweaver Monk
            [262] = true, -- Elemental Shaman
        },
    },

    vigorBar = {
        enabled = true,
        width = 240,
        height = 15,
        color = { 0.4, 0, 1 },
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.5 },
        },
        icons = {
            gap = 5,
            offsetY = -5,
            sideOffset = 5,
        },
    },

    mountSpeedBar = {
        enabled = true,
        width = 240,
        height = 10,
        backdrop = {
            padding = 2,
            color = { 0, 0, 0, 0.5 },
        },
    },

    trackedIcons = {
        left = { x = -200, y = 0 },
        right = { x = 200, y = 0 },
    },

    barTexture = "Interface/Buttons/WHITE8X8",

    barTextures = {
        { text = "Default",           value = "Interface/TargetingFrame/UI-StatusBar" },
        { text = "Raid Bar",          value = "Interface/RaidFrame/Raid-Bar-Hp-Fill" },
        { text = "Casting Bar Spark", value = "Interface/CastingBar/UI-CastingBar-Spark" },
        { text = "Flat",              value = "Interface/Buttons/WHITE8X8" },
    },

    absorbBarColor = { 0.4, 0.0, 1.0, 0.75 },

    minimap = {
        default_size = 220,
        defaultZoom = 0,
        button_bar = {
            spacing = 5,
            button_size = 20,
            defaultX = 0,
            defaultY = -25,
        },
    },

    barLayout = {
        spacing = 1,
    },

    merchant = {
        -- Grid layout
        grid = {
            rows = 10,
            cols = 3,
            item_width = 190,
            item_height = 45,
            spacing_x = 195,
            spacing_y = 50,
            offset_x = 15,
            offset_y = -40,
        },
        -- Frame dimensions
        frame = {
            width = 615,  -- 3 cols * 195 + padding
            height = 620, -- 10 rows * 50 + header/footer
        },
        -- Utility bar
        utility_bar = {
            height = 30,
            bottom_offset = 2,
            button_height = 22,
            button_small = 75,  -- buyback, filter buttons
            button_medium = 70, -- sell greys
            button_large = 110, -- housing filter
            spacing = 4,
        },
        -- Scrollbar
        scrollbar = {
            width = 6,
            right_offset = 5,
        },
        -- Currency display
        currency = {
            height = 20,
            bottom_offset = 35,
        },
        -- Button colors (references to colors table)
        button_colors = {
            filter_active = "purple",
            filter_inactive = "white",
            filter_hover = "cyan",
            decor_hide_owned = "magenta",
            decor_hide_storage = "purple",
            decor_show_all = "white",
        },
        lootFilterState = 0,
    },

    automation = {
        auto_role_check = true,
        auto_sign_lfg = true,
    },


    trackedBars = {
        -- Position anchor
        anchor = {
            point = "BOTTOM",
            x = -300,
            y = 300,
        },
        -- Visual settings
        width = 200,
        height = 20,
        attachedWidthMultiplier = 0.8, -- Multiplier for Health Bar width when acting as secondary bar
        attachedHeight = 20,           -- Standard height for attached bars
        icon_size = 20,
        icon_offset = -5,              -- Space between bar and icon
        spacing = 5,
        backdrop = {
            padding = 1,
            color = { 0, 0, 0, 0.5 },
        },
        -- Stack/Segment settings
        maxSegments = 10, -- Maximum number of stack segments to create
        defaultMaxStacks = 10,
        -- Font settings
        fonts = {
            standard = "GameFontNormalSmall",
            stackModeDurationSize = 14, -- Larger size for stack mode duration text
        },
        -- Performance settings
        updateThrottle = 0.05, -- OnUpdate throttle interval (~20fps)
        -- Special case overrides (by cooldownID)
        specialCases = {
            [9039] = { maxStacks = 12 },   -- Bone Shield (Death Knight)
            [18469] = { maxStacks = 100 }, -- Ignore Pain (Warrior)
            [20811] = { maxStacks = 6 },   -- Soul Fragments (Demon Hunter)
        },
        -- Default visibility settings
        hideOOC = false,      -- Hide all bars when out of combat
        hideMounted = false,  -- Default to false for bars
        hideInVehicle = true, -- Hide all bars when in vehicle UI
        hideInactive = true,  -- Hide bars when cooldowns are inactive
        -- Default bar configuration per cooldown ID
        defaults = {
            [18469] = {                          -- Ignore Pain (Warrior)
                specID = 73,                     -- Protection Warrior
                stackAboveHealth = true,         -- Attach to healthbar (secondary position)
                color = { 1, 0.533, 0, 1 },      -- Orange
                showStacksText = true,           -- Show stack count as duration text
            },
            [9039] = {                           -- Bone Shield (Death Knight)
                specID = 250,                    -- Blood DK
                stackAboveHealth = true,         -- Attach to healthbar
                stackMode = true,                -- Use stack count as bar value
                color = { 0, 0.8, 0.067, 1 },    -- Green
                showName = false,                -- Hide name
            },
            [20811] = {                          -- Soul Fragments (Demon Hunter)
                specID = 581,                    -- Vengeance DH
                stackAboveHealth = true,         -- Attach to healthbar
                stackMode = true,                -- Use stacks as bar value
                showStacksText = true,           -- Show stack count
                color = { 0.64, 0.19, 0.79, 1 }, -- Purple/Magenta
                showName = false,                -- Hide name
            },
        },
    },

    trackedOptionsWindow = {
        width = 800,
        height = 500,
    },

    -- Master's Hammer Specialization Nodes
    -- Organised by expansion version keys.
    masterHammer = {
        requiredRank = 26, -- Required trait rank for repair perks
        defaultPosition = { x = 0, y = 0 },
        defaultColor = "00FFFF",
        [238020] = { -- Thalassian Master Repair Hammer (Midnight)
            nodes = {
                ["HEAD"] = 104570,
                ["SHOULDER"] = 104569,
                ["CHEST"] = 104574,
                ["WRIST"] = 104565,
                ["HANDS"] = 104564,
                ["WAIST"] = 104566,
                ["LEGS"] = 104573,
                ["FEET"] = 104568,
                ["SHIELD"] = 104572,
                [0] = 104627,
                [1] = 104627,
                [6] = 104627, -- Axes/Polearms
                [4] = 104628,
                [5] = 104628, -- Maces
                [7] = 104630,
                [8] = 104630,
                [9] = 104630, -- Long Blades
                [15] = 104631,
                [13] = 104631 -- Short Blades
            }
        },
    },
    alts = {
        width = 1000,
        height = 650,
        columnWidth = 140,
        rowHeight = 25,
        headerHeight = 40,
        backdropColor = { 0.05, 0.05, 0.05, 0.9 },
        borderColor = { 0, 0, 0, 1 },
        highlightColor = { 0.4, 0, 1, 1 }, -- Purple
        expansion = {
            preyFactionID = 2764,          -- Midnight Season 1 Progress
            activeHuntCurrencyID = 3392,   -- Remnant of Anguish
        },
        showM0Dungeons = true,
        statusColors = {
            completed = { 0, 1, 1, 0.8 },      -- Cyan
            inProgress = { 0, 0.2, 0.2, 0.8 }, -- Dark Teal (Strict)
            available = { 0, 0, 0, 0.5 },      -- Black (Available)
            textCompleted = "|cff00ffff",
            textInProgress = "|cff003333",     -- Matching 0, 0.2, 0.2 hex approximately
            textAvailable = "|cff888888",
        },
    },

    questlog = {
        enabled = true,
        width = 280,
        sectionHeight = 20,
        questHeight = 20,
        objectiveHeight = 13,
        itemSize = 32,
        throttle = 0.5,
        defaultHidden = false,
        sections = {
            { id = "scenario",     label = "world event",      color = { 1.00, 0.60, 0.10 } },
            { id = "important",    label = "important",        color = { 1.00, 0.40, 0.35 } },
            { id = "campaign",     label = "campaign",         color = { 0.90, 0.75, 0.10 } },
            { id = "meta",         label = "meta",             color = { 0.00, 1.00, 1.00 } },
            { id = "world",        label = "world quests",     color = { 0.20, 0.85, 0.95 } },
            { id = "activities",   label = "activities",       color = { 0.35, 0.90, 0.40 } },
            { id = "zone",         label = "quests",           color = { 1.00, 1.00, 1.00 } },
            { id = "achievements", label = "achievements",     color = { 0.85, 0.65, 0.35 } },
        },
    },

    -- ─── Mythic+ HUD ──────────────────────────────────────
    -- Settings for the native M+ timer/objectives frame (frames/mythic.lua).
    -- Runtime overrides are stored in SfuiDB to survive UI reloads.
    mythic = {
        enabled = true,     -- master toggle (user can opt-out in Options > objectives)
        width   = 280,      -- HUD frame width in pixels
        posX    = -10,      -- default TOPRIGHT x-offset from UIParent (matches quest log tracker)
        posY    = -10,      -- default TOPRIGHT y-offset from UIParent (matches quest log tracker)
    },

    -- ─── Vehicle Bar ──────────────────────────────────────
    -- Settings for the vehicle/override/possess bar (frames/vehicle.lua).
    vehicle = {
        enabled = true,
        posX    = 0,        -- default horizontal offset (centered at bottom)
        posY    = 50,       -- default vertical offset (+50px from bottom)
    },
}
