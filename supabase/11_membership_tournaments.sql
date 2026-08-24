-- =====================================================================
-- GAMES GRID — memberships & tournaments, editable from admin
-- Run in the Supabase SQL editor. Safe to re-run.
-- =====================================================================

-- The website reads plans and published tournaments without signing in.
drop policy if exists public_read_plans on membership_plans;
create policy public_read_plans on membership_plans for select using (active);

drop policy if exists public_read_tournaments on tournaments;
create policy public_read_tournaments on tournaments for select
  using (status <> 'draft');

-- Staff manage both.
drop policy if exists staff_plans on membership_plans;
create policy staff_plans on membership_plans for all
  using (is_staff()) with check (is_staff());

drop policy if exists staff_tournaments on tournaments;
create policy staff_tournaments on tournaments for all
  using (is_staff()) with check (is_staff());

-- Seed the three tiers with no price, so nothing is claimed before you
-- confirm it. Benefits are editable per line in admin.
insert into membership_plans (name, price_paise, duration_days, benefits, popular, active, sort_order)
values
  ('GAMER', null, 30,
   '["Member pricing on PS5 hours","Special offers on snacks & drinks","Loyalty card stamps","Event invites"]'::jsonb,
   false, true, 1),
  ('LEGEND', null, 30,
   '["Everything in Gamer","Priority booking","Birthday benefit","Tournament priority entry","Exclusive member offers"]'::jsonb,
   true, true, 2),
  ('ELITE', null, 30,
   '["Everything in Legend","Best member rate on all experiences","Private room priority slots","Guaranteed tournament seat","Dedicated support on WhatsApp"]'::jsonb,
   false, true, 3)
on conflict do nothing;

-- Section visibility — hide a section from the website until it is ready.
insert into settings (key, value)
values ('section_visibility', '{"membership":true,"tournaments":true}'::jsonb)
on conflict (key) do nothing;

drop policy if exists public_read on settings;
create policy public_read on settings for select using (
  key in ('opening_hours','booking_window_days','hold_minutes','min_hours',
          'max_hours','whatsapp_number','contact_phone','contact_email',
          'address','promo_display','google_review_url','section_visibility')
  or key like 'theme_%'
);
