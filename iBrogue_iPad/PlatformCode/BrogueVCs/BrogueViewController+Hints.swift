//
//  BrogueViewController+Hints.swift
//  Brogue
//
//  First-run popover hints (long-press button rebinding, pinch-to-zoom) and the
//  popover presentation-controller delegate. Extracted verbatim from
//  BrogueViewController.swift as part of splitting that file by function.
//

import UIKit

// MARK: - First-run keybind hint

extension BrogueViewController: UIPopoverPresentationControllerDelegate {
    /// Shows a one-time popover off the top side button explaining long-press
    /// rebinding, the first time the buttons appear during gameplay. No-op once
    /// shown, on non-cutout devices (buttons hidden), or if we can't present.
    func maybeShowKeybindHint() {
        guard !UserDefaults.standard.bool(forKey: Self.keybindHintShownKey),
              !keybindHintInFlight,
              view.window != nil,
              presentedViewController == nil,
              let anchor = actionButtons.first, !anchor.isHidden else {
            return
        }
        keybindHintInFlight = true
        // Brief delay so it appears after the game screen settles, not instantly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            guard self.view.window != nil,
                  self.presentedViewController == nil,
                  let anchor = self.actionButtons.first, !anchor.isHidden else {
                self.keybindHintInFlight = false   // retry the next time the buttons show
                return
            }
            UserDefaults.standard.set(true, forKey: Self.keybindHintShownKey)
            self.presentKeybindHint(from: anchor)
        }
    }

    private func presentKeybindHint(from anchor: UIView) {
        let hint = UIViewController()
        hint.modalPresentationStyle = .popover

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Tip: long-press a button to change which command it triggers."
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        hint.view.addSubview(label)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: hint.view.topAnchor, constant: pad),
            label.bottomAnchor.constraint(equalTo: hint.view.bottomAnchor, constant: -pad),
            label.leadingAnchor.constraint(equalTo: hint.view.leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: hint.view.trailingAnchor, constant: -pad),
        ])

        let width: CGFloat = 230
        let textHeight = label.sizeThatFits(CGSize(width: width - pad * 2,
                                                   height: .greatestFiniteMagnitude)).height
        hint.preferredContentSize = CGSize(width: width, height: ceil(textHeight) + pad * 2)

        if let pop = hint.popoverPresentationController {
            pop.delegate = self
            pop.sourceView = anchor
            pop.sourceRect = anchor.bounds
            // Buttons hug the trailing edge, so the popover sits to their left
            // with the arrow pointing right at the button.
            pop.permittedArrowDirections = .right
        }
        present(hint, animated: true)
        keybindHintInFlight = false
    }

    /// Shows a one-time popover over the dungeon explaining the zoom gestures, the
    /// first time a game starts with pinch-zoom available. No-op once shown, when
    /// the feature is off or unavailable (non-iPhone), or if we can't present.
    func maybeShowZoomHint() {
        guard !UserDefaults.standard.bool(forKey: Self.zoomHintShownKey),
              !zoomHintInFlight,
              pinchZoomActive,
              view.window != nil,
              presentedViewController == nil else {
            return
        }
        zoomHintInFlight = true
        // Brief delay so it appears after the game screen settles, not instantly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            guard self.pinchZoomActive,
                  self.view.window != nil,
                  self.presentedViewController == nil else {
                self.zoomHintInFlight = false   // retry the next time a game starts
                return
            }
            UserDefaults.standard.set(true, forKey: Self.zoomHintShownKey)
            self.presentZoomHint()
        }
    }

    private func presentZoomHint() {
        let hint = UIViewController()
        hint.modalPresentationStyle = .popover

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        var tip = "Tip: pinch to zoom the map. Two-finger double-tap to zoom all the way out, and again to zoom back in."
        if mapUnderSidebarEnabled {
            tip += " While zoomed, hold to inspect, then drag under the interface (sidebar, log, flavor line) to reach the map behind it."
        }
        label.text = tip
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        hint.view.addSubview(label)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: hint.view.topAnchor, constant: pad),
            label.bottomAnchor.constraint(equalTo: hint.view.bottomAnchor, constant: -pad),
            label.leadingAnchor.constraint(equalTo: hint.view.leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: hint.view.trailingAnchor, constant: -pad),
        ])

        let width: CGFloat = 260
        let textHeight = label.sizeThatFits(CGSize(width: width - pad * 2,
                                                   height: .greatestFiniteMagnitude)).height
        hint.preferredContentSize = CGSize(width: width, height: ceil(textHeight) + pad * 2)

        if let pop = hint.popoverPresentationController {
            pop.delegate = self
            // Anchor over the dungeon view, arrow pointing down so the bubble sits
            // above the center rather than over the directional pad at the bottom.
            pop.sourceView = skViewPort
            pop.sourceRect = CGRect(x: skViewPort.bounds.midX, y: skViewPort.bounds.midY,
                                    width: 1, height: 1)
            pop.permittedArrowDirections = .down
        }
        present(hint, animated: true)
        zoomHintInFlight = false
    }

    // Keep it a popover on iPhone rather than auto-adapting to a full-screen sheet.
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }

    /// Only one first-run hint can occupy the popover slot at a time, so they're
    /// chained: when one is dismissed, offer the next still-pending one. Each is
    /// gated on its own "shown" flag, so the one already seen no-ops and only the
    /// remaining hint presents — letting a fresh install see both in one game.
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        maybeShowKeybindHint()
        maybeShowZoomHint()
    }
}
