-- Tests for db/tid-4.0-agent-contest.sql. Fresh database after baseline-replica, 3.2, 3.3, 2.12 and 4.0.
-- Fixed timestamps from Mon 2026-11-30 onward (the contest is started at the real current time first).

create or replace function pg_temp.q(p_at timestamptz, p_contract text, p_bid numeric, p_ask numeric, p_und numeric)
returns bigint language sql as $$
  insert into tid.tid_raw_snapshots (captured_at, endpoint, symbol, contract_key, request_params, request_key,
                                     capture_status, payload, raw_sha256, payload_sha256, row_sha256)
  values (p_at, 'tradytics/options/contracts', left(p_contract, length(p_contract) - 15), p_contract, '{}', 'k', 'complete',
          jsonb_build_object('data', jsonb_build_object('contract', p_contract, 'bid', p_bid, 'ask', p_ask, 'underlying_price', p_und)),
          repeat('a', 64), 'p', 'r')
  returning snapshot_id;
$$;
create or replace function pg_temp.sub(p_agent text, p_at text, p_contract text, p_hold int default 5,
                                       p_target numeric default 50, p_stop numeric default 40)
returns jsonb language sql as $$
  select tid._contest_submit(p_agent, (p_at || ' America/New_York')::timestamptz, 'idea', p_contract,
                             'test thesis for ' || p_contract, 0.6, p_target, p_stop, p_hold);
$$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'expected error like "%", got "%"', p_like, sqlerrm; end if;
    return;
  end;
  raise exception 'expected error like "%", but the statement succeeded: %', p_like, p_sql;
end $$;

-- 1. submission rules
do $$ begin
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 09:50', 'NVDA261210C00150000')$q$, '%not started%');
  perform tid.contest_start('test');
  perform pg_temp.expect_error($q$select tid.contest_start()$q$, '%already started%');
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 11:00', 'NVDA261210C00150000')$q$, '%outside a submission window%');
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 09:50', 'NVDA261207C00150000')$q$, '%7 days out%');
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 09:50', 'NVDA261215C00150000')$q$, '%15 days out%');
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 09:50', 'NVDA 150 call')$q$, '%OCC symbol%');
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 09:50', 'NVDA261210C00150000', 10)$q$, '%max_hold_days must be between 1 and 9%');
  perform pg_temp.expect_error($q$select pg_temp.sub('gemini', '2026-11-30 09:50', 'NVDA261210C00150000')$q$, '%unknown or inactive agent%');
  perform pg_temp.sub('claude', '2026-11-30 09:50', 'NVDA261210C00150000');
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 09:51', 'NVDA261210C00150000')$q$, '%already submitted in this window%');
  perform pg_temp.sub('claude', '2026-11-30 09:55', 'AMD261211P00100000');
  perform pg_temp.sub('claude', '2026-11-30 09:56', 'TSLA261211C00300000');
  perform pg_temp.expect_error($q$select pg_temp.sub('claude', '2026-11-30 09:57', 'MU261211C00100000')$q$, '%limit of 3%');
  perform pg_temp.expect_error($q$select tid._contest_submit('claude', '2026-11-30 09:58 America/New_York', 'skip', null, 'nothing', null, null, null, null)$q$, '%already has submissions%');
  perform tid._contest_submit('chatgpt', '2026-11-30 10:00 America/New_York', 'skip', null, 'no setup I like', null, null, null, null);
  perform pg_temp.expect_error($q$select pg_temp.sub('chatgpt', '2026-11-30 10:01', 'NVDA261210C00150000')$q$, '%already skipped%');
  raise notice 'PASS 4.0-1: start, windows, expiry range, OCC format, hold limit, duplicates, per-window cap, skips';
end $$;

-- 2. more ideas
do $$ begin
  perform pg_temp.sub('chatgpt', '2026-11-30 12:20', 'SPY261211P00600000', 1);        -- time exit next day
  perform pg_temp.sub('claude',  '2026-11-30 12:25', 'XYZ261208C00050000', 7);        -- expiry, settled at intrinsic
  perform pg_temp.sub('chatgpt', '2026-11-30 14:50', 'META261211C00600000');          -- never captured
  raise notice 'PASS 4.0-2: second and third window submissions';
end $$;

-- 3. entries, marks and exits
do $$
declare r jsonb; x record; n int;
begin
  -- nothing to quote before w1 closes; after it closes, 3 entry contracts
  select count(*) into n from tid.contest_prepare('2026-11-30 10:10 America/New_York');
  assert n = 0, format('before window close expected 0 contracts, got %s', n);
  select count(*) into n from tid.contest_prepare('2026-11-30 10:16 America/New_York');
  assert n = 3, format('after w1 close expected 3 contracts, got %s', n);

  r := tid.contest_record_quote(pg_temp.q('2026-11-30 10:16 America/New_York', 'NVDA261210C00150000', 2.0, 2.2, 150), '2026-11-30 10:16 America/New_York');
  assert (r->>'filled')::int = 1, format('NVDA fill: %s', r);
  r := tid.contest_record_quote(pg_temp.q('2026-11-30 10:16 America/New_York', 'AMD261211P00100000', 0, 0, 98), '2026-11-30 10:16 America/New_York');
  assert (r->>'voided_no_quote')::int = 1, format('AMD void: %s', r);
  r := tid.contest_record_quote(pg_temp.q('2026-11-30 10:17 America/New_York', 'TSLA261211C00300000', 4.8, 5.0, 300), '2026-11-30 10:17 America/New_York');
  assert (r->>'filled')::int = 1, format('TSLA fill: %s', r);

  -- 12:46: NVDA bid 3.4 vs entry ask 2.2 = +54.5% >= 50 target; SPY put enters at ask 4.0; XYZ enters at 1.0
  r := tid.contest_record_quote(pg_temp.q('2026-11-30 12:46 America/New_York', 'NVDA261210C00150000', 3.4, 3.6, 156), '2026-11-30 12:46 America/New_York');
  assert (r->>'closed')::int = 1, format('NVDA target: %s', r);
  r := tid.contest_record_quote(pg_temp.q('2026-11-30 12:46 America/New_York', 'SPY261211P00600000', 3.8, 4.0, 600), '2026-11-30 12:46 America/New_York');
  r := tid.contest_record_quote(pg_temp.q('2026-11-30 12:46 America/New_York', 'XYZ261208C00050000', 0.9, 1.0, 50), '2026-11-30 12:46 America/New_York');
  -- same-capture entry is not also a mark
  assert (select count(*) from tid.tid_trade_marks m join tid.tid_trade_ideas i using (idea_id) where i.contract = 'SPY261211P00600000') = 0, 'entry capture marked';

  -- 2026-11-30 17:30: META idea never got an entry capture -> missed_capture
  perform tid.contest_prepare('2026-11-30 17:30 America/New_York');
  assert (select f.entry_status from tid.tid_trade_fills f join tid.tid_trade_ideas i using (idea_id) where i.contract = 'META261211C00600000') = 'missed_capture', 'missed capture';

  -- Tue 12-01 10:16: TSLA bid 2.9 vs 5.0 = -42% <= -40 stop; SPY time exit (hold 1 day) at bid 4.2, underlying fell (put right)
  r := tid.contest_record_quote(pg_temp.q('2026-12-01 10:16 America/New_York', 'TSLA261211C00300000', 2.9, 3.1, 290), '2026-12-01 10:16 America/New_York');
  assert (r->>'closed')::int = 1, format('TSLA stop: %s', r);
  r := tid.contest_record_quote(pg_temp.q('2026-12-01 10:16 America/New_York', 'SPY261211P00600000', 4.2, 4.4, 595), '2026-12-01 10:16 America/New_York');
  assert (r->>'closed')::int = 1, format('SPY time: %s', r);

  -- XYZ: no quote on 12-07 (time exit day) -> stays open; expiry day 12-08 no quote -> intrinsic 53 - 50 = 3
  r := tid.contest_record_quote(pg_temp.q('2026-12-07 10:16 America/New_York', 'XYZ261208C00050000', 0, 0, 52), '2026-12-07 10:16 America/New_York');
  assert (r->>'closed')::int = 0 and (r->>'marked')::int = 1, format('XYZ no quote: %s', r);
  r := tid.contest_record_quote(pg_temp.q('2026-12-08 15:16 America/New_York', 'XYZ261208C00050000', 0, 0, 53), '2026-12-08 15:16 America/New_York');
  assert (r->>'closed')::int = 1, format('XYZ expiry: %s', r);

  for x in select contract, entry_status, entry_price, exit_reason, exit_price, return_pct, pnl_usd, direction_correct
             from tid.v_contest_trades where kind = 'idea' order by idea_id loop
    raise notice '  % % entry=% exit=% @ % ret=% pnl=% dir=%', x.contract, x.entry_status, x.entry_price,
      x.exit_reason, x.exit_price, x.return_pct, x.pnl_usd, x.direction_correct;
  end loop;
  select * into x from tid.v_contest_trades where contract = 'NVDA261210C00150000';
  assert x.exit_reason = 'target' and x.entry_price = 2.2 and x.exit_price = 3.4 and x.return_pct = 54.5455 and x.direction_correct, 'NVDA result';
  select * into x from tid.v_contest_trades where contract = 'TSLA261211C00300000';
  assert x.exit_reason = 'stop' and x.return_pct = -42 and not x.direction_correct, 'TSLA result';
  select * into x from tid.v_contest_trades where contract = 'SPY261211P00600000';
  assert x.exit_reason = 'time' and x.return_pct = 5 and x.direction_correct, 'SPY result';
  select * into x from tid.v_contest_trades where contract = 'XYZ261208C00050000';
  assert x.exit_reason = 'expiry' and x.exit_price = 3 and x.return_pct = 200 and x.pnl_usd = 2000, 'XYZ result';
  raise notice 'PASS 4.0-3: entry at ask, no-quote void, missed capture, target, stop, time, expiry at intrinsic';
end $$;

-- 4. scoreboard and paired comparison
do $$
declare s record; p record;
begin
  select * into s from tid.v_contest_scoreboard where agent_id = 'claude';
  assert s.ideas = 4 and s.filled = 3 and s.void_no_quote = 1 and s.closed = 3 and s.open = 0, format('claude board: %s', row_to_json(s));
  select * into s from tid.v_contest_scoreboard where agent_id = 'chatgpt';
  assert s.ideas = 2 and s.skipped_windows = 1 and s.void_system = 1 and s.closed = 1, format('chatgpt board: %s', row_to_json(s));
  select * into p from tid.v_contest_paired;
  assert p.paired_windows = 1, format('paired: %s', row_to_json(p));   -- 11-30 w2: claude XYZ +200 vs chatgpt SPY +5
  assert p.mean_diff_claude_minus_chatgpt_pct = 195, format('paired diff: %s', row_to_json(p));
  raise notice 'PASS 4.0-4: scoreboard counts and paired window difference';
end $$;

-- 5. integrity
do $$ begin
  perform pg_temp.expect_error($q$update tid.tid_trade_ideas set confidence = 1$q$, '%append-only%');
  perform pg_temp.expect_error($q$delete from tid.tid_trade_results$q$, '%append-only%');
  perform pg_temp.expect_error($q$select tid.contest_record_quote(tid.capture_snapshot('tradytics/options/chain', 'NVDA', null, '{}', null, '{"data":[]}', 'complete', null, repeat('c', 64), null, 't'), now())$q$, '%not a complete tradytics/options/contracts%');
  raise notice 'PASS 4.0-5: ledger append-only; wrong snapshot type rejected';
end $$;

select 'ALL TESTS PASSED' as result;
