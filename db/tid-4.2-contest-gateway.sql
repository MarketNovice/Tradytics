-- TID-4.2 Contest submission gateway: per-agent tokens and one entry point for the contest-submit Edge Function.
-- Requires TID-4.0/4.1. Idempotent.
--
-- Agents never get database credentials. Each agent gets a bearer token; the database stores only its
-- SHA-256. The Edge Function passes the token to tid.contest_gateway, which works out the agent from the
-- token and calls the same submission rules as the database roles do. A token can be revoked at any time.
--
-- Owner: issue a token (shown once; store it in the agent's configuration, not in chat or git):
--   select tid.contest_issue_token('chatgpt', 'ChatGPT custom GPT action');
-- Revoke all of an agent's tokens:
--   select tid.contest_revoke_tokens('chatgpt');

create table if not exists tid.tid_contest_agent_tokens (
  token_id     bigint generated always as identity primary key,
  agent_id     text not null references tid.tid_contest_agents (agent_id),
  token_sha256 text not null unique,
  label        text,
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz,
  last_used_at timestamptz
);
alter table tid.tid_contest_agent_tokens enable row level security;

create or replace function tid.contest_issue_token(p_agent text, p_label text default null)
returns text language plpgsql security definer set search_path to '' as $$
declare v_token text;
begin
  if not exists (select 1 from tid.tid_contest_agents where agent_id = p_agent) then
    raise exception 'unknown agent %', p_agent;
  end if;
  -- two random (v4) UUIDs: 244 random bits, no extension needed
  v_token := 'tidc_' || p_agent || '_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into tid.tid_contest_agent_tokens (agent_id, token_sha256, label)
  values (p_agent, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), p_label);
  return v_token;
end; $$;

create or replace function tid.contest_revoke_tokens(p_agent text)
returns int language plpgsql security definer set search_path to '' as $$
declare n int;
begin
  update tid.tid_contest_agent_tokens set revoked_at = now() where agent_id = p_agent and revoked_at is null;
  get diagnostics n = row_count;
  return n;
end; $$;

-- Own ideas for a given agent (the role-based tid.my_trade_ideas uses the login role instead).
create or replace function tid._contest_ideas_for(p_agent text, p_limit int default 50)
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x.idea_id desc), '[]'::jsonb) from (
    select i.idea_id, i.submitted_at, i.session_date, i.window_name, i.kind, i.contract, i.direction, i.confidence,
           i.target_pct, i.stop_pct, i.max_hold_days, f.entry_status, f.quality_reasons, f.entry_price,
           r.exit_reason, r.exit_price, r.return_pct, r.direction_correct
    from tid.tid_trade_ideas i
    left join tid.tid_trade_fills f on f.idea_id = i.idea_id
    left join tid.tid_trade_results r on r.idea_id = i.idea_id
    where i.agent_id = p_agent
    order by i.idea_id desc limit greatest(1, least(p_limit, 200))) x;
$$;

-- The single entry point. Returns {ok, agent, result} or {ok:false, error}. Never raises for rule errors,
-- so the Edge Function can return the message to the agent.
create or replace function tid.contest_gateway(p_token text, p_action text, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_agent text;
  v_id    bigint;
  r       jsonb;
begin
  select t.agent_id, t.token_id into v_agent, v_id
  from tid.tid_contest_agent_tokens t
  join tid.tid_contest_agents a on a.agent_id = t.agent_id and a.active
  where t.token_sha256 = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') and t.revoked_at is null;
  if v_agent is null then
    return jsonb_build_object('ok', false, 'status', 401, 'error', 'invalid or revoked token');
  end if;
  update tid.tid_contest_agent_tokens set last_used_at = now() where token_id = v_id;

  begin
    case p_action
      when 'rules' then r := tid.contest_rules();
      when 'my_ideas' then r := tid._contest_ideas_for(v_agent, coalesce((p_payload->>'limit')::int, 50));
      when 'submit' then
        r := tid._contest_submit(v_agent, clock_timestamp(), 'idea', p_payload->>'contract', p_payload->>'thesis',
               (p_payload->>'confidence')::numeric, (p_payload->>'target_pct')::numeric,
               (p_payload->>'stop_pct')::numeric, (p_payload->>'max_hold_days')::int);
      when 'skip' then
        r := tid._contest_submit(v_agent, clock_timestamp(), 'skip', null, p_payload->>'reason', null, null, null, null);
      else
        return jsonb_build_object('ok', false, 'status', 404, 'error', format('unknown action %s', p_action));
    end case;
  exception when others then
    return jsonb_build_object('ok', false, 'status', 422, 'agent', v_agent, 'error', sqlerrm);
  end;
  return jsonb_build_object('ok', true, 'agent', v_agent, 'result', r);
end; $$;

revoke all on tid.tid_contest_agent_tokens from public;
revoke all on function tid.contest_issue_token(text, text) from public;
revoke all on function tid.contest_revoke_tokens(text) from public;
revoke all on function tid._contest_ideas_for(text, int) from public;
revoke all on function tid.contest_gateway(text, text, jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on tid.tid_contest_agent_tokens from anon, authenticated';
    execute 'revoke all on function tid.contest_issue_token(text, text), tid.contest_revoke_tokens(text), tid._contest_ideas_for(text, int), tid.contest_gateway(text, text, jsonb) from anon, authenticated';
  end if;
end $$;

-- The Edge Function uses the project's built-in database connection (SUPABASE_DB_URL) and calls only
-- tid.contest_gateway; agent identity comes from the token, checked here, never from the caller.
