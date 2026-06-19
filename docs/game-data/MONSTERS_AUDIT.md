# Brogue Monsters — Developer Audit

> **Generated entirely from the Brogue SE C source** (a fork of BrogueCE 1.15) embedded in this repo. Every
> number, flag, and relationship below was extracted directly from the code, not from
> memory of the game.
>
> **Primary source files:**
> - `BrogueSE/Engine/Globals.c` — `monsterCatalog`, `monsterText`, `mutationCatalog`, `monsterClassCatalog`
> - `BrogueSE/Engine/GlobalsBrogue.c` — `hordeCatalog_Brogue`, `brogueGameConst`
> - `BrogueSE/Engine/Rogue.h` — `creatureType` struct, `enum monsterTypes`, `enum boltType`, `enum monsterBehaviorFlags` (`MONST_*`), `enum monsterAbilityFlags` (`MA_*`), `enum hordeFlags`
> - `BrogueSE/Engine/Monsters.c` — `pickHordeType`, `spawnHorde`, `generateMonster`, `mutateMonster`, captive/ally handling
> - `BrogueSE/Engine/PowerTables.c` — power-scaling tables
>
> **Total monster count:** the `monsterCatalog` has **69 entries** (`NUMBER_MONSTER_KINDS`), of which **68 are monsters** and one (`MK_YOU`, index 0) is the player. Source: `Rogue.h:1071` (`enum monsterTypes`) and `Globals.c:1164` (`monsterCatalog`).

---

## 1. The `creatureType` struct

Source: `Rogue.h:2389`. Each `monsterCatalog` row is a `creatureType`:

| Field | Type | Meaning |
|---|---|---|
| `monsterID` | `enum monsterTypes` | index into the catalog (set to 0 in the literal; filled in at init) |
| `monsterName` | `char[COLS]` | display name |
| `displayChar` | `enum displayGlyph` | the glyph (e.g. `G_RAT`) |
| `foreColor` | `const color *` | foreground color |
| `maxHP` | `short` | maximum hit points |
| `defense` | `short` | defense (×10 internally for accuracy math; e.g. 70 ≈ +7 armor) |
| `accuracy` | `short` | base to-hit |
| `damage` | `randomRange` | `{lowerBound, upperBound, clumpFactor}` |
| `turnsBetweenRegen` | `long` | turns to regain 1 HP (`0` = no natural regen) |
| `movementSpeed` | `short` | ticks per move (100 = normal; 50 = double speed) |
| `attackSpeed` | `short` | ticks per attack (100 = normal; lower = faster) |
| `bloodType` | `enum dungeonFeatureTypes` | DF spawned as blood |
| `intrinsicLightType` | `enum lightType` | aura/light the monster emits |
| `isLarge` | `boolean` | size of psychic emanation (telepathy) |
| `DFChance` | `short` | % chance per awake turn to spawn `DFType` |
| `DFType` | `enum dungeonFeatureTypes` | terrain feature it leaves behind |
| `bolts[20]` | `enum boltType` | spells/bolts it can cast |
| `flags` | `unsigned long` | `MONST_*` behavior flags |
| `abilityFlags` | `unsigned long` | `MA_*` ability flags |

Speed note: `movementSpeed`/`attackSpeed` are tick durations. **Lower = faster.** 50 is "fast" (double), 100 normal, 200 "slow" (half), etc.

---

## 2. Master monster table

Source: `Globals.c:1164` (`monsterCatalog`). Damage shown as `low–high` (clump factor omitted unless >1). Speed columns are move/attack tick durations. "Regen" is `turnsBetweenRegen` (0 = none).

> **Glyph** = the in-game character + its catalog color. **Noise** = additive perception modifier for the noise system (ringless detection ≈ 25% + value; `—` = never emits movement noise). See ../design/noise-system.md.

| # | Monster | Glyph | Noise | HP | Def | Acc | Damage | Move | Atk | Regen | Bolts | Special abilities & flags (in play) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | rat | $\color{#808080}{\texttt{r}}$ | Normal | 6 | 0 | 80 | 1–3 | 100 | 100 | 20 | — | — |
| 2 | kobold | $\color{#705438}{\texttt{k}}$ | Normal | 7 | 0 | 80 | 1–4 | 100 | 100 | 20 | — | — |
| 3 | jackal | $\color{#996B45}{\texttt{j}}$ | Normal | 8 | 0 | 70 | 2–4 | 50 | 100 | 20 | — | Fast mover (double move speed) |
| 4 | eel | $\color{#4D1F1F}{\texttt{e}}$ | — *(submerged)* | 18 | 27 | 100 | 3–7 | 50 | 100 | 5 | — | Aquatic: confined to deep water, full speed there, submerges out of sight; moves erratically; always awake (`RESTRICTED_TO_LIQUID`, `IMMUNE_TO_WATER`, `SUBMERGES`, `FLITS`, `NEVER_SLEEPS`) |
| 5 | monkey | $\color{#994040}{\texttt{m}}$ | Quiet (−15) | 12 | 17 | 100 | 1–3 | 100 | 100 | 20 | — | Steals an item on hit, then flees (`MA_HIT_STEAL_FLEE`) |
| 6 | bloat | $\color{#BF40D9}{\texttt{b}}$ | Quiet (−15) | 4 | 0 | 100 | 0 | 100 | 100 | 5 | — | Drifts, never attacks; on death bursts into a caustic gas cloud (`MA_KAMIKAZE`, `MA_DF_ON_DEATH`; `FLIES`, `FLITS`) |
| 7 | pit bloat | $\color{#6666FF}{\texttt{b}}$ | Quiet (−15) | 4 | 0 | 100 | 0 | 100 | 100 | 5 | — | Drifts, never attacks; on death bursts open into a descent hole that drops everything nearby to the next floor (`MA_KAMIKAZE`, `MA_DF_ON_DEATH`; `FLIES`, `FLITS`) |
| 8 | goblin | $\color{#705438}{\texttt{g}}$ | Normal | 15 | 10 | 70 | 2–5 | 100 | 100 | 20 | — | Spear attack penetrates one layer, hitting two enemies in a line; avoids 1-wide corridors when hunting (`MA_ATTACKS_PENETRATE`, `MA_AVOID_CORRIDORS`) |
| 9 | goblin conjurer | $\color{#AB1AFF}{\texttt{g}}$ | Normal | 10 | 10 | 70 | 2–4 | 100 | 100 | 20 | — | Summons a swarm of spectral blades (die when it dies); keeps its distance, casts slowly, avoids corridors, sometimes carries an item (`MA_CAST_SUMMON`, `MAINTAINS_DISTANCE`, `CAST_SPELLS_SLOWLY`, `CARRY_ITEM_25`, `MA_AVOID_CORRIDORS`) |
| 10 | goblin mystic | $\color{#1AABFF}{\texttt{g}}$ | Normal | 10 | 10 | 70 | 2–4 | 100 | 100 | 20 | BOLT_SHIELDING | Shields its allies with a protective bolt; keeps its distance, avoids corridors, sometimes carries an item (`MAINTAINS_DISTANCE`, `CARRY_ITEM_25`, `MA_AVOID_CORRIDORS`) |
| 11 | goblin totem | ⚲ | — | 30 | 0 | 0 | 0 | 100 | 300 | 0 | BOLT_HASTE, BOLT_SPARK | Immobile camp totem: hastes goblins and zaps spark bolts; turret-like, never moves or sleeps, won't follow stairs (`IMMOBILE`, `INANIMATE`, `IMMUNE_TO_WEBS`, `NEVER_SLEEPS`, `WILL_NOT_USE_STAIRS`) |
| 12 | pink jelly | $\color{#FF6666}{\texttt{J}}$ | Normal | 50 | 0 | 85 | 1–3 | 100 | 100 | 0 | — | Splits into two jellies whenever struck; always awake (`MA_CLONE_SELF_ON_DEFEND`, `NEVER_SLEEPS`; isLarge) |
| 13 | toad | $\color{#66A64D}{\texttt{t}}$ | Normal | 18 | 0 | 90 | 1–4 | 100 | 100 | 10 | — | Hit causes hallucination (`MA_HIT_HALLUCINATE`) |
| 14 | vampire bat | $\color{#808080}{\texttt{v}}$ | Quiet (−15) | 18 | 25 | 100 | 2–6 | 50 | 100 | 20 | — | Drains life, healing itself for a share of damage dealt; flies and flits erratically; fast mover (`MA_TRANSFERENCE`, `FLIES`, `FLITS`) |
| 15 | arrow turret | $\color{#000000}{\bullet}$ | — | 30 | 0 | 90 | 2–6 | 100 | 250 | 0 | BOLT_DISTANCE_ATTACK | Wall-embedded turret: fires arrows at range, can't move, attackable through walls (`MONST_TURRET`) |
| 16 | acid mound | $\color{#26CC40}{\texttt{a}}$ | Quiet (−15) | 15 | 10 | 70 | 1–3 | 100 | 100 | 5 | — | Corrodes your weapon when you hit it and your armor when it hits you (`DEFEND_DEGRADE_WEAPON`, `MA_HIT_DEGRADE_ARMOR`) |
| 17 | centipede | $\color{#BF40D9}{\texttt{c}}$ | Normal | 20 | 20 | 80 | 4–12 | 100 | 100 | 20 | — | Bite saps your strength (weakness status, ~300 turns) (`MA_CAUSES_WEAKNESS`) |
| 18 | ogre | $\color{#994040}{\texttt{O}}$ | Loud (+15) | 55 | 60 | 125 | 9–13 | 100 | 200 | 20 | — | Heavy blow knocks the target back one space; avoids corridors (`MA_ATTACKS_STAGGER`, `MA_AVOID_CORRIDORS`; MALE/FEMALE) |
| 19 | bog monster | $\color{#FF8C8C}{\texttt{B}}$ | — *(submerged)* | 55 | 60 | 5000 | 3–4 | 200 | 100 | 3 | — | Lurks submerged in mud, seizes and holds prey before attacking; moves erratically, flees near death (`MA_SEIZES`, `RESTRICTED_TO_LIQUID`, `SUBMERGES`, `FLITS`, `FLEES_NEAR_DEATH`; isLarge) |
| 20 | ogre totem | ⚲ | — | 70 | 0 | 0 | 0 | 100 | 400 | 0 | BOLT_HEALING, BOLT_SLOW_2 | Immobile camp totem: heals ogres and slows intruders; turret-like, never moves or sleeps (`IMMOBILE`, `INANIMATE`, `NEVER_SLEEPS`, …) |
| 21 | spider | $\color{#FFFFFF}{\texttt{s}}$ | Quiet (−15) | 20 | 70 | 90 | 3–4(c2) | 100 | 200 | 20 | BOLT_SPIDERWEB | Shoots sticky webs to pin you, then poisons with each bite; immune to its own webs, never misfires its ability, casts slowly (`MA_POISONS`, `IMMUNE_TO_WEBS`, `ALWAYS_USE_ABILITY`, `CAST_SPELLS_SLOWLY`) |
| 22 | spark turret | $\color{#FFFFFF}{\bullet}$ | — | 80 | 0 | 100 | 0 | 100 | 150 | 0 | BOLT_SPARK | Wall-embedded turret: fires lightning bolts, can't move, attackable through walls (`MONST_TURRET`) |
| 23 | wisp (will-o-the-wisp) | $\color{#BFFFFF}{\texttt{w}}$ | Silent (−30) | 10 | 90 | 100 | 0 | 100 | 100 | 5 | — | Burning aura sets you on fire on contact; immune to fire, flies and flits, always awake, dies if negated (`MA_HIT_BURN`, `FIERY`, `IMMUNE_TO_FIRE`, `FLIES`, `FLITS`, `NEVER_SLEEPS`, `DIES_IF_NEGATED`) |
| 24 | wraith | $\color{#A8A840}{\texttt{W}}$ | Quiet (−15) | 50 | 60 | 120 | 6–13 | 50 | 100 | 5 | — | Fast mover; flees near death (`FLEES_NEAR_DEATH`; isLarge) |
| 25 | zombie | $\color{#99800D}{\texttt{Z}}$ | Normal | 80 | 0 | 120 | 7–12 | 100 | 100 | 0 | — | Constantly belches nauseating rot gas (DFChance 100 → DF_ROT_GAS_PUFF); isLarge |
| 26 | troll | $\color{#669926}{\texttt{T}}$ | Loud (+15) | 65 | 70 | 125 | 10–15(c3) | 100 | 100 | **1** | — | Regenerates extremely fast (1 turn/HP) (MALE/FEMALE; isLarge) |
| 27 | ogre shaman | $\color{#00FF00}{\texttt{O}}$ | Loud (+15) | 45 | 40 | 100 | 5–9 | 100 | 200 | 20 | BOLT_HASTE, BOLT_SPARK | Summons ogre reinforcements and hastes them; keeps its distance, casts slowly, avoids corridors (`MA_CAST_SUMMON`, `MAINTAINS_DISTANCE`, `CAST_SPELLS_SLOWLY`, `MA_AVOID_CORRIDORS`; MALE/FEMALE; isLarge) |
| 28 | naga | $\color{#669926}{\texttt{N}}$ | Normal | 75 | 70 | 150 | 7–11(c4) | 100 | 100 | 10 | — | Axe-like sweep hits all adjacent enemies; submerges in deep water, leaves puddles, always awake (`MA_ATTACKS_ALL_ADJACENT`, `IMMUNE_TO_WATER`, `SUBMERGES`, `NEVER_SLEEPS`; DFChance 100 → DF_PUDDLE; FEMALE; isLarge) |
| 29 | salamander | $\color{#661A00}{\texttt{S}}$ | Normal | 60 | 70 | 150 | 5–11(c3) | 100 | 100 | 10 | — | Whip-like fiery attack reaches at range in a line; immune to fire, submerges in lava, leaves flames, always awake (`MA_ATTACKS_EXTEND`, `FIERY`, `IMMUNE_TO_FIRE`, `SUBMERGES`, `NEVER_SLEEPS`; DFChance 100 → DF_SALAMANDER_FLAME; MALE; isLarge) |
| 30 | explosive bloat | $\color{#FF8000}{\texttt{b}}$ | Quiet (−15) | 10 | 0 | 100 | 0 | 100 | 100 | 5 | — | Drifts, never attacks; on death detonates in a violent fiery explosion (`MA_KAMIKAZE`, `MA_DF_ON_DEATH`; `FLIES`, `FLITS`) |
| 31 | dar blademaster | $\color{#FF00FF}{\texttt{d}}$ | Quiet (−15) | 35 | 70 | 160 | 5–9(c2) | 100 | 100 | 20 | BOLT_BLINKING | Blinks (short-range teleport) to close or reposition; avoids corridors, sometimes carries an item (`BOLT_BLINKING`, `MA_AVOID_CORRIDORS`, `CARRY_ITEM_25`; MALE/FEMALE) |
| 32 | dar priestess | $\color{#008080}{\texttt{d}}$ | Quiet (−15) | 20 | 60 | 100 | 2–5 | 100 | 100 | 20 | BOLT_NEGATION, BOLT_HEALING, BOLT_HASTE, BOLT_SPARK | Support caster: negates, heals and hastes allies, zaps spark; keeps its distance, avoids corridors (`MAINTAINS_DISTANCE`, `MA_AVOID_CORRIDORS`, `CARRY_ITEM_25`; FEMALE) |
| 33 | dar battlemage | $\color{#808000}{\texttt{d}}$ | Quiet (−15) | 20 | 60 | 100 | 1–3 | 100 | 100 | 20 | BOLT_FIRE, BOLT_SLOW_2, BOLT_DISCORD | Offensive caster: hurls fire, slows and sows discord; keeps its distance, avoids corridors (`MAINTAINS_DISTANCE`, `MA_AVOID_CORRIDORS`, `CARRY_ITEM_25`; MALE/FEMALE) |
| 34 | acidic jelly | $\color{#26CC40}{\texttt{J}}$ | Normal | 60 | 0 | 115 | 2–6 | 100 | 100 | 0 | — | Splits in two when struck; corrodes your weapon when hit and your armor on its hit (`MA_CLONE_SELF_ON_DEFEND`, `DEFEND_DEGRADE_WEAPON`, `MA_HIT_DEGRADE_ARMOR`; isLarge) |
| 35 | centaur | $\color{#CCAB26}{\texttt{C}}$ | Loud (+15) | 35 | 50 | 175 | 4–8(c2) | 50 | 100 | 20 | BOLT_DISTANCE_ATTACK | Fires arrows at range; keeps its distance; fast mover (`BOLT_DISTANCE_ATTACK`, `MAINTAINS_DISTANCE`; MALE; isLarge) |
| 36 | underworm | $\color{#CC9966}{\texttt{U}}$ | Booming (+30) | 80 | 40 | 160 | 18–22(c2) | 150 | 200 | 3 | — | Slow but hits very hard; always awake (`NEVER_SLEEPS`; isLarge; slow) |
| 37 | sentinel | $\color{#08084D}{\text{ß}}$ | — | 50 | 0 | 0 | 0 | 100 | 175 | 0 | BOLT_HEALING, BOLT_SPARK | Immobile turret that heals its fellow sentinels (found in groups) and zaps spark; casts slowly, dies if negated (`MONST_TURRET`, `CAST_SPELLS_SLOWLY`, `DIES_IF_NEGATED`) |
| 38 | dart turret | $\color{#BF40D9}{\bullet}$ | — | 20 | 0 | 140 | 1–2 | 100 | 250 | 0 | BOLT_POISON_DART | Wall-embedded turret: fires darts that sap strength (weakness); can't move (`MONST_TURRET`, `MA_CAUSES_WEAKNESS`) |
| 39 | kraken | $\color{#FF8C8C}{\texttt{K}}$ | — *(submerged)* | 120 | 0 | 150 | 15–20(c3) | 50 | 100 | **1** | — | Aquatic ambusher: seizes and holds prey, lurks submerged in deep water; moves erratically, flees near death, regenerates fast (`MA_SEIZES`, `RESTRICTED_TO_LIQUID`, `IMMUNE_TO_WATER`, `SUBMERGES`, `FLITS`, `NEVER_SLEEPS`, `FLEES_NEAR_DEATH`; isLarge) |
| 40 | lich | $\color{#FFFFFF}{\texttt{L}}$ | Quiet (−15) | 35 | 80 | 175 | 2–6 | 100 | 100 | 0 | BOLT_FIRE | Summons phantoms and furies and hurls fire; anchored to a phylactery, so killing it spawns the phylactery rather than truly dying; can't be polymorphed (`MA_CAST_SUMMON`, `MAINTAINS_DISTANCE`, `NO_POLYMORPH`, `CARRY_ITEM_25`; isLarge) |
| 41 | phylactery | $\color{#00CC4D}{\bullet}$ | — | 30 | 0 | 0 | 0 | 100 | 150 | 0 | — | The lich's anchor: re-summons the lich and "becomes" it until destroyed; immobile, always hunting, dies if negated (`MA_CAST_SUMMON`, `MA_ENTER_SUMMONS`, `IMMOBILE`, `INANIMATE`, `ALWAYS_HUNTING`, `NEVER_SLEEPS`, `WILL_NOT_USE_STAIRS`, `DIES_IF_NEGATED`) |
| 42 | pixie | $\color{#999999}{\texttt{p}}$ | Quiet (−15) | 10 | 90 | 100 | 1–3 | 50 | 100 | 20 | BOLT_NEGATION, BOLT_SLOW_2, BOLT_DISCORD, BOLT_SPARK | Flitting caster: negates, slows, sows discord, zaps spark; keeps its distance, flies erratically; fast mover (`MAINTAINS_DISTANCE`, `FLIES`, `FLITS`; MALE/FEMALE) |
| 43 | phantom | $\color{#73338C}{\texttt{P}}$ | Silent (−30) | 35 | 70 | 160 | 12–18(c4) | 50 | 200 | 0 | — | Invisible; flies and flits erratically; immune to webs; fast mover (`INVISIBLE`, `FLIES`, `FLITS`, `IMMUNE_TO_WEBS`; DFChance 2 → ectoplasm droplet; isLarge) |
| 44 | flame turret | $\color{#333333}{\bullet}$ | — | 40 | 0 | 150 | 1–2 | 100 | 250 | 0 | BOLT_FIRE | Wall-embedded turret: spits fire bolts, can't move (`MONST_TURRET`) |
| 45 | imp | $\color{#FF99A8}{\texttt{i}}$ | Quiet (−15) | 35 | 90 | 225 | 4–9(c2) | 100 | 100 | 10 | BOLT_BLINKING | Steals an item on hit, then blinks (teleports) away (`MA_HIT_STEAL_FLEE`, `BOLT_BLINKING`) |
| 46 | fury | $\color{#800000}{\texttt{f}}$ | Loud (+15) | 19 | 90 | 200 | 6–11(c4) | 50 | 100 | 20 | — | Relentless flying attacker; always awake; fast mover (`NEVER_SLEEPS`, `FLIES`) |
| 47 | revenant | $\color{#73338C}{\texttt{R}}$ | Normal | 30 | 0 | 200 | 15–20(c5) | 100 | 100 | 0 | — | Immune to physical weapons (only magic/fire harms it) (`IMMUNE_TO_WEAPONS`; isLarge) |
| 48 | tentacle horror | $\color{#BF40D9}{\texttt{H}}$ | Booming (+30) | 120 | 95 | 225 | 25–35(c3) | 100 | 100 | **1** | — | Hits very hard and regenerates extremely fast (1 turn/HP); isLarge |
| 49 | golem | $\color{#808080}{\texttt{G}}$ | Booming (+30) | 400 | 70 | 225 | 4–8 | 100 | 100 | 0 | — | Huge HP, no regen; reflects ~50% of bolts back; dies if negated (`REFLECT_50`, `DIES_IF_NEGATED`; isLarge) |
| 50 | dragon | $\color{#33CC26}{\texttt{D}}$ | Booming (+30) | 150 | 90 | 250 | 25–50(c4) | 50 | 200 | 20 | BOLT_DRAGONFIRE | Breathes a cone of dragonfire; axe-like sweep hits all adjacent enemies; immune to fire, fast mover, carries an item (`MA_ATTACKS_ALL_ADJACENT`, `IMMUNE_TO_FIRE`, `CARRY_ITEM_100`; isLarge) |
| **bosses** | | | | | | | | | | | | |
| 51 | goblin warlord | $\color{#0000FF}{\texttt{g}}$ | Normal | 30 | 17 | 100 | 3–6 | 100 | 100 | 20 | — | Summons goblins (a conjurer plus a pack, arriving from across the level); spear attack penetrates a line; keeps its distance, avoids corridors, may carry an item (`MA_CAST_SUMMON`, `MA_ATTACKS_PENETRATE`, `MAINTAINS_DISTANCE`, `MA_AVOID_CORRIDORS`, `CARRY_ITEM_25`) |
| 52 | black jelly | $\color{#000000}{\texttt{J}}$ | Normal | 120 | 0 | 130 | 3–8 | 100 | 100 | 0 | — | Splits in two whenever struck (`MA_CLONE_SELF_ON_DEFEND`; isLarge) |
| 53 | vampire | $\color{#FFFFFF}{\texttt{V}}$ | Quiet (−15) | 75 | 60 | 120 | 4–15(c2) | 50 | 100 | 6 | BOLT_BLINKING, BOLT_DISCORD | Drains life to heal itself; on death bursts into a cloud of bats and reforms from them; summons bats, blinks away, sows discord; flees near death (`MA_TRANSFERENCE`, `MA_DF_ON_DEATH`, `MA_ENTER_SUMMONS`, `MA_CAST_SUMMON`, `BOLT_BLINKING`, `FLEES_NEAR_DEATH`; MALE; isLarge) |
| 54 | flamedancer | $\color{#FFFFFF}{\texttt{F}}$ | Loud (+15) | 65 | 80 | 120 | 3–8(c2) | 100 | 100 | 0 | BOLT_FIRE | Hurls fire bolts and burns you on contact; immune to fire, fiery aura; keeps its distance (`BOLT_FIRE`, `MA_HIT_BURN`, `FIERY`, `IMMUNE_TO_FIRE`, `MAINTAINS_DISTANCE`; isLarge) |
| **special-effect monsters** | | | | | | | | | | | | |
| 55 | spectral blade | $\color{#262699}{\uparrow}$ | Silent (−30) | 1 | 0 | 150 | 1 | 50 | 100 | 0 | — | Conjurer's summoned blade: flies, never sleeps, dies if negated, hidden from sidebar (`INANIMATE`, `NEVER_SLEEPS`, `FLIES`, `WILL_NOT_USE_STAIRS`, `DIES_IF_NEGATED`, `IMMUNE_TO_WEBS`, `NOT_LISTED_IN_SIDEBAR`) |
| 56 | spectral sword (image) | $\color{#210000}{\uparrow}$ | Silent (−30) | 1 | 0 | 150 | 1 | 50 | 100 | 0 | — | Conjured duplicate blade: flies, never sleeps, dies if negated (`INANIMATE`, `NEVER_SLEEPS`, `FLIES`, `WILL_NOT_USE_STAIRS`, `DIES_IF_NEGATED`, `IMMUNE_TO_WEBS`) |
| 57 | stone guardian | $\color{#FFFFFF}{\text{ß}}$ | — | 1000 | 0 | 200 | 12–17(c2) | 100 | 100 | 0 | — | Puzzle statue: only acts when its glyph is activated, mirrors your movement; reflects 100% of bolts; immune to weapons and fire, dies if negated (`MA_REFLECT_100`, `GETS_TURN_ON_ACTIVATION`, `IMMUNE_TO_WEAPONS`, `IMMUNE_TO_FIRE`, `ALWAYS_HUNTING`, `DIES_IF_NEGATED`, `ALWAYS_USE_ABILITY`; INANIMATE) |
| 58 | winged guardian | $\color{#0000FF}{\text{ß}}$ | — | 1000 | 0 | 200 | 12–17(c2) | 100 | 100 | 0 | BOLT_BLINKING | As stone guardian, but blinks/teleports when activated instead of stepping (`BOLT_BLINKING`; otherwise same flags) |
| 59 | guardian spirit | $\color{#210000}{\text{ß}}$ | — | 1000 | 0 | 200 | 5–12(c2) | 100 | 100 | 0 | — | Charm-summoned guardian: reflects 100% of bolts; immune to weapons and fire, dies if negated (`MA_REFLECT_100`, `IMMUNE_TO_WEAPONS`, `IMMUNE_TO_FIRE`, `DIES_IF_NEGATED`, `ALWAYS_USE_ABILITY`; INANIMATE) |
| 60 | Warden of Yendor | $\color{#80004D}{\texttt{Y}}$ | Booming (+30) | 1000 | 0 | 300 | 12–17(c2) | 200 | 200 | 0 | — | Invulnerable to absolutely everything; relentless, never-sleeping hunter; can't be polymorphed (`INVULNERABLE`, `ALWAYS_HUNTING`, `NEVER_SLEEPS`, `NO_POLYMORPH`; isLarge) |
| 61 | eldritch totem | ⚲ | — | 80 | 0 | 0 | 0 | 100 | 100 | 0 | — | Activated puzzle totem that summons spectral blades and furies (die with it); immobile, always hunting (`MA_CAST_SUMMON`, `IMMOBILE`, `INANIMATE`, `ALWAYS_HUNTING`, `NEVER_SLEEPS`, `WILL_NOT_USE_STAIRS`, `GETS_TURN_ON_ACTIVATION`, `ALWAYS_USE_ABILITY`) |
| 62 | mirrored totem | ⚲ | — | 80 | 0 | 0 | 0 | 100 | 100 | 0 | BOLT_BECKONING | Activated puzzle totem: reflects 100% of bolts and beckons you toward it; immobile, immune to weapons and fire (`MA_REFLECT_100`, `BOLT_BECKONING`, `IMMOBILE`, `INANIMATE`, `ALWAYS_HUNTING`, `IMMUNE_TO_WEAPONS`, `IMMUNE_TO_FIRE`, `GETS_TURN_ON_ACTIVATION`, `ALWAYS_USE_ABILITY`) |
| **legendary allies** | | | | | | | | | | | | |
| 63 | unicorn | $\color{#FFFFFF}{\text{Ú}}$ | Normal | 40 | 60 | 175 | 2–10(c2) | 50 | 100 | 20 | BOLT_HEALING, BOLT_SHIELDING | Heals and shields the player; keeps its distance; fast mover (`BOLT_HEALING`, `BOLT_SHIELDING`, `MAINTAINS_DISTANCE`; DFChance 1 → unicorn poop; MALE/FEMALE; isLarge) |
| 64 | ifrit | $\color{#801AFF}{\texttt{I}}$ | Quiet (−15) | 40 | 75 | 175 | 5–13(c2) | 50 | 100 | **1** | BOLT_DISCORD | Sows discord among enemies; immune to fire, flies; fast mover, regenerates fast (`BOLT_DISCORD`, `IMMUNE_TO_FIRE`, `FLIES`; MALE; isLarge) |
| 65 | phoenix | $\color{#FF0000}{\texttt{P}}$ | Quiet (−15) | 30 | 70 | 175 | 4–10(c2) | 50 | 100 | 0 | — | Immune to fire, flies; on death leaves a phoenix egg from which it is reborn; can't be polymorphed (`IMMUNE_TO_FIRE`, `FLIES`, `NO_POLYMORPH`; isLarge) |
| 66 | phoenix egg | $\color{#FF0000}{\bullet}$ | — | 50 | 0 | 0 | 0 | 100 | 150 | 0 | — | Hatches a new phoenix and "becomes" it; immobile, always hunting, immune to fire and weapons (`MA_CAST_SUMMON`, `MA_ENTER_SUMMONS`, `IMMUNE_TO_FIRE`, `IMMUNE_TO_WEAPONS`, `IMMOBILE`, `INANIMATE`, `ALWAYS_HUNTING`, `NEVER_SLEEPS`, `WILL_NOT_USE_STAIRS`, `NO_POLYMORPH`, `IMMUNE_TO_WEBS`) |
| 67 | mangrove dryad (ancient spirit) | $\color{#CCAB26}{\texttt{M}}$ | Quiet (−15) | 70 | 60 | 175 | 2–8(c2) | 100 | 100 | 6 | BOLT_ANCIENT_SPIRIT_VINES | Entangles enemies with grasping vines; keeps its distance, immune to webs, can't be polymorphed (`BOLT_ANCIENT_SPIRIT_VINES`, `ALWAYS_USE_ABILITY`, `MAINTAINS_DISTANCE`, `IMMUNE_TO_WEBS`, `NO_POLYMORPH`; MALE/FEMALE; isLarge) |

`MK_YOU` (the player, index 0) is also a `monsterCatalog` row: HP 30, def 0, acc 100, dmg 1–2, regen 20, flags `MONST_MALE | MONST_FEMALE`. Source `Globals.c:1166`.

---

## 3. `MONST_*` behavior flags (complete reference)

Source: `Rogue.h:2185` (`enum monsterBehaviorFlags`). All bits via `Fl(n)`.

| Flag | Bit | Meaning |
|---|---|---|
| `MONST_INVISIBLE` | 0 | monster is invisible |
| `MONST_INANIMATE` | 1 | abbreviated stat bar; immune to many status effects |
| `MONST_IMMOBILE` | 2 | won't move or melee |
| `MONST_CARRY_ITEM_100` | 3 | always carries an item |
| `MONST_CARRY_ITEM_25` | 4 | 25% chance to carry an item |
| `MONST_ALWAYS_HUNTING` | 5 | never asleep or wandering |
| `MONST_FLEES_NEAR_DEATH` | 6 | flees under 25% HP, re-engages over 75% |
| `MONST_ATTACKABLE_THRU_WALLS` | 7 | can be attacked while embedded in a wall |
| `MONST_DEFEND_DEGRADE_WEAPON` | 8 | hitting it damages your weapon |
| `MONST_IMMUNE_TO_WEAPONS` | 9 | weapons are ineffective against it |
| `MONST_FLIES` | 10 | permanent levitation |
| `MONST_FLITS` | 11 | moves randomly ~⅓ of the time |
| `MONST_IMMUNE_TO_FIRE` | 12 | won't burn, survives lava |
| `MONST_CAST_SPELLS_SLOWLY` | 13 | spell casting takes 2× attack duration |
| `MONST_IMMUNE_TO_WEBS` | 14 | passes freely through webs |
| `MONST_REFLECT_50` | 15 | reflects ~50% of bolts (like +4 armor of reflection) |
| `MONST_NEVER_SLEEPS` | 16 | always awake |
| `MONST_FIERY` | 17 | carries an aura of flame |
| `MONST_INVULNERABLE` | 18 | immune to everything |
| `MONST_IMMUNE_TO_WATER` | 19 | full speed in deep water; doesn't drop items there |
| `MONST_RESTRICTED_TO_LIQUID` | 20 | can only occupy submersible tiles |
| `MONST_SUBMERGES` | 21 | can submerge in suitable terrain |
| `MONST_MAINTAINS_DISTANCE` | 22 | tries to keep 3 tiles between it and the player |
| `MONST_WILL_NOT_USE_STAIRS` | 23 | won't follow the player between levels |
| `MONST_DIES_IF_NEGATED` | 24 | dies if hit with negation |
| `MONST_MALE` | 25 | male (50% if both MALE+FEMALE set) |
| `MONST_FEMALE` | 26 | female (50% if both set) |
| `MONST_NOT_LISTED_IN_SIDEBAR` | 27 | hidden from the sidebar |
| `MONST_GETS_TURN_ON_ACTIVATION` | 28 | only acts when its machine is activated |
| `MONST_ALWAYS_USE_ABILITY` | 29 | never randomly fails to use its special ability |
| `MONST_NO_POLYMORPH` | 30 | can't be produced by polymorph (lich, phoenix, Warden) |

**Composite/derived sets** (same source):

| Composite | Members |
|---|---|
| `NEGATABLE_TRAITS` | INVISIBLE, DEFEND_DEGRADE_WEAPON, IMMUNE_TO_WEAPONS, FLIES, FLITS, IMMUNE_TO_FIRE, REFLECT_50, FIERY, MAINTAINS_DISTANCE |
| `MONST_TURRET` | IMMUNE_TO_WEBS, NEVER_SLEEPS, IMMOBILE, INANIMATE, ATTACKABLE_THRU_WALLS, WILL_NOT_USE_STAIRS |
| `LEARNABLE_BEHAVIORS` | INVISIBLE, FLIES, IMMUNE_TO_FIRE, REFLECT_50 (gained via empowerment/absorption) |
| `MONST_NEVER_VORPAL_ENEMY` | INANIMATE, INVULNERABLE, IMMOBILE, RESTRICTED_TO_LIQUID, GETS_TURN_ON_ACTIVATION, MAINTAINS_DISTANCE |
| `MONST_NEVER_MUTATED` | INVISIBLE, INANIMATE, IMMOBILE, INVULNERABLE |

---

## 4. `MA_*` ability flags (complete reference)

Source: `Rogue.h:2233` (`enum monsterAbilityFlags`).

| Flag | Bit | Meaning |
|---|---|---|
| `MA_HIT_HALLUCINATE` | 0 | hit causes hallucination |
| `MA_HIT_STEAL_FLEE` | 1 | steals an item, then runs |
| `MA_HIT_BURN` | 2 | hit sets you on fire |
| `MA_ENTER_SUMMONS` | 3 | "becomes" its summoned leader, reappearing when that leader dies (phylactery, phoenix egg, vampire) |
| `MA_HIT_DEGRADE_ARMOR` | 4 | hit damages armor |
| `MA_CAST_SUMMON` | 5 | summons a horde whose leader is this monster type |
| `MA_SEIZES` | 6 | seizes/holds enemies before attacking |
| `MA_POISONS` | 7 | damage is dealt as poison |
| `MA_DF_ON_DEATH` | 8 | spawns its `DFType` on death |
| `MA_CLONE_SELF_ON_DEFEND` | 9 | splits in two when struck |
| `MA_KAMIKAZE` | 10 | dies instead of attacking |
| `MA_TRANSFERENCE` | 11 | recovers 40% or 90% of damage dealt as HP |
| `MA_CAUSES_WEAKNESS` | 12 | attacks cause weakness status |
| `MA_ATTACKS_PENETRATE` | 13 | attacks penetrate one layer of enemies (spear) |
| `MA_ATTACKS_ALL_ADJACENT` | 14 | attacks all adjacent enemies (axe) |
| `MA_ATTACKS_EXTEND` | 15 | attacks at range in a cardinal direction (whip) |
| `MA_ATTACKS_STAGGER` | 16 | attack pushes the target back one space if room |
| `MA_AVOID_CORRIDORS` | 17 | avoids corridors when hunting |
| `MA_REFLECT_100` | 18 | reflects 100% of bolts back at the caster |

> Note: the `MA_ATTACKS_PENETRATE` and `MA_ATTACKS_ALL_ADJACENT` *comment wording* in the header is swapped relative to the constant names — per the inline comments, `MA_ATTACKS_PENETRATE` reads "attacks all adjacent … like an axe" and `MA_ATTACKS_ALL_ADJACENT` reads "penetrate one layer … like a spear." The names are what the engine actually keys on; this audit lists the conventional semantics (penetrate = spear, all-adjacent = axe). Treat the header comments with care.

**Composite/derived sets:**

| Composite | Members |
|---|---|
| `SPECIAL_HIT` | HIT_HALLUCINATE, HIT_STEAL_FLEE, HIT_DEGRADE_ARMOR, POISONS, TRANSFERENCE, CAUSES_WEAKNESS, HIT_BURN, ATTACKS_STAGGER |
| `LEARNABLE_ABILITIES` | TRANSFERENCE, CAUSES_WEAKNESS |
| `MA_NON_NEGATABLE_ABILITIES` | ATTACKS_PENETRATE, ATTACKS_ALL_ADJACENT, ATTACKS_EXTEND, ATTACKS_STAGGER |
| `MA_NEVER_VORPAL_ENEMY` | KAMIKAZE |
| `MA_NEVER_MUTATED` | KAMIKAZE |

---

## 5. Mutation catalog

Source: `Globals.c:1545` (`mutationCatalog`, `NUMBER_MUTATORS = 8`). Factors are percentages applied multiplicatively (e.g. healthFactor 300 = ×3 HP). `DFChance = -1` means "leave unchanged." A mutation is skipped if the monster already has any `forbiddenFlags`/`forbiddenAbilityFlags`.

| Mutation | HP% | Move% | Atk% | Def% | Dmg% | Adds flags | DF / light | Forbidden on | Negatable | Effect |
|---|---|---|---|---|---|---|---|---|---|---|
| **explosive** | 50 | 100 | 100 | 50 | 100 | `MA_DF_ON_DEATH` | DF_MUTATION_EXPLOSION, explosive-bloat light | SUBMERGES | yes | explodes violently on death |
| **infested** | 50 | 100 | 100 | 50 | 100 | `MA_DF_ON_DEATH` | DF_MUTATION_LICHEN | — | yes | poisonous lichen spreads from corpse |
| **agile** | 100 | 50 | 100 | 150 | 100 | `MONST_FLEES_NEAR_DEATH` | — | FLEES_NEAR_DEATH | no | much faster + higher defense |
| **juggernaut** | 300 | 200 | 200 | 75 | 200 | `MA_ATTACKS_STAGGER` | — | MAINTAINS_DISTANCE | no | huge HP/damage but slow |
| **grappling** | 150 | 100 | 100 | 50 | 100 | `MA_SEIZES` | — | MAINTAINS_DISTANCE / (ability) MA_SEIZES | yes | extra HP + grapples prey |
| **vampiric** | 100 | 100 | 100 | 100 | 100 | `MA_TRANSFERENCE` | — | MAINTAINS_DISTANCE / MA_TRANSFERENCE | yes | heals with every attack |
| **toxic** | 100 | 100 | 200 | 100 | 20 | `MA_CAUSES_WEAKNESS | MA_POISONS` | — | MAINTAINS_DISTANCE / (CAUSES_WEAKNESS|POISONS) | yes | poisons + saps strength |
| **reflective** | 100 | 100 | 100 | 100 | 100 | `MONST_REFLECT_50` | — | REFLECT_50 / (ability) ALWAYS_USE_ABILITY | yes | reflective scales (50% bolt reflect) |

### When monsters get mutated

Source: `Monsters.c:58` (`generateMonster`) and `Monsters.c:28` (`mutateMonster`). Constants from `brogueGameConst` (`GlobalsBrogue.c:1061`): `mutationsOccurAboveLevel = 10`, `depthAccelerator = 1`, `amuletLevel`.

- A monster can be mutated only if `mutationPossible`, it lacks `MONST_NEVER_MUTATED`/`MA_NEVER_MUTATED`, **and** `rogue.depthLevel > 10`.
- **Depths 11 → amulet level:** `mutationChance = clamp((depth − 10) × depthAccelerator, 1, 10)` percent — so 1% at depth 11 rising to 10% by depth 20+.
- **Below the amulet level:** `mutationChance = POW_DEEP_MUTATION[min(depth − amuletLevel, 12)]`, where `POW_DEEP_MUTATION[] = {11,13,16,18,21,25,30,35,41,48,56,65,76}` (= `1.17^x × 10`), capped at **75%**.
- If the roll succeeds, one of the 8 mutations is chosen at random; it applies only if not on the monster's forbidden lists. `mutateMonster` multiplies HP/speed/defense/damage by the factors, OR-s in the added flags, and (if ≥0) overrides `DFChance`/`DFType`.

---

## 6. Monster class catalog

Source: `Globals.c:1565` (`monsterClassCatalog`, `MONSTER_CLASS_COUNT = 15`). Classes group monsters for effects such as the staff/wand/charm of **discord-by-class**, certain feats, and "summon monster" weighting. `frequency` weights random selection within the class; `maxDepth = -1` means no depth cap.

| Class | Freq | maxDepth | Members |
|---|---|---|---|
| abomination | 10 | -1 | bog monster, underworm, kraken, tentacle horror |
| dar | 10 | 22 | dar blademaster, dar priestess, dar battlemage |
| animal | 10 | 10 | rat, monkey, jackal, eel, toad, vampire bat, centipede, spider |
| goblin | 10 | 10 | goblin, goblin conjurer, goblin mystic, goblin totem, goblin warlord, spectral blade |
| ogre | 10 | 16 | ogre, ogre shaman, ogre totem |
| dragon | 10 | -1 | dragon |
| undead | 10 | -1 | zombie, wraith, vampire, phantom, lich, revenant |
| jelly | 10 | 15 | pink jelly, black jelly, acidic jelly |
| turret | 5 | 18 | arrow turret, spark turret, dart turret, flame turret |
| infernal | 10 | -1 | flamedancer, imp, revenant, fury, phantom, ifrit |
| mage | 10 | -1 | goblin conjurer, goblin mystic, ogre shaman, dar priestess, dar battlemage, pixie, lich |
| waterborne | 10 | 17 | eel, naga, kraken |
| airborne | 10 | 15 | vampire bat, will-o-the-wisp, pixie, phantom, fury, ifrit, phoenix |
| fireborne | 10 | 12 | will-o-the-wisp, salamander, flamedancer, phoenix |
| troll | 10 | 15 | troll |

---

## 7. Horde catalog

Source: `GlobalsBrogue.c:796` (`hordeCatalog_Brogue`). `brogueGameConst.numberHordes` is computed from the table size (`GlobalsBrogue.c:1115`).

### 7.1 Structure (`hordeType`, `Rogue.h:2455`)

| Field | Meaning |
|---|---|
| `leaderType` | the leader monster (`MK_*`) |
| `numberOfMemberTypes` | how many follower species (0 = solo) |
| `memberType[5]` | the follower species |
| `memberCount[5]` | `randomRange` of how many of each follower spawn |
| `minLevel` / `maxLevel` | depth range where the horde is eligible (`pickHordeType`) |
| `frequency` | spawn weight within the eligible set |
| `spawnsIn` | terrain the horde must spawn into (e.g. `DEEP_WATER`, `WALL`, `MUD`, `STATUE_DORMANT`, `MONSTER_CAGE_CLOSED`) |
| `machine` | accompanying machine to build (e.g. `MT_CAMP_AREA`) |
| `flags` | `HORDE_*` (see §8) |

`pickHordeType` (`Monsters.c:663`) sums `frequency` over eligible hordes (matching depth and flag filters) and picks weighted-randomly. `spawnHorde` (`Monsters.c:944`) places the leader, then iterates members, building any associated `machine`.

### 7.2 Naturally-spawning hordes (no machine/summon flags)

| Leader (× members) | Members (count) | Depths | Freq | Terrain |
|---|---|---|---|---|
| rat | — | 1–5 | 150 | |
| kobold | — | 1–6 | 150 | |
| jackal | — | 1–3 | 100 | |
| jackal ×1 | jackal (1–3) | 3–7 | 50 | |
| eel | — | 2–17 | 100 | DEEP_WATER |
| monkey | — | 2–9 | 50 | |
| bloat | — | 2–13 | 30 | |
| pit bloat | — | 2–13 | 10 | |
| bloat ×1 | bloat (0–2) | 14–26 | 30 | |
| pit bloat ×1 | pit bloat (0–2) | 14–26 | 10 | |
| explosive bloat | — | 10–26 | 10 | |
| goblin | — | 3–10 | 100 | |
| goblin conjurer | — | 3–10 | 60 | |
| toad | — | 4–11 | 100 | |
| pink jelly | — | 4–13 | 100 | |
| goblin totem +camp | goblin (2–4) | 5–13 | 100 | machine `MT_CAMP_AREA`, no periodic spawn |
| arrow turret | — | 5–13 | 100 | WALL, no periodic spawn |
| monkey ×1 | monkey (2–4) | 5–13 | 20 | |
| vampire bat | — | 6–13 | 30 | |
| vampire bat ×1 | vampire bat (1–2) | 6–13 | 70 | never-OOD |
| acid mound | — | 6–13 | 100 | |
| goblin ×3 | goblin (2–3), goblin mystic (1–2), jackal (1–2) | 6–12 | 40 | |
| goblin conjurer ×2 | goblin conjurer (0–1), goblin mystic (1) | 7–15 | 40 | |
| centipede | — | 7–14 | 100 | |
| bog monster | — | 7–14 | 80 | MUD, never-OOD |
| ogre | — | 7–13 | 100 | |
| eel ×1 | eel (2–4) | 8–22 | 70 | DEEP_WATER |
| acid mound ×1 | acid mound (2–4) | 9–13 | 30 | |
| spider | — | 9–16 | 100 | |
| dar blademaster ×1 | dar blademaster (0–1) | 10–14 | 100 | |
| will-o-the-wisp | — | 10–17 | 100 | |
| wraith | — | 10–17 | 100 | |
| goblin totem ×4 +camp | totem (1–2), conjurer (1–2), mystic (1–2), goblin (3–5) | 10–17 | 80 | `MT_CAMP_AREA`, no periodic spawn |
| spark turret | — | 11–18 | 100 | WALL, no periodic spawn |
| zombie | — | 11–18 | 100 | |
| troll | — | 12–19 | 100 | |
| ogre totem ×1 | ogre (2–4) | 12–19 | 60 | no periodic spawn |
| bog monster ×1 | bog monster (2–4) | 12–26 | 100 | MUD |
| naga | — | 13–20 | 100 | DEEP_WATER |
| salamander | — | 13–20 | 100 | LAVA |
| ogre shaman ×1 | ogre (1–3) | 14–20 | 100 | |
| centaur ×1 | centaur (1) | 14–21 | 100 | |
| acidic jelly | — | 14–21 | 100 | |
| dart turret | — | 15–22 | 100 | WALL, no periodic spawn |
| pixie | — | 14–21 | 80 | |
| flame turret | — | 14–24 | 100 | WALL, no periodic spawn |
| dar blademaster ×2 | dar blademaster (0–1), dar priestess (0–1) | 15–17 | 100 | |
| pink jelly ×2 | pink jelly (0–1), dar priestess (1–2) | 17–23 | 70 | |
| kraken | — | 15–30 | 100 | DEEP_WATER |
| phantom | — | 16–23 | 100 | |
| wraith ×1 | wraith (1–4) | 16–23 | 80 | |
| imp | — | 17–24 | 100 | |
| dar blademaster ×3 | blademaster (1–2), priestess (1), battlemage (1) | 18–25 | 100 | |
| fury ×1 | fury (2–4) | 18–26 | 80 | |
| revenant | — | 19–27 | 100 | |
| golem | — | 21–30 | 100 | |
| tentacle horror | — | 22–deepest−1 | 100 | |
| phylactery | — | 22–deepest−1 | 100 | |
| dragon | — | 24–deepest−1 | 70 | |
| dragon ×1 | dragon (1) | 27–deepest−1 | 30 | |
| golem ×3 | golem (1–2), dar priestess (0–1), dar battlemage (0–1) | 27–deepest−1 | 80 | |
| golem ×1 | golem (5–10, clump 2) | 30–deepest−1 | 20 | |
| kraken ×1 | kraken (5–10, clump 2) | 30–deepest−1 | 100 | DEEP_WATER |
| tentacle horror ×2 | tentacle horror (1–3), revenant (2–4) | 32–deepest−1 | 20 | |
| dragon ×1 | dragon (3–5) | 34–deepest−1 | 20 | |

### 7.3 Summon hordes (`HORDE_IS_SUMMONED`)

Spawned by an `MA_CAST_SUMMON` caster whose type matches the leader (depth fields are 0/0; picked by `pickHordeType` with `summonerType`).

| Summoner (leader) | Summons | Count | Extra flags |
|---|---|---|---|
| goblin conjurer | spectral blade | 3–5 | dies on leader death |
| ogre shaman | ogre | 1 | |
| vampire | vampire bat | 3 | |
| lich | phantom | 2–3 | |
| lich | fury | 2–3 | |
| phylactery | lich | 1 | |
| goblin warlord | goblin conjurer (1), goblin (3–4) | | summoned at distance |
| phoenix egg | phoenix | 1 | |
| eldritch totem | spectral blade | 4–7 | dies on leader death |
| eldritch totem | fury | 2–3 | dies on leader death |

### 7.4 Captive hordes (`HORDE_LEADER_CAPTIVE`)

The "leader" is shackled and the followers are its **captors/guards**; freeing the captive makes it an ally. Source `spawnHorde` `Monsters.c:1021` (sets `MB_CAPTIVE`, `MONSTER_WANDERING`, HP = ¼ max, draws manacles). All are `HORDE_NEVER_OOD`, freq 10–20.

Examples: kobold-guarded monkey (1–5); goblin-guarded goblin (3–7); goblin-guarded ogre (4–10); kobold-guarded goblin mystic (5–11); ogre-guarded ogre (8–15); troll-guarded troll/centaur/dar blademaster (12–19); salamander↔naga pairs (13–20); fury-guarded imp/dar (18–26); pixie-guarded imp (14–21); dar-trio-guarded tentacle horror (20–26) and golem (18–25). (Full list `GlobalsBrogue.c:877–896`.)

### 7.5 Machine / area hordes

These spawn only inside generated machines (filtered by `HORDE_MACHINE_ONLY`, `Rogue.h:2176`). Terrain in `spawnsIn`.

| Flag | Purpose | Examples (leader / depths) |
|---|---|---|
| `HORDE_MACHINE_BOSS` | boss-challenge room | goblin warlord (2–10), black jelly (5–15), vampire (10–deepest), flamedancer (10–deepest) |
| `HORDE_MACHINE_WATER_MONSTER` | flooding-room ambush | eel (2–7, 5–15), kraken (12–deepest) |
| `HORDE_MACHINE_CAPTIVE` | powerful captive, **no captors** | ogre (4–13), naga, goblin mystic, troll, dar blademaster/priestess, wraith, golem, tentacle horror (20–amulet), dragon (23–amulet) |
| `HORDE_MACHINE_STATUE` | dormant in `STATUE_DORMANT` | goblin (1–6), ogre, wraith, naga, troll, golem, dragon, tentacle horror |
| `HORDE_MACHINE_TURRET` | dormant in `TURRET_DORMANT` | arrow (5–13), spark (11–18), dart (15–22), flame (17–24) turrets |
| `HORDE_MACHINE_MUD` | dormant in `MACHINE_MUD_DORMANT` | bog monster (12–26), kraken (17–26, freq 30) |
| `HORDE_MACHINE_KENNEL` | caged captives (`MONSTER_CAGE_CLOSED`) | monkey, goblin(+conjurer/mystic), ogre, troll, naga, salamander, imp, pixie, dar trio |
| `HORDE_VAMPIRE_FODDER` | bloodbag captives in cages | same kind of roster as kennels |
| `HORDE_MACHINE_THIEF` | key-thief area | monkey (1–14), imp (15–deepest) |
| `HORDE_SACRIFICE_TARGET` | assassination challenge; leader gets scary light (`MB_MARKED_FOR_SACRIFICE`, `SACRIFICE_MARK_LIGHT`) | monkey, goblin, ogre, troll, wraith, naga, dar blademaster, golem, revenant, tentacle horror (in `STATUE_INSTACRACK`) |
| `HORDE_MACHINE_LEGENDARY_ALLY` (+ `HORDE_ALLIED_WITH_PLAYER`) | starts allied to player | unicorn, ifrit, phoenix egg, mangrove dryad/ancient spirit (1–deepest) |
| `HORDE_MACHINE_GOBLIN_WARREN` | goblin-warren machine | goblin, conjurer, totem-camps, goblin packs, plus a captive goblin |

---

### 7.6 Elite / leader monsters (mutations × hordes)

Brogue has no single unified "elite" template (one creature that bundles extra HP, an escort,
and a random power). Instead, the traits people associate with elites come from **two
independent systems that can stack**:

| Elite trait | System | Where |
|---|---|---|
| Extra HP, buffed stats, a random special ability, a distinct color + name prefix | **Mutations** (per-monster, depth-gated, ≤1 per monster) | §5 |
| An escort of followers led by a leader | **Hordes** (`leaderType` + `memberType[]`) | §7 |

**Leader / follower wiring** (`spawnHorde` → `spawnMinions`, `Monsters.c:944`, `:856`):

- The horde's `leaderType` is generated first; each member is generated next, tagged
  `MB_FOLLOWER` with its `leader` pointer set to the leader (`Monsters.c:731`).
- If at least one minion spawns, the leader gets `MB_LEADER` (`Monsters.c:749`). Followers of
  the same leader treat each other as allies (`monstersAreEnemies`, `Monsters.c:535`) and move
  and fight as a group.
- **Permanent packs** (most natural hordes): followers survive the leader's death and disperse.
- **Bound followers** — `HORDE_DIES_ON_LEADER_DEATH` gives members `MB_BOUND_TO_LEADER`, so
  they vanish when the leader dies (`Monsters.c:904`); used for summoned/spectral hordes.
- **Dynamic followers** — summoners (`MA_CAST_SUMMON`: goblin conjurer, ogre shaman, lich,
  vampire, goblin warlord) spawn new followers mid-fight, bound to themselves as leader
  (`Monsters.c:1156`, `:1221`).

**Stacking:** the leader (or any follower) independently rolls for a mutation in
`generateMonster`, so a horde leader can also be mutated — e.g. a *juggernaut goblin conjurer*
(3× HP, knockback) leading a goblin pack. That intersection is the closest Brogue gets to a
classic "elite with an escort," but it is the product of the two systems, not a dedicated
elite type.

---

## 8. `HORDE_*` flags (complete reference)

Source: `Rogue.h:2154` (`enum hordeFlags`).

| Flag | Bit | Meaning |
|---|---|---|
| `HORDE_DIES_ON_LEADER_DEATH` | 0 | whole horde dies if leader dies (no new leader elected) |
| `HORDE_IS_SUMMONED` | 1 | minions summoned when a creature of the leader's species casts summon |
| `HORDE_SUMMONED_AT_DISTANCE` | 2 | summons appear across the level and path back to the leader |
| `HORDE_LEADER_CAPTIVE` | 3 | leader is in chains; followers are guards |
| `HORDE_NO_PERIODIC_SPAWN` | 4 | spawns only at level generation, never afterward |
| `HORDE_ALLIED_WITH_PLAYER` | 5 | leader starts as the player's ally |
| `HORDE_MACHINE_BOSS` | 6 | used in boss-challenge machines |
| `HORDE_MACHINE_WATER_MONSTER` | 7 | machines that flood with shallow water |
| `HORDE_MACHINE_CAPTIVE` | 8 | powerful captive monsters without captors |
| `HORDE_MACHINE_STATUE` | 9 | monsters suited to statue ambushes |
| `HORDE_MACHINE_TURRET` | 10 | turrets, hiding in walls |
| `HORDE_MACHINE_MUD` | 11 | bog monsters, hiding in mud |
| `HORDE_MACHINE_KENNEL` | 12 | monsters that appear caged in kennels |
| `HORDE_VAMPIRE_FODDER` | 13 | monsters prone to vampire capture/farming |
| `HORDE_MACHINE_LEGENDARY_ALLY` | 14 | legendary allies |
| `HORDE_NEVER_OOD` | 15 | cannot be generated out of depth |
| `HORDE_MACHINE_THIEF` | 16 | key-thief area machines |
| `HORDE_MACHINE_GOBLIN_WARREN` | 17 | goblin warrens |
| `HORDE_SACRIFICE_TARGET` | 18 | assassination-challenge target (scary light on leader) |
| `HORDE_MACHINE_ONLY` | — | union of all the machine-only flags above |

---

## 9. Depth-based spawning, out-of-depth, captives & scaling

### Out-of-depth (OOD)
Source: `spawnHorde`, `Monsters.c:950`. With `brogueGameConst.monsterOutOfDepthChance = 10`, each non-summoned spawn on depth > 1 has a **10%** chance to use an elevated effective depth: `depth = rogue.depthLevel + rand_range(1, min(5, depthLevel/2))`, clamped so it never exceeds the amulet level. When OOD triggers, `HORDE_NEVER_OOD` hordes are excluded. This is how tougher monsters occasionally appear a few floors early.

### How spawn eligibility works
`pickHordeType` (`Monsters.c:663`) considers a horde eligible when `minLevel ≤ depth ≤ maxLevel`, its flags don't intersect `forbiddenFlags`, and it has all `requiredFlags`; selection is weighted by `frequency`. Summon picks instead match `HORDE_IS_SUMMONED` + `leaderType == summonerType`.

### Captive / ally mechanics
- Captive hordes (`HORDE_LEADER_CAPTIVE`): leader gets `MB_CAPTIVE`, starts `MONSTER_WANDERING`, HP reduced to `maxHP/4 + 1` (if it regenerates), and manacles are drawn unless it's caged. Freeing it (walking adjacent and choosing to free) turns it into an ally via `becomeAllyWith`.
- `HORDE_ALLIED_WITH_PLAYER` hordes call `becomeAllyWith(leader)` immediately at spawn (legendary allies).
- Cloning a captive (e.g. via a wand) makes the clone an ally too (`cloneMonster`, `Monsters.c:720`).

### Difficulty scaling with depth
BrogueCE 1.15 does **not** scale a monster's base stats by depth via a per-level array (there is no `monsterAccuracyByLevel`/`monsterDefenseByLevel` table in `PowerTables.c` in this version). Instead, monster difficulty rises through:
1. **Horde depth bands** — each monster only appears within its `minLevel..maxLevel` window, so deeper floors draw from a tougher roster (see §7.2).
2. **Mutations** — increasingly likely past depth 10, and very common below the amulet level (up to 75%), multiplying HP/damage/speed (see §5).
3. **Out-of-depth spawns** — 10% chance to pull a horde from up to 5 floors deeper.
4. **Empowerment** — allies (and some monsters) can be empowered: `empowerMonster` (`Monsters.c:699`) adds +12 HP, +10 defense, +10 accuracy, +~10% damage and full-heals.

`PowerTables.c` monster-relevant scaling is for *player/item* power vs. monsters: `POW_ACCURACY_FRACTION` / `POW_DEFENSE_FRACTION` / `POW_DAMAGE_FRACTION` (`PowerTables.c:143–207`) convert net enchant/armor into hit/defense/damage fractions; `POW_REGEN` (`:130`) governs regeneration timing; `POW_REFLECT` (`:114`) governs reflection. These apply to the combat math, not to a monster's catalog base stats.

Relevant `brogueGameConst` combat tunables (`GlobalsBrogue.c:1076–1095`):
`playerTransferenceRatio = 20`, `onHitHallucinateDuration = 20`, `onHitWeakenDuration = 300`, `onHitMercyHealPercent = 50`, `mutationsOccurAboveLevel = 10`, `monsterOutOfDepthChance = 10`, `depthAccelerator = 1`.

---

## 10. Bolt types monsters can cast

Source: `Rogue.h:986` (`enum boltType`). Bolts referenced by monsters in the catalog:
`BOLT_SHIELDING`, `BOLT_HASTE`, `BOLT_SPARK`, `BOLT_HEALING`, `BOLT_SLOW_2`, `BOLT_SPIDERWEB`, `BOLT_DISTANCE_ATTACK`, `BOLT_NEGATION`, `BOLT_FIRE`, `BOLT_DISCORD`, `BOLT_BLINKING`, `BOLT_POISON_DART`, `BOLT_DRAGONFIRE`, `BOLT_BECKONING`, `BOLT_ANCIENT_SPIRIT_VINES`. (`BOLT_DISTANCE_ATTACK`, `BOLT_POISON_DART`, `BOLT_DRAGONFIRE`, `BOLT_SPIDERWEB`, `BOLT_ANCIENT_SPIRIT_VINES`, `BOLT_WHIP` are monster-only; the rest double as staff/wand effects.)