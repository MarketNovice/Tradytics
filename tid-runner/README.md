# tid-runner

Deterministic scheduled ingestion. Replaces the chat automations as the thing that makes data exist.
**Status: written, never executed.** Start with a dry run.

## First test (needs only the API key, writes nothing)
```
export TRADYTICS_API_KEY=tdy_...
deno run -A tid-runner/run.ts --scan midday --dry-run --force
```
Check that each feed prints a plausible record count and sample. This is the only way to confirm the
assumptions below before anything touches the database.

## Assumptions to verify (marked ASSUMPTION in run.ts)
1. REST paths from the vendor's client reference (v0.6.1): `/stocks/quotes`, `/stocks/bars`,
   `/market/indices|breadth|sectors`, `/options/flow/timeline`. Paths are confirmed; **parameter names are not**
   (symbol lists, `interval`, `date`, `from`, `to`, `type`, `cursor`). They were copied from the MCP tool arguments.
2. `/stocks/quotes` accepts a comma-separated symbol list.
3. A comma-separated symbol list on flow timeline returns a cohort aggregate (as the MCP tool did).
4. `begin_ingestion_batch` returns the batch id (scalar or a `batch_id` column).
5. `tid_ingestion_batch_records` has a `batch_id` column (else readback falls back to batch counters).
6. `tid_market_bars` has unique (symbol, session_date) and the columns used in the morning prompt.

## Secrets
`TRADYTICS_API_KEY`, `DATABASE_URL` (Supabase connection string; use a dedicated role, not your dashboard login).
GitHub Actions: repo secrets + optional variable `TRADYTICS_RPM`.

## Rate limits: set TRADYTICS_RPM to your plan
The vendor's current client page lists Free 5/min and 50/day, Plus 10/min and 1,000/day, Pro 300/min and 50,000/day.
(Older pages and ChatGPT's handoff said otherwise.) Morning is about 105 calls: 11+ minutes at 10/min, so on Plus
keep RPM at 8 and expect ~13 minutes. The runner times out at 45 minutes.

## Not included yet
- `tid.refresh_paper_validation_outcomes` (signature unknown; keep as a separate step after the morning scan).
- Next-day OI capture (`/options/open-interest`) for TID-2.12.
- Retry of a failed feed alone; rerun with `--force` repeats the whole scan.
