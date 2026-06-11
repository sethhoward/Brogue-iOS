# Potion-ID rework — per-phase session kickoff prompts

Ready-to-paste prompts for handing each phase of the potion-identification rework to a fresh
Claude Code session. Each prompt is self-contained (goal + key file:line anchors + the determinism
gotcha) and points at the full approved plan, **[docs/potion-id-rework-plan.md](potion-id-rework-plan.md)**.

**Sequencing:** Phase 1 first → Phase 2 (needs 1) → Phase 3 (needs 1 + 2). Phases 4, 5, 6, 7 are
independent and can run in any order / in parallel sessions.

Every phase: **BrogueCE 1.15 engine only** (`BrogueCE/Engine/`, never `iBrogue_iPad/BrogueCode/`), build via
the **Xcode MCP server**, add a What/Why/Where entry to `BrogueCE/Engine/IOS_MODIFICATIONS.md` + inline
`// iOS port (iBrogue):` markers, preserve RNG determinism, ship as **one PR off `master`** meeting the plan's
Definition of Done.

---

## Phase 1 — Thrown good potions affect the struck creature

```
Implement Phase 1 of the potion-ID rework in this Brogue iPad repo. First read the full plan at
docs/potion-id-rework-plan.md, then do Phase 1 ONLY.

Goal: throwing an unidentified good potion AT a creature applies its effect to that creature with a
visible flavor tell — Life = heal ("looks healthier"), Strength = permanent +maxHP buff (~half the Life
magnitude, "looks stronger"), Haste = speed up, Levitation = float, Invisibility = vanish.
Telepathy/Detect-Magic are player-only → no effect, no ID, fall through to the harmless splash.

Build a new helper applyPotionEffectToCreature(creature *monst, short potionKind, short magnitude) near
drinkPotion (BrogueCE/Engine/Items.c ~7252), reusing heal() (Items.c:3938), haste() (Items.c:3924),
imbueInvisibility() (Items.c:4192 — pass duration = magnitude, NOT the bolt's *15), and STATUS_LEVITATING /
STATUS_IMMUNE_TO_FIRE status writes. Hook it at the TOP of the potion shatter block in throwItem
(Items.c:6206), before the bad-potion `if` at 6207 — re-fetch the struck creature (see the commented stub
at Items.c:6253-6256); if the helper returns true, autoIdentify + delete + return. Don't touch drinkPotion's
own switch.

Determinism: throwItem draws ZERO RNG for potions today — use a FIXED magnitude
(potionTable[kind].range.upperBound), do not call randClump, so the throw path stays replay-safe.

Verify all line numbers by reading before editing. Follow the plan's "Hard constraints" and "Definition of
Done": BrogueCE only (never iBrogue_iPad/BrogueCode/), build via the Xcode MCP server, add a What/Why/Where
entry to BrogueCE/Engine/IOS_MODIFICATIONS.md + inline `// iOS port (iBrogue):` markers, record→replay shows
no desync. Work on a fresh branch off master; ship as one PR.
```

---

## Phase 2 — Potion of Life → healing "wort" cloud on shatter

```
Implement Phase 2 of the potion-ID rework. Read the plan at docs/potion-id-rework-plan.md, then do Phase 2
ONLY. (Depends on Phase 1's throw-shatter changes being in place.)

Goal: a thrown/shattered Potion of Life bursts into the EXISTING HEALING_CLOUD bloodwort gas
(Globals.c:510, flagged T_CAUSES_HEALING) instead of splashing harmlessly. A direct hit still heals the
struck creature (Phase 1); the cloud adds the area heal — both. The cloud heals enemies too (accepted).

Add a dungeon feature DF_LIFE_POTION_CLOUD — APPEND it at the END of the dungeonFeatureType enum in Rogue.h
and add the matching dungeonFeatureCatalog row in Globals.c at the SAME positional index — modeled on the
bloodwort pod-burst DF (DF_BLOODFLOWER_POD_BURST) so its layer spawns HEALING_CLOUD. Give POTION_LIFE its own
case in the throwItem shatter switch that spawnDungeonFeature()s it + message + autoIdentify.

Cross-variant trap: tileCatalog/dungeonFeatureCatalog and these enums are shared by the Rapid/Bullet
variants — append at the END, keep the row positionally aligned, or indices silently corrupt.

Determinism: spawnDungeonFeature/gas spread use the same RNG pattern bloodwort already uses; no new
unconditional draws. Note in the PR that throwing a Life potion now diverges from upstream seeds.

Follow the plan's Hard constraints + Definition of Done (BrogueCE only; Xcode MCP build; IOS_MODIFICATIONS.md
entry + inline markers). Fresh branch off master; one PR.
```

---

## Phase 3 — Potions as traps: bolt-triggered detonation (fire = violent, lightning = gentle)

```
Implement Phase 3 of the potion-ID rework. Read the plan at docs/potion-id-rework-plan.md, then do Phase 3
ONLY. (Depends on Phases 1-2 — it reuses the throw-shatter effects.)

Goal: a dropped potion becomes a placeable trap / ranged ID. A BOLT_FIRE crossing it detonates it VIOLENTLY
(incineration explodes; flammable gas potions ignite); a BOLT_LIGHTNING crossing it triggers it GENTLY
(spawns the potion's normal shatter signature/cloud and applies the creature effect if a creature is there).

Extend updateBolt at the fiery-bolt tile loop (Items.c:4695-4704) and add a sibling check for BOLT_LIGHTNING.
Factor a shared triggerPotionAtLoc(pos, boolean violent) that REUSES the throw shatter logic (the per-potion
DFs + Phase 1/2 effects) so the kind→effect mapping lives in one place. Detect the floor potion via
HAS_ITEM / itemAtLoc; remove it after triggering (mirror burnItem, Time.c:846); set the bolt's autoID so the
staff/wand IDs from the visible result, consistent with the existing fiery block.

Determinism: the new branch runs only when a fire/lightning bolt crosses a potion cell; detection adds no
rand_* on the common path; spawnDungeonFeature follows the established pattern.

Follow the plan's Hard constraints + Definition of Done (BrogueCE only; Xcode MCP build; IOS_MODIFICATIONS.md
entry + inline markers; record→replay no desync). Fresh branch off master; one PR.
```

---

## Phase 4 — Carried-potion volatility (catching fire detonates a volatile pack potion)

```
Implement Phase 4 of the potion-ID rework. Read the plan at docs/potion-id-rework-plan.md, then do Phase 4
ONLY. (Independent.)

Goal: when the player CATCHES fire with a volatile potion in the pack, it detonates on their tile — once per
ignition. Default volatile predicate = POTION_INCINERATION only; NEVER good potions (no unfair loss of Life).

In exposeCreatureToFire (Time.c:28-51), inside the STATUS_BURNING == 0 ignition transition (not every tick),
gated monst == &player, call a new detonateVolatilePackPotion(loc) — scan packItems, spawn the potion's
shatter DF, autoIdentify, consumePackItem, at most one per ignition.

Determinism: incineration-only adds ZERO rand_*. Do NOT add a random chance for arbitrary potions — that
would inject RNG into a hot, widely-called function (shifting the stream) and feels unfair. Keep the volatile
predicate a single tunable point.

Follow the plan's Hard constraints + Definition of Done (BrogueCE only; Xcode MCP build; IOS_MODIFICATIONS.md
entry + inline markers). Fresh branch off master; one PR.
```

---

## Phase 5 — Passive sensory tells

```
Implement Phase 5 of the potion-ID rework. Read the plan at docs/potion-id-rework-plan.md, then do Phase 5
ONLY. (Independent.)

Goal: each UNIDENTIFIED potion's inspect text gains a sensory adjective ("...a swirling crimson liquid that
feels warm...") clustering potions into Vital / Ethereal / Acrid (exact membership in the plan), deliberately
NOT aligned to good/bad polarity so it isn't free detect-magic. Cluster membership is fixed data; the surface
adjective shuffles per game.

Add enum potionSensoryTell + an `int sensoryTell` field on the itemTable struct (Rogue.h ~1433); adjective
pools in Globals.c/Globals.h parallel to itemColors; per-kind values in potionTable_Brogue (GlobalsBrogue.c
~665) using DESIGNATED initializers (so variant tables don't default to 0); pick this game's adjectives by
APPENDING a rand_range loop to the TAIL of shuffleFlavors() (Items.c:7963); weave the adjective into the
unidentified-potion intro sprintf at Items.c:1945. Leave the one-line itemName untouched.

Determinism (critical): the new rand_range MUST be the LAST draw in shuffleFlavors(), after every existing
color/wood/gem/metal/title shuffle, or it desyncs all seeds/recordings. This is the most balance-sensitive
phase — keep cluster membership data-only so it can be retuned without code changes.

Follow the plan's Hard constraints + Definition of Done (BrogueCE only; Xcode MCP build; IOS_MODIFICATIONS.md
entry + inline markers). Fresh branch off master; one PR.
```

---

## Phase 6 — Candidate-narrowing UI

```
Implement Phase 6 of the potion-ID rework. Read the plan at docs/potion-id-rework-plan.md, then do Phase 6
ONLY. (Independent; richer if Phase 5 has shipped.)

Goal: an unidentified potion's inspect panel shows how far deduction has come — "one of N remaining
possibilities" + polarity if known (+ a per-cluster breakdown if Phase 5 shipped). NEVER enumerate
unidentified true names (that would cheat) — count + polarity only.

Add a static candidatePotionKinds(const item *theItem, short *out) near the ID helpers (Items.c ~5845),
reusing itemMagicPolarityIsKnown (Items.c:5186) and per-kind identified/magicPolarity flags (no new state).
Render in itemDetails after the unidentified-potion intro (~Items.c:1993), gated
category==POTION && !identified && !playbackOmniscience, reusing the existing goodColorEscape/whiteColorEscape.

Determinism: pure display, recomputed each inspect — no RNG, no serialized state.

Follow the plan's Hard constraints + Definition of Done (BrogueCE only; Xcode MCP build; IOS_MODIFICATIONS.md
entry + inline markers). Fresh branch off master; one PR.
```

---

## Phase 7 — Sacrificial insight altar

```
Implement Phase 7 of the potion-ID rework. Read the plan at docs/potion-id-rework-plan.md, then do Phase 7
ONLY. (Independent; this is the largest phase — new dungeon content.)

Goal: a rare deep-dungeon altar (sibling to the commutation/resurrection altars). Drop an UNIDENTIFIED
potion/scroll on it → it's consumed and the altar reveals the magic POLARITY of every unidentified consumable
in your pack, then goes inert. Whole-pile polarity reveal, NOT identify-one-item: the commutation altar fires
PASSIVELY from updateFloorItems with no prompt (Items.c:1276-1293), so a prompt-free batch reveal is the
right fit; a blocking item-picker inside automatic turn processing is a replay-desync hazard — avoid it.

APPEND at the END everywhere (cross-variant trap — these enums/catalogs are shared by Rapid/Bullet):
INSIGHT_ALTAR + INSIGHT_ALTAR_INERT (tileType), DF_ALTAR_INSIGHT (dungeonFeatureType),
MT_REWARD_INSIGHT_ALTAR (machineTypes), and a TM_INSIGHT_ALTAR_ACTIVATION mech-flag — all in Rogue.h. Clone
the commutation tileCatalog/dungeonFeatureCatalog rows in Globals.c (~532 / ~793). Add a blueprintCatalog_Brogue
entry cloned from the resurrection altar (GlobalsBrogue.c:227), depth {13, AMULET_LEVEL}, low frequency
(~8-12, the rarest altar). Add a sibling handler block in updateFloorItems next to the commutation handler
(Items.c:1276) that gates on TM_INSIGHT_ALTAR_ACTIVATION + a valid (POTION|SCROLL) ITEM_CAN_BE_IDENTIFIED
sacrifice, calls a new revealPolarityOfPack() (loop packItems → detectMagicOnItem (Items.c:7239) →
tryIdentifyLastItemKinds), consumes the sacrifice, then activateMachine() to promote the altar inert.

CRITICAL: each enum slot must match its catalog row index — a positional mismatch silently corrupts
terrain/DF/blueprint mapping with no compile error. Cross-check after editing. Determinism: adding a blueprint
shifts the depth-13+ reward-room raffle, so all seeds diverge at the first deep reward room — document it (it
breaks shared seed catalogs at 13+).

Follow the plan's Hard constraints + Definition of Done (BrogueCE only; Xcode MCP build; IOS_MODIFICATIONS.md
entry + inline markers). Fresh branch off master; one PR.
```
