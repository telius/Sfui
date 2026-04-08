## v0.6.2 (2026-04-08)

### Features
- **API (12.0.5+)**: Upgraded `is_restricted_content()` in `portals.lua` to use `C_Secrets.ShouldCooldownsBeSecret()` as the primary secrecy gate, covering battlegrounds, arenas, active M+ runs, and raid encounter phases in one authoritative engine call.
- **API (12.0.5+)**: Upgraded spell cooldown display in `portals.lua` to use `C_Spell.GetSpellCooldownDuration` (LuaDurationObject), whose `GetRemainingDuration()` returns a plain taint-free number, eliminating field-level secret value crashes.
- **API (12.0.5+)**: Upgraded pandemic bar detection in `trackedbars.lua` to use `C_UnitAuras.GetAuraBaseDuration` + `C_UnitAuras.GetAuraDuration` for a clean arithmetic-free 30% threshold calculation. Text-parse retained as fallback for older builds.
- **API (12.0.5+)**: Added `C_Secrets.HasSecretRestrictions()` fast early-exit to `issecretvalue()` in `common.lua`, short-circuiting the pcall arithmetic probe when no restrictions are active.
- **Gear Manager**: Registered `PLAYER_EQUIPMENT_CHANGED` event to immediately bust the equipment-set cache when any slot changes, closing the spec-swap gear lag window (e.g. Frost→Unholy DK).
- **Gear Manager**: `SPEC_INVOLUNTARILY_CHANGED` (arena PvP loadout lock, system talent reset) now triggers the same gear+UI refresh as `PLAYER_SPECIALIZATION_CHANGED`.
- **Spec Cache**: Added `C_SpecializationInfo.IsInitialized()` guard to `update_cached_spec_id()` to prevent caching an invalid 0 spec ID on early login frames.

## v0.6.1 (2026-04-07)

### Features
- **UI Colors**: Unified PvE and PvP lock feature colors across UI elements, text, and tooltips to ensure consistent conceptual styling.
- **Gear Manager**: Changed `Force 4-Set` behavior in the automatic equip engine to be implicitly enabled by default for all spaces unless explicitly overwritten by the user.

### Bug Fixes
- **Auto Repair**: Updated the master hammer perk detection to dynamically validate all active expansion profile nodes simultaneously, fixing an issue where players crossing into the Midnight expansion would have outdated skill caches suppressing their repair popup. 
- **Configuration**: Stripped several unused block headers and condensed spacing arrays during config serialization.

## v0.6.0e (2026-04-06)

### Features
- **Documentation**: Added documentation and visual previews for the Alts Manager, Cooldown Manager (CDM), and Portals framework to the README overview.

### Bug Fixes
- **Gear Manager Pawn Strings**: Fixed an issue where importing a Pawn string containing non-secondary stats (like Dps or Stamina) would cause the UI stat priority buttons to incorrectly display random characters ("D S O M").

## v0.6.0d (2026-04-05)### Bug Fixes
- **Print Formatting**: Removed redundant `SFUI:` and `sfui:` string prefixes from print statements across all core frames to prevent double prefixes.
- **Gear Manager**: The "Auto Equip at Max Level" toggle now instantly triggers an item re-evaluation when enabled instead of waiting for the next inventory event.

## v0.6.0b (2026-04-03)
### Bug Fixes
- **Tracked Bars/Icons Scoping**: Resolved a widespread scoping issue across tracked bars and their options (`trackedbars.lua`, `trackedoptions.lua`) where dynamically spawned frames were incorrectly evaluating shadowed cfg variables for textures and colors, triggering silent UI errors that prevented tracking bars from visually populating.

## v0.6.0a (2026-04-01)

### Features
- **Pandemic Window Recoloring**: Tracked debuff bars now shift color during the pandemic window (final 30% of duration), with configurable recolor settings. Duration is parsed from the bar's display text and max duration is cached per-aura for accurate ratio detection.
- **Mythic+ Tracking Improvements**: Enhanced mythic plus cooldown tracking with improved reliability, added spec tab auto-selection in the gear manager, and updated Augmentation Evoker color configuration.
- **Primary Stat Detection**: Improved primary stat detection for dynamic items to correctly evaluate gear upgrades across all specializations.

### Refactoring
- **Code Standardization**: Standardized string casing and applied consistent code formatting across core and gear modules.

## v0.5.4a (2026-03-28)

### Features
- **Portals Framework**: Reorganized legacy portals into distinct continent-based categories (Eastern Kingdoms, Kalimdor, Pandaria, etc.) instead of by expansion. Corrected geographic locations for various dungeons and operations (e.g., Castle Nathria, Liberation of Undermine). Ordered the Wormhole toys to prioritize newer expansions first.
- **Portals State**: Portals frame now persistently remembers its exact multi-axis anchor points rather than flat coordinates across sessions and UI scales.
- **Alts Tracking (Great Vault)**: Implemented Great Vault reward parsing using `C_WeeklyRewards.HasAvailableRewards()`. The Alts Vault panel will now actively feature a golden glowing overlay around unlocked slots and render a tooltip alert when a character has an unclaimed vault reward ready.

### Bug Fixes
- **Merchant Taint Error**: Resolved a UI-breaking Lua crash (`attempt to perform string conversion on a secret string value`) occurring when inspecting vendor tooltips inside protected instance boundaries. Migrated the tooltip parsing function to evaluate strings securely under `pcall` buffers.
- **Resource Bars**: Fixed a UI issue where the irrelevant mana bar was visible for Elemental Shamans. Re-pointed the configuration to hide mana via the `secondaryPowerBar` block architecture naturally corresponding to Maelstrom-primary specs.

### Documentation
- **Gear Manager**: Expanded inline code documentation clarifying the mechanical necessity behind the 2-second execution lock ("debounce timer") on the `BAG_UPDATE_DELAYED` core inventory event.

## v0.5.3 (2026-03-25)

### Bug Fixes
- **Alts Vault Sync Bug**: Fixed a bug where recently completed Mythic+ runs would not immediately reflect in the Alts window. Integrated explicit background server polling (`C_WeeklyRewards.OnUIInteract`) specifically triggering upon `CHALLENGE_MODE_COMPLETED` and the primary UI `Toggle()`, forcing Blizzard servers to asynchronously push updated Great Vault data down to the client dynamically before executing local synchronization arrays.
- **Mythic+ Cooldown Tracker**: Resolved a critical zero-hour API break in WoW Patch 12.0.1 where Blizzard restricted Secret Value assignments behind `LuaDurationObject` validation. Migrated the tracker to natively execute `SetCooldownFromDurationObject`, strictly bypassing local duration math and executing cleanly via the new C++ API boundary without tainting the UI.

## v0.5.1 (2026-03-21)

### Features
- **Automatic Gear Swapper**:
    - Added a dedicated, floating Gear Manager window accessed via a new button on the Character panel.
    - Supports multi-spec gear profiles (independent PvE and PvP configurations per specialization).
    - Includes dual "Equip Highest" utilities to scan inventory and optimize equipped ilevels.
    - Added an options checkbox to optionally disable auto-tracking alongside the Character panel.

### Bug Fixes
- **Gear Manager Combat Desyncs**: Implemented deferred equipment queues and increased server-sync delays to 3 seconds. This fixes a bug where entering a Battleground or Arena with a "Preparation" buff would silently block the automatic PvP gear swap sequence.
- **WQS Map Ping**: Re-parented the World Quest highlight ring dynamically to the Viewport Canvas instead of the static WorldMapFrame, restoring accurate coordinate tracking when the map zoom scale changes.
- **Alts Great Vault (Delves)**: Corrected the Vault color logic to appropriately scale Delve completions based off of a Tier 8 (Mythic) reward cap instead of the +10 Tier fallback array used by M+ Dungeons.

## v0.5.0 (2026-03-13)

### Features
- **Hero Talent UI Overhaul**: Implemented robust name and icon resolution for overrides. Corrected spec discovery logic using Blizzard v12.0.1 source.
- **Alts UI Refinement**:
    - Reduced weekly quest grid to 4 blocks (Abundance, Legends, Runestones, Stormarion).
    - Updated currency tracking: Added Shard of Dundun (Dumdum) and Restored Coffer Key; removed lower-tier Dawncrests.
    - Improved usability: Alts panel can now be closed with the Escape key.

### Bug Fixes
- **CDM Resolution**: Resolved "Unknown" labels for spells and items in the Tracking Manager.
- **Filter Icons**: Fixed a bug where hero talent filter icons were missing in the overrides list.

## v0.4.4 (2026-03-10)

### Features
- **Detachable WQS Panel**: The World Quest Summary frame can now be unpinned from the World Map, dragged freely, and its position is saved persistently.
- **Dynamic WQS Sizing**: The frame now automatically adjusts its height based on the number of active quests.
- **Improved Cursor Ring**: Re-optimized for pixel-perfect tracking on high-refresh displays.

### Performance & Audit
- **Comprehensive Frames Audit**: Conducted a full performance review of all 20 frame modules, ensuring strictly event-driven or throttled update logic.
- **Transient Event Listeners**: Implemented temporary event registration for the Master's Hammer; the addon now only monitors spellcasts while a repair is active, ensuring zero background overhead during regular play.
- **Throttling Optimizations**:
    - Mount Speed Bar: Optimized to 20Hz (0.05s).
    - Cooldown Manager: Dynamic 20Hz (active) / 1Hz (idle) throttles.
- **Performance Manifest**: Added `docs/calls.txt` to document and monitor all high-frequency API interactions.

### Core Improvements
- **Event System Expansion**: Added `UnregisterEvent` to the central event manager to support transient module listeners.
- **API Localization**: Completed localization of math and string libraries across the entire `frames/` directory.

## v0.4.3 (2026-03-07)

### Features
- **Alts Background Syncing**: Character data now updates in the background upon level-up, profession changes, and equipment updates without requiring the UI to be open.
- **Safe Logout Synchronization**: Restored logout triggers with robust validation guards, ensuring final session data is saved safely during the logout sequence.

### Optimizations
- **Memory Pooling Architecture**: Implemented a comprehensive `tablePool` system in `alts.lua` to eliminate garbage collection (GC) pressure via object recycling.
- **Efficient Frame Acquisition**: Optimized UI updates to avoid redundant object creation and temporary table allocations when iterating over frame regions.
- **Smart Stance/Form Anchoring**: Tracked icons now intelligently detect mana/resource bar visibility, automatically shifting position to avoid overlapping UI elements.

### Bug Fixes
- **Alts Data Persistence**: Fixed a critical issue where character level and professions were being cleared on logout.
- **Respec Icon Cleanup**: Resolved a bug where icons from a previous specialization remained visible after switching specs.
- **API Errors**: Fixed "AcquireTable nil" scope error and corrected invalid `PLAYER_AVG_ITEM_LEVEL_READY` event registration.

## v0.4.2 (2026-03-06)

### Optimizations
- **Alts Background CPU Usage**: Added panel-aware sync throttling in `alts.lua`. Background synchronization now correctly defers execution unless the UI is actively open, preventing unnecessary 1-second interval execution during gameplay.
- **UI Update Polling**: Eliminated an infinite CPU update leak in `cdm.lua` caused by the drag-and-drop ghost cursor.
- **Quest Tracking Throttle**: `prey.lua` now actively throttles `QUEST_ACCEPTED` and `QUEST_REMOVED` events to the same 1-second debounce as log updates, preventing unthrottled UI recalculations during gameplay.

### Bug Fixes
- **Alts Dropdown Interactivity**: Fixed an issue where the Character Manager and Section Manager dropdown toggles (Hide/Show) in `alts.lua` were unresponsive and overlaying duplicate font strings due to a recycling bug.

## v0.4.1 (2026-03-06)

### Features
- **Merchant UI Refactor**: Completely rebuilt the merchant frame into a **2-column vertical scrolling list**. Replaced paged navigation with intuitive row-by-row scrolling.
- **Improved Merchant Frame**: Adjusted dimensions (425x620) for a cleaner list view, fitting 20 items per view with a vertical scrollbar.
- **Alts UI Profession Tracking**: Integrated standalone weekly Knowledge Point tracking for The War Within and Midnight expansions.
- **Profession Display**: Tracks Treatises, Weekly Quests, and Treasures/Drops. Shows skill level, done/total progress, and detailed tooltips.
- **Dynamic Alts Frame Sizing**: Frame height naturally shrinks/expands when categories in the sidebar are collapsed/expanded.

### Optimizations
- **Frame-Rate Stability**: Implemented frame-level debouncing for `Prey` and `Alts` UI updates, eliminating redundant redraws during high-frequency events.
- **EJ Data Caching**: Cached Encounter Journal (EJ) lookups in `alts.lua` for significant performance gains when syncing multiple characters.
- **Resource Management**: Localized and cached character-specific data within synchronization loops to minimize API overhead.

### Bug Fixes
- **Alts Grid Collision**: Fixed a rendering bug where M0 grid icons and Vault slots would overlap.
- **C_Timer Linting**: Standardized `C_Timer` references across all frames to prevent potential script errors.

## v0.4.0 (2026-03-05)
- **Comprehensive Code Audit**: Addressed multiple core execution bottlenecks to stabilize baseline memory footprint.
- **UI Element Pooling**: Rewrote dropdown menus to reuse elements natively, eliminating a persistent memory leak.
- **Event Debouncing**: Throttled high-frequency events like `QUEST_LOG_UPDATE` for the Prey tracker.
- **Resource Caching**: Implemented a per-tick cache for cooldown APIs, reducing `pcall` barrage down to one call per unique ID per cycle.
- **Memory Management**: Hoisted allocations and reused stable tables across the Merchant, Minimap, and Options modules.
