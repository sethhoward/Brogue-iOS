# Perception Audit — Stealth, Noise & Hearing (Brogue SE)

> **Engine:** Brogue SE (`BrogueSE/Engine/`). This is original SE ("firehose") content — the sound
> layer does not exist in pristine BrogueCE. All `file:line` citations below are SE paths.
>
> **Scope.** How an entity becomes aware of another in SE. There are **two senses** — *sight*
> (the vanilla **stealth** model) and *sound* (the SE **noise** system) — and the noise sense runs in
> **both directions**: monsters hear the player, and the player "hears" monsters they cannot see. This
> document is the single place that explains all of it and, crucially, **how the two senses interact**.
>
> Companion docs: monster stats/flags in [MONSTERS_AUDIT.md](MONSTERS_AUDIT.md); the terrain layer the
> sound map floods over in [TERRAIN_AUDIT.md](TERRAIN_AUDIT.md). The local design narrative (decisions,
> grill history, deferred phases) lives in `docs/design/noise-system.md` (untracked working notes).

---

## 1. The mental model: two senses × two directions

|  | **Monster perceives player** | **Player perceives monster** |
|---|---|---|
| **Sight** (stealth) | `awareOfTarget` spot roll, gated by `rogue.stealthRange` + field of view. **Substantive.** | The normal FOV / lighting render. (Not part of this system.) |
| **Sound** (noise) | `monsterHearsNoise` / `checkPlayerHeard` — wakes / draws monsters toward your noise. **Substantive.** | `monsterEmitMovementNoise` — an off-screen move you "hear" → the *"heard something"* ripple. **Cosmetic.** |

The two diagonal cells you can ignore (sight-of-monster is just rendering). The **three** that matter:
**sight→stealth**, **sound→monster-hears-you** (substantive, the gameplay), and **sound→you-hear-monster**
(cosmetic, the feedback). They share one substrate — the per-turn **sound map** — and they run **in
parallel every turn**. Understanding the system is mostly understanding how sight and sound combine.

The one-sentence summary: **sight is a radius; sound is a flood.** Sight is line-of-sight inside a range
that shrinks in shadow and when you rest. Sound floods the level from a source, bends around walls,
muffles at doors, and reaches roughly **twice as far** as sight — but only *attracts*, it doesn't by
itself reveal you.

---

## 2. Sight — the stealth model (vanilla, substantive)

Unchanged from upstream except the SE tweak in §2.3. A monster sees the player via `awareOfTarget`
([Monsters.c:1828](../../BrogueSE/Engine/Monsters.c)), driven by **`rogue.stealthRange`**.

### 2.1 `currentStealthRange()` — the sight radius
[Time.c:786](../../BrogueSE/Engine/Time.c). Recomputed every turn (after the player moves, before
monsters act). Starts at **14** and is modified:

| Condition | Effect on stealth range |
|---|---|
| `STATUS_INVISIBLE` | hard-set to **1** (overrides everything below) |
| In darkness (`playerInDarkness`) | halve (round down) |
| Standing in shadow (`IS_IN_SHADOW`) | halve again (stacks with darkness) |
| Heavy armor | `+armorStealthAdjustment` (str-req above 12) |
| Just rested | halve, **round up** |
| `STATUS_AGGRAVATING` | `+` the status magnitude |
| Ring of stealth | `−rogue.stealthBonus` (cursed ring adds) |
| Floor | min **2** (min **1** if you just rested or are invisible) |

Lower is stealthier: a low `stealthRange` means a monster must be very close (and see you) to roll
detection. Darkness + shadow + resting + a stealth ring stack multiplicatively/additively into a very
small radius.

### 2.2 The awareness check
`awareness = rogue.stealthRange * 2` and `perceivedDistance = awarenessDistance(observer, player)`
(≈ **2× the tile distance** — both are in the same doubled units, so compare directly).
[Monsters.c:1800,1830](../../BrogueSE/Engine/Monsters.c). `awareOfTarget` returns true when, in order:

- `MONST_ALWAYS_HUNTING` → always; `MONST_IMMOBILE` (turrets) → true iff within `awareness`.
- Beyond `awareness * 3` → false even if hunting.
- Already `MONSTER_TRACKING_SCENT` (hunting) → stays aware (97% if you slip outside `awareness`).
- **Player not in the monster's field of view → false.** (Sight requires LoS; this is the gate that
  keeps sound the *only* way to be detected around a corner.)
- Within `awareness` and **not sleeping** → the **spot roll** (see §2.3).

### 2.3 The spot roll (SE change)
The "within range but currently unaware" roll ([Monsters.c:1855](../../BrogueSE/Engine/Monsters.c)):

- **SE removed the sleeper case.** The visual spot roll **no longer wakes a `MONSTER_SLEEPING`
  monster** — a sleeper's eyes are closed; it wakes by **sound** (§3.2) or damage only. This is what
  makes a quiet approach a real backstab.
- **Passive wanderer:** flat `rand_percent(25)` — vanilla. A creature that merely strays into your
  stealth radius has a 25%/turn chance to notice you.
- **Active investigator** (`MB_INVESTIGATING`, see §4.2): **proximity-scaled** instead of flat — see
  §3.2.5. This is the only behavioral difference in the sight path and it only applies to a monster
  that is *already* hunting your sound.

---

## 3. Sound — the noise system (SE original)

Single compile-time/runtime knob: **`NOISE_SYSTEM_ENABLED`** ([Rogue.h:128](../../BrogueSE/Engine/Rogue.h)).
Off → none of §3 compiles; the engine is pure-vanilla stealth.

### 3.1 The shared substrate: the sound map (propagation)
`recomputeSoundMap()` ([Time.c:735](../../BrogueSE/Engine/Time.c)) runs once per turn — a Dijkstra
cost-flood **from the player** (8-way). `soundDistanceAt(loc)` returns the effective sound cost-distance
between that cell and the player:

| Cell | Sound cost |
|---|---|
| Open floor | **1** |
| Vision-blocking but passable (closed door, dense foliage, thick smoke) | **1 + `NOISE_DOOR_COST`** (= 5; muffled passage) |
| Wall (`T_OBSTRUCTS_PASSABILITY`) | impassable — sound routes around, or is **silent** if sealed off (`30000`) |

Path distance is symmetric, so a player-sourced flood gives the right value at a monster's cell *and*
vice-versa — both noise directions read the same map. It's read-only and deterministic → never perturbs
the substantive RNG. Visualize it with the sound-map debug overlay.

### 3.2 Monster hears the player (SUBSTANTIVE — the gameplay)

The reverse direction and the heart of the feature. Your actions emit a per-turn loudness; nearby
unaware monsters roll to hear it and either **investigate** (come look) or **aggro** (hunt).

#### 3.2.1 Player loudness — `playerNoiseLevel()` + a spike
[Monsters.c:4613](../../BrogueSE/Engine/Monsters.c). A **new quantity, deliberately not**
`currentStealthRange` (that bakes in darkness/shadow — visual concealment, irrelevant to sound):

```
loudness = AGGRAVATING ? 60
         : armorStealthAdjustment*2          // heavy armor clatters (>=0)
           + (levitating ? -10 : terrainNoiseModifier(player.loc))   // §3.4
           - stealthBonus*3                   // ring of stealth muffles
```

`playerEmitNoise(spike)` sets `rogue.playerNoise = playerNoiseLevel() + spike`, where the spike is the
action: **move 0, throw +15, melee +30** ([Movement.c], [Items.c], [Combat.c]). At end of turn it resets
to `NOISE_PLAYER_SILENT` (−30000) — *holding still emits nothing and is never heard.* Note melee's +30
is ≥ the aggro threshold (§3.2.3): **attacking always aggros anything that hears it.**

#### 3.2.2 The hear roll — `monsterHearsNoise()`
[Monsters.c:1906](../../BrogueSE/Engine/Monsters.c). **Earshot gate:** `soundDist > stealthRange * 2`
**tiles** → not heard. (Kept tight to today's stealth — see §4.1 for why that 2× matters.) Otherwise:

```
hearChance = clamp(NOISE_HEAR_BASE(15) + playerLoudness
                   + (soundDist <= 2 ? +NOISE_HEAR_NEARFIELD_BONUS(20)
                                     : -NOISE_HEAR_FALLOFF_PER_TILE(4) * (soundDist - 2)),
                   0, NOISE_HEAR_CEILING(95))      // sound alone never auto-wakes
```

Rolled with a **substantive `rand_percent`** (it changes monster behavior).

#### 3.2.3 Faint vs. loud — `checkPlayerHeard()`
[Monsters.c:1928](../../BrogueSE/Engine/Monsters.c). On a hit, *how* it's heard:

- **LOUD** (`playerLoudness >= NOISE_HEAR_AGGRO_LOUDNESS(20)` **or** `soundDist <= 1`) → `wakeUp()`:
  full hunt **and** rouses the nearby horde. Melee is always this tier.
- **FAINT** (else) → **investigate** (§3.2.4): it knows roughly where, not that it was *you*.

Gated to `MODE_NORMAL`, state `SLEEPING|WANDERING`, non-captive
([Monsters.c:2058](../../BrogueSE/Engine/Monsters.c)). Only LOUD returns early from `updateMonsterState`
(so the sight/scent chain can't downgrade the fresh aggro); **FAINT falls through** on purpose so the
same turn's sight check can still upgrade an investigator into a hunter.

#### 3.2.4 The investigate state — `MB_INVESTIGATING`
A FAINT hear sets `creatureState = MONSTER_WANDERING` + the **`MB_INVESTIGATING`** bookkeeping flag
with `investigateLoc = player.loc`. The monster is **not hunting**: it walks to that *exact cell*
(real distance-map pathing via `monsterPathTowardLoc`, **not** scent, **not** the coarse waypoint
system) to look. While investigating its glyph blinks with `?` (§5). It escalates to a real hunt only
if it **spots you** or **hears you LOUD**; if it arrives and you're gone, it found nothing → see §3.2.6.
**This is the state that keeps stealth meaningful** — noise *attracts*, it doesn't auto-reveal. See §4.3.

#### 3.2.6 Returning to bed — `MB_RETURNING_HOME`
When an investigator finds nothing (arrives at the empty noise cell, or its path is blocked), what it
does next depends on **where it came from** ([Monsters.c, monstersTurn WANDERING block](../../BrogueSE/Engine/Monsters.c)):

- **Roused from sleep** → it recorded its bed (`slumberLoc`, set in `checkPlayerHeard` only for a genuine
  `MONSTER_SLEEPING` monster, never a dormant lurker). It drops `MB_INVESTIGATING`, takes
  **`MB_RETURNING_HOME`**, and **trudges back to that exact cell** (same `monsterPathTowardLoc`). On
  arrival → `creatureState = MONSTER_SLEEPING` (it dozes off again). **If it can't reach the bed**
  (no path / the cell is blocked) → it abandons the bed and falls back to ordinary wandering.
- **Already wandering when it heard you** → no bed was ever recorded → it just resumes wandering, exactly
  as before. *(The whole feature is scoped to sleep-roused monsters; a natural wanderer is untouched.)*

Precedence: hearing you again mid-return re-sets `MB_INVESTIGATING`, which is checked first, so a fresh
noise pulls it back into investigating; the bed persists (only cleared on arrive-home, blocked-return, or
committing to a hunt via `alertMonster`/`wakeUp`), so once the new investigation fizzles it heads home
again. A return-home monster shows no `?`/`(Investigating)` tell — those key on `MB_INVESTIGATING`.

#### 3.2.5 Investigate → hunt: the proximity-scaled spot roll
Once investigating, the bridge to a hunt is the §2.3 sight roll — but for an investigator it is
**proximity-scaled** instead of flat 25% ([Monsters.c:1855](../../BrogueSE/Engine/Monsters.c)):

```
tilesAway = perceivedDistance / 2        // awarenessDistance ≈ 2× tiles
chance    = clamp(INVESTIGATE_SPOT_ADJACENT_CHANCE(95) - (tilesAway-1)*INVESTIGATE_SPOT_FALLOFF(15),
                  INVESTIGATE_SPOT_FLOOR(25), 95)
```

| Tiles away | 1 | 2 | 3 | 4 | 5 | 6+ |
|---|---|---|---|---|---|---|
| Spot chance/turn | 95% | 80% | 65% | 50% | 35% | 25% (floor) |

**Still requires line of sight and being within sight range** (`perceivedDistance <= awareness`, player
in the monster's FOV) — earshot is bigger than sight (§4.1), so a monster heard from afar gets *no* spot
roll until it physically closes into your stealth radius and sees you. The floor equals the vanilla 25%
for continuity. Rationale: a creature that walked over to look should reliably acquire you point-blank
(no "stands adjacent, blind" dance), while a noise made across a room still grants a window to break LoS
and slip away. **Only investigators get this; passive wanderers keep flat 25%, so the stealth radius
keeps its meaning.**

### 3.3 Player hears the monster (COSMETIC — the feedback)

The forward direction: an off-screen monster's move you can't see but can "hear" as a ripple.
`monsterEmitMovementNoise()` ([Monsters.c:4660](../../BrogueSE/Engine/Monsters.c)) fires after a
monster steps. It is skipped if the monster is the player, **`MB_SUBMERGED`** (eels glide silent — the
splash on surfacing is the real tell), or **`VISIBLE`** (you watched it — that's seen, not heard).
Otherwise:

```
detectChance = clamp(NOISE_BASE_PERCEPTION(25) + awarenessEnchant*NOISE_AWARENESS_PER_ENCHANT(11)
                     + noiseModifier            // the monster's signed tier, §3.4
                     + distanceModifier         // sound map: near-field +15, else -3/tile
                     + terrainNoiseModifier     // emission, §3.4
                     + (playerAdjacentToClosedDoor ? NOISE_DOOR_LISTEN_BONUS(10) : 0)
                     + (justRested ? NOISE_REST_PERCEPTION_BONUS(10) : 0),
                     0, NOISE_PERCEPTION_CEILING(90))     // never a sure thing
```

`awarenessEnchant = rogue.awarenessBonus / 20` (net Ring of Awareness enchant). The roll uses
**`RNG_COSMETIC`** (`assureCosmeticRNG`/`restoreRNG`) — it's informational, must never perturb the
substantive stream, so noise tuning never desyncs saves/replays. On a hit → `cosmeticSpawnRippleMonster`
draws the **"heard something"** box-ripple at the monster's cell (the player feedback). This is how
*perception to hear unseen monsters* exists: a ringless character hears at the 25% floor; each net Ring
of Awareness enchant adds 11%; resting or pressing an ear to a closed door adds a listening bonus.

> The cosmetic→substantive promotion path is noted in code: swap `assureCosmeticRNG`/`restoreRNG` for a
> plain `rand_percent` only if "hearing" ever starts *driving* gameplay (interrupting travel/rest). Until
> then it's pure feedback.

### 3.4 Terrain emission (both noise directions) — `terrainNoiseModifier()`
[Monsters.c:4598](../../BrogueSE/Engine/Monsters.c). A signed **emission** term — how loud the *step
itself* is on this tile — read at the source and added to whoever is moving (player or monster). Takes
the loudest layer of the cell. (Distinct from the sound-map **propagation** in §3.1.)

| Tier | Value | Tiles |
|---|---|---|
| `NOISE_TERRAIN_CRUNCH` | +10 | grass, fungus, hay, ash, rubble, bridge |
| `NOISE_TERRAIN_SPLASH` | +8 | shallow water (loud splash — even as it hides scent) |
| `NOISE_TERRAIN_RUSTLE` | +6 | dense foliage, fungus forest, mud |
| `NOISE_TERRAIN_SOFT` | −8 | carpet, spiderweb |

Monster movement-noise tiers (`noiseLevelForMonsterMove`, the `NOISE_*` body-type tiers): SILENT −30,
QUIET −15, NORMAL 0, LOUD +15, BOOMING +30.

---

## 4. How sight and sound interact (the crux)

### 4.1 Earshot is bigger than sight
Both senses run inside `updateMonsterState` **every turn, independently**. The ranges differ on purpose:

- **Sight range:** `stealthRange` tiles (the spot roll needs `perceivedDistance <= stealthRange*2`
  doubled-units = `stealthRange` tiles, **plus LoS**).
- **Earshot:** `stealthRange * 2` **tiles** (the `monsterHearsNoise` gate), **no LoS required** — sound
  bends around walls.

So a monster can **hear you from ~twice as far as it can see you**, and through walls/doors where it
could never see you. But hearing only ever produces *investigate* (or aggro at point-blank/loud) — to
actually lock onto you by sight it must still close into the sight radius with LoS. The two ranges
nesting this way is the whole feel: noise pulls a distant monster toward you; stealth governs whether it
finds you once it arrives.

### 4.2 The state machine
A non-ally monster is in exactly one `creatureState`, with `MB_INVESTIGATING` layered on `WANDERING`:

```
                       hear LOUD / melee / spotted (§3.2.5)
   SLEEPING ─────────────────────────────────────────────► TRACKING_SCENT (hunting)
      │  ▲                                                       ▲   │
 hear │  │ reach bed                                             │   │ lose scent &
FAINT │  │ (§3.2.6)                                  spot (§3.2.5)│   │ out of range
      ▼  │                                                       │   ▼
  WANDERING                                              WANDERING ◄──┘
   + MB_INVESTIGATING ──── give up, was a sleeper ────►  + MB_RETURNING_HOME
      ▲   │                                                  │
      │   │ give up, was already wandering / blocked return  │
      │   ▼                                                  │
   WANDERING ◄────────────────────────────────────────────  ┘
      │   ▲
      └───┘ hear FAINT again (re-investigate; bed persists)
```

- **SLEEPING** → wakes only by **sound** (LOUD → hunt; FAINT → investigate) or damage. *Not* by sight.
  On a FAINT wake it records its **bed** (`slumberLoc`) so it can return.
- **WANDERING** → milling; gets the flat-25% sight roll and can hear you.
- **WANDERING + MB_INVESTIGATING** → actively walking to your last noise cell; proximity-scaled sight
  roll; `?` blink. On giving up: *was a sleeper* → `MB_RETURNING_HOME`; *was already wandering* → plain
  `WANDERING`.
- **WANDERING + MB_RETURNING_HOME** → trudging back to its bed; reach it → `SLEEPING`; blocked → plain
  `WANDERING`. No `?` tell.
- **TRACKING_SCENT** → hunting (alerts the horde on entry); `alertMonster`/`wakeUp` clears
  `MB_INVESTIGATING`, `MB_RETURNING_HOME`, and the bed.
- **FLEEING / ALLY** → outside this system's scope.

### 4.3 What this buys the player (the design intent)
- **Make noise and stay (rest, fight)** → the investigator walks over and the proximity roll catches you
  within a turn or two of reaching you → hunt. Resting next to a sleeper is a gamble.
- **Make noise and leave before it sees you** → it investigates an empty cell, finds nothing → **you
  escaped.** Noise *attracts*; it doesn't reveal. A monster you woke from sleep then **walks back to its
  bed and dozes off** (§3.2.6) rather than roaming — so a single stray noise doesn't permanently turn a
  sleeping floor into a wandering one (unless the bed is now unreachable, in which case it wanders).
- **Go silent** (hold still) → you emit nothing; even an adjacent wanderer is back to the flat 25%
  sight coin. Silence buys uncertainty.
- **Stack stealth** (darkness + shadow + rest + ring) shrinks *both* your sight radius *and* your
  loudness (the ring and armor terms are shared), so a stealth build is quiet on both axes.

---

## 5. Legibility (the tells)
- **`(Investigating)`** appears in the monster's sidebar status while `MB_INVESTIGATING`.
- **`?` blink** — an investigating monster's glyph ambient-blinks with `?` (slow, ~0.5s/half), riding
  the cosmetic animation layer's idle tick. A spotted/loud-heard monster flashes **`!`** once.
- **"Heard something" ripple** — the §3.3 grey box-ripple for an unseen monster's move.
- **Player sound-footprint ripple** — when you make noise and a visible, not-yet-hunting enemy is at/near
  your audible radius, a blue ripple radiates from you along the sound map, so you can *see* how far your
  noise carries. Shown until that monster starts hunting.

All four are drawn on the **cosmetic animation layer** — see
[../guides/cosmetic-animation-layer.md](../guides/cosmetic-animation-layer.md).

`D_NOISE_DEBUG` ([Rogue.h](../../BrogueSE/Engine/Rogue.h)) prints a message log line per detection event
("a monster hears something" / "has heard you" / "has spotted you"). **Pre-ship: off.**

---

## 6. Determinism
- **Monster-hears-player (§3.2):** **substantive `rand_percent`** — it changes seed outcomes. Fine for
  SE: it is the already-diverged firehose fork and is **Game-Center-silent (no leaderboard)**, so the
  only contract is internal (`same seed + build + inputs → same result`), which `rand_percent` upholds.
  All new state (`playerNoise`, `investigateLoc`, `MB_INVESTIGATING`) is set deterministically, so saves
  (input replays) stay correct.
- **Player-hears-monster (§3.3) + all animation:** **`RNG_COSMETIC`** — never touches the substantive
  stream. A ripple that played live but not on replay (or vice-versa) is *correct*; tuning these never
  desyncs a save.

---

## 7. Tuning levers (all in `Rogue.h` unless noted)

| Lever | Default | Governs |
|---|---|---|
| `NOISE_SYSTEM_ENABLED` | 1 | master on/off for all of §3 |
| **Monster hears player (substantive)** | | |
| `NOISE_HEAR_BASE` | 15 | base % to hear a normal-loudness action |
| `NOISE_HEAR_NEARFIELD_RADIUS` / `_BONUS` | 2 / 20 | point-blank hearing boost |
| `NOISE_HEAR_FALLOFF_PER_TILE` | 4 | hearing lost per sound-tile beyond near field |
| `NOISE_HEAR_CEILING` | 95 | hearing cap (sound never auto-wakes) |
| `NOISE_HEAR_AGGRO_LOUDNESS` | 20 | loudness ≥ this (or `d≤1`) → aggro, else investigate |
| `NOISE_PLAYER_MELEE / THROW / AGGRAVATED / LEVITATE` | 30 / 15 / 60 / −10 | action loudness spikes |
| `NOISE_PLAYER_ARMOR_SCALE / STEALTH_RING_SCALE` | 2 / 3 | armor / ring contribution to loudness |
| `INVESTIGATE_SPOT_ADJACENT_CHANCE / FALLOFF / FLOOR` | 95 / 15 / 25 | investigate→hunt proximity curve (§3.2.5) |
| **Player hears monster (cosmetic)** | | |
| `NOISE_BASE_PERCEPTION` | 25 | hearing floor, ringless |
| `NOISE_AWARENESS_PER_ENCHANT` | 11 | hearing % per net Ring of Awareness enchant |
| `NOISE_PERCEPTION_CEILING` | 90 | hearing cap |
| `NOISE_NEARFIELD_RADIUS` / `_BONUS` | 2 / 15 | point-blank perception boost |
| `NOISE_FALLOFF_PER_TILE` | 3 | perception lost per tile |
| `NOISE_DOOR_LISTEN_BONUS` | 10 | bonus while standing at a closed door |
| `NOISE_REST_PERCEPTION_BONUS` | 10 | bonus while resting (listening intently) |
| `NOISE_RIPPLE_RADIUS / MAX_STRENGTH` | 3 / 60 | "heard something" ripple size/brightness |
| **Shared / terrain** | | |
| `NOISE_DOOR_COST` | 4 | extra sound-map cost through a door/foliage/smoke |
| `NOISE_TERRAIN_CRUNCH / SPLASH / RUSTLE / SOFT` | 10 / 8 / 6 / −8 | terrain emission (§3.4) |
| `NOISE_*` body tiers (QUIET…BOOMING) | −15…+30 | per-monster movement loudness |
| `NOISE_INVESTIGATE_BLINK_FRAMES` | 30 | `?` blink cadence |
| `D_NOISE_DEBUG` | 1 | per-event debug log (pre-ship: 0) |
