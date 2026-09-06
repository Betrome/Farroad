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
