
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
/* v2.10: 0.30 -> 0.50, requested directly by Ian. NOTE: the "saturates hard
   at 30%, worth exactly nothing above it" finding above is from v1.0 —
   several major difficulty retunes have landed since (the v2.1 rescale, the
   v2.9 hard-scaling pass that doubled HARD_MAX) and the measurement was
   never re-run against them, so it should be treated as stale, not as
   confirmation this new ceiling is inert. Flagged rather than silently
   trusted; a fresh clear-rate pass (same 0/20-vs-20/20 methodology as the
   comment above, at 30/35/40/45/50%) would confirm whether 30-50% still
   moves anything under the current curve. */
P.REST_CAP=0.50;
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
/* v2.9: past P.HARD_FROM, enemy count can roll all the way up to P.ENEMY_CAP
   (was 4) — the "5 front / 5 back" ask. A SEPARATE table rather than
   extending COUNT_WEIGHTS in place, so waves 41-100 are provably unchanged
   (same table, same distribution) and only the post-100 hard-scaling range
   gets bigger encounters — tying this to the same threshold as P.hardMul
   rather than introducing a second, independent knob to tune. */
P.ENEMY_CAP=10;
P.COUNT_WEIGHTS_HARD=[[1,0.05],[2,0.08],[3,0.12],[4,0.15],[5,0.15],
 [6,0.13],[7,0.11],[8,0.09],[9,0.07],[10,0.05]];          /* sums to 1.00 */
P.rollCount=function(rng,w){
 var table=(w>P.HARD_FROM)?P.COUNT_WEIGHTS_HARD:P.COUNT_WEIGHTS;
 var r=rng.next(),acc=0;
 for(var i=0;i<table.length;i++){acc+=table[i][1];
  if(r<=acc)return table[i][0];}
 return table[table.length-1][0];};
/* Rarity (v2.12): unit pulls now skew toward Common instead of picking
   uniformly among not-yet-owned companions — Rare becomes genuinely harder
   to pull, not just costlier to grow once owned. Reasoned starting point;
   no Legendary units exist yet (see the plan's open pick) but a weight is
   defined regardless so one can be added later with no code change here. */
P.RARITY_PULL_WEIGHT={common:3, rare:1, legendary:1};
/* Roulette-wheel pick over a list of C.ROSTER entries, weighted by each
   entry's own rarity via P.RARITY_PULL_WEIGHT — same explicit-rng shape as
   P.rollCount just above, so this stays engine-testable headless like the
   rest of this file rather than reaching for a global. */
P.weightedRosterPick=function(rng,list){
 var weights=list.map(function(r){return P.RARITY_PULL_WEIGHT[r.rarity||'common']||1;});
 var total=weights.reduce(function(a,w){return a+w;},0);
 var roll=rng.next()*total,acc=0,i;
 for(i=0;i<list.length;i++){acc+=weights[i];if(roll<acc)return list[i];}
 return list[list.length-1];};
/* v2.13: the equippable-action grid (elemental strikes, one atk + one mag
   per element) introduced real Rare/Legendary EQUIPPABLE actions for the
   first time — before this every equippable was Common, so C.EQUIPPABLE's
   two draw sites (randomDrop's wave-parity action drop, doPull's action
   branch) picked uniformly with no rarity to weight against. Same
   P.RARITY_PULL_WEIGHT table as units, same roulette-wheel shape as
   P.weightedRosterPick just above, reading C.ACTIONS[id].rarity instead of
   a ROSTER entry's own field — kept as a separate function rather than a
   shared callback-taking one since the two id shapes differ (this one
   works over plain action id strings, C.EQUIPPABLE's own shape). */
P.weightedActionPick=function(rng,ids){
 var weights=ids.map(function(id){return P.RARITY_PULL_WEIGHT[(C.ACTIONS[id]&&C.ACTIONS[id].rarity)||'common']||1;});
 var total=weights.reduce(function(a,w){return a+w;},0);
 var roll=rng.next()*total,acc=0,i;
 for(i=0;i<ids.length;i++){acc+=weights[i];if(roll<acc)return ids[i];}
 return ids[ids.length-1];};
/* Equipment (v2.14): identical shape to weightedActionPick just above,
   reading C.EQUIPMENT[id].rarity instead of C.ACTIONS — kept as its own
   function for the same reason: a plain-id-list pick over a different
   content table, not worth a shared callback-taking generic. */
P.weightedEquipmentPick=function(rng,ids){
 var weights=ids.map(function(id){return P.RARITY_PULL_WEIGHT[(C.EQUIPMENT[id]&&C.EQUIPMENT[id].rarity)||'common']||1;});
 var total=weights.reduce(function(a,w){return a+w;},0);
 var roll=rng.next()*total,acc=0,i;
 for(i=0;i<ids.length;i++){acc+=weights[i];if(roll<acc)return ids[i];}
 return ids[ids.length-1];};
/* Per-enemy multiplier. n=1 -> x1.85 elite, n=4 -> x0.72 each. Total encounter
   strength (n x mul) runs 1.85 / 2.60 / 2.88 / 2.88 — rising slightly with count
   but far flatter than linear, so a lone elite is a real fight and a crowd is not
   four times the threat. n=5-10 (v2.9) continue the same plateau: the known
   n=3/4 values already fit total-strength ~2.9 almost exactly (2.9/3=0.967,
   2.9/4=0.725), so the fallback for n>4 keeps that same plateau instead of the
   old flat ||1, which would have let a 10-enemy wave hit 10x total strength. */
P.countStrength=function(n){return {1:1.85,2:1.30,3:0.96,4:0.72}[n]||(2.9/n);};
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
/* v2.9 BUGFIX: both of these used to loop bossWaveAt(i) for i<40, a hardcoded
   iteration cap — bossWaveAt itself is unbounded (BOSS_EVERY past the last
   fixed entry forever), but the loop could never see past bossWaveAt(39)=800,
   so no boss ever spawned past wave 800 and the UI's "next boss" readout went
   blank there too. Replaced with direct arithmetic — no bound to outgrow. */
P.isBossWave=function(w){
 var last=P.BOSS_WAVES[P.BOSS_WAVES.length-1];
 if(w<last)return P.BOSS_WAVES.indexOf(w)>=0;
 return (w-last)%P.BOSS_EVERY===0;};
P.nextBossWave=function(w){
 for(var i=0;i<P.BOSS_WAVES.length;i++)if(P.BOSS_WAVES[i]>w)return P.BOSS_WAVES[i];
 var last=P.BOSS_WAVES[P.BOSS_WAVES.length-1];
 if(w<last)return last;
 return last+P.BOSS_EVERY*(Math.floor((w-last)/P.BOSS_EVERY)+1);};
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
/* v2.9: both rates divided by 5 (Marks 0.65->0.13, Aether 0.90->0.18) — total
   Aether/Marks gain still ran too high, passive idle income especially, and
   now doubly so with expeditions (roadmap item 4) adding a SECOND automated
   income stream on top of live play. Applied here rather than to the idle
   base coefficients specifically because expeditions call P.killReward()
   directly (not P.idlePerSec()) for each battle they resolve — cutting only
   the idle coefficients would have left expedition income untouched. Both
   rates already feed every Aether/Marks source in the game (idle trickle,
   per-kill reward — including expeditions' own — boss hoards, and the
   duplicate-unit conversion, all either use these directly or derive from
   idlePerSec/killReward), so one cut here reaches everything uniformly. */
P.MARKS_RATE=0.13;
/* Applied to the two SOURCES (idle + kills); the boss hoard and the
   duplicate-unit grant are both expressed in waves-of-current-income, so they
   inherit the cut automatically instead of needing their own factor.
   Math.round removed from the kill reward: at 0.9x it was rounding a fractional
   result to an integer BEFORE multiplying by enemy count, which quantised the
   cut away at low waves (14*1.0*0.9 = 12.6 -> 13, only a 7% cut not 10%). */
P.AETHER_RATE=0.18;
/* Base coefficients cut twice: 0.7->0.1->0.01 (aether), 0.35->0.05->0.005
   (marks). The first cut (to 0.1/0.05) still left wave-1 idle income at ~7.8k
   Aether / ~1.3k Marks per 24h, judged still too fast — and waves run into the
   TENS OF THOUSANDS, so idle income at depth is this base times waveScale on
   top: measured directly against the CURRENT curve (not the older "=86 at
   w10000" figure quoted elsewhere, which predates the v2.1 refit), waveScale
   is 1 at wave 1, ~4.4 at 200, ~8.8 at 1000, ~26 at 10000 — so a rate that
   feels only "somewhat too generous" at wave 1 is ~26x that at wave 10000.
   AETHER_RATE/MARKS_RATE are separate, further throttles (roster pacing, the
   v2.8 Aether cut, the v2.9 /5 cut above) layered on TOP of this base — for
   killReward below, which still uses this exact model. */
P.killReward=function(w,n){var S=C.waveScale(w);return {
 aether:14*S*P.AETHER_RATE*n, marks:3*S*P.MARKS_RATE*n};};
/* ===== IDLE INCOME — v2.9 REDESIGN (floor + tempered growth) =====
 * idlePerSec used to be the same multiplicative shape as killReward above —
 * base x C.waveScale(farthest) x RATE — which meant idle income inherited
 * combat's own scaling curve wholesale (that 26x-by-wave-10000 growth two
 * paragraphs up), and at very early waves the raw product could round to a
 * visibly "0/5min" display even though a trickle was technically accruing
 * (see the idleRate UI note). Replaced with an explicit floor: BOTH Aether
 * and Marks idle income are exactly P.IDLE_FLOOR_PER_5MIN (1) per 5 minutes
 * at wave 1, guaranteed regardless of any rate constant, and grow from
 * there using P.idleGrowth — sqrt(waveScale), the same "want growth but not
 * the raw curve" tempering already used for enemy crit scaling — rather
 * than the raw waveScale curve killReward still uses.
 * Aether and Marks grow at DIFFERENT rates ABOVE that shared floor:
 * Aether at half (P.IDLE_AETHER_GROWTH_MUL), Marks at double
 * (P.IDLE_MARKS_GROWTH_MUL) — Marks fund pulls (needed in bulk, so idle
 * income should lean toward it over a long run) where Aether funds
 * per-unit levelling (a slower, more deliberate spend). The multiplier is
 * applied to the GROWTH TERM only (g-1), not the floor itself, so wave 1
 * stays exactly 1/5min for both no matter how asymmetric the growth is —
 * the floor is a hard guarantee, not a side effect of the rate math. */
P.IDLE_FLOOR_PER_5MIN=1;
P.IDLE_AETHER_GROWTH_MUL=0.5;
P.IDLE_MARKS_GROWTH_MUL=2.0;
P.idleGrowth=function(w){return Math.sqrt(C.waveScale(w));};
P.idlePerSec=function(farthest){
 var g=P.idleGrowth(farthest);
 var aether5=P.IDLE_FLOOR_PER_5MIN+(g-1)*P.IDLE_AETHER_GROWTH_MUL;
 var marks5=P.IDLE_FLOOR_PER_5MIN+(g-1)*P.IDLE_MARKS_GROWTH_MUL;
 return {aether:aether5/300, marks:marks5/300};};
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

/* ===== EXPEDITIONS (roadmap item 4, phase 1) =====
 * Benched units sent out on real wall-clock expeditions, resolved with the
 * same combat core as offline progress (resolveExpedition() in the UI layer
 * mirrors simulateOfflineProgress() above) but against the expedition's OWN
 * synthetic wave counter, not G.wave — exploring is its own escalating-
 * difficulty track, independent of road progress, using the same
 * C.waveScale/P.archetypeFor curve and the same P.travelSec pacing so the
 * two systems agree on how fast difficulty and real time move. */
P.EXPED_RETURN_HP_FRAC=0.25;      /* auto-return once carried HP drops below this */
P.EXPED_CAP_SEC=P.OFFLINE_CAP_SEC;  /* same 12h ceiling per catch-up pass */

/* ===== DIRECTIONS =====
 * "Choose a direction... West (easiest/least lucrative) through East
 * (hardest/most lucrative)". One expedition per direction at a time — 8
 * named lanes IS the concurrent-expedition cap, not a separate counter
 * (see sendExpedition in the UI layer). directionMul is computed from
 * index rather than a hardcoded per-direction table, so the 8 values are
 * provably monotonic by construction. Measured (headless balance script,
 * scratchpad/directions-dungeons-tuning.js): min level for a bare-attack
 * party to hold a 50% win rate at a fixed depth (300) rises smoothly
 * west->east, 66 (west) to 104 (east) — a real, ~1.6x spread across the 8
 * lanes, no cliff or degenerate step between any two adjacent directions.
 * Applied to BOTH enemy stats (harder) and rewards (more lucrative) for
 * that direction — see applyStatMul()/resolveExpedition in the UI layer.
 * v2.9: generated from farroaddungeons.csv at build time (see build.js) —
 * window.FarroadContent.DIRECTION_CONFIG is {dir:{label,mul,waveCount,
 * unlockEvery,bossName}}, one row per direction, each field independently
 * CSV-editable (was: directionMul computed from a fixed formula,
 * DUNGEON_WAVE_COUNT/DUNGEON_UNLOCK_EVERY shared across every direction —
 * Ian can now give one direction a longer dungeon or a different unlock
 * pace than another with no code touched). build.js validates all 8
 * P.DIRECTIONS values have exactly one row. */
P.DIRECTION_CONFIG=window.FarroadContent.DIRECTION_CONFIG;
P.DIRECTIONS=Object.keys(P.DIRECTION_CONFIG);
P.DIRECTION_LABELS={};
P.DIRECTIONS.forEach(function(d){P.DIRECTION_LABELS[d]=P.DIRECTION_CONFIG[d].label;});
P.directionMul=function(dir){return (P.DIRECTION_CONFIG[dir]&&P.DIRECTION_CONFIG[dir].mul)||1;};

/* ===== DISCOVERABLE CONTENT (bonus fights) =====
 * Rolled once per WON expedition node — same spirit and shape as
 * MC_CHARGE_DROP_CHANCE (a flat per-opportunity roll, checked once, no
 * extra time cost since it's a bonus riding a fight already paid for).
 * v2.9 CORRECTION: dungeons are no longer part of this roll — "rather
 * than have dungeons discovered randomly, have a dungeon unlocked every
 * 100 waves in each direction" (see P.DIRECTION_CONFIG below and
 * unlockDirectionDungeon() in the UI layer). This section
 * now covers ONLY the bonus-fight half of what was previously a combined
 * roll; EXPED_DUNGEON_SHARE is retired along with it. DUNGEON_LEN (used
 * by the scheduled-dungeon system now, not this roll) still mirrors how
 * BOSS_LEN sizes the boss (1.3-1.5x a normal fight) — a dungeon is
 * "slightly harder than the Road", not boss-tier. Measured (headless
 * balance script, scratchpad/discoverable-content-tuning.js): at 1.15,
 * the min level for a bare-attack-only party to hold a 50% win rate
 * against a dungeon is ~1.1-1.2x the min level needed against a plain
 * Road wave at the same depth (e.g. depth 400: level 88 Road vs 95
 * dungeon) — clearly short of the boss's 1.3-1.5x band, i.e. confirmed
 * "slightly harder", not a second boss. */
P.EXPED_DISCOVERY_CHANCE=0.08;
P.DUNGEON_LEN=1.15;
/* A multi-wave dungeon's own shape (waveCount-1 regular waves then a
   forced boss wave — a real "crawl" without becoming a slog at this
   game's brisk per-fight pace) and unlock pace (a new dungeon every
   unlockEvery depth reached in a direction, cumulative across every
   expedition ever sent there, not reset per trip) are now per-direction
   CSV fields too — see P.DIRECTION_CONFIG/unlockDirectionDungeon (UI
   layer) — rather than two flat constants shared by every direction.
   Shipped identical for all 8 (waveCount 4, unlockEvery 100) — same
   values the flat constants used to hold, just independently tunable now.
   Measured (same balance script as directionMul above) a genuinely
   narrow band between "wall" and "trivial" for the full 3-regular+1-boss
   run, HP/charge carried across waves with no healing between them (no
   penalty on a loss — try again any time — so a hard run is a real
   choice, not a punishing one): at ~1.3x the level that clears ONE
   regular wave in isolation, the run mostly fails partway through the
   regular waves (a genuine crawl); at ~2x that level, the whole run
   including the boss clears comfortably. This band is narrower than
   ideal — a party landing in between the two would find the run
   swingy — but the wave count/DUNGEON_LEN combination isn't a wild guess
   either; flagged here explicitly as the first candidate to retune
   against Ian's real playtesting (now a CSV edit, not a code change)
   rather than further synthetic passes, the same way DUNGEON_LEN/
   QUEST_STAGE_POWER_FRAC were both revised once real numbers came back. */

/* ===== COMPANION QUEST LINES =====
 * One 5-battle chain per roster unit, unlocked the moment they're first
 * acquired (see joinCompanion() in the UI layer). Fought by the full main
 * party — same balance the rest of the game is tuned around — but the
 * questing companion must be fielded for the attempt (Ian's call: keeps
 * it personal without needing separate solo-fight tuning).
 * v2.9 CORRECTION — was a fixed wave-equivalent per stage, shared by every
 * companion (30/150/400/800/1500). That's a bad fit for a companion whose
 * quest can be started at wildly different points in wildly different
 * runs: a fixed schedule is either trivial (attempted late) or a wall
 * (attempted right after acquiring a LATE companion, e.g. Mirel at wave
 * 1500, whose own party is nowhere near ready for a wave-1500 encounter
 * just because that's stage 1's number). Ian's call: scale each stage off
 * the PLAYER'S OWN P.powerLevel instead — stage 1 at half that player's
 * current power, ramping to stage 5 at their full current power, so a
 * quest line is always calibrated to where THIS run actually is, not an
 * absolute milestone. The wave-equivalent is the power number USED
 * DIRECTLY as a wave (P.questStageWave below), not inverted back through
 * C.levelCurve — see the comment on that function for the measured reason
 * inverting the curve breaks badly (a 5-unit party's powerLevel runs
 * 5-10x what levelCurve(their actual wave) alone would be, and squaring
 * that back through the curve overshoots the wave by roughly the square
 * of that factor — measured as an unwinnable wall from stage 1 on).
 * Still baked at FIRST ATTEMPT, not at acquisition or at each retry — see
 * P.questStageWave/attemptQuestStage (UI layer): the frozen wave AND the
 * frozen enemy stats are both fixed the moment a stage is first attempted,
 * immune to the player's power level moving on a later retry after a
 * loss, exactly like every other frozen-difficulty fight in this file.
 * `story` is placeholder-only per Ian's explicit call — he/the associate
 * author the real narrative later, the same way farroadunits.csv/the
 * content designer are already content HE owns, never touched by code
 * changes here.
 * v2.9: generated from farroadquests.csv at build time (see build.js) —
 * window.FarroadContent.QUEST_LINES is already in this exact shape,
 * {uid:[{story,powerFraction,isBoss},...5 entries]}. powerFraction is now
 * explicit PER STAGE PER COMPANION (was one shared P.QUEST_STAGE_POWER_FRAC
 * array applied to every companion identically) — real "nuanced control",
 * e.g. a gentler curve for one companion than another, straight from the
 * CSV, no code touched. isBoss defaults TRUE only on stage 5 in the
 * shipped CSV but isn't locked there — attemptQuestStage (UI layer) reads
 * it directly instead of hardcoding "stage===4". build.js validates every
 * C.ROSTER id has exactly 5 rows with strictly ascending powerFraction —
 * a missing/misordered row fails the BUILD, not a later runtime throw. */
P.QUEST_LINES=window.FarroadContent.QUEST_LINES;
/* A companion quest stage's wave-equivalent: the stage's own powerFraction
   (farroadquests.csv) of the PLAYER'S OWN current P.powerLevel, used
   DIRECTLY as a wave — see the comment on P.questStageWave below for why
   inverting through C.levelCurve was tried first and measured as breaking
   badly. Stage 5 defaults to powerFraction 1.0, landing exactly at the
   player's own current power — a fight sized to match how strong they
   actually are right now, at any point in the run. */

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
    EXPANSION comment in core.js). Originally: every unit's atk+mag+def+
    res+spd growth summed to 7.5, matching the original five's 7.3-7.7
    band — these five are now Rare (v2.12), so growth is deliberately
    NOT balance-equal to the Common five any more; every value below is
    the original x RARITY_POWER_MUL.rare (1.25, farroad-core.js),
    rounded — 9.4ish combined instead of 7.5, on purpose. See the
    RARITY comment there for why this is a real departure from the old
    balance rule, not an oversight. */
 skarn :{hp:24,atk:2.1,mag:0.9,def:1.6,res:1.5,spd:3.3},  /* berserker (Rare)         */
 sorin :{hp:38,atk:2.0,mag:2.0,def:1.6,res:1.5,spd:2.3},  /* battle-mage (Rare)       */
 nyra  :{hp:25,atk:1.1,mag:2.1,def:2.0,res:2.0,spd:2.1},  /* warden / debuffer (Rare) */
 brenn :{hp:48,atk:1.4,mag:1.3,def:1.9,res:1.9,spd:3.0},  /* evasion tank (Rare)      */
 sael  :{hp:24,atk:0.8,mag:2.5,def:1.1,res:1.6,spd:3.4}}; /* swift support (Rare)     */
/* Verified distinct rather than noise: at L20, spd:def runs 1.46 (Dorrek) to 5.94
   (Vey), and atk:mag runs 0.29 (Mirel) to 2.69 (Dorrek). */
/* v2.1: cost exponent 2.8, coefficient 0.4 — solved as a fixed point against the
   income curve so that LV 100 lands at wave 1000 exactly.
   Shape check (levels per wave): 0.8 at w1-10, then 0.1 from w100 onward — early
   levels arrive in a rush, later ones grind, which is the requested feel.
   Part of the late slowdown is intentionally NOT in this curve: it comes from the
   shared pool being split across more units and more Lore sinks competing.
   v2.9: coefficient doubled, 0.4->0.8 — Aether income was outpacing the intended
   difficulty curve, so every level now costs exactly 2x what it did (the exponent,
   and so the curve's SHAPE, is untouched — this is a flat rescale, not a steeper
   ramp). LV 10 costs 252->505 · LV 50 costs 22,865->45,731 · LV 100 costs
   159,243->318,486 · LV 1000 costs 100.5M->201.0M. */
P.expFor=function(L){return Math.round(0.8*Math.pow(L,2.8));};
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
 ['atkCrit','magCrit','chargeRate','evade'].forEach(function(k){o[k]=base[k];});
 return o;};
/* ===== SLOTS UNLOCK WITH LEVEL =====
 * 2 at L1, 3rd at L10. Ties directly to the finding that a solo character
 * can express exactly one rule: with 2 slots the heal takes the only
 * conditional. Under a SHARED pool a solo player hits L10 around wave 14-15 -
 * after the heal lesson has landed, before the boss - while a wide party reaches
 * it later per unit. The schedule self-adjusts to how thinly you are spread, so
 * "3 slots right solo, wrong in a party" needs no special case.
 * v2.9: extended from 4 slots (cap at L25) to 6 (cap at L1000) — the first
 * two entries (both 1) still guarantee 2 slots from level 1, unchanged;
 * 4th/5th/6th slots now arrive at L100/L500/L1000 instead of the old
 * schedule stopping at 4 total. Long-run levels (L100+) were previously
 * spent on nothing but raw stat growth once the slot progression was
 * exhausted at L25 — this gives depth further into the game a reason to
 * matter for build expressiveness too, not just power. */
P.SLOT_LEVELS=[1,1,10,100,500,1000];
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
/* ===== v2.9: POST-WAVE-100 HARD SCALING =====
 * waveScale() alone is one continuous sqrt curve for the whole game — no
 * threshold, no post-100 knee. Enemy SPD also never scaled with wave at all
 * (a flat per-archetype constant), while party SPD grows every level, so
 * enemies fall further behind in turn frequency the deeper a run goes — the
 * concrete mechanism behind "enemies get fewer actions" late-game. hardMul
 * layers a SEPARATE multiplier on top of the existing curve, active only
 * past HARD_FROM, reaching HARD_MAX at HARD_REF and holding there — waves
 * 1-100 are provably unaffected (hardMul(w)<=100 === 1 exactly).
 * bossSpdMul gives bosses (only) a SPD ramp of their own, since turn
 * frequency is SPD-linear and uncapped (tcRaw=TICK_K*rank/spd) — a boss
 * that keeps pace on SPD gets to actually act like a threat instead of
 * getting outpaced by an ever-faster party. */
/* Constants below tuned against a real-combat before/after harness (fixed
   party levels 40-150, boss fights at every reference wave from 100-1500)
   — see MODULES.md. The first pass (HARD_REF=1000, BOSS_HARD_EXTRA=1.35,
   BOSS_SPD_MAX_MUL=3.5) produced a hard cliff rather than a ramp: fine at
   wave 300, a total 0%-HP wipe by wave 800 even at the highest level
   tested. Stretching HARD_REF out and trimming the two boss-only
   multipliers spread the same "up to 10x" escalation over more of the
   range instead of front-loading it.
   v2.9 RETUNE: direct player report — "I'm beating level 46 enemies with
   level 20-30 units" (levelCurve(227)~=46) — that the HARD_REF=2000 pass
   above was still too soft in the wave 150-400 range being actually
   played. Pulled HARD_REF (and BOSS_SPD_REF, kept in sync) down to 800 —
   roughly 2.5x steeper through that range (hardMul(227): 3.33 -> 4.99) —
   a real strengthening without returning to the 1000/2000-vs-first-pass
   cliff. Re-validated with the same before/after harness at levels 20-30
   specifically (not retested at that combination before — the original
   pass used levels 40-150): even at the ORIGINAL HARD_REF=2000, a
   bare-bones loadout (no gambit conditions, no Lore, always-attack) was
   already losing most of the time at wave 200+ / level 20-30 (e.g. 3/20
   wins at w227/L20) — the reported "trivial win" is likely a well-built
   real loadout (gambits, healing, Lore investment) outperforming that
   baseline by a wide margin, not hardMul being weak in an absolute sense.
   Pushing HARD_REF much lower than 800 (500/400/300 were also tested)
   zeroes the bare-bones win rate out almost everywhere past wave 150,
   which would likely be unfair to a less-optimized build — so 800 is a
   deliberately moderate step, not a guess at the full gap; flagged to Ian
   to re-report after trying this, rather than continuing to retune blind
   against a synthetic baseline that can't model real gambit/Lore play. */
/* v2.9 RETUNE #2: a rigorous methodology test (realistic engaged builds —
   unique per-unit actions/gambits, healing, Lore spread evenly with
   randomly-picked bonuses, vs. a disengaged always-attack baseline, both
   scanned for the minimum level clearing an isolated fight at waves
   150-1000 across party sizes 2-5) confirmed the disengagement penalty is
   real and growing (e.g. a full 5-unit party needs level 15 engaged vs 30
   disengaged at wave 150, level 100 vs 170 at wave 1000) but that overall
   difficulty was still too soft in absolute terms — directly requested:
   "double enemy growth[s]". HARD_MAX 10->20 does this: since hardMul(w) =
   1+(HARD_MAX-1)*t for a SHARED ramp fraction t, doubling HARD_MAX roughly
   doubles the multiplier at every wave past HARD_FROM, not just at the
   HARD_REF tail (hardMul(227): 4.83 -> 9.09). Waves <=100 remain exactly
   unaffected by construction (hardMul(w<=100)===1 regardless of HARD_MAX —
   confirmed before shipping, since this is precisely the kind of claim
   worth checking, not assuming). Re-ran the same engaged/disengaged
   harness at HARD_MAX=20: absolute levels needed rise substantially
   (5-unit party wave 500: 70->100 engaged, 110->155 disengaged), but the
   disengaged/engaged RATIO barely moves (wave 500 N=5: 1.57x -> 1.55x) —
   this is a difficulty-floor raise for everyone, not specifically a wider
   engagement incentive; flagged to Ian before shipping so the tradeoff was
   explicit, and confirmed as the intended change. */
P.HARD_FROM=100; P.HARD_REF=800; P.HARD_MAX=20;
P.hardMul=function(w){
 if(w<=P.HARD_FROM)return 1;
 var t=Math.min(1,Math.sqrt((w-P.HARD_FROM)/(P.HARD_REF-P.HARD_FROM)));
 return 1+(P.HARD_MAX-1)*t;};
P.BOSS_HARD_EXTRA=1.20;        /* additional boss-only ATK/MAG multiplier */
P.BOSS_SPD_FROM=20; P.BOSS_SPD_REF=800; P.BOSS_SPD_MAX_MUL=2.2;
P.bossSpdMul=function(w){
 var t=Math.min(1,Math.sqrt(Math.max(0,w-P.BOSS_SPD_FROM)/(P.BOSS_SPD_REF-P.BOSS_SPD_FROM)));
 return 1+(P.BOSS_SPD_MAX_MUL-1)*t;};
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
 hp:[180,840]};
P.MC_GROWTH_RANGE={atk:[0.6,2.1],mag:[0.5,2.7],def:[0.8,2.4],res:[0.8,1.7],spd:[1.4,3.2],
 hp:[18,48]};
/* v2.10: atkCrit/magCrit/block/evade REMOVED from creation entirely — they
   now level like affinities, bought up over time from Aether in the AETHER
   tab (see P.PCT_STAT below) rather than fixed forever at a creation-time
   choice. A custom MC starts at 0 in all four, same "creation stays simple,
   Aether is where investment happens" principle affinities established.
   P.MC_PCT_STATS (the old percent-vs-integer display branch) is gone along
   with them — every remaining MC_STAT_KEYS member is a plain integer stat,
   so mcBuildStats/mcStatDisplay both drop their now-dead percent branch.
   Every stat starts at 0 (its roster-derived floor — see mcLerp, point=MIN
   always maps to statRange[0], so 0 points never means a literal 0 in-game
   stat) rather than a pre-filled midpoint, so building toward a plan means
   only ever ADDING points, never having to first subtract from stats you
   don't want. POOL is deliberately HALF of the theoretical max spend
   (P.MC_STAT_KEYS.length x 15) — an even split still lands mid-range on
   every stat, while a focused build can afford to max a third of the stats
   outright and leave the rest at floor. */
P.MC_STAT_KEYS=['atk','mag','def','res','spd','hp'];
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
/* v2.9: +10 stat-scaling charge actions (one damage + one support per core
   stat — see the CHARGE_ACTIONS comment in core.js), same rare-drop pool as
   the original 8 corner charges, not the 3 generic starters. */
P.MC_CHARGE_DROP_POOL=['tideturn','lastlight','sunder','gravewind','reckoning',
 'bulwarkoath','emberglut','hollowtoll',
 'atk_reckless','mag_lance','def_slam','res_strike','spd_flurry',
 'atk_cry','mag_font','def_bulwark','res_ward','spd_fleet'];
/* Checked once per random-phase wave, replacing that wave's normal action/
   condition drop rather than stacking on top of it — a charge action is a
   bigger deal than either, so it doesn't also cost the player their usual
   drop that wave. v2.9: 5%->10% — Ian reported waves 20-400 without much
   variety here, so the rate is doubled. At 10% per wave, one charge-drop
   event lands roughly every 10 waves; collecting all 8 (a coupon-collector
   problem, expectation 8 x H(8) ≈ 21.7 events) now takes on the order of
   200+ waves of random drops, down from 400+ — still meaningfully rarer
   than the guaranteed per-wave action/condition drop it can replace. */
P.MC_CHARGE_DROP_CHANCE=0.10;
/* Rarity (v2.12): 2 of the 18-action pool (reckoning, hollowtoll) are now
   Legendary rather than Rare — nested roll INSIDE the 10% gate above, not a
   second independent chance: once a charge-drop event fires, this decides
   whether it's the Legendary pair or the remaining 16 Rare ones, uniform
   within whichever tier is picked. Reasoned starting point, same as
   MC_CHARGE_DROP_CHANCE itself — retune from balance-script results if a
   Legendary charge turns out to land far more/less often than intended. */
P.MC_LEGENDARY_CHARGE_CHANCE=0.15;
/* Equipment (v2.14): "about as rare as units" (Ian) — reuses the exact
   0.10 figure that already means "rare special content" in two places
   above (this and P.PULL_ODDS.unit in farroad-ui.js), rather than
   inventing a third number. Checked in randomDrop() WITHOUT the G.mc
   guard MC_CHARGE_DROP_CHANCE uses — equipment drops for every run,
   companion-only included, same as the ordinary action/condition drop
   it replaces when it fires. */
P.EQUIP_DROP_CHANCE=0.10;
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
  stats[k]=Math.round(v);
  if(P.MC_GROWTH_RANGE[k])growth[k]=Math.round(P.mcLerp(P.MC_GROWTH_RANGE[k],points[k])*10)/10;}
 var hp=stats.hp;delete stats.hp;               /* hp is top-level on a unit, not under .stats */
 return {stats:stats,hp:hp,growth:growth};};

/* ===== v2.9: POWER LEVEL =====
 * One number combining every investment axis into a single "how far along
 * am I" readout — roster depth, character levels, Lore, and wave reached.
 * Each term is put on a comparable, level-equivalent scale before summing,
 * so no one input silently dominates or vanishes at typical pace:
 *   - wave: run through C.levelCurve(), the SAME wave->level-equivalent
 *     curve waveScale()/enemy difficulty is already built from (and the
 *     same one the Road's per-enemy Lv tag uses) — reuses an already-
 *     calibrated conversion rather than inventing a second one.
 *   - unit levels: summed across every OWNED unit (not just fielded — a
 *     benched investment is still a real one), already level-scale by
 *     construction.
 *   - unit count: each owned unit worth a flat POWER_PER_UNIT on top of
 *     its own level term — recruiting a companion has value (roster
 *     depth, more gambit/action coverage) beyond just its current,
 *     possibly-low level.
 *   - Lore: summed actionBonusTotal() across every action with any
 *     investment — literally the sum of every LvN badge already visible
 *     on the LORE tabs, so the total is directly cross-checkable against
 *     what's on screen there.
 * POWER_PER_UNIT/POWER_PER_LORE are named, tunable constants rather than
 * inlined literals — this is a display metric, not balance-critical, so a
 * reasoned starting weighting (not a simulated one) is appropriate, but
 * kept easy to retune if it doesn't feel right in practice. */
P.POWER_PER_UNIT=15;
P.POWER_PER_LORE=1;
/* v2.10: purchased affinity points (NOT a unit's authored baseline — see the
   AFFINITY INVESTMENT comment below) count toward Power Level, same
   treatment loreLevels already gets. Weighted below unitLevels/loreLevels'
   effective 1-per-point rate: affinityCostToNext is a flat linear-escalation
   curve (8/16/24 Aether...) against costToNext's ~L^2.8 curve, so a single
   point is a far smaller investment than a level at any real depth — 0.5 is
   a reasoned starting weight, not a simulated one (this is a display metric,
   same caveat POWER_PER_UNIT/POWER_PER_LORE already carry), kept easy to
   retune if it doesn't feel right in practice. */
P.POWER_PER_AFFINITY_POINT=0.5;
P.powerLevel=function(g){
 var waveLevel=C.levelCurve(g.wave||1);
 var unitLevels=0,unitCount=0;
 Object.keys(g.owned||{}).forEach(function(uid){
  unitCount++;unitLevels+=(g.lvl&&g.lvl[uid])||1;});
 /* v2.9: Broad now counts (matches actionLevel() in the UI layer — "leveling
    up broad does not level up the action; it should count towards its
    level"), so this stays the literal sum of every action's displayed LvN. */
 var loreLevels=0;
 Object.keys(g.bonuses||{}).forEach(function(aid){
  var b=g.bonuses[aid];loreLevels+=C.actionBonusTotal(b)+(b.broad||0);});
 /* v2.10: g.affinities[uid][axis] is PURCHASED POINTS ONLY (see the AETHER-
    investment comment below) — a companion's own authored baseline does NOT
    count here, exactly like unitLevels counting real level-ups rather than
    a unit's starting stats. */
 var affinityPoints=0;
 Object.keys(g.affinities||{}).forEach(function(uid){
  var a=g.affinities[uid];if(!a)return;
  Object.keys(a).forEach(function(axis){affinityPoints+=a[axis]||0;});});
 /* v2.10: g.statInvest[uid][stat] is PURCHASED STEPS ONLY (Block/Evade/
    ATK-Crit/MAG-Crit's own baseline — the CSV-authored atk_crit/mag_crit/
    block/evade columns — does NOT count), same treatment affinityPoints
    just got above. */
 var pctStatSteps=0;
 Object.keys(g.statInvest||{}).forEach(function(uid){
  var s=g.statInvest[uid];if(!s)return;
  Object.keys(s).forEach(function(stat){pctStatSteps+=s[stat]||0;});});
 return Math.round(waveLevel+unitLevels+unitCount*P.POWER_PER_UNIT+loreLevels*P.POWER_PER_LORE+
  affinityPoints*P.POWER_PER_AFFINITY_POINT+pctStatSteps*P.POWER_PER_PCT_STAT_STEP);};
/* ===== AFFINITY INVESTMENT (v2.10) =====
 * Fire/Water/Earth/Air/Light/Dark/Body/Spirit — see farroad-core.js's own
 * comment (AFFINITY_CAP/affinityMul/affTerm) for the combat-facing half of
 * this feature; this half is the ECONOMY layer, spent from the same shared
 * Aether pool leveling already draws from. A unit's EFFECTIVE raw affinity
 * combat reads is baseline (C.ROSTER[uid].affinity / C.ARCH[key].affinity,
 * CSV-authored) PLUS purchased points (G.affinities[uid][axis], UI layer) —
 * computed once, at the point a live C.makeUnit is built (buildParty/
 * buildExpeditionParty/buildEnemies, farroad-ui.js), mirroring exactly how
 * P.statsAt already combines a base stat with level-derived growth. Kept as
 * two separate numbers rather than one mutated "current value" specifically
 * so "how many points has the player actually bought" stays a real,
 * separately-readable figure — both for the cost curve below (escalates off
 * points ALREADY invested in that axis on that unit) and for Power Level
 * above (only counts what the player actually spent). Enemies have no
 * investment layer at all — buildEnemies reads C.ARCH[key].affinity
 * unmodified, no G.affinities lookup for them.
 * Cost mirrors bonusPrice's per-action linear-escalation shape (farroad-
 * core.js) more directly than costToNext's per-unit-level ratchet-discount
 * shape does, since this is a per-STAT track, not a whole-unit level: the
 * Nth point bought on one axis on one unit costs N*AFFINITY_COST_BASE. The
 * UI stops offering a purchase once the EFFECTIVE raw (baseline+purchased)
 * reaches AFFINITY_CAP exactly — C.affinityMul plateaus there by
 * construction (Math.min clamps the input), so a further point could not
 * move the number even if bought. */
/* v2.10: 8 -> 4.0976, paired with AFFINITY_CAP doubling (20 -> 40,
   farroad-core.js) — Ian's ask was "double the number of times it needs
   to be leveled [and] double the cost to max them", and those two
   requirements don't fall out of just doubling one constant: a linear-
   escalation curve's TOTAL cost is triangular in the point count, so
   doubling AFFINITY_CAP alone (with the base unchanged) would have
   raised the cost to fully max an axis by ~3.9x (8*(1+...+40)=6,560),
   not 2x. Solved directly instead: the base that makes the doubled-
   length curve sum to exactly double the old total (1,680 -> 3,360) is
   BASE_old*(N_old+1)/(2*N_old+1) = 8*21/41 = 4.0976 — not a round
   number, so affinityCostToNext rounds its output (matching every other
   per-step cost function in this file) rather than showing fractional
   Aether. */
P.AFFINITY_COST_BASE=4.0976;
P.affinityCostToNext=function(investedPoints){
 return Math.round(P.AFFINITY_COST_BASE*(investedPoints+1));};

/* ===== EVADE/CRIT INVESTMENT (v2.10) =====
 * "Level like affinities" — but NOT affinities' logarithmic ±80% shape.
 * Evade/ATK-Crit/MAG-Crit are already bounded 0-to-a-hard-engine-cap
 * percentages (C.CAP_EVADE/C.CAP_CRIT, farroad-core.js), the same shape
 * Recovery (P.REST/P.REST_CAP/P.REST_STEP, recoveryCost() in the UI layer)
 * already solves — fixed step per purchase, geometrically escalating cost,
 * hard-capped. Reused here as independent instances of that exact
 * mechanic rather than adapting the affinity curve to a shape it wasn't
 * designed for (affinityMul is symmetric and unbounded either direction;
 * these are one-directional and already capped by the engine).
 * No new baseline data needed — atk_crit/mag_crit/evade already exist as
 * real per-unit/per-archetype CSV columns (C.ROSTER/C.ARCH) and already
 * ARE the baseline; G.statInvest (UI layer) holds only the purchased step
 * COUNT on top, same "baseline + purchased, kept separate" shape
 * G.affinities already established and for the same reason (a real,
 * separately-readable "how much has the player actually bought" figure).
 * Evade's step originally matched P.REST_STEP (0.03) for continuity with
 * Recovery — halved again since (see the v2.10 note below), so that
 * continuity no longer holds exactly, just a shared lineage.
 * Crit's larger step/cost reflects a bigger ceiling (1.00 vs Evade's 0.40)
 * and a categorically bigger payoff (crit multiplies the WHOLE hit by
 * C.CRIT_MUL) — a longer climb to a more valuable stat.
 * v2.10 Block removal: Block dropped out of this table entirely (and out
 * of the engine — see farroad-core.js) once Ian pointed out Body affinity
 * already covers physical damage reduction, making a second overlapping
 * stat redundant. */
/* Per-stat costBase/costGrowth retuned after the first pass measured WAY
   outside the target range (a naive shared 1.45 growth at each stat's
   initial step count priced ATK/MAG Crit at 52,484 Aether to cap — 31x
   the ~1,680 one maxed affinity axis costs, effectively making 100% crit
   unreachable in a normal run). Re-solved per stat (VM-sandbox balance
   script, scratchpad) for a total cost-to-cap in the same rough order as
   Recovery's own full climb (890 Aether) and one maxed affinity axis
   (1,680): Evade 1,023 (step originally matched Recovery's own 0.03 for
   continuity), ATK/MAG Crit 2,077 each — deliberately pricier than
   Evade, reflecting the bigger ceiling (1.00 vs 0.40) and bigger payoff
   (crit multiplies the WHOLE hit), not forced to the same total as a
   cheaper stat.
   v2.10: "double the number of times it needs to be leveled [and]
   double the cost to max them" — both step (so twice as many purchases
   reach the same cap) AND costGrowth retuned together, same reason
   AFFINITY_COST_BASE couldn't just be left alone above: a geometric
   curve's total is exponential in step count, so halving the step size
   alone (doubling how many terms get summed) would have made these
   curves cost FAR more than double — solved numerically instead
   (VM-sandbox script) for the growth rate that lands each doubled-length
   curve back at exactly 2x its old total, holding costBase fixed as the
   one deliberately-preserved number (what the FIRST purchase costs is
   unchanged): Evade 27 steps for 2,046 Aether (was 14 steps, 1,023),
   ATK/MAG Crit 25 steps for 4,153 Aether each (was 13 steps, 2,077). */
P.PCT_STAT={
 evade:  {step:0.015, cap:C.CAP_EVADE, costBase:8,  costGrowth:1.144},
 atkCrit:{step:0.04,  cap:C.CAP_CRIT,  costBase:15, costGrowth:1.167},
 magCrit:{step:0.04,  cap:C.CAP_CRIT,  costBase:15, costGrowth:1.167}};
P.pctStatCost=function(stat,steps){var s=P.PCT_STAT[stat];
 return Math.round(s.costBase*Math.pow(s.costGrowth,steps));};
/* effective = baseline + steps*step, hard-clamped to the stat's own cap —
   the same value the AETHER tab shows and the UI layer's effectivePctStats
   feeds into a live unit's stats. */
P.pctStatValue=function(baseline,stat,steps){var s=P.PCT_STAT[stat];
 return Math.min(s.cap,baseline+steps*s.step);};
P.pctStatMaxed=function(baseline,stat,steps){
 return P.pctStatValue(baseline,stat,steps)>=P.PCT_STAT[stat].cap-1e-9;};

/* v2.10: purchased Block/Evade/Crit steps count toward Power Level too, same
   treatment affinity points already get (see P.POWER_PER_AFFINITY_POINT
   above) — every real Aether-sink should count uniformly, and this is one. */
P.POWER_PER_PCT_STAT_STEP=0.5;

/* A companion quest stage's wave-equivalent: DIRECTLY proportional to the
   player's own current P.powerLevel — that stage's OWN powerFraction
   (farroadquests.csv, per companion per stage — see the comment above
   P.QUEST_LINES) of it, used as a wave number outright.
   NOT inverted back through C.levelCurve (the wave->level curve powerLevel
   itself is partly built from) — tried that first and it breaks badly:
   powerLevel SUMS every owned unit's level on top of the wave term, so a
   5-unit party's powerLevel routinely runs 5-10x what levelCurve(their
   actual wave) alone would be, and levelCurve is a SQUARE ROOT curve, so
   inverting a 5-10x-inflated "level" back through it overshoots the wave
   by roughly the SQUARE of that factor. Measured directly (headless
   battle sim, a real level-80 5-unit party at wave 300, power 536): stage
   1 alone came out at wave 7130 and every one of 5 stages lost 15/15 — not
   a genuine capstone, an unwinnable wall from stage 1 on. Multiplying
   powerLevel directly by the stage fraction instead measured correctly: a
   trivial stage 1 rising to a real, losable-but-fair stage 5 (7/20 and
   3/20 win rates for early/mid-game parties respectively, at their
   OWN power — a real capstone, not a wall). */
P.questStageWave=function(g,uid,stageIdx){
 var frac=P.QUEST_LINES[uid][stageIdx].powerFraction;
 return Math.max(1,Math.round(frac*P.powerLevel(g)));};
/* v2.10: clearing a companion quest stage now pays Aether — was nothing at
   all (the reward was purely the story beat + the next stage unlocking).
   Linear across the 5 stages, stage 1 (stageIdx 0) at the floor and stage
   5 (stageIdx 4) at the ceiling — same "scale with how far into the line
   you are" shape every other milestone reward in this file already uses
   (bossAether/dupUnitAether scale with wave depth; this scales with quest
   progress instead, since a quest line's own difficulty already scales off
   P.powerLevel via questStageWave above, not off the Road's wave number). */
P.QUEST_STAGE_AETHER_MIN=100;
P.QUEST_STAGE_AETHER_MAX=500;
P.questStageAether=function(stageIdx){
 return Math.round(P.QUEST_STAGE_AETHER_MIN+
  stageIdx*(P.QUEST_STAGE_AETHER_MAX-P.QUEST_STAGE_AETHER_MIN)/4);};
return P;})(window.FarroadCore);
