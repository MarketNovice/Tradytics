-- TID-2.12 Open interest vintages and session mapping
-- Idempotent: safe to re-run. Requires: TID-3.2 (tid.tid_raw_snapshots) and TID-3.3 (calendar functions).
--
-- Why this exists
--   The Tradytics chain endpoint (/options/chain) gives open interest per contract but no OI date and no
--   OI change. OI is published once a day, so the only trustworthy timing is when TID first saw a new set
--   of values. This file turns chain captures into OI "vintages":
--     - a vintage is one distinct set of (contract, open_interest) values for a symbol, identified by a
--       SHA-256 fingerprint over the contracts with non-zero OI;
--     - its availability time is the first capture that saw it (TID-3.2 captured_at);
--     - its session is the last trading session whose close came before that first capture;
--     - it qualifies for protocol F only if first captured before the open of the next session.
--
-- The runner stores each chain page as a TID-3.2 snapshot in a declared projection ('chain_oi_v1':
-- rows of [contract, open_interest, volume, delta]) to keep storage down. raw_sha256 still covers the full
-- raw response as received.

-- ------------------------------------------------------------------ helpers
create or replace function tid.last_closed_session(p_at timestamptz)
returns date language sql stable set search_path to '' as $$
  -- the latest trading day whose close is at or before p_at
  select d::date from generate_series((p_at at time zone 'America/New_York')::date,
                                      (p_at at time zone 'America/New_York')::date - 15,
                                      interval '-1 day') d
  where tid.is_trading_day(d::date) and tid.session_close_at(d::date) <= p_at
  order by d desc limit 1;
$$;

create or replace function tid.occ_expiry(p_contract text)
returns date language sql immutable set search_path to '' as $$
  select to_date(substr(right(p_contract, 15), 1, 6), 'YYMMDD');
$$;
create or replace function tid.occ_type(p_contract text)
returns text language sql immutable set search_path to '' as $$
  select case substr(right(p_contract, 15), 7, 1) when 'C' then 'call' when 'P' then 'put' end;
$$;
create or replace function tid.occ_strike(p_contract text)
returns numeric language sql immutable set search_path to '' as $$
  select round(substr(right(p_contract, 15), 8)::numeric / 1000, 3);
$$;

-- ------------------------------------------------------------------ vintages
create table if not exists tid.tid_oi_vintages (
  vintage_id            bigint generated always as identity primary key,
  symbol                text not null,
  fingerprint           text not null,
  first_captured_at     timestamptz not null,
  first_scan_run_id     uuid references tid.tid_scan_runs (run_id),
  first_snapshot_ids    bigint[] not null,
  last_captured_at      timestamptz not null,
  captures              integer not null default 1,
  contracts             integer not null,          -- contracts with non-zero OI
  call_oi               bigint not null,
  put_oi                bigint not null,
  prev_vintage_id       bigint references tid.tid_oi_vintages (vintage_id),
  oi_session            date,                      -- session whose closing positions this OI reflects
  mapping_status        text not null check (mapping_status in ('baseline', 'overnight', 'evening', 'intraday')),
  available_before_open boolean not null,          -- first captured before the open of the session after oi_session
  follows_prev_session  boolean,                   -- prev vintage's oi_session is the trading day before this one
  unique (symbol, fingerprint)
);
create index if not exists tid_oi_vintages_symbol_session_idx on tid.tid_oi_vintages (symbol, oi_session);

comment on column tid.tid_oi_vintages.mapping_status is
  'baseline: first vintage seen for the symbol, change timing unknown. overnight: first seen between midnight '
  'and the open (expected for OCC data). evening: first seen after the close the same day (unexpected; needs '
  'review). intraday: first seen during regular hours (unexpected; oi_session left null).';

-- ------------------------------------------------------------------ capture
create or replace function tid.record_oi_capture(p_symbol text, p_snapshot_ids bigint[], p_scan_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_n_snap   int;
  v_bad      int;
  v_at       timestamptz;
  v_fp       text;
  v_contracts int; v_call bigint; v_put bigint;
  v_existing bigint;
  v_prev     tid.tid_oi_vintages%rowtype;
  v_status   text;
  v_session  date;
  v_local    date;
  v_id       bigint;
begin
  if p_snapshot_ids is null or cardinality(p_snapshot_ids) = 0 then
    raise exception 'record_oi_capture(%): no snapshot ids', p_symbol;
  end if;
  select count(*),
         count(*) filter (where s.capture_status <> 'complete' or s.endpoint <> 'tradytics/options/chain'
                          or s.payload->>'projection' is distinct from 'chain_oi_v1'
                          or s.symbol is distinct from p_symbol),
         min(s.captured_at)
    into v_n_snap, v_bad, v_at
    from tid.tid_raw_snapshots s where s.snapshot_id = any (p_snapshot_ids);
  if v_n_snap <> cardinality(p_snapshot_ids) or v_bad > 0 then
    raise exception 'record_oi_capture(%): % of % snapshots missing or not complete chain_oi_v1 pages',
      p_symbol, cardinality(p_snapshot_ids) - v_n_snap + v_bad, cardinality(p_snapshot_ids);
  end if;

  with c as (
    select r->>0 as contract, (r->>1)::bigint as oi
    from tid.tid_raw_snapshots s, jsonb_array_elements(s.payload->'rows') r
    where s.snapshot_id = any (p_snapshot_ids)
  ), nz as (select distinct contract, oi from c where oi > 0)
  select encode(sha256(convert_to(coalesce(string_agg(contract || ':' || oi, ',' order by contract), ''), 'UTF8')), 'hex'),
         count(*),
         coalesce(sum(oi) filter (where tid.occ_type(contract) = 'call'), 0),
         coalesce(sum(oi) filter (where tid.occ_type(contract) = 'put'), 0)
    into v_fp, v_contracts, v_call, v_put
    from nz;

  select vintage_id into v_existing from tid.tid_oi_vintages where symbol = p_symbol and fingerprint = v_fp;
  if v_existing is not null then
    update tid.tid_oi_vintages set last_captured_at = greatest(last_captured_at, v_at), captures = captures + 1
     where vintage_id = v_existing;
    return jsonb_build_object('symbol', p_symbol, 'vintage_id', v_existing, 'new', false, 'fingerprint', v_fp);
  end if;

  select * into v_prev from tid.tid_oi_vintages where symbol = p_symbol
   order by first_captured_at desc, vintage_id desc limit 1;
  v_local := (v_at at time zone 'America/New_York')::date;
  if v_prev.vintage_id is null then
    v_status := 'baseline'; v_session := tid.last_closed_session(v_at);
  elsif tid.is_trading_day(v_local) and v_at >= tid.session_open_at(v_local) and v_at < tid.session_close_at(v_local) then
    v_status := 'intraday'; v_session := null;
  elsif tid.is_trading_day(v_local) and v_at >= tid.session_close_at(v_local) then
    v_status := 'evening'; v_session := v_local;
  else
    v_status := 'overnight'; v_session := tid.last_closed_session(v_at);
  end if;

  insert into tid.tid_oi_vintages (
    symbol, fingerprint, first_captured_at, first_scan_run_id, first_snapshot_ids, last_captured_at,
    contracts, call_oi, put_oi, prev_vintage_id, oi_session, mapping_status, available_before_open,
    follows_prev_session)
  values (
    p_symbol, v_fp, v_at, p_scan_run_id, p_snapshot_ids, v_at, v_contracts, v_call, v_put, v_prev.vintage_id,
    v_session, v_status,
    v_session is not null and v_status <> 'baseline'
      and v_at < tid.session_open_at(tid.next_trading_day(v_session)),
    case when v_prev.oi_session is null or v_session is null then null
         else v_prev.oi_session = tid.prev_trading_day(v_session) end)
  returning vintage_id into v_id;
  return jsonb_build_object('symbol', p_symbol, 'vintage_id', v_id, 'new', true, 'fingerprint', v_fp,
                            'mapping_status', v_status, 'oi_session', v_session);
end;
$$;

-- ------------------------------------------------------------------ contract-level views
create or replace view tid.v_oi_vintage_contracts as
select v.vintage_id, v.symbol, v.oi_session, v.mapping_status, v.available_before_open,
       r->>0 as contract,
       tid.occ_type(r->>0) as option_type, tid.occ_expiry(r->>0) as expiry, tid.occ_strike(r->>0) as strike,
       (r->>1)::bigint as open_interest, (r->>2)::bigint as volume, (r->>3)::numeric as delta
from tid.tid_oi_vintages v
join tid.tid_raw_snapshots s on s.snapshot_id = any (v.first_snapshot_ids)
cross join lateral jsonb_array_elements(s.payload->'rows') r;

-- Contract-level OI change from the previous vintage. Contracts absent from one side count as zero.
create or replace function tid.oi_contract_changes(p_vintage_id bigint)
returns table (contract text, option_type text, expiry date, strike numeric,
               open_interest bigint, prev_open_interest bigint, oi_change bigint, delta numeric)
language sql stable set search_path to '' as $$
  with cur as (select contract, max(open_interest) oi, max(delta) delta from tid.v_oi_vintage_contracts
               where vintage_id = p_vintage_id group by contract),
       prv as (select c.contract, max(c.open_interest) oi from tid.v_oi_vintage_contracts c
               join tid.tid_oi_vintages v on v.prev_vintage_id = c.vintage_id
               where v.vintage_id = p_vintage_id group by c.contract)
  select coalesce(cur.contract, prv.contract),
         tid.occ_type(coalesce(cur.contract, prv.contract)), tid.occ_expiry(coalesce(cur.contract, prv.contract)),
         tid.occ_strike(coalesce(cur.contract, prv.contract)),
         coalesce(cur.oi, 0), coalesce(prv.oi, 0), coalesce(cur.oi, 0) - coalesce(prv.oi, 0), cur.delta
  from cur full join prv on prv.contract = cur.contract;
$$;

-- Symbol-level summary per vintage (aggregate change vs the previous vintage).
create or replace view tid.v_oi_vintage_summary as
select v.vintage_id, v.symbol, v.oi_session, v.mapping_status, v.available_before_open, v.follows_prev_session,
       v.first_captured_at, v.captures, v.contracts, v.call_oi, v.put_oi,
       v.call_oi - p.call_oi as call_oi_change, v.put_oi - p.put_oi as put_oi_change
from tid.tid_oi_vintages v left join tid.tid_oi_vintages p on p.vintage_id = v.prev_vintage_id;

-- TID-2.12 verification report: how vintages are distributed by mapping status, per day of first capture.
create or replace view tid.v_oi_mapping_report as
select (first_captured_at at time zone 'America/New_York')::date as first_seen_et_date,
       mapping_status, count(*) as vintages, count(*) filter (where available_before_open) as before_open,
       min((first_captured_at at time zone 'America/New_York')::time) as earliest_et,
       max((first_captured_at at time zone 'America/New_York')::time) as latest_et
from tid.tid_oi_vintages group by 1, 2 order by 1 desc, 2;

-- ------------------------------------------------------------------ access
alter table tid.tid_oi_vintages enable row level security;
revoke all on tid.tid_oi_vintages, tid.v_oi_vintage_contracts, tid.v_oi_vintage_summary, tid.v_oi_mapping_report from public;
revoke all on function tid.record_oi_capture(text, bigint[], uuid) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on tid.tid_oi_vintages, tid.v_oi_vintage_contracts, tid.v_oi_vintage_summary, tid.v_oi_mapping_report from anon, authenticated';
    execute 'revoke all on function tid.record_oi_capture(text, bigint[], uuid) from anon, authenticated';
  end if;
end $$;
