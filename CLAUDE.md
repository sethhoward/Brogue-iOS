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

## Build

- Build via the **Xcode MCP server**, not `xcodebuild` CLI.
