# iBrogue — TODO

Outstanding work for the dual-engine effort (Classic Brogue 1.7.5 + BrogueCE 1.15,
branch `feature/broguece-support`). See `BrogueCE/` and
`.claude/.../memory/reference_dual_engine_architecture.md` for how the two engines
coexist.

## ACTIVE — BrogueCE Tile Graphics (CE only)

Add tile graphics to **BrogueCE only**. Classic stays text-only. This is safe to do
in the *shared* `RogueScene` because tile codes live in a sentinel range (`0x4000+`)
that **only CE's bridge emits** — Classic always sends normal Unicode, so it can never
trigger the tile path. No per-engine branching in the renderer.

**Key insight:** tiles are NOT a sprite atlas. The BrogueCE-ipad fork renders tiles as
glyphs from a custom **`BrogueCE.ttf`** font, where tile artwork lives at codepoints
`0x4000+`. We reuse the existing font-glyph pipeline.

**Encoding (mirror the fork):** in tile mode, `plotChar` emits
`glyphCode = (inputChar - 130) + 0x4000` for tile glyphs (i.e. `inputChar > G_DOWN_ARROW`
and mode is TILES, or HYBRID and `isEnvironmentGlyph(inputChar)`); otherwise
`glyphToUnicode(inputChar)`. The renderer draws `0x4000+` codes in the `BrogueCE` font.

**Reference implementation (do not ship its iOS shell — port from it):**
- `~/Work/BrogueCE-ipad/ios/iBrogueCE_iPad/PlatformCode/RogueDriver.mm` → `_plotChar`
  (the tile encoding) and `_setGraphicsMode`.
- `~/Work/BrogueCE-ipad/ios/iBrogueCE_iPad/PlatformCode/RogueScene.swift` →
  `createTextureFromGlyph` / `GlyphType` (tile cases: monster ranges `\u{4017}`–`\u{405a}`
  etc., `.wall`, per-category `scaleFactor`, `fontName = "Brogue"`).
- `~/Work/BrogueCE-ipad/ios/iBrogueCE_iPad/BrogueCE.ttf` (the tile font; family name "Brogue").

**Work items:**
1. Bundle `BrogueCE.ttf` in the app and register it in `Info.plist` `UIAppFonts`.
2. `BrogueCE/CEBridge.mm` `plotChar`: emit the `0x4000+` tile code in tile mode (needs the
   `0x4000+`/`isEnvironmentGlyph` logic; `isEnvironmentGlyph` lives in CE's
   `platformdependent.c` — vendor that one function alongside `glyphToUnicode`).
3. `BrogueCE/CEBridge.mm` `setGraphicsMode`: stop stubbing — track TEXT/TILES/HYBRID
   (`graphicsMode` global) and use it in `plotChar`.
4. `iBrogue_iPad/PlatformCode/RogueScene.swift` `GlyphType`: add `0x4000+` cases →
   `fontName "Brogue"` + ported scale factors. Tune centering/metrics in our cell size.
   (Classic unaffected — it never sends `0x4000+`.)
5. Mode toggle: confirm how CE triggers a graphics-mode change on iOS (engine keystroke
   vs. a needed native affordance) and wire it; optionally persist the choice.
6. Test: tiles render, text mode still works, switching modes, Classic untouched; iPad + iPhone.

**Risks:** tile-font glyph centering/metrics in our cell size (retune the fork's scale
factors); confirming the mode-toggle UX on iOS. Est. ~1–2 days.

## Deferred — High Scores & Achievements (CE)

**Punted for now.** BrogueCE's score/stats and achievement plumbing is stubbed in
the bridge, so these CE screens are non-functional:

- `getHighScoresList`, `saveHighScore` — stubbed in `BrogueCE/CEBridge.mm`
  (return 0 / false). CE's **High Scores** screen (View flyout) shows nothing and
  CE runs are never recorded to a score table.
- `saveRunHistory`, `loadRunHistory`, `saveResetRun` — stubbed. CE's **Game Stats**
  screen (View flyout) shows nothing.
- `listFiles` — stubbed (CE's own load/recording pickers use the engine's
  `dialogChooseFile`, so this may not be needed; confirm before implementing).

When picked up:
- Implement CE high scores with **per-version storage** so CE scores don't mix with
  Classic's (Classic uses Game Center + its own `NSUserDefaults` key; CE should use a
  separate key, e.g. under `Documents/ce/` or a `ce`-suffixed defaults key).
- Implement run-history persistence for Game Stats (per-version).
- **Achievements:** Game Center is currently **Classic-only** (decided). Decide
  whether CE gets its own Game Center leaderboard/achievements or none. If yes,
  re-inject the 3 achievement hooks into CE's drifted source and stand up a separate
  CE leaderboard; if no, leave CE's score table local-only.

## Other outstanding

- **Classic saves → `Documents/classic/` migration.** Classic currently uses the flat
  `Documents/` folder; CE uses `Documents/ce/`. They're already *separated*, so this is
  organizational tidiness + a one-time migration of existing flat saves into `classic/`.
- **Dead code cleanup.** Classic's old floating file button is unused now that File
  Management is a title-menu item: `setupManageFilesButton` / `manageFilesButtonPressed`
  in `BrogueViewController.swift` (and the `manageFilesButton` outlet).
- **Polish / verify:**
  - Cold-launch flame and grid geometry on a fresh launch (early portrait/first-frame
    observations — likely fine now, unconfirmed).
  - Seed-button position holds on iPhone (the multiplier constraints are untested there).
- **Full test pass:** both engines end-to-end — gameplay, save/load, switching, saves
  isolation — on **iPad and iPhone**.

## Deferred by decision (not bugs)

- **CE variants** (Rapid / Bullet Brogue) — the architecture supports them (runtime
  `gameVariant` switch); the Play-flyout "Change Variant" entry was removed for now.
- **CE Game Center** — see Achievements above.
