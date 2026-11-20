
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
