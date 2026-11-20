-- Private backing rows let Leaders record attendance for imported roster members.
alter table public.members add column if not exists leader_import_key uuid;
create unique index if not exists members_leader_import_key on public.members(leader_import_key);

CREATE OR REPLACE FUNCTION public.admin_members(p_pass text)
 RETURNS SETOF members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _check_admin(p_pass);
  return query select * from members where leader_import_key is null order by active desc, lower(name);
end $function$;

CREATE OR REPLACE FUNCTION public.admin_upsert_members(p_pass text, p_members jsonb, p_deactivate_missing boolean DEFAULT true)
 RETURNS TABLE(inserted integer, updated integer, deactivated integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_ins int := 0; v_upd int := 0; v_deact int := 0; r record;
begin
  perform _check_admin(p_pass);
  create temp table _incoming on commit drop as
    select (x->>'lcr_uuid')::uuid as lcr_uuid,
           coalesce(x->'lcr_classes', '[]'::jsonb) as lcr_classes,
           x->>'name' as name,
           coalesce(x->>'display_name', x->>'name') as display_name,
           x->>'sex' as sex,
           x->>'org' as org,
           (x->>'age')::int as age
    from jsonb_array_elements(p_members) x;

  for r in select * from _incoming loop
    update members m set
      lcr_classes = case when jsonb_array_length(r.lcr_classes) > 0 then r.lcr_classes else m.lcr_classes end,
      name = r.name, display_name = r.display_name,
      sex = coalesce(r.sex, m.sex), org = coalesce(r.org, m.org), age = coalesce(r.age, m.age),
      active = true, updated_at = now()
    where m.leader_import_key is null and ((r.lcr_uuid is not null and m.lcr_uuid = r.lcr_uuid)
       or (r.lcr_uuid is null and m.name = r.name));
    if found then
      v_upd := v_upd + 1;
    else
      insert into members (lcr_uuid, lcr_classes, name, display_name, sex, org, age)
      values (r.lcr_uuid, r.lcr_classes, r.name, r.display_name, r.sex, r.org, r.age);
      v_ins := v_ins + 1;
    end if;
  end loop;

  if p_deactivate_missing then
    update members m set active = false, updated_at = now()
    where m.active and m.leader_import_key is null
      and not exists (
        select 1 from _incoming i
        where (i.lcr_uuid is not null and i.lcr_uuid = m.lcr_uuid)
           or (i.lcr_uuid is null and i.name = m.name));
    get diagnostics v_deact = row_count;
  end if;

  return query select v_ins, v_upd, v_deact;
end $function$;

CREATE OR REPLACE FUNCTION public.check_in(p_date date, p_class text, p_member_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_count int;
begin
  if not _valid_class(p_class) then raise exception 'bad class'; end if;
  if not _window_open(p_class) then raise exception 'Check-in is closed right now' using errcode = 'P0001'; end if;
  if p_date > (now() at time zone 'America/New_York')::date + 1
     or p_date < (now() at time zone 'America/New_York')::date - 8 then
    raise exception 'date out of range';
  end if;
  insert into attendance (meeting_date, class, member_id)
  select p_date, p_class, m.id
  from members m
  where m.id = any(p_member_ids) and m.active and m.leader_import_key is null
  on conflict do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $function$;

CREATE OR REPLACE FUNCTION public.check_out(p_date date, p_class text, p_member_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_count int;
begin
  delete from attendance
  where meeting_date = p_date and class = p_class and member_id = p_member_id
    and exists(select 1 from members m where m.id = p_member_id and m.leader_import_key is null)
    and created_at > now() - interval '3 hours';   -- only recent mistakes
  get diagnostics v_count = row_count;
  return v_count;
end $function$;

CREATE OR REPLACE FUNCTION public.checked_in(p_date date, p_class text)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select a.member_id from attendance a join members m on m.id = a.member_id
  where a.meeting_date = p_date and a.class = p_class and m.leader_import_key is null
$function$;

CREATE OR REPLACE FUNCTION public.roll_members()
 RETURNS TABLE(id uuid, display_name text, org text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select id, display_name, org
  from members
  where active and leader_import_key is null
  order by lower(name)
$function$;

-- Look up the roster identity on the server; never accept a name from the attendance form.
create or replace function public._leader_imported_member(p_id uuid)
returns table(name text, profile_uuid uuid)
language sql stable security definer set search_path='' as $$
  select btrim(r.item->>0),
    substring(r.item->>(case s.key when 'lcr_test_members' then 6 else 2 end)
      from '^https://lcr\.churchofjesuschrist\.org/(?:mlt/)?records/member-profile/([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})(?:[/?#]|$)')::uuid
  from public.sheets s cross join lateral jsonb_array_elements(s.rows) r(item)
  where s.updated_by='LCR Overview test extension' and s.key in ('lcr_test_members','lcr_without_calling')
    and lower(r.item->>(case s.key when 'lcr_test_members' then 3 else 1 end))=p_id::text
    and btrim(r.item->>0)<>''
  order by (s.key='lcr_test_members') desc limit 1
$$;
revoke all on function public._leader_imported_member(uuid) from public,anon,authenticated;

create or replace function public.admin_add_imported_attendance(p_pass text,p_date date,p_class text,p_roster_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare person record; target uuid; first_names text; last_name text;
begin
  perform public._check_admin(p_pass);
  if p_date is null or p_class is null or not public._valid_class(p_class) then raise exception 'Select a date and a class'; end if;
  select * into person from public._leader_imported_member(p_roster_id);
  if not found then raise exception 'This member is no longer on the imported roster. Refresh the page.'; end if;
  select id into target from public.members where leader_import_key=p_roster_id;
  if target is null and person.profile_uuid is not null then
    select id into target from public.members where lcr_uuid=person.profile_uuid and leader_import_key is null and active;
  end if;
  if target is null then
    last_name:=split_part(person.name,',',1);
    first_names:=btrim(substr(person.name,length(last_name)+2));
    insert into public.members(name,display_name,leader_import_key)
      values(person.name,case when first_names<>'' then first_names||' '||last_name else person.name end,p_roster_id)
    on conflict (leader_import_key) do update set name=excluded.name,display_name=excluded.display_name
    returning id into target;
  end if;
  insert into public.attendance(meeting_date,class,member_id) values(p_date,p_class,target) on conflict do nothing;
end $$;

create table if not exists public.leader_current_callings (
  roster_id uuid not null,
  imported boolean not null,
  callings text[] not null,
  primary key(roster_id,imported)
);
alter table public.leader_current_callings enable row level security;
revoke all on public.leader_current_callings from public,anon,authenticated;

create or replace function public.admin_current_callings(p_pass text)
returns table(roster_id uuid,imported boolean,callings text[])
language plpgsql security definer set search_path='' as $$
begin
  perform public._check_admin(p_pass);
  return query select c.roster_id,c.imported,c.callings from public.leader_current_callings c;
end $$;

create or replace function public.admin_save_current_callings(p_pass text,p_roster_id uuid,p_imported boolean,p_callings text[])
returns void language plpgsql security definer set search_path='' as $$
declare clean text[];
begin
  perform public._check_admin(p_pass);
  if p_imported is null or p_roster_id is null or
     (p_imported and not exists(select 1 from public._leader_imported_member(p_roster_id))) or
     (not p_imported and not exists(select 1 from public.members where id=p_roster_id and leader_import_key is null)) then
    raise exception 'This member is no longer on the roster';
  end if;
  select coalesce(array_agg(distinct btrim(n) order by btrim(n)),'{}') into clean
    from unnest(coalesce(p_callings,'{}')) n where btrim(n)<>'';
  if cardinality(clean)>20 or exists(select 1 from unnest(clean) n where length(n)>100)
    then raise exception 'Enter at most 20 callings, each 100 characters or fewer'; end if;
  if cardinality(clean)=0 then
    delete from public.leader_current_callings where roster_id=p_roster_id and imported=p_imported;
  else
    insert into public.leader_current_callings values(p_roster_id,p_imported,clean)
      on conflict(roster_id,imported) do update set callings=excluded.callings;
  end if;
end $$;
revoke all on function public.admin_add_imported_attendance(text,date,text,uuid), public.admin_current_callings(text), public.admin_save_current_callings(text,uuid,boolean,text[]) from public,anon,authenticated;
grant execute on function public.admin_add_imported_attendance(text,date,text,uuid), public.admin_current_callings(text), public.admin_save_current_callings(text,uuid,boolean,text[]) to anon;
notify pgrst,'reload schema';
