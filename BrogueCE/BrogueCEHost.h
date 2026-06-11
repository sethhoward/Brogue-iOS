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
// Inverts the dungeon-map pinch-zoom (iPhone) for a touch point in view points:
// returns the point the engine should treat the touch as. Identity at 1× and
// for touches outside the zoomable map.
- (CGPoint)unzoomedPoint:(CGPoint)point;

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

// Fire a haptic when the player takes damage, scaled by severity (0 = ordinary
// hit, 1 = now under 40% health, 2 = fatal). The host gates this on its own
// haptics setting and device support, so the engine can call it freely.
- (void)playDamageHaptic:(NSInteger)severity;

// True while the player is aiming a throw/zap (the engine's targeting loop), so
// the host can move the escape button aside and enable the aiming magnifier.
- (void)setTargeting:(BOOL)targeting;

// True while a creature/item description box is lingering on the map (the cursor
// examine loop), so the host can suspend pinch-zoom to 1× and not clip the box.
- (void)setExamining:(BOOL)examining;

// Reports the player's WINDOW cell (already mapToWindow-converted) after each
// screen refresh, so the host's iPhone pinch-zoom can keep the player centered.
- (void)setPlayerWindowX:(short)x y:(short)y;

// --- Game Center ------------------------------------------------------------
// Invoked at game over with the final score, for the CE leaderboard. The bridge
// has already filtered out non-standard variants and wizard runs before calling.
- (void)reportCEScore:(long)score;
// Unlock a Game Center achievement by its App Store Connect identifier.
- (void)submitCEAchievementWithID:(NSString *)identifier;

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
