# Contributing to Brogue SE

Thanks for your interest in contributing. A few ground rules keep the project's licensing
clean and its engines maintainable.

## Where contributions go

All original gameplay and content work targets the **Brogue SE** engine
(`BrogueSE/Engine/`). The Classic (`iBrogue_iPad/BrogueCode/`) and BrogueCE
(`BrogueCE/Engine/`) engines stay faithful to upstream — only iOS-platform or
upstream-bugfix changes belong there, and those are kept cherry-pickable. See the
engines' `IOS_MODIFICATIONS.md` files for the conventions.

## Licensing of contributions

This project is licensed under the **GNU Affero General Public License v3 or later**
(see [`LICENSE`](../LICENSE)). Your contributions are accepted under that license, and:

- By submitting a contribution you agree to the **Contributor License Agreement** in
  [`CLA.md`](CLA.md).
- The CLA lets the project apply documented additional permissions (e.g. the app-store
  exception in [`LICENSE-EXCEPTIONS.md`](LICENSE-EXCEPTIONS.md)) to your contribution
  without contacting you again, and confirms your contribution is your own original work.
- Do **not** paste in code from other projects unless it is AGPL-compatible and you
  identify its origin and license in the pull request.

## Engineering conventions

- New content is built from the **reusable components**, not bespoke per-entity code —
  start at [`docs/guides/reusable-components.md`](../docs/guides/reusable-components.md).
- **Determinism is mandatory.** Drive game-state logic from the substantive RNG
  (`rand_range`, `rand_percent`), never `RNG_COSMETIC` or wall-clock — saves are input
  replays and the seeded-run leaderboard depends on it.
- Log every vendored-engine C change in the relevant `IOS_MODIFICATIONS.md` with inline
  `// iOS port` markers.
- Build through Xcode, not the `xcodebuild` CLI.
