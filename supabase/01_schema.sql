-- =====================================================================
-- GAMES GRID — Supabase schema
-- Run this first, in the Supabase SQL editor.
-- Money is stored in paise (integer). ₹99 = 9900. Never use floats.
-- =====================================================================

create extension if not exists "pgcrypto";
create extension if not exists "btree_gist";   -- needed for the no-double-booking rule

-- ---------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------
create type station_kind    as enum ('ps5', 'simulator', 'projector');
create type station_state   as enum ('active', 'blocked', 'maintenance');
create type booking_state   as enum ('held', 'confirmed', 'arrived', 'completed', 'cancelled', 'no_show', 'expired');
create type booking_source  as enum ('online', 'walkin', 'admin');
create type pay_state       as enum ('pending', 'paid', 'failed', 'refunded', 'pay_at_counter');
create type pay_method      as enum ('cash', 'upi', 'card', 'voucher', 'credit', 'other');
create type staff_role      as enum ('owner', 'staff');
create type tourney_state   as enum ('draft', 'registration_open', 'almost_full', 'registration_closed', 'live', 'completed', 'cancelled');

-- ---------------------------------------------------------------------
-- STAFF
-- Each row links a Supabase auth user to a role.
-- ---------------------------------------------------------------------
create table staff (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  role        staff_role not null default 'staff',
  phone       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- CUSTOMERS
-- Phone is the identity. auth_user_id is set only if they make an account.
-- ---------------------------------------------------------------------
create table customers (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  full_name     text not null,
  phone         text not null unique,          -- store as 10 digits, no +91
  email         text,
  notes         text,                          -- staff-only notes
  credit_paise  integer not null default 0,    -- referral / goodwill credit
  created_at    timestamptz not null default now(),
  constraint phone_is_10_digits check (phone ~ '^[0-9]{10}$')
);
create index on customers (phone);
create index on customers (lower(full_name));

-- ---------------------------------------------------------------------
-- STATIONS — the 7 PS5s, 2 simulators, 1 projector room
-- ---------------------------------------------------------------------
create table stations (
  id           uuid primary key default gen_random_uuid(),
  kind         station_kind not null,
  code         text not null unique,           -- 'PS5 #1', 'SIM #2', 'ROOM'
  capacity     smallint not null default 1,    -- 1 for PS5/sim, 5 for the room
  state        station_state not null default 'active',
  sort_order   smallint not null default 0
);

-- ---------------------------------------------------------------------
-- PRICING — editable from the admin panel, never hard-coded in the site
-- ---------------------------------------------------------------------
create table pricing (
  id                uuid primary key default gen_random_uuid(),
  kind              station_kind not null,
  label             text not null,
  standard_paise    integer not null,          -- regular price
  offer_paise       integer,                   -- opening / promo price, null = no offer
  offer_starts_on   date,
  offer_ends_on     date,
  unit              text not null default 'hour',  -- 'hour' or 'slot'
  active            boolean not null default true,
  updated_at        timestamptz not null default now()
);

-- Add-ons like the extra controller. Billed per hour when per_hour = true.
create table addons (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,            -- 'extra_controller'
  label       text not null,
  price_paise integer not null,
  per_hour    boolean not null default true,
  applies_to  station_kind,
  active      boolean not null default true
);

-- ---------------------------------------------------------------------
-- PROJECTOR SLOTS — the three fixed 3-hour windows
-- ---------------------------------------------------------------------
create table projector_slots (
  id          uuid primary key default gen_random_uuid(),
  label       text not null,                   -- '11:30 AM – 2:30 PM'
  starts_at   time not null,
  ends_at     time not null,
  active      boolean not null default true,
  sort_order  smallint not null default 0
);

-- ---------------------------------------------------------------------
-- BOOKINGS
--
-- The exclusion constraint at the bottom is the important part: Postgres
-- itself refuses to store two overlapping bookings on the same station.
-- Two people paying at the same instant cannot both get the slot.
-- ---------------------------------------------------------------------
create table bookings (
  id              uuid primary key default gen_random_uuid(),
  reference       text not null unique default 'GG-' || upper(substr(md5(random()::text), 1, 6)),
  customer_id     uuid not null references customers(id) on delete restrict,
  station_id      uuid not null references stations(id) on delete restrict,
  kind            station_kind not null,

  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  duration_hours  numeric(3,1) not null,
  people          smallint not null default 1,

  status          booking_state not null default 'held',
  source          booking_source not null default 'online',

  base_paise      integer not null default 0,
  addons_paise    integer not null default 0,
  discount_paise  integer not null default 0,
  total_paise     integer not null default 0,
  payment_status  pay_state not null default 'pending',

  hold_expires_at timestamptz,                 -- set while status = 'held'
  arrived_at      timestamptz,
  completed_at    timestamptz,
  cancel_reason   text,

  created_by      uuid references staff(id),   -- null for online self-service
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  slot tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,

  constraint ends_after_start check (ends_at > starts_at),
  constraint sane_total check (total_paise >= 0),

  -- No two live bookings may overlap on one station.
  constraint no_double_booking exclude using gist (
    station_id with =,
    slot with &&
  ) where (status in ('held', 'confirmed', 'arrived'))
);
create index on bookings (starts_at);
create index on bookings (customer_id);
create index on bookings (status) where status in ('held', 'confirmed');

create table booking_addons (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings(id) on delete cascade,
  addon_id    uuid not null references addons(id),
  quantity    smallint not null default 1,
  price_paise integer not null                -- price at time of booking
);

-- Blocking a station for maintenance, a private event, or staff training.
create table station_blocks (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references stations(id) on delete cascade,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  reason      text,
  created_by  uuid references staff(id),
  created_at  timestamptz not null default now(),
  slot tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  constraint block_ends_after_start check (ends_at > starts_at)
);
create index on station_blocks using gist (station_id, slot);

-- ---------------------------------------------------------------------
-- PAYMENTS
-- One booking can have several payment rows (part cash, part UPI, refunds).
-- gateway_* columns stay null until Razorpay is live.
-- ---------------------------------------------------------------------
create table payments (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid references bookings(id) on delete set null,
  customer_id      uuid references customers(id) on delete set null,
  amount_paise     integer not null,
  method           pay_method not null,
  status           pay_state not null default 'pending',
  gateway          text,                        -- 'razorpay' later
  gateway_order_id text,
  gateway_payment_id text unique,
  received_by      uuid references staff(id),   -- who took the cash
  paid_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index on payments (booking_id);
create index on payments (paid_at);

-- ---------------------------------------------------------------------
-- GAMES — the Pick Your Game grid, editable from admin
-- ---------------------------------------------------------------------
create table games (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  genre       text not null,                   -- RACING, SPORTS, SHOOTER, FIGHTING, ADVENTURE
  art_path    text,                            -- Supabase Storage path
  platform    text not null default 'PS5',
  available   boolean not null default true,
  sort_order  smallint not null default 0
);

-- ---------------------------------------------------------------------
-- MEMBERSHIPS
-- ---------------------------------------------------------------------
create table membership_plans (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,                -- GAMER / LEGEND / ELITE
  price_paise    integer,                      -- null until you confirm pricing
  duration_days  smallint not null default 30,
  benefits       jsonb not null default '[]',
  popular        boolean not null default false,
  active         boolean not null default true,
  sort_order     smallint not null default 0
);

create table memberships (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete cascade,
  plan_id     uuid not null references membership_plans(id),
  starts_on   date not null default current_date,
  ends_on     date not null,
  active      boolean not null default true,
  payment_id  uuid references payments(id),
  created_at  timestamptz not null default now()
);
create index on memberships (customer_id) where active;

-- ---------------------------------------------------------------------
-- LOYALTY — the physical card stays; this records it so you have history
-- Play 9 hours, 10th hour free.
-- ---------------------------------------------------------------------
create table loyalty_cards (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references customers(id) on delete cascade,
  card_number   text unique,                   -- printed on the physical card
  stamps        smallint not null default 0,
  rewards_used  smallint not null default 0,
  created_at    timestamptz not null default now(),
  constraint stamps_in_range check (stamps between 0 and 10)
);

create table loyalty_events (
  id          uuid primary key default gen_random_uuid(),
  card_id     uuid not null references loyalty_cards(id) on delete cascade,
  booking_id  uuid references bookings(id) on delete set null,
  delta       smallint not null,               -- +1 stamp, -10 on redeem
  note        text,
  staff_id    uuid references staff(id),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- TOURNAMENTS
-- ---------------------------------------------------------------------
create table tournaments (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  game              text not null,
  format            text,                      -- 'Team of 2', 'Fastest lap'
  starts_at         timestamptz,
  entry_fee_paise   integer,
  prize_text        text,
  max_entries       smallint,
  team_size         smallint not null default 1,
  registration_ends_at timestamptz,
  rules             text,
  status            tourney_state not null default 'draft',
  banner_path       text,
  created_at        timestamptz not null default now()
);

create table tournament_entries (
  id             uuid primary key default gen_random_uuid(),
  tournament_id  uuid not null references tournaments(id) on delete cascade,
  customer_id    uuid not null references customers(id) on delete cascade,
  team_name      text,
  players        jsonb not null default '[]',  -- [{name, phone}]
  payment_id     uuid references payments(id),
  confirmed      boolean not null default false,
  created_at     timestamptz not null default now(),
  unique (tournament_id, customer_id)
);

-- Fastest lap leaderboard
create table lap_times (
  id             uuid primary key default gen_random_uuid(),
  tournament_id  uuid references tournaments(id) on delete cascade,
  customer_id    uuid references customers(id) on delete set null,
  display_name   text not null,
  lap_ms         integer not null,             -- 92341 = 1:32.341
  track          text,
  recorded_by    uuid references staff(id),
  recorded_at    timestamptz not null default now()
);
create index on lap_times (tournament_id, lap_ms);

-- ---------------------------------------------------------------------
-- GIFT VOUCHERS
-- ---------------------------------------------------------------------
create table vouchers (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique,
  value_paise    integer not null,
  balance_paise  integer not null,
  purchased_by   uuid references customers(id) on delete set null,
  recipient_name text,
  recipient_phone text,
  expires_on     date,
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

create table voucher_uses (
  id          uuid primary key default gen_random_uuid(),
  voucher_id  uuid not null references vouchers(id) on delete cascade,
  booking_id  uuid references bookings(id) on delete set null,
  amount_paise integer not null,
  used_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- REFERRALS — ₹30 each side, credited after the friend's first paid booking
-- ---------------------------------------------------------------------
create table referrals (
  id            uuid primary key default gen_random_uuid(),
  referrer_id   uuid not null references customers(id) on delete cascade,
  referred_id   uuid references customers(id) on delete set null,
  code          text not null,
  reward_paise  integer not null default 3000,
  rewarded      boolean not null default false,
  rewarded_at   timestamptz,
  created_at    timestamptz not null default now()
);
create index on referrals (code);

-- ---------------------------------------------------------------------
-- FINANCE — shop and gaming together, as you asked
-- ---------------------------------------------------------------------
create table expense_categories (
  id     uuid primary key default gen_random_uuid(),
  name   text not null unique,
  active boolean not null default true
);

create table expenses (
  id           uuid primary key default gen_random_uuid(),
  category_id  uuid not null references expense_categories(id),
  amount_paise integer not null,
  spent_on     date not null default current_date,
  note         text,
  paid_by      pay_method not null default 'cash',
  receipt_path text,
  staff_id     uuid references staff(id),
  created_at   timestamptz not null default now()
);
create index on expenses (spent_on);

-- End-of-day counter reconciliation
create table day_closings (
  id               uuid primary key default gen_random_uuid(),
  business_date    date not null unique,
  counter_cash_paise integer not null default 0,
  online_paise     integer not null default 0,
  other_paise      integer not null default 0,
  expenses_paise   integer not null default 0,
  note             text,
  closed_by        uuid references staff(id),
  closed_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- NOTIFICATIONS — outbox. A worker reads 'queued' rows and sends them.
-- ---------------------------------------------------------------------
create table notifications (
  id          uuid primary key default gen_random_uuid(),
  channel     text not null,                   -- 'whatsapp' | 'email'
  template    text not null,                   -- 'booking_confirmed', 'reminder_24h'
  to_address  text not null,
  payload     jsonb not null default '{}',
  booking_id  uuid references bookings(id) on delete cascade,
  status      text not null default 'queued',  -- queued | sent | failed
  send_after  timestamptz not null default now(),
  sent_at     timestamptz,
  error       text,
  created_at  timestamptz not null default now()
);
create index on notifications (status, send_after);

-- ---------------------------------------------------------------------
-- SETTINGS — opening hours, WhatsApp number, booking window, etc.
-- ---------------------------------------------------------------------
create table settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- AUDIT — who changed what
-- ---------------------------------------------------------------------
create table audit_log (
  id          bigserial primary key,
  staff_id    uuid references staff(id),
  action      text not null,
  entity      text not null,
  entity_id   uuid,
  detail      jsonb,
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- SEED DATA
-- =====================================================================
insert into stations (kind, code, capacity, sort_order) values
  ('ps5', 'PS5 #1', 1, 1), ('ps5', 'PS5 #2', 1, 2), ('ps5', 'PS5 #3', 1, 3),
  ('ps5', 'PS5 #4', 1, 4), ('ps5', 'PS5 #5', 1, 5), ('ps5', 'PS5 #6', 1, 6),
  ('ps5', 'PS5 #7', 1, 7),
  ('simulator', 'SIM #1', 1, 8), ('simulator', 'SIM #2', 1, 9),
  ('projector', 'ROOM', 5, 10);

insert into pricing (kind, label, standard_paise, offer_paise, unit) values
  ('ps5',       'PS5 Gaming',            12900,  9900, 'hour'),
  ('simulator', 'Racing Simulator',      14900, 12900, 'hour'),
  ('projector', 'Private Projector Room',149900,129900,'slot');

insert into addons (code, label, price_paise, per_hour, applies_to) values
  ('extra_controller', 'Extra controller', 6900, true, 'ps5');

insert into projector_slots (label, starts_at, ends_at, sort_order) values
  ('11:30 AM – 2:30 PM', '11:30', '14:30', 1),
  ('3:00 PM – 6:00 PM',  '15:00', '18:00', 2),
  ('6:30 PM – 9:30 PM',  '18:30', '21:30', 3);

insert into expense_categories (name) values
  ('Salaries'), ('Electricity'), ('Rent'), ('Food & drinks'),
  ('Gaming equipment'), ('Maintenance'), ('Supplies'), ('Marketing'), ('Other');

insert into membership_plans (name, benefits, popular, sort_order) values
  ('GAMER',  '["Member pricing on PS5 hours","Special offers on snacks & drinks","Loyalty card stamps","Event invites"]', false, 1),
  ('LEGEND', '["Everything in Gamer","Priority booking","Birthday benefit","Tournament priority entry","Exclusive member offers"]', true, 2),
  ('ELITE',  '["Everything in Legend","Best member rate on all experiences","Private room priority slots","Guaranteed tournament seat","Dedicated support on WhatsApp"]', false, 3);

insert into settings (key, value) values
  ('opening_hours',      '{"open":"07:00","close":"22:00"}'),
  ('booking_window_days','30'),
  ('hold_minutes',       '10'),
  ('min_hours',          '1'),
  ('max_hours',          '5'),
  ('whatsapp_number',    '""'),
  ('contact_phone',      '""'),
  ('contact_email',      '""'),
  ('address',            '"Near Vignan College"'),
  ('referral_paise',     '3000'),
  ('payments_live',      'false');
