# Fight Simulator — Findings & Tuning Recommendations

A standing summary of what the headless fight simulator has shown about the heavy-weapon enchant meta,
the tuning it converged on, and the recommendation. The full methodology lives in
[`fight-simulator.md`](fight-simulator.md) (§12 has the detailed tables); this doc is the executive read.

Everything here is **sim-only**: the shipping game is byte-identical (the self-test goldens prove it).
The tuned values are a recommendation, not yet applied to the live engine.

---

## The flagship question

> Does heavy-weapon enchant scaling make one weapon the universal go-to, instead of "right tool for the
> right situation"?

**Yes — in the late game — and the fix is per-weapon and per-mechanism, not a single global cap.** The
simulator also confirmed the corollary the project was really after: with the right levers, *surplus
enchants are better spent on a glowed staff than on maxing the weapon*, so a hybrid loadout (weapon +
situational staff) becomes the smart play rather than all-in on one weapon.

---

## How the answer is produced

- Five encounter archetypes — **corridor** (single-file), **frenzy cluster** (packed), **scattered pack**
  (spread), **lone tank** (one big HP), **ambush** (start far / approach). A weapon's *shape across these*
  is what tells "situational" from "universal," which a single aggregate win% hides.
- **Depth-derived budget**: real level generation is replayed to get the strength potions, enchant scrolls,
  and life potions a player plausibly has at a given depth — so the late-game enchant runaway is realistic,
  not assumed.
- **Common random numbers**: baseline and variant run on identical seeds for clean diffs.
- Win% is measured per archetype; the levers are gated behind `#ifdef FIGHTSIM` so shipping never changes.

---

## Findings

1. **Model fidelity beats lever cleverness — the recurring lesson.** Every early ranking was an artifact of
   an unmodeled mechanic, and fixing the model repeatedly *rewrote the conclusion*:
   - mace/war-hammer looked like 95% dominators until attack-speed (½-speed stagger recovery) was modeled;
   - rapier looked like a 34% joke until its 2× speed + lunge were modeled;
   - the **war pike** looked *situational* (weak in scattered packs) until its **reach-2** was modeled —
     after which its one weakness vanished (pack 73 → 95) and it became the single most dominant weapon.

   Three plausible pike levers (penetrate-damage, reach-damage, enchant cap) were chased and abandoned
   because the *model* was incomplete; the real driver only became visible once it was fixed. **Trust no
   tuning number until the weapon's real mechanics are credited.**

2. **The dominance is a late-game phenomenon.** At depth 10–13 the enchant budget is small and all weapons
   bunch ~64–84; the levers don't bite. The runaway is real only at depth ~16–19. So the correction is
   *late-game-only by construction* — early/mid play is untouched.

3. **One lever per *mechanism*, not a blanket cap.** Weapons resist a uniform enchant cap differently:
   - **Raw-stat weapons** (broadsword, war axe) respond cleanly to an enchant **soft knee**.
   - **War pike is immune to every damage lever** (enchant cap, penetrate, reach). Its power is
     **throughput** — normal cadence + penetrate + reach out-damages even the base-30 war hammer (½-speed).
     The only lever that bites is **attack speed**.
   - **Flail** needs its **pass-attack damage** trimmed (its multi-hit *is* its power).

4. **Whack-a-mole.** Each time the top weapon is reined in, the next even-profile generalist inherits
   "best everywhere" (flail jumped to 88 once the others were handled). The fix must hit every universal
   generalist or it just trades one king for another.

5. **A soft knee beats a hard cap.** A hard enchant cap is a cliff — the scroll at +9 is worth zero, a
   feel-bad and a weird "stop enchanting here" rule. A soft knee (full value to the knee, then a 25%
   marginal taper) keeps enchants useful while making the *next* scroll worth more on a staff — the hybrid
   nudge by incentive, not a wall.

---

## Recommended tuning (`FIGHTSIM_TUNED_DEFAULTS`)

One lever matched to each weapon's actual driver; everything else untouched (war hammer stays the 1v1 king,
mace self-balances via stagger recovery, nimble weapons stay free):

| weapon | lever | why |
|---|---|---|
| **broadsword** | enchant **soft knee 9 @ 25% slope** | pure raw-stat generalist; taper, no cliff |
| **war_axe** | enchant **soft knee 10 @ 25% slope** | raw scaling; cleave survives as a pack lean |
| **war_pike** | **2× attack recovery** | throughput weapon — speed is the only lever that bites |
| **flail** | pass-attack damage **50%** | its multi-hit is its power; trim the mechanic directly |

Reproduce the whole end-state with `--tuned`.

### Achieved end-state (depth 19, win% per archetype)
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
every situation. The whole roster (dagger aside) sits in a 72–84 band with distinct per-archetype
identities. That is the goal: right tool for the right situation.

---

## The hybrid payoff (the point of it all)

With the tuning in place, splitting enchants into a glowed lightning staff becomes the smart play — a
**reversal** from shipping, where all-in on the weapon was correct.

| weapon | all-in (shipping) | hybrid (shipping) | all-in (**tuned**) | hybrid (**tuned**) |
|---|---|---|---|---|
| broadsword | **95** | 94 | 82 | **94** |
| war_axe | 92 | 93 | 83 | **93** |
| war_pike | **97** | 92 | 84 | 83 |

- **Shipping:** all-in wins or ties → no reason to diversify (the "go-to weapon" problem).
- **Tuned:** hybrid leads by +10–12 for the raw-stat weapons; pike's all-in edge collapses to a wash.
- **Survives finite charges:** over a full floor that drains the +6 staff, hybrid still clears more
  encounters before dying than all-in under the tuned config — the early lightning burst banks enough HP to
  carry past the point the staff runs dry. (Pike's all-in *sustain* collapses hardest: 3.93 → 1.43
  encounters cleared, because a slow weapon is punished most over a long grind.)

---

## Upgrade-path integrity (pre-ship check)

A nerf that made a heavy weapon worse than its lighter same-family version would invert the upgrade
incentive (why pick up the war axe?). Verified under the tuned/nerfed config — each heavy still beats its
light counterpart in mean at both depths and **in every archetype (no inversions)**:

| family | light (d19) | heavy @ tuned (d19) | margin |
|---|---|---|---|
| sword → broadsword | 72 | 84 | +12 |
| spear → war_pike | 74 | 84 | +10 |
| axe → war_axe | 75 | 84 | +9 |
| mace → war_hammer | 72 | 84 | +12 (unnerfed) |

The nerf roughly halves each heavy's margin over its light version (broadsword was +22 over sword) but
never erases it. Two spots tighten to a tie in the heavy's *weakest* geometry — war_pike ≈ spear in
corridors (92 vs 90), war_axe ≈ axe in scattered packs (78 vs 78) — which is healthy: it gives the light
weapons a genuine niche without breaking progression. Reproduce: `--progression`.

## Enchant curve — where win-rate levels off (depth 19, str 18, HP 80)

Sweeping a single weapon's enchant from +0 to +18 (tuned config, mean win% over the five archetypes;
reproduce with `--enchantcurve`):

| weapon | +0 | +2 | +4 | +6 | +8 | **+10** | +12 | +14 | +16 | +18 |
|---|---|---|---|---|---|---|---|---|---|---|
| sword | 25 | 29 | 36 | 41 | 51 | 72 | 84 | 90 | 90 | 92 |
| broadsword | 26 | 49 | 56 | 72 | 82 | **84** | 86 | 90 | 92 | 94 |
| war_axe | 26 | 40 | 56 | 68 | 80 | **84** | 87 | 89 | 92 | 96 |
| war_pike | 23 | 34 | 43 | 60 | 70 | **84** | 89 | 94 | 95 | 96 |
| war_hammer | 16 | 38 | 51 | 60 | 72 | **84** | 90 | 94 | 96 | 96 |

- **The inflection is +10.** Below it every weapon climbs steeply (each scroll is huge); at +10 all five
  converge to **84%**; above it the curves split.
- **Knee'd weapons (broadsword, war_axe) flatten past +8–10** — gains fall to ~1%/enchant, the soft knee
  made visible. **Un-knee'd weapons (war_pike, war_hammer) keep climbing to ~+14–16** before the ceiling.
- **+10 = 84% is by design:** +10 is the realistic depth-19 scroll budget, the exact level the tuning
  targeted, so all five land at the same balanced point there.
- The **~95–96% ceiling** is the unwinnable tail (you got surrounded) that no enchant fixes.
- **The practical cap is the scroll budget, not the curve.** A normal d19 run rarely affords past +10 on a
  single weapon, so the longer un-knee'd curves are mostly unreachable in play.

## Why the war pike has no enchant knee (kept as-is)

The other three heavies carry levers that also shape the *enchant economy*: the soft knee gives broadsword
and war_axe diminishing returns past +9/+10, nudging surplus scrolls toward a hybrid staff, and the flail's
pass-attack trim caps its multi-hit. The war pike is deliberately different — **only** the 2× recovery
penalty, **no** enchant knee. This was a considered decision, not an oversight:

1. **Recovery already balances its win rate.** At the realistic +10 budget the pike sits at 84% — the same
   band as everything else (see the curve above). It is not a dominance source, so it doesn't *need* a knee.
2. **A knee would over-nerf the all-in build.** Recovery (a flat ÷2 on attack rate) and a knee (a per-hit
   damage trim) double-dip. Tested: knee 8 @ 25% on top of recovery dropped all-in pike to **66%** (below a
   plain sword); even a gentle knee (10 @ 50%) pulled it to **77%**. Recovery-only (84%) keeps all-in viable.
3. **Having no enchant disincentive is the point.** The `--hybrid` data shows pike all-in 84 ≈ hybrid 83 —
   a wash, so the player is genuinely free to choose. The pike is the "commitment" weapon: a strong
   all-rounder *whether or not* the run goes hybrid. Its longer enchant curve (to +14–16) needs a
   scroll-rich run that's rarely affordable, so it isn't a hidden dominance source — just upside for a lucky
   run. Not every run can be a hybrid, and the pike is the one heavy that doesn't ask you to be.

Trade-off accepted: the pike is the lone heavy without a hybrid nudge — by design.

## What's best so far — recommendation

**Adopt the four-lever tuned config above.** It is the strongest result the sim has produced:

- It achieves the stated goal — no universal go-to; every weapon best somewhere and beatable elsewhere.
- It flips the meta toward **hybrid** play, and that flip **holds under realistic charge scarcity**.
- It is **the most shippable** option, because each lever maps onto an existing engine concept:
  - soft-knee enchant → a clamp variant in `netEnchant`;
  - flail pass-attack trim → a damage scalar in `Movement.c`;
  - **pike 2× recovery → the existing "takes an extra turn to recover" mechanic** (mace/war-hammer stagger,
    minus the knockback) — no new system needed.

Within that, two specifics worth flagging as the better of the alternatives explored:

- **Pike: 2× recovery, not an enchant cap.** Damage levers were proven near-useless on it; the speed
  penalty is the only thing that lands it in band *and* restores a genuine weakness (scattered packs), *and*
  it's the most portable. This is the single highest-value finding for the live game.
- **Broadsword/war_axe: soft knee, not a hard cap.** Same balance outcome, strictly better feel, and it is
  what creates the hybrid incentive rather than a dead-zone wall.

### Confidence & caveats
- The **rankings are trustworthy**; absolute win%s carry sampling noise (~±5% per archetype cell at 30–40
  trials) and reflect the modeled mechanics — whip's range-5 reach is still unmodeled (whip is out of
  roster).
- Sustain **survival rates are not realistic** — the test gauntlet is harsher than a real floor, so
  `avg_cleared` (relative depth reached) is the honest sustain metric, not an absolute clear rate.
- These are **balance recommendations, not applied changes.** Shipping is byte-identical.

---

## Open / next

1. **Port the tuned config to the live game** (ungated) — the real balance change; needs its own review.
2. **Buff the dagger** (32% floor) — via runic-odds, *not* enchant; re-verify it doesn't overshoot.
3. **Softer sustain gauntlet** — re-run hybrid sustain in a 30–70% survival band for a cleaner clear-rate
   read (current run answers the ranking but pins survival near 0).
4. **Phase 6 — creature/boss lethality** — sentinel HP OFF; the monster-leveling axis is already wired.
