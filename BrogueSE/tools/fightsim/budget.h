// Depth-derived resource budget: how many strength potions, enchant scrolls, and life potions a
// player has typically found by a given depth — built from the engine's OWN level generation
// (metered cadence + random draw), averaged over seeds. This is what makes "depth" the real axis:
// strength accrues with depth and curves the weapon as much as enchants do.
#ifndef FIGHTSIM_BUDGET_H
#define FIGHTSIM_BUDGET_H

typedef struct {
    double strengthPotions;  // -> rogue.strength = 12 + this
    double enchantScrolls;   // -> the enchant budget B
    double lifePotions;      // -> player maxHP = 30 + 10*this
} DepthBudget;

// Descend real generated levels 1..maxDepth for `seeds` seeds, counting cumulative floor items.
void fs_buildBudgetTable(int maxDepth, int seeds);
DepthBudget fs_budgetAt(int depth);   // cumulative expected counts by that depth
int fs_budgetMaxDepth(void);

#endif
