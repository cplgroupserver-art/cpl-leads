-- Make "Inbox" an editable Ads option (Settings → Ads)
update public.leads set ads = 'Inbox' where ads = 'ไม่ระบุ Ads';
insert into public.options (kind, value)
select 'ads', 'Inbox'
where not exists (select 1 from public.options where kind = 'ads' and value = 'Inbox');
