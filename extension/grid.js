// Runs within the report document. Return only the fields used by Leaders.
export async function grid(mode,date,pending=[]) {
  const clean=v=>String(v??'').replace(/\s+/g,' ').trim();
  const txt=n=>clean(n?.innerText||n?.textContent);
  const shown=n=>n.getClientRects().length>0&&!n.closest('[hidden],[aria-hidden=true]');
  const query=(root,s)=>Array.from(root.querySelectorAll(s));
  const doc=document;
  if(location.origin!=='https://lcr.churchofjesuschrist.org')return {error:'Unexpected report origin.'};
  const moves=mode==='moves', directory=mode==='directory', exporting=mode==='preview'||mode==='write';
  const path=moves?'members-moved-in':directory?'member-list':'class-and-quorum-attendance';
  if(window===window.top&&!location.pathname.replace(/\/$/,'').endsWith('/'+path))return {error:'Waiting for the requested LCR page.'};
  const change=(select,option)=>{
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(select,option.value);
    select.dispatchEvent(new Event('change',{bubbles:true}));
  };
  const selects=query(doc,'select').filter(shown);
  let yearOK=false,rangeOK=false;
  for(const s of selects){
    const opts=[...s.options];let opt;
    if(/per page|page size/i.test(s.getAttribute('aria-label')||''))
      opt=opts.find(o=>/^all$/i.test(txt(o)));
    if(moves){
      const periods=opts.filter(o=>/^\d+\s*months?$/i.test(txt(o)));
      const period=periods.find(o=>/^3\s*months?$/i.test(txt(o)))||
        periods.filter(o=>parseInt(txt(o),10)>=2).sort((a,b)=>parseInt(txt(a),10)-parseInt(txt(b),10))[0]||
        periods.find(o=>/^1\s*months?$/i.test(txt(o)));
      if(period){rangeOK=true;opt=period;}
    }else{
      const month=opts.find(o=>o.value===date.slice(0,7));
      if(month){opt=month;yearOK=true;}
      else opt||=opts.find(o=>/^all(?: classes(?: and quorums)?| organizations| members)?$/i.test(txt(o)));
    }
    if(opt&&s.value!==opt.value){change(s,opt);return {error:'Loading report filters…',delay:moves?15000:1200};}
  }
  if(moves){
    const age=query(doc,'input[type=checkbox]').find(n=>shown(n)&&/^(?:show|display) age$/i.test(clean(n.getAttribute('aria-label')||Array.from(n.labels||[]).map(txt).join(' '))));
    if(age&&!age.checked){age.click();return {error:'Loading move-in ages…',delay:900};}
  }
  if(moves&&!rangeOK){
    const choices=query(doc,'[role=option]').filter(shown);
    const three=choices.find(o=>/^3 months?$/i.test(txt(o)));
    const combo=query(doc,'[role=combobox],button[aria-haspopup=listbox]').filter(shown).find(n=>/^(?:1|3|6|12) months?$/i.test(txt(n)));
    if(combo&&/^3 months?$/i.test(txt(combo)))rangeOK=true;
    else if(combo){
      if(three)three.click();else if(combo.getAttribute('aria-expanded')!=='true')combo.click();
      return {error:'Selecting the three-month report.',delay:three?15000:500};
    }
  }
  if(!moves&&!directory){
    const tab=query(doc,'[role=tab]').find(t=>shown(t)&&txt(t)==='Members');
    if(tab?.getAttribute('aria-selected')==='false'){tab.click();return {error:'Opening Members…',delay:1200};}
  }
  const day=new Date(date+'T12:00:00Z'), labels=new Set([date]);
  for(const locale of ['en-GB','en-US'])for(const month of ['short','long'])for(const year of [undefined,'numeric']){
    if(!year&&!yearOK)continue;
    labels.add(day.toLocaleDateString(locale,{month,year,day:'numeric',timeZone:'UTC'}).toLowerCase().replace(/[.,]/g,''));
  }
  const textVariants=n=>[n.getAttribute('aria-label'),n.getAttribute('title'),n.querySelector('time')?.getAttribute('datetime'),txt(n),...query(n,'span,button,time').map(txt)].filter(Boolean);
  const headKey=v=>clean(v).toLowerCase().replace(/[^a-z]/g,'').replace(/^(.+)\1$/,'$1');
  const cells=r=>Array.from(r.cells||r.querySelectorAll('[role=columnheader],[role=cell],[role=gridcell]'));
  let reason='No matching header row found.';
  const tables=query(doc,'table,[role=table],[role=grid]');
  for(const table of tables.filter(shown)){
    const rows=query(table,'tr,[role=row]').filter(shown);
    const firstData=rows.find(r=>cells(r).some(c=>c.querySelector('.eden-table-card-view__cloned-column-header')||c.getAttribute('data-label')));
    const cardHeaders=firstData&&cells(firstData).map(c=>[txt(c.querySelector('.eden-table-card-view__cloned-column-header')),c.getAttribute('data-label')].filter(Boolean));
    const candidates=[];
    for(const [i,h] of rows.entries()){
      if(i<3||h.closest('thead')||h.querySelector('th,[role=columnheader]'))candidates.push([i,cells(h).map(textVariants)]);
    }
    if(cardHeaders)candidates.push([rows.indexOf(firstData)-1,cardHeaders]);
    for(const [i,headers] of candidates){
      const idx=re=>headers.findIndex(values=>values.some(v=>re.test(headKey(v))));
      const ni=idx(/^(?:(?:record|member|preferred|recordpreferred)?name)(?:name)?$/);
      if(ni<0)continue;
      const gi=idx(/^(record)?(gender|sex)$/),ai=idx(/^(record)?age$/),pi=idx(/(prior|previous)unit$/),mi=idx(/(moveindate|movedindate|datemovedin)$/);
      const di=headers.findIndex(values=>values.some(v=>labels.has(clean(v).toLowerCase().replace(/[.,]/g,''))));
      if(moves&&(mi<0||!rangeOK)){reason='Check the Move In Date column and report period.';continue;}

      if(!directory&&!moves&&gi<0&&di<0)continue;
      const members=[],targets=[],seen=new Set();
      const value=n=>{
        const prefix=txt(n?.querySelector('.eden-table-card-view__cloned-column-header'));
        const val=txt(n);return prefix&&val.startsWith(prefix)?val.slice(prefix.length).trim():val;
      };
      for(const row of rows.slice(i+1)){
        const c=cells(row);if(!c.length||row.closest('thead'))continue;
        const rowText=txt(row)||c.map(txt).join(' ').trim();
        if(!rowText||row.closest('tfoot')||c.every(cell=>cell.matches('th,[role=columnheader]')))continue;
        if(c.length===1&&(/^(loading|no (?:members|results|records)|count\s*:|total\s*[:\d]|showing\s+\d)/i.test(rowText)||Number(c[0].getAttribute('colspan'))>1))continue;
        const member=c[ni]?.querySelector('[data-member-card-person-uuid],a[href*="member-profile"]');
        const name=(txt(member)||txt(c[ni]?.querySelector('a'))||value(c[ni])).replace(/^Warning\s*/i,'');
        if(!name)return {error:'A data row has no readable member name.'};
        if(moves){
          if(!c[mi])return {error:'A move-in data row has no date cell.'};
          const moved=(c[mi]?.querySelector('time[datetime]')?.getAttribute('datetime')?.slice(0,10)||value(c[mi]))
            .replace(/^(\d{1,2})[.\s]*(\p{L}{3,9})[.\s]*(\d{4})$/u,'$1 $2 $3');
          const iso=/^\d{4}-\d{2}-\d{2}$/.test(moved);
          const parsed=new Date(moved);
          if(!moved||!Number.isFinite(parsed.getTime()))return {error:'Waiting for readable move-in dates.'};
          const dateText=iso?moved:[parsed.getFullYear(),String(parsed.getMonth()+1).padStart(2,'0'),String(parsed.getDate()).padStart(2,'0')].join('-');
          members.push([name,value(c[ai]),dateText,value(c[pi])]);continue;
        }
        const id=(member?.getAttribute('data-member-card-person-uuid')||member?.getAttribute('href')||'').match(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i)?.[0].toLowerCase()||'';
        const key=id||'display-name:'+name.toLowerCase();if(seen.has(key))return {error:'Duplicate member identities in the report.'};seen.add(key);
        const dated=di<0&&!directory?c.find(el=>query(el,'button[aria-label],button[aria-pressed]').some(btn=>{
          const key=Object.keys(btn).find(k=>k.startsWith('__reactFiber$'));
          for(let f=btn[key],depth=0;f&&depth<14;depth++,f=f.return){
            const props=f.memoizedProps;
            if(props?.memberId&&props?.weekDate)return props.weekDate===date;
          }
          return false;
        })):null;
        const session=c[di]||dated||(!exporting&&!directory&&c.find((el,j)=>
          j!==ni&&j!==gi&&(/sunday school|elders quorum|relief society/i.test(txt(el))||el.querySelector('button[aria-pressed],input[type=checkbox]'))));
        const elements=session?query(session,'button,input[type=checkbox],[role=checkbox],[role=switch],[role=button],[aria-pressed],[aria-checked]').filter(shown):[];
        const buttons=elements.filter(b=>!elements.some(other=>other!==b&&b.contains(other)));
        const buttonLabels=buttons.map(b=>txt(b)||clean(b.getAttribute('aria-label'))||txt(b.nextElementSibling)||
          clean(b.getAttribute('title'))||(b.parentElement!==session?txt(b.parentElement):''));
        let classes=buttons.map(b=>txt(b)||txt(b.nextElementSibling)||(b.parentElement!==session?txt(b.parentElement):''));
        if(!classes.some(Boolean)&&session){
          const lines=(session.innerText||'').split(/\n+/).map(clean).filter(Boolean);
          if(lines.length===2)classes=lines;
        }
        if(!directory&&session){
          const text=txt(session);
          const school=text.match(/(?:[\w'’()-]+ )*Sunday School(?: [A-Z]\d+)?/i)?.[0]||'';
          const org=text.match(/Elders Quorum|Relief Society|Young Women|Aaronic Priesthood|Primary/i)?.[0]||'';
          if(school||org)classes=[classes[0]&&/sunday school/i.test(classes[0])?classes[0]:school,classes[1]&&classes[1]!==classes[0]?classes[1]:org];
        }
        const sex=value(c[gi]).toUpperCase();
        members.push({name,id,sex:/^(M|F|MALE|FEMALE)$/.test(sex)?sex[0]:'',classes:classes.length===2?classes:[]});
        targets.push({name,id,buttons,buttonLabels});
      }
      const body=txt(doc.body);
      const count=body.match(/\bCount:\s*([\d,]+)/i);
      const range=body.match(/([\d,]+)\s*[-–]\s*([\d,]+)\s+of\s+([\d,]+)/i);
      const next=query(doc,'button,a').find(n=>shown(n)&&!n.disabled&&n.getAttribute('aria-disabled')!=='true'&&/^(?:go to )?next(?: page)?$/i.test(clean(n.getAttribute('aria-label')||n.title||txt(n))));
      if(!exporting&&range){
        const [start,end,total]=range.slice(1).map(v=>Number(v.replaceAll(',','')));
        if(total>0&&(start>1||end<total)){
          if(end-start+1!==members.length||start<1||end>total||total>2000)return {error:'Waiting for the full report page.'};
          const cache=window.__wardV2Pages||=(new Map());
          const item=cache.get(mode)||{pages:new Map(),total};
          if(item.total!==total)return {error:'Report changed during pagination.',stop:true};
          if(!item.pages.has(start)){
            item.pages.set(start,members);cache.set(mode,item);
            if(end<total&&next){next.click();return {error:'Reading next report page.',delay:1000};}
          }
          const all=[];
          while(item.pages.has(all.length+1))all.push(...item.pages.get(all.length+1));
          return all.length===total?{rows:all}:{error:'Waiting for remaining report pages.'};
        }
      }
      if(next)return {error:'Show all report rows so the total can be checked.'};
      if(count&&Number(count[1].replaceAll(',',''))!==members.length||range&&(range[1]!=='1'||range[2]!==range[3]))return {error:'The report shows a partial list. Show all rows before importing.'};
      if(/\bloading\b/i.test(txt(table))&&!members.length)continue;
      if(!members.length&&!(moves&&(count?.[1]==='0'||/no (members|results|records)/i.test(txt(table)))))continue;
      if(!exporting)return {rows:members};
      function normalized(n){const parts=clean(n).split(',');return clean(parts.length===2?parts.reverse().join(' '):n).normalize('NFC').toLowerCase();}
      if(!targets.some(t=>t.buttons.length))return {error:'No verified Sunday column with attendance controls for '+date+'.'};
      const result=[];
      for(const r of pending){
        const hits=targets.filter(t=>r.lcrId&&t.id===r.lcrId);
        const matches=hits.length?hits:targets.filter(t=>normalized(t.name)===normalized(r.name)&&(!r.lcrId||!t.id));
        const sameName=pending.filter(p=>normalized(p.name)===normalized(r.name));
        let status='No unique member match';
        if(matches.length===1&&(hits.length||new Set(sameName.map(p=>p.member_id)).size===1)){
          const {buttons,buttonLabels}=matches[0];
          const school=/\bsunday school\b/i;
          const organization=/\b(?:elders quorum|relief society|young women|aaronic priesthood|deacons quorum|teachers quorum|priests quorum|primary)\b/i;
          const candidates=buttons.filter((_,i)=>r.slot===1
            ? school.test(buttonLabels[i])&&!organization.test(buttonLabels[i])
            : organization.test(buttonLabels[i])&&!school.test(buttonLabels[i]));
          const b=candidates.length===1?candidates[0]:null;
          const state=b?.matches('input[type=checkbox]')?String(b.checked):b?.getAttribute('aria-pressed')??b?.getAttribute('aria-checked')??b?.getAttribute('data-state');
          if(['true','checked'].includes(state))status='Already present';
          else if(!['false','unchecked'].includes(state))status='Class control or its attendance state could not be verified';
          else if(!b.isConnected||b.disabled||b.getAttribute('aria-disabled')==='true')status='Locked by LCR';
          else if(mode==='write'){b.click();status='Submitted';}
          else status='Ready';
        }
        result.push({id:r.id,status});
      }
      return {rows:result};
    }
  }
  return {error:reason+' Visible tables: '+tables.filter(shown).length+'.'};
}
