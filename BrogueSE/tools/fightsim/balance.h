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
    // Per-weapon enchant cap (the heavy-weapon lever): an EXPLICIT set of weapon kinds (bitmask,
    // bit (1<<WEAPON_KIND)) whose net enchant is capped at heavyWeaponCap instead of netEnchantClampHi.
    // A bitmask (not a str-req threshold) so same-req weapons can be separated -- e.g. cap war axe but
    // not broadsword (both req 19). Default 0 = nothing capped, so shipping is unchanged.
    unsigned long heavyWeaponMask;               // 0 (off)
    int heavyWeaponCap;                          // 50
    // Mechanic-specific damage levers (percent of normal, 100 = unchanged). The enchant cap is the
    // wrong tool for mechanic-driven weapons: war pike's penetrate is flat (cap-resistant) and flail's
    // pass-attacks multiply enchant across hits (cap is a cliff). So we trim those mechanics directly.
    // sim.c sets gFsDamageScalePct to these around the secondary hits; Combat.c reads it (see below).
    int penetrateDamagePct;                      // 100 (war pike behind-target hit)
    int passAttackDamagePct;                     // 100 (flail per-flanked-enemy hit while moving)
} balanceConfig;

#define FIGHTSIM_SHIPPING_DEFAULTS (balanceConfig){ \
    .strengthBonusNum = 1,   .strengthBonusDen = 4,   \
    .strengthPenaltyNum = 5, .strengthPenaltyDen = 2, \
    .netEnchantClampLo = -20, .netEnchantClampHi = 50, \
    .staffDmgHighBase = 4, .staffDmgHighSlopeNum = 5, .staffDmgHighSlopeDen = 2, \
    .staffDmgLowNum = 3, .staffDmgLowDen = 4, \
    .seRampThreshold = 5, \
    .heavyWeaponMask = 0, .heavyWeaponCap = 50, \
    .penetrateDamagePct = 100, .passAttackDamagePct = 100, \
}

extern balanceConfig gBalance; // = FIGHTSIM_SHIPPING_DEFAULTS (defined in fightsim.c)

// Runtime damage scale (percent) applied to the player's next weapon hit, then reset to 100 by sim.c.
// 100 by default so the engine is byte-identical until sim.c deliberately scales a secondary hit.
extern short gFsDamageScalePct;

#endif
