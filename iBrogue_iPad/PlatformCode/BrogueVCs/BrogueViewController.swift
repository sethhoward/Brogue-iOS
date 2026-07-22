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

let kESC_Key: UInt8 = 27
let kReturnKey: UInt8 = 13
fileprivate let kEnterKey: UInt8 = 10
let kDeleteKey: UInt8 = 127
let kTabKey: UInt8 = 9

private let eventLock = NSLock()

func synchronized<T>(_ body: () throws -> T) rethrows -> T {
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

// Shared by BrogueViewController and SKMagView (SKMagView.swift), so internal, not fileprivate.
@MainActor func getCellCoords(at point: CGPoint, viewport: SKViewPort?, reach: Bool = false) -> CGPoint {
    let screenH = UIScreen.main.bounds.size.height
    let screenW = UIScreen.main.bounds.size.width
    // When the dungeon map is pinch-zoomed, invert the zoom transform so a
    // touch resolves to the cell actually under the finger. No-op at 1× and
    // for points outside the zoomable map (sidebar, messages, button bar).
    // `reach` extends the inverse over the sidebar columns for the held-magnifier
    // "map under sidebar" drag (see SKViewPort.unzoomedPoint(_:reach:)).
    let point = viewport?.unzoomedPoint(point, reach: reach) ?? point
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
    /// True when this touch belongs to a held-magnifier drag reaching under the
    /// translucent sidebar ("map under sidebar"): the bridge must then invert the zoom
    /// over the sidebar columns so the commit lands on the magnified map cell rather than
    /// a sidebar entity. Carried per-event (not a shared flag) because the bridge resolves
    /// coordinates on the engine thread at dequeue time — a main-thread flag would race the
    /// commit as the finger lifts. Stamped in `addTouchEvent`; read by the CE/SE host stash
    /// and by the Classic RogueDriver bridge.
    @objc var reachUnderSidebar: Bool = false

    required init(phase: UITouch.Phase, location: CGPoint) {
        self.phase = phase
        self.location = location
    }

    required init(touchEvent: UIBrogueTouchEvent) {
        phase = touchEvent.phase
        location = touchEvent.location
        reachUnderSidebar = touchEvent.reachUnderSidebar
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
    var ceHost: CEHost?
    /// The engine currently running on `engineThread`.
    var currentEngine: EngineKind = .classic
    /// Advertises the in-progress CE / Brogue SE run to the user's other nearby devices via
    /// Continuity Handoff. Classic is never advertised (its recordings are desync-prone and
    /// unsafe to replay). See docs/design/game-handoff.md.
    let gameHandoff = GameHandoff()
    /// Set when a received handoff is waiting for the engine to reach its title so it can be booted
    /// into the run (consumed in `setCEAtTitle`). See docs/design/game-handoff.md.
    var handoffResumePending: EngineKind?
    /// True on the SOURCE while a handoff transfer is in flight: input is starved so the run can't
    /// advance a turn that would be lost on relinquish. See docs/design/game-handoff.md.
    var handoffInFlight = false
    /// Matches HANDOFF_RELINQUISH_KEY in each engine's Rogue.h — injected to end the run silently once
    /// the receiver confirms (deep ACK).
    static let handoffRelinquishKey: UInt8 = 128 + 22
    weak var handoffOverlay: UIView?
    /// The background thread running the active engine's `rogueMain`.
    var engineThread: Thread?
    /// Set while a title-screen engine swap is in flight (awaiting clean exit).
    var switchPending = false
    /// The engine to boot once the outgoing one exits during a swap. Captured at
    /// request time so the 3-way cycle can move to a specific target (not just flip).
    var pendingTargetEngine: EngineKind?
    /// The title-screen version-chooser chip and its label.
    var versionChooser: UIView?
    var versionChooserLabel: UILabel?
    /// Fades the chooser out after a few seconds so it isn't a persistent distraction.
    var versionChooserFadeTimer: Timer?
    /// Title-screen options button (lower-left). Universal across Classic and CE.
    var optionsButton: UIButton?
    /// Title-screen info button, beside the options button. Pops an engine-aware
    /// description of the selected engine's key features.
    var infoButton: UIButton?
    /// True while the active engine is showing its title screen (chooser visible).
    var atTitle = false { didSet {
        updateVersionChooserVisibility(); updateTitleOptionsVisibility()
        // Menu magnify is only ever engaged while at the title, so leaving it (to a run, High
        // Scores, recordings, death, …) is the single point that must always tear it down.
        if !atTitle { tearDownMenuMagnify() }
    } }
    var touchEvents = [UIBrogueTouchEvent]()
    var lastTouchLocation = CGPoint()
    @objc var directionsViewController: DirectionControlsViewController?
    // iOS port (iBrogue): a queued key carries its modifier state and a `raw` flag. `raw` is true only
    // for real hardware character keys that the active keyboard scheme should remap; synthesized input
    // (on-screen d-pad/buttons, ESC, text entry, arrows) is already canonical and passes through.
    struct QueuedKeyEvent {
        let code: UInt8
        let shift: Bool
        let control: Bool
        let raw: Bool
    }
    var keyEvents = [QueuedKeyEvent]()
    var magnifierTimer: Timer?
    var inputRequestString: String?

    // iOS port (iBrogue): hardware key-repeat. iOS `pressesBegan` fires once per physical press (unlike
    // desktop SDL, which repeats natively), so holding a movement/rest/search key would only step once.
    // We synthesize repeats with a timer: a held, repeat-eligible key re-enqueues itself after an initial
    // delay, then at a steady interval. See keyRepeatInitialDelay/keyRepeatInterval and isRepeatable(...).
    var keyRepeatTimer: Timer?
    var repeatingKey: QueuedKeyEvent?
    // iOS port (Brogue SE): kept at a safe 0.3s as a tap-vs-hold guard. A physical key tap lasts ~100-150ms,
    // so a shorter delay (we briefly tried 0.1s to match the d-pad) makes a normal tap auto-repeat into an
    // accidental second step. Because 0.3s is ABOVE the noise system's pre-roll window
    // (NOISE_RIPPLE_PREROLL_MS in Rogue.h, 160ms), the first step of a HELD keyboard direction can't be
    // recognised as continuous movement and animates one "you heard something" tick before repeats begin --
    // this is the documented graceful degradation (see KNOWN_CAVEATS.md "Noise system / movement key-repeat"),
    // accepted in favour of correct tap behaviour. The d-pad (DirectionControlsViewController.m) uses 0.1s
    // instead: a touch tap is shorter than a key tap, so it stays under the pre-roll and gets full
    // first-step suppression without accidental steps.
    let keyRepeatInitialDelay: TimeInterval = 0.3
    let keyRepeatInterval: TimeInterval = 0.1

    // ── Safe-area action buttons ─────────────────────────────────────────
    // A small column of buttons in the iPhone notch / dynamic-island safe-area
    // strip (the right edge in our landscape-left lock). Tapping a button injects
    // its bound Brogue keystroke; long-pressing opens a menu to rebind it (saved
    // to UserDefaults). The button face is always the literal bound key character.

    /// A bindable Brogue command: the key it sends, a human-readable name (from
    /// the engine's help screen), and the group it belongs to.
    struct Command {
        let key: UInt8
        let name: String
        let category: String
        /// CE-only commands (e.g. re-throw) are hidden from the rebind menus
        /// while the Classic engine is active, since 1.7.5 doesn't handle them.
        var ceOnly: Bool = false
        /// SE-only commands (e.g. re-apply staff) are shown only while Brogue SE
        /// is active, since neither Classic nor CE handles them.
        var seOnly: Bool = false
    }

    /// Canonical key code for the SE re-apply-last-staff command (REAPPLY_KEY in
    /// Rogue.h, `128+20`). Sent directly (raw) so it bypasses keyboard-scheme
    /// remapping and means re-apply in every scheme.
    private static let reapplyKeyCode: UInt8 = 128 + 20

    /// Synthetic key for "Continue travel" — resume the interrupted journey. Matches
    /// CONTINUE_TRAVEL_KEY (128+21) in all three engines; the engine re-runs travel to the
    /// still-pending destination (rogue.cursorLoc). Not a physical key. Present in every engine
    /// (no `seOnly`/`ceOnly`), so the one button code dispatches wherever it's loaded.
    static let continueTravelKeyCode: UInt8 = 128 + 21

    /// Commands a side button may be bound to. Names mirror printHelpScreen().
    static let commandCatalog: [Command] = [
        // Stairs & Travel
        Command(key: ">".ascii, name: "Descend",           category: "Stairs & Travel"),
        Command(key: "<".ascii, name: "Ascend",            category: "Stairs & Travel"),
        Command(key: "x".ascii, name: "Auto-explore",      category: "Stairs & Travel"),
        Command(key: continueTravelKeyCode, name: "Continue travel", category: "Stairs & Travel"),
        // Resting & Waiting
        Command(key: "z".ascii, name: "Rest once",         category: "Resting & Waiting"),
        Command(key: "Z".ascii, name: "Rest until better", category: "Resting & Waiting"),
        Command(key: "s".ascii, name: "Search",            category: "Resting & Waiting"),
        // Item Actions
        Command(key: "e".ascii, name: "Equip",             category: "Item Actions"),
        Command(key: "r".ascii, name: "Remove",            category: "Item Actions"),
        Command(key: "a".ascii, name: "Apply / use",       category: "Item Actions"),
        Command(key: reapplyKeyCode, name: "Re-apply staff", category: "Item Actions", seOnly: true),
        Command(key: "t".ascii, name: "Throw",             category: "Item Actions"),
        Command(key: "T".ascii, name: "Re-throw at last monster", category: "Item Actions", ceOnly: true),
        Command(key: "d".ascii, name: "Drop",              category: "Item Actions"),
        Command(key: "c".ascii, name: "Call",              category: "Item Actions"),
        Command(key: "R".ascii, name: "Relabel",           category: "Item Actions"),
    ]

    /// Section order for the rebind menu.
    static let commandCategoryOrder = ["Stairs & Travel", "Resting & Waiting", "Item Actions"]

    /// SF Symbol shown on a button face for each bindable command key. Keyed by
    /// the same `UInt8` keys as `commandCatalog`; the engine still receives the
    /// key on tap, so this only controls appearance.
    private static let commandSymbols: [UInt8: String] = [
        ">".ascii: "arrow.down.to.line",
        "<".ascii: "arrow.up.to.line",
        "x".ascii: "map",
        continueTravelKeyCode: "shoeprints.fill",
        "z".ascii: "zzz",
        "Z".ascii: "bed.double.fill",
        "s".ascii: "magnifyingglass",
        "e".ascii: "shield.lefthalf.filled",
        "r".ascii: "xmark.shield",
        "a".ascii: "wand.and.stars",
        reapplyKeyCode: "wand.and.rays",
        "t".ascii: "paperplane.fill",
        "T".ascii: "paperplane.circle.fill",
        "d".ascii: "arrow.down.circle",
        "c".ascii: "tag",
        "R".ascii: "textformat.abc",
    ]

    /// SF Symbol name for a bound key. The center button's "Nothing" sentinel
    /// maps to a slashed circle; anything unmapped falls back to it too.
    static func symbolName(for key: UInt8) -> String {
        commandSymbols[key] ?? "circle.slash"
    }

    /// Rebind-menu row title. Printable-ASCII commands show their key, e.g. "Throw (t)";
    /// synthetic commands (Continue travel, Re-apply staff) have no meaningful character, so
    /// they show just the name rather than a control-character glyph in parentheses.
    static func commandMenuTitle(_ command: Command) -> String {
        if command.key >= 32 && command.key < 127 {
            return "\(command.name) (\(Character(UnicodeScalar(command.key))))"
        }
        return command.name
    }

    /// Point size / weight for button-face glyphs, matched to the old text scale.
    static let buttonSymbolConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)

    /// Default key per slot (top→bottom): throw, apply/use, rest-until-better, descend.
    /// (Auto-explore and search are omitted here — they have dedicated bottom-row buttons.)
    static let defaultSideButtonKeys: [UInt8] = ["t".ascii, "a".ascii, "Z".ascii, ">".ascii]
    static let sideButtonKeysDefaultsKey = "sideButtonKeys"

    /// Current key bound to each of the four slots; persisted to UserDefaults.
    var sideButtonKeys: [UInt8] = BrogueViewController.loadSideButtonKeys()

    var actionButtons: [UIButton] = []

    // ── Directional-pad center button ────────────────────────────────────
    // A fifth programmable button living in the dead zone at the center of the
    // directional pad (storyboard outlet on the D-pad VC, so it drags/hides with
    // it). Like the side buttons but, uniquely, it may be set to "Nothing".

    /// Sentinel binding meaning the center button does nothing when tapped.
    static let centerButtonNothing: UInt8 = 0
    /// Center button's out-of-box binding: "Continue travel" — the reactive continue/rest button.
    /// When bound to this key the center button continues a pending journey and falls back to Rest
    /// once when idle (see `centerButtonEffectiveKey`). Only affects players who have never rebound
    /// the center button; the stored binding is honored otherwise (loadCenterButtonKey).
    static let centerButtonDefaultKey: UInt8 = continueTravelKeyCode
    static let centerButtonKeyDefaultsKey = "directionCenterButtonKey"

    /// Key bound to the center button; `centerButtonNothing` (0) = unbound.
    var centerButtonKey: UInt8 = BrogueViewController.loadCenterButtonKey()

    /// Whether the engine currently has a pending travel destination (reported per-turn by the
    /// bridge via `setTravelPending`). Drives the reactive center button: continue when true,
    /// Rest once when false.
    var isTravelPending = false

    // ── Directional-pad position ─────────────────────────────────────────
    // The pad can be two-finger-dragged. We persist that offset (one key,
    // shared by Classic and CE) and apply it as a transform rather than by
    // mutating `.center`: layout passes — e.g. opening a shortcut button's
    // context menu — reset `.center` back to its constraint position, but
    // leave `.transform` alone. So driving position via transform keeps the
    // pad put across menus and across relaunches.
    static let dpadOffsetDefaultsKey = "directionPadUserOffset"

    /// Base translation applied before the user's drag. iPhone tucks the pad
    /// tighter into the corner; iPad keeps the storyboard position.
    var dpadBaseTranslation: CGPoint {
        UIDevice.current.userInterfaceIdiom == .phone ? CGPoint(x: -80, y: 100) : .zero
    }

    /// User's accumulated two-finger-drag offset, persisted across launches.
    var dpadUserOffset: CGPoint = BrogueViewController.loadDpadOffset()

    /// Transient, NON-persisted horizontal correction that lifts the d-pad clear
    /// of the notch-side safe area in whichever landscape it would otherwise hide
    /// under the cutout. Recomputed on launch and on rotation; never saved, so the
    /// user's flush/default placement is preserved in the non-notch orientation.
    var dpadNotchAvoidance: CGFloat = 0

    /// Resting opacity of the directional pad (semi-transparent so the map shows
    /// through). Also the alpha the pad fades back to after a sidebar-scrub fade-out.
    static let dpadRestingAlpha: CGFloat = 0.3
    /// True while the d-pad is faded out for an in-progress sidebar scrub, so the fade
    /// fires once per scrub and the restore is a no-op when nothing was faded.
    var dpadFadedForSidebarScrub = false

    /// Extra points the notch-avoidance nudge clears the safe-area inset by.
    /// Higher = pad sits further from the cutout; can go to 0 (flush to the inset)
    /// or negative (allow slight overlap). Tune to taste.
    static let dpadNotchClearanceMargin: CGFloat = -20

    // MARK: - Haptics
    //
    // Tactile feedback lives in HapticsController (HapticsController.swift). These stay
    // on the VC as thin forwarders because the C engine bridges call them by selector on
    // BrogueViewController (RogueDriver.mm's global pointer and CEHost).
    let hapticsController = HapticsController()

    @objc func playerTookDamage(_ severity: Int) { hapticsController.playDamage(severity: severity) }
    @objc func noiseDetectionHaptic(_ stage: Int) { hapticsController.playNoiseDetection(stage: stage) }
    @objc func environmentalNoiseHaptic(_ kind: Int) { hapticsController.playEnvironmentalNoise(kind: kind) }

    /// iPhone "left-handed" magnifier mode: when on, the magnifier sits to the
    /// right of the finger instead of the left. Persisted; iPhone-only option.
    static let leftHandMagnifierDefaultsKey = "leftHandMagnifier"
    var leftHandMagnifier: Bool =
        UserDefaults.standard.bool(forKey: leftHandMagnifierDefaultsKey) // default off (right-handed)

    /// iPhone pinch-to-zoom (dungeon map) is always on; there is no user toggle.
    /// True only on the iPhone idiom, where the zoomable scene exists (iPad keeps
    /// the flat, un-zoomable grid).
    var pinchZoomActive: Bool { isPhoneIdiom }

    /// When on (default), single-tapping a sidebar entity zooms out to 1× so its
    /// description box isn't clipped while zoomed. Toggleable in Options.
    var examineZoomEnabled: Bool = RogueScene.isExamineZoomEnabledSetting

    /// When on (default), the zoomed dungeon renders full-width under a translucent
    /// sidebar and a held-magnifier drag can reach the map cells behind it. Toggleable
    /// in Options; iPhone-only (the reveal only applies while zoomed).
    var mapUnderSidebarEnabled: Bool = RogueScene.isMapUnderSidebarEnabledSetting

    /// Latched true while a held-magnifier drag is permitted to reach map cells under the
    /// sidebar: set when the loupe arms over a play-area-origin gesture with the reveal
    /// active (zoomed + enabled), cleared on finger-lift / a fresh touch. Stamped onto each
    /// enqueued touch event (`addTouchEvent`) so the commit resolves in map space even
    /// after this flag is cleared, and mirrored to `magView.sidebarReach` for the loupe.
    var sidebarReachLatched = false {
        didSet {
            guard oldValue != sidebarReachLatched else { return }
            magView?.sidebarReach = sidebarReachLatched
        }
    }

    /// True once this process has gone to the background at least once. Distinguishes a warm
    /// foreground (we backgrounded earlier and the process survived) from a cold launch (a fresh
    /// process after an OS kill, where didBecomeActive also fires). The background suspend/resume
    /// flow uses it to clear a stale resume marker only on a warm foreground — never on cold launch,
    /// where the engine must consume the marker to resume. See docs/design/background-suspend-resume.md.
    var didBackgroundThisProcess = false

    /// Mirrors the directional pad's visibility: true while the player is
    /// actively moving around the dungeon, false on menus/dialogs/title.
    var gameplayControlsActive = false {
        didSet { if oldValue != gameplayControlsActive { updateZoomForGameState() } }
    }

    /// Whether a hardware keyboard is currently attached. When true, the on-screen d-pad and the
    /// ESC button are hidden (redundant with the keyboard's arrows / Escape key); the engines also
    /// surface a "Press <?> for help" hint. Updated by the GCKeyboard observer.
    var hardwareKeyboardConnected = false

    /// Whether the app logic currently wants the on-screen ESC button shown (escapable sub-screen,
    /// active text entry, etc.). The button is only actually shown when this is true AND no hardware
    /// keyboard is attached — see refreshEscButtonVisibility().
    var escButtonWanted = false

    /// True while the player is aiming a throw/zap (CE targeting loop). Reported
    /// by the engine via setCETargeting; moves the esc button aside and re-enables
    /// the magnifier so the player can see what they're aiming at.
    var isTargeting = false {
        didSet { if oldValue != isTargeting { updateZoomForGameState() } }
    }

    /// Derived: suspend zoom only when a description box is shown AND it was armed by a
    /// sidebar selection. Recomputed whenever either input below changes, so the order in
    /// which they arrive doesn't matter (the engine's box signal can race ahead of the
    /// arm set in touchesEnded). didSet drives the suspend/restore animation.
    var isExamining = false {
        didSet { if oldValue != isExamining { updateZoomForGameState() } }
    }
    /// True while the engine is showing a creature/item description box (reported by both
    /// engines via setExamining). On its own it does NOT suspend zoom — it must be armed.
    var examineBoxShown = false {
        didSet {
            guard oldValue != examineBoxShown else { return }
            if !examineBoxShown {
                examineArmDebounce?.cancel()                  // box gone → drop a pending arm
                examineArmed = false                          // …and require a fresh sidebar tap
                examineBox = nil                              // …and forget its rect
                examineFromSidebar = false                    // …and its sidebar-tap provenance
            }
            isExamining = examineBoxShown && examineArmed
        }
    }
    /// The window-cell rect of the on-screen examine description box, reported by SE just
    /// before `setExamining:true` (see setExamineBox). Lets the examine zoom fit the box
    /// rather than dropping all the way to 1×. nil when no box is shown or the engine didn't
    /// report one (CE / Classic) — those keep the 1× zoom-out.
    struct ExamineBox { let x: Int; let y: Int; let w: Int; let h: Int }
    var examineBox: ExamineBox?

    /// iOS port (iBrogue): window-cell rect of the currently-shown modal menu overlay, reported by
    /// the engine (setMenuBox). Phase 0 uses it to auto-magnify the title menu / its dialogs to a
    /// readable, tappable size on iPhone — instantly, no camera movement. nil when no menu is up.
    struct MenuBox: Equatable { let x: Int; let y: Int; let w: Int; let h: Int }
    var menuBox: MenuBox?
    /// True while the full-grid menu magnify is engaged, so apply/clear are idempotent and we know
    /// to tear it down when leaving the title.
    var menuMagnifyEngaged = false
    /// Set only by a sidebar single-tap; gates the zoom-suspend so deliberate sidebar
    /// selections suspend but auto-appearing boxes (auto-explore stopping on an item, a
    /// tap-to-move over a monster) do not. Cleared when the box ends and on competing inputs.
    var examineArmed = false {
        didSet {
            guard oldValue != examineArmed else { return }
            isExamining = examineBoxShown && examineArmed
        }
    }
    /// True the instant a sidebar single-tap selects an entity, until that examine ends or a
    /// fresh input arrives. Unlike `examineArmed` (deferred 0.3s for double-tap protection),
    /// this is set immediately, so it's already true when the engine draws the box a frame
    /// later — the box is drawn once and `moveCursor` then blocks, so a deferred flag would
    /// suppress it forever. It's the "show this box" signal: a deliberate sidebar tap shows
    /// (and zooms out); every *other* box while zoomed — auto-explore stopping on an entity,
    /// a play-field drag-hold, hover, tab-cycle — is suppressed (it would tear against the
    /// 1× sidebar). See `shouldSuppressExamineBox`.
    var examineFromSidebar = false
    /// Deferred arm: a sidebar single-tap schedules arming after the double-tap window
    /// so a double-tap (attack/run toward) cancels it first and never zooms out.
    var examineArmDebounce: DispatchWorkItem?
    /// How long to wait before a sidebar single-tap arms the examine zoom — long enough
    /// to let a second tap (double-tap) arrive and cancel it.
    let examineArmDelay: TimeInterval = 0.3
    /// The escape button's resting transform, captured so it can be restored after
    /// being moved to the lower-left corner during targeting.
    var savedEscTransform: CGAffineTransform?

    // ── Pinch-to-zoom (iPhone only) ──────────────────────────────────────
    // Canonical zoom state, in UIKit point space. `zoomScale` is the
    // magnification; `zoomOriginPt` positions the magnified map so a touch `p`
    // inverts to `(p - origin) / scale` (see SKViewPort.unzoomedPoint). Pushed
    // to the scene via skViewPort.applyZoom. Persists across levels; on the title
    // and on death the *display* drops to 1×, but the magnification is remembered
    // (see zoomScaleDefaultsKey) and carries into the next run. iPad never zooms
    // (gestures aren't installed).
    static let zoomMinScale: CGFloat = 1.0
    static let zoomMaxScale: CGFloat = 2.5
    static let zoomRubberBandFloor: CGFloat = 0.8
    /// Cap for the examine fit-zoom (see examineFitZoom). Below zoomMaxScale so a small
    /// description box doesn't blow up to full magnification (which read as "too far") —
    /// it keeps the box legible while leaving surrounding map context. Tunable.
    static let examineMaxScale: CGFloat = 1.8
    /// User-adjustable cap for the menu fit-magnify (see menuFitZoom), set via Options ▸ Menu size.
    /// The value IS the maximum magnification the menu panels use: menuScaleMin (1.0) turns the
    /// magnify off (menus render at 1×), up to menuScaleMax. On a portrait phone the vertical fit
    /// often binds below this anyway. Persisted; absent key → menuScaleDefault.
    static let menuScaleDefaultsKey = "menuMagnifyScale"
    static let menuScaleDefault: CGFloat = 1.3
    static let menuScaleMin: CGFloat = 1.0
    static let menuScaleMax: CGFloat = 1.4
    static var menuMagnifyScaleSetting: CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: menuScaleDefaultsKey) != nil else { return menuScaleDefault }
        return min(menuScaleMax, max(menuScaleMin, CGFloat(defaults.double(forKey: menuScaleDefaultsKey))))
    }
    /// Fractional finger-spread change required before a pinch starts zooming.
    /// Below this, a two-finger drag is treated as a pure pan (Photos-style).
    static let zoomActivationThreshold: CGFloat = 0.20   // 10%
    /// UserDefaults key for the player's preferred dungeon magnification. Persisted
    /// so the zoom level carries between game runs and across app launches; the
    /// origin is intentionally not stored (each run recenters on the player).
    private static let zoomScaleDefaultsKey = "preferredZoomScale"

    // ── Camera-follow smoothing (iPhone zoom) — TWEAK ME ─────────────────────────
    // These govern how the magnified map follows the player when zoomed in. Without
    // them the camera *snapped* the player to center every step, so at 2.5× each tile
    // was a ~20pt teleport — poppy when moving slowly, chunky when travelling. Now the
    // camera EASES: a continuous trailing lerp during normal movement (player rides
    // slightly ahead of center, glides back to dead-center on stop), a one-shot
    // cinematic pan for a discrete same-level jump (teleport / long blink / returning
    // from a two-finger scout-pan), and an instant snap on a true level change (the old
    // origin means nothing on the new map — see setPlayerWindowX's `depth`). iPhone only.

    /// Master switch. When false, auto-follow reverts to the pre-smoothing behavior
    /// (instant re-center each step, applied in lockstep on the engine thread) — flip
    /// it off to A/B the new feel against the old one.
    static let followSmoothingEnabled = true
    /// Trailing-lerp time constant (seconds) for normal movement. Each frame the applied
    /// origin closes the gap to the player-centered target exponentially with this time
    /// constant, so it's frame-rate independent. **Smaller** = tighter follow, less drift
    /// (player stays nearer center, but a single step is snappier); **larger** = smoother,
    /// but the player rides further ahead during fast travel. Governs BOTH the single-step
    /// ease and the fast-travel trail.
    static let followTimeConstant: CFTimeInterval = 0.10
    /// Camera-travel distance (in dungeon tiles) above which a same-level jump stops being
    /// absorbed by the trail and instead gets the one-shot cinematic pan. A short blink
    /// below this just eases over via the normal trail. **Must stay above the steady
    /// fast-travel trail** (≈ 40·followTimeConstant tiles at ~40 steps/sec, so ≈4 tiles at
    /// the default) or sustained travel would keep (wrongly) tripping the pan.
    static let followPanTriggerTiles: CGFloat = 6
    /// Duration (seconds) of the one-shot cinematic pan. **Fixed regardless of distance**
    /// and smoothstep-eased (accelerate then decelerate), so a long teleport swoops faster
    /// on screen but never whips. Larger = more overtly cinematic / slower.
    static let followPanDuration: CFTimeInterval = 0.35

    /// Center columns of the 5 engine bottom buttons (Explore/Rest/Search/Menu/
    /// Inventory), mirroring initializeMenuButtons in BrogueCode/IO.c (starts
    /// 21/38/53/68/81, widths 15/13/13/11/15). Both engines share this layout.
    /// Used to snap bottom tap-band touches to the nearest button.
    static let bottomButtonCenterColumns = [28, 44, 59, 73, 88]
    var zoomScale: CGFloat = 1.0
    var zoomOriginPt: CGPoint = .zero
    /// The persisted preferred zoom magnification, clamped to the valid range.
    /// An absent/zero default reads back as 1× (no zoom).
    var storedZoomScale: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: BrogueViewController.zoomScaleDefaultsKey))
            guard v >= BrogueViewController.zoomMinScale else { return BrogueViewController.zoomMinScale }
            return min(v, BrogueViewController.zoomMaxScale)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: BrogueViewController.zoomScaleDefaultsKey) }
    }
    /// Previous UIPinchGestureRecognizer.scale, for incremental scale-about-
    /// centroid updates (jump-free, vs. a captured-anchor recompute).
    var lastPinchScale: CGFloat = 1.0
    /// True from the moment a second finger lands (or a zoom gesture begins)
    /// until all fingers lift. While set, raw touches are NOT fed to the engine,
    /// so the first finger of a pinch/pan can't leak a tap/travel that would
    /// snap the view via auto-follow.
    var multiTouchGestureActive = false
    /// iOS port (iBrogue): the screen zone where the current single-finger gesture
    /// began, latched on touch-down and used to route the WHOLE gesture (see
    /// `gestureOriginZone`). A gesture commits only when it lifts in the same zone it
    /// started in — so a swipe up from the bottom band (or the home-indicator strip)
    /// can't leak into a play-field travel/move as the finger crosses into the grid.
    enum GestureOriginZone { case playArea, band, sidebar, other }
    /// The latched origin zone for the active single-finger gesture, or nil when idle.
    /// Set at the top of `touchesBegan` for a fresh primary touch (so a second finger /
    /// pinch never overwrites it); cleared once all fingers lift.
    var gestureOriginZone: GestureOriginZone?
    /// True once the player two-finger-drags to look around; cleared on the next
    /// real player move, which re-centers (auto-follow).
    var manualPanActive = false
    /// Latches true once a pinch's spread crosses `zoomActivationThreshold`, and
    /// stays set until the gesture ends. Until it latches, the pinch is dormant
    /// so a two-finger pan with incidental spread drift reads as a pure pan.
    var pinchZoomEngaged = false
    /// Last player window cell received from the engine bridge (auto-follow).
    var lastPlayerWindowCell: CGPoint?
    /// Set by restoreStoredZoom when a run opens with a remembered zoom. The launch
    /// zoom-in is a one-shot: it waits until we're on the map AND the player's cell is
    /// known, then eases in once, centered on the player. This makes the open immune to
    /// engine event ordering (controls-flip vs. cell-report vs. restore) — no premature
    /// animate-to-1× jitter, and never the map-center because it always has the cell.
    var pendingLaunchZoom = false
    /// The zoom recognizers, kept so the magnifier can be suppressed while a
    /// pinch or two-finger pan is in progress.
    weak var zoomPinch: UIPinchGestureRecognizer?
    weak var zoomPan: UIPanGestureRecognizer?
    /// Two-finger double-tap "zoom out / back" toggle, kept for enable/disable.
    weak var zoomToggle: UITapGestureRecognizer?
    /// iOS port (iBrogue): hover-to-examine for an attached trackpad/mouse. Free pointer
    /// movement (no button) is delivered as hover, not touches, so the only way to reach the
    /// engine's examine path (MOUSE_ENTERED_CELL) used to be a click-drag — whose release is a
    /// MOUSE_UP that commits a move. This recognizer restores the desktop behavior: hover
    /// examines (and moves the targeting reticle) without committing; a click still moves.
    weak var hoverGesture: UIHoverGestureRecognizer?
    /// Last map/sidebar cell a hover emitted, to mimic sdl2-platform.c: only feed a new
    /// MOUSE_ENTERED_CELL when the pointer crosses into a different cell. (-1,-1) = none yet.
    var lastHoverCell = CGPoint(x: -1, y: -1)
    /// The zoom (scale + origin) to return to when a two-finger double-tap toggles
    /// back in. Captured at the moment of toggling out; restoring the origin directly
    /// means the restore doesn't depend on a live auto-follow cell (which can be nil).
    /// scale 0 = nothing captured this session.
    var zoomToggleRestoreScale: CGFloat = 0
    var zoomToggleRestoreOrigin: CGPoint = .zero
    /// True while a pinch or two-finger pan is actively recognizing.
    var zoomGestureInProgress: Bool {
        func active(_ g: UIGestureRecognizer?) -> Bool {
            guard let state = g?.state else { return false }
            return state == .began || state == .changed
        }
        return active(zoomPinch) || active(zoomPan)
    }

    /// Drives the smooth automatic zoom suspend/restore (overlay/menu/examine ↔ map).
    /// Interpolates the *applied* scene transform only; the canonical zoomScale /
    /// zoomOriginPt are owned by the caller and untouched by the animation.
    var zoomAnimLink: CADisplayLink?
    var zoomAnimStartScale: CGFloat = 1.0
    var zoomAnimStartOrigin: CGPoint = .zero
    var zoomAnimTargetScale: CGFloat = 1.0
    var zoomAnimTargetOrigin: CGPoint = .zero
    var zoomAnimStartTime: CFTimeInterval = 0
    let zoomAnimDuration: CFTimeInterval = 0.2
    /// The transform currently shown on screen, so an animation starts from it and
    /// instant applies (gestures, per-step auto-follow) stay in sync.
    var appliedScale: CGFloat = 1.0
    var appliedOrigin: CGPoint = .zero

    /// Smoothed camera-follow display link (iPhone). Distinct from zoomAnimLink (which
    /// tweens the *scale* for suspend/restore/launch): this one only pans the *origin* to
    /// track the player during full-zoom map play. Runs on demand — started when the camera
    /// has ground to cover, invalidated once it converges and the player is idle. Main-thread
    /// only. See BrogueViewController+Zoom.swift (applyAutoFollow / stepFollow).
    var followLink: CADisplayLink?
    /// The player-centered origin the follow is easing toward (canonical, clamped).
    var followTargetOrigin: CGPoint = .zero
    /// Timestamp of the previous follow tick, for frame-rate-independent exponential smoothing.
    var followLastTickTime: CFTimeInterval = 0
    /// While true the follow link is running the fixed-duration cinematic PAN (teleport /
    /// long blink / return-from-scout) rather than the exponential trail; the two fields hold
    /// that pan's start point and start time.
    var followPanActive = false
    var followPanStartOrigin: CGPoint = .zero
    var followPanStartTime: CFTimeInterval = 0
    /// Dungeon depth reported alongside the last player-window cell. A change means a true
    /// level transition — the follow snaps rather than pans (the old origin is meaningless on
    /// the new map). -1 = none yet (first report after a reset establishes the baseline).
    var lastReportedDepth: Int = -1

    var isPhoneIdiom: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// One-time first-run hint pointing at a side button to explain long-press
    /// rebinding. The flag persists across launches; `keybindHintInFlight`
    /// guards the short delayed-present window.
    static let keybindHintShownKey = "didShowKeybindHint"
    var keybindHintInFlight = false

    /// One-time first-run hint, the first time a game starts on iPhone with
    /// pinch-zoom available, explaining the pinch / two-finger-double-tap gestures.
    /// Mirrors the keybind-hint flags: the key persists across launches, the
    /// in-flight bool guards the short delayed-present window.
    static let zoomHintShownKey = "didShowPinchZoomHint"
    var zoomHintInFlight = false

    @IBOutlet var skViewPort: SKViewPort!
    @IBOutlet weak var magView: SKMagView!
    @IBOutlet weak var escButton: UIButton! {
        didSet {
            escButton.isHidden = true
        }
    }
    @IBOutlet weak var inputTextField: UITextField!
    @IBOutlet weak var showInventoryButton: UIButton!
    // Optional: the Game Center leaderboard button was removed from Main.storyboard, so this outlet
    // may be unconnected. All accesses use optional-chaining so its absence can't crash launch.
   // @IBOutlet weak var leaderBoardButton: UIButton?
    @IBOutlet weak var seedButton: UIButton!

    /// Title-screen-only button (created in code, no art asset) that opens the
    /// save/replay file manager. Visibility tracks `lastBrogueGameEvent` just like
    /// the leaderboard/seed overlays.
    var manageFilesButton: UIButton!

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
                   // self.leaderBoardButton?.isHidden = true
                    self.seedButton.isHidden = true
                    self.escButtonWanted = false
                    self.refreshEscButtonVisibility()
                    self.resetZoom()
                case .startNewGame, .openGame, .beginOpenGame:
                  //  self.leaderBoardButton?.isHidden = true
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

        // Handoff (Continuity): a pickup can arrive while we're running (notification) or via a cold
        // launch (stashed in GameHandoff.pendingReceive, drained in viewDidAppear). See docs/design/game-handoff.md.
        NotificationCenter.default.addObserver(self, selector: #selector(handoffDidArrive),
                                               name: GameHandoff.didReceiveNotification, object: nil)
        // Handoff (Continuity): source-side confirmation when a pickup finishes serving (Phase 3a).
        gameHandoff.onServeBegan = { [weak self] in self?.beginHandoffFreeze() }
        gameHandoff.onServeComplete = { [weak self] ok, detail in
            guard let self = self else { return }
            if ok {
                // Receiver has the run — relinquish here so it lives in one place (drops to title).
                self.relinquishAfterHandoff()
            } else {
                self.endHandoffFreeze()
                self.presentHandoffAlert(title: "Handoff Interrupted",
                                         message: "The transfer didn't complete; your run is untouched.\n\(detail)")
            }
        }

        currentEngine = BrogueViewController.persistedEngine()
        setupVersionChooser()
        setupOptionsButton()
        setupInfoButton()
        // iOS port (iBrogue): establish hardware-keyboard state (and thus KEYBOARD_LABELS) BEFORE the
        // engine thread starts. The engine builds the title menu immediately on start, and setButtonText
        // bakes the hotkey highlight in from KEYBOARD_LABELS at build time — the title menu is built once
        // and won't re-read the flag if it flips later — so the flag must be correct before startEngine(),
        // or the title screen shows no shortcuts. On Catalyst the keyboard is always present, so labels
        // must be on from the first frame. (A global set before Thread.start() is visible to that thread.)
        setupHardwareKeyboardObserver()
        startEngine()

        magView.viewToMagnify = skViewPort
        magView.leftHandMode = leftHandMagnifier
        magView.hideMagnifier()
        inputTextField.delegate = self

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(draggedView(_:)))
        panGesture.minimumNumberOfTouches = 2
        dContainerView.addGestureRecognizer(panGesture)
        dContainerView.alpha = BrogueViewController.dpadRestingAlpha

        setupZoomGestures()
        setupHoverGesture()

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

        setupAppLifecycleObserver()
        setupActionButtons()
        setupCenterShortcutButton()
        // File management and Game Center now live in the Classic title menu
        // (engine-drawn), so the floating UIKit buttons are no longer created.
        repositionSeedButton()
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
        applyMacWindowSizeRestrictionsIfNeeded()
        // Handoff (Continuity): drain a pickup that arrived before we were on screen (cold launch).
        processPendingHandoff()
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

    // ── Safe-area action buttons ─────────────────────────────────────────

    static let actionButtonSize: CGFloat = 44
    static let actionButtonGap: CGFloat = 8
    static let actionButtonEdgeMargin: CGFloat = 4
    /// Extra downward nudge for the TOP button pair (A/X) below the top inset.
    /// Tweak to taste.
    static let actionButtonTopOffset: CGFloat = 20
    /// On NOTCH devices only, push the pairs away from center — top pair up,
    /// bottom pair down — by this much (the notch's clear zones differ from the
    /// island's). Tweak to taste.
    static let actionButtonNotchCenterPush: CGFloat = 12

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.destination is DirectionControlsViewController {
            directionsViewController = segue.destination as? DirectionControlsViewController
            addObserver(self, forKeyPath: #keyPath(directionsViewController.directionalButton), options: [.new], context: nil)
        }
    }
    
}
