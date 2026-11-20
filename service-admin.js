window.NPServiceAdmin=(function(){
 const {el,rpc}=NP,S=NPService,$=id=>document.getElementById(id);let getPass,setPending,badgeVersion=0,page=1,version=0,busy=false,dialogBusy=false;
 async function load(settings=false){const v=++version,b=++badgeVersion;$('sb-admin-msg').textContent='Loading…';try{const data=await rpc('admin_service_state',{p_pass:getPass(),p_status:$('sb-admin-filter').value,p_page:page});if(v!==version)return;
  if(settings){$('sb-enabled').checked=data.settings.enabled;$('sb-review-listings').checked=data.settings.review_listings;}
  if(b===badgeVersion)setPending(Number(data.pending)||0);$('sb-admin-msg').textContent=data.total+' '+(data.total===1?'listing':'listings')+' · '+data.pending+' waiting for approval';$('sb-admin-list').replaceChildren();
  if(!data.items.length)$('sb-admin-list').appendChild(el('p',{class:'card muted'},'No listings in this view.'));
  for(const p of data.items){const card=S.card(p,open);const actions=el('div',{class:'sb-admin-actions'});if(p.status!=='approved')actions.appendChild(button('Approve',()=>review(p,'approved')));if(p.status==='pending')actions.appendChild(button('Reject',()=>review(p,'rejected'),'danger'));actions.appendChild(button('Edit / manage',()=>open(p)));card.appendChild(actions);$('sb-admin-list').appendChild(card);}
  $('sb-admin-pages').replaceChildren();if(data.total>30){const max=Math.ceil(data.total/30);$('sb-admin-pages').append(el('button',{type:'button',class:'chip',disabled:page<=1?'':null,onclick:()=>{page--;load();}},'Previous'),el('span',{},page+' / '+max),el('button',{type:'button',class:'chip',disabled:page>=max?'':null,onclick:()=>{page++;load();}},'Next'));}
 }catch(e){$('sb-admin-msg').textContent=e.message;}}
 function button(label,fn,extra=''){return el('button',{class:'chip '+extra,type:'button',onclick:fn},label);}
 async function review(p,status){if(busy)return;busy=true;try{await rpc('admin_service_review',{p_pass:getPass(),p_id:p.id,p_status:status,p_note:p.review_note||''});await load();}catch(e){NP.toast(e.message,5000);}finally{busy=false;}}
 function error(e){$('sb-admin-dialog-error').textContent=e.message;$('sb-admin-dialog-error').hidden=false;}
 function open(p){$('sb-admin-dialog-title').textContent=p.title;$('sb-admin-dialog-error').hidden=true;const body=$('sb-admin-dialog-body');body.replaceChildren();
  body.append(el('p',{class:'notice'},p.status+' · '+p.resolution),S.contact(p));
  const status=el('select',{id:'sb-review-status'},[['pending','Pending review'],['approved','Approved / published'],['rejected','Rejected / hidden']].map(([v,l])=>el('option',{value:v},l)));status.value=p.status;
  const resolution=el('select',{id:'sb-resolution'},[['open','Open'],['fulfilled','Fulfilled'],['closed','Closed']].map(([v,l])=>el('option',{value:v},l)));resolution.value=p.resolution;
  const note=el('textarea',{id:'sb-review-note',rows:2,maxlength:500});note.value=p.review_note||'';
  const saveReview=el('button',{class:'btn',type:'button',onclick:async()=>{
   if(dialogBusy)return;dialogBusy=true;saveReview.disabled=true;try{await rpc('admin_service_review',{p_pass:getPass(),p_id:p.id,p_status:status.value,p_note:note.value.trim(),p_resolution:resolution.value});p.status=status.value;p.review_note=note.value.trim();p.resolution=resolution.value;$('sb-admin-dialog').close();await load();}catch(e){error(e);saveReview.disabled=false;}finally{dialogBusy=false;}
  }},'Save review / availability');
  body.appendChild(el('section',{class:'sb-review-form'},[el('h3',{},'Review and availability'),el('div',{class:'field'},[el('label',{for:status.id},'Approval'),status]),el('div',{class:'field'},[el('label',{for:resolution.id},'Availability'),resolution]),el('div',{class:'field'},[el('label',{for:note.id},'Review note (visible to the submitter)'),note]),saveReview]));
  const form=S.form(p,{admin:true}),save=el('button',{type:'submit',class:'btn secondary'},'Save listing details');form.el.prepend(el('h3',{},'Edit listing'));form.el.appendChild(save);form.el.addEventListener('submit',async e=>{e.preventDefault();if(dialogBusy)return;const invalid=form.validate();if(invalid){error(Error(invalid));return;}dialogBusy=true;save.disabled=true;try{await rpc('admin_service_edit',{p_pass:getPass(),p_id:p.id,p_data:form.values()});$('sb-admin-dialog').close();await load();}catch(e){error(e);save.disabled=false;}finally{dialogBusy=false;}});body.appendChild(form.el);
  $('sb-admin-dialog').showModal();document.body.classList.add('signup-open');
 }
 function init(ctx){getPass=ctx.getPass;setPending=ctx.setPending;$('sb-admin-refresh').addEventListener('click',()=>load());$('sb-admin-filter').addEventListener('change',()=>{page=1;load();});
  $('sb-settings-form').addEventListener('submit',async e=>{e.preventDefault();if(busy)return;busy=true;$('sb-settings-save').disabled=true;try{await rpc('admin_service_settings',{p_pass:getPass(),p_enabled:$('sb-enabled').checked,p_review_listings:$('sb-review-listings').checked});$('sb-settings-msg').textContent='Service settings saved.';await load();}catch(e){$('sb-settings-msg').textContent=e.message;}finally{busy=false;$('sb-settings-save').disabled=false;}});
  $('sb-admin-dialog-close').addEventListener('click',()=>{if(!dialogBusy)$('sb-admin-dialog').close();});$('sb-admin-dialog').addEventListener('cancel',e=>{if(dialogBusy)e.preventDefault();});$('sb-admin-dialog').addEventListener('close',()=>document.body.classList.remove('signup-open'));
 }
 async function refreshBadge(){const b=++badgeVersion;try{const data=await rpc('admin_service_state',{p_pass:getPass(),p_status:'pending',p_page:1});if(b===badgeVersion)setPending(Number(data.pending)||0);}catch{}}
 return{init,refreshBadge,open(){page=1;return load(true);}};
})();
