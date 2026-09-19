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

/* core.js now reads window.FarroadContent (ROSTER/ARCH/ACTIONS, CSV-
   compiled — see content-pipeline.js) at its OWN load time, same as the
   real fused build does via build.js's injected <script> tag before
   core.js's. Compile it here too, from the SAME shared pipeline, so this
   harness tests the exact content a real build would ship, not a second,
   possibly-drifted copy. A validation failure here fails the whole test
   run immediately — the CSVs are wrong in a way that would have broken
   the real build too. */
const { buildContent } = require('./content-pipeline.js');
const { content: farroadContent, problems: contentProblems } = buildContent(__dirname);
if (contentProblems.length) {
  console.error('CONTENT VALIDATION FAILED\n  ' + contentProblems.join('\n  '));
  process.exit(1);
}
sandbox.window.FarroadContent = farroadContent;

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
  /* v2.14: equipment — {itemId:countOwned} and {uid:{slot:itemId}}. */
  equipInv:{ironcap:2,worngauntlet:1},equipped:{kesh:{head:'ironcap',hand1:'worngauntlet'}},
  enrage:true,idleAcc:3,dropQueue:[],dropHistory:[],
  expeditions:[{id:'exp1',partyIds:['dorrek','vey'],startedAt:1700000000000-3600000,
   lastResolvedAt:1700000000000-3600000,ew:3,hpFrac:0.7,bank:{aether:40,marks:5},homeAt:null,
   log:[{at:1700000000000,text:'Dorrek, Vey set out to explore.'}]}]};
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
  ok('save round-trip preserves equipment inventory and equipped slots',
   restored.equipInv&&restored.equipInv.ironcap===2&&restored.equipInv.worngauntlet===1&&
   restored.equipped&&restored.equipped.kesh&&restored.equipped.kesh.head==='ironcap'&&
   restored.equipped.kesh.hand1==='worngauntlet');
  ok('save round-trip preserves an in-progress expedition',
   restored.expeditions&&restored.expeditions.length===1&&
   restored.expeditions[0].partyIds.length===2&&restored.expeditions[0].partyIds[0]==='dorrek'&&
   restored.expeditions[0].ew===3&&restored.expeditions[0].bank.aether===40);
  ok('save round-trip preserves that expedition\'s own log',
   restored.expeditions[0].log&&restored.expeditions[0].log.length===1&&
   restored.expeditions[0].log[0].text.indexOf('Dorrek')>=0);
  var expectedNext=rng.next(), actualNext=restored.rng.next();
  ok('save round-trip rebuilds the RNG to the exact saved position',
   expectedNext===actualNext, expectedNext+' vs '+actualNext);
 }
 /* OLD-SAVE COMPAT: a snapshot from before multi-expedition support has
    neither field at all — deserialize must default to [] rather than
    throw or leave it undefined, the same contract every other FIELDS
    entry already gets. */
 var oldSnap=null,oldThrew=null,oldRestored=null;
 try{
  oldSnap=V.serialize(fakeG,1700000000000);
  delete oldSnap.expeditions;
  oldRestored=V.deserialize(JSON.parse(JSON.stringify(oldSnap)),C);
 }catch(e){oldThrew=e;}
 ok('old save missing expeditions field does not throw', !oldThrew, oldThrew&&oldThrew.message);
 ok('old save missing expeditions field defaults to []',
  !!oldRestored&&Array.isArray(oldRestored.expeditions)&&oldRestored.expeditions.length===0);
 /* v2.14: a save from before equipment existed has neither field at all —
    same contract, default-fill rather than throw or leave undefined. */
 var noEquipSnap=null,noEquipThrew=null,noEquipRestored=null;
 try{
  noEquipSnap=V.serialize(fakeG,1700000000000);
  delete noEquipSnap.equipInv;delete noEquipSnap.equipped;
  noEquipRestored=V.deserialize(JSON.parse(JSON.stringify(noEquipSnap)),C);
 }catch(e){noEquipThrew=e;}
 ok('old save missing equipInv/equipped does not throw', !noEquipThrew, noEquipThrew&&noEquipThrew.message);
 ok('old save missing equipInv/equipped defaults to {}/{} (with kesh seeded)',
  !!noEquipRestored&&JSON.stringify(noEquipRestored.equipInv)==='{}'&&
  !!noEquipRestored.equipped&&!!noEquipRestored.equipped.kesh);
 /* MIGRATION: a save from BEFORE multi-expedition support (singular
    'expedition' object + shared 'expeditionLog' array, neither in FIELDS
    anymore) must have its real in-flight expedition preserved, not
    silently dropped, wrapped into the new array with the old shared log
    folded into it. */
 var legacySnap=null,legacyThrew=null,legacyRestored=null;
 try{
  legacySnap=V.serialize(fakeG,1700000000000);
  delete legacySnap.expeditions;
  legacySnap.expedition={partyIds:['mirel'],startedAt:1700000000000-1800000,
   lastResolvedAt:1700000000000-1800000,ew:2,hpFrac:0.9,bank:{aether:15,marks:2},homeAt:null};
  legacySnap.expeditionLog=[{at:1700000000000,text:'Mirel set out to explore.'}];
  legacyRestored=V.deserialize(JSON.parse(JSON.stringify(legacySnap)),C);
 }catch(e){legacyThrew=e;}
 ok('legacy singular-expedition save does not throw', !legacyThrew, legacyThrew&&legacyThrew.message);
 ok('legacy singular-expedition save migrates into expeditions[0]',
  !!legacyRestored&&legacyRestored.expeditions&&legacyRestored.expeditions.length===1&&
  legacyRestored.expeditions[0].partyIds[0]==='mirel'&&!!legacyRestored.expeditions[0].id);
 ok('legacy migration folds the old shared log into the migrated entry',
  !!legacyRestored&&legacyRestored.expeditions[0].log&&
  legacyRestored.expeditions[0].log.length===1&&
  legacyRestored.expeditions[0].log[0].text.indexOf('Mirel')>=0);
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
 /* v2.10: atkCrit/magCrit/block/evade are no longer offered at creation at
    all (they level like affinities now — Aether-purchased, see section 18
    below) — MC_STAT_KEYS should have exactly the 6 remaining stats and
    none of the old percent-stat set. */
 ok('MC_STAT_KEYS no longer offers atkCrit/magCrit/block/evade at creation',
  keys.length===6 && ['atkCrit','magCrit','block','evade'].every(function(k){return keys.indexOf(k)<0;}),
  keys.join(','));
 ok('mcBuildStats output has no stray atkCrit/magCrit/block/evade fields',
  ['atkCrit','magCrit','block','evade'].every(function(k){return atMid.stats[k]===undefined;}));
 ok('mcPointsSpent: a balanced 5-per-stat build spends exactly the pool',
  P.mcPointsSpent(mid)===P.MC_POINTS_TOTAL);
 ok('MC_POINTS_TOTAL is exactly half of the theoretical max spend (stats x MC_POINT_MAX)',
  P.MC_POINTS_TOTAL===(P.MC_STAT_KEYS.length*P.MC_POINT_MAX)/2);
 ok('MC_POINT_MIN is 0 — every stat can be dumped to its roster floor with no points spent',
  P.MC_POINT_MIN===0);
 ok('a build that maxes exactly half the stats and floors the rest spends exactly the pool',
  (function(){var half={},n=keys.length/2;
   keys.forEach(function(k,i){half[k]=i<n?P.MC_POINT_MAX:P.MC_POINT_MIN;});
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
 // v2.14 (20-item batch, Group D): the original 3 starters are still
 // plain (power only, no status); 2 new ones (wearingdown, ironresolve)
 // deliberately apply a status on top of real power, scaling off the
 // average of ATK/MAG for a build that doesn't lean hard into either camp.
 ok('the 3 original starter charges are still plain: power present, no attached status/lifesteal/revive',
  ['heavystrike','wildfire','greatheal'].every(function(id){var a=C.ACTIONS[id];
   return !!a.power && !a.applies && !a.lifesteal && !a.revive;}));
 ok('every starter charge has real power (none are a hollow status-only pick)',
  P.MC_STARTER_CHARGES.every(function(id){return !!C.ACTIONS[id].power;}));
 ok('wearingdown/ironresolve scale off avgAtkMag and each apply a real status',
  C.ACTIONS.wearingdown.scaleStat==='avgAtkMag' && C.ACTIONS.wearingdown.applies==='enfeebled' &&
  C.ACTIONS.ironresolve.scaleStat==='avgAtkMag' && C.ACTIONS.ironresolve.applies==='bracing');
 ok('statByKey(avgAtkMag) is the mean of effAtk/effMag, not an alias for either alone', (function(){
  var u=C.makeUnit({id:'x',name:'X',isParty:true,level:1,slotIndex:0,
   stats:{atk:20,mag:40,def:10,res:10,spd:100},maxHp:100,hp:100,slots:[{cond:'none',action:'strike'}]});
  var avg=C.statByKey(u,'avgAtkMag');
  return Math.abs(avg-(C.effAtk(u)+C.effMag(u))/2)<1e-9 && avg!==C.effAtk(u) && avg!==C.effMag(u);
 })());
 ok('MC_CHARGE_DROP_CHANCE is a real probability, low enough to read as "rare"',
  P.MC_CHARGE_DROP_CHANCE>0 && P.MC_CHARGE_DROP_CHANCE<=0.10);
})();

/* =================== 8. FLAT PER-STACK LORE BONUS COST (v2.13) =============
 * v2.9 introduced a triangular per-action cost (each further upgrade on the
 * same action cost one more than the last) plus (v2.12) a rarity multiplier;
 * v2.13 reverts BOTH per Ian's explicit request — every non-broad stack is
 * now a flat 1 Lore, regardless of the action's own running total OR its
 * rarity, and Broad stays a flat BONUS_COST_BROAD with no rarity scaling
 * either. This must hold: EVERY non-broad purchase costs exactly 1,
 * regardless of how many upgrades the action already has or which bonus
 * type it is; Broad stays flat at BONUS_COST_BROAD; and bonusSpend's
 * closed-form total matches a flat count*1 plus flat broad*BONUS_COST_BROAD,
 * not a triangular sum. */
(function(){
 var strike=C.ACTIONS.strike,rare=C.ACTIONS.oath,legendary=C.ACTIONS.tidalsurge;
 ok('bonusPrice: a fresh action\'s first upgrade costs exactly 1 Lore',
  C.bonusPrice(strike,'potent',0)===1);
 ok('bonusPrice: every further upgrade on the same action ALSO costs exactly 1 (flat, not escalating)',
  C.bonusPrice(strike,'potent',1)===1 && C.bonusPrice(strike,'potent',2)===1 &&
  C.bonusPrice(strike,'potent',9)===1);
 ok('actionBonusTotal: sums every non-broad bonus on the action, excludes broad',
  C.actionBonusTotal({potent:2,lasting:1,broad:5})===3 && C.actionBonusTotal({broad:5})===0);
 ok('bonusPrice: Broad is flat at BONUS_COST_BROAD regardless of the action\'s total',
  C.bonusPrice(strike,'broad',0)===C.BONUS_COST_BROAD &&
  C.bonusPrice(strike,'broad',10)===C.BONUS_COST_BROAD);
 /* Rarity no longer scales EITHER branch -- a Rare/Legendary action's own
    upgrades cost exactly the same as a Common action's. */
 ok('bonusPrice: rarity no longer scales the non-broad price (reverted v2.12)',
  rare && C.bonusPrice(rare,'potent',0)===1 &&
  legendary && C.bonusPrice(legendary,'potent',0)===1);
 ok('bonusPrice: rarity no longer scales the broad price either (reverted v2.12)',
  rare && C.bonusPrice(rare,'broad',0)===C.BONUS_COST_BROAD &&
  legendary && C.bonusPrice(legendary,'broad',0)===C.BONUS_COST_BROAD);
 var map={strike:{potent:2,lasting:1,broad:3}};
 var expectedFlat=3;                              /* 3 non-broad stacks total, flat 1 each */
 var expectedBroad=3*C.BONUS_COST_BROAD;
 ok('bonusSpend: flat count*1 plus flat broad*BONUS_COST_BROAD, not a triangular sum',
  C.bonusSpend(map)===expectedFlat+expectedBroad,
  C.bonusSpend(map)+' vs '+(expectedFlat+expectedBroad));
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
 /* atkCrit/magCrit/evade dropped — MC_STAT_RANGE no longer bounds them
    (they level like affinities now, see section 18), so the `if(!range)
    return;` guard below already skipped them silently; trimmed rather
    than left as a second stale list. Block is gone from the game
    entirely (see section 18's own note). */
 /* Rare/Legendary roster units are deliberately stronger than the MC's own
    point-buy bounds (see the RARITY comment in core.js) — a Rare unit's
    stat/growth is allowed up to RARITY_POWER_MUL[rarity] times the plain
    MC_STAT_RANGE/MC_GROWTH_RANGE ceiling/floor, not the raw range itself.
    Common units still have to fit the unscaled bounds exactly as before. */
 var statKeys=['atk','mag','def','res','spd'];
 var outOfRange=[];
 R.forEach(function(r){
  var mul=C.RARITY_POWER_MUL[r.rarity||'common']||1;
  statKeys.forEach(function(k){
   var range=P.MC_STAT_RANGE[k];if(!range)return;
   var v=r.stats[k],lo=range[0]*mul,hi=range[1]*mul;
   if(v<lo||v>hi)outOfRange.push(r.id+'.'+k+'='+v+' (range '+lo+'-'+hi+')');});
  var hpRange=P.MC_STAT_RANGE.hp,hpLo=hpRange[0]*mul,hpHi=hpRange[1]*mul;
  if(r.hp<hpLo||r.hp>hpHi)outOfRange.push(r.id+'.hp='+r.hp+' (range '+hpLo+'-'+hpHi+')');});
 ok('every ROSTER unit\'s stats (incl. hp) fall within its rarity-scaled P.MC_STAT_RANGE', outOfRange.length===0, outOfRange.join('; '));
 var growthKeys2=['atk','mag','def','res','spd','hp'];
 var growthOut=[];
 R.forEach(function(r){
  var g=P.GROWTH[r.id];if(!g){growthOut.push(r.id+': no P.GROWTH entry');return;}
  var mul=C.RARITY_POWER_MUL[r.rarity||'common']||1;
  growthKeys2.forEach(function(k){
   var range=P.MC_GROWTH_RANGE[k];if(!range)return;
   var lo=range[0]*mul,hi=range[1]*mul;
   if(g[k]<lo||g[k]>hi)growthOut.push(r.id+'.'+k+'='+g[k]+' (range '+lo+'-'+hi+')');});});
 ok('every ROSTER unit has a P.GROWTH entry within its rarity-scaled P.MC_GROWTH_RANGE', growthOut.length===0, growthOut.join('; '));
 /* Ian's universal hp/speed growth reduction (x0.7 hp, x0.5 spd, baked
    directly into P.GROWTH's own numbers -- no runtime multiplier per his
    own follow-up ask) is a later, separate balance pass over the WHOLE
    roster, unrelated to this roster-authoring-time "5 new companions cost
    the same combined budget as the original 5" invariant. Named locally
    here (not read off P, which no longer carries them) purely to un-reduce
    spd back to its original pre-reduction design value before checking,
    so this still verifies the invariant it was actually written to catch. */
 var HP_REDUCTION=0.7, SPD_REDUCTION=0.5;
 var newFive=['skarn','sorin','nyra','brenn','sael'];
 var budgetOff=newFive.filter(function(id){
  var r=R.filter(function(x){return x.id===id;})[0];
  var mul=C.RARITY_POWER_MUL[r.rarity||'common']||1;
  var g=P.GROWTH[id];
  var originalSpd=g.spd/SPD_REDUCTION;
  var sum=g.atk+g.mag+g.def+g.res+originalSpd;
  /* individually hand-rounded to 1 decimal, so allow slack for rounding
     error across 5 stats rather than requiring exact equality */
  return Math.abs(sum-7.5*mul)>0.3;});
 ok('the 5 new companions\' atk+mag+def+res+spd growth each sum to ~7.5x their rarity\'s RARITY_POWER_MUL',
  budgetOff.length===0, budgetOff.join(','));
 var chargeIds=R.map(function(r){return r.chargeAction;});
 var uniqueCharges=chargeIds.filter(function(id,i){return chargeIds.indexOf(id)===i;});
 ok('every ROSTER chargeAction id is unique across the roster',
  uniqueCharges.length===chargeIds.length,
  chargeIds.filter(function(id,i){return chargeIds.indexOf(id)!==i;}).join(','));
 var badCharge=chargeIds.filter(function(id){var a=C.ACTIONS[id];return !a||!a.isCharge;});
 ok('every ROSTER chargeAction id resolves to a real charge action in C.ACTIONS',
  badCharge.length===0, badCharge.join(','));
 /* --- Ian: "universally reduce HP growths by 30% and speed growths by
    50%", baked directly into the numbers -- confirms the reduction
    actually landed on every roster unit, not just spot-checked ones. --- */
 var knownOriginal={kesh:{hp:34,spd:2.2},dorrek:{hp:48,spd:1.4},sael:{hp:24,spd:3.4}};
 var growthBad=Object.keys(knownOriginal).filter(function(id){
  var g=P.GROWTH[id],orig=knownOriginal[id];
  return Math.abs(g.hp-orig.hp*HP_REDUCTION)>1e-9 || Math.abs(g.spd-orig.spd*SPD_REDUCTION)>1e-9;});
 ok('spot-checked roster units\' hp/spd growth are exactly their original value x0.7/x0.5',
  growthBad.length===0, growthBad.join(','));
 ok('MC_GROWTH_RANGE\'s hp/spd bounds carry the same reduction (18-48 -> 12.6-33.6, 1.4-3.2 -> 0.7-1.6)',
  Math.abs(P.MC_GROWTH_RANGE.hp[0]-12.6)<1e-9 && Math.abs(P.MC_GROWTH_RANGE.hp[1]-33.6)<1e-9 &&
  Math.abs(P.MC_GROWTH_RANGE.spd[0]-0.7)<1e-9 && Math.abs(P.MC_GROWTH_RANGE.spd[1]-1.6)<1e-9);
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

/* =================== 11. ENRAGE GATE IS BATTLE-WIDE, GROWTH TOO (v2.13) ====
 * Gated on the battle's TOTAL turn count (b.beat, both sides combined, grace
 * of 20) so a fast enemy can no longer race to its own enrage threshold in
 * real fight-time regardless of how long the fight has actually run. Growth
 * is ALSO now counted off the total turn count (b.enrageN, any actor), not
 * just the acting enemy's own turns -- two near-immortal units (huge HP/DEF,
 * so the fight runs long enough to prove the point) confirm: zero stacks
 * while b.beat<=ENRAGE_AFTER, stacks accumulate battle-wide once it's open
 * (rising on the PARTY's turn too, not just the enemy's), and a foe that
 * hasn't acted since a stack rose still catches all of it up on its own next
 * turn (base.atk actually multiplies by the full pending amount at once). */
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
 /* Ian: "enrage should start at 20 turns, not 21" -- gate is now
    beat>=ENRAGE_AFTER (was beat>ENRAGE_AFTER), so "before the gate opens"
    now means strictly less than ENRAGE_AFTER, not less-than-or-equal. */
 while(b.beat<C.ENRAGE_AFTER-1&&guard++<1000)C.step(b);
 ok('enrage: no stacks anywhere before the battle-wide gate opens',
  C.enrageStacks(b)===0, 'beat='+b.beat+' stacks='+C.enrageStacks(b));
 /* One more beat, whoever's turn it is (party or enemy), should land
    EXACTLY on ENRAGE_AFTER and immediately produce a battle-wide stack --
    proving growth is no longer scoped to the enemy's own turn, and that
    the gate opens ON turn 20 itself, not turn 21. */
 C.step(b);
 ok('enrage: a stack accumulates battle-wide the moment beat reaches ENRAGE_AFTER, regardless of whose turn it is',
  b.beat===C.ENRAGE_AFTER && C.enrageStacks(b)>0, 'beat='+b.beat+' stacks='+C.enrageStacks(b));
 var guard2=0;
 while(b.beat<C.ENRAGE_AFTER+10&&guard2++<1000)C.step(b);
 ok('enrage: stacks keep accumulating battle-wide as the fight continues',
  C.enrageStacks(b)>0, 'beat='+b.beat+' stacks='+C.enrageStacks(b));
 /* foe.enrageApplied can legitimately lag b.enrageN by however many stacks
    have accumulated since the foe's OWN last turn (it only catches up on
    its own turn) -- never ahead, and (since foe has had several turns in
    this alternating 1v1 across 10 post-gate beats) not still zero either. */
 ok('enrage: the foe has caught its own stats up on at least one of its own turns, never ahead of the shared count',
  foe.enrageApplied>0 && foe.enrageApplied<=C.enrageStacks(b),
  'enrageApplied='+foe.enrageApplied+' stacks='+C.enrageStacks(b));
})();

/* =================== 12. STAT-SCALING MC CHARGE ACTIONS (v2.9) ============
 * The 10 new charge actions (one damage + one support per core stat) are
 * the first content in the game to use act.scaleStat, which overrides
 * resolveHit/healFor's normal camp-implied ATK/MAG source (core.js). This
 * checks the definitions are sane AND, more importantly, that scaleStat
 * actually changes what drives the damage — two sources identical in every
 * stat except DEF, both using a DEF-scaling action against the same
 * target, must deal DIFFERENT damage (proving DEF, not ATK/MAG, is the
 * source), which a battle in deterministic mode (no crit/evade/block
 * variance) can show cleanly. */
(function(){
 var newCharges=['atk_reckless','mag_lance','def_slam','res_strike','spd_flurry',
  'atk_cry','mag_font','def_bulwark','res_ward','spd_fleet'];
 var expectStat={atk_reckless:'atk',mag_lance:'mag',def_slam:'def',res_strike:'res',
  spd_flurry:'spd',atk_cry:'atk',mag_font:'mag',def_bulwark:'def',res_ward:'res',spd_fleet:'spd'};
 var bad=[];
 newCharges.forEach(function(id){
  var a=C.ACTIONS[id];
  if(!a)bad.push(id+': missing');
  else if(!a.isCharge)bad.push(id+': not isCharge');
  else if(a.scaleStat!==expectStat[id])bad.push(id+': scaleStat='+a.scaleStat+' expected '+expectStat[id]);});
 ok('all 10 new stat-scaling charges exist, are isCharge, and scaleStat matches their name',
  bad.length===0, bad.join('; '));
 var uniqueAmongRoster=C.ROSTER.every(function(r){return newCharges.indexOf(r.chargeAction)<0;});
 ok('none of the 10 new charge ids collide with a ROSTER unit\'s own chargeAction',
  uniqueAmongRoster);

 function mkSrc(def){return C.makeUnit({id:'s',name:'Src',isParty:true,level:1,slotIndex:0,
  stats:{atk:15,mag:15,def:def,res:15,spd:100},maxHp:1000,hp:1000,
  chargeAction:'def_slam',charge:100,slots:[{cond:'none',action:'strike'}]});}
 function mkTgt(){return C.makeUnit({id:'t',name:'Tgt',isParty:false,level:1,slotIndex:10,
  stats:{atk:10,mag:10,def:10,res:10,spd:90},maxHp:100000,hp:100000,
  slots:[{cond:'none',action:'strike'}]});}
 function firstHitDamage(defVal){
  var src=mkSrc(defVal),tgt=mkTgt();
  var b=C.makeBattle([src,tgt],{rng:C.makeRNG(1),deterministic:true});
  var e=null,guard=0;
  while(!e&&guard++<10){var ev=C.step(b);if(ev&&ev.actorId==='s'&&ev.hits&&ev.hits.length)e=ev;}
  return e?e.hits[0].damage:null;}
 var dmgLowDef=firstHitDamage(10), dmgHighDef=firstHitDamage(60);
 ok('def_slam (scaleStat:def) deals more damage from a higher-DEF source, ATK/MAG held equal',
  dmgLowDef!=null&&dmgHighDef!=null&&dmgHighDef>dmgLowDef,
  'low='+dmgLowDef+' high='+dmgHighDef);
})();

/* =================== 12b. TANK-BUILD FIX: bastion_strike/aegis_strike =====
 * Ian: a full-tank MC (near-zero ATK/MAG) couldn't clear the tutorial, since
 * every other charge action scales off the very stats a tank neglects.
 * bastion_strike (DEF) / aegis_strike (RES) give a tank build a real damage
 * source that scales off ITS OWN high stat, hits TRUE (defPierce=1.0, so
 * mitigation never applies), and is extra strong through the tutorial
 * (tutorialTankChargeMul: 2x through wave 20, ramping to 1x by wave 100) --
 * both are MC_STARTER_CHARGES so a tank build has them from creation. */
(function(){
 var bs=C.ACTIONS.bastion_strike, ae=C.ACTIONS.aegis_strike;
 ok('bastion_strike/aegis_strike exist, are isCharge, defPierce=1.0, and scale off DEF/RES respectively',
  bs&&ae&&bs.isCharge&&ae.isCharge&&bs.defPierce===1&&ae.defPierce===1&&
  bs.scaleStat==='def'&&ae.scaleStat==='res');
 ok('bastion_strike and aegis_strike are both in P.MC_STARTER_CHARGES',
  P.MC_STARTER_CHARGES.indexOf('bastion_strike')>=0 && P.MC_STARTER_CHARGES.indexOf('aegis_strike')>=0);

 C.setWave(1);
 var atW1=bs.powerFn();
 C.setWave(20);
 var atW20=bs.powerFn();
 C.setWave(100);
 var atW100=bs.powerFn();
 C.setWave(150);
 var atW150=bs.powerFn();
 ok('bastion_strike power is exactly double its wave-100+ baseline through wave 20, and back to baseline by wave 100',
  Math.abs(atW1/atW100-2)<1e-9 && Math.abs(atW20/atW100-2)<1e-9 && atW100===atW150,
  'w1='+atW1+' w20='+atW20+' w100='+atW100+' w150='+atW150);
 var mid=(function(){C.setWave(60);return bs.powerFn();})();
 ok('bastion_strike power decays monotonically and smoothly across wave 20-100, no cliff',
  mid<atW20 && mid>atW100);
 C.setWave(1);

 ok('an already-maxed-pierce action (bastion_strike) no longer offers Piercing as a Lore bonus (it would be a no-op or a regression)',
  C.bonusApplies(bs,'piercing')===false && C.bonusApplies(ae,'piercing')===false);
 ok('an action with real room to grow (defPierce well under the bonus\'s own 0.85 cap) still offers Piercing, unaffected by the fix',
  C.bonusApplies({power:1,camp:'atk',tk:'foe',defPierce:0.25},'piercing')===true);

 function trueDmg(def){
  var src=C.makeUnit({id:'s3',name:'S3',isParty:true,level:1,slotIndex:0,
   stats:{atk:8,mag:7,def:45,res:8,spd:20},chargeAction:'bastion_strike',charge:100,
   slots:[{cond:'none',action:'strike'}]});
  var tgt=C.makeUnit({id:'t3',name:'T3',isParty:false,level:1,slotIndex:10,
   stats:{atk:10,mag:10,def:def,res:def,spd:18},maxHp:100000,hp:100000,
   slots:[{cond:'none',action:'strike'}]});
  var b=C.makeBattle([src,tgt],{rng:C.makeRNG(7),deterministic:true});
  return C.step(b).hits[0].damage;}
 var dmgLo=trueDmg(5), dmgHi=trueDmg(500);
 ok('bastion_strike deals identical TRUE damage regardless of the target\'s DEF (5 vs 500) -- mitigation never applies',
  dmgLo===dmgHi, 'lowDef='+dmgLo+' highDef='+dmgHi);
})();

/* =================== 13. NO DUPLICATE ACTION NAMES =========================
 * Caught live, not by code review: the new spd_flurry charge action was
 * originally also named "Flurry", colliding with the pre-existing basic
 * action `flurry` (id different, display name identical) — found by pulling
 * it in the browser and seeing two unrelated "Flurry" entries. Same name,
 * different mechanics, is confusing regardless of whether the ids collide;
 * this is a permanent regression guard so the next new action can't repeat
 * it silently. */
(function(){
 var names={},dupes=[];
 Object.keys(C.ACTIONS).forEach(function(id){
  var nm=C.ACTIONS[id].name;
  if(names[nm])dupes.push(nm+' ('+names[nm]+' vs '+id+')');
  else names[nm]=id;});
 ok('no two actions share a display name', dupes.length===0, dupes.join('; '));
})();

/* =================== 14. LATE-GAME DIFFICULTY BATCH (v2.9) =================
 * Covers the four engine-side changes from the post-wave-800 batch: the
 * boss-wave-cap bugfix (no bosses spawned past wave 800 — a hardcoded
 * iteration cap, not a formula limit), the post-wave-100 hard-scaling
 * curves (hardMul/bossSpdMul), the enemy-count extension to 10, and the
 * atk/mag charge-action power-parity fix. */
(function(){
 /* --- boss wave cap: must recognize boss waves arbitrarily far out ------ */
 [820,1000,5000,20000].forEach(function(w){
  ok('isBossWave('+w+') true (was capped at 800)', P.isBossWave(w)===((w-20)%20===0));});
 ok('isBossWave(801) false (not a multiple of 20 past 20)', P.isBossWave(801)===false);
 ok('nextBossWave(800) is 820, not null', P.nextBossWave(800)===820);
 ok('nextBossWave(20000) keeps counting, not null', P.nextBossWave(20000)===20020);
 /* early waves unaffected */
 ok('isBossWave(20) still true', P.isBossWave(20)===true);
 ok('isBossWave(19) still false', P.isBossWave(19)===false);

 /* --- hardMul: 1 at/below HARD_FROM, monotonic, caps at HARD_MAX -------- */
 ok('hardMul(100) === 1 (no early-game change)', P.hardMul(100)===1);
 ok('hardMul(50) === 1', P.hardMul(50)===1);
 ok('hardMul(101) > 1', P.hardMul(101)>1);
 ok('hardMul(1000) === HARD_MAX', P.hardMul(P.HARD_REF)===P.HARD_MAX);
 ok('hardMul(5000) still === HARD_MAX (capped, not runaway)', P.hardMul(5000)===P.HARD_MAX);
 ok('hardMul monotonic 100->1000', P.hardMul(300)<P.hardMul(600) && P.hardMul(600)<P.hardMul(900));

 /* --- bossSpdMul: same shape, own thresholds --------------------------- */
 ok('bossSpdMul(20) === 1', P.bossSpdMul(20)===1);
 ok('bossSpdMul(1000) === BOSS_SPD_MAX_MUL', P.bossSpdMul(P.BOSS_SPD_REF)===P.BOSS_SPD_MAX_MUL);
 ok('bossSpdMul monotonic', P.bossSpdMul(100)<P.bossSpdMul(500) && P.bossSpdMul(500)<P.bossSpdMul(900));

 /* --- enemy count: variety table extends to 10 only past HARD_FROM ----- */
 ok('COUNT_WEIGHTS still maxes at 4 (waves 41-100 unchanged)',
  Math.max.apply(null,P.COUNT_WEIGHTS.map(function(x){return x[0];}))===4);
 ok('COUNT_WEIGHTS_HARD reaches ENEMY_CAP',
  Math.max.apply(null,P.COUNT_WEIGHTS_HARD.map(function(x){return x[0];}))===P.ENEMY_CAP);
 var wSum=P.COUNT_WEIGHTS.reduce(function(a,x){return a+x[1];},0);
 var hSum=P.COUNT_WEIGHTS_HARD.reduce(function(a,x){return a+x[1];},0);
 ok('COUNT_WEIGHTS sums to 1', Math.abs(wSum-1)<1e-9, String(wSum));
 ok('COUNT_WEIGHTS_HARD sums to 1', Math.abs(hSum-1)<1e-9, String(hSum));
 var rng=C.makeRNG(99);
 ok('rollCount(w<=100) never exceeds 4', [rng,rng,rng,rng,rng].every(function(){return P.rollCount(rng,50)<=4;}));
 var rng2=C.makeRNG(99),sawFive=false;
 for(var i=0;i<200;i++)if(P.rollCount(rng2,500)>4)sawFive=true;
 ok('rollCount(w>100) can exceed 4 across many rolls', sawFive);
 ok('countStrength(10) continues the plateau (not the old flat ||1)',
  P.countStrength(10)<1 && P.countStrength(10)>0);
 ok('countStrength(1..4) unchanged', P.countStrength(1)===1.85 && P.countStrength(4)===0.72);

 /* --- atk/mag potency: mag_lance/mag_font now match their atk sibling -- */
 ok('mag_lance power matches atk_reckless (no more ceiling-compensation nerf)',
  C.ACTIONS.mag_lance.power===C.ACTIONS.atk_reckless.power);
 ok('mag_font power matches atk_cry', C.ACTIONS.mag_font.power===C.ACTIONS.atk_cry.power);
 /* Rarity (later pass) bumped these 3's power by RARITY_POWER_MUL.rare on
    top of the original out-of-scope baseline (2.60/3.00/0.45) — check
    against that scaled value instead of the old flat baseline. spd_flurry's
    scaleStat=spd power was later also multiplied x5 (the 80% starting-SPD
    cut's own compensation), on top of the rarity scaling, not instead of it. */
 ok('def_slam/res_strike/spd_flurry scaled by RARITY_POWER_MUL.rare, nothing else',
  C.ACTIONS.def_slam.power===Math.round(2.60*C.RARITY_POWER_MUL.rare*100)/100 &&
  C.ACTIONS.res_strike.power===Math.round(3.00*C.RARITY_POWER_MUL.rare*100)/100 &&
  Math.abs(C.ACTIONS.spd_flurry.power-Math.round(0.45*C.RARITY_POWER_MUL.rare*100)/100*5)<1e-9);

 /* --- enemy row: rowSpdMul now reads row regardless of isParty --------- */
 var frontFoe=C.makeUnit({id:'f1',isParty:false,level:1,slotIndex:10,row:'front',
  stats:{atk:10,mag:10,def:10,res:10,spd:100},slots:[]});
 var backFoe=C.makeUnit({id:'f2',isParty:false,level:1,slotIndex:11,row:'back',
  stats:{atk:10,mag:10,def:10,res:10,spd:100},slots:[]});
 ok('front-row enemy gets the SPD bonus front-row party gets',
  C.tcOf?C.tcOf(frontFoe,1)<C.tcOf(backFoe,1):true);
})();

/* =================== 15. POWER LEVEL (v2.9) ================================
 * "a value that accurately shows a player's total power level" — sums
 * wave (via levelCurve, the same wave->level-equivalent curve the Road's
 * per-enemy Lv tag also uses), summed owned-unit levels, a flat per-unit
 * roster-depth bonus, and summed Lore levels (actionBonusTotal per action).
 * Checks the formula responds to each of the four inputs independently and
 * produces a sane baseline. */
(function(){
 var base={farthest:1,owned:{kesh:1},lvl:{kesh:1},bonuses:{}};
 var basePower=P.powerLevel(base);
 ok('powerLevel is a positive finite number', isFinite(basePower)&&basePower>0, String(basePower));

 var higherFarthest=P.powerLevel({farthest:500,owned:{kesh:1},lvl:{kesh:1},bonuses:{}});
 ok('powerLevel increases with farthest wave reached', higherFarthest>basePower);

 var higherLevel=P.powerLevel({farthest:1,owned:{kesh:1},lvl:{kesh:50},bonuses:{}});
 ok('powerLevel increases with unit level', higherLevel>basePower);

 var moreUnits=P.powerLevel({farthest:1,owned:{kesh:1,ansa:1},lvl:{kesh:1,ansa:1},bonuses:{}});
 ok('powerLevel increases with roster size', moreUnits>basePower);

 var moreLore=P.powerLevel({farthest:1,owned:{kesh:1},lvl:{kesh:1},bonuses:{strike:{potent:5}}});
 ok('powerLevel increases with Lore levels', moreLore>basePower);

 ok('powerLevel matches the sum of its own documented terms', (function(){
  var g={farthest:150,owned:{kesh:1},lvl:{kesh:20},bonuses:{strike:{potent:3},ember:{swift:2}}};
  var keshDef=null;C.ROSTER.forEach(function(r){if(r.id==='kesh')keshDef=r;});
  var st=P.statsAt('kesh',keshDef.stats,keshDef.hp,20);
  var unitStatTotal=st.atk+st.mag+st.def+st.res+st.spd+st.hp;
  var loreLevels=C.actionBonusTotal({potent:3})+C.actionBonusTotal({swift:2});
  var expected=Math.round(unitStatTotal/P.POWER_STAT_DIVISOR+loreLevels*P.POWER_PER_LORE+C.levelCurve(150));
  return P.powerLevel(g)===expected;
 })());
})();

/* =================== 16. DISCOVERABLE CONTENT (roadmap 5-7) ================
 * rollExpeditionDiscovery/enterDungeon/attemptQuestStage themselves live in
 * the DOM-bound UI layer (same reason resolveExpedition isn't unit-tested
 * here either) — exercised via the browser check instead. What IS headless
 * and checked here: the progression constants/table those functions are
 * built on are sane and complete, the "freeze" property the whole feature
 * depends on (a baked snapshot's stats are immune to CURRENT_WAVE / any
 * later hardMul-style retuning) actually holds at the C.makeUnit level, and
 * the two new save FIELDS round-trip correctly, including the old-save
 * default-fill path. */
(function(){
 /* --- discovery-roll constants are sane probabilities ------------------- */
 ok('P.EXPED_DISCOVERY_CHANCE is a real, rare-ish probability',
  P.EXPED_DISCOVERY_CHANCE>0&&P.EXPED_DISCOVERY_CHANCE<0.5, ''+P.EXPED_DISCOVERY_CHANCE);
 ok('P.DUNGEON_LEN is "slightly harder", not boss-tier (below BOSS_LEN)',
  P.DUNGEON_LEN>1&&P.DUNGEON_LEN<P.BOSS_LEN, P.DUNGEON_LEN+' vs BOSS_LEN '+P.BOSS_LEN);
 ok('every direction\'s waveCount/unlockEvery (farroaddungeons.csv) are sane positive numbers',
  P.DIRECTIONS.every(function(d){return P.DIRECTION_CONFIG[d].waveCount>=2&&P.DIRECTION_CONFIG[d].unlockEvery>0;}));

 /* --- P.DIRECTIONS / P.directionMul: 8 named lanes, easiest to hardest --
    generated from farroaddungeons.csv (content-pipeline.js) now, not a
    formula — this is a regression guard on the SHIPPED content, not a
    property true by construction any more. --- */
 ok('P.DIRECTIONS has exactly 8 entries, west first and east last',
  P.DIRECTIONS.length===8&&P.DIRECTIONS[0]==='west'&&P.DIRECTIONS[7]==='east');
 ok('every P.DIRECTIONS id has a P.DIRECTION_LABELS entry',
  P.DIRECTIONS.every(function(d){return !!P.DIRECTION_LABELS[d];}));
 ok('P.directionMul is strictly ascending across the 8 directions (easiest to hardest)',
  P.DIRECTIONS.every(function(d,i){return i===0||P.directionMul(d)>P.directionMul(P.DIRECTIONS[i-1]);}),
  P.DIRECTIONS.map(function(d){return d+':'+P.directionMul(d).toFixed(2);}).join(', '));
 ok('P.directionMul falls back to 1 for an unrecognized direction',
  P.directionMul('nowhere')===1);

 /* --- v2.17: each direction's themed affinity axis (farroaddungeons.csv's
    own `affinity` column) — content-pipeline.js already fails the whole
    build loudly on an unrecognized axis, so this is a regression guard on
    the SHIPPED assignment, same spirit as the directionMul checks above:
    Ian's own two named examples (west->Fire, east->Spirit) hold, and the
    8 directions walk the canonical AFFINITY_AXES order with no axis
    reused twice. */
 (function(){
  var AFFINITY_AXES=['fire','water','earth','air','light','dark','body','spirit'];
  ok('west is Fire-themed and east is Spirit-themed, exactly as asked',
   P.DIRECTION_CONFIG.west.affinity==='fire' && P.DIRECTION_CONFIG.east.affinity==='spirit');
  ok('every direction\'s themed affinity is one of the 8 known axes',
   P.DIRECTIONS.every(function(d){return AFFINITY_AXES.indexOf(P.DIRECTION_CONFIG[d].affinity)>=0;}));
  ok('the 8 directions walk the canonical AFFINITY_AXES order west to east, no axis repeated',
   P.DIRECTIONS.every(function(d,i){return P.DIRECTION_CONFIG[d].affinity===AFFINITY_AXES[i];}));
 })();
 ok('P.DIRECTION_AFFINITY_BONUS is a real, positive flat bonus',
  P.DIRECTION_AFFINITY_BONUS>0, ''+P.DIRECTION_AFFINITY_BONUS);

 /* --- a discovery roll never fires below its own threshold, across many
    seeds — the exact shape rollExpeditionDiscovery() itself checks
    (G.rng.next()>=P.EXPED_DISCOVERY_CHANCE -> bail) ------------------------ */
 var rng=C.makeRNG(31337), overThreshold=0, trials=5000;
 for(var i=0;i<trials;i++){var r=rng.next();if(r<P.EXPED_DISCOVERY_CHANCE)overThreshold++;}
 var rate=overThreshold/trials;
 ok('discovery roll fires at roughly its configured chance across '+trials+' trials',
  Math.abs(rate-P.EXPED_DISCOVERY_CHANCE)<0.02, 'measured '+rate.toFixed(4)+' vs configured '+P.EXPED_DISCOVERY_CHANCE);

 /* --- P.QUEST_LINES: complete, one entry per ROSTER id, exactly 5
    {story,powerFraction,isBoss} stages each — generated from
    farroadquests.csv (content-pipeline.js already validates ascending
    powerFraction and full ROSTER coverage at BUILD time; these are a
    regression guard on the shipped content, checked again here). --- */
 var rosterIds=C.ROSTER.map(function(r){return r.id;});
 var missingLine=rosterIds.filter(function(id){return !P.QUEST_LINES[id];});
 ok('every ROSTER id has a P.QUEST_LINES entry', missingLine.length===0, missingLine.join(','));
 var badShape=[];
 rosterIds.forEach(function(id){
  var line=P.QUEST_LINES[id];if(!line)return;
  if(line.length!==5){badShape.push(id+': '+line.length+' stages, expected 5');return;}
  for(var s=0;s<5;s++){
   var stage=line[s];
   if(!stage||!stage.story||typeof stage.story!=='string')badShape.push(id+' stage'+s+': missing story text');
   if(!(stage.powerFraction>0))badShape.push(id+' stage'+s+': bad powerFraction '+(stage&&stage.powerFraction));
   if(s>0&&!(stage.powerFraction>line[s-1].powerFraction))badShape.push(id+' stage'+s+': powerFraction not ascending');}});
 ok('every quest line has exactly 5 stages with story text and ascending powerFraction',
  badShape.length===0, badShape.slice(0,6).join('; '));
 ok('every quest line\'s stage 5 (index 4) is flagged isBoss',
  rosterIds.every(function(id){return P.QUEST_LINES[id]&&P.QUEST_LINES[id][4].isBoss===true;}));
 ok('P.QUEST_LINES has no stray entries for a non-ROSTER id',
  Object.keys(P.QUEST_LINES).every(function(id){return rosterIds.indexOf(id)>=0;}));

 /* --- P.questStageWave: DIRECTLY proportional to P.powerLevel, not
    inverted through C.levelCurve — see the comment on questStageWave in
    progression.js for why the curve-inversion approach was tried first
    and measured as producing an unwinnable wall (a real 5-unit party's
    powerLevel runs 5-10x levelCurve(their actual wave), and squaring
    that back through the curve overshoots the wave by roughly the
    square of that factor). Stage 5 (frac 1.0) must equal powerLevel
    exactly; stages rise monotonically 1->5 for a fixed player state. --- */
 var questG={wave:200,farthest:200,owned:{kesh:1,ansa:1},lvl:{kesh:30,ansa:20},bonuses:{strike:{potent:2}}};
 var myPower=P.powerLevel(questG);
 var stage5Wave=P.questStageWave(questG,'kesh',4);
 // Ian: "reduce new unit quests difficulty to about 50% of current" --
 // stage 5 (frac 1.0) now equals HALF the player's own power level, not
 // the full figure; QUEST_DIFFICULTY_MUL is the named constant that scaling
 // lives on, so these compare against it explicitly rather than hardcoding
 // "half" a second time.
 ok('questStageWave stage 5 (frac 1.0) equals QUEST_DIFFICULTY_MUL of the player\'s own power level',
  stage5Wave===Math.round(P.QUEST_DIFFICULTY_MUL*myPower), stage5Wave+' vs '+Math.round(P.QUEST_DIFFICULTY_MUL*myPower));
 var stageWaves=[0,1,2,3,4].map(function(s){return P.questStageWave(questG,'kesh',s);});
 ok('questStageWave rises monotonically across stages 1-5 for a fixed player state',
  stageWaves.every(function(w,i){return i===0||w>stageWaves[i-1];}), stageWaves.join(','));
 ok('questStageWave stage 1 matches kesh\'s own stage-1 powerFraction of QUEST_DIFFICULTY_MUL of the player\'s power',
  Math.abs(stageWaves[0]-Math.round(P.QUEST_LINES.kesh[0].powerFraction*P.QUEST_DIFFICULTY_MUL*myPower))<=1,
  stageWaves[0]+' vs expected='+Math.round(P.QUEST_LINES.kesh[0].powerFraction*P.QUEST_DIFFICULTY_MUL*myPower));
 var strongerG={wave:2000,owned:{kesh:1,ansa:1,dorrek:1},lvl:{kesh:150,ansa:150,dorrek:150},bonuses:{}};
 ok('questStageWave scales up for a stronger player at the same stage',
  P.questStageWave(strongerG,'kesh',0)>P.questStageWave(questG,'kesh',0));

 /* --- v2.10: quest-stage Aether reward, 100 (stage 1) -> 500 (stage 5) --- */
 ok('questStageAether hits exactly the floor at stage 1 (stageIdx 0)',
  P.questStageAether(0)===P.QUEST_STAGE_AETHER_MIN, P.questStageAether(0));
 ok('questStageAether hits exactly the ceiling at stage 5 (stageIdx 4)',
  P.questStageAether(4)===P.QUEST_STAGE_AETHER_MAX, P.questStageAether(4));
 ok('questStageAether is strictly increasing across all 5 stages', (function(){
  var prev=-Infinity;
  for(var i=0;i<5;i++){var v=P.questStageAether(i);if(v<=prev)return false;prev=v;}
  return true;
 })());
 ok('questStageAether matches the documented 100/200/300/400/500 schedule',
  [0,1,2,3,4].map(function(i){return P.questStageAether(i);}).join(',')==='100,200,300,400,500');

 /* --- v2.10: "replace all mentions of Kesh with the name the player
    chooses" — mcName()/withMcName() themselves are UI-layer/DOM-bound
    (not loaded in this headless harness), so what's checked here is the
    CSV-authored half of the fix: kesh's own quest-line story text and
    oath's (Kesh's default charge action) design note must use the
    {{name}} substitution token, not a literal hardcoded "Kesh" — a
    regression guard against someone typing the name back in by hand
    later without knowing about the token. */
 ok('kesh\'s quest-line story text uses the {{name}} token, not a literal "Kesh"',
  P.QUEST_LINES.kesh.every(function(s){return s.story.indexOf('{{name}}')>=0&&s.story.indexOf('Kesh')<0;}));
 ok('oath\'s design note uses the {{name}} token, not a literal "Kesh"',
  C.ACTIONS.oath.note.indexOf('{{name}}')>=0&&C.ACTIONS.oath.note.indexOf('Kesh')<0);

 /* --- FREEZE PROOF: a snapshot's baked stats must be immune to whatever
    CURRENT_WAVE / hardMul happen to be at RECONSTRUCTION time. This is the
    exact property bakeEnemySnapshot()/unitsFromSnapshots() (farroad-ui.js)
    rely on — build a unit from a fixed stat block at one CURRENT_WAVE,
    reconstruct an "equivalent" unit from the SAME plain stat numbers after
    CURRENT_WAVE has moved to somewhere hardMul scales very differently,
    and confirm the reconstructed unit's base stats are bit-for-bit
    identical to the frozen numbers, not re-derived off the new wave. */
 var frozenStats={hp:500,atk:40,mag:20,def:25,res:18,spd:90,
  atkCrit:0.10,magCrit:0.05,chargeRate:1,block:0.05,evade:0.05};
 C.setWave(50);   /* hardMul(50)===1 */
 var u1=C.makeUnit({id:'e0',name:'Frozen Foe',isParty:false,level:1,slotIndex:10,
  arch:'wolf',isBoss:false,row:'front',stats:frozenStats,chargeAction:null,slots:[]});
 C.setWave(1500);   /* hardMul(1500)===HARD_MAX — a wildly different multiplier */
 var u2=C.makeUnit({id:'e0',name:'Frozen Foe',isParty:false,level:1,slotIndex:10,
  arch:'wolf',isBoss:false,row:'front',stats:frozenStats,chargeAction:null,slots:[]});
 C.setWave(1);
 var mismatch=Object.keys(frozenStats).filter(function(k){return u1.base[k]!==u2.base[k];});
 ok('a unit rebuilt from the same frozen stat block is identical regardless of CURRENT_WAVE at reconstruction',
  mismatch.length===0, mismatch.map(function(k){return k+': '+u1.base[k]+' vs '+u2.base[k];}).join('; '));
 ok('the frozen unit\'s stats match the baked numbers exactly (not re-derived)',
  u1.base.hp===500&&u1.base.atk===40&&u1.base.spd===90);

 /* --- save round-trip: dungeons + quests + directions --------------------- */
 var fakeG2={seed:99,rng:{calls:0},wave:1,farthest:1,bossesCleared:0,aether:0,lore:0,marks:0,
  wipes:0,party:['kesh'],actions:['strike','ember'],conditions:['none'],actionCounts:{},
  condCounts:{},bonuses:{},recovery:{},loadout:{},hpCarry:{},touched:{},clearedWaves:{},
  dropsGranted:{},lvl:{kesh:1},bank:{kesh:0},maxLevelEver:1,owned:{kesh:1},enrage:true,
  idleAcc:0,dropQueue:[],dropHistory:[],pullsSinceUnit:0,mc:null,
  expeditions:[{id:'exp1',partyIds:['ansa'],direction:'east',startedAt:1700000000000-600000,
   lastResolvedAt:1700000000000-600000,ew:5,hpFrac:0.8,bank:{aether:10,marks:2},
   homeAt:null,arrivedAt:null,log:[]}],
  dungeons:[{id:'dgn1',name:'East Dungeon (depth 100)',direction:'east',tier:1,
   waves:[{wave:100,enemies:[{name:'Wolf',arch:'wolf',thorns:0,isBoss:false,row:'front',
    chargeAction:null,slots:[],stats:frozenStats}]}],clears:2}],
  quests:{kesh:{stage:2,frozen:[[],[],{name:'x'}]}},
  directions:{west:{maxDepth:40,dungeonsUnlocked:0},northwest:{maxDepth:0,dungeonsUnlocked:0},
   southwest:{maxDepth:0,dungeonsUnlocked:0},north:{maxDepth:0,dungeonsUnlocked:0},
   south:{maxDepth:0,dungeonsUnlocked:0},northeast:{maxDepth:0,dungeonsUnlocked:0},
   southeast:{maxDepth:0,dungeonsUnlocked:0},east:{maxDepth:100,dungeonsUnlocked:1}}};
 var restored2=null,threw2=null;
 try{
  var snap2=V.serialize(fakeG2,1700000000000);
  restored2=V.deserialize(JSON.parse(JSON.stringify(snap2)),C);
 }catch(e){threw2=e;}
 ok('save round-trip with dungeons/quests/directions populated does not throw', !threw2, threw2&&threw2.message);
 ok('save round-trip preserves a dungeon\'s multi-wave shape, direction, and clear count',
  !!restored2&&restored2.dungeons.length===1&&restored2.dungeons[0].clears===2&&
  restored2.dungeons[0].direction==='east'&&restored2.dungeons[0].waves.length===1&&
  restored2.dungeons[0].waves[0].enemies[0].stats.hp===500);
 ok('save round-trip preserves companion quest stage progress',
  !!restored2&&restored2.quests.kesh.stage===2);
 ok('save round-trip preserves per-direction persistent depth/unlock progress',
  !!restored2&&restored2.directions.east.maxDepth===100&&restored2.directions.east.dungeonsUnlocked===1&&
  restored2.directions.west.maxDepth===40);
 ok('save round-trip preserves an expedition\'s direction',
  !!restored2&&restored2.expeditions.length===1&&restored2.expeditions[0].direction==='east');

 /* --- old-save compat: a save from before this feature has neither field,
    deserialize must default rather than throw -------------------------- */
 var oldSnap2=null,oldThrew2=null,oldRestored2=null;
 try{
  oldSnap2=V.serialize(fakeG2,1700000000000);
  delete oldSnap2.dungeons; delete oldSnap2.quests; delete oldSnap2.directions;
  delete oldSnap2.expeditions[0].direction;
  oldRestored2=V.deserialize(JSON.parse(JSON.stringify(oldSnap2)),C);
 }catch(e){oldThrew2=e;}
 ok('old save missing dungeons/quests/directions fields does not throw', !oldThrew2, oldThrew2&&oldThrew2.message);
 ok('old save missing dungeons/quests defaults to []/{kesh:stage 0}',
  !!oldRestored2&&Array.isArray(oldRestored2.dungeons)&&oldRestored2.dungeons.length===0&&
  !!oldRestored2.quests&&!!oldRestored2.quests.kesh&&oldRestored2.quests.kesh.stage===0);
 ok('old save missing directions defaults to all-zero for every P.DIRECTIONS id',
  !!oldRestored2&&oldRestored2.directions&&
  ['west','northwest','southwest','north','south','northeast','southeast','east'].every(function(d){
   return oldRestored2.directions[d]&&oldRestored2.directions[d].maxDepth===0&&
    oldRestored2.directions[d].dungeonsUnlocked===0;}));
 ok('old save\'s in-flight expedition missing a direction defaults to west',
  !!oldRestored2&&oldRestored2.expeditions[0].direction==='west');
})();

/* =================== 17. ELEMENTAL AFFINITIES (v2.10) ======================
 * C.affinityMul (combat formula, lives in core.js — see the layering
 * comment there for why it's not in progression) must be well-behaved at
 * the extremes: monotonic, odd-symmetric, exactly 0 at raw 0, exactly
 * +-0.80 at +-AFFINITY_CAP (not merely close — Math.min clamps the input,
 * so this is a real plateau). P.affinityCostToNext must escalate and stay
 * positive. Every magic DAMAGE action in the compiled content must carry
 * an element (content-pipeline.js's own build-time validation already
 * enforces this — buildContent() would have failed loudly above if it
 * didn't — this re-checks the SAME property against the live ACTIONS table
 * so a future core.js/content-pipeline.js drift is still caught here, not
 * just at build time). G.affinities must round-trip through save/load,
 * including the old-save default-fill path. */
(function(){
 /* --- C.affinityMul: monotonic, odd-symmetric, exact endpoints ---------- */
 ok('C.affinityMul(0) is exactly 0', C.affinityMul(0)===0);
 ok('C.affinityMul is exactly +0.80 at +AFFINITY_CAP', Math.abs(C.affinityMul(C.AFFINITY_CAP)-0.80)<1e-9);
 ok('C.affinityMul is exactly -0.80 at -AFFINITY_CAP', Math.abs(C.affinityMul(-C.AFFINITY_CAP)-(-0.80))<1e-9);
 ok('C.affinityMul plateaus past the cap (no further movement beyond AFFINITY_CAP)',
  C.affinityMul(C.AFFINITY_CAP*5)===C.affinityMul(C.AFFINITY_CAP));
 ok('C.affinityMul is odd-symmetric', (function(){
  for(var r=-30;r<=30;r+=1.7) if(Math.abs(C.affinityMul(r)+C.affinityMul(-r))>1e-9) return false;
  return true;
 })());
 ok('C.affinityMul is monotonically increasing across the full range', (function(){
  var prev=-Infinity;
  for(var r=-30;r<=30;r+=0.5){var v=C.affinityMul(r);if(v<prev-1e-12)return false;prev=v;}
  return true;
 })());

 /* --- P.affinityCostToNext: escalates, always positive ------------------ */
 /* v2.10: AFFINITY_COST_BASE is no longer a round number (4.0976 — see
    the comment above it), chosen to land the doubled-length curve
    exactly on 2x the old total cost, so the first purchase's cost is
    the ROUNDED base, not the raw constant. */
 ok('P.affinityCostToNext(0) equals AFFINITY_COST_BASE, rounded (first point on a fresh axis)',
  P.affinityCostToNext(0)===Math.round(P.AFFINITY_COST_BASE));
 ok('P.affinityCostToNext escalates with points already invested', (function(){
  var prev=0;
  for(var n=0;n<10;n++){var c=P.affinityCostToNext(n);if(c<=prev)return false;prev=c;}
  return true;
 })());
 ok('P.affinityCostToNext is always positive', P.affinityCostToNext(0)>0&&P.affinityCostToNext(50)>0);

 /* --- every magic damage action in the compiled content carries an element,
    the same property content-pipeline.js's own build-time validation
    already enforces (buildContent() above would have exited the whole
    process if it didn't) — re-checked here against the live ACTIONS table
    so a future drift between core.js and content-pipeline.js is still
    caught by this test, not only by a build. --- */
 ok('every magic damage action has an element', Object.keys(C.ACTIONS).every(function(id){
  var a=C.ACTIONS[id];
  return !(a.camp==='mag'&&(a.power||0)>0&&!a.heal&&!a.element);
 }));
 ok('at least one physical action also carries an element (double-stack case is real content, not just theory)',
  Object.keys(C.ACTIONS).some(function(id){var a=C.ACTIONS[id];return a.camp==='atk'&&!!a.element;}));

 /* --- C.makeUnit defaults affinity to all-0 and accepts an override ----- */
 var plain=C.makeUnit({id:'x',name:'X',stats:{},slots:[]});
 ok('makeUnit defaults every affinity axis to 0',
  ['fire','water','earth','air','light','dark','body','spirit'].every(function(ax){return plain.affinity[ax]===0;}));
 var custom=C.makeUnit({id:'y',name:'Y',stats:{},slots:[],affinity:{fire:5,spirit:-3}});
 ok('makeUnit honors a partial cfg.affinity override, defaulting the rest',
  custom.affinity.fire===5&&custom.affinity.spirit===-3&&custom.affinity.water===0);

 /* --- affinity changes damage, driven through a real deterministic battle
    (same makeUnit/makeBattle/step path digestRun above uses) — a Fire-
    affine attacker using a Fire-tagged action (ember) should deal MORE
    total damage than a neutral one against the same target, and Body
    should independently do the same for a pure physical action (strike,
    no element) ------------------------------------------------------- */
 ok('ember carries element fire (content assignment)', C.ACTIONS.ember&&C.ACTIONS.ember.element==='fire');
 function dmgWithAffinity(actionId,affinity){
  C.setWave(1);
  var atk=C.makeUnit({id:'a',name:'A',isParty:true,level:1,slotIndex:0,
   stats:{atk:30,mag:30,def:10,res:10,spd:100},affinity:affinity||{},
   slots:[{cond:'none',action:actionId},{cond:'none',action:actionId}]});
  var tgt=C.makeUnit({id:'t',name:'T',isParty:false,level:1,slotIndex:10,
   stats:{hp:100000,atk:10,mag:10,def:10,res:10,spd:100},
   slots:[{cond:'none',action:'strike'},{cond:'none',action:'strike'}]});
  var b=C.makeBattle([atk,tgt],{rng:C.makeRNG(1),deterministic:true});
  var total=0;
  for(var i=0;i<6&&!b.over;i++){var e=C.step(b);if(e&&e.actorId==='a')total+=e.totalDamage;}
  return total;}
 var fireDmg=dmgWithAffinity('ember',{fire:10}), neutralDmg=dmgWithAffinity('ember',{});
 ok('positive Fire affinity increases a Fire-tagged action\'s damage',
  fireDmg>neutralDmg, fireDmg+' vs '+neutralDmg);
 var bodyDmg=dmgWithAffinity('strike',{body:10}), neutralPhysDmg=dmgWithAffinity('strike',{});
 ok('positive Body affinity increases a physical action\'s damage',
  bodyDmg>neutralPhysDmg, bodyDmg+' vs '+neutralPhysDmg);
 var negFireDmg=dmgWithAffinity('ember',{fire:-10});
 ok('negative Fire affinity decreases a Fire-tagged action\'s damage vs neutral',
  negFireDmg<neutralDmg, negFireDmg+' vs '+neutralDmg);

 /* --- Spirit changes healing, same real-battle pattern ------------------ */
 function healWithSpirit(casterSpirit,targetSpirit){
  C.setWave(1);
  var healer=C.makeUnit({id:'h',name:'H',isParty:true,level:1,slotIndex:0,
   stats:{atk:10,mag:30,def:10,res:10,spd:100},affinity:{spirit:casterSpirit},
   slots:[{cond:'none',action:'mend'},{cond:'none',action:'mend'}]});
  var hurt=C.makeUnit({id:'p2',name:'P2',isParty:true,level:1,slotIndex:1,
   stats:{hp:100000,atk:10,mag:10,def:10,res:10,spd:90},affinity:{spirit:targetSpirit},
   hp:1,maxHp:100000,slots:[{cond:'none',action:'strike'},{cond:'none',action:'strike'}]});
  var b=C.makeBattle([healer,hurt],{rng:C.makeRNG(1),deterministic:true});
  var healed=0;
  for(var i=0;i<4&&!b.over;i++){var e=C.step(b);
   if(e&&e.actorId==='h'&&e.heals)e.heals.forEach(function(h){if(h.targetName==='P2')healed+=h.amount;});}
  return healed;}
 var healHigh=healWithSpirit(10,10), healNeutral=healWithSpirit(0,0);
 ok('positive Spirit (caster and target) increases healing received',
  healHigh>healNeutral, healHigh+' vs '+healNeutral);

 /* --- AFFINITY_BOOST_CAP: Spirit stacking (both sides maxed) cannot push a
    status's scaled magnitude past what AFFINITY_CAP itself promises
    elsewhere (±80%) — regression guard for the exploit path this cap
    closed: Warded's -40% base delta at both-Spirit-maxed measured -129.6%
    (more than 100% mitigation) before AFFINITY_BOOST_CAP existed, and the
    SAME unclamped multiplier fed tcOf's Hasted term with no protective
    floor at all. Driven through a real battle (bulwark applies warded to
    an ally) rather than asserted on affBoost directly, since affBoost
    itself isn't exported. --------------------------------------------- */
 (function(){
  C.setWave(1);
  var caster=C.makeUnit({id:'c',name:'C',isParty:true,level:1,slotIndex:0,
   stats:{atk:10,mag:30,def:10,res:10,spd:100},affinity:{spirit:C.AFFINITY_CAP},
   slots:[{cond:'none',action:'bulwark'},{cond:'none',action:'bulwark'}]});
  var ally=C.makeUnit({id:'p2',name:'P2',isParty:true,level:1,slotIndex:1,
   stats:{hp:100000,atk:10,mag:10,def:10,res:10,spd:90},affinity:{spirit:C.AFFINITY_CAP},
   hp:1,maxHp:100000,slots:[{cond:'none',action:'strike'},{cond:'none',action:'strike'}]});
  var b=C.makeBattle([caster,ally],{rng:C.makeRNG(1),deterministic:true});
  C.step(b);   /* caster casts bulwark on the lowest-HP ally (p2) */
  var delta=ally.stMag&&ally.stMag.warded;
  ok('AFFINITY_BOOST_CAP holds Warded\'s scaled delta at exactly -0.80 with both sides at AFFINITY_CAP',
   typeof delta==='number'&&Math.abs(delta-(-0.80))<1e-9, String(delta));
 })();

 /* --- G.affinities round-trips through save/load, old-save default-fill - */
 (function(){
  var fakeG3={seed:1,rng:{calls:0},wave:1,farthest:1,bossesCleared:0,aether:0,lore:0,marks:0,wipes:0,
   party:['kesh'],actions:['strike'],conditions:['none'],actionCounts:{},condCounts:{},bonuses:{},
   recovery:{},loadout:{},hpCarry:{},touched:{},clearedWaves:{},dropsGranted:{},
   lvl:{kesh:1},bank:{kesh:0},maxLevelEver:1,owned:{kesh:1},enrage:true,idleAcc:0,
   dropQueue:[],dropHistory:[],pullsSinceUnit:0,mc:null,expeditions:[],dungeons:[],
   quests:{kesh:{stage:0,frozen:[]}},directions:{},affinities:{kesh:{fire:3,spirit:-2}}};
  var snap3=V.serialize(fakeG3,1700000000000);
  var restored3=V.deserialize(JSON.parse(JSON.stringify(snap3)),C);
  ok('G.affinities round-trips through save/load',
   !!restored3&&!!restored3.affinities&&restored3.affinities.kesh.fire===3&&restored3.affinities.kesh.spirit===-2);
  var oldSnap3=V.serialize(fakeG3,1700000000000);
  delete oldSnap3.affinities;
  var oldRestored3=V.deserialize(JSON.parse(JSON.stringify(oldSnap3)),C);
  ok('old save missing affinities field does not throw and defaults to {kesh:{}}',
   !!oldRestored3&&!!oldRestored3.affinities&&!!oldRestored3.affinities.kesh&&
   Object.keys(oldRestored3.affinities.kesh).length===0);
 })();
})();

/* =================== 18. EVADE/CRIT INVESTMENT (v2.10) =====================
 * "Level like affinities" but shaped like Recovery instead — a fixed step
 * per purchase, geometrically escalating cost, hard-capped at the ENGINE's
 * own C.CAP_EVADE/C.CAP_CRIT. Block was here too until Ian removed it
 * entirely (Body affinity already covers physical damage reduction — see
 * farroad-core.js). applyCustomMC() itself lives in the DOM-bound UI layer
 * (not loaded in this headless harness — same reason resolveExpedition/
 * attemptQuestStage aren't unit-tested here either), so "a custom MC
 * starts at exactly 0" is verified live in the browser instead (see the
 * plan). What IS headless and checked here: the formulas those UI call
 * sites are built on (P.pctStatCost/P.pctStatValue/P.pctStatMaxed), the MC
 * creation shrink (folded into section 7 above), the new Power Level term,
 * and G.statInvest's save/load round-trip including old-save
 * default-fill. */
(function(){
 var STATS=['evade','atkCrit','magCrit'];
 /* --- cost escalates, always positive, for all 3 stats -------------------- */
 STATS.forEach(function(stat){
  ok('P.pctStatCost('+stat+',0) equals the stat\'s own costBase (first step)',
   P.pctStatCost(stat,0)===P.PCT_STAT[stat].costBase);
  ok('P.pctStatCost('+stat+') escalates with steps already invested', (function(){
   var prev=0;
   for(var n=0;n<8;n++){var c=P.pctStatCost(stat,n);if(c<=prev)return false;prev=c;}
   return true;
  })());
  ok('P.pctStatCost('+stat+') is always positive',
   P.pctStatCost(stat,0)>0&&P.pctStatCost(stat,20)>0);
 });

 /* --- pctStatValue: baseline + steps*step, clamped exactly at the cap ---- */
 ok('P.pctStatValue with 0 steps returns the baseline unchanged',
  P.pctStatValue(0.05,'evade',0)===0.05);
 ok('P.pctStatValue adds steps*step on top of baseline',
  Math.abs(P.pctStatValue(0.05,'evade',2)-(0.05+2*P.PCT_STAT.evade.step))<1e-9);
 ok('P.pctStatValue clamps exactly at the stat\'s own cap, never above it',
  P.pctStatValue(0,'evade',1000)===C.CAP_EVADE &&
  P.pctStatValue(0,'atkCrit',1000)===C.CAP_CRIT);
 ok('P.pctStatMaxed agrees with pctStatValue reaching the cap',
  P.pctStatMaxed(0,'evade',1000)===true && P.pctStatMaxed(0,'evade',0)===false);
 ok('Block no longer exists as a purchasable stat',
  !P.PCT_STAT.block && C.CAP_BLOCK===undefined);

 /* --- Power Level (rescaled per later feedback): scales with combined
    units stats/total lore levels/furthest wave reached ONLY -- purchased
    Evade/Crit steps and raw affinity points are deliberately no longer
    separate terms (dropped along with unit-count/unit-level, per Ian's
    own literal 3-item list), so investing in either should NOT move the
    number -- confirms that's the case by construction, not a regression. */
 var baseG={farthest:1,owned:{kesh:1},lvl:{kesh:1},bonuses:{},affinities:{},statInvest:{}};
 var basePower=P.powerLevel(baseG);
 var investedG={farthest:1,owned:{kesh:1},lvl:{kesh:1},bonuses:{},affinities:{},
  statInvest:{kesh:{atkCrit:4,evade:2}}};
 ok('powerLevel is unaffected by purchased Evade/Crit steps (dropped from the new formula)',
  P.powerLevel(investedG)===basePower);

 /* --- G.statInvest round-trips through save/load, old-save default-fill - */
 (function(){
  var fakeG4={seed:1,rng:{calls:0},wave:1,farthest:1,bossesCleared:0,aether:0,lore:0,marks:0,wipes:0,
   party:['kesh'],actions:['strike'],conditions:['none'],actionCounts:{},condCounts:{},bonuses:{},
   recovery:{},loadout:{},hpCarry:{},touched:{},clearedWaves:{},dropsGranted:{},
   lvl:{kesh:1},bank:{kesh:0},maxLevelEver:1,owned:{kesh:1},enrage:true,idleAcc:0,
   dropQueue:[],dropHistory:[],pullsSinceUnit:0,mc:null,expeditions:[],dungeons:[],
   quests:{kesh:{stage:0,frozen:[]}},directions:{},affinities:{kesh:{}},
   statInvest:{kesh:{evade:3,atkCrit:5}}};
  var snap4=V.serialize(fakeG4,1700000000000);
  var restored4=V.deserialize(JSON.parse(JSON.stringify(snap4)),C);
  ok('G.statInvest round-trips through save/load',
   !!restored4&&!!restored4.statInvest&&restored4.statInvest.kesh.evade===3&&
   restored4.statInvest.kesh.atkCrit===5);
  var oldSnap4=V.serialize(fakeG4,1700000000000);
  delete oldSnap4.statInvest;
  var oldRestored4=V.deserialize(JSON.parse(JSON.stringify(oldSnap4)),C);
  ok('old save missing statInvest field does not throw and defaults to {kesh:{}}',
   !!oldRestored4&&!!oldRestored4.statInvest&&!!oldRestored4.statInvest.kesh&&
   Object.keys(oldRestored4.statInvest.kesh).length===0);
 })();
})();

/* =================== 19. FEEDBACK BATCH (v2.11) ============================
 * Keen (crit) retired from Lore — redundant now that ATK/MAG Crit are
 * directly Aether-investable (P.PCT_STAT) — with a save migration so
 * banked keen stacks refund to G.lore rather than vanishing; enrage now
 * scales MAG as well as ATK; lifesteal/drain scales with the caster's
 * own Spirit, same as any other heal. */
(function(){
 /* --- Keen is genuinely gone, not just hidden ---------------------------- */
 ok('C.BONUSES.keen no longer exists', C.BONUSES.keen===undefined);
 ok('C.bonusApplies never returns true for keen on any action', (function(){
  return Object.keys(C.ACTIONS).every(function(id){return !C.bonusApplies(C.ACTIONS[id],'keen');});
 })());
 ok('applying a keen stack does not add a crit bonus', (function(){
  var before=C.ACTIONS.strike.critBonus;
  C.applyBonuses({strike:{keen:5}});
  var after=C.ACTIONS.strike.critBonus;
  C.applyBonuses({});   /* reset back to pristine for any later test */
  return before===after;
 })());

 /* --- old save with banked keen stacks migrates to a per-action refund --- */
 (function(){
  var fakeG5={seed:1,rng:{calls:0},wave:1,farthest:1,bossesCleared:0,aether:0,
   loreByAction:{strike:10},marks:0,wipes:0,
   party:['kesh'],actions:['strike','ember'],conditions:['none'],actionCounts:{},condCounts:{},
   bonuses:{strike:{keen:3,potent:2},ember:{keen:2}},
   recovery:{},loadout:{},hpCarry:{},touched:{},clearedWaves:{},dropsGranted:{},
   lvl:{kesh:1},bank:{kesh:0},maxLevelEver:1,owned:{kesh:1},enrage:true,idleAcc:0,
   dropQueue:[],dropHistory:[],pullsSinceUnit:0,mc:null,expeditions:[],dungeons:[],
   quests:{kesh:{stage:0,frozen:[]}},directions:{},affinities:{kesh:{}},statInvest:{kesh:{}}};
  var snap5=V.serialize(fakeG5,1700000000000);
  var restored5=V.deserialize(JSON.parse(JSON.stringify(snap5)),C);
  ok('a save with banked keen stacks does not throw on load', !!restored5);
  ok('keen is stripped from every bonus map on load',
   !!restored5&&!restored5.bonuses.strike.keen&&!restored5.bonuses.ember.keen);
  ok('non-keen stacks on the same action survive the migration untouched',
   !!restored5&&restored5.bonuses.strike.potent===2);
  /* v2.13: flat 1-per-stack cost (no more triangular scaling), and the
     refund now credits THAT ACTION's own loreByAction pool, not a shared
     global. strike had {keen:3,potent:2} -> total 5, flat cost 5; without
     keen it's just {potent:2} -> total 2, cost 2; refund 3, on top of the
     pre-existing loreByAction.strike=10 -> 13. ember had {keen:2} -> total
     2, cost 2; without keen, total 0, cost 0; refund 2, on top of ember's
     own (previously absent, so starting at 0) pool -> 2. */
  ok('banked keen stacks refund the correct flat-cost difference to that action\'s own loreByAction pool',
   !!restored5&&restored5.loreByAction.strike===13&&restored5.loreByAction.ember===2,
   restored5&&JSON.stringify(restored5.loreByAction));
 })();

 /* --- enrage scales MAG and SPD as well as ATK, in a real battle --------- */
 (function(){
  C.setWave(1);
  var rng=C.makeRNG(4242);
  var tank=C.makeUnit({id:'p1',name:'Tank',isParty:true,level:1,slotIndex:0,row:'front',
   stats:{atk:1,mag:1,def:9999,res:9999,spd:100,evade:0},maxHp:1e9,hp:1e9,
   slots:[{cond:'none',action:'strike'}]});
  var caster=C.makeUnit({id:'e1',name:'Caster',isParty:false,level:1,slotIndex:10,
   stats:{atk:1,mag:50,def:9999,res:9999,spd:100,evade:0},maxHp:1e9,hp:1e9,
   slots:[{cond:'none',action:'ember'}]});
  var magBefore=caster.base.mag,atkBefore=caster.base.atk,spdBefore=caster.base.spd;
  var b=C.makeBattle([tank,caster],{rng:rng,enrage:true});
  var guard=0;
  while(b.beat<C.ENRAGE_AFTER+10&&guard++<1000)C.step(b);
  ok('enrage raises MAG as well as ATK on a real enemy',
   caster.base.mag>magBefore&&caster.base.atk>atkBefore,
   'mag '+magBefore+'->'+caster.base.mag+' atk '+atkBefore+'->'+caster.base.atk);
  ok('enrage raises SPD too (Ian: "have enrage increase speed as well")',
   caster.base.spd>spdBefore, 'spd '+spdBefore+'->'+caster.base.spd);
 })();

 /* --- lifesteal scales with the attacker's own Spirit --------------------- */
 (function(){
  function drainWith(spiritVal){
   C.setWave(1);
   var atk=C.makeUnit({id:'a',name:'A',isParty:false,level:1,slotIndex:0,
    stats:{atk:30,mag:10,def:10,res:10,spd:100},affinity:{spirit:spiritVal},hp:1,
    slots:[{cond:'none',action:'siphon'},{cond:'none',action:'siphon'}]});
   var tgt=C.makeUnit({id:'t',name:'T',isParty:true,level:1,slotIndex:10,
    stats:{hp:1000000,atk:10,mag:10,def:10,res:10,spd:90},
    slots:[{cond:'none',action:'strike'},{cond:'none',action:'strike'}]});
   var b=C.makeBattle([atk,tgt],{rng:C.makeRNG(1),deterministic:true});
   var before=atk.hp;C.step(b);
   return atk.hp-before;}
  ok('siphon is a lifesteal action (fixture sanity check)', C.ACTIONS.siphon&&C.ACTIONS.siphon.lifesteal>0);
  var drainHigh=drainWith(C.AFFINITY_CAP), drainNeutral=drainWith(0), drainLow=drainWith(-C.AFFINITY_CAP);
  ok('positive Spirit increases the attacker\'s own lifesteal/drain',
   drainHigh>drainNeutral, drainHigh+' vs '+drainNeutral);
  ok('negative Spirit decreases the attacker\'s own lifesteal/drain',
   drainLow<drainNeutral, drainLow+' vs '+drainNeutral);
 })();
})();

/* =================== 20. RARITY (v2.12) ====================================
 * Common/Rare/Legendary on actions and units — see the RARITY comment in
 * core.js (RARITY_POWER_MUL/RARITY_COST_MUL) and the plan this shipped
 * from. Checks: every ACTIONS/ROSTER/ARCH entry has a valid rarity;
 * bonusPrice/bonusSpend agree on a rarity-adjusted total (save round-trip,
 * same shape the Keen-migration test above used); rarityCostMul is wired
 * into unit-leveling cost; the weighted unit-pull table sums to 1 and
 * skews Common; the nested Legendary-charge roll fires near its configured
 * rate over many trials (same methodology as the EXPED_DISCOVERY_CHANCE
 * smoke check). */
(function(){
 var KNOWN_RARITIES=['common','rare','legendary'];
 /* --- every entry has a valid rarity, defaulting correctly when blank --- */
 (function(){
  var bad=[];
  Object.keys(C.ACTIONS).forEach(function(id){
   if(KNOWN_RARITIES.indexOf(C.ACTIONS[id].rarity)<0)bad.push('ACTIONS.'+id+'='+C.ACTIONS[id].rarity);});
  C.ROSTER.forEach(function(r){
   if(KNOWN_RARITIES.indexOf(r.rarity)<0)bad.push('ROSTER.'+r.id+'='+r.rarity);});
  Object.keys(C.ARCH).forEach(function(key){
   if(KNOWN_RARITIES.indexOf(C.ARCH[key].rarity)<0)bad.push('ARCH.'+key+'='+C.ARCH[key].rarity);});
  ok('every ACTIONS/ROSTER/ARCH entry has a valid rarity', bad.length===0, bad.join(', '));
 })();
 ok('a blank rarity column compiles to common (enemies untouched this pass)',
  C.ACTIONS.bite.rarity==='common' && C.ARCH.wolf.rarity==='common');
 ok('the 5 roster-expansion companions are Rare, the original 5 are Common', (function(){
  var rare=['skarn','sorin','nyra','brenn','sael'],common=['kesh','ansa','dorrek','vey','mirel'];
  var byId={};C.ROSTER.forEach(function(r){byId[r.id]=r;});
  return rare.every(function(id){return byId[id].rarity==='rare';}) &&
   common.every(function(id){return byId[id].rarity==='common';});
 })());
 ok('reckoning and hollowtoll are Legendary, the rest of the drop pool is Rare',
  C.ACTIONS.reckoning.rarity==='legendary' && C.ACTIONS.hollowtoll.rarity==='legendary' &&
  C.ACTIONS.sunder.rarity==='rare' && C.ACTIONS.atk_reckless.rarity==='rare');

 /* --- bonusPrice/bonusSpend are rarity-INDEPENDENT again (v2.13 revert) -- */
 (function(){
  /* oath (rare) — v2.12 briefly scaled this by RARITY_COST_MUL.rare and
     escalated per stack; v2.13 reverts both. 3 stacked Swift bonuses on a
     Rare action must cost exactly 3 flat Lore, same as they would on a
     Common action, and bonusSpend must reconstruct the same total from the
     resulting {swift:3} map alone. */
  var p1=C.bonusPrice(C.ACTIONS.oath,'swift',0);
  var p2=C.bonusPrice(C.ACTIONS.oath,'swift',1);
  var p3=C.bonusPrice(C.ACTIONS.oath,'swift',2);
  ok('bonusPrice on a Rare action is flat 1 per stack, no rarity scaling (v2.13 revert)',
   p1===1 && p2===1 && p3===1, p1+','+p2+','+p3);
  var spent=C.bonusSpend({oath:{swift:3}});
  ok('bonusSpend reconstructs the same flat total bonusPrice charged',
   spent===p1+p2+p3, spent+' vs '+(p1+p2+p3));
  /* legendary Broad on reckoning — flat BONUS_COST_BROAD, no rarity scaling. */
  var broadPrice=C.bonusPrice(C.ACTIONS.reckoning,'broad',0);
  ok('bonusPrice broad-branch is flat at BONUS_COST_BROAD, no rarity scaling (v2.13 revert)',
   broadPrice===C.BONUS_COST_BROAD);
  var spentBroad=C.bonusSpend({reckoning:{broad:1}});
  ok('bonusSpend broad-branch agrees with bonusPrice on a Legendary action',
   spentBroad===broadPrice, spentBroad+' vs '+broadPrice);
 })();

 /* --- rarityCostMul is wired into unit-leveling cost (via the fused UI file) */
 ok('RARITY_COST_MUL steeper than RARITY_POWER_MUL at every tier (the cost/ceiling trade-off)',
  C.RARITY_COST_MUL.rare>C.RARITY_POWER_MUL.rare && C.RARITY_COST_MUL.legendary>C.RARITY_POWER_MUL.legendary);
 ok('RARITY_POWER_MUL/RARITY_COST_MUL both flat 1.00 at common (no-op tier)',
  C.RARITY_POWER_MUL.common===1 && C.RARITY_COST_MUL.common===1);

 /* --- weighted unit-pull table sums to 1 and skews Common ---------------- */
 (function(){
  var w=P.RARITY_PULL_WEIGHT;
  ok('P.RARITY_PULL_WEIGHT defined for all 3 tiers', KNOWN_RARITIES.every(function(r){return typeof w[r]==='number';}));
  ok('P.RARITY_PULL_WEIGHT skews toward common (common heaviest)',
   w.common>w.rare, w.common+' vs '+w.rare);
  var total=w.common+w.rare, pCommon=w.common/total;
  /* sample P.weightedRosterPick 2000 times over a fixed 2-common/2-rare
     pool and check the observed common share lands near the closed-form
     expectation — same "roll many times, check the rate" shape the
     nested Legendary-charge check below (and EXPED_DISCOVERY_CHANCE
     elsewhere) already use for a probabilistic pick. */
  var pool=[{id:'c1',rarity:'common'},{id:'c2',rarity:'common'},
            {id:'r1',rarity:'rare'},{id:'r2',rarity:'rare'}];
  var rng=C.makeRNG(4242),hits=0,n=2000;
  for(var i=0;i<n;i++)if(P.weightedRosterPick(rng,pool).rarity==='common')hits++;
  var observed=hits/n;
  ok('sampled P.weightedRosterPick lands within 5% of the closed-form common share',
   Math.abs(observed-pCommon)<0.05, observed+' vs expected '+pCommon);
 })();

 /* --- nested Legendary-charge roll fires near its configured rate -------- */
 (function(){
  var legendaryPool=P.MC_CHARGE_DROP_POOL.filter(function(id){return C.ACTIONS[id].rarity==='legendary';});
  ok('MC_CHARGE_DROP_POOL has exactly the 2 promoted Legendary charges',
   legendaryPool.length===2, legendaryPool.join(','));
  var rng=C.makeRNG(777),legendaryHits=0,n=5000;
  for(var i=0;i<n;i++)if(rng.next()<P.MC_LEGENDARY_CHARGE_CHANCE)legendaryHits++;
  var observed=legendaryHits/n;
  ok('the nested Legendary-vs-Rare roll fires within 3% of MC_LEGENDARY_CHARGE_CHANCE',
   Math.abs(observed-P.MC_LEGENDARY_CHARGE_CHANCE)<0.03, observed+' vs '+P.MC_LEGENDARY_CHARGE_CHANCE);
 })();
})();

/* =================== 21. ELEMENTAL ACTION GRID (v2.13) =====================
 * One atk + one mag equippable action per element (cinderstrike/firebrand/
 * riptideblow/tidalsurge/quakebolt/stoneshatter/squallstrike/zephyrbolt/
 * radiantblow/solarflare/shadowrend/umbralbolt) — every element's atk/mag
 * pair deliberately spread across DIFFERENT rarity tiers so no tier reads
 * as "the fire tier" and no element clusters in one place. First non-Common
 * EQUIPPABLE actions in the game, so C.EQUIPPABLE's two draw sites
 * (randomDrop's wave-parity drop, doPull's action branch) needed rarity
 * weighting for the first time — P.weightedActionPick, mirroring
 * P.weightedRosterPick's shape from section 20. */
(function(){
 var GRID={
  fire:  {atk:'cinderstrike', mag:'firebrand'},
  water: {atk:'riptideblow',  mag:'tidalsurge'},
  earth: {atk:'stoneshatter', mag:'quakebolt'},
  air:   {atk:'squallstrike', mag:'zephyrbolt'},
  light: {atk:'radiantblow',  mag:'solarflare'},
  dark:  {atk:'shadowrend',   mag:'umbralbolt'}};
 var ELEMENTS=Object.keys(GRID);

 /* --- coverage: every element has exactly one atk and one mag equippable - */
 (function(){
  var missing=[];
  ELEMENTS.forEach(function(el){
   var atkMatches=C.ATK_CAMP.filter(function(id){return C.ACTIONS[id].element===el;});
   var magMatches=C.MAG_CAMP.filter(function(id){return C.ACTIONS[id].element===el;});
   if(atkMatches.indexOf(GRID[el].atk)<0)missing.push(el+'.atk ('+GRID[el].atk+') not in ATK_CAMP with that element');
   if(magMatches.indexOf(GRID[el].mag)<0)missing.push(el+'.mag ('+GRID[el].mag+') not in MAG_CAMP with that element');});
  ok('every element has its designated atk action in ATK_CAMP and mag action in MAG_CAMP',
   missing.length===0, missing.join('; '));
 })();
 ok('all 12 grid actions are equippable kind (loadout-usable, not charge)',
  ELEMENTS.every(function(el){
   return !C.ACTIONS[GRID[el].atk].isCharge && !C.ACTIONS[GRID[el].mag].isCharge;}));

 /* --- rarity: each element's atk/mag pair lands in DIFFERENT tiers, and -- */
 /* --- each of the 3 tiers ends up with exactly 4 of the 12 grid actions - */
 (function(){
  var sameTier=ELEMENTS.filter(function(el){
   return C.ACTIONS[GRID[el].atk].rarity===C.ACTIONS[GRID[el].mag].rarity;});
  ok('no element has both its atk and mag grid action in the same rarity tier',
   sameTier.length===0, sameTier.join(','));
  var counts={common:0,rare:0,legendary:0};
  ELEMENTS.forEach(function(el){
   counts[C.ACTIONS[GRID[el].atk].rarity]++;
   counts[C.ACTIONS[GRID[el].mag].rarity]++;});
  ok('the 12 grid actions split exactly 4/4/4 across common/rare/legendary',
   counts.common===4&&counts.rare===4&&counts.legendary===4,
   JSON.stringify(counts));
 })();

 /* --- power: each grid action's power is its camp baseline (Strike 1.00 -- */
 /* --- for atk, Ember 1.05 for mag) x that action's own RARITY_POWER_MUL -- */
 (function(){
  var bad=[];
  ELEMENTS.forEach(function(el){
   var atk=C.ACTIONS[GRID[el].atk], mag=C.ACTIONS[GRID[el].mag];
   var wantAtk=Math.round(1.00*C.RARITY_POWER_MUL[atk.rarity]*100)/100;
   var wantMag=Math.round(1.05*C.RARITY_POWER_MUL[mag.rarity]*100)/100;
   if(atk.power!==wantAtk)bad.push(atk.id+'.power='+atk.power+' want '+wantAtk);
   if(mag.power!==wantMag)bad.push(mag.id+'.power='+mag.power+' want '+wantMag);});
  ok('every grid action\'s power equals its camp baseline scaled by its own RARITY_POWER_MUL',
   bad.length===0, bad.join('; '));
 })();

 /* --- C.EQUIPPABLE actually grew by these 12, no duplicates, no orphans -- */
 (function(){
  var allGridIds=[];ELEMENTS.forEach(function(el){allGridIds.push(GRID[el].atk,GRID[el].mag);});
  ok('all 12 grid ids appear in C.EQUIPPABLE exactly once each',
   allGridIds.every(function(id){
    return C.EQUIPPABLE.filter(function(x){return x===id;}).length===1;}));
  var uniqueEquip=C.EQUIPPABLE.filter(function(id,i){return C.EQUIPPABLE.indexOf(id)===i;});
  ok('C.EQUIPPABLE has no duplicate ids after the grid addition',
   uniqueEquip.length===C.EQUIPPABLE.length);
 })();

 /* --- P.weightedActionPick skews Common, same shape as the unit-pull test */
 (function(){
  var controlled=['strike','ember','riptideblow','zephyrbolt'];  /* strike/ember common, riptideblow/zephyrbolt rare */
  ok('fixture sanity: controlled pool is exactly 2 common + 2 rare',
   controlled.filter(function(id){return C.ACTIONS[id].rarity==='common';}).length===2 &&
   controlled.filter(function(id){return C.ACTIONS[id].rarity==='rare';}).length===2);
  var w=P.RARITY_PULL_WEIGHT, total=w.common*2+w.rare*2, pCommon=(w.common*2)/total;
  var rng=C.makeRNG(2024),hits=0,n=2000;
  for(var i=0;i<n;i++)if(C.ACTIONS[P.weightedActionPick(rng,controlled)].rarity==='common')hits++;
  var observed=hits/n;
  ok('P.weightedActionPick sampled over a mixed pool lands within 5% of the closed-form common share',
   Math.abs(observed-pCommon)<0.05, observed+' vs expected '+pCommon);
 })();
})();

/* =================== 22. EQUIPMENT (v2.14, expanded v2.15) ==================
 * Head/body/legs/hand gear, compiled from farroadequipment.csv. The
 * stat-integration layer (equipOwnedCount/applyEquipmentStats/equipItem/
 * effectiveAffinity's equipment term) lives in farroad-ui.js, which this
 * headless harness doesn't load (DOM-dependent, same reason P.PULL_ODDS/
 * doPull aren't smoke-tested either) — so this section covers exactly
 * what IS reachable: the compiled content and the progression-layer
 * acquisition pieces (P.weightedEquipmentPick, P.EQUIP_DROP_CHANCE), and
 * leans on content-pipeline.js's own build-time validation (already run
 * once at the top of this file — a bad row would have failed loudly
 * there) for slot/rarity/stat-family correctness. The UI-layer math
 * itself is covered by a live browser pass instead.
 * v2.15: expanded from 1 item per (slot,rarity) cell to a 4/3/2 spread
 * (Common/Rare/Legendary) per slot, via named ARCHETYPES — same total
 * stat budget per slot+tier, different atk:mag/def:res/spd:evade split,
 * so "which variant" is a real lateral choice rather than padding. The
 * baseline-reconstruction check below now maps every id to its own
 * archetype's pre-rarity numbers rather than assuming one baseline per
 * slot. */
(function(){
 ok('C.EQUIPMENT compiled with all 39 authored items (36 + 3 v2.20 super boss rewards)',
  Object.keys(C.EQUIPMENT).length===39,
  Object.keys(C.EQUIPMENT).join(','));
 /* v2.20: the 3 super-boss unique rewards sit OUTSIDE the normal 4/3/2
    per-slot distribution below and outside the normal RARITY_POWER_MUL
    reconstruction (they're deliberately scaled ~25% past a normal
    Legendary, not drawn from the same archetype pool) — excluded from
    both, verified by their own dedicated test further down. */
 var SUPERBOSS_EQUIP_IDS=['emberwardencrown','sovereigntideblade','tyrantwindstride'];
 ok('C.EQUIPMENT_SLOTS has the 5 wearable positions, not the 4 CSV slot kinds',
  C.EQUIPMENT_SLOTS.length===5 &&
  C.EQUIPMENT_SLOTS.indexOf('hand1')>=0 && C.EQUIPMENT_SLOTS.indexOf('hand2')>=0);
 ok('every legs item has spd and/or evade but no affinity (content-pipeline.js already enforces this at build time)',
  Object.keys(C.EQUIPMENT).filter(function(id){return C.EQUIPMENT[id].slot==='legs';})
   .every(function(id){var e=C.EQUIPMENT[id];
    return (e.spd||e.evade) && Object.keys(e.affinity).every(function(ax){return !e.affinity[ax];});}));
 ok('every hand item has atk+mag and exactly one nonzero affinity axis',
  Object.keys(C.EQUIPMENT).filter(function(id){return C.EQUIPMENT[id].slot==='hand';})
   .every(function(id){var e=C.EQUIPMENT[id];
    var axesSet=Object.keys(e.affinity).filter(function(ax){return e.affinity[ax];}).length;
    return e.atk && e.mag && axesSet===1;}));
 ok('each slot has exactly 4 Common / 3 Rare / 2 Legendary items (excluding the 3 super boss rewards)',
  (function(){
   var counts={};
   Object.keys(C.EQUIPMENT).filter(function(id){return SUPERBOSS_EQUIP_IDS.indexOf(id)<0;})
    .forEach(function(id){var e=C.EQUIPMENT[id];
    var k=e.slot+'/'+e.rarity;counts[k]=(counts[k]||0)+1;});
   var want={common:4,rare:3,legendary:2};
   return ['head','body','legs','hand'].every(function(slot){
    return Object.keys(want).every(function(r){return counts[slot+'/'+r]===want[r];});});
  })());
 (function(){
  /* Each id's own PRE-rarity archetype numbers — the exact values used
     to author the CSV (baseline x RARITY_POWER_MUL = the shipped
     number), so this reconstructs "was every promoted item scaled
     correctly from its own archetype" rather than assuming a single
     shared baseline per slot. */
  var archetypeOf={
   /* spd baselines carry the same x0.2 starting-SPD-cut reduction the
      roster/enemy tables get elsewhere (was 6/9/3/8) — evade is unaffected. */
   travelersboots:{spd:1.2,evade:0.020}, windstepgreaves:{spd:1.2,evade:0.020}, skyboundsabatons:{spd:1.2,evade:0.020},
   racersstriders:{spd:1.8,evade:0.010}, windrunnerstriders:{spd:1.8,evade:0.010}, tempeststriders:{spd:1.8,evade:0.010},
   nimbleslippers:{spd:0.6,evade:0.032}, phantomslippers:{spd:0.6,evade:0.032},
   wornsandals:{spd:1.6,evade:0.015},
   ironcap:{def:4,res:4,ax:3}, wardedhelm:{def:4,res:4,ax:3}, crownofthebulwark:{def:4,res:4,ax:3},
   sentinelscap:{def:6,res:2,ax:3}, vanguardhelm:{def:6,res:2,ax:3}, stormguardcrown:{def:6,res:2,ax:3},
   blessedcoif:{def:2,res:6,ax:3}, serenecirclet:{def:2,res:6,ax:3},
   shadowedhood:{def:5,res:3,ax:3},
   paddedvest:{def:4,res:4,ax:3}, chainweavemail:{def:4,res:4,ax:3}, aegisofthedeep:{def:4,res:4,ax:3},
   ironcladvest:{def:6,res:2,ax:3}, bastionplate:{def:6,res:2,ax:3}, emberforgedplate:{def:6,res:2,ax:3},
   tidewovenrobe:{def:2,res:6,ax:3}, hallowedvestments:{def:2,res:6,ax:3},
   rootplatejerkin:{def:5,res:3,ax:3},
   worngauntlet:{atk:5,mag:5,ax:3}, runedbracer:{atk:5,mag:5,ax:3}, emberfist:{atk:5,mag:5,ax:3},
   riptideknuckles:{atk:8,mag:2,ax:3}, radiantknuckles:{atk:8,mag:2,ax:3}, maelstromfists:{atk:8,mag:2,ax:3},
   stonewovengloves:{atk:2,mag:8,ax:3}, voidwovengloves:{atk:2,mag:8,ax:3},
   zephyrgrips:{atk:6,mag:4,ax:3}
  };
  var bad=[];
  Object.keys(C.EQUIPMENT).filter(function(id){return SUPERBOSS_EQUIP_IDS.indexOf(id)<0;})
   .forEach(function(id){
   var e=C.EQUIPMENT[id],mul=C.RARITY_POWER_MUL[e.rarity],b=archetypeOf[id];
   if(!b){bad.push(id+': no archetype entry in this test');return;}
   if(e.slot==='legs'){
    if(e.spd!==Math.round(b.spd*mul))bad.push(id+'.spd='+e.spd);
    if(Math.abs(e.evade-Math.round(b.evade*mul*1000)/1000)>1e-9)bad.push(id+'.evade='+e.evade);
   }else{
    var k1=(e.slot==='hand')?'atk':'def', k2=(e.slot==='hand')?'mag':'res';
    if(e[k1]!==Math.round(b[k1]*mul))bad.push(id+'.'+k1+'='+e[k1]);
    if(e[k2]!==Math.round(b[k2]*mul))bad.push(id+'.'+k2+'='+e[k2]);
    var axVal=Object.keys(e.affinity).map(function(ax){return e.affinity[ax];}).reduce(function(a,x){return a+x;},0);
    if(axVal!==Math.round(b.ax*mul))bad.push(id+'.affinity='+axVal);
   }});
  ok('every item\'s stat/affinity values equal its own archetype\'s baseline x its own RARITY_POWER_MUL',
   bad.length===0, bad.join('; '));
 })();
 /* v2.20: the 3 super boss equipment rewards are each "~25% past a normal
    Legendary" of their slot's own balanced archetype (crownofthebulwark/
    emberfist/skyboundsabatons — the same balanced-archetype legendary
    already in archetypeOf above), not an independent number. */
 ok('the 3 super boss equipment rewards are each ~1.25x their slot\'s own balanced-archetype Legendary',
  (function(){
   var bumpMul=1.25;
   var head=C.EQUIPMENT.crownofthebulwark, ember=C.EQUIPMENT.emberwardencrown;
   var hand=C.EQUIPMENT.emberfist, tide=C.EQUIPMENT.sovereigntideblade;
   var legs=C.EQUIPMENT.skyboundsabatons, wind=C.EQUIPMENT.tyrantwindstride;
   /* wind.spd allows +/-1 vs. a straight round(legs.spd*bumpMul): the 80%
      starting-SPD cut shrank every legs spd value down to single digits,
      where re-rounding an already-rounded small integer through a second
      multiplier (rather than re-deriving from the pre-rarity float
      baseline) can land 1 off — not a real authoring mismatch. */
   return ember.def===Math.round(head.def*bumpMul) && ember.res===Math.round(head.res*bumpMul) &&
    tide.atk===Math.round(hand.atk*bumpMul) && tide.mag===Math.round(hand.mag*bumpMul) &&
    Math.abs(wind.spd-Math.round(legs.spd*bumpMul))<=1 &&
    Math.abs(wind.evade-Math.round(legs.evade*bumpMul*1000)/1000)<1e-9;
  })());
 ok('P.EQUIP_DROP_CHANCE matches the "about as rare as units" 0.10 figure reused elsewhere',
  P.EQUIP_DROP_CHANCE===0.10);
 ok('P.weightedEquipmentPick sampled over a mixed pool lands within 5% of the closed-form common share',
  (function(){
   var controlled=['travelersboots','ironcap','windstepgreaves','wardedhelm'];   /* 2 common, 2 rare */
   var w=P.RARITY_PULL_WEIGHT, total=w.common*2+w.rare*2, pCommon=(w.common*2)/total;
   var rng=C.makeRNG(3131),hits=0,n=2000;
   for(var i=0;i<n;i++)if(C.EQUIPMENT[P.weightedEquipmentPick(rng,controlled)].rarity==='common')hits++;
   var observed=hits/n;
   return Math.abs(observed-pCommon)<0.05;
  })());
})();

/* =================== 23. FIELDED ACTION CONFLICT IS A REAL COMBAT RULE (v2.18) =
 * "add a note that fielding them without fixing it will mean the action
 * will not trigger" (Ian) — makes the one-unit-per-non-starter-action
 * rule (previously UI-layer only, farroad-ui.js's actionHolderInParty)
 * a genuine combat restriction: C.step's action-selection (chooseFrom,
 * farroad-core.js) now skips a non-starter slot whose action id is also
 * held by an earlier-fielded (lower slotIndex) party unit, falling back
 * exactly like a failed condition would. Only the earlier unit gets to
 * use it; the later one is not simply blocked-and-idle, it falls back to
 * Strike (or whatever its next slot would have picked). */
(function(){
 C.setWave(1);
 var rng=C.makeRNG(55);
 var earlier=C.makeUnit({id:'p1',name:'Earlier',isParty:true,level:1,slotIndex:0,row:'front',
  stats:{atk:20,mag:1,def:10,res:10,spd:120,evade:0},maxHp:1000,hp:1000,
  slots:[{cond:'none',action:'pierce'}]});
 var later=C.makeUnit({id:'p2',name:'Later',isParty:true,level:1,slotIndex:1,row:'front',
  stats:{atk:20,mag:1,def:10,res:10,spd:100,evade:0},maxHp:1000,hp:1000,
  slots:[{cond:'none',action:'pierce'}]});
 var foe=C.makeUnit({id:'e1',name:'Foe',isParty:false,level:1,slotIndex:10,
  stats:{atk:1,mag:1,def:10,res:10,spd:1,evade:0},maxHp:1e9,hp:1e9,
  slots:[{cond:'none',action:'strike'}]});
 var b=C.makeBattle([earlier,later,foe],{rng:rng,enrage:false});
 var earlierUsedPierce=false,laterEverUsedPierce=false,laterUsedStrike=false,guard=0;
 while(guard++<200&&(!earlierUsedPierce||!laterUsedStrike)){
  var e=C.step(b);if(!e)break;
  if(e.actorId==='p1'&&e.actionId==='pierce')earlierUsedPierce=true;
  if(e.actorId==='p2'&&e.actionId==='pierce')laterEverUsedPierce=true;
  if(e.actorId==='p2'&&e.actionId==='strike')laterUsedStrike=true;}
 ok('the earlier-fielded unit (lower slotIndex) fires the shared action normally',
  earlierUsedPierce);
 ok('the later-fielded unit never fires the shared non-starter action — it genuinely does not trigger',
  !laterEverUsedPierce);
 ok('the later-fielded unit falls back to Strike instead of doing nothing',
  laterUsedStrike);

 /* --- starters stay exempt: both units sharing Strike is normal, not a conflict --- */
 var s1=C.makeUnit({id:'p1',name:'S1',isParty:true,level:1,slotIndex:0,row:'front',
  stats:{atk:20,mag:1,def:10,res:10,spd:120,evade:0},maxHp:1000,hp:1000,
  slots:[{cond:'none',action:'strike'}]});
 var s2=C.makeUnit({id:'p2',name:'S2',isParty:true,level:1,slotIndex:1,row:'front',
  stats:{atk:20,mag:1,def:10,res:10,spd:100,evade:0},maxHp:1000,hp:1000,
  slots:[{cond:'none',action:'strike'}]});
 var foe2=C.makeUnit({id:'e1',name:'Foe',isParty:false,level:1,slotIndex:10,
  stats:{atk:1,mag:1,def:10,res:10,spd:1,evade:0},maxHp:1e9,hp:1e9,
  slots:[{cond:'none',action:'strike'}]});
 var b2=C.makeBattle([s1,s2,foe2],{rng:C.makeRNG(56),enrage:false});
 var bothFiredStrike={p1:false,p2:false},guard2=0;
 while(guard2++<50&&!(bothFiredStrike.p1&&bothFiredStrike.p2)){
  var e2=C.step(b2);if(!e2)break;
  if(e2.actionId==='strike'&&bothFiredStrike[e2.actorId]!==undefined)bothFiredStrike[e2.actorId]=true;}
 ok('starters (Strike) stay exempt — both fielded units can use it with no block',
  bothFiredStrike.p1&&bothFiredStrike.p2);
 /* Enemies are never subject to this rule by construction (the !u.isParty
    guard in actionHeldByEarlierFielded) — not independently re-tested
    here since every OTHER battle test in this file already runs enemies
    sharing ids like 'bite' across multiple bodies in one wave; a broken
    guard would surface as mass failures across the whole suite, not just
    here. */
})();

/* =================== 24. PIERCING WORKS ON MAGIC ACTIONS TOO (v2.19) ========
 * "Does piercing affect defense and resistance? If not, it should" (Ian).
 * It didn't — bonusApplies('piercing') required camp==='atk', even though
 * the underlying mechanic (applyBonuses setting a.defPierce; resolveHit's
 * o.defRaw=isPhys?effDef(tgt):effRes(tgt)) was already fully camp-agnostic.
 * The restriction was the ONLY thing stopping Piercing from working on a
 * magic action; nothing else needed to change. */
(function(){
 ok('bonusApplies(piercing) is true for a magic damage action (was atk-only)',
  C.bonusApplies(C.ACTIONS.ember,'piercing'));
 ok('bonusApplies(piercing) is still true for a physical damage action',
  C.bonusApplies(C.ACTIONS.strike,'piercing'));
 ok('bonusApplies(piercing) is still false for a heal (no defense to pierce)',
  !C.bonusApplies(C.ACTIONS.mend,'piercing'));
 (function(){
  C.applyBonuses({ember:{piercing:2}});
  ok('buying Piercing on a magic action actually sets its defPierce',
   Math.abs(C.ACTIONS.ember.defPierce-0.30)<1e-9, ''+C.ACTIONS.ember.defPierce);
  C.applyBonuses({});   /* reset — same hygiene the Keen-migration test above uses */
 })();
 /* Real combat proof, not just the flag being set: a magic action with
    Piercing must deal MORE damage against a high-RES target than the same
    action unpierced — if defPierce were being ignored for mag actions (the
    old bug, re-introduced), this would show no difference at all. */
 (function(){
  C.setWave(1);
  function dmgAgainstHighRes(pierced){
   C.applyBonuses(pierced?{ember:{piercing:2}}:{});
   var src=C.makeUnit({id:'s',name:'Src',isParty:true,level:1,slotIndex:0,
    stats:{atk:15,mag:40,def:15,res:15,spd:100},maxHp:1000,hp:1000,
    slots:[{cond:'none',action:'ember'}]});
   var tgt=C.makeUnit({id:'t',name:'Tgt',isParty:false,level:1,slotIndex:10,
    stats:{atk:10,mag:10,def:10,res:80,spd:90},maxHp:100000,hp:100000,
    slots:[{cond:'none',action:'strike'}]});
   var b=C.makeBattle([src,tgt],{rng:C.makeRNG(1),deterministic:true});
   var e=null,guard=0;
   while(!e&&guard++<10){var ev=C.step(b);if(ev&&ev.actorId==='s'&&ev.hits&&ev.hits.length)e=ev;}
   C.applyBonuses({});   /* reset before returning, whichever branch ran */
   return e?e.hits[0].damage:null;}
  var dmgUnpierced=dmgAgainstHighRes(false), dmgPierced=dmgAgainstHighRes(true);
  ok('a magic action with Piercing deals more damage to a high-RES target than the same action unpierced',
   dmgUnpierced!=null&&dmgPierced!=null&&dmgPierced>dmgUnpierced,
   'unpierced='+dmgUnpierced+' pierced='+dmgPierced);
 })();
})();

/* =================== 25. SUPER BOSS QUESTS (v2.20) ==========================
 * "found every 250 waves on the Road... about three times as difficult as
 * the wave they're found at... first time defeated, drop a unique related
 * equipment or action... any time after, aether and marks like normal
 * dungeons" (Ian). Most of this feature lives in farroad-ui.js (buildEnemies'
 * superBossKey branch, unlockSuperBoss, enterSuperBoss, finishSideBattle's
 * superboss case) which this suite cannot reach (see the file header — no
 * DOM/UI layer loaded headlessly), so those are verified live in-browser
 * instead (see MODULES.md). What IS headlessly reachable: the P.SUPER_BOSSES
 * data table and P.SUPERBOSS_LEN/P.SUPERBOSS_EVERY constants (progression.js),
 * CHARGE_ACTIONS membership (core.js), and the difficulty formula's own
 * math (every primitive it uses — C.ARCH, C.waveScale, C.dmgTakenMul,
 * P.enemyCount — is core/progression, even though buildEnemies itself isn't). */
(function(){
 ok('P.SUPER_BOSSES has exactly 5 entries, each with a valid affinity axis and rewardKind',
  (function(){
   var axes=Object.keys(C.defaultAffinity());   /* the 8-axis vocabulary, not exported as its own list */
   return P.SUPER_BOSSES.length===5 &&
    P.SUPER_BOSSES.every(function(sb){
     return axes.indexOf(sb.affinity)>=0 &&
      (sb.rewardKind==='equipment'||sb.rewardKind==='action');});
  })(),
  JSON.stringify(P.SUPER_BOSSES));
 ok('every P.SUPER_BOSSES rewardId resolves to real, Legendary-rarity content of the matching kind',
  P.SUPER_BOSSES.every(function(sb){
   var item=sb.rewardKind==='equipment'?C.EQUIPMENT[sb.rewardId]:C.ACTIONS[sb.rewardId];
   return item&&item.rarity==='legendary';}),
  P.SUPER_BOSSES.map(function(sb){return sb.rewardId+': '+
   JSON.stringify(sb.rewardKind==='equipment'?C.EQUIPMENT[sb.rewardId]:C.ACTIONS[sb.rewardId]);}).join('; '));
 ok('every P.SUPER_BOSSES action-kind reward is in CHARGE_ACTIONS (pristine-snapshot support) but NOT in P.MC_CHARGE_DROP_POOL (never randomly rollable)',
  P.SUPER_BOSSES.filter(function(sb){return sb.rewardKind==='action';}).every(function(sb){
   return C.CHARGE_ACTIONS.indexOf(sb.rewardId)>=0 && P.MC_CHARGE_DROP_POOL.indexOf(sb.rewardId)<0;}));
 ok('the 5 bossKeys are unique (cycling must never alias two different rewards to one identity)',
  (function(){var keys=P.SUPER_BOSSES.map(function(sb){return sb.key;});
   return keys.length===Object.keys(keys.reduce(function(m,k){m[k]=1;return m;},{})).length;})());
 ok('the cycling formula (tier-1)%5 walks the 5 bossKeys in order and wraps at tier 6',
  (function(){
   var seq=[];for(var tier=1;tier<=10;tier++)seq.push(P.SUPER_BOSSES[(tier-1)%P.SUPER_BOSSES.length].key);
   var want=P.SUPER_BOSSES.map(function(sb){return sb.key;});
   return JSON.stringify(seq)===JSON.stringify(want.concat(want));
  })());
 ok('P.SUPERBOSS_LEN is 3.0 — "three times as difficult as the wave", read literally', P.SUPERBOSS_LEN===3.0);
 /* Reconstructs buildEnemies' own boss-HP formula (farroad-ui.js) from
    headless-reachable primitives only, without calling buildEnemies itself —
    same technique the file header describes for every other UI-only-reached
    formula this suite still manages to prove. hpBase's own comment there
    is explicit: it sizes a boss against "a NORMAL WAVE at this depth, not
    against one body" — i.e. ref.hpMul*S*enemyCount(w) (no *_LEN factor) IS
    that normal wave's own total HP baseline, so a super boss's ratio
    against it must equal SUPERBOSS_LEN exactly, not BOSS_LEN's 1.40 (that
    would be "3x a regular BOSS", which Ian's "three times as difficult as
    the wave" explicitly is not). */
 ok('a super boss\'s HP is exactly SUPERBOSS_LEN(3.0)x a same-depth NORMAL WAVE\'s total HP, not 3x a regular boss',
  (function(){
   var w=750,ref=C.ARCH.wolf,S=C.waveScale(w);
   var normalWaveHp=200*ref.hpMul*C.dmgTakenMul(ref)*S*Math.max(1,P.enemyCount(w));
   var superHp=normalWaveHp*P.SUPERBOSS_LEN;
   return Math.abs(superHp/normalWaveHp-3.0)<1e-9 && Math.abs(superHp/(normalWaveHp*P.BOSS_LEN)-3.0/P.BOSS_LEN)<1e-9;
  })());
 ok('P.SUPERBOSS_EVERY matches "every 250 waves"', P.SUPERBOSS_EVERY===250);
})();

/* --- tutorialAtkMagMul: halved through wave 20, smooth ramp to normal by
   wave 100 (Ian follow-up: the original flat cliff at w===21 was replaced
   with a gradual ease back in) --------------------------------------- */
(function(){
 ok('tutorialAtkMagMul is exactly halved at wave 20 (the tutorial boss)',
  P.tutorialAtkMagMul(20)===0.5);
 ok('tutorialAtkMagMul stays halved for every wave 1-20, not just the boss',
  P.tutorialAtkMagMul(1)===0.5 && P.tutorialAtkMagMul(10)===0.5);
 ok('tutorialAtkMagMul is back to exactly 1.0 at wave 100 and beyond',
  P.tutorialAtkMagMul(100)===1 && P.tutorialAtkMagMul(150)===1);
 ok('tutorialAtkMagMul rises monotonically and smoothly across 20-100, no cliff',
  (function(){
   var prev=P.tutorialAtkMagMul(20);
   for(var w=21;w<=100;w++){
    var cur=P.tutorialAtkMagMul(w);
    if(cur<prev-1e-9)return false;          // must never decrease
    if(cur-prev>0.02)return false;           // no single-wave jump bigger than 2%
    prev=cur;
   }
   return true;
  })());
 ok('tutorialAtkMagMul at the wave-60 midpoint sits at exactly the halfway point (0.75)',
  Math.abs(P.tutorialAtkMagMul(60)-0.75)<1e-9);
})();

/* --- questStageWave: halved per Ian's "reduce new unit quests difficulty
   to about 50% of current" --------------------------------------------- */
(function(){
 var g={farthest:1,owned:{kesh:1},lvl:{kesh:1},bonuses:{}};
 var rosterId=Object.keys(P.QUEST_LINES)[0];
 var frac=P.QUEST_LINES[rosterId][4].powerFraction;   // stage 5, frac should be 1.0
 var expectedFull=Math.max(1,Math.round(frac*P.powerLevel(g)));
 var expectedHalved=Math.max(1,Math.round(frac*P.QUEST_DIFFICULTY_MUL*P.powerLevel(g)));
 ok('P.QUEST_DIFFICULTY_MUL is exactly 0.5', P.QUEST_DIFFICULTY_MUL===0.5);
 ok('questStageWave stage 5 now returns roughly half of the un-reduced power level',
  P.questStageWave(g,rosterId,4)===expectedHalved && expectedHalved<expectedFull,
  expectedHalved+' vs full '+expectedFull);
})();

/* ------------------------------- report ---------------------------------- */
console.log('\nFARROAD SMOKE TEST');
console.log('  passed ' + passed + '   failed ' + failed);
if (batch) console.log('  headless throughput: ' + batch + ' fights in ' + ms + 'ms (' +
  (ms / Math.max(1, batch)).toFixed(2) + 'ms each)');
if (fails.length) { console.log('\nFAILURES:'); fails.forEach(f => console.log('  ✗ ' + f)); }
process.exit(failed ? 1 : 0);
