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
    func unzoomedPoint(_ point: CGPoint) -> CGPoint { viewPort?.unzoomedPoint(point) ?? point }

    // MARK: Input

    func hasKeyEvent() -> Bool { viewController?.hasKeyEvent() ?? false }
    func dequeueKeyEvent() -> UInt8 { viewController?.dequeKeyEvent() ?? 0 }
    func hasTouchEvent() -> Bool { viewController?.hasTouchEvent() ?? false }

    func dequeueTouchEvent(_ outLocation: UnsafeMutablePointer<CGPoint>,
                           phase outPhase: UnsafeMutablePointer<Int>) -> Bool {
        guard let touch = viewController?.dequeTouchEvent() else { return false }
        outLocation.pointee = touch.location
        outPhase.pointee = touch.phase.rawValue
        return true
    }

    func controlKeyIsDown() -> Bool { viewController?.seedKeyDown ?? false }

    func setUIMode(_ uiMode: Int) {
        viewController?.applyCEUIMode(uiMode)
    }

    func setAtTitle(_ atTitle: Bool) {
        viewController?.setCEAtTitle(atTitle)
    }

    func presentFileManagement() {
        viewController?.presentFileManagementScreenForCE()
    }

    func playDamageHaptic(_ severity: Int) {
        viewController?.playerTookDamage(severity)
    }

    func setTargeting(_ targeting: Bool) {
        viewController?.setCETargeting(targeting)
    }

    func setPlayerWindowX(_ x: Int16, y: Int16) {
        viewController?.setPlayerWindowX(Int(x), y: Int(y))
    }
}
