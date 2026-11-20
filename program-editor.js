window.NPProgramEditor = (function () {
  const { el, rpc } = NP;
  const $ = id => document.getElementById(id);
  let getPass, items = [], loadedDate = '', dirty = false, loading = false;
  function dateToday() { return new Intl.DateTimeFormat('en-CA', { timeZone: NP.C.timeZone }).format(new Date()); }
  function nextSunday() { const date = new Date(dateToday() + 'T12:00:00Z'); date.setUTCDate(date.getUTCDate() + (7 - date.getUTCDay()) % 7); return date.toISOString().slice(0, 10); }
  function renderItems(focusIndex) {
    const box = $('program-items'); box.replaceChildren();
    items.forEach((item, index) => {
      const id = 'program-item-' + index;
      const label = el('input', { id: id + '-label', type: 'text', maxlength: 100, value: item.label, required: '', oninput: e => { item.label = e.target.value; dirty = true; } });
      const number = el('input', { id: id + '-number', type: 'text', maxlength: 12, value: item.number, placeholder: 'Optional', oninput: e => { item.number = e.target.value; dirty = true; } });
      const details = el('textarea', { id: id + '-details', maxlength: 1500, rows: 2, placeholder: 'Hymn title, speaker’s name, performers, or other details', oninput: e => { item.details = e.target.value; dirty = true; } }); details.value = item.details;
      const move = delta => { [items[index], items[index + delta]] = [items[index + delta], items[index]]; dirty = true; renderItems(index + delta); };
      box.appendChild(el('section', { class: 'program-edit-item' }, [
        el('div', { class: 'program-item-toolbar' }, [el('b', {}, 'Item ' + (index + 1)),
          el('button', { type: 'button', class: 'chip', disabled: index === 0 ? '' : null, 'aria-label': 'Move item ' + (index + 1) + ' up', onclick: () => move(-1) }, '↑'),
          el('button', { type: 'button', class: 'chip', disabled: index === items.length - 1 ? '' : null, 'aria-label': 'Move item ' + (index + 1) + ' down', onclick: () => move(1) }, '↓'),
          el('button', { type: 'button', class: 'chip danger', onclick: () => { items.splice(index, 1); dirty = true; renderItems(Math.min(index, items.length - 1)); } }, 'Remove'),
        ]),
        el('div', { class: 'program-item-fields' }, [
          el('div', { class: 'field' }, [el('label', { for: id + '-label' }, 'Heading'), label]),
          el('div', { class: 'field' }, [el('label', { for: id + '-number' }, 'Hymn number'), number]),
        ]),
        el('div', { class: 'field' }, [el('label', { for: id + '-details' }, 'Details'), details]),
      ]));
    });
    if (!items.length) box.appendChild(el('p', { class: 'muted' }, 'Add an item to start the program.'));
    if (focusIndex >= 0) $( 'program-item-' + focusIndex + '-label')?.focus({ preventScroll: true });
  }
  async function load(date) {
    if (loading) return;
    date = date || $('program-date').value || nextSunday();
    $('program-date').value = date; $('program-date').disabled = true; loading = true;
    $('program-save').disabled = true; $('program-msg').textContent = 'Loading…';
    try {
      const program = await rpc('admin_program_get', { p_pass: getPass(), p_date: date });
      items = program ? program.items : NPProgram.template();
      $('program-start').value = program ? program.start_time.slice(0, 5) : '';
      $('program-end').value = program ? program.end_time.slice(0, 5) : '';
      $('program-published').checked = !!program?.published;
      loadedDate = date; dirty = false; $('program-preview').hidden = true; renderItems();
      $('program-msg').textContent = program ? 'Saved program loaded.' : 'New program. Add the meeting times and details, then save.';
    } catch (e) { $('program-msg').textContent = 'Could not load program: ' + e.message; }
    finally { loading = false; $('program-date').disabled = false; $('program-save').disabled = !loadedDate || loadedDate !== $('program-date').value; }
  }
  function init(ctx) {
    getPass = ctx.getPass;
    document.querySelector('.tab[data-pane=program]').addEventListener('click', () => { if (!loadedDate) load(); });
    $('program-date').value = nextSunday();
    $('program-date').addEventListener('change', () => {
      if (dirty && !confirm('Discard unsaved program changes and open another date?')) { $('program-date').value = loadedDate; return; }
      if ($('program-date').value) load($('program-date').value);
    });
    ['program-start', 'program-end', 'program-published'].forEach(id => $(id).addEventListener('change', () => { dirty = true; }));
    $('program-add').addEventListener('click', () => { if (items.length >= 40) { $('program-msg').textContent = 'The program can have up to 40 items.'; return; } items.push({ label: '', number: '', details: '' }); dirty = true; renderItems(items.length - 1); });
    $('program-reset').addEventListener('click', () => { if (confirm('Replace the program items with a blank standard order?')) { items = NPProgram.template(); dirty = true; renderItems(); } });
    $('program-preview-button').addEventListener('click', () => {
      if (!$('program-date').value) return;
      NPProgram.render($('program-preview'), { meeting_date: $('program-date').value, items }); $('program-preview').hidden = false;
      $('program-preview').scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
    $('program-form').addEventListener('submit', async e => {
      e.preventDefault(); const msg = $('program-msg'), button = $('program-save');
      if (!loadedDate || loadedDate !== $('program-date').value) { msg.textContent = 'Load the selected date before saving.'; return; }
      if ($('program-end').value <= $('program-start').value) { msg.textContent = 'The end time must be later than the start time.'; return; }
      button.disabled = true; msg.textContent = 'Saving…';
      try {
        await rpc('admin_program_save', { p_pass: getPass(), p_date: $('program-date').value, p_start: $('program-start').value, p_end: $('program-end').value, p_published: $('program-published').checked, p_items: items.map(i => ({ label: i.label.trim(), number: i.number.trim(), details: i.details.trim() })) });
        dirty = false; msg.textContent = $('program-published').checked ? 'Saved. The home-page button will appear only during this meeting’s scheduled time.' : 'Draft saved. The program is not visible to members.';
      } catch (e) { msg.textContent = 'Not saved: ' + e.message; }
      finally { button.disabled = false; }
    });
    window.addEventListener('beforeunload', e => { if (dirty) { e.preventDefault(); e.returnValue = ''; } });
  }
  return { init, load };
})();
