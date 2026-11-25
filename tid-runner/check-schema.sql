-- tid-runner schema check (read-only). Paste into the Supabase SQL editor and run.
-- Returns one result set: section | object | detail. Writes nothing.
-- Answers README assumptions 4-6 and the snapshot / dedup questions from the 0.1.0 review.

with fns as (
  select p.oid, p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'tid'
    and p.proname in ('begin_ingestion_batch', 'upsert_ingestion_records_bulk',
                      'finalize_ingestion_batch', 'capture_snapshot', 'refresh_paper_validation_outcomes')
),
tbls as (
  select unnest(array['tid_scan_runs', 'tid_ingestion_batches', 'tid_ingestion_batch_records',
                      'tid_market_bars', 'tid_hb_calendar_exceptions']) as t
)
-- 1. Function signatures (A4: what begin_ingestion_batch returns; capture_snapshot argument order)
select '1 signature' as section, proname as object,
       pg_get_function_identity_arguments(oid) || '  ->  ' || pg_get_function_result(oid) as detail
from fns
union all
-- 2. Function bodies (expected record JSON keys, status/quality rules)
select '2 body', proname, pg_get_functiondef(oid) from fns
union all
-- 3. Tables present or missing
select '3 table', t, case when to_regclass('tid.' || t) is null then 'MISSING' else 'present' end from tbls
union all
-- 4. Columns, types, defaults (A5: batch_id on batch_records; ledger_write_status default)
select '4 column', c.table_name,
       c.column_name || ' ' || c.data_type ||
       case when c.is_nullable = 'NO' then ' not null' else '' end ||
       coalesce(' default ' || c.column_default, '')
from information_schema.columns c
where c.table_schema = 'tid' and c.table_name in (select t from tbls)
union all
-- 5. Unique indexes (A6: tid_market_bars unique key; record_key uniqueness)
select '5 index', tablename, indexdef
from pg_indexes
where schemaname = 'tid' and tablename in (select t from tbls) and indexdef ilike '%unique%'
union all
-- 6. Check constraints (allowed status / quality / ledger values)
select '6 check', rel.relname, con.conname || ': ' || pg_get_constraintdef(con.oid)
from pg_constraint con join pg_class rel on rel.oid = con.conrelid
join pg_namespace n on n.oid = rel.relnamespace
where n.nspname = 'tid' and con.contype = 'c' and rel.relname in (select t from tbls)
order by 1, 2, 3;
