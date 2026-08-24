-- =====================================================================
-- GAMES GRID — social links
-- Run in the Supabase SQL editor. Safe to re-run.
--
-- Instagram and Facebook links for the footer. Icons only appear on the
-- website once a link is saved in Admin → Settings.
-- =====================================================================

insert into settings (key, value) values
  ('instagram_url', '""'::jsonb),
  ('facebook_url',  '""'::jsonb)
on conflict (key) do nothing;

-- The website reads these without signing in.
drop policy if exists public_read on settings;
create policy public_read on settings for select using (
  key in ('opening_hours','booking_window_days','hold_minutes','min_hours',
          'max_hours','whatsapp_number','contact_phone','contact_email',
          'address','promo_display','google_review_url','section_visibility',
          'instagram_url','facebook_url')
  or key like 'theme_%'
);
