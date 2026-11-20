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
