//
//  SKViewPort.swift
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

class SKViewPort: SKView {
    /// Points reserved at the bottom of the view so rendered text doesn't overlap
    /// the iPad home indicator / system gesture strip.
    /// Read by RogueScene (cell layout), BrogueViewController, and RogueDriver (touch math).
    @objc public static let homeIndicatorPad: CGFloat = 0

    /// iPhone-only: extra points reserved below the grid for a fat, easy-to-hit
    /// button tap-band. Lifting the grid by this amount moves the engine button
    /// bar up off the screen edge; touches in the band are remapped to the
    /// nearest button by BrogueViewController. Tunable. iPad gets none.
    @objc public static let bottomButtonBandPoints: CGFloat = 14

    /// Total points reserved at the bottom (home indicator + iPhone button band).
    /// Single source of truth so the scene's `bottomPad` and `effectiveHeightPoints`
    /// stay in agreement.
    @objc public static var bottomReservePoints: CGFloat {
        let band = UIDevice.current.userInterfaceIdiom == .phone ? bottomButtonBandPoints : 0
        return homeIndicatorPad + band
    }

    /// Points to translate the whole gameplay grid to the right: the leading
    /// edge is inset by this much, and the trailing (notch) safe-area
    /// reservation is reduced by the same amount. Equal-and-opposite, so the
    /// grid keeps its width and simply slides right by this amount.
    @objc public static let gridRightShift: CGFloat = 16

    /// Height of the playable area in points, accounting for whether padding is currently
    /// applied. Used by touch→cell math in both Swift and Obj-C.
    @objc public var effectiveHeightPoints: CGFloat {
        let h = UIScreen.main.bounds.size.height
        return rogueScene.paddingEnabled ? h - SKViewPort.bottomReservePoints : h
    }

    /// Width of the playable area in points. Honors the iPhone notch /
    /// dynamic-island safe-area insets, but only when padding is enabled
    /// (i.e. during gameplay — title and menu screens fill the full width).
    @objc public var effectiveWidthPoints: CGFloat {
        return UIScreen.main.bounds.size.width - leftInsetPoints - rightInsetPoints
    }

    /// Leading inset in points. Returns 0 outside of gameplay so the title /
    /// menu screens render edge-to-edge.
    @objc public var leftInsetPoints: CGFloat {
        guard rogueScene.paddingEnabled else { return 0 }
        let scale = UIScreen.main.scale
        return rogueScene.leftPadPixels / scale
    }

    /// Trailing inset in points. Returns 0 outside of gameplay.
    @objc public var rightInsetPoints: CGFloat {
        guard rogueScene.paddingEnabled else { return 0 }
        let scale = UIScreen.main.scale
        return rogueScene.rightPadPixels / scale
    }

    var rogueScene: RogueScene!
    var hWindow = UIScreen.main.bounds.size.width
    var vWindow = UIScreen.main.bounds.size.height

    required init?(coder aDecoder: NSCoder) {
        let rect = UIScreen.main.bounds
        // go max retina on initial size or scaling of text is ugly
        let scale = UIScreen.main.scale
        rogueScene = RogueScene(
            size: CGSize(width: rect.size.width * scale, height: rect.size.height * scale),
            rows: 34,
            cols: 100,
            bottomPadPixels: SKViewPort.bottomReservePoints * scale
        )
        rogueScene.scaleMode = .fill
        super.init(coder: aDecoder)

       // showsFPS = true
      //  showsNodeCount = true
        ignoresSiblingOrder = true
        backgroundColor = .black
    }
    
    override func awakeFromNib() {
        presentScene(rogueScene)
    }
    
    @objc public func setCell(x: Int, y: Int, code: UInt32, bgColor: CGColor, fgColor: CGColor) {
        rogueScene.setCell(x: x, y: y, code: code, bgColor: bgColor, fgColor: fgColor)
    }

    // MARK: - Pinch-to-zoom (iPhone)

    /// Push a zoom transform to the scene. `scale` is the magnification and
    /// `(originXPoints, originYPoints)` is the container origin in UIKit points
    /// (see RogueScene.setZoom). No-op on iPad.
    @objc public func applyZoom(scale: CGFloat, originXPoints: CGFloat, originYPoints: CGFloat) {
        rogueScene.setZoom(scale: scale, originXPoints: originXPoints, originYPoints: originYPoints)
    }

    /// Single source of truth for the zoom touch inverse, shared by every
    /// point→cell router (getCellCoords in Swift, and nextKeyOrMouseEvent in the
    /// Classic + CE bridges). Given a touch point in view points, returns the
    /// point the engine should treat it as: for touches over the magnified
    /// dungeon map it inverts the zoom transform (`u = (p - origin) / scale`);
    /// everywhere else (sidebar, messages, button bar) it returns `point`
    /// unchanged so those map 1:1.
    @objc public func unzoomedPoint(_ point: CGPoint) -> CGPoint {
        let scale = rogueScene.zoomScale
        guard scale != 1.0 else { return point }
        let width = effectiveWidthPoints
        let height = effectiveHeightPoints
        guard width > 0, height > 0 else { return point }
        // Which cell would this be at 1×? Only invert inside the zoomable map.
        let cellX = Int(100.0 * max(point.x - leftInsetPoints, 0) / width)
        let cellY = Int(34.0 * point.y / height)
        guard cellX >= 21, cellX <= 99, cellY >= 3, cellY <= 31 else { return point }
        return CGPoint(x: (point.x - rogueScene.zoomOriginXPoints) / scale,
                       y: (point.y - rogueScene.zoomOriginYPoints) / scale)
    }
}
