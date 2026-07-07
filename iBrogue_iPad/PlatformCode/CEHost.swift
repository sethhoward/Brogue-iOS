//
//  CEHost.swift
//  iBrogue_iPad
//
//  Adapts the app's SpriteKit viewport + view controller to the BrogueCEHost
//  protocol that the BrogueCE.framework engine calls into. This is the app-side
//  half of the bridge: the framework cannot see SKViewPort / BrogueViewController,
//  so it talks to this object instead.
//

import UIKit

final class CEHost: NSObject, BrogueCEHost {
    private weak var viewPort: SKViewPort?
    private weak var viewController: BrogueViewController?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(viewPort: SKViewPort, viewController: BrogueViewController) {
        self.viewPort = viewPort
        self.viewController = viewController
    }

    // MARK: Rendering

    func setCellAtX(_ x: Int16, y: Int16, code: UInt32,
                    bgRed: Int16, bgGreen: Int16, bgBlue: Int16,
                    fgRed: Int16, fgGreen: Int16, fgBlue: Int16) {
        guard let viewPort = viewPort else { return }
        let bg = CGColor(colorSpace: colorSpace,
                         components: [CGFloat(bgRed) * 0.01, CGFloat(bgGreen) * 0.01, CGFloat(bgBlue) * 0.01, 1.0])
        let fg = CGColor(colorSpace: colorSpace,
                         components: [CGFloat(fgRed) * 0.01, CGFloat(fgGreen) * 0.01, CGFloat(fgBlue) * 0.01, 1.0])
        guard let bg = bg, let fg = fg else { return }
        viewPort.setCell(x: Int(x), y: Int(y), code: code, bgColor: bg, fgColor: fg)
    }

    // MARK: Geometry

    func effectiveWidthPoints() -> CGFloat { viewPort?.effectiveWidthPoints ?? 0 }
    func effectiveHeightPoints() -> CGFloat { viewPort?.effectiveHeightPoints ?? 0 }
    func leftInsetPoints() -> CGFloat { viewPort?.leftInsetPoints ?? 0 }

    /// The reach flag of the touch event most recently handed to the engine by
    /// `dequeueTouchEvent`. The engine's input loop calls `dequeueTouchEvent` then
    /// `unzoomedPoint` back-to-back on the engine thread, so stashing it here carries the
    /// per-event "map under sidebar" decision into the coordinate inverse without a shared
    /// main-thread flag that could race the commit. See UIBrogueTouchEvent.reachUnderSidebar.
    private var pendingReach = false

    func unzoomedPoint(_ point: CGPoint) -> CGPoint { viewPort?.unzoomedPoint(point, reach: pendingReach) ?? point }

    // MARK: Input

    func hasKeyEvent() -> Bool { viewController?.hasKeyEvent() ?? false }
    func dequeueKeyEvent(withShift shift: UnsafeMutablePointer<ObjCBool>,
                         control: UnsafeMutablePointer<ObjCBool>,
                         raw: UnsafeMutablePointer<ObjCBool>) -> Int32 {
        viewController?.dequeKeyEvent(shift: shift, control: control, raw: raw) ?? 0
    }
    func hasTouchEvent() -> Bool { viewController?.hasTouchEvent() ?? false }

    func dequeueTouchEvent(_ outLocation: UnsafeMutablePointer<CGPoint>,
                           phase outPhase: UnsafeMutablePointer<Int>) -> Bool {
        guard let touch = viewController?.dequeTouchEvent() else { return false }
        outLocation.pointee = touch.location
        outPhase.pointee = touch.phase.rawValue
        // Stash for the unzoomedPoint call the engine makes next on this thread.
        pendingReach = touch.reachUnderSidebar
        return true
    }

    func controlKeyIsDown() -> Bool { viewController?.seedKeyDown ?? false }

    func setUIMode(_ uiMode: Int) {
        viewController?.applyCEUIMode(uiMode)
    }

    func setAtTitle(_ atTitle: Bool) {
        viewController?.setCEAtTitle(atTitle)
    }

    func requestTextInput(_ defaultText: String, numeric: Bool) {
        viewController?.requestTextInput(for: defaultText, numeric: numeric)
    }

    func presentFileManagement() {
        viewController?.presentFileManagementScreenForCE()
    }

    func presentGameCenter() {
        viewController?.presentGameCenterScreenForCE()
    }

    func playDamageHaptic(_ severity: Int) {
        viewController?.playerTookDamage(severity)
    }

    func playDetectionHaptic(_ stage: Int) {
        viewController?.noiseDetectionHaptic(stage)
    }

    func playEnvironmentalNoiseHaptic(_ kind: Int) {
        viewController?.environmentalNoiseHaptic(kind)
    }

    func setTargeting(_ targeting: Bool) {
        viewController?.setCETargeting(targeting)
    }

    func setExamining(_ examining: Bool) {
        viewController?.setExamining(examining)
    }

    func setExamineBox(_ x: Int, y: Int, width: Int, height: Int) {
        viewController?.setExamineBox(x, y: y, width: width, height: height)
    }

    func setMenuBox(_ x: Int, y: Int, width: Int, height: Int) {
        viewController?.setMenuBox(x, y: y, width: width, height: height)
    }

    func clearMenuBox() {
        viewController?.clearMenuBox()
    }

    func shouldSuppressExamineBox() -> Bool {
        viewController?.shouldSuppressExamineBox() ?? false
    }

    func setPlayerWindowX(_ x: Int16, y: Int16) {
        viewController?.setPlayerWindowX(Int(x), y: Int(y))
    }

    func setTravelPending(_ pending: Bool) {
        viewController?.setTravelPending(pending)
    }

    func setGameDepth(_ depth: Int, turn: Int, seed: UInt64) {
        viewController?.setGameContext(depth: depth, turn: turn, seed: seed)
    }

    // MARK: Game Center
    // These fire on the CE engine's background thread, so hop to main before
    // touching GameKit. The bridge has already gated on variant + wizard mode.

    func reportCEScore(_ score: Int) {
        DispatchQueue.main.async {
            GameCenter.shared.reportScore(Int64(score), leaderboardID: GameCenter.ceHighScoreLeaderboardID)
        }
    }

    func submitCEAchievement(withID identifier: String) {
        DispatchQueue.main.async {
            GameCenter.shared.submitAchievement(identifier, percentComplete: 100)
        }
    }
}
