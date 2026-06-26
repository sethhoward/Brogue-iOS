// Depth-derived resource budget — see budget.h.
#include "Rogue.h"
#include "GlobalsBase.h"
#include "Globals.h"
#include "budget.h"
#include <stdint.h>

#define FS_MAXD 40
static DepthBudget g_table[FS_MAXD + 1];
static int g_maxDepth = 0;

void fs_buildBudgetTable(int maxDepth, int seeds) {
    if (maxDepth > FS_MAXD) maxDepth = FS_MAXD;
    g_maxDepth = maxDepth;
    for (int d = 0; d <= maxDepth; d++) g_table[d] = (DepthBudget){0, 0, 0};

    static boolean inited = false;
    for (int s = 1; s <= seeds; s++) {
        if (inited) freeEverything();
        initializeGameVariant();
        initializeRogue((uint64_t) s);
        rogue.playbackOmniscience = true; // so generation isn't gated on player sight
        inited = true;

        int cumStr = 0, cumEnch = 0, cumLife = 0;
        for (int d = 1; d <= maxDepth; d++) {
            rogue.depthLevel = d;
            startLevel(d == 1 ? 1 : d - 1, 1); // generate/descend into level d (same as seed catalog)
            for (item *it = floorItems->nextItem; it != NULL; it = it->nextItem) {
                if (it->category == POTION && it->kind == POTION_STRENGTH) cumStr  += it->quantity;
                else if (it->category == POTION && it->kind == POTION_LIFE) cumLife += it->quantity;
                else if (it->category == SCROLL && it->kind == SCROLL_ENCHANTING) cumEnch += it->quantity;
            }
            g_table[d].strengthPotions += cumStr;
            g_table[d].enchantScrolls  += cumEnch;
            g_table[d].lifePotions     += cumLife;
        }
    }
    if (inited) freeEverything(); // leave the engine "freed"; combat phase re-inits per encounter

    for (int d = 1; d <= maxDepth; d++) {
        g_table[d].strengthPotions /= seeds;
        g_table[d].enchantScrolls  /= seeds;
        g_table[d].lifePotions     /= seeds;
    }
}

DepthBudget fs_budgetAt(int depth) {
    if (depth < 1) depth = 1;
    if (depth > g_maxDepth) depth = g_maxDepth;
    return g_table[depth];
}

int fs_budgetMaxDepth(void) { return g_maxDepth; }
