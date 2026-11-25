-- TID-4.0 Agent contest: ChatGPT vs Claude on 8-14 day long option trades
-- Requires TID-3.2 (snapshots), TID-3.3 (calendar), TID-2.12 (occ_* helpers). Idempotent.
-- Design and rules: docs/agent-contest.md. Owner decisions (2026-11-25): long calls/puts only; up to 3 ideas
-- per agent per window; buy at the ask, sell at the bid; verdicts at 400 (direction) and 1,000 (return)
-- closed trades per agent; Claude plays from a separate task; each agent gets a submit-only role.
--
-- Flow
--   1. An agent calls tid.submit_trade_idea(...) during a window. The database checks the rules and stamps
--      the time. Ideas are append-only.
--   2. After each window, tid-runner calls tid.contest_prepare(now) for the contracts to quote, fetches each
--      contract's quote (stored as a TID-3.2 snapshot), and calls tid.contest_record_quote(snapshot_id, now).
--   3. contest_record_quote fills new ideas at the ask (or voids them if there is no two-sided quote),
--      marks open trades, and closes them at the bid on target, stop, max holding day or expiry.
--   4. The owner reads tid.v_contest_scoreboard and tid.v_contest_paired.

-- ------------------------------------------------------------------ configuration
create table if not exists tid.tid_contest_config (
  id                    int primary key default 1 check (id = 1),
  notional_usd          numeric not null default 1000,
  max_ideas_per_window  int not null default 3,
  min_expiry_days       int not null default 8,
  max_expiry_days       int not null default 14,
  verdict_direction_n   int not null default 400,
  verdict_return_n      int not null default 1000,
  entry_price           text not null default 'ask' check (entry_price in ('ask', 'mid')),
  exit_price            text not null default 'bid' check (exit_price in ('bid', 'mid')),
  started_at            timestamptz,
  rules_sha256          text,
  note                  text
);
insert into tid.tid_contest_config (id) values (1) on conflict (id) do nothing;

create table if not exists tid.tid_contest_windows (
  window_name text primary key,
  start_et    time not null,
  end_et      time not null,
  check (end_et > start_et)
);
insert into tid.tid_contest_windows values
  ('w1', '09:45', '10:15'), ('w2', '12:15', '12:45'), ('w3', '14:45', '15:15')
on conflict (window_name) do nothing;

create table if not exists tid.tid_contest_agents (
  agent_id text primary key,
  db_role  text not null unique,
  active   boolean not null default true
);
insert into tid.tid_contest_agents values ('chatgpt', 'tid_agent_chatgpt', true), ('claude', 'tid_agent_claude', true)
on conflict (agent_id) do nothing;

-- ------------------------------------------------------------------ append-only ledger
create table if not exists tid.tid_trade_ideas (
  idea_id         bigint generated always as identity primary key,
  agent_id        text not null references tid.tid_contest_agents (agent_id),
  submitted_at    timestamptz not null,
  session_date    date not null,
  window_name     text not null references tid.tid_contest_windows (window_name),
  kind            text not null check (kind in ('idea', 'skip')),
  contract        text,
  underlying      text,
  option_type     text check (option_type in ('call', 'put')),
  direction       text check (direction in ('bullish', 'bearish')),
  strike          numeric,
  expiry          date,
  thesis          text not null,
  confidence      numeric check (confidence between 0 and 1),
  target_pct      numeric check (target_pct > 0 and target_pct <= 1000),
  stop_pct        numeric check (stop_pct > 0 and stop_pct < 100),
  max_hold_days   int check (max_hold_days >= 1),
  idea_sha256     text not null,
  check (kind = 'skip' or (contract is not null and confidence is not null and target_pct is not null
                           and stop_pct is not null and max_hold_days is not null))
);
create index if not exists tid_trade_ideas_agent_window_idx on tid.tid_trade_ideas (agent_id, session_date, window_name);
create index if not exists tid_trade_ideas_contract_idx on tid.tid_trade_ideas (contract);

create table if not exists tid.tid_trade_fills (
  idea_id        bigint primary key references tid.tid_trade_ideas (idea_id),
  filled_at      timestamptz not null,
  snapshot_id    bigint references tid.tid_raw_snapshots (snapshot_id),
  entry_status   text not null check (entry_status in ('filled', 'no_quote', 'missed_capture')),
  bid            numeric,
  ask            numeric,
  entry_price    numeric,
  underlying_entry numeric,
  check (entry_status <> 'filled' or entry_price > 0)
);

create table if not exists tid.tid_trade_marks (
  mark_id          bigint generated always as identity primary key,
  idea_id          bigint not null references tid.tid_trade_fills (idea_id),
  marked_at        timestamptz not null,
  snapshot_id      bigint not null references tid.tid_raw_snapshots (snapshot_id),
  bid              numeric,
  ask              numeric,
  underlying_price numeric,
  unique (idea_id, snapshot_id)
);

create table if not exists tid.tid_trade_results (
  idea_id           bigint primary key references tid.tid_trade_fills (idea_id),
  closed_at         timestamptz not null,
  snapshot_id       bigint references tid.tid_raw_snapshots (snapshot_id),
  exit_reason       text not null check (exit_reason in ('target', 'stop', 'time', 'expiry')),
  exit_price        numeric not null check (exit_price >= 0),
  return_pct        numeric not null,
  pnl_usd           numeric not null,
  underlying_exit   numeric,
  direction_correct boolean
);

-- append-only guards
do $$
declare t text;
begin
  foreach t in array array['tid_trade_ideas', 'tid_trade_fills', 'tid_trade_marks', 'tid_trade_results'] loop
    execute format('drop trigger if exists %I on tid.%I', t || '_append_only', t);
    execute format('create trigger %I before update or delete on tid.%I for each row execute function tid.trg_append_only()', t || '_append_only', t);
    execute format('drop trigger if exists %I on tid.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on tid.%I for each statement execute function tid.trg_append_only()', t || '_no_truncate', t);
  end loop;
end $$;

-- ------------------------------------------------------------------ helpers
create or replace function tid.contest_window_at(p_at timestamptz)
returns text language sql stable set search_path to '' as $$
  select w.window_name from tid.tid_contest_windows w
  where tid.is_trading_day((p_at at time zone 'America/New_York')::date)
    and (p_at at time zone 'America/New_York')::time >= w.start_et
    and (p_at at time zone 'America/New_York')::time <  w.end_et
  limit 1;
$$;

create or replace function tid.contest_window_end(p_day date, p_window text)
returns timestamptz language sql stable set search_path to '' as $$
  select (p_day + w.end_et) at time zone 'America/New_York' from tid.tid_contest_windows w where w.window_name = p_window;
$$;

-- ------------------------------------------------------------------ submission (core, not granted)
create or replace function tid._contest_submit(
  p_agent text, p_now timestamptz, p_kind text, p_contract text, p_thesis text, p_confidence numeric,
  p_target_pct numeric, p_stop_pct numeric, p_max_hold_days int
) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  cfg      tid.tid_contest_config%rowtype;
  v_win    text;
  v_day    date := (p_now at time zone 'America/New_York')::date;
  v_n      int;
  v_c      text := upper(btrim(coalesce(p_contract, '')));
  v_type   text; v_exp date; v_strike numeric; v_und text;
  v_id     bigint;
  v_hash   text;
begin
  select * into cfg from tid.tid_contest_config where id = 1;
  if cfg.started_at is null or p_now < cfg.started_at then raise exception 'contest has not started'; end if;
  if not exists (select 1 from tid.tid_contest_agents where agent_id = p_agent and active) then
    raise exception 'unknown or inactive agent %', p_agent;
  end if;
  v_win := tid.contest_window_at(p_now);
  if v_win is null then
    raise exception 'outside a submission window (ET %; windows 09:45-10:15, 12:15-12:45, 14:45-15:15 on trading days)',
      to_char(p_now at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI');
  end if;
  if nullif(btrim(coalesce(p_thesis, '')), '') is null then raise exception 'thesis (or skip reason) is required'; end if;

  if p_kind = 'skip' then
    if exists (select 1 from tid.tid_trade_ideas where agent_id = p_agent and session_date = v_day and window_name = v_win) then
      raise exception 'window % already has submissions from %', v_win, p_agent;
    end if;
  else
    select count(*) into v_n from tid.tid_trade_ideas
     where agent_id = p_agent and session_date = v_day and window_name = v_win;
    if exists (select 1 from tid.tid_trade_ideas where agent_id = p_agent and session_date = v_day and window_name = v_win and kind = 'skip') then
      raise exception 'window % was already skipped by %', v_win, p_agent;
    end if;
    if v_n >= cfg.max_ideas_per_window then
      raise exception 'limit of % ideas per window reached', cfg.max_ideas_per_window;
    end if;
    if v_c !~ '^[A-Z0-9.]{1,6}[0-9]{6}[CP][0-9]{8}$' then
      raise exception 'contract must be an OCC symbol like NVDA261204C00150000, got %', p_contract;
    end if;
    v_type := tid.occ_type(v_c); v_exp := tid.occ_expiry(v_c); v_strike := tid.occ_strike(v_c);
    v_und := left(v_c, length(v_c) - 15);
    if v_exp - v_day < cfg.min_expiry_days or v_exp - v_day > cfg.max_expiry_days then
      raise exception 'expiry % is % days out; must be % to % calendar days after %',
        v_exp, v_exp - v_day, cfg.min_expiry_days, cfg.max_expiry_days, v_day;
    end if;
    if p_confidence is null or p_confidence < 0 or p_confidence > 1 then raise exception 'confidence must be between 0 and 1'; end if;
    if p_target_pct is null or p_target_pct <= 0 or p_target_pct > 1000 then raise exception 'target_pct must be > 0 and <= 1000'; end if;
    if p_stop_pct is null or p_stop_pct <= 0 or p_stop_pct >= 100 then raise exception 'stop_pct must be > 0 and < 100'; end if;
    if p_max_hold_days is null or p_max_hold_days < 1 or p_max_hold_days > (v_exp - v_day) - 1 then
      raise exception 'max_hold_days must be between 1 and % (days to expiry minus 1)', (v_exp - v_day) - 1;
    end if;
    if exists (select 1 from tid.tid_trade_ideas where agent_id = p_agent and session_date = v_day
               and window_name = v_win and contract = v_c) then
      raise exception 'contract % already submitted in this window', v_c;
    end if;
  end if;

  v_hash := encode(sha256(convert_to(concat_ws('|', p_agent,
              to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), p_kind, v_c, p_thesis,
              p_confidence, p_target_pct, p_stop_pct, p_max_hold_days), 'UTF8')), 'hex');
  insert into tid.tid_trade_ideas (agent_id, submitted_at, session_date, window_name, kind, contract, underlying,
    option_type, direction, strike, expiry, thesis, confidence, target_pct, stop_pct, max_hold_days, idea_sha256)
  values (p_agent, p_now, v_day, v_win, p_kind, nullif(v_c, ''), v_und, v_type,
    case v_type when 'call' then 'bullish' when 'put' then 'bearish' end, v_strike, v_exp, btrim(p_thesis),
    case when p_kind = 'idea' then p_confidence end, case when p_kind = 'idea' then p_target_pct end,
    case when p_kind = 'idea' then p_stop_pct end, case when p_kind = 'idea' then p_max_hold_days end, v_hash)
  returning idea_id into v_id;
  return jsonb_build_object('idea_id', v_id, 'agent', p_agent, 'kind', p_kind, 'window', v_win,
    'session', v_day, 'contract', nullif(v_c, ''), 'expiry', v_exp, 'idea_sha256', v_hash,
    'entry', case when p_kind = 'idea' then 'priced at the ask from the quote captured after this window closes' end);
end;
$$;

-- Agent-facing wrappers: the agent is whoever is logged in (session_user), the time is the database clock.
create or replace function tid._contest_agent() returns text
language sql stable security definer set search_path to '' as $$
  select agent_id from tid.tid_contest_agents where db_role = session_user;
$$;

create or replace function tid.submit_trade_idea(
  p_contract text, p_thesis text, p_confidence numeric, p_target_pct numeric, p_stop_pct numeric, p_max_hold_days int
) returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_agent text := tid._contest_agent();
begin
  if v_agent is null then raise exception 'login role % is not a contest agent', session_user; end if;
  return tid._contest_submit(v_agent, clock_timestamp(), 'idea', p_contract, p_thesis, p_confidence,
                             p_target_pct, p_stop_pct, p_max_hold_days);
end; $$;

create or replace function tid.skip_window(p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_agent text := tid._contest_agent();
begin
  if v_agent is null then raise exception 'login role % is not a contest agent', session_user; end if;
  return tid._contest_submit(v_agent, clock_timestamp(), 'skip', null, p_reason, null, null, null, null);
end; $$;

create or replace function tid.contest_rules()
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
    'started', c.started_at is not null, 'started_at', c.started_at, 'rules_sha256', c.rules_sha256,
    'max_ideas_per_window', c.max_ideas_per_window, 'expiry_days', jsonb_build_array(c.min_expiry_days, c.max_expiry_days),
    'entry', 'ask of the quote captured after the window closes', 'exit', 'bid at the first mark that hits target/stop, or at max holding day',
    'notional_usd', c.notional_usd,
    'windows_et', (select jsonb_agg(jsonb_build_object('window', w.window_name, 'start', w.start_et, 'end', w.end_et) order by w.start_et) from tid.tid_contest_windows w),
    'current_window', tid.contest_window_at(clock_timestamp()))
  from tid.tid_contest_config c where c.id = 1;
$$;

create or replace function tid.my_trade_ideas(p_limit int default 100)
returns table (idea_id bigint, submitted_at timestamptz, session_date date, window_name text, kind text,
               contract text, direction text, confidence numeric, target_pct numeric, stop_pct numeric,
               max_hold_days int, entry_status text, entry_price numeric, exit_reason text, exit_price numeric,
               return_pct numeric, direction_correct boolean)
language sql stable security definer set search_path to '' as $$
  select i.idea_id, i.submitted_at, i.session_date, i.window_name, i.kind, i.contract, i.direction, i.confidence,
         i.target_pct, i.stop_pct, i.max_hold_days, f.entry_status, f.entry_price, r.exit_reason, r.exit_price,
         r.return_pct, r.direction_correct
  from tid.tid_trade_ideas i
  left join tid.tid_trade_fills f on f.idea_id = i.idea_id
  left join tid.tid_trade_results r on r.idea_id = i.idea_id
  where i.agent_id = tid._contest_agent()
  order by i.idea_id desc limit greatest(1, least(p_limit, 1000));
$$;

-- ------------------------------------------------------------------ scoring (runner)
-- Returns the contracts to quote now, in an order fixed by a hash so neither agent is systematically first.
-- Also voids ideas whose entry capture never happened (system failure, excluded from scoring and reported).
create or replace function tid.contest_prepare(p_now timestamptz default now())
returns table (contract text, purpose text)
language plpgsql security definer set search_path to '' as $$
begin
  insert into tid.tid_trade_fills (idea_id, filled_at, entry_status)
  select i.idea_id, p_now, 'missed_capture'
  from tid.tid_trade_ideas i
  where i.kind = 'idea' and not exists (select 1 from tid.tid_trade_fills f where f.idea_id = i.idea_id)
    and tid.contest_window_end(i.session_date, i.window_name) + interval '2 hours' < p_now;

  return query
  select c.contract, string_agg(distinct c.purpose, ',')
  from (
    select i.contract, 'entry' as purpose from tid.tid_trade_ideas i
     where i.kind = 'idea' and not exists (select 1 from tid.tid_trade_fills f where f.idea_id = i.idea_id)
       and tid.contest_window_end(i.session_date, i.window_name) <= p_now
    union all
    select i.contract, 'mark' from tid.tid_trade_ideas i join tid.tid_trade_fills f on f.idea_id = i.idea_id
     where f.entry_status = 'filled' and not exists (select 1 from tid.tid_trade_results r where r.idea_id = i.idea_id)
  ) c
  group by c.contract
  order by md5(c.contract || (p_now at time zone 'America/New_York')::date::text);
end; $$;

create or replace function tid.contest_record_quote(p_snapshot_id bigint, p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  s        tid.tid_raw_snapshots%rowtype;
  cfg      tid.tid_contest_config%rowtype;
  q        jsonb;
  v_c      text;
  v_bid    numeric; v_ask numeric; v_und numeric;
  v_ok     boolean;
  v_day    date := (p_now at time zone 'America/New_York')::date;
  i        record;
  v_ret    numeric; v_exit numeric; v_reason text; v_intr numeric;
  n_fill int := 0; n_void int := 0; n_mark int := 0; n_close int := 0;
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
  v_ok  := v_ask > 0 and v_bid >= 0 and v_ask >= v_bid;

  -- entries: ideas on this contract whose window has closed and that have no fill yet
  for i in select t.* from tid.tid_trade_ideas t
            where t.contract = v_c and t.kind = 'idea'
              and not exists (select 1 from tid.tid_trade_fills f where f.idea_id = t.idea_id)
              and tid.contest_window_end(t.session_date, t.window_name) <= s.captured_at loop
    insert into tid.tid_trade_fills (idea_id, filled_at, snapshot_id, entry_status, bid, ask, entry_price, underlying_entry)
    values (i.idea_id, s.captured_at, s.snapshot_id, case when v_ok then 'filled' else 'no_quote' end, v_bid, v_ask,
            case when v_ok then case cfg.entry_price when 'ask' then v_ask else (v_bid + v_ask) / 2 end end, v_und);
    if v_ok then n_fill := n_fill + 1; else n_void := n_void + 1; end if;
  end loop;

  -- marks and exits: filled, open trades on this contract filled before this capture
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
      -- no two-sided quote on expiry day: settle at intrinsic value from the underlying price
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

  return jsonb_build_object('contract', v_c, 'two_sided', v_ok, 'filled', n_fill, 'voided_no_quote', n_void,
                            'marked', n_mark, 'closed', n_close);
end; $$;

-- ------------------------------------------------------------------ start (owner only)
create or replace function tid.contest_start(p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_rules text; v_hash text;
begin
  if (select started_at from tid.tid_contest_config where id = 1) is not null then
    raise exception 'contest already started';
  end if;
  select jsonb_build_object('config', to_jsonb(c) - 'started_at' - 'rules_sha256' - 'note',
                            'windows', (select jsonb_agg(to_jsonb(w) order by w.window_name) from tid.tid_contest_windows w),
                            'agents', (select jsonb_agg(to_jsonb(a) order by a.agent_id) from tid.tid_contest_agents a))::text
    into v_rules from tid.tid_contest_config c where c.id = 1;
  v_hash := encode(sha256(convert_to(v_rules, 'UTF8')), 'hex');
  update tid.tid_contest_config set started_at = clock_timestamp(), rules_sha256 = v_hash, note = p_note where id = 1;
  update tid.tid_hb_expected_scans set required = true where scan_type like 'contest%';
  return jsonb_build_object('started_at', (select started_at from tid.tid_contest_config where id = 1), 'rules_sha256', v_hash, 'rules', v_rules::jsonb);
end; $$;

-- Contest scans for the heartbeat; required only once the contest starts.
insert into tid.tid_hb_expected_scans (scan_type, deadline_et, required, note) values
  ('contest1', '11:00', false, 'Contest entry/mark capture after window w1'),
  ('contest2', '13:30', false, 'Contest entry/mark capture after window w2'),
  ('contest3', '16:00', false, 'Contest entry/mark capture after window w3')
on conflict (scan_type) do nothing;

-- ------------------------------------------------------------------ owner views
create or replace view tid.v_contest_trades as
select i.idea_id, i.agent_id, i.session_date, i.window_name, i.submitted_at, i.kind, i.contract, i.underlying,
       i.direction, i.expiry, i.confidence, i.target_pct, i.stop_pct, i.max_hold_days, i.thesis,
       f.entry_status, f.filled_at, f.entry_price, f.underlying_entry,
       r.exit_reason, r.closed_at, r.exit_price, r.return_pct, r.pnl_usd, r.underlying_exit, r.direction_correct
from tid.tid_trade_ideas i
left join tid.tid_trade_fills f on f.idea_id = i.idea_id
left join tid.tid_trade_results r on r.idea_id = i.idea_id;

create or replace view tid.v_contest_scoreboard as
select a.agent_id,
  count(*) filter (where t.kind = 'idea')                                  as ideas,
  count(*) filter (where t.kind = 'skip')                                  as skipped_windows,
  count(*) filter (where t.entry_status = 'filled')                        as filled,
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

-- Windows where both agents have closed trades: the paired comparison (market conditions shared).
create or replace view tid.v_contest_paired as
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

-- ------------------------------------------------------------------ roles and access
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'tid_agent_chatgpt') then
    create role tid_agent_chatgpt login noinherit connection limit 3;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'tid_agent_claude') then
    create role tid_agent_claude login noinherit connection limit 3;
  end if;
end $$;
alter role tid_agent_chatgpt set statement_timeout = '30s';
alter role tid_agent_claude  set statement_timeout = '30s';

alter table tid.tid_contest_config  enable row level security;
alter table tid.tid_contest_windows enable row level security;
alter table tid.tid_contest_agents  enable row level security;
alter table tid.tid_trade_ideas     enable row level security;
alter table tid.tid_trade_fills     enable row level security;
alter table tid.tid_trade_marks     enable row level security;
alter table tid.tid_trade_results   enable row level security;
revoke all on tid.tid_contest_config, tid.tid_contest_windows, tid.tid_contest_agents, tid.tid_trade_ideas,
  tid.tid_trade_fills, tid.tid_trade_marks, tid.tid_trade_results, tid.v_contest_trades, tid.v_contest_scoreboard,
  tid.v_contest_paired from public;

revoke all on function tid._contest_submit(text, timestamptz, text, text, text, numeric, numeric, numeric, int) from public;
revoke all on function tid._contest_agent() from public;
revoke all on function tid.submit_trade_idea(text, text, numeric, numeric, numeric, int) from public;
revoke all on function tid.skip_window(text) from public;
revoke all on function tid.contest_rules() from public;
revoke all on function tid.my_trade_ideas(int) from public;
revoke all on function tid.contest_prepare(timestamptz) from public;
revoke all on function tid.contest_record_quote(bigint, timestamptz) from public;
revoke all on function tid.contest_start(text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on tid.tid_contest_config, tid.tid_contest_windows, tid.tid_contest_agents, tid.tid_trade_ideas, tid.tid_trade_fills, tid.tid_trade_marks, tid.tid_trade_results, tid.v_contest_trades, tid.v_contest_scoreboard, tid.v_contest_paired from anon, authenticated';
    execute 'revoke all on function tid.submit_trade_idea(text, text, numeric, numeric, numeric, int), tid.skip_window(text), tid.contest_rules(), tid.my_trade_ideas(int), tid.contest_prepare(timestamptz), tid.contest_record_quote(bigint, timestamptz), tid.contest_start(text), tid._contest_submit(text, timestamptz, text, text, text, numeric, numeric, numeric, int), tid._contest_agent() from anon, authenticated';
  end if;
end $$;

grant usage on schema tid to tid_agent_chatgpt, tid_agent_claude;
grant execute on function tid.submit_trade_idea(text, text, numeric, numeric, numeric, int), tid.skip_window(text),
  tid.contest_rules(), tid.my_trade_ideas(int) to tid_agent_chatgpt, tid_agent_claude;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'tid_runner') then
    execute 'grant execute on function tid.contest_prepare(timestamptz), tid.contest_record_quote(bigint, timestamptz) to tid_runner';
  end if;
end $$;
