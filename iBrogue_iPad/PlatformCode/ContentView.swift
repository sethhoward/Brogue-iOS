//
//  ContentView.swift
//  Brogue
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHY THIS FILE EXISTS — read this before "modernizing" the architecture.
//  ─────────────────────────────────────────────────────────────────────────
//
//  Brogue's game UI is UIKit + SpriteKit (BrogueViewController hosts an
//  SKView/SKScene with 6,800 cell nodes, plus a magnifier, direction controls,
//  buttons, an off-screen text field, and a background thread running the C
//  game loop). That part is staying — SpriteKit gives us the performance we
//  need for the cell-grid + magnifier, and SKCameraNode is the easy path
//  forward for the iPhone pan/zoom we expect to add.
//
//  However, iPadOS 18 only honors the home-indicator gesture deferral
//  (`preferredScreenEdgesDeferringSystemGestures`) and auto-hide
//  (`prefersHomeIndicatorAutoHidden`) when the *root* view controller's
//  values are clean. We tried every variation of overriding those properties
//  on BrogueViewController directly — iOS *queried* the overrides and
//  returned the values, but refused to actually apply gesture deferral.
//
//  The fix that finally worked: make the window's rootViewController a
//  `UIHostingController<ContentView>`. SwiftUI applies the modifiers
//  `.statusBarHidden(true)` and `.defersSystemGestures(on: .bottom)` to the
//  hosting controller, which iPadOS honors cleanly. BrogueViewController
//  becomes a child of the hosting controller via `UIViewControllerRepresentable`.
//
//  Important constraint we discovered the hard way:
//    DO NOT add `.persistentSystemOverlays(.hidden)` here. It conflicts with
//    `.defersSystemGestures` and silently disables the deferral mechanism.
//    With deferral alone the indicator auto-hides anyway after a few seconds
//    of no touches, which is the behavior we want.
//
//  Important constraint #2:
//    BrogueViewController must NOT override any of the system-UI properties
//    (`prefersHomeIndicatorAutoHidden`, `preferredScreenEdgesDeferringSystemGestures`,
//    `childForHomeIndicatorAutoHidden`, `childForScreenEdgesDeferringSystemGestures`,
//    `prefersStatusBarHidden`). When it does, UIHostingController consults the
//    child and the child's overrides clash with the SwiftUI-driven values on
//    the hosting controller. Result: deferral stops working. See the comment
//    block on BrogueViewController explaining why those overrides are absent.
//
//  Bisection process that landed us here (Phase 1–6) is documented in the
//  commit history if you ever need to revisit assumptions.
//

import SwiftUI
import UIKit
import SpriteKit

struct ContentView: View {
    var body: some View {
        // The SwiftUI modifiers applied here are the SOLE source of truth for
        // system-UI behavior. They get mapped onto the UIHostingController
        // that wraps this view, which is the window's rootViewController
        // (see SceneDelegate). iPadOS honors them at that level.
        //
        //   .ignoresSafeArea()           — let the game render edge-to-edge.
        //   .statusBarHidden(true)       — no status bar overlay.
        //   .defersSystemGestures(.bottom) — first bottom-edge swipe is absorbed,
        //                                   second swipe goes home. iOS also
        //                                   auto-hides the indicator after a
        //                                   couple seconds of no touches as a
        //                                   side-effect of deferral being on.
        //
        // Do NOT add `.persistentSystemOverlays(.hidden)` — it cancels the
        // deferral above.
        BrogueViewControllerRepresentable()
            .ignoresSafeArea()
            .statusBarHidden(true)
            .defersSystemGestures(on: .bottom)
    }
}

/// Bridges the storyboard-defined BrogueViewController into the SwiftUI tree.
/// BrogueViewController is still the "real" view controller — IBOutlets,
/// IBActions, the SKView, the background Brogue thread all live there. This
/// wrapper exists purely so the rootViewController can be a UIHostingController.
private struct BrogueViewControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BrogueViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        guard let vc = storyboard.instantiateInitialViewController() as? BrogueViewController else {
            fatalError("Main.storyboard's initial view controller must be BrogueViewController")
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: BrogueViewController, context: Context) {
        // No SwiftUI-driven state flows down to the UIKit VC at the moment.
        // If you later want to push values (e.g. game-state booleans) down
        // from SwiftUI, do it here.
    }
}
