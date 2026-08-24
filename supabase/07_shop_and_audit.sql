-- =====================================================================
-- GAMES GRID — shop & inventory, audit trail, combined revenue
-- Run in the Supabase SQL editor, after 06_availability_fix.sql
-- =====================================================================

-- SHOP PRODUCTS -------------------------------------------------------
create table if not exists products (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  category        text not null default 'Snacks',
  cost_paise      integer not null default 0,      -- what we pay
  price_paise     integer not null default 0,      -- what we charge
  stock           integer not null default 0,
  min_stock       integer not null default 5,
  active          boolean not null default true,
  sort_order      smallint not null default 0,
  created_at      timestamptz not null default now()
);

-- SHOP SALES ----------------------------------------------------------
create table if not exists shop_sales (
  id              uuid primary key default gen_random_uuid(),
  product_id      uuid references products(id) on delete set null,
  customer_id     uuid references customers(id) on delete set null,
  quantity        integer not null default 1,
  unit_paise      integer not null,
  discount_paise  integer not null default 0,
  total_paise     integer not null,
  method          pay_method not null default 'cash',
  staff_id        uuid references staff(id),
  sold_on         date not null default (now() at time zone 'Asia/Kolkata')::date,
  created_at      timestamptz not null default now()
);

create index if not exists shop_sales_day on shop_sales (sold_on);

-- STOCK MOVEMENTS — purchases, corrections, wastage -------------------
create table if not exists stock_moves (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references products(id) on delete cascade,
  delta        integer not null,                   -- +25 received, -3 wastage
  reason       text not null default 'purchase',   -- purchase | correction | wastage
  cost_paise   integer not null default 0,
  staff_id     uuid references staff(id),
  moved_on     date not null default (now() at time zone 'Asia/Kolkata')::date,
  created_at   timestamptz not null default now()
);

alter table products    enable row level security;
alter table shop_sales  enable row level security;
alter table stock_moves enable row level security;

drop policy if exists staff_products on products;
create policy staff_products on products for all
  using (is_staff()) with check (is_staff());

drop policy if exists staff_shop_sales on shop_sales;
create policy staff_shop_sales on shop_sales for all
  using (is_staff()) with check (is_staff());

drop policy if exists staff_stock_moves on stock_moves;
create policy staff_stock_moves on stock_moves for all
  using (is_staff()) with check (is_staff());

-- Selling reduces stock; receiving stock adds to it. -------------------
create or replace function apply_shop_sale() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update products set stock = stock - new.quantity where id = new.product_id;
  return new;
end $$;

drop trigger if exists shop_sale_stock on shop_sales;
create trigger shop_sale_stock after insert on shop_sales
  for each row execute function apply_shop_sale();

create or replace function apply_stock_move() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update products set stock = stock + new.delta where id = new.product_id;
  return new;
end $$;

drop trigger if exists stock_move_apply on stock_moves;
create trigger stock_move_apply after insert on stock_moves
  for each row execute function apply_stock_move();

-- SELL — one call records the sale and moves the stock ----------------
create or replace function sell_product(
  p_product_id uuid,
  p_quantity   integer,
  p_method     pay_method default 'cash',
  p_discount   integer default 0,
  p_customer   uuid default null
)
returns shop_sales
language plpgsql security definer set search_path = public as $$
declare
  v_p products;
  v_row shop_sales;
begin
  if not is_staff() then raise exception 'Not authorised'; end if;
  select * into v_p from products where id = p_product_id for update;
  if v_p is null then raise exception 'Product not found'; end if;
  if v_p.stock < p_quantity then
    raise exception 'Only % left in stock', v_p.stock;
  end if;

  insert into shop_sales (product_id, customer_id, quantity, unit_paise,
                          discount_paise, total_paise, method, staff_id)
  values (p_product_id, p_customer, p_quantity, v_p.price_paise,
          p_discount, (v_p.price_paise * p_quantity) - p_discount,
          p_method, auth.uid())
  returning * into v_row;

  return v_row;
end $$;

grant execute on function sell_product(uuid, integer, pay_method, integer, uuid) to authenticated;

-- AUDIT TRAIL — record price, booking and equipment changes -----------
create or replace function write_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (staff_id, action, entity, entity_id, detail)
  values (
    auth.uid(),
    lower(tg_op),
    tg_table_name,
    coalesce(new.id, old.id),
    jsonb_build_object(
      'before', case when tg_op = 'INSERT' then null else to_jsonb(old) end,
      'after',  case when tg_op = 'DELETE' then null else to_jsonb(new) end
    )
  );
  return coalesce(new, old);
end $$;

drop trigger if exists audit_pricing  on pricing;
create trigger audit_pricing  after insert or update or delete on pricing
  for each row execute function write_audit();

drop trigger if exists audit_bookings on bookings;
create trigger audit_bookings after update or delete on bookings
  for each row execute function write_audit();

drop trigger if exists audit_stations on stations;
create trigger audit_stations after insert or update or delete on stations
  for each row execute function write_audit();

drop trigger if exists audit_expenses on expenses;
create trigger audit_expenses after insert or delete on expenses
  for each row execute function write_audit();

-- END-OF-DAY — columns the closing screen writes ----------------------
alter table day_closings add column if not exists expected_paise   integer not null default 0;
alter table day_closings add column if not exists counted_paise    integer not null default 0;
alter table day_closings add column if not exists difference_paise integer not null default 0;
alter table day_closings add column if not exists notes            text;

-- DAY TOTALS — gaming + shop in one place ----------------------------
create or replace view v_day_totals as
with g as (
  select (p.paid_at at time zone 'Asia/Kolkata')::date as d,
         sum(p.amount_paise)                                            as gaming_paise,
         sum(p.amount_paise) filter (where p.method = 'cash')            as gaming_cash,
         sum(p.amount_paise) filter (where p.method in ('upi','card'))   as gaming_online
  from payments p where p.status = 'paid' group by 1
),
sh as (
  select sold_on as d,
         sum(total_paise)                                        as shop_paise,
         sum(total_paise) filter (where method = 'cash')          as shop_cash,
         sum(total_paise) filter (where method in ('upi','card')) as shop_online
  from shop_sales group by 1
),
ex as (
  select spent_on as d, sum(amount_paise) as expenses_paise from expenses group by 1
),
days as (
  select d from g union select d from sh union select d from ex
)
select
  days.d                                                      as business_date,
  coalesce(g.gaming_paise, 0)                                 as gaming_paise,
  coalesce(sh.shop_paise, 0)                                  as shop_paise,
  coalesce(g.gaming_paise, 0) + coalesce(sh.shop_paise, 0)    as revenue_paise,
  coalesce(g.gaming_cash, 0) + coalesce(sh.shop_cash, 0)      as cash_paise,
  coalesce(g.gaming_online, 0) + coalesce(sh.shop_online, 0)  as online_paise,
  coalesce(ex.expenses_paise, 0)                              as expenses_paise,
  coalesce(g.gaming_paise, 0) + coalesce(sh.shop_paise, 0)
    - coalesce(ex.expenses_paise, 0)                          as net_paise
from days
left join g  on g.d  = days.d
left join sh on sh.d = days.d
left join ex on ex.d = days.d
order by 1 desc;

alter view v_day_totals set (security_invoker = true);

-- Starter products so the shop is usable immediately ------------------
create unique index if not exists products_name_key on products (name);

insert into products (name, category, cost_paise, price_paise, stock, min_stock, sort_order)
values
  ('Water Bottle',      'Drinks', 700,  2000, 24, 6, 1),
  ('Soft Drink',        'Drinks', 2000, 4000, 24, 6, 2),
  ('Energy Drink',      'Drinks', 6000, 9000, 12, 4, 3),
  ('Chips',             'Snacks', 1500, 3000, 30, 8, 4),
  ('Popcorn',           'Snacks', 1200, 3000, 30, 8, 5),
  ('Chocolate',         'Snacks', 2000, 4000, 20, 6, 6)
on conflict do nothing;
