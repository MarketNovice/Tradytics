-- Tests for db/tid-3.3-heartbeat.sql and db/tid-2.12-open-interest.sql.
-- Run on a fresh database after baseline-replica.sql, tid-3.2, tid-3.3 and tid-2.12.
-- Uses fixed timestamps around Thanksgiving 2026 (Thu 11-26 closed, Fri 11-27 early close 13:00 ET).

-- ================================================================== TID-3.3
-- 1. calendar
do $$ begin
  assert tid.is_trading_day('2026-11-25') and not tid.is_trading_day('2026-11-26') and tid.is_trading_day('2026-11-27')
     and not tid.is_trading_day('2026-11-28'), 'trading days wrong';
  assert tid.session_close_at('2026-11-27') = '2026-11-27 13:00 America/New_York'::timestamptz, 'early close wrong';
  assert tid.session_close_at('2026-11-26') is null, 'holiday should have no close';
  assert tid.prev_trading_day('2026-11-27') = '2026-11-25' and tid.next_trading_day('2026-11-25') = '2026-11-27', 'prev/next wrong';
  assert tid.prev_trading_day('2026-11-30') = '2026-11-27', 'prev across weekend wrong';
  raise notice 'PASS 3.3-1: calendar';
end $$;

-- 2. missing scans are reported once; canary always reported
do $$
declare r jsonb; r2 jsonb; c jsonb;
begin
  -- Wed 2026-11-25 21:00 ET: all four deadlines passed for 11-25 and for 11-24, and no tid-runner runs exist
  r := tid.hb_check('test', false, '2026-11-25 21:00 America/New_York');
  assert jsonb_array_length(r->'findings') = 8, format('expected 8 findings (4 scans x 2 days), got %s', r->'findings');
  assert jsonb_array_length(r->'new_findings') = 8, 'all should be new';
  assert (select count(*) from jsonb_array_elements(r->'findings') f where f->>'code' = 'scan_missing') = 8, 'codes wrong';
  r2 := tid.hb_check('test', false, '2026-11-25 22:00 America/New_York');
  assert jsonb_array_length(r2->'findings') = 8 and jsonb_array_length(r2->'new_findings') = 0, 'repeat should not be new';
  -- a different watchdog is not silenced by the first one's reports
  r2 := tid.hb_check('other-watchdog', false, '2026-11-25 22:00 America/New_York');
  assert jsonb_array_length(r2->'new_findings') = 8, 'second checker should get its own new findings';
  c := tid.hb_check('test', true, '2026-11-25 22:00 America/New_York');
  assert (select count(*) from jsonb_array_elements(c->'new_findings') f where f->>'code' = 'canary') = 1, 'canary not new';
  perform tid.hb_ack_canary((c->>'watchdog_run_id')::bigint, 'test', 'received');
  begin perform tid.hb_ack_canary((r->>'watchdog_run_id')::bigint, 'test'); raise exception 'ack of non-canary allowed';
  exception when raise_exception then if sqlerrm not like '%not a canary%' then raise; end if; end;
  raise notice 'PASS 3.3-2: missing scans reported once, canary always, ack recorded';
end $$;

-- 3. completed runs clear findings; completed without snapshots and incomplete runs are flagged
do $$
declare r jsonb;
begin
  insert into tid.tid_scan_runs (scan_name, market_session, ledger_write_status, run_metadata) values
    ('t', '2026-11-27', 'written', '{"runner":"tid-runner","scan_type":"morning","snapshots":true}'),
    ('t', '2026-11-27', 'written', '{"runner":"tid-runner","scan_type":"midday","snapshots":false}'),
    ('t', '2026-11-27', 'partial', '{"runner":"tid-runner","scan_type":"afternoon","snapshots":true}');
  -- Fri 11-27 16:30 ET: morning ok, midday no snapshots, afternoon partial; oi deadline (20:30) not reached.
  -- Previous trading day is 11-25 (Thanksgiving skipped), which still has its 4 missing scans.
  r := tid.hb_check('test', false, '2026-11-27 16:30 America/New_York');
  assert (r->'checked_days') = '["2026-11-25", "2026-11-27"]'::jsonb, format('checked days wrong: %s', r->'checked_days');
  assert not exists (select 1 from jsonb_array_elements(r->'findings') f where f->>'session' = '2026-11-27' and f->>'scan_type' in ('morning', 'oi')), 'morning/oi should be clear';
  assert exists (select 1 from jsonb_array_elements(r->'findings') f where f->>'session' = '2026-11-27' and f->>'scan_type' = 'midday' and f->>'code' = 'snapshots_off'), 'snapshots_off missing';
  assert exists (select 1 from jsonb_array_elements(r->'findings') f where f->>'session' = '2026-11-27' and f->>'scan_type' = 'afternoon' and f->>'code' = 'scan_incomplete'), 'scan_incomplete missing';
  raise notice 'PASS 3.3-3: completed, no-snapshot and incomplete runs classified';
end $$;

-- 4. holiday: nothing expected on Thanksgiving itself
do $$
declare r jsonb;
begin
  r := tid.hb_check('test', false, '2026-11-26 21:00 America/New_York');
  assert (r->'checked_days') = '["2026-11-25"]'::jsonb, format('holiday should only check 11-25, got %s', r->'checked_days');
  raise notice 'PASS 3.3-4: holiday checks only the previous trading day';
end $$;

-- 5. watchdog log is append-only
do $$ begin
  begin update tid.tid_hb_watchdog_runs set status = 'ok'; raise exception 'update allowed';
  exception when raise_exception then if sqlerrm not like '%append-only%' then raise; end if; end;
  raise notice 'PASS 3.3-5: watchdog log append-only';
end $$;

-- ================================================================== TID-2.12
-- helper: insert a chain_oi_v1 snapshot for symbol TST at a fixed time
create or replace function pg_temp.chain_snap(p_at timestamptz, p_rows jsonb) returns bigint language sql as $$
  insert into tid.tid_raw_snapshots (captured_at, endpoint, symbol, request_params, request_key, capture_status,
                                     payload, raw_sha256, payload_sha256, row_sha256)
  values (p_at, 'tradytics/options/chain', 'TST', '{"symbol":"TST"}', 'k', 'complete',
          jsonb_build_object('projection', 'chain_oi_v1', 'columns', '["contract","open_interest","volume","delta"]'::jsonb, 'rows', p_rows),
          repeat('a', 64), 'p', 'r')
  returning snapshot_id;
$$;

do $$
declare v jsonb; s1 bigint; s2 bigint; x record;
begin
  -- a) Tue 11-24 18:00 ET, first ever capture -> baseline
  v := tid.record_oi_capture('TST', array[pg_temp.chain_snap('2026-11-24 18:00 America/New_York',
         '[["TST261218C00100000",100,5,0.5],["TST261218P00100000",50,1,-0.5],["TST261218C00110000",0,0,0.3]]')], null);
  assert v->>'mapping_status' = 'baseline' and (v->>'new')::boolean, format('a: %s', v);

  -- b) Wed 11-25 07:20 ET, new values, two pages -> overnight, session 11-24, available before the 11-25 open
  s1 := pg_temp.chain_snap('2026-11-25 07:20 America/New_York', '[["TST261218C00100000",120,0,0.5]]');
  s2 := pg_temp.chain_snap('2026-11-25 07:20:05 America/New_York', '[["TST261218P00100000",40,0,-0.5],["TST261218C00110000",30,0,0.3]]');
  v := tid.record_oi_capture('TST', array[s1, s2], null);
  assert v->>'mapping_status' = 'overnight' and v->>'oi_session' = '2026-11-24', format('b: %s', v);
  select * into x from tid.tid_oi_vintages where vintage_id = (v->>'vintage_id')::bigint;
  assert x.available_before_open and x.contracts = 3 and x.call_oi = 150 and x.put_oi = 40, format('b row: %s', row_to_json(x));

  -- c) same values seen again at 17:40 ET -> repeat, no new vintage
  v := tid.record_oi_capture('TST', array[pg_temp.chain_snap('2026-11-25 17:40 America/New_York',
         '[["TST261218C00100000",120,9,0.5],["TST261218P00100000",40,9,-0.5],["TST261218C00110000",30,9,0.3]]')], null);
  assert not (v->>'new')::boolean, format('c should repeat: %s', v);
  assert (select captures from tid.tid_oi_vintages where vintage_id = (v->>'vintage_id')::bigint) = 2, 'c captures';

  -- d) values change at 11:00 ET on a trading day -> intraday, no session, not available before open
  v := tid.record_oi_capture('TST', array[pg_temp.chain_snap('2026-11-27 11:00 America/New_York',
         '[["TST261218C00100000",121,0,0.5],["TST261218P00100000",40,0,-0.5],["TST261218C00110000",30,0,0.3]]')], null);
  assert v->>'mapping_status' = 'intraday' and v->>'oi_session' is null, format('d: %s', v);

  -- e) after the 13:00 early close on 11-27 -> evening, session 11-27
  v := tid.record_oi_capture('TST', array[pg_temp.chain_snap('2026-11-27 14:00 America/New_York',
         '[["TST261218C00100000",125,0,0.5],["TST261218P00100000",40,0,-0.5],["TST261218C00110000",30,0,0.3]]')], null);
  assert v->>'mapping_status' = 'evening' and v->>'oi_session' = '2026-11-27', format('e: %s', v);

  -- f) Mon 11-30 07:20 ET, after a weekend -> overnight, session 11-27, follows the previous session? prev is 11-27 itself -> false
  v := tid.record_oi_capture('TST', array[pg_temp.chain_snap('2026-11-30 07:20 America/New_York',
         '[["TST261218C00100000",130,0,0.5],["TST261218P00100000",35,0,-0.5]]')], null);
  assert v->>'mapping_status' = 'overnight' and v->>'oi_session' = '2026-11-27', format('f: %s', v);
  select * into x from tid.tid_oi_vintages where vintage_id = (v->>'vintage_id')::bigint;
  assert x.available_before_open and x.follows_prev_session = false, format('f row: %s', row_to_json(x));

  -- g) contract-level change vs the previous vintage: C110 disappeared (30 -> 0), C100 +5, P100 -5
  assert (select oi_change from tid.oi_contract_changes(x.vintage_id) where contract = 'TST261218C00110000') = -30, 'g: vanished contract';
  assert (select oi_change from tid.oi_contract_changes(x.vintage_id) where contract = 'TST261218C00100000') = 5, 'g: call change';
  assert (select call_oi_change from tid.v_oi_vintage_summary where vintage_id = x.vintage_id) = -25, 'g: summary call change';
  assert (select count(*) from tid.v_oi_vintage_contracts where vintage_id = x.vintage_id) = 2, 'g: contract view';
  raise notice 'PASS 2.12-1: baseline, overnight (multi-page), repeat, intraday, early-close evening, weekend overnight, changes';
end $$;

-- 2. a capture that is not a complete chain_oi_v1 page for the symbol is rejected
do $$
declare s bigint;
begin
  s := tid.capture_snapshot('tradytics/options/chain', 'TST', null, '{}', null, '{"data":[]}', 'complete', null, repeat('b', 64), null, 't');
  begin perform tid.record_oi_capture('TST', array[s], null); raise exception 'unprojected page accepted';
  exception when raise_exception then if sqlerrm not like '%not complete chain_oi_v1%' then raise; end if; end;
  begin perform tid.record_oi_capture('TST', array[999999]::bigint[], null); raise exception 'missing snapshot accepted';
  exception when raise_exception then if sqlerrm not like '%missing%' then raise; end if; end;
  raise notice 'PASS 2.12-2: invalid snapshots rejected';
end $$;

select 'ALL TESTS PASSED' as result;
