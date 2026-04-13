## v0.6.5 (2026-04-13)

### Bug Fixes
- **Tracked Bars (Combat Stutter)**: Fixed destructive visual stuttering resulting from target swaps and global UI layout shifts in stack-mode tracked bars (e.g. Bone Shield).
- **Tracked Bars (Secret Values)**: Bypassed the native `CooldownViewer` wrapper internally for player buffs, ensuring unencrypted C++ `AuraData` integer handles correctly substitute standard stack strings in combat.
- **Tracked Bars (Layout Freeze)**: Hardcoded a UI caching freeze mechanism to securely prevent the standard WoW CooldownViewer engine garbage collection from wiping local UI widths visually mid-combat when charges drop.
- **Tooltip Taint (MoneyFrame)**: Patched an escalated global tooltip Secrecy restriction crash that halted `MoneyFrame_Update` and basic item interactions. Hovering tracking bars no longer securely injects C++ secretive pointers into the global `GameTooltip`.
- **UI Debounce**: Debounced generic Blizzard Native Frame destruction instances securely, resolving layout teardowns when tracking active auras dynamically swap internal Cooldown IDs.
