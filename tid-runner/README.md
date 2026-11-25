# tid-runner

Deterministic scheduled ingestion. Replaces the chat automations as the thing that makes data exist.
**Status: 0.1.1.** Dry-run and live-tested against the vendor API and a local replica of the Supabase schema
(see `DRYRUN-2026-11-24.md`, `SCHEMA-CHECK-2026-11-24.md`, `../db/README.md`). Not yet run from GitHub Actions.

## Scans

| Scan | ET window | Feeds | API calls (approx.) |
|---|---|---|---|
| `morning` | 07:00-09:25 | OI chain (TID-2.12), daily bars, daily flow per symbol, quotes, indices, breadth, sectors | 105 + OI |
| `midday` | 11:30-13:45 | quotes, indices, breadth, sectors, cohort flow (15m) | 5 |
| `afternoon` | 14:30-16:00 | same as midday | 5 |
| `oi` | 17:00-23:30 | OI chain only (evening capture, for TID-2.12 timing verification) | OI |

OI chain = `/options/chain` per symbol, `max_dte` = `OI_MAX_DTE` (default 60), 1,000 contracts per page.
Each page is stored as a TID-3.2 snapshot in the `chain_oi_v1` projection (contract, OI, volume, delta);
`tid.record_oi_capture` turns each symbol's pages into an OI vintage. See `../db/tid-2.12-open-interest.sql`.

## Running

```
export TRADYTICS_API_KEY=tdy_...
deno run -A tid-runner/run.ts --scan midday --dry-run --force      # no database needed
export DATABASE_URL='postgresql://...'                              # dedicated role, not your dashboard login
deno run -A tid-runner/run.ts --scan midday
```

Flags: `--window` (refuse outside the ET window; used by the schedule), `--dry-run`, `--force` (ignore weekend,
holiday and completed-run guards). Exit codes: 0 done or expected skip, 1 feed failure, 2 setup error,
3 aborted on daily API quota.

Guards: holiday calendar (`tid.is_trading_day`, TID-3.3); one completed run per scan per session
(`written` or `complete`); runs left `pending` over 2 hours are marked `abandoned`; requires TID-3.2 snapshots
unless `REQUIRE_SNAPSHOTS=0`; a snapshot failure fails its feed.

## GitHub Actions

- `.github/workflows/tid-runner.yml`: scheduled scans. Each scan has cron entries for both DST offsets;
  `--window` turns the off-season entry into a no-op and the completed-run guard skips later retries.
  Manual runs: Actions → tid-runner → Run workflow (dry run by default).
- `.github/workflows/tid-watchdog.yml`: TID-3.3 watchdog, hourly at :50 (Mon-Sat UTC), independent of the
  runner. On a new finding, or if it cannot reach the database, the run fails and opens a GitHub issue.
  Run it manually with **canary** ticked to test alert delivery, then record receipt:
  `select tid.hb_ack_canary(<watchdog_run_id>, 'github issue', 'received');`

Secrets: `TRADYTICS_API_KEY`, `DATABASE_URL`, optional `WATCHDOG_DATABASE_URL` (separate role for the
watchdog). Variables: `TRADYTICS_RPM` (default 8), `OI_MAX_DTE` (default 60).
Scheduled workflows only run from the repository's default branch, and GitHub pauses them in public
repositories after 60 days without commits.

## Rate limits

Vendor limits: Free 5/min and 50/day, Plus 10/min and 1,000/day, Pro 300/min and 50,000/day. API keys and MCP
connections share one allowance. At `TRADYTICS_RPM=8` the morning scan takes about 25 minutes; the job times
out at 55. On `quota_exceeded` the runner stops immediately (exit 3) and marks the remaining feeds not attempted.

## Changes in 0.1.1

- `--scan` required and validated; new `oi` scan; `--window` for DST-safe scheduling.
- Daily quota error aborts the run; rate limits wait for `Retry-After` (seconds or HTTP date, up to 120 s).
- Bars: rolling `BARS_LOOKBACK_DAYS` window; only sessions before today are written (vendor revises the
  current day's bar for hours after the close).
- Record keys refuse missing parts; quotes check that all 53 symbols arrived.
- Snapshots: required by default, failures fail the feed and are counted in `data_quality`; client receive
  time passed to `capture_snapshot`; non-JSON responses captured as `missing`.
- Completed-run guard accepts `written` and `complete`; stale `pending` runs become `abandoned`.
- Holiday check uses the TID-3.3 calendar.

## Not included yet

- `tid.refresh_paper_validation_outcomes(p_as_of_session date)`: keep as a separate step after the morning scan.
- Retry of a single failed feed; rerunning a scan with `--force` repeats all of it.
