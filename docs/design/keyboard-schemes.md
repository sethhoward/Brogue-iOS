# Selectable keyboard schemes (Classic / Modern) + scheme-aware layout screen

Status: **implemented (2026-06-14)** in both engines (Classic 1.7.5 in `iBrogue_iPad/BrogueCode/`,
BrogueCE 1.15 in `BrogueCE/Engine/`). See the IOS_MODIFICATIONS.md change logs in each tree for the
as-built file map. Deferred: arbitrary user remapping; per-key key-repeat.

## Goal

Brogue's stock keys assume a numpad and use vi movement (`hjkl`+`yubn`), which is unintuitive on
Magic Keyboards / laptops. Add a second, opt-in **Modern** scheme: a spatial 3×3 directional grid on
the right hand, selectable and persisted, with a scheme-aware on-screen reference. Architected so a
later "arbitrary user remap" (deferred) is a clean increment, and so the whole thing is
**backport-friendly** to desktop Brogue (Linux/macOS/Windows).

## Cornerstone: where the remap lives (determinism)

Brogue saves *are* input recordings, and the weekly-seed leaderboard re-replays them. Recording
happens **upstream of command dispatch**: a keypress becomes a `KEYSTROKE` event in
`nextBrogueEvent` → `nextKeyOrMouseEvent`, then `recordEvent` stores `compressKeystroke(param1)` —
the *raw key char* (`Recordings.c`). Movement is dispatched later in `executeKeystroke` off hardcoded
`#define`s (`UP_KEY 'k'`, …).

Therefore the scheme **must translate physical key → canonical engine key at the input layer,
*before* `recordEvent`.** Consequences:

- Recordings are **always canonical** (e.g. Modern physical `i` is recorded as `k`/UP). Replays,
  seeds, and the leaderboard are scheme-independent. ✅
- `executeKeystroke` and the `#define`s are **untouched**.
- The translation lives in the **shared engine** input path (not iOS's `brogueByte`), so desktop's
  SDL input feeds the same canonical pipeline → upstreamable.
- A remap inside `executeKeystroke` (after recording) was rejected: it would bake the scheme into the
  recording and break cross-scheme/leaderboard replay.

**Implementation point:** apply the active scheme's lookup inside `nextKeyOrMouseEvent` when building
the `KEYSTROKE` event — translate the base keycode through the scheme table, preserve the
`controlKey`/`shiftKey` flags, then let recording + dispatch proceed on the canonical result. Replay
uses `recallEvent` (already canonical) and is never re-translated.

## The two schemes

A "scheme" is a table mapping **physical key → canonical engine key**. Only one is active at a time.

### Classic (default)
Identity — today's behavior unchanged: `hjkl`+`yubn` movement, numpad (`NUMPAD_n` == ASCII digit, so
the number row already moves), all commands on their current keys.

### Modern — right-hand 3×3 grid (home-row anchored)

```
 u  i  o        UL  U  UR
 j  k  l    →    L  ·  R       center k = wait (canonical PERIOD_KEY)
 m  ,  .        DL  D  DR
```

`j k l` rest on home row (`j` bump = blind anchor). Physical → canonical:

| Physical | Canonical | Physical | Canonical | Physical | Canonical |
|----------|-----------|----------|-----------|----------|-----------|
| `u` | UPLEFT (`y`) | `i` | UP (`k`) | `o` | UPRIGHT (`u`) |
| `j` | LEFT (`h`) | `k` | WAIT (`.`) | `l` | RIGHT (`l`) |
| `m` | DOWNLEFT (`b`) | `,` | DOWN (`j`) | `.` | DOWNRIGHT (`n`) |

**Run** = **Shift+grid** (and Ctrl+grid — the engine already treats both as run:
`if (controlKey || shiftKey) playerRuns(...)`). This is the priority requirement: Shift locks
directional movement on all 8 directions exactly like Classic. The grid's uppercase
(`U I O J K L`) are free; the three that *weren't* (`M`, `<`, `>`) are vacated below.

**Displaced commands (Modern only — Classic keeps all of these on their letters):**

| Command | Classic key | Modern key | Why |
|---------|-------------|-----------|-----|
| inventory | `i` | `e` | `i` is now UP; `e` freed by moving equip to Shift+E |
| equip | `e` | Shift+`E` | `E` currently unbound |
| message archive | `M` | `p` | frees `M` so Shift+`m` = run-DL; `p` harmless on misclick, log also tap-accessible on iOS |
| ascend stairs | `<` (Shift+`,`) | Shift+`P` | frees Shift+`,` = run-DOWN; shift-gate = the "don't run off accidentally" safety |
| descend stairs | `>` (Shift+`.`) | Shift+`:` (Shift+`;`) | frees Shift+`.` = run-DOWNRIGHT; same safety, near the hand |

Everything else on the **left hand** is identity-mapped and unchanged: `a`pply, `s`earch, `d`rop,
`w` swap, `z`/`Z` rest, `x` explore, `c`all, `t`hrow/`T`, `r`emove/`R`, `f`/`g`, `A`utopilot,
`S`ave, `D`iscoveries, `C`reate, `\` colors, `]` stealth, etc. `z` still rests, so center-`k` wait
is additive, not a replacement.

### Quit removed (both schemes, iOS)
`QUIT_KEY` (`Q`) is dropped as a keystroke on iOS — quit stays the `actionMenu` button only. A quit
keystroke is pointless on a touch device, and it retires the one collision (`Q` vs run-up-left) that
couldn't otherwise coexist.

## The `?` layout screen (repurposed help) + in-screen toggle

- `BROGUE_HELP_KEY` (`?`) already calls `printHelpScreen()`. **Repurpose that overlay into the
  scheme-aware "Keyboard" screen**: render the *active* scheme — the Modern grid drawn as a 3×3, or
  the Classic vi-key list — plus the command reference and the touch notes.
- **No new menu item.** `?` is the entry point (the existing keyboard-gated Help entry in
  `actionMenu` already routes here; leave the menu unchanged). On pure-touch with no keyboard the
  screen is unreachable and irrelevant by design.
- **Scheme toggle on the screen itself (decision A):** the screen is lightly interactive — a labeled
  affordance (key/tap) flips Classic ↔ Modern, redraws the layout, and persists. Space/esc/click
  dismisses. Seeing and choosing happen in one place.
- Labels: **"Classic"** and **"Modern"**, with subtitles — *Classic: vi-keys (`hjkl`+`yubn`,
  numpad)* and *Modern: right-hand grid (`uio/jkl/m,.`), laptop-friendly*.

## Persistence
Store the chosen scheme like CE's graphics mode (`ceLoadPersistedGraphicsMode` pattern); mirror an
equivalent for Classic via the platform layer. **Default = Classic** (no surprise for existing
players or recordings). Scheme is a display/input preference, never game state — save-safe.

## File touchpoints (mirror in both engines)
- **`IO.c`** — scheme table + translation in `nextKeyOrMouseEvent`; repurpose `printHelpScreen`
  (CE `:4145`, Classic `:3731`) into the scheme-aware screen with toggle; `actionMenu` unchanged.
- **`Rogue.h`** — scheme enum / active-scheme accessor (key `#define`s stay as the canonical target).
- **`Recordings.c`** — no change to format; confirm translation precedes `recordEvent`.
- **iOS quit removal** — gate `QUIT_KEY` dispatch off on tablet (both engines).
- **`CEBridge.mm` / `BrogueCEHost.h` / `BrogueViewController.swift`** — scheme persistence hook;
  keep Swift `brogueByte` arrow→`HJKL` mapping (already canonical); the engine does scheme translation.
- **Docs** — `IOS_MODIFICATIONS.md` in both engine trees (inline `// iOS port (iBrogue):` markers);
  update the help-screen content.

## Prerequisite discovered during implementation: iOS drops keyboard modifiers

The iOS hardware-keyboard pipeline is **byte-only** — `nextKeyOrMouseEvent` in both bridges
(`CEBridge.mm:448`, `RogueDriver.mm:179-180`, the latter with the modifier code commented out)
hardcodes `returnEvent->controlKey = shiftKey = 0` for keystrokes. The host key queue
(`addKeyEvent`/`dequeueKeyEvent`) carries a single `UInt8`. So **Shift/Ctrl-run does not work on iOS
today** — a shifted movement key only differs by its uppercase character, and `playerRuns` is gated
on `controlKey || shiftKey`, which are always false.

Since "Shift+move = run" is the priority, this must be solved first. Two approaches:

**Decision: plumb real modifiers** (the byte-only queue was legacy, not a platform limit — iOS exposes
`UIKey.modifierFlags` directly). Widen the host key queue to carry the key plus shift/ctrl flags, and
set `returnEvent->controlKey`/`shiftKey` from them in both bridges. Then real Shift/Ctrl works for
*every* key uniformly, the engine's existing `controlKey || shiftKey` run-check just works, and there's
no "uppercase = run" cleverness.

While widening the queue, also carry the **full key code** (not a single byte) so **arrow keys send
their real codes** (`UP_ARROW` = 63232, …) instead of today's `HJKL`-byte hack. That keeps arrows
**scheme-independent** — they're not letters, so no scheme remaps them, and `executeKeystroke` already
handles the `UP_ARROW`/`DOWN_ARROW`/… cases. (The byte-only queue was the sole reason arrows were
mapped to letters; widening removes that constraint.)

Scheme translation then operates on the delivered char (the *shifted* char, as today — so Classic keeps
`<`/`?`/etc. for free) with the real modifier flags available: movement keys map to canonical
directions and run rides on the real shift flag; discrete shifted commands (Shift+`P`/`:`/`E`) map by
their shifted char.

Touchpoints: `BrogueViewController` (queue element + `addKeyEvent`/`dequeKeyEvent` + `brogueByte`
arrows + `pressesBegan` reads `modifierFlags`), `CEHost.swift` + `BrogueCEHost.h` (protocol method),
`CEBridge.mm` and `RogueDriver.mm` (set the flags). Benefits both engines.

## Out of scope / deferred
- **Arbitrary user remapping** (the editor/conflict-UI) — the scheme-table indirection is built so
  this is a later increment, but not now.
- **Key-repeat** for held movement/rest/search — a separate *platform-layer* concern (iOS
  `pressesBegan` fires once; desktop SDL repeats natively). Tracked separately, not part of schemes.
