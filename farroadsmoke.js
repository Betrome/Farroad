#!/usr/bin/env node
/* =============================================================================
 * FARROAD — farroad-smoke.js
 * The smoke test, ported off the in-page button and onto the modules.
 *
 *   node farroad-smoke.js
 *
 * THE POINT OF THIS FILE: until now "smoke test status" meant "Ian pressed a
 * button and told me". Every bug that has cost a round trip in this project was
 * one an execution would have caught in seconds — cfg/WAVE_EXP/busy were all
 * undeclared identifiers, and the pull bug was a result written to a log on a
 * tab the player was not looking at. This runs without a browser and without
 * Ian, so "shipped" can mean "ran".
 *
 * It loads the modules the same way the fused page does: core first, then
 * progression with core injected. A minimal window shim stands in for the two
 * export statements, which are the only globals either module touches.
 * =========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const srcDir = path.join(__dirname, 'src');
const load = f => fs.readFileSync(path.join(srcDir, f), 'utf8');

/* --- headless module load ------------------------------------------------- */
const sandbox = { window: {}, Math: Math, JSON: JSON, console: console };
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

function run(name) {
  try { vm.runInContext(load(name), sandbox, { filename: name }); }
  catch (e) { fail(`${name} threw on load: ${e.message}`); throw e; }
}
run('farroad-core.js');
run('farroad-progression.js');
run('farroad-save.js');

const C = sandbox.window.FarroadCore;
const P = sandbox.window.FarroadProgression;
const V = sandbox.window.FarroadSave;

/* --- tiny assertion harness ---------------------------------------------- */
let passed = 0, failed = 0;
const fails = [];
function ok(name, cond, detail) {
  if (cond) { passed++; }
  else { failed++; fails.push(name + (detail ? ' — ' + detail : '')); }
}
function fail(msg) { failed++; fails.push(msg); }

/* =========================== 1. MODULES LOAD ============================== */
ok('core exported', !!C);
ok('progression exported', !!P);
ok('core is headless', typeof sandbox.document === 'undefined');

/* ============== 2. FREE-VARIABLE SWEEP (the cfg/WAVE_EXP class) ===========
 * Under 'use strict' an undeclared identifier throws ReferenceError at the
 * moment it is reached, not at parse. Three separate bugs in this project were
 * exactly that, each surviving because the line was only reached in a state
 * nobody had exercised. Calling every exported function is the cheap sweep. */
Object.keys(C).forEach(k => {
  if (typeof C[k] !== 'function') return;
  try { C[k](); } catch (e) {
    if (e instanceof ReferenceError) fail(`core.${k}: ReferenceError — ${e.message}`);
  }
});
Object.keys(P).forEach(k => {
  if (typeof P[k] !== 'function') return;
  try { P[k](1, 1); } catch (e) {
    if (e instanceof ReferenceError) fail(`progression.${k}: ReferenceError — ${e.message}`);
  }
});
/* BUGFIX: the sweep above calls every exported function with no args at all,
   including C.setWave() — which sets the module-level CURRENT_WAVE to
   undefined as a real side effect, not a no-op. Every damage calculation
   after that reads NaN out of K_of() (K_BASE*waveScale(undefined)), which
   silently zeroes out combat: a hit's damage becomes NaN, HP comparisons
   against NaN are always false, and checkEnd() reads that as an instant
   win/loss. digestRun() above never noticed only because its foes array is
   always empty (P.buildEnemies doesn't exist — see note there) and reproduc-
   ibility doesn't care WHAT the corrupted value is, only that it's the same
   both times. Any later section that runs a real multi-hit battle inherits
   the corruption silently. Reset explicitly rather than leaving the sweep's
   side effect to leak into every section that follows it. */
if (C.setWave) C.setWave(1);

/* ===================== 3. DETERMINISM / NO-OP PROOF ======================= *
 * Same seed must give the same fight, every time. This is what makes the
 * refactor checkable: capture the digest before and after any change and
 * compare. It is also what makes replayable async PvP feasible (roadmap 6). */
function digestRun(seed, waves) {
  const out = [];
  for (let w = 1; w <= waves; w++) {
    const rng = C.makeRNG(seed + w);
    const party = [C.makeUnit({ id: 'p1', name: 'Kesh', isParty: true, level: 1, slotIndex: 0,
      row: 'front', stats: { atk: 26, mag: 18, def: 20, res: 16, spd: 100 },
      slots: [{ cond: 'none', action: 'strike' }, { cond: 'none', action: 'strike' }] })];
    const foes = P.buildEnemies ? P.buildEnemies(w) : [];
    const b = C.makeBattle(party.concat(foes), { rng: rng, enrage: true });
    let guard = 0;
    while (!b.over && guard++ < 4000) C.step(b);
    out.push(w + ':' + b.over + ':' + b.beat + ':' + party[0].hp);
  }
  return out.join('|');
}

let d1 = null, d2 = null;
try { d1 = digestRun(12345, 10); d2 = digestRun(12345, 10); } catch (e) {
  fail('determinism run threw: ' + e.message);
}
ok('seeded runs are reproducible', d1 !== null && d1 === d2);

/* ================== 4. CURVES ARE MONOTONIC AND FINITE =================== */
if (C.waveScale) {
  let mono = true, finite = true, prev = 0;
  for (let w = 1; w <= 10000; w += 37) {
    const s = C.waveScale(w);
    if (!isFinite(s)) finite = false;
    if (s < prev) mono = false;
    prev = s;
  }
  ok('waveScale is finite to w10000', finite);
  ok('waveScale is monotonic', mono);
}

/* ================== 5. HEADLESS BATCH — the idle-quest shape =============
 * Roadmap item 4 sends benched units on automated quests: combat run away from
 * the main loop, possibly many times per tick. This asserts the core can do
 * that at all, and measures the cost so the quest system can be budgeted. */
const t0 = Date.now();
let batch = 0;
try {
  for (let i = 0; i < 200; i++) { digestRun(1000 + i, 1); batch++; }
} catch (e) { fail('headless batch threw: ' + e.message); }
const ms = Date.now() - t0;
ok('200 headless fights complete', batch === 200, batch + '/200');

/* ===================== 6. SAVE / LOAD ROUND-TRIP ===========================
 * GDD's own suggested guard: a snapshot that omits a real input to combat
 * replays a DIFFERENT fight while looking correct, and it does so silently.
 * This does not exercise a live G object (that lives in the DOM-bound UI
 * layer) — it builds a representative fake one from the same field list the
 * save module promises to carry, and checks the round trip is lossless AND
 * that the reseeded RNG lands on the exact state the original had reached,
 * by comparing the NEXT roll each would produce, not the last one taken
 * before the save (that value was already spent when the save happened). */
(function(){
 ok('save module exported', !!V);
 if(!V)return;
 var rng=C.makeRNG(4242);
 for(var i=0;i<38;i++)rng.next();          /* stand-in for calls made during play */
 var fakeG={seed:4242,rng:{calls:rng.calls},wave:12,farthest:14,bossesCleared:0,
  aether:123.4,lore:2,marks:56,wipes:1,party:['kesh','ansa'],
  actions:['strike','ember','sear'],conditions:['none','foe_armoured'],
  actionCounts:{sear:1},condCounts:{foe_armoured:1},bonuses:{ember:{power:1}},
  recovery:{kesh:2},loadout:{kesh:[{cond:'none',action:'strike'}]},
  hpCarry:{kesh:0.8},touched:{},clearedWaves:{1:1,2:1},
  lvl:{kesh:5,ansa:1},bank:{kesh:12,ansa:0},maxLevelEver:5,owned:{kesh:1,ansa:1},
  enrage:true,idleAcc:3,dropQueue:[],dropHistory:[],
  expedition:{partyIds:['dorrek','vey'],startedAt:1700000000000-3600000,
   lastResolvedAt:1700000000000-3600000,ew:3,hpFrac:0.7,bank:{aether:40,marks:5}},
  expeditionLog:[{at:1700000000000,text:'Dorrek, Vey set out to explore.'}]};
 var restored=null,threw=null;
 try{
  var snap=V.serialize(fakeG,1700000000000);
  restored=V.deserialize(JSON.parse(JSON.stringify(snap)),C);     /* JSON round-trip too */
 }catch(e){threw=e;}
 ok('save round-trip does not throw', !threw, threw&&threw.message);
 ok('save round-trip produces a G object', !!restored);
 if(restored){
  ok('save round-trip preserves wave/farthest/party',
   restored.wave===12&&restored.farthest===14&&restored.party.length===2&&restored.party[1]==='ansa');
  ok('save round-trip preserves levels and bank',
   restored.lvl.kesh===5&&restored.bank.kesh===12&&restored.maxLevelEver===5);
  ok('save round-trip preserves actions/conditions/loadout',
   restored.actions.indexOf('sear')>=0&&restored.conditions.indexOf('foe_armoured')>=0&&
   restored.loadout.kesh&&restored.loadout.kesh[0].action==='strike');
  ok('save round-trip preserves an in-progress expedition',
   restored.expedition&&restored.expedition.partyIds.length===2&&
   restored.expedition.partyIds[0]==='dorrek'&&restored.expedition.ew===3&&
   restored.expedition.bank.aether===40);
  ok('save round-trip preserves the expedition log',
   restored.expeditionLog&&restored.expeditionLog.length===1&&
   restored.expeditionLog[0].text.indexOf('Dorrek')>=0);
  var expectedNext=rng.next(), actualNext=restored.rng.next();
  ok('save round-trip rebuilds the RNG to the exact saved position',
   expectedNext===actualNext, expectedNext+' vs '+actualNext);
 }
 /* OLD-SAVE COMPAT: a snapshot from before phase 1 has neither field at all —
    deserialize must default them (null/[]) rather than throw or leave them
    undefined, the same contract every other FIELDS entry already gets. */
 var oldSnap=null,oldThrew=null,oldRestored=null;
 try{
  oldSnap=V.serialize(fakeG,1700000000000);
  delete oldSnap.expedition; delete oldSnap.expeditionLog;
  oldRestored=V.deserialize(JSON.parse(JSON.stringify(oldSnap)),C);
 }catch(e){oldThrew=e;}
 ok('old save missing expedition fields does not throw', !oldThrew, oldThrew&&oldThrew.message);
 ok('old save missing expedition fields defaults to null/[]',
  !!oldRestored&&oldRestored.expedition===null&&Array.isArray(oldRestored.expeditionLog)&&
  oldRestored.expeditionLog.length===0);
})();

/* =================== 7. CUSTOMISABLE FIRST UNIT (roadmap 1) ===============
 * The point-buy math (P.mcBuildStats) is what keeps a player-built character
 * inside already-shipped bounds — see the comment above P.MC_STAT_RANGE in
 * progression.js. This checks the bounds actually hold, that spend tracking
 * is exact (the UI gates its confirm button on this being exactly right,
 * not just close), and that every offered charge action is real. */
(function(){
 var keys=P.MC_STAT_KEYS;   /* single source of truth — see progression.js */
 var lo={}, hi={}, mid={};
 /* An even split doesn't divide cleanly (75/10 stats = 7.5) — spread the
    remainder across the first few stats rather than assume any specific
    divisibility, so this keeps working if the pool or stat count changes. */
 var base=Math.floor(P.MC_POINTS_TOTAL/keys.length),remainder=P.MC_POINTS_TOTAL-base*keys.length;
 keys.forEach(function(k,i){lo[k]=P.MC_POINT_MIN;hi[k]=P.MC_POINT_MAX;mid[k]=base+(i<remainder?1:0);});
 var atFloor=P.mcBuildStats(lo), atCeil=P.mcBuildStats(hi), atMid=P.mcBuildStats(mid);
 function valOf(built,k){return k==='hp'?built.hp:built.stats[k];}
 ok('mcBuildStats: all-min points land exactly on each stat\'s roster floor',
  keys.every(function(k){return valOf(atFloor,k)===P.MC_STAT_RANGE[k][0];}),
  keys.filter(function(k){return valOf(atFloor,k)!==P.MC_STAT_RANGE[k][0];}).join(','));
 ok('mcBuildStats: all-max points land exactly on each stat\'s roster ceiling',
  keys.every(function(k){return valOf(atCeil,k)===P.MC_STAT_RANGE[k][1];}),
  keys.filter(function(k){return valOf(atCeil,k)!==P.MC_STAT_RANGE[k][1];}).join(','));
 var growthKeys=Object.keys(P.MC_GROWTH_RANGE);
 ok('mcBuildStats: every stat with a growth curve rises with points spent on it',
  growthKeys.length>0 && growthKeys.every(function(k){return atCeil.growth[k]>atFloor.growth[k];}));
 ok('mcBuildStats: stats with no growth curve (crit/block/evade) are not given one',
  P.MC_PCT_STATS.every(function(k){return atFloor.growth[k]===undefined;}));
 ok('mcPointsSpent: a balanced 5-per-stat build spends exactly the pool',
  P.mcPointsSpent(mid)===P.MC_POINTS_TOTAL);
 ok('MC_POINTS_TOTAL is exactly half of the theoretical max spend (stats x MC_POINT_MAX)',
  P.MC_POINTS_TOTAL===(P.MC_STAT_KEYS.length*P.MC_POINT_MAX)/2);
 ok('MC_POINT_MIN is 0 — every stat can be dumped to its roster floor with no points spent',
  P.MC_POINT_MIN===0);
 ok('a build that maxes exactly half the stats (5x15) and floors the rest spends exactly the pool',
  (function(){var half={};keys.forEach(function(k,i){half[k]=i<5?P.MC_POINT_MAX:P.MC_POINT_MIN;});
   return P.mcPointsSpent(half)===P.MC_POINTS_TOTAL;})());
 var allChargeIds=P.MC_STARTER_CHARGES.concat(P.MC_CHARGE_DROP_POOL);
 var allChargesReal=allChargeIds.every(function(id){var a=C.ACTIONS[id];return !!a&&!!a.isCharge;});
 ok('every starter/drop-pool charge id resolves to a real charge action in C.ACTIONS',
  allChargesReal, allChargeIds.join(','));
 var companionCharges=['oath','hearthlight','vowofstone','ninefold','ashfall'];
 ok('starter/drop-pool charges have no overlap with the five companions\' own',
  allChargeIds.every(function(id){return companionCharges.indexOf(id)<0;}));
 ok('starter charges have no overlap with the rare-drop pool (a starter pick is never a duplicate drop)',
  P.MC_STARTER_CHARGES.every(function(id){return P.MC_CHARGE_DROP_POOL.indexOf(id)<0;}));
 ok('every starter charge is plain: power present, no attached status/lifesteal/revive',
  P.MC_STARTER_CHARGES.every(function(id){var a=C.ACTIONS[id];
   return !!a.power && !a.applies && !a.lifesteal && !a.revive;}));
 ok('MC_CHARGE_DROP_CHANCE is a real probability, low enough to read as "rare"',
  P.MC_CHARGE_DROP_CHANCE>0 && P.MC_CHARGE_DROP_CHANCE<=0.10);
})();

/* =================== 8. PER-ACTION LINEAR LORE BONUS COST ==================
 * v2.9 rework: price is keyed to the ACTION's total upgrade count (every
 * non-broad bonus on it, combined), not any one bonus's own stack count — a
 * fresh action's first upgrade costs 1 Lore, and every further upgrade on
 * that SAME action costs one more than the last, whichever bonus type it is.
 * This must hold: stack 1 on a fresh action costs exactly 1; the price for
 * ANY bonus rises purely from how many upgrades the ACTION already has, so
 * buying bonus A then bonus B on the same action escalates B's price even
 * though B itself has zero stacks; broad stays flat and doesn't feed or pay
 * into that counter; and bonusSpend's closed-form total matches summing the
 * actual per-purchase prices in sequence. */
(function(){
 var strike=C.ACTIONS.strike;
 ok('bonusPrice: a fresh action\'s first upgrade (total=0) costs exactly 1 Lore',
  C.bonusPrice(strike,'potent',0)===1);
 ok('bonusPrice: each further upgrade on the same action costs one more than the last',
  C.bonusPrice(strike,'potent',1)===2 && C.bonusPrice(strike,'potent',2)===3 &&
  C.bonusPrice(strike,'potent',9)===10);
 ok('bonusPrice: price depends on the ACTION\'s total, not the bonus\'s own stack count — '+
  'a bonus with zero stacks of its own still costs more once the action has other upgrades',
  C.bonusPrice(strike,'lasting',0)===1 && C.bonusPrice(strike,'lasting',3)===4);
 ok('actionBonusTotal: sums every non-broad bonus on the action, excludes broad',
  C.actionBonusTotal({potent:2,lasting:1,broad:5})===3 && C.actionBonusTotal({broad:5})===0);
 /* Broad is a one-time unlock (applyBonuses flips single->multi target the
    moment ONE stack exists; further stacks do nothing), so it stays exempt
    from the linear counter — it should just cost its own flat price forever,
    regardless of the action's other upgrades, and never inflate their price. */
 ok('bonusPrice: Broad is flat at BONUS_COST_BROAD regardless of the action\'s total',
  C.bonusPrice(strike,'broad',0)===C.BONUS_COST_BROAD &&
  C.bonusPrice(strike,'broad',10)===C.BONUS_COST_BROAD);
 ok('actionBonusTotal excludes broad from what OTHER bonuses escalate against',
  C.bonusPrice(strike,'potent',C.actionBonusTotal({broad:7}))===1);
 var map={strike:{potent:2,lasting:1,broad:3}};
 var expectedLinear=1+2+3;                       /* 3 non-broad stacks total, triangular sum */
 var expectedBroad=3*C.BONUS_COST_BROAD;
 ok('bonusSpend: closed-form total matches the triangular sum of non-broad stacks plus flat broad',
  C.bonusSpend(map)===expectedLinear+expectedBroad,
  C.bonusSpend(map)+' vs '+(expectedLinear+expectedBroad));
})();

/* =================== 9. ROSTER EXPANSION 5->10 (prereq for item 4) ========
 * A hand-authored batch is exactly where a copy-paste slip (duplicate id,
 * a stat pushed past the range it's supposed to respect, a charge action
 * reused from the MC's reserved pools) survives review by eye. These reuse
 * the SAME bounds the customisable-MC screen is gated on, so they double as
 * a regression guard for any future roster edit, not just this one. */
(function(){
 var R=C.ROSTER;
 ok('ROSTER has exactly 10 entries', R.length===10, 'got '+R.length);
 var ids=R.map(function(r){return r.id;});
 var uniqueIds=ids.filter(function(id,i){return ids.indexOf(id)===i;});
 ok('every ROSTER id is unique', uniqueIds.length===ids.length,
  ids.filter(function(id,i){return ids.indexOf(id)!==i;}).join(','));
 var statKeys=['atk','mag','def','res','spd','atkCrit','magCrit','block','evade'];
 var outOfRange=[];
 R.forEach(function(r){
  statKeys.forEach(function(k){
   var range=P.MC_STAT_RANGE[k];if(!range)return;
   var v=r.stats[k];
   if(v<range[0]||v>range[1])outOfRange.push(r.id+'.'+k+'='+v+' (range '+range[0]+'-'+range[1]+')');});
  var hpRange=P.MC_STAT_RANGE.hp;
  if(r.hp<hpRange[0]||r.hp>hpRange[1])outOfRange.push(r.id+'.hp='+r.hp+' (range '+hpRange[0]+'-'+hpRange[1]+')');});
 ok('every ROSTER unit\'s stats (incl. hp) fall within P.MC_STAT_RANGE', outOfRange.length===0, outOfRange.join('; '));
 var growthKeys2=['atk','mag','def','res','spd','hp'];
 var growthOut=[];
 R.forEach(function(r){
  var g=P.GROWTH[r.id];if(!g){growthOut.push(r.id+': no P.GROWTH entry');return;}
  growthKeys2.forEach(function(k){
   var range=P.MC_GROWTH_RANGE[k];if(!range)return;
   if(g[k]<range[0]||g[k]>range[1])growthOut.push(r.id+'.'+k+'='+g[k]+' (range '+range[0]+'-'+range[1]+')');});});
 ok('every ROSTER unit has a P.GROWTH entry within P.MC_GROWTH_RANGE', growthOut.length===0, growthOut.join('; '));
 var newFive=['skarn','sorin','nyra','brenn','sael'];
 var budgetOff=newFive.filter(function(id){
  var g=P.GROWTH[id];var sum=g.atk+g.mag+g.def+g.res+g.spd;
  return Math.abs(sum-7.5)>1e-9;});
 ok('the 5 new companions\' atk+mag+def+res+spd growth each sum to exactly 7.5',
  budgetOff.length===0, budgetOff.join(','));
 var chargeIds=R.map(function(r){return r.chargeAction;});
 var uniqueCharges=chargeIds.filter(function(id,i){return chargeIds.indexOf(id)===i;});
 ok('every ROSTER chargeAction id is unique across the roster',
  uniqueCharges.length===chargeIds.length,
  chargeIds.filter(function(id,i){return chargeIds.indexOf(id)!==i;}).join(','));
 var badCharge=chargeIds.filter(function(id){var a=C.ACTIONS[id];return !a||!a.isCharge;});
 ok('every ROSTER chargeAction id resolves to a real charge action in C.ACTIONS',
  badCharge.length===0, badCharge.join(','));
 var reserved=P.MC_STARTER_CHARGES.concat(P.MC_CHARGE_DROP_POOL);
 var collision=chargeIds.filter(function(id){return reserved.indexOf(id)>=0;});
 ok('no ROSTER chargeAction collides with the MC\'s reserved starter/drop-pool charges',
  collision.length===0, collision.join(','));
})();

/* =================== 10. EXPEDITIONS (roadmap item 4, phase 1) ============
 * sendExpedition()/resolveExpedition() themselves live in the DOM-bound UI
 * layer (same reason buildParty/buildEnemies/simulateOfflineProgress aren't
 * unit-tested here either — see farroad-ui.js's own header comment) and are
 * exercised via the browser check instead. What IS headless and checked
 * here: the progression constants those functions are built on are sane,
 * and — since P.travelSec/P.killReward/P.isBossWave/P.bossAether/P.statsAt
 * are the exact primitives resolveExpedition() calls against its own
 * synthetic wave counter — that they behave sensibly fed a wave sequence
 * that keeps climbing well past where the curated road ends. */
(function(){
 ok('P.EXPED_RETURN_HP_FRAC is a sane fraction',
  P.EXPED_RETURN_HP_FRAC>0&&P.EXPED_RETURN_HP_FRAC<1, ''+P.EXPED_RETURN_HP_FRAC);
 ok('P.EXPED_CAP_SEC is positive and matches P.OFFLINE_CAP_SEC',
  P.EXPED_CAP_SEC>0&&P.EXPED_CAP_SEC===P.OFFLINE_CAP_SEC, ''+P.EXPED_CAP_SEC);
 var bad=[];
 for(var ew=1;ew<=200;ew++){
  var r=P.killReward(ew,1);
  if(!(r.aether>=0)||!(r.marks>=0))bad.push('killReward('+ew+')');
  if(P.isBossWave(ew)&&!(P.bossAether(ew)>0))bad.push('bossAether('+ew+')');
  if(!(P.travelSec(ew)>0))bad.push('travelSec('+ew+')');}
 ok('reward/pacing primitives stay non-negative and finite across a long synthetic climb',
  bad.length===0, bad.slice(0,5).join('; '));
 var st=P.statsAt('dorrek',C.ROSTER.filter(function(r){return r.id==='dorrek';})[0].stats,
  C.ROSTER.filter(function(r){return r.id==='dorrek';})[0].hp,5);
 ok('P.statsAt (used to build an expedition party from a benched unit\'s level) returns a full stat block',
  st&&st.hp>0&&st.atk>0&&st.spd>0);
})();

/* =================== 11. ENRAGE GATE IS BATTLE-WIDE (v2.9) =================
 * Was gated on each enemy's OWN turn count (grace of 8); now gated on the
 * battle's TOTAL turn count (b.beat, both sides combined, grace of 20) so a
 * fast enemy can no longer race to its own enrage threshold in real
 * fight-time regardless of how long the fight has actually run. Two
 * near-immortal units (huge HP/DEF, so the fight runs long enough to prove
 * the point) confirm: zero stacks while b.beat<=ENRAGE_AFTER, stacks
 * accumulate on the enemy's own subsequent turns once it's open. */
(function(){
 /* HP is set absurdly high (not just DEF) so this doesn't depend on the
    mitigation formula or on C.setWave()'s ambient CURRENT_WAVE — an earlier
    section in this same run may have left it elevated, which raises K_of()
    and weakens a DEF-only "near-invincible" unit enough to die in 1-2 beats
    (caught by this test itself failing exactly that way before the fix). */
 C.setWave(1);   /* known-good K_of() baseline — see the sweep bugfix note above */
 var rng=C.makeRNG(777);
 var tank=C.makeUnit({id:'p1',name:'Tank',isParty:true,level:1,slotIndex:0,row:'front',
  stats:{atk:1,mag:1,def:9999,res:9999,spd:100,evade:0,block:0},maxHp:1e9,hp:1e9,
  slots:[{cond:'none',action:'strike'}]});
 var foe=C.makeUnit({id:'e1',name:'Foe',isParty:false,level:1,slotIndex:10,
  stats:{atk:20,mag:1,def:9999,res:9999,spd:100,evade:0,block:0},maxHp:1e9,hp:1e9,
  slots:[{cond:'none',action:'strike'}]});
 var b=C.makeBattle([tank,foe],{rng:rng,enrage:true});
 var guard=0;
 while(b.beat<C.ENRAGE_AFTER&&guard++<1000)C.step(b);
 ok('enrage: no stacks anywhere before the battle-wide gate opens',
  C.enrageStacks(foe)===0, 'beat='+b.beat+' stacks='+C.enrageStacks(foe));
 var guard2=0;
 while(b.beat<C.ENRAGE_AFTER+10&&guard2++<1000)C.step(b);
 ok('enrage: stacks accumulate on the enemy\'s own turns once the gate is open',
  C.enrageStacks(foe)>0, 'beat='+b.beat+' stacks='+C.enrageStacks(foe));
})();

/* ------------------------------- report ---------------------------------- */
console.log('\nFARROAD SMOKE TEST');
console.log('  passed ' + passed + '   failed ' + failed);
if (batch) console.log('  headless throughput: ' + batch + ' fights in ' + ms + 'ms (' +
  (ms / Math.max(1, batch)).toFixed(2) + 'ms each)');
if (fails.length) { console.log('\nFAILURES:'); fails.forEach(f => console.log('  ✗ ' + f)); }
process.exit(failed ? 1 : 0);
