# PR notes — upstream BrogueCE (`insight-altar`)

> Draft body for the upstream PR. **Not yet opened** — paste/adapt into the GitHub PR when ready.
> Branch `insight-altar` is pushed to your fork (commit `a9c10e9`, off `master`).
> Open against upstream with:
> `https://github.com/tmewett/BrogueCE/compare/master...sethhoward:BrogueCE:insight-altar?expand=1`
> Authored by you with no AI-attribution trailer.
>
> **Heads-up for review (the two things most likely to need discussion):**
> 1. **This is new dungeon content that changes level generation** at the forced depths — existing seeds
>    diverge there, so it needs a `recordingVersionString` bump at release (left to you/maintainers; not
>    bumped in this branch).
> 2. **Placement is *guaranteed* at fixed depths** (a deliberate design choice), which is a stronger,
>    more reliable boon than a rare reward-room find. The cadence is a one-line knob if a rarer raffle is
>    preferred.

---

## Altars of insight — sacrifice one item to reveal another

A new reward room: a linked **pair** of altars (an *altar of insight* and an *altar of offering*), built
like the commutation altars. Drop the item you want to learn about on the insight altar and a payment item
on the offering altar. When both hold items, the offering is consumed and the other item is revealed, then
both altars go inert.

The reveal **scales with what you pay**:

- **Sacrifice an unidentified item** (a real gamble — you might be giving up something precious) → the
  offered item is **fully identified**.
- **Sacrifice an identified item** (a known, controlled cost) → the offered item gets only its
  **polarity/aura** revealed (the detect-magic effect on one item).

It **fires only if it helps** — it never consumes the payment unless the offered item would actually gain
information. A `+0` non-runic weapon/armor reveals as mundane ("no aura"); an already-known item, or only
one altar occupied, does nothing.

## Placement

Force-built in `addMachines()` at depths **5, 15, 25** (`depth >= 5 && (depth - 5) % 10 == 0`), Brogue
variant only — the same mechanism that guarantees the amulet vault and BulletBrogue's L1 weapon vault
(a `for (failsafe = 50…) buildAMachine(…)` loop; best-effort, skipped on the rare level where no room fits).
It is **force-only** (no `BP_REWARD`, frequency 0), so it never enters the random reward raffle.

## Motivation

It eases identification without the free-information problem of detect magic: every use **costs a whole
item**, the altar is one-shot, and the risk dial (gamble an unknown for a full ID, or spend a known item
for just polarity) keeps identification a decision rather than a formality.

## Technical implementation

- **`Rogue.h`:** three tiles (`INSIGHT_ALTAR_INSIGHT` / `_PAYMENT` / `_INERT`), `DF_ALTAR_INSIGHT_INERT`,
  `TM_INSIGHT_ACTIVATION = Fl(26)`, and a machine type `MT_INSIGHT_ALTAR` aliased to
  `MT_REWARD_HEAVY_OR_RUNIC_WEAPON` — both occupy the variant-specific reward slot (index 72), each filled
  only in its own variant's catalog and force-built only under its own variant guard, so they never collide.
- **`Globals.c`:** a back color, three `tileCatalog` rows (modeled on `COMMUTATION_ALTAR`), and the
  promote-to-inert dungeon feature.
- **`Items.c`:** `performInsightSacrifice()` + a sibling block in `updateFloorItems`, structurally identical
  to the commutation-altar block (activation `TM_*` flag, machineNumber, the `nextItem`-skip guard, then
  `activateMachine`). Reveal reuses `identify` / `detectMagicOnItem` / `tryIdentifyLastItemKinds`.
- **`GlobalsBrogue.c`:** the blueprint, appended at index 72 (so it matches `MT_INSIGHT_ALTAR`).
- **`Architect.c`:** the depth-gated, variant-gated force-build in `addMachines`.

## Determinism & compatibility

The reveal handler draws **no RNG** (flag/table flips + a deterministic machine scan), and saves are
recordings (no serialized struct format to change). Because the room is **force-only**, the BP_REWARD
raffle is byte-unchanged at every depth — the only seed divergence is on the forced levels (5/15/25, Brogue
only), where placing the room consumes RNG. As new dungeon content this alters level layout for existing
seeds, so it warrants a **per-variant `recordingVersionString` bump at release** (not done in this branch).
RapidBrogue and BulletBrogue are untouched.

## Testing

- Built with `make GRAPHICS=NO TERMINAL=YES` (strict flags: `-std=c99 -Wall -Wpedantic -Werror=implicit
  -Wmissing-prototypes`); no new warnings.
- Descend to depth 5 (then 15, 25): the room is present every time; it does not appear on other depths.
- Sacrifice an unidentified item → the offered item is fully identified; sacrifice an identified item →
  only its polarity is revealed.
- Offer a `+0` non-runic weapon → revealed mundane ("no aura") and identified; offer an already-known item,
  or fill only one altar → nothing happens and the payment is kept.
- Record a run that uses the altar, then replay → no desync.
