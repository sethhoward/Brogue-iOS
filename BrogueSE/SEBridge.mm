//
//  SEBridge.mm
//  BrogueSE
//
//  Objective-C++ bridge between the Brogue SE C engine (vendored in Engine/, a
//  fork of BrogueCE 1.15) and the host iOS app. The engine declares its platform
//  contract as free C functions in Rogue.h (no brogueConsole struct in this fork),
//  so this file provides definitions for every platform symbol the engine
//  references, plus the single exported entry point se_start().
//
//  This is SE's own copy of the bridge, compiled into BrogueSE.framework. It is a
//  sibling of BrogueCE's CEBridge.mm; the engine symbols are isolated per-framework
//  (two-level namespace) and only the exported entry points differ (se_* vs ce_*).
//
//  Rendering / input / signaling are routed to an app-supplied object that
//  conforms to BrogueCEHost (single-sourced in the BrogueCE framework).
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdlib.h>

// iOS port (Brogue SE): capture the build-config DEBUG flag (set in the BrogueSE framework's Debug
// configuration only) BEFORE Engine/Rogue.h #undefs it and repurposes DEBUG as `if (WIZARD_MODE)`.
// Gates developer-only, never-ship instrumentation (e.g. the rest-stats CSV) to Debug builds.
#if defined(DEBUG) && DEBUG
#define SE_DEBUG_BUILD 1
#else
#define SE_DEBUG_BUILD 0
#endif

#import "Engine/Rogue.h"
// iOS port (Brogue SE): the host protocol is single-sourced in the master-tracked
// BrogueCE framework so a host-protocol change propagates to both engines. SE only
// adds its own entry-point declarations (BrogueSEHost.h).
#import "../BrogueCE/BrogueCEHost.h"
#import "BrogueSEHost.h"

// ---------------------------------------------------------------------------
// Unicode code points for the non-ASCII glyphs. Upstream CE defines these in
// platform/platform.h (which we don't vendor, as it's the SDL/curses platform
// header). Mirrored here for the text-mode glyph translation below.
// ---------------------------------------------------------------------------
#define U_MIDDLE_DOT          0x00b7
#define U_BLACK_STAR          0x2605 // iOS port (Brogue SE): G_STUN_STAR (paralyzed status-blink). Not in Monaco; RogueScene routes it through ArialUnicodeMS (like the ring/foliage glyphs).
#define U_INVERTED_QUESTION   0x00bf // iOS port (Brogue SE): G_INVERTED_QUESTION (confused status-blink). Present in Monaco, so it renders through the default text path.
#define U_BLACK_HEART         0x2665 // iOS port (Brogue SE): G_HEART (healing status-blink). Not in Monaco; RogueScene routes it through ArialUnicodeMS (like the star).
#define U_SHIELD_CREST        0x25c8 // iOS port (Brogue SE): G_SHIELD_CREST (protected status-blink). Not in Monaco; RogueScene routes it through ArialUnicodeMS (like the star/heart).
#define U_FOUR_DOTS           0x2237
#define U_DIAMOND             0x25c7
#define U_FLIPPED_V           0x22CF
#define U_ARIES               0x2648
#define U_ESZETT              0x00df
#define U_ANKH                0x2640
#define U_MUSIC_NOTE          0x266A
#define U_CIRCLE              0x26AA
// Match Classic's RING_CHAR (iBrogue_iPad/BrogueCode/Rogue.h) so the ring renders
// through RogueScene's `.ring` path (ArialUnicodeMS) as a proper ring, not the
// substituted circle that U_CIRCLE (0x26AA) produces via the `.ringCE` fallback.
#define U_RING                0xFFEE
#define U_LIGHTNING_BOLT      0x03DF
#define U_FILLED_CIRCLE       0x25cf
#define U_NEUTER              0x26b2
#define U_U_ACUTE             0x00da
#define U_CURRENCY            0x00A4
#define U_UP_ARROW            0x2191
#define U_DOWN_ARROW          0x2193
#define U_LEFT_ARROW          0x2190
#define U_RIGHT_ARROW         0x2192
#define U_OMEGA               0x03A9
#define U_CIRCLE_BARS         0x29F2
#define U_FILLED_CIRCLE_BARS  0x29F3
#ifdef BROGUE_TABLET
#define U_LEFT_TRIANGLE       0x25C4
#else
#define U_LEFT_TRIANGLE       0x1F780
#endif

// ---------------------------------------------------------------------------
// Host + shared state
// ---------------------------------------------------------------------------
static id<BrogueCEHost> gHost = nil;

// Set by se_requestTermination() (UI thread), read by the engine thread. When
// true, the bridge unblocks the title-screen input wait and the engine's
// titleMenu hook returns with rogue.nextGame = NG_QUIT, so rogueMain() exits.
// Defined with C linkage so the vendored engine (MainMenu.c) can extern it.
extern "C" { volatile boolean brogueSETerminationRequested = false; }

// iOS port (Brogue SE): background suspend/resume. Set by the host (se_requestBackgroundSave)
// when the app backgrounds; read by the engine thread, which snapshots exact state at its next
// poll point and records a one-shot resume marker so a cold launch after an OS kill resumes
// straight into the game. See docs/design/background-suspend-resume.md.
static volatile bool gSEBackgroundSaveRequested = false;
static NSString *const kSEResumePathKey = @"se resume path";

// iOS port (Brogue SE): game-handoff recording flush. The handoff source (OFF the main thread) sets
// gSEHandoffFlushRequested and waits on gSEHandoffFlushDone; the engine thread flushes the live
// recording to currentFilePath at its next poll and signals, so the source can read the exact-state
// bytes and stream them to the receiving device. See docs/design/game-handoff.md.
static volatile bool gSEHandoffFlushRequested = false;
static dispatch_semaphore_t gSEHandoffFlushDone = nil;

// Engine globals (defined in the vendored engine; this file declares them locally near each use).
// Declared here too so the background-snapshot helper below can read them. C linkage to match the
// engine's C definitions (and the other declarations in this file).
extern "C" {
extern playerCharacter rogue;
extern char currentFilePath[BROGUE_FILENAME_MAX];
}

// CE's commitDraws() only re-plots cells that changed vs its previouslyPlottedCells
// cache. That cache survives a teardown/reboot, but the shared RogueScene was
// changed by the other engine in the meantime — so cells CE thinks are current
// are actually stale on screen. After (re)entry we force one full redraw
// (refreshScreen plots every cell and resyncs the cache).
static volatile bool gNeedsFullRedraw = false;

// CE's engine sets this global to signal its tablet UI state (menu / normal play
// / escape / keyboard). We poll it each event-loop iteration and report changes
// to the host so it can show/hide on-screen controls.
extern CBrogueGameEvent uiMode;
static int gLastReportedUIMode = -1;

static void reportUIModeIfChanged(void) {
    if (gHost && (int)uiMode != gLastReportedUIMode) {
        gLastReportedUIMode = (int)uiMode;
        [gHost setUIMode:(NSInteger)uiMode];
    }
}

// Set by the engine (mainBrogueJunction) ONLY while the title screen is showing.
// Distinct from uiMode==InMenu, which is also set for in-game menus — so this is
// what gates the version chooser (and prevents an in-game engine switch).
extern "C" { volatile boolean brogueCEAtTitle = false; }
static int gLastReportedAtTitle = -1;
// iOS port (iBrogue): last game depth forwarded to the host for the cross-device Continuity Handoff
// activity (see ceSetGameContext below). Reset when the title reappears so a new game re-forwards its
// first depth. See docs/design/game-handoff.md.
static short gLastHandoffDepth = -1;

static void reportAtTitleIfChanged(void) {
    if (gHost) {
        int v = brogueCEAtTitle ? 1 : 0;
        if (v != gLastReportedAtTitle) {
            gLastReportedAtTitle = v;
            if (brogueCEAtTitle) gLastHandoffDepth = -1;   // iOS port (iBrogue): re-forward depth next game
            [gHost setAtTitle:(BOOL)brogueCEAtTitle];
        }
    }
}

// ---------------------------------------------------------------------------
// Platform-provided globals (owned by the platform layer upstream).
// ---------------------------------------------------------------------------
boolean serverMode = false;
boolean nonInteractivePlayback = false;
boolean hasGraphics = true;
enum graphicsModes graphicsMode = TEXT_GRAPHICS;

// iOS port (iBrogue): reads the persisted text/tiles/hybrid choice (see below).
static enum graphicsModes ceLoadPersistedGraphicsMode(void);
static enum keyboardScheme ceLoadPersistedKeyboardScheme(void);

// ---------------------------------------------------------------------------
// glyphToUnicode: CE separates the logical display glyph (an enum, to support
// tile graphics) from the rendered character. We render in text mode, so the
// bridge translates the enum back to a Unicode code point. Ported from CE's
// platform/platformdependent.c (text-mode path only).
// ---------------------------------------------------------------------------
static unsigned int ce_glyphToUnicode(enum displayGlyph glyph) {
    if (glyph < 128) return glyph;

    switch (glyph) {
        case G_UP_ARROW: return U_UP_ARROW;
        case G_DOWN_ARROW: return U_DOWN_ARROW;
        case G_POTION: return '!';
        case G_GRASS: return '"';
        case G_WALL: return '#';
        case G_DEMON: return '&';
        case G_OPEN_DOOR: return '\'';
        case G_GOLD: return '*';
        case G_CLOSED_DOOR: return '+';
        case G_RUBBLE: return ',';
        case G_KEY: return '-';
        case G_BOG: return '~';
        case G_CHAIN_TOP_LEFT:
        case G_CHAIN_BOTTOM_RIGHT:
            return '\\';
        case G_CHAIN_TOP_RIGHT:
        case G_CHAIN_BOTTOM_LEFT:
            return '/';
        case G_CHAIN_TOP:
        case G_CHAIN_BOTTOM:
            return '|';
        case G_CHAIN_LEFT:
        case G_CHAIN_RIGHT:
            return '-';
        case G_FOOD: return ';';
        case G_UP_STAIRS: return '<';
        case G_VENT: return '=';
        case G_DOWN_STAIRS: return '>';
        case G_PLAYER: return '@';
        case G_BOG_MONSTER: return 'B';
        case G_CENTAUR: return 'C';
        case G_DRAGON: return 'D';
        case G_FLAMEDANCER: return 'F';
        case G_GOLEM: return 'G';
        case G_TENTACLE_HORROR: return 'H';
        case G_IFRIT: return 'I';
        case G_JELLY: return 'J';
        case G_KRAKEN: return 'K';
        case G_LICH: return 'L';
        case G_NAGA: return 'N';
        case G_OGRE: return 'O';
        case G_PHANTOM: return 'P';
        case G_REVENANT: return 'R';
        case G_SALAMANDER: return 'S';
        case G_TROLL: return 'T';
        case G_UNDERWORM: return 'U';
        case G_VAMPIRE: return 'V';
        case G_WRAITH: return 'W';
        case G_ZOMBIE: return 'Z';
        case G_ARMOR: return '[';
        case G_STAFF: return '/';
        case G_WEB: return ':';
        case G_MOUND: return 'a';
        case G_BLOAT: return 'b';
        case G_CENTIPEDE: return 'c';
        case G_DAR_BLADEMASTER: return 'd';
        case G_EEL: return 'e';
        case G_FURY: return 'f';
        case G_GOBLIN: return 'g';
        case G_IMP: return 'i';
        case G_JACKAL: return 'j';
        case G_KOBOLD: return 'k';
        case G_MONKEY: return 'm';
        case G_PIXIE: return 'p';
        case G_RAT: return 'r';
        case G_SPIDER: return 's';
        case G_TOAD: return 't';
        case G_BAT: return 'v';
        case G_WISP: return 'w';
        case G_PHOENIX: return 'P';
        case G_ALTAR: return '|';
        case G_LIQUID: return '~';
        case G_FLOOR: return U_MIDDLE_DOT;
        case G_CHASM: return U_FOUR_DOTS;
        case G_TRAP: return U_DIAMOND;
        case G_FIRE: return U_FLIPPED_V;
        case G_FOLIAGE: return U_ARIES;
        case G_AMULET: return U_ANKH;
        case G_SCROLL: return U_MUSIC_NOTE;
        case G_RING: return U_RING;
        case G_WEAPON: return U_UP_ARROW;
        case G_GEM: return U_FILLED_CIRCLE;
        case G_TOTEM: return U_NEUTER;
        case G_GOOD_MAGIC: return U_FILLED_CIRCLE_BARS;
        case G_BAD_MAGIC: return U_CIRCLE_BARS;
        case G_DOORWAY: return U_OMEGA;
        case G_CHARM: return U_LIGHTNING_BOLT;
        case G_WALL_TOP: return '#';
        case G_DAR_PRIESTESS: return 'd';
        case G_DAR_BATTLEMAGE: return 'd';
        case G_GOBLIN_MAGIC: return 'g';
        case G_GOBLIN_CHIEFTAN: return 'g';
        case G_OGRE_MAGIC: return 'O';
        case G_GUARDIAN: return U_ESZETT;
        case G_WINGED_GUARDIAN: return U_ESZETT;
        case G_EGG: return U_FILLED_CIRCLE;
        case G_WARDEN: return 'Y';
        case G_DEWAR: return '&';
        case G_ANCIENT_SPIRIT: return 'M';
        case G_LEVER: return '/';
        case G_LEVER_PULLED: return '\\';
        case G_BLOODWORT_STALK: return U_ARIES;
        case G_FLOOR_ALT: return U_MIDDLE_DOT;
        case G_UNICORN: return U_U_ACUTE;
        case G_TURRET: return U_FILLED_CIRCLE;
        case G_WAND: return '~';
        case G_GRANITE: return '#';
        case G_CARPET: return U_MIDDLE_DOT;
        case G_CLOSED_IRON_DOOR: return '+';
        case G_OPEN_IRON_DOOR: return '\'';
        case G_TORCH: return '#';
        case G_CRYSTAL: return '#';
        case G_PORTCULLIS: return '#';
        case G_BARRICADE: return '#';
        case G_STATUE: return U_ESZETT;
        case G_CRACKED_STATUE: return U_ESZETT;
        case G_CLOSED_CAGE: return '#';
        case G_OPEN_CAGE: return '|';
        case G_PEDESTAL: return '|';
        case G_CLOSED_COFFIN: return '-';
        case G_OPEN_COFFIN: return '-';
        case G_MAGIC_GLYPH: return U_FOUR_DOTS;
        case G_BRIDGE: return '=';
        case G_BONES: return ',';
        case G_ELECTRIC_CRYSTAL: return U_CURRENCY;
        case G_ASHES: return '\'';
        case G_BEDROLL: return '=';
        case G_BLOODWORT_POD: return '*';
        case G_VINE: return ':';
        case G_NET: return ':';
        case G_LICHEN: return '"';
        case G_PIPES: return '+';
        case G_SAC_ALTAR: return '|';
        case G_ORB_ALTAR: return '|';
        case G_LEFT_TRIANGLE: return U_LEFT_TRIANGLE;
        case G_STUN_STAR: return U_BLACK_STAR; // iOS port (Brogue SE): paralyzed status-blink star (see Rogue.h G_STUN_STAR).
        case G_INVERTED_QUESTION: return U_INVERTED_QUESTION; // iOS port (Brogue SE): confused status-blink (see Rogue.h G_INVERTED_QUESTION).
        case G_HEART: return U_BLACK_HEART; // iOS port (Brogue SE): healing status-blink (see Rogue.h G_HEART).
        case G_SHIELD_CREST: return U_SHIELD_CREST; // iOS port (Brogue SE): protected status-blink (see Rogue.h G_SHIELD_CREST).
        default: return '?';
    }
}

// ---------------------------------------------------------------------------
// isEnvironmentGlyph: tells whether a display glyph is part of the environment
// (terrain) vs. an item or creature. In HYBRID graphics mode only environment
// glyphs are drawn as tiles; items/creatures stay as text. Ported verbatim from
// CE's platform/platformdependent.c (which we don't vendor — it's the SDL
// platform layer). Used by plotChar's tile-encoding path below.
// ---------------------------------------------------------------------------
static boolean ce_isEnvironmentGlyph(enum displayGlyph glyph) {
    switch (glyph) {
        // items
        case G_AMULET: case G_ARMOR: case G_BEDROLL: case G_CHARM:
        case G_DEWAR: case G_EGG: case G_FOOD: case G_GEM: case G_BLOODWORT_POD:
        case G_GOLD: case G_KEY: case G_POTION: case G_RING:
        case G_SCROLL: case G_STAFF: case G_WAND: case G_WEAPON: case G_LEFT_TRIANGLE:
            return false;

        // creatures
        case G_ANCIENT_SPIRIT: case G_BAT: case G_BLOAT: case G_BOG_MONSTER:
        case G_CENTAUR: case G_CENTIPEDE: case G_DAR_BATTLEMAGE: case G_DAR_BLADEMASTER:
        case G_DAR_PRIESTESS: case G_DEMON: case G_DRAGON: case G_EEL:
        case G_FLAMEDANCER: case G_FURY: case G_GOBLIN: case G_GOBLIN_CHIEFTAN:
        case G_GOBLIN_MAGIC: case G_GOLEM: case G_GUARDIAN: case G_IFRIT:
        case G_IMP: case G_JACKAL: case G_JELLY: case G_KOBOLD:
        case G_KRAKEN: case G_LICH: case G_MONKEY: case G_MOUND:
        case G_NAGA: case G_OGRE: case G_OGRE_MAGIC: case G_PHANTOM:
        case G_PHOENIX: case G_PIXIE: case G_PLAYER: case G_RAT:
        case G_REVENANT: case G_SALAMANDER: case G_SPIDER: case G_TENTACLE_HORROR:
        case G_TOAD: case G_TROLL: case G_UNDERWORM: case G_UNICORN:
        case G_VAMPIRE: case G_WARDEN: case G_WINGED_GUARDIAN: case G_WISP:
        case G_WRAITH: case G_ZOMBIE:
            return false;

        // everything else is considered part of the environment
        default:
            return true;
    }
}

// ---------------------------------------------------------------------------
// Exported entry point.
// ---------------------------------------------------------------------------
// Establishes a writable working directory for the engine's relative file I/O
// (recordings, saves). Brogue SE files are partitioned into Documents/se so they
// never collide with the Classic engine's files in Documents/ or BrogueCE's in
// Documents/ce. Mirrors Classic's initializeBrogueSaveLocation(), scoped to se/.
static void initializeBrogueCESaveLocation(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *ceDir = [documents stringByAppendingPathComponent:@"se"];

    if (![manager fileExistsAtPath:ceDir]) {
        [manager createDirectoryAtPath:ceDir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    // Relative paths the engine opens (e.g. the recording file) now resolve here.
    [manager changeCurrentDirectoryPath:ceDir];
}

extern "C" __attribute__((visibility("default"))) void se_start(id<BrogueCEHost> host) {
    gHost = host;
    // iOS port (iBrogue): restore the player's last-chosen graphics mode so the
    // text/tiles/hybrid selection persists across launches and future runs.
    graphicsMode = ceLoadPersistedGraphicsMode();
    // iOS port (iBrogue): restore the player's chosen keyboard scheme (Classic / Modern).
    rogueKeyboardScheme = ceLoadPersistedKeyboardScheme();
    brogueSETerminationRequested = false;
    brogueCEAtTitle = false;
    gNeedsFullRedraw = true; // resync the shared scene on (re)entry
    gLastReportedUIMode = -1; // force a UI-mode report on (re)entry
    gLastReportedAtTitle = -1; // force an at-title report on (re)entry
    initializeBrogueCESaveLocation();
    rogueMain();
}

extern "C" __attribute__((visibility("default"))) void se_requestTermination(void) {
    brogueSETerminationRequested = true;
}

// iOS port (Brogue SE): engine-thread only. If a background snapshot was requested, flush the
// live recording so currentFilePath holds every input so far (exact state, even mid-animation —
// replay regenerates it) and mark that file for cold-launch auto-load. No-op unless a live game
// is being recorded: at the title there is nothing to flush and Swift won't even request it; in
// playback flushBufferToFile() is itself a no-op. The Swift host clears the marker on a surviving
// foreground, so the snapshot only resumes us after an actual OS kill.
static void seTakeBackgroundSnapshotIfRequested(void) {
    // iOS port (Brogue SE): game-handoff flush — same poll point, flushes the live recording and signals
    // the waiting source so it can stream the exact-state bytes. See docs/design/game-handoff.md.
    if (gSEHandoffFlushRequested) {
        gSEHandoffFlushRequested = false;
        if (!rogue.playbackMode && currentFilePath[0] != '\0') {
            flushBufferToFile();
        }
        if (gSEHandoffFlushDone) dispatch_semaphore_signal(gSEHandoffFlushDone);
    }
    if (!gSEBackgroundSaveRequested) {
        return;
    }
    gSEBackgroundSaveRequested = false;
    if (rogue.playbackMode || currentFilePath[0] == '\0') {
        return;
    }
    flushBufferToFile();
    [[NSUserDefaults standardUserDefaults] setObject:[NSString stringWithUTF8String:currentFilePath]
                                              forKey:kSEResumePathKey];
}

// iOS port (Brogue SE): host hook (UI thread) — request a snapshot on app background.
extern "C" __attribute__((visibility("default"))) void se_requestBackgroundSave(void) {
    gSEBackgroundSaveRequested = true;
}

// iOS port (Brogue SE): host hook (called OFF the main thread by the handoff source). Asks the engine
// thread to flush the live recording, waits (bounded) for it, then reads and returns the exact-state
// save bytes to stream to the receiving device. nil if there's no live game or the flush times out.
extern "C" __attribute__((visibility("default"))) NSData * _Nullable se_flushRecordingForHandoff(void) {
    gSEHandoffFlushDone = dispatch_semaphore_create(0);
    gSEHandoffFlushRequested = true;
    long timedOut = dispatch_semaphore_wait(gSEHandoffFlushDone,
                                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    gSEHandoffFlushDone = nil;
    if (timedOut || currentFilePath[0] == '\0') return nil;
    return [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:currentFilePath]];
}

// iOS port (Brogue SE): host hook (UI thread) — drop a stale resume marker when the app survived
// a background and is returning to a live in-memory game. Also cancels any still-pending request
// so a late-waking engine thread can't re-mark after we've cleared.
extern "C" __attribute__((visibility("default"))) void se_clearResumeMarker(void) {
    gSEBackgroundSaveRequested = false;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSEResumePathKey];
}

// iOS port (iBrogue): drive the engine's runtime KEYBOARD_LABELS flag (see Rogue.h /
// GlobalsBase.c). The host calls this on GCKeyboard connect/disconnect so in-game hotkey
// labels appear only with a hardware keyboard, matching the Classic engine.
extern "C" __attribute__((visibility("default"))) void se_setKeyboardLabelsEnabled(int enabled) {
    KEYBOARD_LABELS = (enabled != 0);
}

// iOS port (Brogue SE): report hardware-keyboard presence to the engine (distinct from KEYBOARD_LABELS).
// The host calls this on GCKeyboard connect/disconnect; the engine uses it to show the "Press <?> for
// help" welcome hint when a keyboard is attached.
extern "C" __attribute__((visibility("default"))) void se_setHardwareKeyboardConnected(int connected) {
    HARDWARE_KEYBOARD_CONNECTED = (connected != 0);
}

// ---------------------------------------------------------------------------
// Platform contract.  Signatures must match Rogue.h exactly. Color order for
// plotChar follows CE's declaration: back* first, fore* second.
// ---------------------------------------------------------------------------
extern "C" {

// NOTE: despite the parameter names in Rogue.h's declaration (which are
// legacy/misleading), CE's commitDraws() — the authoritative caller — passes
// the FOREGROUND color triple first (positions 4-6) and the BACKGROUND triple
// second (positions 7-9). Match that here, exactly like the Classic bridge.
void plotChar(enum displayGlyph inputChar,
              short xLoc, short yLoc,
              short foreRed, short foreGreen, short foreBlue,
              short backRed, short backGreen, short backBlue) {
    if (!gHost) return;

    // Tile path (CE only): in TILES mode every non-trivial glyph becomes a tile;
    // in HYBRID mode only environment glyphs do. Tile glyphs are encoded into a
    // private codepoint range (0x4000+) that the shared RogueScene renders from
    // the BrogueCE font. Mirrors the upstream iBrogueCE plotChar encoding.
    // Otherwise fall back to the text-mode Unicode translation. Classic never
    // reaches this file, so it can never emit a tile code.
    uint32_t code;
    if ((inputChar > G_DOWN_ARROW) &&
        ((graphicsMode == TILES_GRAPHICS) ||
         ((graphicsMode == HYBRID_GRAPHICS) && ce_isEnvironmentGlyph(inputChar)))) {
        code = (uint32_t)((inputChar - 130) + 0x4000);
    } else {
        code = (uint32_t)ce_glyphToUnicode(inputChar);
    }
    [gHost setCellAtX:xLoc y:yLoc code:code
                bgRed:backRed bgGreen:backGreen bgBlue:backBlue
                fgRed:foreRed fgGreen:foreGreen fgBlue:foreBlue];
}

boolean pauseForMilliseconds(short milliseconds, PauseBehavior behavior) {
    // First frame after (re)entry: pauseBrogue has just run commitDraws (which
    // skips cells matching the stale cache), so force a full redraw to resync the
    // shared RogueScene to CE's actual content.
    if (gNeedsFullRedraw) {
        gNeedsFullRedraw = false;
        refreshScreen();
    }
    reportUIModeIfChanged();
    reportAtTitleIfChanged();

    [NSThread sleepForTimeInterval:milliseconds / 1000.];

    // iOS port (Brogue SE): keep the cosmetic layer (status blinks, dash trails) animating through engine-driven
    // automation -- rest / travel / auto-explore -- where the idle pump (nextKeyOrMouseEvent's colorsDance tick)
    // never runs, so the blink clock would otherwise freeze and the tells would vanish/reset. Throttled to ~60Hz
    // of real time so a fast rest loop (sub-ms turns) doesn't strobe the blink. Skipped during fast replay.
    if ((rogue.automationActive || rogue.autoPlayingLevel)
        && !(rogue.playbackMode && rogue.playbackFastForward)) {

        static NSTimeInterval lastCosmeticPump = 0;
        const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now - lastCosmeticPump >= 1.0 / 60.0) {
            lastCosmeticPump = now;
            advanceCosmeticAnimations();
            commitDraws();
        }
    }

    seTakeBackgroundSnapshotIfRequested(); // iOS port (Brogue SE): snapshot mid-animation (e.g. resting)
    if (brogueSETerminationRequested) {
        return true; // wake the title loop so it can observe the request
    }
    if (gHost && ([gHost hasTouchEvent] || [gHost hasKeyEvent])) {
        return true;
    }
    return false;
}

boolean isApplicationActive(void) {
    return true;
}

void nextKeyOrMouseEvent(rogueEvent *returnEvent, boolean textInput, boolean colorsDance) {
    for (;;) {
        // 60Hz poll, mirroring the Classic bridge.
        [NSThread sleepForTimeInterval:0.016667];

        reportUIModeIfChanged();
        reportAtTitleIfChanged();
        seTakeBackgroundSnapshotIfRequested(); // iOS port (Brogue SE): snapshot between turns

        // Engine-switch requested: unblock with a benign keystroke so the title
        // loop iterates and its termination hook returns NG_QUIT.
        if (brogueSETerminationRequested) {
            returnEvent->eventType = KEYSTROKE;
            returnEvent->param1 = 0;
            returnEvent->param2 = 0;
            returnEvent->controlKey = 0;
            returnEvent->shiftKey = 0;
            return;
        }

        if (colorsDance) {
            shuffleTerrainColors(3, true);
            advanceCosmeticAnimations(); // iOS port (Brogue SE): tick the cosmetic animation layer on the
                                         // same idle clock as the terrain shimmer; commitDraws() pushes both.
            commitDraws();
        }

        if (!gHost) {
            continue;
        }

        if ([gHost hasKeyEvent]) {
            BOOL shift = NO, control = NO, raw = NO;
            int32_t key = [gHost dequeueKeyEventWithShift:&shift control:&control raw:&raw];
            // The shared iOS input layer is built around Classic's RETURN_KEY,
            // which is carriage-return ('\r', 13). CE's RETURN_KEY is line-feed
            // ('\n', 10), so a Classic-style Return never matches CE's text-entry
            // loop or Enter-to-confirm prompts. Translate it here, keeping the
            // host engine-agnostic and letting the bridge adapt to CE's convention.
            if (key == '\r') {
                key = RETURN_KEY;
            }
            returnEvent->eventType = KEYSTROKE;
            returnEvent->param2 = 0;
            returnEvent->controlKey = control ? 1 : 0;
            returnEvent->shiftKey = shift ? 1 : 0;
            // iOS port (iBrogue): remap raw hardware character keys through the active keyboard scheme
            // (skipped during text entry, where keys are literal). Synthesized on-screen keys (raw==NO)
            // are already canonical and pass through untouched. See docs/design/keyboard-schemes.md.
            if (raw && !textInput) {
                returnEvent->param1 = applyKeyboardScheme(key, &returnEvent->controlKey, &returnEvent->shiftKey);
            } else {
                returnEvent->param1 = key;
            }
            return;
        }

        if ([gHost hasTouchEvent]) {
            CGPoint location = CGPointMake(0, 0);
            NSInteger phase = -1;
            if (![gHost dequeueTouchEvent:&location phase:&phase]) {
                continue;
            }
            if (phase == UITouchPhaseCancelled) {
                continue;
            }

            switch ((UITouchPhase)phase) {
                case UITouchPhaseBegan:
                case UITouchPhaseStationary:
                    returnEvent->eventType = MOUSE_DOWN;
                    break;
                case UITouchPhaseEnded:
                    returnEvent->eventType = MOUSE_UP;
                    break;
                case UITouchPhaseMoved:
                    returnEvent->eventType = MOUSE_ENTERED_CELL;
                    break;
                default:
                    continue;
            }

            CGFloat width = [gHost effectiveWidthPoints];
            CGFloat height = [gHost effectiveHeightPoints];
            CGFloat leftInset = [gHost leftInsetPoints];
            // Invert pinch-zoom (iPhone) so the engine sees the cell under the
            // finger; identity at 1× / outside the map. Same inverse the Swift
            // getCellCoords and the Classic bridge use.
            CGPoint loc = [gHost unzoomedPoint:location];
            CGFloat xInPlay = MAX((CGFloat)loc.x - leftInset, (CGFloat)0.0);

            returnEvent->param1 = (long)(COLS * xInPlay / width);
            returnEvent->param2 = (long)(ROWS * (CGFloat)loc.y / height);
            returnEvent->controlKey = 0;
            returnEvent->shiftKey = 0;
            return;
        }
    }
}

// iOS port (Brogue SE): Brogue SE is Game Center-silent.
//
// Unlike Classic (which reports from RogueMain.mm) and BrogueCE (which routes scores/
// feats through the BrogueCEHost protocol), SE deliberately posts NOTHING to Game
// Center: no leaderboard score, no achievements. SE's gameplay balance is under active
// change, so an online leaderboard mixing incomparable rulesets would be meaningless,
// and SE must never land on (or corrupt) BrogueCE's "BrogueCE_High_Score" board or its
// shared achievement IDs. Local high scores / run history ARE still recorded — see the
// "se high scores …" / "se run history" NSUserDefaults keys above.
//
// A dedicated SE leaderboard can be introduced later if/when SE stabilizes.
static void ceReportGameOver(long score, boolean isVictory) {
    (void)score; (void)isVictory;   // intentionally no Game Center reporting for SE
}

void notifyEvent(short eventId, int data1, int data2, const char *str1, const char *str2) {
    switch (eventId) {
        case GAMEOVER_DEATH:        ceReportGameOver((long)data1, false); break;
        case GAMEOVER_VICTORY:
        case GAMEOVER_SUPERVICTORY: ceReportGameOver((long)data1, true);  break;
        // GAMEOVER_QUIT (quit/abandon) and GAMEOVER_RECORDING (playback) report nothing.
        default: break;
    }
}

// iOS port (Brogue SE): shared CSV appender for the debug calibration logs. Appends one timestamped row to
// Documents/se/<fileName>, writing the header — prefixed with our own wall-clock "time" column — only when
// the file is first created. Pull the file off-device via Xcode > Window > Devices & Simulators > (app) >
// Download Container, then look under AppData/Documents/se/<fileName>. Output-only. Gated to Debug builds
// (SE_DEBUG_BUILD): in Release this is a no-op, so nothing is written on shipping devices.
static void seAppendCsvRow(NSString *fileName, const char *header, const char *row) {
#if SE_DEBUG_BUILD
    if (!header || !row) {
        return;
    }
    @autoreleasepool {
        NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *seDir = [documents stringByAppendingPathComponent:@"se"];
        NSString *csvPath = [seDir stringByAppendingPathComponent:fileName];
        NSFileManager *manager = [NSFileManager defaultManager];

        if (![manager fileExistsAtPath:seDir]) {
            [manager createDirectoryAtPath:seDir withIntermediateDirectories:YES attributes:nil error:NULL];
        }

        if (![manager fileExistsAtPath:csvPath]) {
            NSString *headerLine = [NSString stringWithFormat:@"time,%s\n", header];
            [headerLine writeToFile:csvPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }

        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSString *stamp = [fmt stringFromDate:[NSDate date]];

        NSString *dataLine = [NSString stringWithFormat:@"%@,%s\n", stamp, row];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:csvPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[dataLine dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
#else
    (void)fileName;
    (void)header;
    (void)row; // Release: these CSVs are debug-only calibration tools; never collect on shipping builds
#endif
}

// iOS port (Brogue SE): debug rest-insight calibration. The engine (recordRestStatsRow in RogueMain.c)
// emits one CSV row per finished live run → Documents/se/rest-stats.csv.
void seRecordRestStats(const char *header, const char *row) {
    seAppendCsvRow(@"rest-stats.csv", header, row);
}

// iOS port (Brogue SE): debug exploration / Lone-Wolf calibration. The engine (recordExplorationStatsRow in
// RogueMain.c) emits one CSV row per finished live run → Documents/se/exploration-stats.csv: per-level
// passable-cell ceiling and xpxp actually accrued, for tuning LONE_WOLF_XP_PER_TIER against real levels.
void seRecordExplorationStats(const char *header, const char *row) {
    seAppendCsvRow(@"exploration-stats.csv", header, row);
}

boolean takeScreenshot(void) {
    return false;
}

// iOS port (iBrogue): the chosen graphics mode (text / tiles / hybrid) is
// persisted in NSUserDefaults so it carries across app launches and future runs,
// rather than resetting to TEXT_GRAPHICS each launch. Stored as the raw enum
// integer under a CE-specific key.
static NSString * const kCEGraphicsModeKey = @"se graphics mode";

// Read the persisted graphics mode, clamped to the valid enum range. Defaults to
// TEXT_GRAPHICS when absent or out of range (matching the engine's own default).
static enum graphicsModes ceLoadPersistedGraphicsMode(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kCEGraphicsModeKey] == nil) {
        return TEXT_GRAPHICS;
    }
    NSInteger stored = [d integerForKey:kCEGraphicsModeKey];
    if (stored < TEXT_GRAPHICS || stored > HYBRID_GRAPHICS) {
        return TEXT_GRAPHICS;
    }
    return (enum graphicsModes)stored;
}

// Called by the engine's "Enable graphics" menu action (IO.c GRAPHICS_KEY),
// which cycles TEXT -> TILES -> HYBRID. We track the requested mode in the
// graphicsMode global and echo it back; plotChar reads it to decide whether to
// emit tile codes. A full redraw is forced so the switch takes effect at once.
// The choice is persisted so it sticks for future runs (iOS port).
enum graphicsModes setGraphicsMode(enum graphicsModes mode) {
    graphicsMode = mode;
    gNeedsFullRedraw = true;
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)mode forKey:kCEGraphicsModeKey];
    return graphicsMode;
}

// iOS port (iBrogue): the seed of the most recent run (previousGameSeed) is
// persisted in NSUserDefaults so the title screen's "New Seeded Game" prompt can
// pre-fill the last-played seed even after the app is killed. Desktop keeps this
// only in memory for the lifetime of the process; on iOS backgrounded apps are
// frequently terminated, which would otherwise reset it to 0 each launch. Stored
// as an NSNumber so the full uint64_t seed range round-trips losslessly.
static NSString * const kCELastSeedKey = @"se last game seed";

uint64_t ceLoadPersistedSeed(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kCELastSeedKey];
    return n ? (uint64_t)[n unsignedLongLongValue] : 0;
}

void cePersistLastSeed(uint64_t seed) {
    [[NSUserDefaults standardUserDefaults] setObject:@((unsigned long long)seed) forKey:kCELastSeedKey];
}

// iOS port (iBrogue): the chosen keyboard scheme (Classic / Modern) is persisted in NSUserDefaults so
// it sticks across launches, defaulting to CLASSIC (stock vi keys) when absent or out of range. The key
// is deliberately shared across all three engines (Classic/CE/SE all use @"keyboard scheme") so the
// scheme is an app-wide input preference -- picking Modern in one engine carries to the others. (This is
// an intentional exception to SE's "se ..."-prefixed state: it is an input preference, not game state.)
static NSString * const kCEKeyboardSchemeKey = @"keyboard scheme";

static enum keyboardScheme ceLoadPersistedKeyboardScheme(void) {
    // iOS port (Brogue SE): default MODERN when absent or out of range (the default layout on iOS/macOS).
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kCEKeyboardSchemeKey] == nil) {
        return KEYBOARD_SCHEME_MODERN;
    }
    NSInteger stored = [d integerForKey:kCEKeyboardSchemeKey];
    if (stored < KEYBOARD_SCHEME_CLASSIC || stored >= KEYBOARD_SCHEME_COUNT) {
        return KEYBOARD_SCHEME_MODERN;
    }
    return (enum keyboardScheme)stored;
}

void cePersistKeyboardScheme(int scheme) {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)scheme forKey:kCEKeyboardSchemeKey];
}

boolean controlKeyIsDown(void) {
    return gHost ? [gHost controlKeyIsDown] : false;
}

boolean shiftKeyIsDown(void) {
    return false;
}

// iOS port (iBrogue): CE's getInputTextString calls this before its input loop so
// the on-screen keyboard is pre-filled with the engine's default seed/name —
// otherwise the field is empty and iOS suppresses the backspace callback for the
// pre-filled text, so it can't be deleted. `numeric` requests a number pad (with
// a Done bar) for seed entry.
void ceRequestTextInput(const char *defaultText, boolean numeric) {
    NSString *s = defaultText ? [NSString stringWithUTF8String:defaultText] : @"";
    if (gHost) [gHost requestTextInput:s numeric:(BOOL)numeric];
}

// iOS port (iBrogue): the CE title menu's "File Management" entry routes here.
void ceShowFileManagement(void) {
    [gHost presentFileManagement];
}

// iOS port (iBrogue): the CE title menu's View > "Game Center" entry routes here;
// presents the BrogueCE_High_Score leaderboard.
void ceShowGameCenter(void) {
    [gHost presentGameCenter];
}

// iOS port (iBrogue): Combat.c calls this when the player takes damage.
void cePlayerTookDamage(int severity) {
    if (gHost) [gHost playDamageHaptic:severity];
}

// iOS port (Brogue SE): Monsters.c (noise system) calls this when an unseen creature
// reacts to the player's noise. stage 0 = began investigating (one tap), 1 = now hunting (two taps).
void cePlayDetectionHaptic(int stage) {
    if (gHost) [gHost playDetectionHaptic:stage];
}

// iOS port (Brogue SE): Time.c (trap click) and Architect.c (altar grind, via DFF_EMITS_NOISE)
// call this when a noisy world event happens near the player. kind 0 = gentle trap click, 1 = pronounced altar grind.
void cePlayEnvironmentalNoiseHaptic(int kind) {
    if (gHost) [gHost playEnvironmentalNoiseHaptic:kind];
}

// iOS port (iBrogue): Items.c calls this around the throw/zap aiming loop.
void ceSetTargeting(boolean isTargeting) {
    if (gHost) [gHost setTargeting:(BOOL)isTargeting];
}

// iOS port (iBrogue): IO.c's mainInputLoop calls this each cursor frame with
// whether a creature/item description box is showing. Deduped (the loop polls at
// frame rate) so we only forward state changes to the host.
void ceSetExamining(boolean examining) {
    static boolean last = false;
    if ((boolean)examining == last) return;
    last = examining;
    if (gHost) [gHost setExamining:(BOOL)examining];
}

// iOS port (Brogue SE): forwards the examine description box's window rect so the iPhone
// host can zoom to fit it rather than all the way to 1×. Emitted only when a box is shown.
void ceSetExamineBox(short x, short y, short width, short height) {
    if (gHost) [gHost setExamineBox:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height];
}

// iOS port (Brogue SE): the examine loop asks this before drawing a description box; YES means
// skip it (zoomed-in play-field examine, where the box would tear against the 1× sidebar).
boolean ceShouldSuppressExamineBox(void) {
    return gHost ? (boolean)[gHost shouldSuppressExamineBox] : false;
}

// iOS port (iBrogue): commitDraws() reports the player's WINDOW cell here every
// refresh so the iPhone pinch-zoom can auto-follow. Deduped against the last
// reported cell so the (frequent) commitDraws calls don't spam the host.
void ceSetPlayerWindowLocation(short windowX, short windowY) {
    static short lastX = -1, lastY = -1;
    if (windowX == lastX && windowY == lastY) return;
    lastX = windowX;
    lastY = windowY;
    if (gHost) [gHost setPlayerWindowX:windowX y:windowY];
}

// iOS port (iBrogue): commitDraws() reports here whether a travel destination is pending
// (rogue.cursorLoc is a real cell). Deduped so the frequent commitDraws calls only forward
// state changes; the host uses it to swap the reactive center d-pad button between "continue
// journey" and "rest".
void ceSetTravelPending(boolean pending) {
    static boolean last = false;
    if ((boolean)pending == last) return;
    last = pending;
    if (gHost) [gHost setTravelPending:(BOOL)pending];
}

// iOS port (iBrogue): commitDraws() reports the live game's context here (current depth, input turn,
// master seed) so the host can keep the cross-device Continuity Handoff activity current. Deduped on
// depth — the frequent commitDraws calls forward only when the player changes level; per-turn churn is
// unnecessary since the recording bytes are streamed live at pickup. gLastHandoffDepth is reset when
// the title reappears (reportAtTitleIfChanged). See docs/design/game-handoff.md.
void ceSetGameContext(short depth, unsigned long turn, uint64_t seed) {
    if (depth == gLastHandoffDepth) return;
    gLastHandoffDepth = depth;
    if (gHost) [gHost setGameDepth:(NSInteger)depth turn:(long)turn seed:seed];
}

// iOS port (iBrogue): high scores are persisted in NSUserDefaults as three
// parallel arrays. Kept under CE-specific keys, separate from the Classic
// engine's list, since the two engines score independently. CE's
// rogueHighScoresEntry has no seed field, so (unlike Classic) we store none.
static NSString * const kCEHighScoresScoresKey = @"se high scores scores";
static NSString * const kCEHighScoresTextKey   = @"se high scores text";
static NSString * const kCEHighScoresDatesKey  = @"se high scores dates";

// Ensure all three arrays exist and hold exactly HIGH_SCORES_COUNT entries,
// padding empty slots (score 0). Safe to call before every read/write.
static void ceInitHighScores(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *scores = [([d arrayForKey:kCEHighScoresScoresKey] ?: @[]) mutableCopy];
    NSMutableArray *text   = [([d arrayForKey:kCEHighScoresTextKey]   ?: @[]) mutableCopy];
    NSMutableArray *dates  = [([d arrayForKey:kCEHighScoresDatesKey]  ?: @[]) mutableCopy];

    while ((short)[scores count] < HIGH_SCORES_COUNT) [scores addObject:@(0L)];
    while ((short)[text count]   < HIGH_SCORES_COUNT) [text addObject:@""];
    while ((short)[dates count]  < HIGH_SCORES_COUNT) [dates addObject:[NSDate date]];

    [d setObject:scores forKey:kCEHighScoresScoresKey];
    [d setObject:text   forKey:kCEHighScoresTextKey];
    [d setObject:dates  forKey:kCEHighScoresDatesKey];
}

// Fills returnList sorted by score (descending) and returns the index (within
// the sorted list) of the most recently dated entry, so printHighScores can
// highlight it. Mirrors the Classic port's algorithm.
short getHighScoresList(rogueHighScoresEntry returnList[HIGH_SCORES_COUNT]) {
    ceInitHighScores();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *scores = [d arrayForKey:kCEHighScoresScoresKey];
    NSArray *text   = [d arrayForKey:kCEHighScoresTextKey];
    NSArray *dates  = [d arrayForKey:kCEHighScoresDatesKey];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"MM/dd/yy"];

    boolean taken[HIGH_SCORES_COUNT];
    for (short i = 0; i < HIGH_SCORES_COUNT; i++) taken[i] = false;

    NSDate *mostRecentDate = [NSDate distantPast];
    short mostRecentIndex = 0;

    for (short i = 0; i < HIGH_SCORES_COUNT; i++) {
        // Pick the highest score not yet placed (>= so empty 0-slots fill too).
        long maxScore = -1;
        short maxIndex = 0;
        for (short j = 0; j < HIGH_SCORES_COUNT; j++) {
            if (!taken[j] && [[scores objectAtIndex:j] longValue] >= maxScore) {
                maxScore = [[scores objectAtIndex:j] longValue];
                maxIndex = j;
            }
        }
        taken[maxIndex] = true;

        returnList[i].score = [[scores objectAtIndex:maxIndex] longValue];
        const char *desc = [[text objectAtIndex:maxIndex] UTF8String];
        const char *date = [[fmt stringFromDate:[dates objectAtIndex:maxIndex]] UTF8String];
        strncpy(returnList[i].description, desc ? desc : "", sizeof(returnList[i].description) - 1);
        returnList[i].description[sizeof(returnList[i].description) - 1] = '\0';
        strncpy(returnList[i].date, date ? date : "", sizeof(returnList[i].date) - 1);
        returnList[i].date[sizeof(returnList[i].date) - 1] = '\0';

        if ([mostRecentDate compare:[dates objectAtIndex:maxIndex]] == NSOrderedAscending) {
            mostRecentDate = [dates objectAtIndex:maxIndex];
            mostRecentIndex = i;
        }
    }
    return mostRecentIndex;
}

// Replaces the lowest entry if theEntry beats it; returns whether it qualified.
// The passed-in date is ignored in favor of the current date, as upstream does.
boolean saveHighScore(rogueHighScoresEntry theEntry) {
    ceInitHighScores();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *scores = [[d arrayForKey:kCEHighScoresScoresKey] mutableCopy];
    NSMutableArray *text   = [[d arrayForKey:kCEHighScoresTextKey]   mutableCopy];
    NSMutableArray *dates  = [[d arrayForKey:kCEHighScoresDatesKey]  mutableCopy];

    short minIndex = -1;
    long minScore = theEntry.score;
    for (short j = 0; j < HIGH_SCORES_COUNT; j++) {
        if ([[scores objectAtIndex:j] longValue] < minScore) {
            minScore = [[scores objectAtIndex:j] longValue];
            minIndex = j;
        }
    }

    if (minIndex == -1) {
        return false; // didn't beat any existing entry
    }

    [scores replaceObjectAtIndex:minIndex withObject:@((long)theEntry.score)];
    [text   replaceObjectAtIndex:minIndex withObject:([NSString stringWithUTF8String:theEntry.description] ?: @"")];
    [dates  replaceObjectAtIndex:minIndex withObject:[NSDate date]];

    [d setObject:scores forKey:kCEHighScoresScoresKey];
    [d setObject:text   forKey:kCEHighScoresTextKey];
    [d setObject:dates  forKey:kCEHighScoresDatesKey];
    [d synchronize];
    return true;
}

// iOS port (iBrogue): CE's lifetime "game stats" screen is built from a run
// history — one rogueRun per finished game, kept in chronological order (the
// streak math in MainMenu.c depends on that order), with a seed==0 entry acting
// as a "player reset their recent stats here" sentinel. Persisted as an array of
// dictionaries in NSUserDefaults under a CE-specific key. `rogue` (the engine's
// global game state) supplies the fields saveRunHistory isn't handed directly.
static NSString * const kCERunHistoryKey = @"se run history";
extern playerCharacter rogue;

static void ceAppendRun(NSDictionary *run) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *runs = [([d arrayForKey:kCERunHistoryKey] ?: @[]) mutableCopy];
    [runs addObject:run];
    [d setObject:runs forKey:kCERunHistoryKey];
    [d synchronize];
}

void saveRunHistory(char *result, char *killedBy, int score, int lumenstones) {
    ceAppendRun(@{
        @"seed":         @((unsigned long long)rogue.seed),
        @"dateNumber":   @((long)[[NSDate date] timeIntervalSince1970]),
        @"result":       (result   ? [NSString stringWithUTF8String:result]   : @"") ?: @"",
        @"killedBy":     (killedBy ? [NSString stringWithUTF8String:killedBy] : @"") ?: @"",
        @"gold":         @((int)rogue.gold),
        @"lumenstones":  @(lumenstones),
        @"score":        @(score),
        @"turns":        @((int)rogue.playerTurnNumber),
        @"deepestLevel": @((int)rogue.deepestLevel),
    });
}

void saveResetRun(void) {
    // A seed==0 entry marks where the player reset their "recent" stats; the
    // other fields are unused for sentinels.
    ceAppendRun(@{
        @"seed":         @(0ULL),
        @"dateNumber":   @((long)[[NSDate date] timeIntervalSince1970]),
        @"result":       @"",
        @"killedBy":     @"",
        @"gold":         @(0),
        @"lumenstones":  @(0),
        @"score":        @(0),
        @"turns":        @(0),
        @"deepestLevel": @(0),
    });
}

// Returns a malloc'd, chronologically-ordered linked list; the caller frees each
// node (result/killedBy are inline arrays, so a plain free() per node suffices).
rogueRun *loadRunHistory(void) {
    NSArray *runs = [[NSUserDefaults standardUserDefaults] arrayForKey:kCERunHistoryKey];
    rogueRun *head = NULL, *tail = NULL;

    for (id obj in runs) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = (NSDictionary *)obj;

        rogueRun *node = (rogueRun *)calloc(1, sizeof(rogueRun));
        if (!node) break;

        node->seed         = (uint64_t)[dict[@"seed"] unsignedLongLongValue];
        node->dateNumber   = (long)[dict[@"dateNumber"] longValue];
        node->gold         = [dict[@"gold"] intValue];
        node->lumenstones  = [dict[@"lumenstones"] intValue];
        node->score        = [dict[@"score"] intValue];
        node->turns        = [dict[@"turns"] intValue];
        node->deepestLevel = [dict[@"deepestLevel"] intValue];
        node->nextRun      = NULL;

        NSString *result   = [dict[@"result"]   isKindOfClass:[NSString class]] ? dict[@"result"]   : @"";
        NSString *killedBy = [dict[@"killedBy"] isKindOfClass:[NSString class]] ? dict[@"killedBy"] : @"";
        const char *resultC   = [result UTF8String];
        const char *killedByC = [killedBy UTF8String];
        strncpy(node->result,   resultC   ? resultC   : "", sizeof(node->result) - 1);
        node->result[sizeof(node->result) - 1] = '\0';
        strncpy(node->killedBy, killedByC ? killedByC : "", sizeof(node->killedBy) - 1);
        node->killedBy[sizeof(node->killedBy) - 1] = '\0';

        if (tail) {
            tail->nextRun = node;
            tail = node;
        } else {
            head = tail = node;
        }
    }
    return head;
}

// Enumerates the files in the engine's working directory (Documents/ce, set by
// initializeBrogueCESaveLocation) so the title menu's Load Game / View Recording
// pickers have something to filter. dialogChooseFile keeps only the entries whose
// name ends in the requested suffix, then frees the returned list and *membuf.
//
// The path strings are packed into a single dynamically grown buffer returned via
// dynamicMemoryBuffer; fileEntry.path entries point into it. fileEntry.date is a
// struct tm (CE differs from Classic's date string) consumed by strftime and
// mktime in MainMenu.c, so we fill it from each file's modification time.
fileEntry *listFiles(short *fileCount, char **dynamicMemoryBuffer) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray<NSString *> *names =
        [manager contentsOfDirectoryAtPath:[manager currentDirectoryPath] error:&err];

    short count = (short)[names count];
    fileEntry *fileList = (fileEntry *)malloc(sizeof(fileEntry) * (count > 0 ? count : 1));
    unsigned long *offsets = (unsigned long *)malloc(sizeof(unsigned long) * (count > 0 ? count : 1));

    char *buffer = NULL;
    unsigned long bufferPosition = 0, bufferSize = 0;

    for (short i = 0; i < count; i++) {
        NSString *name = names[i];
        const char *cName = [name cStringUsingEncoding:NSUTF8StringEncoding];
        if (!cName) {
            cName = "";
        }
        unsigned long nameLength = strlen(cName);

        if (bufferPosition + nameLength + 1 > bufferSize) {
            bufferSize += 1024;
            buffer = (char *)realloc(buffer, bufferSize);
        }
        offsets[i] = bufferPosition;
        strcpy(&buffer[bufferPosition], cName);
        bufferPosition += nameLength + 1;

        // Modification date -> struct tm for MainMenu's strftime/mktime.
        memset(&fileList[i].date, 0, sizeof(fileList[i].date));
        NSDictionary *attrs = [manager attributesOfItemAtPath:name error:nil];
        NSDate *modDate = [attrs fileModificationDate];
        if (modDate) {
            time_t t = (time_t)[modDate timeIntervalSince1970];
            localtime_r(&t, &fileList[i].date);
        }
    }

    // realloc may have moved the buffer, so resolve offsets to pointers last.
    for (short i = 0; i < count; i++) {
        fileList[i].path = &buffer[offsets[i]];
    }

    free(offsets);

    *fileCount = count;
    *dynamicMemoryBuffer = buffer;
    return fileList;
}

void initializeLaunchArguments(enum NGCommands *command, char *path, uint64_t *seed) {
    if (command) *command = NG_NOTHING;
    // iOS port (Brogue SE): cold-launch auto-resume. A one-shot marker set on the last background
    // points at the snapshot; load it straight into the game (no title screen) and consume the
    // marker. If the file is gone (e.g. the run ended after the marker was set), openFile() in
    // mainBrogueJunction returns false and the engine falls through to the title — so no pre-check.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *resumePath = [d stringForKey:kSEResumePathKey];
    if (resumePath.length && command && path) {
        [d removeObjectForKey:kSEResumePathKey];
        *command = NG_OPEN_GAME;
        strncpy(path, resumePath.UTF8String, BROGUE_FILENAME_MAX - 1);
        path[BROGUE_FILENAME_MAX - 1] = '\0';
    }
}

// NOTE: fileExists / chooseFile / openFile are defined by the CE engine itself
// (in RogueMain.c / Recordings.c) in this fork, unlike Classic where they lived
// in the bridge. Do not redefine them here or the framework link sees duplicates.

// CE defines this in platform/main.c upstream (used to parse a seed argument).
boolean tryParseUint64(char *str, uint64_t *num) {
    if (!str || !num) {
        return false;
    }
    char *end = NULL;
    unsigned long long value = strtoull(str, &end, 10);
    if (end == str || (end && *end != '\0')) {
        return false;
    }
    *num = (uint64_t)value;
    return true;
}

} // extern "C"
