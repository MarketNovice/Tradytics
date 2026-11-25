# Contest rules for agents

Give this sheet, unchanged, to every contestant. Both agents get the same rules, the same data source, the
same submission interface and the same scoring. **How you find and choose trades is entirely up to you**: no
methodology is supplied or required, and the other agent's methodology may be completely different.

## What you are doing

You propose swing option trades. A referee program, not you, prices and scores every trade. Your results
are compared with another agent's over many months. Accuracy over time is what counts, not any single trade.

## The rules

1. **Instrument.** Buy one listed call or put (long only). Any stock or ETF available on Tradytics.
2. **Expiry.** 8 to 14 calendar days after the day you submit.
3. **When.** Three windows per trading day (US Eastern time): **09:45-10:15**, **12:15-12:45**, **14:45-15:15**.
   Submissions outside a window are rejected.
4. **How many.** Up to 3 ideas per window. If you have no good idea, skip the window with a reason. Skipping
   is legitimate; a window with neither ideas nor a skip is recorded as missed.
5. **Each idea must state:**
   - `contract`: OCC symbol, e.g. `NVDA261204C00155000` (underlying, YYMMDD expiry, C/P, strike × 1000 in 8 digits)
   - `thesis`: why, in a few sentences, ending with a line `SIGNALS: ...` naming the evidence the idea rests
     on, in your own words (e.g. `SIGNALS: repeated call sweeps, dealer gamma flip below, sector strength`)
   - `confidence`: 0 to 1, your probability that the trade makes money
   - `target_pct`: take-profit, % gain on the option price (e.g. 50)
   - `stop_pct`: stop-loss, % loss on the option price, between 0 and 100 (e.g. 40)
   - `max_hold_days`: calendar days to hold at most, at least 1 and at most days to expiry − 1
6. **Final.** Submitted ideas cannot be changed or withdrawn.
7. **Pricing (done by the referee).**
   - Entry: the **ask** of the quote captured just after the window closes.
   - Checks: quotes are captured after every window. The trade closes at the **bid** at the first check where
     your target or stop is reached, or at the first check on or after your max holding day.
   - If there is no two-sided quote at entry, the idea is void. On expiry day without a quote, the option is
     valued at intrinsic value.
   - Every idea is sized the same ($1,000 of premium).
   - **Contract quality is checked at entry**, on the referee's quote. The idea is rejected (counted against
     you as a rejected idea, with the reasons shown in `my_trade_ideas`) if:
     - the bid/ask spread is above **15%** of the mid price;
     - open interest is below **500** contracts;
     - |delta| is outside **0.30 to 0.65**;
     - the company reports earnings on or before your planned exit day (submission date + `max_hold_days`);
     - the contract does not exist.
     The contest API also runs these checks live when you submit (see below), so a failing contract can be
     fixed inside the window. The entry check is final.
8. **Data.** Use Tradytics for research. Keep your Tradytics usage to about **150 calls per trading day**: the
   allowance is shared with the referee's data capture, and running it out stops scoring for everyone.
9. **Your methodology document.** Before the contest starts, give the owner a written description of how you
   generate, select and size ideas: data you use, signals, filters, how you set target, stop, holding period and
   confidence, and when you skip. Label it with a version and date (e.g. `v1.0, 2026-11-27`).
   - The owner keeps it privately; the other agent does not see it until the contest ends.
   - You may change your methodology during the contest. Each change is a new version with its date and a short
     note of what changed, given to the owner **before** the first idea that uses it.
   - Start every thesis with your current version, e.g. `METHOD: v1.1`.
10. **No interference.** Do not read, change or try to access the referee's data, the scoring, the other agent's
    ideas, or the database and functions behind the contest. Use only the contest API (or your own database
    role) and Tradytics.

## How to submit

**Preferred: the contest API** (`docs/contest-api.openapi.yaml`), with the agent token you were given as
`Authorization: Bearer <token>`. Base URL: `https://uqeclylqjwuorkjgupce.supabase.co/functions/v1/contest-submit`

| Call | Does |
|---|---|
| `GET /health` | confirms your token works (and `?probe=1` that the live contract check is configured) |
| `GET /rules` | rules, quality limits, and the window open now |
| `POST /ideas` | submit an idea (JSON: contract, thesis, confidence, target_pct, stop_pct, max_hold_days) |
| `POST /skip` | skip the current window: `{"reason": "..."}` |
| `GET /ideas` | your own ideas, rejection reasons and results |

The API checks your contract live before recording it. If it fails the quality limits you get 422 with the
reasons and **nothing is recorded**, so you can fix it and resubmit inside the same window.

**Alternative: direct database connection** with the credentials you were given (your own role; it can only
do the following).

```sql
-- rules, and which window is open right now
select tid.contest_rules();

-- submit an idea
select tid.submit_trade_idea(
  'NVDA261204C00155000',                 -- contract
  'METHOD: v1.0. Reclaimed the 20-day average on rising call premium; 8-day target. SIGNALS: call flow, price reclaim',
  0.55,                                  -- confidence
  60,                                    -- target_pct
  40,                                    -- stop_pct
  5                                      -- max_hold_days
);

-- skip the current window
select tid.skip_window('No setup with an edge this window: market flat into FOMC.');

-- your own ideas and results (you cannot see the other agent's)
select * from tid.my_trade_ideas(50);
```

An error message tells you exactly which rule a rejected submission broke; fix it and resubmit inside the
same window.

## What you can and cannot see

You can see the rules and your own ideas and results. You cannot see the other agent's ideas or results,
the scoreboard, or the referee's data, and you cannot change any of them.
