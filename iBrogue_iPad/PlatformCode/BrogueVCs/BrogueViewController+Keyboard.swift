//
//  BrogueViewController+Keyboard.swift
//  Brogue
//
//  Keyboard input: the on-screen d-pad KVO bridge and key-event queue, the hidden
//  text-field delegate for in-game text prompts, and hardware-keyboard press handling
//  with key-repeat and Brogue key remapping. Extracted verbatim from
//  BrogueViewController.swift as part of splitting that file by function.
//

import UIKit
import GameController

extension BrogueViewController {
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(directionsViewController.directionalButton) else { return }

        // While the magnifier is up (a held inspect touch), ignore the d-pad so a
        // second hand on the pad can't fire a move and interrupt the inspection.
        guard magView.isHidden else { return }

        if let tag = directionsViewController?.directionalButton?.tag, let direction = ControlDirection(rawValue: tag) {
            var key: String
            switch direction {
            case .up:
                key = kUP_Key
            case .right:
                key = kRIGHT_key
            case .down:
                key = kDOWN_key
            case .left:
                key = kLEFT_key
            case .upLeft:
                key = kUPLEFT_key
            case .upRight:
                key = kUPRight_key
            case .downRight:
                key = kDOWNRIGHT_key
            case .downLeft:
                key = kDOWNLEFT_key
            case .catchAll:
                return
            }
            
            addKeyEvent(event: key.ascii)
        }
    }
    
    // Synthesized/canonical input (on-screen controls, ESC button, text entry): never scheme-remapped.
    func addKeyEvent(event: UInt8) {
        addKeyEvent(code: event, shift: false, control: false, raw: false)
    }

    // iOS port (iBrogue): full hardware-key enqueue carrying modifiers and the `raw` (scheme-eligible) flag.
    fileprivate func addKeyEvent(code: UInt8, shift: Bool, control: Bool, raw: Bool) {
        // Any key command (move, rest, explore, inventory, …) means the next examine box
        // isn't a sidebar-tap one, so it should suppress while zoomed. Covers auto-explore
        // triggered by a hardware key (button taps are covered by touchesBegan).
        examineFromSidebar = false
        synchronized {
            keyEvents.append(QueuedKeyEvent(code: code, shift: shift, control: control, raw: raw))
        }
    }

    // iOS port (iBrogue): returns the key code and fills the modifier/raw flags. Replaces the old
    // byte-only dequeKeyEvent so the bridges can set rogueEvent.controlKey/shiftKey and decide whether
    // to run the key through the active keyboard scheme. cannot be optional for backward compat.
    @objc(dequeKeyEventWithShift:control:raw:)
    func dequeKeyEvent(shift: UnsafeMutablePointer<ObjCBool>,
                       control: UnsafeMutablePointer<ObjCBool>,
                       raw: UnsafeMutablePointer<ObjCBool>) -> Int32 {
        synchronized {
            guard !keyEvents.isEmpty else {
                fatalError("Deque Key, queue is empty")
            }
            let event = keyEvents.removeFirst()
            shift.pointee = ObjCBool(event.shift)
            control.pointee = ObjCBool(event.control)
            raw.pointee = ObjCBool(event.raw)
            return Int32(event.code)
        }
    }

    @objc func hasKeyEvent() -> Bool {
        synchronized { !handoffInFlight && !keyEvents.isEmpty }
    }
}

extension BrogueViewController: UITextFieldDelegate {
    // `numeric` requests a number pad for digit-only entry (e.g. the seeded-game
    // seed); otherwise the default keyboard is used (e.g. naming a save). The
    // engine pre-fills `string` with its default value and renders the text
    // itself — the field is an off-screen key-capture proxy, so it MUST be seeded
    // with the same default, otherwise iOS suppresses the backspace callback for
    // an empty field and the pre-filled characters can't be deleted (iOS port).
    @objc func requestTextInput(for string: String, numeric: Bool) {
        inputRequestString = string
        DispatchQueue.main.async {
            let desiredType: UIKeyboardType = numeric ? .numberPad : .default
            if self.inputTextField.keyboardType != desiredType {
                self.inputTextField.keyboardType = desiredType
                // A number pad has no Return key, so give it a "Done" accessory
                // bar that submits the same way Return would.
                self.inputTextField.inputAccessoryView = numeric ? self.makeKeyboardDoneBar() : nil
                if self.inputTextField.isFirstResponder {
                    self.inputTextField.reloadInputViews()
                }
            }
            // When a hardware keyboard is attached, skip the software keyboard
            // entirely — pressesBegan delivers keystrokes to the Brogue queue
            // via the responder chain, and the physical Escape key cancels, so
            // no on-screen ESC button is shown (refreshEscButtonVisibility keeps
            // it hidden while a keyboard is present).
            if GCKeyboard.coalesced != nil {
                self.escButtonWanted = true
                self.refreshEscButtonVisibility()
            } else {
                self.inputTextField.becomeFirstResponder()
            }
        }
    }

    /// Toolbar shown above the number pad (which has no Return key) with a single
    /// "Done" button that submits the entry exactly like pressing Return.
    private func makeKeyboardDoneBar() -> UIToolbar {
        let bar = UIToolbar()
        bar.sizeToFit()
        bar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(keyboardDonePressed))
        ]
        return bar
    }

    @objc private func keyboardDonePressed() {
        _ = textFieldShouldReturn(inputTextField)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        inputTextField.resignFirstResponder()
        addKeyEvent(event: kReturnKey)
        escButtonWanted = false
        refreshEscButtonVisibility()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        inputTextField.text = inputRequestString ?? ""
        escButtonWanted = true
        refreshEscButtonVisibility()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string.isEmpty {
            // Backspace
            addKeyEvent(event: kDeleteKey)
        } else if let scalar = string.unicodeScalars.first, scalar.isASCII {
            addKeyEvent(event: UInt8(scalar.value))
        }
        return true
    }
}

// MARK: - Hardware keyboard

extension BrogueViewController {
    func setupHardwareKeyboardObserver() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardDidConnect),
                           name: .GCKeyboardDidConnect, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidDisconnect),
                           name: .GCKeyboardDidDisconnect, object: nil)
        // Set initial state in case a keyboard is already connected at launch.
        updateHardwareKeyboardState(GCKeyboard.coalesced != nil)
    }

    @objc private func keyboardDidConnect(_ note: Notification) {
        updateHardwareKeyboardState(true)
    }

    @objc private func keyboardDidDisconnect(_ note: Notification) {
        updateHardwareKeyboardState(GCKeyboard.coalesced != nil)
    }

    // A hardware keyboard now changes two things (the on-screen hotkey labels themselves stay OFF in
    // every engine — they reflect the Classic layout and would mismatch the Modern default, so we
    // deliberately never re-enable KEYBOARD_LABELS): (1) the on-screen d-pad is redundant, so hide it;
    // (2) the engines surface a "Press <?> for help" hint in the message log — the only help affordance
    // left with the labels (and their help button) disabled. We report presence to every engine via
    // its own image's hook (Classic's setHardwareKeyboardConnected(); CE/SE's
    // ce_/se_setHardwareKeyboardConnected()) so the setting is correct whichever engine is active.
    private func updateHardwareKeyboardState(_ connected: Bool) {
        // iOS port (iBrogue): a Mac always has a keyboard, and GameController's GCKeyboard discovery can
        // lag app launch — long enough that the engine's one-time welcome() can print before the flag
        // flips, dropping the "Press <?> for help" hint and briefly showing the d-pad on Mac. Force the
        // flag true under Catalyst so desktop mode (hidden d-pad/ESC + the help hint) is correct from the
        // first frame, independent of GCKeyboard timing. iOS/iPadOS keep the real connect/disconnect state.
        #if targetEnvironment(macCatalyst)
        let isConnected = true
        #else
        let isConnected = connected
        #endif
        hardwareKeyboardConnected = isConnected
        classic_setHardwareKeyboardConnected(isConnected ? 1 : 0)
        ce_setHardwareKeyboardConnected(isConnected ? 1 : 0)
        se_setHardwareKeyboardConnected(isConnected ? 1 : 0)
        DispatchQueue.main.async { [weak self] in
            self?.refreshDirectionPadVisibility()
            self?.refreshEscButtonVisibility()
            // Drop any touch loupe still on screen when a keyboard is plugged in
            // mid-play — canShowMagnifier now refuses to re-show it.
            if isConnected { self?.hideMagnifier() }
        }
    }

    /// Applies the d-pad's visibility from gameplay state AND hardware-keyboard presence: the d-pad
    /// shows only during normal play AND when no hardware keyboard is attached. Safe to call from the
    /// two gameplay-state sites and from the keyboard observer.
    func refreshDirectionPadVisibility() {
        let show = gameplayControlsActive && !hardwareKeyboardConnected
        dContainerView.isHidden = !show
        dContainerView.isUserInteractionEnabled = show
    }

    /// Applies the ESC button's visibility from app state (escButtonWanted) AND hardware-keyboard
    /// presence: shown only when wanted AND no hardware keyboard is attached (the physical Escape key
    /// covers it otherwise). macOS (Catalyst), not yet a supported target, should likewise be treated
    /// as always keyboard-present — GCKeyboard reports the Mac's keyboard, so this same path applies.
    func refreshEscButtonVisibility() {
        escButton?.isHidden = !(escButtonWanted && !hardwareKeyboardConnected)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handledAny = false
        var repeatCandidate: QueuedKeyEvent?
        for press in presses {
            if let k = brogueKey(for: press) {
                let ev = QueuedKeyEvent(code: k.code, shift: k.shift, control: k.control, raw: k.raw)
                addKeyEvent(code: ev.code, shift: ev.shift, control: ev.control, raw: ev.raw)
                handledAny = true
                if isRepeatable(ev) { repeatCandidate = ev }
            }
        }
        // A new repeat-eligible key starts (and replaces) the repeat; any other handled key cancels it.
        if let ev = repeatCandidate {
            startKeyRepeat(ev)
        } else if handledAny {
            stopKeyRepeat()
        }
        if !handledAny {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endRepeatIfReleased(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endRepeatIfReleased(presses)
        super.pressesCancelled(presses, with: event)
    }

    // Stop the repeat once the key driving it is released. (Only one key repeats at a time, so we just
    // match the released key against the active one.)
    private func endRepeatIfReleased(_ presses: Set<UIPress>) {
        guard let active = repeatingKey else { return }
        for press in presses where brogueKey(for: press)?.code == active.code {
            stopKeyRepeat()
            return
        }
    }

    // iOS port (iBrogue): only directions, rest (`z`), and search (`s`) auto-repeat -- the "safe to spam"
    // keys, matching desktop intent. Commands (apply/drop/quaff/stairs/menu/…) never repeat. Running
    // (Shift/Ctrl) and the long-search / rest-until forms already loop in the engine, so a modified key
    // is never a repeat candidate. The movement-letter set is scheme-dependent, so we read the active
    // scheme from the shared "keyboard scheme" default (kept current by applyKeyboardScheme's persistence);
    // the canonical mapping in applyKeyboardScheme (IO.c) is the source of truth this mirrors.
    private func isRepeatable(_ ev: QueuedKeyEvent) -> Bool {
        guard !ev.shift, !ev.control else { return false }
        if !ev.raw {
            // Synthesized canonical keys: only the four arrow keys (delivered as vi letters) repeat;
            // ESC/return/delete/tab/space do not.
            return [UInt8(ascii: "h"), UInt8(ascii: "j"), UInt8(ascii: "k"), UInt8(ascii: "l")].contains(ev.code)
        }
        // Real hardware character keys: rest and search are the same physical key in both schemes.
        if ev.code == UInt8(ascii: "z") || ev.code == UInt8(ascii: "s") { return true }
        // Default Modern when no preference is stored, matching the bridge loaders' iOS/macOS default.
        let schemeDefaults = UserDefaults.standard
        let isModern = schemeDefaults.object(forKey: "keyboard scheme") == nil
                       || schemeDefaults.integer(forKey: "keyboard scheme") == 1 // KEYBOARD_SCHEME_MODERN
        let movementKeys: Set<UInt8> = isModern ? Set("uiojklm,.".utf8)   // right-hand grid
                                                 : Set("hjklyubn".utf8)   // classic vi keys
        return movementKeys.contains(ev.code)
    }

    private func startKeyRepeat(_ ev: QueuedKeyEvent) {
        stopKeyRepeat()
        repeatingKey = ev
        // Initial delay, then steady repeats. Each tick only enqueues when the queue has drained, so a
        // slow frame (animations/between-turns) can't build a backlog that floods moves after release.
        let timer = Timer(timeInterval: keyRepeatInitialDelay, repeats: false) { [weak self] _ in
            self?.fireKeyRepeat(initial: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        keyRepeatTimer = timer
    }

    private func fireKeyRepeat(initial: Bool) {
        guard let ev = repeatingKey else { return }
        if !hasKeyEvent() {
            addKeyEvent(code: ev.code, shift: ev.shift, control: ev.control, raw: ev.raw)
        }
        if initial {
            let timer = Timer(timeInterval: keyRepeatInterval, repeats: true) { [weak self] _ in
                self?.fireKeyRepeat(initial: false)
            }
            RunLoop.main.add(timer, forMode: .common)
            keyRepeatTimer = timer
        }
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        repeatingKey = nil
    }

    /// Maps a UIPress to the key code Brogue's input loop expects, plus its modifier state and whether
    /// it is eligible for keyboard-scheme remapping (`raw`).
    ///
    /// Special/canonical keys (ESC, return, delete, tab, space) and arrow keys are NOT remapped
    /// (`raw: false`): arrows send canonical lowercase movement letters so they mean the same direction
    /// in every scheme, with Shift/Ctrl riding along via the modifier flags to trigger running. Real
    /// printable character keys are `raw: true` so the active scheme can remap them in the bridge.
    private func brogueKey(for press: UIPress) -> (code: UInt8, shift: Bool, control: Bool, raw: Bool)? {
        guard let key = press.key else { return nil }
        let mods = key.modifierFlags
        let shift = mods.contains(.shift)
        let control = mods.contains(.control)

        switch key.keyCode {
        case .keyboardEscape:            return (kESC_Key, shift, control, false)
        case .keyboardReturnOrEnter:     return (kReturnKey, shift, control, false)
        case .keyboardDeleteOrBackspace: return (kDeleteKey, shift, control, false)
        case .keyboardTab:               return (kTabKey, shift, control, false)
        case .keyboardUpArrow:           return (UInt8(ascii: "k"), shift, control, false)
        case .keyboardDownArrow:         return (UInt8(ascii: "j"), shift, control, false)
        case .keyboardLeftArrow:         return (UInt8(ascii: "h"), shift, control, false)
        case .keyboardRightArrow:        return (UInt8(ascii: "l"), shift, control, false)
        case .keyboardSpacebar:          return (UInt8(ascii: " "), shift, control, false)
        default:
            break
        }

        // A real printable character key — eligible for keyboard-scheme remapping. `characters`
        // reflects shift (so "k" vs "K" arrives correctly); the scheme + run logic uses the flags.
        if let scalar = key.characters.unicodeScalars.first, scalar.isASCII {
            return (UInt8(scalar.value), shift, control, true)
        }
        return nil
    }
}
