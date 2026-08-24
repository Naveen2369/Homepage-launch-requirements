-- =====================================================================
-- GAMES GRID — booking logic
-- Run after 01_schema.sql
--
-- All availability is calculated here, in the database. The website never
-- decides whether a slot is free — it asks these functions.
-- =====================================================================

-- Keep updated_at honest -------------------------------------------------
create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create trigger bookings_touch before update on bookings
  for each row execute function touch_updated_at();

-- Is the signed-in user staff? -------------------------------------------
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where id = auth.uid() and active);
$$;

create or replace function is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where id = auth.uid() and active and role = 'owner');
$$;

-- Settings helper --------------------------------------------------------
create or replace function setting(k text) returns jsonb
language sql stable as $$ select value from settings where key = k $$;

-- ---------------------------------------------------------------------
-- FREE STATIONS
-- Returns the stations of one kind that are completely free for a window.
-- Respects live bookings, maintenance blocks and station state.
-- ---------------------------------------------------------------------
create or replace function free_stations(
  p_kind      station_kind,
  p_starts_at timestamptz,
  p_ends_at   timestamptz
)
returns table (id uuid, code text)
language sql stable as $$
  select s.id, s.code
  from stations s
  where s.kind = p_kind
    and s.state = 'active'
    and not exists (
      select 1 from bookings b
      where b.station_id = s.id
        and b.status in ('held', 'confirmed', 'arrived')
        and b.slot && tstzrange(p_starts_at, p_ends_at, '[)')
    )
    and not exists (
      select 1 from station_blocks k
      where k.station_id = s.id
        and k.slot && tstzrange(p_starts_at, p_ends_at, '[)')
    )
  order by s.sort_order;
$$;

-- ---------------------------------------------------------------------
-- DAY AVAILABILITY
-- Powers the start-time grid. One row per hour, with how many stations
-- of that kind are free for the full requested duration.
-- ---------------------------------------------------------------------
create or replace function day_availability(
  p_kind     station_kind,
  p_date     date,
  p_hours    numeric default 1
)
returns table (hour_start timestamptz, free_count integer)
language sql stable as $$
  with hours as (
    select generate_series(
      (p_date + (setting('opening_hours')->>'open')::time) at time zone 'Asia/Kolkata',
      (p_date + (setting('opening_hours')->>'close')::time) at time zone 'Asia/Kolkata'
        - (p_hours || ' hours')::interval,
      interval '1 hour'
    ) as h
  )
  select h.h,
         (select count(*)::integer
          from free_stations(p_kind, h.h, h.h + (p_hours || ' hours')::interval))
  from hours h
  order by h.h;
$$;

-- ---------------------------------------------------------------------
-- PRICE QUOTE
-- Single source of truth for what a booking costs. The website shows this;
-- it never calculates a total itself.
-- ---------------------------------------------------------------------
create or replace function quote_booking(
  p_kind             station_kind,
  p_hours            numeric,
  p_extra_controller boolean default false,
  p_on_date          date default current_date
)
returns table (base_paise integer, addons_paise integer, total_paise integer)
language sql stable as $$
  with p as (
    select case
             when offer_paise is not null
              and (offer_starts_on is null or p_on_date >= offer_starts_on)
              and (offer_ends_on   is null or p_on_date <= offer_ends_on)
             then offer_paise else standard_paise
           end as rate,
           unit
    from pricing where kind = p_kind and active limit 1
  ),
  a as (
    select coalesce((select price_paise from addons
                     where code = 'extra_controller' and active), 0) as ctrl
  )
  select
    (case when p.unit = 'slot' then p.rate else (p.rate * p_hours)::integer end),
    (case when p_extra_controller then (a.ctrl * p_hours)::integer else 0 end),
    (case when p.unit = 'slot' then p.rate else (p.rate * p_hours)::integer end)
      + (case when p_extra_controller then (a.ctrl * p_hours)::integer else 0 end)
  from p, a;
$$;

-- ---------------------------------------------------------------------
-- HOLD A BOOKING
--
-- Called when the customer presses "Hold slot & pay". Picks a free station,
-- writes a held row, and returns it. If two people call this at the same
-- instant for the last station, the exclusion constraint makes one of them
-- fail — which is the behaviour we want.
--
-- Pass p_station_id to force a specific station (admin walk-in), or leave
-- null for "any available".
-- ---------------------------------------------------------------------
create or replace function hold_booking(
  p_kind             station_kind,
  p_starts_at        timestamptz,
  p_hours            numeric,
  p_full_name        text,
  p_phone            text,
  p_email            text default null,
  p_people           smallint default 1,
  p_extra_controller boolean default false,
  p_station_id       uuid default null,
  p_source           booking_source default 'online'
)
returns bookings
language plpgsql security definer set search_path = public as $$
declare
  v_ends_at   timestamptz := p_starts_at + (p_hours || ' hours')::interval;
  v_station   uuid;
  v_customer  uuid;
  v_quote     record;
  v_hold_min  integer := coalesce((setting('hold_minutes'))::text::integer, 10);
  v_booking   bookings;
begin
  if p_starts_at < now() then
    raise exception 'That time has already passed';
  end if;

  if p_starts_at > now() + ((setting('booking_window_days'))::text::integer || ' days')::interval then
    raise exception 'Bookings open only % days ahead', (setting('booking_window_days'))::text;
  end if;

  -- pick a station
  if p_station_id is not null then
    select id into v_station
    from free_stations(p_kind, p_starts_at, v_ends_at)
    where id = p_station_id;
  else
    select id into v_station
    from free_stations(p_kind, p_starts_at, v_ends_at) limit 1;
  end if;

  if v_station is null then
    raise exception 'No % available for that time', p_kind;
  end if;

  -- find or create the customer by phone
  select id into v_customer from customers where phone = p_phone;
  if v_customer is null then
    insert into customers (full_name, phone, email)
    values (p_full_name, p_phone, p_email)
    returning id into v_customer;
  else
    update customers
       set full_name = coalesce(nullif(p_full_name, ''), full_name),
           email     = coalesce(nullif(p_email, ''), email)
     where id = v_customer;
  end if;

  select * into v_quote
  from quote_booking(p_kind, p_hours, p_extra_controller, p_starts_at::date);

  insert into bookings (
    customer_id, station_id, kind, starts_at, ends_at, duration_hours, people,
    status, source, base_paise, addons_paise, total_paise,
    payment_status, hold_expires_at
  ) values (
    v_customer, v_station, p_kind, p_starts_at, v_ends_at, p_hours, p_people,
    'held', p_source, v_quote.base_paise, v_quote.addons_paise, v_quote.total_paise,
    'pending', now() + (v_hold_min || ' minutes')::interval
  ) returning * into v_booking;

  if p_extra_controller then
    insert into booking_addons (booking_id, addon_id, quantity, price_paise)
    select v_booking.id, id, 1, (price_paise * p_hours)::integer
    from addons where code = 'extra_controller';
  end if;

  return v_booking;
end $$;

-- ---------------------------------------------------------------------
-- CONFIRM A BOOKING
--
-- Call this from the payment webhook, or from admin when cash is taken.
-- Never call it from the customer's browser.
-- ---------------------------------------------------------------------
create or replace function confirm_booking(
  p_booking_id  uuid,
  p_method      pay_method default 'upi',
  p_gateway_payment_id text default null,
  p_staff_id    uuid default null
)
returns bookings
language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
begin
  select * into v_booking from bookings where id = p_booking_id for update;

  if v_booking is null then
    raise exception 'Booking not found';
  end if;
  if v_booking.status <> 'held' then
    raise exception 'Booking is % — cannot confirm', v_booking.status;
  end if;
  if v_booking.hold_expires_at < now() then
    raise exception 'The hold expired — please book again';
  end if;

  insert into payments (booking_id, customer_id, amount_paise, method, status,
                        gateway_payment_id, received_by, paid_at)
  values (v_booking.id, v_booking.customer_id, v_booking.total_paise, p_method,
          'paid'::pay_state,
          p_gateway_payment_id, p_staff_id, now());

  update bookings
     set status = 'confirmed',
         payment_status = 'paid',
         hold_expires_at = null
   where id = p_booking_id
   returning * into v_booking;

  -- queue the messages
  insert into notifications (channel, template, to_address, booking_id, payload, send_after)
  select 'whatsapp', 'booking_confirmed', c.phone, v_booking.id,
         jsonb_build_object('reference', v_booking.reference,
                            'starts_at', v_booking.starts_at,
                            'total_paise', v_booking.total_paise),
         now()
  from customers c where c.id = v_booking.customer_id;

  insert into notifications (channel, template, to_address, booking_id, payload, send_after)
  select 'whatsapp', 'reminder_24h', c.phone, v_booking.id, '{}'::jsonb,
         v_booking.starts_at - interval '24 hours'
  from customers c
  where c.id = v_booking.customer_id
    and v_booking.starts_at - interval '24 hours' > now();

  insert into notifications (channel, template, to_address, booking_id, payload, send_after)
  select 'whatsapp', 'reminder_1h', c.phone, v_booking.id, '{}'::jsonb,
         v_booking.starts_at - interval '1 hour'
  from customers c
  where c.id = v_booking.customer_id
    and v_booking.starts_at - interval '1 hour' > now();

  return v_booking;
end $$;

-- ---------------------------------------------------------------------
-- RELEASE EXPIRED HOLDS
-- Schedule this every minute with pg_cron, or call it before availability
-- checks. Unpaid holds return to the pool.
-- ---------------------------------------------------------------------
create or replace function release_expired_holds() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update bookings
     set status = 'expired', hold_expires_at = null
   where status = 'held' and hold_expires_at < now();
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- LOYALTY — one stamp per completed hour, 10th hour free
-- ---------------------------------------------------------------------
create or replace function add_loyalty_stamps(p_booking_id uuid, p_staff_id uuid default null)
returns loyalty_cards
language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
  v_card    loyalty_cards;
begin
  select * into v_booking from bookings where id = p_booking_id;
  if v_booking is null or v_booking.status <> 'completed' then
    raise exception 'Only completed bookings earn stamps';
  end if;

  select * into v_card from loyalty_cards where customer_id = v_booking.customer_id;
  if v_card is null then
    insert into loyalty_cards (customer_id) values (v_booking.customer_id)
    returning * into v_card;
  end if;

  update loyalty_cards
     set stamps = least(10, stamps + v_booking.duration_hours::smallint)
   where id = v_card.id
   returning * into v_card;

  insert into loyalty_events (card_id, booking_id, delta, staff_id)
  values (v_card.id, p_booking_id, v_booking.duration_hours::smallint, p_staff_id);

  return v_card;
end $$;

-- ---------------------------------------------------------------------
-- REFERRAL — credit both sides after the friend's first paid booking
-- ---------------------------------------------------------------------
create or replace function settle_referral(p_referred_customer uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_ref referrals;
  v_amt integer := coalesce((setting('referral_paise'))::text::integer, 3000);
begin
  select * into v_ref from referrals
   where referred_id = p_referred_customer and not rewarded limit 1;
  if v_ref is null then return; end if;

  if not exists (select 1 from bookings
                 where customer_id = p_referred_customer and payment_status = 'paid') then
    return;
  end if;

  update customers set credit_paise = credit_paise + v_amt
   where id in (v_ref.referrer_id, v_ref.referred_id);

  update referrals set rewarded = true, rewarded_at = now() where id = v_ref.id;
end $$;

-- ---------------------------------------------------------------------
-- ADMIN DASHBOARD — today at a glance
-- ---------------------------------------------------------------------
create or replace view v_today as
select
  (select count(*) from bookings
    where starts_at::date = current_date and kind = 'ps5'
      and status in ('confirmed','arrived','completed'))            as ps5_bookings,
  (select count(*) from bookings
    where starts_at::date = current_date and kind = 'simulator'
      and status in ('confirmed','arrived','completed'))            as sim_bookings,
  (select count(*) from bookings
    where starts_at::date = current_date and kind = 'projector'
      and status in ('confirmed','arrived','completed'))            as room_bookings,
  (select coalesce(sum(amount_paise),0) from payments
    where paid_at::date = current_date and status = 'paid')         as revenue_paise,
  (select coalesce(sum(amount_paise),0) from expenses
    where spent_on = current_date)                                  as expenses_paise;

create or replace view v_station_status as
select s.id, s.code, s.kind, s.state,
       b.id as current_booking, b.ends_at as busy_until
from stations s
left join bookings b
  on b.station_id = s.id
 and b.status in ('confirmed','arrived')
 and now() between b.starts_at and b.ends_at
order by s.sort_order;

create or replace view v_daily_report as
with sales as (
  select p.paid_at::date as business_date,
         sum(p.amount_paise) filter (where p.method = 'cash')            as cash_paise,
         sum(p.amount_paise) filter (where p.method in ('upi','card'))   as online_paise,
         sum(p.amount_paise)                                             as total_sales_paise
  from payments p
  where p.status = 'paid'
  group by p.paid_at::date
),
spend as (
  select e.spent_on as business_date, sum(e.amount_paise) as expenses_paise
  from expenses e
  group by e.spent_on
)
select coalesce(s.business_date, x.business_date)      as business_date,
       coalesce(s.cash_paise, 0)                       as cash_paise,
       coalesce(s.online_paise, 0)                     as online_paise,
       coalesce(s.total_sales_paise, 0)                as total_sales_paise,
       coalesce(x.expenses_paise, 0)                   as expenses_paise,
       coalesce(s.total_sales_paise, 0) - coalesce(x.expenses_paise, 0) as net_paise
from sales s
full outer join spend x on x.business_date = s.business_date
order by 1 desc;
