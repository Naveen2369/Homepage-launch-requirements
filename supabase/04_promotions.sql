-- =====================================================================
-- GAMES GRID — promotions
-- Run in the Supabase SQL editor, after 03_policies.sql
-- Drives the rotating offer bar on the website.
-- =====================================================================

create table if not exists promotions (
  id          uuid primary key default gen_random_uuid(),
  message     text not null,
  detail      text,
  link_url    text,
  accent      text not null default 'purple',   -- purple | blue | green | amber
  starts_on   date,
  ends_on     date,
  active      boolean not null default true,
  sort_order  smallint not null default 0,
  created_at  timestamptz not null default now()
);

alter table promotions enable row level security;

create policy public_read on promotions for select using (
  active
  and (starts_on is null or current_date >= starts_on)
  and (ends_on   is null or current_date <= ends_on)
);

create policy staff_manage_promotions on promotions for all
  using (is_staff()) with check (is_staff());

-- Seeded inactive: switch them on in the admin panel when you're ready.
insert into promotions (message, detail, accent, active, sort_order) values
  ('OPENING MONTH OFFER', 'PS5 from ₹99/hr · Simulator from ₹129/hr', 'purple', false, 1),
  ('PRIVATE PROJECTOR ROOM', '₹1,299 for 3 hours · up to 5 people', 'blue', false, 2);
