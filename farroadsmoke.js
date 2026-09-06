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
  enrage:true,idleAcc:3,dropQueue:[],dropHistory:[]};
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
  var expectedNext=rng.next(), actualNext=restored.rng.next();
  ok('save round-trip rebuilds the RNG to the exact saved position',
   expectedNext===actualNext, expectedNext+' vs '+actualNext);
 }
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
 keys.forEach(function(k){lo[k]=P.MC_POINT_MIN;hi[k]=P.MC_POINT_MAX;mid[k]=5;});
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
 ok('MC_POINTS_TOTAL matches 5 points per offered stat',
  P.MC_POINTS_TOTAL===P.MC_STAT_KEYS.length*5);
 var allChargesReal=P.MC_CHARGE_CHOICES.every(function(id){
  var a=C.ACTIONS[id];return !!a&&!!a.isCharge;});
 ok('every MC_CHARGE_CHOICES id resolves to a real charge action in C.ACTIONS',
  allChargesReal, P.MC_CHARGE_CHOICES.join(','));
 ok('MC_CHARGE_CHOICES has no overlap with the five companions\' own charge actions',
  P.MC_CHARGE_CHOICES.indexOf('oath')<0 && P.MC_CHARGE_CHOICES.indexOf('hearthlight')<0 &&
  P.MC_CHARGE_CHOICES.indexOf('vowofstone')<0 && P.MC_CHARGE_CHOICES.indexOf('ninefold')<0 &&
  P.MC_CHARGE_CHOICES.indexOf('ashfall')<0);
})();

/* ------------------------------- report ---------------------------------- */
console.log('\nFARROAD SMOKE TEST');
console.log('  passed ' + passed + '   failed ' + failed);
if (batch) console.log('  headless throughput: ' + batch + ' fights in ' + ms + 'ms (' +
  (ms / Math.max(1, batch)).toFixed(2) + 'ms each)');
if (fails.length) { console.log('\nFAILURES:'); fails.forEach(f => console.log('  ✗ ' + f)); }
process.exit(failed ? 1 : 0);
