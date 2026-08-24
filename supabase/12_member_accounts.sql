-- =====================================================================
-- GAMES GRID — customer accounts & hour-bank memberships
-- Run in the Supabase SQL editor. Safe to re-run.
--
-- A membership sells a block of hours valid for a period, e.g.
-- ₹1,500 = 15 PS5 hours for 30 days. The customer creates an account,
-- signs in, and sees hours remaining and days left.
--
-- Prices and hours are set from the admin panel — nothing is hard-coded.
-- =====================================================================

-- 1. HOURS PER TIER ---------------------------------------------------
alter table membership_plans add column if not exists hours_included smallint not null default 0;
alter table membership_plans add column if not exists max_members    smallint;          -- cap per tier, null = unlimited
alter table membership_plans add column if not exists covers_sim     boolean not null default false;
alter table membership_plans add column if not exists carry_over     boolean not null default false;

-- 2. HOUR BALANCE ON A MEMBERSHIP -------------------------------------
alter table memberships add column if not exists hours_total     numeric(5,1) not null default 0;
alter table memberships add column if not exists hours_used      numeric(5,1) not null default 0;
alter table memberships add column if not exists activated_by    uuid references staff(id);

-- 3. LINK AN AUTH USER TO A CUSTOMER ----------------------------------
-- Customers sign up with Supabase auth; this ties that login to their
-- booking history, membership and loyalty.
alter table customers add column if not exists auth_user_id uuid unique;

create index if not exists customers_auth on customers (auth_user_id);

-- 4. WHAT A SIGNED-IN CUSTOMER MAY SEE --------------------------------
-- Their own row only. Staff still see everyone via the staff policies.
drop policy if exists own_customer_read on customers;
create policy own_customer_read on customers for select
  using (auth_user_id = auth.uid() or is_staff());

drop policy if exists own_customer_update on customers;
create policy own_customer_update on customers for update
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

alter table memberships enable row level security;

drop policy if exists own_membership_read on memberships;
create policy own_membership_read on memberships for select
  using (
    is_staff() or exists (
      select 1 from customers c
      where c.id = memberships.customer_id and c.auth_user_id = auth.uid()
    )
  );

drop policy if exists staff_memberships on memberships;
create policy staff_memberships on memberships for all
  using (is_staff()) with check (is_staff());

drop policy if exists own_bookings_read on bookings;
create policy own_bookings_read on bookings for select
  using (
    is_staff() or exists (
      select 1 from customers c
      where c.id = bookings.customer_id and c.auth_user_id = auth.uid()
    )
  );

-- 5. CLAIM AN ACCOUNT -------------------------------------------------
-- Called once after sign-up. Attaches the auth user to an existing
-- customer with that phone, or creates one, so a walk-in who later makes
-- an account keeps their history.
create or replace function claim_account(p_full_name text, p_phone text)
returns customers
language plpgsql security definer set search_path = public as $$
declare
  v_row customers;
  v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if length(v_phone) < 10 then raise exception 'A 10-digit phone number is required'; end if;

  -- already claimed by this login
  select * into v_row from customers where auth_user_id = auth.uid();
  if v_row.id is not null then return v_row; end if;

  -- an unclaimed record with the same phone
  select * into v_row from customers
  where regexp_replace(phone, '\D', '', 'g') = v_phone and auth_user_id is null
  limit 1;

  if v_row.id is not null then
    update customers set auth_user_id = auth.uid(),
           full_name = coalesce(nullif(trim(p_full_name), ''), full_name)
    where id = v_row.id returning * into v_row;
    return v_row;
  end if;

  insert into customers (full_name, phone, auth_user_id)
  values (coalesce(nullif(trim(p_full_name), ''), 'Member'), p_phone, auth.uid())
  returning * into v_row;
  return v_row;
end $$;

grant execute on function claim_account(text, text) to authenticated;

-- 6. MY MEMBERSHIP ----------------------------------------------------
-- One call returns everything the account page shows.
create or replace function my_membership()
returns table (
  plan_name       text,
  hours_total     numeric,
  hours_used      numeric,
  hours_left      numeric,
  starts_on       date,
  ends_on         date,
  days_left       integer,
  active          boolean,
  covers_sim      boolean
)
language sql stable security definer set search_path = public as $$
  select p.name,
         m.hours_total,
         m.hours_used,
         greatest(m.hours_total - m.hours_used, 0),
         m.starts_on,
         m.ends_on,
         (m.ends_on - (now() at time zone 'Asia/Kolkata')::date)::integer,
         m.active and m.ends_on >= (now() at time zone 'Asia/Kolkata')::date,
         p.covers_sim
  from memberships m
  join membership_plans p on p.id = m.plan_id
  join customers c on c.id = m.customer_id
  where c.auth_user_id = auth.uid()
  order by m.ends_on desc
  limit 1;
$$;

grant execute on function my_membership() to authenticated;

-- 7. ACTIVATE A MEMBERSHIP (staff) ------------------------------------
-- Used after the customer pays. Sets the hour balance from the plan.
create or replace function activate_membership(
  p_customer_id uuid,
  p_plan_id     uuid,
  p_starts_on   date default null
)
returns memberships
language plpgsql security definer set search_path = public as $$
declare
  v_plan membership_plans;
  v_row  memberships;
  v_from date := coalesce(p_starts_on, (now() at time zone 'Asia/Kolkata')::date);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_count integer;
  v_cap integer;
begin
  if not is_staff() then raise exception 'Not authorised'; end if;
  select * into v_plan from membership_plans where id = p_plan_id;
  if v_plan.id is null then raise exception 'Plan not found'; end if;

  -- Overall cap across every tier. No row, or a non-numeric value, means no
  -- limit. A renewal for this same customer does not count against it, so a
  -- full house can still renew.
  select case when jsonb_typeof(value) = 'number' then (value::text)::integer end
  into v_cap
  from settings where key = 'member_cap';

  if v_cap is not null then
    select count(*) into v_count from memberships
    where active and ends_on >= v_today and customer_id <> p_customer_id;
    if v_count >= v_cap then
      raise exception 'Memberships are full (% of % active)', v_count, v_cap;
    end if;
  end if;

  if v_plan.max_members is not null then
    select count(*) into v_count from memberships
    where plan_id = p_plan_id and active and ends_on >= v_today
      and customer_id <> p_customer_id;
    if v_count >= v_plan.max_members then
      raise exception '% is full (% of % taken)', v_plan.name, v_count, v_plan.max_members;
    end if;
  end if;

  -- close any running membership for this customer
  update memberships set active = false
  where customer_id = p_customer_id and active;

  insert into memberships (customer_id, plan_id, starts_on, ends_on,
                           hours_total, hours_used, active, activated_by)
  values (p_customer_id, p_plan_id, v_from,
          v_from + v_plan.duration_days,
          v_plan.hours_included, 0, true, auth.uid())
  returning * into v_row;
  return v_row;
end $$;

grant execute on function activate_membership(uuid, uuid, date) to authenticated;

-- 8. SPEND HOURS ------------------------------------------------------
-- Draws from the balance; never goes negative, and returns how many
-- hours still need paying for.
create or replace function spend_member_hours(
  p_customer_id uuid,
  p_hours       numeric,
  p_kind        station_kind
)
returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_m memberships;
  v_p membership_plans;
  v_avail numeric;
  v_use numeric;
begin
  select m.*, p.covers_sim into v_m, v_p
  from memberships m join membership_plans p on p.id = m.plan_id
  where m.customer_id = p_customer_id and m.active
    and m.ends_on >= (now() at time zone 'Asia/Kolkata')::date
  order by m.ends_on desc limit 1;

  if v_m.id is null then return p_hours; end if;
  if p_kind = 'projector' then return p_hours; end if;

  select covers_sim into v_p.covers_sim from membership_plans where id = v_m.plan_id;
  if p_kind = 'simulator' and not coalesce(v_p.covers_sim, false) then
    return p_hours;
  end if;

  v_avail := greatest(v_m.hours_total - v_m.hours_used, 0);
  v_use := least(v_avail, p_hours);
  if v_use > 0 then
    update memberships set hours_used = hours_used + v_use where id = v_m.id;
  end if;
  return p_hours - v_use;
end $$;

grant execute on function spend_member_hours(uuid, numeric, station_kind) to authenticated;

-- 9. OVERALL CAP ------------------------------------------------------
insert into settings (key, value) values ('member_cap', '50'::jsonb)
on conflict (key) do nothing;

-- 10. SEED THE GAMER TIER ---------------------------------------------
-- Edit price, hours and cap from Admin → Membership.
update membership_plans
set hours_included = 15, max_members = 30
where name = 'GAMER' and hours_included = 0;

update membership_plans set popular = true where name = 'LEGEND';
