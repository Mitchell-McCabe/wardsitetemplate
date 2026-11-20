(function(){
 const {el,rpc}=NP, D=NPDeclarations, $=id=>document.getElementById(id);
 let data=null, chosen=null, contactMode=false, busy=false;
 let nextName=0;
 function addName(focus=true){
  if(busy||$('decl-names').children.length>=20)return;
  const id='decl-name-'+(++nextName),first=!$('decl-names').children.length;
  const input=el('input',{id,type:'text',class:'decl-person-name',required:'',maxlength:120,autocomplete:'off',placeholder:first?'Full name':'Additional person’s full name','aria-label':first?'Full name':'Additional person’s full name'});
  const row=el('div',{class:'decl-name-row'},input);
  if(!first)row.appendChild(el('button',{type:'button',class:'chip','aria-label':'Remove this person',onclick:()=>{if(busy)return;row.remove();$('decl-add-name').disabled=false;}},'Remove'));
  $('decl-names').appendChild(row);$('decl-add-name').disabled=$('decl-names').children.length>=20;if(focus)input.focus();
 }
 function resetNames(){nextName=0;$('decl-names').replaceChildren();addName(false);}
 $('decl-add-name').addEventListener('click',()=>addName());resetNames();
 async function load(){
  try{
   data=await rpc('declarations_public');const open=!!data?.enabled;
   $('decl-open').hidden=!open;$('decl-closed').hidden=open;
   if(open){
    $('decl-year-heading').textContent=data.year+' appointments';const box=$('decl-public-slots');box.replaceChildren();
    const groups=new Map();for(const slot of data.slots||[]){const day=D.day(slot.starts_at);if(!groups.has(day))groups.set(day,[]);groups.get(day).push(slot);}
    if(!groups.size)box.appendChild(el('p',{class:'card'},'There are no open appointments right now. You can request help scheduling below.'));
    for(const [day,slots] of groups)box.appendChild(el('section',{class:'card decl-day'},[el('h3',{},day),el('div',{class:'decl-slot-grid'},slots.map(s=>el('button',{type:'button',class:'btn secondary','aria-label':'Reserve '+D.slotLabel(s),onclick:()=>openForm(s)},D.time(s.starts_at))))]));
   }
  }catch(e){$('decl-open').hidden=true;$('decl-closed').hidden=false;$('decl-closed').replaceChildren(el('h2',{},'Could not load appointments'),el('p',{},e.message),el('button',{class:'btn secondary',type:'button',onclick:load},'Try again'));}
  finally{$('decl-loading').hidden=true;}
 }
 function openForm(slot){
  chosen=slot;contactMode=!slot;$('decl-signup-title').textContent=contactMode?'Request help scheduling':'Reserve an appointment';$('decl-signup-time').textContent=contactMode?'The executive secretary will contact you to arrange a time.':D.slotLabel(slot);
  $('decl-submit').textContent=contactMode?'Send contact request':'Reserve this time';$('decl-public-error').hidden=true;$('decl-signup-dialog').showModal();document.body.classList.add('signup-open');
 }
 $('decl-request').addEventListener('click',()=>openForm(null));
 $('decl-dialog-close').addEventListener('click',()=>{if(!busy)$('decl-signup-dialog').close();});
 $('decl-signup-dialog').addEventListener('cancel',e=>{if(busy)e.preventDefault();});
 $('decl-signup-dialog').addEventListener('close',()=>document.body.classList.remove('signup-open'));
 $('decl-signup-form').addEventListener('submit',async e=>{
  e.preventDefault();if(busy)return;
  const names=[...document.querySelectorAll('.decl-person-name')].map(x=>x.value.trim()).filter(Boolean),phone=$('decl-phone').value.trim(),error=$('decl-public-error');
  error.hidden=true;
  if(!names.length||names.length>20||names.some(n=>n.length<2)||(phone&&(phone.replace(/\D/g,'').length<10||phone.replace(/\D/g,'').length>15))){error.textContent='Enter each person’s full name and, if provided, a valid phone number.';error.hidden=false;return;}
  busy=true;$('decl-submit').disabled=true;$('decl-dialog-close').disabled=true;
  const args={p_names:names,p_phone:phone,p_email:$('decl-email').value.trim(),p_note:$('decl-note').value.trim(),p_website:$('decl-website').value};
  try{
   const result=await rpc(contactMode?'declarations_request_contact':'declarations_book',contactMode?args:{...args,p_slot:chosen.id});
   $('decl-signup-dialog').close();$('decl-signup-form').reset();nextName=0;$('decl-names').replaceChildren();
   const panel=$('decl-success');panel.hidden=false;panel.replaceChildren(el('h2',{},contactMode?'Request received':'Appointment reserved'),el('p',{},contactMode?'The executive secretary will reach out to arrange a time.':D.slotLabel(result)),el('p',{class:'muted'},contactMode?'Your contact information is visible only to leaders.':'If you need to change this appointment, contact the executive secretary.'));
   panel.focus({preventScroll:true});panel.scrollIntoView({behavior:'smooth',block:'start'});await load();
  }catch(e){error.textContent=e.message;error.hidden=false;await load();}
  finally{busy=false;if(!$('decl-names').children.length)resetNames();$('decl-submit').disabled=false;$('decl-dialog-close').disabled=false;}
 });
 (async()=>{await NP.loadSiteSettings();$('decl-ward').textContent=NP.C.wardName;await load();setInterval(()=>{if(!document.hidden&&!$('decl-signup-dialog').open)load();},30000);})();
})();
