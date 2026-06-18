# Brogue SE — What's Different

Brogue SE is a gameplay fork of BrogueCE 1.15, bundled alongside
Classic 1.7.5 and faithful BrogueCE as a third selectable engine in the iOS app.
SE is where all original content lives. CE tracks upstream; SE diverges freely.

---

## Identification Rework

The biggest systemic change. Vanilla Brogue's binary identified/unidentified model is
replaced with a **two-axis knowledge system**:

- **Polarity** (benevolent / malevolent / neutral) — learned through indirect tells
- **Full identity** (kind + enchant + runic) — learned through direct use or sacrifice

Five active channels and two passive channels feed into a shared escalation rule:
unknown polarity → reveal aura; known polarity → full identify. A deductive
elimination engine auto-IDs the last unknown kind when all counterparts of the
opposite polarity are accounted for.

### Active Channels

| Channel | Cost | Effect |
|---|---|---|
| **Detect magic (drink)** | Potion | Reveals 2 random pack items; prioritizes still-hidden polarities before escalating to full ID. Scales with ring of wisdom. |
| **Detect magic (throw)** | Potion | Senses 1-2 undiscovered floor items on the level, lighting their map auras. Same wisdom scaling. |
| **Potion detonation** | Bolt charge + floor potion | Bad/cloud potions struck by a bolt (fire/lightning) or incendiary dart detonate and fully auto-ID. Fire triggers reveal polarity only for flammable gas clouds (the fire masks the tell). |
| **Altars of insight** | Sacrificed item | Sacrifice an unidentified item for a full identify. Sacrifice an identified item to reveal another's polarity or escalate it. Fire-only-if-it-helps: no turn spent unless information is gained. |

### Passive Channels

| Channel | Trigger | Effect |
|---|---|---|
| **Rest insight** | Resting undisturbed | Accrues toward an escalating threshold (base 80 turns + 30 per prior reveal). Reveals one random unknown item, favoring potions. Ring of wisdom accelerates ~10%/level. Weapons/armor cap at polarity (no full enchant ID). |
| **Eating insight** | Safe meal (no hunters) | Reveals one random unknown scroll. Deliberately scroll-only. |

### Passive Tells

- **Monkey/imp steal preference** — What a thief targets is a clue. Monkeys favor food and potion of life; imps favor scroll of enchanting and runic gear.
- **Empty-bottle capture** — Capturing a gas/liquid transmutes the bottle into an already-identified potion, auto-IDing that kind.
- **Benevolent-potion glow** — A dropped good potion glows warmly when a bolt passes through it (observational only; no flag set).
- **Scroll burn witness** — Watching a scroll burn reveals its polarity at the kind level.
- **Freed-captive reaction** — A rescued captive reacts to your pack, revealing the first unidentified benevolent (monkey) or malevolent (other) item.
- **Ring of awareness** — Senses floor item polarity on first arrival in a room.

### Design Decisions

- Gear (weapons/armor) never escalates to a full enchant ID through passive channels — only through wearing/using (the vanilla path). Polarity channels cap at the good/bad glyph.
- Kind-level persistence: once a potion flavor's polarity is known, it stays known for all instances of that flavor for the rest of the run.
- Darts were removed as a detonation channel. A quiver dropping early made them a free ID tool with no real cost; bolt charges are genuinely limited.

---

## New Items

### Staff of Frost

Single-target freeze bolt. Frozen creatures can be shoved across the floor by bumping into them — push distance scales with player strength (`clamp(strength - 8, 2, 10)` tiles). Shoved creatures stop on hazards, enabling lava kills and pit traps.

Terrain effects:
- Deep water freezes into walkable **ice bridges** that melt edge-inward
- Dense foliage freezes into impassable **frozen foliage walls** that block vision and melt back
- Quenches fire along the ray
- Fire-immune/burning creatures are doused and slowed instead of frozen

Base strength 12. Freq 8, value 1200.

### Empty Bottle

A new item type generated on a separate additive meter (~1 every 3-4 floors, outside the potion budget). Step into a gas, liquid, or surface and the bottle transmutes into the matching identified potion.

**Step-in captures:**

| Source | Result |
|---|---|
| Poison / confusion / paralysis gas | Matching potion |
| Rot gas | Lichen |
| Stench / smoke | Vomit |
| Methane | Incineration |
| Healing cloud | Wort |
| Steam | Steam |
| Deep / shallow water | Water |
| Ice | Ice |
| Brimstone / embers | Incineration / fire immunity |
| Acid splatter | Acid |
| Web / net | Webbing |

**Levitation captures:** Lava → incineration. Chasm / hole / trap door → descent.

**Bolt captures:** Set the bottle on the floor and zap it — lightning yields haste, fire yields incineration.

### Cooked Food

A ration caught in actual fire cooks in place instead of burning. As filling as a fresh ration, plus 5 turns of regeneration (1 HP/turn, 5 HP total).

### Potion of Water ("Bottle of Water")

Capture-only (via empty bottle on water). Drink to flush: douses fire, halves remaining confusion/hallucination/nausea. Throw for a large flood that shocks creatures standing in water and washes away scent trails.

### Capture-Only Potions

These never generate naturally — only through the empty bottle:

| Potion | Effect |
|---|---|
| Acid | Weakens the target |
| Webbing | Creates an entangling web patch |
| Steam | Scalding cloud |
| Ice | Freezing cloud |

### Themed Potion Sets

* Current disabled in-game and exists as zero probability in the code.

Two mutually exclusive pairs — one pair is active per seed, the other is suppressed from generation and the discovery screen:
- **Set 0:** Honey (regen over time; thrown → sticky mire) + Vomit (rot-gas nausea cloud)
- **Set 1:** Wort (healing-spore cloud) + Venom (poison DoT; thrown poisons struck creature)

Detect magic is always present alongside whichever pair the seed selects. A suppressed potion can still be obtained through empty-bottle capture.

### Potion Throw Refinements

- Thrown into deep water: floats to shore instead of shattering (recoverable)
- Direct creature hit with a benevolent potion buffs the target (risk/reward on enemies)
- Telepathy thrown at an enemy: permanent tracking bond
- Detect magic thrown: scouts the level's floor loot

---

## New Monster: Gold Goblin

A passive treasure-hoarder you chase down. Flees on sight toward the upstairs, tossing fungal smoke behind it. Drops depth-scaled gold on hit and a weighted loot hoard on death. Escaping forfeits all loot.

Built entirely from reusable components (see below) — no bespoke AI code. Once-per-run pinned spawn from a designated depth.

**Flee profile:** trigger on sight, exit via upstairs, breakpoint at 50% HP, 4-tile player berth, 10-turn memory, reroute when blocked, fungus-forest toss feature.

**Loot profile:** depth-scaled gold death hoard + per-hit gold trail.

---

## Reusable Behavior Components

Three shared systems extracted from the gold goblin and monkey/imp, replacing all per-monster-ID branches in the engine:

### Flee Component
`fleeProfile` on the creature catalog + `fleeAITakesTurn` dispatcher + `fleerState` runtime.

Configurable: trigger condition, exit target (upstairs/downstairs/random), breakpoint HP%, player berth distance, memory duration, reroute-when-blocked flag, toss dungeon-feature on flee, forfeit-loot-on-escape.

### Loot Component
`lootProfile` + `lootEntry` weighted table + `monsterShedLootOnHit` / `monsterDropDeathLoot`.

Configurable: weighted item table per creature, on-hit shedding, death-drop hoard, depth scaling.

### Steal Component
`stealProfile` + weighted `stealRule[]` evaluated in `rateItemStealDesirability`.

Monkeys and imps each have a scored preference table (food/life vs. enchanting/runic gear). No per-monsterID branching remains in the steal-rating code.

A second flee/looting/thieving creature is just catalog rows — no new behavior code needed.

---

## Ring Changes

### Ring of Light
Beyond its vanilla vision-range effect, the ring of light now creates an aura (radius 3 + |enchant| tiles) that affects allies and enemies within it:

- **Emboldened allies:** Allies standing in your light gain a defense bonus, a small accuracy nudge, and slowly mend their wounds (recovery-paced regeneration, not combat sustain). The buff lingers for 3 turns after leaving the light.
- **Rally behavior:** Emboldened allies that would normally scatter when wounded instead rally *behind* the player, using you as a shield while they heal in the light.
- **Invisible creature reveal:** No invisible creature can hide within the light's glow. Dim range flickers them; bright core fully exposes them.
- **Cursed ring inversion:** A cursed ring dims your sight and unsettles companions — allies lose heart, break formation sooner, and take a mild defense penalty.

### Ring of Awareness
Expanded beyond its vanilla stealth-detection role:

- **Floor item polarity sense:** On first arrival at a new level, a worn ring of awareness may sense the polarity (good/bad aura) of magic items on the floor. Chance and reach scale with enchant level.
- **Lost-trail sense:** When a pursuing monster gives up the chase (loses your scent), you get an awareness-scaled chance to sense it. Base chance is low (~5%); the ring adds +20%/enchant, making a high-awareness character notice reliably.
- **Goblin escape awareness:** Sense the gold goblin's escape even when it's off-screen (requires any positive awareness bonus).

---

## Combat & Status Changes

### Fire Panic
Catching fire inflicts 3 turns of confusion, displayed as "Panic" on the status sidebar (instead of "Confused") while the creature is still burning. Panic always ends before burning does (3 vs 7 turns), so it's visually distinct from real confusion. The message reads: *"you catch fire and panic."*

### Emboldened Allies
Allies within the ring of light's aura gain the "Emboldened" status (see Ring of Light above). They fight harder, take less damage, and slowly heal — but only while they stay in the light.

### Ally AI Improvements
- **Invulnerable monster avoidance:** Allies keep their distance (6 tiles) from damage-immune enemies like revenants and stone guardians, instead of suicidally engaging them.
- **Rally-behind-player:** Emboldened allies retreat behind you rather than scattering to a generic safety map, keeping them in the light's healing aura.

### Water Washes Scent
Wading through water washes away the player's scent trail. Pursuers tracking by scent lose the trail when it crosses water. The ring of awareness lets you sense when this happens.

### Inventory Progress Bars
Subtle progress bars drawn behind inventory item text, showing charge/durability state at a glance. Staff progress bars are segmented by charge count. Full-width, dimmer styling to avoid visual noise.

---

## Terrain & Hazard Changes

### Electrified Water
Lightning striking a creature in water charges the entire connected body via breadth-first flood. Geometric falloff (75% per ring). Stunned creatures are paralyzed for 3 turns. Eels are shocked despite being submerged (overrides the "submerged can't be bolt-targeted" rule).

Conductive water includes deep, shallow, sloshing, and luminescent water. Excludes bog and lava.

### Ice Bridges & Frozen Foliage
Staff of frost terrain (see above). Ice bridges are walkable and melt edge-inward. Frozen foliage is impassable and vision-blocking.

### Forcefield Blocks Explosions
Added `T_OBSTRUCTS_SURFACE_EFFECTS` to forcefields so surface effects (explosions, blood, lichen) no longer bleed through.

---

## Altars & Machines

### Altars of Insight
Paired altar (payment slot + revelation slot). Guaranteed placement at depths 6 and 11 with carry-forward scheduling — if a level can't accommodate it, the obligation rolls to the next level, capped at depth 20.

The insight slot refuses items with nothing to reveal: throwing weapons by kind, already-neutral items, fully-identified items. The payment slot is unrestricted.

### Altars of Transference (code-only, disabled for release)
Swap enchant levels between two items. Reward-room machine, freq 30. Present in the engine but not active in gameplay.

---

## Lone Wolf Solo Progression

A strength bonus that accrues from exploration while playing without allies.

- **Gated:** zero living allies anywhere + depth 6 or deeper
- **Tier 1** (1500 exploration XP): +1 effective strength
- **Tier 2** (3000 XP): +2 effective strength
- **Polarity tells:** one per tier-up, only on pure-solo runs (never had an ally)
- **On ally acquisition:** XP track zeroes, strength bonus stripped
- **Re-grindable:** if your ally dies, XP reaccumulates from zero
- Sidebar displays "Lone Wolf" when a tier is active

---

## Upstream Bugfixes (from BrogueCE)

These fixes are ported from upstream CE and apply to the SE engine:

| Fix | Detail |
|---|---|
| Worm-tunnel lever sealed in walls | Lever origin now builds FLOOR, not WORM_TUNNEL_OUTER_WALL |
| Obstruction crystal not blocking explosions | Forcefield now obstructs surface effects |
| Lumenstones miscounted in loss score | Counts item quantity, not stack count |
| Explosion immunity lasting 4 turns instead of 5 | Decrement moved before `updateEnvironment` |
| Submerged player seeing monsters in separate water bodies | Gated on same-connected-body flood-fill check |
| Monsters waking against stale stealth range | Recompute lighting + stealth before monster loop |
| Confused monsters stumbling onto sacred glyphs | Sacred ground is a hard ward regardless of avoidance preferences |

---

## Platform: Three-Engine Architecture

The iOS app bundles three engines selectable at the title screen:

- **Classic** (Brogue 1.7.5) — the original iBrogue port
- **BrogueCE** (1.15) — faithful upstream port, Game Center active
- **Brogue SE** — gameplay fork, Game Center silent

Engine switching happens live at the title screen with no app restart. Each engine has isolated saves (`Documents/`, `Documents/ce/`, `Documents/se/`) and separate UserDefaults keys for high scores, run history, and graphics mode.

SE is deliberately Game Center-silent — no leaderboard or achievements — because the gameplay balance is actively evolving. Local high scores are still recorded.

---

## Platform: Keyboard & Input

### Keyboard Schemes
Two selectable layouts, persisted across all engines:

- **Classic:** vi-keys (`hjklyubn`) for movement
- **Modern:** spatial grid (`ijkl` cross + `uo`/`m.` diagonals), with displaced commands (`e` = inventory, `Shift+E` = equip, `p` = messages)

Toggled from the help screen. The scheme is applied in the platform bridge, not the engine, so recordings stay canonical.

### Hardware Keyboard Support
- Shift/Ctrl modifiers from `UIKey.modifierFlags` reach the engine for run-movement
- On-screen d-pad and ESC button hide when a hardware keyboard is detected (GCKeyboard observer)
- Welcome screen shows "Press ? for help" only with hardware keyboard present
- Seed-entry prompt pre-fills the last played seed and shows a number pad


---

## Balance Tuning

| Parameter | Value |
|---|---|
| Staff of frost base strength | 12 |
| Scroll of identify frequency | 35 (was 30) |
| Scroll of aggravate monsters frequency | 12 (was 15) |
| Scroll of summon monsters frequency | 8 (was 10) |
| Detect magic base reveals | Flat 2 (was random 1-2), scales with wisdom |
| Rest insight base threshold | 80 turns + 30 per prior reveal |
| Wisdom ring rest acceleration | ~10%/level, capped at 80% faster |
| Empty bottle spawn rate | ~1 every 3-4 floors (separate meter) |
| Ring of light aura | 3 + |enchant| tiles |

---

## License

Brogue SE is a fork of BrogueCE and is licensed, like its base, under the **GNU Affero
General Public License v3 or later** ([`LICENSE`](LICENSE)). The SE-original content
listed above is © 2026 Seth Howard; the forked base is © Brian Walker and the Brogue CE
contributors. See [`NOTICE.md`](legal/NOTICE.md) for the full attribution and
[`LICENSE-EXCEPTIONS.md`](legal/LICENSE-EXCEPTIONS.md) for documented additional permissions.
