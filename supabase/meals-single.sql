-- Single-companionship meals, leader-managed blocked dates, and private cancellation links.
alter table public.missionary_meals alter column gender drop not null;
alter table public.missionary_meals add column if not exists cancel_token_hash text;
create unique index if not exists missionary_meals_one_per_ward_day on public.missionary_meals(meal_date) where status='booked';
create table if not exists public.meal_blocked_dates (
 meal_date date primary key,
 note text not null default '' check (length(note)<=200),
 created_at timestamptz not null default now()
);
alter table public.meal_blocked_dates enable row level security;
revoke all on public.meal_blocked_dates from public,anon,authenticated;
-- Keep the existing companionship and type, with no custom name or area required.
do $$
declare k text; g text;
begin
 k := public._meals_companionships()->>0;
 k := coalesce(k,'missionaries');
 g := coalesce((select value from public.settings where key='meals_'||k||'_gender'),'M');
 insert into public.settings(key,value) values
 ('meals_companionships',jsonb_build_array(k)::text),
 ('meals_'||k||'_label',case when g='F' then 'Sisters' else 'Elders' end),
 ('meals_'||k||'_gender',g),('meals_'||k||'_on','true')
 on conflict(key) do update set value=excluded.value;
end $$;

create or replace function public.meals_public() returns jsonb
language sql stable security definer set search_path=public,extensions as $$
 select jsonb_build_object(
 'enabled',coalesce((select value from settings where key='meals_enabled'),'true')='true',
 'days_ahead',coalesce((select value from settings where key='meals_days_ahead'),'42')::int,
 'companionships',coalesce((select jsonb_build_array(jsonb_build_object('key',k,'label',case when (select value from settings where key='meals_'||k||'_gender')='F' then 'Sisters' else 'Elders' end,'sisters',(select value from settings where key='meals_'||k||'_gender')='F')) from (select _meals_companionships()->>0 as k) c where k is not null),'[]'::jsonb),
 'booked',(select coalesce(jsonb_agg(jsonb_build_object('date',m.meal_date,'who',regexp_replace(btrim(m.name),'^(\S+)\s+(\S).*$', '\1 \2.')) order by m.meal_date),'[]'::jsonb) from missionary_meals m where m.status='booked' and m.meal_date >= (now() at time zone 'America/New_York')::date),
 'blocked',(select coalesce(jsonb_agg(meal_date order by meal_date),'[]'::jsonb) from meal_blocked_dates where meal_date >= (now() at time zone 'America/New_York')::date)
 )
$$;

create or replace function public.meals_book(p_date date,p_name text,p_phone text,p_notes text default null,p_website text default '') returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare k text; n text; ph text; t text; v_id bigint; today date; ahead int;
begin
 if coalesce(p_website,'')<>'' then raise exception 'Unable to book this reservation'; end if;
 if coalesce((select value from settings where key='meals_enabled'),'true')<>'true' then raise exception 'Meal sign-ups are closed right now'; end if;
 k:=_meals_companionships()->>0;
 if k is null then raise exception 'Meal sign-ups are not set up yet'; end if;
 today:=(now() at time zone 'America/New_York')::date;
 ahead:=coalesce((select value from settings where key='meals_days_ahead'),'42')::int;
 if p_date is null or p_date<today or p_date>today+ahead then raise exception 'Choose an available date within the booking calendar'; end if;
 n:=regexp_replace(btrim(coalesce(p_name,'')),'\s+',' ','g'); ph:=btrim(coalesce(p_phone,''));
 if length(n)<2 or length(n)>80 then raise exception 'Please enter your name'; end if;
 if length(regexp_replace(ph,'\D','','g'))<10 or length(ph)>40 then raise exception 'Please enter a mobile number'; end if;
 if length(coalesce(p_notes,''))>600 then raise exception 'Please keep the note under 600 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended('ward-meal:'||p_date::text,0));
 if exists(select 1 from meal_blocked_dates where meal_date=p_date) then raise exception 'That date is unavailable. Please choose another day'; end if;
 if exists(select 1 from missionary_meals where meal_date=p_date and status='booked') then raise exception 'That date is already booked. Please choose another day'; end if;
 if (select count(*) from missionary_meals where created_at>now()-interval '1 hour')>=40 then raise exception 'Too many sign-ups right now. Please try again later'; end if;
 t:=encode(gen_random_bytes(32),'hex');
 insert into missionary_meals(companionship,meal_date,name,gender,phone,notes,cancel_token_hash)
 values(k,p_date,n,null,ph,nullif(btrim(coalesce(p_notes,'')),''),encode(digest(t,'sha256'),'hex')) returning id into v_id;
 return jsonb_build_object('id',v_id,'date',p_date,'cancel_token',t);
end $$;
-- Older clients use the same booking rules.
create or replace function public.meals_signup(p_companionship text,p_date date,p_name text,p_gender text,p_phone text,p_companion text default null,p_notes text default null,p_website text default '') returns jsonb
language sql security definer set search_path=public,extensions as $$
 select meals_book(p_date,p_name,p_phone,p_notes,p_website)
$$;

create or replace function public.meals_reservation(p_id bigint,p_token text) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare r missionary_meals;
begin
 select * into r from missionary_meals where id=p_id and cancel_token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex');
 if not found then raise exception 'This reservation link is invalid or no longer available'; end if;
 return jsonb_build_object('id',r.id,'date',r.meal_date,'status',r.status);
end $$;
create or replace function public.meals_cancel(p_id bigint,p_token text) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r missionary_meals;
begin
 select * into r from missionary_meals where id=p_id and cancel_token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex') for update;
 if not found then raise exception 'This reservation link is invalid or no longer available'; end if;
 if r.status='cancelled' then return; end if;
 if r.status<>'booked' or r.meal_date<(now() at time zone 'America/New_York')::date then raise exception 'This reservation can no longer be cancelled online. Contact a leader'; end if;
 update missionary_meals set status='cancelled',updated_at=now() where id=r.id;
end $$;

create or replace function public.admin_meal_blocked_dates(p_pass text) returns setof public.meal_blocked_dates
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 return query select * from meal_blocked_dates where meal_date >= (now() at time zone 'America/New_York')::date order by meal_date;
end $$;
create or replace function public.admin_meal_block_date(p_pass text,p_date date,p_blocked boolean,p_note text default '') returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 if p_date is null then raise exception 'Choose a date'; end if;
 if p_blocked and p_date<(now() at time zone 'America/New_York')::date then raise exception 'Choose today or a future date'; end if;
 if length(coalesce(p_note,''))>200 then raise exception 'Keep the note under 200 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended('ward-meal:'||p_date::text,0));
 if p_blocked then
  if exists(select 1 from missionary_meals where meal_date=p_date and status='booked') then raise exception 'That date already has a reservation. Cancel or move it before blocking the date'; end if;
  insert into meal_blocked_dates(meal_date,note) values(p_date,btrim(coalesce(p_note,''))) on conflict(meal_date) do update set note=excluded.note;
 else delete from meal_blocked_dates where meal_date=p_date;
 end if;
end $$;
create or replace function public.admin_meal_settings(p_pass text,p_gender text,p_phone text,p_days int) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare k text;
begin
 perform _check_admin(p_pass);
 if p_gender is null or p_gender not in ('M','F') then raise exception 'Choose Elders or Sisters'; end if;
 if p_days is null or p_days<7 or p_days>120 then raise exception 'Booking window must be 7–120 days'; end if;
 if length(coalesce(p_phone,''))>40 then raise exception 'Phone number is too long'; end if;
 k:=coalesce(_meals_companionships()->>0,'missionaries');
 insert into settings(key,value) values
 ('meals_companionships',jsonb_build_array(k)::text),('meals_'||k||'_gender',p_gender),
 ('meals_'||k||'_label',case when p_gender='F' then 'Sisters' else 'Elders' end),
 ('meals_'||k||'_phone',btrim(coalesce(p_phone,''))),('meals_'||k||'_on','true'),('meals_days_ahead',p_days::text)
 on conflict(key) do update set value=excluded.value;
end $$;
create or replace function public.admin_meal_status(p_pass text,p_id bigint,p_status text) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare d date;
begin
 perform _check_admin(p_pass);
 if p_status is null or p_status not in ('booked','done','cancelled') then raise exception 'Bad status'; end if;
 select meal_date into d from missionary_meals where id=p_id;
 if not found then raise exception 'Reservation not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended('ward-meal:'||d::text,0));
 if p_status='booked' and exists(select 1 from meal_blocked_dates where meal_date=d) then raise exception 'Reopen that date before restoring the reservation'; end if;
 if p_status='booked' and exists(select 1 from missionary_meals where meal_date=d and status='booked' and id<>p_id) then raise exception 'That date is already booked'; end if;
 update missionary_meals set status=p_status,updated_at=now() where id=p_id;
end $$;
-- Do not expose cancellation hashes even to the leader page.
drop function public.admin_meals(text,boolean);
create function public.admin_meals(p_pass text,p_include_past boolean default false)
returns table(id bigint,companionship text,meal_date date,name text,gender text,phone text,companion text,notes text,status text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 return query select m.id,m.companionship,m.meal_date,m.name,m.gender,m.phone,m.companion,m.notes,m.status,m.created_at,m.updated_at from missionary_meals m
 where p_include_past or m.meal_date >= (now() at time zone 'America/New_York')::date-7 order by m.meal_date;
end $$;
revoke all on function public.meals_book(date,text,text,text,text),public.meals_reservation(bigint,text),public.meals_cancel(bigint,text),public.admin_meal_blocked_dates(text),public.admin_meal_block_date(text,date,boolean,text),public.admin_meal_settings(text,text,text,int),public.admin_meals(text,boolean) from public,anon,authenticated;
grant execute on function public.meals_book(date,text,text,text,text),public.meals_reservation(bigint,text),public.meals_cancel(bigint,text),public.admin_meal_blocked_dates(text),public.admin_meal_block_date(text,date,boolean,text),public.admin_meal_settings(text,text,text,int),public.admin_meals(text,boolean) to anon;
notify pgrst,'reload schema';
