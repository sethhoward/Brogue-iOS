//
//  SceneDelegate.swift
//  Brogue
//
//  Creates the window with a SwiftUI UIHostingController as its
//  rootViewController. The hosting controller wraps `ContentView`, which in
//  turn hosts the legacy UIKit `BrogueViewController` via
//  `UIViewControllerRepresentable`.
//
//  Why this indirection: see the comment block at the top of ContentView.swift.
//  Short version — iPadOS 18 only honors home-indicator gesture deferral
//  (`.defersSystemGestures(on: .bottom)`) when the rootViewController is a
//  clean SwiftUI host. Setting the equivalent properties directly on
//  BrogueViewController didn't work; SwiftUI hosting does.
//
//  Info.plist's UIApplicationSceneManifest references this class by name and
//  intentionally does NOT set `UISceneStoryboardFile` — we create the window
//  and root VC ourselves here so we control the host. The storyboard is still
//  used (BrogueViewController is loaded from it inside ContentView), it just
//  isn't auto-attached to the window.
//

import UIKit
import SwiftUI

@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ContentView())
        window.makeKeyAndVisible()
        self.window = window

        // Handoff (Continuity): a cold launch triggered by a Handoff pickup delivers the activity
        // here. It's stashed and drained once BrogueViewController appears. See docs/design/game-handoff.md.
        NSLog("[HANDOFF] willConnectTo: \(connectionOptions.userActivities.count) activities: \(connectionOptions.userActivities.map { $0.activityType })")
        if let activity = connectionOptions.userActivities.first(where: { $0.activityType == GameHandoff.activityType }) {
            GameHandoff.deliver(activity)
        }
    }

    // Handoff (Continuity): a pickup while the app is already running arrives here.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        NSLog("[HANDOFF] scene continue: \(userActivity.activityType)")
        GameHandoff.deliver(userActivity)
    }

    // Handoff (Continuity): the system is about to deliver a continuation — logs the type on Mac/iOS.
    func scene(_ scene: UIScene, willContinueUserActivityWithType userActivityType: String) {
        NSLog("[HANDOFF] willContinueUserActivityWithType: \(userActivityType)")
    }

    func scene(_ scene: UIScene, didFailToContinueUserActivityWithType userActivityType: String, error: Error) {
        NSLog("[HANDOFF] didFailToContinue: \(userActivityType) err=\(error.localizedDescription)")
    }
}
