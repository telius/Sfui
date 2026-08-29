# Changelog

> **Note**: This changelog documents **releases, architectural milestones, features**.

---

## v12.1.0-8-1 (2026-08-29)

### Fixes & Improvements
- **CDM & Cooldown Viewer Management (`frames/cdm.lua`)**:
  - Fixed right-click icon removal in left-side CDM panels by properly resolving `cdID` identifiers and restoring click registration on recycled button pool instances.
  - Added right-click removal tooltips and improved spec-specific panel management.
- **Mythic+ & Delve Split Timer Stability (`frames/mythic.lua`)**:
  - Resolved `CHALLENGE_MODE_COMPLETED` nil call exception by properly invoking `UpdateInstanceState()`, `SaveCompletedRunRecord()`, and `SyncBlizzardRunHistory()`.
  - Maintained completed key HUD visibility inside instances after timer finish.
  - Zeroed out garbage churn on fallback scenario forces and gated outdoor widget events.
- **Alt Progression Currency Sync (`frames/alts.lua`)**:
  - Updated Corrosive Coin to official currency ID `3448` with backward-compatible fallback ID `3110` and dynamic icon loading.
- **Tracked Icons Out-of-Combat Optimization (`frames/trackedicons.lua`)**:
  - Added out-of-combat event throttling for power/aura updates and cached spell ID/texture lookups to prevent idle allocation spikes.

---

## v12.1.0-8 (2026-08-28)

### Major Features & Architecture
- **Complete Vehicle HUD Stack (`frames/vehicle.lua`)**:
  - Rebuilt vehicle UI with an integrated status bar stack: **Vehicle Cast Bar** (with animated spark, timer, and icon), **Vehicle Health Bar** (clean flat statusbar matching player healthbar coordinates), **Vehicle Power Bar** (resource-colored for energy, mana, steam, rage), and **6 Action Buttons**.
  - Automatic suppression of player health, power, runes, and attached tracking bars while controlling vehicles.
  - Zero-allocation 20Hz ticker with usable/range state caching and Masque button skinning support.
- **World Event & Outdoor Scenario Tracking (`frames/mythic.lua`)**:
  - Full tracking for World Events (Community Feast, Siege on Dragonbane Keep, Theater Troupe, Superbloom, Time Rifts, Radiant Echoes) and outdoor scenarios via UI Widget extraction (`TextWithState`, `StatusBar`) and criteria scanning.
- **Taint-Free Tooltip & Map Pin Architecture (`frames/quests.lua`)**:
  - Decoupled tooltips from Blizzard widget container registration, eliminating UIWidgetManager tainted arithmetic exceptions.

---

## v12.1.0-7 (2026-08-28)

### Major Features & Diagnostics
- **Interactive Memory Profiler & Pool Inspector (`frames/mem.lua`)**:
  - Added Dark Glass memory diagnostic UI accessible via `/sfmem`, `/sfui mem`, or the `/sfui` Options debug tab.
  - Features real-time allocation rate meters (`KB/s`), live GC metrics, 10s/30s benchmark runs, allocation leaderboard, and a 19-module pool & cache card inspector.
- **Zero-Allocation Hot Path Refactoring**:
  - Eliminated background memory churn across `trackedbars.lua`, `trackedicons.lua`, and `bars.lua` via static closure hoisting, table reuse, and event-driven dirty flag gating.

---

## v12.1.0-5 (2026-08-24)

### Major Features
- **Custom Quest Log & Objective Tracker (`frames/quests.lua`)**:
  - Rebuilt lightweight, custom Quest Log and Objective Tracker panel with zero-interaction isolation from Blizzard's `UIWidgetManager` and secret layout frames.
  - Non-destructive root suppression keeping Blizzard trackers untainted for Mythic+ and Delves.

---

## v12.1.0-4 (2026-08-14)

### Major Features
- **Midnight Expansion & Patch 12.1 Research Trees (`frames/research.lua`)**:
  - Added tree definitions for Altar of Corrosion, Omnium Folio, Valeera Delve Seasons 1 & 2, Zul'Aman Loa Blessing, Coiled Isle, Atal'Utek Vaults, and Delve Companion systems.
- **Midnight Currencies & Alt Progression (`frames/alts.lua`)**:
  - Integrated Mistcrests, Spark of Tides, Venomblight Manaflux Catalyst, Corrosive Coins, and Midnight profession knowledge point tracking.

---

## v12.1.0-1 (2026-07-20)

### Major Features & Compatibility
- **WoW 12.1.0 Compatibility**:
  - Updated TOC interface to `120100` and modernized global slash commands and minimap button integration.

---

## v12.0.7-1 (2026-06-28)

### Major Architecture
- **Secret Value & Taint Hardening (Patch 12.0.7)**:
  - Hardened aura stack counters, statusbars, and combat tickers against client-restricted secret values, preventing tainted arithmetic and comparison failures during combat.
