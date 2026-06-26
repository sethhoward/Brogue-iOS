// Fight simulator — encounter resolver (Phases 1-3).
//
// A custom tick loop over the REAL combat primitives (attack(), zap(), killCreature,
// recalculateEquipmentBonuses) on a hand-carved stub grid — NOT the engine's turn loop.
// Monsters approach straight toward the player (archetype choreography, not AI). One
// policy: zap-on-threat. See docs/design/fight-simulator.md §10-11.

#include "Rogue.h"
#include "GlobalsBase.h"
#include "Globals.h"
#include "balance.h"
#include "sim.h"
#include <stdlib.h>

#define TURN_TICKS  100
#define TICK_CAP   3000   // 30 game turns: ample for a chokepoint/cluster fight; bounds stalemates.
#define FS_BIG_HP  30000  // sentinel player HP (fits in short; >> any fight's damage) so the engine
                          // never sees HP<=0 and never triggers gameOver()

// Arena: an open room with the player near the west wall. Corridor archetype carves a
// 1-wide slice of it instead. Coordinates kept well inside DCOLS/DROWS.
#define ROOM_X0  6
#define ROOM_X1 30
#define ROOM_Y0  6
#define ROOM_Y1 24
#define PX       8          // player x
#define PY      15          // player y (room mid)

const char *fs_archetypeName(Archetype a) {
    switch (a) {
        case ARCH_CORRIDOR_LINE:  return "corridor_line";
        case ARCH_FRENZY_CLUSTER: return "frenzy_cluster";
        case ARCH_SCATTERED_PACK: return "scattered_pack";
        case ARCH_LONE_TANK:      return "lone_tank";
        case ARCH_AMBUSH_RANGE:   return "ambush_range";
        default:                  return "?";
    }
}

// --- grid -----------------------------------------------------------------

static void wallFill(void) {
    // initializeRogue doesn't gen a level, so pmap holds uninitialized flags. Wall-fill
    // the whole grid with cleared flags so DF/blood spread can't hit a stray HAS_MONSTER.
    for (short x = 0; x < DCOLS; x++)
        for (short y = 0; y < DROWS; y++) {
            pmap[x][y].layers[DUNGEON] = GRANITE;
            pmap[x][y].layers[LIQUID] = pmap[x][y].layers[SURFACE] = pmap[x][y].layers[GAS] = NOTHING;
            pmap[x][y].flags &= ~(HAS_MONSTER | HAS_PLAYER | HAS_ITEM);
        }
}

static void carveCell(short x, short y) {
    pmap[x][y].layers[DUNGEON] = FLOOR;
    // Deliberately NOT marking VISIBLE/IN_FIELD_OF_VIEW: combat damage is visibility-independent,
    // but zap()'s per-cell bolt lighting+display animation is gated on player visibility and is the
    // dominant per-zap cost. Leaving cells unseen skips the cosmetic animation entirely. (DISCOVERED
    // only, so terrain is "known" without triggering the visible-render path.)
    pmap[x][y].flags |= DISCOVERED;
}

static void carve(Archetype arch) {
    wallFill();
    if (arch == ARCH_CORRIDOR_LINE) {
        // 1-wide hall on row PY, from PX (back-wall behind player blocks knockback) east.
        for (short x = PX; x <= ROOM_X1; x++) carveCell(x, PY);
    } else {
        // open room; player's west cell (PX-1) stays wall so knockback can't relocate them.
        for (short x = PX; x <= ROOM_X1; x++)
            for (short y = ROOM_Y0; y <= ROOM_Y1; y++) carveCell(x, y);
    }
}

// --- loadout --------------------------------------------------------------

static item *makeWeapon(short kind, short e) {
    item *w = generateItem(WEAPON, kind);
    short req = w->strengthRequired;
    w->enchant1 = e; w->strengthRequired = (short)(req - e > 0 ? req - e : 0);
    w->flags |= ITEM_IDENTIFIED; w->flags &= ~ITEM_RUNIC;
    return w;
}
static item *makeArmor(short kind, short e) {
    item *a = generateItem(ARMOR, kind);
    short req = a->strengthRequired;
    a->enchant1 = e; a->strengthRequired = (short)(req - e > 0 ? req - e : 0);
    a->flags |= ITEM_IDENTIFIED; a->flags &= ~ITEM_RUNIC;
    return a;
}
static item *makeStaff(short kind, short e) {
    item *s = generateItem(STAFF, kind);
    s->enchant1 = e; s->charges = e; s->flags |= ITEM_IDENTIFIED;
    return s;
}
static item *makeRing(short kind, short e) {
    item *r = generateItem(RING, kind);
    r->enchant1 = e; r->flags |= ITEM_IDENTIFIED;
    return r;
}

// --- monster placement per archetype --------------------------------------

static creature *spawnAt(short kind, short x, short y) {
    creature *m = generateMonster(kind, false, false);
    m->loc = (pos){ x, y };
    m->creatureState = MONSTER_TRACKING_SCENT;
    m->ticksUntilTurn = 0;
    m->info.bloodType = 0; // suppress cosmetic blood spread (per-hit hot path)
    pmapAt(m->loc)->flags |= HAS_MONSTER;
    return m;
}

static void placeMonsters(Archetype arch, short kind, int n) {
    switch (arch) {
        case ARCH_CORRIDOR_LINE:
            for (int i = 0; i < n; i++) spawnAt(kind, PX + 4 + i, PY); // single file east
            break;
        case ARCH_FRENZY_CLUSTER: {
            // packed blob a few tiles east of the player
            short cx = PX + 4, cy = PY, placed = 0;
            for (short r = 0; r < 4 && placed < n; r++)
                for (short dx = -r; dx <= r && placed < n; dx++)
                    for (short dy = -r; dy <= r && placed < n; dy++) {
                        if (abs(dx) != r && abs(dy) != r) continue; // ring shell
                        short x = cx + dx, y = cy + dy;
                        if (x < PX+1 || x > ROOM_X1 || y < ROOM_Y0 || y > ROOM_Y1) continue;
                        if (pmapAt((pos){x,y})->flags & (HAS_MONSTER|HAS_PLAYER)) continue;
                        spawnAt(kind, x, y); placed++;
                    }
            break;
        }
        case ARCH_SCATTERED_PACK: {
            int placed = 0;
            for (short y = ROOM_Y0+1; y <= ROOM_Y1-1 && placed < n; y += 3)
                for (short x = PX+6; x <= ROOM_X1-1 && placed < n; x += 4) { spawnAt(kind, x, y); placed++; }
            break;
        }
        case ARCH_LONE_TANK:
            spawnAt(kind, PX + 6, PY); // single target (n ignored)
            break;
        case ARCH_AMBUSH_RANGE:
            for (int i = 0; i < n; i++) spawnAt(kind, ROOM_X1 - i, PY); // start at far wall
            break;
        default: break;
    }
}

// --- helpers --------------------------------------------------------------

static int aliveCount(void) {
    int n = 0;
    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) { nextCreature(&it); n++; }
    return n;
}
static creature *adjacentEnemy(void) {
    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
        creature *m = nextCreature(&it);
        if (distanceBetween(player.loc, m->loc) == 1) return m;
    }
    return NULL;
}
static int adjacentCount(void) {
    int n = 0;
    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
        creature *m = nextCreature(&it);
        if (distanceBetween(player.loc, m->loc) == 1) n++;
    }
    return n;
}
static void stepToward(creature *m) {
    short dx = (player.loc.x > m->loc.x) - (player.loc.x < m->loc.x);
    short dy = (player.loc.y > m->loc.y) - (player.loc.y < m->loc.y);
    pos next = { m->loc.x + dx, m->loc.y + dy };
    if (cellHasTerrainFlag(next, T_OBSTRUCTS_PASSABILITY)) {
        // try axis-only slides so it doesn't stick on a diagonal wall
        pos alt1 = { m->loc.x + dx, m->loc.y }, alt2 = { m->loc.x, m->loc.y + dy };
        if (dx && !cellHasTerrainFlag(alt1, T_OBSTRUCTS_PASSABILITY)) next = alt1;
        else if (dy && !cellHasTerrainFlag(alt2, T_OBSTRUCTS_PASSABILITY)) next = alt2;
        else return;
    }
    if (pmapAt(next)->flags & (HAS_MONSTER | HAS_PLAYER)) return;
    pmapAt(m->loc)->flags &= ~HAS_MONSTER;
    m->loc = next;
    pmapAt(next)->flags |= HAS_MONSTER;
}

// Per-turn status effects the mini-loop must process itself (the engine ticks these in the turn
// pipeline we don't run): burning (firebolt) and poison DoT, using the real inflictDamage with the
// engine's per-turn values. Returns 1 if the creature died (caller removes monsters; the player has
// sentinel HP so never dies here -> models firebolt self-immolation as HP-budget cost). Paralysis/
// entrancement (the SE lightning stun) is honored separately in the action loop.
static int processTurnEffects(creature *m) {
    int dead = 0;
    if (m->status[STATUS_BURNING] > 0 && !m->status[STATUS_IMMUNE_TO_FIRE]) {
        if (inflictDamage(NULL, m, rand_range(1, 3), &orange, true)) dead = 1; // rand_range(1,3)/turn
        if (m->status[STATUS_BURNING] > 0) m->status[STATUS_BURNING]--;
    }
    if (!dead && m->status[STATUS_POISONED] > 0) {
        m->status[STATUS_POISONED]--;
        if (inflictDamage(NULL, m, m->poisonAmount, &green, true)) dead = 1;  // poisonAmount/turn
        if (m->status[STATUS_POISONED] <= 0) m->poisonAmount = 0;
    }
    return dead;
}

// --- encounter ------------------------------------------------------------

EncounterResult fs_run(const BuildSpec *b, Archetype arch, int playerMaxHP,
                       short monsterKind, int numMonsters, uint64_t seed,
                       int startHP, int startCharges, int strength, int depth) {
    EncounterResult r = {0};

    static boolean inited = false;
    if (inited) freeEverything();
    initializeGameVariant();
    initializeRogue(seed);
    inited = true;
    if (strength > 0) rogue.strength = strength; // depth-derived strength (else initializeRogue's 12)

    // Depth-appropriate monster: pick a normal-spawn horde valid at this depth (frequency-weighted,
    // deterministic per seed) and use its bulk member (or leader). depth<=0 keeps monsterKind as given.
    short kind = monsterKind;
    if (depth > 0) {
        short hid = pickHordeType(depth, 0,
                                  HORDE_IS_SUMMONED | HORDE_LEADER_CAPTIVE | HORDE_MACHINE_ONLY, 0);
        if (hid >= 0) {
            const hordeType *h = &hordeCatalog[hid];
            kind = (h->numberOfMemberTypes > 0) ? h->memberType[0] : h->leaderType;
        }
    }

    // Give the engine player a huge sentinel HP so it NEVER sees HP<=0 -> gameOver() (which runs
    // save-recording / high-score / name-prompt machinery and was the dominant per-death cost). We track
    // damage against a virtual budget below and end the encounter ourselves. Combat math is unchanged.
    player.info.maxHP = player.currentHP = FS_BIG_HP;
    player.info.bloodType = 0;
    const int hpBudget = (startHP > 0 && startHP < playerMaxHP) ? startHP : playerMaxHP; // virtual HP pool

    carve(arch);
    player.loc = (pos){ PX, PY };
    pmapAt(player.loc)->flags |= HAS_PLAYER;
    player.ticksUntilTurn = 0;

    item *staff = NULL;
    rogue.weapon = rogue.armor = rogue.ringLeft = rogue.ringRight = NULL;
    if (b->weaponKind >= 0) rogue.weapon = makeWeapon(b->weaponKind, b->weaponEnchant);
    else                    rogue.weapon = makeWeapon(DAGGER, 0);
    if (b->armorKind >= 0)  rogue.armor  = makeArmor(b->armorKind, b->armorEnchant);
    if (b->ringKind >= 0) { rogue.ringLeft = makeRing(b->ringKind, b->ringEnchant); updateRingBonuses(); }
    if (b->staffKind >= 0) {
        staff = makeStaff(b->staffKind, b->staffEnchant);
        if (startCharges >= 0 && startCharges < staff->enchant1) staff->charges = startCharges; // carryover
    }
    recalculateEquipmentBonuses();

    placeMonsters(arch, kind, numMonsters);

    long clock = 0, lastProgress = 0;
    int prevMonHP = 0;
    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) prevMonHP += nextCreature(&it)->currentHP;

    while ((FS_BIG_HP - player.currentHP) < hpBudget && aliveCount() > 0 && clock < TICK_CAP) {
        // Stalemate guard: if the player hasn't dented the monsters in STALL turns (e.g. a dry staff
        // poking a tanky ogre with a backup dagger), it's effectively a loss — bail instead of grinding.
        if (clock - lastProgress > 1000) break;
        short minTicks = player.ticksUntilTurn;
        for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
            creature *m = nextCreature(&it);
            if (m->ticksUntilTurn < minTicks) minTicks = m->ticksUntilTurn;
        }
        if (minTicks > 0) {
            clock += minTicks;
            player.ticksUntilTurn -= minTicks;
            for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);)
                nextCreature(&it)->ticksUntilTurn -= minTicks;
        }

        // Per-turn DoTs on the monsters (snapshot first so killCreature can't break iteration).
        {
            creature *snap[64]; int ns = 0;
            for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it) && ns < 64;)
                snap[ns++] = nextCreature(&it);
            for (int i = 0; i < ns; i++)
                if (snap[i]->ticksUntilTurn <= 0 && processTurnEffects(snap[i]))
                    killCreature(snap[i], false);
        }
        if (player.ticksUntilTurn <= 0) processTurnEffects(&player); // firebolt self-burn, etc.

        // Player acts. Realistic hybrid policy: MELEE by default; zap only when it's clearly worth a
        // charge -- ie. enough enemies are within bolt-rake range that one bolt hits several. This both
        // models how a staff is actually used (situationally, not every turn) and avoids zap-spam.
        if (player.ticksUntilTurn <= 0 && player.currentHP > 0) {
            creature *adj = adjacentEnemy();
            int nearby = 0; creature *far = NULL; short bestD = -1, nearD = 9999; short toughestNear = 0;
            for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
                creature *m = nextCreature(&it);
                short d = distanceBetween(player.loc, m->loc);
                if (d <= 7) { nearby++; if (m->currentHP > toughestNear) toughestNear = m->currentHP; } // in bolt reach
                if (d > bestD) { bestD = d; far = m; }
                if (d < nearD) nearD = d;
            }
            // Firebolt-safe: don't fire when the nearest enemy is close enough that the incineration
            // bloom would wash back over the player (self-immolation). Lightning has no such risk
            // (safe down your own line), so this only gates fire staves.
            boolean fireSafe = !(staff && boltForItem(staff) == BOLT_FIRE) || nearD >= 4;
            // Worth a charge when: several enemies in reach (rake the group), OR a single tough target
            // in reach that would cost many melee rounds (the lone-dragon case). Don't waste it on a
            // lone weakling — melee that.
            boolean zapWorthIt = staff && staff->charges > 0 && fireSafe
                && (nearby >= 3 || (nearby >= 1 && toughestNear >= 30));
            short pcost = player.attackSpeed; // turn cost; zap/wait = normal, melee adjusts per weapon

            // Rapier lunge: no adjacent foe but an enemy is exactly 2 tiles away in a straight line with
            // the gap cell free -> close in and strike with a guaranteed crit (attack(..., lunge=true)).
            creature *lungeTgt = NULL; pos lungeStep = {0,0};
            if (rogue.weapon && (rogue.weapon->flags & ITEM_LUNGE_ATTACKS) && !adj && !zapWorthIt) {
                for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
                    creature *m = nextCreature(&it);
                    short dx = m->loc.x - player.loc.x, dy = m->loc.y - player.loc.y;
                    if ((dx==-2||dx==0||dx==2) && (dy==-2||dy==0||dy==2) && (dx||dy)) {
                        short ux = (dx>0)-(dx<0), uy = (dy>0)-(dy<0);
                        pos gap = { player.loc.x + ux, player.loc.y + uy };
                        if (!cellHasTerrainFlag(gap, T_OBSTRUCTS_PASSABILITY)
                            && !(pmapAt(gap)->flags & (HAS_MONSTER | HAS_PLAYER))) {
                            lungeTgt = m; lungeStep = gap; break;
                        }
                    }
                }
            }

            if (lungeTgt) {
                pmapAt(player.loc)->flags &= ~HAS_PLAYER;
                player.loc = lungeStep;
                pmapAt(player.loc)->flags |= HAS_PLAYER;
                attack(&player, lungeTgt, true /*lunge: guaranteed hit + bonus*/);
                if (rogue.weapon->flags & ITEM_ATTACKS_QUICKLY) pcost /= 2;
            } else if (zapWorthIt) {
                bolt bt = boltCatalog[boltForItem(staff)]; // staff-agnostic: lightning, firebolt, etc.
                bt.magnitude = staff->enchant1;
                if (netEnchant(staff) >= 5 * FP_FACTOR) bt.empowerment = (short)(netEnchant(staff) / FP_FACTOR);
                pos target = far ? far->loc : (pos){ ROOM_X1, PY };
                zap(player.loc, target, &bt, false, false);
                staff->charges--; r.chargesSpent++;
            } else if (adj) {
                boolean cleave  = rogue.weapon && (rogue.weapon->flags & ITEM_ATTACKS_ALL_ADJACENT);
                boolean pierce  = rogue.weapon && (rogue.weapon->flags & ITEM_ATTACKS_PENETRATE);
                pos adjLoc = adj->loc; // capture before attack() can free adj
                attack(&player, adj, false);
                if (cleave) {
                    // hit remaining adjacent enemies (snapshot first; attacks can free creatures)
                    creature *adjs[8]; int na = 0;
                    for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
                        creature *m = nextCreature(&it);
                        if (m != adj && distanceBetween(player.loc, m->loc) == 1 && na < 8) adjs[na++] = m;
                    }
                    for (int i = 0; i < na; i++) attack(&player, adjs[i], false);
                } else if (pierce) {
                    // spear/pike: also strike the creature directly behind the target (same line).
                    pos beyond = { adjLoc.x + (adjLoc.x - player.loc.x), adjLoc.y + (adjLoc.y - player.loc.y) };
                    creature *b = monsterAtLoc(beyond);
                    if (b && b != &player) attack(&player, b, false);
                }
                // Per-weapon attack recovery: rapier (QUICKLY) is 2x faster; mace/war hammer
                // (STAGGER, "extra turn to recover") are 2x slower. Otherwise normal.
                if (rogue.weapon && (rogue.weapon->flags & ITEM_ATTACKS_QUICKLY)) pcost /= 2;
                if (rogue.weapon && (rogue.weapon->flags & ITEM_ATTACKS_STAGGER)) pcost *= 2;
            }
            player.ticksUntilTurn = pcost;
        }

        // Monsters act.
        for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
            creature *m = nextCreature(&it);
            if (m->ticksUntilTurn > 0) continue;
            // Honor the SE lightning stun (and entrancement): a paralyzed monster loses its turn.
            if (m->status[STATUS_PARALYZED] > 0 || m->status[STATUS_ENTRANCED] > 0) {
                if (m->status[STATUS_PARALYZED] > 0) m->status[STATUS_PARALYZED]--;
                if (m->status[STATUS_ENTRANCED] > 0) m->status[STATUS_ENTRANCED]--;
                m->ticksUntilTurn = m->movementSpeed;
                continue;
            }
            if (distanceBetween(player.loc, m->loc) == 1) { attack(m, &player, false); m->ticksUntilTurn = m->attackSpeed; }
            else { stepToward(m); m->ticksUntilTurn = m->movementSpeed; }
        }

        // Stalemate tracking. Count "no progress" only once enemies are engaged (in reach) — while they
        // are still closing the distance, that's a legit approach, not a stalemate (the ambush case).
        int monHP = 0; short nearestD = 9999;
        for (creatureIterator it = iterateCreatures(monsters); hasNextCreature(it);) {
            creature *m = nextCreature(&it);
            monHP += m->currentHP;
            short d = distanceBetween(player.loc, m->loc);
            if (d < nearestD) nearestD = d;
        }
        if (monHP < prevMonHP || nearestD > 8) { prevMonHP = monHP; lastProgress = clock; }
    }

    int dmgTaken = FS_BIG_HP - player.currentHP;
    r.hpLost     = dmgTaken < hpBudget ? dmgTaken : hpBudget;
    r.endHP      = hpBudget - r.hpLost;
    r.endCharges = staff ? staff->charges : 0;
    r.turns      = (int)(clock / TURN_TICKS);
    r.won        = (dmgTaken < hpBudget && aliveCount() == 0) ? 1 : 0; // survived the budget & cleared
    return r;
}
