-- =====================================================================
-- GAMES GRID — row level security
-- Run after 02_functions.sql
--
-- Rule of thumb:
--   public   = anyone visiting the website, not signed in
--   customer = signed in with their phone
--   staff    = your team
--   owner    = you
--
-- Staff can run the shop. Only the owner sees money, pricing and users.
-- =====================================================================

alter table staff               enable row level security;
alter table customers           enable row level security;
alter table stations            enable row level security;
alter table pricing             enable row level security;
alter table addons              enable row level security;
alter table projector_slots     enable row level security;
alter table bookings            enable row level security;
alter table booking_addons      enable row level security;
alter table station_blocks      enable row level security;
alter table payments            enable row level security;
alter table games               enable row level security;
alter table membership_plans    enable row level security;
alter table memberships         enable row level security;
alter table loyalty_cards       enable row level security;
alter table loyalty_events      enable row level security;
alter table tournaments         enable row level security;
alter table tournament_entries  enable row level security;
alter table lap_times           enable row level security;
alter table vouchers            enable row level security;
alter table voucher_uses        enable row level security;
alter table referrals           enable row level security;
alter table expense_categories  enable row level security;
alter table expenses            enable row level security;
alter table day_closings        enable row level security;
alter table notifications       enable row level security;
alter table settings            enable row level security;
alter table audit_log           enable row level security;

-- ---------------------------------------------------------------------
-- PUBLIC READ — what the website shows before anyone signs in
-- ---------------------------------------------------------------------
create policy public_read on stations         for select using (true);
create policy public_read on pricing          for select using (active);
create policy public_read on addons           for select using (active);
create policy public_read on projector_slots  for select using (active);
create policy public_read on games            for select using (available);
create policy public_read on membership_plans for select using (active);
create policy public_read on tournaments      for select using (status <> 'draft');
create policy public_read on lap_times        for select using (true);

-- Opening hours and the WhatsApp number are public; nothing secret lives here.
create policy public_read on settings for select using (
  key in ('opening_hours','booking_window_days','hold_minutes','min_hours',
          'max_hours','whatsapp_number','contact_phone','contact_email','address')
);

-- ---------------------------------------------------------------------
-- STAFF
-- ---------------------------------------------------------------------
create policy staff_read_self on staff for select using (id = auth.uid() or is_owner());
create policy owner_manages   on staff for all    using (is_owner()) with check (is_owner());

-- ---------------------------------------------------------------------
-- CUSTOMERS
-- A customer sees only their own row. Staff see everyone.
-- ---------------------------------------------------------------------
create policy customer_self on customers for select
  using (auth_user_id = auth.uid() or is_staff());
create policy customer_update_self on customers for update
  using (auth_user_id = auth.uid()) with check (auth_user_id = auth.uid());
create policy staff_manage_customers on customers for all
  using (is_staff()) with check (is_staff());

-- ---------------------------------------------------------------------
-- BOOKINGS
-- Customers read their own. Nobody inserts directly — they call
-- hold_booking(), which is security definer and does the checks.
-- ---------------------------------------------------------------------
create policy customer_own_bookings on bookings for select using (
  is_staff() or customer_id in (select id from customers where auth_user_id = auth.uid())
);
create policy staff_manage_bookings on bookings for all
  using (is_staff()) with check (is_staff());

create policy read_booking_addons on booking_addons for select using (
  is_staff() or booking_id in (
    select b.id from bookings b join customers c on c.id = b.customer_id
    where c.auth_user_id = auth.uid())
);
create policy staff_manage_booking_addons on booking_addons for all
  using (is_staff()) with check (is_staff());

create policy staff_manage_blocks on station_blocks for all
  using (is_staff()) with check (is_staff());
create policy public_read_blocks on station_blocks for select using (true);

-- ---------------------------------------------------------------------
-- MONEY — owner only. Staff take payments through confirm_booking(),
-- which runs with elevated rights, but cannot browse the payments table.
-- ---------------------------------------------------------------------
create policy owner_reads_payments on payments for select using (is_owner());
create policy owner_manages_payments on payments for all
  using (is_owner()) with check (is_owner());
create policy customer_own_payments on payments for select using (
  customer_id in (select id from customers where auth_user_id = auth.uid())
);

create policy owner_only_expenses    on expenses          for all using (is_owner()) with check (is_owner());
create policy staff_read_categories  on expense_categories for select using (is_staff());
create policy owner_manages_categories on expense_categories for all using (is_owner()) with check (is_owner());
create policy owner_only_closings    on day_closings      for all using (is_owner()) with check (is_owner());

-- Pricing is business-critical: staff read, owner edits.
create policy staff_read_pricing on pricing for select using (is_staff());
create policy owner_edits_pricing on pricing for all using (is_owner()) with check (is_owner());
create policy owner_edits_addons  on addons  for all using (is_owner()) with check (is_owner());

-- ---------------------------------------------------------------------
-- CONTENT — staff can keep games and tournaments current
-- ---------------------------------------------------------------------
create policy staff_manage_games       on games       for all using (is_staff()) with check (is_staff());
create policy staff_manage_tournaments on tournaments for all using (is_staff()) with check (is_staff());
create policy staff_manage_laps        on lap_times   for all using (is_staff()) with check (is_staff());
create policy staff_manage_stations    on stations    for all using (is_staff()) with check (is_staff());
create policy staff_manage_slots       on projector_slots for all using (is_staff()) with check (is_staff());
create policy owner_manages_plans      on membership_plans for all using (is_owner()) with check (is_owner());

-- ---------------------------------------------------------------------
-- MEMBERSHIPS, LOYALTY, VOUCHERS, REFERRALS
-- ---------------------------------------------------------------------
create policy own_membership on memberships for select using (
  is_staff() or customer_id in (select id from customers where auth_user_id = auth.uid())
);
create policy staff_manage_memberships on memberships for all using (is_staff()) with check (is_staff());

create policy own_loyalty on loyalty_cards for select using (
  is_staff() or customer_id in (select id from customers where auth_user_id = auth.uid())
);
create policy staff_manage_loyalty on loyalty_cards  for all using (is_staff()) with check (is_staff());
create policy staff_manage_events  on loyalty_events for all using (is_staff()) with check (is_staff());

create policy own_entries on tournament_entries for select using (
  is_staff() or customer_id in (select id from customers where auth_user_id = auth.uid())
);
create policy staff_manage_entries on tournament_entries for all using (is_staff()) with check (is_staff());

create policy own_vouchers on vouchers for select using (
  is_staff() or purchased_by in (select id from customers where auth_user_id = auth.uid())
);
create policy staff_manage_vouchers on vouchers    for all using (is_staff()) with check (is_staff());
create policy staff_manage_uses     on voucher_uses for all using (is_staff()) with check (is_staff());

create policy own_referrals on referrals for select using (
  is_staff() or referrer_id in (select id from customers where auth_user_id = auth.uid())
);
create policy staff_manage_referrals on referrals for all using (is_staff()) with check (is_staff());

-- ---------------------------------------------------------------------
-- INTERNAL — no client ever reads these directly
-- ---------------------------------------------------------------------
create policy owner_reads_notifications on notifications for select using (is_owner());
create policy owner_reads_audit on audit_log for select using (is_owner());
create policy owner_edits_settings on settings for all using (is_owner()) with check (is_owner());

-- ---------------------------------------------------------------------
-- Let the public call the booking functions
-- ---------------------------------------------------------------------
grant execute on function free_stations(station_kind, timestamptz, timestamptz) to anon, authenticated;
grant execute on function day_availability(station_kind, date, numeric)          to anon, authenticated;
grant execute on function quote_booking(station_kind, numeric, boolean, date)    to anon, authenticated;
grant execute on function hold_booking(station_kind, timestamptz, numeric, text, text, text, smallint, boolean, uuid, booking_source) to anon, authenticated;

-- confirm_booking is NOT granted to anon. Only the payment webhook
-- (service role) or signed-in staff may confirm a booking.
grant execute on function confirm_booking(uuid, pay_method, text, uuid) to authenticated;
grant execute on function release_expired_holds() to authenticated;
