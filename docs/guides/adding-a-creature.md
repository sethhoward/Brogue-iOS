# Adding a creature to the BrogueCE engine

A reusable recipe for adding a new monster to the embedded **BrogueCE 1.15** engine
(`BrogueCE/Engine/`), plus the issues-and-solutions log from building the **gold goblin**
(`MK_GOLD_GOBLIN`) — a passive treasure-goblin with a bespoke flee/escape AI. Read this
alongside [adding-an-item.md](adding-an-item.md); the two share conventions (kind enums,
parallel tables, determinism rules, the debug "start with one" pattern).

All engine edits must follow the project rules: mark every change in-code with
`// iOS port (iBrogue):` and log it in [`BrogueCE/Engine/IOS_MODIFICATIONS.md`](../../BrogueCE/Engine/IOS_MODIFICATIONS.md);
build via the **Xcode MCP server**, not the CLI.

---

## 1. The monster data model

A creature is three parallel, index-aligned tables plus optional spawn/AI/combat hooks.

| What | Where | Notes |
|---|---|---|
| **Kind enum** `MK_*` | `enum monsterTypes` in `Rogue.h` | The index into the two tables below. |
| **Stats** `monsterCatalog[]` | `Globals.c` | `creatureType`: glyph, color, HP, defense, accuracy, `{dmgMin,dmgMax,clumping}`, `turnsBetweenRegen`, `movementSpeed`, `attackSpeed`, blood DF, light, isLarge, DFChance, DFType, `{bolts}`, **behaviorFlags** (`MONST_*`), **abilityFlags** (`MA_*`). |
| **Flavor** `monsterText[]` | `Globals.c` | `monsterWords`: `flavorText`, `absorbing`, `absorbStatus`, `attack[5][30]`, `DFMessage`, `summonMessage`. Uses `$HESHE`/`$HISHER`/`$HIMHER` pronoun tokens. |

`monsterCatalog` and `monsterText` are both sized `[NUMBER_MONSTER_KINDS]` and are read by
**index**, so the enum order, catalog order, and text order must stay in lock-step.

### Key field semantics (learned the hard way)

- **`turnsBetweenRegen`**: turns to regain 1 HP. **`0` = never regenerates** (gated on `> 0`
  in `Monsters.c`). Use 0 for a monster whose accumulated damage must "stick."
- **`movementSpeed`**: ticks per move; player = 100. **Lower = faster.** A continuously-fleeing
  monster at < 100 is effectively uncatchable, so match player speed (100) unless it pauses.
- **`defense`**: higher = harder to hit. ~25 is a "modest dodge / occasional miss"; 0 is a free
  hit; 70+ (spider) is slippery.
- **damage `{0,0,0}`** + never entering an attack state = a monster that never attacks.
- Random gender: set **both** `MONST_MALE | MONST_FEMALE`; `initializeGender()` clears one per
  spawn. `resolvePronounEscapes(buf, monst)` then fills the `$HESHE`-style tokens.
- **`MONST_NO_POLYMORPH`** keeps the kind out of the polymorph result table (so it can't be
  manufactured from a rat — important for anything with special loot).

### Index stability — append, don't insert

Add `MK_YOURMONSTER` **last in the enum** (just before `NUMBER_MONSTER_KINDS`) and append the
catalog and text entries at the **end** of their tables. Inserting in the middle shifts every
later kind's index; appending shifts nothing (only `NUMBER_MONSTER_KINDS` grows). Everything
else references kinds by name (`MK_*`), so position is otherwise irrelevant.

### Colors

Monster colors (e.g. `goblinColor`, `goldGoblinColor`) are defined at **file scope in
`Globals.c`** and referenced only by the catalog (same file), so they need **no `extern`**.
Add a `const color yourColor = {r,g,b, rRand,gRand,bRand, rand, dances};` near the others.

---

## 2. Generation: how it gets into the dungeon

Two routes:

- **Normal random spawns** → add a `hordeCatalog` entry in `GlobalsBrogue.c` (depth range,
  frequency, group composition, machine association). This is how most monsters appear.
- **A custom, pinned, or metered spawn** → a hook in `initializeLevel()` (`Architect.c`), the way
  `spawnGoldGoblin()` does it. Use this when you need exact placement (e.g. next to
  `rogue.downLoc`), a once-per-run cap (`rogue.goldGoblinSpawned`), or a probability the horde
  tables can't express. `placeStairs()` runs *before* `initializeLevel`, so `rogue.upLoc` /
  `rogue.downLoc` (and their `HAS_STAIRS` flags) are already valid in the hook.

Spawn primitive: `generateMonster(MK_*, itemPossible, mutationPossible)` creates the creature
**and adds it to the `monsters` list**; then set `monst->loc`, override any per-instance stats
(e.g. depth-scaled `maxHP`/`currentHP`), set `pmapAt(loc)->flags |= HAS_MONSTER`, and refresh the
cell if visible. Find a legal tile with `getQualifyingLocNear(&loc, target, hallwaysAllowed, NULL,
forbiddenTerrainFlags, forbiddenMapFlags, forbidLiquid, deterministic)`.

A per-run flag (e.g. `rogue.goldGoblinSpawned`) is reset in `initializeRogue()` (`RogueMain.c`,
next to `rogue.rewardRoomsGenerated = 0`).

---

## 3. Custom AI

The monster turn dispatcher is `monstersTurn()` (`Monsters.c`). To give a monster wholly bespoke
behavior, branch out **early** with an `if (monst->info.monsterID == MK_X) { yourTurn(monst); return; }`,
placed **after** the paralysis/entrancement/captive/dying/sleeping guards (so those status effects
still stop it) and **before** `updateMonsterState()` and the normal hunting/fleeing AI (so none of
it runs). Set `monst->ticksUntilTurn = monst->movementSpeed;` inside your turn function so even
"do nothing" turns are timed correctly.

This is the only "behavior dispatch" the engine has — **one branch per special monster, no behavior
tree, no per-turn planning.** Compose the pathing/combat primitives below inside that one function.

### Pathing toolkit

| Function | Use |
|---|---|
| `calculateDistances(map, destX, destY, blockingFlags, traveler, secretDoors, eightWays)` | Distance field to a point; **force-seeds the destination**, so it works even when the destination is a stair the monster "avoids". |
| `dijkstraScan(distanceMap, costMap, useDiagonals)` | Distance field from a **hand-built cost grid** (`short**`; `1`=normal, higher=costlier, `PDS_FORBIDDEN`/`PDS_OBSTRUCTION`=impassable). Use when you need per-cell costs (e.g. "stay away from the player"). **Gotcha below.** |
| `nextStep(distanceMap, fromLoc, monst, preferDiagonals)` | The steepest-descent step down a distance field; respects `monsterAvoids`, blockers, diagonal walls. Returns `NO_DIRECTION` if no downhill step. |
| `getSafetyMap(monst)` | Engine's flee-from-player field (descend it to flee). |
| `monsterAvoids(monst, p)` | Whether a cell is off-limits for this monster (hazards, walls, **and stairs**). |

---

## 4. Combat & death hooks

- **On damage**: `inflictDamage(attacker, defender, damage, color, ignoresShield)` (`Combat.c`).
  Add a hook near the top (after the wake-up block) keyed on `defender->info.monsterID`. The
  **`attacker` arg distinguishes a discrete attack (non-NULL: melee/bolt/thrown) from
  environmental damage (NULL: fire/gas/poison ticks)** — the cleanest signal for "was this a real
  hit?" The hook runs *before* HP is decremented, so the post-hit HP is `currentHP - damage`
  (pass `damage` in if you need it).
- **On death**: `killCreature(decedent, administrativeDeath)` (`Combat.c`). Add a hook after the
  `carriedItem` block. **`administrativeDeath == true` deletes the carried item (no drop) and skips
  death FX** — use it for "vanishes" (e.g. escaping up the stairs forfeits loot); `false` is a
  normal death (drops loot, blood, messages). Spawn custom loot here.

### Loot

- A single carried item: set `MONST_CARRY_ITEM_25`/`_100`; it's drawn from the finite, balance-safe
  `monsterItemsHopper` and dropped via `makeMonsterDropItem`.
- **Net-new / curated loot**: mint items with `generateItem(category, kind)` and place them with
  `placeItemAt` / a scatter helper using `getQualifyingLocNear`. This inflates the economy — a
  deliberate choice. Equipment categories with `kind = -1` roll honestly (random kind + natural
  enchant/runic/curse); pass a specific kind for guaranteed consumables.
- **Clone safety**: `cloneMonster` does a struct copy (`*newMonst = *monst`), so a "this one carries
  the hoard" flag (e.g. `goldGoblinHasHoard`) **must be cleared on the clone** or a staff of cloning
  duplicates the loot.

---

## 5. Determinism & saves (non-negotiable)

- **All gameplay RNG runs on the substantive stream** (`rand_range`, `rand_percent`, `randRange`)
  during seeded level-gen and normal turns. Don't switch to `RNG_COSMETIC` for anything that affects
  state. A spawn roll consumes RNG every eligible level even when it fails — that's fine, it's
  deterministic on replay.
- **Saves are recordings** (input replay, not struct dumps). Adding fields to `creature`/`rogue` never
  breaks the save format; only **replay determinism** matters, so set new fields deterministically.
- Recordings made *before* a generation change will desync afterward — expected for any new content.

---

## 6. Debug aids

- A standalone toggle, e.g. `#define D_ALWAYS_SPAWN_GOLD_GOBLIN 1` in `Rogue.h`. Unlike the `D_*`
  flags gated on `WIZARD_MODE`, a plain `1`/`0` works in a normal game; compiles out cleanly when 0.
  Use it to force a guaranteed early spawn.
- **Telepathically reveal** a debug spawn (`monst->bookkeepingFlags |= MB_TELEPATHICALLY_REVEALED;`)
  so you can watch it path/flee even out of sight (`monsterRevealed()` honors the flag).
- If pathing misbehaves, render the distance field: the engine has `hiliteGrid`/`displayGrid`
  (see `D_INSPECT_LEVELGEN`) to dump a `short**` map to screen.

---

## 7. Issues & solutions log — the gold goblin

The bespoke flee/escape AI took many iterations. The traps we hit, so you don't:

1. **`dijkstraScan` cost-map seeding (the big one).** `pdsBatchInput` only seeds the field from
   cells with **`cost > 0`**. We marked the destination **stair tile** `PDS_FORBIDDEN` (because
   `monsterAvoids` makes monsters avoid stairs) — so the destination was never seeded, its distance-0
   never propagated, and **the entire map read unreachable every turn**, silently. The monster fell
   through every fallback to the safety map and ran to the farthest corner, always. **Fix:** the
   destination cell must be enterable (`cost = 1`) in the cost grid. (`calculateDistances` sidesteps
   this by force-seeding via `pdsSetDistance`; the raw `dijkstraScan(costMap)` path does not.)
2. **Monsters can't stand on stairs.** `monsterAvoids` returns true for the up/down stair tiles for
   *every* non-player creature. So a monster can never path *onto* a staircase — detect "reached the
   exit" by **adjacency** (`distanceBetween(loc, stair) <= 1`), and escape from there.
3. **A pure flee map runs into dead ends.** `getSafetyMap` picks the cell *farthest* from the
   player — which is a dead-end corner. Fleeing by it alone makes the monster trap itself for free
   hits. **Fix:** flee toward a real destination (a stair / a target), not "away."
4. **Player-aware routing.** To make a monster route *around* the player (not through), build the
   cost grid with the player's tile costly (or forbidden) and cells near the player penalized on a
   **smooth gradient** (`GOLD_GOBLIN_PLAYER_BERTH`/`BERTH_COST`). A smooth penalty shifts the route
   continuously as the player moves; a hard reachable/unreachable flag **flickers** and makes the
   monster dither — add commitment/hysteresis (`goldGoblinFleeCommit`) if you must use a binary one.
5. **Greedy stepping side-steps and bounces.** `moveMonsterPassivelyTowards` toward a player-blocked
   target side-steps among equidistant cells (melee-range jitter). Use `nextStep` on a real distance
   field for monotonic progress instead.
6. **Geometry tension.** Spawn-point vs escape-point vs where-the-player-enters-from determines
   whether an exit is even reachable. The gold goblin spawns by the down stairs, escapes up, and the
   player enters from up — so the player is usually *between* it and its exit. We leaned into this
   (it's elusive, often cornered; escapes mainly via loops) rather than fighting it.
7. **HP-keyed behavior phases.** Splitting behavior by health (`>= 50%`: keep distance; `< 50%`:
   break for the exit) gave the encounter a clean arc and resolved most "what should it do when
   blocked" debates.
8. **Toss-an-item placement.** Throwing a screen (hallucinogen → `DF_FUNGUS_FOREST`) is most useful
   **behind** the fleer — bloom it on the tile it *just vacated* (always a valid cell: clear now, or
   holding the player), not point-blank where it screens nothing.

---

## 8. Architecture: are these behaviors reusable? (Honest answer: not yet)

> Before building a new creature, start at the **[reusable-components reference](reusable-components.md)**
> and [ADR 0001](../adr/0001-deterministic-component-based-content.md) — compose existing
> flags/helpers first; only the truly novel logic should be bespoke.


Everything above the data tables is currently **bespoke to `MK_GOLD_GOBLIN`** — `goldGoblin*`
functions hardcode the kind, read `goldGoblin*` creature fields, and are wired in by a single
`if (monsterID == MK_GOLD_GOBLIN)` branch. Adding a second "fleeing treasure" creature today would
mean copy-paste-and-rename. The engine has no behavior-component system; its only composition unit
is "one bespoke turn function per special monster."

**The discrete behaviors are, however, cleanly separable** and could be lifted into reusable
primitives without a behavior-tree rewrite:

- `monsterStepTowardAvoidingPlayer(monst, target, berth, berthCost)` ← `goldGoblinStepToward` + `goldGoblinDistanceMap`
- `monsterKeepDistanceStep(monst)` ← `goldGoblinKeepDistanceStep`
- `monsterTossScreenBehind(monst, dfType, vacatedTile)` ← the flask logic
- `monsterScatterLoot(monst, ...)` / `monsterShedItem(monst, item)` ← the loot helpers
- A small reusable sub-struct on `creature` (e.g. `fleerState { triggered; fleeTurns; fleeCommit; threwScreen; ... }`) replacing the `goldGoblin*` fields.

A new fleeing creature would then be a **short turn function composing those primitives** with its
own constants — the "assign reusable behaviors" goal, achieved the BrogueCE-idiomatic way (shared
helpers + a thin per-monster dispatch) rather than a data-driven behavior engine.

**Recommendation:** do this extraction as a *separate, deliberate refactor* with the gold goblin as
the regression check — **not** bundled into feature work, since it touches just-tuned, working code.
Until then, treat the `goldGoblin*` functions as the reference implementation to copy.
