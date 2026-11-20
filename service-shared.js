window.NPService=(function(){
 const {el}=NP;
 const kinds=[['lend','Lend an item'],['borrow','Borrow an item'],['need_help','Need help'],['offer_help','Offer help'],['project','Service project']];
 const label=k=>(kinds.find(x=>x[0]===k)||['',k])[1];
 const date=d=>d?NP.fmtDate(d,{weekday:'short',month:'short',day:'numeric'}):'';
 function contact(c){return el('div',{class:'sb-contact'},[
  el('b',{},c.contact_name||c.name||''),c.phone?el('a',{href:'tel:'+c.phone.replace(/[^0-9+]/g,'')},c.phone):null,
  c.email?el('a',{href:'mailto:'+encodeURIComponent(c.email)},c.email):null,(c.contact_note||c.note)?el('p',{},c.contact_note||c.note):null
 ]);}
 function facts(p){return el('div',{class:'sb-facts'},[p.category?el('span',{},p.category):null,p.location?el('span',{},p.location):null,p.event_date?el('span',{},date(p.event_date)):null,p.timing?el('span',{},p.timing):null]);}
 function card(p,open,own=false){return el('article',{class:'card sb-card'},[
  el('div',{class:'sb-card-top'},[el('span',{class:'sb-kind sb-kind-'+p.kind},label(p.kind)),own?el('span',{class:'pill '+(p.status==='pending'?'wait':p.status==='approved'?'ok':'off')},p.status+' · '+p.resolution):null]),
  el('button',{type:'button',class:'sb-title',onclick:()=>open(p)},p.title),facts(p),el('p',{class:'sb-excerpt'},p.details),
  el('div',{class:'sb-card-bottom'},[el('span',{class:'muted'},p.contact_name),el('button',{type:'button',class:'chip',onclick:()=>open(p)},'View details')])
 ]);}
 let serial=0;
 function form(initial={},options={}){
  const prefix='sb-form-'+(++serial)+'-',fields={},root=el('form',{class:'sb-form'});
  function field(key,label,type='text',max=200,required=false){
   const input=type==='textarea'?el('textarea',{rows:4,maxlength:max}):el('input',{type,maxlength:max});
   input.id=prefix+key;input.name=key;if(required)input.required=true;input.value=initial[key]||'';
   if(key==='phone'){input.placeholder='123-456-7890';input.autocomplete='tel';input.inputMode='tel';}
   if(key==='contact_name')input.autocomplete='name';if(key==='email')input.autocomplete='email';
   const title=el('label',{for:input.id},label),wrap=el('div',{class:'field'},[title,input]);root.appendChild(wrap);fields[key]=input;return{input,title,wrap};
  }
  const kind=el('select',{id:prefix+'kind',required:''},kinds.map(([k,l])=>el('option',{value:k},l)));kind.value=initial.kind||options.kind||'lend';fields.kind=kind;
  root.appendChild(el('div',{class:'field'},[el('label',{for:kind.id},'What would you like to share?'),kind]));
  const title=field('title','Title','text',120,true),details=field('details','Details','textarea',4000,true);
  field('category','Category (optional)','text',80);
  const location=field('location','Neighborhood / location (optional)','text',200),timing=field('timing','Availability or timing (optional)','text',200);
  field('event_date','Date (optional)','date');
  root.appendChild(el('h3',{},'Contact information'));
  field('contact_name','Your name','text',120,true);
  const contactHelp=el('p',{id:prefix+'contact-help',class:'muted'},'Enter at least one contact method: phone number or email. Both are welcome, but only one is required.');root.appendChild(contactHelp);
  const phone=field('phone','Phone number','tel',40),email=field('email','Email','email',200);
  phone.input.setAttribute('aria-describedby',contactHelp.id);email.input.setAttribute('aria-describedby',contactHelp.id);
  field('contact_note','Contact instructions (optional)','text',300);field('contact_note','Contact instructions (optional)','text',300).input.placeholder='Text first, evenings, pickup arrangements…';
  const note=el('p',{class:'notice sb-review-notice'});root.appendChild(note);
  if(!options.admin){const consent=el('input',{type:'checkbox',required:''});root.appendChild(el('label',{class:'check sb-consent'},[consent,el('span',{},'I agree to share this listing and let people viewing it reveal my contact information to coordinate.')]));}
  const trap=el('input',{type:'text',tabindex:'-1',autocomplete:'off','aria-label':'Leave blank'});root.appendChild(el('div',{class:'honeypot','aria-hidden':'true'},trap));
  function update(){const k=kind.value,labels={lend:['Item available to lend','Include condition, availability, pickup arrangements, and return expectations.'],borrow:['Item you need to borrow','Include size, quantity, how long you need it, and pickup plans.'],need_help:['What do you need help with?','Describe the help needed, timing, and any tools or skills involved.'],offer_help:['What can you help with?','Describe your skills, the help you can offer, and your availability.'],project:['Project title','Describe the work, tools or supplies, volunteer needs, and any special instructions.']}[k];title.title.textContent=labels[0];details.input.placeholder=labels[1];location.input.required=k==='project';location.title.textContent=k==='project'?'Project location':'Neighborhood / location (optional)';timing.title.textContent=k==='borrow'?'How long do you need it? (optional)':'Availability or timing (optional)';note.textContent=k==='project'?'Service projects are sent to leaders for approval before appearing on the board.':options.review?'This listing will be reviewed by a leader before appearing on the board.':'This listing will appear on the board after you submit it.';if(options.admin)note.textContent='Saving edits preserves the current approval decision. Use Approve to publish a pending listing.';}
  kind.addEventListener('change',update);update();
  return{el:root,fields,values:()=>Object.fromEntries(Object.entries(fields).map(([k,v])=>[k,v.value.trim()])),website:()=>trap.value,validate:()=>{const p=Object.fromEntries(Object.entries(fields).map(([k,v])=>[k,v.value.trim()]));if(p.title.length<3||p.details.length<5)return'Add a title and a description.';if(!p.phone&&!p.email)return'Enter a phone number or email.';if(p.phone&&(p.phone.replace(/\D/g,'').length<10||p.phone.replace(/\D/g,'').length>15))return'Enter a valid phone number.';if(p.kind==='project'&&!p.event_date&&!p.timing)return'Enter a date or timing for the project.';return'';}};
 }
 return{kinds,label,date,contact,facts,card,form};
})();
