# iOS modifications to the Brogue SE engine

> **Brogue SE** (`BrogueSE/Engine/`, embedded `BrogueSE.framework`, driven by `SEBridge.mm`)
> is a **fork of BrogueCE 1.15** and the home of all original "firehose" gameplay. It started as
> a verbatim copy of `BrogueCE/Engine/`, so the entries below were inherited from the CE port and
> still mention `BrogueCE` / `CEBridge.mm` / `ce_*`; in this tree the equivalents are
> `BrogueSE` / `SEBridge.mm` / (for SE-specific entry points) `se_*`. Unlike CE, SE **never merges
> back to upstream**, so this log's role is internal divergence-tracking, not upstream
> cherry-picking. SE-specific bridge changes are marked `// iOS port (Brogue SE):`.

The code here records iOS-specific modifications layered on the engine C, so the divergence stays
legible and future maintainers (human or AI) don't mistake an intentional port change for a bug.
See `BrogueCE/Engine/IOS_MODIFICATIONS.md` (faithful CE) and
`iBrogue_iPad/BrogueCode/IOS_MODIFICATIONS.md` (Classic) for the other two engines.

## Conventions

- **Engine → host hooks are plain C functions** declared `extern` at the top of the
  engine file that calls them and **defined in `CEBridge.mm`** (inside its
  `extern "C"` block). They route to the app via the `BrogueCEHost` protocol. Each
  is a no-op when there's no host or no device support, so the engine may call them
  unconditionally. Naming: `ce*` (e.g. `cePlayerTookDamage`, `ceSetTargeting`).
- **`uiMode` is a write-only host signal.** The engine only ever *assigns*
  `uiMode` (the `CBrogueGameEvent` tablet UI mode); nothing in the engine reads or
  branches on it. It is reported to the host by `CEBridge.mm`, which uses it to
  show/hide on-screen controls. Changing which value a screen sets is therefore a
  pure UI change and cannot affect game logic.
- **Keep changes minimal and commented.** Every edit below is marked in-code with an
  `// iOS port (iBrogue):` comment so it's greppable.

---

## Change log

### 2026-07-07 — Item-detail box: reserve room for action buttons so long descriptions keep "call"

**What.** `printTextBox`'s auto-widen only widened until the **text** fit above the flavor/button
chrome (`ROWS-2`), ignoring the action buttons drawn *below* the text (`apply`/`drop`/`throw`/`call`/
`relabel`), which wrap to a second double-spaced line. A long description (staff of firebolt / frost,
etc.) left the text just fitting but pushed the wrapped button line — "call"/"relabel" — onto the
chrome rows, where it was lost. Now reserves 4 rows (up to two wrapped button lines) in the widen
loop when `buttonCount > 0`, so the box widens until text **and** buttons fit. Zoom-independent (a
plain layout fix). Presentational; no RNG / save / recording impact.

### 2026-07-07 — iPhone menu magnify fix: clear on text-input prompts (Save recording / seed entry)

**What.** `IO.c getInputTextString` now calls `ceClearMenuBox()` at its start. A text-input prompt
(e.g. "Save recording as…", seed entry) is NOT a button menu, so it reports no rect — and the
save/quit flow reaches it straight from a menu without returning to play, leaving the menu magnify
engaged on a stale rect, which tore the prompt. Presentational; no RNG / save / recording impact.
The same `ceClearMenuBox()` is applied at the start of the full-screen **Feats** and
**Discovered-items** views (`displayFeatsScreen` / `printDiscoveriesScreen`) — also non-menu
overlays (they `waitForKeystrokeOrMouseClick`, report no rect) that should render at 1×. They also
set `uiMode = InMenu` for the view's duration (restored on exit) so the host keeps
`gameplayControlsActive` false and thus suspends the **dungeon pinch-zoom** too — otherwise the view
is drawn into the zoomed dungeon cells and appears magnified.

### 2026-07-07 — iPhone menu magnify (phase 1): in-game inventory / action menu / dialogs

**What.** Extends the menu magnify (phase 0) to in-game overlays. Rather than hooking each surface,
the rect is reported from the single choke point every button menu passes through — `buttonInputLoop`
— so inventory, the action menu, and all `printTextBox`-with-buttons dialogs (item detail, confirms,
the game-mode dialog) magnify with one call. Presentational; no RNG / save / recording impact.

- **`Buttons.c` `buttonInputLoop`:** right after it sets `uiMode = InMenu`, calls
  `ceSetMenuBox(...)` with the loop's own window rect, expanded by a 1-cell **horizontal-only** "trim"
  so a printTextBox dialog's side `rectangularShading` shadow scales with the panel instead of being
  left behind at 1× (the dark seam beside the box). Vertical trim is deliberately omitted — the tall
  inventory list has no shadow, so top/bottom trim would only add unneeded rows and shrink its
  fit-magnify. No clear here:
  nested menus (inventory → item detail → inventory) just overwrite the rect, and teardown is
  host-driven when play resumes (see below). This keeps nested navigation flicker-free.
- **`IO.c` `printTextBox`:** removed the direct `ceSetMenuBox` added in phase 0 — it's redundant now
  that `printTextBox`'s own `buttonInputLoop` reports the (more accurate, buttons-included) rect.
- **Host (`BrogueViewController`):** the magnify gate is now just "a menu rect is reported" (dropped
  the title-only guard). Teardown is anchored to `gameplayControlsActive → true` (uiMode →
  InNormalPlay), which — because `reportUIModeIfChanged` only pushes on a settled change per
  event-loop iteration — fires once on true return to play, not on the transient InNormalPlay between
  nested menus. The teardown runs before the gameplay zoom is restored, so borrowed cells are back in
  the dungeon container before it re-scales.
- **Determinism:** read-only reporting; no RNG, no save/recording fields.

### 2026-07-07 — iPhone menu magnify (phase 0): report the title menu's rect to the host

**What.** iPhone renders the whole 100×34 grid stretched onto a narrow screen, so title-menu items are
too small to read/tap. Rather than pan/zoom the camera, the host now auto-magnifies just the menu region
to a readable, tappable size — as a panel over the otherwise-untouched 1× title (only the menu cells scale),
instant, no camera movement. The engine's only job is to tell the host *where* the current menu is
(window-cell rect); all magnification lives in the platform layer.
Presentational hint only — nothing here touches RNG, game state, or the recording, so it's determinism-
and save-safe.

- **`MainMenu.c`:** new `reportTitleMenuBox()` computes the bounding rect of the main-menu buttons (plus
  the flyout buttons when a flyout is open, and a 1-cell shadow-halo "trim") and calls `ceSetMenuBox(x,y,w,h)`.
  Called each title redraw in `titleMenu()`'s inner loop (host dedupes identical rects). On `titleMenu()`
  exit it calls `ceClearMenuBox()` — leaving the title into a game or a sub-screen that reports no rect of
  its own (file browser, high scores, recordings, seed entry) would otherwise leave the stale magnify
  engaged, and its borrowed cells corrupt that screen's rendering.
- **`IO.c` `printTextBox`:** when the box has buttons (a modal menu — e.g. the game-mode dialog), call
  `ceSetMenuBox(x2, y2, width, lineCount + padLines)` before blocking on input. Button-less boxes (examine /
  details) are left to the examine path. In-game buttoned boxes also report, but the host only magnifies
  while at the title, so they're ignored for now (phase 1 extends the gate to inventory).
- **Bridge:** `SEBridge.mm` defines `ceSetMenuBox` → `[gHost setMenuBox:y:width:height:]` and `ceClearMenuBox`
  → `[gHost clearMenuBox]`; both host methods were added to the shared `BrogueCEHost` protocol
  (`BrogueCEHost.h`). CE/Classic hosts that don't magnify menus can ignore them.
- **Determinism:** read-only reporting; no RNG, no save/recording fields.

### 2026-07-07 — Game handoff: engine recording-version accessor (cross-platform version guard)

**What.** The handoff compatibility guard now compares the engine's recording/save-version string
(BROGUE_VERSION_STRING) instead of the app version+build — the build number changes every build, so the
old proxy wrongly blocked cross-device / cross-platform handoff (iPhone→Mac). Bridge/host only. See
`docs/design/game-handoff.md`.

- **`SEBridge.mm`:** `se_recordingVersion()` returns `brogueVersion` (BROGUE_VERSION_STRING); declared in
  `BrogueSEHost.h`. The host stamps it into the Handoff `userInfo` and compares it on receipt.
- **Determinism:** read-only; no RNG, no save fields.

### 2026-07-06 — Game handoff (Phase 4): silent relinquish key (end a handed-off run, no bookkeeping)

**What.** When a run is handed off to another device, the source ends it *silently* so the run lives in
one place and leaves no trace on the source. Added `HANDOFF_RELINQUISH_KEY` (a synthetic, button-only key
the host injects on the deep ACK), handled in `executeKeystroke` beside NEW_GAME_KEY/QUIT_KEY. See
`docs/design/game-handoff.md`.

- **`Rogue.h`:** `#define HANDOFF_RELINQUISH_KEY (128+22)` (beside CONTINUE_TRAVEL_KEY; value shared with CE).
- **`IO.c` `executeKeystroke`:** the new case ends the run with NO `gameOver` bookkeeping (no death/quit
  run-history, high score, or saved recording — unlike QUIT_KEY): `remove(currentFilePath)` then blank it
  (so no later flush recreates the resumable save), `rogue.nextGame = NG_NOTHING`, `rogue.gameHasEnded =
  true` — the same clean exit NEW_GAME_KEY uses. Declares `extern char currentFilePath[]`.
- **Host side:** starves input during the transfer (freeze), injects this key on the ACK, then clears the
  resume marker. No RNG or save-format impact; the relinquish key is never recorded.

### 2026-07-06 — Game handoff (Phase 3b): flush the live recording on demand for the transfer

**What.** The handoff source streams the *exact-state* recording to the receiving device. Added a
bridge hook that flushes the live recording to `currentFilePath` and returns its bytes, reusing the
same `flushBufferToFile()` + engine-thread poll pattern as background-suspend (no vendored engine `.c`
change — bridge/host only). See `docs/design/game-handoff.md`.

- **`SEBridge.mm`:** `se_flushRecordingForHandoff()` (host hook, called off-main) sets
  `gSEHandoffFlushRequested` and waits on a semaphore; `seTakeBackgroundSnapshotIfRequested` (engine
  thread, same poll point as the background snapshot) services it with `flushBufferToFile()` and signals,
  then the hook reads `currentFilePath` and returns the bytes (`NSData`).
- **`BrogueSEHost.h`:** declares `se_flushRecordingForHandoff`.
- **Determinism:** read-only with respect to game state (flush + file read); no RNG, no save fields.

### 2026-07-06 — Game handoff (Phase 1b): report live game context (depth/turn/seed) to the host

**What.** `commitDraws` now reports the live game's context to the host so the cross-device Continuity
**Handoff** activity's banner/metadata (depth/turn/seed) stays current. Part of the game-handoff feature
(CE + SE only; Classic is excluded — its recordings are desync-prone). Platform wiring lives in the
bridge + Swift; only the `IO.c` hook is engine C. See `docs/design/game-handoff.md`.

- **`IO.c` `commitDraws`:** after the existing `ceSetTravelPending` call, gated on `!rogue.playbackMode`
  (skip loading/replay), call `ceSetGameContext(rogue.depthLevel, rogue.playerTurnNumber, rogue.seed)`.
  Extern declared alongside `ceSetTravelPending` near the top of `IO.c`.
- **Bridge (`SEBridge.mm`):** `ceSetGameContext` dedupes on depth (forwarded only when the player
  changes level; per-turn churn is unnecessary since the recording bytes stream live at pickup) and calls
  the new `BrogueCEHost setGameDepth:turn:seed:`. The depth dedup (`gLastHandoffDepth`) resets when the
  title reappears (`reportAtTitleIfChanged`) so a new game re-forwards its first depth.
- **Determinism:** pure outbound signaling — reads engine state, writes nothing to it. No RNG, no save
  fields, replay-safe.

### 2026-07-05 — Continue-travel command + reactive center d-pad button

**What.** A touch-friendly "continue my interrupted journey" command. Tapping a far tile auto-travels
there, but any interruption (spotting a monster, etc.) stops you and — on a touch screen — forces you to
re-select the destination, often re-triggering on the next thing you spot. The engine already remembers
the destination: `rogue.cursorLoc` survives an interruption (only *arrival*, no-path, and stairs clear
it) and the route stays drawn from it. The new command just re-runs `travel(rogue.cursorLoc, true)`.

- **Key.** `#define CONTINUE_TRAVEL_KEY (128+21)` in `Rogue.h` — a synthetic, button-only code (no
  physical-key binding) sitting above `REAPPLY_KEY`/`UNKNOWN_KEY`. Fits a `UInt8` and round-trips cleanly
  through the keystroke-recording compressor (offset 21 is past `keystrokeCount`, so `compressKeystroke`/
  `uncompressKeystroke` pass it through unchanged, no `keystrokeTable` collision). The **same value is
  used in CE and Classic** so the one on-screen button dispatches in every engine.
- **Dispatch.** `mainInputLoop`'s cursor-confirm (`doEvent`) branch intercepts `CONTINUE_TRAVEL_KEY` and
  calls `travelRoute(path, steps)` — the exact route already computed and drawn for the cursor *this
  iteration*, the same fast (~25ms/step) primitive a confirming tap uses, **not** `travel()`→`travelMap`
  (the slow 500ms/step greedy path reserved for stairs — using it made continue ~20× slower and take a
  different route than the displayed one). `travelRoute` also marks visible monsters `MB_ALREADY_SEEN`,
  so it walks past them cleanly. **No explicit `recordKeystroke`** — `travelRoute` drives `playerMoves`,
  which records each step's direction key, so the journey is captured as its moves (like a tap-travel).
  Determinism-safe.
- **Reactive-button state.** `commitDraws` reports whether a journey is pending via a new
  `ceSetTravelPending(isPosInMap(rogue.cursorLoc))` extern (defined in `SEBridge.mm`, deduped, routed
  through the `BrogueCEHost` `setTravelPending:` protocol method). The host swaps the center d-pad button
  between a footprints "continue" glyph and the `zzz` "rest" glyph, sending the continue key vs `z`.
- **Scope.** Walks past *already-seen* monsters and re-stops only on a *new* disturbance (the
  `MB_WAS_VISIBLE` gate in `Time.c`) — i.e. exactly what re-clicking the tile already does; no new power,
  no RNG/save impact. No-op when nothing is pending. Kept identical across Classic / CE / SE.

### 2026-07-05 — Examine description box: report its rect (fit-zoom) + suppress it for zoomed play-field examines

**What.** Two iPhone examine-box hooks (identical hooks added to CE and Classic — see their
IOS_MODIFICATIONS). (1) *Fit-zoom:* the "zoom out on examine" nicety used to drop the magnified map all the
way to 1× whenever a description box appeared, shrinking the box text (it's drawn in the magnified dungeon
cells); the engine now reports the box's window-cell rect so the host can zoom only as far as needed to
*fit* it. (2) *Suppress:* a description box triggered by a **play-field drag-hold while zoomed** tore
against the 1× sidebar/chrome (only the dungeon columns magnify); the engine now asks the host and skips
drawing the box in that case (the sidebar still highlights the entity, and the one-line flavor still shows).

- **`IO.c` `printTextBox`:** after shading the box, stash its rect (`x2, y2, width, lineCount + padLines`)
  in file-static `gLastTextBox{X,Y,Width,Height}`.
- **`IO.c` cursor/examine loop (`mainInputLoop`):**
  - Gate `printMonsterDetails`/`printFloorItemDetails` on `!ceShouldSuppressExamineBox()` (the sidebar
    `refreshSideBar` highlight still runs before the gate).
  - Just before `ceSetExamining(textDisplayed)`, when `textDisplayed`, call `ceSetExamineBox(x,y,w,h)` with
    the stashed rect. Safe because only `printLocationDescription` → `flavorMessage` (a one-line
    `printString`, not a `printTextBox`) runs between the box and here, so it can't clobber the rect.
- **Bridge:** `SEBridge.mm` defines `ceSetExamineBox` → `[gHost setExamineBox:y:width:height:]` and
  `ceShouldSuppressExamineBox` → `[gHost shouldSuppressExamineBox]`; both host methods were added to the
  shared `BrogueCEHost` protocol and implemented in `CEHost.swift`.
- **Scope:** applied to all three engines (this file, CE, Classic). Pure presentation; no gameplay/RNG/save
  impact. iPhone-only in effect (the host consumers are phone-gated); the host suppresses only for a zoomed
  play-field examine (`gestureOriginZone == .playArea`), never a sidebar tap.

### 2026-07-02 — Cursed-runics: Smoky armor progressive per-enchant sight (post-0.12.0)

**Why.** The cursed Smoky armor's 1-tile blindness was too punishing to *live* with — fine as an opening
handicap, but it made exploration (finding scrolls of enchanting, etc.) miserable in a dungeon you can't
see. The rework makes the blindness **ease with every enchant** on the way to the +4 purify, so investment
is felt continuously rather than only at the finish.

**What.** `emitSmokyArmorCloud()` (`Time.c`) no longer wreathes all 8 neighbors in thick, sight-blocking
smoke. It now **dithers**: `clearCount` of the 8 neighbors are thinned to sub-threshold smoke
(`SMOKY_DITHER_THIN_VOLUME` = 10 < `SMOKE_THICK_VOLUME`), which dims but does not block — and clearing a
neighbor opens the whole sightline past it. The easing is **symmetric** (an open lane lets foes see *in* as
well), so cursed-Smoky stays a worse deal than the purified +3 stealth aura and never becomes free invisibility.

- **Curve** (`clearByTier`, indexed by `enchant1 + 1`): `-1 → 0` (byte-identical to the old full blindness),
  `0 → 2`, `+1 → 4`, `+2 → 5`, `+3 → 6` (capped below 8 so +3 still bites). `+4` purifies (cloud gone + the
  stealth aura, unchanged).
- **Which cells clear:** `smokyCellHash(x,y)` — a pure, world-anchored spatial hash (no RNG) — ranks the 8
  neighbors; the `clearCount` lowest are thinned. The lowest-N set ⊂ lowest-(N+1), so enchanting only *adds*
  lanes (monotonic, no reshuffle), and the open lanes drift organically as you move.
- **Determinism:** pure functions of `enchant1` and cell `(x,y)`, recomputed each turn — no new save fields,
  no substantive/cosmetic RNG, replay-safe. Re-stamped at both existing call sites (top-of-turn for monster
  concealment; pre-vision for the player's FOV) so `updateEnvironment` gas-averaging can't wash out the pattern.
- **Tuning constant** (`Rogue.h`): `SMOKY_DITHER_THIN_VOLUME`. Info-panel copy for cursed A_SMOKY (`Items.c`)
  updated to describe the haze thinning per enchant.

### 2026-07-02 — Brogue SE 0.12.0 "C is for Curses": release cut (version + release notes)

**What.** Cut the 0.12.0 release. Headline features since 0.11.0: the **cursed-runics rework** (double-edged
runics — an always-on upside welded to a downside you either *purify* away with enchant scrolls or *eject*
early with remove-curse; six curses: Delirium / Recklessness / Clumsiness→Quietus on weapons, Anchor / Smoky /
Acrophobia on armor) and the **Altars of Divination** reward room, plus the thrown-decoy dwell.

- **Title string:** `BROGUE_VERSION_STRING` → `"C is for Curses 0.12.0 "` (GlobalsBrogue.c).
- **Release notes** (`seInfoBlocks`, BrogueViewController.swift): new intro + three sections — Cursed Runics,
  Altars of Divination, Cleaner Distractions. Demoted 0.11.0 "B is for Balance" to the lone Previous Release
  block (kept its Balance Pass / Smoke & Terrain / Tells & Legibility sections); dropped 0.10.0 "A Is For AAaAH!".
- **Saves/replay:** recording version is already `"SE 2.2.0"` (`BROGUE_MINOR` 1→2 landed with the divination
  save break), so 0.11.0 ("SE 2.1.0") saves are cleanly rejected. No further bump; `BROGUE_PATCH` stays 0. No
  `BROGUE_VERSION_ATLEAST` gates depend on the minor.
- **Marketing version:** `MARKETING_VERSION` (Xcode app targets) — confirm the App Store version before archiving.

### 2026-07-02 — Cursed-runics rework: Smoky blindness bugfix + curse-test identify scrolls

**What.** (1) Fixed Smoky's self-blind not applying (playtest: "I can see fine, so it's all upside"). The
per-turn `emitSmokyArmorCloud` ran once at the top of `playerTurnEnded`, but the do-loop then runs
`updateEnvironment` (two `updateVolumetricMedia` passes that *average* the concentrated cloud below
`SMOKE_THICK_VOLUME`) **before** the final, player-facing `updateVision(true)` — so the FOV was recomputed
against thinned smoke and never collapsed. Fix: re-assert the cloud a second time right before that final
vision pass (the top-of-loop emit still drives monster-awareness concealment). (2) `D_CURSE_TEST_SCROLLS_START`
now also grants 5 scrolls of identify, alongside the enchanting + remove-curse it already gave.

**Why.** The bug made Smoky pure upside (concealment without the blindness cost). Concealment worked because
the *intermediate* vision pass (which drives monster awareness) still saw the fresh thick smoke.

**Where.** `Time.c` (second `emitSmokyArmorCloud` before the end-of-loop `updateVision`), `RogueMain.c`
(identify scrolls in the grant).

### 2026-07-02 — Cursed-runics rework, Phase 2 (armor, part 2): Smoky (armor phase complete)

**What.** The third armor curse (design finalized via a `/grill-me` pass; all Q's landed on the default).
- **Concealment via smoke, range-only.** While cursed, `emitSmokyArmorCloud` (`Time.c`, called early in
  `playerTurnEnded` so it lands before FOV/monster-sight) refreshes a **radius-1 thick-smoke cloud**
  (player + 8 neighbors) — a direct, RNG-free gas write (`layers[GAS]=SMOKE_GAS`, `volume` bumped past
  `SMOKE_THICK_VOLUME`), never clobbering another gas, skipping `T_OBSTRUCTS_GAS`. The **existing shared
  `getFOVMask`** (used by both player and monster FOV) does the rest: monsters >1 tile away can't see you
  (sneak past / can't be targeted / **sneak-attack openers**), adjacent monsters still can, and your own
  FOV collapses to ~1 tile. Cells you leave dissipate into a short trail (escape cover). Noise system still
  hears you (the counter).
- **Purify → stealth aura (a sidegrade, by design).** Purified, the smoke is gone and you gain
  `SMOKY_STEALTH_BONUS` (3) — applied fresh at the two consumption sites (`Time.c` stealth range +
  `Monsters.c` player noise) via `smokyPurifyStealthBonus()`, so it's correct regardless of when you
  purify (avoids the `updateRingBonuses`-not-called-after-armor-enchant trap). So you trade absolute
  at-range sight-block (+ blindness) for see-normally + harder-to-spot-and-quieter. Keeping it cursed is a
  legitimate blind-assassin niche.
- Reveals on equip (`equipItem`). Description by purify state; playtest grant `D_SMOKY_ARMOR_START`.

**Why.** Completes the armor phase. The range-only model + purify sidegrade resolve the long-standing
"one-way invisibility" balance question (we never grant see-through-your-own-smoke).

**Gas interaction (intended, verified):** the Smoky cloud is low-volume (~21). Real gas clouds are far
denser (confusion trap 300, dewars 20000, caustic likewise), and the gas-mix rule (Time.c: denser gas
wins the cell, weaker capped at 3) means a real cloud *overwhelms* your smoke — you lose concealment AND
take the gas effect. So Smoky grants **no** gas protection (no respiration overlap); gas clouds are a
natural hard counter to the smoke-assassin. Your smoke only displaces feeble/residual gas (~<21).

**Where.** `Time.c` (`emitSmokyArmorCloud` + call, stealth-range site), `Monsters.c` (noise site),
`Items.c` (`smokyPurifyStealthBonus`, equip reveal, description), `Rogue.h` (constant + flag + decl),
`RogueMain.c` (grant).

### 2026-07-02 — Cursed-runics rework, Phase 2 (armor, part 1): Acrophobia + Anchor

**What.** Two of the three armor curses (effects + info-panel descriptions + playtest grants). Both are
passive/contextual (not the reactive `applyArmorRunicEffect` slot), gated on the shared `runicCurseActive`.
- **Acrophobia** (`A_ACROPHOBIA`): always-on **fall immunity** (guarded in the fall path, `Time.c`) and
  **dive-at-will** (suppresses the "Dive into the depths?" prompt for an identified wearer, `Movement.c`,
  same pattern as `A_RESPIRATION`); while cursed, standing adjacent to a chasm inflicts **vertigo**
  (per-turn `STATUS_CONFUSED` refresh in `decrementPlayerStatus`). Reveals on the first vertigo or the
  first cushioned fall. (Its purify reward is simply the fear lifting — fall-immunity is binary, so
  there's nothing to scale; and there's no player "forced into a chasm" source to guard.)
- **Anchor** (`A_ANCHOR`): always-on **+defense** (`ANCHOR_DEFENSE_BONUS`, in `recalculateEquipmentBonuses`);
  while cursed, a **move-only slow** (`ANCHOR_MOVE_SLOW_PCT` extra ticks in the non-attack turn-cost path,
  `Time.c` — attacks add ticks elsewhere, so attack speed is untouched). Reveals on the first dragging step.
  **Purify reward — immovable:** immune to knockback (`MA_ATTACKS_STAGGER`, e.g. ogres) and to being seized
  (`MA_SEIZES`, e.g. bog monsters), gated on purify via `playerHasImmovableAnchor` (`Combat.c`). (We verified
  these are the *only* things that displace the player — explosion knockback is gated off, and nothing
  beckons/shoves the player — so beckon / forced-into-chasm immunity were dropped as no-ops.)

Tuning `#defines` in `Rogue.h`. Playtest grants (default 0): `D_ACROPHOBIA_ARMOR_START`,
`D_ANCHOR_ARMOR_START` (cursed −1 runic leather).

**Why.** Phase 2 of the rework. **Smoky remains** — its concealment is an FOV/smoke-emission problem
(and the flagged "one open balance question": purify → one-way sight advantage), so it gets a focused pass.

**Where.** `Time.c` (fall immunity, vertigo, move-slow), `Movement.c` (dive prompt), `Items.c`
(defense bonus, both armor descriptions), `Rogue.h` (constants + grant flags), `RogueMain.c` (grants).

### 2026-07-02 — Cursed-runics rework, Phase 3 (weapons): item-panel descriptions

**What.** Real info-panel descriptions for the three weapon curses, replacing the Phase-0 `[name]`
placeholders. Added custom description blocks in `itemDetails` (`Items.c`, alongside the `W_SLAYING`/
`W_MULTIPLICITY` special cases) because the generic "X% of the time it hits, …" frame doesn't fit them:
- **Delirium** — described by purify state (cursed: hallucination + acid-mound warning + confusion proc
  + purify hint; purified: weakness proc, no cost).
- **Recklessness** — passive, so it bypasses the proc frame entirely (+damage dealt / +damage taken,
  purify removes the vulnerability).
- **Clumsiness** — decap proc + the fumble downside + purify→quietus hint (cursed-only; the purified
  `W_QUIETUS` uses the stock Quietus description).

Precise numbers are gated on `ITEM_IDENTIFIED` (as the generic path does), so an un-ID'd enchant isn't
leaked via the shown proc %. The `weaponRunicEffectDescriptions[]` table entries for these three are now
dead (kept as `[name]` fallbacks; the custom blocks handle all display).

**Why.** Phase 3 polish — the panels were showing bracket placeholders now that the curses surface.

**Where.** `Items.c` (`itemDetails` runic-description chain; the effect-descriptions table).

### 2026-07-02 — Cursed-runics rework, Phase 1: the three weapon-curse effects

**What.** Implemented the effects for the three weapon curses (design: `docs/design/cursed-runics-rework.md`).
Shared helper `runicCurseActive(item)` (`Items.c`, declared in `Rogue.h`) = "bad runic below its purify
threshold" — the single gate for all cursed-phase behavior. **All three effects scale with enchant** (so
purifying-and-enchanting is a real upgrade, matching how good runics scale). Tuning constants in `Rogue.h`:
`DELIRIUM_PROC_FLOOR` (8) + `DELIRIUM_PROC_PER_ENCHANT` (3); `CLUMSINESS_DECAP_PCT` (4, flat cursed decap
AND the purified-Quietus floor); `CLUMSINESS_FUMBLE_PCT`/`_STR_RELIEF`/`_STUN_TURNS`;
`RECKLESSNESS_DAMAGE_DEALT_BASE` (20) + `_PER_ENCHANT` (1); `RECKLESSNESS_DAMAGE_TAKEN_PCT` (50, flat).
- **Delirium** (`W_DELIRIUM`): dual-mode on-hit proc in `magicWeaponHit` keyed on `runicCurseActive` —
  **confusion** while cursed (the "venom", reuses `weaponConfusionDuration`), **weakness** once purified
  (`weaken()`). Downside: while cursed, a per-turn refresh in `decrementPlayerStatus` keeps
  `STATUS_HALLUCINATING` topped up (permanent hallucination while wielded). Reveals on equip
  (`autoIdentify` + hallucination start in `equipItem`). The "real curse" (blind acid-mound corrosion)
  falls out for free from the existing `degradesAttackerWeapon` path; protect-weapon counters it.
- **Recklessness** (`W_RECKLESSNESS`): passive, no on-hit proc (`runicWeaponChance` returns 0 for it).
  +`RECKLESSNESS_DAMAGE_DEALT_PCT`% damage dealt (always, even purified) in `attack()`; +`…_TAKEN_PCT`%
  damage taken while cursed in `inflictDamage` (all sources). Reveals on first connecting attack.
- **Clumsiness** (`W_CLUMSINESS`): on-hit **decapitate** (`CLUMSINESS_DECAP_PCT` via `runicWeaponChance`;
  mirrors `W_QUIETUS` lethal path) in `magicWeaponHit`; while cursed, a pre-hit **fumble** in `attack()`
  (auto-miss + `STATUS_PARALYZED` self-stun, chance reduced by strength over the weapon's requirement).
  Reveals on first proc. (Purify → `W_QUIETUS` already handled in Phase 0b.)

**Why.** Phase 1 of the rework: the sim-able combat curses, ready for Fight-Simulator tuning of the
constants above.

**Where.** `Rogue.h` (constants + `runicCurseActive` decl), `Items.c` (`runicCurseActive` def, `equipItem`
Delirium reveal), `Combat.c` (`magicWeaponHit` Delirium/Clumsiness, `attack()` fumble + Recklessness-dealt,
`inflictDamage` Recklessness-taken, the Clumsiness decap flare), `PowerTables.c` (`runicWeaponChance`
per-runic), `Time.c` (`decrementPlayerStatus` hallucination refresh).

**Notes.** No `STATUS_STUNNED` exists in this engine — the fumble uses `STATUS_PARALYZED` (the engine's
stun, as water-shock does); the constant is raw (the end-of-turn decrement eats 1 → ~1 lost turn). All
rolls use `rand_percent`/`rand_range` (deterministic, replay-safe). Armor curses (Anchor/Smoky/Acrophobia)
remain Phase 2.

**Effect scaling (post-sim decision).** All three effects scale with enchant (parity with how good runics
scale, so purifying-and-enchanting is a real upgrade): Delirium proc `= DELIRIUM_PROC_FLOOR + max(0,e)*_PER_ENCHANT`;
Recklessness dealt `= _DEALT_BASE + max(0,e)*_PER_ENCHANT`; Clumsiness's cursed decap stays flat 4% but its
purified `W_QUIETUS` scales via the runic table and is floored at 4%. Verified with the fightsim `--cursecurve`
mode: cursed phases are a survivable handicap (Clumsiness harshest via the fumble), purify is a clean step-up,
nothing degenerate.

**Playtest grants (`RogueMain.c`, flags in `Rogue.h`, default 0).** `D_DELIRIUM_WEAPON_START` /
`D_RECKLESSNESS_WEAPON_START` / `D_CLUMSINESS_WEAPON_START` each grant an unidentified, cursed −1 runic sword;
`D_CURSE_TEST_SCROLLS_START` grants 12 enchanting + 3 remove-curse to drive the purify/shatter loop. Same
deterministic-grant pattern as the other `D_*_START` flags.

### 2026-07-01 — Cursed-runics rework, Phase 0 follow-ups: deferred shatter-on-unequip; array fix

**What.** The eject consequence for a cursed double-edged runic (design finalized via a grilling pass;
Q-decisions in `docs/design/cursed-runics-rework.md`):
- **Cleansing lifts the weld, it does not destroy** (`uncurse()`): remove-curse / protect clear
  `ITEM_CURSED` on an *equipped* bad runic only (remove-curse's pack sweep leaves unworn cursed runics
  alone). The item drops into a "pending shatter" state (bad runic, unwelded, below purify threshold).
- **Shatter fires on any player-initiated unequip** (`unequipItem`, `force == false` — explicit
  unequip, swap, drop, throw), behind a `confirm()` that warns it shatters the runes *and* pierces the
  nearby walls. Engine-forced unequips never shatter. On confirm: strip the runic, then `crystalize(9)`
  (full wall-breach — opens walls, kills wall-embedded monsters, frees captives) + a `NOISE_BOOMING`
  environmental noise.
- **Noise gap fixed:** scroll of shattering and charm of shattering were silent (`crystalize` emits no
  noise, and scroll-reads emit no player-noise spike). Added `emitEnvironmentalNoise(.., NOISE_BOOMING)`
  at all three shatter sources (eject + scroll + charm), at the call sites — `crystalize()` stays a
  pure terrain function (it is NOT used by staff of obstruction; its only callers are these three).
- Fixed `effectColors[NUMBER_WEAPON_RUNIC_KINDS]` in `magicWeaponHit` (10 initializers for the now-11
  element array left the `W_CLUMSINESS` slot NULL).

**Why.** Accidental scroll reads are common; making eject destructive-on-read would punish a blind
read. Deferring the shatter to the deliberate unequip (with a confirm) keeps an accidental cleanse
harmless while still closing the "remove-curse, shelve, hoard scrolls, re-equip clean" abuse — purity
must be earned by *wearing* the curse to threshold. Residual (accepted): identify-in-pack then
shelf-enchant, self-gated by the extra identify scroll.

**Where.** `Items.c` (`uncurse()`, `unequipItem()`, `SCROLL_SHATTERING`, `CHARM_SHATTERING`),
`Combat.c` (`effectColors`).

**Notes.** Purify never routes through `uncurse()` (it uses `purifyRunicIfReady`), so enchanting toward
threshold never shatters. Swap-to-a-better-item can trigger the shatter confirm (declining aborts the
swap). Rings keep vanilla uncurse (lift unconditionally).

### 2026-07-01 — Cursed-runics rework, Phase 0b/0c: weld lifecycle + generation (save break)

**What.** Decoupled the weld from enchant sign and reworked cursed weapon/armor generation.
- **Generation** (`Items.c`, weapon + armor `makeItemInto`): a negative roll now splits into a
  *double-edged runic curse* (55%, was 33%) — welds (`ITEM_CURSED | ITEM_RUNIC`), starts at **exactly
  −1** — or a plain *inferior* item (45%) — random −1…−3, **no runic and no `ITEM_CURSED`**, so it is
  freely removable.
- **Weld lifecycle:** a cursed runic stays welded until **purified** (enchanted to its threshold:
  weapon +6 / armor +4, `WEAPON_RUNIC_PURIFY_ENCHANT` / `ARMOR_RUNIC_PURIFY_ENCHANT` in `Rogue.h`) or
  **ejected** (remove-curse / protect scroll → `uncurse()`, weld lifts but the downside stays). New
  helpers `isBadRunic`, `runicPurifyThreshold`, `purifyRunicIfReady` (`Items.c`, above
  `checkForDisenchantment`). Purify lifts `ITEM_CURSED` and tempers `W_CLUMSINESS` → `W_QUIETUS`.
- **Enchant scroll path** (`SCROLL_ENCHANTING`): cursed runics no longer uncurse on the first
  enchant — the weld holds until the threshold, then a purge message (a bespoke one for clumsiness).
  Non-runic / rings keep the vanilla `uncurse()` behavior.
- **`checkForDisenchantment`:** the old "any enchant ≥ 0 lifts the curse" clause replaced by
  `purifyRunicIfReady`.

**Why.** Fixes the core complaint (plain-negative weapons/armor being stuck) by making only *runic*
curses weld, and gives cursed runics a purify path. Model in `docs/design/cursed-runics-rework.md`.
The **downside** is not applied yet (Phase 1/2) — the effect code will gate it on
`enchant1 < runicPurifyThreshold`, so purify's raised enchant switches it off automatically while
the weld lift + clumsiness→quietus are the visible transition.

**Where.** `Rogue.h` (threshold `#define`s), `Items.c` (`isBadRunic`/`runicPurifyThreshold`/
`purifyRunicIfReady`, `checkForDisenchantment`, `SCROLL_ENCHANTING`, weapon + armor generation).

**Notes.** `itemMagicPolarity` already flags negatives via `enchant1 < 0`, so inferior items losing
`ITEM_CURSED` does **not** break detect-magic / polarity tells. Rings unchanged (still 16% cursed,
weld, no runic). Approx frequencies now: double-edged runic ≈ 11%, inferior ≈ 9% of weapons/armor.

### 2026-07-01 — Cursed-runics rework, Phase 0a: swap the malevolent runic tail (save break)

**What.** Replaced the pure-downside malevolent runics with the placeholders for the new
double-edged curse set. Weapon `weaponEnchants`: `W_MERCY, W_PLENTY` → `W_DELIRIUM,
W_RECKLESSNESS, W_CLUMSINESS` (`NUMBER_WEAPON_RUNIC_KINDS` 10 → 11). Armor `armorEnchants`:
`A_BURDEN, A_VULNERABILITY, A_IMMOLATION` → `A_ANCHOR, A_SMOKY, A_ACROPHOBIA` (count unchanged at
11). Old on-hit/on-absorb effects removed and **stubbed to no-ops** — the actual behaviors land in
Phase 1 (weapons) / Phase 2 (armor).

**Why.** First step of the cursed-runics rework (design: `docs/design/cursed-runics-rework.md`):
turn cursed weapons/armor from pure "identification noise" into double-edged bargains (always-on
upside + a downside you purify away). This sub-step is the compile-safe rename foundation; weld
lifecycle (0b) and generation (0c) follow. Enum reordering breaks save-compat (SE bumps freely).

**Where.** `Rogue.h` (both enums + `NUMBER_GOOD_*` markers), `Globals.c`
(`weaponRunicNames`/`armorRunicNames`), `PowerTables.c` (`effectChances` rows — bad runics return
early, rows unused), `Combat.c` (`magicWeaponHit` + `applyArmorRunicEffect` dispatch stubbed; the
`A_BURDEN` post-hit `strengthCheck` hook removed), `Items.c` (`weaponRunicEffectDescriptions` +
the weapon/armor runic description switches, interim `[name]` copy pending Phase 2). Marked in-code
`// iOS port (Brogue SE):`.

**Notes.** `Wizard.c`'s create-item runic menu is count-driven
(`NUMBER_*_RUNIC_KINDS − NUMBER_GOOD_*`) and needed no change. Left in place but now unused:
`gameConst.onHitMercyHealPercent` (field + `GlobalsBrogue.c` init) and `DF_ARMOR_IMMOLATION` (enum +
catalog entry) — retire in a later cleanup. No generation/weld changes yet, so cursed items still
weld and still roll −1…−3; only the runic identities changed.

### 2026-07-01 — Altars of Divination replace the deprecated Altars of Insight (new content; save break)

**What.** A new guaranteed reward room — a central **statue** with up to four one-use **altars of divination**
arranged in a cross (one per cardinal direction, one tile out). Place an unidentified item on an active altar
and it is **fully identified** (`identify()`); the altar then **arms** (holds the revealed item) and **seals
shut** when you lift the item (`TM_PROMOTES_ON_ITEM_PICKUP` → `DF_DIVINATION_ALTAR_CLOSE`). "Fire only if it
helps": a known item is a no-op (lift it back freely), so junk can't defuse the room.

**The push-your-luck loop.** Each identify (room-scoped `rogue.divinationAltarUses`) rolls an escalating
chance to awaken the statue's single guardian: **0 / 25 / 50 / 75 %** for uses 1/2/3/4 (`DIVINATION_AWAKEN_*`).
Use 1 is always safe. On an awaken, a tiered monster whose strength scales with *which* use triggered it
**replaces the statue** — **use 2 → Ogre, use 3 → Troll, use 4 → Underworm** (`spawnDivinationGuardian`,
Monsters.c) — the statue cell is cleared and the guardian stands where it stood, emulating the vanilla
`STATUE_DORMANT` shatter (we runtime-spawn rather than activate a pre-placed dormant monster because the kind
depends on the trigger use). **Every unused altar shatters** (a previously-armed altar still holding a revealed
item is spared, so no item is destroyed). One guardian per room; the awaken ends it. The monster emerges **"off balance"**: a large
`ticksUntilTurn` (`DIVINATION_OFFBALANCE_TIER1/2/3` = 200/300/400) delays its first action and surfaces the
existing derived **"(Off balance)"** sidebar tell ([IO.c](IO.c) `ticksUntilTurn > player.ticksUntilTurn +
movementSpeed`). Deadlier tier = longer grace; the Underworm is also natively slow, so the scariest guardian is
the most escapable. Two-channel flavor: the statue escalates each use (*stirs → groans → cracks → shudders
violently*) with a tail clause reporting the roll (*"…but the statue falls silent."* on a safe pull).

**Placement.** Guaranteed **once per run**, force-built with carry-forward from `DIVINATION_ALTAR_MIN_DEPTH`
(D7), abandoned past `DIVINATION_ALTAR_MAX_DEPTH` (D22) — the exact mechanism that built the insight altars,
**retargeted** here (`addMachines`, Architect.c). `roomSize {10,30}`, `BP_IMPREGNABLE` (the guardian can't
tunnel out). The blueprint builds only the carpeted room; `placeAltarCrossInRoom` (Architect.c) lays the statue
at the room-center and an altar one tile out in each cardinal direction (falls back to adjacent).

**Deprecation.** The Altars of Insight **no longer generate** — their `addMachines` carry-forward was replaced
by the divination room. `MT_INSIGHT_ALTAR`, its blueprint, terrain (`INSIGHT_ALTAR_*`), and trigger
(`performInsightSacrifice`) remain in the tree, unreferenced by generation (marked deprecated). Transfer altars
stay disabled (freq 0).

**Save break.** Removing insight generation + adding the new room changes level generation, so old input-replay
saves would desync. Bumped `BROGUE_MINOR` 1 → 2 (recording version "SE 2.1.0" → "SE 2.2.0"), which cleanly
rejects 0.11.0 saves. The title-screen release string / marketing version / release notes are **not** bumped
here — that's the separate release-cut step. (No `BROGUE_VERSION_ATLEAST` gates depend on the minor.)

**Where.** `Rogue.h` — 4 tiles (`DIVINATION_ALTAR`/`_ARMED`/`_CLOSED`, `DIVINATION_STATUE`),
`DF_DIVINATION_ALTAR_CLOSE`, `TM_DIVINATION_ACTIVATION` (Fl(28)), `MT_DIVINATION_ALTARS`, tuning constants,
`rogue.divinationAltar{Built,Uses,Awakened}`, the `BROGUE_MINOR` bump, `spawnDivinationGuardian` proto.
`Globals.c` — the 4 tile defs + the close DF. `GlobalsBrogue.c` — the blueprint. `Architect.c` —
`placeAltarCrossInRoom` + the retargeted carry-forward. `Items.c` — the `updateFloorItems` trigger block +
`performDivination`. `Monsters.c` — `spawnDivinationGuardian`. All marked `// iOS port (Brogue SE):`.

**Determinism.** Awaken via substantive `rand_percent`; guardian kind + grace are pure functions of the use
count; generation/placement use the substantive RNG; all `rogue` fields set deterministically → replay-safe
(reconstructed by replay, no explicit serialization, as with `insightAltarsBuilt`). SE-only gameplay. Docs:
`MACHINES_AUDIT.md`, `IDENTIFICATION_AUDIT.md`, `docs/design/altars-of-divination.md`.

### 2026-07-01 — Noise system: a claimed thrown decoy makes the monster loiter (the "slip by" window)

**What.** A monster investigating a **thrown decoy** used to reach the item, consume it, and immediately
turn back — but on that arrival turn it was still `MB_INVESTIGATING`, so it rolled the **proximity spot
curve** (~50–65% at 3–4 tiles) and reliably re-oriented onto a nearby player: it reached the wrong place
but grabbed you anyway. Now, on claiming the decoy the creature **dwells on the cell** for a seeded
`rand_range(NOISE_INVESTIGATE_DWELL_MIN..MAX)` (4–8, ~6) turns. While dwelling it holds position and drops
from the proximity curve back to the **flat 25% ambient roll** (absorbed by the object, not scanning for
you), keeping `MB_INVESTIGATING` so the `?` blink / `(Investigating)` sidebar persist. That is the "slip
by" window the decoy was meant to buy: the monster is pinned at the wrong place while you break LoS / move
through the space it vacated.

**Scoped to thrown decoys** — the dwell keys on a claimed `ITEM_THROWN_DISTRACTION` (a fixation needs a
physical object). A **player-made-noise** investigate targets an empty cell (`investigateLoc = player.loc`),
finds nothing, and gives up at once, unchanged — that object-vs-empty-cell split *is* the divergence between
investigating a thrown item and investigating a noise you made. Point-blank still bites (25% floor stands),
so a decoy at your own feet is not a free freeze (principle #3). The **approach is unchanged** (proximity
curve en route) — positioning the throw so its path doesn't pass near you stays the player's job.

**Interruptible.** A LOUD hear, a successful spot, damage, or a **louder/closer new noise** all end the
dwell early — each resets `investigateDwell` (the two re-target sites in `checkPlayerHeard` /
`emitEnvironmentalNoise`, and `alertMonster`). Chaining decoys to keep a monster pinned costs one item per
dwell (consume-on-arrival already fired), so it stays a resource drain, not free CC. Only the creature that
*claims* the item dwells; a later investigator arriving at the now-empty cell gives up immediately (emerges
from the item-presence trigger).

**Where.** `Rogue.h` — new `NOISE_INVESTIGATE_DWELL_MIN`/`_MAX` (4/8) levers; new `creature.investigateDwell`
field. `Monsters.c` — init (`initializeMonster`), clear in `alertMonster`, reset at the two re-target sites,
the `awareOfTarget` proximity branch now gated on `investigateDwell == 0` (dwellers fall through to 25%), and
the dwell counter set/decrement + hold-position in the WANDERING arrival block. All marked
`// iOS port (Brogue SE):`.

**Determinism.** Dwell length via a substantive `rand_range`; all state set deterministically → save/replay-
safe, no save-version bump (saves are input replays). SE-only gameplay, gated by `NOISE_SYSTEM_ENABLED`.
Docs: `PERCEPTION_AUDIT.md` §3.2.7 + §7 lever table; `docs/design/environmental-sounds.md` §3.5.1 / §8 (Slice 9a).

### 2026-06-29 — 0.11.0 "B is for Balance": release string + save/recording version bump

**What.** Cut the 0.11.0 release. Two version surfaces moved:
- **Title-screen / `--version`:** `GlobalsBrogue.c` `BROGUE_VERSION_STRING` → `"B is for Balance 0.11.0 "`
  (display-only, as documented in the 2026-06-13 release-string entry below; trailing space intentional).
- **Save/recording version:** `Rogue.h` `BROGUE_MINOR` 0 → 1 and `BROGUE_PATCH` 1 → 0, so the recording
  version string becomes `"SE 2.1.0"` (from `"SE 2.0.1"`).

**Why bump MINOR, not PATCH.** 0.11.0's balance/terrain changes alter how a seed + input stream evolves,
so 0.10.0 (`"SE 2.0.1"`) recordings/saves would go **out-of-sync** if replayed. The loader
(`Recordings.c` ~507) accepts a recording when the patch-pattern `"SE 2.1.%hu"` matches *and* its patch ≤
ours, **or** the version strings are exactly equal. A MINOR bump makes the pattern match fail for old
`"SE 2.0.x"` saves (and the exact-match too), so they are **cleanly rejected** with the "cannot be opened
in version X" dialog rather than loading and desyncing. (A PATCH bump would *not* reject them — patch
bumps are reserved for replay-safe changes; the prior 0.9.0 → 0.10.0 transition only patch-bumped, which
is why 0.9.0 saves could load into 0.10.0 and desync.) Verified safe: `BROGUE_VERSION_ATLEAST` has **zero
usages** in the engine, so bumping the version flips no gameplay gate. Recording version string stays ≤ 16
chars. Marked `// iOS port (Brogue SE):` at the version defines.

### 2026-06-27 — Remove the Rapid Brogue and Bullet Brogue game variants (SE only)

**What.** SE now ships a single game variant (Brogue). The `VARIANT_RAPID_BROGUE` and
`VARIANT_BULLET_BROGUE` paths — quarter-length and 5-level speed variants inherited from upstream CE —
were removed entirely. SE is the firehose fork and never offered variant selection in the shipped iOS UI
anyway (the "Change Variant" flyout button was already removed; `chooseGameVariant()` was unreachable), so
this just deletes the now-dead machinery.

**Why.** All SE gameplay/content (item rework, gold goblin, altars, smoke, …) is authored against the
full-length Brogue variant only. Maintaining three parallel `Globals*.c` catalogs (every potion/scroll/wand
row, horde, blueprint, depth constant) tripled the edit surface for every content change with no shipped
benefit, since the variants weren't selectable.

**Changes.**
- **Deleted** `GlobalsRapidBrogue.{c,h}` and `GlobalsBulletBrogue.{c,h}`. The BrogueSE target is a
  synchronized folder group in `iBrogue_iPad.xcodeproj`, so removing the files from disk drops them from the
  build with no pbxproj edit.
- `Rogue.h` — dropped `VARIANT_RAPID_BROGUE` / `VARIANT_BULLET_BROGUE` from `enum gameVariant` (leaving
  `VARIANT_BROGUE` + `NUMBER_VARIANTS`); dropped `NG_GAME_VARIANT` from `enum NGCommands`; refreshed the
  `MT_TRANSFER_ALTAR` / `MT_INSIGHT_ALTAR` comments that referenced the per-variant catalogs.
- `RogueMain.c` — removed the two `Globals{Rapid,Bullet}Brogue.h` includes, the two `printBrogueVersion()`
  variant lines, and collapsed `initializeGameVariant()` to call `initializeGameVariantBrogue()` directly.
- `MainMenu.c` — deleted `chooseGameVariant()` and its two now-dead dispatch sites (the flyout branch and the
  `NG_GAME_VARIANT` case in the game loop).
- `Architect.c` — deleted the Bullet-only depth-1 guaranteed weapon vault; simplified the now-always-true
  `gameVariant == VARIANT_BROGUE` guards on the transfer-altar pair placement and the insight-altar
  force-build.

**Save/recording compatibility.** Existing Rapid/Bullet recordings (version strings `RB`/`BB`) will no
longer replay — they fail the normal recording version check like any incompatible recording. Accepted
(straight removal, no migration); SE saves are isolated under `Documents/se/` and SE is Game-Center-silent.

### 2026-06-27 — Smoke: burning terrain emits a vision-obscuring gas (new content)

**What.** A new gas, `SMOKE_GAS`, emitted by ordinary burning terrain. It obscures vision in two tiers
governed by a single threshold (`SMOKE_THICK_VOLUME`, default 15):
- **Thin smoke (< threshold)** only *dims* the cell (a gentle negative light, `SMOKE_LIGHT` /
  `smokeCloudColor` `-10`, milder than the supernatural darkness cloud's `-20`) and **dissipates fast**
  (~75%/turn).
- **Thick smoke (≥ threshold)** also **blocks line of sight** and **dissipates slowly** (~35%/turn), so a
  real blaze walls off an area for a handful of turns and then the core crumbles once it thins.

It's **additive**: each burning `PLAIN_FIRE` tile rolls (`SMOKE_EMISSION_CHANCE`, default 45%) to puff a
low-volume `DF_SMOKE_ACCUMULATION` into the gas layer each turn, and the volumetric system pools puffs from
many tiles — a bigger fire makes proportionally more smoke. Only `PLAIN_FIRE` (ordinary burning terrain)
smokes; gas-fire flashes, brimstone, and explosions do not (keeps firebolt spam from whiting out a fight).
Smoke is **non-flammable** and does **no damage** — purely an obscuring effect.

**Symmetric, with built-in counter-pressure.** Smoke blocks the player's and monsters' sight equally
(monsters perceive the player via the player FOV grid `IN_FIELD_OF_VIEW`, which the gate below feeds). The
costs that keep it from being a free escape: smoke comes *from dangerous fire*; standing in thick smoke
blinds **you** too and chokes your own light; and — crucially — smoke does **not** muffle sound (see below),
so a screen breaks line of sight but a pursuer can still *hear* you via the SE noise system. (Grilled design;
see the Q&A captured in the design notes.)

**Sight-only, not a wall.** Smoke deliberately carries **no `T_OBSTRUCTS_VISION` terrain flag**. Instead a
volume-gated helper `cellHasThickSmoke()` (`Globals.c`, declared in `Rogue.h`) is consulted in the FOV
shadowcaster `scanOctantFOV` (`Movement.c`, both the init and loop obstruction checks) **only when the scan
is a vision query** (`forbiddenTerrain & T_OBSTRUCTS_VISION`). Consequences, all intended:
- Player FOV, monster FOV, and **light propagation** (all route through `scanOctantFOV`) honor the block —
  so thick smoke is opaque to sight and chokes light.
- **Projectiles pass through** (bolts/lightning/arrows/blink use `getImpactLoc`/`getLineCoordinates`, which
  test the terrain flag directly — untouched), and **sound carries through** (the noise cost map keys off
  `T_OBSTRUCTS_VISION`, which smoke lacks). Monster↔monster LOS (`openPathBetween`) is likewise unaffected.

**Bottle capture/release.** The SE empty bottle can capture smoke (`emptyBottleCaptureKindForTile` →
`POTION_SMOKE`, a frequency-0 capture-only potion added to all three variant `potionTable`s and the
`captureOnlyKinds` auto-ID list). Thrown (`shatterPotionAtLoc`) or uncorked in hand it releases a real but
short-lived screen via `DF_SMOKE_POTION` (`{SMOKE_GAS, GAS, 250, 0, 0}`). The cost is the bottle economy
itself — scarce + single-use — not a new safeguard; release potency is fixed (doesn't scale to captured
volume), like every other captured gas.

**Determinism / save-safety.** Smoke is fully state-driven: the per-turn emission rolls with `rand_percent`
(substantive RNG) in `updateEnvironment`'s fire loop, and volume lives in `pmap[][].volume`, reconstructed
deterministically each turn — never serialized. The dimming/sight-block are pure reads of that state (no
RNG). `updateVolumetricMedia` already runs before the FOV/light recompute, so smoke and sight agree within
the turn. Adding the `SMOKE_GAS`/`SMOKE_LIGHT`/`DF_SMOKE_*`/`POTION_SMOKE` enum entries (each paired with its
parallel catalog/table row) doesn't touch save format (recordings store inputs, not tile indices).

**Files.** `Rogue.h` (constants `SMOKE_THICK_VOLUME`/`SMOKE_EMISSION_CHANCE`; `SMOKE_GAS`, `SMOKE_LIGHT`,
`DF_SMOKE_ACCUMULATION`, `DF_SMOKE_POTION`, `POTION_SMOKE` enums; `cellHasThickSmoke` proto). `Globals.c`
(`smokeColor`/`smokeCloudColor`, the `SMOKE_LIGHT` light row, the `SMOKE_GAS` tile row, the two `DF_SMOKE_*`
catalog rows, `cellHasThickSmoke`). `Globals{Brogue,BulletBrogue,RapidBrogue}.c` (the `"smoke"` potion row).
`Time.c` (emission hook in `updateEnvironment`; volume-keyed dissipation in `updateVolumetricMedia`).
`Movement.c` (the `scanOctantFOV` sight gate). `Items.c` (capture, throw-release, quaff-release, capture-only
list). All marked `// iOS port (Brogue SE):`. Tuning dials: `SMOKE_THICK_VOLUME`, `SMOKE_EMISSION_CHANCE`,
the `DF_SMOKE_ACCUMULATION`/`DF_SMOKE_POTION` volumes, and the two dissipation rates. **Deferred v2 dials:**
ember-emission (longer haze), release potency scaling to captured volume, smoke issuing its own noise tell.

### 2026-06-25 — Status-blink overlays: confused / on-fire / stunned tells on the map (new content)

**What.** A creature (or the player) now shows a blinking glyph over its cell while afflicted:
- **Confused** → `?` tinted psychotropic **purple** (purple so it never reads as the white "investigating,
  heard something" `?` from the noise system).
- **On fire** (`STATUS_BURNING`, *not* the `MONST_FIERY` trait — matching the light/extinguish systems) →
  the **flame** glyph `G_FIRE`.
- **Paralyzed / stunned** (`STATUS_PARALYZED`) → a true **star** `G_STUN_STAR` (★, U+2605), "seeing stars"
  yellow. *(Bugfix 2026-06-27: was an ASCII `'*'`, which is identical to the gold-pile glyph `G_GOLD` — a
  paralyzed creature read as a pile of money. Monaco has no star glyph, so `G_STUN_STAR` is a new cosmetic
  glyph appended to the `displayGlyph` enum (`Rogue.h`), mapped to U+2605 in `ce_glyphToUnicode` (`SEBridge.mm`),
  and classified as an ArialUnicodeMS glyph in `RogueScene.swift` — the same Arial-Unicode path the ring /
  foliage glyphs already use, since Monaco can't render it. Swap the codepoint to a sparkle (✦/✴/✶) in one
  line if a burst reads better than a filled star.)*

- **Confused** (`STATUS_CONFUSED`) → an inverted **`¿`** `G_INVERTED_QUESTION`, psychotropic purple.
  *(2026-06-27: was an upright `'?'` distinguished from the white noise-system investigate `?` by purple tint
  alone; the inverted glyph differs in shape too. `¿` (U+00BF) is present in Monaco, so unlike the star it
  renders through the default text path — just the enum constant (`Rogue.h`) + `ce_glyphToUnicode` map
  (`SEBridge.mm`), no `RogueScene.swift` change.)*

- **Healing** → a rose-pink **`♥`** `G_HEART` (warm/wort family, but lifted lighter + pinker than the dim
  `darkRed` healing cloud so it separates from the spores it sits in). *(2026-06-27.)* Two triggers, lowest priority (a threat/affliction
  is the more urgent read): (1) a **discrete heal** just landed — every `heal()` call (potion/charm, staff-of-
  healing bolt, bloodwort-pod panacea, on-hit mercy heal, resurrection), shown briefly even if it topped the
  creature off; **passive regeneration is excluded** because it adds HP directly (`currentHP += regenPerTurn`)
  and never calls `heal()`, so creatures don't wear a permanent heart while slowly recovering. (2) **Actively
  gaining HP from bloodwort spores** underfoot (`T_CAUSES_HEALING`), shown only while below max HP. The discrete-
  heal trigger is a small pointer-keyed `gHealMarks[]` table in `IO.c` (set by `cosmeticMarkHealed()` from
  `heal()` on a real HP gain, **debounced**: it stamps `absoluteTurnNumber` and the heart shows while within
  `HEAL_BLINK_TURNS` = 2 turns — a turn *window*, not a per-refresh countdown, because the rebuild fires several
  times in some turns, e.g. the paralysis watch sub-loop, so a countdown would flash off mid-turn; rapid
  re-heals in one turn just re-stamp the same turn, no flicker); the wort trigger is a
  live terrain check, no state. `♥` (U+2665) isn't in Monaco, so like the star it routes through ArialUnicodeMS
  (the renderer's `.arialSymbol` glyph type, shared with `G_STUN_STAR`).

- **Protected** (`STATUS_SHIELDED` — staff/charm of protection, dar-priestess/sentinel shielding bolts) → a
  green crest **`◈`** `G_SHIELD_CREST`. *(2026-06-27.)* A persistent `status[]` value, so it needs no marker —
  just a check in `statusBlinkGlyphFor`, ranked above healing (your damage being absorbed is the more
  actionable read). No true shield glyph exists in Monaco or Arial Unicode (🛡/⛨ are absent, and the emoji
  couldn't be tinted), so `◈` (U+25C8) is the geometric stand-in; like the star/heart it routes through
  ArialUnicodeMS (`.arialSymbol`).

One tell at a time, by priority: burning > paralyzed > confused > shielded > healing. Applies to the player too.

**Hasted → a fading after-image** *(2026-06-27)*, a **separate** effect from the one-tell status glyphs (it can
coexist with them). When a visible `STATUS_HASTED` creature (player included) moves, it leaves a single
electric-cyan ghost of its own glyph on the tile it just vacated, dimming as it ages out
(`NOISE_HASTE_TRAIL_FRAMES`). A fast mover drops one ghost per step, so a short fading train trails it — motion
without a full streak. A new `CE_SPEED_TRAIL` cosmetic kind (single-cell; `origin` = the vacated tile); movement
is detected per-turn in `cosmeticRefreshStatusBlinks` via a pointer-keyed `gHasteTrack[]` last-position table
(`cosmeticTrackHasteTrails`), capped at `NOISE_HASTE_TRAIL_MAX_DIST` so a non-walk jump doesn't drop a ghost
across the map. Cosmetic-only and suppressed under automation/playback (positions jump there), so it's
display-only and replay-safe.

**Reuse.** Built entirely on the existing noise-system cosmetic-overlay layer (the `?` investigate-blink /
`!` alert-blink): a new `CE_STATUS_BLINK` effect kind, a `cosmeticRefreshStatusBlinks()` sibling to
`cosmeticRefreshInvestigateBlinks()` (creature-keyed, follows the creature, despawns when the status/visibility
ends), and four tint colors. It pulses in the same global unison phase and is rendered in a final pass so a
status tell paints **over** any investigate `?`/alert `!` on the same cell (the affliction is the more
important read). All in `IO.c`; per-turn rebuild called from `Time.c` (`playerTurnEnded`) and `Movement.c`
(travel-end), prototype in `Rogue.h`.

**Animating during paralysis / rest / travel.** The blink clock (`gCosmeticBlinkTick`) is driven by the
platform idle pump (`nextKeyOrMouseEvent`'s `colorsDance` tick), which doesn't run while the engine is spinning
its own turn loop — forced "watch helplessly" paralysis turns, *and* rest / travel / auto-explore. Left alone
the tells freeze, and (worse) the per-turn rebuild used to **deactivate** them under `automationActive`, so a
heart/star would vanish for the whole rest and pop back at the end — read as a "reset." Fixed two ways: (1) the
rebuild now keeps the tells up during interactive automation (only fast *replay* hard-suppresses); (2) the
cosmetic layer is pumped through those stretches — `advanceCosmeticAnimations` + `commitDraws` from
`pauseForMilliseconds` (`SEBridge.mm`), throttled to ~60 Hz of real time so a sub-millisecond rest loop doesn't
strobe the blink — plus the existing paralysis-watch sub-pauses in `Time.c`. So the tell keeps a steady on/off
pulse while you rest or travel. (Monster paralysis always animated — the idle loop runs between your turns.)

**Determinism / save-safety.** Display-only — the cosmetic layer runs under `RNG_COSMETIC`, draws nothing
into game state, and is hard-suppressed during playback fast-forward. No engine-state or save impact.
Marked `// iOS port (Brogue SE):`. (`STATUS_FROZEN` is deliberately *not* included — frozen already has its
own strong icy tint in `getCellAppearance`; easy to add a `*` there too if wanted.) The healing tell's
`cosmeticMarkHealed()` hook in `heal()` (`Items.c`) is the one touch outside `IO.c`: it only writes the
pointer-keyed `gHealMarks[]` cosmetic table (never read by game logic or the substantive RNG) and bails early
under automation/playback, so it stays display-only and replay-safe.

**Known minor nuisance (deliberately NOT fixed).** A status/investigate/alert tell on a cell touched by the
per-cursor-move redraw (`refreshDungeonCell` / `hilitePath` / `hiliteCell`) — most visibly the creature you
hover toward — blanks for up to one idle frame (~16ms) until `advanceCosmeticAnimations` repaints it. Two
attempts to re-stamp the overlay from `mainInputLoop` both produced worse artifacts: running the whole
compositor on every move stranded expanding ripple wavefronts on screen ("hanging"), and an additive glyph-only
re-stamp got pinned on screen by `moveCursor`'s `saveDisplayBuffer`/`restoreDisplayBuffer` dance (the saved
buffer captured the stamped `?`/`!`, which `restoreDisplayBuffer` then re-applied after the idle tick cleared
them). The overlay layer compositing into the display buffer fundamentally fights `moveCursor`'s save/restore,
so the momentary blank is accepted rather than chased. See KNOWN_CAVEATS.md.

### 2026-06-25 — Staff "glow-up": lightning stun+chain and firebolt bloom at netEnchant ≥ 5 (new content)

**What.** Two staffs gain new behavior once their **netEnchant reaches 5**, then ramp with further enchant:
- **Lightning** — every creature the bolt strikes is **briefly stunned** (non-stacking `STATUS_PARALYZED`,
  ramp 1→3 turns), and the charge **chains** from the last struck creature to nearby enemies the straight
  line *missed* (1 jump at +5, ramping to 3; per-link damage falloff; each arc also stuns).
- **Firebolt** — the bolt **erupts into an incineration bloom** at its impact point (augmenting the direct
  hit), reusing `DF_INCINERATION_POTION`; the bloom spreads farther with enchant. Real fire — it burns the
  player and ignites the dungeon (the built-in cost).

**Gating / ramp.** Keyed on **`netEnchant >= 5`** (so curse/low-strength can't cheat it), carried into the
bolt via a new `empowerment` field on the `bolt` struct (set in `useStaffOrWand`, `Items.c`; catalog
entries default it to 0). Behavior triggers on actual enchant regardless of identification; only the
*description specifics* are gated on the enchant being known. New `PowerTables.c` ramps:
`staffLightningStunDuration`, `staffLightningChainCount`, `staffLightningChainRange`,
`staffFireboltBloomDecrement` (lower decrement = bigger bloom).

**Reuse / no double-hits.** Stun reuses the electrified-water pattern (`max(existing, dur)` — non-stacking,
can't stun-lock). The chain is a **controlled arc** (`resolveLightningChain`, `Items.c`), *not* `zap()`
recursion: it reuses the same `staffDamage` roll + stun, picks the nearest unstruck enemy within range on
an open path (deterministic; monster-iteration order breaks ties), and shares a **struck-set** with the
line (generalizing electrified water's "ring-0 exclusion") so a creature already pierced by the line is
never hit again and the chain can't ping-pong.

**Where.** `Rogue.h` (bolt `empowerment` field + power-fn prototypes); `PowerTables.c` (4 ramp fns);
`Items.c` (`useStaffOrWand` sets empowerment; `updateBolt` BE_DAMAGE applies the stun; `zap` records the
struck-set and, once the bolt lands, runs the chain or spawns the firebolt bloom at the last passable
cell; `resolveLightningChain` helper; `itemDetails` enchant-known clauses); `Globals.c` (generic clause
appended to both staff descriptions, within the ~540-char cap).

**Determinism / save-safety.** Pure deterministic math + substantive-RNG damage rolls; the `bolt` struct is
transient (never serialized), so the new field is save-safe. Player-staff-only — monster-cast bolts have no
enchant and stay vanilla. Marked `// iOS port (Brogue SE):`.

### 2026-06-25 — Explosions knock everything caught in them back (new content)

**What.** A concussive explosion now flings every animate, mobile creature (the player included) caught in
it away from the blast — into a wall, another creature, or a hazard. Covers every source uniformly because
they all funnel through the one tile that carries `T_CAUSES_EXPLOSIVE_DAMAGE` (`GAS_EXPLOSION`): exploding
bloat, vampire blood-burst, explosive-mutation death, **and** methane/swamp-gas ignition. Incendiary darts
and the incineration potion place *fire*, not `GAS_EXPLOSION`, so they (correctly) don't knock back — fire
isn't concussive.

**Reuse (the "force effect").** Extracted the frost block-push into two shared primitives in `Combat.c`:
`shoveCreatureAlong` (slide along a vector, stop on hazard / before wall/creature/edge, relocate via
`setMonsterLocation` so it's correct for player *and* monsters) and `applyShoveImpact` (momentum damage to
whatever it slams into). `pushFrozenCreature` (staff of frost) now consumes both; the new public
`knockCreatureFromExplosion` also consumes both — no duplicated movement code.

**Direction without an origin.** A gas cascade has no single epicenter (each methane cell detonates
independently — `Time.c` `exposeTileToFire`). So direction comes from the **local gradient**: push away
from the centroid of nearby fire/blast cells (radius 3), collapsed to one of eight unit directions. Point
sources (bloat/dart) and distributed methane both work through this one path; a creature dead-centre in a
symmetric blast (net-zero gradient) isn't flung.

**Where / how it stays correct.** Hooked into the existing `T_CAUSES_EXPLOSIVE_DAMAGE` branch of
`applyInstantTileEffectsToCreature` (`Time.c`), for both the player and monster survive paths. The blast's
own fire/explosive damage is unchanged and applied first. The pre-existing `STATUS_EXPLOSION_IMMUNITY = 6`
(set before the knockback) means each creature is flung **once** per blast and prevents the re-entrant
`setMonsterLocation` → `applyInstantTileEffectsToCreature` from re-triggering the explosion at the landing
cell. The hook only short-circuits the rest of the old cell's tile effects when the creature was actually
relocated (knockback returns a moved/not-moved boolean). Per design call: the **player can be flung into
lava/a chasm** ("everything flung equally"), and a wall/creature slam deals the frost push's momentum
damage. Deterministic (geometry + flat force, no RNG), so input-replay saves are unaffected. Marked
`// iOS port (Brogue SE):`.

**Gated OFF for 0.11.0 (2026-06-29).** Shipped disabled behind `SE_EXPLOSION_KNOCKBACK` (Rogue.h, a
"single kill switch" alongside `NOISE_SYSTEM_ENABLED`). `knockCreatureFromExplosion` early-returns `false`
under `#if !SE_EXPLOSION_KNOCKBACK`, so the two `Time.c` call sites fall through to the normal tile effects
— the blast still burns/damages, it just doesn't fling anyone. Kept as a knob rather than reverted so a
future release can flip it back on without untangling the eight later commits that touch `Combat.c`/`Time.c`.
A feature that never fires can't perturb the substantive RNG stream, so leaving it off is seed/replay-safe.

### 2026-06-25 — Ring of transference also transfers afflictions on hit (new content)

**What.** The ring of transference (heal-in-proportion-to-damage "blood magic") now also bleeds a fraction
of the *player's own* harmful statuses into whatever it strikes. Curated to the statuses that map cleanly
onto a monster: **poison, fire (burning), slow, weakness, confusion**. Each hit sheds
`status * transference / playerTransferenceRatio` turns (the same 5%/level as the heal, floored at 1,
capped at what the player has) from the player and applies them to the defender — so e.g. a poisoned
player relocates a slice of the poison onto the creature they hit, at the player's current concentration.

**Why rate-limited (counter-pressure, not a strict upgrade).** Poison/etc. are core attrition clocks;
a full one-hit dump would let the player launder any affliction into the nearest monster and trivialize a
whole threat category. Rate-limiting keeps it a *tempo* tool — the affliction keeps ticking on you while
you punch it off, and you need a valid (animate, non-invulnerable) target. **Positive ring only**: a cursed
ring keeps its existing HP-drain downside (`gameOver("Drained by a cursed ring")`) and grants no relief.

**Where.** `Combat.c` — new static helper `transferAfflictionsToTarget(defender)` above `inflictDamage`,
called from the existing transference block in `inflictDamage` (guarded `attacker == &player`; the helper
no-ops on `rogue.transference <= 0` or an `INANIMATE`/`INVULNERABLE` target). Reuses the existing appliers
(`addPoison`, `slow`, `weaken`, direct burning/confusion status, `extinguishFireOnCreature` +
`updateEncumbrance` to clean up the player side on full shed). `Globals.c` — `ringTable` transference
description rewritten to mention the affliction bleed (still under the ~540-char cap). Only the player ring
transfers afflictions; monsters/allies with `MA_TRANSFERENCE` keep HP-only transference.

**Determinism / save-safety.** Pure arithmetic on deterministic combat state — no RNG, no new struct
fields — so input-replay saves are unaffected. Marked `// iOS port (Brogue SE):`.

### 2026-06-25 — Staff of frost suppresses (not freezes) a fiery aura, which rekindles after N turns (new content)

**What.** Hitting a fiery creature (wisp / salamander / flamedancer — the `MONST_FIERY` set) with the
**staff of frost** already douses + slows it rather than encasing it in ice (frost can't freeze fire).
Previously that dousing was *accidentally permanent* — `extinguishFireOnCreature` zeroed `STATUS_BURNING`
and nothing re-pinned it (a stale code comment even claimed "MONST_FIERY creatures relight every turn,"
which was never implemented). Now the dousing is an explicit **temporary suppression**: the fire
**rekindles after N turns**. This gives frost and the water bottle distinct roles — frost = a timed
reprieve, water bottle = permanent declaw (strips the flag).

**How.** New monster-facing status `STATUS_FIERY_DOUSED` (a countdown):
- `Rogue.h` — new enum value after `STATUS_FROZEN`; `Globals.c` `statusEffectCatalog` gains the matching
  `{"Doused", …}` row (kept in lockstep with the enum; shows as a countdown bar on the creature's info
  panel via the generic `IO.c` status-display branch).
- `Items.c` `freezeCreature` — the fiery/burning branch sets `STATUS_FIERY_DOUSED` to the bolt's freeze
  duration (`staffFreezeDuration`) **only for `MONST_FIERY` creatures** (an ordinary creature you merely
  set alight stays doused — it isn't fiery). Reuses the same duration a normal creature would be frozen.
- `Monsters.c` `decrementMonsterStatus` — new `STATUS_FIERY_DOUSED` case: on lapse, re-pin
  `STATUS_BURNING`/`maxStatus` to 1000 **iff still `MONST_FIERY`** (a water bottle may have stripped the
  flag meanwhile) **and not already burning**, with a visible "flares back to life" tell.

**Determinism / save-safety.** Suppression duration derives from staff enchant (deterministic), the
countdown lives in the per-turn status loop, and adding a status enum grows the in-memory `status[]`
arrays only — saves are input replays, so no save-format break. Marked `// iOS port (Brogue SE):`.

### 2026-06-25 — Water bottle direct hit douses fire and strips MONST_FIERY (new content)

**What.** A thrown **bottle of water** (`POTION_WATER`) that directly strikes a creature now douses its
fire: it extinguishes `STATUS_BURNING` on any flammable creature, and on a **fiery** creature
(wisp / salamander / flamedancer — the `MONST_FIERY` set) it also **permanently strips `MONST_FIERY`**,
so the creature stops re-igniting its own tile and can stay doused. The tile still floods (`DF_FLOOD`)
as on any water shatter. A struck creature that is neither burning nor fiery just gets wet — the branch
falls through to the normal flood.

**Why this is a declaw, not a kill.** All three `MONST_FIERY` creatures carry `MONST_IMMUNE_TO_FIRE`
as an *independent* flag, so removing `MONST_FIERY` leaves fire immunity intact — the creature loses its
persistent burning aura and terrain-ignition, not its life or its (`MA_HIT_BURN`/whip) attacks. This is a
deliberate counter-pressure tool (costs a bottle + a landed direct hit), not a strict upgrade. Precedent:
negation already treats `MONST_FIERY` as strippable (it's in `NEGATABLE_TRAITS`) and douses on removal.

**Where.** `throwItem` POTION struck-creature path in `Items.c` (alongside the `POTION_LIFE`/`VENOM`/`ACID`
direct-hit cases), marked `// iOS port (Brogue SE):`. Clears the flag **before** calling
`extinguishFireOnCreature` so the `MONST_FIERY` water-exemption in `applyInstantTileEffectsToCreature`
(`Time.c`) no longer blocks the dousing.

**Determinism / save-safety.** A thrown direct hit is a deterministic player input, and per-instance
`monst->info.flags &= ~MONST_FIERY` is the established runtime flag-mutation pattern (negation,
resurrection cleanup). Saves replay inputs, so this is save-safe.

**Known availability note.** The empty bottle is refillable at any water tile, so water (and thus this
effect) is effectively unlimited near water — and the salamander lives in water. Accepted per design call;
the direct-hit requirement against evasive (submerging / flitting) targets is the intended cost.

### 2026-06-23 — Trap-anchored thematic terrain: dry grass at fire traps, bones at caustic traps (new content)

**What.** A fire trap (`FLAMETHROWER` / `FLAMETHROWER_HIDDEN`) now has a ~40% chance to be ringed by a patch
of dry grass; a caustic gas trap (`GAS_TRAP_POISON` / `_HIDDEN`) the same chance to sit amid a patch of bones.
Light flavor that gives a soft, room-level "maybe search here" cue — *not* a reliable tell, because the patch
is offset (never a marker on the trap cell), the chance is partial, and bones/dry grass already occur naturally
across the dungeon. The fire case is also a real escalation: dry grass is `T_IS_FLAMMABLE`, so a triggered fire
trap ignites the patch into a spreading blaze (a deliberate, vanilla-consistent danger — accepted, unlike the
[firebolt scroll-burn rejection](../../KNOWN_CAVEATS.md), because this is environmental, not a player tool).

**How (data-driven, reusable).**
- `Rogue.h` — `autoGenerator` gains two trailing fields: `companionDF` (a `DF_*`) + `companionChance` (percent).
  `0`/absent = none, so every other generator row is untouched (and save-safe — static catalog data).
- `GlobalsBrogue.c` — the two fire-trap rows set `companionDF = DF_TRAP_DRY_GRASS`; the two caustic-trap rows
  set `companionDF = DF_BONES`; all four `companionChance = 40`. Applied to both the revealed and hidden
  variants (uniform — so "patch ⇒ hidden trap" stays *less* inferable, not more).
- `Globals.c` / `Rogue.h` — one new DF, `DF_TRAP_DRY_GRASS` (`DEAD_GRASS`, contained `75/25` vs open-field
  `DF_DEAD_GRASS`'s `75/5` sprawl, and crucially chains *no* dead foliage). Caustic reuses the stock `DF_BONES`.
- `Architect.c` — `runAutogenerators`, after placing the trap, rolls `companionChance` and spreads `companionDF`
  from a cell found by `getQualifyingLocNear` with the foundation cell **blocked as the origin** (forcing an
  offset) and liquids/machines/stairs/items forbidden. No special-casing of the trap cell — the spread covers
  it or not by chance, like any natural patch.

**Reusability.** `companionDF` is the trap/autogenerator-side analogue of `hordeType.spawnDF`: the rest of the
"world feel alive" backlog (scorch marks, blood trails, mineral deposits, …) is now config on an autogenerator
row, not new code.

**#832 interaction.** None — `DEAD_GRASS`/`BONES` aren't `T_OBSTRUCTS_VISION`, so the fillSpawnMap trap guard
leaves them alone and they don't hide the trap (the trap's lower `drawPriority` also draws it over them).

**Determinism / saves.** Chance roll + offset pick + spread all run on substantive RNG during generation, so
they replay from the seed. New struct/DF fields are static catalog data — save/replay-safe. Shifts generation
for existing seeds (expected for new content; SE is Game Center–silent). Marked `// iOS port (Brogue SE):`.

### 2026-06-23 — Noise system: a pack's rallying cry (ripple + message when a creature rouses its companions)

**What.** When a creature actually rouses dormant packmates — `wakeUp()` flips ≥1 teammate from
SLEEPING/WANDERING to hunting — it now emits a **rallying-cry tell**: the (bright/slow) amber impact ripple
from its cell, plus a one-line message. Named if you can see the crier (`"the jackal rouses its
companions!"`), a generic `"you hear a rallying cry echo through the dungeon."` if it's only within earshot
(`soundDistanceAt <= NOISE_PACK_ROUSE_EARSHOT = 16`), silent if out of both. So a jackal hearing/seeing you
and waking its pack now reads on screen instead of happening invisibly.

**Where.** `Monsters.c` — `wakeUp()` counts genuinely-roused packmates (`rousedCount`, was-dormant only) and,
under `#if NOISE_SYSTEM_ENABLED`, calls new static `announcePackRouse()` when `rousedCount > 0` **and** the
crier is a live enemy (not ally/captive — excludes the captive-freeing / summon `wakeUp` paths). `Rogue.h` —
`NOISE_PACK_ROUSE_EARSHOT`. Reuses `impactRippleRadius` / `cosmeticSpawnRippleImpact` (forward-declared) and
`soundDistanceAt` (the same player-earshot metric `checkPlayerHeard` uses).

**Why this choke point.** `wakeUp()` is the single horde-alert broadcast (called from heard-LOUD, spotted-
while-sleeping, melee-on-a-sleeper, …); gating on `rousedCount > 0` means it fires once per genuine pack-
awakening and **self-dedupes** — a second loud noise that turn finds them already hunting (count 0), so no
repeat cry. Fires across all rouse triggers (the chosen "any genuine pack rouse" scope), not just sound/sight.

**Determinism / saves.** Ripple is cosmetic (`RNG_COSMETIC`, self-suppresses off-idle); message uses flags 0
(no acknowledgment pause, so no input-flow change); `rousedCount`/sight/earshot are deterministic reads. No
substantive RNG, no new persisted state → save/replay-safe. All edits marked `// iOS port (Brogue SE):`.

**Update 2026-06-24 — submerged criers are silent.** `announcePackRouse()` now early-returns when the crier
carries `MB_SUBMERGED`, mirroring the guard in `monsterEmitMovementNoise()`: a submerged eel/kraken still
rouses its pack (the substantive `wakeUp` loop is untouched), but emits no ripple or rallying-cry message —
the splash on emerge is the real tell. Previously a submerged creature spammed the amber ripple + log.

### 2026-06-23 — Fix: foliage generated on a trap hides it & blocks darts (BrogueCE #832)

**Cherry-pick candidate — not yet applied to BrogueCE / Classic.** This is an upstream correctness bug
([tmewett/BrogueCE#832](https://github.com/tmewett/BrogueCE/issues/832)), not SE gameplay, so it lives in
shared engine code present in all three engines. It is fixed **in SE only for now**; when it comes time to
cherry-pick, the same two edits apply verbatim to `BrogueCE/Engine/` and `iBrogue_iPad/BrogueCode/`, and the
projectile change is a clean upstream PR.

**Symptom.** A trap generated on a cell that also holds dense foliage (e.g. a fire trap under `FOLIAGE`) is
**invisible** — the surface foliage draws over the trap glyph — and a dart thrown at the trigger **fails to
land on it**, so the trap can't be sprung remotely.

**Root cause (two parts).**
1. *Generation.* Nothing stopped a vision-blocking surface tile and a trap from sharing a cell. Autogenerated
   foliage (and now the jackal den) could spread over a trap.
2. *Projectile.* `throwItem` (`Items.c`) stops a thrown item on any cell flagged
   `T_OBSTRUCTS_PASSABILITY | T_OBSTRUCTS_VISION`. `FOLIAGE` is **passable but vision-blocking**, so the item
   hit that clause, fell past the incendiary-dart and promotable-tile carve-outs, and **backed up one cell**
   (`i--`) — resting *before* the foliage. The trap-trigger path in `placeItemAt` (`Items.c`, `T_IS_DF_TRAP`)
   only fires when an item lands *on* the trap cell, which now never happened.

**Fix.**
- `Architect.c` — `fillSpawnMap` gains a guard clause: never paint a tile with `T_OBSTRUCTS_VISION` onto a
  `T_IS_DF_TRAP` cell. Engine-wide, so it covers autogenerator foliage, the jackal den, and runtime regrowth.
  This is the primary fix and resolves *both* #832 symptoms (hidden trap + un-triggerable trap).
- `Items.c` — `throwItem` gains an `else if (!T_OBSTRUCTS_PASSABILITY)` branch mirroring the existing
  incendiary-dart carve-out: a *passable* vision-only obstruction is **landed on**, not bounced off, so the
  item rests on the cell (and springs a trap there). A solid wall (`T_OBSTRUCTS_PASSABILITY`) still backs up.
  This is a safety net for any foliage-on-trap created at **runtime** (regrowth, fire-spread grass), where the
  generation guard can't reach.

**Determinism / saves.** No new RNG, no struct/format change; both edits are pure logic. Replay-safe. Note the
generation guard can subtly change a level's terrain vs. an old seed (a trap cell that previously hid under
foliage now stays bare) — expected for any generation change; SE is Game Center–silent. Marked
`// iOS port (Brogue SE):`.

### 2026-06-23 — Jackal packs den in dense foliage (new content)

**What.** A jackal **pack** (the `{MK_JACKAL, +members}` horde, depths 3–7 — *not* the lone jackal) now
generates inside a small **den of dense foliage**: a vision-blocking `FOLIAGE` core with a softer `GRASS`
apron. The cover cuts both ways — you can stalk the pack for a sneak attack, but a fast pack can also rush you
from concealment — which is the intended counter-pressure. Self-limited to the D3–D7 band where packs spawn;
never reaches the late game.

**How (data-driven, reusable).**
- `Rogue.h` — `hordeType` gains a trailing `enum dungeonFeatureTypes spawnDF` field (a horde's "lair"
  dressing; `0`/absent = none). Positional catalog initializers leave it zero for every other row.
- `GlobalsBrogue.c` — the jackal-pack row sets `.spawnDF = DF_JACKAL_DEN_FOLIAGE`. The lone-jackal row does
  not — so the **data is the pack/solo discriminator**; no follower-counting heuristic.
- `Globals.c` / `Rogue.h` — two new dungeon features: `DF_JACKAL_DEN_FOLIAGE` (a tighter-than-open-field
  `FOLIAGE` core, `100/40`) chained via `subsequentDF` to `DF_JACKAL_DEN_GRASS` (a contained `GRASS` apron,
  `75/20`). The core+apron composition is pure catalog data, reusing the engine's existing `subsequentDF`
  chaining — no bespoke helper.
- `Monsters.c` — `spawnHorde`, after placing the horde, spawns `theHorde->spawnDF` at the leader's cell **only
  during level generation** (`!levels[rogue.depthLevel-1].visited`), so a pack that *wanders in* mid-game
  doesn't make grass appear in explored dungeon.

**Reusability.** Any future lair monster is a single catalog value (`spawnDF`), no new code. The unrelated
trap-anchored ideas (fire trap → dry grass, caustic trap → bones) would add an analogous field on the
trap/autogenerator side, not here.

**Determinism / saves.** The foliage spread runs on the substantive RNG (`spawnMapDF`'s `rand_percent`), so
it replays from the seed. The new `hordeType` field and DF rows are static catalog data, set deterministically
— save/replay-safe (saves are input replays). Shifts level generation for existing seeds (expected for new
content; SE is Game Center–silent). Marked `// iOS port (Brogue SE):`.

### 2026-06-23 — Noise system: coalesce a multi-cell machine's impact ripples into one (flare-delayed)

**Symptom.** Taking an item from a cage/commutation room ("the cages lower to cover the altars.") showed the
room flash but **no impact ripple** — even though the noise was emitted and nearby monsters were diverted.

**Root cause.** A cage room is a **wired machine**: removing the item runs `checkForMissingKeys` →
`promoteTile` → `activateMachine`, which promotes every linked altar **in shuffled order** (`Time.c`), each
calling `emitEnvironmentalNoise` → `cosmeticSpawnRippleImpact`. That ripple is a **latest-wins singleton**, so
the N per-altar spawns collapse to one survivor at a *random* altar (never the one you took from), and every
altar's simultaneous `GENERIC_FLASH_LIGHT` flare **washes the lone faint pulse out**. A sprung trap "worked"
only because it's a single emit at the player's own cell with one local flare. There was **never an earshot
gate** on environmental ripples — the spawn is unconditional — so this was a collapse/masking bug, not a gate.

**Fix (coalesce + de-mask).**
- `Monsters.c` — `beginCoalescedImpactRipples()` / `endCoalescedImpactRipples(origin)` bracket. While active,
  `emitEnvironmentalNoise` still wakes/diverts monsters per cell (substantive, untouched) but **suppresses the
  per-cell cosmetic ripple**, recording that one fired. `end…` emits **one** ripple at the activation origin.
  Extracted `impactRippleRadius(strength)` (shared by the investigate gate and the ripple).
- `Time.c` — `activateMachine` gains a `pos activationOrigin` param; it brackets only the **wired-promotion
  loop** (guardian-step ripples after it keep their per-step booms — the coalesced ripple is emitted *before*
  the guardian loop so a footfall naturally supersedes it). Callers (`Items.c` ×3 commutation/insight/transfer,
  `Time.c` ×1) pass the cell that powered the machine — i.e. **the altar you took the item from**.
- `IO.c` — impact ripples (`CE_RIPPLE_IMPACT`) render **brighter** (`NOISE_IMPACT_RIPPLE_STRENGTH = 82` vs the
  default 60) and **slower / longer-lived** (`CE_RIPPLE_IMPACT_EXPAND_FRAMES = 9` vs 5) than other ripple kinds,
  so the amber reads **through** a simultaneous tile flare. Per-kind in the render, so it doesn't touch the
  (dimmed) player ripple or re-brighten via the shared `NOISE_RIPPLE_MAX_STRENGTH` lever.

**Why brighter/slower and not a start-delay.** A first cut held the coalesced ripple ~0.2s to wait out the
flare's bright phase. That worked when stationary (item pickup) but **failed on walk-off**: the cosmetic
animator only ticks while the engine is parked in the input-idle loop (`SEBridge.mm` — `advanceCosmeticAnimations`
beside `shuffleTerrainColors`), so a step followed by another step gives the ripple only a few frames and the
delay ate the whole visible window — you saw a brief flash or nothing. The fix instead makes the ripple land
bright and linger, so it registers in the handful of idle frames you get between steps. No delay anywhere.

**Scope.** Coalesce fixes the whole class of multi-cell wired noise-machines (cage/commutation/insight/transfer
altars, `PORTCULLIS_CLOSED` vaults, future `DFF_EMITS_NOISE` machines); the brighter/slower render applies to
**all** impact ripples (traps, throws, machines) — a modest, intentional bump.

**Determinism / saves.** Cosmetic only — deterministic origin, fixed-constant delay, no RNG, nothing recorded;
zero save/replay impact. All edits marked `// iOS port (Brogue SE):`, machine brackets `#if NOISE_SYSTEM_ENABLED`.

### 2026-06-23 — Noise system: wake tells & player ripple survive multi-step travel / auto-explore

**What.** Multi-step travel (`travelMap`/`travelRoute` — the click/tap-to-path move) and auto-explore
(`explore`) run with `rogue.automationActive` set for the whole sequence. The cosmetic animator
(`advanceCosmeticAnimations`) only ticks in the bridge idle loop, so the **entire cosmetic layer is dormant
for the duration of an automated move** — every noise tell that would fire mid-sequence was dropped. You could
fast-travel/auto-explore past sleepers, wake them, and get **zero feedback**; only single-step (keyboard)
moves, which return to the idle loop after each step, showed tells. The tells are now re-emitted **once at the
automation-end seam** (the first moment the animator wakes):
- **Player footprint ripple** — recompute the step's loudness at the final cell and fire
  `recordPlayerNoiseRippleIfNeeded()` one time.
- **`?` investigate blinks** — rebuild from the *current* set of visible `MB_INVESTIGATING` monsters
  (state-driven, so a faithful snapshot, not a replay), so a still-searching creature shows its `?` the instant
  travel stops instead of one action later.
- **Event-edge `!` / off-screen `?`** — these fire at the *moment* a monster hears you, so there's no live
  state to rebuild from at the end. They're captured per-monster via a new flag `MB_HEARD_DURING_AUTOMATION`
  (`Fl(29)`) at the `checkPlayerHeard` edge sites, then drained once by `flushAutomationHeardTells()`,
  re-emitted **by current state**: visible + hunting → `!`, off-screen → `?` (visible + investigating is left
  to the `?` rebuild above). **One condensed haptic** for the whole sequence (the per-event haptics were
  suppressed; N buzzes would feel broken). The "Something nearby stirs" **message is deliberately NOT
  re-emitted** — it isn't gated by `automationActive`, so it already fired live (its `disturbed=true` also
  halts travel) and self-coalesces to "(×N)".

**Two latent bugs surfaced and fixed alongside:**
1. **`travelMap` left `automationActive` stuck `true` on its no-path early return** (the flag was set *before*
   the `distanceMap[player] < 0 || == 30000` guard, whose negative half can slip past `travel()`'s `< 30000`
   gate). Harmless upstream/CE (the flag only trims redraws there), but **SE gates the whole cosmetic layer on
   it**, so a stuck flag silently killed *all* noise/ripple/blink feedback until the next successful automation
   reset it. Fixed by setting the flag only **after** the guard.
2. **The player footprint ripple replayed late after combat.** The ripple is a single-turn footprint, but
   `recordPlayerNoiseRippleIfNeeded()` only ever *spawned* it — never retired it — so one spawned just before a
   burst of input (walk up to an unaware monster via travel, then hammer melee clicks) froze mid-expansion
   (animator starved by the input queue), outlived the fight, and finished animating seconds later — after the
   target was dead, looking like noise from nowhere. New `cosmeticClearPlayerRipple()` retires it on any turn
   that doesn't itself warrant one; called from `recordPlayerNoiseRippleIfNeeded`'s non-spawn paths (silent
   turn, opted-out, or "made noise but no visible unaware enemy in earshot"), which run every `playerTurnEnded`
   — so the kill turn itself clears the stale ripple.

**Why.** Closing the "fast movement hides the noise feedback" gap: the noise system's whole point is the
unseen-detection counter-pressure, and a player who travels everywhere never learned what they woke. The
end-of-seam re-emission is the *correct* hook, not a compromise — it's the first moment the cosmetic animator
runs again. (The simpler "animate per-step during travel" alternative was rejected: steps are 25–500 ms while a
ripple needs many frames, so it would strobe and slow travel.)

**Where (engine).**
- `Rogue.h` — `MB_HEARD_DURING_AUTOMATION = Fl(29)` (bits 0–28 were in use); prototypes for
  `flushAutomationHeardTells` and `cosmeticClearPlayerRipple`.
- `Movement.c` — `showTravelEndNoiseFeedback()` helper (ripple recompute + `?` rebuild + `flushAutomationHeardTells`)
  called at the end of `travelRoute`, `travelMap`, and `explore`; the `travelMap` stuck-flag hoist.
- `Monsters.c` — `flushAutomationHeardTells()`; `MB_HEARD_DURING_AUTOMATION` capture at the three
  `checkPlayerHeard` edge sites (gated on `automationActive` only, so AI autoplay/playback don't capture);
  `cosmeticClearPlayerRipple()` calls in `recordPlayerNoiseRippleIfNeeded`'s non-spawn paths.
- `IO.c` — `cosmeticClearPlayerRipple()` (deactivates the `CE_RIPPLE_PLAYER` singleton slot).
- `Time.c` — safety-net `flushAutomationHeardTells()` in `playerTurnEnded`, guarded to live turns
  (`!automationActive`) so a flag stranded by any uncovered automation path flushes on the next manual turn
  rather than never.

**Determinism / saves.** Cosmetic only — the capture flag is set deterministically from the substantive noise
processing, nothing is recorded, no RNG is drawn, and all spawns/haptics self-suppress for autoplay
(`autoPlayingLevel`) and playback fast-forward. Saves/replays and the seeded/weekly leaderboard are unaffected.
All edits marked `// iOS port (Brogue SE):` and gated by `#if NOISE_SYSTEM_ENABLED`. See
`docs/game-data/PERCEPTION_AUDIT.md` (the cosmetic-animator-dormant-during-automation note).

### 2026-06-22 — Noise system: the aggravate channel now ripples (alarm trap / aggravate scroll)

**What.** `aggravateMonsters` — the alarm trap (`DFF_AGGRAVATES_MONSTERS`) and the scroll of aggravate
monsters — was the one "sound" event with no visual tell: it woke the whole level but drew no ripple. It now
spawns a new, distinct **aggravate ripple**: a hot-red Chebyshev box (through walls, befitting a sound that
"echoes throughout the dungeon"), radius `NOISE_AGGRAVATE_RIPPLE_RADIUS = 16` — much larger than any other
ripple, so it reads as the loudest thing on screen — plus the pronounced haptic. Fires regardless of line of
sight (it's level-wide).

**Why.** Closing the last gap in "every sound generates an animation." Audit found all localized emitters
already ripple through `emitEnvironmentalNoise` → `cosmeticSpawnRippleImpact`; only the level-wide aggravate
channel was silent visually.

**Where.**
- `IO.c` — new `CE_RIPPLE_AGGRAVATE` cosmetic kind + `cosmeticAggravateColor` (hot alarm red) +
  `cosmeticSpawnRippleAggravate(source, radius)` (singleton, latest-wins). Render path groups it with the
  monster ripple's hollow-box branch (no sound-map dependency, so no collision with the impact ripple's
  shared `gImpactSoundMap`).
- `Rogue.h` — `NOISE_AGGRAVATE_RIPPLE_RADIUS` constant; `cosmeticSpawnRippleAggravate` declaration.
- `Items.c` — `aggravateMonsters` spawns the ripple + pronounced haptic at the source, after its existing
  flash/alert work, gated `#if NOISE_SYSTEM_ENABLED`. It deliberately does NOT route through
  `emitEnvironmentalNoise` (aggravateMonsters already did the far stronger level-wide wake itself); this only
  adds the cosmetic tell.

**Determinism / saves.** Cosmetic only (no RNG, no state); the spawn self-suppresses during
automation/fast-forward replay, the haptic during playback. Determinism/recordings unaffected.

### 2026-06-22 — Noise system: the vault portcullis seal + lever pulls now sound

**What.** Tagged two more vault-machinery DF rows with `DFF_EMITS_NOISE` (Globals.c):
- `PORTCULLIS_CLOSED` — a treasure/key vault sealing itself ("with a heavy mechanical sound, an iron
  portcullis falls from the ceiling!") now actually emits, so the seal is heard like the altar cages.
- `DF_PULL_LEVER` (`WALL_LEVER_PULLED`) — pulling a lever now clunks (heavy machinery), heard like the rest
  of the vault. Previously silent.

Both route through the shared `spawnDungeonFeature` emit path (`NOISE_ALTAR_GRIND` strength → ripple +
pronounced haptic + nearby monsters investigate).

**Why.** The altar cage lowering over the un-chosen items (`DF_ITEM_CAGE_CLOSE` / `ALTAR_CAGE_CLOSED`) was
already tagged (2026-06-21), but the portcullis seal and the lever pull — the other two mechanical events in
those rooms — were silent. Now operating any vault machinery is audible.

**Where.** `Globals.c` `PORTCULLIS_CLOSED` and `WALL_LEVER_PULLED` (DF_PULL_LEVER) rows (added
`DFF_EMITS_NOISE`); `Architect.c` comment on the `DFF_EMITS_NOISE` emit updated to list both. No new
constant — reuses the existing grind loudness. Determinism unchanged (no RNG; haptic self-suppresses in
playback).

### 2026-06-22 — Debug exploration-stats CSV (Lone Wolf / xpxp calibration)

**What.** A second debug calibration CSV, modeled exactly on the rest-stats CSV: at the end of each finished
live run, emit one row to `Documents/se/exploration-stats.csv` capturing, per dungeon level, the
**full-exploration xpxp ceiling** (count of passable, non-`T_PATHING_BLOCKER` cells — the exact gate
`discoverCell` uses to award xpxp) and the **xpxp the player actually accrued** there. Summary columns
include `levels_visited`, `passable_total`, `xpxp_earned_total`, and `passable_mean_per_level` — the figure
that calibrates `LONE_WOLF_XP_PER_TIER`. Per-level columns `p{d}` (ceiling) and `x{d}` (realized).

**Why.** We bumped the Lone Wolf cap to 5 tiers (1500 xpxp each) off an *estimated* ~750–900 floor cells per
level. This measures the real distribution across many seeds so the tier cost can be retuned against data
instead of a guess.

**Where (engine).**
- `Rogue.h` — two `levelData` fields: `passableCellsOnLevel`, `xpxpEarnedOnLevel`.
- `RogueMain.c` — zero both in the per-level reset loop (same stale-carry reason as the rest tallies); count
  passable cells once on a level's first visit (after the 50-turn environment break-in, so flooding/gas has
  settled); new `recordExplorationStatsRow()` built/emitted at the two run-end sites beside
  `recordRestStatsRow()`; `extern void seRecordExplorationStats(...)`.
- `Time.c` — accumulate realized xpxp per level in `handleXPXP` (before `xpxpThisTurn` is zeroed).
- **Indexing gotcha:** the debug tallies use `levels[depthLevel]` (1-indexed; depth d → `levels[d]`), the
  same convention as `restTurnsOnLevel` — NOT the 0-indexed `levels[depthLevel-1]` used by map storage and
  the `visited` flag. The CSV reader uses `passableCellsOnLevel > 0` as the "explored this depth" test to
  stay on the 1-indexed side and avoid crossing into the 0-indexed `visited`.

**Where (host).** `SEBridge.mm` — refactored the rest-stats writer into a shared `seAppendCsvRow(fileName,
header, row)`; `seRecordRestStats` and the new `seRecordExplorationStats` are thin wrappers. Both gated to
Debug builds (`SE_DEBUG_BUILD`) — in Release they are no-ops, so **nothing is collected on shipping builds**.

**Determinism / saves.** Output-only: no RNG, no game-state mutation. The per-level counting is deterministic
(replays identically); skipped during playback. Pull the file via Xcode > Devices & Simulators > Download
Container → `AppData/Documents/se/exploration-stats.csv`.

### 2026-06-22 — Lone Wolf scales to 5 tiers (was 2)

**What.** Raised the Lone Wolf solo-progression cap from 2 tiers to 5. Each tier still costs the same solo
exploration XPXP (`LONE_WOLF_XP_PER_TIER = 1500`, so tier N at N×1500; tier 5 at 7500 ≈ ten levels of solo
exploration) and grants +1 effective strength, so the aura now tops out at **+5** instead of +2.

**Why.** Solo play (no allies) is much harder than running with a pack; Lone Wolf is the compensation, and
+2 wasn't enough at depth. The counter-pressure stays intact (design principle #3): the bonus accrues only
while you have *zero* living allies anywhere, so it's a genuine trade — forgo allies (very strong) for raw
strength — not a free upgrade.

**Where (engine).**
- `Rogue.h` — replaced the per-tier `LONE_WOLF_TIER1_XP`/`LONE_WOLF_TIER2_XP` defines with a single
  `LONE_WOLF_XP_PER_TIER`; `LONE_WOLF_MAX_TIER` 2 → 5. Updated the `playerCharacter` field comment.
- `Time.c` — `handleLoneWolf()` now derives the tier as `loneWolfXP / LONE_WOLF_XP_PER_TIER` (clamped to the
  cap) instead of hard-coded tier-1/tier-2 thresholds, and pulls the tier-up flavor line from a small
  `loneWolfTierMessages[]` table (I–V). Strength still set via `setLoneWolfStrengthBonus(tier)`.

**Determinism / saves.** Unchanged from the original feature: the tier is recomputed from `loneWolfXP` every
turn (which itself comes only from deterministic exploration counts), so it replays/reloads identically.
Gaining any ally still zeroes the *entire* track and strips the aura (`loseLoneWolfBonusOnAlly`, fired from
`becomeAllyWith`); re-grindable from zero once that ally dies. **Design note:** that full all-or-nothing
reset — now wiping up to +5 earned over a long solo grind on a single ally pickup — is flagged as a possible
balance flaw to revisit (see `KNOWN_CAVEATS.md`). All edits marked `// iOS port (Brogue SE):`.

### 2026-06-22 — Noise system: stone guardians boom when a glyph steps them

**What.** Each guardian that actually changes cells on a glyph activation now emits a loud environmental
noise (`NOISE_GUARDIAN_STEP = 20`, radius ~7) from the cell it lands on, plus a pronounced iPhone haptic.
The guardian-puzzle key room (guide the totems onto the trap to free the key) is now an audible event that
draws nearby wanderers toward the commotion.

**Why.** Shoving massive stone totems around to solve the puzzle should be heard — a design-principle-#3
counter-pressure: the reward room becomes tenser (you may attract company), not free. It reuses the existing
`emitEnvironmentalNoise` channel, so it also paints the standard impact ripple (a "boom" animation) and the
guaranteed-investigate behavior, consistent with traps/altars.

**Where (engine).**
- `Rogue.h` — new `NOISE_GUARDIAN_STEP` constant (louder than `NOISE_ALTAR_GRIND`, since it's a booming
  footfall; still under the whole-floor `MAX_RADIUS`).
- `Time.c` — `activateMachine()` snapshots each activation-monster's `loc` before its `monstersTurn`, and on
  any real move emits `emitEnvironmentalNoise(landingCell, NOISE_GUARDIAN_STEP, NULL)` + `environmentalNoiseHaptic(1)`.
  No per-kind branch: `MONST_IMMOBILE` mirror totems never move, so only stone/winged guardians boom; the
  climactic fatal step onto a trap still booms (the dying guardian isn't freed until `removeDeadMonsters`, so
  its `loc` is valid).

**Determinism / saves.** `emitEnvironmentalNoise` draws no RNG (guaranteed-investigate radius), and guardian
activation is player-driven (stepping on a wired glyph), so replays are unaffected. The haptic self-suppresses
during playback/automation. All edits marked `// iOS port (Brogue SE):` and gated by `#if NOISE_SYSTEM_ENABLED`.

### 2026-06-22 — Noise system: menu toggle for the player's own sound ripple; drop the sound-map debug overlay

**What.** Two paired menu changes in the in-game `\`-menu (under "Display stealth range"):
- **Added** a "Player sound animation" toggle (`[X]` = on, **on by default**) that suppresses *only* the
  player's own sound-footprint ripple. Every other noise animation — monster ripples, thrown-impact / trap /
  altar ripples, the `?` investigate and `!` alert blinks — is unaffected.
- **Removed** the developer "Display sound map" heat-overlay option entirely (button, key handler, the
  per-cell render block in `IO.c`, the `displaySoundMapMode` field, and its playback save/restore).

**Why.** The footprint ripple began as a feel/test aid but reads as noisy clutter to some players, so it
now has an off switch while staying on by default. The sound-map overlay was a pure debug visualizer with no
player value, so its menu entry was dropped rather than left permanently unreachable.

**Where (engine).**
- `Rogue.h` — `SOUND_MAP_KEY` renamed to `PLAYER_NOISE_ANIM_KEY` (still `'['`, the freed key); new
  `rogue.hidePlayerNoiseRipple` field (replaces `displaySoundMapMode`; `0` = shown, so zero-init = on);
  dropped the `SOUND_MAP_KEY` mention in the noise-falloff comment.
- `IO.c` — menu button + `case` reworked to the new toggle (no `displayLevel()` repaint needed — the ripple
  is an event animation, not a persistent overlay); deleted the `displaySoundMapMode` render overlay.
- `Monsters.c` — `recordPlayerNoiseRippleIfNeeded()` early-returns when `hidePlayerNoiseRipple` is set.
- `RogueMain.c` — `initializeRogue()` carries `hidePlayerNoiseRipple` across the struct memset, so the
  choice is sticky within the app session (matching `trueColorMode` / `displayStealthRangeMode`).
- `Recordings.c` — `resetPlayback()` preserves `hidePlayerNoiseRipple` instead of the removed `soundMap`.

**Determinism / saves.** Purely cosmetic display preference; non-recorded (carried, not serialized). No RNG,
no replay impact. All edits marked `// iOS port (Brogue SE):` and gated by `#if NOISE_SYSTEM_ENABLED`.

### 2026-06-21 — Noise system: traps click and altars grind (two new environmental emitters + iPhone haptics)

**What.** Two new world-event sounds on the existing `emitEnvironmentalNoise` channel (guaranteed-investigate
radius, no hear roll), each with an iPhone haptic:
- **Trap click** — a sprung pressure plate emits a soft noise (`NOISE_TRAP_CLICK = 6`, radius ~3) so nearby
  unaware enemies investigate the trap tile. The **alarm trap is skipped** (its `fireType` is
  `DF_AGGRAVATE_TRAP`, which already broadcasts a level-wide aggravate — a soft local click on top is
  redundant). A **gentle** haptic fires only when the **player** personally springs the trap.
- **Altar grind** — reward-room machinery sealing shut emits a louder noise (`NOISE_ALTAR_GRIND = 15`,
  radius ~5), drawing wanderers toward the altar. A **pronounced** haptic (heavy thud + a short second tap)
  fires on every grind.

**Why.** Principle #3 counter-pressure: setting off a trap or triggering an altar now *costs* you by pulling
nearby monsters to the spot, rather than being silent/free. Reuses the existing primitive (principle #2)
rather than bespoke code. The trap click is deliberately quieter than a thrown dart so it can't become a free
monster-luring tool. The haptics are a distinct channel from the detection haptic ("something heard *you*").

**Where (engine).**
- `Rogue.h` — new levers `NOISE_TRAP_CLICK` / `NOISE_ALTAR_GRIND` (in the `NOISE_*` block); new
  `DFF_EMITS_NOISE = Fl(11)` dungeon-feature flag; declaration of `environmentalNoiseHaptic()`.
- `Time.c` (`handleCreatureTerrainInteraction`, pressure-plate block) — emits `NOISE_TRAP_CLICK` for all
  traps except the alarm trap (detected by `fireType == DF_AGGRAVATE_TRAP` *before* the promotion loop
  mutates the tile); gentle haptic gated to `monst == &player`.
- `Architect.c` (`spawnDungeonFeature`, `if (succeeded)` block) — mirrors the `DFF_AGGRAVATES_MONSTERS`
  handler: when a DF has `DFF_EMITS_NOISE`, emit `NOISE_ALTAR_GRIND` at the origin + the pronounced haptic.
- `Globals.c` (`dungeonFeatureCatalog`) — tagged the 7 close-and-seal DF rows with `DFF_EMITS_NOISE`:
  `DF_ITEM_CAGE_CLOSE`, `DF_ALTAR_RETRACT`, `DF_ALTAR_COMMUTE`, `DF_ALTAR_RESURRECT`, `DF_SACRIFICE_COMPLETE`,
  and SE's `DF_ALTAR_INSIGHT_INERT` / `DF_ALTAR_TRANSFER_INERT`.
- `Monsters.c` — `environmentalNoiseHaptic()` wrapper (extern `cePlayEnvironmentalNoiseHaptic`), same
  playback/automation suppression as `noiseDetectionHaptic`. All marked `// iOS port (Brogue SE):` and gated
  by `#if NOISE_SYSTEM_ENABLED` (matching `emitEnvironmentalNoise`'s own guard).

**Where (bridge/platform).** New host hook `cePlayEnvironmentalNoiseHaptic(int kind)` in `SEBridge.mm` →
`playEnvironmentalNoiseHaptic:` on `BrogueCEHost` (`BrogueCE/BrogueCEHost.h`, SE-only, like the detection
haptic) → `CEHost.swift` → `environmentalNoiseHaptic(_:)` in `BrogueViewController.swift` (dedicated
`.light`/`.heavy` generators + `Haptics` constants; iPhone-only; respects the haptics setting; warmed in
`prepareDamageHaptics`).

**Determinism.** `emitEnvironmentalNoise` draws no RNG (a deterministic radius gate sets `MB_INVESTIGATING`);
the haptics/ripples are cosmetic and self-suppress during playback/automation. Saves/replays unaffected. See
`docs/game-data/PERCEPTION_AUDIT.md` §7.

### 2026-06-21 — Noise system: per-weapon melee loudness (replaces the flat melee spike)

**What.** Player melee noise was a single flat spike (`NOISE_PLAYER_MELEE` = 30, always aggro-tier).
It is now a **per-weapon tier** returned by a new `weaponMeleeLoudness(weapon, connected)` lookup
(`Combat.c`, a `switch (weapon->kind)` mirroring the existing thrown-item `itemImpactLoudness()`):

| Tier | Spike | Weapons |
|---|---|---|
| `NOISE_MELEE_LIGHT` | 12 | dagger, rapier, whip, **unarmed** (`weapon == NULL`) |
| `NOISE_MELEE_NORMAL` | 22 | sword, axe, spear |
| `NOISE_MELEE_HEAVY` | 32 | broadsword, flail, mace, war axe, war pike |
| `NOISE_MELEE_BOOMING` | 45 | war hammer |

Only **LIGHT (12)** sits below the aggro threshold (`NOISE_HEAR_AGGRO_LOUDNESS` = 20), so a clean
LIGHT-weapon hit reaches unseen *bystanders* only as a *faint* "investigate" ping, not full aggro —
the dagger/rapier/whip/unarmed become a genuine stealth-kill tool. A **miss** adds
`NOISE_MELEE_MISS_PENALTY` (+10), so a LIGHT whiff (22) crosses back to aggro — *accuracy = stealth*,
the same philosophy as `itemImpactLoudness`'s BODY-vs-WALL surface tiers. Auto-hits
(sneak/asleep/paralyzed/lunge) count as connected → stay quiet, rewarding the assassin path; this is the
design-principle-3 counter-pressure on the quiet-dagger build. Noise is a pure function of weapon
**kind** (enchant/runic irrelevant). The base loudness (`playerNoiseLevel()`: armor clatter, terrain,
levitation, ring of stealth) still rides underneath, so heavy armor can push even a LIGHT weapon over the
aggro line on a hit (*you can't stealth-dagger in plate* — intended).

**Where.** `Rogue.h` — removed `NOISE_PLAYER_MELEE`; added `NOISE_MELEE_LIGHT/NORMAL/HEAVY/BOOMING` +
`NOISE_MELEE_MISS_PENALTY` (the five tuning levers). `Combat.c` — new `weaponMeleeLoudness()`; in
`attack()` the `playerEmitNoise(...)` call **moved from the top of the function to just after the
hit/miss roll** (so it can branch on connect vs. whiff) and the roll is captured once into `attackLanded`
to avoid double-rolling `attackHit()`. `Monsters.c` — comment on `playerEmitNoise` updated.

**Determinism.** Pure function of weapon kind + the pre-existing substantive `attackHit` roll — no new
RNG, save/replay-safe. SE-only gameplay; gated by `NOISE_SYSTEM_ENABLED`. Marked in-code with
`// iOS port (Brogue SE):`. Docs: `PERCEPTION_AUDIT.md` §3.2.1/§3.2.3/§7, `ITEMS_AUDIT.md` §1 (Noise
column), `docs/design/noise-system.md` Phase 2.

### 2026-06-21 — Re-apply last staff (`A` in the Modern scheme; apply-side mirror of rethrow)

**What.** A new command re-applies the **last staff zapped** — the apply-side mirror of `T`
rethrow. It is bound to a dedicated canonical key `REAPPLY_KEY` (`128+20`, private range beside
`UNKNOWN_KEY`). Under the **Modern** keyboard scheme, physical `A` remaps to it (displacing
autopilot, which becomes keyless in Modern); under **Classic**, `A` stays `AUTOPLAY_KEY`. It also
appears as a bindable iOS shortcut button ("Re-apply staff", SE-only). It tracks **staves only**
(never wands/charms) and **never auto-targets** — it routes through `apply()` → `useStaffOrWand()`,
which always shows the interactive "Direction?" aim prompt, so target choice stays the player's.

**Why.** Re-zapping a staff every turn in a fight is a common rhythm (staves recharge), and the only
prior `A` binding — autopilot — is low-value on a touch device. Wands are excluded by design (finite
charges, no recharge: a re-zap hotkey would just burn a scarce resource). A *dedicated* key rather
than reusing `'A'` keeps the iOS button scheme-independent (the button sends `REAPPLY_KEY` raw,
bypassing `applyKeyboardScheme`, so it means re-apply in every scheme) and keeps recordings
scheme-independent (the canonical `REAPPLY_KEY` is recorded, never `'A'` — see
`docs/design/keyboard-schemes.md`).

**Edge cases (mirroring rethrow).** If the remembered staff was never set, was dropped, or was
stolen (`!itemIsCarried`), `A` falls through to the normal `apply(NULL)` prompt instead of no-opping.
An empty-but-carried remembered staff is left to `useStaffOrWand()`'s existing "no charges" message.

**Determinism.** `rogue.lastStaffZapped` is set inside `useStaffOrWand()` on the confirmed-zap path
(`STAFF`-guarded, so zapping a wand never overwrites it), including a fizzle (an unidentified 0-charge
staff still reaches that point). It is set on the same input path every replay, so saves/recordings
stay in sync.

**Where.**
- `Rogue.h` — `REAPPLY_KEY` `#define`; `item *lastStaffZapped` on the `rogue` struct.
- `Items.c` — `useStaffOrWand()` records `rogue.lastStaffZapped` after `confirmedTarget`.
- `IO.c` — `applyKeyboardScheme()` Modern maps `A → REAPPLY_KEY`; `executeKeystroke()` gains a
  `REAPPLY_KEY` case; `actionMenu()` shows a "Re-apply staff" entry (`REAPPLY_KEY`) only under Modern;
  `printHelpScreen()`'s `modernHelp` `A` line now reads re-apply.
  *(Amended 2026-06-24:* only the *keystroke* was removed under Modern — **Autopilot stays a menu
  option in both schemes.** `actionMenu()` always emits an Autopilot button with
  `hotkey[0] = AUTOPLAY_KEY`; it advertises the `A:` label only under Classic, and is keyless but
  still tap-selectable under Modern, exactly like the keyless Quit button. Physical `A` is remapped to
  `REAPPLY_KEY` before menu key-matching, so the Re-apply and Autopilot entries never collide.)*
- `iBrogue_iPad/PlatformCode/BrogueViewController.swift` — `Command.seOnly` flag + filter; catalog
  entry + `wand.and.rays` symbol for the re-apply key.

### 2026-06-21 — Ring of wisdom speeds up auto-identification of worn armor & rings

**What.** A worn **ring of wisdom** now makes worn **armor** and **rings** auto-identify-by-use faster — ~10%
faster per net enchant level, capped at +50% (2× speed). A *cursed* wisdom ring slows it instead, down to
−100% (2× slower), mirroring how cursed wisdom already slows rest-insight and staff recharge. **Weapons are
out of scope** (their auto-ID is the per-kill timer, left at vanilla 20 kills).

**Why.** Ring of wisdom is the staff/identification amplifier ring; speeding gear familiarization is a natural
extension of its "arcane insight" identity and pairs with the existing wisdom levers (rest-insight threshold,
detect-magic count, staff recharge). The cap keeps a deep ring from making ID instant.

**Mechanism (banked accelerated countdown — the threshold is never lowered).** The base requirement is
unchanged: `item->charges` still seeds from `gameConst->armorDelayToAutoID` (1000) / `ringDelayToAutoID`
(1500) and auto-IDs at `≤ 0`. Only the per-turn decrement changes. In `processIncrementalAutoID()` the worn
armor/ring countdown subtracts `wisdomAutoIDChargeStep()` instead of a flat 1. That step is a **Bresenham tick
on the turn clock** (`rogue.absoluteTurnNumber`): it averages exactly `100/(100 − reductionPct)` charges per
turn but only ever subtracts an integer **0, 1, or 2** — so no fractional charges, **no new save field**, and
the consumed familiarity is permanent (banked: removing the ring just reverts the step to 1). The progress
bar (`charges/threshold`) and generation are untouched.

**Display.** The inventory inspector's "reveal its secrets if worn for N turns" line shows the
wisdom-adjusted estimate (`ceil(charges × (100 − reductionPct)/100)`) for armor and rings, so the countdown
stays honest now that it isn't a flat 1/turn. The weapon "defeat N enemies" line is unchanged.

**Where.** `Items.c` — `wisdomAutoIDReductionPct()` / `wisdomAutoIDChargeStep()` / `wisdomAutoIDDisplayTurns()`
(near `effectiveRingEnchant`), plus the two inspector blocks (armor + ring). `Time.c` —
`processIncrementalAutoID()` decrement. `Rogue.h` — `wisdomAutoIDChargeStep` prototype. Lever constants
`WISDOM_AUTOID_PCT_PER_LEVEL` (10) / `WISDOM_AUTOID_MAX_FASTER_PCT` (50) / `WISDOM_AUTOID_MAX_SLOWER_PCT`
(100) are tunable. A worn-but-unidentified wisdom ring already contributes a partial `wisdomBonus`
(`effectiveRingEnchant`), so it speeds its own/other gear's ID before you know it's wisdom — consistent with
how every ring effect applies pre-ID; not special-cased.

**Determinism / saves.** Step derives only from `rogue.absoluteTurnNumber` + `rogue.wisdomBonus` + `charges`,
all already deterministic/replayed; no struct changes. Reconstructs identically on replay; diverges replays
from pre-change recordings like any gameplay change. SE-only.

**Ring descriptions refreshed (`Globals.c` `ringTable`).** Both rings' inspect text had drifted from their SE
behavior, so it was rewritten to match:
- **Wisdom** previously named only staff recharge. It now also describes the SE effects it gained: faster
  auto-ID of worn armor & rings (this change), faster polarity insight while resting, and a deeper potion of
  detect magic — all scaling with the ring, all dulled by a cursed one.
- **Awareness** already covered search (traps/secret doors/levers), the "chamber of significance" sense, and
  the floor item-aura radar, but omitted its role in the noise/perception system. Added a clause: it sharpens
  your hearing of unseen creatures' movements (extends earshot, scaling with enchant; cursed dulls it).

### 2026-06-21 — Thrown scrolls are the quietest throw (paper impact tier)

**What.** A thrown scroll now lands much more quietly than other light items. It was lumped into
`NOISE_IMPACT_LIGHT` (4 — shared with darts, incendiary darts, food), giving a ~3-tile audible impact radius
on hard floor. It now has its own `NOISE_IMPACT_PAPER` tier (0), so a scroll's landing draws a ~2-tile radius
on stone and clamps to 1 on soft ground / carpet (effectively silent).

**Why.** A sheet of parchment fluttering to the floor shouldn't clatter like a hurled dart. As a distraction
tool a scroll is now a poor lure (it barely carries) — appropriate, and no downside since scrolls aren't
thrown for effect. Scoped to scrolls only; food / wands / charms / rings stay at `NOISE_IMPACT_LIGHT`.

**Where.** `Rogue.h` — new `NOISE_IMPACT_PAPER` define. `Items.c` — `itemImpactLoudness()` gains a
`category & SCROLL` branch returning it (ahead of the catch-all `NOISE_IMPACT_LIGHT`). The tier feeds the
existing radius formula, so the change flows uniformly to the aim-time noise-preview wash, the impact sound
map (what monsters hear), and the cosmetic impact ripple. `docs/design/environmental-sounds.md` item-loudness
table updated.

**Determinism / saves.** Pure tunable constant + a category test; no RNG, no new fields. Diverges replays
from pre-change recordings like any gameplay change. SE-only; gated by `NOISE_SYSTEM_ENABLED`.

### 2026-06-21 — Ring of light: emboldened allies hold a standoff behind you (out of spear reach)

**What.** Refines the ring-of-light ally behavior (see the 2026-06-12 cornerstone entry). While a ring of
light is worn (`STATUS_EMBOLDENED` + a positive `rogue.lightRingBonus`), an emboldened ally now keeps a
**standoff position ~2 tiles behind the player** instead of tucking directly behind you, in two situations:
- *Retreating* — the low-HP rally cell (formerly `allyRallyShieldCell`, the tile **directly** behind you).
- *Backline* — at full HP, when **you** are the one in melee (an enemy adjacent to you) and the ally can't
  land a blow this turn, it holds the standoff rather than pressing up into the front rank. It still charges
  in whenever it can actually reach an enemy, so it isn't a passive turret. **Scoped to fragile skirmishers**
  (`allyHoldsBackline()` — currently monkey + common goblin); bruiser/tank allies (ogre, troll, golem, goblin
  chieftain, …) keep the vanilla engage-anything behavior so they venture ahead and soak hits.

**Why.** The old "tuck **directly** behind the player as a body-shield" cell sat squarely in a spear's line:
a `MA_ATTACKS_PENETRATE` enemy ("attacks up to two opponents in a line") adjacent to the player also hits the
cell directly behind, so the ally tucked there got skewered through the player — especially in 1-wide
corridors where it can't flank and just stacks up behind you. Holding ≥ 2 tiles back puts the ally beyond the
spear's two-tile reach (≥ 3 from an adjacent attacker) while still inside the light aura, so it keeps the
embolden + regen. Gives the ring a clean **frontline-player / backline-ally** identity. Scoped entirely to the
ring: with no positive `lightRingBonus`, allies behave exactly as before.

**Where.** `Monsters.c` — `allyRallyShieldCell()` generalized/renamed to `allyStandoffCell()`: it now scans
a tight band `ALLY_STANDOFF_MIN_DIST`(2)..`ALLY_STANDOFF_MAX_DIST`(3) tiles around the player, rejects cells
within a spear's reach of the threat (`distanceBetween(c, threat) < 3`), and scores nearest-standoff-first
then far-side-from-threat (which resolves to directly behind you). Used by the existing retreat path in
`moveAlly()` and by a new ring-gated backline block (after the spellcast check, before the leash/engagement
logic). Both reachability checks fall through to prior behavior if no standoff tile is reachable.

**Determinism / saves.** `allyStandoffCell()` is pure state-derived (fixed scan order, strict-better tiebreak,
no RNG) and moves via the existing deterministic `moveMonsterPassivelyTowards`; no new persistent fields.
Reconstructs identically on replay; diverges replays from pre-change recordings like any gameplay change.
SE-only. `ALLY_STANDOFF_*` distances are tunable.

### 2026-06-21 — Off-screen combat emits a sound ripple from the monster

**What.** When two creatures fight outside the player's view (the "you hear combat in the distance" /
"you hear something die in combat" messages), the fight now also paints a cosmetic grey sound ripple — the
same "you heard something" box-ripple the noise system already uses — so the player can *locate* the
distant combat, not just read about it. The ripple radiates from the **monster**, not the ally/player who
landed the blow: the listener's own side isn't what we're trying to point at; the enemy is.

**Why.** The text alone gives no direction. The ripple is the existing visual vocabulary for "a sound came
from over there," so reusing it for combat noise is consistent with the rest of the perception system. It
fires on **every** off-screen exchange — hit, miss, *or* kill — rather than the once-per-turn cadence of the
message itself (`rogue.heardCombatThisTurn`); a flurry of swings should keep pinging.

**Companion text fix (upstream dead code).** While here we also repaired the off-screen **non-fatal hit**,
which upstream renders silently in *all three* engines (CE + Classic too). In the defender-survived branch,
the "you hear combat in the distance" line sat inside an outer `(canSeeMonster(attacker) ||
canSeeMonster(defender))` guard — the exact logical negation of `sightUnseen` — so its `if (sightUnseen)`
sub-branch was unreachable: an out-of-sight blow that *landed but didn't kill* produced no message at all
(only misses and kills were audible). The miss and kill sites branch on `sightUnseen` directly and were
always correct; the survive site now matches them. **SE-only** — left unfixed in faithful CE/Classic; a
candidate to push upstream separately.

**Where.** `Combat.c`, in `attack()`:
- *Ripple* — just before the hit/miss resolution (`attackHit`) and after the seize/levitate early-returns, a
  single `if (sightUnseen)` block spawns `cosmeticSpawnRippleMonster()` from
  `(attacker == &player || attacker->creatureState == MONSTER_ALLY) ? defender->loc : attacker->loc`. Placed
  ahead of the branch so it covers hit, miss, and kill uniformly and is independent of the message throttle.
- *Text fix* — the defender-survived branch was restructured to test `!rogue.blockCombatText` then
  `sightUnseen` first (emit the distance tell), `else if (canSeeMonster(...))` for the visible verb message,
  dropping the redundant outer visibility guard.

`sightUnseen` already excludes any attack involving the player (the player is always "visible" to
themselves), so both only apply to monster-vs-monster / monster-vs-ally combat. Marked
`// iOS port (Brogue SE):`. See `docs/design/noise-system.md`.

**Determinism.** `cosmeticSpawnRippleMonster` is purely cosmetic (no substantive RNG) and self-suppresses
during automation / autoplay / playback fast-forward. Saves/replays are unaffected.

### 2026-06-21 — Cosmetic noise layer not reset between games (stale '?' / ripple carry-over)

**What.** The cosmetic-effect layer (`gCosmeticEffects[]` pool, the dirty-cell ping-pong buffers, the
`gCosmeticBlinkTick` phase clock, and `gCosmeticCur`) is process-static in `IO.c`, not part of the `rogue`
struct. Nothing was clearing it when a run ended, so a *new game or a loaded game started in the same app
session inherited the previous run's cosmetic state*: an in-flight `'?'` alert glyph or a persistent
`CE_INVESTIGATE_BLINK` (keyed to a now-freed monster pointer that a fresh monster can reuse) would surface
for no in-game reason, and the never-reset `gCosmeticBlinkTick` made the `'?'` blink resume mid-phase on
reload. Symptom got worse the more new games you started in one session, as stale slots accumulated.

**Fix.** `clearCosmeticAnimations()` (which already existed but was *never called*) now also zeroes
`gCosmeticCur` and `gCosmeticBlinkTick`, and `initializeRogue()` calls it. `initializeRogue()` is the single
chokepoint both the new-game (`MainMenu.c`) and load-game (`Recordings.c`) paths run through, and it runs
before any level is built, so every run now starts with an empty cosmetic layer. The `memset` of `rogue`
in `initializeRogue` never touched these buffers because they live outside the struct.

**Where.** `IO.c` — `clearCosmeticAnimations()` resets the phase clock + ping-pong index in addition to the
effect pool. `RogueMain.c` — `initializeRogue()` calls `clearCosmeticAnimations()` alongside the other
SE per-run resets. Marked `// iOS port (Brogue SE):`.

**Determinism.** The cosmetic layer carries no substantive RNG and is not saved/replayed, so this is a
pure display-correctness fix; saves and the seeded/weekly leaderboard are unaffected.

**Follow-up if a stray `'?'` still appears (within a single game).** This reset closes the *cross-game*
carry-over. A second, narrower vector remains theoretically open: `cosmeticRefreshInvestigateBlinks()`
binds each `CE_INVESTIGATE_BLINK` to its monster by raw pointer (`(const void *)m == e->channel`). If a
monster dies and the allocator hands its address to a *new* monster mid-run, a stale blink could re-bind to
the wrong creature. The clean hardening is identity, not address: stamp each blink with the monster's
`monsterID` (or `bookkeepingFlags`/spawn serial) and match on that, and/or expire any blink whose monster
is no longer on `monsters`/`dormantMonsters`. Only do this if the symptom recurs *within one game* — the
cross-game path (the actual report) is already fixed above.

### 2026-06-18 — Darts removed as a potion-identification channel

**What.** A thrown dart or javelin landing on a dropped potion **no longer detonates it** — it simply drops
and is recoverable, like any thrown weapon. Only **bolts** (fire/lightning staffs & wands) and **incendiary
darts** still detonate floor potions. This removes plain darts/javelins from the identification channels.

**Why (the trial and the kill).** We first trialled a *costed* dart probe — the dart detonates a bad potion
(auto-ID, lightning style), is inert against a benevolent one, and is **consumed against the flask** rather
than recovered — on the theory that the per-probe cost would self-balance against dart scarcity. Playtest
refuted it: scarcity is a property of the *run's RNG*, not of darts. A single early drop (the motivating
case: a staff for combat **plus a stack of 8 javelins** as pure surplus on depth 1) drops the cost to zero
and lets the player map the **entire potion pool's polarity for free** — exactly the free-mass-ID the costed
bolt probe exists to prevent. The bolt avoids this because staff charges are a genuinely limited,
slow-recharging resource; a quiver has no such ceiling, and consuming the dart doesn't help because the
*pile* is the problem, not the recovery. No fiddly per-game/charge cap was judged worth the complexity.

**Where.** `Items.c` — the dart-as-ID channel is gated behind a single file-scope flag
`dartsProbeAndConsumeOnPotions` (just above `throwItem`), now `false`. When false, the `DART | JAVELIN`
branch in `throwItem` short-circuits and the weapon falls through to the normal drop. Flip back to `true` to
restore the consumed-dart probe (the implementation is retained behind the flag). Marked
`// iOS port (Brogue SE):`. Caveat updated in `KNOWN_CAVEATS.md`.

**Determinism.** No RNG involved; saves/replays unaffected beyond the usual gameplay-change divergence from
pre-change recordings.

### 2026-06-18 — Rest & eat-a-meal insight: prioritize still-hidden polarities

**What.** Extended the detect-magic "prioritize still-hidden polarities" behavior (see the 2026-06-17
entry) to the two passive insight channels — **resting** and **eating a meal**. Both pick a random
eligible pack item through the shared `applyPolarityInsightToRandomItem`, whose pool deliberately includes
already-sensed items (so insight can escalate them to full IDs). That pool is now stable-partitioned so an
item whose good/bad aura is **still hidden** is always chosen first; an already-sensed item is only escalated
to a full ID once nothing new remains to reveal. Matches the drink/throw of detect magic.

**Where.** `Items.c` — the polarity-known predicate (formerly `detectMagicPolarityAlreadyKnown`) is renamed
`polarityAlreadySensed` and hoisted next to `revealOrIdentifyPolarityItem`, since it is now shared by all
three reveal-or-escalate channels (detect magic, rest, eat). `applyPolarityInsightToRandomItem` gained the
same partition-then-pick used by `quaffDetectMagic`. Marked `// iOS port (Brogue SE):`.

**Determinism.** Still a single substantive `rand_range` draw at the action point (the partition is a pure
reordering, no extra RNG), so saves/replays stay valid; like any gameplay change it diverges replays from
pre-change recordings.

### 2026-06-17 — Altar of insight: refuse ineligible items on the INSIGHT slot at drop time

**What.** The INSIGHT (item-to-reveal) slot of an altar of insight now refuses, *at drop time*, items
that have no hidden good/bad nature to divine:
1. **Throwing weapons** — darts, javelins, incendiary darts — are refused by kind, regardless of any
   runic (the altar isn't meant to be spent on a quiver).
2. **Items already settled as neutral** — a category that can never carry a good/bad aura (food, gold,
   keys, gems), or a *detectable* item already known to be neutral (fully identified, or magic-detected
   and revealed auraless).

The refusal is **leak-free**: an *unidentified* item whose polarity is still hidden is never refused, so
dropping can't become a free "it's neutral" tell (consistent with the run's other no-ID-side-channel
guards — potions/scrolls are never neutral, so they're unaffected). The **payment/offering twin slot is
unrestricted** — you may still sacrifice anything there. Scope decision (per request): the guard applies to
the **insight slot only**.

**Where.** `Items.c` — new static helper `insightSlotRejectsItem()` (just above `drop()`), and an
early-return guard in `drop()` that fires when the player stands on an `INSIGHT_ALTAR_INSIGHT` tile and the
chosen item is ineligible. Pure UI rejection: no keystroke recorded, no turn spent (mirrors the
cursed-equipped guard), with the message "the altar of insight finds no hidden nature to divine in your …".
Marked `// iOS port (Brogue SE):`.

**Determinism.** RNG-free; the guard only blocks an action before it happens (no state mutation, no
recorded keystroke), so saves/replays are unaffected.

**Not covered (by design / scope).** Only the drop command is guarded; an item *thrown* onto the insight
tile is an unguarded edge case (the vanilla commutation altar is likewise drop-only). The existing
"fire only if it helps" no-op in `performInsightSacrifice` still covers anything that slips past.

### 2026-06-17 — Remove the death-screen rest readout; gate the rest-stats CSV to Debug builds

**What.** Two cleanups to the rest-insight calibration instrumentation:
1. **Removed the on-screen rest tally on the death screen.** `gameOver()` (`RogueMain.c`) appended a
   personal debug readout (`[rest turns/IDs per lvl: …]`) to the recap line. It never touched the saved
   high-score record, but it was developer-only clutter — deleted.
2. **Gated the rest-stats CSV to Debug builds.** The `Documents/se/rest-stats.csv` append
   (`seRecordRestStats` in `SEBridge.mm`) was only guarded against playback, so once SE went to Release
   (the old `SE_ENABLED` Debug gate is gone) it would have collected on shipping devices. The host write
   is now wrapped in `#if SE_DEBUG_BUILD` (a no-op in Release). The CSV collection itself is unchanged —
   it simply only runs in Debug now, as intended.

**Where.** `RogueMain.c` — deleted the death-recap rest-tally block in `gameOver()` (the CSV row builder
`recordRestStatsRow` and its `gameOver`/`victory` call sites are untouched). `SEBridge.mm` — new
`SE_DEBUG_BUILD` macro, captured from the build-config `DEBUG` flag *before* `Engine/Rogue.h` `#undef`s
it (Rogue.h repurposes `DEBUG` as `if (WIZARD_MODE)`); `seRecordRestStats`'s body is now `#if
SE_DEBUG_BUILD`-gated. `iBrogue_iPad.xcodeproj/project.pbxproj` — added `GCC_PREPROCESSOR_DEFINITIONS =
("DEBUG=1", "$(inherited)")` to the **BrogueSE framework's Debug configuration only** (it previously set
`DEBUG` for Swift via `SWIFT_ACTIVE_COMPILATION_CONDITIONS` but not for C/ObjC).

**Determinism.** Output/UI-only; no RNG, no game state, runs at game over — saves/replays unaffected.

### 2026-06-17 — Detect magic: flat base of 2, prioritize still-hidden polarities

**What.** Two tuning changes to the potion of detect magic (`Items.c`):
1. **Base count `1–2` → `2`.** The reveal count is no longer a random `rand_range(1, …)`; it is now a
   flat **2 + ring-of-wisdom level** (`min(max(1, 2 + rogue.wisdomBonus), count)`). A cursed wisdom ring
   can still lower it, but never below 1. Applies to both the drink (`quaffDetectMagic`) and the thrown
   floor-sense (`throwDetectMagicOnFloor`).
2. **Prioritize unknown polarities (drink only).** `quaffDetectMagic` now stable-partitions the eligible
   pack pool so items whose aura is **not yet sensed** sort ahead of already-sensed ones, then keeps the
   partial Fisher-Yates selection inside that still-hidden band until it's exhausted. So a drink spends its
   reveals discovering **new** polarities before escalating any already-sensed item to a full ID. (The
   thrown version needs no partition: its eligibility already excludes `ITEM_MAGIC_DETECTED` items, so every
   floor candidate is unknown.)

**Where.** `Items.c` — new helper `detectMagicPolarityAlreadyKnown` (mirrors the gear-vs-flavored branch in
`revealOrIdentifyPolarityItem`); the partition + banded selection in `quaffDetectMagic`; the flat count in
both `quaffDetectMagic` and `throwDetectMagicOnFloor`. Marked `// iOS port (Brogue SE):`.

**Determinism.** Selection still draws on the substantive `rand_range` stream at the action point, so it
replays identically within this version; like any gameplay change it diverges replays from pre-change
recordings.

### 2026-06-16 — Lone Wolf: a solo-play XPXP progression / fallback (new content)

**What.** A player-owned progression track ("Lone Wolf") that compensates for solo play, since allies
make a run substantially easier. It is driven by the player's *own* exploration XPXP (the same
new-pathable-cell count that already feeds allies via `addXPXPToAlly`), which is otherwise never
accumulated for the player. Two tiers, each granting an **effective-strength aura** and a **polarity
tell**; gated so it can never coexist with allies.

**Rules.**
- **Accrual:** `rogue.loneWolfXP += rogue.xpxpThisTurn`, but **only while the player has zero living
  allies anywhere in the dungeon** (`playerHasLivingAllyAnywhere`, all-depths scan — an ally stranded
  upstairs still counts) **and** at depth `>= LONE_WOLF_MIN_DEPTH` (6; depths 1–5 rarely offer allies,
  and grant-then-yank confuses new players).
- **Tiers (cap 5):** crossing each cumulative-XPXP threshold in `LONE_WOLF_TIER_THRESHOLDS` grants +1
  effective strength (so +5 at the cap). **Update 2026-06-24:** the curve was changed from a flat
  `LONE_WOLF_XP_PER_TIER` (1500) divisor — which maxed a full-clear run at ~depth 15 — to a **front-loaded
  threshold table** `{0, 800, 3000, 5600, 8400, 11700}`, calibrated against real exploration data
  (`exploration-stats.csv`) so a full-clear paces ~one tier every 3–4 levels: I~D6, II~D9, III~D12-13,
  IV~D16, V~D20. `handleLoneWolf` walks the ascending table each turn (re-derives from `loneWolfXP` alone).
  The strength is a **removable aura**, applied as a tracked delta on `rogue.strength`
  (`setLoneWolfStrengthBonus`, via `rogue.loneWolfStrBonus`) so it flows through every combat/equip site
  and can be removed exactly. (`rogue.strength` therefore moves when the aura applies/removes — an
  accepted UX tradeoff for this release.)
- **Polarity tell:** one per tier-up, **only on a run where the player has *never* had an ally**
  (`!rogue.hasEverHadAlly`) — it compensates the pure-solo player for the per-rescue tells in
  `captiveReactToPack` they forgo. Reuses the shared polarity path (`loneWolfRevealPolarity` in
  `Items.c`: collect eligible carried items → `rand_range` pick one → `revealOrIdentifyPolarityItem`).
  Polarity knowledge is permanent (`ITEM_MAGIC_DETECTED`); never un-revealed.
- **Gaining any ally** (`becomeAllyWith`, the sole ally chokepoint) calls `loseLoneWolfBonusOnAlly`:
  latches `hasEverHadAlly` (kills future polarity tells for the run), zeroes the XPXP track, and strips
  the strength aura. The track is **re-grindable from zero** once the ally dies — the intended late-game
  fallback when early allies are lost around depth 12 and no replacements appear (Lone Wolf re-pops ~15).
  Discord does **not** route through `becomeAllyWith`, so a discordant enemy never trips Lone Wolf.

**Determinism / save-safety.** Driven entirely by deterministic exploration counts and ally events; the
polarity `rand_range` draws happen inside `handleLoneWolf` → `playerTurnEnded`, which asserts
`RNG_SUBSTANTIVE`. New `rogue` fields are set deterministically, so saves (input replays) stay valid.

**Files.**
- `Rogue.h`: `playerCharacter` fields `loneWolfXP` / `loneWolfTier` / `loneWolfStrBonus` /
  `hasEverHadAlly`; tuning defines `LONE_WOLF_MIN_DEPTH` / `LONE_WOLF_TIER1_XP` / `LONE_WOLF_TIER2_XP` /
  `LONE_WOLF_MAX_TIER`; prototypes for `loneWolfRevealPolarity` and `loseLoneWolfBonusOnAlly`.
- `RogueMain.c`: zero-init of the four fields in `initializeRogue`.
- `Time.c`: `playerHasLivingAllyAnywhere`, `setLoneWolfStrengthBonus`, `handleLoneWolf` (called from
  `handleXPXP` before `xpxpThisTurn` is zeroed), and `loseLoneWolfBonusOnAlly`.
- `Items.c`: `loneWolfRevealPolarity` (after `quaffDetectMagic`).
- `Movement.c`: `becomeAllyWith` calls `loseLoneWolfBonusOnAlly` after promoting the ally.
- `IO.c`: `printMonsterInfo` titles the player **"Lone Wolf &lt;N&gt;"** in the sidebar (replacing "YOU")
  while a tier is active — the Roman tier numeral (I…V) is shown inline (**update 2026-06-24**; previously
  bare "Lone Wolf" with no numeral, which made the current tier unreadable in-game). "Lone Wolf IV" is 12
  cols; the `(lit)`/`(dark)` illumination tag still fits the 20-col `STAT_BAR_WIDTH`; only the longer
  `(invisible)` tag is suppressed on the rare invisible turn so nothing overflows/clips.

### 2026-06-16 — Empty bottle: additive generation channel (out of the potion draw)

**What.** The empty bottle (`POTION_DETECT_MAGIC`) no longer competes in the weighted potion draw.
Its `itemTable` frequency is set **15 → 0** (Brogue) / **20 → 0** (Rapid/Bullet), and it is now placed
by a dedicated self-correcting meter at the **end of `populateItems`**, fully *in addition to* the
per-level item budget (it consumes neither a potion slot nor a generic item slot).

**Why.** As a ninth "potion," the bottle sitting in the draw at freq 15/20 meant every potion roll had
a real chance of becoming a bottle *instead of* a real potion, visibly skewing the real-potion
distribution. Pulling it into its own channel restores the pre-bottle potion mix while still seeding
bottles across the dungeon.

**Mechanic.** New `short rogue.emptyBottleSpawnChance` accrues `EMPTY_BOTTLE_SPAWN_INCREMENT` (13)
points per eligible depth, rolled with `rand_percent`; on a hit it places one bottle via the normal
item heat-map (`getItemSpawnLoc` + `placeItemAt`) and resets to 0. Reset-on-hit self-corrects and
targets **~1 bottle every 3–4 floors**. Gated to depths `[2, gameConst->amuletLevel]`; no hard per-run
cap. Drawn at the end of `populateItems` so the item/gold RNG stream above is byte-identical to before;
deterministic via `rand_percent`, reset to 0 in `initializeRogue`, so saves (input replays) reproduce
placements. Cross-version seed reproducibility intentionally not preserved (SE is leaderboard-silent).

**Where.** `emptyBottleSpawnChance` field + comment in `playerCharacter` (`Rogue.h`); reset in
`initializeRogue` (`RogueMain.c`); `EMPTY_BOTTLE_SPAWN_INCREMENT` define + the placement pass in
`populateItems` (`Items.c`); empty-bottle `frequency` set to 0 in all three `potionTable_*`
(`GlobalsBrogue.c` / `GlobalsBulletBrogue.c` / `GlobalsRapidBrogue.c`). All marked
`// iOS port (Brogue SE):`. Design rationale in
[docs/design/empty-bottle-v2.md](../../docs/design/empty-bottle-v2.md) §4.

### 2026-06-16 — Altars of insight: retune guaranteed depths to 6 & 11

**What.** Moved the two guaranteed altars-of-insight reward rooms from depths **5 & 15** to **6 & 11**.
Mechanism unchanged — same `insightAltarDepths[]` count-built/carry-forward schedule, same
`INSIGHT_ALTAR_MAX_DEPTH = 20` cutoff (see the 2026-06-14 entry below) — only the table values changed.

**Where.** `insightAltarDepths[] = {6, 11}` in `addMachines` (`Architect.c`). Deterministic
(depth-driven) and save-safe. Docs synced in [MACHINES_AUDIT.md](../../docs/game-data/MACHINES_AUDIT.md).

### 2026-06-16 — Remove the "Game Center" button from the SE title menu

**What.** SE is Game Center-silent (no leaderboard/achievements), but its main menu — inherited from CE
— still showed a "Game Center" button. Removed it. The SE title menu is now New Game, Play, View, File
Management (+ Quit on non-tablet builds).

**Where.** `MainMenu.c` `initializeMainMenuButtons` — dropped the `buttons[4]` `NG_GAME_CENTER` init and
lowered `MAIN_MENU_BUTTON_COUNT` (tablet 5→4, non-tablet 6→5, with Quit moving to `buttons[4]`). The
`NG_GAME_CENTER` dispatch case is left in place (now unreachable, harmless). CE keeps its button in
`BrogueCE/Engine/MainMenu.c`. SE-only.

### 2026-06-16 — SE title-screen release string: "Alphabet-a Soup 0.9.0 "

**What.** The title screen renders `gameConst->versionString` bottom-right (CE shows "CE 1.15"). SE now
shows its own branded release line, **"Alphabet-a Soup 0.9.0 "** (the trailing space is intentional --
it pads the string off the menu's right edge). Replaces the previous `"SE 1.15.1-ios"`.

**Where.** `GlobalsBrogue.c` `BROGUE_VERSION_STRING`. This string is **display-only** (title via
`drawMenuFlames` in `MainMenu.c`, `--version`, seed-catalog header) — it is **not** used for save/
recording compatibility, which is governed by `BROGUE_RECORDING_VERSION_STRING` /
`BROGUE_PATCH_VERSION_PATTERN` (left as `"SE <major>.<minor>.<patch>"`). So SE/CE saves still can never
alias, and the branded version is decoupled from the technical 1.15.1 fork point. No determinism impact.

### 2026-06-16 — Fix: `potionTable_Brogue` row order out of sync with the `potionKind` enum

**What.** In the standard-Brogue potion table only, the **"detect magic"** row sat at index 16 (right
after "creeping death", *before* the honey/vomit/wort/venom block). The `potionKind` enum puts
`POTION_DETECT_MAGIC2` at index 20 (*after* `POTION_VENOM`). Because `makeItemInto` indexes the table
directly by kind (`&potionTable[itemKind]`), every kind 16–20 was off: e.g. capturing a healing cloud
yields `POTION_WORT` (18), which resolved to `potionTable[18]` = **"vomit"** — the reported bug. Stench
capture (`POTION_VOMIT`=17) likewise showed as "honey". Reordered the rows to
HONEY, VOMIT, WORT, VENOM, DETECT_MAGIC2 so the table matches the enum.

**Where.** `GlobalsBrogue.c` `potionTable_Brogue[]` — moved the "detect magic" row to after "venom" and
left a comment warning that row order MUST track `enum potionKind`. `GlobalsRapidBrogue.c` /
`GlobalsBulletBrogue.c` were already correct (unchanged). No enum, capture-mapping, or effect-dispatch
code changed — those all use `POTION_*` constants; this was purely the descriptive table being
mis-ordered. (Note: honey/vomit/wort/venom carry `frequency 0` in Brogue vs 10 in Rapid/Bullet — left
as-is; that's a generation-tuning question, separate from this ordering fix.)

### 2026-06-15 — Display "potion of water" as "bottle of water"

**What.** Captured plain water now reads as **"bottle of water"** instead of "potion of water" — it's
ordinary water in a bottle, not a magical potion. Display-only; the item, its kind (`POTION_WATER`), and
all behavior (drink = flush, thrown = flood) are unchanged.

**Where.** `itemName` POTION branch (Items.c) — a special-case alongside the existing empty-bottle one
(`POTION_DETECT_MAGIC` → "empty bottle"): `POTION_WATER` → "bottle of water". SE-only.

### 2026-06-15 — Rations cook into edible "cooked food" in fire (heal-over-time) (new content)

**What.** A ration of food (but not a mango) caught in actual fire no longer simply burns up — it cooks
into a new food kind, **cooked food**. Cooked food is as filling as a fresh ration (power 1800, same as
a ration), and eating it additionally grants a small heal-over-time: **1 HP/turn for 5 turns (5 HP
total)**. Mangoes stay non-flammable, so only rations convert. Cooked food is never generated naturally
(frequency 0) — it exists only as the product of burning a ration.

**Reused, not bespoke.** The heal-over-time rides the existing `STATUS_REGENERATING` primitive (built
for the honey potion). To support a *fixed* total (5) distinct from honey's *proportional* total (~20%
of max HP), the per-turn metering in `Time.c` was parameterized: a new `rogue.regenerationHeal` field
carries the total HP to mete across the status duration, set when the status is applied (honey →
`maxHP*20/100`; cooked food → 5). The stateless elapsed-fraction metering and exact-total/deterministic
guarantees are unchanged. The fade message is now neutral ("the warmth fades, and your wounds have
finished closing.") so it reads for both consumers.

**Flammability.** Only `RATION` food is flagged `ITEM_FLAMMABLE` (in `makeItemInto`). `burnItem` now
branches first: if a flammable item is a ration **and the tile is `T_IS_FIRE`** (not lava — lava also
routes through `burnItem` via `T_LAVA_INSTA_DEATH`, and a ration dropped in lava is still destroyed), it
swaps the item's kind to `COOKED_FOOD` in place, clears `ITEM_FLAMMABLE` (so the same fire can't burn
the freshly-cooked result to nothing next tick), prints a "sizzle … cook to perfection" line, and
keeps the item on the floor. Everything else burns up as before.

**Determinism / saves.** `rogue.regenerationHeal` is set deterministically wherever the status is
applied and is recomputed on replay; the kind swap in `burnItem` runs in the normal fire-resolution path
during replay. No new non-deterministic state. Save-safe per the input-replay model.

**Where.** `COOKED_FOOD` enum + `COOKED_FOOD_REGEN_TURNS`/`_TOTAL` + `rogue.regenerationHeal`
(Rogue.h); `foodTable` cooked-food row, freq 0, power 1800 (Globals.c); `ITEM_FLAMMABLE` on rations + cooked-food
naming + regen on eat + honey sets `regenerationHeal` (Items.c); `burnItem` cook-transform + regen
metering uses `regenerationHeal` + starvation auto-eat message (Time.c). SE-only (gameplay/content).

### 2026-06-15 — Keyboard labels disabled; hardware-keyboard presence drives UI instead

**What.** The in-game hotkey labels are turned off (they reflect the Classic key layout and would
mismatch the new Modern default — see the "Default to Modern keyboard layout" change). A hardware
keyboard now instead: hides the on-screen d-pad and ESC button (platform/Swift side — redundant with
the keyboard's arrows / Escape), and surfaces the "Press <?> for help" welcome hint (the only help
affordance left with labels — and their help button — gone).

**Engine side.** `KEYBOARD_LABELS` stays at its `false` default — the host no longer enables it. A new
`HARDWARE_KEYBOARD_CONNECTED` global (GlobalsBase.c / Rogue.h), set by the host via
`se_setHardwareKeyboardConnected()` on GCKeyboard connect/disconnect, tracks keyboard presence
independently. `welcome()` now gates the help-menu hint on `HARDWARE_KEYBOARD_CONNECTED` rather than
`KEYBOARD_LABELS`. The label infrastructure (`se_setKeyboardLabelsEnabled`) is left intact but unused,
so labels can be re-enabled (and remapped for Modern) later.

**Where.** `HARDWARE_KEYBOARD_CONNECTED` (GlobalsBase.c, Rogue.h); `se_setHardwareKeyboardConnected`
(SEBridge.mm, BrogueSEHost.h); welcome help-prompt gate (RogueMain.c). Platform behavior (d-pad / ESC
hide) lives in BrogueViewController.swift. Applies to all three engines.

### 2026-06-15 — Fix: worm-tunnel lever could be placed sealed inside walls (#766)

**What.** In the "Worm tunnels" room machine, the hidden lever that opens the tunnels could be placed
entirely surrounded by granite — inaccessible without shatter/tunneling (reported on seed #411762472,
depth 11).

**Cause.** The lever is placed with `MF_IN_PASSABLE_VIEW_OF_ORIGIN` (a field-of-view check from the
machine origin). The blueprint built `WORM_TUNNEL_OUTER_WALL` at the origin (`MF_BUILD_AT_ORIGIN`), so
the FOV was computed *from inside a wall* and could "see" — and select — a wall tile with no reachable
passable space beside it.

**Fix.** Build plain `FLOOR` at the origin instead (and drop the `DF_TUNNELIZE` feature DF so the floor
isn't pre-carved at build time). The FOV now originates from passable space, so the lever lands beside
a reachable tile. The tunnel reveal still runs off the `WORM_TUNNEL_MARKER` tiles on lever-pull; the
only behavioral change is cosmetic — the outer wall no longer detonates instantly on pull, the crumble
trail works outward instead. Matches the upstream-proposed fix for issue #766, scoped to this one
blueprint (the sibling vestibule "exploding wall / portcullis" machine sits in open space, where the
wall-origin FOV still finds reachable tiles, so it isn't touched).

**Notes.** Upstream Brogue bug (CE's blueprint is identical); fix is **SE-only**. This is a
level-generation change, so seeds that place this machine generate differently from here — irrelevant
under the current SE policy (determinism/replays not a concern), noted for if that changes.

**Where.** "Worm tunnels" blueprint, origin feature row (`GlobalsBrogue.c`). Marked `#766`.

### 2026-06-15 — Fix: obstruction crystal didn't block explosions (surface effects) (#812)

**What.** An explosion (e.g. from an explosive mutation/bloat) on one side of a region fully sealed by
staff-of-obstruction crystals damaged creatures on the other side — the barrier didn't stop it.

**Cause.** The staff of obstruction lays `FORCEFIELD` tiles (only the boundary becomes `CRYSTAL_WALL`).
`FORCEFIELD`/`FORCEFIELD_MELT` had `T_OBSTRUCTS_PASSABILITY | T_OBSTRUCTS_GAS |
T_OBSTRUCTS_DIAGONAL_MOVEMENT` but **not** `T_OBSTRUCTS_SURFACE_EFFECTS`. An explosion is a
`GAS_EXPLOSION` tile on the SURFACE layer, and its spread (`spawnMapDF`) only refuses to cross cells
flagged `T_OBSTRUCTS_SURFACE_EFFECTS` — so the flood fill walked straight through the forcefield. Every
other solid obstruction (`CRYSTAL_WALL`, statues, walls) carries the flag; `FORCEFIELD` was the lone
exception.

**Fix.** Add `T_OBSTRUCTS_SURFACE_EFFECTS` to `FORCEFIELD` and `FORCEFIELD_MELT` (the melt phase is
still a solid barrier). Pure data fix, one flag per row; also stops any other surface effect (blood,
lichen, …) from bleeding through a forcefield. Nothing should occupy the surface of an impassable
crystal, so no downside.

**Notes.** Upstream Brogue bug (CE's `FORCEFIELD` flags are identical); fix is **SE-only**.

**Where.** `tileCatalog` `FORCEFIELD` / `FORCEFIELD_MELT` rows (`Globals.c`). Marked `#812`.

### 2026-06-15 — Fix: lumenstones miscounted in the loss score (stacks, not gems) (#805)

**What.** On death/quit, the score counted lumenstone *stacks* rather than individual lumenstones, so
a stack of N lumenstones added 500 gold instead of N × 500.

**Cause.** `gameOver` used `numberOfMatchingPackItems(GEM, 0, 0, false)`, which returns the number of
pack entries (one per stack), to value gems at 500 gold each. The victory path already counts by
`theItem->quantity`.

**Fix.** Sum `theItem->quantity` over `GEM`-category pack items in `gameOver`, matching the victory
path. Ports BrogueCE PR #808 (issue #805), adapted to SE's existing victory-path idiom.

**Notes.** Upstream Brogue bug present in all engines; applied to **SE** here. CE/Classic inherit the
upstream fix when PR #808 merges into `origin/master` (per the master-sync model) — not double-patched.

**Where.** `gameOver` (`RogueMain.c`). Marked `#805`.

### 2026-06-15 — Fix: explosion immunity lasted 4 turns for the player instead of 5 (#816)

**What.** After an explosion, the player is meant to be immune to further explosive damage "for five
turns" (Rogue.h, `T_CAUSES_EXPLOSIVE_DAMAGE`). In practice they could suffer the next explosion after
only 4 turns (reported on the Brogue Discord: explosion on turn 7523, another on 7527).

**Cause.** Explosions are spawned *inside* `updateEnvironment` (flammable gas igniting → `GAS_EXPLOSION`,
which carries `T_IS_FIRE | T_CAUSES_EXPLOSIVE_DAMAGE`) and applied to the player immediately via
`spawnDungeonFeature` → `applyInstantTileEffectsToCreature` (Architect.c), setting
`STATUS_EXPLOSION_IMMUNITY = 5`. In the turn loop the order was `updateEnvironment()` → then
`decrementPlayerStatus()`, so the freshly granted 5 was decremented to 4 on the *same* tick — costing
one of the five turns. Monsters were unaffected because `decrementMonsterStatus` already runs before
`updateEnvironment`; the player's decrement sitting after it was the anomaly.

**Fix (two parts — the second added 2026-06-19 after empirical testing).**

1. *Ordering.* Decrement `STATUS_EXPLOSION_IMMUNITY` *before* `updateEnvironment` (and removed it from
   `decrementPlayerStatus`), aligning the player with the monster ordering so a value granted during
   `updateEnvironment` survives the full turn. This alone took the player from 3 → 4 fully-immune turns.

2. *Grant value 5 → 6.* The status is decremented once per turn and explosive damage only fires while it
   is 0, so a grant of N protects N−1 turns. A grant of `5` therefore gave only **4** clear turns — which
   is what the reporter still observed after part 1 ("still only 4 turns of immunity"). Confirmed with the
   `D_TEST_EXPLOSION` harness: hits landed on turns 1, 6, 11, 16 (gap 5 = 4 immune turns). Bumping the grant
   to `6` yields the intended **five** clear turns (gap 6). Applies to the player and monsters alike (shared
   set site in `applyInstantTileEffectsToCreature`).

**Notes.** Upstream Brogue bug (CE's ordering and grant value are identical); fix is **SE-canonical**
(also backported to CE for testing — see CE's log).

**Where.** `playerTurnEnded` (decrement relocated before `updateEnvironment`), `decrementPlayerStatus`
(decrement removed), and the grant `STATUS_EXPLOSION_IMMUNITY = 6` in `applyInstantTileEffectsToCreature`,
all `Time.c`. Marked `#816`.

**Test harness (2026-06-19, debug; both decrements now gated).** Two `Rogue.h` toggles (default 0, ship
off) verify this empirically since a version-locked save can't replay across builds:
- `D_TEST_EXPLOSION` — each environment tick refuels a `DF_METHANE_GAS_ARMAGEDDON` + `DF_PLAIN_FIRE`
  inferno on the player's tile (`refreshCell=false`, so the hit lands on the normal
  `updateEnvironment`/`applyInstantTileEffectsToCreature` path) and heals them to full. Every fresh
  explosive hit logs `"[#816] explosive hit on turn N"` and zeroes the damage, so the gap between
  consecutive logged turns IS the immunity duration.
- `D_LEGACY_EXPLOSION_TIMING` — reverts to the pre-fix ordering (decrement back in
  `decrementPlayerStatus`, after `updateEnvironment`) for a single-binary A/B: off → gap 5 (fixed),
  on → gap 4 (the reported bug). The two decrement sites are now gated on this flag rather than hard-coded.

### 2026-06-15 — Fix: a submerged player saw submerged monsters across separate water bodies (#831)

**What.** While submerged in deep water, the player could see (and, with telepathy, identify) *every*
submerged monster on the level — including ones in disconnected pools (and lava/bog) that have nothing
to do with the player's water.

**Cause.** `monsterHiddenBySubmersion` revealed a submerged monster whenever the observer was merely
standing in deep water (`T_IS_DEEP_WATER`, not levitating), with no check that observer and target
shared the same body of water. Both visibility paths funnel through this: `canSeeMonster` is
`!monsterIsHidden && (playerCanSee || monsterRevealed)`, so flipping the hidden flag off exposed the
monster to line of sight *and* let telepathy (`monsterRevealed`) supply the identity.

**Fix.** Reveal a submerged monster only if it shares the **same connected body of deep water** as the
observer. Added `inSameDeepWaterBody` (Monsters.c) — an iterative, 8-connected flood fill over
`T_IS_DEEP_WATER` (explicit queue, no recursion, so a large lake can't blow the stack) — and gated the
reveal on it. Scope is deep water only: the player only ever triggers the reveal from deep water, and
the monsters that matter (eel, kraken, naga) submerge there; a salamander in connected lava or a naga
in connected shallow/bog is intentionally not revealed (lava never connects to water anyway, and the
shallow-water naga is a rare edge). The flood fill is the last `&&` term, so the non-swimming common
case never reaches it (zero added cost).

**Notes.** Upstream Brogue bug (CE's implementation is identical); fix is **SE-only**. Symmetric for
monster observers (bolt targeting): a submerged monster observer likewise only perceives submerged
targets in its own body of water.

**Where.** `monsterHiddenBySubmersion` + new static `inSameDeepWaterBody` (`Monsters.c`). Marked `#831`.

### 2026-06-15 — Fix: monsters woke against a one-turn-stale stealth range (#837)

**What.** A monster could begin hunting even though the player's drawn stealth-range circle
excluded it — most visibly when the player stepped from lit into dark lighting on the turn the
monster aggroed.

**Cause.** `playerMoves` updates `player.loc` and then calls `playerTurnEnded` with no vision pass
in between, so lighting still reflects the *old* tile. `playerTurnEnded` only recomputed
`rogue.stealthRange` (and refreshed vision) *after* the monster loop. Meanwhile `awarenessDistance`
already used the new position (scent refreshed at the top of the turn) and the player's current FOV.
So the monster wake check (`awareOfTarget` → `awareness = rogue.stealthRange * 2`) compared a current
distance against the *previous* turn's stealth range — the brighter tile's, ~double the dark one —
while the stealth circle the player saw was the freshly recomputed (dark, smaller) one. Hence a
monster inside the stale range started hunting despite the displayed range excluding it.

**Fix.** Recompute lighting + stealth range *before* the monster loop, by restoring the
`updateVision(true)` / `rogue.stealthRange = currentStealthRange()` block that upstream Brogue left
commented out at the top of the turn. The end-of-turn recompute stays (to reflect what the monsters'
turns changed). `updateVision(true)` is used rather than a bare `updateLighting()` so the
light-diff bookkeeping (`recordOldLights`) stays consistent for the end-of-turn display pass —
otherwise the lighting transition wouldn't redraw.

**Tradeoffs.** One extra `updateVision` (FOV + lighting) per turn — FOV is recomputed redundantly
since the player doesn't move during the monster loop. It also draws cosmetic RNG via `paintLight`,
shifting the RNG stream; irrelevant under the current SE policy (determinism/replays/saves not a
concern) but worth revisiting if seeded determinism is reinstated. This is an upstream Brogue bug
(present identically in CE); the fix is **SE-only** — CE stays faithful to upstream.

**Where.** `playerTurnEnded` (`Time.c`, before the monster turn loop). Marked `#837`.

### 2026-06-15 — Fix: confused monsters could stumble onto sacred glyphs (#841)

**What.** A confused monster that "tries to attack" instead lurches in a random valid direction,
chosen by `randValidDirectionFrom(monst, x, y, false)`. Passing `respectAvoidancePreferences ==
false` made it ignore *all* avoidance — including `T_SACRED`, the ward laid down by a scroll of
sanctuary — so a confused monster could wander straight onto a glyph it could never willingly cross,
bypassing the player's sanctuary.

**Fix.** Sacred ground is a hard ward, not a mere preference, so `randValidDirectionFrom` now
excludes `T_SACRED` tiles the monster avoids *regardless* of `respectAvoidancePreferences`. The
existing "attack a player on the avoided tile" exception is preserved (`HAS_PLAYER && state !=
MONSTER_ALLY`), so a monster can still strike a player standing on the glyph. The player is
sacred-immune (`monsterAvoids` never trips on sacred for them), so player confused-movement is
unaffected. Deterministic: the change only alters which directions are eligible before the single
`rand_range` roll.

**Where.** `randValidDirectionFrom` (`Movement.c`). SE only; marked `#841`.

### 2026-06-15 — Potion of water: drinking it is a "flush" (douse fire + dilute afflictions)

**What.** Drinking captured water used to just flood your own tile (it reused the *thrown* effect).
Now drinking is a beneficial **flush**: it fully extinguishes `STATUS_BURNING` and halves the
remaining duration of `STATUS_CONFUSED`, `STATUS_HALLUCINATING`, and `STATUS_NAUSEOUS` (all active
ones at once). With nothing in scope active it's a flavor sip (still consumed, turn passes). The
flood is now **throw-only** (`shatterPotionAtLoc`, unchanged). Poison and physical/curse-like effects
(stuck, weakened, slowed, darkness, aggravating) are deliberately out of scope.

**Polarity.** Water was mis-tagged malevolent; drinking is now benevolent, so `magicPolarity` is
`+1` (potionTable row) and `magicCharDiscoverySuffix` returns `+1` (water dropped out of the bad
group). Consequence (accepted): thrown water no longer auto-targets enemies (benevolent potions are
excluded in `canAutoTargetMonster`); you aim the flood at a tile manually. Water is capture-only +
always identified, so there's no "cursed potion?" nag and no AI throws it — the reclassification only
affects Discoveries-screen color and throw-targeting.

**Where.** `POTION_WATER` case in `drinkPotion` and `magicCharDiscoverySuffix` (`Items.c`); water
row in `GlobalsBrogue.c` (`magicPolarity` + description). SE only. Design doc:
`docs/design/potion-of-water-drink-flush.md`.

**Determinism.** Extinguish + integer-halve use no RNG; saves/replays unaffected.

### 2026-06-15 — Fix: polarity channels ignored weapons & armor (detect magic, rest, freed captive)

**What.** Drinking/throwing a potion of detect magic, resting, and freeing a captive could never
reveal the good/bad polarity of a weapon or armor — so an unidentified runic/enchanted piece of gear
was invisible to every polarity check (e.g. a +3 runic chain mail that "nothing worth detecting" ever
flagged). These channels scanned only `HAS_INTRINSIC_POLARITY = (POTION|SCROLL|RING|WAND|STAFF)`,
which excludes `WEAPON`/`ARMOR`. Upstream CE detects polarity over the full `CAN_BE_DETECTED` set,
including gear; the SE rework narrowed the scope unintentionally.

**Fix.** Widened the **scan** mask from `HAS_INTRINSIC_POLARITY` to
`CAN_BE_DETECTED = (WEAPON|ARMOR|POTION|SCROLL|RING|CHARM|WAND|STAFF|AMULET)` in the four sensing
channels: `quaffDetectMagic` (drink), `throwDetectMagicOnFloor` (throw), `gainPolarityInsightFromRest`
(via the `applyPolarityInsightToRandomItem` mask argument), and `captiveReactToPack`. The SE
partial-reveal mechanic (random 1–2 per quaff, the rest schedule, first-match for captives) is kept
deliberately — only the *category scope* changed. **Eating insight (`gainScrollInsightFromEating`)
was left `SCROLL`-only on purpose** — it's the intentional single-category channel.

Two correctness guards accompany the widening:
- **Gear caps at the polarity glyph — no escalation to a full enchant ID** (matches CE, where detect
  magic only ever set the aura glyph on weapons/armor; the exact enchant is learned by wearing). New
  predicate `polarityAuraAlreadyShownForGear()` drops a weapon/armor from eligibility once its aura is
  shown, and `revealOrIdentifyPolarityItem()` short-circuits gear to a detect-only (never `identify`).
  The kind-flavored consumables keep the two-step reveal→escalate-to-ID behavior.
- **The kind-deduction call `tryIdentifyLastItemKinds(HAS_INTRINSIC_POLARITY)` was left untouched.**
  Only the *scan* filter widened; the elimination engine still runs over `HAS_INTRINSIC_POLARITY`
  only, since weapons/armor have per-instance (not kind-roster) polarity and can't be deduced.
  Likewise the internal hardcoded `HAS_INTRINSIC_POLARITY` AND-filter inside
  `applyPolarityInsightToRandomItem` was removed so the caller's `categoryMask` alone governs scope.

**Where.** `quaffDetectMagic`, `throwDetectMagicOnFloor`, `captiveReactToPack`,
`applyPolarityInsightToRandomItem`, `gainPolarityInsightFromRest`, `revealOrIdentifyPolarityItem`, and
the new `polarityAuraAlreadyShownForGear` helper — all in `Items.c`. Doc:
`docs/game-data/IDENTIFICATION_AUDIT.md` (§2 note, §5a/§5b/§5g, §6a/§6b).

**Determinism.** Still fully `rand_range`-driven; widening the eligible pool changes the RNG draw
pattern, so pre-change in-flight SE recordings desync — acceptable (SE is unshipped, `SE_ENABLED`
Debug-only, Game-Center-silent). New seeded runs are reproducible as always.

### 2026-06-15 — Fix: applying one empty bottle from a stack converted the whole stack

**What.** With a stack of empty bottles (e.g. 3), applying one to a capturable tile (water, gas, …)
transmuted **all** of them into the captured potion in a single action. The capture branch in
`drinkPotion` called `fillEmptyBottle(theItem, …)`, which sets `bottle->kind` on the *stack* item,
and then `return`ed early — bypassing the normal `consumePackItem` decrement — so the entire
quantity changed kind at once.

**Fix.** When the bottle stack has quantity > 1, peel a single bottle off (clone via `generateItem`
+ struct copy, `quantity = 1`, decrement the original) and fill only that one; the rest stay empty
bottles. Quantity 1 keeps the old unlink-then-`addItemToPack` re-merge path. So one apply = one
captured potion, leaving the remaining empty bottles intact.

**Where.** `POTION_DETECT_MAGIC` capture branch in `drinkPotion`, `Items.c`.

**Determinism.** Mirrors the existing `dropItem` stack-peel pattern (recorded player action; the
`generateItem` RNG draw is reproduced identically on replay), so seeds/replays are unaffected.

### 2026-06-15 — Fix: detect magic crashed on a NULL pack item (deref-before-null-guard)

**What.** Quaffing a potion of detect magic could crash with `EXC_BAD_ACCESS` (SIGSEGV at 0x0).
`itemMagicPolarityIsKnown()` dereferenced `theItem->category` (via `tableForItemCategory`) one line
*above* its own `theItem &&` null-test, so a NULL item faulted at address 0. The reveal path
`quaffDetectMagic` → `revealOrIdentifyPolarityItem` → `itemMagicPolarityIsKnown` is the crashing
chain (confirmed by the device crash log backtrace).

**Fix.** Null-guard `itemMagicPolarityIsKnown()` *before* the deref (a NULL/unknown item has no known
polarity → return false). Hardened the rest of the detect-magic path against a NULL leaking further:
`detectMagicOnItem()` and `revealOrIdentifyPolarityItem()` no-op on NULL, and `quaffDetectMagic`'s
message loop skips empty slots.

**Open question (not yet root-caused).** The crash log shows the symptom (NULL `theItem`), but the
`quaffDetectMagic` eligibility loop only stores non-NULL pack items, the partial Fisher-Yates only
swaps existing entries, and nothing in the reveal path (`identify`/`identifyItemKind`/
`updateRingBonuses`/`detectMagicOnItem`) frees or removes a pack item (`stackItems` runs only on
pickup via `addItemToPack`). So how a NULL reaches the slot isn't explained by the local logic —
possible heap corruption from elsewhere. The guards make the path crash-proof regardless; a repro
from the originating save is still wanted to find the upstream cause.

**Where.** `itemMagicPolarityIsKnown`, `detectMagicOnItem`, `revealOrIdentifyPolarityItem`,
`quaffDetectMagic` in `Items.c`.

**Determinism.** Pure null-guards; no RNG or state change on the non-NULL path, so seeds/replays are
unaffected.

### 2026-06-14 — Fix: rest tallies leaked across games in a session (stale `levels[]` memory)

**What.** `levels[]` is `malloc`'d (not `calloc`'d) and the per-level init loop in `initializeRogue()`
never reset the custom `restTurnsOnLevel` / `restRevealsOnLevel` fields, so a new game inherited the
previous game's counts from the reused heap block. Since the rest mechanic *increments* these counters,
stale values both (a) inflated the rest-stats CSV and (b) — because `gainPolarityInsightFromRest` sums
`restRevealsOnLevel` into its escalating threshold (`revealsSoFar`) — **raised the reveal threshold on
the 2nd+ game played in a session**, making repeat reveals come slower than designed. Now both fields
are zeroed per level at game start.

**Evidence.** In a 7-run capture, a depth-1 *Quit* reported per-level rest data for levels 2/3/4
identical to the prior depth-4 run — impossible for a fresh run, i.e. pure stale memory. The first run
of the session (fresh, OS-zeroed pages) was clean and matched the schedule exactly (217 rested turns →
2 reveals).

**Why it mattered for tuning.** This likely contributed to the original "I rarely get a second reveal"
report: repeated test games in one session accumulated phantom `revealsSoFar`, throttling the cadence.

**Where.** `initializeRogue()` level-init loop in `RogueMain.c`.

**Determinism.** Zeroing leaked debug counters; the fields don't drive dungeon RNG, so seeds/replays are
unaffected (and the rest-cadence threshold now reflects only the current game, as intended).

### 2026-06-14 — Debug: per-run rest-stats CSV export (for cadence calibration)

**What.** Every finished live SE run now appends one row to `Documents/se/rest-stats.csv`: seed, game
mode, outcome (Died/Quit/Escaped/Mastered) + sanitized cause, depth reached, deepest level, wisdom
bonus, total rested turns, total rest reveals, the same two totals restricted to depths 1–10, and a
per-level breakdown (`t1…tN` rested turns, `r1…rN` reveals). The host owns a leading wall-clock `time`
column and writes the header once on file creation. This is the empirical readout for tuning the
rest-insight schedule (the `REST_INSIGHT_BASE_TURNS` / `REST_INSIGHT_STEP_TURNS` constants).

**Pull it off-device:** Xcode → Window → *Devices & Simulators* → select the app → ⚙ → *Download
Container* → show package contents → `AppData/Documents/se/rest-stats.csv`.

**Why.** "How many rest reveals does a normal depth-1..10 run actually earn?" can't be answered from the
code — only from real play. The CSV makes the rest budget measurable so the cadence constants can be set
to the desired ~2-3 reveals by depth 10.

**Where.** `RogueMain.c` — new `extern void seRecordRestStats(const char *, const char *)` hook plus the
statics `sanitizeCsvCell()` / `recordRestStatsRow()`, called at the end of `gameOver()` and `victory()`
(after the outcome is finalized, gated on `!rogue.playbackMode` so recordings don't log). `SEBridge.mm`
— `seRecordRestStats()` inside the `extern "C"` block does the append (reuses the `Documents/se` path,
adds the timestamp). No `BrogueCEHost` protocol or Swift changes. **Update (2026-06-17):** SE now ships
in Release, so the CSV write is gated to Debug builds (`SE_DEBUG_BUILD`) — see the 2026-06-17 entry.

**Determinism.** Output-only: the engine hook draws no RNG and mutates no game state, and runs after the
run has ended — saves/replays are unaffected. The host timestamp is host-side metadata, not engine state.

### 2026-06-14 — Retune the rest-insight schedule (faster repeat reveals)

**What.** Replaced the rest-polarity threshold's steep `100 × N` ramp with a low base plus a gentle
additive step: reveal N now needs `60 + 25 × (N-1)` rested turns since the last reveal (intervals
60, 85, 110, 135…; cumulative 60, 145, 255, 390…). The old ramp put the 2nd reveal at 300 cumulative
rested turns — more than a typical depth-1..10 run accrues — so reveals after the first were rare. The
new curve is tuned to fire ~2-3 times by depth 10 while later reveals still cost progressively more.

**Why.** The first reveal landed but repeats almost never did; resting is already self-limiting (it
burns hunger, and the eligible pool is the finite set of unknown polarity-bearing pack items — reveals
just hold when nothing qualifies), so the steep guard-ramp wasn't earning its cost.

**Where.** `gainPolarityInsightFromRest()` in `Items.c` — new `REST_INSIGHT_BASE_TURNS` (60) constant
alongside `REST_INSIGHT_STEP_TURNS` (now 25), and the threshold expression `BASE + STEP × revealsSoFar`.
Ring-of-wisdom acceleration and the deterministic, replay-safe random target are unchanged. The two
constants are the tuning surface; the Debug-only rest-stats CSV (`rest-stats.csv`) is the readout for
recalibrating against real play (the on-screen death-recap tally was removed 2026-06-17). Supersedes the
schedule in the 2026-06-11 entry below.

**Determinism.** Threshold is a deterministic function of rested-turn count and reveals earned; no RNG.

### 2026-06-14 — Remove curse reveals the cleansed items' polarity

**What.** Reading a scroll of remove curse now reveals the (malevolent) polarity of every item it
actually uncurses. Each item whose `ITEM_CURSED` flag is lifted gets `ITEM_MAGIC_DETECTED` set, so
its good/bad polarity becomes known in the inventory/floor display — the player learns what the curse
had been hiding. Items that weren't cursed are untouched.

**Why.** Previously the cleansing left no trace of what each item's polarity had been; surfacing the
malevolent polarity is information the player has clearly earned by spending the scroll.

**Where.** `SCROLL_REMOVE_CURSE` case in `readScroll()` (`Items.c`). The reveal piggybacks on
`uncurse()`'s return value (true only when a curse was cleared) and reuses the existing
`ITEM_MAGIC_DETECTED` polarity-knowledge flag.

**Determinism.** Purely state-driven (gated on `ITEM_CURSED`); no RNG, save-replay safe.

### 2026-06-14 — "Extra hot" blue title-screen flames (iOS port)

**What.** SE's title-screen menu flames burn blue (hottest part of a real flame) instead of the
Classic/CE red/orange. `flameSourceColor` / `flameSourceColorSecondary` (`Globals.c`) now make blue
the dominant channel, with green/red randoms pushing the hottest source cells to a white-blue core.
Display-only color constants — no change to flame control flow, so RNG/determinism are unaffected.

**Where.** `flameSourceColor`, `flameSourceColorSecondary` in `Globals.c`.

### 2026-06-14 — Title-screen badge: "CE" → "SE" (iOS port)

**What.** The flame-wreathed title-screen badge to the right of the "BROGUE" logo now reads **SE**
(was the inherited "CE" badge from the CE port). Block-letter "S" + "E" in `seAccent[]` (renamed
from `ceAccent[]`); same flame/mask treatment, same position.

**Where.** `drawMenuFlames()` in `MainMenu.c`.

### 2026-06-14 — Tag the welcome line with the engine flavor (iOS port)

**What.** With three selectable engines, the opening adventure-log line now ends with `… Dungeons of
Doom! (Brogue SE)` so it's obvious which one is running. Display-only (a `message()` string, not an
input), so recordings/saves are unaffected. Marked `// iOS port (Brogue SE):` in `welcome()`.

**Where.** `welcome()` in `RogueMain.c`.

### 2026-06-14 — Selectable keyboard schemes (Classic / Modern) + scheme-aware help screen (iOS port)

**What.** Adds an opt-in **Modern** keyboard layout alongside the stock **Classic** (vi-keys) layout,
selectable from the help screen and persisted. Full design: `docs/design/keyboard-schemes.md`.

- **Scheme model.** `enum keyboardScheme { KEYBOARD_SCHEME_CLASSIC, KEYBOARD_SCHEME_MODERN, COUNT }`
  (`Rogue.h`) + global `rogueKeyboardScheme` (`GlobalsBase.c`, default CLASSIC). A scheme is a
  physical→canonical key map applied by `applyKeyboardScheme()` (`IO.c`). CLASSIC is identity.
- **Where translation runs (and why it's recording-safe).** Brogue records *actions*, not raw keys
  (`recordKeystroke(directionKeys[dir])`, `REST_KEY`, …), so recordings are already canonical. The
  scheme is applied in the **platform bridge** (`CEBridge.mm` `nextKeyOrMouseEvent`), *not* in the
  engine input loop, because only the bridge can tell a raw hardware keystroke from a synthesized one:
  the on-screen d-pad/buttons enqueue canonical keys (`raw == NO`) that must **not** be remapped, while
  hardware character keys (`raw == YES`) are run through `applyKeyboardScheme`. Recordings, seeds and
  the leaderboard are unaffected by the active scheme.
- **Modern layout.** Right-hand grid: `u/o` and `m/.` diagonals around the **`i/j/k/l` cross**
  (`i`=up, `j`=left, `k`=down, `l`=right), with `,` a second down; Shift/Ctrl + grid = run on all 8
  directions. Displaced commands: inventory→`e`, equip→Shift+`E`, messages→`p`, ascend→Shift+`P`,
  descend→Shift+`:`. The vi movement keys `h`/`y`/`b`/`n` (and their run forms) are mapped to
  `UNKNOWN_KEY` (inert) so **only the grid moves the player** — `y`/`n` no longer move you, leaving
  them free for yes/no. (Those prompts read via `buttonInputLoop` with `textInput == true`, which
  bypasses `applyKeyboardScheme`, so yes/no and item-letter selection are unaffected.) Other left-hand
  commands (`a`pply/`d`rop/`s`earch/`w`/`z`/`x`/`c`/… and every Shift+command) are untouched (identity).
  *(Refined 2026-06-14: was center `k`=wait with `h`/`y`/`b`/`n` passing through as movement; changed
  to the `i/j/k/l` cross + inert vi keys at the player's request. Wait one turn is still on `z`.)*
- **Quit removed on tablet.** A guard in `applyKeyboardScheme` maps a hardware `QUIT_KEY` to
  `UNKNOWN_KEY` in **both** schemes — quit is menu-only. The on-screen menu's Quit button synthesizes
  `QUIT_KEY` directly (`raw == NO`) so it still works; `actionMenu` no longer advertises a `Q:` hotkey.
- **Scheme-aware help screen + toggle.** `printHelpScreen` (`?` / the keyboard-gated menu Help entry)
  now renders the *active* scheme (the Classic command list or the Modern grid) and toggles between
  them with **Tab** (persisted), dismissing on space/esc/click. No new menu item was added.
- **Persistence.** `cePersistKeyboardScheme()` / `ceLoadPersistedKeyboardScheme()` (`SEBridge.mm`),
  restored in `se_start`, mirroring the graphics-mode and seed persistence. The NSUserDefaults key is
  the **shared** `"keyboard scheme"` (same key in all three engines), so the chosen scheme is an
  app-wide input preference that carries across Classic/CE/SE — an intentional exception to SE's
  `"se …"`-prefixed state, because it is an input preference, not game state.
  *(Refined 2026-06-14: was the per-engine key `"se keyboard scheme"`; unified to the shared key so the
  setting is remembered across all versions, at the player's request.)*

**Why.** The stock layout assumes a numpad and vi movement, which is unintuitive on Magic
Keyboards/laptops. The Modern grid gives a spatial directional pad with no numpad; the indirection
layer is built so an arbitrary-remap feature is a later increment, and so the whole thing is
backportable to desktop Brogue (the engine owns the scheme table; each platform calls it on its real
keyboard input). Deferred: arbitrary user remapping; per-key key-repeat (a separate platform concern).

**Where.** `Rogue.h` (enum + `rogueKeyboardScheme` extern + `applyKeyboardScheme`/`cePersistKeyboardScheme`
decls), `GlobalsBase.c` (global), `IO.c` (`applyKeyboardScheme`, scheme-aware `printHelpScreen`,
`actionMenu` Quit label), `CEBridge.mm` (modifier+`raw` dequeue, scheme call, persistence, `ce_start`
restore), `BrogueCEHost.h` (`dequeueKeyEventWithShift:control:raw:`). Platform-side modifier plumbing
is logged in the Classic tree's IOS_MODIFICATIONS.md (shared `BrogueViewController`/`CEHost`).

### 2026-06-14 — Hardware keyboard modifiers (Shift/Ctrl) now reach the engine (iOS port)

**What.** The iOS host key queue was byte-only, and both bridges hardcoded `controlKey = shiftKey = 0`
for keystrokes — so Shift/Ctrl-run never worked on iOS in *either* engine. The queue
(`BrogueViewController`) now carries the key code plus real `shift`/`control` flags (read from
`UIKey.modifierFlags`) and a `raw` flag (true only for hardware character keys eligible for
keyboard-scheme remapping). `CEBridge.mm` sets `returnEvent->controlKey`/`shiftKey` from the dequeued
modifiers. Arrow keys now send canonical lowercase movement letters (scheme-independent) instead of the
old uppercase-`HJKL` byte hack, with run carried by the modifier flags. `BrogueCEHost`'s
`dequeueKeyEvent` became `dequeueKeyEventWithShift:control:raw:`.

**Why.** Prerequisite for Shift/Ctrl-run in the Modern scheme; also fixes Classic Shift/Ctrl-run on
iOS, which had silently never worked. The byte-only queue was legacy, not a platform limit.

**Where.** `CEBridge.mm` (`nextKeyOrMouseEvent`), `BrogueCEHost.h`. Swift/Classic side (the shared
`BrogueViewController` queue, `CEHost.swift`, `RogueDriver.mm`) is logged in the Classic tree.

### 2026-06-14 — Altars of insight: depths 5 & 15 only, with a carry-forward schedule

**What.** Two changes to the guaranteed altars-of-insight reward room (see the 2026-06-10 entry below):
1. **Removed the depth-25 altar.** The schedule is now just depths 5 and 15.
2. **Failed placements carry forward (bounded to depth 20).** The altar is a `BP_ROOM` machine that needs a
   gate site whose interior choke-size lands in the blueprint's `roomSize` range; a level with no
   qualifying room can't fit it. Previously such a level silently dropped the altar (best-effort, like the
   amulet vault), so it didn't reliably appear at 5 or 15. Now `addMachines` tracks how many altars are
   *due* by the current depth versus how many have actually been built (`rogue.insightAltarsBuilt`), and
   retries on each subsequent level until the obligation is met — depth 5 with no room retries on 6, 7, …
   and likewise for the depth-15 altar — but gives up past `INSIGHT_ALTAR_MAX_DEPTH` (20) rather than chase
   it into the late dungeon.
3. **Widened the room-size window** from `{7,14}` to `{6,25}`. `{7,14}` was the narrowest/lowest window of
   any `BP_ROOM` machine (cf. transfer `{10,30}`, commutation `{15,25}`, reward vaults `{30,50}`), which
   excluded the common larger rooms and was the main cause of placement failures. `placeAltarPairInRoom`
   needs only two open interior cells, so the broad window is safe — a bigger room is just a roomier
   carpeted shrine, like the other altars.

**Why.** Players couldn't count on the identification help arriving when expected; tying the schedule to
"built so far" rather than a depth modulo makes the two altars guaranteed-to-appear rather than
guaranteed-to-be-*attempted*.

**Where.**
- `Rogue.h`: new `short insightAltarsBuilt` on the `rogue` struct (zeroed on new game with the rest of the
  struct; set only in `addMachines`).
- `Architect.c`: `addMachines` replaces the `(depthLevel - 5) % 10 == 0` modulo gate with a due-vs-built
  comparison against a static `insightAltarDepths[] = {5, 15}` table, capped at `INSIGHT_ALTAR_MAX_DEPTH`
  (20); builds at most one altar per level.
- `GlobalsBrogue.c`: `roomSize` widened `{7,14}` → `{6,25}`; blueprint comment updated ("5/15/25" → "5 and
  15", plus the room-size rationale).

**Determinism.** Depth-driven and `buildAMachine` uses the substantive RNG, so it's seed-stable. The new
field is set deterministically during level generation → save-safe (saves are input replays). Note this
*does* shift seed output relative to the old schedule on any level where placement now happens that didn't
before (and removes the depth-25 draw); warrants the same release-time `recordingVersionString` treatment
as the original altar feature. Rapid/Bullet untouched.

### 2026-06-14 — In-game hotkey labels follow an attached hardware keyboard (iOS port)

**What.** On the tablet port, CE's `KEYBOARD_LABELS` was a hardcoded compile-time `false`
(`#ifdef BROGUE_TABLET`), so the engine's in-game keyboard shortcut hints — the hotkey letters on
sidebar/menu buttons and prompt text like *"Press space to continue"* — **never appeared**, even
with a hardware keyboard attached. The Classic engine, by contrast, exposes `KEYBOARD_LABELS` as a
runtime global that the Swift layer toggles on `GCKeyboard` connect/disconnect, so Classic shows the
labels when a keyboard is present. CE had no way to receive that signal.

CE now mirrors Classic: `KEYBOARD_LABELS` becomes a runtime-mutable variable on tablet (default
`false` = touch-only), and the host drives it via a new `ce_setKeyboardLabelsEnabled()` bridge entry
point on the same `GCKeyboard` connect/disconnect notifications. The non-tablet (desktop) build keeps
the original compile-time `#define KEYBOARD_LABELS true`. The flag is display-only (never game
state), so making it dynamic is save/replay-safe.

- **`Rogue.h`**: under `#ifdef BROGUE_TABLET`, replace `#define KEYBOARD_LABELS false` with
  `extern boolean KEYBOARD_LABELS;` (declared after the `boolean` typedef); the `#else` desktop
  default stays `#define KEYBOARD_LABELS true`.
- **`GlobalsBase.c`**: define `boolean KEYBOARD_LABELS = false;` (tablet only).
- **`BrogueCEHost.h` / `CEBridge.mm`**: new exported `void ce_setKeyboardLabelsEnabled(int enabled)`
  that sets the global.
- **Swift (`BrogueViewController.swift`)**: a new `updateKeyboardLabels(_:)` helper drives *both*
  engines (`setKeyboardLabelsEnabled` for Classic + `ce_setKeyboardLabelsEnabled` for CE) from the
  hardware-keyboard observer, so the labels are correct whichever engine is active and survive an
  engine switch.

**Why.** Reported: on iPad CE the keyboard shortcuts don't appear when a keyboard is attached. Root
cause was the compile-time flag; fix matches the long-standing Classic behavior.

### 2026-06-13 — Seed-entry keyboard: pre-fill the field + use a number pad (iOS port)

**What.** Two bugs in the seeded-game (and any pre-filled) text dialog, fixed together.

The engine maintains its own `inputText` buffer and renders the text on the game screen; the
hidden iOS `UITextField` is only an off-screen key-capture proxy. CE showed the keyboard purely
via `uiMode == ShowKeyboardAndEscape` and never told the host the default value, so the field was
**empty** while the engine buffer held the pre-filled seed. iOS does not fire its
`shouldChangeCharactersIn` callback for Backspace on an empty field, so the engine never received
`DELETE_KEY` for the pre-filled digits — they couldn't be deleted. We now hand the default to the
host before the input loop so the field is seeded to match the engine buffer.

The dialog also always used the default (alpha) keyboard even for numeric seed entry. We now pass
whether the entry is numeric so the host can show a number pad.

- **`Rogue.h` / `CEBridge.mm`**: new host hook `ceRequestTextInput(const char *defaultText, boolean
  numeric)` → `[gHost requestTextInput:numeric:]`.
- **`IO.c` (`getInputTextString`)**: call `ceRequestTextInput(defaultEntry, textEntryType ==
  TEXT_INPUT_NUMBERS)` once just before the input loop. (A number pad has no Return key; the host
  adds a "Done" accessory bar that submits like Return.)

### 2026-06-13 — Persist the last-played seed across app launches (iOS port)

**What.** The title screen's "New Seeded Game" prompt pre-fills `previousGameSeed` — the seed of
the most recent run. Upstream keeps this only in memory for the process lifetime; on iOS, where
backgrounded apps are routinely terminated, it reset to 0 on every relaunch, so the prompt never
remembered your last seed. We now back `previousGameSeed` with `NSUserDefaults`.

- **Host hooks** (`CEBridge.mm`): `ceLoadPersistedSeed()` / `cePersistLastSeed(uint64_t)`, declared
  in `Rogue.h` next to `setGraphicsMode`. The seed is stored as an `NSNumber` under
  `@"ce last game seed"` so the full `uint64_t` range round-trips losslessly (mirrors the existing
  graphics-mode persistence).
- **Load** (`RogueMain.c`, `rogueMain()`): `previousGameSeed = ceLoadPersistedSeed();` replaces the
  `= 0` reset, so the menu default is restored on entry.
- **Persist**: wherever the engine assigns `previousGameSeed`, we mirror it to disk — after the
  seed assignment in `initializeRogue` (`RogueMain.c`, guarded by `!playbackMode`) and after the
  recording-load assignment (`Recordings.c`). The persisted value thus always tracks the in-memory one.

### 2026-06-12 — Staff of frost: freeze, slow, ice bridges, frozen-foliage walls, and shoving (new content)

**What.** A new good staff, the **staff of frost** (`STAFF_FREEZE`, positive polarity, freq 8, value 1200,
inserted before `STAFF_HEALING` so it falls inside `NUMBER_GOOD_STAFF_KINDS`). It fires a new single-target,
enemy-targeting bolt (`BOLT_FREEZE` / `BE_FREEZE`, `BF_TARGET_ENEMIES | BF_NOT_LEARNABLE`,
`forbiddenMonsterFlags MONST_INANIMATE`, deals no direct damage). It stops at the first creature it hits —
rather than freezing a whole line — so a single frozen creature can be meaningfully shoved into the others:

- **Freeze → slow.** A struck creature is encased in ice via a new first-class status `STATUS_FROZEN`
  (added before `NUMBER_OF_STATUS_EFFECTS`; "Frozen", not negatable). Frozen gates actions exactly like
  `STATUS_PARALYZED` (every paralysis gate gained a `|| STATUS_FROZEN`: the player turn-loss loop and
  turn-counter and no-metabolism check in `Time.c`; the monster turn gate in `Time.c` and the per-monster
  turn-ender in `Monsters.c`; `attackHit` auto-hit, the helpless-defender backstab flag, and the
  shatter-on-hit clear in `Combat.c`; swarm eligibility and blocker-displacement in `Monsters.c`; stair-
  following in `RogueMain.c`; entrancement mirror-move in `Movement.c`). Freeze decrements via the
  `decrementMonsterStatus` default case / `decrementPlayerStatus`. Durations: new
  `staffFreezeDuration = max(2, 2 + enchant/2)` (hard lock, ~3–7 turns) and
  `staffFreezeSlowDuration = min(20, max(10, enchant·3))` (slow tail, capped under the slowness wand's 30),
  both in `PowerTables.c`. The slow tail is **layered underneath the freeze at cast time**
  (`STATUS_SLOWED = freeze + slow`) so it lingers after the ice breaks without remembering the enchant.
- **Fire beats freeze (both directions).** Casting on a `MONST_FIERY` or currently-burning creature only
  extinguishes + slows it (never freezes); catching fire later (`exposeCreatureToFire`, `Time.c`) instantly
  thaws a frozen creature; a blow shatters the freeze (`Combat.c`, leaving the slow tail).
- **Ice quenches terrain fire.** The ray also snuffs any `T_IS_FIRE` terrain it crosses (new
  `extinguishFireOnTile` in `Time.c` clears burning gas/surface layers to `NOTHING`; called per path cell in
  `updateBolt`), carving a firebreak. Brimstone/lava-fed fire may reignite next turn from its source — that one
  calm turn is intended.
- **Ice bridges over deep water.** The bolt's `pathDF` is the previously-dead `DF_DEEP_WATER_FREEZE`
  cascade, which now does something: deep water it crosses becomes the latent **`ICE_DEEP`** walkable floor
  (white "glossy ice", safe), melting edge-inward (negative `promoteChance`) back to water through the black
  "melting ice" warning tile. (Foundation-gated, so the pathDF is a no-op over floor/lava/chasm.)
- **Frozen foliage walls.** New terrain `FROZEN_FOLIAGE` / `FROZEN_FOLIAGE_MELT` (tiles + `DF_FROZEN_FOLIAGE`
  / `_MELTING` / `_THAW`), chained onto the end of the water-freeze cascade so the one ray also freezes dense
  foliage it crosses into a brittle, impassable barrier (`T_OBSTRUCTS_PASSABILITY | T_OBSTRUCTS_VISION`),
  melting edge-inward back to foliage; `T_IS_FLAMMABLE` + `fireType` = thaw, so fire melts it like lake ice.
- **Bump-to-push.** Walking into a frozen creature shoves it like a statue (`pushFrozenCreature`, `Combat.c`),
  intercepted in `playerMoves` (`Movement.c`) before the attack. The block slides across open floor a distance
  set by the shover's **effective strength** (`clamp(rogue.strength - weaknessAmount - 8, 2, 10)` — 4 tiles at
  the starting strength 12, up to the 10-tile cap by strength 18) and comes to rest **on** the first hazard it
  reaches — lava / a chasm / deep water (`T_LAVA_INSTA_DEATH | T_AUTO_DESCENT | T_IS_DEEP_WATER`), deposited
  there to die / fall a level / flounder via `applyInstantTileEffectsToCreature` — or **before** a wall, another
  creature, or the map edge. (The slide is walked manually rather than via a blind blinking-zap, which is what
  makes "shove the adjacent enemy into the lava" reliable: a raw blink skims over hazards since they aren't
  obstructions and only applies tile effects at the landing cell.) The block takes no damage; a creature it
  slams into takes **distance travelled + `max(0, strength - 12)`** damage (momentum plus a strength shove-bonus
  that bites even on an adjacent slam) and is doused if burning. A block wedged against an obstruction won't
  budge (no turn). Since the frost bolt deals no direct damage, this is the staff's strength-scaling payoff.
  *Bugfix 2026-06-27:* the bump-to-push guard lives in `playerMoves`, but the special-weapon attack handlers
  run **before** it, so a reaching weapon could damage/dispatch a frozen creature instead of pushing it (frozen
  counts as helpless → auto-landing sneak hit). Frozen creatures are now excluded from every player melee
  hit-list builder — `handleSpearAttacks` (pike/spear penetrate) and `handleWhipAttacks` (`Movement.c`), the
  axe sweep in `buildHitList` (`Combat.c`), and the flail pass-attack `buildFlailHitList` (`Movement.c`) — so a
  frozen creature takes no melee damage and the bumped block falls through to the push.
- **Colour state.** Persistent tints in `getCellAppearance` (`IO.c`): a strong icy cast while `STATUS_FROZEN`,
  a fainter chill while `STATUS_SLOWED` (the slow tint is **game-wide, any source**, not just this staff), plus
  the icy `flashMonster` at the moment of freezing. Ice terrain reads via its own tile colours.

**Gating.** Debug grant `D_FROST_STAFF_START` (`Rogue.h`, `WIZARD_MODE && 0`) starts you with a +10
identified staff in `initializeRogue` (`RogueMain.c`), added deterministically (recording-safe). Bolt rows
were appended to all three variant catalogs (`GlobalsBrogue.c` / `GlobalsRapidBrogue.c` /
`GlobalsBulletBrogue.c`); the staff/status/tile/DF tables are shared in `Globals.c`. `BOLT_FREEZE` is
appended (not inserted) since the staff→bolt link is the `power` field, not positional.

**Follow-up (2026-06-14) — itemDetails description.** `STAFF_FREEZE` was never given a `case` in the
identified-staff `switch` in `itemDetails` (`Items.c`), so an *identified* staff of frost fell through to the
`default` and reported "No one knows what this staff does." Added a `STAFF_FREEZE` case that prints the
freeze duration (`staffFreezeDuration`, scaling with enchant like the other staff blurbs) and notes the
thaw-slow tail and the fire-douses-instead-of-freezes rule.

### 2026-06-13 — Steal-preference component (extracted from monkey + imp; third reusable component)

**What.** The per-monsterID theft scoring in `rateItemStealDesirability` (the `if monsterID == MK_MONKEY …
else if == MK_IMP …` branches) is now a data-driven **steal component** — the third reusable component after
flee and loot. A thieving creature (anything with `MA_HIT_STEAL_FLEE`) carries a `stealProfile` on its catalog
`steal` field describing *which* unequipped pack item it prefers to snatch; the shared evaluator scores items
from that profile. The `MA_HIT_STEAL_FLEE` machinery itself (trigger, steal, flee, drop) is untouched — only
the *preference* was extracted.

**Schema** (`Rogue.h`): `stealProfile` = `mode` (`STEAL_ADDITIVE`: every unequipped item eligible, rules adjust
score — monkey/imp; or `STEAL_EXCLUSIVE`: only rule-matching items eligible, the rest never taken) + `baseScore`
+ `randomPickPercent` (the formerly-hardcoded 5% hedge, now per-thief) + a `{0}`-terminated `stealRule[]`. Each
`stealRule` matches `categories` (bitmask) / `kind` / `enchant` polarity / `requireFlags`, and contributes a
`flatBonus` and/or `perEnchantBonus` (× enchant1). The hedge now picks uniformly **among the eligible set only**,
so an EXCLUSIVE thief never breaks its own rule.

**Why.** The steal mechanic (PR #849 + the 2026-06-11 tuning, both below) was recent iOS-port code already
diverged from upstream, and a suite of new thieves is planned — so the per-ID branching was the bespoke duplication
ADR 0001 says to extract on the next consumer. New thieves are now config: e.g. "only cursed" = one EXCLUSIVE rule
gated on `ITEM_CURSED`; "only staffs/potions" = one EXCLUSIVE rule on `STAFF | POTION`. (A thief that *uses* the
stolen item is a separate future behavior, not part of this preference component.)

**Where.** `Rogue.h` — `stealMode` / `enchantPolarity` / `stealRule` / `stealProfile` + the `creatureType.steal`
field (appended after `loot`). `Globals.c` — `monkeyStealProfile`/`monkeyStealRules`, `impStealProfile`/
`impStealRules`, attached to the monkey and imp catalog rows. `Combat.c` — `rateItemStealDesirability` rewritten to
evaluate the profile (returns 0 = ineligible); the candidate count + hedge + weighted pick in `specialHit` made
eligibility-aware.

**Determinism.** Monkey and imp are **RNG-identical** to the prior hardcoded path: their profiles reproduce the
exact per-item scores, and the call order (one `rand_percent(randomPickPercent)`, then one `rand_range` over the
same eligible set / score sum) is unchanged, so seeded runs and recordings are unaffected. New edge for future
EXCLUSIVE thieves: if no eligible item is carried, the steal simply fizzles (the hit still lands). A thief with
no `steal` profile falls back to the legacy uniform "every item desirability 10" behavior. See
[docs/guides/reusable-components.md](../../docs/guides/reusable-components.md) and ADR 0001.

### 2026-06-12 — Gold goblin: a passive treasure-hoarder you chase down (new content)

> **Refactored 2026-06-13 into a reusable flee component (behavior unchanged).** The flee/escape AI no
> longer lives in bespoke `goldGoblin*` functions; it is now the generic, config-driven component
> `fleeProfile` (in `Rogue.h`, attached to a `creatureType`'s `fleeAI` field) + `fleeAITakesTurn` /
> `fleeStepToExit` / `monsterStepTowardAvoidingPlayer` / `monsterFleeDistanceMap` / `monsterKeepDistanceStep` /
> `fleerAtExit` / `fleerEscape` / `monsterTossFeatureBehind` / `fleerNoteDamage` (in `Monsters.c`), with
> per-instance state in `creature.fleer` (`fleerState`). `monstersTurn` dispatches on `monst->info.fleeAI`
> (one data-driven branch for *all* fleers, not a per-monster `if`). The gold goblin is the reference
> consumer: its config is `goldGoblinFleeProfile` (in `Globals.c`), and its spawn stays gold-specific.
> See [docs/guides/reusable-components.md](../../docs/guides/reusable-components.md) and ADR 0001. The
> flee behavior below is unchanged; the old `goldGoblin*`/`GOLD_GOBLIN_*` symbol names in this entry now map to
> the generic ones (`goldGoblinFleeTurns`→`fleer.fleeTurns`, `GOLD_GOBLIN_PLAYER_BERTH`→`fleeProfile.playerBerth`,
> etc.). One cosmetic change: the toss message is now generic ("flings a flask to the ground and it erupts
> behind it") rather than naming the fungal forest.
>
> **Refactored 2026-06-13 (second dogfood) into a reusable loot component (behavior preserved in normal
> play).** The goblin's gold/item drops are no longer bespoke `goldGoblin*` loot functions; they are now the
> generic, config-driven component `lootProfile` + `lootEntry` (weighted table) + `lootThrownStack` (in
> `Rogue.h`, attached to a `creatureType`'s `loot` field) + `monsterShedItem` / `monsterScatterItem` /
> `lootGoldPile` / `rollLootTable` / `monsterShedLootOnHit` / `monsterDropDeathLoot` (in `Monsters.c`), with
> per-instance state in `creature.looter` (`lootState`: `isBearer` + `bonusDropped`). `isBearer` is set in
`initializeMonster` for any creature whose `info.loot != NULL` (so the component is drop-in for *any* looting
monster, not just the goblin's custom spawn) and cleared in `cloneMonster`, so clones stay loot-less; for the
67 non-looting monsters `info.loot` is NULL, leaving `isBearer` false exactly as before (no behavior change).
The one observable shift: a gold goblin created outside `spawnGoldGoblin` (e.g. a wizard-mode summon) now
drops its hoard, where before only the spawn hook flagged it — debug-only, can't affect a seeded run. The
`inflictDamage` and
> `killCreature` hooks now dispatch on `monst->info.loot` — **no `MK_GOLD_GOBLIN` branch remains anywhere in
> the engine**; the goblin is defined entirely by its catalog config (`fleeAI` + `loot`). The goblin's config
> is `goldGoblinLoot` + `goldGoblinMarquee` (in `Globals.c`). Old→new field names: `goldGoblinHasHoard`→
> `looter.isBearer`, `goldGoblinDroppedDetectMagic`→`looter.bonusDropped`; old→new fns: `goldGoblinReactToDamage`→
> `monsterShedLootOnHit`, `goldGoblinDropHoard`→`monsterDropDeathLoot`. The marquee roll is RNG-identical (one
> `rand_range(1, 100)` walked over the weighted table, same thresholds), and the death-hoard / per-hit RNG call
> order is preserved, so seeded drops are unchanged. **One deliberate behavior change:** per-hit shedding is now
> gated on `looter.isBearer`, so a *cloned* goblin no longer sheds gold/detect-magic on hit (previously only its
> *death* hoard was gated). This closes a clone-gold-farm gap and matches the stated "clones are loot-less"
> design; it is invisible in normal play (a wild goblin can't be cloned mid-chase). The `bonusBelowHpPct` test
> (`hpAfter * 100 < maxHP * 25`) is the same 25% threshold as the old `hpAfter * 4 < maxHP`.
>
> **Component hardening 2026-06-13 (post-audit).** Two changes from auditing the components for reuse traps:
> (1) **Loot tables are now `{0}`-weight-terminated sentinels** — `lootProfile.marqueeCount` is gone and
> `rollLootTable(const lootEntry *)` walks to the sentinel, removing the count/array-length mismatch footgun.
> RNG-identical (still one `rand_range(1, 100)` over the same weights). (2) **Discord now overrides the flee
> component** — the `fleeAI` dispatch in `monstersTurn` drops a discordant fleer out of `MONSTER_FLEEING`
> (sets `MONSTER_TRACKING_SCENT`) and falls through to the engine's discord/hunting logic instead of running
> `fleeAITakesTurn`, so a discordant goblin turns on the nearest creature and stops escaping (a player counter;
> previously the early return *and* the vanilla `creatureState != MONSTER_FLEEING` discord guard both insulated
> it). `fleer.triggered`/`fleeTurns` are left intact, so it resumes fleeing when discord ends. Both need a
> playtest to confirm feel. Caveat documented for future fleers: the early dispatch still bypasses
> `updateMonsterState` / scent transitions / per-turn `DFType` auras — a fleer needing those must fold them
> into the flee component. See [reusable-components.md §Sharp edges](../../docs/guides/reusable-components.md).

**What.** A new monster, the **gold goblin** (`MK_GOLD_GOBLIN`), a passive "treasure goblin": it spawns
near the down stairs, never attacks, and — once struck — flees toward the up stairs in bursts, shedding a
trail of gold and dropping a hoard if you kill it before it escapes. Lifecycle:

- **Generation.** `spawnGoldGoblin()` runs once per level (first visit) from `initializeLevel()`. Eligible
  on depths **5–24**, **5%** per eligible level, **at most once per run** (`rogue.goldGoblinSpawned`).
  Placed on an open tile adjacent to `rogue.downLoc`. HP is depth-scaled at spawn (`35 + 6·depth`); the
  catalog HP (65) is only a fallback for non-hook spawns (e.g. wizard mode).
- **Stats.** Never attacks (`{0,0,0}` damage), moves at the player's pace like a monkey (`movementSpeed`
  100 -- since it now flees *continuously*, a faster speed would be flatly uncatchable), modest dodge
  (defense 25), no regen (`turnsBetweenRegen` 0), `MONST_NO_POLYMORPH`, random gender
  (`MONST_MALE | MONST_FEMALE`).
- **AI** (`goldGoblinTakesTurn`, dispatched from `monstersTurn` before the normal AI). Dormant and
  motionless until it shares line of sight with the player (`canDirectlySeeMonster`) or is attacked; from
  then on it runs **continuously**, like a fleeing monkey -- it never pauses within sight, so it can't be
  pinned against a wall and punched. While it can see the player it keeps a flee timer topped up
  (`goldGoblinFleeTurns = GOLD_GOBLIN_FLEE_MEMORY`, 10); after losing sight it runs on for that many turns
  ("a little further") then settles, resuming if spotted again. **Its flight has two phases, keyed off
  health.** While still **healthy** (`>= GOLD_GOBLIN_BREAK_FOR_STAIRS_PCT`, 50% HP) it does *not* run for
  the exit at all -- it merely keeps its distance, fleeing to the farthest-from-player cell via the
  engine's safety map (`goldGoblinKeepDistanceStep`), letting the player wear it down (and shedding its
  gold trail). It can't escape in this phase. Once **wounded** (below 50% HP) it switches to breaking for
  the up stairs (the pathing below) and only then can reaching them count as an escape. (This deliberately
  re-uses, as the healthy-phase behavior, the elusive farthest-cell flee that emerged by accident while the
  stair-pathing was broken -- a bug turned into a feature.) The wounded-phase step (`goldGoblinFleeStep`)
  heads for the **up stairs** (its only escape) along a single blended cost field (`goldGoblinStepToward` /
  `goldGoblinDistanceMap`: `dijkstraScan` over a hand-built cost grid + `nextStep`). That one map folds the
  goblin's two desires into one decision -- which suits an engine whose monster AI does one thing per turn,
  with no state machine: it routes toward the up stairs, but cells within `GOLD_GOBLIN_PLAYER_BERTH` (4) of
  the player carry a steep extra cost (`GOLD_GOBLIN_BERTH_COST` per tile, fading with distance) and the
  player's own tile is impassable. So the cheapest route to the exit naturally swings *wide around* the
  player rather than brushing past -- the goblin heads home while keeping its distance, the way a monkey
  does. Because the penalty is a smooth gradient (not a hard reachable/unreachable flag), the route shifts
  smoothly as the player moves instead of flickering, which is what removed the dithering; it also means the
  goblin keeps *moving* toward the exit (not parking in a corner to be shot) and never brute-forces past the
  player (which would make it a free target). **When the up stairs are blocked** (the up-stairs field
  returns no step -- the player's body in a doorway, a fire/gas wall, or a 1-wide pinch), it does NOT hold
  in the player's eyeline (that would mean free hits, and the block would never have to break). Instead it
  stays *elusive*: it reroutes toward the **down stairs** as a lower-priority target via the *same*
  keep-distance field, so it runs for open ground toward a real destination -- never a dead-end corner, the
  way a flee-from-player safety map would. The down stairs are only a place to run to, never an escape
  (only the up stairs are); this forces the player to abandon the block to give chase, at which point the
  up-stairs route reopens and it retargets the up stairs. A block commits it to the reroute for
  `GOLD_GOBLIN_FLEE_COMMIT` (3) turns (`goldGoblinFleeCommit`) so it doesn't visibly flip up/down each turn
  as the player jockeys on and off the route. Only if *both* stair routes are walled off from it at once
  does it fall to the engine's safety map (`getSafetyMap`) as a last resort. This is the result of a long
  tuning sequence -- earlier tries side-stepped toward a player-blocked route (melee-range bounce),
  flip-flopped back after one step, dithered up/down before the berth penalty existed, ran into dead ends
  via a raw safety map, or held still and ate free hits. (Inherent tension, by design: it
  spawns by the down stairs and the player enters from the up stairs, so the player is usually *between* the
  goblin and its only exit -- it reaches the up stairs mainly when a room or loop lets it swing around, and
  is otherwise run down or cornered. That cost/benefit -- maybe loot, maybe wasted turns chasing -- is the
  intended trade.) On the **first step of its wounded break for the stairs** (not while merely keeping
  distance, and never on the first point-blank hit, where it would screen nothing) it flings its one
  hallucinogen flask back onto the tile it just *vacated* -- blooming `DF_FUNGUS_FOREST` (a glowing forest
  that blocks line of sight) directly between itself and the pursuer, right where the player will step
  next. The vacated tile is always a valid bloom site (it's clear now, or holds the player). Once per
  goblin, only on a turn it actually moved. **Escape (up stairs only):** `monsterAvoids`
  makes *every* non-player creature avoid the actual stair tile, so the goblin can never stand on a
  staircase -- "reaching" the up stairs is detected as adjacency (`goldGoblinAtUpStairs`:
  `distanceBetween(loc, rogue.upLoc) <= 1`), checked both before and after the step so it escapes on
  arrival rather than bouncing off a tile it cannot enter. The down stairs are a reposition target only,
  never an exit. Escaping calls `goldGoblinEscapes` (administrative `killCreature`, forfeiting the undropped
  hoard); the closure message shows in sight, or off-screen only with a ring of awareness
  (`rogue.awarenessBonus > 0`).
- **On hit** (`goldGoblinReactToDamage`, from `inflictDamage`, passed the post-shield `damage`). Any damage
  (incl. fire/gas) commits it to fleeing and refreshes the flee timer. A *discrete* attack — `attacker !=
  NULL`, so not fire/gas/poison ticks, which pass `NULL` — sheds loot: the **first non-lethal blow that
  takes it below 25% HP** (`(currentHP - damage) * 4 < maxHP`) sheds a **potion of detect magic**
  (`POTION_DETECT_MAGIC2`) instead of gold — a one-time near-death bonus, gated by
  `goldGoblinDroppedDetectMagic` so healing and re-wounding it never repeats it; every other discrete hit
  sheds a gold pile (`rand_range(2·depth, 5·depth)`). (Lethal blows fall through to gold; the death hoard
  handles the rest.)
- **Death hoard** (`goldGoblinDropHoard`, from `killCreature` on non-administrative death only, and only for
  the genuine hoard-bearer): one curated marquee item + 2–4 gold piles (`5–10·depth` each) + one thrown-
  weapon stack (darts < depth 10, javelins ≥ 10), scattered nearby. Marquee pool (weights /100): Staff 20,
  Charm 16, Wand 11, Ring 11, Weapon 11, Armor 11 (honest unidentified rolls) | Detect-magic potion 10
  (`POTION_DETECT_MAGIC2`, the always-present good potion on this branch), Scroll of enchanting 6, Potion of
  life 2, Potion of strength 2 (guaranteed-good). Clones (`cloneMonster` clears `goldGoblinHasHoard`) and
  debug spawns drop nothing, so a staff of cloning can't duplicate the loot.

**Why.** Requested feature — a high-risk/reward chase encounter (Diablo's "treasure goblin"). Spawned via a
custom hook rather than the horde/machine tables so it can be pinned to the down stairs and metered to once
per run. The gold is net-new (a deliberate bonus); leaderboard impact is within existing seed noise (gold is
score, items are not — see design notes), and on shared/weekly seeds the encounter is fully deterministic, so
it's a pure skill test rather than a luck swing.

**Where.** `Rogue.h` — `MK_GOLD_GOBLIN` (appended last so kind indices don't shift); `creature` fields
`goldGoblinBurstTiles`/`goldGoblinTriggered`/`goldGoblinHasHoard`; `rogue.goldGoblinSpawned`; decls for
`goldGoblinReactToDamage`/`goldGoblinDropHoard`; debug flag `D_ALWAYS_SPAWN_GOLD_GOBLIN` (a standalone
toggle, *not* gated on wizard mode, so it works in a normal game) which forces a guaranteed spawn on
depth 2 (early, for fast testing) and, in `spawnGoldGoblin`, also flags that goblin
`MB_TELEPATHICALLY_REVEALED` so it can be tracked on the map (even out of sight) while debugging. `Globals.c` — `goldGoblinColor`, `monsterCatalog` and
`monsterText` entries (all appended last, parallel to the enum). `RogueMain.c` — reset
`rogue.goldGoblinSpawned` in `initializeRogue`. `Architect.c` — `spawnGoldGoblin()` + its call in
`initializeLevel`. `Monsters.c` — `goldGoblinEscapes`/`goldGoblinDistanceMap`/`goldGoblinStepToward`/`goldGoblinAtUpStairs`/`goldGoblinFleeStep`/`goldGoblinKeepDistanceStep`/`goldGoblinTakesTurn`/`goldGoblinReactToDamage`/
`goldGoblinShedGold`/`goldGoblinMarqueeItem`/`goldGoblinScatterItem`/`goldGoblinDropHoard`, the dispatch
branch in `monstersTurn`, and the loot-less-clone line in `cloneMonster`. `Combat.c` — the trigger hook in
`inflictDamage` and the hoard-drop hook in `killCreature`.

**Determinism / RNG.** All RNG (the `rand_percent(5)` spawn roll, placement, depth-scaled HP, per-hit and
death gold, marquee/thrown rolls) runs on the substantive gameplay RNG during seeded level generation and
normal turns, so it is fully replay-deterministic. The spawn roll draws one `rand_percent` per eligible
level even when it fails (consistent on replay). New `rogue`/`creature` fields don't affect the
recording-based save format (saves replay inputs; only determinism matters). Recordings made before this
change will desync, as with any generation change.

### 2026-06-12 — Ring of awareness senses room machines on arrival (new content)

**What.** On *first* arriving at a level, a character wearing a (non-cursed) ring of awareness may get a
quiet hunch that the level holds a **room machine** — a hand-built set-piece (reward vault, altar,
captive room, guardian puzzle, library, etc.), detected by scanning for any `IS_IN_ROOM_MACHINE` cell.
The message is existence-only: *"you sense that something of significance lies hidden on this level."* It
never reveals the location, nor whether it's reward or danger (a treasure vault and a sentinel ambush
read identically), so the discovery itself is preserved.

- **Positive-only & truthful.** It fires *only* when a room machine actually exists, so a hunch always
  means "something's here" and silence is ambiguous (nothing, or you didn't pick up on it). It never lies.
- **Scales with awareness, gated on the ring.** Chance = `AWARENESS_MACHINE_SENSE_BASE` (25) +
  `rogue.awarenessBonus` (`20 × enchant`), clamped to 100 → roughly +1 ≈ 45%, +2 ≈ 65%, +3 ≈ 85%, +4 →
  certain. A cursed (negative-bonus) ring senses nothing.
- **First arrival only.** Rolled in `startLevel()` inside the freshly-generated branch (Brogue restores
  visited levels from the `levels[]` cache, so "freshly generated" is a free "first time here" proxy).
  This closes the bounce-the-stairs-to-re-roll exploit a per-entry roll would open.

**Why.** Requested — a subtle reward for an awareness build, in the spirit of its existing
"notice what others miss." Acknowledged seam: sensing a vault *across the level* is closer to divination
than awareness's usual *immediate-surroundings* perception; accepted as heightened intuition. Detects any
room machine (not just `BP_REWARD` vaults) because the cell flag is free to query and the reward-or-danger
ambiguity is more interesting — and more "awareness" — than a loot radar.

**Where.** `RogueMain.c` — `AWARENESS_MACHINE_SENSE_BASE`, `levelContainsRoomMachine()`, and a block after
the `seedRandomGenerator(oldSeed)` re-seed in `startLevel()` (so the `rand_percent` draw is on the
gameplay RNG stream). `Globals.c` — awareness `ringTable` description gains a sentence.

**Determinism / RNG.** The `rand_percent` draw is gated behind *both* `awarenessBonus > 0` and a machine
existing, so a player without the ring (or on a machine-less level) draws **no** RNG here and sees exactly
vanilla behavior. For ring-wearers it perturbs the stream (their game already diverges), deterministically;
like any gameplay change it diverges replays from pre-change recordings. CE-only; base chance tunable.

### 2026-06-28 — Arrival floor polarity sense moved from awareness to clairvoyance + count made guaranteed (new content)

**What.** Moved the per-floor item sense (the 2026-06-15 entry below) **off the ring of awareness and onto the
ring of clairvoyance**, and replaced the murky chance/rolls count with a **direct, guaranteed** one. On *first*
arriving at a level, a worn ring of clairvoyance senses the **good/bad polarity** of **N = enchant** magic items
lying anywhere on the floor — *secret rooms included* (`ITEM_DETECTED` set so the aura glyph shows for unfound
cells) — via `detectMagicOnItem`. It is **polarity only, NOT a full `identify()`**: a floor potion/scroll's
*kind* stays hidden (only its benevolent/malevolent aura, plus the kind's polarity run-wide, is revealed —
feeding elimination deduction), and gear shows its good/bad aura, never the exact enchant number. Message:
*"your ring tingles; you sense a hidden magical aura on this level."*

- **Why this ring.** Awareness was overloaded (search, hearing, room-machine sense, *and* the item radar);
  clairvoyance is the natural scrying home for an item-aura sense. Awareness keeps its trap/door search, the
  noise-system hearing boost, and the room-machine "something of significance" sense — only the floor item
  sense left it.
- **Count made direct & guaranteed (the "but better").** Where awareness did `1 + max(0, enchant − 7)` rolls
  each at `min(90, 10 + 10·(enchant+1))%` (so +1…+7 gave *at most one* coin-flip item), clairvoyance senses
  **exactly N = `rogue.clairvoyance` items, guaranteed** — the ring level *is* the number of auras revealed.
  `enchant` is the raw net enchant (unlike `awarenessBonus`, **not** ×20). **Uncapped** beyond floor contents;
  when more than N eligible items exist, N are chosen at **random** (partial Fisher-Yates). Gated on
  `clairvoyance > 0`; no ring (or a cursed one) senses nothing and draws **no** RNG.
- **No reveal change.** Still `detectMagicOnItem` (polarity), never a full `identify()`. (An interim build
  briefly used `identify()` to read the literal "+enchant level"; that over-revealed floor
  potions/scrolls/rings to their exact kind, so it was reverted to the polarity sense.)
- **Pool includes already-known items (deprioritized).** The eligible pool is *every* non-neutral magical
  floor item — `CAN_BE_DETECTED`, non-neutral — *including* ones whose polarity you already know (identified
  kind, or `ITEM_MAGIC_DETECTED`). A known item can't teach you anything, but lighting its map aura is still a
  location / secret-room breadcrumb (the aura renders in unseen cells). To spend the N well, still-unknown
  items are stable-partitioned to the front and drawn first (learning their polarity); the N only spills onto
  already-known items (location mark only) once the unknowns run out.

**Where.** `Items.c` — `senseFloorPolarityFromAwareness()` renamed to `senseFloorPolarityFromClairvoyance()`.
`RogueMain.c` — the `startLevel()` call + comment. `Rogue.h` — the prototype. `Globals.c` — awareness
`ringTable` description loses the item-aura sentence; clairvoyance gains it.

**Determinism / RNG.** Identical placement/properties to the 2026-06-15 version: self-gated, substantive
gameplay RNG at a fixed point in `startLevel` after item placement and before the level is shown, only sets
existing item/cell flags, no save-format change. SE-only; formula tunable. Recordings from before this change
desync for ring-wearers.

### 2026-06-15 — Ring of awareness senses floor item polarity on arrival (new content) — SUPERSEDED 2026-06-28 (moved to clairvoyance + enchant-level, see entry above)

**What.** Augments the ring of awareness (companion to the room-machine sense above): on *first* arriving at
a level, a worn ring may sense the **good/bad polarity** of magic items lying anywhere on the floor — *secret
rooms included*, since detection sets the `ITEM_DETECTED` cell flag so the aura glyph (`G_GOOD_MAGIC` /
`G_BAD_MAGIC`) shows for items the player hasn't found yet. It's the passive, per-floor analogue of a **thrown
potion of detect magic** (`throwDetectMagicOnFloor`): identical eligibility (any undiscovered, non-neutral,
polarity-bearing floor item) and identical recording via `detectMagicOnItem` — the instance's aura plus, for
kind-flavored consumables, the kind's polarity run-wide (so it feeds elimination deduction, exactly like the
potion). Detected polarity carries into the pack on pickup (`ITEM_MAGIC_DETECTED`). One understated message on
a successful scan: *"your ring tingles; you sense a hidden magical aura on this level."*

- **Scales with awareness, gated on the ring.** `awarenessEnchant = rogue.awarenessBonus / 20` (net effective
  enchant of worn awareness rings, summed; the engine stores it ×20). Per-item chance =
  `min(90, 10 + 10·(enchant+1))` → +1 = 30%, +2 = 40% … **+7 = 90% (cap)**. Rolls = `1 + max(0, enchant − 7)`
  → +1…+7 do **one** roll; +8 does 2, +9 does 3, … Each *successful* roll reveals one more distinct random
  hidden item (partial Fisher-Yates; failed rolls waste no items). Gated on `awarenessBonus > 0`, so no ring —
  or a cursed (senses-dulled) one — senses nothing and draws **no** RNG.
- **First arrival only.** Called from `startLevel()` inside the freshly-generated branch (the `!visited`
  proxy), so the bounce-the-stairs-to-re-roll exploit is closed, same as the machine sense.
- **No visibility filter (deliberate divergence from the thrown potion).** The scan runs *before* the player
  is positioned (no FOV yet), and detecting a soon-to-be-visible item still usefully records its polarity for
  the pack — so unlike a design sketch that excluded visible items, eligibility matches
  `throwDetectMagicOnFloor` exactly. The level is drawn later in `startLevel`, so no `refreshDungeonCell` is
  needed at detection time.

**Why.** Requested — deepen the awareness build with an item-aura radar that pairs naturally with its
existing arrival sense; the secret-room reveal is an intended perk. Folded into the existing `RING_AWARENESS`
rather than a new ring (cohesion, no new enum/table/flavor/frequency tuning).

**Where.** `Items.c` — `senseFloorPolarityFromAwareness()` (mirrors `throwDetectMagicOnFloor`, reuses the
static `detectMagicOnItem` / `itemIdentityFullyKnown`). `RogueMain.c` — a call after the machine-sense block
in `startLevel()` (same gameplay-RNG-stream placement). `Rogue.h` — function declaration. `Globals.c` —
awareness `ringTable` description gains the item-aura sentence.

**Determinism / RNG.** Draws are self-gated (`awarenessBonus > 0` and ≥1 eligible item), on the substantive
gameplay RNG at a fixed point in `startLevel` after item placement and before the level is shown, so they are
replay-deterministic and don't perturb dungeon generation. New detection only sets existing item/cell flags —
no save-format change (saves replay inputs). SE-only; chance/cap/roll formula tunable. Recordings made before
this change desync for ring-wearers, as with any gameplay change.

### 2026-06-12 — Allies keep their distance from invulnerable monsters (cherry-pick: upstream PR #803)

**What.** Cherry-picked the two-part change from upstream BrogueCE **PR #803** (open/unmerged as of
2026-06): allies no longer charge to their deaths against invulnerable enemies (revenants, stone
guardians).
- `monsterFleesFrom()` restructured so the damage-immune-and-mobile avoidance triggers out to **6 tiles**
  (previously the `dist >= 4` early-out fired first, capping it at 4). The `dist >= 4` short-circuit now
  runs *after* the invulnerable check.
- `moveAlly()` blink-to-enemy target scan gains `!attackWouldBeFutile(monst, target)`, so an ally won't
  blink toward a target it can't actually hurt.

**Why.** Requested while reworking allies for the ring of light. Pairs naturally with that feature's
"keep your party alive" theme. Kept faithful to the upstream diff so it can be dropped cleanly if/when
the PR lands and the vendored engine is refreshed — both hunks are marked `// iOS port (iBrogue):
cherry-picked from upstream PR #803`.

**Interaction with the ring of light (same-day change below).** Emboldened allies still flee at the
vanilla low-HP threshold (so they self-preserve), but `moveAlly()` redirects that retreat into a rally
*behind the player* rather than to the generic safety map -- and `monsterFleesFrom()` (this change) still
runs for them, so they keep their distance from revenants/kamikaze/sacrifice targets. Net: an emboldened
ally retreats to heal in your light when hurt and avoids the unkillable enemies, instead of either
scattering or charging to its death.

**Where.** `Monsters.c` — `monsterFleesFrom()` and the second enemy scan in `moveAlly()`. CE-only.
Gameplay/behavior change, so it diverges replay from pre-change recordings (no new RNG draws).

### 2026-06-12 — Ring of light becomes an ally-build cornerstone (new content)

**What.** A worn **ring of light** now does far more than widen your view — its lit radius becomes a
buff aura *and* an invisible-creature detector. The vanilla item only scaled `rogue.lightMultiplier`
(light radius / fade), which is pure upside with no payoff — a "trap" pickup. The rework keeps that and
adds, keyed off a new `rogue.lightRingBonus` (net enchant of worn rings of light; negative if cursed):

- **Emboldened allies.** Any ally standing in the player's light (`IN_FIELD_OF_VIEW` and within
  `effectiveLightAuraRadius()` tiles — see the 2026-06-16 follow-up; originally the map-wide miner's-light
  radius) gets the new `STATUS_EMBOLDENED` status, refreshed
  each vision update and lingering `EMBOLDEN_LINGER` (3) turns after leaving the light (so it fades
  rather than blinks at the dim edge). While emboldened:
  - **Defense** bonus, front-loaded and diminishing toward a ceiling (`EMBOLDEN_DEFENSE_CAP` × E/(E+1),
    cap 20 ≈ two `empowerMonster` levels) — applied in `monsterDefenseAdjusted()`.
  - **Accuracy** small flat `EMBOLDEN_ACCURACY_BONUS` (8) — applied in `monsterAccuracyAdjusted()`.
    **No damage bonus, deliberately** — damage compounds with `empowerMonster` leveling into an
    unbeatable squad; the buff is survivability + presence only.
  - **Courage / rally / backline** — `moveAlly()` extends the attack leash to the aura radius (an
    emboldened ally engages anything in your light). When it *would* flee at low HP, it doesn't scatter to
    the generic safety map (which would lead it *out* of the light, abandoning the defense/regen keeping it
    alive); instead `allyStandoffCell()` sends it to a tile **~2 steps behind you** -- in the light, where it
    heals and waits to re-engage. And even at full HP, a fragile **skirmisher** ally (`allyHoldsBackline()` --
    monkey + common goblin; not tanks like ogres) holds that same standoff cell when *you* are in melee and it
    can't strike this turn, rather than crowding the front rank (the **backline**, see the 2026-06-21
    follow-up). Both fall back to normal behavior if no standoff tile is reachable. The standoff is
    ~2 tiles back (not directly behind) specifically so a spear-style `MA_ATTACKS_PENETRATE` enemy adjacent to
    you can't skewer the ally through you. (Earlier drafts made emboldened allies simply *never* flee; that
    was rejected because our own regen is tuned not to out-heal combat damage, so "never retreat" would have
    gotten allies killed -- the rally preserves self-preservation while keeping them in the buff aura.)
  - **Regeneration** — extra, capped `regenStep` in `decrementMonsterStatus()` (cap
    `EMBOLDEN_REGEN_PERCENT_CAP` 300%). Always-on but recovery-paced: tops off an ally between fights,
    never out-heals focused damage mid-fight (no combat-gating — the engine has no clean combat flag and
    no other regen source is gated).
- **Reveal invisibles.** `playerLightRevealsMonster()` grades by the light's own falloff: invisible
  *enemies* in the **bright core** (inner 60% of the radius) are fully exposed (treated as not hidden →
  translucent, targetable sprite via the existing renderer); in the **dim fade ring** they only flicker
  (`monsterRevealed()` → the existing `X`/`x` render); beyond the light, nothing. Scoped to
  `STATUS_INVISIBLE` enemies (not submerged/dormant, not the player). One-directional and *shared*: the
  player **and** the player's allies see the revealed enemy (allies drop their 33% hesitation in
  `moveAlly()`); an invisible *player* is never revealed to monsters. Because `monsterIsHidden()` also
  governs whip/spear targeting, this incidentally makes reach weapons hit a ring-revealed phantom
  correctly (the concern behind upstream PR #686 / issue #540).
- **Cursed ring (inversion-lite).** A negative `lightRingBonus` (the standard 16% ring curse) shrinks
  your light as before and now also *unsettles* nearby allies: they lose the defense/regen/courage
  (mild defense penalty, flee sooner). No HP drain — a bad roll shouldn't end an ally run.
- **Description + ID.** `ringTable` light description rewritten to state the ally/reveal effect and (for
  the first time, matching its siblings) a cursed clause. Equip-time ID is unchanged
  (`ringIdentifiesOnEquip` already covers light), so the player reads the full effect immediately.

**Why.** Requested — give ring of light a real reason to use without nerfing baseline allies (it
*amplifies* them past baseline rather than fixing them, the way ring of wisdom amplifies staffs) and
without trivializing phantoms globally (the counter is costed, radius-bound, and strictly weaker than
telepathy, which already hard-counters them). Front-loaded so a natural +1–+3 ring is worth wearing;
diminishing-toward-a-ceiling so over-enchanting can't build an invincible army.

**Where.** `Rogue.h` (`STATUS_EMBOLDENED`, `rogue.lightRingBonus`, prototypes);
`Globals.c` (`statusEffectCatalog` "Emboldened" + the previously-implicit AGGRAVATING/REGENERATING
entries; light `ringTable` description); `Items.c` (`updateRingBonuses` sets `lightRingBonus`);
`Monsters.c` (`emboldenmentCurve`/`emboldenmentDefenseBonus`/`emboldenmentAccuracyBonus`,
`playerLightRevealsMonster`, `updateAllyEmboldenment`, clauses in `monsterRevealed`/`monsterIsHidden`/
`allyFlees`/`moveAlly`, regen in `decrementMonsterStatus`); `Combat.c` (defense/accuracy chokepoints);
`Time.c` (`updateVision` drives `updateAllyEmboldenment` after lighting).

**Determinism / saves.** The added `rogue.lightRingBonus` field and `STATUS_EMBOLDENED` don't affect
save format (saves replay inputs). `updateAllyEmboldenment()` is idempotent and derived purely from
deterministic state (positions, light radius), so it reconstructs identically on replay; regen accel
happens once per turn in `decrementMonsterStatus`. Like any gameplay change it diverges replays from
pre-change recordings. CE-only; all magnitudes (`EMBOLDEN_*` defines in `Monsters.c`) are tunable.

**Playtest grants.** `D_LIGHT_RING_START` (`Rogue.h`, default 1) drops a +3 ring of light into the pack
in `initializeRogue()`, mirroring `D_FROST_STAFF_START`. Equip it to activate the aura/reveal.
`D_HEAL_CHARM_START` (default 1) likewise grants a strong +10 charm of health (near-full heal, short
cooldown) for sustaining an ally run during testing. `D_LEATHER_ARMOR_START` (default 1) grants a +50
leather armor (near-invulnerable, so you can test without dying); equip it to wear it.
`D_EMPTY_BOTTLE_START` (default 1) grants a stack of 3 empty bottles (the POTION_DETECT_MAGIC slot) so the
v2 capture system can be tested without first finding one. All are deterministic (not recorded inputs),
so they're replay-safe. Flip to 0 to ship.

### 2026-06-16 — Ring of light aura decoupled from the miner's-light radius (tuning)

**What.** The ally-emboldenment aura, the invisible-creature reveal, and the emboldened-ally attack leash
all keyed off `rogue.minersLight.lightRadius.lowerBound` — the *brightness-fade* radius of the miner's
light. That radius is geometric in depth (`(DCOLS-1) × 0.85^depth`, see `updateMinersLightRadius` in
`Light.c`): ~69 tiles on D1, only collapsing to a tight pool deep in the dungeon. So on shallow floors the
aura covered the **entire level** — allies were emboldened map-wide, invisibles revealed map-wide, and
emboldened allies would chase anything anywhere. The aura was designed assuming a much tighter reach.

**Fix.** New shared helper `effectiveLightAuraRadius()` (`Monsters.c`) returns a tight, depth-independent
reach: `EMBOLDEN_AURA_BASE_RADIUS` (3) `+ abs(rogue.lightRingBonus)`, so a found +3 ring → 6 tiles, a +1 →
4. **Magnitude, not sign, sets the radius** — a cursed −N ring debuffs as wide as an equal +N would buff
(the original `3 + enchant` would have *shrunk* the cursed debuff to zero at −3, an inversion); the callers
still apply polarity. Returns 0 when no ring is worn. The three consumers now read the helper:
`updateAllyEmboldenment()`, `playerLightRevealsMonster()`, and the leash clause in `moveAlly()`. Distance
stays Chebyshev (`distanceBetween`, the engine idiom) and `IN_FIELD_OF_VIEW` still clips the aura to
line-of-sight (walls + closed doors). The reveal's bright-core/dim-fade split (inner 60% = full, outer =
flicker) carries over to the new radius. Everything else (3-turn `EMBOLDEN_LINGER`, the strength curves)
is unchanged.

**Where.** `Monsters.c` (`effectiveLightAuraRadius` + `EMBOLDEN_AURA_BASE_RADIUS`; the three call sites);
`Rogue.h` (prototype).

**Determinism / saves.** Helper is pure state-derived from `rogue.lightRingBonus` (set deterministically
in `updateRingBonuses`), so it replays identically and is safe to call from the display pipeline. No
save-format impact; diverges replays from pre-change recordings like any gameplay tweak.

### 2026-06-11 — Sense when a pursuer gives up the chase (new content)

**What.** When a monster loses the player's trail and reverts from hunting to wandering
(`MONSTER_TRACKING_SCENT -> MONSTER_WANDERING` in `updateMonsterState()`), the player gets a chance to
sense it: `"you sense that <the monster> has lost your trail."` **No line of sight is required** — it's
a pure awareness roll. The chance is `SENSE_LOST_TRAIL_BASE_CHANCE` (20) `+ rogue.awarenessBonus`,
clamped to `[0,100]`. The base is deliberately low so the typical character — who invests nothing in
awareness — only occasionally senses it; a **ring of awareness** (`+20`/enchant) is what makes it
reliable (`+1` → 40%, `+2` → 60%, `+3` → 80%, `+4` → 100%), and a cursed ring suppresses it. Pairs with
the water/scent change: duck out of sight, cross water, and an awareness build learns the coast is clear.

**Why.** Requested — tie "did I shake it?" feedback to the player's awareness, gated so it's a real
payoff for an awareness build rather than near-free. The base was lowered from 50 to 20 (2026-06-14)
because a submerging pursuer spams it: an **eel** standing next to you in water cycles
`TRACKING_SCENT -> WANDERING` every time it submerges (it loses awareness underwater, re-acquires on
surfacing), re-rolling the transition each cycle — at 50% that flooded the log. Line-of-sight gating
was dropped on request (so it also confirms in text even when the monster is visible and its sidebar
already reads `(Wandering)`). Rolled only at the transition (not per turn); it can still re-fire when a
monster re-acquires and loses the player again, which is exactly the eel case — hence the low base.

**Where.** `Monsters.c` — `SENSE_LOST_TRAIL_BASE_CHANCE` define + a block in the
`TRACKING_SCENT && !awareOfPlayer` branch of `updateMonsterState()`. Draws `rand_percent` **only** when
a monster actually loses the trail, keeping RNG-stream perturbation small; deterministic and
reproducible, but like any gameplay/RNG change it diverges replay from pre-change recordings. Minor
caveat: it can name a monster the player never actually saw (it was hunting by scent off-screen);
acceptable as "you sense" flavor, and hallucination still scrambles the name via `monsterName()`. CE-only.

**Update 2026-06-24 — submerged pursuers silenced.** The low base wasn't enough: an eel cycling
`TRACKING_SCENT -> WANDERING` while submerged still occasionally fired the message, reading as spam.
The message is now gated on `!(monst->bookkeepingFlags & MB_SUBMERGED)`, matching the other
submerged-silencing guards (`monsterEmitMovementNoise`, `announcePackRouse`). Crucially the
**substantive** `rand_percent` roll stays unconditional (the `&& !submerged` is appended *after* it),
so the RNG stream is byte-identical to before — this change is fully save/replay- and seed-safe, only
the message output is suppressed.

### 2026-06-11 — Water washes away the player's scent trail (new content)

**What.** `updateScent()` now gates the player's per-turn scent emission on the terrain the player is
standing in (new `playerScentWaterPenalty()` helper in `Time.c`):
- **Deep water** (`T_IS_DEEP_WATER`, when not levitating) — emits **no scent at all** that turn, so the
  scent trail dead-ends at the water's edge. A pursuer that has lost line of sight reverts to wandering
  toward where it last saw the player (the near shore).
- **Shallow water** (`TM_ALLOWS_SUBMERGING && TM_EXTINGUISHES_FIRE`, i.e. any shallow-water variant but
  not deep water; mud/lava excluded since they lack `TM_EXTINGUISHES_FIRE`) — emits a **faint** trail:
  every deposit (the FOV spread and the player's own tile) takes a `SCENT_SHALLOW_WATER_PENALTY` (16,
  in `scentDistance` units ≈ 8 tiles) bump to its `distance`, lowering the stored scent value. The
  trail is followable but liable to be lost via the existing per-turn loss roll in `awareOfTarget()`.
- **Levitating** over either keeps the player dry, so scent is unaffected.

**Why.** Requested — let the player shake pursuers by crossing water, deeper = more reliable. Monsters
hunt by both scent and line of sight (`awarenessDistance()` takes the *min* of scent-on-own-tile and
direct distance when the player is in the monster's FOV), so this only sheds a tracker that **can't see
you** — break line of sight with terrain first, then break the scent with water. `SCENT_SHALLOW_WATER_PENALTY`
is a tunable `#define`.

**Where.** `Time.c` — new `playerScentWaterPenalty()` + `SCENT_SHALLOW_WATER_PENALTY` define, and the
deposit loop in `updateScent()` now adds the penalty / early-returns. No RNG drawn here; deterministic.
Like any gameplay change it diverges replay from pre-change recordings, but draws no new RNG itself.
CE-only.

**Limits / current behavior.** This does **not** guarantee a shed. A monster's awareness is the *min*
of scent-on-its-own-tile and (when the player is in its FOV) direct line-of-sight distance
(`awarenessDistance()`), and water blocks neither vision nor the scent you already laid. So a close
pursuer stays locked: it can see you across the open water, and/or it camps the still-fresh breadcrumb
at the water's edge. Shedding requires *both* breaking line of sight (terrain) *and* enough lead that
the freshest pre-water scent has aged past `stealthRange*2` (~10-turn lead at default stealth via the
+3/turn fade and the 3%/turn loss roll in `awareOfTarget()`; reliable nearer `stealthRange*6`).

**Possible follow-ups (not implemented — noted as options).**
- *Active scent decay while submerged:* have deep water also lower the stored `scentMap` value on the
  monster's tile / at the water's edge over time, so a nearby tracker's lock erodes instead of only
  the trail ceasing to extend. Would let a swim shed a closer pursuer.
- *Degrade the FOV-based lock in/over deep water:* treat a submerged player as harder to see (e.g.
  reduce the sight contribution to `awarenessDistance`), so crossing open water can break a sightline
  lock and not just the scent. Bigger change — touches the vision/awareness path, not just scent.

### 2026-06-11 — Catching fire confuses for 3 turns (new content)

**What.** Any creature (the player included) is confused for `FIRE_CONFUSION_DURATION` (3) turns the
moment it is *initially* set on fire. Applied inside `exposeCreatureToFire`'s `status[STATUS_BURNING]
== 0` branch, so it triggers once on ignition rather than every burning turn, and only for things that
actually catch (fire-immune / submerged / levitating-over-extinguishing-terrain creatures already
early-return before this point). Uses the same `status`/`maxStatus[STATUS_CONFUSED]` path as the
confusion weapon runic.

**Why.** Requested — catching fire should be disorienting; pairs with the panic of needing to reach
water. Note this also confuses the *player* on ignition (3 turns of randomized movement), which is a
real difficulty bump when you're trying to flee to water; tunable via the `#define`.

**Displayed as "Panic".** It's the ordinary `STATUS_CONFUSED` mechanic, but the sidebar status readout
relabels `STATUS_CONFUSED` to "Panic" while the creature is also burning (`IO.c`), since that window is
exactly the fire-induced confusion (confusion lasts 3 turns, burning up to 7). Confusion from other
sources keeps its normal "Confused" label.

**Panic-aware messages (2026-06-18).** The ignition combat message reads "you catch fire and panic"
(was "you catch fire") so the "Panic" status bar has an on-screen cause. The player's `STATUS_CONFUSED`
expiry message in `playerTurnEnded` mirrors the sidebar's condition: "you regain your composure." when
`STATUS_BURNING > 0` (i.e. it was fire-panic), else the normal "you no longer feel confused." Because
panic (3 turns) always ends while burning (7) is still active, this reliably distinguishes fire-panic
from real confusion.

**Where.** `Time.c` — `FIRE_CONFUSION_DURATION` define + one assignment in `exposeCreatureToFire`; the
ignition message and the `STATUS_CONFUSED`-expiry message (in `playerTurnEnded`). `IO.c` — a
`STATUS_CONFUSED` special case in the sidebar status loop renders "Panic" when burning. No RNG drawn;
deterministic, no save/replay impact. CE-only.

**Player exempted (2026-07-02).** Fire-panic is now **monster-only** — catching fire no longer confuses
the player. The `STATUS_CONFUSED` assignment in `exposeCreatureToFire` is guarded by `monst != &player`,
so the hero still catches fire and burns but is not disoriented (fleeing to water stays under the
player's control). Follow-on cleanups: the ignition message reverts to plain "you catch fire" (no
"panic"); the `STATUS_CONFUSED`-expiry message in `playerTurnEnded` reverts to the plain "you no longer
feel confused." (the player can now only be confused by other sources, never fire); and the `IO.c`
"Panic" sidebar label is scoped to `monst != &player` so a player confused by gas/trap *while* burning
still reads "Confused". Monsters are unchanged — they still panic on ignition and show "Panic".

### 2026-06-11 — Subtle progress bars behind inventory rows (new content)

**What.** Each inventory row can now show a faint progress bar tinted into the cells *behind* the
row text. Per category:
- **Weapon / armor / ring** — a **count-down** bar showing use/turns remaining before auto-ID
  (`charges` ÷ the `gameConst` threshold: `weaponKillsToAutoID` / `armorDelayToAutoID` /
  `ringDelayToAutoID`). Shown **only while equipped/worn and still unidentified**; it depletes as ID
  nears and is gone at ID (and for any identified item). Gradient runs dark→light, like the other bars.
- **Staff** — current **charge level**, always shown, including **partial recharge progress** toward
  the next charge (zap → wait → the bar visibly refills). Pre-ID it tracks **a single charge** as one
  continuous bar — full whenever at least one charge is ready (never revealing how many are stockpiled),
  otherwise the recharge progress toward the next charge. Once identified the bar is **split into
  `enchant1` equal segments** (one per charge, separated by 1-cell gaps via `barSegments`): whole
  charges fill whole segments and partial recharge tops off the next, so a 2-charge staff reads 50/50,
  3-charge in thirds, etc. Segment boundaries are placed **proportionally across the full row width**, so
  they tile it exactly — exactly `enchant1` segments with no remainder stub even when the width isn't a
  multiple of the charge count (the segmentation is suppressed if a segment would be narrower than 2
  cells). Partial recharge is derived from `enchant2` (counts down to 0 = next charge) over
  `staffChargeDuration()`. Gradient dark→light.
- **Charm** — **recharge progress** `(rechargeDelay − charges) ÷ rechargeDelay`, shown **only while on
  cooldown** (`charges > 0`); hidden when ready. Gradient dark→light.
- **Wands and everything else** — no bar.

Every bar spans the **full inventory row width** (`maxLength`, the width all rows are padded to), so a
"full" bar is the same physical length on every row and progress is directly comparable between items.

Colors: ID = `gray`, staff = `teal` (blue-cyan), charm = the item's own `foreColor` (charms have no
per-kind color in this engine, so this is the generic item glyph color). The gradient is **chunky** —
the bar-color strength steps up in fixed-width chunks (`INVENTORY_BAR_CHUNK_WIDTH`) rather than a smooth
per-cell fade, mimicking the menu/inventory button gradients — and it blends **toward the bar color, never
toward black** (`INVENTORY_BAR_TINT_MIN` floor), so the dim end is always a visible indication. Tints are
kept low (`INVENTORY_BAR_TINT_MIN`/`MAX`, 12/28) so the row text stays readable on top. The bar renders
**only in the button's normal draw state**, so the focus/press/drag highlight always takes precedence.

**Why.** Requested at-a-glance feedback on the otherwise-invisible auto-ID timers and staff/charm
charge state, without revealing information the player shouldn't have yet (staff max capacity).

**Where.** `Rogue.h` — two new `brogueButton` flags (`B_DRAW_PROGRESS_BAR`, `B_PROGRESS_BAR_FLIP`),
three new `brogueButton` fields (`barColor`, `barFillCells`, `barSegments` — a segment *count*, placed
proportionally over the full width), and the `INVENTORY_BAR_*`
tunables (chunk width, tint min/max). `Buttons.c` — `drawButton()` blends the chunky bar color into the
per-cell background for the leading `barFillCells` cells (skipping segment-boundary gaps), guarded to
`BUTTON_NORMAL`. `Items.c` — new static `setInventoryProgressBar()` computes the bar from item state and
is called per item row in `displayInventory()` after rows are padded to `maxLength` (so it appears in the
main inventory **and** every item-picker prompt, with a uniform full-width track). Purely cosmetic: reads
item state only, no RNG or game state, so no save/replay impact. CE-only; the Classic engine is unchanged.

### 2026-06-11 — Electrified water: lightning struck into water shocks the whole connected body (new content)

**What.** When an electric bolt (`BF_ELECTRIC` — both the staff's `BOLT_LIGHTNING` and the weaker
`BOLT_SPARK` used by turrets, ogre shamans, dar priestesses and pixies) directly strikes a creature
**standing in water**, the charge now floods the entire **connected body of water** and shocks
everything else standing in it. Any caster triggers it (player, monster, turret), and there is **no
friendly-fire exception** — the player wading in the same pool gets zapped by their own bolt.

**Rules.**
- *Trigger:* the bolt must directly hit a non-submerged, non-levitating creature on a water tile.
  A bolt that merely crosses empty water does nothing.
- *Body:* 8-connected flood-fill through connected **deep + shallow** water. Water is detected by
  `TM_ALLOWS_SUBMERGING && TM_EXTINGUISHES_FIRE` — the pair matches deep/shallow/sloshing/luminescent
  water but excludes bog, lava, cooling lava and the sacrificial pit (which share `TM_ALLOWS_SUBMERGING`).
- *Damage:* each shocked creature rolls its own `staffDamage()` (so it scales with staff enchant; spark
  stays weak), multiplied by a **geometric falloff** of `WATER_SHOCK_FALLOFF_PERCENT` (75%) per flood
  ring from the nearest strike point. The spread (and flash) stop at the ring where even a maximum roll
  rounds below 1 — radius scales with bolt strength, bounding huge lakes for free. The directly-struck
  creature takes only its normal direct hit (ring 0 is excluded from the shock); multiple strikes resolve
  as **one shock per body, nearest source wins** (no double-dipping).
- *Submerged creatures (eels) ARE shocked* — this deliberately overrides the usual rule that submerged
  monsters can't be bolt-targeted (`updateBolt`, `Items.c`), making lightning the hard counter to eels.
- *Stun:* anything the shock damages is paralyzed for `WATER_SHOCK_STUN_DURATION` (3) turns — the player
  included (set via `status`/`maxStatus[STATUS_PARALYZED]`, the same path as the paralysis weapon runic).
  **The directly-struck bolt target (ring 0) is stunned too** (amended 2026-06-13): it takes the normal
  bolt hit — ring 0 is excluded from the *spread damage* to avoid double-hitting it — but it's standing in
  the same electrified water, so it still gets the stun (paralysis-only, no extra damage), for both
  monsters and the player. (Originally ring 0 was left unstunned; that was an oversight — a creature
  struck by lightning while in water should be briefly paralyzed.)
- *Levitation:* a creature hovering over water (`STATUS_LEVITATING` / `MONST_FLIES`) is not in contact —
  it neither triggers nor takes the shock. `MONST_INVULNERABLE` creatures are skipped.
- *Feedback:* a cosmetic shockwave flashes the conducting tiles ring-by-ring (dimming with distance) plus
  a one-time-per-bolt "the water crackles with electricity" combat message.

**Why.** Requested content addition — makes water a double-edged tactical element and gives lightning a
purpose against submerging eels.

**Where.** `Items.c` — new statics `isConductiveWater`, `creatureContactsWater`, `electrifyWater`
(multi-source BFS over a `short**` distance grid), the `WATER_SHOCK_*` `#define`s, and two hooks in
`zap()`: the bolt loop records in-water strike tiles (`electricStrikes`), and after the bolt fully
resolves it calls `electrifyWater()`. **Determinism:** damage is applied by iterating the monster list in
fixed order (then the player), so the per-creature RNG draws replay identically; the ring animation is
purely cosmetic and decoupled from damage. CE-only; the Classic engine is unchanged.

### 2026-06-11 — Debug death-recap: count polarity reveals earned by resting

**What.** The on-screen death recap's debug rest readout now shows, per level, `turns/IDs` (rested turns and
the number of polarity reveals resting produced) plus a `rest IDs total`. Verified both rest paths feed the
insight: single rest (`REST_KEY`, IO.c) and long rest (`autoRest`, Time.c) each set `rogue.justRested` and
call `playerTurnEnded`, which calls `gainPolarityInsightFromRest` — so neither path is missing the reveal.

**Why.** Diagnostic — make the passive rest-reveal observable.

**Reworked the threshold.** Replaced the old `90 + 30 × knownPolarityKindCount()` (which counted the
always-identified empty bottle and hidden themed-set potions as "known", skewing pacing) with a flat,
escalating schedule keyed off **reveals already earned this game**: reveal N needs `100 × N` consecutive
rested turns since the last reveal — intervals 100, 200, 300, 400… (cumulative 100, 300, 600, 1000…).
`knownPolarityKindCount` is removed entirely.

**Ring of wisdom.** A worn ring of wisdom makes the polarity machinery scale with its level
(`rogue.wisdomBonus`): the rest-insight threshold is reduced ~10% per level (cursed/negative wisdom slows
it; clamped to at most 80% faster / 2× slower, never below 1 rested turn), and the potion of detect magic
acts on `2 + ring level` items (see the 2026-06-17 entry; was `1–2`, then `1 – (2 + ring level)`). (A
separate exploration-driven "XPXP" reveal channel was considered and tabled.)

**Random target + escalation to full ID.** Both the rest check and the eat-a-meal scroll check now pick a
**random** eligible pack item via a shared helper (`applyPolarityInsightToRandomItem`), and the eligible
pool **includes items whose polarity is already known**: an unknown item gets its polarity revealed; an
already-sensed item gets **fully identified** (`identify()`). Rest considers all polarity categories but
**favors potions first** (restricts the pool to potions whenever any eligible potion is carried); eating
considers **scrolls only**. The rest-turn counter/threshold treat a full-ID the same as a reveal. The
random pick is action-triggered, so it replays deterministically.

**Where.** `Rogue.h` — `levelData.restRevealsOnLevel`. `Items.c` — `gainPolarityInsightFromRest` sums
`restRevealsOnLevel` for the escalating threshold and increments it on each reveal (`knownPolarityKindCount`
deleted). `RogueMain.c` — death-recap readout prints per-level `turns/IDs` and a total. Debug display + a
pacing change; no determinism impact (recomputed identically on replay, like the rest-turn tally).

### 2026-06-11 — Altars of transference: sacrifice an item to pour its enchantment into another (new content)

**What.** A new **random reward vault** (Brogue only), the dangerous sibling of the commutation altar. A linked
pair of altars: place the item you want to empower on the **recipient** altar (west↔east: donor west, recipient
east, one-tile gap — `#....s.o....#`, the same layout as the insight altars) and the item to sacrifice on the
**donor** altar. When both hold items, the donor's enchant level (`+N`) is **added** to the recipient
(*additive concentration* — net enchantment is conserved but pooled onto one item), then the donor is consumed
and both altars go inert.

Where commutation **swaps** two items you keep, this one **consumes one to power up another**. Rules:
- Eligibility matches commutation exactly (`CAN_BE_SWAPPED` = weapon/armor/staff/charm/ring; wands excluded);
  **cross-category is allowed** (feed a junk staff's `+3` into your plate armor).
- The **recipient must have a known enchant level**, else the altar stays primed — you always understand and can
  read the item you're improving.
- Sacrificing a donor with an **unknown** enchant is the gamble: it might be cursed (a negative donor *lowers*
  the recipient). The donor is `identify()`d as it's consumed, so the gamble resolves visibly.
- A donor whose enchant is **known and ≤ 0** is refused (pure-downside misclick guard) — only an *unknown* donor
  can ever hurt the recipient.
- Because the recipient normally only moves *up* and the donor vanishes, the usual `swapItemToEnchantLevel`
  shatter cases don't apply — **except** a deep negative gamble onto a staff/charm recipient, which is detected
  up front (predict-then-branch) so the now-unlinked item is never named after it shatters.

"Fire only if it helps" (except the deliberate unknown-donor gamble). RNG-free, so replays are unaffected.

**Where.** Modeled throughout on the altars-of-insight content (2026-06-10 entry):
- `Rogue.h`: `tileType` — `TRANSFER_ALTAR_DONOR` / `TRANSFER_ALTAR_RECIPIENT` / `TRANSFER_ALTAR_INERT`;
  `dungeonFeatureType` — `DF_ALTAR_TRANSFER_INERT`; `TM_TRANSFER_ENCHANT_ACTIVATION = Fl(27)`; `machineTypes` —
  a **genuine new index** `MT_TRANSFER_ALTAR` appended after `MT_REWARD_HEAVY_OR_RUNIC_WEAPON`. It exists only in
  Brogue's `blueprintCatalog` (which gains one entry, so `numberBlueprints` 73 → 74); the Bullet/Rapid catalogs
  stop at the variant weapon slot, so their reward raffle never reaches the index and it's never built there.
- `Globals.c`: `violetAltarBackColor`; three `tileCatalog` rows (model on `INSIGHT_ALTAR_*`); a
  `DF_ALTAR_TRANSFER_INERT` `dungeonFeatureCatalog` row (empty message — the result text is emitted once by the
  handler, not per promoted altar).
- `GlobalsBrogue.c`: the transference blueprint, appended last (depth 11–`AMULET_LEVEL`, freq 30, `BP_REWARD`).
  Like the insight blueprint it builds **only** the carpeted room; the altar pair is placed afterward.
  **2026-06-16:** frequency temporarily set to `0` (`0/*was 30*/`) for this release so the altar never enters
  the blueprint raffle — i.e. it never appears. Restore to `30` to re-enable. All transference code is intact;
  only the raffle weight changed.
- `Architect.c`: the insight placement helpers were **generalized** — `insightAltarCellIsOpen` →
  `altarPairCellIsOpen`, `setInsightAltar` → `setAltarTile`, `placeInsightAltarsInRoom(min)` →
  `placeAltarPairInRoom(min, westAltar, eastAltar, statueAbove)` (insight call site updated to pass its two
  tiles and `statueAbove = false`). The transference altar is **raffle-built**, so it can't be hooked from
  `addMachines` (which doesn't learn which blueprint the raffle picked); instead `buildAMachine` calls
  `placeAltarPairInRoom` on its success path when `bp == MT_TRANSFER_ALTAR` (Brogue-guarded), passing
  `machineNumber - 1` and `statueAbove = true`. The `statueAbove` flag drops a `STATUE_INERT` on the open
  carpet cell directly **north of each altar** (so the room reads `S . S` / `d . r`), making it
  unmistakable at a glance from the bare altar/gap/altar layout of the insight and commutation rooms; it's
  skipped per-altar if the north cell isn't open interior carpet.
- `Items.c`: `static boolean performEnchantTransfer(short)` (defined just after `performInsightSacrifice`,
  forward-declared beside it) + a sibling block in `updateFloorItems`, modeled on the commutation/insight blocks.

**Determinism / saves.** The handler and placement are RNG-free; the only RNG impact is that adding one
`BP_REWARD` blueprint to the raffle changes which reward room a given seed rolls at depth 11+ (a content change,
like adding the insight altars). No serialized-state change. **Bump `recordingVersionString` at release.**

### 2026-06-11 — Remove candidate-narrowing readout; render the empty bottle without "potion of"

**What.**
- Removed the "You have narrowed it down to one of N remaining…" inspect line for unidentified
  potions/scrolls (reverts the 2026-06-10 candidate-narrowing entry below). It added no value and read
  confusingly next to the themed potion sets. The silent last-kind auto-ID (`tryIdentifyLastItemKinds`)
  is left intact.
- The empty bottle now renders as just **"empty bottle" / "empty bottles"** instead of "potion of empty
  bottle".

**Why.** Player request — the narrowing readout wasn't fully thought through; and the empty bottle isn't a
"potion of" anything.

**Where.** `Items.c` — deleted `candidateKindCount` (and its forward prototype) and the render block in
`itemDetails`; special-cased `POTION_DETECT_MAGIC` in `itemName` to print "empty bottle%s" rather than
"potion%s of %s". Display only; no RNG, no determinism impact.

### 2026-06-11 — Themed potion sets + returning detect magic

**What.** Five new potions (enum grows 16 → 21, all frequency 10), in two mutually-exclusive themed
sets plus an always-present reworked detect magic:

- **Set 1** — **honey** (good): drinking grants `STATUS_REGENERATING`, metering ~20% of max HP over
  ~20 turns; thrown or bolt-hit it shatters into a `DF_NET` (`NETTING`) sticky patch that entangles.
  **vomit** (bad): thrown/bolt-hit → `DF_ROT_GAS_PUFF` nausea cloud; drunk → that cloud at your feet.
- **Set 2** — **wort** (good): drink/throw spawn `DF_LIFE_POTION_CLOUD` (healing cloud); this is also
  what the empty bottle's wort capture now yields (was potion of life). **venom** (bad): drink poisons
  the player (`addPoison(&player, ~15, 1)`); thrown it poisons the creature it strikes, else shatters
  harmlessly.
- **detect magic** (good, new kind `POTION_DETECT_MAGIC2` — the old slot is the empty bottle): drinking
  acts on 1–2 random unidentified polarity-bearing pack items — revealing each one's polarity, or fully
  identifying it if its polarity is already known (same reveal-or-escalate rule as resting/eating, via the
  shared `revealOrIdentifyPolarityItem` helper).

**One set per run.** `shuffleFlavors` draws `rogue.activePotionSet = rand_range(0,1)` (deterministic from
the seed, reproduced on replay). The inactive set's two potions are marked **absent this seed** (a static
`potionAbsentThisSeed[]` in Items.c): skipped by generation (`chooseKind`) and the Discoveries screen
(`IO.c`), and pre-identified so they cancel out of the good/bad polarity deduction. **Exception:** wort is
always producible by empty-bottle capture; `fillEmptyBottle` clears its absent flag when minted.

**Why.** Expands the potion pool and makes the lineup vary run to run, while bringing back detect magic in
a weaker RNG form. Decisions settled via design grilling. **iOS-only, all three variants.**

**Where.**
- `Rogue.h` — 5 new `POTION_*` kinds; `STATUS_REGENERATING`; `rogue.activePotionSet`; proto
  `potionKindAbsentThisSeed`.
- `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — 5 rows in each `potionTable_*`
  (colors `itemColors[17..20]` + `[0]`), 5 index-parallel `meteredItemsGenerationTable_*` entries, and
  `numberGoodPotionKinds` 8 → **11** (count only — good kinds are no longer contiguous).
- `Items.c` — `drinkPotion` (5 cases); `shatterPotionAtLoc` (honey/vomit/wort); `throwItem` venom-on-strike
  and a **polarity-based** good-potion gate (replaces the `kind < numberGoodPotionKinds` index boundary,
  which assumed contiguous good kinds); `magicCharDiscoverySuffix` (vomit/venom → bad); `quaffDetectMagic`;
  `emptyBottleCaptureKindForTile` (`HEALING_CLOUD` → `POTION_WORT`); `shuffleFlavors` set selection;
  `chooseKind` + `fillEmptyBottle` honor `potionAbsentThisSeed`.
- `Time.c` — `STATUS_REGENERATING` per-turn heal (stateless elapsed-fraction metering) + expiry.
- `IO.c` — `printDiscoveries` skips absent potion kinds (separate display-row counter, no gap).

**Determinism.** `shuffleFlavors` now draws an extra `rand_range` (set selection), `quaffDetectMagic` and
venom throws draw, and there are new potion kinds — so item-generation/ID RNG diverges from old recordings.
**Bump `recordingVersionString` at release.** Set selection and absence are recomputed deterministically
from the seed each load; no new serialized state (`rogue.activePotionSet` is derived, not saved).

### 2026-06-11 — Insight altars: place the pair side by side in a fixed s . o layout

**What.** The two altars-of-insight no longer land at random spots in the reward room. They are placed in
a consistent arrangement: the **sacrifice/payment** altar to the west, a one-tile walkable gap, then the
**insight** (offered-item) altar to the east — `#....s.o....#`. The room is also smaller now.

**Why.** The pair read as inconsistent and scattered, making the mechanic hard to parse. A fixed,
adjacent s→o layout makes the room instantly legible. The smaller room also fits into level generation
more easily.

**Where.**
- `GlobalsBrogue.c` — the insight blueprint (`blueprintCatalog_Brogue`, the `MT_INSIGHT_ALTAR` slot) now
  builds **only** the carpeted room: the two altar `machineFeature` rows were removed (featureCount 5 → 3)
  and `roomSize` shrank from `{7, 30}` to `{7, 14}`.
- `Architect.c` — a `placeAltarPairInRoom(min, westAltar, eastAltar)` (with helpers `altarPairCellIsOpen` /
  `setAltarTile`) places the pair after the room is built, called from the `addMachines` force-build
  right after `buildAMachine(MT_INSIGHT_ALTAR, …)` succeeds with `INSIGHT_ALTAR_PAYMENT` (west) +
  `INSIGHT_ALTAR_INSIGHT` (east). (Originally named `placeInsightAltarsInRoom` / `insightAltarCellIsOpen` /
  `setInsightAltar`; generalized 2026-06-11 to be shared with the altars of transference.) It finds the just-built room's carpet cells
  (machineNumber greater than the value captured before the build), picks the horizontal run of three open
  cells nearest the room center, and drops `INSIGHT_ALTAR_PAYMENT` (west) + `INSIGHT_ALTAR_INSIGHT` (east,
  one gap). Fallbacks: an adjacent pair, then any two open cells, so the altars always exist.

**Determinism.** The placement helper uses **no RNG** (a deterministic scan), so it doesn't perturb the
seed stream. But removing the two altar features and shrinking `roomSize` changes what `buildAMachine`
draws, so generation diverges from pre-change recordings — a `recordingVersionString` bump at release is
warranted (the diff doesn't bump it). **Brogue variant only / iOS-only — not contributed to a fork branch.**

### 2026-06-11 — Replace potion of detect magic with the Empty Bottle

**What.** The `POTION_DETECT_MAGIC` slot is repurposed into an always-identified **empty bottle** that
captures dungeon elements and becomes the matching potion (already known, which also identifies any
matching unidentified potions in the pack):

- **Apply capture** (gases / deep water): *applying* (drinking) the empty bottle while standing on a
  catchable gas or deep water transforms it into the mapped potion — caustic→caustic gas,
  confusion→confusion, paralysis→paralysis, rot→creeping death, darkness cloud→darkness, healing
  spores→life, deep water→fire immunity. A turn passes and the bottle becomes that potion (not consumed).
  With nothing catchable underfoot it stays a benign empty bottle and no turn is spent. (Capture is on
  apply, by player choice — never automatic.)
- **Bolt capture** (drop the bottle, zap it): a lightning bolt → speed, a fire bolt → incineration. This
  reuses the existing bolt-through-potion hook in `updateBolt` and absorbs the bolt exactly as a detonating
  bad potion does.

**Why.** Design/testing request: detect magic was a weak, passive pick. The empty bottle keeps its
identification role but makes it active — you learn a potion type by harvesting a hazard. The enum
`POTION_DETECT_MAGIC` is kept as the internal kind (a rename would be high-churn); it is relabeled
"empty bottle" in the item tables. **iOS-only, all three variants** (Brogue/Rapid/Bullet).

**Where.**
- `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — the `"detect magic"` row becomes
  `"empty bottle"` with a new description; Brogue's `frequency` is restored **10 → 20** (Rapid/Bullet were
  already 20).
- `Items.c` `shuffleFlavors` — force `potionTable[POTION_DETECT_MAGIC].identified` (and
  `magicPolarityRevealed`) true each game so the bottle is always known and never joins the ID pool.
- `Items.c` new `fillEmptyBottle()` (near `shatterPotionAtLoc`) — shared transform→message→`autoIdentify`
  helper; prototype in `Rogue.h`. New static `emptyBottleCaptureKindForTile()` maps the gas/liquid on a
  tile to the captured potion kind + flavor.
- `Items.c` `updateBolt` — empty-bottle branch *before* `shatterPotionAtLoc`, keyed on `BF_ELECTRIC`/`BF_FIERY`,
  sets `terminateBolt = true`.
- `Items.c` `drinkPotion` — the `POTION_DETECT_MAGIC` case is the **apply capture**: if the player's tile
  holds a catchable element it records the apply command, calls `fillEmptyBottle`, then re-adds the item
  via `removeItemFromChain` + `addItemToPack` so the new potion **stacks** into an existing same-kind stack
  instead of taking a bespoke inventory slot, and returns `true` (a turn passes, bottle not consumed);
  otherwise it prints "the bottle is empty…" and returns `false` (benign, no turn). The bolt-capture path
  leaves its bottle on the floor, where normal pickup already stacks it. Replaces the old detect-magic quaff
  effect.

**Determinism.** Generation behavior changes (frequency, and the kind is now always-identified), so the
weighted pick / ID bookkeeping diverge from pre-change recordings — a `recordingVersionString` bump at
release is warranted. Capture mutates only existing item/level state (no new RNG call sites). Removing
detect magic from the unidentified-potion pool slightly shifts the `tryIdentifyLastItemKinds` deduction
counts (one fewer good potion to deduce) — intended.

### 2026-06-13 — Empty Bottle v2: broad capture + capture-only potions

**What.** Expands the empty bottle from 9 capture outcomes to a broad "bottle the hazard you're in"
system, adds **five capture-only potions** (never generated — only obtainable by capture), and surfaces
the mapping in-game. Full design: `docs/design/empty-bottle-v2.md`; terrain reference:
`docs/game-data/TERRAIN_AUDIT.md`.

- **Capture-only potions** (frequency 0, always-identified): `POTION_ACID`, `POTION_WEBBING`,
  `POTION_STEAM`, `POTION_ICE`, `POTION_WATER`. Each re-creates its hazard when thrown/uncorked:
  acid → `weaken()` the struck creature (defense −25/pt + accuracy/damage down) and an acid splatter;
  webbing → `DF_WEB_LARGE`; steam → `DF_STEAM_PUFF`; ice → freeze the struck creature (shared frost
  semantics); water → `DF_FLOOD` puddle.
- **Capture precedence `GAS > SURFACE > LIQUID`** (deterministic, no prompt). New gas mappings:
  stench/smoke → vomit, methane → incineration, steam → steam. New surface mappings: embers → fire
  immunity (residue of fire-immune creatures), acid splatter → acid, web/net → webbing. New liquid
  mappings: deep/shallow water → water (**replaces** the old deep-water → fire immunity), ice → ice,
  brimstone → incineration.
- **Levitation skim** (captured only while `STATUS_LEVITATING` over an un-standable tile): lava →
  incineration, any `T_AUTO_DESCENT` tile → descent.
- **Discoverability:** the bottle's description states the general rule; a once-per-kind contextual
  message names the exact potion the tile underfoot would yield while carrying an empty bottle.

**Why.** Many walkable liquids/surfaces and several gases were uncapturable in v1 (only deep water +
GAS). v2 makes terrain engagement rewarding and gives the bottle a small exclusive toolkit, without
diluting the natural loot table (freq 0). Fire immunity moved from deep water (indirect) to embers (the
residue of things that can't burn). Brogue's transparency ethos: surface the exact mapping in-game.

**Where.**
- `Rogue.h` — 5 new `enum potionKind` values; `rogue.emptyBottleHintedKinds` (per-kind hint bitmask);
  `showEmptyBottleCaptureHint` prototype.
- `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — 5 freq-0 potion rows; empty
  bottle description rewritten to the v2 general rule. (`numberPotionKinds` auto-sizes via `sizeof`.)
- `Items.c` — `shuffleFlavors` force-IDs the 5 new kinds; `magicCharDiscoverySuffix` marks them bad;
  new static `freezeCreature()` extracted from the `BE_FREEZE` bolt case and shared with the ice potion;
  `emptyBottleCaptureKindForTile` rewritten with the full precedence + levitation branch;
  `shatterPotionAtLoc` gains steam/water/webbing/acid; `throwItem` gains acid (weaken) + ice (freeze)
  struck-creature cases; `drinkPotion` gains the 5 self-effects; new `showEmptyBottleCaptureHint`.
- `Time.c` — `playerTurnEnded` calls `showEmptyBottleCaptureHint` (after `monstersFall`).

**Determinism.** Captures and the hint use **no RNG** (the hint is pure messaging keyed off the same
capture mapping; its bitmask is zeroed by the game-start `memset(&rogue)` and evolves deterministically
from player position). The thrown/quaffed effects draw the same RNG as the hazards they reproduce
(`DF_FLOOD`, `DF_STEAM_PUFF`, `weaken`, freeze), so they're replay-safe by construction. New potion
kinds change the generation stream / table sizes / `shuffleFlavors` ID bookkeeping, and add new gameplay
effects → **bump `recordingVersionString` at release**; pre-v2 recordings won't replay. **CE only / all
three variants — Classic 1.7.5 untouched (the empty bottle is CE-only).**

**Potion of ice → freezing cloud (refinement).** Thrown/uncorked ice now bursts into a persistent
**freezing cloud** instead of a single-target hit. New `FROST_GAS` gas tile (appended at the end of
`enum tileType` / `tileCatalog` so no existing index shifts) carries a new terrain flag `T_CAUSES_FREEZE`
(`Fl(22)`, added to `T_HARMFUL_TERRAIN`) + `TM_EXTINGUISHES_FIRE` + quick dissipation. New
`DF_FREEZING_CLOUD_POTION` spawns it. `Time.c` `applyInstantTileEffectsToCreature` gains a
`T_CAUSES_FREEZE` block (outside the armor-of-respiration gate — external cold, not an inhaled toxin)
that calls the now-shared, non-static **`freezeCreature(monst, freezeTurns, slowTurns)`** (extracted from
the `BE_FREEZE` bolt case; signature changed from a fixpt enchant to explicit turns; message/flash
de-spammed to fire only on the transition into frozen). Cloud effect: freeze 3 turns → ~5-turn slow
tail, douses flame (the gas tile's `TM_EXTINGUISHES_FIRE`). On shatter/uncork a `spawnFrostCloud(x,y)`
helper also spawns `DF_DEEP_WATER_FREEZE`/`DF_SHALLOW_WATER_FREEZE` (no-ops on dry land) so the cloud
**freezes a sheet over any water it covers** — and because the shatter path is shared with the
bolt-detonation hook, a dropped ice bottle struck by a lightning/fire bolt is a water-freeze **trap**.
No RNG beyond what those DFs already draw.

### 2026-06-13 — Thrown potion of telepathy bonds to the struck creature

**What.** A thrown potion of telepathy that strikes a (non-inanimate) creature now **permanently
reveals that single creature** on the map — it stays telepathically visible wherever it roams, for
the rest of its life — and the potion auto-identifies. Previously a thrown telepathy did nothing
(splashed harmlessly). Drinking is unchanged (brief, level-wide reveal of all creatures).

**Why.** Gives the otherwise throw-useless telepathy potion a deliberate offensive/utility use:
trade the drink's breadth-but-brief reveal for a single *permanent* tracker on a chosen target (e.g.
tag a fleeing treasure monster or a dangerous out-of-depth threat). Permanent (no countdown) was the
chosen design — simpler than a timed bond and no decrement wiring.

**Where.**
- `Items.c` `applyPotionEffectToCreature` — new `POTION_TELEPATHY` case: sets
  `MB_TELEPATHICALLY_REVEALED` on the struck creature (the same flag used for ally telepathic bonds;
  `monsterRevealed` already honors it, so `updateTelepathy` reveals it with no further plumbing),
  refreshes the cell, and returns true so `throwItem`'s benevolent-throw path consumes + auto-IDs the
  flask. Inanimate creatures (turrets/totems) are excluded (returns false → harmless splash), matching
  the drink's "won't reveal inanimate" flavor.
- `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — telepathy description gains a
  sentence about the thrown bond.

**Determinism.** Sets an existing bookkeeping flag on a throw (a recorded input); no RNG, no new
serialized state. Replay-safe. (A new gameplay effect still warrants the standard
`recordingVersionString` bump bundled with the other v2 changes.)

### 2026-06-13 — Thrown potion of detect magic scouts the dungeon floor

**What.** A thrown potion of detect magic now turns its insight **outward**: instead of reading 1-2
items in your pack (the drink, `quaffDetectMagic`), it senses **1-2 random undiscovered, polarity-
bearing items lying on the dungeon floor**, revealing each one's good/bad polarity and **marking its
aura on the map** (even for items you haven't found). Fires wherever the flask lands — creature or bare
ground. Same 1-2 base count as the drink (widened by a worn ring of wisdom). Drinking is unchanged.

**Why.** Gave the throw-useless detect magic a real use: a limited "detect magic on the level" scout
that points you at the good loot (or warns of cursed items) without spending the drink. Pairs naturally
with the potion's identification role.

**Where.**
- `Items.c` new static `throwDetectMagicOnFloor()` (near `quaffDetectMagic`): scans `floorItems` for
  unidentified, not-yet-`ITEM_MAGIC_DETECTED`, non-neutral-polarity items; partial Fisher-Yates picks
  `rand_range(1, max(1, 2 + wisdomBonus))`; calls `detectMagicOnItem` on each and sets the cell's
  `ITEM_DETECTED` flag so the aura glyph shows on the map; `tryIdentifyLastItemKinds` + a count message.
  Forward-declared above `throwItem`, which gains a `POTION_DETECT_MAGIC2` case that calls it then
  auto-IDs/consumes the flask (fires regardless of `struck`).
- `GlobalsBrogue.c` / `GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — detect magic description gains
  a sentence about the thrown, outward scouting.

**Determinism.** `rand_range` draws here are action-triggered (the throw) and reproduced identically on
replay, exactly like the drink's draws. No new serialized state. Same release-time
`recordingVersionString` bump as the rest of the v2 work.

### 2026-06-13 — Thrown weapons detonate dropped potions (cheap potion-trap triggers)

**What.** A thrown weapon that lands on a dropped bad/cloud potion now **detonates** it, the same way a
staff bolt does — giving a cheap, ammo-based way to set off a potion trap from range:
- **Incendiary dart → like a fire bolt:** the potion's cloud spawns, then the dart's own blast
  (`DF_DART_EXPLOSION`, fire) ignites the flammable cloud — a violent burst. Works even when the dart
  strikes a creature standing on the potion (incendiary darts already explode on the tile they hit).
- **Dart / javelin → like a lightning bolt:** the cloud blooms but nothing ignites it (no fire applied);
  the weapon then drops as usual.

Good potions (no shatter signature) and the empty bottle are left untouched — a dart isn't a bolt, so
it can't capture into the bottle.

**Why.** Extends the existing "zap a dropped potion to detonate it" play to thrown weapons, which are
cheaper and more plentiful than staff charges. Incendiary = violent (fire), plain dart/javelin = gentle
(no fire), mirroring the fire-vs-lightning bolt distinction.

**Where.** `Items.c` new static `detonateFloorPotionAt(x, y)` (just above `throwItem`): finds a floor
potion at the tile and runs the shared `shatterPotionAtLoc`, then removes the flask (mirrors the bolt
hook's remove/delete). `throwItem` calls it in the `INCENDIARY_DART` landing block (before spawning the
dart's fire blast, so the cloud is present to ignite) and in a new `DART`/`JAVELIN` check just before the
weapon is dropped. The bolt detonation path in `updateBolt` is unchanged.

**Determinism.** Detonation runs the same RNG `shatterPotionAtLoc` already draws (gas volumes, etc.),
action-triggered by the throw; no new serialized state. Same release-time `recordingVersionString` bump.

### 2026-06-13 — A fire-detonated gas-cloud potion reveals polarity, not full ID

**What.** When a fire trigger (fire bolt or incendiary dart) detonates an unidentified potion whose
signature is a **flammable gas cloud** (poison / confusion / paralysis / vomit), the flame instantly
consumes the cloud — so you no longer **fully identify** the potion; instead you learn only its
**polarity** (good/bad), and the message is generic (*"the volatile flask bursts into flame — you sense
its contents were malevolent."*) rather than naming the cloud. **Incineration** is also erased (added
2026-06-13): its tell *is* fire, which the fire trigger's own flame masks completely — you can't tell an
incinerated potion from the fire bolt / incendiary-dart burst that lit it — so it too reveals only
polarity on a fire trigger. Every other detonation still fully IDs: non-fire triggers (lightning,
dart/javelin, hand-throw) of any potion, and fire triggers of potions whose effect is self-evident
(wort's healing cloud, honey's mire, darkness, descent's hole, a flood, lichen, the fungal forest,
steam, ice, acid).

**Why.** A fire blast erases a gas cloud's tell — you see flame, not a purple poison cloud — so a free
full ID was unearned; the volatility is still legible, hence polarity. Effects the fire *doesn't* erase
give the kind away on their own, so those keep full ID. (Player request.)

**Where.** `Items.c`:
- `shatterPotionAtLoc` gained a `boolean fiery` parameter and now **defers** its per-kind message into a
  local (`shatterMsg`) so it can be suppressed. After spawning the signature it computes
  `fireErasedKind = fiery && (the GAS layer at the tile is flammable || kind == POTION_INCINERATION)`
  (data-driven on the gas tile's own `T_IS_FLAMMABLE`, checked on the GAS layer specifically so honey's
  flammable SURFACE net doesn't qualify, plus incineration explicitly — its fire signature sits on the
  SURFACE layer and matching `T_IS_FIRE` broadly would wrongly catch any potion detonated on already-
  burning ground). If erased and not already identified, it reveals polarity via `detectMagicOnItem` (+ a
  generic, polarity-announcing message, gated on `playerCanSee`) instead of `autoIdentify`; otherwise it
  prints the kind message and `autoIdentify`s as before.
- Callers pass `fiery`: `updateBolt` → `(theBolt->flags & BF_FIERY)`; `detonateFloorPotionAt` gained a
  `fiery` param (incendiary dart → true, dart/javelin → false); the hand-thrown shatter in `throwItem`
  → false. Forward-declared `detectMagicOnItem` for use before its definition.

**Determinism.** Polarity reveal vs. full ID are both deterministic, action-triggered state changes; no
RNG difference. The visibility gate keys on deterministic state. Same release-time
`recordingVersionString` bump as the rest of the v2 work.

### 2026-06-13 — Witnessing a scroll burn reveals its polarity (the scroll-side fire-erasure tell)

**What.** When a flammable item is destroyed by fire **in the player's view**, you glimpse its good/bad
**polarity** (not its kind): *"as it burns you glimpse a malevolent aura curling in the smoke — its magic
was ill."* Scrolls are the only `ITEM_FLAMMABLE` item, so in practice this is scrolls caught by an
incineration burst, a fire trap, or flaming gas. It is the scroll-side analogue of the potion
fire-erasure tell above — you never burn a scroll on purpose, so the insight comes from *witnessing* the
accident, not from a deliberate sacrifice. The reveal escalates through the usual machinery: it persists
at the kind level (`magicPolarityRevealed`), arms the item for a later full ID via the escalation rule,
and runs the elimination pass (`tryIdentifyLastItemKinds`). Already-identified, neutral-polarity, or
already-polarity-known kinds glimpse nothing.

**Why.** Scrolls had no destruction tell — potions get fully ID'd (or polarity-revealed) when thrown,
shattered, or detonated, but a burning scroll just vanished with no information. This closes that
asymmetry without adding a new player verb. First implemented item from
`docs/design/identification-future-ideas.md` (idea A); environmental-hazard reveal, to be extended to
acid later.

**Where.**
- `Items.c`: new non-static `revealPolarityOnFieryDestruction(item *)` (beside `detectMagicOnItem`).
  Gates on `HAS_INTRINSIC_POLARITY`, not yet `ITEM_IDENTIFIED`, and non-neutral `itemMagicPolarity`;
  captures `magicPolarityRevealed` *before* calling `detectMagicOnItem`, then (only if newly revealed)
  runs `tryIdentifyLastItemKinds(HAS_INTRINSIC_POLARITY)` and prints the polarity-colored aura line.
  Returns true on a fresh glimpse. Lives in `Items.c` for access to the `static` detect/identify helpers.
- `Time.c`: `burnItem` now prints the destruction message and calls `revealPolarityOnFieryDestruction`
  **before** `deleteItem` frees the instance (the helper reads `theItem->kind`), both gated on the
  existing `playerCanSee`. Order: destruction line, then the insight.
- `Rogue.h`: forward declaration beside `burnItem`.

**Determinism.** No RNG added; the reveal is a deterministic, action-triggered state change driven by the
deterministic fire-processing path, gated on deterministic visibility. Saves are recordings — no new
struct fields, replay-safe.

### 2026-06-13 — A freed captive senses a pack item's polarity (monkey covets, others recoil)

**What.** Freeing a captive now reveals the good/bad **polarity** (not the kind) of one item in your
pack: a **monkey**, a thief at heart, eyes your best loot — *"the monkey eyes a scroll titled 'XYZ' in
your pack covetously."* (a **benevolent** item) — while **any other** rescued creature recoils from the
worst thing you carry — *"the goblin shies warily from a [potion] in your pack."* (a **malevolent**
item). One tell per rescue, polarity only (no full ID), targeting the first carried item of the relevant
sign whose aura you don't already know. Because the two signs can never land on the same item, the
monkey's covet and the generic recoil are complementary, not competing. Silent no-op when nothing of that
sign is sensed — by design, especially the malevolent recoil when you carry no curses.

**Why.** First pass at the "ally/captive tell" idea from
`docs/design/identification-future-ideas.md` (ideas B + D). Rescue → reward is a core Brogue pattern, and
this gives captives a non-combat value. It leans on **polarity** rather than the monkey's narrow
`rateItemStealDesirability` profile (which only flags food / life / strength), so *any* good item — a
ring, staff, charm — can catch the monkey's eye. Bonding is too slow to rely on, so the trigger is the
moment of **rescue**, not a developed bond.

**Where.**
- `Items.c`: new non-static `captiveReactToPack(creature *freed)` (beside
  `revealPolarityOnFieryDestruction`). Picks the sensed sign from `monsterID` (`MK_MONKEY` → benevolent,
  else malevolent), scans `packItems` for the first `HAS_INTRINSIC_POLARITY`, not-`ITEM_IDENTIFIED` item
  of that sign whose polarity isn't already known, then `detectMagicOnItem` + `tryIdentifyLastItemKinds`
  and prints the monster/item-named, polarity-colored line. Lives in `Items.c` for the `static`
  detect/identify helpers and the `MAGIC_POLARITY_*` constants (both file-local to `Items.c`).
- `Movement.c`: `freeCaptive` calls `captiveReactToPack(monst)` after the "you free the grateful…"
  message. This also covers tunnel-freed captives (`freeCaptivesEmbeddedAt` → `freeCaptive`); it does
  *not* fire for captives turned ally by cloning (`becomeAllyWith` directly), which isn't a rescue.
- `Rogue.h`: forward declaration beside `revealPolarityOnFieryDestruction`.

**Determinism.** No RNG (`itemMagicPolarity` is only ±1/0, so there is no finer "strongest" gradient —
first-in-pack-order is the deterministic choice). Action-triggered state change; saves are recordings, no
new struct fields, replay-safe.

### 2026-06-13 — Fix: insight channels re-"identified" an already-known scroll/potion

**What.** Eating (and, latently, resting, detect-magic drink/throw, and the insight altar) could pick an
item whose **kind was already fully identified** and announce *"…and finally identify <X>."* again —
reported after a fully-identified scroll of enchanting was "studied" while eating.

**Why.** The selection guards tested only the per-**item** `ITEM_IDENTIFIED` flag, but flavored
consumables record full identity at the **kind** level (`scrollTable[kind].identified` /
`potionTable[kind].identified`). `identify()` stamps the instance flag only on the *one* item it is
handed (`Items.c` `identify`), so a *copy* of an already-identified scroll/potion (kind known, instance
flag clear — e.g. a leftover from a stack, or one picked up after the kind was learned) passed the
"unidentified" filter, got selected, and `revealOrIdentifyPolarityItem` saw its polarity as known (the
kind table says so) and called `identify()` redundantly, firing the bogus message.

**Where.** `Items.c`: new `static boolean itemIdentityFullyKnown(const item *)` — true if the instance
flag is set, **or** (for `SCROLL`/`POTION`) the kind table is identified. Rings/wands/staffs still carry a
per-item enchant/charge count, so for them kind-knowledge isn't full knowledge and only the instance flag
counts — they remain eligible so insight can still finish them. Replaced the bare `flags & ITEM_IDENTIFIED`
test with `itemIdentityFullyKnown` in every polarity-bearing selection/escalation guard:
`applyPolarityInsightToRandomItem` (rest + eating; both the potion pre-scan and the eligibility scan),
`quaffDetectMagic`, `throwDetectMagicOnFloor` (kept the separate `ITEM_MAGIC_DETECTED` floor check),
`performInsightSacrifice` (the payment "gamble" test and the insight-item guard), and the two new tells
(`revealPolarityOnFieryDestruction`, `captiveReactToPack`).

**Determinism.** Pure guard tightening; no RNG, no new state, replay-safe. Narrows which items the
existing deterministic draws consider.

### 2026-06-13 — A potion thrown into deep water floats away instead of shattering

**What.** A potion that lands on an open **deep-water** tile (no creature or wall struck) no longer
shatters — it splashes in and is carried to shore by the existing item current, so it can be waded out
and recovered rather than wasted. A potion that strikes a creature or wall *over* the water still
shatters there as before; shallow water (which doesn't sweep items) is unaffected.

**Why.** Lobbing a potion into deep water and having it detonate/vanish felt punishing and unphysical;
floating it ashore reuses the game's own deep-water item behavior and turns a misthrow into a
recoverable mistake. (Player request.) Side effects, both desirable: a thrown **potion of water** no
longer pointlessly floods existing water, and a thrown **potion of ice** no longer freezes a water
crossing (it floats away) — freezing water is now the staff of frost's job, not a thrown potion's.

**Where.** `Items.c` `throwItem`: a new branch *before* the potion-shatter block — if the item is a
potion, nothing solid was hit, no creature/player is on the tile, and the tile is `T_IS_DEEP_WATER`,
it prints a generic splash line (visibility-gated) and `placeItemAt`s the flask in the water (via
`getQualifyingLocNear`, mirroring the normal thrown-item drop). The per-turn `T_MOVES_ITEMS` drift in
the floor-item update (`Items.c`, the existing "items in deep water drift one cell toward shore" code)
then washes it ashore. No new mechanic.

**Determinism.** Placement + the existing drift are deterministic; no RNG. Same release-time
`recordingVersionString` bump.

### 2026-06-11 — Sharpen monkey theft preference (tunes PR #849)

**What.** Strengthened the monkey's deductive-theft bias from the PR #849 entry above: the favored-item
bonus in `rateItemStealDesirability` goes **+50 → +290** (food and potions of life/strength), and the
uniform-pick hedge in `specialHit` drops **10% → 5%**.

**Why.** At +50 (a 6:1 weight) a single favored item still lost to the summed base weight of a full pack,
so monkeys rarely visibly favored food/life/strength in play. +290 (~30:1) makes food the steal ~70%+ of
the time when carried, matching the monkey's flavor text. Note this can't change how often life/strength
are taken — those are simply seldom in the pack. The lower hedge also slightly sharpens **imp** theft,
consistent with the deductive-thievery intent.

**Where.** `Combat.c` — `rateItemStealDesirability` (monkey branch) and the `rand_percent` hedge in
`specialHit`. Pure value tweak; same determinism characterisation as the PR #849 entry below.

### 2026-06-10 — Halve the detect-magic potion's generation frequency (Brogue)

**What.** The potion of detect magic now appears about half as often: its `frequency` in
`potionTable_Brogue` drops from **20 to 10**.

**Why.** Tuning request — detect magic was showing up too readily, undercutting the deliberate,
costed identification the potion-ID rework is built around.

**Where.** `GlobalsBrogue.c` — the `"detect magic"` row of `potionTable_Brogue`. In the Brogue variant
detect magic is **not metered and not guaranteed** (its `meteredItemsGenerationTable_Brogue` entry is bare
defaults with `incrementFrequency == 0`, so the metered system never overrides its frequency — Items.c:683
— and it has no `levelGuarantee`). Its appearance is therefore driven purely by this static `frequency`,
which feeds the weighted pick in `chooseKind` (Items.c:417-421). Halving it halves detect magic's share of
potion generation. **Brogue variant only / iOS-only — not contributed to a fork branch.** (Rapid and Bullet
guarantee detect magic via `levelGuarantee`, so frequency matters far less there; left untouched.)

**Determinism.** This changes item generation, so the weighted pick consumes RNG differently and pre-change
recordings diverge on replay — a per-variant `recordingVersionString` bump at release is warranted (the diff
does not bump it). No new state or RNG call sites; it's a table-value change.

### 2026-06-10 — Benevolent potions glow harmlessly when a bolt crosses them

**What.** A fire or lightning bolt that crosses a dropped **benevolent** potion (the eight good kinds —
life, strength, telepathy, levitation, detect magic, haste self, fire immunity, invisibility) now prints
"the bolt passes through the flask and its fluid glows warmly." instead of doing nothing visible. The flask
is **not** destroyed and the bolt **continues** (it does not halt, unlike a bad potion, which detonates and
absorbs the bolt).

**Why.** Player request — a bolt over a good potion used to be a silent no-op, which read as a bug. The
benevolent potions are exactly the kinds `shatterPotionAtLoc` returns `false` for (they have no shatter
signature), so they were inert to bolts. The glow gives that inertness visible feedback.

**Where.** `Items.c` — the bolt-detonation hook in `updateBolt`. The `if (… shatterPotionAtLoc(…))` was
split into an `if/else`: the detonate-and-halt branch is unchanged; a new `else if (playerCanSee(x, y))`
branch prints the glow message for the inert (good) potions. Gated on visibility so an off-screen monster
bolt crossing a dropped potion doesn't print a phantom message. No item teardown, no `terminateBolt`, no
identify — purely a message.

**Determinism / balance.** No RNG and no serialized state (a deterministic `message()` keyed on game state).
Because bad potions detonate-and-halt while good ones glow-and-pass, a zap becomes a *costed polarity probe*:
one charge reveals (by observation) the leading run of benevolent potions up to the first bad one, which
detonates dangerously and is consumed. Bounded and expensive, not the old free mass-ID. Recorded in
`KNOWN_CAVEATS.md`. Backport note in `docs/notes/fork-backport-tweaks.md` (branch `potion-bolt-detonation`).

### 2026-06-10 — Potion-ID tuning: faster first rest-reveal, and detonating potions absorb the bolt

**What.** Two small balance tweaks to features added earlier in this branch:

1. **Rest-based polarity insight now fires sooner.** The first reveal lands after **90** rested turns
   instead of 120 (`POLARITY_INSIGHT_BASE_TURNS`); the per-known-kind ramp (`+30` turns each) is unchanged,
   so it still gets harder as the player learns more polarities.
2. **A detonating dropped potion now absorbs the bolt.** When a fire or lightning bolt detonates a dropped
   bad/cloud potion (the Phase 3 / PR #842 hook), the bolt **halts at that tile** rather than continuing
   down its path. Each bolt can therefore detonate at most one potion.

**Why.** (1) Player tuning request — 120 felt too slow for the first hint. (2) Closes an exploit: a player
could drop every unidentified potion in a straight line and clear/identify the whole row with a single
lightning (or fire) staff charge, since lightning pierces everything via `BF_PASSES_THRU_CREATURES`. Making
the shattering flask "absorb" the bolt caps each charge at one detonation, so mass-detonation costs one
charge per potion — the intended price. Thematically, the violent explosion disrupts the arc.

**Where.** `Items.c` only.
- Tweak 1: the `POLARITY_INSIGHT_BASE_TURNS` macro (above `gainPolarityInsightFromRest`).
- Tweak 2: the bolt-detonation hook in `updateBolt` — inside the `if (… shatterPotionAtLoc(…))` block, a
  `terminateBolt = true;` after the existing item teardown. It is set *before* the function's trailing
  `exposeTileToFire` / `exposeTileToElectricity` calls, which still run for this tile, so a fire bolt
  ignites the freshly-spawned flammable terrain (gas cloud / fungal forest) before the bolt stops; only
  then does the caller's `if (updateBolt(...)) break;` halt the bolt. `shatterPotionAtLoc` returns `true`
  only for the eight bad/cloud potions, so good potions (which fall through `default: return false`) never
  halt a bolt.

**Determinism.** No new RNG and no serialized state. The bolt simply traverses fewer cells once it
detonates a potion; like the Phase 3 / #842 detonation it diverges only as a direct consequence of the
player's action (zapping a location that holds a dropped bad potion), so it replays identically. Saves are
recordings. See `KNOWN_CAVEATS.md` for the accepted side effect (a dropped bad potion can now shield a
monster directly behind it from that bolt). Both tweaks are tuning refinements of existing fork-branch
features and should be backported to those branches — see `docs/notes/fork-backport-tweaks.md`.

### 2026-06-10 — Deductive thievery: monkeys and imps steal by preference (upstream PR #849)

**What.** Thieving monsters no longer steal a uniformly random item. 90% of the time they pick by a
weighted desirability score, 10% of the time they fall back to the old uniform pick. **Monkeys** favor
food and potions of life/strength; **imps** favor scrolls of enchanting, positively-enchanted gear, and
runics (and shy away from food). Because the thief "knows" an item's true nature, what it grabs is a hint
toward that item's identity (e.g., a monkey snatching an unidentified potion suggests life or strength).

**Why.** Ports [BrogueCE PR #849](https://github.com/tmewett/BrogueCE/pull/849) ("Deductive Thievery"),
which fits the broader potion-ID theme by turning theft into an identification signal. **iOS-only — not
contributed to a fork branch** (PR #849 is itself the upstream contribution).

**Where.** `Combat.c` — a new `static short rateItemStealDesirability(creature *thief, item *theItem)`
defined just above `specialHit`, and the theft item-selection in `specialHit` (the `MA_HIT_STEAL_FLEE`
block) replaced with the 10%-uniform / 90%-weighted-roulette scheme. `Globals.c` — monkey and imp monster
descriptions reworded to hint at their new preferences. (`choiceRoll` is declared `long` to match
`rand_range`'s return type and avoid an Xcode 64→32 narrowing warning; the upstream PR used `int`.)

**Determinism.** No new common-path RNG and no serialized state. The theft draw changes (an extra
`rand_percent(10)`, and the weighted `rand_range` over scores instead of a flat `rand_range` over
candidates), but theft is an action-triggered combat event — it diverges the RNG stream only when a
monkey/imp actually steals, not on every turn — so it's a self-consistent action-triggered divergence,
like the thrown-potion and bolt-detonation changes.

### 2026-06-10 — Thrown hallucination potions bloom a fungal forest, and bolts detonate them (upstream PR #842 + bolt extension)

**What.** A thrown potion of hallucination now spawns a **luminescent fungal forest** at the impact tile
(the existing `FUNGUS_FOREST` terrain: flammable, a light source, and a line-of-sight blocker) instead of
splashing harmlessly. Additionally, fire and lightning bolts now detonate a **dropped** hallucination
potion the same way Phase 3 detonates the bad/cloud potions: a lightning bolt simply blooms the forest,
while a fire bolt blooms it and then **ignites** it.

**Why.** Ports [BrogueCE PR #842](https://github.com/tmewett/BrogueCE/pull/842) ("Give hallucination potions
a use"), which reframes hallucination as a "magic-mushroom" potion. The bolt extension was requested to keep
it consistent with the Phase 3 bolt-detonation mechanic now that thrown hallucination has a real effect.
**iOS-only — not contributed to a fork branch.** (Note: this changes the Phase 3 potion×bolt matrix —
hallucination, previously inert to bolts, now reacts: fire ignites the forest, lightning just spawns it.)

**Where.** `Items.c` — a `case POTION_HALLUCINATION` added to `shatterPotionAtLoc` (spawns
`DF_FUNGUS_FOREST`). Because that helper is shared by both `throwItem` and the bolt-detonation hook in
`updateBolt`, this single case covers the throw effect (PR #842) and the bolt-detonation; the fire-vs-
lightning behavior falls out of the existing ordering (the detonation runs immediately before the bolt's
`exposeTileToFire`, so a fire bolt ignites the freshly-spawned flammable forest). The now-dead
harmless-splash branch for hallucination in `throwItem` was removed. `GlobalsBrogue.c` /
`GlobalsRapidBrogue.c` / `GlobalsBulletBrogue.c` — the hallucination potion description now mentions the
thrown fungal-forest effect.

**Determinism.** No new RNG and no serialized state; reuses existing terrain/DF (`FUNGUS_FOREST` /
`DF_FUNGUS_FOREST`). Like the rest of Phase 3, throwing or bolt-detonating a hallucination potion is an
action-triggered divergence (the spawned forest and any fire it draws), acceptable and self-consistent on
replay; nothing changes on the common path.

### 2026-06-10 — Auto-identify a worn ring deducible by elimination (upstream issue #683)

**What.** When a ring is equipped and reveals no obvious effect, and it is the only still-unidentified ring
kind that stays hidden on equip, its kind is now deduced and identified. (Only clairvoyance, light, and
stealth reveal themselves on equip; the other five — regeneration, transference, awareness, wisdom, reaping
— stay hidden, so once four of those five are known, equipping the fifth identifies it.)

**Why.** Implements [BrogueCE issue #683](https://github.com/tmewett/BrogueCE/issues/683) ("Auto-ID ring
kind based on whether all remaining rings ID on equip"), a flagged good-first-issue: the deduction is one a
player can already make by hand, so the game does the bookkeeping.

**Where.** `Items.c` — two small static helpers above `equipItem` (`ringIdentifiesOnEquip(short)` factors out
the clairvoyance/light/stealth set; `unidentifiedRingKindsHiddenOnEquip(void)` counts the unidentified hidden
kinds), and the ring branch of `equipItem` now uses the helper for the existing self-ID path and adds the
elimination deduction. Reuses `identifyItemKind`, `ringTable`. All vanilla symbols.

**Determinism.** Pure identification bookkeeping — no RNG, no serialized state. ID state isn't part of the
recording stream, so seeds and replays are unaffected.

### 2026-06-10 — Altars of insight: sacrifice one item to reveal another (new content)

> **Updated 2026-06-11** (see the rest-insight entry above): paying with an *identified* item now reveals
> the insight item's polarity, or — if its good/bad polarity is already known — **escalates to a full
> identification** (via the shared `revealOrIdentifyPolarityItem` helper). The "fire only if it helps"
> guard now refuses only when the insight item is fully identified or already revealed as having no
> good/bad polarity.

> **Updated 2026-06-14** (see the "carry-forward schedule" entry below): the schedule is now **depths 5 and
> 15 only** (the depth-25 altar was removed), and an altar that can't fit on its target level is no longer
> silently dropped — the obligation carries forward to the next level until a room is found.

**What.** A new guaranteed reward room — a pair of linked altars (an "altar of insight" + an "altar of
offering") that appears at depths 5 and 15, Brogue variant only.
Place the item you want to learn about on the insight altar and a payment item on the offering altar; when
both hold items the offering is consumed and the other item is revealed. The reveal scales with the
payment: **sacrificing an unidentified item fully identifies** the offered item, while sacrificing an
**identified item only reveals its polarity/aura** (via `detectMagicOnItem`). Both altars then go inert. It
"fires only if it helps" — never consumes the payment unless the offered item would actually gain info, so
a `+0` mundane weapon reveals as "no aura" rather than wasting the sacrifice, and an already-known item
does nothing.

**Why.** The deferred Phase 7 of the potion-ID arc, redesigned as a costed trade (give up an item to learn
one) rather than the original free whole-pack polarity reveal, which was effectively on-demand detect
magic. The risk dial (gamble an unknown for a full ID, or pay a known item for just polarity) keeps
identification a gamble while easing it.

**Where.**
- `Rogue.h`: `tileType` — `INSIGHT_ALTAR_INSIGHT` / `INSIGHT_ALTAR_PAYMENT` / `INSIGHT_ALTAR_INERT`;
  `dungeonFeatureType` — `DF_ALTAR_INSIGHT_INERT`; `TM_INSIGHT_ACTIVATION = Fl(26)`; `machineTypes` —
  `MT_INSIGHT_ALTAR` aliased to `MT_REWARD_HEAVY_OR_RUNIC_WEAPON` (Brogue fills the variant-specific reward
  slot, index 72, that BulletBrogue uses for its weapon vault — they never collide, being per-variant + variant-gated).
- `Globals.c`: `blueAltarBackColor`; three `tileCatalog` rows (model on `COMMUTATION_ALTAR`); a
  `DF_ALTAR_INSIGHT_INERT` `dungeonFeatureCatalog` row (empty message — the reveal text is emitted once by
  the handler, not per promoted altar).
- `Items.c`: `static boolean performInsightSacrifice(short)` (defined near `detectMagicOnItem`, forward-declared
  above `updateFloorItems`) + a sibling block in `updateFloorItems`, modeled exactly on the commutation-altar
  block (`TM_*` flag + machineNumber + `nextItem`-skip + `activateMachine`). Reuses `identify`,
  `detectMagicOnItem`, `tryIdentifyLastItemKinds`, `itemMagicPolarity`, `itemName`, `messageWithColor`,
  `removeItemFromChain`, `deleteItem`. All vanilla.
- `GlobalsBrogue.c`: the blueprint appended at index 72 (force-only — no `BP_REWARD`, frequency 0).
- `Architect.c`: a Brogue-gated, depth-gated force-build in `addMachines` (modeled on the amulet vault and
  BulletBrogue's L1 weapon vault).

**Determinism.** The reveal handler is RNG-free (flag/table flips + a deterministic machine scan); saves are
recordings (no serialized format change). Because the altar is force-only (not in the BP_REWARD raffle), the
random reward-room raffle is byte-unchanged at every depth — the only seed divergence is on the forced
levels (5 and 15, Brogue only), where placing the room draws RNG. As new dungeon content it warrants a
per-variant `recordingVersionString` bump at release (left to maintainers; not bumped here). Rapid/Bullet
untouched.

### 2026-06-10 — Eating studies a scroll: reveal one scroll's polarity on a safe meal

> **Updated 2026-06-11** (see the rest-insight entry above): the scroll is now chosen **at random** (not
> top-of-pack), the eligible pool **includes scrolls whose polarity is already known**, and acting on such
> a scroll **fully identifies** it instead of only revealing polarity. Reuses the shared
> `applyPolarityInsightToRandomItem(SCROLL, …)` helper. The selection now consumes RNG (action-triggered,
> replay-safe) — no longer "no RNG" as originally described below.

**What.** Eating a meal (`eat` returning true) reveals the polarity (benevolent/malevolent) of a
still-unknown scroll in your pack, with a colored message ("you study a scroll intently while eating; it
radiates a … aura."). Polarity only (or a full ID of an already-sensed scroll — see the 2026-06-11 update
above). One scroll per meal; if you hold no eligible scroll, the meal proceeds normally with no reveal.

> **Updated 2026-07-02 — no longer safety-gated.** The old "nothing is hunting you" requirement was
> removed: eating now **always** polarity-checks a scroll if one is available, regardless of whether any
> monster is aware of / hunting you. The `MONSTER_TRACKING_SCENT` scan at the top of
> `gainScrollInsightFromEating` is gone. The `Globals.c` `foodTable` flavor text was updated to match
> (dropped "with nothing on the hunt for you" / "when eaten undisturbed"); the reward is a plain "any
> meal" effect now.

**Why.** Companion to the rest-insight feature: a calm moment to study a scroll while you eat. Meals are
scarce and the reward is safety-gated, so it eases scroll identification without removing the gamble.

**Where.** `Items.c` — a new `void gainScrollInsightFromEating(void)` defined just after
`gainPolarityInsightFromRest` (as of 2026-07-02 it no longer scans `monsters`; it goes straight to
`applyPolarityInsightToRandomItem(SCROLL, …)`), called from `eat()` just before its `return true`.
Prototype in `Rogue.h`. All vanilla symbols.

**Flavor (added 2026-06-10).** Both `foodTable` descriptions in `Globals.c` (the shared catalog — the
feature is not variant-gated, so the hint is accurate in every variant) now hint at this: the ration of
food notes that "a meal taken in peace, with nothing on the hunt for you, settles the mind enough to study
an unidentified scroll…", and the mango that eating "undisturbed" affords "a quiet moment to divine the
nature of an unknown scroll." Description-only; no logic change. Backport with the feature — see
`docs/notes/fork-backport-tweaks.md` (branch `eat-scroll-insight`).

**Determinism.** `eat()` is one command per keystroke (no `autoRest`-style per-turn re-recording), the
reveal is RNG-free, and there's no new stored state — so it's reconstructed identically on replay (saves
are recordings). Like the rest feature it's a deterministic gameplay-rule change, so pre-feature recordings
diverge on replay; a per-variant `recordingVersionString` bump is warranted at release (not in the diff).

### 2026-06-10 — Passive polarity insight while resting (+ debug rest-count readout)

**What.** Resting slowly reveals item polarity. Each rested turn accrues toward a threshold; on reaching
it, the first still-unknown (good/bad) item in the pack has its benevolent/malevolent polarity revealed
(same effect as detect-magic on one item), with a colored "while resting, you sense the … aura of …"
message, and any in-progress auto-rest is interrupted so the player notices. The threshold grows with the
number of polarity kinds already known (`BASE = 120`, `STEP = 30` rested turns per known kind), so it
eases the early-game ID burden but tapers off late so it can't trivialize identification. Separately, an
**iOS-only debug readout** appends `[rests/lvl: 1:12 3:40 …]` (rested turns per depth) to the on-screen
death/quit recap.

**Why.** Requested feature: ease the chore of identifying healing/strength items without removing the
gamble. Polarity-only (never a full ID) and self-tapering keeps it in line with the arc's anti-triviality
goal (the concern that shelved Phase 5). The debug readout exists to tune `BASE`/`STEP` from real runs.

**Where.**
- *Feature (also ported upstream):* `Rogue.h` — `playerCharacter.restTurnsSinceInsight` field + a
  `void gainPolarityInsightFromRest(void)` prototype. `Items.c` — `static int knownPolarityKindCount(void)`
  and `gainPolarityInsightFromRest()` defined just after `detectMagicOnItem` (reuses `detectMagicOnItem`,
  `tryIdentifyLastItemKinds`, `itemMagicPolarityIsKnown`, `itemMagicPolarity`, `itemKindCount`,
  `tableForItemCategory`, `itemName`, `messageWithColor` — all vanilla). `Time.c` — a call in
  `playerTurnEnded`, gated on `rogue.justRested`, just before the `justRested` reset.
- *iOS-only debug:* `Rogue.h` — `levelData.restTurnsOnLevel` field; `Time.c` — increment in the same
  `justRested` block; `RogueMain.c` — the `[rests/lvl: …]` append in `gameOver`, after
  `theEntry.description` is copied (so the saved high-score text is untouched), length-guarded to `buf[200]`.

**Determinism.** Brogue "saves" are recordings (state is rebuilt by replay), so the new fields add no
serialized format to break. Counting is done in `playerTurnEnded` rather than at the command dispatch on
purpose: `autoRest` re-records each rested turn as `REST_KEY`, so one `Z` replays as N rests — the
turn-resolution chokepoint is the only place that tallies identically live and on replay. The reveal is
pure flag-flipping (no RNG). It is, however, a deterministic *gameplay-rule* change: recordings/seeds made
before it will diverge on replay, so a `recordingVersionString` bump is warranted at release (per-variant;
left to the maintainers — the diff does not bump it).

### 2026-06-10 — Candidate-narrowing inspect line for unidentified potions/scrolls

> **Reverted 2026-06-11** (see the "Remove candidate-narrowing readout" entry above): the readout added
> no value and read confusingly alongside the themed potion sets. The `candidateKindCount` helper, its
> forward prototype, and the `itemDetails` render block were removed.

**What.** An unidentified potion's or scroll's inspect text now ends with a line like "You have narrowed
it down to one of 3 remaining beneficial potions." — the count of kinds it could still be, narrowed to
its polarity if that's known (the count is colored good/bad accordingly). It never names candidate kinds,
and is shown only when the count is ≥ 2.

**Why.** Surfaces the deduction bookkeeping a player otherwise tracks by hand. It reveals no new
information: the count is derived purely from what the player already knows (which kinds are identified,
plus this item's polarity if detect-magic/elimination has revealed it). The engine already
auto-identifies the last unknown kind of a polarity (`tryIdentifyLastItemKinds`, fired from every ID
path), so an unidentified item's count is always ≥ 2 — rendering only at ≥ 2 guarantees the line can
never hand out a free identification.

**Where.** `Items.c` — a forward prototype above `itemDetails`; a new `static short
candidateKindCount(item*, boolean *knownGood, boolean *knownBad)` defined just after
`itemMagicPolarityIsKnown` (iterates the category's kinds, counts unidentified ones matching known
polarity); and a render block appended to the unidentified branch of `itemDetails` (after the category
switch's `strcat`), gated on `POTION | SCROLL`. Reuses `itemMagicPolarityIsKnown`, `itemKindCount`,
`tableForItemCategory`, and `itemDetails`'s existing color-escape locals. All vanilla symbols.

**Determinism.** Pure display, recomputed on each inspect — no RNG, no serialized state; seeds and
recordings are unaffected.

### 2026-06-10 — Fire/lightning bolts detonate dropped bad potions

**What.** A fire or lightning bolt (`BF_FIERY` / `BF_ELECTRIC`) passing over a *dropped* potion now
detonates it in place, turning the potion into a placeable trap / ranged identifier. Only the seven
bad/cloud kinds react (poison, confusion, paralysis, incineration, darkness, descent, creeping death) —
the same set the thrown-potion shatter switch handles; good potions and hallucination get no bolt
signature. Fire is **violent** and lightning is **gentle** as an *emergent* property: detonation spawns
the potion's ordinary shatter dungeon feature, and the fire bolt's own per-cell `exposeTileToFire` then
ignites the flammable gas (poison/confusion/paralysis gas carry `T_IS_FLAMMABLE`); lightning has no fire
step, so the gas lingers as a cloud. The bad-potion switch was extracted from `throwItem` into a new
`static boolean shatterPotionAtLoc(item*, short x, short y)` (spawns DF + message + auto-ID + cell
refresh; returns true for the seven kinds) and is now shared between `throwItem` and the bolt hook.

**Why.** A dropped potion is otherwise inert until walked into. Letting a bolt set it off makes a dropped
bad potion a deliberate tool — lay a gas trap in a doorway, or ignite one on a chasing pack — and gives
fire/lightning staffs a second, terrain-driven use. Kept independent of the earlier potion-rework phases
so the change ports to upstream BrogueCE master verbatim (no creature effects or life cloud on bolt).

**Where.** `Items.c` only. (1) Forward prototype of `shatterPotionAtLoc` above `updateBolt`. (2) A new
hook in `updateBolt`, after the `pathDF` spawn and before the `BF_FIERY` `exposeTileToFire` block, so fire
ignites the gas the hook just spawned; it calls `shatterPotionAtLoc` on a `POTION` at the cell and tears
the floor item down exactly like `burnItem` (`removeItemFromChain(floorItems)` → `deleteItem` → clear
`HAS_ITEM | ITEM_DETECTED`), then sets `*lightingChanged` / `*autoID`. (3) `shatterPotionAtLoc` defined
above `throwItem`, extracted from the old inline switch. (4) `throwItem`'s bad-potion block replaced with
`if (shatterPotionAtLoc(...)) { } else { <existing harmless-splash + hallucination-ID> }`. Reuses only
upstream symbols.

**Determinism.** No RNG on the common bolt path (the hook is an `itemAtLoc` lookup + category test;
`spawnDungeonFeature` on a GAS-layer DF is a pure write). Action-triggered divergence only: detonating a
potion via a bolt diverges the seed exactly as *throwing* it would (same DFs; fire ignition via
`exposeTileToFire` is forced with `alwaysIgnite`, drawing no `rand_percent` of its own). No new RNG
primitive.

### 2026-06-10 — Thrown good potions affect the struck creature

**What.** Throwing an unidentified *good* potion (the first `numberGoodPotionKinds` of the potion
table: life, strength, telepathy, levitation, detect-magic, haste, fire-immunity, invisibility) at a
creature now applies that potion's effect to the creature it shatters on. A new
`static boolean applyPotionEffectToCreature(creature*, short potionKind, short magnitude)` (`Items.c`,
defined just above `drinkPotion`, forward-declared above `throwItem`) carries the per-kind logic. It
always applies the mechanical effect, but returns `true` only when a *player-visible* tell was
produced — which is what drives `autoIdentify`:
- strength → reuses the empowerment system (`empowerMonster` + `EMPOWERMENT_LIGHT` flare, the same
  effect as the empowerment bolt/wand/altar): a permanent all-round combat boost + full heal, with
  `empowerMonster`'s own "looks stronger" tell. Skipped on `MONST_INANIMATE`/`MONST_INVULNERABLE`
  targets (no effect, no ID), mirroring the bolt. The ally-only `newPowerCount` talent-learning side
  effect is gated on `MONSTER_ALLY` elsewhere, so it's inert on an enemy and a bonus on an ally,
- haste → "speeds up"; levitation → "floats into the air",
- life → full panacea heal of the struck creature **and**, on shatter, a healing-spore gas cloud
  (a new `DF_LIFE_POTION_CLOUD` that spawns the existing bloodwort `HEALING_CLOUD`); life auto-IDs
  unconditionally on shatter, like the gas potions,
- invisibility → reuses `imbueInvisibility` (its own flash + visibility-gated auto-ID),
- fire-immunity → sets `STATUS_IMMUNE_TO_FIRE`, but only IDs by *visibly snuffing flames* on a
  burning, not-already-immune, non-`MONST_FIERY` creature (no invented flavor text),
- telepathy / detect-magic and any bad potion → no effect, no ID.
The player is never the target (a thrown good potion shouldn't self-buff). The hook is a block at the
top of the potion-shatter branch in `throwItem`, before the bad-potion switch; when there is no tell
it falls through unchanged to the existing harmless-splash / hallucination-ID path. `drinkPotion`'s
own switch is untouched.

**Why.** Brogue's residual identification slog is discriminating the *good* potion cluster (life vs
strength vs haste…), which today can only be done by drinking in a safe corner. Making a thrown good
potion affect — and visibly tell on — the struck creature turns identification into a risky ranged
diagnostic. Effect-always / tell-gated keeps an unseen creature mechanically affected without leaking
information the player couldn't perceive. Upstream has no thrown-good-potion effect, so this is an
iOS divergence.

**Where.** `Items.c` — forward prototype above `throwItem`; `applyPotionEffectToCreature` defined
between `detectMagicOnItem` and `drinkPotion`; a new block at the top of the potion-shatter `if` in
`throwItem` (the good-potion effect, plus a `POTION_LIFE` case that spawns the cloud). Reuses `heal`,
`haste`, `imbueInvisibility`, `extinguishFireOnCreature`, `spawnDungeonFeature`, and `empowerMonster`
+ `createFlare` (`Monsters.c`) for strength. `Rogue.h` —
`DF_LIFE_POTION_CLOUD` appended to the `dungeonFeatureType` enum before `NUMBER_DUNGEON_FEATURES`.
`Globals.c` — a matching `{HEALING_CLOUD, GAS, 350, 0, 0}` row appended to `dungeonFeatureCatalog`
(clone of the bloodwort pod-burst). The catalog and enum are shared across the Brogue/Rapid/Bullet
variants; appending at the tail keeps every existing index aligned.

**Determinism.** No RNG on the common path: fixed magnitude via `potionTable[kind].range.upperBound`
(every good potion has `lowerBound == upperBound`), the helper draws no RNG, and `spawnDungeonFeature`
on a GAS layer is a pure volume/tile write (no RNG). Two action-triggered substantive-RNG divergences,
both stemming from the player's throw rather than from added bookkeeping: (1) thrown fire-immunity
early-extinguishing a burning creature removes that creature's remaining per-turn `rand_range(1,3)`
burn draws (the `STATUS_BURNING` case in `decrementMonsterStatus`, Monsters.c, draws unconditionally
per burning turn; fire immunity gates only the damage, not the draw); (2) the life cloud's gas changes
the gas map, so subsequent gas-dissipation rolls diverge from upstream seeds.

### 2026-06-11 — Button-drag highlight follows the finger

**What.** While dragging a touch across a menu/inventory (`MOUSE_ENTERED_CELL` with a
button already pressed), `processButtonInput` now moves `buttonDepressed` to the button
under the finger, instead of only setting it on `MOUSE_DOWN`.

**Why.** `drawButtonsInState` paints `buttonFocused` as `BUTTON_HOVER` and
`buttonDepressed` as `BUTTON_PRESSED`. On a drag, focus follows the finger but the
depressed index stayed on the originally-pressed button, so two rows lit up at once (e.g.
press "Autopilot", drag to "Feats" → both highlighted). On touch you want exactly one
highlight tracking the finger. The Classic engine already carries this fix
(`iBrogue_iPad/BrogueCode/Buttons.c`); this brings CE in line.

**Where.** `Buttons.c` — `processButtonInput()`, the focus-found branch now also sets
`buttonDepressed` when `event->eventType == MOUSE_ENTERED_CELL && buttonDepressed >= 0`.

### 2026-06-08 — Rethrow falls through to a normal throw prompt

**What.** The rethrow command (`RETHROW_KEY`, Shift+T) used to no-op when there was no
valid item to rethrow. It now falls through to a normal throw prompt in that case.

**Why.** Upstream, rethrow only fires if `rogue.lastItemThrown != NULL` *and* that item
is still carried (`itemIsCarried`); otherwise the keystroke silently does nothing — most
visibly the first time you press it in a game (nothing thrown yet). On touch a button that
does nothing reads as broken, so we degrade to the ordinary "Throw what?" item picker
(`throwCommand(NULL, false)`), the same thing `THROW_KEY` does. Auto-targeting at
`lastTarget` is intentionally *not* preserved in the fall-through case (it would require a
`throwCommand` that can both prompt for an item and auto-aim).

**Where.** `IO.c` — `executeKeystroke()`, the `RETHROW_KEY` case gains an `else` branch.

### 2026-06-07 — Don't show the ESC button for tap-to-continue prompts

**What.** `waitForAcknowledgment()` and `waitForKeystrokeOrMouseClick()` no longer force
`uiMode = CBrogueGameEventShowEscape`; they leave `uiMode` as-is (InNormalPlay during play,
so no ESC button).

**Why.** Both prompts already dismiss on `MOUSE_UP` (tap anywhere) — they're "press any key
/ click to continue" acknowledgments, including the `--more--` message prompt
(`displayMoreSign → waitForAcknowledgment`). The on-screen ESC button was appearing for
transient messages like "A pressure plate clicks underneath the dart!", which is redundant
and noisy. The ESC button stays for states a tap can NOT dismiss: text entry
(`getInputTextString` → `ShowKeyboardAndEscape`: save game / save recording / seed) and the
throw/zap aiming loop (`Items.c`, which needs ESC to cancel an aim). Care was taken not to
remove ESC anywhere it's the only way out — these two functions provably exit on a tap.

**Where.** `IO.c` — removed the `uiMode = CBrogueGameEventShowEscape` (and the
save/restore of `oldUiMode`) in `waitForAcknowledgment` and `waitForKeystrokeOrMouseClick`.
Classic doesn't set a UI mode in its equivalents, so this is CE-only.

### 2026-06-06 — Suspend pinch-zoom while an entity description box is shown

**What.** When a creature/item description box lingers in the cursor loop (e.g. the
player taps an entity in the sidebar), the host suspends the iPhone pinch-zoom to 1×
so the box isn't magnified/clipped, then restores it — the same treatment menu and
inventory already get.

**Why.** The description box (`printMonsterDetails`/`printFloorItemDetails` →
`printTextBox`) renders into the dungeon cells but fired no host signal, so it was
drawn magnified and ran off-screen while zoomed.

**Where.** `IO.c` — `extern void ceSetExamining(boolean);` at file top; in
`mainInputLoop`'s cursor `do/while`, `ceSetExamining(textDisplayed)` right before
`moveCursor` and `ceSetExamining(false)` right after the loop (clears on action/cancel).
Defined in `CEBridge.mm` (deduped) → `BrogueCEHost setExamining:` → host. The host only
suspends zoom when the box was armed by a **sidebar single-tap** (`examineArmed`, set in
`touchesEnded`); boxes that auto-appear (auto-explore stopping on an item, a tap-to-move
over a monster) are not armed, so they don't zoom out — that previously caused an in/out
flicker while exploring.

### 2026-06-06 — Title flyout marker: ASCII `<` instead of a triangle glyph

**What.** The main-menu flyout buttons (Play, View) are marked with a literal ASCII
`<` in their button text instead of the `G_LEFT_TRIANGLE` display glyph.

**Why.** `G_LEFT_TRIANGLE` maps (via `ce_glyphToUnicode`) to `U_LEFT_TRIANGLE`
(`0x25C4` / `0x1F780`), which renders through a font that doesn't carry the glyph on
every locale/device, so it showed up inconsistently. `<` is in the reliable text set
(rendered from Monaco) and always looks the same. The flyout opens to the buttons'
left, so a left-pointing marker still reads correctly.

**Where.** `MainMenu.c` `initializeMainMenuButtons` — the Play/View button text uses
` <  ...` and the two `buttons[n].symbol[0] = G_LEFT_TRIANGLE;` assignments were
removed. (`*` in button text is the symbol placeholder; with no symbol set it would
render literally, so the text uses `<` directly.)

### 2026-06-06 — On-screen Explore button: single-tap auto-explore

**What.** A single tap on the on-screen Explore button now auto-explores
immediately, instead of the desktop two-step "tap once to preview the path, tap
again to commit." Ports the Classic engine's existing fix to CE (the button
previously misfired, often needing a second tap). Keyboard `x` (a `KEYSTROKE`) is
unaffected.

**Why.** On touch, the preview-then-commit step reads as the button "not
registering." A tapped button should act like pressing its hotkey.

**Where.** `IO.c` — file-scope `static boolean exploreImmediately`; in
`mainInputLoop`, set it when the chosen button is Explore and the event is
`MOUSE_UP`; in `exploreKey`, consume it into a local `forceExplore` and OR it into
the final `proposeOrConfirmLocation(...)` guard.

### 2026-06-05 — Light haptic when the player takes damage

**What.** When the player loses HP, the engine signals the host to play a haptic,
scaled by severity: ordinary hit, a hit that leaves the player under 40% health
(the engine's own low-health-flash threshold), or a fatal blow.

**Why.** Tactile feedback for combat; the host owns the actual haptic so it can honor
the user's haptics setting and skip unsupported devices (iPad).

**Where.**
- `Combat.c` — `extern void cePlayerTookDamage(int severity);` at file top; in
  `inflictDamage`, when `defender == &player && damage > 0 && !rogue.playbackMode`,
  compute severity (fatal / under-40% / ordinary) and call it.
- Defined in `CEBridge.mm` → `BrogueCEHost playDamageHaptic:` → host.

**Gating.** Suppressed during recording playback. The host no-ops it when haptics
are off or on iPad.

### 2026-06-05 — Move the escape button aside while aiming a throw/zap

**What.** Around the targeting loop, the engine tells the host when aiming starts and
ends, so the host can move the on-screen escape button to the lower-left corner and
enable the aiming magnifier.

**Why.** During throw/zap targeting the escape button overlapped the aiming area, and
the magnifier (tap-and-hold) was otherwise suppressed outside normal play.

**Where.**
- `Items.c` — `extern void ceSetTargeting(boolean isTargeting);` at file top; in
  `chooseTarget`, `ceSetTargeting(true)` right after entering the aim loop and
  `ceSetTargeting(false)` at **both** exits (cancel and confirm).
- Defined in `CEBridge.mm` → `BrogueCEHost setTargeting:` → host.

### 2026-06-05 — No escape button on the death screen

**What.** The "You die… — press space or click to continue" screen now uses
`CBrogueGameEventInMenu` instead of `CBrogueGameEventShowEscape`.

**Why.** A tap already advances that screen, so the on-screen escape button was
redundant clutter. `InMenu` and `ShowEscape` are identical to the host except that
`InMenu` hides the escape button; touches still flow, so a tap still advances.

**Where.** `RogueMain.c` — `gameOver()`, the death "press to continue" loop.

### 2026-06-05 — Keep the full-screen title layout during the Load/Replay pickers

**What.** While the title-menu file pickers (Open saved game / View recording) are
open, keep `brogueCEAtTitle = true`; drop it to `false` only once a file is actually
opened.

**Why.** The pickers ran with `brogueCEAtTitle = false`, so the host enabled the
in-game safe-area insets and the view visibly shrank before any game had loaded.

**Where.** `MainMenu.c` — `mainBrogueJunction()`, the `NG_OPEN_GAME` and
`NG_VIEW_RECORDING` cases (set true before `dialogChooseFile`, false inside the
`openFile` success branch). `brogueCEAtTitle` is reported to the host by
`CEBridge.mm`.

---

### 2026-06-11 — Game Center leaderboard & achievements

**What.** Implemented the `notifyEvent` platform hook in `CEBridge.mm` so CE reports its
final score to a new `BrogueCE_High_Score` leaderboard and unlocks Game Center
achievements for earned feats. Added two `BrogueCEHost` methods — `reportCEScore:` and
`submitCEAchievementWithID:` — forwarded by `CEHost.swift` to the shared `GameCenter`
singleton (`ceHighScoreLeaderboardID` / `submitAchievement`). The on-screen leaderboard
button (`BrogueViewController.showLeaderBoardButtonPressed`) now picks the board by the
active engine.

**Why.** Classic already reports to Game Center (directly from `RogueMain.mm`); CE's
score/feats were local-only. CE lives in a framework that can't see the app's classes, so
it must route through the host protocol instead of calling `GameCenter` directly.

**Where.** No vendored `Engine/` C was changed — the engine already calls
`notifyEvent(GAMEOVER_*, score, …)` at game over. `CEBridge.mm`'s `ceReportGameOver()`
reads the engine globals `rogue.featRecord` / `featTable` / `gameConst` / `gameVariant`
and maps the `featTypes` enum to achievement IDs via `kCEAchievementIDForFeat[]`. Seven
feats reuse the Classic engine's achievement IDs (Game Center achievements are app-global);
the eighth, `brogue_untempted` (FEAT_TONE / "Untempted"), is CE-only and must be created in
App Store Connect.

**Gating.** Standard Brogue only (`gameVariant == VARIANT_BROGUE`); wizard runs never
report. Only completed runs report to the leaderboard — `GAMEOVER_QUIT` (quit/abandon) and
`GAMEOVER_RECORDING` (playback) are not forwarded, so giving up never posts a score. On
death only non-`initialValue` feats count; on victory/supervictory all set feats count.
(Note: the engine's *local* high-scores list still records quits via its own
`saveHighScore()`, matching upstream — only the online leaderboard excludes them.)

**Title-menu entry.** Added a "Game Center" item to the title screen's **main menu**
(after File Management), opening the `BrogueCE_High_Score` leaderboard. New
`NG_GAME_CENTER` command in the `NGCommands` enum (`Rogue.h`); the button + dispatch case
live in `MainMenu.c` (`initializeMainMenuButtons`, with `MAIN_MENU_BUTTON_COUNT` bumped to
5 tablet / 6 desktop; the `NG_GAME_CENTER` case calls `extern void ceShowGameCenter(void)`).
The bridge's
`ceShowGameCenter()` → `BrogueCEHost.presentGameCenter` → `CEHost` →
`BrogueViewController.presentGameCenterScreenForCE()`. Mirrors the existing
`NG_FILE_MANAGEMENT` / `ceShowFileManagement` plumbing; the leaderboard is presented as a
modal on the main thread while the engine stays at the title.

---

## Platform functions implemented in `CEBridge.mm`

These engine-declared platform functions were upstream stubs in this port and are now
implemented in the bridge (not the engine C, but listed here for orientation):

- `listFiles` — enumerates the CE save directory for the Load/Replay pickers.
- `getHighScoresList` / `saveHighScore` — local high scores (NSUserDefaults, CE keys).
- `saveRunHistory` / `saveResetRun` / `loadRunHistory` — the lifetime game-stats
  history (NSUserDefaults, CE keys; `seed == 0` is the "reset recent stats" sentinel).
- `notifyEvent` — CE → Game Center score/achievement reporting at game over (see the
  2026-06-11 entry above). Local high scores remain in NSUserDefaults; this adds the
  online leaderboard/achievements on top.

Still stubbed: `takeScreenshot`.

---

### 2026-06-21 — Background suspend & resume (save exact state, auto-resume on cold launch)

**What.** Backgrounding the app now snapshots the exact game state to disk, and if iOS later evicts
the suspended process, the next launch resumes straight into the game (no title screen). The common
case — backgrounding and returning before the OS kills the app — is untouched: iOS un-suspends the
in-memory game with no reload. Full rationale and the decision tree in
[docs/design/background-suspend-resume.md](../../docs/design/background-suspend-resume.md).

**Engine side.** None — no vendored engine `.c` changes. This rides entirely on existing engine
machinery: `flushBufferToFile()` to make the working recording exact, `initializeLaunchArguments()`
(platform-defined; the engine calls it at the top of `mainBrogueJunction`) to inject
`NG_OPEN_GAME` + a resume path, and `switchToPlaying()`'s existing copy-to-fresh-`LastGame` +
`DELETE_SAVE_FILE_AFTER_LOADING` source-delete for file hygiene. No new save files; resume is the
normal record-and-replay path, so it stays deterministic/save-safe.

**Bridge side.** New host hooks `se_requestBackgroundSave()` / `se_clearResumeMarker()` (SEBridge.mm,
BrogueSEHost.h). On background the host sets a flag; the engine thread, at its next poll point in
`nextKeyOrMouseEvent` **and** `pauseForMilliseconds` (so a backgrounded rest/travel is also caught),
flushes the recording and writes a one-shot resume marker (`"se resume path"` in NSUserDefaults).
`initializeLaunchArguments` consumes that marker on the next cold launch. Fire-and-forget — the
snapshot finishes inside iOS's grace window; no `beginBackgroundTask`.

**Where.** SEBridge.mm (`gSEBackgroundSaveRequested`, `seTakeBackgroundSnapshotIfRequested`,
`se_requestBackgroundSave`, `se_clearResumeMarker`, `initializeLaunchArguments`), BrogueSEHost.h.
Platform lifecycle (`appDidEnterBackground` / `appDidBecomeActive`, the cold-vs-warm
`didBackgroundThisProcess` guard) lives in BrogueViewController.swift. Applies to all three engines
(mirrored in CEBridge.mm / RogueDriver.mm).

**Notes.** Mid-play crash *without* backgrounding is intentionally not covered (matches prior
behavior — in-progress recordings were already orphaned). Resume after an eviction on a deep run
shows Brogue's normal `[ Loading… ]` replay bar, which is intrinsic to the save-as-recording format.

---

## Adding a new CE engine tweak

1. Prefer a host hook: declare `extern void ce<Thing>(...);` at the top of the engine
   file, call it where needed (with an `// iOS port (iBrogue):` comment), define it in
   `CEBridge.mm` inside `extern "C"`, add the matching `BrogueCEHost` method, and
   forward it from `CEHost.swift` to `BrogueViewController`.
2. For control visibility, reuse `uiMode` (write-only signal) rather than adding new
   plumbing where a mode value already conveys the intent.
3. Record the change here (what / why / where / gating).
