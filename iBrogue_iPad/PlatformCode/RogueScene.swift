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
    fileprivate let cellSize: CGSize
    
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
    
    public init(size: CGSize, rows: Int, cols: Int) {
        gridSize = CGSize(rows: rows, cols: cols)
        cellSize = CGSize(width: CGFloat(size.width) / CGFloat(cols), height: CGFloat(size.height) / CGFloat(rows))
        super.init(size: size)
        
        if #available(iOS 10.0, *) {}
        else {
            sceneDidLoad()
        }
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
        for x in 0...gridSize.cols {
            var row = [Cell]()
            for y in 0...gridSize.rows {
                let newCell = Cell(x: CGFloat(x) * cellSize.width, y: CGFloat(gridSize.rows - y - 1) * cellSize.height, size: CGSize(width: cellSize.width, height: cellSize.height))
                row.append(newCell)
            }
            cells.append(row)
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
            case foliage
            case amulet
            case weapon
            case glyph
            
            var fontName: String {
                switch self {
                case .foliage, .ring, .weapon:
                    return "ArialUnicodeMS"
                default:
                    return "Monaco"
                }
            }
            
            var scaleFactor: CGFloat {
                switch self {
                case .scroll, .weapon, .ring:
                    return 1.3
                
                case .foliage, .charm:
                    return 1.1
                default:
                    return 1
                }
            }
            
            var drawingOptions: NSStringDrawingOptions {
                return [.usesFontLeading]
            }
            
            // TODO: fix charm
            init(glyph: String) {
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
                let clampedScaleFactor = max(maxScaleFactor * 0.8, min(rawScaleFactor, maxScaleFactor * 1.2)) // Within 20% of original
                
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
