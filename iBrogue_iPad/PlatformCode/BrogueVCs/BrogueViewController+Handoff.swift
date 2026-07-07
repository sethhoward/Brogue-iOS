//
//  BrogueViewController+Handoff.swift
//  Brogue
//
//  VC-side Continuity Handoff flow: receiving a pickup (parse + guard + install/resume) and
//  the source-side freeze / relinquish during transfer. The NSUserActivity and stream plumbing
//  lives in GameHandoff.swift. Extracted verbatim from BrogueViewController.swift as part of
//  splitting that file by function.
//

import UIKit

extension BrogueViewController {

    // MARK: - Handoff receive (Phase 2: parse + guard; transfer/resume land in Phase 3)

    /// A Handoff pickup arrived while the app is already running.
    @objc func handoffDidArrive() {
        DispatchQueue.main.async { [weak self] in self?.processPendingHandoff() }
    }

    /// Drains a pending Handoff pickup (from a live notification or a cold launch): parse the payload
    /// and run the compatibility guard, then surface the result. The stream transfer + resume land in
    /// Phase 3. See docs/design/game-handoff.md.
    func processPendingHandoff() {
        // Only act once we're on screen so we can present; otherwise viewDidAppear retries.
        guard viewIfLoaded?.window != nil else { return }
        guard let activity = GameHandoff.pendingActivity else { return }
        GameHandoff.pendingActivity = nil
        let info = activity.userInfo ?? [:]

        let lineage = (info["lineage"] as? String) ?? ""
        let theirVersion = (info["version"] as? String) ?? "?"

        // Guard 1 — lineage must be a replay-safe engine (CE or SE; Classic is never advertised).
        guard lineage == "ce" || lineage == "se" else {
            presentHandoffAlert(title: "Can't Continue",
                                message: "This game isn't from a compatible engine.")
            return
        }
        // Guard 2 — engine recording/save-compatibility version must match (the token the engine writes
        // into save headers and checks on load). It's stable across app builds/platforms, so cross-device
        // handoff isn't blocked by differing build numbers. The engine's own load-time check backstops it.
        let ourVersion = GameHandoff.recordingVersion(lineage: lineage)
        guard theirVersion == ourVersion else {
            presentHandoffAlert(title: "Update Needed",
                                message: "That game is from a different version of Brogue (\(theirVersion)); this device runs \(ourVersion). Update both to the same version to hand off.")
            return
        }

        // Pull the payload over the continuation streams, then write it + resume.
        var streamsArrived = false
        activity.getContinuationStreams { [weak self] input, output, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                streamsArrived = true
                guard let input = input, let output = output, error == nil else {
                    self.presentHandoffAlert(title: "Handoff Failed",
                                             message: "Couldn't open the transfer channel: \(error?.localizedDescription ?? "no streams").")
                    return
                }
                HandoffTransfer.receive(input: input, output: output) { data, commit in
                    self.installAndResumeHandoff(data: data, lineage: lineage, commit: commit)
                }
            }
        }
        // Watchdog: if getContinuationStreams never calls back (silent hang seen on Mac), surface it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self, !streamsArrived else { return }
            self.presentHandoffAlert(title: "Handoff Timed Out",
                                     message: "The transfer channel never opened. Keep the sending device on its game screen; both must share one Apple ID.")
        }
    }

    func presentHandoffAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// 3c: write the received recording into the target engine's save dir, set that engine's resume
    /// marker, and boot the engine so `initializeLaunchArguments` cold-resumes it (`NG_OPEN_GAME`).
    /// The engine renames the file to LastGame + deletes this source on load. No relinquish on the
    /// source yet (Phase 4). See docs/design/game-handoff.md.
    private func installAndResumeHandoff(data: Data, lineage: String, commit: @escaping (Bool) -> Void) {
        let target: EngineKind = (lineage == "se") ? .se : .ce
        // Deep ACK: only accept (commit(true) → ACK → the source relinquishes) if we can actually resume
        // right now — i.e. this device is at its title (no live game to clobber, and performHandoffBoot
        // can restart cleanly). If it's anywhere in its own game (playing OR in a menu — both leave
        // `atTitle` false), REFUSE (commit(false) → NAK) and write nothing, so the source keeps its run:
        // no data loss, no fork. Refusing-when-unsure is the safe direction; on a cold launch the ~1s
        // transfer gives the engine time to reach its title first. (Phase 5 will auto persist-before-
        // replace instead of refusing.) See docs/design/game-handoff.md.
        guard atTitle, !switchPending else {
            commit(false)
            presentHandoffAlert(title: "Finish Your Game First",
                                message: "This device isn't at its title screen. Return to the title, then hand off again — your other device kept its run.")
            return
        }
        let subfolder = (target == .se) ? "se" : "ce"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(subfolder)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = uniqueHandoffFileName(in: dir)
            try data.write(to: dir.appendingPathComponent(name))
            // Relative filename: the engine chdir's to Documents/<subfolder>, so it resolves on boot.
            UserDefaults.standard.set(name, forKey: (target == .se) ? "se resume path" : "ce resume path")
            commit(true)                 // ACK the source → it relinquishes; we're committed to resuming
            performHandoffBoot(target)
        } catch {
            commit(false)                // couldn't save → don't take the source's run
            presentHandoffAlert(title: "Handoff Failed",
                                message: "Couldn't save the received game: \(error.localizedDescription)")
        }
    }

    /// A collision-free save name in `dir` (the engine renames it to LastGame on load, so it's transient).
    private func uniqueHandoffFileName(in dir: URL) -> String {
        let base = "Handoff", ext = "broguesave"
        var name = "\(base).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base) \(n).\(ext)"
            n += 1
        }
        return name
    }

    /// Restart (or switch to) `target` so a fresh `rogueMain` consumes the resume marker. Unlike
    /// `requestEngineSwitch`, allows `target == currentEngine` (the common iPad-SE → SE handoff). The
    /// engine's terminate hook lives in its title loop, so if we're not at the title yet, defer until
    /// `setCEAtTitle` reports it.
    private func performHandoffBoot(_ target: EngineKind) {
        guard atTitle, !switchPending else { handoffResumePending = target; return }
        switchPending = true
        pendingTargetEngine = target
        switch currentEngine {
        case .ce: ce_requestTermination()
        case .se: se_requestTermination()
        case .classic: setClassicTerminationRequested(true)
        }
    }

    // MARK: - Handoff source: freeze during transfer, relinquish on ACK (Phase 4)

    /// Freeze the run while a handoff transfer is in flight: starve input so no turn advances (a turn
    /// taken mid-transfer would be lost on relinquish), and show a "Handing off…" overlay.
    func beginHandoffFreeze() {
        synchronized {
            handoffInFlight = true
            keyEvents.removeAll()
            touchEvents.removeAll()
        }
        showHandoffOverlay()
    }

    /// Transfer failed/aborted — unfreeze and resume in place; nothing was lost.
    func endHandoffFreeze() {
        synchronized {
            handoffInFlight = false
            keyEvents.removeAll()
            touchEvents.removeAll()
        }
        hideHandoffOverlay()
    }

    /// Receiver confirmed (deep ACK) — relinquish: inject the relinquish key so the engine ends the run
    /// silently, deletes its save, and drops to title; also clear this engine's resume marker.
    func relinquishAfterHandoff() {
        synchronized {
            keyEvents.removeAll()
            touchEvents.removeAll()
            handoffInFlight = false   // let the injected relinquish key through
            keyEvents.append(QueuedKeyEvent(code: Self.handoffRelinquishKey, shift: false, control: false, raw: false))
        }
        switch currentEngine {
        case .se: se_clearResumeMarker()
        case .ce: ce_clearResumeMarker()
        case .classic: break
        }
        hideHandoffOverlay()
    }

    private func showHandoffOverlay() {
        guard handoffOverlay == nil else { return }
        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        let label = UILabel()
        label.text = "Handing off…"
        label.textColor = .white
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        view.addSubview(overlay)
        handoffOverlay = overlay
    }

    private func hideHandoffOverlay() {
        handoffOverlay?.removeFromSuperview()
        handoffOverlay = nil
    }

    /// Called by the CE bridge: true only while the CE title screen is showing.
    @objc func setCEAtTitle(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.atTitle = value
            // Full-screen (no insets) on the title; reserve insets everywhere
            // else — gameplay AND in-game menus — so the width doesn't jump.
            self.skViewPort.rogueScene.paddingEnabled = !value
            // CE never sets lastBrogueGameEvent, so this is where a CE run begins/ends
            // for zoom purposes. At the title, drop the display to 1×; leaving the title
            // (a game is starting/resuming) restores the player's remembered zoom — the
            // first player-cell report then animates it in, recentered on the player.
            if value { self.resetZoom() } else { self.restoreStoredZoom() }

            // Handoff (Continuity): advertise the run while in play; stop at the title. Driven
            // here because this is the CE/SE begin/end signal (Classic never calls setCEAtTitle,
            // so it's excluded for free). Phase 1 advertises with best-effort metadata; live
            // depth/turn arrive via a game-context push in a later phase. See docs/design/game-handoff.md.
            if value {
                self.gameHandoff.stop()
                // A received handoff waiting for the title can now boot into its run (see performHandoffBoot).
                if let target = self.handoffResumePending {
                    self.handoffResumePending = nil
                    self.performHandoffBoot(target)
                }
            } else if self.currentEngine != .classic {
                self.gameHandoff.advertise(lineage: self.engineLineageString,
                                           seed: self.lastPersistedSeed,
                                           depth: 0, turn: 0)
            }
        }
    }

    /// Runs (on the engine thread) when `rogueMain` returns. If a swap is pending,
    /// boots the other engine on the main thread.
    func engineDidExit() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.switchPending else { return }
            self.switchPending = false
            self.engineThread = nil
            self.ceHost = nil
            // Boot the engine captured at request time (the 3-way cycle's target),
            // and remember the choice.
            self.currentEngine = self.pendingTargetEngine ?? self.currentEngine
            self.pendingTargetEngine = nil
            self.persistEngine()
            self.updateVersionChooserLabel()
            self.startEngine()
        }
    }
}
