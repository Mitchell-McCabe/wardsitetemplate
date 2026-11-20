-- Annual tithing-declaration scheduling. No contribution amounts or declaration answers are stored.
create table if not exists public.declaration_seasons(year int primary key check(year between 2020 and 2100),enabled boolean not null default false,slot_minutes int not null default 15 check(slot_minutes between 5 and 120),time_zone text not null default 'America/New_York');
create unique index if not exists declaration_one_enabled_year on public.declaration_seasons(enabled) where enabled;
create table if not exists public.declaration_ranges(id uuid primary key default gen_random_uuid(),year int not null references public.declaration_seasons(year),meeting_date date not null,start_time time not null,end_time time not null,slot_minutes int not null,active boolean not null default true,check(end_time>start_time));
create table if not exists public.declaration_slots(id uuid primary key default gen_random_uuid(),year int not null references public.declaration_seasons(year),range_id uuid not null references public.declaration_ranges(id),starts_at timestamptz not null,ends_at timestamptz not null,active boolean not null default true,check(ends_at>starts_at));
create unique index if not exists declaration_slot_start on public.declaration_slots(year,starts_at) where active;
create table if not exists public.declaration_bookings(id uuid primary key default gen_random_uuid(),year int not null references public.declaration_seasons(year),slot_id uuid not null references public.declaration_slots(id),member_ids uuid[] not null,names text[] not null,phone text not null default '',email text not null default '',note text not null default '',status text not null default 'booked' check(status in ('booked','cancelled')),created_at timestamptz not null default now());
create unique index if not exists declaration_slot_booking on public.declaration_bookings(slot_id) where status='booked';
create table if not exists public.declaration_members(id uuid primary key default gen_random_uuid(),year int not null references public.declaration_seasons(year),source_key text not null,full_name text not null,phone text not null default '',email text not null default '',household text not null default '',status text not null default 'not_scheduled' check(status in ('confirmed','completed','scheduled','not_scheduled','to_contact')),manual_override boolean not null default false,booking_id uuid references public.declaration_bookings(id),updated_at timestamptz not null default now(),unique(year,source_key));
create index if not exists declaration_members_year_status on public.declaration_members(year,status);
create table if not exists public.declaration_contact_requests(id uuid primary key default gen_random_uuid(),year int not null references public.declaration_seasons(year),names text[] not null,member_ids uuid[] not null default '{}',phone text not null,email text not null default '',note text not null default '',resolved boolean not null default false,created_at timestamptz not null default now());
alter table public.declaration_seasons enable row level security;
alter table public.declaration_ranges enable row level security;
alter table public.declaration_slots enable row level security;
alter table public.declaration_bookings enable row level security;
alter table public.declaration_members enable row level security;
alter table public.declaration_contact_requests enable row level security;
revoke all on public.declaration_seasons,public.declaration_ranges,public.declaration_slots,public.declaration_bookings,public.declaration_members,public.declaration_contact_requests from public,anon,authenticated;

create or replace function public._decl_name(p_name text) returns text
language sql immutable set search_path=pg_catalog as $$
 select lower(regexp_replace(regexp_replace(btrim(case when strpos(coalesce(p_name,''),',')>0 then split_part(p_name,',',2)||' '||split_part(p_name,',',1) else coalesce(p_name,'') end),'[^[:alnum:] ]','','g'),'\s+',' ','g'))
$$;
create index if not exists declaration_member_name on public.declaration_members(year,public._decl_name(full_name));
create or replace function public._decl_refresh(p_year int) returns void
language sql security definer set search_path=public,extensions as $$
 update declaration_members m set status='completed',updated_at=now() from declaration_bookings b join declaration_slots s on s.id=b.slot_id
 where m.year=p_year and m.booking_id=b.id and b.status='booked' and s.ends_at<=now() and m.status='scheduled' and not m.manual_override
$$;
create or replace function public.admin_declarations_settings(p_pass text,p_year int,p_enabled boolean,p_minutes int) returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 if p_year is null or p_year<2020 or p_year>2100 or p_minutes is null or p_minutes<5 or p_minutes>120 then raise exception 'Choose a year and an interview length from 5 to 120 minutes'; end if;
 perform pg_advisory_xact_lock(742901);
 if p_enabled then update declaration_seasons set enabled=false where year<>p_year and enabled; end if;
 insert into declaration_seasons(year,enabled,slot_minutes) values(p_year,coalesce(p_enabled,false),p_minutes) on conflict(year) do update set enabled=excluded.enabled,slot_minutes=excluded.slot_minutes;
end $$;
create or replace function public.admin_declarations_import(p_pass text,p_year int,p_records jsonb) returns int
language plpgsql security definer set search_path=public,extensions as $$
declare r jsonb; v_name text; v_key text; keys text[]:='{}'; n int:=0;
begin
 perform _check_admin(p_pass);
 if p_year is null or p_year<2020 or p_year>2100 then raise exception 'Choose a year'; end if;
 if p_records is null or jsonb_typeof(p_records)<>'array' or jsonb_array_length(p_records)<1 or jsonb_array_length(p_records)>3000 then raise exception 'Import between 1 and 3000 members at a time'; end if;
 perform pg_advisory_xact_lock(742901,p_year);
 insert into declaration_seasons(year) values(p_year) on conflict do nothing;
 for r in select value from jsonb_array_elements(p_records) loop
  v_name:=btrim(coalesce(r->>'full_name',''));
  if length(v_name)<2 or length(v_name)>120 then raise exception 'Every row needs a member name of 2 to 120 characters'; end if;
  if length(coalesce(r->>'phone',''))>40 or length(coalesce(r->>'email',''))>200 or length(coalesce(r->>'household',''))>120 or length(coalesce(r->>'source_id',''))>120 then raise exception 'A contact field is too long'; end if;
  v_key:=case when btrim(coalesce(r->>'source_id',''))<>'' then 'id:'||btrim(r->>'source_id') else 'name:'||_decl_name(v_name) end;
  if v_key=any(keys) then raise exception 'Duplicate names need distinct member IDs. Check the member ID mapping before importing'; end if;
  keys:=array_append(keys,v_key);
  insert into declaration_members(year,source_key,full_name,phone,email,household) values(p_year,v_key,v_name,btrim(coalesce(r->>'phone','')),btrim(coalesce(r->>'email','')),btrim(coalesce(r->>'household','')))
  on conflict(year,source_key) do update set full_name=excluded.full_name,phone=excluded.phone,email=excluded.email,household=excluded.household,updated_at=now();
  n:=n+1;
 end loop;
 return n;
end $$;
create or replace function public.admin_declarations_add_range(p_pass text,p_year int,p_date date,p_start time,p_end time) returns int
language plpgsql security definer set search_path=public,extensions as $$
declare season declaration_seasons; begins timestamptz; finishes timestamptz; cursor_time timestamptz; range_id uuid; n int:=0;
begin
 perform _check_admin(p_pass); perform pg_advisory_xact_lock(742901,p_year);
 select * into season from declaration_seasons where year=p_year;
 if not found then raise exception 'Save the year settings first'; end if;
 if p_date is null or extract(year from p_date)::int<>p_year or p_start is null or p_end is null or p_end<=p_start then raise exception 'Choose a date in the selected year and an end time after the start time'; end if;
 begins:=(p_date+p_start) at time zone season.time_zone; finishes:=(p_date+p_end) at time zone season.time_zone;
 if begins<=now() then raise exception 'Availability must start in the future'; end if;
 if finishes-begins<make_interval(mins=>season.slot_minutes) then raise exception 'The time range is shorter than one interview'; end if;
 if exists(select 1 from declaration_slots s where s.year=p_year and s.active and s.starts_at<finishes and s.ends_at>begins) then raise exception 'That time range overlaps existing slots'; end if;
 if (select count(*) from declaration_slots where year=p_year and active)>5000 then raise exception 'There are too many slots for this year'; end if;
 insert into declaration_ranges(year,meeting_date,start_time,end_time,slot_minutes) values(p_year,p_date,p_start,p_end,season.slot_minutes) returning id into range_id;
 cursor_time:=begins;
 while cursor_time+make_interval(mins=>season.slot_minutes)<=finishes loop
  insert into declaration_slots(year,range_id,starts_at,ends_at) values(p_year,range_id,cursor_time,cursor_time+make_interval(mins=>season.slot_minutes));
  cursor_time:=cursor_time+make_interval(mins=>season.slot_minutes); n:=n+1;
 end loop;
 return n;
end $$;
create or replace function public.admin_declarations_remove_range(p_pass text,p_id uuid) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare y int;
begin
 perform _check_admin(p_pass); select year into y from declaration_ranges where id=p_id;
 if y is null then raise exception 'Range not found'; end if;
 perform pg_advisory_xact_lock(742901,y);
 if exists(select 1 from declaration_slots s join declaration_bookings b on b.slot_id=s.id and b.status='booked' where s.range_id=p_id) then raise exception 'Cancel or move the appointments in this range first'; end if;
 update declaration_slots set active=false where range_id=p_id;
 update declaration_ranges set active=false where id=p_id;
end $$;
create or replace function public._decl_resolve(p_year int,p_names text[],p_phone text,p_email text,p_strict boolean) returns uuid[]
language plpgsql security definer set search_path=public,extensions as $$
declare n text; matches uuid[]; chosen uuid; result uuid[]:='{}';
begin
 if coalesce(cardinality(p_names),0)<1 or cardinality(p_names)>20 then raise exception 'Enter between 1 and 20 member names'; end if;
 foreach n in array p_names loop
  if length(btrim(coalesce(n,'')))<2 or length(n)>120 then raise exception 'Enter each member’s full name'; end if;
  select array_agg(m.id) into matches from declaration_members m where m.year=p_year and _decl_name(m.full_name)=_decl_name(n);
  if coalesce(cardinality(matches),0)>1 then
   select array_agg(m.id) into matches from declaration_members m where m.id=any(matches) and ((length(_meal_phone(p_phone))>=10 and _meal_phone(m.phone)=_meal_phone(p_phone)) or (coalesce(p_email,'')<>'' and lower(btrim(m.email))=lower(btrim(p_email))));
  end if;
  if coalesce(cardinality(matches),0)=1 then
   chosen:=matches[1]; if not chosen=any(result) then result:=array_append(result,chosen); end if;
  elsif p_strict then raise exception 'A member name could not be matched uniquely to this year’s list. Check the full names or use the request-contact option';
  end if;
 end loop;
 return result;
end $$;
create or replace function public._decl_book(p_year int,p_slot uuid,p_members uuid[],p_phone text,p_email text,p_note text,p_public boolean) returns uuid
language plpgsql security definer set search_path=public,extensions as $$
declare slot declaration_slots; ids uuid[]; names text[]; booking uuid; v_phone text;
begin
 perform pg_advisory_xact_lock(742901,p_year);
 if p_public and not exists(select 1 from declaration_seasons where year=p_year and enabled) then raise exception 'Declaration sign-ups are closed'; end if;
 if coalesce(cardinality(p_members),0)<1 or cardinality(p_members)>20 then raise exception 'Choose between 1 and 20 members'; end if;
 select array_agg(distinct value) into ids from unnest(p_members) as value;
 if (select count(*) from declaration_members where year=p_year and id=any(ids))<>cardinality(ids) then raise exception 'A member is not on this year’s list'; end if;
 if btrim(coalesce(p_phone,''))<>'' and (length(_meal_phone(p_phone))<10 or length(_meal_phone(p_phone))>15) then raise exception 'Enter a valid phone number'; end if;
 if length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>200 or length(coalesce(p_note,''))>1000 then raise exception 'A contact field or note is too long'; end if;
 select * into slot from declaration_slots where id=p_slot and year=p_year and active for update;
 if not found or slot.starts_at<=now() then raise exception 'That slot is no longer available'; end if;
 if exists(select 1 from declaration_bookings where slot_id=p_slot and status='booked') then raise exception 'That slot has just been taken. Choose another time'; end if;
 if exists(select 1 from declaration_members m join declaration_bookings b on b.id=m.booking_id and b.status='booked' where m.id=any(ids)) then raise exception 'A selected member already has a declaration appointment. Ask the executive secretary to change it'; end if;
 select array_agg(m.full_name order by m.full_name) into names from declaration_members m where m.id=any(ids);
 v_phone:=btrim(coalesce(p_phone,''));
 if v_phone='' then select btrim(m.phone) into v_phone from declaration_members m where m.id=any(ids) and btrim(m.phone)<>'' order by array_position(p_members,m.id) limit 1; end if;
 insert into declaration_bookings(year,slot_id,member_ids,names,phone,email,note) values(p_year,p_slot,ids,names,coalesce(v_phone,''),btrim(coalesce(p_email,'')),btrim(coalesce(p_note,''))) returning id into booking;
 update declaration_members set booking_id=booking,status=case when manual_override then status else 'scheduled' end,updated_at=now() where id=any(ids);
 update declaration_contact_requests set resolved=true where year=p_year and not resolved and cardinality(member_ids)>0 and member_ids<@ids;
 return booking;
end $$;
create or replace function public.declarations_public() returns jsonb
language sql stable security definer set search_path=public,extensions as $$
 select jsonb_build_object('year',s.year,'enabled',true,'slot_minutes',s.slot_minutes,'time_zone',s.time_zone,'slots',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'starts_at',t.starts_at,'ends_at',t.ends_at) order by t.starts_at),'[]'::jsonb) from declaration_slots t where t.year=s.year and t.active and t.starts_at>now() and not exists(select 1 from declaration_bookings b where b.slot_id=t.id and b.status='booked')))
 from declaration_seasons s where s.enabled
$$;
create or replace function public.declarations_book(p_slot uuid,p_names text[],p_phone text,p_email text default '',p_note text default '',p_website text default '') returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare y int; ids uuid[]; slot declaration_slots; booking uuid;
begin
 if coalesce(p_website,'')<>'' then raise exception 'Unable to complete signup'; end if;
 select year into y from declaration_seasons where enabled;
 if y is null then raise exception 'Declaration sign-ups are closed'; end if;
 if (select count(*) from declaration_bookings where year=y and created_at>now()-interval '1 hour')>=100 then raise exception 'Too many sign-ups right now. Try again later'; end if;
 ids:=_decl_resolve(y,p_names,p_phone,p_email,true);
 booking:=_decl_book(y,p_slot,ids,p_phone,p_email,p_note,true);
 select * into slot from declaration_slots where id=p_slot;
 return jsonb_build_object('starts_at',slot.starts_at,'ends_at',slot.ends_at);
end $$;
create or replace function public.declarations_request_contact(p_names text[],p_phone text,p_email text default '',p_note text default '',p_website text default '') returns void
language plpgsql security definer set search_path=public,extensions as $$
declare y int; ids uuid[]; v_phone text;
begin
 if coalesce(p_website,'')<>'' then raise exception 'Unable to submit request'; end if;
 select year into y from declaration_seasons where enabled;
 if y is null then raise exception 'Declaration sign-ups are closed'; end if;
 if (btrim(coalesce(p_phone,''))<>'' and (length(_meal_phone(p_phone))<10 or length(_meal_phone(p_phone))>15)) or length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>200 or length(coalesce(p_note,''))>1000 then raise exception 'Enter a valid phone number and keep notes under 1000 characters'; end if;
 perform pg_advisory_xact_lock(742901,y);
 if (select count(*) from declaration_contact_requests where year=y and created_at>now()-interval '1 hour')>=100 then raise exception 'Too many requests right now. Try again later'; end if;
 ids:=_decl_resolve(y,p_names,p_phone,p_email,false);
 v_phone:=btrim(coalesce(p_phone,''));
 if v_phone='' then select btrim(m.phone) into v_phone from declaration_members m where m.id=any(ids) and btrim(m.phone)<>'' order by array_position(ids,m.id) limit 1; end if;
 v_phone:=coalesce(v_phone,'');
 if exists(select 1 from declaration_contact_requests r where r.year=y and not r.resolved and _meal_phone(r.phone)=_meal_phone(v_phone) and r.names=p_names) then return; end if;
 insert into declaration_contact_requests(year,names,member_ids,phone,email,note) values(y,p_names,ids,v_phone,btrim(coalesce(p_email,'')),btrim(coalesce(p_note,'')));
 update declaration_members set status='to_contact',updated_at=now() where id=any(ids) and not manual_override;
end $$;
create or replace function public.admin_declarations_state(p_pass text,p_year int) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass); perform _decl_refresh(p_year);
 return jsonb_build_object(
 'season',coalesce((select to_jsonb(s) from declaration_seasons s where year=p_year),jsonb_build_object('year',p_year,'enabled',false,'slot_minutes',15,'time_zone','America/New_York')),
 'members',(select coalesce(jsonb_agg(to_jsonb(m)||jsonb_build_object('starts_at',s.starts_at,'ends_at',s.ends_at,'contact_phone',coalesce(nullif(b.phone,''),m.phone),'contact_email',coalesce(nullif(b.email,''),m.email)) order by case m.status when 'confirmed' then 1 when 'completed' then 2 when 'scheduled' then 3 when 'not_scheduled' then 4 else 5 end,m.full_name),'[]'::jsonb) from declaration_members m left join declaration_bookings b on b.id=m.booking_id and b.status='booked' left join declaration_slots s on s.id=b.slot_id where m.year=p_year),
 'ranges',(select coalesce(jsonb_agg(to_jsonb(r) order by r.meeting_date,r.start_time),'[]'::jsonb) from declaration_ranges r where r.year=p_year and r.active),
 'slots',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'starts_at',s.starts_at,'ends_at',s.ends_at,'booking',to_jsonb(b)) order by s.starts_at),'[]'::jsonb) from declaration_slots s left join declaration_bookings b on b.slot_id=s.id and b.status='booked' where s.year=p_year and s.active),
 'requests',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from declaration_contact_requests r where r.year=p_year and not r.resolved));
end $$;
create or replace function public.admin_declarations_status(p_pass text,p_id uuid,p_status text,p_manual boolean default true) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare m declaration_members; automatic_status text;
begin
 perform _check_admin(p_pass);
 if p_status is null or p_status not in ('confirmed','completed','scheduled','not_scheduled','to_contact') then raise exception 'Choose a valid status'; end if;
 select * into m from declaration_members where id=p_id;
 if not found then raise exception 'Member not found'; end if;
 perform pg_advisory_xact_lock(742901,m.year);
 if p_manual then automatic_status:=p_status;
 elsif exists(select 1 from declaration_bookings b join declaration_slots s on s.id=b.slot_id where b.id=m.booking_id and b.status='booked') then
  select case when s.ends_at<=now() then 'completed' else 'scheduled' end into automatic_status from declaration_bookings b join declaration_slots s on s.id=b.slot_id where b.id=m.booking_id;
 elsif exists(select 1 from declaration_contact_requests r where not r.resolved and m.id=any(r.member_ids)) then automatic_status:='to_contact';
 else automatic_status:='not_scheduled'; end if;
 update declaration_members set status=automatic_status,manual_override=coalesce(p_manual,true),updated_at=now() where id=p_id;
end $$;
create or replace function public.admin_declarations_book(p_pass text,p_year int,p_slot uuid,p_members uuid[],p_phone text default '',p_email text default '',p_note text default '',p_request uuid default null) returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 if p_request is not null and not exists(select 1 from declaration_contact_requests where id=p_request and year=p_year) then raise exception 'Contact request not found'; end if;
 perform _decl_book(p_year,p_slot,p_members,p_phone,p_email,p_note,false);
 if p_request is not null then update declaration_contact_requests set resolved=true,member_ids=p_members where id=p_request; end if;
end $$;
create or replace function public.admin_declarations_cancel(p_pass text,p_booking uuid) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare b declaration_bookings;
begin
 perform _check_admin(p_pass); select * into b from declaration_bookings where id=p_booking;
 if not found then raise exception 'Appointment not found'; end if;
 perform pg_advisory_xact_lock(742901,b.year);
 update declaration_bookings set status='cancelled' where id=p_booking;
 update declaration_members m set booking_id=null,status=case when manual_override then status when exists(select 1 from declaration_contact_requests r where not r.resolved and m.id=any(r.member_ids)) then 'to_contact' else 'not_scheduled' end,updated_at=now() where m.booking_id=p_booking;
end $$;
create or replace function public.admin_declarations_resolve_request(p_pass text,p_id uuid) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r declaration_contact_requests;
begin
 perform _check_admin(p_pass); select * into r from declaration_contact_requests where id=p_id;
 if not found then raise exception 'Request not found'; end if;
 perform pg_advisory_xact_lock(742901,r.year);
 update declaration_contact_requests set resolved=true where id=p_id;
 update declaration_members m set status=case when exists(select 1 from declaration_bookings b where b.id=m.booking_id and b.status='booked') then 'scheduled' else 'not_scheduled' end,updated_at=now() where m.id=any(r.member_ids) and m.status='to_contact' and not m.manual_override and not exists(select 1 from declaration_contact_requests other where not other.resolved and m.id=any(other.member_ids));
 perform _decl_refresh(r.year);
end $$;
-- Only the declared public and leader RPCs are callable by the browser. Helpers stay private.
do $permissions$
declare f record;
begin
 for f in select p.oid::regprocedure as signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and (p.proname like 'admin_declarations_%' or p.proname like 'declarations_%' or p.proname like '_decl_%') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if left(f.proname,1)<>'_' then execute format('grant execute on function %s to anon',f.signature); end if;
 end loop;
end $permissions$;
notify pgrst,'reload schema';
