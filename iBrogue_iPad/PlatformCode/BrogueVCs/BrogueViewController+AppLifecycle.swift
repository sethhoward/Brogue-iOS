//
//  BrogueViewController+AppLifecycle.swift
//  Brogue
//
//  App background-suspend / foreground-resume handling. Extracted verbatim from
//  BrogueViewController.swift as part of splitting that file by function.
//

import UIKit

// MARK: - App lifecycle (background suspend / resume)

extension BrogueViewController {
    /// Wires background/foreground notifications that drive save-on-background and
    /// auto-resume-on-cold-launch. See docs/design/background-suspend-resume.md.
    func setupAppLifecycleObserver() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// On background: ask the active engine to snapshot exact state at its next poll point and mark
    /// it for cold-launch resume. The engine guards against title/playback, but we also skip the
    /// request at the title where there's no live game. Fire-and-forget — the snapshot completes
    /// inside iOS's brief grace window before suspension (see the design note for why we don't
    /// take a background-task assertion).
    @objc private func appDidEnterBackground() {
        didBackgroundThisProcess = true
        guard !atTitle else { return }
        switch currentEngine {
        case .classic: setClassicBackgroundSaveRequested(true)
        case .ce:      ce_requestBackgroundSave()
        case .se:      se_requestBackgroundSave()
        }
    }

    /// On foreground: cold launch fires this too, but `didBackgroundThisProcess` is only set after a
    /// real background in THIS process — so on a fresh launch we do nothing and let the engine
    /// consume the resume marker. On a warm foreground (the process survived) the in-memory game is
    /// authoritative, so we drop the now-stale resume marker.
    @objc private func appDidBecomeActive() {
        guard didBackgroundThisProcess else { return }
        switch currentEngine {
        case .classic: clearClassicResumeMarker()
        case .ce:      ce_clearResumeMarker()
        case .se:      se_clearResumeMarker()
        }
    }
}
