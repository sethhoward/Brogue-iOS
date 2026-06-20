# The Cosmetic Animation Layer (Brogue SE)

> Engine: **Brogue SE only** (`BrogueSE/Engine/IO.c`). A small, reusable, **RNG-cosmetic,
> non-blocking** animation system. Use it for any *presentational* effect that should play out
> over time without freezing the turn loop (noise ripples, alert glyphs, the investigate blink, …).

## What it is

A fixed-size registry of **effects** that are advanced once per **idle tick** (the same ~60 Hz clock
that drives water/lava shimmer and hallucination) and drawn as a **dirty-cell overlay** on top of the
base map. Effects play their full life **regardless of input** — they are never blocking and never
fast-forward-erased — and self-expire. The layer composites *on top of* `getCellAppearance`, so it
coexists with the terrain shimmer (which it does **not** own) without conflict.

It exists because the noise ripples were originally blocking `pauseAnimation` loops that input erased
mid-animation (jarring), propped up by a fragile platform key-repeat-timing contract. The layer
replaces all of that.

## The hard rules (do not break these)

1. **Cosmetic only.** Effects may *read* game state to decide what to draw; they must **never** write
   game state, never draw from the substantive RNG, and never gate logic. The layer runs in
   `RNG_COSMETIC`. Invariant: *same seed + same inputs → identical game, regardless of what animated.*
2. **Never saved.** Effects are transient and re-derived from game state; they are not serialized into
   saves/recordings. A ripple that played live but not on replay (or vice-versa) is *correct*.
3. **Ambient / non-blocking only.** The layer does not host turn-sequenced ("modal") animations that
   must finish before the turn proceeds — bolts/flashes stay on the blocking `pauseAnimation` path.
4. **Single-threaded.** It is a data structure + an `advance()` function, not a thread. It only makes
   progress when pumped (the bridge idle loop). Lifetimes are measured in **ticks**, never wall-clock.
5. **Dirty-cell scoped.** Only ever touch cells effects occupy (and cells they vacated). Never the
   button-bar row. This keeps the `commitDraws` diff honest and clean cells untouched.

## How it works

- **Registry:** `gCosmeticEffects[MAX_COSMETIC_EFFECTS]` (a fixed pool; overflow drops the effect — a
  missed cosmetic flash is harmless).
- **Tick:** `advanceCosmeticAnimations()` is called from `SEBridge.mm`'s idle loop, beside
  `shuffleTerrainColors`, then `commitDraws()` pushes the frame. Each tick it: ages/expires effects →
  paints this frame's cells (ripples first via `hiliteCell`, then glyph kinds via `plotCharWithColor`
  so glyphs win on shared cells) → restores cells painted *last* frame but not this one
  (`refreshDungeonCell`, re-deriving the base incl. shimmer). A two-buffer (ping-pong) painted-cell
  set makes restore O(effect cells), not O(map).
- **Kinds** (`enum cosmeticEffectKind`, file-local): `CE_ALERT_GLYPH` (one-shot flicker, e.g. `!`),
  `CE_RIPPLE_MONSTER` (grey geometric box from a cell), `CE_RIPPLE_PLAYER` (blue sound-map wavefront
  from the player), `CE_INVESTIGATE_BLINK` (`?` glyph blinking over an investigating monster).
- **Coalescing** (`channel` + the spawn logic): `ACCUMULATE` (+ same-cell merge) for monster ripples;
  `SINGLETON`/latest-wins for the player ripple (keyed by a sentinel address) and per-monster for the
  blink (keyed by the creature pointer — *only compared, never dereferenced* outside the live-monster
  rebuild, so it can't dangle).

## How to add a new effect

1. **Add a kind** to `enum cosmeticEffectKind` in `IO.c`.
2. **Add a spawn function** (declare it in `Rogue.h`). Set the struct fields: `kind`, `origin`, and
   either `glyph`+`tint` (glyph kinds; `tint == NULL` → draw in the cell's own foreColor) or
   `maxRadius`+`tint` (ripple kinds). Set `frameLife` in ticks (`0` = persistent, you manage its
   lifetime externally — see the blink). **Early-return during automation / playback fast-forward**
   (`rogue.automationActive || rogue.autoPlayingLevel || rogue.playbackFastForward`) like the others.
   For SINGLETON, reuse/replace the existing slot of that kind/channel; for same-cell merge, skip if an
   active effect of that kind already occupies the cell.
3. **Add a `case`** in `advanceCosmeticAnimations`: compute the effect's cells for this frame from
   `frameAge` (and/or the global blink phase), `cosmeticMarkCell()` each, and draw (`hiliteCell` for a
   tint overlay, or `getCellAppearance`+`plotCharWithColor` for a glyph). Cells you *don't* paint a
   given frame are restored automatically.
4. **Call your spawn** from wherever the event happens (gameplay code). If the effect tracks live game
   state (like the blink), rebuild it once per turn from `playerTurnEnded`.

**Worked example — the `!` alert glyph (the simplest tenant):** `cosmeticSpawnAlertGlyph(loc, '!')` drops
a `CE_ALERT_GLYPH` (red tint, `frameLife = CE_ALERT_LIFE_FRAMES`). In `advance`, it paints `!` over its
cell during alternating `CE_ALERT_FLICKER_FRAMES` windows (off windows paint nothing → the cell restores
→ it flickers), then expires. Called from `Monsters.c` when a monster spots/hears-loud the player.

## Porting to other platforms (Windows / Linux / SDL / curses)

The layer's *logic* (`advanceCosmeticAnimations` and friends) is **engine code in `IO.c` — fully
cross-platform.** Only the **pump** lives in the platform layer: on iOS it's one line in
`BrogueSE/SEBridge.mm`'s idle loop, right beside the existing `shuffleTerrainColors(_, true)` call that
already drives the terrain shimmer:

```objc
if (colorsDance) {
    shuffleTerrainColors(3, true);
    advanceCosmeticAnimations();   // <-- the cosmetic layer's pump
    commitDraws();
}
```

`SEBridge.mm` is **iOS-only** (Objective-C++). When SE is ported to another platform, that platform's
own event-wait / idle loop must add the same `advanceCosmeticAnimations()` call wherever it ticks the
terrain shimmer, then commit. **It's the exact same integration point as the shimmer** — if a platform
animates water, it adds one line for this.

Crucially, unlike the *old* noise system, there is **no timing contract** here: the pump has no
frequency or latency requirement. If a platform pumps it slower, effects animate slower; if a platform
forgets entirely, cosmetic effects simply don't play (graceful degradation) — nothing else breaks, and
the simulation is identical either way. (Contrast the deleted pre-roll system, which *required* the
platform's key-repeat timing to fall inside a window. That fragility is gone.)

## Limitations

- No modal/turn-blocking effects (bolts stay on `pauseAnimation`).
- Progress only happens while the idle loop pumps it (between turns and between held-key repeats); it
  does not advance *during* a turn's logic. Fine for ambient effects; not a substitute for a real-time
  scheduler.
- One-level deep: effects don't compose/parent. Precedence is fixed (base → ripple hilites → glyphs).
- Pool/painted-cell caps (`MAX_COSMETIC_EFFECTS`, `MAX_COSMETIC_PAINTED_CELLS`) silently drop overflow.

## Tuning levers (all in `IO.c` / `Rogue.h`)

| Lever | Effect |
|---|---|
| `MAX_COSMETIC_EFFECTS` / `MAX_COSMETIC_PAINTED_CELLS` | pool / per-frame paint caps |
| `CE_ALERT_FLICKER_FRAMES`, `CE_ALERT_LIFE_FRAMES` | `!` flicker speed / total linger |
| `CE_RIPPLE_FRAMES_PER_RING` | how fast ripple rings expand |
| `NOISE_RIPPLE_RADIUS`, `NOISE_RIPPLE_MAX_STRENGTH` | monster-ripple size / brightness (`Rogue.h`) |
| `NOISE_INVESTIGATE_BLINK_FRAMES` | `?` blink cadence (`Rogue.h`) |
| `cosmeticAlertColor` / `cosmeticNoiseColor` / `cosmeticPlayerColor` | effect tints |

## Determinism note

None of this affects replay: the layer never touches the substantive RNG or game state, and animation
timing can differ machine-to-machine with zero simulation impact.
