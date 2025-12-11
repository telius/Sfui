# sfui - World of Warcraft UI Framework

**sfui** (stfui) is a lightweight and dynamic World of Warcraft addon designed to enhance your gameplay experience with modular and customizable user interface elements. It focuses on providing essential player information clearly and efficiently, with a modern aesthetic.

---

## Features

*   **Dynamic Unit Bars:** Clean and efficient display for:
    *   Health Bar
    *   Primary Power Bar (Mana, Energy, Rage, Runic Power, Focus, Fury, Lunar Power, Insanity, Maelstrom)
    *   Secondary Power Bar (Combo Points, Soul Shards, Runes, Essence, Chi, Holy Power, Arcane Charges, Stagger)
    *   Vigor Bar (for Dragonriding)
    *   Mount Speed Bar (for Dragonriding)
*   **Intelligent Visibility:**
    *   Core bars (Health, Primary, Secondary Power) only show when in combat or targeting an enemy.
    *   Dragonriding-specific bars (Vigor, Mount Speed) show instantly only when Dragonriding is active.
    *   Secondary Power Bar hides when mounted.
*   **Pet Warning System:** Customizable on-screen warning for specific pet-dependent specs (Warlock, BM/Surv Hunter, Unholy DK) if no pet is active and not mounted. Includes a delay to prevent false warnings (e.g., during dismounting). Excludes Warlocks with Grimoire of Sacrifice.
*   **Minimap Enhancements:**
    *   **Button Manager:** Collects and organizes minimap buttons into a customizable bar.
    *   **Button Reordering:** Drag-and-drop functionality to reorder minimap buttons.
    *   **Mouseover Only Mode:** Hides the minimap button bar until hovered, with the Dungeon Eye optionally moving to a fixed corner.
    *   **Square Minimap:** Option to switch between square and round minimap shapes.
    *   **Clock & Calendar Toggles:** Control visibility of the game clock and calendar button.
    *   **Custom Spacing:** Adjustable spacing between minimap buttons.
    *   **Addon Icon:** A dedicated minimap icon for sfui (Death Coil) for quick access, with right-click to reload UI.
*   **Customizable Bar Appearance:**
    *   Select from various LibSharedMedia statusbar textures to personalize your UI.
    *   Configurable absorb bar color.
*   **Absorb Bar Overlay:** Visual representation of absorb shields directly on your health bar, growing from right to left with a customizable semi-transparent color.
*   **Currency & Item Tracking:** A dynamic widget to track selected currencies and items, easily configurable via drag-and-drop or item ID entry.
*   **In-Game Options Panel:** Access all settings conveniently via the `/sfui` chat command.
*   **UI Reload Command:** Quickly reload your UI with `/rl`.

---

## Installation

1.  Download the latest version of the addon.
2.  Extract the contents of the `.zip` file into your World of Warcraft `_retail_/Interface/AddOns/` directory.
    *   Ensure the folder structure looks like this: `World of Warcraft/_retail_/Interface/AddOns/Sfui/`
3.  Restart your World of Warcraft client.

---

## Usage

*   **Open Options Panel:**
    *   Left-click the sfui minimap icon.
    *   Type `/sfui` in chat.
*   **Reload UI:**
    *   Right-click the sfui minimap icon.
    *   Type `/rl` in chat.
*   **Bar Textures:** Customize the look of your bars in the "Bars" tab of the options panel.
*   **Absorb Bar Color:** Adjust the color of your health bar's absorb overlay in the "Bars" tab.
*   **Currency/Item Tracking:** Use the "Currency/Items" tab to manage what's displayed.
*   **Minimap Settings:** Configure minimap button collection, square minimap, mouseover behavior, and other options in the "Minimap" tab.

---

## Configuration

All configurable options can be accessed through the in-game options panel using the `/sfui` command.

---

## Troubleshooting

*   **Bars not showing/appearing incorrectly:** Ensure `sfui` is enabled in your addon list. Try reloading your UI (`/rl`).
*   **Errors in chat:** If you encounter Lua errors, please report them to the author with the full error message and steps to reproduce.

---

## Credits

*   **Author:** teli
*   **Inspiration & Adaptations:** NephUI for resource bar implementation.

---

## License

This project is open-source and released under the [MIT License](https://opensource.org/licenses/MIT).
Please see the `LICENSE` file for more details.
