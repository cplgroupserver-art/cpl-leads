-- ============================================================
-- lead_type + lead_activities + customer source
-- รันได้ซ้ำ · ขั้นแรกสำรองข้อมูลก่อน
-- ============================================================

-- 0) สำรองข้อมูล
create table if not exists public.bak_20261126_leads as table public.leads;
create table if not exists public.bak_20261126_customers as table public.customers;
create table if not exists public.bak_20261126_customer_contacts as table public.customer_contacts;
alter table public.bak_20261126_leads enable row level security;
alter table public.bak_20261126_customers enable row level security;
alter table public.bak_20261126_customer_contacts enable row level security;
revoke all on public.bak_20261126_leads, public.bak_20261126_customers, public.bak_20261126_customer_contacts from anon, authenticated;

-- 1) ค่าตั้งค่า X / Y วัน
create table if not exists public.app_config (key text primary key, val text not null);
insert into public.app_config(key,val) values ('churn_days','90'),('act_days','30') on conflict (key) do nothing;
alter table public.app_config enable row level security;
drop policy if exists app_config_read on public.app_config;
drop policy if exists app_config_write on public.app_config;
create policy app_config_read on public.app_config for select to authenticated using (true);
create policy app_config_write on public.app_config for all to authenticated
  using (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'))
  with check (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'));

-- 2) คอลัมน์ใหม่
alter table public.leads add column if not exists lead_type text default 'new';
alter table public.customers add column if not exists first_source text;
alter table public.customers add column if not exists last_source text;
create index if not exists leads_customer_idx on public.leads(customer_id);

-- ทะเบียนงาน (ถ้ายังไม่ได้รัน beta-setup.sql)
create table if not exists public.sales_jobs (
  id bigserial primary key, job_no text not null, open_date date, close_date date,
  sales text not null, assistant text, customer_name text not null, customer_id bigint, lead_id bigint,
  svc text not null, country text, income numeric default 0, net numeric default 0, new_old text,
  channel text, branch text, status text default 'OPEN', pay text default 'p', src text,
  so text, awb text, product text, remark text, created_by uuid default auth.uid(), created_at timestamptz default now());

-- 3) กิจกรรมของ Lead (สิทธิ์ตาม leads)
do $$
declare tl text; tc text;
begin
  select format_type(atttypid,atttypmod) into tl from pg_attribute where attrelid='public.leads'::regclass and attname='id';
  select format_type(atttypid,atttypmod) into tc from pg_attribute where attrelid='public.customers'::regclass and attname='id';
  execute format('create table if not exists public.lead_activities (
    id bigserial primary key, lead_id %s not null, at date not null default current_date,
    channel text, ads text, note text, created_by uuid default auth.uid(), created_by_name text,
    created_at timestamptz default now())', tl);
  -- ให้ชนิด id ในทะเบียนงานตรงกับ leads / customers
  if (select format_type(atttypid,atttypmod) from pg_attribute where attrelid='public.sales_jobs'::regclass and attname='lead_id')<>tl then
    execute format('alter table public.sales_jobs alter column lead_id type %s using lead_id::text::%s', tl, tl); end if;
  if (select format_type(atttypid,atttypmod) from pg_attribute where attrelid='public.sales_jobs'::regclass and attname='customer_id')<>tc then
    execute format('alter table public.sales_jobs alter column customer_id type %s using customer_id::text::%s', tc, tc); end if;
end $$;
create index if not exists lead_act_lead_idx on public.lead_activities(lead_id);
alter table public.lead_activities enable row level security;
drop policy if exists lead_act_all on public.lead_activities;
create policy lead_act_all on public.lead_activities for all to authenticated
  using (exists(select 1 from public.leads l where l.id=lead_id))
  with check (exists(select 1 from public.leads l where l.id=lead_id));

-- 4) คำนวณ lead_type ใหม่ทั้งลูกค้า (แยกแบรนด์ตาม team)
create or replace function public.lt_recalc(cid public.leads.customer_id%TYPE) returns void
language plpgsql security definer set search_path=public as $$
declare x int := coalesce((select val::int from app_config where key='churn_days'),90);
begin
  if cid is null then return; end if;
  with L as (
    select id, team, date::date d, coalesce(deal_date::date, date::date) cd,
           (status='ปิดการขาย' or fu_status='ปิดการขาย') won
    from leads where customer_id=cid),
  C as (
    select team, cd from L where won and cd is not null
    union all
    select o.team, j.close_date from sales_jobs j
      join options o on o.kind='sales' and o.value=j.sales
      where j.customer_id::text=cid::text and j.close_date is not null),
  T as (
    select l.id,
      exists(select 1 from L p where p.team=l.team and (p.d<l.d or (p.d=l.d and p.id<l.id))) prior,
      (select max(c.cd) from C c where c.team=l.team and c.cd<l.d) lc, l.d
    from L l),
  R as (
    select id, case when not prior and lc is null then 'new'
                    when lc is null then 'repeat_inquiry'
                    when lc >= d - x then 'active'
                    else 'winback' end lt
    from T)
  update leads set lead_type=R.lt from R where leads.id=R.id and leads.lead_type is distinct from R.lt;
end $$;

-- 5) แหล่งที่มาของลูกค้า (first ไม่เปลี่ยน ยกเว้นตอนรวมรายชื่อ)
create or replace function public.cu_src(cid public.leads.customer_id%TYPE, force boolean default false) returns void
language plpgsql security definer set search_path=public as $$
begin
  if cid is null then return; end if;
  update customers c set
    first_source = case when force or c.first_source is null then
      (select nullif(ads,'') from leads where customer_id=cid and coalesce(ads,'')<>'' order by date asc, id asc limit 1)
      else c.first_source end,
    last_source = (select nullif(ads,'') from leads where customer_id=cid and coalesce(ads,'')<>'' order by date desc, id desc limit 1)
  where c.id=cid;
end $$;

create or replace function public.lt_merge(cid public.leads.customer_id%TYPE) returns void
language plpgsql security definer set search_path=public as $$
begin perform lt_recalc(cid); perform cu_src(cid,true); end $$;

grant execute on function public.lt_recalc to authenticated;
grant execute on function public.cu_src to authenticated;
grant execute on function public.lt_merge to authenticated;

create or replace function public.lt_recalc_all() returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='admin') then return; end if;
  perform lt_recalc(customer_id) from (select distinct customer_id from leads where customer_id is not null) s;
end $$;
grant execute on function public.lt_recalc_all to authenticated;

-- 6) Trigger: คำนวณอัตโนมัติทุกครั้งที่ Lead เปลี่ยน (บันทึก/แก้/ปิด/แก้วันปิด/ลบ/รวม/ผูกหลังนำเข้า)
create or replace function public.lt_trg() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    perform lt_recalc(old.customer_id); perform cu_src(old.customer_id);
  end if;
  if tg_op='DELETE' then delete from lead_activities where lead_id=old.id; end if;
  if tg_op='INSERT' or (tg_op='UPDATE' and new.customer_id is distinct from old.customer_id) then
    perform lt_recalc(new.customer_id); perform cu_src(new.customer_id);
  end if;
  return null;
end $$;
drop trigger if exists leads_lt on public.leads;
create trigger leads_lt after insert or delete or update of customer_id,status,fu_status,date,deal_date,team,ads
  on public.leads for each row execute function public.lt_trg();

create or replace function public.lt_trg_jobs() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if tg_op in ('UPDATE','DELETE') then perform lt_recalc(old.customer_id); end if;
  if tg_op in ('INSERT','UPDATE') then perform lt_recalc(new.customer_id); end if;
  return null;
end $$;
drop trigger if exists sales_jobs_lt on public.sales_jobs;
create trigger sales_jobs_lt after insert or delete or update of customer_id,close_date,sales
  on public.sales_jobs for each row execute function public.lt_trg_jobs();

-- 7) Lead ที่ยังไม่ระบุเซลล์ → ใส่เจ้าของลูกค้า
create or replace function public.lead_owner_fill() returns trigger
language plpgsql security definer set search_path=public as $$
declare o text;
begin
  if coalesce(new.sales,'')='' and new.customer_id is not null then
    select owner into o from customers where id=new.customer_id;
    if coalesce(o,'')<>'' then new.sales:=o; end if;
  end if;
  return new;
end $$;
drop trigger if exists leads_owner_fill on public.leads;
create trigger leads_owner_fill before insert or update of customer_id,sales
  on public.leads for each row execute function public.lead_owner_fill();

-- 8) ไล่คำนวณข้อมูลเก่าทั้งหมด
update public.leads l set sales=c.owner from public.customers c
  where l.customer_id=c.id and coalesce(l.sales,'')='' and coalesce(c.owner,'')<>'';
update public.leads set lead_type='new' where customer_id is null and lead_type is distinct from 'new';
select public.lt_recalc(customer_id) from (select distinct customer_id from public.leads where customer_id is not null) s;
select public.cu_src(id) from public.customers;

-- ตรวจผล: ทุก Lead ต้องมีประเภท
select date_trunc('month',date::date) m, count(*) total,
  count(*) filter (where lead_type='new') new_, count(*) filter (where lead_type='repeat_inquiry') repeat_,
  count(*) filter (where lead_type='active') active_, count(*) filter (where lead_type='winback') winback_
from public.leads where date >= '2026-10-01' group by 1 order by 1;
