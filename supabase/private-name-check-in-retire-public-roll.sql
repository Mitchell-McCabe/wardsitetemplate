-- Retire the old public roster and attendance endpoints after the new roll page is published.
revoke execute on function public.roll_members(), public.checked_in(date,text),
  public.guests_checked_in(date,text), public.check_in(date,text,uuid[]),
  public.check_out(date,text,uuid), public.check_in_guest(date,text,text)
from public, anon, authenticated;
