-- Starting with newly submitted requests, queue email separately from the legacy SMS status.
alter table public.meeting_requests add column if not exists email_eligible boolean not null default false;
alter table public.meeting_requests alter column email_eligible set default true;
alter table public.meeting_requests add column if not exists email_claimed_at timestamptz;
alter table public.meeting_requests add column if not exists email_claim_id uuid;
alter table public.meeting_requests add column if not exists emailed_at timestamptz;

create or replace function public.admin_bishop_email_worker_key(p_pass text)
returns text language plpgsql security definer set search_path='' as $$
declare k text := encode(extensions.gen_random_bytes(32),'hex');
begin
  perform public._check_admin(p_pass);
  insert into public.settings(key,value) values ('bishop_email_worker_hash',encode(extensions.digest(k,'sha256'),'hex'))
  on conflict (key) do update set value=excluded.value;
  return k;
end $$;

create or replace function public.bishop_email_claim(p_key text)
returns table(request_id bigint, claim_id uuid, recipient text)
language plpgsql security definer set search_path='' as $$
declare to_email text;
begin
  if p_key is null or length(p_key) <> 64 or not exists (
    select 1 from public.settings where key='bishop_email_worker_hash'
    and value=encode(extensions.digest(p_key,'sha256'),'hex')) then raise exception 'Invalid mail worker key'; end if;
  select trim(value) into to_email from public.settings where key='bishop_notify_email';
  if to_email is null or length(to_email)>254 or to_email !~ '^[^[:space:],;@]+@[^[:space:],;@]+\.[^[:space:],;@]+$' then return; end if;
  return query
  with next_request as (
    select m.id from public.meeting_requests m
    where m.email_eligible and m.emailed_at is null and m.handled_at is null
      and m.created_at > now() - interval '2 days'
      and (m.email_claimed_at is null or m.email_claimed_at < now() - interval '15 minutes')
    order by m.id limit 1 for update skip locked
  )
  update public.meeting_requests m set email_claimed_at=now(), email_claim_id=gen_random_uuid()
  from next_request q where m.id=q.id
  returning m.id,m.email_claim_id,to_email;
end $$;

create or replace function public.bishop_email_finish(p_key text,p_id bigint,p_claim uuid,p_sent boolean)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_key is null or length(p_key) <> 64 or not exists (
    select 1 from public.settings where key='bishop_email_worker_hash'
    and value=encode(extensions.digest(p_key,'sha256'),'hex')) then raise exception 'Invalid mail worker key'; end if;
  update public.meeting_requests set emailed_at=case when p_sent then now() end, email_claimed_at=null, email_claim_id=null
  where id=p_id and email_claim_id=p_claim and emailed_at is null;
  return found;
end $$;
revoke all on function public.admin_bishop_email_worker_key(text), public.bishop_email_claim(text), public.bishop_email_finish(text,bigint,uuid,boolean) from public;
grant execute on function public.admin_bishop_email_worker_key(text), public.bishop_email_claim(text), public.bishop_email_finish(text,bigint,uuid,boolean) to anon;
notify pgrst,'reload schema';
