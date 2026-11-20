(function () {
  const { rpc, el, fmtDate } = NP;
  const $ = id => document.getElementById(id);
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  let info = null, current = null;
  NP.store.del('ward_meal_reservations');
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: NP.C.timeZone }).format(new Date());
  const dateLabel = date => fmtDate(date, { weekday: 'long', month: 'long', day: 'numeric' });
  const plusDays = (date, n) => { const d = new Date(date + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  function showPanel(children) {
    const panel = $('reservation'); panel.replaceChildren(...children); panel.hidden = false;
    panel.focus({ preventScroll: true }); panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  let lookupVersion = 0, matchedPhone = '', selectedAppointment = null, cancelling = false;
  function openCancellation() {
    lookupVersion++; matchedPhone = ''; selectedAppointment = null;
    $('cancel-lookup-form').reset(); $('cancel-matches').replaceChildren(); $('cancel-status').textContent = '';
    $('cancel-sheet').showModal(); document.body.classList.add('signup-open');
  }
  function closeCancellation() { if (!cancelling) $('cancel-sheet').close(); }
  $('cancel-sheet').addEventListener('cancel', e => { if (cancelling) e.preventDefault(); });
  $('open-meal-cancel').addEventListener('click', openCancellation);
  $('close-cancel-sheet').addEventListener('click', closeCancellation);
  $('cancel-sheet').addEventListener('close', () => { document.body.classList.remove('signup-open'); lookupVersion++; });
  $('cancel-phone').addEventListener('input', () => {
    lookupVersion++; matchedPhone = ''; selectedAppointment = null;
    $('cancel-matches').replaceChildren(); $('cancel-status').textContent = '';
  });
  $('cancel-lookup-form').addEventListener('submit', async e => {
    e.preventDefault();
    const phone = $('cancel-phone').value.trim(), version = ++lookupVersion;
    const find = $('find-appointments'), status = $('cancel-status');
    selectedAppointment = null; $('cancel-matches').replaceChildren();
    if (phone.replace(/\D/g, '').length < 10) { status.textContent = 'Please enter the phone number used when signing up.'; return; }
    find.disabled = true; status.textContent = 'Finding appointments…';
    try {
      const rows = await rpc('meals_find_by_phone', { p_phone: phone });
      if (version !== lookupVersion) return;
      matchedPhone = phone;
      if (!rows.length) { status.textContent = 'No upcoming meal appointments were found for that phone number.'; return; }
      status.textContent = rows.length === 1 ? 'Appointment found. Confirm below to cancel it.' : 'Choose the appointment you want to cancel.';
      const confirmButton = el('button', { class: 'btn danger', type: 'button', disabled: rows.length === 1 ? null : '', onclick: cancelSelected }, 'Cancel selected appointment');
      const choices = el('fieldset', { class: 'meal-cancel-choices' }, el('legend', {}, 'Your upcoming appointments'));
      if (rows.length === 1) selectedAppointment = rows[0];
      rows.forEach(row => choices.appendChild(el('label', { class: 'check' }, [
        el('input', { type: 'radio', name: 'meal-to-cancel', value: row.id, checked: rows.length === 1 ? '' : null, onchange: () => { selectedAppointment = row; confirmButton.disabled = false; } }),
        el('span', {}, dateLabel(row.meal_date)),
      ])));
      $('cancel-matches').replaceChildren(choices, el('p', { class: 'muted' }, 'Cancelling releases this day for another household.'), confirmButton);
      async function cancelSelected() {
        if (!selectedAppointment || !matchedPhone) return;
        const appointment = selectedAppointment, number = matchedPhone;
        cancelling = true; $('close-cancel-sheet').disabled = true;
        confirmButton.disabled = true; find.disabled = true; $('cancel-phone').disabled = true; choices.disabled = true;
        status.textContent = 'Cancelling…';
        try {
          await rpc('meals_cancel_by_phone', { p_id: appointment.id, p_phone: number });
          $('cancel-matches').replaceChildren(); selectedAppointment = null;
          status.textContent = 'Your appointment for ' + dateLabel(appointment.meal_date) + ' has been cancelled.';
          $('reservation').hidden = true;
          await loadCalendar();
        } catch (error) { status.textContent = error.message; confirmButton.disabled = false; choices.disabled = false; }
        finally { cancelling = false; $('close-cancel-sheet').disabled = false; find.disabled = false; $('cancel-phone').disabled = false; }
      }
    } catch (error) { if (version === lookupVersion) status.textContent = error.message; }
    finally { find.disabled = false; }
  });
  function renderCalendar() {
    const booked = new Map((info.booked || []).map(b => [b.date, b.who]));
    const blocked = new Set(info.blocked || []), last = plusDays(today, info.days_ahead);
    const box = $('cal'); box.replaceChildren();
    let month = today.slice(0, 7);
    while (month <= last.slice(0, 7)) {
      const [year, m] = month.split('-').map(Number);
      const startDay = month === today.slice(0, 7) ? Math.max(1, Number(today.slice(8)) - new Date(today + 'T12:00:00Z').getUTCDay()) : 1;
      const first = new Date(Date.UTC(year, m - 1, startDay)).getUTCDay();
      const count = new Date(Date.UTC(year, m, 0)).getUTCDate();
      const cells = days.map(d => el('span', { class: 'dow', 'aria-label': d }, d));
      for (let n = 0; n < first; n++) cells.push(el('span', { class: 'pad', 'aria-hidden': 'true' }));
      for (let d = startDay; d <= count; d++) {
        const date = month + '-' + String(d).padStart(2, '0');
        if (date < today || date > last) { cells.push(el('span', { class: 'day off' }, String(d))); continue; }
        if (blocked.has(date)) { cells.push(el('span', { class: 'day blocked', 'aria-label': dateLabel(date) + ': unavailable', title: 'Unavailable' }, [String(d), el('i', {}, '—')])); continue; }
        if (booked.has(date)) { cells.push(el('span', { class: 'day taken', 'aria-label': dateLabel(date) + ': booked', title: booked.get(date) }, [String(d), el('i', {}, booked.get(date).split(' ')[0])])); continue; }
        cells.push(el('button', { class: 'day open' + (date === today ? ' today' : ''), type: 'button', 'aria-label': 'Book ' + dateLabel(date), onclick: () => openSheet(date) }, String(d)));
      }
      box.appendChild(el('div', { class: 'mgrid-month' }, [el('h2', { class: 'mgrid-name' }, new Date(Date.UTC(year, m - 1, 1)).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'long', year: 'numeric' })), el('div', { class: 'mgrid meals' }, cells)]));
      month = m === 12 ? (year + 1) + '-01' : year + '-' + String(m + 1).padStart(2, '0');
    }
  }
  async function loadCalendar() {
    try {
      info = await rpc('meals_public');
      const open = info && info.enabled && info.companionships && info.companionships.length;
      $('calendar-section').hidden = !open; $('closed').hidden = !!open;
      if (open) renderCalendar();
    } catch (e) {
      $('calendar-section').hidden = true; $('closed').hidden = false;
      $('closed').replaceChildren(el('h2', {}, 'Could not load the calendar'), el('p', {}, e.message), el('button', { class: 'btn secondary', type: 'button', onclick: loadCalendar }, 'Try again'));
    } finally { $('meal-loading').hidden = true; }
  }
  function openSheet(date) {
    current = date; $('sheet-title').textContent = dateLabel(date); $('error').hidden = true;
    $('sheet').showModal(); document.body.classList.add('signup-open');
  }
  function closeSheet() { $('sheet').close(); document.body.classList.remove('signup-open'); current = null; }
  $('close-sheet').addEventListener('click', closeSheet);
  $('sheet').addEventListener('close', () => { document.body.classList.remove('signup-open'); current = null; });
  $('booking-form').addEventListener('submit', async e => {
    e.preventDefault(); if (!current) return;
    const send = $('send'); $('error').hidden = true;
    if ($('phone').value.replace(/\D/g, '').length < 10) { $('error').textContent = 'Please enter a mobile number.'; $('error').hidden = false; $('phone').focus(); return; }
    const date = current; send.disabled = true; send.textContent = 'Booking…';
    try {
      await rpc('meals_book', { p_date: date, p_name: $('name').value.trim(), p_phone: $('phone').value.trim(), p_notes: $('notes').value.trim() || null, p_website: $('website').value });
      closeSheet(); $('booking-form').reset();
      showPanel([el('h2', {}, 'You’re booked'), el('p', {}, dateLabel(date)), el('p', { class: 'muted' }, 'If your plans change, use Cancel appointment and enter the phone number you signed up with.'), el('button', { class: 'btn secondary', type: 'button', onclick: openCancellation }, 'Cancel appointment')]);
      await loadCalendar();
    } catch (error) { $('error').textContent = error.message; $('error').hidden = false; await loadCalendar(); }
    finally { send.disabled = false; send.textContent = 'Book this day'; }
  });
  (async () => {
    await NP.loadSiteSettings(); $('eyebrow').textContent = NP.C.wardName || 'Your Ward';
    document.title = 'Feed the missionaries · ' + (NP.C.wardName || 'Your Ward');
    await loadCalendar();
    if (location.hash.startsWith('#reservation=')) {
      history.replaceState(null, '', location.pathname + location.search);
      openCancellation();
    }
  })();
})();
