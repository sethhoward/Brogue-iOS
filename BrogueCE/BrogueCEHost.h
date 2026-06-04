//
//  BrogueCEHost.h
//  BrogueCE
//
//  The contract between the BrogueCE engine (running inside this framework on a
//  background thread) and the host iOS app. The framework cannot see the app's
//  classes (BrogueViewController, SKViewPort), so the app passes an object
//  conforming to BrogueCEHost into ce_start(); the bridge routes the engine's
//  rendering / input / signaling through it.
//
//  This header is included by the framework's CEBridge.mm and by the app's
//  Objective-C bridging header, so it must use only Foundation / CoreGraphics
//  types.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrogueCEHost <NSObject>

// --- Rendering (invoked from the engine's background thread) ---------------
// Plots a single already-translated Unicode glyph at grid cell (x, y). Colors
// are the engine's native 0-100 RGB components; the host builds the platform
// color (this keeps the framework free of any CoreGraphics link dependency).
- (void)setCellAtX:(short)x
                 y:(short)y
              code:(uint32_t)code
             bgRed:(short)bgRed bgGreen:(short)bgGreen bgBlue:(short)bgBlue
             fgRed:(short)fgRed fgGreen:(short)fgGreen fgBlue:(short)fgBlue;

// --- Playfield geometry (points) -------------------------------------------
- (CGFloat)effectiveWidthPoints;
- (CGFloat)effectiveHeightPoints;
- (CGFloat)leftInsetPoints;

// --- Input source -----------------------------------------------------------
- (BOOL)hasKeyEvent;
- (uint8_t)dequeueKeyEvent;
- (BOOL)hasTouchEvent;
// Returns NO if there is no pending touch. Otherwise fills `outLocation` (in
// points) and `outPhase` (a UITouch.Phase raw value).
- (BOOL)dequeueTouchEvent:(CGPoint *)outLocation phase:(NSInteger *)outPhase;

// --- Misc -------------------------------------------------------------------
- (BOOL)controlKeyIsDown;

// UI state signal. Invoked when the engine's tablet UI mode changes, so the host
// can show/hide on-screen controls. Values match CE's CBrogueGameEvent enum:
// 0 = InMenu, 1 = InNormalPlay, 2 = ShowEscape, 3 = ShowKeyboardAndEscape.
- (void)setUIMode:(NSInteger)uiMode;

// True only while the CE title screen is showing — gates the version chooser.
- (void)setAtTitle:(BOOL)atTitle;

// Present the native file manager (CE title menu's "File Management" entry),
// scoped to the CE save directory.
- (void)presentFileManagement;

@end

#ifdef __cplusplus
extern "C" {
#endif

// Single exported entry point. Stores `host` and runs the engine's main loop
// (rogueMain) on the calling thread. Does not return until the engine exits.
void ce_start(id<BrogueCEHost> host);

// Requests that the running CE engine unwind out of its title-screen menu loop
// so rogueMain() returns and the engine thread can exit (used for in-process
// engine switching). Only meaningful while the engine is at the title screen.
void ce_requestTermination(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
