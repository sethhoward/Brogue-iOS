# Identification Audit — Brogue SE (forked from BrogueCE 1.15)

How an item, or just its **polarity**, becomes known on the `feature/potion-id-rework` branch.
Engine: `BrogueSE/Engine/` (`Items.c`, `Combat.c`, `Time.c`, `Movement.c`, `Globals*.c`, `Rogue.h`).
Every mechanic is cited `file:line` and flagged **[vanilla]** (stock BrogueCE) or **[iOS]** (a port
modification, marked in source with `// iOS port (iBrogue):`). A few carry **[pending]** — built on
this branch but not yet playtest-signed-off, so behavior/tuning may still change; see
[../design/identification-future-ideas.md](../design/identification-future-ideas.md).

This documents the *current* behavior. For the change history and rationale, see
[IOS_MODIFICATIONS.md](../../BrogueSE/Engine/IOS_MODIFICATIONS.md); for base item stats and the
"how enchantments are applied" reference, see [ITEMS_AUDIT.md](ITEMS_AUDIT.md) §11.

> **Why this rework exists.** The old meta: find a potion of detect magic, polarity-check the whole
> pack at once, then chug/read the good ones (or, barring that, blind-chug everything). This branch
> nerfs that single dominant channel and spreads identification across many slower, deductive
> channels — so information becomes a resource bought with turns, risk, or opportunity cost.

---

## 1. The two-axis knowledge model

An item has **two** independent things you can learn:

- **Full identity** — kind + enchant level + runic. Flag `ITEM_IDENTIFIED` = `Fl(0)`
  ([Rogue.h:1464](../../BrogueSE/Engine/Rogue.h)). **[vanilla]**
- **Polarity** — benevolent / malevolent / neutral, *without* knowing the kind. Flag
  `ITEM_MAGIC_DETECTED` = `Fl(11)` ([Rogue.h:1475](../../BrogueSE/Engine/Rogue.h)). **[vanilla flag,
  iOS-expanded usage]**

Supporting flags: `ITEM_CAN_BE_IDENTIFIED` = `Fl(8)` (eligible for auto-ID by use,
[Rogue.h:1472](../../BrogueSE/Engine/Rogue.h)); `ITEM_DETECTED` = `Fl(12)`, a *cell* flag that
draws the polarity aura glyph on the map even for items you haven't picked up
([Rogue.h:1179](../../BrogueSE/Engine/Rogue.h)). **[vanilla]**

Which categories participate ([Rogue.h:832,837](../../BrogueSE/Engine/Rogue.h)) **[vanilla]**:

```
HAS_INTRINSIC_POLARITY = (POTION | SCROLL | RING | WAND | STAFF)
NEVER_IDENTIFIABLE     = (FOOD | CHARM | GOLD | AMULET | GEM | KEY)
```

Weapons and armor are not in `HAS_INTRINSIC_POLARITY` — their polarity is read from their
enchant/curse instead (see §2).

> **[iOS · 2026-06-15] The polarity-sensing channels scan the wider `CAN_BE_DETECTED`, not
> `HAS_INTRINSIC_POLARITY`.** `HAS_INTRINSIC_POLARITY` is the *kind-deduction* set (the elimination
> engine §3b only ever runs over it). But which items a channel can *sense* is a separate question, and
> the four sensing channels — detect magic drink (§5a) & throw (§5b), rest insight (§6a), and the
> freed-captive tell (§5g) — sense the full
> `CAN_BE_DETECTED = (WEAPON|ARMOR|POTION|SCROLL|RING|CHARM|WAND|STAFF|AMULET)`, so a weapon's or
> armor's good/bad aura (the sign of its enchant) is revealed like everything else. **This matches
> upstream CE's scope.** Earlier the SE rework narrowed these channels to `HAS_INTRINSIC_POLARITY`,
> which silently hid gear from detect magic — a bug (the *partial 1–2 reveal* that replaced CE's
> whole-pack reveal was the intended change; *excluding categories* was not). Eating insight (§6b) is
> the deliberate exception: it stays scroll-only by design. **Gear caps at the aura glyph** — a polarity
> channel never escalates a weapon/armor to a full enchant ID (that still comes from wearing/using it,
> exactly as in CE); once its aura is shown the gear drops out of eligibility
> (`polarityAuraAlreadyShownForGear`). The kind-flavored consumables keep the two-step
> reveal→escalate-to-ID behavior (§3a).

---

## 2. The polarity data model

Polarity constants ([Items.c:34–37](../../BrogueSE/Engine/Items.c)): `MAGIC_POLARITY_BENEVOLENT`
= +1, `MAGIC_POLARITY_MALEVOLENT` = −1, `MAGIC_POLARITY_NEUTRAL` = 0 (and `MAGIC_POLARITY_ANY` = 0,
the "ignore polarity" sentinel). **[vanilla]**

Two ways polarity is stored:

- **Per-kind, intrinsic** — `itemTable.magicPolarity` (the flavor's true polarity) and
  `itemTable.magicPolarityRevealed` (set once *any* instance of that kind has been polarity-sensed,
  so the knowledge sticks across the run for that whole flavor). See `magicPolarity` column in
  [ITEMS_AUDIT.md](ITEMS_AUDIT.md). **[vanilla data, iOS-expanded]**
- **Computed per-item** — `itemMagicPolarity()` ([Items.c:9123](../../BrogueSE/Engine/Items.c)):
  for potions/scrolls/staffs/charms it returns the table value; for **weapons, armor, and rings**
  it derives polarity from the instance — cursed or `enchant1 < 0` → malevolent, `> 0` → benevolent,
  `0` → neutral; a 0-charge wand is neutral; the amulet is always benevolent. **[vanilla]**

`itemMagicPolarityIsKnown(theItem, polarity)` ([Items.c:5704](../../BrogueSE/Engine/Items.c)) is the
read predicate: true if the item (or its kind) is known and its polarity equals `polarity`. **[vanilla]**

---

## 3. The two cross-cutting engines (the heart of the rework) **[iOS]**

Almost every channel below routes through one of these two shared mechanisms, which is what makes
the new system *compound*: scattered partial clues converge into full IDs.

### 3a. Escalation — a second signal finishes the job

`revealOrIdentifyPolarityItem()` ([Items.c:8263–8282](../../BrogueSE/Engine/Items.c)):

```
polarity unknown  → detectMagicOnItem()   // reveal good/bad only
polarity known    → identify()            // escalate to a full ID
```

So sensing polarity once arms the item; the *next* polarity signal of any kind (rest, eating,
detect magic, altar) completes it. The shared insight helper
`applyPolarityInsightToRandomItem()` ([Items.c:8291–8330](../../BrogueSE/Engine/Items.c))
deliberately keeps already-sensed items in its candidate pool so escalation can happen.

### 3b. Elimination deduction — process of elimination auto-IDs the last one

After *every* reveal, `tryIdentifyLastItemKinds(HAS_INTRINSIC_POLARITY)`
([Items.c:6443–6459](../../BrogueSE/Engine/Items.c)) runs the deduction:
`tryIdentifyLastItemKind()` ([Items.c:6420–6439](../../BrogueSE/Engine/Items.c)) fully identifies
the last unknown kind in a category-and-polarity when **every counterpart of the opposite polarity
is already known** — counted by `magicPolarityRevealedItemKindCount()`
([Items.c:6394–6410](../../BrogueSE/Engine/Items.c)). Example: once all the *bad* potions are
accounted for, the last unknown good potion must be the remaining good kind, so it IDs itself.

---

## 4. Auto-identification by use **[vanilla]**

Equipment IDs itself through use. Thresholds live in the per-variant globals
(`GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c`), set onto `charges` at
creation ([Items.c:286,296,364](../../BrogueSE/Engine/Items.c)) and counted down:

| Equipment | Counter | Decremented in | On zero |
|---|---|---|---|
| **Weapon** | `weaponKillsToAutoID` kills | `decrementWeaponAutoIDTimer()` [Combat.c:1154–1168](../../BrogueSE/Engine/Combat.c) (per kill) | sets `ITEM_IDENTIFIED` |
| **Armor** | `armorDelayToAutoID` turns worn | `autoIDItems()` [Time.c:1882–1913](../../BrogueSE/Engine/Time.c) (per turn) | sets `ITEM_IDENTIFIED` — reveals it *has* a runic, not which ([Time.c:1901](../../BrogueSE/Engine/Time.c)) |
| **Ring** | `ringDelayToAutoID` turns worn | `autoIDItems()` [Time.c:1882–1913](../../BrogueSE/Engine/Time.c) (per turn) | full `identify()` ([Time.c:1903](../../BrogueSE/Engine/Time.c)) |

**Ring of wisdom accelerates the worn-gear timers [iOS port].** For **armor and rings** (not weapons), the
per-turn countdown in `processIncrementalAutoID()` subtracts `wisdomAutoIDChargeStep()` instead of a flat 1
([Items.c](../../BrogueSE/Engine/Items.c), [Time.c](../../BrogueSE/Engine/Time.c)). The base requirement
(`charges`) is never lowered; the countdown just ticks faster — ~10% per net wisdom enchant, capped at +50%
(2× speed), and a *cursed* wisdom ring slows it to −100% (2× slower), matching the other wisdom levers
(rest-insight, recharge). It's a Bresenham step on `rogue.absoluteTurnNumber` (averages `100/(100−reductionPct)`
charges/turn as an integer 0/1/2 — banked, deterministic, no new field). The inspector's "worn for N turns"
line shows the wisdom-adjusted estimate. Levers: `WISDOM_AUTOID_PCT_PER_LEVEL` / `WISDOM_AUTOID_MAX_FASTER_PCT`
/ `WISDOM_AUTOID_MAX_SLOWER_PCT`.

See the [tuning table](#8-tuning-reference) for the per-variant values. A non-positive ring also
auto-IDs by elimination on equip (upstream issue #683; see
[pr-notes-ring-equip-deduction issue 683.md](../notes/pr-notes-ring-equip-deduction%20issue%20683.md)).

---

## 5. Active channels (spend a turn or an item)

### 5a. Detect magic — drink **[iOS]**
`quaffDetectMagic()` ([Items.c:8439–8488](../../BrogueSE/Engine/Items.c)). Acts on **1–2** random
unidentified, polarity-bearing pack items (excluding the potion being drunk), via the escalation
rule (§3a) — a weaker, fleeting version of the old whole-pack reveal. A worn ring of wisdom widens
the spread to `1–(2 + wisdomBonus)` ([Items.c:8459](../../BrogueSE/Engine/Items.c)). Then runs the
elimination pass (§3b). **Scans `CAN_BE_DETECTED`** (incl. weapons/armor — see the §2 note); gear
reveals its aura glyph but never escalates to a full enchant ID.

### 5b. Detect magic — throw **[iOS]**
`throwDetectMagicOnFloor()` ([Items.c:8495–8529](../../BrogueSE/Engine/Items.c)). Turns the insight
*outward*: senses 1–2 (same wisdom scaling) random undiscovered, polarity-bearing items lying on
the **floor** of this level, revealing each one's polarity and lighting its map aura
(`ITEM_DETECTED` cell flag, [Items.c:8520](../../BrogueSE/Engine/Items.c)) — the classic "detect
magic on the level" feel. The thrown potion self-IDs. **Scans `CAN_BE_DETECTED`** (incl.
weapons/armor); a floor weapon/armor lights its good/bad aura on the map like any other item.

### 5c. Throwing / shattering a potion **[iOS, on a vanilla base]**
`shatterPotionAtLoc()` ([Items.c:6642–6760](../../BrogueSE/Engine/Items.c)). A bad/cloud potion
that shatters spawns its visible signature (gas cloud / terrain burst) and then **full-`autoIdentify`s**
([Items.c:6756](../../BrogueSE/Engine/Items.c)) — the effect *is* the tell.

> **Fire-erasure special case** ([Items.c:6729–6750](../../BrogueSE/Engine/Items.c)): a fire trigger
> (fire bolt / incendiary dart) erases the tell of two groups, which then reveal **polarity only**
> (`detectMagicOnItem`, not a full ID), and only if the player sees the burst: *"the volatile flask
> bursts into flame — you sense its contents were benevolent/malevolent."*
> - **Flammable gas clouds** (poison/confusion/paralysis/vomit): a tile whose **GAS layer** is
>   flammable ignites into indistinguishable flame the same instant (data-driven on `T_IS_FLAMMABLE`,
>   GAS layer only — so honey's flammable *surface* net doesn't qualify).
> - **Incineration** (explicit `POTION_INCINERATION` case): its tell *is* fire, so the trigger's own
>   flame masks it completely — you can't tell it from the bolt/dart burst. (Its fire sits on the
>   SURFACE layer, so matching `T_IS_FIRE` broadly would wrongly catch any potion detonated on
>   already-burning ground; hence the explicit case.)
>
> Non-fire triggers, and fire triggers of self-evident effects (wort, honey, darkness, descent, flood,
> lichen, fungal forest, steam, ice, acid), still **full-ID**.

### 5d. Dart / javelin detonation **[iOS]**
`detonateFloorPotionAt()` ([Items.c:6917–6926](../../BrogueSE/Engine/Items.c)). A thrown dart or
javelin striking a *dropped* bad/cloud potion detonates it through the same `shatterPotionAtLoc()`
path (an incendiary dart detonates fiery, like a fire bolt; a plain dart/javelin detonates
unignited, like a lightning bolt). Good potions and the empty bottle are left untouched — a dart
isn't a bolt and can't capture.

### 5e′. Altars of divination **[Brogue SE]** — the live altar ID channel
`performDivination()` ([Items.c](../../BrogueSE/Engine/Items.c)). The current altar identify channel (replaces
§5e). A guaranteed once-per-run reward room: a central totem with up to four one-use **divination altars**.
Place an unidentified item on an active altar → it is fully `identify()`d (no offering/payment — unlike insight)
→ the altar arms (holds the revealed item) and seals shut when the item is lifted. "Fire only if it helps": a
known item is a no-op. **Cost = a push-your-luck threat, not a sacrificed item:** each identify (room-scoped
`rogue.divinationAltarUses`) rolls **0/25/50/75%** to awaken the totem's single tiered guardian (Ogre→Troll→
Underworm by trigger-use); on an awaken the unused altars shatter. **Substantive** (`rand_percent`) — unlike the
RNG-free insight altar, this channel touches the seed. See MACHINES_AUDIT §7f and `docs/design/altars-of-
divination.md`.

### 5e. Altars of insight **[iOS]** — DEPRECATED (Brogue SE): no longer generated (see §5e′)
`performInsightSacrifice()` ([Items.c:8601–8671](../../BrogueSE/Engine/Items.c)). A linked altar
pair (`INSIGHT_ALTAR_INSIGHT` reveals, `INSIGHT_ALTAR_PAYMENT` is consumed). The cost shapes the
reward:
- **Sacrifice an *un*identified item** → fully `identify()` the offered item
  ([Items.c:8633](../../BrogueSE/Engine/Items.c)) — the gamble pays the most.
- **Sacrifice an *identified* item** → reveal the offered item's polarity, or escalate to full ID
  if its polarity was already known ([Items.c:8647](../../BrogueSE/Engine/Items.c)).
- "Fire only if it helps": the payment is never consumed unless the offered item actually gains
  information ([Items.c:8631,8645](../../BrogueSE/Engine/Items.c)). RNG-free.

See [pr-notes-insight-altar phase 7.md](../notes/pr-notes-insight-altar%20phase%207.md).

### 5f. Witnessing a scroll burn **[iOS · pending]**
`revealPolarityOnFieryDestruction()` ([Items.c:8196](../../BrogueSE/Engine/Items.c)), called from
`burnItem()` ([Time.c:902](../../BrogueSE/Engine/Time.c)) before the item is freed, gated on
`playerCanSee`. The **scroll-side mirror of §5c's fire-erasure**: scrolls are the only
`ITEM_FLAMMABLE` item, and you never burn one on purpose, so the insight comes from *witnessing* the
accident (incineration burst, fire trap, flaming gas). Reveals **polarity only** (`detectMagicOnItem`,
persisted at the kind level so it survives the item's deletion), then escalates (§3a) / runs the
elimination pass (§3b): *"as it burns you glimpse a benevolent/malevolent aura curling in the smoke."*
No-op on already-identified, neutral, or already-polarity-known kinds. No RNG.

### 5g. Freed-captive reaction **[iOS · pending]**
`captiveReactToPack()` ([Items.c:8231](../../BrogueSE/Engine/Items.c)), called from `freeCaptive()`
([Movement.c:541](../../BrogueSE/Engine/Movement.c)). On rescue, the captive reacts to what it senses
in your pack — revealing the **polarity** (not the kind) of the first unidentified item of the
relevant sign whose aura you don't already know:
- **Monkey** (`MK_MONKEY`) → covets a **benevolent** item: *"the monkey eyes <item> in your pack
  covetously."* Leans on `itemMagicPolarity`, **not** the narrow steal profile (§7a), so any good
  ring/staff/charm — **or weapon/armor** — counts.
- **Any other captive** → recoils from a **malevolent** item: *"the … shies warily from <item>."* A
  free curse-warning (now including a cursed/negative weapon or armor). **Silent no-op when you carry
  no malevolent item** (by design).

One tell per rescue; polarity reveal only (no escalation — gear caps at the aura glyph). **Scans
`CAN_BE_DETECTED`** (incl. weapons/armor — see the §2 note). Picks the first eligible item in pack
order (`itemMagicPolarity` is only ±1/0 — no finer gradient); because the pack sorts by ascending
category and `WEAPON(1)`/`ARMOR(2)` precede the consumables, an unsensed good/bad piece of gear is the
first thing a captive points at. No RNG. Also fires for tunnel-freed captives
(`freeCaptivesEmbeddedAt` → `freeCaptive`), but not for clone-made allies.

### 5h. Ring of clairvoyance — arrival floor sense **[iOS]**
`senseFloorPolarityFromClairvoyance()` ([Items.c](../../BrogueSE/Engine/Items.c), after
`throwDetectMagicOnFloor`), called once from `startLevel()` on **first arrival** at a level (the
`!visited` branch, beside the room-machine sense). A worn ring of clairvoyance senses the polarity of
items lying on the **floor** of the new level — *secret rooms included* — lighting each one's map aura
(`ITEM_DETECTED` cell flag) and recording it via `detectMagicOnItem` (kind-level for consumables, so it
feeds §3a/§3b). **Polarity only — not a full `identify()`:** a floor potion/scroll's exact *kind* stays
hidden, and gear shows its good/bad aura, never the enchant number. *(Moved 2026-06-28 off the ring of
awareness.)* The pool is **every non-neutral magical floor item** (`CAN_BE_DETECTED`, non-neutral) —
*including* ones whose polarity you already know (identified kind, or `ITEM_MAGIC_DETECTED`): a known item
teaches nothing, but lighting its map aura is a location / secret-room breadcrumb. Still-unknown items are
**prioritized** (stable-partitioned to the front, drawn first to learn their polarity); the N only spills onto
already-known items (location mark only) once the unknowns run out. It's a *standing* radar twin of §5b.
- **Count scales directly with the ring**, gated on `clairvoyance > 0` (no ring / cursed → senses nothing,
  no RNG). It senses **exactly N = `rogue.clairvoyance` items, guaranteed** (no per-item chance) — `enchant`
  is the raw net enchant, **not** ×20 like `awarenessBonus`. **Uncapped** beyond floor contents: if fewer
  than N eligible items exist, all are sensed; if more, N are chosen at **random** (partial Fisher-Yates).
  This is the old awareness sense "but better" — the ring level *is* the number of auras revealed.
- **First arrival only** (closes the stair-bounce re-roll exploit, same as the machine sense). **No
  visibility filter** — it runs before the player is positioned, and detecting a soon-to-be-visible item
  still records its polarity for the pack. Action-triggered RNG on the gameplay stream, replay-stable. See
  IOS_MODIFICATIONS.md (2026-06-28; supersedes 2026-06-15).

---

## 6. Passive channels (knowledge accrues over time) **[iOS]**

Both share `applyPolarityInsightToRandomItem()`
([Items.c:8291–8330](../../BrogueSE/Engine/Items.c)) — pick a random eligible item (escalation rule
§3a), then run the elimination pass (§3b). The random pick is action-triggered and replay-stable
(saves are recordings).

> **Eligibility guard.** "Already known" is tested with `itemIdentityFullyKnown()`, not the bare
> per-item `ITEM_IDENTIFIED` flag: a **scroll/potion** is fully known once its *kind* is identified
> (no per-item enchant), so a copy with a clear instance flag still counts as known and is excluded —
> otherwise insight would re-"identify" it. Rings/wands/staffs keep a per-item enchant, so for them
> only the instance flag counts and they stay eligible until fully ID'd. Shared by every polarity
> selection guard (rest, eating, detect-magic drink/throw, the insight altar, and the §5f/§5g tells).

### 6a. Rest insight
`gainPolarityInsightFromRest()` ([Items.c:8357–8398](../../BrogueSE/Engine/Items.c)), called once
per rested turn from `playerTurnEnded` ([Time.c:2748](../../BrogueSE/Engine/Time.c), gated on
`rogue.justRested`). Each rested turn accrues toward an **escalating threshold**: reveal *N* needs
`REST_INSIGHT_BASE_TURNS` (80) + `REST_INSIGHT_STEP_TURNS` (30) × reveals-earned-so-far rested turns
*since the last reveal* (the counter resets on each reveal) — intervals 80, 110, 140… (cumulative
80, 190, 330, 500…), keyed off reveals earned so far. *(The earlier `100 × N` ramp — cumulative 100,
300, 600 — was rejected: its 2nd reveal at 300 cumulative turns rarely fired on a depth-1..10 run.
This lower base + gentle additive step is tuned to fire ~2–3 times by depth 10.)* **Favors potions**
when any eligible potion exists. A ring of wisdom
accelerates it ~10%/level (clamped). **Scans `CAN_BE_DETECTED`** (incl. weapons/armor — see the §2
note): when no unidentified potion is left to favor, the secondary pool now includes gear (capped at
the aura glyph). See
[pr-notes-rest-polarity-insight phase 8.md](../notes/pr-notes-rest-polarity-insight%20phase%208.md).

### 6b. Eating insight
`gainScrollInsightFromEating()` ([Items.c:8406–8431](../../BrogueSE/Engine/Items.c)), called from
`eat()` ([Items.c:7583](../../BrogueSE/Engine/Items.c)). A safe meal — **nothing in the
`MONSTER_TRACKING_SCENT` (hunting) state** ([Items.c:8409](../../BrogueSE/Engine/Items.c)) — is a
calm moment to study one random unknown **scroll**. **This is the deliberate single-category
exception**: unlike the other channels it stays `SCROLL`-only (potions are the rest channel's job), so
it was *not* widened to `CAN_BE_DETECTED`. See
[pr-notes-eat-scroll-insight phase 9.md](../notes/pr-notes-eat-scroll-insight%20phase%209.md).

---

## 7. Indirect / deductive tells (information, not a direct reveal)

### 7a. Monkey / imp theft preference **[iOS]**
`rateItemStealDesirability()` ([Combat.c:398–426](../../BrogueSE/Engine/Combat.c)) scores items
against a data-driven `stealProfile` ([Globals.c:1139–1162](../../BrogueSE/Engine/Globals.c)).
*What gets stolen is a clue to what it is:*

- **Monkey** (`monkeyStealProfile`): big bonus (+290) to **food, potion of life, potion of
  strength**; ADDITIVE base 10 so it'll grab anything; 5% random. A potion a monkey ran off with is
  *probably* life or strength.
- **Imp** (`impStealProfile`): scroll of enchanting (+50), positively-enchanted gear (+5/enchant),
  runics (+25), dislikes food (−8). An item the imp wanted is *probably* good/enchanted.

See [reusable-components.md](../guides/reusable-components.md) (the steal component) and
[IOS_MODIFICATIONS.md](../../BrogueSE/Engine/IOS_MODIFICATIONS.md) "Deductive thievery". A *freed*
monkey gives a separate, **direct** polarity tell — see §5g (it uses polarity, not this steal profile).

### 7b. Empty-bottle capture **[iOS]**
`fillEmptyBottle()` ([Items.c:6766](../../BrogueSE/Engine/Items.c)): capturing a gas/liquid (or a
bolt) turns the always-identified empty bottle into the matching, **already-identified** potion —
and auto-IDs that kind, so matching unidentified potions in the pack become known too. See
[TERRAIN_AUDIT.md](TERRAIN_AUDIT.md) §empty-bottle and
[docs/design/empty-bottle-v2.md](../design/empty-bottle-v2.md).

### 7c. Benevolent-potion glow **[iOS]**
A dropped good potion glows warmly when a bolt passes through it — a free polarity tell for the
observant (see [IOS_MODIFICATIONS.md](../../BrogueSE/Engine/IOS_MODIFICATIONS.md), phase 3 polish).

---

## 8. Tuning reference

One place for every scalar, so balancing doesn't mean spelunking ten files.

### Auto-ID by use — per game variant ([Globals*.c](../../BrogueSE/Engine/GlobalsBrogue.c))
| Constant | Brogue | RapidBrogue | BulletBrogue |
|---|---|---|---|
| `weaponKillsToAutoID` | 20 kills | 5 | 2 |
| `armorDelayToAutoID` | 1000 turns | 250 | 120 |
| `ringDelayToAutoID` | 1500 turns | 250 | 120 |

### Insight & detect magic
| Knob | Value | Cite |
|---|---|---|
| Rest reveal threshold | `REST_INSIGHT_BASE_TURNS` (80) + `REST_INSIGHT_STEP_TURNS` (30) × reveals earned, rested turns | [Items.c:8354–8363](../../BrogueSE/Engine/Items.c) |
| Ring of wisdom speedup | −10% threshold per ring level; clamped (max 80% faster, max 2× slower) | [Items.c:8366–8369](../../BrogueSE/Engine/Items.c) |
| Detect magic spread (drink & throw) | `rand_range(1, 2 + wisdomBonus)` items | [Items.c:8458,8512](../../BrogueSE/Engine/Items.c) |
| Eating insight gate | no creature in `MONSTER_TRACKING_SCENT` | [Items.c:8409](../../BrogueSE/Engine/Items.c) |
| Clairvoyance floor-sense count (§5h) | `N = rogue.clairvoyance`, **guaranteed** (uncapped, ≤ eligible floor items); N random picks, polarity only | [Items.c](../../BrogueSE/Engine/Items.c) `senseFloorPolarityFromClairvoyance` |

### Theft desirability ([Combat.c:398](../../BrogueSE/Engine/Combat.c) `rateItemStealDesirability`; per-thief weights are now component data in the catalog `steal` field — see [reusable-components.md](../guides/reusable-components.md))
| Thief | Bonuses (over base 10, additive) | Random pick |
|---|---|---|
| Monkey | food +290, potion of life +290, potion of strength +290 | 5% |
| Imp | scroll of enchanting +50, +enchant×5 on positive gear, runic +25, food −8 | 5% |

---

## 9. Cross-references

- [ITEMS_AUDIT.md](ITEMS_AUDIT.md) — base item stats, `magicPolarity` per kind, §11 "how
  enchantments are applied" (auto-ID thresholds in their original context).
- [TERRAIN_AUDIT.md](TERRAIN_AUDIT.md) — the empty-bottle capture map and gap analysis.
- [IOS_MODIFICATIONS.md](../../BrogueSE/Engine/IOS_MODIFICATIONS.md) — per-change history & rationale
  for every **[iOS]** mechanic above.
- Phase notes (in `docs/notes/`): `potion-id-rework-plan.md` (master plan),
  `pr-notes-potion-throw-good-effects phase 1+2.md`, `pr-notes-potion-bolt-detonation phase 3.md`,
  `pr-notes-insight-altar phase 7.md`, `pr-notes-rest-polarity-insight phase 8.md`,
  `pr-notes-eat-scroll-insight phase 9.md`, `pr-notes-ring-equip-deduction issue 683.md`.
