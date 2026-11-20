export const reports = [
 {key:'lcr_sacrament',label:'Sacrament attendance',path:'/report/sacrament-attendance'},
 {key:'lcr_moved_in',label:'Members moved in',path:'/mlt/report/members-moved-in'},
 {key:'lcr_test_members',label:'Members roster',headers:['Name','Gender','LCR Classes','Roster Key','Sunday School','Org','LCR Profile']},
 {key:'lcr_without_calling',label:'Without Calling',headers:['Name','Roster Key','LCR Profile']},
 {key:'lcr_converts',label:'Recent converts',path:'/one-work/progress-record'}
];

// Serialized and executed by Chrome on the report page.
export function readOverviewReport(key, path) {
  if(location.origin!=='https://lcr.churchofjesuschrist.org'||location.pathname.replace(/\/$/,'')!==path)
    return {error:'LCR did not open the requested report.',stop:true};
  const selects=[...document.querySelectorAll('select')];
  const choose=(select,value)=>{
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(select,value);
    select.dispatchEvent(new Event('change',{bubbles:true}));
  };
  const waiting=(error,extra)=>({error,...extra});
  const norm=v=>String(v||'').replace(/\s+/g,' ').trim();
  if(key==='lcr_sacrament'){
    const months=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const year=selects.find(s=>s.options.length&&[...s.options].every(o=>/^20\d{2}$/.test(o.textContent.trim())))?.selectedOptions[0]?.textContent.trim();
    if(!year)return waiting('Waiting for the sacrament report year.');
    const rows=new Map();
    for(const input of document.querySelectorAll('input[type=text], input[type=number]')){
      const d=input.parentElement?.parentElement?.innerText?.trim().match(/^(\d{1,2})(?:st|nd|rd|th)$/);
      const value=input.value.trim();
      if(!d||!/^\d+$/.test(value))continue;
      let node=input, m=-1;
      for(let i=0;i<10&&node.parentElement;i++){
        node=node.parentElement;
        const label=(node.innerText||'').match(/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b/);
        if(label){m=months.indexOf(label[1]);break;}
      }
      if(m>=0)rows.set(year+'-'+String(m+1).padStart(2,'0')+'-'+d[1].padStart(2,'0'),value);
    }
    if(!rows.size)return waiting('No entered sacrament headcounts could be verified in the selected year.');
    return {headers:['Sunday','Attendance'],rows:[...rows].sort(([a],[b])=>a.localeCompare(b))};
  }
  if(key==='lcr_converts'){
    const tabs=[...document.querySelectorAll('[role=tab],button,a,[role=button]')];
    const target=tabs.find(t=>/^New Members$/i.test(norm(t.textContent)));
    const otherSelected=tabs.some(t=>/^(Returning|People Being Taught)$/i.test(norm(t.textContent))&&
      (t.getAttribute('aria-selected')==='true'||t.getAttribute('aria-current')==='page'||t.classList.contains('active')));
    if(target&&(target.getAttribute('aria-selected')==='false'||otherSelected)){
      target.click();return waiting('Waiting for New Members.');
    }
    const panelId=target?.getAttribute('aria-controls');
    const panel=(panelId&&document.getElementById(panelId))||document;
    const visible=node=>!node.closest('[hidden],[aria-hidden="true"]')&&node.getClientRects().length>0;
    const cards=new Map(), seen=new Set();
    const tenure=t=>norm(t).match(/\bMember for\s+((?:\d+\s+(?:years?|months?|weeks?|days?)(?:(?:,?\s+and|,)\s*|\s*)?)+)/i)?.[1]?.trim().replace(/,?\s+and$|,$/i,'');
    function track(member){
      if(!member||!visible(member)||seen.has(member))return;
      let card=member.closest('div.row')||member.parentElement;
      let fallback=null;
      for(let i=0;card&&i<12&&card!==document.body;card=card.parentElement,i++){
        const text=norm(card.innerText||card.textContent);
        const ids=card.querySelectorAll('[data-member-card-person-uuid]');
        if((text.match(/\bMember for\b/gi)||[]).length>1||ids.length>1)break;
        if(!tenure(text))continue;
        fallback ||= card;
        if(/Attended Sacrament Meeting/i.test(text)||card.querySelector('a[href*="progress-details"]')){fallback=card;break;}
      }
      if(fallback){seen.add(member);cards.set(member,fallback);}
    }
    // Primary path from lcr-converts.js: New Members cards expose the member-card marker.
    // That marker plus tenure identifies the cards even without a detectable tab control.
    for(const member of panel.querySelectorAll('[data-member-card-person-uuid]'))track(member);
    // The newer layout can render the details control and person's name without the marker.
    for(const details of panel.querySelectorAll('a,button,[role=button]')){
      if(!visible(details)||!(/View Details/i.test(norm(details.textContent))||details.matches('a[href*="progress-details"]')))continue;
      let parent=details.parentElement;
      for(let i=0;parent&&i<9;i++,parent=parent.parentElement){
        const text=norm(parent.innerText||parent.textContent);
        if((text.match(/\bMember for\b/gi)||[]).length>1)break;
        if(!tenure(text))continue;
        const member=[...parent.querySelectorAll('[data-member-card-person-uuid],a,button')].find(a=>a!==details&&visible(a)&&norm(a.textContent)&&!a.matches('a[href*="progress-details"]')&&!/^View Details/i.test(norm(a.textContent)));
        if(member){track(member);break;}
      }
    }
    const people=new Map();
    for(const [member,card] of cards){
      const name=norm(member.textContent);
      const text=norm(card.innerText||card.textContent);
      const since=tenure(text);
      if(!name||!since)continue;
      const y=Number(since.match(/(\d+)\s+year/i)?.[1]||0),m=Number(since.match(/(\d+)\s+month/i)?.[1]||0);
      const days=new Map();
      for(const svg of card.querySelectorAll('svg')){
        let node=svg;
        for(let i=0;node&&node!==card&&i<3;i++,node=node.parentElement){
          const date=norm(node.previousElementSibling?.textContent);
          if(!/^\d{1,2} [A-Z][a-z]{2}$/.test(date))continue;
          const d=svg.querySelector('path')?.getAttribute('d')||'';
          const label=norm(svg.getAttribute('aria-label')||svg.querySelector('title')?.textContent);
          if(d||label){
            const attended=/^M12 22c5\.523/.test(d)||/^(attended|present)$/i.test(label);
            if(!days.has(date)||attended)days.set(date,attended?'✓':'·');
          }
          break;
        }
      }
      const last=[...days].slice(-6);
      const missed=text.match(/(\d+) sacrament meetings? missed/i)?.[1]||'';
      const friends=text.match(/(\d+) friends? in the Church identified/i)?.[1]||(/not yet identified/i.test(text)?'0':'');
      people.set(member.getAttribute('data-member-card-person-uuid')||name,
        [name,since,String(y*12+m),last.map(d=>d[1]).join(''),last.map(d=>d[0]).join(', '),missed,friends]);
    }
    const page=norm((panel.body||panel).innerText);
    const empty=/\b(no new members|there are no new members)\b/i.test(page)||
      target?.getAttribute('aria-selected')==='true'&&/\bno (?:members|records|results) found\b/i.test(page);
    if(!people.size&&!empty)return waiting('No New Members cards or empty-state message could be verified on Covenant Path Progress.');
    return {headers:['Name','Member for','Months','Last 6 Sundays','Sunday dates','Missed','Friends'],rows:[...people.values()]};
  }
  return {error:'Unsupported Overview report.',stop:true};
}

export async function manageOverview(items){
  if(location.origin!=='https://ward.example.invalid'||document.getElementById('app')?.hidden!==false||
     !/^\/admin(?:\.html)?\/?$/.test(location.pathname)||typeof window.NP?.rpc!=='function')throw new Error('Open and unlock Leaders → LCR first.');
  let pass='';
  for(const key of ['localStorage','sessionStorage']){
    try{pass=window[key].getItem('np_admin_token')||'';}catch{}
    if(pass)break;
  }
  if(!pass)throw new Error('Sign in to Leaders again.');
  const allowed={lcr_without_calling:['Name','Roster Key','LCR Profile'],lcr_test_members:['Name','Gender','LCR Classes','Roster Key','Sunday School','Org','LCR Profile'],lcr_sacrament:['Sunday','Attendance'],lcr_moved_in:['Name','Age','Move In Date','Prior Unit'],lcr_converts:['Name','Member for','Months','Last 6 Sundays','Sunday dates','Missed','Friends']};
  const marker='LCR Overview test extension';
  const rpc=(name,args)=>window.NP.rpc(name,{p_pass:pass,...args});
  const existing=new Map((await rpc('admin_sheets')).map(s=>[s.key,s]));
  const outcomes=[];
  for(const item of items){
    const {key,label}=item;
    if(key==='current_callings'){
      try{
        if(!item.roster?.length)throw Error('Import Members first.');
        const norm=n=>{const parts=n.split(',');return (parts.length===2?parts.reverse().join(' '):n).normalize('NFC').trim().toLowerCase().replace(/\s+/g,' ');};
        const planned=new Map(item.roster.map(r=>[r[3],[]]));
        let skipped=0;
        for(const [name,id,role] of item.roles){
          const byId=id?item.roster.filter(r=>r[6].toLowerCase().includes('/member-profile/'+id+'?')):[];
          const matches=byId.length?byId:item.roster.filter(r=>(!id||!r[6])&&norm(r[0])===norm(name));
          if(matches.length!==1){skipped++;continue;}
          const list=planned.get(matches[0][3]);if(!list.includes(role))list.push(role);
        }
        const prior=new Map((await rpc('admin_current_callings')).filter(r=>r.imported).map(r=>[r.roster_id,r.callings]));
        let members=0,changes=0;
        for(const [id,roles] of planned){
          if(roles.length)members++;
          const old=prior.get(id)||[];
          if(skipped && old.length)continue;
          if(JSON.stringify([...old].sort())===JSON.stringify([...roles].sort()))continue;
          await rpc('admin_save_current_callings',{p_imported:true,p_roster_id:id,p_callings:roles});changes++;
        }
        outcomes.push('Current callings: '+members+' roster members matched; '+changes+' updated.'+(skipped?' '+skipped+' report rows unmatched; existing callings preserved.':''));
      }catch(e){outcomes.push('Current callings failed: '+e.message);}
      continue;
    }
    if(!Object.hasOwn(allowed,key))continue;
    const previous=existing.get(key);
    if(previous&&previous.updated_by!==marker){outcomes.push(label+': existing report preserved.');continue;}
    const headers=allowed[key],rows=item.rows;
    if(JSON.stringify(headers)!==JSON.stringify(item.headers)||
       !Array.isArray(rows)||rows.length>2000||rows.some(r=>!Array.isArray(r)||r.length!==headers.length||r.some(v=>typeof v!=='string'||v.length>300))){
      outcomes.push(label+': invalid report; nothing saved.');continue;
    }
    try{
      await rpc('admin_replace_sheet',{p_key:key,p_title:label+' (LCR)',p_source_url:null,p_headers:headers,p_rows:rows,p_by:marker});
      const assignments=key==='lcr_test_members'
        ? ' Sunday School: '+rows.filter(row=>row[4]).length+'; Org: '+rows.filter(row=>row[5]).length+'.'
        : '';
      outcomes.push(label+': saved '+rows.length+' rows.'+assignments);
    }catch(e){outcomes.push(label+': failed to save. Check your Leaders session and try again.');}
  }
  try{await window.NPOverview?.refresh();}catch{}
  document.dispatchEvent(new Event('ward-lcr-test-roster-updated'));
  return {outcomes};
}
