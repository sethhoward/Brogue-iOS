//
//  CEBridge.mm
//  BrogueCE
//
//  Objective-C++ bridge between the BrogueCE 1.15 C engine (vendored in
//  Engine/) and the host iOS app. The engine declares its platform contract as
//  free C functions in Rogue.h (no brogueConsole struct in this fork), so this
//  file provides definitions for every platform symbol the engine references,
//  plus the single exported entry point ce_start().
//
//  Rendering / input / signaling are routed to an app-supplied object that
//  conforms to BrogueCEHost (see BrogueCEHost.h).
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdlib.h>

#import "Engine/Rogue.h"
#import "BrogueCEHost.h"

// ---------------------------------------------------------------------------
// Unicode code points for the non-ASCII glyphs. Upstream CE defines these in
// platform/platform.h (which we don't vendor, as it's the SDL/curses platform
// header). Mirrored here for the text-mode glyph translation below.
// ---------------------------------------------------------------------------
#define U_MIDDLE_DOT          0x00b7
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

// Set by ce_requestTermination() (UI thread), read by the engine thread. When
// true, the bridge unblocks the title-screen input wait and the engine's
// titleMenu hook returns with rogue.nextGame = NG_QUIT, so rogueMain() exits.
// Defined with C linkage so the vendored engine (MainMenu.c) can extern it.
extern "C" { volatile boolean brogueCETerminationRequested = false; }

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

static void reportAtTitleIfChanged(void) {
    if (gHost) {
        int v = brogueCEAtTitle ? 1 : 0;
        if (v != gLastReportedAtTitle) {
            gLastReportedAtTitle = v;
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
// (recordings, saves). BrogueCE files are partitioned into Documents/ce so they
// never collide with the Classic engine's files in Documents/. Mirrors Classic's
// initializeBrogueSaveLocation(), but scoped to the CE subdirectory.
static void initializeBrogueCESaveLocation(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *ceDir = [documents stringByAppendingPathComponent:@"ce"];

    if (![manager fileExistsAtPath:ceDir]) {
        [manager createDirectoryAtPath:ceDir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    // Relative paths the engine opens (e.g. the recording file) now resolve here.
    [manager changeCurrentDirectoryPath:ceDir];
}

extern "C" __attribute__((visibility("default"))) void ce_start(id<BrogueCEHost> host) {
    gHost = host;
    brogueCETerminationRequested = false;
    brogueCEAtTitle = false;
    gNeedsFullRedraw = true; // resync the shared scene on (re)entry
    gLastReportedUIMode = -1; // force a UI-mode report on (re)entry
    gLastReportedAtTitle = -1; // force an at-title report on (re)entry
    initializeBrogueCESaveLocation();
    rogueMain();
}

extern "C" __attribute__((visibility("default"))) void ce_requestTermination(void) {
    brogueCETerminationRequested = true;
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
    if (brogueCETerminationRequested) {
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

        // Engine-switch requested: unblock with a benign keystroke so the title
        // loop iterates and its termination hook returns NG_QUIT.
        if (brogueCETerminationRequested) {
            returnEvent->eventType = KEYSTROKE;
            returnEvent->param1 = 0;
            returnEvent->param2 = 0;
            returnEvent->controlKey = 0;
            returnEvent->shiftKey = 0;
            return;
        }

        if (colorsDance) {
            shuffleTerrainColors(3, true);
            commitDraws();
        }

        if (!gHost) {
            continue;
        }

        if ([gHost hasKeyEvent]) {
            uint8_t key = [gHost dequeueKeyEvent];
            // The shared iOS input layer is built around Classic's RETURN_KEY,
            // which is carriage-return ('\r', 13). CE's RETURN_KEY is line-feed
            // ('\n', 10), so a Classic-style Return never matches CE's text-entry
            // loop or Enter-to-confirm prompts. Translate it here, keeping the
            // host engine-agnostic and letting the bridge adapt to CE's convention.
            if (key == '\r') {
                key = RETURN_KEY;
            }
            returnEvent->eventType = KEYSTROKE;
            returnEvent->param1 = key;
            returnEvent->param2 = 0;
            returnEvent->controlKey = 0;
            returnEvent->shiftKey = 0;
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

void notifyEvent(short eventId, int data1, int data2, const char *str1, const char *str2) {
}

boolean takeScreenshot(void) {
    return false;
}

// Called by the engine's "Enable graphics" menu action (IO.c GRAPHICS_KEY),
// which cycles TEXT -> TILES -> HYBRID. We track the requested mode in the
// graphicsMode global and echo it back; plotChar reads it to decide whether to
// emit tile codes. A full redraw is forced so the switch takes effect at once.
enum graphicsModes setGraphicsMode(enum graphicsModes mode) {
    graphicsMode = mode;
    gNeedsFullRedraw = true;
    return graphicsMode;
}

boolean controlKeyIsDown(void) {
    return gHost ? [gHost controlKeyIsDown] : false;
}

boolean shiftKeyIsDown(void) {
    return false;
}

// iOS port (iBrogue): the CE title menu's "File Management" entry routes here.
void ceShowFileManagement(void) {
    [gHost presentFileManagement];
}

// iOS port (iBrogue): Combat.c calls this when the player takes damage.
void cePlayerTookDamage(int severity) {
    if (gHost) [gHost playDamageHaptic:severity];
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

// iOS port (iBrogue): high scores are persisted in NSUserDefaults as three
// parallel arrays. Kept under CE-specific keys, separate from the Classic
// engine's list, since the two engines score independently. CE's
// rogueHighScoresEntry has no seed field, so (unlike Classic) we store none.
static NSString * const kCEHighScoresScoresKey = @"ce high scores scores";
static NSString * const kCEHighScoresTextKey   = @"ce high scores text";
static NSString * const kCEHighScoresDatesKey  = @"ce high scores dates";

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
static NSString * const kCERunHistoryKey = @"ce run history";
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
