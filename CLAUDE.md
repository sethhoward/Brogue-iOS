# Brogue iPad/iPhone — project notes for Claude

## When investigating a bug

**Before treating unexpected behavior as a bug, check [KNOWN_CAVEATS.md](KNOWN_CAVEATS.md).**
It lists deliberate tradeoffs and known side effects (especially around the iPhone
touch / pinch-zoom / bottom-button / orientation work) so a documented decision isn't
chased as a regression. If a real fix lands for one, remove it from that file; if a new
tradeoff is accepted, add it there.

## Architecture orientation

- **Two engines.** Classic 1.7.5 lives in `iBrogue_iPad/BrogueCode/` (compiled into the
  app target); BrogueCE 1.15 lives in `BrogueCE/Engine/` (embedded framework, driven
  through `CEBridge.mm` / the `BrogueCEHost` protocol). They share the SpriteKit
  `RogueScene`. A change to engine behavior usually needs to be made — or at least
  checked — in **both**.
- **iOS modifications to the vendored engines are documented** in
  `iBrogue_iPad/BrogueCode/IOS_MODIFICATIONS.md` and `BrogueCE/Engine/IOS_MODIFICATIONS.md`,
  each in-code marked with `// iOS port (iBrogue):`. Keep those change logs current.
- **Platform layer** (rendering, touch, gestures, UI) is in `iBrogue_iPad/PlatformCode/`
  — chiefly `BrogueViewController.swift`, `RogueScene.swift`, `SKViewPort.swift`,
  `RogueDriver.mm` (Classic bridge), `CEHost.swift` (CE host).

## Game data reference

These audits document the **BrogueCE 1.15** engine (`BrogueCE/Engine/`) and cite source
`file:line` throughout. Consult them before reasoning about item or monster behavior; if
engine code changes, regenerate or update them.

- **[docs/game-data/ITEMS_AUDIT.md](docs/game-data/ITEMS_AUDIT.md)** — every item in all 13 categories
  (weapons, armor, staffs, wands, rings, charms, potions, scrolls, food, keys, gold,
  amulet, lumenstones) with exact stats, frequencies, the metered-generation system, and
  a dedicated "how enchantments are applied" section (net enchant, strength modifier,
  scroll of enchanting, cursing, weapon/armor runics, auto-ID thresholds).
- **[docs/game-data/MONSTERS_AUDIT.md](docs/game-data/MONSTERS_AUDIT.md)** — all 68 monsters with full stats,
  abilities, and flavor/death text; complete `MONST_*` behavior- and `MA_*` ability-flag
  references; the mutation and monster-class catalogs; the horde catalog (spawn groupings,
  depths, frequencies); and out-of-depth / captive / scaling mechanics.

## Engine guides

- **[docs/guides/adding-an-item.md](docs/guides/adding-an-item.md)** — reusable recipe for
  adding a new item (scroll/potion/charm/wand/…) to the BrogueCE engine: the kind enum, item
  and effect tables (and their per-variant copies), effect dispatch, generation frequency, the
  debug "start with one" grant, the deferred-action pattern, and the determinism rules.

## Build

- Build via the **Xcode MCP server**, not `xcodebuild` CLI.
