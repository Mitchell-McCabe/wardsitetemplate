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
