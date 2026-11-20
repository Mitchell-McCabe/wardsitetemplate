-- Ward Site: initial setup for a new ward project
-- Supabase Dashboard > SQL Editor > New query: paste this whole file and Run.
-- Creates the database and flyer bucket used by the current site.
-- No copied ward members, events, announcements, recipients, or scores are imported.
-- The existing app uses a leader passphrase; individual leader accounts can be added later.
-- Run the separate passphrase command shown at the end after this succeeds.
begin;

-- MODULE: schema
-- Ward site — roll / attendance schema
-- Paste this whole file into the Supabase SQL editor of your project and run it once.
-- Safe to re-run: everything is CREATE ... IF NOT EXISTS / CREATE OR REPLACE.
--
-- Roll classes (Primary, Young Men, Young Women, Sunday School, Elders Quorum, Relief
-- Society — whatever your ward uses) are NOT hardcoded here. They are configured on the
-- Leaders › Settings page (stored as the 'roll_classes' row in the settings table below)
-- so a ward can add, rename or remove classes at any time without touching this schema.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.members (
  id                 uuid primary key default gen_random_uuid(),
  lcr_uuid           uuid unique,            -- LCR person uuid (used when pushing attendance back)
  lcr_classes        jsonb not null default '[]'::jsonb, -- [{"orgName","classUuid","orgTypeId"}] from LCR
  name               text not null,          -- as LCR shows it: "Last, First Middle"
  display_name       text not null,          -- "First Last" for the roll
  sex                text check (sex in ('M','F')),
  org                text,                   -- optional sub-group within a class (e.g. "EQ" / "RS") — free text, ward-defined
  age                int,
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists members_active_name_idx on public.members (active, display_name);

create table if not exists public.attendance (
  id             bigserial primary key,
  meeting_date   date not null,
  class          text not null,          -- a key from the ward's 'roll_classes' setting
  member_id      uuid not null references public.members(id) on delete cascade,
  created_at     timestamptz not null default now(),
  synced_to_lcr_at timestamptz,
  unique (meeting_date, class, member_id)
);
create index if not exists attendance_date_class_idx on public.attendance (meeting_date, class);

create table if not exists public.settings (
  key    text primary key,
  value  text not null
);

-- ---------------------------------------------------------------------------
-- Row Level Security: the anon key can do nothing directly. All access goes
-- through the functions below (SECURITY DEFINER), which decide what is allowed.
-- ---------------------------------------------------------------------------
alter table public.members    enable row level security;
alter table public.attendance enable row level security;
alter table public.settings   enable row level security;
revoke all on public.members, public.attendance, public.settings from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public._check_admin(p_pass text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_fail int; v_at timestamptz;
begin
  if p_pass is null or length(p_pass) < 4 then raise exception 'not authorized' using errcode = '42501'; end if;
  if exists (select 1 from admin_sessions where token = p_pass and expires_at > now()) then return; end if;
  select coalesce((select value from settings where key = 'admin_fail_count'), '0')::int,
         (select value from settings where key = 'admin_fail_at')::timestamptz
    into v_fail, v_at;
  if v_fail >= 10 and v_at is not null and v_at > now() - interval '15 minutes' then
    raise exception 'Too many failed attempts — try again in 15 minutes' using errcode = '42501';
  end if;
  select value into v_hash from settings where key = 'admin_passphrase_hash';
  if v_hash is null or crypt(p_pass, v_hash) <> v_hash then
    perform pg_sleep(1);
    raise exception 'not authorized' using errcode = '42501';
  end if;
end $$;

-- Most recent Sunday (America/New_York), or today if today is Sunday.
create or replace function public.current_meeting_date() returns date
language sql stable set search_path = pg_catalog as $$
  select (
    (now() at time zone 'America/New_York')::date
    - extract(dow from (now() at time zone 'America/New_York'))::int
  )::date
$$;

-- The ward's configured roll classes, e.g.
--   [{"key":"primary","label":"Primary","short":"Primary","orgTypeIds":[...]},
--    {"key":"sunday_school","label":"Sunday School","short":"Sunday School","orgTypeIds":[...]}, ...]
-- Stored as the 'roll_classes' setting so leaders can add/rename/remove classes at any time
-- (Leaders › Settings). Falls back to an empty list until configured.
create or replace function public.roll_classes()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select value::jsonb from settings where key = 'roll_classes'), '[]'::jsonb)
$$;
grant execute on function public.roll_classes() to anon;

-- True if p_class is one of the ward's configured roll class keys.
create or replace function public._valid_class(p_class text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from jsonb_array_elements(roll_classes()) c where c->>'key' = p_class)
$$;

-- Admin: replace the whole roll-classes list in one call (validated shape).
create or replace function public.admin_set_roll_classes(p_pass text, p_classes jsonb)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  if jsonb_typeof(p_classes) <> 'array' then raise exception 'roll classes must be a list'; end if;
  if exists (select 1 from jsonb_array_elements(p_classes) c where coalesce(c->>'key','') = '' or coalesce(c->>'label','') = '') then
    raise exception 'each class needs a key and a label';
  end if;
  insert into settings (key, value) values ('roll_classes', p_classes::text)
  on conflict (key) do update set value = excluded.value;
end $$;
grant execute on function public.admin_set_roll_classes(text, jsonb) to anon;

-- ---------------------------------------------------------------------------
-- Public (anon) functions used by the roll pages
-- ---------------------------------------------------------------------------

-- Active members for the roll. Only the fields the page needs.
create or replace function public.roll_members()
returns table (id uuid, display_name text, org text)
language sql stable security definer set search_path = public, extensions as $$
  select id, display_name, org
  from members
  where active
  order by lower(name)
$$;

-- Who is already checked in for a given meeting/class (ids only).
create or replace function public.checked_in(p_date date, p_class text)
returns setof uuid
language sql stable security definer set search_path = public, extensions as $$
  select member_id from attendance where meeting_date = p_date and class = p_class
$$;

-- Check in one or more members. Only allows dates within the last 8 days
-- (so a stale phone can't write to a random week). Duplicates are ignored.
create or replace function public.check_in(p_date date, p_class text, p_member_ids uuid[])
returns int
language plpgsql security definer set search_path = public, extensions as $$
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
  where m.id = any(p_member_ids) and m.active
  on conflict do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Undo a check-in (someone tapped the wrong name).
create or replace function public.check_out(p_date date, p_class text, p_member_id uuid)
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v_count int;
begin
  delete from attendance
  where meeting_date = p_date and class = p_class and member_id = p_member_id
    and created_at > now() - interval '3 hours';   -- only recent mistakes
  get diagnostics v_count = row_count;
  return v_count;
end $$;

grant execute on function public.roll_members()                    to anon;
grant execute on function public.checked_in(date, text)            to anon;
grant execute on function public.check_in(date, text, uuid[])      to anon;
grant execute on function public.check_out(date, text, uuid)       to anon;
grant execute on function public.current_meeting_date()            to anon;

-- ---------------------------------------------------------------------------
-- Admin functions (passphrase-gated). Used by admin.html and the LCR sync.
-- ---------------------------------------------------------------------------

-- Set / change the admin passphrase. Run this once from the SQL editor:
--   select set_admin_passphrase('CHOOSE-A-PASSPHRASE');
-- (Only callable from the SQL editor / service role — not granted to anon.)
create or replace function public.set_admin_passphrase(p_pass text) returns void
language sql security definer set search_path = public, extensions as $$
  insert into settings (key, value)
  values ('admin_passphrase_hash', crypt(p_pass, gen_salt('bf')))
  on conflict (key) do update set value = excluded.value
$$;
revoke execute on function public.set_admin_passphrase(text) from anon, authenticated, public;

-- Attendance for one Sunday, with names, for every class.
create or replace function public.admin_attendance(p_pass text, p_date date)
returns table (
  attendance_id bigint, class text, member_id uuid, display_name text, name text,
  org text, lcr_uuid uuid, lcr_classes jsonb, created_at timestamptz, synced_to_lcr_at timestamptz
)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query
    select a.id, a.class, m.id, m.display_name, m.name, m.org, m.lcr_uuid, m.lcr_classes,
           a.created_at, a.synced_to_lcr_at
    from attendance a join members m on m.id = a.member_id
    where a.meeting_date = p_date
    order by a.class, lower(m.display_name);
end $$;

-- Sundays that have any attendance, newest first (for the admin date picker). Per-class
-- counts (including guests) come back as one jsonb object keyed by class, e.g. {"primary":12,...}.
create or replace function public.admin_meeting_dates(p_pass text)
returns table (meeting_date date, counts jsonb)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query
    with x as (
      select a.meeting_date, a.class from attendance a
      union all
      select g.meeting_date, g.class from attendance_guests g
    )
    select x.meeting_date, coalesce(jsonb_object_agg(x.class, x.n), '{}'::jsonb)
    from (select source.meeting_date, source.class, count(*) as n from x as source group by source.meeting_date, source.class) x
    group by x.meeting_date
    order by x.meeting_date desc
    limit 52;
end $$;

-- Full member list for the admin page.
create or replace function public.admin_members(p_pass text)
returns setof public.members
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from members order by active desc, lower(name);
end $$;

-- Import / refresh members from LCR. p_members is a JSON array of objects:
--   { "lcr_uuid": "…", "name": "Last, First", "display_name": "First Last",
--     "sex": "M"|"F", "org": "EQ"|"RS"|…, "age": 24,
--     "lcr_classes": [{"orgName":"Adult Sunday School","classUuid":"…","orgTypeId":1255}, …] }
-- Existing rows are matched on lcr_uuid (fallback: exact name).
-- If p_deactivate_missing is true, members not in the list are marked inactive.
create or replace function public.admin_upsert_members(p_pass text, p_members jsonb, p_deactivate_missing boolean default true)
returns table (inserted int, updated int, deactivated int)
language plpgsql security definer set search_path = public, extensions as $$
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
    where (r.lcr_uuid is not null and m.lcr_uuid = r.lcr_uuid)
       or (r.lcr_uuid is null and m.name = r.name);
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
    where m.active
      and not exists (
        select 1 from _incoming i
        where (i.lcr_uuid is not null and i.lcr_uuid = m.lcr_uuid)
           or (i.lcr_uuid is null and i.name = m.name));
    get diagnostics v_deact = row_count;
  end if;

  return query select v_ins, v_upd, v_deact;
end $$;

-- Mark attendance rows as pushed to LCR.
create or replace function public.admin_mark_synced(p_pass text, p_attendance_ids bigint[])
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v int;
begin
  perform _check_admin(p_pass);
  update attendance set synced_to_lcr_at = now() where id = any(p_attendance_ids);
  get diagnostics v = row_count;
  return v;
end $$;

-- Manually toggle a member active/inactive (moved out, etc.).
create or replace function public.admin_set_member_active(p_pass text, p_member_id uuid, p_active boolean)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  update members set active = p_active, updated_at = now() where id = p_member_id;
end $$;

-- Admin-side check-in/out (fixing the roll after the fact, any date).
create or replace function public.admin_set_attendance(p_pass text, p_date date, p_class text, p_member_id uuid, p_present boolean)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  if p_present then
    insert into attendance (meeting_date, class, member_id) values (p_date, p_class, p_member_id)
    on conflict do nothing;
  else
    delete from attendance where meeting_date = p_date and class = p_class and member_id = p_member_id;
  end if;
end $$;

grant execute on function public.admin_attendance(text, date)                         to anon;
grant execute on function public.admin_meeting_dates(text)                            to anon;
grant execute on function public.admin_members(text)                                  to anon;
grant execute on function public.admin_upsert_members(text, jsonb, boolean)           to anon;
grant execute on function public.admin_mark_synced(text, bigint[])                    to anon;
grant execute on function public.admin_set_member_active(text, uuid, boolean)         to anon;
grant execute on function public.admin_set_attendance(text, date, text, uuid, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Guests / visitors who are not on the LCR roll: they type their name on the roll page.
-- ---------------------------------------------------------------------------
create table if not exists public.attendance_guests (
  id             bigserial primary key,
  meeting_date   date not null,
  class          text not null,
  name           text not null,
  created_at     timestamptz not null default now(),
  synced_to_lcr_at timestamptz
);
create unique index if not exists attendance_guests_unique_idx
  on public.attendance_guests (meeting_date, class, lower(name));
alter table public.attendance_guests enable row level security;
revoke all on public.attendance_guests from anon, authenticated;

-- Public: a guest checks in by typing a name (2–60 chars, letters/spaces/'-. only).
create or replace function public.check_in_guest(p_date date, p_class text, p_name text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_name text;
begin
  if not _valid_class(p_class) then raise exception 'bad class'; end if;
  if not _window_open(p_class) then raise exception 'Check-in is closed right now' using errcode = 'P0001'; end if;
  if p_date > (now() at time zone 'America/New_York')::date + 1
     or p_date < (now() at time zone 'America/New_York')::date - 8 then
    raise exception 'date out of range';
  end if;
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if length(v_name) < 2 or length(v_name) > 60 or v_name !~ '^[[:alpha:]][[:alpha:] ''.-]*$' then
    raise exception 'Please enter a first and last name';
  end if;
  insert into attendance_guests (meeting_date, class, name) values (p_date, p_class, v_name)
  on conflict do nothing;
  return v_name;
end $$;

-- Public: guest names already checked in for a meeting/class.
create or replace function public.guests_checked_in(p_date date, p_class text)
returns setof text
language sql stable security definer set search_path = public, extensions as $$
  select name from attendance_guests where meeting_date = p_date and class = p_class order by lower(name)
$$;

grant execute on function public.check_in_guest(date, text, text) to anon;
grant execute on function public.guests_checked_in(date, text)   to anon;

-- Admin: guests for a Sunday.
create or replace function public.admin_guests(p_pass text, p_date date)
returns table (guest_id bigint, class text, name text, created_at timestamptz, synced_to_lcr_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select g.id, g.class, g.name, g.created_at, g.synced_to_lcr_at
    from attendance_guests g where g.meeting_date = p_date order by g.class, lower(g.name);
end $$;

create or replace function public.admin_remove_guest(p_pass text, p_guest_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  delete from attendance_guests where id = p_guest_id;
end $$;

create or replace function public.admin_mark_guests_synced(p_pass text, p_guest_ids bigint[])
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v int;
begin
  perform _check_admin(p_pass);
  update attendance_guests set synced_to_lcr_at = now() where id = any(p_guest_ids);
  get diagnostics v = row_count;
  return v;
end $$;

grant execute on function public.admin_guests(text, date)                 to anon;
grant execute on function public.admin_remove_guest(text, bigint)         to anon;
grant execute on function public.admin_mark_guests_synced(text, bigint[]) to anon;

-- ---------------------------------------------------------------------------
-- Check-in time windows (America/New_York). One window per class, keyed
-- 'window_<class key>' in settings, e.g. "12:50-14:30". A class with no window
-- setting is always open. Leaders › Settings edits these per class.
-- ---------------------------------------------------------------------------
insert into public.settings (key, value) values
  ('window_day', '0'),                 -- 0 = Sunday
  ('roll_enforce_window', 'true')      -- set to 'false' to allow check-in any time (testing)
on conflict (key) do nothing;

-- Public: the windows for every configured class, so the site can grey buttons out
-- without a reload. A class with no 'window_<key>' setting comes back unenforced (always open).
create or replace function public.roll_windows()
returns table (class text, start_time text, end_time text, day_of_week int, enforced boolean)
language sql stable security definer set search_path = public, extensions as $$
  select c->>'key',
         split_part(s.value, '-', 1), split_part(s.value, '-', 2),
         coalesce((select value from settings where key = 'window_day'), '0')::int,
         coalesce((select value from settings where key = 'roll_enforce_window'), 'true') = 'true' and s.value is not null
  from jsonb_array_elements(roll_classes()) c
  left join settings s on s.key = 'window_' || (c->>'key')
$$;
grant execute on function public.roll_windows() to anon;

-- Is the window for p_class open right now (ET)? Always true when unconfigured or enforcement is off.
create or replace function public._window_open(p_class text) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare v text; v_day int; v_now timestamp; v_t time;
begin
  if coalesce((select value from settings where key = 'roll_enforce_window'), 'true') <> 'true' then return true; end if;
  select value into v from settings where key = 'window_' || p_class;
  if v is null then return true; end if;
  v_day := coalesce((select value from settings where key = 'window_day'), '0')::int;
  v_now := now() at time zone 'America/New_York';
  v_t := v_now::time;
  return extract(dow from v_now)::int = v_day
     and v_t >= split_part(v, '-', 1)::time
     and v_t <  split_part(v, '-', 2)::time;
end $$;

-- Admin: read / change settings from the Leaders page.
create or replace function public.admin_get_settings(p_pass text)
returns setof public.settings
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from settings where key not in ('admin_passphrase_hash','admin_fail_count','admin_fail_at') order by key;
end $$;

create or replace function public.admin_set_setting(p_pass text, p_key text, p_value text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  if p_key = 'admin_passphrase_hash' then raise exception 'not allowed'; end if;
  if p_key like 'window_%' and p_key <> 'window_day' and p_value !~ '^\d{1,2}:\d{2}-\d{1,2}:\d{2}$' then
    raise exception 'window must look like 12:50-14:30';
  end if;
  insert into settings (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
end $$;

grant execute on function public.admin_get_settings(text)              to anon;
grant execute on function public.admin_set_setting(text, text, text)    to anon;

-- Public: settings safe to show on the site itself (no passphrase needed), such as the ward's
-- name — set on Leaders › Settings, used everywhere on the site instead of being hardcoded in
-- config.js, so a ward can rename itself without editing any files.
create or replace function public.site_settings()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('ward_name', coalesce((select value from settings where key = 'ward_name'), ''))
$$;
grant execute on function public.site_settings() to anon;

-- ---------------------------------------------------------------------------
-- Leaders login: short-lived session tokens + brute-force lockout
-- ---------------------------------------------------------------------------
create table if not exists public.admin_sessions (
  token       text primary key,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  label       text
);
alter table public.admin_sessions enable row level security;
revoke all on public.admin_sessions from anon, authenticated;

-- Login: returns {ok, token} or {ok:false, error}. Failures are counted here (this function never
-- raises, so the count commits) and the lockout applies to every admin function.
create or replace function public.admin_login(p_pass text, p_label text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_fail int; v_at timestamptz; v_token text;
begin
  delete from admin_sessions where expires_at < now();
  select coalesce((select value from settings where key = 'admin_fail_count'), '0')::int,
         (select value from settings where key = 'admin_fail_at')::timestamptz
    into v_fail, v_at;
  if v_at is not null and v_at < now() - interval '15 minutes' then v_fail := 0; end if;
  if v_fail >= 10 then
    return jsonb_build_object('ok', false, 'error', 'Too many failed attempts — try again in 15 minutes');
  end if;
  select value into v_hash from settings where key = 'admin_passphrase_hash';
  if v_hash is null or p_pass is null or crypt(p_pass, v_hash) <> v_hash then
    insert into settings (key, value) values ('admin_fail_count', (v_fail + 1)::text)
      on conflict (key) do update set value = excluded.value;
    insert into settings (key, value) values ('admin_fail_at', now()::text)
      on conflict (key) do update set value = excluded.value;
    perform pg_sleep(1);
    return jsonb_build_object('ok', false, 'error', 'Wrong passphrase', 'attempts_left', 10 - (v_fail + 1));
  end if;
  insert into settings (key, value) values ('admin_fail_count', '0') on conflict (key) do update set value = '0';
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into admin_sessions (token, expires_at, label) values (v_token, now() + interval '12 hours', left(p_label, 80));
  return jsonb_build_object('ok', true, 'token', v_token, 'expires_in_hours', 12);
end $$;

create or replace function public.admin_logout(p_token text) returns void
language sql security definer set search_path = public, extensions as $$
  delete from admin_sessions where token = p_token
$$;

grant execute on function public.admin_login(text, text) to anon;
grant execute on function public.admin_logout(text)      to anon;

-- ---------------------------------------------------------------------------
-- Announcements (editable by leaders) + "Request a meeting with the Bishop"
-- ---------------------------------------------------------------------------
create table if not exists public.announcements (
  id          bigserial primary key,
  subject     text,
  text        text not null default '',
  images      jsonb not null default '[]'::jsonb,   -- [{"path":"img/ann-…","name":"…"}]
  files       jsonb not null default '[]'::jsonb,   -- PDFs, same shape
  sent_at     timestamptz,                          -- when the email went out
  source      text,                                 -- 'email' | 'leaders'
  message_id  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  text
);
alter table public.announcements enable row level security;
revoke all on public.announcements from anon, authenticated;

-- Public: what the home page shows.
create or replace function public.current_announcements()
returns table (id bigint, subject text, text text, images jsonb, files jsonb, sent_at timestamptz, updated_at timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  select id, subject, text, images, files, sent_at, updated_at
  from announcements order by created_at desc limit 1
$$;
grant execute on function public.current_announcements() to anon;

-- Admin / Apps Script: publish a new week (skips if that email was already published).
create or replace function public.admin_publish_announcements(p_pass text, p_text text, p_images jsonb default '[]', p_files jsonb default '[]', p_subject text default null, p_sent_at timestamptz default null, p_message_id text default null, p_source text default 'email')
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint;
begin
  perform _check_admin(p_pass);
  if p_message_id is not null then
    select id into v_id from announcements where message_id = p_message_id;
    if v_id is not null then return v_id; end if;
  end if;
  insert into announcements (subject, text, images, files, sent_at, source, message_id)
  values (p_subject, coalesce(p_text, ''), coalesce(p_images, '[]'), coalesce(p_files, '[]'), p_sent_at, p_source, p_message_id)
  returning id into v_id;
  return v_id;
end $$;

-- Admin: edit the current announcements in place.
create or replace function public.admin_update_announcements(p_pass text, p_id bigint, p_text text, p_images jsonb, p_files jsonb, p_by text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  update announcements set text = coalesce(p_text, text), images = coalesce(p_images, images), files = coalesce(p_files, files),
    updated_at = now(), updated_by = left(p_by, 80)
  where id = p_id;
end $$;

create or replace function public.admin_announcements_history(p_pass text)
returns setof public.announcements
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from announcements order by created_at desc limit 12;
end $$;

grant execute on function public.admin_publish_announcements(text, text, jsonb, jsonb, text, timestamptz, text, text) to anon;
grant execute on function public.admin_update_announcements(text, bigint, text, jsonb, jsonb, text) to anon;
grant execute on function public.admin_announcements_history(text) to anon;

-- ---------------------------------------------------------------------------
-- Meeting requests for the Bishop (handled by the executive secretaries)
-- ---------------------------------------------------------------------------
create table if not exists public.meeting_requests (
  id                bigserial primary key,
  name              text not null,
  phone             text not null,
  email             text not null,
  temple_recommend  boolean not null default false,
  note              text,
  created_at        timestamptz not null default now(),
  handled_at        timestamptz,
  handled_by        text
);
alter table public.meeting_requests enable row level security;
revoke all on public.meeting_requests from anon, authenticated;

create or replace function public.submit_meeting_request(p_name text, p_phone text, p_email text, p_temple_recommend boolean default false, p_note text default null)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_name text; v_phone text; v_email text;
begin
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_phone := btrim(coalesce(p_phone, ''));
  v_email := lower(btrim(coalesce(p_email, '')));
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Please enter your name'; end if;
  if length(regexp_replace(v_phone, '\D', '', 'g')) < 7 or length(v_phone) > 40 then raise exception 'Please enter a phone number we can reach you at'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then raise exception 'Please enter a valid email address'; end if;
  if length(coalesce(p_note, '')) > 1000 then raise exception 'Please keep the note under 1000 characters'; end if;
  if (select count(*) from meeting_requests where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many requests right now — please try again in a little while';
  end if;
  insert into meeting_requests (name, phone, email, temple_recommend, note)
  values (v_name, v_phone, v_email, coalesce(p_temple_recommend, false), nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.submit_meeting_request(text, text, text, boolean, text) to anon;

create or replace function public.admin_meeting_requests(p_pass text, p_include_handled boolean default false)
returns setof public.meeting_requests
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from meeting_requests m where p_include_handled or m.handled_at is null
    order by m.handled_at is not null, m.created_at desc;
end $$;

create or replace function public.admin_meeting_handled(p_pass text, p_id bigint, p_handled boolean, p_by text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  update meeting_requests set handled_at = case when p_handled then now() end, handled_by = case when p_handled then left(p_by, 80) end where id = p_id;
end $$;

create or replace function public.admin_meeting_delete(p_pass text, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  delete from meeting_requests where id = p_id;
end $$;

grant execute on function public.admin_meeting_requests(text, boolean)                to anon;
grant execute on function public.admin_meeting_handled(text, bigint, boolean, text)   to anon;
grant execute on function public.admin_meeting_delete(text, bigint)                   to anon;

-- Inbox badge: open meeting requests.
create or replace function public.admin_notes_count(p_pass text)
returns int
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return (select count(*) from meeting_requests where handled_at is null)::int;
end $$;
grant execute on function public.admin_notes_count(text) to anon;

-- ---------------------------------------------------------------------------
-- After running:
--   1. set the admin passphrase:       select set_admin_passphrase('replace-me');
--   2. set your ward's roll classes from the Leaders › Settings page, or directly:
--        select admin_set_roll_classes('replace-me', '[
--          {"key":"primary","label":"Primary","short":"Primary","orgTypeIds":[]},
--          {"key":"young_men","label":"Young Men","short":"YM","orgTypeIds":[]},
--          {"key":"young_women","label":"Young Women","short":"YW","orgTypeIds":[]},
--          {"key":"sunday_school","label":"Sunday School","short":"Sunday School","orgTypeIds":[]},
--          {"key":"priesthood_rs","label":"Priesthood / Relief Society","short":"Priesthood / RS","orgTypeIds":[]}
--        ]'::jsonb);
-- ---------------------------------------------------------------------------


-- MODULE: posts
-- Announcements as posts: one row per event / notice, ordered by when it happens, with an
-- optional flyer. Anyone can submit a post from the site (post.html); it sits in "pending"
-- until a leader approves it under Leaders › Announcements. Leaders' own posts publish at once.
-- Paste into the Supabase SQL editor and run once (safe to re-run). Requires notes.sql
-- (_check_admin) and inbox.sql (announcements, admin_notes_count).

-- ---------------------------------------------------------------------------
-- 1. Posts
-- ---------------------------------------------------------------------------
create table if not exists public.posts (
  id            bigserial primary key,
  title         text not null,
  details       text not null default '',
  event_date    date,                      -- null = a general notice (shown for 30 days)
  start_time    time,
  end_time      time,
  location      text,
  link          text,                      -- sign-up / more-info URL
  flyer_url     text,                      -- public URL in the "flyers" storage bucket
  submitted_name    text,
  submitted_contact text,                  -- email or phone, so a leader can follow up
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  source        text not null default 'public' check (source in ('public', 'leaders')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  reviewed_at   timestamptz,
  reviewed_by   text
);
create index if not exists posts_status_date on public.posts (status, event_date);
alter table public.posts enable row level security;
revoke all on public.posts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Public: what the home page shows — approved posts whose day hasn't passed
--    (undated notices stay up for 30 days), soonest first, undated last.
-- ---------------------------------------------------------------------------
create or replace function public.posts_public()
returns table (id bigint, title text, details text, event_date date, start_time time, end_time time, location text, link text, flyer_url text, created_at timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.title, p.details, p.event_date, p.start_time, p.end_time, p.location, p.link, p.flyer_url, p.created_at
  from posts p
  where p.status = 'approved'
    and ((p.event_date is not null and p.event_date >= (now() at time zone 'America/New_York')::date)
      or (p.event_date is null and p.created_at > now() - interval '30 days'))
  order by p.event_date asc nulls last, p.start_time asc nulls last, p.created_at desc
$$;
grant execute on function public.posts_public() to anon;

-- ---------------------------------------------------------------------------
-- 3. Public: submit a post for approval. Light rate limit; the honeypot (p_website) must be
--    empty — bots fill every field.
-- ---------------------------------------------------------------------------
create or replace function public.submit_post(p_title text, p_details text, p_event_date date, p_start_time time, p_end_time time,
  p_location text, p_link text, p_flyer_url text, p_name text, p_contact text, p_website text default '')
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_title text; v_name text; v_contact text; v_link text; v_flyer text;
begin
  if coalesce(p_website, '') <> '' then return 0; end if;   -- honeypot: pretend it worked
  v_title := regexp_replace(btrim(coalesce(p_title, '')), '\s+', ' ', 'g');
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_contact := btrim(coalesce(p_contact, ''));
  v_link := btrim(coalesce(p_link, ''));
  v_flyer := btrim(coalesce(p_flyer_url, ''));
  if length(v_title) < 3 or length(v_title) > 120 then raise exception 'Please give the post a title (3–120 characters)'; end if;
  if length(coalesce(p_details, '')) > 3000 then raise exception 'Please keep the details under 3000 characters'; end if;
  if length(coalesce(p_location, '')) > 200 then raise exception 'Location is too long'; end if;
  if v_link <> '' and (v_link !~* '^https?://' or length(v_link) > 500) then raise exception 'The link must start with http:// or https://'; end if;
  if v_flyer <> '' and (v_flyer !~* '^https://' or length(v_flyer) > 500) then raise exception 'Bad flyer URL'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Please enter your name'; end if;
  if length(v_contact) < 5 or length(v_contact) > 120 then raise exception 'Please enter an email or phone number a leader can reach you at'; end if;
  if p_event_date is not null and p_event_date < (now() at time zone 'America/New_York')::date - 1 then raise exception 'That date has already passed'; end if;
  if p_start_time is not null and p_end_time is not null and p_end_time < p_start_time then raise exception 'The end time is before the start time'; end if;
  if (select count(*) from posts where source = 'public' and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many submissions right now — please try again in a little while';
  end if;
  insert into posts (title, details, event_date, start_time, end_time, location, link, flyer_url, submitted_name, submitted_contact, status, source)
  values (v_title, coalesce(p_details, ''), p_event_date, p_start_time, p_end_time, nullif(btrim(coalesce(p_location, '')), ''), nullif(v_link, ''), nullif(v_flyer, ''), v_name, v_contact, 'pending', 'public')
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.submit_post(text, text, date, time, time, text, text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Leaders
-- ---------------------------------------------------------------------------
-- Everything recent: pending first, then upcoming approved, then the rest (rejected / past, last 60 days).
create or replace function public.admin_posts(p_pass text)
returns setof public.posts
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from posts p
    where p.status = 'pending' or p.event_date >= (now() at time zone 'America/New_York')::date - 7 or p.created_at > now() - interval '60 days'
    order by (p.status = 'pending') desc, p.event_date asc nulls last, p.start_time asc nulls last, p.created_at desc;
end $$;

-- Add (p_id null) or edit a post. Leaders' new posts go straight to approved.
create or replace function public.admin_post_save(p_pass text, p_id bigint, p_title text, p_details text, p_event_date date, p_start_time time, p_end_time time,
  p_location text, p_link text, p_flyer_url text, p_by text default null)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_title text;
begin
  perform _check_admin(p_pass);
  v_title := regexp_replace(btrim(coalesce(p_title, '')), '\s+', ' ', 'g');
  if length(v_title) < 3 or length(v_title) > 120 then raise exception 'Please give the post a title (3–120 characters)'; end if;
  if length(coalesce(p_details, '')) > 3000 then raise exception 'Please keep the details under 3000 characters'; end if;
  if p_link is not null and btrim(p_link) <> '' and btrim(p_link) !~* '^https?://' then raise exception 'The link must start with http:// or https://'; end if;
  if p_id is null then
    insert into posts (title, details, event_date, start_time, end_time, location, link, flyer_url, submitted_name, status, source, reviewed_at, reviewed_by)
    values (v_title, coalesce(p_details, ''), p_event_date, p_start_time, p_end_time, nullif(btrim(coalesce(p_location, '')), ''), nullif(btrim(coalesce(p_link, '')), ''), nullif(btrim(coalesce(p_flyer_url, '')), ''), 'Leaders', 'approved', 'leaders', now(), left(p_by, 80))
    returning id into v_id;
  else
    update posts set title = v_title, details = coalesce(p_details, ''), event_date = p_event_date, start_time = p_start_time, end_time = p_end_time,
      location = nullif(btrim(coalesce(p_location, '')), ''), link = nullif(btrim(coalesce(p_link, '')), ''), flyer_url = nullif(btrim(coalesce(p_flyer_url, '')), ''), updated_at = now()
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'post not found'; end if;
  end if;
  return v_id;
end $$;

-- Approve / reject / put back to pending.
create or replace function public.admin_post_status(p_pass text, p_id bigint, p_status text, p_by text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  if p_status not in ('pending', 'approved', 'rejected') then raise exception 'bad status'; end if;
  update posts set status = p_status, reviewed_at = case when p_status = 'pending' then null else now() end, reviewed_by = case when p_status = 'pending' then null else left(p_by, 80) end, updated_at = now()
  where id = p_id;
end $$;

create or replace function public.admin_post_delete(p_pass text, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  delete from posts where id = p_id;
end $$;

-- Badge on the Announcements tab.
create or replace function public.admin_posts_pending_count(p_pass text)
returns int
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return (select count(*) from posts where status = 'pending')::int;
end $$;

grant execute on function public.admin_posts(text) to anon;
grant execute on function public.admin_post_save(text, bigint, text, text, date, time, time, text, text, text, text) to anon;
grant execute on function public.admin_post_status(text, bigint, text, text) to anon;
grant execute on function public.admin_post_delete(text, bigint) to anon;
grant execute on function public.admin_posts_pending_count(text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Flyers: a public storage bucket. Anyone can upload an image (JPEG/PNG/WebP, 3 MB) into
--    uploads/…; nobody can overwrite or delete through the public key. The site resizes
--    images in the browser before uploading, so most flyers land well under 500 KB.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('flyers', 'flyers', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "flyers public read" on storage.objects;
create policy "flyers public read" on storage.objects for select to anon, authenticated using (bucket_id = 'flyers');
drop policy if exists "flyers anon upload" on storage.objects;
create policy "flyers anon upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'flyers' and (storage.foldername(name))[1] = 'uploads');


-- MODULE: repeat
-- ---------------------------------------------------------------------------
-- Repeating posts (Institute every Tuesday, a monthly break-the-fast…) — run after posts.sql.
--
--   repeat       'weekly' | 'biweekly' | 'monthly' (same weekday of the month, e.g. 1st Tuesday) | null
--   repeat_until last day it repeats (optional)
--   repeat_show  how many upcoming occurrences the home page / email show at a time (1–4, default 2)
--   skip_dates   occurrences that are cancelled — the site shows them as cancelled, the .ics gets
--                an EXDATE, subscribers see them vanish
--   reminded_at  when "Text a reminder" last went to the ward text list (also in this file)
--
-- The post's event_date is the first occurrence. The site works out the upcoming dates itself
-- (posts.js occurrences()); the calendar files carry an RRULE (scripts/announcements.gs).
-- ---------------------------------------------------------------------------
alter table public.posts add column if not exists repeat text check (repeat in ('weekly', 'biweekly', 'monthly'));
alter table public.posts add column if not exists repeat_until date;
alter table public.posts add column if not exists repeat_show int not null default 2 check (repeat_show between 1 and 4);
alter table public.posts add column if not exists skip_dates date[] not null default '{}';
alter table public.posts add column if not exists reminded_at timestamptz;     -- last "Text a reminder" from the Leaders page

-- A series is live while it still has occurrences left. (Dropped first: the return type grows.)
drop function if exists public.posts_public();
create or replace function public.posts_public()
returns table (id bigint, title text, details text, event_date date, start_time time, end_time time, location text, link text, flyer_url text, created_at timestamptz,
  repeat text, repeat_until date, repeat_show int, skip_dates date[])
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.title, p.details, p.event_date, p.start_time, p.end_time, p.location, p.link, p.flyer_url, p.created_at,
    p.repeat, p.repeat_until, p.repeat_show, p.skip_dates
  from posts p
  where p.status = 'approved'
    and ((p.event_date is not null and (p.event_date >= (now() at time zone 'America/New_York')::date
                                        or (p.repeat is not null and (p.repeat_until is null or p.repeat_until >= (now() at time zone 'America/New_York')::date))))
      or (p.event_date is null and p.created_at > now() - interval '30 days'))
  order by p.event_date asc nulls last, p.start_time asc nulls last, p.created_at desc
$$;
grant execute on function public.posts_public() to anon;

-- Public submission: same as before plus the repeat fields (the old signature goes, or PostgREST
-- can't pick between the two).
drop function if exists public.submit_post(text, text, date, time, time, text, text, text, text, text, text);
create or replace function public.submit_post(p_title text, p_details text, p_event_date date, p_start_time time, p_end_time time,
  p_location text, p_link text, p_flyer_url text, p_name text, p_contact text, p_website text default '',
  p_repeat text default null, p_repeat_until date default null, p_repeat_show int default 2)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_title text; v_name text; v_contact text; v_link text; v_flyer text; v_repeat text;
begin
  if coalesce(p_website, '') <> '' then return 0; end if;   -- honeypot: pretend it worked
  v_title := regexp_replace(btrim(coalesce(p_title, '')), '\s+', ' ', 'g');
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_contact := btrim(coalesce(p_contact, ''));
  v_link := btrim(coalesce(p_link, ''));
  v_flyer := btrim(coalesce(p_flyer_url, ''));
  v_repeat := nullif(btrim(coalesce(p_repeat, '')), '');
  if length(v_title) < 3 or length(v_title) > 120 then raise exception 'Please give the post a title (3–120 characters)'; end if;
  if length(coalesce(p_details, '')) > 3000 then raise exception 'Please keep the details under 3000 characters'; end if;
  if length(coalesce(p_location, '')) > 200 then raise exception 'Location is too long'; end if;
  if v_link <> '' and (v_link !~* '^https?://' or length(v_link) > 500) then raise exception 'The link must start with http:// or https://'; end if;
  if v_flyer <> '' and (v_flyer !~* '^https://' or length(v_flyer) > 500) then raise exception 'Bad flyer URL'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Please enter your name'; end if;
  if length(v_contact) < 5 or length(v_contact) > 120 then raise exception 'Please enter an email or phone number a leader can reach you at'; end if;
  if p_event_date is not null and p_event_date < (now() at time zone 'America/New_York')::date - 1 and v_repeat is null then raise exception 'That date has already passed'; end if;
  if p_start_time is not null and p_end_time is not null and p_end_time < p_start_time then raise exception 'The end time is before the start time'; end if;
  if v_repeat is not null and v_repeat not in ('weekly', 'biweekly', 'monthly') then raise exception 'bad repeat'; end if;
  if v_repeat is not null and p_event_date is null then raise exception 'A repeating post needs a first date'; end if;
  if p_repeat_until is not null and p_event_date is not null and p_repeat_until < p_event_date then raise exception 'The last date is before the first one'; end if;
  if (select count(*) from posts where source = 'public' and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many submissions right now — please try again in a little while';
  end if;
  insert into posts (title, details, event_date, start_time, end_time, location, link, flyer_url, submitted_name, submitted_contact, status, source, repeat, repeat_until, repeat_show)
  values (v_title, coalesce(p_details, ''), p_event_date, p_start_time, p_end_time, nullif(btrim(coalesce(p_location, '')), ''), nullif(v_link, ''), nullif(v_flyer, ''), v_name, v_contact, 'pending', 'public',
    v_repeat, case when v_repeat is null then null else p_repeat_until end, least(4, greatest(1, coalesce(p_repeat_show, 2))))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.submit_post(text, text, date, time, time, text, text, text, text, text, text, text, date, int) to anon;

-- Leaders: add / edit, now with the repeat fields.
drop function if exists public.admin_post_save(text, bigint, text, text, date, time, time, text, text, text, text);
create or replace function public.admin_post_save(p_pass text, p_id bigint, p_title text, p_details text, p_event_date date, p_start_time time, p_end_time time,
  p_location text, p_link text, p_flyer_url text, p_by text default null,
  p_repeat text default null, p_repeat_until date default null, p_repeat_show int default 2)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_title text; v_repeat text;
begin
  perform _check_admin(p_pass);
  v_title := regexp_replace(btrim(coalesce(p_title, '')), '\s+', ' ', 'g');
  v_repeat := nullif(btrim(coalesce(p_repeat, '')), '');
  if length(v_title) < 3 or length(v_title) > 120 then raise exception 'Please give the post a title (3–120 characters)'; end if;
  if length(coalesce(p_details, '')) > 3000 then raise exception 'Please keep the details under 3000 characters'; end if;
  if p_link is not null and btrim(p_link) <> '' and btrim(p_link) !~* '^https?://' then raise exception 'The link must start with http:// or https://'; end if;
  if v_repeat is not null and v_repeat not in ('weekly', 'biweekly', 'monthly') then raise exception 'bad repeat'; end if;
  if v_repeat is not null and p_event_date is null then raise exception 'A repeating post needs a first date'; end if;
  if p_repeat_until is not null and p_event_date is not null and p_repeat_until < p_event_date then raise exception 'The last date is before the first one'; end if;
  if p_id is null then
    insert into posts (title, details, event_date, start_time, end_time, location, link, flyer_url, submitted_name, status, source, reviewed_at, reviewed_by, repeat, repeat_until, repeat_show)
    values (v_title, coalesce(p_details, ''), p_event_date, p_start_time, p_end_time, nullif(btrim(coalesce(p_location, '')), ''), nullif(btrim(coalesce(p_link, '')), ''), nullif(btrim(coalesce(p_flyer_url, '')), ''), 'Leaders', 'approved', 'leaders', now(), left(p_by, 80),
      v_repeat, case when v_repeat is null then null else p_repeat_until end, least(4, greatest(1, coalesce(p_repeat_show, 2))))
    returning id into v_id;
  else
    update posts set title = v_title, details = coalesce(p_details, ''), event_date = p_event_date, start_time = p_start_time, end_time = p_end_time,
      location = nullif(btrim(coalesce(p_location, '')), ''), link = nullif(btrim(coalesce(p_link, '')), ''), flyer_url = nullif(btrim(coalesce(p_flyer_url, '')), ''),
      repeat = v_repeat, repeat_until = case when v_repeat is null then null else p_repeat_until end, repeat_show = least(4, greatest(1, coalesce(p_repeat_show, 2))),
      skip_dates = case when v_repeat is null then '{}' else skip_dates end, updated_at = now()
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'post not found'; end if;
  end if;
  return v_id;
end $$;
grant execute on function public.admin_post_save(text, bigint, text, text, date, time, time, text, text, text, text, text, date, int) to anon;

-- Leaders' list: a series stays listed while it is still running, however long ago it was created.
create or replace function public.admin_posts(p_pass text)
returns setof public.posts
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from posts p
    where p.status = 'pending' or p.event_date >= (now() at time zone 'America/New_York')::date - 7 or p.created_at > now() - interval '60 days'
      or (p.repeat is not null and (p.repeat_until is null or p.repeat_until >= (now() at time zone 'America/New_York')::date - 7))
    order by (p.status = 'pending') desc, p.event_date asc nulls last, p.start_time asc nulls last, p.created_at desc;
end $$;

-- Cancel (or restore) one occurrence of a repeating post.
create or replace function public.admin_post_skip(p_pass text, p_id bigint, p_date date, p_skip boolean)
returns date[]
language plpgsql security definer set search_path = public, extensions as $$
declare v_dates date[];
begin
  perform _check_admin(p_pass);
  update posts set
    skip_dates = case when p_skip then (select array_agg(distinct d order by d) from unnest(array_append(skip_dates, p_date)) d)
                      else coalesce(array_remove(skip_dates, p_date), '{}') end,
    updated_at = now()
  where id = p_id returning skip_dates into v_dates;
  if v_dates is null then raise exception 'post not found'; end if;
  return v_dates;
end $$;
grant execute on function public.admin_post_skip(text, bigint, date, boolean) to anon;

-- The Leaders page's "Text a reminder" (a SimpleTexting campaign to the ward list, sent by the
-- Apps Script) records when it went out, so the card can say so and nobody sends it twice by accident.
create or replace function public.admin_post_reminded(p_pass text, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  update posts set reminded_at = now() where id = p_id;
end $$;
grant execute on function public.admin_post_reminded(text, bigint) to anon;


-- MODULE: bishop
-- ---------------------------------------------------------------------------
-- Bishop meeting requests → a text to the executive secretary / Bishop the moment one comes in.
-- Run after inbox.sql (safe to re-run).
--
-- bishop.html submits the request (submit_meeting_request) and then pokes the Apps Script web app
-- (action "bishop", just the request id — no secret, the page is public). The script, which holds
-- the Leaders passphrase, CLAIMS the request here: the claim only succeeds once, for a real request
-- from the last day, so a stray or repeated poke can never send a second text. The number it texts
-- is the site setting `bishop_notify_phone` (Leaders › Settings). syncMemberSheets sweeps for any
-- request that was never texted (the page's poke got lost) every 6 hours.
-- ---------------------------------------------------------------------------
alter table public.meeting_requests add column if not exists notified_at timestamptz;

-- p_claim = true: mark the request as being texted and return it — only if nobody has claimed it
-- yet and it is recent. Returns nothing the second time. p_claim = false: release it (the text
-- failed to send), so the next sweep tries again.
create or replace function public.admin_meeting_request_claim(p_pass text, p_id bigint, p_claim boolean default true)
returns setof public.meeting_requests
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  if p_claim then
    return query update meeting_requests set notified_at = now()
      where id = p_id and notified_at is null and created_at > now() - interval '2 days'
      returning *;
  else
    return query update meeting_requests set notified_at = null where id = p_id returning *;
  end if;
end $$;
grant execute on function public.admin_meeting_request_claim(text, bigint, boolean) to anon;

insert into public.settings (key, value) values
  ('bishop_notify_phone', '')     -- who gets the text: digits only; blank = no texts
on conflict (key) do nothing;


-- MODULE: meals
-- ---------------------------------------------------------------------------
-- Missionary meals: members pick a day to take the missionaries out to eat. Companionships
-- (Elders, Sisters, or however many of each the ward has — this can change at any time) are
-- configured on Leaders › Settings, not hardcoded here.
-- Run after schema.sql (safe to re-run).
--
--   missionary_meals   one row per meal: companionship key + date, who, their phone, the
--                      companion coming along (when a brother feeds sister missionaries),
--                      notes. One booked meal per companionship per day.
--   settings           meals_enabled (the switch), meals_days_ahead (how far out people can
--                      book, default 42), meals_companionships (a JSON array of companionship
--                      keys, e.g. ["elders","sisters_a","sisters_b"]), and per companionship
--                      (key k): meals_<k>_on, meals_<k>_label, meals_<k>_gender ('M' or 'F' —
--                      brothers or sisters), meals_<k>_area, meals_<k>_phone (the phone is only
--                      ever shown to someone who has just booked a meal)
--
-- Public: meals_public() (what's open) and meals_signup(...). Everything else needs the Leaders session.
-- ---------------------------------------------------------------------------
create table if not exists public.missionary_meals (
  id             bigserial primary key,
  companionship  text not null,          -- a key from the ward's 'meals_companionships' setting
  meal_date      date not null,
  name           text not null,
  gender         text not null check (gender in ('M', 'F')),
  phone          text not null,
  companion      text,                      -- someone coming along when a brother feeds sister missionaries
  notes          text,
  status         text not null default 'booked' check (status in ('booked', 'done', 'cancelled')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists missionary_meals_one_per_day on public.missionary_meals (companionship, meal_date) where status = 'booked';
alter table public.missionary_meals enable row level security;
revoke all on public.missionary_meals from anon, authenticated;

insert into public.settings (key, value) values
  ('meals_enabled', 'true'),
  ('meals_days_ahead', '42'),
  ('meals_companionships', '[]')
on conflict (key) do nothing;

-- The ward's configured companionships (key list) as jsonb.
create or replace function public._meals_companionships()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select value::jsonb from settings where key = 'meals_companionships'), '[]'::jsonb)
$$;

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------
-- The switch, how far out, the companionships (label + area + gender, never the phone), and
-- the booked days ahead with the volunteer as "First L.".
create or replace function public.meals_public()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  with s as (select key, value from settings where key like 'meals\_%'),
       comps as (select value as k, ordinality as ord from jsonb_array_elements_text(_meals_companionships()) with ordinality)
  select jsonb_build_object(
    'enabled', coalesce((select value from s where key = 'meals_enabled'), 'true') = 'true',
    'days_ahead', coalesce((select value from s where key = 'meals_days_ahead'), '42')::int,
    'companionships', (select coalesce(jsonb_agg(jsonb_build_object(
        'key', c.k, 'label', coalesce((select value from s where key = 'meals_' || c.k || '_label'), initcap(c.k)),
        'area', coalesce((select value from s where key = 'meals_' || c.k || '_area'), ''),
        'sisters', coalesce((select value from s where key = 'meals_' || c.k || '_gender'), 'F') = 'F') order by c.ord), '[]'::jsonb)
      from comps c
      where coalesce((select value from s where key = 'meals_' || c.k || '_on'), 'true') = 'true'),
    'booked', (select coalesce(jsonb_agg(jsonb_build_object('companionship', m.companionship, 'date', m.meal_date,
        'who', regexp_replace(btrim(m.name), '^(\S+)\s+(\S).*$', '\1 \2.')) order by m.meal_date), '[]'::jsonb)
      from missionary_meals m where m.status = 'booked' and m.meal_date >= (now() at time zone 'America/New_York')::date)
  );
$$;
grant execute on function public.meals_public() to anon;

-- Book a day. Returns the meal id and that companionship's phone number (to set up time and place).
create or replace function public.meals_signup(p_companionship text, p_date date, p_name text, p_gender text, p_phone text,
  p_companion text default null, p_notes text default null, p_website text default '')
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_name text; v_phone text; v_digits text; v_companion text; v_today date; v_ahead int; v_label text; v_comp_gender text;
begin
  if coalesce(p_website, '') <> '' then return jsonb_build_object('id', 0); end if;   -- honeypot: pretend it worked
  if coalesce((select value from settings where key = 'meals_enabled'), 'true') <> 'true' then raise exception 'Meal sign-ups are closed right now'; end if;
  if not exists (select 1 from jsonb_array_elements_text(_meals_companionships()) k where k = p_companionship) then raise exception 'Pick which missionaries'; end if;
  if coalesce((select value from settings where key = 'meals_' || p_companionship || '_on'), 'true') <> 'true' then raise exception 'Those missionaries aren''t taking meals right now'; end if;
  v_label := coalesce((select value from settings where key = 'meals_' || p_companionship || '_label'), initcap(p_companionship));
  v_comp_gender := coalesce((select value from settings where key = 'meals_' || p_companionship || '_gender'), 'F');
  v_today := (now() at time zone 'America/New_York')::date;
  v_ahead := coalesce((select value from settings where key = 'meals_days_ahead'), '42')::int;
  if p_date is null or p_date < v_today then raise exception 'Pick a day that hasn''t passed'; end if;
  if p_date > v_today + v_ahead then raise exception 'You can book up to % days ahead', v_ahead; end if;
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_phone := btrim(coalesce(p_phone, ''));
  v_digits := regexp_replace(v_phone, '\D', '', 'g');
  v_companion := nullif(regexp_replace(btrim(coalesce(p_companion, '')), '\s+', ' ', 'g'), '');
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Please enter your name'; end if;
  if p_gender not in ('M', 'F') then raise exception 'Brother or sister?'; end if;
  if length(v_digits) < 10 or length(v_phone) > 40 then raise exception 'Please enter a mobile number the missionaries can text'; end if;
  if p_gender = 'M' and v_comp_gender = 'F' and v_companion is null then
    raise exception 'A brother taking the % out needs someone else along — please add their name', v_label;
  end if;
  if length(coalesce(v_companion, '')) > 80 or length(coalesce(p_notes, '')) > 600 then raise exception 'Please keep it shorter'; end if;
  if (select count(*) from missionary_meals where created_at > now() - interval '1 hour') >= 40 then
    raise exception 'Too many sign-ups right now — please try again in a little while';
  end if;
  if exists (select 1 from missionary_meals where companionship = p_companionship and meal_date = p_date and status = 'booked') then
    raise exception 'Someone already has the % that day — pick another day', v_label;
  end if;
  insert into missionary_meals (companionship, meal_date, name, gender, phone, companion, notes)
  values (p_companionship, p_date, v_name, p_gender, v_phone, v_companion, nullif(btrim(coalesce(p_notes, '')), ''))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'label', v_label, 'phone', coalesce((select value from settings where key = 'meals_' || p_companionship || '_phone'), ''));
end $$;
grant execute on function public.meals_signup(text, date, text, text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Leaders
-- ---------------------------------------------------------------------------
create or replace function public.admin_meals(p_pass text, p_include_past boolean default false)
returns setof public.missionary_meals
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from missionary_meals m
    where p_include_past or m.meal_date >= (now() at time zone 'America/New_York')::date - 7
    order by m.meal_date, m.companionship;
end $$;

create or replace function public.admin_meal_status(p_pass text, p_id bigint, p_status text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  if p_status not in ('booked', 'done', 'cancelled') then raise exception 'bad status'; end if;
  update missionary_meals set status = p_status, updated_at = now() where id = p_id;
  if not found then raise exception 'not found'; end if;
end $$;

create or replace function public.admin_meal_delete(p_pass text, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  delete from missionary_meals where id = p_id;
end $$;

-- Add, rename or remove a companionship. p_key is created if new; passing p_remove drops it
-- (and its settings) rather than editing it. Existing bookings under a removed key are left
-- alone (they'll just show under a companionship no longer offered).
create or replace function public.admin_set_meal_companionship(p_pass text, p_key text, p_label text default null,
  p_gender text default 'F', p_area text default '', p_phone text default '', p_on boolean default true, p_remove boolean default false)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_list jsonb;
begin
  perform _check_admin(p_pass);
  if p_key is null or p_key !~ '^[a-z0-9_]{1,40}$' then raise exception 'key must be lowercase letters/numbers/underscore'; end if;
  v_list := _meals_companionships();
  if p_remove then
    v_list := (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(v_list) x where x <> p_key);
    insert into settings (key, value) values ('meals_companionships', v_list::text) on conflict (key) do update set value = excluded.value;
    delete from settings where key in ('meals_' || p_key || '_on', 'meals_' || p_key || '_label', 'meals_' || p_key || '_gender', 'meals_' || p_key || '_area', 'meals_' || p_key || '_phone');
    return;
  end if;
  if not exists (select 1 from jsonb_array_elements_text(v_list) x where x = p_key) then
    v_list := v_list || to_jsonb(p_key);
    insert into settings (key, value) values ('meals_companionships', v_list::text) on conflict (key) do update set value = excluded.value;
  end if;
  insert into settings (key, value) values ('meals_' || p_key || '_on', case when p_on then 'true' else 'false' end) on conflict (key) do update set value = excluded.value;
  insert into settings (key, value) values ('meals_' || p_key || '_label', coalesce(p_label, initcap(p_key))) on conflict (key) do update set value = excluded.value;
  insert into settings (key, value) values ('meals_' || p_key || '_gender', case when p_gender = 'M' then 'M' else 'F' end) on conflict (key) do update set value = excluded.value;
  insert into settings (key, value) values ('meals_' || p_key || '_area', coalesce(p_area, '')) on conflict (key) do update set value = excluded.value;
  insert into settings (key, value) values ('meals_' || p_key || '_phone', coalesce(p_phone, '')) on conflict (key) do update set value = excluded.value;
end $$;

grant execute on function public.admin_meals(text, boolean)                 to anon;
grant execute on function public.admin_meal_status(text, bigint, text)      to anon;
grant execute on function public.admin_meal_delete(text, bigint)            to anon;
grant execute on function public.admin_set_meal_companionship(text, text, text, text, text, text, boolean, boolean) to anon;


-- MODULE: keys
-- "The Keys" mini game (keys.html): a ward-wide high score board.
-- Paste into the Supabase SQL editor and run once (safe to re-run).

create table if not exists public.keys_scores (
  id         bigserial primary key,
  name       text not null check (length(name) between 1 and 20),
  score      int  not null check (score between 0 and 1000000),
  level      int  not null default 1 check (level between 1 and 999),
  created_at timestamptz not null default now()
);
alter table public.keys_scores enable row level security;
revoke all on public.keys_scores from anon, authenticated;

-- Public: add a score. Name is letters / numbers / spaces, up to 20 characters; a light
-- rate limit so nobody can flood the board.
create or replace function public.keys_submit(p_name text, p_score int, p_level int default 1)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_name text;
begin
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if length(v_name) < 1 or length(v_name) > 20 or v_name !~ '^[[:alnum:]][[:alnum:] ''.-]*$' then
    raise exception 'Name: letters, numbers and spaces, up to 20 characters';
  end if;
  if p_score is null or p_score < 0 or p_score > 1000000 then raise exception 'bad score'; end if;
  if (select count(*) from keys_scores where created_at > now() - interval '1 minute') >= 30 then
    raise exception 'The board is busy — try again in a minute';
  end if;
  insert into keys_scores (name, score, level) values (v_name, p_score, greatest(1, least(999, coalesce(p_level, 1))));
end $$;

-- Public: the top of the board.
create or replace function public.keys_top(p_limit int default 10)
returns table (id bigint, name text, score int, level int, played_at timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  select s.id, s.name, s.score, s.level, s.created_at
  from keys_scores s
  order by s.score desc, s.created_at asc
  limit least(greatest(coalesce(p_limit, 10), 1), 50)
$$;

-- Leaders: take a score off the board (a name that shouldn't be there).
create or replace function public.admin_keys_delete(p_pass text, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  delete from keys_scores where id = p_id;
end $$;

grant execute on function public.keys_submit(text, int, int) to anon;
grant execute on function public.keys_top(int)              to anon;
grant execute on function public.admin_keys_delete(text, bigint) to anon;


-- MODULE: sheets
-- Leadership Google Sheets ("members without callings", "new member form") mirrored into the
-- database so the Leaders page can show them per person and run the callings meeting.
-- Paste into the Supabase SQL editor and run once (safe to re-run).
-- The data is written by scripts/announcements.gs (syncMemberSheets) or by Claude on request;
-- it is only ever readable through the admin functions below.

create table if not exists public.sheets (
  key         text primary key,            -- 'callings' | 'callings_committees' | 'newmember'
  title       text,
  source_url  text,
  headers     jsonb not null default '[]',  -- ["NAME","LOCATION",…]
  rows        jsonb not null default '[]',  -- [["Aaron Besson","Acworth",…], …]  (strings, blanks as "")
  row_count   int  not null default 0,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
alter table public.sheets enable row level security;
revoke all on public.sheets from anon, authenticated;

-- Admin: replace a sheet wholesale (the sync always sends the full sheet).
create or replace function public.admin_replace_sheet(p_pass text, p_key text, p_title text, p_source_url text, p_headers jsonb, p_rows jsonb, p_by text default null)
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v int;
begin
  perform _check_admin(p_pass);
  if p_key !~ '^[a-z_]{2,40}$' then raise exception 'bad key'; end if;
  if jsonb_typeof(p_headers) <> 'array' or jsonb_typeof(p_rows) <> 'array' then raise exception 'headers and rows must be arrays'; end if;
  v := jsonb_array_length(p_rows);
  insert into sheets (key, title, source_url, headers, rows, row_count, updated_at, updated_by)
  values (p_key, p_title, p_source_url, p_headers, p_rows, v, now(), p_by)
  on conflict (key) do update
    set title = excluded.title, source_url = excluded.source_url, headers = excluded.headers,
        rows = excluded.rows, row_count = excluded.row_count, updated_at = now(), updated_by = excluded.updated_by;
  return v;
end $$;

-- Admin: every mirrored sheet.
create or replace function public.admin_sheets(p_pass text)
returns table (key text, title text, source_url text, headers jsonb, rows jsonb, row_count int, updated_at timestamptz, updated_by text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select s.key, s.title, s.source_url, s.headers, s.rows, s.row_count, s.updated_at, s.updated_by
    from sheets s order by s.key;
end $$;

-- Admin: recent check-ins for everyone (last N Sundays), so the meeting view can show attendance.
create or replace function public.admin_attendance_recent(p_pass text, p_weeks int default 8)
returns table (member_id uuid, meeting_date date, class text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select a.member_id, a.meeting_date, a.class from attendance a
    where a.meeting_date >= (now() at time zone 'America/New_York')::date - (7 * greatest(1, least(p_weeks, 52)))
    order by a.meeting_date desc;
end $$;

grant execute on function public.admin_replace_sheet(text, text, text, text, jsonb, jsonb, text) to anon;
grant execute on function public.admin_sheets(text) to anon;
grant execute on function public.admin_attendance_recent(text, int) to anon;


-- MODULE: edits
-- Leaders › Callings: edits made on the site to the "Members without Callings" Google Sheet.
-- Only the columns leaders update in meetings are editable (proposed calling, who texts, texted,
-- answer, sustained, other notes). Edits are saved here immediately, shown on the site at once,
-- and written into the Google Sheet by scripts/announcements.gs (syncMemberSheets) on its next
-- run — after which the sheet copy carries them and the row here is marked synced.
-- Paste into the Supabase SQL editor and run once (safe to re-run). Requires sheets.sql.

create table if not exists public.callings_edits (
  name        text primary key,            -- NAME exactly as on the sheet (or "First Last" for a new row)
  lcr_uuid    text,
  edits       jsonb not null default '{}', -- {"Proposed calling": "...", "texted": "Y", ...}
  updated_at  timestamptz not null default now(),
  updated_by  text,
  synced_at   timestamptz                  -- when the Apps Script wrote it into the sheet
);
alter table public.callings_edits enable row level security;
revoke all on public.callings_edits from anon, authenticated;

-- Admin: save (merge) an edit for one person. Unknown columns are rejected.
create or replace function public.admin_callings_edit(p_pass text, p_name text, p_lcr_uuid text, p_values jsonb, p_by text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_allowed text[] := array['Proposed calling','text assignment / calling','texted','answer','sustained','Other Notes'];
        v_key text; v_clean jsonb := '{}'; v_out jsonb;
begin
  perform _check_admin(p_pass);
  if p_name is null or length(btrim(p_name)) < 2 or length(p_name) > 80 then raise exception 'bad name'; end if;
  if jsonb_typeof(p_values) <> 'object' then raise exception 'values must be an object'; end if;
  for v_key in select jsonb_object_keys(p_values) loop
    if not (v_key = any(v_allowed)) then raise exception 'column % is not editable', v_key; end if;
    if jsonb_typeof(p_values -> v_key) <> 'string' then raise exception 'values must be strings'; end if;
    if length(p_values ->> v_key) > 500 then raise exception 'value too long'; end if;
    v_clean := v_clean || jsonb_build_object(v_key, btrim(p_values ->> v_key));
  end loop;
  insert into callings_edits (name, lcr_uuid, edits, updated_at, updated_by, synced_at)
  values (btrim(p_name), nullif(p_lcr_uuid, ''), v_clean, now(), p_by, null)
  on conflict (name) do update
    set edits = callings_edits.edits || excluded.edits,
        lcr_uuid = coalesce(excluded.lcr_uuid, callings_edits.lcr_uuid),
        updated_at = now(), updated_by = excluded.updated_by, synced_at = null
  returning edits into v_out;
  return v_out;
end $$;

-- Admin: every edit (the site overlays the pending ones on the sheet copy).
create or replace function public.admin_callings_edits(p_pass text)
returns table (name text, lcr_uuid text, edits jsonb, updated_at timestamptz, updated_by text, synced_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select e.name, e.lcr_uuid, e.edits, e.updated_at, e.updated_by, e.synced_at from callings_edits e order by e.updated_at desc;
end $$;

-- Admin (Apps Script): edits not yet written into the Google Sheet.
create or replace function public.admin_callings_pending(p_pass text)
returns table (name text, lcr_uuid text, edits jsonb, updated_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select e.name, e.lcr_uuid, e.edits, e.updated_at from callings_edits e where e.synced_at is null order by e.updated_at;
end $$;

-- Admin (Apps Script): mark edits as written into the sheet (only if not edited again since).
create or replace function public.admin_callings_mark_synced(p_pass text, p_names text[], p_as_of timestamptz default now())
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v int;
begin
  perform _check_admin(p_pass);
  update callings_edits set synced_at = now() where name = any(p_names) and updated_at <= p_as_of;
  get diagnostics v = row_count;
  return v;
end $$;

grant execute on function public.admin_callings_edit(text, text, text, jsonb, text) to anon;
grant execute on function public.admin_callings_edits(text) to anon;
grant execute on function public.admin_callings_pending(text) to anon;
grant execute on function public.admin_callings_mark_synced(text, text[], timestamptz) to anon;


-- MODULE: flags
-- Leaders › Callings, round 2: lets a sheet row be marked deleted (and undone) from the site,
-- instead of only from the Google Sheet directly.
-- Paste into the Supabase SQL editor and run once (safe to re-run). Requires edits.sql.

alter table public.callings_edits add column if not exists deleted boolean not null default false;

-- A value of null means "clear this cell on purpose"; a blank string is never written over
-- something already in the sheet (see writePendingEdits_).
create or replace function public.admin_callings_edit(p_pass text, p_name text, p_lcr_uuid text, p_values jsonb, p_by text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_allowed text[] := array['Proposed calling','text assignment / calling','texted','answer','sustained','Other Notes'];
        v_key text; v_clean jsonb := '{}'; v_out jsonb;
begin
  perform _check_admin(p_pass);
  if p_name is null or length(btrim(p_name)) < 2 or length(p_name) > 80 then raise exception 'bad name'; end if;
  if jsonb_typeof(p_values) <> 'object' then raise exception 'values must be an object'; end if;
  for v_key in select jsonb_object_keys(p_values) loop
    if not (v_key = any(v_allowed)) then raise exception 'column % is not editable', v_key; end if;
    if jsonb_typeof(p_values -> v_key) not in ('string', 'null') then raise exception 'values must be strings (or null to clear)'; end if;
    if length(p_values ->> v_key) > 500 then raise exception 'value too long'; end if;
    v_clean := v_clean || jsonb_build_object(v_key, btrim(p_values ->> v_key));
  end loop;
  insert into callings_edits (name, lcr_uuid, edits, updated_at, updated_by, synced_at, deleted)
  values (btrim(p_name), nullif(p_lcr_uuid, ''), v_clean, now(), p_by, null, false)
  on conflict (name) do update
    set edits = callings_edits.edits || excluded.edits,
        lcr_uuid = coalesce(excluded.lcr_uuid, callings_edits.lcr_uuid),
        deleted = false,
        updated_at = now(), updated_by = excluded.updated_by, synced_at = null
  returning edits into v_out;
  return v_out;
end $$;

-- Admin: mark a sheet row for deletion (or undo it). The Apps Script removes the row on its next run.
create or replace function public.admin_callings_delete(p_pass text, p_name text, p_delete boolean default true, p_by text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  if p_name is null or length(btrim(p_name)) < 2 then raise exception 'bad name'; end if;
  insert into callings_edits (name, edits, updated_at, updated_by, synced_at, deleted)
  values (btrim(p_name), '{}', now(), p_by, null, p_delete)
  on conflict (name) do update
    set deleted = excluded.deleted, updated_at = now(), updated_by = excluded.updated_by, synced_at = null;
end $$;

drop function if exists public.admin_callings_edits(text);
create function public.admin_callings_edits(p_pass text)
returns table (name text, lcr_uuid text, edits jsonb, updated_at timestamptz, updated_by text, synced_at timestamptz, deleted boolean)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select e.name, e.lcr_uuid, e.edits, e.updated_at, e.updated_by, e.synced_at, e.deleted from callings_edits e order by e.updated_at desc;
end $$;

drop function if exists public.admin_callings_pending(text);
create function public.admin_callings_pending(p_pass text)
returns table (name text, lcr_uuid text, edits jsonb, updated_at timestamptz, deleted boolean)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select e.name, e.lcr_uuid, e.edits, e.updated_at, e.deleted from callings_edits e where e.synced_at is null order by e.updated_at;
end $$;

grant execute on function public.admin_callings_edit(text, text, text, jsonb, text) to anon;
grant execute on function public.admin_callings_delete(text, text, boolean, text) to anon;
grant execute on function public.admin_callings_edits(text) to anon;
grant execute on function public.admin_callings_pending(text) to anon;


-- MODULE: addrow
-- Leaders › Callings: "Add to sheet" for people on LCR's no-calling report who have no row on the
-- Members without Callings sheet yet. The site pre-fills the intake columns from LCR and the
-- new member form, so those columns become writable too (only through this function, only by a
-- signed-in leader). Paste into the Supabase SQL editor and run once (safe to re-run).
-- Requires flags.sql.

create or replace function public.admin_callings_edit(p_pass text, p_name text, p_lcr_uuid text, p_values jsonb, p_by text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_allowed text[] := array[
          -- the meeting columns (Edit on a slide)
          'Proposed calling','text assignment / calling','texted','answer','sustained','Other Notes',
          -- the intake columns (pre-filled by "Add to sheet")
          'LOCATION','AGE','RECENT CONVERT (under yr)','CAR','LENGTH OF STAY','MISSION','PURPOSE IN ATL','HOBBIES','MUSIC'];
        v_key text; v_clean jsonb := '{}'; v_out jsonb;
begin
  perform _check_admin(p_pass);
  if p_name is null or length(btrim(p_name)) < 2 or length(p_name) > 80 then raise exception 'bad name'; end if;
  if jsonb_typeof(p_values) <> 'object' then raise exception 'values must be an object'; end if;
  for v_key in select jsonb_object_keys(p_values) loop
    if not (v_key = any(v_allowed)) then raise exception 'column % is not editable', v_key; end if;
    if jsonb_typeof(p_values -> v_key) not in ('string', 'null') then raise exception 'values must be strings (or null to clear)'; end if;
    if length(p_values ->> v_key) > 500 then raise exception 'value too long'; end if;
    v_clean := v_clean || jsonb_build_object(v_key, btrim(p_values ->> v_key));
  end loop;
  insert into callings_edits (name, lcr_uuid, edits, updated_at, updated_by, synced_at, deleted)
  values (btrim(p_name), nullif(p_lcr_uuid, ''), v_clean, now(), p_by, null, false)
  on conflict (name) do update
    set edits = callings_edits.edits || excluded.edits,
        lcr_uuid = coalesce(excluded.lcr_uuid, callings_edits.lcr_uuid),
        deleted = false,
        updated_at = now(), updated_by = excluded.updated_by, synced_at = null
  returning edits into v_out;
  return v_out;
end $$;

grant execute on function public.admin_callings_edit(text, text, text, jsonb, text) to anon;


-- MODULE: pipeline
-- ---------------------------------------------------------------------------
-- Callings in progress, for anyone on the members list (not just the members-without-callings
-- sheet): proposed calling (who contacts noted) → contacted → accepted (yes / no) → sustained → set apart.
-- Run after schema.sql (safe to re-run).
--
--   calling_pipeline   one row per calling being extended. status: open while it moves along,
--                      done once set apart, dropped when declined or withdrawn.
--
-- The steps happen in that order, so recording a later one fills in the earlier ones (marking
-- someone set apart also marks them sustained and accepted). Leaders › Members shows the open
-- row's current step and who contacts; Leaders › Overview lists who still needs sustaining and
-- who still needs setting apart.
-- ---------------------------------------------------------------------------
create table if not exists public.calling_pipeline (
  id            bigserial primary key,
  member_id     uuid references public.members (id) on delete set null,
  lcr_uuid      uuid,                        -- LCR person uuid, so the row follows a re-imported member
  name          text not null,               -- "First Last", as shown
  calling       text not null,               -- the proposed calling
  contact       text,                        -- who contacts / extends it
  contacted_at  date,                        -- they have been reached
  accepted      text check (accepted in ('yes', 'no')),
  accepted_at   date,
  sustained_at  date,
  set_apart_at  date,
  notes         text,
  status        text not null default 'open' check (status in ('open', 'done', 'dropped')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    text
);
create index if not exists calling_pipeline_member on public.calling_pipeline (member_id, status);
create index if not exists calling_pipeline_status on public.calling_pipeline (status, updated_at desc);
alter table public.calling_pipeline enable row level security;
revoke all on public.calling_pipeline from anon, authenticated;

-- Open rows, plus (p_include_closed) anything finished or dropped in the last 90 days.
create or replace function public.admin_pipeline(p_pass text, p_include_closed boolean default true)
returns setof public.calling_pipeline
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query select * from calling_pipeline p
    where p.status = 'open' or (p_include_closed and p.updated_at > now() - interval '90 days')
    order by (p.status = 'open') desc, p.updated_at desc;
end $$;

-- Create (p_id null) or update one row. Later steps fill in the earlier ones; status follows the
-- steps unless p_status says otherwise (dropped = declined or withdrawn; open = reopen).
create or replace function public.admin_pipeline_save(p_pass text, p_id bigint, p_member_id uuid, p_lcr_uuid uuid, p_name text, p_calling text,
  p_contact text default null, p_contacted_at date default null, p_accepted text default null, p_accepted_at date default null,
  p_sustained_at date default null, p_set_apart_at date default null, p_notes text default null, p_status text default null, p_by text default null)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_name text; v_calling text; v_accepted text; v_accepted_at date; v_contacted date; v_sustained date; v_set_apart date; v_status text;
begin
  perform _check_admin(p_pass);
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_calling := regexp_replace(btrim(coalesce(p_calling, '')), '\s+', ' ', 'g');
  if length(v_name) < 2 or length(v_name) > 120 then raise exception 'Whose calling is this?'; end if;
  if length(v_calling) < 2 or length(v_calling) > 120 then raise exception 'Please name the proposed calling'; end if;
  if p_accepted is not null and p_accepted not in ('yes', 'no') then raise exception 'accepted is yes or no'; end if;
  if p_status is not null and p_status not in ('open', 'done', 'dropped') then raise exception 'bad status'; end if;
  if length(coalesce(p_notes, '')) > 1000 then raise exception 'Please keep the notes under 1000 characters'; end if;
  -- the order: set apart ⇒ sustained ⇒ accepted ⇒ contacted
  v_set_apart := p_set_apart_at;
  v_sustained := coalesce(p_sustained_at, v_set_apart);
  v_accepted  := case when v_sustained is not null then 'yes' else p_accepted end;
  v_accepted_at := case when v_accepted is null then null else coalesce(p_accepted_at, v_sustained, current_date) end;
  v_contacted := coalesce(p_contacted_at, v_accepted_at);
  v_status := coalesce(p_status, case when v_set_apart is not null then 'done' when v_accepted = 'no' then 'dropped' else 'open' end);
  if p_id is null then
    insert into calling_pipeline (member_id, lcr_uuid, name, calling, contact, contacted_at, accepted, accepted_at, sustained_at, set_apart_at, notes, status, updated_by)
    values (p_member_id, p_lcr_uuid, v_name, v_calling, nullif(btrim(coalesce(p_contact, '')), ''), v_contacted, v_accepted, v_accepted_at, v_sustained, v_set_apart, nullif(btrim(coalesce(p_notes, '')), ''), v_status, left(p_by, 80))
    returning id into v_id;
  else
    update calling_pipeline set member_id = coalesce(p_member_id, member_id), lcr_uuid = coalesce(p_lcr_uuid, lcr_uuid), name = v_name, calling = v_calling,
      contact = nullif(btrim(coalesce(p_contact, '')), ''), contacted_at = v_contacted, accepted = v_accepted, accepted_at = v_accepted_at,
      sustained_at = v_sustained, set_apart_at = v_set_apart, notes = nullif(btrim(coalesce(p_notes, '')), ''), status = v_status,
      updated_at = now(), updated_by = left(p_by, 80)
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'not found'; end if;
  end if;
  return v_id;
end $$;

-- One step from the Overview: sustained today / set apart today (the date can be given).
create or replace function public.admin_pipeline_step(p_pass text, p_id bigint, p_step text, p_date date default current_date, p_by text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d date := coalesce(p_date, current_date);   -- an explicit null still means today
begin
  perform _check_admin(p_pass);
  if p_step = 'sustained' then
    update calling_pipeline set sustained_at = coalesce(sustained_at, d), accepted = 'yes', accepted_at = coalesce(accepted_at, d), contacted_at = coalesce(contacted_at, d),
      status = case when status = 'dropped' then 'open' else status end, updated_at = now(), updated_by = left(p_by, 80) where id = p_id;
  elsif p_step = 'set_apart' then
    update calling_pipeline set set_apart_at = coalesce(set_apart_at, d), sustained_at = coalesce(sustained_at, d), accepted = 'yes', accepted_at = coalesce(accepted_at, d), contacted_at = coalesce(contacted_at, d),
      status = 'done', updated_at = now(), updated_by = left(p_by, 80) where id = p_id;
  else raise exception 'bad step';
  end if;
  if not found then raise exception 'not found'; end if;
end $$;

create or replace function public.admin_pipeline_delete(p_pass text, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  delete from calling_pipeline where id = p_id;
end $$;

grant execute on function public.admin_pipeline(text, boolean)                                                                          to anon;
grant execute on function public.admin_pipeline_save(text, bigint, uuid, uuid, text, text, text, date, text, date, date, date, text, text, text) to anon;
grant execute on function public.admin_pipeline_step(text, bigint, text, date, text)                                                    to anon;
grant execute on function public.admin_pipeline_delete(text, bigint)                                                                    to anon;

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


-- Replace private-link cancellation with a phone-number lookup and cancellation flow.
create or replace function public._meal_phone(p_phone text) returns text
language sql immutable set search_path=pg_catalog as $$
 select case when length(digits)=11 and left(digits,1)='1' then substr(digits,2) else digits end
 from (select regexp_replace(coalesce(p_phone,''),'[^0-9]','','g') as digits) d
$$;
revoke all on function public._meal_phone(text) from public,anon,authenticated;
create index if not exists missionary_meals_phone_upcoming on public.missionary_meals(public._meal_phone(phone),meal_date) where status='booked';
create or replace function public.meals_find_by_phone(p_phone text)
returns table(id bigint,meal_date date)
language plpgsql security definer set search_path=public,extensions as $$
declare digits text:=_meal_phone(p_phone);
begin
 if length(digits)<10 or length(digits)>15 then raise exception 'Please enter the phone number used when signing up'; end if;
 return query select m.id,m.meal_date from missionary_meals m where m.status='booked' and m.meal_date >= (now() at time zone 'America/New_York')::date and _meal_phone(m.phone)=digits order by m.meal_date;
end $$;
create or replace function public.meals_cancel_by_phone(p_id bigint,p_phone text) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare digits text:=_meal_phone(p_phone); r missionary_meals;
begin
 if length(digits)<10 or length(digits)>15 then raise exception 'Please enter the phone number used when signing up'; end if;
 select * into r from missionary_meals m where m.id=p_id and _meal_phone(m.phone)=digits for update;
 if not found then raise exception 'No matching appointment was found for that phone number'; end if;
 if r.status='cancelled' then return; end if;
 if r.status<>'booked' or r.meal_date<(now() at time zone 'America/New_York')::date then raise exception 'This appointment can no longer be cancelled online. Contact a leader'; end if;
 update missionary_meals set status='cancelled',updated_at=now() where id=r.id;
end $$;
revoke all on function public.meals_find_by_phone(text),public.meals_cancel_by_phone(bigint,text) from public,anon,authenticated;
grant execute on function public.meals_find_by_phone(text),public.meals_cancel_by_phone(bigint,text) to anon;
revoke all on function public.meals_reservation(bigint,text),public.meals_cancel(bigint,text) from public,anon,authenticated;

create or replace function public.meals_book(p_date date,p_name text,p_phone text,p_notes text default null,p_website text default '') returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare k text; n text; ph text; v_id bigint; today date; ahead int;
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
 insert into missionary_meals(companionship,meal_date,name,gender,phone,notes)
 values(k,p_date,n,null,ph,nullif(btrim(coalesce(p_notes,'')),'')) returning id into v_id;
 return jsonb_build_object('id',v_id,'date',p_date);
end $$;

notify pgrst,'reload schema';


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
  if length(btrim(coalesce(n,'')))<2 or length(n)>120 then raise exception 'Enter each member’s full name, one per line'; end if;
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
declare slot declaration_slots; ids uuid[]; names text[]; booking uuid;
begin
 perform pg_advisory_xact_lock(742901,p_year);
 if p_public and not exists(select 1 from declaration_seasons where year=p_year and enabled) then raise exception 'Declaration sign-ups are closed'; end if;
 if coalesce(cardinality(p_members),0)<1 or cardinality(p_members)>20 then raise exception 'Choose between 1 and 20 members'; end if;
 select array_agg(distinct value) into ids from unnest(p_members) as value;
 if (select count(*) from declaration_members where year=p_year and id=any(ids))<>cardinality(ids) then raise exception 'A member is not on this year’s list'; end if;
 if (p_public or coalesce(p_phone,'')<>'') and (length(_meal_phone(p_phone))<10 or length(_meal_phone(p_phone))>15) then raise exception 'Enter a valid phone number'; end if;
 if length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>200 or length(coalesce(p_note,''))>1000 then raise exception 'A contact field or note is too long'; end if;
 select * into slot from declaration_slots where id=p_slot and year=p_year and active for update;
 if not found or slot.starts_at<=now() then raise exception 'That slot is no longer available'; end if;
 if exists(select 1 from declaration_bookings where slot_id=p_slot and status='booked') then raise exception 'That slot has just been taken. Choose another time'; end if;
 if exists(select 1 from declaration_members m join declaration_bookings b on b.id=m.booking_id and b.status='booked' where m.id=any(ids)) then raise exception 'A selected member already has a declaration appointment. Ask the executive secretary to change it'; end if;
 select array_agg(m.full_name order by m.full_name) into names from declaration_members m where m.id=any(ids);
 insert into declaration_bookings(year,slot_id,member_ids,names,phone,email,note) values(p_year,p_slot,ids,names,btrim(coalesce(p_phone,'')),btrim(coalesce(p_email,'')),btrim(coalesce(p_note,''))) returning id into booking;
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
declare y int; ids uuid[];
begin
 if coalesce(p_website,'')<>'' then raise exception 'Unable to submit request'; end if;
 select year into y from declaration_seasons where enabled;
 if y is null then raise exception 'Declaration sign-ups are closed'; end if;
 if length(_meal_phone(p_phone))<10 or length(_meal_phone(p_phone))>15 or length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>200 or length(coalesce(p_note,''))>1000 then raise exception 'Enter a valid phone number and keep notes under 1000 characters'; end if;
 perform pg_advisory_xact_lock(742901,y);
 if (select count(*) from declaration_contact_requests where year=y and created_at>now()-interval '1 hour')>=100 then raise exception 'Too many requests right now. Try again later'; end if;
 ids:=_decl_resolve(y,p_names,p_phone,p_email,false);
 if exists(select 1 from declaration_contact_requests r where r.year=y and not r.resolved and _meal_phone(r.phone)=_meal_phone(p_phone) and r.names=p_names) then return; end if;
 insert into declaration_contact_requests(year,names,member_ids,phone,email,note) values(y,p_names,ids,btrim(p_phone),btrim(coalesce(p_email,'')),btrim(coalesce(p_note,'')));
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


-- Keep automatic completion current even while no one has the site open.
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;
select cron.schedule('ward-declaration-completions','* * * * *','select public._decl_refresh(year) from public.declaration_seasons;');


-- Preserve only explicit public API grants. Internal helpers and passphrase setup
-- are callable by the database owner, not by anonymous website visitors.
revoke create on schema public from public, anon, authenticated;
grant usage on schema public to anon, authenticated;
do $hardening$
declare f record;
begin
  for f in select p.oid::regprocedure as signature, p.proname
           from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname = any(array['_check_admin', '_meals_companionships', '_valid_class', '_window_open', 'admin_announcements_history', 'admin_attendance', 'admin_attendance_recent', 'admin_callings_delete', 'admin_callings_edit', 'admin_callings_edits', 'admin_callings_mark_synced', 'admin_callings_pending', 'admin_get_settings', 'admin_guests', 'admin_keys_delete', 'admin_login', 'admin_logout', 'admin_mark_guests_synced', 'admin_mark_synced', 'admin_meal_delete', 'admin_meal_status', 'admin_meals', 'admin_meeting_dates', 'admin_meeting_delete', 'admin_meeting_handled', 'admin_meeting_request_claim', 'admin_meeting_requests', 'admin_members', 'admin_notes_count', 'admin_pipeline', 'admin_pipeline_delete', 'admin_pipeline_save', 'admin_pipeline_step', 'admin_post_delete', 'admin_post_reminded', 'admin_post_save', 'admin_post_skip', 'admin_post_status', 'admin_posts', 'admin_posts_pending_count', 'admin_publish_announcements', 'admin_remove_guest', 'admin_replace_sheet', 'admin_set_attendance', 'admin_set_meal_companionship', 'admin_set_member_active', 'admin_set_roll_classes', 'admin_set_setting', 'admin_sheets', 'admin_update_announcements', 'admin_upsert_members', 'check_in', 'check_in_guest', 'check_out', 'checked_in', 'current_announcements', 'current_meeting_date', 'guests_checked_in', 'keys_submit', 'keys_top', 'meals_public', 'meals_signup', 'posts_public', 'roll_classes', 'roll_members', 'roll_windows', 'set_admin_passphrase', 'site_settings', 'submit_meeting_request', 'submit_post']::text[])
  loop
    execute format('revoke execute on function %s from public, authenticated', f.signature);
    if left(f.proname, 1) = '_' or f.proname = 'set_admin_passphrase' then
      execute format('revoke execute on function %s from anon', f.signature);
    end if;
  end loop;
end
$hardening$;
notify pgrst, 'reload schema';
commit;

-- NEXT: In a new SQL Editor query, choose your own leader passphrase:
-- select public.set_admin_passphrase('YOUR OWN LONG PASSPHRASE');
-- Keep it private; it is not a Supabase account password.
-- Then sign in at the Leaders page on your ward site

-- Leader-only manual roster maintenance; scoped to one declaration year.
create or replace function public.admin_declarations_add_member(p_pass text,p_year int,p_name text,p_phone text default '',p_email text default '',p_household text default '',p_source_id text default '') returns uuid
language plpgsql security definer set search_path=public,extensions as $$
declare v_key text; v_id uuid;
begin
 perform _check_admin(p_pass);
 if p_year is null or p_year<2020 or p_year>2100 then raise exception 'Choose a year'; end if;
 if length(btrim(coalesce(p_name,'')))<2 or length(btrim(p_name))>120 then raise exception 'Enter a member name of 2 to 120 characters'; end if;
 if length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>200 or length(coalesce(p_household,''))>120 or length(coalesce(p_source_id,''))>120 then raise exception 'A contact field is too long'; end if;
 perform pg_advisory_xact_lock(742901,p_year);
 insert into declaration_seasons(year) values(p_year) on conflict do nothing;
 v_key:=case when btrim(coalesce(p_source_id,''))<>'' then 'id:'||btrim(p_source_id) else 'name:'||_decl_name(p_name) end;
 if exists(select 1 from declaration_members where year=p_year and (source_key=v_key or (btrim(coalesce(p_source_id,''))='' and _decl_name(full_name)=_decl_name(p_name)))) then raise exception 'This member is already on this year’s list. For different people with the same name, enter a distinct member ID'; end if;
 insert into declaration_members(year,source_key,full_name,phone,email,household) values(p_year,v_key,btrim(p_name),btrim(coalesce(p_phone,'')),btrim(coalesce(p_email,'')),btrim(coalesce(p_household,''))) returning id into v_id;
 return v_id;
end $$;
create or replace function public.admin_declarations_remove_member(p_pass text,p_id uuid) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare v_member declaration_members;
begin
 perform _check_admin(p_pass);
 select * into v_member from declaration_members where id=p_id;
 if not found then raise exception 'Member not found'; end if;
 perform pg_advisory_xact_lock(742901,v_member.year);
 -- A shared appointment stays booked for the remaining people. A sole appointment reopens.
 update declaration_bookings b set member_ids=array_remove(b.member_ids,p_id),
 names=coalesce((select array_agg(m.full_name order by m.full_name) from declaration_members m where m.id=any(b.member_ids) and m.id<>p_id),'{}'::text[]),
 status=case when cardinality(array_remove(b.member_ids,p_id))=0 then 'cancelled' else b.status end
 where p_id=any(b.member_ids);
 update declaration_contact_requests r set member_ids=array_remove(r.member_ids,p_id),
 names=coalesce((select array_agg(n) from unnest(r.names) n where _decl_name(n)<>_decl_name(v_member.full_name)),'{}'::text[]),
 resolved=case when not exists(select 1 from unnest(r.names) n where _decl_name(n)<>_decl_name(v_member.full_name)) and cardinality(array_remove(r.member_ids,p_id))=0 then true else r.resolved end
 where p_id=any(r.member_ids);
 delete from declaration_members where id=p_id;
end $$;
revoke all on function public.admin_declarations_add_member(text,int,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.admin_declarations_remove_member(text,uuid) from public,anon,authenticated;
grant execute on function public.admin_declarations_add_member(text,int,text,text,text,text,text) to anon;
grant execute on function public.admin_declarations_remove_member(text,uuid) to anon;
notify pgrst,'reload schema';

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

notify pgrst,'reload schema';

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

-- Optional community sign-ups and missionary posts
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
create or replace function public.admin_ward_extra_save(p_pass text,p_id bigint,p_kind text,p_title text,p_detail text,p_day date,p_capacity int,p_email text,p_photo text,p_state text)
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
create or replace function public.site_settings()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'ward_name', coalesce((select value from public.settings where key = 'ward_name'), ''),
    'ward_email', coalesce((select value from public.settings where key = 'ward_email'), ''),
    'roll_home_visible', coalesce((select value <> 'false' from public.settings where key = 'roll_home_visible'), true)
  )
$$;
grant execute on function public.site_settings() to anon;

alter table public.ward_extra
  add column scripture_text text not null default '' check (length(scripture_text) <= 2000),
  add column scripture_reference text not null default '' check (length(scripture_reference) <= 120);

create function public.admin_missionary_profile_save(
 p_pass text, p_id bigint, p_title text, p_mission text, p_email text, p_photo text,
 p_scripture_text text, p_scripture_reference text
) returns void language plpgsql security definer set search_path = '' as $$
begin
 perform public._check_admin(p_pass);
 if btrim(coalesce(p_mission,'')) = '' then raise exception 'Enter the mission name.'; end if;
 if btrim(coalesce(p_email,'')) <> '' and btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
   raise exception 'Enter a valid missionary email address, or leave it blank.';
 end if;
 if p_id is null then
   insert into public.ward_extra(kind,title,detail,email,photo,state,scripture_text,scripture_reference)
   values('missionary',btrim(p_title),btrim(p_mission),btrim(coalesce(p_email,'')),coalesce(p_photo,''),'live',
          btrim(coalesce(p_scripture_text,'')),btrim(coalesce(p_scripture_reference,'')));
 else
   update public.ward_extra set title=btrim(p_title),detail=btrim(p_mission),
     email=btrim(coalesce(p_email,'')),photo=coalesce(p_photo,photo),state='live',
     scripture_text=btrim(coalesce(p_scripture_text,'')),scripture_reference=btrim(coalesce(p_scripture_reference,''))
   where id=p_id and kind='missionary';
   if not found then raise exception 'This missionary profile could not be found.'; end if;
 end if;
end $$;
revoke all on function public.admin_missionary_profile_save(text,bigint,text,text,text,text,text,text) from public;
grant execute on function public.admin_missionary_profile_save(text,bigint,text,text,text,text,text,text) to anon;

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

create function public.admin_missionary_weekly_email_count(p_pass text)
returns bigint language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 return (select count(*) from public.missionary_weekly_email);
end $$;
revoke all on function public.admin_missionary_weekly_email_count(text) from public;
grant execute on function public.admin_missionary_weekly_email_count(text) to anon;

create function public.admin_ward_signup_pending_count(p_pass text)
returns bigint language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 return (select count(*) from public.ward_extra where kind='signup' and state='pending');
end $$;
revoke all on function public.admin_ward_signup_pending_count(text) from public;
grant execute on function public.admin_ward_signup_pending_count(text) to anon;

alter table public.calling_pipeline add column if not exists release_from text;
create or replace function public.admin_pipeline_save_release(p_pass text, p_id bigint, p_member_id uuid, p_lcr_uuid uuid, p_name text, p_calling text, p_release_from text,
  p_contact text default null, p_contacted_at date default null, p_accepted text default null, p_accepted_at date default null,
  p_sustained_at date default null, p_set_apart_at date default null, p_notes text default null, p_status text default null, p_by text default null)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_name text; v_calling text; v_release text; v_accepted text; v_accepted_at date; v_contacted date; v_sustained date; v_set_apart date; v_status text;
begin
  perform _check_admin(p_pass);
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_calling := regexp_replace(btrim(coalesce(p_calling, '')), '\s+', ' ', 'g');
  if length(v_name) < 2 or length(v_name) > 120 then raise exception 'Whose calling is this?'; end if;
  v_release := btrim(coalesce(p_release_from,''));
  if length(v_calling) > 120 or length(v_release) > 120 or
     length(v_calling) = 1 or length(v_release) = 1 or
     (v_calling = '' and v_release = '') then raise exception 'Enter a proposed calling or a calling to release'; end if;
  if v_calling = '' then
    p_sustained_at := null; p_set_apart_at := null;
  end if;
  if p_accepted is not null and p_accepted not in ('yes', 'no') then raise exception 'accepted is yes or no'; end if;
  if p_status is not null and p_status not in ('open', 'done', 'dropped') then raise exception 'bad status'; end if;
  if length(coalesce(p_notes, '')) > 1000 then raise exception 'Please keep the notes under 1000 characters'; end if;
  -- the order: set apart ⇒ sustained ⇒ accepted ⇒ contacted
  v_set_apart := p_set_apart_at;
  v_sustained := coalesce(p_sustained_at, v_set_apart);
  v_accepted  := case when v_sustained is not null then 'yes' else p_accepted end;
  v_accepted_at := case when v_accepted is null then null else coalesce(p_accepted_at, v_sustained, current_date) end;
  v_contacted := coalesce(p_contacted_at, v_accepted_at);
  v_status := coalesce(p_status, case when v_set_apart is not null then 'done' when v_accepted = 'no' then 'dropped' else 'open' end);
  if p_id is null then
    insert into calling_pipeline (member_id, lcr_uuid, name, calling, release_from, contact, contacted_at, accepted, accepted_at, sustained_at, set_apart_at, notes, status, updated_by)
    values (p_member_id, p_lcr_uuid, v_name, v_calling, nullif(v_release,''), nullif(btrim(coalesce(p_contact, '')), ''), v_contacted, v_accepted, v_accepted_at, v_sustained, v_set_apart, nullif(btrim(coalesce(p_notes, '')), ''), v_status, left(p_by, 80))
    returning id into v_id;
  else
    update calling_pipeline set member_id = coalesce(p_member_id, member_id), lcr_uuid = coalesce(p_lcr_uuid, lcr_uuid), name = v_name, calling = v_calling, release_from = nullif(v_release,''),
      contact = nullif(btrim(coalesce(p_contact, '')), ''), contacted_at = v_contacted, accepted = v_accepted, accepted_at = v_accepted_at,
      sustained_at = v_sustained, set_apart_at = v_set_apart, notes = nullif(btrim(coalesce(p_notes, '')), ''), status = v_status,
      updated_at = now(), updated_by = left(p_by, 80)
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'not found'; end if;
  end if;
  return v_id;
end $$;

revoke all on function public.admin_pipeline_save_release(text,bigint,uuid,uuid,text,text,text,text,date,text,date,date,date,text,text,text) from public;
grant execute on function public.admin_pipeline_save_release(text,bigint,uuid,uuid,text,text,text,text,date,text,date,date,date,text,text,text) to anon;

alter table public.calling_pipeline add column if not exists imported_roster boolean not null default false;
create or replace function public.admin_pipeline_save_release(p_pass text, p_id bigint, p_member_id uuid, p_lcr_uuid uuid, p_name text, p_calling text, p_release_from text,
  p_contact text default null, p_contacted_at date default null, p_accepted text default null, p_accepted_at date default null,
  p_sustained_at date default null, p_set_apart_at date default null, p_notes text default null, p_status text default null, p_by text default null)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_name text; v_calling text; v_release text; v_accepted text; v_accepted_at date; v_contacted date; v_sustained date; v_set_apart date; v_status text;
begin
  perform _check_admin(p_pass);
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_calling := regexp_replace(btrim(coalesce(p_calling, '')), '\s+', ' ', 'g');
  if length(v_name) < 2 or length(v_name) > 120 then raise exception 'Whose calling is this?'; end if;
  v_release := btrim(coalesce(p_release_from,''));
  if length(v_calling) > 120 or length(v_release) > 120 or
     length(v_calling) = 1 or length(v_release) = 1 or
     (v_calling = '' and v_release = '') then raise exception 'Enter a proposed calling or a calling to release'; end if;
  if v_calling = '' then
    p_sustained_at := null; p_set_apart_at := null;
  end if;
  if p_accepted is not null and p_accepted not in ('yes', 'no') then raise exception 'accepted is yes or no'; end if;
  if p_status is not null and p_status not in ('open', 'done', 'dropped') then raise exception 'bad status'; end if;
  if length(coalesce(p_notes, '')) > 1000 then raise exception 'Please keep the notes under 1000 characters'; end if;
  -- the order: set apart ⇒ sustained ⇒ accepted ⇒ contacted
  v_set_apart := p_set_apart_at;
  v_sustained := coalesce(p_sustained_at, v_set_apart);
  v_accepted  := case when v_sustained is not null then 'yes' else p_accepted end;
  v_accepted_at := case when v_accepted is null then null else coalesce(p_accepted_at, v_sustained, current_date) end;
  v_contacted := coalesce(p_contacted_at, v_accepted_at);
  v_status := coalesce(p_status, case when v_set_apart is not null then 'done' when v_accepted = 'no' then 'dropped' else 'open' end);
  if p_id is null then
    insert into calling_pipeline (member_id, lcr_uuid, name, calling, release_from, contact, contacted_at, accepted, accepted_at, sustained_at, set_apart_at, notes, status, updated_by, imported_roster)
    values (p_member_id, p_lcr_uuid, v_name, v_calling, nullif(v_release,''), nullif(btrim(coalesce(p_contact, '')), ''), v_contacted, v_accepted, v_accepted_at, v_sustained, v_set_apart, nullif(btrim(coalesce(p_notes, '')), ''), v_status, left(p_by, 80), coalesce(p_by = 'lcr-roster-import', false))
    returning id into v_id;
  else
    update calling_pipeline set member_id = coalesce(p_member_id, member_id), lcr_uuid = coalesce(p_lcr_uuid, lcr_uuid), name = v_name, calling = v_calling, release_from = nullif(v_release,''),
      contact = nullif(btrim(coalesce(p_contact, '')), ''), contacted_at = v_contacted, accepted = v_accepted, accepted_at = v_accepted_at,
      sustained_at = v_sustained, set_apart_at = v_set_apart, notes = nullif(btrim(coalesce(p_notes, '')), ''), status = v_status,
      updated_at = now(), updated_by = left(p_by, 80)
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'not found'; end if;
  end if;
  return v_id;
end $$;

revoke all on function public.admin_pipeline_save_release(text,bigint,uuid,uuid,text,text,text,text,date,text,date,date,date,text,text,text) from public;
grant execute on function public.admin_pipeline_save_release(text,bigint,uuid,uuid,text,text,text,text,date,text,date,date,date,text,text,text) to anon;

create or replace function public.admin_clear_lcr_extension_data(p_pass text) returns void
language plpgsql security definer set search_path='' as $$
begin
  perform public._check_admin(p_pass);
  delete from public.calling_pipeline where imported_roster;
  delete from public.sheets
    where (key in ('lcr_sacrament','lcr_moved_in','lcr_converts','lcr_test_members','lcr_without_calling') and updated_by = 'LCR Overview test extension')
       or (key = 'lcr_extension_test_summary' and updated_by = 'LCR test extension');
end $$;
revoke all on function public.admin_clear_lcr_extension_data(text) from public;
grant execute on function public.admin_clear_lcr_extension_data(text) to anon;
-- Keep the existing class keys so historical attendance and check-in links still work.
create or replace function public.roll_classes()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_agg(jsonb_build_object(
    'key', c.key, 'label', c.label, 'short', c.short, 'slot', c.slot,
    'enabled', coalesce(s.value <> 'false', true)
  ) order by c.slot)
  from (values
    ('sunday_school', 'Sunday School', 'Sunday School', 1),
    ('priesthood___relief_society', 'Organization Classes', 'Organization', 2)
  ) as c(key,label,short,slot)
  left join public.settings s on s.key = 'roll_enabled_' || c.key
$$;

create or replace function public._window_open(p_class text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v text; v_day int; v_now timestamp; v_t time;
begin
  if coalesce((select value from public.settings where key = 'roll_enabled_' || p_class), 'true') = 'false' then return false; end if;
  if coalesce((select value from public.settings where key = 'roll_enforce_window'), 'true') <> 'true' then return true; end if;
  select value into v from public.settings where key = 'window_' || p_class;
  if v is null then return true; end if;
  v_day := coalesce((select value from public.settings where key = 'window_day'), '0')::int;
  v_now := now() at time zone 'America/New_York';
  v_t := v_now::time;
  return extract(dow from v_now)::int = v_day
    and v_t >= split_part(v, '-', 1)::time and v_t < split_part(v, '-', 2)::time;
end $$;

create or replace function public.admin_save_roll_slots(
  p_pass text, p_day integer, p_enforce boolean, p_school_enabled boolean,
  p_school_start time, p_school_end time, p_org_enabled boolean, p_org_start time, p_org_end time
)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_admin(p_pass);
  if p_day is null or p_day not between 0 and 6 or p_enforce is null
    or p_school_enabled is null or p_org_enabled is null then raise exception 'Invalid check-in settings'; end if;
  if (p_school_start is null) <> (p_school_end is null) or p_school_start >= p_school_end
    or (p_org_start is null) <> (p_org_end is null) or p_org_start >= p_org_end then
    raise exception 'Enter both times, with closing later than opening, or leave both blank';
  end if;
  insert into public.settings(key,value) values
    ('window_day',p_day::text), ('roll_enforce_window',p_enforce::text),
    ('roll_enabled_sunday_school',p_school_enabled::text),
    ('roll_enabled_priesthood___relief_society',p_org_enabled::text)
  on conflict (key) do update set value=excluded.value;
  delete from public.settings where
    (key='window_sunday_school' and p_school_start is null) or
    (key='window_priesthood___relief_society' and p_org_start is null);
  insert into public.settings(key,value)
    select v.key, left(v.start_at::text,5)||'-'||left(v.end_at::text,5)
    from (values ('window_sunday_school',p_school_start,p_school_end),
                 ('window_priesthood___relief_society',p_org_start,p_org_end)) v(key,start_at,end_at)
    where v.start_at is not null
  on conflict (key) do update set value=excluded.value;
end $$;
revoke all on function public.admin_save_roll_slots(text,integer,boolean,boolean,time,time,boolean,time,time) from public;
grant execute on function public.admin_save_roll_slots(text,integer,boolean,boolean,time,time,boolean,time,time) to anon;
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
-- Write-only public attendance check-in. Membership matches are never returned.
create or replace function public.check_in_by_name(p_date date, p_class text, p_name text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  entered text := regexp_replace(btrim(replace(coalesce(p_name, ''), '’', '''')), '\s+', ' ', 'g');
  name_key text := lower(entered);
  native_ids uuid[];
  roster_ids uuid[];
  roster_id uuid;
  person record;
  target uuid;
begin
  if p_class is null or not public._valid_class(p_class) then raise exception 'Choose a valid class'; end if;
  if not public._window_open(p_class) then raise exception 'Check-in is closed right now'; end if;
  if p_date is distinct from public.current_meeting_date() then raise exception 'Check-in is only open for the current meeting'; end if;
  if length(entered) > 60 or entered !~ '^[[:alpha:]][[:alpha:] ''.-]* [[:alpha:]][[:alpha:] ''.-]*$' then
    raise exception 'Please enter your first and last name';
  end if;

  select array_agg(m.id) into native_ids
  from public.members m
  where m.active and m.leader_import_key is null
    and name_key in (lower(regexp_replace(btrim(replace(m.display_name, '’', '''')), '\s+', ' ', 'g')),
      lower(regexp_replace(btrim(replace(regexp_replace(m.name, '^([^,]+),\s*(.+)$', '\2 \1'), '’', '''')), '\s+', ' ', 'g')));

  select array_agg(distinct (r.item->>3)::uuid) into roster_ids
  from public.sheets s cross join lateral jsonb_array_elements(s.rows) r(item)
  where s.key = 'lcr_test_members' and s.updated_by = 'LCR Overview test extension'
    and (r.item->>3) ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
    and lower(regexp_replace(btrim(replace(regexp_replace(r.item->>0, '^([^,]+),\s*(.+)$', '\2 \1'), '’', '''')), '\s+', ' ', 'g')) = name_key;

  if coalesce(cardinality(native_ids), 0) = 1 and coalesce(cardinality(roster_ids), 0) = 0 then
    target := native_ids[1];
  elsif cardinality(roster_ids) = 1 and coalesce(cardinality(native_ids), 0) <= 1 then
    roster_id := roster_ids[1];
    select * into person from public._leader_imported_member(roster_id);
    if found then
      if cardinality(native_ids) = 1 then
        select m.id into target from public.members m where m.id = native_ids[1] and m.lcr_uuid = person.profile_uuid;
      else
        select m.id into target from public.members m where m.active and
          (m.leader_import_key = roster_id or (m.leader_import_key is null and m.lcr_uuid = person.profile_uuid))
        order by (m.leader_import_key is null) desc limit 1;
        if target is null then
          insert into public.members(name, display_name, leader_import_key)
          values (person.name, regexp_replace(person.name, '^([^,]+),\s*(.+)$', '\2 \1'), roster_id)
          on conflict (leader_import_key) do update set name = excluded.name, display_name = excluded.display_name
          returning id into target;
        end if;
      end if;
    end if;
  end if;

  if target is null then
    insert into public.attendance_guests(meeting_date, class, name) values (p_date, p_class, entered)
    on conflict do nothing;
  else
    insert into public.attendance(meeting_date, class, member_id) values (p_date, p_class, target)
    on conflict do nothing;
  end if;
  return true;
end $$;
revoke all on function public.check_in_by_name(date, text, text) from public, anon, authenticated;
grant execute on function public.check_in_by_name(date, text, text) to anon, authenticated;
-- Retire the old public roster and attendance endpoints after the new roll page is published.
revoke execute on function public.roll_members(), public.checked_in(date,text),
  public.guests_checked_in(date,text), public.check_in(date,text,uuid[]),
  public.check_out(date,text,uuid), public.check_in_guest(date,text,text)
from public, anon, authenticated;
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
