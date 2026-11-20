
create table public.missionary_weekly_email (
 missionary_id bigint not null references public.ward_extra(id) on delete cascade,
 email text not null check(length(email) <= 254),
 created_at timestamptz not null default now(),
 primary key (missionary_id,email)
);
alter table public.missionary_weekly_email enable row level security;
revoke all on public.missionary_weekly_email from public,anon,authenticated;

create function public.request_missionary_weekly_email(p_id bigint,p_email text)
returns void language plpgsql security definer set search_path='' as $$
declare address text := lower(btrim(coalesce(p_email,'')));
begin
 if length(address)>254 or address !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
   raise exception 'Enter a valid email address.';
 end if;
 if not exists(select 1 from public.ward_extra where id=p_id and kind='missionary' and state='live') then
   raise exception 'This missionary is no longer accepting requests.';
 end if;
 insert into public.missionary_weekly_email(missionary_id,email) values(p_id,address)
 on conflict do nothing;
end $$;

create function public.admin_missionary_weekly_emails(p_pass text,p_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 return (select coalesce(jsonb_agg(email order by email),'[]'::jsonb)
   from public.missionary_weekly_email where missionary_id=p_id);
end $$;

create function public.admin_remove_missionary_weekly_email(p_pass text,p_id bigint,p_email text)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 delete from public.missionary_weekly_email where missionary_id=p_id and email=lower(btrim(p_email));
end $$;

revoke all on function public.request_missionary_weekly_email(bigint,text),public.admin_missionary_weekly_emails(text,bigint),public.admin_remove_missionary_weekly_email(text,bigint,text) from public;
grant execute on function public.request_missionary_weekly_email(bigint,text),public.admin_missionary_weekly_emails(text,bigint),public.admin_remove_missionary_weekly_email(text,bigint,text) to anon;
