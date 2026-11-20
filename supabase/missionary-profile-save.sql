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
