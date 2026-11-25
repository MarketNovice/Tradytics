# Trade idea playbook: 8-14 day long options

**Version 1.0 (2026-11-25).** For every agent proposing trades in this project. Same playbook for all agents.
These are working rules, not proven ones: each idea records which evidence it used, so results will show
which checks actually help, and the playbook will be revised from that.

## 0. What a good idea is

A good idea has three parts, and is skipped if any is missing:

1. **An edge**: a specific reason the stock should move in one direction *within days*, backed by at least
   two independent kinds of evidence (section 3).
2. **A vehicle**: a contract that profits if the edge plays out, without needing more than the move the
   market already expects (section 5).
3. **An invalidation**: a price or event that proves the idea wrong, decided before entry (section 6).

Facts about 8-14 day long options that drive every rule below:
- Time decay is steep: the stock must move soon, not eventually.
- Implied volatility is the price you pay. Buying when it is high, or before earnings, often loses even when
  the direction is right.
- The bid/ask spread is paid twice (in at the ask, out at the bid). A 15% spread starts the trade 15% down.

**Skipping is a valid answer.** One well-supported idea beats three forced ones.

## 1. Market context (once per window, about 4 calls)

| Check | Tool / view | What to record |
|---|---|---|
| Index level and VIX | `get_market` `indices` | VIX level and today's change |
| Breadth | `get_market` `breadth` | advancers vs decliners; equal-weight vs cap-weight |
| Sector leadership | `get_market` `sectors` | strongest and weakest 2 sectors |
| Index dealer gamma | `get_dealer_positioning` `exposure`, `symbol=SPX` | positive or negative gamma; gamma flip level |
| Events | `get_calendar` `economic`, `impact=high` (once a day) | FOMC, CPI, jobs, GDP inside the next 14 days |

Regime tag for the window, one of: **trend-up**, **trend-down**, **range** (positive dealer gamma, low VIX),
**stress** (VIX up sharply, breadth very weak). In **stress**, skip unless the idea is explicitly about the
stress. In **range**, prefer ideas near dark pool or gamma levels over breakout ideas.

## 2. Finding candidates (about 5 calls)

Pull from at least two of these and keep at most 5 names:

| Source | Tool / view | Look for |
|---|---|---|
| Flow leaders | `get_flow_summary` `leaders`, `direction=bullish` and `bearish` | net premium well above the 20-session average |
| Unusual contracts | `get_flow_summary` `unusual` | volume above open interest, large premium, expiries under 45 days |
| Screener | `screen_stocks` (e.g. `min_relative_volume` 2, `min_options_net_premium_usd`) | relative volume plus options interest |
| Dark pool | `get_dark_pool` `daily` (no symbol) | names with top-ranked dark pool notional today |
| Sector context | section 1 | names in the strongest or weakest sectors |

Drop at once: stocks under $10, options with thin chains, earnings inside the planned holding period
(`get_calendar` `earnings`, `symbol=`), unless the idea is explicitly an earnings trade (discouraged).

## 3. Validating the thesis (about 8 calls per name; do the best 2-3)

Collect evidence from these **families**. An idea needs **at least two families agreeing** and **no family
strongly against**.

| Family | Tool / view | Supports a bullish idea when... (mirror for bearish) |
|---|---|---|
| **Flow** | `get_options_flow` with `symbol`, `min_premium=100000`, `side=bought`, `opening=true`; `get_flow_summary` `timeline` `interval=1d` over 10 days | calls bought at the ask, opening (size above OI), sweeps rather than single blocks, repeated on 2+ sessions, in expiries 2-45 days out. One-off prints and spreads count for little. |
| **Positioning** | `get_dealer_positioning` `exposure` `by=strike`; `open_interest` | price above the gamma flip with room to the call wall; call OI rising at strikes above price |
| **Dark pool** | `get_dark_pool` `levels` (`window=20`) | a large dark pool level just below price acting as support |
| **Price** | `get_price_bars` daily, 60 sessions | trend or a clean break of a level on rising volume; record ATR(14) and the nearest support/resistance |
| **Catalyst** | `get_news`, `get_calendar` | a dated reason to move inside the hold (product event, sector data, index rebalance) |
| **Volatility** | `get_volatility` `current` | IV rank below about 60; IV not far above realized vol; expected move to the target expiry |

Record the numbers, not adjectives: "$2.4M calls bought at ask over 3 sessions, 80% opening" rather than
"strong flow".

## 4. The edge statement

Before choosing a contract, write in one or two sentences:
- **what** should happen (underlying target price),
- **by when** (a date inside the expiry window),
- **why** (the two or more evidence families),
- **what proves it wrong** (an underlying price, or an event).

If the target needs a move larger than the options-implied expected move to that date (from
`get_volatility`), the idea is a long shot: lower confidence, or skip.

## 5. Choosing the contract (2-4 calls)

Use `get_option_contracts` `chain` with `min_dte=8`, `max_dte=14`, `type`, `min_delta`/`max_delta`,
`min_open_interest`, then `contract` for the final quote.

**Enforced in the contest** (an idea that fails is rejected at entry): spread above 15%, open interest below
500, |delta| outside 0.30-0.65, earnings on or before the planned exit day, contract not listed. The tighter
values below are the playbook's targets; the enforced limits are the floor.

| Rule | Value | Why |
|---|---|---|
| Expiry | 8-14 calendar days (contest rule) | |
| Delta | 0.35 to 0.60 | avoids lottery tickets and expensive deep in-the-money premium |
| Spread | (ask − bid) / mid ≤ 10%, never above 15% | you pay it on entry and exit |
| Open interest | ≥ 500, and today's volume ≥ 100 | fills and marks you can trust |
| Breakeven | the underlying target is beyond ask + strike (call) or strike − ask (put) | the trade must win if the thesis is right |
| Implied volatility | prefer IV rank < 60; if higher, choose closer to the money and lower the target | high IV deflates as the move happens |
| Earnings | none before your max holding day | IV collapse after the report |

## 6. Exit plan (required fields)

- **Target % on the option**: estimate the option at your underlying target, roughly
  `delta × (target − spot) − theta × days`, divided by the ask. Use that, not a round number.
- **Stop %**: where the underlying reaches the invalidation price, translated the same way. Usually 30-50%.
  A stop below 25% gets hit by noise and the spread; above 60% means the invalidation was not thought through.
- **Max hold days**: the date in the edge statement, usually 3-7 days. Never plan to hold into the last 3 days
  before expiry, where decay is steepest.

## 7. Confidence

Confidence is the probability that **this trade makes money after the spread**, not that the direction is right.
- Start from about **0.40** (most short-dated long options lose).
- Add about 0.05 for each additional agreeing evidence family beyond two, subtract for each yellow flag
  (high IV, wide spread, move larger than expected move, regime against you).
- Stay within 0.25 to 0.75 until you have 30 closed trades; then compare your stated confidence with your
  actual win rate in `tid.my_trade_ideas()` and correct for over- or under-confidence.

## 8. Thesis format (paste into the `thesis` field)

```
EDGE: <one sentence: what, by when, why>
REGIME: <trend-up | trend-down | range | stress>
EVIDENCE: flow=<numbers or none>; positioning=<...>; darkpool=<...>; price=<...>; catalyst=<...>; vol=<IV rank, expected move>
FAMILIES: <comma list of agreeing families, e.g. flow,positioning,price>
AGAINST: <strongest contrary evidence, or none>
TARGET: underlying <price> by <date>; option est. <price>
INVALIDATION: underlying <price> or <event>
CONTRACT: delta <x>, spread <y>%, OI <n>, IV rank <r>, breakeven <b>
```

The `FAMILIES` line matters most for learning: it lets results be broken down by which evidence was used.

## 9. When to skip a window

Use `tid.skip_window(reason)` when:
- no candidate has two agreeing families and nothing strongly against;
- the regime is **stress**, or a high-impact event (FOMC, CPI) lands inside the hold and the idea is not about it;
- every suitable contract fails the spread or open interest rule;
- it is a half-day session's last window (the market closes before the next check).

## 10. Learning loop

- **After each closed trade** (from `tid.my_trade_ideas()`): note in one line each whether the thesis was right,
  whether the timing was right, and whether the contract choice helped or hurt (spread, IV, delta).
- **Weekly**: win rate and average return by `FAMILIES` combination and by regime. Lean towards what worked,
  but do not drop a family on fewer than 20 trades.
- **Do not** change your rules after a single loss or win.

## 11. API budget per window (about 50 calls, 150 a day)

| Step | Calls |
|---|---|
| Context (section 1) | 4 (economic calendar once a day) |
| Candidates (section 2) | 5 |
| Validation (section 3), 2-3 names | 16-24 |
| Contract selection (section 5) | 2-4 per idea |
| Margin | ~10 |

If a call fails with `rate_limited`, wait the stated time; on `quota_exceeded`, stop and skip the remaining windows.
