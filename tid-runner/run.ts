// tid-runner/run.ts
// Deterministic replacement for the chat-based scheduled scans.
// Calls the Tradytics REST API, writes through the existing ingestion functions
// (begin_ingestion_batch / upsert_ingestion_records_bulk / finalize_ingestion_batch),
// records every raw response with TID-3.2 capture_snapshot, records OI vintages (TID-2.12),
// and verifies each batch by reading it back.
//
// Usage:
//   deno run -A run.ts --scan morning|midday|afternoon|oi|auto [--window] [--dry-run] [--force]
//
//   --window   refuse to run outside the scan's ET window (used by the scheduled workflow, so the
//              cron entry for the other DST offset exits without doing anything)
//   --dry-run  fetch and print counts and one sample per feed; needs only TRADYTICS_API_KEY; writes nothing
//   --force    run on weekends/holidays and repeat a scan that already completed today
//
// Exit codes: 0 done or expected skip, 1 one or more feeds failed, 2 setup error, 3 aborted on API quota.
//
// Env: TRADYTICS_API_KEY (required), DATABASE_URL (required unless --dry-run),
//      TRADYTICS_BASE_URL, TRADYTICS_RPM (default 8), BARS_LOOKBACK_DAYS (default 150),
//      OI_MAX_DTE (default 60), REQUIRE_SNAPSHOTS (default 1; set 0 to allow runs without TID-3.2)

import postgres from "npm:postgres@3.4.4";

type ScanType = "morning" | "midday" | "afternoon" | "oi";
const SCANS: ScanType[] = ["morning", "midday", "afternoon", "oi"];
const RUNNER_VERSION = "tid-runner/0.1.1";
const SOURCE = "Tradytics";
const BASE = Deno.env.get("TRADYTICS_BASE_URL") ?? "https://tradytics.com/api/public/v1";
const RPM = Number(Deno.env.get("TRADYTICS_RPM") ?? "8");
const BARS_LOOKBACK_DAYS = Number(Deno.env.get("BARS_LOOKBACK_DAYS") ?? "150");
const OI_MAX_DTE = Number(Deno.env.get("OI_MAX_DTE") ?? "60");
const REQUIRE_SNAPSHOTS = (Deno.env.get("REQUIRE_SNAPSHOTS") ?? "1") !== "0";
const COHORT_ID = "TID_50_COHORT";

// ET windows [start, end) in minutes after midnight. Morning must finish before the 09:30 open.
const WINDOWS: Record<ScanType, [number, number]> = {
  morning: [7 * 60, 9 * 60 + 25],
  midday: [11 * 60 + 30, 13 * 60 + 45],
  afternoon: [14 * 60 + 30, 16 * 60],
  oi: [17 * 60, 23 * 60 + 30],
};

const UNIVERSE = ("NVDA,MU,SNDK,AMD,TSLA,JNJ,AMZN,AAPL,AVGO,VLO,BA,META,INTC,MSFT,GOOGL,NBIS,CRWD,MSTR,CRWV,RDDT," +
  "DELL,PLTR,ORCL,UNH,GME,BE,LULU,AMAT,NFLX,FSLR,MRVL,COIN,ADBE,MRNA,HOOD,EXE,VSAT,SMCI,LITE,CAT,IREN,JPM,APH," +
  "LRCX,NOW,CMI,GPN,WMT,STX,RIOT").split(",");
const QUOTE_SET = [...UNIVERSE, "SPY", "QQQ", "IWM"];

// ------------------------------------------------------------------ arguments
class SetupError extends Error {}
class QuotaError extends Error {}

const args = Deno.args;
const DRY = args.includes("--dry-run");
const FORCE = args.includes("--force");
const WINDOW = args.includes("--window");
function scanArgument(): ScanType | "auto" {
  const i = args.indexOf("--scan");
  const v = i >= 0 ? args[i + 1] : undefined;
  if (!v || v.startsWith("--")) throw new SetupError(`--scan is required: ${[...SCANS, "auto"].join("|")}`);
  if (v !== "auto" && !SCANS.includes(v as ScanType)) throw new SetupError(`unknown scan "${v}"`);
  return v as ScanType | "auto";
}

// deno-lint-ignore no-explicit-any
let sql: any = null;
let runId: string | null = null;
let snapshotsOn = false;
const snapStats = { stored: 0, failed: 0 };

// ------------------------------------------------------------------ helpers
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function sha256(s: string) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}
function et(now = new Date()) {
  const p = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23", weekday: "short",
  }).formatToParts(now);
  const g = (t: string) => p.find((x) => x.type === t)!.value;
  return { date: `${g("year")}-${g("month")}-${g("day")}`, minutes: +g("hour") * 60 + +g("minute"), weekday: g("weekday") };
}
function addDays(d: string, n: number) {
  const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10);
}
const hhmm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;

// Builds a record key and refuses missing parts, so a missing field can never collapse days onto one key.
function key(...parts: unknown[]): string {
  for (const p of parts) if (p === undefined || p === null || p === "") throw new Error(`record key part missing in ${JSON.stringify(parts)}`);
  return parts.join(":");
}

let lastCall = 0;
async function throttle() {
  const wait = lastCall + 60000 / RPM - Date.now();
  if (wait > 0) await sleep(wait);
  lastCall = Date.now();
}
function retryAfterSeconds(h: string | null, fallback: number): number {
  if (!h) return fallback;
  const n = Number(h);
  if (isFinite(n)) return n;
  const t = Date.parse(h);
  return isFinite(t) ? Math.max(0, (t - Date.now()) / 1000) : fallback;
}

// deno-lint-ignore no-explicit-any
type Json = any;
interface ApiResult { json: Json; url: string; rawSha: string; asOf: string | null; snapshotId: number | null }
interface ApiOpts { project?: (json: Json) => Json }

async function snap(path: string, params: Json, r: ApiResult | null, reason: string | null, receivedAt: string | null, payload?: Json): Promise<number | null> {
  if (!sql || !snapshotsOn) return null;
  const sym = params.symbol && !String(params.symbol).includes(",") ? String(params.symbol) : null;
  try {
    const row = (await sql`select tid.capture_snapshot(
      ${"tradytics" + path}::text, ${sym}::text, null::text, ${sql.json(params)}::jsonb,
      ${r?.asOf ?? null}::timestamptz, ${r ? sql.json(payload ?? r.json) : null}::jsonb,
      ${r ? "complete" : "missing"}::text, ${reason}::text, ${r?.rawSha ?? null}::text,
      ${runId}::uuid, ${RUNNER_VERSION}::text, ${receivedAt}::timestamptz) as id`)[0];
    snapStats.stored++;
    return Number(row.id);
  } catch (e) {
    snapStats.failed++;
    const msg = `snapshot capture failed: ${(e as Error).message}`;
    console.error(msg);
    if (REQUIRE_SNAPSHOTS) throw new Error(msg);
    return null;
  }
}

async function api(path: string, params: Json, opts: ApiOpts = {}, attempt = 0): Promise<ApiResult> {
  const clean: Json = {};
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null) clean[k] = v;
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(clean)) url.searchParams.set(k, String(v));
  await throttle();
  let res: Response, text: string;
  try {
    res = await fetch(url, { headers: { Authorization: `Bearer ${Deno.env.get("TRADYTICS_API_KEY")}`, Accept: "application/json" } });
    text = await res.text();
  } catch (e) {
    if (attempt < 2) { await sleep(3000 * (attempt + 1)); return api(path, params, opts, attempt + 1); }
    await snap(path, clean, null, `network: ${(e as Error).message}`, new Date().toISOString());
    throw e;
  }
  const receivedAt = new Date().toISOString();
  if (res.status === 429) {
    if (/quota_exceeded/i.test(text)) {
      await snap(path, clean, null, `quota_exceeded: ${text.slice(0, 200)}`, receivedAt);
      throw new QuotaError(`daily quota exceeded (resets 00:00 UTC): ${text.slice(0, 300)}`);
    }
    if (attempt < 3) {
      const wait = Math.min(retryAfterSeconds(res.headers.get("retry-after"), 10), 120);
      console.error(`rate limited on ${path}; waiting ${Math.round(wait)}s`);
      await sleep(wait * 1000);
      return api(path, params, opts, attempt + 1);
    }
  }
  if (res.status >= 500 && attempt < 2) {
    await sleep(Math.min(retryAfterSeconds(res.headers.get("retry-after"), 5), 60) * 1000);
    return api(path, params, opts, attempt + 1);
  }
  if (!res.ok) {
    await snap(path, clean, null, `http ${res.status}: ${text.slice(0, 200)}`, receivedAt);
    throw new Error(`${path} -> HTTP ${res.status}: ${text.slice(0, 300)}`);
  }
  let json: Json;
  try { json = JSON.parse(text); }
  catch {
    await snap(path, clean, null, `non-JSON 200 response: ${text.slice(0, 200)}`, receivedAt);
    throw new Error(`${path} -> non-JSON 200 response`);
  }
  const out: ApiResult = { json, url: url.toString(), rawSha: await sha256(text), asOf: json?.meta?.as_of ?? null, snapshotId: null };
  out.snapshotId = await snap(path, clean, out, null, receivedAt, opts.project ? opts.project(json) : undefined);
  return out;
}

// REST and MCP shapes differ; accept {data:[...]}, {data:{columns,rows}}, or {data:{...}}.
function rows(json: Json): Json[] {
  const d = json?.data;
  if (Array.isArray(d)) return d;
  if (d && Array.isArray(d.columns) && Array.isArray(d.rows)) {
    return d.rows.map((r: Json[]) => Object.fromEntries(d.columns.map((c: string, i: number) => [c, r[i]])));
  }
  if (d && typeof d === "object") return [d];
  return [];
}

// Follows next_cursor via the "cursor" parameter (confirmed in the 2026-11-24 dry run).
async function fetchAll(path: string, params: Json, opts: ApiOpts = {}, maxPages = 40) {
  const pages: ApiResult[] = [];
  const seen = new Set<string>();
  let cursor: string | undefined, complete = true, more = false, error: string | null = null;
  for (let i = 0; i < maxPages; i++) {
    const r = await api(path, { ...params, cursor }, opts);
    pages.push(r);
    const next = r.json?.next_cursor;
    if (next === null || next === undefined || next === "") break;
    const nk = String(next);
    if (seen.has(nk)) { complete = false; more = true; error = "repeated cursor detected"; break; }
    seen.add(nk); cursor = nk;
    if (i === maxPages - 1) { complete = false; more = true; error = "page cap reached"; }
  }
  return { pages, complete, more, error, all: pages.flatMap((p) => rows(p.json)) };
}

interface Rec { record_key: string; source_event_key: string; payload: Json; symbol: string | null; source_event_at: string | null; source_as_of: string | null }
const rec = (k: string, payload: Json, symbol: string | null, at: string | null, asOf: string | null): Rec =>
  ({ record_key: k, source_event_key: k, payload, symbol, source_event_at: at, source_as_of: asOf });

interface Built { records: Rec[]; pages: number; complete: boolean; more: boolean; error: string | null; asOf: string | null; meta: Json; after?: () => Promise<void> }
interface FeedOutcome { feedType: string; ok: boolean; received: number; error: string | null; snapshots_failed?: number }
const maxAsOf = (a: ApiResult[]) => a.map((p) => p.asOf).filter(Boolean).sort().pop() ?? null;

// Converts rows to records, collecting key errors instead of failing on the first.
function toRecords(all: Json[], make: (x: Json) => Rec, errors: string[]): Rec[] {
  const out: Rec[] = [];
  for (const x of all) {
    try { out.push(make(x)); } catch (e) { errors.push((e as Error).message); }
  }
  return out;
}

// ------------------------------------------------------------------ persistence
async function persist(feedType: string, b: Built): Promise<FeedOutcome> {
  if (DRY) {
    console.log(`[dry] ${feedType}: ${b.records.length} records, pages=${b.pages}, complete=${b.complete}, error=${b.error}`);
    if (b.records[0]) console.log("      sample:", JSON.stringify(b.records[0]).slice(0, 400));
    return { feedType, ok: !b.error && b.complete, received: b.records.length, error: b.error };
  }
  const meta = { ...b.meta, runner: RUNNER_VERSION };
  const row = (await sql`select * from tid.begin_ingestion_batch(
      ${feedType}::text, ${SOURCE}::text, ${runId}::uuid, ${b.asOf}::timestamptz,
      ${b.records.length}::int, ${b.pages}::int, ${sql.json(meta)}::jsonb)`)[0];
  const batchId = row.batch_id ?? row.begin_ingestion_batch ?? Object.values(row)[0];
  let upsertError: string | null = null;
  try {
    for (let i = 0; i < b.records.length; i += 500) {
      await sql`select * from tid.upsert_ingestion_records_bulk(${batchId}::uuid, ${sql.json(b.records.slice(i, i + 500))}::jsonb)`;
    }
    if (b.after) await b.after();
  } catch (e) { upsertError = (e as Error).message; }
  const err = b.error ?? upsertError;
  await sql`select * from tid.finalize_ingestion_batch(
      ${batchId}::uuid, ${b.pages}::int, ${b.complete && !upsertError}::boolean, ${b.more}::boolean,
      ${err}::text, ${sql.json(meta)}::jsonb)`;

  // Readback: never trust the finalize response.
  const bt = (await sql`select status, quality_status, pagination_complete, records_received, records_upserted, error_text
                        from tid.tid_ingestion_batches where batch_id = ${batchId}::uuid`)[0];
  const linked = (await sql`select count(*)::int as n from tid.tid_ingestion_batch_records where batch_id = ${batchId}::uuid`)[0].n;
  const ok = bt.status === "complete" && bt.quality_status === "pass" && bt.pagination_complete === true && linked === bt.records_received;
  console.log(`${feedType}: status=${bt.status} quality=${bt.quality_status} received=${bt.records_received} ` +
    `upserted=${bt.records_upserted} linked=${linked} ok=${ok}`);
  return { feedType, ok, received: bt.records_received, error: ok ? null : (bt.error_text ?? err ?? "readback mismatch") };
}

async function runFeed(feedType: string, build: () => Promise<Built>): Promise<FeedOutcome> {
  const snapFailedBefore = snapStats.failed;
  let built: Built;
  try { built = await build(); }
  catch (e) {
    if (e instanceof QuotaError) throw e;
    built = { records: [], pages: 0, complete: false, more: false, error: String((e as Error).message), asOf: null, meta: { failed_before_write: true } };
  }
  let out: FeedOutcome;
  try { out = await persist(feedType, built); }
  catch (e) { out = { feedType, ok: false, received: 0, error: `persist failed: ${(e as Error).message}` }; }
  out.snapshots_failed = snapStats.failed - snapFailedBefore;
  return out;
}

// ------------------------------------------------------------------ feeds
// Per-symbol loop used by bars, daily flow and OI. A quota error aborts the whole run.
async function perSymbol(symbols: string[], each: (sym: string) => Promise<void>, errors: string[]) {
  for (const sym of symbols) {
    try { await each(sym); }
    catch (e) {
      if (e instanceof QuotaError) throw e;
      errors.push(`${sym}: ${(e as Error).message}`);
    }
  }
}
const summarize = (errors: string[]) => errors.length ? `${errors.length} error(s): ${errors.slice(0, 5).join("; ")}` : null;

function quotesFeed(): () => Promise<Built> {
  return async () => {
    const r = await fetchAll("/stocks/quotes", { symbol: QUOTE_SET.join(",") });
    const asOf = maxAsOf(r.pages); const errors: string[] = r.error ? [r.error] : [];
    const records = toRecords(r.all, (q) => rec(key("quote", q.symbol, q.price_at), q, q.symbol, q.price_at, asOf), errors);
    if (records.length !== QUOTE_SET.length) errors.push(`expected ${QUOTE_SET.length} quotes, got ${records.length}`);
    return { records, pages: r.pages.length, complete: r.complete, more: r.more, error: summarize(errors), asOf,
      meta: { endpoint: "/stocks/quotes", symbols: QUOTE_SET.length } };
  };
}
function marketFeed(path: string, keyFn: (x: Json, asOf: string | null) => string, extra: Json = {}): () => Promise<Built> {
  return async () => {
    const r = await fetchAll(path, extra);
    const asOf = maxAsOf(r.pages); const errors: string[] = r.error ? [r.error] : [];
    const records = toRecords(r.all, (x) => rec(keyFn(x, asOf), x, null, x.time ?? x.date ?? asOf, asOf), errors);
    if (records.length === 0) errors.push("no rows");
    return { records, pages: r.pages.length, complete: r.complete, more: r.more, error: summarize(errors), asOf, meta: { endpoint: path, ...extra } };
  };
}
function cohortFlowFeed(session: string): () => Promise<Built> {
  return async () => {
    // Cohort AGGREGATE. Rows carry no symbol. Never attribute to individual tickers.
    const r = await fetchAll("/options/flow/timeline", { symbol: UNIVERSE.join(","), interval: "15m", date: session });
    const asOf = maxAsOf(r.pages); const errors: string[] = r.error ? [r.error] : [];
    const records = toRecords(r.all, (x) => rec(key("cohortflow", COHORT_ID, x.time), { ...x, cohort: COHORT_ID, members: UNIVERSE }, COHORT_ID, x.time, asOf), errors);
    return { records, pages: r.pages.length, complete: r.complete, more: r.more, error: summarize(errors), asOf,
      meta: { endpoint: "/options/flow/timeline", interval: "15m", date: session, aggregate: true, cohort: COHORT_ID } };
  };
}
function symbolFlowFeed(session: string): () => Promise<Built> {
  return async () => {
    const records: Rec[] = []; const empty: string[] = []; const errors: string[] = []; const asOfs: string[] = [];
    let pages = 0, complete = true, more = false;
    await perSymbol(UNIVERSE, async (sym) => {
      const r = await fetchAll("/options/flow/timeline", { symbol: sym, interval: "1d", from: addDays(session, -60), to: session });
      pages += r.pages.length; complete &&= r.complete; more ||= r.more;
      if (r.error) errors.push(`${sym}: ${r.error}`);
      const a = maxAsOf(r.pages); if (a) asOfs.push(a);
      if (r.all.length === 0) {
        empty.push(sym); // explicit empty-feed status, never imputed as zero
        records.push(rec(key("flow1d", sym, "EMPTY", session), { status: "empty_feed", session }, sym, null, a));
      }
      records.push(...toRecords(r.all, (x) => rec(key("flow1d", sym, x.date ?? x.time), x, sym, x.time ?? null, a), errors));
    }, errors);
    if (errors.length) complete = false;
    return { records, pages, complete, more, error: summarize(errors), asOf: asOfs.sort().pop() ?? null,
      meta: { endpoint: "/options/flow/timeline", interval: "1d", empty_symbols: empty, failed: errors.length } };
  };
}
function barsFeed(session: string): () => Promise<Built> {
  return async () => {
    const today = et().date;
    const from = addDays(session, -BARS_LOOKBACK_DAYS);
    const records: Rec[] = []; const bars: Json[] = []; const errors: string[] = []; const asOfs: string[] = [];
    let pages = 0, complete = true, more = false;
    await perSymbol([...UNIVERSE, "SPY"], async (sym) => {
      const r = await fetchAll("/stocks/bars", { symbol: sym, timeframe: "1d", from, to: session, limit: 100 });
      pages += r.pages.length; complete &&= r.complete; more ||= r.more;
      if (r.error) errors.push(`${sym}: ${r.error}`);
      const a = maxAsOf(r.pages); if (a) asOfs.push(a);
      for (const x of r.all) {
        const d = String(x.time ?? "").slice(0, 10);
        // Only sessions before today: the vendor still revises the current day's bar hours after the close.
        if (!/^\d{4}-\d{2}-\d{2}$/.test(d) || d >= today) continue;
        records.push(rec(key("bars1d", sym, d), x, sym, x.time, a));
        bars.push({ symbol: sym, session_date: d, open: x.open, high: x.high, low: x.low, close: x.close, volume: x.volume, source_as_of: a });
      }
    }, errors);
    if (errors.length) complete = false;
    return {
      records, pages, complete, more, error: summarize(errors), asOf: asOfs.sort().pop() ?? null,
      meta: { endpoint: "/stocks/bars", timeframe: "1d", from, to: session, failed: errors.length },
      after: async () => {
        if (!sql || bars.length === 0) return;
        await sql`insert into tid.tid_market_bars (symbol, session_date, timeframe, open, high, low, close, volume, source, source_as_of)
          select x->>'symbol', (x->>'session_date')::date, '1d', (x->>'open')::numeric, (x->>'high')::numeric,
                 (x->>'low')::numeric, (x->>'close')::numeric, (x->>'volume')::numeric, 'Tradytics', (x->>'source_as_of')::timestamptz
          from jsonb_array_elements(${sql.json(bars)}::jsonb) x
          on conflict (symbol, session_date) do update set
            open = excluded.open, high = excluded.high, low = excluded.low, close = excluded.close,
            volume = excluded.volume, source_as_of = excluded.source_as_of
          where tid.tid_market_bars.source_as_of is null or excluded.source_as_of >= tid.tid_market_bars.source_as_of`;
      },
    };
  };
}

// TID-2.12: per-contract OI chain. Each page is stored as a 'chain_oi_v1' projection snapshot, then
// tid.record_oi_capture turns the symbol's pages into an OI vintage (new or repeat).
const projectChain = (json: Json) => ({
  projection: "chain_oi_v1",
  columns: ["contract", "open_interest", "volume", "delta"],
  rows: rows(json).map((r) => [r.contract, r.open_interest, r.volume, r.delta]),
  meta: json?.meta ?? null,
  next_cursor: json?.next_cursor ?? null,
});
function oiFeed(session: string, scan: ScanType): () => Promise<Built> {
  return async () => {
    if (!DRY && !snapshotsOn) throw new Error("OI capture requires TID-3.2 snapshots");
    const records: Rec[] = []; const errors: string[] = []; const asOfs: string[] = [];
    let pages = 0, complete = true, more = false, newVintages = 0;
    await perSymbol(UNIVERSE, async (sym) => {
      const r = await fetchAll("/options/chain", { symbol: sym, limit: 1000, max_dte: OI_MAX_DTE }, { project: projectChain });
      pages += r.pages.length; complete &&= r.complete; more ||= r.more;
      if (r.error) throw new Error(r.error);
      const a = maxAsOf(r.pages); if (a) asOfs.push(a);
      const bad = r.all.filter((x) => typeof x.contract !== "string" || typeof x.open_interest !== "number").length;
      if (bad) throw new Error(`${bad} chain rows lack contract or open_interest`);
      if (r.all.length === 0) throw new Error("empty chain");
      const calls = r.all.filter((x) => x.type === "call"), puts = r.all.filter((x) => x.type === "put");
      const summary: Json = {
        session, scan, contracts: r.all.length, nonzero_oi: r.all.filter((x) => x.open_interest > 0).length,
        call_oi: calls.reduce((s, x) => s + x.open_interest, 0), put_oi: puts.reduce((s, x) => s + x.open_interest, 0),
        max_dte: OI_MAX_DTE, pages: r.pages.length, snapshot_ids: r.pages.map((p) => p.snapshotId),
      };
      if (sql) {
        const v = (await sql`select tid.record_oi_capture(${sym}::text, ${r.pages.map((p) => p.snapshotId)}::bigint[], ${runId}::uuid) as v`)[0].v;
        summary.vintage = v; if (v.new) newVintages++;
      }
      records.push(rec(key("oi_chain", sym, session, scan), summary, sym, null, a));
    }, errors);
    if (errors.length) complete = false;
    return { records, pages, complete, more, error: summarize(errors), asOf: asOfs.sort().pop() ?? null,
      meta: { endpoint: "/options/chain", max_dte: OI_MAX_DTE, projection: "chain_oi_v1", new_vintages: newVintages, failed: errors.length } };
  };
}

function feedsFor(scan: ScanType, session: string): [string, () => Promise<Built>][] {
  const market: [string, () => Promise<Built>][] = [
    ["tradytics_symbol_quotes", quotesFeed()],
    ["tradytics_market_indices", marketFeed("/market/indices", (x) => key("index", x.symbol, x.time))],
    ["tradytics_market_breadth", marketFeed("/market/breadth", (_x, a) => key("breadth", a))],
    ["tradytics_sector_snapshot", marketFeed("/market/sectors", (x) => key("sector", x.etf ?? x.name, x.date), { type: "sector" })],
  ];
  switch (scan) {
    case "morning": return [
      ["tradytics_open_interest_chain", oiFeed(session, scan)], // first: OI must be captured before the open
      ["tradytics_daily_bars", barsFeed(session)],
      ["tradytics_symbol_flow_1d", symbolFlowFeed(session)],
      ...market,
    ];
    case "midday": case "afternoon": return [...market, ["tradytics_options_flow_timeline", cohortFlowFeed(session)]];
    case "oi": return [["tradytics_open_interest_chain", oiFeed(session, scan)]];
  }
}

// ------------------------------------------------------------------ main
async function main(): Promise<number> {
  if (UNIVERSE.length !== 50) throw new SetupError(`universe must be 50 symbols, got ${UNIVERSE.length}`);
  if (!Deno.env.get("TRADYTICS_API_KEY")) throw new SetupError("TRADYTICS_API_KEY is required");
  if (!DRY && !Deno.env.get("DATABASE_URL")) throw new SetupError("DATABASE_URL is required (or use --dry-run)");
  const requested = scanArgument();
  const now = et();
  const inWindow = (s: ScanType) => now.minutes >= WINDOWS[s][0] && now.minutes < WINDOWS[s][1];

  let scan: ScanType;
  if (requested === "auto") {
    const s = SCANS.find(inWindow);
    if (!s) { console.log(`ET ${hhmm(now.minutes)}: no scan window open; nothing to do.`); return 0; }
    scan = s;
  } else scan = requested;
  if (WINDOW && !inWindow(scan)) {
    console.log(`ET ${hhmm(now.minutes)} is outside the ${scan} window ${hhmm(WINDOWS[scan][0])}-${hhmm(WINDOWS[scan][1])}; skipping.`);
    return 0;
  }
  const session = now.date;
  if ((now.weekday === "Sat" || now.weekday === "Sun") && !FORCE) { console.log("Weekend; exiting."); return 0; }

  if (!DRY) {
    sql = postgres(Deno.env.get("DATABASE_URL")!, { max: 2, prepare: false, onnotice: () => {} });
    if (!FORCE && (await sql`select tid.is_trading_day(${session}::date) as t`)[0].t === false) {
      console.log(`${session} is a market holiday; exiting.`); return 0;
    }
    // Runs that never finished (process killed) would otherwise sit at 'pending' forever.
    await sql`update tid.tid_scan_runs set ledger_write_status = 'abandoned'
      where run_metadata->>'runner' = 'tid-runner' and ledger_write_status = 'pending'
        and run_completed_at is null and run_started_at < now() - interval '2 hours'`;
    if (!FORCE) {
      const done = await sql`select run_id from tid.tid_scan_runs
        where run_metadata->>'runner' = 'tid-runner' and run_metadata->>'scan_type' = ${scan}
          and market_session = ${session}::date and ledger_write_status in ('written', 'complete') limit 1`;
      if (done.length) { console.log(`A completed ${scan} run already exists for ${session} (${done[0].run_id}); use --force to repeat.`); return 0; }
    }
    snapshotsOn = (await sql`select to_regproc('tid.capture_snapshot') as f`)[0].f !== null;
    if (!snapshotsOn && REQUIRE_SNAPSHOTS) throw new SetupError("tid.capture_snapshot is not installed (TID-3.2); set REQUIRE_SNAPSHOTS=0 to run without it");
    runId = (await sql`insert into tid.tid_scan_runs (scan_name, market_session, universe_definition, universe_rows, run_metadata)
      values (${`TID ${scan} scheduled (tid-runner)`}, ${session}::date,
              'TID selected 50-symbol cohort; index membership unverified', 50,
              ${sql.json({ runner: "tid-runner", runner_version: RUNNER_VERSION, scan_type: scan, snapshots: snapshotsOn,
                           oi_max_dte: OI_MAX_DTE, rpm: RPM })}::jsonb)
      returning run_id`)[0].run_id;
    console.log(`scan_run ${runId} (${scan}, session ${session}, snapshots=${snapshotsOn})`);
  }

  const feeds = feedsFor(scan, session);
  const out: FeedOutcome[] = [];
  let quotaError: string | null = null;
  for (const [t, b] of feeds) {
    if (quotaError) { out.push({ feedType: t, ok: false, received: 0, error: "not attempted: quota exceeded" }); continue; }
    try { out.push(await runFeed(t, b)); }
    catch (e) {
      if (!(e instanceof QuotaError)) throw e;
      quotaError = e.message;
      out.push({ feedType: t, ok: false, received: 0, error: e.message });
      console.error(`ABORTING: ${e.message}`);
    }
  }

  const okN = out.filter((f) => f.ok).length;
  const allOk = okN === out.length;
  console.log(`\nSUMMARY ${scan} ${session}: ${okN}/${out.length} feeds ok; snapshots stored=${snapStats.stored} failed=${snapStats.failed}`);
  for (const f of out) if (!f.ok) console.log(`  FAILED ${f.feedType}: ${f.error}`);

  if (!DRY && sql) {
    const ledger = allOk ? "written" : okN > 0 ? "partial" : "not_written";
    await sql`update tid.tid_scan_runs set run_completed_at = now(),
      coverage_pct = ${(100 * okN) / out.length}::numeric, pagination_complete = ${allOk}::boolean,
      ledger_write_status = ${ledger}::text,
      data_quality = ${sql.json({ feeds: out, snapshots: snapStats, quota_aborted: quotaError })}::jsonb
      where run_id = ${runId}::uuid`;
    const back = (await sql`select ledger_write_status, run_completed_at from tid.tid_scan_runs where run_id = ${runId}::uuid`)[0];
    console.log(`scan_run readback: ledger=${back.ledger_write_status} completed=${back.run_completed_at}`);
  }
  return quotaError ? 3 : allOk ? 0 : 1;
}

let code: number;
try { code = await main(); }
catch (e) {
  console.error(`${e instanceof SetupError ? "SETUP ERROR" : "ERROR"}: ${(e as Error).message}`);
  code = e instanceof SetupError ? 2 : 1;
} finally {
  if (sql) await sql.end({ timeout: 5 });
}
Deno.exit(code!);
