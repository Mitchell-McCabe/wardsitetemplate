-- Install after the base ward schema. Keep this migration with the Leaders account rollout.
begin;

create table if not exists public.leader_accounts (
  member_id uuid primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  calling text not null check (calling in (
    'Bishop', 'Bishopric First Counselor', 'Bishopric Second Counselor',
    'Ward Executive Secretary', 'Ward Clerk'
  )),
  active boolean not null default true
);
create unique index if not exists leader_accounts_active_calling
  on public.leader_accounts (calling) where active;
alter table public.leader_accounts enable row level security;
revoke all on public.leader_accounts from public, anon, authenticated;
grant select on public.leader_accounts to service_role;

create table if not exists public.leader_account_revision (
  singleton boolean primary key default true check (singleton),
  revision bigint not null default 0
);
insert into public.leader_account_revision default values on conflict do nothing;
alter table public.leader_account_revision enable row level security;
revoke all on public.leader_account_revision from public, anon, authenticated;
grant select on public.leader_account_revision to service_role;

alter table public.admin_sessions add column if not exists leader_user_id uuid
  references auth.users(id) on delete cascade;

create or replace function public.leader_open_session() returns text
language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare
  leader_uid uuid := auth.uid();
  session_token text;
begin
  if not exists (select 1 from public.leader_accounts where user_id = leader_uid and active) then
    raise exception 'Leaders access is not active' using errcode = '42501';
  end if;
  session_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.admin_sessions (token, expires_at, leader_user_id)
    values (session_token, now() + interval '12 hours', leader_uid);
  return session_token;
end $$;
revoke all on function public.leader_open_session() from public, anon;
grant execute on function public.leader_open_session() to authenticated;

create or replace function public._check_admin(p_pass text) returns void
language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare
  pass_hash text;
  failures int;
  failed_at timestamptz;
begin
  if p_pass is null or length(p_pass) < 4 then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.admin_sessions s
    join public.leader_accounts a on a.user_id = s.leader_user_id and a.active
    where s.token = p_pass and s.expires_at > now()
  ) then return; end if;

  if (select revision from public.leader_account_revision where singleton) > 0 then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.admin_sessions
    where token = p_pass and expires_at > now() and leader_user_id is null
  ) then return; end if;
  select coalesce((select value from public.settings where key = 'admin_fail_count'), '0')::int,
         (select value from public.settings where key = 'admin_fail_at')::timestamptz
    into failures, failed_at;
  if failures >= 10 and failed_at > now() - interval '15 minutes' then
    raise exception 'Too many failed attempts' using errcode = '42501';
  end if;
  select value into pass_hash from public.settings where key = 'admin_passphrase_hash';
  if pass_hash is null or extensions.crypt(p_pass, pass_hash) <> pass_hash then
    perform pg_sleep(1);
    raise exception 'not authorized' using errcode = '42501';
  end if;
end $$;

-- Only the trusted sync endpoint can apply a verified, complete assignment snapshot.
-- Existing identities are retained so that moving or returning leaders keep their login.
create or replace function public.leader_apply_assignments(p_revision bigint, p_assignments jsonb)
returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  current_revision bigint;
begin
  select revision into current_revision from public.leader_account_revision where singleton for update;
  if p_revision is distinct from current_revision then
    raise exception 'Leaders assignments changed. Run Ward Sync again.';
  end if;
  if jsonb_typeof(p_assignments) is distinct from 'array'
     or jsonb_array_length(p_assignments) not between 1 and 5
     or not exists (select 1 from jsonb_to_recordset(p_assignments) as a(calling text) where calling = 'Bishop') then
    raise exception 'A verified calling snapshot including the Bishop is required.';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_assignments) as a(member_id uuid, user_id uuid)
    join public.leader_accounts previous using (member_id)
    where previous.user_id is distinct from a.user_id
  ) then raise exception 'An existing leader identity cannot be reassigned.'; end if;

  if not exists (
    select 1 from (
      (select member_id, user_id, calling from public.leader_accounts where active
       except select * from jsonb_to_recordset(p_assignments) as a(member_id uuid, user_id uuid, calling text))
      union all
      (select * from jsonb_to_recordset(p_assignments) as a(member_id uuid, user_id uuid, calling text)
       except select member_id, user_id, calling from public.leader_accounts where active)
    ) difference
  ) then return current_revision; end if;

  update public.leader_accounts set active = false where active;
  insert into public.leader_accounts (member_id, user_id, calling, active)
    select member_id, user_id, calling, true
    from jsonb_to_recordset(p_assignments) as a(member_id uuid, user_id uuid, calling text)
    on conflict (member_id) do update set calling = excluded.calling, active = true;
  delete from public.admin_sessions s
    where s.leader_user_id is null or not exists (
      select 1 from public.leader_accounts a where a.user_id = s.leader_user_id and a.active
    );
  update public.leader_account_revision set revision = current_revision + 1 where singleton;
  return current_revision + 1;
end $$;
revoke all on function public.leader_apply_assignments(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.leader_apply_assignments(bigint, jsonb) to service_role;

create or replace function public.leader_setup_complete() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $
  select revision > 0 from public.leader_account_revision where singleton
$;
revoke all on function public.leader_setup_complete() from public;
grant execute on function public.leader_setup_complete() to anon, authenticated;

commit;
