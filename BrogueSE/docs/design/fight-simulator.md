# Fight Simulator — Design Spec

A headless, statistical combat simulator for evaluating **loadout metas** and **new/modified
creatures** without playing hour-long games. Modeled in spirit on DCSS's `fsim`, but adapted to
Brogue's economy-over-time balance, where the decisive questions are about *sustain* and *resource
cost*, not raw burst.

Status: design agreed; not yet implemented.

**Scope.** Targets the **Brogue SE engine** (`Brogue-iPad/BrogueSE/Engine/`) — the gameplay-fork
library, not the bundled Classic 1.7.5 or faithful BrogueCE engines — and within it the **standard
`VARIANT_BROGUE`** game (SE's default; the ~26-depth fork of BrogueCE 1.15 where SE's original content
lives). The `RAPID`/`BULLET` in-engine variants are out of scope. Note the combat *formulas*
(`PowerTables.c`) are shared across variants; only the per-variant tables (`GlobalsBrogue.c`) and
`gameConst` differ, and we read the standard-variant set.

---

## 0. Motivating questions

The tool exists to answer balance questions that are currently only answerable by long playthroughs:

1. **The weapon-vs-staff gap.** A plain, heavily-enchanted heavy weapon (e.g. war axe) currently
   dominates: enchant scaling is *geometric* while staff damage is *linear*, the weapon is free, and
   enchanting buys down the strength requirement. Can we tune enchant/strength/heavy-weapon constants
   to bring weapons on par with combat staves **without overshooting**?
2. **New creature tuning.** If rats get a "pestilence" trait, *is it too much*? How far past comparable
   existing threats does it push?
3. **Build viability between battles.** How do we fairly compare a Ring-of-Reaping staff build against a
   +15 war-hammer warrior when the staff's whole viability depends on recharge economy across fights?
4. **Individual monster tuning/balancing — new *and* old.** Beyond introducing a new creature, rebalance
   any single monster (buff/nerf stats, flags, abilities, bolts) and see the effect. Pin the monster as
   subject, A/B the change against the baseline cohort across the archetypes where it actually appears
   (by `hordeCatalog` depth range), and read whether it moved inside or outside the comparable-monster
   band. Covers both "is the new thing too strong" and "did this nerf to an existing monster do what we
   intended."

### Why the meta exists (grounding)

- `damageFraction` (`PowerTables.c:154`) — weapon damage scales as `1.065^(4·netEnchant)`, **geometric**
  (~1.29× per full enchant point).
- `staffDamageHigh` (`PowerTables.c:50`) — `4 + 2.5·enchant`, **linear**.
- `netEnchant` / `strengthModifier` (`Combat.c:65`, `:74`) — net enchant = `enchant1 + strengthModifier`,
  clamped `[-20, 50]`; over the strength requirement adds `+0.25/pt`, under subtracts a punishing
  `-2.5/pt`.
- Enchanting a weapon does **both** `enchant1 += mag` **and** `strengthRequired -= mag`
  (`Items.c:8456`), so early enchants on a too-heavy weapon simultaneously add geometric damage and buy
  off the under-strength penalty — the compounding behind the meta.
- Staves are **charge-starved**: `charges` (current) ≈ 2 + enchant extras, `enchant1` = max charges,
  `enchant2` = recharge "mojo" (500/1000) refilled slowly via `rechargeItemsIncrementally`
  (`Items.c:338-349`).
- **SE-original staff ramps (the staff-side gap lever).** Lightning and firebolt staves gain nonlinear
  power at **net enchant ≥ 5** (a staff's net enchant = its raw `+enchant`; staves get no strength
  modifier). Gated on `theBolt->empowerment` (= `netEnchant/FP_FACTOR`, `Items.c:7946`), applied in the
  bolt code, defined in `PowerTables.c:62-72` (tagged "iOS port (Brogue SE)"):
  - `staffLightningChainCount` — chain jumps 1 (+5) → 3 (+11)
  - `staffLightningChainRange` — arc range 3 (+5) → 8
  - `staffLightningStunDuration` — paralysis 1 (+5) → 3 turns
  - `staffFireboltBloomDecrement` — incineration bloom spread, 37 (+5) → floor 12 (LOWER = farther)

  These are *the* reason a high-enchant lightning/fire staff is situationally strong (corridor lines,
  clusters), and the breakpoint at +5 means the gap analysis must sweep across it, not just at the
  endpoints.

---

## 1. Headline metric (Q1)

Primary output is **clear-cost at depth**, reported **per encounter archetype**:

- **HP cost** — % of max HP lost to neutralize the threat.
- **Resource cost** — charges spent (and heal/recharge consumed).
- **Win probability** and **turns-to-clear**.

Secondary/bonus readout: **raw analytic per-encounter DPS** straight from the engine's own math (see §9
oracle).

Rationale: the meta is a *sustain/economy* story, not burst DPS. A pure-DPS metric would hide staff
charge scarcity and draw the wrong conclusion. A weapon reports "0 charges, X% HP lost"; a staff reports
"Y charges, Z% HP lost" — the gap is directly legible.

---

## 2. Spatial fidelity (Q2)

**Templated encounters on a tiny stub `pmap`** (option B). Geometry is required — `buildHitList(...,
sweep=true)` (`Combat.c:2182`, axe cleave) and the lightning/fire bolt code both trace the real grid, so
a positionless duel literally can't run AOE code. We do **not** do full movement/pathfinding/AI (too
noisy to attribute a result to a balance change).

Each archetype = geometry + composition, real monster structs placed on a stub grid, real
damage/bolt/sweep/DF code, Monte-Carlo'd. Starter archetype set:

| Archetype        | Geometry                              | Stresses                          |
|------------------|---------------------------------------|-----------------------------------|
| `lone-tank`      | 1 high-HP target, melee range         | sustained single-target (poison)  |
| `frenzy-cluster` | N enemies adjacent                    | axe cleave, AOE staves, pestilence|
| `corridor-line`  | N enemies in a line                   | lightning chain                   |
| `scattered-pack` | N enemies spread                      | mixed; AOE devalued               |
| `ambush-at-range`| 1 enemy at range R, closing           | kiting / staff range value        |

Kiting is **abstract**: attacker gets `floor(openingDistance / netClosingSpeed)` free ranged actions
before melee closes — no real pathfinding.

---

## 3. Player budget & allocation (Q3)

- **Budget derived from the metered cadence** (`meteredItemsGenerationTable_Brogue`, `GlobalsBrogue.c:659`,
  the standard `VARIANT_BROGUE` table; applied in `populateItems`, `Items.c:758-769`). Replaying the
  cadence yields expected enchant scrolls,
  strength potions, and life potions (→ max HP) by depth D. This is the default; **no free enchant lever**
  in standard runs.
- **Allocation policy is a first-class swept dimension** — `{all-weapon, all-armor, weapon+armor split,
  all-staff}`. This *is* the meta under test.
- **Strength** is a derived global counter (not per-item). Weapon effective requirement = `base −
  enchants-on-weapon`; `netEnchant` is computed honestly via the real functions, including the −2.5/pt
  under-strength penalty — so the "enchant a too-heavy war axe" strategy emerges naturally with no fudge.
- **Optional break-even analysis mode**: sweep enchant total freely to find the point where a weapon
  overtakes a staff. Analysis-only, not the standard run.

---

## 4. Encounter resolution & sustain (Q4)

- **Encounter layer (core)**: per-archetype Monte-Carlo → (HP lost, charges spent, turns, win%).
- **Thin sustain layer**: draw a depth's encounter sequence weighted by archetype frequency; carry HP
  (regen between fights) and staff charges (recharge based on a single soft parameter: turns walked
  between encounters); report a depth-level resource trajectory. This is the **only** layer that makes
  staff recharge matter — without it a staff "fires free every fight."
- **Turn model**: reuse Brogue's real speed convention (`movementSpeed`/`attackSpeed`, 100 = normal) to
  schedule who-acts-when and attacks-per-exchange. Attack-speed differences (fast jackals, slow ogres)
  materially change HP lost, so 1:1 exchanges are not assumed.

---

## 5. Loadout scope & action policy (Q5)

- **Loadout = full build**: weapon + armor + up to 2 rings + optional staff; hybrids allowed.
- **Economy aggregates all sources** by running the real hooks: per-hit (`rogue.reaping` →
  `rechargeItemsIncrementally`, `Combat.c:1420`; `rogue.transference` heal, `Combat.c:1953`) and per-turn
  (regen, mojo recharge, gas/DF spread). Reaping makes melee↔zap interleaving the whole point of a staff
  build, so it must be modeled.
- **Player action policy = best-of a small declarative named set** (option B):
  `{pure-melee, zap-on-threat (zap if it kills/CCs or ≥K clustered, else melee-to-recharge),
  kite-then-melee}`. Report cost **per policy**; treat **best-of as the "skilled player" upper bound**,
  naive as the floor. We explicitly do **not** search for optimal play (that's a combat AI; the in-game
  autopilot can't fight, so there's nothing to borrow).
- **Consumables off by default**, with an opt-in "last-resort heal below X% HP" rule available to any
  policy.

---

## 6. Monster selection (Q6)

Two use modes:

- **Mode 1 — tune a specific creature**: pin the subject (e.g. rat-with-pestilence) into the matching
  archetype(s); the tool auto-runs baseline-vs-modified A/B.
- **Mode 2 — tune a system/formula**: evaluate loadouts against the representative population, no subject.

Population model = **role-based frequency-weighted draw** (option C): archetype declares geometry + a role
tag (`weak-swarm`, `single-tank`, `mixed-pack`); the role is filled by a frequency-weighted draw from
`hordeCatalog` at depth D (`minLevel/maxLevel/frequency`, `Monsters.c:685-707`). **Mutations off by
default** (clean attribution) but toggleable to a realistic-depth-distribution mode.

**Baseline band**: a **fixed named cohort** of reference builds/monsters whose membership is stable but
whose numbers are **recomputed each run under the engine variant being tested**. The yardstick is
relative ("did war axe and combat staff converge vs a fixed reference set"), so it stays honest when a
formula change moves everyone at once.

Pestilence example → pin rat-with-pestilence into `frenzy-cluster` at depth D, A/B vs vanilla rats, read
the HP-lost + turns + sustain-trajectory delta. "Too much" = the delta exceeds the band set by comparable
existing swarm threats.

---

## 7. Balance knobs (Q7)

- Extract the named constants into a **sim-only `balanceConfig` struct** with the current values as
  defaults (option B implemented as C — the shipping game behaves identically; the harness populates the
  config).
- **Initial knob set is narrow** — only the weapon-vs-staff gap levers:
  - enchant→damage curve base/cap — `damageFraction` (`PowerTables.c:154`)
  - net-enchant clamp (the `50`) — `netEnchant` (`Combat.c:79`)
  - strength bonus/penalty rates (`0.25` / `2.5`) — `strengthModifier` (`Combat.c:67`)
  - staff damage curve (`4 + 2.5·e`) — `staffDamageLow/High` (`PowerTables.c:49`)
  - **SE staff ramps (the +5 breakpoint levers)** — `staffLightningChainCount` / `…ChainRange` /
    `…StunDuration` / `staffFireboltBloomDecrement` (`PowerTables.c:62-72`). These are the staff-side
    knobs for closing the gap; tuning the weapon side alone (enchant curve) ignores half the lever.
  - heavy-weapon base damage & str-req — `weaponTable` (Globals.c)
  - enchant→str-req reduction — `enchantMagnitude` (`Items.c:8456`)
  - Widen later; each parameterized site is a refactor whose defaults must be proven byte-identical to
    shipping.
- **Implemented knob set** (beyond the initial list): per-weapon enchant cap
  `heavyWeaponCap[NUMBER_WEAPON_KINDS]` and mechanic damage levers `penetrateDamagePct` /
  `passAttackDamagePct`. See §12 for the tuning that used them and `FIGHTSIM_TUNED_DEFAULTS` for the result.
- **A/B = baseline + variant on shared seeds** (paired / common random numbers) → clean per-archetype diff.

---

## 8. Architecture (Q8)

- **Separate headless CLI target** (option A), modeled on DCSS's `fake-main.hpp`:
  - compile `Engine/*.c` + a **stub platform layer** — no-op implementations of the I/O free-functions
    (`nextKeyOrMouseEvent`, render/flash hooks, `combatMessage`). (This fork has **no `brogueConsole`
    struct**; the platform is free C functions — `SEBridge.mm:7`.)
  - **custom mini-loop** that inits globals (`gameConst`, catalogs, RNG, synthetic `pmap`), places
    creatures, and calls the **real** combat primitives directly (`attack()`, bolt functions, status
    processing, `rechargeItemsIncrementally`, per-turn tick). Never `rogueMain` / `mainBrogueJunction`.
- Shipping binary stays provably untouched; runs in batch/CI.
- **Implementation risk = transitive globals**: `attack()` and bolt code reach into many globals and call
  I/O hooks. Mitigation: no-op platform stubs + start from a single `attack()` call and expand global-init
  until it runs clean, rather than initializing the whole world up front.
- **Config-file driven** (declarative: depth, loadout matrix, allocation policies, archetypes,
  `balanceConfig` variants, trials, seeds) → CSV / diff output. Large reproducible matrices over ad-hoc
  CLI flags.

---

### Spike result (de-risk — DONE)

The transitive-globals risk is **retired**. A throwaway spike (`tools/fightsim-spike/`) proves:

- The whole engine (`Engine/*.c`) links into a headless CLI with **clang directly** (no Xcode), against
  a **no-op platform layer** of exactly **~35 free functions/variables** (`platform_stubs.c`): render
  (`plotChar`), input (`nextKeyOrMouseEvent`), haptics, file I/O, high scores, screenshots, telemetry,
  plus the `hasGraphics` / `serverMode` / `nonInteractivePlayback` / `graphicsMode` /
  `brogueCEAtTitle` / `brogueSETerminationRequested` flags. That list is the entire boundary.
- `initializeGameVariant()` + `initializeRogue(seed)` set up `gameConst`, the catalogs, the RNG, the
  `player`, and the `monsters` list — **without** `startLevel`/dungeon generation.
- `attack()` runs correctly against a **hand-carved stub grid** (carve a few `FLOOR` cells, set
  `HAS_PLAYER`/`HAS_MONSTER`, place a `generateMonster()` rat adjacent). Player kills the rat in 2 rounds,
  damage applied both ways, and the **death path (`killCreature`) does not crash**. Exit 0.
- The §9 analytic oracle is reachable headless: `hitProbability(&player, rat)` returns sane values
  (100% / 50%) in the same process.

Implication: the §8 architecture is sound and the stub-grid approach (not full level gen) works, so we are
not forced onto the `initializeRogue + startLevel` fallback. Build/run via
`tools/fightsim-spike/build.sh`.

**Bolt / AOE path also proven (spike #2, `bolt_main.c`).** The real `zap()` bolt code runs headless on the
stub grid, and the **SE lightning ramps fire correctly**. Firing a lightning bolt down a line of (HP-
inflated) monsters with an extra monster placed *off* the line:

- **+4 (empowerment 0, below threshold):** on-line monsters damaged; the off-line monster is **untouched**
  (no chain).
- **+6 (empowerment 6, SE ramp active):** the off-line monster takes chain damage **and** gains
  `STATUS_PARALYZED` — i.e. `resolveLightningChain` arced to a target the straight line missed and applied
  the SE stun, through the real bolt code.

So the AOE/bolt path — including SE's `>=5` ramps and the `killCreature`/status machinery they touch —
works headless. Gotcha to remember: `staffLightningChainCount(0)` still returns 1 (the function clamps to
min 1), but the chain is gated by `empowerment >= 5` *inside* `zap`, so +4 correctly produces no chain
despite the helper's return value — don't read the ramp helpers in isolation as "is the chain active."

## 9. Validation & statistical rigor (Q9)

- **Correctness — engine-analytic oracle (primary)**: the sim's per-attack layer must converge to the
  engine's own closed-form `hitProbability()` (`Combat.c:112`) and `monsterDetails()` (`Monsters.c:5928`)
  values within Monte-Carlo error. Mismatch ⇒ harness mis-wired. Automatable as a regression test; catches
  nearly every wiring bug for free.
- **Correctness — known-outcome anchors (secondary)**: calibrate aggregate results against real-run truth
  (`exploration-stats.csv` data; obvious cases like "+0 dagger vs lone rat at D1 ≈ 100% win").
- **Rigor — common random numbers**: baseline and variant share per-trial seeds, so the *diff* has tiny
  variance even when absolute numbers are noisy.
- **Rigor — CI-driven trial counts**: every headline number reported as mean ± confidence interval; raise
  trials until CI width < threshold (rather than a hardcoded round count like fsim's 4000). A reported
  gap-narrowing is then provably real, not noise.

---

## 10. Methodology: how results are produced

Two output layers, kept distinct:

1. **Damage-curve reference (analytic, deterministic).** Emit the known curves — `damageFraction`
   (weapons) and `staffDamage` (+ SE ramps) — as a reference CSV (enchant → expected per-hit damage,
   accuracy). This is the **§9 oracle and a sanity dataset**, NOT the answer: it ignores accuracy-vs-
   defense, HP, multi-target, charges, and turn order.
2. **Clear-cost simulation (Monte-Carlo, the answer).** Run encounters, measure *cost to win* — HP lost,
   charges spent, turns, win%. This ranks loadouts and detects whether a balance change closed the gap.

**What "seed" means here.** We do **not** generate dungeon levels (rejected in Q2 as too noisy). The seed
is the **combat-RNG seed** (hit / damage / mutation rolls). We run a distribution of seeds and pair them
across loadouts via **common random numbers**: for each seed, every loadout faces the identical encounter
and identical rolls, and we average the per-seed *differences* so luck cancels (§9). The **economy seed**
(what you'd find) is not rolled — it's replaced by the metered-cadence-derived expected budget at depth D
(§3).

**"Sending a player down virtual levels"** = the sustain/trajectory mode (§4 sustain layer): a *sequence*
of archetype encounters at increasing depth, carrying HP and staff charges with regen/recharge between,
same seed across loadouts. It is "a run" whose *levels are archetype sequences*, not procedurally
generated dungeons. This is where free-weapon vs charge-starved-staff economics surface.

**Worked example — the corridor-line slice (the Phase 1 tracer):**
1. Inputs: depth D; archetype `corridor-line` (N enemies in a line, roles drawn frequency-weighted from
   `hordeCatalog` at D); loadout pair (war axe @ all-weapon vs +6 staff of lightning); `balanceConfig` =
   defaults; seed range + CI target.
2. For each (loadout, seed): build the player from the depth-D budget, carve the line, place monsters, run
   the policy-driven encounter to resolution, record (HP lost, charges, turns, win).
3. Aggregate over seeds → mean ± CI per loadout; paired diff between loadouts (CRN).
4. Output: one CSV row per (loadout, archetype, depth) of clear-cost metrics + the analytic damage-curve
   reference for cross-check.

## 11. Delivery phases

Each phase is independently runnable and yields a result you can read. Vertical-slice first
(tracer bullet), then broaden.

- **Phase 0 — Harness skeleton.** _(Skeleton DONE — `tools/fightsim/`.)_ Promote the spike into a real
  target: the sim-only `balanceConfig` + the §9 analytic-oracle regression test, CSV plumbing.
  - **Done:** `tools/fightsim/` builds via `build.sh`; `fightsim --selftest` asserts 19 engine formula
    goldens at shipping defaults (staff curve, SE lightning/fire ramps, strength/net-enchant) — PASS;
    `fightsim --damage-curve` emits the §10 layer-1 reference CSV (geometric weapon mult vs linear staff,
    SE ramps switching on at +5).
  - **Deferred to Phase 5 (decision):** the `balanceConfig` struct + shipping defaults are defined
    (`balance.h`), but the engine formula functions do **not** yet read it. Wiring them touches shipping
    `PowerTables.c`/`Combat.c` **and the Xcode project**, so it's deferred until a knob actually needs to
    move (Phase 5). Phases 0–1 run at shipping defaults → zero engine behavior change. The self-test
    goldens are the byte-identical guard for that future refactor.
  - **Remaining for Phase 1 use:** config input (CLI flags) + RNG-seed plumbing (`seedRandomGenerator`,
    `RNG_SUBSTANTIVE`) land with Phase 1's runner.
- **Phase 1 — Corridor-line tracer (single archetype, single encounter).** _(DONE — `tools/fightsim/`
  `sim.c`; run `fightsim --corridor <enchant> <trials>`.)_ Custom tick loop over the real
  `attack()`/`zap()`/`killCreature` on a 1-wide corridor; loadout builder (`generateItem` → set enchant /
  lowered str-req / charges → `rogue.weapon` + `recalculateEquipmentBonuses`); straight-line monster
  choreography; one `zap-on-threat` policy; CRN-paired trials; mean ± 95% CI.
  - **Validating result** (war axe vs staff of lightning, 5 goblins, 60 HP, per enchant — HP lost):
    `+4` axe 14.2 / staff 0.3 (staff dominates; axe is under-strength) → `+6` 1.1 / 0.0 → `+8`–`+10`
    0.0 / ~0.2 (axe one-shots the front goblin in the chokepoint before it strikes; staff just wins on
    *speed* — 2 turns vs 11 — for ~1 charge) → `+14` both flawless. A believable crossover that matches
    play intuition; the staff's *situational* superiority is expected to show in frenzy-cluster (Phase 3),
    not the corridor chokepoint.
  - **Known caveats (carry into later phases):** (1) player wins initiative on ties — fair for "stand and
    receive a single-file approach," revisit for other archetypes; (2) `initializeRogue` is called per
    encounter and leaks level allocations, so trials are practically capped at a few hundred until Phase 2
    adds a cheap state reset (or frees the level); (3) one policy only — don't over-read absolute numbers
    until Phase 2 adds the policy set + best-of.
- **Phase 2 — Loadout & budget model.** _(Build model DONE; budget-cadence derivation + perf still open.
  `fightsim --matrix <budget> <trials>`.)_ Generalized loadout → `BuildSpec` (weapon + armor + staff +
  ring, per-slot enchant); builders for armor (`makeArmor`) and rings (`makeRing` + `updateRingBonuses`,
  wiring `rogue.reaping`); allocation via named builds (`axe_all`, `axe_armor_split`, `staff_pure`,
  `staff_reaping`); honest `netEnchant` strength.
  - **Validating result** (budget +8, 4 ogres, 80 HP — HP lost): `axe_all` 44 / `axe_armor_split` 67 /
    `staff_pure` 0 / `staff_reaping` 0. Splitting the budget *weakens* the war axe (less damage → longer
    fight → +23 HP); the staff kills the dangerous ogres at range before contact (0 HP); **reaping ==
    pure-staff because the fight is too short to deplete charges** — confirming reaping/charge-economy is
    a long-attrition lever (cluster / tanky fights), not a corridor one. Inverts the +10-goblin corridor
    finding (there the chokepointing axe took 0 HP): danger level flips which side the corridor favors.
  - **Bug fixed:** `initializeRogue` doesn't gen a level, so off-corridor `pmap` cells held uninitialized
    flags; high-damage blood spread (war axe vs ogre) hit a stray `HAS_MONSTER` cell → `monsterAtLoc`
    NULL → SEGV. Now the whole `pmap` is wall-filled with cleared flags each encounter, and the cell
    behind the player stays wall so knockback can't relocate the player into the heavy updateVision path.
  - **Budget-by-depth DONE (`budget.c`, `fightsim --depth`).** `fs_buildBudgetTable` descends the engine's
    own generated levels (avg of N seeds) counting cumulative floor items → expected strength potions
    (`strength = 12 + count`), enchant scrolls (`= budget B`), life potions (`maxHP = 30 + 10*count`) by
    depth. `--depth` sweeps depth with all three derived, so the weapon's curve reflects *strength* accrual
    (str 12→18 by D19), not just enchants — strength is the other half of the weapon graph.
  - **Monster-leveling DONE.** `fs_run(depth>0)` picks a depth-appropriate monster from `hordeCatalog`
    (`pickHordeType`, frequency-weighted, deterministic per seed → CRN-safe), bulk member or leader, so
    deep fights face deep monsters. Count/geometry stay controlled per archetype; only the tier scales.
  - **Still open in Phase 2:** (1) ~~metered-cadence budget derivation~~ — done above;
    (2) **perf** — short fights (goblins) are ~6 ms/encounter; tanky fights (ogres, many turns) cost more.
    Two cosmetic hot paths suppressed so far: **blood spread** (`info.bloodType = 0` — `spawnDungeonFeature`
    ran on every hit) and **bolt animation** (carved cells are left *unseen*, so `zap()`'s per-cell
    `backUpLighting`/`paintLight`/display is skipped — combat damage is visibility-independent, verified:
    goblin +6 result unchanged 0.95→1.01 within noise). Remaining cost is genuine per-`attack()`/`zap()`
    engine work over the (tick-capped) fight; tight-CI runs at thousands of trials still want a lightweight
    per-encounter reset + a sampling-profiler pass. Modest trial counts (10-50) are practical now.
    (3) Transference/Regeneration rings + the policy *set* (only `zap-on-threat` so far).
- **Phase 3 — Archetype library.** _(DONE. `fightsim --archetypes <budget> <trials>`.)_ `fs_run` now takes
  an `Archetype` (corridor-line, frenzy-cluster, scattered-pack, lone-tank, ambush-range); `carve()` builds
  a 1-wide hall or an open room; `placeMonsters()` lays out single-file / packed blob / spread / lone / far-
  wall; monsters use 2D straight-line approach. War-axe cleave (`ITEM_ATTACKS_ALL_ADJACENT`) now hits all
  adjacent enemies, and the staff aims at the farthest monster so the bolt rakes the group. *Result:* per-
  archetype clear-cost. (Monster population is still a fixed kind, not yet `hordeCatalog` frequency-weighted
  — that's the Phase 6/role-tag follow-on.)
- **Phase 4 — Sustain layer (depth trajectory).** _(DONE. `fightsim --trajectory <budget> <trials>`.)_
  `fs_run` gained `startHP`/`startCharges` so a sequence of encounters carries live HP and staff charges;
  between fights a soft rest applies HP regen + slow staff recharge. *Result:* the "virtual run" — the staff
  can run dry over a stretch while the free weapon sustains.
- **Phase 5 — Balance-knob A/B + reporting.** _(DONE. `fightsim --ab <cap> <budget> <trials>`.)_ The
  `balanceConfig` knobs are now wired into the engine formulas behind `#ifdef FIGHTSIM` (strengthModifier,
  netEnchant clamp, staffDamageLow/High) — **shipping is provably unchanged** (the `#else` is the original
  literal; the selftest goldens pass under `-DFIGHTSIM`, proving the gBalance path is byte-identical at
  defaults; no Xcode-project change needed). `--ab` A/B's the net-enchant clamp (= weapon enchant *damage
  cap*) on CRN-shared seeds and reports the war-axe-vs-staff gap shift. *Result:* "did lowering the enchant
  cap narrow the gap, by how much" — measured, not played. (Break-even sweep + named-cohort baseline band
  remain as reporting niceties.)
- **Phase 6 — Monster-tuning mode.** Pinned-subject A/B (new/old monster), mutation-roll toggle. *Result:*
  the rat-pestilence / individual-monster-balancing use case (motivating Q2 & Q4).
  - **⚠️ Flag for this phase — the sentinel-HP trick must be OFF here.** Phases 1-5 give the player a huge
    sentinel HP (`FS_BIG_HP`) so the engine never fires `gameOver()` and we measure *HP-lost vs a virtual
    budget* — perfect for *loadout comparison* (how much does this build pay?), but **wrong for
    creature/boss tuning**, where the question is literally "does the player **die**?" Lethality (death
    rate, can-a-boss-burst-you-down, does-a-meta-slice-through) needs **real player HP** and faithful death
    detection — the virtual-budget approximation flattens burst/threshold dynamics and suppresses any
    HP-fraction-dependent behavior. So creature-tuning mode should run with real HP (accepting the
    `gameOver` cost, or stubbing `gameOver` itself cheaply) rather than the sentinel. Keep the sentinel for
    the loadout/meta scenarios; switch it off for lethality.

## 12. Tuning result — the heavy-weapon enchant meta

The flagship question (Q0): does heavy-weapon enchant scaling make one weapon the universal go-to?
**Answer: yes, late-game — but the fix is per-weapon and per-mechanism, not a single global cap (and for
the pike it isn't even an enchant lever).** This section records the converged tuning, baked as
`FIGHTSIM_TUNED_DEFAULTS` (balance.h) and reproducible with `--tuned`.

### Prerequisite: model every weapon's real mechanics first
Tuning conclusions are only valid once each weapon is credited for what it actually does. The sim models:
attack speed (rapier 2× / mace+hammer ½× recovery), war-axe cleave (all adjacent), rapier lunge (closing
crit), mace/hammer knockback+stagger, flail pass-attacks (every enemy adjacent to both the start and
destination cell of a move), and the **spear/pike reach-2** — `handleSpearAttacks` (Movement.c, range 2)
strikes a straight-line enemy *two tiles away across an empty gap* without moving, as well as the
adjacent+behind penetrate. Before each fix, rankings were artifacts: mace/hammer looked like 95%
dominators at 2× their real rate; rapier looked like a 34% joke; and the pike looked *situational*
(scattered-pack weakness) only because its reach was missing. Only whip's EXTEND reach (range 5) remains
unmodeled (whip is out of roster).

### Findings
1. **The dominance is a late-game phenomenon.** At depth 10–13 the enchant budget is small, all weapons
   bunch ~64–84, and the levers don't bite. The runaway is real only at depth ~16–19 (budget +9/+10),
   exactly where enchant scaling compounds. So the tuning is a **late-game-only correction**; early/mid
   play is untouched by construction (the knee clamps the high end of `netEnchant`, which only the late
   budget reaches).
2. **One lever per *mechanism*, not a blanket cap.** Weapons respond to an enchant cap by what drives them:
   - **Raw-stat weapons** (broadsword — no mechanic; war axe — cleave) take a clean enchant **soft knee**:
     full value to the knee, then a 25% marginal taper. No cliff — past the knee each enchant still helps a
     little, so a rational player diversifies into staff/armor (a hybrid nudge by incentive, not a wall).
   - **war pike is immune to damage levers.** Enchant cap (→94 capped), penetrate-damage (→90 at 50%), and
     even reach-damage (→93 at 0%) barely move it. Its power is **throughput**: normal attack cadence +
     penetrate (2-in-line) + reach out-damages even war hammer (base 30, but ½-speed). The lever that works
     is **attack speed** — at 2× recovery the pike lands at band (84) and its scattered-pack weakness
     returns (48), because it can no longer poke the approach fast enough.
   - **flail** takes a **pass-attack damage** trim (its multi-hit *is* its power; an enchant cap on it is a
     cliff, 86→68 between cap 12 and 10).
3. **Whack-a-mole.** Each time the top weapon is reined in, the next even-profile generalist inherits
   "best everywhere" (flail jumped to 88 once the others were handled — hence its pass trim). The fix has
   to hit every universal generalist or it just trades one king for another.
4. **Model fidelity beats lever cleverness.** The pike chase is the cautionary tale: three plausible
   mechanic levers (penetrate, reach, enchant) all failed because the *model* was incomplete (missing
   reach) and the real driver (throughput) was only visible once it was fixed. Correct the mechanics first.

### The tuned config (`FIGHTSIM_TUNED_DEFAULTS`)
One lever matched to each weapon's actual driver; everything else untouched (war hammer stays the 1v1
king, mace self-balances via stagger recovery, nimble weapons stay free):

| weapon | lever | rationale |
|---|---|---|
| broadsword | enchant **soft knee 9 @ 25% slope** | pure raw-stat generalist; taper, no cliff |
| war_axe | enchant **soft knee 10 @ 25% slope** | raw scaling; cleave survives as a pack lean |
| war_pike | **2× attack recovery** | throughput weapon — speed is the only lever that bites |
| flail | pass-attack damage **50%** | its multi-hit is its power; trim the mechanic directly |

### Achieved end-state (depth 19, win% per archetype, `--tuned`)
`lone_tank` ≈ 98 for everyone (a single ogre at full enchant is trivial) — read the other four columns.

| weapon | corridor | cluster | pack | ambush | mean | identity |
|---|---|---|---|---|---|---|
| dagger | 18 | 22 | 15 | 10 | 32 | floor (buff candidate) |
| sword | 72 | 82 | 48 | 60 | 72 | honest baseline |
| rapier | 90 | 78 | 75 | 72 | 82 | corridor / skill |
| mace | 75 | 82 | 55 | 48 | 72 | even, self-balanced |
| axe | 68 | 80 | **78** | 52 | 75 | light pack pick |
| broadsword | 85 | 88 | 68 | 85 | 84 | even generalist |
| flail | 88 | 88 | 65 | 75 | 82 | line-ish multi-hit |
| war_pike | **92** | **95** | **48** | 85 | 84 | line king, pack-helpless |
| war_axe | 80 | 85 | **78** | 80 | 84 | pack / cleave king |
| war_hammer | 80 | **88** | 75 | 80 | 84 | cluster / 1v1 king |

The four heavies all land at **84 — tied — with completely different shapes**, and no weapon is dominant in
every situation. War pike is the line/cluster king (92/95) but helpless in scattered packs (48); war axe
and the light axe own packs (78); war hammer owns clusters/1v1; rapier owns corridors. The whole roster
(dagger aside) sits in a 72–84 band with **distinct per-archetype identities** — "right tool for the right
situation." Dagger (32) is the lone floor and the next candidate for a buff (runic-odds, not enchant).

### Hybrid economy — does the tuning nudge weapon → staff?
The flagship intent was that a weapon shouldn't be the universal go-to: surplus enchants should be
*better spent* glowing a staff (the SE lightning ramp at net-enchant ≥5: chain / range / stun). Comparing
all-in (weapon +B) vs hybrid (weapon +B−6 / lightning +6), per-encounter at depth 19 (mean win%):

| weapon | all-in SH | hybrid SH | all-in **TU** | hybrid **TU** |
|---|---|---|---|---|
| sword (control) | 71 | 89 | 71 | 89 |
| broadsword | **95** | 94 | 82 | **94** |
| war_axe | 92 | 93 | 83 | **93** |
| war_pike | **97** | 92 | 84 | 83 |

Under **shipping**, all-in wins or ties for the strong weapons (broadsword 95 vs 94, pike 97 vs 92) — there
is no reason to split, which *is* the "weapon is the go-to" problem. Under **tuned**, the ranking inverts:
hybrid leads by +10–12 (broadsword, war_axe) and pike's all-in edge collapses to a wash. The lever taxes the
*all-in* build (its weapon enchant is past the knee / the pike is slowed) but never the *hybrid* one (its
weapon sits below the knee at full value; the staff is untouched), so the scrolls pay off better on the
staff. The hybrid's edge concentrates where lightning should shine — cluster/ambush/pack — while the weapon
still carries single-target and corridors. Right tool, right moment, inside one loadout.

**It survives finite charges.** Over an 8-encounter floor that depletes the +6 staff (recharge +1/rest),
under the tuned config hybrid clears *more encounters before dying* than all-in for every weapon (d19
avg cleared: broadsword 1.90 vs 1.50, war_axe 2.17 vs 1.40, war_pike 1.70 vs 1.43), reversed from shipping
where all-in pike ran away (3.93). The early-fight lightning burst banks enough HP to carry past the point
the staff runs dry. (Caveat: that gauntlet is harsh enough that survival ≈ 0, so `avg_cleared` is a
*relative* depth-reached metric, not an absolute clear rate. Reproduce: `--hybrid`, `--hybridsustain`.)

### Mechanism (how the knobs reach the engine)
- Per-weapon enchant **soft knee**: `heavyWeaponCap[kind]` is the knee and `heavyWeaponSlopePct[kind]` the
  marginal % above it (0 = hard cap, 100 = no taper), read in `netEnchant` (`Combat.c`) behind
  `#ifdef FIGHTSIM`. Per-kind so each weapon curves differently.
- **Attack-speed lever**: `weaponRecoveryPct[kind]` scales the turn cost of melee/pass/lunge actions
  (sim-only — cadence lives in sim.c's tick loop, not the engine). 2× = the pike penalty.
- **Mechanic damage levers**: `penetrateDamagePct` / `passAttackDamagePct` / `reachDamagePct` (default 100).
  `sim.c` sets a runtime `gFsDamageScalePct` around the relevant secondary hit; `Combat.c` scales the
  player's weapon damage by it. All default to no-op → goldens stay byte-identical.
- Reproduce: `--tuned` (loads the preset, prints the table above). Explore: `--capsweep`, `--archprofile`,
  `--levertune`, `--tapersweep`, `--pikespeed`, `--reachsweep`, `--final`.

## Open / deferred

- **Land the tuned values in the shipping game** — port the soft-knee enchant curve to `netEnchant`, the
  flail pass-attack reduction to `Movement.c`, and the pike 2× recovery as an "extra turn to recover"
  (the existing mace/hammer stagger mechanic, minus the knockback) in `Items.c`/`Combat.c`. All ungated;
  an actual gameplay balance change that needs its own review. The sim values are the recommendation,
  not yet applied.
- **Buff the dagger** (32% floor) — via runic-odds, not enchant; re-verify it doesn't overshoot.
- Phase 6 creature/boss lethality — sentinel HP OFF (see §"Open"), monster-leveling axis already wired.
- Exact archetype parameters (N enemies, ranges, turns-between-encounters) — to calibrate against real runs.
- Which rings beyond Reaping/Transference/Regeneration are worth first-class modeling.
- Output/report presentation details (CSV schema, diff table layout).
