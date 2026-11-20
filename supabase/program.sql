-- Sacrament meeting programs: dated content with a server-enforced visibility window.
create table if not exists public.sacrament_programs (
 meeting_date date primary key,
 start_time time not null,
 end_time time not null check(end_time>start_time),
 published boolean not null default false,
 items jsonb not null default '[]'::jsonb,
 updated_at timestamptz not null default now(),
 check(jsonb_typeof(items)='array' and jsonb_array_length(items)<=40)
);
alter table public.sacrament_programs enable row level security;
revoke all on public.sacrament_programs from public,anon,authenticated;
create or replace function public.admin_program_get(p_pass text,p_date date) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 return (select to_jsonb(p) from sacrament_programs p where p.meeting_date=p_date);
end $$;
create or replace function public.admin_program_save(p_pass text,p_date date,p_start time,p_end time,p_published boolean,p_items jsonb) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare item jsonb;
begin
 perform _check_admin(p_pass);
 if p_date is null or p_start is null or p_end is null or p_end<=p_start then raise exception 'Choose a meeting date and an end time later than the start time'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Program items must be a list'; end if;
 if jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>40 then raise exception 'Add between 1 and 40 program items'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(item)<>'object' or jsonb_typeof(item->'label') is distinct from 'string' or length(btrim(item->>'label'))<1 or length(item->>'label')>100 then raise exception 'Each program item needs a heading of up to 100 characters'; end if;
  if jsonb_typeof(item->'details') is distinct from 'string' or length(item->>'details')>1500 then raise exception 'Keep item details under 1500 characters'; end if;
  if jsonb_typeof(item->'number') is distinct from 'string' or length(item->>'number')>12 then raise exception 'Keep hymn numbers under 12 characters'; end if;
 end loop;
 insert into sacrament_programs(meeting_date,start_time,end_time,published,items)
 values(p_date,p_start,p_end,coalesce(p_published,false),p_items)
 on conflict(meeting_date) do update set start_time=excluded.start_time,end_time=excluded.end_time,published=excluded.published,items=excluded.items,updated_at=now();
end $$;
create or replace function public.program_status() returns jsonb
language sql stable security definer set search_path=public,extensions as $$
 select jsonb_build_object('server_now',now(),'opens_at',((p.meeting_date+p.start_time) at time zone 'America/New_York'),'closes_at',((p.meeting_date+p.end_time) at time zone 'America/New_York'),'active',p.published and now()>=((p.meeting_date+p.start_time) at time zone 'America/New_York') and now()<((p.meeting_date+p.end_time) at time zone 'America/New_York'))
 from (select (now() at time zone 'America/New_York')::date as today) d
 left join sacrament_programs p on p.meeting_date=d.today and p.published
$$;
create or replace function public.program_public() returns jsonb
language sql stable security definer set search_path=public,extensions as $$
 select jsonb_build_object('meeting_date',p.meeting_date,'items',p.items,'closes_at',((p.meeting_date+p.end_time) at time zone 'America/New_York'),'server_now',now())
 from sacrament_programs p where p.published and now()>=((p.meeting_date+p.start_time) at time zone 'America/New_York') and now()<((p.meeting_date+p.end_time) at time zone 'America/New_York')
$$;
revoke all on function public.admin_program_get(text,date),public.admin_program_save(text,date,time,time,boolean,jsonb),public.program_status(),public.program_public() from public,anon,authenticated;
grant execute on function public.admin_program_get(text,date),public.admin_program_save(text,date,time,time,boolean,jsonb),public.program_status(),public.program_public() to anon;
notify pgrst,'reload schema';
