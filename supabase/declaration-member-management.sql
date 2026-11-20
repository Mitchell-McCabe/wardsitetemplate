-- Leader-only manual roster maintenance; scoped to one declaration year.
create or replace function public.admin_declarations_add_member(p_pass text,p_year int,p_name text,p_phone text default '',p_email text default '',p_household text default '',p_source_id text default '') returns uuid
language plpgsql security definer set search_path=public,extensions as $$
declare v_key text; v_id uuid;
begin
 perform _check_admin(p_pass);
 if p_year is null or p_year<2020 or p_year>2100 then raise exception 'Choose a year'; end if;
 if length(btrim(coalesce(p_name,'')))<2 or length(btrim(p_name))>120 then raise exception 'Enter a member name of 2 to 120 characters'; end if;
 if length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>200 or length(coalesce(p_household,''))>120 or length(coalesce(p_source_id,''))>120 then raise exception 'A contact field is too long'; end if;
 perform pg_advisory_xact_lock(742901,p_year);
 insert into declaration_seasons(year) values(p_year) on conflict do nothing;
 v_key:=case when btrim(coalesce(p_source_id,''))<>'' then 'id:'||btrim(p_source_id) else 'name:'||_decl_name(p_name) end;
 if exists(select 1 from declaration_members where year=p_year and (source_key=v_key or (btrim(coalesce(p_source_id,''))='' and _decl_name(full_name)=_decl_name(p_name)))) then raise exception 'This member is already on this year’s list. For different people with the same name, enter a distinct member ID'; end if;
 insert into declaration_members(year,source_key,full_name,phone,email,household) values(p_year,v_key,btrim(p_name),btrim(coalesce(p_phone,'')),btrim(coalesce(p_email,'')),btrim(coalesce(p_household,''))) returning id into v_id;
 return v_id;
end $$;
create or replace function public.admin_declarations_remove_member(p_pass text,p_id uuid) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare v_member declaration_members;
begin
 perform _check_admin(p_pass);
 select * into v_member from declaration_members where id=p_id;
 if not found then raise exception 'Member not found'; end if;
 perform pg_advisory_xact_lock(742901,v_member.year);
 -- A shared appointment stays booked for the remaining people. A sole appointment reopens.
 update declaration_bookings b set member_ids=array_remove(b.member_ids,p_id),
 names=coalesce((select array_agg(m.full_name order by m.full_name) from declaration_members m where m.id=any(b.member_ids) and m.id<>p_id),'{}'::text[]),
 status=case when cardinality(array_remove(b.member_ids,p_id))=0 then 'cancelled' else b.status end
 where p_id=any(b.member_ids);
 update declaration_contact_requests r set member_ids=array_remove(r.member_ids,p_id),
 names=coalesce((select array_agg(n) from unnest(r.names) n where _decl_name(n)<>_decl_name(v_member.full_name)),'{}'::text[]),
 resolved=case when not exists(select 1 from unnest(r.names) n where _decl_name(n)<>_decl_name(v_member.full_name)) and cardinality(array_remove(r.member_ids,p_id))=0 then true else r.resolved end
 where p_id=any(r.member_ids);
 delete from declaration_members where id=p_id;
end $$;
revoke all on function public.admin_declarations_add_member(text,int,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.admin_declarations_remove_member(text,uuid) from public,anon,authenticated;
grant execute on function public.admin_declarations_add_member(text,int,text,text,text,text,text) to anon;
grant execute on function public.admin_declarations_remove_member(text,uuid) to anon;
notify pgrst,'reload schema';
