-- Tests for db/tid-3.2-raw-snapshots.sql. Run against a fresh database after
-- baseline-replica.sql and the migration:  psql -v ON_ERROR_STOP=1 -f test-tid-3.2.sql
-- Each block raises an exception on failure; the script ends by printing ALL TESTS PASSED.

-- 1. capture_snapshot with the exact 11-argument call tid-runner 0.1.0 makes
do $$
declare v_run uuid; v_id bigint; s tid.tid_raw_snapshots%rowtype;
begin
  insert into tid.tid_scan_runs(scan_name, market_session) values ('test', '2026-11-24') returning run_id into v_run;
  v_id := tid.capture_snapshot('tradytics/stocks/bars'::text, 'SPY'::text, null::text,
            '{"symbol":"SPY","timeframe":"1d","limit":100}'::jsonb, '2026-11-25T01:25:02Z'::timestamptz,
            '{"data":[{"time":"2026-11-24T00:00:00Z","close":718.79}]}'::jsonb, 'complete'::text, null::text,
            repeat('ab', 32)::text, v_run, 'tid-runner/0.1.0'::text);
  select * into s from tid.tid_raw_snapshots where snapshot_id = v_id;
  assert s.payload_sha256 = encode(sha256(convert_to(s.payload::text, 'UTF8')), 'hex'), 'payload hash mismatch';
  assert s.row_sha256 ~ '^[0-9a-f]{64}$', 'row hash missing';
  assert s.request_key ~ '^[0-9a-f]{64}$', 'request key missing';
  assert s.captured_at is not null and s.scan_run_id = v_run, 'capture metadata missing';
  raise notice 'PASS 1: 11-argument capture call';
end $$;

-- 2. same params in a different key order give the same request_key
do $$
declare a text; b text;
begin
  perform tid.capture_snapshot('tradytics/x', null, null, '{"a":1,"b":2}', null, '{"data":[]}', 'complete', null, repeat('cd',32), null, 't');
  perform tid.capture_snapshot('tradytics/x', null, null, '{"b":2,"a":1}', null, '{"data":[]}', 'complete', null, repeat('cd',32), null, 't');
  select count(distinct request_key) into a from tid.tid_raw_snapshots where endpoint = 'tradytics/x';
  assert a = '1', 'request_key not canonical';
  raise notice 'PASS 2: canonical request_key';
end $$;

-- 3. missing capture requires a reason; complete requires payload and a valid hash
do $$
begin
  perform tid.capture_snapshot('tradytics/x', null, null, '{}', null, null, 'missing', 'http 503: down', null, null, 't');
  begin
    perform tid.capture_snapshot('tradytics/x', null, null, '{}', null, null, 'missing', null, null, null, 't');
    raise exception 'missing without reason was accepted';
  exception when check_violation then null; end;
  begin
    perform tid.capture_snapshot('tradytics/x', null, null, '{}', null, '{"data":[]}', 'complete', null, 'nothex', null, 't');
    raise exception 'bad raw hash was accepted';
  exception when check_violation then null; end;
  raise notice 'PASS 3: status constraints';
end $$;

-- 4. snapshots are append-only
do $$
begin
  begin update tid.tid_raw_snapshots set symbol = 'X'; raise exception 'update allowed';
  exception when raise_exception then if sqlerrm not like '%append-only%' then raise; end if; end;
  begin delete from tid.tid_raw_snapshots; raise exception 'delete allowed';
  exception when raise_exception then if sqlerrm not like '%append-only%' then raise; end if; end;
  begin truncate tid.tid_raw_snapshots; raise exception 'truncate allowed';
  exception when raise_exception then if sqlerrm not like '%append-only%' then raise; end if; end;
  raise notice 'PASS 4: append-only snapshots';
end $$;

-- 5. record versions: first capture kept, revisions logged, unchanged re-ingest not logged,
--    older data does not overwrite (existing upsert rule) and logs nothing
do $$
declare b1 uuid; b2 uuid; b3 uuid; b4 uuid; n int; fc tid.v_record_first_capture%rowtype; cur jsonb;
begin
  b1 := tid.begin_ingestion_batch('tradytics_daily_bars', 'Tradytics', null, '2026-11-25T01:25:02Z', 1, 1, '{}');
  perform tid.upsert_ingestion_records_bulk(b1, '[{"record_key":"bars1d:SPY:2026-11-24","source_event_key":"bars1d:SPY:2026-11-24","payload":{"close":718.79,"volume":53547320},"symbol":"SPY","source_event_at":"2026-11-24T00:00:00Z","source_as_of":"2026-11-25T01:25:02Z"}]');
  perform tid.finalize_ingestion_batch(b1, 1, true, false, null, '{}');

  b2 := tid.begin_ingestion_batch('tradytics_daily_bars', 'Tradytics', null, '2026-11-25T01:32:12Z', 1, 1, '{}');
  perform tid.upsert_ingestion_records_bulk(b2, '[{"record_key":"bars1d:SPY:2026-11-24","source_event_key":"bars1d:SPY:2026-11-24","payload":{"close":718.78,"volume":64740484},"symbol":"SPY","source_event_at":"2026-11-24T00:00:00Z","source_as_of":"2026-11-25T01:32:12Z"}]');
  perform tid.finalize_ingestion_batch(b2, 1, true, false, null, '{}');

  b3 := tid.begin_ingestion_batch('tradytics_daily_bars', 'Tradytics', null, '2026-11-25T11:00:00Z', 1, 1, '{}');
  perform tid.upsert_ingestion_records_bulk(b3, '[{"record_key":"bars1d:SPY:2026-11-24","source_event_key":"bars1d:SPY:2026-11-24","payload":{"close":718.78,"volume":64740484},"symbol":"SPY","source_event_at":"2026-11-24T00:00:00Z","source_as_of":"2026-11-25T11:00:00Z"}]');
  perform tid.finalize_ingestion_batch(b3, 1, true, false, null, '{}');

  b4 := tid.begin_ingestion_batch('tradytics_daily_bars', 'Tradytics', null, '2026-11-24T22:00:00Z', 1, 1, '{}');
  perform tid.upsert_ingestion_records_bulk(b4, '[{"record_key":"bars1d:SPY:2026-11-24","source_event_key":"bars1d:SPY:2026-11-24","payload":{"close":1.0,"volume":1},"symbol":"SPY","source_event_at":"2026-11-24T00:00:00Z","source_as_of":"2026-11-24T22:00:00Z"}]');
  perform tid.finalize_ingestion_batch(b4, 1, true, false, null, '{}');

  select count(*) into n from tid.tid_record_versions where record_key = 'bars1d:SPY:2026-11-24';
  assert n = 2, format('expected 2 versions (first + 1 revision), got %s', n);
  select * into fc from tid.v_record_first_capture where record_key = 'bars1d:SPY:2026-11-24';
  assert (fc.first_payload->>'volume')::bigint = 53547320, 'first capture not preserved';
  assert fc.revision_count = 1, 'revision count wrong';
  select payload into cur from tid.tid_ingestion_records where record_key = 'bars1d:SPY:2026-11-24';
  assert (cur->>'volume')::bigint = 64740484, 'current payload should be the latest revision';
  begin update tid.tid_record_versions set payload = '{}'; raise exception 'version update allowed';
  exception when raise_exception then if sqlerrm not like '%append-only%' then raise; end if; end;
  raise notice 'PASS 5: first capture kept, 1 revision logged, unchanged and older data ignored';
end $$;

-- 6. daily digest is deterministic
do $$
declare d1 text; d2 text; n bigint;
begin
  select digest_sha256, snapshots into d1, n from tid.snapshot_daily_digest((now() at time zone 'America/New_York')::date);
  select digest_sha256 into d2 from tid.snapshot_daily_digest((now() at time zone 'America/New_York')::date);
  assert d1 = d2 and d1 ~ '^[0-9a-f]{64}$' and n >= 4, 'digest not deterministic';
  raise notice 'PASS 6: daily digest over % snapshots', n;
end $$;

select 'ALL TESTS PASSED' as result;
