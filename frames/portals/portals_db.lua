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
-- Midnight Season 2 (12.1) spell IDs
-- ========================
sfui.portals_db.SEASON_PORTALS = {
    { spell = 1286812, name = "Altar of Fangs",        instance = 2993 }, -- Path of Venomous Evolution / Path of the Vicious
    { spell = 1286807, name = "Den of Nalorakk",        instance = 2825 }, -- Path of the Savage God
    { spell = 1286831, name = "Kings' Rest",           instance = 1762 }, -- Path of the Slumbering Conqueror / Path of the Ancient Kings
    { spell = 1286809, name = "Murder Row",            instance = 2813 }, -- Path of the Devious Smuggler / Path of the Murderer
    { spell = 393256,  name = "Ruby Life Pools",       instance = 2521 }, -- Path of the Clutch Defender
    { spell = 1286828, name = "Temple of Sethraliss",  instance = 1877 }, -- Path of the Sacred Temple
    { spell = 1286801, name = "The Blinding Vale",      instance = 2859 }, -- Path of the Blooming Verdure
    { spell = 1286804, name = "Voidscar Arena",        instance = 2923 }, -- Path of the Brutal Combatant / Path of the Voidscarred
}

-- ========================
-- Midnight Expansion Portals
-- Midnight expansion dungeon portals
-- ========================
sfui.portals_db.MIDNIGHT_PORTALS = {
    { spell = 1286812, name = "Altar of Fangs",        instance = 2993 },
    { spell = 1286807, name = "Den of Nalorakk",        instance = 2825 },
    { spell = 1254572, name = "Magisters' Terrace",      instance = 2811 },
    { spell = 1254559, name = "Maisara Caverns",         instance = 2874 },
    { spell = 1286809, name = "Murder Row",            instance = 2813 },
    { spell = 1254563, name = "Nexus-Point Xenas",       instance = 2915 },
    { spell = 1286801, name = "The Blinding Vale",      instance = 2859 },
    { spell = 1286804, name = "Voidscar Arena",        instance = 2923 },
    { spell = 1254400, name = "Windrunner Spire",        instance = 2805 },
}

-- ========================
-- Personal / Class Portals
-- Shown only if the player knows the spell (IsSpellInSpellBook)
-- Includes: mage teleports, DK/Monk/Druid class abilities, race abilities
-- ========================
sfui.portals_db.PERSONAL_PORTALS = {
    { spell = 50977,   name = "Acherus (Death Knight)"               },
    { spell = 281403,  portal = 281400, name = "Boralus"                          },
    { spell = 120145,  portal = 120146, name = "Dalaran (Crater)"                 },
    { spell = 224869,  portal = 224871, name = "Dalaran (Legion)"                 },
    { spell = 53140,   portal = 53142,  name = "Dalaran (Northrend)"              },
    { spell = 3565,    portal = 11419,  name = "Darnassus"                        },
    { spell = 281404,  portal = 281402, name = "Dazar'alor"                       },
    { spell = 446540,  portal = 446534, name = "Dornogal"                         },
    { spell = 193753,  name = "Dreamwalk (Druid)"                    },
    { spell = 32271,   portal = 32266,  name = "Exodar"                           },
    { spell = 193759,  name = "Hall of the Guardian (Mage)"          },
    { spell = 3562,    portal = 11416,  name = "Ironforge"                        },
    { spell = 265225,  name = "Mole Machine (Dark Iron Dwarf)"       },
    { spell = 18960,   name = "Moonglade (Druid)"                    },
    { spell = 344587,  portal = 344597, name = "Oribos"                           },
    { spell = 3567,    portal = 11417,  name = "Orgrimmar"                        },
    { spell = 1238686, name = "Rootwalking (Haranir)"                },
    { spell = 35715,   portal = 35717,  name = "Shattrath (A)"                   },
    { spell = 33690,   portal = 33691,  name = "Shattrath (H)"                   },
    { spell = 32272,   portal = 32267,  name = "Silvermoon"                       },
    { spell = 1259190, portal = 1259194,name = "Silvermoon City (Midnight)"       },
    { spell = 49358,   portal = 49361,  name = "Stonard"                          },
    { spell = 176248,  portal = 176246, name = "Stormshield"                      },
    { spell = 3561,    portal = 10059,  name = "Stormwind"                        },
    { spell = 49359,   portal = 49360,  name = "Theramore"                        },
    { spell = 3566,    portal = 11420,  name = "Thunder Bluff"                    },
    { spell = 88342,   portal = 88345,  name = "Tol Barad (A)"                   },
    { spell = 88344,   portal = 88346,  name = "Tol Barad (H)"                   },
    { spell = 3563,    portal = 11418,  name = "Undercity"                        },
    { spell = 395277,  portal = 395289, name = "Valdrakken"                       },
    { spell = 132621,  portal = 132620, name = "Vale of Eternal Blossoms (A)"     },
    { spell = 132627,  portal = 132626, name = "Vale of Eternal Blossoms (H)"     },
    { spell = 176242,  portal = 176244, name = "Warspear"                         },
    { spell = 126892,  name = "Zen Pilgrimage (Monk)"                },
}

-- ========================
-- Engineering Wormhole Toys
-- Checked via PlayerHasToy() AND is_engineer() at runtime
-- ========================
sfui.portals_db.WORMHOLE_TOYS = {
    { toy = 248485, name = "Wormhole Generator: Quel'Thalas"         }, -- Midnight (12.0)
    { toy = 221966, name = "Wormhole Generator: Khaz Algar"          }, -- The War Within (11.0)
    { toy = 198156, name = "Wyrmhole Generator: Dragon Isles"        }, -- Dragonflight (10.0)
    { toy = 172924, name = "Wormhole Generator: Shadowlands"         }, -- Shadowlands (9.0)
    { toy = 168808, name = "Wormhole Generator: Zandalar"            }, -- Battle for Azeroth (8.0)
    { toy = 168807, name = "Wormhole Generator: Kul Tiras"           }, -- Battle for Azeroth (8.0)
    { toy = 151652, name = "Wormhole Generator: Argus"               }, -- Legion (7.3)
    { toy = 112059, name = "Wormhole Centrifuge: Draenor"            }, -- Warlords of Draenor (6.0)
    { toy = 87215,  name = "Wormhole Generator: Pandaria"            }, -- Mists of Pandaria (5.0)
    { toy = 48933,  name = "Wormhole Generator: Northrend"           }, -- Wrath of the Lich King (3.0)
    { toy = 30544,  name = "Ultrasafe Transporter: Toshley's Station"}, -- The Burning Crusade (2.0)
    { toy = 30542,  name = "Dimensional Ripper: Area 52"             }, -- The Burning Crusade (2.0)
    { toy = 18986,  name = "Ultrasafe Transporter: Gadgetzan"        }, -- Classic (1.0)
    { toy = 18984,  name = "Dimensional Ripper: Everlook"            }, -- Classic (1.0)
}

-- ========================
-- Legacy Dungeon Portals — grouped by expansion for dropdowns
-- Spells shown only if IsSpellInSpellBook is true (player has the spell)
-- ========================
sfui.portals_db.LEGACY_GROUPS = {
    {
        label = "Khaz Algar",
        portals = {
            { spell = 445417,  name = "Ara-Kara"                     },
            { spell = 445440,  name = "Cinderbrew Meadery"           },
            { spell = 445416,  name = "City of Threads"              },
            { spell = 445441,  name = "Darkflame Cleft"              },
            { spell = 1237215, name = "Eco-Dome Al'dani"             },
            { spell = 1226482, name = "Liberation of Undermine"      },
            { spell = 1239155, name = "Manaforge Omega"              },
            { spell = 1216786, name = "Operation: Floodgate"         },
            { spell = 445444,  name = "Priory of the Sacred Flame"   },
            { spell = 445269,  name = "Stonevault"                   },
            { spell = 445414,  name = "The Dawnbreaker"              },
            { spell = 445443,  name = "The Rookery"                  },
        },
    },
    {
        label = "Dragon Isles",
        portals = {
            { spell = 432257, name = "Aberrus"                       },
            { spell = 393273, name = "Algeth'ar Academy"             },
            { spell = 432258, name = "Amirdrassil"                   },
            { spell = 393267, name = "Brackenhide Hollow"            },
            { spell = 424197, name = "Dawn of the Infinite"          },
            { spell = 393283, name = "Halls of Infusion"             },
            { spell = 393276, name = "Neltharus"                     },
            { spell = 393256, name = "Ruby Life Pools"               },
            { spell = 393279, name = "The Azure Vault"               },
            { spell = 393262, name = "The Nokhud Offensive"          },
            { spell = 432254, name = "Vault of the Incarnates"       },
        },
    },
    {
        label = "Shadowlands",
        portals = {
            { spell = 354468, name = "De Other Side"                 },
            { spell = 354465, name = "Halls of Atonement"            },
            { spell = 354464, name = "Mists of Tirna Scithe"         },
            { spell = 354462, name = "Necrotic Wake"                 },
            { spell = 354463, name = "Plaguefall"                    },
            { spell = 373191, name = "Sanctum of Domination"         },
            { spell = 354469, name = "Sanguine Depths"               },
            { spell = 373192, name = "Sepulcher of the First Ones"   },
            { spell = 354466, name = "Spires of Ascension"           },
            { spell = 367416, name = "Tazavesh the Veiled Market"    },
            { spell = 354467, name = "Theater of Pain"               },
        },
    },
    {
        label = "Kul Tiras",
        portals = {
            { spell = 410071, name = "Freehold"                      },
            { spell = 373274, name = "Operation: Mechagon"           },
            { spell = 445418, name = "Siege of Boralus"              },
            { spell = 464256, name = "Siege of Boralus (S2)"         },
            { spell = 424167, name = "Waycrest Manor"                },
        },
    },
    {
        label = "Zandalar",
        portals = {
            { spell = 424187,  name = "Atal'Dazar"                    },
            { spell = 1286831, name = "Kings' Rest"                   },
            { spell = 1286828, name = "Temple of Sethraliss"          },
            { spell = 467553,  name = "The MOTHERLODE!! (A)"          },
            { spell = 467555,  name = "The MOTHERLODE!! (H)"          },
            { spell = 410074,  name = "The Underrot"                  },
        },
    },
    {
        label = "Broken Isles",
        portals = {
            { spell = 424153, name = "Black Rook Hold"               },
            { spell = 393766, name = "Court of Stars"                },
            { spell = 424163, name = "Darkheart Thicket"             },
            { spell = 393764, name = "Halls of Valor"                },
            { spell = 410078, name = "Neltharion's Lair"             },
            { spell = 1254551, name = "Seat of the Triumvirate"      },
        },
    },
    {
        label = "Draenor",
        portals = {
            { spell = 159897, name = "Auchindoun"                    },
            { spell = 159895, name = "Bloodmaul Slag Mines"          },
            { spell = 159900, name = "Grimrail Depot"                },
            { spell = 159896, name = "Iron Docks"                    },
            { spell = 159899, name = "Shadowmoon Burial Grounds"     },
            { spell = 159898, name = "Skyreach"                     },
            { spell = 1254557, name = "Skyreach (New)"               },
            { spell = 159901, name = "The Everbloom"                 },
        },
    },
    {
        label = "Pandaria",
        portals = {
            { spell = 131225, name = "Gate of the Setting Sun"       },
            { spell = 131222, name = "Mogu'shan Palace"              },
            { spell = 131206, name = "Shado-Pan Monastery"           },
            { spell = 131228, name = "Siege of Niuzao Temple"        },
            { spell = 131205, name = "Stormstout Brewery"            },
            { spell = 131204, name = "Temple of the Jade Serpent"    },
        },
    },
    {
        label = "Northrend",
        portals = {
            { spell = 1254555, name = "Pit of Saron"                 },
        },
    },
    {
        label = "Maelstrom",
        portals = {
            { spell = 424142, name = "Throne of the Tides"           },
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
        label = "Eastern Kingdoms",
        portals = {
            { spell = 373190, name = "Castle Nathria"                },
            { spell = 445424, name = "Grim Batol"                    },
            { spell = 373262, name = "Karazhan"                      },
            { spell = 131231, name = "Scarlet Halls"                 },
            { spell = 131229, name = "Scarlet Monastery"             },
            { spell = 131232, name = "Scholomance"                   },
            { spell = 159902, name = "Upper Blackrock Spire"         },
        },
    },
}

-- ========================
-- Global UI Name Abbreviations
-- Consumed by sfui.common.get_short_string()
-- ========================
sfui.portals_db.SHORT_STRINGS = {
    ["Ara-Kara, City of Echoes"] = "ARA",
    ["City of Threads"] = "COT",
    ["The Stonevault"] = "SV",
    ["The Dawnbreaker"] = "DB",
    ["Mists of Tirna Scithe"] = "MISTS",
    ["The Necrotic Wake"] = "NW",
    ["Siege of Boralus"] = "SIEGE",
    ["Grim Batol"] = "GB",
    ["Darkflame Cleft"] = "DFC",
    ["Cinderbrew Meadery"] = "CM",
    ["Priory of the Sacred Flame"] = "PSF",
    ["The Rookery"] = "ROOK",
    ["Operation: Floodgate"] = "FLOOD",
    ["Liberation of Undermine"] = "LOU",
    ["Darkmoon"] = "DM",
    ["Theater of Pain"] = "TOP",
    ["Ruby Life Pools"] = "RLP",
    ["The Nokhud Offensive"] = "TNO",
    ["Algeth'ar Academy"] = "AA",
    ["Halls of Infusion"] = "HOI",
    ["Neltharus"] = "NELT",
    ["Brackenhide Hollow"] = "BH",
    ["Uldaman: Legacy of Tyr"] = "ULD",
    ["Operation: Mechagon - Junkyard"] = "JUNK",
    ["Operation: Mechagon - Workshop"] = "WORK",
    ["Return to Karazhan: Lower"] = "LOW",
    ["Return to Karazhan: Upper"] = "UPP",
    ["Stonevault"] = "SV",
    ["Ara-Kara"] = "ARA",
    ["Necrotic Wake"] = "NW",
    ["Operation: Mechagon"] = "MECH",
    ["Siege of Boralus (S2)"] = "SIEGE",
    ["Eco-Dome Al'dani"] = "ECO",
    ["Manaforge Omega"] = "OMEGA",
    ["Pit of Saron"] = "POS",
    ["Magisters' Terrace"] = "MGT",
    ["Seat of the Triumvirate"] = "SEAT",
    ["Maisara Cavern"] = "MAIS",
    ["Maisara Caverns"] = "MAIS",
    ["Nexus Point Xenas"] = "NPX",
    ["Nexus-Point Xenas"] = "NPX",
    ["Windrunner Spire"] = "SPIRE",
    ["Skyreach"] = "SKY",
    ["Skyreach (New)"] = "SKY",
    ["Altar of Fangs"] = "AOF",
    ["Murder Row"] = "MR",
    ["Den of Nalorakk"] = "DON",
    ["The Blinding Vale"] = "BV",
    ["Voidscar Arena"] = "VA",
    ["Kings' Rest"] = "KR",
    ["King's Rest"] = "KR",
    ["Temple of Sethraliss"] = "TOS",
}

