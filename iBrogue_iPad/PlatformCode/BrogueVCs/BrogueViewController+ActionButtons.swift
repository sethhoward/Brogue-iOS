//
//  BrogueViewController+ActionButtons.swift
//  Brogue
//
//  On-screen action buttons (the four configurable side buttons + center shortcut), their
//  layout and visibility, the file-management and Game Center entry points, the d-pad drag
//  handlers, and the long-press side-button rebinding menus. Extracted verbatim from
//  BrogueViewController.swift as part of splitting that file by function.
//

import UIKit

extension BrogueViewController {

    /// Builds the buttons once and adds them above the SKView. They stay hidden
    /// until `applyNotchInsets` positions them and `updateActionButtonVisibility`
    /// reveals them for cutout devices during gameplay.
    func setupActionButtons() {
        actionButtons = sideButtonKeys.indices.map { slot in
            let button = UIButton(type: .custom)
            // Soft off-white to echo Brogue's menu text rather than a stark #FFF
            // (a crisp system font at pure white reads much harsher than the
            // game's anti-aliased bitmap font does).
            // Off-white tint so template SF Symbols echo Brogue's menu text.
            button.tintColor = UIColor(white: 0.8, alpha: 1.0)
            button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            button.layer.cornerRadius = 8
            // Translucent gray border — Brogue's `gray` is {50,50,50} ≈ 0.5 white.
            button.layer.borderColor = UIColor(white: 0.5, alpha: 0.6).cgColor
            button.layer.borderWidth = 1
            // Tag holds the slot index; the bound key lives in sideButtonKeys[slot].
            button.tag = slot
            button.addTarget(self, action: #selector(actionButtonTapped(_:)), for: .touchUpInside)
            // Long-press opens the rebind menu (tap still fires the key).
            button.addInteraction(UIContextMenuInteraction(delegate: self))
            button.isHidden = true
            view.addSubview(button)
            return button
        }
        refreshActionButtonTitles()
    }

    /// Builds the title-screen file-manager button in code and pins it above the
    /// seed button, joining the other title overlays. It starts visible because
    /// the app always launches on the title screen; `lastBrogueGameEvent` hides it
    /// once a game starts.
    private func setupManageFilesButton() {
        let button = UIButton(type: .system)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        button.setImage(UIImage(systemName: "tray.full.fill", withConfiguration: symbolConfig), for: .normal)
        // Match the off-white the side buttons use to echo Brogue's menu text.
        button.tintColor = UIColor(white: 0.8, alpha: 1.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(manageFilesButtonPressed), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: seedButton.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: seedButton.topAnchor, constant: 26),
            button.widthAnchor.constraint(equalToConstant: 60),
            button.heightAnchor.constraint(equalToConstant: 60),
        ])
        manageFilesButton = button
    }

    @objc private func manageFilesButtonPressed() {
        let nav = UINavigationController(rootViewController: FileManagementViewController())
        present(nav, animated: true)
    }

    /// Invoked from the Classic engine's title menu ("File Management" item).
    @objc func presentFileManagementScreen() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            let nav = UINavigationController(rootViewController: FileManagementViewController())
            self.present(nav, animated: true)
        }
    }

    /// Invoked from the BrogueCE/Brogue SE engine's title menu ("File Management" item).
    /// CE and SE share the same CEHost bridge, so this one handler serves both — it
    /// scopes the browser to the *current* engine's save directory (Documents/ce or
    /// Documents/se) so it doesn't show Classic's (or the other engine's) files.
    @objc func presentFileManagementScreenForCE() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            // iOS port (Brogue SE): pick the subfolder from the running engine. SE saves
            // live in Documents/se; previously this was hardcoded to "ce", so SE's file
            // management always showed an empty CE directory ("no files found").
            var subfolder = "ce"
            var allowsDuplicate = false
            if self.currentEngine == .se {
                subfolder = "se"
                allowsDuplicate = true   // debug aid: SE-only "Duplicate" swipe action
            }
            let saveDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(subfolder)
            // iOS port (iBrogue): debug "Import" lets us pull in a shared CE/SE save
            // (e.g. a bug report's exact game) into the engine's directory to load it.
            let nav = UINavigationController(rootViewController:
                FileManagementViewController(directory: saveDir,
                                             allowsDuplicate: allowsDuplicate,
                                             allowsImport: true))
            self.present(nav, animated: true)
        }
    }

    /// Invoked from the Classic engine's title menu ("Game Center" item).
    @objc func presentGameCenterScreen() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            GameCenter.shared.showLeaderboard(id: GameCenter.highScoreLeaderboardID, from: self)
        }
    }

    /// Invoked from the BrogueCE engine's title menu (View > "Game Center" item).
    /// Opens the CE-specific leaderboard, separate from Classic's.
    @objc func presentGameCenterScreenForCE() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            GameCenter.shared.showLeaderboard(id: GameCenter.ceHighScoreLeaderboardID, from: self)
        }
    }

    /// Sets each button's face to the SF Symbol for its bound command.
    private func refreshActionButtonTitles() {
        for (slot, button) in actionButtons.enumerated() where slot < sideButtonKeys.count {
            let name = BrogueViewController.symbolName(for: sideButtonKeys[slot])
            button.setImage(UIImage(systemName: name, withConfiguration: BrogueViewController.buttonSymbolConfig), for: .normal)
        }
    }

    @objc private func actionButtonTapped(_ sender: UIButton) {
        let slot = sender.tag
        guard slot >= 0, slot < sideButtonKeys.count else { return }
        hapticsController.fireButton()
        addKeyEvent(event: sideButtonKeys[slot])
    }

    /// Styles and wires the storyboard center button. Reuses the side-button
    /// look; tap fires its bound key (unless "Nothing"), long-press rebinds it.
    /// Visibility/position are handled by the D-pad it lives inside.
    func setupCenterShortcutButton() {
        guard let button = directionsViewController?.centerShortcutButton else { return }
        button.tintColor = UIColor(white: 0.8, alpha: 1.0)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 8
        button.layer.borderColor = UIColor(white: 0.5, alpha: 0.6).cgColor
        button.layer.borderWidth = 1
        button.addTarget(self, action: #selector(centerButtonTapped), for: .touchUpInside)
        button.addInteraction(UIContextMenuInteraction(delegate: self))
        refreshCenterButtonAppearance()
    }

    /// The key the center button acts as *right now*. Normally its bound key, but when bound to
    /// "Continue travel" it becomes a smart button: continue while a journey is pending, else Rest
    /// once. Only the center button is reactive — a side button bound to Continue travel stays pure
    /// (always sends the continue key, which the engine no-ops when nothing is pending).
    private var centerButtonEffectiveKey: UInt8 {
        if centerButtonKey == BrogueViewController.continueTravelKeyCode && !isTravelPending {
            return "z".ascii   // idle → Rest once
        }
        return centerButtonKey
    }

    /// Center button shows the SF Symbol for its effective command (footprints while a journey is
    /// pending, zzz when it will rest instead); when set to "Nothing" it shows a slashed circle so
    /// it stays visible and long-pressable.
    private func refreshCenterButtonAppearance() {
        guard let button = directionsViewController?.centerShortcutButton else { return }
        let name = BrogueViewController.symbolName(for: centerButtonEffectiveKey)
        button.setImage(UIImage(systemName: name, withConfiguration: BrogueViewController.buttonSymbolConfig), for: .normal)
        button.alpha = 1.0
    }

    @objc private func centerButtonTapped() {
        guard centerButtonKey != BrogueViewController.centerButtonNothing else { return }
        hapticsController.fireButton()
        addKeyEvent(event: centerButtonEffectiveKey)
    }

    /// Host callback (fires on the engine thread): the engine reports whether a travel destination
    /// is currently pending. Hop to main for UIKit (matches `setExamining`). Only the reactive
    /// continue binding changes its face with pending state, so we only repaint in that case.
    @objc func setTravelPending(_ pending: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isTravelPending != pending else { return }
            self.isTravelPending = pending
            if self.centerButtonKey == BrogueViewController.continueTravelKeyCode {
                self.refreshCenterButtonAppearance()
            }
        }
    }

    /// Lays the buttons out along the trailing (cutout) edge: the first half of
    /// the list anchored to the top safe inset stacking down, the second half
    /// anchored to the bottom stacking up. The island/notch occupies the center
    /// of the edge, so leaving the middle empty dodges it without needing its
    /// (unavailable) exact rect.
    func layoutActionButtons(insets: UIEdgeInsets) {
        guard !actionButtons.isEmpty else { return }

        let size = Self.actionButtonSize
        let gap = Self.actionButtonGap
        let margin = Self.actionButtonEdgeMargin
        let bounds = view.bounds

        // Follow the notch: hug the cutout edge (right in landscapeLeft, left in
        // landscapeRight), a hair in from the rounded corner.
        let x = notchOnRight ? bounds.maxX - size - margin : bounds.minX + margin

        // Notch devices get an extra outward push on both pairs (away from center).
        let notchPush = currentDisplayCutout(insets: insets) == .notch
            ? Self.actionButtonNotchCenterPush : 0

        let topCount = (actionButtons.count + 1) / 2   // 4 → 2 top, 2 bottom
        let topStart = insets.top + gap + Self.actionButtonTopOffset - notchPush
        let bottomBase = bounds.maxY - insets.bottom - gap + notchPush

        for (index, button) in actionButtons.enumerated() {
            let y: CGFloat
            if index < topCount {
                // Top zone: stack downward from the top inset.
                y = topStart + CGFloat(index) * (size + gap)
            } else {
                // Bottom zone: stack upward from the bottom, last button lowest.
                let fromBottom = actionButtons.count - 1 - index
                y = bottomBase - size - CGFloat(fromBottom) * (size + gap)
            }
            button.frame = CGRect(x: x, y: y, width: size, height: size)
        }
    }

    /// Buttons are visible only on cutout devices (there's no strip to occupy on
    /// SE phones / iPads) and only while the directional pad is — i.e. during
    /// active dungeon play.
    func updateActionButtonVisibility() {
        let hasStrip = currentDisplayCutout(insets: bestSafeAreaInsets) != .none
        let visible = hasStrip && gameplayControlsActive
        for button in actionButtons {
            button.isHidden = !visible
            button.isUserInteractionEnabled = visible
        }
        // Warm up the haptic engine so the first tap / hit fires without latency.
        // (A cold Taptic Engine often drops or weakens the first impactOccurred.)
        if visible {
            hapticsController.warmUp()
            // First time the buttons appear in a game, explain long-press rebinding.
            maybeShowKeybindHint()
        }
    }

    @objc func handleDirectionTouch(_ sender: UIPanGestureRecognizer) {
        directionsViewController?.cancel()
    }
    
    @objc func draggedView(_ sender: UIPanGestureRecognizer) {
        directionsViewController?.cancel()
        // Fold any transient notch-avoidance into the real offset as the drag
        // starts, so the pad doesn't jump and the saved value is exactly where the
        // user leaves it (a deliberate park, even under the cutout, is honored).
        if sender.state == .began {
            dpadUserOffset.x += dpadNotchAvoidance
            dpadNotchAvoidance = 0
        }
        let translation = sender.translation(in: view)
        dpadUserOffset.x += translation.x
        dpadUserOffset.y += translation.y
        applyDpadTransform()
        sender.setTranslation(.zero, in: view)
        // Persist once the drag settles, not on every incremental move.
        if sender.state == .ended || sender.state == .cancelled {
            saveDpadOffset()
        }
    }
}

// MARK: - Side-button rebinding (long-press menu + persistence)

extension BrogueViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let button = interaction.view as? UIButton else { return nil }
        if button == directionsViewController?.centerShortcutButton {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.centerRebindMenu()
            }
        }
        guard let slot = actionButtons.firstIndex(of: button) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.rebindMenu(forSlot: slot)
        }
    }

    /// Sectioned menu of bindable commands for one side-button slot. Each row
    /// shows the human-readable name and the key; the current binding is checked.
    /// Commands offered in the rebind menus for the active engine. CE-only
    /// commands (e.g. re-throw) are dropped while Classic is running; SE-only
    /// commands (e.g. re-apply staff) are shown only while Brogue SE is running.
    private func availableCommands() -> [Command] {
        BrogueViewController.commandCatalog.filter {
            (currentEngine.isCEFamily || !$0.ceOnly) && (currentEngine == .se || !$0.seOnly)
        }
    }

    private func rebindMenu(forSlot slot: Int) -> UIMenu {
        let currentKey = sideButtonKeys[slot]
        let catalog = availableCommands()
        let sections = BrogueViewController.commandCategoryOrder.map { category -> UIMenu in
            let actions = catalog
                .filter { $0.category == category }
                .map { command -> UIAction in
                    let action = UIAction(title: BrogueViewController.commandMenuTitle(command),
                                          image: UIImage(systemName: BrogueViewController.symbolName(for: command.key))) { [weak self] _ in
                        self?.bindSideButton(slot: slot, to: command.key)
                    }
                    action.state = (command.key == currentKey) ? .on : .off
                    return action
                }
            return UIMenu(title: category, options: .displayInline, children: actions)
        }
        return UIMenu(title: "Rebind button", children: sections)
    }

    private func bindSideButton(slot: Int, to key: UInt8) {
        guard slot >= 0, slot < sideButtonKeys.count else { return }
        sideButtonKeys[slot] = key
        saveSideButtonKeys()
        refreshActionButtonTitles()
    }

    /// Loads the four bound keys from UserDefaults, validating each against the
    /// catalog and falling back to the slot default for anything missing/invalid.
    static func loadSideButtonKeys() -> [UInt8] {
        let valid = Set(commandCatalog.map { $0.key })
        var keys = defaultSideButtonKeys
        if let stored = UserDefaults.standard.array(forKey: sideButtonKeysDefaultsKey) as? [Int] {
            for slot in keys.indices where slot < stored.count {
                let candidate = UInt8(truncatingIfNeeded: stored[slot])
                if valid.contains(candidate) {
                    keys[slot] = candidate
                }
            }
        }
        return keys
    }

    private func saveSideButtonKeys() {
        UserDefaults.standard.set(sideButtonKeys.map(Int.init),
                                  forKey: BrogueViewController.sideButtonKeysDefaultsKey)
    }

    /// Rebind menu for the center button: the same sectioned command list as the
    /// side buttons, prefixed with a "Nothing" option that unbinds it.
    private func centerRebindMenu() -> UIMenu {
        let current = centerButtonKey
        let none = UIAction(title: "Nothing",
                            image: UIImage(systemName: "circle.slash")) { [weak self] _ in
            self?.bindCenterButton(to: BrogueViewController.centerButtonNothing)
        }
        none.state = (current == BrogueViewController.centerButtonNothing) ? .on : .off
        let noneSection = UIMenu(title: "", options: .displayInline, children: [none])

        let catalog = availableCommands()
        let sections = BrogueViewController.commandCategoryOrder.map { category -> UIMenu in
            let actions = catalog
                .filter { $0.category == category }
                .map { command -> UIAction in
                    let action = UIAction(title: BrogueViewController.commandMenuTitle(command),
                                          image: UIImage(systemName: BrogueViewController.symbolName(for: command.key))) { [weak self] _ in
                        self?.bindCenterButton(to: command.key)
                    }
                    action.state = (command.key == current) ? .on : .off
                    return action
                }
            return UIMenu(title: category, options: .displayInline, children: actions)
        }
        return UIMenu(title: "Rebind center button", children: [noneSection] + sections)
    }

    private func bindCenterButton(to key: UInt8) {
        centerButtonKey = key
        saveCenterButtonKey()
        refreshCenterButtonAppearance()
    }

    /// Loads the center button's key, accepting any catalog key or the "Nothing"
    /// sentinel; falls back to the default ("Rest once") when unset/invalid.
    static func loadCenterButtonKey() -> UInt8 {
        guard UserDefaults.standard.object(forKey: centerButtonKeyDefaultsKey) != nil else {
            return centerButtonDefaultKey
        }
        let valid = Set(commandCatalog.map { $0.key }).union([centerButtonNothing])
        let stored = UInt8(truncatingIfNeeded: UserDefaults.standard.integer(forKey: centerButtonKeyDefaultsKey))
        return valid.contains(stored) ? stored : centerButtonDefaultKey
    }

    private func saveCenterButtonKey() {
        UserDefaults.standard.set(Int(centerButtonKey),
                                  forKey: BrogueViewController.centerButtonKeyDefaultsKey)
    }
}
