//
//  BrogueViewController+EngineSession.swift
//  Brogue
//
//  Engine session lifecycle: booting the selected engine on a background thread, in-process
//  engine switching, and the CE/SE bridge setters (UI mode, targeting, examine/menu boxes,
//  title state, game context). Extracted verbatim from BrogueViewController.swift as part of
//  splitting that file by function.
//

import UIKit

extension BrogueViewController {

    // MARK: - Engine session (start / in-process swap)

    /// Boots the engine named by `currentEngine` on a large-stack background
    /// thread. When `rogueMain` returns (e.g. after a Quit), `engineDidExit` runs.
    func startEngine() {
        switch currentEngine {
        case .classic:
            // Classic 1.7.5 engine, in its own embedded framework. Same CEHost bridge as
            // CE/SE; classic_start() clears any prior termination request internally.
            let host = CEHost(viewPort: skViewPort, viewController: self)
            ceHost = host
            // iPhone-only layout tweaks (taller bottom button bar). iPad: default.
            classic_setPhoneLayout(UIDevice.current.userInterfaceIdiom == .phone ? 1 : 0)
            let thread = Thread { [weak self] in
                classic_start(host)
                self?.engineDidExit()
            }
            thread.stackSize = 400 * 8192
            thread.start()
            engineThread = thread

        case .ce:
            // BrogueCE 1.15 engine, in the embedded framework. Bridge → CEHost.
            let host = CEHost(viewPort: skViewPort, viewController: self)
            ceHost = host
            let thread = Thread { [weak self] in
                ce_start(host)
                self?.engineDidExit()
            }
            thread.stackSize = 400 * 8192
            thread.start()
            engineThread = thread

        case .se:
            // Brogue SE engine, in its own embedded framework. Same CEHost bridge as
            // CE; only the entry point differs (se_start vs ce_start).
            let host = CEHost(viewPort: skViewPort, viewController: self)
            ceHost = host
            let thread = Thread { [weak self] in
                se_start(host)
                self?.engineDidExit()
            }
            thread.stackSize = 400 * 8192
            thread.start()
            engineThread = thread
        }
    }

    /// Engines in title-screen cycling order (Classic → BrogueCE → Brogue SE).
    private static let engineCycle: [EngineKind] = [.classic, .ce, .se]

    /// Cycles to the next/previous engine in lineage order (wrapping). `forward`
    /// advances Classic → CE → SE; `!forward` goes the other way.
    func cycleEngine(forward: Bool) {
        let cycle = Self.engineCycle
        guard let idx = cycle.firstIndex(of: currentEngine) else { return }
        let n = cycle.count
        let target = cycle[forward ? (idx + 1) % n : (idx - 1 + n) % n]
        requestEngineSwitch(to: target)
    }

    /// Requests an in-place swap to `target`. Only meaningful at the title screen:
    /// injects the Quit keystroke so the active engine unwinds out of its main-menu
    /// loop and `rogueMain` returns cleanly; `engineDidExit` then boots `target`.
    func requestEngineSwitch(to target: EngineKind) {
        // Only switch from a title screen — the engine's terminate hook lives in
        // its title loop, so requesting it mid-game would hang the engine.
        guard atTitle, !switchPending, target != currentEngine else { return }
        switchPending = true
        pendingTargetEngine = target
        switch currentEngine {
        case .ce:
            ce_requestTermination()
        case .se:
            se_requestTermination()
        case .classic:
            classic_requestTermination()
        }
    }

    /// Maps BrogueCE's `uiMode` (reported by the bridge) to on-screen control
    /// visibility. CE has only four states and draws its own in-engine menu, so
    /// this is a CE-specific mapping rather than the Classic `lastBrogueGameEvent`
    /// path. Values: 0 = InMenu, 1 = InNormalPlay, 2 = ShowEscape,
    /// 3 = ShowKeyboardAndEscape.
    @objc func applyCEUIMode(_ uiMode: Int) {
        DispatchQueue.main.async {
            let inPlay = (uiMode == 1)
            let showEscape = (uiMode == 2 || uiMode == 3)
            let keyboard = (uiMode == 3)

            // CE renders its own menu (New Game / Play / View); hide the Classic
            // overlay buttons (leaderboard is Game Center — Classic only).
        //    self.leaderBoardButton?.isHidden = true
            self.seedButton.isHidden = true
            self.manageFilesButton?.isHidden = true
            self.showInventoryButton.isHidden = true

            // Directional pad + action bar only during normal play. The d-pad is additionally
            // hidden when a hardware keyboard is attached; see refreshDirectionPadVisibility().
            self.gameplayControlsActive = inPlay

            // iOS port (iBrogue): the menu magnify is valid ONLY while a button menu is up
            // (uiMode == InMenu, 0). Every other state — normal play, or an escape/keyboard prompt
            // (Save recording, seed entry, the "call" name/inscribe prompts, confirmations) — must
            // drop it, else it lingers on a stale menu rect and tears that overlay. Nested button
            // menus stay InMenu (the bridge dedups the transient InNormalPlay between them), so this
            // never flickers mid-menu. This is the general teardown for CE/SE (Classic uses events).
            if uiMode != 0 { self.tearDownMenuMagnify() }

            self.refreshDirectionPadVisibility()
            self.updateActionButtonVisibility()

            // Escape button when CE is showing an escapable sub-screen (hidden when a hardware
            // keyboard is attached — the physical Escape key covers it; see refreshEscButtonVisibility).
            self.escButtonWanted = showEscape
            self.refreshEscButtonVisibility()

            // Keyboard for text entry (naming a save, entering a seed, etc.).
            if keyboard {
                self.inputTextField.becomeFirstResponder()
            } else {
                self.inputTextField.resignFirstResponder()
            }

            // NOTE: padding (insets) and atTitle are NOT driven from uiMode —
            // uiMode==InMenu is also true for in-game menus, which would wrongly
            // toggle the layout width. Both are driven by setCEAtTitle() instead.
        }
    }

    /// Called by the CE bridge while the player aims a throw/zap. Moves the esc
    /// button to the lower-left corner so it's out of the aiming area, and flags
    /// targeting so the magnifier is allowed (see canShowMagnifier).
    @objc func setCETargeting(_ targeting: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isTargeting = targeting
            self.positionEscButtonForTargeting(targeting)
        }
    }

    /// Called by the Classic bridge (setBrogueTargeting) while the player aims a
    /// throw/zap. Classic has no uiMode==ShowEscape event — CE drives the ESC button's
    /// visibility that way — so unlike setCETargeting this ALSO toggles escButtonWanted;
    /// without it Classic would offer no on-screen way to cancel an aim. The rest mirrors
    /// setCETargeting: repositions the button clear of the aiming area and enables the
    /// magnifier so the player can see what they're aiming at.
    @objc func setClassicTargeting(_ targeting: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isTargeting = targeting
            self.escButtonWanted = targeting
            self.refreshEscButtonVisibility()
            self.positionEscButtonForTargeting(targeting)
        }
    }

    /// Reported by both engines (CE: setExamining via the host protocol; Classic:
    /// setBrogueExamining) as the cursor-loop description box appears/disappears. Just
    /// records box state; the actual zoom-suspend is gated on examineArmed and computed
    /// in the flags' didSet, so it works regardless of whether the box signal arrives
    /// before or after the sidebar tap arms it.
    @objc func setExamining(_ examining: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.examineBoxShown = examining
        }
    }

    /// SE reports the examine description box's window-cell rect here, just before
    /// `setExamining:true` (main-queue FIFO keeps it ahead of the isExamining flip). Stored
    /// for the iPhone fit-zoom in updateZoomForGameState. No effect on iPad (that path is
    /// phone-gated) or on CE/Classic (which never call this → 1× zoom-out).
    @objc func setExamineBox(_ x: Int, y: Int, width: Int, height: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.examineBox = ExamineBox(x: x, y: y, w: width, h: height)
        }
    }

    /// iOS port (iBrogue): the engine reports the window-cell rect of a modal menu overlay here.
    /// Phase 0: driven from the SE title menu (main menu / flyout / variant & mode dialogs). On
    /// iPhone, while at the title, this auto-magnifies that rect to a readable/tappable size —
    /// instantly, no camera movement. Reports overwrite each other as the active menu changes
    /// (e.g. main menu → dialog → back), so no explicit per-menu clear is needed; the magnify is
    /// torn down when we leave the title (see resetZoom / restoreStoredZoom). No-op off iPhone.
    @objc func setMenuBox(_ x: Int, y: Int, width: Int, height: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // The title loop re-reports every animation frame; skip the redundant re-apply unless
            // the rect actually changed (or we aren't yet engaged, so a first report always lands).
            let box = MenuBox(x: x, y: y, w: width, h: height)
            guard self.menuBox != box || !self.menuMagnifyEngaged else { return }
            self.menuBox = box
            self.applyMenuMagnify()
        }
    }

    /// iOS port (iBrogue): the engine reports that no menu overlay is shown. Tears down any menu
    /// magnify. (Phase 0 mostly relies on the leave-title teardown; this is the explicit path used
    /// when a menu closes without a state change — and by later phases, e.g. closing inventory.)
    @objc func clearMenuBox() {
        DispatchQueue.main.async { [weak self] in self?.tearDownMenuMagnify() }
    }

    /// Moves the esc button to the lower-left safe-area corner during targeting,
    /// restoring its resting position afterward. Uses a transform (rather than
    /// touching .center) so it composes with the storyboard layout, matching how
    /// the button is already offset at launch.
    private func positionEscButtonForTargeting(_ targeting: Bool) {
        guard let escButton = escButton, let parent = escButton.superview else { return }
        if targeting {
            if savedEscTransform == nil { savedEscTransform = escButton.transform }
            // `center` is transform-independent (constraint-defined), so the
            // delta below lands the button's center at the lower-left corner.
            // Hug the actual left edge (ignoring the left safe-area inset) with a
            // little padding, and sit low — just clear of the home indicator.
            let size = escButton.bounds.size
            let leftPadding: CGFloat = 10
            let bottomPadding: CGFloat = 6
            let targetCenter = CGPoint(
                x: parent.bounds.minX + leftPadding + size.width / 2,
                y: parent.bounds.maxY - parent.safeAreaInsets.bottom - bottomPadding - size.height / 2)
            escButton.transform = CGAffineTransform(translationX: targetCenter.x - escButton.center.x,
                                                    y: targetCenter.y - escButton.center.y)
        } else if let saved = savedEscTransform {
            escButton.transform = saved
        }
    }

    /// Lineage tag for the Handoff payload / save-dir routing: "ce", "se", or "classic".
    var engineLineageString: String {
        switch currentEngine {
        case .classic: return "classic"
        case .ce: return "ce"
        case .se: return "se"
        }
    }

    /// The current engine's last-known game seed (persisted by the bridge's
    /// `cePersistLastSeed`). Best-effort display metadata for the Handoff banner; 0 if unset.
    var lastPersistedSeed: UInt64 {
        let key = (currentEngine == .se) ? "se last game seed" : "ce last game seed"
        return (UserDefaults.standard.object(forKey: key) as? NSNumber)?.uint64Value ?? 0
    }

    /// Called by the CE/SE bridge (deduped on depth change) with the live game's context, so the
    /// Handoff activity's banner/metadata stays current. Runs on the engine thread → hop to main.
    func setGameContext(depth: Int, turn: Int, seed: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.atTitle, self.currentEngine != .classic else { return }
            self.gameHandoff.advertise(lineage: self.engineLineageString,
                                       seed: seed, depth: depth, turn: turn)
        }
    }
}
