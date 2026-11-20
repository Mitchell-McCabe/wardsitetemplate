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
