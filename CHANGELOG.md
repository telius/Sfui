## v12.1.0-7 (2026-08-28)

### Bug Fixes & Performance
- **City & Idle Memory Leak Fix (`trackedicons.lua`, `trackedbars.lua`, `common.lua`)**: Fixed central event argument signatures for `UNIT_AURA` and `UNIT_SPELLCAST_SUCCEEDED`. Added strict player-only unit filtering, preventing nearby player and NPC aura updates in populated cities from triggering continuous icon layout updates and table churn.
- **Table Allocation & Scratch Pooling**: Added reusable destination table support to `sfui.common.get_active_panel_entries` and hoisted scratch tables in `trackedicons.lua` and `trackedbars.lua`.
- **Delve Nemesis Tracking (`mythic.lua`)**: Fixed Nemesis Influence counter in Delves to accurately display active remaining empowered packs (e.g. `4/4`) counting down to `Done`, and expanded widget inspection to `IconAndTextWidget` and `TextWithStateWidget`.
- **M+ / Delve HUD Fixes (`mythic.lua`)**: Replaced raw escape bytes with Blizzard raid target markup in preview, resolved preview lexical scoping nil calls, and eliminated duplicate `GetAllWidgetsBySetID` queries.
- **Blizzard Objective Tracker Taint & Flicker Prevention (`quests.lua`)**: Switched tracker hiding to native `RegisterStateDriver` without insecure `OnShow` hooks, eliminating secret aura taint errors in `ShouldShowMawBuffs` during Mythic+, and anchored the Blizzard tracker off-screen with alpha 0 to eliminate delve 1-frame flickering.
- **Fast Spec Swapping & Gear Cache (`gear.lua`, `highest.lua`)**: Added staggered sync passes (0ms, 150ms, 400ms) on spec switch to guarantee immediate equipping of weapons and trinkets, and added a 300-entry eviction limit to `validationCache`.
- **World Quest Summary Optimizations (`wqs.lua`)**: Eliminated intermediate table creation on item scans and capped `tablePool`.

## v12.1.0-6 (2026-08-25)

### Features & Updates
- **Great Vault Rewards & Item Levels (`alts.lua`)**: Integrated Great Vault reward item level resolution and upgrade tracks (Myth, Hero, Champion, Veteran) for Patch 12.1 / Midnight.
- **Great Vault Tooltips**: Enhanced hover tooltips across Raid, Dungeon, and World/Delve rows to display exact item levels, difficulty names, and color-coded upgrade tracks (`318 ilvl (Myth 1/6)`, `315 ilvl (Hero 4/6)`, `308 ilvl (Hero 2/6)`, etc.).
- **Vault Grid Visuals**: Aligned Great Vault grid box colors with Blizzard item quality standards (Mythic Orange for +10/Mythic, Epic Purple for +2–9/Heroic/Tier 7–8+, Rare Blue for M0/Normal/Tier 4–6, Uncommon Green for LFR/Veteran).

## v12.1.0-5 (2026-08-24)

### Features & Updates
- **Custom Quest Log & Objective Tracker (`quests.lua`)**: Rebuilt custom Quest Log and Objective Tracker panel with zero-interaction isolation from Blizzard's `UIWidgetManager` and secret layout frames.
- **Quest Log Toggle**: Added an `enable quest log` toggle in the Main tab of the Options panel (enabled by default) and `/sfquestlog` / `/sfql` slash command toggles.
- **Zero-Interaction & Taint Prevention**: Decoupled `SfuiTooltip` from `"GameTooltipTemplate"` and switched to `"TooltipBackdropTemplate"` with `TooltipDataHandlerMixin`, eliminating secret arithmetic errors (`LayoutFrame.lua:491` / `Blizzard_UIWidgetTemplateTextWithState.lua:35`).
- **MapCanvas & Pin Protection**: Replaced dynamic group finder queries with static quest log metadata and deferred tracker re-hiding, eliminating blocked action errors on `SetPassThroughButtons()` and `SetPropagateMouseClicks()`.
- **World Quest Summary (`wqs.lua`)**: Reparented WQS UI elements to `UIParent` with deferred World Map synchronization and modern `C_TooltipInfo.GetQuestLogItem` scanning.

## v12.1.0-4 (2026-08-14)

### Features & Updates
- **Research Trees (Patch 12.1 & Midnight)**: Added research and generic trait tree definitions for **Altar of Corrosion** (1191), **Omnium Folio** (1186), **Valeera Delve Season 2** (1177/1151), **Valeera Delve Season 1** (1168), **Zul'Aman Loa Blessing** (1166), **Coiled Isle System** (1192), **Atal'Utek Vaults** (1190), **Delve Companion Perks/Abilities/Specs** (1185, 1176, 1175, 1173), and **Void Research**.
- **Alt Tracker Currencies (12.1 PTR / Midnight)**: Updated currency tracking in `alts.lua` with 12.1 PTR IDs: **Mistcrests** (Hero 3445, Myth 3446), **Spark of Tides** (Item 274476), **Venomblight Manaflux Catalyst** (3465), and **Corrosive Coin** (3110).
- **Alt Tracker Weekly Quests**: Expanded weekly quest grid with Midnight World Bosses (`worldBoss`), Special Assignments (`specialAssignment`), Void Assaults (`voidAssaults`), and Prey Bounties (`prey`).
- **Profession KP Tracking**: Added Midnight expansion skillLine ID mappings (`2903`–`2913`) to `PROF_KP_SOURCES` for seamless profession knowledge tracking across parent and expansion skill line APIs.

## v12.1.0-3 (2026-08-13)

### Features & Refactoring
- **Vehicle UI**: Rebuilt `vehicle.lua` with a secure, combat-safe vehicle action bar driven exclusively by `RegisterStateDriver`. Up to 6 action buttons automatically display during vehicles, follower dungeons, and possess bars.
- **Icon Styling**: Applied square icon crop with 2px black inset borders and 54px button sizing matching `trackedicons.lua` design aesthetics.

### Bug Fixes
- **Action Usable API**: Updated `UpdateUsable` to call `C_ActionBar.IsUsableAction` to prevent nil function call runtime errors.
- **Taint Fix**: Positioned the vehicle bar via absolute screen coordinates anchored to `UIParent`, resolving `ADDON_ACTION_BLOCKED` taint errors on `SfuiIconPanel_1:Show()`.

## v12.1.0-2 (2026-08-13)

### Bug Fixes
- **Tracked Bars (Patch 12.1 Mythic+ Combat)**: Implemented direct statusbar min/max/value mirroring from Blizzard's `BuffBarCooldownViewer` to safely pass through secret values.
- **Tracked Bars (Secret Aura Data Provider)**: Ensured tracked bars remain visible during Mythic+ combat when `AURA_DATA_PROVIDER_SWITCH` fires by switching to safe sink handlers.
- **Tracked Bars (Cooldown Cast Mirror)**: Added spellcast dead-reckoning mirror for tracked cooldown bars listening to `UNIT_SPELLCAST_SUCCEEDED` to handle secret duration values in Mythic+.
- **Tracked Options**: Added guard check in `toggle_viewer()` when `SfuiDB.enableTrackingManager` is disabled.

## v12.1.0-1 (2026-07-20)

### Compatibility
- **WoW 12.1.0 PTR**: Bumped TOC interface version to `120100`.
- **Slash Command Fix**: `/sfui` and `/rl` were registered as Lua locals (`local SLASH_SFUI1`) which the WoW engine never reads. Changed to globals so both commands now work correctly.
- **Minimap Icon Fix**: Replaced the `Interface/Icons/Spell_shadow_deathcoil` icon path (unreliable in 12.x) with the addon's bundled `icon.png`, restoring the LibDBIcon minimap button.

### Bug Fixes
- **Tracked Options Window**: Fixed a crash on load (`bad argument #1 to 'SetSize'`) caused by Blizzard tightening argument validation in 12.1. `SfuiDB.trackedOptionsWindow` was pre-initialized as `{}` by the database setup, making the existence check always truthy while `width`/`height` were still `nil`. Added explicit nil-guards for both values before calling `SetSize`.
- **Match Mount**: Added a `C_Secrets.ShouldAurasBeSecret()` early-exit guard to `match_mount` in `automation.lua` so the target aura scan is skipped when aura data is restricted (e.g. in arena).

## v12.0.7-3 (2026-06-28)

### Cleanup
- **Remove Obsolete Prey Tracking**: Completely removed the redundant Prey (Midnight Expansion Season 1) hunt renown, progression tracking, and quest listener logic from `alts.lua` to clean up the Alt Tracker database and UI footprint.

## v12.0.7-2 (2026-06-28)

### Optimizations
- **Zero-Allocation Hot Path Refactoring**: Extracted high-frequency anonymous pcall closure allocations in `common.lua` (SafeGT, SafeLT, SafeArithmetic), `trackedbars.lua` (pandemic checks), and `trackedicons.lua` (visibility syncs) into static, file-scoped helpers. This completely resolves in-combat garbage collection memory jumps and micro-stutters.

## v12.0.7-1 (2026-06-28)

### Bug Fixes
- **Aura Stacks (Patch 12.0.7 Compatibility)**: Refactored `GetPlayerAuraBySpellID` check on tracked bars, tracked icons, and resource bars to safely accept and handle memory-protected **secret values** returned by the client during combat. This restores functional Bone Shield stack tracking and prevents Lua arithmetic/comparison errors from crashing the UI.
