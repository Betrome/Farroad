#!/usr/bin/env node
/* =============================================================================
 * FARROAD — parity-reference.js
 * Produces reference output from the REAL farroad-core.js for diffing against
 * the Godot port (godot-project/) — same headless-load technique
 * farroadsmoke.js already uses (a minimal window shim + CSV content), just
 * dumping RNG sequences and battle logs instead of running assertions.
 *
 *   node parity-reference.js rng      -> RNG sequences for a few seeds
 *   node parity-reference.js battle   -> (Step 1b) battle logs
 * =========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const srcDir = path.join(__dirname, 'src');
const load = f => fs.readFileSync(path.join(srcDir, f), 'utf8');

const sandbox = { window: {}, Math: Math, JSON: JSON, console: console };
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

const { buildContent } = require('./content-pipeline.js');
const { content, problems } = buildContent(__dirname);
if (problems.length) { console.error('CONTENT BUILD FAILED:\n' + problems.join('\n')); process.exit(1); }
sandbox.window.FarroadContent = content;

vm.runInContext(load('farroad-core.js'), sandbox, { filename: 'farroad-core.js' });
const C = sandbox.window.FarroadCore;

const mode = process.argv[2] || 'rng';

if (mode === 'rng') {
  const seeds = [1, 12345, 987654321, 42];
  const out = {};
  seeds.forEach(seed => {
    const rng = C.makeRNG(seed);
    const nexts = [];
    for (let i = 0; i < 200; i++) nexts.push(rng.next());
    const rng2 = C.makeRNG(seed);
    const nextInts = [];
    for (let i = 0; i < 100; i++) nextInts.push(rng2.nextInt(37));
    out[seed] = { next: nexts, nextInt: nextInts };
  });
  console.log(JSON.stringify(out));
}

/* Step 1b: hand-authored test content -- deliberately NOT the real CSV
   pipeline (deferred, see plan). Kept identical, by hand, to the literals
   registered in godot-project/test/parity_test.gd's _run_battle(). */
const TEST_ACTIONS = {
  strike: { id: 'strike', name: 'Strike', camp: 'atk', tk: 'foe', power: 1.00, rank: 1.00, charge: 20 },
  mend:   { id: 'mend',   name: 'Mend',   camp: 'mag', tk: 'ally', power: 1.00, rank: 1.20, charge: 15, heal: true },
  ember:  { id: 'ember',  name: 'Ember',  camp: 'mag', tk: 'foe', power: 1.05, rank: 1.05, charge: 21, applies: 'burning', turns: 3 }
};

function registerTestActions() {
  Object.keys(TEST_ACTIONS).forEach(id => { C.ACTIONS[id] = TEST_ACTIONS[id]; });
}

function runBattle(seed, units, enrage) {
  const b = C.makeBattle(units, { rng: C.makeRNG(seed), enrage: !!enrage });
  const log = [];
  let guard = 0;
  while (!b.over && guard++ < 500) {
    const e = C.step(b);
    if (!e) break;
    log.push({
      beat: e.beat, actorId: e.actorId, actionId: e.actionId, targetName: e.targetName,
      totalDamage: e.totalDamage, dot: e.dot, regen: e.regen,
      hits: e.hits.map(h => ({ evaded: h.evaded, crit: h.crit, damage: h.damage })),
      heals: e.heals.map(h => ({ targetName: h.targetName, amount: h.amount })),
      notes: e.notes, hpAfter: b.units.map(u => u.hp)
    });
  }
  return { over: b.over, beats: b.beat, log };
}

if (mode === 'battle') {
  registerTestActions();
  const out = {};

  // Scenario A: 1v1 to the death.
  C.setWave(1);
  out.A = runBattle(7, [
    C.makeUnit({ id: 'p1', name: 'Hero', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 200, atk: 20, mag: 5, def: 10, res: 10, spd: 100 },
      slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e1', name: 'Wolf', isParty: false, level: 1, slotIndex: 10, arch: 'wolf',
      stats: { hp: 150, atk: 15, mag: 5, def: 8, res: 8, spd: 90 }, row: 'front',
      slots: [{ cond: 'none', action: 'strike' }] })
  ]);

  // Scenario B: 2 party (attacker + alternating attacker/healer) vs 2 enemies.
  out.B = runBattle(2024, [
    C.makeUnit({ id: 'p1', name: 'Vanguard', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 220, atk: 18, mag: 5, def: 12, res: 10, spd: 105 },
      slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'p2', name: 'Cleric', isParty: true, level: 1, slotIndex: 1,
      stats: { hp: 180, atk: 8, mag: 16, def: 8, res: 12, spd: 95 },
      slots: [{ cond: 'none', action: 'strike' }, { cond: 'none', action: 'mend' }] }),
    C.makeUnit({ id: 'e1', name: 'Wolf', isParty: false, level: 1, slotIndex: 10, arch: 'wolf', row: 'front',
      stats: { hp: 160, atk: 14, mag: 4, def: 9, res: 9, spd: 92 },
      slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e2', name: 'Hound', isParty: false, level: 1, slotIndex: 11, arch: 'hound', row: 'back',
      stats: { hp: 130, atk: 12, mag: 4, def: 7, res: 7, spd: 110 },
      slots: [{ cond: 'none', action: 'strike' }] })
  ]);

  // Scenario C: a status (Burning) applier vs an enemy, to exercise
  // apply()/magOf()/the per-beat status decrement and DOT tick.
  out.C = runBattle(99, [
    C.makeUnit({ id: 'p1', name: 'Ember Mage', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 190, atk: 8, mag: 22, def: 8, res: 10, spd: 98 },
      slots: [{ cond: 'none', action: 'ember' }] }),
    C.makeUnit({ id: 'e1', name: 'Ox', isParty: false, level: 1, slotIndex: 10, arch: 'ox',
      stats: { hp: 260, atk: 16, mag: 4, def: 12, res: 9, spd: 80 }, row: 'front',
      slots: [{ cond: 'none', action: 'strike' }] })
  ], true);

  console.log(JSON.stringify(out));
}
