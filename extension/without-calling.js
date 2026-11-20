// The two tabs are independent reports. Ages are used locally.
export const callingSources = [
  { key: 'without_callings', label: 'Members Without Callings', path: '/mlt/report/member-callings', tab: 'without-callings' },
  { key: 'member_callings', label: 'Members with Callings', path: '/mlt/report/member-callings' },
];

export function readCallingSource(key, path) {
  if (location.origin !== 'https://lcr.churchofjesuschrist.org' || location.pathname.replace(/\/$/, '') !== path ||
      !['without_callings','member_callings'].includes(key)) return { error: 'LCR did not open the requested report.', stop: true };
  const members = key === 'without_callings';
  const norm = value => String(value || '').replace(/\s+/g, ' ').trim();
  const text = node => norm(node?.innerText || node?.textContent);
  const shown = node => node.getClientRects().length > 0;
  const selectedTab = new URLSearchParams(location.search).get('tab');
  if (members ? selectedTab !== 'without-callings' : selectedTab === 'without-callings') {
    return { error: 'LCR opened a different callings tab.', stop: true };
  }
  if (document.querySelector('input[type=password]')) return { error: 'Refresh LCR and sign in again.', stop: true };
  const active = [...document.querySelectorAll('[role=tab][aria-selected=true],a[aria-current=page]')].filter(shown);
  if (active.some(node => (members ? /\bwith callings\b/i : /\bwithout callings\b/i).test(text(node)))) {
    return { error: 'Waiting for the requested callings tab.' };
  }
  const panels = [...document.querySelectorAll('[role=tabpanel]')].filter(shown);
  const scope = panels.length === 1 ? panels[0] : document;
  const bodyText = text(scope === document ? document.body : scope);
  const count = bodyText.match(/\bCount:\s*([\d,]+)/i);
  const expected = count ? Number(count[1].replace(/,/g, '')) : null;
  const empty = /\b(?:no (?:members|callings|records|results)(?: found| to display)?|there are no (?:members|callings))\b/i;
  const filterTables = [...scope.querySelectorAll('table,[role=table],[role=grid]')].filter(shown);
  for (const input of document.querySelectorAll('select')) {
    if (!shown(input)) continue;
    const all = [...input.options].find(option => /^all(?: members| organizations| callings)?$/i.test(text(option)));
    const isFilter = all && (all.value.toUpperCase() === 'ALL' || /page size|per page/i.test(input.getAttribute('aria-label') || ''));
    if (isFilter && input.value !== all.value) {
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(input, all.value);
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return { error: 'Waiting for the unfiltered LCR report.' };
    }
  }
  if (members) {
    const showAge = [...document.querySelectorAll('input[type=checkbox],[role=checkbox]')].find(node => {
      const label = norm(node.getAttribute('aria-label') || [...(node.labels || [])].map(text).join(' ') || text(node.closest('label')));
      return shown(node) && /^(?:show|display) ages?$/i.test(label);
    });
    if (showAge && (showAge.matches('input') ? !showAge.checked : showAge.getAttribute('aria-checked') === 'false')) {
      showAge.click(); // Only the report's display option.
      return { error: 'Waiting for LCR to display member ages.' };
    }
  }
  const uuid = /[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i;
  const headers = {calling:'calling',callings:'calling',position:'calling',positionname:'calling',callingname:'calling',
    'recordname': 'name', 'recordpreferredname': 'name', 'name': 'name', 'member': 'name', 'membername': 'name', 'preferredname': 'name', 'individual': 'name',
    'age': 'age', 'recordage': 'age', 'ageyears': 'age', 'ageinyears': 'age',
    'birthdate': 'birth', 'dateofbirth': 'birth', 'recordbirthdate': 'birth',
    'membershipstatus': 'status', 'memberstatus': 'status', 'membershiptype': 'status',
  };
  const field = cell => {
    for (const candidate of [text(cell.querySelector('span')), text(cell)]) {
      const clean = candidate.replace(/^(.+?)\s*\1$/,'$1').toLowerCase().replace(/[^a-z]/g, '');
      if (headers[clean]) return headers[clean];
    }
  };
  const cells = row => row.cells ? [...row.cells] : [...row.querySelectorAll('[role=columnheader],[role=cell],[role=gridcell]')];
  const value = cell => {
    const raw = text(cell);
    const prefix = text(cell?.querySelector('.eden-table-card-view__cloned-column-header'));
    return prefix && raw.startsWith(prefix) ? raw.slice(prefix.length).trim() : raw;
  };
  function ageAtLeast12(age) {
    const years = age.match(/^(\d{1,3})(?:\s*(?:y|yrs?|years?)\b.*)?$/i);
    if (years) return +years[1] >= 12;
    if (/^\d{1,3}\s+(?:months?|weeks?|days?)(?:\s.*)?$/i.test(age)) return false;
    return null;
  }
  let issue = 'Waiting for the LCR report table.';
  for (const table of filterTables) {
    const rawRows = [...table.querySelectorAll('tr,[role=row]')];
    const heading = table.tHead?.rows[0] || rawRows.find(row => cells(row).some(cell => field(cell) === 'name'));
    if (!heading) continue;
    const columns = cells(heading).map(field);
    if (members && columns.includes('calling')) continue;
    if (!columns.includes('name') || !members && !columns.includes('calling')) continue;
    if (members && !columns.includes('age')) {
      issue = 'Members Without Callings does not show an Age column. Check the report in LCR.';
      continue;
    }
    const records = table.tBodies?.length ? [...table.tBodies].flatMap(body => [...body.rows]) : rawRows.slice(rawRows.indexOf(heading)+1);
    const output = [];
    let incomplete = false, seenRows = 0;
    for (const row of records) {
      const items = cells(row), nameCell = items[columns.indexOf('name')], raw = text(row);
      if (!raw || items.length === 1 && empty.test(raw) || /^loading\b/i.test(raw)) continue;
      const member = nameCell?.querySelector('[data-member-card-person-uuid],a[href*="member-profile"]') || nameCell?.querySelector('a,button');
      const name = (text(member) || value(nameCell)).replace(/^Warning\s*/i, '').trim();
      if (!name || items.length < columns.length) { incomplete = true; continue; }
      seenRows++;
      const nonmember = /\b(?:non[\s-]*member|not a member)\b/i.test(value(items[columns.indexOf('status')]));
      if (members && nonmember) continue;
      const id = (member?.getAttribute('data-member-card-person-uuid') || member?.getAttribute('href') || '').match(uuid)?.[0] || '';
      const eligible = members ? ageAtLeast12(value(items[columns.indexOf('age')])) : null;
      if (members && eligible === null) { incomplete = true; continue; }
      const role=members?'':value(items[columns.indexOf('calling')]);
      if(!members && !role){incomplete=true;continue;}
      output.push([name, id.toLowerCase(), members?eligible:role]);
    }
    const range=bodyText.match(/(?:showing\s+)?([\d,]+)\s*[-–]\s*([\d,]+)\s+of\s+([\d,]+)/i);
    const numbers=range?.slice(1).map(v=>Number(v.replaceAll(',','')));
    if(incomplete){issue='A report row is missing a name, age, or calling. The previous report was kept.';continue;}
    const next=[...document.querySelectorAll('button,a')].find(node=>shown(node)&&/^(?:go to )?next(?: page)?$/i.test(norm(node.getAttribute('aria-label')||node.getAttribute('title')||text(node)))&&!node.disabled&&node.getAttribute('aria-disabled')!=='true');
    if(numbers && (numbers[0]>1 || numbers[1]<numbers[2])){
      const [start,end,total]=numbers;
      if(end-start+1!==seenRows || total>5000 || total<end || start<1)return {error:'Waiting for all rows on this report page.'};
      const cache=window.__wardPagedReports ||= {};
      const acc=cache[key] ||= {pages:{},total};
      if(acc.total!==total)return {error:'The report changed during paging. Run sync again.',stop:true};
      if(acc.pages[start] && acc.pages[start].end!==end)return {error:'The report pagination changed.',stop:true};
      if(!acc.pages[start]){
        acc.pages[start]={end,output};
        if(end<total && next){next.click();return {error:'Reading the next report page.'};}
      }
      let cursor=1,all=[];
      while(acc.pages[cursor]){const page=acc.pages[cursor];all=all.concat(page.output);cursor=page.end+1;}
      if(cursor===total+1)return {rows:all};
      return {error:'Waiting for the next report page.'};
    }
    if(next || expected!==null && seenRows!==expected && (members || new Set(output.map(r=>r[1]||r[0])).size!==expected)){issue='Could not verify the full report count. The previous report was kept.';continue;}
    if (seenRows || !/loading/i.test(text(table)) && (expected === 0 || empty.test(text(table)))) return { rows: output };
  }
  if (members && !filterTables.length && /\bno members without callings\b/i.test(bodyText)) return { rows: [] };
  if (!members && (expected === 0 || empty.test(bodyText)) && !filterTables.length) return { rows: [] };
  return { error: issue };
}

export async function withoutCallingRows(members, roster = [], digest = crypto.subtle) {
  const nameKey = name => {
    const [last, first] = name.split(/,\s*(.+)/);
    return (first ? first + ' ' + last : last).normalize('NFC').toLowerCase().replace(/\s+/g, ' ').trim();
  };
  const byName = new Map(), byId = new Map();
  for (const member of members) {
    const [name, id] = member;
    if (id && byId.has(id)) throw new Error('Members Without Callings has a duplicate LCR ID. The existing list was kept.');
    if (id) byId.set(id, member);
    const index = nameKey(name);
    byName.set(index, [...(byName.get(index) || []), member]);
  }
  const profileId = value => String(value || '').match(/\/member-profile\/([0-9a-f-]{36})(?:[/?#]|$)/i)?.[1].toLowerCase() || '';
  const oldKeys = new Map(roster.filter(row => profileId(row[6])).map(row => [profileId(row[6]), row[3]]));
  const rosterNames = new Map();
  for (const row of roster) {
    const index = nameKey(row[0]);
    rosterNames.set(index, [...(rosterNames.get(index) || []), row]);
  }
  const output = new Map();
  for (const member of members) {
    const [name, id, eligible] = member;
    if (eligible !== true) continue;
    const hits = byName.get(nameKey(name));
    if (!id && hits.length !== 1) throw new Error('Members Without Callings has duplicate names without stable IDs. The existing list was kept.');
    const rosterMatches = rosterNames.get(nameKey(name)) || [];
    const equivalent = hits.length === 1 && rosterMatches.length === 1 &&
      (!id || !profileId(rosterMatches[0][6]) || id === profileId(rosterMatches[0][6])) ? rosterMatches[0][3] : '';
    let key = oldKeys.get(id) || equivalent;
    if (!key) {
      const identity = id || 'display-name:' + name.toLowerCase();
      const bytes = new Uint8Array(await digest.digest('SHA-256', new TextEncoder().encode('ward-site-private-roster:'+identity))).slice(0,16);
      bytes[6] = (bytes[6]&15)|128; bytes[8] = (bytes[8]&63)|128;
      const h = [...bytes].map(b => b.toString(16).padStart(2,'0')).join('');
      key = [h.slice(0,8),h.slice(8,12),h.slice(12,16),h.slice(16,20),h.slice(20)].join('-');
    }
    output.set(key,[name,key,id ? 'https://lcr.churchofjesuschrist.org/mlt/records/member-profile/'+id+'?lang=eng' : '']);
  }
  return [...output.values()];
}
