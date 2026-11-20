window.NPDeclarations = (function () {
  const statuses = [['confirmed','Confirmed'],['completed','Completed'],['scheduled','Scheduled'],['not_scheduled','Not scheduled'],['to_contact','To contact']];
  const zone = 'America/New_York';
  const day = value => new Date(value).toLocaleDateString('en-US',{timeZone:zone,weekday:'short',month:'short',day:'numeric'});
  const time = value => new Date(value).toLocaleTimeString('en-US',{timeZone:zone,hour:'numeric',minute:'2-digit'});
  const slotLabel = slot => day(slot.starts_at)+' · '+time(slot.starts_at)+'–'+time(slot.ends_at);
  function parseCsv(source) {
    source=String(source).replace(/^\uFEFF/,'');
    const first=source.split(/\r?\n/)[0]||'';
    const delimiter=[',','\t',';'].sort((a,b)=>first.split(b).length-first.split(a).length)[0];
    let rows=[],row=[],cell='',quoted=false;
    for(let i=0;i<source.length;i++) {
      const c=source[i];
      if(c==='"') { if(quoted && source[i+1]==='"'){cell+='"';i++;}else quoted=!quoted; }
      else if(c===delimiter && !quoted){row.push(cell.trim());cell='';}
      else if((c==='\n'||c==='\r') && !quoted){if(c==='\r'&&source[i+1]==='\n')i++;row.push(cell.trim());if(row.some(Boolean))rows.push(row);row=[];cell='';}
      else cell+=c;
    }
    if(quoted)throw Error('The CSV has an unclosed quoted field.');
    row.push(cell.trim());if(row.some(Boolean))rows.push(row);
    if(rows.length<2)throw Error('The file needs a header row and at least one member.');
    const headers=rows.shift();return {headers,rows};
  }
  function currentYear(){return Number(new Intl.DateTimeFormat('en-US',{timeZone:zone,year:'numeric'}).format(new Date()));}
  function mountHome(link) {
    let busy=false;
    async function refresh(){if(busy)return;busy=true;try{const data=await NP.rpc('declarations_public');link.hidden=!data?.enabled;}catch(e){link.hidden=true;}finally{busy=false;}}
    refresh();setInterval(refresh,30000);document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
  }
  return {statuses,zone,day,time,slotLabel,parseCsv,currentYear,mountHome};
})();
