create table public.ward_extra (
 id bigint generated always as identity primary key,
 kind text not null check(kind in ('signup','missionary','moment')),
 title text not null check(length(btrim(title)) between 1 and 120),
 detail text not null default '' check(length(detail)<=2000),
 day date,
 capacity integer not null default 1 check(capacity between 1 and 500),
 email text not null default '' check(length(email)<=200),
 photo text not null default '' check(photo='' or (length(photo)<=500000 and photo ~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$')),
 state text not null check(state in ('pending','live','closed')),
 created_at timestamptz not null default now()
);
create table public.ward_extra_reservation (
 id bigint generated always as identity primary key,
 signup bigint not null references public.ward_extra(id),
 name text not null check(length(btrim(name)) between 1 and 100),
 contact text not null check(length(btrim(contact)) between 1 and 200)
);
create index ward_extra_reservation_signup on public.ward_extra_reservation(signup);
alter table public.ward_extra enable row level security;
alter table public.ward_extra_reservation enable row level security;
revoke all on public.ward_extra, public.ward_extra_reservation from anon, authenticated, public;

create function public.ward_extra_list() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('taken',(select count(*) from public.ward_extra_reservation r where r.signup=e.id)) order by e.day nulls last,e.id desc),'[]')
 from public.ward_extra e where e.state='live' and (e.kind<>'signup' or e.day is null or e.day>=timezone('America/New_York',now())::date);
$$;
create function public.ward_extra_request(p_title text,p_detail text,p_day date,p_capacity integer) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(917238455);
 if (select count(*) from public.ward_extra where kind='signup' and created_at>now()-interval '1 hour')>=25 then raise exception 'Please try again later'; end if;
 insert into public.ward_extra(kind,title,detail,day,capacity,state) values('signup',btrim(p_title),btrim(p_detail),p_day,p_capacity,'pending');
end $$;
create function public.ward_extra_join(p_id bigint,p_name text,p_contact text) returns void
language plpgsql security definer set search_path='' as $$
declare e public.ward_extra;
begin
 select * into e from public.ward_extra where id=p_id for update;
 if not found or e.kind<>'signup' or e.state<>'live' or e.day<timezone('America/New_York',now())::date then raise exception 'This sign-up is closed'; end if;
 if exists(select 1 from public.ward_extra_reservation where signup=p_id and lower(name)=lower(btrim(p_name)) and lower(contact)=lower(btrim(p_contact))) then raise exception 'You already signed up'; end if;
 if (select count(*) from public.ward_extra_reservation where signup=p_id)>=e.capacity then raise exception 'This sign-up is full'; end if;
 insert into public.ward_extra_reservation(signup,name,contact) values(p_id,btrim(p_name),btrim(p_contact));
end $$;
create function public.admin_ward_extra_list(p_pass text,p_kind text) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 return (select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('reservations',
 (select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]') from public.ward_extra_reservation r where r.signup=e.id)) order by (e.state='pending') desc,e.id desc),'[]')
 from public.ward_extra e where e.kind=p_kind);
end $$;
create function public.admin_ward_extra_save(p_pass text,p_id bigint,p_kind text,p_title text,p_detail text,p_day date,p_capacity int,p_email text,p_photo text,p_state text)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 if p_kind='missionary' then
   if btrim(coalesce(p_detail,''))='' then raise exception 'Enter the mission name.'; end if;
   if btrim(coalesce(p_email,''))<>'' and btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
     raise exception 'Enter a valid missionary email address, or leave it blank.';
   end if;
 end if;
 if p_kind='moment' and (btrim(p_detail)='' or coalesce(p_photo,(select photo from public.ward_extra where id=p_id and kind=p_kind),'')='') then raise exception 'Add a story and photo'; end if;
 if p_id is null then
 insert into public.ward_extra(kind,title,detail,day,capacity,email,photo,state) values(p_kind,btrim(p_title),btrim(p_detail),p_day,p_capacity,btrim(coalesce(p_email,'')),coalesce(p_photo,''),p_state);
 else
 update public.ward_extra set title=btrim(p_title),detail=btrim(p_detail),day=p_day,capacity=p_capacity,email=btrim(coalesce(p_email,'')),photo=coalesce(p_photo,photo),state=p_state where id=p_id and kind=p_kind;
 end if;
end $$;
create function public.admin_ward_extra_remove(p_pass text,p_id bigint,p_reservation boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 if p_reservation then delete from public.ward_extra_reservation where id=p_id;
 else update public.ward_extra set state='closed' where id=p_id; end if;
end $$;
revoke all on function public.ward_extra_list(),public.ward_extra_request(text,text,date,integer),public.ward_extra_join(bigint,text,text),public.admin_ward_extra_list(text,text),public.admin_ward_extra_save(text,bigint,text,text,text,date,integer,text,text,text),public.admin_ward_extra_remove(text,bigint,boolean) from public;
grant execute on function public.ward_extra_list(),public.ward_extra_request(text,text,date,integer),public.ward_extra_join(bigint,text,text),public.admin_ward_extra_list(text,text),public.admin_ward_extra_save(text,bigint,text,text,text,date,integer,text,text,text),public.admin_ward_extra_remove(text,bigint,boolean) to anon;
