-- =====================================================================
-- GAMES GRID — daily shop takings
-- Run in the Supabase SQL editor. Safe to re-run.
--
-- Records snacks and drinks takings as one figure per day per payment
-- method, so shop money sits alongside gaming money in Finance without
-- running full inventory.
-- =====================================================================

create table if not exists shop_revenue (
  id            uuid primary key default gen_random_uuid(),
  business_date date not null default (now() at time zone 'Asia/Kolkata')::date,
  amount_paise  integer not null,
  method        pay_method not null default 'cash',
  note          text,
  staff_id      uuid references staff(id),
  created_at    timestamptz not null default now()
);

create index if not exists shop_revenue_day on shop_revenue (business_date);

alter table shop_revenue enable row level security;

drop policy if exists staff_shop_revenue on shop_revenue;
create policy staff_shop_revenue on shop_revenue for all
  using (is_staff()) with check (is_staff());

-- Gaming + shop + expenses, one row per day -------------------------
create or replace view v_finance_day as
with gaming as (
  select (p.paid_at at time zone 'Asia/Kolkata')::date as d,
         sum(p.amount_paise)                                           as gaming_paise,
         sum(p.amount_paise) filter (where p.method = 'cash')           as gaming_cash,
         sum(p.amount_paise) filter (where p.method in ('upi','card'))  as gaming_online
  from payments p where p.status = 'paid' group by 1
),
shop as (
  select business_date as d,
         sum(amount_paise)                                        as shop_paise,
         sum(amount_paise) filter (where method = 'cash')          as shop_cash,
         sum(amount_paise) filter (where method in ('upi','card')) as shop_online
  from shop_revenue group by 1
),
spend as (
  select spent_on as d, sum(amount_paise) as expenses_paise from expenses group by 1
),
days as (
  select d from gaming union select d from shop union select d from spend
)
select
  days.d                                                         as business_date,
  coalesce(g.gaming_paise, 0)                                    as gaming_paise,
  coalesce(s.shop_paise, 0)                                      as shop_paise,
  coalesce(g.gaming_paise, 0) + coalesce(s.shop_paise, 0)        as revenue_paise,
  coalesce(g.gaming_cash, 0) + coalesce(s.shop_cash, 0)          as cash_paise,
  coalesce(g.gaming_online, 0) + coalesce(s.shop_online, 0)      as online_paise,
  coalesce(x.expenses_paise, 0)                                  as expenses_paise,
  coalesce(g.gaming_paise, 0) + coalesce(s.shop_paise, 0)
    - coalesce(x.expenses_paise, 0)                              as net_paise
from days
left join gaming g on g.d = days.d
left join shop  s  on s.d = days.d
left join spend x  on x.d = days.d
order by 1 desc;

alter view v_finance_day set (security_invoker = true);
