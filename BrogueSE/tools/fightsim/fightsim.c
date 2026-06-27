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

// The "heavy" weapons subject to the enchant cap: the high-win generalists. War hammer is included
// (mildly capped) but its big base damage keeps it the 1v1 king; mace + broadsword are in so the cap
// can't be dodged by swapping to them. Light/finesse weapons (dagger/sword/rapier/axe) stay free.
#define FS_HEAVY_MASK ((1UL<<WAR_AXE)|(1UL<<HAMMER)|(1UL<<PIKE)|(1UL<<FLAIL)|(1UL<<MACE)|(1UL<<BROADSWORD))

// Per-kind enchant-knee helpers (the config fields are now arrays).
static void fsResetCaps(void) {
    for (int i = 0; i < NUMBER_WEAPON_KINDS; i++) {
        gBalance.heavyWeaponCap[i] = 0;
        gBalance.heavyWeaponSlopePct[i] = 0;
        gBalance.weaponRecoveryPct[i] = 0;
    }
}
// Knee every weapon kind whose bit is set in `mask` at `cap`, as a HARD cap (slope 0); clear the rest.
static void fsCapSet(unsigned long mask, int cap) {
    for (int i = 0; i < NUMBER_WEAPON_KINDS; i++) {
        boolean on = (mask & (1UL << i)) != 0;
        gBalance.heavyWeaponCap[i] = on ? cap : 0;
        gBalance.heavyWeaponSlopePct[i] = 0;
    }
}

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

// TUNING: three-way (all-in war axe vs all-in lightning staff vs glow-up hybrid) across every
// scenario at one depth, run at baseline AND at a tuned weapon enchant cap (the net-enchant clamp),
// so we can watch the balance shift. HP lost (lower=better) + win%.
static void tuneThreeWay(int depth, int trials, int tunedCap) {
    fs_buildBudgetTable(depth, 8);
    DepthBudget bud = fs_budgetAt(depth);
    int B = (int)(bud.enchantScrolls + 0.5);
    int strength = 12 + (int)(bud.strengthPotions + 0.5);
    int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
    int sE = (B < 6) ? B : 6, wE = B - sE;
    BuildSpec axe = { "war_axe",   WAR_AXE, LEATHER_ARMOR, NONE,            NONE, (short)B,  0, 0,        0 };
    BuildSpec lgt = { "lightning", DAGGER,  LEATHER_ARMOR, STAFF_LIGHTNING, NONE, 0,        0, (short)B, 0 };
    BuildSpec hyb = { "hybrid",    WAR_AXE, LEATHER_ARMOR, STAFF_LIGHTNING, NONE, (short)wE,0, (short)sE,0 };
    const BuildSpec *builds[3] = { &axe, &lgt, &hyb };
    // "Heavy" weapons that get the enchant cap: war axe, war hammer, war pike, flail (NOT dagger/
    // sword/rapier/mace/broadsword). Edit this set to taste.
    const unsigned long heavyMask = FS_HEAVY_MASK;

    printf("# THREE-WAY tuning @ depth %d (str %d, HP %d, budget +%d): all-in war axe vs all-in\n", depth, strength, hp, B);
    printf("#   lightning vs glow-up hybrid (axe+%d/staff+%d). HP lost (win%%). heavy-weapon enchant cap.\n", wE, sE);
    for (int c = 0; c < 2; c++) {
        fsCapSet((c == 0) ? 0 : heavyMask, tunedCap); // baseline: no cap
        printf("--- heavy-weapon enchant cap = %s ---\n", c == 0 ? "off (baseline)" : "on (tuned)");
        printf("scenario,axe_hp,axe_win,lightning_hp,lgt_win,hybrid_hp,hyb_win\n");
        for (Archetype a = 0; a < ARCH_COUNT; a++) {
            int n = (a == ARCH_LONE_TANK) ? 1 : 4;
            Stat h[3] = {0}, w[3] = {0};
            for (int t = 0; t < trials; t++) {
                uint64_t s = (uint64_t) t + 1;
                for (int bi = 0; bi < 3; bi++) {
                    EncounterResult r = fs_run(builds[bi], a, hp, MK_OGRE, n, s, 0, -1, strength, depth);
                    statAdd(&h[bi], r.hpLost); statAdd(&w[bi], r.won);
                }
            }
            printf("%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f\n", fs_archetypeName(a),
                   statMean(&h[0]), 100*statMean(&w[0]),
                   statMean(&h[1]), 100*statMean(&w[1]),
                   statMean(&h[2]), 100*statMean(&w[2]));
        }
    }
    fsResetCaps(); // restore
}

// WEAPON ROSTER: every weapon, all-in at the depth's budget, averaged over all five scenarios,
// at baseline vs the heavy-weapon cap -- so we see which weapons dominate as generalists AND confirm
// the cap lands only on the heavy set (war axe/hammer/pike/flail), sparing dagger/sword/rapier/etc.
static void weaponRoster(int depth, int trials, int heavyCap) {
    fs_buildBudgetTable(depth, 8);
    DepthBudget bud = fs_budgetAt(depth);
    int B = (int)(bud.enchantScrolls + 0.5);
    int strength = 12 + (int)(bud.strengthPotions + 0.5);
    int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
    struct { short kind; const char *name; } roster[] = {
        {DAGGER,"dagger"}, {SWORD,"sword"}, {RAPIER,"rapier"}, {MACE,"mace"}, {AXE,"axe"},
        {BROADSWORD,"broadsword"}, {FLAIL,"flail"}, {PIKE,"war_pike"}, {WAR_AXE,"war_axe"}, {HAMMER,"war_hammer"},
    };
    const unsigned long heavyMask = FS_HEAVY_MASK;
    const int nW = (int)(sizeof roster / sizeof roster[0]);

    printf("# WEAPON ROSTER @ depth %d (str %d, HP %d, all-in +%d), mean over 5 scenarios, %d trials.\n",
           depth, strength, hp, B, trials);
    printf("# heavy cap = %d on {war axe, war hammer, war pike, flail}.\n", heavyCap);
    printf("weapon,base_hp,base_win,capped_hp,capped_win,in_heavy_set\n");
    for (int wi = 0; wi < nW; wi++) {
        double out[2][2]; // [cfg][0=hp,1=win]
        for (int c = 0; c < 2; c++) {
            fsCapSet((c == 0) ? 0 : heavyMask, heavyCap);
            BuildSpec w = { roster[wi].name, roster[wi].kind, LEATHER_ARMOR, NONE, NONE, (short)B, 0, 0, 0 };
            Stat hS = {0}, wS = {0};
            for (Archetype a = 0; a < ARCH_COUNT; a++) {
                int n = (a == ARCH_LONE_TANK) ? 1 : 4;
                for (int t = 0; t < trials; t++) {
                    EncounterResult r = fs_run(&w, a, hp, MK_OGRE, n, (uint64_t)t + 1, 0, -1, strength, depth);
                    statAdd(&hS, r.hpLost); statAdd(&wS, r.won);
                }
            }
            out[c][0] = statMean(&hS); out[c][1] = 100 * statMean(&wS);
        }
        printf("%s,%.0f,%.0f,%.0f,%.0f,%s\n", roster[wi].name,
               out[0][0], out[0][1], out[1][0], out[1][1],
               (heavyMask & (1UL << roster[wi].kind)) ? "yes" : "no");
    }
    fsResetCaps();
}

// Run one weapon across all archetypes at a given depth/budget; return mean win% (0..100).
static double runWeaponWin(short kind, const char *name, int B, int hp, int strength, int depth, int trials) {
    BuildSpec w = { name, kind, LEATHER_ARMOR, NONE, NONE, (short)B, 0, 0, 0 };
    Stat wS = {0};
    for (Archetype a = 0; a < ARCH_COUNT; a++) {
        int n = (a == ARCH_LONE_TANK) ? 1 : 4;
        for (int t = 0; t < trials; t++) {
            EncounterResult r = fs_run(&w, a, hp, MK_OGRE, n, (uint64_t)t + 1, 0, -1, strength, depth);
            statAdd(&wS, r.won);
        }
    }
    return 100 * statMean(&wS);
}

// Focused cap sweep: cap only the four genuine generalists {broadsword, war pike, war axe, flail}
// (sparing war hammer = 1v1 king, mace = self-balancing, and all nimble weapons), and watch how each
// cap value pulls their universal dominance toward the "strong but situational" band, depth by depth.
// sword/rapier/war_hammer are printed as uncapped reference bars (the floor the cap must not cross).
static void capSweep(int trials) {
    const int depths[] = {10, 13, 16, 19};
    const int caps[]   = {12, 10, 8, 6};
    const unsigned long focusMask =
        (1UL<<BROADSWORD) | (1UL<<PIKE) | (1UL<<WAR_AXE) | (1UL<<FLAIL);
    struct { short kind; const char *name; } capped[] = {
        {BROADSWORD,"broadsword"}, {PIKE,"war_pike"}, {WAR_AXE,"war_axe"}, {FLAIL,"flail"},
    };
    struct { short kind; const char *name; } refs[] = {
        {SWORD,"sword"}, {RAPIER,"rapier"}, {HAMMER,"war_hammer"},
    };
    printf("# CAP SWEEP -- mask = {broadsword, war_pike, war_axe, flail}; %d trials x 5 archetypes.\n", trials);
    printf("# refs (sword/rapier/war_hammer) are uncapped baselines. cap=0 row is the capped weapon's own baseline.\n");
    printf("depth,cap,weapon,win,role\n");
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8); // build once to max depth (repeat calls double-free)
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        fsResetCaps();
        for (int i = 0; i < (int)(sizeof refs/sizeof refs[0]); i++)
            printf("%d,0,%s,%.0f,ref\n", depth, refs[i].name,
                   runWeaponWin(refs[i].kind, refs[i].name, B, hp, strength, depth, trials));
        for (int wi = 0; wi < (int)(sizeof capped/sizeof capped[0]); wi++) {
            fsResetCaps();
            printf("%d,0,%s,%.0f,capped\n", depth, capped[wi].name,
                   runWeaponWin(capped[wi].kind, capped[wi].name, B, hp, strength, depth, trials));
            for (int ci = 0; ci < (int)(sizeof caps/sizeof caps[0]); ci++) {
                fsCapSet(focusMask, caps[ci]);
                printf("%d,%d,%s,%.0f,capped\n", depth, caps[ci], capped[wi].name,
                       runWeaponWin(capped[wi].kind, capped[wi].name, B, hp, strength, depth, trials));
            }
        }
        fflush(stdout);
    }
    fsResetCaps();
}

// One weapon vs one archetype at a given depth/budget; mean win% (0..100).
static double runWA(short kind, const char *name, Archetype a, int B, int hp, int strength, int depth, int trials) {
    BuildSpec w = { name, kind, LEATHER_ARMOR, NONE, NONE, (short)B, 0, 0, 0 };
    Stat wS = {0};
    int n = (a == ARCH_LONE_TANK) ? 1 : 4;
    for (int t = 0; t < trials; t++) {
        EncounterResult r = fs_run(&w, a, hp, MK_OGRE, n, (uint64_t)t + 1, 0, -1, strength, depth);
        statAdd(&wS, r.won);
    }
    return 100 * statMean(&wS);
}

// Per-archetype profile at d16 & d19, baseline + cap-10, for the four generalists + sword/rapier/war_hammer.
// Answers what the aggregate win% hides: is a "91%" weapon dominant *everywhere*, or already situational
// (strong in its geometry, weak elsewhere)? That decides whether the cap fix should be light or differentiated.
static void archProfile(int trials) {
    const int depths[] = {16, 19};
    const unsigned long focusMask =
        (1UL<<BROADSWORD) | (1UL<<PIKE) | (1UL<<WAR_AXE) | (1UL<<FLAIL);
    struct { short kind; const char *name; } W[] = {
        {SWORD,"sword"}, {RAPIER,"rapier"}, {HAMMER,"war_hammer"},
        {BROADSWORD,"broadsword"}, {PIKE,"war_pike"}, {WAR_AXE,"war_axe"}, {FLAIL,"flail"},
    };
    const int nW = (int)(sizeof W / sizeof W[0]);
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        for (int cfg = 0; cfg < 2; cfg++) {
            fsCapSet(cfg ? focusMask : 0, 10); // refs unaffected: their bit isn't in the set
            printf("# ARCH PROFILE @ depth %d, %s -- win%% per archetype (str %d, HP %d, +%d)\n",
                   depth, cfg ? "CAP 10 on generalists" : "baseline", strength, hp, B);
            printf("weapon,corridor,cluster,pack,lone_tank,ambush,mean\n");
            for (int wi = 0; wi < nW; wi++) {
                double sum = 0;
                printf("%s", W[wi].name);
                for (Archetype a = 0; a < ARCH_COUNT; a++) {
                    double v = runWA(W[wi].kind, W[wi].name, a, B, hp, strength, depth, trials);
                    sum += v; printf(",%.0f", v);
                }
                printf(",%.0f\n", sum / ARCH_COUNT);
            }
            printf("\n");
            fflush(stdout);
        }
    }
    fsResetCaps();
}

static void printArchRow(const char *label, short kind, const char *name,
                         int B, int hp, int strength, int depth, int trials) {
    double sum = 0;
    printf("%s", label);
    for (Archetype a = 0; a < ARCH_COUNT; a++) {
        double v = runWA(kind, name, a, B, hp, strength, depth, trials);
        sum += v; printf(",%.0f", v);
    }
    printf(",%.0f\n", sum / ARCH_COUNT);
    fflush(stdout);
}

// Differentiated lever tuning at d16/d19: broadsword+war_axe locked at enchant cap 10, then sweep
// war_pike's penetrate-damage % and flail's pass-attack % to find values that land them in the
// reference band (rapier ~82 / war_hammer ~83 at d19) with genuine per-archetype variation.
static void leverTune(int trials) {
    const int depths[] = {16, 19};
    const int pcts[] = {100, 75, 50};
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        char lbl[48];
        printf("# LEVER TUNE @ depth %d -- win%% per archetype (str %d, HP %d, +%d)\n", depth, strength, hp, B);
        printf("config,corridor,cluster,pack,lone_tank,ambush,mean\n");
        // References (uncapped, levers off)
        fsResetCaps(); gBalance.penetrateDamagePct = 100; gBalance.passAttackDamagePct = 100;
        printArchRow("sword", SWORD, "sword", B, hp, strength, depth, trials);
        printArchRow("rapier", RAPIER, "rapier", B, hp, strength, depth, trials);
        printArchRow("war_hammer", HAMMER, "war_hammer", B, hp, strength, depth, trials);
        // Locked decisions: broadsword + war_axe at enchant cap 10
        fsCapSet((1UL<<BROADSWORD) | (1UL<<WAR_AXE), 10);
        printArchRow("broadsword@cap10", BROADSWORD, "broadsword", B, hp, strength, depth, trials);
        printArchRow("war_axe@cap10", WAR_AXE, "war_axe", B, hp, strength, depth, trials);
        fsResetCaps();
        // war_pike: penetrate-damage % sweep (enchant cap is ineffective on it)
        for (int i = 0; i < (int)(sizeof pcts/sizeof pcts[0]); i++) {
            gBalance.penetrateDamagePct = pcts[i];
            sprintf(lbl, "war_pike@pen%d", pcts[i]);
            printArchRow(lbl, PIKE, "war_pike", B, hp, strength, depth, trials);
        }
        gBalance.penetrateDamagePct = 100;
        // flail: pass-attack % sweep (enchant cap is a cliff on it)
        for (int i = 0; i < (int)(sizeof pcts/sizeof pcts[0]); i++) {
            gBalance.passAttackDamagePct = pcts[i];
            sprintf(lbl, "flail@pass%d", pcts[i]);
            printArchRow(lbl, FLAIL, "flail", B, hp, strength, depth, trials);
        }
        gBalance.passAttackDamagePct = 100;
        printf("\n");
    }
    fsResetCaps();
}

// Final proposed config across the curve: broadsword/war_axe @ enchant cap 10, war_pike @ cap 8,
// flail left as-is, vs sword/rapier/war_hammer references. Each weapon is equipped alone per run,
// so setting that weapon's per-kind cap before its row is sufficient.
static void finalConfig(int trials) {
    const int depths[] = {13, 16, 19};
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        printf("# FINAL CONFIG @ depth %d -- win%% per archetype (str %d, HP %d, +%d)\n", depth, strength, hp, B);
        printf("config,corridor,cluster,pack,lone_tank,ambush,mean\n");
        fsResetCaps(); gBalance.penetrateDamagePct = 100; gBalance.passAttackDamagePct = 100;
        printArchRow("sword", SWORD, "sword", B, hp, strength, depth, trials);
        printArchRow("rapier", RAPIER, "rapier", B, hp, strength, depth, trials);
        printArchRow("war_hammer", HAMMER, "war_hammer", B, hp, strength, depth, trials);
        fsCapSet((1UL<<BROADSWORD), 10);
        printArchRow("broadsword@cap10", BROADSWORD, "broadsword", B, hp, strength, depth, trials);
        fsCapSet((1UL<<BROADSWORD), 9);
        printArchRow("broadsword@cap9", BROADSWORD, "broadsword", B, hp, strength, depth, trials);
        fsCapSet((1UL<<WAR_AXE), 10);
        printArchRow("war_axe@cap10", WAR_AXE, "war_axe", B, hp, strength, depth, trials);
        fsCapSet((1UL<<PIKE), 8);
        printArchRow("war_pike@cap8", PIKE, "war_pike", B, hp, strength, depth, trials);
        fsResetCaps();
        printArchRow("flail@leave", FLAIL, "flail", B, hp, strength, depth, trials);
        gBalance.passAttackDamagePct = 50;
        printArchRow("flail@pass50", FLAIL, "flail", B, hp, strength, depth, trials);
        gBalance.passAttackDamagePct = 100;
        printf("\n");
    }
    fsResetCaps();
}

// Reproduce the baked tuned end-state: load FIGHTSIM_TUNED_DEFAULTS and print the per-archetype
// profile for the whole roster across the curve. One command to verify the preset (and to diff
// against --archprofile's baseline). Restores gBalance afterward.
static void tunedConfig(int trials) {
    const int depths[] = {13, 16, 19};
    struct { short kind; const char *name; } roster[] = {
        {DAGGER,"dagger"}, {SWORD,"sword"}, {RAPIER,"rapier"}, {MACE,"mace"}, {AXE,"axe"},
        {BROADSWORD,"broadsword"}, {FLAIL,"flail"}, {PIKE,"war_pike"}, {WAR_AXE,"war_axe"}, {HAMMER,"war_hammer"},
    };
    const int nW = (int)(sizeof roster / sizeof roster[0]);
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    balanceConfig saved = gBalance;
    gBalance = FIGHTSIM_TUNED_DEFAULTS;
    printf("# TUNED CONFIG (FIGHTSIM_TUNED_DEFAULTS): soft knees broadsword 9/war_axe 10 @slope25; "
           "war_pike 2x recovery (reach-modeled); flail pass50.\n");
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        printf("# depth %d -- win%% per archetype (str %d, HP %d, +%d)\n", depth, strength, hp, B);
        printf("weapon,corridor,cluster,pack,lone_tank,ambush,mean\n");
        for (int wi = 0; wi < nW; wi++)
            printArchRow(roster[wi].name, roster[wi].kind, roster[wi].name, B, hp, strength, depth, trials);
        printf("\n");
    }
    gBalance = saved;
}

// Soft-knee slope sweep: for the tuned per-weapon knees, vary the marginal % above the knee
// (0 = hard cap .. 100 = no taper) and watch each weapon climb back from the hard-cap floor toward
// uncapped. Finds the slope that keeps post-knee growth without restoring universal dominance.
static void taperSweep(int trials) {
    const int depths[] = {16, 19};
    const int slopes[] = {0, 25, 50, 75, 100};
    struct { short kind; const char *name; int knee; } K[] = {
        {BROADSWORD,"broadsword",9}, {WAR_AXE,"war_axe",10}, {PIKE,"war_pike",8},
    };
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        char lbl[48];
        printf("# TAPER SWEEP @ depth %d -- win%% per archetype (str %d, HP %d, +%d). slope 0=hard cap.\n",
               depth, strength, hp, B);
        printf("config,corridor,cluster,pack,lone_tank,ambush,mean\n");
        fsResetCaps();
        printArchRow("rapier(ref)", RAPIER, "rapier", B, hp, strength, depth, trials);
        printArchRow("war_hammer(ref)", HAMMER, "war_hammer", B, hp, strength, depth, trials);
        for (int ki = 0; ki < (int)(sizeof K/sizeof K[0]); ki++) {
            for (int si = 0; si < (int)(sizeof slopes/sizeof slopes[0]); si++) {
                fsCapSet((1UL << K[ki].kind), K[ki].knee);          // sets knee, slope 0
                gBalance.heavyWeaponSlopePct[K[ki].kind] = slopes[si]; // then the taper
                sprintf(lbl, "%s@knee%d/slope%d", K[ki].name, K[ki].knee, slopes[si]);
                printArchRow(lbl, K[ki].kind, K[ki].name, B, hp, strength, depth, trials);
            }
        }
        printf("\n");
    }
    fsResetCaps();
}

// Pike attack-speed lever: pike UNCAPPED (no enchant knee), recovery % varied, to see whether a
// cliff-free speed penalty alone tames it while preserving its per-archetype shape. Refs for the band.
static void pikeSpeedSweep(int trials) {
    const int depths[] = {16, 19};
    const int rec[] = {100, 125, 150, 175, 200};
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        char lbl[48];
        printf("# PIKE SPEED SWEEP @ depth %d -- pike uncapped, melee recovery%% varied (100=normal).\n",
               depth);
        printf("config,corridor,cluster,pack,lone_tank,ambush,mean\n");
        fsResetCaps();
        printArchRow("rapier(ref)", RAPIER, "rapier", B, hp, strength, depth, trials);
        printArchRow("war_hammer(ref)", HAMMER, "war_hammer", B, hp, strength, depth, trials);
        for (int ri = 0; ri < (int)(sizeof rec/sizeof rec[0]); ri++) {
            fsResetCaps();
            gBalance.weaponRecoveryPct[PIKE] = rec[ri];
            sprintf(lbl, "war_pike@rec%d", rec[ri]);
            printArchRow(lbl, PIKE, "war_pike", B, hp, strength, depth, trials);
        }
        printf("\n");
    }
    fsResetCaps();
}

// Pike reach-damage lever sweep: pike UNCAPPED, the distance-2 reach poke's damage varied
// (100 = full reach .. 0 = no reach benefit), to see whether trimming the reach restores pike's
// natural scattered-pack/approach weakness and pulls it back to a situational line weapon.
static void reachSweep(int trials) {
    const int depths[] = {16, 19};
    const int pcts[] = {100, 75, 50, 25, 0};
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        char lbl[48];
        printf("# REACH SWEEP @ depth %d -- pike uncapped, reach-poke damage%% varied (100=full reach).\n",
               depth);
        printf("config,corridor,cluster,pack,lone_tank,ambush,mean\n");
        fsResetCaps(); gBalance.reachDamagePct = 100;
        printArchRow("rapier(ref)", RAPIER, "rapier", B, hp, strength, depth, trials);
        printArchRow("war_hammer(ref)", HAMMER, "war_hammer", B, hp, strength, depth, trials);
        for (int i = 0; i < (int)(sizeof pcts/sizeof pcts[0]); i++) {
            gBalance.reachDamagePct = pcts[i];
            sprintf(lbl, "war_pike@reach%d", pcts[i]);
            printArchRow(lbl, PIKE, "war_pike", B, hp, strength, depth, trials);
        }
        gBalance.reachDamagePct = 100;
        printf("\n");
    }
    fsResetCaps();
}

// Run a full BuildSpec (weapon and/or staff) across all archetypes; print win% row + mean.
static void printBuildRow(const char *lbl, const BuildSpec *b, int hp, int strength, int depth, int trials) {
    double sum = 0;
    printf("%s", lbl);
    for (Archetype a = 0; a < ARCH_COUNT; a++) {
        int n = (a == ARCH_LONE_TANK) ? 1 : 4;
        Stat wS = {0};
        for (int t = 0; t < trials; t++) {
            EncounterResult r = fs_run(b, a, hp, MK_OGRE, n, (uint64_t)t + 1, 0, -1, strength, depth);
            statAdd(&wS, r.won);
        }
        double v = 100 * statMean(&wS); sum += v; printf(",%.0f", v);
    }
    printf(",%.0f\n", sum / ARCH_COUNT);
    fflush(stdout);
}

// Hybrid question: with the weapon's surplus enchants tapered (or the pike slowed), does diverting
// budget into a glowed lightning staff (+6 -> the SE >=5 chain/range/stun ramp) pay off better?
// For each weapon, compare ALL-IN (weapon +B) vs HYBRID (weapon +B-6 / staff +6) under SHIPPING vs TUNED.
static void hybridCompare(int trials) {
    const int depths[] = {16, 19};
    struct { short kind; const char *name; } W[] = {
        {SWORD,"sword"},          // control: no lever touches it
        {BROADSWORD,"broadsword"}, {WAR_AXE,"war_axe"}, {PIKE,"war_pike"},
    };
    const int glow = 6;
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    balanceConfig saved = gBalance;
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        int sE = (B < glow) ? B : glow, wHyb = B - sE;
        printf("# HYBRID @ depth %d (B=%d): all-in weapon (+%d) vs hybrid (weapon +%d / lightning +%d).\n",
               depth, B, B, wHyb, sE);
        printf("weapon,build,cfg,corridor,cluster,pack,lone_tank,ambush,mean\n");
        for (int wi = 0; wi < (int)(sizeof W/sizeof W[0]); wi++) {
            char lbl[64];
            for (int cfg = 0; cfg < 2; cfg++) {
                gBalance = cfg ? FIGHTSIM_TUNED_DEFAULTS : FIGHTSIM_SHIPPING_DEFAULTS;
                const char *cn = cfg ? "TU" : "SH";
                BuildSpec allin = { W[wi].name, W[wi].kind, LEATHER_ARMOR, NONE, NONE, (short)B, 0, 0, 0 };
                BuildSpec hyb   = { W[wi].name, W[wi].kind, LEATHER_ARMOR, STAFF_LIGHTNING, NONE,
                                    (short)wHyb, 0, (short)sE, 0 };
                sprintf(lbl, "%s,all-in,%s", W[wi].name, cn); printBuildRow(lbl, &allin, hp, strength, depth, trials);
                sprintf(lbl, "%s,hybrid,%s", W[wi].name, cn); printBuildRow(lbl, &hyb,   hp, strength, depth, trials);
            }
        }
        printf("\n");
    }
    gBalance = saved;
}

// Run one build through a fixed encounter sequence, carrying HP + finite staff charges (slow recharge
// and HP regen between fights). Prints survived%, avg encounters cleared, avg end HP.
static void runSustain(const char *lbl, const BuildSpec *b, int playerHP, int strength, int depth,
                       const Archetype *seq, int nSeq, int trials) {
    const int regenPerRest = 12, rechargePerRest = 1; // walk-to-next-fight heal; staff recharge is slow
    Stat survived = {0}, cleared = {0}, endHP = {0};
    for (int t = 0; t < trials; t++) {
        int hp = playerHP;
        int charges = (b->staffKind >= 0) ? b->staffEnchant : -1;
        int done = 0, alive = 1;
        for (int d = 0; d < nSeq; d++) {
            int n = (seq[d] == ARCH_LONE_TANK) ? 1 : 4;
            uint64_t seed = (uint64_t)(t * 100 + d + 1);
            EncounterResult r = fs_run(b, seq[d], playerHP, MK_OGRE, n, seed, hp, charges, strength, depth);
            hp = r.endHP;
            if (b->staffKind >= 0) charges = r.endCharges;
            if (!r.won || hp <= 0) { alive = 0; break; }
            done++;
            hp = (hp + regenPerRest > playerHP) ? playerHP : hp + regenPerRest;
            if (charges >= 0 && charges < b->staffEnchant) charges += rechargePerRest;
        }
        statAdd(&survived, alive); statAdd(&cleared, done); statAdd(&endHP, hp);
    }
    printf("%s,%.0f,%.2f,%.1f\n", lbl, 100 * statMean(&survived), statMean(&cleared), statMean(&endHP));
    fflush(stdout);
}

// Hybrid under finite charges: does the per-encounter hybrid edge survive a full floor's worth of fights,
// where the +6 staff runs dry and the (below-knee) fallback weapon must carry? 8-encounter sequence,
// all-in vs hybrid, shipping vs tuned.
static void hybridSustain(int trials) {
    const int depths[] = {16, 19};
    struct { short kind; const char *name; } W[] = {
        {SWORD,"sword"}, {BROADSWORD,"broadsword"}, {WAR_AXE,"war_axe"}, {PIKE,"war_pike"},
    };
    const Archetype seq[] = { ARCH_AMBUSH_RANGE, ARCH_FRENZY_CLUSTER, ARCH_SCATTERED_PACK,
                              ARCH_CORRIDOR_LINE, ARCH_LONE_TANK, ARCH_FRENZY_CLUSTER,
                              ARCH_AMBUSH_RANGE, ARCH_SCATTERED_PACK };
    const int nSeq = (int)(sizeof seq / sizeof seq[0]);
    const int glow = 6;
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    balanceConfig saved = gBalance;
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        int sE = (B < glow) ? B : glow, wHyb = B - sE;
        printf("# HYBRID SUSTAIN @ depth %d (B=%d, HP %d): %d encounters, staff +%d (%d charges), recharge +1/rest.\n",
               depth, B, hp, nSeq, sE, sE);
        printf("# all-in weapon (+%d) vs hybrid (weapon +%d / lightning +%d). SH=shipping, TU=tuned.\n",
               B, wHyb, sE);
        printf("weapon,build,cfg,survived_pct,avg_cleared,avg_end_hp\n");
        for (int wi = 0; wi < (int)(sizeof W/sizeof W[0]); wi++) {
            char lbl[64];
            for (int cfg = 0; cfg < 2; cfg++) {
                gBalance = cfg ? FIGHTSIM_TUNED_DEFAULTS : FIGHTSIM_SHIPPING_DEFAULTS;
                const char *cn = cfg ? "TU" : "SH";
                BuildSpec allin = { W[wi].name, W[wi].kind, LEATHER_ARMOR, NONE, NONE, (short)B, 0, 0, 0 };
                BuildSpec hyb   = { W[wi].name, W[wi].kind, LEATHER_ARMOR, STAFF_LIGHTNING, NONE,
                                    (short)wHyb, 0, (short)sE, 0 };
                sprintf(lbl, "%s,all-in,%s", W[wi].name, cn); runSustain(lbl, &allin, hp, strength, depth, seq, nSeq, trials);
                sprintf(lbl, "%s,hybrid,%s", W[wi].name, cn); runSustain(lbl, &hyb,   hp, strength, depth, seq, nSeq, trials);
            }
        }
        printf("\n");
    }
    gBalance = saved;
}

// Upgrade-path sanity check: after the nerf, does each heavy weapon still beat its lighter same-family
// counterpart (so the upgrade is still worth picking up)? Per family: light (unnerfed), heavy @ shipping,
// heavy @ tuned/nerfed -- all all-in at the depth budget, per archetype. Heavy@TU must stay >= light.
static void progression(int trials) {
    const int depths[] = {16, 19};
    struct { short light, heavy; const char *ln, *hn; } fam[] = {
        {SWORD, BROADSWORD, "sword",  "broadsword"},
        {SPEAR, PIKE,       "spear",  "war_pike"},
        {AXE,   WAR_AXE,    "axe",    "war_axe"},
        {MACE,  HAMMER,     "mace",   "war_hammer"}, // war hammer isn't nerfed; included for completeness
    };
    fs_buildBudgetTable(depths[(int)(sizeof depths/sizeof depths[0]) - 1], 8);
    balanceConfig saved = gBalance;
    for (int di = 0; di < (int)(sizeof depths/sizeof depths[0]); di++) {
        int depth = depths[di];
        DepthBudget bud = fs_budgetAt(depth);
        int B = (int)(bud.enchantScrolls + 0.5);
        int strength = 12 + (int)(bud.strengthPotions + 0.5);
        int hp = 30 + 10 * (int)(bud.lifePotions + 0.5);
        printf("# PROGRESSION @ depth %d (all-in +%d, str %d): does the nerfed heavy still beat its light "
               "counterpart? SH=shipping, TU=tuned/nerfed.\n", depth, B, strength);
        printf("config,corridor,cluster,pack,lone_tank,ambush,mean\n");
        char lbl[64];
        for (int f = 0; f < (int)(sizeof fam/sizeof fam[0]); f++) {
            gBalance = FIGHTSIM_TUNED_DEFAULTS; // light weapons are untouched by the levers
            sprintf(lbl, "%s(light)", fam[f].ln);
            printArchRow(lbl, fam[f].light, fam[f].ln, B, hp, strength, depth, trials);
            gBalance = FIGHTSIM_SHIPPING_DEFAULTS;
            sprintf(lbl, "%s(heavy)@SH", fam[f].hn);
            printArchRow(lbl, fam[f].heavy, fam[f].hn, B, hp, strength, depth, trials);
            gBalance = FIGHTSIM_TUNED_DEFAULTS;
            sprintf(lbl, "%s(heavy)@TU", fam[f].hn);
            printArchRow(lbl, fam[f].heavy, fam[f].hn, B, hp, strength, depth, trials);
        }
        printf("\n");
    }
    gBalance = saved;
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
    if (strcmp(mode, "--progression") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 40;
        progression(trials);
        return 0;
    }
    if (strcmp(mode, "--hybrid") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 30;
        hybridCompare(trials);
        return 0;
    }
    if (strcmp(mode, "--hybridsustain") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 30;
        hybridSustain(trials);
        return 0;
    }
    if (strcmp(mode, "--reachsweep") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 40;
        reachSweep(trials);
        return 0;
    }
    if (strcmp(mode, "--pikespeed") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 30;
        pikeSpeedSweep(trials);
        return 0;
    }
    if (strcmp(mode, "--tapersweep") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 30;
        taperSweep(trials);
        return 0;
    }
    if (strcmp(mode, "--tuned") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 40;
        tunedConfig(trials);
        return 0;
    }
    if (strcmp(mode, "--final") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 40;
        finalConfig(trials);
        return 0;
    }
    if (strcmp(mode, "--levertune") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 30;
        leverTune(trials);
        return 0;
    }
    if (strcmp(mode, "--archprofile") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 30;
        archProfile(trials);
        return 0;
    }
    if (strcmp(mode, "--capsweep") == 0) {
        int trials = (argc > 2) ? atoi(argv[2]) : 20;
        capSweep(trials);
        return 0;
    }
    if (strcmp(mode, "--weapons") == 0) {
        int depth   = (argc > 2) ? atoi(argv[2]) : 13;
        int trials  = (argc > 3) ? atoi(argv[3]) : 20;
        int cap     = (argc > 4) ? atoi(argv[4]) : 8;
        weaponRoster(depth, trials, cap);
        return 0;
    }
    if (strcmp(mode, "--tune") == 0) {
        int depth   = (argc > 2) ? atoi(argv[2]) : 17;
        int trials  = (argc > 3) ? atoi(argv[3]) : 30;
        int cap     = (argc > 4) ? atoi(argv[4]) : 8;  // tuned weapon enchant cap to compare vs baseline 50
        tuneThreeWay(depth, trials, cap);
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
