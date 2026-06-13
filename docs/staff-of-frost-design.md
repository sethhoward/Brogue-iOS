# Staff of Frost — design document

A new **good staff** for the BrogueCE 1.15 engine (`BrogueCE/Engine/`, CE only — the Classic
1.7.5 engine is untouched). This document captures the design *decisions*, the *reasoning*
behind each, and the *outcome* as implemented. It is the "why"; the "what/where" change log
lives in [`BrogueCE/Engine/IOS_MODIFICATIONS.md`](../BrogueCE/Engine/IOS_MODIFICATIONS.md) and
the accepted tradeoffs in [`KNOWN_CAVEATS.md`](../KNOWN_CAVEATS.md).

## Identity in one line

A zero-damage control + utility staff: it freezes a single target solid (then leaves it
sluggish), freezes deep water into temporary walkable bridges and dense foliage into brittle
walls, quenches fire it crosses, and turns frozen creatures into shove-able blocks you can slam
into enemies or into lava. Fire is its universal counter, in both directions.

## The pillars (and why each)

### 1. `STATUS_FROZEN` — a first-class status, not a reused one

**Decision.** Add a new `STATUS_FROZEN` rather than composing freeze from existing
`STATUS_PARALYZED` + `STATUS_SLOWED`.

**Why.** We wanted freeze to be its own colorable, shatterable, distinctly-named state with a
clean "frozen → thawing-slow" arc. Action-gating, however, is *identical* to paralysis, so
`STATUS_FROZEN` reuses every `STATUS_PARALYZED` gate (`|| STATUS_FROZEN`) instead of
reinventing AI handling — the new status carries the identity, paralysis carries the proven
"can't act" plumbing.

**Outcome.** Frozen = total lock (no move/attack/ability), works on the player too. On thaw it
leaves `STATUS_SLOWED`. Adding a status field is replay-safe (recordings replay inputs, not
state).

### 2. Freeze → slow, with the tail *layered underneath* the freeze

**Decision.** On cast, set `STATUS_FROZEN = freezeTurns` **and** `STATUS_SLOWED =
freezeTurns + slowTurns`. Both tick down together; when the ice breaks, exactly `slowTurns` of
slow remain.

**Why.** The naive approach — "remember the enchant, apply slow when freeze expires" — requires
carrying state across turns and a special decrement-time handoff. Layering the slow underneath
makes the tail fall out for free with **no remembered state**, and survives shatter/thaw
identically.

**Outcome.** A clean "frozen, then stiff" arc with zero bookkeeping. Frozen takes visual
precedence over the slow it sits on top of.

### 3. Fire beats freeze — one unified rule, both directions

**Decision.** Heat always wins, reducing freeze to a mere slow:

| Situation | Result |
|---|---|
| Bolt hits a normal, non-burning creature | Freeze, then slow tail on thaw |
| Bolt hits a **currently burning** creature | Extinguish + slow only — no freeze |
| Bolt hits a **`MONST_FIERY`** creature (always burning) | Extinguish + slow only — no freeze |
| A **frozen** creature later **catches fire** | Thaws → clears `STATUS_FROZEN`, slow tail remains |
| A blow lands on a frozen creature | Shatters it (clears frozen), slow tail remains |

**Why.** Symmetry and counterplay. The original loose idea ("extinguish, then freeze anyway")
was replaced mid-session with the cleaner "too hot to freeze solid" — it gives a crisp ice-vs-fire
identity and a guaranteed answer for both players and monsters. The predicate is one check:
`(info.flags & MONST_FIERY) || status[STATUS_BURNING]`.

**Outcome.** No frozen-and-burning contradictions; fire is a universal, intuitive counter.

### 4. Single-target bolt, not piercing

**Decision.** The bolt stops at the first creature it hits (`BF_TARGET_ENEMIES |
BF_NOT_LEARNABLE`, *no* `BF_PASSES_THRU_CREATURES`).

**Why.** This reversed an earlier call. We first chose a piercing ray (freeze a whole line), but
realized that freezing every creature in the line makes the **push pointless** — there'd be no
unfrozen target to slam a frozen block into. Single-target freezes one and leaves the rest as
shove targets.

**Outcome.** Freeze one, shove it into the pack. Auto-targets enemies; not learnable by empowered
allies (chosen for safety, to avoid an ally freezing your other allies, since the effect itself is
allegiance-blind). The `pathDF` still freezes terrain along the bolt's travel up to the impact, so
ice bridges across open water are unaffected.

### 5. Zero direct damage

**Decision.** The bolt deals no damage; it belongs with the control staffs (obstruction,
entrancement, discord).

**Why.** Freeze is already strong CC, and the staff also carries terrain utility and a push. Adding
bolt damage on top would make it strictly the best staff. Keeping it damage-free gives it a clear
identity ("you don't kill with it, you neutralize and reposition") and makes the *push* the only
way it indirectly causes harm — a more interesting payoff than flat damage.

**Outcome.** A control/utility staff whose offensive output is entirely positional.

### 6. Ice bridges over deep water — reuse the engine's dead infrastructure

**Decision.** The bolt's `pathDF` triggers the **already-present-but-unused** `ICE_DEEP` /
`DF_DEEP_WATER_FREEZE` system: deep water it crosses becomes temporary walkable ice that melts
back on its own.

**Why.** This was the session's biggest risk-collapse. The ice-terrain system already existed in
the engine, fully built and wired, but nothing triggered it. Reusing it meant the marquee feature
cost ~zero new terrain code.

**Outcome (and its emergent behavior, accepted as-is):**
- **Instant freeze**, ~5-wide swath, deep water only (foundation-gated, so a no-op over
  floor/lava/chasm).
- **Edge-melt lifetime** (~30–50 turns): `ICE_DEEP` has a negative `promoteChance`, so melt chance
  per turn = ~1% × number of non-ice orthogonal neighbors. The bridge melts from the rim inward;
  the interior outlives the edges. No hard timer — organic and self-balancing.
- **Built-in safety telegraph**: solid ice is **white** ("glossy"), about-to-melt ice is **black**
  ("cracking"), which reverts to open water the very next turn. Loitering on a darkening cell drops
  you into deep water (swim + ~50% item-theft).
- A pursuer caught when its cell melts is **dumped into the water** (the thaw doesn't evacuate,
  unlike the freeze). It does **not** drown — Brogue has no drowning — but it drops a carried item
  to the current and must swim to shore, costing it pursuit time. So the bridge is a **soft trap,
  not a kill**.

### 7. Frozen foliage — brittle temporary walls (the one net-new terrain)

**Decision.** Crossing dense foliage freezes it into `FROZEN_FOLIAGE`: a brittle barrier that
gains `T_OBSTRUCTS_PASSABILITY` (+ keeps vision-block) and thaws back to foliage.

**Why.** "Can't be trampled while frozen" was the player's own follow-up idea. We chose the
*barrier* reading (rigid, blocks passage) over the subtler *persistent-cover* reading, because a
"freeze a hedge into a wall" trick is a meaningful second terrain use that rhymes with obstruction —
worth the net-new terrain cost (the only fully-new terrain in the feature).

**Outcome.** New `FROZEN_FOLIAGE` / `FROZEN_FOLIAGE_MELT` tiles + DFs, **chained onto the end of
the water-freeze cascade** (via `subsequentDF`) so a single `pathDF` freezes water *and* foliage.
Fire melts it like lake ice (`T_IS_FLAMMABLE` + `fireType` = thaw).

### 8. Bump-to-push — frozen creatures are shove-able statues

**Decision.** Walking into a frozen creature shoves it instead of attacking it. The block takes no
damage; whatever it slams into does. It comes to rest **on** the first hazard it reaches.

**Why and the iteration it took:**
- The push reuses the precedent of the **`W_FORCE`** weapon runic (knockback already existed).
- **v1** fired a blind `BOLT_BLINKING`-style slide. Problem surfaced by playtesting the design in
  conversation: a blink **skims over hazards** (lava/chasm/water aren't "obstructions", and tile
  effects only fire at the landing cell), so "shove the adjacent enemy into the lava" was
  unreliable — the block sailed over a thin lava channel and landed safe.
- **v2** walks the slide **manually**: it slides across open floor and **stops on the first
  hazard** (deposited there to die in lava / fall down a chasm / flounder in deep water) or
  **before** a wall / creature / map edge. This makes environmental kills reliable.

**Outcome.** A frozen block: no self-damage; slams deal momentum damage to what they hit and douse
its fire; wedged blocks won't budge (and cost no turn). Lava/chasm/deep-water kills are reliable.

### 9. Push distance and slam damage scale with strength

**Decision.** Both the shove distance and the slam damage scale with the shover's **effective
strength** (`rogue.strength − weaknessAmount`):
- **Distance** = `clamp(effStr − 8, 2, 10)` — 4 tiles at the starting strength 12, up to the
  10-tile cap by strength 18.
- **Slam damage** = `distanceTravelled + max(0, effStr − 12)` — momentum plus a strength
  shove-bonus that is **0 at starting strength** and grows with each potion of strength.

**Why.** The player proposed it, and it fills a real gap: because the bolt deals no damage, the
staff had no way to scale with a martial build. Tying the push to strength — mirroring the engine's
existing effective-strength convention (`strengthModifier`) — gives a **strength-bruiser + frost
staff** synergy. The strength bonus is *additive* (not just via longer slides) so it bites even on
an adjacent slam, where the momentum term is tiny.

**Outcome.** A low-strength mage uses the staff purely for control/bridges/positioning; a
high-strength character turns a shove into a real hit or an environmental kill. Balance anchor:
0 bonus at the starting strength, and the whole combo still needs a freeze + positioning + a
target to slam into, so it doesn't outclass a weapon.

### 10. Quench terrain fire along the ray

**Decision.** The frost ray extinguishes any `T_IS_FIRE` terrain on each cell it crosses, carving a
firebreak.

**Why.** Completes the ice-vs-fire identity both directions (fire already melts the staff's ice).
Tactically useful — calm a room set ablaze, clear a grass fire.

**Outcome.** New `extinguishFireOnTile` clears burning gas/surface layers to `NOTHING` (floor
beneath untouched). Brimstone/lava-fed fire may reignite next turn from its source — that one calm
turn is intended.

### 11. Colour state

**Decision.** Persistent tints: a strong icy cast while frozen, a fainter chill while slowed
(slow tint applied **game-wide**, to slow from *any* source), plus an icy flash at the moment of
freezing. Ice terrain reads via its own tile colors.

**Why.** The player explicitly asked for clear frozen / slow / walkable indication. Tinting all
slowed creatures (not just frost-slowed ones) is a small, consistent feedback improvement rather
than a special case.

## Balance numbers

| Knob | Value | Notes |
|---|---|---|
| Generation frequency | 8 | rarer side, like other control staffs |
| Market value | 1200 | — |
| Enchant range | `{2,4,1}` | as other staffs |
| Freeze duration | `max(2, 2 + enchant/2)` | ~3–7 turns; scales slowly like the paralysis runic (strongest CC scales slowest) |
| Slow tail | `min(20, max(10, enchant·3))` | capped at 20, always under a dedicated wand of slowness's 30 |
| Push distance | `clamp(effStr − 8, 2, 10)` | 4 at str 12, cap 10 by str 18 |
| Slam damage | `distance + max(0, effStr − 12)` | momentum + strength shove-bonus |

Reference points used to calibrate: paralysis runic `max(2, 2 + enchant/2)`; entrancement
`enchant·3`; wand of slowness = a flat 30-turn slow (a *whole item*'s effect, so our tail stays
below it); `strengthModifier`'s effective-strength convention.

## Implementation map

| Concern | Location |
|---|---|
| Kind / bolt / effect / status / tile / DF enums; debug flag; PowerTables decls | `Rogue.h` |
| Staff row (shared), status string, ice/frozen-foliage tiles & DFs, freeze cascade | `Globals.c` |
| `frost` bolt row (×3 variants) | `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` |
| `BE_FREEZE` effect, fire-vs-freeze rule, per-path fire-quench hook | `Items.c` (`updateBolt`) |
| Freeze durations | `PowerTables.c` |
| `STATUS_FROZEN` action-gates, decrement, fire-thaw, terrain-fire extinguish | `Time.c` |
| Frozen action-gates, swarm/blocker rules | `Monsters.c` |
| `attackHit` / shatter-on-hit / backstab flag; `pushFrozenCreature` | `Combat.c` |
| Bump-to-push intercept; entrancement gate | `Movement.c` |
| Frozen / slow creature tints | `IO.c` (`getCellAppearance`) |
| Stair-follow gate | `RogueMain.c` |
| Debug grant `D_FROST_STAFF_START` | `RogueMain.c` (`initializeRogue`) |

## Tuning knobs

- Freeze / slow-tail formulas — `PowerTables.c`.
- Push distance `clamp` bounds (`FROST_PUSH_MIN/MAX_DISTANCE`) and the `−8` / `−12` anchors —
  `pushFrozenCreature` in `Combat.c`.
- Ice-bridge width (`probabilityDecrement`) and melt rate (`promoteChance`) — `Globals.c`.
- Generation frequency / value — the staff row in `Globals.c`.

## Deferred / out of scope

- Lava-freezing and shallow-water-specific behavior (the cascade does incidentally freeze shallow
  water, harmlessly — see `KNOWN_CAVEATS.md`).
- Native monster frost-casters (the bolt is `BF_NOT_LEARNABLE`, player-only).
- A shatter-on-melee *bonus-damage* mechanic — the push is the offensive payoff instead.
- Enchant-scaled bridge longevity/width (uses the fixed built-in values).

## Accepted tradeoffs (see `KNOWN_CAVEATS.md`)

- The slow tint is **game-wide**, changing the appearance of any slowed creature.
- The ray incidentally freezes **shallow** water too (cosmetic; shallow water is already walkable).
- A frozen creature **wedged** against an obstruction blocks its tile until it thaws (you can't
  melee past it; push from another angle or wait).
- The melting bridge is a **soft trap** — it can strip a pursuer's item and delay it, but cannot
  drown it (consistent with deep water everywhere in Brogue). Hard kills are the push's job.

## Debug

`D_FROST_STAFF_START` (`Rogue.h`, `WIZARD_MODE && 0`) grants a +10 identified staff in
`initializeRogue`, added deterministically (recording-safe). Flip to `&& 1` to playtest.
