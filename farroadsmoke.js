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

const C = sandbox.window.FarroadCore;
const P = sandbox.window.FarroadProgression;

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

/* ------------------------------- report ---------------------------------- */
console.log('\nFARROAD SMOKE TEST');
console.log('  passed ' + passed + '   failed ' + failed);
if (batch) console.log('  headless throughput: ' + batch + ' fights in ' + ms + 'ms (' +
  (ms / Math.max(1, batch)).toFixed(2) + 'ms each)');
if (fails.length) { console.log('\nFAILURES:'); fails.forEach(f => console.log('  ✗ ' + f)); }
process.exit(failed ? 1 : 0);
