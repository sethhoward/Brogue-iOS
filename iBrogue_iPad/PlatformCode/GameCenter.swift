//
//  GameCenter.swift
//  Brogue
//
//  Modern replacement for GameCenterManager. Uses GameKit APIs current as of iOS 14+
//  (GKGameCenterViewController(leaderboardID:...), GKLeaderboard.submitScore, GKAchievement.report).
//

import Foundation
import GameKit
import UIKit

@objc final class GameCenter: NSObject {
    @objc public static let shared = GameCenter()

    /// Matches the leaderboard ID configured in App Store Connect.
    @objc public static let highScoreLeaderboardID = "iBrogue_High_Score"

    /// Held weakly so the auth handler can re-present the sign-in sheet if needed.
    private weak var presenter: UIViewController?

    private override init() {
        super.init()
    }

    @objc(authenticateFromViewController:)
    func authenticate(from viewController: UIViewController) {
        presenter = viewController
        NSLog("[GameCenter] starting authentication; isAuthenticated=\(GKLocalPlayer.local.isAuthenticated)")
        GKLocalPlayer.local.authenticateHandler = { [weak self] signInVC, error in
            if let signInVC {
                NSLog("[GameCenter] auth handler returned a sign-in view controller; presenting")
                self?.presenter?.present(signInVC, animated: true)
            } else if let error {
                NSLog("[GameCenter] auth error: \(error.localizedDescription)")
            } else {
                NSLog("[GameCenter] auth complete; isAuthenticated=\(GKLocalPlayer.local.isAuthenticated)")
            }
        }
    }

    @objc(showLeaderboardWithID:fromViewController:)
    func showLeaderboard(id leaderboardID: String, from viewController: UIViewController) {
        NSLog("[GameCenter] showLeaderboard tapped; isAuthenticated=\(GKLocalPlayer.local.isAuthenticated)")
        // Don't gate on isAuthenticated — GKGameCenterViewController handles the
        // unauthenticated state itself (shows the sign-in prompt). Gating here
        // means the button silently does nothing if auth hasn't completed yet.
        let gcvc = GKGameCenterViewController(
            leaderboardID: leaderboardID,
            playerScope: .global,
            timeScope: .allTime
        )
        gcvc.gameCenterDelegate = self
        viewController.present(gcvc, animated: true) {
            NSLog("[GameCenter] leaderboard presented")
        }
    }

    @objc(reportScore:leaderboardID:)
    func reportScore(_ score: Int64, leaderboardID: String) {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        GKLeaderboard.submitScore(
            Int(score),
            context: 0,
            player: GKLocalPlayer.local,
            leaderboardIDs: [leaderboardID]
        ) { error in
            if let error {
                NSLog("Game Center: score submit failed: \(error.localizedDescription)")
            }
        }
    }

    @objc(submitAchievement:percentComplete:)
    func submitAchievement(_ identifier: String, percentComplete: Double) {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        let achievement = GKAchievement(identifier: identifier)
        achievement.percentComplete = percentComplete
        achievement.showsCompletionBanner = true
        GKAchievement.report([achievement]) { error in
            if let error {
                NSLog("Game Center: achievement report failed: \(error.localizedDescription)")
            }
        }
    }
}

extension GameCenter: GKGameCenterControllerDelegate {
    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true)
    }
}
