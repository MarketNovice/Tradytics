// tid-runner/run.ts
// Deterministic replacement for the chat-based scheduled scans.
// Calls the Tradytics REST API, writes through your EXISTING ingestion functions
// (begin_ingestion_batch / upsert_ingestion_records_bulk / finalize_ingestion_batch),
// records every raw response with TID-3.2 capture_snapshot when it is installed,
// and verifies each batch by reading it back.
//
// Usage:
//   deno run -A run.ts --scan auto|morning|midday|afternoon [--dry-run] [--force]
//
// --dry-run needs only TRADYTICS_API_KEY. It fetches, prints counts and one sample
// record per feed, and writes nothing. Run it first to confirm the endpoint and
// parameter assumptions marked ASSUMPTION below.
//
// Env: TRADYTICS_API_KEY (required), DATABASE_URL (required unless --dry-run),
//      TRADYTICS_BASE_URL, TRADYTICS_RPM (default 8), BARS_FROM (default 2026-08-20),
//      SNAPSHOTS (default on if tid.capture_snapshot exists)

import postgres from "npm:postgres@3.4.4";

type ScanType = "morning" | "midday" | "afternoon";
const RUNNER_VERSION = "tid-runner/0.1.0";
const SOURCE = "Tradytics";
const BASE = Deno.env.get("TRADYTICS_BASE_URL") ?? "https://tradytics.com/api/public/v1";
const RPM = Number(Deno.env.get("TRADYTICS_RPM") ?? "8"); // Plus plan is 10/min; Pro 300/min. Set to your plan.
const BARS_FROM = Deno.env.get("BARS_FROM") ?? "2026-08-20";
const COHORT_ID = "TID_50_COHORT";

const UNIVERSE = ("NVDA,MU,SNDK,AMD,TSLA,JNJ,AMZN,AAPL,AVGO,VLO,BA,META,INTC,MSFT,GOOGL,NBIS,CRWD,MSTR,CRWV,RDDT," +
  "DELL,PLTR,ORCL,UNH,GME,BE,LULU,AMAT,NFLX,FSLR,MRVL,COIN,ADBE,MRNA,HOOD,EXE,VSAT,SMCI,LITE,CAT,IREN,JPM,APH," +
  "LRCX,NOW,CMI,GPN,WMT,STX,RIOT").split(",");
if (UNIVERSE.length !== 50) throw new Error(`universe must be 50 symbols, got ${UNIVERSE.length}`);
const QUOTE_SET = [...UNIVERSE, "SPY", "QQQ", "IWM"];

const args = Deno.args;
const DRY = args.includes("--dry-run");
const FORCE = args.includes("--force");
const scanArg = (args[args.indexOf("--scan") + 1] ?? "auto") as ScanType | "auto";

const KEY = Deno.env.get("TRADYTICS_API_KEY");
if (!KEY) throw new Error("TRADYTICS_API_KEY is required");
// deno-lint-ignore no-explicit-any
let sql: any = null;
let runId: string | null = null;
let snapshotsOn = false;

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
  return { date: `${g("year")}-${g("month")}-${g("day")}`, hour: +g("hour"), minute: +g("minute"), weekday: g("weekday") };
}
function addDays(d: string, n: number) {
  const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10);
}

let lastCall = 0;
async function throttle() {
  const wait = lastCall + 60000 / RPM - Date.now();
  if (wait > 0) await sleep(wait);
  lastCall = Date.now();
}

// deno-lint-ignore no-explicit-any
type Json = any;
interface ApiResult { json: Json; url: string; rawSha: string; asOf: string | null }

async function snap(path: string, params: Json, r: ApiResult | null, reason: string | null) {
  if (!sql || !snapshotsOn) return;
  const sym = params.symbol && !String(params.symbol).includes(",") ? String(params.symbol) : null;
  try {
    await sql`select tid.capture_snapshot(
      ${"tradytics" + path}::text, ${sym}::text, null::text, ${sql.json(params)}::jsonb,
      ${r?.asOf ?? null}::timestamptz, ${r ? sql.json(r.json) : null}::jsonb,
      ${r ? "complete" : "missing"}::text, ${reason}::text, ${r?.rawSha ?? null}::text,
      ${runId}::uuid, ${RUNNER_VERSION}::text)`;
  } catch (e) {
    console.error("snapshot capture failed:", (e as Error).message);
  }
}

async function api(path: string, params: Json, attempt = 0): Promise<ApiResult> {
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  await throttle();
  let res: Response, text: string;
  try {
    res = await fetch(url, { headers: { Authorization: `Bearer ${KEY}`, Accept: "application/json" } });
    text = await res.text();
  } catch (e) {
    if (attempt < 2) { await sleep(3000); return api(path, params, attempt + 1); }
    await snap(path, params, null, `network: ${(e as Error).message}`);
    throw e;
  }
  if ((res.status === 429 || res.status >= 500) && attempt < 2) {
    const ra = Number(res.headers.get("retry-after") ?? "5");
    await sleep(Math.min(isFinite(ra) ? ra : 5, 60) * 1000);
    return api(path, params, attempt + 1);
  }
  if (!res.ok) {
    await snap(path, params, null, `http ${res.status}: ${text.slice(0, 200)}`);
    throw new Error(`${path} -> HTTP ${res.status}: ${text.slice(0, 300)}`);
  }
  const json = JSON.parse(text);
  const out = { json, url: url.toString(), rawSha: await sha256(text), asOf: json?.meta?.as_of ?? null };
  await snap(path, params, out, null);
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

// Follows next_cursor (ASSUMPTION: the cursor query parameter is named "cursor").
async function fetchAll(path: string, params: Json, maxPages = 40) {
  const pages: ApiResult[] = [];
  const seen = new Set<string>();
  let cursor: string | undefined, complete = true, more = false, error: string | null = null;
  for (let i = 0; i < maxPages; i++) {
    const r = await api(path, { ...params, cursor });
    pages.push(r);
    const next = r.json?.next_cursor;
    if (!next) break;
    if (seen.has(next)) { complete = false; more = true; error = "repeated cursor detected"; break; }
    seen.add(next); cursor = next;
    if (i === maxPages - 1) { complete = false; more = true; error = "page cap reached"; }
  }
  return { pages, complete, more, error, all: pages.flatMap((p) => rows(p.json)) };
}

interface Rec { record_key: string; source_event_key: string; payload: Json; symbol: string | null; source_event_at: string | null; source_as_of: string | null }
const rec = (key: string, payload: Json, symbol: string | null, at: string | null, asOf: string | null): Rec =>
  ({ record_key: key, source_event_key: key, payload, symbol, source_event_at: at, source_as_of: asOf });

interface Built { records: Rec[]; pages: number; complete: boolean; more: boolean; error: string | null; asOf: string | null; meta: Json; after?: () => Promise<void> }
interface FeedOutcome { feedType: string; ok: boolean; received: number; error: string | null }

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
  let linked: number | null = null;
  try { // ASSUMPTION: tid_ingestion_batch_records has a batch_id column.
    linked = (await sql`select count(*)::int as n from tid.tid_ingestion_batch_records where batch_id = ${batchId}::uuid`)[0].n;
  } catch { linked = null; }
  const ok = bt.status === "complete" && bt.quality_status === "pass" && bt.pagination_complete === true &&
    (linked === null || linked === bt.records_received);
  console.log(`${feedType}: status=${bt.status} quality=${bt.quality_status} received=${bt.records_received} ` +
    `upserted=${bt.records_upserted} linked=${linked ?? "n/a"} ok=${ok}`);
  return { feedType, ok, received: bt.records_received, error: ok ? null : (bt.error_text ?? err ?? "readback mismatch") };
}

async function runFeed(feedType: string, build: () => Promise<Built>): Promise<FeedOutcome> {
  let built: Built;
  try { built = await build(); }
  catch (e) {
    built = { records: [], pages: 0, complete: false, more: false, error: String((e as Error).message), asOf: null, meta: { failed_before_write: true } };
  }
  try { return await persist(feedType, built); }
  catch (e) { return { feedType, ok: false, received: 0, error: `persist failed: ${(e as Error).message}` }; }
}

// ------------------------------------------------------------------ feeds
const maxAsOf = (a: ApiResult[]) => a.map((p) => p.asOf).filter(Boolean).sort().pop() ?? null;

function quotesFeed(): () => Promise<Built> {
  return async () => {
    // ASSUMPTION: GET /stocks/quotes accepts a comma-separated symbol list.
    const r = await fetchAll("/stocks/quotes", { symbol: QUOTE_SET.join(",") });
    const asOf = maxAsOf(r.pages);
    return {
      records: r.all.map((q) => rec(`quote:${q.symbol}:${q.price_at}`, q, q.symbol, q.price_at ?? null, asOf)),
      pages: r.pages.length, complete: r.complete, more: r.more, error: r.error, asOf,
      meta: { endpoint: "/stocks/quotes", symbols: QUOTE_SET.length },
    };
  };
}
function marketFeed(path: string, keyFn: (x: Json, asOf: string | null) => string, extra: Json = {}): () => Promise<Built> {
  return async () => {
    const r = await fetchAll(path, extra);
    const asOf = maxAsOf(r.pages);
    return {
      records: r.all.map((x) => rec(keyFn(x, asOf), x, null, x.time ?? x.date ?? asOf, asOf)),
      pages: r.pages.length, complete: r.complete, more: r.more, error: r.error, asOf, meta: { endpoint: path, ...extra },
    };
  };
}
function cohortFlowFeed(session: string): () => Promise<Built> {
  return async () => {
    // Cohort AGGREGATE. Rows carry no symbol. Never attribute to individual tickers.
    const r = await fetchAll("/options/flow/timeline", { symbol: UNIVERSE.join(","), interval: "15m", date: session });
    const asOf = maxAsOf(r.pages);
    return {
      records: r.all.map((x) => rec(`cohortflow:${COHORT_ID}:${x.time}`, { ...x, cohort: COHORT_ID, members: UNIVERSE }, COHORT_ID, x.time ?? null, asOf)),
      pages: r.pages.length, complete: r.complete, more: r.more, error: r.error, asOf,
      meta: { endpoint: "/options/flow/timeline", interval: "15m", date: session, aggregate: true, cohort: COHORT_ID },
    };
  };
}
function symbolFlowFeed(session: string): () => Promise<Built> {
  return async () => {
    const records: Rec[] = []; const missing: string[] = []; let pages = 0, complete = true, more = false;
    const errors: string[] = []; const asOfs: string[] = [];
    for (const sym of UNIVERSE) {
      try {
        const r = await fetchAll("/options/flow/timeline", { symbol: sym, interval: "1d", from: addDays(session, -60), to: session });
        pages += r.pages.length; complete &&= r.complete; more ||= r.more;
        if (r.error) errors.push(`${sym}: ${r.error}`);
        const a = maxAsOf(r.pages); if (a) asOfs.push(a);
        if (r.all.length === 0) {
          missing.push(sym); // explicit empty-feed status, never imputed as zero
          records.push(rec(`flow1d:${sym}:EMPTY:${session}`, { status: "empty_feed", session }, sym, null, a));
        }
        for (const x of r.all) records.push(rec(`flow1d:${sym}:${x.date ?? x.time}`, x, sym, x.time ?? null, a));
      } catch (e) { complete = false; errors.push(`${sym}: ${(e as Error).message}`); }
    }
    return { records, pages, complete, more, error: errors.length ? errors.slice(0, 5).join("; ") : null,
      asOf: asOfs.sort().pop() ?? null, meta: { endpoint: "/options/flow/timeline", interval: "1d", empty_symbols: missing, failed: errors.length } };
  };
}
function barsFeed(session: string): () => Promise<Built> {
  return async () => {
    const now = et();
    const done = (d: string) => d < now.date || (d === now.date && (now.hour > 16 || (now.hour === 16 && now.minute >= 30)));
    const records: Rec[] = []; const bars: Json[] = []; let pages = 0, complete = true, more = false;
    const errors: string[] = []; const asOfs: string[] = [];
    for (const sym of [...UNIVERSE, "SPY"]) {
      try {
        const r = await fetchAll("/stocks/bars", { symbol: sym, timeframe: "1d", from: BARS_FROM, to: session, limit: 100 });
        pages += r.pages.length; complete &&= r.complete; more ||= r.more;
        if (r.error) errors.push(`${sym}: ${r.error}`);
        const a = maxAsOf(r.pages); if (a) asOfs.push(a);
        for (const x of r.all) {
          const d = String(x.time).slice(0, 10);
          if (!done(d)) continue; // exclude the forming bar
          records.push(rec(`bars1d:${sym}:${d}`, x, sym, x.time, a));
          bars.push({ symbol: sym, session_date: d, open: x.open, high: x.high, low: x.low, close: x.close, volume: x.volume, source_as_of: a });
        }
      } catch (e) { complete = false; errors.push(`${sym}: ${(e as Error).message}`); }
    }
    return {
      records, pages, complete, more, error: errors.length ? errors.slice(0, 5).join("; ") : null,
      asOf: asOfs.sort().pop() ?? null, meta: { endpoint: "/stocks/bars", timeframe: "1d", from: BARS_FROM, to: session, failed: errors.length },
      after: async () => { // columns per the stored morning prompt; upsert only when incoming source_as_of is not older
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

// ------------------------------------------------------------------ main
async function main() {
  const now = et();
  let scan: ScanType;
  if (scanArg === "auto") {
    const map: Record<number, ScanType> = { 6: "morning", 12: "midday", 15: "afternoon" };
    if (!map[now.hour] && !FORCE) { console.log(`ET hour ${now.hour}: no scan scheduled; exiting.`); return 0; }
    scan = map[now.hour] ?? "morning";
  } else scan = scanArg;
  if ((now.weekday === "Sat" || now.weekday === "Sun") && !FORCE) { console.log("Weekend; exiting."); return 0; }
  const session = now.date;

  if (!DRY) {
    sql = postgres(Deno.env.get("DATABASE_URL")!, { max: 2, prepare: false, onnotice: () => {} });
    try {
      if ((await sql`select 1 from tid.tid_hb_calendar_exceptions where exception_date = ${session}::date`).length && !FORCE) {
        console.log("Calendar exception (holiday); exiting."); await sql.end(); return 0;
      }
    } catch { /* heartbeat tables not installed yet */ }
    if (!FORCE) {
      const dup = await sql`select run_id from tid.tid_scan_runs
        where run_metadata->>'runner' = 'tid-runner' and run_metadata->>'scan_type' = ${scan}
          and market_session = ${session}::date and ledger_write_status in ('written','pending') limit 1`;
      if (dup.length) { console.log(`A ${scan} run already exists for ${session} (${dup[0].run_id}); use --force to repeat.`); await sql.end(); return 0; }
    }
    snapshotsOn = Deno.env.get("SNAPSHOTS") !== "0" &&
      (await sql`select to_regproc('tid.capture_snapshot') as f`)[0].f !== null;
    runId = (await sql`insert into tid.tid_scan_runs (scan_name, market_session, universe_definition, universe_rows, run_metadata)
      values (${`TID ${scan} scheduled (tid-runner)`}, ${session}::date,
              'TID selected 50-symbol cohort; index membership unverified', 50,
              ${sql.json({ runner: "tid-runner", runner_version: RUNNER_VERSION, scan_type: scan, snapshots: snapshotsOn })}::jsonb)
      returning run_id`)[0].run_id;
    console.log(`scan_run ${runId} (${scan}, session ${session}, snapshots=${snapshotsOn})`);
  }

  const out: FeedOutcome[] = [];
  const feed = async (t: string, b: () => Promise<Built>) => { out.push(await runFeed(t, b)); };

  if (scan === "morning") await feed("tradytics_daily_bars", barsFeed(session));
  if (scan === "morning") await feed("tradytics_symbol_flow_1d", symbolFlowFeed(session));
  await feed("tradytics_symbol_quotes", quotesFeed());
  await feed("tradytics_market_indices", marketFeed("/market/indices", (x) => `index:${x.symbol}:${x.time}`));
  await feed("tradytics_market_breadth", marketFeed("/market/breadth", (_x, a) => `breadth:${a}`));
  await feed("tradytics_sector_snapshot", marketFeed("/market/sectors", (x) => `sector:${x.etf ?? x.name}:${x.date}`, { type: "sector" }));
  if (scan !== "morning") await feed("tradytics_options_flow_timeline", cohortFlowFeed(session));

  const okN = out.filter((f) => f.ok).length;
  const allOk = okN === out.length;
  console.log(`\nSUMMARY ${scan} ${session}: ${okN}/${out.length} feeds ok`);
  for (const f of out) if (!f.ok) console.log(`  FAILED ${f.feedType}: ${f.error}`);

  if (!DRY && sql) {
    const ledger = allOk ? "written" : okN > 0 ? "partial" : "not_written";
    await sql`update tid.tid_scan_runs set run_completed_at = now(),
      coverage_pct = ${(100 * okN) / out.length}::numeric, pagination_complete = ${allOk}::boolean,
      ledger_write_status = ${ledger}::text, data_quality = ${sql.json({ feeds: out })}::jsonb
      where run_id = ${runId}::uuid`;
    const back = (await sql`select ledger_write_status, run_completed_at from tid.tid_scan_runs where run_id = ${runId}::uuid`)[0];
    console.log(`scan_run readback: ledger=${back.ledger_write_status} completed=${back.run_completed_at}`);
    await sql.end();
  }
  return allOk ? 0 : 1;
}

Deno.exit(await main());
