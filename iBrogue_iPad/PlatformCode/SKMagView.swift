//
//  SKMagView.swift
//  Brogue
//
//  The magnifier "loupe" view. Extracted verbatim from BrogueViewController.swift
//  as part of splitting that file by function; behavior unchanged.
//

import UIKit
import SpriteKit
import QuartzCore

// `COLS`/`ROWS` shadow the C engine's macros (Rogue.h) with Int-typed, file-local
// constants — matching BrogueViewController.swift. They stay fileprivate to avoid a
// module-scope clash with the imported C `COLS`/`ROWS` (which are Int32).
fileprivate let COLS = 100
fileprivate let ROWS = 34

// MARK: - SKMagView
final class SKMagView: SKView {
    var viewToMagnify: SKViewPort?

    /// iPhone "left-handed" mode: place the magnifier to the RIGHT of the finger
    /// instead of the left, so a left hand gripping the device doesn't cover it.
    /// No effect on iPad (which hovers the magnifier above the touch).
    var leftHandMode: Bool = false

    /// Mirrors BrogueViewController.sidebarReachLatched: when true, the loupe resolves the
    /// cell under the finger with the zoom inverse extended over the sidebar columns, so it
    /// shows the magnified map behind the translucent sidebar rather than the sidebar cells.
    var sidebarReach: Bool = false

    /// Where the loupe sits relative to the finger. Tracked so a *change* (e.g. flipping
    /// from beside the finger to above it when it reaches an edge) glides instead of
    /// snapping, while same-placement finger tracking stays instant.
    private enum LoupePlacement { case beside, above, below }
    private var lastPlacement: LoupePlacement = .beside
    /// While a placement glide is in flight, tracking sets are suppressed until this time so
    /// they don't yank the animation. `CACurrentMediaTime` clock.
    private var repositionUntil: CFTimeInterval = 0

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
        let positioned = positionedCenter(forTouch: point)
        setLoupeCenter(positioned.center, placement: positioned.placement)
        isHidden = false
    }

    /// Move the loupe to `newCenter`. Track the finger instantly while the placement is
    /// unchanged, but GLIDE (animate) when the placement flips — e.g. from beside the finger
    /// to above it when the loupe reaches an edge, so it never snaps. During the glide,
    /// same-placement tracking sets are suppressed so they don't yank the animation. The
    /// first show after being hidden always sets directly, so the loupe appears in place.
    private func setLoupeCenter(_ newCenter: CGPoint, placement: LoupePlacement) {
        // iPad keeps its original snap-to-position magnifier untouched; the glide-on-
        // reposition (paired with the iPhone lift placement) is an iPhone-only nicety.
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            center = newCenter
            return
        }
        let firstShow = isHidden
        let now = CACurrentMediaTime()
        if !firstShow && placement != lastPlacement {
            lastPlacement = placement
            repositionUntil = now + 0.2
            UIView.animate(withDuration: 0.2, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState]) {
                self.center = newCenter
            }
            return
        }
        lastPlacement = placement
        if firstShow || now >= repositionUntil {
            center = newCenter
        }
    }

    /// Where to place the loupe, and its placement mode (for glide-vs-track above). On iPhone
    /// it stays on the user's preferred side — left by default, right in left-handed mode — so
    /// the finger never occludes the magnified content. It tracks beside the finger until the
    /// finger nears the loupe's centre horizontally (reaching hard against the leading edge,
    /// e.g. under the translucent sidebar); then, *keeping the same side*, it lifts vertically
    /// — up by default, down when near the top — along a smooth circular arc, so the touched
    /// cell at the centre clears the fingertip without any jarring beside↔above flip or
    /// oscillation. On iPad it hovers above the touch, flipping left only when that would clip
    /// the top. Always clamped to the parent's safe area (notch / dynamic island / edges).
    private func positionedCenter(forTouch point: CGPoint) -> (center: CGPoint, placement: LoupePlacement) {
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
        // TWEAK ME: gap between the finger and the nearer edge of the loupe.
        let flipPadding: CGFloat = 38
        var c: CGPoint
        var placement: LoupePlacement

        if isPhone {
            // Preferred side, clamped horizontally to the safe area.
            var cx = leftHandMode ? point.x + radius + flipPadding    // RIGHT of finger
                                  : point.x - radius - flipPadding      // LEFT of finger
            if cx - radius < bounds.minX { cx = bounds.minX + radius }
            else if cx + radius > bounds.maxX { cx = bounds.maxX - radius }

            // As the finger nears the loupe's centre horizontally, lift the loupe off it so
            // the centre cell stays visible. The lift follows a circle of radius `clearance`,
            // so it's zero while the finger is comfortably to the side and grows smoothly to
            // `clearance` as the finger reaches the centre — continuous, never a snap.
            // TWEAK ME: `clearance` is how far the finger is kept from the loupe centre.
            let clearance: CGFloat = 52
            let dx = abs(point.x - cx)
            let lift = dx < clearance ? (clearance * clearance - dx * dx).squareRoot() : 0
            // Direction is chosen from the finger's height alone (stable as it moves
            // sideways): lift down only when too near the top for an upward lift to fit.
            let liftDown = point.y - clearance - radius < bounds.minY
            c = CGPoint(x: cx, y: liftDown ? point.y + lift : point.y - lift)
            placement = liftDown ? .below : .above
        } else {
            // iPad: hover above the touch, flipping left only when that clips the top.
            c = CGPoint(x: point.x + size.width / 2 - offset.width,
                        y: point.y - size.height / 2 + offset.height)
            if c.y - radius < bounds.minY {
                c = CGPoint(x: point.x - radius - flipPadding, y: point.y)
                placement = .beside
            } else {
                placement = .above
            }
        }

        // Final clamp to the safe area (notch / dynamic island / edges).
        if c.x - radius < bounds.minX { c.x = bounds.minX + radius }
        else if c.x + radius > bounds.maxX { c.x = bounds.maxX - radius }
        if c.y - radius < bounds.minY { c.y = bounds.minY + radius }
        else if c.y + radius > bounds.maxY { c.y = bounds.maxY - radius }

        return (c, placement)
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
        let currentCellXY = getCellCoords(at: point, viewport: viewToMagnify, reach: sidebarReach)
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
            let unzoomed = viewToMagnify.unzoomedPoint(point, reach: sidebarReach)
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
