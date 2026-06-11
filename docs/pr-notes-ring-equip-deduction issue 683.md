# PR notes — upstream BrogueCE (`ring-equip-deduction`)

> Draft body for the upstream PR. **Not yet opened** — paste/adapt into the GitHub PR when ready.
> Branch `ring-equip-deduction` is pushed to your fork (commit `f9fe05d`, off `master`).
> Open against upstream with:
> `https://github.com/tmewett/BrogueCE/compare/master...sethhoward:BrogueCE:ring-equip-deduction?expand=1`
> Authored by you with no AI-attribution trailer.

---

## Auto-identify a worn ring that's deducible by elimination

Closes #683.

Only three ring kinds reveal themselves the instant they're worn — **clairvoyance, light, and stealth**
(their effect is immediately obvious). The other five — **regeneration, transference, awareness, wisdom,
reaping** — stay hidden on equip. So once a player has identified four of those five "hidden" kinds, the
fifth is fully determined: equip an unidentified ring, and if it *doesn't* reveal itself, it can only be the
one remaining hidden kind.

This PR makes the game perform that deduction: when a ring is equipped and produces no self-identifying
effect, and exactly one still-unidentified ring kind stays hidden on equip, the worn ring is identified as
that kind.

## Motivation

It's exactly the request in #683 (a flagged *good first issue*): the deduction is one an attentive player
already makes by hand, so the game does the bookkeeping rather than making the player track it. It never
reveals anything the player couldn't already conclude.

## Implementation

All in `src/brogue/Items.c`:

- `static boolean ringIdentifiesOnEquip(short ringKind)` factors out the self-identifying set
  (`RING_CLAIRVOYANCE`, `RING_LIGHT`, `RING_STEALTH`) so it isn't duplicated.
- `static int unidentifiedRingKindsHiddenOnEquip(void)` counts ring kinds that are unidentified **and** not
  self-identifying.
- The ring branch of `equipItem` now uses the helper for the existing self-ID path, and adds an `else if`:
  when the worn ring didn't self-identify and `unidentifiedRingKindsHiddenOnEquip() == 1`, call
  `identifyItemKind` on it.

Reuses the existing `identifyItemKind` (so it also slots into the per-kind / last-polarity auto-ID cascade
already triggered there) and `ringTable`. The "Now wearing a ring of …" line already prints after equip, so
the deduced kind is surfaced with no new messaging — consistent with how clairvoyance/light/stealth already
read on equip.

## Edge cases

- A ring that *does* self-identify (clairvoyance/light/stealth) takes the self-ID path as before.
- If two or more hidden kinds remain unidentified, nothing is deduced (the count guard).
- A cursed (negative-enchant) ring deduced this way is identified as before via `identifyItemKind`.
- An unidentified self-identifying kind that hasn't been found yet does not block the deduction — a worn
  ring that stayed hidden can't be one of those, so they're correctly excluded from the count.

## Determinism & compatibility

Pure identification bookkeeping — no RNG, no serialized state. Identification state isn't part of the
recording stream, so seeds and recordings are unaffected.

## Testing

- Built with `make GRAPHICS=NO TERMINAL=YES` (strict flags); no new warnings.
- Identify four of {regeneration, transference, awareness, wisdom, reaping}; equip the fifth (unknown) →
  it's identified on equip.
- With two or more of those still unknown, equip one → not identified (still ambiguous).
- Equip an unknown clairvoyance/light/stealth ring → self-identifies as before.
