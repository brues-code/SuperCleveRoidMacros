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
- **~~Caveat: `expirationTime` is player-only~~ — NO LONGER TRUE.** This note said
  target/focus `expirationTime` was always `0`, so debuff *timers* had to stay on
  libdebuff. ClassicAPI has since added the `Aura::Source` cache: for a non-player
  unit `expirationTime` is reconstructed from the observed `SMSG_SPELL_GO`, and
  `duration` is the **caster-modified** value (talent extensions like Improved
  Shadow Word: Pain included). It also handles combo-point finisher scaling
  automatically (Rupture at 4 CP reads 14s, no registration) and ships Carnage's
  roll-gated Rip/Rake refresh in the DLL (`src/turtle/Carnage.cpp`, exposed as
  `RegisterAuraDurationModifierByTrigger`).
- **Real remaining caveats** (all best-effort, from `docs/API.md`):
  - Only auras observed *after login* carry caster/timing; older ones report
    `expirationTime` 0 and `sourceUnit` nil.
  - Max-stack refresh is a blind spot: re-applying at max stacks (Shadow Weaving
    5→5) emits no client-visible change, so the entry elapses and evicts.
  - Out-of-range group members are spell-ID only, with `applications` always 1.
- **Consequence:** most of libdebuff is now redundant — see
  "libdebuff retirement" below.

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

### 2. ~~`C_Item.GetWeaponEnchantInfo()` — temp-enchant IDs~~ — DONE
- Shipped as `[mhenchant]` / `[ohenchant]` (+ `no` variants). Matches the applied
  temp enchant by SpellItemEnchantment ID *or* localized name — the name path
  resolves via `C_Item.GetEnchantInfo(id).name` (the ID→name table this doc
  assumed we lacked), so no tooltip scan. Wrappers `ClassicAPI.GetWeaponEnchant`
  / `GetEnchantName`; `ValidateWeaponImbue` now reads through the former.
- Bare = any temp enchant; OR-lists supported (`[mhenchant:2823/Deadly_Poison]`).
- Follow-up (optional): route `[mhimbue:Name]`'s match through `GetEnchantName`
  too, retiring the green-text tooltip scan in `CheckWeaponImbueByName`.

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
  detection in `Core.lua` to `GetActionInfo` too.

### 4. `C_Spell.*` / `GetSpellInfo(spellID)`
- **API:** `API.md:6649+` — `GetSpellCooldown`, `IsUsableSpell`, `IsSpellKnown`,
  `SpellHasRange`, `GetSpellSchool`, `FindSpellBookSlotByID`.
- **Replaces today:** spellbook scanning via `GetSpellName(i, BOOKTYPE_SPELL)`.
  Simplifies `[known]`, `[usable]`, range checks.
- **Done:** the Slam-slot and `[spellcasttime]` tooltip scans read
  `C_Spell.GetSpellInfo(name).castTime` (the player's cast time since v1.17.0).
  Left: the `[gcd]` fallback scan; ClassicAPI has no GCD field to replace it.

### 5. `C_Timer.After` / `NewTicker` (+ coroutines)
- **API:** `API.md:8008+`.
- **Replaces today:** manual `OnUpdate` frames (`Core.lua:5082`, `:80`, `:460`)
  and the UnitXP aura-cleanup timer (`Conditionals.lua:1474`).

### 6. `UnitGUID` / `UnitTokenFromGUID`
- **API:** `API.md:8206+`.
- **Done.** The immunity guards and aura expectations resolve combat-log GUIDs
  with `UnitTokenFromGUID`; the GUID string format matches SuperWoW's.

### 7. Native `focus` token + `FocusUnit`/`ClearFocus` + `PLAYER_FOCUS_CHANGED`
- **API:** `API.md:2624+`.
- **Done.** `focus` / `focustarget` go to the API as is; the pfUI focus
  emulation and its `/focus` hook are gone. A clause on an unset focus fails
  quietly via `UnitExists("focus")`.

---

## Tier 3 — situational

- **`C_NamePlate.GetNamePlates()` / `nameplateN` tokens** (`API.md:5742+`) —
  alternative to UnitXP enemy enumeration for AoE counting (`Conditionals.lua:3099`).
- ~~**`GetShapeshiftFormID()` + `UPDATE_SHAPESHIFT_FORM`** (`API.md:7792`) —
  cleaner stance/form conditionals.~~ — DONE with `GetShapeshiftForm(true)`
  instead (see the trap below).
- **`CastSpellNoToggle` / numeric spellIDs in `/cast`** (`API.md:5336+`) —
  rank-specific casting by ID, no-toggle behavior; could back a `/cast <spellID>`.
- **State helpers** `IsStealthed` / `IsMounted` / `UnitStandState` (`API.md:7574+`) —
  back simple `[stealth]` / `[mounted]` / `[standing]` conditionals.

---

## Cross-cutting policy

ClassicAPI is a **hard requirement** (see policy at the top) — ClassicAPI-backed
code calls the API directly, **no fallbacks**. Light `pcall`/nil guards for
runtime safety are fine; do not maintain alternate non-ClassicAPI
implementations. The load-time requirement check (`Core.lua`) warns when it's
missing, the same as nampower/UnitXP.

---

## Nampower reduction — keep only the spell queue

**Goal:** nampower stays only for its spell queue, which ClassicAPI does not
have: `QueueSpellByName`, `QueueScript`, `CastSpellByNameNoQueue`,
`ChannelStopCastingNextTick`, `SPELL_QUEUE_EVENT` and the `NP_Queue*` /
`*QueueWindowMs` / buffer CVars — and for its aura-cap data (step 3c).
Everything else moves to ClassicAPI. Where ClassicAPI has no equivalent, add one
to ClassicAPI instead of keeping nampower.
Each step leaves a working addon.

1. ~~**Combat events → `COMBAT_LOG_EVENT_UNFILTERED`.**~~ — DONE. The
   dispatcher at the end of `Utility.lua` (`CleveRoidsCombatLogFrame`) feeds
   immunity (`SPELL_MISSED`/`RANGE_MISSED` `IMMUNE`), reactive procs
   (`ProcessAvoidance`, swings and spells alike), `[resisted]`, spell-school
   learning, CC/bleed landing (`SPELL_AURA_APPLIED`) and `UNIT_DIED` cleanup.
   `CleveRoidsMeleeResultFrame` in `Conditionals.lua` records
   `[lastswing]`/`[incominghit]`; the Cursive extension refreshes Judgements on
   `SWING_DAMAGE`. Gone: every chat-text parser and `CHAT_MSG_*`/`RAW_COMBATLOG`
   registration, nampower `SPELL_MISS_*`, `SPELL_DAMAGE_EVENT_*`,
   `AUTO_ATTACK_*` and `UNIT_DIED`, the `NP_EnableAutoAttackEvents` setup, the
   `ProcessMissReason` correlation and its `WasSpellReflected`/`DidTargetEvade`.
   The `RAW_COMBATLOG` debuff-fade learner was dropped, not ported: it stripped
   `0x` from GUIDs before looking up `lib.objects`, so it never matched.
2. ~~**Cast tracking.**~~ — DONE for the cast state. `[casting]`,
   `[channeled]`, `[casttime]`, `[channeltime]`, `[selfcasting]` and the
   pending-debuff check read `C_Spell.CastingInfo`/`ChannelInfo`
   (`CleveRoids.GetPlayerCast`), which have the effective cast time and track
   pushback; `CheckSpellCast` reads `C_Spell.UnitCastingInfo`/`UnitChannelInfo`
   for any unit. Core's `UNIT_SPELLCAST_*` handlers refresh the buttons,
   advance `/castsequence` on `SUCCEEDED`, and record each sent cast with a
   finisher's combo points (`CleveRoids.sentCasts`, on `SENT`). Gone: Core's
   `UNIT_CASTEVENT`, `SPELL_CAST_EVENT`, `SPELL_START_SELF`, `SPELL_FAILED_SELF`
   and stock `SPELLCAST_*` handlers, `spell_tracking`, the cast/channel timers,
   `CurrentSpell.type`/`spellName`, `UpdateCastingState`, `lastCastSpell`, and
   the tooltip/DBC channel-duration lookup.
   Still on nampower/SuperWoW, moving with step 3 because they record debuff
   applications, not casts: libdebuff's `UNIT_CASTEVENT`, `SPELL_GO_*`,
   `SPELL_START_*`/`SPELL_FAILED_OTHER` (and the `castTracking` target fallback
   they feed), and the Cursive extension's `UNIT_CASTEVENT` frames. CLEU
   `SPELL_CAST_SUCCESS` does not fire for a spell with a cast time, so their
   replacement is `SPELL_AURA_APPLIED` + `C_UnitAuras`, not a cast event.
3. **Auras.** In three slices:
   - **3a — DONE: aura reads.** `ValidateAura` (`[buff]`, `[mybuff]`,
     `[mydebuff]`) and `ValidateUnitDebuff` (`[debuff]`) resolve every unit
     through `ResolveUnitAura` (`C_UnitAuras.UnitAura`): polarity-based, so an
     overflowed debuff still reads harmful; `expirationTime` for time left;
     `applications` for stacks. On another unit a personal debuff counts only
     when the player or pet cast it (`sourceUnit`). Gone: the libdebuff
     `lib.objects` timer lookups and `lib:UnitDebuff` time-left, nampower's
     `FindUnitAuraInfo`/`GetUnitAuras`/`GetUnitAuraApplications`,
     `GetPlayerAura`, and the slot-by-slot scans. libdebuff still runs, but
     nothing outside it reads its timers except the `/cleveroid` debug dump.
   - **3b — DONE: libdebuff's tracking pipeline.** Gone: its `UNIT_CASTEVENT`,
     `SPELL_GO_*`, `SPELL_START_*`, `SPELL_FAILED_OTHER`, `AURA_CAST_*`,
     `DEBUFF_ADDED/REMOVED_*`, `BUFF_REMOVED_*` and target `UNIT_AURA` handlers,
     the delayed verification frame, `lib.objects` and the tables beside it,
     `castTracking`, `AddEffect`/`GetDuration`/`UnitDebuff`/`UnitBuff`, the
     pfUI libdebuff table linking, and nampower's `SPELL_START`/`SPELL_GO` CVar
     setup. The **aura expectations** in `Utility.lua` replace the pending
     arrays: the player's hit (`SPELL_CAST_SUCCESS`, `SPELL_DAMAGE`,
     `RANGE_DAMAGE`) expects the debuff, `SPELL_AURA_APPLIED` / a miss / a
     `C_UnitAuras` check settles it, and a bleed or CC debuff still missing
     after 0.4s records a bleed or CC immunity behind the old guards. They also
     answer `IsPendingDebuffCast` ("in flight"), and the player's CC landing
     counts DR (`recentCCHits`). The old CC and shared-debuff "missing aura"
     verifiers were dropped, not ported: with nampower's `SPELL_GO` they
     short-circuited on `spellGoHit` and never recorded anything.
   - **3d — DONE: duration bookkeeping removed.** Only libdebuff consumed it,
     and ClassicAPI supplies caster-modified durations. Gone: the talent /
     equipment / set-bonus duration modifiers (`ApplyAllDurationModifiers`),
     nampower's `GetSpellModifiers` wrappers, `ComboPointTracker.lua` (its
     combo-point duration math, cast hooks and `/combotrack`),
     `CleveRoids_LearnedDurations` / `CleveRoids_ComboDurations` /
     `CleveRoids_AuraTextures` and the `learn`/`forget`/`combo*`/`testtalent`
     commands, and the Console `/cast` pre-tracking. `sentCasts` now holds only
     the send time. The bleed tables moved into `Utility.lua` beside the aura
     expectations. `[setbonus]`'s `GetEquippedSetPieceCount` stays. The Cursive
     extension's `UNIT_CASTEVENT` frames feed Cursive's own timers and are
     SuperWoW, not nampower.
   - **3c — DECIDED: stays on nampower.** `[buffcapped]`/`[debuffcapped]`
     (`AURA_CAST` `auraCapStatus`), player buffs past the 32 client slots
     (`OverflowBuffs`, the OverflowBuffFrame extension) and
     `AllCasterAuraTracking` keep reading nampower's `AURA_CAST_*`,
     `BUFF/DEBUFF_REMOVED_OTHER` and `*_UPDATE_DURATION_SELF` events
     (`CleveRoidsAuraCastFrame` in `Conditionals.lua`). ClassicAPI cannot see a
     buff that has no client slot, and only nampower reports the server's cap
     flags. Like the spell queue, this is a nampower feature SCRM keeps.
4. **Direct swaps.** `GetCurrentCastingInfo`, now read only for its on-swing
   and auto-attack flags (`[onswing]`, weapon swap, Core.lua:94) → ClassicAPI's
   next-melee/auto-attack state (`C_Spell.IsCurrentSpell` and friends); `IsSpellUsable`/
   `GetSpellPowerCost` → `C_Spell.*`; `GetPlayerAuraDuration`/`GetUnitAuras` →
   `C_UnitAuras`; `GetSpellIdForName`/`GetSpellNameAndRankForId`/
   `GetSpellSlotTypeIdForName` → `C_Spell.GetSpellInfo`/`FindSpellBookSlotByID`;
   item lookups (`FindPlayerItemSlot`, `GetBagItems`, `GetEquippedItems`,
   `GetTrinkets`, `UseItemIdOrName`, `GetItemStats`) → `C_Container`/`C_Item`.
   - **`IsSpellInRange` — DONE.** Button range, `[inrange]`/`[outrange]` and
     their negations (count mode too) and the no-UnitXP melee fallback read
     `C_Spell.IsSpellInRange`. v1.18.0 gave it the engine's target gate, which
     replaced the rangeIndex / implicit-target heuristics and the UnitXP
     distance fallback. nil (rangeless spell, or a unit the spell can't be cast
     at) passes neither `[inrange]` nor `[outrange]`.
5. **Field reads.** Match each field SCRM reads through `GetUnitField`/
   `GetUnitData` and `GetSpellRecField`/`GetSpellRec`, and also
   `GetSpellModifiers`, `GetSpellDuration`, `IsAuraHidden`, `GetItemLevel`,
   `SetMouseoverUnit` and `[rooted]`. File each gap against ClassicAPI.
   - **Spell schools — DONE.** `GetSpellSchool` resolves a name through the
     spellbook (`CleveRoids.GetSpell(name).id`) and reads ClassicAPI's
     `GetSpellSchool(spellID)` (Spell.dbc), with bleeds from the DBC mechanic
     (`IsBleedByMechanic`). Gone: `KNOWN_NON_DAMAGING_SPELLS`, the tooltip
     scanner, the name patterns, `BLEED_SPELL_IDS`, `LearnSpellSchool`, the
     `CleveRoids_SpellSchools` SavedVariable and `listschools`/`clearschools`.

The "keep nampower" verdicts below (`FindItemLocation`, `[usable]`,
`[rooted]`) are now gaps to close under steps 4–5, not reasons to keep nampower.

---

## Conditionals.lua audit — do NOT migrate (traps)

Findings from the full Conditionals.lua audit. These look like ClassicAPI
candidates but are **worse** than the current implementation — recorded so we
don't re-investigate.

- ~~**Auras / `ValidateAura`** — `C_UnitAuras.expirationTime` is player-only~~ —
  **Wrong, and now migrated** (step 3a). The `Aura::Source` cache gives
  non-player `expirationTime`/`duration`, and both aura validators read
  `C_UnitAuras`.
- ~~**`GetCurrentShapeshiftIndex` form loop / `[stance]`·`[form]`**~~ —
  `GetShapeshiftFormID()` returns the **DBC form id** (Cat=1, Bear=5,
  Shadowform=28…), NOT the 1-based **bar index** these conditionals compare
  against, so it is still the wrong call. **Migrated anyway** to v1.18.0's
  `GetShapeshiftForm(true)`, which returns the bar index.
- **Range / distance / behind / facing** — UnitXP_SP3 gives precise yards +
  facing; `UnitInRange` is a binary 40yd and has no facing/behind. Keep UnitXP.
- **`FindItemLocation`** — nampower `FindPlayerItemSlot` finds an item by id/name
  across bags in one call; ClassicAPI has no equivalent (would need a manual
  `C_Container` bag scan). Keep nampower.
- **`[known]`** (name+rank+talent logic richer than `IsSpellKnown`/`IsPlayerSpell`'s
  current-rank/no-talent semantics) and **`[usable]`/reactive** (nampower
  `IsSpellUsable` == `IsUsableSpell`). Keep.

## Conditionals.lua audit — done

- `GetItemCooldownCached` → ClassicAPI `GetItemCooldown(item)` (slots 1-19 still
  inventory-based).
- `[stealth]`/`[nostealth]`/`[stl]`/`[nostl]` + Rogue branch of
  `GetCurrentShapeshiftIndex` → `IsStealthed()`.
- `CountEnemiesMatching` nameplate scan → `C_NamePlate.GetNamePlateGUIDs()`.
- Focus: `GetFocusUnitId`/`TryTargetFocus` use the native `"focus"` token;
  added `[focus]`/`[nofocus]`. `/focus` is provided by ClassicAPI's companion
  addon.

## libdebuff retirement

libdebuff existed because vanilla cannot report debuff durations on units other
than the player. ClassicAPI's `Aura::Source` cache now does exactly that, so the
tracking was removed (steps 3a, 3b). What remains of `CleveRoids.libdebuff` is
data and small helpers with no `C_UnitAuras` equivalent: the shared debuff
set (`IsSharedDebuff`; Spell.dbc has no per-caster stacking flag),
`GetSpellRank`/`GetSpellBaseName`,
`trackedAfflictions`, `guidToName`, and the immunity guards `recentDeaths` and
`recentCCHits`.

**Check in-game** (not run before the removal): `[debuff:Rip<3]` across a
Carnage proc, and `C_UnitAuras.GetUnitAuraBySpellID("target", spellID,
"HARMFUL")` (`duration`, `expirationTime - GetTime()`) against the tooltip.
Watch the documented best-effort gaps: an aura cast before you logged in, and
refresh-at-max-stacks. Also Conflagrate: libdebuff shortened its Immolate timer
by 3s; whether ClassicAPI models that is unverified.

## Marginal / optional follow-ups

- **`[swimming]`** → `IsSwimming()` would drop the nampower-2.36 version gate +
  warning (same semantics). `[rooted]` has no ClassicAPI equivalent — keep nampower.
- **Weapon-imbue name match** (`[imbue:Mongoose]`) → `C_Item.GetWeaponEnchantInfo`
  gives enchant **IDs**, so it needs an enchantID→name table we don't ship.
