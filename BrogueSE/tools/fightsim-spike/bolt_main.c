// Fight-simulator de-risking spike #2: the bolt / AOE path.
// Goal: prove the SE staff "glow-up" ramps (lightning chain + stun at net-enchant >= 5)
// fire correctly headless, via the real zap() bolt code on a stub grid.
// See docs/design/fight-simulator.md §0 (SE staff ramps) and §8.

#include "Rogue.h"
#include "GlobalsBase.h"
#include "Globals.h"
#include <stdio.h>

static void carveArena(short x0, short y0, short x1, short y1) {
    for (short i = x0; i <= x1; i++) {
        for (short j = y0; j <= y1; j++) {
            pmap[i][j].layers[DUNGEON] = FLOOR;
            pmap[i][j].layers[LIQUID]  = NOTHING;
            pmap[i][j].layers[SURFACE] = NOTHING;
            pmap[i][j].layers[GAS]     = NOTHING;
            pmap[i][j].flags |= (DISCOVERED | VISIBLE | IN_FIELD_OF_VIEW);
            pmap[i][j].flags &= ~(HAS_MONSTER | HAS_PLAYER);
        }
    }
}

// A rat, but with inflated HP so it survives the bolt and we can read HP deltas + status.
static creature *placeTankyRat(pos loc) {
    creature *m = generateMonster(1 /* rat */, false, false);
    m->loc = loc;
    m->currentHP = m->info.maxHP = 100;
    m->creatureState = MONSTER_TRACKING_SCENT; // hostile, awake
    pmapAt(loc)->flags |= HAS_MONSTER;
    return m;
}

static void clearMonsters(void) {
    // Wipe the monster list and HAS_MONSTER flags so each scenario starts clean.
    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
        creature *m = nextCreature(&it);
        pmapAt(m->loc)->flags &= ~HAS_MONSTER;
    }
    *monsters = createCreatureList();
}

static void runLightning(const char *label, short enchant) {
    clearMonsters();
    carveArena(6, 7, 20, 13);

    const pos playerLoc = { 8, 10 };
    player.loc = playerLoc;
    pmapAt(playerLoc)->flags |= HAS_PLAYER;

    creature *onLineA  = placeTankyRat((pos){ 11, 10 }); // straight bolt should hit (passes thru)
    creature *onLineB  = placeTankyRat((pos){ 14, 10 }); // straight bolt should hit
    creature *offLine  = placeTankyRat((pos){ 14,  8 }); // 2 tiles off the line -> only the SE chain can reach it

    // Build the lightning bolt exactly like useStaffOrWand (Items.c:7939-7947).
    bolt theBolt = boltCatalog[BOLT_LIGHTNING];
    theBolt.magnitude = enchant;
    if (enchant >= 5) {
        theBolt.empowerment = enchant; // net enchant == raw enchant for a staff; gates the SE ramps
    }

    printf("\n=== %s (enchant +%d, empowerment=%d) ===\n", label, enchant, theBolt.empowerment);
    printf("    ramps: chainCount=%d chainRange=%d stunDur=%d\n",
           staffLightningChainCount(theBolt.empowerment),
           staffLightningChainRange(theBolt.empowerment),
           staffLightningStunDuration(theBolt.empowerment));

    zap(playerLoc, (pos){ 18, 10 }, &theBolt, false, false);

    printf("    on-line  A (11,10): HP %3d/100  paralyzed=%d\n", onLineA->currentHP, onLineA->status[STATUS_PARALYZED]);
    printf("    on-line  B (14,10): HP %3d/100  paralyzed=%d\n", onLineB->currentHP, onLineB->status[STATUS_PARALYZED]);
    printf("    OFF-line   (14, 8): HP %3d/100  paralyzed=%d  <- only the SE chain can touch this\n",
           offLine->currentHP, offLine->status[STATUS_PARALYZED]);
}

int main(void) {
    gameVariant = VARIANT_BROGUE;
    initializeGameVariant();
    initializeRogue(1 /* seed */);
    printf("[bolt-spike] SE engine initialized. version: %s\n", gameConst->versionString);

    runLightning("BASELINE +4 (below SE ramp threshold)", 4);
    runLightning("RAMPED   +6 (SE glow-up active)",       6);

    printf("\n[bolt-spike] DONE. If the OFF-line monster is untouched at +4 but damaged/paralyzed at +6,\n");
    printf("             the SE lightning chain + stun ramps fired through the real zap() path.\n");
    return 0;
}
