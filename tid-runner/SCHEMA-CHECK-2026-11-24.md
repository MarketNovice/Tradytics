# tid-runner schema check against Supabase, 2026-11-24

Project `TID-Trade-Intelligence` (Postgres 17), read-only queries via the Supabase connector.
Existing data at check time: 5 scan runs (ledger: complete 3, written 1, partial 1), 69 ingestion batches,
17,382 ingestion records, 3,752 market bars.

## README assumptions

| # | Assumption | Result |
|---|---|---|
| 4 | `begin_ingestion_batch` returns the batch id | Confirmed: `returns uuid`. `select *` yields a column named `begin_ingestion_batch`, which the runner's fallback reads. |
| 5 | `tid_ingestion_batch_records.batch_id` exists | Confirmed (PK `batch_id, record_id`). |
| 6 | `tid_market_bars` unique (symbol, session_date) | Confirmed (PK). `timeframe` is not in the key and is constrained to `'1d'`. All 3,468 dry-run bars pass the OHLC check constraints. |

Signatures of `begin_ingestion_batch`, `upsert_ingestion_records_bulk` and `finalize_ingestion_batch` match the runner's calls (argument order and types). Record JSON keys expected by `upsert_ingestion_record` (`record_key`, `source_event_key`, `payload`, `symbol`, `source_event_at`, `source_as_of`) match the runner's `Rec`.

## Findings

1. **`tid.capture_snapshot` is not installed.** The runner turns snapshots off without warning. TID-3.2 is not deployed, so protocol §13's first prerequisite is unmet and no capture-time hashes exist.
2. **`tid.tid_hb_calendar_exceptions` is missing.** TID-3.3 is not deployed. The runner's holiday check is skipped silently, so it would run and write on market holidays.
3. **A crashed run blocks reruns.** `tid_scan_runs.ledger_write_status` defaults to `'pending'`, and the runner's duplicate check treats `'pending'` as an existing run. A run that dies before its final update blocks every later run of that scan for the day unless `--force` is used.
4. **Inconsistent ledger vocabulary.** Earlier (chat) runs wrote `'complete'`; the runner writes `'written'`. There is no check constraint. The duplicate check does not match `'complete'`, so it will not see chat-written runs.
5. **Revisions overwrite the first capture everywhere.** `upsert_ingestion_record` replaces `payload` and `payload_hash` whenever the incoming `source_as_of` is the same or newer, and the runner's `tid_market_bars` upsert does the same. Only `first_seen_at` survives. With TID-3.2 absent, the first-captured values that protocol §4 relies on are not stored anywhere.
6. **Status rules (for reference).** `finalize_ingestion_batch` sets `failed/fail` if any error text is passed (a single failed symbol fails the whole feed), `complete/pass` only if pagination is complete, the provider has no more, and linked records ≥ expected, otherwise `partial/warning`. Duplicate record keys within a batch reduce the linked count and so show up as `partial`.
7. **Connector role.** The connector runs as `postgres` (bypasses RLS). The runner should use a dedicated role with execute on the three functions and insert/update on `tid_scan_runs` and `tid_market_bars` only.
