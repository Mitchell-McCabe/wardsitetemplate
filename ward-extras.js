(() => {
  const { el, rpc, fmtDate } = NP;
  const btn = (label,run) => el('button',{class:'chip',type:'button',onclick:run},label);
  const para = s => el('p',{class:'muted'},s);
  const capture = (form,run) => {
    const status=el('p',{role:'status'}), submit=el('button',{class:'btn',type:'submit'},form.dataset.submit);
    form.append(submit,status);
    form.addEventListener('submit',async e=>{
      e.preventDefault();submit.disabled=true;status.textContent='Saving…';
      try { await run(new FormData(form));status.textContent='Saved.'; }
      catch(err){ status.textContent=err.message; }
      finally{submit.disabled=false;}
    });
  };
  function field(form,name,label,options={},value=''){
    const input=el(options.multiline?'textarea':'input',{name,...options});
    if(options.type!=='file')input.value=value??'';
    form.append(el('label',{class:'field'},[el('span',{},label),input]));
  }
  const photo = async file => {
    if(!file?.size)return null;
    let blob = await NPPosts.compressImage(file,800,.76);
    if (blob.size > 370000) blob = await NPPosts.compressImage(file,560,.68);
    if (blob.size > 370000) throw new Error('This photo is too large. Try a smaller JPEG or PNG.');
    return new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=()=>reject(new Error('Could not read photo'));r.readAsDataURL(blob);});
  };
  function editor(kind,item={},pass=null,done=()=>{}){
    const f=el('form',{class:'card ward-extra-form','data-submit':pass?'Save':'Submit for approval'});
    field(f,'title',kind==='missionary'?'Missionary name':kind==='moment'?'Story title':'Sign-up title or task',{required:'',maxlength:120},item.title);
    field(f,'detail',kind==='missionary'?'Mission name':kind==='moment'?'Short story':'Details (optional)',{...(kind==='signup'?{}:{required:''}),maxlength:kind==='missionary'?120:2000,multiline:kind!=='missionary'},item.detail);
    if(kind==='signup'){
      field(f,'day','Date (optional)',{type:'date'},item.day);
      field(f,'capacity','Number of spots',{type:'number',required:'',min:1,max:500},item.capacity??1);
    }else{
      if(kind==='missionary') field(f,'email','Missionary email (optional)',{type:'email',maxlength:200},item.email);
      field(f,'photo',item.photo?'Replace photo (optional)':kind==='missionary'?'Photo (optional)':'Photo',{type:'file',accept:'image/*',...(item.photo||kind==='missionary'?{}:{required:''})});
      if(kind==='missionary'){
        field(f,'scripture_text','Plaque scripture (optional)',{multiline:true,maxlength:2000,rows:4},item.scripture_text);
        field(f,'scripture_reference','Scripture reference (optional)',{maxlength:120,placeholder:'1 Nephi 3:7'},item.scripture_reference);
      }
      f.append(para('This will appear on the public site. Share photos, stories, and email addresses only with permission.'));
    }
    capture(f,async d=>{
      const common={p_title:d.get('title').trim(),p_detail:d.get('detail').trim(),p_day:d.get('day')||null,p_capacity:Number(d.get('capacity')||1)};
      if (!common.p_title) throw new Error(kind==='missionary'?'Enter the missionary’s name.':'Enter a title.');
      if (kind==='missionary' && !common.p_detail) throw new Error('Enter the mission name.');
      if(pass && kind==='missionary') await rpc('admin_missionary_profile_save',{
        p_pass:pass(),p_id:item.id??null,p_title:common.p_title,p_mission:common.p_detail,
        p_email:d.get('email').trim(),p_photo:await photo(d.get('photo')),
        p_scripture_text:d.get('scripture_text').trim(),p_scripture_reference:d.get('scripture_reference').trim()
      });
      else if(pass) await rpc('admin_ward_extra_save',{p_pass:pass(),p_kind:kind,p_id:item.id??null,...common,p_email:(d.get('email')||'').trim(),p_photo:await photo(d.get('photo')),p_state:'live'});
      else await rpc('ward_extra_request',common);
      done();
    });
    return f;
  }
  function requestWeeklyEmails(item){
    const dialog=el('dialog',{class:'card missionary-email-dialog','aria-labelledby':'missionary-request-title'});
    const f=el('form',{class:'ward-extra-form','data-submit':'Submit request'});
    const heading=el('h2',{id:'missionary-request-title'},'Request weekly emails');
    const close=btn('Close',()=>dialog.close());
    close.setAttribute('aria-label','Close weekly email request');
    f.append(para('Enter the email address you’d like '+item.title+'’s weekly emails sent to. Your request goes to ward leaders.'));
    field(f,'email','Your email',{type:'email',required:'',maxlength:254,autocomplete:'email',autofocus:''});
    capture(f,async d=>{
      await rpc('request_missionary_weekly_email',{p_id:item.id,p_email:d.get('email').trim()});
      f.replaceWith(el('p',{role:'status'},'Request received. Ward leaders can now see your signup.'));
      close.focus();
    });
    dialog.append(el('header',{class:'missionary-request-header'},[heading,close]),f);
    dialog.addEventListener('close',()=>dialog.remove(),{once:true});
    document.body.append(dialog);
    dialog.showModal();
  }

  function weeklyEmailList(item,pass,onRemove){
    const summary=el('summary',{},'Weekly email requests'), list=el('ul',{class:'missionary-subscribers'});
    const status=el('p',{role:'status',class:'muted'});
    const details=el('details',{class:'missionary-subscriber-panel'},[summary,status,list]);
    let loading=false;
    async function refresh(){
      if(loading)return;
      loading=true;list.replaceChildren();status.textContent='Loading…';
      try{
        const emails=await rpc('admin_missionary_weekly_emails',{p_pass:pass(),p_id:item.id});
        summary.textContent='Weekly email requests ('+emails.length+')';
        status.textContent=emails.length?'':'No requests yet.';
        for(const email of emails){
          const remove=btn('×',async ()=>{
            remove.disabled=true;
            try{
              await rpc('admin_remove_missionary_weekly_email',{p_pass:pass(),p_id:item.id,p_email:email});
              onRemove();
              await refresh();
              summary.focus();
            }catch(e){status.textContent='Could not remove this address: '+e.message;remove.disabled=false;}
          });
          remove.setAttribute('aria-label','Remove '+email+' from weekly emails');
          list.append(el('li',{},[el('span',{},email),remove]));
        }
      }catch(e){status.replaceChildren('Could not load requests. ',btn('Try again',refresh));}
      finally{loading=false;}
    }
    details.addEventListener('toggle',()=>{if(details.open)refresh();});
    return details;
  }
  function article(item, isPublic=true){
    const a=el('article',{class:'card ward-extra-card'});
    if(item.kind==='missionary'){
      a.classList.add('missionary-profile');
      a.append(el('header',{class:'missionary-profile-heading'},[
        el('h3',{},item.title),el('p',{class:'muted'},item.detail)
      ]));
      const portrait=item.photo?el('img',{class:'missionary-portrait',src:item.photo,alt:item.title,loading:'lazy'}):null;
      const passage=item.scripture_text||item.scripture_reference?el('figure',{class:'missionary-scripture'},[
        item.scripture_reference?el('figcaption',{},item.scripture_reference):null,
        item.scripture_text?el('blockquote',{},item.scripture_text):null
      ]):null;
      if(portrait||passage)a.append(el('div',{class:'missionary-plaque'+(portrait&&passage?' has-both':'')},[portrait,passage]));
      if(isPublic){
        const actions=el('div',{class:'missionary-email-actions'});
        if(item.email)actions.append(el('a',{class:'btn small secondary',href:'mailto:'+encodeURIComponent(item.email).replace('%40','@')},'Send an email'));
        actions.append(el('button',{class:'btn small secondary',type:'button',onclick:()=>requestWeeklyEmails(item)},'Request weekly emails'));
        a.append(el('div',{class:'missionary-email'},actions));
      }
      return a;
    }
    if(item.photo)a.append(el('img',{src:item.photo,alt:item.kind==='missionary'?item.title:'',loading:'lazy'}));
    a.append(el('h3',{},item.title));
    if(item.day)a.append(para(fmtDate(item.day)));
    if(item.detail)a.append(el('p',{class:'ward-extra-detail'},item.detail));
    if(item.email)a.append(el('a',{href:'mailto:'+encodeURIComponent(item.email).replace('%40','@')},item.email));
    return a;
  }
  async function publicPage(){
    const sign=document.querySelector('#ward-signups'),corner=document.querySelector('#missionary-corner');
    const info=document.querySelector('#ward-signup-request');
    const requestButton=document.querySelector('#ward-signup-request-toggle');
    requestButton.addEventListener('click',()=>{
      info.hidden=!info.hidden;
      requestButton.setAttribute('aria-expanded',String(!info.hidden));
    });
    info.append(editor('signup',{},null,()=>info.replaceChildren(para('Sent to leaders for approval.'))));
    let records;
    try { records=await rpc('ward_extra_list'); }
    catch(e){ sign.replaceChildren(para('Sign-ups could not load. Refresh to try again.'));corner.replaceChildren(para('Missionary Corner could not load.'));return; }
    const signups=records.filter(r=>r.kind==='signup');
    sign.replaceChildren(...signups.map(item=>{
      const a=article(item), left=Math.max(0,item.capacity-item.taken);
      a.append(para(left?left+' of '+item.capacity+' spots open':'Full'));
      if(left){
        const f=el('form',{'data-submit':'Reserve a spot',class:'ward-extra-form'});
        field(f,'name','Your name',{required:'',maxlength:100});
        field(f,'contact','Phone number or email',{required:'',maxlength:200});
        f.append(para('Only leaders can see your name and contact information. To cancel, contact a leader.'));
        capture(f,async d=>{
          await rpc('ward_extra_join',{p_id:item.id,p_name:d.get('name'),p_contact:d.get('contact')});
          f.replaceWith(el('p',{role:'status'},'You’re signed up.'));
          a.querySelector('summary').textContent='Reservation confirmed';
        });
        a.append(el('details',{},[el('summary',{},'Sign up'),f]));
      }
      return a;
    }));
    if(!signups.length)sign.append(para('No open sign-ups right now.'));
    corner.replaceChildren();
    for(const kind of ['missionary','moment']){
      corner.append(el('h3',{},kind==='moment'?'Missionary Moment':'Serving from our ward'));
      const set=records.filter(r=>r.kind===kind);
      corner.append(el('div',{class:'ward-extra-list'},set.length?set.map(item=>article(item)):[para(kind==='missionary'?'No missionaries listed yet.':'No moments shared yet.')]));
    }
  }
  function admin(pass,onEmailRemoved,onSignupChanged){
    const root=document.querySelector('#ward-extras-admin');let kind='signup';
    const box=root;
    async function load(next=kind){
      kind=next;box.replaceChildren(para('Loading…'));
      try{
        const items=await rpc('admin_ward_extra_list',{p_pass:pass(),p_kind:next});
        if(next!==kind)return;
        box.replaceChildren(el('details',{class:'card'},[el('summary',{},'Create '+(kind==='signup'?'a sign-up':kind==='missionary'?'a missionary profile':'a Missionary Moment')),editor(kind,{},pass,()=>load())]));
        items.forEach(item=>{
          const a=article(item,false),label=item.state==='pending'?'Awaiting approval':item.state==='closed'?'Unpublished':'Published';
          a.append(para(label));
          const edit=el('details',{},[el('summary',{},item.state==='live'?'Edit':'Review and publish'),editor(next,item,pass,()=>{
            if(next==='signup')onSignupChanged?.();
            load();
          })]);
          a.append(edit);
          const remove=async (id,reservation)=>{
            if(!confirm(reservation?'Remove this reservation?':'Unpublish this item?'))return;
            try{await rpc('admin_ward_extra_remove',{p_pass:pass(),p_id:id,p_reservation:reservation});if(next==='signup'&&!reservation)onSignupChanged?.();await load();}
            catch(e){a.append(para(e.message));}
          };
          if(item.state!=='closed')a.append(btn(item.state==='pending'?'Decline':'Unpublish',()=>remove(item.id,false)));
          if(next==='missionary')a.append(weeklyEmailList(item,pass,onEmailRemoved));
          if(next==='signup'){
            const list=el('details',{},el('summary',{},'Reservations ('+item.reservations.length+')'));
            for(const r of item.reservations)list.append(el('p',{},[r.name+' · '+r.contact+' ',btn('Remove',()=>remove(r.id,true))]));
            a.append(list);
          }
          box.append(a);
        });
      }catch(e){if(kind===next)box.replaceChildren(para(e.message),btn('Try again',()=>load()));}
    }
    return load;
  }
  window.NPWardExtras={admin};
  if(document.querySelector('#ward-signups'))publicPage();
})();
