// contest-submit: the agents' way into the contest (TID-4.2). Deployed as a Supabase Edge Function.
//
//   GET  .../contest-submit/health[?probe=1] readiness: database, whether the live pre-check is configured
//   GET  .../contest-submit/rules            contest rules and the window open now
//   GET  .../contest-submit/ideas?limit=50   your own ideas and results
//   POST .../contest-submit/ideas            submit an idea (JSON body, see docs/contest-api.openapi.yaml)
//   POST .../contest-submit/skip             skip the current window: {"reason": "..."}
//
// Auth: "Authorization: Bearer <agent token>" (tokens from tid.contest_issue_token; only their hashes are stored).
// Before recording an idea, the contract is checked live against the contest's quality limits (spread, open
// interest, delta, earnings before the planned exit, listed). A failing idea is rejected with reasons and NOT
// recorded, so the agent can fix it inside the window. The referee checks again at entry; that check is final.
//
// Env: SUPABASE_DB_URL (provided by Supabase), TRADYTICS_API_KEY (Edge Function secret; without it the live
// pre-check is skipped and only the entry check applies).

import postgres from "npm:postgres@3.4.4";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 3, idle_timeout: 20 });
const TRADYTICS = "https://tradytics.com/api/public/v1";
const KEY = Deno.env.get("TRADYTICS_API_KEY");

// deno-lint-ignore no-explicit-any
type Json = any;
const json = (status: number, body: Json) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });

async function gateway(token: string, action: string, payload: Json = {}) {
  return (await sql`select tid.contest_gateway(${token}::text, ${action}::text, ${sql.json(payload)}::jsonb) as r`)[0].r;
}

function etDate(d = new Date()) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(d); // YYYY-MM-DD
}
function addDays(day: string, n: number) {
  const t = new Date(day + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10);
}

async function tradytics(path: string): Promise<{ status: number; body: Json }> {
  const res = await fetch(TRADYTICS + path, { headers: { Authorization: `Bearer ${KEY}`, Accept: "application/json" } });
  let body: Json = null;
  try { body = await res.json(); } catch { /* non-JSON */ }
  return { status: res.status, body };
}

// Live contract check with the same limits the referee applies at entry.
async function precheck(contract: string, maxHold: number, q: Json): Promise<{ reasons: string[]; notes: string[]; quote?: Json }> {
  const reasons: string[] = [], notes: string[] = [];
  if (!KEY) return { reasons, notes: ["live pre-check not configured; the referee checks at entry"] };
  try {
    const c = await tradytics(`/options/contracts/${encodeURIComponent(contract)}`);
    if (c.status === 404) return { reasons: [`contract not listed: ${c.body?.error?.message ?? contract}`], notes };
    if (c.status !== 200 || !c.body?.data) {
      return { reasons, notes: [`live quote unavailable (HTTP ${c.status}); the referee checks at entry`] };
    }
    const d = c.body.data;
    const bid = Number(d.bid), ask = Number(d.ask);
    if (!(ask > 0 && bid >= 0 && ask >= bid)) {
      notes.push("no two-sided quote right now; if there is none at entry the idea is void");
    } else {
      const spread = (ask - bid) / ((ask + bid) / 2) * 100;
      if (spread > Number(q.max_spread_pct)) reasons.push(`spread ${spread.toFixed(1)}% > ${q.max_spread_pct}%`);
    }
    if (d.open_interest == null) notes.push("open interest not available");
    else if (Number(d.open_interest) < Number(q.min_open_interest)) reasons.push(`open interest ${d.open_interest} < ${q.min_open_interest}`);
    const delta = d.delta == null ? null : Math.abs(Number(d.delta));
    if (delta == null) notes.push("delta not available");
    else if (delta < Number(q.abs_delta[0]) || delta > Number(q.abs_delta[1])) {
      reasons.push(`delta ${delta.toFixed(3)} outside ${q.abs_delta[0]}-${q.abs_delta[1]}`);
    }
    if (q.no_earnings_before_exit) {
      const today = etDate();
      const exit = addDays(today, maxHold);
      const e = await tradytics(`/calendar/earnings?symbol=${encodeURIComponent(contract.slice(0, -15))}`);
      if (e.status === 200 && Array.isArray(e.body?.data)) {
        const next = e.body.data.map((x: Json) => String(x.date ?? "")).filter((x: string) => x >= today).sort()[0];
        if (next && next <= exit) reasons.push(`earnings ${next} on or before planned exit ${exit}`);
      } else notes.push("earnings calendar unavailable; the referee checks at entry");
    }
    return { reasons, notes, quote: { bid: d.bid, ask: d.ask, open_interest: d.open_interest, delta: d.delta, updated_at: d.updated_at } };
  } catch (e) {
    return { reasons, notes: [`live pre-check failed (${(e as Error).message}); the referee checks at entry`] };
  }
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return json(401, { ok: false, error: "missing Authorization: Bearer <agent token>" });

    if (req.method === "GET" && route === "health") {
      // Readiness only: never returns the key. ?probe=1 makes one Tradytics call to prove the key works.
      const r = await gateway(token, "rules");
      if (!r.ok) return json(r.status ?? 401, r);
      let probe: Json = null;
      if (url.searchParams.get("probe") === "1" && KEY) {
        try {
          const t = await tradytics("/market/indices");
          probe = { tradytics_http_status: t.status, tradytics_ok: t.status === 200 };
        } catch (e) { probe = { tradytics_ok: false, error: (e as Error).message }; }
      }
      return json(200, { ok: true, agent: r.agent, database_ok: true, precheck_configured: !!KEY,
                         contest_started: r.result.started, current_window: r.result.current_window, probe });
    }
    if (req.method === "GET" && route === "rules") {
      const r = await gateway(token, "rules");
      return json(r.ok ? 200 : r.status ?? 400, r);
    }
    if (req.method === "GET" && route === "ideas") {
      const r = await gateway(token, "my_ideas", { limit: Number(url.searchParams.get("limit") ?? 50) });
      return json(r.ok ? 200 : r.status ?? 400, r);
    }
    if (req.method === "POST" && (route === "ideas" || route === "skip")) {
      let body: Json;
      try { body = await req.json(); } catch { return json(400, { ok: false, error: "body must be JSON" }); }
      if (route === "skip") {
        const r = await gateway(token, "skip", { reason: body?.reason });
        return json(r.ok ? 201 : r.status ?? 400, r);
      }
      // Authenticate and read the limits first; pre-check only when a submission could actually be accepted.
      const rules = await gateway(token, "rules");
      if (!rules.ok) return json(rules.status ?? 401, rules);
      const contract = String(body?.contract ?? "").trim().toUpperCase();
      let pre: { reasons: string[]; notes: string[]; quote?: Json } = { reasons: [], notes: [] };
      // Only spend Tradytics calls when the database rules (window, expiry range, holding days) can pass.
      const m = /^[A-Z0-9.]{1,6}(\d{2})(\d{2})(\d{2})[CP]\d{8}$/.exec(contract);
      const days = m ? Math.round((Date.parse(`20${m[1]}-${m[2]}-${m[3]}T00:00:00Z`) - Date.parse(`${etDate()}T00:00:00Z`)) / 86400000) : -1;
      const [minD, maxD] = rules.result.expiry_days ?? [8, 14];
      const hold = Number(body?.max_hold_days);
      const rulesCanPass = days >= minD && days <= maxD && hold >= 1 && hold <= days - 1;
      if (rules.result.started && rules.result.current_window && m && rulesCanPass) {
        pre = await precheck(contract, Number(body?.max_hold_days ?? 0), rules.result.contract_quality_at_entry);
        if (pre.reasons.length) {
          return json(422, { ok: false, agent: rules.agent, recorded: false,
            error: "contract fails the contest quality checks; fix and resubmit inside the window",
            reasons: pre.reasons, notes: pre.notes, quote: pre.quote });
        }
      }
      const r = await gateway(token, "submit", {
        contract, thesis: body?.thesis, confidence: body?.confidence, target_pct: body?.target_pct,
        stop_pct: body?.stop_pct, max_hold_days: body?.max_hold_days,
      });
      return json(r.ok ? 201 : r.status ?? 400, { ...r, recorded: !!r.ok, precheck_notes: pre.notes, quote: pre.quote });
    }
    return json(404, { ok: false, error: "routes: GET health, GET rules, GET ideas, POST ideas, POST skip" });
  } catch (e) {
    console.error(e);
    return json(500, { ok: false, error: "internal error" });
  }
});
