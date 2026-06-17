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
import QuartzCore

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
    // When the dungeon map is pinch-zoomed, invert the zoom transform so a
    // touch resolves to the cell actually under the finger. No-op at 1× and
    // for points outside the zoomable map (sidebar, messages, button bar).
    let point = viewport?.unzoomedPoint(point) ?? point
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

/// Which engine is currently driving the shared rendering surface.
///
/// `.se` (Brogue SE) is a fork of the CE engine living in its own framework.
enum EngineKind {
    case classic, ce, se

    /// SE runs through the same CEHost bridge and presents the same in-engine UI as
    /// CE, so most "is this the CE engine?" UI checks should treat SE like CE. Only
    /// truly engine-specific things (Game Center, the ce_*/se_* entry points) branch
    /// on the exact case.
    var isCEFamily: Bool { self != .classic }
}

final class BrogueViewController: UIViewController {
    /// Retains the BrogueCE host adapter for the lifetime of the CE engine thread.
    private var ceHost: CEHost?
    /// The engine currently running on `engineThread`.
    private var currentEngine: EngineKind = .classic
    /// The background thread running the active engine's `rogueMain`.
    private var engineThread: Thread?
    /// Set while a title-screen engine swap is in flight (awaiting clean exit).
    private var switchPending = false
    /// The engine to boot once the outgoing one exits during a swap. Captured at
    /// request time so the 3-way cycle can move to a specific target (not just flip).
    private var pendingTargetEngine: EngineKind?
    /// The title-screen version-chooser chip and its label.
    private var versionChooser: UIView?
    private var versionChooserLabel: UILabel?
    /// Fades the chooser out after a few seconds so it isn't a persistent distraction.
    private var versionChooserFadeTimer: Timer?
    /// Title-screen options button (lower-left). Universal across Classic and CE.
    private var optionsButton: UIButton?
    /// Title-screen info button, beside the options button. Pops an engine-aware
    /// description of the selected engine's key features.
    private var infoButton: UIButton?
    /// True while the active engine is showing its title screen (chooser visible).
    private var atTitle = false { didSet { updateVersionChooserVisibility(); updateTitleOptionsVisibility() } }
    fileprivate var touchEvents = [UIBrogueTouchEvent]()
    fileprivate var lastTouchLocation = CGPoint()
    @objc fileprivate var directionsViewController: DirectionControlsViewController?
    // iOS port (iBrogue): a queued key carries its modifier state and a `raw` flag. `raw` is true only
    // for real hardware character keys that the active keyboard scheme should remap; synthesized input
    // (on-screen d-pad/buttons, ESC, text entry, arrows) is already canonical and passes through.
    fileprivate struct QueuedKeyEvent {
        let code: UInt8
        let shift: Bool
        let control: Bool
        let raw: Bool
    }
    fileprivate var keyEvents = [QueuedKeyEvent]()
    fileprivate var magnifierTimer: Timer?
    fileprivate var inputRequestString: String?

    // iOS port (iBrogue): hardware key-repeat. iOS `pressesBegan` fires once per physical press (unlike
    // desktop SDL, which repeats natively), so holding a movement/rest/search key would only step once.
    // We synthesize repeats with a timer: a held, repeat-eligible key re-enqueues itself after an initial
    // delay, then at a steady interval. See keyRepeatInitialDelay/keyRepeatInterval and isRepeatable(...).
    fileprivate var keyRepeatTimer: Timer?
    fileprivate var repeatingKey: QueuedKeyEvent?
    private let keyRepeatInitialDelay: TimeInterval = 0.4
    private let keyRepeatInterval: TimeInterval = 0.1

    // ── Safe-area action buttons ─────────────────────────────────────────
    // A small column of buttons in the iPhone notch / dynamic-island safe-area
    // strip (the right edge in our landscape-left lock). Tapping a button injects
    // its bound Brogue keystroke; long-pressing opens a menu to rebind it (saved
    // to UserDefaults). The button face is always the literal bound key character.

    /// A bindable Brogue command: the key it sends, a human-readable name (from
    /// the engine's help screen), and the group it belongs to.
    private struct Command {
        let key: UInt8
        let name: String
        let category: String
        /// CE-only commands (e.g. re-throw) are hidden from the rebind menus
        /// while the Classic engine is active, since 1.7.5 doesn't handle them.
        var ceOnly: Bool = false
    }

    /// Commands a side button may be bound to. Names mirror printHelpScreen().
    private static let commandCatalog: [Command] = [
        // Stairs & Travel
        Command(key: ">".ascii, name: "Descend",           category: "Stairs & Travel"),
        Command(key: "<".ascii, name: "Ascend",            category: "Stairs & Travel"),
        Command(key: "x".ascii, name: "Auto-explore",      category: "Stairs & Travel"),
        // Resting & Waiting
        Command(key: "z".ascii, name: "Rest once",         category: "Resting & Waiting"),
        Command(key: "Z".ascii, name: "Rest until better", category: "Resting & Waiting"),
        Command(key: "s".ascii, name: "Search",            category: "Resting & Waiting"),
        // Item Actions
        Command(key: "e".ascii, name: "Equip",             category: "Item Actions"),
        Command(key: "r".ascii, name: "Remove",            category: "Item Actions"),
        Command(key: "a".ascii, name: "Apply / use",       category: "Item Actions"),
        Command(key: "t".ascii, name: "Throw",             category: "Item Actions"),
        Command(key: "T".ascii, name: "Re-throw at last monster", category: "Item Actions", ceOnly: true),
        Command(key: "d".ascii, name: "Drop",              category: "Item Actions"),
        Command(key: "c".ascii, name: "Call",              category: "Item Actions"),
        Command(key: "R".ascii, name: "Relabel",           category: "Item Actions"),
    ]

    /// Section order for the rebind menu.
    private static let commandCategoryOrder = ["Stairs & Travel", "Resting & Waiting", "Item Actions"]

    /// SF Symbol shown on a button face for each bindable command key. Keyed by
    /// the same `UInt8` keys as `commandCatalog`; the engine still receives the
    /// key on tap, so this only controls appearance.
    private static let commandSymbols: [UInt8: String] = [
        ">".ascii: "arrow.down.to.line",
        "<".ascii: "arrow.up.to.line",
        "x".ascii: "map",
        "z".ascii: "zzz",
        "Z".ascii: "bed.double.fill",
        "s".ascii: "magnifyingglass",
        "e".ascii: "shield.lefthalf.filled",
        "r".ascii: "xmark.shield",
        "a".ascii: "wand.and.stars",
        "t".ascii: "paperplane.fill",
        "T".ascii: "paperplane.circle.fill",
        "d".ascii: "arrow.down.circle",
        "c".ascii: "tag",
        "R".ascii: "textformat.abc",
    ]

    /// SF Symbol name for a bound key. The center button's "Nothing" sentinel
    /// maps to a slashed circle; anything unmapped falls back to it too.
    private static func symbolName(for key: UInt8) -> String {
        commandSymbols[key] ?? "circle.slash"
    }

    /// Point size / weight for button-face glyphs, matched to the old text scale.
    private static let buttonSymbolConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)

    /// Default key per slot (top→bottom): throw, auto-explore, search, rest-until-better.
    private static let defaultSideButtonKeys: [UInt8] = ["t".ascii, "x".ascii, "s".ascii, "Z".ascii]
    private static let sideButtonKeysDefaultsKey = "sideButtonKeys"

    /// Current key bound to each of the four slots; persisted to UserDefaults.
    private var sideButtonKeys: [UInt8] = BrogueViewController.loadSideButtonKeys()

    private var actionButtons: [UIButton] = []

    // ── Directional-pad center button ────────────────────────────────────
    // A fifth programmable button living in the dead zone at the center of the
    // directional pad (storyboard outlet on the D-pad VC, so it drags/hides with
    // it). Like the side buttons but, uniquely, it may be set to "Nothing".

    /// Sentinel binding meaning the center button does nothing when tapped.
    private static let centerButtonNothing: UInt8 = 0
    /// Center button's out-of-box binding: "Rest once" (z).
    private static let centerButtonDefaultKey: UInt8 = "z".ascii
    private static let centerButtonKeyDefaultsKey = "directionCenterButtonKey"

    /// Key bound to the center button; `centerButtonNothing` (0) = unbound.
    private var centerButtonKey: UInt8 = BrogueViewController.loadCenterButtonKey()

    // ── Directional-pad position ─────────────────────────────────────────
    // The pad can be two-finger-dragged. We persist that offset (one key,
    // shared by Classic and CE) and apply it as a transform rather than by
    // mutating `.center`: layout passes — e.g. opening a shortcut button's
    // context menu — reset `.center` back to its constraint position, but
    // leave `.transform` alone. So driving position via transform keeps the
    // pad put across menus and across relaunches.
    private static let dpadOffsetDefaultsKey = "directionPadUserOffset"

    /// Base translation applied before the user's drag. iPhone tucks the pad
    /// tighter into the corner; iPad keeps the storyboard position.
    private var dpadBaseTranslation: CGPoint {
        UIDevice.current.userInterfaceIdiom == .phone ? CGPoint(x: -80, y: 100) : .zero
    }

    /// User's accumulated two-finger-drag offset, persisted across launches.
    private var dpadUserOffset: CGPoint = BrogueViewController.loadDpadOffset()

    /// Transient, NON-persisted horizontal correction that lifts the d-pad clear
    /// of the notch-side safe area in whichever landscape it would otherwise hide
    /// under the cutout. Recomputed on launch and on rotation; never saved, so the
    /// user's flush/default placement is preserved in the non-notch orientation.
    private var dpadNotchAvoidance: CGFloat = 0

    /// Extra points the notch-avoidance nudge clears the safe-area inset by.
    /// Higher = pad sits further from the cutout; can go to 0 (flush to the inset)
    /// or negative (allow slight overlap). Tune to taste.
    private static let dpadNotchClearanceMargin: CGFloat = -20

    private static func loadDpadOffset() -> CGPoint {
        guard let stored = UserDefaults.standard.array(forKey: dpadOffsetDefaultsKey) as? [Double],
              stored.count == 2 else { return .zero }
        return CGPoint(x: stored[0], y: stored[1])
    }

    private func saveDpadOffset() {
        UserDefaults.standard.set([Double(dpadUserOffset.x), Double(dpadUserOffset.y)],
                                  forKey: BrogueViewController.dpadOffsetDefaultsKey)
    }

    /// Position the pad at its base translation plus the persisted user drag plus
    /// the transient notch-avoidance correction.
    private func applyDpadTransform() {
        dContainerView.transform = CGAffineTransform(
            translationX: dpadBaseTranslation.x + dpadUserOffset.x + dpadNotchAvoidance,
            y: dpadBaseTranslation.y + dpadUserOffset.y)
    }

    /// All hand-tunable haptic parameters in one place. Adjust feel here; nothing
    /// else hard-codes a style, intensity, or severity level. The `severity*`
    /// values must stay in sync with the engine's Combat.c damage hook.
    private enum Haptics {
        // Generator styles.
        static let buttonStyle: UIImpactFeedbackGenerator.FeedbackStyle = .soft
        static let lightDamageStyle: UIImpactFeedbackGenerator.FeedbackStyle = .medium
        static let strongDamageStyle: UIImpactFeedbackGenerator.FeedbackStyle = .heavy

        // Impact intensities (0...1). NOTE: iOS effectively drops impacts below
        // ~0.4 (imperceptible / not fired), so keep these at 0.4 or above.
        static let buttonIntensity: CGFloat = 0.6          // on-screen button tap / option feedback
        static let ordinaryDamageIntensity: CGFloat = 0.6  // severity 0: routine hit
        static let lowHealthDamageIntensity: CGFloat = 0.8 // severity 1: hit while under 40% HP
        // Death (severity 2) uses a notification buzz instead of an impact:
        static let deathNotification: UINotificationFeedbackGenerator.FeedbackType = .error

        // Damage severity levels passed up from the engine (see Combat.c).
        static let severityLowHealth = 1
        static let severityFatal = 2
    }

    /// Tactile feedback when an action button is tapped.
    private let actionButtonHaptics = UIImpactFeedbackGenerator(style: Haptics.buttonStyle)

    /// Whether tactile feedback is on. User-toggleable from the title options;
    /// persisted and shared across Classic and CE. Defaults on.
    private static let hapticsEnabledDefaultsKey = "hapticsEnabled"
    private var hapticsEnabled: Bool = {
        // Absent key → default on; honor an explicit stored value otherwise.
        UserDefaults.standard.object(forKey: hapticsEnabledDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: hapticsEnabledDefaultsKey)
    }()

    /// Fires the action-button haptic, unless the user has disabled haptics.
    private func fireHaptic() {
        guard hapticsEnabled else { return }
        actionButtonHaptics.impactOccurred(intensity: Haptics.buttonIntensity)
    }

    /// Generators for the take-damage feedback: a soft tick for ordinary hits and
    /// a heavy one for low-health hits, plus a notification generator for death.
    private let lightDamageHaptics = UIImpactFeedbackGenerator(style: Haptics.lightDamageStyle)
    private let strongDamageHaptics = UIImpactFeedbackGenerator(style: Haptics.strongDamageStyle)
    private let deathHaptics = UINotificationFeedbackGenerator()

    /// Tactile feedback when the player takes damage, scaled by severity (computed
    /// by the engine): 0 = ordinary hit (very light), 1 = hit while under 40%
    /// health, the threshold of the engine's low-health flash (stronger), 2 =
    /// killing blow (very strong). Respects the haptics setting and is iPhone-only
    /// (iPad has no haptic engine). Called from both engine bridges on the engine's
    /// background thread, so it hops to main.
    @objc func playerTookDamage(_ severity: Int) {
        guard hapticsEnabled, UIDevice.current.userInterfaceIdiom == .phone else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if severity >= Haptics.severityFatal {            // death — very strong, distinct buzz
                self.deathHaptics.notificationOccurred(Haptics.deathNotification)
                self.deathHaptics.prepare()
            } else if severity >= Haptics.severityLowHealth {  // low health (<40%) — stronger thud
                self.strongDamageHaptics.impactOccurred(intensity: Haptics.lowHealthDamageIntensity)
                self.strongDamageHaptics.prepare()             // keep warm for the next hit
            } else {                                           // ordinary hit — very light tick
                self.lightDamageHaptics.impactOccurred(intensity: Haptics.ordinaryDamageIntensity)
                self.lightDamageHaptics.prepare()
            }
        }
    }

    /// Warms the take-damage generators so the first hit isn't dropped by a cold
    /// Taptic Engine. Called when gameplay controls appear.
    private func prepareDamageHaptics() {
        lightDamageHaptics.prepare()
        strongDamageHaptics.prepare()
        deathHaptics.prepare()
    }

    /// iPhone "left-handed" magnifier mode: when on, the magnifier sits to the
    /// right of the finger instead of the left. Persisted; iPhone-only option.
    private static let leftHandMagnifierDefaultsKey = "leftHandMagnifier"
    private var leftHandMagnifier: Bool =
        UserDefaults.standard.bool(forKey: leftHandMagnifierDefaultsKey) // default off (right-handed)

    /// iPhone pinch-to-zoom (dungeon map) is always on; there is no user toggle.
    /// True only on the iPhone idiom, where the zoomable scene exists (iPad keeps
    /// the flat, un-zoomable grid).
    private var pinchZoomActive: Bool { isPhoneIdiom }

    /// When on (default), single-tapping a sidebar entity zooms out to 1× so its
    /// description box isn't clipped while zoomed. Toggleable in Options.
    private var examineZoomEnabled: Bool = RogueScene.isExamineZoomEnabledSetting

    /// Mirrors the directional pad's visibility: true while the player is
    /// actively moving around the dungeon, false on menus/dialogs/title.
    private var gameplayControlsActive = false {
        didSet { if oldValue != gameplayControlsActive { updateZoomForGameState() } }
    }

    /// Whether a hardware keyboard is currently attached. When true, the on-screen d-pad and the
    /// ESC button are hidden (redundant with the keyboard's arrows / Escape key); the engines also
    /// surface a "Press <?> for help" hint. Updated by the GCKeyboard observer.
    private var hardwareKeyboardConnected = false

    /// Whether the app logic currently wants the on-screen ESC button shown (escapable sub-screen,
    /// active text entry, etc.). The button is only actually shown when this is true AND no hardware
    /// keyboard is attached — see refreshEscButtonVisibility().
    private var escButtonWanted = false

    /// True while the player is aiming a throw/zap (CE targeting loop). Reported
    /// by the engine via setCETargeting; moves the esc button aside and re-enables
    /// the magnifier so the player can see what they're aiming at.
    private var isTargeting = false {
        didSet { if oldValue != isTargeting { updateZoomForGameState() } }
    }

    /// Derived: suspend zoom only when a description box is shown AND it was armed by a
    /// sidebar selection. Recomputed whenever either input below changes, so the order in
    /// which they arrive doesn't matter (the engine's box signal can race ahead of the
    /// arm set in touchesEnded). didSet drives the suspend/restore animation.
    private var isExamining = false {
        didSet { if oldValue != isExamining { updateZoomForGameState() } }
    }
    /// True while the engine is showing a creature/item description box (reported by both
    /// engines via setExamining). On its own it does NOT suspend zoom — it must be armed.
    private var examineBoxShown = false {
        didSet {
            guard oldValue != examineBoxShown else { return }
            if !examineBoxShown {
                examineArmDebounce?.cancel()                  // box gone → drop a pending arm
                examineArmed = false                          // …and require a fresh sidebar tap
            }
            isExamining = examineBoxShown && examineArmed
        }
    }
    /// Set only by a sidebar single-tap; gates the zoom-suspend so deliberate sidebar
    /// selections suspend but auto-appearing boxes (auto-explore stopping on an item, a
    /// tap-to-move over a monster) do not. Cleared when the box ends and on competing inputs.
    private var examineArmed = false {
        didSet {
            guard oldValue != examineArmed else { return }
            isExamining = examineBoxShown && examineArmed
        }
    }
    /// Deferred arm: a sidebar single-tap schedules arming after the double-tap window
    /// so a double-tap (attack/run toward) cancels it first and never zooms out.
    private var examineArmDebounce: DispatchWorkItem?
    /// How long to wait before a sidebar single-tap arms the examine zoom — long enough
    /// to let a second tap (double-tap) arrive and cancel it.
    private let examineArmDelay: TimeInterval = 0.3
    /// The escape button's resting transform, captured so it can be restored after
    /// being moved to the lower-left corner during targeting.
    private var savedEscTransform: CGAffineTransform?

    // ── Pinch-to-zoom (iPhone only) ──────────────────────────────────────
    // Canonical zoom state, in UIKit point space. `zoomScale` is the
    // magnification; `zoomOriginPt` positions the magnified map so a touch `p`
    // inverts to `(p - origin) / scale` (see SKViewPort.unzoomedPoint). Pushed
    // to the scene via skViewPort.applyZoom. Persists across levels; on the title
    // and on death the *display* drops to 1×, but the magnification is remembered
    // (see zoomScaleDefaultsKey) and carries into the next run. iPad never zooms
    // (gestures aren't installed).
    private static let zoomMinScale: CGFloat = 1.0
    private static let zoomMaxScale: CGFloat = 2.5
    private static let zoomRubberBandFloor: CGFloat = 0.8
    /// Fractional finger-spread change required before a pinch starts zooming.
    /// Below this, a two-finger drag is treated as a pure pan (Photos-style).
    private static let zoomActivationThreshold: CGFloat = 0.20   // 10%
    /// UserDefaults key for the player's preferred dungeon magnification. Persisted
    /// so the zoom level carries between game runs and across app launches; the
    /// origin is intentionally not stored (each run recenters on the player).
    private static let zoomScaleDefaultsKey = "preferredZoomScale"

    /// Center columns of the 5 engine bottom buttons (Explore/Rest/Search/Menu/
    /// Inventory), mirroring initializeMenuButtons in BrogueCode/IO.c (starts
    /// 21/38/53/68/81, widths 15/13/13/11/15). Both engines share this layout.
    /// Used to snap bottom tap-band touches to the nearest button.
    private static let bottomButtonCenterColumns = [28, 44, 59, 73, 88]
    private var zoomScale: CGFloat = 1.0
    private var zoomOriginPt: CGPoint = .zero
    /// The persisted preferred zoom magnification, clamped to the valid range.
    /// An absent/zero default reads back as 1× (no zoom).
    private var storedZoomScale: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: BrogueViewController.zoomScaleDefaultsKey))
            guard v >= BrogueViewController.zoomMinScale else { return BrogueViewController.zoomMinScale }
            return min(v, BrogueViewController.zoomMaxScale)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: BrogueViewController.zoomScaleDefaultsKey) }
    }
    /// Previous UIPinchGestureRecognizer.scale, for incremental scale-about-
    /// centroid updates (jump-free, vs. a captured-anchor recompute).
    private var lastPinchScale: CGFloat = 1.0
    /// True from the moment a second finger lands (or a zoom gesture begins)
    /// until all fingers lift. While set, raw touches are NOT fed to the engine,
    /// so the first finger of a pinch/pan can't leak a tap/travel that would
    /// snap the view via auto-follow.
    private var multiTouchGestureActive = false
    /// True once the player two-finger-drags to look around; cleared on the next
    /// real player move, which re-centers (auto-follow).
    private var manualPanActive = false
    /// Latches true once a pinch's spread crosses `zoomActivationThreshold`, and
    /// stays set until the gesture ends. Until it latches, the pinch is dormant
    /// so a two-finger pan with incidental spread drift reads as a pure pan.
    private var pinchZoomEngaged = false
    /// Last player window cell received from the engine bridge (auto-follow).
    private var lastPlayerWindowCell: CGPoint?
    /// Set by restoreStoredZoom when a run opens with a remembered zoom. The launch
    /// zoom-in is a one-shot: it waits until we're on the map AND the player's cell is
    /// known, then eases in once, centered on the player. This makes the open immune to
    /// engine event ordering (controls-flip vs. cell-report vs. restore) — no premature
    /// animate-to-1× jitter, and never the map-center because it always has the cell.
    private var pendingLaunchZoom = false
    /// The zoom recognizers, kept so the magnifier can be suppressed while a
    /// pinch or two-finger pan is in progress.
    private weak var zoomPinch: UIPinchGestureRecognizer?
    private weak var zoomPan: UIPanGestureRecognizer?
    /// Two-finger double-tap "zoom out / back" toggle, kept for enable/disable.
    private weak var zoomToggle: UITapGestureRecognizer?
    /// The zoom (scale + origin) to return to when a two-finger double-tap toggles
    /// back in. Captured at the moment of toggling out; restoring the origin directly
    /// means the restore doesn't depend on a live auto-follow cell (which can be nil).
    /// scale 0 = nothing captured this session.
    private var zoomToggleRestoreScale: CGFloat = 0
    private var zoomToggleRestoreOrigin: CGPoint = .zero
    /// True while a pinch or two-finger pan is actively recognizing.
    private var zoomGestureInProgress: Bool {
        func active(_ g: UIGestureRecognizer?) -> Bool {
            guard let state = g?.state else { return false }
            return state == .began || state == .changed
        }
        return active(zoomPinch) || active(zoomPan)
    }

    /// Drives the smooth automatic zoom suspend/restore (overlay/menu/examine ↔ map).
    /// Interpolates the *applied* scene transform only; the canonical zoomScale /
    /// zoomOriginPt are owned by the caller and untouched by the animation.
    private var zoomAnimLink: CADisplayLink?
    private var zoomAnimStartScale: CGFloat = 1.0
    private var zoomAnimStartOrigin: CGPoint = .zero
    private var zoomAnimTargetScale: CGFloat = 1.0
    private var zoomAnimTargetOrigin: CGPoint = .zero
    private var zoomAnimStartTime: CFTimeInterval = 0
    private let zoomAnimDuration: CFTimeInterval = 0.2
    /// The transform currently shown on screen, so an animation starts from it and
    /// instant applies (gestures, per-step auto-follow) stay in sync.
    private var appliedScale: CGFloat = 1.0
    private var appliedOrigin: CGPoint = .zero

    private var isPhoneIdiom: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// One-time first-run hint pointing at a side button to explain long-press
    /// rebinding. The flag persists across launches; `keybindHintInFlight`
    /// guards the short delayed-present window.
    private static let keybindHintShownKey = "didShowKeybindHint"
    private var keybindHintInFlight = false

    /// One-time first-run hint, the first time a game starts on iPhone with
    /// pinch-zoom available, explaining the pinch / two-finger-double-tap gestures.
    /// Mirrors the keybind-hint flags: the key persists across launches, the
    /// in-flight bool guards the short delayed-present window.
    private static let zoomHintShownKey = "didShowPinchZoomHint"
    private var zoomHintInFlight = false

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

    /// Title-screen-only button (created in code, no art asset) that opens the
    /// save/replay file manager. Visibility tracks `lastBrogueGameEvent` just like
    /// the leaderboard/seed overlays.
    private var manageFilesButton: UIButton!

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
                    // Game Center + File Management moved into the Classic title menu.
                    self.leaderBoardButton.isHidden = true
                    self.seedButton.isHidden = false
                    self.escButtonWanted = false
                    self.refreshEscButtonVisibility()
                    self.resetZoom()
                case .startNewGame, .openGame, .beginOpenGame:
                    self.leaderBoardButton.isHidden = true
                    self.seedButton.isHidden = true
                    self.manageFilesButton?.isHidden = true
                    self.seedKeyDown = false
                    self.restoreStoredZoom()
                case .messagePlayerHasDied:
                    self.showInventoryButton.isHidden = false
                    self.resetZoom()
                case .playerHasDiedMessageAcknowledged:
                    self.showInventoryButton.isHidden = true
                default: ()
                }
                
                // Hide/Show the directions.
                switch self.lastBrogueGameEvent {
                case .waitingForConfirmation, .actionMenuOpen, .openedInventory, .showTitle, .openGameFinished, .playRecording, .showHighScores, .playBackPanic, .messagePlayerHasDied, .playerHasDiedMessageAcknowledged, .keyBoardInputRequired, .beginOpenGame:
                    self.gameplayControlsActive = false
                default:
                    self.gameplayControlsActive = true
                }
                // Actual d-pad visibility also depends on hardware-keyboard presence (hidden when one
                // is attached); see refreshDirectionPadVisibility().
                self.refreshDirectionPadVisibility()
                self.updateActionButtonVisibility()

                // Reserve the home-indicator strip only during gameplay. On the title
                // and other menu screens, let the grid fill the full screen.
                switch self.lastBrogueGameEvent {
                case .showTitle, .openGameFinished, .beginOpenGame, .showHighScores:
                    self.skViewPort.rogueScene.paddingEnabled = false
                default:
                    self.skViewPort.rogueScene.paddingEnabled = true
                }

                // Show the version chooser only on the Classic title screen.
                self.atTitle = (self.lastBrogueGameEvent == .showTitle)
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        currentEngine = BrogueViewController.persistedEngine()
        setupVersionChooser()
        setupOptionsButton()
        setupInfoButton()
        startEngine()

        magView.viewToMagnify = skViewPort
        magView.leftHandMode = leftHandMagnifier
        magView.hideMagnifier()
        inputTextField.delegate = self

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(draggedView(_:)))
        panGesture.minimumNumberOfTouches = 2
        dContainerView.addGestureRecognizer(panGesture)
        dContainerView.alpha = 0.3

        setupZoomGestures()

        // Storyboard positions these for iPad. On iPhone (much less screen
        // real estate, landscape-only) push the esc button tighter into the
        // edge. Applied as a transform so auto-layout passes don't fight us.
        // Tune this constant to taste.
        if UIDevice.current.userInterfaceIdiom == .phone {
            escButton.transform = CGAffineTransform(translationX: -80, y: 90)
        }
        // Position the draggable pad from its base offset plus any saved drag.
        // (Transform, not .center — see dpad position note above.)
        applyDpadTransform()

        GameCenter.shared.authenticate(from: self)

        setupHardwareKeyboardObserver()
        setupActionButtons()
        setupCenterShortcutButton()
        // File management and Game Center now live in the Classic title menu
        // (engine-drawn), so the floating UIKit buttons are no longer created.
        repositionSeedButton()
    }

    /// Moves the seed button from its storyboard spot (bottom-left) to just left
    /// of the "New Game" menu item, outside the menu's black border. The Classic
    /// menu is engine-drawn at fixed grid cells and the title grid fills the
    /// screen, so we anchor with fractional (multiplier) constraints that track
    /// rotation. New Game renders at roughly grid (x≈77, y≈21) of the 100×34 grid.
    private func repositionSeedButton() {
        guard let seedButton = seedButton, let host = seedButton.superview else { return }
        // Drop the storyboard position constraints (leading vs leaderboard,
        // bottom vs layout guide); the 80×80 size constraints live on the button
        // itself and are preserved.
        let positional = host.constraints.filter { $0.firstItem === seedButton || $0.secondItem === seedButton }
        NSLayoutConstraint.deactivate(positional)
        NSLayoutConstraint.activate([
            // Right edge just left of the menu's left border (~grid x 77).
            NSLayoutConstraint(item: seedButton, attribute: .trailing, relatedBy: .equal,
                               toItem: view!, attribute: .trailing, multiplier: 75.0 / 100.0, constant: 0),
            // Vertically centered on the New Game row (~grid y 21.5 of 34).
            NSLayoutConstraint(item: seedButton, attribute: .centerY, relatedBy: .equal,
                               toItem: view!, attribute: .bottom, multiplier: 21.5 / 34.0, constant: 0),
        ])
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
        updateDpadNotchAvoidance()
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

    /// Which screen edge the front cutout (notch / dynamic island) sits on in the
    /// current landscape. In `landscapeLeft` the device's camera end points RIGHT;
    /// in `landscapeRight` it points LEFT. iOS reports near-symmetric horizontal
    /// safe-area insets in landscape, so the interface orientation — not inset
    /// asymmetry — is the reliable signal. Defaults to right (the app's original
    /// single-orientation assumption) before a window scene is attached.
    private var notchOnRight: Bool {
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeLeft
        return orientation != .landscapeRight
    }

    private func applyNotchInsets() {
        let insets = bestSafeAreaInsets
        let scale = UIScreen.main.scale

        // Position the safe-area action buttons in the (now-known) cutout strip
        // and show/hide them for this device + game state.
        layoutActionButtons(insets: insets)
        updateActionButtonVisibility()

        // Reserve space on whichever side the notch / dynamic island currently
        // sits (landscapeLeft → right edge, landscapeRight → left edge). iOS
        // reports near-symmetric horizontal insets in landscape, so we reserve
        // only the actual-notch side and slide the whole grid AWAY from it by
        // `gridRightShift`: the non-notch edge is inset by that amount, and the
        // notch-side reservation is reduced by the same amount, so the grid keeps
        // its width and pushes that far into the notch-side safe area.
        let shift = SKViewPort.gridRightShift
        let onRight = notchOnRight
        let notchInset = onRight ? insets.right : insets.left
        let nearPixels = shift * scale                          // non-notch edge
        let notchPixels = max(notchInset - shift, 0) * scale    // notch edge
        skViewPort.rogueScene.setHorizontalEdgeInsets(
            leftPixels: onRight ? nearPixels : notchPixels,
            rightPixels: onRight ? notchPixels : nearPixels
        )
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Re-mirror the grid shift and action-button edge for the new landscape
        // once the rotation (bounds + interface orientation) has settled, then
        // rescue the d-pad if it now sits under the cutout.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.applyNotchInsets()
            self?.updateDpadNotchAvoidance()
        }
    }

    /// Recomputes the transient notch-avoidance shift for the current landscape:
    /// if the d-pad's saved/default position would overlap the notch-side safe
    /// area, push it just clear; otherwise zero. Display-only — never persisted —
    /// so the user's placement is intact and simply returns to where they left it
    /// in the orientation whose cutout it doesn't touch. Called on launch and on
    /// rotation, never during normal play (a deliberate under-cutout park stays).
    private func updateDpadNotchAvoidance() {
        guard isPhoneIdiom else { return }
        // Measure the pad at its true (un-corrected) position first.
        dpadNotchAvoidance = 0
        applyDpadTransform()

        let insets = bestSafeAreaInsets
        let bounds = view.bounds
        let frame = dContainerView.frame
        let margin = BrogueViewController.dpadNotchClearanceMargin
        var dx: CGFloat = 0
        if notchOnRight {
            let limit = bounds.maxX - insets.right - margin
            if frame.maxX > limit { dx = limit - frame.maxX }   // shift left
        } else {
            let limit = bounds.minX + insets.left + margin
            if frame.minX < limit { dx = limit - frame.minX }   // shift right
        }
        guard dx != 0 else { return }
        dpadNotchAvoidance = dx
        applyDpadTransform()
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
            let nav = UINavigationController(rootViewController:
                FileManagementViewController(directory: saveDir, allowsDuplicate: allowsDuplicate))
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
        fireHaptic()
        addKeyEvent(event: sideButtonKeys[slot])
    }

    /// Styles and wires the storyboard center button. Reuses the side-button
    /// look; tap fires its bound key (unless "Nothing"), long-press rebinds it.
    /// Visibility/position are handled by the D-pad it lives inside.
    private func setupCenterShortcutButton() {
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

    /// Center button shows the SF Symbol for its bound command; when set to
    /// "Nothing" it shows a slashed circle so it stays visible and long-pressable.
    private func refreshCenterButtonAppearance() {
        guard let button = directionsViewController?.centerShortcutButton else { return }
        let name = BrogueViewController.symbolName(for: centerButtonKey)
        button.setImage(UIImage(systemName: name, withConfiguration: BrogueViewController.buttonSymbolConfig), for: .normal)
        button.alpha = 1.0
    }

    @objc private func centerButtonTapped() {
        guard centerButtonKey != BrogueViewController.centerButtonNothing else { return }
        fireHaptic()
        addKeyEvent(event: centerButtonKey)
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
    private func updateActionButtonVisibility() {
        let hasStrip = currentDisplayCutout(insets: bestSafeAreaInsets) != .none
        let visible = hasStrip && gameplayControlsActive
        for button in actionButtons {
            button.isHidden = !visible
            button.isUserInteractionEnabled = visible
        }
        // Warm up the haptic engine so the first tap / hit fires without latency.
        // (A cold Taptic Engine often drops or weakens the first impactOccurred.)
        if visible {
            if hapticsEnabled {
                actionButtonHaptics.prepare()
                prepareDamageHaptics()
            }
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
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.destination is DirectionControlsViewController {
            directionsViewController = segue.destination as? DirectionControlsViewController
            addObserver(self, forKeyPath: #keyPath(directionsViewController.directionalButton), options: [.new], context: nil)
        }
    }
    
    // MARK: - Engine session (start / in-process swap)

    /// Boots the engine named by `currentEngine` on a large-stack background
    /// thread. When `rogueMain` returns (e.g. after a Quit), `engineDidExit` runs.
    private func startEngine() {
        switch currentEngine {
        case .classic:
            // Classic 1.7.5 engine, compiled into the app target.
            setClassicTerminationRequested(false) // clear any prior switch request
            RogueDriver.sharedInstance(with: skViewPort, viewController: self)
            // iPhone-only layout tweaks (taller bottom button bar). iPad: default.
            setPhoneLayout(UIDevice.current.userInterfaceIdiom == .phone ? 1 : 0)
            let thread = Thread { [weak self] in
                rogueMain()
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
    private func cycleEngine(forward: Bool) {
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
            setClassicTerminationRequested(true)
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
            self.leaderBoardButton.isHidden = true
            self.seedButton.isHidden = true
            self.manageFilesButton?.isHidden = true
            self.showInventoryButton.isHidden = true

            // Directional pad + action bar only during normal play. The d-pad is additionally
            // hidden when a hardware keyboard is attached; see refreshDirectionPadVisibility().
            self.gameplayControlsActive = inPlay
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
        }
    }

    /// Runs (on the engine thread) when `rogueMain` returns. If a swap is pending,
    /// boots the other engine on the main thread.
    private func engineDidExit() {
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

    // MARK: - Version chooser (title-screen engine swap)

    private static let engineDefaultsKey = "selectedEngine"

    /// The engine to boot on launch — the last one played, defaulting to Classic.
    private static func persistedEngine() -> EngineKind {
        switch UserDefaults.standard.string(forKey: engineDefaultsKey) {
        case "ce": return .ce
        case "se": return .se
        default: return .classic
        }
    }

    private func persistEngine() {
        let value: String
        switch currentEngine {
        case .classic: value = "classic"
        case .ce: value = "ce"
        case .se: value = "se"
        }
        UserDefaults.standard.set(value, forKey: Self.engineDefaultsKey)
    }

    /// Builds the title-only "‹ engine ›" chip. Swipe or tap it to switch engines.
    private func setupVersionChooser() {
        let chip = UIView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        chip.layer.cornerRadius = 16
        chip.isHidden = true

        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
        let makeChevron: (String) -> UILabel = { text in
            let chevron = UILabel()
            chevron.text = text
            chevron.textColor = .white
            chevron.font = font
            return chevron
        }
        // The chip and these chevrons stay put; only `name` fades.
        let name = UILabel()
        name.textColor = .white
        name.font = font
        name.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [makeChevron("‹"), name, makeChevron("›")])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        chip.addSubview(stack)

        view.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -16),
        ])

        // Swipe direction maps to the lineage cycle: left → next (Classic→CE→SE),
        // right → previous. A tap advances forward, same as a left swipe.
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(versionChooserSwipedNext))
        swipeLeft.direction = .left
        chip.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(versionChooserSwipedPrev))
        swipeRight.direction = .right
        chip.addGestureRecognizer(swipeRight)
        chip.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(versionChooserActivated)))

        versionChooser = chip
        versionChooserLabel = name
        updateVersionChooserLabel()
    }

    @objc private func versionChooserActivated() {
        cycleEngine(forward: true)
    }

    @objc private func versionChooserSwipedNext() {
        cycleEngine(forward: true)
    }

    @objc private func versionChooserSwipedPrev() {
        cycleEngine(forward: false)
    }

    // MARK: - Title-screen options (universal, Classic + CE)

    /// Builds the lower-left options button. A single tap opens its menu; the
    /// button is title-only, shown/hidden alongside the version chooser.
    private func setupOptionsButton() {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = UIColor(white: 0.85, alpha: 1.0)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 22
        button.setImage(UIImage(systemName: "gearshape.fill",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)),
                        for: .normal)
        button.isHidden = true
        button.showsMenuAsPrimaryAction = true
        button.menu = optionsMenu()

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        optionsButton = button
    }

    /// Info button, placed just to the right of the options button. Matches the
    /// options button's styling. Tapping it presents a description of the
    /// currently selected engine's key features.
    private func setupInfoButton() {
        guard let optionsButton = optionsButton else { return }
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = UIColor(white: 0.85, alpha: 1.0)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 22
        button.setImage(UIImage(systemName: "info.circle.fill",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)),
                        for: .normal)
        button.isHidden = true
        button.addTarget(self, action: #selector(infoButtonPressed), for: .touchUpInside)

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: optionsButton.trailingAnchor, constant: 12),
            button.centerYAnchor.constraint(equalTo: optionsButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        infoButton = button
    }

    @objc private func infoButtonPressed() {
        presentEngineInfo()
    }

    /// The options menu. Universal across engines; add new entries here.
    private func optionsMenu() -> UIMenu {
        let resetDirections = UIAction(title: "Default d-pad position",
                                       image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
            self?.resetDpadPosition()
        }

        var children: [UIMenuElement] = []

        // Haptics and magnifier orientation are iPhone-only: iPad has no haptic
        // engine, and the beside-the-finger magnifier placement is iPhone-only.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let haptics = UIAction(title: "Haptics",
                                   image: UIImage(systemName: "iphone.radiowaves.left.and.right"),
                                   state: hapticsEnabled ? .on : .off) { [weak self] _ in
                self?.toggleHaptics()
            }
            // Title states the current side (left-handed mode = magnifier on the
            // right); no checkmark, since the text itself conveys the state.
            let magnifierSide = UIAction(title: leftHandMagnifier ? "Magnifier: right side" : "Magnifier: left side",
                                         image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.toggleLeftHandMagnifier()
            }
            children.append(contentsOf: [haptics, magnifierSide])
            // Pinch-to-zoom is always on; this sub-option zooms out to show a tapped
            // sidebar entity's description box so it isn't clipped while zoomed.
            let examineZoom = UIAction(title: "Zoom out on examine",
                                       image: UIImage(systemName: "sidebar.left"),
                                       state: examineZoomEnabled ? .on : .off) { [weak self] _ in
                self?.toggleExamineZoom()
            }
            children.append(examineZoom)
        }

        children.append(resetDirections)
        return UIMenu(title: "Options", children: children)
    }

    /// Flips the left-handed magnifier setting, persists it, applies it to the
    /// live magnifier, and rebuilds the menu so its checkmark updates.
    private func toggleLeftHandMagnifier() {
        leftHandMagnifier.toggle()
        UserDefaults.standard.set(leftHandMagnifier, forKey: BrogueViewController.leftHandMagnifierDefaultsKey)
        magView.leftHandMode = leftHandMagnifier
        fireHaptic()
        optionsButton?.menu = optionsMenu()
    }

    /// Flips "zoom out on examine" (sidebar-tap description), persists it, and rebuilds
    /// the menu. If turned off mid-examine, restore the zoom immediately.
    private func toggleExamineZoom() {
        examineZoomEnabled.toggle()
        UserDefaults.standard.set(examineZoomEnabled, forKey: RogueScene.examineZoomEnabledDefaultsKey)
        if !examineZoomEnabled {                            // drops any active/pending examine suspend
            examineArmDebounce?.cancel()
            examineArmed = false
        }
        fireHaptic()
        optionsButton?.menu = optionsMenu()
    }

    /// Flips the haptics setting, persists it, gives confirming feedback if it was
    /// just enabled, and rebuilds the menu so its checkmark reflects the new state.
    private func toggleHaptics() {
        hapticsEnabled.toggle()
        UserDefaults.standard.set(hapticsEnabled, forKey: BrogueViewController.hapticsEnabledDefaultsKey)
        if hapticsEnabled {
            actionButtonHaptics.prepare()
            actionButtonHaptics.impactOccurred(intensity: Haptics.buttonIntensity)
        }
        optionsButton?.menu = optionsMenu()
    }

    /// Clears the saved two-finger-drag offset so the directional pad returns to
    /// its default position. Universal — the offset is shared by Classic and CE.
    private func resetDpadPosition() {
        fireHaptic()
        dpadUserOffset = .zero
        saveDpadOffset()
        applyDpadTransform()
    }

    private func updateTitleOptionsVisibility() {
        optionsButton?.isHidden = !atTitle
        infoButton?.isHidden = !atTitle
    }

    // MARK: - Engine info panel

    /// Returns a bold variant of the font, preserving its (Dynamic Type) size.
    private static func boldFont(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Returns an italic variant of the font, preserving its (Dynamic Type) size.
    private static func italicFont(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// A line in the info panel. The renderer styles each kind differently.
    private enum InfoBlock {
        case heading(String)        // top-level group heading
        case note(String)           // italic descriptor beneath a heading
        case section(String)        // sub-section heading
        case body(String)           // plain body paragraph
        case bullets([String])      // bullet list
        case link(String, String)   // tappable label + destination URL
    }

    /// Presents a scrollable description of the currently selected engine's key
    /// features. Content is engine-aware: CE summarizes how it differs from the
    /// original Brogue; Classic gives a short description of the original game.
    private func presentEngineInfo() {
        guard presentedViewController == nil else { return }

        let title: String
        let blocks: [InfoBlock]
        switch currentEngine {
        case .classic: title = "About Brogue";    blocks = Self.classicInfoBlocks()
        case .ce:      title = "About BrogueCE";   blocks = Self.ceInfoBlocks()
        case .se:      title = "About Brogue SE";  blocks = Self.seInfoBlocks()
        }

        let content = UIViewController()
        content.view.backgroundColor = .systemBackground
        content.title = title
        content.navigationItem.rightBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissEngineInfo))

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true          // required for .link attributes to be tappable
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.attributedText = BrogueViewController.infoAttributedText(blocks)
        content.view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.trailingAnchor),
        ])

        let nav = UINavigationController(rootViewController: content)
        present(nav, animated: true)
    }

    @objc private func dismissEngineInfo() {
        dismiss(animated: true)
    }

    /// Renders the structured info blocks into a styled attributed string,
    /// scaling with the user's Dynamic Type setting.
    private static func infoAttributedText(_ blocks: [InfoBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let bulletStyle = NSMutableParagraphStyle()
        bulletStyle.headIndent = 16
        bulletStyle.firstLineHeadIndent = 0
        bulletStyle.paragraphSpacing = 7
        bulletStyle.lineBreakMode = .byWordWrapping
        bulletStyle.tabStops = [NSTextTab(textAlignment: .left, location: 16)]

        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 18
        headingStyle.paragraphSpacing = 4

        let sectionStyle = NSMutableParagraphStyle()
        sectionStyle.paragraphSpacingBefore = 12
        sectionStyle.paragraphSpacing = 4

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.paragraphSpacing = 8
        bodyStyle.lineBreakMode = .byWordWrapping

        for block in blocks {
            switch block {
            case .heading(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: boldFont(UIFont.preferredFont(forTextStyle: .title2)),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: headingStyle,
                ]))
            case .note(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: italicFont(UIFont.preferredFont(forTextStyle: .subheadline)),
                    .foregroundColor: UIColor.secondaryLabel,
                ]))
            case .section(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .headline),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: sectionStyle,
                ]))
            case .body(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: bodyStyle,
                ]))
            case .bullets(let items):
                for item in items {
                    out.append(NSAttributedString(string: "•\t" + item + "\n", attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: bulletStyle,
                    ]))
                }
            case .link(let text, let urlString):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .paragraphStyle: bodyStyle,
                ]
                // The .link attribute drives both tap handling and the styling from
                // the text view's linkTextAttributes; fall back to plain body text
                // if the URL is somehow unparseable rather than dropping the line.
                if let url = URL(string: urlString) {
                    attributes[.link] = url
                } else {
                    attributes[.foregroundColor] = UIColor.label
                }
                out.append(NSAttributedString(string: text + "\n", attributes: attributes))
            }
        }
        return out
    }

    /// BrogueCE's purpose and how it relates to the original Brogue. Curated for
    /// the iOS port; the full change list lives in the project changelog/wiki.
    private static func ceInfoBlocks() -> [InfoBlock] {
        return [
            .note("Brogue was created by Brian Walker. This version, Brogue: Community Edition, is a continuation of its development. It has several main goals:"),
            .bullets([
                "fix bugs and crashes",
                "add useful quality of life and non-gameplay features",
                "improve the gameplay and keep it exciting",
                "ease development and maintenance",
                "be a convenient base for forks and ports to new platforms",
            ]),
            .section("How is CE different from the original Brogue?"),
            .note("Please refer to the changelog or release history for a complete list:"),
            .link("Changes from original", "https://github.com/tmewett/BrogueCE/wiki/Changes-from-original"),
        ]
    }

    /// Brogue SE release notes — player-facing highlights for the current release.
    /// Curated for the info panel; the full technical log lives in
    /// BrogueSE/Engine/IOS_MODIFICATIONS.md. Keep in sync with new content.
    private static func seInfoBlocks() -> [InfoBlock] {
        return [
            .note("Brogue SE — An experimental fork of BrogueCE with original items, monsters, and mechanics with release 1 (\"Alphabet-a Soup\") and an upcoming release (\"Alphabeast\") that will bring new monsters and minibosses. Here's what's new:"),
            .heading("🧪 New Items"),
            .bullets([
                "The Empty Bottle — Carry it and the world fills it: step into a gas or pool to bottle it, drift over lava or a chasm while levitating to skim it, or set it down and zap it with a bolt. Each capture becomes a real, identified potion.",
                "Captured potions — Acid, webbing, steam, ice, and water can only be obtained by capturing hazards with the empty bottle. Each one re-creates its hazard when thrown.",
                "Staff of Frost — Freeze enemies solid, slow them, freeze water into walkable ice bridges, turn foliage into brittle frozen walls, and shove foes back moving them out of your way and damaging enemies in their path.",
            ]),
            .heading("👹 Monsters & Allies"),
            .bullets([
                "The Gold Goblin — A skittish treasure-hoarder that flees toward the stairs, scattering a trail of gold. Chase it down and corner it before it escapes to the next floor.",
                "Cleverer thieves — Monkeys and imps now target the items they actually covet, not just whatever's handy. #849 gimballock",
                "Better allies — Allies keep a safe distance from invulnerable monsters, and the Ring of Light can rally and embolden the companions fighting beside you.",
            ]),
            .heading("🔍 A New Way to Identify Items"),
            .bullets([
                "Rest to learn — Resting gradually reveals whether your unidentified items are helpful or harmful.",
                "Clues add up — Gather enough hints about an item — or rule out enough of the alternatives — and the dungeon puts it together for you, identifying it outright.",
                "Detect magic, reined in — The potion of detect magic now only hints at the good-or-bad nature of one or two items at a time, and turns up less often than before. But pair it with a Ring of Wisdom and the potion becomes stronger.",
                "Altars of Insight — Sacrifice one item to reveal the nature of another.",
                "Everyday tells — Eating a meal, watching a scroll burn, shattering a potion with a thrown weapon or a bolt, freeing a captive, and the rings of awareness and wisdom all quietly reveal clues about what you're carrying.",
            ]),
            .heading("🌊 The Living Dungeon"),
            .bullets([
                "Electrified water — A lightning bolt striking a pool now shocks the entire connected body of water. Mind where you stand.",
                "Water has uses — Wading washes away the scent trail you leave for hunters and douses flames.",
                "Fire spreads consequences — Catching fire sends you into a brief panic; food rations caught in fire cook into edible \"cooked food.\"",
                "Read the chase — You can now sense when a pursuing monster has lost your trail.",
            ]),
            .heading("🎮 Quality of Life"),
            .bullets([
                "Pick your controls — Choose between Classic and Modern keyboard layouts; the game adapts when a hardware keyboard is attached.",
                "Pick up where you left off — Your last-played seed is remembered across launches.",
                "Smoother and more stable — Numerous community bug fixes, from dungeon-generation quirks to combat, stealth, and identification edge cases (#766, #805, #812, #816, #831, #837, #841).",
                "..and so much more",
            ]),
        ]
    }

    /// Short description of the original Brogue (the "Classic" engine).
    private static func classicInfoBlocks() -> [InfoBlock] {
        return [
            .note("Countless adventurers before you have descended this torch-lit staircase, seeking the promised riches below. As you reach the bottom and step into the wide cavern, the doors behind you seal with a powerful magic..."),
            .heading("Welcome to the Dungeons of Doom!"),
            .body("Brogue is a single-player strategy game set in the halls of a mysterious and randomly-generated dungeon. The objective is simple enough -- retrieve the fabled Amulet of Yendor from the 26th level -- but the dungeon is riddled with danger. Horrifying creatures and devious, trap-ridden terrain await. Yet it is also riddled with weapons, potions, and artifacts of forgotten power. Survival demands strength and cunning in equal measure as you descend, making the most of what the dungeon gives you. You will make sacrifices, narrow escapes, and maybe even some friends along the way -- but will you be one of the lucky few to return alive?"),
        ]
    }

    private func updateVersionChooserLabel() {
        switch currentEngine {
        case .classic: versionChooserLabel?.text = "Brogue"
        case .ce:      versionChooserLabel?.text = "BrogueCE"
        case .se:      versionChooserLabel?.text = "Brogue SE"
        }
    }

    private func updateVersionChooserVisibility() {
        updateVersionChooserLabel()
        if atTitle {
            versionChooser?.isHidden = false
            showVersionChooserName()
        } else {
            versionChooserFadeTimer?.invalidate()
            versionChooser?.isHidden = true
        }
    }

    /// Shows the engine name briefly, then fades just the name out — the chip and
    /// its ‹ › chevrons stay visible so the affordance remains.
    private func showVersionChooserName() {
        guard let name = versionChooserLabel else { return }
        versionChooserFadeTimer?.invalidate()
        UIView.animate(withDuration: 0.2) { name.alpha = 1 }
        versionChooserFadeTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            guard let name = self?.versionChooserLabel else { return }
            UIView.animate(withDuration: 0.6) { name.alpha = 0 }
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
    /// commands (e.g. re-throw) are dropped while Classic is running.
    private func availableCommands() -> [Command] {
        BrogueViewController.commandCatalog.filter { currentEngine.isCEFamily || !$0.ceOnly }
    }

    private func rebindMenu(forSlot slot: Int) -> UIMenu {
        let currentKey = sideButtonKeys[slot]
        let catalog = availableCommands()
        let sections = BrogueViewController.commandCategoryOrder.map { category -> UIMenu in
            let actions = catalog
                .filter { $0.category == category }
                .map { command -> UIAction in
                    let keyChar = String(UnicodeScalar(command.key))
                    let action = UIAction(title: "\(command.name) (\(keyChar))",
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
    fileprivate static func loadSideButtonKeys() -> [UInt8] {
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
                    let keyChar = String(UnicodeScalar(command.key))
                    let action = UIAction(title: "\(command.name) (\(keyChar))",
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
    fileprivate static func loadCenterButtonKey() -> UInt8 {
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

// MARK: - First-run keybind hint

extension BrogueViewController: UIPopoverPresentationControllerDelegate {
    /// Shows a one-time popover off the top side button explaining long-press
    /// rebinding, the first time the buttons appear during gameplay. No-op once
    /// shown, on non-cutout devices (buttons hidden), or if we can't present.
    fileprivate func maybeShowKeybindHint() {
        guard !UserDefaults.standard.bool(forKey: Self.keybindHintShownKey),
              !keybindHintInFlight,
              view.window != nil,
              presentedViewController == nil,
              let anchor = actionButtons.first, !anchor.isHidden else {
            return
        }
        keybindHintInFlight = true
        // Brief delay so it appears after the game screen settles, not instantly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            guard self.view.window != nil,
                  self.presentedViewController == nil,
                  let anchor = self.actionButtons.first, !anchor.isHidden else {
                self.keybindHintInFlight = false   // retry the next time the buttons show
                return
            }
            UserDefaults.standard.set(true, forKey: Self.keybindHintShownKey)
            self.presentKeybindHint(from: anchor)
        }
    }

    private func presentKeybindHint(from anchor: UIView) {
        let hint = UIViewController()
        hint.modalPresentationStyle = .popover

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Tip: long-press a button to change which command it triggers."
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        hint.view.addSubview(label)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: hint.view.topAnchor, constant: pad),
            label.bottomAnchor.constraint(equalTo: hint.view.bottomAnchor, constant: -pad),
            label.leadingAnchor.constraint(equalTo: hint.view.leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: hint.view.trailingAnchor, constant: -pad),
        ])

        let width: CGFloat = 230
        let textHeight = label.sizeThatFits(CGSize(width: width - pad * 2,
                                                   height: .greatestFiniteMagnitude)).height
        hint.preferredContentSize = CGSize(width: width, height: ceil(textHeight) + pad * 2)

        if let pop = hint.popoverPresentationController {
            pop.delegate = self
            pop.sourceView = anchor
            pop.sourceRect = anchor.bounds
            // Buttons hug the trailing edge, so the popover sits to their left
            // with the arrow pointing right at the button.
            pop.permittedArrowDirections = .right
        }
        present(hint, animated: true)
        keybindHintInFlight = false
    }

    /// Shows a one-time popover over the dungeon explaining the zoom gestures, the
    /// first time a game starts with pinch-zoom available. No-op once shown, when
    /// the feature is off or unavailable (non-iPhone), or if we can't present.
    fileprivate func maybeShowZoomHint() {
        guard !UserDefaults.standard.bool(forKey: Self.zoomHintShownKey),
              !zoomHintInFlight,
              pinchZoomActive,
              view.window != nil,
              presentedViewController == nil else {
            return
        }
        zoomHintInFlight = true
        // Brief delay so it appears after the game screen settles, not instantly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            guard self.pinchZoomActive,
                  self.view.window != nil,
                  self.presentedViewController == nil else {
                self.zoomHintInFlight = false   // retry the next time a game starts
                return
            }
            UserDefaults.standard.set(true, forKey: Self.zoomHintShownKey)
            self.presentZoomHint()
        }
    }

    private func presentZoomHint() {
        let hint = UIViewController()
        hint.modalPresentationStyle = .popover

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Tip: pinch to zoom the map. Two-finger double-tap to zoom all the way out, and again to zoom back in."
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        hint.view.addSubview(label)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: hint.view.topAnchor, constant: pad),
            label.bottomAnchor.constraint(equalTo: hint.view.bottomAnchor, constant: -pad),
            label.leadingAnchor.constraint(equalTo: hint.view.leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: hint.view.trailingAnchor, constant: -pad),
        ])

        let width: CGFloat = 260
        let textHeight = label.sizeThatFits(CGSize(width: width - pad * 2,
                                                   height: .greatestFiniteMagnitude)).height
        hint.preferredContentSize = CGSize(width: width, height: ceil(textHeight) + pad * 2)

        if let pop = hint.popoverPresentationController {
            pop.delegate = self
            // Anchor over the dungeon view, arrow pointing down so the bubble sits
            // above the center rather than over the directional pad at the bottom.
            pop.sourceView = skViewPort
            pop.sourceRect = CGRect(x: skViewPort.bounds.midX, y: skViewPort.bounds.midY,
                                    width: 1, height: 1)
            pop.permittedArrowDirections = .down
        }
        present(hint, animated: true)
        zoomHintInFlight = false
    }

    // Keep it a popover on iPhone rather than auto-adapting to a full-screen sheet.
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }

    /// Only one first-run hint can occupy the popover slot at a time, so they're
    /// chained: when one is dismissed, offer the next still-pending one. Each is
    /// gated on its own "shown" flag, so the one already seen no-ops and only the
    /// remaining hint presents — letting a fresh install see both in one game.
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        maybeShowKeybindHint()
        maybeShowZoomHint()
    }
}
 
extension BrogueViewController {
    @IBAction func escButtonPressed(_ sender: Any) {
        addKeyEvent(event: kESC_Key)
        inputTextField.resignFirstResponder()
        escButtonWanted = false
        refreshEscButtonVisibility()
    }
    
    @IBAction func showInventoryButtonPressed(_ sender: Any) {
        addKeyEvent(event: "i".ascii)
    }
    
    @IBAction func showLeaderBoardButtonPressed(_ sender: Any) {
        NSLog("[GameCenter] leaderboard button pressed")
        let boardID = (currentEngine == .ce) ? GameCenter.ceHighScoreLeaderboardID
                                              : GameCenter.highScoreLeaderboardID
        GameCenter.shared.showLeaderboard(id: boardID, from: self)
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

// MARK: - Pinch-to-zoom (iPhone)

extension BrogueViewController: UIGestureRecognizerDelegate {

    /// Installs the pinch + two-finger-pan recognizers on the SpriteKit viewport.
    /// iPhone only; iPad keeps the flat, un-zoomable scene.
    private func setupZoomGestures() {
        guard isPhoneIdiom else { return }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleZoomPinch(_:)))
        pinch.name = "zoomPinch"
        pinch.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleZoomPan(_:)))
        pan.name = "zoomPan"
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        // Two-finger double-tap toggles fully out to 1× and back to the prior zoom.
        // Distinct from the engine's one-finger double-tap-to-move (different touch
        // count), and its touches never reach the engine (touchesBegan flushes any
        // ≥2-finger touch), so it can't trigger a cursor select or move.
        let toggle = UITapGestureRecognizer(target: self, action: #selector(handleZoomToggleTap(_:)))
        toggle.name = "zoomToggle"
        toggle.numberOfTouchesRequired = 2
        toggle.numberOfTapsRequired = 2
        toggle.delegate = self
        skViewPort.addGestureRecognizer(pinch)
        skViewPort.addGestureRecognizer(pan)
        skViewPort.addGestureRecognizer(toggle)
        zoomPinch = pinch
        zoomPan = pan
        zoomToggle = toggle
    }

    // Pinch + two-finger pan + the two-finger double-tap toggle must run together,
    // but not alongside unrelated recognizers (e.g. the dpad's drag).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let zoomNames: Set<String> = ["zoomPinch", "zoomPan", "zoomToggle"]
        return zoomNames.contains(g.name ?? "") && zoomNames.contains(other.name ?? "")
    }

    // Only zoom when the gesture is centered on the dungeon map — not over the
    // sidebar, message lines, or the bottom button bar. Uses the same play-area
    // helper as touch routing; getCellCoords is zoom-aware so this holds whether
    // or not the map is already zoomed.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        let zoomNames: Set<String> = ["zoomPinch", "zoomPan", "zoomToggle"]
        guard zoomNames.contains(g.name ?? "") else { return true }
        return pointIsInPlayArea(point: g.location(in: view))
    }

    @objc private func handleZoomPinch(_ g: UIPinchGestureRecognizer) {
        guard isPhoneIdiom, gameplayControlsActive || isTargeting else { return }
        switch g.state {
        case .began:
            // Start the pinch from what's actually on screen. Usually the applied
            // transform already equals the canonical zoom, but at game-open the zoom
            // is seeded (zoomScale>1, origin .zero) while the display is still 1×
            // pending the first auto-follow; without this sync the first frame would
            // jump to the seeded scale at origin .zero — i.e. snap to the top-left
            // corner — before the pinch pans it back.
            zoomScale = appliedScale
            zoomOriginPt = appliedOrigin
            pendingLaunchZoom = false // manual zoom supersedes the one-shot launch zoom
            multiTouchGestureActive = true
            clearTouchEvents()       // drop any tap the first finger queued
            clearTravelCursor()      // erase any travel path the first finger drew
            hideMagnifier()          // invalidates the pending magnifier timer too
            lastPinchScale = 1.0     // g.scale resets to 1 at each gesture start
            pinchZoomEngaged = false // dormant until the spread crosses the threshold
        case .changed:
            // Dormant until the cumulative spread (g.scale is relative to gesture
            // start) crosses the activation threshold, so a two-finger pan with
            // incidental spread drift reads as a pure pan. Once latched, zoom and
            // pan coexist for the rest of the gesture (Photos-style).
            if !pinchZoomEngaged {
                guard abs(g.scale - 1.0) >= BrogueViewController.zoomActivationThreshold else {
                    lastPinchScale = g.scale   // keep tracking so engagement has no jump
                    return
                }
                pinchZoomEngaged = true
                lastPinchScale = g.scale       // anchor at current spread: first zoom frame is a no-op
            }
            // Incremental scale about the live two-finger centroid: keep the
            // content point under the centroid fixed as the scale changes. No
            // captured anchor, so no jump; clamped to [1×, max], so no snap-back.
            let factor = g.scale / lastPinchScale
            lastPinchScale = g.scale
            let newScale = min(max(zoomScale * factor,
                                   BrogueViewController.zoomMinScale),
                               BrogueViewController.zoomMaxScale)
            let applied = zoomScale > 0 ? newScale / zoomScale : 1
            let c = g.location(in: view)
            zoomOriginPt = CGPoint(x: c.x - applied * (c.x - zoomOriginPt.x),
                                   y: c.y - applied * (c.y - zoomOriginPt.y))
            zoomScale = newScale
            pushZoom()
        case .ended, .cancelled:
            // Remember the level the player settled on, so the next run starts here.
            storedZoomScale = zoomScale
        default:
            break
        }
    }

    @objc private func handleZoomPan(_ g: UIPanGestureRecognizer) {
        guard isPhoneIdiom, gameplayControlsActive || isTargeting, zoomScale > 1.0 else { return }
        switch g.state {
        case .began:
            // Sync to the on-screen transform (see handleZoomPinch .began): if the
            // canonical zoom is seeded but the display is still 1×, a pan must not
            // apply the seeded scale. After this the guard above re-evaluates each
            // .changed, so panning a 1× display is a no-op until a pinch zooms in.
            zoomScale = appliedScale
            zoomOriginPt = appliedOrigin
            manualPanActive = true
            multiTouchGestureActive = true
            clearTravelCursor()      // erase any travel path the first finger drew
            hideMagnifier()
        case .changed:
            let t = g.translation(in: view)
            zoomOriginPt.x += t.x
            zoomOriginPt.y += t.y
            g.setTranslation(.zero, in: view)
            pushZoom()
        default:
            // Keep manualPanActive set until the next real player move re-centers.
            break
        }
    }

    /// Two-finger double-tap: toggle fully out to 1× and back to the prior zoom.
    /// When zoomed in, remembers the current magnification and eases out to 1×;
    /// when already out, eases back to that remembered level (falling back to the
    /// persisted preference), recentered on the player. The two-finger touches are
    /// suppressed by touchesBegan, so this never leaks a cursor select or move.
    @objc private func handleZoomToggleTap(_ g: UITapGestureRecognizer) {
        guard isPhoneIdiom, pinchZoomActive, gameplayControlsActive || isTargeting else { return }
        clearTouchEvents()   // drop anything the fingers queued before the tap resolved
        hideMagnifier()
        manualPanActive = false
        if zoomScale > 1.0 {
            // Remember the exact view (scale + origin) to come back to, then ease out.
            zoomToggleRestoreScale = zoomScale
            zoomToggleRestoreOrigin = zoomOriginPt
            zoomScale = 1.0
            zoomOriginPt = .zero
            animateZoom(toScale: 1.0, toOrigin: .zero)
        } else {
            // Ease back to the remembered zoom (or the saved preference if none).
            let prior = zoomToggleRestoreScale > BrogueViewController.zoomMinScale
                ? zoomToggleRestoreScale : storedZoomScale
            let target = min(max(prior, BrogueViewController.zoomMinScale),
                             BrogueViewController.zoomMaxScale)
            guard target > 1.0 else { return }   // nothing to restore
            zoomScale = target
            // Pick the recenter target, in priority order — never the (0,0) corner:
            //   1. the live player cell (follow the player, freshest);
            //   2. the origin we captured on the way out (back to the same view);
            //   3. the dungeon-map center (last-resort fallback).
            let origin: CGPoint
            if let cell = lastPlayerWindowCell {
                origin = autoFollowOrigin(playerCell: cell)
            } else if zoomToggleRestoreScale > BrogueViewController.zoomMinScale {
                origin = zoomToggleRestoreOrigin
            } else {
                let f = dungeonFramePoints()
                origin = CGPoint(x: f.midX * (1 - zoomScale), y: f.midY * (1 - zoomScale))
            }
            zoomOriginPt = clampedOrigin(origin, scale: zoomScale)
            animateZoom(toScale: zoomScale, toOrigin: zoomOriginPt)
        }
    }

    /// The dungeon-map rectangle in UIKit points (window cols 21…99, rows 3…30),
    /// mirroring RogueScene.dungeonFrameInScene but in point space.
    private func dungeonFramePoints() -> CGRect {
        let w = skViewPort.effectiveWidthPoints
        let h = skViewPort.effectiveHeightPoints
        let li = skViewPort.leftInsetPoints
        let cw = w / CGFloat(COLS)
        let ch = h / CGFloat(ROWS)
        let left = li + 21 * cw
        let right = li + 100 * cw   // right edge of col 99
        let top = 3 * ch            // top edge of row 3
        let bottom = 32 * ch        // bottom edge of row 31 (full dungeon map)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Clamps the origin so the magnified map always fully covers the dungeon
    /// frame (no empty gutters). Below 1× there's nothing to clamp.
    private func clampedOrigin(_ origin: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 1.0 else { return origin }
        let f = dungeonFramePoints()
        let xLo = f.maxX * (1 - scale), xHi = f.minX * (1 - scale)
        let yLo = f.maxY * (1 - scale), yHi = f.minY * (1 - scale)
        return CGPoint(x: min(max(origin.x, xLo), xHi),
                       y: min(max(origin.y, yLo), yHi))
    }

    private func clampedDisplayScale(_ raw: CGFloat) -> CGFloat {
        if raw >= BrogueViewController.zoomMinScale {
            return min(raw, BrogueViewController.zoomMaxScale)
        }
        // Rubber-band resistance below 1×, with a hard floor.
        let resisted = 1 - (1 - raw) * 0.4
        return max(resisted, BrogueViewController.zoomRubberBandFloor)
    }

    private func pushZoom() {
        zoomOriginPt = clampedOrigin(zoomOriginPt, scale: zoomScale)
        setAppliedZoom(scale: zoomScale, origin: zoomOriginPt)
    }

    /// Origin that centers the player's window cell in the dungeon frame.
    private func autoFollowOrigin(playerCell: CGPoint) -> CGPoint {
        let f = dungeonFramePoints()
        let cw = skViewPort.effectiveWidthPoints / CGFloat(COLS)
        let ch = skViewPort.effectiveHeightPoints / CGFloat(ROWS)
        let li = skViewPort.leftInsetPoints
        // Player cell center in 1× view points.
        let px = li + (playerCell.x + 0.5) * cw
        let py = (playerCell.y + 0.5) * ch
        // Want player at frame center: f.mid = scale·p + origin.
        return CGPoint(x: f.midX - zoomScale * px, y: f.midY - zoomScale * py)
    }

    /// Centers the player's window cell in the dungeon frame (auto-follow), instantly.
    /// Called per player step from the engine thread. When already at full zoom this
    /// applies the pan instantly (lockstep with the cell redraw, no lag). When returning
    /// from a suspended (≈1×) view — e.g. the very move that dismissed an examine/overlay
    /// — it animates the zoom-in instead of snapping. The CADisplayLink is created on the
    /// main thread (where it must live); the instant path only runs once appliedScale has
    /// reached full zoom, so it never races a live link.
    private func applyAutoFollow(playerCell: CGPoint) {
        guard zoomScale > 1.0 else { return }
        let origin = clampedOrigin(autoFollowOrigin(playerCell: playerCell), scale: zoomScale)
        zoomOriginPt = origin
        if appliedScale < zoomScale - 0.001 {
            // Suspended: ease the zoom back in (and keep following — each step retargets
            // the animation toward the latest player cell from the current applied scale).
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.zoomScale > 1.0, !self.manualPanActive else { return }
                self.animateZoom(toScale: self.zoomScale, toOrigin: origin)
            }
        } else {
            applyAppliedTransform(scale: zoomScale, origin: origin)
        }
    }

    /// Engine bridge callback (both engines), reporting the player's window cell
    /// each refresh. Runs auto-follow unless the user is currently looking around.
    ///
    /// Called on the ENGINE thread at the end of `commitDraws`, right after the
    /// changed cells were plotted. We deliberately do NOT hop to the main queue:
    /// re-centering in the same pass as the cell redraw keeps camera and cells in
    /// lockstep. Dispatching to a later runloop left the map a frame behind the
    /// player — a visible stutter when zoomed. This mirrors how `setCell` already
    /// mutates SpriteKit nodes directly from the engine thread in this bridge.
    @objc func setPlayerWindowX(_ x: Int, y: Int) {
        guard isPhoneIdiom else { return }
        let cell = CGPoint(x: x, y: y)
        let moved = (lastPlayerWindowCell != cell)
        lastPlayerWindowCell = cell
        // A run just opened with a remembered zoom: the cell we just recorded may be the
        // last piece the one-shot launch zoom-in was waiting for. Let it own the first
        // zoom-in (don't also auto-follow, which would animate a second time). Hop to
        // main — this runs on the engine thread and the launch zoom drives a CADisplayLink.
        if pendingLaunchZoom {
            DispatchQueue.main.async { [weak self] in self?.runPendingLaunchZoomIfReady() }
            return
        }
        guard gameplayControlsActive, zoomScale > 1.0 else { return }
        // A real move re-establishes follow after a manual look-around.
        if moved { manualPanActive = false }
        if !manualPanActive {
            applyAutoFollow(playerCell: cell)
        }
    }

    /// Suspend-and-restore: engine-drawn overlays (inventory, menus, confirmations)
    /// render into the same dungeon cells, so they'd appear magnified and clipped
    /// off-screen while zoomed. So whenever the game leaves map play
    /// (`gameplayControlsActive` false, and not aiming) we display the map at 1×
    /// — keeping the user's stored zoom intact — and restore it (re-centered on
    /// the player) when normal play resumes. Driven by didSet on the two flags.
    private func updateZoomForGameState() {
        guard isPhoneIdiom else { return }
        // Aiming a throw/zap is map interaction — keep the zoom. An examine
        // description box is treated like an overlay — suspend to 1× so it isn't clipped.
        let onMap = (gameplayControlsActive || isTargeting) && !isExamining
        guard onMap, zoomScale > 1.0 else {
            // Overlay up (or not zoomed): animate the displayed map to 1×. The stored
            // zoomScale / zoomOriginPt are deliberately left untouched. (While a launch
            // zoom is still pending the display is already 1×, so this is a no-op.)
            animateZoom(toScale: 1.0, toOrigin: .zero)
            return
        }
        // A fresh run's first zoom-in is owned by the one-shot launch zoom, which waits
        // for the player's cell so it eases in centered on them — don't also animate here
        // (that double-trigger caused the "snap to 1× then zoom in" jitter).
        if pendingLaunchZoom {
            runPendingLaunchZoomIfReady()
            return
        }
        // Back on the map: animate to the stored zoom, recentered on the player.
        if let cell = lastPlayerWindowCell, !manualPanActive {
            zoomOriginPt = clampedOrigin(autoFollowOrigin(playerCell: cell), scale: zoomScale)
        } else if lastPlayerWindowCell == nil {
            // Run just started with a remembered zoom but no player cell yet: zoom in
            // centered on the dungeon map (never the (0,0) corner) so the game still
            // opens zoomed; the first cell report then recenters on the player.
            zoomOriginPt = mapCenterOrigin(scale: zoomScale)
        } else {
            zoomOriginPt = clampedOrigin(zoomOriginPt, scale: zoomScale)
        }
        animateZoom(toScale: zoomScale, toOrigin: zoomOriginPt)
    }

    /// Resets to 1× (death / return to title), instantly. iPad no-op. The persisted
    /// preference (storedZoomScale) is untouched, so the next run still restores it.
    private func resetZoom() {
        guard isPhoneIdiom else { return }
        zoomScale = 1.0
        zoomOriginPt = .zero
        manualPanActive = false
        lastPlayerWindowCell = nil
        pendingLaunchZoom = false
        setAppliedZoom(scale: 1.0, origin: .zero)
    }

    /// Origin that centers the dungeon map itself in the frame. Used as the recenter
    /// fallback before the player's cell is known, so a zoom-in never defaults to the
    /// (0,0) corner. The first player-cell report then recenters on the player.
    private func mapCenterOrigin(scale: CGFloat) -> CGPoint {
        let f = dungeonFramePoints()
        return clampedOrigin(CGPoint(x: f.midX * (1 - scale), y: f.midY * (1 - scale)), scale: scale)
    }

    /// Begins a run at the player's remembered zoom (iPhone). Seeds zoomScale from the
    /// stored preference but leaves the *display* at 1×, so the zoom EASES in (rather
    /// than snapping) once the map becomes visible — driven by `updateZoomForGameState`
    /// on the gameplay-controls flip, or by the first `setPlayerWindowX` auto-follow,
    /// both of which `animateZoom` from 1× to the stored scale centered on the player.
    /// NOTE: deliberately does NOT clear `lastPlayerWindowCell` — this runs on the main
    /// queue while the engine is already drawing the new level and reporting the player
    /// cell on its thread; clearing it here would wipe that report and the zoom-in would
    /// land on the map center instead of the player. `resetZoom` (title/death) clears it.
    private func restoreStoredZoom() {
        guard isPhoneIdiom else { return }
        manualPanActive = false
        zoomScale = storedZoomScale
        zoomOriginPt = .zero
        setAppliedZoom(scale: 1.0, origin: .zero)
        // Arm the one-shot launch zoom-in; it fires from runPendingLaunchZoomIfReady once
        // we're on the map and the player's cell is known (whichever arrives last).
        pendingLaunchZoom = zoomScale > 1.0
        runPendingLaunchZoomIfReady()

        // First game on iPhone: point out the pinch / two-finger-tap zoom gestures.
        maybeShowZoomHint()
    }

    /// Fires the one-shot launch zoom-in (see `pendingLaunchZoom`). No-op until we're on
    /// the map AND the player's cell is known, so it always eases in from 1× centered on
    /// the player. Runs at most once per `restoreStoredZoom`, regardless of whether the
    /// controls-flip or the first cell report arrives first. Must run on the main thread
    /// (it drives the CADisplayLink animation); the engine-thread caller dispatches.
    private func runPendingLaunchZoomIfReady() {
        guard isPhoneIdiom, pendingLaunchZoom, zoomScale > 1.0,
              gameplayControlsActive || isTargeting, !isExamining,
              let cell = lastPlayerWindowCell else { return }
        pendingLaunchZoom = false
        manualPanActive = false
        zoomOriginPt = clampedOrigin(autoFollowOrigin(playerCell: cell), scale: zoomScale)
        animateZoom(toScale: zoomScale, toOrigin: zoomOriginPt)
    }

    /// Cancels the engine's travel cursor/path by injecting Escape. While the
    /// player is choosing a destination the engine is in its moveCursor loop, and
    /// ESCAPE_KEY (27) there sets `canceled` → `hideCursor()`, erasing the drawn
    /// path. Same keycode and behavior in both engines; harmless if no path is up.
    private func clearTravelCursor() {
        addKeyEvent(event: kESC_Key)
    }

    // MARK: - Bottom button tap-band (iPhone)

    /// True when a touch lands in the reserved band below the grid (iPhone, during
    /// normal play). The band is the fat, easy-to-hit target for the bottom buttons.
    private func isBandTouch(_ point: CGPoint) -> Bool {
        guard isPhoneIdiom, gameplayControlsActive else { return false }
        return point.y >= skViewPort.effectiveHeightPoints
    }

    /// Maps a tap in the bottom band to the nearest of the 5 engine buttons and
    /// replays it as a touch at that button's cell (window row 33), so the engine
    /// fires the button exactly as a direct tap would (Menu opens its submenu, etc.).
    private func handleBandTap(_ point: CGPoint) {
        let width = skViewPort.effectiveWidthPoints
        let height = skViewPort.effectiveHeightPoints
        let leftInset = skViewPort.leftInsetPoints
        guard width > 0, height > 0 else { return }
        let cw = width / CGFloat(COLS)
        let ch = height / CGFloat(ROWS)
        // Column under the finger; ignore the sidebar side of the band (no button).
        let col = Int(CGFloat(COLS) * max(point.x - leftInset, 0) / width)
        guard col >= 21 else { return }
        // A bottom-bar button (incl. Explore) is an action, not an examine — disarm so
        // any description box that auto-appears afterward doesn't suspend the zoom.
        examineArmDebounce?.cancel()
        examineArmed = false
        let centers = BrogueViewController.bottomButtonCenterColumns
        let target = centers.min(by: { abs($0 - col) < abs($1 - col) }) ?? centers[0]
        // Center of the chosen button cell on the button row (33), in view points.
        let p = CGPoint(x: leftInset + (CGFloat(target) + 0.5) * cw, y: (33.0 + 0.5) * ch)
        // Mirror the regular tap path: MOUSE_DOWN (stationary) then MOUSE_UP (ended).
        addTouchEvent(event: UIBrogueTouchEvent(phase: .stationary, location: p))
        addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: p))
        fireHaptic()
    }

    /// Writes a transform to the scene and records it as the current applied state.
    /// Does NOT touch the animation link, so it is safe to call from the engine thread
    /// (per-step auto-follow) — callers guarantee no animation is mid-flight when they
    /// use this directly (appliedScale has already reached the target zoom).
    private func applyAppliedTransform(scale: CGFloat, origin: CGPoint) {
        appliedScale = scale
        appliedOrigin = origin
        skViewPort.applyZoom(scale: scale, originXPoints: origin.x, originYPoints: origin.y)
    }

    /// Instantly applies a zoom transform, cancelling any in-flight animation. MAIN
    /// THREAD only (it touches the CADisplayLink). Used by gestures (pinch/pan) and reset.
    private func setAppliedZoom(scale: CGFloat, origin: CGPoint) {
        cancelZoomAnimation()
        applyAppliedTransform(scale: scale, origin: origin)
    }

    /// Smoothly animates the *applied* transform from where it is now to a target
    /// (smoothstep over zoomAnimDuration). Canonical zoomScale / zoomOriginPt are NOT
    /// touched here — the caller owns those (so a suspend keeps the user's stored zoom).
    private func animateZoom(toScale targetScale: CGFloat, toOrigin targetOrigin: CGPoint) {
        cancelZoomAnimation()
        // Already there → apply instantly, skipping a no-op animation.
        if abs(appliedScale - targetScale) < 0.001,
           abs(appliedOrigin.x - targetOrigin.x) < 0.5,
           abs(appliedOrigin.y - targetOrigin.y) < 0.5 {
            setAppliedZoom(scale: targetScale, origin: targetOrigin)
            return
        }
        zoomAnimStartScale = appliedScale
        zoomAnimStartOrigin = appliedOrigin
        zoomAnimTargetScale = targetScale
        zoomAnimTargetOrigin = targetOrigin
        zoomAnimStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepZoomAnimation(_:)))
        link.add(to: .main, forMode: .common)
        zoomAnimLink = link
    }

    @objc private func stepZoomAnimation(_ link: CADisplayLink) {
        let raw = (CACurrentMediaTime() - zoomAnimStartTime) / zoomAnimDuration
        let t = CGFloat(min(max(raw, 0), 1))
        let e = t * t * (3 - 2 * t) // smoothstep
        let s = zoomAnimStartScale + (zoomAnimTargetScale - zoomAnimStartScale) * e
        let ox = zoomAnimStartOrigin.x + (zoomAnimTargetOrigin.x - zoomAnimStartOrigin.x) * e
        let oy = zoomAnimStartOrigin.y + (zoomAnimTargetOrigin.y - zoomAnimStartOrigin.y) * e
        applyAppliedTransform(scale: s, origin: CGPoint(x: ox, y: oy))
        if t >= 1.0 {
            // Land exactly on target, then stop.
            applyAppliedTransform(scale: zoomAnimTargetScale, origin: zoomAnimTargetOrigin)
            cancelZoomAnimation()
        }
    }

    private func cancelZoomAnimation() {
        zoomAnimLink?.invalidate()
        zoomAnimLink = nil
    }
}

extension BrogueViewController {
    override func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        addKeyEvent(event: kESC_Key)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        // A fresh single-finger touch means any prior pinch/pan is over. Clear the
        // latch here: the gesture recognizer cancels its touches while fingers are
        // still down, so the lift produces no touchesEnded to reset it — leaving it
        // stuck, which made the first post-gesture touch flash the magnifier and
        // then hide it.
        if (event?.allTouches?.count ?? touches.count) <= 1 {
            multiTouchGestureActive = false
        }

        // iPhone (zoom on): a second finger means a pinch / two-finger pan is
        // starting. Flush the tap the first finger queued (so it can't commit a
        // map-move that auto-follow then snaps to), kill any pending magnifier,
        // and stop feeding the engine until all fingers lift.
        if pinchZoomActive, (event?.allTouches?.count ?? touches.count) >= 2 {
            multiTouchGestureActive = true
            clearTouchEvents()
            hideMagnifier()
            return
        }
        // Bottom tap-band: handled on release; swallow the down (before the dpad
        // guard, so the dpad container can't eat band taps) so it never becomes a
        // map-move or pops the magnifier.
        if isBandTouch(touches.first!.location(in: view)) {
            hideMagnifier()
            return
        }

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

        if multiTouchGestureActive || (pinchZoomActive && (event?.allTouches?.count ?? touches.count) >= 2) {
            multiTouchGestureActive = true
            clearTouchEvents()
            hideMagnifier()
            return
        }
        if isBandTouch(touches.first!.location(in: view)) {
            hideMagnifier()
            return
        }

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

        // A multi-touch gesture (pinch / two-finger pan) was in progress: never
        // commit a tap on release — that's what produced the view "snap." Reset
        // once every finger has lifted.
        if multiTouchGestureActive {
            clearTouchEvents()
            hideMagnifier()
            if activeTouchCount(event) == 0 { multiTouchGestureActive = false }
            return
        }

        // Bottom tap-band takes priority over the dpad container and normal
        // routing, so a tap at the very bottom always fires a button.
        if let loc = touches.first?.location(in: view), isBandTouch(loc) {
            handleBandTap(loc)
            hideMagnifier()
            return
        }

        guard dContainerView.hitTest(touches.first!.location(in: dContainerView), with: event) == nil else { return }

        if let touch = touches.first {
            let location = touch.location(in: view)

            // The sidebar-examine (hover-only) routing is meaningful ONLY during
            // active play (the mainInputLoop cursor description box). While a menu
            // or button box is up (gameplayControlsActive == false — buttonInputLoop
            // forces uiMode = InMenu), the engine draws its action-menu buttons
            // (apply/equip/drop/throw…) starting as far left as window column 2, so
            // for long descriptions the leftmost buttons (throw, due to the
            // right-to-left layout) land in the sidebar columns (x <= 20). Routing
            // those through the examine branch sends only a MOUSE_ENTERED_CELL hover
            // and never the MOUSE_UP that activates a button — so the first tap did
            // nothing and the player had to tap again. Treat sidebar-column taps as
            // ordinary clicks whenever we're not in active play.
            if pointIsInSideBar(point: location) && gameplayControlsActive {
                // side bar
                if touch.tapCount >= 2 {
                    // Double-tap acts on the entity (attack / run toward) — not an examine.
                    // Cancel the pending single-tap arm so it never zooms out.
                    examineArmDebounce?.cancel()
                    examineArmed = false
                    addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
                } else {
                    // Single-tap selects an entity → the engine shows its description box.
                    // Defer arming past the double-tap window so a follow-up double-tap
                    // cancels it; only a lone single tap actually suspends the zoom.
                    examineArmDebounce?.cancel()
                    if examineZoomEnabled {
                        let work = DispatchWorkItem { [weak self] in
                            guard let self = self, self.examineBoxShown else { return }
                            self.examineArmed = true
                        }
                        examineArmDebounce = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + examineArmDelay, execute: work)
                    }
                    addTouchEvent(event: UIBrogueTouchEvent(phase: .moved, location: location))
                }
            } else {
                // other touch
                examineArmDebounce?.cancel()
                examineArmed = false
                addTouchEvent(event: UIBrogueTouchEvent(phase: .stationary, location: lastTouchLocation))
                addTouchEvent(event: UIBrogueTouchEvent(phase: .ended, location: lastTouchLocation))
            }
        }
        
        hideMagnifier()
    }

    // When a gesture recognizer (pinch / pan) claims the touches, UIKit cancels
    // them here instead of calling touchesEnded. Flush anything queued so a leaked
    // first-finger touch can't linger, and clear the multi-touch latch on lift.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        clearTouchEvents()
        hideMagnifier()
        if activeTouchCount(event) == 0 { multiTouchGestureActive = false }
    }

    /// Touches still down (not ended/cancelled) in this event.
    private func activeTouchCount(_ event: UIEvent?) -> Int {
        (event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count) ?? 0
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
            // Magnifier is now up: stop any in-progress d-pad press (kills its
            // repeat timer so a held button can't keep moving) and hide the pad.
            directionsViewController?.cancel()
            setDpadHiddenForMagnifier(true)
        }
    }
    
    private func canShowMagnifier(at point: CGPoint) -> Bool {
        // Classic gates on its fine-grained game-event states. CE drives only a
        // coarse uiMode and never sets `lastBrogueGameEvent`, so use the shared
        // `gameplayControlsActive` flag (true exactly when CE reports normal
        // play, set in applyCEUIMode) to allow the magnifier there.
        // CE drives only a coarse uiMode and never sets `lastBrogueGameEvent`, so
        // allow the magnifier during normal play (gameplayControlsActive) and also
        // while aiming a throw/zap (isTargeting), where it helps the player see the
        // target cell under their finger.
        // Never while pinching / two-finger panning the map — the magnifier would
        // fight the gesture and lag behind the moving cells.
        guard !zoomGestureInProgress else { return false }
        let engineAllowsMagnifier = currentEngine.isCEFamily
            ? (gameplayControlsActive || isTargeting)
            : lastBrogueGameEvent.canShowMagnifyingGlass
        guard engineAllowsMagnifier, pointIsInPlayArea(point: point) else {
            return false
        }
        // iPhone: suppress the magnifier over the chrome rows — the flavor line
        // (row 32) and the button bar (row 33) — so it doesn't pop up when the
        // player is aiming for a button. Row 31 is now pure dungeon (the bottom
        // map row), so the magnifier is allowed there. Not suppressed while
        // targeting, when the buttons are hidden.
        if UIDevice.current.userInterfaceIdiom == .phone, !isTargeting {
            let cell = getCellCoords(at: point, viewport: skViewPort)
            if cell.y >= 32 {
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
            magnifierTimer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(BrogueViewController.handleMagnifierTimer), userInfo: nil, repeats: false)
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
        setDpadHiddenForMagnifier(false)
        DispatchQueue.main.async {
            self.magView.hideMagnifier()
        }
    }

    /// Hides the directional pad while the magnifier is up, and restores it when the
    /// magnifier goes away. Restoration defers to refreshDirectionPadVisibility() — the
    /// single source of truth — so it honors BOTH gameplay state AND hardware-keyboard
    /// presence. (Restoring via `!gameplayControlsActive` alone re-showed the d-pad
    /// after a magnifier dismissal even with a keyboard attached — e.g. on every mouse
    /// click, which drives the touch/magnifier path.)
    private func setDpadHiddenForMagnifier(_ hidden: Bool) {
        if hidden {
            dContainerView.isHidden = true
        } else {
            refreshDirectionPadVisibility()
        }
    }
}

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
    fileprivate func addKeyEvent(event: UInt8) {
        addKeyEvent(code: event, shift: false, control: false, raw: false)
    }

    // iOS port (iBrogue): full hardware-key enqueue carrying modifiers and the `raw` (scheme-eligible) flag.
    fileprivate func addKeyEvent(code: UInt8, shift: Bool, control: Bool, raw: Bool) {
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
        synchronized { !keyEvents.isEmpty }
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
    fileprivate func setupHardwareKeyboardObserver() {
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
        hardwareKeyboardConnected = connected
        setHardwareKeyboardConnected(connected ? 1 : 0)
        ce_setHardwareKeyboardConnected(connected ? 1 : 0)
        se_setHardwareKeyboardConnected(connected ? 1 : 0)
        DispatchQueue.main.async { [weak self] in
            self?.refreshDirectionPadVisibility()
            self?.refreshEscButtonVisibility()
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

// MARK: - SKMagView

final class SKMagView: SKView {
    var viewToMagnify: SKViewPort?

    /// iPhone "left-handed" mode: place the magnifier to the RIGHT of the finger
    /// instead of the left, so a left hand gripping the device doesn't cover it.
    /// No effect on iPad (which hovers the magnifier above the touch).
    var leftHandMode: Bool = false

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

        // iPhone: ALWAYS place beside the finger — to the left by default, or to
        // the right in left-handed mode (so the gripping hand never covers it).
        // iPad: only flip left when the above-touch default would clip the top.
        // Either way the magnifier sits beside the finger, never under it.
        //
        // TWEAK ME: `flipPadding` is the gap between the finger and the nearer
        // edge of the magnifier when it sits beside it. Bigger = further away.
        let flipPadding: CGFloat = 38
        if isPhone && leftHandMode {
            c.x = point.x + radius + flipPadding   // to the RIGHT of the finger
            c.y = point.y
        } else if isPhone || c.y - radius < bounds.minY {
            c.x = point.x - radius - flipPadding    // to the LEFT of the finger
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
            // Measure the sub-cell offset in the SAME space currentCellXY came
            // from. getCellCoords un-zooms internally, so when the dungeon map is
            // pinch-zoomed the raw touch point is in zoomed space while the cell
            // index is in 1× space — using `point` here would put the content
            // wildly off-center. Un-zoom the point so both agree; across one
            // on-screen (zoomed) cell the un-zoomed point sweeps exactly one cell.
            let unzoomed = viewToMagnify.unzoomedPoint(point)
            let xMouseOffset = (unzoomed.x - leftInset - (currentCellXY.x * (viewToMagnify.rogueScene.cells[0][0].size.width / screenScale))) * magnificationOffset
            let yMouseOffset = (unzoomed.y - (currentCellXY.y * (viewToMagnify.rogueScene.cells[0][0].size.height / screenScale))) * magnificationOffset
            
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
