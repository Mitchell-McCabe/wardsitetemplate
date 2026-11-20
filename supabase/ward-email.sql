create or replace function public.site_settings()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'ward_name', coalesce((select value from public.settings where key = 'ward_name'), ''),
    'ward_email', coalesce((select value from public.settings where key = 'ward_email'), ''),
    'roll_home_visible', coalesce((select value <> 'false' from public.settings where key = 'roll_home_visible'), true)
  )
$$;
grant execute on function public.site_settings() to anon;
