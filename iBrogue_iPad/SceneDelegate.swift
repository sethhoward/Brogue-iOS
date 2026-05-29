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
    }
}
