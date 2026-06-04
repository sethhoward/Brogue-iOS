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

    private func relayoutCells() {
        // Both the bottom (home-indicator) pad and the left/right (notch) pads
        // are only applied during gameplay. On title / menu screens the grid
        // fills the full scene.
        let effectiveLeft: CGFloat = paddingEnabled ? leftPadPixels : 0
        let effectiveRight: CGFloat = paddingEnabled ? rightPadPixels : 0
        let usableHeight = paddingEnabled ? size.height - bottomPad : size.height
        let usableWidth = max(size.width - effectiveLeft - effectiveRight, 0)
        let yOffset: CGFloat = paddingEnabled ? bottomPad : 0
        let xOffset: CGFloat = effectiveLeft
        cellSize = CGSize(
            width: usableWidth / CGFloat(gridSize.cols),
            height: usableHeight / CGFloat(gridSize.rows)
        )
        for x in 0..<cells.count {
            let column = cells[x]
            for y in 0..<column.count {
                let cell = column[y]
                cell.size = cellSize
                cell.position = CGPoint(
                    x: xOffset + CGFloat(x) * cellSize.width,
                    y: yOffset + CGFloat(gridSize.rows - y - 1) * cellSize.height
                )
            }
        }
    }
    
    override public func didMove(to view: SKView) {
        (cells.flatMap { $0 }).forEach {
            $0.background.anchorPoint = CGPoint(x: 0, y: 0)
            addChild($0.background)
            addChild($0.foreground)
        }
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
            case ring
            // CE's ring glyph is U+26AA (Classic's is 0xFFEE). Neither Monaco nor
            // ArialUnicodeMS carry it, so it's font-substituted and renders too
            // large for the cell (clipped at top). Same default font as `.glyph`,
            // just scaled down to fit — see scaleFactor below.
            case ringCE
            case foliage
            case amulet
            case weapon
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
                case .foliage, .ring, .weapon:
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

                case .foliage, .charm:
                    return 1.1

                // CE ring (U+26AA): shrink the substituted circle so it isn't
                // clipped. Tune this value if it's still too big/small.
                case .ringCE:
                    return 0.8

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
                case "\u{26AA}": // CE's ring glyph (U_CIRCLE)
                    self = .ringCE
                case "\(UnicodeScalar(UInt32(AMULET_CHAR))!)":
                    self = .amulet
                case "\(UnicodeScalar(UInt32(WEAPON_CHAR))!)":
                    self = .weapon
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
            let font = UIFont(name: glyphType.fontName, size: fontSize * scaleFactor)!
            let fontAttributes = [
                convertFromNSAttributedStringKey(NSAttributedString.Key.font): font,
                convertFromNSAttributedStringKey(NSAttributedString.Key.foregroundColor): SKColor.white // White so we can blend it
            ]
            
            let realBounds: CGRect = glyph.boundingRect(with: CGSize(), options: glyphType.drawingOptions, attributes: convertToOptionalNSAttributedStringKeyDictionary(fontAttributes), context: nil)
            let stringOrigin = CGPoint(x: (size.width - realBounds.width)/2 - realBounds.origin.x + 1, y:
                                           font.descender - realBounds.origin.y + (size.height - realBounds.height)/2)
           
            UIGraphicsBeginImageContext(size)
            glyph.draw(at: stringOrigin, withAttributes: convertToOptionalNSAttributedStringKeyDictionary(fontAttributes))
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
