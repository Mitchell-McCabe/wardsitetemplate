(function(){
 const {el,rpc}=NP,S=NPService,$=id=>document.getElementById(id);let kind='all',page=1,query='',mine=false,busy=false,review=false,loadId=0,detailVersion=0,boardEnabled=true;
 function keys(){try{return JSON.parse(localStorage.getItem('ward-service-listings')||'[]').filter(x=>x&&typeof x.id==='string'&&typeof x.token==='string').slice(0,100);}catch{return[];}}
 function saveKey(value){const list=keys().filter(x=>x.id!==value.id);list.unshift({id:value.id,token:value.manage_token});try{localStorage.setItem('ward-service-listings',JSON.stringify(list.slice(0,100)));return true;}catch{return false;}}
 function dialog(title){detailVersion++;$('sb-dialog-title').textContent=title;$('sb-dialog-error').hidden=true;$('sb-dialog-body').replaceChildren();if(!$('sb-dialog').open)$('sb-dialog').showModal();document.body.classList.add('signup-open');}
 function error(e){$('sb-dialog-error').textContent=e.message;$('sb-dialog-error').hidden=false;}
 $('sb-close').addEventListener('click',()=>{if(!busy)$('sb-dialog').close();});$('sb-dialog').addEventListener('cancel',e=>{if(busy)e.preventDefault();});$('sb-dialog').addEventListener('close',()=>document.body.classList.remove('signup-open'));
 function filters(){
  const options=[['all','All listings'],['lend','Items to lend'],['borrow','Wanted items'],['need_help','Help wanted'],['offer_help','Help offered'],['project','Projects']];
  const box=$('sb-filters');
  for(const [value,label] of options){
   const button=el('button',{class:'chip',type:'button','aria-pressed':String(kind===value)},label);
   button.addEventListener('click',()=>{
    if(kind===value)return;
    kind=value;page=1;
    for(const chip of box.children)chip.setAttribute('aria-pressed',String(chip===button));
    load();
   });
   box.appendChild(button);
  }
 }
 async function load(){const v=++loadId;$('sb-message').textContent='Loading…';try{
  let items,total,enabled=true;if(mine){items=await rpc('service_my_listings',{p_keys:keys()});total=items.length;}else{const data=await rpc('service_board',{p_kind:kind,p_query:query,p_page:page});items=data.items;total=data.total;enabled=data.enabled;boardEnabled=enabled;review=!!data.review_listings;}
  if(v!==loadId)return;$('sb-new').hidden=!boardEnabled;$('sb-browse').hidden=mine||!enabled;$('sb-pages').replaceChildren();$('sb-list').replaceChildren();
  $('sb-message').textContent=mine?'Listings created on this device. Ask a leader for changes from another device.':!enabled?'The service board is closed right now.':total+' open '+(total===1?'listing':'listings');
  if(!items.length){
   const filtered=kind!=='all'||!!query;
   const title=mine?'No listings on this device':!enabled?'The board is closed':filtered?'No matching listings':'No listings yet';
   const copy=mine?'Listings you create on this device will appear here.':!enabled?'Please check back later.':filtered?'Try another search or listing type.':'Post an item, a request for help, or a service project.';
   $('sb-list').appendChild(el('div',{class:'sb-empty'},[el('h3',{},title),el('p',{class:'muted'},copy)]));
  }
  for(const item of items)$('sb-list').appendChild(S.card(item,openDetail,mine));
  if(!mine&&enabled&&total>20){const count=Math.ceil(total/20);$('sb-pages').append(el('button',{class:'btn secondary',type:'button',disabled:page<=1?'':null,onclick:()=>{page--;load();}},'Previous'),el('span',{},page+' / '+count),el('button',{class:'btn secondary',type:'button',disabled:page>=count?'':null,onclick:()=>{page++;load();}},'Next'));}
 }catch(e){if(v===loadId)$('sb-message').textContent='Could not load listings: '+e.message;}}
 function openDetail(p){dialog(p.title);const detail=detailVersion,body=$('sb-dialog-body');body.append(el('span',{class:'sb-kind sb-kind-'+p.kind},S.label(p.kind)),S.facts(p),el('p',{class:'sb-full-details'},p.details),el('p',{class:'muted'},'Shared by '+p.contact_name));
  if(p.review_note)body.appendChild(el('p',{class:'notice'},'Leader note: '+p.review_note));
  if(!p.status||p.status==='approved'){
   const button=el('button',{class:'btn',type:'button',onclick:async()=>{button.disabled=true;try{const c=await rpc('service_contact',{p_id:p.id});if(detail===detailVersion){button.replaceWith(S.contact(c));}}catch(e){error(e);button.disabled=false;}}},'Show contact details');
   if(!p.resolution||p.resolution==='open')body.append(button,el('p',{class:'muted'},'Contact them directly to coordinate borrowing, helping, or joining the project.'));
  }else body.appendChild(el('p',{class:'notice'},p.status==='pending'?'Waiting for leader approval. Your listing is not public yet.':'This listing was not approved. Contact a leader if you have questions.'));
  const key=keys().find(x=>x.id===p.id);if(key){const select=el('select',{'aria-label':'Listing availability'},[['open','Open'],['fulfilled','Fulfilled'],['closed','Closed']].map(([v,l])=>el('option',{value:v},l)));select.value=p.resolution||'open';const save=el('button',{class:'btn secondary',type:'button',onclick:async()=>{busy=true;save.disabled=true;try{await rpc('service_manage',{p_id:p.id,p_token:key.token,p_resolution:select.value});$('sb-dialog').close();await load();}catch(e){error(e);save.disabled=false;}finally{busy=false;}}},'Update listing');body.appendChild(el('section',{class:'sb-manage'},[el('h3',{},'Manage your listing'),el('p',{class:'muted'},'Mark a request fulfilled or close a listing when it is no longer available. Reopening does not bypass leader approval.'),select,save]));}
 }
 $('sb-new').addEventListener('click',()=>{dialog('New listing');const form=S.form({},{review,kind:mine||kind==='all'?'lend':kind}),submit=el('button',{type:'submit',class:'btn'},'Submit listing');form.el.appendChild(submit);$('sb-dialog-body').appendChild(form.el);form.el.addEventListener('submit',async e=>{e.preventDefault();if(busy)return;const invalid=form.validate();if(invalid){error(Error(invalid));return;}busy=true;submit.disabled=true;$('sb-dialog-error').hidden=true;try{const result=await rpc('service_submit',{p_data:form.values(),p_website:form.website()});const saved=saveKey(result);dialog(result.status==='pending'?'Sent for approval':'Listing shared');$('sb-dialog-body').append(el('p',{},result.status==='pending'?'A leader will review this before it appears publicly.':'Your listing is now on the ward board.'),el('p',{class:'muted'},saved?'You can close or mark it fulfilled under My listings on this device.':'This browser could not save access to manage the listing. Ask a leader to update or close it.'),el('button',{type:'button',class:'btn',onclick:()=>{$('sb-dialog').close();}},'Done'));await load();}catch(e){error(e);submit.disabled=false;}finally{busy=false;}});});
 $('sb-mine').addEventListener('click',()=>{mine=!mine;page=1;$('sb-mine').setAttribute('aria-pressed',String(mine));$('sb-mine').textContent=mine?'Back to ward listings':'My listings';$('sb-board-title').textContent=mine?'My listings':'Ward listings';load();});
 let timer;$('sb-search').addEventListener('input',()=>{clearTimeout(timer);timer=setTimeout(()=>{query=$('sb-search').value.trim();page=1;load();},250);});
 filters();NP.loadSiteSettings().then(()=>$('sb-ward').textContent=NP.C.wardName);load();setInterval(()=>{if(!document.hidden&&!$('sb-dialog').open)load();},60000);
})();
