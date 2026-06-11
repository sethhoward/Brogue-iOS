# PR notes — upstream BrogueCE (`potion-candidate-ui`)

> Draft body for the upstream PR. **Not yet opened** — paste/adapt into the GitHub PR when ready.
> Branch `potion-candidate-ui` is pushed to your fork (commit `fc10b43`, off `master`).
> Open against upstream with:
> `https://github.com/tmewett/BrogueCE/compare/master...sethhoward:BrogueCE:potion-candidate-ui?expand=1`
> Authored by you with no AI-attribution trailer.

---

## Candidate-narrowing line for unidentified potions and scrolls

Inspecting an **unidentified potion or scroll** now appends a single line showing how far you've
narrowed it down — e.g. *"You have narrowed it down to one of 3 remaining beneficial potions."* It's
the count of kinds the item could still be, filtered by its polarity when that's known, and colored
good/bad accordingly. It never lists candidate names.

## Motivation

Players already do this bookkeeping by hand: "I've identified 4 potions and detect-magic flagged this
one good, so it's one of the three remaining good potions." This surfaces that running tally in the
inspect panel instead of asking the player to track it on paper or in their head. It's a pure
quality-of-life readout — the kind of thing the existing magic-polarity sigil already started.

## Balance & design — it reveals nothing new

This is the important part for a feature that touches identification:

- The count is **derived entirely from information the player already has**: which kinds are identified
  (public, per-kind) and this item's polarity *if* it's already known (via detect-magic, or the per-kind
  reveal, or elimination). It introduces **no new information channel** — no flavor grouping, no new
  polarity source.
- It **can never hand out a free identification.** The engine already auto-identifies the last unknown
  kind of a polarity via `tryIdentifyLastItemKinds` (fired from every identification path), so an
  unidentified item's candidate count is always ≥ 2. The line is rendered **only when the count is ≥ 2**,
  so it can never read "one of 1" and reveal an item by elimination.
- It **never enumerates candidate names** — count and polarity only.

## Technical implementation

A new `static short candidateKindCount(item *theItem, boolean *knownGood, boolean *knownBad)` (in
`Items.c`, just after `itemMagicPolarityIsKnown`) iterates the item's category kinds and counts the
unidentified ones, narrowed to the item's polarity when known (mirrors the existing
`magicPolarityRevealedItemKindCount` iteration). It's generic over potions and scrolls via
`tableForItemCategory` + `itemKindCount`.

`itemDetails` appends the sentence in the unidentified branch (right after the per-category description),
gated on `POTION | SCROLL` and `count >= 2`, coloring the number with the function's existing good/bad
escape sequences. Reuses only existing engine symbols — `itemMagicPolarityIsKnown`, `itemKindCount`,
`tableForItemCategory`.

## Impact on gameplay

- **Less mental/paper bookkeeping**, especially mid-to-late game when you've identified several kinds.
- **No power creep**: it never tells you anything you couldn't already deduce, and never resolves an
  item for you.
- Scoped to **potions and scrolls** — the two flavor-identified, intrinsically-polarized consumable
  classes — where the deduction tracking is most tedious.

## Determinism & compatibility

Pure display, recomputed each time the inspect panel is drawn. No RNG, no serialized state. Seeds and
recordings are byte-identical. Change is confined to `src/brogue/Items.c`.

## Testing

- Early game (nothing identified, no detect-magic): inspect an unidentified potion → "one of N remaining
  potions" (N = unidentified potion kinds); likewise a scroll. Never "one of 1"; never names candidates.
- After learning a potion's polarity (detect-magic, etc.): the line filters to that polarity and colors
  the number — "one of M beneficial/malevolent potions."
- Identify several kinds (drink/throw/read/identify-scroll): the count shrinks; when only the last kind
  of a polarity remains it auto-identifies and the line disappears (the item is now identified).
- Inspect an identified potion/scroll → normal description, no candidate line.
- Record → replay a session that inspects items → no desync (pure display).
