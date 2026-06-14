# Machines & room-placement audit (BrogueCE 1.15)

This documents the **machine** system in the BrogueCE 1.15 engine (`BrogueCE/Engine/`): how
reward rooms, vaults, vestibules, flavor areas, and our iOS-port altars get placed into the
dungeon, **why the `roomSize` window decides whether a machine can appear at all**, and a full
audit of the Brogue `blueprintCatalog`. Citations are `file:line` against the engine source; if
the engine changes, regenerate.

> **Terminology.** Brogue calls every prefab structure a *machine* — not just mechanical
> contraptions. A "machine" is anything built from a `blueprint`: reward vaults, key/guardian
> puzzles, captive-monster rooms, door guards (*vestibules*), purely cosmetic *flavor* areas
> (swamp, idyll, camp), and our altars of insight/transference. They all run through the same
> builder, `buildAMachine`.

---

## 1. Where it lives

| Concern | Location |
|---|---|
| Builder + placement | [`buildAMachine`](../../BrogueCE/Engine/Architect.c) — Architect.c:988 |
| Per-level machine scheduling | [`addMachines`](../../BrogueCE/Engine/Architect.c) — Architect.c:1847 |
| Choke / gate-site analysis | [`analyzeMap`](../../BrogueCE/Engine/Architect.c) — Architect.c:192 |
| Interior flood-fill | [`addTileToMachineInteriorAndIterate`](../../BrogueCE/Engine/Architect.c) — Architect.c:400 |
| Room/corridor carving | [`carveDungeon`](../../BrogueCE/Engine/Architect.c) / [`attachRooms`](../../BrogueCE/Engine/Architect.c) — Architect.c:2608 / 2519 |
| The catalog (Brogue) | `blueprintCatalog` in [GlobalsBrogue.c:178+](../../BrogueCE/Engine/GlobalsBrogue.c) |
| `blueprint` / `machineFeature` structs | [Rogue.h:2830 / 2869](../../BrogueCE/Engine/Rogue.h) |
| `BP_*` / `MF_*` flags | [Rogue.h:2851 / 2796](../../BrogueCE/Engine/Rogue.h) |
| `machineTypes` enum (blueprint indices) | [Rogue.h:2880](../../BrogueCE/Engine/Rogue.h) |
| Metering constants | `brogueGameConst` in [GlobalsBrogue.c:1051+](../../BrogueCE/Engine/GlobalsBrogue.c) |

The catalog is **per-variant**: Brogue, Rapid, and Bullet each have their own
`blueprintCatalog` (`GlobalsBrogue.c`, `GlobalsRapidBrogue.c`, `GlobalsBulletBrogue.c`). This
audit covers the **Brogue** catalog. Play grid is **79×29** (`DCOLS`×`DROWS`), `AMULET_LEVEL = 26`,
`DEEPEST_LEVEL = 40` ([GlobalsBrogue.c:43](../../BrogueCE/Engine/GlobalsBrogue.c), [Rogue.h:210](../../BrogueCE/Engine/Rogue.h)).

---

## 2. The level-generation pipeline (why rooms exist before machines)

Machines are placed *into an already-carved level*. They do not create the rooms they live in
(except `BP_REDESIGN_INTERIOR` ones); they **find** a pocket of the existing dungeon that matches
their `roomSize` and claim it. The order, from [`digDungeon`](../../BrogueCE/Engine/Architect.c) (Architect.c:~3040):

1. `clearLevel()` — fill with granite.
2. **`carveDungeon(grid)`** (Architect.c:2608) — place the first room, then `attachRooms` accretes
   ~35 more, each a randomly-chosen shape attached at a door site.
3. **`addLoops(grid, 20)`** (Architect.c:340) — punch *secondary* doorways between rooms whose
   pathing distance currently exceeds 20, converting the tree of rooms into a graph with loops.
4. Translate the grid to `FLOOR`/`DOOR` tiles (a grid==2 cell becomes a real `DOOR` 60% of the time).
5. `finishWalls`, then `designLakes`/`fillLakes` (water, lava, chasm, brimstone).
6. `runAutogenerators(false)` — non-machine terrain & dungeon-features (Architect.c:1910).
7. `removeDiagonalOpenings`.
8. **`addMachines()`** (Architect.c:1847) — **the subject of this doc.**
9. `runAutogenerators(true)` — the *machine* autogenerators (traps, flavor machines, etc.).
10. `cleanUpLakeBoundaries`.

The crucial consequence: **the topology of rooms and corridors is fixed before `addMachines`
runs.** Whether a level *can* host a given room machine depends entirely on what shapes step 2–3
happened to produce. This is why placement is probabilistic and seed-dependent.

### Room shapes (`designRandomRoom`, Architect.c:2426)

`attachRooms` picks each room from these types by frequency:

| # | Generator | Rough footprint |
|---|---|---|
| 0 | `designCrossRoom` | medium "+" |
| 1 | `designSymmetricalCrossRoom` | small symmetric "+" |
| 2 | `designSmallRoom` | small rectangle |
| 3 | `designCircularRoom` | small–medium disc |
| 4 | `designChunkyRoom` | irregular blob |
| 5 | `designCavern` (compact / N-S / E-W) | small-to-long cave |
| 6 | `designCavern` (full) | huge cave (≥50×20) |
| 7 | `designEntranceRoom` | the level's entry room |

A room's *machine-relevant* size is **not** its tile count — it is the choke-region size measured
in §3.

---

## 3. The choke map & gate sites — *why size decides placement*

This is the heart of the system and the answer to "certain sizes are more likely to be placed."

`analyzeMap(calculateChokeMap=true)` ([Architect.c:192](../../BrogueCE/Engine/Architect.c)) runs in two passes:

### 3a. Find chokepoints (Architect.c:246)
A passable, non-loop cell is an `IS_CHOKEPOINT` if blocking it would pinch the local passable arcs
— intuitively, a *single-tile doorway* between two regions. Cells inside loops can never be
chokepoints (you can always go around).

### 3b. Build the choke map (Architect.c:271)
For every chokepoint adjacent to open floor, the engine pretends that chokepoint is walled and
flood-fills the region now cut off. The size of that sealed region (`cellCount`) is written into
`chokeMap[][]` for every cell in it (taking the *minimum* across competing chokepoints), and the
chokepoint tile itself is flagged **`IS_GATE_SITE`** with that size.

```
chokeMap[x][y] = number of cells sealed off behind the nearest exit chokepoint.
IS_GATE_SITE   = "this doorway gates a dead-end pocket of size chokeMap[x][y]."
```

Two hard rules fall out of this code:

- **Regions smaller than 4 cells are ignored** (`if (cellCount >= 4)`, Architect.c:314). A pocket
  of 1–3 tiles never becomes a gate site, so **no machine can ever target a region < 4**.
- **Cells already inside another room machine are roped off** (`IS_IN_ROOM_MACHINE` →
  `passMap=false`, Architect.c:286) before the flood-fill, so a level's second machine cannot reuse
  the first machine's pocket.

### 3c. How `roomSize` gates a `BP_ROOM` machine
When `buildAMachine` places a `BP_ROOM` blueprint it scans for gate sites whose region size lands
**inside the blueprint's `roomSize[0..1]` window** ([Architect.c:1087–1099](../../BrogueCE/Engine/Architect.c)):

```c
if ((pmap[i][j].flags & IS_GATE_SITE)
    && !(pmap[i][j].flags & IS_IN_MACHINE)
    && chokeMap[i][j] >= blueprintCatalog[bp].roomSize[0]
    && chokeMap[i][j] <= blueprintCatalog[bp].roomSize[1]) { ... eligible gate ... }
```

It collects up to 50 eligible gates, picks one at random, and floods the interior from there
(`addTileToMachineInteriorAndIterate`, Architect.c:400) by walking cells of equal-or-lower choke
value. **If zero gates qualify, the build fails** (Architect.c:1106).

> **This is the whole story behind "some sizes are more placeable."** A blueprint with
> `roomSize {7,14}` only fits a dead-end pocket holding 7–14 cells behind one doorway. If every
> dead-end on the level is either smaller than 7 or larger than 14, the machine cannot be placed —
> no matter how many times you retry. A **wider** window (e.g. `{10,30}`) matches far more of the
> pockets a random level produces, so it places reliably. A **narrow or low** window is fragile.
> Flagged directly by the 2026-06-14 insight-altar fix (§8).

`BP_OPEN_INTERIOR` / `BP_MAXIMIZE_INTERIOR` then widen the claimed interior after the fact, and
`BP_REDESIGN_INTERIOR` bulldozes it and lays down fresh rooms from a dungeon profile — but the
*entry gate still has to qualify by `roomSize` first*.

Non-`BP_ROOM` machines don't use gate sites: `BP_VESTIBULE` machines must be handed an explicit
door location (Architect.c:1125), and `BP_ADOPT_ITEM`/flavor machines without `BP_ROOM` find a
location by other means (e.g. `MF_BUILD_ANYWHERE_ON_LEVEL`).

---

## 4. `buildAMachine` — the builder (Architect.c:988)

Signature: `buildAMachine(bp, originX, originY, requiredMachineFlags, adoptiveItem, parentItems, parentMonsters)`.

1. **Blueprint selection** (if `bp <= 0`): sum the `frequency` of every blueprint that
   `blueprintQualifies` (matches the required `BP_*` flags *and* the current depth's `depthRange`),
   then draw one by weighted raffle (Architect.c:1040–1075). A blueprint with `frequency 0` never
   enters the raffle — it can only be force-built by passing its explicit index.
2. **Location** (if not given): for `BP_ROOM`, the gate-site scan of §3c; for `BP_VESTIBULE`, the
   caller-supplied door.
3. **Map the interior**, then run up to 10 outer attempts (`failsafe`, Architect.c:1020) re-rolling
   blueprint/location on transient failures.
4. **Place features** in order. Each `machineFeature` row generates terrain/DF/items/monsters under
   its `MF_*` constraints; `minimumInstanceCount` aborts the whole machine if it can't place enough.
5. Connectivity & adoption checks (`BP_TREAT_AS_BLOCKING`, `BP_ADOPT_ITEM`, vestibule spawning),
   then commit.

Failure modes (each returns `false`): no qualifying blueprint for depth+flags (Architect.c:1051);
no eligible gate site (Architect.c:1106); interior flood hit another machine (Architect.c:411);
a feature missed its `minimumInstanceCount`; connectivity violation. **Callers retry** — see §5.

---

## 5. `addMachines` — per-level scheduling (Architect.c:1847)

Runs once per level, in this order:

1. **Bullet-variant L1 weapon vault** (Bullet only).
2. **Amulet holder** at `AMULET_LEVEL` (26): force-build `MT_AMULET_AREA`, up to 50 tries.
3. **Altars of insight** (Brogue only, iOS port) — force-built at depths **5 and 15** with a
   carry-forward schedule and a depth-20 cutoff (§8).
4. **Metered reward rooms** — the random reward raffle:

```c
while (depthLevel <= deepestLevelForMachines
    && (rewardRoomsGenerated + machineCount) * machinesPerLevelSuppressionMultiplier
        + machinesPerLevelSuppressionOffset < depthLevel * machinesPerLevelIncreaseFactor) {
    machineCount++;   // ~one guaranteed reward every few levels
}
// then a random bonus pass (40% the first one if none yet, else 15% each)
```

Brogue metering constants ([GlobalsBrogue.c:1073+](../../BrogueCE/Engine/GlobalsBrogue.c)):

| Constant | Value | Effect |
|---|---|---|
| `machinesPerLevelSuppressionMultiplier` | 4 | each existing reward suppresses the next |
| `machinesPerLevelSuppressionOffset` | 2 | baseline suppression |
| `machinesPerLevelIncreaseFactor` | 1 | reward pressure grows ~1/level |
| `maxLevelForBonusMachines` | 2 | extra-generous bonus roll only on early levels |
| `deepestLevelForMachines` | 26 | no reward rooms below the amulet level |

Each metered reward calls `buildAMachine(-1, -1, -1, BP_REWARD, …)` (Architect.c:1900), so it draws
a *random* `BP_REWARD` blueprint whose `depthRange` covers the current depth — **the reward you
get is filtered by depth and weighted by `frequency`.** Up to 50 build attempts back the whole
loop.

---

## 6. Flag reference

### Blueprint flags (`BP_*`, Rogue.h:2851)
| Flag | Meaning |
|---|---|
| `BP_ADOPT_ITEM` | machine must adopt an item (e.g. a door key from a vestibule) |
| `BP_VESTIBULE` | spawns in a given doorway and expands to guard the room behind it |
| `BP_PURGE_PATHING_BLOCKERS` | clear traps/blockers from the interior |
| `BP_PURGE_INTERIOR` | wipe all interior terrain before building |
| `BP_PURGE_LIQUIDS` | wipe interior liquids |
| `BP_SURROUND_WITH_WALLS` | wall off any impassable perimeter gaps |
| `BP_IMPREGNABLE` | interior/perimeter immune to tunneling |
| `BP_REWARD` | enters the metered reward raffle |
| `BP_OPEN_INTERIOR` | clear interior walls, widen until convex |
| `BP_MAXIMIZE_INTERIOR` | as above but expand as far as possible |
| `BP_ROOM` | **place in a dead-end pocket dominated by a chokepoint of `roomSize`** |
| `BP_TREAT_AS_BLOCKING` | abort if walling the interior would break level connectivity |
| `BP_REQUIRE_BLOCKING` | abort *unless* it would break connectivity (forces bridges/catwalks) |
| `BP_NO_INTERIOR_FLAG` | don't mark the area as a machine (flavor terrain) |
| `BP_REDESIGN_INTERIOR` | nuke & pave: delete interior, build fresh rooms from a dungeon profile |

### Notable feature flags (`MF_*`, Rogue.h:2796)
`MF_GENERATE_ITEM`, `MF_GENERATE_HORDE`, `MF_BUILD_AT_ORIGIN` (at the entry door),
`MF_BUILD_IN_WALLS` (statues/torches in the perimeter), `MF_BUILD_VESTIBULE` (spawn a door-guard
machine at the origin), `MF_EVERYWHERE` (carpet the whole interior), `MF_ALTERNATIVE` /
`MF_ALTERNATIVE_2` (pick exactly one feature from a set — how reward rooms choose *which* prize),
`MF_TREAT_AS_BLOCKING`, `MF_PERMIT_BLOCKING`, `MF_NEAR_ORIGIN` / `MF_FAR_FROM_ORIGIN`,
`MF_NOT_IN_HALLWAY`, `MF_OUTSOURCE_ITEM_TO_MACHINE` / `MF_ADOPT_ITEM` (key↔lock linkage),
`MF_MONSTERS_DORMANT` (statues/cages that burst on a trigger).

---

## 7. Catalog audit — Brogue `blueprintCatalog`

`depth` = `depthRange[0..1]`; `roomSize` = choke-region window (§3); `freq` = raffle weight (0 = never
in raffle; force-built or autogenerated only). `AL` = `AMULET_LEVEL` (26), `DL` = `DEEPEST_LEVEL` (40).

### 7a. Reward rooms (`BP_REWARD`, enter the raffle)
| Blueprint | depth | roomSize | freq | line |
|---|---|---|---|---|
| Mixed item library | 1–12 | 30–50 | 30 | GlobalsBrogue.c:186 |
| Single-category library | 1–12 | 30–50 | 15 | :194 |
| Treasure room (apothecary/archive) | 8–AL | 20–40 | 20 | :201 |
| Good permanent item on pedestal | 5–16 | 10–30 | 30 | :209 |
| Good consumable on pedestals | 10–AL | 10–30 | 30 | :217 |
| Commutation altars | 13–AL | 10–30 | 50 | :224 |
| Resurrection altar | 13–AL | 10–30 | 30 | :230 |
| Outsourced item (adopted by key machines) | 5–17 | 0–0¹ | 20 | :236 |
| Dungeon — two chained allies | 5–AL | 30–80 | 12 | :242 |
| Kennel — caged allies | 5–AL | 30–80 | 12 | :250 |
| Vampire lair | 10–AL | 50–80 | 5 | :257 |
| Legendary ally portal | 8–AL | 30–50 | 15 | :263 |
| Goblin warren² | 5–15 | 100–200 | 15 | :267 |
| Sentinel sanctuary² | 10–23 | 100–200 | 15 | :278 |
| **Altars of transference** [iOS] | 11–AL | 10–30 | 30 | :642 |

¹ `roomSize {0,0}` + `BP_NO_INTERIOR_FLAG`: not a room machine; its items are adopted by key
machines elsewhere via `MF_BUILD_ANYWHERE_ON_LEVEL`.
² `BP_MAXIMIZE_INTERIOR | BP_REDESIGN_INTERIOR`: needs a *large* pocket (100–200) and then rebuilds it.

### 7b. Amulet holder
| Statuary (amulet) — force-built at depth 26 | 10–AL | 35–40 | 0 | :292 |

### 7c. Vestibules (`BP_VESTIBULE`, door guards; `roomSize` is the *door*, usually 1)
| Blueprint | depth | roomSize | freq | line |
|---|---|---|---|---|
| Plain locked door | 1–AL | 1–1 | 100 | :301 |
| Plain secret door | 2–AL | 1–1 | 1 | :304 |
| Lever + exploding wall / portcullis | 4–AL | 1–1 | 8 | :307 |
| Flammable barricade | 1–6 | 1–1 | 10 | :312 |
| Statue door (shatter to enter) | 1–AL | 1–1 | 6 | :317 |
| Statue door (bursts to monster) | 5–AL | 2–2 | 6 | :321 |
| Throwing tutorial (portcullis) | 1–4 | 70–70 | 8 | :325 |
| Pit-trap entry field | 1–AL | 30–60 | 8 | :330 |
| Beckoning obstacle (mirrored totem) | 5–AL | 15–30 | 8 | :335 |
| Guardian obstacle | 6–AL | 25–25 | 8 | :341 |

### 7d. Key / guardian / challenge rooms (mostly `BP_ADOPT_ITEM`; reached *through* a vestibule)
These have `freq 0` for the reward raffle — they're pulled in to host the key a vestibule guards.
| Blueprint | depth | roomSize | line |
|---|---|---|---|
| Nested item library | 1–AL | 30–50 | :350 |
| Secret room (key on altar) | 1–AL | 15–100 | :359 |
| Throwing tutorial (cage key) | 1–4 | 70–80 | :363 |
| Rat trap | 1–8 | 30–70 | :367 |
| Fun with fire | 3–10 | 80–100 | :372 |
| Flood room | 3–AL | 80–180 | :380 |
| Fire-trap room | 4–AL | 80–180 | :386 |
| Thief area | 3–AL | 15–20 | :393 |
| Collapsing floor | 1–AL | 45–65 | :397 |
| Pit-trap room | 1–AL | 30–100 | :402 |
| Levitation challenge | 1–13 | 75–120 | :407 |
| Web-climbing | 7–AL | 55–90 | :416 |
| Lava-moat room | 3–13 | 75–120 | :423 |
| Lava-moat area | 3–13 | 40–60 | :432 |
| Poison-gas trap | 4–AL | 35–60 | :439 |
| Explosive situation | 7–AL | 80–90 | :448 |
| Burning-grass | 1–7 | 40–110 | :455 |
| Statuary (key) | 10–AL | 35–90 | :463 |
| Guardian water puzzle | 4–AL | 35–70 | :467 |
| Guardian gauntlet | 6–AL | 50–95 | :473 |
| Guardian corridor | 4–AL | 85–100 | :481 |
| Sacrifice altar | 4–AL | 20–60 | :490 |
| Summoning circle (DISABLED, freq 0) | 12–AL | 50–100 | :498 |
| Beckoning obstacle (key) | 5–AL | 60–100 | :502 |
| Worms in the walls | 12–AL | 7–7 | :508 |
| Mud pit | 12–AL | 40–90 | :512 |
| Electric crystals | 6–AL | 40–60 | :517 |
| Zombie crypt | 12–AL | 60–90 | :524 |
| Haunted house | 16–AL | 45–150 | :534 |
| Worm tunnels | 8–AL | 80–175 | :540 |
| Gauntlet (turrets) | 5–24 | 35–90 | :548 |
| Boss room | 5–AL | 40–100 | :552 |

### 7e. Thematic / flavor areas (`freq 0`; placed by machine autogenerators, not the reward raffle)
| Blueprint | depth | roomSize | line |
|---|---|---|---|
| Shrine (safe haven) | 1–DL | 15–25 | :564 |
| Idyll (ponds/grass) | 1–DL | 80–120 | :569 |
| Swamp | 1–DL | 50–65 | :573 |
| Camp | 1–DL | 40–50 | :577 |
| Remnant (carpet + statues) | 1–DL | 80–120 | :583 |
| Dismal | 1–DL | 60–70 | :587 |
| Chasm catwalk | 1–DL-1 | 40–80 | :592 |
| Lake walk | 1–DL | 40–80 | :598 |
| Paralysis trap (revealed) | 1–DL | 35–40 | :603 |
| Paralysis trap (hidden) | 1–DL | 35–40 | :607 |
| Trick statue | 1–DL | 5–5 | :611 |
| Worms in the walls (area) | 1–DL | 7–7 | :616 |
| Sentinels | 1–DL | 40–40 | :620 |

### 7f. iOS-port additions
| Blueprint | depth | roomSize | freq | placement | line |
|---|---|---|---|---|---|
| **Altars of insight** | 5–AL | **6–25** | 0 | force-built at 5 & 15 (§8) | :632 |
| **Altars of transference** | 11–AL | 10–30 | 30 | reward raffle (`BP_REWARD`) | :642 |

---

## 8. roomSize distribution — what's actually "placeable"

Plotting the `roomSize` windows of the **room machines that need a gate** (`BP_ROOM`, excluding
the 100–200 redesign rooms and the door-sized vestibules):

```
region size:   4    10    14   20   25   30        50        80       100
                |----|=====|----|----|----|=========|=========|========|
reward vaults                  [20......40]
                          [10..............30]   <- pedestal/altar vaults, transference
libraries                              [30..................50]
captive rooms                                    [30...............80]
shrine (flavor)         [15........25]
insight altar (OLD)  [7.14]                       <- 7-wide, lowest ceiling of any room machine
insight altar (NEW)  [6.........................25]
```

Observations:

- **The common, reliable window is roughly 10–50.** A random Brogue level reliably produces several
  dead-end pockets in that band, which is why the pedestal/altar reward vaults (`10–30`) and
  libraries (`30–50`) place dependably.
- **`< 4` is impossible** (§3b) and **very small windows are fragile** — `worms-in-the-walls` (`7–7`)
  and `trick statue` (`5–5`) only place when a level happens to produce a pocket of *exactly* that
  size, which is why they're flavor/`freq 0` rather than guaranteed rewards.
- **The old insight-altar window `{7,14}` was the narrowest, lowest-ceilinged of any room machine.**
  Its ceiling of 14 excluded the abundant 15–50 pockets, so on many levels nothing qualified and the
  force-build silently failed. Widening it to `{6,25}` brought it in line with the commutation
  (`15–25`) and transference (`10–30`) altars — see the 2026-06-14 entry in
  [IOS_MODIFICATIONS.md](../../BrogueCE/Engine/IOS_MODIFICATIONS.md).
- **Bigger windows ≈ more reliable, with almost no downside** for a small fixture, because the altar
  pair is placed by `placeAltarPairInRoom` which needs only **two open interior cells** (three
  fallback tiers, Architect.c:1774). A larger claimed pocket just yields a roomier carpeted shrine.

### The guaranteed-placement pattern (insight altars)

Because a single level can fail to offer a qualifying pocket, the insight altars don't rely on a
one-shot best-effort like the amulet vault. `addMachines` ([Architect.c:1871](../../BrogueCE/Engine/Architect.c)) instead tracks
how many altars are *due* by the current depth (`insightAltarDepths[] = {5, 15}`) versus how many
have actually been built (`rogue.insightAltarsBuilt`), and **carries any shortfall forward**: a
depth-5 failure retries on 6, 7, … until a room is found, capped at `INSIGHT_ALTAR_MAX_DEPTH = 20`.
This is the reusable recipe for "a fixture that must appear around depth N" given probabilistic
placement: *schedule by count-built, not by depth-modulo, and bound the carry-forward.*

---

## 9. Layouts

Most reward rooms share a stereotyped layout, expressed as `machineFeature` rows:

- **Carpet** the whole interior (`MF_EVERYWHERE`).
- **Statues / torches** in the perimeter walls (`MF_BUILD_IN_WALLS`).
- A **vestibule door** at the entry gate (`MF_BUILD_AT_ORIGIN | MF_BUILD_VESTIBULE`), which spawns a
  *separate* door-guard machine (lock, secret door, lever, etc.).
- One **prize**, chosen among `MF_ALTERNATIVE` rows (e.g. the good-permanent-item room rolls *one* of
  runic weapon / runic armor / two staffs).

### The altar-pair layout (iOS insight & transference)

The generic builder scatters features at random interior cells and can't guarantee an *ordered,
adjacent* pair, so the iOS altars build **only the carpeted room** via the blueprint, then place the
two altars in code with `placeAltarPairInRoom` ([Architect.c:1774](../../BrogueCE/Engine/Architect.c)). The target layout is a
horizontal run with a one-tile gap:

```
#  .  .  .  .  #
#  .  s  .  o  .   #     s = payment / donor altar (west)
#  .  .  .  .  #         o = insight / recipient altar (east)
```

`placeAltarPairInRoom` prefers three open cells in a row centered on the room (the `s . o` form),
then falls back to two adjacent cells (`s o`), then to any two open cells — so the pair always
exists even in a cramped pocket. Donor/recipient and payment/insight share the identical placement
helper (`statueAbove` differs); see [GlobalsBrogue.c:624](../../BrogueCE/Engine/GlobalsBrogue.c).

---

## 10. Determinism

All placement is driven by the substantive RNG (`rand_range` over gate candidates and the blueprint
raffle), so machines are **seed-stable** and the weekly-seed leaderboard is safe. New `rogue` fields
that participate (e.g. `insightAltarsBuilt`, `goldGoblinSpawned`) are save-safe **because they are
set deterministically during generation** — saves are input replays, not struct dumps
([ADR-0001](../adr/0001-deterministic-component-based-content.md), and the dual-engine save model).
Any change that alters how much RNG `addMachines` consumes on a given depth (adding/removing a
force-build, widening a `roomSize` so a level now places where it didn't) shifts downstream seed
output and warrants a release-time `recordingVersionString` bump.
