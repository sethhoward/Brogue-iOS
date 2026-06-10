# Reworking potion identification — potions as interactive objects

## Status (2026-06-10)

- **Shipped** (iOS `feature/potion-id-rework`; upstream fork branches off `master`):
  - Phase 1 — thrown good potions affect the struck creature. (fork: `potion-throw-good-effects`)
  - Phase 2 — potion of Life bursts into a healing cloud on shatter. (fork: `potion-throw-good-effects`, combined PR with P1)
  - Phase 3 — fire/lightning bolts detonate dropped bad potions. (fork: `potion-bolt-detonation`)
  - Phase 6 — candidate-narrowing inspect line for unidentified potions + scrolls. (fork: `potion-candidate-ui`)
  - All commits authored as a human (no AI-attribution trailer); upstream PRs are drafted (see `docs/pr-notes-*`) but **not opened**.
- **Deferred** (not started): Phase 4 (carried-potion volatility); Phase 7 (insight altar — itself a
  polarity reveal, in tension with the "ID is a gamble" goal).
- **Shelved**: Phase 5 (passive sensory tells). A player-simulation showed that any cluster scheme
  trivializes Life/Strength identification once the player holds detect-magic: the self-identifying
  common goods plus elimination make Life/Strength riskless to find. The validated mitigation — pair
  Life and Strength in one cluster so deduction floors at a 1-of-2 that polarity can't break — is
  recorded in case P5 is ever revived.
- **Parked**: a detect-magic rework. Detect-magic is the amplifier behind P5's triviality, but it's a
  core, cross-category mechanic (it reveals magic-item polarity for potions/scrolls/rings/wands/staffs
  and the Amulet's aura — *not* secret rooms or monsters, which are magic-mapping and telepathy). A
  rework is a large, separate, upstream-risky effort, deliberately out of scope for the potion arc.

## Context

The current ID system funnels players into the "potion chug": drinking unknowns in a safe corner.
The two referenced articles frame ID as *thrilling* when it forces risky decisions and a *slog* when
it's a zero-risk ritual. Engine exploration sharpened the diagnosis: Brogue's three existing ID channels
(**throwing**, **detect magic**, **auto-ID by use**) all reveal the *bad* potions; the residual slog is
discriminating the **good cluster** (Life vs Strength vs Telepathy…), which today can only be done by drinking.

**Corrected understanding (verified in code):**
- A *thrown* good potion does **nothing** to a creature today — it "splashes harmlessly"
  ([Items.c:6257](BrogueCE/Engine/Items.c:6257)). Only *gas* potions affect creatures, and only via the
  gas cloud they spawn ([Items.c:6207-6247](BrogueCE/Engine/Items.c:6207)).
- The *wand* of invisibility turning a monster invisible is a **bolt** effect
  (`BE_INVISIBILITY` → `imbueInvisibility`, [Items.c:4520](BrogueCE/Engine/Items.c:4520) /
  [4192](BrogueCE/Engine/Items.c:4192)) — a different code path from the thrown potion.

**The vision (this plan):** make every potion an interactive object. *Triggering* a potion — by throwing it,
or by detonating a dropped one with a fire (violent) or lightning (gentle) bolt — produces a visible signature:
bad potions make their existing gas/fire clouds; good potions affect the creature they hit (with flavor text)
and, where it fits, spawn a beneficial cloud (Life → healing "wort" cloud). This turns potions into a *ranged,
risky diagnostic channel* and a *tactical trap*, directly attacking the corner-chug.

**Scope:** BrogueCE 1.15 engine only (`BrogueCE/Engine/`). Classic 1.7.5 stays authentic vanilla. The
thief-palate idea is a separate PR, out of scope here.

## What already exists (our reuse inventory)

- **Creature-generic effect helpers** (already used by staff bolts): `heal(creature*, pct, panacea)`
  ([Items.c:3938](BrogueCE/Engine/Items.c:3938)) — prints "looks healthier" for monsters;
  `haste(creature*, turns)` ([Items.c:3924](BrogueCE/Engine/Items.c:3924));
  `imbueInvisibility(creature*, dur)` ([Items.c:4192](BrogueCE/Engine/Items.c:4192)). Levitation/fire-immunity
  are per-creature `status[]` writes.
- **Healing gas ("wort cloud"):** `HEALING_CLOUD` terrain + `T_CAUSES_HEALING`
  ([Globals.c:510](BrogueCE/Engine/Globals.c:510), [Rogue.h:1951](BrogueCE/Engine/Rogue.h:1951)), spawned today
  by the bloodwort pod-burst DF (`DF_BLOODFLOWER_POD_BURST`, [Rogue.h:1564](BrogueCE/Engine/Rogue.h:1564)).
- **Per-potion shatter DFs:** `DF_POISON_GAS_CLOUD_POTION`, `DF_CONFUSION_GAS_CLOUD_POTION`,
  `DF_PARALYSIS_GAS_CLOUD_POTION`, `DF_INCINERATION_POTION`, `DF_DARKNESS_POTION`, `DF_HOLE_POTION`,
  `DF_LICHEN_PLANTED` (all in the throw switch, [Items.c:6211-6246](BrogueCE/Engine/Items.c:6211)).
- **Bolts:** `BOLT_FIRE` (BF_FIERY) and `BOLT_LIGHTNING` ([Rogue.h:925-926](BrogueCE/Engine/Rogue.h:925)); the
  fiery-bolt tile loop already iterates every path cell ([Items.c:4695-4704](BrogueCE/Engine/Items.c:4695)).
- **Throw seam:** the dev-commented stub at [Items.c:6253-6256](BrogueCE/Engine/Items.c:6253)
  (`applyInstantTileEffectsToCreature(monst)`) marks exactly where creature effects belong; `monst` is captured
  at [Items.c:6129](BrogueCE/Engine/Items.c:6129).
- **Identification/display:** `autoIdentify` ([Items.c:5982](BrogueCE/Engine/Items.c:5982)),
  `detectMagicOnItem` ([7239](BrogueCE/Engine/Items.c:7239)), `identify` ([6859](BrogueCE/Engine/Items.c:6859)),
  `shuffleFlavors` ([7963](BrogueCE/Engine/Items.c:7963)), `itemDetails` unidentified-potion branch
  ([1944](BrogueCE/Engine/Items.c:1944)), commutation-altar passive trigger in `updateFloorItems`
  ([1276-1293](BrogueCE/Engine/Items.c:1276)).

## Hard constraints (apply to every phase)

- **BrogueCE only** — no edits under `iBrogue_iPad/BrogueCode/`.
- **Determinism** — replays/seeds require an identical RNG draw *sequence*. New `rand_*` must be appended where
  it can't perturb existing draws, or avoided. Each phase states its stance.
- **Cross-variant trap** — `tileCatalog`, `dungeonFeatureCatalog`, and the `tileType`/`dungeonFeatureType`/
  `machineTypes` enums are shared by the Rapid/Bullet variants. **Append new enum members at the end**; keep
  catalog rows positionally aligned, or indices silently corrupt.

## Definition of Done (the PR bar for each phase)

Every phase ships as one PR meeting all of:
1. **Builds clean** via the **Xcode MCP server** (not `xcodebuild` CLI); no new warnings on touched files.
2. **Change-log** — a dated entry in [`BrogueCE/Engine/IOS_MODIFICATIONS.md`](BrogueCE/Engine/IOS_MODIFICATIONS.md)
   (What / Why / Where) **and** inline `// iOS port (iBrogue):` markers at every touched site.
3. **Determinism preserved** — no unintended RNG-stream shift; any seed/replay divergence documented in the PR.
4. **Style match** — matches surrounding engine conventions; reuses existing helpers/DFs/terrain.
5. **Manual test pass** — the phase's test steps (below) verified in-app; record→replay shows no desync.
6. **Docs** — if a deliberate tradeoff is accepted, add it to [KNOWN_CAVEATS.md](KNOWN_CAVEATS.md); update the
   game-data audits if engine data tables changed.

---

## Phase 1 — Thrown good potions affect the struck creature  ⭐ (flagship; all reuse)

**Goal:** throwing an unidentified good potion *at a creature* (ally, freed captive, or enemy) applies its effect
to that creature with a flavor tell — heal ("the goblin looks healthier") = **Life**, muscles bulge = **Strength**,
speeds up = **Haste**, floats = **Levitation**, vanishes = **Invisibility**. The only channel that discriminates
the good cluster. Feeding an ally = throw at its tile (no new command/keybind → no recorded-command format change).

**Touch points:**
- New helper near `drinkPotion` (≈[7252](BrogueCE/Engine/Items.c:7252)):
  `boolean applyPotionEffectToCreature(creature *monst, short potionKind, short magnitude)` — a `switch` over
  the good kinds, reusing `heal(monst,100,true)` (Life), `haste(monst,mag)` (Haste),
  `imbueInvisibility(monst,mag)` (Invisibility — duration is the potion magnitude, *not* the bolt's ×15),
  `monst->status[STATUS_LEVITATING]` (Levitation),
  `STATUS_IMMUNE_TO_FIRE` (Fire Immunity). Strength has no monster stat → apply a permanent **+maxHP** buff
  (reuse the Life path with a smaller amount, ≈half the Life magnitude) with a "looks stronger / muscles bulge"
  tell. TELEPATHY/DETECT_MAGIC → `return false` (player-only).
  Returns true when a visible tell was produced. Do **not** modify `drinkPotion`'s own switch.
- Call site at the top of the potion shatter block ([Items.c:6206](BrogueCE/Engine/Items.c:6206)), before the
  bad-potion `if` (6207): re-fetch the struck creature at the shatter cell; if `applyPotionEffectToCreature`
  returns true → `autoIdentify(theItem)`, refresh, `deleteItem`, return. Bad potions untouched; good potions
  intercepted before the harmless-splash `else`. No tell (telepathy/detect-magic, or unseen) → fall through to
  the existing splash message, no ID.

**Determinism:** `throwItem` draws zero RNG for potions today; use a **fixed magnitude**
(`potionTable[kind].range.upperBound`) so the throw path stays RNG-neutral and replay-safe.

**Test:** debug-grant unidentified Life/Strength/Haste/Levitation/Invisibility; summon/free an ally; throw each at
it → confirm the tell + auto-ID; throw at an enemy → it's buffed; throw Telepathy/Detect-Magic at a monster →
harmless splash, no ID. Record→replay a session that throws potions → no desync.

---

## Phase 2 — Potion of Life → healing "wort" cloud on shatter (area)

**Goal:** a potion of Life, when it shatters (thrown, or later bolt-triggered), bursts into a `HEALING_CLOUD`
instead of splashing harmlessly — a visible red healing-spore cloud that heals creatures standing in it, exactly
like a bloodwort pod. Establishes the reusable "good potion → area signature" pattern.

**Touch points:**
- Add one dungeon feature (append at end of the `dungeonFeatureType` enum, [Rogue.h](BrogueCE/Engine/Rogue.h)),
  e.g. `DF_LIFE_POTION_CLOUD`, modeled on the bloodwort pod-burst DF — its layer spawns the existing
  `HEALING_CLOUD` gas ([Globals.c:510](BrogueCE/Engine/Globals.c:510) / catalog row near
  [Globals.c:701](BrogueCE/Engine/Globals.c:701)). Append the matching `dungeonFeatureCatalog` row positionally.
- In the throw shatter switch, give `POTION_LIFE` its own case that `spawnDungeonFeature(... DF_LIFE_POTION_CLOUD ...)`
  + message + `autoIdentify`, instead of the harmless-splash `else`.
- Reconcile with Phase 1: a *direct hit* on a creature heals it (Phase 1) **and** the shatter spawns the cloud
  for the area heal (both — confirmed).

**Determinism:** `spawnDungeonFeature`/gas spread use the same RNG pattern bloodwort already uses; adding a spawn
site shifts the stream only when a Life potion is thrown (a player action), like any gameplay change. No new
unconditional draws. Document that throwing a Life potion now diverges from upstream seeds.

**Test:** throw Life near a wounded ally and near an enemy → healing cloud forms, both heal while inside;
confirm auto-ID and the cloud dissipates like bloodwort.

---

## Phase 3 — Potions as traps: bolt-triggered detonation (fire = violent, lightning = gentle)

**Goal:** a dropped potion becomes a placeable trap / ranged ID. A `BOLT_FIRE` crossing it detonates it
*violently* (incineration explodes; flammable gas potions ignite); a `BOLT_LIGHTNING` crossing it triggers it
*gently* (fires the potion's normal shatter signature without the fire). Drop an unknown potion in a doorway,
zap it when an enemy steps in.

**Touch points:**
- Extend `updateBolt` ([Items.c:4695-4704](BrogueCE/Engine/Items.c:4695), the fiery-bolt tile loop, plus a
  sibling check for `BOLT_LIGHTNING`): when the bolt's path cell has `HAS_ITEM` holding a potion, trigger it.
  Factor a shared `triggerPotionAtLoc(pos, boolean violent)` that reuses the throw shatter logic (the per-potion
  DFs from Phase 1/2) so the kind→effect mapping lives in one place. Fire path = violent (ignite/explode);
  lightning path = gentle (spawn the signature DF / cloud, apply the creature effect if one is present).
- Remove the floor potion after triggering (mirror `burnItem`, [Time.c:846](BrogueCE/Engine/Time.c:846)); set
  the bolt's `autoID` so the staff/wand IDs from the visible result, consistent with the existing fiery block.

**Determinism:** the new branch runs only when a fire/lightning bolt crosses a potion cell; detection is
deterministic and adds no `rand_*` on the common path. `spawnDungeonFeature` follows the established pattern.

**Test:** drop incineration → firebolt it → violent explosion; drop caustic/confusion → lightning it → gas cloud
(gentle); drop Life → lightning it → healing cloud; confirm staff auto-IDs and the potion is consumed.

---

## Phase 4 — Carried-potion volatility: catching fire detonates a volatile pack potion

**Goal:** carrying volatile potions through fire is now risky. When the player *catches* fire with a volatile
potion in the pack, it detonates on their tile.

**Touch points:** in `exposeCreatureToFire` ([Time.c:28-51](BrogueCE/Engine/Time.c:28)), inside the
`STATUS_BURNING == 0` *ignition transition* (fires once per catch, not per tick), gated `monst == &player`,
call a new `detonateVolatilePackPotion(loc)` — scan `packItems`, spawn the potion's shatter DF, `autoIdentify`,
`consumePackItem`, at most one per ignition. Default volatile predicate = `POTION_INCINERATION` only (extensible
to the flammable-gas potions); **never good potions** (no unfair loss of Life/Strength).

**Determinism:** incineration-only path adds zero `rand_*` → stream untouched. (A "random chance for any potion"
design is explicitly rejected: it would add RNG inside a hot, widely-called function and feel unfair.)

**Test:** catch fire with an incineration potion in pack → one detonation; with a Life potion in pack → never
detonates; confirm one detonation per ignition (walk back into fire → no double-trigger).

---

## Phase 5 — Passive sensory tells

**Goal:** each unidentified potion's inspect text gains a sensory adjective ("…a swirling crimson liquid that
feels **warm**…") clustering potions into Vital / Ethereal / Acrid, so blind-drinking is an informed gamble.
Clusters are deliberately *not* aligned to good/bad polarity (so it's not free detect-magic): Vital = {Life,
Strength, Fire Immunity, **Incineration**}; Ethereal = {Telepathy, Levitation, Detect Magic, Haste, Invisibility,
**Hallucination, Darkness**}; Acrid = {Caustic, Paralysis, Confusion, Descent, Lichen}. Membership is fixed data;
the surface adjective shuffles per game.

**Touch points:** new `enum potionSensoryTell` + an `int sensoryTell` field on `itemTable`
([Rogue.h:1433](BrogueCE/Engine/Rogue.h:1433)); adjective pools in `Globals.c`/`Globals.h` parallel to
`itemColors`; per-kind values in `potionTable_Brogue` ([GlobalsBrogue.c:665](BrogueCE/Engine/GlobalsBrogue.c:665))
using **designated initializers** (so variant tables don't default to 0); pick this game's adjectives by
**appending** a `rand_range` loop to the **tail** of `shuffleFlavors()`
([Items.c:7963](BrogueCE/Engine/Items.c:7963)); weave the adjective into the unidentified-potion intro at
[Items.c:1945](BrogueCE/Engine/Items.c:1945). One-line `itemName` untouched.

**Determinism:** the only new RNG is the adjective pick, appended after every existing shuffle → seeds/recordings
replay byte-identically.

**Test:** several fixed seeds — confirm each unidentified potion shows a cluster adjective, the adjective↔kind map
differs across seeds while cluster membership is stable, and it never equals detect-magic polarity.

---

## Phase 6 — Candidate-narrowing UI

**Goal:** an unidentified potion's inspect panel shows how far deduction has come — "one of **3** remaining
possibilities" (+ polarity if known, + per-cluster breakdown when Phase 5 shipped). Surfaces the bookkeeping the
player does by hand. **Never enumerates unidentified true names** (that would cheat) — count + polarity only.

**Touch points:** new static `candidatePotionKinds(const item*, short *out)` near the ID helpers
(≈[Items.c:5845](BrogueCE/Engine/Items.c:5845)), reusing `itemMagicPolarityIsKnown`
([5186](BrogueCE/Engine/Items.c:5186)) and per-kind `identified`/`magicPolarity` flags; render in `itemDetails`
after the unidentified-potion intro (≈[1993](BrogueCE/Engine/Items.c:1993)), gated
`category==POTION && !identified && !playbackOmniscience`, reusing the existing color escapes.

**Determinism:** pure display, recomputed each inspect. No RNG, no serialized state.

**Test:** detect-magic + identify some kinds + throw-test others → candidate count shrinks correctly and no
unidentified true name is ever printed.

---

## Phase 7 — Sacrificial insight altar (largest; new content)

**Goal:** a rare deep-dungeon altar (sibling to commutation/resurrection). Drop an unidentified potion/scroll on
it; the sacrifice is consumed and it reveals the **magic polarity of every unidentified consumable in your pack**,
then goes inert.

**Recommendation — whole-pile polarity reveal, not identify-one-item.** The commutation altar fires *passively*
from `updateFloorItems` with no prompt ([Items.c:1276-1293](BrogueCE/Engine/Items.c:1276)); a polarity reveal is a
silent batch op (reuse the detect-magic pack loop, [Items.c:7372-7382](BrogueCE/Engine/Items.c:7372)) that fits
that trigger with zero new UI. "Identify one chosen item" would require a blocking prompt inside automatic turn
processing (replay-desync hazard) — ~3× the work.

**Touch points (append-at-end everywhere):** `INSIGHT_ALTAR`/`INSIGHT_ALTAR_INERT` (tileType),
`DF_ALTAR_INSIGHT` (dungeonFeatureType), `MT_REWARD_INSIGHT_ALTAR` (machineTypes), a `TM_INSIGHT_ALTAR_ACTIVATION`
flag — all in `Rogue.h`; cloned `tileCatalog`/`dungeonFeatureCatalog` rows in `Globals.c` (model on commutation,
[532](BrogueCE/Engine/Globals.c:532)/[793](BrogueCE/Engine/Globals.c:793)); a `blueprintCatalog_Brogue` entry
cloned from resurrection ([GlobalsBrogue.c:227](BrogueCE/Engine/GlobalsBrogue.c:227)), depth `{13, AMULET_LEVEL}`,
low frequency; a sibling handler block in `updateFloorItems` calling a new `revealPolarityOfPack()`
(loop `packItems` → `detectMagicOnItem` → `tryIdentifyLastItemKinds`), consume the sacrifice, `activateMachine`
to promote inert.

**Determinism:** adding a blueprint shifts the depth-13+ reward-room raffle → all seeds diverge at the first deep
reward room (unavoidable for new content; document it, breaks shared seed catalogs at 13+). The handler adds no RNG.

**Test:** reach 13+ (seed/debug spawn), drop an unidentified potion → whole-pack polarity revealed, altar inert,
sacrifice consumed; drop an identified/non-consumable → no-op.

---

## Deferred / stretch (not committed)

- **Bespoke clouds for more good potions** (a haste-gas, a levitation-gas, etc.). Each needs *new* gas terrain +
  `T_CAUSES_*` mechanics + balance, so it's deferred until Phase 2 proves the pattern. Most good potions are
  better as Phase-1 single-target effects; only Life maps cleanly to an existing cloud. Revisit per appetite.

## Decisions (confirmed)

1. **Strength on a creature (Phase 1):** permanent **+maxHP** buff (smaller than Life), with a "looks stronger"
   tell. (No monster strength stat exists; maxHP is the physical-buff analog.)
2. **Life (Phase 1↔2):** direct-hit heal of the struck creature **and** an area healing cloud — both.
3. **Healing cloud heals enemies too** (`T_CAUSES_HEALING`) — accepted as the risk/tell tradeoff.
4. **Altar (Phase 7):** whole-pile polarity reveal (cheap, replay-safe), not identify-one-item.

## Cross-phase verification

- Build every phase via the **Xcode MCP server**.
- After Phases 1–4, **record a session** exercising throws, a bolt-triggered trap, and a fire detonation, then
  **replay it** → confirm zero desync (the determinism backbone of the whole arc).
- Spot-check that the **Classic engine** is untouched and still launches/plays from the title switch.
