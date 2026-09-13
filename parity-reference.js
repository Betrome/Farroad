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

/* Mirrors A() (farroad-core.js:271-272), which isn't exported on F -- the
   real content pipeline always runs every action through it before combat
   ever sees it, so test content must too, or fields it defaults (defPierce,
   critBonus, chargeCost) come back `undefined` here instead of the real 0/
   CHARGE_FULL a CSV-compiled action would always have. This bit Step 1d
   specifically: reading .defPierce/.chargeCost directly (not through a
   defensive `||0`) after a reset exposed the gap between this harness's raw
   `C.ACTIONS[id]=...` assignment and the GDScript side's register_actions(),
   which already runs everything through the ported a_defaults(). */
function applyDefaults(o) {
  o.rank = o.rank || 1; o.charge = o.charge || 0; o.hits = o.hits || 1;
  o.defPierce = o.defPierce || 0; o.critBonus = o.critBonus || 0; o.power = o.power || 0;
  if (o.isCharge) o.chargeCost = o.chargeCost || 100;
  return o;
}

function registerTestActions() {
  Object.keys(TEST_ACTIONS).forEach(id => { C.ACTIONS[id] = applyDefaults(TEST_ACTIONS[id]); });
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

  // Scenario D: self-heal gambit (pct-ladder condition self_hp_lte_50) with
  // a fallback attack slot -- exercises the generic percentile path and
  // resolveTarget's 'ally' fallback (byLowestHp includes the caster itself).
  out.D = runBattle(555, [
    C.makeUnit({ id: 'p1', name: 'Paladin', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 240, atk: 16, mag: 14, def: 11, res: 11, spd: 100 },
      slots: [{ cond: 'self_hp_lte_50', action: 'mend' }, { cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e1', name: 'Ox', isParty: false, level: 1, slotIndex: 10, arch: 'ox', row: 'front',
      stats: { hp: 220, atk: 17, mag: 4, def: 10, res: 9, spd: 88 },
      slots: [{ cond: 'none', action: 'strike' }] })
  ]);

  // Scenario E: bespoke multi-target sorting -- foe_lowest_hp and
  // foe_softest_def across a 3-enemy field.
  out.E = runBattle(777, [
    C.makeUnit({ id: 'p1', name: 'Sniper', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 200, atk: 19, mag: 5, def: 9, res: 9, spd: 102 },
      slots: [{ cond: 'foe_lowest_hp', action: 'strike' }] }),
    C.makeUnit({ id: 'p2', name: 'Breaker', isParty: true, level: 1, slotIndex: 1,
      stats: { hp: 210, atk: 15, mag: 5, def: 10, res: 10, spd: 97 },
      slots: [{ cond: 'foe_softest_def', action: 'strike' }] }),
    C.makeUnit({ id: 'e1', name: 'Wolf', isParty: false, level: 1, slotIndex: 10, arch: 'wolf', row: 'front',
      stats: { hp: 120, atk: 13, mag: 4, def: 11, res: 8, spd: 91 }, slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e2', name: 'Hound', isParty: false, level: 1, slotIndex: 11, arch: 'hound', row: 'back',
      stats: { hp: 130, atk: 12, mag: 4, def: 6, res: 7, spd: 108 }, slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e3', name: 'Knight', isParty: false, level: 1, slotIndex: 12, arch: 'knight', row: 'front',
      stats: { hp: 150, atk: 11, mag: 4, def: 9, res: 10, spd: 85 }, slots: [{ cond: 'none', action: 'strike' }] })
  ]);

  // Scenario F: status-aware conditions -- foe_lacks_debuff (spread burning
  // to whichever foe doesn't have it yet) and foe_healer_present (one enemy
  // carries 'mend' in its own slots).
  out.F = runBattle(333, [
    C.makeUnit({ id: 'p1', name: 'Pyromancer', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 210, atk: 8, mag: 20, def: 9, res: 11, spd: 96 },
      slots: [{ cond: 'foe_lacks_debuff', action: 'ember' }] }),
    C.makeUnit({ id: 'p2', name: 'Watcher', isParty: true, level: 1, slotIndex: 1,
      stats: { hp: 190, atk: 14, mag: 6, def: 9, res: 9, spd: 101 },
      slots: [{ cond: 'foe_healer_present', action: 'strike' }, { cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e1', name: 'Wolf', isParty: false, level: 1, slotIndex: 10, arch: 'wolf', row: 'front',
      stats: { hp: 140, atk: 12, mag: 4, def: 8, res: 8, spd: 90 }, slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e2', name: 'Priest', isParty: false, level: 1, slotIndex: 11, arch: 'priest', row: 'back',
      stats: { hp: 130, atk: 8, mag: 12, def: 7, res: 10, spd: 88 }, slots: [{ cond: 'none', action: 'mend' }] })
  ]);

  console.log(JSON.stringify(out));
}

if (mode === 'bonuses') {
  registerTestActions();
  // 'heavystrike' is a real CHARGE_ACTIONS id -- overwritten here the same
  // way registerTestActions() overwrites strike/mend/ember (real EQUIPPABLE
  // ids), so it's still whitelist-eligible for snapshot() below.
  C.ACTIONS.heavystrike = applyDefaults({ id: 'heavystrike', name: 'Heavy Strike', camp: 'atk', tk: 'foe', power: 3.0, rank: 1.4, isCharge: true });
  const out = {};

  // bonusPrice: 3 rarities x totals 0-3, for 'swift' (linear) and 'broad' (flat).
  out.bonusPrice = [];
  ['common', 'rare', 'legendary'].forEach(rarity => {
    for (let total = 0; total <= 3; total++) {
      out.bonusPrice.push({ rarity, bid: 'swift', total, price: C.bonusPrice({ rarity }, 'swift', total) });
    }
    out.bonusPrice.push({ rarity, bid: 'broad', price: C.bonusPrice({ rarity }, 'broad', 0) });
  });

  // bonusApplies: all 9 bonus ids x 5 representative action shapes.
  const SHAPES = {
    atkDamage: { power: 1.0, camp: 'atk', tk: 'foe' },
    heal: { power: 1.0, heal: true, tk: 'ally' },
    charge: { power: 2.0, isCharge: true, tk: 'foe' },
    appliesDebuff: { power: 1.0, applies: 'burning', tk: 'foe' },
    appliesBuff: { power: 0, applies: 'hasted', tk: 'self' }
  };
  const BONUS_IDS = ['swift', 'potent', 'lasting', 'deepening', 'surge', 'piercing', 'broad', 'cleansing', 'thrifty'];
  out.bonusApplies = {};
  Object.keys(SHAPES).forEach(shape => {
    out.bonusApplies[shape] = {};
    BONUS_IDS.forEach(bid => { out.bonusApplies[shape][bid] = C.bonusApplies(SHAPES[shape], bid); });
  });

  // actionBonusTotal
  out.actionBonusTotal = [
    C.actionBonusTotal({ swift: 2, piercing: 1 }),
    C.actionBonusTotal({ broad: 1 }),
    C.actionBonusTotal({ swift: 3, broad: 1, potent: 2 }),
    C.actionBonusTotal({})
  ];

  // bonusSpend
  out.bonusSpend = [
    C.bonusSpend({ strike: { swift: 2, piercing: 1 } }),
    C.bonusSpend({ strike: { swift: 2, piercing: 1 }, mend: { potent: 1, broad: 1 } }),
    C.bonusSpend({})
  ];

  // applyBonuses mutation correctness -- register, apply, read back, reset,
  // reapply differently (proves the reset-to-PRISTINE replay, not a
  // compounding mutation).
  C.applyBonuses({
    strike: { swift: 2, piercing: 3 },
    mend: { potent: 1, cleansing: 2 },
    heavystrike: { surge: 1, thrifty: 1 }
  });
  out.afterApply = {
    strikeRank: C.ACTIONS.strike.rank, strikeDefPierce: C.ACTIONS.strike.defPierce,
    mendPower: C.ACTIONS.mend.power, mendCleanse: C.ACTIONS.mend.cleanse,
    heavystrikeChargeCost: C.ACTIONS.heavystrike.chargeCost
  };
  C.applyBonuses({});
  out.afterReset = {
    strikeRank: C.ACTIONS.strike.rank, strikeDefPierce: C.ACTIONS.strike.defPierce,
    mendPower: C.ACTIONS.mend.power, mendCleanse: C.ACTIONS.mend.cleanse,
    heavystrikeChargeCost: C.ACTIONS.heavystrike.chargeCost
  };
  C.applyBonuses({ strike: { swift: 5 } });
  out.afterReapply = { strikeRank: C.ACTIONS.strike.rank, strikeDefPierce: C.ACTIONS.strike.defPierce };
  C.applyBonuses({});

  // Real battle proof (mirrors the existing farroadsmoke.js Piercing test):
  // a magic action with Piercing must deal MORE damage to a high-RES target
  // than the same action unpierced -- proves the bonus-adjusted number
  // actually changes combat, not just that a flag got set.
  function dmgAgainstHighRes(pierced) {
    C.applyBonuses(pierced ? { ember: { piercing: 2 } } : {});
    const src = C.makeUnit({ id: 's', name: 'Src', isParty: true, level: 1, slotIndex: 0,
      stats: { atk: 15, mag: 40, def: 15, res: 15, spd: 100 }, slots: [{ cond: 'none', action: 'ember' }] });
    const tgt = C.makeUnit({ id: 't', name: 'Tgt', isParty: false, level: 1, slotIndex: 10,
      stats: { atk: 10, mag: 10, def: 10, res: 80, spd: 90 }, maxHp: 100000, hp: 100000,
      slots: [{ cond: 'none', action: 'strike' }] });
    const b = C.makeBattle([src, tgt], { rng: C.makeRNG(1), deterministic: true });
    let e = null, guard = 0;
    while (!e && guard++ < 10) { const ev = C.step(b); if (ev && ev.actorId === 's' && ev.hits.length) e = ev; }
    C.applyBonuses({});
    return e ? e.hits[0].damage : null;
  }
  out.piercingProof = { unpierced: dmgAgainstHighRes(false), pierced: dmgAgainstHighRes(true) };

  console.log(JSON.stringify(out));
}

if (mode === 'content') {
  // NOTE: no registerTestActions() here -- C.ACTIONS/ARCH/ROSTER/EQUIPMENT
  // are already the genuine CSV-compiled tables (this is how core.js always
  // initializes), so this mode proves the export/load round-trip rather
  // than proving anything about hand-authored test content.
  const out = {};
  out.counts = {
    actions: Object.keys(C.ACTIONS).length,
    arch: Object.keys(C.ARCH).length,
    roster: C.ROSTER.length,
    equipment: Object.keys(C.EQUIPMENT).length
  };
  out.spotCheck = {
    strikePower: C.ACTIONS.strike.power,
    keshHp: C.ROSTER.find(r => r.id === 'kesh').hp,
    wolfAtk: C.ARCH.wolf.atk
  };

  // Real battle 1: Execute's crit-bonus dynamic (0.65 under 30% target HP,
  // else -1 -- effectively never crits until the target is nearly dead).
  C.setWave(1);
  out.executeProof = runBattle(2222, [
    C.makeUnit({ id: 'kesh', name: 'Kesh', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 430, atk: 26, mag: 18, def: 20, res: 16, spd: 100, atkCrit: 0.05, magCrit: 0.05 },
      affinity: { body: 3 }, slots: [{ cond: 'none', action: 'execute' }] }),
    C.makeUnit({ id: 'wolf', name: 'Roadwolf', isParty: false, level: 1, slotIndex: 10, arch: 'wolf', row: 'front',
      stats: { hp: 200, atk: 21, mag: 8, def: 12, res: 8, spd: 92, atkCrit: 0.04, magCrit: 0.04, evade: 0.05 },
      slots: [{ cond: 'none', action: 'strike' }] })
  ]);

  // Real battle 2: Vengeance's self-HP-scaled powerFn (0.55 at full HP,
  // ramping up to 2.10 near death) -- a low-HP party unit should hit
  // progressively harder as the fight goes on.
  out.vengeanceProof = runBattle(4444, [
    C.makeUnit({ id: 'kesh', name: 'Kesh', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 150, atk: 26, mag: 18, def: 12, res: 16, spd: 100, atkCrit: 0.05, magCrit: 0.05 },
      affinity: { body: 3 }, slots: [{ cond: 'none', action: 'vengeance' }] }),
    C.makeUnit({ id: 'wolf', name: 'Roadwolf', isParty: false, level: 1, slotIndex: 10, arch: 'wolf', row: 'front',
      stats: { hp: 260, atk: 14, mag: 8, def: 12, res: 8, spd: 88, atkCrit: 0.04, magCrit: 0.04, evade: 0.05 },
      slots: [{ cond: 'none', action: 'strike' }] })
  ]);

  console.log(JSON.stringify(out));
}
