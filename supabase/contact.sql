create table if not exists public.ward_contact_messages (
  id bigint generated always as identity primary key,
  name text not null, email text not null, message text not null,
  created_at timestamptz not null default now(),
  handled boolean not null default false
);
alter table public.ward_contact_messages enable row level security;
revoke all on public.ward_contact_messages from public, anon, authenticated;

create or replace function public.submit_ward_contact(p_name text, p_email text, p_message text)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_name is null or length(btrim(p_name)) not between 2 and 80 then raise exception 'Enter your name'; end if;
  if p_email is null or length(btrim(p_email)) > 120 or btrim(p_email) !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Enter a valid email address'; end if;
  if p_message is null or length(btrim(p_message)) not between 1 and 1000 then raise exception 'Enter a message up to 1,000 characters'; end if;
  perform pg_advisory_xact_lock(20132004);
  if (select count(*) from public.ward_contact_messages where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'The contact form is busy. Try again later.';
  end if;
  insert into public.ward_contact_messages(name,email,message) values(btrim(p_name),lower(btrim(p_email)),btrim(p_message));
  return true;
end $$;

create or replace function public.admin_ward_contacts(p_pass text, p_include_handled boolean)
returns setof public.ward_contact_messages language plpgsql security definer set search_path='' as $$
begin
  perform public._check_admin(p_pass);
  return query select * from public.ward_contact_messages where p_include_handled or not handled order by created_at desc;
end $$;

create or replace function public.admin_ward_contact_handle(p_pass text, p_id bigint, p_handled boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform public._check_admin(p_pass);
  update public.ward_contact_messages set handled=p_handled where id=p_id;
end $$;

revoke all on function public.submit_ward_contact(text,text,text), public.admin_ward_contacts(text,boolean), public.admin_ward_contact_handle(text,bigint,boolean) from public, anon, authenticated;
grant execute on function public.submit_ward_contact(text,text,text), public.admin_ward_contacts(text,boolean), public.admin_ward_contact_handle(text,bigint,boolean) to anon, authenticated;
