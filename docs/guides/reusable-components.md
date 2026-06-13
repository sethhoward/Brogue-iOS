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
  wands/charms/rings), the bolt catalog, and the deferred-action pattern. **See
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

These behaviors exist *only* as the gold goblin's bespoke `goldGoblin*` code (`Monsters.c`). They are
the obvious shared monster-behavior primitives — but per ADR 0001 they should be lifted into generic
form **the next time a creature needs one**, not as a speculative refactor. When that happens, here's
the target shape (gold goblin becomes one of the two regression checks):

| Behavior | Lives now in | Proposed reusable form |
|---|---|---|
| Flee toward a target, swinging wide around the player | `goldGoblinStepToward` / `goldGoblinDistanceMap` | `monsterStepTowardAvoidingPlayer(monst, target, berth, berthCost)` |
| Keep maximum distance (elusive) | `goldGoblinKeepDistanceStep` | `monsterKeepDistanceStep(monst)` |
| Toss a screen onto the just-vacated tile | the flask block in `goldGoblinTakesTurn` | `monsterTossFeatureBehind(monst, dfType, vacatedTile)` |
| HP-phased behavior switch | the `< X% HP` branch in `goldGoblinTakesTurn` | `hpPhased(monst, pct, belowFn, aboveFn)` |
| Scatter curated loot on death | `goldGoblinDropHoard` / `goldGoblinScatterItem` | `monsterScatterLoot(monst, pool, counts)` |
| Once-per-run pinned spawn | `spawnGoldGoblin` (`Architect.c`) | `spawnUniqueNear(MK_*, anchor, depthRange, chance, &flag)` |
| Adjacency-escape at a stair | `goldGoblinAtUpStairs` + `goldGoblinEscapes` | `monsterReachedStairs(monst, loc)` / `monsterEscapeUpstairs(monst)` |

A reusable state sub-struct on `creature` (e.g. `fleerState { triggered; fleeTurns; fleeCommit; … }`)
should replace the per-monster `goldGoblin*` fields at the same time.

---

## See also

- [adding-a-creature.md](adding-a-creature.md) — the monster recipe + the gold goblin issues log.
- [adding-an-item.md](adding-an-item.md) — the item recipe.
- [docs/adr/0001](../adr/0001-deterministic-component-based-content.md) — why (determinism +
  components) and the abstraction policy.
- [docs/game-data/MONSTERS_AUDIT.md](../game-data/MONSTERS_AUDIT.md) /
  [ITEMS_AUDIT.md](../game-data/ITEMS_AUDIT.md) — the authoritative flag/stat catalogs.
