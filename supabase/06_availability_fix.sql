-- =====================================================================
-- GAMES GRID — availability + privacy fix
-- Run this in the Supabase SQL editor. Safe to re-run.
--
-- Fixes two things:
--   1. Availability always said "free". free_stations ran under the
--      caller's permissions, and the public website cannot read the
--      bookings table — so it never saw a clash. Now it runs with
--      trusted permissions, read-only, on explicit arguments.
--   2. Daily takings were readable by anyone. The dashboard views now
--      obey row security, so only signed-in staff can read them.
-- =====================================================================

-- 1. AVAILABILITY -----------------------------------------------------
create or replace function free_stations(
  p_kind      station_kind,
  p_starts_at timestamptz,
  p_ends_at   timestamptz
)
returns table (id uuid, code text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.code
  from stations s
  where s.kind = p_kind
    and s.state = 'active'
    and not exists (
      select 1 from bookings b
      where b.station_id = s.id
        and b.status in ('held', 'confirmed', 'arrived')
        and b.slot && tstzrange(p_starts_at, p_ends_at, '[)')
    )
    and not exists (
      select 1 from station_blocks k
      where k.station_id = s.id
        and k.slot && tstzrange(p_starts_at, p_ends_at, '[)')
    )
  order by s.sort_order;
$$;

create or replace function day_availability(
  p_kind  station_kind,
  p_date  date,
  p_hours numeric default 1
)
returns table (hour_start timestamptz, free_count integer)
language sql
stable
security definer
set search_path = public
as $$
  with hours as (
    select generate_series(
      (p_date + (setting('opening_hours')->>'open')::time) at time zone 'Asia/Kolkata',
      (p_date + (setting('opening_hours')->>'close')::time) at time zone 'Asia/Kolkata'
        - (p_hours || ' hours')::interval,
      interval '1 hour'
    ) as h
  )
  select h.h,
         (select count(*)::integer
          from free_stations(p_kind, h.h, h.h + (p_hours || ' hours')::interval))
  from hours h
  order by h.h;
$$;

grant execute on function free_stations(station_kind, timestamptz, timestamptz) to anon, authenticated;
grant execute on function day_availability(station_kind, date, numeric)          to anon, authenticated;
grant execute on function quote_booking(station_kind, numeric, boolean, date)    to anon, authenticated;

-- 2. DASHBOARD VIEWS — staff only -------------------------------------
alter view v_today          set (security_invoker = true);
alter view v_daily_report   set (security_invoker = true);
alter view v_station_status  set (security_invoker = true);
