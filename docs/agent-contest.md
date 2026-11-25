# Agent contest: ChatGPT vs Claude on swing option trades

**Status:** DESIGN DRAFT. Nothing here is built yet. Decisions marked **[D1]**–**[D6]** are the owner's.

## Goal

Find out which agent produces more accurate swing option trade ideas, under rules neither agent can bend.
The comparison is only as good as its weakest rule, so every rule below exists to close a specific way the
result could be wrong.

## Contest rules (both agents)

| Rule | Value |
|---|---|
| Instrument | One listed option contract (OCC symbol), long only (buy a call or a put) **[D1]** |
| Expiry | 8 to 14 calendar days after submission (checked by the database at submission) |
| Underlying | Anything on the Tradytics platform; stocks and ETFs with listed options |
| Windows | 3 per trading day: 09:45-10:15, 12:15-12:45, 14:45-15:15 ET |
| Ideas per window | Up to **[D2: 1 / 2 / 3]** per agent; a skipped window is recorded as a skip, not hidden |
| Required at submission | contract, direction (bullish/bearish), thesis (text), confidence (0-1), exit plan: profit target % and stop % on the option price, max holding days (≤ days to expiry − 1) |
| Size | Fixed notional per idea (e.g. $1,000 of premium) so every idea counts equally |
| Data | Both agents use Tradytics only, at the same windows; neither sees the other's ideas or the scoreboard of the other |

An idea is final when submitted. No edits, no cancellations. A malformed idea is rejected at submission
with the reason, and the agent may resubmit inside the same window.

## How trades are scored (by code, not by an agent)

1. **Entry.** At the end of each window, the runner captures a quote for every contract submitted in that
   window (TID-3.2 snapshot). Entry price = **[D3: ask (realistic) / mid]** of that captured quote. Both agents'
   ideas from the same window are priced from captures taken minutes apart, so neither gains from timing.
2. **Marks.** The runner captures quotes for all open contracts at each of the three daily windows.
3. **Exit.** At the first mark where the option's **[D3: bid / mid]** reaches the target or the stop, or at the
   max-holding-day mark, whichever comes first. If a contract has no two-sided quote at a mark, the next mark
   is used; at expiry an option with no quote is valued at intrinsic value from the underlying close.
4. **Result.** Return on premium, after the bid/ask cost implied by [D3]. No agent reports its own P&L.

Path between marks is not observed (three marks a day), the same for both agents.

## What is compared

Primary metric (fixed before the contest starts): **mean return on premium per idea**, agent A vs agent B,
paired by window (both agents' ideas from the same window are compared together, so market days affect both).

Also reported, never used to pick a winner on their own:
- win rate, average win and loss, worst drawdown of the equal-size equity curve;
- **direction accuracy**: did the underlying move the predicted way by the exit time. Much less noisy than
  option returns, so it separates the agents much sooner, but it ignores option pricing;
- calibration: do 0.8-confidence ideas win more often than 0.5-confidence ones;
- baselines: (a) a random-direction at-the-money option on the same underlying and expiry, which shows
  whether the agent's *direction* adds anything beyond its choice of stock; (b) SPY at-the-money option in the
  agent's direction, same expiry.

## How long it takes (honest numbers)

Option returns on 8-14 day trades are very noisy: a standard deviation of 60-100% of premium per trade is
normal. To tell apart two agents whose true average returns differ by 10 percentage points per trade, at the
usual 95% confidence and 80% power, takes on the order of **1,000 ideas per agent**. At 3 ideas a day that is
over a year. Direction accuracy needs far fewer (a 10-point hit-rate gap needs roughly 400 per agent).

So: decide now **[D4]** the minimum sample and the date of the first real verdict, and do not pick a winner
from early streaks. Allowing up to 3 ideas per window **[D2]** shortens this three-fold.

## Separation and access

| Party | Can | Cannot |
|---|---|---|
| Agent role `tid_agent_chatgpt` | submit ideas through `tid.submit_trade_idea`; read its own submitted ideas and its own closed results | read the other agent's ideas or results, change scoring, outcomes, data tables, jobs or functions |
| Agent role `tid_agent_claude` | same | same |
| `tid_runner` | capture quotes and marks, close trades by the rules | submit ideas |
| Owner (you) | everything, including the full scoreboard | — |

**Current state that breaks this:** ChatGPT has administrator-level database access (it created the pg_cron
jobs and the Edge Function), and so does the Claude session that built the pipeline. During the contest,
each contestant should connect only as its agent role. Infrastructure changes go through you.

**Who plays for Claude [D5]:** not the session that built the pipeline and scoring. Recommended: a separate
scheduled Claude task with only the Tradytics connector and the `tid_agent_claude` database role.

## API quota [D6]

API keys and MCP connections share one Tradytics allowance (Plus: 1,000 calls a day). The runner already
uses about 310 on a trading day, the contest adds quote captures (roughly one call per open contract per
mark), and each agent's own research uses the same allowance. If an agent's research exhausts the quota, the
runner stops (exit 3) and the scoring data for that day is missing for both. Options: Pro plan; a cap on each
agent's calls; or measure for a week first.

## Build list (after decisions)

1. Migration: `tid_trade_ideas` (append-only, hashed), `tid_trade_marks`, `tid_trade_results`,
   `submit_trade_idea` (validates contract, expiry 8-14 days, window, limits), agent roles, owner scoreboard views.
2. Runner: `ideas` step at the end of each window (entry quotes) and marks for open contracts at every window;
   deterministic exit rules.
3. Tests with fixed timestamps (window edges, expiry range, target/stop/expiry exits, no-quote cases).
4. A short instruction sheet for each agent: how to submit, the rules, what it can see.
