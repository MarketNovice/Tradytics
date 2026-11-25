-- TID-3.2 Raw snapshot capture and first-capture record versions
-- Status: DRAFT, not applied. Review, then apply once in the Supabase SQL editor or as a migration.
-- Idempotent: safe to re-run. Requires: schema tid, tid.tid_scan_runs, tid.tid_ingestion_records.
--
-- What it adds
--   1. tid.tid_raw_snapshots       append-only store of every raw API response (or its failure),
--                                  with capture time, client SHA-256 of the raw bytes, server SHA-256
--                                  of the stored payload, and a per-row hash over both.
--   2. tid.capture_snapshot(...)   the function tid-runner/run.ts already calls (same 11 arguments,
--                                  plus an optional 12th, p_received_at, for a client-side timestamp).
--   3. tid.tid_record_versions     append-only log of every distinct payload a record has had, filled by
--                                  a trigger on tid.tid_ingestion_records. The existing upsert overwrites
--                                  payloads when newer data arrives; this keeps the first capture and
--                                  every revision (protocol 3.4.2 section 4).
--   4. tid.v_record_first_capture  first-captured payload and timestamp per record.
--   5. tid.snapshot_daily_digest() one SHA-256 over a day's row hashes, for recording outside the
--                                  database (for example, committed to git) as tamper evidence.
--
-- Append-only is enforced by triggers that reject UPDATE, DELETE and TRUNCATE. A superuser can still
-- drop the triggers; the external daily digest is what makes such changes detectable.

begin;

-- ------------------------------------------------------------------ 1. raw snapshots
create table if not exists tid.tid_raw_snapshots (
  snapshot_id     bigint generated always as identity primary key,
  captured_at     timestamptz not null default clock_timestamp(),  -- when the database stored it
  received_at     timestamptz,                                     -- when the client received it (optional)
  endpoint        text not null,                                   -- e.g. 'tradytics/stocks/bars'
  symbol          text,                                            -- single-symbol requests only
  contract_key    text,                                            -- option contract or other sub-key, if any
  request_params  jsonb not null default '{}'::jsonb,
  request_key     text not null,                                   -- sha256(endpoint || canonical params)
  source_as_of    timestamptz,                                     -- vendor meta.as_of
  capture_status  text not null check (capture_status in ('complete', 'partial', 'missing')),
  missing_reason  text,
  payload         jsonb,
  raw_sha256      text,                                            -- client hash of the raw response bytes
  payload_sha256  text,                                            -- server hash of payload::text
  row_sha256      text not null,                                   -- hash over the identifying fields and both hashes
  scan_run_id     uuid references tid.tid_scan_runs (run_id),
  runner_version  text,
  constraint tid_raw_snapshots_complete_has_payload
    check (capture_status = 'missing' or (payload is not null and raw_sha256 ~ '^[0-9a-f]{64}$')),
  constraint tid_raw_snapshots_missing_has_reason
    check (capture_status <> 'missing' or nullif(btrim(missing_reason), '') is not null)
);

create index if not exists tid_raw_snapshots_endpoint_symbol_time_idx
  on tid.tid_raw_snapshots (endpoint, symbol, captured_at desc);
create index if not exists tid_raw_snapshots_request_key_idx
  on tid.tid_raw_snapshots (request_key, captured_at);
create index if not exists tid_raw_snapshots_run_idx
  on tid.tid_raw_snapshots (scan_run_id);
create index if not exists tid_raw_snapshots_captured_idx
  on tid.tid_raw_snapshots (captured_at);

-- ------------------------------------------------------------------ 2. capture function
create or replace function tid.capture_snapshot(
  p_endpoint       text,
  p_symbol         text,
  p_contract_key   text,
  p_request_params jsonb,
  p_source_as_of   timestamptz,
  p_payload        jsonb,
  p_capture_status text,
  p_missing_reason text,
  p_raw_sha256     text,
  p_scan_run_id    uuid,
  p_runner_version text,
  p_received_at    timestamptz default null
) returns bigint
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_params  jsonb := coalesce(p_request_params, '{}'::jsonb);  -- includes cursor, so each page has its own key
  v_req     text;
  v_payhash text;
  v_at      timestamptz := clock_timestamp();
  v_id      bigint;
begin
  if nullif(btrim(p_endpoint), '') is null then raise exception 'endpoint is required'; end if;
  -- jsonb::text is canonical (sorted keys, normalized spacing), so equal params give equal keys.
  v_req := encode(sha256(convert_to(p_endpoint || '|' || v_params::text, 'UTF8')), 'hex');
  v_payhash := case when p_payload is null then null
                    else encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex') end;
  insert into tid.tid_raw_snapshots (
    captured_at, received_at, endpoint, symbol, contract_key, request_params, request_key,
    source_as_of, capture_status, missing_reason, payload, raw_sha256, payload_sha256, row_sha256,
    scan_run_id, runner_version)
  values (
    v_at, p_received_at, p_endpoint, nullif(p_symbol, ''), nullif(p_contract_key, ''), v_params, v_req,
    p_source_as_of, p_capture_status, p_missing_reason, p_payload, lower(p_raw_sha256), v_payhash,
    encode(sha256(convert_to(concat_ws('|',
      to_char(v_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      p_endpoint, v_req, coalesce(p_symbol, ''), coalesce(p_contract_key, ''),
      p_capture_status, coalesce(lower(p_raw_sha256), ''), coalesce(v_payhash, '')), 'UTF8')), 'hex'),
    p_scan_run_id, p_runner_version)
  returning snapshot_id into v_id;
  return v_id;
end;
$$;

-- ------------------------------------------------------------------ 3. record versions
create table if not exists tid.tid_record_versions (
  version_id      bigint generated always as identity primary key,
  record_id       uuid not null,
  feed_type       text not null,
  record_key      text not null,
  symbol          text,
  source_event_at timestamptz,
  source_as_of    timestamptz,
  payload         jsonb not null,
  payload_hash    text not null,          -- same md5 the ingestion table uses, for joining
  captured_at     timestamptz not null default clock_timestamp(),
  change_kind     text not null check (change_kind in ('first', 'revision'))
);

create index if not exists tid_record_versions_record_idx
  on tid.tid_record_versions (record_id, captured_at);
create index if not exists tid_record_versions_feed_key_idx
  on tid.tid_record_versions (feed_type, record_key);

create or replace function tid.trg_record_versions()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if tg_op = 'INSERT' or new.payload_hash is distinct from old.payload_hash then
    insert into tid.tid_record_versions (
      record_id, feed_type, record_key, symbol, source_event_at, source_as_of, payload, payload_hash, change_kind)
    values (
      new.record_id, new.feed_type, new.record_key, new.symbol, new.source_event_at, new.source_as_of,
      new.payload, new.payload_hash, case when tg_op = 'INSERT' then 'first' else 'revision' end);
  end if;
  return null;
end;
$$;

drop trigger if exists tid_record_versions_capture on tid.tid_ingestion_records;
create trigger tid_record_versions_capture
  after insert or update of payload_hash on tid.tid_ingestion_records
  for each row execute function tid.trg_record_versions();

-- Records that already exist have no 'first' version yet. Seed them once, marked by the
-- version's captured_at being the migration time (their true first capture is first_seen_at).
insert into tid.tid_record_versions (
  record_id, feed_type, record_key, symbol, source_event_at, source_as_of, payload, payload_hash, change_kind)
select r.record_id, r.feed_type, r.record_key, r.symbol, r.source_event_at, r.source_as_of,
       r.payload, r.payload_hash, 'first'
from tid.tid_ingestion_records r
where not exists (select 1 from tid.tid_record_versions v where v.record_id = r.record_id);

-- ------------------------------------------------------------------ 4. first-capture view
create or replace view tid.v_record_first_capture as
select distinct on (v.record_id)
  v.record_id, v.feed_type, v.record_key, v.symbol, v.source_event_at,
  v.payload        as first_payload,
  v.payload_hash   as first_payload_hash,
  v.source_as_of   as first_source_as_of,
  v.captured_at    as first_captured_at,
  (select count(*) - 1 from tid.tid_record_versions x where x.record_id = v.record_id) as revision_count
from tid.tid_record_versions v
order by v.record_id, v.captured_at, v.version_id;

-- ------------------------------------------------------------------ append-only guards
create or replace function tid.trg_append_only()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  raise exception '% is append-only (% rejected)', tg_table_name, tg_op;
end;
$$;

drop trigger if exists tid_raw_snapshots_append_only on tid.tid_raw_snapshots;
create trigger tid_raw_snapshots_append_only
  before update or delete on tid.tid_raw_snapshots
  for each row execute function tid.trg_append_only();
drop trigger if exists tid_raw_snapshots_no_truncate on tid.tid_raw_snapshots;
create trigger tid_raw_snapshots_no_truncate
  before truncate on tid.tid_raw_snapshots
  for each statement execute function tid.trg_append_only();

drop trigger if exists tid_record_versions_append_only on tid.tid_record_versions;
create trigger tid_record_versions_append_only
  before update or delete on tid.tid_record_versions
  for each row execute function tid.trg_append_only();
drop trigger if exists tid_record_versions_no_truncate on tid.tid_record_versions;
create trigger tid_record_versions_no_truncate
  before truncate on tid.tid_record_versions
  for each statement execute function tid.trg_append_only();

-- ------------------------------------------------------------------ 5. daily digest
create or replace function tid.snapshot_daily_digest(p_day date, p_tz text default 'America/New_York')
returns table (day date, snapshots bigint, digest_sha256 text)
language sql
stable
set search_path to ''
as $$
  select p_day,
         count(*),
         encode(sha256(convert_to(coalesce(string_agg(row_sha256, '' order by snapshot_id), ''), 'UTF8')), 'hex')
  from tid.tid_raw_snapshots
  where (captured_at at time zone p_tz)::date = p_day;
$$;

-- ------------------------------------------------------------------ access
alter table tid.tid_raw_snapshots   enable row level security;  -- no policies: API roles see nothing
alter table tid.tid_record_versions enable row level security;
revoke all on tid.tid_raw_snapshots, tid.tid_record_versions, tid.v_record_first_capture from public;
revoke all on function tid.capture_snapshot(text, text, text, jsonb, timestamptz, jsonb, text, text, text, uuid, text, timestamptz) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on tid.tid_raw_snapshots, tid.tid_record_versions, tid.v_record_first_capture from anon, authenticated';
    execute 'revoke all on function tid.capture_snapshot(text, text, text, jsonb, timestamptz, jsonb, text, text, text, uuid, text, timestamptz) from anon, authenticated';
  end if;
end $$;
-- When the runner gets its own role:
--   grant execute on function tid.capture_snapshot(text, text, text, jsonb, timestamptz, jsonb, text, text, text, uuid, text, timestamptz) to tid_runner;

commit;
