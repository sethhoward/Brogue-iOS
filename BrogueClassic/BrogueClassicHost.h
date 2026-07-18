//
//  BrogueClassicHost.h
//  BrogueClassic
//
//  The contract between the Classic (1.7.5) Brogue engine (running inside this framework
//  on a background thread) and the host iOS app. Mirrors BrogueCEHost: the framework
//  cannot see the app's classes (BrogueViewController, SKViewPort), so the app passes an
//  object conforming to BrogueClassicHost into classic_start() and the bridge routes the
//  engine's rendering / input / signaling through it.
//
//  Classic reuses the shared BrogueCEHost surface (rendering, geometry, input, examine /
//  menu boxes, player-window, travel, damage haptic, control key) and adds the handful of
//  callbacks Classic needs that CE/SE do not: its BrogueGameEvent UI signal, its own
//  targeting / file-management / Game Center routing, and score/achievement reporting to
//  the Classic leaderboard.
//
//  Included by the framework's ClassicBridge.mm and by the app's Objective-C bridging
//  header, so it must use only Foundation / CoreGraphics types. The BrogueGameEvent enum
//  lives here (moved from the old RogueDriver.h) because the app's Swift UI depends on it.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "../BrogueCE/BrogueCEHost.h"

NS_ASSUME_NONNULL_BEGIN

// Engine-emitted UI events that drive the app's `lastBrogueGameEvent` state machine —
// Classic's finer-grained analog of CE's setUIMode:. (Moved verbatim from RogueDriver.h.)
typedef NS_ENUM(NSInteger, BrogueGameEvent) {
    BrogueGameEventActionMenuOpen = 0,
    BrogueGameEventActionMenuClose,
    BrogueGameEventKeyBoardInputRequired,
    BrogueGameEventWaitingForConfirmation,
    BrogueGameEventConfirmationComplete,
    BrogueGameEventOpenedInventory,
    BrogueGameEventClosedInventory,
    BrogueGameEventInventoryItemAction,
    BrogueGameEventShowTitle,
    BrogueGameEventStartNewGame,
    BrogueGameEventOpenGame,
    BrogueGameEventBeginOpenGame,
    BrogueGameEventOpenGameFinished,
    BrogueGameEventPlayRecording,
    BrogueGameEventShowHighScores,
    BrogueGameEventPlayBackPanic,
    BrogueGameEventMessagePlayerHasDied,
    BrogueGameEventPlayerHasDiedMessageAcknowledged,
};

@protocol BrogueClassicHost <BrogueCEHost>

// Classic-only: an engine UI event → the app's `lastBrogueGameEvent`. (Classic drives far
// more UI off this than CE's coarse setUIMode:, so it can't reuse setUIMode:.)
- (void)setGameEvent:(NSInteger)event;

// Classic-only targeting: like BrogueCEHost's setTargeting: but Classic also toggles the
// on-screen escape button, so it routes through the VC's Classic-specific handler.
- (void)setClassicTargeting:(BOOL)targeting;

// Classic title menu "File Management" → the native file browser scoped to Classic's flat
// Documents/ save directory (distinct from CE's Documents/ce).
- (void)presentClassicFileManagement;

// Classic title menu "Game Center" → the Classic leaderboard (iBrogue_High_Score).
- (void)presentClassicGameCenter;

// Final score at game over, reported to the Classic leaderboard (iBrogue_High_Score).
- (void)reportClassicScore:(long)score;

// Unlock a Game Center achievement (a Classic feat) by its identifier.
- (void)submitClassicAchievement:(NSString *)identifier;

@end

#ifdef __cplusplus
extern "C" {
#endif

// Single entry point: stores `host`, restores persisted state, and runs the engine's main
// loop (rogueMain) on the calling thread. Does not return until the engine exits.
void classic_start(id<BrogueClassicHost> host);

// In-process engine switching: ask the running Classic engine to leave its title-menu loop
// so rogueMain() returns and the engine thread can be torn down.
void classic_requestTermination(void);

// iOS port (iBrogue): background suspend/resume. classic_requestBackgroundSave() is called
// when the app backgrounds; the engine thread snapshots exact state and marks it for
// cold-launch resume. classic_clearResumeMarker() drops that marker when the app survived
// the background. See docs/design/background-suspend-resume.md.
void classic_requestBackgroundSave(void);
void classic_clearResumeMarker(void);

// iOS port (iBrogue): true on iPhone; drives Classic's phone-specific layout. Call before
// classic_start so the engine sees it at startup.
void classic_setPhoneLayout(int isPhone);

// iOS port (iBrogue): reports hardware-keyboard presence; gates Classic's KEYBOARD_LABELS
// hotkey hints. Called on GCKeyboard connect/disconnect.
void classic_setHardwareKeyboardConnected(int connected);

// iOS port (iBrogue): enables Classic's in-game hotkey labels (KEYBOARD_LABELS) when a keyboard is
// present. The labels are scheme-aware. Called on GCKeyboard connect/disconnect.
void classic_setKeyboardLabelsEnabled(int enabled);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
