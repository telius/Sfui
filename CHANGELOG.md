# Changelog

> **Note**: This changelog documents **releases, architectural milestones, features**.

## v12.1.0-25 (2026-09-02)

### Architecture & Features
- **Centralized Seasonal Architecture (`season.lua`, `sfui.toc`)**:
  - Introduced root database `sfui.season` for Midnight Season 2 (Patch 12.1) loaded ahead of core and frames.
  - Centralized seasonal currencies (Mistcrests, Spark of Tides, Tidal Spark Dust, Catalysts, Coffer Keys, Voidcores, Accolades, Pearls, Particles).
  - Centralized all 14 weekly quests (Unity, Abundance, Legends, Runestones, Stormarion, Surges, Special Assignments, World Boss, Bounty Map, Gilded Delve Stash, Prey, Void Assaults, Bonus Event, Timewalking Raid).
  - Centralized all 11 profession knowledge point sources (`PROF_KP_SOURCES`) with weekly quests, treatises, gatherable/treasure drops, catchup currency IDs, and Midnight skillLine mappings (2903–2913).
  - Centralized Great Vault item level baselines (279–318) and color-coded upgrade tracks (`Myth 1/6`, `Hero 4/6`, `Champion 1/6`, `Veteran 1/6`).
- **Alts Window Optimization & Spark Progression (`frames/alts.lua`)**:
  - Refactored `alts.lua` to source currencies, weekly quest pools, profession KP data, and Great Vault baselines directly from `sfui.season`, removing over 160 lines of static tables and redundant branching.
  - Added **Tidal Spark Dust** (Currency `3509`) tracking alongside **Spark of Tides** (Item `274476`). Displays bag count and seasonal earned vs cap (`earned/max`) with color status (green = caught up, orange = partial, red = 0 earned).
  - Fixed group tooltip rendering where `tLine.count` and `max` were unpopulated.
- **LFG Dungeon Auto-Select Automation (`frames/automation.lua`, `frames/options.lua`)**:
  - Added `lfgDungeonMythicKeystoneCompetitive` automation setting.
  - Automatically pre-selects **Mythic Keystone** difficulty and **Competitive** playstyle when creating a dungeon group in Group Finder (`LFGListEntryCreation_Show`).
- **Blizzard Cooldown Viewer Suppression Hardening (`common.lua`, `core.lua`, `frames/mem.lua`)**:
  - Suppressed all 4 Blizzard Cooldown Viewers (`EssentialCooldownViewer`, `UtilityCooldownViewer`, `BuffIconCooldownViewer`, `BuffBarCooldownViewer`).
  - Evicted viewers from `BottomManagedFrameContainer.showingFrames` and set `ignoreFramePositionManager = true`.
  - Hooked `SetAlpha` to re-assert `0` against Blizzard animations.
  - Hooked `CinematicFrame:OnHide`, `MovieFrame:OnHide`, `"CinematicFrame.CinematicStopped"`, `"UI.TopLevelParentShown"`, and challenge mode start/reset events.
  - Added `blizz hidden: yes/no` live telemetry to `frames/mem.lua`.

---

## v12.1.0-24 (2026-09-02)

### Features & Fixes
- **Player Housing Quest Log Visibility (`common.lua`, `frames/quests.lua`, `frames/mythic.lua`)**:
  - Added `sfui.common.is_housing_zone()` multi-tier detection supporting Midnight player housing (`C_Housing` API checks and zone/neighborhood name matching for Razorwind Shores, Founder's Point, houses, and plots).
  - Prevented player housing instances from falsely hiding the quest log or triggering dungeon/scenario HUD takeovers.
- **Login Gear Equip & Chat Spam Fix (`frames/gear.lua`, `frames/highest.lua`)**:
  - Tracked `lastSpecID` in `handle_spec_change()` so initial `TRAIT_CONFIG_UPDATED` talent events on login/reload no longer trigger fake spec swaps or forced re-equip cycles.
  - Settle delay increased to 2 seconds on login/reload (`PLAYER_ENTERING_WORLD`) to allow Blizzard equipment sets and item stats to fully populate from the server.
  - Added strict `and not silent` guards to item swap prints in `equipNext()` (`frames/highest.lua`), ensuring automated/background updates run 100% silently while preserving manual click feedback.
- **PaperDoll Slot Locking Shortcut (`frames/gear.lua`)**:
  - Updated paperdoll item lock toggle to **Shift + Left-Click** (avoiding conflict with Blizzard's Shift + Right-Click item socketing panel).

---

## v12.1.0-23 (2026-09-02)

### Combat Hardening & Diagnostics
- **CooldownViewer & LayoutFrame Taint Prevention (`common.lua`, `frames/trackedbars.lua`)**:
  - Replaced intrusive `Hide()` and `UnregisterAllEvents()` on Blizzard's `CooldownViewer` layout frames with clean `SetAlpha(0)` and `EnableMouse(false)`.
  - Removed per-tick `SetAlpha` calls from `UpdateBarsState()` 60 FPS loop, completely eliminating `LayoutFrame.lua:491` and `FrameUtil.lua:223` secret number comparison taint errors in combat.
- **CDM Category Safety (`frames/cdm.lua`)**:
  - Sanitized category ID resolution in `RenderAssignmentsIconPool` and reverse lookup to guarantee valid non-negative numbers (`0` Essential, `1` Utility, `2` Buffs, `3` Tracked Bars).
  - Protected all `C_CooldownViewer.GetCooldownViewerCategorySet` calls with range checks and `pcall` guards.
- **Combat Equipment Protection (`frames/highest.lua`)**:
  - Added `InCombatLockdown()` check to abort automated item swaps during combat, preventing `[ADDON_ACTION_BLOCKED] EquipCursorItem()` errors.
- **Memory Diagnostics Expansion (`frames/mem.lua`, `dispatcher.lua`)**:
  - Added real-time telemetry tracking for central event dispatcher (`sfui.dispatcher_debug_info`).
  - Added module telemetry for all remaining sub-systems (`currency`, `lootspec`, `location`, `cdm`, `research`).

---

## v12.1.0-22 (2026-09-01)

### Architecture & Modernization
- **Dispatcher & Event System Consolidation**:
  - Migrated modules across the entire addon to native `RegisterEvent`, `RegisterUnitEvent`, and `RegisterThrottledEvent` via `dispatcher.lua`.
  - Replaced redundant closure generation and pcall layers with clean direct API calls and secret value safety checks.
  - Hardened dynamic frame pools and table reuse across tracking bars, quests, and class HUDs for zero combat allocation.

---

## v12.1.0-21 (2026-09-01)

### Castbars Optimization & Secret Value Hardening
- **Castbar Architecture Refactor (`frames/castbar.lua`)**:
  - Removed legacy interrupt marker and cooldown tracking logic (`CLASS_INTERRUPTS`, `knownInterrupts`, positioners, markers).
  - Target castbar optimized to use Blizzard's C-engine `SetTimerDuration` duration animation without Lua `OnUpdate` polling loops.
  - Safely evaluated Retail 12.x secret boolean `notInterruptible` via `C_CurveUtil.EvaluateColorValueFromBoolean`, completely preventing secret value taint crashes.
  - Implemented zero-allocation telemetry table for `mem.lua` profiler queries (`sfui.castbar_debug_info`).
  - Added memoized instant-cast spell detection with automatic invalidation on talent/spec updates.
  - Fully standardized with `common.lua`, `dispatcher.lua`, `config.lua`, and `core.lua`.

---

## v12.1.0-20 (2026-08-31)

### Raid Quest Tracking & Objectives
- **Active Raid Quest Detection (`frames/quests.lua`)**:
  - Implemented `HasRaidQuest()` and `IsRaidQuest()` detection in `State:Update()`.
  - SFUI Quest Log now stays visible inside raid instances if the player holds active raid quests (e.g. raid skip quests, story/boss kill quests, raid map objectives), while cleanly hiding when no raid quests are tracked.
  - Automatically filters out unrelated outdoor world quests and bonus objectives when inside a raid instance.

### Loot Spec Manager Enhancements
- **Debounced Asynchronous Swaps (`frames/lootspec.lua`)**:
  - Added `pendingSpec` asynchronous state tracking and `PLAYER_LOOT_SPEC_UPDATED` listener to eliminate duplicate restoration chat messages when leaving instances.
- **Improved Dungeon & M+ Entry Detection (`frames/lootspec.lua`)**:
  - Upgraded `GetActiveDungeonSpec()` to cross-reference Challenge Mode season map tables by instance name and map ID, ensuring spec swaps trigger reliably upon entering dungeons as well as when the timer starts.
- **Core Architecture & UI Integration (`frames/lootspec.lua`, `core.lua`)**:
  - Initialized `SfuiDB.lootspec` in `core.lua` master load routine.
  - Deduplicated `GetSpecColor()` helper and bound UI styling to `sfui.config.appearance` tokens and `sfui.pixelScale` responsive height clamping.

---

## v12.1.0-19 (2026-08-31)

### Quest Log & Group Finder
- **Native LFG Quest Search Integration (`frames/quests.lua`)**:
  - Adopted Blizzard's native `QuestObjectiveFindGroupButtonTemplate` and mixin for the tracker's group finder eye button.
  - Bound `questID` attribute directly to allow native Blizzard mixin execution, enabling instant automated group searching and creation without `ADDON_ACTION_BLOCKED: Search()` errors.
  - Fully compatible in and out of combat.

- **Map Pin Passthrough Protection (`frames/quests.lua`)**:
  - Deferred `QuestMapFrame_OpenToQuestDetails`, `OpenWorldMap`, and `ToggleWorldMap` out of the user click stack via `C_Timer.After(0)`.
  - Prevents Blizzard `MapCanvas` and `QuestDataProvider` from executing inside an insecure addon stack, resolving the `Button:SetPassThroughButtons()` action block.

---

## v12.1.0-18 (2026-08-31)

### CI & Distribution
- **Fixed WowUp Release Asset Matching (`.github/workflows/release.yml`)**:
  - Removed `-n sfui` zip name override from BigWigs Packager.
  - Releases now generate standard `{package-name}-{version}.zip` (e.g. `sfui-v12.1.0-18.zip`), allowing WowUp's GitHub provider to correctly extract and match the version string instead of displaying `sfui.zip`.
  - Addon contents remain properly encapsulated in the `sfui/` folder via `package-as: sfui` in `.pkgmeta`.

---

## v12.1.0-17 (2026-08-31)

### Major Improvements & Taint Elimination
- **Blizzard UIWidget Taint & Secret Value Crash Elimination (`common.lua`, `frames/quests.lua`, `frames/minimap.lua`)**:
  - Replaced shared global `_G.GameTooltip` references across all SFUI modules with dedicated, isolated `SfuiGameTooltip` (`CreateFrame("GameTooltip", "SfuiGameTooltip", UIParent, "GameTooltipTemplate")`), preventing UIWidgetManager execution context taint.
  - Eliminated `ObjectiveTrackerFrame:HookScript("OnShow")` in favor of pure alpha/mouse suppression.
  - Eliminated `Minimap:GetChildren()` / `MinimapCluster:GetChildren()` scanning and method monkeypatching in `ButtonManager`, preventing Blizzard `AreaPOIPinTemplate` and Delve map pins from being hooked or modified.
- **Robust Minimap Button Collection (`frames/minimap.lua`)**:
  - Added direct `ldbi.objects` enumeration and `LibDBIcon:Register` dynamic hook to reliably collect and arrange LibDataBroker minimap buttons (WeakAuras, Details, Raider.IO, BugSack, MRT, Simulationcraft, etc.).
  - Added explicit whitelist (`KNOWN_ADDON_BUTTONS`) and refined Blizzard core frame prefix filtering (`BLIZZARD_IGNORE_PREFIXES`).
  - Added combat lockdown protection (`pendingArrange`) and automatic post-combat layout flushing on `PLAYER_REGEN_ENABLED`.
  - Removed legacy unused `SfuiMinimapFrame` allocation.

---

## v12.1.0-16 (2026-08-30)

### Versioning & Distribution
- **Aligned TOC Versioning with Release Tags (`sfui.toc`)**:
  - Aligned TOC `Version` tag format to standard `v<WoWVersion>-<Release>` (e.g. `v12.1.0-16`).
  - Ensures WowUp, CurseForge, and Wago display matching version strings across local installations and remote releases.

---

## v12.1.0-15 (2026-08-30)

### CI & Release Distribution
- **WowUp & Addon Manager Update Tracking (`.github/workflows/release.yml`)**:
  - Preserved continuous GitHub Releases history by removing destructive release pruning.
  - Ensures WowUp, CurseForge, Wago, and third-party addon managers retain valid release IDs, version progression, and automated update notifications.

---

## v12.1.0-14 (2026-08-30)

### Architecture & Central Event Dispatcher
- **Unified Event Subsystem (`dispatcher.lua`)**:
  - Implemented centralized event dispatcher (`sfui.events`) handling all global game events, unit events (`RegisterUnitEvent`), throttled events (`RegisterThrottledEvent`), and frame update loops (`RegisterUpdate`) across 20+ addon modules.
  - Replaced fragmented standalone frames and OnUpdate scripts with a single central event router and unified 0-CPU idle ticker.
  - Added module routing index and architecture reference directly in the dispatcher header.

### Major Improvements & Bug Fixes
- **Direct API Forwarding for Mythic+ Forces (`frames/mythic.lua`)**:
  - Aligned Mythic+ enemy forces calculation and criteria handling with the clean direct API forwarding pattern from `MPlusTimer`.
  - Added robust detection for raw mob count criteria, 0.1% resolution (`totalQuantity == 1000`), and localized objective keywords without `pcall` arithmetic taint.
- **Blizzard UI Taint Prevention (`frames/minimap.lua`, `frames/quests.lua`, `frames/mythic.lua`)**:
  - Resolved `[ADDON_ACTION_BLOCKED] Button:SetPassThroughButtons()` by strictly filtering Blizzard MapCanvas / DataProvider pins out of Minimap button collection.
  - Fixed `UIWidgetManager` secret arithmetic crashes (`textHeight` / secret value) by replacing direct container frame table lookups with official `C_UIWidgetManager` C-APIs.
  - Replaced `ShowUIPanel(WorldMapFrame)` calls with `QuestMapFrame_OpenToQuestDetails` and `OpenWorldMap()` to prevent `UIParentPanelManager` state table taint.
- **Performance Optimizations & Memory Management**:
  - Added pre-computed lookup tables (`INT_STR_LUT` for 0–200, `DEC_STR_LUT` for 0.1–5.0s) in `common.lua` to eliminate runtime string churn.
  - Converted minimap menu and mount speed bar scripts to zero-allocation static passes.
  - Cleaned up dead frame allocations and lifted nested inner functions (`CheckPandemicState`) in `frames/trackedbars.lua`.

---

## v12.1.0-13 (2026-08-30)

### Features & Major Improvements
- **Devourer Demon Hunter Void Metamorphosis HUD (`frames/class/soulfragments.lua`, `config.lua`)**:
  - Implemented standalone dual-phase **Void Metamorphosis** HUD bar for Devourer Demon Hunter:
    - *Out of Form*: Tracks *Dark Heart* stacks ($0\rightarrow 50$, or $35$ with *Soul Glutton*) in Azure (`#008dbe`), switching to radiant gold (`#edcd4e`) with `META READY` indicator at trigger threshold.
    - *In Form*: Tracks active *Void Metamorphosis* duration timer and *Collapsing Star* build ($0\rightarrow 30$) in Astral Cosmic Blue (`#0066ff`).
  - Added dynamic vertical dual-bar stacking system anchored flush above player health bar with tracked aura bars stacked above.
  - Added Dynamic Moment of Craving (MoC) 10-soul reap threshold indicator and overcap warning state backdrops.
  - Seamless flat bar styling without cell dividers, and proper text layering above status bar textures.
- **Decoupled Demon Hunter Resources (`frames/bars.lua`, `frames/trackedbars.lua`)**:
  - Cleaned up core unit frames and secondary power bar logic, isolating Demon Hunter resource management exclusively into `soulfragments.lua`.
- **Gear Optimization & Weapon Scoring (`frames/highest.lua`)**:
  - Fixed hybrid 1H weapon (axes, swords, fist weapons) stat mapping: primary stats dynamically map to active spec stat (Agility/Strength/Intellect), preventing shared weapons from receiving 0 main stat score under Pawn/stat weighting.
  - Implemented heavy item level prioritization on Weapon slots ($\times 1000$ base multiplier), ensuring high-ilvl weapons (e.g. 298 vs 259/276) properly outrank lower-ilvl items due to Weapon DPS scaling.
  - Fixed dual-wielding duplicate non-unique weapons when main hand is locked.
  - Added locale-independent primary stat tooltip evaluation using Blizzard's localized constants.

---

## v12.1.0-10 (2026-08-29)

### Fixes & Improvements
- **Scenario & World Event Weighted Progress (`frames/quests.lua`, `frames/mythic.lua`)**:
  - Prioritized weighted progress detection over raw count comparisons, ensuring percentage-based scenario criteria (e.g. "Cull the Brood") render as full progress bars instead of raw count fractions (`68/1000`).
  - Added robust scaling support for Blizzard's `1000`-point criteria weighting in both Quest Log and Mythic/Dungeon forces trackers.
- **Delve Nemesis Counter Display (`frames/mythic.lua`)**:
  - Changed Nemesis counter completion display to consistently show numeric ratio `4/4` instead of `"Done"`.

---

## v12.1.0-9 (2026-08-29)

### Features & Major Improvements
- **Meta Quests Classification & Header (`frames/quests.lua`, `config.lua`)**:
  - Added a dedicated `meta` section positioned directly below `campaign` for all meta quests (`QC_Meta` / `IsMetaQuest`).
  - Added meta quests section configuration with distinct cyan tinting (`0.0, 1.0, 1.0`).
- **Comprehensive World Event Scenario & Widget Tracking (`frames/quests.lua`)**:
  - Full support for outdoor world events (such as Dundun, Dunelle's Kindness / Abundance event, Community Feast, Theater Troupe, Superbloom, Time Rifts).
  - Automated extraction of scenario countdown timers (`ScenarioHeaderTimer`, criteria durations) with bright cyan clock badges.
  - Complete support for event status and progress bars (`StatusBar`, `DoubleStatusBar`, `FillUpFrames`, `DiscreteProgressSteps`, `CaptureBar`) with formatted value text (e.g. `450/1000 (45%)`).
  - Exhaustive coverage of all `UIWidgetManager` visualization types (`BulletTextList`, `TextWithState`, `TextWithSubtext`, `TextureAndText`, `HorizontalCurrencies`, `StackedResourceTracker`, `IconTextAndCurrencies`).
  - Added bonus steps scanning via `C_Scenario.GetBonusSteps()`.
- **Strict Separation Between Quest Log & Mythic/Delve HUD (`frames/quests.lua`, `frames/mythic.lua`)**:
  - Enforced strict state isolation so `quests.lua` never renders Delves, Dungeons, Raids, or Mythic+ content handled by `mythic.lua`.
  - Unconditional suppression of Blizzard's default Objective Tracker across scenario/delve completions and stage transitions.
- **Midnight Secret Values Taint Fixes (`frames/mythic.lua`)**:
  - Direct pass-through of secret strings and numbers to native UI elements without invalid Lua comparisons or arithmetic.
  - Guarded spell descriptions, tooltips, and delve badge metrics against secret value taint errors in WoW 12.0/Midnight.

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
