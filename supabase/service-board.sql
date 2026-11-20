-- Ward lending, borrowing, help, and reviewed service projects.
create table if not exists public.service_board_settings(id boolean primary key default true check(id),enabled boolean not null default true,review_listings boolean not null default false);
insert into public.service_board_settings(id)values(true)on conflict do nothing;
create table if not exists public.service_listings(
 id uuid primary key default gen_random_uuid(),kind text not null check(kind in('lend','borrow','need_help','offer_help','project')),
 title text not null,details text not null,category text not null default '',location text not null default '',timing text not null default '',event_date date,
 contact_name text not null,phone text not null default '',email text not null default '',contact_note text not null default '',
 status text not null default 'pending' check(status in('pending','approved','rejected')),
 resolution text not null default 'open' check(resolution in('open','fulfilled','closed')),
 manage_hash text not null,review_note text not null default '',created_at timestamptz not null default now(),updated_at timestamptz not null default now(),reviewed_at timestamptz);
create index if not exists service_listings_public on public.service_listings(status,resolution,kind,created_at desc);
alter table public.service_board_settings enable row level security;
alter table public.service_listings enable row level security;
revoke all on public.service_board_settings,public.service_listings from public,anon,authenticated;

create or replace function public._service_validate(p jsonb) returns void language plpgsql set search_path=public,extensions as $$
begin
 if p is null or jsonb_typeof(p)<>'object' then raise exception 'Enter listing details';end if;
 if coalesce(p->>'kind','') not in('lend','borrow','need_help','offer_help','project') then raise exception 'Choose a listing type';end if;
 if length(btrim(coalesce(p->>'title','')))<3 or length(p->>'title')>120 then raise exception 'Enter a title of 3 to 120 characters';end if;
 if length(btrim(coalesce(p->>'details','')))<5 or length(p->>'details')>4000 then raise exception 'Enter details of 5 to 4000 characters';end if;
 if length(btrim(coalesce(p->>'contact_name','')))<2 or length(p->>'contact_name')>120 then raise exception 'Enter your name';end if;
 if length(coalesce(p->>'phone',''))>40 or length(coalesce(p->>'email',''))>200 or length(coalesce(p->>'contact_note',''))>300 or length(coalesce(p->>'location',''))>200 or length(coalesce(p->>'timing',''))>200 or length(coalesce(p->>'category',''))>80 then raise exception 'A field is too long';end if;
 if btrim(coalesce(p->>'phone',''))='' and btrim(coalesce(p->>'email',''))='' then raise exception 'Enter a phone number or email so others can coordinate with you';end if;
 if btrim(coalesce(p->>'phone',''))<>'' and length(_meal_phone(p->>'phone')) not between 10 and 15 then raise exception 'Enter a valid phone number';end if;
 if btrim(coalesce(p->>'email',''))<>'' and btrim(p->>'email')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email';end if;
 if p->>'kind'='project' and (btrim(coalesce(p->>'location',''))='' or (btrim(coalesce(p->>'timing',''))='' and coalesce(p->>'event_date','')='')) then raise exception 'Add a location and date or timing for the project';end if;
 if coalesce(p->>'event_date','')<>'' and (p->>'event_date')::date<(now()at time zone 'America/New_York')::date then raise exception 'Choose today or a future date';end if;
end $$;

create or replace function public.service_board(p_kind text default 'all',p_query text default '',p_page int default 1) returns jsonb
language plpgsql stable security definer set search_path=public,extensions as $$
declare total int;items jsonb;cfg service_board_settings;pg int:=greatest(1,least(coalesce(p_page,1),100000));
begin
 select * into cfg from service_board_settings where id;
 if not cfg.enabled then return jsonb_build_object('enabled',false,'items','[]'::jsonb,'total',0);end if;
 select count(*)into total from service_listings l where l.status='approved' and l.resolution='open' and (l.event_date is null or l.event_date>=(now()at time zone 'America/New_York')::date) and (p_kind='all' or l.kind=p_kind) and concat_ws(' ',l.title,l.details,l.category,l.location) ilike '%'||left(coalesce(p_query,''),100)||'%';
 select coalesce(jsonb_agg(to_jsonb(t)order by t.created_at desc,t.id),'[]'::jsonb)into items from(select l.id,l.kind,l.title,l.details,l.category,l.location,l.timing,l.event_date,l.contact_name,l.created_at from service_listings l where l.status='approved' and l.resolution='open' and (l.event_date is null or l.event_date>=(now()at time zone 'America/New_York')::date) and (p_kind='all' or l.kind=p_kind) and concat_ws(' ',l.title,l.details,l.category,l.location) ilike '%'||left(coalesce(p_query,''),100)||'%' order by l.created_at desc,l.id limit 20 offset(pg-1)*20)t;
 return jsonb_build_object('enabled',true,'review_listings',cfg.review_listings,'items',items,'total',total,'page',pg,'page_size',20);
end $$;
create or replace function public.service_submit(p_data jsonb,p_website text default '')returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare cfg service_board_settings;v_id uuid;token text;v_status text;
begin
 if coalesce(p_website,'')<>'' then raise exception 'Unable to submit';end if;
 perform _service_validate(p_data);
 perform pg_advisory_xact_lock(742902);
 select * into cfg from service_board_settings where id;
 if not cfg.enabled then raise exception 'The service board is closed right now';end if;
 if(select count(*)from service_listings where created_at>now()-interval '1 hour')>=100 then raise exception 'Too many listings right now. Try again later';end if;
 if exists(select 1 from service_listings where created_at>now()-interval '2 minutes' and title=btrim(p_data->>'title') and contact_name=btrim(p_data->>'contact_name') and kind=p_data->>'kind')then raise exception 'This listing was just submitted. Check My listings';end if;
 token:=encode(gen_random_bytes(24),'hex');v_status:=case when p_data->>'kind'='project' or cfg.review_listings then 'pending' else 'approved' end;
 insert into service_listings(kind,title,details,category,location,timing,event_date,contact_name,phone,email,contact_note,status,manage_hash)
 values(p_data->>'kind',btrim(p_data->>'title'),btrim(p_data->>'details'),btrim(coalesce(p_data->>'category','')),btrim(coalesce(p_data->>'location','')),btrim(coalesce(p_data->>'timing','')),nullif(p_data->>'event_date','')::date,btrim(p_data->>'contact_name'),btrim(coalesce(p_data->>'phone','')),btrim(coalesce(p_data->>'email','')),btrim(coalesce(p_data->>'contact_note','')),v_status,encode(digest(token,'sha256'),'hex'))returning id into v_id;
 return jsonb_build_object('id',v_id,'status',v_status,'manage_token',token);
end $$;
create or replace function public.service_contact(p_id uuid)returns jsonb
language plpgsql stable security definer set search_path=public,extensions as $$
declare result jsonb;
begin
 select jsonb_build_object('name',l.contact_name,'phone',l.phone,'email',l.email,'note',l.contact_note)into result from service_listings l where l.id=p_id and l.status='approved' and l.resolution='open' and (l.event_date is null or l.event_date>=(now()at time zone 'America/New_York')::date) and exists(select 1 from service_board_settings where enabled);
 if result is null then raise exception 'This listing is not available';end if;return result;
end $$;
create or replace function public.service_my_listings(p_keys jsonb)returns jsonb
language plpgsql stable security definer set search_path=public,extensions as $$
begin
 if p_keys is null or jsonb_typeof(p_keys)<>'array' or jsonb_array_length(p_keys)>100 then raise exception 'Invalid saved listings';end if;
 return(select coalesce(jsonb_agg(to_jsonb(l)-'manage_hash' order by l.created_at desc),'[]'::jsonb)from service_listings l where exists(select 1 from jsonb_array_elements(p_keys)k where k->>'id'=l.id::text and length(k->>'token')=48 and l.manage_hash=encode(digest(k->>'token','sha256'),'hex')));
end $$;
create or replace function public.service_manage(p_id uuid,p_token text,p_resolution text)returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 if p_resolution is null or p_resolution not in('open','fulfilled','closed')then raise exception 'Choose a valid listing state';end if;
 update service_listings set resolution=p_resolution,updated_at=now()where id=p_id and length(p_token)=48 and manage_hash=encode(digest(p_token,'sha256'),'hex');
 if not found then raise exception 'This device cannot manage that listing. Ask a leader for help';end if;
end $$;
create or replace function public.admin_service_state(p_pass text,p_status text default 'all',p_page int default 1)returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 return jsonb_build_object('settings',(select to_jsonb(s)from service_board_settings s where id),'pending',(select count(*)from service_listings where status='pending'),'total',(select count(*)from service_listings where p_status='all' or status=p_status),
 'items',(select coalesce(jsonb_agg(to_jsonb(t)-'manage_hash' order by(t.status='pending')desc,t.created_at desc),'[]'::jsonb)from(select * from service_listings where p_status='all' or status=p_status order by(status='pending')desc,created_at desc,id limit 30 offset(greatest(1,least(coalesce(p_page,1),100000))-1)*30)t));
end $$;
create or replace function public.admin_service_settings(p_pass text,p_enabled boolean,p_review_listings boolean)returns void
language plpgsql security definer set search_path=public,extensions as $$
begin perform _check_admin(p_pass);update service_board_settings set enabled=coalesce(p_enabled,true),review_listings=coalesce(p_review_listings,false)where id;end $$;
drop function if exists public.admin_service_review(text,uuid,text,text);
create or replace function public.admin_service_review(p_pass text,p_id uuid,p_status text,p_note text default '',p_resolution text default null)returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);
 if p_status is null or p_status not in('pending','approved','rejected')then raise exception 'Choose a valid review decision';end if;
 if p_resolution is not null and p_resolution not in('open','fulfilled','closed')then raise exception 'Choose a valid listing state';end if;
 if length(coalesce(p_note,''))>500 then raise exception 'Keep review notes under 500 characters';end if;
 update service_listings set status=p_status,resolution=coalesce(p_resolution,resolution),review_note=coalesce(p_note,''),reviewed_at=case when p_status='pending'then null else now()end,updated_at=now()where id=p_id;
 if not found then raise exception 'Listing not found';end if;
end $$;
create or replace function public.admin_service_resolution(p_pass text,p_id uuid,p_resolution text)returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);if p_resolution is null or p_resolution not in('open','fulfilled','closed')then raise exception 'Choose a valid listing state';end if;
 update service_listings set resolution=p_resolution,updated_at=now()where id=p_id;if not found then raise exception 'Listing not found';end if;
end $$;
create or replace function public.admin_service_edit(p_pass text,p_id uuid,p_data jsonb)returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform _check_admin(p_pass);perform _service_validate(p_data);
 update service_listings set kind=p_data->>'kind',title=btrim(p_data->>'title'),details=btrim(p_data->>'details'),category=btrim(coalesce(p_data->>'category','')),location=btrim(coalesce(p_data->>'location','')),timing=btrim(coalesce(p_data->>'timing','')),event_date=nullif(p_data->>'event_date','')::date,contact_name=btrim(p_data->>'contact_name'),phone=btrim(coalesce(p_data->>'phone','')),email=btrim(coalesce(p_data->>'email','')),contact_note=btrim(coalesce(p_data->>'contact_note','')),updated_at=now()where id=p_id;
 if not found then raise exception 'Listing not found';end if;
end $$;
do $permissions$declare f record;begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and (p.proname like 'service_%' or p.proname like 'admin_service_%' or p.proname='_service_validate')loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 if f.proname<>'_service_validate' then execute format('grant execute on function %s to anon',f.signature);end if;
 end loop;end $permissions$;
notify pgrst,'reload schema';
