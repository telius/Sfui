## v12.0.7-4 (2026-07-20)

### Bug Fixes
- **Slash Command Fix**: `/sfui` and `/rl` were registered as Lua locals (`local SLASH_SFUI1`) which the WoW engine never reads. Changed to globals so both commands now work correctly.
- **Minimap Icon Fix**: Replaced the `Interface/Icons/Spell_shadow_deathcoil` icon path (unreliable in 12.x) with the addon's bundled `icon.png`, restoring the LibDBIcon minimap button.
- **Tracked Options Window**: Fixed a crash on load (`bad argument #1 to 'SetSize'`) caused by Blizzard tightening argument validation. `SfuiDB.trackedOptionsWindow` was pre-initialized as `{}` by the database setup, making the existence check always truthy while `width`/`height` were still `nil`. Added explicit nil-guards for both values before calling `SetSize`.
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

## v0.8.0 (2026-05-24)

### Features
- **Project-Wide Event Unification**: Consolidated all local module event frames (`bars.lua`, `castbar.lua`, `currency.lua`) into the centralized global `sfui.events` dispatcher. This significantly reduces overall Frame memory footprint and unifies event handling loops under a single error-trapped pcall boundary.
- **Out-of-Combat Haste Caching**: Implemented a caching system for casting bar spell haste. In combat, when stats are secret under Blizzard's `C_Secrets` restrictions (making `UnitSpellHaste` return a secret value that crashes mathematical operations), the castbar now safely falls back to the cached out-of-combat haste instead of disabling the instant castbar entirely.
- **Robust PLAYER_LOGIN Dispatch**: Modernized `sfui.events.RegisterEvent` in `common.lua` to check `IsLoggedIn()` and immediately execute the callback if true. This guarantees that during UI reloads (`/reload`), late loads, or dynamic loads, login callbacks across all modules run reliably, resolving race conditions and ensuring casting bars and trackers initialize correctly.

### Optimizations
- **O(1) Snapshot Scanning**: Eradicated the performance anti-pattern of calling `select(i, GetChildren())` and `select(i, GetRegions())` inside loops in `alts.lua`, `portals.lua`, and `minimap.lua` (which re-evaluates the children list and calls the C-API $N$ times). Replaced with flat, single-pass snapshot tables (`local children = { f:GetChildren() }`), reducing C-to-Lua boundaries by over 90% and completely eliminating UI stutters.
- **CDM Zero-Allocation Hot Paths**: Refactored Cooldown Manager (`cdm.lua`) interaction handlers to use pre-defined file-scope helpers and one-time pools hook registration instead of dynamic anonymous closure allocations.
- **Settings Panel Tab Caching**: Implemented control states caching for the settings panel (`trackedoptions.lua`), preventing dynamic frame recreation when switching editor tabs.
- **Bank Transfer Queue Halting**: Programmed automated queue cancellation and transfer ticker halting in `transfer.lua` upon bank frame closure, removing zombie background scanners.
- **Obsolete Hotkeys Eradication**: Completely removed `hotkeys.lua` and its settings widgets from the addon, reducing drawing and event overhead.

## v0.7.3 (2026-05-17)

### Features
- **Location Reminder**: Added support for monitoring groups you create yourself in the LFD tool. The addon now seamlessly registers and watches your roster when you list a Mythic+ keystone group, triggering the same "GROUP FILLED" reminder.

### Optimizations
- **Event Multiplexer**: Modernized `gear.lua` to fully utilize the shared `sfui.events` multiplexer, removing monolithic event frames and improving modularity and performance.
- **Bag Scanning**: Standardized bag iteration limits in `automation.lua` and `highest.lua` to scan up to index 5 (inclusive of the Reagent Bag) across the board, ensuring no valid gear or items are missed.
- **Automation**: Pruned a dead-code `MERCHANT_CLOSED` event listener.

## v0.7.2c (2026-05-13)

### Bug Fixes
- **Location Reminder**: Fixed an issue where the trailing "ff" in color formatting codes caused literal "ff" characters to display in chat. Additionally, replaced unsupported Unicode symbols (★ and →) with standard text and WoW chat icons to prevent unprintable square boxes.

## v0.7.2b (2026-05-12)

### Bug Fixes
- **Alts Tracker (Time Played Spam)**: Completely re-architected the "Time Played" chat message suppression engine. Previously, `ChatFrameUtil.DisplayTimePlayed` was hooked directly, which leaked messages if the player had multiple chat tabs with the "System" message group enabled, since the event dispatched independently per chat frame. Suppression is now handled robustly via a `customEventHandler` injected into every chat window, consuming the `TIME_PLAYED_MSG` payload before it reaches the Blizzard UI dispatch chain.

## v0.7.2a (2026-05-05)

### Features
- **Location Reminder**: The addon now proactively prints a "Keystone invite received" chat message when the invitation popup appears, allowing you to easily verify the dungeon name and key level before clicking Accept.

### Bug Fixes
- **Location Reminder**: Fixed a severe logic flaw where protected Mythic+ payload properties (key level, leader name) triggered arithmetic taint errors, causing the module to crash silently.
- **Location Reminder**: Corrected a parameter shift bug caused by the SFUI event multiplexer where the event payload was misaligned, entirely preventing the module from successfully polling LFG search result updates.

## v0.7.2 (2026-05-05)

### Features
- **Location Reminder**: Replaced the standalone `MythicLocationReminder` addon with a built-in SFUI module. The feature has been highly optimized to eliminate background memory footprint and garbage collection overhead.
- **Automation Settings**: Added a togglable "keystone reminder" option to the Automation configuration panel, enabled by default, ensuring the addon prints the dungeon name and key level to chat when a Mythic+ invite is accepted, and again when the group fills.

### Optimizations
- **Tracked Bars**: Resolved a performance bug by implementing a `configPool` to recycle configuration tables during `InvalidateConfigCache` calls, achieving zero allocations and zero GC pressure during frequent spec-swapping or UI refreshes.
- **World Quests**: Addressed memory bloat in the `wqs.lua` world quest system by lowering the stale cache eviction threshold from 300 to 50 refreshes, significantly reducing background memory load during long play sessions.
- **Location Module**: Implemented the location module leveraging the shared `sfui.events` multiplexer rather than creating a dedicated UI frame, avoiding redundant object allocations.

## v0.7.1 (2026-05-01)

### Features
- **Loot Spec (World & Delves)**: Added full auto-swap and bonus roll suppression support for Delves and World Bosses. New "All World Bosses" and "All Delves" global toggles are now available at the top of the Raids and Dungeons tabs.
- **Loot Spec (Database Pruning)**: The Encounter Journal data builders now automatically cross-reference saved settings and permanently prune orphaned raid boss and dungeon map keys from previous expansion seasons, eliminating cross-season configuration bloat.

### Bug Fixes
- **Gear Manager (Respec Sync)**: Reduced the `PLAYER_SPECIALIZATION_CHANGED` execution delay from 1.5s to 0.1s and forced the clearance of `manualEditUntil` lockout locks. Gear now auto-equips instantly during specialization swaps even if the character frame was previously opened.
- **Loot Spec (M+ Bonus Rolls)**: Fixed a bug where bonus rolls at the end of a Mythic+ run would bypass suppression rules. The addon now proactively caches the active challenge map ID during the run since the WoW API forcibly nils it the moment the timer completes.
- **Loot Spec (Bonus Roll Suppression)**: Resolved a race condition where the Blizzard UI would forcefully unhide the `BonusRollFrame` milliseconds after the addon successfully suppressed it. Suppression is now enforced by a secure `Show()` hook with a 10-second lockdown window.
- **Loot Spec (Row Recycling)**: Fixed an object-pooling state leak where rapidly switching between Raids and Dungeons tabs could cause the "All Delves" custom row to inherit a stale `field` property from a recycled boss row, breaking its ability to save configuration data.

## v0.7.0 (2026-04-22)

### Features
- **Alts Tracker (Currencies)**: Added support for Patch 12.0.5 world content and Voidforge currencies including Nebulous Voidcore, Ascendant Voidcore, Ascendant Voidshard, Field Accolades, Dark Particles, and Angler Pearls.
- **Alts Tracker (Currency Grouping)**: Implemented a new `currency_group` type to cleanly combine related items into single rows (e.g. Heroic/Mythic Crests, Keys/Shards, Voidforge upgrade tokens). Tooltips now dynamically parse and display progress for all items in the group.

### Bug Fixes
- **Castbar (Mythic+ Taint)**: Resolved an issue in M+ environments where the instant cast bar would crash the UI due to evaluating `UnitSpellHaste`, which is now `SecretWhenUnitStatsRestricted` in Patch 12.0.5. Evaluated logic is now proactively guarded behind `C_Secrets.ShouldUnitStatsBeSecret()`.
- **UI Render**: Removed deprecated `"NONE"` font flags causing engine crashes in 12.0.5.

## v0.6.7c (2026-04-18)

### Bug Fixes
- **Tracked Bars (Mythic+)**: Fixed an issue where the string `"0"` would appear on icons in Mythic+ due to the `C_Spell.GetSpellCharges` API obfuscating empty cooldown counts as Secret Values.
- **Tracked Icons / Bars**: Fixed a severe Lua error crashing the UI in Mythic+ when evaluating `chargeInfo.maxCharges`. The evaluation is now safely wrapped in a protected execution environment (`SafeGT`).
- **Tracked Options**: Stack counts on standard icons are now hidden by default to reduce UI clutter, and will only render if explicitly enabled via the global "Show Stack Count" option in the config menu.

## v0.6.7b (2026-04-14)

### Features
- **Tracked Bars (Manual Ordering)**: Implemented manual reordering for both Normal and Attached tracks. Bars can now be moved up/down independently via [▲]/[▼] controls in the settings panel.
- **Tracked Bars (Independent Sort Tracks)**: Sorting logic now treats Normal and Health-attached bars as distinct layout pools with their own manual indices.

### Bug Fixes
- **Tracked Icons (Taint Safety)**: Fixed critical "Secret String" comparison errors in `GetSpellDisplayCount` that would trigger in restricted M+ environments. Replaced literal string checks with `issecretvalue` short-circuiting to safely handle protected Blizzard payloads.

## v0.6.7a (2026-04-14)

### Bug Fixes
- **Tracked Icons (Bone Shield)**: Extracted native `cdInfo.linkedSpellIDs` deeply out of the C++ CooldownViewer bridge to force aura applications checking on proxy cooldowns. Resolves a massive Blizzard-inherited disconnect where tracking `Marrowrend` naturally failed to query `Bone Shield` aura stacks.
- **Tracked Icons (CooldownViewer Counts)**: Shifted `GetSpellDisplayCount` interpretation to act as a fallback hierarchy rather than an isolated source. `UpdateIconCooldown` will now correctly simulate CooldownViewer counting priority (incorporating `GetSpellCharges` and `GetSpellChargeInfo`) if the base Actionbar query turns up dry.

## v0.6.7 (2026-04-14)
- **Tracked Icons (Display Count)**: Implemented native `GetSpellDisplayCount` support on tracked icons, mirroring the Blizzard action bar exactly. Soul fragments (Soul Cleave, Spirit Bomb), spell charges, reagent use counts, and all resource-pool-derived counts now display on icon badges.
- **Tracked Icons (Aura Stacks)**: Added `C_UnitAuras.GetPlayerAuraBySpellID.applications` overlay for tracked spell/buff entries. Stack counts (e.g. Maelstrom Weapon, Irresistible Pain) now display when `applications > 1`, matching CooldownViewer `RefreshApplications` behavior.
- **Tracked Icons (Count Font/Position)**: Count badge now uses `NumberFontNormal` and is positioned at `BOTTOMRIGHT -3, 1` to exactly match the Blizzard action bar count fontstring.

### Bug Fixes
- **Tracked Icons (Taint)**: Eliminated all secret-value taint errors in `UpdateIconCooldown`. Readiness logic now uses only `NeverSecret` fields (`cdInfo.isActive`, `cdInfo.isOnGCD`, `cdInfo.isEnabled`). `GetSpellDisplayCount` result is passed directly to `SetText`/`SafeSetText` without any Lua-level comparison.



### Features
- **UI Updates**: Modularized portal abbreviations, fixed tooltip anchoring, and updated gear manager UI logic.

## v0.6.5 (2026-04-13)

### Bug Fixes
- **Tracked Bars (Combat Stutter)**: Fixed destructive visual stuttering resulting from target swaps and global UI layout shifts in stack-mode tracked bars (e.g. Bone Shield).
- **Tracked Bars (Secret Values)**: Bypassed the native `CooldownViewer` wrapper internally for player buffs, ensuring unencrypted C++ `AuraData` integer handles correctly substitute standard stack strings in combat.
- **Tracked Bars (Layout Freeze)**: Hardcoded a UI caching freeze mechanism to securely prevent the standard WoW CooldownViewer engine garbage collection from wiping local UI widths visually mid-combat when charges drop.
- **Tooltip Taint (MoneyFrame)**: Patched an escalated global tooltip Secrecy restriction crash that halted `MoneyFrame_Update` and basic item interactions. Hovering tracking bars no longer securely injects C++ secretive pointers into the global `GameTooltip`.
- **UI Debounce**: Debounced generic Blizzard Native Frame destruction instances securely, resolving layout teardowns when tracking active auras dynamically swap internal Cooldown IDs.
