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
