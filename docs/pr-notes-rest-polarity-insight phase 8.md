# PR notes — upstream BrogueCE (`rest-polarity-insight`)

> Draft body for the upstream PR. **Not yet opened** — paste/adapt into the GitHub PR when ready.
> Branch `rest-polarity-insight` is pushed to your fork (commit `9c84c53`, off `master`).
> Open against upstream with:
> `https://github.com/tmewett/BrogueCE/compare/master...sethhoward:BrogueCE:rest-polarity-insight?expand=1`
> Authored by you with no AI-attribution trailer.

---

## Resting gradually reveals item polarity

Resting now slowly chips away at the unknown. Each rested turn accrues toward a threshold; on reaching
it, the **polarity** (benevolent/malevolent) of the first still-unknown item in your pack is revealed —
the same thing detect magic does to a single item — announced with a colored *"while resting, you sense
the benevolent/malevolent aura of …"* message that interrupts any in-progress auto-rest so you notice it.
It **never grants a full identification**, only the good/bad sigil.

The cadence tapers as the run goes on:

```
threshold (in rested turns) = 120 + 30 * (polarity kinds you already know)
```

So it's most generous early — when the unknowns are most punishing — and slows to a near-stop once you've
learned most kinds.

## Motivation

Resting is one of Brogue's central risk/reward levers, and deliberately a double-edged one — both
punishing and rewarding:

- **It's a hunger sink.** Nutrition drains one per turn (`decrementPlayerStatus`), and a single `Z` can
  burn dozens to hundreds of turns. Every turn spent resting is food you can't get back; over-rest and you
  slide Hungry → Starving → dead. Resting is never free.
- **It's a scoring and economy decision.** Your score is your treasure haul (gold, and gems at 500 gold
  each), and the richest pickings sit deep. Resting to top off HP is what lets you survive far enough down
  to grab them — but the food it costs is the same food you need to climb back out with the Amulet. How
  much you rest is a constant bet against how much you can still carry out alive.
- **It's survival itself.** Healing between fights is mostly done by resting; it's how you stay alive long
  enough to win at all.

So a player is *already* weighing "rest now?" against hunger, depth, score, and escape on nearly every
screen. This feature hangs slow identification progress on that existing decision: the resting you'd do
anyway to heal now also chips, slowly, at the identification wall — but it's paid for out of the very same
food economy that punishes over-resting. It adds value to a costly action rather than handing out a free
new lever, and it never removes the core gamble (polarity only, never a full ID, and it tapers off as you
learn more). Resting stays exactly what it already is — both punishing and rewarding.

## Balance & design — it stays a gamble

- **Polarity only, never a full ID.** It reuses `detectMagicOnItem` on one item, so it reveals exactly the
  good/bad sigil and nothing more.
- **Self-tapering.** Because the threshold grows with the number of polarity kinds already known
  (`identified || magicPolarityRevealed` across potions/scrolls/rings/wands/staffs), the late game — where
  cheap reveals would trivialize the remaining deductions — sees reveals slow dramatically. The two
  constants (`POLARITY_INSIGHT_BASE_TURNS`, `POLARITY_INSIGHT_TURNS_PER_KIND`) are the tuning knobs.
- **Deterministic item choice.** It reveals the *first* still-unknown item in pack order. Neutral-polarity
  items (a 0-enchant ring, an empty wand) are skipped — their polarity never resolves to good/bad, so they
  would otherwise be picked every milestone and mislabeled.
- **No new information channel.** The auto-ID of the last unknown kind of a polarity
  (`tryIdentifyLastItemKinds`) behaves exactly as it already does after any reveal.

## Technical implementation

- New `playerCharacter.restTurnsSinceInsight` accumulator.
- New `void gainPolarityInsightFromRest(void)` in `Items.c` (declared in `Rogue.h`), plus a file-local
  `static int knownPolarityKindCount(void)`. The function increments the accumulator, computes the
  threshold, finds the first eligible item, calls `detectMagicOnItem` + `tryIdentifyLastItemKinds`, prints
  the message, resets the accumulator, and sets `rogue.disturbed`. It reuses only existing engine symbols
  (`detectMagicOnItem`, `tryIdentifyLastItemKinds`, `itemMagicPolarity`, `itemMagicPolarityIsKnown`,
  `itemKindCount`, `tableForItemCategory`, `itemName`, `messageWithColor`).
- One call site in `playerTurnEnded` (`Time.c`), gated on `rogue.justRested`, just before the
  `justRested` reset.

**Why count in `playerTurnEnded` and not at the command dispatch:** `autoRest` re-records each rested turn
as a `REST_KEY` event, so one `Z` press replays as N separate rests. Counting at the keystroke dispatch
would tally 1 during play but N on replay. The turn-resolution chokepoint, gated on `justRested`, is the
one place that counts identically live and on replay. (A consequence is that a long `Z` rest counts as
many rests, not one — which is the intended unit.)

## Impact on gameplay

- Eases the early-game identification chore for players who rest, without handing out full IDs.
- No power creep late: reveals slow to near-zero once most kinds are known.
- Scoped to the five intrinsic-polarity categories; weapons/armor (which detect magic can fully ID at
  0/0/non-runic) are untouched by this path.

## Determinism & compatibility

The reveal draws **no RNG** (pure flag-flipping), and the accumulator is updated at a replay-identical
point, so a recording made under this version replays byte-for-byte. It is, however, a deterministic
**gameplay-rule** change: recordings and seed playthroughs made *before* it will diverge on replay. That
warrants a `recordingVersionString` bump (per-variant) — I've left that to your release process and have
**not** bumped it in this branch. Brogue stores games as recordings, so the new struct field adds no
serialized save format to break.

## Testing

- Built with `make GRAPHICS=NO TERMINAL=YES` (strict flags: `-std=c99 -Wall -Wpedantic -Werror=implicit
  -Wmissing-prototypes`); no new warnings.
- Early game, nothing identified: rest until ~120 turns elapse → the first unknown pack item's polarity is
  revealed, message colored good/bad, auto-rest stops. Never a full ID.
- After identifying several kinds: the gap between reveals visibly lengthens.
- A pack with only neutral/known items: no reveal fires (milestone is held until an eligible item exists).
- Record a session that rests through several reveals, then replay → no desync.
