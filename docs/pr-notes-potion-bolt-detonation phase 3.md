# PR notes — upstream BrogueCE (`potion-bolt-detonation`)

> Draft body for the upstream PR. **Not yet opened** — paste/adapt into the GitHub PR when ready.
> Branch `potion-bolt-detonation` is pushed to your fork (commit `9be626a`, off `master`).
> Open against upstream with:
> `https://github.com/tmewett/BrogueCE/compare/master...sethhoward:BrogueCE:potion-bolt-detonation?expand=1`
> The commit is authored by you with no AI-attribution trailer.

---

## Bolt-triggered potion detonation: dropped potions as traps / ranged ID

A fire or lightning bolt that passes over a **dropped** potion now detonates it in place. A dropped
bad potion becomes a placeable trap and a ranged way to identify it — bolt an unknown flask to see
what it does, lay a gas trap in a doorway, or ignite one on a chasing pack. Fire and lightning differ:
fire is **violent** (the released flammable gas ignites), lightning is **gentle** (the gas just
spreads).

## Motivation

A potion you drop on the floor is inert until something walks into it. Meanwhile fire and lightning
bolts already interact richly with terrain (igniting grass, electrifying water) but ignore items.
Letting a bolt set off a dropped potion turns a flask into a deliberate tool and gives fire/lightning
staffs a second, terrain-driven use — without any new command, key, or UI.

It also reads naturally: a flask of caustic gas struck by a firebolt *should* go up; one zapped by
lightning *should* just break and release its gas.

## Balance & design

- **Only the seven cloud/explosion potions react** — poison (caustic), confusion, paralysis,
  incineration, darkness, descent, creeping death — exactly the set that already produces a shatter
  signature when thrown. Good potions and hallucination (which "splash harmlessly" when thrown) get
  no bolt signature, so a stray bolt never wastes a useful dropped potion through this feature.
- **Violent vs gentle is emergent, not hand-tuned.** Detonation simply spawns the potion's ordinary
  shatter dungeon feature. The fire bolt's *existing* per-cell `exposeTileToFire` then ignites the
  flammable gas (caustic/confusion/paralysis gas already carry `T_IS_FLAMMABLE`); lightning has no
  fire step, so the same gas lingers as a cloud. Incineration explodes either way (its nature).
- **Identification mirrors throwing.** A detonated bad potion auto-identifies exactly as a thrown one
  does, and the firing staff/wand auto-identifies from the visible detonation.

## Technical implementation

### A. Shared shatter helper
The bad-potion kind→dungeon-feature/message mapping is extracted from `throwItem` into a new
`static boolean shatterPotionAtLoc(item *theItem, short x, short y)`. It spawns the signature DF,
prints the shatter message, auto-identifies the flask, refreshes the cell, and returns `true` for the
seven cloud/explosion kinds (`false` otherwise). `throwItem`'s inline switch is replaced by a call to
it, so the mapping now lives in one place.

### B. Bolt hook in `updateBolt`
A small block in `updateBolt`, placed right after the `pathDF` spawn and **before** the existing
`BF_FIERY` `exposeTileToFire` block, so a fire bolt ignites the gas the hook just spawned:
```c
if (theBolt->flags & (BF_FIERY | BF_ELECTRIC)) {
    item *floorPotion = itemAtLoc((pos){ x, y });
    if (floorPotion && (floorPotion->category & POTION) && shatterPotionAtLoc(floorPotion, x, y)) {
        removeItemFromChain(floorPotion, floorItems);   // teardown mirrors burnItem()
        deleteItem(floorPotion);
        pmap[x][y].flags &= ~(HAS_ITEM | ITEM_DETECTED);
        if (lightingChanged) { *lightingChanged = true; }
        if (autoID)          { *autoID = true; }
    }
}
```
`updateBolt` is invoked per path cell for both fiery and electric bolts, so a bolt detonates every
dropped bad potion it crosses. Item teardown matches `burnItem` (unchain → delete → clear
`HAS_ITEM | ITEM_DETECTED`), which `itemAtLoc` requires to stay consistent.

## Behavior matrix

| Potion | 🔥 Fire bolt | ⚡ Lightning bolt | Auto-IDs? |
|---|---|---|---|
| Caustic gas | gas ignites → fire (cloud burns away) | lingering caustic cloud | yes |
| Confusion | gas ignites → fire | lingering confusion cloud | yes |
| Paralysis | gas ignites → fire | lingering paralysis cloud | yes |
| Incineration | explosion | still explodes (volatile) | yes |
| Darkness | darkness cloud | darkness cloud | yes |
| Descent | chasm opens; bolt continues | chasm opens | yes |
| Creeping death | lichen plants then burns (fire purges) | lichen spreads | yes |
| Hallucination + the 8 good potions | no effect | no effect | no |

## Impact on gameplay

- **A dropped potion becomes a tool** — set a gas trap, or detonate a cache as enemies close in.
- **Fire/lightning staffs gain reach into the item layer** without new inputs.
- **Minimal footprint** — one new helper + one hook, all in `Items.c`, reusing the existing shatter
  features, `itemAtLoc`, and the `burnItem` teardown pattern. No new commands, tiles, or DFs.

## Determinism & compatibility

No RNG is drawn on the common bolt path: the hook is an `itemAtLoc` lookup plus a category test, and
`spawnDungeonFeature` on a gas-layer feature is a pure write. Seeds and recordings are unchanged
unless a bolt actually detonates a dropped potion, in which case the divergence is identical in
character to *throwing* that potion (same dungeon features; the fire ignition uses the existing
`exposeTileToFire` path, forced with `alwaysIgnite`, so it draws no `rand_percent` of its own). No new
RNG primitive is introduced. Change is confined to `src/brogue/Items.c`.

## Testing

- Drop incineration → firebolt → explosion; lightning → still ignites. Flask consumed + identified.
- Drop caustic/confusion/paralysis → firebolt → gas ignites into fire (violent); lightning → gas
  cloud lingers (gentle). Flask consumed + identified.
- Drop darkness → bolt → darkness cloud; drop descent → bolt → chasm opens, bolt continues across.
- Drop a good potion or hallucination → bolt → no effect, not identified.
- Confirm the firing staff/wand identifies from the detonation, and a bolt crossing several dropped
  potions detonates each.
- Record → replay a session that bolts a few dropped potions (incl. a fire-ignited gas and a descent
  hole) → no desync.
