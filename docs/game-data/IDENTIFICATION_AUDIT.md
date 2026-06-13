# Identification Audit — BrogueCE 1.15 (iOS port)

How an item, or just its **polarity**, becomes known on the `feature/potion-id-rework` branch.
Engine: `BrogueCE/Engine/` (`Items.c`, `Combat.c`, `Time.c`, `Globals*.c`, `Rogue.h`). Every
mechanic is cited `file:line` and flagged **[vanilla]** (stock BrogueCE) or **[iOS]** (a port
modification, marked in source with `// iOS port (iBrogue):`).

This documents the *current* behavior. For the change history and rationale, see
[IOS_MODIFICATIONS.md](../../BrogueCE/Engine/IOS_MODIFICATIONS.md); for base item stats and the
"how enchantments are applied" reference, see [ITEMS_AUDIT.md](ITEMS_AUDIT.md) §11.

> **Why this rework exists.** The old meta: find a potion of detect magic, polarity-check the whole
> pack at once, then chug/read the good ones (or, barring that, blind-chug everything). This branch
> nerfs that single dominant channel and spreads identification across many slower, deductive
> channels — so information becomes a resource bought with turns, risk, or opportunity cost.

---

## 1. The two-axis knowledge model

An item has **two** independent things you can learn:

- **Full identity** — kind + enchant level + runic. Flag `ITEM_IDENTIFIED` = `Fl(0)`
  ([Rogue.h:1434](../../BrogueCE/Engine/Rogue.h)). **[vanilla]**
- **Polarity** — benevolent / malevolent / neutral, *without* knowing the kind. Flag
  `ITEM_MAGIC_DETECTED` = `Fl(11)` ([Rogue.h:1445](../../BrogueCE/Engine/Rogue.h)). **[vanilla flag,
  iOS-expanded usage]**

Supporting flags: `ITEM_CAN_BE_IDENTIFIED` = `Fl(8)` (eligible for auto-ID by use,
[Rogue.h:1442](../../BrogueCE/Engine/Rogue.h)); `ITEM_DETECTED` = `Fl(12)`, a *cell* flag that
draws the polarity aura glyph on the map even for items you haven't picked up
([Rogue.h:1166](../../BrogueCE/Engine/Rogue.h)). **[vanilla]**

Which categories participate ([Rogue.h:820,825](../../BrogueCE/Engine/Rogue.h)) **[vanilla]**:

```
HAS_INTRINSIC_POLARITY = (POTION | SCROLL | RING | WAND | STAFF)
NEVER_IDENTIFIABLE     = (FOOD | CHARM | GOLD | AMULET | GEM | KEY)
```

Weapons and armor are not in `HAS_INTRINSIC_POLARITY` — their polarity is read from their
enchant/curse instead (see §2).

---

## 2. The polarity data model

Polarity constants ([Items.c:34–37](../../BrogueCE/Engine/Items.c)): `MAGIC_POLARITY_BENEVOLENT`
= +1, `MAGIC_POLARITY_MALEVOLENT` = −1, `MAGIC_POLARITY_NEUTRAL` = 0 (and `MAGIC_POLARITY_ANY` = 0,
the "ignore polarity" sentinel). **[vanilla]**

Two ways polarity is stored:

- **Per-kind, intrinsic** — `itemTable.magicPolarity` (the flavor's true polarity) and
  `itemTable.magicPolarityRevealed` (set once *any* instance of that kind has been polarity-sensed,
  so the knowledge sticks across the run for that whole flavor). See `magicPolarity` column in
  [ITEMS_AUDIT.md](ITEMS_AUDIT.md). **[vanilla data, iOS-expanded]**
- **Computed per-item** — `itemMagicPolarity()` ([Items.c:8847](../../BrogueCE/Engine/Items.c)):
  for potions/scrolls/staffs/charms it returns the table value; for **weapons, armor, and rings**
  it derives polarity from the instance — cursed or `enchant1 < 0` → malevolent, `> 0` → benevolent,
  `0` → neutral; a 0-charge wand is neutral; the amulet is always benevolent. **[vanilla]**

`itemMagicPolarityIsKnown(theItem, polarity)` ([Items.c:5680](../../BrogueCE/Engine/Items.c)) is the
read predicate: true if the item (or its kind) is known and its polarity equals `polarity`. **[vanilla]**

---

## 3. The two cross-cutting engines (the heart of the rework) **[iOS]**

Almost every channel below routes through one of these two shared mechanisms, which is what makes
the new system *compound*: scattered partial clues converge into full IDs.

### 3a. Escalation — a second signal finishes the job

`revealOrIdentifyPolarityItem()` ([Items.c:8105–8114](../../BrogueCE/Engine/Items.c)):

```
polarity unknown  → detectMagicOnItem()   // reveal good/bad only
polarity known    → identify()            // escalate to a full ID
```

So sensing polarity once arms the item; the *next* polarity signal of any kind (rest, eating,
detect magic, altar) completes it. The shared insight helper
`applyPolarityInsightToRandomItem()` ([Items.c:8123–8160](../../BrogueCE/Engine/Items.c))
deliberately keeps already-sensed items in its candidate pool so escalation can happen.

### 3b. Elimination deduction — process of elimination auto-IDs the last one

After *every* reveal, `tryIdentifyLastItemKinds(HAS_INTRINSIC_POLARITY)`
([Items.c:6412–6427](../../BrogueCE/Engine/Items.c)) runs the deduction:
`tryIdentifyLastItemKind()` ([Items.c:6389–6407](../../BrogueCE/Engine/Items.c)) fully identifies
the last unknown kind in a category-and-polarity when **every counterpart of the opposite polarity
is already known** — counted by `magicPolarityRevealedItemKindCount()`
([Items.c:6363–6378](../../BrogueCE/Engine/Items.c)). Example: once all the *bad* potions are
accounted for, the last unknown good potion must be the remaining good kind, so it IDs itself.

---

## 4. Auto-identification by use **[vanilla]**

Equipment IDs itself through use. Thresholds live in the per-variant globals
(`GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c`), set onto `charges` at
creation ([Items.c:280,290,358](../../BrogueCE/Engine/Items.c)) and counted down:

| Equipment | Counter | Decremented in | On zero |
|---|---|---|---|
| **Weapon** | `weaponKillsToAutoID` kills | `decrementWeaponAutoIDTimer()` [Combat.c:1154–1168](../../BrogueCE/Engine/Combat.c) (per kill) | sets `ITEM_IDENTIFIED` |
| **Armor** | `armorDelayToAutoID` turns worn | `autoIDItems()` [Time.c:1855–1885](../../BrogueCE/Engine/Time.c) (per turn) | sets `ITEM_IDENTIFIED` — reveals it *has* a runic, not which ([Time.c:1872](../../BrogueCE/Engine/Time.c)) |
| **Ring** | `ringDelayToAutoID` turns worn | `autoIDItems()` [Time.c:1855–1885](../../BrogueCE/Engine/Time.c) (per turn) | full `identify()` ([Time.c:1875](../../BrogueCE/Engine/Time.c)) |

See the [tuning table](#8-tuning-reference) for the per-variant values. A non-positive ring also
auto-IDs by elimination on equip (upstream issue #683; see
[pr-notes-ring-equip-deduction issue 683.md](../pr-notes-ring-equip-deduction%20issue%20683.md)).

---

## 5. Active channels (spend a turn or an item)

### 5a. Detect magic — drink **[iOS]**
`quaffDetectMagic()` ([Items.c:8257–8300](../../BrogueCE/Engine/Items.c)). Acts on **1–2** random
unidentified, polarity-bearing pack items (excluding the potion being drunk), via the escalation
rule (§3a) — a weaker, fleeting version of the old whole-pack reveal. A worn ring of wisdom widens
the spread to `1–(2 + wisdomBonus)` ([Items.c:8275](../../BrogueCE/Engine/Items.c)). Then runs the
elimination pass (§3b).

### 5b. Detect magic — throw **[iOS]**
`throwDetectMagicOnFloor()` ([Items.c:8309–8342](../../BrogueCE/Engine/Items.c)). Turns the insight
*outward*: senses 1–2 (same wisdom scaling) random undiscovered, polarity-bearing items lying on
the **floor** of this level, revealing each one's polarity and lighting its map aura
(`ITEM_DETECTED` cell flag, [Items.c:8333](../../BrogueCE/Engine/Items.c)) — the classic "detect
magic on the level" feel. The thrown potion self-IDs.

### 5c. Throwing / shattering a potion **[iOS, on a vanilla base]**
`shatterPotionAtLoc()` ([Items.c:6611–6724](../../BrogueCE/Engine/Items.c)). A bad/cloud potion
that shatters spawns its visible signature (gas cloud / terrain burst) and then **full-`autoIdentify`s**
([Items.c:6720](../../BrogueCE/Engine/Items.c)) — the effect *is* the tell.

> **Fire-erasure special case** ([Items.c:6694–6715](../../BrogueCE/Engine/Items.c)): a fire trigger
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
`detonateFloorPotionAt()` ([Items.c:6881–6890](../../BrogueCE/Engine/Items.c)). A thrown dart or
javelin striking a *dropped* bad/cloud potion detonates it through the same `shatterPotionAtLoc()`
path (an incendiary dart detonates fiery, like a fire bolt; a plain dart/javelin detonates
unignited, like a lightning bolt). Good potions and the empty bottle are left untouched — a dart
isn't a bolt and can't capture.

### 5e. Altars of insight **[iOS]**
`performInsightSacrifice()` ([Items.c:8350–8420](../../BrogueCE/Engine/Items.c)). A linked altar
pair (`INSIGHT_ALTAR_INSIGHT` reveals, `INSIGHT_ALTAR_PAYMENT` is consumed). The cost shapes the
reward:
- **Sacrifice an *un*identified item** → fully `identify()` the offered item
  ([Items.c:8382](../../BrogueCE/Engine/Items.c)) — the gamble pays the most.
- **Sacrifice an *identified* item** → reveal the offered item's polarity, or escalate to full ID
  if its polarity was already known ([Items.c:8396](../../BrogueCE/Engine/Items.c)).
- "Fire only if it helps": the payment is never consumed unless the offered item actually gains
  information ([Items.c:8380,8394](../../BrogueCE/Engine/Items.c)). RNG-free.

See [pr-notes-insight-altar phase 7.md](../pr-notes-insight-altar%20phase%207.md).

---

## 6. Passive channels (knowledge accrues over time) **[iOS]**

Both share `applyPolarityInsightToRandomItem()`
([Items.c:8123–8160](../../BrogueCE/Engine/Items.c)) — pick a random eligible item (escalation rule
§3a), then run the elimination pass (§3b). The random pick is action-triggered and replay-stable
(saves are recordings).

### 6a. Rest insight
`gainPolarityInsightFromRest()` ([Items.c:8178–8217](../../BrogueCE/Engine/Items.c)), called once
per rested turn from `playerTurnEnded` ([Time.c:2693](../../BrogueCE/Engine/Time.c), gated on
`rogue.justRested`). Each rested turn accrues toward an **escalating threshold**: reveal *N* needs
`100 × N` consecutive rested turns (intervals 100, 200, 300…; cumulative 100, 300, 600…), keyed off
reveals earned so far. **Favors potions** when any eligible potion exists. A ring of wisdom
accelerates it ~10%/level (clamped). See
[pr-notes-rest-polarity-insight phase 8.md](../pr-notes-rest-polarity-insight%20phase%208.md).

### 6b. Eating insight
`gainScrollInsightFromEating()` ([Items.c:8224–8250](../../BrogueCE/Engine/Items.c)), called from
`eat()` ([Items.c:7574](../../BrogueCE/Engine/Items.c)). A safe meal — **nothing in the
`MONSTER_TRACKING_SCENT` (hunting) state** ([Items.c:8226](../../BrogueCE/Engine/Items.c)) — is a
calm moment to study one random unknown **scroll** (scrolls only; potions are the rest channel's
job). See [pr-notes-eat-scroll-insight phase 9.md](../pr-notes-eat-scroll-insight%20phase%209.md).

---

## 7. Indirect / deductive tells (information, not a direct reveal)

### 7a. Monkey / imp theft preference **[iOS]**
`rateItemStealDesirability()` ([Combat.c:398–426](../../BrogueCE/Engine/Combat.c)) scores items
against a data-driven `stealProfile` ([Globals.c:1131–1152](../../BrogueCE/Engine/Globals.c)).
*What gets stolen is a clue to what it is:*

- **Monkey** (`monkeyStealProfile`): big bonus (+290) to **food, potion of life, potion of
  strength**; ADDITIVE base 10 so it'll grab anything; 5% random. A potion a monkey ran off with is
  *probably* life or strength.
- **Imp** (`impStealProfile`): scroll of enchanting (+50), positively-enchanted gear (+5/enchant),
  runics (+25), dislikes food (−8). An item the imp wanted is *probably* good/enchanted.

See [reusable-components.md](../guides/reusable-components.md) (the steal component) and
[IOS_MODIFICATIONS.md](../../BrogueCE/Engine/IOS_MODIFICATIONS.md) "Deductive thievery".

### 7b. Empty-bottle capture **[iOS]**
`fillEmptyBottle()` ([Items.c:6730](../../BrogueCE/Engine/Items.c)): capturing a gas/liquid (or a
bolt) turns the always-identified empty bottle into the matching, **already-identified** potion —
and auto-IDs that kind, so matching unidentified potions in the pack become known too. See
[TERRAIN_AUDIT.md](TERRAIN_AUDIT.md) §empty-bottle and
[docs/design/empty-bottle-v2.md](../design/empty-bottle-v2.md).

### 7c. Benevolent-potion glow **[iOS]**
A dropped good potion glows warmly when a bolt passes through it — a free polarity tell for the
observant (see [IOS_MODIFICATIONS.md](../../BrogueCE/Engine/IOS_MODIFICATIONS.md), phase 3 polish).

---

## 8. Tuning reference

One place for every scalar, so balancing doesn't mean spelunking ten files.

### Auto-ID by use — per game variant ([Globals*.c](../../BrogueCE/Engine/GlobalsBrogue.c))
| Constant | Brogue | RapidBrogue | BulletBrogue |
|---|---|---|---|
| `weaponKillsToAutoID` | 20 kills | 5 | 2 |
| `armorDelayToAutoID` | 1000 turns | 250 | 120 |
| `ringDelayToAutoID` | 1500 turns | 250 | 120 |

### Insight & detect magic
| Knob | Value | Cite |
|---|---|---|
| Rest reveal threshold | `100 × (reveals earned + 1)` rested turns | [Items.c:8176,8184](../../BrogueCE/Engine/Items.c) |
| Ring of wisdom speedup | −10% threshold per ring level; clamped (max 80% faster, max 2× slower) | [Items.c:8185–8189](../../BrogueCE/Engine/Items.c) |
| Detect magic spread (drink & throw) | `rand_range(1, 2 + wisdomBonus)` items | [Items.c:8275,8325](../../BrogueCE/Engine/Items.c) |
| Eating insight gate | no creature in `MONSTER_TRACKING_SCENT` | [Items.c:8226](../../BrogueCE/Engine/Items.c) |

### Theft desirability ([Globals.c:1131–1152](../../BrogueCE/Engine/Globals.c))
| Thief | Bonuses (over base 10, additive) | Random pick |
|---|---|---|
| Monkey | food +290, potion of life +290, potion of strength +290 | 5% |
| Imp | scroll of enchanting +50, +enchant×5 on positive gear, runic +25, food −8 | 5% |

---

## 9. Cross-references

- [ITEMS_AUDIT.md](ITEMS_AUDIT.md) — base item stats, `magicPolarity` per kind, §11 "how
  enchantments are applied" (auto-ID thresholds in their original context).
- [TERRAIN_AUDIT.md](TERRAIN_AUDIT.md) — the empty-bottle capture map and gap analysis.
- [IOS_MODIFICATIONS.md](../../BrogueCE/Engine/IOS_MODIFICATIONS.md) — per-change history & rationale
  for every **[iOS]** mechanic above.
- Phase notes (in `docs/`): `potion-id-rework-plan.md` (master plan),
  `pr-notes-potion-throw-good-effects phase 1+2.md`, `pr-notes-potion-bolt-detonation phase 3.md`,
  `pr-notes-insight-altar phase 7.md`, `pr-notes-rest-polarity-insight phase 8.md`,
  `pr-notes-eat-scroll-insight phase 9.md`, `pr-notes-ring-equip-deduction issue 683.md`.
