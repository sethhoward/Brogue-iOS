// Fight simulator — tunable balance constants.
//
// Phase 0: the struct and its shipping defaults are DEFINED here, and the
// self-test captures the engine's current formula outputs as goldens. The
// engine formula functions (PowerTables.c / Combat.c) do NOT yet read this —
// wiring them is the invasive, Xcode-project-touching refactor deferred to
// Phase 5 (see docs/design/fight-simulator.md §7, §11). Phases 0–1 run at
// shipping defaults, so nothing here changes engine behavior yet.
//
// When Phase 5 wires it, the rule is: defaults below MUST equal the current
// engine literals, proven byte-identical by the self-test goldens.

#ifndef FIGHTSIM_BALANCE_H
#define FIGHTSIM_BALANCE_H

typedef struct balanceConfig {
    // strengthModifier (Combat.c:65): over-req bonus +num/den per pt; under-req penalty -num/den.
    int strengthBonusNum,   strengthBonusDen;    // 1, 4   (+0.25/pt)
    int strengthPenaltyNum, strengthPenaltyDen;  // 5, 2   (-2.5/pt)
    // netEnchant clamp (Combat.c:79).
    int netEnchantClampLo, netEnchantClampHi;    // -20, 50
    // staffDamageHigh = base + slopeNum/slopeDen * e ; staffDamageLow = (2+e)*lowNum/lowDen.
    int staffDmgHighBase, staffDmgHighSlopeNum, staffDmgHighSlopeDen; // 4, 5, 2
    int staffDmgLowNum, staffDmgLowDen;          // 3, 4
    // SE lightning/firebolt ramp gate (PowerTables.c:62-72).
    int seRampThreshold;                         // 5
    // Per-weapon soft-knee enchant curve. heavyWeaponCap[kind] is the KNEE (full value up to it);
    // above it each point is worth only heavyWeaponSlopePct%. Per-kind (not a scalar) so each heavy
    // weapon can knee at a different value -- the tuned config knees war pike at 8 but broadsword at 9.
    // slope 0 == a hard cap (a cliff); slope 100 == no taper. knee 0 == untouched. Default all-0 =
    // nothing knee'd, so shipping is unchanged.
    int heavyWeaponCap[NUMBER_WEAPON_KINDS];      // {0} (off) -- the per-weapon knee
    int heavyWeaponSlopePct[NUMBER_WEAPON_KINDS]; // per-weapon marginal % above the knee: 0 == hard cap
                                                  // (cliff), 100 == no taper. Per-kind because weapons
                                                  // re-inflate differently -- war pike's primary hit
                                                  // scales hard, so it wants a gentle slope where the
                                                  // raw-stat generalists can take a full 25% taper.
    // Per-weapon melee recovery multiplier (percent), indexed by weapon kind. Scales the turn cost of
    // melee/pass/lunge actions (NOT zaps): >100 = slower to recover, <100 = faster. 0 == default (100%).
    // A mechanic-flavored, cliff-free lever -- e.g. a long/unwieldy war pike recovers slowly, scaling its
    // whole curve down uniformly instead of capping enchant. sim-only (cadence lives in sim.c's tick loop).
    int weaponRecoveryPct[NUMBER_WEAPON_KINDS];  // {0} (all default 100%)
    // Mechanic-specific damage levers (percent of normal, 100 = unchanged). The enchant cap is the
    // wrong tool for mechanic-driven weapons: war pike's penetrate is flat (cap-resistant) and flail's
    // pass-attacks multiply enchant across hits (cap is a cliff). So we trim those mechanics directly.
    // sim.c sets gFsDamageScalePct to these around the secondary hits; Combat.c reads it (see below).
    int penetrateDamagePct;                      // 100 (war pike behind-target hit, adjacent case)
    int passAttackDamagePct;                     // 100 (flail per-flanked-enemy hit while moving)
    int reachDamagePct;                          // 100 (spear/pike reach poke: distance-2 strike with
                                                 //      no adjacent foe -- the kite-the-approach benefit)
} balanceConfig;

#define FIGHTSIM_SHIPPING_DEFAULTS (balanceConfig){ \
    .strengthBonusNum = 1,   .strengthBonusDen = 4,   \
    .strengthPenaltyNum = 5, .strengthPenaltyDen = 2, \
    .netEnchantClampLo = -20, .netEnchantClampHi = 50, \
    .staffDmgHighBase = 4, .staffDmgHighSlopeNum = 5, .staffDmgHighSlopeDen = 2, \
    .staffDmgLowNum = 3, .staffDmgLowDen = 4, \
    .seRampThreshold = 5, \
    .heavyWeaponCap = {0}, .heavyWeaponSlopePct = {0}, .weaponRecoveryPct = {0}, \
    .penetrateDamagePct = 100, .passAttackDamagePct = 100, .reachDamagePct = 100, \
}

// The tuned balance config the simulator converged on (see docs/design/fight-simulator.md §"Tuning").
// Soft-knee the two raw-stat generalists (broadsword/war_axe), slow the pike (its power is throughput,
// not enchant -- so 2x recovery, not an enchant cap), and trim flail's pass-attack damage. Everything
// else untouched. Applied via --tuned; NOT the shipping default (shipping stays byte-identical).
#define FIGHTSIM_TUNED_DEFAULTS (balanceConfig){ \
    .strengthBonusNum = 1,   .strengthBonusDen = 4,   \
    .strengthPenaltyNum = 5, .strengthPenaltyDen = 2, \
    .netEnchantClampLo = -20, .netEnchantClampHi = 50, \
    .staffDmgHighBase = 4, .staffDmgHighSlopeNum = 5, .staffDmgHighSlopeDen = 2, \
    .staffDmgLowNum = 3, .staffDmgLowDen = 4, \
    .seRampThreshold = 5, \
    /* Soft knee: raw-stat generalists keep a full 25% taper past the knee (growth, no cliff). Pike */ \
    /* is NOT enchant-capped -- caps barely touch it; its power is throughput, so it's slowed instead. */ \
    .heavyWeaponCap      = { [BROADSWORD] = 9,  [WAR_AXE] = 10 }, \
    .heavyWeaponSlopePct = { [BROADSWORD] = 25, [WAR_AXE] = 25 }, \
    .weaponRecoveryPct   = { [PIKE] = 200 }, /* pike at 2x recovery: lands at band, restores pack weakness */ \
    .penetrateDamagePct = 100, .passAttackDamagePct = 50, .reachDamagePct = 100, \
}

extern balanceConfig gBalance; // = FIGHTSIM_SHIPPING_DEFAULTS (defined in fightsim.c)

// Runtime damage scale (percent) applied to the player's next weapon hit, then reset to 100 by sim.c.
// 100 by default so the engine is byte-identical until sim.c deliberately scales a secondary hit.
extern short gFsDamageScalePct;

#endif
