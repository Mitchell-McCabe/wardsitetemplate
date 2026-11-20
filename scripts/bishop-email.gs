// Standalone Google Apps Script. Add project Script Properties SUPABASE_URL,
// SUPABASE_PUBLISHABLE_KEY, BISHOP_EMAIL_WORKER_KEY, and LEADERS_INBOX_URL.
// Run installBishopEmailTrigger once from the site-owned Google account.
function installBishopEmailTrigger() {
  bishopEmailConfig_();
  MailApp.getRemainingDailyQuota(); // authorize mail sending during setup
  const handler = 'sendBishopRequestAlerts';
  if (!ScriptApp.getProjectTriggers().some(t => t.getHandlerFunction() === handler)) {
    ScriptApp.newTrigger(handler).timeBased().everyMinutes(5).create();
  }
}

function bishopEmailConfig_() {
  const p = PropertiesService.getScriptProperties().getProperties();
  for (const key of ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','BISHOP_EMAIL_WORKER_KEY','LEADERS_INBOX_URL']) {
    if (!String(p[key] || '').trim()) throw new Error('Missing script property: ' + key);
    p[key] = p[key].trim();
  }
  if (!/^https:\/\//.test(p.SUPABASE_URL) || !/^https:\/\//.test(p.LEADERS_INBOX_URL)) throw new Error('Use HTTPS URLs.');
  return p;
}

function sendBishopRequestAlerts() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return;
  try {
    const p = bishopEmailConfig_();
    function call(name, args) {
      const response = UrlFetchApp.fetch(p.SUPABASE_URL.replace(/\/$/,'') + '/rest/v1/rpc/' + name, {
        method:'post', contentType:'application/json', muteHttpExceptions:true,
        headers:{ apikey:p.SUPABASE_PUBLISHABLE_KEY },
        payload:JSON.stringify(Object.assign({ p_key:p.BISHOP_EMAIL_WORKER_KEY }, args)),
      });
      if (response.getResponseCode() >= 300) throw new Error(name + ' failed (' + response.getResponseCode() + ').');
      return JSON.parse(response.getContentText());
    }
    let quota = Math.min(20, MailApp.getRemainingDailyQuota());
    while (quota-- > 0) {
      const item = call('bishop_email_claim', {})[0];
      if (!item) break;
      const args = { p_id:item.request_id, p_claim:item.claim_id };
      try {
        MailApp.sendEmail(item.recipient, 'New bishopric meeting request',
          'A new bishopric meeting request is waiting in Leaders → Inbox. Sign in to see the details.\n\n' + p.LEADERS_INBOX_URL);
      } catch (error) {
        call('bishop_email_finish', Object.assign({ p_sent:false }, args));
        throw error;
      }
      if (!call('bishop_email_finish', Object.assign({ p_sent:true }, args))) throw new Error('Could not confirm the email alert.');
    }
  } finally { lock.releaseLock(); }
}
