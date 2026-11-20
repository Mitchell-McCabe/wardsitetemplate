// Private LCR report snapshots and the Without Calling meeting list.
window.NPLcrReports = (() => {
  let reports = {}, pending = null, loaded = false;
  const keys = new Set(['lcr_test_members', 'lcr_without_calling', 'lcr_moved_in', 'lcr_sacrament', 'lcr_converts']);
  async function load(pass, force) {
    if (pending) return pending;
    if (loaded && !force) return reports;
    pending = NP.rpc('admin_sheets', { p_pass: pass }).then(rows => {
      reports = Object.fromEntries(rows.filter(r => keys.has(r.key)).map(r => [r.key, r]));
      loaded = true;
      return reports;
    }).finally(() => { pending = null; });
    return pending;
  }
  return { load, data: () => reports };
})();

window.NPWithoutCalling = (() => {
  const { C, el } = NP;
  const $ = id => document.getElementById(id);
  let ctx, filter = 'all', visible = [], deck = [], at = 0, returnFocus;
  const filters = [
    ['all', 'Everyone'], ['none', 'Nothing proposed'], ['proposed', 'Proposed'],
    ['contacted', 'Waiting for an answer'], ['accepted', 'Accepted'],
    ['sustained', 'Sustained'], ['set_apart', 'Set apart'], ['dropped', 'Closed'],
  ];
  const matches = (id, stage) => id === 'all' || id === (stage?.key || 'none');
  const searchKey = text => String(text || '').normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
  function details(member) {
    const pending = NPPipeline.openFor(member);
    const record = pending || NPPipeline.historyFor(member).find(r => r.calling);
    return { record, badge: record ? NPPipeline.stage(record) : null };
  }
  function rowBadge(info) {
    return el('span', { class: 'pill ' + (info.badge?.k || 'off') }, info.badge?.label || 'Nothing yet');
  }
  function lcrLink(member) {
    const url = ctx.profile(member);
    return url ? el('a', { class: 'muted small wc-profile', href: url, target: '_blank', rel: 'noopener noreferrer' }, 'View in LCR ↗') : null;
  }
  function render() {
    const sheet = NPLcrReports.data().lcr_without_calling;
    const canShowStatus = !NPPipeline.data().unavailable;
    const entries = ctx.getEntries().map(member => ({ member, info: canShowStatus ? details(member) : {} }));
    if (!canShowStatus) filter = 'all';
    const q = searchKey($('cal-search').value.trim());
    const searched = entries.filter(({ member }) => !q || searchKey(member.name + ' ' + member.display_name).includes(q));
    visible = searched.filter(({ info }) => matches(filter, info.badge)).map(({ member }) => member);
    $('cal-meta').textContent = sheet ? entries.length + ' without a calling · LCR updated ' +
      new Date(sheet.updated_at).toLocaleString('en-US', { timeZone: C.timeZone, month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
    $('cal-start').disabled = !visible.length;
    $('cal-filters').replaceChildren(...(sheet ? filters : []).flatMap(([id, label]) => {
      const count = searched.filter(({ info }) => matches(id, info.badge)).length;
      return (count || id === filter || id === 'all') && (canShowStatus || id === 'all') ? [el('button', {
        class: 'chip' + (id === filter ? ' on' : ''), type: 'button', 'aria-pressed': String(id === filter),
        onclick: () => { filter = id; render(); },
      }, label + ' · ' + count)] : [];
    }));
    const children = !sheet ? [el('p', { class: 'empty' }, ['Run the LCR Sync extension to populate this list with ward members ages 12 and older who have no calling in LCR. ', el('a', { href: '#sync', onclick: e => { e.preventDefault(); ctx.openSync(); } }, 'Open LCR sync')])]
      : !entries.length ? [el('p', { class: 'empty' }, 'LCR lists no ward members ages 12 and older without a calling.')]
      : !visible.length ? [el('p', { class: 'empty' }, 'No members match this search and filter.')]
      : [el('ul', { class: 'cal-list wc-list' }, visible.map((member, i) => {
        const info = canShowStatus ? details(member) : {};
        return el('li', { class: 'wc-row' }, [
          el('button', { class: 'cal-item wc-person', type: 'button', onclick: e => openDeck(i, e.currentTarget) }, [
            el('span', { class: 'cal-item-main' }, [el('b', {}, member.display_name), canShowStatus ? rowBadge(info) : null,
              info.record?.calling ? el('span', { class: 'muted small' }, info.record.calling) : null]),
            el('span', { class: 'muted', 'aria-hidden': 'true' }, '›'),
          ]),
          lcrLink(member),
        ]);
      }))];
    if (!canShowStatus) children.unshift(el('p', { class: 'notice' }, 'Could not load calling proposals. Use Refresh to try again.'));
    $('cal-list').replaceChildren(...children);
    if (!$('deck').hidden) drawSlide();
  }
  async function refresh() {
    $('cal-refresh').disabled = true;
    try {
      await Promise.all([ctx.loadReports(true), NPPipeline.load(true)]);
      render();
    } catch (e) {
      $('cal-list').replaceChildren(el('p', { class: 'notice', role: 'alert' }, 'Could not load Without Calling. Use Refresh to try again.'));
    } finally { $('cal-refresh').disabled = false; }
  }
  function drawSlide() {
    const person = ctx.getEntries().find(m => m.id === deck[at]?.id) || deck[at];
    if (!person) return;
    const { record, badge } = details(person);
    const open = NPPipeline.openFor(person);
    const completed = !open && badge?.key === 'set_apart' ? record : null;
    $('deck-pos').textContent = (at + 1) + ' / ' + deck.length;
    $('deck-jump').value = String(at);
    $('deck-prev').disabled = at === 0;
    $('deck-next').disabled = at === deck.length - 1;
    $('deck-slide').replaceChildren(el('article', { class: 'card wc-slide-card' }, [
      el('h2', { id: 'wc-meeting-person' }, person.display_name),
      lcrLink(person),
      el('p', { class: 'wc-slide-stage' }, [rowBadge({ badge }), record?.calling ? ' ' + record.calling : null]),
      record?.contact ? el('p', {}, 'Who contacts: ' + record.contact) : null,
      record?.notes ? el('p', { class: 'muted' }, record.notes) : null,
      el('button', { class: 'btn small', type: 'button', onclick: () => ctx.openEditor(person, open) },
        open ? 'Edit calling' : 'Propose calling'),
      completed ? el('button', { class: 'btn small secondary', type: 'button', onclick: () => ctx.openEditor(person, completed) }, 'Open completed proposal') : null,
    ]));
  }
  function openDeck(index, focus) {
    if (!visible.length) return;
    deck = visible.slice(); at = index; returnFocus = focus;
    $('deck-jump').replaceChildren(...deck.map((m, i) => el('option', { value: i }, m.display_name)));
    $('deck').hidden = false; document.body.classList.add('deck-open');
    drawSlide(); $('deck-close').focus();
  }
  function closeDeck() {
    $('deck').hidden = true; document.body.classList.remove('deck-open');
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    (returnFocus?.isConnected ? returnFocus : $('cal-start')).focus();
  }
  function step(delta) {
    const next = at + delta;
    if (next >= 0 && next < deck.length) { at = next; drawSlide(); }
  }
  function init(context) {
    ctx = context;
    $('cal-search').addEventListener('input', render);
    $('cal-refresh').addEventListener('click', refresh);
    $('cal-start').addEventListener('click', e => openDeck(0, e.currentTarget));
    $('deck-close').addEventListener('click', closeDeck);
    $('deck-prev').addEventListener('click', () => step(-1));
    $('deck-next').addEventListener('click', () => step(1));
    $('deck-jump').addEventListener('change', e => { at = Number(e.target.value); drawSlide(); });
    $('deck-full').addEventListener('click', () => {
      const action = document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.();
      action?.catch(() => {});
    });
    document.addEventListener('keydown', e => {
      if ($('deck').hidden || document.querySelector('.pipe-modal')) return;
      if (e.key === 'Escape') { e.preventDefault(); closeDeck(); }
      if (e.target.closest('input,textarea,select')) return;
      if (e.key === 'ArrowLeft') { e.preventDefault(); step(-1); }
      if (e.key === 'ArrowRight') { e.preventDefault(); step(1); }
    });
  }
  return { init, render, refresh };
})();
