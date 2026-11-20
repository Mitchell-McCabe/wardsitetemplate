-- Qualify output-column names inside the attendance aggregate.
create or replace function public.admin_meeting_dates(p_pass text)
returns table (meeting_date date, counts jsonb)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_pass);
  return query
    with x as (
      select a.meeting_date, a.class from attendance a
      union all
      select g.meeting_date, g.class from attendance_guests g
    )
    select x.meeting_date, coalesce(jsonb_object_agg(x.class, x.n), '{}'::jsonb)
    from (select source.meeting_date, source.class, count(*) as n from x as source group by source.meeting_date, source.class) x
    group by x.meeting_date
    order by x.meeting_date desc
    limit 52;
end $$;
