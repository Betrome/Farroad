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
   correctly get none, and every starter/drop-pool charge id resolves to a
   real charge action with no overlap with the five companions'.
8. **Charge action starter/drop-pool separation** — the three starters are
   provably plain (power present, no attached status/lifesteal/revive), the
   starter set and the rare-drop pool never share an id, and the drop chance
   is a real, appropriately low probability.
9. **Escalating Lore bonus cost** — a first stack still costs the old flat/
   swift-tiered base, cost is non-decreasing and meaningfully higher after
   several stacks (not just occasionally), swift's speed-tier rule still
   holds at stack 1 with the same escalation layered on top, and
   `bonusSpend` reconstructs the exact total paid by summing the series
   rather than `stacks x current price`. Broad is provably flat at its own
   `BONUS_COST_BROAD` regardless of stacks already owned, and distinct from
   the normal per-stack base.

**Broad is priced separately: flat 50, no escalation.** It isn't a magnitude
bonus like the other eight — `applyBonuses()` flips the action from single-
to multi-target the instant ONE stack exists, and every stack after that
does nothing (and `bonusApplies` correctly hides it once the action is
already multi-target, so a wasted 2nd purchase isn't even offered). Pricing
it like a repeatable bonus undersold a strong one-time unlock, so
`bonusPrice()` special-cases `bid==='broad'` to return `BONUS_COST_BROAD`
(50) unconditionally, before the swift/escalation branches even run.

**Keen's description now reads "+8% crit"**, not "+8pp" — cosmetic only,
the underlying math (`critBonus += 0.08 x stacks`, clamped to `CAP_CRIT`
at combat time) didn't change.

## Lore bonus cost — now a per-action linear counter (two follow-ups)

Idle Aether/Marks were cut hard this session (`P.idlePerSec`'s base
coefficients: 0.7/0.35 -> 0.1/0.05 -> 0.01/0.005 — see progression.js for the
full reasoning), but at endgame most Marks-funded drops are duplicates
anyway and become Lore regardless of the idle rate, so Lore bonuses needed
their own fix. Before this, every bonus stack cost the same flat price
forever (`BONUS_COST=2`, or a fixed swift tier of 2/4/6 based on the
action's speed) — the 1st and 50th stack were identical, so nothing ever
stopped being an auto-buy once Lore was abundant.

**First pass** made `bonusPrice(a, bid, n)` multiply that base by
`BONUS_GROWTH` (1.15) once per stack of THAT bonus already owned on the
action. It worked, but left a loophole: escalation was scoped to a single
(action, bonus) pair, so spreading purchases across DIFFERENT bonus types on
one action never triggered it — stack 1 of five different bonuses on the
same action was five separate "stack 1" base prices, so an action could
still be maxed out cheaply as long as no single bonus was stacked deep. That
directly worked against the actual goal (discourage dumping everything into
one action), so it was reworked rather than tuned further:

**Current model**: price is keyed to the ACTION's total upgrade count —
every non-broad bonus on it, combined (`actionBonusTotal(b)`) — not any one
bonus's own stack count. A fresh action's first Lore upgrade, whichever
bonus it is, costs 1; every further upgrade on that SAME action costs one
more than the last, regardless of which bonus type. Buying Swift then Potent
on one action prices Potent's first stack at 2, not 1, because the action
already has one upgrade — this is what actually taxes "focus everything on
a single action," at the action level rather than the bonus level. Swift's
old speed-tiered base (2/4/6) is retired along with the geometric curve —
redundant once the per-action counter does that job for every bonus, not
just swift. Broad stays exempt and flat at `BONUS_COST_BROAD` (50): a
one-time unlock (`applyBonuses` flips behaviour the moment ONE stack exists;
further stacks do nothing), not a repeatable magnitude buy, so it neither
pays into nor counts toward the linear total other bonuses escalate against.

`bonusSpend` no longer needs to replay a purchase sequence — since price
depends only on the action's running total, not on which specific bonus or
what order, the total cost of K non-broad stacks on one action is the
closed-form triangular sum `K*(K+1)/2`, plus `stacks x BONUS_COST_BROAD`
for broad, regardless of how those stacks are split across bonus types.
Covered by headless smoke checks (§ above, item 8) and verified live: buying
one bonus on Strike correctly raised the LISTED price of every OTHER
(unbought) bonus on Strike to 2, while a completely separate action (Kesh's
charge action) stayed at 1 — confirming the escalation is per-action, not
global — and refunding the purchase correctly reset both the price and the
free-Lore total.

## Unit level-up cost doubled (Aether outpacing difficulty)

`P.expFor(L)` (progression.js — the cumulative-cost curve `P.marginal`/
`P.costToNext` derive a unit's next-level Aether cost from) had its
coefficient doubled, 0.4->0.8: every level now costs exactly 2x what it did.
The exponent (2.8), and so the curve's overall SHAPE, is untouched — this is
a flat rescale of the whole curve, not a steeper ramp, because Aether income
was outpacing the intended difficulty curve broadly, not specifically at
early or late levels. Reference costs: LV 10 252->505, LV 50 22,865->45,731,
LV 100 159,243->318,486, LV 1000 100.5M->201.0M.

## Save / load — built

`src/farroad-save.js` sits between progression and UI, exactly as planned below:
`S.serialize(G, now)` and `S.deserialize(snapshot, C)` are pure, headless, and
covered by `farroad-smoke.js`'s round-trip test (fields preserved, RNG restored
to the exact call position, no exceptions on a JSON round-trip). The UI layer
(`farroad-ui.js`) owns everything the save module deliberately doesn't: reading
and writing `localStorage`, and the offline-progress simulation on load
(`P.OFFLINE_CAP_SEC`, 12h — see progression.js for why that number and not the
full §1.4 estimator).

**Offline progress is a real simulation, not an estimate.**
`simulateOfflineProgress()` plays the road forward on resume using the exact
same functions live play uses — `startWave`, `C.step`, `afterWaveCleared`,
`onWipe` — for however many waves fit in the elapsed time at `20+
P.travelSec(w)` seconds each (the same per-wave cost `P.wavesPerHour()` is
itself derived from), plus the ambient `idlePerSec()` trickle live play earns
concurrently, both capped at `P.OFFLINE_CAP_SEC`. `tryResumeSave()` calls
`startWave(G.wave||1,true)` FIRST (rebuilding a valid `G.battle` for the
wave the player was actually on, `skipDrops` so it isn't re-granted) and
only then runs the simulation — the loop needs a real battle in progress to
step forward from, and `Save.deserialize()` always hands back `battle:null`.

Because it's the real engine and not a formula, **a wipe can genuinely
happen while the player is away**, sending them back to their last
checkpoint exactly as it would live — a deliberate choice of full fidelity
over GDD §1.4's stated "offline never wipes" rule (see that section for the
tradeoff). This is still not §1.4's full node/Waymark estimator (no
auto-invest, no danger-halt) since this prototype has no node-based map to
advance along — it's the same combat core simply run unattended, which is
exactly the shape the smoke test's 200-fight headless batch already proved
out safe to do at scale.

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
`MC_GROWTH_RANGE`, `MC_PCT_STATS`, `mcBuildStats`), originally bounded by the
ROSTER's own min/max per stat, then widened per Ian's request for more build
variance — ceilings scale up and floors scale down from those roster bounds,
so a player build CAN now exceed a shipped specialist in a stat (a deliberate
tradeoff of the earlier "never exceed shipped values" guarantee). See the
comment block above those constants for the full reasoning, the correlation
it's matching (highest base stat = highest growth in that stat, still true of
the shipped five), and the balance-correction note (below). Covered by a
headless smoke test (§ above, item 7).

**Every stat but one.** `P.MC_STAT_KEYS` lists all ten offered:
ATK/MAG/DEF/RES/SPD/HP/ATK-CRIT/MAG-CRIT/BLOCK/EVADE, 75-point pool, 0-15 per
stat, every stat starting at 0. HP got its own point rather than riding the
DEF choice as first shipped — cleaner and lets DEF and tankiness-via-HP be
separate decisions. CRIT/BLOCK/EVADE have no growth curve, because
`P.statsAt()` gives NONE of them a growth curve for any unit — a level-1 point
is that stat for the whole run, same as it always has been for the five
companions. `chargeRate` is the one field deliberately NOT offered: all five
shipped units carry the same 1.0, so there is no already-played range to
bound a choice against.

**Balance correction.** A "max one stat, spread the rest of the pool evenly"
specialist was simulated wave-by-wave (real enemy curve, real leveling off
real Aether income) for all ten stats after the widening: seven landed within
noise of a 5-wave mean, but ATK/MAG/SPD's ceiling let them compound (linear
damage/turn-order stats, unlike DEF/RES's diminishing-returns mitigation or
the capped CRIT/BLOCK/EVADE) to a 14+ wave mean. Their ceilings were re-fit
as a joint problem — not just each stat's own maxed mean, but the "spread"
contribution every OTHER build draws from those same three stats — landing at
atk 39->26, mag 45->30, spd 186->131. All ten now cluster at a 4-5 wave mean
with no dominant pick; floors were untouched since they never drove the
imbalance.

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

**Creation offers 3 GENERIC starters, not the 8 corners.** `heavystrike`,
`wildfire`, `greatheal` (core.js's "MC GENERIC STARTERS") are plain bulk
physical / bulk magic / heal, no attached effect — deliberately NOT the
build-around "corner" actions (`tideturn`, `lastlight`, `sunder`, `gravewind`,
`reckoning`, `bulwarkoath`, `emberglut`, `hollowtoll`) from core.js's CHARGE
ACTION DESIGN SPACE, which used to be the creation-time offer and are now the
rare-drop pool below instead (`P.MC_STARTER_CHARGES` vs. `P.MC_CHARGE_DROP_POOL`
in progression.js). Each card shows "N of 10 Lore upgrades apply to this
action" (same count `renderLore()` computes via `C.bonusApplies`) — an AoE or
heal-shaped pick is dead on more of the ten than a single-target damage one
(6 / 4 / 4 across the three starters), which is the deadness matrix working
as designed, visible before committing rather than only after.

## Charge action acquisition & swapping — built (GDD §0.2 item 2)

The 8 "corner" charge actions are now a rare RANDOM drop, gated to `G.mc`
existing (MC only) and the random-drop phase only (`randomDrop()` in
farroad-ui.js, post wave-20 — `grantDrops` never calls it during the curated
run, so the authored tutorial is untouched). `P.MC_CHARGE_DROP_CHANCE` (5%)
is checked first, before the normal action/condition branch, and REPLACES
that wave's drop rather than adding to it — a charge action is a bigger deal
than either, so it costs the player their usual item that wave. A duplicate
converts to Lore exactly like a duplicate action or condition. At 5%, the
coupon-collector expectation for completing the 8-action pool is 8 x H(8) ≈
21.7 drop events, i.e. on the order of 400+ waves of random drops — "much
more rare" than the guaranteed per-wave drop it can replace.

Acquired ids live in `G.mc.acquiredCharges` (starts as `[starterPick]` at
creation; an old save from before this existed gets backfilled to the same
shape by `applyCustomMC()` the first time it runs). The swap control appears
in the GAMBITS tab's per-unit box — the same place the charge action was
already shown — as a `<select>` once `acquiredCharges.length>1`, replacing
the former dead branch that read `G.chargeAction` (a field nothing ever set,
left over from a v0.8→v0.9 rename). Swapping is free and instant, and does
TWO things: `applyCustomMC()` updates the ROSTER template (so the next wave
picks it up), and the handler ALSO patches the live `G.units` entry directly
— without that second step a swap mid-fight would silently do nothing until
the wave ended, since `buildParty()` only copies `chargeAction` onto a unit
once, at wave start. Found by testing, not by inspection.

**Lore already follows the action, not the unit** — the GDD's own
recommendation for this, true for free: `G.bonuses` was already keyed by
action id everywhere in the codebase, so each acquired charge action keeps
its own Lore stacks independently, and switching back restores whatever was
bought on it. No new bookkeeping needed.

**Persistence:** `G.mc` (`{name, stats, hp, growth, chargeAction,
acquiredCharges}`, or `null` for the hardcoded default) round-trips through
`farroad-save.js`'s `FIELDS` list like everything else. An old save from before this feature simply has no
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
that part of the original implication is untouched by this change. (Update:
5 of those 20 are now written — see below.)

## Roster expansion 5→10 — prerequisite for item 4 (idle quests)

Item 4 (idle quests for benched units) is explicitly paused, but it needs
units to actually BE benched, which the game couldn't do: `G.owned` vs
`G.party` already existed as separate concepts (the pull UI already labelled
the state "Benched"), but with only 5 companions authored against
`PARTY_CAP=5`, every owned unit was always fielded — the instant all 5 were
owned, every further pull or boss reward converted straight to Aether instead
of ever producing a 6th owned unit. `skarn, sorin, nyra, brenn, sael` (10 of
a target 25) exist to make a real, persistent bench possible.

**Pull-only, no engine changes needed.** New companions are acquired purely
through the existing Marks pull (`doPull()` in farroad-ui.js already draws
generically from `C.ROSTER.filter(!G.owned[id])` with zero unit-count
assumptions) — the boss-milestone schedule (waves 20/150/500/1500) is
untouched and none of the five get a milestone wave. Every other system that
touches `C.ROSTER` (buildParty, renderLore, the loadout editor's charge box,
save/load) already iterates it generically, so this was close to pure data
addition — no new mechanics, only new numbers.

**Numbers are bounded by the existing five, not new extremes.** Every stat
and growth value sits inside the ranges `P.MC_STAT_RANGE`/`MC_GROWTH_RANGE`
already encode (themselves derived from the original five) — new
combinations within the existing envelope, so the customisable-MC creation
screen needed zero changes. Each new unit's `atk+mag+def+res+spd` growth
sums to exactly 7.5, matching the original five's 7.3–7.7 band. No new unit
ties or exceeds an existing per-stat champion; two were placed one notch
under a leader on purpose (Skarn's atkCrit .11 under Vey's .12; Brenn's
evade .09 under Vey's .10) so that leader's identity stays unambiguous.
Design rationale for each unit and its charge action lives in
farroadgdd.md's roadmap item 4 note and this session's plan file.

**Covered by 6 new headless smoke-test checks**, all pure data validation
(no combat/UI needed): exactly 10 unique `ROSTER` ids; every unit's stats
(including hp) fall within `P.MC_STAT_RANGE`; every unit has a `P.GROWTH`
entry within `P.MC_GROWTH_RANGE`; the 5 new units' growth budgets sum to
exactly 7.5; every `chargeAction` id is unique across the roster, resolves to
a real `isCharge` action, and doesn't collide with the MC's reserved
`MC_STARTER_CHARGES`/`MC_CHARGE_DROP_POOL` ids. These double as a regression
guard for any future roster edit, not just this one.

**Verified live via Marks pulls** (not just manual save edits): pulled
against the expanded roster until the party filled to 5, then confirmed the
next two companion pulls correctly landed as owned-but-benched rather than
fielded or lost.

**Found in passing, fixed in a follow-up.** The pull's companion-drop object
carried a `note` field ("Fielded immediately" / "Benched — your party is
full...") that neither `renderDropNote()` nor `renderDrops()` ever read (both
only read `why`/`pair`/`body`) — a player pulling a new companion was never
actually told, anywhere in the UI, whether it joined the party or the bench.
Pre-existing (the same class of dead-field bug as `G.chargeAction`), only
became reachable/noticeable once benching was sustainable.

**The fix:** rather than patch just the companion case, `note` turned out to
be written by all six `doPull()` outcomes and read by none of them — a
systemic gap, not a one-off. The fielded/benched question is the one thing
the notification actually exists to answer, so that specific field was
promoted from `note` to `why` (already rendered, with the same prominent
`--hp`-colored styling curated-teaching moments use) rather than just wired
up as one more dim aside. The other five `note` uses (duplicate-currency
trivia, pairing hints, "you now hold N copies") are genuinely secondary, so
`note` rendering was added to both `renderDropNote()` (the live banner) and
the drop-history list in `renderDrops()` using the same dim treatment as
`pair` — fixing the history view too, which had the identical gap.

**Not touched:** `farroadunits.csv`, `farroadcontentdesigner.html`, and
`farroadcsvREADME.md` are the user's own authoring-workflow files (the CSV
still mirrors the original 5; the tool and README describe that same CSV
pipeline) — left alone rather than updated to a count they don't reflect.
`src/farroad-save.js` needed no changes (all persistence is already generic
dictionaries keyed by unit id).

## Expeditions, phase 1 — built (GDD §0.2 item 4)

The shared "send a benched party out, real time passes, they come back with
rewards" engine — open-ended exploration only, no dungeons/events/map/log/
quest-board/origin-chains yet (see the approved plan for phases 2-5).

**Reuses the offline-progress shape rather than inventing a new one.**
`resolveExpedition()` (`farroad-ui.js`) is `simulateOfflineProgress()`'s exact
pattern applied to a different clock: elapsed real seconds since
`G.expedition.lastResolvedAt`, capped at `P.EXPED_CAP_SEC` (=
`P.OFFLINE_CAP_SEC`), spent on battles at the identical `20+P.travelSec(w)`
per-wave pacing. The one real difference is the wave source: an expedition
tracks its own synthetic counter (`G.expedition.ew`, starting at 1) instead
of `G.wave`, so exploring is its own escalating-difficulty track — built by
feeding `ew` through the exact same `C.waveScale`/`P.archetypeFor`/
`buildEnemies()` machinery the main road uses (confirmed by this session's
own research: difficulty in this engine is a pure function of a wave-like
integer, nothing else, so no new scaling math was needed).

**Kept fully separate from the live battle.** An expedition builds its own
party (`buildExpeditionParty()`) and its own `C.makeBattle` instance — it
never touches `G.wave`/`G.battle`/`G.units`/`G.enemies`/`G.hpCarry`, so it can
resolve (including from the 30s background interval, below) without
disturbing a fight the player is actively watching. The one shared piece of
engine state is `C.setWave()`'s module-level `CURRENT_WAVE` (read by `K_of()`
for damage mitigation) — every expedition enemy build bumps it to `ew`, and
`resolveExpedition()` always restores it to `G.wave` before returning, so it
never leaks into a concurrent real fight's damage math.

**HP-triggered turn-back**, not a wipe-to-checkpoint. A carried HP fraction
(`G.expedition.hpFrac`, one scalar across the whole party, not per-unit)
mirrors `G.hpCarry` between expedition battles; once it drops below
`P.EXPED_RETURN_HP_FRAC` (0.25) — or the party is actually wiped — the party
turns back (`beginReturnTrip()`).

**Turning back — HP threshold or manual recall, same rule — isn't instant
and doesn't bank early.** The trip home costs HALF the real time the party
spent out, computed from a real timestamp (`decisionMoment`, the actual
wall-clock moment the turn-back happened — which for a big catch-up pass, or
a recall issued well into an expedition, can be well in the past relative to
"now") rather than a countdown, specifically so a long-enough absence can
resolve the WHOLE round trip — explore, turn back, travel home — in one
catch-up pass instead of leaving the party stuck "returning" until the next
check. `G.expedition.homeAt` holds that arrival timestamp; `resolveExpedition()`
checks it first and, once set, skips the battle loop entirely (no more
combat happens on the way home) and only asks "have they arrived yet".
Rewards sit in `G.expedition.bank` until `settleExpedition()` actually fires
on arrival — a recall never grants anything early.

**`recallExpedition()`** catches up on elapsed real time first (which may
itself trigger and even fully resolve an auto turn-back along the way), then
calls `beginReturnTrip(Date.now(),'recalled.')` if the party isn't already
heading home — i.e. it decides "turn back now" rather than later, the exact
same path an HP-triggered turn-back takes, just called from the button
instead of from inside the battle loop. A recall issued right after
departure reads as instant in practice (half of a couple seconds rounds to
nothing), not because it's special-cased, but because the shared formula
naturally produces a near-zero trip for a near-zero absence.

**A dedicated `setTimeout`, not just the 30s background poll, wakes a
turned-back party the moment it's actually due.** `scheduleExpeditionCheck()`
is called from `beginReturnTrip()` whenever `homeAt` lands in the future,
so a short remaining wait (a party recalled 10s into an expedition, say)
resolves itself on screen a few seconds later with no further click and no
reload needed, rather than sitting stale until the next 30s tick.

**Picked up two ways**, since there's no other "time has passed while the tab
stayed open" poller in this codebase (`tick()` only runs during active
combat playback): once on load via `tryResumeSave()` (same catch-up moment
`simulateOfflineProgress()` already uses) and once every 30s via a dedicated
`setInterval`, so a returning party shows up without requiring a reload.

**New save state**, same dictionary/id-keyed convention as `G.lvl`/`G.bank`/
`G.owned`: `G.expedition` (null, or the live record) and `G.expeditionLog`
(capped history array, same cap-and-unshift shape as `G.dropHistory`) — both
added to `farroad-save.js`'s `FIELDS`, with default-fill (`null`/`[]`) for
saves from before this shipped.

**UI**: one more tab (`EXPEDITION`), following the existing flat button+panel
tab pattern exactly — a benched-unit picker (click to select up to
`P.PARTY_CAP`) when nothing's out, live status (synthetic wave reached, time
away, banked-so-far) and a recall button when something is, and an inline
expedition log underneath either way.

**Covered by 8 new headless smoke-test checks**: the round-trip and
old-save-default-fill checks for `G.expedition`/`G.expeditionLog` in
`farroad-save.js`'s existing save/load section; `P.EXPED_RETURN_HP_FRAC`/
`P.EXPED_CAP_SEC` sanity; and that `P.killReward`/`P.isBossWave`/
`P.bossAether`/`P.travelSec`/`P.statsAt` — the exact primitives
`resolveExpedition()` calls against its own synthetic wave — stay
non-negative and finite across a synthetic climb well past where the curated
road ends. `sendExpedition()`/`resolveExpedition()` themselves are UI-layer
(DOM-bound) like `buildParty`/`buildEnemies`/`simulateOfflineProgress`, so
per this file's existing convention they're verified live instead (below),
not unit-tested headlessly.

**Verified live in-browser**, not just by reading the code, across several
rounds (same localStorage-edit technique used throughout this session for
offline-progress testing — edit from a tab that won't itself navigate, then
open a fresh tab to observe, to avoid the `beforeunload`-autosave race):
- A 5-hour backdated expedition caught up to synthetic wave 16, turned back
  on low HP, AND fully completed its (well inside 5h) trip home in the same
  load — settled with the exact reward total on top of seeded currency.
- A 10-minute backdated expedition turned back mid-catch-up but hadn't yet
  finished its trip home — correctly showed "heading home, ETA ~1 minute"
  rather than settling early.
- A save seeded with `homeAt` already 2 minutes in the past (turn-back
  happened on an earlier check, party now overdue) settled correctly on the
  very next load with its pre-banked reward.
- Live through the real UI: the party picker (click to select, caps at
  `PARTY_CAP`), send, the active-expedition status view, and manual recall
  all work end-to-end. Recall specifically: issued ~1-2s after departure it
  settled with no visible "heading home" state at all; issued ~10s into an
  expedition it correctly showed "heading home" with nothing banked yet,
  then self-settled a few seconds later via the scheduled check with no
  further clicks — confirming rewards don't bank until arrival, but a
  near-immediate recall still feels instant.

**Not yet built** (phases 2-5 of the approved plan): dungeons, events, the
world map, a dedicated adventure-log screen (the log itself is already being
written to `G.expeditionLog`), the quest board, and per-companion origin
story chains.

## Enrage gate is now battle-wide, not per-enemy

`ENRAGE_AFTER` (`farroad-core.js`) went 8→20, and its meaning changed from a
grace period in each ENEMY'S OWN turn count to one in the BATTLE's total turn
count (`b.beat`, both sides combined). Was: a fast enemy (e.g. Mire Hound,
spd 124) raced to its own 8-turn threshold in real fight-time regardless of
how the fight was actually going, sometimes ramping up ATK before the party
had a real chance to respond — a crippling start. The gate condition in
`step()` moved from `u.turnsTaken>ENRAGE_AFTER` to `b.beat>ENRAGE_AFTER`, so
enrage timing now tracks how long the FIGHT has run, not how fast any one
enemy happens to act.

Growth is still applied per-unit-action once the gate is open — a new
`u.enrageN` field counts THIS unit's own actions taken since the gate
opened (same +5%/turn compounding as before), so a fast enemy still racks up
stacks faster than a slow one from that point on, it just can no longer get
there ahead of the fight itself. `C.enrageStacks(u)` now simply reads
`u.enrageN` rather than computing `turnsTaken - ENRAGE_AFTER`. This does give
up the old free Slow/Cripple-delays-enrage synergy the gate used to have (a
Slowed enemy no longer enrages more slowly, since the gate itself is no
longer keyed to any one unit's own turn count) — a known, accepted tradeoff,
not an oversight.

Covered by a new headless smoke check (two near-immortal units — HP raised
to 1e9, not just DEF, so the test doesn't depend on `C.setWave()`'s ambient
`CURRENT_WAVE` — see the bugfix note below) confirming zero stacks before
the gate opens and accumulation after. Verified live: the in-game enrage
copy (shell.html's clock explainer, the enrage-toggle log message, and each
enemy's own "calm — enrages after turn N" display) all updated to match.

**Found and fixed in passing**: the smoke test's own "free-variable sweep"
(section 2 — calls every exported function with no arguments to catch
undeclared-identifier bugs) calls `C.setWave()` with no argument as a side
effect of that sweep, which sets the module-level `CURRENT_WAVE` to
`undefined` for the rest of the test run. Every damage calculation after
that silently read `NaN` out of `K_of()`, which is how this session's new
enrage test first surfaced it — nothing before it happened to run a real
multi-hit battle where that mattered. Fixed by resetting `C.setWave(1)`
right after the sweep, rather than leaving its side effect to leak into
every section that follows it.

## Aether/Marks income divided by 5

`P.AETHER_RATE` (0.90→0.18) and `P.MARKS_RATE` (0.65→0.13) — at the time,
the single shared multiplier feeding every Aether/Marks source in the game
(idle trickle, per-kill reward, boss hoards, and the duplicate-unit
conversion all either used these directly via `P.idlePerSec`/`P.killReward`
or derived from them), so one cut reached everything uniformly. Applied
here rather than to the idle base coefficients specifically because
expeditions (roadmap item 4) call `P.killReward()` directly for each battle
they resolve, not `P.idlePerSec()` — cutting only the idle side would have
left expedition income, a second automated income stream now running
alongside live play, completely untouched. (Idle income no longer shares
this formula at all — see the redesign below, which superseded it for
`idlePerSec` specifically; `killReward`, boss hoards, and the duplicate-unit
conversion still use `AETHER_RATE`/`MARKS_RATE` exactly as described here.)

## Idle income redesigned — floor + tempered, asymmetric growth

Two follow-ups after the /5 cut above. First, the idle-rate display
(`renderPurse()`) was changed from per-minute rounded to a whole number to
per-5-minutes with 2 decimals — at depth the per-minute Marks figure
rounded to a flat "0" and read as "income stopped" even though it was still
trickling in (e.g. ~0.26/min at wave 558). Second, and larger: `idlePerSec`
used to share `killReward`'s exact shape — `base x C.waveScale(farthest) x
RATE` — which meant idle income inherited combat's own scaling curve
wholesale (26x by wave 10000). Replaced with an explicit floor: Aether and
Marks idle income are now each EXACTLY `P.IDLE_FLOOR_PER_5MIN` (1) per 5
minutes at wave 1, guaranteed regardless of any rate constant, growing from
there via `P.idleGrowth` — `sqrt(waveScale(w))`, the same "want growth but
not the raw curve" tempering already used for enemy crit scaling — instead
of the raw curve `killReward` still uses. Aether and Marks grow at
different rates ABOVE that shared floor (`P.IDLE_AETHER_GROWTH_MUL=0.5`,
`P.IDLE_MARKS_GROWTH_MUL=2.0` — Marks fund pulls, needed in bulk, so idle
income leans toward it over a long run; Aether funds per-unit levelling, a
slower, more deliberate spend), applied to the growth term only (`g-1`), so
wave 1 stays exactly 1/5min for both no matter how asymmetric the growth
is — the floor is a hard guarantee, not a side effect of the rate math.
Verified: wave 1 -> 1.00/1.00 exactly; wave 558 -> 1.80 Aether / 4.21 Marks
per 5min (confirmed live, matching a standalone calculation); wave 10000 ->
~3.07 Aether / ~9.27 Marks, vs. the old formula's un-tempered 26x.

## Party roster editor — built (previously no way to change who's fielded)

`G.party` could previously only change via the boss-milestone auto-join and
a pull's auto-fielding-when-there's-room — no way to manually bench a
fielded unit or field a benched one. `renderPartyRoster()` (`farroad-ui.js`)
adds that: a PARTY section listing current fielded units with a `Bench`
button each, and a BENCHED section listing owned-but-unfielded units with a
`Field` button each, using the same `benchedUnits()`-style filtering
established for expeditions — units currently away on an expedition are
excluded from what's available to field (`availableForParty()`, which
additionally checks `G.expedition.partyIds`).

Lives at the TOP of the existing GAMBITS tab rather than a new tab of its
own: picking who's in the party and setting their gambits is one "build your
team" task, and this app already has eight tabs to scroll through on a
phone (a live concern now that Ian is playing on his). `fieldUnit()` runs
the same `autoEquip()` pass a pull or boss-join gets, so a newly-fielded
unit doesn't sit with a bare default loadout. `benchUnit()` refuses to empty
the party (disables its own button once only one unit remains) — nothing
else in the engine expects `G.party` to ever be empty. Neither function
retroactively touches an in-progress fight; the change takes effect at the
next `buildParty()` call (next wave, or after a wipe), same as any other
roster-composition change, and the roster panel says so explicitly.

Verified live: fielding a benched unit correctly moved it out of BENCHED and
into the PARTY list, gave it an auto-equipped loadout and its own gambit box
below, and updated the party-size counter; benching correctly reversed all
of that; and the last remaining party member's own Bench button was
confirmed disabled.

## Post-build feedback batch — 20 items across 8 groups

Ian played to wave 400+ and sent back a large, mixed batch: copy fixes, two
bugs, balance tuning, new content, and a UI restructure. Grouped and
implemented per the approved plan; see the individual comment blocks in
`farroad-core.js`/`farroad-progression.js`/`farroad-ui.js`/`shell.html` for
full reasoning at each change — this section is the roll-up.

**Copy/display**: MC role "Attacker"→"Traveler" (displayed capitalized via a
new `capRole()` helper, stored lowercase); "enemyies"→"enemies" (a naive
`+'ies'` pluralization bug in `renderHead()`); idle Aether/Marks rate now
shown near the top (`#idleRate`, populated in `renderPurse()`); duplicate-
drop/pull messages no longer name the specific item, just the conversion
result (`name:'+1 Lore'` etc., replacing `name:info.name` and dropping the
"you now hold N copies of X" notes); initiative shown as a whole number
(`×124` not `×1.24` — `initStr()` now does `Math.round(m*100)`, single
source feeding every call site).

**Bugs**: a real one — wiping into an UNCLEARED wave and re-entering it
re-ran `grantDrops()`, letting curated/random rewards be farmed indefinitely
by repeat suicide (the existing `clearedWaves` gate only ever blocked
already-WON waves). Fixed with a new `dropsGranted` dict, set the first time
`grantDrops(w)` ever processes a wave regardless of outcome — see the Group
2 note in the approved plan for the full trace. Verified live: seeded a
5-HP starter, forced three wipes at wave 1, confirmed "Wave 1 already
attempted — no drop" on repeat and no duplicate Lore/action grants. The
reported "present" condition bug (`foe_2plus`/`foe_3plus` allegedly counting
dead enemies) did NOT reproduce — `foes()` already filters to `hp>0` — no
code change made there, flagged back to Ian instead of guessed at.

**Balance/economy**: `P.MC_CHARGE_DROP_CHANCE` 5%→10%; a new independent
10% companion-drop roll on EVERY boss clear (not gated by first-clear or
milestone eligibility, repeatable by re-grinding a boss — same spirit as
`killReward` staying repeatable), using a new shared `joinCompanion(uid)`
helper that replaced three duplicated copies of the same `G.lvl/bank/owned/
party` mutation (boss milestone, this new roll, `doPull()`); pull pity — a
new `G.pullsSinceUnit` counter forces `kind='unit'` on the 30th pull since
the last one obtained (`P.PULL_PITY_AT=30`), resets on any unit outcome;
`P.SLOT_LEVELS` extended from `[1,1,10,25]` (4 slots) to `[1,1,10,100,500,
1000]` (6 slots) — 2 slots still guaranteed at L1, 3rd-6th now at
10/100/500/1000. All aimed at the same root complaint: reaching wave 400+
without a 3rd companion.

**New gambit conditions**: the HP-threshold ladder filled out to every 10%
decile (10-90, both directions) for Self/Ally/Foe — generated in `core.js`
rather than hand-typed ~49 times, reusing each group's existing resolver
shape exactly, and leaving the five pre-existing named entries
(`self_hp_lte_50` etc.) untouched since `GATE_FOR`/`PRI` and one enemy
archetype's own default gambit reference them by id. The condition dropdown
is now sorted by group (Self/Ally/Foe, "always true" first) instead of raw
acquisition order — 84 conditions in total now, unmanageable unsorted.

**Action/Lore display**: every action now shows which stat it scales with
(`scalesWith(a)`, reading `a.camp`) and its current effective power/rank
(already-live post-bonus values, no new math); the LORE tab additionally
shows a one-line "total bonus" summary per action, diffing the live
`C.ACTIONS[id]` against a newly-exported `C.pristineOf(id)` (the pre-bonus
baseline `applyBonuses()` already kept internally) rather than re-deriving
each bonus's math a second time.

**10 new MC charge actions** (one damage + one support per core stat):
required a genuine small engine addition, since damage/heal magnitude was
hardcoded to ATK/MAG via `camp` — a new `act.scaleStat` field, read by
`resolveHit`/`healFor` via a new `statByKey()` helper (DEF/RES reuse the
existing status-aware `effDef`/`effRes`; SPD reads `u.base.spd` directly,
since nothing in the engine has an "effective SPD" concept — Hasted/Slowed
modify turn cadence via `tcOf`, never the raw stat). Balanced so a build
maxing the relevant stat lands on roughly the same pre-mitigation base as
the existing MC starters (~118 for a single-hit damage action, ~78 for a
party heal — heavystrike/greatheal's own numbers are the reference points).
Added to `P.MC_CHARGE_DROP_POOL`, same rare-drop path as the original 8
corner charges. **Caught live, not by code review**: the new `spd_flurry`
was originally also named "Flurry", colliding with the pre-existing basic
action `flurry` — found by actually pulling it in the browser and seeing
two unrelated "Flurry" entries, renamed to "Fleetstrike". Added a permanent
smoke check (no two `C.ACTIONS` entries may share a display name) so the
next new action can't repeat this silently.

**Lore bulk refund**: a new button on the LORE tab refunds every unused
action's Lore in one click, showing the exact total before confirming.
"Unused" is computed against every OWNED unit's `G.loadout`/chargeAction
(not just fielded `G.party` — a benched unit's own investment is still
real), and separately protects the MC's WHOLE `acquiredCharges` pool, not
just the currently-equipped one, since swapping between them is documented
to preserve Lore investment. Refund itself needed no new crediting logic —
confirmed earlier this session that free Lore is always recomputed live
from the bonus map, so clearing unused entries refunds automatically.

**Layout restructure**: the ROAD tab (and the whole tab system with it) moved
above the units/battle panel and travel controls, cutting the scroll depth
to see the combat log — "a lot of scrolling" on a phone with a full 5-unit
party was the direct complaint. GAMBITS/AETHER/LORE each gained a shared
`selectedUnitTab` unit-picker (persists as you switch between the three
tabs) so they show one character's content at a time instead of stacking
every fielded unit vertically; LORE's version narrows to the selected
unit's own equipped actions rather than merging the whole party's.

**Verification**: 4 new headless smoke sections (scaleStat mechanism proven
via a controlled DEF-differential battle, not just definition checks; no
duplicate action names) bringing the suite to 56/56, clean `build.js`, and
an extensive live-browser pass seeding realistic saves for every item —
role/enemies-copy/idle-rate/layout confirmed in one screenshot, per-unit
tabs and action-scaling/bonus-summary display confirmed on GAMBITS/LORE,
condition ladder+grouping confirmed via a full-84-id dropdown dump, the
wipe-farm fix confirmed via three forced wipes at wave 1, pull pity and the
new charge-action pool confirmed via real pulls, and the refund button's
exact Lore math confirmed before and after clicking.

## One-unit-per-non-starter-action rule

`bonusPrice`'s escalating cost ladder is scoped to the *action*, not the
*party* — a Lore purchase that upgrades an action every fielded unit sharing
that action benefits at once, paying the escalating cost only once no matter
how many units cash in. An empirical balance test (5-unit party, matched
functional roles across both builds so no unit lost a capability, real
`C.step` combat, 150 seeds per data point) confirmed this is a real,
compounding incentive: a party that concentrates on a handful of shared
actions beat an equally-invested, role-appropriate varied build by 8-14% in
wave-survival once the Lore budget was large enough to matter, and the edge
didn't shrink as more Lore accumulated.

Fix: non-starter actions (`P.STARTER_ACTIONS` — `strike`/`ember` are exempt,
since every unit begins with them regardless) may only be equipped by one
FIELDED unit at a time. A follow-up test of this exact rule (same harness)
shrank the concentrated-build's edge from 8-14% down to roughly 1-4%, mostly
attributable to strike/ember themselves still being freely shared as the
baseline every unit starts with.

Implementation is UI-layer only (`buildGambits()` in `farroad-ui.js`), not
an engine restriction — `G.actions`/`G.loadout` themselves stay unconstrained,
same as before. A new `actionHolderInParty(actionId,excludeUid)` scans
`G.party` (fielded units only — a benched unit's loadout can't simultaneously
benefit from a shared upgrade, so it isn't restricted) for another unit
already holding a given non-starter id. The action `<select>` disables any
option already held elsewhere (with a tooltip naming the holder), but never
disables a slot's own current value — so an existing (pre-patch) save that
already has two fielded units sharing a non-starter action isn't silently
force-changed. Instead, a small warning line appears under that slot naming
the other unit and inviting the player to resolve it themselves; the moment
either side switches away, the warning clears. Verified live: seeded a save
with kesh/dorrek/vey all on Pierce, confirmed the disabled `<option>`s are
genuinely unselectable in the DOM (not just visually greyed), confirmed the
warning text and the option list update immediately when Dorrek's conflict
was resolved by switching to Cleave, and confirmed starters (Strike, used by
kesh/dorrek/vey throughout) stayed exempt.

## Late-game difficulty & UI-scroll batch

**No bosses past wave 800 (real bug)**: `P.isBossWave`/`P.nextBossWave`
looped `for(i=0;i<40;i++)` over an unbounded formula (`bossWaveAt(i)=
20*(i+1)`) — the loop, not the formula, capped recognition at wave 800.
Replaced with direct arithmetic (a modulo check once past the last fixed
`BOSS_WAVES` entry) — no iteration bound to outgrow again.

**Post-wave-100 hard scaling, up to 10x, bosses hit harder and act faster**:
`waveScale()` was one continuous sqrt curve for the whole game, and enemy
SPD never scaled with wave at all (a flat archetype constant) while party
SPD grows every level — the concrete mechanism behind enemies getting
fewer relative actions late-game. Added `P.hardMul(w)` (1 at/below wave
100, ramping to `P.HARD_MAX` by `P.HARD_REF`, layered multiplicatively on
top of the existing curve so waves ≤100 are provably unchanged) applied to
enemy ATK/MAG (full multiplier) and HP (its square root — a harder hit, not
a bigger sponge); bosses get an additional `P.BOSS_HARD_EXTRA` on ATK/MAG
and their own `P.bossSpdMul(w)` ramp (SPD is uncapped and linear in turn
frequency — `tcRaw=TICK_K*rank/spd` — so this reliably means "acts more
often," not just "hits harder"). **Tuned against a real-combat before/after
harness**, not shipped on the first guess: the initial constants
(`HARD_REF=1000`, `BOSS_HARD_EXTRA=1.35`, `BOSS_SPD_MAX_MUL=3.5`) produced a
cliff — fine at wave 300, a total 0%-HP wipe by wave 800 even at the
highest fixed test level (150). Stretched `HARD_REF`/`BOSS_SPD_REF` to 2000
and trimmed both boss-only multipliers (1.20/2.2) to spread the same
escalation over more of the range instead of front-loading it — the same
harness then showed a smooth gradient: comfortable at wave 100, a real
multi-turn fight costing meaningful HP by wave 500-800 at moderate levels,
and a clear "you need to actually invest" wall only at levels far below
what that depth calls for, not an arbitrary one.

**Enemy count 5→10, five front / five back**: `P.enemyCount` (the baseline,
deterministic pre-wave-40 path) was left untouched — it's `partySizeAt`
reused, carefully tuned via prior measurement to track party size exactly
(100% win rate w20-w3000) and barely ever invoked past wave 40 anyway,
since the "variety" system (`P.rollCount`/`P.COUNT_WEIGHTS`) governs almost
the entire post-40 game unconditionally. Extended THAT system instead: a
new `P.COUNT_WEIGHTS_HARD` table (max count `P.ENEMY_CAP`=10) used only
past `P.HARD_FROM`, so waves 41-100 keep the exact original 1-4
distribution. `P.countStrength`'s per-enemy tempering fallback (previously
a flat `||1` for n>4, which would have let a 10-enemy wave hit 10x total
encounter strength) now continues the existing plateau trend
(`2.9/n`, fitted to match the already-tuned n=3/4 values almost exactly).
Enemies now carry a `row` (`buildEnemies`: first 5 front, next 5 back).
Only `rowSpdMul` was extended to enemies (front row gets the same +10% SPD
front-row party gets) — the back-row physical-damage discount
(`rowOut`/`rowIn`) stayed party-only, a deliberate scope call: it only
means something paired with a targeting choice, and party→enemy targeting
has no row awareness to make that choice real, so adding the discount alone
would just be invisible, confusing damage variance.

**ATK vs MAG potency**: root cause precisely isolated, not a roster-wide
issue — base atk/mag are tied roster-wide (183 vs 182 total) and magic's
own starter (`ember`, power 1.05) already outpaces `strike` (1.00). The
actual mechanism lives in exactly one place: two of the 10 MC stat-scaling
charge actions (`mag_lance`/`mag_font`) had their power coefficients
deliberately calibrated *down* to cancel out MAG's higher point-buy ceiling
against their `atk_reckless`/`atk_cry` siblings, so a maxed-MAG build hit
for the exact same total as a maxed-ATK build despite its bigger stat —
precisely "mag reads as bigger but doesn't hit harder." Fix: `mag_lance`/
`mag_font` now use the same power coefficient as their atk sibling, so
MAG's ~7% bigger ceiling (30 vs 28) translates into ~7% more output instead
of being cancelled out. `def_slam`/`res_strike`/`spd_flurry` and their
support pairs are untouched — not part of the atk/mag complaint. The
growth-rate skew (MC mag growth ceiling 2.7 vs atk 2.1) is a known,
separate contributor left out of scope — touching it means rebalancing the
point-buy survival-parity system, a bigger task.

**UI restructure**: Road log moved back to the bottom (pure DOM-order
revert — tab switching is id-based, confirmed zero functional risk). Party
allocation (field/bench) moved from the top of GAMBITS onto EXPEDITION —
`renderPartyRoster` became `partyRosterHTML()`+`wirePartyRoster()` (a plain
string plus a separate wiring pass) since `renderExpedition()` assembles
its own content as one string and sets `host.innerHTML` once, unlike
GAMBITS' append-based pattern the old function relied on. AETHER dropped
the one-unit-at-a-time tab selector for one compact row per OWNED unit
(fielded and benched — benched units were previously unreachable from this
tab at all, not just hidden) trading the old box's full stat/growth/slot
readout (still visible elsewhere) for density. LORE dropped its per-unit
selector too, now listing every unlocked action once, globally, sorted
used-first (reusing `usedActions()`, already exactly the right helper —
previously only powered the refund button's eligibility) with a new "used
by: X, Y" line per action — newly meaningful given the one-action-per-unit
rule from the previous session change.

**Verification**: 30 new headless smoke checks (bringing the suite to
86/86) covering the boss-wave-cap fix arbitrarily far past 800, `hardMul`/
`bossSpdMul` curve shape and exact-1 boundary proof, the variety-table
extension and its sum-to-1 weights, `countStrength`'s plateau fallback,
mag_lance/mag_font power parity, and enemy `rowSpdMul`. A dedicated
scratchpad harness (real `C.step` combat, `buildEnemies` reproduced
verbatim from the current source) ran the before/after tuning pass above
and a 5-seed boss-fight snapshot at every reference wave. Live browser pass
confirmed: `isBossWave`/`nextBossWave` correct at 820/5000, the Road log's
DOM position (`#tab-log` now after `#tab-tests`), the party editor now
rendering on EXPEDITION and gone from GAMBITS, AETHER showing all 7 owned
units in a seeded save including 2 benched ones, and LORE's used-first sort
with correct "used by" tags (confirmed a genuinely-unused seeded action,
Pierce, sorted to the very bottom below all 6 used actions).

## AETHER/LORE reverted to the per-unit tab selector

Short-lived: the compact all-units-list redesign for AETHER (and the
global used-first list for LORE) from the batch above didn't stick — "let's
change the UI for aether and lore to be like gambits with the tabs." Both
went back to `renderUnitTabs`/`currentSelectedUnit`, the same tab-per-
character pattern GAMBITS already used, showing one unit's full box at a
time again (AETHER: stats/growth/slots/recovery restored; LORE: back to a
selected unit's own equipped-actions list, `eq`).

The one thing kept from the reverted pass rather than silently dropped:
benched-unit reach. `renderUnitTabs`/`currentSelectedUnit` gained an
`includeBenched` parameter (`unitTabPool` picks `G.owned` vs `G.party`) —
AETHER and LORE now pass `true` (so a benched unit's tab still appears,
labeled "(bench)"), while GAMBITS' own call site is untouched (omits the
argument, stays fielded-only, since gambit slots only matter for units
actually in a fight). LORE also keeps the "used by" line inside each
action's box from the reverted pass — still useful information in a
per-unit view, it just no longer drives the sort order.

Verified live with a seeded 7-owned/5-fielded save: AETHER and LORE both
show Kesh/Ansa/Dorrek/Vey/Mirel/Skarn (bench)/Sorin (bench) as tabs;
selecting benched Skarn on each tab correctly showed his own box (AETHER:
level/stat readout and feed buttons; LORE: his own equipped Strike, "used
by Kesh, Ansa, Dorrek, Vey, Mirel, Skarn"); GAMBITS confirmed unaffected
(still only the 5 fielded units, no bench entries).

## LORE moved to per-action tabs

One more iteration, LORE only: "I want Lore to have per action tabs, with
the ones in use having a star next to them." Replaced the per-unit tab
selector (just adopted above) with a new, parallel `renderActionTabs`/
`currentSelectedAction`/`selectedActionTab` (separate from the unit
versions — LORE has no unit dimension in this design at all). Tab pool is
`G.actions`, sorted used-first same as the earlier global-list pass, but
now each tab is one action (labeled with a ★ suffix when `usedActions()`
flags it) rather than a row in a scrollable list, and selecting a tab shows
only that one action's existing upgrade box. The "used by: X, Y" line
inside the box (from the used-by-tabs pass) is kept — GAMBITS/AETHER's own
`renderUnitTabs`/`currentSelectedUnit` are untouched. Verified live with a
seeded save: tab row reads "Strike ★ / Ember ★ / Brace ★ / Mend ★ / Sear ★
/ Guard Break ★ / Pierce" (the one seeded-but-unequipped action correctly
unstarred and sorted last), and clicking Pierce's tab swaps the box to
Pierce's own (unused, its own Lore total and bonus stacks) — confirming the
tab switch, the star logic, and the sort all work together correctly.

## Action levels, DROPS removed, MARKS trimmed, levels on the Road

**Action "level" next to its name**: a new `actionLevel(aid)` reuses
`C.actionBonusTotal` (the same escalating-upgrade count already driving
Lore pricing and the "this action's upgrade #N" line) — shown as `LvN` on
every LORE action tab and in the per-action box header.

**Charge actions vanished from LORE — caught immediately, not shipped**:
the per-action-tabs pass built its tab pool from `G.actions`, but charge
actions are never entries in `G.actions` (a companion's `chargeAction` is a
fixed roster property; the MC's come from `G.mc.acquiredCharges` — neither
goes through the drop/pull unlock path `G.actions` tracks). Fixed by
folding in every `isCharge` id already present in `used` (`usedActions()`,
computed right there for the star/refund logic anyway) that isn't already
in `G.actions`, rather than re-deriving a second scan.

**DROPS tab removed**: the curated-checklist + collected-drops-history
panel, tab button, and `renderDrops()` all deleted — "seems unnecessary at
this point." `G.dropHistory` itself (and the separate `G.dropQueue`/
`#dropnote` live-notification banner, which is unrelated and stays) is left
as-is: still recorded on every drop, just no longer displayed anywhere.
Left alone deliberately rather than also stripped from `FIELDS`/save
schema — a save-format change wasn't asked for and the write side is
harmless (capped at 60 entries) now that nothing reads it.

**MARKS "income scales with wave" line removed**: not something the player
acts on from that screen, and the idle rate already has its own readout at
the top of the page (`#idleRate`).

**Levels on the Road**: every unit/enemy name in the battle panel now shows
`LvN`. Party level is the real `levelOf(uid)`. Enemies have no such stat —
their level is `Math.round(C.levelCurve(wave))`, the exact wave→level-
equivalent curve `waveScale()` itself is built from (already calibrated so
its numbers read like a plausible party level for that depth — e.g.
`levelCurve(150)≈37`, close to what a level-20-at-wave-150 player would be
under-leveled against, which is the intended "gauge the difficulty" signal).
Every enemy on a given wave shares that one number — a wave-difficulty
proxy, not a precise per-enemy rating (a boss is tougher than its number
alone suggests, by design).

Verified live in one seeded pass: Strike/Oath show `Lv3`/`Lv1` matching
seeded Potent stacks, all 5 companions' charge actions (previously just
Oath was tested, but Hearthlight/Vow of Stone/Ninefold Rain/Ashfall all
reappeared too) show up starred, DROPS is gone from the tab row, MARKS no
longer shows the income line, and the wave-150 battle panel read "Kesh
Lv20 FRONT" / "Thorn Shrike Lv37 indiscriminate".

## Power Level

"A value that accurately shows a player's total power level" at the top of
the ROAD tab, combining every investment axis named — roster depth, unit
levels, Lore, wave — per `P.powerLevel(g)` (`farroad-progression.js`), a
plain sum of four terms each put on a comparable level-equivalent scale
first, rather than a raw unweighted sum of wildly different-scale numbers
(wave can run into the thousands, Lore/unit-count are single or double
digits — summed raw, the latter two would be invisible):
- **wave**: `C.levelCurve(wave)` — the exact same wave→level-equivalent
  curve `waveScale()` (and the Road's own new per-enemy `Lv` tag, added
  just before this) is already built from, so this reuses an
  already-calibrated conversion instead of inventing a second one.
- **unit levels**: `levelOf(uid)` summed across every OWNED unit (not just
  fielded — a benched investment is still real), already level-scale.
- **roster depth**: each owned unit worth a flat `P.POWER_PER_UNIT` (15) on
  top of its own level term — recruiting a companion has value beyond its
  current, possibly-low level.
- **Lore**: `C.actionBonusTotal` summed across every action with any
  investment, weighted `P.POWER_PER_LORE` (1) — literally the sum of every
  `LvN` badge now on the LORE tabs, so the total is directly
  cross-checkable against what's on screen there.

`POWER_PER_UNIT`/`POWER_PER_LORE` are named, tunable constants — a
reasoned starting weighting, not a simulated one (this is a display
metric, not balance-critical), easy to retune if it doesn't feel right.
6 new headless smoke checks (bringing the suite to 92/92): sane/positive
output, independently responds to each of the four inputs, and an exact
expected-sum check against a hand-computed example. Verified live with a
seeded wave-150/2-unit/Lore save: displayed "POWER LEVEL 102", matching
`round(levelCurve(150)≈37 + unit levels 30 + roster 2×15=30 + Lore 5)`
exactly.

## LORE polish, welcome-back moved, auto-travel, difficulty retune

**Action descriptions on LORE**: each box now shows `a.note` (the same
flavor/mechanical text GAMBITS already prints under a slot) right under
the name — was never surfaced here before.

**Starred-but-"banked" contradiction fixed**: the star/sort previously
keyed off `usedActions()` — a broader "protected from refund" sense that
also covers an MC charge action sitting unequipped in `G.mc.acquiredCharges`
— so a banked-but-unequipped charge could be starred *and* labeled "banked
on Kesh — not currently equipped" in the same breath, a real contradiction
Ian caught, not just bad wording. Star/sort now key off a new `active` map
(`actionHolders(aid).active.length>0` — genuinely equipped somewhere right
now), computed separately from `usedActions()`; the box's status line
collapsed to "used by X, Y" or "unused" (the "banked" text is gone). Also
resolves "I don't know if they can be refunded if the action is unused" —
every unused action's box now says outright whether it's refundable
(`usedActions()`'s own sense, unchanged — still correctly protects the
whole MC charge pool from the bulk-refund button) or "not refundable, kept
as part of Kesh's charge pool".

**Broad counts toward level**: `actionLevel()` (and `P.powerLevel`'s Lore
term, to keep them cross-checkable as documented above) now add `b.broad`
on top of `actionBonusTotal` — "leveling up broad does not level up the
action; it should count towards its level." Pricing itself is untouched;
this is a display-only change (broad stays flat-priced, still doesn't
escalate the per-action cost ladder).

**Lore-available made prominent**: the "N of M Lore free" line was a single
`.tiny` row, easy to miss — now a bold, `--lore`-colored number matching how
AETHER/MARKS/LORE currencies read in the purse bar.

**Welcome-back moved into "SOMETHING NEW"**: `simulateOfflineProgress()`'s
summary (away time, waves cleared, wipes, Aether/Marks earned) was a
`sysLog()` line — only visible on the ROAD tab, easy to miss on open. Now a
`pushDrop()` entry in the same banner every other notable event already
uses, so it can't be missed regardless of which tab is showing on load.

**Auto-travel on load**: a resumed save with a custom `G.mc` now calls
`play()` immediately after `tryResumeSave()` succeeds, instead of sitting
paused until a manual ▶ Travel click — "so long as the player has already
made an MC". Gated on `G.mc` specifically (not just a successful resume):
a legacy save from before MC creation existed has `G.mc===null` and never
"made an MC" in the sense meant here, so it's left starting paused; a
genuinely fresh visit still goes to character creation regardless.

**Difficulty retune — direct player report**: "I'm beating level 46
enemies with level 20-30 units" (`levelCurve(227)≈46`) — the HARD_REF=2000
pass from the prior round was still too soft through wave 150-400 in
practice. Re-ran the same before/after harness at levels 20-30 specifically
(the prior pass only tested 40-150) and found something notable: even at
the *original* HARD_REF=2000, a bare-bones loadout (no gambit conditions,
no Lore, always-attack) was already losing most fights at wave 200+/level
20-30 (e.g. 3/20 wins at w227/L20) — so the reported "trivial win" is more
likely a well-built real loadout (working gambits, healing, Lore
investment) substantially outperforming that synthetic baseline, not
`hardMul` being weak in any absolute sense the harness can see. Candidates
down to `HARD_REF`=500/400/300 were also tested and effectively zero out
the bare-bones win rate almost everywhere past wave 150 — likely unfair to
a less-optimized build. Landed on a moderate step, `HARD_REF`/`BOSS_SPD_REF`
2000→800 (`hardMul(227)`: 3.33→4.99), a real ~2.5x steeper ramp through the
range actually being played without returning to the first-pass cliff —
flagged to Ian as a deliberately partial move, to re-report after trying it
rather than continuing to retune against a synthetic baseline that can't
model real gambit/Lore play.

## Difficulty retune #3 — a rigorous engaged-vs-disengaged methodology

Built a genuinely realistic balance test rather than another bare-bones
one: each unit gets its own distinct, role-fitting action + gambit (kesh
Strike+Pierce/foe-armoured, dorrek Strike+Brace/self≤50%, vey
Strike+Execute/foe≤30%, ansa Ember+Mend/ally≤60%, mirel Ember+Gale/3+foes —
healing included and properly gated, not neglected), Lore split evenly
across every distinct equipped action with each purchase picking a
*randomly*-chosen applicable bonus (not hand-optimized), Lore budget
`floor((wave-20)/3)` (a stated, transparent stand-in for the real
duplicate-drop economy). Scanned for the minimum level clearing an
isolated fight at waves 150-1000, party sizes 2-5, both for this engaged
build and the earlier disengaged (always-attack, no gambits/Lore) one.

Confirmed the disengagement penalty the game already has is real and
grows with depth (5-unit party: level 15 engaged vs 30 disengaged at wave
150; 100 vs 170 at wave 1000) — but also confirmed overall difficulty was
still too soft in absolute terms even for the engaged build, matching
Ian's direct read of the numbers: "it definitely shows that something
needs to change."

**Change: `P.HARD_MAX` 10→20** ("double enemy growth[s]"). Since
`hardMul(w)=1+(HARD_MAX-1)*t` for a shared ramp fraction `t`, doubling
`HARD_MAX` roughly doubles the multiplier at every wave past `HARD_FROM`,
not just at the far tail (`hardMul(227)`: 4.83→9.09) — confirmed `hardMul
(w<=100)` stays exactly 1 regardless (checked explicitly before shipping,
per Ian's "will this make the early game harder" question — no, by
construction, though the ramp immediately past wave 100 does get steeper:
`hardMul(120)` 2.52→4.21). Re-ran the same engaged/disengaged harness at
`HARD_MAX`=20 and found the disengaged/engaged *ratio* barely moves (wave
500, N=5: 1.57x→1.55x) even though absolute levels rise substantially
(70→100 engaged, 110→155 disengaged) — this is a difficulty-floor raise
for everyone, not specifically a wider engagement incentive. Surfaced that
distinction explicitly before shipping; confirmed as the intended change
("send it").

## Three bugs from live play

**"Occasionally have to click buttons twice"**: `doStep()`'s ordinary
per-beat path called the full `renderAll()` — with travel now auto-
starting on load, AETHER/LORE/MARKS/EXPEDITION's entire tab content
(`host.innerHTML=''` + rebuild, fresh button listeners) was being torn
down and rebuilt on every single combat beat, on WHICHEVER tab happened to
be open, even though none of that content changes from an ordinary beat —
leveling, Lore, pulls, and expeditions all need an explicit button click
elsewhere to change anything. A click landing while a tick-driven rebuild
replaced the button under it reads as "sometimes needs a second click."
New `renderTick()` (used only by `doStep()`'s non-wave-transition path)
skips straight to `renderPurse()` instead of the full `renderEconomy()` —
wave-transition beats (`afterWaveCleared()`/`onWipe()`, which CAN change
owned units/drops/checkpoints) still use the full `renderAll()`.

**"Tab switches to the MC" after leveling a benched unit**: `selectedUnitTab`
is shared across GAMBITS/AETHER/LORE so switching units on one keeps that
unit selected on the others — but GAMBITS' own `renderUnitTabs` call was
still fielded-only (`G.party`), while AETHER/LORE had already gained
`includeBenched=true` two rounds ago. The AETHER feed-button handler calls
`buildGambits()` as a side effect (to refresh the gambit-slot-count line
after a level-up); that call validated the shared `selectedUnitTab` against
GAMBITS' narrower fielded-only pool, found a benched selection invalid, and
reset it to the first fielded unit — reading as "the tab switches to the
MC" even though the actual click was on AETHER.

**"Still can't update gambits for benched units"**: the direct cause of
the bug above and a standing feature gap together — GAMBITS now also
passes `includeBenched=true`. `ensureLoadout`/`syncLoadout` already only
key off `uid`, no `G.party` dependency (`syncLoadout` safely no-ops for a
unit not currently in `G.units`, i.e. not in an active battle), so nothing
about editing a benched unit's loadout was ever actually unsafe — it was
purely unreachable through this tab. Added a "benched" label and a
"Changes apply once this unit is fielded" note to the box header, matching
AETHER's own benched-unit treatment; fixing this also eliminates the
tab-reset bug above, since all three tabs now agree on the same pool.

**Testing note for future rounds**: verifying this surfaced a real gap in
the established seed-tab workflow — with travel now auto-starting, a
freshly-opened "seed" tab boots into whatever OLD save is already in
localStorage and starts its own tick/autosave loop *before* the seed
script gets a chance to overwrite it, so the old tab's autosave can race
and clobber the fresh seed within milliseconds. Fix: stop that tab's own
travel (`document.getElementById('btnPlay').click()` if it reads "⏸ Rest")
*before* writing new localStorage into it. Also reconfirmed the existing
beforeunload-autosave rule the hard way — editing localStorage directly
in a tab and then calling `navigate()` on that SAME tab still fires
`beforeunload`, which re-saves the tab's stale in-memory state and undoes
the direct edit; the fix is the one already documented (seed from a tab,
then observe from a *different*, freshly-opened tab, never navigating or
relying on the edited tab again).

## Power Level relocated; benched-vs-benched action warning

**Power Level moved** from inside the ROAD tab to the always-visible
header, right below the idle-rate line (`#powerLevel` now a sibling of
`#idleRate` in `#app`, not nested in `#tab-log`) — visible regardless of
which tab is open now, confirmed live while on GAMBITS.

**Benched-vs-benched action sharing now warns, doesn't block**: the one-
action-per-unit rule was always scoped to `G.party` (fielded only) by
original design — only simultaneously-fielded units create the Lore-
sharing exploit it exists to close. That scoping meant two *benched* units
could silently share a non-starter action with zero indication, only
surfacing as a real conflict once both happened to get fielded together.
Given the choice between extending the hard-block to every owned unit
(stricter, and restrictive fast with ~25 basics to go around a full
roster) or a warning that surfaces the moment both would be fielded
together, went with the latter, per direct instruction. New
`benchedActionHolder(aid,excludeUid)` (companion to the existing
`actionHolderInParty`, scanning only benched owned units) — used in two
places, both warning-only, never disabling an option or blocking a save:
the action dropdown tags a benched-held option "(also held by X, benched)"
instead of leaving it silently unlabeled, and the existing "grandfathered
conflict" warning line now also fires for a benched-vs-benched match, not
just the original fielded-vs-fielded case. Verified live: seeded Mirel and
Skarn (both benched) sharing Pierce, confirmed the option is selectable
(`disabled===false`) with the new warning showing on both units' own
boxes, correctly naming the other as the conflicting holder.

## Multi-expedition overhaul (items 1-4)

"I want multiple parties to be able to go on expeditions in different
directions" — the whole system was built around exactly one `G.expedition`
(nullable object) plus one shared `G.expeditionLog` array. `G.expedition`
→ **`G.expeditions`** (array), each entry gaining an `id`
(`'exp'+Date.now()+'_'+random`) and its own `log` (was the shared
`G.expeditionLog`). Every core function (`sendExpedition`,
`resolveExpedition`, `settleExpedition`, `beginReturnTrip`,
`pushExpeditionLog`) now takes the specific expedition object as a
parameter instead of reading the module singular; new
`resolveAllExpeditions()` loops a `.slice()` of the array (so settling one
mid-loop via `settleExpedition`'s `filter` can't skip its neighbor) —
called from `tryResumeSave()`'s catch-up and the periodic poll.
`recallExpedition` now takes an id. `sendExpedition` drops the old
single-slot gate; the one new per-unit check is "not already on a
DIFFERENT expedition" (`isOnExpedition`, new — `G.expeditions.some(e=>
e.partyIds.indexOf(uid)>=0)`), used for that AND for `benchedUnits()`/
`availableForParty()`/`fieldUnit()`'s existing away-exclusions, which
previously each open-coded their own `G.expedition&&...` check.

**"Unique expedition logs for each group that clear after they've been
collected"**: satisfied structurally, not with an explicit clear step —
each expedition's `log` lives ON the expedition object, so the moment
`settleExpedition` removes that object from `G.expeditions` (nothing
copies `log` anywhere else first), the log simply ceases to exist with it.

**Timers**: the old single `expedTimer`/`scheduleExpeditionCheck(delayMs)`
precise-wakeup mechanism assumed exactly one pending arrival and doesn't
generalize to N without a timer-per-expedition map — dropped entirely.
Replaced with two independent interval loops: a ~15s resolution poll
(`resolveAllExpeditions()`+`renderAll()`, was 30s, halved since one pass
now covers every concurrent expedition) for the real combat/reward
simulation, and a new, separate ~1s live-counter tick
(`updateExpeditionTimers()`) satisfying "a live count of how long they've
been out as well as how long until they return" — deliberately patches
ONLY each `#exp-timer-<id>` span's `textContent` directly, never calls
`renderExpedition()`/rebuilds any DOM, and no-ops instantly when the
EXPEDITION tab isn't the visible one. This split matters: a full rebuild
every second would have reintroduced the double-click bug fixed two
rounds ago (tearing the picker/recall buttons out from under an
in-progress click) — verified live that the timer's DOM node identity is
provably stable across tick cycles (tagged a node, waited 3s, confirmed
`===` same reference, not a replacement).

**`renderExpedition()` restructure**: was one `if(exp){active panel}else
{picker}` block; now zero-or-more active-expedition boxes (one per
`G.expeditions` entry, each with its own live timer span, Recall button
scoped to that id, and its own inline log with each entry's timestamp via
new `fmtClock(ts)` — "let's list timestamps on messages") followed by the
send picker, now shown whenever any benched-and-not-already-away unit
remains, REGARDLESS of how many other expeditions are already active — a
second or third party can be dispatched at any time now.

**On-expedition indicator** ("there currently is none"): the three label
sites (`renderUnitTabs` — shared GAMBITS/AETHER/LORE tab bar, `renderAether`,
`buildGambits`) each tested only `G.party.indexOf(uid)<0` with zero
expedition awareness, so an away unit read identically to a plain benched
one everywhere. All three now check `isOnExpedition(uid)` and show
"(expedition)"/"· on expedition" instead of "(bench)"/"· benched" when
true.

**Save/migration**: `farroad-save.js` FIELDS `'expedition','expeditionLog'`
→ `'expeditions'`. `deserialize` needed a real migration, not just a
default-fill, since Ian has a live save that could have an in-flight
singular expedition: if `snap.expeditions` is absent but the legacy
`snap.expedition` is present, it's wrapped into a one-element array
(fresh id assigned) with the old shared `snap.expeditionLog` folded into
that entry's `log` — lossless for any save that matters, since there was
only ever one active expedition at a time under the old model. 8 new
smoke checks (bringing the suite to 95/95): round-trip on the new array
shape, old-save-missing-field defaults to `[]`, and the legacy-singular
migration (does not throw, wraps correctly, folds the old log correctly).

**Verified live** (this required discovering and working around a new
testing-workflow hazard — see below): sent two real expeditions in one
session (Dorrek+Vey, Mirel+Skarn), confirmed both rendered as independent
boxes with independent timer ids/logs, confirmed GAMBITS/AETHER labeled
all four "(expedition)" — never "(bench)" — while away, recalled ONE
without disturbing the other (its box, log, and Recall button untouched),
then seeded one expedition with `homeAt` in the past alongside the other
still active and confirmed on load: the settled one's box and log
vanished completely, its units reverted to plain "BENCHED" with Field
buttons, while the still-active one correctly ran its own catch-up
simulation forward (reached wave 12, banked more rewards) untouched.

**Testing-workflow hazard found while verifying this**: the new periodic
pollers (`resolveAllExpeditions`+`renderAll()`, which calls `autoSave()`)
mean ANY lingering background tab from an earlier test round — not just
the specific tab just edited — keeps re-saving its own stale in-memory
state over a fresh `localStorage` seed, on an unconditional ~15s cadence,
regardless of `beforeunload`/navigation. A round of expedition testing
must close every other Farroad-origin tab before seeding, not just the
one about to be edited or observed.

## Discoverable content — bonus fights, dungeons, companion quest lines (items 5-7)

"Discoverable bonus fights/events... discoverable dungeons... companion
quest lines" — one framework, reusing the expedition system's own
"resolve headlessly to completion, report via a log entry" precedent
rather than inventing a new one: nothing here is live-watched through
`G.battle`/`renderUnits`/`doStep()`, since making a side fight
live-watchable would need `doStep()` and three render functions to accept
"which battle" instead of hardcoding the `G.battle` global — a real
architecture change the ask didn't require. Confirmed with Ian up front:
quest story text is placeholder-only, he authors the real narrative later
the same way `farroadunits.csv`/the content designer are already his own
tools; quest battles use the FULL main party, but the specific companion
whose quest it is must be currently fielded for the attempt to be allowed.

**Data model**: `G.dungeons` — array, each entry's enemies **fully baked
at discovery time** via new `bakeEnemySnapshot(u)` (a plain, JSON-safe
stat block: name/arch/thorns/isBoss/row/chargeAction/slots/stats), not a
wave-number reference — `{id,name,enemies:[...],discoveredAtWave,clears}`.
`G.quests` — `{uid:{stage,frozen}}`, keyed only for owned units (`kesh`
included from `newGame()`, exactly like every other owned-unit dict);
`stage` is battles won (0-5), `frozen[i]` is that stage's own baked
snapshot, populated lazily on FIRST ATTEMPT rather than at acquisition —
a companion acquired at wave 20 but not attempted until wave 800 still
gets the intended difficulty, not whatever the player's current wave
happens to be. New `unitsFromSnapshots(snapshots)` reconstructs fresh
`C.makeUnit()` instances from either source every time a fight is
(re-)entered — never reusing a live, possibly-damaged unit object across
separate attempts. `farroad-save.js` FIELDS gains `'dungeons','quests'`;
`deserialize` default-fills both (brand-new fields, no legacy shape).

**Discovery roll** — `rollExpeditionDiscovery(exp)`, called from
`resolveExpedition`'s win branch right after `exp.ew++`: a flat
`P.EXPED_DISCOVERY_CHANCE` (0.08) per won node, splitting into a bonus
fight (common, `P.EXPED_DUNGEON_SHARE`=0.30 is the dungeon share, the
rest) — an extra `buildEnemies(exp.ew,true)` encounter resolved
immediately against the same expedition party, banking a reward into
`exp.bank` on a win, logged via `pushExpeditionLog` either way, with
losses deliberately NOT touching `exp.hpFrac` (upside-only, "no reward"
is the only downside) — or a dungeon discovery: enemies built at `exp.ew`
scaled by `P.DUNGEON_LEN` (mirrors how `P.BOSS_LEN` already sizes the
boss, just smaller), baked into a new `G.dungeons` entry, surfaced via
both `pushExpeditionLog` and `pushDrop({kind:'DUNGEON DISCOVERED',...})`
so it isn't buried in a log the player might not check.

**New QUESTS tab** (`shell.html`, registered in the same tab-switch array
every other tab uses): two sections. Dungeons — one row per `G.dungeons`
entry with an Enter button; `enterDungeon(id)` builds
`buildExpeditionParty(G.party,1)` (full-HP current party) against
`unitsFromSnapshots(dungeon.enemies)`, `C.setWave`-bracketed around the
frozen `discoveredAtWave` (see the mitigation note below), reports via
`sysLog`, increments `clears` on a win. Companion quests — one row per
owned unit with `stage<5`, an Attempt button disabled (with a tooltip)
unless that companion is in `G.party`; `attemptQuestStage(uid)` bakes
`q.frozen[stage]` on first attempt, then resolves the same
setWave-bracketed way, incrementing `stage` and revealing that stage's
`story` via `pushDrop({kind:'QUEST',...})` on a win. Both paths: no
penalty on a loss beyond the log message — "try again any time."

**Damage-mitigation footgun avoided**: `K_of(l)` (`farroad-core.js`)
reads the *module-global* `CURRENT_WAVE` at every `resolveHit`/`step()`
call, not just at unit construction — any frozen-difficulty fight has to
bracket its own step-loop with `C.setWave(<frozen>)` / restore after,
exactly like `resolveExpedition` already does. Both `enterDungeon` and
`attemptQuestStage` do this explicitly; a new smoke check proves the
property directly (build a unit from a fixed stat block, flip
`CURRENT_WAVE` somewhere `hardMul` scales very differently, rebuild from
the same block, assert the base stats are bit-for-bit identical).

**Acquisition hook**: one line added as the first statement in
`joinCompanion(uid)` — `if(!G.owned[uid])G.quests[uid]={stage:0,frozen:[]}`
— read before the `G.owned[uid]=1` write below it overwrites the signal.
`joinCompanion` is already the single choke point all 3 acquisition paths
(boss milestone, boss unit-drop roll, pull) funnel through, so this is
the only call-site change needed.

**Difficulty tuning — a real finding, not a guess shipped blind**: a
headless balance script (`scratchpad/discoverable-content-tuning.js`,
same VM-sandbox pattern as every prior balance test this session,
reproducing `buildEnemies` verbatim) measured `P.DUNGEON_LEN=1.15` as
landing the min level for a 50%-win bare-attack party at roughly 1.1-1.2x
the plain-Road figure at the same discovery depth (e.g. depth 400: level
88 Road vs 95 dungeon) — confirmed short of the boss's 1.3-1.5x band, i.e.
genuinely "slightly harder", not a second boss. `P.QUEST_LINES`' first-pass
wave-equivalents (10/20/30/45/60) measured as **completely trivial at
every stage** — min level 1 wins 100% of the time — because the quest is
fought by the FULL 5-unit party, but `P.enemyCount(w)` (which the quest's
enemy-building reuses) only grows past 1-2 foes at waves 20/150/500/1500;
a wave in the 10-60 range can never field enough bodies to threaten five
units regardless of level. First retune: fixed milestones
**30/150/400/800/1500** (reusing the game's own `UNIT_WAVES` at 150/1500) —
measured a real monotonic escalation and shipped a build on it.

**Superseded the same session, before Ian saw it** — Ian's actual ask was
to scale each stage off the *player's own* `P.powerLevel` instead of any
fixed wave schedule (0.5x power at stage 1, ramping to a full 1.0x-power
stage 5), so a quest line is always calibrated to where THIS run is, not
an absolute milestone a very-early or very-late companion might unlock
nowhere near. The obvious implementation — invert `C.levelCurve()`
(the same wave->level curve `powerLevel`'s own wave term already uses) on
`frac*powerLevel(g)` — measured as **catastrophically broken**: a real
level-80 5-unit party at wave 300 (power 536) got a stage-1 wave of 7130
and lost 15/15 at every one of the 5 stages, not an escalation, a wall
from the very first attempt. Root cause: `powerLevel` SUMS every owned
unit's level on top of the wave term, so a 5-unit party's `powerLevel`
runs 5-10x what `levelCurve(their actual wave)` alone would be —
`levelCurve` is a square-root curve, so inverting a 5-10x-inflated
"level" back through it overshoots the wave by roughly the *square* of
that factor. Fixed by using the power number **directly as the wave**,
no curve inversion (`P.questStageWave = Math.round(frac*powerLevel(g))`)
— re-measured (real level-80/level-14 parties, headless battle sim, 20
trials/stage): a trivial stage 1 rising to a genuinely losable stage 5
(7/20 and 3/20 win rates for early/mid-game parties respectively, always
at their OWN current power) — a real capstone, not a wall.
`P.QUEST_LINES` entries dropped their per-stage `wave` field entirely
(now just 5 story strings per companion); the wave is computed fresh via
`P.questStageWave(G,stage)` at first attempt and baked alongside the
enemy snapshot into `q.frozen[stage]={wave,enemies}` (was just the
enemy-snapshot array) — the frozen wave has to travel with the frozen
enemies now, since it's no longer a lookup into a static table.

**Verification**: 14 new smoke checks (95→109), then the power-scaling
correction swapped 3 `waveForLevel`-specific checks for 4 checks against
the new direct-proportional formula (109→115 net): discovery-chance
constants are sane probabilities, the roll fires at its configured rate
across 5000 trials, `P.QUEST_LINES` has one complete 5-story entry per
`C.ROSTER` id, `P.QUEST_STAGE_POWER_FRAC` is 5 ascending fractions
0.5->1.0, `questStageWave` stage 5 equals `powerLevel` exactly and rises
monotonically across stages, the freeze-proof above, and full/old-save
round-trip coverage for both new FIELDS entries. Live browser pass (fresh
tab each time, per the hazard below): an owned-but-unquested companion
(Ansa) showed "Stage 2 of 5" with Attempt correctly disabled and
tooltipped until fielded, then enabled the moment she was; a
directly-seeded `G.dungeons` entry rendered and Enter resolved headlessly,
incrementing `clears`; Kesh's quest stage 1 resolved BOTH ways — a genuine
loss (solo, level 5, bare Strike/Strike) logged "Quest attempt failed"
with the stage held at 1, and a win (leveled to 40, Ansa fielded
alongside) logged "Quest stage cleared", advanced to stage 2, and revealed
the placeholder story text via the drop banner; a REAL expedition (seeded
with a large elapsed offline window so `tryResumeSave`'s catch-up had many
nodes to resolve, `P.EXPED_DISCOVERY_CHANCE` bumped to 1 in one run to
force the branch) produced both outcomes live — "Dorrek won a bonus fight
along the way — +4 Aether, +0 Marks" at default odds, and 5 separate
"DUNGEON DISCOVERED" drop notices in the forced run, each correctly baked,
listed in the QUESTS tab, and clearable via Enter. After the power-scaling
correction: a seeded level-80 5-unit party (power 536, matching the
headless balance figures above) showed `POWER LEVEL 536` in the header and
ran Kesh's quest line to completion end-to-end through all 5 real,
power-derived-wave stages — "Kesh's quest line is complete." — confirming
the corrected formula is wired all the way from `attemptQuestStage()`
through to the UI.

**Testing-workflow hazard found while verifying this (a new variant)**:
the known "lingering background tab re-saves stale state" hazard turned
out to have a second trigger beyond the periodic poller — `farroad-ui.js`
has `window.addEventListener('beforeunload',function(){doSave();})`, so
simply calling `navigate()` to reload the SAME tab a `localStorage` seed
was just written into fires that handler on the OLD page instance,
re-serializing whatever G it already had in memory (built from
localStorage at ITS OWN earlier load) right back over the fresh seed
before the reload's read ever happens. Fix is the same discipline as
before, stated more precisely: never reload/navigate the tab you just
wrote `localStorage` into — write from tab A, then open a genuinely fresh
tab B to observe, and close tab A (or otherwise ensure it never gets a
chance to autosave or unload) before its own 15s poller or a later
navigation of it can fire.

## Live battle visualization for quests and dungeons

Ian's report: attempting a quest "just says the next stage is available —
there aren't any actual battles." `attemptQuestStage()`/`enterDungeon()`
were resolving headlessly, synchronously, in a tight `while(!battle.over)`
loop — the same shape expedition catch-up uses — so nothing was ever
visibly watched. Ask: both should "take the place of" the Road's own live
battle display, pausing Road combat while they play out, then handing
control back. Confirmed with Ian: expedition bonus-fight "events" stay
exactly as they are (headless/instant) — they're found automatically by a
benched party, often during an offline catch-up that can resolve dozens in
one pass, so there's nothing sensible to watch there.

**Key enabler**: `G.battle` was already a bare, reassignable module-level
pointer, written only by `startWave()` by convention, not by any
structural requirement. `renderUnits()`/`renderRail()` already read
`G.battle` generically (`G.battle.units`, `C.preview(G.battle,6)`) — they
don't care what kind of fight is in it. So a side battle just points
`G.battle` at its own battle object and lets the EXISTING `doStep()`/
`tick()`/`play()`/`stop()` loop drive it forward exactly like Road travel
does — no new stepping/pacing logic, no new overlay/CSS (this codebase
has no floating-modal pattern at all, only a `.hidden`-toggle full-panel
swap; reusing the existing always-visible battle panel — outside any
`#tab-*` wrapper — is simpler than adding one).

**New state**: `G.sideBattle` (null outside a side fight, else
`{savedWave, wasPlaying, wave, meta}`) and `G.roadBattle` (the parked real
Road battle while one is active) — both transient, never added to
`farroad-save.js` FIELDS, same precedent as `G.battle` itself never being
persisted (a reload mid-side-fight simply loses it, same as reloading
mid-Road-fight already does).

**`startSideBattle(enemies,wave,meta)`** (new): guards against stacking a
second fight (`if(G.sideBattle)return false;`), `stop()`s the Road's timer
chain if it was running, parks `G.battle` into `G.roadBattle`, pins
`C.setWave(wave)` for the fight's whole visible duration (not just a
single synchronous bracket any more — many separate `setTimeout` turns
now), builds the battle, and calls the existing `play()` to auto-run it.

**`finishSideBattle(result)`** (new): the exact reward/log tail
`attemptQuestStage`/`enterDungeon` used to run inline right after their
own synchronous while-loop, moved here verbatim (reading `meta` instead of
closure variables) since the fight now finishes asynchronously. Restores
`C.setWave`/`G.battle` to the real Road battle, then either `play()`s
(if the Road was traveling before) or explicitly `stop()`s.

**Real bug caught by live verification, not assumed away**: the first
version only called `play()` conditionally
(`if(sb.wasPlaying)play();`) and never called `stop()` in the else case.
Since `startSideBattle()` unconditionally calls `play()` to auto-run the
fight, `playing` stays `true` regardless of the Road's prior state — so
when a side battle finished from a "Road wasn't traveling" state, nothing
ever reset it, and the still-alive `tick()` timer chain silently started
auto-traveling the just-restored Road battle the player never asked to
resume. Caught by seeding a solo, low-level Kesh (guaranteed loss) with
the Road stopped beforehand, watching the header/button after the loss —
"Wave 1" restored correctly, but the button stayed on "⏸ Fighting"
instead of reverting to "▶ Travel". Fixed with an explicit
`else stop();`.

**`doStep()`** branches on `G.sideBattle` before the Road-specific
wave-transition checks, mirroring the exact check-before/step/check-after
shape the Road branch already used, swapping `afterWaveCleared()`/
`startWave()`/`onWipe()` for `finishSideBattle()`. **`renderHead()`**
branches similarly — "QUEST — Name, stage N of 5" / "DUNGEON — Name"
instead of "Wave X · N enemies · farthest Y · checkpoint Z" (all
Road-specific globals that don't apply to a side fight). One line in
`renderUnits()` needed a fix beyond the obvious redirect: the enemy "Lv"
tag read `C.levelCurve(G.wave)` directly — during a side battle that's the
Road's current wave, not the fight's own frozen one, so it would have
shown the wrong level. Now reads `G.sideBattle?G.sideBattle.wave:G.wave`.
`play()`/`stop()`'s button labels also branch (`⏸ Fighting`/`▶ Resume`)
so a player who manually pauses mid-side-battle isn't shown the misleading
"▶ Travel". `renderQuests()` disables both Enter/Attempt while any side
battle is active (`busy=!!G.sideBattle`), so a second fight can't be
stacked from the UI either, on top of `startSideBattle`'s own guard.

Pure `farroad-ui.js` change — `farroad-core.js`/`farroad-progression.js`/
`farroad-save.js` untouched, confirmed via `git diff --stat` showing zero
overlap with `resolveExpedition`/`rollExpeditionDiscovery` (the bonus-fight
event path), so the existing 115 smoke checks are a regression guard, not
something expected to gain new checks — there's no new headless-testable
math here, only orchestration of when `C.step()` fires.

**Verified live** (same fresh-tab-per-write discipline as every other
session in this log; also surfaced a THIRD variant of the tab-clobbering
hazard — see below): a guaranteed-loss quest attempt (solo Kesh, level 1,
vs. a stage scaled to a 5-unit level-80 party's power) showed the live
header/enemies/ticking, resolved to "Quest attempt failed" with the stage
held, and correctly reverted the header/button to normal Road display (the
`else stop()` fix above, confirmed working after the fix). A guaranteed
win (full level-80 party) started mid-Road-travel correctly paused it
(`⏸ Fighting`, "QUEST — Kesh, stage 1 of 5"), and while it was running,
both Enter and Attempt showed `disabled` with "A battle is already in
progress" — clicking Enter on the dungeon while the quest fight was live
was confirmed a no-op. Once resolved: "Quest stage cleared" + the
placeholder story banner + stage advanced, AND the Road resumed traveling
on its own (reached wave 2) — confirming the `wasPlaying:true` path.
Repeated for a seeded dungeon Enter: same live header/ticking, "Dungeon
cleared" logged, `clears` incremented, Road resumed.

**Testing note, not a game bug**: mid-verification, beats appeared to
almost completely stall (the combat log stopped growing for 10+ seconds
even at the in-game 40x speed setting). This traced to the Browser pane
being *hidden* during automated testing — browsers heavily throttle
`setTimeout` timers on backgrounded/hidden tabs regardless of the delay
requested, which is exactly what `tick()`'s self-rescheduling chain runs
on. Not reproducible for a real player with the tab open and focused.
Worked around for verification by clicking `#btnStep` in a tight loop
(each click synchronously runs one `doStep()`, bypassing the timer
entirely) rather than waiting on wall-clock time.

**Tab-clobbering hazard, third variant**: confirmed the existing
discipline (write `localStorage` from tab A, observe from fresh tab B,
never reload A) is necessary but not sufficient on its own if tab A is
left OPEN afterward with its own `G.sideBattle`/travel state diverging
from what's on disk — not a new mechanism, just a reminder that the same
15s-poller and `beforeunload` triggers documented above apply to this
feature's state too, not only expeditions.

## BUGFIX: the Road sped up after every side battle, compounding

Ian's report: "after battling in a dungeon or quest, the Road combat is
sped up afterwards — it gets faster the more dungeons and quests you
complete." Root cause was exactly the reentrancy risk flagged (but not
fully closed) in the live-battle work above: `finishSideBattle()` called
`play()` to resume Road travel when `wasPlaying` was true — but
`finishSideBattle()` runs from INSIDE `doStep()`, itself invoked from
INSIDE the side battle's own still-executing `tick()` call. `play()`
calls `tick()` synchronously, which schedules a brand-new
self-rescheduling `setTimeout` chain (chain B) for the Road's next beat.
Control then unwinds back up through `finishSideBattle()`/`doStep()` to
the ORIGINAL, still-running `tick()` call (chain A), which — completely
unaware anything happened underneath it — reaches its own
`timer=setTimeout(tick,...)` line and schedules a SECOND chain. Neither
chain is ever cancelled (the shared `timer` variable only remembers the
LAST one scheduled), so both keep re-arming themselves forever in
parallel: one extra permanent tick chain per side battle finished while
the Road was already traveling, exactly matching "gets faster the more
you complete."

Fixed by splitting `play()`'s two responsibilities — syncing the button
label and kicking off a NEW tick chain — into `syncPlayBtn()` (label only)
and `play()` (`syncPlayBtn()`+`tick()`). `finishSideBattle()` now calls
`syncPlayBtn()` instead of `play()` when resuming: `playing` is already
`true` (set by `startSideBattle()`), so nothing needs to happen except the
label — the ALREADY-RUNNING chain A naturally continues ticking the
now-restored Road battle on its own next scheduled beat, no second chain
ever spawned. The `wasPlaying:false` branch is unaffected (`stop()` never
called `tick()`, so was never at risk).

**Verified live**, since this bug only manifests through the real
`setTimeout` chain (the earlier live-battle verification pass happened to
fast-forward completions via repeated `#btnStep` clicks, which bypasses
`tick()`'s scheduling entirely and never exercised this path — a gap in
that verification, not a second bug): monkey-patched `window.setTimeout`
to count short-delay (<2s) schedules, measured a baseline rate over an
8s window while the Road traveled normally (15 schedules), then let a
dungeon fight resolve via the REAL timer (no `#btnStep`) while the Road
was traveling, and re-measured the same 8s window afterward — still
exactly 15. Repeated for a second side battle in a row — still 15,
confirming the fix holds and doesn't need to "catch up" or compound.

## Directional expeditions, manual collection, multi-wave dungeons

Ian's next batch: expedition timers should read as a genuine live clock;
expeditions must be manually collected, not auto-granted on arrival, with
a SOMETHING NEW notice when they return; sending one should require
picking a direction (8 named lanes, West easiest/least lucrative through
East hardest/most lucrative, up to 8 out at once); dungeons should be
multi-wave with a boss finale, unlocked on a fixed per-direction schedule
instead of randomly discovered; a companion quest's final stage should
also be a boss. Full plan at `.claude/plans/lovely-zooming-comet.md`
("Part 1").

**Live countdown turned out to already be live** — `updateExpeditionTimers()`
was already recomputing both the away/returning displays every second
from `Date.now()`; `fmtDur()` just rounded to whole minutes/hours, so the
text only visibly changed once a minute. Reformatted to a real M:SS/H:MM:SS
ticking clock — no data/architecture change needed, confirmed by research
before touching anything (would have been wasted work otherwise).

**Manual collection**: both auto-settle call sites (`resolveExpedition`'s
homebound branch, `beginReturnTrip`'s immediate-settle check) replaced
with a shared `checkArrival(exp)` — the first time it observes
`Date.now()>=exp.homeAt` (guarded by a new `exp.arrivedAt`, so it fires
exactly once), it logs and `pushDrop`s a preview of the banked reward
WITHOUT touching `G.aether`/`G.marks` or removing the expedition. New
`collectExpedition(id)` (renamed from the old auto-called
`settleExpedition`) does the actual grant+removal, gated on `arrivedAt`
being set — only reachable from the new "Returned — Collect" button.
`renderExpedition()` gained a third visual state (Away / Heading home /
Returned) plus a `Collect All` convenience button when 2+ are waiting.

**Directions**: `P.DIRECTIONS` (8 ids) + `P.directionMul(dir)` — computed
from index (0.75 west to 1.75 east) rather than a hardcoded table, so the
8 values are provably monotonic by construction. `sendExpedition` now
requires a direction and rejects one already occupied by another active
expedition — that occupancy check IS the 8-concurrent cap, no separate
counter. Applied via a new shared `applyStatMul(enemies,mul)` helper
(lifted verbatim from the old dungeon-discovery roll's scaling shape: HP
via `sqrt(mul)`, ATK/MAG via `mul` directly) to regular expedition-node
enemies AND their rewards, the bonus-fight roll's enemies AND rewards,
and the new scheduled-dungeon system's enemies. Measured (headless
balance script, `scratchpad/directions-dungeons-tuning.js`): min level
for a 50%-win bare-attack party at a fixed depth (300) rises smoothly
66 (west) to 104 (east) — a real ~1.6x spread, no cliff between adjacent
directions.

**A "Returned but not yet collected" expedition still occupies its
direction** — deliberate, not an oversight: it's still technically "out"
from the game's perspective, and freeing the direction immediately on
arrival would let a player leave rewards sitting indefinitely with zero
cost, undermining the whole point of making collection a deliberate
action. Verified live (an expedition seeded already-arrived correctly
showed East disabled in the direction picker; collecting it freed East
immediately after).

**Scheduled per-direction dungeons, multi-wave, ending in a boss**: new
per-direction persistent state `G.directions[dir]={maxDepth,
dungeonsUnlocked}` — `maxDepth` is cumulative across EVERY expedition
ever sent that direction, never reset per trip (confirmed with Ian this
was the intended read of "every 100 waves in each direction" — a single
trip rarely survives anywhere near 100 nodes before the HP-return
threshold trips it, so the schedule has to accumulate across many
separate sends to mean anything). New `farroad-save.js` FIELDS entry
`'directions'`, default-filled to all-zero for an old save, same pattern
`'dungeons'`/`'quests'` already established; an old save's in-flight
expedition missing `.direction` defaults to `'west'`.

`rollExpeditionDiscovery()`'s dungeon branch is gone entirely — replaced
by a deterministic check in `resolveExpedition`'s win branch
(`Math.floor(maxDepth/DUNGEON_UNLOCK_EVERY)` crossing `dungeonsUnlocked`,
in a `while` loop so a big offline catch-up that jumps several
100-multiples at once unlocks every one of them, not just the first).
`P.EXPED_DUNGEON_SHARE` retired along with it — the bonus-fight roll
(`rollExpeditionDiscovery`, now bonus-fight-only) is otherwise untouched
except for taking the direction multiplier as a parameter.

A dungeon entry's shape changed from one frozen fight to
`{...,direction,tier,waves:[{wave,enemies},...],clears}` — `waves` is
`DUNGEON_WAVE_COUNT-1` (3) regular waves then a forced boss wave, each
carrying its OWN frozen `wave` value (not just enemies), since the
regular waves and the boss are frozen at DIFFERENT depths.

**Real bug caught while building this, before it ever shipped**:
`DUNGEON_UNLOCK_EVERY` (100) is itself always a multiple of `BOSS_EVERY`
(20), so building a dungeon's "regular" waves directly at `baseWave`
would have silently made every one of them a boss wave too (single
enemy, not a normal multi-enemy fight) — caught by the balance script
showing `bossWave===baseWave` unexpectedly for every tier tested, not by
inspection. Fixed by building regular waves one wave short of the unlock
depth whenever `baseWave` itself is a boss wave (`P.isBossWave` check),
while the FINAL wave still deliberately forces onto the real boss wave
via `P.nextBossWave`.

**`finishSideBattle()`'s dungeon branch now has two shapes**: winning a
non-final wave advances `meta.waveIndex` and swaps in the next wave's
enemies IN PLACE — deliberately does NOT touch `G.roadBattle`/
`G.sideBattle`/`playing`, only `G.battle`+`CURRENT_WAVE`+`G.sideBattle.wave`
(the last so `renderUnits()`'s enemy level-tag doesn't go stale on wave
2+) — mirroring how the Road's own `startWave()` swaps in a fresh battle
without touching play/pause state. Party units carry over unrebuilt
between waves (real attrition, no mid-run healing) — full HP/0 charge is
granted only once, at the very start of wave 1 (confirmed with Ian:
charge stays at 0, not full, contrary to my first reading of his note).
Only the FINAL result (whole-run win or any-wave loss) produces a
`pushDrop` pop-up — intermediate wave-clears stay `sysLog`-only, matching
how the Road's own wave-clears don't banner either.

**Quest final stage is a boss**: `attemptQuestStage`'s stage-4 (5th,
final) wave computation rounds UP to the nearest boss wave via
`P.nextBossWave(rawWave-1)` before baking — the exact same trick the
dungeon's own final wave uses — so `buildEnemies` automatically takes its
existing single-powerful-enemy path, no new construction code.

**Measured, not guessed, but flagged as the first retune candidate**: the
multi-wave dungeon's win-rate band (3 regular waves + boss, HP carried,
no healing) came out narrower than ideal — around 1.3x a single wave's
own min-level the run mostly fails partway through the regular waves;
around 2x, the whole run including the boss clears comfortably. Shipped
as the reasoned starting point (same treatment `DUNGEON_LEN`/
`QUEST_STAGE_POWER_FRAC` got), explicitly flagged in the
`P.DUNGEON_WAVE_COUNT`/`P.DUNGEON_UNLOCK_EVERY` comment as the first
thing to retune against Ian's real playtesting.

**Verified live** (fresh-tab-per-write discipline): a seeded already-
arrived expedition showed "Returned — ready to collect" with East
disabled in the direction picker; clicking Collect granted the exact
banked amount and freed East immediately; a naturally-arriving expedition
(seeded past `homeAt` but without `arrivedAt`) correctly fired the
SOMETHING NEW notice on load without touching `G.aether`. A seeded
4-wave dungeon: entering showed "wave 1 of 4" with full HP/0 charge,
resolved all 4 waves with exactly ONE "DUNGEON CLEARED" pop-up (not one
per wave), and `clears` incremented; a heavily overmatched party showed
exactly ONE "DUNGEON FAILED" pop-up on a wave-1 loss, correctly omitting
the wave-index suffix for a first-wave death. Kesh's stage-5 quest
attempt showed a single "ROADWARDEN" boss-tier enemy, not the usual
multi-enemy composition. A REAL expedition (not directly seeded — a
2-hour offline catch-up on a level-200 Dorrek sent East) organically
produced BOTH a bonus-fight win (direction-scaled reward) and an actual
"A new dungeon has opened up to the East — 100 depth reached." unlock,
confirming the whole pipeline (depth tracking → threshold crossing →
dungeon construction → notification) works end-to-end, not just via
direct seeding. 124/124 smoke checks pass (115→124, 9 new: direction
ordering/monotonicity, dungeon/unlock-interval sanity, save round-trip +
old-save defaults for `directions` and an expedition's `direction`).

## CSV content pipeline — units/actions/enemies/quests/dungeons are now the real source of truth

Ian's ask, mid-conversation: make quest/dungeon content CSV-editable "for
more nuanced control," then — once that pipeline existed — extend the
same treatment to the existing units/actions/enemies CSVs, which today
are just reference mirrors Ian keeps in sync with the hand-written JS some
other way (`build.js` never reads them). Full design at
`.claude/plans/lovely-zooming-comet.md` ("Part 2").

**Not everything converts — said so up front, not discovered by a bug
report later.** Two parallel Explore passes over every relevant table in
`farroad-core.js` found this splits cleanly:
- **Converts cleanly** (pure flat data, no embedded logic): `C.ROSTER`,
  `C.ARCH` (minus the `boss` row — there's no `ARCH.boss`; a boss enemy is
  synthesized at combat-build time from `ox`'s shape + `wolf`'s HP, a
  deliberate design this pipeline doesn't touch), and the large majority
  of `C.ACTIONS` (~59 of 64 entries).
- **Stays hand-written JS**: gambit conditions — confirmed directly that
  a condition's `resolve` field (`{id,label,group,resolve}`) IS the
  executable logic, not data next to it (`chooseFrom()` calls
  `.resolve(u,b,act)` directly, no dispatcher in between) — of
  `farroadgambitconditions.csv`'s 10 columns only `id/label/scope` map to
  anything the engine reads, and CSV data alone can't add a genuinely NEW
  condition anyway. Left as a documentation-only mirror, unchanged —
  converting it would have been a false "real source of truth" promise.
  Five `ACTIONS` ids (`execute`, `vengeance`, `onslaught`, `reckoning`,
  `ninefold`) carry an actual JS closure (a dynamic power/crit formula, or
  "each hit re-rolls its own random target") — code, not a spreadsheet
  cell — merged onto the CSV-generated table by id via a small
  hand-written `ACTION_DYNAMIC` object in `farroad-core.js`.

**Architecture**: a new shared `content-pipeline.js` (dependency-free —
a small RFC4180-ish CSV parser, quoted fields with embedded commas/
escaped quotes) reads and compiles all 5 CSVs, validates them (duplicate
ids, every `charge_action` reference resolves, every `C.ROSTER` id has
exactly 5 ascending-`power_fraction` quest rows, all 8 `P.DIRECTIONS`
values have exactly one dungeon-config row), and returns the plain
`window.FarroadContent` object. `build.js` embeds it as a new
`<script id="farroad-content">` tag, injected via a new
`<!--@@CONTENT@@-->` shell.html placeholder placed BEFORE
`<!--@@CORE@@-->` — script tags execute in document order, so
`farroad-core.js` can read it synchronously at its own load time.
`build.js`'s `strayWindow` purity check gained `window.FarroadContent` as
a fourth recognized import (same exemption `FarroadCore/Progression/Save`
already had). `farroadsmoke.js` (the headless test harness) requires the
SAME `content-pipeline.js` and populates its own sandbox's
`window.FarroadContent` before loading `core.js` — one pipeline, two
consumers, never two copies that could quietly drift apart. Validation
failures abort immediately with a specific message (`node build.js`/
`node farroadsmoke.js` both fail loudly, never ship or test a silent
`undefined`) — the exact same shape of check the smoke suite already did
for `P.QUEST_LINES` completeness, just moved to build time where Ian
gets immediate, actionable feedback instead of a later runtime throw.

`farroad-core.js` changes: `ROSTER`/`ARCH`/`ACTIONS` go from inline
literals (`ROSTER`/`ARCH` together were ~215 lines) to
`window.FarroadContent.ROSTER`/`.ARCH` directly, and
`window.FarroadContent.ACTIONS` run through the existing `A()` defaulting
wrapper then merged with `ACTION_DYNAMIC`. `farroad-ui.js`'s
`buildEnemies()` gained two real, low-risk generalizations while in
there: `magCrit` was a single hardcoded `0.04` applied to every
archetype — now a genuine per-archetype `ARCH` field (seeded to `0.04`
for every archetype in the shipped CSV, so day-one behavior is
unchanged, but Ian has a real lever now); `chargeAction` was a hardcoded
`key==='ox'/'hound'` check — now read straight off `ARCH[key]
.chargeAction`, so any archetype can carry one, not just those two.

**Two new CSVs, replacing the hand-written `P.QUEST_LINES`/direction
constants entirely** (not layered alongside them): `farroadquests.csv`
(50 rows — 10 companions × 5 stages: `companion_id,stage,power_fraction,
is_boss,story,design_note`) replaces the fixed `P.QUEST_STAGE_POWER_FRAC`
array shared by every companion with an explicit value per stage PER
COMPANION — genuine "nuanced control," e.g. a gentler curve for one
companion than another, no code touched.  `farroaddungeons.csv` (8 rows,
one per direction: `direction,label,difficulty_multiplier,wave_count,
unlock_every,boss_name,design_note`) replaces the formula-computed
`P.directionMul()` and the flat `DUNGEON_WAVE_COUNT`/`DUNGEON_UNLOCK_EVERY`
constants from Part 1 with independently-editable per-direction values —
Ian can now give one direction a longer dungeon, a different unlock
pace, or a named boss than another, all from a spreadsheet. Both CSVs
seeded with the exact values Part 1 shipped (same placeholder story text,
same 0.5→1.0 power-fraction ramp, same 0.75→1.75 direction range, same
wave count/unlock interval for all 8) — day-one behavior unchanged, the
CSV is just where those numbers live now.

**A real, silent-corruption bug caught by the validation tests
THEMSELVES, not by a human**: the "every quest line has 5 ascending-
power-fraction stages" check used `Array.prototype.some()`/`.filter()`
over the per-companion stage array — and `some()`/`filter()` SILENTLY
SKIP holes in a sparse array. A missing CSV row (e.g. a companion's
stage-3 line deleted) leaves that array index truly unassigned, not
merely falsy — `[a,,c].some(x=>!x)` returns `false`, not `true`, because
`some()` never visits the hole at all. That meant a missing quest-stage
row would silently pass the "has 5 valid stages" gate and crash several
lines later on `undefined.powerFraction`, with a stack trace pointing at
the WRONG check. Caught immediately by deliberately testing this exact
scenario (per the plan's own verification step — "deliberately break a
CSV, confirm build.js fails with a clear message") rather than assuming
the check worked because it looked right. Fixed with an explicit indexed
loop that visits every slot 0-4, hole or not.

**Verified**: `node build.js` on the real CSVs produces byte-identical
`ROSTER`/`ARCH`/`ACTIONS` values to the pre-migration hardcoded tables
(confirmed via live browser: Kesh ATK 26/MAG 18/HP 430, Roadwolf ATK
21/HP 200 — exact matches); a full wave plays and clears normally with
CSV-sourced content. Build-time validation deliberately exercised against
a scratch copy of the CSVs (never the real files) for: a duplicate unit
id, an unresolved `charge_action` reference, and a missing quest-stage
row — all three fail the build with a specific, correct message, the
missing-row case only after the sparse-array fix above. The pipeline
proven REAL, not just structurally present: gave `wolf` a `charge_action`
in `farroadenemies.csv` (`quickenedhowl`), rebuilt, and confirmed a fresh
Roadwolf in a live fight now shows "⚡ Quickened Howl" — then reverted the
test edit and rebuilt clean. 122/122 smoke checks pass (124→122 — net
of removing checks tied to now-deleted constants like
`P.QUEST_STAGE_POWER_FRAC`/`P.DIR_MUL_MIN` and adding CSV-shape checks
for `P.QUEST_LINES`' new `{story,powerFraction,isBoss}` stage shape).

## Elemental affinities — Fire/Water/Earth/Air/Light/Dark/Body/Spirit

Ian's ask: 8 new per-unit stats — 6 elements plus Body (physical) and
Spirit (buff/debuff/healing potency) — scaling damage dealt/taken (and
healing, and status magnitude) by a diminishing-returns curve capped at
±80%, invited into character creation "with explanations of what they
do." Three plan-mode corrections during design, each incorporated before
implementation began (full history: `.claude/plans/lovely-zooming-comet.md`):
healing scales with **Spirit, not Light** (Light is a normal 6th damage
element); the explanatory text belongs in the **AETHER tab**, not
character creation (`#mcCreate` stays completely untouched by this
feature); and Aether-purchased investment must count toward **Power
Level**, which is what forced the data model below — a unit's own raw
affinity value is never stored directly, only the *purchased* delta on
top of an authored baseline.

**The core formula lives in `farroad-core.js`, not `farroad-progression.js`**
— a deliberate deviation from the original plan text, caught while
implementing: `resolveHit`/`healFor`/`apply()` all need the multiplier
formula directly, and core.js is evaluated (and its own module IIFE
fully executes) *before* progression.js — `window.FarroadProgression`
doesn't exist yet at the point core.js's functions are defined, so a
`P.affinityMul` couldn't be called from inside them. `C.affinityMul`/
`C.AFFINITY_CAP` are exported for progression's cost curve and the UI's
AETHER tab to read the identical formula — the same reason `F.CAP_CRIT`
is already exported from core for progression's `buildEnemies` to clamp
against.

**Two different symmetric shapes, not one.** The 6 elements + Body use
`affTerm(atkRaw,defRaw) = (1+mul(atk))*(1-mul(def))` — the attacker's own
value boosts their output, the DEFENDER's own value on the same axis
MITIGATES what they take, same shape DEF/RES already have. Spirit uses a
different helper, `affBoost(a,b) = (1+mul(a))*(1+mul(b))` — both sides
BOOST. This was **not** a hunch; naively reusing `affTerm` for Spirit
(as the approved plan's own pseudocode literally wrote) was traced by
hand before implementing further: a target's *negative* Spirit would have
made `(1-mul(negative))` come out **greater than 1**, i.e. a
Spirit-negative unit would have received *more* healing — the exact
opposite of the plan's own explicit promise, "a Spirit-negative unit is
genuinely hard to keep buffed/healed." `affBoost` fixes the direction:
both caster and target Spirit push the same way, so a high-Spirit target
receives stronger heals/buffs (and, by the same uniform mechanism, is hit
harder by a debuff too — the unstated flip side of "attuned to magic
effects," consistent with though not explicitly spelled out in the
original ask).

**Damage integration** (`resolveHit`): one new multiplicative term,
`o.affMul = affinityFactor(src,tgt,act)`, alongside the existing `o.mit`
(DEF/RES mitigation) — Body always applies to a physical (`camp==='atk'`)
action; the action's own `element` field (mandatory on every magic
action that deals direct damage, optional on physical, absent on
heal/buff/debuff-only actions) stacks multiplicatively on top if present.
**Healing** (`healFor`) and **status magnitude** both route through
Spirit via `affBoost`.

**Status magnitude — the invasive part, handled with one new parallel
field.** `u.st[id]` used to be a bare turn counter; every status's actual
magnitude (Bracing's DEF/block bonus, Burning's DOT%, Slowed's turn-cost
penalty, ...) was a hardcoded constant read directly inside ~10 different
`eff*()`/`tcOf`/DOT functions. `STATUS_BASE_MAG` pulls every one of those
constants into a single table (as the delta from baseline); `apply(u,id,
t,casterSpirit)` gained a 4th parameter and now computes+stores the
Spirit-scaled magnitude for THIS application in a new parallel `u.stMag`
map, populated once at apply-time (not re-derived on every read) so a
status keeps the magnitude it landed with even if the caster's Spirit
changes later. Bracing carries two independent magnitudes under one
status id (a DEF ratio and a flat block bonus), so its `STATUS_BASE_MAG`
entry is an object of sub-magnitudes rather than a bare number —
`magOf(u,id,key)` reads either shape uniformly. Every `eff*()`/`tcOf`/
DOT read site now calls `magOf` instead of a hardcoded literal.

**Data model — purchased points, not a merged value.** `G.affinities` is
`{uid:{fire,water,...}}`, PURCHASED points only — a companion's authored
CSV baseline (`C.ROSTER[uid].affinity`/`C.ARCH[key].affinity`, new
`affinity_*` columns on `farroadunits.csv`/`farroadenemies.csv`) is a
separate number. The effective combat-time value is baseline+purchased,
computed once at party-build time (`buildParty`/`buildExpeditionParty`,
mirroring exactly how `P.statsAt` already combines a base stat with
level-derived growth) — kept as two numbers specifically so "how many
points has the player actually bought" is a real, separately-readable
figure for both the escalating cost curve (`P.affinityCostToNext`, mirrors
the Lore-bonus linear-escalation shape) and the new **Power Level** term
(`P.POWER_PER_AFFINITY_POINT`, sums only purchased points across every
owned unit/axis — a companion's own baseline does NOT count, exactly like
`unitLevels` counting real level-ups rather than a unit's starting
stats). Enemies have no investment layer at all — `buildEnemies` reads
`C.ARCH[key].affinity` unmodified.

**A custom MC starts genuinely neutral, caught by live-browser testing,
not assumed.** `applyCustomMC()` copies name/hp/chargeAction/stats/growth
from `G.mc` onto the shared `kesh` ROSTER row, but originally left that
row's own `affinity` object untouched — so a custom MC silently inherited
`kesh`'s CSV-authored baseline (Body +3) instead of the all-0 neutral
start the design promised. Found by actually opening the built HTML,
creating a character, and reading the AETHER tab's own Body row (it said
+3, not +0) rather than trusting the code read-through. Fixed with one
line: `keshDef.affinity=C.defaultAffinity();` inside `applyCustomMC()`.

**Two balance findings surfaced by a headless VM-sandbox script (same
pattern as every prior tuning pass), reported rather than silently
"fixed" without Ian's input — both were explicitly anticipated risks in
the original plan, now measured instead of guessed:**
- **Physical+elemental double-stack is real and large.** A fully-invested
  attacker (both Body and an element at the ±20 cap) against an
  oppositely-invested defender measured a ~10.6× damage swing on
  `spellbrand` (camp `atk`, element `water`) — matching the predicted
  3.24² independent-compounding figure almost exactly. This only reaches
  players through the 3 actions deliberately double-tagged in this first
  pass (`spellbrand`/water, `def_slam`/earth, `bloodfury`/fire) and
  requires both sides near-maxed, not something reachable by accident —
  flagged as "a real, exciting swing," per the plan's own framing, not a
  runaway bug, but worth Ian's eyes before any of those 3 actions get
  balanced further.
- **A large base status magnitude stacked with maxed Spirit could exceed
  its intended range — FIXED, `AFFINITY_BOOST_CAP`.** Warded's base −40%
  incoming-damage delta, scaled by `affBoost` at both sides maxed (up to
  3.24×), measured a −129.6% delta — more than 100% mitigation. Worse
  than the cosmetic overshoot it first looked like: `resolveHit`'s
  existing `Math.max(1,Math.floor(d))` floor happens to absorb the
  Warded case, but the SAME unclamped multiplier also feeds `tcOf`'s
  Hasted term, which has no such incidental protection — enough Spirit
  stacked with Hasted could have pushed a unit's tick cost toward
  `tcRaw`'s own floor of 1, a genuine near-infinite-turns exploit, not
  just a wasted overshoot. Unlike the double-stack finding above, this
  wasn't confined to a few exotic actions (Spirit governs every support/
  heal action), so it was fixed rather than left to watch: `affBoost`
  is now capped at `AFFINITY_BOOST_CAP=2.0` — chosen so the largest base
  magnitude in `STATUS_BASE_MAG` (Warded/Hasted, −0.40) caps out at
  EXACTLY −0.80, the same ±80% ceiling `AFFINITY_CAP` already guarantees
  everywhere else in this feature, not a second arbitrary number. Applies
  uniformly to `healFor` too (same shared helper) — re-measured
  both-Spirit-maxed healing dropped from 116 to 72 (the exact capped
  figure), Warded's delta from −1.296 to exactly −0.80. One new smoke
  check (`farroadsmoke.js`, 142→143) regression-guards the cap by driving
  a real Bulwark cast through `C.step` and asserting the resulting
  `stMag.warded` lands at exactly −0.80 with both sides at `AFFINITY_CAP`.

**Verified**: `node farroadsmoke.js` — 21 new checks (122→143): `C.affinityMul`
monotonic/odd-symmetric/exact ±0.80 endpoints/plateau past the cap,
`P.affinityCostToNext` escalates and stays positive, every magic damage
action in the compiled content carries an element (content-pipeline.js's
own build-time validation enforces this too — same fail-loudly pattern as
the `charge_action` check), `C.makeUnit` defaults/overrides affinity
correctly, real deterministic battles (`C.makeBattle`/`C.step`, same
pattern `digestRun` uses) confirming Fire/Body/Spirit each measurably
change damage/healing in the correct direction, and `G.affinities`
round-trips through save/load including the old-save default-fill path.
Balance validated via a headless VM-sandbox script (scratchpad) — see the
two findings above. Live browser pass: character creation confirmed
unchanged (no affinity content anywhere on `#mcCreate`); AETHER tab shows
all 8 axes with descriptions, current raw→%, and a working +1 purchase
button that spent the correct escalating Aether cost, updated the raw
value/percentage/next-cost display, and moved Power Level; caught and
fixed the custom-MC-baseline bug above in this same pass.

## Block/Evade/ATK-Crit/MAG-Crit level like affinities — but shaped like Recovery

Floated as an aside while designing elemental affinities, deliberately
deferred then; requested directly this phase: "make the change to evade,
block, and the crit rates to level like affinities." Two questions
resolved the design before any code was written: character creation
drops these 4 stats entirely (a custom MC starts at 0 in all four,
exactly like affinities — not kept as a creation-time baseline with
Aether stacking on top), and the investment curve mirrors **Recovery's**
existing mechanic, not affinities' logarithmic ±80% one — Block/Evade/
Crit are already bounded 0-to-hard-engine-cap percentages (`CAP_BLOCK`=
.50/`CAP_EVADE`=.40/`CAP_CRIT`=1.00, `farroad-core.js`), the exact shape
Recovery (`P.REST`/`P.REST_CAP`/`P.REST_STEP`, `recoveryCost()`) already
solves, unlike affinities' symmetric, either-direction axis.

**No CSV changes needed** — `atk_crit`/`mag_crit`/`block`/`evade` already
existed as real per-unit/per-archetype columns and were already the sole
source of these stats; they simply become the "baseline" half of the
same baseline+purchased split `G.affinities` established last phase.
New `G.statInvest` holds purchased STEP COUNTS only (`{uid:{block,evade,
atkCrit,magCrit}}`); a new `farroad-ui.js` helper, `effectivePctStats`
(driven by `applyPctStatInvestment`), combines baseline+steps*step into
the effective value and overwrites `P.statsAt`'s output with it —
`P.statsAt` itself stays completely untouched, same "core formula
unmodified, UI layer combines it with investment" shape
`effectiveAffinity` already used.

**Caught the exact same bug class the affinity feature caught, before
it shipped this time.** `applyCustomMC()` (`farroad-ui.js`) used to
build `keshDef.stats` by reading `G.mc.stats.atkCrit`/`.magCrit`/
`.block`/`.evade` straight off the creation payload — once these 4 left
`P.MC_STAT_KEYS`, `G.mc.stats` never carries those keys again, and
reading them would silently write literal `undefined` onto
`keshDef.stats` (a key IS present, `makeUnit`'s `hasOwnProperty` merge
loop WOULD copy it over the sane default). Set explicitly to `0`
instead, in the same edit, rather than waiting to discover it live the
way the affinity version of this bug was found last phase.

**Cost curve needed real retuning, not just a plausible first guess.**
A naive shared `growth=1.45` (Recovery's own rate) applied at each
stat's initially-chosen step size measured wildly outside the intended
range: Block cost 6,996 Aether to cap (4× one maxed affinity axis),
ATK/MAG Crit cost 52,484 each (**31×**) — at that price 100% crit is
not a build target, it is unreachable in a normal run. Re-solved per
stat (VM-sandbox balance script, scratchpad) for a total cost-to-cap in
the same rough order as Recovery's own climb (890 Aether) and one
maxed affinity axis (1,680): Block 838 (10 steps of 0.05, base 12,
growth 1.40), Evade 1,023 (14 steps of 0.03 — kept matching Recovery's
own step for continuity, growth softened to 1.30 to compensate), ATK/
MAG Crit 2,077 each (13 steps of 0.08, base 15, growth 1.35) —
deliberately pricier than Block/Evade, reflecting crit's bigger ceiling
(1.00 vs 0.50) and bigger payoff (multiplies the WHOLE hit, vs. block
only halving it), not forced to the same total as a cheaper stat.
Re-measured after retuning: a real deterministic battle confirmed Block
moves from a baseline ~2.8% blocked to ~49.9% at the cap, and ATK Crit
from ~4.8% to ~98.6% — both a real, felt combat difference, not
swallowed by anything downstream.

**Live browser pass caught one more thing code review alone would have
missed: stale help copy.** `shell.html`'s character-creation screen
carried a static line — "CRIT/BLOCK/EVADE don't grow with level for
any unit in the game, so a point there is fixed for the run" — written
for a screen where those 4 stats were still offered as points to spend.
Once the sliders were removed the sentence still rendered, now
describing controls that no longer exist. Found only by actually
opening the built page and reading the creation screen, not by
re-reading the diff. Rewritten to say what's actually true now: these
4 aren't offered here at all, bought up via Aether in the AETHER tab
instead, same as affinities.

**Verified**: `node farroadsmoke.js` — 20 new checks (144→164, on top of
2 existing section-7 checks updated for the shrunk `P.MC_STAT_KEYS` and
a pre-existing hardcoded "half the stats = 5" test fixed to derive the
split from `keys.length` generically instead, which would have silently
broken the moment the key count changed): `P.pctStatCost` escalates and
stays positive for all 4 stats, `P.pctStatValue`/`P.pctStatMaxed` clamp
exactly at each stat's own cap, Power Level responds to purchased steps
and matches its own documented formula, `G.statInvest` round-trips
through save/load including the old-save default-fill path.
`applyCustomMC()` itself is DOM-bound UI-layer code (not loaded in the
headless smoke harness) — its "starts at exactly 0" property is verified
live instead, alongside `node build.js` and a full browser pass: creation
now shows exactly 6 stat sliders (45 points, matching the auto-scaled
pool) with no CRIT/BLOCK/EVADE and no stale help text; a fresh custom
MC's AETHER tab shows all 4 new rows starting at exactly 0%; a real
purchase (Block, 0%→5%) spent the exact computed cost (12), advanced the
displayed value, escalated the next cost to 17 (matching `12×1.40`), and
moved Power Level (17→18) — no console errors.

## Block removed — Body already covers physical mitigation

Requested directly, same phase Block became Aether-investable: "remove
block, since we already have Body which can handle physical damage
reduction." A real mechanic removal, not a UI trim — touched the damage
formula, every unit/enemy's CSV baseline, and the investment system
that had only just shipped.

**Confirmed with Ian mid-plan, not left as a silent gap**: removing
Block would have left physical attacks with strictly less defense than
before (no block AND evade at half strength, since the old `NEG` table
gave physical only half evade effectiveness — block was meant to be its
primary answer). Fixed directly: evade is now full strength against
both camps, and the entire `NEG`/`NG` per-camp-weighting mechanism
(the "a sword gets parried, a spell goes wide" asymmetry, live since
v1.1) is gone — with block gone it would have computed nothing but a
constant ×1.00.

**Two things confirmed to need no manual rebalancing, not assumed**:
`dmgTakenMul()` (`farroad-core.js`) already sizes each enemy archetype's
HP relative to its own def/evade/block versus the Roadwolf reference —
dropping block's term from that formula is itself the compensation:
re-measured directly, Barrow Knight's computed multiplier rose from
~0.615 to 0.647 (+5.2%) and Stone Ox's from ~0.836 to 0.857 (+2.5%),
both self-correcting toward more HP without a hand-tuned constant
anywhere. And Dorrek's tank identity (his design note used to read
"Only unit with block 0.10") already had the roster's highest Body
baseline (+4) from when affinities shipped two phases ago — the
identity had already transferred; only the sentence describing it
needed rewriting, not the numbers.

**Explicitly out of scope, consistent with a pre-existing gap**:
`farroadcontentdesigner.html`, Ian's own standalone authoring tool,
still has `block`-shaped input fields, a `dmgTakenMul` preview
calculator, and an `effBlock` code-gen snippet in its status-effect
builder — all now describing removed mechanics. Left untouched because
it was ALREADY out of sync (no `affinity_*` fields were ever added
there when affinities shipped) — a resync pass is a natural, separate
follow-up (git history shows one happened before, as its own dedicated
commit), not something to bundle silently into this change.

**`STATUS_BASE_MAG`/`magOf` simplified, not just trimmed.** Bracing was
the one status with two independent magnitudes under one id (a DEF
ratio and a flat block bonus, `{def:0.40,block:0.30}`) — specifically
because it modified two stats. With block's half retired, no status in
the table is multi-part any more, so `magOf(u,id,key)` lost its
sub-key branch and its one caller (`effDef`) lost the now-meaningless
`'def'` argument, rather than leaving dead generality for a case that
can no longer occur.

**Verified**: `node farroadsmoke.js` — 162/162 (down from 164: -3 from
the STATS loop dropping to 3 stats, +1 new "Block no longer exists"
guard, net -2, matching exactly). A VM-sandbox balance script
(scratchpad) confirmed evade now measures IDENTICAL effectiveness
against a physical vs. a magic attacker at the same stat (20.0% both,
was 20% physical/40% magic-equivalent under the old asymmetry); a
physical attacker vs. a Body/DEF-defended target produces a sane,
non-degenerate range (no negative or runaway multipliers); crit
measured unaffected (5.1% at a 5% setting, confirming this change is
properly scoped); and the `dmgTakenMul` self-compensation numbers
above. Live browser pass caught one more stale-copy bug the same way
the custom-MC-baseline bug was caught last phase — actually opening the
page, not re-reading the diff: the AETHER tab's investment section
still read "BLOCK / EVADE / CRIT" as its heading after Block's row was
removed from it. Fixed to "EVADE / CRIT". Combat log confirmed to
contain no `BLOCK` tag or block-chance text anywhere after a live
fight; console clean throughout.

## Companion quest stage rewards + a Give Up button

Ian's ask: quest stages should pay Aether, scaling 100 (stage 1) to 500
(stage 5); and a way to back out of a quest attempt already in progress
without waiting for the auto-battle to actually lose. Both land in
`finishSideBattle()`/`renderQuests()` (`farroad-ui.js`), the same
live-side-battle machinery dungeons already share.

**Reward**: new `P.questStageAether(stageIdx)` (`farroad-progression.js`)
— linear across the 5 stages, `P.QUEST_STAGE_AETHER_MIN=100` at stageIdx
0 to `P.QUEST_STAGE_AETHER_MAX=500` at stageIdx 4, hitting both endpoints
exactly. `finishSideBattle`'s quest-win branch now grants it
(`G.aether+=reward`) and mentions it in both the drop notice and the
sysLog line, same style the boss-hoard grant already uses. The AETHER-tab-
style "+N Aether on clear" is also shown directly on each quest's row in
the QUESTS tab (`renderQuests()`), not just after the fact, so the payoff
is visible before committing to the attempt.

**Give Up**: `giveUpQuest()` — a thin wrapper that calls
`finishSideBattle('enemy',true)` on the currently-live side battle. The
`gaveUp` flag is new: same result as a genuine defeat for every reward/
state purpose (no stage advance, no penalty either way — quest losses
already had none), but the log/drop wording says "The attempt was
called off" / "QUEST ABANDONED" rather than "The party was defeated" /
"QUEST FAILED" — worth the small branch rather than mislabeling a
voluntary retreat as a loss. Scoped to quests only, not dungeons, per
Ian's own wording ("the quests you are currently attempting"). Confirmed
safe to call at ANY point mid-fight, not just after `battle.over` fires
(the normal path): `finishSideBattle` never reads the live battle's own
`over` state — it unconditionally tears down `G.sideBattle`/restores
`G.roadBattle` and branches purely on the `result` argument — so calling
it early just short-circuits the same teardown doStep() would have
triggered anyway once the fight naturally ended.

**UI**: `renderQuests()`'s active-quest row swaps its Attempt button for
a Give Up button specifically on the row matching
`G.sideBattle.meta.uid` — every OTHER quest row stays disabled with the
existing "a battle is already in progress" title, unchanged.

**Verified**: `node farroadsmoke.js` — 166/166 (4 new: `questStageAether`
hits both endpoints exactly, is strictly increasing, and matches the
literal 100/200/300/400/500 schedule). Live browser pass exercised the
full loop on Kesh's own quest line (owned from `newGame()`, so stage 1 is
attemptable immediately, no grinding needed): confirmed the row shows
"+100 Aether on clear" before attempting; started an attempt, confirmed
the row swapped to a working Give Up button, clicked it, confirmed a
"QUEST ABANDONED — The attempt was called off" drop, the Road battle
resumed cleanly, and the row reverted to Attempt at stage 1 (no
progress lost); re-attempted, let it play to a win, confirmed Aether
went 0→100 and the row advanced to "Stage 2 of 5 · +200 Aether on
clear" — the full schedule confirmed end to end, not just the formula
in isolation. No console errors throughout.

## Kesh's name — replaced everywhere the player's own choice should show

Ian's ask: "replace all mentions of Kesh (the MC stand-in) with the
name the player chooses." Most of the UI already got this for free —
`applyCustomMC()` (roadmap item 1) already writes `G.mc.name` onto
`C.ROSTER`'s kesh row, and everything that renders a unit reads that
row's `.name` live — so this was never about a sweeping rename; it was
about finding the handful of spots that DIDN'T get it for free.

**Researched first, not guessed**: grepped every source file and every
content CSV for literal "Kesh" mentions, then sorted what came back
into three buckets — the internal id `'kesh'` (a dict key throughout
`G.lvl`/`G.bank`/`G.owned`/etc., invisible to the player, correctly
left untouched), code comments (dev-only, left untouched), and actual
player-facing text. The third bucket had two shapes: two hardcoded UI
strings in `farroad-ui.js` (a LORE-tab tooltip — "kept as part of
Kesh's charge pool" — and the TESTS tab's debug dump — "Kesh level"),
and static CSV-authored prose that can't read live game state at
CSV-author time: kesh's own 5 quest-stage story placeholders
(`farroadquests.csv`) and `oath`'s (Kesh's original, pre-customisation
charge action) design note (`farroadactions.csv`), both confirmed live
during the PREVIOUS phase's own testing ("PLACEHOLDER — Kesh, stage 1."
showed up in a drop notice for an MC already named "Testwind").

**Built the render-time substitution the CSV cases actually needed**,
rather than hand-fixing today's placeholder text and losing the ability
to reference the player's name at all: `mcName()` (reads the current
name straight off `C.ROSTER`'s kesh row, same lookup pattern used
everywhere else in the file) and `withMcName(text)` (a no-op
`{{name}}` token replacement — returns the string completely unchanged
if the token isn't present, so it's safe to wrap uniformly rather than
special-case the specific rows that use it today). CSV content authors
`{{name}}`; the UI substitutes the live name wherever that text is
actually displayed.

**Wrapped every site that displays action-note or quest-story text**,
not just the two currently affected — `describeAction()` is the single
choke point for most of them (6 call sites read `.note` off its return
value), plus 6 more direct `C.ACTIONS[...].note` reads that bypass it
(the LORE-tab detail box, the gambit-slot editor, the charge-action
display box, and three companion-recruitment drop notices) and the one
`.story` capture site (`attemptQuestStage`). Cheap to wrap all of them
uniformly (the no-op case costs one `.replace()` call) rather than
auditing which ones could theoretically reach a `{{name}}`-bearing row
today — future authored content (Ian's own placeholder text throughout
is explicitly marked as such — real narrative comes later) can use the
token in any of these fields and it'll just work.

**Verified**: `node farroadsmoke.js` — 168/168 (2 new: kesh's quest
story text and `oath`'s note both use `{{name}}`, neither contains a
literal "Kesh" — a regression guard against the name being typed back
in by hand later without knowing about the token).
`mcName`/`withMcName` themselves are DOM-bound UI-layer functions, not
loaded in the headless harness — verified live instead: created a
custom MC named "Aria", confirmed the quest-stage story text read
"Aria, stage 1" (not "Kesh, stage 1" or a raw "{{name}}, stage 1"), and
confirmed the TESTS tab's debug dump read "Aria level" — both of the
two previously-hardcoded UI strings and the CSV substitution path
exercised end to end. No console errors.

## Doubling the climb to max Evade/Crit/Affinities

Ian's ask: "double the number of times [Evade, ATK/MAG Crit, and the
affinities] need to be leveled to max them. This should double the
cost to max them." Both halves of that sentence are real, independent
constraints, and they don't fall out of touching one constant — every
one of these curves is an ESCALATING cost (linear-triangular for
affinities, geometric for the other three), so doubling how many
purchases it takes to reach the cap, with nothing else changed, raises
the TOTAL cost by far more than 2x (a triangular sum is quadratic in
step count; a geometric sum is exponential in it). Solved directly
instead of guessed — same VM-sandbox methodology as every prior tuning
pass, but this time solving FOR the new constants rather than just
measuring existing ones.

**Affinities** (`AFFINITY_CAP`/`AFFINITY_COST_BASE`): doubling the step
count has a clean closed-form answer here, since the cost curve is
linear (`cost(n)=BASE*(n+1)`, a triangular sum). `AFFINITY_CAP` doubles
20→40 (`farroad-core.js`); the base that makes THAT doubled-length sum
land on exactly double the old total works out to
`BASE_old*(N_old+1)/(2*N_old+1) = 8*21/41 = 4.0976` — not a round
number, so `affinityCostToNext` now rounds its output (matching every
other per-step cost function in the file) rather than showing
fractional Aether. Verified: 40 steps, 3,360 Aether total — exactly
2.000x the old 20 steps/1,680 Aether.

**Evade/ATK Crit/MAG Crit** (`P.PCT_STAT`): no closed form for a
geometric curve's growth rate given a target sum, so solved
numerically (binary search in a scratchpad script) — step halved for
each stat (so twice as many purchases reach the same hard-engine cap),
`costGrowth` reduced to compensate for the geometric explosion that
halving alone would have caused, `costBase` held deliberately fixed
(what the FIRST purchase costs is unchanged — 8 for Evade, 15 for
either Crit). Landed within ~1% of exactly double on total cost for
all three (Evade 2,045 vs. the target 2,046; ATK/MAG Crit 4,177 vs.
4,153) — step counts land at ~1.9x rather than an exact 2x purely
because the caps (0.40, 1.00) don't divide evenly by the halved step
sizes, the same ceiling-function rounding the ORIGINAL step counts
(14, 13) already had, not a new imprecision this change introduced.

**Verified**: `node farroadsmoke.js` — 168/168 (one pre-existing
assertion updated for the new rounding — `affinityCostToNext(0)` now
equals `Math.round(AFFINITY_COST_BASE)`, not the raw constant — every
other existing check was already parametric, reading the live constants
rather than hardcoding old numbers, so needed no changes). Live browser
pass confirmed the AETHER tab renders the new figures exactly as
calculated: Evade "0% → 1.5%" (was 3%) at cost 8 (unchanged), ATK/MAG
Crit "0% → 4%" (was 8%) at cost 15 (unchanged), and Fire (representative
affinity) "+1" at cost 4 (was 8, the halved base). No console errors.

## Nine-item feedback batch — layout, Spirit/drain, icons, weaknesses, Lore cleanup

Ian's feedback on the affinities/investment arc, all raised in one
message. Two needed real back-and-forth to pin down exactly, not just
implement — flagged here since "asked a clarifying question, got a
clear answer, moved on" is itself worth recording as the reason the fix
landed on the right target the first time:

- **"Squished" affinity rows** — screenshotted the live AETHER tab
  before touching anything. `.node` (`shell.html`) turned out to be
  `display:flex;justify-content:space-between` — fine for Recovery's
  one-line description, but the longer affinity descriptions (Body/
  Spirit especially) wrapped their VALUE column too, visibly breaking
  ("+0 →" and "+0%" splitting across lines). Grepped first: `.node` is
  used by exactly 3 call sites in the whole codebase (Recovery, the
  Evade/Crit rows, the affinity rows — all in `renderAether()`), so
  restyling it directly was safe. Changed to a stacked layout reusing
  `.bslot`/`.bdesc`'s already-established shape from the LORE tab (name,
  then description on its own line, then a `.spread` row for value+
  button) — the three row types now share one real layout, not just a
  similar-looking one.
- **The level-up arrow** — two rounds of AskUserQuestion, because "an
  arrow pointing to the current level" didn't match anything in the
  three places level+arrow both appear in the AETHER tab (all three
  already pointed at the NEXT level correctly). Confirmed on the second
  round: the plain "LV 1" header badge itself should become "LV 1 →
  LV 2". Not what a code-only read would have found.

The rest, more directly scoped:

- **Spirit's description** now says "in-combat healing... including
  drain/lifesteal effects like Siphon" AND says so correctly — Siphon/
  Bloodfury/Hollow Toll's lifesteal previously did NOT scale with
  Spirit at all (`step()`'s lifesteal branch read straight off the
  already-affinity-scaled damage, which is element/Body, never Spirit).
  Real fix, not just a claim made true by wording: lifesteal now
  multiplies by `affBoost(u.affinity.spirit,u.affinity.spirit)` (a
  self-heal — same unit is both caster and recipient).
- **Element/camp icons** — new `actionGlyph(a)`/`actionGlyphText(a)`
  (`farroad-ui.js`): every action always shows a camp icon (⚔️ physical/
  🔮 magic), ADDITIONALLY an element icon+color when `a.element` is set
  — both signals together, not either/or, so Spellbrand (physical +
  water) shows ⚔️💧. `describeAction()` is the one choke point that
  covers most display sites (drop notices, MC creation charge cards);
  6 more direct call sites needed their own wrap (LORE/GAMBITS detail
  headers, combat log, turn-order rail, both `<select>` dropdowns — the
  plain-text `actionGlyphText` variant for those, since native
  `<option>` elements can't render HTML/color). 8 new CSS vars
  (`--fire`/`--water`/`--earth`/`--air`/`--light`/`--dark`/`--body`/
  `--magic`) — `--body` deliberately doubles as both "physical action"
  and "Body affinity," one visual identity, not two.
- **"Weak to" notes on unit/enemy cards** — `weaknessLine(u)`
  (`farroad-ui.js`), right after the existing DEF/RES line in
  `renderUnits()`: lists any affinity axis where `u.affinity` (already
  the effective value — baseline+investment for a party unit, straight
  baseline for an enemy) is negative. Grepped every CSV baseline first:
  zero negatives existed anywhere, so this would have shipped silent
  for every unit and enemy in the game. Added a first pass of 3 thematic
  weaknesses to give it real content — Mire Hound/Light (-3, "a creature
  of the mire's gloom"), Stone Ox/Water (-3, "stone wears down under
  running water"), Thorn Shrike/Fire (-3, "dry bramble growth") — same
  "I do a first pass, Ian tunes later" precedent as the original
  element-on-actions assignment.
- **Keen (crit) removed from Lore** — redundant now that ATK/MAG Crit
  are directly Aether-investable (`P.PCT_STAT`). Real removal (`BONUSES`/
  `bonusApplies`/`applyBonuses`, `farroad-core.js`), same treatment
  Block got — but unlike Block (nothing had been spent on it yet when
  it was removed), players COULD already have Lore sunk into Keen, so
  `farroad-save.js` migrates it: refunds the triangular-cost difference
  a save's own bonus map drops by once keen no longer counts toward that
  action's stack total (reuses `C.bonusSpend`'s existing closed-form
  pricing rather than reimplementing it), then strips keen so it can
  never be read again.
- **Broad's description** was actively wrong — "+1 target covered"
  describes a per-stack increment; `applyBonuses` shows the real
  mechanic (confirmed by reading the code, not assumed): ONE stack
  converts a single-target action to hit the WHOLE party or WHOLE enemy
  side, flat, further stacks doing nothing. Reworded to say what it
  actually does; mechanic untouched.
- **Enrage** scaled ATK only — a MAG-using enemy (Fen Priest, or any
  archetype with a real mag stat) got no stronger from enrage at all.
  Now scales MAG too, log/card wording changed from "+N% ATK" to
  "+N% damage" to match.
- **Drop-notice condensing** — the three bare "+1 Lore" duplicate cards
  (action/charge action/gambit) and the "PULL · duplicate unit" Aether
  conversion are exactly the shape that clutters an idle catch-up
  banner with several near-identical cards in a row; Boss Hoard/Welcome
  Back/quest rewards stay real cards since each carries genuine per-
  event context, not just a number. New `G.dropGains={lore,aether}`
  running total + `addDropGain()`, rendered as ONE synthetic card
  alongside the real `dropQueue` items, both reset together on "Got it".

**Verified**: `node farroadsmoke.js` — 179/179 (11 new checks): Keen
genuinely gone from `BONUSES`/`bonusApplies`; a save with banked keen
stacks migrates the correct triangular-cost refund to `G.lore` and
strips keen without throwing; enrage's MAG scaling and lifesteal's
Spirit scaling both confirmed via real battles (`C.makeBattle`/
`C.step`), not just formula inspection. Live browser pass: AETHER tab's
three row types confirmed visually consistent via screenshot (no more
wrapped/squished values); the level badge reads "LV 1 → LV 2"; Spirit's
corrected description renders correctly; MC creation's charge cards and
the turn-order rail both confirmed showing icons correctly (⚔️ physical,
🔮 magic, element icons layered on top); `C.BONUSES.keen` confirmed
`undefined` and `C.BONUSES.broad.d` confirmed reading the corrected
text live; the 3 new enemy weakness baselines confirmed compiled
correctly via `C.ARCH`. Not exercised live: the condensed drop-notice
card specifically, which needs wave 20+ (when drops turn random) to
trigger a real duplicate — covered by code review and the save-
round-trip structure only, disclosed rather than claimed as fully
verified.

## Rarity — Common/Rare/Legendary for actions and units

Ian: "I want to introduce rarities for actions and units (and in the
future, equipment), with the rare ones being more specialized and/or
powerful." Four clarifying questions settled the shape before writing
any code — 3 tiers (Common/Rare/Legendary); retroactive (sort the
existing ~59 actions and 10 units into tiers now, not just new content
going forward); units get genuinely stronger stats AND a unique charge
action, not just a label; actions get "real power bump too", not only
specialization. The trade-off, quoted directly: *"I'd like units and
actions to be comparable with the same investment. This will result in
the things that are more rare naturally being more late game as well."*
Read as: cost scales FASTER than power per tier, so a Rare pick isn't a
strict upgrade at equal Aether/Lore spend — it costs more to reach its
higher ceiling.

**Not invented from nothing** — `P.MC_STARTER_CHARGES` (3 generic, plain)
vs. `P.MC_CHARGE_DROP_POOL` (18 "corner" charges, gated behind
`P.MC_CHARGE_DROP_CHANCE=0.10`) was already a 2-tier rarity system in
every way but name. This generalizes that exact shape into a named,
3-tier system covering every action and unit, rather than building
something structurally new next to it.

**Data model**: `RARITY_POWER_MUL={common:1.00,rare:1.25,legendary:1.55}`
and `RARITY_COST_MUL={common:1.00,rare:1.60,legendary:2.40}`
(`farroad-core.js`) — cost deliberately steeper than power at every
tier, the mechanical expression of the trade-off above. New `rarity`
CSV column on `farroadunits.csv`/`farroadactions.csv` (NOT
`farroadenemies.csv` — left untouched this pass; `compileRarity(r)`
(`content-pipeline.js`) already defaults a missing column to `'common'`
per row, so leaving the enemy CSV alone is a real no-op, not a gap).
Invalid rarity strings are passed through uncoerced rather than
silently defaulted, so `buildContent()`'s new validation loop catches a
typo the same way it already catches a bad `element`/`charge_action`.

**First-pass assignment — reasoned, not arbitrary, tunable**:
- Units: the roster-expansion five (Skarn/Sorin/Nyra/Brenn/Sael) are
  Rare; the original five (Kesh/Ansa/Dorrek/Vey/Mirel) are Common.
  Grounded in an asymmetry that already existed — the original five
  arrive on a guaranteed milestone schedule (`P.UNIT_WAVES`), the
  expansion five are pull-only with no guaranteed date — this plan just
  names it. No Legendary unit yet (an open pick, left for later).
- Actions: the baseline equippables + 3 MC generic starters stay
  Common on purpose (several are explicitly authored as "the baseline,
  everything else is measured against this" — promoting them out of
  Common would undermine that role). The 18-action `MC_CHARGE_DROP_POOL`
  + the 10 companion-exclusive charge actions are Rare. `reckoning` and
  `hollowtoll` are promoted to Legendary (a companion unit's own charge
  action would be Legendary too if/when a Legendary unit is picked).

**Power** — hand-authored bumps, no new formula: every Rare/Legendary
unit's `farroadunits.csv` base stats AND `P.GROWTH` per-level growth
(`farroad-progression.js`) are the original value × that tier's
`RARITY_POWER_MUL`, computed via a Node script and rounded, same as
`power`/`defPierce`/`critBonus` on every promoted action's CSV row.
`reckoning`'s `ACTION_DYNAMIC.powerFn` (`farroad-core.js`) — a hardcoded
formula that overrides the CSV `power` field entirely for that one
action — got its own constants scaled the same way (2.0/4.5 →
3.1/6.975), since bumping the now-cosmetic CSV field alone would have
done nothing to its actual damage.

**Cost** — one multiplier layered at two existing choke points, core
formulas left pure: `rarityCostMul(uid)` (`farroad-ui.js`) wraps
`P.costToNext` in both `costNext()` and `feedUnit()`'s bank loop, same
layering pattern `effectiveAffinity()`/`applyPctStatInvestment()` already
established for per-unit adjustments. `bonusPrice`/`bonusSpend`
(`farroad-core.js`) both read `RARITY_COST_MUL[a.rarity]` directly —
Lore costs on a Rare/Legendary action scale the same way. Fixed a real
bug surfaced by the new smoke test here: `bonusPrice` rounds EACH
purchase individually (Lore is spent in whole points), so at any
`mul!==1` the closed-form triangular sum `K*(K+1)/2*mul` drifts from
the true total once rounded — `bonusSpend` now sums the same
`Math.round(k*mul)` per step bonusPrice would have charged, rather than
rounding the smooth sum once at the end.

**Acquisition** — rarity is rarer to GET, not just costlier to grow:
- `randomDrop()`'s existing 10% MC charge-drop gate now rolls a nested
  Legendary-vs-Rare choice once it fires (`P.MC_LEGENDARY_CHARGE_CHANCE
  =0.15`) — uniform within whichever tier is picked, derived from each
  action's own `.rarity` field rather than a hardcoded id list.
- `doPull()`'s unit branch now calls `P.weightedRosterPick(rng,avail)`
  (`farroad-progression.js`, explicit-rng signature mirroring
  `P.rollCount`/`P.COUNT_WEIGHTS` so it stays headless-testable) instead
  of a uniform pick — `P.RARITY_PULL_WEIGHT={common:3,rare:1,legendary:1}`
  skews pulls toward Common. Lives in progression.js rather than ui.js
  specifically so `farroadsmoke.js` (core+progression+save only, no DOM)
  can exercise it directly.
- The curated milestone unit-award path (`P.unitDueAt`) is untouched —
  deterministic, not random, so a weighting has nothing to act on there.

**Visual treatment**: `--rare`/`--legendary` CSS vars (`shell.html`,
alongside the element vars from the icon phase) and a `.rtag` pill,
same convention `.pill`/`.bosstag` already use for short status labels.
Common gets no badge — the absence already reads as default. Wired via
`rarityTag()`/`rarityTagText()` (HTML pill vs. plain-text for native
`<select>` options, which can't render markup) into `describeAction()`'s
one choke point plus the LORE header, GAMBITS action tabs, both action
`<select>`s, the MC's equipped-charge-action box, the AETHER-tab unit
box and unit-tab selector, and the pull-result drop banner. Skipped
deliberately on the turn-order rail (76px chips — too cramped) and the
combat log (would spam every hit).

**Balance validation** (Node/VM script, not shipped as a file — ad hoc,
same as every prior tuning pass): simulated a fixed Aether budget spent
purely on leveling a synthetic Rare unit (real base+growth × 1.25)
against its Common counterpart, at 4 budget/ratchet pairs spanning
early to very-late game. Rare's total stat output is consistently
10-20% ahead of Common's at equal spend, the edge SHRINKING with scale
rather than growing — at first glance the opposite of "more of a
late-game thing." Traced the cause: Rare's edge comes almost entirely
from the free, un-costed base-stat head start (`RARITY_POWER_MUL`
applied once, for nothing, to the CSV row), not from leveling being a
bargain. Checked the marginal claim directly — power gained per Aether
spent on the NEXT level, for Rare vs. Common, is `1.25/1.60 = 0.78×`:
leveling itself really is a worse deal for Rare, confirming "the rarer
something is, the more expensive it is to upgrade" holds on the
investment axis specifically, even though total power (head start
included) doesn't converge to parity — which it should not, since
Ian's own first request was that Rare units be "genuinely stronger."
No retune applied; concluded validated rather than forced a numeric
change without playtest signal, per the plan's own "if" framing.

**Verified**: `node farroadsmoke.js` — 194/194 (15 new checks, one
section): every `ACTIONS`/`ROSTER`/`ARCH` entry has a valid rarity,
defaulting correctly on a blank column; the roster-expansion five are
Rare and the original five Common; `reckoning`/`hollowtoll` are
Legendary and the rest of the drop pool Rare; `bonusPrice`/`bonusSpend`
agree on a rarity-adjusted total for both the triangular and flat-Broad
pricing branches (this is what caught the rounding-drift bug above);
`RARITY_COST_MUL` confirmed steeper than `RARITY_POWER_MUL` at every
tier; `P.weightedRosterPick` sampled 2000 times lands within 5% of its
closed-form Common share; the nested Legendary-charge roll sampled 5000
times lands within 3% of `MC_LEGENDARY_CHARGE_CHANCE`. Live browser
pass: MC creation's 3 starter charges confirmed showing no badge
(Common); after spending the character-creation stat pool and starting
a run, GAMBITS/AETHER tabs confirmed rendering Strike/Ember and the
player unit with no badge and no console errors; the in-page SMOKE TEST
(drive-the-real-UI button, distinct from `farroadsmoke.js`) ran 120
waves of `doStep()` and reported PASS; the `.rtag` pill's computed
background/text color confirmed resolving to readable, distinct blue
(Rare) and gold (Legendary) against the panel background. Not exercised
live: an actual Rare/Legendary pull or MC charge-drop, since both are
gated behind wave 20+ (curated run) and this session's browser sandbox
disables `localStorage` (blocks injecting a save to skip ahead) —
covered instead by the headless weighted-pick/nested-roll sampling
above, disclosed rather than claimed as fully verified.

## Elemental action grid — one atk + one mag action per element

Ian: "let's create new actions for each combination of atk and magic
with each affinity. split them up so in total each affinity is
represented evenly among the rarities." Scoped to the 6 combat
elements (Fire/Water/Earth/Air/Light/Dark) — Body and Spirit are
mitigation/healing stats that already apply to every physical/healing
action automatically (`affTerm`/`affBoost`, `farroad-core.js`), not
something a single action can carry the way `element` works; there was
nothing to "combine" atk/mag with for those two. Asked one clarifying
question on what "evenly" meant, since it has genuinely different
readings that produce different content — Ian picked: for each
element, its atk version and its mag version land in DIFFERENT rarity
tiers, so no tier reads as "the fire tier" and no element clusters in
one place.

**Coverage gap this fills**: before this, every `element` tag lived on
`MAG_CAMP` only, and unevenly — Fire had 2 (Ember, Sear), Dark had 2
(Hex, Siphon), Water/Air/Light had 1 each, Earth had 0. `ATK_CAMP` had
zero elemental actions at all. 12 new `equippable`-kind actions
(`farroadactions.csv`) close the gap completely: `cinderstrike`/
`firebrand` (Fire), `riptideblow`/`tidalsurge` (Water), `stoneshatter`/
`quakebolt` (Earth), `squallstrike`/`zephyrbolt` (Air), `radiantblow`/
`solarflare` (Light), `shadowrend`/`umbralbolt` (Dark) — atk name
first, mag name second in each pair. Added to `ATK_CAMP`/`MAG_CAMP`
(`farroad-core.js`), the hardcoded id lists `C.EQUIPPABLE` is built
from (CSV `camp` alone doesn't drive pool membership — the two have to
be kept in sync by hand, same as every existing equippable).

**Design, not new mechanics**: each action is plain elemental damage,
same shape as Ember (mag, no status) rather than Sear/Hex/Smother/
Dazzle (mag, carries a status) — the element tag itself is the
differentiator (it interacts with the target's/caster's affinity via
`affTerm`), so no new status-effect design was needed or asked for.
Base power is the existing camp baseline — Strike's 1.00 for atk,
Ember's 1.05 for mag — multiplied by that specific action's own
assigned tier's `RARITY_POWER_MUL` and rounded, the exact pattern
already established for every other rarity-promoted action last
session. Rank/initiative/charge_gain stay flat at Strike's/Ember's own
values regardless of tier, also matching precedent (only power/
defPierce/critBonus scale with rarity, never action speed).

**Rarity split** (round-robin over the 6 elements, tiers cycling
common→rare→legendary, mag offset by one tier from its element's own
atk so the two never land together):

| Element | atk tier | mag tier |
|---|---|---|
| Fire | Common | Rare |
| Water | Rare | Legendary |
| Earth | Legendary | Common |
| Air | Common | Rare |
| Light | Rare | Legendary |
| Dark | Legendary | Common |

4 actions land in each tier, each tier covering 4 different elements —
no tier is "the X tier," and every element is split across two of the
three tiers rather than concentrated in one.

**First non-Common equippables — acquisition needed rarity-weighting
for the first time**: every equippable action before this was Common,
so `C.EQUIPPABLE`'s two random-draw sites — `randomDrop()`'s wave-
parity action drop and `doPull()`'s Marks-pull action branch
(`farroad-ui.js`) — picked uniformly with no rarity to weight against.
Introducing real Rare/Legendary equippables into that same uniform
pool would have handed them out exactly as often as Strike, quietly
defeating the entire point of the tier. New `P.weightedActionPick(rng,
ids)` (`farroad-progression.js`), mirroring `P.weightedRosterPick`'s
exact shape and reusing the same `P.RARITY_PULL_WEIGHT` table (common
weighted 3x over rare/legendary) — both draw sites now call it instead
of `pool[G.rng.nextInt(pool.length)]`.

**Verified**: `node farroadsmoke.js` — 203/203 (9 new checks, one
section): every element has its designated atk action in `ATK_CAMP`
and mag action in `MAG_CAMP` with the right `element` field; all 12
are `equippable` kind, not `charge`; no element has both its atk and
mag action in the same rarity tier; the 12 split exactly 4/4/4 across
the three tiers; every action's `power` equals its camp baseline times
its own `RARITY_POWER_MUL`, exactly; all 12 ids appear in
`C.EQUIPPABLE` exactly once with no duplicates introduced; `P.
weightedActionPick` sampled 2000 times over a controlled 2-common/2-
rare pool lands within 5% of the closed-form expected Common share.
Live browser pass: game boots and runs a full curated sequence (the
in-page SMOKE TEST button) with zero console errors after the
`ATK_CAMP`/`MAG_CAMP`/`C.EQUIPPABLE` changes; each of the 12 new
actions' compiled `camp`/`element`/`rarity`/`power` fields confirmed
correct by reading `window.FarroadCore.ACTIONS` directly in the live
page. Not exercised live: an actual random drop or pull landing one of
these 12 specifically, since that requires reaching wave 20+ or a
random-drop roll landing on one of only 12 ids among ~35 equippables —
not practical to force in this session's `localStorage`-disabled
sandbox (same disclosed gap as the Rarity system above); the rendering
path itself (`describeAction`/`actionGlyph`/`rarityTag`) is unchanged,
pre-existing code already verified live last session for arbitrary
action/element/rarity combinations, so it was not re-verified visually
here — only the new content's compiled data was.

## Equipment — head/body/legs/2 hands, new farroadequipment.csv

Ian: "I want each unit to be able to equip one head, one body, one
legs, and two hand equipments (left and right). these can affect
everything but health. have legs primarily affect speed and evasion,
body and head defense, resistance, and affinities, and hands attack,
magic, and affinities. have non leg equipment marginally reduce speed,
based on how good it is. they will also have varying rarities. they
should be added as random drops to waves and pulls, about as rare as
units. we'll need a new csv for easy editing as well." Followed
mid-turn by: "You can have duplicate equipment." This is the
"equipment later" item the Rarity plan explicitly flagged as future
scope (`farroadgdd.md`'s own "specified, never built" note) — nothing
equipment-shaped existed before this; every prior "equip" hit in the
codebase was combat ACTIONS in loadout slots, an unrelated concept.

Sized as a real feature, not a quick add — three Explore passes (stat-
assembly pipeline, save/UI structure, drop/pull mechanics) plus a Plan
review before writing any code. The review caught a real, otherwise-
silent bug before it shipped: `grantDrops()` (`farroad-ui.js`) is a
separate dispatcher from `randomDrop()` with an if/elseif chain ending
in a bare `else` that treats anything unrecognized as a gambit
condition — an equipment drop without its own branch would have
silently miscounted as a condition, wrong array, wrong notice, wrong
everything. Fixed before it was ever live.

**Data model**: new `farroadequipment.csv` — `id,name,slot,rarity,atk,
mag,def,res,spd,evade,affinity_fire...affinity_spirit,design_note`.
`slot` is one of 4 item KINDS (`head/body/legs/hand`); a unit wears 5
POSITIONS (`EQUIPMENT_SLOTS` in `farroad-core.js` —
`head/body/legs/hand1/hand2`), a `hand` item fitting either hand
position. That kind-vs-position split is exactly why duplicate
ownership matters: dual-wielding the same hand item, or putting the
same body armor on two different units, needs 2 owned copies — hence
Ian's own clarification, taken literally rather than treated as a
throwaway remark. `compileEquipment(rows)` (`content-pipeline.js`)
reuses `compileAffinity`/`compileRarity` verbatim, no new parsing
code. Stat columns are scoped by slot and enforced at build time
(legs: spd/evade only, no affinity by design; head/body: def/res+one
affinity axis; hand: atk/mag+one affinity axis) — same fail-loudly
validation style as the existing element/rarity checks, catching a
stray value in the wrong column as a content error rather than a
silent no-op.

Equipment affects exactly atk/mag/def/res/spd/evade and the 8 affinity
axes — not atkCrit/magCrit/chargeRate (never mentioned in Ian's own
per-slot breakdown) and not HP (explicit). Values are hand-authored,
already tier-scaled by `RARITY_POWER_MUL` at authoring time, same as
every other rarity-promoted number this project has shipped — not
computed at runtime from a smaller base. The one number that IS
computed at runtime: the marginal speed penalty. `EQUIP_SPD_PENALTY_
BASE=1.5` (`farroad-core.js`) × that item's own `RARITY_POWER_MUL`,
summed once across every equipped NON-leg slot (head/body/hand1/
hand2 — legs are the speed slot, exempt) and rounded ONCE at the end
rather than per-item, so it stays proportionate instead of compounding
rounding error. Verified live (see below): a fully-Common loadout nets
to exactly 0 net speed change; a fully-Legendary loadout also nets to
~0 — genuinely marginal at every tier, not a real tax, exactly as
asked.

**12 initial items** = 4 slot kinds × 3 rarities, one per cell —
Traveler's Boots/Windstep Greaves/Skybound Sabatons (legs); Iron Cap/
Warded Helm/Crown of the Bulwark (head); Padded Vest/Chainweave Mail/
Aegis of the Deep (body); Worn Gauntlet/Runed Bracer/Emberfist (hand).
Every item in a slot family grants its FULL family stat set (no
per-item subset-rolling — simplest maintainable shape); each head/
body/hand item also carries one affinity axis, cycled fire→water→
earth→air→light→dark→body→spirit across the 9 non-leg items (wrapping
once, Emberfist landing back on Fire).

**Acquisition — "about as rare as units"**: both existing "rare
special content" gates already used the figure `0.10`
(`P.PULL_ODDS.unit`, `P.MC_CHARGE_DROP_CHANCE`) — equipment reuses
that exact figure rather than inventing a new one. `P.PULL_ODDS`
(`farroad-ui.js`) extended from `{unit:.10,action:.45,cond:.45}` to
`{unit:.10,equip:.10,action:.40,cond:.40}`; a new `P.EQUIP_DROP_
CHANCE=0.10` gate in `randomDrop()`, checked WITHOUT the `G.mc` guard
the charge-action gate uses — equipment drops for every run,
companion-only included, same as the ordinary action/condition drop
it replaces when it fires. New `P.weightedEquipmentPick(rng,ids)`
(`farroad-progression.js`) mirrors `P.weightedActionPick` exactly,
reusing the existing `P.RARITY_PULL_WEIGHT` table. Equipment
duplicates are NEVER converted to Lore the way action/condition dupes
are — a dupe always increments the shared `G.equipInv` count and
always gets its own drop notice ("NEW EQUIPMENT" vs. "EQUIPMENT
(DUPLICATE)"), since owning more copies is the entire point.

**Save format**: `G.equipInv` (`{itemId:countOwned}` — the count
itself IS the ownership signal, no separate unlock-boolean, unlike
actions/conditions) and `G.equipped` (`{uid:{head,body,legs,hand1,
hand2}}`). Added to `FIELDS`/`newGame()`/`deserialize()`/
`joinCompanion()` following the `statInvest`/`affinities` precedent
exactly — brand-new fields, plain default-fill, no legacy shape.

**Stat integration**: `effectiveAffinity(uid)` (`farroad-ui.js`)
extended from baseline+purchased to baseline+purchased+equipment (one
new `equipmentAffinity(uid)` term inside the existing single choke
point every assembly site already calls, rather than touching each
site separately). New `applyEquipmentStats(uid,st)` mirrors
`applyPctStatInvestment`'s exact shape and placement — called
immediately after it at all 3 real assembly sites (`buildParty`,
`buildExpeditionParty`, `refreshLiveStats`), mutating `st.atk/mag/def/
res/spd/evade` before `C.makeUnit` (or the direct `u.base` copy-back
in `refreshLiveStats`) reads it. `equipOwnedCount`/`equipInUseCount`/
`equipAvailableCount` derive availability by scanning `G.equipped`
live rather than tracking a separate counter — small data, no
precedent for anything fancier here. `equipItem(uid,slot,itemId)`
validates the item's own `slot` kind matches the position (`hand1`/
`hand2` both accept kind `hand` via `equipKindForSlot`) and that a
copy is actually available (or it's already this exact slot's
occupant — a no-op swap); `unequipItem` just clears it.

**UI**: new EQUIPMENT tab (`shell.html` button+panel,
`farroad-ui.js`'s hardcoded tab-visibility array, `renderEquipment()`
called from `renderEconomy()`). Modeled on GAMBITS' loadout `<select>`
editor, not AETHER's "buy an upgrade node" rows — equip-slot
assignment is "pick one of a shared, contention-limited pool per
slot," the exact problem GAMBITS already solved for actions (disabling
an option when something else holds it), just gated on OWNED COUNT
instead of fielded-unit identity. 5 `<select>` rows per unit (Head/
Body/Legs/Hand (left)/Hand (right)), each option labeled with owned/
available counts and the existing `rarityTagText()` badge — no new CSS
needed. `onchange` calls `equipItem`/`unequipItem` then
`refreshLiveStats();renderAll();`, identical to every existing
affinity/pct-stat buy handler.

**Verified**: `node farroadsmoke.js` — 214/214 (11 new checks): all 12
items compiled with correct slot/rarity/stat-family shape (content-
pipeline.js's own build-time validation catches a scoping mistake
before this even runs); exactly one item per (slot,rarity) cell; every
item's numbers equal the Common baseline × its own `RARITY_POWER_MUL`
exactly; `P.EQUIP_DROP_CHANCE`/`P.weightedEquipmentPick` correct,
sampled 2000 times landing within 5% of the closed-form Common share;
a save round-trip preserves `G.equipInv`/`G.equipped` exactly, and an
old save missing both fields entirely default-fills without throwing.
The UI-layer stat math itself (`applyEquipmentStats`/`equipItem`/
`effectiveAffinity`'s equipment term) lives in `farroad-ui.js`, which
the headless harness doesn't load (DOM-dependent, same reason `P.
PULL_ODDS`/`doPull` aren't smoke-tested either) — verified instead via
a temporary debug hook in a live browser session (added, exercised,
then fully removed before this shipped): equipping Iron Cap/Padded
Vest/Worn Gauntlet ×2/Traveler's Boots on Kesh produced an exact
+10/+10/+8/+8/+0 atk/mag/def/res/spd delta against the unequipped
baseline (matching the authored numbers precisely, and confirming the
Common-tier speed penalty nets to exactly 0 as designed); a fully-
Legendary loadout also netted to 0 speed; `effectiveAffinity` summed
Fire+3/Air+3/Body+6 exactly as equipped; attempting to equip an
unowned item, a wrong-slot-kind item, or a 3rd copy of a 2-owned item
all correctly failed and left state untouched; unequipping via an
actual `<select>` change event (not just a direct function call)
correctly freed the item back to available; the live battle view's
displayed ATK/MAG/DEF/RES (35/35/40/35 from a 19/19/28/23 baseline)
matched the equipped bonuses exactly, confirming the full pipeline
from equip state through to the actual combat unit; no console errors
throughout. Not exercised live: an actual wave/pull equipment drop
landing in the notice queue, since real drops need wave 20+ (post-
curated) and this session's browser sandbox disables `localStorage`
(blocks injecting a save to skip ahead) — the acquisition CODE PATHS
were read-reviewed line-by-line against the actual `pushDrop`/
`grantDrops` shapes rather than left unverified, but the notice text
itself wasn't seen rendered.

## Equipment expansion — 3 more Common, 2 more Rare, 1 more Legendary per slot

Ian: "Can you build out variations of 3 more common equipment for each
type, 2 rare for each type, and 1 more legendary for each type?" — 6
more items per slot × 4 slots = 24 new, on top of the 12 shipped
above, landing on 4 Common / 3 Rare / 2 Legendary per slot (36 total).

**"Variations", not reskins** — each new item is a genuinely different
stat SPLIT within its slot's existing family, on the SAME total budget
as the original item, not just a new name on the same numbers. Every
family now has named archetypes:
- **Legs** (spd/evade, budget ~12 "feel" either way): Balanced
  (original — Traveler's Boots/Windstep Greaves/Skybound Sabatons,
  spd 6/evade .020 common baseline), Swift (spd-leaning, spd 9/evade
  .010 — Racer's Striders/Windrunner Striders/Tempest Striders, full
  3-tier spread), Evasive (evade-leaning, spd 3/evade .032 — Nimble
  Slippers/Phantom Slippers, Common+Rare only), and a 4th Common-only
  in-betweener (Worn Sandals, spd 8/evade .015).
- **Head/Body** (def+res, budget 8): Balanced (original), Bulwark
  (def-heavy, 6/2), Warded (res-heavy, 2/6), each getting the same
  3-tier spread as Legs' Swift/Evasive; a 4th Common-only in-betweener
  each (Shadowed Hood def 5/res 3 for Head, Rootplate Jerkin same
  split for Body).
- **Hand** (atk+mag, budget 10): Balanced (original), Brawler
  (atk-heavy, 8/2), Arcane (mag-heavy, 2/8), same shape; 4th
  Common-only in-betweener (Zephyr Grips, atk 6/mag 4).

Every new item still carries one affinity axis (head/body/hand) per
the original design, cycling through whichever of the 8 axes its slot
hadn't used yet — Head's new 6 cover Air/Light/Dark/Body/Spirit/Air
(wrapping), Body's cover Fire/Water/Earth/Body/Spirit/Fire, Hand's
cover Water/Earth/Air/Light/Dark/Water. Legs still carries no affinity
at any tier, unchanged from the original design. All values are still
hand-authored archetype-baseline × `RARITY_POWER_MUL`, same as every
other rarity-promoted number in this project — no new scaling
mechanism, no new mechanics, purely more content on the existing rails
(acquisition odds, drop/pull weighting, the EQUIPMENT tab UI, and the
UI-layer stat math are all completely untouched by this pass).

**Not every archetype reaches every tier on purpose** — Evasive/Arcane/
Warded (the "off-balance" archetype in each family) stop at Rare, and
each family's 4th Common-only in-betweener never gets a Rare/Legendary
version at all. This wasn't asked for symmetrically and inventing 3
full tiers for every archetype would have meant 12 items per slot (48
total) instead of the 9 actually requested (4+3+2) — the asymmetry is
deliberate scope discipline, not an oversight, and easy to extend
later if a specific archetype earns a higher tier.

**Verified**: `node build.js` (36 items compile clean, zero validation
problems) and `node farroadsmoke.js` — 214/214, with the equipment
section's 3 count/baseline checks rewritten for the new shape: exactly
4/3/2 items per slot per rarity (was "exactly 1 per cell"); every
item's stat/affinity values reconstructed against its OWN archetype's
pre-rarity baseline × `RARITY_POWER_MUL` (was a single shared baseline
per slot, no longer true now that a slot has 3-4 different archetypes
in play). Live browser pass: EQUIPMENT tab's Head slot dropdown
confirmed listing all 9 Head items (4 Common/3 Rare/2 Legendary) with
correct names and rarity tags; no console errors. Not re-verified: the
stat-math/duplicate-ownership/speed-penalty mechanics themselves,
since those are unchanged code paths already verified live in the
Equipment section above — this pass only added data.

## LORE regrouped by unit — equipped row + unequipped dropdown

Ian: "I need a better way to organize actions on the lore tab.
scrolling through them is unwieldy. what if we had buttons for each
unit which drop-down you show their equipped actions and a drop-down
for all unequipped actions." The v2.9 per-action tab row (one button
per action the player has ever unlocked, active ones sorted first) was
fine at a handful of actions but became a long wrapped block once
drops turn random past wave 20 and duplicates start piling up Lore.

**Reused the shared unit-tab row rather than inventing a new one** —
`renderUnitTabs` (the same `selectedUnitTab` AETHER/GAMBITS/EQUIPMENT
already read/write) now drives LORE too, so picking a unit anywhere
in the app keeps LORE in sync rather than adding a fifth independent
"which unit am I looking at" concept. New `unitActiveActions(uid)`
(`farroad-ui.js`, beside `actionHolders` — the inverse question: given
a unit, not an action) returns that unit's deduped loadout-slot action
ids plus its live charge action, reusing the exact `mcOwns ?
G.mc.chargeAction : def.chargeAction` resolution GAMBITS' own loadout
render already has, rather than re-deriving it a third time.

**Two buckets, matching what LORE spend already cares about**: a short
row of the selected unit's 2-3 actively-equipped actions (reusing the
old tab-button visual exactly — icon, name, rarity badge, level), and
one `<select>` below it listing every action nobody currently has
equipped (icon/name/rarity/level as option text, same as GAMBITS'
action selects). The ★-marked "active" flag that used to live on every
button is gone — which BUCKET an action is in now says that
structurally, so a separate marker was redundant. `renderActionTabs`
(the old flat-row renderer, LORE's only caller) is deleted rather than
kept dead.

**Kept the currently-open action honest across renders**, not just on
a tab click: if the action shown in the detail panel belongs to some
OTHER unit than the one just selected (switching from a different tab
elsewhere, or LORE's very first render this session), it snaps to the
newly-selected unit's own first equipped action instead of leaving the
equipped-row looking unselected while the panel below shows someone
else's action — verified live to correctly NOT snap when the shown
action is also equipped by the newly-selected unit (e.g. Strike, used
by both a fresh MC and Dorrek), only snapping when there's truly no
overlap.

**Verified**: `node build.js` + `node farroadsmoke.js` (214/214, no
regressions — this pass touched only rendering, no touched formula/
data). Live browser pass (a temporary debug hook, added and fully
removed before shipping, seeded a 3-unit party with overlapping and
non-overlapping loadouts and 50 Lore): confirmed the equipped row
shows exactly a unit's own 2-3 actions with correct dedup (Dorrek's
`[strike,strike]` loadout collapsed to one Strike button, not two);
confirmed the unequipped dropdown excludes anything any unit currently
holds and updates live as loadouts change (emptying Kesh's loadout
moved Pierce from the equipped row into the dropdown on the next
render); confirmed switching to Ansa (no action overlap with the
previously-viewed Strike) auto-snapped the detail panel to her own
Mend, while switching to Dorrek (who also uses Strike) correctly left
the panel showing Strike unchanged; confirmed selecting an unequipped
action from the dropdown and buying a Lore upgrade on it worked
end-to-end (Sear → Lv1, Lore 50→49, refund button appeared); no
console errors throughout.

## LORE refund button repositioned; a Field-time conflict pop-up; themed dungeons

Three requests in one message.

**1. "we lost the button to refund all unequipped actions."** Not
actually deleted — the LORE regroup above moved it, and it ended up
buried past the new equipped-row/dropdown, near the Lore-total line,
disconnected from the list it acts on. Moved it to sit directly under
the "Unequipped actions" `<select>` instead — it now visually belongs
to the exact list it bulk-refunds, which is also just better UX than
where it lived before the regroup, not merely restored.

**2. Field-time action-conflict pop-up, replacing the passive per-slot
notice.** Ian: "rather than have a notice that an action is equipped
by another unit on the action, have there be a pop-up if you try to
put two units in the party with the same actions noting which actions
need changed, and letting the player change it in the pop-up." GAMBITS'
loadout `<select>` already disabled a conflicting option and (until
now) showed a passive "also equipped by X from before this rule"
paragraph if you happened to open that unit's own slot editor — but
nothing stopped FIELDING a unit whose saved loadout collided with one
already in the party (a `G.touched` unit's manual loadout is never
touched by `autoEquip()`'s "never override a hand-written rule"), and
nothing surfaced it until noticed.

- New `renderFieldConflicts(uid)` (`farroad-ui.js`, beside
  `actionHolderInParty`/`benchedActionHolder`) scans the just-fielded
  unit's loadout for slots where `actionHolderInParty(action,uid)`
  finds another fielded holder, and — only if any exist — opens a
  small blocking modal listing each conflicting slot with a `<select>`
  to pick a different action right there (options disabled the same
  way GAMBITS' own select already disables them), or a "Field anyway,
  fix later" dismiss. Picking a replacement re-scans immediately;
  resolving the last conflict auto-closes the modal.
- This is **the one deliberate exception** to this project's own
  "no blocking modals" rule (`shell.html`'s existing comment on the
  drop-notice banner: "an idle game cannot afford a modal that halts
  progress every few waves") — it only ever opens in direct response
  to a Field click, never on the game's own clock, so it doesn't fight
  the reason that rule exists.
- The retired passive notice is gone from GAMBITS' own slot render;
  the SELECT's own option-disabling (prevention, stops a manual edit
  from CREATING a new conflict) is untouched — a different job from
  the retired notice (after-the-fact disclosure of one that already
  existed), now superseded by the pop-up catching it at the moment of
  creation instead.
- New markup: `#conflictModal`/`#conflictModalBody` (`shell.html`,
  right after `#app` closes) — a fixed-position overlay, `z-index:50`,
  the first of its kind in this codebase.

**3. Themed dungeons — one affinity axis per direction.** Ian: "let's
make them themed, so each direction has a themed affinity... west
dungeons... fire themed while the ones to the east are Spirit themed."
8 directions, 8 affinity axes — a clean 1:1 mapping, walking the same
canonical fire/water/earth/air/light/dark/body/spirit order every
other CSV in this project already uses, landing exactly on Ian's two
named examples (west→Fire, east→Spirit) with no separate ordering
decision needed for the other six.

- New `affinity` column on `farroaddungeons.csv`, compiled into
  `DIRECTION_CONFIG[dir].affinity` (`content-pipeline.js`), validated
  the same fail-loudly way as element/rarity elsewhere (an
  unrecognized axis stops the build, not a silent blank).
- New `P.DIRECTION_AFFINITY_BONUS=6` (`farroad-progression.js`) — a
  flat additive bonus applied ON TOP of an enemy's own archetype-
  authored affinity, never replacing it. Reasoned starting point, same
  order of magnitude as a single equipment piece's own affinity bonus
  (3-5 raw points) — flagged tunable like every other rarity/theme
  number this project has shipped.
- New `applyDirectionAffinity(enemies,dir)` (`farroad-ui.js`), a
  sibling to the existing `applyStatMul` (same shape, same 4 call
  sites: `resolveExpedition`'s regular node, `rollExpeditionDiscovery`'s
  bonus fight, and `unlockDirectionDungeon`'s two waves-list builds) —
  deliberately NOT wired into the main Road (`buildEnemies` called with
  no direction) or companion quests, since theming is a directional-
  content thing, not game-wide.
- **Real pre-existing bug caught and fixed before it could ship
  silently broken**: `bakeEnemySnapshot`/`unitsFromSnapshots` (the
  freeze/replay pair every dungeon and companion-quest stage already
  uses) never carried `affinity` at all — only `stats`. Without a fix,
  every dungeon's frozen enemies would have LOST their themed bonus
  (and, incidentally, their own archetype's ordinary affinity too) the
  moment they were baked, silently reconstructing at `defaultAffinity()`
  0 on every replay. Both functions now carry `affinity` through the
  round trip — a strict correctness fix for quest-stage snapshots too,
  not just new theming behavior. An old save's already-baked dungeons
  (from before this fix) degrade gracefully to 0 via `makeUnit`'s
  existing `cfg.affinity||{}` guard — no migration needed, no throw.

**Verified**: `node build.js` + `node farroadsmoke.js` (218/218, 4 new
checks: west=Fire/east=Spirit exactly, every direction's axis is one
of the 8 known ones, the 8 directions walk the canonical axis order
with none repeated, `DIRECTION_AFFINITY_BONUS` is a real positive
number). Live browser pass (temporary debug hooks, added and fully
removed before shipping): confirmed the refund button now sits under
the unequipped dropdown and still round-trips a real refund correctly;
confirmed the conflict pop-up opens exactly when fielding a unit whose
loadout collides with an already-fielded one, correctly lists the
right slot/holder, resolves and auto-closes when a non-conflicting
replacement is picked, and "Field anyway" dismisses without changing
state; confirmed `applyDirectionAffinity` adds the bonus additively
without disturbing an enemy's other axes (spot-checked west→+6 Fire,
east→+6 Spirit on the same base enemy); confirmed the bake→snapshot→
restore round trip preserves the themed affinity exactly; confirmed a
REAL dungeon built via `unlockDirectionDungeon('west',1)` carries
Fire+6 on every enemy in both a regular wave and the boss wave; entered
that dungeon through the actual QUESTS tab UI and confirmed the fight
started and resolved a real combat turn with no console errors
throughout.

## Shared-action rule promoted from UI warning to a real combat restriction

Ian asked for the field-conflict pop-up above to note that leaving a
conflict unfixed means the action won't trigger. It didn't, yet — the
one-unit-per-non-starter-action rule (`One-unit-per-non-starter-action
rule` above) was UI-layer only by original design, purely a Lore-
sharing-exploit guard with `farroad-core.js`'s combat resolver having
no idea the rule existed; two fielded units sharing a non-starter
action both fired it normally in a real fight. Flagged this discrepancy
before writing an inaccurate note — Ian chose to make it literally
true rather than soften the wording.

**New `actionHeldByEarlierFielded(b,u,actionId)`** (`farroad-core.js`,
beside `needsHeal`) — the engine's own version of `actionHolderInParty`,
scanning `b.units` instead of `G.party`/`G.loadout` (core.js can't read
UI-layer state). A naive "does any OTHER fielded unit hold this"
symmetric check would deadlock two units that already share an action —
neither could ever use it, each seeing the other as the blocker. Broken
by `slotIndex` (a unit's position in `G.party`, set at `buildParty`
time): only a unit with a LOWER slotIndex counts as a blocker, so
exactly one fielded holder — the earliest — keeps using the action
normally, and every other holder falls through. Starters (`strike`/
`ember`) stay exempt via a small `STARTER_ACTIONS` list duplicated from
`P.STARTER_ACTIONS` — core.js loads before progression.js, same
load-order reason `RARITY_POWER_MUL` lives in core despite reading like
an economy concern.

**Wired into `chooseFrom`** at both points a slot's action gets
selected: the `allNone` round-robin branch (falls back to Strike, same
shape as the existing `smartHeal` skip-checks right above it) and the
main condition-matching loop (a blocked slot is skipped exactly like a
failed condition, `continue`s to the next one). The final "all
conditions false" fallback was already Strike, so a fully-blocked
unit's worst case was already handled by existing code.

**Popup text updated** (`renderFieldConflicts`, `farroad-ui.js`) to
state the real consequence plainly — "will skip that slot in battle
rather than fire a copy of an action someone else already fields" —
and the dismiss button now reads "Field anyway (conflicting slots
won't fire)" instead of the vaguer "fix later".

**Verified**: `node build.js` + `node farroadsmoke.js` (222/222, 4 new
checks in a dedicated section: a lower-slotIndex party unit fires a
shared non-starter action normally; a higher-slotIndex unit sharing the
same id never fires it across many turns; that unit correctly falls
back to Strike rather than going idle; both units sharing Strike itself
remain completely unrestricted). Live browser pass (a temporary debug
hook, added and fully removed before shipping): confirmed the pop-up's
new wording renders correctly; built a REAL 2-unit battle via
`C.makeBattle`/`C.step` with Kesh (earlier) and Ansa (later) both
loadout-assigned Pierce — the combat log showed Kesh firing Pierce
every cycle and Ansa's identical slot firing Strike every single time
instead, tagged `via: alternate (shared with an earlier-fielded unit)`,
while her OTHER (non-conflicting) slot fired normally; confirmed
Strike itself stays fully shared between both units with zero blocking;
no console errors throughout.
