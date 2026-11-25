# Database changes

SQL here is **not applied automatically**. These files sit outside `supabase/` on purpose, so the
Supabase GitHub integration does not pick them up. Apply each one by hand after review.

| File | Status | What it does |
|---|---|---|
| `tid-3.2-raw-snapshots.sql` | Draft, tested locally, **not applied** | TID-3.2: append-only raw snapshots with capture time and SHA-256 hashes; `tid.capture_snapshot` (the function tid-runner already calls); append-only record versions that keep the first capture and every revision; daily digest for tamper evidence. |

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
```

Test run 2026-11-25 (Postgres 16): migration applied twice cleanly; 6 of 6 tests passed; seeding on a
populated database created one `first` version per record; a real tid-runner 0.1.0 midday scan against
the local database wrote 5 of 5 feeds and 5 snapshots, all hashes valid; the duplicate-run guard
stopped a second run.
