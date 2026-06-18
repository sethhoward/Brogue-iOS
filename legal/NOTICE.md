# NOTICE — Copyright & Attribution

This repository is an iOS port that bundles three Brogue engines. The whole work is
licensed under the **GNU Affero General Public License, version 3 or (at your option)
any later version** — see [`LICENSE`](../LICENSE). Documented additional permissions (and
their current status) are in [`LICENSE-EXCEPTIONS.md`](LICENSE-EXCEPTIONS.md).

## Copyright holders

| Component | Path | Copyright |
|---|---|---|
| **Brogue (Classic, 1.7.5)** | `iBrogue_iPad/BrogueCode/` | © Brian Walker. Original Brogue. Basis of all three engines. |
| **Brogue CE (1.15)** | `BrogueCE/Engine/` | © Brian Walker + the [Brogue CE](https://github.com/tmewett/BrogueCE) contributors (community-edition modifications). |
| **Brogue SE** | `BrogueSE/Engine/`, `BrogueSE/` | © Brian Walker + Brogue CE contributors (forked base) + © 2026 Seth Howard (SE-original content). |
| **iOS platform layer** | `iBrogue_iPad/PlatformCode/` and app target | © Seth Howard / contributors. |

"SE-original content" means the files and portions identified in
[`BROGUE_SE.md`](../BROGUE_SE.md) and marked `// iOS port (Brogue SE):` — the identification
rework, gold goblin, altars of insight, staff of frost, empty bottle, reusable
flee/loot/steal components, and the other original gameplay listed there.

## License-version note

Nearly all engine source files declare **AGPLv3-or-later**. One file,
`PlatformDefines.h` (present in both `BrogueCE/Engine/` and `BrogueSE/Engine/`),
declares plain **GPLv3-or-later** rather than the Affero variant. This reflects its
upstream Brogue origin and is preserved as-is.

## Trademarks

"Brogue" and related marks belong to their respective owner(s); no trademark rights are
granted by the AGPL or by this notice.
