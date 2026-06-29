// No-op platform layer for the headless fight-simulator spike.
// The engine (Engine/*.c) calls these free functions, normally provided by the
// iOS host (SEBridge.mm). Headless, they do nothing / return inert values.
// See docs/design/fight-simulator.md §8.

#include "Rogue.h"
#include "GlobalsBase.h"
#include <stdint.h>
#include <stddef.h>

// --- Platform variables the engine externs ---
boolean hasGraphics = false;
boolean nonInteractivePlayback = false;
boolean serverMode = false;
enum graphicsModes graphicsMode = TEXT_GRAPHICS;
volatile boolean brogueCEAtTitle = false;
volatile boolean brogueSETerminationRequested = false;

// --- Rendering / input (no-op) ---
void plotChar(enum displayGlyph inputChar,
              short xLoc, short yLoc,
              short backRed, short backGreen, short backBlue,
              short foreRed, short foreGreen, short foreBlue) {}

void nextKeyOrMouseEvent(rogueEvent *returnEvent, boolean textInput, boolean colorsDance) {
    // Headless: hand back a harmless keypress so any input loop terminates rather than spins.
    if (returnEvent) {
        returnEvent->eventType = KEYSTROKE;
        returnEvent->param1 = ACKNOWLEDGE_KEY;
        returnEvent->param2 = 0;
        returnEvent->controlKey = false;
        returnEvent->shiftKey = false;
    }
}

boolean pauseForMilliseconds(short milliseconds, PauseBehavior behavior) { return false; }
boolean isApplicationActive(void) { return true; }
boolean takeScreenshot(void) { return false; }
enum graphicsModes setGraphicsMode(enum graphicsModes mode) { return mode; }

// --- Persistence / scores / history (no-op) ---
uint64_t ceLoadPersistedSeed(void) { return 0; }
void cePersistKeyboardScheme(int scheme) {}
void cePersistLastSeed(uint64_t seed) {}
void ceRequestTextInput(const char *defaultText, boolean numeric) {}
short getHighScoresList(rogueHighScoresEntry returnList[HIGH_SCORES_COUNT]) { return 0; }
boolean saveHighScore(rogueHighScoresEntry theEntry) { return false; }
void saveResetRun(void) {}
void saveRunHistory(char *result, char *killedBy, int score, int lumenstones) {}
rogueRun *loadRunHistory(void) { return NULL; }
fileEntry *listFiles(short *fileCount, char **dynamicMemoryBuffer) {
    if (fileCount) *fileCount = 0;
    if (dynamicMemoryBuffer) *dynamicMemoryBuffer = NULL;
    return NULL;
}

// --- iOS host hooks (haptics, UI panels, telemetry) — no-op ---
void notifyEvent(short eventId, int data1, int data2, const char *str1, const char *str2) {}
void initializeLaunchArguments(enum NGCommands *command, char *path, uint64_t *seed) {
    if (command) *command = NG_NOTHING;
    if (seed) *seed = 0;
}
boolean tryParseUint64(char *str, uint64_t *num) { return false; }
void cePlayDetectionHaptic(int stage) {}
void cePlayEnvironmentalNoiseHaptic(int kind) {}
void cePlayerTookDamage(int severity) {}
void ceSetExamining(boolean examining) {}
void ceSetPlayerWindowLocation(short windowX, short windowY) {}
void ceSetTargeting(boolean isTargeting) {}
void ceShowFileManagement(void) {}
void ceShowGameCenter(void) {}
void seRecordExplorationStats(const char *header, const char *row) {}
void seRecordRestStats(const char *header, const char *row) {}
