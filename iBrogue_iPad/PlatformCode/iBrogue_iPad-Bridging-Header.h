//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "DirectionControlsViewController.h"

// Canonical glyph code points the shared RogueScene renderer keys off (used to be pulled in
// via Classic's Rogue.h before the engine moved to its own framework).
#import "BrogueGlyphs.h"

// BrogueClassic framework: Classic's host protocol + classic_start() entry points, and the
// BrogueGameEvent enum (moved here from the old RogueDriver.h). Relative path, like CE/SE below.
// (This transitively imports BrogueCEHost.h, which BrogueClassicHost extends.)
#import "../../BrogueClassic/BrogueClassicHost.h"

// BrogueCE framework: host protocol + ce_start() entry point. Relative path
// avoids needing the framework's public-header/module machinery for now.
#import "../../BrogueCE/BrogueCEHost.h"

// BrogueSE framework: SE's own entry points (se_start / se_requestTermination /
// se_setKeyboardLabelsEnabled). The framework is always linked and SE ships as a
// selectable engine alongside Classic and BrogueCE.
#import "../../BrogueSE/BrogueSEHost.h"

#define kROWS		(30+3+1)
#define kCOLS		100
#define FONT_SIZE	16
