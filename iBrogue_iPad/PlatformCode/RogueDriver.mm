//
//  RogueDriver.m
//  Brogue
//
//  Created by Brian and Kevin Walker on 12/26/08.
//  Updated for iOS by Seth Howard on 03/01/13
//  Copyright 2012. All rights reserved.
//
//  This file is part of Brogue.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Affero General Public License as
//  published by the Free Software Foundation, either version 3 of the
//  License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Affero General Public License for more details.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#include <limits.h>
#include <unistd.h>
#include "CoreFoundation/CoreFoundation.h"
#import "RogueDriver.h"
#include "IncludeGlobals.h"
#include "Rogue.h"
#import "GameCenterManager.h"
#import <QuartzCore/QuartzCore.h>
#import "Brogue-Swift.h"

#define kRateScore 3000

#define BROGUE_VERSION	4	// A special version number that's incremented only when
// something about the OS X high scores file structure changes.

// Objective-c Bridge

static CGColorSpaceRef _colorSpace;
// quick and easy bridge for C/C++ code. Could be cleaned up.
static SKViewPort *skviewPort;
static BrogueViewController *brogueViewController;

// In-process engine switching: when set, the bridge unblocks the title-screen
// input wait and the engine's titleMenu hook returns rogue.nextGame = NG_QUIT,
// so rogueMain() exits and the Classic engine thread can be torn down. Defined
// with C linkage so the engine (MainMenu.c) can extern it.
volatile boolean classicTerminationRequested = false;
extern "C" void setClassicTerminationRequested(BOOL requested) {
    classicTerminationRequested = requested ? true : false;
}

// iOS port (iBrogue): background suspend/resume. Set by the host
// (setClassicBackgroundSaveRequested) when the app backgrounds; read by the engine
// thread, which snapshots exact state at its next poll point and records a one-shot
// resume marker so a cold launch after an OS kill resumes straight into the game.
// See docs/design/background-suspend-resume.md.
static volatile bool classicBackgroundSaveRequested = false;
static NSString *const kClassicResumePathKey = @"classic resume path";

// Engine-thread only. If a background snapshot was requested, flush the live recording
// so currentFilePath holds every input so far (exact state, even mid-animation — replay
// regenerates it) and mark that file for cold-launch auto-load. No-op unless a live game
// is being recorded (skips title — Swift won't request it there — and playback).
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

// iOS port (iBrogue): host hook (UI thread) — request a snapshot on app background.
extern "C" void setClassicBackgroundSaveRequested(BOOL requested) {
    classicBackgroundSaveRequested = requested ? true : false;
}

// iOS port (iBrogue): host hook (UI thread) — drop a stale resume marker when the app
// survived a background and is returning to a live in-memory game. Also cancels any
// still-pending request.
extern "C" void clearClassicResumeMarker(void) {
    classicBackgroundSaveRequested = false;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kClassicResumePathKey];
}

@implementation RogueDriver 

+ (id)sharedInstanceWithViewPort:(SKViewPort *)viewPort viewController:(BrogueViewController *)viewController {
    static RogueDriver *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[RogueDriver alloc] init];
        brogueViewController = viewController;
        skviewPort = viewPort;
    });
    
    return instance;
}

- (id)init
{
    self = [super init];
    if (self) {
        if (!_colorSpace) {
            _colorSpace = CGColorSpaceCreateDeviceRGB();
        }
    }
    return self;
}

+ (unsigned long)rogueSeed {
    return rogue.seed;
}

@end

//  plotChar: plots inputChar at (xLoc, yLoc) with specified background and foreground colors.
//  Color components are given in ints from 0 to 100.

void plotChar(uchar inputChar,
			  short xLoc, short yLoc,
			  short foreRed, short foreGreen, short foreBlue,
			  short backRed, short backGreen, short backBlue) {
    
   // NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    CGFloat backComponents[] = {(CGFloat)(backRed * .01), (CGFloat)(backGreen * .01), (CGFloat)(backBlue * .01), 1.};
    CGColorRef backColor = CGColorCreate(_colorSpace, backComponents);

    CGFloat foreComponents[] = {(CGFloat)(foreRed * .01), (CGFloat)(foreGreen * .01), (CGFloat)(foreBlue * .01), 1.};
    CGColorRef foreColor = CGColorCreate(_colorSpace, foreComponents);

    [skviewPort setCellWithX:xLoc y:yLoc code:inputChar bgColor:backColor fgColor:foreColor];
    
    CGColorRelease(backColor);
    CGColorRelease(foreColor);
}

// iOS port (iBrogue): Combat.c calls this when the player takes damage. C
// linkage so the C engine resolves the unmangled symbol.
extern "C" void iosPlayerTookDamage(int severity) {
    [brogueViewController playerTookDamage:severity];
}

// iOS port (iBrogue): commitDraws() reports the player's WINDOW cell here every
// refresh so the iPhone pinch-zoom can auto-follow. Deduped against the last
// reported cell so the (frequent) commitDraws calls don't spam the main queue.
extern "C" void iosSetPlayerWindowLocation(short windowX, short windowY) {
    static short lastX = -1, lastY = -1;
    if (windowX == lastX && windowY == lastY) return;
    lastX = windowX;
    lastY = windowY;
    [brogueViewController setPlayerWindowX:windowX y:windowY];
}

__unused void pausingTimerStartsNow() {}

// Returns true if the player interrupted the wait with a keystroke; otherwise false.
boolean pauseForMilliseconds(short milliseconds) {
    BOOL hasEvent = NO;

    [NSThread sleepForTimeInterval:milliseconds/1000.];

    classicTakeBackgroundSnapshotIfRequested(); // iOS port (iBrogue): snapshot mid-animation (e.g. resting)

    if (classicTerminationRequested) {
        return true; // wake the title loop so it can observe the request
    }

    if (brogueViewController.hasTouchEvent || brogueViewController.hasKeyEvent) {
        hasEvent = YES;
    }

	return hasEvent;
}

void nextKeyOrMouseEvent(rogueEvent *returnEvent, boolean textInput, boolean colorsDance) {
	short x, y;
    // Match the current cell layout: bottom strip reserved during gameplay,
    // and left/right insets reserved for the iPhone notch / dynamic island.
    float width = skviewPort.effectiveWidthPoints;
    float height = skviewPort.effectiveHeightPoints;
    float leftInset = skviewPort.leftInsetPoints;
    
    for(;;) {
        // we should be ok to block here. We don't seem to call pauseForMilli and this at the same time
        // 60Hz
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
        
        if ([brogueViewController hasKeyEvent]) {
            // iOS port (iBrogue): the queue now carries real Shift/Ctrl state and a `raw` flag (this
            // replaces the old byte-only dequeKeyEvent — modifiers used to be hardcoded to 0 here, which
            // is why Shift/Ctrl-run never worked on iOS).
            BOOL shift = NO, control = NO, raw = NO;
            int32_t key = [brogueViewController dequeKeyEventWithShift:&shift control:&control raw:&raw];
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
            break;
        }
        if (brogueViewController.hasTouchEvent) {
            UIBrogueTouchEvent *touch = [brogueViewController dequeTouchEvent];
            
            if (touch.phase != UITouchPhaseCancelled) {
                switch (touch.phase) {
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
                        break;
                }
                
                // Invert pinch-zoom (iPhone) so the engine sees the cell under
                // the finger; identity at 1× / outside the map. Same inverse as
                // the Swift getCellCoords and the CE bridge.
                CGPoint loc = [skviewPort unzoomedPoint:touch.location];
                float xInPlay = MAX(float(loc.x) - leftInset, 0.0f);
                x = COLS * xInPlay / width;
                y = ROWS * float(loc.y) / height;
                
                returnEvent->param1 = x;
                returnEvent->param2 = y;
                returnEvent->controlKey = 0;
                returnEvent->shiftKey = 0;
                
                break;
            }
        }
    }
}

#pragma mark - bridge

// iOS port (iBrogue): `numeric` selects a number pad for digit-only entry (seeds);
// `string` is the engine's default, which pre-fills the field so backspace can
// clear it.
void requestKeyboardInput(char *string, boolean numeric) {
    [brogueViewController requestTextInputFor:[NSString stringWithUTF8String:string] numeric:(BOOL)numeric];
}

void setBrogueGameEvent(CBrogueGameEvent brogueGameEvent) {
    brogueViewController.lastBrogueGameEvent = (BrogueGameEvent)brogueGameEvent;
}

// iOS port (iBrogue): IO.c's mainInputLoop calls this each cursor frame with
// whether a creature/item description box is showing, so the host can suspend
// pinch-zoom to 1×. Deduped (the loop polls at frame rate) so we only forward
// state changes. Mirrors CE's ceSetExamining.
extern "C" void setBrogueExamining(boolean examining) {
    static boolean last = false;
    if (examining == last) return;
    last = examining;
    [brogueViewController setExamining:(BOOL)examining];
}

// iOS port (iBrogue): chooseTarget calls this as the aiming loop begins/ends so the
// host can show the on-screen ESC button (Classic has no uiMode==ShowEscape event;
// CE drives the button that way). Deduped since chooseTarget has several exit points.
// Mirrors CE's ceSetTargeting.
extern "C" void setBrogueTargeting(boolean isTargeting) {
    static boolean last = false;
    if (isTargeting == last) return;
    last = isTargeting;
    [brogueViewController setClassicTargeting:(BOOL)isTargeting];
}

void showFileManagementScreen() {
    [brogueViewController presentFileManagementScreen];
}

void showGameCenterScreen() {
    [brogueViewController presentGameCenterScreen];
}

boolean controlKeyIsDown() {
    if (brogueViewController.seedKeyDown) {
        return 1;
    }
    
    return 0;
}

boolean shiftKeyIsDown() {
    return NO;
}

void submitAchievementForCharString(char *achievementKey) {
    [[GameCenter shared] submitAchievement:[NSString stringWithUTF8String:achievementKey] percentComplete:100.];
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

// saves the high scores entry over the lowest-score entry if it qualifies.
// returns whether the score qualified for the list.
// This function ignores the date passed to it in theEntry and substitutes the current
// date instead.

// TODO: going to assume every save highscore qualifies as an end game screen.

// iOS port (iBrogue): persist the most recent run's seed (previousGameSeed) so the
// title screen's seeded-game prompt can pre-fill it across app launches; iOS kills
// backgrounded apps, which would otherwise reset it to 0 each launch. Stored as an
// NSNumber so the full unsigned long seed range round-trips losslessly.
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
// MODERN when absent or out of range (the default layout on iOS/macOS). Mirrors the BrogueCE bridge's
// cePersistKeyboardScheme. The @"keyboard scheme" key is shared across all three engines
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
        [[GameCenter shared] reportScore:theEntry.score leaderboardID:kBrogueHighScoreLeaderBoard];
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
	//*command = NG_SCUM;
    *command = NG_NOTHING;
	path[0] = '\0';
	*seed = 0;
    // iOS port (iBrogue): cold-launch auto-resume. A one-shot marker set on the last background
    // points at the snapshot; load it straight into the game (no title screen) and consume the
    // marker. If the file is gone, openFile() in mainBrogueJunction returns false and the engine
    // falls through to the title — so no pre-check.
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
        // copy all files into the documents directory
    //    [manager copyItemAtPath:legacySupportPath toPath:documentsPath error:&err];
        
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
    
    // Look up the full path to the user's Application Support folder (usually ~/Library/Application Support/).
    NSString *basePath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
    
    // Use a folder under Application Support named after the application.
  //  NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleName"];
    NSString *documentsPath = basePath;//[basePath stringByAppendingPathComponent: appName];
    
    // Create our folder the first time it is needed.
    if (![manager fileExistsAtPath:documentsPath]) {
        [manager createDirectoryAtPath:documentsPath withIntermediateDirectories:YES attributes:nil error:&err];
    }
    
    // Set the working directory to this path, so that savegames and recordings will be stored here.
    [manager changeCurrentDirectoryPath:documentsPath];
}

#define ADD_FAKE_PADDING_FILES 0

// Returns a malloc'ed fileEntry array, and puts the file count into *fileCount.
// Also returns a pointer to the memory that holds the file names, so that it can also
// be freed afterward.
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
    [dateFormatter setDateFormat:@"MM/dd/yy"];//                initWithDateFormat:@"%1m/%1d/%y" allowNaturalLanguage:YES];
    
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
