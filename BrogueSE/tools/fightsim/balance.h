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
} balanceConfig;

#define FIGHTSIM_SHIPPING_DEFAULTS (balanceConfig){ \
    .strengthBonusNum = 1,   .strengthBonusDen = 4,   \
    .strengthPenaltyNum = 5, .strengthPenaltyDen = 2, \
    .netEnchantClampLo = -20, .netEnchantClampHi = 50, \
    .staffDmgHighBase = 4, .staffDmgHighSlopeNum = 5, .staffDmgHighSlopeDen = 2, \
    .staffDmgLowNum = 3, .staffDmgLowDen = 4, \
    .seRampThreshold = 5, \
}

extern balanceConfig gBalance; // = FIGHTSIM_SHIPPING_DEFAULTS (defined in fightsim.c)

#endif
