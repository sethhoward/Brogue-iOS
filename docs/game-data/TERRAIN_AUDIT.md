# Brogue SE — Terrain, Liquids, Gases & Dynamic Features Audit

Documents the **Brogue SE** engine (`BrogueSE/Engine/`, a fork of BrogueCE 1.15). Cites source `file:line`
throughout. Consult before reasoning about terrain, liquid, gas, or dungeon-feature behavior;
if engine code changes, regenerate or update.

Companion to [ITEMS_AUDIT.md](ITEMS_AUDIT.md) and [MONSTERS_AUDIT.md](MONSTERS_AUDIT.md).
The iOS-port **empty bottle** (§8) is the consumer that ties items to this system, and §9 is a
**gap analysis** of what the bottle does *not* yet capture — the tuning surface.

---

## 1. The terrain model in one picture

Every cell stacks up to four terrain tiles, one per **layer** (`enum dungeonLayers`,
`Rogue.h:1401`):

| Layer | # | Holds | Examples |
|-------|---|-------|----------|
| `DUNGEON` | 0 | structural tile | walls, floor, doors, stairs, traps, machines, chasm |
| `LIQUID` | 1 | liquid pool | deep/shallow water, lava, mud/bog, brimstone, ice |
| `GAS` | 2 | volumetric gas | poison, confusion, paralysis, rot, steam, methane, fire, darkness, healing |
| `SURFACE` | 3 | thin overlay | grass, blood, **acid splatter**, webs, nets, ash, foliage |

`NUMBER_TERRAIN_LAYERS = 4`. A cell stores `enum tileType layers[NUMBER_TERRAIN_LAYERS]`
(`Rogue.h:1423`) plus a `volume` (`unsigned short`, `Rogue.h:1425`) used only by the GAS layer.

Two catalogs and a flag system drive everything:

- **`tileCatalog[NUMBER_TILETYPES]`** — `Globals.c:324`. The static properties of every tile type
  (`enum tileType`, `Rogue.h:489`): glyph, colors, draw priority, ignite chance, fire/discover/promote
  DFs, promote chance, glow light, `T_*` flags, `TM_*` mechanical flags, name, flavor text. Struct
  shape: `floorTileType` at `Rogue.h:2031`.
- **`dungeonFeatureCatalog[NUMBER_DUNGEON_FEATURES]`** — `Globals.c:639`. The recipes (DFs,
  `enum dungeonFeatureTypes`, `Rogue.h:1577`) for *placing* tiles into a layer with a probability
  falloff and optional cascade. Struct: `dungeonFeature` at `Rogue.h:2012`.
- **Gas dynamics** — `updateVolumetricMedia()` at `Time.c:1334`, called **twice per turn**
  (`Time.c:1547-1548`), spreads and dissipates the GAS layer by `volume`.

---

## 2. Terrain flags (`T_*`) — the "what does it do to a creature standing here" set

`enum terrainFlagCatalog`, `Rogue.h:2049-2071`.

| Flag | Bit | Meaning |
|------|-----|---------|
| `T_OBSTRUCTS_PASSABILITY` | 0 | cannot be walked through |
| `T_OBSTRUCTS_VISION` | 1 | blocks line of sight |
| `T_OBSTRUCTS_ITEMS` | 2 | items can't rest here |
| `T_OBSTRUCTS_SURFACE_EFFECTS` | 3 | no grass/blood/etc. can form |
| `T_OBSTRUCTS_GAS` | 4 | blocks gas permeation |
| `T_OBSTRUCTS_DIAGONAL_MOVEMENT` | 5 | can't be cut diagonally past |
| `T_SPONTANEOUSLY_IGNITES` | 6 | monsters avoid unless chasing / fire-immune (brimstone) |
| `T_AUTO_DESCENT` | 7 | drops creature to next depth (chasm/hole/trap door), fall damage |
| `T_LAVA_INSTA_DEATH` | 8 | instant death to non-levitating, non-fire-immune |
| `T_CAUSES_POISON` | 9 | applies poison |
| `T_IS_FLAMMABLE` | 10 | can catch fire |
| `T_IS_FIRE` | 11 | is fire; ignites flammable neighbors |
| `T_ENTANGLES` | 12 | entangles like a spiderweb |
| `T_IS_DEEP_WATER` | 13 | deep water; can steal/move floating items |
| `T_CAUSES_DAMAGE` | 14 | per-turn damage (poison gas, steam, spirit vines) |
| `T_CAUSES_NAUSEA` | 15 | applies nausea (rot gas, stench) |
| `T_CAUSES_PARALYSIS` | 16 | applies paralysis |
| `T_CAUSES_CONFUSION` | 17 | applies confusion |
| `T_CAUSES_HEALING` | 18 | heals per turn (bloodwort/healing cloud) |
| `T_IS_DF_TRAP` | 19 | spews its DF when triggered (pressure-plate traps) |
| `T_CAUSES_EXPLOSIVE_DAMAGE` | 20 | explosion damage (gas explosion) |
| `T_SACRED` | 21 | non-ally monsters avoid (sacred glyph) |

Composite masks (`Rogue.h:2074-2082`): `T_PATHING_BLOCKER`, `T_LAKE_PATHING_BLOCKER`,
`T_OBSTRUCTS_EVERYTHING`, `T_HARMFUL_TERRAIN` (= poison | fire | damage | paralysis | confusion |
explosive). The instant per-turn application of these to creatures happens in
`applyInstantTileEffectsToCreature()` (`Time.c`, see §5).

## 3. Mechanical flags (`TM_*`) — the "how does the tile itself behave" set

`enum terrainMechanicalFlagCatalog`, `Rogue.h:2086-2114`. Most relevant to this audit:

| Flag | Bit | Meaning |
|------|-----|---------|
| `TM_IS_SECRET` | 0 | hidden until searched / stepped on → `discoverType` |
| `TM_PROMOTES_ON_*` | 3–8 | promote on creature / item / pickup / player entry / sacrifice / electricity |
| `TM_PROMOTES_WITH_KEY` / `_WITHOUT_KEY` | 1–2 | key-gated promotion (locked doors, cages, altars) |
| `TM_ALLOWS_SUBMERGING` | 9 | submersible monsters can hide here (deep water, lava, mud) |
| `TM_IS_WIRED` / `TM_IS_CIRCUIT_BREAKER` | 10–11 | machine power wiring |
| `TM_GAS_DISSIPATES` | 12 | gas thins over time (slow — poison) |
| `TM_GAS_DISSIPATES_QUICKLY` | 13 | gas thins fast (confusion, rot, paralysis, steam, healing) |
| `TM_EXTINGUISHES_FIRE` | 14 | water puts out fire on terrain/creatures |
| `TM_VANISHES_UPON_PROMOTION` | 15 | tile removed (not replaced) when it promotes |
| `TM_REFLECTS_BOLTS` | 16 | bounces magic bolts (crystal wall) |
| `TM_STAND_IN_TILE` | 17 | earthbound creatures stand *in*, not *on* (water/lava/mud/blood/ash) |
| `TM_EXPLOSIVE_PROMOTE` | 21 | when surrounded by fire/explosion, promotes (methane → explosion) |
| `TM_SWAP_ENCHANTS_ACTIVATION` | 25 | commutation altar |
| `TM_INSIGHT_ACTIVATION` / `TM_TRANSFER_ENCHANT_ACTIVATION` | 26–27 | **iOS-port** insight / transfer altars |

---

## 4. The tile catalog by layer (`Globals.c:324`)

The `enum tileType` (`Rogue.h:489`) has ~250 entries. The full DUNGEON-layer set (walls, doors,
stairs, torches, altars, cages, levers, statues, traps, machine plumbing, manacles, dewars, chasms)
is large and mostly structural; below are the layers this audit prioritizes. Line numbers point at
the `tileCatalog[]` row in `Globals.c`.

### 4.1 LIQUID layer

| Tile | Globals.c | Key `T_*` | Notes |
|------|-----------|-----------|-------|
| `DEEP_WATER` | 422 | `T_IS_DEEP_WATER`, `T_IS_FLAMMABLE`† | submerging, extinguishes fire; can sweep floating items |
| `SHALLOW_WATER` | 423 | — | extinguishes fire, allows submerging |
| `MUD` (bog) | 424 | — | `promoteChance 100` → `METHANE_GAS_PUFF`; submerging |
| `LAVA` | 429 | `T_LAVA_INSTA_DEATH` | instant death unless levitating/fire-immune; submerging |
| `LAVA_RETRACTABLE` / `LAVA_RETRACTING` | 430–431 | `T_LAVA_INSTA_DEATH` | machine-controlled (wired) / cooling |
| `SACRIFICE_LAVA` | 558 | `T_LAVA_INSTA_DEATH` | sacrifice-machine pit |
| `ACTIVE_BRIMSTONE` | 434 | `T_IS_FLAMMABLE`, `T_SPONTANEOUSLY_IGNITES` | `promoteChance 10` → inert; ignites readily |
| `INERT_BRIMSTONE` | 435 | `T_SPONTANEOUSLY_IGNITES` | `promoteChance 800` → active |
| `ICE_DEEP` / `ICE_SHALLOW` (+ `_MELT`) | 444–447 | `T_IS_FLAMMABLE` | frozen water; `_MELT` promotes back to water |
| `FLOOD_WATER_DEEP` / `_SHALLOW` | 454 / `Rogue.h:608` | `T_IS_DEEP_WATER` (deep) | machine/trap flooding; vanishes on promotion |
| `DEEP_WATER_ALGAE_*` | 533–535 | — | luminescent algae variants (glow) |

† `DEEP_WATER` carries `T_IS_FLAMMABLE` so a fire DF can pass over it / it can host floating
flammables; the water itself extinguishes via `TM_EXTINGUISHES_FIRE`.

### 4.2 GAS layer (also covered as dynamics in §5)

| Tile | Globals.c | Key `T_*` | Dissipation |
|------|-----------|-----------|-------------|
| `PLAIN_FIRE` and fire variants (`BRIMSTONE_FIRE`, `GAS_FIRE`, `FLAMEDANCER_FIRE`, `ITEM_FIRE`, `CREATURE_FIRE`, `DART_EXPLOSION`) | ~505–512 | `T_IS_FIRE` | promote/vanish, not "gas dissipation" |
| `GAS_EXPLOSION` | ~509 | `T_IS_FIRE`, `T_CAUSES_EXPLOSIVE_DAMAGE` | one-shot |
| `POISON_GAS` | 515 | `T_IS_FLAMMABLE`, `T_CAUSES_DAMAGE` | `TM_GAS_DISSIPATES` (slow) |
| `CONFUSION_GAS` | 516 | `T_IS_FLAMMABLE`, `T_CAUSES_CONFUSION` | `TM_GAS_DISSIPATES_QUICKLY` |
| `ROT_GAS` | 517 | `T_IS_FLAMMABLE`, `T_CAUSES_NAUSEA` | quickly |
| `STENCH_SMOKE_GAS` | 518 | `T_CAUSES_NAUSEA` | quickly |
| `PARALYSIS_GAS` | 519 | `T_IS_FLAMMABLE`, `T_CAUSES_PARALYSIS` | quickly |
| `METHANE_GAS` | 520 | `T_IS_FLAMMABLE`, `TM_EXPLOSIVE_PROMOTE` | does **not** dissipate (accumulates → explodes) |
| `STEAM` | 521 | `T_CAUSES_DAMAGE` | quickly |
| `DARKNESS_CLOUD` | 522 | — (light effect) | does not dissipate via flag (managed elsewhere) |
| `HEALING_CLOUD` | 523 | `T_CAUSES_HEALING` | quickly |
| `SMOKE_GAS` (iOS port) | ~524 | — (no flag; `SMOKE_LIGHT` dims; thick smoke blocks **sight only** via volume-gated `cellHasThickSmoke()` in `scanOctantFOV`, not a terrain flag) | **volume-keyed** (not flag-driven): thin ~50%/turn, thick (≥ `SMOKE_THICK_VOLUME`) ~20%/turn. Emitted per-turn by burning `PLAIN_FIRE` (`updateEnvironment`). See IOS_MODIFICATIONS.md 2026-06-27. |

(Row line numbers approximate within the catalog block; the gas tiles are contiguous around
`Globals.c:515-523`. The authoritative effect comes from the `T_*` flags, applied in §5.)

### 4.3 SURFACE layer

| Tile | Globals.c | Key flags | Notes |
|------|-----------|-----------|-------|
| `GRASS` / `DEAD_GRASS` / `GRAY_FUNGUS` / `LUMINESCENT_FUNGUS` / `HAY` | 456–461 | `T_IS_FLAMMABLE` | varying `chanceToIgnite`; fungus glows |
| `RED_BLOOD` / `GREEN_BLOOD` / `PURPLE_BLOOD` / `WORM_BLOOD` | 462–469 | — | cosmetic pools; `TM_STAND_IN_TILE` |
| **`ACID_SPLATTER`** | 465 | — (`fireType DF_PLAIN_FIRE`) | **"a puddle of acid"** — the acid trail; see §7 |
| `ASH` / `BURNED_CARPET` / `EMBERS` | 470–478 | — | burn residue; `EMBERS` → `ASH` via promote |
| `FOLIAGE` / `DEAD_FOLIAGE` / `TRAMPLED_FOLIAGE` | 481–483 | `T_OBSTRUCTS_VISION`, `T_IS_FLAMMABLE` | trample on step |
| `FUNGUS_FOREST` / `TRAMPLED_FUNGUS_FOREST` | 484–485 | `T_OBSTRUCTS_VISION` | glowing forest |
| `FROZEN_FOLIAGE` (+ `_MELT`) | 609–610 | `T_OBSTRUCTS_PASSABILITY`, `T_OBSTRUCTS_VISION` | staff-of-frost barrier |
| `SPIDERWEB` | 479 | `T_ENTANGLES`, `T_IS_FLAMMABLE` | spider trap |
| `NETTING` | 480 | `T_ENTANGLES`, `T_IS_FLAMMABLE` | net trap |
| `ANCIENT_SPIRIT_VINES` / `_GRASS` | 538–539 | `T_ENTANGLES`, `T_CAUSES_DAMAGE` (vines) | guardian set-piece |
| `BLOODFLOWER_STALK` / `_POD` | 526–527 | `T_OBSTRUCTS_PASSABILITY`, `T_IS_FLAMMABLE` | pod bursts → `HEALING_CLOUD` |
| `VOMIT` / `URINE` / `UNICORN_POOP` / `PUDDLE` / `BONES` / `RUBBLE` / `ECTOPLASM` | `Rogue.h:620-631` | — | misc residue |

---

## 5. Gas dynamics — spread, mix, dissipate

`updateVolumetricMedia()` (`Time.c:1334`), run twice per game turn (`Time.c:1547-1548`):

1. **Spread.** For each cell holding gas, average its `volume` across neighbors that don't block gas
   (`T_OBSTRUCTS_GAS`). Chasm / trap-door cells count as a sink so gas can drain off-level.
2. **Mix cap.** When two *different* gas types meet, the receiving cell's new volume is capped low
   (≈ `min(3, …)`) to avoid chaotic interactions.
3. **Dissipate.** `TM_GAS_DISSIPATES` loses 1 volume ~20% of turns; `TM_GAS_DISSIPATES_QUICKLY`
   ~50%. When `volume` drops below 1 the gas clears. Gas with no dissipation flag
   (`METHANE_GAS`, `DARKNESS_CLOUD`) persists until consumed/ignited or managed elsewhere.
4. **Forced disperse.** If a cell that obstructs gas somehow holds volume, it dumps into neighbors.

**Per-turn effects on a creature standing in gas** come from the tile's `T_*` flags, applied in
`applyInstantTileEffectsToCreature()` (`Time.c`):

| Gas | Flag | Effect |
|-----|------|--------|
| Poison gas | `T_CAUSES_DAMAGE` | weakening damage per turn |
| Steam | `T_CAUSES_DAMAGE` | scalding damage per turn |
| Confusion gas | `T_CAUSES_CONFUSION` | sets `STATUS_CONFUSED` |
| Paralysis gas | `T_CAUSES_PARALYSIS` | sets `STATUS_PARALYZED` |
| Rot gas / stench smoke | `T_CAUSES_NAUSEA` | sets `STATUS_NAUSEOUS` |
| Healing cloud | `T_CAUSES_HEALING` | heals per turn |
| Methane gas | (none directly) | inert until ignited — then `TM_EXPLOSIVE_PROMOTE` → gas explosion |
| Darkness cloud | (none) | suppresses light only |

---

## 6. Dungeon features (DFs) — how tiles get placed and cascade

A DF is one recipe row in `dungeonFeatureCatalog[]` (`Globals.c:639`). Struct
`dungeonFeature` (`Rogue.h:2012-2028`):

| Field | Meaning |
|-------|---------|
| `tile` | the `tileType` to lay down |
| `layer` | which layer it occupies (`DUNGEON`/`LIQUID`/`GAS`/`SURFACE`) |
| `startProbability` | spawn % at the origin — **or initial `volume` for a GAS DF** |
| `probabilityDecrement` | falloff per radial step (0 = fixed-size) |
| `flags` | `DFF_*` behavior bits |
| `description` | message shown when it spawns |
| `lightFlare` / `flashColor` / `effectRadius` | visual flare + aggravation radius |
| `propagationTerrain` | only spread across this terrain (0 = any) |
| `subsequentDF` | a follow-up DF to chain (the cascade) |

`DFF_*` flags (`Rogue.h:1936-1946`): evacuate creatures first, spawn subsequent everywhere vs.
origin-only, treat-as/permit blocking (level-connectivity guard), clear other/lower-priority
terrain, superpriority overwrite, activate dormant monster, aggravate monsters, resurrect ally.

**Spawn path:** `spawnDungeonFeature()` (`Architect.c:3511`). For a GAS DF it adds
`startProbability` straight into `pmap[x][y].volume` and sets the GAS layer. For non-gas DFs it
fills a spawn map radially from `startProbability` down by `probabilityDecrement`, respecting
`propagationTerrain` and blocking rules, then chains `subsequentDF` (everywhere or at origin).

### Notable DFs by category (names; rows in `Globals.c:639+`)

- **Water/ice:** `DF_FLOOD` → `DF_FLOOD_2` (shallow→deep), `DF_FLOOD_DRAIN`, `DF_WATER_SPREADS`
  → `DF_SHALLOW_WATER` (machine flood over `FLOOR_FLOODABLE`), `DF_SPREADABLE_DEEP_WATER_POOL`,
  the freeze chain `DF_DEEP_WATER_FREEZE` → algae freezes → `DF_SHALLOW_WATER_FREEZE` →
  `DF_FROZEN_FOLIAGE` (staff of frost).
- **Lava:** `DF_LAVA_RETRACTABLE` → `DF_RETRACTING_LAVA` → obsidian + steam accumulation.
- **Gases:** trap clouds (`DF_POISON_GAS_CLOUD`, `DF_CONFUSION_GAS_TRAP_CLOUD`,
  `DF_PARALYSIS_GAS_CLOUD_POTION`, `DF_DARKNESS_POTION`); continuous vents
  (`DF_VENT_SPEW_POISON_GAS`, `DF_PARALYSIS_VENT_SPEW`, `DF_VENT_SPEW_METHANE`); shattering dewars
  (`DF_DEWAR_CAUSTIC` / `_CONFUSION` / `_PARALYSIS` / `_METHANE`, `startProbability` ~20000 = huge
  volume, `effectRadius 4`); `DF_STEAM_PUFF` / `DF_STEAM_ACCUMULATION`; `DF_METHANE_GAS_PUFF`
  (bog); `DF_BLOODFLOWER_POD_BURST` → `HEALING_CLOUD`.
- **Surfaces:** the blood family (see §7), `DF_WEB_SMALL` / `DF_WEB_LARGE`, `DF_ANCIENT_SPIRIT_VINES`,
  `DF_TRAMPLED_FOLIAGE` / `DF_FOLIAGE_REGROW`, `DF_VOMIT` / `DF_URINE` / `DF_UNICORN_POOP`.
- **SE — lair dressing:** `DF_JACKAL_DEN_FOLIAGE` (a tighter-than-open-field `FOLIAGE` core, `100/40`)
  chains `subsequentDF` → `DF_JACKAL_DEN_GRASS` (a contained `GRASS` apron, `75/20`). `FOLIAGE` outranks
  `GRASS` in draw priority, so the apron fills *around* the core without erasing it. A horde drops this at
  its spawn site via the `hordeType.spawnDF` catalog field (the jackal pack is the only consumer; see
  [MONSTERS_AUDIT.md §7.2](MONSTERS_AUDIT.md)). The core+apron is pure catalog data — no bespoke helper.
- **SE — trap companion terrain:** an `autoGenerator` row may carry `companionDF` + `companionChance`
  ([GlobalsBrogue.c](../../BrogueSE/Engine/GlobalsBrogue.c)). `runAutogenerators` rolls the chance and spreads
  the DF from a cell *offset* off the foundation (the foundation is blocked as the origin), so it's never a
  pinpoint marker. Consumers: fire traps → `DF_TRAP_DRY_GRASS` (a contained `DEAD_GRASS` patch, `75/25`, no
  dead-foliage chain — flammable, so a triggered fire trap can ignite it); caustic traps → stock `DF_BONES`.
  ~40% on both revealed and hidden variants; a soft search cue, not a tell (it doesn't touch the trap cell and
  blends with naturally-occurring patches). Grass/bones aren't vision-blocking, so the §6.1 trap guard ignores
  them and they don't hide the trap.

### 6.1 SE — foliage never paves a trap (BrogueCE [#832](https://github.com/tmewett/BrogueCE/issues/832))

A trap (`T_IS_DF_TRAP`, `DUNGEON` layer) and a vision-blocking surface tile could previously share a cell.
The foliage then **hid the trap** (drawn over the trap glyph) and **stopped a thrown dart from settling on
the trigger**, so the trap couldn't be sprung remotely. Two-part SE fix:

- **Generation (primary):** `fillSpawnMap` (`Architect.c`) refuses to paint a `T_OBSTRUCTS_VISION` tile onto
  a `T_IS_DF_TRAP` cell. Engine-wide — covers autogenerator foliage, the jackal den, and runtime regrowth.
- **Projectile (net):** `throwItem` (`Items.c`) lands a thrown item *on* a passable vision-only obstruction
  (foliage) instead of backing it up one cell, so an item reaching a trap under runtime-grown foliage still
  triggers it. A solid wall (`T_OBSTRUCTS_PASSABILITY`) still stops the projectile short.

Both are SE-only for now and flagged as a cherry-pick candidate for CE/Classic/upstream (see
[`BrogueSE/Engine/IOS_MODIFICATIONS.md`](../../BrogueSE/Engine/IOS_MODIFICATIONS.md)).

---

## 7. Acid — the full story

Acid is **not its own tile flag**; it is a surface trail + two combat-degradation abilities.

**The trail.** `ACID_SPLATTER` (SURFACE tile, `Globals.c:465`, *"a puddle of acid"*) is laid down
as a creature's **blood**: `DF_ACID_BLOOD` (`Rogue.h:1607`; catalog row in `Globals.c:639+`,
`startProbability ~200`). Blood is spawned whenever a creature with a `bloodType` takes damage —
`Combat.c` scales the DF's `startProbability` by the damage dealt and calls `spawnDungeonFeature`,
so a hard hit on an acid creature leaves a bigger puddle. The "trail" is this blood being dropped
as the creature moves and is struck.

**The creatures.** Acid blood + corrosion come from:
- **Acid mound** — `bloodType = DF_ACID_BLOOD`; `MONST_DEFEND_DEGRADE_WEAPON` (corrodes the
  attacker's weapon) + `MA_HIT_DEGRADE_ARMOR` (corrodes the player's armor on hit). Flavor:
  *"…leaving a trail of hissing goo in its path."*
- **Acidic jelly** — same corrosion flags, plus `MA_CLONE_SELF_ON_DEFEND`.

(See [MONSTERS_AUDIT.md](MONSTERS_AUDIT.md) for full stats.)

**Corrosion mechanics** (`Combat.c`): attacking a `MONST_DEFEND_DEGRADE_WEAPON` creature decrements
the weapon's `enchant1`; being hit by an `MA_HIT_DEGRADE_ARMOR` creature decrements armor
`enchant1`. Both are blocked by the `ITEM_PROTECTED` flag and floored at −10 enchant.

`ACID_SPLATTER` itself carries **no `T_*` flags** — standing in an acid puddle does nothing; it is
purely the visual record of acid combat (its `fireType` is `DF_PLAIN_FIRE`, so it can burn).

---

## 8. The empty bottle (iOS port) — terrain/gas capture

The iOS port replaces the **potion of detect magic** with an **empty bottle**, reusing the internal
`POTION_DETECT_MAGIC` kind (`Rogue.h`) to avoid churn. Table entries:
`GlobalsBrogue.c:707`, `GlobalsRapidBrogue.c:679`, `GlobalsBulletBrogue.c:689` — frequency **20**,
market value **500**, always-identified (`Items.c` `shuffleFlavors()`). Documented in
`IOS_MODIFICATIONS.md` ("Replace potion of detect magic with the Empty Bottle").

**It does not store captured contents** — capturing *transmutes the bottle into a real, identified
potion of the matching kind* and merges it into the matching pack stack. Core helper:
`fillEmptyBottle()` (`Items.c:6766`) sets `bottle->kind`, un-hides the kind (so wort works even when
its themed set is absent this seed), prints flavor, and auto-identifies.

### 8.1 Capture matrix

**Apply (drink) on a tile** — `emptyBottleCaptureKindForTile()` (`Items.c:6786`), called from the
drink path (`Items.c:8948`). Gas on the tile (`volume > 0`) takes priority; otherwise deep water:

| On the tile | Becomes potion of |
|-------------|-------------------|
| `POISON_GAS` | poison |
| `CONFUSION_GAS` | confusion |
| `PARALYSIS_GAS` | paralysis |
| `ROT_GAS` | lichen |
| `DARKNESS_CLOUD` | darkness |
| `HEALING_CLOUD` | wort |
| `SMOKE_GAS` (iOS port) | smoke (capture-only `POTION_SMOKE`; thrown/uncorked → a short-lived sight-blocking screen via `DF_SMOKE_POTION`) |
| deep water (`T_IS_DEEP_WATER`, while **not** levitating) | fire immunity |

If nothing is capturable: *"the bottle is empty, and there is nothing here to capture."* — no turn
spent. Capturing spends a turn.

**Bolt capture** — set the bottle on the floor and zap it (`Items.c:4967-4982`). The bottle drinks
the bolt (terminates it):

| Bolt | Becomes potion of |
|------|-------------------|
| lightning (`BF_ELECTRIC`) | haste self (speed) |
| fire (`BF_FIERY`) | incineration |

### 8.2 Determinism

Both capture paths are deterministic — no `rand_*` in `fillEmptyBottle` /
`emptyBottleCaptureKindForTile`. The drink path records the command
(`recordApplyItemCommand`, `Items.c:8950`); the bolt path rides the already-determined bolt. Saves
are recordings, so the only save-relevant state is the mutated `item.kind`, which replays
identically. The generation change (freq 20, always-ID) diverges from pre-feature recordings — a
`recordingVersionString` bump is warranted at release.

---

## 9. Gap analysis — what is *not* captured (the tuning surface)

> **v2 status:** the gaps below are the input to the **empty-bottle v2** redesign — see
> [`docs/design/empty-bottle-v2.md`](../design/empty-bottle-v2.md) for the full decided capture map
> (step-in / levitation-skim / bolt gestures) and the five new **capture-only** potions (acid,
> webbing, steam, ice, water). This section remains the engine-side "what exists" reference.

The bottle's own flavor text promises *"stepping into a gas **or hazard you can already walk
through**."* In v1 code, "hazard you can walk through" is **only deep water**; everything else
routes through the GAS layer. So a number of walkable liquids/surfaces and several gases were
**unaccounted for** (v2 addresses these):

> **Note (iOS port, 2026-06-27):** the new `SMOKE_GAS` (emitted by burning `PLAIN_FIRE`) **is**
> capturable, as the capture-only `POTION_SMOKE` (thrown/uncorked → a short-lived sight-blocking
> screen). So it is *not* a gap — see §8.1 and IOS_MODIFICATIONS.md 2026-06-27.

**Gases that exist but aren't capturable:**

| Gas | Could map to | Note |
|-----|--------------|------|
| `STENCH_SMOKE_GAS` | (nausea) | rot-gas sibling; no potion analog — would need one or fold into lichen |
| `STEAM` | — | scalding; no obvious potion (fire immunity is taken by water) |
| `METHANE_GAS` | (incineration?) | explosive; capturing raw methane vs. its explosion is a design choice |

**Walkable liquids/surfaces the apply-path ignores (gas-or-deep-water only):**

| Terrain | Layer | Walkable? | Candidate capture |
|---------|-------|-----------|-------------------|
| `SHALLOW_WATER` | LIQUID | yes | — (deep water already → fire immunity) |
| `MUD` (bog) | LIQUID | yes | methane/lichen flavored? |
| `ACID_SPLATTER` | SURFACE | yes | **acid trail — the one the user flagged**; could become a corrosive/caustic potion |
| `ACTIVE_BRIMSTONE` | LIQUID | yes (ignites) | incineration-flavored? |
| blood pools, ash, ectoplasm | SURFACE | yes | cosmetic — probably out of scope |

**Hazards you cannot walk through (so the bottle can never reach them by stepping):**
`LAVA` (insta-death), `PLAIN_FIRE` / fire variants, `FROZEN_FOLIAGE`. These would need a
bolt-style or thrown capture, not the step-in path.

> The acid trail (`ACID_SPLATTER`) is the clearest gap: it's a walkable surface hazard left by acid
> mounds/jellies, it thematically *should* fill a bottle, but the apply-path only checks the GAS
> layer and deep water — never the SURFACE layer. Wiring `emptyBottleCaptureKindForTile` to also
> inspect `layers[SURFACE]` (and optionally `layers[LIQUID]` beyond deep water) is the natural
> extension, gated on a sensible potion mapping per terrain.

---

## 10. Movement-noise emission (noise system)

The SE noise system reads terrain two ways (see `docs/design/noise-system.md`):

- **Propagation** — terrain *between* a noise source and the player muffles sound *in transit*, via the
  per-turn sound map: vision-blocking-but-passable tiles (dense foliage / closed door / smoke,
  `T_OBSTRUCTS_VISION`) cost extra to cross; walls (`T_OBSTRUCTS_PASSABILITY`, incl. `CRYSTAL_WALL`) block
  sound entirely (it routes around).
- **Emission** — the tile a creature *steps into* changes how loud that step *is*, a signed modifier
  (`terrainNoiseModifier` → `tileNoiseValue`, Monsters.c) added to the detection roll. Loudest-magnitude
  layer wins. Flavor-grounded by each tile's catalog description ("crunches/creaks underfoot", etc.).

| Emission tier | Value | Tiles |
|---|---|---|
| Crunch / creak | **+10** (`NOISE_TERRAIN_CRUNCH`) | `GRASS`, `DEAD_GRASS`, `GRAY_FUNGUS`, `LUMINESCENT_FUNGUS`, `HAY`, `ASH`, `RUBBLE`, `BRIDGE` |
| Rustle / squelch | **+6** (`NOISE_TERRAIN_RUSTLE`) | `FOLIAGE`, `DEAD_FOLIAGE`, `TRAMPLED_FOLIAGE`, `FUNGUS_FOREST`, `TRAMPLED_FUNGUS_FOREST`, `MUD` |
| Splash | **+8** (`NOISE_TERRAIN_SPLASH`) | `SHALLOW_WATER` — note: water *hides scent* (`playerScentWaterPenalty`) but *broadcasts splash* |
| Soft (dampen) | **−8** (`NOISE_TERRAIN_SOFT`) | `CARPET`, `SPIDERWEB` (+ a future `MOSS`) |
| Neutral | 0 | stone floor, `MARBLE_FLOOR`, `DEEP_WATER` (submergers already silenced), everything else |

Values are tunable `NOISE_TERRAIN_*` constants in `Rogue.h`. The modifier is direction-agnostic — it makes
the *source* louder/quieter, so it will also feed the future monster-hears-player detection.

---

## Source index

| Subject | File:line |
|---------|-----------|
| `tileType` enum | `Rogue.h:489` |
| Terrain layers | `Rogue.h:1401` |
| Cell layer array + `volume` | `Rogue.h:1423`, `Rogue.h:1425` |
| `T_*` flags | `Rogue.h:2049-2071` |
| `TM_*` flags | `Rogue.h:2086-2114` |
| `floorTileType` struct | `Rogue.h:2031` |
| `tileCatalog[]` | `Globals.c:324` |
| `dungeonFeature` struct | `Rogue.h:2012-2028` |
| `DFF_*` flags | `Rogue.h:1936-1946` |
| `dungeonFeatureTypes` enum | `Rogue.h:1577` |
| `dungeonFeatureCatalog[]` | `Globals.c:639` |
| `spawnDungeonFeature()` | `Architect.c:3511` |
| `updateVolumetricMedia()` | `Time.c:1334` (called `Time.c:1547-1548`) |
| `ACID_SPLATTER` tile | `Globals.c:465` |
| `DF_ACID_BLOOD` | `Rogue.h:1607` |
| `fillEmptyBottle()` | `Items.c:6766` |
| `emptyBottleCaptureKindForTile()` | `Items.c:6786` |
| Empty bottle apply path | `Items.c:8948` |
| Empty bottle bolt capture | `Items.c:4967-4982` |
| Empty bottle item table | `GlobalsBrogue.c:707` (+ Rapid `:679`, Bullet `:689`) |
