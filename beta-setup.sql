-- หน้าหลัก Beta: งานปิดการขาย + เงินเดือนเซลล์ (เฉพาะ Jonus / admin)
create table if not exists sales_jobs (
  id bigserial primary key,
  job_no text not null,
  open_date date,
  close_date date,
  sales text not null,
  assistant text,
  customer_name text not null,
  customer_id bigint,
  lead_id bigint,
  svc text not null,
  country text,
  income numeric default 0,
  net numeric default 0,
  new_old text,
  channel text,
  branch text,
  status text default 'OPEN',
  pay text default 'p',
  src text,
  so text, awb text, product text, remark text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);
create index if not exists sales_jobs_open_idx on sales_jobs(open_date);
create index if not exists sales_jobs_sales_idx on sales_jobs(sales);
create index if not exists sales_jobs_lead_idx on sales_jobs(lead_id);

create table if not exists sales_targets (
  sales text primary key,
  salary numeric not null,
  updated_at timestamptz default now()
);

alter table sales_jobs enable row level security;
alter table sales_targets enable row level security;

create or replace function hb_ok() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from profiles where id=auth.uid() and (role='admin' or name ilike '%jonus%'))
$$;

drop policy if exists hb_jobs on sales_jobs;
create policy hb_jobs on sales_jobs for all to authenticated using (hb_ok()) with check (hb_ok());
drop policy if exists hb_targets on sales_targets;
create policy hb_targets on sales_targets for all to authenticated using (hb_ok()) with check (hb_ok());
