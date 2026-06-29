# Runics — Mechanics & How to Model Them in the Fight Simulator

The fight simulator currently runs **plain, runic-less weapons**. That is the single biggest gap in the
balance model, because runic *generation* is a built-in counterweight to raw weapon damage: low-damage
weapons frequently spawn with a powerful runic, while the heavy weapons we've been tuning **essentially
never do**. Until runics are modeled, the heavy-vs-light picture (and therefore the case for nerfing the
heavies at all) is incomplete. This doc records how runics work and how to add them.

---

## Two separate mechanics: generation vs activation

### 1. Generation — does an item *spawn* with a runic? (`Items.c`, weapon case ~`:249`)
Every generated weapon runs:

1. **40% magic gate** (`rand_percent(40)`) — 60% are mundane.
2. **50/50 cursed** — cursed weapons get a *bad* runic 33% of the time (mercy/plenty).
3. **Good-runic roll** (non-cursed half):
   ```c
   rand_range(3,10) * (STAGGER?2:1) / (QUICKLY?2:1) / (EXTEND?2:1) > damage.lowerBound
   ```
   If the (flag-adjusted) roll **beats the weapon's minimum damage**, it gets a good runic, chosen
   uniformly from 8 kinds. *Lower-damage weapons are more likely to be runic* — and because the roll caps
   at 10 (20 for staggers), weapons whose min damage exceeds that ceiling can **never** roll one.

**Good-runic chance, conditional on the non-cursed-magic branch (≈20% of all weapons):**

| weapon | min dmg | good-runic chance |
|---|---|---|
| dagger | 3 | 87.5% |
| spear | 4 | 75% |
| sword / axe / rapier / whip | 3–7 | 37.5% |
| mace | 16 (×2 stagger) | 25% |
| flail | 9 | 12.5% |
| **broadsword / war_pike / war_axe / war_hammer** | 11–25 | **0%** |

Unconditional good-runic spawn rate ≈ `0.40 × 0.50 × (chance above)` → dagger ≈17.5%, spear ≈15%,
sword/axe ≈7.5%, mace ≈5%, flail ≈2.5%, **heavies 0%**. (Bad runics: any weapon, ≈6.6% of all.)

Armor is analogous (`Items.c:307`): `rand_range(0,95) > armorValue` → lower-armor pieces (leather!) are
likelier to be runic.

### 2. Activation — how often does a runic *trigger* in combat? (`PowerTables.c:244 runicWeaponChance`)
Proc runics (everything except slaying) fire per hit with probability `100 − 100·(decrement)^index`, where
`index ∝ enchantLevel · modifier` and `modifier = 1 − min(0.99, avgBaseDamage/18)`.

- **Higher enchant → higher proc chance** (and it scales with strength via `netEnchant`).
- **Higher base damage → lower proc chance** ("innately high-damage weapons trigger runics less"). Stagger
  weapons halve their effective base for this. So heavies are doubly disfavored: they rarely *get* a runic,
  and would *proc* it least if they did.
- W_SLAYING is not a proc — it's always-on bonus damage vs one chosen monster class. Bad runics proc ~15%.

---

## The good weapon runics (what each does, for modeling)

| runic | effect on proc | sim impact |
|---|---|---|
| **W_SPEED** | hastes the player (extra turns) | more attacks → big throughput gain |
| **W_QUIETUS** | instant kill | huge vs single tough targets (lone tank) |
| **W_PARALYSIS** | paralyzes the struck enemy | crowd control; effectively removes a turn |
| **W_MULTIPLICITY** | spawns spectral-blade allies | extra attackers → strong in clusters/packs |
| **W_SLOWING** | slows the struck enemy | mitigation; fewer incoming hits |
| **W_CONFUSION** | confuses the struck enemy | mitigation / crowd control |
| **W_FORCE** | knockback (scales with enchant) | repositioning; wall-slam damage |
| **W_SLAYING** | always-on vorpal bonus vs a monster class | flat power vs the chosen class |

Armor runics (for completeness): multiplicity, mutuality, absorption, reprisal, immunity, reflection,
respiration, dampening (good); burden, vulnerability, immolation (bad).

---

## How to add runics to the sim

The proc machinery is **already wired**: `attack()` calls `magicWeaponHit()` (Combat.c:1551), which calls
`runicWeaponChance()` and applies the effect. So a runic assigned to the player's weapon will *already*
proc in the stub-grid loop. The work is assignment, effect-validation, and methodology — not re-implementing
the math.

### Step 1 — assign runics to builds
Extend `BuildSpec` with `short weaponRunic` (−1 = none) and `short weaponVorpal` (for slaying). At build
setup in `sim.c`, when `weaponRunic >= 0`: set `theItem->enchant2 = weaponRunic`, `theItem->flags |=
ITEM_RUNIC`, and (for W_SLAYING) `theItem->vorpalEnemy`. Mirror for armor (`armorRunic`).

### Step 2 — validate each effect on the stub grid
The mini-loop isn't the engine turn pipeline, so each effect needs the same scrutiny we gave knockback/DoT:
- **Multiplicity** spawns spectral-blade *creatures* — confirm they're placed, take turns, attack, and are
  cleaned up on the stub grid (the highest-risk effect; summons touched the bugs we hit before).
- **Force** knockback — already exercised by mace/hammer; confirm it composes with the back-wall setup.
- **Speed** haste — verify the player's `ticksUntilTurn` actually shortens in our scheduler.
- **Paralysis/slowing/confusion** — these set monster status; confirm our per-turn status handling
  (`processTurnEffects` / the paralysis decrement) covers them, like we did for the lightning stun.
- **Quietus / slaying** — pure damage/kill, should "just work" through `inflictDamage`/`killCreature`.

### Step 3 — methodology (the important part)
Don't just bolt a fixed runic on every weapon. Three complementary runs:
1. **No-runic** (today's baseline) — the lower bound.
2. **Expected-runic** — assign each weapon a runic with its *generation-weighted* probability (table
   above), averaged over many trials, so the dagger is runic ~17% of runs and the war axe ~never. This is
   the realistic meta and the one that answers "are the heavy nerfs still warranted?"
3. **Best-case-runic** — each weapon with its strongest plausible runic, as the upper bound / ceiling.

Compare the tuned config across all three. Add a `--runics` mode that prints the per-archetype profile for
each (and a `--runicgen` sanity check that the assignment frequencies match the table).

### Step 4 — what it will likely change
- **The dagger** (sim's 32% floor) is the clearest case: it's runic ~17% of the time, often
  multiplicity/quietus/speed — a real runic dagger is a different weapon. Its true expected strength is well
  above the plain-stick number, which bears on whether it needs a buff at all.
- **The heavy-vs-light gap** narrows on its own: light weapons gain their frequent runics; heavies gain
  nothing (0% generation, lowest proc). This may show the heavy enchant/speed nerfs are **partly redundant**
  with a counterbalance the game already has — or confirm they're still needed on top of it.
- **Hybrid economy** interacts: a runic light weapon competes with the glowed staff for the "what do I
  invest in" slot.

---

## Why this matters for the current tuning

The recommended heavy-weapon nerfs (soft knees, pike 2× recovery, flail trim — see
[`fight-simulator-findings.md`](fight-simulator-findings.md)) were derived on runic-less weapons. Runic
generation is a structural counterweight the heavies already pay (they can't roll one). Modeling runics is
therefore the proper validation of *whether, and how hard,* to nerf the heavies. It is the recommended next
build before shipping any nerf — but the nerfs can be applied first and re-checked against the runic model
afterward, if a balance pass is wanted sooner than the modeling work.
