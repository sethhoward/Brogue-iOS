// Fight simulator — encounter resolver (Phases 1-3).
#ifndef FIGHTSIM_SIM_H
#define FIGHTSIM_SIM_H
#include <stdint.h>

typedef struct {
    const char *name;
    short weaponKind;   // e.g. WAR_AXE / DAGGER, or -1 = none
    short armorKind;    // e.g. LEATHER_ARMOR, or -1 = none
    short staffKind;    // e.g. STAFF_LIGHTNING, or -1 = none
    short ringKind;     // e.g. RING_REAPING, or -1 = none
    short weaponEnchant, armorEnchant, staffEnchant, ringEnchant;
} BuildSpec;

// iOS port (Brogue SE): cursed-runics rework. When >= 0, the player weapon under test is given this
// runic (enchant2 + ITEM_RUNIC); -1 = no runic (default). A global rather than a BuildSpec field so the
// curse modes set it per-run without touching every existing initializer. runicCurseActive() keys
// cursed-vs-purified off enchant1 vs the purify threshold, so sweep enchant to walk the ramp.
extern short gFightsimWeaponRunic;

// Encounter geometry (Phase 3). Each places real monsters on a stub grid and uses
// straight-line-toward-player choreography; what differs is room shape + placement.
typedef enum {
    ARCH_CORRIDOR_LINE,   // 1-wide hall, monsters single-file (chokepoint; line-pierce)
    ARCH_FRENZY_CLUSTER,  // open room, monsters packed adjacent (axe cleave / chain / bloom)
    ARCH_SCATTERED_PACK,  // open room, monsters spread out (AOE devalued)
    ARCH_LONE_TANK,       // open room, one high-HP target (sustained single-target)
    ARCH_AMBUSH_RANGE,    // open room, monsters start far (kiting / staff range)
    ARCH_COUNT
} Archetype;

const char *fs_archetypeName(Archetype a);

typedef struct {
    int hpLost;
    int chargesSpent;
    int turns;
    int won;
    int endHP;       // player HP at encounter end (for sustain carryover)
    int endCharges;  // staff charges remaining
} EncounterResult;

// Run one encounter. Fully resets engine state from `seed` (common random numbers).
// startHP <= 0 means start at full (playerMaxHP); startCharges < 0 means full (staffEnchant).
// These let the Phase 4 sustain layer carry HP/charges across a sequence of encounters.
// depth <= 0: use monsterKind as given. depth > 0: pick a depth-appropriate monster from the
// horde catalog (frequency-weighted, deterministic per seed) and use that instead of monsterKind.
EncounterResult fs_run(const BuildSpec *b, Archetype arch, int playerMaxHP,
                       short monsterKind, int numMonsters, uint64_t seed,
                       int startHP, int startCharges, int strength /* <=0 => 12 */, int depth);

#endif
