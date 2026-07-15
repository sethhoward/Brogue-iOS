//
//  BrogueGlyphs.h
//  Brogue
//
//  Canonical glyph code points the shared RogueScene renderer maps to special fonts
//  (ArialUnicodeMS etc.), independent of which engine is running. These are the UNICODE
//  values every engine emits for these glyphs: they mirror the Classic engine's *_CHAR
//  defines (BrogueClassic/Engine/Rogue.h, USE_UNICODE block) and BrogueCE/SE's matching
//  U_* code points (CEBridge.mm). Kept app-side so the platform layer (RogueScene.swift)
//  doesn't have to import an engine's full Rogue.h just for these six constants.
//

#ifndef BrogueGlyphs_h
#define BrogueGlyphs_h

#define FOLIAGE_CHAR    0x2648  // Aries symbol
#define AMULET_CHAR     0x2640  // ankh
#define SCROLL_CHAR     0x266A  // music note
#define RING_CHAR       0xffee  // renders through RogueScene's .ring (ArialUnicodeMS) path
#define CHARM_CHAR      0x03DF  // lightning bolt
#define WEAPON_CHAR     0x2191  // up arrow

#endif /* BrogueGlyphs_h */
