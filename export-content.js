#!/usr/bin/env node
/* =============================================================================
 * FARROAD — export-content.js
 * Exports the CSV-compiled content core.js needs into a JSON file the Godot
 * port can load (godot-project/data/content.json) -- Milestone 1 (Step 1e).
 *
 * Uses the SAME content-pipeline.js buildContent() build.js/farroadsmoke.js
 * already share, so this is never a second, possibly-drifted CSV reader.
 * Only exports the 4 tables farroad-core.js itself reads off
 * window.FarroadContent (ACTIONS/ARCH/ROSTER/EQUIPMENT) -- QUEST_LINES and
 * DIRECTION_CONFIG are progression/UI-layer concerns, out of this milestone's
 * scope (see the plan).
 *
 * Like farroad-prototype-*.html, the output is a committed build artifact,
 * not hand-edited -- regenerate with `node export-content.js` whenever the
 * CSVs change.
 *
 *   node export-content.js   -> godot-project/data/content.json
 * =========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');

const { buildContent } = require('./content-pipeline.js');
const { content, problems } = buildContent(__dirname);
if (problems.length) {
  console.error('CONTENT BUILD FAILED:\n  ' + problems.join('\n  '));
  process.exit(1);
}

const exported = {
  ACTIONS: content.ACTIONS,
  ARCH: content.ARCH,
  ROSTER: content.ROSTER,
  EQUIPMENT: content.EQUIPMENT
};

const outDir = path.join(__dirname, 'godot-project', 'data');
fs.mkdirSync(outDir, { recursive: true });
const outFile = path.join(outDir, 'content.json');
fs.writeFileSync(outFile, JSON.stringify(exported));

console.log('exported ' + path.relative(__dirname, outFile) +
  '  (' + Object.keys(exported.ACTIONS).length + ' actions, ' +
  Object.keys(exported.ARCH).length + ' archetypes, ' +
  exported.ROSTER.length + ' roster, ' +
  Object.keys(exported.EQUIPMENT).length + ' equipment)');
