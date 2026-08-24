# Games Grid — backend setup

Everything here runs on Supabase. Three SQL files, run in order, and you have
a working database with real availability, no double bookings, and an admin
that can change prices without touching code.

---

## 1. Create the project

1. Go to supabase.com, create a project.
2. Region: **Mumbai (ap-south-1)** — closest to your customers.
3. Save the database password somewhere safe. You cannot recover it.

## 2. Run the SQL

Open the SQL editor in Supabase and run these in order. Each one should
finish with "Success".

| Order | File | What it does |
|---|---|---|
| 1 | `01_schema.sql` | Tables, and seeds your 7 PS5s, 2 simulators, 1 room, prices, expense categories |
| 2 | `02_functions.sql` | Availability, price quotes, hold and confirm logic |
| 3 | `03_policies.sql` | Who can see and change what |

## 3. Make yourself the owner

Create your login under **Authentication → Users → Add user** (email +
password). Copy the user id it gives you, then run:

```sql
insert into staff (id, full_name, role)
values ('paste-the-user-id-here', 'Your name', 'owner');
```

Add staff the same way with `'staff'` instead of `'owner'`.

## 4. Expire abandoned holds

Under **Database → Extensions**, enable `pg_cron`, then run:

```sql
select cron.schedule('release-holds', '* * * * *', 'select release_expired_holds()');
```

Without this, a customer who starts payment and closes the tab keeps the slot
blocked forever.

## 5. Connect the website

In **Project Settings → API**, copy the project URL and the `anon` key. Those
two are safe in the website's code. The `service_role` key is not — it bypasses
every security rule and belongs only on a server.

---

## How booking works

Four steps, and the important one is that the website never decides
availability. It asks the database.

```
1. Customer picks date + duration
   → day_availability('ps5', '2026-09-04', 2)
   returns each hour with how many PS5s are free for the full 2 hours

2. Customer picks a start time
   → free_stations('ps5', starts, ends)
   returns the actual free stations, so you can show "PS5 #3 — booked"

3. Customer presses "Hold slot & pay"
   → hold_booking(...)
   writes a held row, assigns a station, starts a 10-minute clock

4. Payment succeeds
   → confirm_booking(booking_id, 'upi', ...)
   marks it confirmed and queues the WhatsApp messages
```

### Why double booking cannot happen

The `bookings` table has this constraint:

```sql
exclude using gist (station_id with =, slot with &&)
  where (status in ('held', 'confirmed', 'arrived'))
```

Postgres itself refuses to store two overlapping rows on the same station.
If two customers hit "pay" for the last PS5 in the same millisecond, one
insert succeeds and the other gets an error. There is no window where both
succeed. This is why we use Postgres rather than a simpler database.

### Example calls from the website

```js
// how many PS5s are free each hour, for a 2-hour session
const { data } = await supabase.rpc('day_availability', {
  p_kind: 'ps5', p_date: '2026-09-04', p_hours: 2
})

// what will it cost
const { data: quote } = await supabase.rpc('quote_booking', {
  p_kind: 'ps5', p_hours: 2, p_extra_controller: true
})

// hold it
const { data: booking, error } = await supabase.rpc('hold_booking', {
  p_kind: 'ps5',
  p_starts_at: '2026-09-04T15:00:00+05:30',
  p_hours: 2,
  p_full_name: 'Ravi',
  p_phone: '9876543210',
  p_extra_controller: true
})
// error.message will say "No ps5 available for that time" if someone beat them to it
```

---

## Money

All amounts are stored in **paise as whole numbers**. ₹99 is `9900`.
Never store rupees as a decimal — floating point arithmetic loses paise and
your day-end totals stop matching the counter.

Display: `(paise / 100).toLocaleString('en-IN')`

---

## Payments — before and after Razorpay

You do not have Razorpay yet, and the system works without it.

**Now.** Customers book online and pay at the counter. Set the booking's
payment method to `pay_at_counter`, and staff confirm it in admin when the
customer arrives and pays. Nothing in the schema needs to change.

To make this the default:

```sql
update settings set value = 'false' where key = 'payments_live';
```

**When your GST and KYC come through.** Add Razorpay in three steps:

1. Create a Razorpay order when the customer presses pay, store the order id
   on the `payments` row.
2. Write a Supabase **edge function** that Razorpay calls when payment
   completes. It verifies the signature, then calls `confirm_booking()`.
3. Flip `payments_live` to `true`.

One rule worth stating plainly: **confirm the booking from the webhook, never
from the customer's browser.** If you confirm in the browser, a customer who
closes the tab mid-payment ends up paying with no booking recorded, or worse,
someone can fake a confirmation. The webhook is the only trustworthy signal.
This is why `confirm_booking` is not granted to `anon`.

---

## WhatsApp and email

`confirm_booking()` writes rows into the `notifications` table rather than
sending anything itself. Confirmation goes out immediately; reminders are
queued for 24 hours and 1 hour before the slot.

A small worker — a Supabase edge function on a schedule — reads rows where
`status = 'queued'` and `send_after <= now()`, sends them, and marks them
`sent`. Swap the provider (AiSensy, Interakt, Twilio) by changing that one
function; nothing else in the system knows or cares.

Until you set that up, the rows simply accumulate, and staff can send messages
by hand. Nothing breaks.

---

## What the admin panel edits

None of these need a developer once the panel is built:

| Table | What you change |
|---|---|
| `pricing` | Hourly rates, opening offers, offer start and end dates |
| `addons` | Extra controller price |
| `games` | Add or remove titles, upload artwork |
| `tournaments` | Create events, set fees and prizes, open and close registration |
| `membership_plans` | Tier pricing and benefits |
| `settings` | Opening hours, hold duration, booking window, contact details |
| `stations` | Block a PS5 for maintenance |
| `expenses` | Daily costs by category |

---

## Roles

**Owner** — everything, including payments, expenses, pricing and staff.

**Staff** — bookings, walk-ins, customers, games, tournaments, blocking a
station. They cannot browse the payments table, edit prices, see expenses,
or add users. They can still take payment through `confirm_booking()`,
which records who received it.

---

## Before you go live

- Turn on **Point in Time Recovery** (paid plan). Booking data is your business.
- Set the project timezone expectation: all times are stored as
  `timestamptz` and the availability functions assume **Asia/Kolkata**.
- Test the double-booking guard: open two browsers, hold the same last PS5
  slot in both. One must fail.
- Test a hold expiring: hold a slot, wait 11 minutes, confirm it becomes
  available again.
- Have someone local check the terms, refund policy and privacy text against
  Indian consumer law.

---

## Storage buckets

Create two under **Storage**:

- `game-art` — public. Game key art, 900 × 1200.
- `venue` — public. Interior photos.

Then `games.art_path` holds the file path and the site builds the URL. Upload
new artwork from admin without touching code.

---

## Files

```
supabase/
  01_schema.sql      tables, constraints, seed data
  02_functions.sql   availability, quotes, hold, confirm, loyalty, reports
  03_policies.sql    row level security and function grants
```
