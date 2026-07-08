# iOS modifications to the Brogue C engine

The code in `BrogueCode/` is a vendored copy of the upstream **Brogue CE** engine
with a number of iOS-specific modifications layered on top. This document records
**what** was changed and **why**, so the divergence from upstream stays legible and
future maintainers (human or AI) don't mistake an intentional port change for a bug.

## Conventions

- **No `#ifdef` for device/platform branching.** The engine's display dimensions
  (`ROWS`, `COLS`, `DROWS`, `MESSAGE_LINES`) are compile-time `#define`s that
  statically size global arrays, and one compiled binary serves both iPhone and
  iPad. Per-device behavior is therefore selected at **runtime** via `extern boolean`
  flags that the Swift layer sets at startup.
- **Runtime flags live in `Globals.c`** (definition + a tiny setter) and are
  declared in `Rogue.h`. The Swift layer calls the setter — see
  `setKeyboardLabelsEnabled` / `setPhoneLayout`.
- **Keep changes minimal and gated.** A change that should only affect one device
  or one UI element should be opt-in via a flag or a dedicated button flag, never a
  blanket edit to shared engine logic.

---

## Change log

### 2026-07-07 — Item-detail box: reserve room for action buttons so long descriptions keep "call"

**What.** `printTextBox`'s auto-widen only widened until the **text** fit above the flavor/button
chrome (`ROWS-2`), ignoring the action buttons drawn *below* the text, which wrap to a second
double-spaced line. A long description left the text just fitting but pushed the wrapped button line
("call"/"relabel") onto the chrome rows, where it was lost. Now reserves 4 rows in the widen loop
when `buttonCount > 0`, so the box widens until text **and** buttons fit. Presentational; no RNG /
save / recording impact.

### 2026-07-07 — iPhone menu magnify fix: clear on text-input prompts (Save recording / seed entry)

**What.** `IO.c getInputTextString` now calls `clearBrogueMenuBox()` at its start. A text-input
prompt (e.g. "Save recording as…", seed entry) is NOT a button menu, so it reports no rect — and the
save/quit flow reaches it straight from a menu without returning to play, leaving the menu magnify
engaged on a stale rect, which tore the prompt. Presentational; no RNG / save / recording impact.
The same `clearBrogueMenuBox()` is applied at the start of the full-screen **Discovered-items** view
(`printDiscoveriesScreen`) — also a non-menu overlay (`waitForKeystrokeOrMouseClick`, no rect) that
should render at 1×. (Classic 1.7.5 has no Feats screen.)

### 2026-07-07 — iPhone menu magnify: report menu rects to the host (title / inventory / dialogs)

**What.** Ports the iPhone "menu magnify" (from Brogue SE/CE) to Classic: the host magnifies just a
menu's cells to a readable, tappable size over the untouched 1× screen. The engine only reports the
menu's window-cell rect. Classic uses the `RogueDriver.mm` bridge (not the `BrogueCEHost` protocol),
so it gets its own bridge functions; the host gate ("a rect is reported") and teardown (return to
play, which Classic's game events already drive) are shared and work as-is. Presentational; no RNG /
save / recording impact.

- **`RogueDriver.mm`:** new `setBrogueMenuBox(x,y,w,h)` → `[brogueViewController setMenuBox:…]` and
  `clearBrogueMenuBox()` → `[brogueViewController clearMenuBox]`, mirroring `setBrogueExamineBox`.
- **`Buttons.c` `buttonInputLoop`:** after `initializeButtonState`, calls `setBrogueMenuBox(...)` with
  the loop's window rect + a 1-cell shadow trim. Single choke point → covers inventory (Items.c),
  action menu and dialogs (IO.c).
- **`MainMenu.c` `titleMenu`:** reports the flat title menu's rect each redraw (it uses
  `processButtonInput`, not `buttonInputLoop`), and `clearBrogueMenuBox()` on exit so a following
  native/engine screen isn't corrupted by stale cells. Raised the flame title
  (`MENU_TITLE_OFFSET_Y` −2 → −5) to match SE/CE. Classic has no edition badge.
- **Determinism:** read-only reporting; no RNG, no save/recording fields. Title offset is cosmetic.

### 2026-07-05 — Continue-travel command + reactive center d-pad button

**What.** The Classic half of the touch-friendly "continue my interrupted journey" command (see
`BrogueSE/Engine/IOS_MODIFICATIONS.md` for the full rationale), using Classic's coordinate-array and
`ios*` naming. An iOS-platform QoL feature added identically to all three engines.

- **Key.** `#define CONTINUE_TRAVEL_KEY (128+21)` in `Rogue.h` — synthetic, button-only code; value
  matches CE and SE. Round-trips cleanly through Classic's keystroke compressor (149 is above
  `UNKNOWN_KEY`, so `compressKeystroke`/`uncompressKeystroke` pass it through as a raw byte).
- **Dispatch.** `mainInputLoop`'s cursor-confirm (`doEvent`) branch intercepts `CONTINUE_TRAVEL_KEY` →
  `travelRoute(path, steps)` (Classic's `short path[1000][2]`) — the exact displayed route, the fast
  primitive a confirming tap uses, not `travel()`→`travelMap` (slow, different path). No explicit
  `recordKeystroke`: `travelRoute`→`playerMoves` records each step's direction key, so the journey
  replays as its moves. Determinism-safe.
- **Reactive-button state.** `refreshScreen` calls a new
  `iosSetTravelPending(coordinatesAreInMap(rogue.cursorLoc[0], rogue.cursorLoc[1]))` extern (defined in
  `RogueDriver.mm`, deduped, → `[brogueViewController setTravelPending:]`) so the host can swap the
  center d-pad button between the footprints "continue" glyph and the `zzz` glyph.
- **Scope.** Walks past *already-seen* monsters and re-stops on a *new* disturbance — same as
  re-clicking; no new power, no RNG/save impact. No-op when idle. Kept identical across Classic / CE / SE.

### 2026-07-05 — Examine description box: report its rect (fit-zoom) + suppress it for zoomed play-field examines

**What.** iPhone examine-box hooks, identical to CE/SE's (see `BrogueSE/Engine/IOS_MODIFICATIONS.md` for the
full rationale), using Classic's `setBrogue*` naming. (1) `printTextBox` stashes its rect (`x2, y2, width,
lineCount + padLines`) in file-static `gLastTextBox{X,Y,Width,Height}`; the cursor/examine loop reports it
via a new `setBrogueExamineBox(x,y,w,h)` extern just before `setBrogueExamining` so the host can zoom to
*fit* the box instead of dropping to 1×. (2) The loop gates `printMonsterDetails`/`printFloorItemDetails`
(Classic's `(monst, rbuf)` / `(theItem, rbuf)` signatures) on `!brogueShouldSuppressExamineBox()` so a box
triggered by a zoomed play-field drag-hold is skipped — the sidebar highlight + one-line flavor still show.

- **Bridge:** `RogueDriver.mm` defines `setBrogueExamineBox` (→ `[brogueViewController setExamineBox:…]`)
  and `brogueShouldSuppressExamineBox` (→ `[brogueViewController shouldSuppressExamineBox]`).
- **Scope:** pure presentation; no gameplay/RNG/save impact. iPhone-only in effect (host consumers are
  phone-gated). Kept identical across Classic / CE / SE.

### 2026-06-16 — On-screen ESC button during targeting (parity with CE/SE)

**What.** While aiming a throw/zap, Classic now shows the on-screen ESC button so a touch player can
cancel the aim — CE/SE already did this; Classic was the only engine without it. Tapping it sends
`ESCAPE_KEY` (27), which `moveCursor` reads as a cancel, exactly as the physical Escape key does.

**Why.** Classic has no `uiMode == ShowEscape` event (CE drives the ESC button's visibility through
its coarse `uiMode`); Classic's discrete `setBrogueGameEvent` stream had no targeting signal, so
`escButtonWanted` stayed false and the button never appeared during an aim.

**Engine side.** New `setBrogueTargeting(boolean)` bridge (declared in `Rogue.h`), called from
`chooseTarget` (`Items.c`): `true` once the aiming loop begins (after the playback early-return, so
recordings don't trigger UI), `false` at each of the three exit points (cancel, self-target, confirm).
Display-only and consumes no RNG, so saves/recordings are unaffected. Mirrors CE's `ceSetTargeting`.

**Where.** `setBrogueTargeting` (Rogue.h decl; `RogueDriver.mm` definition — deduped, like
`setBrogueExamining`, since `chooseTarget` has several exits); enter/exit calls in `chooseTarget`
(`Items.c`). Platform side: `BrogueViewController.setClassicTargeting(_:)` toggles `escButtonWanted`
(visibility) in addition to repositioning the button + enabling the magnifier (what `setCETargeting`
already does for CE). Classic engine only.

### 2026-06-15 — Keyboard labels disabled; hardware-keyboard presence drives UI instead

**What.** The in-game hotkey labels are turned off (they reflect the Classic key layout and would
mismatch the new Modern default — see the "Default to Modern keyboard layout" change). A hardware
keyboard now instead: hides the on-screen d-pad and ESC button (platform/Swift side — redundant with
the keyboard's arrows / Escape), and surfaces the "Press <?> for help" welcome hint (the only help
affordance left with labels — and their help button — gone).

**Engine side.** `KEYBOARD_LABELS` stays at its `false` default — the host no longer enables it. A new
`HARDWARE_KEYBOARD_CONNECTED` global (Globals.c / Rogue.h), set by the host via
`setHardwareKeyboardConnected()` on GCKeyboard connect/disconnect, tracks keyboard presence
independently. `welcome()` now gates the help-menu hint on `HARDWARE_KEYBOARD_CONNECTED` rather than
`KEYBOARD_LABELS`. The label infrastructure (`setKeyboardLabelsEnabled`) is left intact but unused,
so labels can be re-enabled (and remapped for Modern) later.

**Where.** `HARDWARE_KEYBOARD_CONNECTED` (Globals.c, Rogue.h); `setHardwareKeyboardConnected`
(Globals.c, Rogue.h); welcome help-prompt gate (RogueMain.mm). Platform behavior (d-pad / ESC hide)
lives in BrogueViewController.swift. Applies to all three engines.

### 2026-06-14 — Tag the welcome line with the engine flavor (iOS port)

**What.** With three selectable engines, the opening adventure-log line now ends with the engine
flavor in parens — `… Dungeons of Doom! (Brogue)` for this (Classic) engine — so it's obvious which
one is running. Display-only (a `message()` string, not an input), so recordings/saves are unaffected.

**Where.** `welcome()` in `RogueMain.mm`.

### 2026-06-14 — Backport: seed persistence + selectable keyboard schemes + modifier plumbing

**What.** Backported from the `se-game-mode` line (without the gameplay WIP), mirroring the BrogueCE
engine. Full design: `docs/design/keyboard-schemes.md`; engine-side details in
`BrogueCE/Engine/IOS_MODIFICATIONS.md`.

- **Seed persistence** — `loadPersistedSeed`/`persistLastSeed` (NSUserDefaults, in `RogueDriver.mm`),
  restored in `rogueMain` (`RogueMain.mm`) and synced from `Recordings.c`; the seed prompt is pre-filled
  and `requestKeyboardInput` gained a `numeric` arg for a number pad.
- **Hardware keyboard modifiers** — the shared `BrogueViewController` key queue now carries real
  Shift/Ctrl + a `raw` flag (was byte-only, modifiers hardcoded to 0), fixing Shift/Ctrl-run; arrows are
  scheme-independent. `RogueDriver.mm` sets the event flags and runs `raw` keys through the scheme.
- **Selectable keyboard schemes** — `enum keyboardScheme` + `rogueKeyboardScheme` (default CLASSIC) +
  `applyKeyboardScheme()` (`IO.c`); the Modern right-hand grid (`u/o`,`m/.` diagonals around the
  `i/j/k/l` cross — `i`=up,`j`=left,`k`=down,`l`=right — plus `,`=down), Shift/Ctrl-run, displaced
  inventory/equip/messages/stairs, quit-removed-on-tablet, and the scheme-aware `printHelpScreen` with a
  Tab toggle. The vi keys `h`/`y`/`b`/`n` are inert in Modern (only the grid moves the player; `y`/`n`
  stay free for yes/no). Persisted via `persistKeyboardScheme` under the shared `"keyboard scheme"`
  NSUserDefaults key (same key in all three engines, so the scheme carries across Classic/CE/SE).

Default is Classic, so behavior is unchanged until the player opts in via `?` → Tab.

**Where.** `Rogue.h`, `Globals.c`, `IO.c`, `RogueMain.mm`, `Recordings.c`; platform files
(`BrogueViewController.swift`/`CEHost.swift`/`RogueDriver.mm`/`RogueScene.swift`) shared with BrogueCE.

### 2026-06-11 — Port BrogueCE's rethrow command

**What.** Added the rethrow command (`RETHROW_KEY`, Shift+T): repeat the last thrown
item, auto-aiming at the last target. Classic did not have this command at all.

**Why.** A keyboard shortcut bound to `RETHROW_KEY` carries over when a player plays
BrogueCE and then switches to Classic. Classic's `executeKeystroke` had no case for it,
so the key silently no-opped. Porting CE's behavior makes the shortcut work instead of
appearing broken.

**Where.**
- `Rogue.h` — `#define RETHROW_KEY 'T'`; `item *lastItemThrown;` added to the `rogue`
  struct (after `lastTarget`); `throwCommand` gains a `boolean autoThrow` parameter.
- `Items.c` — `throwCommand(item *theItem, boolean autoThrow)`: when `autoThrow` and
  `rogue.lastTarget` is a valid, visible, reachable enemy on this depth, skip the
  targeting prompt and aim there directly (predicate matches `chooseTarget`'s own
  auto-target gate). After a successful throw, save `rogue.lastItemThrown` (the carried
  stack) or clear it when the last one was thrown. The inventory-action caller passes
  `false`.
- `IO.c` — `executeKeystroke` gains a `RETHROW_KEY` case: rethrow when
  `lastItemThrown != NULL && itemIsCarried(...)`, else fall through to a normal throw
  prompt (`throwCommand(NULL, false)`) — same no-op-avoidance as the CE side.

This doesn't affect the save/recording format: rethrow expands to the same recorded
keystroke sequence as a normal throw (`THROW_KEY` + item letter + target click), so
playback is unchanged.

### 2026-06-06 — Suspend pinch-zoom while an entity description box is shown

**What.** When a creature/item description box lingers in the cursor loop (e.g. the
player taps an entity in the sidebar), the host suspends the iPhone pinch-zoom to 1×
so the box isn't magnified/clipped, then restores it — matching menu/inventory.

**Why.** The description box (`printMonsterDetails`/`printFloorItemDetails` →
`printTextBox`) renders into the dungeon cells but fired no host signal, so it was
drawn magnified and ran off-screen while zoomed.

**Where.** `IO.c` — `extern void setBrogueExamining(boolean);` at file top; in
`mainInputLoop`'s cursor `do/while`, `setBrogueExamining(textDisplayed)` right before
`moveCursor` and `setBrogueExamining(false)` right after the loop. Defined (with
`extern "C"`) in `RogueDriver.mm` (deduped) → `BrogueViewController setExamining:`. The
host only suspends zoom when the box was armed by a **sidebar single-tap** (`examineArmed`,
set in `touchesEnded`); auto-appearing boxes (auto-explore stopping on an item, tap-to-move
over a monster) aren't armed and don't zoom out — that previously flickered while exploring.
Mirrors CE's `ceSetExamining`.

### 2026-06-02 — iPhone: taller tap area for the bottom button bar

**What.** On iPhone only, the in-game bottom button bar (Explore / Rest / Search /
Menu / Inventory) gets a **3-grid-row-tall tap area** (the button's row plus the two
rows above it) instead of the default 2. No visual change — the buttons still render
on a single row.

**Why.** The bar is drawn at `y = ROWS - 1` and Brogue buttons are inherently one row
tall (`brogueButton` has no height field). On a phone a grid row is ~11 pt, so the
single-row hit target was hard to tap. The buttons already carried
`B_WIDE_CLICK_AREA` (a 2-row area, rows 32–33), but row 34 is off-grid so only ~2
cells were usable. This adds one more usable row upward.

**Where.**
- `Rogue.h` — new `extern boolean PHONE_LAYOUT;` + `setPhoneLayout(boolean)` proto
  (mirrors `KEYBOARD_LABELS`); new button flag `B_TALL_CLICK_AREA = Fl(6)` in
  `enum BUTTON_FLAGS`.
- `Globals.c` — `PHONE_LAYOUT` definition + `setPhoneLayout` body.
- `IO.c` — `initializeMenuButtons()` sets `B_TALL_CLICK_AREA` on each bar button
  **only when `PHONE_LAYOUT`** is true.
- `Buttons.c` — `processButtonInput()` hit-test honors `B_TALL_CLICK_AREA` by
  accepting `0 <= (button.y - y) <= 2` (two rows upward).
- `PlatformCode/BrogueViewController.swift` — calls
  `setPhoneLayout(UIDevice.current.userInterfaceIdiom == .phone ? 1 : 0)` at startup.

**Gating / safety.**
- iPad: `PHONE_LAYOUT` stays `false` → `B_TALL_CLICK_AREA` is never set → unchanged.
- Other button bars (title menu, inventory, confirmation dialogs) use
  `B_WIDE_CLICK_AREA` but **never** the new flag, so they're unaffected on both
  platforms. The hit-test's existing x-range check still confines the effect to the
  columns under each button label.

**Known, accepted trade-off.** On iPhone, a tap on the bottom dungeon row
(window row 31) that lands directly under a button label now triggers the button
instead of the map cell. Limited to the columns beneath the buttons; the sidebar
and the gaps between buttons remain map-tappable.

**Companion Swift change.** Because the bottom dungeon row is now part of the bar's
tap area, the magnifying glass is suppressed on that row on iPhone — otherwise a
press/drag there would pop the magnifier over the map while the player is aiming for
a button. See `canShowMagnifier(at:)` in `PlatformCode/BrogueViewController.swift`
(the bottom bound is `cell.y < 31` on iPhone vs. the default `< 32`). Note this
suppresses the magnifier across the whole bottom row on iPhone, not just the columns
under the buttons — Swift doesn't know the engine's button extents, and losing
pinch-magnify on that thin bottom sliver is an accepted simplification.

---

## Catalog of pre-existing iOS divergences

These were already present in the vendored engine before the change log above. They
are described from the code as it stands; rationale is inferred from comments and
behavior.

### `KEYBOARD_LABELS` — keyboard vs. touch prompt text
Runtime flag (`Rogue.h`, `Globals.c`, `setKeyboardLabelsEnabled`). Set from Swift
based on whether a hardware keyboard is connected. When off, prompts/labels use
touch phrasing ("Touch anywhere to continue", "touch an item for more info",
"Exploring... touch anywhere to stop"); when on, they use keystroke hints. Branches
appear throughout `IO.c`, `Movement.c`, `Items.c`, `Recordings.c`.

### Touch-driven button interaction (`Buttons.c`)
`processButtonInput()` handles `MOUSE_ENTERED_CELL` so a depressed button's pressed
highlight follows the finger during a drag, and the bottom bar uses
`B_WIDE_CLICK_AREA` for a more forgiving (2-row) touch target. These adapt Brogue's
mouse-hover button model to touch.

### On-screen Explore button: single-tap auto-explore (`IO.c`)
The `exploreImmediately` flag (set in `mainInputLoop` when the on-screen Explore
button is tapped) makes a single tap auto-explore immediately, rather than the
desktop two-step "tap once to preview the path, tap again to commit." Keyboard `x`
(delivered as a `KEYSTROKE`) is unaffected.

### Game Center achievement hooks
`submitAchievementForCharString(...)` calls are injected into engine logic
(`Combat.c` dragonslayer, `Items.c` specialist, `Monsters.c` jellymancer), using the
`kAchievementUTF8*` constants in `Rogue.h`, to report achievements to iOS Game Center.

### Engine → platform event bridge (`setBrogueGameEvent`)
The engine signals game-state transitions (title, new game, inventory open/closed,
death, playback, etc.) to the Swift layer via `setBrogueGameEvent(...)`, called from
`MainMenu.c`, `IO.c`, and `RogueMain.mm`. The UI uses these to show/hide on-screen
controls. Rendering and input are bridged in `PlatformCode/RogueDriver.mm`
(`plotChar`, the touch→mouse-event path).

### Background suspend & resume (`setClassicBackgroundSaveRequested` / `clearClassicResumeMarker`)
Backgrounding the app snapshots exact game state to disk; if iOS evicts the suspended process, the
next launch resumes straight into the game (no title screen). Returning before an eviction is
untouched. No vendored engine `.c` changes — it rides on existing machinery: `flushBufferToFile()`,
`initializeLaunchArguments()` (defined in `RogueDriver.mm`; the engine calls it at the top of
`mainBrogueJunction` in `MainMenu.c`) injecting `NG_OPEN_GAME` + a resume path, and
`switchToPlaying()`'s copy-to-fresh-`LastGame` + `DELETE_SAVE_FILE_AFTER_LOADING`. On background the
Swift host sets a flag; the engine thread, at its next poll in `nextKeyOrMouseEvent` and
`pauseForMilliseconds` (RogueDriver.mm), flushes and writes a one-shot resume marker
(`"classic resume path"` in NSUserDefaults), consumed by `initializeLaunchArguments` on cold launch.
Platform lifecycle (`appDidEnterBackground`/`appDidBecomeActive`, the cold-vs-warm guard) lives in
`BrogueViewController.swift`; applies to all three engines. Full rationale:
[docs/design/background-suspend-resume.md](../../docs/design/background-suspend-resume.md).

---

## Adding a new iPhone-only engine tweak

The established pattern (see the 2026-06-02 entry):

1. If a new device flag is needed, add an `extern boolean` + setter in `Rogue.h`,
   define it in `Globals.c`, and call the setter from the Swift layer
   (`BrogueViewController`). Reuse `PHONE_LAYOUT` if "is iPhone" is sufficient.
2. Prefer a **dedicated `brogueButton`/state flag** over editing shared logic, so the
   change is opt-in and can't leak into other screens.
3. Do **not** change `ROWS` / `MESSAGE_LINES` / `DCOLS` / `DROWS` — they are
   compile-time constants baked into static arrays and mirrored in the Swift render
   layer; changing them is a cross-cutting, both-platforms refactor.
4. Record the change in the change log above (what / why / where / gating / trade-offs).
