# Reusable components reference — start here before building new content

**This is the first stop when adding a monster, item, terrain, or effect.** Per
[ADR 0001](../adr/0001-deterministic-component-based-content.md), new content is *assembled from
existing building blocks*, not reinvented per entity. Before writing any bespoke code, work the
decision tree below and check the catalogs — most "new" content is a configuration of things that
already exist.

This reference covers the **BrogueCE 1.15** engine (`BrogueCE/Engine/`). The Classic 1.7.5 engine
(`iBrogue_iPad/BrogueCode/`) has analogous primitives; check there too if you're touching both.

---

## Decision tree

1. **Can existing data-driven flags / effect tables express it?** → just write a catalog entry
   (no new code). This covers the large majority of monsters and items.
2. **Needs logic no flag provides?** → compose the **shared helpers** (below) inside a *thin*
   per-entity hook (a single `if (monsterID == MK_X)` branch in `monstersTurn`, an effect-dispatch
   case for an item, etc.).
3. **Does that hook duplicate a behavior some other entity already implements bespoke?** → extract a
   shared primitive **now**, parameterized, and point both consumers at it. Validate against both.
4. **Never speculatively back-port** working content into the component model for consistency alone
   (ADR 0001: high risk, huge testing surface, no functional gain).

---

## The two component systems the engine already has

### A. Data-driven flags & tables — the *primary* component system. Compose these first.

- **Monsters:** the `creatureType` catalog entry already composes behavior from
  **`MONST_*` behavior flags** + **`MA_*` ability flags** + a `bolts[]` list + stats. This is a
  large menu of ready behaviors — flying, submerging, maintaining distance, fleeing near death,
  steal-and-flee, casting/summoning, kamikaze, immunities, gender, item-carrying, and more. **Full,
  authoritative catalog with every flag's meaning: [docs/game-data/MONSTERS_AUDIT.md](../game-data/MONSTERS_AUDIT.md).**
  Reach for bespoke AI (a custom `monstersTurn` branch) *only* when no flag combination expresses
  the behavior (e.g. the gold goblin's "flee to a specific exit, phased by HP").
- **Items:** behavior comes from the per-category effect tables + dispatch (potions/scrolls/staffs/
  wands/charms/rings), the bolt catalog, and the deferred-action pattern. Items have **no profile
  component** like the flee/loot ones below, and shouldn't get one (ADR 0001) — they compose from
  three data-driven seams instead (bolt verbs + modifiers, DF cascades, helpers/statuses). **The
  item-side deep-dive on composing those seams is [composing-items.md](composing-items.md); see also
  [docs/game-data/ITEMS_AUDIT.md](../game-data/ITEMS_AUDIT.md) and the recipe in
  [adding-an-item.md](adding-an-item.md).**
- **Terrain/effects:** the **`DF_*` dungeon-feature catalog** (`dungeonFeatureCatalog`) + tile flags
  (`T_*`, `TM_*`). Spawning a feature is one call (below); the catalog already has gases, fires,
  fungus, webs, etc.

### B. Shared code helpers — the toolkit that bespoke logic composes

Accurate as of this writing; confirm signatures in-engine before use.

**Pathing & movement**
| Primitive | Use for |
|---|---|
| `calculateDistances(map, dx, dy, blockingFlags, traveler, secretDoors, eightWays)` | Distance field to a point (force-seeds the destination, so it works even toward a stair the monster "avoids"). |
| `dijkstraScan(distanceMap, costMap, useDiagonals)` | Distance field from a hand-built **cost grid** (per-cell costs; `PDS_FORBIDDEN`/`PDS_OBSTRUCTION` = impassable). **Gotcha:** only seeds from cells with cost > 0 — the destination cell must be cost > 0 or the whole field is unreachable. |
| `nextStep(distanceMap, fromLoc, monst, preferDiagonals)` | Steepest-descent step down a field; respects `monsterAvoids`, blockers, diagonal walls. |
| `getSafetyMap(monst)` | Engine's flee-from-player field (descend it to flee — note it heads to the *farthest* cell, i.e. dead-end corners). |
| `monsterAvoids(monst, p)` | Is a cell off-limits for this monster (hazards, walls, **and stairs** — no non-player creature can stand on a stair tile). |
| `moveMonster` / `moveMonsterPassivelyTowards` | Execute a move / greedily step toward a target. |
| `getQualifyingLocNear` / `randomMatchingLocation` | Find a legal tile near a point / anywhere. |
| `distanceBetween` / `pathingDistance` | Chebyshev distance / terrain-aware path distance. |

**Monster lifecycle**
| Primitive | Use for |
|---|---|
| `generateMonster(MK_*, itemPossible, mutationPossible)` | Create a monster **and add it to the `monsters` list**. |
| `spawnHorde(...)` / `hordeCatalog` (`GlobalsBrogue.c`) | Normal random/grouped spawns by depth & frequency. |
| `killCreature(decedent, administrativeDeath)` | Death. `administrativeDeath=true` = vanish, no drops/FX (e.g. escapes); `false` = normal death (drops, blood, message). |
| `makeMonsterDropItem` / `carriedItem` + `MONST_CARRY_ITEM_*` | Carry/drop one hopper item (balance-safe). |
| `cloneMonster` | Duplicate (struct copy — clear any "owns special loot" flag on the clone). |

**Combat & effects**
| Primitive | Use for |
|---|---|
| `inflictDamage(attacker, defender, dmg, color, ignoresShield)` | Apply damage. **`attacker == NULL` ⇒ environmental (fire/gas/poison); non-NULL ⇒ a discrete attack** — the clean "real hit?" signal. |
| `spawnDungeonFeature(x, y, &dungeonFeatureCatalog[DF_*], refresh, all)` | Bloom gas/fire/fungus/web/etc. at a tile. |
| `throwItem(item, thrower, target, maxDistance)` | Lob an item (thrower may be a monster). |
| bolt system (`BOLT_*`, `monsterCatalog.bolts[]`) | Ranged/cast abilities without custom code. |

**Items, text, RNG**
| Primitive | Use for |
|---|---|
| `generateItem(category, kind)` | Mint an item; `kind = -1` rolls a random kind honestly (enchant/runic/curse). |
| `placeItemAt(item, dest)` | Drop an item on the floor (sets `HAS_ITEM`). |
| `monsterName` / `resolvePronounEscapes(buf, monst)` / `message` | Build & print flavor text with `$HESHE`/`$HISHER`/`$HIMHER` tokens. |
| `rand_range` / `rand_percent` / `randRange` | **The substantive (seeded) RNG — use this for all game state.** Never `RNG_COSMETIC` for state (ADR 0001). |

---

## Candidate behavior components — bespoke today, extract on next reuse

**The flee/escape AND loot behaviors are now real, reusable components** (the flee component built
2026-06-13 as the first dogfood of this model, the loot component the same day as the second).
Everything in the *flee* and *loot* groups below ships as the generic functions named; the gold goblin
is the reference consumer of both (flee config `goldGoblinFleeProfile` via the catalog `fleeAI` field;
loot config `goldGoblinLoot` + `goldGoblinMarquee` via the catalog `loot` field). After these two,
**no `MK_GOLD_GOBLIN` branch remains in the engine** — the goblin is defined entirely by catalog
config. Only the **once-per-run pinned spawn** remains gold-goblin-specific, the *next* extraction
candidate — to be lifted on next reuse, per [ADR 0001](../adr/0001-deterministic-component-based-content.md),
not speculatively.

| Behavior | Status | Reusable form |
|---|---|---|
| Flee toward a target, swinging wide around the player | ✅ **built** | `monsterStepTowardAvoidingPlayer(monst, target, berth, berthCost)` (+ `monsterFleeDistanceMap`) |
| Keep maximum distance (elusive) | ✅ **built** | `monsterKeepDistanceStep(monst)` |
| Toss a screen onto the just-vacated tile | ✅ **built** | `monsterTossFeatureBehind(monst, dfType, vacatedTile)` |
| HP-phased keep-distance → break-for-exit switch | ✅ **built** | the `breakForExitBelowHpPct` branch in `fleeAITakesTurn` |
| Adjacency-escape at the exit stair | ✅ **built** | `fleerAtExit` / `fleerEscape` |
| Whole flee/escape turn, config-driven | ✅ **built** | `fleeAITakesTurn(monst, const fleeProfile *)` + `fleerState` runtime + `fleeProfile` config |
| Roll one item from a weighted pool | ✅ **built** | `rollLootTable(const lootEntry *)` ({0}-weight-terminated table) |
| Place loot (trail at self / scatter near origin) | ✅ **built** | `monsterShedItem(monst, item)` / `monsterScatterItem(item, origin)` |
| Per-hit shed + one-time near-death bonus | ✅ **built** | `monsterShedLootOnHit(monst, attacker, damage)` |
| Death hoard (marquee + gold burst + thrown stack), config-driven | ✅ **built** | `monsterDropDeathLoot(monst)` + `lootState` runtime + `lootProfile` config |
| Once-per-run pinned spawn | candidate | `spawnUniqueNear(MK_*, anchor, depthRange, chance, &flag)` (now `spawnGoldGoblin`) |

---

## Worked example: a flee-to-exit creature

This is **the shipping flee component** (built 2026-06-13), using a flee-creature as the case study —
the test being "does a *second* such creature drop out as data, not code?" (It does.) The structs and
functions below are real; the gold goblin is the first consumer.

**First, the decision-tree check:** existing flags get you partway — `MONST_FLEES_NEAR_DEATH` flees
under 25% and `MONST_MAINTAINS_DISTANCE` backs off — but both flee *away from the player* (safety
map), not *to a chosen exit*. "Flee to the up stairs" is expressible by no flag, so it earns a
component.

Three pieces (config + system + per-instance state):

```c
// COMPONENT (config): static, shared, attached to the catalog entry.
typedef struct fleeProfile {
    enum { FLEE_ON_SIGHT, FLEE_ON_DAMAGE } trigger;
    enum { EXIT_UP, EXIT_DOWN, EXIT_NEAREST } exit;  // which stair counts as escape
    short breakForExitBelowHpPct;  // 100 = always run for the exit; 50 = keep distance until wounded; 0 = pure kite (never escapes)
    short playerBerth;             // how wide to route around the player
    short fleeMemoryTurns;         // run-on after losing sight
    boolean rerouteWhenBlocked;    // head for the OTHER stair to reposition (non-escape) when the exit route is blocked
    short tossFeatureType;         // DF_* dropped on the just-vacated tile on the first break step (0 = none)
    boolean forfeitLootOnEscape;
} fleeProfile;
```

- **Assign the component:** add `const fleeProfile *fleeAI;` to `creatureType`, set it in the catalog
  (`NULL` = normal AI).
- **One shared system** — `fleeAITakesTurn(monst, profile)`, the generalized `goldGoblinTakesTurn` —
  reads the profile and composes the candidate primitives above (`stepTowardAvoidingPlayer`,
  `keepDistanceStep`, `tossFeatureBehind`, `reachedStairs`/`escapeUpstairs`, the HP-phase switch).
- **Per-instance runtime state** — the `fleerState` sub-struct on `creature` (above).

Dispatch is then **one data-driven branch for every flee-creature** (no per-monster branch):

```c
// in monstersTurn(), before the normal AI:
if (monst->info.fleeAI) { fleeAITakesTurn(monst, monst->info.fleeAI); return; }
```

A new "flees upstairs" creature is then **just a config row** — no new behavior code:

```c
// Minimal skulker: bolts for the up stairs the instant it's hit, keeps its distance, no theatrics.
static const fleeProfile SKULKER_FLEE = {
    .trigger = FLEE_ON_DAMAGE, .exit = EXIT_UP, .breakForExitBelowHpPct = 100,
    .playerBerth = 4, .fleeMemoryTurns = 10, .rerouteWhenBlocked = true,
    .tossFeatureType = 0, .forfeitLootOnEscape = false,
};

// The gold goblin is the SAME system, richer config:
static const fleeProfile GOLD_GOBLIN_FLEE = {
    .trigger = FLEE_ON_SIGHT, .exit = EXIT_UP, .breakForExitBelowHpPct = 50,  // keep distance, then run when wounded
    .playerBerth = 4, .fleeMemoryTurns = 10, .rerouteWhenBlocked = true,
    .tossFeatureType = DF_FUNGUS_FOREST, .forfeitLootOnEscape = true,
};
```

That the goblin and a bare skulker differ only in *config* is the signal the abstraction is real.

**Keep the seams orthogonal.** Loot and spawn are *separate* components, not part of the flee
profile, so you can mix and match (a fleeing monster with no special loot; a stationary monster with a
hoard):

- `lootProfile` — ✅ **built** (the second dogfood). A `lootEntry` weighted table (`marquee`) +
  depth-scaled death gold + an optional depth-gated `lootThrownStack` + a per-hit gold trail + a
  one-time near-death bonus. Attached to the catalog `loot` field; consumed by `monsterShedLootOnHit`
  (in `inflictDamage`) and `monsterDropDeathLoot` (in `killCreature`). Runtime state is `lootState`
  (`isBearer`, set in `initializeMonster` for any creature whose `info.loot != NULL` and cleared in
  `cloneMonster` so clones are loot-less; `bonusDropped`). Because the bearer flag is initialized
  generically, **giving a monster a `lootProfile` is enough — no custom spawn code required.**
  This is *net-new* loot — use `MONST_CARRY_ITEM_*` instead for an ordinary single carried drop drawn
  from the dungeon's item budget. The gold goblin's config is `goldGoblinLoot` (Globals.c). A second
  looting creature is just another `lootEntry` table + `lootProfile` row.
- `spawnProfile` — *candidate.* Anchor stair, depth range, chance, once-per-run — would be consumed by
  `initializeLevel` (or a plain `hordeCatalog` entry for normal spawns). Still bespoke in
  `spawnGoldGoblin`; extract on next reuse.

**Limits, honestly:** the `dijkstraScan`/stairs gotchas live *inside* the shared primitives, so a new
creature can't re-trip them — but genuinely novel movement (teleporting, burrowing) is a *new*
primitive plus a profile field, written once and then reusable. The profile only covers behaviors we
have actually built.

**Doing the refactor safely:** introduce `fleeProfile` + `fleeAITakesTurn`, point the gold goblin at
`GOLD_GOBLIN_FLEE`, and confirm it plays identically (the regression check) — then the skulker is free.
Per [ADR 0001](../adr/0001-deterministic-component-based-content.md) this happens *when a second
flee-creature is actually wanted*, not as a speculative standalone pass.

---

## Sharp edges — read before adopting a component

These were surfaced auditing the gold goblin (2026-06-13). None block reuse; they're the seams to know.

- **The flee dispatch returns early, bypassing the rest of `monstersTurn`.** Status counters that end a
  turn (paralysis, frozen, entrancement, captivity) are handled *above* the dispatch, so they still work.
  **Discord** is handled explicitly: a discordant fleer is dropped out of `MONSTER_FLEEING` so the engine's
  discord logic engages (it turns on the nearest creature instead of escaping — a clean player counter),
  and the flee AI resumes when discord ends. But the early `return` still skips `updateMonsterState`, scent
  transitions, and any per-turn `DFType` aura. The goblin needs none of those; a future fleer that **attacks**
  (so wants normal targeting), or that **emits a terrain aura**, must fold that into the flee component
  rather than expect the normal tail to run.
- **Loot tables are `{0}`-weight-terminated** (`rollLootTable` walks to the sentinel), so there's no count
  to keep in sync — but the array *must* end in a `{0}` row or the walk runs off the end. `rand_range` is
  defensive (a zero/degenerate range returns its low bound and consumes no RNG), so a malformed table can't
  crash, but it can silently mis-roll. Keep weights positive and the sentinel present.
- **Loot scales with spawn count.** A `lootProfile` is net-new gold/items; on a once-per-run pinned monster
  that's within seed noise (see the goblin's leaderboard analysis), but the *same* profile on a horde monster
  multiplies by every spawn and can skew the gold-based leaderboard. Size loot to expected spawn frequency.
- **`fleeAI` and `loot` are positional trailing columns** in `monsterCatalog`, relying on C zero-init for the
  rows that omit them. Append new `creatureType` fields; never insert/reorder, or every catalog row shifts.

---

## See also

- [adding-a-creature.md](adding-a-creature.md) — the monster recipe + the gold goblin issues log.
- [adding-an-item.md](adding-an-item.md) — the item recipe.
- [docs/adr/0001](../adr/0001-deterministic-component-based-content.md) — why (determinism +
  components) and the abstraction policy.
- [docs/game-data/MONSTERS_AUDIT.md](../game-data/MONSTERS_AUDIT.md) /
  [ITEMS_AUDIT.md](../game-data/ITEMS_AUDIT.md) — the authoritative flag/stat catalogs.
