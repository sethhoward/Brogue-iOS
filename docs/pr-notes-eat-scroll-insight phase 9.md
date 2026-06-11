# PR notes — upstream BrogueCE (`eat-scroll-insight`)

> Draft body for the upstream PR. **Not yet opened** — paste/adapt into the GitHub PR when ready.
> Branch `eat-scroll-insight` is pushed to your fork (commit `34c4648`, off `master`).
> Open against upstream with:
> `https://github.com/tmewett/BrogueCE/compare/master...sethhoward:BrogueCE:eat-scroll-insight?expand=1`
> Authored by you with no AI-attribution trailer.

---

## Eating lets you study an unidentified scroll

Eating a meal when **nothing is hunting you** now reveals the **polarity** (benevolent/malevolent) of the
first still-unknown scroll in your pack — a quiet moment to study a scroll while you eat — announced with a
colored message:

> *you study a scroll intently while eating; it radiates a benevolent aura.*

It's polarity only, the same thing detect magic does to a single item, and **never a full identification**.
If any creature is in the **"(Hunting)"** state, or you carry no unknown scroll, the meal proceeds normally
with no reveal.

## Motivation

Eating is one of the few genuinely calm beats in a run — you only do it when you're safe enough to spend the
turns, and food is scarce. That makes it a natural, self-limiting moment to "read" something. This hangs a
small, slow identification aid on that beat: a meal taken in safety buys you one scroll's polarity, paid for
with the food economy you're already managing, and gated so you can't do it mid-fight. It's a companion to
the resting-reveal idea, scoped to scrolls (the things you read).

## Balance & design — it stays a gamble

- **Polarity only, never a full ID** — reuses `detectMagicOnItem` on one scroll.
- **Safety-gated.** It fires only when no creature is in `MONSTER_TRACKING_SCENT` (the state the UI labels
  "(Hunting)"). Sleeping, wandering, and fleeing monsters, allies, and captives don't block it — so a lull
  is reachable even deep down, but the moment something is actually after you, the calm (and the reveal) is
  gone.
- **Self-limiting.** One scroll per safe meal; meals are scarce, so there's no need for a meter and there's
  no stored state.
- **Deterministic target.** The first still-unknown scroll in pack order; neutral-polarity items are skipped
  (scrolls are always good/bad, but the guard keeps it robust).

## Technical implementation

- New `void gainScrollInsightFromEating(void)` in `Items.c` (declared in `Rogue.h`): iterates `monsters` for
  the Hunting gate, walks `packItems` for the first unknown-polarity scroll, then calls `detectMagicOnItem`
  + `tryIdentifyLastItemKinds(SCROLL)` and prints the colored message. Reuses only existing engine symbols
  (`detectMagicOnItem`, `tryIdentifyLastItemKinds`, `itemMagicPolarity`, `itemMagicPolarityIsKnown`,
  `messageWithColor`).
- One call site: `eat()`, just before its `return true`. `eat()` is invoked once per `apply` command, so the
  reveal happens exactly once per successful meal.

## Impact on gameplay

- A gentle, safety-gated nudge against the scroll-identification wall, scoped to the calm act of eating.
- No power creep: polarity only, one per scarce meal, and never while threatened.
- Works across all variants (food, scrolls, and `eat()` are shared).

## Determinism & compatibility

The reveal draws **no RNG** and stores **no state**, and `eat()` runs identically during play and on replay
(unlike a rest-until-better loop, a meal is a single command), so recordings replay byte-for-byte. Brogue
stores games as recordings, so there's no serialized save format to change. It is a deterministic
**gameplay-rule** change, so recordings and seed playthroughs made *before* it will diverge on replay; that
warrants a `recordingVersionString` bump (per-variant) — left to your release process, **not** bumped in this
branch.

## Testing

- Built with `make GRAPHICS=NO TERMINAL=YES` (strict flags); no new warnings.
- Safe (nothing hunting), holding ≥1 unidentified scroll: eat a ration/mango → one scroll's polarity is
  revealed, colored; eat again → the next unknown scroll.
- A monster in the "(Hunting)" state: eat → normal meal, no reveal.
- No unknown scrolls: eat → normal meal, no reveal.
- Record a session that eats through several reveals, then replay → no desync.
