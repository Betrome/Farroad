#!/usr/bin/env node
/* =============================================================================
 * FARROAD — content-pipeline.js
 * Reads farroadunits/actions/enemies/quests/dungeons.csv (the REAL source of
 * truth for that content — edit the CSV, rebuild, the change is live) and
 * compiles them into the plain-data shape farroad-core.js/-progression.js
 * expect off window.FarroadContent. Shared by build.js (the fused HTML) and
 * farroadsmoke.js (the headless test harness), so both ever see the SAME
 * compiled content — never duplicated, never able to drift apart.
 *
 * farroadgambitconditions.csv stays a documentation-only mirror (not read
 * here) — a gambit condition's "resolve" field IS executable JS, not data
 * next to logic, so there is nothing honest to generate from it; see
 * MODULES.md.
 * ========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');

function parseCSV(text) {
  const rows = [];
  let row = [], field = '', inQuotes = false;
  const pushField = () => { row.push(field); field = ''; };
  const pushRow = () => { pushField(); rows.push(row); row = []; };
  for (let i = 0; i < text.length; i++) {
    const c = text[i], next = text[i + 1];
    if (inQuotes) {
      if (c === '"' && next === '"') { field += '"'; i++; }
      else if (c === '"') inQuotes = false;
      else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ',') pushField();
    else if (c === '\r') { /* skip, \n (or end) closes the row */ }
    else if (c === '\n') pushRow();
    else field += c;
  }
  if (field.length || row.length) pushRow();
  const nonEmpty = rows.filter(r => !(r.length === 1 && r[0] === ''));
  const header = nonEmpty[0];
  return nonEmpty.slice(1).map(r => {
    const obj = {};
    header.forEach((h, i) => { obj[h] = (r[i] === undefined ? '' : r[i]).trim(); });
    return obj;
  });
}
const num = (v, dflt) => (v === undefined || v === '' ? dflt : Number(v));
const bool = v => v === 'TRUE';

function compileRoster(rows) {
  return rows.map(r => ({
    id: r.id, name: r.name, role: r.role, row: r.row, hp: num(r.hp),
    chargeAction: r.charge_action || null,
    stats: {
      atk: num(r.atk), mag: num(r.mag), def: num(r.def), res: num(r.res), spd: num(r.spd),
      atkCrit: num(r.atk_crit), magCrit: num(r.mag_crit), chargeRate: num(r.charge_rate),
      block: num(r.block), evade: num(r.evade)
    }
  }));
}

/* Skips the 'boss' row — there is no ARCH.boss in the engine; boss enemies
   are synthesized at combat-build time from ARCH.ox's shape + ARCH.wolf's
   HP reference (see buildEnemies in farroad-ui.js), a deliberate design
   this pipeline doesn't change. Two real generalizations vs. the old
   hardcoded JS: magCrit and chargeAction become genuine per-archetype
   fields (seeded here to match today's effective values — a single global
   0.04 magCrit, and chargeAction only on ox/hound — so behavior is
   unchanged on day one, but both are now real CSV-editable levers). */
function compileArch(rows) {
  const arch = {};
  rows.forEach(r => {
    if (!/^[\d.]+$/.test(r.hp_multiplier)) return;   // the 'boss' row: not a real archetype
    const entry = {
      key: r.key, name: r.name, hpMul: num(r.hp_multiplier),
      atk: num(r.atk), def: num(r.def), res: num(r.res), spd: num(r.spd),
      atkCrit: num(r.atk_crit), magCrit: num(r.mag_crit, 0.04),
      evade: num(r.evade), block: num(r.block),
      slots: [{ cond: r.slot1_condition, action: r.slot1_action },
              { cond: r.slot2_condition, action: r.slot2_action }]
    };
    if (r.mag !== '') entry.mag = num(r.mag);
    if (num(r.thorns, 0) > 0) entry.thorns = num(r.thorns);
    if (r.charge_action) entry.chargeAction = r.charge_action;
    arch[r.key] = entry;
  });
  return arch;
}

/* Every field an action can carry EXCEPT the handful that are genuinely
   executable code (a dynamic power/crit formula, or the "hits each land on
   a fresh random target" flag) — those stay hand-written JS, merged onto
   this CSV-generated table by id (ACTION_DYNAMIC in farroad-core.js). Both
   isCharge and inert ARE derivable from the CSV's own `kind` column
   (charge / equippable / inert), so — unlike the true closures — they
   don't need a hand-written override. */
function compileActions(rows) {
  const actions = {};
  rows.forEach(r => {
    const e = { id: r.id, name: r.name, camp: r.camp, tk: r.target };
    if (r.scale_stat) e.scaleStat = r.scale_stat;
    if (r.power !== '') e.power = num(r.power);
    if (r.rank !== '') e.rank = num(r.rank);
    if (r.charge_gain !== '') e.charge = num(r.charge_gain);
    if (r.hits !== '' && num(r.hits) !== 1) e.hits = num(r.hits);
    if (r.applies_status) e.applies = r.applies_status;
    if (r.status_turns !== '') e.turns = num(r.status_turns);
    if (r.def_pierce !== '') e.defPierce = num(r.def_pierce);
    if (r.crit_bonus !== '') e.critBonus = num(r.crit_bonus);
    if (bool(r.heal)) e.heal = true;
    if (r.lifesteal !== '') e.lifesteal = num(r.lifesteal);
    if (r.revive !== '') e.revive = num(r.revive);
    if (r.cleanse !== '') e.cleanse = num(r.cleanse);
    if (r.self_taunt !== '') e.selfTaunt = num(r.self_taunt);
    if (r.kind === 'charge') e.isCharge = true;
    if (r.kind === 'inert') e.inert = true;
    if (r.design_note) e.note = r.design_note;
    actions[r.id] = e;
  });
  return actions;
}

/* One entry per companion, 5 stages each: {story, powerFraction, isBoss}.
   powerFraction replaces the old fixed P.QUEST_STAGE_POWER_FRAC array with
   an explicit per-companion-per-stage value (validated ascending below). */
function compileQuestLines(rows) {
  const lines = {};
  rows.forEach(r => {
    const id = r.companion_id, stage = Number(r.stage);
    if (!lines[id]) lines[id] = [];
    lines[id][stage - 1] = { story: r.story, powerFraction: num(r.power_fraction), isBoss: bool(r.is_boss) };
  });
  return lines;
}
/* {dir:{label,mul,waveCount,unlockEvery,bossName}} — replaces the formula-
   computed P.directionMul() and the hardcoded DUNGEON_WAVE_COUNT/
   DUNGEON_UNLOCK_EVERY defaults with explicit, independently CSV-editable
   per-direction values. */
function compileDirectionConfig(rows) {
  const cfg = {};
  rows.forEach(r => {
    cfg[r.direction] = {
      label: r.label, mul: num(r.difficulty_multiplier),
      waveCount: num(r.wave_count), unlockEvery: num(r.unlock_every),
      bossName: r.boss_name || null
    };
  });
  return cfg;
}

const ACTION_DYNAMIC_IDS = ['execute', 'vengeance', 'onslaught', 'reckoning', 'ninefold'];
const DIRECTIONS_EXPECTED = ['west', 'northwest', 'southwest', 'north', 'south', 'northeast', 'southeast', 'east'];

/* Reads and compiles all 5 CSVs from `rootDir`, validates them (fail loudly,
   never ship/test a silent undefined), and returns {content, problems} —
   `content` is the plain object window.FarroadContent gets set to;
   `problems` is a string[] of validation failures (empty = clean). */
function buildContent(rootDir) {
  const readCsv = f => fs.readFileSync(path.join(rootDir, f), 'utf8');
  const problems = [];

  const rosterRows = parseCSV(readCsv('farroadunits.csv'));
  const archRows = parseCSV(readCsv('farroadenemies.csv'));
  const actionRows = parseCSV(readCsv('farroadactions.csv'));
  const questRows = parseCSV(readCsv('farroadquests.csv'));
  const dungeonRows = parseCSV(readCsv('farroaddungeons.csv'));

  const ROSTER = compileRoster(rosterRows);
  const ARCH = compileArch(archRows);
  const ACTIONS = compileActions(actionRows);
  const QUEST_LINES = compileQuestLines(questRows);
  const DIRECTION_CONFIG = compileDirectionConfig(dungeonRows);

  function dupCheck(name, rows, keyFn) {
    const seen = {};
    rows.forEach(r => { const k = keyFn(r); if (seen[k]) problems.push(`${name}: duplicate id "${k}"`); seen[k] = 1; });
  }
  dupCheck('farroadunits.csv', rosterRows, r => r.id);
  dupCheck('farroadenemies.csv', archRows.filter(r => /^[\d.]+$/.test(r.hp_multiplier)), r => r.key);
  dupCheck('farroadactions.csv', actionRows, r => r.id);

  const allChargeIds = []
    .concat(ROSTER.map(r => r.chargeAction).filter(Boolean))
    .concat(Object.keys(ARCH).map(k => ARCH[k].chargeAction).filter(Boolean));
  allChargeIds.forEach(id => { if (!ACTIONS[id]) problems.push(`charge_action "${id}" has no matching row in farroadactions.csv`); });
  ACTION_DYNAMIC_IDS.forEach(id => { if (!ACTIONS[id]) problems.push(`ACTION_DYNAMIC override "${id}" (farroad-core.js) has no matching row in farroadactions.csv`); });

  ROSTER.forEach(r => {
    const line = QUEST_LINES[r.id];
    /* .some()/.filter() SKIP holes in a sparse array (a missing stage row
       leaves index i-1 unassigned, not merely falsy) — explicit index
       access is required here or a missing row silently passes this
       check and crashes the ascending-powerFraction loop below instead
       of failing cleanly. */
    let presentCount = 0, hasHole = line ? line.length !== 5 : true;
    if (line) for (let i = 0; i < 5; i++) { if (line[i]) presentCount++; else hasHole = true; }
    if (!line || hasHole) {
      problems.push(`farroadquests.csv: roster id "${r.id}" needs exactly 5 stage rows (1-5), has ${presentCount}`);
      return;
    }
    for (let i = 1; i < 5; i++) if (!(line[i].powerFraction > line[i - 1].powerFraction))
      problems.push(`farroadquests.csv: "${r.id}" stage ${i + 1}'s power_fraction must be greater than stage ${i}'s`);
  });
  DIRECTIONS_EXPECTED.forEach(dir => { if (!DIRECTION_CONFIG[dir]) problems.push(`farroaddungeons.csv: missing a row for direction "${dir}"`); });
  Object.keys(DIRECTION_CONFIG).forEach(dir => { if (DIRECTIONS_EXPECTED.indexOf(dir) < 0) problems.push(`farroaddungeons.csv: unrecognized direction "${dir}"`); });

  return { content: { ROSTER, ARCH, ACTIONS, QUEST_LINES, DIRECTION_CONFIG }, problems };
}

module.exports = { parseCSV, compileRoster, compileArch, compileActions, compileQuestLines, compileDirectionConfig, buildContent };
