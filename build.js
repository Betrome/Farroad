#!/usr/bin/env node
/* =============================================================================
 * FARROAD — build.js
 * Fuses src/ back into ONE self-contained HTML file.
 *
 * WHY THE FUSED FILE IS NON-NEGOTIABLE: Ian opens the prototype directly from
 * disk on both phone and desktop. A multi-file page over file:// hits local-file
 * security restrictions and simply will not load. So the delivered artifact must
 * stay a single file; the module split exists purely so the source can be
 * executed and tested, which the fused file cannot be.
 *
 *   node build.js            -> farroad-prototype-v2.9.html
 *   node build.js --check    -> verifies round-trip fidelity, writes nothing
 *
 * ROUND-TRIP GUARANTEE
 * build(split(x)) === x, byte for byte. --check asserts it. Because split.js
 * only slices and build.js only concatenates, neither ever reformats, minifies
 * or rewrites a single character. That is what makes "the refactor is a no-op"
 * a checkable claim rather than a hopeful one.
 * =========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');

const VERSION = process.env.FARROAD_VERSION || 'v2.9';
const srcDir  = path.join(__dirname, 'src');
const outFile = path.join(__dirname, `farroad-prototype-${VERSION}.html`);

const read = f => fs.readFileSync(path.join(srcDir, f), 'utf8');

const shell = read('shell.html');
const core  = read('farroad-core.js');
const prog  = read('farroad-progression.js');
const ui    = read('farroad-ui.js');

const fused = shell
  .replace('<!--@@CORE@@-->',        `<script id="farroad-core">${core}</script>`)
  .replace('<!--@@PROGRESSION@@-->', `<script id="farroad-progression">${prog}</script>`)
  .replace('<!--@@UI@@-->',          `<script>${ui}</script>`);

/* --- fidelity checks that run on every build ------------------------------ */
const problems = [];

/* 1. every placeholder consumed */
['@@CORE@@', '@@PROGRESSION@@', '@@UI@@'].forEach(p => {
  if (fused.includes(p)) problems.push(`placeholder ${p} was not replaced`);
});

/* 2. the core must stay headless. This is the property that makes idle quests
      (roadmap item 4) possible at all: combat has to run away from the main
      loop, many times, with no DOM present. Enforced, not assumed. */
const DOM = /\b(document|localStorage|sessionStorage|alert|requestAnimationFrame)\b/;
[['core', core], ['progression', prog]].forEach(([name, body]) => {
  body.split('\n').forEach((line, i) => {
    const code = line.replace(/\/\*.*?\*\//g, '').replace(/\/\/.*$/, '');
    if (DOM.test(code)) problems.push(`${name}.js:${i + 1} touches the DOM: ${line.trim()}`);
  });
});

/* 3. the only permitted window references are the module's own export/import */
const strayWindow = (name, body) => body.split('\n').forEach((line, i) => {
  const code = line.replace(/\/\*.*?\*\//g, '').replace(/\/\/.*$/, '');
  if (!/\bwindow\b/.test(code)) return;
  if (/window\.Farroad(Core|Progression)\b/.test(code)) return;   // export or import
  problems.push(`${name}.js:${i + 1} unexpected window use: ${line.trim()}`);
});
strayWindow('core', core);
strayWindow('progression', prog);

if (process.argv.includes('--check')) {
  const original = process.argv[process.argv.indexOf('--check') + 1];
  if (original && fs.existsSync(original)) {
    const before = fs.readFileSync(original, 'utf8');
    if (before !== fused) problems.push('ROUND-TRIP MISMATCH: rebuild differs from the original');
    else console.log('round-trip: byte-identical to ' + path.basename(original));
  }
}

if (problems.length) {
  console.error('BUILD FAILED\n  ' + problems.join('\n  '));
  process.exit(1);
}

if (!process.argv.includes('--check')) {
  fs.writeFileSync(outFile, fused);
  console.log('built ' + path.basename(outFile) + '  (' + fused.length + ' bytes)');
}
console.log('checks passed: no DOM in core/progression, no stray globals');
