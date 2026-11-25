# Database changes

SQL here is **not applied automatically**. These files sit outside `supabase/` on purpose, so the
Supabase GitHub integration does not pick them up. Apply each one by hand after review.

| File | Status | What it does |
|---|---|---|
| `tid-3.2-raw-snapshots.sql` | **Applied** to Supabase 2026-11-25 (`tid_3_2_raw_snapshots`) | TID-3.2: append-only raw snapshots with capture time and SHA-256 hashes; `tid.capture_snapshot` (the function tid-runner already calls); append-only record versions that keep the first capture and every revision; daily digest for tamper evidence. |
| `tid-3.3-heartbeat.sql` | **Applied** 2026-11-25 (`tid_3_3_heartbeat`) | TID-3.3: NYSE calendar 2026-2027 (closures, early closes), calendar functions, expected scans with ET deadlines, append-only watchdog log, `tid.hb_check` (reports each finding once), canary and `tid.hb_ack_canary`. |
| `tid-2.12-open-interest.sql` | **Applied** 2026-11-25 (`tid_2_12_open_interest`) | TID-2.12: OI vintages from chain snapshots (fingerprint per distinct OI set), first-capture timing, session mapping (`baseline`/`overnight`/`evening`/`intraday`), `available_before_open`, contract-level view, `tid.oi_contract_changes`, mapping report. |

| `tid-runner-role.sql` | **Applied** 2026-11-25 (`tid_runner_role`) | Login role `tid_runner` for the runner and watchdog, created without a password. Writes scan runs, ingestion tables and market bars; reads the calendar; executes the TID functions. Cannot delete, read snapshot/version/OI/watchdog tables, or touch other tables. Verified as the role in a rolled-back transaction. |

| `tid-4.0-agent-contest.sql` | **Applied** 2026-11-25 (`tid_4_0_agent_contest`), **not started** | Agent contest: append-only ideas, fills, marks and results; `submit_trade_idea`/`skip_window`/`my_trade_ideas` for agents; `contest_prepare`/`contest_record_quote` scoring for the runner; `contest_start` (owner); roles `tid_agent_chatgpt`, `tid_agent_claude` (no passwords yet); scoreboard and paired views. See `docs/agent-contest.md`. |
| (hb_check update) | **Applied** 2026-11-25 (`tid_3_3_1_per_checker_dedup`) | Each watchdog deduplicates only its own reports. |

Order: 3.2, 3.3, 2.12, runner role, 4.0. All are idempotent.

Contest tests: `test/test-tid-4.0-contest.sql` (5 of 5 passed on a fresh database). A live run of the
`contest1` scan against a local database filled two real contracts at the ask from the first capture and
marked them from the next.

## TID-2.12 verification (protocol §13)

The vendor chain has no OI date, so timing is inferred from captures. After a few trading days of
morning (07:20-09:20 ET) and evening (17:40-19:40 ET) captures:
```sql
select * from tid.v_oi_mapping_report;
```
Expected if OI updates overnight: new vintages are `overnight` with `available_before_open = true`, evening
captures repeat the morning vintage, and there are no `evening` or `intraday` rows. Anything else needs review
before OI can classify protocol F. The first vintage per symbol is `baseline` and never qualifies.

Storage: one OI capture of the 50 names (`OI_MAX_DTE=60`) is about 70,000 contracts, 97 API calls and
850 kB compressed. Two captures per trading day is roughly 430 MB a year; once timing is verified, the
evening `oi` scan can be dropped to halve that.

## Applying TID-3.2

1. Read `tid-3.2-raw-snapshots.sql`. It runs in one transaction and is safe to re-run.
2. Supabase → SQL Editor → paste → Run.
3. Check: `select to_regproc('tid.capture_snapshot');` returns a value, and
   `select change_kind, count(*) from tid.tid_record_versions group by 1;` shows one `first` row per existing ingestion record.
4. The next tid-runner run turns snapshots on automatically (`snapshots=true` in its first log line).

Seeded versions for records that existed before the migration carry the migration time as `captured_at`.
Their true first capture time is `tid_ingestion_records.first_seen_at`, and their original payloads,
where revised before the migration, are not recoverable.

Daily digest, to record outside the database (for example in a git commit):
```sql
select * from tid.snapshot_daily_digest(current_date - 1);
```

## Testing locally

`test/baseline-replica.sql` copies the Supabase ingestion tables and functions (as of 2026-11-24).
```
createdb tidtest
psql -v ON_ERROR_STOP=1 -d tidtest -f test/baseline-replica.sql
psql -v ON_ERROR_STOP=1 -d tidtest -f tid-3.2-raw-snapshots.sql
psql -v ON_ERROR_STOP=1 -d tidtest -f test/test-tid-3.2.sql      # ends with ALL TESTS PASSED
psql -v ON_ERROR_STOP=1 -d tidtest -f tid-3.3-heartbeat.sql
psql -v ON_ERROR_STOP=1 -d tidtest -f tid-2.12-open-interest.sql
psql -v ON_ERROR_STOP=1 -d tidtest -f test/test-tid-3.3-2.12.sql  # ends with ALL TESTS PASSED
```
Run the 3.3/2.12 tests on a database with no tid-runner scan runs; they assume an empty heartbeat history.

Test run 2026-11-25 (fresh database, all three migrations): 7 of 7 TID-3.3/2.12 tests and 6 of 6 TID-3.2
tests passed. A real `oi` scan with runner 0.1.1 wrote 97 chain snapshots and 50 baseline vintages
(69,445 contracts) and finished `written` in 12 minutes. The watchdog script reported missing scans,
reported only the canary on the next run, and alerted on a bad database password.

Test run 2026-11-25 (Postgres 16): migration applied twice cleanly; 6 of 6 tests passed; seeding on a
populated database created one `first` version per record; a real tid-runner 0.1.0 midday scan against
the local database wrote 5 of 5 feeds and 5 snapshots, all hashes valid; the duplicate-run guard
stopped a second run.
