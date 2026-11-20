
create function public.admin_missionary_weekly_email_count(p_pass text)
returns bigint language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 return (select count(*) from public.missionary_weekly_email);
end $$;
revoke all on function public.admin_missionary_weekly_email_count(text) from public;
grant execute on function public.admin_missionary_weekly_email_count(text) to anon;
