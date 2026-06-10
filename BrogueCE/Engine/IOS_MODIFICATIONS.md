# iOS modifications to the BrogueCE engine

The code in `BrogueCE/Engine/` is a vendored copy of the upstream **BrogueCE 1.15**
engine, compiled into the embedded `BrogueCE.framework` and driven by the iOS host
through `CEBridge.mm`. This document records iOS-specific modifications layered on
top of the vendored engine C, so the divergence from upstream stays legible and
future maintainers (human or AI) don't mistake an intentional port change for a bug.

This is the CE counterpart to `iBrogue_iPad/BrogueCode/IOS_MODIFICATIONS.md` (which
covers the separate Classic engine that ships in the app target).

## Conventions

- **Engine → host hooks are plain C functions** declared `extern` at the top of the
  engine file that calls them and **defined in `CEBridge.mm`** (inside its
  `extern "C"` block). They route to the app via the `BrogueCEHost` protocol. Each
  is a no-op when there's no host or no device support, so the engine may call them
  unconditionally. Naming: `ce*` (e.g. `cePlayerTookDamage`, `ceSetTargeting`).
- **`uiMode` is a write-only host signal.** The engine only ever *assigns*
  `uiMode` (the `CBrogueGameEvent` tablet UI mode); nothing in the engine reads or
  branches on it. It is reported to the host by `CEBridge.mm`, which uses it to
  show/hide on-screen controls. Changing which value a screen sets is therefore a
  pure UI change and cannot affect game logic.
- **Keep changes minimal and commented.** Every edit below is marked in-code with an
  `// iOS port (iBrogue):` comment so it's greppable.

---

## Change log

### 2026-06-10 — Candidate-narrowing inspect line for unidentified potions/scrolls

**What.** An unidentified potion's or scroll's inspect text now ends with a line like "You have narrowed
it down to one of 3 remaining beneficial potions." — the count of kinds it could still be, narrowed to
its polarity if that's known (the count is colored good/bad accordingly). It never names candidate kinds,
and is shown only when the count is ≥ 2.

**Why.** Surfaces the deduction bookkeeping a player otherwise tracks by hand. It reveals no new
information: the count is derived purely from what the player already knows (which kinds are identified,
plus this item's polarity if detect-magic/elimination has revealed it). The engine already
auto-identifies the last unknown kind of a polarity (`tryIdentifyLastItemKinds`, fired from every ID
path), so an unidentified item's count is always ≥ 2 — rendering only at ≥ 2 guarantees the line can
never hand out a free identification.

**Where.** `Items.c` — a forward prototype above `itemDetails`; a new `static short
candidateKindCount(item*, boolean *knownGood, boolean *knownBad)` defined just after
`itemMagicPolarityIsKnown` (iterates the category's kinds, counts unidentified ones matching known
polarity); and a render block appended to the unidentified branch of `itemDetails` (after the category
switch's `strcat`), gated on `POTION | SCROLL`. Reuses `itemMagicPolarityIsKnown`, `itemKindCount`,
`tableForItemCategory`, and `itemDetails`'s existing color-escape locals. All vanilla symbols.

**Determinism.** Pure display, recomputed on each inspect — no RNG, no serialized state; seeds and
recordings are unaffected.

### 2026-06-10 — Fire/lightning bolts detonate dropped bad potions

**What.** A fire or lightning bolt (`BF_FIERY` / `BF_ELECTRIC`) passing over a *dropped* potion now
detonates it in place, turning the potion into a placeable trap / ranged identifier. Only the seven
bad/cloud kinds react (poison, confusion, paralysis, incineration, darkness, descent, creeping death) —
the same set the thrown-potion shatter switch handles; good potions and hallucination get no bolt
signature. Fire is **violent** and lightning is **gentle** as an *emergent* property: detonation spawns
the potion's ordinary shatter dungeon feature, and the fire bolt's own per-cell `exposeTileToFire` then
ignites the flammable gas (poison/confusion/paralysis gas carry `T_IS_FLAMMABLE`); lightning has no fire
step, so the gas lingers as a cloud. The bad-potion switch was extracted from `throwItem` into a new
`static boolean shatterPotionAtLoc(item*, short x, short y)` (spawns DF + message + auto-ID + cell
refresh; returns true for the seven kinds) and is now shared between `throwItem` and the bolt hook.

**Why.** A dropped potion is otherwise inert until walked into. Letting a bolt set it off makes a dropped
bad potion a deliberate tool — lay a gas trap in a doorway, or ignite one on a chasing pack — and gives
fire/lightning staffs a second, terrain-driven use. Kept independent of the earlier potion-rework phases
so the change ports to upstream BrogueCE master verbatim (no creature effects or life cloud on bolt).

**Where.** `Items.c` only. (1) Forward prototype of `shatterPotionAtLoc` above `updateBolt`. (2) A new
hook in `updateBolt`, after the `pathDF` spawn and before the `BF_FIERY` `exposeTileToFire` block, so fire
ignites the gas the hook just spawned; it calls `shatterPotionAtLoc` on a `POTION` at the cell and tears
the floor item down exactly like `burnItem` (`removeItemFromChain(floorItems)` → `deleteItem` → clear
`HAS_ITEM | ITEM_DETECTED`), then sets `*lightingChanged` / `*autoID`. (3) `shatterPotionAtLoc` defined
above `throwItem`, extracted from the old inline switch. (4) `throwItem`'s bad-potion block replaced with
`if (shatterPotionAtLoc(...)) { } else { <existing harmless-splash + hallucination-ID> }`. Reuses only
upstream symbols.

**Determinism.** No RNG on the common bolt path (the hook is an `itemAtLoc` lookup + category test;
`spawnDungeonFeature` on a GAS-layer DF is a pure write). Action-triggered divergence only: detonating a
potion via a bolt diverges the seed exactly as *throwing* it would (same DFs; fire ignition via
`exposeTileToFire` is forced with `alwaysIgnite`, drawing no `rand_percent` of its own). No new RNG
primitive.

### 2026-06-10 — Thrown good potions affect the struck creature

**What.** Throwing an unidentified *good* potion (the first `numberGoodPotionKinds` of the potion
table: life, strength, telepathy, levitation, detect-magic, haste, fire-immunity, invisibility) at a
creature now applies that potion's effect to the creature it shatters on. A new
`static boolean applyPotionEffectToCreature(creature*, short potionKind, short magnitude)` (`Items.c`,
defined just above `drinkPotion`, forward-declared above `throwItem`) carries the per-kind logic. It
always applies the mechanical effect, but returns `true` only when a *player-visible* tell was
produced — which is what drives `autoIdentify`:
- strength → permanent +maxHP/+currentHP buff (≈half a life potion; "muscles bulge"),
- haste → "speeds up"; levitation → "floats into the air",
- life → full panacea heal of the struck creature **and**, on shatter, a healing-spore gas cloud
  (a new `DF_LIFE_POTION_CLOUD` that spawns the existing bloodwort `HEALING_CLOUD`); life auto-IDs
  unconditionally on shatter, like the gas potions,
- invisibility → reuses `imbueInvisibility` (its own flash + visibility-gated auto-ID),
- fire-immunity → sets `STATUS_IMMUNE_TO_FIRE`, but only IDs by *visibly snuffing flames* on a
  burning, not-already-immune, non-`MONST_FIERY` creature (no invented flavor text),
- telepathy / detect-magic and any bad potion → no effect, no ID.
The player is never the target (a thrown good potion shouldn't self-buff). The hook is a block at the
top of the potion-shatter branch in `throwItem`, before the bad-potion switch; when there is no tell
it falls through unchanged to the existing harmless-splash / hallucination-ID path. `drinkPotion`'s
own switch is untouched.

**Why.** Brogue's residual identification slog is discriminating the *good* potion cluster (life vs
strength vs haste…), which today can only be done by drinking in a safe corner. Making a thrown good
potion affect — and visibly tell on — the struck creature turns identification into a risky ranged
diagnostic. Effect-always / tell-gated keeps an unseen creature mechanically affected without leaking
information the player couldn't perceive. Upstream has no thrown-good-potion effect, so this is an
iOS divergence.

**Where.** `Items.c` — forward prototype above `throwItem`; `applyPotionEffectToCreature` defined
between `detectMagicOnItem` and `drinkPotion`; a new block at the top of the potion-shatter `if` in
`throwItem` (the good-potion effect, plus a `POTION_LIFE` case that spawns the cloud). Reuses `heal`,
`haste`, `imbueInvisibility`, `extinguishFireOnCreature`, `spawnDungeonFeature`. `Rogue.h` —
`DF_LIFE_POTION_CLOUD` appended to the `dungeonFeatureType` enum before `NUMBER_DUNGEON_FEATURES`.
`Globals.c` — a matching `{HEALING_CLOUD, GAS, 350, 0, 0}` row appended to `dungeonFeatureCatalog`
(clone of the bloodwort pod-burst). The catalog and enum are shared across the Brogue/Rapid/Bullet
variants; appending at the tail keeps every existing index aligned.

**Determinism.** No RNG on the common path: fixed magnitude via `potionTable[kind].range.upperBound`
(every good potion has `lowerBound == upperBound`), the helper draws no RNG, and `spawnDungeonFeature`
on a GAS layer is a pure volume/tile write (no RNG). Two action-triggered substantive-RNG divergences,
both stemming from the player's throw rather than from added bookkeeping: (1) thrown fire-immunity
early-extinguishing a burning creature removes that creature's remaining per-turn `rand_range(1,3)`
burn draws (the `STATUS_BURNING` case in `decrementMonsterStatus`, Monsters.c, draws unconditionally
per burning turn; fire immunity gates only the damage, not the draw); (2) the life cloud's gas changes
the gas map, so subsequent gas-dissipation rolls diverge from upstream seeds.

### 2026-06-08 — Rethrow falls through to a normal throw prompt

**What.** The rethrow command (`RETHROW_KEY`, Shift+T) used to no-op when there was no
valid item to rethrow. It now falls through to a normal throw prompt in that case.

**Why.** Upstream, rethrow only fires if `rogue.lastItemThrown != NULL` *and* that item
is still carried (`itemIsCarried`); otherwise the keystroke silently does nothing — most
visibly the first time you press it in a game (nothing thrown yet). On touch a button that
does nothing reads as broken, so we degrade to the ordinary "Throw what?" item picker
(`throwCommand(NULL, false)`), the same thing `THROW_KEY` does. Auto-targeting at
`lastTarget` is intentionally *not* preserved in the fall-through case (it would require a
`throwCommand` that can both prompt for an item and auto-aim).

**Where.** `IO.c` — `executeKeystroke()`, the `RETHROW_KEY` case gains an `else` branch.

### 2026-06-07 — Don't show the ESC button for tap-to-continue prompts

**What.** `waitForAcknowledgment()` and `waitForKeystrokeOrMouseClick()` no longer force
`uiMode = CBrogueGameEventShowEscape`; they leave `uiMode` as-is (InNormalPlay during play,
so no ESC button).

**Why.** Both prompts already dismiss on `MOUSE_UP` (tap anywhere) — they're "press any key
/ click to continue" acknowledgments, including the `--more--` message prompt
(`displayMoreSign → waitForAcknowledgment`). The on-screen ESC button was appearing for
transient messages like "A pressure plate clicks underneath the dart!", which is redundant
and noisy. The ESC button stays for states a tap can NOT dismiss: text entry
(`getInputTextString` → `ShowKeyboardAndEscape`: save game / save recording / seed) and the
throw/zap aiming loop (`Items.c`, which needs ESC to cancel an aim). Care was taken not to
remove ESC anywhere it's the only way out — these two functions provably exit on a tap.

**Where.** `IO.c` — removed the `uiMode = CBrogueGameEventShowEscape` (and the
save/restore of `oldUiMode`) in `waitForAcknowledgment` and `waitForKeystrokeOrMouseClick`.
Classic doesn't set a UI mode in its equivalents, so this is CE-only.

### 2026-06-06 — Suspend pinch-zoom while an entity description box is shown

**What.** When a creature/item description box lingers in the cursor loop (e.g. the
player taps an entity in the sidebar), the host suspends the iPhone pinch-zoom to 1×
so the box isn't magnified/clipped, then restores it — the same treatment menu and
inventory already get.

**Why.** The description box (`printMonsterDetails`/`printFloorItemDetails` →
`printTextBox`) renders into the dungeon cells but fired no host signal, so it was
drawn magnified and ran off-screen while zoomed.

**Where.** `IO.c` — `extern void ceSetExamining(boolean);` at file top; in
`mainInputLoop`'s cursor `do/while`, `ceSetExamining(textDisplayed)` right before
`moveCursor` and `ceSetExamining(false)` right after the loop (clears on action/cancel).
Defined in `CEBridge.mm` (deduped) → `BrogueCEHost setExamining:` → host. The host only
suspends zoom when the box was armed by a **sidebar single-tap** (`examineArmed`, set in
`touchesEnded`); boxes that auto-appear (auto-explore stopping on an item, a tap-to-move
over a monster) are not armed, so they don't zoom out — that previously caused an in/out
flicker while exploring.

### 2026-06-06 — Title flyout marker: ASCII `<` instead of a triangle glyph

**What.** The main-menu flyout buttons (Play, View) are marked with a literal ASCII
`<` in their button text instead of the `G_LEFT_TRIANGLE` display glyph.

**Why.** `G_LEFT_TRIANGLE` maps (via `ce_glyphToUnicode`) to `U_LEFT_TRIANGLE`
(`0x25C4` / `0x1F780`), which renders through a font that doesn't carry the glyph on
every locale/device, so it showed up inconsistently. `<` is in the reliable text set
(rendered from Monaco) and always looks the same. The flyout opens to the buttons'
left, so a left-pointing marker still reads correctly.

**Where.** `MainMenu.c` `initializeMainMenuButtons` — the Play/View button text uses
` <  ...` and the two `buttons[n].symbol[0] = G_LEFT_TRIANGLE;` assignments were
removed. (`*` in button text is the symbol placeholder; with no symbol set it would
render literally, so the text uses `<` directly.)

### 2026-06-06 — On-screen Explore button: single-tap auto-explore

**What.** A single tap on the on-screen Explore button now auto-explores
immediately, instead of the desktop two-step "tap once to preview the path, tap
again to commit." Ports the Classic engine's existing fix to CE (the button
previously misfired, often needing a second tap). Keyboard `x` (a `KEYSTROKE`) is
unaffected.

**Why.** On touch, the preview-then-commit step reads as the button "not
registering." A tapped button should act like pressing its hotkey.

**Where.** `IO.c` — file-scope `static boolean exploreImmediately`; in
`mainInputLoop`, set it when the chosen button is Explore and the event is
`MOUSE_UP`; in `exploreKey`, consume it into a local `forceExplore` and OR it into
the final `proposeOrConfirmLocation(...)` guard.

### 2026-06-05 — Light haptic when the player takes damage

**What.** When the player loses HP, the engine signals the host to play a haptic,
scaled by severity: ordinary hit, a hit that leaves the player under 40% health
(the engine's own low-health-flash threshold), or a fatal blow.

**Why.** Tactile feedback for combat; the host owns the actual haptic so it can honor
the user's haptics setting and skip unsupported devices (iPad).

**Where.**
- `Combat.c` — `extern void cePlayerTookDamage(int severity);` at file top; in
  `inflictDamage`, when `defender == &player && damage > 0 && !rogue.playbackMode`,
  compute severity (fatal / under-40% / ordinary) and call it.
- Defined in `CEBridge.mm` → `BrogueCEHost playDamageHaptic:` → host.

**Gating.** Suppressed during recording playback. The host no-ops it when haptics
are off or on iPad.

### 2026-06-05 — Move the escape button aside while aiming a throw/zap

**What.** Around the targeting loop, the engine tells the host when aiming starts and
ends, so the host can move the on-screen escape button to the lower-left corner and
enable the aiming magnifier.

**Why.** During throw/zap targeting the escape button overlapped the aiming area, and
the magnifier (tap-and-hold) was otherwise suppressed outside normal play.

**Where.**
- `Items.c` — `extern void ceSetTargeting(boolean isTargeting);` at file top; in
  `chooseTarget`, `ceSetTargeting(true)` right after entering the aim loop and
  `ceSetTargeting(false)` at **both** exits (cancel and confirm).
- Defined in `CEBridge.mm` → `BrogueCEHost setTargeting:` → host.

### 2026-06-05 — No escape button on the death screen

**What.** The "You die… — press space or click to continue" screen now uses
`CBrogueGameEventInMenu` instead of `CBrogueGameEventShowEscape`.

**Why.** A tap already advances that screen, so the on-screen escape button was
redundant clutter. `InMenu` and `ShowEscape` are identical to the host except that
`InMenu` hides the escape button; touches still flow, so a tap still advances.

**Where.** `RogueMain.c` — `gameOver()`, the death "press to continue" loop.

### 2026-06-05 — Keep the full-screen title layout during the Load/Replay pickers

**What.** While the title-menu file pickers (Open saved game / View recording) are
open, keep `brogueCEAtTitle = true`; drop it to `false` only once a file is actually
opened.

**Why.** The pickers ran with `brogueCEAtTitle = false`, so the host enabled the
in-game safe-area insets and the view visibly shrank before any game had loaded.

**Where.** `MainMenu.c` — `mainBrogueJunction()`, the `NG_OPEN_GAME` and
`NG_VIEW_RECORDING` cases (set true before `dialogChooseFile`, false inside the
`openFile` success branch). `brogueCEAtTitle` is reported to the host by
`CEBridge.mm`.

---

## Platform functions implemented in `CEBridge.mm`

These engine-declared platform functions were upstream stubs in this port and are now
implemented in the bridge (not the engine C, but listed here for orientation):

- `listFiles` — enumerates the CE save directory for the Load/Replay pickers.
- `getHighScoresList` / `saveHighScore` — local high scores (NSUserDefaults, CE keys).
- `saveRunHistory` / `saveResetRun` / `loadRunHistory` — the lifetime game-stats
  history (NSUserDefaults, CE keys; `seed == 0` is the "reset recent stats" sentinel).

Still stubbed: `takeScreenshot`, `notifyEvent` (the latter is where CE → Game Center
score/achievement reporting would hook in; CE high scores are currently local-only).

---

## Adding a new CE engine tweak

1. Prefer a host hook: declare `extern void ce<Thing>(...);` at the top of the engine
   file, call it where needed (with an `// iOS port (iBrogue):` comment), define it in
   `CEBridge.mm` inside `extern "C"`, add the matching `BrogueCEHost` method, and
   forward it from `CEHost.swift` to `BrogueViewController`.
2. For control visibility, reuse `uiMode` (write-only signal) rather than adding new
   plumbing where a mode value already conveys the intent.
3. Record the change here (what / why / where / gating).
