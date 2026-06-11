# PR notes — upstream BrogueCE (`potion-throw-good-effects`)

> Draft body for the upstream PR. **Not yet opened** — paste/adapt into the GitHub PR when ready.
> Branch `potion-throw-good-effects` is committed locally off `master` (commit `924b2a6`).
> The commit carries a `Co-Authored-By: Claude` trailer — strip it with `git commit --amend` if you'd
> rather it not appear on the upstream contribution.

---

## Deductive Throwing: identify good potions by throwing them at creatures (+ potion of life healing cloud)

Throwing an unidentified **good** potion at a creature now applies that potion's effect to the
creature it shatters on, with a visible flavor tell that auto-identifies the potion. Potion of life
additionally bursts into the existing bloodwort healing gas. Identification of the good-potion
cluster becomes a *ranged, risky diagnostic* rather than something you can only learn by drinking in
a safe corner.

## Motivation

Brogue already has three ways to narrow potion identity — throwing (gas potions make a tell-tale
cloud), detect magic (polarity), and auto-ID by use. All three reliably reveal the *bad* potions.
The residual identification slog is discriminating the **good cluster** (life vs strength vs
telepathy vs levitation vs detect-magic vs haste vs fire-immunity vs invisibility), which today can
only be resolved by *drinking* — encouraging the well-known "drink unknowns in a safe corner" ritual.

Today a thrown good potion just "splashes harmlessly". This PR gives a thrown good potion a
**consequence on the creature it hits**:

- *the goblin looks healthier* → **life**
- *the goblin's muscles bulge* → **strength**
- *the goblin speeds up* → **haste**
- *the goblin floats into the air* → **levitation**
- *the goblin shimmers and vanishes* → **invisibility**
- *flames on a burning goblin go out* → **fire immunity**

Now you can spend a potion to learn what it is — but throwing a *good* potion at an *enemy* helps the
enemy, so it is a genuine gamble, not free information.

## Balance & design

- **Effect always applies; the tell + auto-ID are gated on visibility.** The creature is mechanically
  affected even if you can't see it, but you only identify the potion when you can actually witness
  the result (`canSeeMonster`, which includes telepathy). Lobbing a potion into the dark wastes it
  without leaking its identity.
- **Throwing a good potion at an enemy benefits the enemy** (heal, +max HP, haste, or — worst —
  turning it invisible). That downside is the cost of the diagnostic.
- **The player is never a valid target.** A thrown good potion that would shatter on the player's own
  tile (a point-blank throw into an adjacent wall, or a monster-thrown potion) does nothing — no free
  self-buff.
- **Fire immunity identifies only when it does something observable.** It IDs solely by *visibly
  snuffing flames* on a creature that is burning, visible, and not already fire-immune (and not an
  innately fiery monster). Thrown at anything else it silently grants immunity without identifying —
  no invented "it shimmers" tell.
- **Telepathy and detect magic are player-only** and produce no effect, no ID — they fall through to
  the existing harmless-splash message.
- Strength has no monster strength stat, so it stands in as a permanent **+maxHP / +currentHP** buff
  (≈ half a life potion's magnitude).

## Technical implementation

### A. Per-creature effect helper

A new `static boolean applyPotionEffectToCreature(creature *monst, short potionKind, short magnitude)`
(in `Items.c`, just above `drinkPotion`, forward-declared above `throwItem`). It applies the
mechanical effect and returns `true` only when a player-visible tell was produced — which is what
drives `autoIdentify`. It reuses the existing creature-effect helpers (`heal`, `haste`,
`imbueInvisibility`, `extinguishFireOnCreature`) so the kind→effect mapping lives in one place:

```c
case POTION_FIRE_IMMUNITY: {
    boolean alreadyImmune = monst->status[STATUS_IMMUNE_TO_FIRE]
                            || (monst->info.flags & MONST_IMMUNE_TO_FIRE);
    monst->status[STATUS_IMMUNE_TO_FIRE] = monst->maxStatus[STATUS_IMMUNE_TO_FIRE] = magnitude;
    if (!alreadyImmune && monst->status[STATUS_BURNING]
        && !(monst->info.flags & MONST_FIERY) && canSeeMonster(monst)) {
        extinguishFireOnCreature(monst);   // the flames going out is the tell
        refreshDungeonCell(monst->loc);
        return true;
    }
    return false;
}
```

`drinkPotion`'s own switch is left untouched.

### B. Throw hook

A block at the top of the potion-shatter branch in `throwItem`, before the existing bad-potion
switch. It re-fetches the struck creature at the shatter cell and, for a good potion, calls the
helper; a visible tell → `autoIdentify` + delete. With no tell it falls through **unchanged** to the
existing bad-potion clouds and the harmless-splash / hallucination-ID path. Magnitude is fixed at
`potionTable[kind].range.upperBound` (every good potion has `lowerBound == upperBound`).

### C. Potion of life → healing cloud

A new `DF_LIFE_POTION_CLOUD` dungeon feature, appended at the end of the `dungeonFeatureType` enum
with a matching `dungeonFeatureCatalog` row cloned from the bloodwort pod-burst
(`{HEALING_CLOUD, GAS, 350, 0, 0}`). A thrown potion of life spawns it (instead of splashing
harmlessly) and identifies unconditionally on shatter, like the gas potions. A direct hit also gets
the instant panacea heal from the helper; the cloud adds the lingering area heal (it heals enemies
standing in it too, consistent with `T_CAUSES_HEALING`).

## Impact on gameplay

- **Strategic enrichment** — the good-potion cluster gains a deliberate identification path with a
  real cost/benefit decision, attacking the safe-corner chug.
- **Minimalist footprint** — reuses existing effect helpers, the bloodwort `HEALING_CLOUD`, and the
  existing throw/auto-ID plumbing; one new helper, one new dungeon feature, no new commands or
  keybinds.
- **Thematic** — a hurled flask of life splashes a healing cloud; a flask of fire immunity douses a
  burning foe; a flask of invisibility makes your enemy vanish on you.

## Determinism & compatibility

No RNG is drawn on the common path: potion magnitudes are fixed, the helper draws no RNG, and
`spawnDungeonFeature` on a GAS layer is a pure volume/tile write. Seeds and recordings are therefore
byte-identical **unless** one of these new actions occurs. Two action-triggered divergences, both a
consequence of the player's throw (not of added bookkeeping):

1. Thrown fire immunity early-extinguishing a burning creature removes that creature's remaining
   per-turn `rand_range(1, 3)` burn draws (the `STATUS_BURNING` case in `decrementMonsterStatus`
   draws unconditionally per burning turn; immunity gates only the damage).
2. The life cloud's gas alters the gas map, so subsequent gas-dissipation rolls diverge.

Builds clean (terminal target) under the project flags; the change is confined to `Items.c`,
`Rogue.h`, and `Globals.c`. The `dungeonFeatureType` enum / `dungeonFeatureCatalog` are shared across
the Brogue / Rapid / Bullet variants — the new member and row are appended at the tail so every
existing index is unchanged.

## Testing

- Debug-grant unidentified life / strength / haste / levitation / invisibility / fire-immunity; throw
  each at an ally and at an enemy → correct effect + tell + auto-ID.
- Fire immunity: at a non-burning creature → no ID (silent immunity); at a burning creature → flames
  go out + ID; at an already-immune creature → no ID.
- Telepathy / detect magic at a creature, and any good potion thrown into the dark or at empty floor
  → harmless splash, no ID (life still makes its cloud + IDs).
- Potion of life → healing cloud forms, heals creatures inside, dissipates like bloodwort.
- Record → replay a session with several throws (including a fire-immunity snuff and a life cloud) →
  no desync.
