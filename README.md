# SuperCleveRoid Macros

Enhanced macro addon for World of Warcraft 1.12.1 (Vanilla/Turtle WoW) with dynamic tooltips, conditional execution, and extended syntax.

**[Full Documentation on the Wiki](https://github.com/brues-code/SuperCleveRoidMacros/wiki)**

## Requirements

| Mod | Required | Purpose |
|-----|:--------:|---------|
| [Nampower](https://github.com/brues-code/nampower/releases) (v3.0.0+) | ✅ | Spell queueing, DBC data, auto-attack events |
| [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3/releases) | ✅ | Distance checks, `[multiscan]` enemy scanning |
| [ClassicAPI](https://github.com/brues-code/ClassicAPI/releases) | ✅ | Modern `C_*` API: dispel-type conditionals (`[magic]`, `[curse]`, …), `[moving]` speed |

## Installation

1. Download and extract to `Interface/AddOns/SuperCleveRoidMacros`
2. **Recommended pfUI:** Use [brues-code/pfUI](https://github.com/brues-code/pfUI) for full compatibility with macro spell scanning and action bar features

## Quick Start

```lua
#showtooltip
/cast [mod:alt] Frostbolt; [mod:ctrl] Fire Blast; Blink
```
- **Conditionals** in `[]` brackets, space or comma separated
- **Arguments** use colon: `[mod:alt]`, `[hp:>50]`
- **Negation** with `no` prefix: `[nobuff]`, `[nomod:alt]`
- **Target** with `@`: `[@mouseover,help]`, `[@party1,hp:<50]`
- **Spell names** with spaces: `"Mark of the Wild"` or `Mark_of_the_Wild`

**Multi-value logic:**

| Syntax | Logic | Example |
|--------|-------|---------|
| `[buff:X/Y]` | OR | Has X **or** Y |
| `[buff:X&Y]` | AND | Has X **and** Y |
| `[nobuff:X/Y]` | NOR | Missing **both** |
| `[nobuff:X&Y]` | NAND | Missing **at least one** |

**Comparisons:** `[hp:>50]`, `[hp:>20&<50]`, `[buff:"Name"<5]` (time), `[debuff:"Name">#3]` (stacks)

## Wiki

See the **[Wiki](https://github.com/brues-code/SuperCleveRoidMacros/wiki)** for complete documentation:

- **[Quick Start](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Quick-Start)** — Syntax, multi-value logic, comparisons, special prefixes
- **[Slash Commands](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Slash-Commands)** — All 35+ commands, priority macros, UnitXP scanning
- **[Conditionals](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Conditionals)** — 70+ conditionals (player & target), extended unit tokens, multiscan
- **[Reference Tables](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Reference-Tables)** — CC types, damage schools, stat types, swing types
- **[Features](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Features)** — Debuff timers, combo tracking, talent modifiers, TWoW mechanics
- **[Overflow Buff Frame](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Overflow-Buff-Frame)** — Hidden buff display for 32+ buffs
- **[Immunity Tracking](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Immunity-Tracking)** — Auto-learned NPC immunities
- **[Settings](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Settings)** — Configuration and console commands
- **[Supported Addons](https://github.com/brues-code/SuperCleveRoidMacros/wiki/Supported-Addons)** — Compatible addons and integrations

## Known Issues

- Action-bar macros are identified by slot, so blank or duplicate macro names are fine. Only macros referenced *by name* (`{MacroName}` nesting, `/runmacro "Name"`) still need a unique name to disambiguate.
- Reactive abilities must be on action bars for detection
- Debuff time-left conditionals only work on own debuffs unless pfUI libdebuff or Cursive has data
- Macro line length: 261 characters max (MacroLengthWarn extension prevents crashes)

## Supported Addons

**Unit Frames:** [pfUI](https://github.com/brues-code/pfUI), LunaUnitFrames, XPerl, Grid, CT_UnitFrames, agUnitFrames, and more

**Action Bars:** Blizzard, [pfUI](https://github.com/brues-code/pfUI), Bongos, Discord Action Bars

**Integrations:** [SP_SwingTimer](https://github.com/jrc13245/SP_SwingTimer), [TWThreat](https://github.com/MarcelineVQ/TWThreat), [TimeToKill](https://github.com/jrc13245/TimeToKill), [QuickHeal](https://github.com/jrc13245/QuickHeal), [Cursive](https://github.com/pepopo978/Cursive), [ClassicFocus](https://github.com/wtfcolt/Addons-for-Vanilla-1.12.1-CFM/tree/master/ClassicFocus), [SuperMacro](https://github.com/jrc13245/SuperMacro-turtle-SuperWoW)

> **Note:** For pfUI users, the [brues-code/pfUI fork](https://github.com/brues-code/pfUI) includes native SuperCleveRoidMacros integration for proper cooldown, icon, and tooltip display on conditional macros.

## Credits

Based on [CleverMacro](https://github.com/DanielAdolfsson/CleverMacro) and [Roid-Macros](https://github.com/DennisWG/Roid-Macros).

MIT License
