# TID-3.4 Prospective Validation Protocol

**Status:** DRAFT. Not frozen until Sections 12 to 14 are complete.
**Protocol version:** 3.4.2-draft (supersedes 3.4.1-draft)
**Freeze timestamp (ET):** [to be filled at freeze]
**Protocol hash:** [SHA-256 of the frozen text, written at freeze; see Section 12 for the canonical form]

Fields in [brackets] must be filled before freeze. Nothing in brackets may be filled after confirmatory data collection begins.

**Changes from 3.4.0:** F vs T0 is the primary comparison, with T1 as a diagnostic. Pairing is by date and direction. Bootstrap runs on the full session calendar. An MDE gate and a revised robustness rule were added. The no-edge verdict is renamed. Freeze prerequisites now require operational evidence.

**Changes from 3.4.1:**
- Flow persistence, OI corroboration and OI materiality now have bracketed operational definitions (Section 2).
- Gap contribution, return data source and corporate-action handling are defined (Section 4).
- Sector and liquidity moved out of the primary cell into the fixed-effects sensitivity model; robustness check 4 is now distinct from the primary (Sections 5, 11).
- Planned end, hard cap and extension rule added (Section 12).
- The power gate now covers the full promotion rule, not only rejection of zero (Sections 7, 10).
- A prospective pilot window is defined, separate from the confirmatory cohort (Section 12).
- "Materially harmful" is defined directly; the Risk-off slope term is disambiguated (Section 8).
- Robustness counting rule reworded; check 3 horizon fixed (Section 11).
- Random-control relaxation is the expected path in a 50-name universe (Section 9).
- Canonical form of the hashed text is defined (Section 12).

## 1. Hypothesis

H1: Among TID-2.11 daily breakout triggers, those with persistent institutional flow and directionally corroborating open interest (F) earn higher direction-adjusted five-session underlying returns than those with no qualifying flow persistence (T0).

This is a test of underlying returns only. It is not an options P&L test.

## 2. Event definitions

**Trigger event (E):** A TID-2.11 trigger on the 50-name universe at a completed daily close, using the frozen thresholds (volume 1.20x, CLV 0.65/0.35, extension 1.5x ATR14 from SMA20, five-session move 3x ATR14).

**Eligibility:** Price at or above $5; options available; no earnings inside the +5 window; fresh complete data (all hard gates except the flow gate).

**Calendar rule:** Earnings inside the +5 window are excluded using the earnings calendar known at signal time. Scheduled macro events are recorded from the calendar known at signal time, never a later revised one.

**Flow groups**, assigned before entry using only data TID had captured before the entry open:

| Group | Definition | Analytical role |
|---|---|---|
| F | Persistent flow + directionally corroborating OI | Primary treatment |
| T0 | No qualifying flow persistence | Primary control |
| T1 | Persistent flow + neutral or no material OI change | Secondary diagnostic |
| C | Flow or OI conflicts with trigger direction | Exploratory |
| U | Required flow or OI data unavailable | Excluded; count reported |

The primary comparison is F vs T0. The groups are mutually exclusive subsets of E, so no event is compared against itself. T1 vs T0 tests flow persistence alone; F vs T1 tests whether OI corroboration adds value beyond persistent flow.

**Operational definitions.** Group assignment is a deterministic function of captured data and the parameters below. All parameters are fixed at freeze and versioned with the model.

- **Directional flow print:** an options print on the ticker classified as [bullish/bearish rule, e.g. calls at/above ask or puts at/below bid count as bullish/bearish respectively] with premium at least [$___] and [DTE range ___].
- **Qualifying flow session:** a session in which net directional premium in the trigger direction is at least [___ $ or ___ × the ticker's 20-session median daily premium].
- **Persistent flow:** at least [m] qualifying flow sessions within the [n] sessions ending at S (inclusive), using only prints captured before the S+1 open.
- **No qualifying flow persistence (T0):** fewer than [m] qualifying sessions in that window, and no qualifying session in the opposite direction within the window (otherwise C).
- **OI change:** change in open interest from the S-1 report to the S report (the report published before the S+1 open), aggregated over [contracts matching the flow prints / all contracts within ___ DTE and ___ delta], call minus put, in the trigger direction.
- **Material OI change:** absolute OI change of at least [___ contracts or ___% of prior OI].
- **Corroborating OI:** a material OI change with the same sign as the trigger direction. Neutral: not material. Conflicting: material with the opposite sign.
- **Group precedence:** U (any required input missing) > C (flow or OI conflicting) > F > T1 > T0.

## 3. De-duplication

Per ticker and direction, a new event is admitted only after a 5-session cooldown from the previous admitted event. Suppressed events are logged but not analyzed. This prevents overlapping +5 windows from the same name.

## 4. Entry convention and returns

- Signal: completed daily close of session S.
- Flow and OI status must be fully determined from data TID had captured before the open of S+1. The availability time is the TID-3.2 first-capture timestamp. This shows when TID had the data, not necessarily when Tradytics first published it, and both timestamps stay visible in the record.
- If no qualifying OI capture exists before that open, the event is classified U.
- Entry: open of session S+1.
- Horizon h return: close of the h-th session counting the entry session as session 1, divided by entry open, minus 1.
- Direction-adjusted: multiplied by +1 (bullish) or -1 (bearish).
- Also record MFE, MAE, and the overnight, earnings, and scheduled-macro gap contributions.
- **Gap contribution (horizon h):** the sum of direction-adjusted overnight returns, open_t / close_(t-1) - 1, for sessions t = 2 to h counting the entry session as 1. The S to S+1 gap is excluded because entry is at the S+1 open. Earnings and scheduled-macro gap contributions are the subsets of those overnight returns whose overnight interval contains such an event.
- **Price source:** returns use the daily bars as first captured by TID-3.2. Later vendor revisions are recorded but do not change confirmatory returns; any discrepancy above [___ bp] is reported in the data-health log.
- **Corporate actions:** prices are split- and dividend-adjusted using factors known at the time of capture. If a ticker is halted for the rest of the window, delisted or acquired inside the window, the return runs to the last available trade, and the event is flagged and counted. [Alternative rule, if preferred: exclude and report.]

| Horizon | Role |
|---|---|
| +5 | Primary |
| +1, +3, +10 | Secondary |

## 5. Primary metric and pairing

The primary estimate compares F with T0 within date-direction cells, so a long/short mix difference between arms cannot masquerade as flow alpha.

$$\Delta ER_{5,d,q} = \overline{R}_{F,d,q} - \overline{R}_{T0,d,q}, \quad q \in \{\text{bullish}, \text{bearish}\}$$

- A cell is eligible only if it holds at least one F and one T0 event. All returns are direction-adjusted.
- Within each date, average the eligible cells. Each eligible date then carries equal weight in the primary mean.
- Within a cell, F and T0 events are averaged without further stratification. With a 50-name universe, splitting cells by sector or liquidity would leave most strata with only one arm. Sector and options-liquidity bucket [bucket thresholds set from pilot] enter the fixed-effects regression as covariates instead, so the sensitivity analysis tests whether flow proxies for attention or liquidity. Robustness check 4 tests sector matching directly.
- Report eligible bullish cells, eligible bearish cells, and eligible dates separately. They are not interchangeable.
- Dates with no eligible cell are excluded, and their number and share are reported.
- If fewer than [N_min eligible dates, set from pilot] exist at the planned end (Section 12), the result is Inconclusive by default.
- Estimator rule: the cell estimator is primary only if the pilot shows paired-cell coverage of at least [coverage threshold, set from pilot]. Otherwise the date × direction fixed-effects regression is the pre-registered primary estimator. This choice is made at freeze from pilot data and never after confirmatory outcomes are seen.
- The fixed-effects regression is reported as a sensitivity analysis in either case.
- Diagnostics: T1 vs T0 and F vs T1 use the same estimator. Arm C is exploratory.

## 6. Inference

- Unit of analysis: signal date, aggregated from date-direction cells.
- Two-sided test, alpha = 0.05. No one-sided option.
- Moving-block bootstrap on the complete trading-session calendar. Sessions with no eligible observation stay in the calendar as empty positions, contiguous session blocks are resampled, and eligible cells are recomputed within every resample. This keeps the effective block length from shrinking when empty dates are dropped.
- Block length: at least 10 sessions, [L = 10 or data-driven value]. A data-driven choice uses the pre-registered rule (Politis-White on pilot data, floored at 10) and is fixed at freeze.
- 10,000 resamples. Store the seed and the bootstrap implementation version.
- Sensitivity: ticker-clustered intervals, two-way clustered intervals, and the date × direction fixed-effects regression.
- Report raw events per arm, eligible cells, eligible dates, unique tickers, effective sample size, mean, median, and 95% CI.
- Power target 80%, using pilot variance and dependence.
- Interpretation: an upper 95% two-sided CI bound below δ is a deliberately conservative practical-equivalence rule. A standard equivalence test would use a 90% interval.

## 7. Practical-effect threshold (δ)

- δ = [___ percentage points of 5-session return].
- Set by [owner] from a stated cost-benefit judgment of what improvement justifies the added data cost and complexity, plus pilot variance estimates.
- Pilot variance is estimated without arm outcomes: apply random label permutations to eligible historical or pilot TID-2.11 triggers. Historical events inform variance and feasibility only and are never confirmatory evidence.
- Deadline: before the freeze timestamp. Immutable afterward.
- MDE gate: at 80% power and two-sided alpha = 0.05, the MDE for rejecting zero must be no greater than δ.
- Decision-rule power gate: by simulation from pilot variance and dependence (same estimator, bootstrap and calendar as Section 6, [≥ 1,000] simulated studies), with a true effect of δ, the probability of reaching "Promote for review" under conditions (1), (2) and (5) of Section 10 must be at least [80%]. The simulation stores its seed and code version. This gate exists because condition (2) alone succeeds only about half the time when the true effect equals δ.
- If either gate fails, the confirmatory study cannot start under this protocol. Use a pre-authorized lever (Section 12). δ is never relaxed to pass a gate.

## 8. Regime classification

Classified at signal timestamp from available information.

| Regime | Definition |
|---|---|
| Risk-on | VIX < 20 and SPX above SMA50, with SMA50 5-session change > +0.1% |
| Risk-off | VIX >= 25, or SPX below SMA50 with SMA50 5-session change < -0.1% |
| Transition | Everything else |

Dealer net-gamma sign is stored as a separate stratifier, never used to relabel regimes.

**Viability check (before freeze):** compute pilot regime shares. If any regime holds fewer than [15%] of events, collapse to two states (Risk-on vs Other) and record this in the protocol.

**Role of regime results:** a direction-consistency check only, not evidence. Report the point estimate and CI per regime. A regime is **materially harmful** if its point estimate is below [-δ], or its 95% CI upper bound is at or below zero. If regimes are collapsed to two states, "positive in at least 2 regimes" (Section 10) means positive in both.

## 9. Random-control specification (secondary)

- Per signal date, sample from the eligible universe, same direction, same sector where feasible, same volatility bucket, excluding the TID-selected ticker.
- Same eligibility conditions as TID events (liquidity, no earnings window).
- At least 500 draws, stored seeds, eligible pool and matching variables.
- Report the number of distinct possible portfolios per date. Where the pool has fewer than [10] names, relax to the next coarser matching level and record it. The relaxation order is fixed: [drop sector, then widen volatility bucket]. In a 50-name universe, relaxation is expected on most dates, and its frequency is reported.
- Compare TID against the distribution of control means.

**Research universe record:** store the exact 50 symbols, the universe effective date, inclusion and exclusion rationale, sector assignments, volatility buckets, and any membership change. Results apply to this hand-picked universe only and are not evidence that TID generalizes to the S&P 500 or Nasdaq-100. An expanded universe requires a new model version and its own cohort.

## 10. Decision table

| Outcome | All conditions required |
|---|---|
| Promote for review | (1) Lower 95% CI bound of the primary estimate > 0. (2) Point estimate >= [δ or δ/2; chosen before freeze, and the decision-rule power simulation in Section 7 must use the chosen value]. (3) MDE gate, decision-rule power gate and effective-sample requirements met. (4) Robustness rule in Section 11 met. (5) Regime consistency: point estimate positive in at least 2 regimes, none materially harmful (Section 8). |
| No practically meaningful edge | Upper 95% CI bound < δ, with sample and power requirements met. |
| Inconclusive | Anything else, including underpowered results or too few eligible dates. |

No practically meaningful edge means a practical improvement of size δ is unsupported by the data. It does not prove the true effect is zero, and a small positive estimate can still land here. Inconclusive is not success, and a non-significant underpowered result is not evidence of no edge.

Secondary comparisons (SPY, random control, 20/50 SMA baseline, T1 diagnostic, arm C) are exploratory and cannot change this verdict. Even if F beats T0, that does not establish options profitability. Options paper results are reported separately.

## 11. Pre-registered robustness checks

Robustness checks are not separate hypothesis tests, and none can promote the strategy on its own.

1. Exclude the single highest-contribution date.
2. Exclude gap-dominated events (definition below).
3. Alternative entry: close of S+1, with the exit date unchanged (close of session S+5), so the holding period is four sessions.
4. Sector-matched within-date pairing: F and T0 events are paired only within the same date, direction and sector.
5. Leave-one-sector-out, summarized as the minimum estimate across exclusions.
6. Winsorize R5 at the 1st and 99th percentiles.
7. Alternative comparator: F vs all non-F triggers in T0 and T1.

**Rule:** promotion requires at least 5 of the 7 checks to be both evaluable and positive in point estimate, and no evaluable check below -δ/2. An unevaluable check counts as not positive. A check with insufficient observations is marked unevaluable, never passed, and is reported explicitly. Evaluability thresholds [set from pilot].

Gap dominance uses a denominator floor so near-zero returns do not distort the ratio:

$$\text{gap share} = \frac{|\text{gap contribution}|}{\max\left(|R_5|,\; k \cdot \text{ATR14}_{\text{return scale}}\right)}$$

An event is gap-dominated when gap share exceeds 0.5. The ATR return scale and k are set before freeze. Use k = [1.0] only as the starting value for pilot sensitivity analysis.

## 12. Governance and locks

- **Freeze:** record the protocol hash, ET freeze timestamp, and a protocol-version flag in the model-version table. The confirmatory cohort starts the next trading session. Freeze requires completion of Sections 12 to 14.
- **Exploratory cohort:** the existing 100-observation cohort is permanently exploratory and never merged into confirmatory results. Historical TID-2.11 events may inform variance and feasibility only.
- **Blinding control:** confirmatory outcome tables are exposed only through a restricted role. Tuning work uses exploratory data only.
- **Model freeze:** TID-2.11 thresholds and hard gates are immutable. Changes follow the audited release process: motivation, new model version, old and new thresholds, historical test excluding the holdout, new cohort, original cohort preserved.
- **Retention:** confirmatory-event records are exempt from hot-tier expiry or remain queryable from the warm tier through final analysis.
- **Planned end:** collection ends at the later of [N_planned eligible dates] or [calendar date], subject to a hard cap of [calendar date or session count]. An event whose +10 window is still open at the end is followed to completion; no new events are admitted after the end.
- **Extension:** lever (a) may be used once, before freeze or at a pre-set checkpoint, and only on data-health evidence (eligible-date accrual, coverage). Outcome data never informs an extension. The extended end and hard cap are recorded with a new protocol version before the extension takes effect.
- **Interim looks:** no outcome looks before [N_min eligible dates]. Only data-health reports are allowed before then.
- **MDE failure levers (decided now):** (a) extend collection, (b) widen the universe under a new model version, (c) reclassify the study as descriptive-only. Changing δ or the primary metric is not allowed.
- **Pilot window:** a prospective window of [___ sessions] with full TID-3.2 captures, run before freeze. Historical triggers lack first-capture timestamps, so they cannot be labeled F or T0 and cannot estimate paired-cell coverage; the pilot window can. Pilot events are permanently exploratory, labeled as such alongside the 100-observation cohort, and never merged into confirmatory results. Pilot outcomes by arm are hidden from anyone setting thresholds or δ.
- **Pilot feasibility report:** produced before freeze from pilot data only, covering paired-cell coverage, liquidity and sector balance, regime distribution, variance, dependence, effective sample size, eligible-date counts, and MDE. It exposes no treatment-arm outcome comparison to anyone tuning the model.
- **Protocol hash:** the hashed text is this file as committed to the repository at freeze: UTF-8, LF line endings, no trailing whitespace changes, with the hash and freeze-timestamp fields left as their bracketed placeholders. The freeze commit SHA is stored with the hash.

## 13. Operational prerequisites

A deployed module that has not been exercised is not a satisfied prerequisite.

| Prerequisite | Required evidence |
|---|---|
| TID-3.2 snapshots | Captured raw snapshots with capture-time hashes, including OI first-capture timestamps |
| TID-3.3 heartbeat | Independent watchdog execution and a successful canary alert delivered |
| TID-2.12 OI mapping | Verified OI timing and contract-level session mapping against actual captures |
| Confirmatory access | Restricted-role test showing no unauthorized access to outcomes |
| Model freeze | Versioned TID-2.11 thresholds and hard gates recorded |
| Storage | Retention policy documented and confirmatory-record exemption confirmed |

The OI availability time is the TID-3.2 first-capture timestamp. If the vendor supplies only a date with no capture evidence, that observation cannot qualify as F.

## 14. Freeze checklist

This is a review checklist, not a database-backed freeze record.

- [ ] F vs T0 primary comparison and T1 diagnostic grouping finalized
- [ ] Flow, OI and group-precedence parameters in Section 2 fixed
- [ ] Gap contribution, price source and corporate-action rules confirmed
- [ ] Date × direction pairing and aggregation logic finalized
- [ ] δ selected and cost-benefit rationale recorded
- [ ] Pilot window completed and labeled exploratory
- [ ] Pilot variance, clustering, and MDE calculation completed; MDE gate passed
- [ ] Decision-rule power simulation completed and passed; condition (2) threshold chosen
- [ ] Planned end, hard cap and extension rule recorded
- [ ] N_min eligible dates and block length recorded
- [ ] Regime viability check completed and classifier frozen
- [ ] Random-control matching and seed methodology implemented
- [ ] Gap-dominance and robustness definitions finalized
- [ ] OI first-capture timestamps verified against actual captures
- [ ] TID-3.2 raw snapshot capture tested with capture-time hashes
- [ ] TID-3.3 independent heartbeat and canary notification tested
- [ ] Confirmatory restricted-role access tested
- [ ] Exploratory cohort permanently labeled and isolated
- [ ] Retention and confirmatory-data protection verified
- [ ] Model version and frozen TID-2.11 thresholds recorded
- [ ] Protocol hash and ET freeze timestamp stored
