<!-- BEGIN DISCLAIMER (managed by FFXIWindower author; do not remove) -->
## ⚠️ Disclaimer — Use at Your Own Risk

This is unofficial, fan-made software for *Final Fantasy XI*. It is **not affiliated with, endorsed by, or supported by Square Enix Holdings Co., Ltd.** FINAL FANTASY is a registered trademark of Square Enix.

**Square Enix's official position is that third-party tools and modifications to the FFXI client are prohibited by the Terms of Service.** Installing or using this software may result in account suspension, account termination, character data loss, or other action taken by Square Enix at their sole discretion.

This software is provided **AS IS, without warranty of any kind**, express or implied — including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author or contributors be liable for any claim, damages, account action, lost time, lost progress, file corruption, or any other liability arising from the use of, or inability to use, this software.

**By installing, building, or running this software you acknowledge that you understand and accept these risks.**

<!-- END DISCLAIMER -->
# FFXIAzureSets — Blue Mage spell-set builder with live trait + points preview

## 🔑 Hotkey

**Default toggle: `Z`**

Press `Z` in-game to show or hide the window. Disabled while the chat bar or macro editor is open.

**Rebind it any time:**

| Command | What it does |
|---|---|
| `//faset changekey Z` | Bind to a specific letter / function key (A-Z, F1-F12) |

Aliases for the addon command prefix: `//faset`, `//azuresets_ui`, `//asetui`.

## What it does

A panel layered over the classic BLU spell-set workflow with:

- **Saved sets list** — `[ Live ]` pinned at top + every saved set; click to view
- **Spells of selected set** — 20 slot rows; click any slot to open the picker
- **Spell Info** — description, MP, set points, cast/recast, and the traits each spell contributes to
- **Cumulative Traits** — every BLU job trait the set activates, with current tier (I-IV) and points-to-next, gold-highlighted when within 2 pts of the next tier
- **Title-bar points counter** — `74/80 pts` pinned to the upper-right; red when overcommitted, gold when within cap
- **Auto-import from azureSets** — first load reads `azureSets/data/settings.xml` and brings every saved set across

## Building and editing sets

Click any slot in the *Spells of Selected Set* column → the column transforms into a **spell picker**:

```
Filter: All  v               ← dropdown: All, 6 categories, 36 individual traits
1000 Needles                  ← scrollable spell list (already-set spells hidden)
1-Hour-Spell
Acrid Stream
...
[Clear]            [Cancel]
```

While picking, **cols 3 (Spell Info) and 4 (Cumulative Traits) live-preview** what the set would look like with the hovered spell substituted in. Gold rows in col 4 show "this pick unlocks the next tier".

Filter dropdown supports filtering by:

| Level | What it filters to |
|---|---|
| `All` | Every BLU spell (~120) |
| `Physical` / `Magical` / `Defensive` / `Killer` / `Utility` / `Resist` | Spells contributing to any trait in that category |
| `Fast Cast` / `Auto Refresh` / `Magic Attack Bonus` / ... | Spells contributing specifically to that single trait |

## Action buttons

| Button | Effect |
|---|---|
| **Save Current Spell Set** | Prefills `//faset save ` into chat — type a name, press enter |
| **New Empty Set** | Prefills `//faset new ` — blank set ready to populate via the picker |
| **Equip Spell Set** | Equips the selected saved set on your character (uses your default `setmode`) |
| **Delete Spell Set** | Confirmed delete of the selected saved set |

## Set-points cap auto-detection

Cap = level base + Assimilation merits (up to +5) + BLU JP gifts (up to +20).

Auto-detects from `windower.ffxi.get_player()` for both main-job and sub-job BLU. Sub-job BLU correctly omits merits/JP since they don't apply on sub.

If your build uses different field names, override manually:

```
//faset setbonus 25      ← force +25 (5 merits + 20 JP, total = 80 at lvl 99)
//faset setbonus 0       ← revert to auto-detect
//faset debugcap         ← show what was detected
```

## Commands

```
//faset                          toggle the panel
//faset changekey <letter>       rebind the toggle hotkey (A-Z, F1-F12)
//faset removeall                clear every set spell
//faset spellset <name> [mode]   equip the named set
//faset set <name>               alias for spellset
//faset add <slot> <spell>       set one spell in one slot
//faset save <name>              save current loadout under <name>
//faset new <name>               create an empty set you can build via the picker
//faset delete <name>            delete a saved set
//faset currentlist              print live loadout to chat
//faset setlist                  print saved set names
//faset spelllist <name>         print one set's spells
//faset setmode <mode>           default equip mode: ClearFirst or PreserveTraits
//faset setspeed <seconds>       delay between set packets (default 0.65s)
//faset setbonus <0-25>          manual cap bonus above lvl base (0 = auto-detect)
//faset debugcap                 print cap breakdown (level base + merits + JP)
//faset import                   re-import from azureSets (overwrites same-named sets)
//faset help                     full help
```

Mode is either:

* **PreserveTraits** *(default)* — for each spell already set that's also in the target set, leave it alone. Only swap what doesn't belong. Avoids brief trait dropouts.
* **ClearFirst** — wipe every slot, then set the target loadout from scratch. Faster total swap but you lose traits during the gap.

## Installation

1. Put the `FFXIAzureSets` folder in `Windower/addons/`
2. `//lua load FFXIAzureSets` (or add to your `init.txt`)
3. Press `Z` (or your chosen hotkey) to open the panel

## Migrating from azureSets

**It happens automatically.** First load reads `azureSets/data/settings.xml` (sibling addon directory) and copies every saved set across. You'll see `FFXIAzureSets: imported 8 sets from azureSets.` in chat.

A `imported_from_azuresets` flag in `settings.xml` gates this so it runs once and won't clobber later edits.

Need to re-import after updating azureSets externally? `//faset import` forces a fresh pull and **overwrites** same-named sets. FFXIAzureSets-only sets are left alone.

## Credits

* **Original BLU spell-set logic** — **Ricky Gall (Nitrous of Shiva)**, 2013–2020. License preserved verbatim in `libs/spell_core.lua`. The PreserveTraits / ClearFirst strategy, slot rotation, and scheduled set+remove timing all come from the original `azureSets` addon.
  See: <https://github.com/Windower/Lua/tree/dev/addons/azureSets>
* **Trait point database** — scraped from [BG-Wiki Blue Mage Job Traits](https://www.bg-wiki.com/ffxi/Blue_Mage_Job_Traits), 2026-06.
* **Spell descriptions + metadata** — pulled from `FFXIMissingSpells/libs/blu_info.lua` when that addon is installed. Without it the Spell Info column still shows trait contributions from the bundled trait_db.
* **GSUI-styled UI + trait integration + points calculator** — Jason, 2026.
