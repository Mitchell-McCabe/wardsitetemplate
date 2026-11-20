
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
