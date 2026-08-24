-- =====================================================================
-- GAMES GRID — offer bar display mode
-- Run in the Supabase SQL editor. Safe to re-run.
--
-- Adds a site-wide choice between a fading rotation and a continuous
-- marquee, plus a speed control for both.
-- =====================================================================

insert into settings (key, value)
values ('promo_display', '{"mode":"fade","speed":5}'::jsonb)
on conflict (key) do nothing;

-- mode  : 'fade'   — one promotion at a time, cross-fading
--         'scroll' — all promotions in one continuous marquee
-- speed : seconds each promotion is shown (fade)
--         or seconds per promotion of travel (scroll)

-- The WEBSITE reads this key without signing in, so it has to be in the
-- public allow-list — otherwise the saved mode never reaches visitors and
-- the bar silently falls back to fading.
drop policy if exists public_read on settings;
create policy public_read on settings for select using (
  key in ('opening_hours','booking_window_days','hold_minutes','min_hours',
          'max_hours','whatsapp_number','contact_phone','contact_email',
          'address','promo_display')
  or key like 'theme_%'
);
