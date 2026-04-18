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
