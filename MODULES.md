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

**In-page version badge.** `shell.html` carries `<!--@@VERSION@@-->` and
`<!--@@BUILD_STAMP@@-->` placeholders (both header blocks — creation screen
and main app); `build.js` fills them with `FARROAD_VERSION` (same value the
output filename uses, default `v2.9`) and a `built YYYY-MM-DD HH:MM UTC`
timestamp generated at build time. The version number alone isn't enough to
tell builds apart during a stretch of same-version iteration — several
distinct builds shipped as "v2.9" in one day — so the timestamp is what
actually disambiguates "is this the file Claude just sent me" without
requiring a version bump for every change.

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
6. **Save/load round-trip** — fields preserved, RNG restored to the exact call
   position, survives an actual JSON round-trip.
7. **Customisable-first-unit math** — point-buy bounds land exactly on the
   ROSTER's own floor/ceiling for all ten offered stats, growth rises with
   points spent on every stat that has a growth curve, CRIT/BLOCK/EVADE
   correctly get none, and every offered charge action resolves to a real,
   actually-a-charge-action entry with no overlap with the five companions'.

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
no dedicated "clear save" control — **Reset run** deletes the save outright
(behind a native `confirm()`, since it also discards the player's built
character — see the customisable-first-unit section below) and sends the
player back through character creation, rather than restarting the same
character at a new seed. `showMcCreate()` resets the creation FORM too (name
field, point allocation, charge pick), not just the save, so the screen it
shows can't silently recreate the character that was just deleted.

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

## Customisable first unit — built (GDD §0.2 item 1)

Shown once, only when there is no save to resume (`showMcCreate()` in the UI
bootstrap) — an existing run's Kesh, custom or default, is never touched. The
formula lives in `progression.js` (`P.MC_STAT_KEYS`, `MC_STAT_RANGE`,
`MC_GROWTH_RANGE`, `MC_PCT_STATS`, `mcBuildStats`), bounded by the ROSTER's
own min/max per stat so a player build can never exceed an already-shipped,
already-balanced specialist in any one stat — see the comment block above
those constants for the full reasoning and the correlation it's matching
(highest base stat = highest growth in that stat, already true of the shipped
five). Covered by a headless smoke test (§ above, item 7).

**Every stat but one.** `P.MC_STAT_KEYS` lists all ten offered:
ATK/MAG/DEF/RES/SPD/HP/ATK-CRIT/MAG-CRIT/BLOCK/EVADE, 50-point pool (10 x 5
default). HP got its own point rather than riding the DEF choice as first
shipped — cleaner and lets DEF and tankiness-via-HP be separate decisions.
CRIT/BLOCK/EVADE have no growth curve, because `P.statsAt()` gives NONE of
them a growth curve for any unit — a level-1 point is that stat for the whole
run, same as it always has been for the five companions. `chargeRate` is the
one field deliberately NOT offered: all five shipped units carry the same 1.0,
so there is no already-played range to bound a choice against.

**No ROSTER/GROWTH factory.** Rather than threading a per-unit override
through every `C.ROSTER` lookup site (nine of them — buildParty, renderLore,
autoEquip, the loadout editor's charge box, the new-companion flavor text...),
`applyCustomMC()` in the UI layer mutates the existing `kesh` entries in
`C.ROSTER`/`P.GROWTH` in place, the same pattern the row-toggle button already
used on `C.ROSTER`. Every one of those nine sites already reads from those
tables, so none of them needed to change. Called after every place `G` gets
established: fresh creation and resuming a save. (Reset run no longer calls
`boot()` directly with a carried-over `G.mc` — it clears the save and routes
back through creation instead, so `applyCustomMC()` runs again there too, on
whatever the player builds next.)

**Charge action choice reuses existing content.** The 8 options offered are
the "corner" charge actions already authored in core.js's CHARGE ACTION
DESIGN SPACE (`tideturn`, `lastlight`, `sunder`, `gravewind`, `reckoning`,
`bulwarkoath`, `emberglut`, `hollowtoll`) — balance-considered content that
existed but wasn't assigned to any roster unit, not new numbers invented for
this feature. Each card also shows "N of 10 Lore upgrades apply to this
action" (same count `renderLore()` computes in-game via `C.bonusApplies`) —
support/utility picks like Tideturn (3 of 10) or Last Light (2 of 10)
genuinely have fewer live bonuses than a damage-shaped one like Reckoning
(6 of 10). That's the deadness matrix working as designed, not a missing
feature — the Lore tab already offered the same upgrades before this, the
count just wasn't visible until the point of picking.

**Persistence:** `G.mc` (`{name, stats, hp, growth, chargeAction}`, or `null`
for the hardcoded default) round-trips through `farroad-save.js`'s `FIELDS`
list like everything else. An old save from before this feature simply has no
`mc` field, which `applyCustomMC()` treats as "use the hardcoded Kesh" — no
migration needed.

**Name is sanitized, not escaped.** The only free-text player input in the
game strips `< > & " '` at creation time (`mcSanitizeName`) rather than
HTML-escaping at every render site, because the rest of the codebase already
inserts unit names via `innerHTML` unescaped everywhere (trusted "developer
content" so far) — closing the one new untrusted-input gap at its source was
far less invasive than auditing every call site.

**What GDD item 1 asked for that this doesn't touch:** the 20 unwritten
companions still want to be authored as data rather than as ROSTER literals —
that part of the original implication is untouched by this change.
