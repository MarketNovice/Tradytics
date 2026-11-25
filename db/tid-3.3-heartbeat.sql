-- TID-3.3 Heartbeat: trading calendar, expected scans, watchdog checks, canary alerts
-- Idempotent: safe to re-run. Requires: schema tid, tid.tid_scan_runs.
--
-- What it adds
--   1. tid.tid_hb_calendar_exceptions  NYSE full closures and early closes (2026-2027 seeded).
--   2. Calendar functions              is_trading_day, session_open_at, session_close_at,
--                                      prev_trading_day, next_trading_day.
--   3. tid.tid_hb_expected_scans       which scans must exist each trading day, and by when (ET).
--   4. tid.tid_hb_watchdog_runs        append-only log of every watchdog execution and its findings.
--   5. tid.hb_check(...)               the check the independent watchdog calls; reports only findings
--                                      not already reported in the last 7 days, so one outage alerts once.
--   6. Canary                          hb_check(p_canary => true) always raises a finding, to prove the
--                                      alert reaches a person; tid.hb_ack_canary records that it did.

-- ------------------------------------------------------------------ 1. calendar
create table if not exists tid.tid_hb_calendar_exceptions (
  exception_date date primary key,
  kind           text not null check (kind in ('closed', 'early_close')),
  early_close_et time,
  note           text not null,
  source         text not null default 'NYSE published holiday calendar',
  constraint tid_hb_calendar_early_close_time
    check ((kind = 'early_close') = (early_close_et is not null))
);

-- NYSE 2026-2027. Verify against https://www.nyse.com/markets/hours-calendars before relying on 2027.
insert into tid.tid_hb_calendar_exceptions (exception_date, kind, early_close_et, note) values
  ('2026-01-01', 'closed', null, 'New Year''s Day'),
  ('2026-01-19', 'closed', null, 'Martin Luther King Jr. Day'),
  ('2026-02-16', 'closed', null, 'Washington''s Birthday'),
  ('2026-04-03', 'closed', null, 'Good Friday'),
  ('2026-05-25', 'closed', null, 'Memorial Day'),
  ('2026-06-19', 'closed', null, 'Juneteenth'),
  ('2026-07-03', 'closed', null, 'Independence Day (observed)'),
  ('2026-09-07', 'closed', null, 'Labor Day'),
  ('2026-11-26', 'closed', null, 'Thanksgiving Day'),
  ('2026-11-27', 'early_close', '13:00', 'Day after Thanksgiving'),
  ('2026-12-24', 'early_close', '13:00', 'Christmas Eve'),
  ('2026-12-25', 'closed', null, 'Christmas Day'),
  ('2027-01-01', 'closed', null, 'New Year''s Day'),
  ('2027-01-18', 'closed', null, 'Martin Luther King Jr. Day'),
  ('2027-02-15', 'closed', null, 'Washington''s Birthday'),
  ('2027-03-26', 'closed', null, 'Good Friday'),
  ('2027-05-31', 'closed', null, 'Memorial Day'),
  ('2027-06-18', 'closed', null, 'Juneteenth (observed)'),
  ('2027-07-05', 'closed', null, 'Independence Day (observed)'),
  ('2027-09-06', 'closed', null, 'Labor Day'),
  ('2027-11-25', 'closed', null, 'Thanksgiving Day'),
  ('2027-11-26', 'early_close', '13:00', 'Day after Thanksgiving'),
  ('2027-12-24', 'closed', null, 'Christmas Day (observed)')
on conflict (exception_date) do nothing;

-- ------------------------------------------------------------------ 2. calendar functions
create or replace function tid.is_trading_day(p_day date)
returns boolean language sql stable set search_path to '' as $$
  select extract(isodow from p_day) < 6
     and not exists (select 1 from tid.tid_hb_calendar_exceptions e
                     where e.exception_date = p_day and e.kind = 'closed');
$$;

create or replace function tid.session_open_at(p_day date)
returns timestamptz language sql stable set search_path to '' as $$
  select case when tid.is_trading_day(p_day)
              then (p_day + time '09:30') at time zone 'America/New_York' end;
$$;

create or replace function tid.session_close_at(p_day date)
returns timestamptz language sql stable set search_path to '' as $$
  select case when tid.is_trading_day(p_day)
              then (p_day + coalesce((select e.early_close_et from tid.tid_hb_calendar_exceptions e
                                      where e.exception_date = p_day and e.kind = 'early_close'),
                                     time '16:00')) at time zone 'America/New_York' end;
$$;

create or replace function tid.prev_trading_day(p_day date)
returns date language sql stable set search_path to '' as $$
  select d::date from generate_series(p_day - 1, p_day - 15, interval '-1 day') d
  where tid.is_trading_day(d::date) order by d desc limit 1;
$$;

create or replace function tid.next_trading_day(p_day date)
returns date language sql stable set search_path to '' as $$
  select d::date from generate_series(p_day + 1, p_day + 15, interval '1 day') d
  where tid.is_trading_day(d::date) order by d limit 1;
$$;

-- ------------------------------------------------------------------ 3. expected scans
create table if not exists tid.tid_hb_expected_scans (
  scan_type   text primary key,
  deadline_et time not null,           -- a completed run must exist by this ET time on each trading day
  required    boolean not null default true,
  note        text
);

insert into tid.tid_hb_expected_scans (scan_type, deadline_et, required, note) values
  ('morning',   '09:25', true, 'Bars, daily flow and pre-open OI chain; must finish before the open'),
  ('midday',    '13:45', true, 'Quotes, market, cohort flow'),
  ('afternoon', '16:00', true, 'Quotes, market, cohort flow'),
  ('oi',        '20:30', true, 'Evening OI chain capture, for TID-2.12 timing verification')
on conflict (scan_type) do nothing;

-- ------------------------------------------------------------------ 4. watchdog log
create table if not exists tid.tid_hb_watchdog_runs (
  watchdog_run_id bigint generated always as identity primary key,
  checked_at      timestamptz not null default clock_timestamp(),
  checker         text not null,
  is_canary       boolean not null default false,
  status          text not null check (status in ('ok', 'alert')),
  findings        jsonb not null default '[]'::jsonb,
  new_findings    jsonb not null default '[]'::jsonb
);
create index if not exists tid_hb_watchdog_runs_checked_idx on tid.tid_hb_watchdog_runs (checked_at desc);

create table if not exists tid.tid_hb_canary_acks (
  watchdog_run_id bigint primary key references tid.tid_hb_watchdog_runs (watchdog_run_id),
  acknowledged_at timestamptz not null default now(),
  channel         text not null,       -- how the alert arrived, e.g. 'github email', 'github issue'
  note            text
);

-- ------------------------------------------------------------------ 5. the check
create or replace function tid.hb_check(
  p_checker text default 'watchdog',
  p_canary  boolean default false,
  p_now     timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_today date := (p_now at time zone 'America/New_York')::date;
  v_days  date[];
  v_day   date;
  e       record;
  v_runs  record;
  f       jsonb := '[]'::jsonb;
  v_new   jsonb := '[]'::jsonb;
  x       jsonb;
  v_id    bigint;
begin
  -- Check today and the previous trading day, so a scan missed late in the day is still caught
  -- the next morning even if a watchdog run was skipped.
  v_days := array_remove(array[tid.prev_trading_day(v_today),
                               case when tid.is_trading_day(v_today) then v_today end], null);
  foreach v_day in array v_days loop
    for e in select * from tid.tid_hb_expected_scans where required order by deadline_et loop
      continue when ((v_day + e.deadline_et) at time zone 'America/New_York') > p_now;
      select count(*) filter (where s.ledger_write_status in ('written', 'complete')) as ok,
             count(*) filter (where s.ledger_write_status in ('written', 'complete')
                              and coalesce(s.run_metadata->>'snapshots', 'false') <> 'true') as ok_no_snap,
             count(*) as any_run,
             string_agg(distinct s.ledger_write_status, ',') as statuses
        into v_runs
        from tid.tid_scan_runs s
       where s.market_session = v_day
         and s.run_metadata->>'runner' = 'tid-runner'
         and s.run_metadata->>'scan_type' = e.scan_type;
      if v_runs.ok = 0 then
        f := f || jsonb_build_object(
               'code', case when v_runs.any_run = 0 then 'scan_missing' else 'scan_incomplete' end,
               'scan_type', e.scan_type, 'session', v_day, 'deadline_et', e.deadline_et,
               'statuses', v_runs.statuses);
      elsif v_runs.ok = v_runs.ok_no_snap then
        f := f || jsonb_build_object('code', 'snapshots_off', 'scan_type', e.scan_type, 'session', v_day);
      end if;
    end loop;
  end loop;

  if p_canary then
    f := f || jsonb_build_object('code', 'canary', 'note', 'Test alert. Acknowledge with tid.hb_ack_canary.');
  end if;

  -- A finding is new unless the same code/scan/session was reported in the last 7 days. Canaries are always new.
  for x in select value from jsonb_array_elements(f) loop
    if x->>'code' = 'canary' or not exists (
         select 1 from tid.tid_hb_watchdog_runs w, jsonb_array_elements(w.new_findings) old
          where w.checked_at > p_now - interval '7 days' and not w.is_canary
            and old->>'code' = x->>'code'
            and coalesce(old->>'scan_type', '') = coalesce(x->>'scan_type', '')
            and coalesce(old->>'session', '') = coalesce(x->>'session', '')) then
      v_new := v_new || x;
    end if;
  end loop;

  insert into tid.tid_hb_watchdog_runs (checked_at, checker, is_canary, status, findings, new_findings)
  values (clock_timestamp(), p_checker, p_canary,
          case when jsonb_array_length(f) = 0 then 'ok' else 'alert' end, f, v_new)
  returning watchdog_run_id into v_id;

  return jsonb_build_object('watchdog_run_id', v_id, 'checked_days', to_jsonb(v_days),
                            'findings', f, 'new_findings', v_new);
end;
$$;

create or replace function tid.hb_ack_canary(p_watchdog_run_id bigint, p_channel text, p_note text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not exists (select 1 from tid.tid_hb_watchdog_runs where watchdog_run_id = p_watchdog_run_id and is_canary) then
    raise exception 'watchdog run % is not a canary run', p_watchdog_run_id;
  end if;
  insert into tid.tid_hb_canary_acks (watchdog_run_id, channel, note)
  values (p_watchdog_run_id, p_channel, p_note) on conflict (watchdog_run_id) do nothing;
end;
$$;

-- ------------------------------------------------------------------ append-only guard on the watchdog log
create or replace function tid.trg_append_only()   -- same definition as in TID-3.2
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  raise exception '% is append-only (% rejected)', tg_table_name, tg_op;
end;
$$;
drop trigger if exists tid_hb_watchdog_runs_append_only on tid.tid_hb_watchdog_runs;
create trigger tid_hb_watchdog_runs_append_only
  before update or delete on tid.tid_hb_watchdog_runs
  for each row execute function tid.trg_append_only();

-- ------------------------------------------------------------------ access
alter table tid.tid_hb_calendar_exceptions enable row level security;
alter table tid.tid_hb_expected_scans      enable row level security;
alter table tid.tid_hb_watchdog_runs       enable row level security;
alter table tid.tid_hb_canary_acks         enable row level security;
revoke all on function tid.hb_check(text, boolean, timestamptz) from public;
revoke all on function tid.hb_ack_canary(bigint, text, text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function tid.hb_check(text, boolean, timestamptz) from anon, authenticated';
    execute 'revoke all on function tid.hb_ack_canary(bigint, text, text) from anon, authenticated';
  end if;
end $$;
