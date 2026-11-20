import {grid} from './grid.js';
import {leaders} from './site.js';
import {reports,readOverviewReport,manageOverview} from './overview.js';
import {callingSources,readCallingSource,withoutCallingRows} from './without-calling.js';
const $=id=>document.getElementById(id);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const root='https://lcr.churchofjesuschrist.org';
const att='/mlt/report/class-and-quorum-attendance',members='/mlt/records/member-list';
const jobs=['Members','Current callings','Recent move-ins','Sacrament attendance','Recent converts','Members without callings'];
const sunday=new Date(new Date().toLocaleDateString('en-US',{timeZone:'America/New_York'})+' 12:00');
sunday.setDate(sunday.getDate()-sunday.getDay());
const lastSunday=[sunday.getFullYear(),String(sunday.getMonth()+1).padStart(2,'0'),String(sunday.getDate()).padStart(2,'0')].join('-');

for(const job of jobs){
  const label=document.createElement('label'),box=document.createElement('input');
  box.type='checkbox';box.checked=true;box.value=job;label.append(box,' '+job);$('choices').append(label);
}
function line(parent,message){const li=document.createElement('li');li.textContent=message;parent.append(li);return li;}
async function run(id,func,args,frame=0){
  const [r]=await chrome.scripting.executeScript({target:{tabId:id,frameIds:[frame]},world:'MAIN',func,args});
  if(r?.error||r?.result===undefined)throw Error(r?.error?.message||'Page action failed. Check the signed-in page.');
  return r.result;
}
async function site(){
  for(const tab of await chrome.tabs.query({url:'https://ward.example.invalid/admin*'})){
    try{if(await run(tab.id,leaders,['ready']))return tab.id;}catch{}
  }
  throw Error('Open the ward site and unlock Leaders.');
}
async function report(path,params,work){
  const url=new URL(path,root);url.search=new URLSearchParams({lang:'eng',...params});
  const tab=await chrome.tabs.create({url:url.href,active:true});
  try{return await work(tab.id);}finally{await chrome.tabs.remove(tab.id).catch(()=>{});}
}
async function collect(id,path,func,args,timeout=42000){
  const deadline=Date.now()+timeout;let prior=null,since=0,error='Report still loading.';
  while(Date.now()<deadline){
    const tab=await chrome.tabs.get(id);
    if(tab.status==='complete'&&tab.url&&tab.url!=='about:blank'){
      const url=new URL(tab.url);
      if(url.origin!==root||url.pathname.replace(/\/$/,'')!==path)throw Error('LCR redirected away from the report. Open it while signed in.');
      const hits=await chrome.scripting.executeScript({target:{tabId:id,allFrames:true},world:'MAIN',func,args});
      const valid=hits.filter(h=>Array.isArray(h.result?.rows));
      if(valid.length>1)throw Error('Multiple report frames matched.');
      if(valid.length){
        const h=valid[0],snapshot=JSON.stringify([h.frameId,h.result.rows]);
        if(snapshot===prior&&Date.now()-since>=1400)return {...h.result,frame:h.frameId};
        if(snapshot!==prior){prior=snapshot;since=Date.now();}
      }else{
        prior=null;
        const issue=hits.map(h=>h.result).find(r=>r?.delay)||hits.map(h=>h.result).find(r=>r?.error);
        error=issue?.error||hits[0]?.error?.message||error;
        if(issue?.stop)throw Error(error);
        if(issue?.delay||issue?.filterChanged)await sleep(issue.delay||15000);
      }
    }
    await sleep(450);
  }
  throw Error(error);
}
const readReport=(path,params,func,args,timeout)=>report(path,params,id=>collect(id,path,func,args,timeout));
async function buildRoster(rows,old){
  const ids=await withoutCallingRows(rows.map(p=>[p.name,p.id,true]),old);
  if(ids.length!==rows.length)throw Error('Roster identities collided.');
  const prior=new Map(old.map(r=>[r[3],r]));
  return ids.map(([name,key,profile],i)=>{
    const p=rows[i],before=prior.get(key)||[],first=p.classes[0]||before[4]||'',second=p.classes[1]||before[5]||'';
    return [name,p.sex||before[1]||'',[...new Set([first,second].filter(Boolean))].join(', ')||before[2]||'',key,first,second,profile||before[6]||''];
  });
}
async function importOne(job,id){
  const save=async item=>(await run(id,manageOverview,[[item]])).outcomes.join(' ');
  const base=key=>reports.find(r=>r.key===key);
  if(job===jobs[0]){
    const {rows}=await readReport(members,{},grid,['directory',lastSunday]);
    let classRows=[], classIssue='';
    try{({rows:classRows}=await readReport(att,{},grid,['roster',lastSunday],30000));}
    catch(e){classIssue=e.message;}
    const normalize=name=>name.split(',').reverse().join(' ').normalize('NFC').toLowerCase().trim().replace(/\s+/g,' ');
    for(const member of rows){
      const exact=classRows.filter(p=>member.id&&p.id===member.id);
      const byName=classRows.filter(p=>(!p.id||!member.id)&&normalize(p.name)===normalize(member.name));
      const uniqueName=rows.filter(p=>normalize(p.name)===normalize(member.name)).length===1;
      const match=exact.length===1?exact[0]:uniqueName&&byName.length===1?byName[0]:null;
      if(match){member.classes=match.classes;member.sex||=match.sex;}
    }
    const saved=await save({...base('lcr_test_members'),rows:await buildRoster(rows,await run(id,leaders,['roster']))});
    return saved+' Source: LCR Member List.'+(classIssue?' Class assignments: '+classIssue:'');

  }
  if(job===jobs[1]||job===jobs[5]){
    const isRoles=job===jobs[1],src=callingSources[isRoles?1:0];
    const {rows}=await readReport(src.path,src.tab?{tab:src.tab}:{},readCallingSource,[src.key,src.path],120000);
    const roster=await run(id,leaders,['roster']);
    return save(isRoles?{key:'current_callings',roles:rows,roster}:{...base('lcr_without_calling'),rows:await withoutCallingRows(rows,roster)});
  }
  const src=base(({[jobs[2]]:'lcr_moved_in',[jobs[3]]:'lcr_sacrament',[jobs[4]]:'lcr_converts'})[job]);
  if(job===jobs[2]){
    const {rows}=await readReport(src.path,{months:'3'},grid,['moves',lastSunday],65000);
    return save({...src,headers:['Name','Age','Move In Date','Prior Unit'],rows});
  }
  return save({...src,...await readReport(src.path,{},readOverviewReport,[src.key,src.path])});
}
let plan=null;
function busy(lock){for(const el of document.querySelectorAll('button,input'))el.disabled=lock;$('send').disabled=lock||!plan?.rows.length;$('preview').disabled=lock||!$('date').value;}
$('sync').onclick=async()=>{
  const chosen=[...$('choices').querySelectorAll(':checked')].map(x=>x.value);
  if(!chosen.length)return;
  busy(true);$('log').replaceChildren();
  try{
    const id=await site();
    for(const job of chosen){
      const row=line($('log'),job+' — reading…');
      try{row.textContent=await importOne(job,id);}catch(e){row.textContent=job+' — '+e.message;}
    }
  }catch(e){line($('log'),e.message);}finally{busy(false);}
};
$('date').onchange=()=>{plan=null;$('matches').replaceChildren();$('status').textContent='';busy(false);};
const inspect=(date,rows)=>readReport(att,{},grid,['preview',date,rows]);
$('preview').onclick=async()=>{
  plan=null;busy(true);$('matches').replaceChildren();$('status').textContent='Checking Leaders…';
  try{
    const date=$('date').value;
    if(!date||new Date(date+'T12:00:00Z').getUTCDay()!==0)throw Error('Choose a Sunday.');
    const id=await site(),pending=await run(id,leaders,['pending',date]);
    if(!pending.length)throw Error('No pending named class check-ins for this Sunday.');
    const result=await inspect(date,pending);
    const rows=pending.filter((r,i)=>{
      const status=result.rows[i]?.status;
      line($('matches'),r.name+' · '+(r.slot===1?'Sunday School':'Organization')+' · '+status);
      return ['Ready','Already present'].includes(status);
    });
    plan={date,id,rows};$('status').textContent=rows.length+' of '+pending.length+' check-ins matched.';
  }catch(e){$('status').textContent=e.message;}finally{busy(false);}
};
$('send').onclick=async()=>{
  if(!plan||!confirm('Mark the reviewed check-ins present for '+plan.date+' in the ward open in LCR?'))return;
  const {date,id,rows}=plan;plan=null;busy(true);
  try{
    const current=await run(id,leaders,['pending',date]);
    const reviewed=rows.filter(r=>current.some(c=>c.id===r.id&&c.member_id===r.member_id&&c.slot===r.slot&&c.name===r.name));
    let problem='';
    try{await report(att,{},async tab=>{
      const pre=await collect(tab,att,grid,['preview',date,reviewed]);
      for(const [i,row] of reviewed.entries()){
        if(pre.rows[i]?.status!=='Ready')continue;
        const result=await run(tab,grid,['write',date,[row]],pre.frame);
        if(!result.rows)throw Error(result.error);
        await sleep(500);
      }
      await sleep(1500);
    });}catch(e){problem=e.message;}
    const confirmed=await inspect(date,reviewed);
    const verified=reviewed.filter((r,i)=>confirmed.rows[i]?.status==='Already present');
    const n=await run(id,leaders,['ack',date,verified]);
    $('matches').replaceChildren();
    reviewed.forEach((r,i)=>line($('matches'),r.name+' · '+(r.slot===1?'Sunday School':'Organization')+' · '+(confirmed.rows[i]?.status==='Already present'?'Verified in LCR':'Still pending')));
    $('status').textContent=n+' confirmed and marked synced. '+(reviewed.length-verified.length)+' pending. '+problem;
  }catch(e){$('status').textContent=e.message+' Preview again to reconcile pending check-ins.';}finally{busy(false);}
};
