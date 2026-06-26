// Fight simulator — Phase 0 harness skeleton.
//
//   --selftest      (default) assert engine formula goldens at shipping defaults.
//                   This is the §9 oracle + the byte-identical guard for the Phase 5
//                   balanceConfig refactor: if these move, a "default" config changed
//                   the engine.
//   --damage-curve  emit the analytic damage-curve reference CSV (§10 layer 1).
//
// See docs/design/fight-simulator.md §10-11. Build: tools/fightsim/build.sh

#include "Rogue.h"
#include "GlobalsBase.h"
#include "Globals.h"
#include "balance.h"
#include "sim.h"
#include "budget.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

balanceConfig gBalance = FIGHTSIM_SHIPPING_DEFAULTS;

static int g_failures = 0;

static void checkInt(const char *label, long got, long want) {
    const char *mark = (got == want) ? "ok " : "FAIL";
    if (got != want) g_failures++;
    printf("    [%s] %-34s got=%ld want=%ld\n", mark, label, got, want);
}

// Capture the engine's current formula outputs. Literals are frozen goldens; if a
// future refactor (Phase 5) changes a default-config result, these fail loudly.
static int selftest(void) {
    printf("[fightsim] self-test (engine formula goldens @ shipping defaults)\n");

    // --- staff damage curve (PowerTables.c:49-50) ---
    checkInt("staffDamageLow(+4)",  staffDamageLow(4 * FP_FACTOR),  4);   // (2+4)*3/4 = 4
    checkInt("staffDamageHigh(+4)", staffDamageHigh(4 * FP_FACTOR), 14);  // 4 + 5*4/2 = 14
    checkInt("staffDamageLow(+6)",  staffDamageLow(6 * FP_FACTOR),  6);   // (2+6)*3/4 = 6
    checkInt("staffDamageHigh(+6)", staffDamageHigh(6 * FP_FACTOR), 19);  // 4 + 5*6/2 = 19
    checkInt("staffDamageHigh(+10)",staffDamageHigh(10 * FP_FACTOR),29);  // 4 + 5*10/2 = 29

    // --- SE lightning/firebolt ramps (PowerTables.c:65-72), keyed by net-enchant LEVEL ---
    checkInt("lightningChainCount(4)",  staffLightningChainCount(4),  1);
    checkInt("lightningChainCount(6)",  staffLightningChainCount(6),  1);
    checkInt("lightningChainCount(8)",  staffLightningChainCount(8),  2);
    checkInt("lightningChainCount(11)", staffLightningChainCount(11), 3);
    checkInt("lightningChainRange(5)",  staffLightningChainRange(5),  3);
    checkInt("lightningChainRange(6)",  staffLightningChainRange(6),  4);
    checkInt("lightningChainRange(11)", staffLightningChainRange(11), 8);
    checkInt("lightningStunDuration(6)",staffLightningStunDuration(6),1);
    checkInt("lightningStunDuration(9)",staffLightningStunDuration(9),3);
    checkInt("fireboltBloomDecrement(5)", staffFireboltBloomDecrement(5),  37);
    checkInt("fireboltBloomDecrement(6)", staffFireboltBloomDecrement(6),  33);
    checkInt("fireboltBloomDecrement(12)",staffFireboltBloomDecrement(12), 12); // floor

    // --- strength / net enchant (Combat.c:65-81), realistic +6 war axe @ str 12 ---
    // war axe base str-req 19; +6 enchant lowers it to 13; player str 12 -> 1 under.
    item warAxe; memset(&warAxe, 0, sizeof warAxe);
    warAxe.category = WEAPON;
    warAxe.strengthRequired = 13;
    warAxe.enchant1 = 6;
    // -1 under-strength: -1 * FP_FACTOR * 5/2 = -2.5 * 65536 = -163840
    checkInt("strengthModifier(+6 war axe)", strengthModifier(&warAxe), -163840);
    // netEnchant = 6*FP + (-163840) = 393216 - 163840 = 229376  (= 3.5 enchant)
    checkInt("netEnchant(+6 war axe)", netEnchant(&warAxe), 229376);

    printf("[fightsim] self-test %s (%d failure%s)\n",
           g_failures ? "FAILED" : "PASSED", g_failures, g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}

// §10 layer 1: the analytic damage-curve reference dataset.
static void damageCurveCsv(void) {
    printf("enchant,weapon_dmg_mult_x1000,staff_dmg_low,staff_dmg_high,lgt_chain,lgt_range,lgt_stun,fire_bloom_decr\n");
    for (int e = 0; e <= 16; e++) {
        long weaponMult = (long) damageFraction((fixpt) e * FP_FACTOR) * 1000 / FP_FACTOR;
        int ramped = (e >= gBalance.seRampThreshold);
        printf("%d,%ld,%d,%d,%d,%d,%d,%d\n",
               e,
               weaponMult,
               staffDamageLow((fixpt) e * FP_FACTOR),
               staffDamageHigh((fixpt) e * FP_FACTOR),
               ramped ? staffLightningChainCount(e) : 0,
               ramped ? staffLightningChainRange(e) : 0,
               ramped ? staffLightningStunDuration(e) : 0,
               ramped ? staffFireboltBloomDecrement(e) : 0);
    }
}

// Running mean ± 95% CI half-width over a sample.
typedef struct { double n, sum, sumSq; } Stat;
static void statAdd(Stat *s, double x) { s->n++; s->sum += x; s->sumSq += x * x; }
static double statMean(const Stat *s) { return s->n ? s->sum / s->n : 0; }
static double statCI(const Stat *s) {
    if (s->n < 2) return 0;
    double m = statMean(s);
    double var = (s->sumSq - s->n * m * m) / (s->n - 1);
    if (var < 0) var = 0;
    return 1.96 * sqrt(var / s->n);
}

// Run a set of builds against the same corridor, sharing each trial's seed across all
// builds (common random numbers). Reports each build + paired HP-lost diff vs builds[0].
typedef struct { Stat hp, turns, win, charges, diff; } BuildStats;

static void runMatrix(const char *title, const BuildSpec *builds, int nBuilds, Archetype arch,
                      int playerHP, short monsterKind, int numMonsters, int trials) {
    BuildStats st[8] = {0};
    for (int t = 0; t < trials; t++) {
        uint64_t seed = (uint64_t) t + 1;
        EncounterResult res[8];
        for (int bi = 0; bi < nBuilds; bi++)
            res[bi] = fs_run(&builds[bi], arch, playerHP, monsterKind, numMonsters, seed, 0, -1, 12, 0);
        for (int bi = 0; bi < nBuilds; bi++) {
            statAdd(&st[bi].hp, res[bi].hpLost);   statAdd(&st[bi].turns, res[bi].turns);
            statAdd(&st[bi].win, res[bi].won);     statAdd(&st[bi].charges, res[bi].chargesSpent);
            statAdd(&st[bi].diff, (double) res[bi].hpLost - res[0].hpLost);
        }
    }
    printf("# %s\n", title);
    printf("# %d monsters, player %d HP, %d CRN-paired trials\n", numMonsters, playerHP, trials);
    printf("build,hp_lost,hp_lost_ci,win_pct,turns,charges,hp_diff_vs_%s\n", builds[0].name);
    for (int bi = 0; bi < nBuilds; bi++) {
        printf("%s,%.2f,%.2f,%.0f,%.2f,%.2f,%+.2f\n",
               builds[bi].name, statMean(&st[bi].hp), statCI(&st[bi].hp),
               100 * statMean(&st[bi].win), statMean(&st[bi].turns),
               statMean(&st[bi].charges), statMean(&st[bi].diff));
    }
}

#define NONE (-1)

// Phase 1: war axe vs lightning staff at one enchant, in a corridor of goblins.
static void corridorPair(int trials, int B, int playerHP, int numMonsters) {
    BuildSpec builds[] = {
        { "war_axe",   WAR_AXE, LEATHER_ARMOR, NONE,            NONE, (short)B, 0, 0, 0 },
        { "lightning", NONE,    LEATHER_ARMOR, STAFF_LIGHTNING, NONE, 0, 0, (short)B, 0 },
    };
    char title[128];
    snprintf(title, sizeof title, "corridor-line: war axe +%d vs staff of lightning +%d (goblins)", B, B);
    runMatrix(title, builds, 2, ARCH_CORRIDOR_LINE, playerHP, MK_GOBLIN, numMonsters, trials);
}

// Phase 2: allocation-policy + reaping matrix, vs tanky ogres.
static void corridorMatrix(int trials, int B, int playerHP, int numMonsters) {
    BuildSpec builds[] = {
        { "axe_all",        WAR_AXE, LEATHER_ARMOR, NONE,            NONE,         (short)B,     0, 0,        0 },
        { "axe_armor_split",WAR_AXE, LEATHER_ARMOR, NONE,            NONE,         (short)(B/2), (short)(B-B/2), 0, 0 },
        { "staff_pure",     NONE,    LEATHER_ARMOR, STAFF_LIGHTNING, NONE,         0, 0, (short)B,            0 },
        { "staff_reaping",  NONE,    LEATHER_ARMOR, STAFF_LIGHTNING, RING_REAPING, 0, 0, (short)B, (short)B },
    };
    char title[128];
    snprintf(title, sizeof title, "corridor-line allocation matrix @ budget +%d (ogres)", B);
    runMatrix(title, builds, 4, ARCH_CORRIDOR_LINE, playerHP, MK_OGRE, numMonsters, trials);
}

// Phase 3: the same build pair across every archetype -> situational purpose.
static void archetypeSweep(int trials, int B, int playerHP) {
    BuildSpec builds[] = {
        { "war_axe",   WAR_AXE, LEATHER_ARMOR, NONE,            NONE, (short)B, 0, 0, 0 },
        { "lightning", NONE,    LEATHER_ARMOR, STAFF_LIGHTNING, NONE, 0, 0, (short)B, 0 },
    };
    // tanky enough that melee costs HP and one zap doesn't one-shot -> archetypes differ
    for (Archetype a = 0; a < ARCH_COUNT; a++) {
        char title[128];
        snprintf(title, sizeof title, "archetype=%s: war axe +%d vs lightning +%d (ogres)",
                 fs_archetypeName(a), B, B);
        int n = (a == ARCH_LONE_TANK) ? 1 : 5;
        runMatrix(title, builds, 2, a, playerHP, MK_OGRE, n, trials);
        printf("\n");
    }
}

// Phase 5: A/B a balance knob on shared seeds (common random numbers). Here: the net-enchant
// clamp == the weapon enchant *damage cap*. Lower it and watch the war-axe-vs-staff gap move.
// Requires -DFIGHTSIM (engine formulas read gBalance); selftest proves defaults are byte-identical.
static void clampAB(int trials, int clampHi, int B, int playerHP) {
    BuildSpec axe   = { "war_axe",   WAR_AXE, LEATHER_ARMOR, NONE,            NONE, (short)B, 0, 0, 0 };
    BuildSpec staff = { "lightning", NONE,    LEATHER_ARMOR, STAFF_LIGHTNING, NONE, 0, 0, (short)B, 0 };
    const balanceConfig base = FIGHTSIM_SHIPPING_DEFAULTS;
    Stat bAxe={0}, bSt={0}, vAxe={0}, vSt={0};
    for (int t = 0; t < trials; t++) {
        uint64_t s = (uint64_t) t + 1;
        gBalance = base;
        statAdd(&bAxe, fs_run(&axe,   ARCH_CORRIDOR_LINE, playerHP, MK_OGRE, 4, s, 0, -1, 12, 0).hpLost);
        statAdd(&bSt,  fs_run(&staff, ARCH_CORRIDOR_LINE, playerHP, MK_OGRE, 4, s, 0, -1, 12, 0).hpLost);
        gBalance = base; gBalance.netEnchantClampHi = clampHi;
        statAdd(&vAxe, fs_run(&axe,   ARCH_CORRIDOR_LINE, playerHP, MK_OGRE, 4, s, 0, -1, 12, 0).hpLost);
        statAdd(&vSt,  fs_run(&staff, ARCH_CORRIDOR_LINE, playerHP, MK_OGRE, 4, s, 0, -1, 12, 0).hpLost);
    }
    gBalance = base;
    printf("# A/B: net-enchant clamp (weapon enchant cap) 50 -> %d, budget +%d, 4 ogres, %d CRN trials\n",
           clampHi, B, trials);
    printf("config,war_axe_hp,war_axe_ci,lightning_hp,lightning_ci,gap(axe-staff)\n");
    printf("baseline(cap=50),%.2f,%.2f,%.2f,%.2f,%+.2f\n",
           statMean(&bAxe), statCI(&bAxe), statMean(&bSt), statCI(&bSt), statMean(&bAxe)-statMean(&bSt));
    printf("variant(cap=%d),%.2f,%.2f,%.2f,%.2f,%+.2f\n",
           clampHi, statMean(&vAxe), statCI(&vAxe), statMean(&vSt), statCI(&vSt), statMean(&vAxe)-statMean(&vSt));
    printf("# war-axe HP-lost change under the cap: %+.2f (the staff is the control — weapon-cap-immune;\n"
           "#   read the two 'gap' columns to see whether the cap moved the axe toward or past the staff).\n",
           statMean(&vAxe) - statMean(&bAxe));
}

// Phase 4: a depth trajectory — a sequence of encounters carrying HP and staff charges,
// with regen/recharge during the (soft) rest between fights. This is where the free-weapon
// vs charge-starved-staff economy actually surfaces: the staff can run dry over a stretch.
static void trajectory(int trials, int B, int playerHP) {
    BuildSpec axe   = { "war_axe",   WAR_AXE, LEATHER_ARMOR, NONE,            NONE, (short)B, 0, 0, 0 };
    BuildSpec staff = { "lightning", NONE,    LEATHER_ARMOR, STAFF_LIGHTNING, NONE, 0, 0, (short)B, 0 };
    const BuildSpec *builds[2] = { &axe, &staff };
    Archetype seq[] = { ARCH_AMBUSH_RANGE, ARCH_FRENZY_CLUSTER, ARCH_SCATTERED_PACK,
                        ARCH_CORRIDOR_LINE, ARCH_FRENZY_CLUSTER };
    const int nSeq = 5;
    const int regenPerRest = 12;   // HP healed while walking to the next fight
    const int rechargePerRest = 1; // staff charges regained per rest (mojo is slow)

    printf("# trajectory: %d encounters (ambush,cluster,scatter,corridor,cluster), 4 ogres each,\n", nSeq);
    printf("#   player %d HP, budget +%d, regen +%d/rest, staff recharge +%d/rest, %d trials\n",
           playerHP, B, regenPerRest, rechargePerRest, trials);
    printf("build,survived_pct,avg_encounters_cleared,avg_end_hp\n");
    for (int bi = 0; bi < 2; bi++) {
        Stat survived = {0}, cleared = {0}, endHP = {0};
        for (int t = 0; t < trials; t++) {
            int hp = playerHP;
            int charges = (builds[bi]->staffKind >= 0) ? B : -1;
            int done = 0; int alive = 1;
            for (int d = 0; d < nSeq; d++) {
                uint64_t seed = (uint64_t)(t * 100 + d + 1);
                EncounterResult r = fs_run(builds[bi], seq[d], playerHP, MK_OGRE, 4, seed, hp, charges, 12, 0);
                hp = r.endHP;
                if (builds[bi]->staffKind >= 0) charges = r.endCharges;
                if (!r.won || hp <= 0) { alive = 0; break; }
                done++;
                hp = (hp + regenPerRest > playerHP) ? playerHP : hp + regenPerRest; // rest
                if (charges >= 0 && charges < B) charges += rechargePerRest;
            }
            statAdd(&survived, alive); statAdd(&cleared, done); statAdd(&endHP, hp);
        }
        printf("%s,%.0f,%.2f,%.1f\n", builds[bi]->name,
               100 * statMean(&survived), statMean(&cleared), statMean(&endHP));
    }
}

// The flagship scenario: how much does heavy-weapon enchant SCALING tilt the game toward "all-in on
// the weapon" vs a SMART hybrid that buys the staff just to its +5/6 glow-up (the SE lightning ramp)
// and dumps every remaining point into the war axe? Sweep the enchant budget -> CRN-paired curve.
static void curveSweep(Archetype arch, int trials, int playerHP, int numMonsters, int maxB, int staffGlow) {
    printf("# crossover curve: all-in war axe (+B) vs glow-up hybrid (staff at +%d ramp, rest in war axe)\n", staffGlow);
    printf("# archetype=%s, %d ogres, player %d HP, %d CRN trials/point\n",
           fs_archetypeName(arch), numMonsters, playerHP, trials);
    printf("budget,allin_hp,allin_turns,allin_win,hyb_axe,hyb_staff,hyb_hp,hyb_turns,hyb_charges,hyb_win,delta_hp(hyb-allin)\n");
    for (int B = 4; B <= maxB; B += 2) {
        int sE = (B < staffGlow) ? B : staffGlow; // staff to its glow-up (capped by budget)
        int wE = B - sE;                           // everything else into the axe
        BuildSpec wpn = { "weapon", WAR_AXE, LEATHER_ARMOR, NONE,            NONE, (short)B,  0, 0,        0 };
        BuildSpec hyb = { "hybrid", WAR_AXE, LEATHER_ARMOR, STAFF_LIGHTNING, NONE, (short)wE, 0, (short)sE,0 };
        Stat wHP={0}, wT={0}, wW={0}, hHP={0}, hT={0}, hC={0}, hW={0}, dHP={0};
        for (int t = 0; t < trials; t++) {
            uint64_t s = (uint64_t) t + 1;
            EncounterResult w = fs_run(&wpn, arch, playerHP, MK_OGRE, numMonsters, s, 0, -1, 12, 0);
            EncounterResult h = fs_run(&hyb, arch, playerHP, MK_OGRE, numMonsters, s, 0, -1, 12, 0);
            statAdd(&wHP,w.hpLost); statAdd(&wT,w.turns); statAdd(&wW,w.won);
            statAdd(&hHP,h.hpLost); statAdd(&hT,h.turns); statAdd(&hC,h.chargesSpent); statAdd(&hW,h.won);
            statAdd(&dHP,(double)h.hpLost - w.hpLost);
        }
        printf("+%d,%.1f,%.1f,%.0f,+%d,+%d,%.1f,%.1f,%.1f,%.0f,%+.1f\n", B,
               statMean(&wHP), statMean(&wT), 100*statMean(&wW), wE, sE,
               statMean(&hHP), statMean(&hT), statMean(&hC), 100*statMean(&hW),
               statMean(&dHP));
    }
}

// DEPTH-indexed flagship: budget AND strength AND HP all derived from the metered cadence by depth,
// so the weapon's curve reflects strength accrual (not just enchants). all-in axe vs glow-up hybrid.
static void depthSweep(Archetype arch, int trials, int staffGlow, int maxDepth, int tableSeeds, short staffKind) {
    fs_buildBudgetTable(maxDepth, tableSeeds);
    int n = (arch == ARCH_LONE_TANK) ? 1 : 4;
    const char *staffName = (staffKind == STAFF_FIRE) ? "firebolt" : (staffKind == STAFF_POISON) ? "poison" : "lightning";
    printf("# DEPTH curve (resources derived from metered cadence, avg of %d seeds): all-in war axe\n", tableSeeds);
    printf("#   vs glow-up hybrid (staff-of-%s +%d, rest axe). archetype=%s, %d depth-monsters.\n",
           staffName, staffGlow, fs_archetypeName(arch), n);
    printf("depth,strength,maxHP,budget,allin_hp,allin_win,hyb_axe,hyb_staff,hyb_hp,hyb_win,delta(hyb-allin)\n");
    for (int d = 3; d <= maxDepth; d += 2) {
        DepthBudget bud = fs_budgetAt(d);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        int sE = (B < staffGlow) ? B : staffGlow;
        int wE = B - sE;
        BuildSpec wpn = { "weapon", WAR_AXE, LEATHER_ARMOR, NONE,      NONE, (short)B,  0, 0,        0 };
        BuildSpec hyb = { "hybrid", WAR_AXE, LEATHER_ARMOR, staffKind, NONE, (short)wE, 0, (short)sE,0 };
        Stat wHP={0}, wW={0}, hHP={0}, hW={0}, dHP={0};
        for (int t = 0; t < trials; t++) {
            uint64_t s = (uint64_t) t + 1;
            EncounterResult w = fs_run(&wpn, arch, hp, MK_OGRE, n, s, 0, -1, strength, d);
            EncounterResult h = fs_run(&hyb, arch, hp, MK_OGRE, n, s, 0, -1, strength, d);
            statAdd(&wHP,w.hpLost); statAdd(&wW,w.won);
            statAdd(&hHP,h.hpLost); statAdd(&hW,h.won);
            statAdd(&dHP,(double)h.hpLost - w.hpLost);
        }
        printf("%d,%d,%d,+%d,%.1f,%.0f,+%d,+%d,%.1f,%.0f,%+.1f\n", d, strength, hp, B,
               statMean(&wHP), 100*statMean(&wW), wE, sE,
               statMean(&hHP), 100*statMean(&hW), statMean(&dHP));
    }
}

int main(int argc, char **argv) {
    gameVariant = VARIANT_BROGUE;
    initializeGameVariant();
    initializeRogue(1 /* seed */);

    const char *mode = (argc > 1) ? argv[1] : "--selftest";
    if (strcmp(mode, "--damage-curve") == 0) {
        damageCurveCsv();
        return 0;
    }
    if (strcmp(mode, "--corridor") == 0) {
        int enchant = (argc > 2) ? atoi(argv[2]) : 10;
        int trials  = (argc > 3) ? atoi(argv[3]) : 500;
        corridorPair(trials, enchant, 60 /*playerHP*/, 5 /*monsters*/);
        return 0;
    }
    if (strcmp(mode, "--matrix") == 0) {
        int budget = (argc > 2) ? atoi(argv[2]) : 8;
        int trials = (argc > 3) ? atoi(argv[3]) : 300;
        corridorMatrix(trials, budget, 80 /*playerHP*/, 4 /*ogres*/);
        return 0;
    }
    if (strcmp(mode, "--archetypes") == 0) {
        int budget = (argc > 2) ? atoi(argv[2]) : 8;
        int trials = (argc > 3) ? atoi(argv[3]) : 50;
        archetypeSweep(trials, budget, 90 /*playerHP*/);
        return 0;
    }
    if (strcmp(mode, "--ab") == 0) {
        int clampHi = (argc > 2) ? atoi(argv[2]) : 10;
        int budget  = (argc > 3) ? atoi(argv[3]) : 16;
        int trials  = (argc > 4) ? atoi(argv[4]) : 60;
        clampAB(trials, clampHi, budget, 90 /*playerHP*/);
        return 0;
    }
    if (strcmp(mode, "--trajectory") == 0) {
        int budget = (argc > 2) ? atoi(argv[2]) : 8;
        int trials = (argc > 3) ? atoi(argv[3]) : 20;
        trajectory(trials, budget, 90 /*playerHP*/);
        return 0;
    }
    if (strcmp(mode, "--curve") == 0) {
        int arch   = (argc > 2) ? atoi(argv[2]) : ARCH_FRENZY_CLUSTER;
        int maxB   = (argc > 3) ? atoi(argv[3]) : 16;
        int trials = (argc > 4) ? atoi(argv[4]) : 20;
        int glow   = (argc > 5) ? atoi(argv[5]) : 6;  // staff glow-up target (+5/6)
        int n = (arch == ARCH_LONE_TANK) ? 1 : 4;
        curveSweep((Archetype) arch, trials, 90 /*playerHP*/, n, maxB, glow);
        return 0;
    }
    if (strcmp(mode, "--baseline") == 0) {
        // Full situational baseline: every archetype, depth-scaled both sides, one staff. Table built once.
        int maxDepth = (argc > 2) ? atoi(argv[2]) : 19;
        int trials   = (argc > 3) ? atoi(argv[3]) : 25;
        int sk       = (argc > 4) ? atoi(argv[4]) : 0;
        short staffKind = (sk == 1) ? STAFF_FIRE : (sk == 2) ? STAFF_POISON : STAFF_LIGHTNING;
        for (Archetype a = 0; a < ARCH_COUNT; a++) {
            depthSweep(a, trials, 6 /*glow*/, maxDepth, 8 /*table seeds*/, staffKind);
            printf("\n");
        }
        return 0;
    }
    if (strcmp(mode, "--depth") == 0) {
        int arch     = (argc > 2) ? atoi(argv[2]) : ARCH_FRENZY_CLUSTER;
        int maxDepth = (argc > 3) ? atoi(argv[3]) : 20;
        int trials   = (argc > 4) ? atoi(argv[4]) : 25;
        int glow     = (argc > 5) ? atoi(argv[5]) : 6;
        // staff: 0=lightning (default), 1=firebolt, 2=poison
        int sk = (argc > 6) ? atoi(argv[6]) : 0;
        short staffKind = (sk == 1) ? STAFF_FIRE : (sk == 2) ? STAFF_POISON : STAFF_LIGHTNING;
        depthSweep((Archetype) arch, trials, glow, maxDepth, 8 /*table seeds*/, staffKind);
        return 0;
    }
    return selftest();
}
