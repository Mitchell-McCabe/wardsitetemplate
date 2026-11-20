export async function leaders(op,date,verified=[]) {
  if(location.origin!=='https://ward.example.invalid'||!/^\/admin(?:\.html)?\/?$/.test(location.pathname)||document.getElementById('app')?.hidden!==false||!window.NP?.rpc)
    throw Error('Open the unlocked Leaders page on the ward site.');
  const pass=localStorage.getItem('np_admin_token')||sessionStorage.getItem('np_admin_token');
  if(!pass)throw Error('Sign in to Leaders again.');
  const rpc=(fn,args={})=>window.NP.rpc(fn,{p_pass:pass,...args});
  if(op==='ready')return true;
  if(op==='roster'){
    const sheet=(await rpc('admin_sheets')).find(s=>s.key==='lcr_test_members'&&s.updated_by==='LCR Overview test extension');
    return sheet?.rows||[];
  }
  const slots={sunday_school:1,priesthood___relief_society:2};
  const rows=(await rpc('admin_attendance',{p_date:date})).filter(r=>!r.synced_to_lcr_at&&Object.hasOwn(slots,r.class)).map(r=>({
    id:r.attendance_id,member_id:r.member_id,name:r.name||r.display_name,lcrId:r.lcr_uuid||'',slot:slots[r.class]
  }));
  if(op==='pending')return rows;
  if(op!=='ack')throw Error('Unknown attendance action.');
  const ids=rows.filter(r=>verified.some(v=>r.id===v.id&&r.member_id===v.member_id&&r.slot===v.slot&&r.name===v.name)).map(r=>r.id);
  const marked=ids.length?await rpc('admin_mark_synced',{p_attendance_ids:ids}):0;
  document.getElementById('refresh')?.click();
  return marked;
}
