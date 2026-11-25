-- Announcements: meeting data (time, attendees, Google Meet / Calendar link)
alter table public.announcements add column if not exists meet jsonb;

-- Attendee e-mails for Google Calendar invites (admin / marketing only)
create or replace function public.meet_emails()
returns table(name text, team text, email text)
language sql security definer
set search_path = public, auth
as $$
  select p.name, p.team, u.email::text
  from public.profiles p join auth.users u on u.id = p.id
  where exists (select 1 from public.profiles me where me.id = auth.uid() and me.role in ('admin','marketing'))
$$;
revoke all on function public.meet_emails() from public, anon;
grant execute on function public.meet_emails() to authenticated;
