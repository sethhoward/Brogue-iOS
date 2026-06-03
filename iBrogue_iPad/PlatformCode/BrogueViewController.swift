 //
//  BrogueViewController.swift
//  iBrogue_iPad
//
//  This file is part of Brogue.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Affero General Public License as
//  published by the Free Software Foundation, either version 3 of the
//  License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Affero General Public License for more details.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import SpriteKit
import GameController

fileprivate let kESC_Key: UInt8 = 27
fileprivate let kReturnKey: UInt8 = 13
fileprivate let kEnterKey: UInt8 = 10
fileprivate let kDeleteKey: UInt8 = 127
fileprivate let kTabKey: UInt8 = 9

private let eventLock = NSLock()

private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
    eventLock.lock()
    defer { eventLock.unlock() }
    return try body()
}

fileprivate let COLS = 100
fileprivate let ROWS = 34

// ─────────────────────────────────────────────────────────────────────────
// Front-display cutout classification.
//
// iOS exposes NO public API for "is this a notch or a Dynamic Island."
// safeAreaInsets can tell you a cutout EXISTS, but the notch and island
// top/side insets overlap too much to distinguish reliably. The only
// dependable signal is the hardware model identifier matched against the
// known Dynamic Island roster.
// ─────────────────────────────────────────────────────────────────────────
enum DisplayCutout {
    case none
    case notch
    case dynamicIsland
}

extension UIDevice {
    /// Raw hardware model id, e.g. "iPhone16,1". On the simulator `uname`
    /// returns the host arch, so we read the env var Apple injects instead.
    var modelIdentifier: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown"
        #else
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        #endif
    }

    /// Every iPhone shipped with a Dynamic Island. MUST be extended as Apple
    /// releases new models — an island device missing from this set degrades
    /// gracefully to `.notch` (it still reserves cutout space, just labeled
    /// wrong). Note iPhone 16e (iPhone17,5) has a NOTCH, not an island, and is
    /// deliberately absent.
    var hasDynamicIsland: Bool {
        let islandModels: Set<String> = [
            "iPhone15,2", "iPhone15,3",   // 14 Pro / 14 Pro Max
            "iPhone15,4", "iPhone15,5",   // 15 / 15 Plus
            "iPhone16,1", "iPhone16,2",   // 15 Pro / 15 Pro Max
            "iPhone17,3", "iPhone17,4",   // 16 / 16 Plus
            "iPhone17,1", "iPhone17,2",   // 16 Pro / 16 Pro Max
        ]
        return islandModels.contains(modelIdentifier)
    }
}

fileprivate func getCellCoords(at point: CGPoint, viewport: SKViewPort?) -> CGPoint {
    let screenH = UIScreen.main.bounds.size.height
    let screenW = UIScreen.main.bounds.size.width
    let effectiveHeight = viewport?.effectiveHeightPoints ?? screenH
    let effectiveWidth = viewport?.effectiveWidthPoints ?? screenW
    let leftInset = viewport?.leftInsetPoints ?? 0
    let xInPlay = max(point.x - leftInset, 0)
    let cellx = Int(CGFloat(COLS) * xInPlay / effectiveWidth)
    let celly = Int(CGFloat(ROWS) * point.y / effectiveHeight)

    return CGPoint(x: cellx, y: celly)
}

// TODO: switch to Character
extension String {
    var ascii: UInt8 {
        return (unicodeScalars.map { UInt8($0.value) }).first!
    }
}

// MARK: - UIBrogueTouchEvent

@objc class UIBrogueTouchEvent: NSObject, NSCopying {
    @objc let phase: UITouch.Phase
    @objc let location: CGPoint
    
    required init(phase: UITouch.Phase, location: CGPoint) {
        self.phase = phase
        self.location = location
    }
    
    required init(touchEvent: UIBrogueTouchEvent) {
        phase = touchEvent.phase
        location = touchEvent.location
    }
    
    func copy(with zone: NSZone? = nil) -> Any {
        return type(of:self).init(touchEvent: self)
    }
}

// MARK: - BrogueGameEvent

extension BrogueGameEvent {
    var canShowMagnifyingGlass: Bool {
        switch self {
        case .startNewGame, .inventoryItemAction, .confirmationComplete, .actionMenuClose, .closedInventory, .openGame:
            return true
        default:
            return false
        }
    }
}

// MARK: - BrogueViewController

final class BrogueViewController: UIViewController {
    fileprivate var touchEvents = [UIBrogueTouchEvent]()
    fileprivate var lastTouchLocation = CGPoint()
    @objc fileprivate var directionsViewController: DirectionControlsViewController?
    fileprivate var keyEvents = [UInt8]()
    fileprivate var magnifierTimer: Timer?
    fileprivate var inputRequestString: String?

    // ── Safe-area action buttons ─────────────────────────────────────────
    // A small column of buttons that live in the iPhone notch / dynamic-island
    // safe-area strip (the right edge in our landscape-left lock). Each injects
    // a Brogue keystroke. Hardcoded for now; swap `actionButtonSpecs` for a
    // UserDefaults-loaded list to make these user-configurable later.
    private struct ActionButtonSpec {
        let label: String   // glyph shown on the button
        let key: UInt8      // Brogue keystroke injected on tap
    }

    private let actionButtonSpecs: [ActionButtonSpec] = [
        ActionButtonSpec(label: "A", key: "A".ascii),   // autoplay level
        ActionButtonSpec(label: "X", key: "x".ascii),   // autoexplore
        ActionButtonSpec(label: "S", key: "s".ascii),   // search for secrets
        ActionButtonSpec(label: "R", key: "Z".ascii),   // rest until better
    ]

    private var actionButtons: [UIButton] = []

    /// Tactile feedback when an action button is tapped.
    private let actionButtonHaptics = UIImpactFeedbackGenerator(style: .light)

    /// Mirrors the directional pad's visibility: true while the player is
    /// actively moving around the dungeon, false on menus/dialogs/title.
    private var gameplayControlsActive = false

    @IBOutlet var skViewPort: SKViewPort!
    @IBOutlet fileprivate weak var magView: SKMagView!
    @IBOutlet fileprivate weak var escButton: UIButton! {
        didSet {
            escButton.isHidden = true
        }
    }
    @IBOutlet fileprivate weak var inputTextField: UITextField!
    @IBOutlet fileprivate weak var showInventoryButton: UIButton!
    @IBOutlet fileprivate weak var leaderBoardButton: UIButton!
    @IBOutlet fileprivate weak var seedButton: UIButton!
   
    @IBOutlet weak var dContainerView: UIView!
    @objc var seedKeyDown = false
    @objc var lastBrogueGameEvent: BrogueGameEvent = .showTitle {
        didSet {
            DispatchQueue.main.async {
                switch self.lastBrogueGameEvent {
                case .keyBoardInputRequired:
                    self.inputTextField.becomeFirstResponder()
                case .showTitle, .openGameFinished:
                    self.inputTextField.resignFirstResponder()
                    self.showInventoryButton.isHidden = true
                    self.leaderBoardButton.isHidden = false
                    self.seedButton.isHidden = false
                    self.escButton.isHidden = true
                case .startNewGame, .openGame, .beginOpenGame:
                    self.leaderBoardButton.isHidden = true
                    self.seedButton.isHidden = true
                    self.seedKeyDown = false
                case .messagePlayerHasDied:
                    self.showInventoryButton.isHidden = false
                case .playerHasDiedMessageAcknowledged:
                    self.showInventoryButton.isHidden = true
                default: ()
                }
                
                // Hide/Show the directions.
                switch self.lastBrogueGameEvent {
                case .waitingForConfirmation, .actionMenuOpen, .openedInventory, .showTitle, .openGameFinished, .playRecording, .showHighScores, .playBackPanic, .messagePlayerHasDied, .playerHasDiedMessageAcknowledged, .keyBoardInputRequired, .beginOpenGame:
                    self.dContainerView.isHidden = true
                    self.dContainerView.isUserInteractionEnabled = false
                    self.gameplayControlsActive = false
                default:
                    self.dContainerView.isHidden = false
                    self.dContainerView.isUserInteractionEnabled = true
                    self.gameplayControlsActive = true
                }
                self.updateActionButtonVisibility()

                // Reserve the home-indicator strip only during gameplay. On the title
                // and other menu screens, let the grid fill the full screen.
                switch self.lastBrogueGameEvent {
                case .showTitle, .openGameFinished, .beginOpenGame, .showHighScores:
                    self.skViewPort.rogueScene.paddingEnabled = false
                default:
                    self.skViewPort.rogueScene.paddingEnabled = true
                }
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // TODO: clean this up
        RogueDriver.sharedInstance(with: skViewPort, viewController: self)

        // Opt the C engine into iPhone-only layout tweaks (e.g. the taller
        // tap area for the bottom button bar). iPad keeps default behavior.
        setPhoneLayout(UIDevice.current.userInterfaceIdiom == .phone ? 1 : 0)

        let thread = Thread(target: self, selector: #selector(BrogueViewController.playBrogue), object: nil)
        thread.stackSize = 400 * 8192
        thread.start()

        magView.viewToMagnify = skViewPort
        magView.hideMagnifier()
        inputTextField.delegate = self

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(draggedView(_:)))
        panGesture.minimumNumberOfTouches = 2
        dContainerView.addGestureRecognizer(panGesture)
        dContainerView.alpha = 0.3

        // Storyboard positions these for iPad. On iPhone (much less screen
        // real estate, landscape-only) push them tighter into the edges.
        // Applied once as a transform so auto-layout passes don't fight us,
        // and so any user-drag gesture on dContainerView (which modifies
        // .center) keeps working on top.
        // Tune these constants to taste.
        if UIDevice.current.userInterfaceIdiom == .phone {
            dContainerView.transform = CGAffineTransform(translationX: -80, y: 100)
            escButton.transform = CGAffineTransform(translationX: -80, y: 90)
        }

        GameCenter.shared.authenticate(from: self)

        setupHardwareKeyboardObserver()
        setupActionButtons()
    }

    // ─────────────────────────────────────────────────────────────────────
    // System-UI overrides are intentionally absent here. Do NOT add:
    //
    //   prefersHomeIndicatorAutoHidden
    //   preferredScreenEdgesDeferringSystemGestures
    //   childForHomeIndicatorAutoHidden
    //   childForScreenEdgesDeferringSystemGestures
    //   prefersStatusBarHidden
    //
    // The window's rootViewController is a UIHostingController(ContentView),
    // and SwiftUI's `.defersSystemGestures(on: .bottom)` and
    // `.statusBarHidden(true)` modifiers on ContentView are the sole source
    // of truth. When this VC declares its own overrides, UIHostingController
    // consults this child via its childFor… resolution, the child values
    // collide with the SwiftUI-driven values on the host, and iPadOS stops
    // honoring gesture deferral entirely (verified by bisection). The
    // indicator goes back to single-swipe-to-exit.
    //
    // See ContentView.swift's header for the full story.
    // ─────────────────────────────────────────────────────────────────────

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }

    // Plumb iPhone notch / dynamic-island safe-area insets into RogueScene so
    // the cell grid (and its touch math) avoid the notched zones.
    //
    // We read from `view.window?.safeAreaInsets`, not `view.safeAreaInsets`.
    // SwiftUI's `.ignoresSafeArea()` on the hosting ContentView zeros out the
    // hosted view's insets but the underlying window still reports the true
    // device insets. Reading from the window gives us reality.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyNotchInsets()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // view.window only becomes non-nil once the view is in the hierarchy.
        // Run after viewDidAppear so we definitely have it.
        applyNotchInsets()
    }

    /// Best-available safe-area insets. SwiftUI's `.ignoresSafeArea()` zeroes
    /// the hosted view's insets, so we prefer the window's. If our own window
    /// isn't attached yet, fall back to any foreground window scene's key
    /// window so we never read a falsely-zeroed inset during early layout.
    private var bestSafeAreaInsets: UIEdgeInsets {
        if let window = view.window { return window.safeAreaInsets }
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
        return keyWindow?.safeAreaInsets ?? view.safeAreaInsets
    }

    /// Classifies the current device's front cutout. `.dynamicIsland` is
    /// model-driven (the only reliable signal); `.notch` vs `.none` is decided
    /// by whether a real safe-area inset exists. We're landscape-locked, so a
    /// cutout shows up as a left/right inset rather than a top one. `.none`
    /// covers the home-button iPhone SE models and every iPad (no iPad has a
    /// cutout).
    private func currentDisplayCutout(insets: UIEdgeInsets) -> DisplayCutout {
        if UIDevice.current.hasDynamicIsland { return .dynamicIsland }
        let sideInset = max(insets.left, insets.right)
        return sideInset > 20 ? .notch : .none
    }

    private func applyNotchInsets() {
        let insets = bestSafeAreaInsets
        let scale = UIScreen.main.scale

        // Position the safe-area action buttons in the (now-known) cutout strip
        // and show/hide them for this device + game state.
        layoutActionButtons(insets: insets)
        updateActionButtonVisibility()

        // The app is locked to UIInterfaceOrientation.landscapeLeft in
        // Info.plist. In that orientation the iPhone's notch / dynamic island
        // sits along the RIGHT edge of the screen. iOS reports symmetric
        // safe-area insets on both sides (~62pt each, including the bezel
        // safe area on the non-notch side), but we only want to reserve
        // space on the actual-notch side.
        //
        // We then slide the whole grid right by `gridRightShift`: inset the
        // left edge by that amount and reduce the right (notch) reservation by
        // the same amount, so the grid keeps its width and pushes that far into
        // the right safe area.
        let shift = SKViewPort.gridRightShift
        skViewPort.rogueScene.setHorizontalEdgeInsets(
            leftPixels: shift * scale,
            rightPixels: max(insets.right - shift, 0) * scale
        )
    }
    
    // ── Safe-area action buttons ─────────────────────────────────────────

    private static let actionButtonSize: CGFloat = 44
    private static let actionButtonGap: CGFloat = 8
    private static let actionButtonEdgeMargin: CGFloat = 4
    /// Extra downward nudge for the TOP button pair (A/X) below the top inset.
    /// Tweak to taste.
    private static let actionButtonTopOffset: CGFloat = 20
    /// On NOTCH devices only, push the pairs away from center — top pair up,
    /// bottom pair down — by this much (the notch's clear zones differ from the
    /// island's). Tweak to taste.
    private static let actionButtonNotchCenterPush: CGFloat = 12

    /// Builds the buttons once and adds them above the SKView. They stay hidden
    /// until `applyNotchInsets` positions them and `updateActionButtonVisibility`
    /// reveals them for cutout devices during gameplay.
    private func setupActionButtons() {
        actionButtons = actionButtonSpecs.map { spec in
            let button = UIButton(type: .custom)
            button.setTitle(spec.label, for: .normal)
            // Soft off-white to echo Brogue's menu text rather than a stark #FFF
            // (a crisp system font at pure white reads much harsher than the
            // game's anti-aliased bitmap font does).
            button.setTitleColor(UIColor(white: 0.9, alpha: 1.0), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
            button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            button.layer.cornerRadius = 8
            // Translucent gray border — Brogue's `gray` is {50,50,50} ≈ 0.5 white.
            button.layer.borderColor = UIColor(white: 0.5, alpha: 0.6).cgColor
            button.layer.borderWidth = 1
            // Stash the keystroke in the tag so one handler serves every button.
            button.tag = Int(spec.key)
            button.addTarget(self, action: #selector(actionButtonTapped(_:)), for: .touchUpInside)
            button.isHidden = true
            view.addSubview(button)
            return button
        }
    }

    @objc private func actionButtonTapped(_ sender: UIButton) {
        actionButtonHaptics.impactOccurred()
        addKeyEvent(event: UInt8(sender.tag))
    }

    /// Lays the buttons out along the trailing (cutout) edge: the first half of
    /// the list anchored to the top safe inset stacking down, the second half
    /// anchored to the bottom stacking up. The island/notch occupies the center
    /// of the edge, so leaving the middle empty dodges it without needing its
    /// (unavailable) exact rect.
    private func layoutActionButtons(insets: UIEdgeInsets) {
        guard !actionButtons.isEmpty else { return }

        let size = Self.actionButtonSize
        let gap = Self.actionButtonGap
        let margin = Self.actionButtonEdgeMargin
        let bounds = view.bounds

        // Flush to the trailing edge, a hair in from the rounded corner.
        let x = bounds.maxX - size - margin

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
    private func updateActionButtonVisibility() {
        let hasStrip = currentDisplayCutout(insets: bestSafeAreaInsets) != .none
        let visible = hasStrip && gameplayControlsActive
        for button in actionButtons {
            button.isHidden = !visible
            button.isUserInteractionEnabled = visible
        }
        // Warm up the haptic engine so the first tap fires without latency.
        if visible {
            actionButtonHaptics.prepare()
        }
    }

    @objc func handleDirectionTouch(_ sender: UIPanGestureRecognizer) {
        directionsViewController?.cancel()
    }
    
    @objc func draggedView(_ sender: UIPanGestureRecognizer) {

        directionsViewController?.cancel()
        let translation = sender.translation(in: view)
        dContainerView.center = CGPoint(x: dContainerView.center.x + translation.x, y: dContainerView.center.y + translation.y)
        sender.setTranslation(CGPoint.zero, in: view)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.destination is DirectionControlsViewController {
            directionsViewController = segue.destination as? DirectionControlsViewController
            addObserver(self, forKeyPath: #keyPath(directionsViewController.directionalButton), options: [.new], context: nil)
        }
    }
    
    @objc private func playBrogue() {
        rogueMain()
    }
}
 
extension BrogueViewController {
    @IBAction func escButtonPressed(_ sender: Any) {
        addKeyEvent(event: kESC_Key)
        inputTextField.resignFirstResponder()
        escButton.isHidden = true
    }
    
    @IBAction func showInventoryButtonPressed(_ sender: Any) {
        addKeyEvent(event: "i".ascii)
    }
    
    @IBAction func showLeaderBoardButtonPressed(_ sender: Any) {
        NSLog("[GameCenter] leaderboard button pressed")
        GameCenter.shared.showLeaderboard(id: GameCenter.highScoreLeaderboardID, from: self)
    }
    
    @IBAction func seedButtonPressed(_ sender: Any) {
        seedKeyDown = !seedKeyDown
        
        if seedKeyDown {
            let image = UIImage(named: "brogue_sproutedseed.png")
            seedButton.setImage(image, for: .normal)
        } else {
            let image = UIImage(named: "brogue_seed.png")
            seedButton.setImage(image, for: .normal)
        }
    }
}

extension BrogueViewController {
    override func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        addKeyEvent(event: kESC_Key)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        
        guard dContainerView.hitTest(touches.first!.location(in: dContainerView), with: event) == nil else { return }
        
        for touch in touches {
            let location = touch.location(in: view)
            // handle double tap on began.
            if touch.tapCount >= 2 && pointIsInPlayArea(point: location) {
                // double tap in the play area
                addTouchEvent(event: UIBrogueTouchEvent(phase: .stationary, location: lastTouchLocation))
                addTouchEvent(event: UIBrogueTouchEvent(phase: .moved, location: lastTouchLocation))
                addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
            }
            else {
                let brogueEvent = UIBrogueTouchEvent(phase: touch.phase, location: location)
                addTouchEvent(event: brogueEvent)
                showMagnifier(at: location)
            }
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        
        guard dContainerView.hitTest(touches.first!.location(in: dContainerView), with: event) == nil else { return }
        
        if let touch = touches.first {
            let location = touch.location(in: view)
            let brogueEvent = UIBrogueTouchEvent(phase: touch.phase, location: location)

            addTouchEvent(event: brogueEvent)
            showMagnifier(at: location)
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        
        guard dContainerView.hitTest(touches.first!.location(in: dContainerView), with: event) == nil else { return }
        
        if let touch = touches.first {
            let location = touch.location(in: view)
            
            if pointIsInSideBar(point: location) {
                // side bar
                if touch.tapCount >= 2 {
                    addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
                } else {
                    addTouchEvent(event: UIBrogueTouchEvent(phase: .moved, location: location))
                }
            } else {
                // other touch
                addTouchEvent(event: UIBrogueTouchEvent(phase: .stationary, location: lastTouchLocation))
                addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
            }
        }
        
        hideMagnifier()
    }
    
    fileprivate func pointIsInPlayArea(point: CGPoint) -> Bool {
        let cellCoord = getCellCoords(at: point, viewport: skViewPort)
        if cellCoord.x > 20 && cellCoord.y < 32 && cellCoord.y > 3 {
            return true
        }

        return false
    }

    private func pointIsInSideBar(point: CGPoint) -> Bool {
        let cellCoord = getCellCoords(at: point, viewport: skViewPort)
        if cellCoord.x <= 20 {
            return true
        }

        return false
    }
    
    private func addTouchEvent(event: UIBrogueTouchEvent) {
        lastTouchLocation = event.location
        synchronized {
            // only want the last moved event, no point caching them all
            if let lastEvent = touchEvents.last, lastEvent.phase == .moved, !touchEvents.isEmpty {
                _ = touchEvents.removeLast()
            }

            touchEvents.append(event)
        }
    }

    private func clearTouchEvents() {
        synchronized {
            touchEvents.removeAll()
        }
    }

    @objc func dequeTouchEvent() -> UIBrogueTouchEvent? {
        synchronized {
            guard !touchEvents.isEmpty else { return nil }
            let event = touchEvents.removeFirst()
            return event.copy() as? UIBrogueTouchEvent
        }
    }

    @objc func hasTouchEvent() -> Bool {
        synchronized { !touchEvents.isEmpty }
    }
}

extension BrogueViewController {
    @objc private func handleMagnifierTimer() {
        if canShowMagnifier(at: lastTouchLocation) {
            magView.showMagnifier(at: lastTouchLocation)
        }
    }
    
    private func canShowMagnifier(at point: CGPoint) -> Bool {
        guard lastBrogueGameEvent.canShowMagnifyingGlass, pointIsInPlayArea(point: point) else {
            return false
        }
        // iPhone: the bottom dungeon row (window row 31) doubles as the bottom
        // button bar's extended 3-cell tap area (see B_TALL_CLICK_AREA in
        // BrogueCode/IOS_MODIFICATIONS.md). Suppress the magnifier there so it
        // doesn't pop up over the map when the player is aiming for a button.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let cell = getCellCoords(at: point, viewport: skViewPort)
            if cell.y >= 31 {
                return false
            }
        }
        return true
    }
    
    fileprivate func showMagnifier(at point: CGPoint) {
        guard canShowMagnifier(at: point) else {
            magView.hideMagnifier()
            return
        }
        
        if magView.isHidden {
            magnifierTimer?.invalidate()
            magnifierTimer = nil
            magnifierTimer = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(BrogueViewController.handleMagnifierTimer), userInfo: nil, repeats: false)
            // Need to go iOS 10
            //            magnifierTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            //                self.magView.showMagnifier(at: self.lastTouchLocation)
            //            }
        } else {
            magView.updateMagnifier(at: point)
        }
    }
    
    fileprivate func hideMagnifier() {
        magnifierTimer?.invalidate()
        magnifierTimer = nil
        DispatchQueue.main.async {
            self.magView.hideMagnifier()
        }
    }
}

extension BrogueViewController {
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(directionsViewController.directionalButton) else { return }

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
    
    fileprivate func addKeyEvent(event: UInt8) {
        synchronized {
            keyEvents.append(event)
        }
    }

    // cannot be optional for backward compat
    @objc func dequeKeyEvent() -> UInt8 {
        synchronized {
            guard !keyEvents.isEmpty else {
                fatalError("Deque Key, queue is empty")
            }
            return keyEvents.removeFirst()
        }
    }

    @objc func hasKeyEvent() -> Bool {
        synchronized { !keyEvents.isEmpty }
    }
}

extension BrogueViewController: UITextFieldDelegate {
    @objc func requestTextInput(for string: String) {
        inputRequestString = string
        DispatchQueue.main.async {
            // When a hardware keyboard is attached, skip the software keyboard
            // entirely — pressesBegan delivers keystrokes to the Brogue queue
            // via the responder chain. Just expose the Esc button so the user
            // has a touch-friendly cancel.
            if GCKeyboard.coalesced != nil {
                self.escButton.isHidden = false
            } else {
                self.inputTextField.becomeFirstResponder()
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        inputTextField.resignFirstResponder()
        addKeyEvent(event: kReturnKey)
        escButton.isHidden = true
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        inputTextField.text = inputRequestString ?? ""
        escButton.isHidden = false
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
    fileprivate func setupHardwareKeyboardObserver() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardDidConnect),
                           name: .GCKeyboardDidConnect, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidDisconnect),
                           name: .GCKeyboardDidDisconnect, object: nil)
        // Set initial state in case a keyboard is already connected at launch.
        setKeyboardLabelsEnabled(GCKeyboard.coalesced != nil ? 1 : 0)
    }

    @objc private func keyboardDidConnect(_ note: Notification) {
        setKeyboardLabelsEnabled(1)
    }

    @objc private func keyboardDidDisconnect(_ note: Notification) {
        setKeyboardLabelsEnabled(GCKeyboard.coalesced != nil ? 1 : 0)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handledAny = false
        for press in presses {
            if let byte = brogueByte(for: press) {
                addKeyEvent(event: byte)
                handledAny = true
            }
        }
        if !handledAny {
            super.pressesBegan(presses, with: event)
        }
    }

    /// Maps a UIPress to the byte Brogue's input loop expects.
    /// Arrow keys map to vi-style hjkl since the event queue is byte-sized.
    private func brogueByte(for press: UIPress) -> UInt8? {
        guard let key = press.key else { return nil }

        switch key.keyCode {
        case .keyboardEscape:            return kESC_Key
        case .keyboardReturnOrEnter:     return kReturnKey
        case .keyboardDeleteOrBackspace: return kDeleteKey
        case .keyboardTab:               return kTabKey
        case .keyboardUpArrow:           return UInt8(ascii: "K")
        case .keyboardDownArrow:         return UInt8(ascii: "J")
        case .keyboardLeftArrow:         return UInt8(ascii: "H")
        case .keyboardRightArrow:        return UInt8(ascii: "L")
        case .keyboardSpacebar:          return UInt8(ascii: " ")
        default:
            break
        }

        // Fall back to the printable characters the user actually typed.
        // `characters` reflects modifiers (shift, etc.) so "k" vs "K" arrives correctly.
        if let scalar = key.characters.unicodeScalars.first, scalar.isASCII {
            return UInt8(scalar.value)
        }
        return nil
    }
}

// MARK: - SKMagView

final class SKMagView: SKView {
    var viewToMagnify: SKViewPort?

    // Half-extents (cells out from the center) of the magnified block.
    // `xHalf` is the horizontal axis (2*xHalf+1 cells wide), `yHalf` the
    // vertical (2*yHalf+1 cells tall). The centering math in cellsAtTouch
    // assumes xHalf == yHalf + 1, so preserve that relationship when tuning.
    private let xHalf = 4 // 9 cells wide
    private let yHalf = 3 // 7 cells tall

    // The window diameter/offset are recomputed per-layout in cellsAtTouch from
    // the live cell size and the half-extents above; these are just initial
    // values until the first layout runs.
    private var size = CGSize(width: 110, height: 110)
    private var offset = CGSize(width: 55, height: -35)
    private let parentNode: SKSpriteNode
    private var cells: [Cell]? {
        willSet {
            parentNode.removeAllChildren()
        }
        didSet {
            for cell in cells! {
                parentNode.addChild(cell.background)
                parentNode.addChild(cell.foreground)
            }
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        // parentNode used to default to cyan; that color shows through when the
        // magnified cells don't fully cover the magView (which can happen now
        // that cells are smaller due to safe-area insets). Black matches the
        // game's background so empty areas read as "no content here" instead
        // of a colored artifact.
        parentNode = SKSpriteNode(color: .black, size: size)
        super.init(coder: aDecoder)

        let styleWindow: () -> Void = {
            self.frame = CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height)
            self.layer.borderColor = UIColor(red: 1, green: 1, blue: 1, alpha: 0.4).cgColor
            self.layer.borderWidth = 3
            self.layer.cornerRadius = self.frame.size.width / 2
            self.layer.masksToBounds = true
            self.backgroundColor = .black
        }

        var scene: SKScene {
            let scene = SKScene(size: self.size)
            scene.scaleMode = .aspectFit
            scene.backgroundColor = .black // default SKScene bg is gray; we want black
            scene.addChild(self.parentNode)
            return scene
        }

        styleWindow()
        presentScene(scene)
    }
    
    func showMagnifier(at point: CGPoint) {
        cells = cellsAtTouch(point: point)
        center = positionedCenter(forTouch: point)
        isHidden = false
    }

    /// On iPad the magnifier hovers above the touch, flipping to the LEFT only
    /// when that would clip off the top. On iPhone it ALWAYS sits to the left
    /// of the finger — never above and never under it, so the finger never
    /// occludes the magnified content. Always clamped to the parent's safe area
    /// so it never sits under the iPhone notch / dynamic island or off the
    /// leading edge.
    private func positionedCenter(forTouch point: CGPoint) -> CGPoint {
        let radius = size.width / 2
        let parent = superview
        let viewBounds = parent?.bounds ?? UIScreen.main.bounds
        let insets = parent?.safeAreaInsets ?? .zero
        let bounds = CGRect(
            x: viewBounds.minX + insets.left,
            y: viewBounds.minY + insets.top,
            width: viewBounds.width - insets.left - insets.right,
            height: viewBounds.height - insets.top - insets.bottom
        )

        let isPhone = UIDevice.current.userInterfaceIdiom == .phone

        // Default placement: above the touch (offset.height is negative).
        var c = CGPoint(
            x: point.x + size.width / 2 - offset.width,
            y: point.y - size.height / 2 + offset.height
        )

        // iPhone: ALWAYS place to the left of the finger.
        // iPad: only flip left when the above-touch default would clip the top.
        // Either way the magnifier sits beside the finger, never under it.
        //
        // TWEAK ME: `leftFlipPadding` is the gap between the finger and the
        // magnifier's right edge when it sits to the left. Bigger = magnifier
        // sits further left of the finger.
        if isPhone || c.y - radius < bounds.minY {
            let leftFlipPadding: CGFloat = 38
            c.x = point.x - radius - leftFlipPadding
            c.y = point.y
        }

        // Clamp horizontally so it doesn't spill past either side or under
        // the notch. This is what enforces "can't go out of bounds toward
        // the left" — if the finger is too close to the leading edge for
        // the magnifier to fit beside it, we clamp it to the leading inset
        // (the magnifier will partially overlap the finger, which is
        // acceptable; staying visible is the priority).
        if c.x - radius < bounds.minX {
            c.x = bounds.minX + radius
        } else if c.x + radius > bounds.maxX {
            c.x = bounds.maxX - radius
        }

        // Final vertical clamp.
        if c.y - radius < bounds.minY {
            c.y = bounds.minY + radius
        } else if c.y + radius > bounds.maxY {
            c.y = bounds.maxY - radius
        }

        return c
    }
    
    func updateMagnifier(at point: CGPoint) {
        showMagnifier(at: point)
    }
    
    func hideMagnifier() {
        isHidden = true
        parentNode.removeAllChildren()
    }

    /// Resize the (circular) magnifier window to `diameter` points, keeping it a
    /// circle and re-centering the finger offset. The scene and backing sprite
    /// are kept in sync so the 1px→1pt rendering (and thus the zoom) is
    /// preserved. Cheap no-op when the diameter hasn't meaningfully changed.
    private func resizeWindow(toDiameter diameter: CGFloat) {
        guard diameter > 0, abs(diameter - size.width) > 0.5 else { return }
        size = CGSize(width: diameter, height: diameter)
        offset.width = diameter / 2            // keep the magnifier centered over the finger
        bounds = CGRect(origin: .zero, size: size)
        layer.cornerRadius = diameter / 2      // masksToBounds is already true → circle
        scene?.size = size
        parentNode.size = size
    }
    
    private func cellsAtTouch(point: CGPoint) -> [Cell] {
        guard let viewToMagnify = viewToMagnify else { return [Cell]() }
       
        let magnification: CGFloat = 1.0
        let currentCellXY = getCellCoords(at: point, viewport: viewToMagnify)
        // Local aliases for the block half-extents (see xHalf/yHalf). `rows` is
        // the x-axis, `cols` the y-axis — the names are flipped historically.
        let rows = xHalf
        let cols = yHalf
        
        let cells: [[Cell]] = {
            var cells = [[Cell]]()
            
            for x in -(rows)...rows {
                var row = [Cell]()
                for y in -(cols)...cols {
                    let indexX = Int(currentCellXY.x) + x
                    let indexY = Int(currentCellXY.y) + y
                    // don't try to draw anything out of bounds
                    if indexX < COLS && indexY < ROWS && indexX >= 0 && indexY >= 0 {
                        let newCell = MagCell(cell: viewToMagnify.rogueScene.cells[indexX][indexY], magnify: magnification)
                        row.append(newCell)
                    } else {
                        let cell = Cell(x: 0, y: 0, size: viewToMagnify.rogueScene.cells[0][0].size)
                        cell.bgcolor = .black
                        row.append(cell)
                    }
                }
                cells.append(row);
            }
            
            return cells
        }()
        
        let cellSize = cells[0][0].size

        // Size the circular window from the live cell size and the half-extents.
        // cellSize is in scene PIXELS, which the magnifier renders 1:1 as points,
        // so these products are in view points.
        //
        // Size to ONE FEWER cell than is built on each axis (2*n-1, not 2*n+1):
        // the outer ring of built cells is overflow that keeps the circle fully
        // covered as the content pans within a cell. Without it the backdrop
        // shows through at the trailing edge and the touched cell drifts
        // off-center. Taking the min of the two keeps it a circle with no black
        // margins on either axis.
        let visibleWidth = CGFloat(rows * 2 - 1) * cellSize.width
        let visibleHeight = CGFloat(cols * 2 - 1) * cellSize.height
        resizeWindow(toDiameter: min(visibleWidth, visibleHeight))

        // layout cells
        for x in 0...rows * 2 {
            for y in 0...cols * 2 {
                cells[x][y].position = CGPoint(x: (CGFloat(x) * cellSize.width), y: CGFloat(rows - y - 1) * cellSize.height)
            }
        }
        
        var position: CGPoint {
            let screenScale = UIScreen.main.scale
            // Cells are stored in scene PIXELS but the magView's SKScene is in
            // POINTS (110 logical units == 110 view points via aspectFit). That
            // means placing a cell of size W pixels inside the magView's scene
            // displays it W *points* wide — an effective zoom of `screenScale`.
            // The pan-tracking factor must match that implicit zoom, otherwise
            // the centered cell drifts off-center as the touch moves within
            // a cell. Originally hardcoded to `magnification + 1 == 2`, which
            // only happened to be correct on devices with @2x scale (iPad).
            // On @3x devices (iPhone Pro/Max) it was 33% off. Use screenScale.
            let magnificationOffset = screenScale

            // take the touch point and figure out how far off from 0,0 inside the node we are. Magical fudge of magoffset ensure we move smoothly from one cell to the next.
            // Subtract the grid's left inset: currentCellXY came from getCellCoords,
            // which measures from `point.x - leftInset`, so the cell's left edge in
            // view points is `leftInset + currentCellXY.x * cellPtW`. Omitting it
            // drifts the content left by leftInset*scale (an empty column on the
            // right). The y-axis has no matching inset, so it's left as-is.
            let leftInset = viewToMagnify.leftInsetPoints
            let xMouseOffset = (point.x - leftInset - (currentCellXY.x * (viewToMagnify.rogueScene.cells[0][0].size.width / screenScale))) * magnificationOffset
            let yMouseOffset = (point.y - (currentCellXY.y * (viewToMagnify.rogueScene.cells[0][0].size.height / screenScale))) * magnificationOffset
            
            // center cell is at index (rows, cols) and should be in the middle of the magnifying glass view. As touches move so does the view need to move to follow.
            let xFinalOffset = ((CGFloat(rows) * cellSize.width - self.size.width/2) + cellSize.width/2) + xMouseOffset
            let yFinalOffset = ((CGFloat(rows - cols - 1) * cellSize.height - self.size.height / 2) + cellSize.height / 2) - yMouseOffset
            
            return CGPoint(x: -xFinalOffset + cellSize.width / 2, y: -yFinalOffset - cellSize.height / 2)
        }
        
        // offset needs to be offset by the appropriate cellsize.
        parentNode.position = position
        
        return cells.flatMap { $0 }
    }
}
