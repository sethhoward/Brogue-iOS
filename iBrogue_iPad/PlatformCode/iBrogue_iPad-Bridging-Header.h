//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "Rogue.h"
#import "RogueDriver.h"
#import "DirectionControlsViewController.h"

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
