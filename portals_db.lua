-- portals_db.lua
-- All portal/wormhole spell and toy IDs. Edit here to add new portals.
-- Availability is checked at runtime in portals.lua:
--   Spells: C_SpellBook.IsSpellInSpellBook(spellID)
--   Toys:   PlayerHasToy(toyID)
--
-- Names use GetRealZoneText(instance) automatically when instance is set.
-- Set name="" to force instance-based name lookup.

sfui = sfui or {}
sfui.portals_db = {}

-- ========================
-- Current M+ Season Portals ("Path of the ...")
-- Midnight Season 1 spell IDs
-- ========================
sfui.portals_db.SEASON_PORTALS = {
    { spell = 1254400, name = "Windrunner Spire",        instance = 2805 },
    { spell = 1254572, name = "Magisters' Terrace",      instance = 2811 },
    { spell = 1254559, name = "Maisara Cavern",          instance = 2874 },
    { spell = 1254563, name = "Nexus Point Xenas",       instance = 2915 },
    { spell = 1254551, name = "Seat of the Triumvirate", instance = 1753 },
    { spell = 1254555, name = "Pit of Saron",            instance = 658  },
    { spell = 159898,  name = "Skyreach",                instance = 1209 }, -- old spell ID
    { spell = 1254557, name = "Skyreach (New)",          instance = 1209 }, -- new spell ID
    { spell = 393273,  name = "Algeth'ar Academy",       instance = 2526 },
}

-- ========================
-- Personal / Class Portals
-- Shown only if the player knows the spell (IsSpellInSpellBook)
-- Includes: mage teleports, DK/Monk/Druid class abilities, race abilities
-- ========================
sfui.portals_db.PERSONAL_PORTALS = {
    -- Death Knight
    { spell = 50977,   name = "Archerus (Death Knight)"              },
    -- Monk
    { spell = 126892,  name = "Zen Pilgrimage (Monk)"                },
    -- Mage - Class Hall
    { spell = 193759,  name = "Hall of the Guardian (Mage)"          },
    -- Druid
    { spell = 18960,   name = "Moonglade (Druid)"                    },
    { spell = 193753,  name = "Dreamwalk (Druid)"                    },
    -- Haranir
    { spell = 1238686, name = "Rootwalking (Haranir)"                },
    -- Dark Iron Dwarf Mole Machine
    { spell = 265225,  name = "Mole Machine (Dark Iron Dwarf)"       },
    -- Mage city teleports — left-click = teleport (self), right-click = portal (group)
    { spell = 3561,    portal = 10059,  name = "Stormwind"                        },
    { spell = 3562,    portal = 11416,  name = "Ironforge"                        },
    { spell = 3563,    portal = 11418,  name = "Undercity"                        },
    { spell = 3565,    portal = 11419,  name = "Darnassus"                        },
    { spell = 3566,    portal = 11420,  name = "Thunder Bluff"                    },
    { spell = 3567,    portal = 11417,  name = "Orgrimmar"                        },
    { spell = 32271,   portal = 32266,  name = "Exodar"                           },
    { spell = 32272,   portal = 32267,  name = "Silvermoon"                       },
    { spell = 35715,   portal = 35717,  name = "Shattrath (A)"                   },
    { spell = 33690,   portal = 33691,  name = "Shattrath (H)"                   },
    { spell = 49358,   portal = 49361,  name = "Stonard"                          },
    { spell = 49359,   portal = 49360,  name = "Theramore"                        },
    { spell = 53140,   portal = 53142,  name = "Dalaran (Northrend)"              },
    { spell = 88342,   portal = 88345,  name = "Tol Barad (A)"                   },
    { spell = 88344,   portal = 88346,  name = "Tol Barad (H)"                   },
    { spell = 120145,  portal = 120146, name = "Dalaran (Crater)"                 },
    { spell = 132621,  portal = 132620, name = "Vale of Eternal Blossoms (A)"     },
    { spell = 132627,  portal = 132626, name = "Vale of Eternal Blossoms (H)"     },
    { spell = 176242,  portal = 176244, name = "Warspear"                         },
    { spell = 176248,  portal = 176246, name = "Stormshield"                      },
    { spell = 224869,  portal = 224871, name = "Dalaran (Legion)"                 },
    { spell = 281403,  portal = 281400, name = "Boralus"                          },
    { spell = 281404,  portal = 281402, name = "Dazar'alor"                       },
    { spell = 344587,  portal = 344597, name = "Oribos"                           },
    { spell = 395277,  portal = 395289, name = "Valdraken"                        },
    { spell = 446540,  portal = 446534, name = "Dornogal"                         },
    { spell = 1259190, portal = 1259194,name = "Silvermoon City (Midnight)"       },
}

-- ========================
-- Engineering Wormhole Toys
-- Checked via PlayerHasToy() AND is_engineer() at runtime
-- ========================
sfui.portals_db.WORMHOLE_TOYS = {
    { toy = 248485, name = "Wormhole Generator: Quel'Thalas"         }, -- Midnight
    { toy = 221966, name = "Wormhole Generator: Khaz Algar"          },
    { toy = 198156, name = "Wyrmhole Generator: Dragon Isles"        },
    { toy = 172924, name = "Wormhole Generator: Shadowlands"         },
    { toy = 168808, name = "Wormhole Generator: Zandalar"            },
    { toy = 168807, name = "Wormhole Generator: Kul Tiras"           },
    { toy = 151652, name = "Wormhole Generator: Argus"               },
    { toy = 112059, name = "Wormhole Centrifuge: Draenor"            },
    { toy = 87215,  name = "Wormhole Generator: Pandaria"            },
    { toy = 48933,  name = "Wormhole Generator: Northrend"           },
    -- Old-world transporters (Goblin & Gnomish engineering)
    { toy = 30544,  name = "Ultrasafe Transporter: Toshley's Station"},
    { toy = 30542,  name = "Dimensional Ripper: Area 52"             },
    { toy = 18986,  name = "Ultrasafe Transporter: Gadgetzan"        },
    { toy = 18984,  name = "Dimensional Ripper: Everlook"            },
}

-- ========================
-- Legacy Dungeon Portals — grouped by expansion for dropdowns
-- Spells shown only if IsSpellInSpellBook is true (player has the spell)
-- ========================
sfui.portals_db.LEGACY_GROUPS = {
    {
        label = "Eastern Kingdoms",
        portals = {
            { spell = 131229, name = "Scarlet Monastery"             },
            { spell = 131231, name = "Scarlet Halls"                 },
            { spell = 131232, name = "Scholomance"                   },
            { spell = 373262, name = "Karazhan"                      },
            { spell = 445424, name = "Grim Batol"                    },
            { spell = 159902, name = "Upper Blackrock Spire"         },
            { spell = 373190, name = "Castle Nathria"                },
        },
    },
    {
        label = "Kalimdor",
        portals = {
            { spell = 410080, name = "The Vortex Pinnacle"           },
            { spell = 393222, name = "Uldaman: Legacy of Tyr"        },
        },
    },
    {
        label = "Pandaria",
        portals = {
            { spell = 131204, name = "Temple of the Jade Serpent"    },
            { spell = 131205, name = "Stormstout Brewery"            },
            { spell = 131206, name = "Shado-Pan Monastery"           },
            { spell = 131222, name = "Mogu'shan Palace"              },
            { spell = 131225, name = "Gate of the Setting Sun"       },
            { spell = 131228, name = "Siege of Niuzao Temple"        },
        },
    },
    {
        label = "Draenor",
        portals = {
            { spell = 159895, name = "Bloodmaul Slag Mines"          },
            { spell = 159896, name = "Iron Docks"                    },
            { spell = 159897, name = "Auchindoun"                    },
            { spell = 159899, name = "Shadowmoon Burial Grounds"     },
            { spell = 159900, name = "Grimrail Depot"                },
            { spell = 159901, name = "The Everbloom"                 },
        },
    },
    {
        label = "Broken Isles",
        portals = {
            { spell = 393764, name = "Halls of Valor"                },
            { spell = 393766, name = "Court of Stars"                },
            { spell = 424153, name = "Black Rook Hold"               },
            { spell = 424163, name = "Darkheart Thicket"             },
            { spell = 410078, name = "Neltharion's Lair"             },
        },
    },
    {
        label = "Zandalar",
        portals = {
            { spell = 410074, name = "The Underrot"                  },
            { spell = 424187, name = "Atal'Dazar"                    },
            { spell = 467553, name = "The MOTHERLODE!! (A)"          },
            { spell = 467555, name = "The MOTHERLODE!! (H)"          },
        },
    },
    {
        label = "Kul Tiras",
        portals = {
            { spell = 410071, name = "Freehold"                      },
            { spell = 424167, name = "Waycrest Manor"                },
            { spell = 373274, name = "Operation: Mechagon"           },
            { spell = 445418, name = "Siege of Boralus"              },
            { spell = 464256, name = "Siege of Boralus (S2)"         },
        },
    },
    {
        label = "Shadowlands",
        portals = {
            { spell = 354462, name = "Necrotic Wake"                 },
            { spell = 354463, name = "Plaguefall"                    },
            { spell = 354464, name = "Mists of Tirna Scithe"         },
            { spell = 354465, name = "Halls of Atonement"            },
            { spell = 354466, name = "Spires of Ascension"           },
            { spell = 354467, name = "Theater of Pain"               },
            { spell = 354468, name = "De Other Side"                 },
            { spell = 354469, name = "Sanguine Depths"               },
            { spell = 367416, name = "Tazavesh the Veiled Market"    },
            { spell = 373191, name = "Sanctum of Domination"         },
            { spell = 373192, name = "Sepulcher of the First Ones"   },
        },
    },
    {
        label = "Dragon Isles",
        portals = {
            { spell = 393256, name = "Ruby Life Pools"               },
            { spell = 393262, name = "The Nokhud Offensive"          },
            { spell = 393267, name = "Brackenhide Hollow"            },
            { spell = 393276, name = "Neltharus"                     },
            { spell = 393279, name = "The Azure Vault"               },
            { spell = 393283, name = "Halls of Infusion"             },
            { spell = 393273, name = "Algeth'ar Academy"             },
            { spell = 424197, name = "Dawn of the Infinite"          },
            { spell = 432254, name = "Vault of the Incarnates"       },
            { spell = 432257, name = "Aberrus"                       },
            { spell = 432258, name = "Amirdrassil"                   },
        },
    },
    {
        label = "Khaz Algar",
        portals = {
            { spell = 445269,  name = "Stonevault"                   },
            { spell = 445416,  name = "City of Threads"              },
            { spell = 445414,  name = "The Dawnbreaker"              },
            { spell = 445417,  name = "Ara-Kara"                     },
            { spell = 445440,  name = "Cinderbrew Meadery"           },
            { spell = 445441,  name = "Darkflame Cleft"              },
            { spell = 445443,  name = "The Rookery"                  },
            { spell = 445444,  name = "Priory of the Sacred Flame"   },
            { spell = 1216786, name = "Operation: Floodgate"         },
            { spell = 1226482, name = "Liberation of Undermine"      },
            { spell = 1237215, name = "Eco-Dome Al'dani"             },
            { spell = 1239155, name = "Manaforge Omega"              },
        },
    },
    {
        label = "Maelstrom",
        portals = {
            { spell = 424142, name = "Throne of the Tides"           },
        },
    },
}
