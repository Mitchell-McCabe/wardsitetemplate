window.NPProgram = (function () {
  const { el, rpc } = NP;
  function template() {
    return ['Opening Hymn', 'Invocation', 'Announcements', 'Sacrament Hymn', 'Administration of the Sacrament', 'Speaker', 'Intermediate Hymn', 'Speaker', 'Closing Hymn', 'Benediction'].map(label => ({ label, number: '', details: '' }));
  }
  function render(box, program) {
    const article = el('article', { class: 'program-paper' }, [
      el('p', { class: 'program-ward' }, NP.C.wardName || 'Your Ward'),
      el('h2', { class: 'program-title' }, 'Sacrament Meeting Program'),
      el('p', { class: 'program-date' }, NP.fmtDate(program.meeting_date, { year: 'numeric' })),
    ]);
    for (const item of program.items || []) {
      article.appendChild(el('section', { class: 'program-item' }, [
        el('h3', {}, item.label), item.number ? el('p', { class: 'program-number' }, item.number) : null,
        item.details ? el('p', { class: 'program-details' }, item.details) : null,
      ]));
    }
    box.replaceChildren(article);
  }
  function mountHome(link) {
    let timer, busy = false;
    async function refresh() {
      if (busy) return; busy = true; clearTimeout(timer);
      try {
        const status = await rpc('program_status');
        link.hidden = !status || !status.active;
        let wait = 30000;
        if (status) {
          const now = Date.parse(status.server_now);
          const edge = Date.parse(status.active ? status.closes_at : status.opens_at);
          if (edge > now) wait = Math.min(wait, edge - now + 25);
        }
        const closeOnTick = status && status.active && Date.parse(status.closes_at) - Date.parse(status.server_now) <= wait;
        timer = setTimeout(() => { if (closeOnTick) link.hidden = true; refresh(); }, wait);
      } catch (e) { link.hidden = true; timer = setTimeout(refresh, 30000); }
      finally { busy = false; }
    }
    document.addEventListener('visibilitychange', () => { if (!document.hidden) { link.hidden = true; refresh(); } });
    refresh();
  }
  async function mountReader(box) {
    let timer, signature = '';
    const unavailable = () => { signature = ''; box.replaceChildren(el('div', { class: 'card program-unavailable' }, [el('h2', {}, 'Program not available right now'), el('p', {}, 'The program is available during the meeting’s scheduled time.'), el('a', { class: 'btn secondary', href: 'index.html' }, 'Back to home')])); };
    async function refresh() {
      clearTimeout(timer);
      try {
        const program = await rpc('program_public');
        if (!program) { unavailable(); timer = setTimeout(refresh, 30000); return; }
        const next = JSON.stringify(program.items) + program.meeting_date;
        if (next !== signature) { render(box, program); signature = next; }
        const remaining = Math.max(0, Date.parse(program.closes_at) - Date.parse(program.server_now));
        timer = setTimeout(() => { if (remaining <= 30000) unavailable(); refresh(); }, Math.min(30000, remaining + 25));
      } catch (e) {
        signature = ''; box.replaceChildren(el('div', { class: 'card program-unavailable' }, [el('h2', {}, 'Could not load the program'), el('p', {}, e.message), el('button', { class: 'btn secondary', type: 'button', onclick: refresh }, 'Try again')]));
        timer = setTimeout(refresh, 30000);
      }
    }
    document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
    await NP.loadSiteSettings(); document.getElementById('program-ward').textContent = NP.C.wardName || 'Your Ward';
    await refresh();
  }
  return { template, render, mountHome, mountReader };
})();
