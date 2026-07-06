//
//  BrogueSEHost.h
//  BrogueSE
//
//  Brogue SE's entry-point declarations. SE reuses the host contract defined by
//  BrogueCE (the BrogueCEHost protocol is single-sourced in the master-tracked
//  BrogueCE framework so a protocol change propagates to both engines); SE only
//  adds its own uniquely-named exported entry points so the app can link and
//  drive both engines in the same process.
//
//  Included by the framework's SEBridge.mm and by the app's Objective-C bridging
//  header.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// The host protocol (BrogueCEHost) lives in the BrogueCE framework. Relative path,
// mirroring how the bridge imports it.
#import "../BrogueCE/BrogueCEHost.h"

#ifdef __cplusplus
extern "C" {
#endif

// Single exported entry point. Stores `host` and runs the SE engine's main loop
// (rogueMain) on the calling thread. Does not return until the engine exits.
// Sibling of ce_start(); distinct symbol so the app can link both frameworks.
void se_start(id<BrogueCEHost> host);

// Requests that the running SE engine unwind out of its title-screen menu loop so
// rogueMain() returns and the engine thread can exit (in-process engine switching).
// Only meaningful while the engine is at the title screen.
void se_requestTermination(void);

// iOS port (Brogue SE): toggles the engine's in-game hotkey labels (KEYBOARD_LABELS).
// The host calls this on GCKeyboard connect/disconnect so SE shows keyboard shortcut
// hints only when a hardware keyboard is attached, mirroring Classic / CE.
void se_setKeyboardLabelsEnabled(int enabled);

// iOS port (Brogue SE): reports hardware-keyboard presence (distinct from KEYBOARD_LABELS).
// Gates SE's "Press <?> for help" welcome hint. Called on GCKeyboard connect/disconnect.
void se_setHardwareKeyboardConnected(int connected);

// iOS port (Brogue SE): background suspend/resume. se_requestBackgroundSave() is called when the
// app backgrounds; the engine thread snapshots exact state and marks it for cold-launch resume.
// se_clearResumeMarker() drops that marker when the app survived the background (the in-memory
// game is authoritative). See docs/design/background-suspend-resume.md.
void se_requestBackgroundSave(void);
void se_clearResumeMarker(void);

// iOS port (Brogue SE): game handoff. Called OFF the main thread by the handoff source: flushes the
// live recording on the engine thread, then returns the exact-state save bytes to stream to the
// receiving device. nil if there's no live game or the flush times out. See docs/design/game-handoff.md.
NSData * _Nullable se_flushRecordingForHandoff(void);

#ifdef __cplusplus
}
#endif
