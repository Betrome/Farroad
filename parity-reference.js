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
vm.runInContext(load('farroad-progression.js'), sandbox, { filename: 'farroad-progression.js' });
const P = sandbox.window.FarroadProgression;
vm.runInContext(load('farroad-save.js'), sandbox, { filename: 'farroad-save.js' });
const S = sandbox.window.FarroadSave;

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

  // Scenario G: enrage-every-turn catch-up -- a huge speed gap between two
  // enemies (Swift Hound acts many times, Lumbering Ox rarely) against a
  // weak attacker, high enemy HP/DEF so the fight runs well past
  // ENRAGE_AFTER=20 beats -- exercises the SHARED battle-level enrageN
  // counter (rising on the party's turns too, not just an enemy's) and the
  // rare-acting Ox's lump pow(1+ENRAGE_PCT, pending) catch-up specifically.
  out.G = runBattle(4242, [
    C.makeUnit({ id: 'p1', name: 'Skirmisher', isParty: true, level: 1, slotIndex: 0,
      stats: { hp: 260, atk: 14, mag: 4, def: 10, res: 10, spd: 100 },
      slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e1', name: 'Swift Hound', isParty: false, level: 1, slotIndex: 10, arch: 'hound', row: 'back',
      stats: { hp: 900, atk: 6, mag: 2, def: 18, res: 14, spd: 220 },
      slots: [{ cond: 'none', action: 'strike' }] }),
    C.makeUnit({ id: 'e2', name: 'Lumbering Ox', isParty: false, level: 1, slotIndex: 11, arch: 'ox', row: 'front',
      stats: { hp: 900, atk: 6, mag: 2, def: 18, res: 14, spd: 30 },
      slots: [{ cond: 'none', action: 'strike' }] })
  ], true);

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

  // 20-item batch, Group D: statByKey('avgAtkMag') -- the new stat-lookup
  // case the 2 new starter charge actions (wearingdown/ironresolve) rely
  // on. Direct comparison (not routed through full combat noise) against
  // a hand-built unit with distinct ATK/MAG values, proving it's a real
  // average and not an alias for either stat alone.
  const avgU = C.makeUnit({ id: 'avg', name: 'Avg', isParty: true, level: 1, slotIndex: 0,
    stats: { atk: 22, mag: 48, def: 15, res: 15, spd: 100 }, slots: [{ cond: 'none', action: 'strike' }] });
  out.avgAtkMag = {
    value: C.statByKey(avgU, 'avgAtkMag'),
    effAtk: C.effAtk(avgU), effMag: C.effMag(avgU)
  };

  // 20-item batch, Group F: the new caster-boost/target-resist debuff
  // formula (affBoostResist), and confirmation that BUFFS are unaffected
  // (still the original symmetric affBoost). Direct calls, not routed
  // through combat RNG -- a precise, deterministic comparison.
  function mkSpiritUnit(spirit) {
    const u = C.makeUnit({ id: 's', name: 'S', isParty: false, level: 1, slotIndex: 10,
      stats: { atk: 10, mag: 10, def: 10, res: 10, spd: 100 }, slots: [{ cond: 'none', action: 'strike' }] });
    u.affinity.spirit = spirit;
    return u;
  }
  const debuffLow = mkSpiritUnit(0);       // spirit-neutral target
  const debuffHigh = mkSpiritUnit(18);     // BOSS_SPIRIT_BONUS-equivalent target
  C.apply(debuffLow, 'enfeebled', 3, 0);   // neutral caster
  C.apply(debuffHigh, 'enfeebled', 3, 0);
  const buffLow = mkSpiritUnit(0);
  const buffHigh = mkSpiritUnit(18);
  C.apply(buffLow, 'bracing', 3, 0);
  C.apply(buffHigh, 'bracing', 3, 0);
  out.spiritResist = {
    debuffMagLowSpiritTarget: C.magOf(debuffLow, 'enfeebled'),
    debuffMagHighSpiritTarget: C.magOf(debuffHigh, 'enfeebled'),
    // A higher-spirit TARGET must now resist the debuff more (smaller
    // magnitude in absolute terms, since enfeebled's base is negative).
    debuffWeakerOnHighSpiritTarget: Math.abs(C.magOf(debuffHigh, 'enfeebled')) < Math.abs(C.magOf(debuffLow, 'enfeebled')),
    buffMagLowSpiritTarget: C.magOf(buffLow, 'bracing'),
    buffMagHighSpiritTarget: C.magOf(buffHigh, 'bracing'),
    // Buffs stay on the ORIGINAL symmetric formula -- a higher-spirit
    // target should still receive a STRONGER buff, the opposite direction
    // from the debuff case just above (regression-safe: this must NOT flip).
    buffStrongerOnHighSpiritTarget: Math.abs(C.magOf(buffHigh, 'bracing')) > Math.abs(C.magOf(buffLow, 'bracing')),
    directFormulaCheck: {
      affBoostResist_caster0_target18: C.affBoostResist(0, 18),
      affBoost_caster0_target18: C.affBoost(0, 18)
    }
  };

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

/* Step 3a: FarroadProgression.gd + the wave-loop orchestration functions
   (buildParty/buildEnemies/grantDrops/startWave/afterWaveCleared/onWipe --
   farroad-ui.js) that mirror this exactly. Those orchestration functions
   are UI-layer by file location (they call sysLog/pushDrop, which ARE
   DOM-bound) but the functions THEMSELVES never touch the DOM -- confirmed
   by reading their real bodies (Milestone 3 Step 3a research) -- so this
   hand-transcribes them minus every sysLog/pushDrop call, the exact same
   "faithful but DOM-free mirror" approach 'battle' mode's runBattle/
   TEST_ACTIONS above already established, not a new technique. */
if (mode === 'progression') {
  function recoveryOf(g, uid) { return Math.min(P.REST_CAP, P.REST + P.REST_STEP * ((g.recovery && g.recovery[uid]) || 0)); }
  function levelOf(g, uid) { return (g.lvl && g.lvl[uid]) || 1; }
  function ratchetR(g) { return g.maxLevelEver || 1; }
  function rarityCostMul(uid) {
    var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
    return C.RARITY_COST_MUL[(def && def.rarity) || 'common'] || 1;
  }
  function affinityBaseline(uid) {
    var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
    return (def && def.affinity) || {};
  }
  var AFFINITY_AXES = ['fire', 'water', 'earth', 'air', 'light', 'dark', 'body', 'spirit'];
  function affinityPurchased(g, uid) { return (g.affinities && g.affinities[uid]) || {}; }
  function equipmentAffinity(g, uid) {
    var out = {}, equipped = (g.equipped && g.equipped[uid]) || {};
    AFFINITY_AXES.forEach(function (ax) { out[ax] = 0; });
    C.EQUIPMENT_SLOTS.forEach(function (slot) {
      var id = equipped[slot], item = id && C.EQUIPMENT[id];
      if (item) AFFINITY_AXES.forEach(function (ax) { out[ax] += item.affinity[ax] || 0; });
    });
    return out;
  }
  function effectiveAffinity(g, uid) {
    var base = affinityBaseline(uid), purchased = affinityPurchased(g, uid), equip = equipmentAffinity(g, uid), out = {};
    AFFINITY_AXES.forEach(function (ax) { out[ax] = (base[ax] || 0) + (purchased[ax] || 0) + equip[ax]; });
    return out;
  }
  var PCT_STAT_KEYS = ['evade', 'atkCrit', 'magCrit'];
  function pctStatBaseline(uid, stat) {
    var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
    return (def && def.stats && def.stats[stat]) || 0;
  }
  function pctStatPurchased(g, uid, stat) { return ((g.statInvest && g.statInvest[uid] && g.statInvest[uid][stat]) || 0); }
  function applyPctStatInvestment(g, uid, st) {
    PCT_STAT_KEYS.forEach(function (stat) { st[stat] = P.pctStatValue(pctStatBaseline(uid, stat), stat, pctStatPurchased(g, uid, stat)); });
    return st;
  }
  function applyEquipmentStats(g, uid, st) {
    var equipped = (g.equipped && g.equipped[uid]) || {}, spdPenalty = 0;
    C.EQUIPMENT_SLOTS.forEach(function (slot) {
      var id = equipped[slot], item = id && C.EQUIPMENT[id];
      if (!item) return;
      ['atk', 'mag', 'def', 'res', 'spd'].forEach(function (k) { if (item[k]) st[k] += item[k]; });
      if (item.evade) st.evade += item.evade;
      if (slot !== 'legs') spdPenalty += C.EQUIP_SPD_PENALTY_BASE * (C.RARITY_POWER_MUL[item.rarity] || 1);
    });
    if (spdPenalty) st.spd = Math.round(st.spd - spdPenalty);
    return st;
  }
  function ensureLoadout(g, uid) {
    var want = P.slotsAt(levelOf(g, uid));
    if (!g.loadout[uid]) g.loadout[uid] = [{ cond: 'none', action: 'strike' }, { cond: 'none', action: 'strike' }];
    while (g.loadout[uid].length < want) g.loadout[uid].push({ cond: 'none', action: 'strike' });
    if (g.loadout[uid].length > want) g.loadout[uid] = g.loadout[uid].slice(0, want);
    g.loadout[uid].forEach(function (s) {
      if (g.actions.indexOf(s.action) < 0) s.action = 'strike';
      if (g.conditions.indexOf(s.cond) < 0) s.cond = 'none';
    });
    return g.loadout[uid];
  }
  var GATE_FOR = {
    foe_lacks_debuff: ['sear', 'hex', 'cripple', 'smother', 'daunt'], foe_armoured: ['pierce', 'hex', 'ember'],
    ally_lacks_buff: ['bulwark'], self_hp_lte_50: ['mend', 'bulwark'], foe_fast: ['cripple', 'daunt'],
    ally_hp_lte_60: ['mend'], foe_lowest_hp: ['execute', 'strike'], foe_highest_hp: ['gale', 'cleave', 'daunt'],
    foe_hp_gte_70: ['gale', 'cleave', 'sear', 'hex']
  };
  var PRI = ['self_hp_lte_50', 'ally_hp_lte_60', 'ally_lacks_buff', 'foe_fast', 'foe_lacks_debuff',
    'foe_armoured', 'foe_highest_hp', 'foe_hp_gte_70', 'foe_lowest_hp'];
  function autoEquip(g) {
    g.party.forEach(function (uid) {
      if (g.touched && g.touched[uid]) return;
      var s1 = null;
      for (var i = 0; i < PRI.length && !s1; i++) {
        var cd = PRI[i];
        if (g.conditions.indexOf(cd) < 0) continue;
        var a = (GATE_FOR[cd] || []).filter(function (x) { return g.actions.indexOf(x) >= 0; })[0];
        if (a) s1 = { cond: cd, action: a };
      }
      g.loadout[uid] = s1 ? [s1, { cond: 'none', action: 'strike' }] : [{ cond: 'none', action: 'strike' }, { cond: 'none', action: 'strike' }];
    });
  }
  function buildParty(g) {
    var out = [];
    g.party.forEach(function (uid, i) {
      var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
      var st = P.statsAt(uid, def.stats, def.hp, levelOf(g, uid));
      applyPctStatInvestment(g, uid, st);
      applyEquipmentStats(g, uid, st);
      var mh = st.hp;
      var carry = g.hpCarry[uid];
      if (carry != null) carry = Math.min(1, carry + recoveryOf(g, uid));
      var hp = (carry == null) ? mh : Math.max(1, Math.round(mh * carry));
      out.push(C.makeUnit({
        id: uid, name: def.name, isParty: true, level: 1, slotIndex: i, stats: st,
        maxHp: mh, hp: Math.min(hp, mh), row: def.row, chargeAction: def.chargeAction,
        charge: g.chargeCarry[uid] || 0,
        affinity: effectiveAffinity(g, uid),
        slots: ensureLoadout(g, uid).map(function (s) { return { cond: s.cond, action: s.action }; })
      }));
    });
    return out;
  }
  function buildEnemies(g, w, superBossKey) {
    var boss = P.isBossWave(w) || !!superBossKey;
    var variety = (!boss && w > P.VARIETY_FROM);
    var n = boss ? 1 : (variety ? P.rollCount(g.rng, w) : P.enemyCount(w));
    var countMul = w >= P.UNIT_WAVES[0] ? P.countStrength(n) : 1;
    var vMul = variety ? (countMul * P.bandRoll(g.rng)) : countMul;
    C.setWave(w);
    var S = C.waveScale(w), out = [];
    var isFirstBoss = boss && w === P.BOSS_WAVES[0];
    var priestUsed = false;   // 1 healer max per wave -- mirrors buildEnemies (farroad-ui.js)
    for (var j = 0; j < n; j++) {
      var key = boss ? 'ox' : P.archetypeFor(w, j);
      if (key === 'priest') {
        if (priestUsed) key = 'wolf';
        else priestUsed = true;
      }
      var a = C.ARCH[key];
      var hpBase;
      if (boss) {
        var ref = C.ARCH.wolf;
        var lenMul = superBossKey ? P.SUPERBOSS_LEN : (isFirstBoss ? P.FIRST_BOSS_LEN : P.BOSS_LEN);
        hpBase = 200 * ref.hpMul * C.dmgTakenMul(ref) * S * Math.max(1, P.enemyCount(w)) * lenMul;
      } else hpBase = 200 * a.hpMul * C.dmgTakenMul(a) * S;
      hpBase *= P.DIFFICULTY * vMul * Math.sqrt(P.hardMul(w));
      var hardAtkMul = P.hardMul(w) * (boss ? (isFirstBoss ? P.FIRST_BOSS_HARD_EXTRA : P.BOSS_HARD_EXTRA) : 1);
      var atkMul = (boss ? 1.10 : 1) * P.DIFFICULTY * vMul * hardAtkMul;
      var dmgMul = (isFirstBoss ? P.FIRST_BOSS_DMG_MUL : 1) * (w <= 20 ? P.TUTORIAL_ATK_MAG_MUL : 1);
      out.push(C.makeUnit({
        id: 'e' + j, name: (boss ? 'ROADWARDEN' : a.name) + (n > 1 ? ' ' + (j + 1) : ''),
        isParty: false, level: 1, slotIndex: 10 + j, arch: key, thorns: a.thorns || 0, isBoss: boss,
        row: j < 5 ? 'front' : 'back',
        stats: {
          hp: Math.max(8, Math.round(hpBase)), atk: Math.max(1, Math.round(a.atk * S * atkMul * dmgMul)),
          mag: Math.round((a.mag || 8) * S * P.DIFFICULTY * hardAtkMul * dmgMul),
          def: Math.round(a.def * S), res: Math.round(a.res * S),
          spd: boss ? Math.round(a.spd * P.bossSpdMul(w)) : a.spd,
          atkCrit: Math.min(C.CAP_CRIT, a.atkCrit * Math.sqrt(S)),
          magCrit: Math.min(C.CAP_CRIT, (a.magCrit || 0.04) * Math.sqrt(S)),
          chargeRate: (boss ? 1.15 : 1), evade: a.evade
        },
        chargeAction: (boss ? 'wardensmaul' : (a.chargeAction || null)), affinity: a.affinity,
        slots: a.slots.map(function (s) { return { cond: s.cond, action: s.action }; })
      }));
    }
    return out;
  }
  function randomDrop(g, w) {
    if (w % 2 !== 0 && w % 2 !== 1) return [];
    if (g.mc && g.rng.next() < P.MC_CHARGE_DROP_CHANCE) {
      var chargePool = P.MC_CHARGE_DROP_POOL;
      var legendaryPool = chargePool.filter(function (id) { return C.ACTIONS[id] && C.ACTIONS[id].rarity === 'legendary'; });
      var rarePool = chargePool.filter(function (id) { return !(C.ACTIONS[id] && C.ACTIONS[id].rarity === 'legendary'); });
      var wantLegendary = legendaryPool.length > 0 && g.rng.next() < P.MC_LEGENDARY_CHARGE_CHANCE;
      var pool = (wantLegendary ? legendaryPool : rarePool);
      if (pool.length === 0) pool = chargePool;
      return [{ kind: 'charge', id: pool[g.rng.nextInt(pool.length)], why: (wantLegendary ? 'legendary' : 'rare') + ' charge-action drop' }];
    }
    if (g.rng.next() < P.EQUIP_DROP_CHANCE) {
      var equipIds = Object.keys(C.EQUIPMENT);
      return [{ kind: 'equip', id: P.weightedEquipmentPick(g.rng, equipIds), why: 'equipment drop' }];
    }
    var out = [];
    if (w % 2 === 0) { var pool2 = C.EQUIPPABLE; out.push({ kind: 'action', id: P.weightedActionPick(g.rng, pool2), why: 'random drop' }); }
    else { var cp = C.CONDITIONS.filter(function (c) { return c.id !== 'none'; }); out.push({ kind: 'cond', id: cp[g.rng.nextInt(cp.length)].id, why: 'random drop' }); }
    return out;
  }
  function grantDrops(g, w) {
    if (g.dropsGranted[w]) return [{ kind: 'already_attempted', wave: w }];
    g.dropsGranted[w] = 1;
    var curated = P.isCurated(w);
    var drops = curated ? P.dropsAt(w) : randomDrop(g, w);
    var events = [];
    drops.forEach(function (d) {
      if (d.kind === 'action') {
        g.actionCounts[d.id] = (g.actionCounts[d.id] || 0) + 1;
        var dup = g.actions.indexOf(d.id) >= 0;
        if (!dup) g.actions.push(d.id); else creditLoreG(g, d.id);
        events.push({ kind: 'action', id: d.id, wave: w, duplicate: dup, why: curated ? (d.why || null) : null });
      } else if (d.kind === 'charge') {
        g.mc.acquiredCharges = g.mc.acquiredCharges || [];
        var dupC = g.mc.acquiredCharges.indexOf(d.id) >= 0;
        if (!dupC) g.mc.acquiredCharges.push(d.id); else creditLoreG(g, d.id);
        events.push({ kind: 'charge', id: d.id, wave: w, duplicate: dupC });
      } else if (d.kind === 'equip') {
        g.equipInv = g.equipInv || {};
        g.equipInv[d.id] = (g.equipInv[d.id] || 0) + 1;
        events.push({ kind: 'equip', id: d.id, wave: w, ownedCount: g.equipInv[d.id], why: curated ? (d.why || null) : null });
      } else {
        g.condCounts[d.id] = (g.condCounts[d.id] || 0) + 1;
        var dup2 = g.conditions.indexOf(d.id) >= 0;
        if (!dup2) g.conditions.push(d.id); else creditRandomLoreG(g);
        events.push({ kind: 'cond', id: d.id, wave: w, duplicate: dup2, why: curated ? (d.why || null) : null });
      }
    });
    if (drops.length) autoEquip(g);
    return events;
  }
  function joinCompanion(g, uid) {
    if (!g.owned[uid]) g.quests[uid] = { stage: 0, frozen: [] };
    g.lvl[uid] = 1; g.bank[uid] = 0; g.owned[uid] = 1;
    g.affinities = g.affinities || {}; if (!g.affinities[uid]) g.affinities[uid] = {};
    g.statInvest = g.statInvest || {}; if (!g.statInvest[uid]) g.statInvest[uid] = {};
    g.equipped = g.equipped || {}; if (!g.equipped[uid]) g.equipped[uid] = {};
    var fielded = g.party.length < P.PARTY_CAP;
    if (fielded) g.party.push(uid);
    return fielded;
  }
  function startWave(g, w, skipDrops) {
    g.wave = w; if (w > g.farthest) g.farthest = w;
    var events = skipDrops ? [] : grantDrops(g, w);
    C.applyBonuses(g.bonuses);
    var party = buildParty(g), enemies = buildEnemies(g, w);
    g.units = party; g.enemies = enemies;
    g.battle = C.makeBattle(party.concat(enemies), { rng: g.rng, enrage: g.enrage });
    g.over = null;
    return events;
  }
  function afterWaveCleared(g) {
    var events = [];
    var firstClear = !g.clearedWaves[g.wave];
    g.clearedWaves[g.wave] = 1;
    g.units.forEach(function (u) { g.hpCarry[u.id] = u.hp / u.maxHp; g.chargeCarry[u.id] = u.charge; });
    var r = P.killReward(g.wave, g.enemies.length);
    var aetherMul = (g.wave <= P.TUTORIAL_AETHER_WAVES) ? P.TUTORIAL_AETHER_MUL : 1;
    g.aether += r.aether * aetherMul; g.marks += r.marks * P.marksMul(g);
    if (P.isBossWave(g.wave) && firstClear) {
      g.bossesCleared++;
      var hoard = P.bossAether(g.wave) * aetherMul;
      g.aether += hoard;
      events.push({ kind: 'boss_hoard', wave: g.wave, amount: hoard });
      var next = P.unitDueAt(g.wave);
      if (next && g.party.indexOf(next) >= 0) next = null;
      if (!next) {
        var dup = P.dupUnitAether(g.wave); g.aether += dup;
        events.push({ kind: 'boss_no_companion', wave: g.wave, amount: dup });
      } else if (g.party.length < 5) {
        joinCompanion(g, next);
        events.push({ kind: 'boss_companion', wave: g.wave, id: next });
      }
      events.push({ kind: 'checkpoint', wave: g.bossesCleared * P.BOSS_EVERY });
    }
    if (P.isBossWave(g.wave) && g.rng.next() < 0.10) {
      var bossAvail = C.ROSTER.filter(function (r) { return !g.owned[r.id]; });
      if (bossAvail.length) {
        var bossPick = bossAvail[g.rng.nextInt(bossAvail.length)];
        var bossFielded = joinCompanion(g, bossPick.id);
        events.push({ kind: 'boss_companion_roll', wave: g.wave, id: bossPick.id, fielded: bossFielded });
      }
    }
    return events;
  }
  function onWipe(g) {
    g.wipes++;
    var back = P.checkpoint(g.bossesCleared, g.farthest);
    g.hpCarry = {};
    g.chargeCarry = {};
    var events = [{ kind: 'wipe', backTo: back }];
    events = events.concat(startWave(g, back));
    return events;
  }
  function newDirectionsG() {
    var d = {};
    Object.keys(P.DIRECTION_CONFIG).forEach(function (dir) { d[dir] = { maxDepth: 0, dungeonsUnlocked: 0 }; });
    return d;
  }
  function newGame(seed, mc) {
    return {
      seed: seed || 7, rng: C.makeRNG(seed || 7), wave: 0, farthest: 1, bossesCleared: 0,
      aether: 0, loreByAction: {}, marks: 0, wipes: 0,
      party: ['kesh'], actions: P.STARTER_ACTIONS.slice(), conditions: ['none'],
      actionCounts: {}, condCounts: {}, bonuses: {}, recovery: {}, loadout: {}, hpCarry: {}, chargeCarry: {}, touched: {},
      clearedWaves: {}, dropsGranted: {},
      lvl: { kesh: 1 }, bank: { kesh: 0 }, maxLevelEver: 1, owned: { kesh: 1 },
      affinities: { kesh: {} }, statInvest: { kesh: {} }, equipInv: {}, equipped: { kesh: {} },
      battle: null, units: null, enemies: null, over: null, enrage: true, idleAcc: 0,
      mc: mc || null, expeditions: [], pullsSinceUnit: 0,
      dungeons: [], quests: { kesh: { stage: 0, frozen: [] } },
      superBossQuests: [], superBossesUnlocked: 0, superBossesCleared: {},
      directions: newDirectionsG()
    };
  }

  var out = {};

  // Direct math spot-checks across a wide wave range -- pure functions,
  // no RNG involved, so these must match exactly with no seed dependency.
  var waves = [1, 5, 20, 21, 40, 41, 100, 101, 227, 500, 800, 1000, 3000];
  out.math = waves.map(function (w) {
    return {
      w: w, isBoss: P.isBossWave(w), nextBoss: P.nextBossWave(w), hardMul: P.hardMul(w),
      bossSpdMul: P.bossSpdMul(w), killReward: P.killReward(w, 3), bossAether: P.bossAether(w),
      dupUnitAether: P.dupUnitAether(w), idlePerSec: P.idlePerSec(w), enemyCount: P.enemyCount(w)
    };
  });
  out.checkpoints = [0, 1, 2, 3, 5].map(function (n) { return P.checkpoint(n); });
  // Tutorial checkpoints (bossesCleared===0): farthest snaps DOWN to the
  // nearest 5-wave boundary (1/6/11/16), not always a flat 1. bossesCleared>0
  // still ignores farthest entirely -- confirmed via the last two entries.
  out.tutorialCheckpoints = [1, 4, 5, 6, 7, 10, 11, 15, 16, 19].map(function (f) {
    return { farthest: f, checkpoint: P.checkpoint(0, f) };
  });
  out.tutorialCheckpoints.push({ bossesCleared: 1, farthest: 999, checkpoint: P.checkpoint(1, 999) });
  out.tutorialCheckpoints.push({ bossesCleared: 1, farthest: 1, checkpoint: P.checkpoint(1, 1) });
  out.slots = [1, 9, 10, 99, 100, 499, 500, 999, 1000, 1500].map(function (l) { return { l: l, slots: P.slotsAt(l), next: P.nextSlotAt(l) }; });
  out.leveling = [[1, 1], [10, 1], [10, 50], [100, 100], [1000, 1000]].map(function (p) {
    return { l: p[0], r: p[1], cost: P.costToNext(p[0], p[1]) };
  });

  // Full simulated playthrough -- the real integration test. Same win/lose
  // loop the Godot debug run used: exercises buildParty/buildEnemies (via
  // C.makeBattle/C.step, already proven bit-exact) and every RNG-consuming
  // path (rollCount/bandRoll past wave 40, grantDrops/randomDrop past wave
  // 20) in the exact call order a real game would hit them.
  var g = newGame(7, null);
  startWave(g, 1);
  var trace = [];
  for (var i = 0; i < 60; i++) {
    var guard = 0;
    while (!g.battle.over && guard++ < 1000) { var e = C.step(g.battle); if (!e) break; }
    var w = g.wave;
    var entry = { wave: w, outcome: g.battle.over };
    if (g.battle.over === 'party') {
      entry.events = afterWaveCleared(g);
      entry.aether = g.aether; entry.marks = g.marks; entry.loreByAction = g.loreByAction;
      entry.party = g.party.slice(); entry.actions = g.actions.slice(); entry.conditions = g.conditions.slice();
      trace.push(entry);
      startWave(g, w + 1);
    } else {
      entry.events = onWipe(g);
      entry.aether = g.aether; entry.marks = g.marks; entry.loreByAction = g.loreByAction;
      trace.push(entry);
    }
  }
  out.trace = trace;

  // Step 3c: GAMBITS -- loadout sync + party bench/field, hand-transcribed
  // from the real farroad-ui.js the same way every orchestration function
  // above already was.
  function syncLoadout(gg, uid) {
    if (!gg.units) return;
    gg.units.forEach(function (u) { if (u.id === uid) u.slots = gg.loadout[uid].map(function (s) { return { cond: s.cond, action: s.action }; }); });
  }
  function benchUnit(gg, uid) {
    if (gg.party.length <= 1) return false;
    var i = gg.party.indexOf(uid);
    if (i < 0) return false;
    gg.party.splice(i, 1);
    return true;
  }
  function fieldUnit(gg, uid) {
    if (!gg.owned[uid]) return false;
    if (gg.party.indexOf(uid) >= 0) return false;
    if (gg.party.length >= P.PARTY_CAP) return false;
    gg.party.push(uid);
    autoEquip(gg);
    return true;
  }
  function availableForParty(gg) {
    return Object.keys(gg.owned).filter(function (uid) { return gg.party.indexOf(uid) < 0; });
  }
  function actionHolderInParty(gg, aid, excludeUid) {
    if (P.STARTER_ACTIONS.indexOf(aid) >= 0) return null;
    var holder = null;
    gg.party.forEach(function (uid) {
      if (uid === excludeUid || holder) return;
      var sl = gg.loadout[uid]; if (!sl) return;
      sl.forEach(function (s) {
        if (s.action === aid) {
          var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
          holder = def ? def.name : uid;
        }
      });
    });
    return holder;
  }

  var g2 = newGame(7, null);
  startWave(g2, 1);
  joinCompanion(g2, 'ansa');
  g2.actions.push('sear');
  g2.loadout.kesh = [{ cond: 'none', action: 'sear' }, { cond: 'none', action: 'strike' }];
  syncLoadout(g2, 'kesh');
  out.gambits = {
    keshLiveSlot0: g2.units[0].slots[0],
    holderExcludeNone: actionHolderInParty(g2, 'sear', ''),
    holderExcludeAnsa: actionHolderInParty(g2, 'sear', 'ansa'),
    holderExcludeKesh: actionHolderInParty(g2, 'sear', 'kesh'),
    holderStarter: actionHolderInParty(g2, 'strike', ''),
    availableFielded: availableForParty(g2)
  };
  out.gambits.benchAnsa = benchUnit(g2, 'ansa');
  out.gambits.partyAfterBench = g2.party.slice();
  out.gambits.availableBenched = availableForParty(g2);
  out.gambits.benchKeshRefused = benchUnit(g2, 'kesh');
  out.gambits.partyAfterRefusedBench = g2.party.slice();
  out.gambits.fieldAnsa = fieldUnit(g2, 'ansa');
  out.gambits.partyAfterField = g2.party.slice();
  out.gambits.fieldUnowned = fieldUnit(g2, 'vey');

  // Step 3d: AETHER -- leveling + Recovery + Evade/Crit + Affinity
  // purchases, hand-transcribed from the real 4 purchase handlers
  // (farroad-ui.js:1899-1938) the same way everything else above was.
  function levelOfG(gg, uid) { return (gg.lvl && gg.lvl[uid]) || 1; }
  function ratchetRG(gg) { return gg.maxLevelEver || 1; }
  function rarityCostMulG(uid) {
    var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
    return C.RARITY_COST_MUL[(def && def.rarity) || 'common'] || 1;
  }
  function costNextG(gg, uid) { return Math.round(P.costToNext(levelOfG(gg, uid), ratchetRG(gg)) * rarityCostMulG(uid)); }
  function feedUnitG(gg, uid, amount) {
    gg.bank = gg.bank || {}; gg.lvl = gg.lvl || {};
    gg.bank[uid] = (gg.bank[uid] || 0) + amount;
    var guard = 0, mul = rarityCostMulG(uid);
    while (guard++ < 100000) {
      var c = Math.round(P.costToNext(levelOfG(gg, uid), ratchetRG(gg)) * mul);
      if (gg.bank[uid] < c) break;
      gg.bank[uid] -= c; gg.lvl[uid] = levelOfG(gg, uid) + 1;
      if (gg.lvl[uid] > (gg.maxLevelEver || 1)) gg.maxLevelEver = gg.lvl[uid];
    }
  }
  function recoveryOfG(gg, uid) {
    var steps = (gg.recovery && gg.recovery[uid]) || 0;
    return Math.min(P.REST_CAP, P.REST + P.REST_STEP * steps);
  }
  function recoveryCostG(gg, uid) { return Math.round(10 * Math.pow(1.45, (gg.recovery && gg.recovery[uid]) || 0)); }
  function recoveryMaxedG(gg, uid) { return recoveryOfG(gg, uid) >= P.REST_CAP - 1e-9; }
  function affinityBaselineG(uid) {
    var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
    return (def && def.affinity) || {};
  }
  function affinityPurchasedG(gg, uid) { return (gg.affinities && gg.affinities[uid]) || {}; }
  function affinityRawG(gg, uid, axis) { return (affinityBaselineG(uid)[axis] || 0) + (affinityPurchasedG(gg, uid)[axis] || 0); }
  function affinityMaxedG(gg, uid, axis) { return affinityRawG(gg, uid, axis) >= C.AFFINITY_CAP; }
  function pctStatBaselineG(uid, stat) {
    var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
    return (def && def.stats && def.stats[stat]) || 0;
  }
  function pctStatPurchasedG(gg, uid, stat) { return ((gg.statInvest && gg.statInvest[uid] && gg.statInvest[uid][stat]) || 0); }
  function spendFeed(gg, uid, amount) {
    if (gg.aether < amount) return false;
    gg.aether -= amount; feedUnitG(gg, uid, amount); return true;
  }
  function spendRecovery(gg, uid) {
    var c = recoveryCostG(gg, uid);
    if (gg.aether < c || recoveryMaxedG(gg, uid)) return false;
    gg.aether -= c; gg.recovery = gg.recovery || {}; gg.recovery[uid] = (gg.recovery[uid] || 0) + 1;
    return true;
  }
  function spendAffinity(gg, uid, axis) {
    var c = P.affinityCostToNext(affinityPurchasedG(gg, uid)[axis] || 0);
    if (gg.aether < c || affinityMaxedG(gg, uid, axis)) return false;
    gg.aether -= c; gg.affinities = gg.affinities || {}; gg.affinities[uid] = gg.affinities[uid] || {};
    gg.affinities[uid][axis] = (gg.affinities[uid][axis] || 0) + 1;
    return true;
  }
  function spendPctStat(gg, uid, stat) {
    var c = P.pctStatCost(stat, pctStatPurchasedG(gg, uid, stat));
    if (gg.aether < c || P.pctStatMaxed(pctStatBaselineG(uid, stat), stat, pctStatPurchasedG(gg, uid, stat))) return false;
    gg.aether -= c; gg.statInvest = gg.statInvest || {}; gg.statInvest[uid] = gg.statInvest[uid] || {};
    gg.statInvest[uid][stat] = (gg.statInvest[uid][stat] || 0) + 1;
    return true;
  }

  var g3 = newGame(7, null);
  startWave(g3, 1);
  g3.aether = 100000;
  var aether3 = { costNextL1: costNextG(g3, 'kesh') };
  aether3.feed250 = spendFeed(g3, 'kesh', 250);
  aether3.levelAfterFeed = levelOfG(g3, 'kesh');
  aether3.aetherAfterFeed = g3.aether;
  aether3.recoveryBefore = recoveryOfG(g3, 'kesh');
  spendRecovery(g3, 'kesh');
  aether3.recoveryAfter = recoveryOfG(g3, 'kesh');
  aether3.fireBefore = affinityRawG(g3, 'kesh', 'fire');
  spendAffinity(g3, 'kesh', 'fire');
  aether3.fireAfter = affinityRawG(g3, 'kesh', 'fire');
  aether3.evadeBefore = P.pctStatValue(pctStatBaselineG('kesh', 'evade'), 'evade', pctStatPurchasedG(g3, 'kesh', 'evade'));
  spendPctStat(g3, 'kesh', 'evade');
  aether3.evadeAfter = P.pctStatValue(pctStatBaselineG('kesh', 'evade'), 'evade', pctStatPurchasedG(g3, 'kesh', 'evade'));
  g3.aether = 0;
  var aetherBefore3 = g3.aether;
  aether3.refusedFeed = spendFeed(g3, 'kesh', 50);
  aether3.aetherUnchanged = (g3.aether === aetherBefore3);
  out.aether = aether3;

  // Step 3e: LORE -- bonus purchase/remove/refund, hand-transcribed from
  // the real renderLore() and its supporting functions
  // (farroad-ui.js:1995-2220) the same way everything else above was.
  function usedActionsG(gg) {
    var used = {};
    Object.keys(gg.owned).forEach(function (uid) {
      (gg.loadout[uid] || []).forEach(function (s) { used[s.action] = 1; });
      var rd = null; C.ROSTER.forEach(function (r) { if (r.id === uid) rd = r; });
      if (rd && rd.chargeAction) used[rd.chargeAction] = 1;
    });
    return used;
  }
  function actionHoldersG(gg, aid) {
    var active = [], banked = false;
    Object.keys(gg.owned).forEach(function (uid) {
      var holds = false;
      (gg.loadout[uid] || []).forEach(function (s) { if (s.action === aid) holds = true; });
      var rd = null; C.ROSTER.forEach(function (r) { if (r.id === uid) rd = r; });
      var ca = rd && rd.chargeAction;
      if (ca === aid) holds = true;
      if (holds) active.push(rd ? rd.name : uid);
    });
    return { active: active, banked: banked };
  }
  function unitActiveActionsG(gg, uid) {
    var ids = [];
    (gg.loadout[uid] || []).forEach(function (s) { if (ids.indexOf(s.action) < 0) ids.push(s.action); });
    var rd = null; C.ROSTER.forEach(function (r) { if (r.id === uid) rd = r; });
    var ca = rd && rd.chargeAction;
    if (ca && ids.indexOf(ca) < 0) ids.push(ca);
    return ids;
  }
  function loreActionIdsG(gg) {
    var ids = gg.actions.slice();
    Object.keys(usedActionsG(gg)).forEach(function (id) {
      if (ids.indexOf(id) < 0 && C.ACTIONS[id] && C.ACTIONS[id].isCharge) ids.push(id);
    });
    return ids;
  }
  // v2.13: Lore became per-action (gg.loreByAction[aid], replacing the
  // single global gg.lore) and bonusSpend/bonusPrice lost their rarity
  // multiplier AND triangular per-stack scaling -- a non-broad stack is
  // now a flat 1 Lore regardless of rarity or how many are already owned.
  function freeLoreG(gg, aid) {
    return Math.max(0, (gg.loreByAction[aid] || 0) - C.bonusSpend({ x: gg.bonuses[aid] || {} }));
  }
  function creditLoreG(gg, aid) { gg.loreByAction[aid] = (gg.loreByAction[aid] || 0) + 1; }
  function loreActionIdsGForCredit(gg) { return loreActionIdsG(gg); }
  function creditRandomLoreG(gg) {
    var ids = loreActionIdsGForCredit(gg);
    if (!ids.length) return;
    creditLoreG(gg, ids[gg.rng.nextInt(ids.length)]);
  }
  function unusedLoreRefundG(gg) {
    var used = usedActionsG(gg);
    var unusedIds = Object.keys(gg.bonuses).filter(function (aid) {
      return !used[aid] && gg.bonuses[aid] && Object.keys(gg.bonuses[aid]).length;
    });
    var total = 0;
    unusedIds.forEach(function (aid) {
      total += C.bonusSpend({ x: gg.bonuses[aid] });
    });
    return { ids: unusedIds, total: total };
  }
  function claimLoreRefundG(gg, ids) {
    ids.forEach(function (aid) { delete gg.bonuses[aid]; });
    C.applyBonuses(gg.bonuses);
  }
  function buyBonusG(gg, aid, bid) {
    gg.bonuses[aid] = gg.bonuses[aid] || {};
    gg.bonuses[aid][bid] = (gg.bonuses[aid][bid] || 0) + 1;
    C.applyBonuses(gg.bonuses);
  }
  function removeBonusG(gg, aid, bid) {
    if (!gg.bonuses[aid]) return;
    gg.bonuses[aid][bid] = Math.max(0, (gg.bonuses[aid][bid] || 0) - 1);
    if (!gg.bonuses[aid][bid]) delete gg.bonuses[aid][bid];
    C.applyBonuses(gg.bonuses);
  }

  var g4 = newGame(7, null);
  startWave(g4, 1);
  // Deterministic loadout regardless of whatever the default happens to be
  // -- both slots on 'strike', so 'strike' is unambiguously "used" while
  // 'ember' (a starter action, never equipped) stays genuinely unused.
  g4.loadout.kesh = [{ cond: 'none', action: 'strike' }, { cond: 'none', action: 'strike' }];
  // v2.13: each action gets its OWN Lore pool now -- strike/oath/ember each
  // seeded separately (was a single flat g.lore=100 before).
  g4.loreByAction = { strike: 100, oath: 100, ember: 100 };
  var lore4 = {};
  // Kesh's own chargeAction ('oath') is never in g.actions (a fixed roster
  // property, not a drop/pull unlock) -- this is exactly the case
  // lore_action_ids exists to cover.
  lore4.actionIdsFresh = loreActionIdsG(g4);
  lore4.usedFresh = usedActionsG(g4);
  lore4.holdersOathBefore = actionHoldersG(g4, 'oath');
  lore4.activeKesh = unitActiveActionsG(g4, 'kesh');
  lore4.freeLoreFreshStrike = freeLoreG(g4, 'strike');
  buyBonusG(g4, 'strike', 'swift');
  buyBonusG(g4, 'strike', 'swift');
  buyBonusG(g4, 'oath', 'potent');
  buyBonusG(g4, 'ember', 'swift');
  // Object.assign snapshots -- g4.bonuses.strike is a live reference, and a
  // later removeBonusG call mutates that SAME object, so capturing it
  // without copying would silently show the post-remove value here too.
  lore4.strikeBonuses = Object.assign({}, g4.bonuses.strike);
  lore4.oathBonuses = Object.assign({}, g4.bonuses.oath);
  // v2.13: flat 1-Lore-per-stack, no triangular scaling -- 2 swift stacks on
  // strike costs exactly 2 Lore now (was 1+2=3 under the old formula), and
  // buying on 'oath'/'ember' must NOT touch strike's own pool (each action's
  // pool is now genuinely independent).
  lore4.freeLoreAfterBuysStrike = freeLoreG(g4, 'strike');
  lore4.freeLoreAfterBuysOath = freeLoreG(g4, 'oath');
  lore4.freeLoreAfterBuysEmber = freeLoreG(g4, 'ember');
  // 'swift' modifies rank (initiative), not power -- confirms applyBonuses
  // (called inside buyBonusG, same as the real handler) actually took
  // effect on the live ACTIONS table, not just the bonuses map.
  lore4.strikeRankPristine = C.pristineOf('strike').rank;
  lore4.strikeRankAfter = C.ACTIONS['strike'].rank;
  removeBonusG(g4, 'strike', 'swift');
  lore4.strikeBonusesAfterRemove = Object.assign({}, g4.bonuses.strike);
  lore4.freeLoreAfterRemoveStrike = freeLoreG(g4, 'strike');
  // 'strike'/'oath' are both "used" (equipped/live chargeAction) so neither
  // is refundable despite real bonus stacks -- only 'ember' (never
  // equipped) should show up here.
  lore4.refundPreview = unusedLoreRefundG(g4);
  claimLoreRefundG(g4, lore4.refundPreview.ids);
  lore4.bonusesAfterRefund = g4.bonuses;
  lore4.freeLoreAfterRefundEmber = freeLoreG(g4, 'ember');
  // Duplicate-drop routing (v2.13, confirmed design): a duplicate REGULAR
  // action and a duplicate CHARGE action both credit that SAME action's own
  // pool (creditLoreG); only a duplicate CONDITION routes to a RANDOM
  // action's pool (creditRandomLoreG), chosen from lore_action_ids(g).
  creditLoreG(g4, 'strike');
  lore4.loreByActionAfterOwnCredit = Object.assign({}, g4.loreByAction);
  var poolBeforeRandomCredit = loreActionIdsG(g4);
  creditRandomLoreG(g4);
  lore4.poolForRandomCredit = poolBeforeRandomCredit;
  lore4.loreByActionAfterRandomCredit = Object.assign({}, g4.loreByAction);
  out.lore = lore4;

  // Step 3f: EQUIPMENT -- equip/unequip mutation + query helpers,
  // hand-transcribed from the real farroad-ui.js the same way every
  // orchestration function above was.
  function equipKindForSlot(slot) { return slot.indexOf('hand') === 0 ? 'hand' : slot; }
  function equipOwnedCount(gg, id) { return gg.equipInv[id] || 0; }
  function equipInUseCount(gg, id) {
    var n = 0;
    Object.keys(gg.equipped || {}).forEach(function (uid) {
      Object.keys(gg.equipped[uid]).forEach(function (slot) {
        if (gg.equipped[uid][slot] === id) n++;
      });
    });
    return n;
  }
  function equipAvailableCount(gg, id) { return equipOwnedCount(gg, id) - equipInUseCount(gg, id); }
  function equipItem(gg, uid, slot, itemId) {
    var item = C.EQUIPMENT[itemId];
    if (!item || item.slot !== equipKindForSlot(slot)) return false;
    gg.equipped = gg.equipped || {}; gg.equipped[uid] = gg.equipped[uid] || {};
    if (gg.equipped[uid][slot] === itemId) return true;
    if (equipAvailableCount(gg, itemId) <= 0) return false;
    gg.equipped[uid][slot] = itemId;
    return true;
  }
  function unequipItem(gg, uid, slot) {
    gg.equipped = gg.equipped || {}; gg.equipped[uid] = gg.equipped[uid] || {};
    delete gg.equipped[uid][slot];
  }

  var g5 = newGame(7, null);
  startWave(g5, 1);
  var equipIds = Object.keys(C.EQUIPMENT);
  var headId = equipIds.filter(function (id) { return C.EQUIPMENT[id].slot === 'head'; })[0];
  var handIds = equipIds.filter(function (id) { return C.EQUIPMENT[id].slot === 'hand'; });
  var handId = handIds[0];
  g5.equipInv[headId] = 1;
  g5.equipInv[handId] = 1;
  var equip5 = {};
  equip5.ownedBefore = equipOwnedCount(g5, headId);
  equip5.availableBefore = equipAvailableCount(g5, headId);
  equip5.equipHeadResult = equipItem(g5, 'kesh', 'head', headId);
  equip5.availableAfterEquip = equipAvailableCount(g5, headId);
  equip5.inUseAfterEquip = equipInUseCount(g5, headId);
  // Same item, same slot, already worn there -- a no-op success, not a
  // second consumption of the single owned copy.
  equip5.reEquipSameSlotResult = equipItem(g5, 'kesh', 'head', headId);
  equip5.availableAfterReEquipSameSlot = equipAvailableCount(g5, headId);
  // Slot/kind mismatch: a head item can't go in a hand slot.
  equip5.slotMismatchResult = equipItem(g5, 'kesh', 'hand1', headId);
  // Only 1 copy owned and it's already worn by kesh -- a 2nd unit can't
  // equip the same (unowned-a-2nd-copy-of) item.
  equip5.secondUnitRejectedResult = equipItem(g5, 'ansa', 'head', headId);
  unequipItem(g5, 'kesh', 'head');
  equip5.availableAfterUnequip = equipAvailableCount(g5, headId);
  equip5.equippedAfterUnequip = g5.equipped.kesh.head === undefined;
  // hand1/hand2 both accept a 'hand'-kind item (equipKindForSlot collapses
  // both positions to the same kind).
  equip5.equipHand1Result = equipItem(g5, 'kesh', 'hand1', handId);
  equip5.equipKindForHand2 = equipKindForSlot('hand2');
  out.equipment = equip5;

  // Step 3g: MARKS -- gacha pulls, hand-transcribed from the real
  // farroad-ui.js's own doPull() (UI-closure-private, same situation
  // equipItem/unequipItem were in above) the same way every orchestration
  // function above was.
  // PULL_ODDS/PULL_PITY_AT live in farroad-ui.js in the real source, which
  // this harness never loads (only core/progression/save) -- transcribed
  // here the same way doPull itself is.
  var PULL_ODDS = { unit: 0.10, equip: 0.10, action: 0.40, cond: 0.40 };
  var PULL_PITY_AT = 30;
  function pullCost(w) { return 100; }
  function doPull(g) {
    var cost = pullCost(g.wave);
    if (!P.pullsUnlocked(g)) return {};
    if (g.marks < cost) return {};
    g.marks -= cost;
    g.pullsSinceUnit = (g.pullsSinceUnit || 0) + 1;
    var pity = g.pullsSinceUnit >= PULL_PITY_AT;
    var roll = g.rng.next(), O = PULL_ODDS;
    var kind = pity ? 'unit' : ((roll < O.unit) ? 'unit' :
      ((roll < O.unit + O.equip) ? 'equip' :
        ((roll < O.unit + O.equip + O.action) ? 'action' : 'cond')));
    if (kind === 'unit') {
      g.pullsSinceUnit = 0;
      var avail = C.ROSTER.filter(function (r) { return !g.owned[r.id]; });
      if (!avail.length) {
        var dup = P.dupUnitAether(g.wave); g.aether += dup;
        return { kind: 'unit_dup', pity: pity, aetherGain: dup };
      }
      var pick = P.weightedRosterPick(g.rng, avail);
      var fielded = joinCompanion(g, pick.id);
      return { kind: 'unit', pity: pity, id: pick.id, name: pick.name, fielded: fielded };
    } else if (kind === 'equip') {
      var equipIds = Object.keys(C.EQUIPMENT);
      var eid = P.weightedEquipmentPick(g.rng, equipIds);
      g.equipInv = g.equipInv || {};
      g.equipInv[eid] = (g.equipInv[eid] || 0) + 1;
      return { kind: 'equip', id: eid, duplicate: g.equipInv[eid] > 1, ownedCount: g.equipInv[eid] };
    } else if (kind === 'action') {
      // v2.13: ALL charge actions are now pullable too, not just the
      // EQUIPPABLE pool -- the pool grows, the outcome branch dispatches on
      // ACTIONS[id].isCharge.
      var pool = C.EQUIPPABLE.concat(C.CHARGE_ACTIONS);
      var aid = P.weightedActionPick(g.rng, pool);
      g.actionCounts[aid] = (g.actionCounts[aid] || 0) + 1;
      var isChargeA = !!(C.ACTIONS[aid] && C.ACTIONS[aid].isCharge);
      if (isChargeA) {
        if (!g.mc) return { kind: 'action', id: aid, duplicate: false, isCharge: true };
        g.mc.acquiredCharges = g.mc.acquiredCharges || [];
        var dupMc = g.mc.acquiredCharges.indexOf(aid) >= 0;
        if (!dupMc) g.mc.acquiredCharges.push(aid); else creditLoreG(g, aid);
        return { kind: 'action', id: aid, duplicate: dupMc, isCharge: true };
      }
      var dupA = g.actions.indexOf(aid) >= 0;
      if (!dupA) g.actions.push(aid); else creditLoreG(g, aid);
      return { kind: 'action', id: aid, duplicate: dupA };
    } else {
      var cp = C.CONDITIONS.filter(function (c) { return c.id !== 'none'; });
      var cid = cp[g.rng.nextInt(cp.length)].id;
      g.condCounts[cid] = (g.condCounts[cid] || 0) + 1;
      var dupC = g.conditions.indexOf(cid) >= 0;
      if (!dupC) g.conditions.push(cid); else creditRandomLoreG(g);
      return { kind: 'cond', id: cid, duplicate: dupC };
    }
  }

  var g6 = newGame(7, null);
  startWave(g6, 1);
  // v2.13: a real (non-null) mc so the expanded action-pull pool's charge
  // branch is genuinely exercised (post-character-creation state), not
  // silently no-op'd by the defensive g.mc==null guard.
  g6.mc = { name: 'MC', chargeAction: 'heavystrike', acquiredCharges: ['heavystrike'] };
  var marks6 = {};
  marks6.lockedBeforeUnlock = doPull(g6);
  g6.farthest = P.MARKS_UNLOCK_WAVE;
  marks6.unaffordable = doPull(g6);
  g6.marks = 100000;
  var pullResults = [];
  for (var i = 0; i < 60; i++) pullResults.push(doPull(g6));
  marks6.pullResults = pullResults;
  marks6.pullsSinceUnitAfter = g6.pullsSinceUnit;
  marks6.marksAfter = g6.marks;
  marks6.ownedAfter = Object.keys(g6.owned);
  marks6.partyAfter = g6.party.slice();
  marks6.actionsAfter = g6.actions.slice();
  marks6.conditionsAfter = g6.conditions.slice();
  marks6.equipInvAfter = g6.equipInv;
  marks6.loreByActionAfter = g6.loreByAction;
  marks6.aetherAfter = g6.aether;
  marks6.mcAcquiredChargesAfter = g6.mc.acquiredCharges.slice();
  // Confirms at least one charge action was actually offered by the
  // expanded pull pool across these 60 draws -- a real, not just
  // theoretical, exercise of the B4 pool expansion.
  marks6.anyChargePullSeen = pullResults.some(function (r) { return r && r.isCharge; });
  out.marks = marks6;

  // Step 3h: EXPEDITION -- real-time idle sending + offline catch-up,
  // hand-transcribed from the real farroad-ui.js the same way every
  // orchestration function above was. Every time-touching function here
  // takes `now`/`saved_at` explicitly (seconds, not the real JS's
  // milliseconds) rather than reading Date.now() internally, so this
  // scenario can inject fixed synthetic timestamps and get reproducible
  // RNG-call counts -- the design fork this step's own plan flagged
  // before writing any of it (every prior section relied purely on
  // seed+call-sequence determinism; this is the first one that can't).
  var EXPED_RETURN_HP_FRAC = 0.25, EXPED_CAP_SEC = P.OFFLINE_CAP_SEC, EXPED_DISCOVERY_CHANCE = 0.08;
  var DIRECTION_AFFINITY_BONUS = 6;
  function directionLabel(dir) { return (P.DIRECTION_CONFIG[dir] || {}).label || dir; }
  function directionMul(dir) { return (P.DIRECTION_CONFIG[dir] || {}).mul || 1; }
  function isOnExpeditionG(gg, uid) {
    return gg.expeditions.some(function (e) { return e.partyIds.indexOf(uid) >= 0; });
  }
  function expNames(partyIds) {
    return partyIds.map(function (uid) {
      var d = null; C.ROSTER.forEach(function (r) { if (r.id === uid) d = r; });
      return d ? d.name : uid;
    }).join(', ');
  }
  function pushExpLog(exp, text, now) {
    exp.log = exp.log || [];
    exp.log.unshift({ at: now, text: text });
    while (exp.log.length > 40) exp.log.pop();
  }
  function applyStatMulG(enemies, mul) {
    var hpMul = Math.sqrt(mul);
    enemies.forEach(function (u) {
      u.base.hp = Math.max(1, Math.round(u.base.hp * hpMul)); u.maxHp = u.base.hp; u.hp = u.base.hp;
      u.base.atk = Math.max(1, Math.round(u.base.atk * mul));
      u.base.mag = Math.round(u.base.mag * mul);
    });
    return enemies;
  }
  function applyDirectionAffinityG(enemies, dir) {
    var ax = P.DIRECTION_CONFIG[dir] && P.DIRECTION_CONFIG[dir].affinity;
    if (!ax) return enemies;
    enemies.forEach(function (u) { u.affinity[ax] = (u.affinity[ax] || 0) + DIRECTION_AFFINITY_BONUS; });
    return enemies;
  }
  function buildExpeditionParty(gg, partyIds, hpFrac) {
    var out2 = [];
    partyIds.forEach(function (uid, i) {
      var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
      var st = P.statsAt(uid, def.stats, def.hp, levelOf(gg, uid));
      applyPctStatInvestment(gg, uid, st);
      applyEquipmentStats(gg, uid, st);
      var mh = st.hp;
      var frac = (hpFrac == null) ? 1 : Math.min(1, hpFrac + recoveryOf(gg, uid));
      var hp = Math.max(1, Math.round(mh * frac));
      out2.push(C.makeUnit({
        id: uid, name: def.name, isParty: true, level: 1, slotIndex: i, stats: st,
        maxHp: mh, hp: Math.min(hp, mh), row: def.row, chargeAction: def.chargeAction,
        affinity: effectiveAffinity(gg, uid),
        slots: ensureLoadout(gg, uid).map(function (s) { return { cond: s.cond, action: s.action }; })
      }));
    });
    return out2;
  }
  function sendExpeditionG(gg, partyIds, direction, now) {
    if (!partyIds || !partyIds.length || partyIds.length > P.PARTY_CAP) return false;
    if (Object.keys(P.DIRECTION_CONFIG).indexOf(direction) < 0) return false;
    if (gg.expeditions.some(function (e) { return e.direction === direction; })) return false;
    var seen = {};
    for (var i = 0; i < partyIds.length; i++) {
      var uid = partyIds[i];
      if (seen[uid]) return false; seen[uid] = 1;
      if (!gg.owned[uid] || gg.party.indexOf(uid) >= 0 || isOnExpeditionG(gg, uid)) return false;
    }
    var exp = {
      id: 'exp' + now + '_0', partyIds: partyIds.slice(), direction: direction,
      startedAt: now, lastResolvedAt: now, ew: 1, hpFrac: 1, bank: { aether: 0, marks: 0 },
      homeAt: null, arrivedAt: null, log: []
    };
    gg.expeditions.push(exp);
    pushExpLog(exp, expNames(partyIds) + ' set out to explore ' + directionLabel(direction) + '.', now);
    return true;
  }
  function beginReturnTripG(exp, decisionMoment, reason, now) {
    if (exp.homeAt) return;
    var awaySec = Math.max(0, decisionMoment - exp.startedAt);
    exp.homeAt = decisionMoment + awaySec / 2;
    pushExpLog(exp, expNames(exp.partyIds) + ' — ' + reason + ' Heading home now.', now);
    checkArrivalG(exp, now);
  }
  function checkArrivalG(exp, now) {
    if (exp.arrivedAt || !exp.homeAt || now < exp.homeAt) return;
    exp.arrivedAt = now;
    pushExpLog(exp, expNames(exp.partyIds) + ' arrived home — awaiting collection.', now);
  }
  function resolveExpeditionG(gg, exp, now) {
    if (exp.homeAt) { checkArrivalG(exp, now); return; }
    var elapsedSec = Math.max(0, now - exp.lastResolvedAt);
    if (elapsedSec < 5) return;
    var resolveStartedAt = exp.lastResolvedAt;
    var capped = Math.min(elapsedSec, EXPED_CAP_SEC);
    var mul = directionMul(exp.direction);
    var remaining = capped, guard = 0, savedWave = gg.wave, turnedBack = false;
    while (remaining > 0 && guard++ < 200000) {
      var cost = 20 + P.travelSec(exp.ew);
      if (cost > remaining) break;
      var party = buildExpeditionParty(gg, exp.partyIds, exp.hpFrac);
      var enemies = applyDirectionAffinityG(applyStatMulG(buildEnemies(gg, exp.ew), mul), exp.direction);
      var battle = C.makeBattle(party.concat(enemies), { rng: gg.rng, enrage: gg.enrage });
      var beatGuard = 0;
      while (!battle.over && beatGuard++ < 4000) C.step(battle);
      if (battle.over === 'party') {
        var r = P.killReward(exp.ew, enemies.length);
        exp.bank.aether += r.aether * mul; exp.bank.marks += r.marks * P.marksMul(gg) * mul;
        if (P.isBossWave(exp.ew)) exp.bank.aether += P.bossAether(exp.ew) * mul;
        var alive = party.filter(function (u) { return u.hp > 0; });
        exp.hpFrac = alive.length ? alive.reduce(function (s, u) { return s + u.hp / u.maxHp; }, 0) / alive.length : 0;
        exp.ew++;
        rollExpeditionDiscoveryG(gg, exp, mul, now);
        var dp = gg.directions[exp.direction];
        dp.maxDepth = Math.max(dp.maxDepth, exp.ew);
        // Step 3i: a while, not if -- a big catch-up pass crossing more
        // than one unlockEvery multiple in one go must unlock every
        // intervening dungeon, not just one.
        var targetTier = Math.floor(dp.maxDepth / P.DIRECTION_CONFIG[exp.direction].unlockEvery);
        while (targetTier > dp.dungeonsUnlocked) {
          dp.dungeonsUnlocked++;
          unlockDirectionDungeonG(gg, exp.direction, dp.dungeonsUnlocked, now);
        }
      } else {
        exp.hpFrac = 0;
      }
      remaining -= cost;
      if (exp.hpFrac < EXPED_RETURN_HP_FRAC) { turnedBack = true; break; }
    }
    C.setWave(savedWave);
    exp.lastResolvedAt = now;
    if (turnedBack) beginReturnTripG(exp, resolveStartedAt + (capped - remaining), 'injuries mounted and the party turned back.', now);
  }
  function rollExpeditionDiscoveryG(gg, exp, mul, now) {
    if (gg.rng.next() >= EXPED_DISCOVERY_CHANCE) return;
    var bEnemies = applyDirectionAffinityG(applyStatMulG(buildEnemies(gg, exp.ew), mul), exp.direction);
    var bParty = buildExpeditionParty(gg, exp.partyIds, exp.hpFrac);
    var bBattle = C.makeBattle(bParty.concat(bEnemies), { rng: gg.rng, enrage: gg.enrage });
    var bGuard = 0;
    while (!bBattle.over && bGuard++ < 4000) C.step(bBattle);
    if (bBattle.over === 'party') {
      var br = P.killReward(exp.ew, bEnemies.length);
      var bAether = br.aether * mul, bMarks = br.marks * P.marksMul(gg) * mul;
      exp.bank.aether += bAether; exp.bank.marks += bMarks;
      pushExpLog(exp, expNames(exp.partyIds) + ' won a bonus fight along the way — +' + Math.round(bAether) + ' Aether, +' + Math.floor(bMarks) + ' Marks.', now);
    } else {
      pushExpLog(exp, expNames(exp.partyIds) + ' were ambushed in a bonus fight and had to disengage — no reward.', now);
    }
  }
  function resolveAllExpeditionsG(gg, now) {
    gg.expeditions.slice().forEach(function (exp) { resolveExpeditionG(gg, exp, now); });
  }
  function recallExpeditionG(gg, id, now) {
    var exp = null; gg.expeditions.forEach(function (e) { if (e.id === id) exp = e; });
    if (!exp) return false;
    resolveExpeditionG(gg, exp, now);
    if (gg.expeditions.indexOf(exp) >= 0 && !exp.homeAt) beginReturnTripG(exp, now, 'recalled.', now);
    return true;
  }
  function collectExpeditionG(gg, id) {
    var exp = null; gg.expeditions.forEach(function (e) { if (e.id === id) exp = e; });
    if (!exp || !exp.arrivedAt) return false;
    gg.aether += exp.bank.aether; gg.marks += exp.bank.marks;
    gg.expeditions = gg.expeditions.filter(function (e) { return e.id !== exp.id; });
    return true;
  }
  function simulateOfflineProgressG(gg, savedAt, now) {
    var elapsedSec = Math.max(0, now - (savedAt == null ? now : savedAt));
    if (elapsedSec < 5) return;
    var capped = Math.min(elapsedSec, P.OFFLINE_CAP_SEC);
    var r = P.idlePerSec(gg.farthest);
    // v2.14: banked, not credited -- mirrors the quest/dungeon pending-
    // reward gate; accumulates across multiple uncollected resumes. The
    // replayed-combat loop below stays auto-applied, unchanged.
    gg.pendingIdleAether = (gg.pendingIdleAether || 0) + r.aether * capped;
    gg.pendingIdleMarks = (gg.pendingIdleMarks || 0) + r.marks * P.marksMul(gg) * capped;
    var remaining = capped, guard = 0;
    while (remaining > 0 && guard++ < 200000) {
      if (!gg.battle) break;
      var cost = 20 + P.travelSec(gg.wave);
      if (cost > remaining) break;
      var beatGuard = 0;
      while (!gg.battle.over && beatGuard++ < 4000) C.step(gg.battle);
      if (gg.battle.over === 'party') { afterWaveCleared(gg); startWave(gg, gg.wave + 1); }
      else if (gg.battle.over === 'enemy') { onWipe(gg); }
      else break;
      remaining -= cost;
    }
  }
  // Mirrors collectIdleReward exactly.
  function collectIdleRewardG(gg) {
    var aether = gg.pendingIdleAether || 0, marks = gg.pendingIdleMarks || 0;
    if (aether <= 0 && marks <= 0) return { aether: 0, marks: 0 };
    gg.aether += aether; gg.marks += marks;
    gg.pendingIdleAether = 0; gg.pendingIdleMarks = 0;
    return { aether: aether, marks: marks };
  }

  // Step 3i: QUESTS/dungeons -- companion quest lines + direction
  // dungeons, hand-transcribed from the real farroad-ui.js/
  // farroad-progression.js the same way every orchestration function
  // above was. bakeEnemySnapshot/unitsFromSnapshots/unlockDirectionDungeon/
  // startSideBattle/finishSideBattle mirror the real functions verbatim
  // (minus the superboss branch and all pushDrop/sysLog text, same scope
  // cut the Godot port made) -- power_level/quest_stage_wave/
  // quest_stage_aether are plain pure functions, transcribed directly.
  var DUNGEON_LEN = 1.15;
  var QUEST_STAGE_AETHER_MIN = 100, QUEST_STAGE_AETHER_MAX = 500;
  // Rescaled per later feedback: "combined units stats, total lore levels,
  // furthest wave reached" -- mirrors P.powerLevel's own new body exactly.
  var POWER_STAT_DIVISOR = 20, POWER_PER_LORE = 1;
  function powerLevelG(gg) {
    var unitStatTotal = 0;
    Object.keys(gg.owned || {}).forEach(function (uid) {
      var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
      if (!def) return;
      var st = P.statsAt(uid, def.stats, def.hp, (gg.lvl && gg.lvl[uid]) || 1);
      unitStatTotal += st.atk + st.mag + st.def + st.res + st.spd + st.hp;
    });
    var loreLevels = 0;
    Object.keys(gg.bonuses || {}).forEach(function (aid) {
      var b = gg.bonuses[aid]; loreLevels += C.actionBonusTotal(b) + (b.broad || 0);
    });
    var waveLevel = C.levelCurve(gg.farthest || 1);
    return Math.max(1, Math.round(unitStatTotal / POWER_STAT_DIVISOR + loreLevels * POWER_PER_LORE + waveLevel));
  }
  function questStageWaveG(gg, uid, stageIdx) {
    var frac = P.QUEST_LINES[uid][stageIdx].powerFraction;
    return Math.max(1, Math.round(frac * powerLevelG(gg)));
  }
  function questStageAetherG(stageIdx) {
    return Math.round(QUEST_STAGE_AETHER_MIN + stageIdx * (QUEST_STAGE_AETHER_MAX - QUEST_STAGE_AETHER_MIN) / 4);
  }
  function bakeEnemySnapshotG(u) {
    return {
      name: u.name, arch: u.arch, thorns: u.thorns, isBoss: u.isBoss, row: u.row,
      chargeAction: u.chargeAction, slots: u.slots.map(function (s) { return { cond: s.cond, action: s.action }; }),
      stats: {
        hp: u.base.hp, atk: u.base.atk, mag: u.base.mag, def: u.base.def, res: u.base.res, spd: u.base.spd,
        atkCrit: u.base.atkCrit, magCrit: u.base.magCrit, chargeRate: u.base.chargeRate, evade: u.base.evade
      },
      affinity: u.affinity
    };
  }
  function unitsFromSnapshotsG(snapshots) {
    return snapshots.map(function (snap, j) {
      return C.makeUnit({
        id: 'e' + j, name: snap.name, isParty: false, level: 1, slotIndex: 10 + j,
        arch: snap.arch, thorns: snap.thorns || 0, isBoss: snap.isBoss, row: snap.row,
        stats: snap.stats, chargeAction: snap.chargeAction, slots: snap.slots, affinity: snap.affinity
      });
    });
  }
  function unlockDirectionDungeonG(gg, dir, tier, now) {
    var cfg = P.DIRECTION_CONFIG[dir], mul = cfg.mul;
    var baseWave = tier * cfg.unlockEvery;
    var regularWave = P.isBossWave(baseWave) ? baseWave - 1 : baseWave;
    var waves = [];
    for (var i = 0; i < cfg.waveCount - 1; i++) {
      var enemies = applyDirectionAffinityG(applyStatMulG(buildEnemies(gg, regularWave), mul), dir);
      waves.push({ wave: regularWave, enemies: enemies.map(bakeEnemySnapshotG) });
    }
    var bossWave = P.nextBossWave(baseWave - 1);
    var bossEnemies = applyDirectionAffinityG(applyStatMulG(buildEnemies(gg, bossWave), mul * DUNGEON_LEN), dir);
    if (cfg.bossName) bossEnemies.forEach(function (u) { u.name = cfg.bossName; });
    waves.push({ wave: bossWave, enemies: bossEnemies.map(bakeEnemySnapshotG) });
    var dungeon = {
      id: 'dgn' + now + '_0', name: cfg.label + ' Dungeon (depth ' + baseWave + ')',
      direction: dir, tier: tier, waves: waves, clears: 0
    };
    gg.dungeons.push(dungeon);
    return dungeon;
  }
  // Step 3j: mirrors mcName/withMcName (farroad-ui.js:178-181) -- reads
  // the CURRENT C.ROSTER "kesh" entry's name directly (not g.mc.name),
  // exactly like the real functions; applyCustomMC() (not hand-
  // transcribed here, never called by this test file at all -- no
  // scenario in this harness ever mutates C.ROSTER) is what keeps that
  // entry in sync with g.mc in a real playthrough, so this always reads
  // the CSV-authored default name "Kesh" in every scenario this file
  // runs, same as prepQuestAttemptG's own g.mc-less scenarios.
  function mcNameG() {
    var d = null; C.ROSTER.forEach(function (r) { if (r.id === 'kesh') d = r; });
    return d ? d.name : 'Kesh';
  }
  function withMcNameG(text) { return text ? text.replace(/\{\{name\}\}/g, mcNameG()) : text; }
  function prepQuestAttemptG(gg, uid) {
    if (gg.sideBattle) return {};
    var q = gg.quests[uid];
    if (!q || q.stage >= 5 || gg.party.indexOf(uid) < 0) return {};
    var line = P.QUEST_LINES[uid]; if (!line) return {};
    var stage = q.stage, step = line[stage];
    q.frozen = q.frozen || [];
    if (!q.frozen[stage]) {
      var rawWave = questStageWaveG(gg, uid, stage);
      var wave = step.isBoss ? P.nextBossWave(rawWave - 1) : rawWave;
      var fresh = buildEnemies(gg, wave);
      q.frozen[stage] = { wave: wave, enemies: fresh.map(bakeEnemySnapshotG) };
    }
    var def = null; C.ROSTER.forEach(function (r) { if (r.id === uid) def = r; });
    return {
      enemies: unitsFromSnapshotsG(q.frozen[stage].enemies), wave: q.frozen[stage].wave,
      meta: { kind: 'quest', uid: uid, stage: stage, name: def ? def.name : uid, story: withMcNameG(step.story) }
    };
  }
  // Mirrors calendarDay/dungeonAvailable (farroad-ui.js:2661-2664). This
  // harness's own `now` convention is SECONDS (matching Godot's
  // Time.get_unix_time_from_system, not the real JS's Date.now() ms --
  // see the file-level note on parity-reference.js's timestamp
  // convention), so *1000 to feed a real JS Date.
  function calendarDayG(ts) {
    var d = new Date(ts * 1000);
    return d.getUTCFullYear() + '-' + d.getUTCMonth() + '-' + d.getUTCDate();
  }
  function dungeonAvailableG(dungeon, now) {
    if (dungeon.lastClearedAt == null) return true;
    return calendarDayG(now) !== calendarDayG(dungeon.lastClearedAt);
  }
  function prepDungeonAttemptG(gg, id, now) {
    if (gg.sideBattle) return {};
    var dungeon = null; gg.dungeons.forEach(function (d) { if (d.id === id) dungeon = d; });
    if (!dungeon || !dungeonAvailableG(dungeon, now)) return {};
    var wave0 = dungeon.waves[0];
    return {
      enemies: unitsFromSnapshotsG(wave0.enemies), wave: wave0.wave,
      meta: { kind: 'dungeon', dungeonId: id, name: dungeon.name, direction: dungeon.direction, tier: dungeon.tier, waveIndex: 0, totalWaves: dungeon.waves.length }
    };
  }
  function startSideBattleG(gg, enemies, wave, meta) {
    if (gg.sideBattle) return false;
    gg.roadBattle = gg.battle;
    var savedWave = gg.wave;
    C.setWave(wave);
    var party = buildExpeditionParty(gg, gg.party, 1);
    gg.battle = C.makeBattle(party.concat(enemies), { rng: gg.rng, enrage: gg.enrage });
    gg.sideBattle = { savedWave: savedWave, wave: wave, meta: meta };
    return true;
  }
  function finishSideBattleG(gg, result, gaveUp, now) {
    var sb = gg.sideBattle, meta = sb.meta;
    if (meta.kind === 'dungeon' && result === 'party' && meta.waveIndex < meta.totalWaves - 1) {
      var curDungeon = null; gg.dungeons.forEach(function (d) { if (d.id === meta.dungeonId) curDungeon = d; });
      var survivors = gg.battle.units.filter(function (u) { return u.isParty; });
      meta.waveIndex++;
      var nextWave = curDungeon.waves[meta.waveIndex];
      C.setWave(nextWave.wave);
      sb.wave = nextWave.wave;
      gg.battle = C.makeBattle(survivors.concat(unitsFromSnapshotsG(nextWave.enemies)), { rng: gg.rng, enrage: gg.enrage });
      return { kind: 'dungeon_wave_advance', waveIndex: meta.waveIndex, totalWaves: meta.totalWaves };
    }
    C.setWave(sb.savedWave);
    gg.battle = gg.roadBattle; gg.roadBattle = null; gg.sideBattle = null;
    if (meta.kind === 'quest') {
      var q = gg.quests[meta.uid];
      if (result === 'party') {
        q.stage++;
        var reward = questStageAetherG(meta.stage);
        // Banked, not credited (v2.14) -- mirrors collectExpedition's own
        // bank/collect pattern; accumulates across uncollected clears.
        q.pendingAether = (q.pendingAether || 0) + reward;
        return { kind: 'quest_cleared', name: meta.name, story: meta.story, stageNum: meta.stage + 1, questComplete: q.stage >= 5, aether: reward };
      } else if (gaveUp) {
        return { kind: 'quest_abandoned', name: meta.name, stageNum: meta.stage + 1 };
      } else {
        return { kind: 'quest_failed', name: meta.name, stageNum: meta.stage + 1 };
      }
    } else {
      var dungeon = null; gg.dungeons.forEach(function (d) { if (d.id === meta.dungeonId) dungeon = d; });
      if (result === 'party' && dungeon) {
        dungeon.clears++;
        dungeon.lastClearedAt = now;
        var rewardWave = meta.tier * P.DIRECTION_CONFIG[meta.direction].unlockEvery;
        var mul = directionMul(meta.direction);
        var r = P.killReward(rewardWave, meta.totalWaves);
        var dAether = r.aether * mul, dMarks = r.marks * P.marksMul(gg) * mul;
        // Banked, not credited (v2.14) -- same reasoning as the quest
        // branch above.
        dungeon.pendingAether = (dungeon.pendingAether || 0) + dAether;
        dungeon.pendingMarks = (dungeon.pendingMarks || 0) + dMarks;
        return { kind: 'dungeon_cleared', name: dungeon.name, aether: dAether, marks: dMarks };
      } else {
        return { kind: 'dungeon_failed', name: dungeon ? dungeon.name : 'Dungeon' };
      }
    }
  }
  // Mirrors collectQuestReward/collectDungeonReward exactly.
  function collectQuestRewardG(gg, uid) {
    var q = gg.quests[uid]; if (!q) return 0;
    var amount = q.pendingAether || 0; if (amount <= 0) return 0;
    gg.aether += amount; q.pendingAether = 0; return amount;
  }
  function collectDungeonRewardG(gg, dungeonId) {
    var dungeon = null; gg.dungeons.forEach(function (d) { if (d.id === dungeonId) dungeon = d; });
    if (!dungeon) return { aether: 0, marks: 0 };
    var aether = dungeon.pendingAether || 0, marks = dungeon.pendingMarks || 0;
    if (aether <= 0 && marks <= 0) return { aether: 0, marks: 0 };
    gg.aether += aether; gg.marks += marks;
    dungeon.pendingAether = 0; dungeon.pendingMarks = 0;
    return { aether: aether, marks: marks };
  }

  var qd = {};
  // power_level across wave/unit-count/lore/affinity/stat-invest variation.
  var gpl = newGame(7, null); startWave(gpl, 5);
  qd.powerLevelFreshWave5 = powerLevelG(gpl);
  joinCompanion(gpl, 'ansa');
  gpl.lvl.kesh = 10; gpl.lvl.ansa = 4;
  gpl.bonuses = { strike: { potent: 2, swift: 1 } };
  gpl.affinities = { kesh: { fire: 3, water: 1 } };
  gpl.statInvest = { kesh: { evade: 2 } };
  qd.powerLevelAfterInvestment = powerLevelG(gpl);

  // quest_stage_wave/quest_stage_aether across all 5 stages, two roster ids.
  qd.questStageWaveKesh = [0, 1, 2, 3, 4].map(function (s) { return questStageWaveG(gpl, 'kesh', s); });
  qd.questStageWaveAnsa = [0, 1, 2, 3, 4].map(function (s) { return questStageWaveG(gpl, 'ansa', s); });
  qd.questStageAether = [0, 1, 2, 3, 4].map(questStageAetherG);

  // unlock_direction_dungeon's full construction, two directions/tiers.
  var gud = newGame(7, null); startWave(gud, 1);
  var dWest1 = unlockDirectionDungeonG(gud, 'west', 1, 1700000000);
  var dEast2 = unlockDirectionDungeonG(gud, 'east', 2, 1700000001);
  qd.dungeonWest1 = { name: dWest1.name, tier: dWest1.tier, waveCount: dWest1.waves.length,
    waves: dWest1.waves.map(function (w) { return { wave: w.wave, enemyCount: w.enemies.length, firstAffinityKeys: Object.keys(w.enemies[0].affinity).length }; }) };
  qd.dungeonEast2 = { name: dEast2.name, tier: dEast2.tier, waveCount: dEast2.waves.length,
    waves: dEast2.waves.map(function (w) { return { wave: w.wave, enemyCount: w.enemies.length }; }) };
  qd.dungeonIdsUnique = dWest1.id !== dEast2.id;

  // resolve_expedition's while-loop dungeon-unlock wiring: a maxDepth jump
  // crossing 2+ unlockEvery multiples in one catch-up pass must unlock
  // every intervening tier, not just one.
  var gwl = newGame(7, null); startWave(gwl, 1);
  var dpWl = gwl.directions.west;
  dpWl.maxDepth = 250;
  var targetTierWl = Math.floor(dpWl.maxDepth / P.DIRECTION_CONFIG.west.unlockEvery);
  while (targetTierWl > dpWl.dungeonsUnlocked) {
    dpWl.dungeonsUnlocked++;
    unlockDirectionDungeonG(gwl, 'west', dpWl.dungeonsUnlocked, 1700000000);
  }
  qd.whileLoopDungeonsUnlocked = dpWl.dungeonsUnlocked;
  qd.whileLoopDungeonCount = gwl.dungeons.length;

  // prep_quest_attempt's freeze-once-on-first-attempt behavior.
  var gfz = newGame(7, null); startWave(gfz, 1);
  var prep1 = prepQuestAttemptG(gfz, 'kesh');
  qd.prepWaveBefore = prep1.wave;
  startWave(gfz, 50);
  var prep2 = prepQuestAttemptG(gfz, 'kesh');
  qd.prepWaveAfterMoved = prep2.wave;
  qd.prepFrozenMatches = prep1.wave === prep2.wave;

  // finish_side_battle's reward math -- quest branch (full cycle, real
  // combat play-out, deterministic via the shared seeded RNG).
  var gq = newGame(7, null); startWave(gq, 1);
  var aetherBeforeQ = gq.aether;
  var prepQ = prepQuestAttemptG(gq, 'kesh');
  startSideBattleG(gq, prepQ.enemies, prepQ.wave, prepQ.meta);
  var bg1 = 0; while (!gq.battle.over && bg1++ < 4000) C.step(gq.battle);
  var eventQ = finishSideBattleG(gq, gq.battle.over, false, 1700000000);
  qd.questCycleEvent = eventQ;
  // v2.14: a quest reward is now banked (pendingAether), not credited --
  // gg.aether stays untouched by the clear itself; the pending pool holds
  // it until collectQuestRewardG. Confirms the pending amount matches the
  // event's own reported reward, and that a real collect() round-trip
  // credits gg.aether by exactly that amount, zeroing the pool after.
  qd.questCycleAetherGain = gq.aether - aetherBeforeQ;
  qd.questCyclePendingAfterClear = gq.quests.kesh.pendingAether;
  var collectedQ = collectQuestRewardG(gq, 'kesh');
  qd.questCycleCollectedAmount = collectedQ;
  qd.questCycleAetherAfterCollect = gq.aether - aetherBeforeQ;
  qd.questCyclePendingAfterCollect = gq.quests.kesh.pendingAether;
  qd.questCycleStageAfter = gq.quests.kesh.stage;
  qd.questCycleSideBattleCleared = gq.sideBattle === null && gq.roadBattle === null;

  // give-up (quest only), instant, no beats stepped.
  var gg2 = newGame(7, null); startWave(gg2, 1);
  var stageBeforeGiveUp = gg2.quests.kesh.stage, aetherBeforeGiveUp = gg2.aether;
  var prepGu = prepQuestAttemptG(gg2, 'kesh');
  startSideBattleG(gg2, prepGu.enemies, prepGu.wave, prepGu.meta);
  var eventGu = finishSideBattleG(gg2, 'enemy', true, 1700000000);
  qd.giveUpEvent = eventGu;
  qd.giveUpStageUnchanged = gg2.quests.kesh.stage === stageBeforeGiveUp;
  qd.giveUpAetherUnchanged = gg2.aether === aetherBeforeGiveUp;

  // finish_side_battle's reward math + multi-wave in-place advance --
  // dungeon branch, driven to full resolution (win or lose is fine, this
  // exercises the SAME code path either way; we just record what happened).
  var gd = newGame(7, null); startWave(gd, 1);
  var dungeonD = unlockDirectionDungeonG(gd, 'west', 1, 1700000000);
  var prepD = prepDungeonAttemptG(gd, dungeonD.id, 1700000000);
  startSideBattleG(gd, prepD.enemies, prepD.wave, prepD.meta);
  var waveAdvances = 0, finalEventD = null, guardD = 0;
  while (guardD++ < 20) {
    var bg2 = 0; while (!gd.battle.over && bg2++ < 4000) C.step(gd.battle);
    var evD = finishSideBattleG(gd, gd.battle.over, false, 1700000000);
    if (evD.kind === 'dungeon_wave_advance') { waveAdvances++; continue; }
    finalEventD = evD; break;
  }
  qd.dungeonCycleWaveAdvances = waveAdvances;
  qd.dungeonCycleFinalEvent = finalEventD;
  qd.dungeonCycleClears = dungeonD.clears;
  qd.dungeonCycleSideBattleCleared = gd.sideBattle === null;
  // v2.14: same banked-then-collect check as the quest cycle above.
  qd.dungeonCyclePendingAfterClear = { aether: dungeonD.pendingAether || 0, marks: dungeonD.pendingMarks || 0 };
  var aetherBeforeDCollect = gd.aether, marksBeforeDCollect = gd.marks;
  var collectedD = collectDungeonRewardG(gd, dungeonD.id);
  qd.dungeonCycleCollectedAmount = collectedD;
  qd.dungeonCycleAetherAfterCollect = gd.aether - aetherBeforeDCollect;
  qd.dungeonCycleMarksAfterCollect = gd.marks - marksBeforeDCollect;
  qd.dungeonCyclePendingAfterCollect = { aether: dungeonD.pendingAether || 0, marks: dungeonD.pendingMarks || 0 };

  // dungeon_available's calendar-day cooldown: flips false immediately
  // after a clear, stays false later the SAME UTC day, and flips back
  // true once `now` crosses the UTC day boundary -- constructed directly
  // (two timestamps straddling a real midnight) rather than waiting on
  // a real clock.
  var gca = newGame(7, null); startWave(gca, 1);
  var dungeonCA = unlockDirectionDungeonG(gca, 'west', 1, 1700000000);
  var midnightUtc = 1704067200; // 2024-01-01T00:00:00Z
  var justBeforeMidnight = midnightUtc - 1; // 2023-12-31T23:59:59Z
  dungeonCA.lastClearedAt = justBeforeMidnight;
  qd.dungeonAvailableNeverCleared = dungeonAvailableG({ lastClearedAt: null }, 1700000000);
  qd.dungeonAvailableSameMoment = dungeonAvailableG(dungeonCA, justBeforeMidnight);
  qd.dungeonAvailableSameDayLater = dungeonAvailableG(dungeonCA, midnightUtc - 30);
  qd.dungeonAvailableAfterMidnight = dungeonAvailableG(dungeonCA, midnightUtc);
  var prepBlocked = prepDungeonAttemptG(gca, dungeonCA.id, justBeforeMidnight);
  qd.dungeonAvailablePrepBlocked = Object.keys(prepBlocked).length === 0;
  var prepAllowed = prepDungeonAttemptG(gca, dungeonCA.id, midnightUtc);
  qd.dungeonAvailablePrepAllowed = Object.keys(prepAllowed).length > 0;

  out.questsDungeons = qd;

  // Step 3j: character creation -- mc_lerp/mc_points_spent/mc_build_stats
  // are REAL P functions (P.mcLerp/mcPointsSpent/mcBuildStats), not
  // UI-layer closures -- called directly here, no hand-transcription
  // needed (unlike everything sourced from farroad-ui.js).
  var mcOut = {};
  mcOut.lerpAtkMin = P.mcLerp(P.MC_STAT_RANGE.atk, P.MC_POINT_MIN);
  mcOut.lerpAtkMax = P.mcLerp(P.MC_STAT_RANGE.atk, P.MC_POINT_MAX);
  mcOut.lerpAtkMid = P.mcLerp(P.MC_STAT_RANGE.atk, 7);
  mcOut.lerpHpGrowthMin = P.mcLerp(P.MC_GROWTH_RANGE.hp, P.MC_POINT_MIN);
  mcOut.lerpHpGrowthMax = P.mcLerp(P.MC_GROWTH_RANGE.hp, P.MC_POINT_MAX);
  mcOut.lerpHpGrowthMid = P.mcLerp(P.MC_GROWTH_RANGE.hp, 7);
  var allZero = { atk: 0, mag: 0, def: 0, res: 0, spd: 0, hp: 0 };
  var allMax = { atk: 15, mag: 15, def: 15, res: 15, spd: 15, hp: 15 };
  var mixed = { atk: 15, mag: 0, def: 10, res: 5, spd: 10, hp: 5 };
  mcOut.pointsSpentZero = P.mcPointsSpent(allZero);
  mcOut.pointsSpentMax = P.mcPointsSpent(allMax);
  mcOut.pointsSpentMixed = P.mcPointsSpent(mixed);
  mcOut.buildStatsZero = P.mcBuildStats(allZero);
  mcOut.buildStatsMax = P.mcBuildStats(allMax);
  mcOut.buildStatsMixed = P.mcBuildStats(mixed);
  out.mc = mcOut;

  var NOW0 = 1700000000;
  var g7 = newGame(7, null);
  startWave(g7, 1);
  var exped7 = {};
  // Own a 2nd unit to send (kesh stays fielded, ansa gets benched-by-
  // construction -- joinCompanion only auto-fields up to PARTY_CAP, and
  // kesh is already in g7.party from newGame, so ansa lands benched here
  // as long as PARTY_CAP allows both -- confirmed benched via
  // isOnExpeditionG/available check below rather than assumed).
  joinCompanion(g7, 'ansa');
  g7.party = ['kesh']; // force ansa benched regardless of PARTY_CAP, deterministic setup
  exped7.isOnExpeditionBefore = isOnExpeditionG(g7, 'ansa');
  exped7.sendResult = sendExpeditionG(g7, ['ansa'], 'west', NOW0);
  exped7.isOnExpeditionAfter = isOnExpeditionG(g7, 'ansa');
  exped7.sendDuplicateDirectionRejected = sendExpeditionG(g7, ['ansa'], 'west', NOW0);
  exped7.sendAlreadyAwayRejected = sendExpeditionG(g7, ['ansa'], 'northwest', NOW0);

  var exp7 = g7.expeditions[0];
  // Partial catch-up: 1 hour in.
  resolveExpeditionG(g7, exp7, NOW0 + 3600);
  exped7.ewAfter1h = exp7.ew;
  exped7.bankAfter1h = { aether: exp7.bank.aether, marks: exp7.bank.marks };
  exped7.hpFracAfter1h = exp7.hpFrac;
  exped7.lastResolvedAtAfter1h = exp7.lastResolvedAt;
  // A second pass far enough out to force the 12h cap on THIS pass alone.
  resolveExpeditionG(g7, exp7, NOW0 + 3600 + 50000);
  exped7.ewAfterCapPass = exp7.ew;
  exped7.lastResolvedAtAfterCapPass = exp7.lastResolvedAt;
  exped7.homeAtAfterCapPass = exp7.homeAt;
  exped7.arrivedAtAfterCapPass = exp7.arrivedAt;

  // Recall a FRESH short expedition (sent and immediately recalled --
  // awaySec ~0, so the trip home reads as instant).
  var g8 = newGame(11, null);
  startWave(g8, 1);
  joinCompanion(g8, 'ansa'); g8.party = ['kesh'];
  sendExpeditionG(g8, ['ansa'], 'east', NOW0);
  var exp8 = g8.expeditions[0];
  exped7.recallResult = recallExpeditionG(g8, exp8.id, NOW0 + 2);
  exped7.homeAtAfterRecall = exp8.homeAt;
  exped7.arrivedAtAfterRecall = exp8.arrivedAt;
  exped7.collectBeforeArrivedRejected = collectExpeditionG(g8, exp8.id);
  // Fast-forward past the (near-instant) trip home, then collect for real.
  var arrivedNow = Math.ceil(exp8.homeAt) + 1;
  checkArrivalG(exp8, arrivedNow);
  var aetherBeforeCollect = g8.aether, marksBeforeCollect = g8.marks;
  var bankAtCollect = { aether: exp8.bank.aether, marks: exp8.bank.marks };
  exped7.collectResult = collectExpeditionG(g8, exp8.id);
  exped7.aetherGainFromCollect = g8.aether - aetherBeforeCollect;
  exped7.marksGainFromCollect = g8.marks - marksBeforeCollect;
  exped7.bankMatchesGain = (Math.abs(bankAtCollect.aether - exped7.aetherGainFromCollect) < 1e-9) &&
    (Math.abs(bankAtCollect.marks - exped7.marksGainFromCollect) < 1e-9);
  exped7.expeditionsAfterCollect = g8.expeditions.length;

  // simulate_offline_progress: a multi-hour gap on a fresh game.
  var g9 = newGame(7, null);
  startWave(g9, 1);
  var waveBefore9 = g9.wave, aetherBefore9 = g9.aether, wipesBefore9 = g9.wipes;
  simulateOfflineProgressG(g9, NOW0, NOW0 + 7200);
  exped7.offlineWaveDelta = g9.wave - waveBefore9;
  // v2.14: offlineAetherGained now covers ONLY what the replayed combat
  // itself already credited (kill_reward, never gated) -- the idle
  // trickle is separately banked/collected, checked just below.
  exped7.offlineAetherGained = g9.aether - aetherBefore9;
  exped7.offlineWipes = g9.wipes - wipesBefore9;
  exped7.offlineRngCallsAfter = g9.rng.calls;
  exped7.offlineIdlePendingAfter = { aether: g9.pendingIdleAether || 0, marks: g9.pendingIdleMarks || 0 };
  var aetherBefore9Collect = g9.aether, marksBefore9Collect = g9.marks;
  var idleCollected = collectIdleRewardG(g9);
  exped7.offlineIdleCollectedAmount = idleCollected;
  exped7.offlineAetherAfterIdleCollect = g9.aether - aetherBefore9Collect;
  exped7.offlineMarksAfterIdleCollect = g9.marks - marksBefore9Collect;
  exped7.offlineIdlePendingAfterCollect = { aether: g9.pendingIdleAether || 0, marks: g9.pendingIdleMarks || 0 };

  out.expedition = exped7;

  console.log(JSON.stringify(out));
}

/* Step 3a: FarroadSave.gd -- a hand-built G with non-default values in every
   FIELDS entry (not a full simulated playthrough -- serialize/deserialize
   don't care HOW a value got there, only that it round-trips), plus a
   couple of real rng.next() calls before serializing so the RNG
   reseed-and-fast-forward logic is actually exercised, not just field
   copying. Also covers the pre-field-existing migration defaults
   (dropsGranted seeded from clearedWaves, kesh's owned/lvl/bank/affinities/
   statInvest/equipped backfills, directions default-fill) by deserializing
   a DELIBERATELY SPARSE snapshot missing those fields. */
if (mode === 'save') {
  var g = {
    seed: 999, rng: C.makeRNG(999), wave: 5, farthest: 5, bossesCleared: 0,
    aether: 42.5, loreByAction: { strike: 3 }, marks: 7.25, wipes: 1,
    party: ['kesh', 'ansa'], actions: ['strike', 'ember', 'sear'], conditions: ['none', 'foe_lowest_hp'],
    actionCounts: { sear: 1 }, condCounts: { foe_lowest_hp: 1 }, bonuses: { strike: { potent: 2 } },
    recovery: { kesh: 3 }, loadout: { kesh: [{ cond: 'none', action: 'strike' }] },
    hpCarry: { kesh: 0.8 }, chargeCarry: { kesh: 12.5 }, touched: { kesh: true }, clearedWaves: { 1: 1, 2: 1, 3: 1, 4: 1 },
    dropsGranted: { 1: 1, 2: 1, 3: 1, 4: 1, 5: 1 },
    lvl: { kesh: 3, ansa: 1 }, bank: { kesh: 12, ansa: 0 }, maxLevelEver: 3, owned: { kesh: 1, ansa: 1 },
    enrage: true, idleAcc: 1.5, dropQueue: [{ name: 'Sear' }], dropHistory: [{ name: 'Sear' }],
    pullsSinceUnit: 4, dropGains: { lore: 2, aether: 10 },
    mc: { name: 'Testarossa', stats: { atk: 28, mag: 16, def: 23, res: 21, spd: 86 }, hp: 444,
      growth: { atk: 2.1, mag: 1.4, def: 1.4, res: 1.2, spd: 2.1, hp: 30 },
      chargeAction: 'wildfire', acquiredCharges: ['wildfire'] },
    expeditions: [], dungeons: [], quests: { kesh: { stage: 0, frozen: [] } },
    directions: { west: { maxDepth: 3, dungeonsUnlocked: 1 } },
    affinities: { kesh: { fire: 2 }, ansa: {} }, statInvest: { kesh: { evade: 1 }, ansa: {} },
    equipInv: { emberwardencrown: 1 }, equipped: { kesh: { head: 'emberwardencrown' }, ansa: {} },
    superBossQuests: [], superBossesUnlocked: 0, superBossesCleared: {}
  };
  for (var i = 0; i < 17; i++) g.rng.next();   // move the RNG off its seed position

  var out = {};
  var snap = S.serialize(g, 1234567890);
  out.snapRngCalls = snap.rngCalls;
  var restored = S.deserialize(snap, C);
  out.restoredWave = restored.wave;
  out.restoredParty = restored.party;
  out.restoredAffinities = restored.affinities;
  out.restoredEquipped = restored.equipped;
  out.restoredMc = restored.mc;
  out.restoredChargeCarry = restored.chargeCarry;
  out.restoredLoreByAction = restored.loreByAction;
  // Prove the RNG position round-trips: draw the same N values from both the
  // ORIGINAL (still-live) rng and the RESTORED one -- must match bit-exact.
  var origNext = [], restoredNext = [];
  for (var j = 0; j < 10; j++) origNext.push(g.rng.next());
  for (var j = 0; j < 10; j++) restoredNext.push(restored.rng.next());
  out.rngMatch = JSON.stringify(origNext) === JSON.stringify(restoredNext);
  out.origNext = origNext; out.restoredNext = restoredNext;

  // Sparse snapshot -- a save from before several fields existed -- proves
  // the migration/default-fill branches in deserialize().
  var sparse = { v: 1, savedAt: 1, seed: 5, rngCalls: 0, wave: 3, farthest: 3, party: ['kesh'],
    clearedWaves: { 1: 1, 2: 1 } };
  var migrated = S.deserialize(sparse, C);
  out.migrated = {
    dropsGranted: migrated.dropsGranted, owned: migrated.owned, lvl: migrated.lvl, bank: migrated.bank,
    affinities: migrated.affinities, statInvest: migrated.statInvest, equipped: migrated.equipped,
    directions: migrated.directions, quests: migrated.quests, expeditions: migrated.expeditions,
    enrage: migrated.enrage, actions: migrated.actions, conditions: migrated.conditions,
    loreByAction: migrated.loreByAction
  };

  console.log(JSON.stringify(out));
}
