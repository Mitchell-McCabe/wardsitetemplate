// Leaders: one proposal pipeline shared by Members, Without Calling, and Overview.
window.NPPipeline = (function () {
  const { C, rpc, el, toast } = NP;
  let ctx = null, rows = [], loaded = false, loading = null, unavailable = '';

  const truthy = v => !!String(v || '').trim();
  const todayIso = () => new Intl.DateTimeFormat('en-CA', { timeZone: C.timeZone }).format(new Date());
  const fmtDay = iso => iso ? new Date(String(iso).slice(0, 10) + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : '';
  const firstLast = n => { const [last, rest] = String(n || '').split(/,\s*/); return rest ? (rest.split(' ')[0] + ' ' + last).trim() : String(n || ''); };

  // ---------- where a row is ----------
  // { key, label, k (pill class), next (what happens next, for the editor) }
  function stage(r) {
    if (r.status === 'dropped') return { key: 'dropped', label: r.accepted === 'no' ? 'Declined' : 'Withdrawn', k: 'off' };
    if (!r.calling && r.release_from) return { key: r.status === 'done' ? 'released' : 'release', label: r.status === 'done' ? 'Released' : 'To be released', k: r.status === 'done' ? 'ok' : 'wait' };
    if (r.set_apart_at) return { key: 'set_apart', label: 'Set apart', k: 'ok' };
    if (r.sustained_at) return { key: 'sustained', label: 'Sustained', k: 'ok', next: 'to be set apart' };
    if (r.accepted === 'yes') return { key: 'accepted', label: 'Accepted', k: 'ok', next: 'to be sustained' };
    if (r.accepted === 'no') return { key: 'declined', label: 'Declined', k: 'need' };
    if (r.contacted_at) return { key: 'contacted', label: 'Contacted', k: 'wait', next: 'waiting on an answer' };
    // "who contacts" is information, not a step: assigned or not, the calling is still just proposed
    return { key: 'proposed', label: 'Proposed', k: 'wait', next: truthy(r.contact) ? r.contact + ' contacts them' : 'nobody assigned to contact them yet' };
  }
  // ---------- lookups ----------
  const isMine = (r, m) => !!r.imported_roster === !!m.imported && ((r.member_id && r.member_id === m.id) || (r.lcr_uuid && m.lcr_uuid && r.lcr_uuid === m.lcr_uuid));
  function openFor(m) { return rows.find(r => r.status === 'open' && isMine(r, m)) || null; }
  function historyFor(m) { return rows.filter(r => r.status !== 'open' && isMine(r, m)); }
  // ---------- data ----------
  async function load(force) {
    if (loaded && !force) return;
    if (loading) return loading;
    loading = (async () => {
      try { rows = (await rpc('admin_pipeline', { p_pass: ctx.getPass(), p_include_closed: true })) || []; unavailable = ''; }
      catch (e) { rows = []; unavailable = /admin_pipeline/.test(e.message) ? 'Run supabase/pipeline.sql in Supabase first.' : e.message; }
      loaded = true; loading = null;
    })();
    return loading;
  }
  async function save(values) {
    const id = await rpc(Object.hasOwn(values, 'p_release_from') ? 'admin_pipeline_save_release' : 'admin_pipeline_save', Object.assign({ p_pass: ctx.getPass(), p_id: null, p_member_id: null, p_lcr_uuid: null, p_contact: null, p_contacted_at: null, p_accepted: null, p_accepted_at: null, p_sustained_at: null, p_set_apart_at: null, p_notes: null, p_status: null, p_by: null }, values));
    await load(true);
    return rows.find(r => r.id === id) || null;
  }
  async function step(r, which, date) {
    await rpc('admin_pipeline_step', { p_pass: ctx.getPass(), p_id: r.id, p_step: which, p_date: date || todayIso(), p_by: null });
    await load(true);
  }
  async function remove(r) { await rpc('admin_pipeline_delete', { p_pass: ctx.getPass(), p_id: r.id }); await load(true); }
  // The Members column and its filters use only proposals entered in this site's pipeline.
  function stageFor(m) {
    const r = openFor(m);
    return r ? Object.assign({ src: 'site', calling: r.calling || r.release_from, contact: r.contact || '' }, stage(r)) : null;
  }
  // One line per person for pasting into a text or meeting notes: "First Last — calling — who contacts".
  function copyLines(members, stageOf) {
    return members.map(m => [m, stageOf.get(m.id)]).filter(([, st]) => st)
      .map(([m, st]) => `${m.display_name || firstLast(m.name)} — ${st.calling} — ${st.contact || 'nobody assigned'}`);
  }
  // The chips, in process order. `test` gets the member and their stage (or null).
  const GROUPS = [
    ['all', 'Everyone', () => true],
    ['proposed', 'Proposed', (m, st) => !!st && st.key === 'proposed'],
    ['contacted', 'Waiting on an answer', (m, st) => !!st && (st.key === 'contacted' || st.key === 'answered')],
    ['accepted', 'Accepted · to be sustained', (m, st) => !!st && st.key === 'accepted'],
    ['sustained', 'Sustained · to be set apart', (m, st) => !!st && st.key === 'sustained'],
    ['declined', 'Declined', (m, st) => !!st && st.key === 'declined'],
    ['release', 'To be released', (m, st) => !!st && st.key === 'release'],
    ['done', 'Set apart recently', m => historyFor(m).some(h => h.status === 'done' && h.set_apart_at && (Date.now() - new Date(h.set_apart_at + 'T00:00:00').getTime()) < 90 * 864e5)],
  ];

  // ---------- the Members column ----------
  // A compact line: calling · step pill · who contacts. Tapping it opens the editor (onOpen).
  function cell(m, onOpen) {
    const items = rows.filter(r => r.status === 'open' && isMine(r, m)).map(r => {
      const st = stage(r);
      return el('button', { class: 'pipe-cell', type: 'button', title: 'Edit this proposal', onclick: () => onOpen(r) }, [
        el('b', {}, r.calling || r.release_from), el('span', { class: 'pill ' + st.k }, st.label),
        truthy(r.contact) && st.key !== 'set_apart' ? el('span', { class: 'muted' }, r.contact) : null,
      ]);
    });
    return el('div', { class: 'member-proposals' }, [
      ...items,
      ...historyFor(m).filter(r => r.status === 'done' && r.calling && r.set_apart_at).map(r =>
        el('button', { class: 'pipe-cell', type: 'button', title: 'Open completed proposal', onclick: () => onOpen(r) }, [
          el('b', {}, r.calling), el('span', { class: 'pill ok' }, 'Set apart'),
        ])),
      el('button', { class: 'chip', type: 'button', title: 'Propose a calling', onclick: () => onOpen(null) }, '+ Propose'),
    ]);
  }

  // ---------- the editor ----------
  function editor(m, r, onDone) {
    const v = r || {};
    const date = (id, label, val, hint) => {
      const chk = el('input', { type: 'checkbox', class: 'pipe-chk', id: 'pc-' + id });
      const inp = el('input', { type: 'date', class: 'edit-field pipe-date', id: 'pd-' + id });
      const has = !!val; chk.checked = has; inp.value = has ? (String(val).length === 10 ? val : todayIso()) : ''; inp.hidden = !has;
      chk.addEventListener('change', () => { inp.hidden = !chk.checked; if (chk.checked && !inp.value) inp.value = todayIso(); });
      return { chk, inp, row: el('label', { class: 'edit-row check pipe-step' }, [el('span', {}, label), el('span', { class: 'check-wrap' }, [chk, inp, hint ? el('span', { class: 'muted small' }, hint) : null])]) };
    };
    const calling = el('input', { class: 'edit-field', placeholder: 'e.g. Ward missionary — leave blank for a release only', maxlength: 120 }); calling.value = v.calling || '';
    const release = el('input', { class: 'edit-field', placeholder: 'e.g. Sunday School teacher', maxlength: 120 }); release.value = v.release_from || '';
    const released = el('input', { type: 'checkbox', class: 'pipe-chk' }); released.checked = !v.calling && v.status === 'done';
    const releasedRow = el('label', { class: 'edit-row' }, [el('span', {}, 'Released'), released]);
    const contact = el('input', { class: 'edit-field', placeholder: 'e.g. Bishop Dancy', maxlength: 120 }); contact.value = v.contact || '';
    const contacted = date('contacted', 'Contacted', v.contacted_at);
    const accepted = el('select', { class: 'edit-field' }, [el('option', { value: '' }, 'Not answered yet'), el('option', { value: 'yes' }, 'Yes — accepted'), el('option', { value: 'no' }, 'No — declined')]); accepted.value = v.accepted || '';
    const acceptedAt = el('input', { type: 'date', class: 'edit-field pipe-date' }); acceptedAt.value = v.accepted_at && String(v.accepted_at).length === 10 ? v.accepted_at : (v.accepted ? todayIso() : ''); acceptedAt.hidden = !v.accepted;
    accepted.addEventListener('change', () => { acceptedAt.hidden = !accepted.value; if (accepted.value && !acceptedAt.value) acceptedAt.value = todayIso(); });
    const sustained = date('sustained', 'Sustained', v.sustained_at);
    const setApart = date('setapart', 'Set apart', v.set_apart_at, 'closes it');
    const notes = el('textarea', { class: 'edit-field', rows: 2, placeholder: 'About this calling — who’s extending it, timing, their answer', maxlength: 1000 }); notes.value = v.notes || '';
    const msg = el('span', { class: 'muted', role: 'status' });
    const blocked = unavailable ? 'Could not load the callings pipeline. Close this window and try again.' :
      m.imported && !m.lcr_uuid ? 'Run the current LCR sync to give this roster entry a stable key before saving a calling.' : '';
    msg.textContent = blocked;
    const hist = historyFor(m).filter(entry => entry.id !== r?.id);
    function toggleReleaseOnly() {
      const releaseOnly = !calling.value.trim() && !!release.value.trim();
      releasedRow.hidden = !releaseOnly;
      sustained.row.hidden = setApart.row.hidden = releaseOnly;
    }
    calling.addEventListener('input', toggleReleaseOnly);
    release.addEventListener('input', toggleReleaseOnly);
    toggleReleaseOnly();
    const form = el('form', { class: 'edit-form pipe-form', onsubmit: async e => {
      e.preventDefault();
      if (blocked) return;
      if (!calling.value.trim() && !release.value.trim()) { msg.textContent = 'Enter a proposed calling or a calling to release.'; calling.focus(); return; }
      msg.textContent = 'Saving…';
      try {
        await save({ p_id: r ? r.id : null, p_member_id: m.imported ? null : m.id, p_lcr_uuid: m.lcr_uuid || null, p_by: m.imported ? 'lcr-roster-import' : null, p_name: m.display_name || firstLast(m.name), p_calling: calling.value.trim(), p_release_from: release.value.trim(), p_contact: contact.value.trim() || null,
          p_contacted_at: contacted.chk.checked ? contacted.inp.value || todayIso() : null, p_accepted: accepted.value || null, p_accepted_at: accepted.value ? acceptedAt.value || todayIso() : null,
          p_sustained_at: sustained.chk.checked ? sustained.inp.value || todayIso() : null, p_set_apart_at: setApart.chk.checked ? setApart.inp.value || todayIso() : null, p_notes: notes.value.trim() || null,
          p_status: !calling.value.trim() && released.checked ? 'done' : r && r.status === 'dropped' && accepted.value !== 'no' ? 'open' : null });
        toast(r ? 'Saved' : 'Tracking ' + (m.display_name || firstLast(m.name)) + '’s calling'); onDone(true);
      } catch (err) { msg.textContent = /admin_pipeline/.test(err.message) ? 'Run supabase/pipeline.sql in Supabase first.' : 'Not saved: ' + err.message; }
    } }, [
      el('p', { class: 'muted small pipe-intro' }, 'In order: proposed → contacted → accepted → sustained → set apart. Ticking a later step fills in the earlier ones. For a release only, fill in Release from and leave Proposed calling blank.'),
      el('label', { class: 'edit-row' }, [el('span', {}, 'Proposed calling'), calling]),
      el('label', { class: 'edit-row' }, [el('span', {}, 'Release from'), release]),
      el('label', { class: 'edit-row' }, [el('span', {}, 'Who contacts'), contact]),
      contacted.row,
      el('label', { class: 'edit-row' }, [el('span', {}, 'Accepted'), el('span', { class: 'check-wrap' }, [accepted, acceptedAt])]),
      sustained.row,
      setApart.row,
      releasedRow,
      el('label', { class: 'edit-row' }, [el('span', {}, 'Calling notes'), el('span', {}, [notes, el('span', { class: 'muted small' }, 'Notes about this calling only.')])]),
      el('div', { class: 'edit-actions' }, [
        el('button', { class: 'btn small', type: 'submit', disabled: blocked ? '' : null }, 'Save'),
        r && r.status === 'open' ? el('button', { class: 'btn small secondary', type: 'button', title: 'The calling was withdrawn or they said no — keeps the row, closes it', onclick: async () => { if (!confirm('Close this without finishing it (withdrawn / not going ahead)?')) return; try { await rpc('admin_pipeline_save_release', { p_pass: ctx.getPass(), p_id: r.id, p_member_id: null, p_lcr_uuid: null, p_name: r.name, p_calling: r.calling, p_release_from: r.release_from || '', p_contact: r.contact, p_contacted_at: r.contacted_at, p_accepted: r.accepted, p_accepted_at: r.accepted_at, p_sustained_at: r.sustained_at, p_set_apart_at: null, p_notes: r.notes, p_status: 'dropped', p_by: null }); await load(true); toast('Closed'); onDone(true); } catch (err) { msg.textContent = 'Failed: ' + err.message; } } }, 'Withdraw') : null,
        r ? el('button', { class: 'btn small secondary danger', type: 'button', onclick: async () => { if (!confirm('Delete the proposal for ' + (r.calling || r.release_from) + ' for ' + r.name + '?')) return; try { await remove(r); toast('Deleted'); onDone(true); } catch (err) { msg.textContent = 'Failed: ' + err.message; } } }, 'Delete') : null,
        el('button', { class: 'btn small secondary', type: 'button', onclick: () => onDone(false) }, 'Cancel'),
        msg,
      ]),
      hist.length ? el('p', { class: 'muted small' }, 'Before: ' + hist.map(h => (h.calling || h.release_from) + ' — ' + (h.status === 'done' ? (h.calling ? 'set apart ' + fmtDay(h.set_apart_at) : 'released') : stage(h).label.toLowerCase() + (h.updated_at ? ' ' + fmtDay(h.updated_at) : ''))).join(' · ')) : null,
    ]);
    setTimeout(() => calling.focus(), 0);
    return form;
  }

  // ---------- for Leaders › Overview ----------
  function lists() {
    const open = rows.filter(r => r.status === 'open');
    const byDate = (a, b) => (a.sustained_at || a.accepted_at || '').localeCompare(b.sustained_at || b.accepted_at || '');
    return {
      open,
      toSustain: open.filter(r => stage(r).key === 'accepted').sort(byDate),
      toSetApart: open.filter(r => stage(r).key === 'sustained').sort(byDate),
    };
  }

  function init(c) { ctx = c; }
  function data() { return { rows, loaded, unavailable }; }
  return { init, load, refresh: () => load(true), data, stage, stageFor, GROUPS, copyLines, openFor, historyFor, cell, editor, save, step, remove, lists, fmtDay };
})();
