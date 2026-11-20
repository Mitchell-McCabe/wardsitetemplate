// Public site configuration. The publishable key is safe to publish: the database only
// exposes the roll functions to it (see supabase/schema.sql). Admin actions
// additionally require the passphrase.
//
window.NP_CONFIG = {
  wardName: 'Your Ward',
  supabaseUrl: '',
  supabaseAnonKey: '',
  timeZone: 'America/New_York',
  // Optional legacy announcement and calendar integration. Bishopric alerts use their own script.
  sheetsRefreshUrl: '',
  // Community links shown on the home page (leave a value empty to hide it).
  links: {
    facebook: '',
    whatsapp: '',
    // Ward text list: opens a text to this number with the message started for them.
    textList: { number: '', body: 'Please add me to the ward text list. My name is ' },
  },
};
