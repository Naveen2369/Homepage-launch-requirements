-- =====================================================================
-- GAMES GRID — Google review link
-- Run in the Supabase SQL editor. Safe to re-run.
--
-- Reviews live on your Google Business Profile, not in this database.
-- This stores the link the website's "LEAVE A GOOGLE REVIEW" button opens.
--
-- Where to find it:
--   Google Business Profile → Read reviews → Get more reviews → copy link
--   It looks like  https://g.page/r/XXXXXXXXXXXX/review
-- =====================================================================

insert into settings (key, value)
values ('google_review_url', '""'::jsonb)
on conflict (key) do nothing;

-- The website reads this without signing in.
drop policy if exists public_read on settings;
create policy public_read on settings for select using (
  key in ('opening_hours','booking_window_days','hold_minutes','min_hours',
          'max_hours','whatsapp_number','contact_phone','contact_email',
          'address','promo_display','google_review_url')
  or key like 'theme_%'
);
