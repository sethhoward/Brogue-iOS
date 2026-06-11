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
- `Architect.c` — a new `placeInsightAltarsInRoom()` (with helpers `insightAltarCellIsOpen` /
  `setInsightAltar`) places the pair after the room is built, called from the `addMachines` force-build
  right after `buildAMachine(MT_INSIGHT_ALTAR, …)` succeeds. It finds the just-built room's carpet cells
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

- **Stand-in capture** (gases / deep water): caustic→caustic gas, confusion→confusion, paralysis→paralysis,
  rot→creeping death, darkness cloud→darkness, healing spores→life, deep water→fire immunity.
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
  helper; prototype in `Rogue.h`.
- `Items.c` `updateBolt` — empty-bottle branch *before* `shatterPotionAtLoc`, keyed on `BF_ELECTRIC`/`BF_FIERY`,
  sets `terminateBolt = true`.
- `Items.c` `drinkPotion` — the `POTION_DETECT_MAGIC` case is now inert ("the bottle is empty…") and returns
  `false` so it is neither consumed nor costs a turn (replaces the old detect-magic quaff effect).
- `Time.c` new `captureElementIntoEmptyBottle()`, called once per player turn from
  `applyGradualTileEffectsToCreature`.

**Determinism.** Generation behavior changes (frequency, and the kind is now always-identified), so the
weighted pick / ID bookkeeping diverge from pre-change recordings — a `recordingVersionString` bump at
release is warranted. Capture mutates only existing item/level state (no new RNG call sites). Removing
detect magic from the unidentified-potion pool slightly shifts the `tryIdentifyLastItemKinds` deduction
counts (one fewer good potion to deduce) — intended.

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

## Platform functions implemented in `CEBridge.mm`

These engine-declared platform functions were upstream stubs in this port and are now
implemented in the bridge (not the engine C, but listed here for orientation):

- `listFiles` — enumerates the CE save directory for the Load/Replay pickers.
- `getHighScoresList` / `saveHighScore` — local high scores (NSUserDefaults, CE keys).
- `saveRunHistory` / `saveResetRun` / `loadRunHistory` — the lifetime game-stats
  history (NSUserDefaults, CE keys; `seed == 0` is the "reset recent stats" sentinel).

Still stubbed: `takeScreenshot`, `notifyEvent` (the latter is where CE → Game Center
score/achievement reporting would hook in; CE high scores are currently local-only).

---

## Adding a new CE engine tweak

1. Prefer a host hook: declare `extern void ce<Thing>(...);` at the top of the engine
   file, call it where needed (with an `// iOS port (iBrogue):` comment), define it in
   `CEBridge.mm` inside `extern "C"`, add the matching `BrogueCEHost` method, and
   forward it from `CEHost.swift` to `BrogueViewController`.
2. For control visibility, reuse `uiMode` (write-only signal) rather than adding new
   plumbing where a mode value already conveys the intent.
3. Record the change here (what / why / where / gating).
