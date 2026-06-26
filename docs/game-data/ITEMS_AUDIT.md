# Brogue Items Audit (Brogue SE)

> **Source of truth.** This document was generated entirely from the **Brogue SE** C
> engine (a fork of BrogueCE 1.15) vendored at `BrogueSE/Engine/`. Every value below was read
> from the code, not from memory of the game.
>
> Primary source files:
> - `BrogueSE/Engine/Globals.c` — static item catalogs (keys, food, weapons, armor, staffs, rings, runic name tables, appearance pools).
> - `BrogueSE/Engine/GlobalsBrogue.c` — Brogue-variant tables (potions, scrolls, wands, charms, charm-effect table, metered generation table) and the `brogueGameConst` constants block.
> - `BrogueSE/Engine/GlobalsBase.c` — shared power-curve arrays (charm increment tables).
> - `BrogueSE/Engine/Items.c` — generation, enchantment, charges, identification, metered generation.
> - `BrogueSE/Engine/Combat.c` — runic effects, strength modifier, net enchant.
> - `BrogueSE/Engine/PowerTables.c` — enchant-level → effect scaling tables.
> - `BrogueSE/Engine/Rogue.h` — `itemTable` struct, item flags, all item-kind / runic / bolt enums.

---

## 0. The `itemTable` struct and how to read the catalogs

`itemTable` (source: `BrogueSE/Engine/Rogue.h:1532`):

```c
typedef struct itemTable {
    char *name;
    char *flavor;            // randomized appearance (color/wood/metal/gem/title), or "" for prenamed
    char callTitle[30];
    short frequency;         // generation weight within the category (see chooseKind)
    short marketValue;       // shop / score value
    short strengthRequired;  // weapons & armor only; 0 otherwise
    int power;               // bolt type for staffs/wands; enchant magnitude for scroll of enchanting; nutrition for food
    randomRange range;       // {lowerBound, upperBound, clumpFactor}
    boolean identified;
    boolean called;
    int magicPolarity;       // +1 good, -1 bad, used for detect-magic sigils
    boolean magicPolarityRevealed;
    char description[1500];
} itemTable;
```

The column order in the catalogs is therefore:
`{name, flavor, callTitle, frequency, marketValue, strengthRequired, power, {range}, identified, called, magicPolarity, magicPolarityRevealed, description}`.

### Item categories
Source: `BrogueSE/Engine/Rogue.h:814` (`NUMBER_ITEM_CATEGORIES 13`) and `itemCategoryNames` (`Globals.c:1588`):

`food, weapon, armor, potion, scroll, staff, wand, ring, charm, gold, amulet, lumenstone (GEM), key`.

Category flag groupings (`Rogue.h:817`):
- `HAS_INTRINSIC_POLARITY = POTION | SCROLL | RING | WAND | STAFF`
- `CAN_BE_DETECTED = WEAPON | ARMOR | POTION | SCROLL | RING | CHARM | WAND | STAFF | AMULET`
- `CAN_BE_ENCHANTED = WEAPON | ARMOR | RING | CHARM | WAND | STAFF`
- `PRENAMED_CATEGORY = FOOD | GOLD | AMULET | GEM | KEY`
- `NEVER_IDENTIFIABLE = FOOD | CHARM | GOLD | AMULET | GEM | KEY`
- `CAN_BE_SWAPPED = WEAPON | ARMOR | STAFF | CHARM | RING`

### Game constants (`brogueGameConst`, `GlobalsBrogue.c:1061`)
| Constant | Value |
|---|---|
| `amuletLevel` (`AMULET_LEVEL`) | 26 |
| `deepestLevel` (`DEEPEST_LEVEL`) | 40 |
| `depthAccelerator` | 1 |
| `extraItemsPerLevel` | 0 |
| `goldAdjustmentStartDepth` | 6 |
| `playerTransferenceRatio` | 20 |
| `onHitHallucinateDuration` | 20 |
| `onHitWeakenDuration` | 300 |
| `onHitMercyHealPercent` | 50 |
| `weaponKillsToAutoID` | 20 |
| `armorDelayToAutoID` | 1000 (turns) |
| `ringDelayToAutoID` | 1500 (turns) |
| `numberGoodPotionKinds` | 8 |
| `numberGoodScrollKinds` | 12 |
| `numberGoodWandKinds` | 6 |
| `fallDamageMin / Max` | 8 / 10 |

### Category generation probabilities
Source: `itemGenerationProbabilities_Brogue[13]` (`GlobalsBrogue.c:112`). Order is
`{GOLD, SCROLL, POTION, STAFF, WAND, WEAPON, ARMOR, FOOD, RING, CHARM, AMULET, GEM, KEY}`
(per `pickItemCategory`, `Items.c:86`):

| Category | Weight |
|---|---|
| gold | 50 |
| scroll | 42 |
| potion | 52 |
| staff | 3 |
| wand | 3 |
| weapon | 10 |
| armor | 8 |
| food | 2 |
| ring | 3 |
| charm | 2 |
| amulet | 0 |
| lumenstone (gem) | 0 |
| key | 0 |

Within a category, `chooseKind` (`Items.c:433`) picks a kind weighted by each entry's
`frequency` field (negative frequencies treated as 0). So the per-category `frequency`
column controls relative drop rates of the individual kinds.

---

## 1. Weapons

Source: `weaponTable[NUMBER_WEAPON_KINDS]` at `Globals.c:1732`. Enum order: `Rogue.h:895`.
Damage is `{lowerBound, upperBound, clumpFactor}`. `strengthReq` is the strength to use
without penalty. The "Attribute" column is the special melee behavior flag assigned in
`makeItemInto` (`Items.c:221`).

| # | Weapon | StrReq | Damage (lo–hi, clump) | Noise | Freq | MktVal | Attribute flag / behavior |
|---|---|---|---|---|---|---|---|
| 0 | dagger | 12 | 3–4 (1) | LIGHT (12) | 10 | 190 | `ITEM_SNEAK_ATTACK_BONUS` — sneak attacks deal **5×** instead of 3× |
| 1 | sword | 14 | 7–9 (1) | NORMAL (22) | 10 | 440 | (plain) |
| 2 | broadsword | 19 | 14–22 (1) | HEAVY (32) | 10 | 990 | (plain, heavy) |
| 3 | whip | 14 | 3–5 (1) | LIGHT (12) | 10 | 440 | `ITEM_ATTACKS_EXTEND` — reaches enemies up to 5 spaces away |
| 4 | rapier | 15 | 3–5 (1) | LIGHT (12) | 10 | 440 | `ITEM_ATTACKS_QUICKLY | ITEM_LUNGE_ATTACKS` — attacks twice as fast; lunge = 3× and never misses |
| 5 | flail | 17 | 9–15 (1) | HEAVY (32) | 10 | 440 | `ITEM_PASS_ATTACKS` — free attack when moving between two cells adjacent to a foe |
| 6 | mace | 16 | 16–20 (1) | HEAVY (32) | 10 | 660 | `ITEM_ATTACKS_STAGGER` — extra recovery turn on hit; knockback |
| 7 | war hammer | 20 | 25–35 (1) | BOOMING (45) | 10 | 1100 | `ITEM_ATTACKS_STAGGER` — extra recovery turn on hit; knockback |
| 8 | spear | 13 | 4–5 (1) | NORMAL (22) | 10 | 330 | `ITEM_ATTACKS_PENETRATE` — hits adjacent foe + foe directly behind |
| 9 | war pike | 18 | 11–15 (1) | HEAVY (32) | 10 | 880 | `ITEM_ATTACKS_PENETRATE` |
| 10 | axe | 15 | 7–9 (1) | NORMAL (22) | 10 | 550 | `ITEM_ATTACKS_ALL_ADJACENT` — hits all adjacent foes |
| 11 | war axe | 19 | 12–17 (1) | HEAVY (32) | 10 | 990 | `ITEM_ATTACKS_ALL_ADJACENT` |
| 12 | dart | **0** | 2–4 (1) | thrown¹ | **0** | 15 | thrown; stacks 5–18; can't be magical/runic |
| 13 | incendiary dart | 12 | 1–2 (1) | thrown¹ | 10 | 25 | thrown; stacks 3–6; explodes into fire |
| 14 | javelin | 15 | 3–11 (3) | thrown¹ | 10 | 40 | thrown; stacks 5–18 |

Notes:
- **Noise** (Brogue SE noise system) is the loudness spike a melee swing emits — the per-weapon tier from
  `weaponMeleeLoudness()` (`Combat.c`), stacked on the player's base loudness (armor/terrain/ring of
  stealth). Tiers are tunable `#define`s in `Rogue.h` (`NOISE_MELEE_LIGHT/NORMAL/HEAVY/BOOMING`). A
  **clean hit** emits the listed value; a **miss** adds `NOISE_MELEE_MISS_PENALTY` (+10). Only **LIGHT
  (12)** sits below the aggro threshold (`NOISE_HEAR_AGGRO_LOUDNESS` = 20), so a clean LIGHT-weapon kill
  only makes unseen *bystanders* investigate rather than swarm — the dagger/rapier/whip are the
  assassin's tier. Auto-hits (sneak/asleep/paralyzed/lunge) count as a clean connect → stay quiet. Heavy
  armor's base clatter can still push a LIGHT weapon over the line. Unarmed = LIGHT. Full mechanics:
  [PERCEPTION_AUDIT.md §3.2.1](PERCEPTION_AUDIT.md).
- ¹ Thrown weapons don't melee; their *impact* loudness on landing uses a separate mass tier
  (`itemImpactLoudness()`, `NOISE_IMPACT_*`) — see [PERCEPTION_AUDIT.md](PERCEPTION_AUDIT.md) / the
  environmental-sounds doc.
- Darts have frequency 0, so they never appear in the normal weapon raffle; they spawn via
  blueprints / special placement. Throwing weapons (`dart`, `incendiary dart`, `javelin`)
  are forced non-cursed, non-runic, non-magical and given a random `quiverNumber`
  (`Items.c:282`).
- All non-thrown weapons get `charges = weaponKillsToAutoID` (20) — kill 20 foes to auto-ID
  (`Items.c:286`).

### Weapon runics (W_*)
Names: `weaponRunicNames` (`Globals.c:1764`). Enum: `Rogue.h:920`. Good runics are
`W_SPEED..W_MERCY` (`NUMBER_GOOD_WEAPON_ENCHANT_KINDS = W_MERCY`); bad runics are `W_PLENTY`
(and conceptually the cursed ones). Effects implemented in `Combat.c:762` (`magicWeaponHit`).

| Runic | Good? | Effect (per `Combat.c`) | Scaling fn (`PowerTables.c`) |
|---|---|---|---|
| `W_SPEED` (0) | good | Grants a free turn on a triggered hit (`player.ticksUntilTurn = -1`) | `runicWeaponChance`, base decrement `POW_16` |
| `W_QUIETUS` (1) | good | Instant kill (`inflictLethalDamage` + `killCreature`) | `POW_6` (rare trigger) |
| `W_PARALYSIS` (2) | good | Paralyzes target for `weaponParalysisDuration(e) = max(2, 2 + e/2)` turns | `POW_7` |
| `W_MULTIPLICITY` (3) | good | Spawns `weaponImageCount(e) = clamp(e/3,1,7)` spectral allies for `weaponImageDuration = 3` turns | `POW_15` |
| `W_SLOWING` (4) | good | Slows target for `weaponSlowDuration(e) = max(3, ((e+2)*(e+2))/3)` turns | `POW_14` |
| `W_CONFUSION` (5) | good | Confuses target for `weaponConfusionDuration(e) = max(3, e*3/2)` turns | `POW_11` |
| `W_FORCE` (6) | good | Knocks target back `weaponForceDistance(e) = max(4, e*2 + 2)` cells, damaging on collision | `POW_15` |
| `W_SLAYING` (7) | good | 100% kill vs its random `vorpalEnemy` class, 0% otherwise (`chance` short-circuits) | n/a (always 0/100) |
| `W_MERCY` (8) | good (de facto bad for you) | Heals the target by `onHitMercyHealPercent` = 50% | n/a (fixed 15% trigger for bad) |
| `W_PLENTY` (9) | **bad** | Clones the target (`cloneMonster`) | fixed 15% trigger |

Trigger chance: `runicWeaponChance` (`PowerTables.c:224`). Key mechanics:
- `W_SLAYING` → returns 0 here (handled separately as 100% vs vorpal enemy).
- Bad runics (`>= NUMBER_GOOD_WEAPON_ENCHANT_KINDS`, i.e. W_PLENTY and the cursed bad set)
  → fixed **15%**.
- Good runics: chance derived from a per-runic `(1-p)^x` decrement table (mapping above),
  indexed by `enchantLevel * modifier`. `modifier` shrinks with the weapon's average base
  damage (`FP_FACTOR - min(0.99, avgDamage/18)`) — **higher-damage weapons trigger runics
  less often**. Stagger weapons get `1-(1-p)^2`; quick weapons get `1-sqrt(1-p)`. Floor is
  `max(1, enchantLevel)` percent.
- Backstabs double the chance (capped) (`Combat.c:790`).

---

## 2. Armor

Source: `armorTable[NUMBER_ARMOR_KINDS]` at `Globals.c:1755`. Enum: `Rogue.h` armor kinds.
Base armor value is rolled from `range` (`randClump`). Auto-ID after `armorDelayToAutoID`
(1000) turns worn (`Items.c:296`).

| # | Armor | StrReq | Base armor (lo–hi) | Freq | MktVal |
|---|---|---|---|---|---|
| 0 | leather armor | 10 | 30 | 10 | 250 |
| 1 | scale mail | 12 | 40 | 10 | 350 |
| 2 | chain mail | 13 | 50 | 10 | 500 |
| 3 | banded mail | 15 | 70 | 10 | 800 |
| 4 | splint mail | 17 | 90 | 10 | 1000 |
| 5 | plate armor | 19 | 110 | 10 | 1300 |

(Armor values are stored ×10 internally; displayed armor is `value/10`. The defense curve is
`defenseFraction`, `PowerTables.c:188`, a `0.877^x` table indexed by net defense in 0.25
display-point steps.)

### Armor runics (A_*)
Names: `armorRunicNames` (`Globals.c:1777`). Enum: `Rogue.h:945`. Good runics are
`A_MULTIPLICITY..A_BURDEN` (`NUMBER_GOOD_ARMOR_ENCHANT_KINDS = A_BURDEN`); bad runics are
`A_VULNERABILITY`, `A_IMMOLATION`. **Note:** `A_BURDEN` is classed as "good" by the enum
boundary even though its effect is detrimental. Effects in `Combat.c:979`
(`applyArmorRunicEffect`).

| Runic | Good? | Effect | Scaling fn |
|---|---|---|---|
| `A_MULTIPLICITY` (0) | good | On melee hit, 33% chance to spawn `armorImageCount(e) = clamp(e/3,1,5)` spectral clones of the attacker (1 HP, 3-turn lifespan) | `armorImageCount` |
| `A_MUTUALITY` (1) | good | Splits incoming damage among adjacent enemies: `dmg = (dmg+count)/(count+1)` | — |
| `A_ABSORPTION` (2) | good | Reduces damage by `rand(1, armorAbsorptionMax(e))`, `armorAbsorptionMax = max(1, e)` | `armorAbsorptionMax` |
| `A_REPRISAL` (3) | good | Reflects `armorReprisalPercent(e) = max(5, e*5)`% of melee damage back to attacker | `armorReprisalPercent` |
| `A_IMMUNITY` (4) | good | Takes **0** damage from its random `vorpalEnemy` class | — |
| `A_REFLECTION` (5) | good | Reflects bolts; `reflectionChance(e)` from `POW_REFLECT` (0.85^x) table | `reflectionChance` |
| `A_RESPIRATION` (6) | good | Immunity to harmful gases (checked elsewhere) | — |
| `A_DAMPENING` (7) | good | Suppresses bolt/explosion effects in the wearer's vicinity (checked elsewhere) | — |
| `A_BURDEN` (8) | "good" (bad effect) | 10% chance per hit to permanently raise `strengthRequired` by 1 | — |
| `A_VULNERABILITY` (9) | **bad** | Doubles all incoming damage (`*damage *= 2`) | — |
| `A_IMMOLATION` (10) | **bad** | 10% chance per hit to ignite the wearer (`DF_ARMOR_IMMOLATION`) | — |

(`A_RESPIRATION` and `A_DAMPENING` are passive and handled outside `applyArmorRunicEffect`;
the switch there covers the active-on-hit runics.)

---

## 3. Staffs

Source: `staffTable[NUMBER_STAFF_KINDS]` at `Globals.c:1791`. Enum: `Rogue.h:973`.
The `power` column is the `boltType`. All staffs share `range {2,4,1}`. Good staffs are
`STAFF_LIGHTNING..STAFF_FREEZE` (`NUMBER_GOOD_STAFF_KINDS = STAFF_HEALING`, the first non-good index);
healing, `STAFF_HASTE` and `STAFF_PROTECTION` have `magicPolarity = -1` (they help the *target*, so bad
to fire at a foe). On generation (`Items.c:333`): start with 2 charges, 50% +1, then 15% +1, then 10%
chains; `enchant1 = charges`; recharge counter starts at 500 (1000 for blinking/obstruction).

**iOS port:** `STAFF_FREEZE` (staff of **frost**, #9) is an iOS-port addition inserted into the enum
before healing (shifting healing/haste/protection to 10/11/12). Full design:
[`docs/design/staff-of-frost.md`](../design/staff-of-frost.md).

| # | Staff | Bolt | StrReq | Freq | MktVal | Polarity |
|---|---|---|---|---|---|---|
| 0 | lightning | `BOLT_LIGHTNING` | 0 | 15 | 1300 | + |
| 1 | firebolt | `BOLT_FIRE` | 0 | 15 | 1300 | + |
| 2 | poison | `BOLT_POISON` | 0 | 10 | 1200 | + |
| 3 | tunneling | `BOLT_TUNNELING` | 0 | 10 | 1000 | + |
| 4 | blinking | `BOLT_BLINKING` | 0 | 11 | 1200 | + |
| 5 | entrancement | `BOLT_ENTRANCEMENT` | 0 | 6 | 1000 | + |
| 6 | obstruction | `BOLT_OBSTRUCTION` | 0 | 10 | 1000 | + |
| 7 | discord | `BOLT_DISCORD` | 0 | 10 | 1000 | + |
| 8 | conjuration | `BOLT_CONJURATION` | 0 | 8 | 1000 | + |
| 9 | **frost** (iOS port) | `BOLT_FREEZE` | 0 | 8 | 1200 | + |
| 10 | healing | `BOLT_HEALING` | 0 | 5 | 1100 | − |
| 11 | haste | `BOLT_HASTE` | 0 | 5 | 900 | − |
| 12 | protection | `BOLT_SHIELDING` | 0 | 5 | 900 | − |

### Staff power scaling by enchant level
All from `PowerTables.c:48`. `enchant` below is the net enchant ×`FP_FACTOR`; the formulas
use `enchant/FP_FACTOR` (= the displayed staff level).

| Staff | Effect formula |
|---|---|
| damage staffs (lightning/fire/etc.) | `staffDamageLow = (2 + level)*3/4`; `staffDamageHigh = 4 + 5*level/2`; rolled clumped. *(iOS port: lightning & firebolt gain stun/chain/bloom at netEnchant ≥ 5 — see [Staff glow-up](#staff-glow-up-ios-port--lightning--firebolt-at-netenchant--5) below.)* |
| poison | `staffPoison(e) = 5 * 1.3^(level-2)` doses (table `POW_POISON`, 1.3^x) |
| blinking | `staffBlinkDistance = 2 + level*2` cells |
| haste | `staffHasteDuration = 2 + level*4` turns |
| conjuration | `staffBladeCount = level*3/2` blades |
| discord | `staffDiscordDuration = level*4` turns |
| entrancement | `staffEntrancementDuration = level*3` turns |
| obstruction | scales with level (larger crystal walls); uses bolt magnitude |
| protection (shielding) | `staffProtection(e) = 130 * 1.40^(level-2)` shield points |
| frost (iOS port) | single-target freeze: `staffFreezeDuration` turns frozen, then a `staffFreezeSlowDuration` slow tail (both scale with level, `PowerTables.c`); freezes deep water into temporary walkable ice and dense foliage into brittle walls; quenches fire it crosses. Anything ablaze/`MONST_FIERY` is doused + slowed instead of frozen. Shared `freezeCreature()` with the potion of ice. |

### Staff glow-up (iOS port) — lightning & firebolt at netEnchant ≥ 5

The staffs of **lightning** and **firebolt** gain new behavior once their **netEnchant reaches 5**, then
ramp with further enchant. The gate is `netEnchant >= 5` (so curse/low strength can't cheat it), carried
into the bolt via a new `bolt.empowerment` field (the effective net-enchant level, else 0) set in
`useStaffOrWand` (`Items.c`); catalog bolts default it to 0. Behavior triggers on the actual enchant
regardless of identification — only the description *specifics* are gated on the enchant being known.
**Player-staff-only:** monster-cast lightning/fire bolts have no enchant and stay vanilla. Single charge,
fully automatic. Deterministic (substantive-RNG damage rolls only; the `bolt` struct is transient/never
serialized, so the field is save-safe). Ramp formulas in `PowerTables.c`:

| Staff | Empowered effect (netEnchant ≥ 5) | Ramp |
|---|---|---|
| lightning | every creature the bolt damages is briefly **stunned** (non-stacking `STATUS_PARALYZED`, the electrified-water `max(existing, dur)` pattern) **and** the charge **chains** to nearby enemies the straight line *missed* | `staffLightningStunDuration` 1→3 turns; `staffLightningChainCount` 1→3 jumps; `staffLightningChainRange` 3→8 cells |
| firebolt | the bolt **erupts into an incineration bloom** at its impact point (the last passable cell), *augmenting* the direct line hit — reuses `DF_INCINERATION_POTION` (real fire: burns the player and ignites the dungeon) | `staffFireboltBloomDecrement` 37→12 (lower = larger bloom) |

- **Stun** is applied in `updateBolt` BE_DAMAGE (the "monster lives" branch); symmetric — a reflected bolt
  can stun the player. Non-stacking, so it can't stun-lock.
- **Chain** is a *controlled arc* (`resolveLightningChain`, `Items.c`), **not** `zap()` recursion: it reuses
  the same `staffDamage` roll + stun, arcs from the last struck creature to the nearest **unstruck** enemy
  within range on an open path (deterministic — nearest by distance, monster-iteration order breaks ties),
  with **per-link damage falloff** (~75% each hop). It shares a **struck-set** with the primary line
  (generalizing electrified water's "ring-0 exclusion" below), so a creature already pierced by the line is
  never hit twice and the chain can't ping-pong. Fires only if the primary bolt struck a creature.
- **Firebolt bloom** spawns once the bolt lands; on a clean miss into a wall it blooms at the cell before
  the wall (never inside it). It does **not** use the concussive `GAS_EXPLOSION` / knockback path — it's
  incineration *fire*, by design (lightning is the crowd-control staff; firebolt is area-denial).

### Electrified water (iOS port) — lightning + water

A lightning bolt (`BF_ELECTRIC` — staff of lightning, spark turrets, a reflected/monster electric bolt)
that strikes a creature **standing in water** charges the entire **connected body of water** and shocks
everything in it. (`Items.c` `electrifyWater`, ~`5164`; hooks in `zap` / `updateBolt`.)

- **Conductive water** = `isConductiveWater` (`Items.c:5148`): tiles with both `TM_ALLOWS_SUBMERGING`
  and `TM_EXTINGUISHES_FIRE` — i.e. deep / shallow / sloshing / luminescent water. Bog, lava, cooling
  lava and the sacrificial pit allow submerging but don't extinguish fire, so they're **excluded**.
- **In contact** = `creatureContactsWater` (`Items.c:5155`): standing in conductive water and **not**
  levitating or flying. Hovering creatures neither trigger nor take the shock; `MONST_INVULNERABLE`
  creatures are skipped.
- **Spread & damage:** a breadth-first flood from each struck-in-water tile (8-connected, nearest source
  wins — one shock per body, no double-dipping). Each shocked creature rolls lightning damage scaled by a
  geometric falloff of `WATER_SHOCK_FALLOFF_PERCENT` (75%) per ring; the spread stops where even a max
  roll would deal <1 damage.
- **Stun:** anything the shock damages is paralyzed for `WATER_SHOCK_STUN_DURATION` (**3** turns). The
  **directly-struck target** (ring 0) takes the normal bolt hit — excluded from the *spread damage* to
  avoid double-hitting — and (as of 2026-06-13) **is also stunned** (paralysis only). So a creature struck
  by lightning while in water is both damaged and briefly paralyzed; the player is affected symmetrically.
- **Submerged eels ARE shocked** — this deliberately overrides the usual "submerged monsters can't be
  bolt-targeted" rule, making lightning the hard counter to eels.

The iOS **potion of water** (§7, capture-only) exists partly to set this up: its flood is "lightning-stun
footing" (and washes scent — see [MONSTERS_AUDIT.md](MONSTERS_AUDIT.md)). Determinism: damage iterates the
monster list then the player in a fixed order; the cosmetic shockwave draws no RNG.

### Bolts vs. dropped potions — what a fire / lightning staff does to a flask on the floor

A fire or lightning bolt that crosses a **dropped potion** (or the empty bottle) interacts with it; the
full rules — including the throw side, thrown-weapon triggers, and the identification consequences — live
in **§7b** (Potions). The short version:

- **Bad / cloud potions detonate** (spawn their shatter signature and absorb the bolt). A **fire** bolt
  ignites the cloud as it spawns; a **lightning** bolt blooms it unignited. The bolt is halted at the flask
  either way (so a line of dropped potions isn't cleared by one zap).
- **The 8 benevolent potions glow-and-pass** — the bolt passes through harmlessly and **no flag is set**
  on the flask. You learn the polarity only *by observation* (good glows & passes, bad detonates); the
  game doesn't record it, so it's no free mass-ID.
- **The empty bottle is captured**, not shattered: lightning → speed, fire → incineration (see §7a).
- **Identification:** a detonation normally full-IDs the potion (you saw the cloud), **except** a *fire*
  trigger reveals only **polarity** for the flammable gas clouds (poison/confusion/paralysis/vomit) and for
  incineration, whose tells are erased by the flame. See §7b for the exact list.

(Frost is the other terrain-shaping bolt — it quenches fire and freezes water/foliage; see the staff table
above. It does not detonate potions.)

---

## 4. Wands

Source: `wandTable_Brogue[]` at `GlobalsBrogue.c:753`. Enum: `Rogue.h:961`. `power` column
is the `boltType`. `numberWandKinds` = 9, `numberGoodWandKinds` = 6. On generation
(`Items.c:351`): `charges = randClump(range)`. A wand auto-IDs immediately if its charge
range is a single value (`range.lowerBound == range.upperBound`) (`Items.c:914`).

| # | Wand | Bolt | Charges (lo–hi, clump) | StrReq | Freq | MktVal | Polarity |
|---|---|---|---|---|---|---|---|
| 0 | teleportation | `BOLT_TELEPORT` | 3–5 (1) | 0 | 3 | 800 | + |
| 1 | slowness | `BOLT_SLOW` | 2–5 (1) | 0 | 3 | 800 | + |
| 2 | polymorphism | `BOLT_POLYMORPH` | 3–5 (1) | 0 | 3 | 700 | + |
| 3 | negation | `BOLT_NEGATION` | 4–6 (1) | 0 | 3 | 550 | + |
| 4 | domination | `BOLT_DOMINATION` | 1–2 (1) | 0 | 1 | 1000 | + |
| 5 | beckoning | `BOLT_BECKONING` | 2–4 (1) | 0 | 3 | 500 | + |
| 6 | plenty | `BOLT_PLENTY` | 1–2 (1) | 0 | 2 | 700 | − |
| 7 | invisibility | `BOLT_INVISIBILITY` | 3–5 (1) | 0 | 3 | 100 | − |
| 8 | empowerment | `BOLT_EMPOWERMENT` | 1–1 (1) | 0 | 1 | 100 | − |

Notes: `domination` (`wandDominate`, `PowerTables.c:45`) is 100% if the target is below 20%
max HP, otherwise scales with the target's missing HP. Empowerment has a fixed 1 charge and
auto-IDs on pickup. Wands gain charges (not levels) when read with a scroll of enchanting:
`charges += range.lowerBound * enchantMagnitude` (`Items.c:7985`).

---

## 5. Rings

Source: `ringTable[NUMBER_RING_KINDS]` at `Globals.c:1808`. Enum: `Rogue.h:1026`. All rings
share `range {1,3,1}` (initial enchant). On generation (`Items.c:358`): `enchant1 =
randClump(range)`; 16% cursed (negated enchant + `ITEM_CURSED`), otherwise 10% chains add +1.
Auto-IDs after `ringDelayToAutoID` (1500) turns worn; a non-positive ring auto-identifies
immediately on inspection (`Items.c:6489`).

| # | Ring | Freq | MktVal | Effect (positive enchant) | Cursed |
|---|---|---|---|---|---|
| 0 | clairvoyance | 1 | 900 | See through walls/doors within radius = enchant | Blinds immediate surroundings |
| 1 | stealth | 1 | 800 | Reduces stealth range | Increases stealth range |
| 2 | regeneration | 1 | 750 | Faster HP regen (`turnsForFullRegenInThousandths`, 0.75^x) | Slows/halts regen |
| 3 | transference | 1 | 750 | Heal % of damage dealt (`playerTransferenceRatio` = 20% per level base) | Lose HP when dealing damage |
| 4 | light | 1 | 600 | See farther in dim light; no extra noticeability | (always good kind) |
| 5 | awareness | 1 | 700 | Better detection of traps/secret doors/levers + iOS-port perception effects (see below) | Dulls detection (cursed senses nothing extra) |
| 6 | wisdom | 1 | 700 | Staffs recharge faster (`ringWisdomMultiplier`, 1.3^x, `PowerTables.c:76`) + iOS-port insight effects (see below) | Slower staff recharge / slower insight |
| 7 | reaping | 1 | 700 | Recharge staffs/charms on each hit | Drains staffs/charms on each hit |

The worn enchant of each ring is summed into a `rogue.*Bonus` field on equip (`Items.c:9562`).
`rogue.awarenessBonus += 20 * effectiveRingEnchant` (so +20 per enchant level);
`rogue.wisdomBonus += effectiveRingEnchant` (so +1 per enchant level). Cursed (negative-enchant)
rings push the bonus negative.

### Ring of awareness — iOS-port effects

Beyond vanilla trap/secret-door/lever detection, the iOS port adds several **perception** effects, all
keyed off `rogue.awarenessBonus`:

- **Search strength.** Passive/active searches scale with the bonus: a base search is
  `max(60, awarenessBonus + 30)` (positive ring) and the per-turn passive search is `awarenessBonus + 30`;
  a cursed ring (`< 0`) drops the active base to 30 (`Time.c:2316`, `Time.c:2431`, `Time.c:2307`).
- **Sense a pursuer losing your trail.** When a hunting monster gives up (hunting → wandering), you get a
  `clamp(20 + awarenessBonus, 0, 100)`% chance to be told it lost your trail — no line of sight required
  (`SENSE_LOST_TRAIL_BASE_CHANCE = 20`, `Monsters.c:1876`, `Monsters.c:1943`).
- **Off-screen escape notice.** A fleeing creature that escapes up/down the stairs prints its closure
  message even off-screen, but only if `awarenessBonus > 0` (`Monsters.c:3601`).
- **Sense a level's room machine.** On first arriving at a level that contains a room machine
  (vault/altar/captive/guardian set-piece), a positive ring gives a
  `min(100, 25 + awarenessBonus)`% chance of "you sense that something of significance lies hidden on
  this level." Existence only — never location or reward/danger; truthful (never false-positives), so
  silence is ambiguous. Gated on wearing the ring AND a machine existing, so non-wearers draw no RNG and
  keep vanilla replay behavior (`AWARENESS_MACHINE_SENSE_BASE = 25`, `RogueMain.c:618`, `RogueMain.c:836`).
- **Sense floor item polarity (Brogue SE).** On first arriving at a level, a positive ring may sense the
  benevolent/malevolent aura of magic items lying on the floor — *secret rooms included* — lighting each
  one's map aura and recording its polarity (the passive, per-floor twin of a thrown potion of detect
  magic). With `enchant = awarenessBonus / 20`: per-item chance `min(90, 10 + 10·(enchant+1))` (+1 = 30% …
  +7 = 90% cap), with `1 + max(0, enchant − 7)` rolls (each success reveals one more item). Gated on
  `awarenessBonus > 0` (cursed senses nothing); action-triggered RNG, replay-stable. See the
  identification audit §5h and `senseFloorPolarityFromAwareness` (`Items.c`).
- **Hear unseen monsters farther (Brogue SE noise system).** Awareness extends how far off-screen monster
  movement registers as a "heard something" ripple. The ring's primary effect here is **range, not
  probability** ("bigger ears, not a louder world"): each net enchant adds `NOISE_AWARENESS_RANGE_PER_ENCHANT`
  (5) tiles to the audible radius — ringless ≈ 6 tiles, **+6 ≈ 36 tiles (~half the map)** — while only a
  small `NOISE_AWARENESS_PER_ENCHANT` (2%) is added to the per-step chance (just enough that a high ring can
  hear quiet/silent creatures). A within-earshot floor (`NOISE_AUDIBLE_FLOOR`) keeps that extended range
  *real* — faint but accumulating pings out to the edge — so the practical detection climbs sharply with
  enchant (none ~35% → +1 ~54% → +3 ~79% → +6 ~95% over an approach). Cosmetic/replay-safe. See
  **PERCEPTION_AUDIT.md §3.3** for the full two-stage model and the cumulative E / P(≥1) detection tables.

### Ring of wisdom — iOS-port effects

Beyond the vanilla staff-recharge multiplier, the iOS port adds two **insight** effects, keyed off
`rogue.wisdomBonus` (the effective enchant, +1 per level):

- **Faster rest-insight.** Resting reveals/identifies a random polarity-bearing pack item on an
  escalating turn threshold (`100 * (revealsSoFar + 1)`). A worn wisdom ring cuts that threshold by
  ~`10 * wisdomBonus`%, clamped to at most 80% faster (cursed slows it, capped at 2× and never below 1
  rested turn) (`Items.c:8366`).
- **Wider detect-magic spread.** The reworked potion of detect magic reveals `rand_range(1, maxReveals)`
  pack items, where `maxReveals = max(1, 2 + wisdomBonus)` — so a worn wisdom ring widens the 1–2 default
  (`Items.c:8458`).

---

## 6. Charms

Source: `charmTable_Brogue[]` at `GlobalsBrogue.c:765`; effect table
`charmEffectTable_Brogue[]` at `GlobalsBrogue.c:781`. Enum: `Rogue.h:1037`. All charms share
`range {1,2,1}` (initial enchant). On generation (`Items.c:375`): `charges = 0` (ready),
`enchant1 = randClump(range)`, then 7% chains add +1, and the charm is flagged
`ITEM_IDENTIFIED` (charms are `NEVER_IDENTIFIABLE` — appearance is plain text). Charm of fear
is commented out in the table.

| # | Charm | Freq | MktVal | Effect summary |
|---|---|---|---|---|
| 0 | health | 5 | 900 | Instantly heals `charmHealing(e) = clamp(20*e, 0,100)`% of max HP |
| 1 | protection | 5 | 800 | Shield for `charmProtection(e) = 150 * 1.35^(e-1)` (×10 internal) |
| 2 | haste | 5 | 750 | Haste for `effectDurationBase=7` × `1.20^e` turns |
| 3 | fire immunity | 3 | 750 | Fire immunity, base 10 × `1.25^e` turns |
| 4 | invisibility | 5 | 700 | Invisibility, base 5 × `1.20^e` turns |
| 5 | telepathy | 3 | 700 | Telepathy, base 25 × `1.25^e` turns |
| 6 | levitation | 1 | 700 | Levitation, base 10 × `1.25^e` turns |
| 7 | shattering | 1 | 700 | Shatters nearby walls; radius `charmShattering(e) = 4 + e` |
| 8 | guardian | 5 | 700 | Summons a guardian; lifespan `charmGuardianLifespan(e) = 4 + 2*e`, base duration 18 |
| 9 | teleportation | 4 | 700 | Teleports the player to a random location |
| 10 | recharging | 5 | 700 | Recharges staffs/charms |
| 11 | negation | 5 | 700 | Negation burst; radius `charmNegationRadius(e) = 1 + 3*e` |
| 12 | rewind | **0** | 900 | **iOS-port addition** — rewinds time up to `effectMagnitudeConstant = 10` player turns. Frequency 0 keeps it out of loot; only via the `D_REWIND_CHARM_START` debug start. (`GlobalsBrogue.c:728`, `Rogue.h:977`) |

### `charmEffectTable_Brogue` (source `GlobalsBrogue.c:781`)
Fields: `effectDurationBase`, `effectDurationIncrement` (one of the `POW_*_CHARM_INCREMENT`
arrays in `GlobalsBase.c:123`), `rechargeDelayDuration`, `rechargeDelayBase`
(`FP_FACTOR * pct/100`), `rechargeDelayMinTurns`, `effectMagnitudeConstant`,
`effectMagnitudeMultiplier`.

| Charm | durBase | durIncr | rechargeDur | rechargeBase | magConst | magMult |
|---|---|---|---|---|---|---|
| HEALTH | 3 | POW_0 (×1.0) | 2500 | 0.55 | — | 20 |
| PROTECTION | 20 | POW_0 | 1000 | 0.60 | — | 150 |
| HASTE | 7 | POW_120 (1.20^x) | 800 | 0.65 | — | — |
| FIRE_IMMUNITY | 10 | POW_125 (1.25^x) | 800 | 0.60 | — | — |
| INVISIBILITY | 5 | POW_120 | 800 | 0.65 | — | — |
| TELEPATHY | 25 | POW_125 | 800 | 0.65 | — | — |
| LEVITATION | 10 | POW_125 | 800 | 0.65 | — | — |
| SHATTERING | 0 | POW_0 | 2500 | 0.60 | 4 | — |
| GUARDIAN | 18 | POW_0 | 700 | 0.70 | 4 | 2 |
| TELEPORTATION | 0 | POW_0 | 920 | 0.60 | — | — |
| RECHARGING | 0 | POW_0 | 10000 | 0.55 | — | — |
| NEGATION | 0 | POW_0 | 2500 | 0.60 | 1 | 3 |
| REWIND (iOS) | 0 | POW_0 | 3000 | 0.60 | 10 | — |

Effect duration: `charmEffectDuration(kind, enchant) = durBase * durIncr[enchant-1]`
(`PowerTables.c:210`). Recharge delay: `charmRechargeDelay = effectDuration + rechargeDur *
rechargeBase^enchant`, floored at `rechargeDelayMinTurns` (`PowerTables.c:216`). So higher
enchant = longer effect **and** shorter relative recharge for the duration-scaling charms.

---

## 7. Potions

Source: `potionTable_Brogue[]` at `GlobalsBrogue.c:702`. Enum: `Rogue.h` `enum potionKind`. **26 kinds**
= 16 vanilla (0–15) + 5 **iOS-port** themed/returning (16–20) + 5 **iOS-port** capture-only (21–25).
`magicPolarity` +1 = beneficial, −1 = malevolent. The `range` for many is the effect duration in
turns. Appearance is a random color from `itemColorsRef` (capture-only kinds and the empty bottle are
always-identified, so their color is never shown). `numberGoodPotionKinds` = 11.

| # | Potion | Good? | Freq | MktVal | Range (effect) | Description summary |
|---|---|---|---|---|---|---|
| 0 | life | + | **0†** | 500 | 10,10 | Full heal, cure, +max HP permanently |
| 1 | strength | + | **0†** | 400 | 1,1 | +1 strength permanently |
| 2 | telepathy | + | 20 | 350 | 300 | Drink: sense all creatures (temporary). iOS: thrown at a creature → a *permanent* single-target bond (that one stays revealed). See §7b |
| 3 | levitation | + | 15 | 250 | 100 | Hover over hazards |
| 4 | **empty bottle** | + | **0✧** | 500 | 0 | iOS port: the `POTION_DETECT_MAGIC` slot, repurposed. `frequency 0` — **not** in the weighted potion draw; placed by its own additive meter (see ✧). Captures a gas/liquid/hazard → the matching, already-known potion. See §7a |
| 5 | speed (haste self) | + | 10 | 500 | 25 | Move at double speed |
| 6 | fire immunity | + | 15 | 500 | 150 | Immune to heat/fire/lava |
| 7 | invisibility | + | 15 | 400 | 75 | Temporarily invisible |
| 8 | caustic gas | − | 15 | 200 | 0 | Cloud of caustic gas (throwable) |
| 9 | paralysis | − | 10 | 250 | 0 | Paralysis gas |
| 10 | hallucination | − | 10 | 500 | 300 | Long hallucinogen |
| 11 | confusion | − | 15 | 450 | 0 | Confusion gas |
| 12 | incineration | − | 15 | 500 | 0 | Bursts into flame |
| 13 | darkness | − | 7 | 150 | 400 | Blinds; supernatural darkness cloud |
| 14 | descent | − | 15 | 500 | 0 | Ground vanishes (fall to next level) |
| 15 | creeping death (lichen) | − | 7 | 450 | 0 | Plants deadly lichen |
| 16 | honey | + | 10‡ | 400 | 20 | iOS: regenerate over time; thrown → a sticky net mire |
| 17 | vomit | − | 10‡ | 150 | 0 | iOS: rot-gas nausea cloud (a zombie's stench, bottled) |
| 18 | wort | + | 10‡ | 500 | 0 | iOS: healing-spore cloud |
| 19 | venom | − | 10‡ | 250 | 15 | iOS: poison DoT; thrown poisons the struck creature |
| 20 | detect magic | + | 10 | 350 | 0 | iOS: the *returning* detect magic — drink reveals polarity of 1–2 random **pack** items; **thrown** instead senses 1–2 undiscovered **floor** items (auras on the map). See §7b |
| 21 | acid | − | **0✦** | 300 | 15 | **Capture-only.** Thrown: `weaken()` the struck creature (defense −25/pt + accuracy/damage down) + acid splatter |
| 22 | webbing | − | **0✦** | 300 | 0 | **Capture-only.** Thrown/uncorked: lays an entangling web patch (`DF_WEB_LARGE`) |
| 23 | steam | − | **0✦** | 300 | 0 | **Capture-only.** Thrown/uncorked: a scalding steam cloud (`DF_STEAM_PUFF`) |
| 24 | ice | − | **0✦** | 300 | 5 | **Capture-only.** Thrown/uncorked: a freezing cloud — freeze 3 turns → slow, douses flame, freezes water it covers. Bolt-detonable as a trap |
| 25 | water | − | **0✦** | 300 | 0 | **Capture-only.** Displays as **"bottle of water"**, not "potion of water" (`itemName` special-case, like the empty bottle). Drunk: a "flush" — douses fire, halves remaining confusion/hallucination/nausea. Thrown/uncorked: a large flood puddle (`DF_FLOOD`) — lightning-stun footing (§3 *Electrified water*), washes out scent |

† **Metered.** `POTION_LIFE` and `POTION_STRENGTH` have base `frequency = 0` in the table;
their generation is driven entirely by the metered system (see §10). Comments in the table
note "frequency is dynamically adjusted".

‡ **Themed sets (iOS port).** honey+vomit (set 1) and wort+venom (set 2) are *mutually exclusive* —
exactly one set is live per run, chosen deterministically from the seed in `shuffleFlavors`; the
other set's two kinds are marked absent (never generated, pre-identified). Detect magic (20) is
always present. Polarity of the live set is what `detect magic` / rest-insight can reveal.

✦ **Capture-only (iOS port, empty-bottle v2).** `frequency = 0` **and** deliberately absent from the
metered table (§10), so *nothing* overrides the 0 — these never generate. The only way to obtain one
is to capture a matching hazard with the empty bottle (§7a). Always identified (`shuffleFlavors`);
`magicPolarity −1` so a thrown one is treated as offensive. Adding `POTION_*` enum values shifts the
generation/ID stream → a `recordingVersionString` bump is owed at release.

✧ **Empty bottle — additive channel (iOS port, Brogue SE).** `frequency = 0` in all three variant
tables, so `chooseKind` never picks it and it never displaces a real potion (the dilution it caused
as a ninth in-pool "potion" is gone). It is placed by a dedicated self-correcting meter at the *end*
of `populateItems`, fully in addition to the per-level item budget: `rogue.emptyBottleSpawnChance`
accrues `EMPTY_BOTTLE_SPAWN_INCREMENT` (13) points per eligible depth, rolled with `rand_percent`;
a hit places one bottle (normal item heat-map) and resets the accumulator. Targets **~1 bottle every
3–4 floors**, gated to depths `[2, amuletLevel]`, no hard cap. Deterministic / save-replay-safe (reset
in `initializeRogue`; drawn after the item+gold loops so their RNG stream is unchanged). See
[`docs/design/empty-bottle-v2.md`](../design/empty-bottle-v2.md) §4.

### 7a. Empty bottle & the capture system (iOS port)

The empty bottle (slot 4) fills with the hazard you reach and becomes the matching, already-known
potion. Three capture gestures, resolved **GAS > SURFACE > LIQUID** (`emptyBottleCaptureKindForTile`,
`Items.c`):

- **Step-in** (stand on the tile): poison gas→poison, confusion→confusion, paralysis→paralysis, rot
  gas→lichen, stench/smoke→vomit, methane→incineration, darkness cloud→darkness, healing cloud→wort,
  steam→**steam**, deep/shallow water→**water**, ice→**ice**, brimstone→incineration, embers→fire
  immunity, acid splatter→**acid**, web/net→**webbing**.
- **Levitation skim** (float over an un-standable tile): lava→incineration, any `T_AUTO_DESCENT`
  (chasm/hole/trap door)→descent.
- **Bolt** (drop the bottle, zap it): lightning→speed, fire→incineration.

A once-per-kind contextual hint names the exact result while you carry a bottle. Full capture map,
hazard reference, and rationale: [TERRAIN_AUDIT.md §8–9](TERRAIN_AUDIT.md) and the design doc
[`docs/design/empty-bottle-v2.md`](../design/empty-bottle-v2.md).

### 7b. Throw & zap behavior — fire/lightning shattering a dropped potion, & which are inert

Two off-label uses exist: **throwing** a potion (shatters at the target) and **zapping** a *dropped*
potion with a fire/lightning bolt. Not every potion reacts.

- **Inert under all conditions** (thrown *and* zapped): **none anymore.** (Telepathy and detect magic
  used to be — both now have thrown effects, below. The empty bottle is harmless *thrown* but captures
  when *zapped*.)
- **Fires on any throw, target irrelevant:** **detect magic** (iOS port) — a thrown detect magic senses
  1–2 random *undiscovered* magic items lying on the dungeon **floor** (not your pack), revealing their
  polarity and marking their auras on the map. Works thrown at a creature or bare ground alike
  (`throwDetectMagicOnFloor`). Same 1–2 base count as the drink (widened by a ring of wisdom).
- **Glow-and-pass when zapped** (the bolt passes through harmlessly): the **8 benevolent potions** —
  life, strength, telepathy, levitation, speed, fire immunity, invisibility, detect magic
  (`Items.c`, "the bolt passes through the flask and its fluid glows warmly"). This sets **no flag** on
  the flask — no `ITEM_MAGIC_DETECTED`, no auto-ID. So a zap reveals polarity **by observation only**
  (good = glows & passes, bad = detonates); the game records nothing on a benevolent flask, so it stays
  unmarked in your pack and is no free mass-ID (see KNOWN_CAVEATS.md). The **empty bottle is the
  exception** — zapping it *captures* the bolt. Bad/cloud potions **detonate** (spawn their shatter
  signature and absorb the bolt), including the new acid/webbing/steam/ice/water.
- **Thrown weapons can detonate a dropped bad/cloud potion too** (iOS port, `detonateFloorPotionAt`): an
  **incendiary dart** triggers it like a *fire* bolt (cloud spawns, then the dart's blast ignites it), and
  a plain **dart / javelin** triggers it like a *lightning* bolt (cloud blooms, unignited) — a cheap,
  ammo-based potion-trap trigger. (Good potions / the empty bottle are untouched — a dart can't capture.)
- **Identification from a detonation — fire reveals only polarity for gas clouds** (iOS port). Detonating
  an *unidentified* potion normally **fully identifies** it (you saw the cloud). But a **fire** trigger
  (fire bolt / incendiary dart) erases the tell of two groups, leaving only their **polarity** (good/bad)
  — a generic "volatile flask bursts into flame" message, gated on seeing it: **(1)** the **flammable gas
  clouds** (poison / confusion / paralysis / vomit), which instantly burn into indistinguishable flame
  (data-driven — the GAS layer's own `T_IS_FLAMMABLE`); and **(2)** **incineration**, whose tell *is*
  fire and so is completely masked by the trigger's own flame (an explicit `POTION_INCINERATION` case —
  its fire sits on the SURFACE layer). Polarity is per-kind, so it persists and tags every potion of that
  appearance (see §7 ‡/✦). Every other detonation still full-IDs: non-fire triggers (lightning,
  dart/javelin, hand-throw), and fire triggers of self-evident effects (wort, honey, darkness, descent,
  flood, lichen, fungal forest, steam, ice, acid).
- **Harmless splash when thrown on bare ground but active on a direct creature hit:** strength, speed,
  levitation, fire immunity, invisibility **buff the struck creature** (throwing them at an enemy
  helps it); venom **poisons** it; **telepathy** (iOS port) **permanently bonds you to the struck
  creature** — it stays revealed on the map wherever it roams (the one "throw at an enemy" here that
  *helps you*; excludes inanimate turrets/totems; `applyPotionEffectToCreature`, `MB_TELEPATHICALLY_REVEALED`).
  life thrown bursts a healing cloud (but is inert when zapped).
- **Thrown into deep water → floats to shore, no shatter** (iOS port). A potion that lands on an open
  `T_IS_DEEP_WATER` tile (no creature/wall struck) is *not* destroyed — it's dropped in the water and the
  existing `T_MOVES_ITEMS` drift carries it ashore for recovery (`throwItem`). A potion that strikes a
  creature or wall *over* the water still shatters there; shallow water is unaffected. Consequences:
  thrown **potion of water** no longer floods existing water, and thrown **potion of ice** no longer
  freezes the crossing (it floats away — water-freezing is the staff of frost's role).

So the practical "wasted if thrown" potions are the good self-buffs thrown at *bare ground* — with the
caveats that **the empty bottle wants to be zapped, not thrown**, the **buff potions help an enemy you
directly hit**, **telepathy thrown at an enemy is a permanent tracker**, and **detect magic thrown
anywhere scouts the level's loot**. After these iOS changes, no potion is inert under every condition.

---

## 8. Scrolls

Source: `scrollTable_Brogue[]` at `GlobalsBrogue.c:736`. Enum: `Rogue.h:1053`. 14 kinds.
Appearance is a random title (`itemTitles`, assembled from `titlePhonemes`, `Globals.c:1604`).
All scrolls are `ITEM_FLAMMABLE`. `numberGoodScrollKinds` = 12.
`SCROLL_ENCHANTING.power = 1` — this is the global `enchantMagnitude()` (`Items.c:1873`).

| # | Scroll | Good? | Freq | MktVal | Effect summary |
|---|---|---|---|---|---|
| 0 | enchanting | + | **0†** | 550 | +1 magic charge to an item (see §11). `power = 1` |
| 1 | identify | + | 30 | 300 | Reveal one item fully |
| 2 | teleportation | + | 10 | 500 | Random relocation on the level |
| 3 | remove curse | + | 15 | 150 | Strip curses from equipped/carried items |
| 4 | recharging | + | 12 | 375 | Recharge all staffs & charms |
| 5 | protect armor | + | 10 | 400 | Armor immune to acid degradation; uncurses |
| 6 | protect weapon | + | 10 | 400 | Weapon immune to acid degradation; uncurses |
| 7 | sanctuary | + | 10 | 500 | Warding glyphs monsters avoid |
| 8 | magic mapping | + | 12 | 500 | Reveal level, traps, secret doors, levers |
| 9 | negation | + | 8 | 400 | Anti-magic blast in field of view |
| 10 | shattering | + | 8 | 500 | Dissolves nearby stone |
| 11 | discord | + | 8 | 400 | Visible creatures attack each other 30 turns |
| 12 | aggravate monsters | − | 15 | 50 | Wakes & alerts all monsters |
| 13 | summon monsters | − | 10 | 50 | Summons monsters next to reader |

† **Metered.** `SCROLL_ENCHANTING` has base `frequency = 0`; generation is metered (see §10).

---

## 9. Food, Keys, Gold, Lumenstones, Amulet

### Food (`foodTable[NUMBER_FOOD_KINDS]`, `Globals.c:1726`; enum `Rogue.h:854`)
The `power` column is nutrition. Always spawn `ITEM_IDENTIFIED`. Frequency-driven nutrition
guarantee in `populateItems` (~one ration per 4 levels, more when deeper).

| # | Food | Nutrition (power) | Freq | MktVal | StrReq |
|---|---|---|---|---|---|
| 0 | ration of food | 1800 | 3 | 25 | 0 |
| 1 | mango | 1550 | 1 | 15 | 0 |
| 2 | cooked food | 1800 | **0** | 15 | 0 |

**Cooked food (`COOKED_FOOD`, iOS port / Brogue SE).** Never generated naturally (frequency 0). It is
created only when a **ration of food** catches fire: a ration is the lone flammable food
(`ITEM_FLAMMABLE` set in `makeItemInto`; mangoes don't burn), and `burnItem` (`Time.c`) — when the tile
is genuinely `T_IS_FIRE`, not lava — swaps the ration's kind to `COOKED_FOOD` in place instead of
destroying it, clearing `ITEM_FLAMMABLE` so the same fire can't consume the result. Cooked food is as
filling as a fresh ration (power 1800). On top of the nutrition, **eating it grants
`STATUS_REGENERATING` for 5 turns, healing 1 HP/turn (5 HP total)** — see `eat()` and the regeneration
metering in `Time.c`. The heal-over-time reuses the honey potion's `STATUS_REGENERATING` primitive,
parameterized by a new `rogue.regenerationHeal` field (the total HP to mete across the duration: honey =
~20% of max HP, cooked food = a flat 5). Tuning: `COOKED_FOOD_REGEN_TURNS` / `COOKED_FOOD_REGEN_TOTAL`
(`Rogue.h`). Determinism-safe (the kind swap and the heal total are both set deterministically).

### Keys (`keyTable[NUMBER_KEY_TYPES]`, `Globals.c:1720`; enum `Rogue.h:848`)
Always `ITEM_IDENTIFIED`, `ITEM_IS_KEY`, frequency 1, no value. Generated by blueprints, not
the normal raffle.

| # | Key | Purpose |
|---|---|---|
| 0 | door key (`KEY_DOOR`) | Opens a specific locked door |
| 1 | cage key (`KEY_CAGE`) | Opens a captive monster's cage |
| 2 | crystal orb (`KEY_PORTAL`) | Activates a commutation/portal device |

### Gold (`GOLD`)
No table entry. Quantity = `rand_range(50 + depth*10, 100 + depth*15)` (`Items.c:388`,
`depthAccelerator` = 1). Gold piles placed separately from the item raffle; count
self-corrects against `aggregateGoldLowerBound/UpperBound` past depth 6 (`Items.c:637`).

### Lumenstones (`GEM`) and the Amulet (`AMULET`)
- Below the amulet level (depth > 26), items become **lumenstones** (`GEM`). The number per
  level is `lumenstoneDistribution_Brogue` (`GlobalsBrogue.c:108`), one entry per depth from
  27 to 40: `{3,3,3,2,2,2,2,2,1,1,1,1,1,1}`. They are score-only collectibles.
- The **Amulet of Yendor** (`AMULET`) is generated `ITEM_IDENTIFIED`, kind 0, no table entry
  (`Items.c:390`). It appears at `AMULET_LEVEL` (26).

### Appearance pools (randomized per game; `Globals.c`)
- Colors (potions), `itemColorsRef[21]` (`:1630`): crimson, scarlet, orange, yellow, green,
  blue, indigo, violet, puce, mauve, burgundy, turquoise, aquamarine, gray, pink, white,
  lavender, tan, brown, cyan, black.
- Woods (staffs), `itemWoodsRef[21]` (`:1656`): teak, oak, redwood, rowan, willow, mahogany,
  pinewood, maple, bamboo, ironwood, pearwood, birch, cherry, eucalyptus, walnut, cedar,
  rosewood, yew, sandalwood, hickory, hemlock.
- Metals (wands), `itemMetalsRef[12]` (`:1682`): bronze, steel, brass, pewter, nickel,
  copper, aluminum, tungsten, titanium, cobalt, chromium, silver.
- Gems (rings), `itemGemsRef[18]` (`:1699`): diamond, opal, garnet, ruby, amethyst, topaz,
  onyx, tourmaline, sapphire, obsidian, malachite, aquamarine, emerald, jade, alexandrite,
  agate, bloodstone, jasper.
- Scroll titles built from `titlePhonemes[21]` (`:1604`).

---

## 10. Item generation & the metered system

### Per-level item count (`populateItems`, `Items.c:573`)
- Above the amulet level: `numberOfItems = 3`, then `while (rand_percent(60)) numberOfItems++`.
- Depth ≤ 2: +2 items; depth ≤ 4: +1 item (kickstart). Plus `extraItemsPerLevel` (0).
- A spawn **heat map** biases placement toward areas behind secret/regular doors
  (`fillItemSpawnHeatMap`); items are placed at random heat-weighted cells, then the map
  cools around chosen spots so items spread out. Food and potions of strength ignore the heat
  map and avoid hallways.
- Below the amulet level: items become lumenstones per the distribution above.

### Metered generation (`meteredItemsGenerationTable_Brogue`, `GlobalsBrogue.c:657`)
This system meters the appearance of the "ration"-style guaranteed items and suppresses /
biases certain scrolls and potions. Per-entry fields:
`category, kind, initialFrequency, incrementFrequency, decrementFrequency, genMultiplier,
genIncrement, levelScaling, levelGuarantee, itemNumberGuarantee`.

Mechanics (`Items.c:614`, `Items.c:731`):
- Each level, `rogue.meteredItems[i].frequency += incrementFrequency`.
- For entries with `incrementFrequency != 0`, the running `frequency` is copied into the live
  `scrollTable`/`potionTable` frequency before the raffle, then `-= decrementFrequency` and
  `numberSpawned++` whenever one actually spawns. This makes a kind progressively more likely
  the longer it hasn't appeared, and less likely right after it does.
- `levelScaling != 0` entries are **hard-thresholded**: if
  `numberSpawned*genMultiplier + genIncrement < depth*levelScaling + randomDepthOffset`, that
  exact kind is force-generated.
- `levelGuarantee`/`itemNumberGuarantee` force a kind by a specific depth if not enough have
  spawned.

The only entries with nonzero tuning are:

| Entry | initialFreq | incrFreq | decrFreq | genMult | genIncr | levelScaling |
|---|---|---|---|---|---|---|
| `SCROLL_ENCHANTING` | 60 | 30 | 50 | — | — | — |
| `POTION_LIFE` | 0 | 34 | 150 | 4 | 3 | 1 |
| `POTION_STRENGTH` | 40 | 17 | 50 | — | — | — |

All other scroll/potion kinds appear with default zeros and use their static `frequency`
from the catalog. **Important:** after each level's population, `populateItems` restores the
original potion/scroll tables (`memcpy` from saved copies, `Items.c:848`), which is what keeps
enchant scrolls and life/strength potions out of the ordinary raffle except via the metered
path or blueprints.

**This table is also why `frequency = 0` means different things for different potions.** Life and
strength sit here with a nonzero `incrementFrequency`, so their effective frequency is set at runtime
(the catalog `0` is just a placeholder — hence "frequency is dynamically adjusted" in the table).
The empty-bottle v2 capture-only potions (§7, acid/webbing/steam/ice/water) are `frequency = 0`
**and deliberately absent from this table**, so nothing ever overrides their `0` — they can never
generate, only be captured. *Rule of thumb:* freq 0 + metered = guaranteed pacing; freq 0 +
unmetered = never generated. (The same "why" is commented in `Items.c` at the metered-override loop.)

---

## 11. How enchantments are applied

### Net enchant and strength
- `netEnchant(item)` (`Combat.c:74`): `enchant1 * FP_FACTOR`, plus `strengthModifier` for
  weapons/armor, clamped to **[−20, 50]** display points (×`FP_FACTOR`).
- `strengthModifier(item)` (`Combat.c:65`): `diff = (strength − weakness) − strengthRequired`.
  If `diff > 0`: bonus `diff * 0.25`. If `diff ≤ 0`: penalty `diff * 2.5`. So being *under*
  the strength requirement is punished 10× harder than the reward for being over it.
- Combat scaling uses `accuracyFraction` / `damageFraction` (`PowerTables.c:165/142`, 1.065^x
  tables indexed by net enchant in 0.25 steps) and `defenseFraction` for armor.

### Scroll of enchanting (`readScroll`, `Items.c:7862`)
`enchantMagnitude()` returns `scrollTable[SCROLL_ENCHANTING].power` = **1**. Each read:
- `timesEnchanted += enchantMagnitude()`.
- **Weapon:** `strengthRequired = max(0, strengthRequired − 1)`; `enchant1 += 1`. Reroll
  quiver number if thrown.
- **Armor:** `strengthRequired = max(0, strengthRequired − 1)`; `enchant1 += 1`.
- **Ring:** `enchant1 += 1`; recompute bonuses (and clairvoyance display).
- **Staff:** `enchant1 += 1`; `charges += 1`; `enchant2 = 500 / enchant1` (faster recharge).
- **Wand:** `charges += range.lowerBound * 1` (gains charges in the smallest increment that
  wand can be found with — no levels).
- **Charm:** `enchant1 += 1`; `charges = min(0, charges)` (instant full recharge).
- Reaching `enchant1 >= 16` on weapon/armor/staff/ring/charm sets the `FEAT_SPECIALIST`
  achievement.
- The item is **uncursed** (`uncurse`) and re-equipped if worn.

`enchantIncrement(item)` (`Items.c:1927`) gives the *effective* per-level step shown in
tooltips for weapons/armor: `1.0` if no strength req, `3.5×` if currently under the req
(so enchanting also relieves the strength penalty quickly), `1.25×` if meeting it.

### Cursing & runic assignment at generation (`makeItemInto`, `Items.c:184`)
**Weapons** (`:249`): 40% chance to get any magic at all. If so, `enchant1 += rand(1,3)`, then:
- 50% → **cursed**: negate `enchant1`, set `ITEM_CURSED`; 33% of those also get a *bad* runic
  (`rand(NUMBER_GOOD_WEAPON_ENCHANT_KINDS, NUMBER_WEAPON_RUNIC_KINDS-1)`, i.e. `W_PLENTY`).
- else if `rand(3,10) * staggerFactor / quickFactor / extendFactor > damage.lowerBound` →
  **good runic** (`rand(0, NUMBER_GOOD_WEAPON_ENCHANT_KINDS-1)`). Lower-damage weapons are
  thus more likely to be runic. If the runic is `W_SLAYING`, pick a random `vorpalEnemy`.
- else 10%-chained extra `enchant1++`.

**Armor** (`:297`): same 40% gate. `enchant1 += rand(1,3)`, then:
- 50% → **cursed** (negate, `ITEM_CURSED`); 33% of those get a *bad* runic
  (`rand(NUMBER_GOOD_ARMOR_ENCHANT_KINDS, NUMBER_ARMOR_ENCHANT_KINDS-1)`: `A_VULNERABILITY` or
  `A_IMMOLATION`).
- else if `rand(0,95) > armor` → **good runic** (`rand(0, NUMBER_GOOD_ARMOR_ENCHANT_KINDS-1)`).
  Lower-armor pieces are more likely to be runic. `A_IMMUNITY` picks a random `vorpalEnemy`.
- else 10%-chained extra `enchant1++`.

**Rings** (`:365`): 16% cursed (negate enchant), else 10%-chained extra `enchant1++`.

Throwing weapons can never be cursed/runic/magical (`Items.c:284`).

### Auto-identification
- **Item-kind ID** (`identifyItemKind`, `Items.c:6460`): marks the whole kind identified;
  cascades via `tryIdentifyLastItemKinds` (if all but one kind in a category are known, the
  last is deduced). A ring with `enchant1 <= 0` and a single-charge-range wand are flagged
  `ITEM_IDENTIFIED` directly.
- **autoIdentify** (`Items.c:6507`): identifies the kind on use, and reveals a weapon/armor
  **runic** (`ITEM_RUNIC_IDENTIFIED`) when its effect triggers in combat (`Combat.c:955`,
  `:1150`).
- **Time/kill-based reveal:** weapons reveal enchant/runic after `weaponKillsToAutoID` = 20
  kills (`charges` countdown set at generation); armor after `armorDelayToAutoID` = 1000 turns
  worn; rings after `ringDelayToAutoID` = 1500 turns worn.
- Potions of hallucination thrown can self-ID once all good potions are known
  (`Items.c:6269`).

---

## 12. Enchantment effects: behavior vs. stats

A common question is whether enchanting an item ever grants a genuinely **new ability**
(e.g. "does a high-level lightning staff start hitting multiple enemies?"). Tracing the
scaling code (`PowerTables.c`) and the runic/bolt application code (`Combat.c`,
`GlobalsBrogue.c`), the answer is: **almost never.** Pass-through bolts, instakills, and
similar behaviors are *inherent* properties present at +1 — enchanting only scales them.
Every enchant-driven change falls into one of four buckets:

### (a) More spawned entities (count scales) — the only "feels like a new ability" case

| Item | What scales with enchant | Formula | Source |
|---|---|---|---|
| Staff of conjuration | number of spectral blades summoned | `staffBladeCount = enchant × 1.5` | `PowerTables.c:54` |
| Weapon of multiplicity | number of spectral duplicates (and their accuracy) | `weaponImageCount = clamp(enchant/3, 1, 7)`; clone accuracy = `player.accuracy + 5×enchant` | `PowerTables.c:107`, `Combat.c:881` |
| Armor of multiplicity | number of spectral clones of the attacker | `armorImageCount = clamp(enchant/3, 1, 5)` | `PowerTables.c:112`, `Combat.c:1005` |

### (b) Proc chance — scales for weapon runics, mostly **fixed** for armor runics

- **Weapon runics**: trigger chance rises with enchant, each runic with its own decay curve
  (heavier weapons proc less often). `runicWeaponChance`, `PowerTables.c:224`. Exceptions:
  **slaying** is binary (100% vs its vorpal class, else 0%, `Combat.c:785`); bad runics are a
  flat 15% (`PowerTables.c:308`).
- **Armor runics** — proc chance does **not** scale with enchant (`Combat.c:1002`):
  - multiplicity → **fixed 33%** (`Combat.c:1004`); burden → fixed 10% (`Combat.c:1123`);
    immolation → fixed 10% (`Combat.c:1138`)
  - mutuality, absorption, reprisal, immunity, vulnerability → **always trigger** (no roll);
    only their *magnitude* scales
  - **reflection** is the one armor effect whose *chance* scales — `reflectionChance` climbs
    toward 100% (`PowerTables.c:113`)

### (c) Duration / magnitude / distance (effect "size," not behavior)

Staff blink distance, haste/discord/entrancement duration, poison stacks, protection shield;
weapon paralysis/confusion/slow duration and **force knockback distance**; charm magnitudes,
durations, recharge delay, and **negation radius** / guardian lifespan. Sources:
`PowerTables.c:52-106` and `:210-222`.

### (d) Pure stats (no behavior change)

Weapon/armor base damage/accuracy/defense fractions, ring bonuses (regeneration, stealth,
etc.), and the ring of wisdom's staff-recharge multiplier. Sources: `PowerTables.c:142-208`,
`:76-85`.

### Inherent properties that enchanting does **not** grant

These are set by bolt/item flags and apply at every enchant level:
- **Lightning, spark, dragonfire** carry `BF_PASSES_THRU_CREATURES` (`GlobalsBrogue.c`
  `boltCatalog_Brogue`), so they hit *every* creature in their line even at +1. Enchanting
  only raises their damage (`staffDamage`, `PowerTables.c:51`). They gain no extra reflections
  or targets from enchanting.
- **Firebolt / dragonfire** ignite flammable terrain (`BF_FIERY`); **tunneling** passes through
  walls — both inherent, level-independent.
- **Weapon of slaying** / **armor of immunity** are binary vs. their vorpal monster class
  (`vorpalEnemy`), not scaled.

---

## 13. Charges, depletion & destruction

Do items break from use? **No — normal use never destroys an item.** Use either consumes a
single-use item or decrements a charge; the only effect that outright *destroys* an item
(outside of consumption) is the commutation-altar shatter below.

### Use & charge behavior (`useStaffOrWand`, `Items.c:7442`)
- **Potions / scrolls / food** — single-use; consumed via `consumePackItem` (`Items.c:7568`),
  which decrements `quantity` and removes the item only when the last one is used. Used up,
  not "broken."
- **Staffs** — charges decrement on use (`Items.c:7539`); at 0, *"fizzles; it must be out of
  charges for now"* (`Items.c:7519`). Staffs **recharge over time** and remain in the pack.
- **Wands** — charges decrement on use; at 0, *"fizzles; it must be depleted"* (`Items.c:7521`).
  Wands **do not recharge**, but the depleted wand **stays in inventory** (useless, not
  destroyed). `enchant2` counts discharges for the player's convenience (`Items.c:7541`).
- **Charms** — go on a recharge cooldown (`charges` counts down) after use, then become usable
  again. Never destroyed.
- **Weapons / armor** — never break. They can be **corroded** (enchant level reduced) by acid
  mounds / acidic jellies, but the item persists.

### The one destruction-by-effect: commutation-altar shatter
`swapItemToEnchantLevel` (`Items.c:1138`) is the only place a game effect destroys an item. At a
**commutation altar** (paired altars carrying `TM_SWAP_ENCHANTS_ACTIVATION` that swap two items'
enchant levels, `swapItemEnchants`, `Items.c:1213`), if the swap would drop:
- a **staff below +2**, or
- a **charm below +1**, or
- a **wand below 0**,

the item *"shatters from the strain!"* and is removed (`Items.c:1142-1160`). This is a guard
against commuting a staff/charm/wand down to a nonfunctional enchant level — it is triggered by
the altar swap, **not** by using the item.

---

## 14. iOS-port-only items

- **Charm of rewinding** (`CHARM_REWIND`, `charmTable_Brogue` index 12, frequency 0) is an
  iBrogue addition, marked `// iOS port (iBrogue):` at `GlobalsBrogue.c:727` /
  `GlobalsBrogue.c:744` and `Rogue.h:977`. It is debug-only (obtainable via
  `D_REWIND_CHARM_START`) and never enters the loot pool.
