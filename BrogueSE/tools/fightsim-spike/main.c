// Fight-simulator de-risking spike.
// Goal: prove the Brogue engine can be linked into a headless CLI and that
// attack() runs against a STUB grid (no full level gen) with no UI.
// See docs/design/fight-simulator.md §8.

#include "Rogue.h"
#include "GlobalsBase.h"
#include "Globals.h"
#include <stdio.h>

// Carve a small floor arena so terrain lookups in attack()/killCreature are valid.
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

int main(void) {
    gameVariant = VARIANT_BROGUE;
    initializeGameVariant();
    initializeRogue(1 /* seed */);

    printf("[spike] engine + rogue initialized. version: %s\n", gameConst->versionString);

    // --- Build a stub arena and place the player ---
    carveArena(8, 8, 14, 12);
    const pos playerLoc  = { 10, 10 };
    const pos monsterLoc = { 11, 10 }; // adjacent (east)
    player.loc = playerLoc;
    pmapAt(playerLoc)->flags |= HAS_PLAYER;

    // --- Spawn a rat (monsterCatalog[1]) adjacent to the player ---
    creature *rat = generateMonster(1 /* rat */, false, false);
    rat->loc = monsterLoc;
    rat->creatureState = MONSTER_TRACKING_SCENT; // awake & hostile, so it's not a sneak attack
    pmapAt(monsterLoc)->flags |= HAS_MONSTER;

    printf("[spike] player HP %d/%d  vs  rat HP %d/%d\n",
           player.currentHP, player.info.maxHP, rat->currentHP, rat->info.maxHP);

    // §9 oracle: the engine's own analytic combat math, callable headless.
    printf("[spike] oracle: P(player hits rat)=%d%%, P(rat hits player)=%d%%\n",
           hitProbability(&player, rat), hitProbability(rat, &player));

    // --- Attack the rat to the death; print each round ---
    int round = 0;
    while (rat->currentHP > 0 && round < 50) {
        short before = rat->currentHP;
        attack(&player, rat, false);
        round++;
        printf("[spike] round %2d: player attacked rat  (rat HP %d -> %d)\n",
               round, before, rat->currentHP);
        if (rat->currentHP <= 0) break;
        // Rat hits back.
        short pbefore = player.currentHP;
        attack(rat, &player, false);
        printf("[spike] round %2d: rat attacked player  (player HP %d -> %d)\n",
               round, pbefore, player.currentHP);
    }

    printf("[spike] DONE after %d rounds. rat dead=%s, player HP=%d\n",
           round, (rat->currentHP <= 0 ? "yes" : "no"), player.currentHP);
    return 0;
}
