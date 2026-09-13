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
    var vMul = variety ? (P.countStrength(n) * P.bandRoll(g.rng)) : 1;
    C.setWave(w);
    var S = C.waveScale(w), out = [];
    for (var j = 0; j < n; j++) {
      var key = boss ? 'ox' : P.archetypeFor(w, j), a = C.ARCH[key];
      var hpBase;
      if (boss) {
        var ref = C.ARCH.wolf;
        hpBase = 200 * ref.hpMul * C.dmgTakenMul(ref) * S * Math.max(1, P.enemyCount(w)) * (superBossKey ? P.SUPERBOSS_LEN : P.BOSS_LEN);
      } else hpBase = 200 * a.hpMul * C.dmgTakenMul(a) * S;
      hpBase *= P.DIFFICULTY * vMul * Math.sqrt(P.hardMul(w));
      var hardAtkMul = P.hardMul(w) * (boss ? P.BOSS_HARD_EXTRA : 1);
      var atkMul = (boss ? 1.10 : 1) * P.DIFFICULTY * vMul * hardAtkMul;
      out.push(C.makeUnit({
        id: 'e' + j, name: (boss ? 'ROADWARDEN' : a.name) + (n > 1 ? ' ' + (j + 1) : ''),
        isParty: false, level: 1, slotIndex: 10 + j, arch: key, thorns: a.thorns || 0, isBoss: boss,
        row: j < 5 ? 'front' : 'back',
        stats: {
          hp: Math.max(8, Math.round(hpBase)), atk: Math.max(1, Math.round(a.atk * S * atkMul)),
          mag: Math.round((a.mag || 8) * S * P.DIFFICULTY * hardAtkMul),
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
        if (!dup) g.actions.push(d.id); else g.lore += 1;
        events.push({ kind: 'action', id: d.id, wave: w, duplicate: dup, why: curated ? (d.why || null) : null });
      } else if (d.kind === 'charge') {
        g.mc.acquiredCharges = g.mc.acquiredCharges || [];
        var dupC = g.mc.acquiredCharges.indexOf(d.id) >= 0;
        if (!dupC) g.mc.acquiredCharges.push(d.id); else g.lore += 1;
        events.push({ kind: 'charge', id: d.id, wave: w, duplicate: dupC });
      } else if (d.kind === 'equip') {
        g.equipInv = g.equipInv || {};
        g.equipInv[d.id] = (g.equipInv[d.id] || 0) + 1;
        events.push({ kind: 'equip', id: d.id, wave: w, ownedCount: g.equipInv[d.id], why: curated ? (d.why || null) : null });
      } else {
        g.condCounts[d.id] = (g.condCounts[d.id] || 0) + 1;
        var dup2 = g.conditions.indexOf(d.id) >= 0;
        if (!dup2) g.conditions.push(d.id); else g.lore += 1;
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
    g.units.forEach(function (u) { g.hpCarry[u.id] = u.hp / u.maxHp; });
    var r = P.killReward(g.wave, g.enemies.length);
    g.aether += r.aether; g.marks += r.marks * P.marksMul(g);
    if (P.isBossWave(g.wave) && firstClear) {
      g.bossesCleared++;
      var hoard = P.bossAether(g.wave);
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
    var back = P.checkpoint(g.bossesCleared);
    g.hpCarry = {};
    var events = [{ kind: 'wipe', backTo: back }];
    events = events.concat(startWave(g, back));
    return events;
  }
  function newGame(seed, mc) {
    return {
      seed: seed || 7, rng: C.makeRNG(seed || 7), wave: 0, farthest: 1, bossesCleared: 0,
      aether: 0, lore: 0, marks: 0, wipes: 0,
      party: ['kesh'], actions: P.STARTER_ACTIONS.slice(), conditions: ['none'],
      actionCounts: {}, condCounts: {}, bonuses: {}, recovery: {}, loadout: {}, hpCarry: {}, touched: {},
      clearedWaves: {}, dropsGranted: {},
      lvl: { kesh: 1 }, bank: { kesh: 0 }, maxLevelEver: 1, owned: { kesh: 1 },
      affinities: { kesh: {} }, statInvest: { kesh: {} }, equipInv: {}, equipped: { kesh: {} },
      battle: null, units: null, enemies: null, over: null, enrage: true, idleAcc: 0,
      mc: mc || null, expeditions: [], pullsSinceUnit: 0,
      dungeons: [], quests: { kesh: { stage: 0, frozen: [] } },
      superBossQuests: [], superBossesUnlocked: 0, superBossesCleared: {}
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
      entry.aether = g.aether; entry.marks = g.marks; entry.lore = g.lore;
      entry.party = g.party.slice(); entry.actions = g.actions.slice(); entry.conditions = g.conditions.slice();
      trace.push(entry);
      startWave(g, w + 1);
    } else {
      entry.events = onWipe(g);
      entry.aether = g.aether; entry.marks = g.marks; entry.lore = g.lore;
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
    aether: 42.5, lore: 3, marks: 7.25, wipes: 1,
    party: ['kesh', 'ansa'], actions: ['strike', 'ember', 'sear'], conditions: ['none', 'foe_lowest_hp'],
    actionCounts: { sear: 1 }, condCounts: { foe_lowest_hp: 1 }, bonuses: { strike: { potent: 2 } },
    recovery: { kesh: 3 }, loadout: { kesh: [{ cond: 'none', action: 'strike' }] },
    hpCarry: { kesh: 0.8 }, touched: { kesh: true }, clearedWaves: { 1: 1, 2: 1, 3: 1, 4: 1 },
    dropsGranted: { 1: 1, 2: 1, 3: 1, 4: 1, 5: 1 },
    lvl: { kesh: 3, ansa: 1 }, bank: { kesh: 12, ansa: 0 }, maxLevelEver: 3, owned: { kesh: 1, ansa: 1 },
    enrage: true, idleAcc: 1.5, dropQueue: [{ name: 'Sear' }], dropHistory: [{ name: 'Sear' }],
    pullsSinceUnit: 4, dropGains: { lore: 2, aether: 10 },
    mc: null, expeditions: [], dungeons: [], quests: { kesh: { stage: 0, frozen: [] } },
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
    enrage: migrated.enrage, actions: migrated.actions, conditions: migrated.conditions
  };

  console.log(JSON.stringify(out));
}
