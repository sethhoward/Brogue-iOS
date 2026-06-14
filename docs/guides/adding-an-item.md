# Adding an item to the BrogueCE engine

A reusable recipe for adding a new item (scroll, potion, charm, wand, staff, …) to the
**BrogueCE 1.15** engine in `BrogueCE/Engine/`. Scope is CE only; the Classic 1.7.5 engine
in `iBrogue_iPad/BrogueCode/` has a parallel but separate item system and is not covered here.

The worked example throughout is the **charm of rewinding**, a debug experiment we built and
then removed. The rewind *mechanism* was specific to that idea, but the *item plumbing* — the
parts that make any new item exist, generate, identify, and fire an effect — is identical for
every item and is what this guide captures.

---

## How CE items are wired (orientation)

| Concern | Where |
|---|---|
| **Kind enums** (`SCROLL_*`, `POTION_*`, `CHARM_*`, `WAND_*`, weapon/armor kinds, …) | `Rogue.h` (`enum scrollKind`, `enum charmKind`, …) |
| **Item tables** (name, flavor, frequency, value, range, description) | `GlobalsBrogue.c` (`scrollTable_Brogue[]`, `charmTable_Brogue[]`, …) — plus **variant copies** in `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` |
| **Active table binding** | `Globals.c` holds `const itemTable *scrollTable;` etc.; `initializeGameVariant*()` points them at the active variant's arrays |
| **Kind counts** | `gameConst->numberScrollKinds` etc. = `sizeof(table)/sizeof(itemTable)` — **auto-derived**, there is no `NUMBER_*_KINDS` constant to bump |
| **Effect dispatch** | `Items.c` — `apply()` routes by category to per-category handlers (`useCharm()`, the scroll/potion handlers, the wand/staff bolt system) |
| **Effect magnitude/duration** (charms) | `GlobalsBrogue.c` `charmEffectTable_Brogue[]`, read via `charmEffectDuration()` / `charmRechargeDelay()` in `PowerTables.c` — **indexed by kind**, so keep it enum-ordered |
| **Generation** | `Items.c` `chooseKind()` weights by each row's `frequency`; the per-category odds are `itemGenerationProbabilities_*` in `GlobalsBrogue.c`. **Frequency `0` ⇒ never generated as loot** |
| **Naming / identify** | `itemName()` and `magicCharDiscoverySuffix()` (`Items.c`) read the tables automatically — usually no change needed |

---

## The recipe

### 1. Add the kind enum — `Rogue.h`
Append to the end of the relevant family enum (order matters; effect tables are indexed by it):

```c
enum charmKind {
    ...
    CHARM_NEGATION,
    CHARM_REWIND // iOS port (iBrogue): ...
};
```

### 2. Add a table row — `GlobalsBrogue.c`
Match the existing field order for that category. Charm row layout
(`name, flavor, callTitle, frequency, marketValue, strengthRequired, power, range, identified, called, magicPolarity, magicPolarityRevealed, description`):

```c
{"rewinding", "", "", 0, 900, 0, 0, {1,2,1}, true, false, 1, false, "A cracked hourglass…"},
```

- **`frequency = 0`** keeps it out of the normal loot pool (obtainable only by explicit grant).
- ⚠️ **Variant tables.** If you add the row only to `charmTable_Brogue[]`, the Rapid/Bullet
  variants' tables won't have it and their `numberCharmKinds` will be smaller. Either add the
  row to every variant table, or guard any code that references the new kind with
  `KIND < gameConst->numberCharmKinds` (see the starting-grant guard below).

### 3. Add the effect — `Items.c`
Add a `case` in the per-category handler (`useCharm()` for charms; the scroll/potion handlers;
the bolt catalog for wands/staffs):

```c
case CHARM_REWIND:
    // ... effect ...
    break;
```

Charms set their own cooldown after the switch (`theItem->charges = charmRechargeDelay(...)`)
and are not consumed; scrolls/potions are consumed by the caller.

### 4. (Charms) add an effect-table entry — `GlobalsBrogue.c`
`charmEffectTable_Brogue[]` is indexed by kind, so append in enum order:

```c
{ .kind = CHARM_REWIND, .effectDurationBase = 0, .effectDurationIncrement = POW_0_CHARM_INCREMENT,
  .rechargeDelayDuration = 3000, .rechargeDelayBase = FP_FACTOR * 60 / 100,
  .rechargeDelayMinTurns = 1, .effectMagnitudeConstant = 10 }
```

`charmRechargeDelay()` returns `max(rechargeDelayMinTurns, effectDuration + rechargeDelayDuration·base^enchant)`.
A flat debug cooldown of N turns = `rechargeDelayDuration = 0`, `rechargeDelayMinTurns = N`.

### 5. Counts, identify, naming
Usually automatic — the `sizeof`-derived count, `itemName()`, and identify logic all read the
tables. Verify there's no place that hard-codes the old count.

---

## Patterns worth reusing

- **Debug-only / start-with-item.** Add a `D_*` compile flag next to the others in `Rogue.h`,
  then grant the item after the normal starting kit in `initializeRogue()` (`RogueMain.c`):

  ```c
  #if D_REWIND_CHARM_START
      if (CHARM_REWIND < gameConst->numberCharmKinds) { // variant-safe guard
          theItem = generateItem(CHARM, CHARM_REWIND);
          theItem = addItemToPack(theItem);
      }
  #endif
  ```

  Starting items are added deterministically inside `initializeRogue` (they are **not** recorded
  input events), so they reconstruct identically on replay and are recording-safe. Combine with
  `frequency = 0` so the item is *only* obtainable this way.

- **Deferred actions.** If an effect can't safely run re-entrantly from inside `executeEvent`
  (e.g. it re-initializes the game, drives playback, or must run between turns), don't do it in
  the effect `case`. Instead set a request flag on `rogue` there and service it at a safe point at
  the top of the live loop in `mainInputLoop()` (`IO.c`), guarded by `!playbackMode`. That's how
  the rewind charm avoided re-entering `seek()` mid-event.

- **Determinism is mandatory.** Any RNG the effect consumes during live play must use
  `RNG_SUBSTANTIVE` and reproduce identically on replay, or `OOSCheck` (`Recordings.c`) halts the
  game as out-of-sync. Never poke game state the recording can't reproduce from its input stream.

---

## Conventions (required by this repo)

- Mark **every** C edit with an `// iOS port (iBrogue):` comment so it's greppable.
- Log the change in **[BrogueCE/Engine/IOS_MODIFICATIONS.md](../../BrogueCE/Engine/IOS_MODIFICATIONS.md)**
  (what / why / where / gating) so future CE upstream merges can be reconciled.
- Record any accepted tradeoffs in **[KNOWN_CAVEATS.md](../../KNOWN_CAVEATS.md)**.
- Build via the **Xcode MCP server** (the Brogue workspace tab), not the `xcodebuild` CLI.

---

## Touch-point checklist

| Step | File | Change | Often automatic? |
|---|---|---|---|
| Kind enum | `Rogue.h` | add `<FAMILY>_<NAME>` at end of enum | — |
| Item table row | `GlobalsBrogue.c` (+ variant copies) | name/flavor/frequency/value/desc | — |
| Effect | `Items.c` | `case` in the category handler | — |
| Effect magnitudes (charms) | `GlobalsBrogue.c` | `charmEffectTable_*` entry | — |
| Kind count | `gameConst->numberXKinds` | `sizeof`-derived | ✅ |
| Identify / naming | `Items.c` | reads tables | ✅ |
| Generation frequency | table `frequency` field | `0` = never | — |
| Debug grant (optional) | `Rogue.h` + `RogueMain.c` | `D_*` flag + `generateItem`/`addItemToPack` | — |
| Deferred action (if needed) | `IO.c` `mainInputLoop()` | request flag serviced between turns | — |
| Docs | `IOS_MODIFICATIONS.md`, `KNOWN_CAVEATS.md` | log change + caveats | — |

---

## Gotchas we hit with the rewind charm

- **Variant tables bite.** `generateItem(CHARM, CHARM_REWIND)` indexed past the shorter
  Rapid/Bullet charm tables until we guarded it with `CHARM_REWIND < gameConst->numberCharmKinds`.
- **`charmEffectTable` is indexed by kind**, not searched — a misordered append silently reads the
  wrong row.
- **Re-entrancy.** The effect needed to re-init/replay the game, which is illegal from inside
  `executeEvent`; the deferred-flag-in-`mainInputLoop` pattern was required.
- **Recording is the source of truth.** Any state change that isn't a natural consequence of a
  recorded input (we re-applied a cooldown directly in memory) won't survive a save/reload — fine
  for debug, but note it.
