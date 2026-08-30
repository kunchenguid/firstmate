---
name: quant-research-method
description: >-
  Agent-only method for quantitative experiments.
  Load before scoping a quant experiment, writing a backtest brief, or interpreting a backtest result.
  It distinguishes factor tests from gate tests and owns their attribution, timing, comparison, statistical, null-result, and methodology-learning discipline.
user-invocable: false
metadata:
  internal: true
---

# quant-research-method

Load this skill before scoping any quantitative experiment, before writing a backtest brief, and before interpreting a backtest result.
This skill is the single owner of the fleet's general quant-experiment method.
It does not authorize a backtest, data access, promotion, or an order.

## Decide the test first

A factor test asks whether one feature improves prediction.
Freeze the model, label, universe, split, and all non-tested features.
Run a paired ablation and evaluate predictive metrics, including Rank IC, on the same observations.
A factor test needs no strategy, no entry rule, and no exit rule.
Specifying entry or exit rules for one is an attribution error.

A gate test asks whether trading only in a stated condition improves a stated strategy.
Run the factor test first when the proposed gate contains a new feature.
Then implement the gate as an explicit custom state strategy with stated transitions, decision time, execution time, and exposure.
Compare it to the same ungated strategy with exposure-matched and volatility-matched controls.
Inheriting a framework strategy for a gate test is worse than adding entry or exit rules to a factor test because it answers an unstated trading question.

## Make the execution claim attributable

Never inherit a framework default for the strategy itself.
If a backtest brief does not name the strategy class, parameters, state transitions, decision clock, signal clock, execution clock, and one owner of lag, its result is not attributable to the hypothesis.
Assert the logged signal `available_at`, decision time, and fill time produce exactly the stated number of lags.

RD-Agent(Q)'s factor runner invokes Qlib factor templates whose `PortAnaRecord` uses `TopkDropoutStrategy` over cross-sectional predictions.
That path can support a ranking-factor comparison, but it is not evidence for a swing or gate strategy.
Qlib's bundled signal strategies periodically rebalance rankings or target weights rather than expressing entry or exit state machines.
For a flip-and-hold gate, implement the declared state machine as a custom `qlib.strategy.base.BaseStrategy`.
The simulator maintains the account's current position, so an explicit custom strategy can hold state across bars.

## Preserve decision-time correctness

Store both `period_end` and `available_at` for every feature, state, universe membership, and event input.
Enforce `available_at <= decision_time` at the join and retain the checked columns in the run artifact.
Use the prior completed higher-timeframe period only: week W is usable in W+1 and month M is usable in M+1.
Never compute a weekly or monthly bar from a partial current period and forward-fill it into decisions.
Build the label, signal, order, and execution timeline in one artifact and reject any mismatch between label horizon and executable fill.
Use point-in-time universe membership, corporate actions, and delisting returns rather than a survivor list.

## Isolate the claim and comparison

Test one indicator at a time.
Do not test a composite state code when the claim is about one indicator because squeeze, momentum, dead-zone, and proximity rules make the result uninterpretable.
Pre-state the hypothesis, expected direction, primary metric, rejection condition, and fixed controls before the first measurement.

Exposure reduction is not alpha.
For every gate, report the acceptance rate, time in market, gross and net exposure, turnover, and risk alongside returns.
Compare with exposure-matched and volatility-matched baselines, and use a placebo gate with a similar acceptance rate when feasible.

Report panel coverage separately from measurement support.
Panel coverage is the number of distinct observation dates in the panel.
Per-signal support is the number of dates on which that signal has both comparison buckets populated.
Report both quantities for every signal and never use one as a proxy for the other.

Collapse cross-sectional results to one statistic per date before inference.
Correct the resulting series for serial dependence and for overlap in forward-return windows.
Naive standard errors were 1.7x to 2.9x too narrow in prior real-data checks, so estimate the correction instead of applying a fixed multiplier.
Use walk-forward splits for research selection and reserve a sealed holdout, frozen specification, predefined metrics, and selection-aware inference for confirmation.

## Treat the null honestly

A null, adverse cost result, or rejection condition is a result.
Do not tune features, windows, thresholds, or costs toward a positive outcome.
Re-run only to correct a documented execution defect that changes what actually ran, then preserve the original result and link the corrected run to it.
Do not re-run merely because the number was unfavourable.

## Check the growing failure-mode list

This is a growing list, not a claim that these are the only ways a result can fail.
Before accepting a result, run the detector named for every applicable failure mode.

- **Current-week leakage:** assert every higher-timeframe row has a completed `period_end` and `available_at <= decision_time`.
- **Incorrect Wilder ATR initialization:** reproduce the warm-up seed and recurrence against a hand-checked reference before using any downstream state.
- **Survivor universe:** reconcile each decision-date universe to point-in-time membership, delistings, and corporate actions.
- **Label/execution mismatch:** inspect the recorded label, signal availability, decision, order, and fill timeline for the claimed horizon.
- **Composite contamination:** run the primitive indicator with all other state filters absent and name every remaining control.
- **Mechanical risk reduction:** compare return and drawdown to exposure-matched, volatility-matched, and, where feasible, placebo-gate controls.
- **Goalpost drift:** hash or version the pre-measurement hypothesis, metric, controls, and rejection condition before reading results.
- **Framework-default strategy:** diff the run configuration against the brief and reject any unnamed strategy class or parameter.
- **Double lag:** assert the signal, decision, and execution timestamps have exactly the declared lag, with one transformation owning it.
- **Coverage-support confusion:** report panel observation dates and per-signal populated-bucket dates as distinct fields.

## Close the methodology loop

Every traversal records two findings alongside the market feedback record.
The market finding says whether the hypothesis survived.
The required `METHODOLOGY FINDING` says what in the process was wrong or nearly misleading and names the rule that would have caught it.

Before closing the traversal, check that the methodology finding exists.
If it generalizes beyond that experiment, append the failure mode and its detector to this skill in the same change, then verify the skill contains both.
"Someone should update the method" is not a completed traversal.

This mechanism prevents repetition of known mistakes.
It cannot identify a new class of error, which is why independent external review remains necessary and must not be made falsely internal.
The tenth traversal should be impossible to fool by any failure that fooled one of the first nine.

## Sources consulted

- Qlib source: `/Users/sz/github/qlib/qlib/contrib/strategy/signal_strategy.py`, `/Users/sz/github/qlib/qlib/contrib/strategy/cost_control.py`, `/Users/sz/github/qlib/qlib/strategy/base.py`, and `/Users/sz/github/qlib/qlib/backtest/executor.py`.
- RD-Agent source: `/Users/sz/github/rd-agent/rdagent/scenarios/qlib/developer/factor_runner.py` and its `scenarios/qlib/experiment/factor_template/` configurations.
- R&D-Agent(Q) paper: `projects/BlackPearl/doctrine/sources/rdagent-quant-2505.15155v2.md`, especially its factor-fixed evaluation and factor/model pairing description.
- *Machine Learning for Trading*, 3rd ed.: `projects/BlackPearl/doctrine/sources/machine-learning-for-trading-3e.md`, especially decision-time correctness, walk-forward validation, and its exploration/confirmation evidence boundary.
