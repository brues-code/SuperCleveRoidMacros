# ClassicAPI Adoption Backlog

Opportunities to use [ClassicAPI](https://github.com/brues-code/ClassicAPI)
(`C:\Git\ClassicAPI`, see `docs/API.md`) in SuperCleveRoidMacros. ClassicAPI is
a client mod (sibling to nampower/SuperWoW) that backports the modern `C_*` API
into the 1.12.1 client.

**Policy: ClassicAPI is a hard requirement of this fork — no fallbacks.** The
load-time requirement check warns when it's missing (`Core.lua`), the same as
nampower/UnitXP. ClassicAPI-backed code may assume the API is present (light
`pcall`/nil guards for runtime safety are fine, but do not maintain alternate
non-ClassicAPI implementations). Users who don't want ClassicAPI should run the
upstream addon instead.

API references are line numbers into `C:\Git\ClassicAPI\docs\API.md`.

---

## Tier 1 — high impact (new capabilities, not just refactors)

### 1. `C_UnitAuras` — native aura data for any unit
- **API:** `API.md:8670` — `GetAuraDataBySpellName(unit, name, filter)`,
  `GetUnitAuraBySpellID(unit, spellID, filter)`, `GetAuraDataByIndex`.
- Returns `spellId`, `dispelName` (`"Magic"`/`"Curse"`/`"Disease"`/`"Poison"`),
  `applications` (stacks), `duration`.
- **Unlocks:** `[dispellable]` / `[curse]` / `[magic]` target conditionals and
  spellID-based (rank/locale-proof) aura matching.
- **Caveat:** `expirationTime` is only populated for `unit=="player"`; it's `0`
  for target/focus (vanilla server limitation). Target debuff *timers* still
  need the existing libdebuff tracking — only presence/stacks/school/spellId
  are reliable cross-unit.

- **DONE (slice 1 — dispel-type conditionals):** added `ClassicAPI.lua`
  detection module (`CleveRoids.ClassicAPI`, mirrors NampowerAPI's
  `HasMinimumVersion`) and the `[magic]`/`[curse]`/`[disease]`/`[poison]`/
  `[dispellable]` conditionals + negations, backed by
  `C_UnitAuras.GetDebuffDataByIndex(...).dispelName`. No-arg booleans, honor
  `@unit`, graceful fallback (positive→false, negated→true) when ClassicAPI is
  absent. Purely additive — the existing `ValidateAura` path is untouched.
- **DONE (slice 2 — buff-side / offensive dispel):** `UnitHasDispelType` now
  takes a `helpful` flag (scans `GetBuffDataByIndex`), exposed as
  `[magicbuff]`/`[dispellablebuff]` + negations — detect a dispellable buff to
  strip off an enemy (e.g. `[harm,magicbuff] Dispel Magic`). Magic-only is the
  practical set since 1.12 offensive dispel removes Magic buffs.
- **Follow-ups (still TODO):**
  - spellID-based aura matching via `GetUnitAuraBySpellID` (rank/locale-proof),
    optionally wired into `ValidateAura` as a fast path with libdebuff fallback.
  - more reliable cross-unit stacks via `applications`.
  - class-aware `[dispellable]` (only types this character can actually remove).
  - optional name filtering on the type keywords (e.g. `[magic:Polymorph]`).

### 2. `C_Item.GetWeaponEnchantInfo()` — temp-enchant IDs
- **API:** `API.md:7159` — returns 12-tuple including `enchantID` for main/off/ranged.
- **Unlocks:** detect *which* temp enchant (poison/oil/sharpening stone) is
  applied to a weapon, not just that one exists.
- **Naming:** `[poison]` is now taken by the target dispel-type conditional
  (slice 1 above). Use weapon-specific keywords for this — e.g.
  `[mhenchant:<id>]` / `[ohenchant:<id>]` (or `[mhpoison:<id>]`/`[ohpoison:<id>]`),
  not a bare `[poison]`.
- Vanilla's global only reports presence; this is a genuinely new capability
  (rogue/shaman/enhance).

### 3. `GetUnitSpeed(unit)` + `IsFalling()` / `IsSwimming()`
- **API:** `API.md:8312`, `API.md:7629`.
- **Replaces today:** MonkeySpeed addon dependency (which needs SuperWoW
  `UnitPosition`) for `[moving]` — `Conditionals.lua:2981`.

- **DONE:** `ClassicAPI.lua` exposes `HasUnitSpeed` / `GetUnitCurrentSpeed` /
  `GetPlayerSpeedPercent` (100% = 7.0 yd/s) plus `IsPlayerFalling` (`IsFalling`).
  `GetPlayerSpeed` and `IsPlayerMoving` are ClassicAPI-only now; the boolean
  `[moving]` ORs in `IsPlayerFalling` so jumping/falling registers even though
  `currentSpeed` is horizontal-only.
- **Fallbacks removed (ClassicAPI mandatory):** deleted the MonkeySpeed
  integration (`HasMonkeySpeed`, `RequireMonkeySpeed`), the Nampower
  `PlayerIsMoving` branch, and the 100 Hz position-tracking buffer in Core.lua's
  OnUpdate (`_positionHistory`, `POS_TRACK_INTERVAL`, `UnitPosition` upvalue).
  MonkeySpeed dropped from README "Supported Addons".
- **`IsSwimming` deliberately not used:** swim state is true while treading
  water motionless, which would falsely report `[moving]`.

---

## Tier 2 — replace custom scanning / extra deps

### `GetActionInfo(slot)` — action-slot → spell/macro/item mapping
- **API:** `API.md:489` — returns `actionType, id, subType`.
- **DONE:** `ClassicAPI.GetActionInfo` wrapper added; `GetActionButtonInfo`
  (`Extensions/Tooltip/Generic.lua`) rewritten to use it and resolve names via
  `GetSpellRecField` / `GetItem` / `GetMacroInfo`, replacing the per-slot
  GameTooltip scan + texture heuristic (which couldn't tell spell from item and
  never recognized macros). Powers reactive-ability slot detection
  (`IndexActionSlot`). Deleted the dead SuperWoW-`GetActionText` copy of
  `GetActionButtonInfo` in `Conditionals.lua`.
- **Known limitation:** GetActionInfo returns `id = nil` for bag-instance items
  (items dragged from bags rather than placed by itemID), so those slots get no
  name. The consumers (`actionSlots` for `/startattack`·`/shoot`·auto-shot
  proxies, reactive spells) only need spells, so this is acceptable.
- **Follow-up (optional):** migrate the remaining `GetActionText` macro-slot
  detection in `Core.lua` / `ComboPointTracker.lua` to `GetActionInfo` too.

### 4. `C_Spell.*` / `GetSpellInfo(spellID)`
- **API:** `API.md:6649+` — `GetSpellCooldown`, `IsUsableSpell`, `IsSpellKnown`,
  `SpellHasRange`, `GetSpellSchool`, `FindSpellBookSlotByID`.
- **Replaces today:** spellbook scanning via `GetSpellName(i, BOOKTYPE_SPELL)`
  (`Conditionals.lua:2500`) and the Slam-slot hack. Simplifies `[known]`,
  `[usable]`, range checks.

### 5. `C_Timer.After` / `NewTicker` (+ coroutines)
- **API:** `API.md:8008+`.
- **Replaces today:** manual `OnUpdate` frames (`Core.lua:5082`, `:80`, `:460`)
  and the UnitXP aura-cleanup timer (`Conditionals.lua:1474`).

### 6. `UnitGUID` / `UnitTokenFromGUID`
- **API:** `API.md:8206+`.
- **Replaces today:** SuperWoW GUIDs in ComboPointTracker (`ComboPointTracker.lua`).
- **Verify first:** confirm GUID string format matches SuperWoW's before swapping.

### 7. Native `focus` token + `FocusUnit`/`ClearFocus` + `PLAYER_FOCUS_CHANGED`
- **API:** `API.md:2624+`.
- **Replaces today:** custom/pfUI focus resolution (`Conditionals.lua:5799`, `:3148`).
  Gives engine-backed `@focus` for non-pfUI users.

---

## Tier 3 — situational

- **`C_NamePlate.GetNamePlates()` / `nameplateN` tokens** (`API.md:5742+`) —
  alternative to UnitXP enemy enumeration for AoE counting (`Conditionals.lua:3099`).
- **`GetShapeshiftFormID()` + `UPDATE_SHAPESHIFT_FORM`** (`API.md:7792`) —
  cleaner stance/form conditionals.
- **`CastSpellNoToggle` / numeric spellIDs in `/cast`** (`API.md:5336+`) —
  rank-specific casting by ID, no-toggle behavior; could back a `/cast <spellID>`.
- **State helpers** `IsStealthed` / `IsMounted` / `UnitStandState` (`API.md:7574+`) —
  back simple `[stealth]` / `[mounted]` / `[standing]` conditionals.

---

## Cross-cutting requirement

Gate **every** ClassicAPI path behind feature-detection with graceful fallback,
mirroring the nampower `HasMinimumVersion` pattern (`Conditionals.lua:227`):

```lua
if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    -- ClassicAPI path
else
    -- existing libdebuff/tooltip path
end
```
