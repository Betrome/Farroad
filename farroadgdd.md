# FARROAD — Game Design Document v1.0

> ## §0.2 — FEATURE ROADMAP (recorded, not built)
>
> Ian's intended direction. Nothing here is implemented. It is recorded because
> several items have architectural consequences that should shape decisions made
> now, while they are still cheap.
>
> ### Fits the current architecture (client-side, single file)
>
> **1. Customisable first unit** — the player chooses starting stats, growth
> curve, name and charge action for their main character.
> *Implication:* unit definitions must be fully data-driven. Kesh stops being a
> hardcoded roster entry and becomes a template instantiated from player choices.
> `ROSTER` is already a plain data array, so this is mostly a matter of moving
> instantiation behind a factory — but the 20 unwritten companions should be
> authored as data from the start rather than as literals.
>
> **2. Swappable charge actions — MC only** — change your charge action when you
> acquire a new one. This applies **only to the Main Character** (item 1's
> customisable first unit); every other unit stays locked to its own charge
> action, as today.
> *Implication:* charge actions decouple from unit identity **for the MC alone**.
> The MC needs its own pool of unlockable/acquirable charge actions to swap
> between — a list distinct from the fixed one-action-per-unit model the rest of
> the roster keeps. `chargeAction` remains a fixed field on non-MC roster
> definitions; only the MC's unit instance gains an equippable charge-action slot
> plus the acquired-actions list it draws from.
> Note this interacts with the v2.8 charge-cost rule: upgrades are bought against
> a specific charge action, so swapping must decide whether Lore follows the unit
> or the action. Recommend it follows the **action**, consistent with how every
> other Lore upgrade already works — this still applies since it's the MC's own
> Lore stacks per acquired action that are at stake.
>
> **3. Equipment, with Mettal as its currency** — specified in §0 economy, never
> built. A new item layer on units.
> *Implication:* a fourth stat source. The stat pipeline is currently
> `base → level → status`; equipment inserts between level and status. Mettal has
> had no source and no sink since it was specified, which is why it is hidden.
>
> **4. Idle quests for benched units** — unused units go on automated party quests
> earning currencies, actions, gambits and equipment.
> ***This is the architecturally significant one.*** It requires running combat
> **headlessly, away from the main loop, potentially many times per tick**. That
> is exactly why the module split was drawn where it was: `farroad-core.js` and
> `farroad-progression.js` are verified DOM-free and the build fails if that ever
> stops being true. The smoke test already runs 200 headless fights as a batch to
> prove the shape works and to measure throughput, so quest resolution can be
> budgeted against a real number rather than guessed.
> It also solves a live design problem: benched units currently have no purpose
> and no reason to be levelled, which gets worse as the roster grows toward 25.
>
> **5. Dungeons, bosses and events** discovered through quests, attempted with the
> main party — a content/encounter system distinct from wave progression.
> *Implication:* `buildEnemies(wave)` currently derives everything from a single
> wave number. Encounters need to become authored data that the same combat core
> consumes, which is a natural extension rather than a rewrite.
>
> ### ⚠ ARCHITECTURAL FORK — items 6 and 7 are a different kind of project
>
> **6. Player versus player, with rewards.**
> **7. Late starters must not be permanently behind early players.**
>
> Items 1–5 are all client-side and fit a single HTML file. **These two do not.**
>
> - PvP requires **shared state between players**.
> - "Late starters aren't behind" is a **cross-player economy** problem — it only
>   has meaning relative to other players' progress, which a local file cannot see.
>
> Both imply **a backend and player accounts**: servers, authentication, stored
> state, an anti-cheat posture (a client-authoritative idle game is trivially
> edited), and ongoing running costs. That is a different kind of project from a
> single HTML file Ian opens from disk — different skills, different budget,
> different failure modes. **This fork should be seen clearly before it is
> invested in**, because it is the point where the project stops being something
> one person ships by copying a file around.
>
> **PvP IS ASYNCHRONOUS. This is the design, not a fallback.** (Confirmed by Ian —
> it was always the intent.) A match is fought against a *stored snapshot* of
> another player's party — their units, levels, equipped actions, gambit rules —
> not against a live opponent. No live connection, no matchmaking latency, no
> rollback netcode. A match is a row in a database and a fight either side can run
> whenever they like.
>
> The combat core is already seeded-deterministic, verified by the smoke test:
> same seed and same party snapshots give the same outcome. So a server stores
> `(seed, snapshotA, snapshotB)` and any client replays the identical fight for
> display. Results are verifiable, the payload is tiny, and the replay is a real
> fight rather than a recording. That property already exists — it was built for
> testing and happens to be exactly what async PvP needs.
>
> ### ⚑ THE SNAPSHOT FORMAT IS A SHARED DEPENDENCY — cheap now, expensive later
>
> Async PvP needs a **replayable match**: a serialisable party snapshot plus a
> seed, such that replaying the pair reproduces the match exactly. The seeded core
> already guarantees the *engine* half. The piece that can quietly rot is
> **snapshot completeness** — if any input to combat is not captured in the
> snapshot format, replay diverges, and it diverges silently and late.
>
> Everything combat reads must be in the snapshot: units and their base stats,
> levels, rows, equipped actions, gambit slot rules and their order, Lore bonus
> stacks per action (including charge-gauge cost, which upgrades now modify),
> charge action and current gauge, statuses, and eventually equipment. A snapshot
> that captures "the party" but omits, say, per-action Lore stacks will replay a
> *different fight* while looking correct.
>
> **Three roadmap items want this one format:**
>
> | need | why it wants the same thing |
> |---|---|
> | Async PvP (6) | replay a stored opponent party deterministically |
> | Save / load | persist and restore the player's own state |
> | Idle quests (4) | hand a benched party to the headless core, away from the main loop |
>
> So when **save/load is built — the next thing after the refactor — it should be
> designed as the general snapshot format, not as a save file that later needs
> widening.** Retrofitting completeness onto a shipped save format means migrating
> existing saves, which is the expensive version of this. Designing it once, now,
> as "everything combat needs to reproduce a fight" costs nothing extra and
> discharges all three.
>
> A cheap ongoing guard: the smoke test can assert that a fight run from live
> objects and the same fight run from a serialised-then-deserialised snapshot
> produce identical digests. That turns snapshot completeness into a build-time
> check rather than a bug discovered when someone's PvP replay disagrees with
> their result.
>
> ### Near-term gap: SAVE / LOAD
>
> Not on Ian's list, and it should be. An idle game needs **persisted state and a
> stored timestamp for offline progress** — the genre's core promise is that
> progress continues while you are away, and right now closing the tab loses
> everything. This should be the **first thing built after the refactor**, before
> any roadmap item. The module split leaves room for it: game state is a single
> plain object with no DOM handles, so a `farroad-save.js` between progression and
> UI can serialise it without either layer knowing.

> ## §0.1 — FIRST END-TO-END PLAY RESULT (v2.8 tuning)
>
> **Ian reached WAVE 51** with **two units at level 10** and **15% recovery**, playing gambits well.
>
> This is the first measured play result at the current tuning and it settles several
> open questions at once:
>
> - **The build is clearable.** Recovery starting at 0 had been shipped against an old
>   measurement (0% recovery → 0/20 clears) that predated the current enrage clock, the
>   Aether cuts and the v2.1 enemy curve. That measurement no longer holds: opting in to
>   15% recovery — reachable by about wave 4 at the 10-Aether first step — carries a run
>   to at least wave 51.
> - **The gambit system is carrying the run, not raw stats.** Two units at LV10 is a
>   *low* stat investment for wave 51; the enemy curve at w51 sits near S≈2.6. Reaching it
>   on gambit quality is the strongest evidence so far that the automation layer is the
>   real skill expression, which is the central design bet.
> - **Recovery is correctly priced as an opt-in.** 15% was enough. It did not need the
>   30% cap, so the purchase curve leaves genuine headroom rather than being a tax.
>
> **Caveat, stated plainly:** this is one run, not a clear *rate*. It establishes that the
> build is playable and roughly where it sits; it does not replace the per-wave clear-rate
> measurement, which remains unavailable while the shipped file cannot be executed
> (see the verification gap note in §10).

> ## §3.4 Crit, block and evade are FULLY SYMMETRIC — enemies can crit
>
> Previously undocumented, which was the real problem: enemy crits were landing and being tagged
> in the log, but nothing in the doc said they could. Confirmed from source — `resolveHit` contains
> **no `isParty` check anywhere**:
>
> ```js
> o.evadeChance=clamp(effEvade(tgt)+(has(src,'blinded')?.30:0),0,CAP_EVADE+.30);
> o.critChance =clamp((isPhys?src.base.atkCrit:src.base.magCrit)+(act.critBonus||0),0,CAP_CRIT);
> o.blockChance=clamp(effBlock(tgt),0,CAP_BLOCK);
> ```
>
> `src` is whoever attacks and `tgt` is whoever is hit, party or not. Enemy crit rates are real and
> per-archetype: Mire Hound **8%**, Stone Ox and Thorn Shrike 5%, Roadwolf 4%, Barrow Knight and
> Fen Priest 3%, plus 4% magic crit on all. The **only** `isParty` gates in the combat math are the
> three row modifiers, which are deliberate and documented in §2.
>
> **This is intentional and is being kept.** Enemy crit is the main thing making defensive stats
> worth anything — measured solo over waves 1–20:
>
> | Investment | enemy crit ON | enemy crit OFF |
> |---|---|---|
> | +35% DEF/RES | **+2.12%** | +0.26% |
> | +15pp block | **+2.12%** | +0.26% |
> | +35% HP (reference) | +5.84% | +4.17% |
>
> **Enemy crit makes DEF and block roughly 8× more valuable.** Defensive investment has been weak
> throughout this project, and removing enemy crit would take it to approximately zero. The
> variance objection is real but bounded: crit is ×1.75 rather than ×2.0 precisely so a spike
> cannot one-shot through a heal threshold, and the rates above are low. HP still outperforms
> every defensive stat, so defence is viable rather than dominant.
>
> ## §8.5 RECOVERY — a real stat, with a visible cap
>
> HP regained between waves. Base **15%**, improvable to a hard cap of **30%**. The cap is shown in
> the UI because the stat **saturates exactly there** — measured solo clear rate over waves 1–20:
> 0% → 0/20 · 5% → 12/20 · 10% → 16/20 · 15% → 17/20 · 25% → 17/20 · **30% → 20/20** · 35% and 40%
> → identical to 30%. Across its usable range it is one of the strongest stats in the game; above
> 30% it is worth precisely nothing, so the ceiling is surfaced rather than hidden.
>
> **This reverses the v0.9 finding and the reversal is the interesting part.** In v0.9, 25%, 50%
> and 100% recovery measured identical, because the wall then sat *inside* the first two-enemy
> fight at wave 15 and between-wave healing could not touch it. The v1.0 ramp gives one enemy
> through wave 20, which moves the binding constraint to pre-heal attrition — and recovery now
> governs it. **A stat's value is a property of where the wall is, not of the stat.**
>
> ## §9.4 Difficulty is native — the 65% multiplier is retired
>
> Intended difficulty is baked into enemy base stats and growth. **ATK growth exponent 1.02 → 0.80**
> (at 1.02, enemy damage grew 3.10× by wave 20 against a solo character's 2.05×), and per-archetype
> base ATK reduced ~4%. Enemy **HP was deliberately left alone** — scaling it measured almost inert,
> because what kills a solo character is damage taken, not pool size. The multiplier survives as a
> debug control at 1.00.
>
> **Wave order: Fen Priest and Mire Hound swapped.** Every bottom-decile run died at wave 7 to the
> Hound, which sat in the pre-heal window before Mend arrives at wave 8. Cutting its ATK changed
> nothing — it was its **speed** (SPD 124, many turns) against a character with no heal rule.
> Moving the Priest (ATK 12) into waves 5–7 took p10 from wave 7 to wave 20.
>
> **Verified at 100%, no crutch: 20/24 solo runs clear waves 1–20; the boss is beaten 91% of the
> time at 62 beats (1.6× a normal fight).**

---

# FARROAD — Game Design Document v0.9

> **v0.9 — progression, checkpoints, and a curated opening.** Paired build:
> `farroad-v0.9-progression.js` over `farroad-prototype-v0.8.html`.
> Full report: `VERIFICATION-v0.9.md`.
>
> **The number: gambit uplift over waves 1–20, solo, is 5.3 → 20.0 waves — +277%.** The largest
> gambit effect measured anywhere in the project, and the opposite of the "near zero at 1v1"
> concern. Focus-fire is worth 0% at one enemy, but focus-fire is a *targeting* gambit and
> targeting is meaningless against one foe. Survival gambits are worth everything.
>
> **But it is one lesson.** Every kit tested — starter, curated, three independent random draws —
> converges on the same rule: *heal when hurt*. Curated drops add **exactly zero** over the starter
> kit (20.0 vs 20.0 capped; 22.0 vs 22.0 uncapped). So does archetype variety (4.5 vs 7.1). So do
> five extra actions. **A solo character with two slots can express exactly one rule**, so every
> tool beyond that is inventory rather than a lesson until the second character arrives.
>
> **Root cause, and it is one cause rather than three: every gambit that pays is a survival
> gambit.** Mend (+277%) and Cripple (+8.3%) both work by cutting incoming damage — Slowed
> multiplies enemy turn cost by 1.50, so the enemy acts 33% less. Every damage gambit measures at
> or below zero: focus-fire 0%, Execute −2.1%, Pierce −5.8%. **Nothing in the game punishes a slow
> clear**, so damage improves a quantity that is never binding. Proved by adding an enrage clock
> (+7% enemy ATK per turn taken), under which Execute flips **−2.1% → +3.3%** and Cripple
> **+2.6% → +6.6%**. That mechanic is the prerequisite for offensive lessons to teach anything
> true; it is proposed for v1.0, not shipped here, because it needs its own rebalance.
>
> **Two self-inflicted defects found and fixed.** The v0.6 repricing set every action to DPT ≈ 1.00,
> which makes conditionals worthless *by construction* — swapping one DPT-1.00 action for another
> gains nothing. Niche actions must **lose outside their niche** (Pierce at pow 1.00 / pierce 0.75 /
> **rank 1.50**); widening it the obvious way made Pierce better than Strike against all six
> archetypes, at which point always-using it beat conditionally using it. Separately,
> **absolute-threshold conditions break under compounding stat scaling** — `foe DEF ≥ 25` is
> always-true by wave 15 — so all thresholds are now relative ("DEF > 1.4× yours").

---

## §0.3 — PROGRESSION (v0.9)

| Rule | Value |
|---|---|
| Idle rate | Keys off **farthest wave reached** (ratchet), never current wave |
| Boss cadence | Every **20 waves** |
| Boss length | **1.3–1.5×** a normal fight (per Q9: 28 s normals make a 2–3× boss drag) |
| Wipe | Returns to **just after the last boss cleared** — max loss 19 waves |
| Three-wipe rule | **Retired.** Checkpoints do the job without the bookkeeping or the sudden-death feel |
| Enemy-count ramp | **1 to w14, 2 to w22, 3 after** |
| Start state | **1 character, Strike + Ember**, `none` condition |
| Unit acquisition | Guaranteed post-boss drop (floor) + Marks gacha (accelerator) — §7.2 |

**The ramp was never the blocker.** Every candidate ramp — including one enemy for twenty straight
waves — produced an identical solo depth of ~4.6, because the constraint is enemy stat scaling
(1.06/wave compounding), not enemy count. **Solo requires ≈4% compounding stat growth per wave**,
which is now a hard requirement on the Aether curve: at g=1.04 the heal gambit is the difference
between failing and clearing (7.1 → 25.4), which is exactly where a tutorial should sit. At g=1.06
the game plays itself; at g=1.02 nothing saves you. With growth modelled the ramp *does* matter,
and the shipped ramp puts **9/10 solo characters at the wave-20 boss**.

### §0.4 — Curated onboarding (waves 1–20)

An action every 2 waves, a gambit condition between them; random drops thereafter. Teaching order
is **magic → buffs → healing → debuffs → AoE**.

| W | Drop | Gates / answers |
|---|---|---|
| 2 | **Sear** *(magic)* | Roadwolf. Load-bearing: raises reach-wave-8 from 3/10 to **10/10** |
| 3 | `foe lacks debuff` | gates Sear — "check before acting" |
| 4 | **Hex** *(magic)* | Frail cuts RES before the armoured foe arrives |
| 5 | `foe armoured` *(relative)* | Barrow Knight w5–6, DEF 34 |
| 6 | **Bulwark** *(buff)* | Warded ×0.60; holds p10 at wave 9 |
| 7 | `ally lacks buff` | gates Bulwark — don't overwrite a running buff |
| 8 | **Mend** *(healing)* | Stone Ox w9–10. The +277% lesson |
| 9 | `self HP ≤ 50%` | gates Mend, Bulwark — the highest-value rule in the game |
| 10 | **Cripple** *(debuff)* | Slowed = 33% fewer enemy turns |
| 11 | `foe faster than you` | gates Cripple |
| 12 | **Smother** *(debuff)* | Dulled cuts the Fen Priest's healing |
| 13 | `ally HP ≤ 60%` | gates Mend at party scale — ready for character 2 |
| 14 | **Daunt** *(debuff)* | Enfeebled ×0.75 ATK as the count rises |
| 15 | `foe lowest HP` | **2 enemies begin** — focus fire stops being degenerate |
| 16 | **Gale** *(AoE magic)* | magic AoE first: Shrike thorns punish *physical* AoE |
| 17 | `foe highest HP` | gates Gale, Daunt |
| 18 | **Cleave** *(AoE physical)* | once the player knows when not to use it |
| 19 | `foe HP ≥ 70%` | gates Cleave, Gale — AoE early, single-target once hurt |
| 20 | **Execute** | **BOSS** — ×2.90 below 30% |

**12 actions and 10 conditions at the boss. No dead drops** — every condition gates something
already held, verified programmatically by `validateCadence()`, which caught one (`foe HP ≤ 30%`
at w19 would have gated an Execute that arrives at w20; it moved to the post-boss random pool).

**Healing moved from last to third, on measurement.** Ian specified healing last, and the
insurance argument for guaranteed Mend does lapse during curation — there is no draw luck to
insure against. But **0 of 8 solo characters reach wave 19 on any non-healing build** (best is
Cripple at 11.13, against Mend's 20.75), and a between-wave rest doesn't help: 25%, 50% and 100%
restoration give identical results, because the wall is *inside* the first 2-enemy fight, not
between waves. Mend still leaves the starter kit — magic is present from wave 1 via Ember — and
arrives at wave 8, which preserves a genuine 6-wave window each for magic and buffs.

**Hand size at the boss is 12, and Ian's cadence lands on the number the v0.6 sweep identified —
but for the party that exists *after* the boss, not the solo player receiving it.** That sweep
measured +20% uplift at hand 10 with a *three-unit* party. Solo, a curated hand of 12 measures
identical to the 3-action starter kit, because two slots hold one rule. The staging is still
right: the player crosses the boss already holding a healthy hand.

---

> **v0.8 — the resource economy is named and canonical, and duplicate actions buy action bonuses.**
> Paired build: `farroad-prototype-v0.8.html`. Full report: `VERIFICATION-v0.8.md`.
>
> **The headline: the flat 9.0 naive line finally moved.** For seven versions a player who never
> opens the gambit screen scored exactly 9.0 regardless of collection size, ownership, levelling
> or repricing. Lore-funded bonuses move it to **9.25 at 18 drops and 9.43 at 25** — modest, but
> the first non-zero result in the project, because bonuses deliver *power applied to what is
> already equipped* rather than *expressiveness*, and expressiveness is worth nothing to a player
> who writes no rules.
>
> **It is not the levelling model in a new coat, and this was tested specifically.** Levelling
> gave power based on *which* duplicates you drew, so luck set the direction and compounded
> (spread 1.11 → 1.22). Lore gives power based on *how many*, and duplicate count converges hard:
> the standard deviation stays flat (~1.4) while the mean grows, so the coefficient of variation
> collapses **0.57 → 0.08** between 10 and 35 drops. The engaged player's luck spread is
> **unchanged at 1.67×** while depth rises. Power up, variance flat.
>
> **No bonus is an auto-buy.** `Lasting` is the strongest purchase on a build holding a status
> action (+16.7%) and worth **exactly zero** without one; `Swift` runs +9.2% → +19.1% depending on
> action cost and armour. `Weighty` (+12% power, no condition) was included as a deliberate
> control and is **never the best pick on any build**. Convergence *improved* — naive 0.86 → 0.72,
> skilled 0.63 → 0.51 — the opposite of the v0.7 currency option, which pushed it to 0.83.
>
> **The v0.7 duplicate conflict dissolved rather than being traded off.** Under the named economy
> Lore has two sources, and gambit duplicates supply the **majority (~54%)** while having no
> competing use — conditions were never per-unit, and the condition pool is smaller (17 vs 22) so
> it duplicates faster. Taking Lore *only* from gambit duplicates measures identically to also
> taxing action duplicates (9.00 / 9.83 / 10.17 vs 9.00 / 9.83 / 10.00). So action duplicates
> serve ownership essentially untaxed; the overflow rule survives only as a dead-copy sink.

---

## §0 — RESOURCE ECONOMY (canonical)

Four currencies. One acquires, three upgrade — **one upgrade currency per upgradeable category**,
each fed by duplicates of its own category. The mapping is self-describing: a duplicate unit makes
units stronger, a duplicate action makes actions stronger.

| Currency | Upgrades | Sources |
|---|---|---|
| **Aether** | **Unit stat nodes** (§8.2) | Idle rate scaling with wave · defeating enemies · **duplicate units** |
| **Lore** | **Actions** — the v0.8 bonus system | **Duplicate actions · duplicate gambits** |
| **Mettal** | **Equipment** *(not implemented — forward-looking)* | Duplicate equipment |
| **Marks** | *Nothing — it is the gacha input* | Idle rate scaling with wave · defeating enemies |

**Marks** pull from four categories: units, actions, gambits, equipment. Other acquisition routes
exist but these are the main ones. The action named **Ember** is unaffected by this naming — it
stays as-is; the stat currency is what changed, which removes the collision.

### §0.1 Is four currencies too many? — assessed, and the answer is no, with two flags

**Keep the four.** The structure is legible because **each upgrade currency has exactly one sink**.
A currency with one sink is not an allocation decision, it is a progress bar — so four currencies
impose far less cognitive load than four *competing* currencies would. There is no cross-category
budgeting to reason about, and the duplicate→category mapping teaches itself without a tutorial.

**Flag 1 — Aether mixes two incomes of completely different character, and the gacha half will
vanish.** Aether comes from a smooth, guaranteed idle-and-kill stream *and* from duplicate units,
which are lumpy gacha payouts. Dropping a rare duplicate into a pool that fills steadily anyway
means the duplicate feels like nothing — the moment it is meant to reward is drowned in
background income. Either make the duplicate-unit grant large enough to read as an event, or give
duplicate units a distinct visible reward. This is the one real flaw in the economy as specified.

**Flag 2 — Mettal is currently unfunded.** Equipment does not exist, so Mettal has no source and
no sink. Noted here as forward-looking; it should **not appear in any UI** until equipment ships,
or it is a fourth currency that visibly does nothing.

**If currency fatigue ever shows up in playtest, merge Lore and Mettal first — and only those.**
They are the strongest merge candidates: both upgrade equippable things, both come from duplicates
of pulled items, neither has an idle source. Merging them would *add* a decision (one pool spent
across actions and equipment) rather than remove one, which is arguably an improvement. The
argument for keeping them apart is tuning independence and preventing equipment upgrades from
starving action upgrades. No other pair should merge: Marks is an input not a sink, and Aether's
idle stream makes it structurally unlike the duplicate-fed pools.

### §0.2 Idle rate × the travel-time throttle

Aether and Marks both scale their idle rate with wave, which sets up a feedback loop — stronger →
deeper → faster income → stronger. **The §9 travel-time throttle is what makes this safe**, and it
is now doing load-bearing work it was not originally designed for: because travel time imposes a
fixed real-time cost per wave, it caps waves-per-hour, which converts what would be compounding
income growth into something closer to linear-in-time-at-current-depth. Any future change to
travel time is therefore also an economy change and must be evaluated as one.

**One concrete correction: key the idle rate off *deepest wave reached*, not *current* wave.** As
specified, a player who wipes and restarts at wave 1 loses their income rate as well as their
progress — punished twice for one failure, and the second punishment lands hardest on the players
least able to absorb it. Making the rate a ratchet on max depth removes that without changing the
ceiling for anyone.

---

> **v0.7 — actions are per-unit. Each dropped copy equips to one character.**
> Paired build: `farroad-prototype-v0.7.html`. Full report: `VERIFICATION-v0.7.md`.
>
> **The library was global and unlimited** — confirmed from source. Every unit had its own two
> slots, but any unit could name any action, and nothing checked whether another unit already
> used it. Three characters could all run Mend off one conceptual copy. **v0.7 makes copies
> real:** a second Mend lets a second character heal. Duplicates become immediately useful and
> **no power enters the game.**
>
> **Chosen over two alternatives on the numbers.** Duplicates-as-currency (the preferred option
> going in) *does* narrow the luck spread — 1.78 → 1.67, uniquely — but it raises build
> convergence **0.60 → 0.83** and *lowers* drop relevance, making players more alike. Per-unit
> ownership gives **drop share 30.6% → 36.1%** and **convergence 0.60 → 0.40**, the best of any
> option on both. Cost-curve retuning was measurably inert. The decisive number is drop share and
> convergence together: only Option 1 makes duplicates matter *in the form the player experiences*.
>
> **Two facts that govern the whole area.** (1) **Duplicates barely exist below ~14 drops** — so
> every duplicate mechanic is a late-game one, which inverts the "insurance for the unlucky"
> framing: the player with the most duplicates has the *largest* collection. (2) **p10 depth is 9
> in every option tested** — no design lowers the floor, so all luck variation is at the ceiling.
>
> Known cost, carried deliberately: per-unit ownership makes **thin collections worse** (drop
> share 10.4% → 5.6% at 8 drops). Mitigated by keeping Strike/Ember/Mend as per-character base kit
> and by front-loading drops, which §6.-2 already recommended for an unrelated reason.

---

> **v0.6 — three guaranteed actions, a balance pass, and rows that change damage and tempo.**
> Paired build: `farroad-prototype-v0.6.html`. Full report: `VERIFICATION-v0.6.md`.
>
> **The skill-vs-loot goal is met.** Bottom-quartile draw played well beats top-quartile draw
> played naively by **1.69 waves** (2 SE = 0.55). The gap has run 4.8 → 2.2 → 0.7 → **−1.69**.
> **Caveat, stated plainly: placement contributes +1.33 of that and the gambit system only ~0.36.
> The gambit screen remains the weaker half of skill expression.**
>
> **The finding that matters most, from the hand-size sweep (§6.-2):** a naive player's depth is
> **completely flat at 9.0 from a 4-action hand to the full 25-action library**, while a skilled
> player goes 9.0 → 15.0. **Drops do not deliver power; they deliver gambit expressiveness.** A
> drop is worth nothing until a rule uses it. This is the same fact as the 18.7% drop-relevance
> number seen from the other side, and it changes the fix: not more power in the pool, but making
> the gambit system easier to engage with early.
>
> Also: **Q1 is answered — two slots stays.** A third slot is *worse* at a large hand (10.67 vs
> 11.00) and identical at a small one. Slot count is not the binding constraint; the constraint
> is that a conditional slot costs uptime on your best unconditional action.
>
> Balance pass: utility floor 0.38 → 0.56 DPT, Burning 8% → 5%, single-target band narrowed
> 3.00× → **2.03×**. Rows now modify damage (§2.7). Stat band survives and tightened to 1.21×.

---

> **v0.5 — random drops, threat targeting, and enemy variety under the anti-meta constraint.**
> Paired build: `farroad-prototype-v0.5.html`. Full report: `VERIFICATION-v0.5.md`.
>
> **Actions and gambit conditions are random drops.** The design goal, from Unicorn Overlord:
> a player should succeed with whatever subset they drew plus a good understanding of the
> system, never be funnelled into one meta build. This constrains everything below.
>
> **1. Enemy targeting was uniform random.** Confirmed by reading the code — every archetype
> picked a party member with equal probability, so defence and healing were diluted and no
> `Ally:` gambit could be reasoned about. Replaced with **weighted threat**: row (front 1.8× /
> back 0.55×) × taunt (8×) × per-archetype preference (§2.6). Neither uniform nor solvable.
>
> **2. Six enemy archetypes, each demanding a *category* of response with ≥4 valid answers**
> (§9.6). Verified: no enemy walls any single answer — a party holding only one answer clears.
>
> **3. The anti-meta property was measured, and it initially failed.** Across 48 random draws
> of 6 actions and 5 conditions, **a good draw played badly beat a bad draw played well by 4.8
> waves.** Root cause: **healing was mandatory** (+3.6 waves) and only half of draws had one.
> **Fix: Mend joins Strike as a guaranteed, never-dropped action.** Result: wave-10 clear rate
> **54% → 100%**, luck gap **1.8× → 1.4×**, loot's edge cut to 2.2 waves. Every draw is now
> viable; loot still edges skill, and closing that needs the library's power band narrowed.
>
> **4. Gambit value is *not* bimodal** (+7.0% on marginal draws vs +7.6% on comfortable ones).
> The prediction that it would be invisible when winning and decisive when marginal is rejected.

---

> **v0.4 — action cost prices power; enemy count becomes a difficulty axis.**
> Paired build: `farroad-prototype-v0.4.html`. Full report: `VERIFICATION-v0.4.md`.
>
> **1. Per-action tick cost was already implemented** (§2.1, §2.3) and the presentation beat
> was already separate from the scheduling cost (§2.4) — but the ranks weren't *pricing* the
> powers. **Pierce (DPT 1.045) and Flurry (1.050) strictly dominated Strike (1.000)**, so the
> mechanic existed while the tradeoff didn't. The whole library is repriced to a **DPT ≈ 1.00
> baseline** (§6.1–6.2), rank band widened to 0.65–2.00, and cost is now surfaced everywhere
> in the UI.
>
> **2. The §9.5 encounter-HP normalisation is reversed.** Enemies are full strength regardless
> of count. Enemy count is now a difficulty axis and **party size is the answer to it**: a solo
> unit clears 2.9 waves against one enemy, 0.7 against two, and zero against three. Recruitment
> precedes the pressure by 25 and 5 miles, so there is no pacing problem (§9.5).
>
> **3. Fight length no longer holds at 15–20 s and cannot.** Even a *matched* party runs 14 s
> at one enemy and **28 s at three**, because 8 units on the field at one action per beat is
> ~40 actions. §1.1 now states a curve rather than a target, and the consequence for boss
> length is flagged as **open question Q9**.
>
> Also: §9.2 reactivated — early difficulty comes from count, late from stats, and the two must
> not stack. Charge actions, statuses and tick costs all have visible descriptions in the build.

---

> **v0.3 — action library and gambit system expanded, and reconciled against the prototype.**
> Paired build: `farroad-prototype-v0.3.html`. Full report: `VERIFICATION-v0.3.md`.
>
> **The finding that matters most:** hand-written gambits beat the naive alternate-when-unset
> default by only **+2.7%** on average across 11 builds, and *lose* in 4 of 11. The system is
> not decorative, but its value is narrow and concentrated in two places — **actions that are
> bad outside their window** (§6.0) and **targeting across multiple enemies** (§5.5). Both have
> been addressed rather than papered over: situational actions now carry a penalty, and waves
> ramp to 2–3 enemies (§9.5).
>
> Also in v0.3: §6 expanded from 13 to **25 standard actions** with proper debuff and healing
> coverage · §5.3 from 12 to **18 conditions** including `Foe: lacks this debuff` · §3.5 from 6
> to **14 statuses** with stated refresh semantics · §5.2 **switched to strict top-down
> evaluation**, fixing an inconsistency that made slot order a no-op · a second party unit and
> 1–3 enemies as testbed affordances · §9.5 enemy-count normalisation.

---

> **v0.2.1 — reconciled against the Milestone 0 prototype.** The combat core is now built
> (`farroad-prototype.html`, sources in `src/`) and simulated. §3.6's worked trace reproduces
> **exactly, beat for beat**, and §8.2's marginal-value table reproduces within 0.2 pp on 7 of
> 8 stats. Six numbers in this doc were wrong or overstated and have been corrected in place,
> each marked *(measured)* or footnoted with a finding ID: **F1** wave-2 enemy HP 218→221 ·
> **F2** the 17–22 beat band holds only 60.9% of the time, so §10.4 now states the target in
> seconds · **F3** the DEF node can't be measured at L1 · **F4** Pierce is +40.5%, not +33.7% ·
> **F5** SPD is +4.17%, not +4.00% · **F6** charge persistence measured. One new design question
> (**Q8**, evadable charge actions) came out of playing it. Full report: `VERIFICATION.md`.

**Genre:** idle / auto-battler RPG, mobile (portrait)
**Pitch:** You walk a road of unknown length toward a single wish. Fights resolve themselves. What you actually play is the *loadout* — who is in the party, what two actions each of them carries, and the one-line rule that decides which of the two they use.

This doc is written to be implemented from. Every formula is stated in a form you can type into code. Section 10 is the only thing that needs to exist for the first build.

**Changes in v0.2** (both from Ian's review, both with knock-ons worked through, not just patched):

1. **Damage formula replaced.** `power × ATK²/(ATK+DEF)` was superlinear in ATK — see §3.0 for the elasticity proof — which made single-stat stacking the correct answer. Replaced with a separated form where ATK is strictly linear, and every stat node retuned so the whole investment menu lands in a **1.4× band** (§8.2).
2. **Fight length retargeted to 15–20 s** (17–22 beats), bosses 30–45 s (40–65 beats). This forced changes to the beat length (§2.4, now ramped), the difficulty exponents (§9.2, now near-neutral with a level cap providing the wall), the charge-gauge argument (§4.4, which got *stronger*, not weaker), and the entire idle throughput model (§1.4, which needed a travel-time term it didn't have).

---

## 0. Design pillars

1. **The fight plays itself; the decision happens before the fight.** If the player is tapping during a fight, the design has failed.
2. **Two actions and one condition is the whole puzzle.** A phone screen fits two rows.
3. **Legibility over depth.** A player must be able to look at the turn queue and predict the next three actions.
4. **No stat is the answer.** Several allocations should land within ~40% of each other. §8.2 is the receipt.
5. **The road does not end when you lose.** Failure moves you backward, not to zero.

---

## 1. Core loop

### 1.1 Moment to moment

Combat runs unattended. One action per **Beat** (§2.4, ramped 900 → 400 ms across four tiers).

**Fight length is a curve, not a target (changed in v0.4).** Encounter size drives it, and since v0.4's §9.5 leaves enemies at full strength regardless of count, a bigger encounter is a longer one even for a correctly-sized party:

| Encounter | Matched party | Beats | Seconds |
|---|---|---|---|
| 1 enemy | 2 | 16 | **14 s** |
| 2 enemies | 3 | 35 | **26 s** |
| 3 enemies | 5 | 39 | **28 s** |

This is structural. With 5 party units and 3 enemies there are **8 units on the field**, each acting ~5 times, so a full-size encounter is ~40 actions and no damage tuning changes that — the floor for 8 units each acting twice is already 16 beats. Lowering enemy HP shortens everything proportionally; it cannot make a 5v3 as short as a 2v1.

The old flat "15–20 s" target survives only for the smallest encounters. The knock-on for Named fights (which would land at 60–85 s) is **open question Q9**.

Between encounters the party **walks**, which is most of the elapsed time (§1.4).

There is nothing to tap during a fight. This is intentional.

### 1.2 Session to session

Target session: **60–120 s, 3–5 times a day.**

| Step | Taps | What it is |
|---|---|---|
| Collect | 1 | Offline bundle: Aether, miles travelled, a log of what happened |
| Invest | 3–8 | Spend Aether on unit stat nodes (§8.2) |
| Waymark | 0–2 | If a Waymark is pending, pick a branch and/or recruit (§7) |
| Re-slot | 0–4 | Change an action or a gambit condition on one unit |
| Close | — | |

The **Waymark** is the only place the game blocks on the player. Combat never blocks.

### 1.3 Week to week

- Day 1: Mile ~40, 2 companions, gambit UI unlocked.
- Day 2: party of 5 filled (Mile ~95).
- Day 5–7: run walls somewhere around Mile 500–620 (§9.3), player prestiges (§8.5).
- Week 3+: runs are faster and deeper; the variable is Reason choice and roster, not raw stats.

### 1.4 Idle, travel, and offline

**This section changed materially in v0.2.** At v0.1's 9-second fights, an unthrottled 12 h offline session would have advanced ~3,600 nodes — six full runs overnight. Longer fights don't fix that; they make it marginally worse per fight and much worse per hour of watching. The missing piece was that **v0.1 had no travel time at all**, so combat throughput was the only clock.

**Travel is the throttle. Combat is the punctuation.**

```
travelTime(mile) = 300 + 0.5 * mile        # seconds, per node
nodeDuration(mile) = travelTime(mile) + encounters(node) * ~19 s
```

| Mile | Travel | Node duration | Nodes per 12 h |
|---|---|---|---|
| 0 | 5.0 min | 5.4 min | 134 |
| 200 | 6.7 min | 7.0 min | 102 |
| 400 | 8.3 min | 8.7 min | 82 |
| 600 | 10.0 min | 10.4 min | 69 |

**~100 nodes per 12 h session**, and a 500-node run integrates to `∫₀^500 (323 + 0.5m) dm ≈ 224,000 s ≈ 62 h` of game-time — **5.2 days at 12 h/day**, which is the §1.3 target. Combat is ~5% of elapsed time. That is the genre: the walk is the idle state, combat interrupts it, and the art direction is a party walking a road.

**Offline: 12 h cap.** Chosen over Melvor Idle's 24 h because 12 h maps to a twice-daily login without ever wasting a night's sleep; the convention runs 12–24 h and 12 h is the tighter, more login-positive end ([offline cap conventions](https://blog.clickerheroes.com/top-offline-idle-games-in-2025/)).

Offline is **not** simulated action by action. It advances node by node against a closed-form estimator:

```
dps_per_beat  = expected party damage per beat, from current loadout      # §3.7
ehp           = sum(party HP) / expected incoming damage per beat
budget        = min(elapsed, 12h)
for each node ahead:
    if budget < nodeDuration(mile): HALT (clock)
    enemy_hp, enemy_dps = scaled(mile)                                    # §9.2
    margin = (ehp / (enemy_hp / dps_per_beat))
    if margin < 1.35: HALT (danger)
    advance; award Aether; AUTO-INVEST (below); deduct nodeDuration
```

Three consequences, all deliberate:

- **Offline never wipes the party.** Risk exists only online. The sim stops one node short of a loss: *"The party halted at Mile 412. The road ahead is too dangerous."* Self-limiting, and a concrete non-nagging reason to open the app.
- **Offline stops at Waymarks**, because Waymarks need a decision.
- **Auto-invest is required, not optional.** Without it, the party's automatic level growth alone falls behind enemy scaling and the danger-halt fires after ~1 h of simulated time — an offline session that ends in an hour is not an offline session. The player sets a percentage allocation once (`40% ATK / 30% HP / 30% chargeRate`) and the offline sim spends Aether to it as they're earned. This is a **new v0.2 system** and it needs UI.

So: **offline is clock-limited in normal play and danger-limited when the player is genuinely outmatched.** Both mechanisms ship; they do different jobs.

Estimator validation: every 100th fight while online, run the estimator alongside the real fight and log the delta. Drift >10% means the loadout has a mechanic the estimator doesn't model (usually a heal or a delay) and it needs a term.

**No energy gate.** [AFK Arena wraps grind in an idle mechanic rather than an energy cap](https://www.deconstructoroffun.com/blog/2019/6/6/afk-arena-puts-lilith-into-the-billionaire-club), and that's correct for this shape.

---

## 2. Turn and tick system

### 2.1 Model

FFX's Conditional Turn-Based system with the quantization removed. In FFX each combatant holds a **CTB Value** that decrements per tick; at 0 they act and it resets to `Base CTB × Action Rank`, where Base CTB is a lookup table on Agility stepping from 28 down to 3 ([FFX-Info: CTB](https://grayfox96.github.io/FFX-Info/game-mechanics/ctb)). That table is a PS2-era optimization with dead zones — Agility 98–169 are all identical. Farroad uses the continuous form:

```
TICK_K = 10000
turnCost(unit, action) = max(1, round(TICK_K * action.rank / unit.SPD))
```

`SPD 100, rank 1.0` → **100 ticks**. `SPD 92` → 109. `SPD 125` → 80. Integer output, so the timeline is deterministic and replayable — which the offline estimator, the turn preview, and any future async PvP all depend on.

### 2.2 Scheduler

A min-heap of `(nextActAt, tiebreak, unitId)`. Ticks are ordinal, so there is nothing to decrement toward — pop the earliest.

```
onBattleStart:  for each unit: unit.nextActAt = turnCost(unit, RANK_1)     # ICV
resolveNext:
    unit = heap.pop()          # ties: party before enemy, then higher SPD, then lower slot index
    now  = unit.nextActAt
    action = chooseAction(unit)                                            # §5
    play(action)                                                           # one Beat
    unit.nextActAt = now + turnCost(unit, action)
    heap.push(unit)
```

Tiebreak order is FFX's (characters before monsters, then Agility, then index), because it makes the player-facing rule "your party wins ties," which reads as fair.

### 2.3 Action Rank

`rank` is the turn-cost multiplier — the scheduling half of §2.4's two clocks. It is what makes a heavy action cost you turns, exactly as FFX's Rank does.

| Rank | Cost @ SPD 100 | Meaning | Examples |
|---|---|---|---|
| 0.65–0.80 | 65–80 ticks | very fast, non-damaging | Brace, Rally |
| 0.95–1.10 | 95–110 | baseline and light utility | Strike, Ember, Daunt, Bulwark |
| 1.15–1.35 | 115–135 | slower hits, riders, AoE | Pierce, Cleave, Guard Break, Siphon |
| 1.45–1.75 | 145–175 | heavy conditional hits, revive | Execute, Onslaught, Recall |
| 1.55–2.00 | 155–200 | charge actions | Oath 180, Ashfall 200 |

**Power is priced against rank (v0.4).** The design rule is `DPT = power ÷ rank ≈ 1.00` for a plain single-target hit, and every deviation is paid for with a rider, a condition, or reach:

```
Strike  1.00 / 1.00 = 1.000     baseline
Pierce  1.30 / 1.30 = 1.000     same DPT, slower, ignores 40% DEF
Ember   1.05 / 1.05 = 1.000     same DPT off MAG
Cleave  0.60 / 1.35 = 0.444 ea  ×3 foes = 1.333
Cripple 0.50 / 1.20 = 0.417     + Slowed
Execute 2.90 / 1.45 = 2.000 in window;  0.60 / 1.45 = 0.414 out
```

**This is a v0.4 correction, not a new system.** v0.3 assigned power by feel and rank separately, and never multiplied the two — with the result that **Pierce (DPT 1.045) and Flurry (1.050) strictly dominated Strike (1.000)**, Pierce with 40% armour pierce on top. The rank mechanic was working; it just wasn't pricing anything.

**Cost is a genuine but modest lever on pacing.** Swapping a party from all-rank-1.00 to rank-1.30–1.45 actions shortens a fight by ~15% in beats (64 → 53 at party 3 vs 2 enemies). Over-committing backfires: an all-rank-1.45 party runs *longer*, because Execute out of window is DPT 0.41.

**Cost as an alternative to a penalty multiplier.** For breadth actions (Cleave, Gale) and rider actions (Guard Break, Sear), cost alone is enough to make them situational — rank 1.35 for 0.60 power is self-evidently wrong against one target. For **conditional** actions it is *not* enough, because cost is symmetric and a condition is not: Execute at rank 1.45 with no floor penalty would still be worth spamming. §6.0's rule therefore stands, amended: *cost suffices for breadth and riders; conditions still need a penalty.*

### 2.4 The Beat — how ~1 s reconciles with variable SPD

**Every action occupies exactly one Beat of screen time, regardless of rank or SPD.** The tick clock **stops** during a Beat, exactly as FFX's CTB clock freezes during animations.

This is the reconciliation, and it inverts the usual intuition:

> **SPD does not make you faster on screen. SPD buys you a larger share of the turn queue.**

A SPD-140 unit and a SPD-70 unit both take one Beat to swing; the SPD-140 unit simply appears twice as often. Consequences: wall-clock fight length is a pure function of action count (so §1.4's estimator is exact on the combat term); SPD is a "you get more of the actions" stat, not a "fights end sooner" stat, so it competes honestly with ATK; and animation sync is free because everything is on one grid.

**Beat length ramps within a fight (new in v0.2).** At a flat 900 ms, a 65-beat Named fight is 58 s, which is too long to hold on a phone, while dropping the base below 900 ms makes normal fights feel rushed. So:

```
beatMs(n) =  900   for n <= 16
             700   for 17 <= n <= 34
             550   for n >= 35
```

| Fight | Beats | Seconds |
|---|---|---|
| Short normal | 17 | 15.1 |
| Typical normal | 20 | 17.2 |
| Long normal | 22 | 18.6 |
| Short Named | 40 | 30.3 |
| Long Named | 65 | 44.1 |

Normal **15.1–18.6 s** ✓ (target 15–20). Named **30.3–44.1 s** ✓ (target 2–3× normal). The first 16 beats of every fight are at full weight, so the opening — where the turn preview is being read and the first charge lands — never feels compressed. A manual 1×/2×/4× toggle multiplies on top.

Animations are authored at 900 ms and time-compressed; multi-hit actions subdivide a single Beat (3 hits at 300 ms, 9 at 100 ms).

### 2.7 Rows — damage and tempo, not just threat (new in v0.6)

In v0.5, `row` fed the threat weighting and **touched damage not at all**. That made placement a solved problem: measured, **ALL FRONT and ALL BACK scored identically (22.86)** because threat weights are relative and a uniform assignment normalises out. Only *bad* placement registered. Row was a trap you could fail, not a decision you could win.

```
Front row:  +10% SPD · threat ×1.35 · full damage dealt and taken
Back row:   threat ×0.75 · physical damage DEALT ×0.70 and TAKEN ×0.70
Magic is unaffected in both directions.
Rows are a PARTY formation. Enemies have no row and receive no modifiers.
```

**Magic is exempt by camp, not by action, and that is deliberate.** Gating the back-row penalty on specific "reach" actions would be a drop-luck trap — row would only work if you drew the right thing. Camp-based exemption is drop-independent **because Ember is guaranteed (§6.-1)**: every player, whatever they rolled, has a way to make the back rank productive. The two v0.6 decisions support each other.

**Result — placement is now a real decision:**

| Assignment | v0.5 | **v0.6** |
|---|---|---|
| melee front / casters back | 24.6 | **24.92** |
| ALL FRONT | 22.86 | 23.50 |
| ALL BACK | 22.86 | 21.58 |
| INVERTED | 20.29 | 22.00 |

Mixed beats both uniforms, spread **15.5%**, no dominant assignment. Placement is worth **+1.33 waves** of skill expression and it is drop-independent, which makes it the cheapest source of tactical depth in the design.

**The front-row SPD bonus is sized at +10% by measurement, and it is close to net-neutral** (+0.8% depth) — correctly so, because the units that stand front are the ones absorbing damage, so the tempo gain is paid for almost exactly. It is a two-sided trade, not a free buff. Checked at +5/+8/+10/+12%: mixed wins at every value, ALL FRONT never dominates.

**One property is not achieved and should not be claimed.** The hope was that SPD affecting both camps would stop placement being class-determined. Measured per archetype, a fragile caster still prefers the back against every enemy that actually pressures the party (Ox by 6.08 waves, Wolf 4.67, Knight 1.83, Hound 0.50; Priest and Shrike are ties within noise). The +10% narrowed the mixed-wave gap from 2.17 to ~1.0 waves, but the threat multiplier dominates a ±10% tempo swing on a 270 HP unit. **Party-level placement is a genuine decision; an individual fragile caster's answer is still usually "back".** The knob if this matters: give the front row a small *damage* bonus rather than only SPD — not shipped, since it is a new mechanic and needs its own sizing pass.

*(A bug worth recording: enemies were built with `row:'front'`, so the first version of the SPD bonus was handed to the enemy side too and measured negative. Rows are now party-only.)*

### 2.6 Enemy targeting — weighted threat (new in v0.5)

**What it was.** Uniform random among living party members, with a taunt override, identical across every archetype. That is the worst of the options: defensive stats and healing were diluted across the party, a fragile unit could not be protected, and every `Ally:` gambit was reacting to noise.

**What it is now.** Weighted random — neither uniform (no dilution) nor deterministic (not solvable once):

```
threat(u) = rowMul(u)                          front 1.8 · back 0.55
          × (taunted ? 8.0 : 1)
          × archetypePreference(enemy, u)
target    = weighted random draw over the living party
```

Deterministic mode picks the highest weight so debug traces stay reproducible.

**Rows.** Every unit is Front or Back, freely assignable, no cost. This is the player's lever on targeting and it is **drop-independent** — it cannot meta-lock anyone because everybody has it.

**Per-archetype preference is where the variety lives**, and it is also drop-independent:

| Enemy | Preference | Reads as |
|---|---|---|
| Roadwolf | `1 + 1.5 × (1 − hp%)` | lunges at whoever is already hurt |
| Barrow Knight | front ×2.5, back ×0.4 | engages the line and stays there |
| **Mire Hound** | back ×2.2, front ×0.6 | **darts past the line at your back rank** |
| Stone Ox | flat | indiscriminate |
| Fen Priest | `1 + 1.0 × (1 − hp%)` | opportunist |
| Thorn Shrike | flat | indiscriminate |

Measured on a 5-unit party (front Kesh/Dorrek, back Ansa/Vey/Mirel; uniform would be 20% each):

| Enemy | Kesh | Ansa | Dorrek | Vey | Mirel |
|---|---|---|---|---|---|
| Roadwolf | 29% | 11% | **42%** | 10% | 7% |
| Barrow Knight | 41% | 2% | **47%** | 8% | 2% |
| **Mire Hound** | 17% | **24%** | 17% | **24%** | 19% |
| Stone Ox | 24% | 20% | 27% | 12% | 18% |

The Knight barely touches the back rank; the Hound inverts and puts a quarter of its attacks into each squishy. **Rows demonstrably steer this** — moving Mirel forward takes her Knight share from 2% to 41% while the Hound ignores the change. So positioning answers some threats and not others, which is exactly the situational variation gambits need.

**The UI exposes all of it**: a THREAT tab showing each enemy's live target probabilities with its preference in plain language, a tap-to-toggle FRONT/BACK tag on every unit, the current target highlighted, and a `▸ threat:` line in the log recording the odds at the moment of each enemy action.

### 2.5 Turn-order preview

A horizontal rail of **6 portrait chips**, current actor leftmost and highlighted. Generated by cloning the heap and popping 6 times, assuming each unit uses the action its gambit list currently selects. Regenerated after every action.

The preview is **predictive, not a promise** — it cannot know about effects not yet applied. When something reorders the queue (Quicken, a delay, a death), the affected chip slides to its new index over 250 ms with a colored trail (cyan = sped up, amber = delayed). This animation is the clearest teacher in the game for what SPD and rank do, and should be exaggerated rather than subtle.

Chips show portrait + 1-line action name; charge-ready units get a glowing frame. Long-press → why: `"Kesh — Pierce — Foe: HP ≤ 30% is false, falling through"`.

---

## 3. Combat math

### 3.0 Why v0.1's formula was wrong

v0.1 used `damage = power × ATK²/(ATK+DEF)`. Its elasticity with respect to ATK (the % damage gained per % ATK gained, at fixed DEF) is:

```
d(D)/d(A) * A/D = (A + 2D)/(A + D)
```

which equals **1.5 at parity (A = D), 2.0 as DEF dominates, and never falls below 1.0.** It is superlinear *everywhere*, and worst exactly where players spend their time — at or below stat parity. Concretely: ATK 100 vs DEF 100 deals 50; ATK 200 vs DEF 100 deals 133 — **2.67× the damage for 2× the ATK.**

The consequence is that no secondary stat can compete. A crit or charge-rate node buys a fixed multiplier; an ATK node buys a multiplier *that grows as you buy more of them*. Single-stat stacking has increasing returns, so the optimal build is "put everything in your highest offensive stat," and the other nine stats are decoration.

### 3.1 Damage core (v0.2)

Offense and mitigation are separated so ATK appears exactly once and is therefore **strictly linear (elasticity 1.000)**:

```
PHYSICAL:  base = power * ATK * K(L) / (K(L) + DEF_eff)
MAGIC:     base = power * MAG * K(L) / (K(L) + RES_eff)

K(L) = 23 + 2*L          # L = the ACTING unit's level; the mitigation constant

DEF_eff = DEF * (1 - action.defPierce) * (1 - sundered)     # Sundered = 0.25
RES_eff = RES * (1 - action.resPierce) * (1 - frail)        # Frail    = 0.25
```

**What `K` is and why it's level-keyed.** `K` is the defense value at which damage is halved. A flat constant (`100/(100+DEF)`, as in SMITE) breaks over a long progression: as DEF grows from 20 to 160 across a run, mitigation would climb from 17% to 62% and damage would collapse. Tying `K` to the acting unit's level tracks it against expected DEF at that point in the run and holds mitigation in a **stable 43–45% band from Mile 0 to the level cap**, verified in §3.8. Enemies have a level too: `enemyLevel(mile) = 1 + floor(mile/8)`, the same curve as the party.

Mitigation curve — note it is now keyed on `K`, not on the attacker's ATK:

| DEF vs K | Damage taken |
|---|---|
| DEF = 0 | 100% |
| DEF = ½K | 67% |
| **DEF = K** | **50%** |
| DEF = 2K | 33% |
| DEF = 4K | 20% |

**`K(1) = 25` was chosen so that early-game damage numbers come out identical to v0.1's.** `26 × 25/37 = 17.57`, and `26²/(26+12) = 17.57`. This is not a coincidence — it was solved for, so that **every `power` value in the action library (§6) carries over from v0.1 unchanged.** Only the charge actions were retuned, and for a different reason (§6.3).

### 3.2 Variance

Copied from FFX, which rolls `base × (rand(0..30) + 240)/256` ([FFX-Info](https://grayfox96.github.io/FFX-Info/rng/damage-crit-escape-icv)):

```
variance = (randInt(0, 30) + 240) / 256      # 0.9375 .. 1.0547, mean 0.9961
```

±5%, mean ≈1.0. Deliberately tight: in an auto-battler the player cannot respond to a bad roll, so wide variance reads as unfairness rather than excitement — and tight variance is what lets §1.4's estimator use expected values without lying.

### 3.3 Resolution order

Per hit; multi-hit actions roll each hit independently.

```
1. EVADE    physical only. p = clamp(target.evade, 0, 0.40).  On hit → 0 damage, "MISS". Stop.
2. CRIT     p = clamp(source.atkCrit or magCrit + action.critBonus, 0, 0.70)
3. BASE     §3.1
4. VARIANCE §3.2
5. CRIT MUL if crit: * 1.75
6. BLOCK    p = clamp(target.block, 0, 0.50).  If blocked: * 0.50, "BLOCK"
7. FLOOR    damage = max(1, floor(damage))
```

- **Crit is ×1.75, not ×2.0.** In a game where the player never chooses when a crit lands, a 2× spike is indistinguishable from randomness. 1.75 with a high crit *rate* ceiling (70%, §8.2) delivers comparable expected damage at lower variance.
- **Evade nulls, block halves, evade is physical-only.** Two defensive stats need two feels: evade is a lottery (spiky, physical-only), block is a tax (steady, covers magic). Making both partial reductions would be one stat with two names.

Crit and block stack: a blocked crit is `1.75 × 0.5 = 0.875×`. It gets its own sound.

### 3.4 Healing

`heal = power × MAG × variance`, floored, no overheal. No `RES` term and no crit — healing through a defence stat is a known source of unreadable outcomes, and a crit heal is a spike the player can't plan around.

**The idle-context question: what happens to a player who never opens the gambit screen?** Under the default their healer runs `alternate Mend / Ember`, healing every other turn whether or not anyone is hurt. Wasteful, but measurably **not** a trap — 20.75 waves versus 17.88 for a healer who never heals, so **+16% for carrying a heal at all, with zero configuration.** The reactive version (`Ally: HP ≤ 60% → Mend`) adds a further +6.4% on top. That is the right shape: the default is safe, and learning the system is a bonus rather than a rescue.

A guard that skips the heal and Strikes instead when nobody is hurt measured at **20.75 vs 20.72** — no effect. It ships as free insurance against a "healer stands there overhealing" screenshot, but it is not a system and should not be documented as one.

### 3.5 Statuses in v1

Fourteen statuses. **All of them REFRESH**: re-applying resets the duration to full and *never* stacks magnitude or extends.

| Status | Effect | Turns |
|---|---|---|
| Sundered | DEF_eff × 0.75 | 3 |
| Frail | RES_eff × 0.75 | 3 |
| **Enfeebled** | ATK_eff × 0.75 | 3 |
| **Dulled** | MAG_eff × 0.75 | 3 |
| **Slowed** | turnCost × 1.50 — literally steals turns out of the CTB queue | 3 |
| **Blinded** | the afflicted unit's *physical* attacks gain +30% miss (added at §3.3 step 1) | 3 |
| Burning | 8% of max HP at the start of each of the target's turns | 3 |
| Hasted | turnCost × 0.60 | 3 |
| Warded | incoming damage × 0.60 (applied at §3.3 step 6b) | 3 |
| **Regen** | +6% of max HP at the start of each of the target's turns | 4 |
| **Blurred** | +0.20 evade | 3 |
| **Surging** | chargeRate × 2.0 | 3 |
| **Bracing** | +0.30 block, DEF_eff × 1.40 | 2 |
| Taunted | enemies forced to target the taunter if legal | 3 |

Durations tick on **the afflicted unit's own turns**, not global ticks — so Slowing an enemy doesn't secretly extend every debuff on it. Burning and Regen resolve at the start of the turn, *before* the duration decrements, so a 3-turn Burn deals exactly 3 ticks.

**Why refresh and not stack.** Stacking magnitude creates runaway states an idle player cannot see coming; extending duration makes debuff-spam strictly dominant. Refresh means re-applying a live debuff is a **wasted turn** — which is exactly the pressure that makes `Foe: lacks this debuff` (§5.3) worth putting in a slot. The three rules are load-bearing on each other.

**Slowed deserves special note.** Because SPD drives the entire turn queue (§2.4), a 1.50× turn-cost multiplier doesn't reduce a stat — it removes roughly a third of the target's actions from the fight. It is the most powerful debuff in the library and Cripple is priced accordingly (0.45 power, rank 1.10).

### 3.6 Worked example — hand-checkable

Deterministic mode: variance fixed at 1.0, crit/evade/block rolls all fail. Milestone 0 configuration (§10).

**Kesh (MC, L1):** HP 900\*, ATK 26, MAG 18, DEF 20, RES 16, SPD 100 · atkCrit 5%, block 3%, evade 3%, chargeRate 100%
**Roadwolf Alpha (L1):** HP 210\*, ATK 22, DEF 12, SPD 92 · atkCrit 4%, evade 5%, block 0%
Loadout: both slots Strike (power 1.00, rank 1.00, charge +20). Charge action: Wayfarer's Oath (power 3.50, rank 1.50).

\* *Prototype-only values. In the shipping game Kesh has 180 HP and a Roadwolf has 95, because a normal encounter is 3 enemies against a party of 5. The prototype is 1v1, so its single wolf has to be a whole encounter and its Kesh has to carry the party's HP budget. Derivation in §10.1.*

```
K(1) = 23 + 2(1) = 25

Kesh Strike → Wolf:   1.00 * 26 * 25/(25+12) = 650/37  = 17.568 → 17
Kesh Oath   → Wolf:   3.50 * 26 * 25/(25+12) = 61.49            → 61
Wolf Bite   → Kesh:   1.00 * 22 * 25/(25+20) = 550/45  = 12.222 → 12

turnCost(Kesh, 1.00) = round(10000 * 1.00 / 100) = 100
turnCost(Kesh, 1.50) = round(10000 * 1.50 / 100) = 150
turnCost(Wolf, 1.00) = round(10000 * 1.00 /  92) = 109
```

**Wave 1** — full trace, 19 beats:

| Tick | Actor | Action | Dmg | Wolf HP | Kesh HP | Charge |
|---|---|---|---|---|---|---|
| 100 | Kesh | Strike | 17 | 193 | 900 | 20 |
| 109 | Wolf | Bite | 12 | 193 | 888 | 20 |
| 200 | Kesh | Strike | 17 | 176 | 888 | 40 |
| 218 | Wolf | Bite | 12 | 176 | 876 | 40 |
| 300 | Kesh | Strike | 17 | 159 | 876 | 60 |
| 327 | Wolf | Bite | 12 | 159 | 864 | 60 |
| 400 | Kesh | Strike | 17 | 142 | 864 | 80 |
| 436 | Wolf | Bite | 12 | 142 | 852 | 80 |
| 500 | Kesh | Strike | 17 | 125 | 852 | **100** |
| 545 | Wolf | Bite | 12 | 125 | 840 | 100 |
| 600 | Kesh | **Wayfarer's Oath** | **61** | 64 | 840 | 0 |
| 654 | Wolf | Bite | 12 | 64 | 828 | 0 |
| 750 | Kesh | Strike | 17 | 47 | 828 | 20 |
| 763 | Wolf | Bite | 12 | 47 | 816 | 20 |
| 850 | Kesh | Strike | 17 | 30 | 816 | 40 |
| 872 | Wolf | Bite | 12 | 30 | 804 | 40 |
| 950 | Kesh | Strike | 17 | 13 | 804 | 60 |
| 981 | Wolf | Bite | 12 | 13 | 792 | 60 |
| 1050 | Kesh | Strike | 17 | **dead** | 792 | 80 |

**10 Kesh actions + 9 Wolf actions = 19 beats.** At §2.4's ramp: `16 × 0.9 + 3 × 0.7 = 16.5 s`. ✓ Kesh ends 792/900, charge 80.

Note tick 654: the rank-1.50 Oath pushed Kesh's next turn from 700 to 750, so the wolf got a free turn in the gap. That cost is visible in the turn preview one action before it happens, and it is the reason rank exists.

**Wave 2** — wolf scaled ×1.06 (HP 221, ATK 23, DEF 13, per §9.2's exponents; `210 × 1.06^0.84 = 220.53 → 221`). Kesh carries in 80 charge, so the Oath fires on his **second** action, and a second Oath lands late in the fight.

| | |
|---|---|
| Kesh sequence | S(17), **Oath(59)**, S, S, S, S, S, **Oath(59)**, S |
| Kesh actions | 9 (7 Strikes + 2 Oaths) = `7×17 + 2×59 = 237` vs 221 HP ✓ |
| Wolf actions | 9 (ticks 109…981, wolf dies at Kesh's tick-1000 action) |
| **Total** | **18 beats = 15.8 s** |

Wave 2 is *shorter* than wave 1 despite a tougher wolf, because two charge actions landed instead of one. That variance-between-fights is the charge rhythm doing its job, and it is the main reason waves don't feel identical.

### 3.7 Expected values (variance, crit, evade on)

```
E[Strike vs Roadwolf] = 17.568 * 0.9961 * (1 + 0.05*0.75) * (1 - 0.05)              = 17.25
E[Oath   vs Roadwolf] = 61.49  * 0.9961 * (1 + 0.35*0.75) * (1 - 0.05)              = 73.46
E[Bite   vs Kesh]     = 12.222 * 0.9961 * (1 + 0.04*0.75) * (1-0.03) * (1-0.03*0.5) = 11.98
```

Deterministic trace and stochastic expectation agree to within ~1%, which is §3.2's tight-variance property paying off.

### 3.8 Mitigation stability check

The claim in §3.1 is that `K(L) = 23 + 2L` holds mitigation in a stable band across the run. Against a level-appropriate enemy (`enemy DEF = 12 × S(mile)^0.98`, §9.2):

| Mile | Level | K | Enemy DEF | `K/(K+DEF)` | Reduction |
|---|---|---|---|---|---|
| 0 | 1 | 25 | 12 | 0.676 | 32% |
| 100 | 13 | 49 | 30 | 0.620 | 38% |
| 200 | 26 | 75 | 49 | 0.605 | 40% |
| 400 | 51 | 125 | 101 | 0.553 | 45% |
| 600 | 60 (cap) | 143 | 158 | 0.476 | 52% |

Stable 32–45% through the level cap, then deliberately worsening past it — which is where the run's wall comes from (§9.3). Player-side mitigation against enemy attacks behaves identically by symmetry.

---

## 4. Charge gauge

### 4.1 Fill

Gauge is measured in points, target 100. Filled only by the unit's own actions.

```
onActionComplete(unit, action):
    if action.isCharge: unit.charge -= 100; return         # NOTE: subtract, do not zero
    unit.charge += action.charge * unit.chargeRate         # NOTE: no cap
```

**Overflow carries, and there is no cap (changed in v0.2).** v0.1 clamped at 100 and zeroed on use. That made `chargeRate` a **step function** — going from 100% to 108% changed `ceil(100/20)` from 5 actions to 5 actions, i.e. bought literally nothing, and a node's value depended entirely on whether it happened to cross a threshold. With overflow carried, actions-per-charge is continuous at `100 / (action.charge × chargeRate)` and every point of `chargeRate` pays immediately. This is what makes `chargeRate` a competitive investment in §8.2 rather than a lottery ticket.

`action.charge` values are **20 / 25 / 33** (§6). `chargeRate` starts at 1.00, caps at 3.50.

### 4.2 The turn it fills

Filling happens at the end of the action that completes it. On the unit's **next** turn:

```
chooseAction(unit):
    if unit.charge >= 100: return unit.chargeAction     # bypasses the gambit list entirely
    ... evaluate gambits ...                            # §5
```

The charge action **overrides the gambit list unconditionally.** No condition can suppress it or trigger it early. Deliberate: the moment charge is something you can gate on, the two-row gambit UI stops fitting on a phone, and the player loses the ability to look at a full gauge and know exactly what happens next. The portrait chip glows from the moment the gauge fills, so it is always telegraphed at least one Beat ahead.

### 4.3 chargeRate

A multiplier on gain, not a separate resource. Node value: **+25 percentage points**, cap 350% (§8.2). It is the **best first node and the worst tenth node** of any offensive stat — front-loaded, because its ceiling is "you are casting your charge action constantly," which is a hard asymptote. For support units (Ansa, Dorrek) whose charge actions are heals and wards rather than damage, it is the *only* stat that increases their output at all, and it is unambiguously their best buy.

**Support builds are not punished by the charge gauge — they are slightly rewarded.** Measured over 120 runs (VERIFICATION-v0.3 §G4):

| | Actions per fight | Charges per fight | **Actions per charge** |
|---|---|---|---|
| Kesh (damage: Strike) | 6.23 | 1.00 | **6.3** |
| Ansa (support: Mend / Ember) | 5.50 | 1.06 | **5.2** |

Support charges **17% faster** than the damage dealer, because support and utility actions grant 25–33 charge against Strike's 20. That asymmetry is now a designed property rather than an accident, and it constrains the library: **any future support action stays in the 25–33 charge band.** Dropping a heal to Strike's 20 would quietly make healers the worst charge users in the game.

### 4.4 Persistence across fights — re-derived for v0.2

**Charge persists across fights within a leg of the road.** It resets to 0 on party wipe and on starting a new run. Benched units keep their charge.

Ian's question was whether longer fights weaken this argument, since a gauge that fills *within* one fight doesn't need to carry over. **It strengthens it**, because the relevant number is not fight length — it's actions *per unit* per fight, and adding party members divides that down faster than longer fights multiply it up:

```
Normal encounter: 20 beats, party of 5 (SPD ~100) vs 3 enemies (SPD ~92)

party turn rate = 5 / 100  = 0.05000 /tick
enemy turn rate = 3 / 109  = 0.02752 /tick
party share     = 0.05 / 0.07752 = 64.5%

party actions per fight = 20 * 0.645 = 12.9
actions PER UNIT        = 12.9 / 5   = 2.58
charge earned per unit  = 2.58 * 20  = 51.6
fights to fill a gauge  = 100 / 51.6 = 1.94
```

**A unit gets 2.58 actions per fight and needs 5 to charge.** If charge reset per fight, charge actions would fire *approximately never* — a unit would need a fight nearly twice as long as any normal encounter just to reach the gauge once. The mechanic would be decorative in exactly the way v0.1 feared, and more so at v0.2's party math than at v0.1's.

The character of the decision does change in one place, and it's worth naming: **at the boss length it becomes an intra-fight rhythm.** A 45-beat Named fight gives each unit `45 × 0.645 / 5 = 5.8` actions → ~1.16 charges *within* the fight, plus whatever was carried in. So charge is a between-fights resource in normal play and a within-fight resource against Named. That's a good split — it means Named fights have a pacing structure normal fights don't (§9.4).

**The prototype will not validate this decision**, and v0.1 was wrong to claim it would. Milestone 0 is 1v1, so Kesh takes *all* the actions and charges within the fight — the opposite of the shipping experience. Measured over 1,500 prototype runs:

| | Oaths per fight | Kesh actions per fight | Actions per Oath |
|---|---|---|---|
| persist **ON** | 1.75 | 10.69 | 6.12 |
| persist **OFF** | 1.58 | 11.42 | 7.21 |

Turning persistence off changes charge frequency by **11%**. Milestone 0 validates that a charge action *feels* like an event; persistence gets validated at Milestone 1 when the party exists. The debug toggle for "reset charge between waves" ships anyway so the tester can feel both — **but it will feel like it does almost nothing, and that is the correct result, not a bug.**

**v0.3 re-derivation with multiple enemies and a second unit.** Adding enemies raises total beats but adding party members divides the actions among more units, so the two pull in opposite directions. Measured:

| Configuration | Actions/unit/fight | Fights to fill a gauge | Persistence worth |
|---|---|---|---|
| v0.2 prototype (solo, 1 enemy) | 10.7 | 0.39 | +1.3% |
| solo, 3 enemies | 8.58 | 0.58 | **+6.9%** |
| **duo, 3 enemies** (hardest prototype config) | **5.68** | **0.88** | +2.3% |
| **shipping target (5 party, 3 enemies)** | **2.58** | **1.94** | — |

The prototype moved from 10.7 actions/unit to 5.68 — **the gap to the shipping case closed by 47%** — but it is still 2.2× the shipping value, so units continue to charge roughly once per fight and persistence stays hard to feel. The conclusion is unchanged and now better bounded: **§4.4's reasoning is sound, and it becomes testable at Milestone 1 with a party of five, not before.** Party size, not enemy count, is the variable that matters here.

Cost of persistence: the first fight after a wipe is the run's weakest. Acceptable, arguably good — it makes the fallback (§9.1) sting without taking anything permanent.

---

## 5. The gambit system

### 5.1 Grammar and screen

Each unit has exactly **two action slots**; each has an optional condition. That is the whole system.

```
┌──────────────────────────────┐
│  KESH                        │
│                              │
│  ① [ Foe: HP ≤ 30%    ▾ ]    │
│     [ Execute         ▾ ]    │
│                              │
│  ② [ — always —       ▾ ]    │
│     [ Strike          ▾ ]    │
│                              │
│  ⚡ Wayfarer's Oath           │
└──────────────────────────────┘
```

FF12's grammar is `target/condition → action`, evaluated top-down, first true condition wins ([FF12 gambit list](https://jegged.com/Games/Final-Fantasy-XII/Gambits/)). Farroad keeps the shape, cuts the condition list from ~100 to 12 and the slots from 12 to 2 — not for simplicity's sake, but because at 12 slots the optimal list converges and stops being a decision, and it doesn't fit a phone without scrolling.

### 5.2 Evaluation

```
chooseAction(unit):
    if unit.charge >= 100:
        return unit.chargeAction                      # §4.2, unconditional override

    if every slot has condition == NONE:
        i = unit.alternateFlag % n                    # ALTERNATE ①②(③)
        unit.alternateFlag = (unit.alternateFlag + 1) % n
        return slot[i].action

    for i in 0 .. n-1:                                # STRICT TOP-DOWN (v0.3)
        if evaluate(slot[i].condition, unit):         # NONE evaluates true, so an
            return slot[i].action                     # unconditional slot ends the list
    return STRIKE                                     # implicit floor, never removable
```

In plain language, for the tutorial:

1. **A full gauge always wins.**
2. **No slot has a rule → the unit alternates**, ①②(③). The user-specified default, and the best starting state: it teaches that both slots matter before it teaches conditions.
3. **Otherwise the list is read top down and the first slot whose condition holds wins.** An unconditional slot is always true, so **everything below it is dead**. This is FF12's rule and it makes ordering the primary expressive tool.
4. **Nothing matched → Strike.** Every unit has an invisible, unremovable `Strike` at the bottom, occupying no slot. A badly-configured party is *weak*, never *frozen* — which matters enormously when the player isn't watching.

Conditions are re-evaluated fresh every turn. No memory except `alternateFlag`.

**Why this changed in v0.3.** v0.2 checked all *conditional* slots first and treated an unconditional slot as the fallback wherever it sat. That was forgiving — it auto-rescued a list with the catch-all in position ① — but it made **slot order a no-op** whenever two slots differed in conditionality, contradicting §5.1's claim of FF12 semantics and leaving a reordering UI with nothing to do. Measured, the forgiving rule is worth **+2.8%** on a deliberately misconfigured list (10.66 vs 10.37 waves). That cost is paid deliberately: ordering that means something is worth more than automatic rescue, and the UI removes the mistake for free by greying out unreachable slots and labelling them *"⚠ unreachable — an unconditional slot above always wins."* Both orderings ship behind a toggle in the prototype.

### 5.3 Condition list (v0.3 — 18)

Each is one line and resolves both trigger and target.

**Foe** (action targets the matched foe)
`Foe: any` · `Foe: lowest HP` · `Foe: highest HP` · `Foe: HP ≥ 70%` · `Foe: HP ≤ 30%` · `Foe: 3+ present` · `Foe: most defended` · **`Foe: lacks this debuff`** · `Foe: not weakened`

**Ally** (action targets the matched ally, self included)
`Ally: HP ≤ 60%` · `Ally: HP ≤ 30%` · `Ally: lowest HP` · `Ally: 2+ wounded` (HP < 70%) · `Ally: is down` · **`Ally: lacks this buff`**

**Self**
`Self: HP ≤ 50%` · `Self: first turn`

Plus `— always —` as the unconditional entry, for 18 dropdown rows grouped under three headings — still one screen on a phone.

**`Foe: lacks this debuff` and `Ally: lacks this buff` are self-referential**: they read the status that *this slot's own action* applies, so one entry covers every debuff and every buff. This is what keeps the list short while making the whole status system addressable, and it is the condition that makes §3.5's refresh semantics matter — re-applying a live debuff is a wasted turn, and this is how the player avoids it.

**Targeting reconciliation.** A condition that names a target the action cannot use acts as a pure **trigger**, and the action falls back to its own default target. `Ally: HP ≤ 60% → Strike` means "when someone is hurt, attack" — not "attack your ally."

Deliberately absent: element weakness, foe-targeting-me, MP (there is none), charge thresholds (§4.2), numeric HP values. FF12 shipped ~100 conditions, most of them dead weight.

`Ally: lowest HP` and `Ally: HP ≤ 60%` are separate entries because the difference is the first real lesson in the system: the former always fires (the healer never attacks), the latter fires only when needed.

### 5.5 What the gambit system is actually worth

Measured over 11 builds, 300 runs each, each against its own no-condition twin (§VERIFICATION-v0.3 Part 1):

> **Mean gambit value: +2.7%. Positive in 7 of 11 builds. Negative in 4.**

That is far weaker than this doc previously implied, and the reason is precise: **gating an action that is good unconditionally strictly reduces its uptime.** Crit burst (−4.1%), Sustain (−5.9%), Charge spam (−2.3%) and Armour-breaker (−3.8%) all fail for that one reason — Flurry, Brace and Rally are simply better than Strike, so using them *less* costs you.

The system earns its keep in exactly two places, and the design now leans on both:

1. **Actions that are bad outside their window** (§6.0). Execute with a real floor penalty is worth **+17.1%** — by far the best gambit in the game.
2. **Targeting across multiple enemies** (§9.5). `Foe: lowest HP` versus the random default: **0%** at one enemy, **+16.2%** at two, **+7.5%** at three, plus 16–18% less damage taken. Focus-fire wins because killing an enemy permanently removes its share of incoming damage.

Neither of these existed in the v0.2 prototype — the first because no action had a real penalty, the second because there was only ever one enemy.

### 5.4 Exposure schedule

| Unlock | When | What appears |
|---|---|---|
| Two slots, no conditions | Mile 0 | Both unconditional. Player learns alternation by watching. |
| Condition dropdowns | Companion #1 (Mile ~5) | 3 only: `— always —`, `Foe: lowest HP`, `Ally: HP ≤ 60%` |
| +3 | Mile 40 | `Foe: HP ≤ 30%`, `Self: HP ≤ 50%`, `Foe: 3+ present` |
| +3 | Mile 110 | `Foe: HP ≥ 70%`, `Ally: HP ≤ 30%`, `Ally: lowest HP` |
| Remaining | Mile 220 | `Foe: any`, `Foe: highest HP`, `Ally: 2+ wounded`, `Self: first turn` |
| Presets | Second run | Save/load a full-party gambit set. Prestige-gated because it only matters on re-runs. |

---

## 6. Action library

Actions have **no resource cost.** There is no MP. Cost is paid in **rank** (turn frequency) and **opportunity** (two slots). This removes the worst idle-game failure state — the party standing around out of MP while the player sleeps — and makes rank a real currency.

Any unit can equip any standard action. `power` multiplies §3.1. `chg` is charge gained.

**All standard-action `power` values are unchanged from v0.1**, per §3.1's `K(1) = 25` construction.

### 6.-2 What a drop is actually worth (new in v0.6)

Hand size swept from 4 actions to the full library, everything else held constant, conditions scaling with hand size:

| Hand | Naive depth | Skilled depth | Gambit uplift |
|---|---|---|---|
| 4 | **9.0** | 9.0 | 0% |
| 6 | **9.0** | 9.25 | +2.8% |
| 10 | **9.0** | 10.8 | +20% |
| 16 | **9.0** | 11.25 | +25% |
| 25 | **9.0** | **15.0** | **+67%** |

> **The naive column is flat. A player who ignores the gambit screen gets nothing at all from drops — four actions and twenty-five produce identical depth.**

**Drops do not deliver power. They deliver gambit expressiveness.** Nothing in the pool beats the guaranteed trio on raw single-target DPT (Strike 1.00, Ember 1.00; Pierce ties, Flurry 1.03), so a builder that only asks "what hits hardest?" has its answer before it draws anything. Every drop is a *situational* tool, and a situational tool is worth zero without a condition attached to it.

This is the same fact as §6.-1's 18.7% drop-relevance figure, seen from the other side. Drops are not weak — they are the entire engine of progression for an engaged player, worth **+67%** at a full collection. They are inert for a player who never opens the gambit screen.

**Consequences for pacing and drop rates:**

- **Below hand 8 the gambit system is effectively inert** (0–2.8% uplift). A player forming their habits there will reasonably conclude the gambit screen is pointless.
- **It switches on at ~10 actions** (+20%) and keeps climbing to the full library with no observed plateau.
- **So front-load the first six or seven drops hard, then slow down.** The urgency is entirely in getting the player past the threshold where the central system starts doing something; after that the curve is still rising at 25, so there is no rush.
- **There is no collection size at which authoring more actions stops paying.** The limit is authoring effort, not design headroom.

**Levelling on duplicates was modelled and is not recommended as a fix for drop relevance.** Every variant tested (auto/convertible × power/behaviour) roughly **doubled the luck spread, 1.11× → 1.22×**, moved differentiation barely at all (5 → 6 distinct actions equipped), and left the naive line flat at 9.0 — so it does not even solve the problem it was proposed for, while reopening the lottery two passes were spent flattening. If it ships for a different reason (somewhere for late drops to go once the collection is complete) it should be **behaviour-at-thresholds, convertible, and must exclude the guaranteed trio** — otherwise everyone converges on the same levelled Strike/Ember/Mend. Behaviour is the right axis on measurement as well as principle: it added the least raw power per unit of variance introduced, and behaviour changes give the gambit system more to reason about, which is the half still carrying least weight.

### 6.-1 Drops, and the two guaranteed actions (new in v0.5)

**Actions and gambit conditions are random drops.** Not every player will hold every one. The design target, following Unicorn Overlord: broad viability bands, several valid counters to any threat, and equipment that changes a unit's *role* rather than ranking it — so a player succeeds with what they drew plus system understanding, rather than being funnelled to one build.

**Two actions are guaranteed and never drop: `Strike` and `Mend`.**

Strike was always the unremovable fallback (§5.2 rule 4). **Mend was added in v0.5 because simulation found healing was effectively mandatory** — subsets holding a heal reached 14.2 waves against 10.6 for those without, a **+3.6 wave** gap no amount of good play could close, and only half of random draws contained one. Guaranteeing it:

| | fully random draw | Strike + Mend guaranteed |
|---|---|---|
| p10 depth | 8.7 | **11.0** |
| **clear rate to wave 10** | **54%** | **100%** |
| luck gap (p90/p10) | 1.8× | **1.4×** |
| weak draw + skill vs strong draw + naive | loot wins by 4.8 | loot wins by 2.2 |

It costs nothing in build diversity — nobody was choosing *not* to run a heal — and it removes the only hard wall in the drop pool.

**The remaining gap is honest and unresolved.** Loot still edges skill by 2.2 waves. Every draw is now viable, but system mastery does not yet beat better loot. Closing it means narrowing the library's power band: the low-DPT utility actions (Dazzle, Smother, Daunt, Blur, all 0.38–0.43) need their floor raised, and Sear needs its ceiling trimmed. That is a repricing pass, not a measurement.

**A finding that constrains future balance work: action value is collection-dependent.** Cripple was the *best* build in v0.4's full-library test (+21.6%) and the *worst* contributor in a thin random draw (−3.2 waves), because with only 6 actions and 2 slots its 0.42 DPT is unaffordable. Balance judgements made against the full library do not transfer to a player holding a quarter of it.

### 6.0 The rule every situational action must obey

**A situational action needs a penalty outside its window, not just a bonus inside it.**

This is the single most important lesson from the v0.3 simulation pass and it was learned the hard way. v0.2's Execute was `×2.00 at ≤30% HP, ×1.00 above` — a bonus with no downside, which meant it was never actually *bad*, which meant gating it behind a condition only reduced how often you used a fine action. Measured:

| Execute variant | Value of the gambit that gates it |
|---|---|
| v0.2: ×2.00 / **×1.00** | +10.2% |
| **v0.3: ×2.20 / ×0.55** | **+17.1%** |

Four of v0.2's eleven testable builds had *negative* gambit value for exactly this reason (§5.5). The rule for any future action intended to pair with a condition: **it must be worse than Strike when the condition is false.** If it isn't, the correct play is to leave both slots unconditional and alternate, and the gambit UI is decoration.

### 6.1 Attack camp — 12 actions (ATK vs DEF, evadable)

| # | Action | Power | Rank | Chg | Target | Effect |
|---|---|---|---|---|---|---|
| 1 | **Strike** | 1.00 | 1.00 | 20 | 1 foe | Baseline. Free, always owned, also the implicit fallback. |
| 2 | **Pierce** | 1.15 | 1.10 | 25 | 1 foe | `defPierce 0.40`. The answer to armour. |
| 3 | **Cleave** | 0.65 | 1.20 | 25 | all foes | Worse than Strike against a single target — situational by construction. |
| 4 | **Flurry** | 0.42 ×3 | 1.20 | 30 | 1 foe | Each hit rolls crit/evade/block separately. The crit-build payoff and liability. |
| 5 | **Execute** | **2.20 / 0.55** | 1.15 | 25 | 1 foe | ×2.20 at target HP ≤ 30%, **×0.55 above it**. Pair with `Foe: HP ≤ 30%`. |
| 6 | **Guard Break** | 0.75 | 1.00 | 25 | 1 foe | Applies **Sundered**. Pair with `Foe: lacks this debuff`. |
| 7 | **Daunt** | 0.40 | 1.00 | 25 | 1 foe | Applies **Enfeebled** (ATK −25%). Defensive tempo. |
| 8 | **Cripple** | 0.45 | 1.10 | 25 | 1 foe | Applies **Slowed** — steals ~⅓ of the target's actions. The strongest debuff. |
| 9 | **Brace** | — | 0.70 | 33 | self | Applies **Bracing**. Fast + high charge: the charge-battery build. |
| 10 | **Vengeance** | **0.60 → 2.00** | 1.15 | 25 | 1 foe | `0.60 + 1.40 × missing HP`. Bad at full health. Pair with `Self: HP ≤ 50%`. |
| 11 | **Onslaught** | **1.80 / 0.70** | 1.20 | 25 | 1 foe | 1.80 on your first turn of a fight, 0.70 after. Pair with `Self: first turn`. |
| 12 | **Rally** | — | 0.80 | 40 | self | Applies **Surging** (chargeRate ×2.0). The charge-gain axis. |

### 6.2 Magic camp — 13 actions (MAG vs RES, never evadable, still blockable)

| # | Action | Power | Rank | Chg | Target | Effect |
|---|---|---|---|---|---|---|
| 13 | **Ember** | 1.05 | 1.05 | 25 | 1 foe | |
| 14 | **Gale** | 0.60 | 1.25 | 25 | all foes | |
| 15 | **Sear** | 0.55 | 1.05 | 25 | 1 foe | Applies **Burning**. Low direct damage; the DoT is the point. |
| 16 | **Hex** | 0.50 | 1.00 | 25 | 1 foe | Applies **Frail** (RES −25%). |
| 17 | **Smother** | 0.40 | 1.05 | 25 | 1 foe | Applies **Dulled** (MAG −25%). |
| 18 | **Dazzle** | 0.35 | 1.00 | 25 | 1 foe | Applies **Blinded** (+30% miss on the target's attacks). |
| 19 | **Siphon** | 0.85 | 1.15 | 25 | 1 foe | Heals the caster 50% of damage dealt. |
| 20 | **Mend** | 1.10 | 1.00 | 25 | 1 ally | Heal, no mitigation (§3.4). |
| 21 | **Renew** | — | 1.10 | 25 | 1 ally | Applies **Regen** (4 turns). Pair with `Ally: lacks this buff`. |
| 22 | **Recall** | — | 1.60 | 30 | 1 downed ally | Revive at 35% HP. Pair with `Ally: is down`. |
| 23 | **Bulwark** | — | 0.90 | 30 | 1 ally | Applies **Warded** (incoming ×0.60). |
| 24 | **Blur** | — | 0.90 | 30 | 1 ally | Applies **Blurred** (+0.20 evade). |
| 25 | **Quicken** | — | 1.30 | 30 | 1 ally | Applies **Hasted**. Clearest teacher of the turn-preview animation. |

Split 12/13. **All support and all healing lives in the magic camp**; the attack camp has no heal and no ally-targeted buff, only self-buffs (Brace, Rally) and debuffs. Intentional: an all-physical party is a real high-damage low-safety build rather than a strictly worse one, and it's what most players will run first.

**Debuff coverage** now spans every stat that matters — DEF (Guard Break), RES (Hex), ATK (Daunt), MAG (Smother), SPD (Cripple), accuracy (Dazzle) — plus a DoT (Sear). Every one of them pairs with `Foe: lacks this debuff`, and every one of them is *worse than Strike* on raw damage, so gating them is correct rather than costly.

**Healing coverage** spans burst (Mend), over-time (Renew) and recovery (Recall), plus mitigation (Bulwark, Blur) and self-sustain (Siphon). Charge values sit at 25–33 across the board, which matters: see §4.3.

### 6.3 Charge actions (unit-unique, not equippable, one per character)

**Retuned upward in v0.2.** v0.1's charge actions sat at ~1.8× a standard action's damage-per-tick, which made `chargeRate` worth only ~0.9% DPS per 10 points — an unbuyable stat. The balance target is now **≈3× a standard action's DPT against the encounter's expected 3 targets.** Single-target charge actions land near power 3.5; AoE charge actions near 1.8 per target.

| Character | Charge Action | Power | Rank | Effect | DPT vs Strike |
|---|---|---|---|---|---|
| Kesh (MC) | **Wayfarer's Oath** | 3.50 | 1.50 | 1 foe, physical, `critBonus +0.30` | 2.84× |
| Vey (rogue) | **Ninefold Rain** | 0.45 ×9 | 1.60 | random foes, physical, independent rolls | 2.53× |
| Ansa (healer) | **Hearthlight** | 2.20 | 1.40 | heal all allies, cleanse 1 debuff each | — |
| Dorrek (tank) | **Vow of Stone** | — | 1.30 | all allies **Warded** 3 turns; self taunts | — |
| Mirel (mage) | **Ashfall** | 1.80 | 1.70 | all foes, magic, applies **Burning** | 3.18× (vs 3) |

Rank climbs with breadth. Vow of Stone is rank 1.30 because a defensive charge that also costs tempo is a trap.

---

## 7. Party and companions

### 7.1 Composition

**MC + 4 active = 5.** Kesh cannot be benched. Launch roster: **12 companions.**

### 7.2 Recruitment pacing — **REPLACED in v0.9**

> **The mile-based schedule below is retired.** It pinned acquisition to distance travelled, which
> decoupled it from whether the player could actually field another unit. v0.9 ties recruitment to
> the difficulty curve instead, via two sources with different jobs.

**Source 1 — the post-boss drop is the PACING FLOOR.** One guaranteed unit after each boss, so
party size tracks depth on a fixed schedule (one per 20 waves) that §9 can be balanced against.
The first is always Ansa (healer), arriving after the wave-20 boss.

**Source 2 — Marks gacha is the ACCELERATOR.** Pulls cost Marks and can arrive at any time,
letting an engaged player outpace the floor. Never required; the floor is what difficulty assumes.

**This placement is measured, not chosen.** A solo character hits a hard wall at the 2-enemy
transition — capping enemies at 2 forever gives an identical result to the full ramp (20.75 mean,
p90 22), because a single unit cannot survive a 2-enemy fight regardless of what follows. The
wave-20 boss therefore lands exactly where solo play stops working, and the reward for clearing it
is the unit that answers the second enemy. Party growth and difficulty growth are the same curve.

Filling the cap by boss 4 (wave 80) remains deliberate: the interesting decisions are *swaps*, and
swaps don't exist until the bench does.

### 7.3 The bench (the Caravan)

Benched companions are **not** dead weight:

- **50% XP**, staying within ~3 levels of the active party, so a swap is never blocked by a level gap. This kills the worst emotion in a roster game — "I want to try her but she's 20 levels behind."
- Each contributes a **Road Gift**, a small always-on party passive (`+3% party max HP`, `+2% party chargeRate`, `+4% Aether find`). Gifts stack across the whole bench, so recruiting is always good even when the active five are settled.
- Equipped actions and gambit rules persist while benched.

**Swaps only at Waymarks**, which keeps the offline estimator valid over a stretch of road.

### 7.4 The Reason to embark

Chosen once at run start, from 5. Simultaneously a run modifier, a content filter, an ending, and the prestige axis.

| Reason | Run modifier | Road bias | Wish |
|---|---|---|---|
| **To bring back the dead** | Revive effects +20%; Kesh self-revives once at 25% HP per leg | more undead; undead take +25% from healing actions | resurrection |
| **To be remembered** | +15% XP, −10% party max HP | more Named; each Named grants a permanent +1% Aether find for the run | legend |
| **To end a bloodline** | +25% damage vs Named | Named +20% frequency, double Aether | vengeance |
| **To unmake a mistake** | 1 free Rewind per leg (restore to current Waystone, no cost) | more branching Waymarks, more side-nodes | undoing |
| **To see what's there** | +1 branch at every Waymark (3 not 2); +10% Aether find | more unique one-off nodes | the truth |

It matters in four ways, and should be pitched as all four:

1. **Immediately** — the modifier changes the first fight.
2. **Structurally** — it reweights the encounter table and the companion offer pool, so two Reasons meet different enemies and recruit different people.
3. **Terminally** — it determines the ending, each authored separately.
4. **Permanently** — completing a run under a Reason unlocks its modifier **at 25% strength, forever, on all future runs regardless of Reason.** This is the main long-term replay driver: a veteran runs a stacked passive set assembled from every ending reached.

---

## 8. Progression

### 8.1 Stats

**Primary (6):** HP, ATK, MAG, DEF, RES, SPD. **Secondary (5):** atkCrit, magCrit, chargeRate, block, evade.

| Stat | Base | Cap | Notes |
|---|---|---|---|
| atkCrit | 5% | **70%** | attack-camp actions (raised from 60% in v0.1) |
| magCrit | 5% | **70%** | magic-camp actions |
| chargeRate | 100% | **350%** | multiplies §4.1 |
| block | 3% | 50% | halves damage, works vs magic |
| evade | 3% | 40% | nulls damage, physical only |

Separate crit stats per camp is what makes a hybrid unit a real tradeoff. Caps exist because at 100% evade the game stops being a game; crit's cap rose to 70% so the crit track has the same ~10-node runway as the ATK track (§8.2).

Kesh at L1: HP 180, ATK 26, MAG 18, DEF 20, RES 16, SPD 100.
Growth/level (Kesh): HP +14, ATK +2.0, MAG +1.4, DEF +1.5, RES +1.3, SPD +1.0. Each companion has its own vector.

**Level = `1 + floor(mile / 8)`, capped at 60** (reached ~Mile 472). The cap is load-bearing; see §9.3.

### 8.2 Investment — Aether, and the marginal-value table

**Aether** drops from every fight and is the in-run currency for unit stats (§0 economy). Spent on a per-unit node grid, **11 tracks, one per stat**:

```
cost(unit, nth node bought on that unit) = ceil(30 * 1.09^n)
```

`n` counts every node on that unit, so a specialist and a generalist pay the same for their 20th node.

**Node yields are a percentage of the unit's level-adjusted base** — the stat it would have at its current level with zero Aether investment. This is a v0.2 fix: v0.1's "% of base" meant a +5% ATK node was worth +5% at L1 and +1.7% at L26, so Aether decayed into worthlessness as you levelled. Under the corrected rule, **every number in the table below is identical at every level**, which is the property that makes this table a design decision rather than a snapshot.

#### Offensive nodes — % gain in damage-per-tick

Reference build: Kesh, Strike/Strike, Wayfarer's Oath, no prior nodes in the tested stat. One cycle = 5 Strikes (rank 1.00) + 1 Oath (rank 1.50) = 650 ticks.

| Node | Yield | 1st node | **Simulated** | 10 nodes | Shape |
|---|---|---|---|---|---|
| **ATK / MAG** | +5% of base | +5.00% | **5.20%** | **+50.0%** | flat; the reliable buy |
| **chargeRate** | +25 pp (cap 350%) | +5.42% | **5.40%** | **+36.4%** | front-loaded; asymptotic |
| **atkCrit / magCrit** | +7 pp (cap 70%) | +4.64% | **4.65%** | **+43.1%** | mildly diminishing |
| **SPD** | +4% of base | +4.00% | **4.17%** | **+40.0%** | flat, plus an unmodelled tempo premium |

SPD measures 4.17% rather than 4.00% because §2.1's turn cost is an integer: `round(10000/104) = 96`, and `100/96 = 1.0417`. Real, minor, and worth knowing before anyone tunes SPD in single points — at SPD ≈ 100 each ±1 SPD is a ~1% step.

#### Defensive nodes — % gain in effective HP

| Node | Yield | 1st node | **Simulated** | Coverage |
|---|---|---|---|---|
| **evade** | +5 pp (cap 40%) | +5.43% | **5.41%** | physical only → **+3.80%** weighted at 70% physical encounters |
| **HP** | +5% of base | +5.00% | **5.00%** | everything |
| **DEF / RES** | +10% of base | +4.45% | **3.59%** ⚠ | physical / magic respectively; diminishing as DEF grows |
| **block** | +8 pp (cap 50%) | +4.23% | **4.28%** | everything, including magic |

⚠ **DEF is the one row simulation does not confirm at Milestone 0 magnitudes, and the cause is the floor, not the formula.** At L1 a wolf bite is 12 damage, so `floor()` quantizes into ~8% steps and a 4.5% mitigation change vanishes into rounding. Swept across levels the node reads 3.62% (L1) → 4.33% (L13) → 4.41% (L26) → 4.41% (L40) → 4.23% (L60), converging on the algebraic 4.4%. The same artifact mildly inflates ATK at L1 (5.19% → 4.98% by L60). **The table is right in the limit; the prototype is simply too small to measure DEF.** See VERIFICATION.md finding F3.

#### Is anything dominant?

**No, and the ordering flips between shallow and deep investment**, which is what makes allocation a real decision:

- **Whole menu spans 3.80% – 5.43% per node — a 1.43× band.** *Simulation: 3.59% – 5.41%, a 1.51× band. The entire difference is the DEF row's measurement artifact above; excluding it, simulated spread is 1.30×.*
- At **1 node** the best offensive buy is chargeRate (5.42%); at **10 nodes** it's ATK (50.0%) and chargeRate is last (36.4%). Charge rate is an opener, ATK is a closer.
- SPD is nominally the weakest offensive node at +4.00%, deliberately: it carries a real tempo benefit (acting before the enemy in a kill race) that this model doesn't price. Setting it to +5% would have made it strictly best, and in a CTB game everyone would stack it.
- **HP is *not* dominant among defensive nodes** because DEF/block/evade multiply with it. Verified: 10 HP nodes = 1.50× EHP; 5 HP + 5 DEF = `1.25 × 1.222 = 1.53×` EHP. **Mixed slightly beats pure**, which is the correct incentive. (v0.1's HP node at +6% did dominate at 1.60× vs 1.59×; it was cut to +5%.)
- **Pure DEF is correctly bad**: 10 DEF nodes = 1.44× EHP, below both, because `K/(K+DEF)` has diminishing returns. DEF is a good buy up to roughly parity with HP investment, then falls off — a real decision with a real wrong answer.

Two design changes were required to get here, both already folded into their sections: charge actions moved from ~1.8× to ~2.8× a standard action's DPT (§6.3), without which chargeRate was worth ~0.9% per 10 points; and the gauge stopped clamping at 100 (§4.1), without which chargeRate was a step function that usually bought nothing.

### 8.3 Run structure

A run is **5 Reaches**, each a procedurally-chosen **60–140 nodes**. Total **400–600 nodes**, ~5.2 days of real time at 12 h/day (§1.4).

**The player is never shown a total or a percentage.** They see `Mile 412 · The Ash Reach` and nothing else. No progress bars, no "Reach 3 of 5", no chapter counters. This is the concept's central fiction and every UI decision protects it.

Node weights: 62% encounter · 12% Waystone (auto-bank, save) · 10% Waymark (the only blocking node) · 8% rest (heal 40%) · 5% cache · 3% Named. Named are forced roughly every 50 miles.

### 8.4 Economy — now derived, previously guessed

```
aetherPerFight(mile) = round(8 * S(mile)^0.90)          # S from §9.2
encounters per mile  ≈ 1.2
```

v0.1 flagged these exponents as unverified. They now check out. Cumulative Aether to mile M:

```
∫₀^M 1.2 * 8 * (1 + m/100)^1.215 dm = 433.4 * [(1 + M/100)^2.215 - 1]
```

| Mile | Total Aether | Per unit (÷5) | Nodes affordable per unit |
|---|---|---|---|
| 400 | 14,900 | 2,980 | **26.6** |
| 600 | 31,900 | 6,370 | **34.8** |

At 26.6 nodes with ~40% into ATK, that's 10.6 ATK nodes = **+53% ATK at Mile 400** — which is the `+55%` figure §9.3's wall calculation assumes. The economy is self-consistent.

The important consequence: **Mile 400 → 600 buys only 8 more nodes** (26.6 → 34.8) while enemies get 1.57× stronger. That gap is the wall, and combined with the level cap it lands where §8.3 wants it. Still worth confirming by simulation before ship, but it is no longer a guess.

### 8.5 Prestige

A run ends by reaching the road's end (rare), taking a third wipe at one Waystone (§9.1), or the player electing to end it.

**Carries over:** **Wishlight** = `floor(deepestMile/10) + 50 × ReachesCleared + 200 if completed`, spent on a small permanent tree (starting level, starting Aether, extra bench slots, +1 starting action, Waymark rerolls) · every companion ever recruited · every action ever unlocked · every gambit condition ever unlocked (so run 2 opens with all 12) · every completed Reason's modifier at 25% · gambit presets.

**Resets:** unit levels, all Aether spending, current Aether, party, mile position, charge gauges, the Reason.

The asymmetry is the point: **knowledge and options carry, power does not.** Run 2 is faster because you open with the full gambit vocabulary, the whole action library, and a roster you know — not because your numbers are bigger. Numbers return only via Wishlight, slowly.

---

## 9. Failure and pacing

### 9.1 Wipes

All 5 active units at 0 HP. **Not** a run reset.

```
onWipe:
    run.position = last Waystone
    all units revived at 50% max HP
    all charge gauges = 0
    lose 30% of unbanked Aether          # banked = everything at the last Waystone
    wipeCount[thisWaystone] += 1
    if wipeCount[thisWaystone] >= 3:  END RUN (full Wishlight payout)
```

Waystones every ~10 nodes and auto-bank, so a wipe costs at most ~10 nodes of travel and ~3 nodes of Aether.

The **three-strikes rule** is the pacing valve and the most important rule here. Without it an under-powered player grinds one Waystone forever — the death state of every idle RPG. With it, the run ends on its own at exactly the point progress stopped, converts to Wishlight, and the next run starts stronger. It pays out **in full**, so it reads as a chapter closing, not a punishment. `wipeCount` resets on passing a new Waystone, so it only accumulates against a real wall.

Offline never wipes (§1.4).

### 9.2 Difficulty scaling — retuned for constant fight length

Ian's target is 15–20 s normal fights *throughout the run*, not just at Mile 0. v0.1's exponents (`HP S^1.15`, `ATK/DEF S^0.95`) grew enemy HP 1.58× faster than party damage, so a 20-beat fight at Mile 0 became a 32-beat fight at Mile 400 — out of band and into boss territory. Solved for the exponent that holds beats flat:

```
S(mile) = (1 + mile/100) ^ 1.35

enemy.HP      = base.HP  * S^0.84      # was S^1.15
enemy.ATK/MAG = base.ATK * S^1.02      # was S^0.95
enemy.DEF/RES = base.DEF * S^0.98      # was S^0.95
enemy.SPD     = base.SPD * (1 + mile/2000)     # very shallow; SPD arms races are miserable
```

| Mile | S | HP × | ATK × | DEF × | Party dmg × | **Beats/fight** |
|---|---|---|---|---|---|---|
| 0 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | **20.0** |
| 100 | 2.55 | 2.19 | 2.62 | 2.50 | 2.13 | **20.6** |
| 200 | 4.41 | 3.44 | 4.55 | 4.28 | 3.40 | **20.2** |
| 400 | 8.78 | 6.20 | 9.17 | 8.41 | 6.15 | **20.2** |
| 472 (cap) | 10.4 | 6.98 | 11.0 | 10.0 | 6.90 | **20.2** |

Party damage column accounts for level growth, `K(L)` growth, and the §8.4 Aether investment. **Fight length holds at 20 ± 0.6 beats from Mile 0 to the level cap.** ✓

Survivability is flat by the same construction: enemy ATK grows 9.17× to Mile 400 against party EHP growth of ~9.1×. That is intentional — with one throttle instead of two, the run's difficulty comes from a single legible source (§9.3) rather than from a creeping stat gap the player can't see.

Named enemies: `S(mile) × 1.35` on HP, `× 1.15` on offense, ≥1 status immunity.

### 9.3 Where the wall actually is

With §9.2 near-neutral, nothing in the scaling curve ends a run. The wall comes from **the level cap at 60 (Mile 472)**. Past it, automatic growth stops and only Aether spending continues — and §8.4 shows Aether buys just 8 more nodes across the next 200 miles.

| Mile | Player ATK | Enemy DEF | Player dmg | Enemy HP | Beats/fight |
|---|---|---|---|---|---|
| 400 | 193 | 101 | 106.7 | 6.20× | 20.2 |
| 500 | 218 | 121 | 110.5 | 6.75× | 22.8 |
| 600 | 244 | 158 | 116.2 | 9.08× | **27.2** |

Fights lengthen past the cap while incoming damage rises ~1.6× against near-static EHP. The run becomes unwinnable somewhere around **Mile 500–620**, which is §8.3's target. Composition contributes texture on top: deeper Reaches run 4–5 enemies instead of 3, and Named appear more often.

This is a better structure than v0.1's, because the wall is now **one thing, in one place, with a stated cause** — you stopped levelling — rather than an emergent gap between two exponents nobody can see.

### 9.4 What carries a 40–65 beat Named fight

Ian's question: at that length, is a boss just a stat check? It would be with the normal-encounter ruleset, so Named get four things normal enemies don't:

**Phases**, keyed on HP thresholds (100–66%, 66–33%, 33–0%). Each changes the Named's action set and one global rule. Phase 2 typically summons 2 adds — which is the moment `Foe: 3+ present` and every AoE action in §6 abruptly matter, mid-fight, without the player touching anything. Phase 3 typically enrages (the Named gains Hasted) or applies a party-wide debuff.

**Charge spikes.** The Named uses the same gauge. A 45-beat fight gives it ~15 actions → **3 charge actions**, each telegraphed in the turn preview one Beat early. On the party side, `45 × 0.645 / 5 = 5.8` actions per unit → **~5 party charge actions**. So a boss fight contains **~8 telegraphed spikes across 45 beats, one every ~5.6 beats** — that is the rhythm, and it is derived from the same numbers as everything else, not bolted on.

**A counter-rule** per Named that punishes a naive build: *"gains 20 charge whenever it takes a critical hit"* makes a crit-stacked party actively worse and is the clearest possible teaching moment for why §8.2's band matters.

**Status immunities**, 1–2 each, so a single debuff loadout can't be the universal answer.

Between phases, adds, and 8 charge spikes, a 45-beat Named fight has roughly one state change every 5 beats. If playtesting shows it still reads as a slog, the fix is fewer beats (raise Named damage), not more mechanics.

### 9.5 Enemy count — a difficulty axis (rewritten in v0.4)

**Enemies are full strength regardless of how many there are. Party size is the answer to enemy count.**

```
perEnemyHP  = enemyBaseHP × dmgTakenMul(archetype) × S(mile)^0.84
perEnemyATK = baseATK × S(mile)^1.02                      # no count term anywhere
matchedParty(E) = round(5E/3)                             # 1 enemy → 2, 2 → 3, 3 → 5
```

`dmgTakenMul` is retained: it equalises *archetypes* so armour and evasion change texture rather than time-to-kill. That is a separate concern from count.

**Pressure grid** — median beats / seconds / % of party HP pool lost. `*` = matched party.

| | 1 enemy | 2 enemies | 3 enemies |
|---|---|---|---|
| **party 1** | 17b / 14.7 s / 29% | 45b / 31.1 s / **87%, wipes 49%** | **WIPES** |
| **party 2** | *16b / 14.0 s / 5%* | 36b / 26.6 s / 10% | 70b / 41.1 s / 26% |
| **party 3** | 15b / 13.3 s / 4% | *35b / 26.0 s / 4%* | 65b / 39.1 s / 6% |
| **party 4** | 14b / 12.6 s / 2% | 30b / 23.4 s / 2% | 52b / 33.4 s / 5% |
| **party 5** | 12b / 11.0 s / 1% | 27b / 21.6 s / 4% | *39b / 28.1 s / 1%* |

Waves survived: party 1 clears **2.9 / 0.7 / 0** against 1 / 2 / 3 enemies; party 2 clears **22.7 / 12.5 / 6.5**; party 5 clears **37.7 / 29.5 / 24.1**.

**The solo failure threshold is two enemies.** A lone unit wipes on the first two-enemy wave half the time and cannot clear a three-enemy wave at all. Adding one companion restores survivability more than tenfold.

**Count is keyed to mile, and tracks recruitment (§7.2):**

| Mile | Enemies | Party | Ratio | |
|---|---|---|---|---|
| 0–5 | 1 | 1 | 1.0 | scripted solo window — must stay easy |
| 5–30 | 1 | 2 (Ansa at Mile 5) | 2.0 | matched |
| 30–60 | 2 | 3 (#2 at Mile 22) | 1.5 | slightly under |
| 60–95 | 3 | 4 (#3 at Mile 55) | 1.33 | **the run's tightest stretch** |
| 95+ | 3 | 5 (#4 at Mile 95) | 1.67 | matched |

**Recruitment always precedes the pressure** — by 25 miles at the first step and 5 at the second. Two things to hold onto: Miles 0–5 are a real solo window and a solo unit survives only ~2.9 waves even at one enemy, so that stretch stays scripted; and Miles 60–95 is a deliberate trough that motivates the final recruit, which should be tuned on purpose rather than left to fall out.

**§9.2 is reactivated by this change.** Count is a multiplicative difficulty term the exponents don't model: across the early game count alone multiplies encounter difficulty ~3× while party growth multiplies party power ~4–5×. Those roughly cancel — but only because the two ramps are aligned, so **moving either one breaks the early game.** The rule that follows: **early difficulty comes from count, late difficulty comes from stats, and the two must never stack.** Hold `S(mile) ≈ 1` until the party fills around Mile 95, then resume the curve. One axis at a time, each legible.

### 9.6 Enemy archetypes and their answer sets (new in v0.5)

**The anti-meta rule: every enemy threat must demand a *category* of response with at least three valid answers drawn from different parts of the library — never a specific action.** Under random drops, any encounter requiring one particular action is a hard wall for every player who never dropped it.

| Enemy | Threat | Valid answers — any one suffices |
|---|---|---|
| **Roadwolf** | baseline; focuses whoever is wounded | ① raw damage ② healing to deny the focus ③ Warded/Bracing on the wounded unit ④ kill it fast |
| **Barrow Knight** | DEF 34 makes physical inefficient | ① armour pierce (Pierce) ② **any magic** — hits RES 20, not DEF 34 ③ DEF debuff (Guard Break) ④ sustained damage at a time cost |
| **Mire Hound** | SPD 124, evasive, dives the back rank | ① Slow (Cripple) ② burst it down — it has the lowest HP pool ③ defensive on the back rank (Bulwark/Blur/row swap) ④ Blind it (Dazzle) |
| **Stone Ox** | attrition, ATK 28 | ① sustain (Mend/Renew/Siphon) ② mitigation (Bulwark/Brace) ③ ATK debuff (Daunt) ④ out-damage it |
| **Fen Priest** | heals other enemies; spread damage never kills | ① focus it ② burst past the heal ③ Dulled (Smother) cuts its healing ④ **AoE** hits it while hitting everything |
| **Thorn Shrike** | retaliates 6% max HP against any AoE | ① single-target it ② kill it first ③ mitigate the reflect (Warded/Bracing) ④ eat it and heal through |

Two choices keep these from becoming walls:

- **The Fen Priest has the lowest max HP in the game**, so *default* targeting finds it without the player owning `Foe: lowest HP`. Focus-fire is faster; its absence is not a wall.
- **The Thorn Shrike removes an option rather than requiring one.** A player whose only damage is AoE still clears — measured at 8.5 waves against 12 for single-target, so the reflect *costs* without *blocking*.

**Verified, not asserted.** A party of three whose only notable action is one answer, against two of that archetype: every answer for every archetype cleared the 12-wave test band, the lowest being AoE-vs-Shrike at 8.5. **No enemy walls any single answer.**

**Enemy stat lines**: Roadwolf baseline · Barrow Knight DEF 34, blocks · Mire Hound SPD 124, evasive, fragile · Stone Ox HP ×1.6, ATK 28, SPD 70 · Fen Priest HP ×0.55, MAG 24, heals allies · Thorn Shrike RES 26, 6% thorns.

---

### 9.5-old Enemy count as a tactical axis — SUPERSEDED (v0.3)

Encounters ramp in size:

```
enemyCount(wave) = min(3, 1 + floor((wave - 1) / 3))     waves 1–3 → 1, 4–6 → 2, 7+ → 3
```

Each encounter *shape* gets a full three-wave block before the next appears, so the player meets single-target, pair and group combat in sequence rather than all at once. **Capped at 3** because 3 is the shipping normal-encounter size that §4.4 and §9.2 both assume; ramping past it would validate a shape the game never ships.

**The problem.** Naively adding enemies destroys the 15–20 s target. Solo Kesh's share of the turn queue falls from 52% (1 enemy) to 27% (3), so a fixed-HP encounter goes from 18 beats to ~43.

**The fix — normalise the encounter budget against turn share, not against count:**

```
share       = Σ(1 / partyTurnCost) / ( Σ(1 / partyTurnCost) + Σ(1 / enemyTurnCost) )
encounterHP = targetBeats × share × dpa           # dpa = party's mean damage per action
perEnemyHP  = encounterHP / E × dmgTakenMul(archetype) × S(mile)^0.84
perEnemyATK = baseATK × E^-0.55 × S(mile)^1.02
```

`dmgTakenMul` folds an archetype's DEF mitigation, evade and block into one number, so armour, evasion and speed change **texture** without changing time-to-kill. The `E^-0.55` exponent was fitted, not derived: at `E^-0.35` a three-pack dealt 2.07× the incoming damage of a single enemy (too hard), at `E^-1.0` it dealt 0.37× (too easy, because focus-fire removes attackers). Measured result, 500 runs per cell:

| | 1 enemy | 2 enemies | 3 enemies |
|---|---|---|---|
| Solo | 21 beats · **17.9 s** · 104 damage taken | 21 · **17.9 s** · 92 | 20 · **17.2 s** · 76 |
| Duo | 18 beats · **15.8 s** · 22 | 19 · **16.5 s** · 13 | 19 · **16.5 s** · 43 |

**Fight length holds at 15.8–17.9 s across every party×enemy combination**, inside the §1.1 target.

**Two consequences, both wanted:**

- **`S(wave)` needed no change.** Because the normalisation holds both beats and damage-taken flat, enemy count adds no difficulty of its own, so §9.2's exponents remain the sole difficulty term. This was the knock-on that looked most dangerous and it dissolves once the budget is normalised against turn share rather than count.
- **Multiple enemies are where the gambit system earns its keep.** Damage taken drifts *down* as count rises because killing an enemy permanently removes its share of incoming damage — so focus-fire is worth 16.2% fewer beats and 18.1% less damage at two enemies, versus **exactly zero** at one (§5.5). Group combat is not harder; it is where targeting becomes a decision.

**Enemy archetypes** (four, rotating through waves so mixed groups appear automatically): **Roadwolf** baseline · **Barrow Knight** DEF 34, blocks — the case for Pierce and magic · **Mire Hound** SPD 124, evasive, fragile — distorts the turn queue · **Stone Ox** high HP, ATK 28, SPD 70 — attrition. HP is normalised per archetype so all four die in comparable time despite very different defensive profiles.

---

## 10. Prototype scope — Milestone 0

**One scene. Kesh alone versus a queue of Roadwolf Alphas, one at a time, until he dies.**

The prototype answers one question: **does an auto-resolving CTB fight read as a fight, or as a spreadsheet scrolling?** Everything not needed for that is out.

### 10.1 Prototype stat blocks and why they differ from the game

The shipping game's normal encounter is **3 enemies vs a party of 5**. The prototype is 1v1, so two numbers are overridden:

```
Shipping:   party of 5, ~113 HP avg/unit (567 total); Roadwolf 95 HP, ATK 22
            → 20 beats, party takes ~85 damage = ~15% of pool per fight

Prototype:  Kesh alone must BE the party        → HP 900  (carries the party's HP budget)
            One wolf must BE the encounter      → HP 210  (≈ 3 wolves' worth, minus AoE inefficiency)
            → 19 beats, Kesh takes 108 = 12% of pool per wave → ~7 waves before death
```

Everything else is the shipping value. All damage numbers in §3.6 are computed from these.

### 10.2 In scope

| System | Spec | Why |
|---|---|---|
| CTB scheduler | §2.1–2.2, min-heap, integer ticks, FFX tiebreak | The thing being tested |
| Action Rank | §2.3; values 0.70 / 1.00 / 1.10 / 1.50 | Rank is meaningless until a slow action visibly costs you a turn |
| Beat + ramp | §2.4 full ramp (900/700/550) + 1×/2×/4× toggle | Pacing is a wall-clock question and the ramp is new and unproven |
| Turn preview | §2.5, 6 chips, with the reorder slide | If the preview doesn't read, nothing else matters |
| Physical damage | §3.1 physical branch, `K(L) = 23 + 2L` | |
| Variance | §3.2 | To judge whether ±5% is tight enough |
| Crit / block / evade | §3.3 full order, physical only | The entire texture of an auto-fight |
| Charge gauge | §4.1 **including overflow carry**, §4.4 persistence, **plus a debug toggle to disable persistence** | Overflow-carry is new; persistence can't be validated at 1v1 (§4.4) but can be felt both ways |
| Two action slots | §5.2 rules 1, 2, 4 (charge override, alternate-when-unset, implicit Strike) | The default is what most players will ever see |
| Actions | **Strike, Pierce, Brace** + **Wayfarer's Oath** | One baseline, one that beats armor, one fast/high-charge. Enough to make slotting a real choice. |
| Wave scaling | `S(wave) = 1.06^(wave-1)` through §9.2's exponents | A ramp, so the run has an ending |
| Wipe | Restart at wave 1, show max wave reached | |
| Debug overlay | tick clock, both `nextActAt`, every roll, every intermediate damage term, **live DPT readout** | Non-negotiable. The DPT readout is how §8.2's table gets verified. |

### 10.3 Deferred

Gambit conditions (all 12) · companions and the party of 5 · bench and Road Gifts · magic camp and the MAG/RES branch · healing · all statuses · all other charge actions · offline simulation and auto-invest · Aether, levelling, node grid · path, nodes, Waymarks, Waystones · travel time · Reasons · prestige and Wishlight · multi-enemy encounters and AoE · Named phases · art, audio beyond placeholder hit-stings, meta screens, monetization.

Multi-enemy is deferred as one unit of work, not three: AoE, targeting rules, and the whole `Foe:` condition family all become necessary the moment there are two enemies. That's Milestone 1.

### 10.4 Success criteria

The prototype fails if it misses these.

1. **A wave resolves in 15–20 s.** *Measured over 5,000 runs: median 16.5 s, mean 15.71 s, p5–p95 = 11.7–19.3 s, **70.7% inside 15–20 s**.* In beats: median 19, p5–p95 = 13–23, full range 11–33 — so the "17–22 beats" figure stated elsewhere in this doc holds only 60.9% of the time and **the target should be read in seconds, not beats.** The spread is driven almost entirely by the Oath: its 35% crit swings mean fight length by 27% (8.11 vs 10.32 Kesh actions), and its 5% chance of being evaded outright swings it comparably. This is a 1v1 artifact — with 5 units the same variance averages across the party. See VERIFICATION.md finding F2.
2. **A watcher can name the next actor from portraits alone**, without reading the rail's text, within 3 waves.
3. **Swapping slot ② Strike → Pierce changes TTK by ≥15%** against an armored variant (Roadwolf DEF 30). *Measured: **+40.5% DPT**, and **−25.0% time-to-kill** over 600 seeds.* Strike `floor(26 × 25/55) = 11` over 100 ticks = 0.110; Pierce `floor(1.15 × 26 × 25/43) = 17` over 110 ticks = 0.155. An earlier draft of this line said +33.7% by taking the ratio *before* §3.3 step 7 floors; the floor rounds Strike down harder (−6.9%) than Pierce (−2.2%), so the real figure is higher. Criterion met either way. See finding F4.
4. **The charge action fires every 5th–6th Kesh action** and reads as an event — own sound, own camera, preview glow at least one Beat early, every time.
5. **The §8.2 marginal-value table reproduces.** ✅ *Done — see §8.2's Simulated column.* ATK, chargeRate, atkCrit, SPD, HP, evade and block all land within 0.2 pp of prediction. **DEF is excluded from this criterion**: at L1 magnitudes the damage floor swamps it (finding F3), so it can only be checked once levels exist, at Milestone 2.
6. **At 4× speed the fight is still legible**: you can tell who acted and roughly what happened.
7. **Ten consecutive waves are watchable without the tester reaching for the speed toggle out of boredom.** This is the real test. If it fails, the problem is beat length or damage-number presentation, not the math.

---

## 11. Open questions — genuine forks

Decisions where the doc picked a side but the other side is defensible and reversal is expensive. Everything else should be treated as settled.

**Q1. Does taking a hit fill the charge gauge?**
Currently no — own actions only, per the original concept. §4.4's new math sharpens the cost: at **2.58 actions per unit per fight**, a tank that gets focused down all fight still charges no faster than anyone else, and Dorrek's entire kit is a charge action. `+6 × chargeRate` per hit taken is the standard fix. It complicates the offline estimator and makes charge timing depend on enemy behavior rather than loadout. **Decide before Milestone 1**, when the tank exists.

**Q2. Two action slots, or three? — ANSWERED in v0.6: two.**
Swept against collection size, which was the remaining unknown. A third slot is **slightly worse at a large hand** (10.67 vs 11.00 with the full library) and **identical at a small one** (10.00 vs 10.00), matching v0.3's independent result (12.16 vs 10.69). The reasoning is now clear: slot count was never the binding constraint. The constraint is that **every conditional slot costs uptime on your best unconditional action**, and under top-down evaluation an extra rule fires often enough to crowd out damage. Adding slots makes that worse, not better. A larger collection pays off through *better selection of which two things to equip*, not through equipping more — so there is no collection size at which a third slot starts to earn its place. **Closed. Two slots, and the alternate-when-unset default stays coherent.**

*Superseded framing, kept for the record:*

**Q2-old. Two action slots, or three?**
Two is chosen for the phone screen and for the alternate-when-unset default. Three would allow the natural FF12 shape (opener → conditional → fallback) at ~90 px more. **Still the single biggest fork**, and it can't be changed later without redoing the UI, tutorial and unlock schedule.

*v0.3 evidence, not a verdict:* the default generalises fine to N slots (alternate becomes ①②③), so that is no longer an argument for two. But a third slot is **not** a free win — adding `Foe: lacks this debuff → Guard Break` to the best two-slot build made it **12% worse** (12.16 → 10.69 waves), because a 0.75-power action displaced a 1.15-power one. Combined with §6.0, the case for three slots strengthens only as the library gains more actions with genuine downside. The prototype ships a 2/3 toggle; decide from feel, and note that the measurement above is confounded by the choice of third gambit.

**Q3. Is `K(L) = 23 + 2L` the right coupling? (new in v0.2)**
Keying the mitigation constant to the *acting* unit's level means an under-levelled attacker is penalized twice — low ATK *and* low `K`. That's intentional (level gaps should matter) but it makes level a hidden third offensive stat that never appears in §8.2's table, and it means a benched companion brought back at −3 levels is worse than their stat sheet implies. The alternative — keying `K` to the *defender's* level, or to a global per-Reach constant — is flatter but decouples `K` from the thing it's meant to track. **Check the magnitude before Milestone 2**; if the double penalty exceeds ~15% at a 5-level gap, switch to a global constant.

**Q4. Does charge persistence survive contact with the boss length?**
§4.4 now says charge is a between-fights resource in normal play and a within-fight resource against Named. That's a good split on paper, but it means a player who arrives at a Named with five full gauges opens with five charge actions — potentially deleting phase 1 before any mechanic fires. Mitigations exist (Named phase 1 could have a damage floor, or gauges could soft-cap entering a Named) but they're all inelegant. **Watch for it in Milestone 2**; the exploit shape is real and the fix is not obvious.

**Q5. Is the run's unknown length satisfying, or just opaque?**
The no-progress-bar fiction is the concept's core, but idle players will have mile counts on a wiki within a week. The alternative is making the length genuinely *responsive* — the road ends when the player's power curve flattens, not at a fixed node count. §9.3 actually gets closer to this than v0.1 did, since the wall is now a single legible cause rather than an emergent gap. **Decide before the first public build.**

**Q6. Should the Reason be re-selectable mid-run?**
Locked at run start. Allowing a change at a Reach boundary would soften wrong-pick anxiety but gut the §7.4.4 replay incentive. Leaning strongly toward keeping it locked.

**Q7. Where does monetization attach?**
Deliberately unaddressed, and should stay so until the loop is proven — but it constrains §8 and now §1.4. The natural attachment points are the offline cap (12 h → 24 h), **travel speed** (new in v0.2, and the most obviously monetizable thing in the game now that travel is the throttle), and Wishlight. All three are load-bearing for pacing. **Do not tune the economy to a final state before this is answered.**

**Q9. What is a Named fight now that a normal encounter is 28 seconds? (new in v0.4)**
§9.5's reversal means a full-size normal encounter runs **28 s**, not 15–20. §9.4 sized Named fights at 2–3× a normal fight, which now implies **60–85 s** — almost certainly too long for a phone, and long enough that the four-tier beat ramp is already running at its 400 ms floor for most of it. Three ways out, none obviously right:
(a) **Named fights get fewer, bigger units** — one Named plus two adds instead of a Named plus a full group, so the beat count stays near a normal encounter while the threat rises.
(b) **Named fights are 1.3–1.5× a normal encounter** (36–42 s) rather than 2–3×, and carry their weight through phases and mechanics rather than length. §9.4 already argues the pacing comes from ~8 telegraphed spikes, not from duration.
(c) **Accept 60 s Named fights** as a deliberate once-per-50-miles set piece, and lean on the speed toggle.
Leaning toward (b). This needs deciding before §9.4's phase structure is built, since it sets the beat budget the phases have to fit inside.

**Q8. Should a charge action be evadable? (new — raised by the prototype)**
It currently is, and at the default seed the very first Wayfarer's Oath rolled 0.04 against the wolf's 5% evade and dealt nothing. Five actions of gauge, the fight's biggest telegraphed moment — §2.5 glows the portrait a full Beat in advance — erased by a roll the player cannot influence. The game makes a promise and then doesn't keep it. Options: exempt charge actions from evade entirely; give them a partial-damage floor when evaded; or keep it as a rare, memorable bad beat. It also matters for pacing: at 1v1 the Oath is ~25% of Kesh's damage, so nulling it swings fight length ~25% (finding F2). **This is precisely the feel question Milestone 0 exists to answer — decide from playtest, not from the table.**

---

## Sources

- [FFX-Info — CTB](https://grayfox96.github.io/FFX-Info/game-mechanics/ctb) — Base CTB / Agility table, `CTB = Base CTB × Action Rank`, tiebreak ordering, haste/slow/delay as CTB modifiers.
- [FFX-Info — Damage, crit, escape and ICV](https://grayfox96.github.io/FFX-Info/rng/damage-crit-escape-icv) — the `(rand(0..30)+240)/256` variance roll; ICV initialization.
- [Final Fantasy Wiki — FFX battle system](https://finalfantasy.fandom.com/wiki/Final_Fantasy_X_battle_system) — CTB overview, Act List, Rank 1–8.
- [Jegged — FF12 Gambits](https://jegged.com/Games/Final-Fantasy-XII/Gambits/) — full condition list, top-down first-true-wins evaluation, fallback-at-the-bottom convention.
- [Deconstructor of Fun — AFK Arena](https://www.deconstructoroffun.com/blog/2019/6/6/afk-arena-puts-lilith-into-the-billionaire-club) — automated combat with choice moved out of the fight; no energy gate.
- [Clicker Heroes blog — offline idle games](https://blog.clickerheroes.com/top-offline-idle-games-in-2025/) — offline cap conventions (12 h vs Melvor's 24 h), "return value" over time-gating.
- [RPG Maker forums — damage formulas](https://forums.rpgmakerweb.com/threads/what-damage-formulas-do-you-use.138968/) — ratio vs subtractive mitigation; the `k/(k+DEF)` form and why the constant matters.
- [Bugnet — roguelite meta-progression](https://bugnet.io/blog/how-to-design-a-roguelite-meta-progression) — permanent-unlock vs permanent-power split across runs.
