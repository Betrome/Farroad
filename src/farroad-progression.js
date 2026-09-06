
/* =============================================================================
 * v0.9 PROGRESSION — bosses, checkpoints, curated onboarding, economy.
 * ========================================================================== */
window.FarroadProgression=(function(C){
'use strict';var P={};
P.BOSS_EVERY=20; P.BOSS_LEN=1.40;         /* 1.3-1.5x a normal fight (Q9) */
/* ===== BOSS SCHEDULE — the economy sets boss 2 =====
 * Boss 2 is placed at the wave where accrued Marks first cover one pull at the
 * shipped 700 cost. Measured across four seeds that is wave 22, identically
 * (728 / 749 / 761 / 730 Marks banked). Putting it there means pulls unlock
 * BEFORE the wave-28 wall, so the wall never forms: w28 goes 23% -> 100% and
 * runs reaching wave 45 go 0/16 -> 13/16.
 *
 * Boss 2 at 22, 24 and 26 all measure IDENTICALLY, so there is slack — see the
 * recommendation in VERIFICATION about using 26 for rhythm rather than 22.
 *
 * Boss 3 onward returns to a FIXED 20-wave interval. The economy rule solved a
 * one-off bootstrap problem (no pull income exists before the first unlock);
 * after that Marks flow continuously and a schedule the player can anticipate is
 * worth more than one that drifts with their spending. */
/* v2.2: wave 22 RETIRED. It was derived from the OLD Marks economy (pull cost 700,
 * banked Marks first crossing it at w22) to solve a wave-28 wall — and both the
 * economy and the wall were artefacts of the pre-rescale curve. Re-measured under
 * v2.1: the w28 wall is GONE (88% then 100% at w30), because enemy scale is now
 * DEFINED as the player's own multiplier and cannot outrun them. With no bootstrap
 * problem there is no reason for a special case, so boss 2 returns to the regular
 * cadence at wave 40 and the schedule is simply "every 20 waves". */
P.BOSS_WAVES=[20];
P.bossWaveAt=function(i){
 if(i<P.BOSS_WAVES.length)return P.BOSS_WAVES[i];
 return P.BOSS_WAVES[P.BOSS_WAVES.length-1]+P.BOSS_EVERY*(i-P.BOSS_WAVES.length+1);};
/* ===== MARKS (v1.0 — the loop is live) =====
 * Tuned so pulling is a felt cadence rather than a screen: first pull lands at
 * about wave 22, just after the boss, then roughly one every 3 waves. Measured
 * over waves 21-40: 7 pulls, median gap 3, units arriving w22 / w27 / w31.
 * Cheaper (cost 400) floods three units into w21-24; dearer (1100) delays the
 * first pull past the wave-28 wall and drops clear rate to 46%. */
/* Pull cost scales with the wave curve, or pulls become free at depth. */
/* v2.2 CORRECTION: last pass I measured and reported "cost 300×S, units 1-in-4"
   for the roster retune, then shipped 700 and 1-in-14 — the measured values were
   never actually written. 300/4 is what produces 9 owned by w500. */
/* v2.3: FLAT 100, chosen explicitly by Ian having seen the scaling numbers.
   Deliberately does NOT scale, so pulls get cheaper in real terms with depth:
   5.9 waves of income per pull at wave 1, ~0.23 by wave 3000 (≈4 pulls a wave).
   That rate is the driver of the duplicate-income dominance reported with this
   build — it is a consequence of this line, not of the duplicate value. */
P.pullCostAt=function(w){return 100;};
/* A pull yields a UNIT only ~1 in 14. With a 25-unit pool that makes collection a
   genuine long tail: 5 owned by w477, 10 by w2620, 15 by w4754, 20 by w6888,
   25 by w9020 — the roster completes near the end of a month-scale run, not in
   the first two thousand waves. */
P.UNIT_PULL_ODDS=10;   /* v2.3: 1-in-4 -> 1-in-10, compensating for cheaper pulls */
/* v2.3: was 700 and stale — pulls have not cost 700 since the scaled cost landed,
   and this constant only survives as the basis for the pre-unlock bank cap. Now
   derived from the real flat cost so the cap stays "two pulls' worth". */
P.MARKS_PER_PULL=100;
/* Pulls unlock after the SECOND boss. Marks still accrue from wave 1.
   ⚠ MEASURED CONSEQUENCE — see VERIFICATION: unit pulls were what closed the
   wave-28 wall (23% -> 100%, reach-45 0/16 -> 13/16). With the unlock at boss 2,
   wave 28 returns to 23% and 0/16 runs ever reach wave 40, so the player can
   never arrive at the boss that unlocks the fix. Left as specified and reported
   rather than silently worked around. */
/* v2.5 BUGFIX — pulls were unreachable for 39 waves.
 * The unlock was keyed to BOSS INDEX 2. When Ian asked for that, boss 2 sat at
 * wave 22, so it meant "just after the tutorial". Retiring the wave-22 special
 * case moved boss 2 to wave 40 and silently doubled the lockout — the unlock
 * followed the boss schedule even though the INTENT was tied to the tutorial
 * ending. Meanwhile the 200 bank cap pinned Marks from wave ~15 onward, so the
 * screen read "bank full, income wasted" for 25 waves with nothing to spend on.
 * Now keyed to a WAVE, which is what the intent always was and is stable against
 * any future change to the boss schedule. */
P.MARKS_UNLOCK_WAVE=40;
P.MARKS_UNLOCK_BOSSES=2;   /* retained only for the old label; not used to gate */
P.pullsUnlocked=function(g){return g.farthest>=P.MARKS_UNLOCK_WAVE;};
/* Bank cap. At 3.5/kill + idle, 40 waves of unspent accrual releases ~4 pulls in
   one lump at unlock, which spends the whole reward in a single tap. Capped at
   two pulls' worth so the unlock is a strong moment, not a windfall. */
/* ===== v2.7: NO CURRENCY CAPS =====
 * The Marks bank cap is GONE. A resource pinned at a cap with income visibly
 * wasted is a bad experience and no amount of tuning the cap fixes that.
 * What the cap was doing: pulls unlock at wave 40, and full-rate accrual to
 * there banks ~1,390 Marks = 13 pulls, which buys most of the early collection
 * curve in one sitting. That is a real problem, so it is fixed at the SOURCE —
 * Marks income runs at 45% before the unlock, then full rate after. Nothing
 * accumulates unreasonably, so nothing needs capping.
 * Aether and Lore have never had caps and still don't. REST_CAP and PARTY_CAP
 * survive: those are mechanic limits (recovery saturates; five party slots
 * exist), not currencies accruing into a bucket that overflows. */
P.PRE_UNLOCK_MARKS_MUL=0.45;
P.marksMul=function(g){return P.pullsUnlocked(g)?1:P.PRE_UNLOCK_MARKS_MUL;};
/* ===== BOSS HOARD — cut 75% in v1.1 =====
 * Was 120 * wave^1.2. Reduced to 30 because a recruit turned out not to need
 * compensating: joining at LV 1 with a 30x hoard measures IDENTICALLY to joining
 * at party level with a 120x hoard (100% at w21-w30, 17/20 reaching w32 in both).
 * 30 is the floor with margin, not a round number — at 20x wave 21 falls to 76%,
 * at 10x to 65%, at 5x to 35%, and at 0 the stretch collapses entirely. */
/* v2.2: was 30 × wave^1.2, derived when the hoard had to bridge the wave-28 wall.
   With the wall gone the hoard is just a reward, and wave^1.2 outgrew income badly
   (193 waves' worth by wave 1000). Now expressed as a fixed number of waves of
   CURRENT income, so it stays meaningful at every depth without ballooning. */
P.BOSS_AETHER_WAVES=12.5;   /* v2.3: halved from 25 waves of income */
P.bossAether=function(w){
 var kr=P.killReward(w,P.enemyCount(w)).aether;
 var idle=P.idlePerSec(w).aether*P.NOMINAL_WAVE_SEC;
 return Math.round(P.BOSS_AETHER_WAVES*(kr+idle));};
/* ===== RECOVERY (v1.0) — now a named, visible stat rather than a hidden constant.
 * Re-measured under the current build, because the answer CHANGED. In v0.9 the wall
 * sat inside the first 2-enemy fight at w15, so 25/50/100% recovery all measured
 * identical and it was inert. The ramp now gives one enemy through wave 20, which
 * moves the wall to pre-heal attrition - and recovery is now one of the strongest
 * stats in the game across its usable range:
 *     0% -> 0/20 clear     15% -> 17/20     30% -> 20/20
 *     5% -> 12/20          20% -> 16/20     35% -> 20/20  (identical to 30%)
 *    10% -> 16/20          25% -> 17/20     40% -> 20/20  (identical to 30%)
 * It SATURATES HARD at 30%. Above that it is worth exactly nothing, so the stat is
 * shipped with a visible cap: base 15%, improvable to 30%. Selling the player
 * anything past 30% would be selling a lever that does nothing. */
/* ===== v2.8: RECOVERY NOW STARTS AT ZERO =====
 * Ian's call — recovery becomes entirely a purchased stat, opted into rather
 * than granted. NOTE THE MEASURED CONSEQUENCE, which is severe: the table above
 * put 0% recovery at 0/20 clears. That measurement predates the current enrage
 * clock, the Aether cuts and the v2.1 enemy curve, so it has been re-run against
 * this build (see the report) — but a player who never buys recovery is being
 * asked to clear on a setting that has never cleared.
 * The mitigation is REST_FIRST_WAVE: the first recovery step is purchasable from
 * the very first Aether, so opting in is a real choice available immediately
 * rather than a gate the player discovers by dying. */
P.REST=0.00;          /* v2.8: was 0.15 — recovery is now entirely opt-in */
P.REST_CAP=0.30;      /* measured saturation point - beyond this it is inert */
P.REST_STEP=0.03;     /* per purchase */

/* Ramp, revised again during the v0.9 fusion. Measured: a solo character cannot
   survive the 2-enemy step at all, so it must not arrive BEFORE the boss that
   grants the second character. The second enemy and the second character now
   arrive together at wave 21. */
/* v2.2: enemy count now TRACKS PARTY SIZE. The old ramp (1/w20, 2/w30, 3/w31+)
 * was derived when a run ended near wave 45; at thousand-wave scale it left the
 * player 2-vs-3 from wave 31 all the way to wave 150, when unit 3 arrives.
 * Measured win rate over that stretch: 67% / 33% / 50% / 50% at w35/40/100/149.
 * With count matched to party it is 100% at every checkpoint from w20 to w3000. */
P.partySizeAt=function(w){
 for(var i=P.UNIT_WAVES.length-1;i>=0;i--)if(w>=P.UNIT_WAVES[i])return Math.min(P.PARTY_CAP,i+2);
 return 1;};
P.enemyCount=function(w){return P.partySizeAt(w);};

/* ===== POST-BOSS-2 VARIETY (v1.0) =====
 * After wave 40 the wave size is rolled rather than fixed, and individual enemy
 * strength scales INVERSELY with the count: one foe is an elite, four are each
 * ordinary. This is the opposite of the encounter-HP normalisation rejected in
 * v0.4 — that made enemies individually WEAKER as groups grew, to force party
 * size, and was rejected because it flattened enemy count as a difficulty axis.
 * Here count is not a difficulty axis at all, it is a COMPOSITION axis: total
 * encounter threat stays in a band while shape varies, so single-target and AoE
 * each get waves where they are plainly right.
 *
 * Threat is deliberately NOT flat — the band multiplier runs 0.85 to 1.20, so
 * some waves are harder than others. Randomness at constant difficulty is noise. */
P.VARIETY_FROM=40;
P.COUNT_WEIGHTS=[[1,0.15],[2,0.30],[3,0.35],[4,0.20]];   /* sums to 1.00 */
P.rollCount=function(rng){
 var r=rng.next(),acc=0;
 for(var i=0;i<P.COUNT_WEIGHTS.length;i++){acc+=P.COUNT_WEIGHTS[i][1];
  if(r<=acc)return P.COUNT_WEIGHTS[i][0];}
 return 3;};
/* Per-enemy multiplier. n=1 -> x1.85 elite, n=4 -> x0.72 each. Total encounter
   strength (n x mul) runs 1.85 / 2.60 / 2.88 / 2.88 — rising slightly with count
   but far flatter than linear, so a lone elite is a real fight and a crowd is not
   four times the threat. */
P.countStrength=function(n){return {1:1.85,2:1.30,3:0.96,4:0.72}[n]||1;};
P.bandRoll=function(rng){return 0.85+rng.next()*0.35;};   /* 0.85 .. 1.20 */

/* Curated onboarding. Teaching order MAGIC -> BUFFS -> HEALING -> DEBUFFS -> AOE.
   Healing sits 3rd rather than last because 0/8 solo characters reach w19 without
   it, and a between-wave rest does not help (the wall is inside the first 2-enemy
   fight). Sear at w2 is load-bearing: it takes reach-w8 from 3/10 to 10/10. */
P.STARTER_ACTIONS=['strike','ember'];
P.CURATED=[
 {w:2, kind:'action',id:'sear',    cat:'magic', why:'first magic tool — takes reach-wave-8 from 3/10 to 10/10'},
 {w:3, kind:'cond',  id:'foe_lacks_debuff',     why:'gates Sear — Burning is wasted if reapplied'},
 {w:4, kind:'action',id:'hex',     cat:'magic', why:'Frail cuts RES before the armoured foe arrives'},
 {w:5, kind:'cond',  id:'foe_armoured',         why:'Barrow Knight arrives — DEF 34, physical stalls'},
 {w:6, kind:'action',id:'bulwark', cat:'buff',  why:'Warded ×0.60; holds the 10th-percentile at wave 9'},
 {w:7, kind:'cond',  id:'ally_lacks_buff',      why:'gates Bulwark — do not overwrite a running buff'},
 {w:8, kind:'action',id:'mend',    cat:'heal',  why:'THE survival lesson, worth +277%'},
 {w:9, kind:'cond',  id:'self_hp_lte_50',       why:'gates Mend — the highest-value rule in the game'},
 {w:10,kind:'action',id:'cripple', cat:'debuff',why:'Slowed ×1.50 turn cost = 33% fewer enemy turns'},
 {w:11,kind:'cond',  id:'foe_fast',             why:'gates Cripple — relative, so it survives stat scaling'},
 {w:12,kind:'action',id:'smother', cat:'debuff',why:'Dulled cuts the Fen Priest’s healing'},
 {w:13,kind:'cond',  id:'ally_hp_lte_60',       why:'party-scale healing, ready for character 2'},
 {w:14,kind:'action',id:'daunt',   cat:'debuff',why:'Enfeebled ×0.75 ATK as the count rises'},
 {w:15,kind:'cond',  id:'foe_lowest_hp',        why:'2 enemies begin — focus fire stops being degenerate'},
 {w:16,kind:'action',id:'gale',    cat:'aoe',   why:'magic AoE first — Shrike thorns punish PHYSICAL AoE'},
 {w:17,kind:'cond',  id:'foe_highest_hp',       why:'gates Gale and Daunt'},
 {w:18,kind:'action',id:'cleave',  cat:'aoe',   why:'physical AoE, once you know when not to use it'},
 {w:19,kind:'cond',  id:'foe_hp_gte_70',        why:'gates Cleave/Gale — AoE early, single-target once hurt'},
 {w:20,kind:'action',id:'execute', cat:'attack',why:'BOSS — always crits below 30%'}];
/* foe_hp_lte_30 is deliberately NOT here: Execute lands on the boss wave, so its
   gate would arrive before anything it could gate. It joins the random pool. */
/* Difficulty-ASCENDING. The original order put the Barrow Knight (DEF 34) at w5,
   which killed every solo run at wave 5 - the starter's MAG is 18 against ATK 26,
   so Hex+Ember does not answer armour, and no heal exists until w8. */
/* v1.0: Priest and Hound SWAPPED. Every bottom-decile run was dying at wave 7 to
   the Mire Hound, which sits in the pre-heal window (Mend arrives at w8). Lowering
   its ATK changed nothing - it was the hound's SPEED (124) giving it many turns
   against a character with no heal rule yet. Moving the Fen Priest (ATK 12, the
   weakest attacker) into w5-7 took the 10th percentile from wave 7 to wave 20. */
P.WAVE_ARCH=['wolf','wolf','wolf','wolf','priest','priest','priest','hound','hound','hound',
 'shrike','shrike','shrike','ox','ox','ox','knight','knight','knight'];
P.archetypeFor=function(w,i){
 if(w<=19)return P.WAVE_ARCH[w-1];
 return C.ROT[(w-1+i)%C.ROT.length];};
P.dropsAt=function(w){var o=[];P.CURATED.forEach(function(d){if(d.w===w)o.push(d);});return o;};
P.isCurated=function(w){return w<=P.BOSS_EVERY;};
P.isBossWave=function(w){
 for(var i=0;i<40;i++){var bw=P.bossWaveAt(i);if(bw===w)return true;if(bw>w)return false;}
 return false;};
P.nextBossWave=function(w){
 for(var i=0;i<40;i++){var bw=P.bossWaveAt(i);if(bw>w)return bw;}
 return null;};
P.checkpoint=function(bossesCleared){
 return bossesCleared===0?1:(P.bossWaveAt(bossesCleared-1)+1);};

/* Idle rate keys off FARTHEST wave (a ratchet), never current wave - so a wipe
   costs progress but never income rate. */
/* Tuned against the growth requirement, not by feel: these values put a solo
   character at ~21 stat nodes by wave 20, i.e. ~2.05x base, i.e. g = 1.04 per
   wave - the rate measured as necessary to reach the first boss. */
/* v2.0 income: tied to the wave curve so it keeps pace across thousands of waves
   without the old 1.06^w explosion. */
/* v2.3: passive AETHER halved (1.4 -> 0.7). Marks untouched — Ian asked for the
   idle Aether cut only. Intent: units level too fast and full parties trivialise
   waves; the enemy curve deliberately does NOT move, so difficulty rises. */
/* v2.8: Marks income cut to 65% at ALL depths, on top of the 45% pre-unlock
   multiplier. Removing the bank cap meant nothing throttles accrual any more, so
   the rate itself has to carry it. 0.65 holds the roster curve Ian asked for —
   a workable party by wave 500 and a genuine tail after it — where full rate had
   the roster effectively complete around wave 900 and the tail collapsing. */
P.MARKS_RATE=0.65;
/* v2.8: a further -10% on Aether, on top of the v2.3 halving of idle and boss
   Aether. Applied to the two SOURCES (idle + kills); the boss hoard and the
   duplicate-unit grant are both expressed in waves-of-current-income, so they
   inherit the cut automatically instead of needing their own factor.
   Math.round removed from the kill reward: at 0.9x it was rounding a fractional
   result to an integer BEFORE multiplying by enemy count, which quantised the
   cut away at low waves (14*1.0*0.9 = 12.6 -> 13, only a 7% cut not 10%). */
P.AETHER_RATE=0.90;
/* Base coefficients cut twice: 0.7->0.1->0.01 (aether), 0.35->0.05->0.005
   (marks). The first cut (to 0.1/0.05) still left wave-1 idle income at ~7.8k
   Aether / ~1.3k Marks per 24h, judged still too fast — and waves run into the
   TENS OF THOUSANDS, so idle income at depth is this base times waveScale on
   top: measured directly against the CURRENT curve (not the older "=86 at
   w10000" figure quoted elsewhere, which predates the v2.1 refit), waveScale
   is 1 at wave 1, ~4.4 at 200, ~8.8 at 1000, ~26 at 10000 — so a rate that
   feels only "somewhat too generous" at wave 1 is ~26x that at wave 10000.
   AETHER_RATE/MARKS_RATE are left as-is; they are late-game throttles (roster
   pacing, the v2.8 Aether cut) layered on TOP of this base, not the base
   rate itself. */
P.idlePerSec=function(farthest){var S=C.waveScale(farthest);return {
 aether:0.01*S*P.AETHER_RATE, marks:0.005*S*P.MARKS_RATE};};
P.killReward=function(w,n){var S=C.waveScale(w);return {
 aether:14*S*P.AETHER_RATE*n, marks:3*S*P.MARKS_RATE*n};};
/* TRAVEL TIME is the real throttle — it is what turns "thousands of waves" into
   weeks instead of hours. Fight length is flat, so wave RATE is set here.
   w1 = 8s, w500 = 48s, w2000 = 168s, w10000 = 808s per node. */
P.travelSec=function(w){return 8+0.08*w;};
P.wavesPerHour=function(w){return 3600/(20+P.travelSec(w));};
/* ===== OFFLINE PROGRESS (save/load) =====
 * Bounds simulateOfflineProgress() in the UI layer: on resume, the road is
 * actually played forward with the real combat core for however many waves
 * fit in the elapsed real time (each wave costing 20+travelSec(w) seconds,
 * the same per-wave cost P.wavesPerHour() is derived from), capped here so
 * a long absence can't be gamed into unbounded progress. Real fights mean a
 * real wipe can happen while you're away — Ian chose full fidelity over
 * GDD §1.4's "offline never wipes" rule. It's still not that section's
 * full node/Waymark estimator (auto-invest, danger-halt, node-by-node
 * pacing) — this prototype has no node-based map to advance along, only
 * wave numbers, so it's the same combat core run unattended rather than a
 * separate simulation model. The cap value is reused from that same spec
 * (12h, chosen there over Melvor's 24h) so the two systems agree on one
 * number if §1.4's fuller model is ever built on top of this. */
P.OFFLINE_CAP_SEC=12*3600;

/* ===== v1.0: AETHER IS EXPERIENCE. The stat-node grid is RETIRED. =====
 * Measured justification: player-directed allocation was worth almost nothing.
 * Six very different allocations of the same 20-node budget produced a depth
 * spread of 1.04x with no clock and 1.24x with it - against an action/gambit axis
 * worth up to +173%. Allocation was expressive but not consequential, so trading
 * it for per-unit growth curves costs no measurable build diversity and buys
 * character identity. Diversity now lives in actions, gambits, Lore and rows.
 *
 * Aether is a SHARED pool the player allocates between units. That makes "who do
 * I level" a real decision and gives benched companions a genuine cost - and it
 * resolves the slot question by itself: a solo player pours everything into one
 * unit and reaches the slot-3 level early, precisely because they cannot delegate.
 */
P.GROWTH={
 kesh  :{hp:34,atk:2.1,mag:1.0,def:1.4,res:1.0,spd:2.2},  /* balanced attacker  */
 ansa  :{hp:22,atk:0.8,mag:2.3,def:0.9,res:1.7,spd:2.0},  /* caster / support   */
 dorrek:{hp:48,atk:1.6,mag:0.5,def:2.4,res:1.4,spd:1.4},  /* wall               */
 vey   :{hp:21,atk:2.0,mag:0.7,def:0.9,res:0.8,spd:3.2},  /* fast, fragile      */
 mirel :{hp:18,atk:0.6,mag:2.7,def:0.8,res:1.5,spd:1.9},  /* glass caster       */
 /* Roster expansion 5->10 (prereq for roadmap item 4 — see the ROSTER
    EXPANSION comment in core.js). Every unit's atk+mag+def+res+spd growth
    sums to 7.5, matching the original five's 7.3-7.7 band. */
 skarn :{hp:19,atk:1.7,mag:0.7,def:1.3,res:1.2,spd:2.6},  /* berserker          */
 sorin :{hp:30,atk:1.6,mag:1.6,def:1.3,res:1.2,spd:1.8},  /* battle-mage        */
 nyra  :{hp:20,atk:0.9,mag:1.7,def:1.6,res:1.6,spd:1.7},  /* warden / debuffer  */
 brenn :{hp:38,atk:1.1,mag:1.0,def:1.5,res:1.5,spd:2.4},  /* evasion tank       */
 sael  :{hp:19,atk:0.6,mag:2.0,def:0.9,res:1.3,spd:2.7}}; /* swift support      */
/* Verified distinct rather than noise: at L20, spd:def runs 1.46 (Dorrek) to 5.94
   (Vey), and atk:mag runs 0.29 (Mirel) to 2.69 (Dorrek). */
/* v2.1: cost exponent 2.6, coefficient 1.5 — solved as a fixed point against the
   income curve so that LV 100 lands at wave 1000 exactly.
   Shape check (levels per wave): 0.8 at w1-10, then 0.1 from w100 onward — early
   levels arrive in a rush, later ones grind, which is the requested feel.
   LV 10 costs 616 · LV 50 costs 40,416 · LV 100 costs 245,036 · LV 1000 costs 97.5M.
   Part of the late slowdown is intentionally NOT in this curve: it comes from the
   shared pool being split across more units and more Lore sinks competing. */
P.expFor=function(L){return Math.round(0.4*Math.pow(L,2.8));};
/* ===== OPTION 2 — costs are RELATIVE to the roster ratchet =====
 * R = the highest level ANY owned unit has ever reached, monotonic. A unit's next
 * level costs the absolute marginal x clamp(L/R, 0.15, 1), so units that are BEHIND
 * pay a fraction while the leader — who IS R — always pays clamp(1)=1.00 and can
 * never be accelerated by its own discount.
 * Verified non-abusable: rushing one unit to inflate R costs 1.7-1.8x MORE than
 * levelling evenly to the same end state, because the rushed unit pays full price
 * at the reference. R cannot be lowered (ratchet) and low units cannot drag it
 * down, so there is no reason to hold a unit back either. */
P.DISCOUNT_FLOOR=0.15;
P.marginal=function(L){return Math.max(1,P.expFor(L)-P.expFor(L-1));};
P.discount=function(L,R){if(!R||R<=1)return 1;
 return Math.max(P.DISCOUNT_FLOOR,Math.min(1,L/R));};
P.costToNext=function(L,R){return Math.max(1,Math.round(P.marginal(L+1)*P.discount(L+1,R)));};
/* Idle is credited against a NOMINAL wave length, not the real one. Travel time
   grows with depth, so crediting real elapsed time inflated per-wave income and
   the player outran the curve badly late (+285 levels by w10000). Decoupled, the
   afforded level tracks the target within ~8 levels from wave 500 on. */
P.NOMINAL_WAVE_SEC=40;
P.levelFromExp=function(x){var L=1;while(P.expFor(L+1)<=x)L++;return L;};
/* Calibrated so a SOLO character is ~L14 at wave 20 => ~2.05x base, i.e. the 4%
   compounding growth per wave established as the solo survival requirement. */
P.statsAt=function(uid,base,baseHp,L){
 var g=P.GROWTH[uid]||P.GROWTH.kesh,n=L-1,o={};
 ['atk','mag','def','res','spd'].forEach(function(s){o[s]=Math.round(base[s]+g[s]*n);});
 o.hp=Math.round(baseHp+g.hp*n);
 ['atkCrit','magCrit','chargeRate','block','evade'].forEach(function(k){o[k]=base[k];});
 return o;};
/* ===== SLOTS UNLOCK WITH LEVEL =====
 * 2 at L1, 3rd at L10, 4th at L25. Ties directly to the finding that a solo
 * character can express exactly one rule: with 2 slots the heal takes the only
 * conditional. Under a SHARED pool a solo player hits L10 around wave 14-15 -
 * after the heal lesson has landed, before the boss - while a wide party reaches
 * it later per unit. The schedule self-adjusts to how thinly you are spread, so
 * "3 slots right solo, wrong in a party" needs no special case. */
P.SLOT_LEVELS=[1,1,10,25];
P.slotsAt=function(L){var n=0;
 for(var i=0;i<P.SLOT_LEVELS.length;i++)if(L>=P.SLOT_LEVELS[i])n++;
 return Math.max(2,n);};
P.nextSlotAt=function(L){
 for(var i=0;i<P.SLOT_LEVELS.length;i++)if(L<P.SLOT_LEVELS[i])return P.SLOT_LEVELS[i];
 return null;};
/* DEBUG ONLY. The crutch is retired: intended difficulty is baked into enemy base
   stats and the ATK growth exponent, so 1.00 is normal play and the numbers in the
   doc are the real numbers. Kept solely for testing. */
P.DIFFICULTY=1.00;
/* was a flat 700 — the wave-scaled pullCostAt existed but nothing called it, so
   pulls became effectively free at depth. Now routed through the scaled version. */
P.pullCost=function(w){return P.pullCostAt(w||1);};
/* ===== v2.1: COLLECTION vs PARTY are now different things =====
 * ROSTER POOL: ~25 units, each with a UNIQUE charge action. You COLLECT them and
 * freely choose which 5 form the active PARTY. Benched units stay owned — they are
 * never consumed — so a pull you cannot field is still a real acquisition.
 *   OWNED  = your collection, grows across thousands of waves (long tail)
 *   PARTY  = the 5 you field, fills early and then becomes a CHOICE, not a gate
 * A duplicate is now only a duplicate of a unit you ALREADY OWN. With 25 units
 * that stays rare for a long time, so unit pulls read as collection first and an
 * Aether source second — the reverse of the v2.0 rule this replaces. */
P.PARTY_CAP=5;
P.POOL_SIZE=25;
P.BOSS_UNIT_ORDER=['ansa','dorrek','vey','mirel'];
/* ===== v2.0 UNIT CADENCE =====
 * Was: a unit at EVERY boss, so the roster finished by wave ~23. At the new scale
 * that is absurd — 50+ bosses in the first thousand waves. Units now arrive at
 * MILESTONE waves only; every other boss pays Aether instead.
 * Spread across the shape of the run: unit 2 is the tutorial payoff, unit 5 lands
 * around day 2. Marks pulls can still beat these dates — this is the floor. */
P.UNIT_WAVES=[20,150,500,1500];
P.unitDueAt=function(w){var i=P.UNIT_WAVES.indexOf(w);return i>=0?P.BOSS_UNIT_ORDER[i]:null;};
/* Duplicate units convert to AETHER, mirroring duplicate actions/gambits -> Lore.
   This is what makes 50+ boss rewards coherent once the roster caps at 5: past
   the cap a "unit" reward is simply a large Aether grant, and it taper-reads as
   intended rather than as a broken reward. */
/* v2.3: duplicate units worth MORE, expressed the same way as the boss hoard —
   as waves of CURRENT income — so it stays meaningful at every depth.
   Chosen at 3 waves: a boss hoard is 12.5, so a duplicate companion reads as a
   meaningful event at roughly a quarter of a boss, which is the right weight for
   something that arrives from a pull rather than a fight. In flat terms that is
   ~294 Aether at wave 20 rising to ~1,660 at wave 3000, against the old flat
   400×scale (756 at w20, 5,900 at w3000) — so it is LOWER in absolute terms at
   depth, but the pull RATE at flat-100 cost more than compensates. See the
   dominance warning reported alongside this build. */
P.DUP_UNIT_WAVES=3;
P.dupUnitAether=function(w){
 var kr=P.killReward(w,P.enemyCount(w)).aether;
 var idle=P.idlePerSec(w).aether*P.NOMINAL_WAVE_SEC;
 return Math.round(P.DUP_UNIT_WAVES*(kr+idle));};

/* ===== CUSTOMISABLE FIRST UNIT (roadmap item 1) =====
 * Bounds ORIGINATE from the ROSTER's own min/max per stat, but as of the
 * 1-10 -> 0-15 point-scale widening, they are no longer CLAMPED to it: the
 * ceiling scales by the same factor the point-max did (10 -> 15 = x1.5) and
 * the floor scales down by the same factor (/1.5) — evade's [0.02,0.10]
 * becoming [0,0.15] is the worked example that set this rule (x1.5 lands
 * exactly on 0.15; 0 is used for the floor instead of /1.5 specifically for
 * the four percentage stats, since 0% is a normal, functional value for
 * them). A player-built character CAN now exceed every existing specialist
 * in a stat — a deliberate tradeoff of the "never exceed shipped content"
 * safety property for more build variance, per Ian's explicit request. The
 * difficulty curve is tuned against the ORIGINAL five's stats (see the "solo
 * character survival requirement" notes throughout this file); an extreme
 * custom build can now go meaningfully beyond what those measurements cover.
 *
 * EVERY stat the engine tracks is here — ATK/MAG/DEF/RES/SPD/HP plus
 * ATK-CRIT/MAG-CRIT/BLOCK/EVADE — with one deliberate exception: chargeRate is
 * not offered, because it is the one field where the five shipped units carry
 * IDENTICAL values (1.0, every one). There is no already-played range to bound
 * a choice against, so — consistent with the rule above — none is invented;
 * every unit's charge gauge fills at the same rate regardless of build.
 *
 * Growth (P.MC_GROWTH_RANGE below) is UNCHANGED by this — still clamped to
 * the original five's own min/max, not widened. Ian's ask was specifically
 * about the stat gates (the evade example has no growth curve at all), and
 * long-run levelling power is a more sensitive lever than a starting stat,
 * so it wasn't touched without being asked. Growth is still tied to the SAME
 * point spent on a stat's base value — the shipped five's own rule
 * (whichever unit has a stat's highest base value also has that stat's
 * highest growth: Vey/SPD 124+3.2, Mirel/MAG 30+2.7, Dorrek/DEF 30+2.4,
 * Ansa/RES 22+1.7, Kesh/ATK 26+2.1, Dorrek/HP 560+48) — just no longer
 * matched by an equally widened base-stat ceiling. ATK-CRIT/MAG-CRIT/BLOCK/
 * EVADE have no growth curve to bound either way — P.statsAt() copies them
 * straight from base for every unit in the game, not just a custom one, so
 * a level-1 point is this stat for the whole run.
 *
 * CORRECTION (post-widening balance test): a "max this stat, spread the rest
 * of the pool evenly" specialist was simulated wave-by-wave (real enemy
 * curve, real leveling off real Aether income, 150 seeds/stat) for all ten
 * stats. Seven landed within noise of a 5.0-wave mean, but the naive x1.5
 * ceiling badly overshot for three linearly-scaling combat stats — atk 14.1,
 * mag 14.6, spd 13.8 mean waves survived, vs. ~5.0 for everything else
 * (DEF/RES are self-limiting by the K/(K+stat) mitigation curve, HP/CRIT/
 * BLOCK/EVADE are all capped or sub-linear, but raw ATK/MAG damage and SPD's
 * turn-order/action-count advantage compound directly).
 *
 * First attempt just binary-searched each of the three stats' OWN maxed-mean
 * back to 5.0 in isolation (atk 39->19, mag 45->19, spd 186->110) — that
 * over-corrected: those same three stats also supply the "spread the rest of
 * the pool evenly" points every OTHER build's atk/mag/spd draws from, so
 * shrinking their ceiling that far also starved every non-outlier build,
 * dragging def/res/hp/crit/block/evade down to 2.1-4.5 (previously ~5.0 at
 * full widening). Re-solved as a joint problem instead — swept a shared
 * scale-down factor across all three ceilings together, checking BOTH each
 * stat's own maxed-mean AND a same-methodology def-maxed build (a stand-in
 * for every "spread" build) at each step, until both landed on 5.0 at once.
 * That equilibrium is atk 39->26, mag 45->29, spd 186->131 (all three, and
 * the def proxy, measured within 0.06 waves of a 5.0 mean at this setting;
 * pool-shifted at the same rate they were widened, without the 39/45/186
 * ceilings' compounding payoff). mag's ceiling is bumped one further point,
 * 29->30, to stay >= Mirel's own mag base stat (30) — the smoke test asserts
 * every shipped ROSTER stat still falls inside MC_STAT_RANGE, and 29 would
 * put the MC's own cap a point below a shipped companion's; the 1-point
 * nudge is inside the sweep's own noise band and doesn't reopen the mag
 * outlier gap. Floors are UNCHANGED (still the /1.5-widened floor from
 * above) — only the ceiling needed correcting.
 *
 * MANUAL ADJUSTMENT (post-correction, Ian's explicit values): atk 26->28,
 * res 33->40, magCrit/block/evade 0.15->0.18. Re-run against the same
 * specialist simulation: atk's own maxed-mean rose back to 5.4 (an 8% gap
 * over the pack, vs. the fitted equilibrium's 0%), and res/block/evade rose
 * from 4.0-4.1 to 4.1-4.3 — a small, deliberate re-opening of the atk gap
 * traded for a little headroom on res/block/evade, not re-verified against
 * the joint "spread" methodology above since these were requested values,
 * not re-fit ones. */
P.MC_STAT_RANGE={atk:[8,28],mag:[7,30],def:[8,45],res:[8,40],spd:[56,131],
 hp:[180,840],atkCrit:[0,0.18],magCrit:[0,0.18],block:[0,0.18],evade:[0,0.18]};
P.MC_GROWTH_RANGE={atk:[0.6,2.1],mag:[0.5,2.7],def:[0.8,2.4],res:[0.8,1.7],spd:[1.4,3.2],
 hp:[18,48]};
/* Percentage-scale stats (crit/block/evade run 0.02-0.12) round to the nearest
   whole percent, matching the granularity every shipped value already uses —
   interpolating to raw floating point would imply a precision the roster
   itself doesn't have (nothing is tuned to e.g. 7.3% block). */
P.MC_PCT_STATS=['atkCrit','magCrit','block','evade'];
/* Every stat starts at 0 (its roster-derived floor — see mcLerp, point=MIN
   always maps to statRange[0], so 0 points never means a literal 0 in-game
   stat) rather than a pre-filled midpoint, so building toward a plan means
   only ever ADDING points, never having to first subtract from stats you
   don't want. Range widened 1-10 -> 0-15 for more room to specialize before
   the fixed pool runs out. POOL is deliberately HALF of the theoretical max
   spend (10 stats x 15 = 150) rather than derived from a per-stat default —
   there is no default to derive it from any more — so an even split still
   lands mid-range on every stat (75/10=7.5, roughly half of 15), while a
   focused build can afford to max 5 of the 10 stats outright (5x15=75) and
   leave the rest at floor, which is more extreme specialization than the
   old 1-10/pool-50 scheme allowed. */
P.MC_STAT_KEYS=['atk','mag','def','res','spd','hp','atkCrit','magCrit','block','evade'];
P.MC_POINT_MIN=0;
P.MC_POINT_MAX=15;
P.MC_POINTS_TOTAL=(P.MC_STAT_KEYS.length*P.MC_POINT_MAX)/2;
/* ===== MC CHARGE ACTIONS: starter pick vs. rare acquisition (roadmap 2) =====
 * Creation only offers the three GENERIC starters (core.js's "MC GENERIC
 * STARTERS" — plain bulk-physical, bulk-magic, or heal, no attached effect).
 * The eight "corner" charge actions — build-around options with an attached
 * status, a conditional, or a resource effect instead of raw numbers — are
 * withheld at creation and become a RARE random drop instead, exactly like
 * an equippable action or gambit condition except far less frequent (see
 * MC_CHARGE_DROP_CHANCE) and gated to the random-drop phase only (post
 * wave-20) so the curated tutorial sequence is never disturbed by one. */
P.MC_STARTER_CHARGES=['heavystrike','wildfire','greatheal'];
P.MC_CHARGE_DROP_POOL=['tideturn','lastlight','sunder','gravewind','reckoning',
 'bulwarkoath','emberglut','hollowtoll'];
/* Checked once per random-phase wave, replacing that wave's normal action/
   condition drop rather than stacking on top of it — a charge action is a
   bigger deal than either, so it doesn't also cost the player their usual
   drop that wave. At 5% per wave, one charge-drop event lands roughly every
   20 waves; collecting all 8 (a coupon-collector problem, expectation
   8 x H(8) ≈ 21.7 events) takes on the order of 400+ waves of random drops —
   "much more rare" than the guaranteed per-wave action/condition drop it
   can replace. */
P.MC_CHARGE_DROP_CHANCE=0.05;
P.mcLerp=function(range,point){
 return range[0]+(point-P.MC_POINT_MIN)/(P.MC_POINT_MAX-P.MC_POINT_MIN)*(range[1]-range[0]);};
P.mcPointsSpent=function(points){
 var sum=0,i;for(i=0;i<P.MC_STAT_KEYS.length;i++)sum+=points[P.MC_STAT_KEYS[i]]||0;
 return sum;};
/* @param points one P.MC_POINT_MIN..P.MC_POINT_MAX value per P.MC_STAT_KEYS */
P.mcBuildStats=function(points){
 var stats={},growth={},i,k,v;
 for(i=0;i<P.MC_STAT_KEYS.length;i++){
  k=P.MC_STAT_KEYS[i];v=P.mcLerp(P.MC_STAT_RANGE[k],points[k]);
  stats[k]=(P.MC_PCT_STATS.indexOf(k)>=0)?Math.round(v*100)/100:Math.round(v);
  if(P.MC_GROWTH_RANGE[k])growth[k]=Math.round(P.mcLerp(P.MC_GROWTH_RANGE[k],points[k])*10)/10;}
 var hp=stats.hp;delete stats.hp;               /* hp is top-level on a unit, not under .stats */
 return {stats:stats,hp:hp,growth:growth};};
return P;})(window.FarroadCore);
