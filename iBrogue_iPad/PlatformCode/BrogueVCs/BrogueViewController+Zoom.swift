//
//  BrogueViewController+Zoom.swift
//  Brogue
//
//  The iPhone pinch-to-zoom subsystem: pinch / pan / hover / toggle gesture handling,
//  the zoom transform and its animation, auto-follow, and the examine-fit / menu-magnify
//  fit-zoom math. Extracted verbatim from BrogueViewController.swift as part of splitting
//  that file by function.
//

import UIKit
import SpriteKit
import QuartzCore

// COLS/ROWS shadow the C engine's macros (Rogue.h) with Int-typed, file-local
// constants — matching BrogueViewController.swift. They stay fileprivate to avoid a
// module-scope clash with the imported C COLS/ROWS (which are Int32).
fileprivate let COLS = 100
fileprivate let ROWS = 34

// MARK: - Pinch-to-zoom (iPhone)

extension BrogueViewController: UIGestureRecognizerDelegate {

    /// Installs the pinch + two-finger-pan recognizers on the SpriteKit viewport.
    /// iPhone only; iPad keeps the flat, un-zoomable scene.
    func setupZoomGestures() {
        guard isPhoneIdiom else { return }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleZoomPinch(_:)))
        pinch.name = "zoomPinch"
        pinch.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleZoomPan(_:)))
        pan.name = "zoomPan"
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        // Two-finger double-tap toggles fully out to 1× and back to the prior zoom.
        // Distinct from the engine's one-finger double-tap-to-move (different touch
        // count), and its touches never reach the engine (touchesBegan flushes any
        // ≥2-finger touch), so it can't trigger a cursor select or move.
        let toggle = UITapGestureRecognizer(target: self, action: #selector(handleZoomToggleTap(_:)))
        toggle.name = "zoomToggle"
        toggle.numberOfTouchesRequired = 2
        toggle.numberOfTapsRequired = 2
        toggle.delegate = self
        skViewPort.addGestureRecognizer(pinch)
        skViewPort.addGestureRecognizer(pan)
        skViewPort.addGestureRecognizer(toggle)
        zoomPinch = pinch
        zoomPan = pan
        zoomToggle = toggle
    }

    /// iOS port (iBrogue): installs the hover-to-examine recognizer. Inert without a hardware
    /// pointer (a finger never produces hover callbacks), so it's safe on every idiom — including
    /// Mac Catalyst, where GCKeyboard reports the Mac keyboard and the screen is already in
    /// "desktop mode" (d-pad/ESC hidden, magnifier suppressed). Attached to the root view so its
    /// locations share the touch coordinate space (location(in: view)).
    func setupHoverGesture() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.name = "examineHover"
        view.addGestureRecognizer(hover)
        hoverGesture = hover
    }

    /// Translates pointer hover into the engine's non-committal examine event. Pure platform
    /// layer: enqueues a synthetic `.moved` touch, which every bridge already maps to
    /// MOUSE_ENTERED_CELL — so no engine/bridge/protocol change, and all three engines benefit.
    /// Hover never enters the recording stream (only committed clicks/keystrokes are recorded),
    /// so there is no determinism or replay impact.
    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        // Pointer left the view: forget the last cell so re-entry re-emits.
        guard g.state == .began || g.state == .changed else {
            lastHoverCell = CGPoint(x: -1, y: -1)
            return
        }
        // Examine is meaningful only while the map cursor is live: normal play (sidebar +
        // map describe) and targeting (reticle follows the pointer). Never in menus.
        guard gameplayControlsActive || isTargeting else { return }
        // Don't examine through an in-progress pinch/pan, the on-screen d-pad, or the bottom
        // band. These chrome guards are no-ops once a keyboard hides the controls (the common
        // case) and still protect the rare keyboardless-mouse case.
        guard !multiTouchGestureActive else { return }
        let location = g.location(in: view)
        if isBandTouch(location) { return }
        if dContainerView.hitTest(g.location(in: dContainerView), with: nil) != nil { return }

        // Mimic sdl2-platform.c: only emit when the pointer crosses into a new cell. getCellCoords
        // applies the pinch-zoom inverse for the comparison; the event itself carries the raw
        // location, leaving the bridge's unzoomedPoint transform to resolve the cell (as for touches).
        let cell = getCellCoords(at: location, viewport: skViewPort)
        if cell == lastHoverCell { return }
        lastHoverCell = cell
        addHoverEvent(event: UIBrogueTouchEvent(phase: .moved, location: location))
    }

    // Pinch + two-finger pan + the two-finger double-tap toggle must run together,
    // but not alongside unrelated recognizers (e.g. the dpad's drag).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let zoomNames: Set<String> = ["zoomPinch", "zoomPan", "zoomToggle"]
        return zoomNames.contains(g.name ?? "") && zoomNames.contains(other.name ?? "")
    }

    // Only zoom when the gesture is centered on the dungeon map — not over the
    // sidebar, message lines, or the bottom button bar. Uses the same play-area
    // helper as touch routing; getCellCoords is zoom-aware so this holds whether
    // or not the map is already zoomed.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        let zoomNames: Set<String> = ["zoomPinch", "zoomPan", "zoomToggle"]
        guard zoomNames.contains(g.name ?? "") else { return true }
        return pointIsInPlayArea(point: g.location(in: view))
    }

    @objc private func handleZoomPinch(_ g: UIPinchGestureRecognizer) {
        guard isPhoneIdiom, gameplayControlsActive || isTargeting else { return }
        switch g.state {
        case .began:
            // Start the pinch from what's actually on screen. Usually the applied
            // transform already equals the canonical zoom, but at game-open the zoom
            // is seeded (zoomScale>1, origin .zero) while the display is still 1×
            // pending the first auto-follow; without this sync the first frame would
            // jump to the seeded scale at origin .zero — i.e. snap to the top-left
            // corner — before the pinch pans it back.
            zoomScale = appliedScale
            zoomOriginPt = appliedOrigin
            pendingLaunchZoom = false // manual zoom supersedes the one-shot launch zoom
            multiTouchGestureActive = true
            clearTouchEvents()       // drop any tap the first finger queued
            clearTravelCursor()      // erase any travel path the first finger drew
            hideMagnifier()          // invalidates the pending magnifier timer too
            lastPinchScale = 1.0     // g.scale resets to 1 at each gesture start
            pinchZoomEngaged = false // dormant until the spread crosses the threshold
        case .changed:
            // Dormant until the cumulative spread (g.scale is relative to gesture
            // start) crosses the activation threshold, so a two-finger pan with
            // incidental spread drift reads as a pure pan. Once latched, zoom and
            // pan coexist for the rest of the gesture (Photos-style).
            if !pinchZoomEngaged {
                guard abs(g.scale - 1.0) >= BrogueViewController.zoomActivationThreshold else {
                    lastPinchScale = g.scale   // keep tracking so engagement has no jump
                    return
                }
                pinchZoomEngaged = true
                lastPinchScale = g.scale       // anchor at current spread: first zoom frame is a no-op
            }
            // Incremental scale about the live two-finger centroid: keep the
            // content point under the centroid fixed as the scale changes. No
            // captured anchor, so no jump; clamped to [1×, max], so no snap-back.
            let factor = g.scale / lastPinchScale
            lastPinchScale = g.scale
            let newScale = min(max(zoomScale * factor,
                                   BrogueViewController.zoomMinScale),
                               BrogueViewController.zoomMaxScale)
            let applied = zoomScale > 0 ? newScale / zoomScale : 1
            let c = g.location(in: view)
            zoomOriginPt = CGPoint(x: c.x - applied * (c.x - zoomOriginPt.x),
                                   y: c.y - applied * (c.y - zoomOriginPt.y))
            zoomScale = newScale
            pushZoom()
        case .ended, .cancelled:
            // Remember the level the player settled on, so the next run starts here.
            storedZoomScale = zoomScale
        default:
            break
        }
    }

    @objc private func handleZoomPan(_ g: UIPanGestureRecognizer) {
        guard isPhoneIdiom, gameplayControlsActive || isTargeting, zoomScale > 1.0 else { return }
        switch g.state {
        case .began:
            // Sync to the on-screen transform (see handleZoomPinch .began): if the
            // canonical zoom is seeded but the display is still 1×, a pan must not
            // apply the seeded scale. After this the guard above re-evaluates each
            // .changed, so panning a 1× display is a no-op until a pinch zooms in.
            zoomScale = appliedScale
            zoomOriginPt = appliedOrigin
            manualPanActive = true
            multiTouchGestureActive = true
            clearTravelCursor()      // erase any travel path the first finger drew
            hideMagnifier()
        case .changed:
            let t = g.translation(in: view)
            zoomOriginPt.x += t.x
            zoomOriginPt.y += t.y
            g.setTranslation(.zero, in: view)
            pushZoom()
        default:
            // Keep manualPanActive set until the next real player move re-centers.
            break
        }
    }

    /// Two-finger double-tap: toggle fully out to 1× and back to the prior zoom.
    /// When zoomed in, remembers the current magnification and eases out to 1×;
    /// when already out, eases back to that remembered level (falling back to the
    /// persisted preference), recentered on the player. The two-finger touches are
    /// suppressed by touchesBegan, so this never leaks a cursor select or move.
    @objc private func handleZoomToggleTap(_ g: UITapGestureRecognizer) {
        guard isPhoneIdiom, pinchZoomActive, gameplayControlsActive || isTargeting else { return }
        clearTouchEvents()   // drop anything the fingers queued before the tap resolved
        hideMagnifier()
        manualPanActive = false
        if zoomScale > 1.0 {
            // Remember the exact view (scale + origin) to come back to, then ease out.
            zoomToggleRestoreScale = zoomScale
            zoomToggleRestoreOrigin = zoomOriginPt
            zoomScale = 1.0
            zoomOriginPt = .zero
            animateZoom(toScale: 1.0, toOrigin: .zero)
        } else {
            // Ease back to the remembered zoom (or the saved preference if none).
            let prior = zoomToggleRestoreScale > BrogueViewController.zoomMinScale
                ? zoomToggleRestoreScale : storedZoomScale
            let target = min(max(prior, BrogueViewController.zoomMinScale),
                             BrogueViewController.zoomMaxScale)
            guard target > 1.0 else { return }   // nothing to restore
            zoomScale = target
            // Pick the recenter target, in priority order — never the (0,0) corner:
            //   1. the live player cell (follow the player, freshest);
            //   2. the origin we captured on the way out (back to the same view);
            //   3. the dungeon-map center (last-resort fallback).
            let origin: CGPoint
            if let cell = lastPlayerWindowCell {
                origin = autoFollowOrigin(playerCell: cell)
            } else if zoomToggleRestoreScale > BrogueViewController.zoomMinScale {
                origin = zoomToggleRestoreOrigin
            } else {
                let f = dungeonFramePoints()
                origin = CGPoint(x: f.midX * (1 - zoomScale), y: f.midY * (1 - zoomScale))
            }
            zoomOriginPt = clampedOrigin(origin, scale: zoomScale)
            animateZoom(toScale: zoomScale, toOrigin: zoomOriginPt)
        }
    }

    /// The dungeon-map rectangle in UIKit points (window cols 21…99, rows 3…30),
    /// mirroring RogueScene.dungeonFrameInScene but in point space.
    private func dungeonFramePoints() -> CGRect {
        let w = skViewPort.effectiveWidthPoints
        let h = skViewPort.effectiveHeightPoints
        let li = skViewPort.leftInsetPoints
        let cw = w / CGFloat(COLS)
        let ch = h / CGFloat(ROWS)
        let left = li + 21 * cw
        let right = li + 100 * cw   // right edge of col 99
        let top = 3 * ch            // top edge of row 3
        let bottom = 32 * ch        // bottom edge of row 31 (full dungeon map)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Clamps the origin so the magnified map always fully covers the dungeon
    /// frame (no empty gutters). At ≤ 1× the map fills the frame, so the origin is pinned
    /// to .zero — there's nothing to pan, and this prevents a stray pinch-out origin from
    /// leaving the map shifted at "fully zoomed out".
    private func clampedOrigin(_ origin: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 1.0 else { return .zero }
        let f = dungeonFramePoints()
        let xLo = f.maxX * (1 - scale), xHi = f.minX * (1 - scale)
        let yLo = f.maxY * (1 - scale), yHi = f.minY * (1 - scale)
        return CGPoint(x: min(max(origin.x, xLo), xHi),
                       y: min(max(origin.y, yLo), yHi))
    }

    private func clampedDisplayScale(_ raw: CGFloat) -> CGFloat {
        if raw >= BrogueViewController.zoomMinScale {
            return min(raw, BrogueViewController.zoomMaxScale)
        }
        // Rubber-band resistance below 1×, with a hard floor.
        let resisted = 1 - (1 - raw) * 0.4
        return max(resisted, BrogueViewController.zoomRubberBandFloor)
    }

    private func pushZoom() {
        zoomOriginPt = clampedOrigin(zoomOriginPt, scale: zoomScale)
        setAppliedZoom(scale: zoomScale, origin: zoomOriginPt)
    }

    /// Origin that centers the player's window cell in the dungeon frame.
    private func autoFollowOrigin(playerCell: CGPoint) -> CGPoint {
        let f = dungeonFramePoints()
        let cw = skViewPort.effectiveWidthPoints / CGFloat(COLS)
        let ch = skViewPort.effectiveHeightPoints / CGFloat(ROWS)
        let li = skViewPort.leftInsetPoints
        // Player cell center in 1× view points.
        let px = li + (playerCell.x + 0.5) * cw
        let py = (playerCell.y + 0.5) * ch
        // Want player at frame center: f.mid = scale·p + origin.
        return CGPoint(x: f.midX - zoomScale * px, y: f.midY - zoomScale * py)
    }

    /// Scale + origin that fit the on-screen examine description box within the viewport
    /// (with a small margin), centered like auto-follow — so examining zooms only as far as
    /// needed to show the box instead of dropping to 1×, keeping the box text as large as
    /// legibly fits. Never zooms in past the current zoom, never below 1×. Returns nil when
    /// no box rect was reported (CE / Classic) or the box needs a full 1× zoom-out anyway,
    /// so the caller falls back to the plain 1× behavior.
    private func examineFitZoom() -> (scale: CGFloat, origin: CGPoint)? {
        guard let box = examineBox, box.w > 0, box.h > 0 else { return nil }
        // If the box starts left of the dungeon (window col 21 = mapToWindowX(0)), part of
        // it is drawn in the sidebar cells, which don't live in the zoom container and stay
        // 1× — magnifying would tear the box. Fall back to a plain 1× zoom-out instead.
        guard box.x >= 21 else { return nil }
        let w = skViewPort.effectiveWidthPoints
        let h = skViewPort.effectiveHeightPoints
        guard w > 0, h > 0 else { return nil }
        let cw = w / CGFloat(COLS)
        let ch = h / CGFloat(ROWS)
        let li = skViewPort.leftInsetPoints
        let boxW = CGFloat(box.w) * cw
        let boxH = CGFloat(box.h) * ch
        let f = dungeonFramePoints()   // the dungeon rect: rows 3–31, cols 21–99
        // Fit within the DUNGEON rect (not the whole screen), so the magnified box can't
        // spill up into the message log or down into the flavor / button rows. Centring on
        // f.mid then keeps it inside those bounds.
        let margin: CGFloat = 10       // TWEAK ME: gap kept around the box
        let fitThatFits = min((f.width - 2 * margin) / boxW, (f.height - 2 * margin) / boxH)
        // Cap below full zoom so a small box doesn't blow up (felt "too far").
        let scale = max(1.0, min(zoomScale, BrogueViewController.examineMaxScale, fitThatFits))
        guard scale > 1.0 else { return nil }   // fits only at ~1× → let the plain 1× path run
        // Box centre in 1× view points; centre it in the dungeon frame (f.mid = scale·c + origin).
        let boxCenterX = li + (CGFloat(box.x) + CGFloat(box.w) / 2) * cw
        let boxCenterY = (CGFloat(box.y) + CGFloat(box.h) / 2) * ch
        return (scale, CGPoint(x: f.midX - scale * boxCenterX, y: f.midY - scale * boxCenterY))
    }

    /// iOS port (iBrogue): scale + origin that fit the reported menu rect into the FULL viewport
    /// (with a margin), centered — the phase-0 title-menu magnify. Unlike examineFitZoom (which
    /// fits within the dungeon rect so an in-map box can't spill into the HUD), a menu owns the
    /// whole screen, so it fits/centers against the entire viewport. Capped at menuMaxScale; never
    /// below 1×. Returns nil when it only fits at ~1× (nothing worth magnifying).
    private func menuFitZoom(_ box: MenuBox) -> (scale: CGFloat, origin: CGPoint)? {
        guard box.w > 0, box.h > 0 else { return nil }
        let w = skViewPort.effectiveWidthPoints
        let h = skViewPort.effectiveHeightPoints
        guard w > 0, h > 0 else { return nil }
        let cw = w / CGFloat(COLS)
        let ch = h / CGFloat(ROWS)
        let li = skViewPort.leftInsetPoints        // 0 at the title (padding disabled there)
        let boxW = CGFloat(box.w) * cw
        let boxH = CGFloat(box.h) * ch
        let margin: CGFloat = 14                    // TWEAK ME: gap kept around the menu
        let fit = min((w - 2 * margin) / boxW, (h - 2 * margin) / boxH)
        let scale = max(1.0, min(BrogueViewController.menuMagnifyScaleSetting, fit))
        guard scale > 1.0 else { return nil }
        // Box centre in 1× view points; centre it in the viewport (center = scale·c + origin).
        let boxCenterX = li + (CGFloat(box.x) + CGFloat(box.w) / 2) * cw
        let boxCenterY = (CGFloat(box.y) + CGFloat(box.h) / 2) * ch
        var ox = li + w / 2 - scale * boxCenterX
        var oy = h / 2 - scale * boxCenterY
        // Clamp the origin to the range that keeps the (virtual) grid extent covering the viewport,
        // so the magnified menu stays fully on-screen. For a menu flush against a grid edge (the
        // main menu sits at cols ~80–99) this right-aligns it against that edge rather than centring
        // it half-off; a menu nearer the middle is unaffected and stays centred. Forward map is
        // screenPt = scale·u + origin, grid 1× extent u ∈ [li, li+w] × [0, h].
        ox = min(li * (1 - scale), max((li + w) * (1 - scale), ox))
        oy = min(0, max(h * (1 - scale), oy))
        return (scale, CGPoint(x: ox, y: oy))
    }

    /// iOS port (iBrogue): apply the menu magnify for the current `menuBox` — the title menu, and
    /// (phase 1) in-game overlays: inventory, the action menu, and buttoned dialogs. iPhone only;
    /// instant (no animation). Scales ONLY the menu cells (a panel over the untouched 1× grid), not
    /// the whole grid. The gate is simply "a menu rect is reported": the engine reports one only
    /// while a button menu is up (reportTitleMenuBox / buttonInputLoop) and it's torn down on return
    /// to play. If the box only fits at ~1× it tears any prior magnify down instead, so a wide
    /// dialog following a narrow menu doesn't stay wrongly zoomed.
    func applyMenuMagnify() {
        guard isPhoneIdiom, let box = menuBox, let fit = menuFitZoom(box) else {
            tearDownMenuMagnify()
            return
        }
        skViewPort.rogueScene.applyMenuMagnify(
            colMin: box.x, colMax: box.x + box.w - 1,
            rowMin: box.y, rowMax: box.y + box.h - 1,
            scale: fit.scale, originXPoints: fit.origin.x, originYPoints: fit.origin.y)
        menuMagnifyEngaged = true
    }

    /// iOS port (iBrogue): tear down any menu magnify, returning the borrowed cells to the flat
    /// grid. Idempotent. The gameplay zoom transform is never touched by the menu path.
    func tearDownMenuMagnify() {
        guard menuMagnifyEngaged else { return }
        menuMagnifyEngaged = false
        menuBox = nil
        skViewPort.rogueScene.endMenuMagnify()
    }

    /// Whether the examine box is already fully on-screen at the *current* displayed
    /// transform — in which case examine leaves the view exactly as-is (no pan, no zoom).
    /// At ≤1× the box renders at its designed 1× position, which the engine already fit on
    /// screen, so it's always visible there — fully/low zoom gets no bells & whistles. When
    /// zoomed in, maps the box's 1× rect through the applied transform (p = u·scale + origin)
    /// and checks it's inside the play viewport, so a box that's clipped off-screen still
    /// gets fitted.
    private func examineBoxFullyVisible(_ box: ExamineBox) -> Bool {
        guard appliedScale > 1.0 else { return true }
        let w = skViewPort.effectiveWidthPoints
        let h = skViewPort.effectiveHeightPoints
        guard w > 0, h > 0 else { return true }
        let cw = w / CGFloat(COLS)
        let ch = h / CGFloat(ROWS)
        let li = skViewPort.leftInsetPoints
        let s = appliedScale, o = appliedOrigin
        let left   = (li + CGFloat(box.x) * cw) * s + o.x
        let right  = (li + CGFloat(box.x + box.w) * cw) * s + o.x
        let top    = (CGFloat(box.y) * ch) * s + o.y
        let bottom = (CGFloat(box.y + box.h) * ch) * s + o.y
        return left >= li && right <= li + w && top >= 0 && bottom <= h
    }

    /// Whether the engine should skip drawing the examine description box for the *current*
    /// cursor examine. True when zoomed in on screen AND the examine did NOT come from a
    /// sidebar tap — i.e. a play-field drag-hold, auto-explore stopping on an entity, hover,
    /// or tab-cycle — where the box, drawn into the magnified dungeon cells, would tear
    /// against the 1× sidebar/chrome. A deliberate sidebar tap (`examineFromSidebar`) is NOT
    /// suppressed: it zooms out to show the box readably. Inverting the test (suppress unless
    /// sidebar) is what catches the no-touch cases like auto-explore that a positive
    /// "finger on the play field" test missed. Queried by all three engines' examine loops
    /// via the bridge. iPhone-only. Presentational — a one-frame stale read is harmless.
    @objc func shouldSuppressExamineBox() -> Bool {
        return isPhoneIdiom && appliedScale > 1.0 && !examineFromSidebar
    }

    /// Tracks the player's window cell with the magnified camera. Called per player step
    /// (via `setPlayerWindowX`) from the ENGINE thread.
    ///
    /// With smoothing OFF this keeps the original behavior: snap the player to center
    /// instantly, in lockstep with the cell redraw on the engine thread (and, returning from
    /// a suspended ≈1× view, ease the zoom-in rather than snap).
    ///
    /// With smoothing ON (default) the follow is continuous and lives entirely on the main
    /// thread (where its CADisplayLink must run): a trailing exponential lerp for normal
    /// movement and blinks alike, and an instant snap when the dungeon `depth` changed (a true
    /// level transition — the old origin points at nothing on the new map). Engine-thread
    /// lockstep is deliberately given up: a *continuous* ease reads as intentional, unlike the
    /// one-frame lag that made an instant apply stutter.
    private func applyAutoFollow(playerCell: CGPoint, depth: Int) {
        guard zoomScale > 1.0 else { return }
        let target = clampedOrigin(autoFollowOrigin(playerCell: playerCell), scale: zoomScale)
        zoomOriginPt = target

        guard BrogueViewController.followSmoothingEnabled else {
            // Legacy path: instant, in-lockstep on the engine thread — except ease the
            // zoom-in when returning from a suspended (≈1×) view.
            if appliedScale < zoomScale - 0.001 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.zoomScale > 1.0, !self.manualPanActive else { return }
                    self.animateZoom(toScale: self.zoomScale, toOrigin: target)
                }
            } else {
                applyAppliedTransform(scale: zoomScale, origin: target)
            }
            return
        }

        // Smoothed follow: everything the link touches lives on main.
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.zoomScale > 1.0, self.gameplayControlsActive, !self.manualPanActive else { return }
            // Still easing in from a suspended / launch ≈1× view: let the scale animation own
            // the transform, just retargeting it at the player. It converges to full zoom, and
            // the next step (appliedScale == zoomScale) hands over to the follow proper.
            if self.appliedScale < self.zoomScale - 0.001 {
                self.animateZoom(toScale: self.zoomScale, toOrigin: target)
                return
            }
            // Baseline the depth on the first report after a reset (no spurious level-change).
            let levelChanged = (self.lastReportedDepth >= 0 && depth != self.lastReportedDepth)
            self.lastReportedDepth = depth
            if levelChanged {
                self.snapFollow(to: target)
            } else {
                self.updateFollow(to: target)
            }
        }
    }

    /// Feeds a new player-centered target to the smoothed follow (main thread); the running
    /// trail lerp then chases it. Used for every same-level move — a normal step, fast travel,
    /// or a blink all just ease over via the trail.
    private func updateFollow(to target: CGPoint) {
        followTargetOrigin = target
        ensureFollowLinkRunning()
    }

    /// Instantly centers on the player (a true level transition): cancels the trail and
    /// applies the target with no animation. Main thread only.
    private func snapFollow(to target: CGPoint) {
        followTargetOrigin = target
        setAppliedZoom(scale: zoomScale, origin: target) // cancels the follow + anim links, applies instantly
    }

    /// Per-frame smoothed-follow tick (main thread): a continuous exponential TRAIL that chases
    /// the (possibly still-moving) target. Sleeps itself once it converges and the player is idle.
    @objc private func stepFollow(_ link: CADisplayLink) {
        // Be defensive: if we somehow left full-zoom map play, stop (suspend/gesture/reset
        // each tear the link down through their own paths too).
        guard zoomScale > 1.0, appliedScale >= zoomScale - 0.001 else { cancelFollow(); return }
        let now = CACurrentMediaTime()
        let target = followTargetOrigin
        // Exponential trail toward the (possibly moving) target — frame-rate independent.
        let dt = max(0, now - followLastTickTime)
        followLastTickTime = now
        let tau = BrogueViewController.followTimeConstant
        let alpha: CGFloat = tau > 0 ? CGFloat(1 - exp(-dt / tau)) : 1
        var o = appliedOrigin
        o.x += (target.x - o.x) * alpha
        o.y += (target.y - o.y) * alpha
        // Settle exactly and sleep once within a sub-pixel of the target (nothing moving).
        if abs(target.x - o.x) < 0.5, abs(target.y - o.y) < 0.5 {
            applyAppliedTransform(scale: zoomScale, origin: target)
            cancelFollow()
        } else {
            applyAppliedTransform(scale: zoomScale, origin: o)
        }
    }

    /// Starts the follow link if it isn't already running. Main thread only.
    private func ensureFollowLinkRunning() {
        guard followLink == nil else { return }
        followLastTickTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepFollow(_:)))
        link.add(to: .main, forMode: .common)
        followLink = link
    }

    /// Stops the smoothed follow link and clears its pan state. Idempotent; main thread only
    /// (it invalidates a CADisplayLink). Called on any override of the follow — gestures, a
    /// scale animation, a snap, reset/restore.
    func cancelFollow() {
        followLink?.invalidate()
        followLink = nil
    }

    /// Engine bridge callback (both engines), reporting the player's window cell
    /// each refresh. Runs auto-follow unless the user is currently looking around.
    ///
    /// Called on the ENGINE thread at the end of `commitDraws`, right after the
    /// changed cells were plotted. We deliberately do NOT hop to the main queue:
    /// re-centering in the same pass as the cell redraw keeps camera and cells in
    /// lockstep. Dispatching to a later runloop left the map a frame behind the
    /// player — a visible stutter when zoomed. This mirrors how `setCell` already
    /// mutates SpriteKit nodes directly from the engine thread in this bridge.
    @objc func setPlayerWindowX(_ x: Int, y: Int, depth: Int) {
        guard isPhoneIdiom else { return }
        let cell = CGPoint(x: x, y: y)
        let moved = (lastPlayerWindowCell != cell)
        lastPlayerWindowCell = cell
        // A run just opened with a remembered zoom: the cell we just recorded may be the
        // last piece the one-shot launch zoom-in was waiting for. Let it own the first
        // zoom-in (don't also auto-follow, which would animate a second time). Hop to
        // main — this runs on the engine thread and the launch zoom drives a CADisplayLink.
        if pendingLaunchZoom {
            DispatchQueue.main.async { [weak self] in self?.runPendingLaunchZoomIfReady() }
            return
        }
        guard gameplayControlsActive, zoomScale > 1.0 else { return }
        // A real move re-establishes follow after a manual look-around.
        if moved { manualPanActive = false }
        if !manualPanActive {
            applyAutoFollow(playerCell: cell, depth: depth)
        }
    }

    /// Suspend-and-restore: engine-drawn overlays (inventory, menus, confirmations)
    /// render into the same dungeon cells, so they'd appear magnified and clipped
    /// off-screen while zoomed. So whenever the game leaves map play
    /// (`gameplayControlsActive` false, and not aiming) we display the map at 1×
    /// — keeping the user's stored zoom intact — and restore it (re-centered on
    /// the player) when normal play resumes. Driven by didSet on the two flags.
    func updateZoomForGameState() {
        guard isPhoneIdiom else { return }
        // Aiming a throw/zap is map interaction — keep the zoom. An examine
        // description box is treated like an overlay — suspend to 1× so it isn't clipped.
        let onMap = (gameplayControlsActive || isTargeting) && !isExamining
        if onMap {
            // Returning to map play — drop any in-game menu magnify FIRST, so its borrowed cells
            // are back in the dungeon container before the gameplay zoom is (re)applied below;
            // otherwise the container would scale while missing them and tear the map. This is the
            // reliable teardown for inventory/menu close (uiMode → InNormalPlay). Idempotent.
            tearDownMenuMagnify()
        }
        guard onMap, zoomScale > 1.0 else {
            // Examining a description box: if it's already fully on-screen at the current
            // zoom (always true at ≤1×), leave the view exactly as-is — no pan, no zoom.
            // Fully / lightly zoomed views get no bells & whistles (iPad/macOS-like). If the
            // box is clipped, fit it (zoom only as far as needed, keeping the text as large
            // as legibly fits); a box that can't fit magnified (too big, or spanning the
            // sidebar) drops to 1× via the fall-through. The stored zoom is left untouched,
            // so ending the examine restores the player-centered zoom.
            if isExamining, let box = examineBox {
                if examineBoxFullyVisible(box) { return }
                if let fit = examineFitZoom() {
                    animateZoom(toScale: fit.scale, toOrigin: fit.origin)
                    return
                }
            }
            // Overlay/menu, or an examine box that must drop to 1×: settle the display to 1×,
            // but only if something is actually magnified — never pan an already-1× view.
            guard appliedScale > 1.0 || zoomScale > 1.0 else { return }
            animateZoom(toScale: 1.0, toOrigin: .zero)
            return
        }
        // A fresh run's first zoom-in is owned by the one-shot launch zoom, which waits
        // for the player's cell so it eases in centered on them — don't also animate here
        // (that double-trigger caused the "snap to 1× then zoom in" jitter).
        if pendingLaunchZoom {
            runPendingLaunchZoomIfReady()
            return
        }
        // Back on the map: animate to the stored zoom, recentered on the player.
        if let cell = lastPlayerWindowCell, !manualPanActive {
            zoomOriginPt = clampedOrigin(autoFollowOrigin(playerCell: cell), scale: zoomScale)
        } else if lastPlayerWindowCell == nil {
            // Run just started with a remembered zoom but no player cell yet: zoom in
            // centered on the dungeon map (never the (0,0) corner) so the game still
            // opens zoomed; the first cell report then recenters on the player.
            zoomOriginPt = mapCenterOrigin(scale: zoomScale)
        } else {
            zoomOriginPt = clampedOrigin(zoomOriginPt, scale: zoomScale)
        }
        animateZoom(toScale: zoomScale, toOrigin: zoomOriginPt)
    }

    /// Resets to 1× (death / return to title), instantly. iPad no-op. The persisted
    /// preference (storedZoomScale) is untouched, so the next run still restores it.
    func resetZoom() {
        guard isPhoneIdiom else { return }
        tearDownMenuMagnify()   // reparent any menu-magnified cells back before resetting
        zoomScale = 1.0
        zoomOriginPt = .zero
        manualPanActive = false
        lastPlayerWindowCell = nil
        pendingLaunchZoom = false
        lastReportedDepth = -1   // re-baseline the follow's level-change detector
        setAppliedZoom(scale: 1.0, origin: .zero)
    }

    /// Origin that centers the dungeon map itself in the frame. Used as the recenter
    /// fallback before the player's cell is known, so a zoom-in never defaults to the
    /// (0,0) corner. The first player-cell report then recenters on the player.
    private func mapCenterOrigin(scale: CGFloat) -> CGPoint {
        let f = dungeonFramePoints()
        return clampedOrigin(CGPoint(x: f.midX * (1 - scale), y: f.midY * (1 - scale)), scale: scale)
    }

    /// Begins a run at the player's remembered zoom (iPhone). Seeds zoomScale from the
    /// stored preference but leaves the *display* at 1×, so the zoom EASES in (rather
    /// than snapping) once the map becomes visible — driven by `updateZoomForGameState`
    /// on the gameplay-controls flip, or by the first `setPlayerWindowX` auto-follow,
    /// both of which `animateZoom` from 1× to the stored scale centered on the player.
    /// NOTE: deliberately does NOT clear `lastPlayerWindowCell` — this runs on the main
    /// queue while the engine is already drawing the new level and reporting the player
    /// cell on its thread; clearing it here would wipe that report and the zoom-in would
    /// land on the map center instead of the player. `resetZoom` (title/death) clears it.
    func restoreStoredZoom() {
        guard isPhoneIdiom else { return }
        tearDownMenuMagnify()   // leaving the title into a run — drop the menu magnify first
        manualPanActive = false
        zoomScale = storedZoomScale
        zoomOriginPt = .zero
        lastReportedDepth = -1   // re-baseline the follow's level-change detector
        setAppliedZoom(scale: 1.0, origin: .zero)
        // Arm the one-shot launch zoom-in; it fires from runPendingLaunchZoomIfReady once
        // we're on the map and the player's cell is known (whichever arrives last).
        pendingLaunchZoom = zoomScale > 1.0
        runPendingLaunchZoomIfReady()

        // First game on iPhone: point out the pinch / two-finger-tap zoom gestures.
        maybeShowZoomHint()
    }

    /// Fires the one-shot launch zoom-in (see `pendingLaunchZoom`). No-op until we're on
    /// the map AND the player's cell is known, so it always eases in from 1× centered on
    /// the player. Runs at most once per `restoreStoredZoom`, regardless of whether the
    /// controls-flip or the first cell report arrives first. Must run on the main thread
    /// (it drives the CADisplayLink animation); the engine-thread caller dispatches.
    private func runPendingLaunchZoomIfReady() {
        guard isPhoneIdiom, pendingLaunchZoom, zoomScale > 1.0,
              gameplayControlsActive || isTargeting, !isExamining,
              let cell = lastPlayerWindowCell else { return }
        pendingLaunchZoom = false
        manualPanActive = false
        zoomOriginPt = clampedOrigin(autoFollowOrigin(playerCell: cell), scale: zoomScale)
        animateZoom(toScale: zoomScale, toOrigin: zoomOriginPt)
    }

    /// Cancels the engine's travel cursor/path by injecting Escape. While the
    /// player is choosing a destination the engine is in its moveCursor loop, and
    /// ESCAPE_KEY (27) there sets `canceled` → `hideCursor()`, erasing the drawn
    /// path. Same keycode and behavior in both engines; harmless if no path is up.
    private func clearTravelCursor() {
        addKeyEvent(event: kESC_Key)
    }

    // MARK: - Bottom button tap-band (iPhone)

    /// True when a touch lands in the reserved band below the grid (iPhone, during
    /// normal play). The band is the fat, easy-to-hit target for the bottom buttons.
    func isBandTouch(_ point: CGPoint) -> Bool {
        guard isPhoneIdiom, gameplayControlsActive else { return false }
        return point.y >= skViewPort.effectiveHeightPoints
    }

    /// Maps a tap in the bottom band to the nearest of the 5 engine buttons and
    /// replays it as a touch at that button's cell (window row 33), so the engine
    /// fires the button exactly as a direct tap would (Menu opens its submenu, etc.).
    func handleBandTap(_ point: CGPoint) {
        let width = skViewPort.effectiveWidthPoints
        let height = skViewPort.effectiveHeightPoints
        let leftInset = skViewPort.leftInsetPoints
        guard width > 0, height > 0 else { return }
        let cw = width / CGFloat(COLS)
        let ch = height / CGFloat(ROWS)
        // Column under the finger; ignore the sidebar side of the band (no button).
        let col = Int(CGFloat(COLS) * max(point.x - leftInset, 0) / width)
        guard col >= 21 else { return }
        // A bottom-bar button (incl. Explore) is an action, not an examine — disarm so
        // any description box that auto-appears afterward doesn't suspend the zoom.
        examineArmDebounce?.cancel()
        examineArmed = false
        let centers = BrogueViewController.bottomButtonCenterColumns
        let target = centers.min(by: { abs($0 - col) < abs($1 - col) }) ?? centers[0]
        // Center of the chosen button cell on the button row (33), in view points.
        let p = CGPoint(x: leftInset + (CGFloat(target) + 0.5) * cw, y: (33.0 + 0.5) * ch)
        // Mirror the regular tap path: MOUSE_DOWN (stationary) then MOUSE_UP (ended).
        addTouchEvent(event: UIBrogueTouchEvent(phase: .stationary, location: p))
        addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: p))
        hapticsController.fireButton()
    }

    /// Writes a transform to the scene and records it as the current applied state.
    /// Does NOT touch the animation link, so it is safe to call from the engine thread
    /// (per-step auto-follow) — callers guarantee no animation is mid-flight when they
    /// use this directly (appliedScale has already reached the target zoom).
    private func applyAppliedTransform(scale: CGFloat, origin: CGPoint) {
        appliedScale = scale
        appliedOrigin = origin
        skViewPort.applyZoom(scale: scale, originXPoints: origin.x, originYPoints: origin.y)
    }

    /// Instantly applies a zoom transform, cancelling any in-flight animation. MAIN
    /// THREAD only (it touches the CADisplayLink). Used by gestures (pinch/pan) and reset.
    private func setAppliedZoom(scale: CGFloat, origin: CGPoint) {
        cancelZoomAnimation()
        cancelFollow()   // an instant apply (gesture / reset / snap) supersedes the smoothed follow
        applyAppliedTransform(scale: scale, origin: origin)
    }

    /// Smoothly animates the *applied* transform from where it is now to a target
    /// (smoothstep over zoomAnimDuration). Canonical zoomScale / zoomOriginPt are NOT
    /// touched here — the caller owns those (so a suspend keeps the user's stored zoom).
    private func animateZoom(toScale targetScale: CGFloat, toOrigin targetOrigin: CGPoint) {
        cancelZoomAnimation()
        cancelFollow()   // a scale transition (suspend/restore/launch/examine/toggle) supersedes the follow
        // Already there → apply instantly, skipping a no-op animation.
        if abs(appliedScale - targetScale) < 0.001,
           abs(appliedOrigin.x - targetOrigin.x) < 0.5,
           abs(appliedOrigin.y - targetOrigin.y) < 0.5 {
            setAppliedZoom(scale: targetScale, origin: targetOrigin)
            return
        }
        zoomAnimStartScale = appliedScale
        zoomAnimStartOrigin = appliedOrigin
        zoomAnimTargetScale = targetScale
        zoomAnimTargetOrigin = targetOrigin
        zoomAnimStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepZoomAnimation(_:)))
        link.add(to: .main, forMode: .common)
        zoomAnimLink = link
    }

    @objc private func stepZoomAnimation(_ link: CADisplayLink) {
        let raw = (CACurrentMediaTime() - zoomAnimStartTime) / zoomAnimDuration
        let t = CGFloat(min(max(raw, 0), 1))
        let e = t * t * (3 - 2 * t) // smoothstep
        let s = zoomAnimStartScale + (zoomAnimTargetScale - zoomAnimStartScale) * e
        let ox = zoomAnimStartOrigin.x + (zoomAnimTargetOrigin.x - zoomAnimStartOrigin.x) * e
        let oy = zoomAnimStartOrigin.y + (zoomAnimTargetOrigin.y - zoomAnimStartOrigin.y) * e
        applyAppliedTransform(scale: s, origin: CGPoint(x: ox, y: oy))
        if t >= 1.0 {
            // Land exactly on target, then stop.
            applyAppliedTransform(scale: zoomAnimTargetScale, origin: zoomAnimTargetOrigin)
            cancelZoomAnimation()
        }
    }

    private func cancelZoomAnimation() {
        zoomAnimLink?.invalidate()
        zoomAnimLink = nil
    }
}
