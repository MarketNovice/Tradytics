-- Tests for db/tid-4.1-contest-quality.sql. Run after test-tid-4.0-contest.sql on the same database
-- (it relies on the contest having been started there).

create or replace function pg_temp.q(p_at timestamptz, p_contract text, p_bid numeric, p_ask numeric, p_und numeric,
                                     p_oi numeric, p_delta numeric)
returns bigint language sql as $$
  insert into tid.tid_raw_snapshots (captured_at, endpoint, symbol, contract_key, request_params, request_key,
                                     capture_status, payload, raw_sha256, payload_sha256, row_sha256)
  values (p_at, 'tradytics/options/contracts', left(p_contract, length(p_contract) - 15), p_contract, '{}', 'k', 'complete',
          jsonb_build_object('data', jsonb_strip_nulls(jsonb_build_object('contract', p_contract, 'bid', p_bid, 'ask', p_ask,
                             'underlying_price', p_und, 'open_interest', p_oi, 'delta', p_delta))),
          repeat('a', 64), 'p', 'r')
  returning snapshot_id;
$$;
create or replace function pg_temp.sub(p_agent text, p_at text, p_contract text, p_hold int default 5)
returns jsonb language sql as $$
  select tid._contest_submit(p_agent, (p_at || ' America/New_York')::timestamptz, 'idea', p_contract,
                             'quality test ' || p_contract, 0.5, 50, 40, p_hold);
$$;
create or replace function pg_temp.status(p_contract text) returns text language sql as $$
  select f.entry_status || coalesce(' ' || array_to_string(f.quality_reasons, '; '), '')
                        || coalesce(' unchecked=' || array_to_string(f.quality_unchecked, ','), '')
  from tid.tid_trade_fills f join tid.tid_trade_ideas i using (idea_id) where i.contract = p_contract;
$$;

do $$
declare t timestamptz := '2026-12-01 12:46 America/New_York'; s text;
begin
  perform pg_temp.sub('claude',  '2026-12-01 12:20', 'AAA261211C00100000');
  perform pg_temp.sub('claude',  '2026-12-01 12:21', 'BBB261211C00100000');
  perform pg_temp.sub('claude',  '2026-12-01 12:22', 'CCC261211C00100000');
  perform pg_temp.sub('chatgpt', '2026-12-01 12:23', 'DDD261211P00100000', 5);
  perform pg_temp.sub('chatgpt', '2026-12-01 12:24', 'EEE261211P00100000', 5);
  perform pg_temp.sub('chatgpt', '2026-12-01 12:25', 'FFF261211P00100000', 5);

  -- spread (1.4-1.0)/1.2 = 33%
  perform tid.contest_record_quote(pg_temp.q(t, 'AAA261211C00100000', 1.0, 1.4, 100, 1000, 0.5), t, '2027-01-30', true);
  -- open interest 100
  perform tid.contest_record_quote(pg_temp.q(t, 'BBB261211C00100000', 2.0, 2.1, 100, 100, 0.5), t, null, true);
  -- delta 0.10
  perform tid.contest_record_quote(pg_temp.q(t, 'CCC261211C00100000', 0.10, 0.11, 100, 5000, 0.10), t, null, true);
  -- earnings 12-03 before planned exit 12-06
  perform tid.contest_record_quote(pg_temp.q(t, 'DDD261211P00100000', 3.0, 3.2, 100, 900, -0.45), t, '2026-12-03', true);
  -- passes everything (earnings after exit)
  perform tid.contest_record_quote(pg_temp.q(t, 'EEE261211P00100000', 3.0, 3.2, 100, 900, -0.45), t, '2026-12-20', true);
  -- no delta in the quote and earnings not checked -> filled, both recorded as unchecked
  perform tid.contest_record_quote(pg_temp.q(t, 'FFF261211P00100000', 3.0, 3.2, 100, 900, null), t, null, false);

  s := pg_temp.status('AAA261211C00100000'); raise notice '  AAA: %', s; assert s like 'rejected_quality spread 33.3% > 15%%', s;
  s := pg_temp.status('BBB261211C00100000'); raise notice '  BBB: %', s; assert s like 'rejected_quality open interest 100 < 500%', s;
  s := pg_temp.status('CCC261211C00100000'); raise notice '  CCC: %', s; assert s like 'rejected_quality delta 0.100 outside 0.30-0.65%', s;
  s := pg_temp.status('DDD261211P00100000'); raise notice '  DDD: %', s; assert s like 'rejected_quality earnings 2026-12-03 on or before planned exit 2026-12-06%', s;
  s := pg_temp.status('EEE261211P00100000'); raise notice '  EEE: %', s; assert s = 'filled', s;
  s := pg_temp.status('FFF261211P00100000'); raise notice '  FFF: %', s; assert s = 'filled unchecked=delta,earnings', s;
  assert (select entry_price from tid.v_contest_trades where contract = 'EEE261211P00100000') = 3.2, 'EEE entry at ask';
  assert (select entry_price from tid.v_contest_trades where contract = 'AAA261211C00100000') is null, 'rejected has no entry price';
  raise notice 'PASS 4.1-1: spread, open interest, delta and earnings checks; unchecked recorded; passing idea fills at ask';
end $$;

do $$
declare s record;
begin
  select * into s from tid.v_contest_scoreboard where agent_id = 'claude';
  assert s.rejected_quality = 3, format('claude rejected: %s', row_to_json(s));
  select * into s from tid.v_contest_scoreboard where agent_id = 'chatgpt';
  assert s.rejected_quality = 1, format('chatgpt rejected: %s', row_to_json(s));
  assert (tid.contest_rules()->'contract_quality_at_entry'->>'max_spread_pct')::numeric = 15, 'rules show quality limits';
  raise notice 'PASS 4.1-2: scoreboard counts rejections; rules expose the limits';
end $$;

do $$
declare n int;
begin
  perform pg_temp.sub('claude', '2026-12-02 09:50', 'ZZZ261211C00100000');
  n := tid.contest_reject_unlisted('ZZZ261211C00100000', 'HTTP 404: No listed contract', '2026-12-02 10:16 America/New_York');
  assert n = 1, format('expected 1 rejection, got %s', n);
  assert pg_temp.status('ZZZ261211C00100000') like 'rejected_quality contract not listed%', pg_temp.status('ZZZ261211C00100000');
  n := tid.contest_reject_unlisted('ZZZ261211C00100000', 'again', '2026-12-02 12:46 America/New_York');
  assert n = 0, 'already rejected ideas are not touched again';
  raise notice 'PASS 4.1-3: unlisted contract rejected once, as the agent''s error';
end $$;

select 'ALL TESTS PASSED' as result;
