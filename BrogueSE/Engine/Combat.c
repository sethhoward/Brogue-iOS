/*
 *  Combat.c
 *  Brogue
 *
 *  Created by Brian Walker on 6/11/09.
 *  Copyright 2012. All rights reserved.
 *
 *  This file is part of Brogue.
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "Rogue.h"
#include "GlobalsBase.h"
#include "Globals.h"
#ifdef FIGHTSIM
#include "balance.h" // fight-simulator tunables (sim-only build); no effect on shipping
#endif

// Per-hit player-weapon damage scale in percent; 100 = normal. See the extern in Rogue.h.
short gWeaponDamageScalePct = 100;

// iOS port (iBrogue): host hook for a haptic when the player takes damage.
// severity: 0 = ordinary hit, 1 = survived but now under 40% health, 2 = fatal.
// Defined in CEBridge.mm; no-op on devices without a haptic engine.
extern void cePlayerTookDamage(int severity);


/* Combat rules:
 * Each combatant has an accuracy rating. This is the percentage of their attacks that will ordinarily hit;
 * higher numbers are better for them. Numbers over 100 are permitted.
 *
 * Each combatant also has a defense rating. The "hit probability" is calculated as given by this formula:
 *
 *          hit probability = (accuracy) * 0.987 ^ (defense)
 *
 * when hit determinations are made. Negative numbers and numbers over 100 are permitted.
 * The hit is then randomly determined according to this final percentage.
 *
 * Some environmental factors can modify these numbers. An unaware, sleeping, stuck or paralyzed
 * combatant is always hit. An unaware, sleeping or paralyzed combatant also takes triple damage.
 *
 * If the hit lands, damage is calculated in the range provided. However, the clumping factor affects the
 * probability distribution. If the range is 0-10 with a clumping factor of 1, it's a uniform distribution.
 * With a clumping factor of 2, it's calculated as 2d5 (with d5 meaing a die numbered from 0 through 5).
 * With 3, it's 3d3, and so on. Note that a range not divisible by the clumping factor is defective,
 * as it will never be resolved in the top few numbers of the range. In fact, the top
 * (rangeWidth % clumpingFactor) will never succeed. Thus we increment the maximum of the first
 * (rangeWidth % clumpingFactor) die by 1, so that in fact 0-10 with a CF of 3 would be 1d4 + 2d3. Similarly,
 * 0-10 with CF 4 would be 2d3 + 2d2. By playing with the numbers, one can approximate a gaussian
 * distribution of any mean and standard deviation.
 *
 * Player combatants take their base defense value of their actual armor. Their accuracy is a combination of weapon, armor
 * and strength.
 *
 * Players have a base accuracy value of 100 throughout the game. Each point of weapon enchantment (net of
 * strength penalty/benefit) increases
 */

fixpt strengthModifier(item *theItem) {
    int difference = (rogue.strength - player.weaknessAmount) - theItem->strengthRequired;
#ifdef FIGHTSIM
    // Fight-simulator tunable (sim-only build; gBalance defaults == the literals below).
    if (difference > 0) {
        return difference * FP_FACTOR * gBalance.strengthBonusNum / gBalance.strengthBonusDen;
    } else {
        return difference * FP_FACTOR * gBalance.strengthPenaltyNum / gBalance.strengthPenaltyDen;
    }
#else
    if (difference > 0) {
        return difference * FP_FACTOR / 4; // 0.25x
    } else {
        return difference * FP_FACTOR * 5/2; // 2.5x
    }
#endif
}

fixpt netEnchant(item *theItem) {
    fixpt retval = theItem->enchant1 * FP_FACTOR;
    if (theItem->category & (WEAPON | ARMOR)) {
        retval += strengthModifier(theItem);
    }
    // Clamp all net enchantment values to [-20, 50].
#ifdef FIGHTSIM
    // Soft knee per weapon: full value up to heavyWeaponCap[kind] (the knee), then each point above it
    // is worth only heavyWeaponSlopePct% (diminishing returns instead of a wall). slope 0 == a hard cap;
    // slope 100 == no taper. knee 0 == untouched, so shipping (all-zero) is byte-identical.
    if ((theItem->category & WEAPON) && gBalance.heavyWeaponCap[theItem->kind] > 0) {
        fixpt kneeFp = (fixpt)gBalance.heavyWeaponCap[theItem->kind] * FP_FACTOR;
        if (retval > kneeFp) {
            retval = kneeFp + (retval - kneeFp) * gBalance.heavyWeaponSlopePct[theItem->kind] / 100;
        }
    }
    return clamp(retval, gBalance.netEnchantClampLo * FP_FACTOR, gBalance.netEnchantClampHi * FP_FACTOR);
#else
    // Heavy-weapon balance pass: broadsword and war axe earn only a 25% marginal enchant past a knee
    // (a soft cap, not a cliff) -- curbs their late-game raw-stat dominance as the universal go-to without
    // inverting the upgrade path (they stay ahead of sword/axe) or punishing continued enchanting. Derived
    // from the fight simulator; see docs/design/fight-simulator-findings.md.
    if (theItem->category & WEAPON) {
        int knee = (theItem->kind == BROADSWORD) ? 10 : (theItem->kind == WAR_AXE) ? 10 : 0;
        if (knee > 0) {
            fixpt kneeFp = (fixpt)knee * FP_FACTOR;
            if (retval > kneeFp) {
                retval = kneeFp + (retval - kneeFp) * 25 / 100;
            }
        }
    }
    return clamp(retval, -20 * FP_FACTOR, 50 * FP_FACTOR);
#endif
}

fixpt monsterDamageAdjustmentAmount(const creature *monst) {
    if (monst == &player) {
        // Handled through player strength routines elsewhere.
        return FP_FACTOR;
    } else {
        return damageFraction(monst->weaknessAmount * FP_FACTOR * -3/2);
    }
}

short monsterDefenseAdjusted(const creature *monst) {
    short retval;
    if (monst == &player) {
        // Weakness is already taken into account in recalculateEquipmentBonuses() for the player.
        retval = monst->info.defense;
    } else {
        retval = monst->info.defense - 25 * monst->weaknessAmount;
    }
    retval += emboldenmentDefenseBonus(monst); // iOS port (iBrogue): ring of light ally aura
    return max(retval, 0);
}

short monsterAccuracyAdjusted(const creature *monst) {
    short retval = monst->info.accuracy * accuracyFraction(monst->weaknessAmount * FP_FACTOR * -3/2) / FP_FACTOR;
    retval += emboldenmentAccuracyBonus(monst); // iOS port (iBrogue): ring of light ally aura
    return max(retval, 0);
}

// does NOT account for auto-hit from sleeping or unaware defenders; does account for auto-hit from
// stuck or captive defenders and from weapons of slaying.
short hitProbability(creature *attacker, creature *defender) {
    short accuracy = monsterAccuracyAdjusted(attacker);
    short defense = monsterDefenseAdjusted(defender);
    short hitProbability;

    if (defender->status[STATUS_STUCK] || (defender->bookkeepingFlags & MB_CAPTIVE)) {
        return 100;
    }
    if ((defender->bookkeepingFlags & MB_SEIZED)
        && (attacker->bookkeepingFlags & MB_SEIZING)) {

        return 100;
    }
    if (attacker == &player && rogue.weapon) {
        if ((rogue.weapon->flags & ITEM_RUNIC)
            && rogue.weapon->enchant2 == W_SLAYING
            && monsterIsInClass(defender, rogue.weapon->vorpalEnemy)) {

            return 100;
        }
        accuracy = player.info.accuracy * accuracyFraction(netEnchant(rogue.weapon)) / FP_FACTOR;
    }
    hitProbability = accuracy * defenseFraction(defense * FP_FACTOR) / FP_FACTOR;
    if (hitProbability > 100) {
        hitProbability = 100;
    } else if (hitProbability < 0) {
        hitProbability = 0;
    }
    return hitProbability;
}

boolean attackHit(creature *attacker, creature *defender) {
    // automatically hit if the monster is sleeping or captive or stuck in a web
    if (defender->status[STATUS_STUCK]
        || defender->status[STATUS_PARALYZED]
        || defender->status[STATUS_FROZEN] // iOS port (iBrogue): staff of frost — a frozen creature can't dodge
        || (defender->bookkeepingFlags & MB_CAPTIVE)) {

        return true;
    }

    return rand_percent(hitProbability(attacker, defender));
}

static void addMonsterToContiguousMonsterGrid(short x, short y, creature *monst, char grid[DCOLS][DROWS]) {
    short newX, newY;
    enum directions dir;
    creature *tempMonst;

    grid[x][y] = true;
    for (dir=0; dir<4; dir++) {
        newX = x + nbDirs[dir][0];
        newY = y + nbDirs[dir][1];

        if (coordinatesAreInMap(newX, newY) && !grid[newX][newY]) {
            tempMonst = monsterAtLoc((pos){ newX, newY });
            if (tempMonst && monstersAreTeammates(monst, tempMonst)) {
                addMonsterToContiguousMonsterGrid(newX, newY, monst, grid);
            }
        }
    }
}

static short alliedCloneCount(creature *monst) {
    short count = 0;
    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
        creature *temp = nextCreature(&it);
        if (temp != monst
            && temp->info.monsterID == monst->info.monsterID
            && monstersAreTeammates(temp, monst)) {

            count++;
        }
    }
    if (rogue.depthLevel > 1) {
        for (creatureIterator it = iterateCreatures(&levels[rogue.depthLevel - 2].monsters); hasNextCreature(it);) {
            creature *temp = nextCreature(&it);
            if (temp != monst
                && temp->info.monsterID == monst->info.monsterID
                && monstersAreTeammates(temp, monst)) {

                count++;
            }
        }
    }
    if (rogue.depthLevel < gameConst->deepestLevel) {
        for (creatureIterator it = iterateCreatures(&levels[rogue.depthLevel].monsters); hasNextCreature(it);) {
            creature *temp = nextCreature(&it);
            if (temp != monst
                && temp->info.monsterID == monst->info.monsterID
                && monstersAreTeammates(temp, monst)) {

                count++;
            }
        }
    }
    return count;
}

// Splits a monster in half.
// The split occurs only if there is a spot adjacent to the contiguous
// group of monsters that the monster would not avoid.
// The contiguous group is supplemented with the given (x, y) coordinates, if any;
// this is so that jellies et al. can spawn behind the player in a hallway.
void splitMonster(creature *monst, creature *attacker) {
    char buf[DCOLS * 3];
    char monstName[DCOLS];
    char monsterGrid[DCOLS][DROWS], eligibleGrid[DCOLS][DROWS];
    creature *clone;
    pos loc = INVALID_POS;

    if ((monst->info.abilityFlags & MA_CLONE_SELF_ON_DEFEND) && alliedCloneCount(monst) < 100
        && monst->currentHP > 0 && !(monst->bookkeepingFlags & MB_IS_DYING)) {

        if (distanceBetween(monst->loc, attacker->loc) <= 1) {
            loc = attacker->loc;
        }
    } else {
        return;
    }

    zeroOutGrid(monsterGrid);
    zeroOutGrid(eligibleGrid);
    int eligibleLocationCount = 0;

    // Add the (x, y) location to the contiguous group, if any.
    if (isPosInMap(loc)) {
        monsterGrid[loc.x][loc.y] = true;
    }

    // Find the contiguous group of monsters.
    addMonsterToContiguousMonsterGrid(monst->loc.x, monst->loc.y, monst, monsterGrid);

    // Find the eligible edges around the group of monsters.
    for (int i=0; i<DCOLS; i++) {
        for (int j=0; j<DROWS; j++) {
            if (monsterGrid[i][j]) {
                for (int dir=0; dir<4; dir++) {
                    const int newX = i + nbDirs[dir][0];
                    const int newY = j + nbDirs[dir][1];
                    if (coordinatesAreInMap(newX, newY)
                        && !eligibleGrid[newX][newY]
                        && !monsterGrid[newX][newY]
                        && !(pmap[newX][newY].flags & (HAS_PLAYER | HAS_MONSTER))
                        && !monsterAvoids(monst, (pos){ newX, newY })) {

                        eligibleGrid[newX][newY] = true;
                        eligibleLocationCount++;
                    }
                }
            }
        }
    }
//    DEBUG {
//        hiliteCharGrid(eligibleGrid, &green, 75);
//        hiliteCharGrid(monsterGrid, &blue, 75);
//        temporaryMessage("Jelly spawn possibilities (green = eligible, blue = monster):", REQUIRE_ACKNOWLEDGMENT);
//        displayLevel();
//    }

    // Pick a random location on the eligibleGrid and add the clone there.
    if (eligibleLocationCount) {
        int randIndex = rand_range(1, eligibleLocationCount);
        for (int i=0; i<DCOLS; i++) {
            for (int j=0; j<DROWS; j++) {
                if (eligibleGrid[i][j] && !--randIndex) {
                    // Found the spot!

                    monsterName(monstName, monst, true);
                    monst->currentHP = (monst->currentHP + 1) / 2;
                    clone = cloneMonster(monst, false, false);

                    // Split monsters don't inherit the learnings of their parents.
                    // Sorry, but self-healing jelly armies are too much.
                    // Mutation effects can be inherited, however; they're not learned abilities.
                    if (monst->mutationIndex >= 0) {
                        clone->info.flags           &= (monsterCatalog[clone->info.monsterID].flags | mutationCatalog[monst->mutationIndex].monsterFlags);
                        clone->info.abilityFlags    &= (monsterCatalog[clone->info.monsterID].abilityFlags | mutationCatalog[monst->mutationIndex].monsterAbilityFlags);
                    } else {
                        clone->info.flags           &= monsterCatalog[clone->info.monsterID].flags;
                        clone->info.abilityFlags    &= monsterCatalog[clone->info.monsterID].abilityFlags;
                    }
                    for (int b = 0; b < 20; b++) {
                        clone->info.bolts[b] = monsterCatalog[clone->info.monsterID].bolts[b];
                    }

                    if (!(clone->info.flags & MONST_FLIES)
                        && clone->status[STATUS_LEVITATING] == 1000) {

                        clone->status[STATUS_LEVITATING] = 0;
                    }

                    clone->loc = (pos){.x = i, .y = j};
                    pmap[i][j].flags |= HAS_MONSTER;
                    clone->ticksUntilTurn = max(clone->ticksUntilTurn, 101);
                    fadeInMonster(clone);
                    refreshSideBar(-1, -1, false);

                    if (canDirectlySeeMonster(monst)) {
                        sprintf(buf, "%s splits in two!", monstName);
                        message(buf, 0);
                    }

                    return;
                }
            }
        }
    }
}

// This function is called whenever one creature acts aggressively against another in a way that directly causes damage.
// This can be things like melee attacks, fire/lightning attacks or throwing a weapon.
void moralAttack(creature *attacker, creature *defender) {

    if (defender->currentHP > 0
        && !(defender->bookkeepingFlags & MB_IS_DYING)) {

        if (defender->status[STATUS_PARALYZED] || defender->status[STATUS_FROZEN]) {
            defender->status[STATUS_PARALYZED] = 0;
            defender->status[STATUS_FROZEN] = 0; // iOS port (iBrogue): a blow shatters the ice (the layered slow tail remains)
             // Paralyzed creature gets a turn to react before the attacker moves again.
            defender->ticksUntilTurn = min(attacker->attackSpeed, 100) - 1;
        }
        if (defender->status[STATUS_MAGICAL_FEAR]) {
            defender->status[STATUS_MAGICAL_FEAR] = 1;
        }
        defender->status[STATUS_ENTRANCED] = 0;

        if ((defender->info.abilityFlags & MA_AVOID_CORRIDORS)) {
            defender->status[STATUS_ENRAGED] = defender->maxStatus[STATUS_ENRAGED] = 4;
        }

        if (attacker == &player
            && defender->creatureState == MONSTER_ALLY
            && !defender->status[STATUS_DISCORDANT]
            && !attacker->status[STATUS_CONFUSED]
            && !(attacker->bookkeepingFlags & MB_IS_DYING)) {

            unAlly(defender);
        }

        if ((attacker == &player || attacker->creatureState == MONSTER_ALLY)
            && defender != &player
            && defender->creatureState != MONSTER_ALLY) {

            alertMonster(defender); // this alerts the monster that you're nearby
        }
    }
}

/// @brief Determine if the action forfeits the paladin feat. In general, the player fails the feat if they attempt
/// to deal direct damage to a non-hunting creature that they are aware of and the creature would be damaged by the attack.
/// @param attacker 
/// @param defender 
void handlePaladinFeat(creature *defender) {
    if (rogue.featRecord[FEAT_PALADIN]
        && defender->creatureState != MONSTER_TRACKING_SCENT
        && (player.status[STATUS_TELEPATHIC] || canSeeMonster(defender))
        && !(defender->info.flags & (MONST_INANIMATE | MONST_TURRET | MONST_IMMOBILE | MONST_INVULNERABLE))
        && !(player.bookkeepingFlags & MB_SEIZED)
        && defender != &player
        ) {
        rogue.featRecord[FEAT_PALADIN] = false;
    }
}

static boolean playerImmuneToMonster(creature *monst) {
    if (monst != &player
        && rogue.armor
        && (rogue.armor->flags & ITEM_RUNIC)
        && (rogue.armor->enchant2 == A_IMMUNITY)
        && monsterIsInClass(monst, rogue.armor->vorpalEnemy)) {

        return true;
    } else {
        return false;
    }
}

// iOS port (iBrogue): steal-preference component (see docs/guides/reusable-components.md). Scores how much a
// thief wants a given item, from its catalog stealProfile -- the data-driven successor to the per-monsterID
// branches that ported PR #849 ("Deductive Thievery"). Theft becomes an identification hint: monkeys favor food
// and potions of life/strength (but, ADDITIVE, will take anything); imps favor scrolls of enchanting, positively-
// enchanted gear (scaled), and runics, and dislike food. Pure scoring (no RNG); the weighted draw happens at the
// call site in specialHit. Returns 0 for an item this thief will not take (EXCLUSIVE mode, no rule matched).
// A thief with no profile falls back to the legacy "every item equally desirable" (score 10) behavior.
static short rateItemStealDesirability(creature *thief, item *theItem) {
    if (!theItem) {
        return 0;
    }
    const stealProfile *profile = thief->info.steal;
    if (!profile) {
        return 10; // legacy default: uniform desirability
    }
    short score = profile->baseScore;
    boolean matched = false;
    for (const stealRule *r = profile->rules;
         r->categories || r->requireFlags || r->enchant != ENCHANT_ANY; // a no-criteria row terminates the list
         r++) {

        if (r->categories && !(theItem->category & r->categories)) continue;
        if (r->kind >= 0 && theItem->kind != r->kind) continue;
        if (r->enchant == ENCHANT_POSITIVE && theItem->enchant1 <= 0) continue;
        if (r->enchant == ENCHANT_NEGATIVE && theItem->enchant1 >= 0) continue;
        if (r->requireFlags && (theItem->flags & r->requireFlags) != r->requireFlags) continue;

        matched = true;
        score += r->flatBonus;
        score += theItem->enchant1 * r->perEnchantBonus;
    }
    if (profile->mode == STEAL_EXCLUSIVE && !matched) {
        return 0; // this thief is only interested in matching items
    }
    return max(1, score);
}

// iOS port (Brogue SE): cursed-runics rework -- a PURIFIED Anchor makes the player immovable: immune to
// knockback (MA_ATTACKS_STAGGER, e.g. an ogre) and to being seized/held (MA_SEIZES, e.g. a bog monster).
// Gated on purify (enchant >= threshold), so it's the purify reward; a cursed Anchor doesn't get it.
static boolean playerHasImmovableAnchor(void) {
    return rogue.armor && (rogue.armor->flags & ITEM_RUNIC)
        && rogue.armor->enchant2 == A_ANCHOR
        && rogue.armor->enchant1 >= ARMOR_RUNIC_PURIFY_ENCHANT;
}

static void specialHit(creature *attacker, creature *defender, short damage) {
    short itemCandidates, randItemIndex, stolenQuantity;
    item *theItem = NULL, *itemFromTopOfStack;
    char buf[COLS], buf2[COLS], buf3[COLS];

    if (!(attacker->info.abilityFlags & SPECIAL_HIT)) {
        return;
    }

    // Special hits that can affect only the player:
    if (defender == &player) {
        if (playerImmuneToMonster(attacker)) {
            return;
        }

        if (attacker->info.abilityFlags & MA_HIT_DEGRADE_ARMOR
            && defender == &player
            && rogue.armor
            && !(rogue.armor->flags & ITEM_PROTECTED)
            && (rogue.armor->enchant1 + rogue.armor->armor/10 > -10)) {

            rogue.armor->enchant1--;
            equipItem(rogue.armor, true, NULL);
            itemName(rogue.armor, buf2, false, false, NULL);
            sprintf(buf, "your %s weakens!", buf2);
            messageWithColor(buf, &itemMessageColor, 0);
            checkForDisenchantment(rogue.armor);
        }
        if (attacker->info.abilityFlags & MA_HIT_HALLUCINATE) {
            if (!player.status[STATUS_HALLUCINATING]) {
                combatMessage("you begin to hallucinate", 0);
            }
            if (!player.status[STATUS_HALLUCINATING]) {
                player.maxStatus[STATUS_HALLUCINATING] = 0;
            }
            player.status[STATUS_HALLUCINATING] += gameConst->onHitHallucinateDuration;
            player.maxStatus[STATUS_HALLUCINATING] = max(player.maxStatus[STATUS_HALLUCINATING], player.status[STATUS_HALLUCINATING]);
        }
        if (attacker->info.abilityFlags & MA_HIT_BURN
             && !defender->status[STATUS_IMMUNE_TO_FIRE]) {

            exposeCreatureToFire(defender);
        }

        if (attacker->info.abilityFlags & MA_HIT_STEAL_FLEE
            && !(attacker->carriedItem)
            && (packItems->nextItem)
            && attacker->currentHP > 0
            && !attacker->status[STATUS_CONFUSED] // No stealing from the player if you bump him while confused.
            && attackHit(attacker, defender)) {

            // iOS port (iBrogue): steal-preference component. Eligibility and weighting come from the thief's
            // stealProfile (catalog `steal` field) via rateItemStealDesirability: an ADDITIVE thief (monkey, imp)
            // scores every unequipped item >= 1, so it always grabs SOMETHING; an EXCLUSIVE thief scores only the
            // items it wants (the rest rate 0 and are skipped). A configurable share of thefts (randomPickPercent,
            // default 5) ignores the weighting and picks uniformly -- but only AMONG THE ELIGIBLE items, so an
            // EXCLUSIVE thief never breaks its own rule. Monkey/imp stay RNG-identical to the previous hardcoded
            // path (same rand_percent, then rand_range over the same scores).
            const stealProfile *stealPrefs = attacker->info.steal;
            itemCandidates = 0;
            for (theItem = packItems->nextItem; theItem != NULL; theItem = theItem->nextItem) {
                if (!(theItem->flags & (ITEM_EQUIPPED)) && rateItemStealDesirability(attacker, theItem) > 0) {
                    itemCandidates++;
                }
            }
            theItem = NULL;
            if (itemCandidates) {
                if (rand_percent(stealPrefs ? stealPrefs->randomPickPercent : 5)) {
                    randItemIndex = rand_range(1, itemCandidates);
                    for (theItem = packItems->nextItem; theItem != NULL; theItem = theItem->nextItem) {
                        if (!(theItem->flags & (ITEM_EQUIPPED)) && rateItemStealDesirability(attacker, theItem) > 0) {
                            if (randItemIndex == 1) {
                                break;
                            } else {
                                randItemIndex--;
                            }
                        }
                    }
                } else {
                    int totalScoreSum = 0;
                    for (theItem = packItems->nextItem; theItem != NULL; theItem = theItem->nextItem) {
                        if (!(theItem->flags & (ITEM_EQUIPPED))) {
                            totalScoreSum += rateItemStealDesirability(attacker, theItem);
                        }
                    }
                    long choiceRoll = rand_range(1, totalScoreSum); // totalScoreSum >= 1 (itemCandidates > 0)
                    int runningSum = 0;
                    for (theItem = packItems->nextItem; theItem != NULL; theItem = theItem->nextItem) {
                        if (!(theItem->flags & (ITEM_EQUIPPED))) {
                            runningSum += rateItemStealDesirability(attacker, theItem);
                            if (runningSum >= choiceRoll) {
                                break;
                            }
                        }
                    }
                }
                if (theItem) {
                    if (theItem->category & WEAPON) { // Monkeys will steal half of a stack of weapons, and one of any other stack.
                        if (theItem->quantity > 3) {
                            stolenQuantity = (theItem->quantity + 1) / 2;
                        } else {
                            stolenQuantity = theItem->quantity;
                        }
                    } else {
                        stolenQuantity = 1;
                    }
                    if (stolenQuantity < theItem->quantity) { // Peel off stolen item(s).
                        itemFromTopOfStack = generateItem(ALL_ITEMS, -1);
                        *itemFromTopOfStack = *theItem; // Clone the item.
                        theItem->quantity -= stolenQuantity;
                        itemFromTopOfStack->quantity = stolenQuantity;
                        theItem = itemFromTopOfStack; // Redirect pointer.
                    } else {
                        if (rogue.swappedIn == theItem || rogue.swappedOut == theItem) {
                            rogue.swappedIn = NULL;
                            rogue.swappedOut = NULL;
                        }
                        removeItemFromChain(theItem, packItems);
                    }
                    theItem->flags &= ~ITEM_PLAYER_AVOIDS; // Explore will seek the item out if it ends up on the floor again.
                    attacker->carriedItem = theItem;
                    attacker->creatureMode = MODE_PERM_FLEEING;
                    attacker->creatureState = MONSTER_FLEEING;
                    monsterName(buf2, attacker, true);
                    itemName(theItem, buf3, false, true, NULL);
                    sprintf(buf, "%s stole %s!", buf2, buf3);
                    messageWithColor(buf, &badMessageColor, 0);
                    rogue.autoPlayingLevel = false;
                }
            }
        }
    }
    if ((attacker->info.abilityFlags & MA_POISONS)
        && damage > 0
        && !(defender->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE))) {

        addPoison(defender, damage, 1);
    }
    if ((attacker->info.abilityFlags & MA_CAUSES_WEAKNESS)
        && damage > 0
        && !(defender->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE))) {

        weaken(defender, gameConst->onHitWeakenDuration);
    }
    if (attacker->info.abilityFlags & MA_ATTACKS_STAGGER
        && !(defender == &player && playerHasImmovableAnchor())) { // purified Anchor: can't be knocked back
        processStaggerHit(attacker, defender);
    }
}

static boolean forceWeaponHit(creature *defender, item *theItem) {
    short forceDamage;
    char buf[DCOLS*3], buf2[COLS], monstName[DCOLS];
    creature *otherMonster = NULL;
    boolean knowFirstMonsterDied = false, autoID = false;
    bolt theBolt;

    monsterName(monstName, defender, true);

    pos oldLoc = defender->loc;
    pos newLoc = (pos){
        .x = defender->loc.x + clamp(defender->loc.x - player.loc.x, -1, 1),
        .y = defender->loc.y + clamp(defender->loc.y - player.loc.y, -1, 1)
    };
    if (canDirectlySeeMonster(defender)
        && !cellHasTerrainFlag(newLoc, T_OBSTRUCTS_PASSABILITY | T_OBSTRUCTS_VISION)
        && !(pmapAt(newLoc)->flags & (HAS_MONSTER | HAS_PLAYER))) {
        sprintf(buf, "you launch %s backward with the force of your blow", monstName);
        buf[DCOLS] = '\0';
        combatMessage(buf, messageColorFromVictim(defender));
        autoID = true;
    }
    theBolt = boltCatalog[BOLT_BLINKING];
    theBolt.magnitude = max(1, netEnchant(theItem) / FP_FACTOR);
    zap(oldLoc, newLoc, &theBolt, false, false);
    if (!(defender->bookkeepingFlags & MB_IS_DYING)
        && distanceBetween(oldLoc, defender->loc) > 0
        && distanceBetween(oldLoc, defender->loc) < weaponForceDistance(netEnchant(theItem))) {

        if (pmap[defender->loc.x + newLoc.x - oldLoc.x][defender->loc.y + newLoc.y - oldLoc.y].flags & (HAS_MONSTER | HAS_PLAYER)) {
            otherMonster = monsterAtLoc((pos){ defender->loc.x + newLoc.x - oldLoc.x, defender->loc.y + newLoc.y - oldLoc.y });
            monsterName(buf2, otherMonster, true);
        } else {
            otherMonster = NULL;
            strcpy(buf2, tileCatalog[pmap[defender->loc.x + newLoc.x - oldLoc.x][defender->loc.y + newLoc.y - oldLoc.y].layers[highestPriorityLayer(defender->loc.x + newLoc.x - oldLoc.x, defender->loc.y + newLoc.y - oldLoc.y, true)]].description);
        }

        forceDamage = distanceBetween(oldLoc, defender->loc);

        if (!(defender->info.flags & (MONST_IMMUNE_TO_WEAPONS | MONST_INVULNERABLE))
            && inflictDamage(NULL, defender, forceDamage, &white, false)) {

            if (canDirectlySeeMonster(defender)) {
                knowFirstMonsterDied = true;
                sprintf(buf, "%s %s on impact with %s",
                        monstName,
                        (defender->info.flags & MONST_INANIMATE) ? "is destroyed" : "dies",
                        buf2);
                buf[DCOLS] = '\0';
                combatMessage(buf, messageColorFromVictim(defender));
                autoID = true;
            }
            killCreature(defender, false);
        } else {
            if (canDirectlySeeMonster(defender)) {
                sprintf(buf, "%s slams against %s",
                        monstName,
                        buf2);
                buf[DCOLS] = '\0';
                combatMessage(buf, messageColorFromVictim(defender));
                autoID = true;
            }
        }
        moralAttack(&player, defender);
        splitMonster(defender, &player);

        if (otherMonster
            && !(otherMonster->info.flags & (MONST_IMMUNE_TO_WEAPONS | MONST_INVULNERABLE))) {

            if (inflictDamage(NULL, otherMonster, forceDamage, &white, false)) {
                if (canDirectlySeeMonster(otherMonster)) {
                    sprintf(buf, "%s %s%s when %s slams into $HIMHER",
                            buf2,
                            (knowFirstMonsterDied ? "also " : ""),
                            (otherMonster->info.flags & MONST_INANIMATE) ? "is destroyed" : "dies",
                            monstName);
                    resolvePronounEscapes(buf, otherMonster);
                    buf[DCOLS] = '\0';
                    combatMessage(buf, messageColorFromVictim(otherMonster));
                    autoID = true;
                }
                killCreature(otherMonster, false);
            }
            if (otherMonster->creatureState != MONSTER_ALLY) {
                // Allies won't defect if you throw another monster at them, even though it hurts.
                moralAttack(&player, otherMonster);
                splitMonster(otherMonster, &player);
            }
        }
    }
    return autoID;
}

// iOS port (iBrogue): a shoved frozen block slides a distance set by the shover's effective strength
// (clamped to this range), and a creature it slams into takes bonus damage for strength above the starting 12.
#define FROST_PUSH_MIN_DISTANCE 2
#define FROST_PUSH_MAX_DISTANCE 10

// iOS port (Brogue SE): an explosion's concussive force flings every (animate, mobile) creature caught in
// it. Distance is a flat blast force; a creature slammed into a wall/another creature takes this bonus on
// top of the travel distance. The blast's own fire/explosive damage is separate.
#define EXPLOSION_KNOCKBACK_DISTANCE 4
#define EXPLOSION_KNOCKBACK_SLAM_BONUS 3

// iOS port (Brogue SE): the cosmetic slide for a force-shoved creature. Instead of the victim popping
// straight to its rest cell, its own glyph (frozen tint and all) skates cell-by-cell along the shove
// path -- the same "launched creature" read as the force weapon's blink and a thrown item's arc. Purely
// visual: it consumes no RNG and changes no game state (shoveCreatureAlong still does the real relocation
// via setMonsterLocation once the slide finishes), so seeded runs and save-replay are untouched. Bails
// out when the player can't see the slide or during fast-forward playback. Shared by the frost block-push
// and (when enabled) the explosion knockback -- see the force-shove primitive below.
static void animateForceShove(creature *victim, pos fromLoc, const pos *path, short pathLen) {
    enum displayGlyph slideChar, cellChar;
    color slideFore, slideBack, cellFore, cellBack;
    const unsigned long creatureFlag = (victim == &player ? HAS_PLAYER : HAS_MONSTER);
    boolean fastForward = false;

    if (pathLen <= 0 || rogue.playbackFastForward) {
        return;
    }

    // Snapshot the victim's rendered appearance at its starting cell (keeps any frozen tint) -- this is
    // the glyph that slides. Then hide the victim at its origin so the moving glyph reads as the creature
    // itself, not a duplicate; setMonsterLocation re-adds the flag at the destination once the slide ends.
    getCellAppearance(fromLoc, &slideChar, &slideFore, &slideBack);
    pmapAt(fromLoc)->flags &= ~creatureFlag;
    refreshDungeonCell(fromLoc);

    for (short i = 0; i < pathLen; i++) {
        const pos step = path[i];
        if (playerCanSee(step.x, step.y)) {
            getCellAppearance(step, &cellChar, &cellFore, &cellBack); // for the cell's own background
            plotCharWithColor(slideChar, mapToWindow(step), &slideFore, &cellBack);
            if (!fastForward) {
                fastForward = rogue.playbackFastForward || pauseAnimation(16, PAUSE_BEHAVIOR_DEFAULT);
            }
            refreshDungeonCell(step); // wipe this frame so only the single moving glyph is ever shown
        }
    }
}

// iOS port (Brogue SE): the shared "force shove" primitive behind BOTH the frost block-push and the
// explosion knockback (the reusable force effect). Slides `victim` along the unit vector (dx,dy) up to
// maxDist tiles, coming to rest ON the first hazard (lava/chasm/deep water -- it then meets its fate via
// the destination's tile effects) or BEFORE a wall, another creature, or the map edge. Relocation goes
// through setMonsterLocation, so it is correct for the player and monsters alike (creature flag, vision,
// item pickup, and destination tile effects), preceded by a cosmetic slide animation along the same path.
// If stopped by a creature, that creature is returned via *slamTargetOut so the caller can apply impact
// damage. Returns the number of tiles actually travelled.
static short shoveCreatureAlong(creature *victim, short dx, short dy, short maxDist, creature **slamTargetOut) {
    const pos oldLoc = victim->loc;
    pos cur = oldLoc;
    creature *slamTarget = NULL;
    pos path[FROST_PUSH_MAX_DISTANCE]; // slide cells captured for animateForceShove; maxDist never exceeds this
    short pathLen = 0;

    for (short step = 0; step < maxDist; step++) {
        const pos next = (pos){ cur.x + dx, cur.y + dy };
        if (!coordinatesAreInMap(next.x, next.y)
            || cellHasTerrainFlag(next, T_OBSTRUCTS_PASSABILITY)
            || diagonalBlocked(cur.x, cur.y, next.x, next.y, false)) {
            break; // wall or map edge: come to rest on the current cell
        }
        if (pmapAt(next)->flags & (HAS_MONSTER | HAS_PLAYER)) {
            slamTarget = monsterAtLoc(next); // stop here and slam into whatever is in the way
            break;
        }
        cur = next; // slide onto the next cell
        if (pathLen < FROST_PUSH_MAX_DISTANCE) {
            path[pathLen++] = cur; // record the traversed cell so the slide can be animated below
        }
        if (cellHasTerrainFlag(cur, (T_LAVA_INSTA_DEATH | T_AUTO_DESCENT | T_IS_DEEP_WATER))) {
            break; // deposited onto the hazard; it meets its fate via the destination's tile effects
        }
    }

    const short dist = distanceBetween(oldLoc, cur);
    if (dist > 0) {
        animateForceShove(victim, oldLoc, path, pathLen); // cosmetic slide; the real relocation follows
        setMonsterLocation(victim, cur); // handles player/monster flags, vision, item pickup, tile effects
    }
    if (slamTargetOut) {
        *slamTargetOut = slamTarget;
    }
    return dist;
}

// iOS port (Brogue SE): apply a shove's momentum damage to whatever the shoved creature slammed into (the
// shoved creature itself is unharmed). `pusher` is credited for morale/aggravation (NULL = the environment,
// e.g. an explosion -- no morale attribution). `douse` extinguishes a burning slam target (the icy frost
// block). Shared by the frost push and the explosion knockback.
static void applyShoveImpact(creature *victim, creature *slamTarget, short forceDamage,
                             creature *pusher, boolean douse) {
    char buf[DCOLS*3], buf2[COLS];

    if (!slamTarget
        || (victim->bookkeepingFlags & MB_IS_DYING)
        || (slamTarget->info.flags & (MONST_IMMUNE_TO_WEAPONS | MONST_INVULNERABLE))) {
        return;
    }
    monsterName(buf2, slamTarget, true);
    if (douse && slamTarget->status[STATUS_BURNING]) {
        extinguishFireOnCreature(slamTarget);
    }
    if (inflictDamage(NULL, slamTarget, forceDamage, &lightBlue, false)) {
        if (canDirectlySeeMonster(slamTarget)) {
            sprintf(buf, "%s %s the impact.",
                    buf2,
                    (slamTarget->info.flags & MONST_INANIMATE) ? "is shattered by" : "is crushed by");
            buf[DCOLS] = '\0';
            combatMessage(buf, messageColorFromVictim(slamTarget));
        }
        killCreature(slamTarget, false);
    }
    if (pusher && slamTarget->creatureState != MONSTER_ALLY) {
        moralAttack(pusher, slamTarget);
        splitMonster(slamTarget, pusher);
    }
}

// iOS port (Brogue SE): explosion knockback. Flings `monst` away from the blast. A gas-cascade explosion
// (methane) has no single origin -- each cell detonates independently -- so direction comes from the LOCAL
// gradient: push away from the centroid of nearby fire/blast cells. (cx,cy) is the creature's own cell.
// Reuses the shared shove primitives; the blast's fire/explosive damage is applied separately by the caller.
boolean knockCreatureFromExplosion(creature *monst, short cx, short cy) {
#if !SE_EXPLOSION_KNOCKBACK
    // iOS port (Brogue SE): explosion knockback is gated OFF for the 0.11.0 "B is for Balance" release
    // (see SE_EXPLOSION_KNOCKBACK in Rogue.h). No-op so the Time.c call sites fall through to the normal
    // tile effects -- the blast still burns/damages as before, it just doesn't fling anything. The body
    // below is retained intact so a future release can flip the switch back on without a revert.
    (void)monst; (void)cx; (void)cy;
    return false;
#else
    short sumX = 0, sumY = 0, count = 0;
    const short radius = 3;

    // Things that can't be flung: inanimate/immobile/invulnerable, captives, and the already-dying.
    if ((monst->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE | MONST_IMMOBILE))
        || (monst->bookkeepingFlags & (MB_CAPTIVE | MB_IS_DYING))) {
        return false;
    }

    for (short i = -radius; i <= radius; i++) {
        for (short j = -radius; j <= radius; j++) {
            const short nx = cx + i, ny = cy + j;
            if ((i == 0 && j == 0) || !coordinatesAreInMap(nx, ny)) {
                continue;
            }
            if (cellHasTerrainFlag((pos){ nx, ny }, (T_CAUSES_EXPLOSIVE_DAMAGE | T_IS_FIRE))) {
                sumX += i;
                sumY += j;
                count++;
            }
        }
    }
    if (count == 0) {
        return false;
    }

    // Push opposite the blast mass; the sign collapses the gradient to one of eight unit directions.
    // A creature dead-centre in a symmetric blast (net-zero gradient) isn't flung -- deterministic, no RNG.
    const short dx = (sumX > 0) ? -1 : (sumX < 0) ? 1 : 0;
    const short dy = (sumY > 0) ? -1 : (sumY < 0) ? 1 : 0;
    if (dx == 0 && dy == 0) {
        return false;
    }

    creature *slamTarget = NULL;
    const short dist = shoveCreatureAlong(monst, dx, dy, EXPLOSION_KNOCKBACK_DISTANCE, &slamTarget);
    applyShoveImpact(monst, slamTarget, dist + EXPLOSION_KNOCKBACK_SLAM_BONUS, NULL /*environment*/, false /*no douse*/);
    return (dist > 0); // true only if the creature was actually relocated
#endif // SE_EXPLOSION_KNOCKBACK
}

// iOS port (iBrogue): staff of frost. Bumping a frozen creature shoves it like a statue. It slides across open
// floor -- a distance set by the shover's effective strength (`clamp(str - 8, 2, 10)`) -- then comes to rest
// the moment it reaches a hazard (lava / a chasm / deep water -- it is deposited ONTO the hazard, to die, fall,
// or flounder) or runs out of room before a wall, another creature, or the map edge. The frozen block itself
// takes NO damage; a creature it slams into takes momentum damage (the distance the block travelled) plus a
// strength shove-bonus (`max(0, str - 12)`, so it bites even on an adjacent slam for a strong shover), and,
// being struck by ice, is doused if it was on fire. (dx,dy) is the one-tile push direction (away from the
// shover); the caller guarantees the first cell is open or a hazard (a wedged block is rejected before here).
void pushFrozenCreature(creature *defender, short dx, short dy) {
    char buf[DCOLS*3], monstName[DCOLS];
    creature *slamTarget = NULL;

    monsterName(monstName, defender, false);

    const short effectiveStrength = rogue.strength - player.weaknessAmount;
    const short maxPush = clamp(effectiveStrength - 8, FROST_PUSH_MIN_DISTANCE, FROST_PUSH_MAX_DISTANCE);
    const short strengthBonus = max(0, effectiveStrength - 12);

    if (canDirectlySeeMonster(defender)) {
        sprintf(buf, "you send the frozen %s skidding away", monstName);
        buf[DCOLS] = '\0';
        combatMessage(buf, messageColorFromVictim(defender));
    }

    // Slide via the shared force-shove primitive, then deal the icy slam's momentum + strength shove-force
    // (the frozen block itself is unharmed; a creature it slams into is doused if it was burning).
    const short dist = shoveCreatureAlong(defender, dx, dy, maxPush, &slamTarget);
    applyShoveImpact(defender, slamTarget, dist + strengthBonus, &player, true /*douse*/);
}

void magicWeaponHit(creature *defender, item *theItem, boolean backstabbed) {
    char buf[DCOLS*3], monstName[DCOLS], theItemName[DCOLS];

    const color *effectColors[NUMBER_WEAPON_RUNIC_KINDS] = {&white, &black,
        &yellow, &pink, &green, &confusionGasColor, NULL, NULL, &darkRed, &rainbow, &white};
    //  W_SPEED, W_QUIETUS, W_PARALYSIS, W_MULTIPLICITY, W_SLOWING, W_CONFUSION, W_FORCE, W_SLAYING, W_DELIRIUM, W_RECKLESSNESS, W_CLUMSINESS
    short chance, i;
    fixpt enchant;
    enum weaponEnchants enchantType = theItem->enchant2;
    creature *newMonst;
    boolean autoID = false;

    // If the defender is already dead, proceed only if the runic is speed or multiplicity.
    // (Everything else acts on the victim, which would literally be overkill.)
    if ((defender->bookkeepingFlags & MB_IS_DYING)
        && theItem->enchant2 != W_SPEED
        && theItem->enchant2 != W_MULTIPLICITY) {
        return;
    }

    enchant = netEnchant(theItem);

    if (theItem->enchant2 == W_SLAYING) {
        chance = (monsterIsInClass(defender, theItem->vorpalEnemy) ? 100 : 0);
    } else if (defender->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE)) {
        chance = 0;
    } else {
        chance = runicWeaponChance(theItem, false, 0);
        if (backstabbed && chance < 100) {
            chance = min(chance * 2, (chance + 100) / 2);
        }
    }
    if (chance > 0 && rand_percent(chance)) {
        if (!(defender->bookkeepingFlags & MB_SUBMERGED)) {
            switch (enchantType) {
                case W_SPEED:
                    createFlare(player.loc.x, player.loc.y, SCROLL_ENCHANTMENT_LIGHT);
                    break;
                case W_QUIETUS:
                case W_CLUMSINESS: // iOS port (Brogue SE): a decapitation deserves the quietus flare
                    createFlare(defender->loc.x, defender->loc.y, QUIETUS_FLARE_LIGHT);
                    break;
                case W_SLAYING:
                    createFlare(defender->loc.x, defender->loc.y, SLAYING_FLARE_LIGHT);
                    break;
                default:
                    flashMonster(defender, effectColors[enchantType], 100);
                    break;
            }
            autoID = true;
        }
        rogue.disturbed = true;
        monsterName(monstName, defender, true);
        itemName(theItem, theItemName, false, false, NULL);

        switch (enchantType) {
            case W_SPEED:
                if (player.ticksUntilTurn != -1) {
                    sprintf(buf, "your %s trembles and time freezes for a moment", theItemName);
                    buf[DCOLS] = '\0';
                    combatMessage(buf, 0);
                    player.ticksUntilTurn = -1; // free turn!
                    autoID = true;
                }
                break;
            case W_SLAYING:
            case W_QUIETUS:
                inflictLethalDamage(&player, defender);
                sprintf(buf, "%s suddenly %s",
                        monstName,
                        (defender->info.flags & MONST_INANIMATE) ? "shatters" : "dies");
                buf[DCOLS] = '\0';
                combatMessage(buf, messageColorFromVictim(defender));
                killCreature(defender, false);
                autoID = true;
                break;
            case W_PARALYSIS:
                defender->status[STATUS_PARALYZED] = max(defender->status[STATUS_PARALYZED], weaponParalysisDuration(enchant));
                defender->maxStatus[STATUS_PARALYZED] = defender->status[STATUS_PARALYZED];
                if (canDirectlySeeMonster(defender)) {
                    sprintf(buf, "%s is frozen in place", monstName);
                    buf[DCOLS] = '\0';
                    combatMessage(buf, messageColorFromVictim(defender));
                    autoID = true;
                }
                break;
            case W_MULTIPLICITY:
                sprintf(buf, "Your %s emits a flash of light, and %sspectral duplicate%s appear%s!",
                        theItemName,
                        (weaponImageCount(enchant) == 1 ? "a " : ""),
                        (weaponImageCount(enchant) == 1 ? "" : "s"),
                        (weaponImageCount(enchant) == 1 ? "s" : ""));
                buf[DCOLS] = '\0';

                for (i = 0; i < (weaponImageCount(enchant)); i++) {
                    newMonst = generateMonster(MK_SPECTRAL_IMAGE, true, false);
                    newMonst->loc = getQualifyingPathLocNear(defender->loc, true,
                                             T_DIVIDES_LEVEL & avoidedFlagsForMonster(&(newMonst->info)), HAS_PLAYER,
                                             avoidedFlagsForMonster(&(newMonst->info)), (HAS_PLAYER | HAS_MONSTER | HAS_STAIRS), false);
                    newMonst->bookkeepingFlags |= (MB_FOLLOWER | MB_BOUND_TO_LEADER | MB_DOES_NOT_TRACK_LEADER | MB_TELEPATHICALLY_REVEALED);
                    newMonst->bookkeepingFlags &= ~MB_JUST_SUMMONED;
                    newMonst->leader = &player;
                    newMonst->creatureState = MONSTER_ALLY;
                    if (theItem->flags & ITEM_ATTACKS_STAGGER) {
                        newMonst->info.attackSpeed *= 2;
                        newMonst->info.abilityFlags |= MA_ATTACKS_STAGGER;
                    }
                    if (theItem->flags & ITEM_ATTACKS_QUICKLY) {
                        newMonst->info.attackSpeed /= 2;
                    }
                    if (theItem->flags & ITEM_ATTACKS_PENETRATE) {
                        newMonst->info.abilityFlags |= MA_ATTACKS_PENETRATE;
                    }
                    if (theItem->flags & ITEM_ATTACKS_ALL_ADJACENT) {
                        newMonst->info.abilityFlags |= MA_ATTACKS_ALL_ADJACENT;
                    }
                    if (theItem->flags & ITEM_ATTACKS_EXTEND) {
                        newMonst->info.abilityFlags |= MA_ATTACKS_EXTEND;
                    }
                    newMonst->ticksUntilTurn = 100;
                    newMonst->info.accuracy = player.info.accuracy + (5 * netEnchant(theItem) / FP_FACTOR);
                    newMonst->info.damage = player.info.damage;
                    newMonst->status[STATUS_LIFESPAN_REMAINING] = newMonst->maxStatus[STATUS_LIFESPAN_REMAINING] = weaponImageDuration(enchant);
                    if (strLenWithoutEscapes(theItemName) <= 8) {
                        sprintf(newMonst->info.monsterName, "spectral %s", theItemName);
                    } else {
                        switch (rogue.weapon->kind) {
                            case BROADSWORD:
                                strcpy(newMonst->info.monsterName, "spectral sword");
                                break;
                            case HAMMER:
                                strcpy(newMonst->info.monsterName, "spectral hammer");
                                break;
                            case PIKE:
                                strcpy(newMonst->info.monsterName, "spectral pike");
                                break;
                            case WAR_AXE:
                                strcpy(newMonst->info.monsterName, "spectral axe");
                                break;
                            default:
                                strcpy(newMonst->info.monsterName, "spectral weapon");
                                break;
                        }
                    }
                    pmapAt(newMonst->loc)->flags |= HAS_MONSTER;
                    fadeInMonster(newMonst);
                }
                updateVision(true);

                message(buf, 0);
                autoID = true;
                break;
            case W_SLOWING:
                slow(defender, weaponSlowDuration(enchant));
                if (canDirectlySeeMonster(defender)) {
                    sprintf(buf, "%s slows down", monstName);
                    buf[DCOLS] = '\0';
                    combatMessage(buf, messageColorFromVictim(defender));
                    autoID = true;
                }
                break;
            case W_CONFUSION:
                defender->status[STATUS_CONFUSED] = max(defender->status[STATUS_CONFUSED], weaponConfusionDuration(enchant));
                defender->maxStatus[STATUS_CONFUSED] = defender->status[STATUS_CONFUSED];
                if (canDirectlySeeMonster(defender)) {
                    sprintf(buf, "%s looks very confused", monstName);
                    buf[DCOLS] = '\0';
                    combatMessage(buf, messageColorFromVictim(defender));
                    autoID = true;
                }
                break;
            case W_FORCE:
                autoID = forceWeaponHit(defender, theItem);
                break;
            // iOS port (Brogue SE): cursed-runics rework, Phase 1.
            case W_DELIRIUM:
                if (runicCurseActive(theItem)) {
                    // cursed: the venom -- drive the foe into delirium (confusion)
                    defender->status[STATUS_CONFUSED] = max(defender->status[STATUS_CONFUSED], weaponConfusionDuration(enchant));
                    defender->maxStatus[STATUS_CONFUSED] = max(defender->maxStatus[STATUS_CONFUSED], defender->status[STATUS_CONFUSED]);
                    if (canDirectlySeeMonster(defender)) {
                        sprintf(buf, "%s reels in a sudden delirium", monstName);
                        buf[DCOLS] = '\0';
                        combatMessage(buf, messageColorFromVictim(defender));
                    }
                } else {
                    // purified: the mastered blade saps its victim's vigor
                    weaken(defender, gameConst->onHitWeakenDuration);
                    if (canDirectlySeeMonster(defender)) {
                        sprintf(buf, "%s sags as its vigor drains away", monstName);
                        buf[DCOLS] = '\0';
                        combatMessage(buf, messageColorFromVictim(defender));
                    }
                }
                autoID = true;
                break;
            case W_RECKLESSNESS:
                // passive: damage dealt/taken handled in attack()/inflictDamage; nothing on-hit.
                break;
            case W_CLUMSINESS:
                // cursed clumsiness: a wild, lucky swing decapitates. (Purified -> W_QUIETUS is the clean form.)
                inflictLethalDamage(&player, defender);
                sprintf(buf, "a wild, lucky swing %s %s",
                        (defender->info.flags & MONST_INANIMATE) ? "shatters" : "decapitates",
                        monstName);
                buf[DCOLS] = '\0';
                combatMessage(buf, messageColorFromVictim(defender));
                killCreature(defender, false);
                autoID = true;
                break;
            default:
                break;
        }
    }
    if (autoID) {
        autoIdentify(theItem);
    }
}

static void attackVerb(char returnString[DCOLS], creature *attacker, short hitPercentile) {
    short verbCount, increment;

    if (attacker != &player && (player.status[STATUS_HALLUCINATING] || !canSeeMonster(attacker))) {
        strcpy(returnString, "hits");
        return;
    }

    if (attacker == &player && !rogue.weapon) {
        strcpy(returnString, "punch");
        return;
    }

    for (verbCount = 0; verbCount < 4 && monsterText[attacker->info.monsterID].attack[verbCount + 1][0] != '\0'; verbCount++);
    increment = (100 / (verbCount + 1));
    hitPercentile = max(0, min(hitPercentile, increment * (verbCount + 1) - 1));
    strcpy(returnString, monsterText[attacker->info.monsterID].attack[hitPercentile / increment]);
    resolvePronounEscapes(returnString, attacker);
}

void applyArmorRunicEffect(char returnString[DCOLS], creature *attacker, short *damage, boolean melee) {
    char armorName[DCOLS], attackerName[DCOLS], monstName[DCOLS], buf[DCOLS * 3];
    boolean runicKnown;
    boolean runicDiscovered;
    short newDamage, dir, newX, newY, count, i;
    fixpt enchant;
    creature *monst, *hitList[8];

    returnString[0] = '\0';

    if (!(rogue.armor && rogue.armor->flags & ITEM_RUNIC)) {
        return; // just in case
    }

    enchant = netEnchant(rogue.armor);

    runicKnown = rogue.armor->flags & ITEM_RUNIC_IDENTIFIED;
    runicDiscovered = false;

    itemName(rogue.armor, armorName, false, false, NULL);

    monsterName(attackerName, attacker, true);

    switch (rogue.armor->enchant2) {
        case A_MULTIPLICITY:
            if (melee && !(attacker->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE)) && rand_percent(33)) {
                for (i = 0; i < armorImageCount(enchant); i++) {
                    monst = cloneMonster(attacker, false, true);
                    monst->bookkeepingFlags |= (MB_FOLLOWER | MB_BOUND_TO_LEADER | MB_DOES_NOT_TRACK_LEADER | MB_TELEPATHICALLY_REVEALED);
                    monst->info.flags |= MONST_DIES_IF_NEGATED;
                    monst->bookkeepingFlags &= ~(MB_JUST_SUMMONED | MB_SEIZED | MB_SEIZING);
                    monst->info.abilityFlags &= ~(MA_CAST_SUMMON | MA_DF_ON_DEATH); // No summoning by spectral images. Gotta draw the line!
                                                                                    // Also no exploding or infecting by spectral clones.
                    monst->leader = &player;
                    monst->creatureState = MONSTER_ALLY;
                    monst->status[STATUS_DISCORDANT] = 0; // Otherwise things can get out of control...
                    monst->ticksUntilTurn = 100;
                    monst->info.monsterID = MK_SPECTRAL_IMAGE;
                    if (monst->carriedMonster) {
                        creature *carried = monst->carriedMonster;
                        monst->carriedMonster = NULL;
                        killCreature(carried, true); // Otherwise you can get infinite phoenices from a discordant phoenix.
                    }

                    // Give it the glowy red light and color.
                    monst->info.intrinsicLightType = SPECTRAL_IMAGE_LIGHT;
                    monst->info.foreColor = &spectralImageColor;

                    // Temporary guest!
                    monst->status[STATUS_LIFESPAN_REMAINING] = monst->maxStatus[STATUS_LIFESPAN_REMAINING] = 3;
                    monst->currentHP = monst->info.maxHP = 1;
                    monst->info.defense = 0;

                    if (strLenWithoutEscapes(attacker->info.monsterName) <= 6) {
                        sprintf(monst->info.monsterName, "spectral %s", attacker->info.monsterName);
                    } else {
                        strcpy(monst->info.monsterName, "spectral clone");
                    }
                    fadeInMonster(monst);
                }
                updateVision(true);

                runicDiscovered = true;
                sprintf(returnString, "Your %s flashes, and spectral images of %s appear!", armorName, attackerName);
            }
            break;
        case A_MUTUALITY:
            if (*damage > 0) {
                count = 0;
                for (i=0; i<8; i++) {
                    hitList[i] = NULL;
                    dir = i % 8;
                    newX = player.loc.x + nbDirs[dir][0];
                    newY = player.loc.y + nbDirs[dir][1];
                    if (coordinatesAreInMap(newX, newY) && (pmap[newX][newY].flags & HAS_MONSTER)) {
                        monst = monsterAtLoc((pos){ newX, newY });
                        if (monst
                            && monst != attacker
                            && monstersAreEnemies(&player, monst)
                            && !(monst->info.flags & (MONST_IMMUNE_TO_WEAPONS | MONST_INVULNERABLE))
                            && !(monst->bookkeepingFlags & MB_IS_DYING)) {

                            hitList[i] = monst;
                            count++;
                        }
                    }
                }
                if (count) {
                    for (i=0; i<8; i++) {
                        if (hitList[i] && !(hitList[i]->bookkeepingFlags & MB_IS_DYING)) {
                            monsterName(monstName, hitList[i], true);
                            if (inflictDamage(&player, hitList[i], (*damage + count) / (count + 1), &blue, true)) {
                                if (canSeeMonster(hitList[i])) {
                                    sprintf(buf, "%s %s", monstName, ((hitList[i]->info.flags & MONST_INANIMATE) ? "is destroyed" : "dies"));
                                    combatMessage(buf, messageColorFromVictim(hitList[i]));
                                }
                                killCreature(hitList[i], false);
                            }
                        }
                    }
                    runicDiscovered = true;
                    if (!runicKnown) {
                        sprintf(returnString, "Your %s pulses, and the damage is shared with %s!",
                                armorName,
                                (count == 1 ? monstName : "the other adjacent enemies"));
                    }
                    *damage = (*damage + count) / (count + 1);
                }
            }
            break;
        case A_ABSORPTION:
            *damage -= rand_range(1, armorAbsorptionMax(enchant));
            if (*damage <= 0) {
                *damage = 0;
                runicDiscovered = true;
                if (!runicKnown) {
                    sprintf(returnString, "your %s pulses and absorbs the blow!", armorName);
                }
            }
            break;
        case A_REPRISAL:
            if (melee && !(attacker->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE))) {
                newDamage = max(1, armorReprisalPercent(enchant) * (*damage) / 100); // 5% reprisal per armor level
                if (inflictDamage(&player, attacker, newDamage, &blue, true)) {
                    if (canSeeMonster(attacker)) {
                        sprintf(returnString, "your %s pulses and %s drops dead!", armorName, attackerName);
                        runicDiscovered = true;
                    }
                    killCreature(attacker, false);
                } else if (!runicKnown) {
                    if (canSeeMonster(attacker)) {
                        sprintf(returnString, "your %s pulses and %s shudders in pain!", armorName, attackerName);
                        runicDiscovered = true;
                    }
                }
            }
            break;
        case A_IMMUNITY:
            if (monsterIsInClass(attacker, rogue.armor->vorpalEnemy)) {
                *damage = 0;
                runicDiscovered = true;
            }
            break;
        // iOS port (Brogue SE): cursed-runics rework. A_ANCHOR (defense + slow), A_SMOKY (concealing
        // smoke) and A_ACROPHOBIA (chasm-fear) are passive/contextual runics applied at equip / per
        // turn / on movement -- none of them react on-hit, so there are no cases here.
        default:
            break;
    }

    if (runicDiscovered && !runicKnown) {
        autoIdentify(rogue.armor);
    }
}

static void decrementWeaponAutoIDTimer() {
    char buf[COLS*3], buf2[COLS*3];

    if (rogue.weapon
        && !(rogue.weapon->flags & ITEM_IDENTIFIED)
        && !--rogue.weapon->charges) {

        rogue.weapon->flags |= ITEM_IDENTIFIED;
        updateIdentifiableItems();
        messageWithColor("you are now familiar enough with your weapon to identify it.", &itemMessageColor, 0);
        itemName(rogue.weapon, buf2, true, true, NULL);
        sprintf(buf, "%s %s.", (rogue.weapon->quantity > 1 ? "they are" : "it is"), buf2);
        messageWithColor(buf, &itemMessageColor, 0);
        createFlare(player.loc.x, player.loc.y, IDENTIFY_FLARE_LIGHT); // iOS port (Brogue SE): gold "now familiar" flare
    }
}

void processStaggerHit(creature *attacker, creature *defender) {
    if ((defender->info.flags & (MONST_INVULNERABLE | MONST_IMMOBILE | MONST_INANIMATE))
        || (defender->bookkeepingFlags & MB_CAPTIVE)
        || cellHasTerrainFlag(defender->loc, T_OBSTRUCTS_PASSABILITY)) {

        return;
    }
    short newX = clamp(defender->loc.x - attacker->loc.x, -1, 1) + defender->loc.x;
    short newY = clamp(defender->loc.y - attacker->loc.y, -1, 1) + defender->loc.y;
    if (coordinatesAreInMap(newX, newY)
        && !cellHasTerrainFlag((pos){ newX, newY }, T_OBSTRUCTS_PASSABILITY)
        && !(pmap[newX][newY].flags & (HAS_MONSTER | HAS_PLAYER))) {

        setMonsterLocation(defender, (pos){ newX, newY });
    }
}

// iOS port (Brogue SE): noise system -- how loud a PLAYER melee swing is. A per-weapon mass/finesse
// tier (the spike passed to playerEmitNoise, stacked on playerNoiseLevel()'s armor/terrain/ring base)
// plus a miss penalty: a clean connect is a muffled thud, a whiff rings out ("accuracy = stealth",
// mirroring itemImpactLoudness's BODY-vs-WALL surface tiers for throws). Pure function of weapon KIND
// (enchant/runic irrelevant) -> RNG-silent and save-safe. Tier values + the miss penalty are the
// tuning levers in Rogue.h (NOISE_MELEE_*). See docs/design/noise-system.md "Phase 2".
static short weaponMeleeLoudness(const item *weapon, boolean connected) {
    short loudness;
    if (weapon == NULL) {
        loudness = NOISE_MELEE_LIGHT;            // bare fists/claws -- quiet
    } else {
        switch (weapon->kind) {
            case DAGGER:
            case RAPIER:
            case WHIP:
                loudness = NOISE_MELEE_LIGHT;     // finesse / light blades -- the assassin's tier
                break;
            case SWORD:
            case AXE:
            case SPEAR:
                loudness = NOISE_MELEE_NORMAL;    // ordinary one-handers
                break;
            case HAMMER:
                loudness = NOISE_MELEE_BOOMING;   // war hammer -- wakes the floor
                break;
            default:
                loudness = NOISE_MELEE_HEAVY;     // broadsword/flail/mace/war axe/war pike -- two-handed heft
                break;
        }
    }
    if (!connected) {
        loudness += NOISE_MELEE_MISS_PENALTY;     // a whiff/clang betrays you
    }
    return loudness;
}

// returns whether the attack hit
boolean attack(creature *attacker, creature *defender, boolean lungeAttack) {
    short damage, specialDamage, poisonDamage;
    char buf[COLS*2], buf2[COLS*2], attackerName[COLS], defenderName[COLS], verb[DCOLS], explicationClause[DCOLS] = "", armorRunicString[DCOLS*3];
    boolean sneakAttack, defenderWasAsleep, defenderWasParalyzed, degradesAttackerWeapon, sightUnseen;

    // Check paladin feat before creatureState is changed
    if (attacker == &player && !(defender->info.flags & MONST_IMMUNE_TO_WEAPONS)) {
        handlePaladinFeat(defender);
    }

    if (attacker == &player && rogue.weapon && rogue.featRecord[FEAT_PURE_MAGE] && canSeeMonster(defender)) {
        rogue.featRecord[FEAT_PURE_MAGE] = false;
    }

    if (attacker->info.abilityFlags & MA_KAMIKAZE) {
        killCreature(attacker, false);
        return true;
    }

    armorRunicString[0] = '\0';

    poisonDamage = 0;

    degradesAttackerWeapon = (defender->info.flags & MONST_DEFEND_DEGRADE_WEAPON ? true : false);

    sightUnseen = !canSeeMonster(attacker) && !canSeeMonster(defender);

    if (defender->status[STATUS_LEVITATING] && (attacker->info.flags & MONST_RESTRICTED_TO_LIQUID)) {
        return false; // aquatic or other liquid-bound monsters cannot attack flying opponents
    }

    if ((attacker == &player || defender == &player) && !rogue.blockCombatText) {
        rogue.disturbed = true;
    }

    defender->status[STATUS_ENTRANCED] = 0;
    if (defender->status[STATUS_MAGICAL_FEAR]) {
        defender->status[STATUS_MAGICAL_FEAR] = 1;
    }

    if (attacker != &player && defender == &player && attacker->creatureState == MONSTER_WANDERING) {
        attacker->creatureState = MONSTER_TRACKING_SCENT;
    }

    if (defender->info.flags & MONST_INANIMATE) {
        sneakAttack = false;
        defenderWasAsleep = false;
        defenderWasParalyzed = false;
    } else {
        sneakAttack = (defender != &player && attacker == &player && (defender->creatureState == MONSTER_WANDERING) ? true : false);
        defenderWasAsleep = (defender != &player && (defender->creatureState == MONSTER_SLEEPING) ? true : false);
        defenderWasParalyzed = defender->status[STATUS_PARALYZED] > 0 || defender->status[STATUS_FROZEN] > 0; // iOS port (iBrogue): frozen counts as helpless for backstab
    }

    monsterName(attackerName, attacker, true);
    monsterName(defenderName, defender, true);

    if ((attacker->info.abilityFlags & MA_SEIZES)
        && (!(attacker->bookkeepingFlags & MB_SEIZING) || !(defender->bookkeepingFlags & MB_SEIZED))
        && (distanceBetween(attacker->loc, defender->loc) == 1
            && !diagonalBlocked(attacker->loc.x, attacker->loc.y, defender->loc.x, defender->loc.y, false))
        && !(defender == &player && playerHasImmovableAnchor())) { // purified Anchor: can't be seized/held

        attacker->bookkeepingFlags |= MB_SEIZING;
        defender->bookkeepingFlags |= MB_SEIZED;

        // if the player is seized by a submerged monster they can see (i.e. player is also submerged), 
        // it immediately surfaces so it can be targeted with staffs/wands
        if (defender == &player && (attacker->bookkeepingFlags & MB_SUBMERGED) && canSeeMonster(attacker)) {            
            attacker->bookkeepingFlags &= ~MB_SUBMERGED;
            monsterName(attackerName, attacker, true);
        }

        if (canSeeMonster(attacker) || canSeeMonster(defender)) {
            sprintf(buf, "%s seizes %s!", attackerName, (defender == &player ? "your legs" : defenderName));
            messageWithColor(buf, &white, 0);
        }
        return false;
    }

    if (sightUnseen) {
        // iOS port (Brogue SE): noise system -- off-screen combat the player can only "hear" (the
        // "you hear combat in the distance" / "...die in combat" messages) gets a cosmetic sound ripple
        // so the player can locate the fight. Fires on EVERY off-screen exchange (hit, miss, or kill),
        // unlike the once-per-turn message throttle, and radiates from the MONSTER -- not the ally/player
        // landing the blow (the ally is the listener's "side"; the enemy is what we're locating). Cosmetic
        // and RNG-silent; same-cell merge keeps repeated swings from stacking. See docs/design/noise-system.md.
        creature *noiseSource = (attacker == &player || attacker->creatureState == MONSTER_ALLY) ? defender : attacker;
        cosmeticSpawnRippleMonster(noiseSource->loc);
    }

    // iOS port (Brogue SE): cursed-runics rework -- Clumsiness (unpurified) fumble: a chance to trip on
    // your own swing (auto-miss + self-stun), lessened by strength above the weapon's requirement. A
    // purified clumsiness blade (now W_QUIETUS) never fumbles.
    boolean clumsyFumble = false;
    if (attacker == &player && rogue.weapon && (rogue.weapon->flags & ITEM_RUNIC)
        && rogue.weapon->enchant2 == W_CLUMSINESS && runicCurseActive(rogue.weapon)) {
        short fumbleChance = CLUMSINESS_FUMBLE_PCT
            - max(0, (rogue.strength - player.weaknessAmount) - rogue.weapon->strengthRequired) * CLUMSINESS_FUMBLE_STR_RELIEF;
        clumsyFumble = (fumbleChance > 0 && rand_percent(fumbleChance));
    }

    boolean attackLanded = !clumsyFumble
        && (sneakAttack || defenderWasAsleep || defenderWasParalyzed || lungeAttack || attackHit(attacker, defender));

    if (attacker == &player) {
        // iOS port (Brogue SE): noise system -- emit the player's melee loudness AFTER the hit/miss roll
        // (not at the top of the function as before), so a clean connect is a muffled per-weapon thud
        // while a whiff adds NOISE_MELEE_MISS_PENALTY and rings out. Auto-hits (sneak/asleep/paralyzed/
        // lunge) count as connected -> stay quiet, rewarding the assassin path. See weaponMeleeLoudness().
        playerEmitNoise(weaponMeleeLoudness(rogue.weapon, attackLanded));
    }

    if (attackLanded) {
        // If the attack hit:
        damage = (defender->info.flags & (MONST_IMMUNE_TO_WEAPONS | MONST_INVULNERABLE)
                  ? 0 : randClump(attacker->info.damage) * monsterDamageAdjustmentAmount(attacker) / FP_FACTOR);

        // Per-hit damage scale (100 = no-op): the flail pass-attack balance nerf sets this to 50 around
        // its hits (Movement.c); the sim build also uses it to model pike penetrate/reach. Player only.
        if (attacker == &player && gWeaponDamageScalePct != 100) {
            damage = damage * gWeaponDamageScalePct / 100;
        }

        // iOS port (Brogue SE): cursed-runics rework -- Recklessness: +damage dealt (always on, even
        // purified). Its downside (+damage taken) lives in inflictDamage, gated on the curse being active.
        if (attacker == &player && rogue.weapon && (rogue.weapon->flags & ITEM_RUNIC)
            && rogue.weapon->enchant2 == W_RECKLESSNESS) {
            short recklessPct = RECKLESSNESS_DAMAGE_DEALT_BASE
                + max(0, (short)(netEnchant(rogue.weapon) / FP_FACTOR)) * RECKLESSNESS_DAMAGE_DEALT_PER_ENCHANT;
            damage = damage * (100 + recklessPct) / 100;
            autoIdentify(rogue.weapon); // reveal on the first connecting attack
        }

        if (sneakAttack || defenderWasAsleep || defenderWasParalyzed) {
            if (defender != &player) {
                // The non-player defender doesn't hit back this turn because it's still flat-footed.
                defender->ticksUntilTurn += max(defender->movementSpeed, defender->attackSpeed);
                if (defender->creatureState != MONSTER_ALLY) {
                    defender->creatureState = MONSTER_TRACKING_SCENT; // Wake up!
                }
            }
        }
        if (sneakAttack || defenderWasAsleep || defenderWasParalyzed || lungeAttack) {
            if (attacker == &player
                && rogue.weapon
                && (rogue.weapon->flags & ITEM_SNEAK_ATTACK_BONUS)) {

                damage *= 5; // 5x damage for dagger sneak attacks.
            } else {
                damage *= 3; // Triple damage for general sneak attacks.
            }
        }

        if (defender == &player && rogue.armor && (rogue.armor->flags & ITEM_RUNIC)) {
            applyArmorRunicEffect(armorRunicString, attacker, &damage, true);
        }

        if (attacker == &player
            && rogue.reaping
            && !(defender->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE))) {

            specialDamage = min(damage, defender->currentHP) * rogue.reaping; // Maximum reaped damage can't exceed the victim's remaining health.
            if (rogue.reaping > 0) {
                specialDamage = rand_range(0, specialDamage);
            } else {
                specialDamage = rand_range(specialDamage, 0);
            }
            if (specialDamage) {
                rechargeItemsIncrementally(specialDamage);
            }
        }

        if (damage == 0) {
            sprintf(explicationClause, " but %s no damage", (attacker == &player ? "do" : "does"));
            if (attacker == &player) {
                rogue.disturbed = true;
            }
        } else if (lungeAttack) {
            strcpy(explicationClause, " with a vicious lunge attack");
        } else if (defenderWasParalyzed) {
            sprintf(explicationClause, " while $HESHE %s paralyzed", (defender == &player ? "are" : "is"));
        } else if (defenderWasAsleep) {
            strcpy(explicationClause, " in $HISHER sleep");
        } else if (sneakAttack) {
            strcpy(explicationClause, ", catching $HIMHER unaware");
        } else if (defender->status[STATUS_STUCK] || defender->bookkeepingFlags & MB_CAPTIVE) {
            sprintf(explicationClause, " while %s dangle%s helplessly",
                    (canSeeMonster(defender) ? "$HESHE" : "it"),
                    (defender == &player ? "" : "s"));
        }
        resolvePronounEscapes(explicationClause, defender);

        if ((attacker->info.abilityFlags & MA_POISONS) && damage > 0) {
            poisonDamage = damage;
            damage = 1;
        }

        if (inflictDamage(attacker, defender, damage, &red, false)) { // if the attack killed the defender
            if (defenderWasAsleep || sneakAttack || defenderWasParalyzed || lungeAttack) {
                sprintf(buf, "%s %s %s%s", attackerName,
                        ((defender->info.flags & MONST_INANIMATE) ? "destroyed" : "dispatched"),
                        defenderName,
                        explicationClause);
            } else {
                sprintf(buf, "%s %s %s%s",
                        attackerName,
                        ((defender->info.flags & MONST_INANIMATE) ? "destroyed" : "defeated"),
                        defenderName,
                        explicationClause);
            }
            if (sightUnseen) {
                if (defender->info.flags & MONST_INANIMATE) {
                    combatMessage("you hear something get destroyed in combat", 0);
                } else {
                    combatMessage("you hear something die in combat", 0);
                }
            } else {
                combatMessage(buf, (damage > 0 ? messageColorFromVictim(defender) : &white));
            }
            killCreature(defender, false);
            if (&player == defender) {
                gameOver(attacker->info.monsterName, false);
                return true;
            } else if (&player == attacker
                       && defender->info.monsterID == MK_DRAGON) {

                rogue.featRecord[FEAT_DRAGONSLAYER] = true;
            }
        } else { // if the defender survived
            // iOS port (Brogue SE): noise system -- the survive-hit "you hear combat in the distance" tell
            // was upstream dead code. Its `if (sightUnseen)` sat inside an outer
            // `(canSeeMonster(attacker) || canSeeMonster(defender))` guard -- the logical negation of
            // `sightUnseen` -- so an off-screen NON-FATAL hit produced no message at all (only misses and
            // kills were audible). Branch on `sightUnseen` first, as the miss/kill sites already do, so an
            // unseen landed blow is heard; the visible verb message keeps its own visibility guard (where it
            // belongs). See docs/design/noise-system.md.
            if (!rogue.blockCombatText) {
                if (sightUnseen) {
                    if (!rogue.heardCombatThisTurn) {
                        rogue.heardCombatThisTurn = true;
                        combatMessage("you hear combat in the distance", 0);
                    }
                } else if (canSeeMonster(attacker) || canSeeMonster(defender)) {
                    attackVerb(verb, attacker, max(damage - (attacker->info.damage.lowerBound * monsterDamageAdjustmentAmount(attacker) / FP_FACTOR), 0) * 100
                               / max(1, (attacker->info.damage.upperBound - attacker->info.damage.lowerBound) * monsterDamageAdjustmentAmount(attacker) / FP_FACTOR));
                    sprintf(buf, "%s %s %s%s", attackerName, verb, defenderName, explicationClause);
                    combatMessage(buf, messageColorFromVictim(defender));
                }
            }
            if (attacker == &player && rogue.weapon && (rogue.weapon->flags & ITEM_ATTACKS_STAGGER)) {
                processStaggerHit(attacker, defender);
            }
            if (attacker->info.abilityFlags & SPECIAL_HIT) {
                specialHit(attacker, defender, (attacker->info.abilityFlags & MA_POISONS) ? poisonDamage : damage);
            }
            if (armorRunicString[0]) {
                message(armorRunicString, 0);
            }
        }

        moralAttack(attacker, defender);
        
        if (attacker == &player && rogue.weapon && (rogue.weapon->flags & ITEM_RUNIC)) {
            magicWeaponHit(defender, rogue.weapon, sneakAttack || defenderWasAsleep || defenderWasParalyzed);
        }

        splitMonster(defender, attacker);

        if (attacker == &player
            && (defender->bookkeepingFlags & MB_IS_DYING)
            && (defender->bookkeepingFlags & MB_WEAPON_AUTO_ID)) {

            decrementWeaponAutoIDTimer();
        }

        if (degradesAttackerWeapon
            && attacker == &player
            && rogue.weapon
            && !(rogue.weapon->flags & ITEM_PROTECTED)
                // Can't damage a Weapon of Acid Mound Slaying by attacking an acid mound... just ain't right!
            && !((rogue.weapon->flags & ITEM_RUNIC) && rogue.weapon->enchant2 == W_SLAYING && monsterIsInClass(defender, rogue.weapon->vorpalEnemy))
            && rogue.weapon->enchant1 >= -10) {

            rogue.weapon->enchant1--;
            if (rogue.weapon->quiverNumber) {
                rogue.weapon->quiverNumber = rand_range(1, 60000);
            }
            equipItem(rogue.weapon, true, NULL);
            itemName(rogue.weapon, buf2, false, false, NULL);
            sprintf(buf, "your %s weakens!", buf2);
            messageWithColor(buf, &itemMessageColor, 0);
            checkForDisenchantment(rogue.weapon);
        }

        return true;
    } else if (clumsyFumble) { // iOS port (Brogue SE): cursed-runics rework -- the clumsiness fumble
        player.status[STATUS_PARALYZED] = max(player.status[STATUS_PARALYZED], CLUMSINESS_FUMBLE_STUN_TURNS);
        player.maxStatus[STATUS_PARALYZED] = max(player.maxStatus[STATUS_PARALYZED], player.status[STATUS_PARALYZED]);
        message("you stumble over your own strike and reel, momentarily helpless!", 0);
        autoIdentify(rogue.weapon);
        rogue.disturbed = true;
        return false;
    } else { // if the attack missed
        if (!rogue.blockCombatText) {
            if (sightUnseen) {
                if (!rogue.heardCombatThisTurn) {
                    rogue.heardCombatThisTurn = true;
                    combatMessage("you hear combat in the distance", 0);
                }
            } else {
                sprintf(buf, "%s missed %s", attackerName, defenderName);
                combatMessage(buf, 0);
            }
        }
        return false;
    }
}

// Gets the length of a string without the four-character color escape sequences, since those aren't displayed.
short strLenWithoutEscapes(const char *str) {
    short i, count;

    count = 0;
    for (i=0; str[i];) {
        if (str[i] == COLOR_ESCAPE) {
            i += 4;
            continue;
        }
        count++;
        i++;
    }
    return count;
}

// Buffer messages generated by combat until flushed by displayCombatText().
// Messages in the buffer are delimited by newlines.
void combatMessage(char *theMsg, const color *theColor) {
    short length;
    char newMsg[COLS * 2 - 1]; // -1 for the newline when appending later

    if (theColor == 0) {
        theColor = &white;
    }

    newMsg[0] = '\0';
    encodeMessageColor(newMsg, 0, theColor);
    length = strlen(newMsg);
    strncat(&newMsg[length], theMsg, (COLS * 2 - 1) - length - 1);

    length = strlen(combatText);

    // Buffer combat messages here just for timing; otherwise player combat
    // messages appear after monsters, rather than before.  The -2 is for the
    // newline and terminator.
    if (length + strlen(newMsg) > COLS * 2 - 2) {
        displayCombatText();
    }

    if (combatText[0]) {
        snprintf(&combatText[length], COLS * 2 - length, "\n%s", newMsg);
    } else {
        strcpy(combatText, newMsg);
    }
}

// Flush any buffered, newline-delimited combat messages, passing each to
// message().  These messages are "foldable", meaning that if space permits
// they may be joined together by semi-colons.  Notice that combat messages may
// be flushed by a number of different callers.  One is message() itself
// creating a recursion, which this function is responsible for terminating.
void displayCombatText() {
    char buf[COLS * 2];
    char *start, *end;

    // message itself will call displayCombatText.  For this guard to terminate
    // the recursion, we need to copy combatText out and empty it before
    // calling message.
    if (combatText[0] == '\0') {
        return;
    }

    strcpy(buf, combatText);
    combatText[0] = '\0';

    start = buf;
    for (end = start; *end != '\0'; end++) {
        if (*end == '\n') {
            *end = '\0';
            message(start, FOLDABLE | (rogue.cautiousMode ? REQUIRE_ACKNOWLEDGMENT : 0));
            start = end + 1;
        }
    }

    message(start, FOLDABLE | (rogue.cautiousMode ? REQUIRE_ACKNOWLEDGMENT : 0));

    rogue.cautiousMode = false;
}

void flashMonster(creature *monst, const color *theColor, short strength) {
    if (!theColor) {
        return;
    }
    if (!(monst->bookkeepingFlags & MB_WILL_FLASH) || monst->flashStrength < strength) {
        monst->bookkeepingFlags |= MB_WILL_FLASH;
        monst->flashStrength = strength;
        monst->flashColor = *theColor;
        rogue.creaturesWillFlashThisTurn = true;
    }
}

static boolean canAbsorb(creature *ally, boolean ourBolts[], creature *prey, short **grid) {
    short i;

    if (ally->creatureState == MONSTER_ALLY
        && ally->newPowerCount > 0
        && (!isPosInMap(ally->targetCorpseLoc))
        && !((ally->info.flags | prey->info.flags) & (MONST_INANIMATE | MONST_IMMOBILE))
        && !monsterAvoids(ally, prey->loc)
        && grid[ally->loc.x][ally->loc.y] <= 10) {

        if (~(ally->info.abilityFlags) & prey->info.abilityFlags & LEARNABLE_ABILITIES) {
            return true;
        } else if (~(ally->info.flags) & prey->info.flags & LEARNABLE_BEHAVIORS) {
            return true;
        } else {
            for (i = 0; i < gameConst->numberBoltKinds; i++) {
                ourBolts[i] = false;
            }
            for (i = 0; ally->info.bolts[i] != BOLT_NONE; i++) {
                ourBolts[ally->info.bolts[i]] = true;
            }

            for (i=0; prey->info.bolts[i] != BOLT_NONE; i++) {
                if (!(boltCatalog[prey->info.bolts[i]].flags & BF_NOT_LEARNABLE)
                    && !ourBolts[prey->info.bolts[i]]) {

                    return true;
                }
            }
        }
    }
    return false;
}

static boolean anyoneWantABite(creature *decedent) {
    short candidates, randIndex, i;
    short **grid;
    boolean success = false;
    boolean *ourBolts;

    ourBolts = (boolean *)calloc(gameConst->numberBoltKinds, sizeof(boolean));

    candidates = 0;
    if ((!(decedent->info.abilityFlags & LEARNABLE_ABILITIES)
         && !(decedent->info.flags & LEARNABLE_BEHAVIORS)
         && decedent->info.bolts[0] == BOLT_NONE)
        || (cellHasTerrainFlag(decedent->loc, T_OBSTRUCTS_PASSABILITY))
        || decedent->info.monsterID == MK_SPECTRAL_IMAGE
        || (decedent->info.flags & (MONST_INANIMATE | MONST_IMMOBILE))) {

        return false;
    }

    grid = allocGrid();
    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
        creature *ally = nextCreature(&it);
        if (ally->creatureState == MONSTER_ALLY) {
            fillGrid(grid, 0);
            calculateDistances(grid, decedent->loc.x, decedent->loc.y, forbiddenFlagsForMonster(&(ally->info)), NULL, true, true);
        }
        if (canAbsorb(ally, ourBolts, decedent, grid)) {
            candidates++;
        }
    }
    if (candidates > 0) {
        randIndex = rand_range(1, candidates);
        creature *firstAlly = NULL;
        for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
            creature *ally = nextCreature(&it);
            // CanAbsorb() populates ourBolts if it returns true and there are no learnable behaviors or flags:
            if (canAbsorb(ally, ourBolts, decedent, grid) && !--randIndex) {
                firstAlly = ally;
                break;
            }
        }
        if (firstAlly) {
            firstAlly->targetCorpseLoc = decedent->loc;
            strcpy(firstAlly->targetCorpseName, decedent->info.monsterName);
            firstAlly->corpseAbsorptionCounter = 20; // 20 turns to get there and start eating before he loses interest

            // Choose a superpower.
            // First, select from among learnable ability or behavior flags, if one is available.
            candidates = 0;
            for (i=0; i<32; i++) {
                if (Fl(i) & ~(firstAlly->info.abilityFlags) & decedent->info.abilityFlags & LEARNABLE_ABILITIES) {
                    candidates++;
                }
            }
            for (i=0; i<32; i++) {
                if (Fl(i) & ~(firstAlly->info.flags) & decedent->info.flags & LEARNABLE_BEHAVIORS) {
                    candidates++;
                }
            }
            if (candidates > 0) {
                randIndex = rand_range(1, candidates);
                for (i=0; i<32; i++) {
                    if ((Fl(i) & ~(firstAlly->info.abilityFlags) & decedent->info.abilityFlags & LEARNABLE_ABILITIES)
                        && !--randIndex) {

                        firstAlly->absorptionFlags = Fl(i);
                        firstAlly->absorbBehavior = false;
                        success = true;
                        break;
                    }
                }
                for (i=0; i<32 && !success; i++) {
                    if ((Fl(i) & ~(firstAlly->info.flags) & decedent->info.flags & LEARNABLE_BEHAVIORS)
                        && !--randIndex) {

                        firstAlly->absorptionFlags = Fl(i);
                        firstAlly->absorbBehavior = true;
                        success = true;
                        break;
                    }
                }
            } else if (decedent->info.bolts[0] != BOLT_NONE) {
                // If there are no learnable ability or behavior flags, pick a learnable bolt.
                candidates = 0;
                for (i=0; decedent->info.bolts[i] != BOLT_NONE; i++) {
                    if (!(boltCatalog[decedent->info.bolts[i]].flags & BF_NOT_LEARNABLE)
                        && !ourBolts[decedent->info.bolts[i]]) {

                        candidates++;
                    }
                }
                if (candidates > 0) {
                    randIndex = rand_range(1, candidates);
                    for (i=0; decedent->info.bolts[i] != BOLT_NONE; i++) {
                        if (!(boltCatalog[decedent->info.bolts[i]].flags & BF_NOT_LEARNABLE)
                            && !ourBolts[decedent->info.bolts[i]]
                            && !--randIndex) {

                            firstAlly->absorptionBolt = decedent->info.bolts[i];
                            success = true;
                            break;
                        }
                    }
                }
            }
        }
    }
    freeGrid(grid);
    free(ourBolts);
    return success;
}

#define MIN_FLASH_STRENGTH  50

void inflictLethalDamage(creature *attacker, creature *defender) {
    inflictDamage(attacker, defender, defender->currentHP, NULL, true);
}

// iOS port (Brogue SE): ring of transference -- affliction transfer. "Blood magic" cuts both ways: the
// same conduit that drains a victim's life into you also lets you bleed a fraction of your own harmful
// statuses INTO whatever you strike. Rate-limited by the ring's transference fraction (transference /
// playerTransferenceRatio -- the same 5%/level as the heal) so it's tempo-paced relief, NOT a one-hit
// cleanse: the affliction keeps ticking on you while you punch it off. Curated to the statuses that map
// cleanly onto a monster (poison, fire, slow, weakness, confusion). Positive ring only -- a cursed ring
// keeps its existing HP-drain downside and grants no relief. Deterministic (pure arithmetic on game
// state, no RNG), so save-replay safe.
static void transferAfflictionsToTarget(creature *defender) {
    short shed;

    if (rogue.transference <= 0
        || (defender->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE))) {
        return;
    }

    // Turns of an affliction shed per hit: its remaining duration scaled by the transference fraction,
    // floored at 1 (so any affliction makes some progress) and never more than the player still has.
    #define SHED_TURNS(dur) (min((dur), max(1, (dur) * rogue.transference / gameConst->playerTransferenceRatio)))

    // Poison -- relocate duration at the player's current concentration onto the target.
    if (player.status[STATUS_POISONED] > 0) {
        shed = SHED_TURNS(player.status[STATUS_POISONED]);
        addPoison(defender, shed, player.poisonAmount);
        player.status[STATUS_POISONED] -= shed;
        if (player.status[STATUS_POISONED] <= 0) {
            player.status[STATUS_POISONED] = 0;
            player.poisonAmount = 0;
        }
    }

    // Fire -- only takes hold on a target that can actually burn.
    if (player.status[STATUS_BURNING] > 0
        && !defender->status[STATUS_IMMUNE_TO_FIRE]
        && !(defender->info.flags & MONST_IMMUNE_TO_FIRE)) {
        shed = SHED_TURNS(player.status[STATUS_BURNING]);
        defender->status[STATUS_BURNING] = max(defender->status[STATUS_BURNING], shed);
        defender->maxStatus[STATUS_BURNING] = max(defender->maxStatus[STATUS_BURNING], defender->status[STATUS_BURNING]);
        player.status[STATUS_BURNING] -= shed;
        if (player.status[STATUS_BURNING] <= 0) {
            extinguishFireOnCreature(&player);
        }
    }

    // Slow.
    if (player.status[STATUS_SLOWED] > 0) {
        shed = SHED_TURNS(player.status[STATUS_SLOWED]);
        slow(defender, max(defender->status[STATUS_SLOWED], shed));
        player.status[STATUS_SLOWED] -= shed;
    }

    // Weakness -- bleed duration across (deepening the target's enervation by a point); working it fully
    // off restores the player's strength.
    if (player.status[STATUS_WEAKENED] > 0) {
        shed = SHED_TURNS(player.status[STATUS_WEAKENED]);
        weaken(defender, max(defender->status[STATUS_WEAKENED], shed));
        player.status[STATUS_WEAKENED] -= shed;
        if (player.status[STATUS_WEAKENED] <= 0) {
            player.status[STATUS_WEAKENED] = 0;
            player.weaknessAmount = 0;
            updateEncumbrance(); // recompute strength-derived stats now the toxin has drained
        }
    }

    // Confusion.
    if (player.status[STATUS_CONFUSED] > 0) {
        shed = SHED_TURNS(player.status[STATUS_CONFUSED]);
        defender->status[STATUS_CONFUSED] = max(defender->status[STATUS_CONFUSED], shed);
        defender->maxStatus[STATUS_CONFUSED] = max(defender->maxStatus[STATUS_CONFUSED], defender->status[STATUS_CONFUSED]);
        player.status[STATUS_CONFUSED] -= shed;
    }

    #undef SHED_TURNS
}

// returns true if this was a killing stroke; does NOT call killCreature
// flashColor indicates the color that the damage will cause the creature to flash
boolean inflictDamage(creature *attacker, creature *defender,
                      short damage, const color *flashColor, boolean ignoresProtectionShield) {
    dungeonFeature theBlood;
    short transferenceAmount;

    if (damage == 0
        || (defender->info.flags & MONST_INVULNERABLE)) {

        return false;
    }

    // iOS port (Brogue SE): cursed-runics rework -- Recklessness (unpurified) makes you reckless:
    // +damage taken, from all sources. Purifying it removes the vulnerability (keeps the +damage dealt).
    if (defender == &player && damage > 0 && rogue.weapon
        && (rogue.weapon->flags & ITEM_RUNIC) && rogue.weapon->enchant2 == W_RECKLESSNESS
        && runicCurseActive(rogue.weapon)) {
        damage = damage * (100 + RECKLESSNESS_DAMAGE_TAKEN_PCT) / 100;
    }

    if (!ignoresProtectionShield
        && defender->status[STATUS_SHIELDED]) {

        if (defender->status[STATUS_SHIELDED] > damage * 10) {
            defender->status[STATUS_SHIELDED] -= damage * 10;
            damage = 0;
        } else {
            damage -= (defender->status[STATUS_SHIELDED] + 9) / 10;
            defender->status[STATUS_SHIELDED] = defender->maxStatus[STATUS_SHIELDED] = 0;
        }
    }

    defender->bookkeepingFlags &= ~MB_ABSORBING; // Stop eating a corpse if you are getting hurt.

    // bleed all over the place, proportionately to damage inflicted:
    if (damage > 0 && defender->info.bloodType) {
        theBlood = dungeonFeatureCatalog[defender->info.bloodType];
        theBlood.startProbability = (theBlood.startProbability * (15 + min(damage, defender->currentHP) * 3 / 2) / 100);
        if (theBlood.layer == GAS) {
            theBlood.startProbability *= 100;
        }
        spawnDungeonFeature(defender->loc.x, defender->loc.y, &theBlood, true, false);
    }

    if (defender != &player && defender->creatureState == MONSTER_SLEEPING) {
        wakeUp(defender);
    }

    // iOS port (iBrogue): two reusable components react to taking damage. A wounded fleer (creature with a
    // fleeAI profile) commits to fleeing; a looter (creature with a loot profile) sheds loot -- gold per
    // discrete hit, or a one-time near-death bonus. Both are data-driven (no per-monster branch); the gold
    // goblin is the reference consumer of both. `damage` here is post-shield and not yet subtracted from HP.
    if (defender->info.fleeAI && damage > 0) {
        fleerNoteDamage(defender);
    }
    if (defender->info.loot && damage > 0) {
        monsterShedLootOnHit(defender, attacker, damage);
    }

    if (defender == &player
        && rogue.mode == GAME_MODE_EASY
        && damage > 0) {
        damage = max(1, damage/5);
    }

    if (((attacker == &player && rogue.transference) || (attacker && attacker != &player && (attacker->info.abilityFlags & MA_TRANSFERENCE)))
        && !(defender->info.flags & (MONST_INANIMATE | MONST_INVULNERABLE))) {

        transferenceAmount = min(damage, defender->currentHP); // Maximum transferred damage can't exceed the victim's remaining health.

        if (attacker == &player) {
            transferenceAmount = transferenceAmount * rogue.transference / gameConst->playerTransferenceRatio;
            if (transferenceAmount == 0) {
                transferenceAmount = ((rogue.transference > 0) ? 1 : -1);
            }
        } else if (attacker->creatureState == MONSTER_ALLY) {
            transferenceAmount = transferenceAmount * 4 / 10; // allies get 40% recovery rate
        } else {
            transferenceAmount = transferenceAmount * 9 / 10; // enemies get 90% recovery rate, deal with it
        }

        attacker->currentHP += transferenceAmount;

        if (attacker == &player && player.currentHP <= 0) {
            gameOver("Drained by a cursed ring", true);
            return false;
        }

        // iOS port (Brogue SE): same hit also bleeds a fraction of the player's own afflictions into
        // the victim (positive ring only; helper no-ops on a cursed ring or an inanimate target).
        if (attacker == &player) {
            transferAfflictionsToTarget(defender);
        }
    }

    // iOS port (iBrogue): haptic when the player actually loses HP (suppressed
    // during recording playback). Scaled by severity — fatal blow, a hit that
    // leaves the player under 40% health (the low-health flash threshold), or an
    // ordinary hit. The host honors its haptics setting.
    if (defender == &player && damage > 0 && !rogue.playbackMode) {
        int severity;
        if (defender->currentHP <= damage) {
            severity = 2; // fatal
        } else if ((defender->currentHP - damage) * 100 < defender->info.maxHP * 40) {
            severity = 1; // survives, but now under 40% health
        } else {
            severity = 0; // ordinary hit
        }
        cePlayerTookDamage(severity);
    }

    if (defender->currentHP <= damage) { // killed
        defender->currentHP = 0;
        return true;
    } else { // survived
        if (damage < 0 && defender->currentHP - damage > defender->info.maxHP) {
            defender->currentHP = max(defender->currentHP, defender->info.maxHP);
        } else {
            defender->currentHP -= damage; // inflict the damage!
        }

        if (defender != &player && defender->creatureState != MONSTER_ALLY
            && defender->info.flags & MONST_FLEES_NEAR_DEATH
            && defender->info.maxHP / 4 >= defender->currentHP) {

            defender->creatureState = MONSTER_FLEEING;
        }
        if (flashColor && damage > 0) {
            flashMonster(defender, flashColor, MIN_FLASH_STRENGTH + (100 - MIN_FLASH_STRENGTH) * damage / defender->info.maxHP);
        }
    }

    refreshSideBar(-1, -1, false);
    return false;
}

void addPoison(creature *monst, short durationIncrement, short concentrationIncrement) {
    extern const color poisonColor;
    if (durationIncrement > 0) {
        if (monst == &player && !player.status[STATUS_POISONED]) {
            combatMessage("scalding poison fills your veins", &badMessageColor);
        }
        if (!monst->status[STATUS_POISONED]) {
            monst->maxStatus[STATUS_POISONED] = 0;
        }
        monst->poisonAmount += concentrationIncrement;
        if (monst->poisonAmount == 0) {
            monst->poisonAmount = 1;
        }
        monst->status[STATUS_POISONED] += durationIncrement;
        monst->maxStatus[STATUS_POISONED] = monst->info.maxHP / monst->poisonAmount;

        if (canSeeMonster(monst)) {
            flashMonster(monst, &poisonColor, 100);
        }
    }
}


// Marks the decedent as dying, but does not remove it from the monster chain to avoid iterator invalidation;
// that is done in `removeDeadMonsters`.
// Use "administrativeDeath" if the monster is being deleted for administrative purposes, as opposed to dying as a result of physical actions.
// AdministrativeDeath means the monster simply disappears, with no messages, dropped item, DFs or other effect.
void killCreature(creature *decedent, boolean administrativeDeath) {
    short x, y;
    char monstName[DCOLS], buf[DCOLS * 3];

    if (decedent->bookkeepingFlags & (MB_IS_DYING | MB_HAS_DIED)) {
        // monster has already been killed; let's avoid overkill
        return;
    }

    if (decedent != &player) {
        decedent->bookkeepingFlags |= MB_IS_DYING;
    }

    if (rogue.lastTarget == decedent) {
        rogue.lastTarget = NULL;
    }
    if (rogue.yendorWarden == decedent) {
        rogue.yendorWarden = NULL;
    }

    if (decedent->carriedItem) {
        if (administrativeDeath) {
            deleteItem(decedent->carriedItem);
            decedent->carriedItem = NULL;
        } else {
            makeMonsterDropItem(decedent);
        }
    }

    // iOS port (iBrogue): a slain looter (creature with a loot profile) spills its death hoard (marquee item
    // + gold piles + thrown weapons). Only on a real death -- escaping via the stairs uses administrativeDeath
    // and forfeits everything -- and only for the genuine bearer, so clones and debug spawns drop nothing.
    if (!administrativeDeath
        && decedent->info.loot
        && decedent->looter.isBearer) {

        monsterDropDeathLoot(decedent);
    }

    if (!administrativeDeath && (decedent->info.abilityFlags & MA_DF_ON_DEATH)
        && !(decedent->bookkeepingFlags & MB_IS_FALLING)) {
        spawnDungeonFeature(decedent->loc.x, decedent->loc.y, &dungeonFeatureCatalog[decedent->info.DFType], true, false);

        if (monsterText[decedent->info.monsterID].DFMessage[0] && canSeeMonster(decedent)) {
            monsterName(monstName, decedent, true);
            snprintf(buf, DCOLS * 3, "%s %s", monstName, monsterText[decedent->info.monsterID].DFMessage);
            resolvePronounEscapes(buf, decedent);
            message(buf, 0);
        }
    }

    if (decedent == &player) { // the player died
        // game over handled elsewhere
    } else {
        if (!administrativeDeath
            && decedent->creatureState == MONSTER_ALLY
            && !canSeeMonster(decedent)
            && (!(decedent->info.flags & MONST_INANIMATE) 
                || (monsterCatalog[decedent->info.monsterID].abilityFlags & MA_ENTER_SUMMONS))
            && !(decedent->bookkeepingFlags & MB_BOUND_TO_LEADER)
            && !decedent->carriedMonster) {

            messageWithColor("you feel a sense of loss.", &badMessageColor, 0);
        }
        x = decedent->loc.x;
        y = decedent->loc.y;
        if (decedent->bookkeepingFlags & MB_IS_DORMANT) {
            pmap[x][y].flags &= ~HAS_DORMANT_MONSTER;
        } else {
            pmap[x][y].flags &= ~HAS_MONSTER;
        }

        // This must be done at the same time as removing the HAS_MONSTER flag, or game state might
        // end up inconsistent.
        decedent->bookkeepingFlags |= MB_HAS_DIED;
        if (administrativeDeath) {
            decedent->bookkeepingFlags |= MB_ADMINISTRATIVE_DEATH;
        }

        if (!administrativeDeath && !(decedent->bookkeepingFlags & MB_IS_DORMANT)) {
            // Was there another monster inside?
            if (decedent->carriedMonster) {
                // Insert it into the chain.
                creature *carriedMonster = decedent->carriedMonster;
                decedent->carriedMonster = NULL;
                prependCreature(monsters, carriedMonster);

                carriedMonster->loc.x = x;
                carriedMonster->loc.y = y;
                carriedMonster->ticksUntilTurn = 200;
                pmap[x][y].flags |= HAS_MONSTER;
                fadeInMonster(carriedMonster);

                if (canSeeMonster(carriedMonster)) {
                    monsterName(monstName, carriedMonster, true);
                    sprintf(buf, "%s appears", monstName);
                    combatMessage(buf, NULL);
                }

                applyInstantTileEffectsToCreature(carriedMonster);
            }
            anyoneWantABite(decedent);
            refreshDungeonCell((pos){ x, y });
        }
    }
    decedent->currentHP = 0;
    demoteMonsterFromLeadership(decedent);
    if (decedent->leader) {
        checkForContinuedLeadership(decedent->leader);
    }
}

void buildHitList(const creature **hitList, const creature *attacker, creature *defender, const boolean sweep) {
    short i, x, y, newX, newY, newestX, newestY;
    enum directions dir, newDir;

    x = attacker->loc.x;
    y = attacker->loc.y;
    newX = defender->loc.x;
    newY = defender->loc.y;

    dir = NO_DIRECTION;
    for (i = 0; i < DIRECTION_COUNT; i++) {
        if (nbDirs[i][0] == newX - x
            && nbDirs[i][1] == newY - y) {

            dir = i;
            break;
        }
    }

    if (sweep) {
        if (dir == NO_DIRECTION) {
            dir = UP; // Just pick one.
        }
        for (i=0; i<8; i++) {
            newDir = (dir + i) % DIRECTION_COUNT;
            newestX = x + cDirs[newDir][0];
            newestY = y + cDirs[newDir][1];
            if (coordinatesAreInMap(newestX, newestY) && (pmap[newestX][newestY].flags & (HAS_MONSTER | HAS_PLAYER))) {
                defender = monsterAtLoc((pos){ newestX, newestY });
                if (defender
                    && !defender->status[STATUS_FROZEN] // iOS port (Brogue SE): staff of frost -- an axe sweep skips a frozen creature; frozen creatures take no damage (they are pushed, not struck).
                    && monsterWillAttackTarget(attacker, defender)
                    && (!cellHasTerrainFlag(defender->loc, T_OBSTRUCTS_PASSABILITY) || (defender->info.flags & MONST_ATTACKABLE_THRU_WALLS))) {

                    hitList[i] = defender;
                }
            }
        }
    } else {
        hitList[0] = defender;
    }
}
