sfui = sfui or {}

sfui.config = {
    -- addon metadata
    title = "|cff6600ffst|r fui - frameworks",
    version = "0.0.1",

    -- general appearance
    font = "GameFontNormal",
    font_small = "GameFontNormalSmall",
    font_large = "GameFontNormalLarge",
    font_highlight = "GameFontHighlight",
    header_color = {1, 1, 1},
    textures = {
        white = "Interface/Buttons/WHITE8X8",
        tooltip = "Interface/Tooltips/UI-Tooltip-Background",
        gold_icon = "Interface\MoneyFrame\UI-GoldIcon",
    },

    -- shared settings for icon bars
    widget_bar = {
        icon_size = 40,
        icon_spacing = 5,
        label_offset_y = -2,
        label_color = {1, 1, 1},
    },

    -- custom spec colors (for example, to override defaults or add new ones)
    spec_colors = {
        -- Death Knight
        [250] = {0.77, 0.12, 0.23},   -- Blood
        [251] = {0.0, 1.0, 1.0},       -- Frost (User Override)
        [252] = {0.0, 1.0, 0.0},       -- Unholy (User Override)
        -- Demon Hunter
        [577] = {0.64, 0.19, 0.79},   -- Havoc
        [581] = {0.64, 0.19, 0.79},   -- Vengeance
        [1480] = {0.4, 0, 1},          -- Devourer
        -- Druid
        [102] = {1.00, 0.49, 0.04},   -- Balance
        [103] = {1.00, 0.49, 0.04},   -- Feral
        [104] = {1.00, 0.49, 0.04},   -- Guardian
        [105] = {1.00, 0.49, 0.04},   -- Restoration
        -- Evoker
        [1467] = {0.20, 0.58, 0.50},  -- Devastation
        [1468] = {0.20, 0.58, 0.50},  -- Preservation
        [1473] = {0.20, 0.58, 0.50},  -- Augmentation
        -- Hunter
        [253] = {0.67, 0.83, 0.45},   -- Beast Mastery
        [254] = {0.67, 0.83, 0.45},   -- Marksmanship
        [255] = {0.67, 0.83, 0.45},   -- Survival
        -- Mage
        [62] = {0.25, 0.78, 0.92},    -- Arcane
        [63] = {0.25, 0.78, 0.92},    -- Fire
        [64] = {0.25, 0.78, 0.92},    -- Frost
        -- Monk
        [268] = {0.00, 1.00, 0.59},   -- Brewmaster
        [269] = {0.00, 1.00, 0.59},   -- Mistweaver
        [270] = {0.00, 1.00, 0.59},   -- Windwalker
        -- Paladin
        [65] = {0.96, 0.55, 0.73},    -- Holy
        [66] = {0.96, 0.55, 0.73},    -- Protection
        [70] = {0.96, 0.55, 0.73},    -- Retribution
        -- Priest
        [256] = {1.00, 1.00, 1.00},   -- Discipline
        [257] = {1.00, 1.00, 1.00},   -- Holy
        [258] = {1.00, 1.00, 1.00},   -- Shadow
        -- Rogue
        [259] = {1.00, 0.96, 0.41},   -- Assassination
        [260] = {1.00, 0.96, 0.41},   -- Outlaw
        [261] = {1.00, 0.96, 0.41},   -- Subtlety
        -- Shaman
        [262] = {0.00, 0.44, 0.87},   -- Elemental
        [263] = {0.00, 0.44, 0.87},   -- Enhancement
        [264] = {0.00, 0.44, 0.87},   -- Restoration
        -- Warlock
        [265] = {0.53, 0.53, 0.93},   -- Affliction
        [266] = {0.53, 0.53, 0.93},   -- Demonology
        [267] = {0.53, 0.53, 0.93},   -- Destruction
        -- Warrior
        [71] = {0.78, 0.61, 0.43},    -- Arms
        [72] = {0.78, 0.61, 0.43},    -- Fury
        [73] = {0.78, 0.61, 0.43},    -- Protection
    },

    -- options panel specific settings
    options_panel = {
        width = 500,
        height = 500,
        backdrop_color = { r = 0.05, g = 0.05, b = 0.05, a = 0.8 },
        tabs = {
            width = 100,
            height = 30,
            color = { r = 0.4, g = 0.0, b = 1.0 }, -- 6600ff for unselected tabs
            selected_color = { r = 0.9, g = 0.9, b = 0.9 }, -- Off-white for selected tab
            highlight_color = { r = 0.6, g = 0.6, b = 0.6 }, -- Medium gray for hover
        }
    },

    -- currency frame settings
    currency_frame = {
        width = 200,
        height = 70,
    },

    -- item frame settings
    item_frame = {
        width = 200,
        height = 70,
    },

    -- CVars to set on addon load
    cvars_on_load = {
        { name = "autoLootDefault", value = 1 },
        { name = "uiScale", value = 0.6 },
    },

    -- Power Bar settings
    powerBar = {
        enabled = true,
        width = 300,
        height = 10,
        useClassColor = true,
        backdrop = {
            padding = 2,
            color = {0, 0, 0, 0.5},
        },
    },

    -- Health Bar settings
    healthBar = {
        enabled = true,
        width = 300,
        height = 20,
        backdrop = {
            padding = 2,
            color = {0, 0, 0, 0.5},
        },
    },

    -- Secondary Power Bar settings
    secondaryPowerBar = {
        enabled = true,
        width = 240,
        height = 15,
        useClassColor = true,
        fontSize = 14,
        backdrop = {
            padding = 2,
            color = {0, 0, 0, 0.5},
        },
    },

    -- Vigor Bar settings
    vigorBar = {
        enabled = true,
        width = 240,
        height = 15,
        color = {0.4, 0, 1}, -- #6600ff
        backdrop = {
            padding = 2,
            color = {0, 0, 0, 0.5},
        },
    },

    -- Mount Speed Bar settings
    mountSpeedBar = {
        enabled = true,
        width = 240, -- Inherit width from vigorBar
        height = 10,
        backdrop = {
            padding = 2,
            color = {0, 0, 0, 0.5},
        },
    },

    barTexture = "Interface/Buttons/WHITE8X8",

    barTextures = {
        { text = "Default", value = "Interface/TargetingFrame/UI-StatusBar" },
        { text = "Raid Bar", value = "Interface/RaidFrame/Raid-Bar-Hp-Fill" },
        { text = "Casting Bar Spark", value = "Interface/CastingBar/UI-CastingBar-Spark" },
        { text = "Flat", value = "Interface/Buttons/WHITE8X8" },
    },

    absorbBarColor = {0.392, 1.0, 1.0, 0.75}, -- Hardcoded #64ffff with 75% alpha

    minimap = {
        default_size = 220, -- Default size for square minimap
        border = {
            size = 2,
            color = {0, 0, 0, 0.5}, -- Black, 50% transparent
        },
        button_bar = {
            spacing = 2,
            position = "LEFT", -- or TOP, RIGHT, BOTTOM
            button_size = 28,
        },
        auto_zoom = true,
        square = true,
        collect_buttons = true,
        masque = false,
    },
}