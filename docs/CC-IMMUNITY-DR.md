# CC, Learned Immunity and Diminishing Returns

How SuperCleveRoidMacros classifies crowd control, what it learns about NPC
immunity, and why diminishing returns only ever acts as a brake on that
learning. Source citations are into `C:\Git\vmangos` and `C:\Git\nampower`.

## Three identities, never conflated

```text
ccType          Exact DBC mechanic. Backs [cc:*] and CC landing verification.
                Conditionals.lua, CleveRoids.CCMechanics

immunityType    Exact DBC mechanic, recorded against an NPC name when a CC
                spell comes back IMMUNE.
                Utility.lua, MECHANIC_TO_IMMUNITY_TYPE / GetSpellImmunityType

DR type         The real Vanilla diminishing-return pool. Internal only.
                Utility.lua, GetSpellImmunityDRType
```

The first two are the same taxonomy used for different purposes; the third is
a separate axis and is never exposed to macros. Folding any pair together is
what produced the bugs this design replaces: a target that resisted Gouge got
written down as stun-immune, and every later Kidney Shot was suppressed
against a target that had never resisted one.

## `[cc:*]` follows the DBC mechanic exactly

One conditional, one mechanic. Several names may alias a single mechanic, but
no name spans two:

```text
[cc:stun]      -> mechanic 12 only
[cc:freeze]    -> mechanic 13 only
[cc:knockout]  -> mechanic 14 only
[cc:sap]       -> mechanic 30 only
[cc:daze]      -> mechanic 27 only
```

Bare `[cc]` and `[cc:any]` still mean "any loss-of-control effect" and are
driven by `CleveRoids.CCTypesLossOfControl`, which is deliberately independent
of the per-mechanic table. An aggregate does not require redefining the parts.

Current aliases:

```text
slow                                  -> snare
disoriented                           -> disorient
grip                                  -> fumble    (mechanic 6 is DBC Fumble)
incap / incapacitate / incapacitated  -> knockout  (immunity input only)
```

Aliases exist so published macros keep working. They resolve to the canonical
mechanic name before anything is stored, so SavedVariables only ever hold
canonical keys.

## Vanilla DBC mechanic taxonomy

The identities SCRM names. Where a mechanic is named at all, it is named as
itself:

| DBC mechanic | ID | Canonical `ccType` |
|---|---:|---|
| Charm | 1 | `charm` |
| Disoriented | 2 | `disorient` |
| Disarm | 3 | `disarm` |
| Distract | 4 | `distract` |
| Fear | 5 | `fear` |
| Fumble | 6 | `fumble` |
| Root | 7 | `root` |
| Pacify | 8 | `pacify` |
| Silence | 9 | `silence` |
| Sleep | 10 | `sleep` |
| Snare | 11 | `snare` |
| Stun | 12 | `stun` |
| Freeze | 13 | `freeze` |
| Knockout | 14 | `knockout` |
| Bleed | 15 | `bleed` |
| Polymorph | 17 | `polymorph` |
| Banish | 18 | `banish` |
| Shackle | 20 | `shackle` |
| Turn | 23 | `turn` |
| Horror | 24 | `horror` |
| Interrupt | 26 | `interrupt` |
| Daze | 27 | `daze` |
| Sapped | 30 | `sap` |

Mechanics 16, 19, 21, 22, 25, 28 and 29 (Bandage, Shield, Mount, Persuade,
Invulnerability, Discovery, Immune Shield) are real DBC values but are not
crowd control, so they get no conditional.

## Diminishing returns

DR matters here for exactly one reason: a target at DR level 4 returns
`IMMUNE`, and that must not be recorded as permanent immunity. Nothing else in
the addon consumes DR state, and there is no player-facing DR feature.

### Only three pools can diminish a creature

`GetDiminishingReturnsGroupType` in
`vmangos/src/game/Spells/SpellEntry.h:52-79` returns `DRTYPE_ALL` for exactly
three groups:

```text
DIMINISHING_CONTROL_STUN
DIMINISHING_TRIGGER_STUN
DIMINISHING_KIDNEYSHOT
```

Every other staged group — sleep, both roots, fear, Warlock fear, charm,
polymorph, silence, disarm, Death Coil, freeze, banish, knockout — is
`DRTYPE_PLAYER`, and `Unit.cpp:7881` applies those only when the victim is a
player. So on an NPC target they can never generate a DR immunity, and they
must never hold back immunity learning.

This is why `GetSpellImmunityDRType` returns nil for everything that is not
mechanic 12. It is not an approximation; it is the complete `DRTYPE_ALL` set.

### Classifying a stun into its pool

`SpellEntry::GetDiminishingReturnsGroup(bool triggered)`
(`vmangos/src/game/Spells/SpellEntry.cpp:281-432`) resolves the pool, and the
`triggered` argument means the runtime fact of whether an aura triggered the
cast — this is not a pure DBC property. SCRM reconstructs it from
`UNIT_SPELLCAST_SENT`, which only fires for client-initiated casts: a spell ID
with a recent `CleveRoids.sentCasts` entry was cast deliberately, one without
reached the server as a proc.

```text
Kidney Shot                    -> stun_kidneyshot
Charge / Intercept stun        -> stun_control
other mechanic-12, client cast -> stun_control
other mechanic-12, proc        -> stun_trigger
```

Kidney Shot is matched on rogue family bit 21 (`0x00200000`,
`SpellClassMask.h:228`) rather than a bare ID list, so custom ranks that keep
their DBC family data still classify correctly. Charge (7922) and Intercept
(20253, 20614, 20615) are internally triggered but explicitly returned as
controlled stun by `SpellEntry.cpp:389-399`; they are the only such exceptions
in 1.12.

### Pools that exist but do not apply

Recorded so nobody re-adds them to the safeguard. Knockout and Sap are
distinct mechanics that share `DIMINISHING_KNOCKOUT`
(`SpellEntry.cpp:424-425`), and Horror maps to `DIMINISHING_DEATHCOIL`
(`SpellEntry.cpp:428-429`). Both are `DRTYPE_PLAYER`. `DIMINISHING_LIMITONLY`
is a PvP duration cap rather than a staged pool, and `DIMINISHING_NONE` is not
a pool at all.

### The safeguard itself

`recentCCHits[targetGUID][drType]` counts landed CC per DR pool, so the three
stun pools keep separate histories. A hit more than `DR_RESET_WINDOW` (20s)
after the previous one in that pool restarts the count at 1, matching the DR
decay the skip check uses. Without that reset the counter only ever climbed,
so three stuns on a target permanently disqualified it from ever teaching the
addon anything again.

An `IMMUNE` result is treated as DR, and discarded, only while the pool holds
three or more hits inside the window. Otherwise it is learned.

## Where `IMMUNE` comes from

Immunity is learned from ClassicAPI's `COMBAT_LOG_EVENT_UNFILTERED`: a
`SPELL_MISSED` or `RANGE_MISSED` whose source is the player and whose
`missType` is `"IMMUNE"`. The event gives the spell ID, the target GUID and
the target name, so nothing is parsed from chat text. Ranged-class spells
(Aimed Shot, Multi-Shot, Shoot) arrive as `RANGE_MISSED`, so both prefixes
must be handled. Spells that the 1.12 combat log hides (attributes `0x180`)
fire no combat log event, as they write no chat line either.

`SMSG_SPELLORDAMAGE_IMMUNE` — a target immune to the damage of a periodic tick
or a damage shield — arrives as `DAMAGE_SHIELD_MISSED` (or
`SPELL_PERIODIC_MISSED` when the server sets its debug byte) with `missType`
`"IMMUNE"`, and is recorded the same way. The server sends nothing when it
skips one effect of a spell (`IsImmuneToSpellEffect` strips it from the effect
mask), so Rake's bleed or Pounce's stun on an immune mob produces no event:
those are learned by checking that the aura appeared.

A tracked CC or bleed confirms that it landed through `SPELL_AURA_APPLIED`
with `auraType` `"DEBUFF"` (`HandleAffliction`).

## Known limitation: untokened targets

`ProcessSpellMissSelf` refuses to learn permanent immunity when it cannot
resolve a queryable unit, because the temporary-immunity-buff check needs one
— an NPC under Divine Shield must not be recorded as permanently immune. The
unit comes from `UnitTokenFromGUID`, so the target, focus, mouseover or any
unit with a nameplate works. An `IMMUNE` on a unit that no
token points at is not learned.

This is the safeguard working as designed, not a known bug. Do not loosen it
without a reproduction showing a real failure, since the failure mode on the
other side is permanent bad data in `CleveRoids_ImmunityData`.
