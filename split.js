#!/usr/bin/env node
/* =============================================================================
 * FARROAD — split.js
 * Extracts the fused prototype HTML into source modules.
 *
 * This is the INVERSE of build.js. Run it ONCE to bootstrap src/ from the
 * existing single-file prototype, then never again — after that, src/ is the
 * source of truth and build.js regenerates the HTML.
 *
 * The extraction is purely mechanical: it slices on the <script> markers that
 * already exist in the file. Nothing is retyped, so nothing can be mistyped.
 * That property is the entire point — hand-transcribing 2,200 lines is the
 * error source this refactor exists to remove.
 *
 *   node split.js farroad-prototype-v0.9.html
 * =========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');

const srcFile = process.argv[2] || 'farroad-prototype-v0.9.html';
const outDir  = path.join(__dirname, 'src');
const html    = fs.readFileSync(srcFile, 'utf8');

/* The three script blocks, identified by the id attributes already present.
   The UI block is the only unlabelled <script>, so it is matched last by
   exclusion rather than by a marker we would have to add. */
function sliceTagged(id) {
  const open = `<script id="${id}">`;
  const i = html.indexOf(open);
  if (i < 0) throw new Error(`missing <script id="${id}">`);
  const start = i + open.length;
  const end = html.indexOf('</script>', start);
  if (end < 0) throw new Error(`unterminated <script id="${id}">`);
  return { body: html.slice(start, end), from: i, to: end + '</script>'.length };
}

const core = sliceTagged('farroad-core');
const prog = sliceTagged('farroad-progression');

/* UI = the first untagged <script> after the progression block */
const uiOpen = html.indexOf('<script>', prog.to);
if (uiOpen < 0) throw new Error('missing UI <script>');
const uiStart = uiOpen + '<script>'.length;
const uiEnd = html.indexOf('</script>', uiStart);
const ui = { body: html.slice(uiStart, uiEnd), from: uiOpen, to: uiEnd + '</script>'.length };

/* The shell is everything that is not a script block: doctype, head, CSS, body
   markup, and the closing tags. Placeholders mark where build.js re-inserts. */
const shell =
  html.slice(0, core.from) +
  '<!--@@CORE@@-->' +
  html.slice(core.to, prog.from) +
  '<!--@@PROGRESSION@@-->' +
  html.slice(prog.to, ui.from) +
  '<!--@@UI@@-->' +
  html.slice(ui.to);

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'farroad-core.js'), core.body);
fs.writeFileSync(path.join(outDir, 'farroad-progression.js'), prog.body);
fs.writeFileSync(path.join(outDir, 'farroad-ui.js'), ui.body);
fs.writeFileSync(path.join(outDir, 'shell.html'), shell);

console.log('split ->');
console.log('  src/farroad-core.js         ' + core.body.split('\n').length + ' lines');
console.log('  src/farroad-progression.js  ' + prog.body.split('\n').length + ' lines');
console.log('  src/farroad-ui.js           ' + ui.body.split('\n').length + ' lines');
console.log('  src/shell.html              ' + shell.split('\n').length + ' lines');
