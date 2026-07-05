//
//  GameScene.swift
//  SKTest
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


import SpriteKit
import GameplayKit

extension CGSize {
    public init(rows: Int, cols: Int) {
        self = CGSize(width: rows, height: cols)
    }
    
    var rows: Int {
        return Int(self.width)
    }
    
    var cols: Int {
        return Int(self.height)
    }
}

// To see Swift classes from ObjC they MUST be prefaced with @objc and be public/open
@objc public class RogueScene: SKScene {
    fileprivate let gridSize: CGSize
    fileprivate var cellSize: CGSize
    /// In scene pixels. Cells are shifted up by this amount so the bottom row
    /// sits above the home indicator gesture strip when padding is enabled.
    fileprivate let bottomPad: CGFloat
    /// In scene pixels. Cells are inset from the left/right scene edges by
    /// these amounts so they don't render under the iPhone notch / dynamic
    /// island when the device is in landscape. Driven by safe-area insets.
    fileprivate(set) var leftPadPixels: CGFloat = 0
    fileprivate(set) var rightPadPixels: CGFloat = 0
    /// When true (default), cells render in [bottomPad, sceneHeight] leaving a black
    /// strip at the bottom for the home indicator. When false (title screen),
    /// cells fill the full scene height.
    @objc public var paddingEnabled: Bool = true {
        didSet { relayoutCells() }
    }

    /// Update the horizontal safe-area insets (in scene pixels). Triggers a
    /// relayout so cells avoid the notched zones.
    @objc public func setHorizontalEdgeInsets(leftPixels: CGFloat, rightPixels: CGFloat) {
        guard leftPixels != leftPadPixels || rightPixels != rightPadPixels else { return }
        leftPadPixels = leftPixels
        rightPadPixels = rightPixels
        relayoutCells()
    }

    fileprivate var fgTextures = [SKTexture]()
    fileprivate var bgTextures = [SKTexture]()
    var cells = [[Cell]]()
    fileprivate var textureMap: [String : SKTexture] = [:]

    // ─────────────────────────────────────────────────────────────────────
    // Pinch-to-zoom (iPhone only). Only the dungeon map cells — window cols
    // 21…99, rows 3…30 — are reparented under `dungeonContainer`, which is
    // scaled and translated to zoom/pan the map. The container is wrapped in
    // an SKCropNode clipped to the dungeon frame so the magnified map can't
    // bleed over the sidebar / messages / button bar (which stay at 1×).
    //
    // The canonical zoom state is kept in UIKit POINT space (origin top-left,
    // y down) so the touch→cell inverse (SKViewPort.unzoomedPoint) is a plain
    // `u = (p - origin) / scale`. setZoom() converts that into the scene's
    // pixel / bottom-up space exactly once, in applyZoomTransform().
    //
    // Window row 31 is deliberately NOT included: on iPhone it's part of the
    // bottom buttons' tall (B_TALL_CLICK_AREA) tap zone and must stay at 1×.
    private static let zoomColMin = 21, zoomColMax = 99
    // Rows 3…31 are the full dungeon map (row 31 is the bottom dungeon row). It's
    // included so the whole map magnifies uniformly — leaving it out left a
    // 1× "bottom wall" when zoomed. Rows 32 (flavor) and 33 (buttons) stay chrome.
    private static let zoomRowMin = 3,  zoomRowMax = 31

    /// UserDefaults key for "zoom out to show a tapped sidebar entity's description".
    @objc public static let examineZoomEnabledDefaultsKey = "examineZoomOutEnabled"

    /// Whether tapping a sidebar entity zooms out to 1× so its description box isn't
    /// clipped. **Default ON**; absent key → default, stored value (on/off) respected
    /// (an absent key returns the default while a stored value, on or off, is kept).
    @objc public static var isExamineZoomEnabledSetting: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: examineZoomEnabledDefaultsKey) == nil { return true }
        return defaults.bool(forKey: examineZoomEnabledDefaultsKey)
    }

    /// UserDefaults key for "extend the magnified dungeon under a translucent sidebar."
    @objc public static let mapUnderSidebarEnabledDefaultsKey = "mapUnderSidebarEnabled"

    /// Whether the zoomed dungeon renders full-width under a translucent sidebar (so the
    /// map shows behind the stats/monster list) and a magnifier-drag can reach the cells
    /// there. **Default ON**; absent key → default, stored value (on/off) respected.
    @objc public static var isMapUnderSidebarEnabledSetting: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: mapUnderSidebarEnabledDefaultsKey) == nil { return true }
        return defaults.bool(forKey: mapUnderSidebarEnabledDefaultsKey)
    }

    /// Whether the "map under sidebar" reveal is permitted (the user's Options toggle).
    /// The reveal is *applied* only when also zoomed in — see `updateSidebarReveal`.
    /// Seeded from the persisted setting; flipped live by `setMapUnderSidebarEnabled`.
    private var mapUnderSidebarEnabled: Bool = RogueScene.isMapUnderSidebarEnabledSetting
    /// Latched state of whether the reveal is currently applied (zoomed AND enabled), so
    /// the mask-widen + sidebar-wash are re-applied only when it flips — not every zoom
    /// tick (the engine thread's per-step auto-follow calls setZoom constantly).
    private var sidebarRevealActive = false

    /// Fraction of opacity kept on the sidebar cell backgrounds while the reveal is
    /// active (glyphs stay fully opaque). Lower = more map shows through, at the cost of
    /// text contrast. Tunable.
    private static let sidebarWashAlpha: CGFloat = 0.5

    private var dungeonCrop: SKCropNode?
    private var dungeonContainer: SKNode?
    private var dungeonMask: SKSpriteNode?

    /// Current zoom factor (1.0 = no zoom). Read by SKViewPort.unzoomedPoint.
    private(set) var zoomScale: CGFloat = 1.0
    /// Container origin in UIKit points (see setZoom). Read by unzoomedPoint.
    private(set) var zoomOriginXPoints: CGFloat = 0
    private(set) var zoomOriginYPoints: CGFloat = 0

    /// Per-frame batch captured off the main thread (the engine thread's `commitDraws`)
    /// and flushed together in the next `update(_:)`, on the main thread, right before the
    /// renderer samples the node tree. Both the cell glyph/colour writes AND the
    /// auto-follow camera move are buffered here so they land in the SAME render pass —
    /// otherwise the engine thread mutating SK nodes mid-render tears the player glyph
    /// away from the camera (a fixed one-frame jump that reverts), which animated terrain
    /// (water/fire/lava) makes constant by keeping the engine thread, and so `commitDraws`,
    /// busy every frame. Only used while the zoom layer is active (iPhone, pinch on); the
    /// flat 1× / iPad path keeps writing nodes directly (no camera → nothing to tear
    /// against). All three fields are guarded by `pendingLock`.
    private struct PendingCell { let code: UInt32; let bgColor: CGColor; let fgColor: CGColor }
    private var pendingCells: [Int: PendingCell] = [:]   // key = x * (gridSize.rows + 1) + y
    private var pendingZoom: (scale: CGFloat, originXPoints: CGFloat, originYPoints: CGFloat)?
    private let pendingLock = NSLock()

    /// Zoom is an iPhone-only feature; iPad keeps the flat 1× scene unchanged.
    private var zoomEnabled: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    // We don't want small letters scaled to huge proportions, so we only allow letters to stretch
    // within a certain range (e.g. size of M +/- 20%)
    fileprivate lazy var maxScaleFactor: CGFloat = {
        let char: NSString = "M" // Good letter to do the base calculations from
        let calcBounds: CGRect = char.boundingRect(with: CGSize(width: 0, height: 0),
                                                   options: [.usesDeviceMetrics, .usesFontLeading],
                                                   attributes: convertToOptionalNSAttributedStringKeyDictionary([convertFromNSAttributedStringKey(NSAttributedString.Key.font): UIFont(name: "ArialUnicodeMS", size: 120)!]), context: nil)
        return min(self.cellSize.width / calcBounds.width, self.cellSize.height / calcBounds.height)
    }()

    // CE tile glyphs render from the "Brogue" font, whose metrics differ from
    // ArialUnicodeMS, so they need their own clamp base. Only consulted for
    // tile-range codepoints (0x4000+), which only the CE engine emits.
    fileprivate lazy var brogueMaxScaleFactor: CGFloat = {
        let char: NSString = "M"
        let calcBounds: CGRect = char.boundingRect(with: CGSize(width: 0, height: 0),
                                                   options: [.usesDeviceMetrics, .usesFontLeading],
                                                   attributes: convertToOptionalNSAttributedStringKeyDictionary([convertFromNSAttributedStringKey(NSAttributedString.Key.font): UIFont(name: "Brogue", size: 120)!]), context: nil)
        return min(self.cellSize.width / calcBounds.width, self.cellSize.height / calcBounds.height)
    }()

    public init(size: CGSize, rows: Int, cols: Int, bottomPadPixels: CGFloat = 0) {
        gridSize = CGSize(rows: rows, cols: cols)
        bottomPad = bottomPadPixels
        let usableHeight = max(size.height - bottomPadPixels, 0)
        cellSize = CGSize(
            width: CGFloat(size.width) / CGFloat(cols),
            height: usableHeight / CGFloat(rows)
        )
        super.init(size: size)
        backgroundColor = .black
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension RogueScene {
    public func setCell(x: Int, y: Int, code: UInt32, bgColor: CGColor, fgColor: CGColor) {
        // When the zoom layer is up (iPhone, pinch on) the dungeon cells live under a
        // container whose transform the camera moves. To keep the player glyph and the
        // camera in the same render pass, buffer the engine thread's writes and flush them
        // in update(_:) on the main thread (see pendingCells). Without the zoom layer
        // (iPad, or pinch off) there's no camera to tear against, so apply directly — the
        // long-standing path. Main-thread callers always apply directly.
        if dungeonContainer != nil, !Thread.isMainThread {
            pendingLock.lock()
            pendingCells[x * (gridSize.rows + 1) + y] = PendingCell(code: code, bgColor: bgColor, fgColor: fgColor)
            pendingLock.unlock()
            return
        }
        applyCell(x: x, y: y, code: code, bgColor: bgColor, fgColor: fgColor)
    }

    /// Writes a cell's glyph and colours to its SK nodes. MUST run on the main thread when
    /// the zoom layer is active (it mutates nodes the renderer reads); the direct path
    /// calls it inline on whatever thread when there's no zoom layer. Texture resolution
    /// (`getTexture`, which mutates `textureMap`) therefore also stays main-thread-only
    /// while zoomed.
    private func applyCell(x: Int, y: Int, code: UInt32, bgColor: CGColor, fgColor: CGColor) {
        cells[x][y].fgcolor = UIColor(cgColor: fgColor)
        cells[x][y].bgcolor = UIColor(cgColor: bgColor)

        if let glyph = UnicodeScalar(code) {
            cells[x][y].glyph = getTexture(glyph: String(glyph))
        }
    }
    
    override public func sceneDidLoad() {
        let usableHeight = max(size.height - bottomPad, 0)
        let usableWidth = max(size.width - leftPadPixels - rightPadPixels, 0)
        cellSize = CGSize(
            width: usableWidth / CGFloat(gridSize.cols),
            height: usableHeight / CGFloat(gridSize.rows)
        )
        for x in 0...gridSize.cols {
            var row = [Cell]()
            for y in 0...gridSize.rows {
                let newCell = Cell(
                    x: leftPadPixels + CGFloat(x) * cellSize.width,
                    y: bottomPad + CGFloat(gridSize.rows - y - 1) * cellSize.height,
                    size: CGSize(width: cellSize.width, height: cellSize.height)
                )
                row.append(newCell)
            }
            cells.append(row)
        }
    }

    /// The current cell layout in scene pixels: the bottom-left offset of grid
    /// cell (0,0) and the per-cell size. Both the bottom (home-indicator) pad
    /// and the left/right (notch) pads are only applied during gameplay; on
    /// title / menu screens the grid fills the full scene.
    private func currentLayout() -> (xOffset: CGFloat, yOffset: CGFloat, cell: CGSize) {
        let effectiveLeft: CGFloat = paddingEnabled ? leftPadPixels : 0
        let effectiveRight: CGFloat = paddingEnabled ? rightPadPixels : 0
        let usableHeight = paddingEnabled ? size.height - bottomPad : size.height
        let usableWidth = max(size.width - effectiveLeft - effectiveRight, 0)
        let yOffset: CGFloat = paddingEnabled ? bottomPad : 0
        let cell = CGSize(
            width: usableWidth / CGFloat(gridSize.cols),
            height: usableHeight / CGFloat(gridSize.rows)
        )
        return (effectiveLeft, yOffset, cell)
    }

    private func relayoutCells() {
        let layout = currentLayout()
        cellSize = layout.cell
        for x in 0..<cells.count {
            let column = cells[x]
            for y in 0..<column.count {
                let cell = column[y]
                cell.size = cellSize
                cell.position = CGPoint(
                    x: layout.xOffset + CGFloat(x) * cellSize.width,
                    y: layout.yOffset + CGFloat(gridSize.rows - y - 1) * cellSize.height
                )
            }
        }
        // iOS port (iBrogue): on iPhone the engine button bar is a single row floating
        // above the tap-band. Extend each bottom-row button cell's BACKGROUND down past
        // the scene bottom so the buttons read as taller, flush-to-bottom tabs. The glyph
        // (foreground) stays put, so the label sits toward the top of the taller button.
        // yOffset == band height in gameplay, 0 on title/menu — so this no-ops off-gameplay.
        // Two subtleties handled here:
        //  • The cell array has one unused extra row (index gridSize.rows) whose black
        //    background lands over the band; bumping zPosition above it (but below the
        //    foreground glyph at z=1) keeps the button color on top in the band.
        //  • Overshoot below y=0 by a cell so the color reaches the physical bottom edge
        //    (the SKView is edge-to-edge); SpriteKit clips the overshoot.
        if layout.yOffset > 0 {
            let lastRow = gridSize.rows - 1
            let overshoot = cellSize.height
            for x in 21...gridSize.cols - 1 {
                let bg = cells[x][lastRow].background
                bg.zPosition = 0.5
                bg.position = CGPoint(x: layout.xOffset + CGFloat(x) * cellSize.width, y: -overshoot)
                bg.size = CGSize(width: cellSize.width, height: cellSize.height + layout.yOffset + overshoot)
            }
        }
        relayoutZoomLayer()
    }

    override public func didMove(to view: SKView) {
        // Every cell starts as a direct child of the scene (the un-zoomed layout).
        for x in 0..<cells.count {
            for y in 0..<cells[x].count {
                let cell = cells[x][y]
                cell.background.anchorPoint = CGPoint(x: 0, y: 0)
                addChild(cell.background)
                addChild(cell.foreground)
            }
        }
        // Build the zoom layer on iPhone (pinch-to-zoom is always on). iPad keeps a
        // flat 1× grid with no crop / offscreen pass.
        if zoomEnabled {
            enableZoomLayer()
        }
        // paddingEnabled's didSet only fires on change, and updatePadding early-returns
        // on non-notch phones, so relayoutCells may not run before the first frame. Run
        // it once here so the bottom-row button-background extension is applied on entry.
        relayoutCells()
    }

    // MARK: - Zoom layer

    private func dungeonCellNodes() -> [SKNode] {
        var nodes = [SKNode]()
        for x in RogueScene.zoomColMin...RogueScene.zoomColMax {
            for y in RogueScene.zoomRowMin...RogueScene.zoomRowMax {
                nodes.append(cells[x][y].background)
                nodes.append(cells[x][y].foreground)
            }
        }
        return nodes
    }

    /// Builds the crop + container and reparents the dungeon-map cells into it.
    /// Idempotent; iPhone-only. Toggling the experimental option calls this.
    func enableZoomLayer() {
        guard zoomEnabled, dungeonContainer == nil else { return }
        setupZoomLayer()
        guard let container = dungeonContainer else { return }
        for node in dungeonCellNodes() {
            node.removeFromParent()
            container.addChild(node)
        }
    }

    /// Tears the zoom layer down: resets to 1×, returns the dungeon cells to the
    /// scene as flat children, and removes the crop. Leaves the scene exactly as
    /// it was before the feature was ever enabled.
    func disableZoomLayer() {
        guard let crop = dungeonCrop else { return }
        for node in dungeonCellNodes() {
            node.removeFromParent()
            addChild(node)
        }
        crop.removeFromParent()
        dungeonCrop = nil
        dungeonContainer = nil
        dungeonMask = nil
        zoomScale = 1.0
        zoomOriginXPoints = 0
        zoomOriginYPoints = 0
        // Flush any buffered cell writes before switching to the direct path: commitDraws
        // only re-plots *changed* cells, so dropping these would leave stale glyphs. The
        // pending camera is moot — the container is gone and we've reset to 1×.
        pendingLock.lock()
        let leftover = pendingCells
        pendingCells.removeAll()
        pendingZoom = nil
        pendingLock.unlock()
        let stride = gridSize.rows + 1
        for (key, pc) in leftover {
            applyCell(x: key / stride, y: key % stride,
                      code: pc.code, bgColor: pc.bgColor, fgColor: pc.fgColor)
        }
    }

    /// The crop-mask rectangle (rows 3…31) in scene pixels, derived from the live cell
    /// layout so it tracks rotations / inset changes. Normally spans the dungeon columns
    /// (window cols 21…99); while the "map under sidebar" reveal is active it widens to the
    /// full grid width (cols 0…99) so the magnified map shows under the translucent sidebar.
    /// The auto-follow pan clamp (BrogueViewController.dungeonFramePoints) is unaffected and
    /// stays on cols 21…99, so the framing/centering is unchanged — the extra columns are a
    /// bonus reveal that shows black only hard against the map's left edge.
    private func dungeonFrameInScene() -> CGRect {
        let layout = currentLayout()
        let rows = CGFloat(RogueScene.zoomRowMax - RogueScene.zoomRowMin + 1) // 29
        // Bottom edge of the lowest zoomed row, measured bottom-up.
        let minY = layout.yOffset
            + CGFloat(gridSize.rows - RogueScene.zoomRowMax - 1) * layout.cell.height
        let height = rows * layout.cell.height
        if sidebarRevealActive {
            let width = CGFloat(gridSize.cols) * layout.cell.width // cols 0…99
            return CGRect(x: layout.xOffset, y: minY, width: width, height: height)
        }
        let cols = CGFloat(RogueScene.zoomColMax - RogueScene.zoomColMin + 1) // 79
        let minX = layout.xOffset + CGFloat(RogueScene.zoomColMin) * layout.cell.width
        return CGRect(x: minX, y: minY, width: cols * layout.cell.width, height: height)
    }

    /// Builds the crop + container once, before cells are parented (didMove).
    private func setupZoomLayer() {
        let frame = dungeonFrameInScene()
        let mask = SKSpriteNode(color: .white, size: frame.size)
        mask.anchorPoint = CGPoint(x: 0, y: 0)
        mask.position = frame.origin

        let crop = SKCropNode()
        crop.position = .zero
        crop.zPosition = 0
        crop.maskNode = mask

        let container = SKNode()
        container.position = .zero
        crop.addChild(container)
        addChild(crop)

        dungeonMask = mask
        dungeonCrop = crop
        dungeonContainer = container
    }

    /// Applies a zoom transform expressed in UIKit point space. `scale` is the
    /// magnification; `(originXPoints, originYPoints)` positions the scaled map
    /// such that a touch point `p` maps back to the un-zoomed point
    /// `u = (p - origin) / scale` (see SKViewPort.unzoomedPoint). Converts that
    /// into the scene's pixel + bottom-up space here, the single place the
    /// y-flip lives. No-op on iPad (no container).
    func setZoom(scale: CGFloat, originXPoints: CGFloat, originYPoints: CGFloat) {
        // Publish the transform synchronously on whatever thread asked: these fields are
        // read by SKViewPort.unzoomedPoint to invert touches, so they must reflect the
        // latest requested zoom immediately, regardless of when the node write lands.
        zoomScale = scale
        zoomOriginXPoints = originXPoints
        zoomOriginYPoints = originYPoints

        // The container node mutation must land in lockstep with the renderer (main
        // thread). Main-thread callers — pinch/pan gestures, the suspend/restore zoom
        // animation, rotation relayout — apply it immediately. The engine thread's
        // per-step auto-follow (commitDraws → setPlayerWindowX) instead STASHES it for
        // the next update(_:): writing the container transform from the engine thread
        // tore the camera away from the player glyph whenever the renderer sampled
        // mid-commitDraws, which animated terrain (water/fire/lava) made constant —
        // the player visibly jittered while walking. See update(_:).
        if Thread.isMainThread {
            pendingLock.lock()
            pendingZoom = nil   // a fresh main-thread apply supersedes any stale stash
            pendingLock.unlock()
            applyZoomToContainer(scale: scale, originXPoints: originXPoints, originYPoints: originYPoints)
        } else {
            pendingLock.lock()
            pendingZoom = (scale, originXPoints, originYPoints)
            pendingLock.unlock()
        }
    }

    /// Applies a zoom transform to the dungeon container. MUST run on the main thread —
    /// it mutates the SK node tree the renderer reads. Shared by the immediate path
    /// (main-thread setZoom callers) and the deferred path (engine-thread auto-follow
    /// drained in update(_:)).
    private func applyZoomToContainer(scale: CGFloat, originXPoints: CGFloat, originYPoints: CGFloat) {
        guard let container = dungeonContainer else { return }
        let pixelScale = UIScreen.main.scale
        container.setScale(scale)
        container.position = CGPoint(
            x: pixelScale * originXPoints,
            y: size.height * (1 - scale) - pixelScale * originYPoints
        )
        // Cross the zoomed/1× threshold on the same (main) thread that applies the
        // transform, so the sidebar reveal flips in lockstep with the magnification.
        updateSidebarReveal()
    }

    // MARK: - Map-under-sidebar reveal

    /// Flip the Options toggle live (called from BrogueViewController). Re-applies the
    /// reveal immediately so turning it off mid-zoom restores the opaque sidebar.
    @objc public func setMapUnderSidebarEnabled(_ enabled: Bool) {
        guard mapUnderSidebarEnabled != enabled else { return }
        mapUnderSidebarEnabled = enabled
        updateSidebarReveal()
    }

    /// Recompute whether the reveal should be applied (zoomed in AND enabled AND iPhone)
    /// and, only when that latched state flips, re-mask the crop to full/partial width and
    /// wash/unwash the sidebar backgrounds. Idempotent and cheap on the common no-flip path
    /// (the engine thread's per-step auto-follow drives applyZoomToContainer constantly).
    /// Must run on the main thread — it mutates the mask + cell nodes.
    private func updateSidebarReveal() {
        let active = zoomEnabled && mapUnderSidebarEnabled && zoomScale > 1.0
        guard active != sidebarRevealActive else { return }
        sidebarRevealActive = active
        if let mask = dungeonMask {
            let frame = dungeonFrameInScene()   // active-aware: full width while revealed
            mask.size = frame.size
            mask.position = frame.origin
        }
        applySidebarWash(active)
    }

    /// Fade the sidebar cell backgrounds (window cols 0…20, dungeon rows 3…31) so the
    /// magnified map shows behind them, and lift them above the crop so the wash sits over
    /// the dungeon (glyphs, at zPosition 1, stay on top and fully opaque). Restores to
    /// opaque, base z-order when inactive. `background.alpha` is independent of `bgcolor`,
    /// so engine colour updates don't disturb it.
    private func applySidebarWash(_ active: Bool) {
        guard !cells.isEmpty else { return }
        let alpha: CGFloat = active ? RogueScene.sidebarWashAlpha : 1.0
        let z: CGFloat = active ? 0.4 : 0.0   // above crop (0), below glyph (1)
        for x in 0..<RogueScene.zoomColMin {                       // cols 0…20
            for y in RogueScene.zoomRowMin...RogueScene.zoomRowMax { // rows 3…31
                let bg = cells[x][y].background
                bg.alpha = alpha
                bg.zPosition = z
            }
        }
    }

    /// SpriteKit calls this on the main thread at the top of every frame, immediately
    /// before it renders. Drain the engine thread's buffered batch (cell writes + the
    /// auto-follow camera) and apply it here, so every glyph the engine plotted and the
    /// camera move that follows it land in the SAME render pass — no engine-thread node
    /// write ever races the renderer. This is what keeps the player glyph and the camera
    /// locked together while moving over animated terrain (water/fire/lava); applying the
    /// camera alone left the glyph free to leak into a render a frame early, a fixed
    /// one-frame jump that reverts. Cells first, then the camera that frames them. The
    /// flat 1× / iPad path never buffers, so this is a cheap no-op there.
    override public func update(_ currentTime: TimeInterval) {
        super.update(currentTime)

        pendingLock.lock()
        let cellBatch = pendingCells.isEmpty ? nil : pendingCells
        if cellBatch != nil { pendingCells.removeAll(keepingCapacity: true) }
        let zoom = pendingZoom
        pendingZoom = nil
        pendingLock.unlock()

        if let cellBatch = cellBatch {
            let stride = gridSize.rows + 1
            for (key, pc) in cellBatch {
                applyCell(x: key / stride, y: key % stride,
                          code: pc.code, bgColor: pc.bgColor, fgColor: pc.fgColor)
            }
        }
        if let zoom = zoom {
            applyZoomToContainer(scale: zoom.scale,
                                 originXPoints: zoom.originXPoints,
                                 originYPoints: zoom.originYPoints)
        }
    }

    /// Keeps the crop mask sized to the dungeon frame and re-applies the current
    /// transform after a relayout (rotation / safe-area change).
    private func relayoutZoomLayer() {
        guard let mask = dungeonMask else { return }
        let frame = dungeonFrameInScene()
        mask.size = frame.size
        mask.position = frame.origin
        setZoom(scale: zoomScale, originXPoints: zoomOriginXPoints, originYPoints: zoomOriginYPoints)
    }
}

fileprivate extension RogueScene {

    // Create/find glyph textures
    func getTexture(glyph: String) -> SKTexture {
        return textureMap[glyph] ?? addTexture(glyph: glyph)
    }
    
    func createTextureFromGlyph(glyph: String, size: CGSize) -> SKTexture {
        // Apple Symbols provides U+26AA, for rings, which Arial does not.
        
        enum GlyphType {
            case letter
            case scroll
            case charm
            // Rings use codepoint 0xFFEE in both engines (Classic's RING_CHAR and,
            // via the CE bridge's G_RING mapping, BrogueCE too), rendered through
            // the `.ring` path below.
            case ring
            case foliage
            case amulet
            case weapon
            // Brogue SE status-blink symbols that Monaco lacks (U+2605 ★ paralyzed,
            // U+2665 ♥ healing, U+25C8 ◈ protected). Rendered from ArialUnicodeMS
            // like the special symbols below.
            case arialSymbol
            case glyph
            // CE tile-graphics glyphs (codepoints 0x4000+, emitted only by the
            // BrogueCE engine in tile/hybrid mode). Rendered from the "Brogue" font.
            case wall
            case monster
            case tile

            var fontName: String {
                switch self {
                case .wall, .monster, .tile:
                    return "Brogue"
                case .foliage, .ring, .weapon, .arialSymbol:
                    return "ArialUnicodeMS"
                default:
                    return "Monaco"
                }
            }

            /// True for the CE tile glyphs that draw from the "Brogue" font and
            /// therefore clamp against the Brogue-font scale base.
            var usesBrogueFont: Bool {
                switch self {
                case .wall, .monster, .tile: return true
                default: return false
                }
            }

            var scaleFactor: CGFloat {
                switch self {
                case .scroll, .weapon, .ring:
                    return 1.3

                case .foliage, .charm, .arialSymbol:
                    return 1.1

                // Tile categories — ported from the iBrogueCE reference renderer.
                case .wall:
                    return 1.1
                case .monster:
                    return 1.4
                case .tile:
                    return 1
                default:
                    return 1
                }
            }

            var drawingOptions: NSStringDrawingOptions {
                return [.usesFontLeading]
            }

            // TODO: fix charm
            init(glyph: String) {
                // CE tile glyphs live in a private codepoint range (0x4000+) that
                // only the BrogueCE engine emits. Classify those first so they
                // render from the Brogue tile font; everything below is the
                // shared text path used by both engines.
                if let scalar = glyph.unicodeScalars.first, scalar.value >= 0x4000 {
                    switch scalar.value {
                    case 0x4051, 0x4002: // U_TILES_WALL_TOP, U_TILES_WALL
                        self = .wall
                    case 0x4017...0x402a,
                         0x402e...0x403e,
                         0x4052...0x405a,
                         0x405c, 0x4061:
                        self = .monster
                    default:
                        self = .tile
                    }
                    return
                }

                // We want to use pretty font/centering if we can, but
                // it makes tExT LOOk liKe THiS so we're defining characters
                // that will be rendered at the same lineheight
                // Note: Items "call"ed with non-standard characters aren't covered
                // If some characters become ugly, this list can be expanded
                switch (glyph) {
                case "a"..."z",
                     "A"..."Z",
                     "0"..."9",
                     "!"..."?",
                     " ", "[", "/", "]", "^", "{", "|", "}", "~":
                    self = .letter
                case "\(UnicodeScalar(UInt32(FOLIAGE_CHAR))!)":
                    self = .foliage
                case "\(UnicodeScalar(UInt32(SCROLL_CHAR))!)":
                    self = .scroll
                case "\(UnicodeScalar(UInt32(CHARM_CHAR))!)":
                    self = .charm
                case "\(UnicodeScalar(UInt32(RING_CHAR))!)":
                    self = .ring
                case "\(UnicodeScalar(UInt32(AMULET_CHAR))!)":
                    self = .amulet
                case "\(UnicodeScalar(UInt32(WEAPON_CHAR))!)":
                    self = .weapon
                case "\u{2605}", // Brogue SE G_STUN_STAR ★ (paralyzed status-blink)
                     "\u{2665}", // Brogue SE G_HEART ♥ (healing status-blink)
                     "\u{25C8}": // Brogue SE G_SHIELD_CREST ◈ (protected status-blink)
                    self = .arialSymbol
                default:
                    self = .glyph
                }
            }
        }
        
        let glyphType = GlyphType(glyph: glyph)
        // Find ideal size for text
        let fontSize: CGFloat = 130 // Base size, we'll calculate from here
        let calcFont = UIFont(name: glyphType.fontName, size: fontSize)!
        
        var surface: UIImage {
            // Calculate font scale factor
            var scaleFactor: CGFloat {
                let calcAttributes = [convertFromNSAttributedStringKey(NSAttributedString.Key.font): calcFont]
                // If we calculate with the descender, the line height will be centered incorrectly for letters
                let calcOptions = glyphType.drawingOptions
                let calcBounds = glyph.boundingRect(with: CGSize(), options: calcOptions, attributes: convertToOptionalNSAttributedStringKeyDictionary(calcAttributes), context: nil)
                let rawScaleFactor = min(size.width / calcBounds.width, size.height / calcBounds.height)
                // Tile glyphs draw from the Brogue font, so clamp them against the
                // Brogue-font scale base; text glyphs keep the ArialUnicodeMS base.
                let baseMax = glyphType.usesBrogueFont ? brogueMaxScaleFactor : maxScaleFactor
                let clampedScaleFactor = max(baseMax * 0.8, min(rawScaleFactor, baseMax * 1.2)) // Within 20% of original

                return clampedScaleFactor * (glyphType.scaleFactor) // Shrink certain non-letters
            }
            
            // Actual font that we're going to render
            let font: UIFont
            let stringOrigin: CGPoint

            if case .letter = glyphType {
                // Baseline-aligned, descender-safe layout for text glyphs (a–z,
                // A–Z, 0–9, punctuation, brackets). The generic path below scales
                // a capital to fill the full cell height, which pushes descenders
                // (j, g, p, q, y) and tall brackets ([, ]) past the bottom edge of
                // the cell-sized texture and clips them — most visibly on iPhone,
                // where cells are smallest. Instead, scale so the font's whole line
                // box (ascent + descent) fits the cell, then place every glyph on a
                // shared baseline: nothing is clipped and text stays aligned.
                let ns = glyph as NSString
                let probe = UIFont(name: glyphType.fontName, size: fontSize)!
                let probeWidth = max(ns.size(withAttributes: [.font: probe]).width, 0.0001)
                let probeLineHeight = probe.ascender - probe.descender // descender is negative
                let fit = min(size.height / probeLineHeight, size.width / probeWidth)
                let letterFont = UIFont(name: glyphType.fontName, size: fontSize * fit)!

                let lineHeight = letterFont.ascender - letterFont.descender
                let topInset = (size.height - lineHeight) / 2
                let advance = ns.size(withAttributes: [.font: letterFont]).width

                font = letterFont
                // draw(at:) takes the top of the line box; the baseline sits at
                // topInset + ascender, so the descender bottom lands at
                // size.height - topInset and never crosses the cell edge.
                stringOrigin = CGPoint(x: (size.width - advance) / 2 + 1, y: topInset)
            } else {
                // Generic glyphs (items, monsters, tiles): fit-and-center.
                font = UIFont(name: glyphType.fontName, size: fontSize * scaleFactor)!
                let centerAttributes = convertToOptionalNSAttributedStringKeyDictionary([
                    convertFromNSAttributedStringKey(NSAttributedString.Key.font): font
                ])
                let realBounds: CGRect = glyph.boundingRect(with: CGSize(), options: glyphType.drawingOptions, attributes: centerAttributes, context: nil)
                stringOrigin = CGPoint(x: (size.width - realBounds.width)/2 - realBounds.origin.x + 1, y:
                                           font.descender - realBounds.origin.y + (size.height - realBounds.height)/2)
            }

            let fontAttributes = convertToOptionalNSAttributedStringKeyDictionary([
                convertFromNSAttributedStringKey(NSAttributedString.Key.font): font,
                convertFromNSAttributedStringKey(NSAttributedString.Key.foregroundColor): SKColor.white // White so we can blend it
            ])

            UIGraphicsBeginImageContext(size)
            glyph.draw(at: stringOrigin, withAttributes: fontAttributes)
            let surface = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            return surface!
        }
    
        return SKTexture(image: surface)
    }
    
    func addTexture(glyph: String) -> SKTexture {
        textureMap[glyph] = createTextureFromGlyph(glyph: glyph, size: cellSize)
        return textureMap[glyph]!
    }
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToOptionalNSAttributedStringKeyDictionary(_ input: [String: Any]?) -> [NSAttributedString.Key: Any]? {
	guard let input = input else { return nil }
	return Dictionary(uniqueKeysWithValues: input.map { key, value in (NSAttributedString.Key(rawValue: key), value)})
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromNSAttributedStringKey(_ input: NSAttributedString.Key) -> String {
	return input.rawValue
}
