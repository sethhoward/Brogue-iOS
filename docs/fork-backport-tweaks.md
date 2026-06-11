# Fork backport: potion-ID tuning tweaks

> **STATUS: applied & pushed 2026-06-10.** All three tweaks are now committed on their fork
> branches and pushed to origin:
> - `rest-polarity-insight` → commit `ae17767` (base 90)
> - `potion-bolt-detonation` → commit `687e638` (absorb + glow)
> - `eat-scroll-insight` → commit `e5e5086` (food descriptions)
>
> **Fork-only difference (tweak 2):** the fork's `potion-bolt-detonation` branch has no
> `POTION_HALLUCINATION` case in `shatterPotionAtLoc` (that's the iOS-only PR #842), so the
> glow branch there is gated on `floorPotion->kind < gameConst->numberGoodPotionKinds` to keep
> a malevolent hallucination potion from being mislabeled. iOS does not need that gate (its
> `shatterPotionAtLoc` handles hallucination), so the iOS and fork glow branches differ by
> that one condition — intentional.

Small follow-up tweaks were applied to the iOS branch `feature/potion-id-rework` on
2026-06-10. Each refines a feature that already has a bespoke fork branch / upstream PR, so
they should be folded into those branches when convenient. **iOS markers
(`// iOS port (iBrogue):`) are dropped on the fork — use neutral comments.**

The fork lives at `/Users/sethhoward/Work/BrogueCE-fork` (upstream layout: shared engine in
`src/brogue/`). Edits live in `src/brogue/Items.c` (tweaks 1–2) and `src/brogue/Globals.c`
(tweak 3).

---

## 1. Faster first rest-reveal → branch `rest-polarity-insight`

Lower the base rest-turn threshold from 120 to 90 so the first polarity hint lands sooner.
The per-known-kind ramp is unchanged.

```c
// before
#define POLARITY_INSIGHT_BASE_TURNS       120
// after
#define POLARITY_INSIGHT_BASE_TURNS       90
```

(Macro sits just above `gainPolarityInsightFromRest`; on the fork branch it was at
`src/brogue/Items.c:7244` at time of writing.)

---

## 2. Detonating potion absorbs the bolt → branch `potion-bolt-detonation`

When a fire/lightning bolt detonates a dropped bad/cloud potion, the bolt should **halt at
that tile** instead of piercing onward, so a single charge can detonate at most one potion.
This closes the exploit of lining up every unidentified potion in a row and clearing the
whole line with one zap.

Restructure the bolt-detonation hook in `updateBolt` into an `if/else`. Two behaviors:

1. **Bad/cloud potion** (`shatterPotionAtLoc` returns `true`): after the existing item teardown,
   add `terminateBolt = true;` so the bolt halts here (the detonation absorbs it), capping each
   bolt at one detonation.
2. **Benevolent potion** (`shatterPotionAtLoc` returns `false` — the eight good kinds, which have
   no shatter signature): print a harmless-glow line. The flask is **not** destroyed and the bolt
   **continues** (no `terminateBolt`). Gate on visibility so an off-screen monster bolt doesn't
   print a phantom message.

```c
    if (theBolt->flags & (BF_FIERY | BF_ELECTRIC)) {
        item *floorPotion = itemAtLoc((pos){ x, y });
        if (floorPotion && (floorPotion->category & POTION)) {
            if (shatterPotionAtLoc(floorPotion, x, y)) {
                removeItemFromChain(floorPotion, floorItems);
                deleteItem(floorPotion);
                pmap[x][y].flags &= ~(HAS_ITEM | ITEM_DETECTED);
                if (lightingChanged) {
                    *lightingChanged = true;
                }
                if (autoID) {
                    *autoID = true;
                }
                // The detonation absorbs the bolt: it halts here rather than piercing onward
                // (lightning normally passes through everything via BF_PASSES_THRU_CREATURES), so a
                // single bolt can detonate at most one potion. We only flag termination here; the
                // function still falls through to the exposeTileToFire/exposeTileToElectricity calls
                // below before returning, so a fire bolt ignites the freshly-spawned terrain at this
                // tile before the bolt stops.
                terminateBolt = true;
            } else if (playerCanSee(x, y)) {
                // The eight benevolent potions have no shatter signature, so the bolt passes through
                // the flask harmlessly — it is neither destroyed nor halts the bolt. Give that inert
                // reaction a line of feedback instead of a silent no-op.
                message("the bolt passes through the flask and its fluid glows warmly.", 0);
            }
        }
    }
```

`terminateBolt` is already declared at the top of `updateBolt` and consumed by the caller's
`if (updateBolt(...)) break;`. `shatterPotionAtLoc` returns `true` only for the bad/cloud
potions, so good potions never halt a bolt.

**PR-notes follow-up.** In
[docs/pr-notes-potion-bolt-detonation phase 3.md](pr-notes-potion-bolt-detonation%20phase%203.md)
note two accepted points: (a) a dropped bad potion directly in front of a monster now eats a bolt
aimed at that monster (rare; the explosion disrupts the arc); (b) because bad potions detonate-and-
halt while good ones glow-and-pass, a zap is a costed polarity probe — bounded and expensive, not a
free mass-ID.

---

## 3. Food descriptions hint at the quiet-meal scroll study → branch `eat-scroll-insight`

Description-only flavor that teaches the eat-scroll-insight mechanic (eating while nothing
hunts you studies an unidentified scroll's polarity). The `eat()` reveal is not variant-gated,
so the shared `foodTable` descriptions are accurate in every variant. In `src/brogue/Globals.c`,
extend both `foodTable` descriptions:

```c
itemTable foodTable[NUMBER_FOOD_KINDS] = {
    {"ration of food",      "", "", 3, 25,  0, 1800, {0,0,0}, true, false, 0, false, "A ration of food. Was it left by former adventurers? Is it a curious byproduct of the subterranean ecosystem? A meal taken in peace, with nothing on the hunt for you, settles the mind enough to study an unidentified scroll and sense whether its magic is benevolent or malevolent."},
    {"mango",               "", "", 1, 15,  0, 1550, {0,0,0}, true, false, 0, false, "An odd fruit to be found so deep beneath the surface of the earth, but only slightly less filling than a ration of food. Like any meal, it feeds the mind as well as the body when eaten undisturbed, affording a quiet moment to divine the nature of an unknown scroll."}
};
```

No logic change; no determinism implication.

---

## Determinism note

None of these tweaks add RNG or serialized state. The bolt change only makes the bolt traverse
fewer cells once it detonates a potion — an action-triggered divergence (player zaps a tile
holding a dropped bad potion), so recordings replay identically. The food and message changes
are description/flavor only. No `recordingVersionString` implication beyond what the underlying
Phase 3 / Phase 8 / Phase 9 features already carry.
