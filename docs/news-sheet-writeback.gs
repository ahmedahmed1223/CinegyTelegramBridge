/**
 * news-sheet-writeback.gs — Google Apps Script web app that lets the bridge
 * write the published ticker back into the sheet it reads from.
 *
 * WHY A SCRIPT AND NOT THE SHEETS API
 * The Sheets API needs OAuth or a service-account key plus RS256 JWT signing,
 * none of which PowerShell does without pulling in a library. A deployed web
 * app is one HTTPS POST with a shared secret.
 *
 * SETUP
 *  1. Open the sheet → Extensions → Apps Script.
 *  2. Replace the contents of Code.gs with this file.
 *  3. Change SECRET below to a long random string of your own.
 *  4. Check SHEET_NAME and START_ROW match your sheet.
 *  5. Deploy → New deployment → type "Web app".
 *       Execute as:      Me
 *       Who has access:  Anyone
 *     "Anyone" is why SECRET matters: the URL is reachable without a Google
 *     login, and the token is the only thing standing between it and a
 *     stranger rewriting your ticker. Treat the URL as a secret too.
 *  6. Copy the deployment URL into config.json:
 *       "NewsSheetWriteUrl":   "https://script.google.com/macros/s/..../exec"
 *       "NewsSheetWriteToken": "the same SECRET"
 *     Both live at the top level of config.json, beside BotToken, and never
 *     inside "Settings" — the bridge's settings export writes only Settings
 *     keys, so keeping them out is what keeps them out of a forwarded export.
 *  7. Restart the bridge.
 *
 * BEHAVIOUR
 * Replaces column A from START_ROW down with the published headlines, then
 * clears whatever used to sit below them. Other columns are untouched, so any
 * editor notes kept in column B survive.
 */

var SECRET = 'CHANGE_ME_TO_A_LONG_RANDOM_STRING';
var SHEET_NAME = 'Sheet1';  // the tab the bridge reads (gid=0 is the first tab)
var START_ROW = 1;          // 2 if the sheet has a header row

function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) {
      return reply({ ok: false, error: 'empty request' });
    }

    var body = JSON.parse(e.postData.contents);

    // Never echo the token back in any branch.
    if (!body.token || body.token !== SECRET) {
      return reply({ ok: false, error: 'bad token' });
    }

    var items = body.items || [];
    if (!Array.isArray(items)) {
      return reply({ ok: false, error: 'items must be an array' });
    }

    var sheet = SpreadsheetApp.getActive().getSheetByName(SHEET_NAME);
    if (!sheet) {
      return reply({ ok: false, error: 'no sheet named ' + SHEET_NAME });
    }

    // A lock because two publishes seconds apart would otherwise interleave a
    // write with a clear and leave the sheet half written.
    var lock = LockService.getScriptLock();
    lock.waitLock(20000);
    try {
      var lastRow = sheet.getLastRow();

      if (items.length > 0) {
        var values = items.map(function (item) { return [String(item)]; });
        sheet.getRange(START_ROW, 1, values.length, 1).setValues(values);
      }

      // Clear only what the new list did not cover, and only column A.
      var firstStale = START_ROW + items.length;
      if (lastRow >= firstStale) {
        sheet.getRange(firstStale, 1, lastRow - firstStale + 1, 1).clearContent();
      }

      SpreadsheetApp.flush();
      return reply({ ok: true, written: items.length });
    } finally {
      lock.releaseLock();
    }
  } catch (err) {
    return reply({ ok: false, error: String(err) });
  }
}

function doGet() {
  // The bridge only ever POSTs. Answering GET with the same shape means a
  // browser visit shows the deployment is alive without leaking anything.
  return reply({ ok: false, error: 'post only' });
}

function reply(payload) {
  return ContentService
    .createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}
