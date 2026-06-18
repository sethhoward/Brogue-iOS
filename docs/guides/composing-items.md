# Composing items from existing parts — the item-side reference

**Before building a new item, read this.** It is the item-focused companion to
[reusable-components.md](reusable-components.md) (the general "first stop" — flags, the shared-helper
toolkit, and the flee/loot *creature* components). This guide goes deep on the **three composition
seams that items are built from**, so a "new" item is usually a configuration of things that already
exist rather than fresh code.

Related references:
- [reusable-components.md](reusable-components.md) — the decision tree, the shared-helper toolkit, and
  the determinism / forward-only philosophy. **Everything there applies here too.**
- [adding-an-item.md](adding-an-item.md) — the mechanical recipe (kind enum, tables, per-variant
  copies, generation frequency, the deferred-action pattern, the debug grant).
- [docs/game-data/ITEMS_AUDIT.md](../game-data/ITEMS_AUDIT.md) — the authoritative catalog of every
  item with stats and frequencies.
- [ADR 0001](../adr/0001-deterministic-component-based-content.md) — determinism is mandatory; build
  from reusable components; abstraction is opportunistic and forward-only.
- [docs/design/staff-of-frost.md](../design/staff-of-frost.md) — the worked feature this guide draws
  its running example from.

This reference covers the **BrogueCE 1.15** engine (`BrogueCE/Engine/`).

---

## Items have no profile component — and shouldn't

Creatures got first-class behavior components (`fleeProfile` / `lootProfile` attached to the
`creatureType` catalog row + thin dispatch) because their bespoke AI genuinely duplicated across
entities. **Items have no `itemProfile` analog, and per [ADR 0001](../adr/0001-deterministic-component-based-content.md)
they should not get one speculatively.** They don't need it: item behavior is already assembled from
three data-driven seams. Those seams *are* the item "components." Reach for new C code only at the
bottom of the decision tree.

The two standing requirements still bind: **determinism** (drive all state from `rand_range` /
`rand_percent`, never `RNG_COSMETIC`), and **compose, don't copy-paste**.

---

## Layer 1 — Bolt verbs + modifiers (staffs & wands)

A staff or wand is almost entirely **one table row** that points at a **bolt**, and the bolt is itself
a composition of a *verb*, *modifiers*, and *terrain hooks*.

- A staff/wand row's `power` field is a `boltType` index; `boltForItem` (`Items.c:4512`) returns
  `tableForItemCategory(category)[kind].power`. The staff table is **shared** across variants
  (`staffTable[]`, `Globals.c:1744`), but the **`boltCatalog` is per-variant** — add a bolt row to
  `boltCatalog_Brogue` (`GlobalsBrogue.c:58`) *and* the Rapid/Bullet copies.
- The `bolt` struct (`Rogue.h:1937`) bundles: `boltEffect` (the `BE_*` verb), `magnitude` (tuning),
  `pathDF` (a DF spawned on every cell the bolt crosses), `targetDF` (a DF at the terminal cell),
  `forbiddenMonsterFlags` (who's immune), and `flags` (the `BF_*` modifiers).
- Dispatch: `updateBolt` (`Items.c:4532`) runs the `BE_*` switch per cell and applies `pathDF`
  (`Items.c:4886`); `detonateBolt` (`Items.c:4982`) runs the terminal effects and `targetDF`
  (`Items.c:5070`).

### The reusable `BE_*` verbs (`enum boltEffects`, `Rogue.h:1898`)

| Verb | Effect | Composes |
|---|---|---|
| `BE_DAMAGE` | Ranged damage (`staffDamage`) | `inflictDamage()`; with `BF_FIERY`, ignites |
| `BE_SLOW` | Halve speed | `slow()` |
| `BE_HASTE` | Double speed | `haste()` |
| `BE_FREEZE` | Encase in ice → slow on thaw | `STATUS_FROZEN` + `slow()` (see Layer 3) |
| `BE_POISON` | Stacking poison | `addPoison()` |
| `BE_TELEPORT` | Relocate target | `teleport()` |
| `BE_BECKONING` | Pull target toward caster | `beckonMonster()` |
| `BE_BLINKING` | Move the caster along the bolt | (used by the W_FORCE runic and the frost push) |
| `BE_POLYMORPH` | Transform target | `polymorph()` (`Items.c:4008`) |
| `BE_NEGATION` | Strip magic | `negate()` (`Items.c:3901`) |
| `BE_DOMINATION` | Convert to ally (RNG) | `becomeAllyWith()` |
| `BE_INVISIBILITY` | Hide target | `imbueInvisibility()` (`Items.c:4354`) |
| `BE_EMPOWERMENT` | Permanent ally buff | `empowerMonster()` |
| `BE_HEALING` | Restore HP | `heal()` |
| `BE_SHIELDING` | Absorb damage | `STATUS_SHIELDED` |
| `BE_ENTRANCEMENT` | Trance (mirror moves) | `STATUS_ENTRANCED` / `STATUS_CONFUSED` |
| `BE_DISCORD` | Turn on allies | `STATUS_DISCORDANT` |
| `BE_OBSTRUCTION` | Crystal wall | spawns `DF_FORCEFIELD` (density scales w/ magnitude) |
| `BE_CONJURATION` | Summon spectral blades | `generateMonster()` |
| `BE_TUNNELING` | Dig through stone | terrain edit + waypoint recompute |
| `BE_PLENTY` | Duplicate target | `cloneMonster()` |
| `BE_ATTACK` | Melee strike | `attack()` |

### The reusable `BF_*` modifiers (`enum boltFlags`, `Rogue.h:1924`)

`BF_PASSES_THRU_CREATURES` (pierce vs stop at first), `BF_HALTS_BEFORE_OBSTRUCTION` (stop one tile
short), `BF_TARGET_ALLIES` / `BF_TARGET_ENEMIES` (auto-aim), `BF_FIERY` (ignite terrain/creatures via
`exposeCreatureToFire`), `BF_ELECTRIC` (activate `TM_PROMOTES_ON_ELECTRICITY`, water-shock),
`BF_NEVER_REFLECTS`, `BF_NOT_LEARNABLE` (empowered allies can't absorb it), `BF_NOT_NEGATABLE`,
`BF_DISPLAY_CHAR_ALONG_LENGTH`.

**A new staff/wand built from an existing verb + flags + a pathDF/targetDF is ~95% a table row.** The
staff of frost added one bolt row (`BE_FREEZE`, `pathDF = DF_DEEP_WATER_FREEZE`, `BF_TARGET_ENEMIES |
BF_NOT_LEARNABLE`) per variant plus one shared `staffTable` row.

---

## Layer 2 — Dungeon-feature cascades (environmental effects)

Any terrain/atmospheric effect is a `dungeonFeatureCatalog` row (`Globals.c`). One row composes:

- **tile + layer** — what terrain, on which of `DUNGEON / LIQUID / GAS / SURFACE`.
- **spread** — `startProbability` + `probabilityDecrement` (origin is always placed; the decrement
  governs how far it bleeds outward).
- **`propagationTerrain`** — a *foundation gate*: the feature only lands where this tile type already
  exists (so firing it over the wrong terrain is a no-op).
- **`subsequentDF`** — *chaining*: after this row resolves at a cell, the next DF is tried there too.

The frost staff's water→foliage freeze (`Globals.c:783`–`797`) is a pure cascade: `DF_DEEP_WATER_FREEZE`
gates on deep water and chains through the algae variants to `DF_SHALLOW_WATER_FREEZE`, which chains to
`DF_FROZEN_FOLIAGE` (gated on `FOLIAGE`). One `pathDF` therefore freezes water *and* plants along the
ray, each gated to the terrain that fits.

Two reusable terrain-decay idioms worth copying:
- **Edge-melt** — a negative `promoteChance` makes a tile melt faster the more dissimilar neighbors it
  has (the ice bridge dissolves from the rim inward; the interior outlives the edges).
- **Self-thaw under fire** — flag the tile `T_IS_FLAMMABLE` with its `fireType` pointing at the
  thaw-back DF, so fire "burns" it straight back to its base terrain (how ice melts).

**Crucially, `spawnDungeonFeature(x, y, &dungeonFeatureCatalog[DF_*], …)` (`Architect.c:3489`) is the
universal trigger.** The bolt's `pathDF` is just one caller. *Any* item — a thrown potion, a charm, a
scroll — can spawn `DF_DEEP_WATER_FREEZE` at a location to get the whole ice cascade for free, no new
terrain code.

---

## Layer 3 — Helpers + status-driven effects (creature effects)

The shared-helper toolkit is tabulated in [reusable-components.md](reusable-components.md) (section
"Shared code helpers"); the item-relevant verbs (all already exported, all reusable as-is):

| Helper | Where | Does |
|---|---|---|
| `slow(monst, turns)` | `Items.c:4072` | Set `STATUS_SLOWED`, cancel haste, halve speeds |
| `haste(monst, turns)` | `Items.c:4086` | Set `STATUS_HASTED` |
| `weaken(monst, dur)` | `Items.c:3994` | Strength penalty |
| `heal(monst, pct, panacea)` | `Items.c:4100` | Restore HP (panacea also cures confusion/nausea/hallucination) |
| `addPoison(monst, dur, conc)` | `Combat.c:1808` | Stack poison |
| `negate(monst)` | `Items.c:3901` | Strip magic |
| `exposeCreatureToFire(monst)` | `Time.c:30` | Ignite (and thaw frozen) |
| `extinguishFireOnCreature(monst)` | `Time.c:1928` | Douse a burning creature |
| `extinguishFireOnTile(x, y)` | `Time.c:1270` | Snuff terrain fire at a cell |
| `spawnDungeonFeature(...)` | `Architect.c:3489` | Bloom any DF (Layer 2) |

### The status-driven pattern (the most reusable of all)

Many effects are **just a status**: set `monst->status[STATUS_X] = monst->maxStatus[STATUS_X] = turns`
and the engine does the rest — `decrementMonsterStatus` (`Monsters.c:1956`) and `decrementPlayerStatus`
(`Time.c:2039`) tick it down, and the scattered gates read it. **Any source that sets the status gets
the whole behavior for free.**

`STATUS_FROZEN` (`Rogue.h:2097`) is the worked example: setting it gives you paralysis-style
action-gating (every `STATUS_PARALYZED` gate also checks `STATUS_FROZEN`), the thaw-to-slow handoff
(the slow is layered underneath at apply-time), the fire-thaw interaction, the shatter-on-hit, and the
icy render tint — **none of it tied to the bolt**. A potion, trap, or monster ability that sets
`STATUS_FROZEN` inherits all of it.

---

## The potion dispatch seam

Potions have two entry points, both already wired to Layers 2 and 3:

- **Drink** — `drinkPotion` (`Items.c:8252`): a `switch (theItem->kind)` that calls helpers or
  `spawnDungeonFeature` (e.g. caustic-gas/confusion/descent potions bloom a DF at the player).
- **Throw** — `shatterPotionAtLoc` (`Items.c:6543`) spawns the potion's DF cloud at the impact;
  `applyPotionEffectToCreature` (`Items.c:8191`) applies a direct effect to a creature the flask
  strikes (e.g. thrown fire-immunity douses a burning target via `extinguishFireOnCreature`).
- **Empty-bottle capture** maps gas/water tiles back to the potion that produces them — keep any new
  gas↔potion pairing consistent there.

So a thrown potion that "spawns a cloud and slows whatever it touches" is: one potion row + a
`shatterPotionAtLoc` case calling `spawnDungeonFeature(DF_*)` + an `applyPotionEffectToCreature` case
calling `slow()`. No new subsystems.

---

## Decision tree for a new item

Work top-down; stop at the first that fits (mirrors the general tree in
[reusable-components.md](reusable-components.md#decision-tree)):

1. **Expressible as an existing bolt verb + `BF_*` flags + a path/target DF?** → a staff/wand is a
   **table row** (bolt row ×3 variants + shared staff row). No code.
2. **An environmental effect?** → a **DF row / cascade** (Layer 2): pick tile/layer/spread, gate with
   `propagationTerrain`, chain with `subsequentDF`. Trigger with `spawnDungeonFeature`. Data only.
3. **A creature effect?** → **compose existing helpers** (Layer 3) or **set a status**. For a potion,
   that's a `drinkPotion` / `shatterPotionAtLoc` / `applyPotionEffectToCreature` case.
4. **A genuinely new mechanic** no verb/DF/status provides → then, and only then, new C: a new `BE_*`
   case (~15–40 lines reusing helpers) or a new `STATUS_*` (enum + decrement + gates + render tint —
   the larger cost). Add it parameterized so the *next* item can reuse it.

---

## Worked example: a frost potion (illustrative — NOT implemented)

The user's "could I make a frost potion that freezes water and slows, but isn't strong enough to freeze
solid?" — assembled almost entirely from parts that already exist:

- **Thrown → ice + chill.** In `shatterPotionAtLoc`, call
  `spawnDungeonFeature(x, y, &dungeonFeatureCatalog[DF_DEEP_WATER_FREEZE], true, false)` — the entire
  water/foliage ice cascade (Layer 2), free. The splash creates a temporary bridge / brittle wall just
  like the staff.
- **"Too weak to freeze solid, only slow."** This is *already a branch in the engine*: the `BE_FREEZE`
  case (`Items.c:4667`) takes a **slow-only** path for fiery/burning creatures. A weak frost item just
  always takes that path — call `slow(monst, …)` on creatures in the splash and **don't** set
  `STATUS_FROZEN`. (To freeze solid instead, set `STATUS_FROZEN` and layer the slow underneath, exactly
  as the staff does.)
- **Drink** → a self-effect (e.g. self-`slow`, or a fire-immunity-style defensive status), your call.
- **Duration** → reuse `staffFreezeSlowDuration` (`PowerTables.c:60`) or add a potion-specific scalar.

**The one extraction this would justify — and only then.** The freeze-*or*-slow *decision* (the
`MONST_FIERY`/burning check + the layered-slow) currently lives inline in the `BE_FREEZE` case. The
moment a frost potion becomes a real **second consumer**, lift it into a shared
`applyFrostToCreature(creature *, magnitude)` and point both the bolt and the potion at it — the same
dogfooding that produced the flee/loot components. Per [ADR 0001](../adr/0001-deterministic-component-based-content.md),
do this **when** the second consumer is built, not speculatively now.

---

## Forward-only, restated for items

Don't build an `itemProfile` framework "for symmetry" with creatures — the table / DF / helper /
status composition above already covers item behavior, and a speculative abstraction is exactly what
ADR 0001 forbids (high risk, huge testing surface, no functional gain). Extract a shared helper (like
`applyFrostToCreature`) **only** when a second item actually needs it, validated against both.
