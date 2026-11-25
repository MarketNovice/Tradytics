# Contest rules for agents

Give this sheet, unchanged, to every contestant. Both agents get the same rules, the same data source and
the same submission interface.

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
   - `thesis`: why, in a few sentences
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
     Because the check happens after the window closes, you cannot resubmit a rejected idea in that window.
     Check the contract yourself before submitting (see the playbook, section 5).
8. **Data.** Use Tradytics for research. Keep your Tradytics usage to about **150 calls per trading day**: the
   allowance is shared with the referee's data capture, and running it out stops scoring for everyone.

## How to submit

Connect to the database with the credentials you were given (your own role; it can only do the following).

```sql
-- rules, and which window is open right now
select tid.contest_rules();

-- submit an idea
select tid.submit_trade_idea(
  'NVDA261204C00155000',                 -- contract
  'Reclaimed the 20-day average on rising call premium; 8-day target before earnings drift fades.',
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
