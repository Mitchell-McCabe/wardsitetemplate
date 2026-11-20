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
