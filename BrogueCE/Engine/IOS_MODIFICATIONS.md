# iOS modifications to the BrogueCE engine

The code in `BrogueCE/Engine/` is a vendored copy of the upstream **BrogueCE 1.15**
engine, compiled into the embedded `BrogueCE.framework` and driven by the iOS host
through `CEBridge.mm`. This document records iOS-specific modifications layered on
top of the vendored engine C, so the divergence from upstream stays legible and
future maintainers (human or AI) don't mistake an intentional port change for a bug.

This is the CE counterpart to `iBrogue_iPad/BrogueCode/IOS_MODIFICATIONS.md` (which
covers the separate Classic engine that ships in the app target).

## Conventions

- **Engine → host hooks are plain C functions** declared `extern` at the top of the
  engine file that calls them and **defined in `CEBridge.mm`** (inside its
  `extern "C"` block). They route to the app via the `BrogueCEHost` protocol. Each
  is a no-op when there's no host or no device support, so the engine may call them
  unconditionally. Naming: `ce*` (e.g. `cePlayerTookDamage`, `ceSetTargeting`).
- **`uiMode` is a write-only host signal.** The engine only ever *assigns*
  `uiMode` (the `CBrogueGameEvent` tablet UI mode); nothing in the engine reads or
  branches on it. It is reported to the host by `CEBridge.mm`, which uses it to
  show/hide on-screen controls. Changing which value a screen sets is therefore a
  pure UI change and cannot affect game logic.
- **Keep changes minimal and commented.** Every edit below is marked in-code with an
  `// iOS port (iBrogue):` comment so it's greppable.

---

## Change log

### 2026-06-13 — Seed-entry keyboard: pre-fill the field + use a number pad (iOS port)

**What.** Two bugs in the seeded-game (and any pre-filled) text dialog, fixed together.

The engine maintains its own `inputText` buffer and renders the text on the game screen; the
hidden iOS `UITextField` is only an off-screen key-capture proxy. CE showed the keyboard purely
via `uiMode == ShowKeyboardAndEscape` and never told the host the default value, so the field was
**empty** while the engine buffer held the pre-filled seed. iOS does not fire its
`shouldChangeCharactersIn` callback for Backspace on an empty field, so the engine never received
`DELETE_KEY` for the pre-filled digits — they couldn't be deleted. We now hand the default to the
host before the input loop so the field is seeded to match the engine buffer.

The dialog also always used the default (alpha) keyboard even for numeric seed entry. We now pass
whether the entry is numeric so the host can show a number pad.

- **`Rogue.h` / `CEBridge.mm`**: new host hook `ceRequestTextInput(const char *defaultText, boolean
  numeric)` → `[gHost requestTextInput:numeric:]`.
- **`IO.c` (`getInputTextString`)**: call `ceRequestTextInput(defaultEntry, textEntryType ==
  TEXT_INPUT_NUMBERS)` once just before the input loop. (A number pad has no Return key; the host
  adds a "Done" accessory bar that submits like Return.)

### 2026-06-13 — Persist the last-played seed across app launches (iOS port)

**What.** The title screen's "New Seeded Game" prompt pre-fills `previousGameSeed` — the seed of
the most recent run. Upstream keeps this only in memory for the process lifetime; on iOS, where
backgrounded apps are routinely terminated, it reset to 0 on every relaunch, so the prompt never
remembered your last seed. We now back `previousGameSeed` with `NSUserDefaults`.

- **Host hooks** (`CEBridge.mm`): `ceLoadPersistedSeed()` / `cePersistLastSeed(uint64_t)`, declared
  in `Rogue.h` next to `setGraphicsMode`. The seed is stored as an `NSNumber` under
  `@"ce last game seed"` so the full `uint64_t` range round-trips losslessly (mirrors the existing
  graphics-mode persistence).
- **Load** (`RogueMain.c`, `rogueMain()`): `previousGameSeed = ceLoadPersistedSeed();` replaces the
  `= 0` reset, so the menu default is restored on entry.
- **Persist**: wherever the engine assigns `previousGameSeed`, we mirror it to disk — after the
  seed assignment in `initializeRogue` (`RogueMain.c`, guarded by `!playbackMode`) and after the
  recording-load assignment (`Recordings.c`). The persisted value thus always tracks the in-memory one.

### 2026-06-12 — Staff of frost: freeze, slow, ice bridges, frozen-foliage walls, and shoving (new content)

**What.** A new good staff, the **staff of frost** (`STAFF_FREEZE`, positive polarity, freq 8, value 1200,
inserted before `STAFF_HEALING` so it falls inside `NUMBER_GOOD_STAFF_KINDS`). It fires a new single-target,
enemy-targeting bolt (`BOLT_FREEZE` / `BE_FREEZE`, `BF_TARGET_ENEMIES | BF_NOT_LEARNABLE`,
`forbiddenMonsterFlags MONST_INANIMATE`, deals no direct damage). It stops at the first creature it hits —
rather than freezing a whole line — so a single frozen creature can be meaningfully shoved into the others:

- **Freeze → slow.** A struck creature is encased in ice via a new first-class status `STATUS_FROZEN`
  (added before `NUMBER_OF_STATUS_EFFECTS`; "Frozen", not negatable). Frozen gates actions exactly like
  `STATUS_PARALYZED` (every paralysis gate gained a `|| STATUS_FROZEN`: the player turn-loss loop and
  turn-counter and no-metabolism check in `Time.c`; the monster turn gate in `Time.c` and the per-monster
  turn-ender in `Monsters.c`; `attackHit` auto-hit, the helpless-defender backstab flag, and the
  shatter-on-hit clear in `Combat.c`; swarm eligibility and blocker-displacement in `Monsters.c`; stair-
  following in `RogueMain.c`; entrancement mirror-move in `Movement.c`). Freeze decrements via the
  `decrementMonsterStatus` default case / `decrementPlayerStatus`. Durations: new
  `staffFreezeDuration = max(2, 2 + enchant/2)` (hard lock, ~3–7 turns) and
  `staffFreezeSlowDuration = min(20, max(10, enchant·3))` (slow tail, capped under the slowness wand's 30),
  both in `PowerTables.c`. The slow tail is **layered underneath the freeze at cast time**
  (`STATUS_SLOWED = freeze + slow`) so it lingers after the ice breaks without remembering the enchant.
- **Fire beats freeze (both directions).** Casting on a `MONST_FIERY` or currently-burning creature only
  extinguishes + slows it (never freezes); catching fire later (`exposeCreatureToFire`, `Time.c`) instantly
  thaws a frozen creature; a blow shatters the freeze (`Combat.c`, leaving the slow tail).
- **Ice quenches terrain fire.** The ray also snuffs any `T_IS_FIRE` terrain it crosses (new
  `extinguishFireOnTile` in `Time.c` clears burning gas/surface layers to `NOTHING`; called per path cell in
  `updateBolt`), carving a firebreak. Brimstone/lava-fed fire may reignite next turn from its source — that one
  calm turn is intended.
- **Ice bridges over deep water.** The bolt's `pathDF` is the previously-dead `DF_DEEP_WATER_FREEZE`
  cascade, which now does something: deep water it crosses becomes the latent **`ICE_DEEP`** walkable floor
  (white "glossy ice", safe), melting edge-inward (negative `promoteChance`) back to water through the black
  "melting ice" warning tile. (Foundation-gated, so the pathDF is a no-op over floor/lava/chasm.)
- **Frozen foliage walls.** New terrain `FROZEN_FOLIAGE` / `FROZEN_FOLIAGE_MELT` (tiles + `DF_FROZEN_FOLIAGE`
  / `_MELTING` / `_THAW`), chained onto the end of the water-freeze cascade so the one ray also freezes dense
  foliage it crosses into a brittle, impassable barrier (`T_OBSTRUCTS_PASSABILITY | T_OBSTRUCTS_VISION`),
  melting edge-inward back to foliage; `T_IS_FLAMMABLE` + `fireType` = thaw, so fire melts it like lake ice.
- **Bump-to-push.** Walking into a frozen creature shoves it like a statue (`pushFrozenCreature`, `Combat.c`),
  intercepted in `playerMoves` (`Movement.c`) before the attack. The block slides across open floor a distance
  set by the shover's **effective strength** (`clamp(rogue.strength - weaknessAmount - 8, 2, 10)` — 4 tiles at
  the starting strength 12, up to the 10-tile cap by strength 18) and comes to rest **on** the first hazard it
  reaches — lava / a chasm / deep water (`T_LAVA_INSTA_DEATH | T_AUTO_DESCENT | T_IS_DEEP_WATER`), deposited
  there to die / fall a level / flounder via `applyInstantTileEffectsToCreature` — or **before** a wall, another
  creature, or the map edge. (The slide is walked manually rather than via a blind blinking-zap, which is what
  makes "shove the adjacent enemy into the lava" reliable: a raw blink skims over hazards since they aren't
  obstructions and only applies tile effects at the landing cell.) The block takes no damage; a creature it
  slams into takes **distance travelled + `max(0, strength - 12)`** damage (momentum plus a strength shove-bonus
  that bites even on an adjacent slam) and is doused if burning. A block wedged against an obstruction won't
  budge (no turn). Since the frost bolt deals no direct damage, this is the staff's strength-scaling payoff.
- **Colour state.** Persistent tints in `getCellAppearance` (`IO.c`): a strong icy cast while `STATUS_FROZEN`,
  a fainter chill while `STATUS_SLOWED` (the slow tint is **game-wide, any source**, not just this staff), plus
  the icy `flashMonster` at the moment of freezing. Ice terrain reads via its own tile colours.

**Gating.** Debug grant `D_FROST_STAFF_START` (`Rogue.h`, `WIZARD_MODE && 0`) starts you with a +10
identified staff in `initializeRogue` (`RogueMain.c`), added deterministically (recording-safe). Bolt rows
were appended to all three variant catalogs (`GlobalsBrogue.c` / `GlobalsRapidBrogue.c` /
`GlobalsBulletBrogue.c`); the staff/status/tile/DF tables are shared in `Globals.c`. `BOLT_FREEZE` is
appended (not inserted) since the staff→bolt link is the `power` field, not positional.

### 2026-06-12 — Gold goblin: a passive treasure-hoarder you chase down (new content)

> **Refactored 2026-06-13 into a reusable flee component (behavior unchanged).** The flee/escape AI no
> longer lives in bespoke `goldGoblin*` functions; it is now the generic, config-driven component
> `fleeProfile` (in `Rogue.h`, attached to a `creatureType`'s `fleeAI` field) + `fleeAITakesTurn` /
> `fleeStepToExit` / `monsterStepTowardAvoidingPlayer` / `monsterFleeDistanceMap` / `monsterKeepDistanceStep` /
> `fleerAtExit` / `fleerEscape` / `monsterTossFeatureBehind` / `fleerNoteDamage` (in `Monsters.c`), with
> per-instance state in `creature.fleer` (`fleerState`). `monstersTurn` dispatches on `monst->info.fleeAI`
> (one data-driven branch for *all* fleers, not a per-monster `if`). The gold goblin is the reference
> consumer: its config is `goldGoblinFleeProfile` (in `Globals.c`), and its loot/spawn stay gold-specific
> (`goldGoblinReactToDamage` now does only loot; `fleerNoteDamage` handles the flight trigger). See
> [docs/guides/reusable-components.md](../../docs/guides/reusable-components.md) and ADR 0001. The
> behavior below is unchanged; the old `goldGoblin*`/`GOLD_GOBLIN_*` symbol names in this entry now map to
> the generic ones (`goldGoblinFleeTurns`→`fleer.fleeTurns`, `GOLD_GOBLIN_PLAYER_BERTH`→`fleeProfile.playerBerth`,
> etc.). One cosmetic change: the toss message is now generic ("flings a flask to the ground and it erupts
> behind it") rather than naming the fungal forest.

**What.** A new monster, the **gold goblin** (`MK_GOLD_GOBLIN`), a passive "treasure goblin": it spawns
near the down stairs, never attacks, and — once struck — flees toward the up stairs in bursts, shedding a
trail of gold and dropping a hoard if you kill it before it escapes. Lifecycle:

- **Generation.** `spawnGoldGoblin()` runs once per level (first visit) from `initializeLevel()`. Eligible
  on depths **5–24**, **5%** per eligible level, **at most once per run** (`rogue.goldGoblinSpawned`).
  Placed on an open tile adjacent to `rogue.downLoc`. HP is depth-scaled at spawn (`35 + 6·depth`); the
  catalog HP (65) is only a fallback for non-hook spawns (e.g. wizard mode).
- **Stats.** Never attacks (`{0,0,0}` damage), moves at the player's pace like a monkey (`movementSpeed`
  100 -- since it now flees *continuously*, a faster speed would be flatly uncatchable), modest dodge
  (defense 25), no regen (`turnsBetweenRegen` 0), `MONST_NO_POLYMORPH`, random gender
  (`MONST_MALE | MONST_FEMALE`).
- **AI** (`goldGoblinTakesTurn`, dispatched from `monstersTurn` before the normal AI). Dormant and
  motionless until it shares line of sight with the player (`canDirectlySeeMonster`) or is attacked; from
  then on it runs **continuously**, like a fleeing monkey -- it never pauses within sight, so it can't be
  pinned against a wall and punched. While it can see the player it keeps a flee timer topped up
  (`goldGoblinFleeTurns = GOLD_GOBLIN_FLEE_MEMORY`, 10); after losing sight it runs on for that many turns
  ("a little further") then settles, resuming if spotted again. **Its flight has two phases, keyed off
  health.** While still **healthy** (`>= GOLD_GOBLIN_BREAK_FOR_STAIRS_PCT`, 50% HP) it does *not* run for
  the exit at all -- it merely keeps its distance, fleeing to the farthest-from-player cell via the
  engine's safety map (`goldGoblinKeepDistanceStep`), letting the player wear it down (and shedding its
  gold trail). It can't escape in this phase. Once **wounded** (below 50% HP) it switches to breaking for
  the up stairs (the pathing below) and only then can reaching them count as an escape. (This deliberately
  re-uses, as the healthy-phase behavior, the elusive farthest-cell flee that emerged by accident while the
  stair-pathing was broken -- a bug turned into a feature.) The wounded-phase step (`goldGoblinFleeStep`)
  heads for the **up stairs** (its only escape) along a single blended cost field (`goldGoblinStepToward` /
  `goldGoblinDistanceMap`: `dijkstraScan` over a hand-built cost grid + `nextStep`). That one map folds the
  goblin's two desires into one decision -- which suits an engine whose monster AI does one thing per turn,
  with no state machine: it routes toward the up stairs, but cells within `GOLD_GOBLIN_PLAYER_BERTH` (4) of
  the player carry a steep extra cost (`GOLD_GOBLIN_BERTH_COST` per tile, fading with distance) and the
  player's own tile is impassable. So the cheapest route to the exit naturally swings *wide around* the
  player rather than brushing past -- the goblin heads home while keeping its distance, the way a monkey
  does. Because the penalty is a smooth gradient (not a hard reachable/unreachable flag), the route shifts
  smoothly as the player moves instead of flickering, which is what removed the dithering; it also means the
  goblin keeps *moving* toward the exit (not parking in a corner to be shot) and never brute-forces past the
  player (which would make it a free target). **When the up stairs are blocked** (the up-stairs field
  returns no step -- the player's body in a doorway, a fire/gas wall, or a 1-wide pinch), it does NOT hold
  in the player's eyeline (that would mean free hits, and the block would never have to break). Instead it
  stays *elusive*: it reroutes toward the **down stairs** as a lower-priority target via the *same*
  keep-distance field, so it runs for open ground toward a real destination -- never a dead-end corner, the
  way a flee-from-player safety map would. The down stairs are only a place to run to, never an escape
  (only the up stairs are); this forces the player to abandon the block to give chase, at which point the
  up-stairs route reopens and it retargets the up stairs. A block commits it to the reroute for
  `GOLD_GOBLIN_FLEE_COMMIT` (3) turns (`goldGoblinFleeCommit`) so it doesn't visibly flip up/down each turn
  as the player jockeys on and off the route. Only if *both* stair routes are walled off from it at once
  does it fall to the engine's safety map (`getSafetyMap`) as a last resort. This is the result of a long
  tuning sequence -- earlier tries side-stepped toward a player-blocked route (melee-range bounce),
  flip-flopped back after one step, dithered up/down before the berth penalty existed, ran into dead ends
  via a raw safety map, or held still and ate free hits. (Inherent tension, by design: it
  spawns by the down stairs and the player enters from the up stairs, so the player is usually *between* the
  goblin and its only exit -- it reaches the up stairs mainly when a room or loop lets it swing around, and
  is otherwise run down or cornered. That cost/benefit -- maybe loot, maybe wasted turns chasing -- is the
  intended trade.) On the **first step of its wounded break for the stairs** (not while merely keeping
  distance, and never on the first point-blank hit, where it would screen nothing) it flings its one
  hallucinogen flask back onto the tile it just *vacated* -- blooming `DF_FUNGUS_FOREST` (a glowing forest
  that blocks line of sight) directly between itself and the pursuer, right where the player will step
  next. The vacated tile is always a valid bloom site (it's clear now, or holds the player). Once per
  goblin, only on a turn it actually moved. **Escape (up stairs only):** `monsterAvoids`
  makes *every* non-player creature avoid the actual stair tile, so the goblin can never stand on a
  staircase -- "reaching" the up stairs is detected as adjacency (`goldGoblinAtUpStairs`:
  `distanceBetween(loc, rogue.upLoc) <= 1`), checked both before and after the step so it escapes on
  arrival rather than bouncing off a tile it cannot enter. The down stairs are a reposition target only,
  never an exit. Escaping calls `goldGoblinEscapes` (administrative `killCreature`, forfeiting the undropped
  hoard); the closure message shows in sight, or off-screen only with a ring of awareness
  (`rogue.awarenessBonus > 0`).
- **On hit** (`goldGoblinReactToDamage`, from `inflictDamage`, passed the post-shield `damage`). Any damage
  (incl. fire/gas) commits it to fleeing and refreshes the flee timer. A *discrete* attack — `attacker !=
  NULL`, so not fire/gas/poison ticks, which pass `NULL` — sheds loot: the **first non-lethal blow that
  takes it below 25% HP** (`(currentHP - damage) * 4 < maxHP`) sheds a **potion of detect magic**
  (`POTION_DETECT_MAGIC2`) instead of gold — a one-time near-death bonus, gated by
  `goldGoblinDroppedDetectMagic` so healing and re-wounding it never repeats it; every other discrete hit
  sheds a gold pile (`rand_range(2·depth, 5·depth)`). (Lethal blows fall through to gold; the death hoard
  handles the rest.)
- **Death hoard** (`goldGoblinDropHoard`, from `killCreature` on non-administrative death only, and only for
  the genuine hoard-bearer): one curated marquee item + 2–4 gold piles (`5–10·depth` each) + one thrown-
  weapon stack (darts < depth 10, javelins ≥ 10), scattered nearby. Marquee pool (weights /100): Staff 20,
  Charm 16, Wand 11, Ring 11, Weapon 11, Armor 11 (honest unidentified rolls) | Detect-magic potion 10
  (`POTION_DETECT_MAGIC2`, the always-present good potion on this branch), Scroll of enchanting 6, Potion of
  life 2, Potion of strength 2 (guaranteed-good). Clones (`cloneMonster` clears `goldGoblinHasHoard`) and
  debug spawns drop nothing, so a staff of cloning can't duplicate the loot.

**Why.** Requested feature — a high-risk/reward chase encounter (Diablo's "treasure goblin"). Spawned via a
custom hook rather than the horde/machine tables so it can be pinned to the down stairs and metered to once
per run. The gold is net-new (a deliberate bonus); leaderboard impact is within existing seed noise (gold is
score, items are not — see design notes), and on shared/weekly seeds the encounter is fully deterministic, so
it's a pure skill test rather than a luck swing.

**Where.** `Rogue.h` — `MK_GOLD_GOBLIN` (appended last so kind indices don't shift); `creature` fields
`goldGoblinBurstTiles`/`goldGoblinTriggered`/`goldGoblinHasHoard`; `rogue.goldGoblinSpawned`; decls for
`goldGoblinReactToDamage`/`goldGoblinDropHoard`; debug flag `D_ALWAYS_SPAWN_GOLD_GOBLIN` (a standalone
toggle, *not* gated on wizard mode, so it works in a normal game) which forces a guaranteed spawn on
depth 2 (early, for fast testing) and, in `spawnGoldGoblin`, also flags that goblin
`MB_TELEPATHICALLY_REVEALED` so it can be tracked on the map (even out of sight) while debugging. `Globals.c` — `goldGoblinColor`, `monsterCatalog` and
`monsterText` entries (all appended last, parallel to the enum). `RogueMain.c` — reset
`rogue.goldGoblinSpawned` in `initializeRogue`. `Architect.c` — `spawnGoldGoblin()` + its call in
`initializeLevel`. `Monsters.c` — `goldGoblinEscapes`/`goldGoblinDistanceMap`/`goldGoblinStepToward`/`goldGoblinAtUpStairs`/`goldGoblinFleeStep`/`goldGoblinKeepDistanceStep`/`goldGoblinTakesTurn`/`goldGoblinReactToDamage`/
`goldGoblinShedGold`/`goldGoblinMarqueeItem`/`goldGoblinScatterItem`/`goldGoblinDropHoard`, the dispatch
branch in `monstersTurn`, and the loot-less-clone line in `cloneMonster`. `Combat.c` — the trigger hook in
`inflictDamage` and the hoard-drop hook in `killCreature`.

**Determinism / RNG.** All RNG (the `rand_percent(5)` spawn roll, placement, depth-scaled HP, per-hit and
death gold, marquee/thrown rolls) runs on the substantive gameplay RNG during seeded level generation and
normal turns, so it is fully replay-deterministic. The spawn roll draws one `rand_percent` per eligible
level even when it fails (consistent on replay). New `rogue`/`creature` fields don't affect the
recording-based save format (saves replay inputs; only determinism matters). Recordings made before this
change will desync, as with any generation change.

### 2026-06-12 — Ring of awareness senses room machines on arrival (new content)

**What.** On *first* arriving at a level, a character wearing a (non-cursed) ring of awareness may get a
quiet hunch that the level holds a **room machine** — a hand-built set-piece (reward vault, altar,
captive room, guardian puzzle, library, etc.), detected by scanning for any `IS_IN_ROOM_MACHINE` cell.
The message is existence-only: *"you sense that something of significance lies hidden on this level."* It
never reveals the location, nor whether it's reward or danger (a treasure vault and a sentinel ambush
read identically), so the discovery itself is preserved.

- **Positive-only & truthful.** It fires *only* when a room machine actually exists, so a hunch always
  means "something's here" and silence is ambiguous (nothing, or you didn't pick up on it). It never lies.
- **Scales with awareness, gated on the ring.** Chance = `AWARENESS_MACHINE_SENSE_BASE` (25) +
  `rogue.awarenessBonus` (`20 × enchant`), clamped to 100 → roughly +1 ≈ 45%, +2 ≈ 65%, +3 ≈ 85%, +4 →
  certain. A cursed (negative-bonus) ring senses nothing.
- **First arrival only.** Rolled in `startLevel()` inside the freshly-generated branch (Brogue restores
  visited levels from the `levels[]` cache, so "freshly generated" is a free "first time here" proxy).
  This closes the bounce-the-stairs-to-re-roll exploit a per-entry roll would open.

**Why.** Requested — a subtle reward for an awareness build, in the spirit of its existing
"notice what others miss." Acknowledged seam: sensing a vault *across the level* is closer to divination
than awareness's usual *immediate-surroundings* perception; accepted as heightened intuition. Detects any
room machine (not just `BP_REWARD` vaults) because the cell flag is free to query and the reward-or-danger
ambiguity is more interesting — and more "awareness" — than a loot radar.

**Where.** `RogueMain.c` — `AWARENESS_MACHINE_SENSE_BASE`, `levelContainsRoomMachine()`, and a block after
the `seedRandomGenerator(oldSeed)` re-seed in `startLevel()` (so the `rand_percent` draw is on the
gameplay RNG stream). `Globals.c` — awareness `ringTable` description gains a sentence.

**Determinism / RNG.** The `rand_percent` draw is gated behind *both* `awarenessBonus > 0` and a machine
existing, so a player without the ring (or on a machine-less level) draws **no** RNG here and sees exactly
vanilla behavior. For ring-wearers it perturbs the stream (their game already diverges), deterministically;
like any gameplay change it diverges replays from pre-change recordings. CE-only; base chance tunable.

### 2026-06-12 — Allies keep their distance from invulnerable monsters (cherry-pick: upstream PR #803)

**What.** Cherry-picked the two-part change from upstream BrogueCE **PR #803** (open/unmerged as of
2026-06): allies no longer charge to their deaths against invulnerable enemies (revenants, stone
guardians).
- `monsterFleesFrom()` restructured so the damage-immune-and-mobile avoidance triggers out to **6 tiles**
  (previously the `dist >= 4` early-out fired first, capping it at 4). The `dist >= 4` short-circuit now
  runs *after* the invulnerable check.
- `moveAlly()` blink-to-enemy target scan gains `!attackWouldBeFutile(monst, target)`, so an ally won't
  blink toward a target it can't actually hurt.

**Why.** Requested while reworking allies for the ring of light. Pairs naturally with that feature's
"keep your party alive" theme. Kept faithful to the upstream diff so it can be dropped cleanly if/when
the PR lands and the vendored engine is refreshed — both hunks are marked `// iOS port (iBrogue):
cherry-picked from upstream PR #803`.

**Interaction with the ring of light (same-day change below).** Emboldened allies still flee at the
vanilla low-HP threshold (so they self-preserve), but `moveAlly()` redirects that retreat into a rally
*behind the player* rather than to the generic safety map -- and `monsterFleesFrom()` (this change) still
runs for them, so they keep their distance from revenants/kamikaze/sacrifice targets. Net: an emboldened
ally retreats to heal in your light when hurt and avoids the unkillable enemies, instead of either
scattering or charging to its death.

**Where.** `Monsters.c` — `monsterFleesFrom()` and the second enemy scan in `moveAlly()`. CE-only.
Gameplay/behavior change, so it diverges replay from pre-change recordings (no new RNG draws).

### 2026-06-12 — Ring of light becomes an ally-build cornerstone (new content)

**What.** A worn **ring of light** now does far more than widen your view — its lit radius becomes a
buff aura *and* an invisible-creature detector. The vanilla item only scaled `rogue.lightMultiplier`
(light radius / fade), which is pure upside with no payoff — a "trap" pickup. The rework keeps that and
adds, keyed off a new `rogue.lightRingBonus` (net enchant of worn rings of light; negative if cursed):

- **Emboldened allies.** Any ally standing in the player's light (`IN_FIELD_OF_VIEW` and within
  `rogue.minersLight.lightRadius.lowerBound` tiles) gets the new `STATUS_EMBOLDENED` status, refreshed
  each vision update and lingering `EMBOLDEN_LINGER` (3) turns after leaving the light (so it fades
  rather than blinks at the dim edge). While emboldened:
  - **Defense** bonus, front-loaded and diminishing toward a ceiling (`EMBOLDEN_DEFENSE_CAP` × E/(E+1),
    cap 20 ≈ two `empowerMonster` levels) — applied in `monsterDefenseAdjusted()`.
  - **Accuracy** small flat `EMBOLDEN_ACCURACY_BONUS` (8) — applied in `monsterAccuracyAdjusted()`.
    **No damage bonus, deliberately** — damage compounds with `empowerMonster` leveling into an
    unbeatable squad; the buff is survivability + presence only.
  - **Courage / rally** — `moveAlly()` extends the attack leash to the light radius (an emboldened ally
    engages anything in your light). And when it *would* flee at low HP, it doesn't scatter to the generic
    safety map (which would lead it *out* of the light, abandoning the defense/regen keeping it alive);
    instead `allyRallyShieldCell()` sends it to a tile **behind you** -- shielded by your body, in the
    light, where it heals and waits to re-engage. It falls back to a normal flee if no sheltered tile is
    reachable. (Earlier drafts made emboldened allies simply *never* flee; that was rejected because our
    own regen is tuned not to out-heal combat damage, so "never retreat" would have gotten allies killed --
    the rally preserves self-preservation while keeping them in the buff aura.)
  - **Regeneration** — extra, capped `regenStep` in `decrementMonsterStatus()` (cap
    `EMBOLDEN_REGEN_PERCENT_CAP` 300%). Always-on but recovery-paced: tops off an ally between fights,
    never out-heals focused damage mid-fight (no combat-gating — the engine has no clean combat flag and
    no other regen source is gated).
- **Reveal invisibles.** `playerLightRevealsMonster()` grades by the light's own falloff: invisible
  *enemies* in the **bright core** (inner 60% of the radius) are fully exposed (treated as not hidden →
  translucent, targetable sprite via the existing renderer); in the **dim fade ring** they only flicker
  (`monsterRevealed()` → the existing `X`/`x` render); beyond the light, nothing. Scoped to
  `STATUS_INVISIBLE` enemies (not submerged/dormant, not the player). One-directional and *shared*: the
  player **and** the player's allies see the revealed enemy (allies drop their 33% hesitation in
  `moveAlly()`); an invisible *player* is never revealed to monsters. Because `monsterIsHidden()` also
  governs whip/spear targeting, this incidentally makes reach weapons hit a ring-revealed phantom
  correctly (the concern behind upstream PR #686 / issue #540).
- **Cursed ring (inversion-lite).** A negative `lightRingBonus` (the standard 16% ring curse) shrinks
  your light as before and now also *unsettles* nearby allies: they lose the defense/regen/courage
  (mild defense penalty, flee sooner). No HP drain — a bad roll shouldn't end an ally run.
- **Description + ID.** `ringTable` light description rewritten to state the ally/reveal effect and (for
  the first time, matching its siblings) a cursed clause. Equip-time ID is unchanged
  (`ringIdentifiesOnEquip` already covers light), so the player reads the full effect immediately.

**Why.** Requested — give ring of light a real reason to use without nerfing baseline allies (it
*amplifies* them past baseline rather than fixing them, the way ring of wisdom amplifies staffs) and
without trivializing phantoms globally (the counter is costed, radius-bound, and strictly weaker than
telepathy, which already hard-counters them). Front-loaded so a natural +1–+3 ring is worth wearing;
diminishing-toward-a-ceiling so over-enchanting can't build an invincible army.

**Where.** `Rogue.h` (`STATUS_EMBOLDENED`, `rogue.lightRingBonus`, prototypes);
`Globals.c` (`statusEffectCatalog` "Emboldened" + the previously-implicit AGGRAVATING/REGENERATING
entries; light `ringTable` description); `Items.c` (`updateRingBonuses` sets `lightRingBonus`);
`Monsters.c` (`emboldenmentCurve`/`emboldenmentDefenseBonus`/`emboldenmentAccuracyBonus`,
`playerLightRevealsMonster`, `updateAllyEmboldenment`, clauses in `monsterRevealed`/`monsterIsHidden`/
`allyFlees`/`moveAlly`, regen in `decrementMonsterStatus`); `Combat.c` (defense/accuracy chokepoints);
`Time.c` (`updateVision` drives `updateAllyEmboldenment` after lighting).

**Determinism / saves.** The added `rogue.lightRingBonus` field and `STATUS_EMBOLDENED` don't affect
save format (saves replay inputs). `updateAllyEmboldenment()` is idempotent and derived purely from
deterministic state (positions, light radius), so it reconstructs identically on replay; regen accel
happens once per turn in `decrementMonsterStatus`. Like any gameplay change it diverges replays from
pre-change recordings. CE-only; all magnitudes (`EMBOLDEN_*` defines in `Monsters.c`) are tunable.

**Playtest grants.** `D_LIGHT_RING_START` (`Rogue.h`, default 1) drops a +3 ring of light into the pack
in `initializeRogue()`, mirroring `D_FROST_STAFF_START`. Equip it to activate the aura/reveal.
`D_HEAL_CHARM_START` (default 1) likewise grants a strong +10 charm of health (near-full heal, short
cooldown) for sustaining an ally run during testing. `D_LEATHER_ARMOR_START` (default 1) grants a +50
leather armor (near-invulnerable, so you can test without dying); equip it to wear it. All are
deterministic (not recorded inputs), so they're replay-safe. Flip to 0 to ship.

### 2026-06-11 — Sense when a pursuer gives up the chase (new content)

**What.** When a monster loses the player's trail and reverts from hunting to wandering
(`MONSTER_TRACKING_SCENT -> MONSTER_WANDERING` in `updateMonsterState()`), the player gets a chance to
sense it: `"you sense that <the monster> has lost your trail."` **No line of sight is required** — it's
a pure awareness roll. The chance is `SENSE_LOST_TRAIL_BASE_CHANCE` (50) `+ rogue.awarenessBonus`,
clamped to `[0,100]`. The base is deliberately high so the typical character — who invests nothing in
awareness — still notices about half the time; a **ring of awareness** (`+20`/enchant) pushes it toward
certainty (`+1` → 70%, `+2` → 90%, `+3` → 100%), and a cursed ring suppresses it. Pairs with the
water/scent change: duck out of sight, cross water, and you'll usually learn the coast is clear.

**Why.** Requested — tie "did I shake it?" feedback to the player's awareness, with a low enough bar
that it's useful without an awareness build. Line-of-sight gating was dropped on request (so it also
confirms in text even when the monster is visible and its sidebar already reads `(Wandering)`). Rolled
only at the transition (not per turn), so it doesn't spam; it can re-fire only if the monster
re-acquires and loses the player again.

**Where.** `Monsters.c` — `SENSE_LOST_TRAIL_BASE_CHANCE` define + a block in the
`TRACKING_SCENT && !awareOfPlayer` branch of `updateMonsterState()`. Draws `rand_percent` **only** when
a monster actually loses the trail, keeping RNG-stream perturbation small; deterministic and
reproducible, but like any gameplay/RNG change it diverges replay from pre-change recordings. Minor
caveat: it can name a monster the player never actually saw (it was hunting by scent off-screen);
acceptable as "you sense" flavor, and hallucination still scrambles the name via `monsterName()`. CE-only.

### 2026-06-11 — Water washes away the player's scent trail (new content)

**What.** `updateScent()` now gates the player's per-turn scent emission on the terrain the player is
standing in (new `playerScentWaterPenalty()` helper in `Time.c`):
- **Deep water** (`T_IS_DEEP_WATER`, when not levitating) — emits **no scent at all** that turn, so the
  scent trail dead-ends at the water's edge. A pursuer that has lost line of sight reverts to wandering
  toward where it last saw the player (the near shore).
- **Shallow water** (`TM_ALLOWS_SUBMERGING && TM_EXTINGUISHES_FIRE`, i.e. any shallow-water variant but
  not deep water; mud/lava excluded since they lack `TM_EXTINGUISHES_FIRE`) — emits a **faint** trail:
  every deposit (the FOV spread and the player's own tile) takes a `SCENT_SHALLOW_WATER_PENALTY` (16,
  in `scentDistance` units ≈ 8 tiles) bump to its `distance`, lowering the stored scent value. The
  trail is followable but liable to be lost via the existing per-turn loss roll in `awareOfTarget()`.
- **Levitating** over either keeps the player dry, so scent is unaffected.

**Why.** Requested — let the player shake pursuers by crossing water, deeper = more reliable. Monsters
hunt by both scent and line of sight (`awarenessDistance()` takes the *min* of scent-on-own-tile and
direct distance when the player is in the monster's FOV), so this only sheds a tracker that **can't see
you** — break line of sight with terrain first, then break the scent with water. `SCENT_SHALLOW_WATER_PENALTY`
is a tunable `#define`.

**Where.** `Time.c` — new `playerScentWaterPenalty()` + `SCENT_SHALLOW_WATER_PENALTY` define, and the
deposit loop in `updateScent()` now adds the penalty / early-returns. No RNG drawn here; deterministic.
Like any gameplay change it diverges replay from pre-change recordings, but draws no new RNG itself.
CE-only.

**Limits / current behavior.** This does **not** guarantee a shed. A monster's awareness is the *min*
of scent-on-its-own-tile and (when the player is in its FOV) direct line-of-sight distance
(`awarenessDistance()`), and water blocks neither vision nor the scent you already laid. So a close
pursuer stays locked: it can see you across the open water, and/or it camps the still-fresh breadcrumb
at the water's edge. Shedding requires *both* breaking line of sight (terrain) *and* enough lead that
the freshest pre-water scent has aged past `stealthRange*2` (~10-turn lead at default stealth via the
+3/turn fade and the 3%/turn loss roll in `awareOfTarget()`; reliable nearer `stealthRange*6`).

**Possible follow-ups (not implemented — noted as options).**
- *Active scent decay while submerged:* have deep water also lower the stored `scentMap` value on the
  monster's tile / at the water's edge over time, so a nearby tracker's lock erodes instead of only
  the trail ceasing to extend. Would let a swim shed a closer pursuer.
- *Degrade the FOV-based lock in/over deep water:* treat a submerged player as harder to see (e.g.
  reduce the sight contribution to `awarenessDistance`), so crossing open water can break a sightline
  lock and not just the scent. Bigger change — touches the vision/awareness path, not just scent.

### 2026-06-11 — Catching fire confuses for 3 turns (new content)

**What.** Any creature (the player included) is confused for `FIRE_CONFUSION_DURATION` (3) turns the
moment it is *initially* set on fire. Applied inside `exposeCreatureToFire`'s `status[STATUS_BURNING]
== 0` branch, so it triggers once on ignition rather than every burning turn, and only for things that
actually catch (fire-immune / submerged / levitating-over-extinguishing-terrain creatures already
early-return before this point). Uses the same `status`/`maxStatus[STATUS_CONFUSED]` path as the
confusion weapon runic.

**Why.** Requested — catching fire should be disorienting; pairs with the panic of needing to reach
water. Note this also confuses the *player* on ignition (3 turns of randomized movement), which is a
real difficulty bump when you're trying to flee to water; tunable via the `#define`.

**Displayed as "Panic".** It's the ordinary `STATUS_CONFUSED` mechanic, but the sidebar status readout
relabels `STATUS_CONFUSED` to "Panic" while the creature is also burning (`IO.c`), since that window is
exactly the fire-induced confusion (confusion lasts 3 turns, burning up to 7). Confusion from other
sources keeps its normal "Confused" label.

**Where.** `Time.c` — `FIRE_CONFUSION_DURATION` define + one assignment in `exposeCreatureToFire`.
`IO.c` — a `STATUS_CONFUSED` special case in the sidebar status loop renders "Panic" when burning. No
RNG drawn; deterministic, no save/replay impact. CE-only.

### 2026-06-11 — Subtle progress bars behind inventory rows (new content)

**What.** Each inventory row can now show a faint progress bar tinted into the cells *behind* the
row text. Per category:
- **Weapon / armor / ring** — a **count-down** bar showing use/turns remaining before auto-ID
  (`charges` ÷ the `gameConst` threshold: `weaponKillsToAutoID` / `armorDelayToAutoID` /
  `ringDelayToAutoID`). Shown **only while equipped/worn and still unidentified**; it depletes as ID
  nears and is gone at ID (and for any identified item). Gradient runs dark→light, like the other bars.
- **Staff** — current **charge level**, always shown, including **partial recharge progress** toward
  the next charge (zap → wait → the bar visibly refills). Pre-ID it tracks **a single charge** as one
  continuous bar — full whenever at least one charge is ready (never revealing how many are stockpiled),
  otherwise the recharge progress toward the next charge. Once identified the bar is **split into
  `enchant1` equal segments** (one per charge, separated by 1-cell gaps via `barSegmentCells`): whole
  charges fill whole segments and partial recharge tops off the next, so a 2-charge staff reads 50/50,
  3-charge in thirds, etc. Partial recharge is derived from `enchant2` (counts down to 0 = next charge)
  over `staffChargeDuration()`. Gradient dark→light.
- **Charm** — **recharge progress** `(rechargeDelay − charges) ÷ rechargeDelay`, shown **only while on
  cooldown** (`charges > 0`); hidden when ready. Gradient dark→light.
- **Wands and everything else** — no bar.

Every bar spans the **full inventory row width** (`maxLength`, the width all rows are padded to), so a
"full" bar is the same physical length on every row and progress is directly comparable between items.

Colors: ID = `gray`, staff = `teal` (blue-cyan), charm = the item's own `foreColor` (charms have no
per-kind color in this engine, so this is the generic item glyph color). The gradient is **chunky** —
the bar-color strength steps up in fixed-width chunks (`INVENTORY_BAR_CHUNK_WIDTH`) rather than a smooth
per-cell fade, mimicking the menu/inventory button gradients — and it blends **toward the bar color, never
toward black** (`INVENTORY_BAR_TINT_MIN` floor), so the dim end is always a visible indication. Tints are
kept low (`INVENTORY_BAR_TINT_MIN`/`MAX`, 12/28) so the row text stays readable on top. The bar renders
**only in the button's normal draw state**, so the focus/press/drag highlight always takes precedence.

**Why.** Requested at-a-glance feedback on the otherwise-invisible auto-ID timers and staff/charm
charge state, without revealing information the player shouldn't have yet (staff max capacity).

**Where.** `Rogue.h` — two new `brogueButton` flags (`B_DRAW_PROGRESS_BAR`, `B_PROGRESS_BAR_FLIP`),
three new `brogueButton` fields (`barColor`, `barFillCells`, `barSegmentCells`), and the `INVENTORY_BAR_*`
tunables (chunk width, tint min/max). `Buttons.c` — `drawButton()` blends the chunky bar color into the
per-cell background for the leading `barFillCells` cells (skipping segment-boundary gaps), guarded to
`BUTTON_NORMAL`. `Items.c` — new static `setInventoryProgressBar()` computes the bar from item state and
is called per item row in `displayInventory()` after rows are padded to `maxLength` (so it appears in the
main inventory **and** every item-picker prompt, with a uniform full-width track). Purely cosmetic: reads
item state only, no RNG or game state, so no save/replay impact. CE-only; the Classic engine is unchanged.

### 2026-06-11 — Electrified water: lightning struck into water shocks the whole connected body (new content)

**What.** When an electric bolt (`BF_ELECTRIC` — both the staff's `BOLT_LIGHTNING` and the weaker
`BOLT_SPARK` used by turrets, ogre shamans, dar priestesses and pixies) directly strikes a creature
**standing in water**, the charge now floods the entire **connected body of water** and shocks
everything else standing in it. Any caster triggers it (player, monster, turret), and there is **no
friendly-fire exception** — the player wading in the same pool gets zapped by their own bolt.

**Rules.**
- *Trigger:* the bolt must directly hit a non-submerged, non-levitating creature on a water tile.
  A bolt that merely crosses empty water does nothing.
- *Body:* 8-connected flood-fill through connected **deep + shallow** water. Water is detected by
  `TM_ALLOWS_SUBMERGING && TM_EXTINGUISHES_FIRE` — the pair matches deep/shallow/sloshing/luminescent
  water but excludes bog, lava, cooling lava and the sacrificial pit (which share `TM_ALLOWS_SUBMERGING`).
- *Damage:* each shocked creature rolls its own `staffDamage()` (so it scales with staff enchant; spark
  stays weak), multiplied by a **geometric falloff** of `WATER_SHOCK_FALLOFF_PERCENT` (75%) per flood
  ring from the nearest strike point. The spread (and flash) stop at the ring where even a maximum roll
  rounds below 1 — radius scales with bolt strength, bounding huge lakes for free. The directly-struck
  creature takes only its normal direct hit (ring 0 is excluded from the shock); multiple strikes resolve
  as **one shock per body, nearest source wins** (no double-dipping).
- *Submerged creatures (eels) ARE shocked* — this deliberately overrides the usual rule that submerged
  monsters can't be bolt-targeted (`updateBolt`, `Items.c`), making lightning the hard counter to eels.
- *Stun:* anything the shock actually damages is paralyzed for `WATER_SHOCK_STUN_DURATION` (3) turns —
  the player included (set via `status`/`maxStatus[STATUS_PARALYZED]`, the same path as the paralysis
  weapon runic). The directly-struck bolt target (ring 0) takes the normal hit and is not stunned.
- *Levitation:* a creature hovering over water (`STATUS_LEVITATING` / `MONST_FLIES`) is not in contact —
  it neither triggers nor takes the shock. `MONST_INVULNERABLE` creatures are skipped.
- *Feedback:* a cosmetic shockwave flashes the conducting tiles ring-by-ring (dimming with distance) plus
  a one-time-per-bolt "the water crackles with electricity" combat message.

**Why.** Requested content addition — makes water a double-edged tactical element and gives lightning a
purpose against submerging eels.

**Where.** `Items.c` — new statics `isConductiveWater`, `creatureContactsWater`, `electrifyWater`
(multi-source BFS over a `short**` distance grid), the `WATER_SHOCK_*` `#define`s, and two hooks in
`zap()`: the bolt loop records in-water strike tiles (`electricStrikes`), and after the bolt fully
resolves it calls `electrifyWater()`. **Determinism:** damage is applied by iterating the monster list in
fixed order (then the player), so the per-creature RNG draws replay identically; the ring animation is
purely cosmetic and decoupled from damage. CE-only; the Classic engine is unchanged.

### 2026-06-11 — Debug death-recap: count polarity reveals earned by resting

**What.** The on-screen death recap's debug rest readout now shows, per level, `turns/IDs` (rested turns and
the number of polarity reveals resting produced) plus a `rest IDs total`. Verified both rest paths feed the
insight: single rest (`REST_KEY`, IO.c) and long rest (`autoRest`, Time.c) each set `rogue.justRested` and
call `playerTurnEnded`, which calls `gainPolarityInsightFromRest` — so neither path is missing the reveal.

**Why.** Diagnostic — make the passive rest-reveal observable.

**Reworked the threshold.** Replaced the old `90 + 30 × knownPolarityKindCount()` (which counted the
always-identified empty bottle and hidden themed-set potions as "known", skewing pacing) with a flat,
escalating schedule keyed off **reveals already earned this game**: reveal N needs `100 × N` consecutive
rested turns since the last reveal — intervals 100, 200, 300, 400… (cumulative 100, 300, 600, 1000…).
`knownPolarityKindCount` is removed entirely.

**Ring of wisdom.** A worn ring of wisdom makes the polarity machinery scale with its level
(`rogue.wisdomBonus`): the rest-insight threshold is reduced ~10% per level (cursed/negative wisdom slows
it; clamped to at most 80% faster / 2× slower, never below 1 rested turn), and the potion of detect magic
acts on `1 – (2 + ring level)` items instead of `1–2`. (A separate exploration-driven "XPXP" reveal
channel was considered and tabled.)

**Random target + escalation to full ID.** Both the rest check and the eat-a-meal scroll check now pick a
**random** eligible pack item via a shared helper (`applyPolarityInsightToRandomItem`), and the eligible
pool **includes items whose polarity is already known**: an unknown item gets its polarity revealed; an
already-sensed item gets **fully identified** (`identify()`). Rest considers all polarity categories but
**favors potions first** (restricts the pool to potions whenever any eligible potion is carried); eating
considers **scrolls only**. The rest-turn counter/threshold treat a full-ID the same as a reveal. The
random pick is action-triggered, so it replays deterministically.

**Where.** `Rogue.h` — `levelData.restRevealsOnLevel`. `Items.c` — `gainPolarityInsightFromRest` sums
`restRevealsOnLevel` for the escalating threshold and increments it on each reveal (`knownPolarityKindCount`
deleted). `RogueMain.c` — death-recap readout prints per-level `turns/IDs` and a total. Debug display + a
pacing change; no determinism impact (recomputed identically on replay, like the rest-turn tally).

### 2026-06-11 — Altars of transference: sacrifice an item to pour its enchantment into another (new content)

**What.** A new **random reward vault** (Brogue only), the dangerous sibling of the commutation altar. A linked
pair of altars: place the item you want to empower on the **recipient** altar (west↔east: donor west, recipient
east, one-tile gap — `#....s.o....#`, the same layout as the insight altars) and the item to sacrifice on the
**donor** altar. When both hold items, the donor's enchant level (`+N`) is **added** to the recipient
(*additive concentration* — net enchantment is conserved but pooled onto one item), then the donor is consumed
and both altars go inert.

Where commutation **swaps** two items you keep, this one **consumes one to power up another**. Rules:
- Eligibility matches commutation exactly (`CAN_BE_SWAPPED` = weapon/armor/staff/charm/ring; wands excluded);
  **cross-category is allowed** (feed a junk staff's `+3` into your plate armor).
- The **recipient must have a known enchant level**, else the altar stays primed — you always understand and can
  read the item you're improving.
- Sacrificing a donor with an **unknown** enchant is the gamble: it might be cursed (a negative donor *lowers*
  the recipient). The donor is `identify()`d as it's consumed, so the gamble resolves visibly.
- A donor whose enchant is **known and ≤ 0** is refused (pure-downside misclick guard) — only an *unknown* donor
  can ever hurt the recipient.
- Because the recipient normally only moves *up* and the donor vanishes, the usual `swapItemToEnchantLevel`
  shatter cases don't apply — **except** a deep negative gamble onto a staff/charm recipient, which is detected
  up front (predict-then-branch) so the now-unlinked item is never named after it shatters.

"Fire only if it helps" (except the deliberate unknown-donor gamble). RNG-free, so replays are unaffected.

**Where.** Modeled throughout on the altars-of-insight content (2026-06-10 entry):
- `Rogue.h`: `tileType` — `TRANSFER_ALTAR_DONOR` / `TRANSFER_ALTAR_RECIPIENT` / `TRANSFER_ALTAR_INERT`;
  `dungeonFeatureType` — `DF_ALTAR_TRANSFER_INERT`; `TM_TRANSFER_ENCHANT_ACTIVATION = Fl(27)`; `machineTypes` —
  a **genuine new index** `MT_TRANSFER_ALTAR` appended after `MT_REWARD_HEAVY_OR_RUNIC_WEAPON`. It exists only in
  Brogue's `blueprintCatalog` (which gains one entry, so `numberBlueprints` 73 → 74); the Bullet/Rapid catalogs
  stop at the variant weapon slot, so their reward raffle never reaches the index and it's never built there.
- `Globals.c`: `violetAltarBackColor`; three `tileCatalog` rows (model on `INSIGHT_ALTAR_*`); a
  `DF_ALTAR_TRANSFER_INERT` `dungeonFeatureCatalog` row (empty message — the result text is emitted once by the
  handler, not per promoted altar).
- `GlobalsBrogue.c`: the transference blueprint, appended last (depth 11–`AMULET_LEVEL`, freq 30, `BP_REWARD`).
  Like the insight blueprint it builds **only** the carpeted room; the altar pair is placed afterward.
- `Architect.c`: the insight placement helpers were **generalized** — `insightAltarCellIsOpen` →
  `altarPairCellIsOpen`, `setInsightAltar` → `setAltarTile`, `placeInsightAltarsInRoom(min)` →
  `placeAltarPairInRoom(min, westAltar, eastAltar, statueAbove)` (insight call site updated to pass its two
  tiles and `statueAbove = false`). The transference altar is **raffle-built**, so it can't be hooked from
  `addMachines` (which doesn't learn which blueprint the raffle picked); instead `buildAMachine` calls
  `placeAltarPairInRoom` on its success path when `bp == MT_TRANSFER_ALTAR` (Brogue-guarded), passing
  `machineNumber - 1` and `statueAbove = true`. The `statueAbove` flag drops a `STATUE_INERT` on the open
  carpet cell directly **north of each altar** (so the room reads `S . S` / `d . r`), making it
  unmistakable at a glance from the bare altar/gap/altar layout of the insight and commutation rooms; it's
  skipped per-altar if the north cell isn't open interior carpet.
- `Items.c`: `static boolean performEnchantTransfer(short)` (defined just after `performInsightSacrifice`,
  forward-declared beside it) + a sibling block in `updateFloorItems`, modeled on the commutation/insight blocks.

**Determinism / saves.** The handler and placement are RNG-free; the only RNG impact is that adding one
`BP_REWARD` blueprint to the raffle changes which reward room a given seed rolls at depth 11+ (a content change,
like adding the insight altars). No serialized-state change. **Bump `recordingVersionString` at release.**

### 2026-06-11 — Remove candidate-narrowing readout; render the empty bottle without "potion of"

**What.**
- Removed the "You have narrowed it down to one of N remaining…" inspect line for unidentified
  potions/scrolls (reverts the 2026-06-10 candidate-narrowing entry below). It added no value and read
  confusingly next to the themed potion sets. The silent last-kind auto-ID (`tryIdentifyLastItemKinds`)
  is left intact.
- The empty bottle now renders as just **"empty bottle" / "empty bottles"** instead of "potion of empty
  bottle".

**Why.** Player request — the narrowing readout wasn't fully thought through; and the empty bottle isn't a
"potion of" anything.

**Where.** `Items.c` — deleted `candidateKindCount` (and its forward prototype) and the render block in
`itemDetails`; special-cased `POTION_DETECT_MAGIC` in `itemName` to print "empty bottle%s" rather than
"potion%s of %s". Display only; no RNG, no determinism impact.

### 2026-06-11 — Themed potion sets + returning detect magic

**What.** Five new potions (enum grows 16 → 21, all frequency 10), in two mutually-exclusive themed
sets plus an always-present reworked detect magic:

- **Set 1** — **honey** (good): drinking grants `STATUS_REGENERATING`, metering ~20% of max HP over
  ~20 turns; thrown or bolt-hit it shatters into a `DF_NET` (`NETTING`) sticky patch that entangles.
  **vomit** (bad): thrown/bolt-hit → `DF_ROT_GAS_PUFF` nausea cloud; drunk → that cloud at your feet.
- **Set 2** — **wort** (good): drink/throw spawn `DF_LIFE_POTION_CLOUD` (healing cloud); this is also
  what the empty bottle's wort capture now yields (was potion of life). **venom** (bad): drink poisons
  the player (`addPoison(&player, ~15, 1)`); thrown it poisons the creature it strikes, else shatters
  harmlessly.
- **detect magic** (good, new kind `POTION_DETECT_MAGIC2` — the old slot is the empty bottle): drinking
  acts on 1–2 random unidentified polarity-bearing pack items — revealing each one's polarity, or fully
  identifying it if its polarity is already known (same reveal-or-escalate rule as resting/eating, via the
  shared `revealOrIdentifyPolarityItem` helper).

**One set per run.** `shuffleFlavors` draws `rogue.activePotionSet = rand_range(0,1)` (deterministic from
the seed, reproduced on replay). The inactive set's two potions are marked **absent this seed** (a static
`potionAbsentThisSeed[]` in Items.c): skipped by generation (`chooseKind`) and the Discoveries screen
(`IO.c`), and pre-identified so they cancel out of the good/bad polarity deduction. **Exception:** wort is
always producible by empty-bottle capture; `fillEmptyBottle` clears its absent flag when minted.

**Why.** Expands the potion pool and makes the lineup vary run to run, while bringing back detect magic in
a weaker RNG form. Decisions settled via design grilling. **iOS-only, all three variants.**

**Where.**
- `Rogue.h` — 5 new `POTION_*` kinds; `STATUS_REGENERATING`; `rogue.activePotionSet`; proto
  `potionKindAbsentThisSeed`.
- `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — 5 rows in each `potionTable_*`
  (colors `itemColors[17..20]` + `[0]`), 5 index-parallel `meteredItemsGenerationTable_*` entries, and
  `numberGoodPotionKinds` 8 → **11** (count only — good kinds are no longer contiguous).
- `Items.c` — `drinkPotion` (5 cases); `shatterPotionAtLoc` (honey/vomit/wort); `throwItem` venom-on-strike
  and a **polarity-based** good-potion gate (replaces the `kind < numberGoodPotionKinds` index boundary,
  which assumed contiguous good kinds); `magicCharDiscoverySuffix` (vomit/venom → bad); `quaffDetectMagic`;
  `emptyBottleCaptureKindForTile` (`HEALING_CLOUD` → `POTION_WORT`); `shuffleFlavors` set selection;
  `chooseKind` + `fillEmptyBottle` honor `potionAbsentThisSeed`.
- `Time.c` — `STATUS_REGENERATING` per-turn heal (stateless elapsed-fraction metering) + expiry.
- `IO.c` — `printDiscoveries` skips absent potion kinds (separate display-row counter, no gap).

**Determinism.** `shuffleFlavors` now draws an extra `rand_range` (set selection), `quaffDetectMagic` and
venom throws draw, and there are new potion kinds — so item-generation/ID RNG diverges from old recordings.
**Bump `recordingVersionString` at release.** Set selection and absence are recomputed deterministically
from the seed each load; no new serialized state (`rogue.activePotionSet` is derived, not saved).

### 2026-06-11 — Insight altars: place the pair side by side in a fixed s . o layout

**What.** The two altars-of-insight no longer land at random spots in the reward room. They are placed in
a consistent arrangement: the **sacrifice/payment** altar to the west, a one-tile walkable gap, then the
**insight** (offered-item) altar to the east — `#....s.o....#`. The room is also smaller now.

**Why.** The pair read as inconsistent and scattered, making the mechanic hard to parse. A fixed,
adjacent s→o layout makes the room instantly legible. The smaller room also fits into level generation
more easily.

**Where.**
- `GlobalsBrogue.c` — the insight blueprint (`blueprintCatalog_Brogue`, the `MT_INSIGHT_ALTAR` slot) now
  builds **only** the carpeted room: the two altar `machineFeature` rows were removed (featureCount 5 → 3)
  and `roomSize` shrank from `{7, 30}` to `{7, 14}`.
- `Architect.c` — a `placeAltarPairInRoom(min, westAltar, eastAltar)` (with helpers `altarPairCellIsOpen` /
  `setAltarTile`) places the pair after the room is built, called from the `addMachines` force-build
  right after `buildAMachine(MT_INSIGHT_ALTAR, …)` succeeds with `INSIGHT_ALTAR_PAYMENT` (west) +
  `INSIGHT_ALTAR_INSIGHT` (east). (Originally named `placeInsightAltarsInRoom` / `insightAltarCellIsOpen` /
  `setInsightAltar`; generalized 2026-06-11 to be shared with the altars of transference.) It finds the just-built room's carpet cells
  (machineNumber greater than the value captured before the build), picks the horizontal run of three open
  cells nearest the room center, and drops `INSIGHT_ALTAR_PAYMENT` (west) + `INSIGHT_ALTAR_INSIGHT` (east,
  one gap). Fallbacks: an adjacent pair, then any two open cells, so the altars always exist.

**Determinism.** The placement helper uses **no RNG** (a deterministic scan), so it doesn't perturb the
seed stream. But removing the two altar features and shrinking `roomSize` changes what `buildAMachine`
draws, so generation diverges from pre-change recordings — a `recordingVersionString` bump at release is
warranted (the diff doesn't bump it). **Brogue variant only / iOS-only — not contributed to a fork branch.**

### 2026-06-11 — Replace potion of detect magic with the Empty Bottle

**What.** The `POTION_DETECT_MAGIC` slot is repurposed into an always-identified **empty bottle** that
captures dungeon elements and becomes the matching potion (already known, which also identifies any
matching unidentified potions in the pack):

- **Apply capture** (gases / deep water): *applying* (drinking) the empty bottle while standing on a
  catchable gas or deep water transforms it into the mapped potion — caustic→caustic gas,
  confusion→confusion, paralysis→paralysis, rot→creeping death, darkness cloud→darkness, healing
  spores→life, deep water→fire immunity. A turn passes and the bottle becomes that potion (not consumed).
  With nothing catchable underfoot it stays a benign empty bottle and no turn is spent. (Capture is on
  apply, by player choice — never automatic.)
- **Bolt capture** (drop the bottle, zap it): a lightning bolt → speed, a fire bolt → incineration. This
  reuses the existing bolt-through-potion hook in `updateBolt` and absorbs the bolt exactly as a detonating
  bad potion does.

**Why.** Design/testing request: detect magic was a weak, passive pick. The empty bottle keeps its
identification role but makes it active — you learn a potion type by harvesting a hazard. The enum
`POTION_DETECT_MAGIC` is kept as the internal kind (a rename would be high-churn); it is relabeled
"empty bottle" in the item tables. **iOS-only, all three variants** (Brogue/Rapid/Bullet).

**Where.**
- `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — the `"detect magic"` row becomes
  `"empty bottle"` with a new description; Brogue's `frequency` is restored **10 → 20** (Rapid/Bullet were
  already 20).
- `Items.c` `shuffleFlavors` — force `potionTable[POTION_DETECT_MAGIC].identified` (and
  `magicPolarityRevealed`) true each game so the bottle is always known and never joins the ID pool.
- `Items.c` new `fillEmptyBottle()` (near `shatterPotionAtLoc`) — shared transform→message→`autoIdentify`
  helper; prototype in `Rogue.h`. New static `emptyBottleCaptureKindForTile()` maps the gas/liquid on a
  tile to the captured potion kind + flavor.
- `Items.c` `updateBolt` — empty-bottle branch *before* `shatterPotionAtLoc`, keyed on `BF_ELECTRIC`/`BF_FIERY`,
  sets `terminateBolt = true`.
- `Items.c` `drinkPotion` — the `POTION_DETECT_MAGIC` case is the **apply capture**: if the player's tile
  holds a catchable element it records the apply command, calls `fillEmptyBottle`, then re-adds the item
  via `removeItemFromChain` + `addItemToPack` so the new potion **stacks** into an existing same-kind stack
  instead of taking a bespoke inventory slot, and returns `true` (a turn passes, bottle not consumed);
  otherwise it prints "the bottle is empty…" and returns `false` (benign, no turn). The bolt-capture path
  leaves its bottle on the floor, where normal pickup already stacks it. Replaces the old detect-magic quaff
  effect.

**Determinism.** Generation behavior changes (frequency, and the kind is now always-identified), so the
weighted pick / ID bookkeeping diverge from pre-change recordings — a `recordingVersionString` bump at
release is warranted. Capture mutates only existing item/level state (no new RNG call sites). Removing
detect magic from the unidentified-potion pool slightly shifts the `tryIdentifyLastItemKinds` deduction
counts (one fewer good potion to deduce) — intended.

### 2026-06-11 — Sharpen monkey theft preference (tunes PR #849)

**What.** Strengthened the monkey's deductive-theft bias from the PR #849 entry above: the favored-item
bonus in `rateItemStealDesirability` goes **+50 → +290** (food and potions of life/strength), and the
uniform-pick hedge in `specialHit` drops **10% → 5%**.

**Why.** At +50 (a 6:1 weight) a single favored item still lost to the summed base weight of a full pack,
so monkeys rarely visibly favored food/life/strength in play. +290 (~30:1) makes food the steal ~70%+ of
the time when carried, matching the monkey's flavor text. Note this can't change how often life/strength
are taken — those are simply seldom in the pack. The lower hedge also slightly sharpens **imp** theft,
consistent with the deductive-thievery intent.

**Where.** `Combat.c` — `rateItemStealDesirability` (monkey branch) and the `rand_percent` hedge in
`specialHit`. Pure value tweak; same determinism characterisation as the PR #849 entry below.

### 2026-06-10 — Halve the detect-magic potion's generation frequency (Brogue)

**What.** The potion of detect magic now appears about half as often: its `frequency` in
`potionTable_Brogue` drops from **20 to 10**.

**Why.** Tuning request — detect magic was showing up too readily, undercutting the deliberate,
costed identification the potion-ID rework is built around.

**Where.** `GlobalsBrogue.c` — the `"detect magic"` row of `potionTable_Brogue`. In the Brogue variant
detect magic is **not metered and not guaranteed** (its `meteredItemsGenerationTable_Brogue` entry is bare
defaults with `incrementFrequency == 0`, so the metered system never overrides its frequency — Items.c:683
— and it has no `levelGuarantee`). Its appearance is therefore driven purely by this static `frequency`,
which feeds the weighted pick in `chooseKind` (Items.c:417-421). Halving it halves detect magic's share of
potion generation. **Brogue variant only / iOS-only — not contributed to a fork branch.** (Rapid and Bullet
guarantee detect magic via `levelGuarantee`, so frequency matters far less there; left untouched.)

**Determinism.** This changes item generation, so the weighted pick consumes RNG differently and pre-change
recordings diverge on replay — a per-variant `recordingVersionString` bump at release is warranted (the diff
does not bump it). No new state or RNG call sites; it's a table-value change.

### 2026-06-10 — Benevolent potions glow harmlessly when a bolt crosses them

**What.** A fire or lightning bolt that crosses a dropped **benevolent** potion (the eight good kinds —
life, strength, telepathy, levitation, detect magic, haste self, fire immunity, invisibility) now prints
"the bolt passes through the flask and its fluid glows warmly." instead of doing nothing visible. The flask
is **not** destroyed and the bolt **continues** (it does not halt, unlike a bad potion, which detonates and
absorbs the bolt).

**Why.** Player request — a bolt over a good potion used to be a silent no-op, which read as a bug. The
benevolent potions are exactly the kinds `shatterPotionAtLoc` returns `false` for (they have no shatter
signature), so they were inert to bolts. The glow gives that inertness visible feedback.

**Where.** `Items.c` — the bolt-detonation hook in `updateBolt`. The `if (… shatterPotionAtLoc(…))` was
split into an `if/else`: the detonate-and-halt branch is unchanged; a new `else if (playerCanSee(x, y))`
branch prints the glow message for the inert (good) potions. Gated on visibility so an off-screen monster
bolt crossing a dropped potion doesn't print a phantom message. No item teardown, no `terminateBolt`, no
identify — purely a message.

**Determinism / balance.** No RNG and no serialized state (a deterministic `message()` keyed on game state).
Because bad potions detonate-and-halt while good ones glow-and-pass, a zap becomes a *costed polarity probe*:
one charge reveals (by observation) the leading run of benevolent potions up to the first bad one, which
detonates dangerously and is consumed. Bounded and expensive, not the old free mass-ID. Recorded in
`KNOWN_CAVEATS.md`. Backport note in `docs/fork-backport-tweaks.md` (branch `potion-bolt-detonation`).

### 2026-06-10 — Potion-ID tuning: faster first rest-reveal, and detonating potions absorb the bolt

**What.** Two small balance tweaks to features added earlier in this branch:

1. **Rest-based polarity insight now fires sooner.** The first reveal lands after **90** rested turns
   instead of 120 (`POLARITY_INSIGHT_BASE_TURNS`); the per-known-kind ramp (`+30` turns each) is unchanged,
   so it still gets harder as the player learns more polarities.
2. **A detonating dropped potion now absorbs the bolt.** When a fire or lightning bolt detonates a dropped
   bad/cloud potion (the Phase 3 / PR #842 hook), the bolt **halts at that tile** rather than continuing
   down its path. Each bolt can therefore detonate at most one potion.

**Why.** (1) Player tuning request — 120 felt too slow for the first hint. (2) Closes an exploit: a player
could drop every unidentified potion in a straight line and clear/identify the whole row with a single
lightning (or fire) staff charge, since lightning pierces everything via `BF_PASSES_THRU_CREATURES`. Making
the shattering flask "absorb" the bolt caps each charge at one detonation, so mass-detonation costs one
charge per potion — the intended price. Thematically, the violent explosion disrupts the arc.

**Where.** `Items.c` only.
- Tweak 1: the `POLARITY_INSIGHT_BASE_TURNS` macro (above `gainPolarityInsightFromRest`).
- Tweak 2: the bolt-detonation hook in `updateBolt` — inside the `if (… shatterPotionAtLoc(…))` block, a
  `terminateBolt = true;` after the existing item teardown. It is set *before* the function's trailing
  `exposeTileToFire` / `exposeTileToElectricity` calls, which still run for this tile, so a fire bolt
  ignites the freshly-spawned flammable terrain (gas cloud / fungal forest) before the bolt stops; only
  then does the caller's `if (updateBolt(...)) break;` halt the bolt. `shatterPotionAtLoc` returns `true`
  only for the eight bad/cloud potions, so good potions (which fall through `default: return false`) never
  halt a bolt.

**Determinism.** No new RNG and no serialized state. The bolt simply traverses fewer cells once it
detonates a potion; like the Phase 3 / #842 detonation it diverges only as a direct consequence of the
player's action (zapping a location that holds a dropped bad potion), so it replays identically. Saves are
recordings. See `KNOWN_CAVEATS.md` for the accepted side effect (a dropped bad potion can now shield a
monster directly behind it from that bolt). Both tweaks are tuning refinements of existing fork-branch
features and should be backported to those branches — see `docs/fork-backport-tweaks.md`.

### 2026-06-10 — Deductive thievery: monkeys and imps steal by preference (upstream PR #849)

**What.** Thieving monsters no longer steal a uniformly random item. 90% of the time they pick by a
weighted desirability score, 10% of the time they fall back to the old uniform pick. **Monkeys** favor
food and potions of life/strength; **imps** favor scrolls of enchanting, positively-enchanted gear, and
runics (and shy away from food). Because the thief "knows" an item's true nature, what it grabs is a hint
toward that item's identity (e.g., a monkey snatching an unidentified potion suggests life or strength).

**Why.** Ports [BrogueCE PR #849](https://github.com/tmewett/BrogueCE/pull/849) ("Deductive Thievery"),
which fits the broader potion-ID theme by turning theft into an identification signal. **iOS-only — not
contributed to a fork branch** (PR #849 is itself the upstream contribution).

**Where.** `Combat.c` — a new `static short rateItemStealDesirability(creature *thief, item *theItem)`
defined just above `specialHit`, and the theft item-selection in `specialHit` (the `MA_HIT_STEAL_FLEE`
block) replaced with the 10%-uniform / 90%-weighted-roulette scheme. `Globals.c` — monkey and imp monster
descriptions reworded to hint at their new preferences. (`choiceRoll` is declared `long` to match
`rand_range`'s return type and avoid an Xcode 64→32 narrowing warning; the upstream PR used `int`.)

**Determinism.** No new common-path RNG and no serialized state. The theft draw changes (an extra
`rand_percent(10)`, and the weighted `rand_range` over scores instead of a flat `rand_range` over
candidates), but theft is an action-triggered combat event — it diverges the RNG stream only when a
monkey/imp actually steals, not on every turn — so it's a self-consistent action-triggered divergence,
like the thrown-potion and bolt-detonation changes.

### 2026-06-10 — Thrown hallucination potions bloom a fungal forest, and bolts detonate them (upstream PR #842 + bolt extension)

**What.** A thrown potion of hallucination now spawns a **luminescent fungal forest** at the impact tile
(the existing `FUNGUS_FOREST` terrain: flammable, a light source, and a line-of-sight blocker) instead of
splashing harmlessly. Additionally, fire and lightning bolts now detonate a **dropped** hallucination
potion the same way Phase 3 detonates the bad/cloud potions: a lightning bolt simply blooms the forest,
while a fire bolt blooms it and then **ignites** it.

**Why.** Ports [BrogueCE PR #842](https://github.com/tmewett/BrogueCE/pull/842) ("Give hallucination potions
a use"), which reframes hallucination as a "magic-mushroom" potion. The bolt extension was requested to keep
it consistent with the Phase 3 bolt-detonation mechanic now that thrown hallucination has a real effect.
**iOS-only — not contributed to a fork branch.** (Note: this changes the Phase 3 potion×bolt matrix —
hallucination, previously inert to bolts, now reacts: fire ignites the forest, lightning just spawns it.)

**Where.** `Items.c` — a `case POTION_HALLUCINATION` added to `shatterPotionAtLoc` (spawns
`DF_FUNGUS_FOREST`). Because that helper is shared by both `throwItem` and the bolt-detonation hook in
`updateBolt`, this single case covers the throw effect (PR #842) and the bolt-detonation; the fire-vs-
lightning behavior falls out of the existing ordering (the detonation runs immediately before the bolt's
`exposeTileToFire`, so a fire bolt ignites the freshly-spawned flammable forest). The now-dead
harmless-splash branch for hallucination in `throwItem` was removed. `GlobalsBrogue.c` /
`GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — the hallucination potion description now mentions the
thrown fungal-forest effect.

**Determinism.** No new RNG and no serialized state; reuses existing terrain/DF (`FUNGUS_FOREST` /
`DF_FUNGUS_FOREST`). Like the rest of Phase 3, throwing or bolt-detonating a hallucination potion is an
action-triggered divergence (the spawned forest and any fire it draws), acceptable and self-consistent on
replay; nothing changes on the common path.

### 2026-06-10 — Auto-identify a worn ring deducible by elimination (upstream issue #683)

**What.** When a ring is equipped and reveals no obvious effect, and it is the only still-unidentified ring
kind that stays hidden on equip, its kind is now deduced and identified. (Only clairvoyance, light, and
stealth reveal themselves on equip; the other five — regeneration, transference, awareness, wisdom, reaping
— stay hidden, so once four of those five are known, equipping the fifth identifies it.)

**Why.** Implements [BrogueCE issue #683](https://github.com/tmewett/BrogueCE/issues/683) ("Auto-ID ring
kind based on whether all remaining rings ID on equip"), a flagged good-first-issue: the deduction is one a
player can already make by hand, so the game does the bookkeeping.

**Where.** `Items.c` — two small static helpers above `equipItem` (`ringIdentifiesOnEquip(short)` factors out
the clairvoyance/light/stealth set; `unidentifiedRingKindsHiddenOnEquip(void)` counts the unidentified hidden
kinds), and the ring branch of `equipItem` now uses the helper for the existing self-ID path and adds the
elimination deduction. Reuses `identifyItemKind`, `ringTable`. All vanilla symbols.

**Determinism.** Pure identification bookkeeping — no RNG, no serialized state. ID state isn't part of the
recording stream, so seeds and replays are unaffected.

### 2026-06-10 — Altars of insight: sacrifice one item to reveal another (new content)

> **Updated 2026-06-11** (see the rest-insight entry above): paying with an *identified* item now reveals
> the insight item's polarity, or — if its good/bad polarity is already known — **escalates to a full
> identification** (via the shared `revealOrIdentifyPolarityItem` helper). The "fire only if it helps"
> guard now refuses only when the insight item is fully identified or already revealed as having no
> good/bad polarity.

**What.** A new guaranteed reward room — a pair of linked altars (an "altar of insight" + an "altar of
offering") that appears once every 10 levels starting at depth 5 (depths 5, 15, 25), Brogue variant only.
Place the item you want to learn about on the insight altar and a payment item on the offering altar; when
both hold items the offering is consumed and the other item is revealed. The reveal scales with the
payment: **sacrificing an unidentified item fully identifies** the offered item, while sacrificing an
**identified item only reveals its polarity/aura** (via `detectMagicOnItem`). Both altars then go inert. It
"fires only if it helps" — never consumes the payment unless the offered item would actually gain info, so
a `+0` mundane weapon reveals as "no aura" rather than wasting the sacrifice, and an already-known item
does nothing.

**Why.** The deferred Phase 7 of the potion-ID arc, redesigned as a costed trade (give up an item to learn
one) rather than the original free whole-pack polarity reveal, which was effectively on-demand detect
magic. The risk dial (gamble an unknown for a full ID, or pay a known item for just polarity) keeps
identification a gamble while easing it.

**Where.**
- `Rogue.h`: `tileType` — `INSIGHT_ALTAR_INSIGHT` / `INSIGHT_ALTAR_PAYMENT` / `INSIGHT_ALTAR_INERT`;
  `dungeonFeatureType` — `DF_ALTAR_INSIGHT_INERT`; `TM_INSIGHT_ACTIVATION = Fl(26)`; `machineTypes` —
  `MT_INSIGHT_ALTAR` aliased to `MT_REWARD_HEAVY_OR_RUNIC_WEAPON` (Brogue fills the variant-specific reward
  slot, index 72, that BulletBrogue uses for its weapon vault — they never collide, being per-variant + variant-gated).
- `Globals.c`: `blueAltarBackColor`; three `tileCatalog` rows (model on `COMMUTATION_ALTAR`); a
  `DF_ALTAR_INSIGHT_INERT` `dungeonFeatureCatalog` row (empty message — the reveal text is emitted once by
  the handler, not per promoted altar).
- `Items.c`: `static boolean performInsightSacrifice(short)` (defined near `detectMagicOnItem`, forward-declared
  above `updateFloorItems`) + a sibling block in `updateFloorItems`, modeled exactly on the commutation-altar
  block (`TM_*` flag + machineNumber + `nextItem`-skip + `activateMachine`). Reuses `identify`,
  `detectMagicOnItem`, `tryIdentifyLastItemKinds`, `itemMagicPolarity`, `itemName`, `messageWithColor`,
  `removeItemFromChain`, `deleteItem`. All vanilla.
- `GlobalsBrogue.c`: the blueprint appended at index 72 (force-only — no `BP_REWARD`, frequency 0).
- `Architect.c`: a Brogue-gated, depth-gated force-build in `addMachines` (modeled on the amulet vault and
  BulletBrogue's L1 weapon vault).

**Determinism.** The reveal handler is RNG-free (flag/table flips + a deterministic machine scan); saves are
recordings (no serialized format change). Because the altar is force-only (not in the BP_REWARD raffle), the
random reward-room raffle is byte-unchanged at every depth — the only seed divergence is on the forced
levels (5, 15, 25, Brogue only), where placing the room draws RNG. As new dungeon content it warrants a
per-variant `recordingVersionString` bump at release (left to maintainers; not bumped here). Rapid/Bullet
untouched.

### 2026-06-10 — Eating studies a scroll: reveal one scroll's polarity on a safe meal

> **Updated 2026-06-11** (see the rest-insight entry above): the scroll is now chosen **at random** (not
> top-of-pack), the eligible pool **includes scrolls whose polarity is already known**, and acting on such
> a scroll **fully identifies** it instead of only revealing polarity. Reuses the shared
> `applyPolarityInsightToRandomItem(SCROLL, …)` helper. The selection now consumes RNG (action-triggered,
> replay-safe) — no longer "no RNG" as originally described below.

**What.** Eating a meal (`eat` returning true) while **nothing is hunting you** reveals the polarity
(benevolent/malevolent) of the first still-unknown scroll in your pack, with a colored message
("you study a scroll intently while eating; it radiates a … aura."). Polarity only, never a full ID. One
scroll per safe meal; if something is hunting you (any creature in the `MONSTER_TRACKING_SCENT` /
"(Hunting)" state) or you hold no unknown scroll, the meal proceeds normally with no reveal.

**Why.** Companion to the rest-insight feature: a calm moment to study a scroll while you eat. Meals are
scarce and the reward is safety-gated, so it eases scroll identification without removing the gamble.

**Where.** `Items.c` — a new `void gainScrollInsightFromEating(void)` defined just after
`gainPolarityInsightFromRest` (iterates `monsters` for the Hunting gate, then the pack for the first
unknown-polarity scroll; reuses `detectMagicOnItem` + `tryIdentifyLastItemKinds(SCROLL)` + `itemMagicPolarity`
+ `itemMagicPolarityIsKnown`), called from `eat()` just before its `return true`. Prototype in `Rogue.h`.
All vanilla symbols.

**Flavor (added 2026-06-10).** Both `foodTable` descriptions in `Globals.c` (the shared catalog — the
feature is not variant-gated, so the hint is accurate in every variant) now hint at this: the ration of
food notes that "a meal taken in peace, with nothing on the hunt for you, settles the mind enough to study
an unidentified scroll…", and the mango that eating "undisturbed" affords "a quiet moment to divine the
nature of an unknown scroll." Description-only; no logic change. Backport with the feature — see
`docs/fork-backport-tweaks.md` (branch `eat-scroll-insight`).

**Determinism.** `eat()` is one command per keystroke (no `autoRest`-style per-turn re-recording), the
reveal is RNG-free, and there's no new stored state — so it's reconstructed identically on replay (saves
are recordings). Like the rest feature it's a deterministic gameplay-rule change, so pre-feature recordings
diverge on replay; a per-variant `recordingVersionString` bump is warranted at release (not in the diff).

### 2026-06-10 — Passive polarity insight while resting (+ debug rest-count readout)

**What.** Resting slowly reveals item polarity. Each rested turn accrues toward a threshold; on reaching
it, the first still-unknown (good/bad) item in the pack has its benevolent/malevolent polarity revealed
(same effect as detect-magic on one item), with a colored "while resting, you sense the … aura of …"
message, and any in-progress auto-rest is interrupted so the player notices. The threshold grows with the
number of polarity kinds already known (`BASE = 120`, `STEP = 30` rested turns per known kind), so it
eases the early-game ID burden but tapers off late so it can't trivialize identification. Separately, an
**iOS-only debug readout** appends `[rests/lvl: 1:12 3:40 …]` (rested turns per depth) to the on-screen
death/quit recap.

**Why.** Requested feature: ease the chore of identifying healing/strength items without removing the
gamble. Polarity-only (never a full ID) and self-tapering keeps it in line with the arc's anti-triviality
goal (the concern that shelved Phase 5). The debug readout exists to tune `BASE`/`STEP` from real runs.

**Where.**
- *Feature (also ported upstream):* `Rogue.h` — `playerCharacter.restTurnsSinceInsight` field + a
  `void gainPolarityInsightFromRest(void)` prototype. `Items.c` — `static int knownPolarityKindCount(void)`
  and `gainPolarityInsightFromRest()` defined just after `detectMagicOnItem` (reuses `detectMagicOnItem`,
  `tryIdentifyLastItemKinds`, `itemMagicPolarityIsKnown`, `itemMagicPolarity`, `itemKindCount`,
  `tableForItemCategory`, `itemName`, `messageWithColor` — all vanilla). `Time.c` — a call in
  `playerTurnEnded`, gated on `rogue.justRested`, just before the `justRested` reset.
- *iOS-only debug:* `Rogue.h` — `levelData.restTurnsOnLevel` field; `Time.c` — increment in the same
  `justRested` block; `RogueMain.c` — the `[rests/lvl: …]` append in `gameOver`, after
  `theEntry.description` is copied (so the saved high-score text is untouched), length-guarded to `buf[200]`.

**Determinism.** Brogue "saves" are recordings (state is rebuilt by replay), so the new fields add no
serialized format to break. Counting is done in `playerTurnEnded` rather than at the command dispatch on
purpose: `autoRest` re-records each rested turn as `REST_KEY`, so one `Z` replays as N rests — the
turn-resolution chokepoint is the only place that tallies identically live and on replay. The reveal is
pure flag-flipping (no RNG). It is, however, a deterministic *gameplay-rule* change: recordings/seeds made
before it will diverge on replay, so a `recordingVersionString` bump is warranted at release (per-variant;
left to the maintainers — the diff does not bump it).

### 2026-06-10 — Candidate-narrowing inspect line for unidentified potions/scrolls

> **Reverted 2026-06-11** (see the "Remove candidate-narrowing readout" entry above): the readout added
> no value and read confusingly alongside the themed potion sets. The `candidateKindCount` helper, its
> forward prototype, and the `itemDetails` render block were removed.

**What.** An unidentified potion's or scroll's inspect text now ends with a line like "You have narrowed
it down to one of 3 remaining beneficial potions." — the count of kinds it could still be, narrowed to
its polarity if that's known (the count is colored good/bad accordingly). It never names candidate kinds,
and is shown only when the count is ≥ 2.

**Why.** Surfaces the deduction bookkeeping a player otherwise tracks by hand. It reveals no new
information: the count is derived purely from what the player already knows (which kinds are identified,
plus this item's polarity if detect-magic/elimination has revealed it). The engine already
auto-identifies the last unknown kind of a polarity (`tryIdentifyLastItemKinds`, fired from every ID
path), so an unidentified item's count is always ≥ 2 — rendering only at ≥ 2 guarantees the line can
never hand out a free identification.

**Where.** `Items.c` — a forward prototype above `itemDetails`; a new `static short
candidateKindCount(item*, boolean *knownGood, boolean *knownBad)` defined just after
`itemMagicPolarityIsKnown` (iterates the category's kinds, counts unidentified ones matching known
polarity); and a render block appended to the unidentified branch of `itemDetails` (after the category
switch's `strcat`), gated on `POTION | SCROLL`. Reuses `itemMagicPolarityIsKnown`, `itemKindCount`,
`tableForItemCategory`, and `itemDetails`'s existing color-escape locals. All vanilla symbols.

**Determinism.** Pure display, recomputed on each inspect — no RNG, no serialized state; seeds and
recordings are unaffected.

### 2026-06-10 — Fire/lightning bolts detonate dropped bad potions

**What.** A fire or lightning bolt (`BF_FIERY` / `BF_ELECTRIC`) passing over a *dropped* potion now
detonates it in place, turning the potion into a placeable trap / ranged identifier. Only the seven
bad/cloud kinds react (poison, confusion, paralysis, incineration, darkness, descent, creeping death) —
the same set the thrown-potion shatter switch handles; good potions and hallucination get no bolt
signature. Fire is **violent** and lightning is **gentle** as an *emergent* property: detonation spawns
the potion's ordinary shatter dungeon feature, and the fire bolt's own per-cell `exposeTileToFire` then
ignites the flammable gas (poison/confusion/paralysis gas carry `T_IS_FLAMMABLE`); lightning has no fire
step, so the gas lingers as a cloud. The bad-potion switch was extracted from `throwItem` into a new
`static boolean shatterPotionAtLoc(item*, short x, short y)` (spawns DF + message + auto-ID + cell
refresh; returns true for the seven kinds) and is now shared between `throwItem` and the bolt hook.

**Why.** A dropped potion is otherwise inert until walked into. Letting a bolt set it off makes a dropped
bad potion a deliberate tool — lay a gas trap in a doorway, or ignite one on a chasing pack — and gives
fire/lightning staffs a second, terrain-driven use. Kept independent of the earlier potion-rework phases
so the change ports to upstream BrogueCE master verbatim (no creature effects or life cloud on bolt).

**Where.** `Items.c` only. (1) Forward prototype of `shatterPotionAtLoc` above `updateBolt`. (2) A new
hook in `updateBolt`, after the `pathDF` spawn and before the `BF_FIERY` `exposeTileToFire` block, so fire
ignites the gas the hook just spawned; it calls `shatterPotionAtLoc` on a `POTION` at the cell and tears
the floor item down exactly like `burnItem` (`removeItemFromChain(floorItems)` → `deleteItem` → clear
`HAS_ITEM | ITEM_DETECTED`), then sets `*lightingChanged` / `*autoID`. (3) `shatterPotionAtLoc` defined
above `throwItem`, extracted from the old inline switch. (4) `throwItem`'s bad-potion block replaced with
`if (shatterPotionAtLoc(...)) { } else { <existing harmless-splash + hallucination-ID> }`. Reuses only
upstream symbols.

**Determinism.** No RNG on the common bolt path (the hook is an `itemAtLoc` lookup + category test;
`spawnDungeonFeature` on a GAS-layer DF is a pure write). Action-triggered divergence only: detonating a
potion via a bolt diverges the seed exactly as *throwing* it would (same DFs; fire ignition via
`exposeTileToFire` is forced with `alwaysIgnite`, drawing no `rand_percent` of its own). No new RNG
primitive.

### 2026-06-10 — Thrown good potions affect the struck creature

**What.** Throwing an unidentified *good* potion (the first `numberGoodPotionKinds` of the potion
table: life, strength, telepathy, levitation, detect-magic, haste, fire-immunity, invisibility) at a
creature now applies that potion's effect to the creature it shatters on. A new
`static boolean applyPotionEffectToCreature(creature*, short potionKind, short magnitude)` (`Items.c`,
defined just above `drinkPotion`, forward-declared above `throwItem`) carries the per-kind logic. It
always applies the mechanical effect, but returns `true` only when a *player-visible* tell was
produced — which is what drives `autoIdentify`:
- strength → permanent +maxHP/+currentHP buff (≈half a life potion; "muscles bulge"),
- haste → "speeds up"; levitation → "floats into the air",
- life → full panacea heal of the struck creature **and**, on shatter, a healing-spore gas cloud
  (a new `DF_LIFE_POTION_CLOUD` that spawns the existing bloodwort `HEALING_CLOUD`); life auto-IDs
  unconditionally on shatter, like the gas potions,
- invisibility → reuses `imbueInvisibility` (its own flash + visibility-gated auto-ID),
- fire-immunity → sets `STATUS_IMMUNE_TO_FIRE`, but only IDs by *visibly snuffing flames* on a
  burning, not-already-immune, non-`MONST_FIERY` creature (no invented flavor text),
- telepathy / detect-magic and any bad potion → no effect, no ID.
The player is never the target (a thrown good potion shouldn't self-buff). The hook is a block at the
top of the potion-shatter branch in `throwItem`, before the bad-potion switch; when there is no tell
it falls through unchanged to the existing harmless-splash / hallucination-ID path. `drinkPotion`'s
own switch is untouched.

**Why.** Brogue's residual identification slog is discriminating the *good* potion cluster (life vs
strength vs haste…), which today can only be done by drinking in a safe corner. Making a thrown good
potion affect — and visibly tell on — the struck creature turns identification into a risky ranged
diagnostic. Effect-always / tell-gated keeps an unseen creature mechanically affected without leaking
information the player couldn't perceive. Upstream has no thrown-good-potion effect, so this is an
iOS divergence.

**Where.** `Items.c` — forward prototype above `throwItem`; `applyPotionEffectToCreature` defined
between `detectMagicOnItem` and `drinkPotion`; a new block at the top of the potion-shatter `if` in
`throwItem` (the good-potion effect, plus a `POTION_LIFE` case that spawns the cloud). Reuses `heal`,
`haste`, `imbueInvisibility`, `extinguishFireOnCreature`, `spawnDungeonFeature`. `Rogue.h` —
`DF_LIFE_POTION_CLOUD` appended to the `dungeonFeatureType` enum before `NUMBER_DUNGEON_FEATURES`.
`Globals.c` — a matching `{HEALING_CLOUD, GAS, 350, 0, 0}` row appended to `dungeonFeatureCatalog`
(clone of the bloodwort pod-burst). The catalog and enum are shared across the Brogue/Rapid/Bullet
variants; appending at the tail keeps every existing index aligned.

**Determinism.** No RNG on the common path: fixed magnitude via `potionTable[kind].range.upperBound`
(every good potion has `lowerBound == upperBound`), the helper draws no RNG, and `spawnDungeonFeature`
on a GAS layer is a pure volume/tile write (no RNG). Two action-triggered substantive-RNG divergences,
both stemming from the player's throw rather than from added bookkeeping: (1) thrown fire-immunity
early-extinguishing a burning creature removes that creature's remaining per-turn `rand_range(1,3)`
burn draws (the `STATUS_BURNING` case in `decrementMonsterStatus`, Monsters.c, draws unconditionally
per burning turn; fire immunity gates only the damage, not the draw); (2) the life cloud's gas changes
the gas map, so subsequent gas-dissipation rolls diverge from upstream seeds.

### 2026-06-11 — Button-drag highlight follows the finger

**What.** While dragging a touch across a menu/inventory (`MOUSE_ENTERED_CELL` with a
button already pressed), `processButtonInput` now moves `buttonDepressed` to the button
under the finger, instead of only setting it on `MOUSE_DOWN`.

**Why.** `drawButtonsInState` paints `buttonFocused` as `BUTTON_HOVER` and
`buttonDepressed` as `BUTTON_PRESSED`. On a drag, focus follows the finger but the
depressed index stayed on the originally-pressed button, so two rows lit up at once (e.g.
press "Autopilot", drag to "Feats" → both highlighted). On touch you want exactly one
highlight tracking the finger. The Classic engine already carries this fix
(`iBrogue_iPad/BrogueCode/Buttons.c`); this brings CE in line.

**Where.** `Buttons.c` — `processButtonInput()`, the focus-found branch now also sets
`buttonDepressed` when `event->eventType == MOUSE_ENTERED_CELL && buttonDepressed >= 0`.

### 2026-06-08 — Rethrow falls through to a normal throw prompt

**What.** The rethrow command (`RETHROW_KEY`, Shift+T) used to no-op when there was no
valid item to rethrow. It now falls through to a normal throw prompt in that case.

**Why.** Upstream, rethrow only fires if `rogue.lastItemThrown != NULL` *and* that item
is still carried (`itemIsCarried`); otherwise the keystroke silently does nothing — most
visibly the first time you press it in a game (nothing thrown yet). On touch a button that
does nothing reads as broken, so we degrade to the ordinary "Throw what?" item picker
(`throwCommand(NULL, false)`), the same thing `THROW_KEY` does. Auto-targeting at
`lastTarget` is intentionally *not* preserved in the fall-through case (it would require a
`throwCommand` that can both prompt for an item and auto-aim).

**Where.** `IO.c` — `executeKeystroke()`, the `RETHROW_KEY` case gains an `else` branch.

### 2026-06-07 — Don't show the ESC button for tap-to-continue prompts

**What.** `waitForAcknowledgment()` and `waitForKeystrokeOrMouseClick()` no longer force
`uiMode = CBrogueGameEventShowEscape`; they leave `uiMode` as-is (InNormalPlay during play,
so no ESC button).

**Why.** Both prompts already dismiss on `MOUSE_UP` (tap anywhere) — they're "press any key
/ click to continue" acknowledgments, including the `--more--` message prompt
(`displayMoreSign → waitForAcknowledgment`). The on-screen ESC button was appearing for
transient messages like "A pressure plate clicks underneath the dart!", which is redundant
and noisy. The ESC button stays for states a tap can NOT dismiss: text entry
(`getInputTextString` → `ShowKeyboardAndEscape`: save game / save recording / seed) and the
throw/zap aiming loop (`Items.c`, which needs ESC to cancel an aim). Care was taken not to
remove ESC anywhere it's the only way out — these two functions provably exit on a tap.

**Where.** `IO.c` — removed the `uiMode = CBrogueGameEventShowEscape` (and the
save/restore of `oldUiMode`) in `waitForAcknowledgment` and `waitForKeystrokeOrMouseClick`.
Classic doesn't set a UI mode in its equivalents, so this is CE-only.

### 2026-06-06 — Suspend pinch-zoom while an entity description box is shown

**What.** When a creature/item description box lingers in the cursor loop (e.g. the
player taps an entity in the sidebar), the host suspends the iPhone pinch-zoom to 1×
so the box isn't magnified/clipped, then restores it — the same treatment menu and
inventory already get.

**Why.** The description box (`printMonsterDetails`/`printFloorItemDetails` →
`printTextBox`) renders into the dungeon cells but fired no host signal, so it was
drawn magnified and ran off-screen while zoomed.

**Where.** `IO.c` — `extern void ceSetExamining(boolean);` at file top; in
`mainInputLoop`'s cursor `do/while`, `ceSetExamining(textDisplayed)` right before
`moveCursor` and `ceSetExamining(false)` right after the loop (clears on action/cancel).
Defined in `CEBridge.mm` (deduped) → `BrogueCEHost setExamining:` → host. The host only
suspends zoom when the box was armed by a **sidebar single-tap** (`examineArmed`, set in
`touchesEnded`); boxes that auto-appear (auto-explore stopping on an item, a tap-to-move
over a monster) are not armed, so they don't zoom out — that previously caused an in/out
flicker while exploring.

### 2026-06-06 — Title flyout marker: ASCII `<` instead of a triangle glyph

**What.** The main-menu flyout buttons (Play, View) are marked with a literal ASCII
`<` in their button text instead of the `G_LEFT_TRIANGLE` display glyph.

**Why.** `G_LEFT_TRIANGLE` maps (via `ce_glyphToUnicode`) to `U_LEFT_TRIANGLE`
(`0x25C4` / `0x1F780`), which renders through a font that doesn't carry the glyph on
every locale/device, so it showed up inconsistently. `<` is in the reliable text set
(rendered from Monaco) and always looks the same. The flyout opens to the buttons'
left, so a left-pointing marker still reads correctly.

**Where.** `MainMenu.c` `initializeMainMenuButtons` — the Play/View button text uses
` <  ...` and the two `buttons[n].symbol[0] = G_LEFT_TRIANGLE;` assignments were
removed. (`*` in button text is the symbol placeholder; with no symbol set it would
render literally, so the text uses `<` directly.)

### 2026-06-06 — On-screen Explore button: single-tap auto-explore

**What.** A single tap on the on-screen Explore button now auto-explores
immediately, instead of the desktop two-step "tap once to preview the path, tap
again to commit." Ports the Classic engine's existing fix to CE (the button
previously misfired, often needing a second tap). Keyboard `x` (a `KEYSTROKE`) is
unaffected.

**Why.** On touch, the preview-then-commit step reads as the button "not
registering." A tapped button should act like pressing its hotkey.

**Where.** `IO.c` — file-scope `static boolean exploreImmediately`; in
`mainInputLoop`, set it when the chosen button is Explore and the event is
`MOUSE_UP`; in `exploreKey`, consume it into a local `forceExplore` and OR it into
the final `proposeOrConfirmLocation(...)` guard.

### 2026-06-05 — Light haptic when the player takes damage

**What.** When the player loses HP, the engine signals the host to play a haptic,
scaled by severity: ordinary hit, a hit that leaves the player under 40% health
(the engine's own low-health-flash threshold), or a fatal blow.

**Why.** Tactile feedback for combat; the host owns the actual haptic so it can honor
the user's haptics setting and skip unsupported devices (iPad).

**Where.**
- `Combat.c` — `extern void cePlayerTookDamage(int severity);` at file top; in
  `inflictDamage`, when `defender == &player && damage > 0 && !rogue.playbackMode`,
  compute severity (fatal / under-40% / ordinary) and call it.
- Defined in `CEBridge.mm` → `BrogueCEHost playDamageHaptic:` → host.

**Gating.** Suppressed during recording playback. The host no-ops it when haptics
are off or on iPad.

### 2026-06-05 — Move the escape button aside while aiming a throw/zap

**What.** Around the targeting loop, the engine tells the host when aiming starts and
ends, so the host can move the on-screen escape button to the lower-left corner and
enable the aiming magnifier.

**Why.** During throw/zap targeting the escape button overlapped the aiming area, and
the magnifier (tap-and-hold) was otherwise suppressed outside normal play.

**Where.**
- `Items.c` — `extern void ceSetTargeting(boolean isTargeting);` at file top; in
  `chooseTarget`, `ceSetTargeting(true)` right after entering the aim loop and
  `ceSetTargeting(false)` at **both** exits (cancel and confirm).
- Defined in `CEBridge.mm` → `BrogueCEHost setTargeting:` → host.

### 2026-06-05 — No escape button on the death screen

**What.** The "You die… — press space or click to continue" screen now uses
`CBrogueGameEventInMenu` instead of `CBrogueGameEventShowEscape`.

**Why.** A tap already advances that screen, so the on-screen escape button was
redundant clutter. `InMenu` and `ShowEscape` are identical to the host except that
`InMenu` hides the escape button; touches still flow, so a tap still advances.

**Where.** `RogueMain.c` — `gameOver()`, the death "press to continue" loop.

### 2026-06-05 — Keep the full-screen title layout during the Load/Replay pickers

**What.** While the title-menu file pickers (Open saved game / View recording) are
open, keep `brogueCEAtTitle = true`; drop it to `false` only once a file is actually
opened.

**Why.** The pickers ran with `brogueCEAtTitle = false`, so the host enabled the
in-game safe-area insets and the view visibly shrank before any game had loaded.

**Where.** `MainMenu.c` — `mainBrogueJunction()`, the `NG_OPEN_GAME` and
`NG_VIEW_RECORDING` cases (set true before `dialogChooseFile`, false inside the
`openFile` success branch). `brogueCEAtTitle` is reported to the host by
`CEBridge.mm`.

---

### 2026-06-11 — Game Center leaderboard & achievements

**What.** Implemented the `notifyEvent` platform hook in `CEBridge.mm` so CE reports its
final score to a new `BrogueCE_High_Score` leaderboard and unlocks Game Center
achievements for earned feats. Added two `BrogueCEHost` methods — `reportCEScore:` and
`submitCEAchievementWithID:` — forwarded by `CEHost.swift` to the shared `GameCenter`
singleton (`ceHighScoreLeaderboardID` / `submitAchievement`). The on-screen leaderboard
button (`BrogueViewController.showLeaderBoardButtonPressed`) now picks the board by the
active engine.

**Why.** Classic already reports to Game Center (directly from `RogueMain.mm`); CE's
score/feats were local-only. CE lives in a framework that can't see the app's classes, so
it must route through the host protocol instead of calling `GameCenter` directly.

**Where.** No vendored `Engine/` C was changed — the engine already calls
`notifyEvent(GAMEOVER_*, score, …)` at game over. `CEBridge.mm`'s `ceReportGameOver()`
reads the engine globals `rogue.featRecord` / `featTable` / `gameConst` / `gameVariant`
and maps the `featTypes` enum to achievement IDs via `kCEAchievementIDForFeat[]`. Seven
feats reuse the Classic engine's achievement IDs (Game Center achievements are app-global);
the eighth, `brogue_untempted` (FEAT_TONE / "Untempted"), is CE-only and must be created in
App Store Connect.

**Gating.** Standard Brogue only (`gameVariant == VARIANT_BROGUE`); wizard runs never
report. Only completed runs report to the leaderboard — `GAMEOVER_QUIT` (quit/abandon) and
`GAMEOVER_RECORDING` (playback) are not forwarded, so giving up never posts a score. On
death only non-`initialValue` feats count; on victory/supervictory all set feats count.
(Note: the engine's *local* high-scores list still records quits via its own
`saveHighScore()`, matching upstream — only the online leaderboard excludes them.)

**Title-menu entry.** Added a "Game Center" item to the title screen's **main menu**
(after File Management), opening the `BrogueCE_High_Score` leaderboard. New
`NG_GAME_CENTER` command in the `NGCommands` enum (`Rogue.h`); the button + dispatch case
live in `MainMenu.c` (`initializeMainMenuButtons`, with `MAIN_MENU_BUTTON_COUNT` bumped to
5 tablet / 6 desktop; the `NG_GAME_CENTER` case calls `extern void ceShowGameCenter(void)`).
The bridge's
`ceShowGameCenter()` → `BrogueCEHost.presentGameCenter` → `CEHost` →
`BrogueViewController.presentGameCenterScreenForCE()`. Mirrors the existing
`NG_FILE_MANAGEMENT` / `ceShowFileManagement` plumbing; the leaderboard is presented as a
modal on the main thread while the engine stays at the title.

---

## Platform functions implemented in `CEBridge.mm`

These engine-declared platform functions were upstream stubs in this port and are now
implemented in the bridge (not the engine C, but listed here for orientation):

- `listFiles` — enumerates the CE save directory for the Load/Replay pickers.
- `getHighScoresList` / `saveHighScore` — local high scores (NSUserDefaults, CE keys).
- `saveRunHistory` / `saveResetRun` / `loadRunHistory` — the lifetime game-stats
  history (NSUserDefaults, CE keys; `seed == 0` is the "reset recent stats" sentinel).
- `notifyEvent` — CE → Game Center score/achievement reporting at game over (see the
  2026-06-11 entry above). Local high scores remain in NSUserDefaults; this adds the
  online leaderboard/achievements on top.

Still stubbed: `takeScreenshot`.

---

## Adding a new CE engine tweak

1. Prefer a host hook: declare `extern void ce<Thing>(...);` at the top of the engine
   file, call it where needed (with an `// iOS port (iBrogue):` comment), define it in
   `CEBridge.mm` inside `extern "C"`, add the matching `BrogueCEHost` method, and
   forward it from `CEHost.swift` to `BrogueViewController`.
2. For control visibility, reuse `uiMode` (write-only signal) rather than adding new
   plumbing where a mode value already conveys the intent.
3. Record the change here (what / why / where / gating).
