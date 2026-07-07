//
//  BrogueViewController+Layout.swift
//  Brogue
//
//  Layout: notch / Dynamic-Island safe-area insets, the seed-button repositioning, and the
//  d-pad transform (base translation + persisted drag + transient notch avoidance) plus its
//  offset persistence. Extracted verbatim from BrogueViewController.swift as part of splitting
//  that file by function. The lifecycle overrides that call these stay in BrogueViewController.swift.
//

import UIKit

extension BrogueViewController {

    static func loadDpadOffset() -> CGPoint {
        guard let stored = UserDefaults.standard.array(forKey: dpadOffsetDefaultsKey) as? [Double],
              stored.count == 2 else { return .zero }
        return CGPoint(x: stored[0], y: stored[1])
    }

    func saveDpadOffset() {
        UserDefaults.standard.set([Double(dpadUserOffset.x), Double(dpadUserOffset.y)],
                                  forKey: BrogueViewController.dpadOffsetDefaultsKey)
    }

    /// Position the pad at its base translation plus the persisted user drag plus
    /// the transient notch-avoidance correction.
    func applyDpadTransform() {
        dContainerView.transform = CGAffineTransform(
            translationX: dpadBaseTranslation.x + dpadUserOffset.x + dpadNotchAvoidance,
            y: dpadBaseTranslation.y + dpadUserOffset.y)
    }

    /// Moves the seed button from its storyboard spot (bottom-left) to just left
    /// of the "New Game" menu item, outside the menu's black border. The Classic
    /// menu is engine-drawn at fixed grid cells and the title grid fills the
    /// screen, so we anchor with fractional (multiplier) constraints that track
    /// rotation. New Game renders at roughly grid (x≈77, y≈21) of the 100×34 grid.
    func repositionSeedButton() {
        guard let seedButton = seedButton, let host = seedButton.superview else { return }
        // Drop the storyboard position constraints (leading vs leaderboard,
        // bottom vs layout guide); the 80×80 size constraints live on the button
        // itself and are preserved.
        let positional = host.constraints.filter { $0.firstItem === seedButton || $0.secondItem === seedButton }
        NSLayoutConstraint.deactivate(positional)
        NSLayoutConstraint.activate([
            // Right edge just left of the menu's left border (~grid x 77).
            NSLayoutConstraint(item: seedButton, attribute: .trailing, relatedBy: .equal,
                               toItem: view!, attribute: .trailing, multiplier: 75.0 / 100.0, constant: 0),
            // Vertically centered on the New Game row (~grid y 21.5 of 34).
            NSLayoutConstraint(item: seedButton, attribute: .centerY, relatedBy: .equal,
                               toItem: view!, attribute: .bottom, multiplier: 21.5 / 34.0, constant: 0),
        ])
    }

    /// iOS port (iBrogue): Mac Catalyst only — stop the window from being resized so small the
    /// dungeon grid becomes illegible / the layout collapses. No-op on iOS/iPadOS (a touch device's
    /// window isn't user-resizable, and `windowScene.sizeRestrictions` is nil there). Idempotent —
    /// safe to re-run on every appearance. Default/last window size is left to scene state restoration.
    func applyMacWindowSizeRestrictionsIfNeeded() {
        #if targetEnvironment(macCatalyst)
        guard let restrictions = view.window?.windowScene?.sizeRestrictions else { return }
        restrictions.minimumSize = CGSize(width: 1024, height: 640)
        #endif
    }

    /// Best-available safe-area insets. SwiftUI's `.ignoresSafeArea()` zeroes
    /// the hosted view's insets, so we prefer the window's. If our own window
    /// isn't attached yet, fall back to any foreground window scene's key
    /// window so we never read a falsely-zeroed inset during early layout.
    var bestSafeAreaInsets: UIEdgeInsets {
        if let window = view.window { return window.safeAreaInsets }
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
        return keyWindow?.safeAreaInsets ?? view.safeAreaInsets
    }

    /// Classifies the current device's front cutout. `.dynamicIsland` is
    /// model-driven (the only reliable signal); `.notch` vs `.none` is decided
    /// by whether a real safe-area inset exists. We're landscape-locked, so a
    /// cutout shows up as a left/right inset rather than a top one. `.none`
    /// covers the home-button iPhone SE models and every iPad (no iPad has a
    /// cutout).
    func currentDisplayCutout(insets: UIEdgeInsets) -> DisplayCutout {
        if UIDevice.current.hasDynamicIsland { return .dynamicIsland }
        let sideInset = max(insets.left, insets.right)
        return sideInset > 20 ? .notch : .none
    }

    /// Which screen edge the front cutout (notch / dynamic island) sits on in the
    /// current landscape. In `landscapeLeft` the device's camera end points RIGHT;
    /// in `landscapeRight` it points LEFT. iOS reports near-symmetric horizontal
    /// safe-area insets in landscape, so the interface orientation — not inset
    /// asymmetry — is the reliable signal. Defaults to right (the app's original
    /// single-orientation assumption) before a window scene is attached.
    var notchOnRight: Bool {
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeLeft
        return orientation != .landscapeRight
    }

    func applyNotchInsets() {
        let insets = bestSafeAreaInsets
        let scale = UIScreen.main.scale

        // Position the safe-area action buttons in the (now-known) cutout strip
        // and show/hide them for this device + game state.
        layoutActionButtons(insets: insets)
        updateActionButtonVisibility()

        // Reserve space on whichever side the notch / dynamic island currently
        // sits (landscapeLeft → right edge, landscapeRight → left edge). iOS
        // reports near-symmetric horizontal insets in landscape, so we reserve
        // only the actual-notch side and slide the whole grid AWAY from it by
        // `gridRightShift`: the non-notch edge is inset by that amount, and the
        // notch-side reservation is reduced by the same amount, so the grid keeps
        // its width and pushes that far into the notch-side safe area.
        let shift = SKViewPort.gridRightShift
        let onRight = notchOnRight
        let notchInset = onRight ? insets.right : insets.left
        let nearPixels = shift * scale                          // non-notch edge
        let notchPixels = max(notchInset - shift, 0) * scale    // notch edge
        skViewPort.rogueScene.setHorizontalEdgeInsets(
            leftPixels: onRight ? nearPixels : notchPixels,
            rightPixels: onRight ? notchPixels : nearPixels
        )
    }

    /// Recomputes the transient notch-avoidance shift for the current landscape:
    /// if the d-pad's saved/default position would overlap the notch-side safe
    /// area, push it just clear; otherwise zero. Display-only — never persisted —
    /// so the user's placement is intact and simply returns to where they left it
    /// in the orientation whose cutout it doesn't touch. Called on launch and on
    /// rotation, never during normal play (a deliberate under-cutout park stays).
    func updateDpadNotchAvoidance() {
        guard isPhoneIdiom else { return }
        // Measure the pad at its true (un-corrected) position first.
        dpadNotchAvoidance = 0
        applyDpadTransform()

        let insets = bestSafeAreaInsets
        let bounds = view.bounds
        let frame = dContainerView.frame
        let margin = BrogueViewController.dpadNotchClearanceMargin
        var dx: CGFloat = 0
        if notchOnRight {
            let limit = bounds.maxX - insets.right - margin
            if frame.maxX > limit { dx = limit - frame.maxX }   // shift left
        } else {
            let limit = bounds.minX + insets.left + margin
            if frame.minX < limit { dx = limit - frame.minX }   // shift right
        }
        guard dx != 0 else { return }
        dpadNotchAvoidance = dx
        applyDpadTransform()
    }
}
