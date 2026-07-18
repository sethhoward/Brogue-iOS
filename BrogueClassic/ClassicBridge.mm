//
//  ClassicBridge.mm
//  BrogueClassic
//
//  Objective-C++ bridge between the Classic (1.7.5) Brogue C engine (vendored in Engine/)
//  and the host iOS app. Extracted from the app's old RogueDriver.mm: the engine now lives
//  in its own framework, which cannot see the app's classes (BrogueViewController, SKViewPort),
//  so rendering / input / signaling route through an app-supplied object conforming to
//  BrogueClassicHost (see BrogueClassicHost.h) — exactly as BrogueCE/SE do with BrogueCEHost.
//  The single exported entry point is classic_start(); a few classic_* control entries mirror
//  the ce_* set.
//
//  Self-contained persistence (high scores, seed, keyboard scheme, file listing, resume marker)
//  moved in with the engine and keeps its exact NSUserDefaults keys and the flat Documents/ save
//  directory, so existing installs' saves and leaderboards keep working.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <limits.h>
#include <unistd.h>

#import "Engine/Rogue.h"
#import "Engine/IncludeGlobals.h"
#import "BrogueClassicHost.h"

// ---------------------------------------------------------------------------
// Host + shared state
// ---------------------------------------------------------------------------
static id<BrogueClassicHost> gHost = nil;

// In-process engine switching: when set, the bridge unblocks the title-screen input wait and the
// engine's titleMenu hook returns rogue.nextGame = NG_QUIT, so rogueMain() exits and the Classic
// engine thread can be torn down. Defined with C linkage so the engine (MainMenu.c) can extern it.
extern "C" { volatile boolean classicTerminationRequested = false; }

// iOS port (iBrogue): background suspend/resume. Set by the host (classic_requestBackgroundSave) when
// the app backgrounds; read by the engine thread, which snapshots exact state at its next poll point
// and records a one-shot resume marker so a cold launch after an OS kill resumes straight into the
// game. See docs/design/background-suspend-resume.md.
static volatile bool classicBackgroundSaveRequested = false;
static NSString *const kClassicResumePathKey = @"classic resume path";

// Engine-thread only. If a background snapshot was requested, flush the live recording so
// currentFilePath holds every input so far (exact state, even mid-animation — replay regenerates it)
// and mark that file for cold-launch auto-load. No-op unless a live game is being recorded (skips
// title — Swift won't request it there — and playback).
static void classicTakeBackgroundSnapshotIfRequested(void) {
    if (!classicBackgroundSaveRequested) {
        return;
    }
    classicBackgroundSaveRequested = false;
    if (rogue.playbackMode || currentFilePath[0] == '\0') {
        return;
    }
    flushBufferToFile();
    [[NSUserDefaults standardUserDefaults] setObject:[NSString stringWithUTF8String:currentFilePath]
                                              forKey:kClassicResumePathKey];
}

// ---------------------------------------------------------------------------
// Exported entry points (mirror the ce_* set). visibility("default") so the app links them
// unambiguously; everything else is internal to the framework image.
// ---------------------------------------------------------------------------
extern "C" __attribute__((visibility("default"))) void classic_start(id<BrogueClassicHost> host) {
    gHost = host;
    classicTerminationRequested = false;
    rogueMain(); // runs the engine on the calling thread; sets up save location / seed / scheme itself
}

extern "C" __attribute__((visibility("default"))) void classic_requestTermination(void) {
    classicTerminationRequested = true;
}

// iOS port (iBrogue): host hook (UI thread) — request a snapshot on app background.
extern "C" __attribute__((visibility("default"))) void classic_requestBackgroundSave(void) {
    classicBackgroundSaveRequested = true;
}

// iOS port (iBrogue): host hook (UI thread) — drop a stale resume marker when the app survived a
// background and is returning to a live in-memory game. Also cancels any still-pending request.
extern "C" __attribute__((visibility("default"))) void classic_clearResumeMarker(void) {
    classicBackgroundSaveRequested = false;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kClassicResumePathKey];
}

// iOS port (iBrogue): true on iPhone; drives Classic's phone-specific layout (PHONE_LAYOUT). Called
// before classic_start so the engine sees it at startup. Exposes a Classic-specific symbol (not the
// plain engine name, which CE/SE forks also export). Sets the engine global directly: the engine's
// setPhoneLayout() is declared outside Rogue.h's extern "C" guard, so a C++ call would mislink — the
// global itself is an unmangled extern that links fine, and the setter only assigns it.
extern "C" __attribute__((visibility("default"))) void classic_setPhoneLayout(int isPhone) {
    PHONE_LAYOUT = (boolean)(isPhone != 0);
}

// iOS port (iBrogue): report hardware-keyboard presence; gates Classic's KEYBOARD_LABELS hotkey hints.
// Called on GCKeyboard connect/disconnect. Sets the engine global directly, for the same linkage
// reason as classic_setPhoneLayout above.
extern "C" __attribute__((visibility("default"))) void classic_setHardwareKeyboardConnected(int connected) {
    HARDWARE_KEYBOARD_CONNECTED = (boolean)(connected != 0);
}

// iOS port (iBrogue): drive Classic's runtime KEYBOARD_LABELS flag (the in-game hotkey hints). Called on
// GCKeyboard connect/disconnect so labels show only with a keyboard. Sets the engine global directly, for
// the same linkage reason as classic_setPhoneLayout / classic_setHardwareKeyboardConnected above.
extern "C" __attribute__((visibility("default"))) void classic_setKeyboardLabelsEnabled(int enabled) {
    KEYBOARD_LABELS = (boolean)(enabled != 0);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
//  plotChar: plots inputChar at (xLoc, yLoc) with the given background and foreground colors
//  (0-100 int components). Classic's inputChar is already a rendered code point (no glyph enum /
//  tile encoding, unlike CE), so it passes straight through as the cell code. The host builds the
//  platform colors, keeping the framework free of a CoreGraphics link dependency.
void plotChar(uchar inputChar,
              short xLoc, short yLoc,
              short foreRed, short foreGreen, short foreBlue,
              short backRed, short backGreen, short backBlue) {
    if (!gHost) return;
    [gHost setCellAtX:xLoc y:yLoc code:(uint32_t)inputChar
                bgRed:backRed bgGreen:backGreen bgBlue:backBlue
                fgRed:foreRed fgGreen:foreGreen fgBlue:foreBlue];
}

// iOS port (iBrogue): Combat.c calls this when the player takes damage.
extern "C" void iosPlayerTookDamage(int severity) {
    if (gHost) [gHost playDamageHaptic:(NSInteger)severity];
}

// iOS port (iBrogue): commitDraws() reports the player's WINDOW cell here every refresh so the
// iPhone pinch-zoom can auto-follow. Deduped against the last reported cell so the (frequent)
// commitDraws calls don't spam the host.
extern "C" void iosSetPlayerWindowLocation(short windowX, short windowY) {
    static short lastX = -1, lastY = -1;
    if (windowX == lastX && windowY == lastY) return;
    lastX = windowX;
    lastY = windowY;
    if (gHost) [gHost setPlayerWindowX:windowX y:windowY];
}

// iOS port (iBrogue): refreshScreen() reports here whether a travel destination is pending
// (rogue.cursorLoc is a real cell). Deduped so the frequent refresh calls only forward state
// changes; the host uses it to swap the reactive center d-pad button between "continue journey"
// and "rest".
extern "C" void iosSetTravelPending(boolean pending) {
    static boolean last = false;
    if (pending == last) return;
    last = pending;
    if (gHost) [gHost setTravelPending:(BOOL)pending];
}

__unused void pausingTimerStartsNow() {}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------
// Returns true if the player interrupted the wait with a keystroke; otherwise false.
boolean pauseForMilliseconds(short milliseconds) {
    [NSThread sleepForTimeInterval:milliseconds/1000.];

    classicTakeBackgroundSnapshotIfRequested(); // iOS port (iBrogue): snapshot mid-animation (e.g. resting)

    if (classicTerminationRequested) {
        return true; // wake the title loop so it can observe the request
    }

    if (gHost && ([gHost hasTouchEvent] || [gHost hasKeyEvent])) {
        return true;
    }
    return false;
}

void nextKeyOrMouseEvent(rogueEvent *returnEvent, boolean textInput, boolean colorsDance) {
    for (;;) {
        // 60Hz poll.
        [NSThread sleepForTimeInterval:0.016667];

        classicTakeBackgroundSnapshotIfRequested(); // iOS port (iBrogue): snapshot between turns

        // Engine-switch requested: unblock with a benign keystroke so the title
        // loop iterates and its termination hook returns NG_QUIT.
        if (classicTerminationRequested) {
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
            // iOS port (iBrogue): the queue carries real Shift/Ctrl state and a `raw` flag.
            BOOL shift = NO, control = NO, raw = NO;
            int32_t key = [gHost dequeueKeyEventWithShift:&shift control:&control raw:&raw];
            returnEvent->eventType = KEYSTROKE;
            returnEvent->param2 = 0;
            returnEvent->controlKey = control ? 1 : 0;
            returnEvent->shiftKey = shift ? 1 : 0;
            // Remap raw hardware character keys through the active keyboard scheme (skipped during text
            // entry). Synthesized on-screen keys (raw==NO) are already canonical. See docs/design/keyboard-schemes.md.
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

            // Match the current cell layout: left/right insets reserved for the iPhone notch /
            // dynamic island. Invert pinch-zoom (iPhone) so the engine sees the cell under the
            // finger; identity at 1× / outside the map. The host stashes the touch's reach flag and
            // applies it inside unzoomedPoint (same inverse as the Swift getCellCoords and CE bridge).
            CGFloat width = [gHost effectiveWidthPoints];
            CGFloat height = [gHost effectiveHeightPoints];
            CGFloat leftInset = [gHost leftInsetPoints];
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

#pragma mark - bridge

// iOS port (iBrogue): `numeric` selects a number pad for digit-only entry (seeds); `string` is the
// engine's default, which pre-fills the field so backspace can clear it.
void requestKeyboardInput(char *string, boolean numeric) {
    if (gHost) [gHost requestTextInput:[NSString stringWithUTF8String:string] numeric:(BOOL)numeric];
}

void setBrogueGameEvent(CBrogueGameEvent brogueGameEvent) {
    if (gHost) [gHost setGameEvent:(NSInteger)brogueGameEvent];
}

// iOS port (iBrogue): IO.c's mainInputLoop calls this each cursor frame with whether a creature/item
// description box is showing, so the host can suspend pinch-zoom to 1×. Deduped (the loop polls at
// frame rate) so we only forward state changes.
extern "C" void setBrogueExamining(boolean examining) {
    static boolean last = false;
    if (examining == last) return;
    last = examining;
    if (gHost) [gHost setExamining:(BOOL)examining];
}

// iOS port (iBrogue): reports the examine description box's window rect so the iPhone host can zoom to
// fit it rather than all the way to 1×. Emitted only when a box is shown.
extern "C" void setBrogueExamineBox(short x, short y, short width, short height) {
    if (gHost) [gHost setExamineBox:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height];
}

// iOS port (iBrogue): forwards a modal menu overlay's window rect so the iPhone host can auto-magnify
// it (title menu, inventory, action menu, dialogs).
extern "C" void setBrogueMenuBox(short x, short y, short width, short height) {
    if (gHost) [gHost setMenuBox:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height];
}

// iOS port (iBrogue): signals no menu overlay is shown, so the host tears the magnify down.
extern "C" void clearBrogueMenuBox(void) {
    if (gHost) [gHost clearMenuBox];
}

// iOS port (iBrogue): the examine loop asks this before drawing a description box; YES means skip it
// (zoomed-in play-field examine, where the box would tear against the 1× sidebar).
extern "C" boolean brogueShouldSuppressExamineBox(void) {
    return gHost ? (boolean)[gHost shouldSuppressExamineBox] : false;
}

// iOS port (iBrogue): chooseTarget calls this as the aiming loop begins/ends so the host can show the
// on-screen ESC button (Classic has no uiMode==ShowEscape event; it also toggles escButtonWanted).
// Deduped since chooseTarget has several exit points.
extern "C" void setBrogueTargeting(boolean isTargeting) {
    static boolean last = false;
    if (isTargeting == last) return;
    last = isTargeting;
    if (gHost) [gHost setClassicTargeting:(BOOL)isTargeting];
}

void showFileManagementScreen() {
    if (gHost) [gHost presentClassicFileManagement];
}

void showGameCenterScreen() {
    if (gHost) [gHost presentClassicGameCenter];
}

boolean controlKeyIsDown() {
    return gHost ? (boolean)[gHost controlKeyIsDown] : false;
}

boolean shiftKeyIsDown() {
    return NO;
}

void submitAchievementForCharString(char *achievementKey) {
    if (gHost) [gHost submitClassicAchievement:[NSString stringWithUTF8String:achievementKey]];
}

#pragma mark - OSX->iOS implementation

void initHighScores() {
	NSMutableArray *scoresArray, *textArray, *datesArray;
	short j, theCount;

	if ([[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores scores"] == nil
		|| [[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores text"] == nil
		|| [[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores dates"] == nil) {

		scoresArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
		textArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
		datesArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];

		for (j=0; j<HIGH_SCORES_COUNT; j++) {
			[scoresArray addObject:[NSNumber numberWithLong:0]];
			[textArray addObject:[NSString string]];
			[datesArray addObject:[NSDate date]];
		}

		[[NSUserDefaults standardUserDefaults] setObject:scoresArray forKey:@"high scores scores"];
		[[NSUserDefaults standardUserDefaults] setObject:textArray forKey:@"high scores text"];
		[[NSUserDefaults standardUserDefaults] setObject:datesArray forKey:@"high scores dates"];
	}

	theCount = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores scores"] count];

	if (theCount < HIGH_SCORES_COUNT) { // backwards compatibility
		scoresArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
		textArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
		datesArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];

		[scoresArray setArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores scores"]];
		[textArray setArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores text"]];
		[datesArray setArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores dates"]];

		for (j=theCount; j<HIGH_SCORES_COUNT; j++) {
			[scoresArray addObject:[NSNumber numberWithLong:0]];
			[textArray addObject:[NSString string]];
			[datesArray addObject:[NSDate date]];
		}

		[[NSUserDefaults standardUserDefaults] setObject:scoresArray forKey:@"high scores scores"];
		[[NSUserDefaults standardUserDefaults] setObject:textArray forKey:@"high scores text"];
		[[NSUserDefaults standardUserDefaults] setObject:datesArray forKey:@"high scores dates"];
	}

    if ([[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores seeds"] == nil) {
        NSMutableArray *seedArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
        for (j = 0; j < HIGH_SCORES_COUNT; j++) {
            [seedArray addObject:[NSNumber numberWithInt:0]];
        }

        [[NSUserDefaults standardUserDefaults] setObject:seedArray forKey:@"high scores seeds"];
    }

    [[NSUserDefaults standardUserDefaults] synchronize];
}

// returns the index number of the most recent score
short getHighScoresList(rogueHighScoresEntry returnList[HIGH_SCORES_COUNT]) {
	NSArray *scoresArray, *textArray, *datesArray;
	NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"MM/dd/yy"];
    NSDate *mostRecentDate;
	short i, j, maxIndex, mostRecentIndex;
	long maxScore;
	boolean scoreTaken[HIGH_SCORES_COUNT];

	// no scores have been taken
	for (i=0; i<HIGH_SCORES_COUNT; i++) {
		scoreTaken[i] = false;
	}

	initHighScores();

	scoresArray = [[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores scores"];
	textArray = [[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores text"];
	datesArray = [[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores dates"];
    NSArray *seedArray = [[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores seeds"];

	mostRecentDate = [NSDate distantPast];

	// store each value in order into returnList
	for (i=0; i<HIGH_SCORES_COUNT; i++) {
		// find the highest value that hasn't already been taken
		maxScore = 0; // excludes scores of zero
		for (j=0; j<HIGH_SCORES_COUNT; j++) {
			if (scoreTaken[j] == false && [[scoresArray objectAtIndex:j] longValue] >= maxScore) {
				maxScore = [[scoresArray objectAtIndex:j] longValue];
				maxIndex = j;
			}
		}
		// maxIndex identifies the highest non-taken score
		scoreTaken[maxIndex] = true;
		returnList[i].score = [[scoresArray objectAtIndex:maxIndex] longValue];
		strcpy(returnList[i].description, [[textArray objectAtIndex:maxIndex] cStringUsingEncoding:NSASCIIStringEncoding]);
		strcpy(returnList[i].date, [[dateFormatter stringFromDate:[datesArray objectAtIndex:maxIndex]] cStringUsingEncoding:NSASCIIStringEncoding]);
        returnList[i].seed = [[seedArray objectAtIndex:maxIndex] longValue];

		// if this is the most recent score we've seen so far
		if ([mostRecentDate compare:[datesArray objectAtIndex:maxIndex]] == NSOrderedAscending) {
			mostRecentDate = [datesArray objectAtIndex:maxIndex];
			mostRecentIndex = i;
		}
	}


	return mostRecentIndex;
}

// iOS port (iBrogue): persist the most recent run's seed (previousGameSeed) so the title screen's
// seeded-game prompt can pre-fill it across app launches. Stored as an NSNumber so the full unsigned
// long seed range round-trips losslessly.
static NSString * const kLastSeedKey = @"last game seed";

void persistLastSeed(unsigned long seed) {
    [[NSUserDefaults standardUserDefaults] setObject:@((unsigned long long)seed) forKey:kLastSeedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

unsigned long loadPersistedSeed(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kLastSeedKey];
    return n ? (unsigned long)[n unsignedLongLongValue] : 0;
}

// iOS port (iBrogue): persist/restore the chosen keyboard scheme (Classic / Modern), defaulting to
// MODERN when absent or out of range. The @"keyboard scheme" key is shared across all three engines
// (Classic/CE/SE) so the scheme is an app-wide input preference that carries between them.
static NSString * const kKeyboardSchemeKey = @"keyboard scheme";

void persistKeyboardScheme(int scheme) {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)scheme forKey:kKeyboardSchemeKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

enum keyboardScheme loadPersistedKeyboardScheme(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kKeyboardSchemeKey] == nil) {
        return KEYBOARD_SCHEME_MODERN;
    }
    NSInteger stored = [d integerForKey:kKeyboardSchemeKey];
    if (stored < KEYBOARD_SCHEME_CLASSIC || stored >= KEYBOARD_SCHEME_COUNT) {
        return KEYBOARD_SCHEME_MODERN;
    }
    return (enum keyboardScheme)stored;
}

boolean saveHighScore(rogueHighScoresEntry theEntry) {
	NSMutableArray *scoresArray, *textArray, *datesArray;
	NSNumber *newScore;
	NSString *newText;

	short j, minIndex = -1;
	long minScore = theEntry.score;

	// generate high scores if prefs don't exist or contain no high scores data
	initHighScores();

	scoresArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
	textArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
	datesArray = [NSMutableArray arrayWithCapacity:HIGH_SCORES_COUNT];
    NSMutableArray *seedArray = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores seeds"] mutableCopy];

	[scoresArray setArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores scores"]];
	[textArray setArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores text"]];
	[datesArray setArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"high scores dates"]];

	// find the lowest value
	for (j=0; j<HIGH_SCORES_COUNT; j++) {
		if ([[scoresArray objectAtIndex:j] longValue] < minScore) {
			minScore = [[scoresArray objectAtIndex:j] longValue];
			minIndex = j;
		}
	}

    if (theEntry.score > 0) {
        if (gHost) [gHost reportClassicScore:theEntry.score];
    }

	if (minIndex == -1) { // didn't qualify
		return false;
	}

	// minIndex identifies the score entry to be replaced
	newScore = [NSNumber numberWithLong:theEntry.score];
	newText = [NSString stringWithCString:theEntry.description encoding:NSASCIIStringEncoding];
    NSNumber *seed = [NSNumber numberWithLong:theEntry.seed];

	[scoresArray replaceObjectAtIndex:minIndex withObject:newScore];
	[textArray replaceObjectAtIndex:minIndex withObject:newText];
	[datesArray replaceObjectAtIndex:minIndex withObject:[NSDate date]];
    [seedArray replaceObjectAtIndex:minIndex withObject:seed];

	[[NSUserDefaults standardUserDefaults] setObject:scoresArray forKey:@"high scores scores"];
	[[NSUserDefaults standardUserDefaults] setObject:textArray forKey:@"high scores text"];
	[[NSUserDefaults standardUserDefaults] setObject:datesArray forKey:@"high scores dates"];
    [[NSUserDefaults standardUserDefaults] setObject:seedArray forKey:@"high scores seeds"];
	[[NSUserDefaults standardUserDefaults] synchronize];

	return true;
}

void initializeLaunchArguments(enum NGCommands *command, char *path, unsigned long *seed) {
    *command = NG_NOTHING;
	path[0] = '\0';
	*seed = 0;
    // iOS port (iBrogue): cold-launch auto-resume. A one-shot marker set on the last background points
    // at the snapshot; load it straight into the game (no title screen) and consume the marker. If the
    // file is gone, openFile() in mainBrogueJunction returns false and the engine falls through to the
    // title — so no pre-check.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *resumePath = [d stringForKey:kClassicResumePathKey];
    if (resumePath.length) {
        [d removeObjectForKey:kClassicResumePathKey];
        *command = NG_OPEN_GAME;
        strncpy(path, resumePath.UTF8String, BROGUE_FILENAME_MAX - 1);
        path[BROGUE_FILENAME_MAX - 1] = '\0';
    }
}

void migrateFilesFromLegacyStorageLocation() {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSError *err;

    NSString *legacyPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex: 0];

    // Use a folder under Application Support named after the application.
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleName"];
    NSString *legacySupportPath = [legacyPath stringByAppendingPathComponent: appName];

    // Look up the full path to the user's Application Support folder (usually ~/Library/Application Support/).
    NSString *basePath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
    NSString *documentsPath = basePath;//[basePath stringByAppendingPathComponent:@"/"];

    if ([manager fileExistsAtPath:legacySupportPath]) {
        NSArray *legacyFolderContents = [manager contentsOfDirectoryAtPath:legacySupportPath error:&err];

        for (NSString *source in legacyFolderContents) {
            if (![manager copyItemAtPath:[legacySupportPath stringByAppendingPathComponent:source] toPath:[documentsPath stringByAppendingPathComponent:source] error:&err]) {
                NSLog(@"%@", err);
            }
        }
    }
}

void initializeBrogueSaveLocation() {
    migrateFilesFromLegacyStorageLocation();

    NSFileManager *manager = [NSFileManager defaultManager];
    NSError *err;

    // Classic keeps its saves/recordings in the flat Documents/ directory (distinct from CE's
    // Documents/ce and SE's Documents/se) — do NOT scope it, so existing installs keep their files.
    NSString *basePath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
    NSString *documentsPath = basePath;

    // Create our folder the first time it is needed.
    if (![manager fileExistsAtPath:documentsPath]) {
        [manager createDirectoryAtPath:documentsPath withIntermediateDirectories:YES attributes:nil error:&err];
    }

    // Set the working directory to this path, so that savegames and recordings will be stored here.
    [manager changeCurrentDirectoryPath:documentsPath];
}

#define ADD_FAKE_PADDING_FILES 0

// Returns a malloc'ed fileEntry array, and puts the file count into *fileCount. Also returns a pointer
// to the memory that holds the file names, so that it can also be freed afterward.
fileEntry *listFiles(short *fileCount, char **dynamicMemoryBuffer) {
	short i, count, thisFileNameLength;
	unsigned long bufferPosition, bufferSize;
	unsigned long *offsets;
	fileEntry *fileList;
	NSArray *array;
	NSFileManager *manager = [NSFileManager defaultManager];
    NSError *err;
	NSDictionary *fileAttributes;
	NSDateFormatter *dateFormatter;
	const char *thisFileName;

	char tempString[500];

	bufferPosition = bufferSize = 0;
	*dynamicMemoryBuffer = NULL;

	dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"MM/dd/yy"];

	array = [manager contentsOfDirectoryAtPath:[manager currentDirectoryPath] error:&err];
	count = [array count];

	fileList = (fileEntry *)malloc((count + ADD_FAKE_PADDING_FILES) * sizeof(fileEntry));
	offsets = (unsigned long*)malloc((count + ADD_FAKE_PADDING_FILES) * sizeof(unsigned long));

	for (i=0; i < count + ADD_FAKE_PADDING_FILES; i++) {
		if (i < count) {
			thisFileName = [[array objectAtIndex:i] cStringUsingEncoding:NSASCIIStringEncoding];
			fileAttributes = [manager attributesOfItemAtPath:[array objectAtIndex:i] error:nil];

            NSString *aDate = [dateFormatter stringFromDate:[fileAttributes fileModificationDate]];

            const char *date = [aDate cStringUsingEncoding:NSASCIIStringEncoding];

			strcpy(fileList[i].date,
				   date);
		} else {
			// Debug feature.
			sprintf(tempString, "Fake padding file %i.broguerec", i - count + 1);
			thisFileName = &(tempString[0]);
			strcpy(fileList[i].date, "12/12/12");
		}

		thisFileNameLength = strlen(thisFileName);

		if (thisFileNameLength + bufferPosition > bufferSize) {
			bufferSize += sizeof(char) * 1024;
			*dynamicMemoryBuffer = (char *) realloc(*dynamicMemoryBuffer, bufferSize);
		}

		offsets[i] = bufferPosition; // Have to store these as offsets instead of pointers, as realloc could invalidate pointers.

		strcpy(&((*dynamicMemoryBuffer)[bufferPosition]), thisFileName);
		bufferPosition += thisFileNameLength + 1;
	}

	// Convert the offsets to pointers.
	for (i = 0; i < count + ADD_FAKE_PADDING_FILES; i++) {
		fileList[i].path = &((*dynamicMemoryBuffer)[offsets[i]]);
	}

	free(offsets);

	*fileCount = count + ADD_FAKE_PADDING_FILES;
	return fileList;
}
