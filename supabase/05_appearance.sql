-- =====================================================================
-- GAMES GRID — appearance settings
-- Run in the Supabase SQL editor, after 04_promotions.sql
-- Lets the admin panel restyle the website without code changes.
-- =====================================================================

insert into settings (key, value) values
  ('theme_purple',        '"#8B2CFF"'),
  ('theme_blue',          '"#1677FF"'),
  ('theme_neon',          '"#B026FF"'),
  ('theme_highlight',     '"#00A8FF"'),
  ('theme_bg',            '"#050509"'),
  ('theme_bg2',           '"#0B0B12"'),
  ('theme_card',          '"#11111A"'),
  ('theme_head_font',     '"Orbitron"'),
  ('theme_body_font',     '"Inter"'),
  ('theme_num_font',      '"Rajdhani"'),
  ('theme_hero_image',    '""'),
  ('theme_header_logo',   '""'),
  ('theme_ps5_image',     '""'),
  ('theme_sim_image',     '""'),
  ('theme_room_image',    '""'),
  ('theme_games_bg',      '""'),
  ('theme_tournament_bg', '""'),
  ('theme_cta_image',     '""')
on conflict (key) do nothing;

-- The website reads these without signing in.
drop policy if exists public_read on settings;
create policy public_read on settings for select using (
  key in ('opening_hours','booking_window_days','hold_minutes','min_hours',
          'max_hours','whatsapp_number','contact_phone','contact_email','address')
  or key like 'theme_%'
);

-- Writes a setting as a JSON string, creating it if missing.
create or replace function set_setting(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_staff() then
    raise exception 'Not authorised';
  end if;
  insert into settings (key, value, updated_at)
  values (p_key, to_jsonb(p_value), now())
  on conflict (key) do update
    set value = to_jsonb(p_value), updated_at = now();
end;
$$;

grant execute on function set_setting(text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Image storage — website images uploaded from the admin panel
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('site', 'site', true)
on conflict (id) do nothing;

drop policy if exists "site images are public" on storage.objects;
create policy "site images are public"
  on storage.objects for select
  using (bucket_id = 'site');

drop policy if exists "staff upload site images" on storage.objects;
create policy "staff upload site images"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'site' and is_staff());

drop policy if exists "staff replace site images" on storage.objects;
create policy "staff replace site images"
  on storage.objects for update to authenticated
  using (bucket_id = 'site' and is_staff());

drop policy if exists "staff delete site images" on storage.objects;
create policy "staff delete site images"
  on storage.objects for delete to authenticated
  using (bucket_id = 'site' and is_staff());
