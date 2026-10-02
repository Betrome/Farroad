/**
 * Farroad gameplay stats receiver -- a Google Apps Script web app bound to
 * a Google Sheet. The game POSTs one JSON report per player per day; each
 * becomes a row in the "reports" sheet. The parser (farroad_analytics.py)
 * reads the rows back with a private read key.
 *
 * Setup (once):
 *  1. Make a new Google Sheet. Extensions > Apps Script. Paste this file.
 *  2. Project Settings > Script properties: add READ_KEY = a long random
 *     string of your own (keep it private; don't put it in the repo).
 *  3. Deploy > New deployment > Web app. Execute as: Me. Who has access:
 *     Anyone. Copy the /exec URL -- that goes in the game (Analytics.gd).
 */
var SHEET = 'reports';
var MAX_CHARS = 50000;

function sheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(SHEET);
  if (!sh) {
    sh = ss.insertSheet(SHEET);
    sh.appendRow(['received', 'id', 'version', 'platform', 'from', 'to', 'report']);
    sh.setFrozenRows(1);
  }
  return sh;
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

function doPost(e) {
  try {
    var body = e && e.postData ? e.postData.contents : '';
    if (!body || body.length > MAX_CHARS) return json_({ ok: false, error: 'size' });
    var r = JSON.parse(body);
    if (!r || r.schema !== 1 || typeof r.id !== 'string' || r.id.length > 32 || !r.counters || !r.snapshot) {
      return json_({ ok: false, error: 'shape' });
    }
    var lock = LockService.getScriptLock();
    lock.waitLock(10000);
    try {
      sheet_().appendRow([new Date(), r.id, String(r.version).slice(0, 16), String(r.platform).slice(0, 16),
        Number(r.from) || 0, Number(r.to) || 0, body]);
    } finally {
      lock.releaseLock();
    }
    return json_({ ok: true });
  } catch (err) {
    return json_({ ok: false, error: 'parse' });
  }
}

/** Read rows back: ?key=READ_KEY[&after=N] -> rows after row N (1 = header). */
function doGet(e) {
  var key = PropertiesService.getScriptProperties().getProperty('READ_KEY');
  if (!key || !e || !e.parameter || e.parameter.key !== key) return json_({ ok: false, error: 'denied' });
  var sh = sheet_();
  var last = sh.getLastRow();
  var after = Math.max(1, parseInt(e.parameter.after || '1', 10) || 1);
  var limit = 2000;
  if (last <= after) return json_({ ok: true, rows: [], last: last });
  var n = Math.min(limit, last - after);
  var values = sh.getRange(after + 1, 1, n, 7).getValues();
  var rows = values.map(function (v) { return { received: v[0], report: v[6] }; });
  return json_({ ok: true, rows: rows, last: after + n, more: after + n < last });
}
