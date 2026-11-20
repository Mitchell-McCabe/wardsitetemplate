
create function public.admin_ward_signup_pending_count(p_pass text)
returns bigint language plpgsql security definer set search_path='' as $$
begin
 perform public._check_admin(p_pass);
 return (select count(*) from public.ward_extra where kind='signup' and state='pending');
end $$;
revoke all on function public.admin_ward_signup_pending_count(text) from public;
grant execute on function public.admin_ward_signup_pending_count(text) to anon;
