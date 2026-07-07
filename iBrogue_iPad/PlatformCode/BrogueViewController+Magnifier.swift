//
//  BrogueViewController+Magnifier.swift
//  Brogue
//
//  VC-side control of the magnifier loupe (SKMagView): when it may appear, showing and
//  hiding it, and the d-pad fade / hide coordination while it is active. Extracted
//  verbatim from BrogueViewController.swift as part of splitting that file by function.
//

import UIKit
import SpriteKit

extension BrogueViewController {
    @objc private func handleMagnifierTimer() {
        if canShowMagnifier(at: lastTouchLocation) {
            magView.showMagnifier(at: lastTouchLocation)
            // Magnifier is now up: stop any in-progress d-pad press (kills its
            // repeat timer so a held button can't keep moving) and hide the pad.
            // (Sidebar reach is latched earlier, at gesture start in touchesBegan, so a
            // fast drag across the boundary isn't dropped before the loupe arms.)
            directionsViewController?.cancel()
            setDpadHiddenForMagnifier(true)
        }
    }
    
    private func canShowMagnifier(at point: CGPoint) -> Bool {
        // Classic gates on its fine-grained game-event states. CE drives only a
        // coarse uiMode and never sets `lastBrogueGameEvent`, so use the shared
        // `gameplayControlsActive` flag (true exactly when CE reports normal
        // play, set in applyCEUIMode) to allow the magnifier there.
        // CE drives only a coarse uiMode and never sets `lastBrogueGameEvent`, so
        // allow the magnifier during normal play (gameplayControlsActive) and also
        // while aiming a throw/zap (isTargeting), where it helps the player see the
        // target cell under their finger.
        // Never while pinching / two-finger panning the map — the magnifier would
        // fight the gesture and lag behind the moving cells.
        guard !zoomGestureInProgress else { return false }
        // Never while a hardware keyboard is attached — the player is driving by
        // keyboard, not touch, so the touch loupe is just noise.
        guard !hardwareKeyboardConnected else { return false }
        let engineAllowsMagnifier = currentEngine.isCEFamily
            ? (gameplayControlsActive || isTargeting)
            : lastBrogueGameEvent.canShowMagnifyingGlass
        // Normally the loupe only appears over the map (cols 21…99, dungeon rows). While a
        // reach drag is latched, also allow it anywhere in the reveal frame (over the
        // sidebar, message log, and flavor line), so it keeps tracking as the finger crosses
        // under the translucent interface.
        let reachAllowed = sidebarReachLatched && pointIsInReachRegion(point: point)
        guard engineAllowsMagnifier, pointIsInPlayArea(point: point) || reachAllowed else {
            return false
        }
        // iPhone: suppress the magnifier over the chrome rows — the flavor line
        // (row 32) and the button bar (row 33) — so it doesn't pop up when the
        // player is aiming for a button. Row 31 is pure dungeon (the bottom map
        // row), so the magnifier is allowed there. Not suppressed while targeting
        // (buttons hidden), nor during a reach drag — there the reveal exposes the
        // map behind the flavor line (row 32), and pointIsInReachRegion already
        // excludes the button row (33).
        if UIDevice.current.userInterfaceIdiom == .phone, !isTargeting, !sidebarReachLatched {
            let cell = getCellCoords(at: point, viewport: skViewPort)
            if cell.y >= 32 {
                return false
            }
        }
        return true
    }
    
    func showMagnifier(at point: CGPoint) {
        guard canShowMagnifier(at: point) else {
            magView.hideMagnifier()
            return
        }
        
        if magView.isHidden {
            magnifierTimer?.invalidate()
            magnifierTimer = nil
            magnifierTimer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(BrogueViewController.handleMagnifierTimer), userInfo: nil, repeats: false)
            // Need to go iOS 10
            //            magnifierTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            //                self.magView.showMagnifier(at: self.lastTouchLocation)
            //            }
        } else {
            magView.updateMagnifier(at: point)
        }
    }
    
    func hideMagnifier() {
        magnifierTimer?.invalidate()
        magnifierTimer = nil
        setDpadHiddenForMagnifier(false)
        DispatchQueue.main.async {
            self.magView.hideMagnifier()
        }
    }

    /// Hides the directional pad while the magnifier is up, and restores it when the
    /// magnifier goes away. Restoration defers to refreshDirectionPadVisibility() — the
    /// single source of truth — so it honors BOTH gameplay state AND hardware-keyboard
    /// presence. (Restoring via `!gameplayControlsActive` alone re-showed the d-pad
    /// after a magnifier dismissal even with a keyboard attached — e.g. on every mouse
    /// click, which drives the touch/magnifier path.)
    private func setDpadHiddenForMagnifier(_ hidden: Bool) {
        if hidden {
            dContainerView.isHidden = true
        } else {
            refreshDirectionPadVisibility()
        }
    }

    /// Fades the directional pad out for the duration of a sidebar scrub, then fades it
    /// back on release. The pad's lower-left corner overlaps the bottom sidebar entities;
    /// while scrubbing the entity list that overlap both hides them (it's semi-opaque) and
    /// eats their touches (the touchesMoved hit-test guard bails over the pad), so the
    /// lowest entities can't be browsed or selected. Distinct from the magnifier's instant
    /// hide (setDpadHiddenForMagnifier): a scrub is a continuous gesture, so this animates
    /// to match the loupe's polish. Interaction is disabled *immediately* (not after the
    /// fade) so the hit-test guard passes on the very same event and the scrub reaches the
    /// cells behind the pad. Restoring hands final visibility back to
    /// refreshDirectionPadVisibility() (the source of truth for gameplay-state / hardware-
    /// keyboard presence); this only manages the transient alpha. The guard makes the
    /// fade fire once per scrub and the restore a no-op when nothing was faded.
    func setDpadFadedForSidebarScrub(_ faded: Bool) {
        guard faded != dpadFadedForSidebarScrub else { return }
        dpadFadedForSidebarScrub = faded
        if faded {
            dContainerView.isUserInteractionEnabled = false   // pass scrub touches through NOW
            UIView.animate(withDuration: 0.2) { self.dContainerView.alpha = 0 }
        } else {
            UIView.animate(withDuration: 0.2) {
                self.dContainerView.alpha = BrogueViewController.dpadRestingAlpha
            }
            refreshDirectionPadVisibility()                   // restore isHidden / interaction per state
        }
    }
}
