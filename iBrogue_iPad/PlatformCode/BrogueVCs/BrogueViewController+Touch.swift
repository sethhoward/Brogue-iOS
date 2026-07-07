//
//  BrogueViewController+Touch.swift
//  Brogue
//
//  Raw touch handling: multi-touch tracking, gesture-origin zone classification
//  (play area / sidebar / bottom band), and the touch-event queue the engine drains.
//  Extracted verbatim from BrogueViewController.swift as part of splitting that file
//  by function.
//

import UIKit
import SpriteKit

// COLS/ROWS shadow the C engine's Rogue.h macros with Int-typed, file-local constants
// (see BrogueViewController.swift). fileprivate to avoid clashing with the imported
// C COLS/ROWS (Int32).
fileprivate let COLS = 100
fileprivate let ROWS = 34

extension BrogueViewController {
    override func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        addKeyEvent(event: kESC_Key)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        // A fresh single-finger touch means any prior pinch/pan is over. Clear the
        // latch here: the gesture recognizer cancels its touches while fingers are
        // still down, so the lift produces no touchesEnded to reset it — leaving it
        // stuck, which made the first post-gesture touch flash the magnifier and
        // then hide it.
        if (event?.allTouches?.count ?? touches.count) <= 1 {
            multiTouchGestureActive = false
            // Latch where this gesture began so the whole gesture routes by its origin
            // zone (see `gestureOriginZone`). Captured here, before the pinch/band
            // early-returns, and only for the primary finger so a pinch can't clobber it.
            gestureOriginZone = originZone(for: touches.first!.location(in: view))
            // Map-under-sidebar: latch reach for any gesture that STARTS on the dungeon
            // while the reveal is on screen, so a drag left into the translucent sidebar
            // reaches the map behind it — even a fast drag that beats the 0.3s magnifier
            // delay (otherwise the boundary-cross is dropped in touchesMoved, killing the
            // loupe timer and freezing the selection at the sidebar edge). Non-dungeon
            // origins latch false, keeping raw-coordinate routing (sidebar entity taps).
            // Harmless for gestures that never leave the map (reach ≡ no-reach in cols
            // 21…99). Gated on appliedScale (on-screen zoom), not the canonical zoomScale,
            // which stays high behind a 1× menu.
            sidebarReachLatched = gestureOriginZone == .playArea
                && pinchZoomActive && mapUnderSidebarEnabled && appliedScale > 1.0
            // Fresh gesture: drop any prior sidebar-tap examine provenance. A sidebar
            // single-tap re-sets it in touchesEnded; anything else (incl. tapping the
            // Explore button, which kicks off auto-explore) leaves it false so that box is
            // suppressed while zoomed.
            examineFromSidebar = false
        }

        // iPhone (zoom on): a second finger means a pinch / two-finger pan is
        // starting. Flush the tap the first finger queued (so it can't commit a
        // map-move that auto-follow then snaps to), kill any pending magnifier,
        // and stop feeding the engine until all fingers lift.
        if pinchZoomActive, (event?.allTouches?.count ?? touches.count) >= 2 {
            multiTouchGestureActive = true
            clearTouchEvents()
            hideMagnifier()
            return
        }
        // Bottom tap-band: handled on release; swallow the down (before the dpad
        // guard, so the dpad container can't eat band taps) so it never becomes a
        // map-move or pops the magnifier. Keyed on the latched origin zone so a swipe
        // that starts in the band stays swallowed even after it crosses into the grid.
        if gestureOriginZone == .band {
            hideMagnifier()
            return
        }

        guard dContainerView.hitTest(touches.first!.location(in: dContainerView), with: event) == nil else { return }

        for touch in touches {
            let location = touch.location(in: view)
            // handle double tap on began.
            if touch.tapCount >= 2 && pointIsInPlayArea(point: location) {
                // double tap in the play area
                addTouchEvent(event: UIBrogueTouchEvent(phase: .stationary, location: lastTouchLocation))
                addTouchEvent(event: UIBrogueTouchEvent(phase: .moved, location: lastTouchLocation))
                addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
            }
            else {
                let brogueEvent = UIBrogueTouchEvent(phase: touch.phase, location: location)
                addTouchEvent(event: brogueEvent)
                showMagnifier(at: location)
            }
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        if multiTouchGestureActive || (pinchZoomActive && (event?.allTouches?.count ?? touches.count) >= 2) {
            multiTouchGestureActive = true
            clearTouchEvents()
            hideMagnifier()
            return
        }
        // Band-origin gesture: swallow for its whole life (it can only ever fire a
        // button, on release, and only if it lifts back in the band).
        if gestureOriginZone == .band {
            hideMagnifier()
            return
        }
        // Off-grid feed clamp (active play only): a play-area / other-origin drag must
        // not feed an off-grid coordinate (the finger wandered into the band or
        // sidebar) — drop it so lastTouchLocation (the commit cell) stays at the last
        // in-grid cell. A sidebar-origin gesture is exempt: its in-sidebar moves are
        // examine hovers. Gated on gameplayControlsActive so it never touches menu /
        // inventory interaction, where item rows sit above the play area (rows <= 3)
        // and must stay selectable by tap or drag.
        let moveLoc = touches.first!.location(in: view)
        if gameplayControlsActive, gestureOriginZone != .sidebar,
           !pointIsInPlayArea(point: moveLoc),
           !(sidebarReachLatched && pointIsInReachRegion(point: moveLoc)) {
            hideMagnifier()
            return
        }

        // A sidebar scrub has begun to move (a plain tap never reaches touchesMoved):
        // fade the d-pad out so its lower-left overlap stops hiding and blocking the
        // bottom sidebar entities. Disables the pad's touches immediately, so the
        // hit-test guard below passes on this same event and the scrub reaches the cells
        // behind it. Restored on release (touchesEnded / touchesCancelled).
        if gameplayControlsActive, gestureOriginZone == .sidebar {
            setDpadFadedForSidebarScrub(true)
        }

        guard dContainerView.hitTest(touches.first!.location(in: dContainerView), with: event) == nil else { return }

        if let touch = touches.first {
            let location = touch.location(in: view)
            let brogueEvent = UIBrogueTouchEvent(phase: touch.phase, location: location)

            addTouchEvent(event: brogueEvent)
            showMagnifier(at: location)
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)

        // Release the latched origin zone once every finger has lifted, on every path.
        // Fade the d-pad back in too (no-op unless a sidebar scrub faded it out).
        let allFingersUp = activeTouchCount(event) == 0
        defer { if allFingersUp { gestureOriginZone = nil; setDpadFadedForSidebarScrub(false) } }

        // A multi-touch gesture (pinch / two-finger pan) was in progress: never
        // commit a tap on release — that's what produced the view "snap." Reset
        // once every finger has lifted.
        if multiTouchGestureActive {
            clearTouchEvents()
            hideMagnifier()
            if allFingersUp { multiTouchGestureActive = false }
            return
        }

        // Band-origin gesture: fire the nearest bottom button ONLY if it also lifts in
        // the band. A band-origin swipe that lifts in the grid/sidebar (the home-
        // indicator swipe-up) commits nothing — it never leaks a play-field move.
        if gestureOriginZone == .band {
            if let loc = touches.first?.location(in: view), isBandTouch(loc) {
                handleBandTap(loc)
            }
            hideMagnifier()
            return
        }

        guard dContainerView.hitTest(touches.first!.location(in: dContainerView), with: event) == nil else { return }

        if let touch = touches.first {
            let location = touch.location(in: view)

            // The sidebar-examine (hover-only) routing is meaningful ONLY during
            // active play (the mainInputLoop cursor description box). While a menu
            // or button box is up (gameplayControlsActive == false — buttonInputLoop
            // forces uiMode = InMenu), the engine draws its action-menu buttons
            // (apply/equip/drop/throw…) starting as far left as window column 2, so
            // for long descriptions the leftmost buttons (throw, due to the
            // right-to-left layout) land in the sidebar columns (x <= 20). Routing
            // those through the examine branch sends only a MOUSE_ENTERED_CELL hover
            // and never the MOUSE_UP that activates a button — so the first tap did
            // nothing and the player had to tap again. Treat sidebar-column taps as
            // ordinary clicks whenever we're not in active play.
            if gestureOriginZone == .sidebar && gameplayControlsActive && !pointIsInSideBar(point: location) {
                // Sidebar-origin gesture that lifted outside the sidebar (dragged into
                // the grid / band): commit nothing — just disarm the pending examine.
                examineArmDebounce?.cancel()
                examineArmed = false
            } else if gestureOriginZone == .sidebar && gameplayControlsActive {
                // side bar
                if touch.tapCount >= 2 {
                    // Double-tap acts on the entity (attack / run toward) — not an examine.
                    // Cancel the pending single-tap arm so it never zooms out.
                    examineArmDebounce?.cancel()
                    examineArmed = false
                    addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
                } else {
                    // Single-tap selects an entity → the engine shows its description box.
                    // Mark it a sidebar-tap examine immediately (before the deferred arm) so
                    // the box isn't suppressed when the engine draws it a frame later — this
                    // is the deliberate "show it" case (auto-explore / play-field boxes stay
                    // suppressed while zoomed). Set regardless of examineZoomEnabled: a
                    // sidebar tap always shows the box; the zoom-out is the separate arm.
                    examineFromSidebar = true
                    // Defer arming past the double-tap window so a follow-up double-tap
                    // cancels it; only a lone single tap actually suspends the zoom.
                    examineArmDebounce?.cancel()
                    if examineZoomEnabled {
                        let work = DispatchWorkItem { [weak self] in
                            guard let self = self, self.examineBoxShown else { return }
                            self.examineArmed = true
                        }
                        examineArmDebounce = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + examineArmDelay, execute: work)
                    }
                    addTouchEvent(event: UIBrogueTouchEvent(phase: .moved, location: location))
                }
            } else {
                // other touch
                examineArmDebounce?.cancel()
                examineArmed = false
                addTouchEvent(event: UIBrogueTouchEvent(phase: .stationary, location: lastTouchLocation))
                addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
            }
        }
        
        hideMagnifier()
    }

    // When a gesture recognizer (pinch / pan) claims the touches, UIKit cancels
    // them here instead of calling touchesEnded. Flush anything queued so a leaked
    // first-finger touch can't linger, and clear the multi-touch latch on lift.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        clearTouchEvents()
        hideMagnifier()
        if activeTouchCount(event) == 0 {
            multiTouchGestureActive = false
            gestureOriginZone = nil
            setDpadFadedForSidebarScrub(false)   // fade the d-pad back if a scrub faded it out
        }
    }

    /// Touches still down (not ended/cancelled) in this event.
    private func activeTouchCount(_ event: UIEvent?) -> Int {
        (event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count) ?? 0
    }

    func pointIsInPlayArea(point: CGPoint) -> Bool {
        let cellCoord = getCellCoords(at: point, viewport: skViewPort)
        if cellCoord.x > 20 && cellCoord.y < 32 && cellCoord.y > 3 {
            return true
        }

        return false
    }

    private func pointIsInSideBar(point: CGPoint) -> Bool {
        let cellCoord = getCellCoords(at: point, viewport: skViewPort)
        if cellCoord.x <= 20 {
            return true
        }

        return false
    }

    /// The region a latched held-magnifier reach may inspect once the map is revealed behind
    /// the interface: the full HUD frame — cols 0…99, rows 0…32 (ROWS-2) — which covers the
    /// sidebar, the message log (top), and the flavor line (bottom). The button row (33) is
    /// excluded so a reach drag can't stray onto it. Raw (non-reach) cell coords: we're
    /// classifying where the finger physically is, not where it resolves to.
    func pointIsInReachRegion(point: CGPoint) -> Bool {
        let cellCoord = getCellCoords(at: point, viewport: skViewPort)
        return cellCoord.x >= 0 && cellCoord.x <= 99 && cellCoord.y >= 0 && cellCoord.y <= 32
    }

    /// iOS port (iBrogue): classify a touch-down location into the zone that owns the
    /// gesture. `isBandTouch` is checked first because it already carries the
    /// `gameplayControlsActive` guard — so `.band` is only ever latched during active
    /// play; outside play the bottom area falls through to `.playArea`/`.other` and
    /// keeps its existing routing.
    private func originZone(for point: CGPoint) -> GestureOriginZone {
        if isBandTouch(point) { return .band }
        if pointIsInSideBar(point: point) { return .sidebar }
        if pointIsInPlayArea(point: point) { return .playArea }
        return .other
    }
    
    func addTouchEvent(event: UIBrogueTouchEvent) {
        lastTouchLocation = event.location
        // Stamp the reach decision onto the event so the bridge resolves it in map space
        // at dequeue time (engine thread) even after the latch is cleared on lift. Only
        // ever true during a genuine reach drag; the sidebar-examine and double-tap paths
        // enqueue with the latch false, so their coordinates stay untouched.
        event.reachUnderSidebar = sidebarReachLatched
        synchronized {
            // only want the last moved event, no point caching them all
            if let lastEvent = touchEvents.last, lastEvent.phase == .moved, !touchEvents.isEmpty {
                _ = touchEvents.removeLast()
            }

            touchEvents.append(event)
        }
    }

    /// iOS port (iBrogue): enqueue a hover-derived examine event. Identical to addTouchEvent's
    /// dedup+append, but deliberately does NOT write `lastTouchLocation` — that field is the
    /// commit coordinate for a tap's synthesized MOUSE_UP, and hover must never influence where a
    /// click commits (desktop keeps hover and click fully independent). Keeping the write out makes
    /// that independence hold by construction rather than relying on touchesBegan event ordering.
    func addHoverEvent(event: UIBrogueTouchEvent) {
        synchronized {
            if let lastEvent = touchEvents.last, lastEvent.phase == .moved, !touchEvents.isEmpty {
                _ = touchEvents.removeLast()
            }
            touchEvents.append(event)
        }
    }

    func clearTouchEvents() {
        synchronized {
            touchEvents.removeAll()
        }
    }

    @objc func dequeTouchEvent() -> UIBrogueTouchEvent? {
        synchronized {
            guard !touchEvents.isEmpty else { return nil }
            let event = touchEvents.removeFirst()
            return event.copy() as? UIBrogueTouchEvent
        }
    }

    @objc func hasTouchEvent() -> Bool {
        synchronized { !handoffInFlight && !touchEvents.isEmpty }
    }
}
