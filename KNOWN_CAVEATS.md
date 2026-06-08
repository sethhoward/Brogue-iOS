# Known caveats & accepted side effects

Living list of **deliberate tradeoffs and known limitations** in the iOS port — the
things that look like bugs but are expected. Check here before chasing a "bug": if
it's listed, it's a documented decision, not a regression. When you fix one, move it
to a "Resolved" note or delete it. When you accept a new tradeoff, add it.

Most entries below are from the iPhone touch/zoom work (pinch-to-zoom, the bottom
button tap-band, both-landscape support, d-pad notch avoidance). Pinch-to-zoom is a
toggle (title → Options → "Pinch zoom (experimental)"), now **on by default** — an
explicit prior choice is respected (see `RogueScene.isPinchZoomEnabledSetting`). The
zoom-related caveats apply whenever it's enabled, i.e. by default.

## Pinch-to-zoom (iPhone)

- **Glyphs are soft at high zoom.** Cell textures render at 1× cell resolution and the
  zoom container scales them up, so at ~2.5× they look fuzzy. Re-rendering textures per
  zoom level is out of scope.
- **`SKCropNode` adds an offscreen pass.** The zoom layer composites the dungeon cells
  through a crop node; on older iPhones watch the frame rate. Only active when the
  experimental zoom is on (the layer is built lazily).
- **Zoom transform can be briefly off after a mid-game rotation.** If you're zoomed and
  rotate between landscapes, the pan/clamp may be momentarily wrong until the next pan or
  player move re-clamps it. There is no zoom reset on rotation (self-correcting).
- **Simultaneous zoom + pan can slightly over-translate.** Pinch (scale about the live
  centroid) and the two-finger pan (translation) run together; moving the fingers while
  also changing their spread double-counts centroid movement a little. Pure zoom or pure
  pan are exact.
- **A pinch needs ~10% spread change to engage (`zoomActivationThreshold`).** Until the
  fingers' spread crosses that, the pinch stays dormant and a two-finger drag reads as a
  pure pan — deliberate, to stop incidental spread drift during a pan from nudging the
  zoom. The side effect: a very gentle, slow pinch start is briefly treated as a pan
  before zoom latches on (then zoom + pan coexist for the rest of the gesture).
- **Rubber-band / snap-back below 1× was removed (behavior change).** Pinching in just
  stops at fit (1×) with no bounce — deliberate, to kill a motion that read as a "snap."
- **Only a sidebar SINGLE-tap suspends zoom, and it's toggleable.** Single-tapping a
  creature/item in the **sidebar** shows its description box and, like menus/inventory,
  drops the zoom to 1× so the box isn't clipped, restoring on dismiss. Gated on
  `examineArmed`, which is **deferred** ~0.3s past the double-tap window: a **double-tap**
  (attack / run toward) cancels the pending arm, so it never zooms out — only a lone single
  tap does. Also cleared when the box ends or on a competing input (map tap, bottom-bar
  button). So boxes that auto-appear — auto-explore stopping on an item, a tap-to-move over
  a monster — and map-tap / long-press examines do **not** zoom out. The whole behavior is
  an Options toggle, **"Zoom out on examine" (default on)**, shown only when pinch zoom is
  on (`RogueScene.isExamineZoomEnabledSetting`). Side effect of the defer: the zoom-out
  begins ~0.3s after the tap (the box itself still appears immediately).
- **Auto-follow re-centers on the engine thread.** To keep the camera in lockstep with
  the cell redraw (a main-queue hop made the map lurch a frame behind the player —
  visible stutter when zoomed), `setPlayerWindowX` applies the zoom transform directly on
  the engine thread, mirroring how `setCell` mutates SK nodes there. The cost: `zoomScale`
  / `zoomOriginPt` and the container transform can be touched by both the engine thread
  (movement) and the main thread (a gesture) at once. In practice you don't pinch and walk
  simultaneously; a collision is at worst a one-frame visual glitch, not a crash.
- **Clearing the travel cursor on gesture-begin also acknowledges messages.** Starting a
  pinch/pan injects `ESCAPE_KEY` to erase the engine's travel path; the engine also runs
  `confirmMessages()` on Escape, so a pending `--more--` prompt would be dismissed if a
  pinch starts while it's up. (Could be gated on "a cursor path is actually active.")

## Bottom button tap-band (iPhone)

- **Band overlaps the home-indicator gesture strip.** The tap-band reaches the screen's
  bottom edge, so the very first touch in the lowest few points may be deferred by iOS;
  targets above the extreme edge work fine.
- **Button-center table can drift from the engine.** Band taps snap to hardcoded button
  centers (cols 28/44/59/73/88) mirroring `initializeMenuButtons`; if the engine button
  layout changes, update the table (`bottomButtonCenterColumns`). It also assumes the
  normal 5-button bar, not playback mode's different set (gated off in playback anyway).
- **Bottom-row button backgrounds extend to the screen edge (taller-looking buttons).**
  In `RogueScene.relayoutCells`, the bottom row's cell *backgrounds* (cols ≥ 21) are
  stretched down through the tap-band to the scene bottom so the buttons read as taller,
  flush-to-bottom tabs. Only the background grows — the engine glyph stays on row 33, so
  the label sits toward the *top* of the taller button (deliberate; we don't re-center
  because the text is engine-drawn at a fixed row). The extra height equals
  `SKViewPort.bottomButtonBandPoints`, so the colored area and the tap-band stay in lockstep.

## Magnifier ↔ d-pad

- **D-pad suppression starts only when the magnifier is *visible*.** The d-pad is ignored
  while `!magView.isHidden`, but there's a ~0.2s delay between touch-down and the
  magnifier appearing; during that window the d-pad still responds. Gate on a
  "magnifier-touch-in-progress" flag if the gap is noticeable.

## Orientation / notch (iPhone, both landscapes)

- **Esc button is not notch-aware.** The on-screen escape button uses a fixed
  `(-80, 90)` transform, so in landscapeRight it can sit slightly off. The grid shift and
  the quick-action buttons follow the notch; the esc button does not (yet).
- **D-pad notch-avoidance is display-only and per-orientation.** In the orientation where
  the cutout is on the d-pad's side, the pad is always nudged clear of the safe area
  regardless of the saved position; a deliberate park under the cutout only persists in
  the orientation where it doesn't encroach. Recomputed on launch and rotation, never
  saved (so the saved/flush placement is preserved in the non-notch orientation).
