-- TID-4.1 Contest contract-quality checks (playbook section 5), enforced at entry.
-- Requires TID-4.0. Must be applied before tid.contest_start(): the rules become part of the rules hash.
-- Idempotent.
--
-- At the entry capture (the referee's quote after the window closes), an idea whose contract fails any check
-- is voided as 'rejected_quality' with the reasons listed. Checks:
--   spread     (ask - bid) / mid <= max_spread_pct (15)
--   liquidity  open interest >= min_open_interest (500)
--   delta      min_abs_delta (0.30) <= |delta| <= max_abs_delta (0.65)   (playbook 0.35-0.60, with tolerance
--              for the move between submission and entry)
--   earnings   no report on or before the planned exit day (session date + max_hold_days)
-- A check whose data is missing from the quote (no delta, no open interest) is recorded as unchecked, not failed.

alter table tid.tid_contest_config
  add column if not exists max_spread_pct    numeric not null default 15,
  add column if not exists min_open_interest int     not null default 500,
  add column if not exists min_abs_delta     numeric not null default 0.30,
  add column if not exists max_abs_delta     numeric not null default 0.65,
  add column if not exists block_earnings    boolean not null default true;

alter table tid.tid_trade_fills add column if not exists quality_reasons text[];
alter table tid.tid_trade_fills add column if not exists quality_unchecked text[];
alter table tid.tid_trade_fills drop constraint if exists tid_trade_fills_entry_status_check;
alter table tid.tid_trade_fills add constraint tid_trade_fills_entry_status_check
  check (entry_status in ('filled', 'no_quote', 'missed_capture', 'rejected_quality'));

-- Signature changes: drop the old versions first.
drop function if exists tid.contest_record_quote(bigint, timestamptz);
drop function if exists tid.my_trade_ideas(int);

create or replace function tid.contest_record_quote(
  p_snapshot_id bigint, p_now timestamptz default now(),
  p_next_earnings date default null, p_earnings_checked boolean default false
) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  s        tid.tid_raw_snapshots%rowtype;
  cfg      tid.tid_contest_config%rowtype;
  q        jsonb;
  v_c      text;
  v_bid    numeric; v_ask numeric; v_und numeric; v_oi numeric; v_delta numeric; v_spread numeric;
  v_ok     boolean;
  v_day    date := (p_now at time zone 'America/New_York')::date;
  i        record;
  v_ret    numeric; v_exit numeric; v_reason text; v_intr numeric;
  v_bad    text[]; v_unchk text[];
  n_fill int := 0; n_void int := 0; n_rej int := 0; n_mark int := 0; n_close int := 0;
begin
  select * into cfg from tid.tid_contest_config where id = 1;
  select * into s from tid.tid_raw_snapshots where snapshot_id = p_snapshot_id;
  if s.snapshot_id is null then raise exception 'snapshot % not found', p_snapshot_id; end if;
  if s.endpoint <> 'tradytics/options/contracts' or s.capture_status <> 'complete' or s.contract_key is null then
    raise exception 'snapshot % is not a complete tradytics/options/contracts capture', p_snapshot_id;
  end if;
  q := coalesce(s.payload->'data', s.payload);
  v_c := upper(q->>'contract');
  if v_c is distinct from upper(s.contract_key) then
    raise exception 'snapshot % is for %, not %', p_snapshot_id, v_c, s.contract_key;
  end if;
  v_bid := nullif(q->>'bid', '')::numeric; v_ask := nullif(q->>'ask', '')::numeric;
  v_und := nullif(q->>'underlying_price', '')::numeric;
  v_oi := nullif(q->>'open_interest', '')::numeric;
  v_delta := abs(nullif(q->>'delta', '')::numeric);
  v_ok  := v_ask > 0 and v_bid >= 0 and v_ask >= v_bid;
  v_spread := case when v_ok and (v_bid + v_ask) > 0 then (v_ask - v_bid) / ((v_bid + v_ask) / 2) * 100 end;

  -- entries
  for i in select t.* from tid.tid_trade_ideas t
            where t.contract = v_c and t.kind = 'idea'
              and not exists (select 1 from tid.tid_trade_fills f where f.idea_id = t.idea_id)
              and tid.contest_window_end(t.session_date, t.window_name) <= s.captured_at loop
    v_bad := array[]::text[]; v_unchk := array[]::text[];
    if v_ok then
      if v_spread > cfg.max_spread_pct then
        v_bad := v_bad || format('spread %s%% > %s%%', round(v_spread, 1), cfg.max_spread_pct);
      end if;
      if v_oi is null then v_unchk := v_unchk || 'open_interest'::text;
      elsif v_oi < cfg.min_open_interest then
        v_bad := v_bad || format('open interest %s < %s', v_oi, cfg.min_open_interest);
      end if;
      if v_delta is null then v_unchk := v_unchk || 'delta'::text;
      elsif v_delta < cfg.min_abs_delta or v_delta > cfg.max_abs_delta then
        v_bad := v_bad || format('delta %s outside %s-%s', round(v_delta, 3), cfg.min_abs_delta, cfg.max_abs_delta);
      end if;
      if cfg.block_earnings then
        if not p_earnings_checked then v_unchk := v_unchk || 'earnings'::text;
        elsif p_next_earnings is not null and p_next_earnings <= i.session_date + i.max_hold_days then
          v_bad := v_bad || format('earnings %s on or before planned exit %s', p_next_earnings, i.session_date + i.max_hold_days);
        end if;
      end if;
    end if;
    insert into tid.tid_trade_fills (idea_id, filled_at, snapshot_id, entry_status, bid, ask, entry_price,
                                     underlying_entry, quality_reasons, quality_unchecked)
    values (i.idea_id, s.captured_at, s.snapshot_id,
            case when not v_ok then 'no_quote' when cardinality(v_bad) > 0 then 'rejected_quality' else 'filled' end,
            v_bid, v_ask,
            case when v_ok and cardinality(v_bad) = 0 then case cfg.entry_price when 'ask' then v_ask else (v_bid + v_ask) / 2 end end,
            v_und, nullif(v_bad, array[]::text[]), nullif(v_unchk, array[]::text[]));
    if not v_ok then n_void := n_void + 1; elsif cardinality(v_bad) > 0 then n_rej := n_rej + 1; else n_fill := n_fill + 1; end if;
  end loop;

  -- marks and exits (unchanged from 4.0)
  for i in select t.*, f.entry_price, f.underlying_entry, f.filled_at from tid.tid_trade_ideas t
            join tid.tid_trade_fills f on f.idea_id = t.idea_id
            where t.contract = v_c and f.entry_status = 'filled' and f.filled_at < s.captured_at
              and not exists (select 1 from tid.tid_trade_results r where r.idea_id = t.idea_id) loop
    insert into tid.tid_trade_marks (idea_id, marked_at, snapshot_id, bid, ask, underlying_price)
    values (i.idea_id, s.captured_at, s.snapshot_id, v_bid, v_ask, v_und) on conflict do nothing;
    n_mark := n_mark + 1;
    v_reason := null; v_exit := null;
    if v_ok then
      v_exit := case cfg.exit_price when 'bid' then v_bid else (v_bid + v_ask) / 2 end;
      v_ret := (v_exit / i.entry_price - 1) * 100;
      if v_ret >= i.target_pct then v_reason := 'target';
      elsif v_ret <= -i.stop_pct then v_reason := 'stop';
      elsif v_day >= i.session_date + i.max_hold_days then v_reason := 'time';
      elsif v_day >= i.expiry then v_reason := 'expiry';
      end if;
    elsif v_day >= i.expiry and v_und is not null then
      v_intr := greatest(0, case i.option_type when 'call' then v_und - i.strike else i.strike - v_und end);
      v_exit := v_intr; v_reason := 'expiry';
    end if;
    if v_reason is not null then
      insert into tid.tid_trade_results (idea_id, closed_at, snapshot_id, exit_reason, exit_price, return_pct, pnl_usd,
                                         underlying_exit, direction_correct)
      values (i.idea_id, s.captured_at, s.snapshot_id, v_reason, v_exit, round((v_exit / i.entry_price - 1) * 100, 4),
              round(cfg.notional_usd * (v_exit / i.entry_price - 1), 2), v_und,
              case when v_und is null or i.underlying_entry is null or v_und = i.underlying_entry then null
                   when i.option_type = 'call' then v_und > i.underlying_entry
                   else v_und < i.underlying_entry end);
      n_close := n_close + 1;
    end if;
  end loop;

  return jsonb_build_object('contract', v_c, 'two_sided', v_ok, 'spread_pct', round(v_spread, 2),
                            'filled', n_fill, 'voided_no_quote', n_void, 'rejected_quality', n_rej,
                            'marked', n_mark, 'closed', n_close);
end; $$;

create or replace function tid.my_trade_ideas(p_limit int default 100)
returns table (idea_id bigint, submitted_at timestamptz, session_date date, window_name text, kind text,
               contract text, direction text, confidence numeric, target_pct numeric, stop_pct numeric,
               max_hold_days int, entry_status text, quality_reasons text[], entry_price numeric,
               exit_reason text, exit_price numeric, return_pct numeric, direction_correct boolean)
language sql stable security definer set search_path to '' as $$
  select i.idea_id, i.submitted_at, i.session_date, i.window_name, i.kind, i.contract, i.direction, i.confidence,
         i.target_pct, i.stop_pct, i.max_hold_days, f.entry_status, f.quality_reasons, f.entry_price,
         r.exit_reason, r.exit_price, r.return_pct, r.direction_correct
  from tid.tid_trade_ideas i
  left join tid.tid_trade_fills f on f.idea_id = i.idea_id
  left join tid.tid_trade_results r on r.idea_id = i.idea_id
  where i.agent_id = tid._contest_agent()
  order by i.idea_id desc limit greatest(1, least(p_limit, 1000));
$$;

create or replace function tid.contest_rules()
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
    'started', c.started_at is not null, 'started_at', c.started_at, 'rules_sha256', c.rules_sha256,
    'max_ideas_per_window', c.max_ideas_per_window, 'expiry_days', jsonb_build_array(c.min_expiry_days, c.max_expiry_days),
    'entry', 'ask of the quote captured after the window closes', 'exit', 'bid at the first mark that hits target/stop, or at max holding day',
    'notional_usd', c.notional_usd,
    'contract_quality_at_entry', jsonb_build_object('max_spread_pct', c.max_spread_pct, 'min_open_interest', c.min_open_interest,
        'abs_delta', jsonb_build_array(c.min_abs_delta, c.max_abs_delta), 'no_earnings_before_exit', c.block_earnings),
    'windows_et', (select jsonb_agg(jsonb_build_object('window', w.window_name, 'start', w.start_et, 'end', w.end_et) order by w.start_et) from tid.tid_contest_windows w),
    'current_window', tid.contest_window_at(clock_timestamp()))
  from tid.tid_contest_config c where c.id = 1;
$$;

-- Owner views: add quality fields and the rejected count.
drop view if exists tid.v_contest_paired;
drop view if exists tid.v_contest_scoreboard;
drop view if exists tid.v_contest_trades;
create view tid.v_contest_trades as
select i.idea_id, i.agent_id, i.session_date, i.window_name, i.submitted_at, i.kind, i.contract, i.underlying,
       i.direction, i.expiry, i.confidence, i.target_pct, i.stop_pct, i.max_hold_days, i.thesis,
       f.entry_status, f.quality_reasons, f.quality_unchecked, f.filled_at, f.entry_price, f.underlying_entry,
       r.exit_reason, r.closed_at, r.exit_price, r.return_pct, r.pnl_usd, r.underlying_exit, r.direction_correct
from tid.tid_trade_ideas i
left join tid.tid_trade_fills f on f.idea_id = i.idea_id
left join tid.tid_trade_results r on r.idea_id = i.idea_id;

create view tid.v_contest_scoreboard as
select a.agent_id,
  count(*) filter (where t.kind = 'idea')                                  as ideas,
  count(*) filter (where t.kind = 'skip')                                  as skipped_windows,
  count(*) filter (where t.entry_status = 'filled')                        as filled,
  count(*) filter (where t.entry_status = 'rejected_quality')              as rejected_quality,
  count(*) filter (where t.entry_status = 'no_quote')                      as void_no_quote,
  count(*) filter (where t.entry_status = 'missed_capture')                as void_system,
  count(*) filter (where t.exit_reason is not null)                        as closed,
  count(*) filter (where t.entry_status = 'filled' and t.exit_reason is null) as open,
  round(avg(t.return_pct), 2)                                              as mean_return_pct,
  round((percentile_cont(0.5) within group (order by t.return_pct))::numeric, 2) as median_return_pct,
  round(stddev_samp(t.return_pct), 2)                                      as sd_return_pct,
  round(100.0 * avg((t.return_pct > 0)::int), 1)                           as win_rate_pct,
  round(100.0 * avg(t.direction_correct::int), 1)                          as direction_accuracy_pct,
  sum(t.pnl_usd)                                                           as total_pnl_usd,
  round(avg(t.confidence) filter (where t.return_pct > 0), 3)              as mean_conf_winners,
  round(avg(t.confidence) filter (where t.return_pct <= 0), 3)             as mean_conf_losers,
  (select verdict_direction_n from tid.tid_contest_config where id = 1)    as direction_verdict_at,
  (select verdict_return_n from tid.tid_contest_config where id = 1)       as return_verdict_at
from tid.tid_contest_agents a
left join tid.v_contest_trades t on t.agent_id = a.agent_id
group by a.agent_id;

create view tid.v_contest_paired as
with w as (
  select session_date, window_name,
         avg(return_pct) filter (where agent_id = 'claude')  as claude_mean,
         avg(return_pct) filter (where agent_id = 'chatgpt') as chatgpt_mean
  from tid.v_contest_trades where exit_reason is not null group by 1, 2
)
select count(*) as paired_windows,
       round(avg(claude_mean - chatgpt_mean), 2) as mean_diff_claude_minus_chatgpt_pct,
       round(stddev_samp(claude_mean - chatgpt_mean), 2) as sd_diff_pct,
       round((avg(claude_mean - chatgpt_mean)
              / nullif(stddev_samp(claude_mean - chatgpt_mean) / sqrt(count(*))::numeric, 0))::numeric, 2) as t_stat
from w where claude_mean is not null and chatgpt_mean is not null;

-- access (re-grant after drop/recreate)
revoke all on tid.v_contest_trades, tid.v_contest_scoreboard, tid.v_contest_paired from public;
revoke all on function tid.contest_record_quote(bigint, timestamptz, date, boolean) from public;
revoke all on function tid.my_trade_ideas(int) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on tid.v_contest_trades, tid.v_contest_scoreboard, tid.v_contest_paired from anon, authenticated';
    execute 'revoke all on function tid.contest_record_quote(bigint, timestamptz, date, boolean), tid.my_trade_ideas(int) from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'tid_runner') then
    execute 'grant execute on function tid.contest_record_quote(bigint, timestamptz, date, boolean) to tid_runner';
  end if;
end $$;
grant execute on function tid.my_trade_ideas(int) to tid_agent_chatgpt, tid_agent_claude;

-- A contract the vendor says is not listed is the agent's error, not a system failure: reject it at entry.
create or replace function tid.contest_reject_unlisted(p_contract text, p_detail text, p_now timestamptz default now())
returns int language plpgsql security definer set search_path to '' as $$
declare n int;
begin
  insert into tid.tid_trade_fills (idea_id, filled_at, entry_status, quality_reasons)
  select t.idea_id, p_now, 'rejected_quality', array['contract not listed: ' || left(coalesce(p_detail, ''), 200)]
  from tid.tid_trade_ideas t
  where t.contract = upper(p_contract) and t.kind = 'idea'
    and not exists (select 1 from tid.tid_trade_fills f where f.idea_id = t.idea_id)
    and tid.contest_window_end(t.session_date, t.window_name) <= p_now;
  get diagnostics n = row_count;
  return n;
end; $$;
revoke all on function tid.contest_reject_unlisted(text, text, timestamptz) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function tid.contest_reject_unlisted(text, text, timestamptz) from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'tid_runner') then
    execute 'grant execute on function tid.contest_reject_unlisted(text, text, timestamptz) to tid_runner';
  end if;
end $$;
