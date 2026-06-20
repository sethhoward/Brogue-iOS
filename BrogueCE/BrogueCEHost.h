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
// iOS port (iBrogue): returns the next key code and fills its modifier state and `raw` flag. `raw` is
// YES only for hardware character keys eligible for keyboard-scheme remapping (the bridge runs those
// through applyKeyboardScheme); synthesized on-screen keys are already canonical (raw NO).
- (int32_t)dequeueKeyEventWithShift:(BOOL *)shift control:(BOOL *)control raw:(BOOL *)raw;
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

// Show the on-screen keyboard for engine text entry (naming a save, entering a
// seed). `defaultText` pre-fills the field with the engine's default so backspace
// can clear it; `numeric` picks a number pad (with a Done bar) for seed entry vs.
// the default keyboard.
- (void)requestTextInput:(NSString *)defaultText numeric:(BOOL)numeric;

// Present the native file manager (CE title menu's "File Management" entry),
// scoped to the CE save directory.
- (void)presentFileManagement;

// Present the Game Center leaderboard (CE title menu's View > "Game Center"
// entry), scoped to the CE leaderboard (BrogueCE_High_Score).
- (void)presentGameCenter;

// Fire a haptic when the player takes damage, scaled by severity (0 = ordinary
// hit, 1 = now under 40% health, 2 = fatal). The host gates this on its own
// haptics setting and device support, so the engine can call it freely.
- (void)playDamageHaptic:(NSInteger)severity;

// iOS port (Brogue SE): fire a haptic when an unseen creature reacts to the player's
// noise. stage 0 = something just began investigating you (one short, sharp tap);
// stage 1 = an investigator locked onto you and is now hunting (two quick taps).
// iPhone-only; the host gates on its own haptics setting and device support, so the
// engine can call it freely. (Only the SE engine calls this; CE never does.)
- (void)playDetectionHaptic:(NSInteger)stage;

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

// iOS port (iBrogue): toggles the engine's in-game hotkey labels (KEYBOARD_LABELS).
// The host calls this on GCKeyboard connect/disconnect so CE shows keyboard shortcut
// hints only when a hardware keyboard is attached, mirroring the Classic engine.
void ce_setKeyboardLabelsEnabled(int enabled);

// iOS port (iBrogue): reports hardware-keyboard presence (distinct from KEYBOARD_LABELS).
// Gates CE's "Press <?> for help" welcome hint. Called on GCKeyboard connect/disconnect.
void ce_setHardwareKeyboardConnected(int connected);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
