-- Dedicated login role for tid-runner and the TID-3.3 watchdog.
-- Created WITHOUT a password: it cannot log in until the owner sets one in the Supabase SQL editor:
--   alter role tid_runner with password '<long random password>';
-- Connection string (transaction pooler):
--   postgresql://tid_runner.<project-ref>:<password>@<pooler-host>:6543/postgres
--
-- What it can do: write scan runs, ingestion batches/records/watermarks and market bars (directly or through
-- the invoker-rights ingestion functions), read the trading calendar, and call the security-definer functions
-- capture_snapshot, record_oi_capture and hb_check. It cannot delete anything, read the snapshot, version,
-- OI vintage or watchdog tables directly, or touch any other schema.
-- Idempotent: safe to re-run.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'tid_runner') then
    create role tid_runner login noinherit connection limit 5;
  end if;
end $$;
alter role tid_runner set statement_timeout = '10min';
alter role tid_runner set search_path = '';

grant usage on schema tid to tid_runner;

-- Tables the runner writes directly or through invoker-rights functions
grant select, insert, update on tid.tid_scan_runs, tid.tid_ingestion_batches, tid.tid_ingestion_records,
  tid.tid_ingestion_watermarks, tid.tid_market_bars to tid_runner;
grant select, insert on tid.tid_ingestion_batch_records to tid_runner;
grant select on tid.tid_hb_calendar_exceptions to tid_runner;

-- Row-level security is on for every tid table with no policies, so each needs one for this role.
do $$
declare t text;
begin
  foreach t in array array['tid_scan_runs', 'tid_ingestion_batches', 'tid_ingestion_records',
                           'tid_ingestion_watermarks', 'tid_market_bars', 'tid_ingestion_batch_records'] loop
    execute format('drop policy if exists tid_runner_rw on tid.%I', t);
    execute format('create policy tid_runner_rw on tid.%I for all to tid_runner using (true) with check (true)', t);
  end loop;
  drop policy if exists tid_runner_read on tid.tid_hb_calendar_exceptions;
  create policy tid_runner_read on tid.tid_hb_calendar_exceptions for select to tid_runner using (true);
end $$;

grant execute on function
  tid.begin_ingestion_batch(text, text, uuid, timestamptz, integer, integer, jsonb),
  tid.upsert_ingestion_records_bulk(uuid, jsonb),
  tid.upsert_ingestion_record(uuid, text, text, jsonb, text, timestamptz, timestamptz),
  tid.finalize_ingestion_batch(uuid, integer, boolean, boolean, text, jsonb),
  tid.capture_snapshot(text, text, text, jsonb, timestamptz, jsonb, text, text, text, uuid, text, timestamptz),
  tid.record_oi_capture(text, bigint[], uuid),
  tid.hb_check(text, boolean, timestamptz),
  tid.is_trading_day(date)
to tid_runner;
