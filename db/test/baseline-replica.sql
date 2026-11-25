-- Local test replica of the tid ingestion schema, copied from Supabase project
-- TID-Trade-Intelligence on 2026-11-24 (columns, keys, checks and function bodies verbatim).
-- Test use only. Never apply this to Supabase: the real tables already exist there.

create extension if not exists pgcrypto;
create schema if not exists tid;

create table tid.tid_scan_runs (
  run_id uuid not null default gen_random_uuid() primary key,
  run_started_at timestamptz not null default now(),
  run_completed_at timestamptz,
  scan_name text not null,
  market_session date not null,
  timezone text not null default 'America/New_York',
  source text not null default 'Tradytics',
  source_as_of timestamptz,
  universe_definition text,
  universe_rows integer,
  candidates_scored integer,
  coverage_pct numeric,
  pagination_complete boolean,
  ledger_write_status text not null default 'pending',
  data_quality jsonb not null default '{}'::jsonb,
  run_metadata jsonb not null default '{}'::jsonb
);

create table tid.tid_ingestion_batches (
  batch_id uuid not null default gen_random_uuid() primary key,
  scan_run_id uuid references tid.tid_scan_runs(run_id) on delete set null,
  feed_type text not null,
  source text not null default 'Tradytics',
  source_as_of timestamptz,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  expected_records integer check (expected_records is null or expected_records >= 0),
  expected_pages integer check (expected_pages is null or expected_pages >= 0),
  pages_completed integer not null default 0 check (pages_completed >= 0),
  records_received integer not null default 0 check (records_received >= 0),
  records_upserted integer not null default 0 check (records_upserted >= 0),
  pagination_complete boolean not null default false,
  provider_has_more boolean,
  status text not null default 'in_progress' check (status = any (array['in_progress','complete','partial','failed'])),
  quality_status text not null default 'pending' check (quality_status = any (array['pending','pass','warning','fail'])),
  error_text text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table tid.tid_ingestion_records (
  record_id uuid not null default gen_random_uuid() primary key,
  feed_type text not null,
  record_key text not null,
  source_event_key text not null,
  symbol text,
  source_event_at timestamptz,
  source_as_of timestamptz,
  payload jsonb not null,
  payload_hash text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (feed_type, record_key, source_event_key)
);

create table tid.tid_ingestion_batch_records (
  batch_id uuid not null references tid.tid_ingestion_batches(batch_id) on delete cascade,
  record_id uuid not null references tid.tid_ingestion_records(record_id) on delete restrict,
  linked_at timestamptz not null default now(),
  primary key (batch_id, record_id)
);

create table tid.tid_ingestion_watermarks (
  feed_type text not null primary key,
  last_successful_source_as_of timestamptz,
  last_successful_batch_id uuid references tid.tid_ingestion_batches(batch_id),
  last_attempt_at timestamptz,
  last_status text not null default 'never_run',
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table tid.tid_market_bars (
  symbol text not null,
  session_date date not null,
  timeframe text not null default '1d' check (timeframe = '1d'),
  open numeric not null check (open > 0),
  high numeric not null check (high > 0),
  low numeric not null check (low > 0),
  close numeric not null check (close > 0),
  volume numeric,
  source text not null default 'Tradytics',
  source_as_of timestamptz,
  ingested_at timestamptz not null default now(),
  primary key (symbol, session_date),
  check (high >= low),
  check (high >= greatest(open, close)),
  check (low <= least(open, close))
);

CREATE OR REPLACE FUNCTION tid.begin_ingestion_batch(p_feed_type text, p_source text DEFAULT 'Tradytics'::text, p_scan_run_id uuid DEFAULT NULL::uuid, p_source_as_of timestamp with time zone DEFAULT NULL::timestamp with time zone, p_expected_records integer DEFAULT NULL::integer, p_expected_pages integer DEFAULT NULL::integer, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_id uuid;
begin
  if nullif(btrim(p_feed_type),'') is null then raise exception 'feed_type is required'; end if;
  insert into tid.tid_ingestion_batches(feed_type,source,scan_run_id,source_as_of,expected_records,expected_pages,metadata)
  values (p_feed_type,coalesce(nullif(p_source,''),'Tradytics'),p_scan_run_id,p_source_as_of,p_expected_records,p_expected_pages,coalesce(p_metadata,'{}'::jsonb))
  returning batch_id into v_id;
  insert into tid.tid_ingestion_watermarks(feed_type,last_attempt_at,last_status)
  values (p_feed_type,now(),'in_progress')
  on conflict (feed_type) do update set last_attempt_at=excluded.last_attempt_at,last_status='in_progress',updated_at=now();
  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION tid.upsert_ingestion_record(p_batch_id uuid, p_record_key text, p_source_event_key text, p_payload jsonb, p_symbol text DEFAULT NULL::text, p_source_event_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_source_as_of timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_feed text; v_id uuid; v_hash text;
begin
  select feed_type into v_feed from tid.tid_ingestion_batches where batch_id=p_batch_id and status='in_progress';
  if v_feed is null then raise exception 'batch not found or not in progress'; end if;
  if nullif(btrim(p_record_key),'') is null or nullif(btrim(p_source_event_key),'') is null then raise exception 'stable record_key and source_event_key are required'; end if;
  if p_payload is null then raise exception 'payload is required'; end if;
  v_hash := md5(p_payload::text);
  insert into tid.tid_ingestion_records(feed_type,record_key,source_event_key,symbol,source_event_at,source_as_of,payload,payload_hash)
  values(v_feed,p_record_key,p_source_event_key,p_symbol,p_source_event_at,p_source_as_of,p_payload,v_hash)
  on conflict(feed_type,record_key,source_event_key) do update
    set symbol=coalesce(excluded.symbol,tid.tid_ingestion_records.symbol),
        source_event_at=coalesce(excluded.source_event_at,tid.tid_ingestion_records.source_event_at),
        source_as_of=case when excluded.source_as_of is not null and (tid.tid_ingestion_records.source_as_of is null or excluded.source_as_of >= tid.tid_ingestion_records.source_as_of) then excluded.source_as_of else tid.tid_ingestion_records.source_as_of end,
        payload=case when excluded.source_as_of is null or tid.tid_ingestion_records.source_as_of is null or excluded.source_as_of >= tid.tid_ingestion_records.source_as_of then excluded.payload else tid.tid_ingestion_records.payload end,
        payload_hash=case when excluded.source_as_of is null or tid.tid_ingestion_records.source_as_of is null or excluded.source_as_of >= tid.tid_ingestion_records.source_as_of then excluded.payload_hash else tid.tid_ingestion_records.payload_hash end,
        last_seen_at=now()
  returning record_id into v_id;
  insert into tid.tid_ingestion_batch_records(batch_id,record_id) values(p_batch_id,v_id) on conflict do nothing;
  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION tid.upsert_ingestion_records_bulk(p_batch_id uuid, p_records jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r jsonb;
  v_count integer := 0;
  v_ids integer := 0;
begin
  if jsonb_typeof(p_records) <> 'array' then
    raise exception 'p_records must be a JSON array';
  end if;
  for r in select value from jsonb_array_elements(p_records)
  loop
    perform tid.upsert_ingestion_record(
      p_batch_id,
      r->>'record_key',
      r->>'source_event_key',
      r->'payload',
      nullif(r->>'symbol',''),
      nullif(r->>'source_event_at','')::timestamptz,
      nullif(r->>'source_as_of','')::timestamptz
    );
    v_count := v_count + 1;
  end loop;
  select count(*) into v_ids
  from tid.tid_ingestion_batch_records
  where batch_id = p_batch_id;
  return jsonb_build_object('records_processed',v_count,'batch_linked_records',v_ids);
end;
$function$;

CREATE OR REPLACE FUNCTION tid.finalize_ingestion_batch(p_batch_id uuid, p_pages_completed integer, p_pagination_complete boolean, p_provider_has_more boolean DEFAULT false, p_error_text text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare b tid.tid_ingestion_batches%rowtype; v_count integer; v_status text; v_quality text; v_result jsonb;
begin
  select * into b from tid.tid_ingestion_batches where batch_id=p_batch_id for update;
  if not found then raise exception 'batch not found'; end if;
  select count(*) into v_count from tid.tid_ingestion_batch_records where batch_id=p_batch_id;
  if p_pages_completed < 0 then raise exception 'pages_completed cannot be negative'; end if;
  if p_error_text is not null then v_status := 'failed'; v_quality := 'fail';
  elsif p_pagination_complete and not coalesce(p_provider_has_more,false) and (b.expected_records is null or v_count >= b.expected_records) and (b.expected_pages is null or p_pages_completed >= b.expected_pages) then v_status := 'complete'; v_quality := 'pass';
  else v_status := 'partial'; v_quality := 'warning'; end if;
  update tid.tid_ingestion_batches set completed_at=now(),pages_completed=p_pages_completed,records_received=v_count,records_upserted=v_count,pagination_complete=p_pagination_complete,provider_has_more=p_provider_has_more,status=v_status,quality_status=v_quality,error_text=p_error_text,metadata=metadata || coalesce(p_metadata,'{}'::jsonb) where batch_id=p_batch_id;
  if v_status='complete' then
    insert into tid.tid_ingestion_watermarks(feed_type,last_successful_source_as_of,last_successful_batch_id,last_attempt_at,last_status,updated_at,metadata)
    values(b.feed_type,b.source_as_of,p_batch_id,now(),'complete',now(),coalesce(p_metadata,'{}'::jsonb))
    on conflict(feed_type) do update set last_successful_source_as_of=case when excluded.last_successful_source_as_of is not null and (tid.tid_ingestion_watermarks.last_successful_source_as_of is null or excluded.last_successful_source_as_of >= tid.tid_ingestion_watermarks.last_successful_source_as_of) then excluded.last_successful_source_as_of else tid.tid_ingestion_watermarks.last_successful_source_as_of end,last_successful_batch_id=excluded.last_successful_batch_id,last_attempt_at=now(),last_status='complete',updated_at=now(),metadata=excluded.metadata;
  else
    update tid.tid_ingestion_watermarks set last_attempt_at=now(),last_status=v_status,updated_at=now(),metadata=coalesce(p_metadata,'{}'::jsonb) where feed_type=b.feed_type;
  end if;
  v_result := jsonb_build_object('batch_id',p_batch_id,'feed_type',b.feed_type,'status',v_status,'quality_status',v_quality,'records_received',v_count,'expected_records',b.expected_records,'pages_completed',p_pages_completed,'expected_pages',b.expected_pages,'pagination_complete',p_pagination_complete,'provider_has_more',p_provider_has_more,'error_text',p_error_text);
  return v_result;
end;
$function$;
