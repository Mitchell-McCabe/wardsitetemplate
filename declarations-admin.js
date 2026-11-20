window.NPDeclarationsAdmin=(function(){
 const {el,rpc}=NP,D=NPDeclarations,$=id=>document.getElementById(id);
 let getPass,state=null,filter='all',csv=null,mutating=0,loadVersion=0,dialogBusy=false,importVersion=0;
 const year=()=>Number($('decl-admin-year').value);
 const args=()=>({p_pass:getPass(),p_year:year()});
 const statusLabel=s=>(D.statuses.find(x=>x[0]===s)||['',s])[1];
 async function load(settings=false){
  const y=year(),version=++loadVersion;if(!Number.isInteger(y)||y<2020||y>2100){$('decl-admin-message').textContent='Choose a year from 2020 to 2100.';return;}
  try{
   const result=await rpc('admin_declarations_state',{p_pass:getPass(),p_year:y});if(version!==loadVersion||year()!==y)return;state=result;
   if(settings){$('decl-minutes').value=state.season.slot_minutes;$('decl-enabled').checked=state.season.enabled;}
   renderRoster();renderRanges();renderSlots();renderRequests();
  }catch(e){$('decl-admin-message').textContent='Could not load declarations: '+e.message;}
 }
 async function action(button,msg,task,success){
  if(button)button.disabled=true;mutating++;if(msg)msg.textContent='Saving…';
  try{const result=await task();if(msg)msg.textContent=typeof success==='function'?success(result):(success||'Saved.');await load(false);return true;}
  catch(e){if(msg)msg.textContent=e.message;else NP.toast(e.message,5000);return false;}
  finally{mutating--;if(button)button.disabled=false;}
 }
 function contact(phone,email){return el('div',{class:'decl-contact-lines'},[phone?el('a',{href:'tel:'+phone.replace(/[^0-9+]/g,'')},phone):null,email?el('a',{href:'mailto:'+email},email):null]);}
 function renderRoster(){
  const box=$('decl-roster'),q=$('decl-member-search').value.trim().toLowerCase();box.replaceChildren();
  const filters=$('decl-status-filters');filters.replaceChildren(el('button',{type:'button',class:'chip'+(filter==='all'?' on':''),onclick:()=>{filter='all';renderRoster();}},'All · '+state.members.length));
  for(const [value,label]of D.statuses){const n=state.members.filter(m=>m.status===value).length;filters.appendChild(el('button',{type:'button',class:'chip decl-status-key decl-status-'+value+(filter===value?' on':''),onclick:()=>{filter=value;renderRoster();}},label+' · '+n));}
  const shown=state.members.filter(m=>(filter==='all'||m.status===filter)&&(!q||[m.full_name,m.household,m.contact_phone,m.contact_email].join(' ').toLowerCase().includes(q)));
  if(!shown.length){box.appendChild(el('p',{class:'muted'},state.members.length?'No members match this filter.':'Import this year’s member list to get started.'));return;}
  const rank=new Map(D.statuses.map(([value],i)=>[value,i]));
  shown.sort((a,b)=>($('decl-member-sort').value==='status'?(rank.get(a.status)-rank.get(b.status)):0)||a.full_name.localeCompare(b.full_name,'en',{sensitivity:'base',numeric:true})||a.id.localeCompare(b.id));
  const list=el('div',{class:'decl-member-list'});
  for(const member of shown){list.appendChild(el('button',{type:'button',class:'decl-member-row decl-status-'+member.status,'aria-label':member.full_name+', '+statusLabel(member.status)+'. '+(member.contact_phone||'No phone number')+'. Open member details',onclick:()=>openMember(member.id)},[el('span',{class:'decl-member-name'},member.full_name),el('span',{},' — '+(member.contact_phone||'No phone'))]));}
  box.appendChild(list);
 }
 function openMember(id){
  const member=state.members.find(m=>m.id===id);if(!member)return;
  showDialog(member.full_name);
  const select=el('select',{id:'decl-member-status','aria-label':'Member status'},D.statuses.map(([v,l])=>el('option',{value:v},l)));select.value=member.status;
  const save=el('button',{type:'button',class:'btn',onclick:()=>changeStatus(true)},'Save status');
  const auto=el('button',{type:'button',class:'btn secondary',onclick:()=>changeStatus(false)},'Use automatic status');
  async function changeStatus(manual){
   dialogBusy=true;save.disabled=true;auto.disabled=true;select.disabled=true;
   try{await rpc('admin_declarations_status',{p_pass:getPass(),p_id:member.id,p_status:select.value,p_manual:manual});await load(false);openMember(id);NP.toast('Status saved.');}
   catch(error){dialogError(error);save.disabled=false;auto.disabled=false;select.disabled=false;}finally{dialogBusy=false;}
  }
  const remove=el('button',{type:'button',class:'chip danger',onclick:async()=>{dialogBusy=true;try{await removeMember(member,remove);}finally{dialogBusy=false;}}},'Remove member');
  $('decl-leader-body').append(
   contact(member.contact_phone,member.contact_email),
   member.household?el('p',{class:'muted'},member.household):el('span'),
   el('p',{class:'decl-dialog-time'},member.starts_at?D.slotLabel(member):'No appointment scheduled.'),
   el('div',{class:'field'},[el('label',{for:'decl-member-status'},'Status'),select]),
   el('p',{class:'muted'},member.manual_override?'Status is set manually. Automatic updates are paused.':'Automatic status tracking is active.'),
   el('div',{class:'decl-actions'},[save,member.manual_override?auto:null]),
   member.booking_id?el('button',{type:'button',class:'btn secondary',onclick:()=>openBooked(state.slots.find(s=>s.booking?.id===member.booking_id))},'View appointment / cancel'):el('button',{type:'button',class:'btn secondary',onclick:()=>openManual(null,[member.id])},'Schedule appointment'),
   remove
  );
 }
 async function removeMember(member,button){
  const booking=state.slots.find(s=>s.booking?.id===member.booking_id)?.booking;
  const detail=booking?(booking.member_ids?.length>1||booking.names.length>1?' Their shared appointment will remain booked for the other members.':' Their appointment will be cancelled and the time will reopen.') : '';
  if(!confirm('Remove '+member.full_name+' from the '+year()+' declaration list?'+detail+' This affects only this year. A later import containing this person can add them again.'))return;
  const ok=await action(button,$('decl-admin-message'),()=>rpc('admin_declarations_remove_member',{p_pass:getPass(),p_id:member.id}),'Member removed.');if(ok)$('decl-leader-dialog').close();
 }
 function openAddMember(){
  const targetYear=year();showDialog('Add member to '+targetYear);
  const inputs={};const fields=[['name','Full name','text',120,true],['phone','Phone (optional)','tel',40,false],['email','Email (optional)','email',200,false],['household','Household (optional)','text',120,false],['source_id','Member ID (optional)','text',120,false]];
  const children=fields.map(([key,label,type,max,required])=>{const input=el('input',{id:'decl-add-'+key,type,maxlength:max,required:required?'':null,placeholder:key==='phone'?'123-456-7890':null});inputs[key]=input;return el('div',{class:'field'},[el('label',{for:'decl-add-'+key},label),input]);});
  const submit=el('button',{class:'btn',type:'submit'},'Add member');
  const form=el('form',{class:'decl-manual-form',onsubmit:async e=>{
   e.preventDefault();dialogBusy=true;submit.disabled=true;
   try{await rpc('admin_declarations_add_member',{p_pass:getPass(),p_year:targetYear,...Object.fromEntries(Object.entries(inputs).map(([k,v])=>['p_'+k,v.value.trim()]))});$('decl-leader-dialog').close();$('decl-admin-message').textContent='Member added as Not scheduled.';await load(false);}
   catch(error){dialogError(error);submit.disabled=false;}finally{dialogBusy=false;}
  }},[...children,el('p',{class:'muted'},'Use a distinct member ID for different people with the same name. New members start as Not scheduled.'),submit]);
  $('decl-leader-body').appendChild(form);inputs.name.focus();
 }
 function renderRanges(){
  const box=$('decl-ranges');box.replaceChildren();
  if(!state.ranges.length)box.appendChild(el('p',{class:'muted'},'No availability has been added for this year.'));
  for(const range of state.ranges){const date=new Date(range.meeting_date+'T12:00:00Z').toLocaleDateString('en-US',{timeZone:'UTC',weekday:'short',month:'short',day:'numeric'});
   const clock=t=>{const [h,m]=t.split(':').map(Number);return (h%12||12)+':'+String(m).padStart(2,'0')+(h<12?' AM':' PM');};
   box.appendChild(el('div',{class:'decl-range-row'},[el('span',{},[el('b',{},date+' · '+clock(range.start_time)+'–'+clock(range.end_time)),el('span',{class:'muted decl-block'},range.slot_minutes+'-minute interviews')]),el('button',{class:'chip danger',type:'button',onclick:e=>{if(confirm('Remove this availability? Ranges with booked appointments must be cleared first.'))action(e.currentTarget,$('decl-range-msg'),()=>rpc('admin_declarations_remove_range',{p_pass:getPass(),p_id:range.id}),'Availability removed.');}},'Remove')]));
  }
 }
 function renderSlots(){
  const box=$('decl-admin-slots');box.replaceChildren();const showPast=$('decl-show-past').checked;
  const slots=state.slots.filter(s=>showPast||new Date(s.ends_at)>new Date());
  const groups=new Map();for(const slot of slots){const day=D.day(slot.starts_at);if(!groups.has(day))groups.set(day,[]);groups.get(day).push(slot);}
  if(!slots.length)box.appendChild(el('p',{class:'muted'},'No upcoming slots. Add an availability range above.'));
  for(const [day,list]of groups)box.appendChild(el('section',{class:'decl-day'},[el('h4',{},day),el('div',{class:'decl-slot-grid'},list.map(slot=>el('button',{type:'button',class:'decl-admin-slot'+(slot.booking?' booked':''),onclick:()=>slot.booking?openBooked(slot):openManual(slot,[])},[el('b',{},D.time(slot.starts_at)),el('span',{},slot.booking?slot.booking.names.join(', '):'Open')])))]));
 }
 function renderRequests(){
  const box=$('decl-contact-queue');box.replaceChildren();if(!state.requests.length)box.appendChild(el('p',{class:'muted'},'No open contact requests.'));
  for(const request of state.requests)box.appendChild(el('article',{class:'decl-request-card'},[
   el('h4',{},request.names.join(', ')),contact(request.phone,request.email),
   request.note?el('p',{class:'decl-note'},request.note):null,
   !request.member_ids.length?el('p',{class:'notice'},'Names were not matched to the imported list. Choose the correct members when scheduling.'):null,
   el('div',{class:'decl-actions'},[
    el('button',{type:'button',class:'btn secondary',onclick:()=>openManual(null,request.member_ids,request)},'Schedule'),
    el('button',{type:'button',class:'chip',onclick:e=>action(e.currentTarget,$('decl-admin-message'),()=>rpc('admin_declarations_resolve_request',{p_pass:getPass(),p_id:request.id}),'Contact request marked handled.')},'Mark handled'),
   ]),
  ]));
 }
 function showDialog(title){$('decl-leader-title').textContent=title;$('decl-leader-error').hidden=true;$('decl-leader-body').replaceChildren();if(!$('decl-leader-dialog').open)$('decl-leader-dialog').showModal();document.body.classList.add('signup-open');}
 function dialogError(e){$('decl-leader-error').textContent=e.message;$('decl-leader-error').hidden=false;}
 function openBooked(slot){
  if(!slot?.booking){NP.toast('This appointment is no longer on the calendar. Refresh and try again.');return;}
  showDialog('Declaration appointment');const b=slot.booking;
  const cancel=el('button',{class:'btn danger',type:'button',onclick:async()=>{
   if(!confirm('Cancel this appointment? The time will become available again.'))return;
   dialogBusy=true;cancel.disabled=true;
   try{await rpc('admin_declarations_cancel',{p_pass:getPass(),p_booking:b.id});$('decl-leader-dialog').close();await load(false);}
   catch(e){dialogError(e);cancel.disabled=false;}finally{dialogBusy=false;}
  }},'Cancel appointment');
  $('decl-leader-body').append(el('p',{class:'decl-dialog-time'},D.slotLabel(slot)),el('p',{},b.names.join(', ')),contact(b.phone,b.email),b.note?el('p',{class:'decl-note'},b.note):el('p',{class:'muted'},'No notes.'),cancel);
 }
 function openManual(slot,selected,request){
  const available=state.slots.filter(s=>!s.booking&&new Date(s.starts_at)>new Date());
  if(!available.length){NP.toast('Add an available time range before scheduling.',5000);return;}
  showDialog('Schedule declaration');const selectedIds=new Set(selected||[]);
  const selectSlot=el('select',{id:'decl-manual-slot',required:''},available.map(s=>el('option',{value:s.id},D.slotLabel(s))));if(slot)selectSlot.value=slot.id;
  const search=el('input',{type:'search',placeholder:'Find members to include','aria-label':'Find members to include'}),choices=el('div',{class:'decl-member-picker'});
  function renderChoices(){
   const q=search.value.toLowerCase();choices.replaceChildren();
   for(const member of state.members.filter(m=>!q||m.full_name.toLowerCase().includes(q))){const input=el('input',{type:'checkbox',checked:selectedIds.has(member.id)?'':null,onchange:e=>{if(e.target.checked)selectedIds.add(member.id);else selectedIds.delete(member.id);}});
    choices.appendChild(el('label',{class:'check'},[input,el('span',{},member.full_name+(member.booking_id?' (already scheduled)':''))]));}
  }
  search.addEventListener('input',renderChoices);renderChoices();
  const first=state.members.find(m=>selectedIds.has(m.id));
  const phone=el('input',{id:'decl-manual-phone',type:'tel',placeholder:'123-456-7890',maxlength:40,value:request?.phone||first?.contact_phone||''}),email=el('input',{id:'decl-manual-email',type:'email',maxlength:200,value:request?.email||first?.contact_email||''}),note=el('textarea',{id:'decl-manual-note',maxlength:1000,rows:2});note.value=request?.note||'';
  const submit=el('button',{type:'submit',class:'btn'},'Schedule selected members');
  const form=el('form',{class:'decl-manual-form',onsubmit:async e=>{
   e.preventDefault();if(!selectedIds.size){dialogError(Error('Choose at least one member.'));return;}
   dialogBusy=true;submit.disabled=true;
   try{await rpc('admin_declarations_book',{...args(),p_slot:selectSlot.value,p_members:[...selectedIds],p_phone:phone.value.trim(),p_email:email.value.trim(),p_note:note.value.trim(),p_request:request?.id||null});$('decl-leader-dialog').close();await load(false);}
   catch(error){dialogError(error);submit.disabled=false;}finally{dialogBusy=false;}
  }},[
   el('div',{class:'field'},[el('label',{for:'decl-manual-slot'},'Appointment time'),selectSlot]),el('h3',{},'Members attending'),search,choices,
   el('div',{class:'field'},[el('label',{for:'decl-manual-phone'},'Phone (optional)'),phone]),
   el('div',{class:'field'},[el('label',{for:'decl-manual-email'},'Email (optional)'),email]),
   el('div',{class:'field'},[el('label',{for:'decl-manual-note'},'Notes (optional)'),note]),submit,
  ]);$('decl-leader-body').appendChild(form);
 }
 const mappings=[['full_name','Full name',['fullname','preferredname','name','membername']],['first_name','First name',['firstname','givenname']],['last_name','Last name',['lastname','surname','familyname']],['phone','Phone',['phone','phonenumber','mobile','mobilephone','individualphone','householdphone']],['email','Email',['email','emailaddress','individualemail','householdemail']],['household','Household',['household','householdname']],['source_id','Member ID',['personuuid','memberid','individualid','uuid']]];
 function records(){
  if(!csv)throw Error('Choose a PDF or CSV file first.');
  const col=key=>$('decl-map-'+key).value;
  if(col('full_name')===''&&(col('first_name')===''||col('last_name')===''))throw Error('Map a full-name column, or both first and last name columns.');
  if(csv.rows.length>3000)throw Error('Import up to 3000 rows at a time.');
  return csv.rows.map((row,i)=>{
   const get=key=>col(key)===''?'':String(row[Number(col(key))]||'').trim();
   const full_name=get('full_name')||[get('first_name'),get('last_name')].filter(Boolean).join(' ');
   if(full_name.length<2)throw Error('Row '+(i+2)+' needs a member name.');
   return {full_name,phone:get('phone'),email:get('email'),household:get('household'),source_id:get('source_id')};
  });
 }
 function previewImport(){
  const box=$('decl-import-preview');box.replaceChildren();
  try{const rows=records();box.appendChild(el('p',{class:'muted'},rows.length+' members ready to import for '+year()+'. Review the list below.'));
   if(csv.pdf){box.appendChild(el('p',{class:'notice'},(csv.ward?'Source: '+csv.ward+'. ':'')+'PDF read on your device. '+rows.filter(r=>!r.phone).length+' members have no phone number. Nothing is saved until you press Import members.'));}
   const t=el('table',{class:'grid'},el('thead',{},el('tr',{},['Name','Phone','Email'].map(x=>el('th',{},x)))));t.appendChild(el('tbody',{},rows.map(r=>el('tr',{},[el('td',{},r.full_name),el('td',{},r.phone),el('td',{},r.email)]))));box.appendChild(el('div',{class:'decl-table-wrap'},t));$('decl-import-button').disabled=false;
  }catch(e){box.appendChild(el('p',{class:'notice'},e.message));$('decl-import-button').disabled=true;}
 }
 function init(ctx){
  getPass=ctx.getPass;$('decl-admin-year').value=D.currentYear();
  $('decl-add-member').addEventListener('click',openAddMember);
  document.querySelector('.tab[data-pane=declarations]').addEventListener('click',()=>load(true));
  $('decl-admin-refresh').addEventListener('click',()=>load(false));
  $('decl-admin-year').addEventListener('change',()=>{state=null;load(true);if(csv)previewImport();});
  $('decl-settings-form').addEventListener('submit',e=>{e.preventDefault();action($('decl-settings-save'),$('decl-admin-message'),()=>rpc('admin_declarations_settings',{...args(),p_enabled:$('decl-enabled').checked,p_minutes:Number($('decl-minutes').value)}),'Year settings saved.');});
  $('decl-member-sort').addEventListener('change',()=>{if(state)renderRoster();});
  $('decl-member-search').addEventListener('input',()=>{if(state)renderRoster();});$('decl-show-past').addEventListener('change',()=>{if(state)renderSlots();});
  $('decl-range-form').addEventListener('submit',e=>{e.preventDefault();action($('decl-range-add'),$('decl-range-msg'),()=>rpc('admin_declarations_add_range',{...args(),p_date:$('decl-range-date').value,p_start:$('decl-range-start').value,p_end:$('decl-range-end').value}),n=>n+' appointment slots created.');});
  $('decl-csv').addEventListener('change',async()=>{
   const file=$('decl-csv').files[0],version=++importVersion;csv=null;$('decl-mapping').replaceChildren();$('decl-import-preview').replaceChildren();if(!file){$('decl-import-button').disabled=true;return;}
   $('decl-import-button').disabled=true;$('decl-import-msg').textContent='Reading file…';
   try{
    if(file.size>10*1024*1024)throw Error('Choose a PDF or CSV file under 10 MB.');
    const bytes=new Uint8Array(await file.arrayBuffer());const encoding=bytes[0]===255&&bytes[1]===254?'utf-16le':bytes[0]===254&&bytes[1]===255?'utf-16be':'utf-8';
    let parsed;if(/\.pdf$/i.test(file.name)||file.type==='application/pdf'){const {readMemberPdf}=await import('./declarations-pdf.mjs?v=1');parsed=await readMemberPdf(bytes,(page,total)=>{if(version===importVersion)$('decl-import-msg').textContent='Reading PDF page '+page+' of '+total+'…';});}else{parsed=D.parseCsv(new TextDecoder(encoding).decode(bytes));}
    if(version!==importVersion)return;csv=parsed;const box=$('decl-mapping');box.replaceChildren();
    const norm=s=>s.toLowerCase().replace(/[^a-z0-9]/g,'');
    for(const [key,label,aliases]of mappings){const select=el('select',{id:'decl-map-'+key,onchange:previewImport},[el('option',{value:''},'Not included'),...csv.headers.map((h,i)=>el('option',{value:String(i)},h||'Column '+(i+1)))]);const match=csv.headers.findIndex(h=>aliases.includes(norm(h)));select.value=match<0?'':String(match);box.appendChild(el('div',{class:'field'},[el('label',{for:'decl-map-'+key},label),select]));}
    $('decl-import-msg').textContent='';previewImport();
   }catch(e){if(version!==importVersion)return;csv=null;$('decl-import-msg').textContent=e.name==='PasswordException'?'This PDF is password protected. Save an unprotected copy from the print menu.':e.message;}
  });
  $('decl-import-button').addEventListener('click',()=>{
   let rows;try{rows=records();}catch(e){$('decl-import-msg').textContent=e.message;return;}
   action($('decl-import-button'),$('decl-import-msg'),()=>rpc('admin_declarations_import',{...args(),p_records:rows}),n=>n+' members imported. Existing statuses and appointments were preserved.');
  });
  $('decl-leader-close').addEventListener('click',()=>{if(!dialogBusy)$('decl-leader-dialog').close();});
  $('decl-leader-dialog').addEventListener('cancel',e=>{if(dialogBusy)e.preventDefault();});$('decl-leader-dialog').addEventListener('close',()=>document.body.classList.remove('signup-open'));
  setInterval(()=>{if(!document.hidden&&$('pane-announcements').classList.contains('on')&&!mutating&&!$('decl-leader-dialog').open&&document.querySelector('.tab[data-pane=declarations]').classList.contains('on')&&!document.activeElement?.closest('#decl-roster'))load(false);},30000);
 }
 return {init};
})();
