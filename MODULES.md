# Farroad — module split and build pipeline

## The shape

Source lives as separate files that can be executed and tested. The **delivered
artifact stays one self-contained HTML file**, because Ian opens it directly from
disk on phone and desktop, and a multi-file page over `file://` hits local-file
security restrictions and won't load. The split is entirely on the verification
side; the played artifact is unchanged.

```
src/farroad-core.js          combat engine — HEADLESS, no DOM
src/farroad-progression.js   economy, curves, drops, enemy building — HEADLESS
src/farroad-save.js          G <-> plain snapshot, and back — HEADLESS
src/farroad-ui.js            renderer, input, tabs, storage — DOM-bound by design
src/shell.html               doctype, CSS, body markup, script placeholders

split.js            one-time: fused HTML  -> src/
build.js            every build: src/     -> farroad-prototype-vX.html
farroad-smoke.js    runs the test suite against src/ with no browser
```

## Boundaries, as verified in the current file

| block | lines | `document` refs | `window` refs |
|---|---|---|---|
| `farroad-core` | 374–1030 | **0** | 1 — its own export |
| `farroad-progression` | 1032–1406 | **0** | 2 — export + core import |
| UI | 1408–2431 | many (correct) | many (correct) |

The core and progression layers were **already headless** — the only globals
either touches are the export and import statements. That was checked against
the real file, not assumed, and it is why this refactor is low-risk: the
boundary already existed, it just wasn't enforceable.

`build.js` now enforces it. Every build fails if `document`, `localStorage`,
`alert` or `requestAnimationFrame` appears in core or progression, or if either
touches a global other than its own export. The rule is machine-checked from now
on rather than being a convention that erodes. `farroad-save.js` joins the same
enforced set (see below) — it is checked, not just written, to stay headless.

## Why the round-trip is safe

`split.js` only **slices** on markers already in the file. `build.js` only
**concatenates**. Neither reformats, minifies, or rewrites a character, so
`build(split(x)) === x` byte for byte. `node build.js --check <original>`
asserts it.

This matters because "the refactor is a no-op" then stops being a hope and
becomes a check. Hand-retyping 2,200 lines would have been the single largest
error source in the project — the same class as the `cfg`, `WAVE_EXP` and `busy`
bugs — so the pipeline is built to never require it.

## Running it

```sh
node split.js farroad-prototype-v0.9.html   # once, to bootstrap src/
node build.js --check farroad-prototype-v0.9.html   # prove round-trip
node farroad-smoke.js                       # run the suite
node build.js                               # emit the fused HTML
```

## What the smoke test covers

1. **Modules load headlessly** — core and progression in a bare VM context, no DOM.
2. **Free-variable sweep** — calls every exported function and flags `ReferenceError`.
   This is the `cfg` / `WAVE_EXP` / `busy` class: under `'use strict'` an undeclared
   identifier throws when reached, which is why each of those survived until a
   specific state hit them.
3. **Seeded determinism** — the same seed must produce the same fight. This is the
   before/after comparison that proves a change is a no-op.
4. **Curve sanity** — `waveScale` finite and monotonic to wave 10,000.
5. **Headless batch** — 200 fights run away from any main loop, with throughput
   measured. This is the shape idle quests need (roadmap item 4).

## Save / load — built

`src/farroad-save.js` sits between progression and UI, exactly as planned below:
`S.serialize(G, now)` and `S.deserialize(snapshot, C)` are pure, headless, and
covered by `farroad-smoke.js`'s round-trip test (fields preserved, RNG restored
to the exact call position, no exceptions on a JSON round-trip). The UI layer
(`farroad-ui.js`) owns everything the save module deliberately doesn't: reading
and writing `localStorage`, and the offline-progress grant on load
(`P.OFFLINE_CAP_SEC`, 12h — see progression.js for why that number and not the
full §1.4 simulator).

**No manual Save/Load/Clear-save controls.** Saving is fully automatic: it is
hooked into `renderAll()`, which already runs after essentially every state
change in the game (wave clears, purchases, gambit/loadout edits, pulls),
throttled to 2s of wall-clock time so it doesn't hammer `localStorage` during
fast auto-battling; idle-income accrual and tab close/backgrounding each get
their own explicit call since they don't route through `renderAll()`. There is
no dedicated "clear save" control — **Reset run** already starts a fresh game
and its own autosave immediately overwrites the old save, so it doubles as one.

**Scope actually shipped vs. the general format below:** the snapshot covers
meta-progression — wave, currencies, roster, levels, loadouts, one-time-reward
history — not a live mid-fight `Battle` (HP, statuses, charge gauges, tick
position). Loading resumes at the **start** of the current wave rather than
freezing it mid-tick, the same way a wipe already returns to a wave boundary
rather than a fight-interior point. Extending the snapshot to a fight-exact
format is what async PvP (roadmap 6) will actually need for a *replayable
opponent snapshot*, and remains open — see below.

**Still true, and still the design constraint for that extension:** async PvP
(replaying a stored opponent party) and idle quests (handing a benched party to
the headless core) want the same serialisation as save/load, and all three break
the same way — if any input to combat is missing from the format, replay
diverges silently. See GDD §0.2 for the full field list a fight-exact format
would need. Widening a shipped format later means migrating existing saves; the
current field list already lives in `farroad-save.js`'s `FIELDS` array as a
single, explicit place to extend.
