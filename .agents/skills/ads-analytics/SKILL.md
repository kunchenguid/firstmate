---
name: paid-traffic-ops
description: >-
  General paid-traffic operations playbook: scale up/down, pause, hold, approve vs kill,
  winner/drain framing, validation windows, and multi-platform decision patterns.
  Load when analyzing ads performance, diagnosing pacing, designing scale/pause rules,
  validating historical media decisions, backtesting choice policies, or drafting Jev-style
  action prompts for Meta, Google, or other paid channels.
  Owns reusable traffic-management practice; client-specific constants live in optional
  overlays under references/, not in this body.
user-invocable: false
metadata:
  internal: true
---

# paid-traffic-ops

Reusable decision practice for paid traffic management across accounts and platforms.
This skill is methodology, not one customer's report automation.
Load client overlays only when the active account matches; never treat overlay numbers as universal law.

Optional overlays live under `references/` (for example `references/client-treinar-servicos.md`).
When an overlay and this body conflict on a named account, the overlay wins for that account only.

---

## 1. Load triggers and scope

Load this skill when any of the following is true:

- The ask is about paid-media diagnosis, pacing, winners, drains, scale, pause, or hold.
- A worker must design or validate approve/kill/scale rules from historical ad data.
- A backtest or choice model needs action enums, feature checklists, or decision windows.
- Multi-platform notes (Meta vs Google vs others) affect cost base, attribution, or scale mechanics.

Out of scope here: data-ingestion extractors, warehouse connectors, and running live model training.
Those stay in their own tooling; this skill owns how to reason once the numbers are trustworthy.

---

## 2. Hard methodological rules

These rules are platform-agnostic.
Violating any one of them corrupts the rest of the analysis.

**R1 — Define the sale before counting it.**
Agree what counts as a primary purchase (or primary lead) for the funnel under study.
Add-ons, order bumps, upsells, and downsells are usually additional revenue on the same buyer, not new sales.
Use the primary-sale definition as the denominator for CPA and conversion rate.
Sum all attributed revenue lines when computing revenue, contribution margin, and ROAS unless the client states otherwise.
State the definition in the report; do not silently switch mid-analysis.

**R2 — Compare structures on aggregate economics, not per-event averages.**
When asking where margin is born, use aggregate margin over spend (MC ÷ investment, or equivalent) at the unit under study.
Averages that weight a tiny ad equal to a large ad hide volume effects.

**R3 — Goals belong to the whole funnel, then cascade by channel.**
A funnel MC or revenue goal is the sum of channels, not a single channel's scoreboard.
Never compare one channel's result to the full-funnel goal without cascading.
Cascade with current, stated channel weights (historical share of MC or investment for the relevant window), and declare the weights used.

**R4 — Exclude contamination windows before trend or pacing reads.**
External anomalies (site redirects, tracking outages, bad pixels, payment outages, one-off PR spikes) corrupt both efficiency and volume.
Identify them from evidence, scope them out of trend and calibration sets, and name the excluded dates.
Contamination is a method, not a fixed calendar borrowed from another account.

**R5 — Manage media at the delivery unit id, not the creative name.**
Creative name aggregates every placement of the same asset across structures.
The delivery unit (`ad_id` / ad set id / campaign id, depending on the decision) is where budget, delivery, and lifecycle actually live.
A "winning" creative name with mostly failing delivery units is an aggregation error.
Use names for creative-content questions; use ids for performance, spend, pause, and scale.

**R6 — Approved ≠ Winner.**
**Approved** = passed the initial validation window (entry qualification).
**Winner** = retrospective label on accumulated results (exit / pillar qualification).
A unit can sit in any cell of the Approved × Winner matrix.
Always produce that matrix when labeling performance.

**R7 — Initial validation is strict; revocation of a validated unit is conservative.**
Early kill criteria exist to fail cheap and fast.
The same criteria applied continuously to already-validated winners will pause good units on short bad windows.
Never reuse the entry gate as an automatic daily kill switch on validated spend.
Prefer budget reduce, longer lookback, and channel-wide context before pausing a proven unit.

**R8 — Cost base must match the economics the business actually pays.**
Some platforms and exports report net media; the operation may pay tax, agency fee, or platform surcharge on top.
Some platforms already invoice gross.
Before ROAS, CPA, MC, or pacing:

- Establish whether each source is net or gross.
- Apply account-configured gross-up only where the source is net and the business pays the extra.
- Never double-count tax already inside an invoice.
- Recompute break-even ROAS on the same cost base used in the denominator.
- Reconcile totals to the client's dashboard before trusting ratios.
- Declare the factor and effective dates when a gross-up is used.

Default posture when unknown: do not invent a tax factor; flag the gap and use the source as-is with an explicit caveat.

**R9 — Contribution margin has one formula per account, applied everywhere.**
Typical form when net revenue and gross media are the agreed bases:

```
MC = net_revenue − media_cost_on_agreed_base
MC% = MC ÷ gross_revenue
ROAS = gross_revenue ÷ media_cost_on_agreed_base
```

Never subtract fees or taxes that are already netted inside `net_revenue`.
Use the same formula at ad, ad set, campaign, channel, and funnel grain.

**R10 — Refund and dispute policy is explicit.**
Decide with the client whether refunded or disputed orders stay in revenue and buyer counts.
Many dashboards keep them in gross sales and show refunds as a separate line.
Whatever the rule, apply it uniformly and list excluded statuses (expired, refused, unpaid, unmapped, and so on).

**R11 — Include every revenue source the macro claims to cover.**
If the funnel includes secondary checkouts, alternate processors, or marketplace rails, they count in macro pacing even when channel mapping is coarse.
Do not drop rows because a dataframe dtype filter missed string columns.

---

## 3. Unit of management

| Question | Prefer |
|---|---|
| Creative content, hook, narrative, asset library | creative / ad **name** |
| Performance, spend, lifecycle, approve/pause, drain id | delivery **id** (ad, ad set, or campaign) |
| Budget owner for a scale action | the entity that actually holds the bid/budget (ad set vs campaign, ABO vs CBO) |

Same split applies one level up: ad set id vs name, campaign id vs name.
Practical rule: once the question is performance, cross by id before concluding.

---

## 4. Decision actions (enums for ops and choice models)

Use a closed action set unless the account overlay defines more.
These enums are stable inputs for backtests and Jev-style prompts.

| Action | Meaning |
|---|---|
| `HOLD` | No change; keep learning or ride variance |
| `PAUSE` | Stop delivery on the unit |
| `REDUCE` | Lower budget or cap (prefer before pause on validated units) |
| `SCALE_MODERATE` | Raise budget modestly on the existing unit (typical +15–30%, at most ~30% per step) |
| `SCALE_AGGRESSIVE` | Larger raise or additional structural copy — higher risk |
| `DUPLICATE_TEST` | New delivery unit / structure to test transfer (not the default scale path) |
| `WAIT_WINDOW` | Decision deferred until the post-change or validation window closes |
| `INVESTIGATE` | Numbers conflict or tracking is untrustworthy; do not act on efficiency yet |

Pair every action with:

- **unit_id** (the delivery id)
- **reason_codes** (which gates fired)
- **evidence_window** (dates and grain)
- **confidence** (data sufficiency)

---

## 5. Feature checklist (point-in-time only)

Decisions and backtests may use only features knowable at decision time.
No future leakage.

**Identity and structure**

- platform, account, campaign_id, adset_id, ad_id
- structure class (e.g. broad/manual, ABO/CBO, prospecting/remarketing) as labeled at the time
- age of unit (days since first delivery)
- whether the unit was already Approved or Winner under then-current rules

**Spend and delivery (windowed)**

- spend on 1d / 3d / 7d / lifetime (as available)
- impressions, CTR, CPC, CPM
- funnel rates the account actually tracks (thumbstop, hold, landing view, checkout start, purchase)

**Economics (windowed, agreed cost base)**

- revenue, net revenue, purchases (primary-sale definition)
- ROAS, CPA, MC, MC%
- distance to break-even ROAS and to target CPA/MC%

**Motion**

- last budget change size and date
- days since last pause/unpause
- concurrent channel-level ROAS move (external factor proxy)

**Data quality**

- tracking coverage / unattributed share
- whether the window intersects a contamination exclusion
- sample flags (too little spend, too few purchases)

Do not feed post-outcome labels (final Winner flag days later) into the decision feature set for a backtest of that day.

---

## 6. Configurable performance benches

Every numeric gate below is a **default starting point**, not sacred law.
Replace from account history when enough winners and losers exist; publish the calibrated set in the client overlay or the report appendix.

### 6.1 Initial validation window

Default: **first N days OR spend S**, whichever comes first.
Starting suggestion: N = 5 days, S sized to roughly 0.5–1× historical median spend-to-first-verdict on winners for that account.
If history is thin, keep N small and S explicit in currency units the buyer recognizes.

### 6.2 Approve gate (entry) — per delivery unit

Default pattern (all must hold inside the validation window unless overlay says otherwise):

- primary sales ≥ `min_sales_approve` (default 2)
- MC% ≥ `mc_pct_approve` (default 50%)
- ROAS ≥ `roas_approve` (default 2.5× on the agreed cost base)

Properties to verify when calibrating:

- **Precision on early failure** matters more than perfect recall.
- Some eventual winners will miss the early approve gate; keep a qualitative watch band for positive-but-incomplete signals (for example 1 strong sale with healthy MC%).

### 6.3 Kill gate (early) — per delivery unit

Default pattern (either fires):

- 0 primary sales after spend ≥ `spend_kill_no_sale` (default: about half of validation spend S), **or**
- MC ≤ `mc_kill_floor` and ROAS < `roas_kill` (defaults: material negative MC and ROAS under ~0.8×)

Calibration targets:

- High precision: historical winners should almost never trip the early kill gate inside their true validation window.
- Do not "fix" a working kill threshold upward only because operators ignore it; fix adherence first.
- A higher spend ceiling often becomes a floor (moral hazard) and increases total loss.

### 6.4 Winner label (retrospective)

Default: primary sales ≥ `min_sales_winner` (default 5) and MC% ≥ `mc_pct_winner` (default 30%) on accumulated history for that delivery unit.
Winners are pillars for narrative and prioritization, not an automatic bid strategy.

### 6.5 Scale-ready (budget increase on the same unit)

Default pattern:

- lifetime long enough to exit pure noise (often ≥7 days)
- material accumulated spend in a band the account treats as "proven enough"
- recent window still clearing the approve economics (for example last 3 consecutive complete days)
- scale = budget raise on the set where the unit already delivers, not blind duplication into a new structure
- step size default: **at most ~30% budget increase per step** — reassess before stacking another raise
- when cutting a losing unit's budget instead of pausing it outright, default cut is **about 30–50%**

`PAUSE` and any `SCALE_*` decision require both **constancy** (the signal held across the window, not one lucky/unlucky day) and **performance** (the metrics actually clear/miss the gate) on **paired 3D and 7D windows** — never decide from ROAS or MC alone, and never from a single window in isolation. Always read CPA together with margin (MC/MC%) and ROAS; CPA alone can look fine while margin erodes, and vice versa.

New (not-yet-approved) ads get looser, pre-defined pause thresholds so they have room to clear the initial validation window (see 6.1–6.2). Matured/approved ads need stricter constancy and performance evidence before a pause — see 6.8.

#### 3D × 7D performance matrix (default actions)

| 3D read | 7D read | Default action |
|---|---|---|
| Good | Good | Constancy confirmed — proceed with `SCALE_*` per the step-size default above |
| Good | Bad | Recent bounce inside a weak lifetime — hold or gentle probe; do not scale off 3D alone |
| Bad | Good | Likely noise or a short-lived external dip inside a proven unit — hold, or a small gentle scale if 7D is strongly clear; do not cut on 3D alone |
| Bad | Bad | Sustained underperformance — hard cut or `PAUSE` per 6.8 |

### 6.6 Post-change observation window

After `SCALE_*`, `REDUCE`, or structure change:

- days 1–2: noise — do not revert from these alone
- days 3–5: intermediate
- days 5–7+: decision-quality for moderate changes

Use `WAIT_WINDOW` rather than thrashing.

### 6.7 Noise filter

Prefer an explicit rule such as "ignore units with only one primary sale when ranking drains/winners" over silent impression cutoffs, unless the account's tracking makes sales unreliable.
State the filter.

### 6.8 Revoking a validated unit

No single automated rule replaces judgment.
Before `PAUSE` on a former approve/winner:

- lengthen the lookback (often 14d+, not 5d)
- prefer `REDUCE` first
- compare recent trajectory to the unit's own early life (stable vs free-fall)
- check whether the whole channel moved the same way (external factor)

---

## 7. Approved × Winner matrix

Eligible units need a minimum spend floor so pure noise stays out (configure per account).

| Category | Pattern | Operational read |
|---|---|---|
| 1. Consolidated winner | Approved + Winner | Pillar — protect and scale carefully |
| 2. Winner forming | Approved + not yet Winner | Active watch — not "just another test" |
| 3. Slow bloomer | Not approved + Winner | Documents approve-gate recall limits |
| 4. Middling | Not approved, not winner, some sales, MC not deeply red | Neither star nor bleed |
| 5. Mild loser | Modest negative MC with some sales | Candidate to reduce or recycle |
| 6. Clear loser | Deep negative MC or zero sales past kill spend | Pause / do not relaunch without a new hypothesis |

Always show delivery ids in tables so operators can find units in the ads manager.

---

## 8. Scale and structure patterns (general)

These are recurring patterns, not guaranteed laws.

**Scale on the unit that already works.**
Budget increases on the delivering ad set/campaign usually beat cloning a winner into an unproven structure.
Treat duplication as a transfer test (`DUPLICATE_TEST`), not as the default scale action.

**Structure often dominates creative copy.**
The same asset in broad vs narrow, ABO vs CBO, or prospecting vs remarketing can flip results.
Confirm with natural experiments (same creative name, different delivery ids) before rewriting creative doctrine.

**First structural copy can work; repeated copies decay.**
When history supports it, a second delivery unit may still add margin; later generations often fade.
Validate per account; do not assume infinite duplication.

**Inertia on bad ROAS is a first-class loss mode.**
Holding spend on units with sustained sub-break-even ROAS frequently destroys more margin than shy scaling fails to capture.
Stop-loss discipline is an equal lever to scale.

**Safe-ish scale quadrant (default prior).**
Moderate raises on mid-high ROAS bands beat aggressive raises on thin data.
Reducing after a peak ROAS band can be rational recycling, not only "fear".
One-day signals are noisy — do not decide from a single day in isolation.

**Isolation vs batch.**
Neither "always isolate winners" nor "always batch" is universal.
Some creatives need solo delivery; others only work inside a set.
Judge on aggregate MC/Inv and paired history, not slogan.

**Audience automation and tight interest stacks.**
Platform auto-audiences and ultra-narrow interest/lookalike stacks are account-specific bets.
Treat "worked elsewhere" as a hypothesis; verify on this account's winner rate and aggregate MC before mandating them.
Document confirmed anti-patterns only inside the client overlay with sample evidence.

**Remarketing winners rarely port cleanly to cold prospecting.**
When scaling a remarketing-only winner into cold, start small, validate on a short window, and step up only if economics hold.

---

## 9. Contamination and anomaly windows

Method:

1. Detect candidate windows from external incident logs, tracking gaps, or impossible metric spikes.
2. Mark inclusive date ranges excluded from calibration, trend, and "normal pacing" narratives.
3. Still report raw spend inside the window in an appendix if finance needs it.
4. Never hardcode another client's incident dates into a new account.

Revisit exclusions when the incident is reclassified (false alarm vs real).

---

## 10. Multi-platform notes

**Cost base**

- Meta exports and many warehouses are often net of media tax; BR operations commonly need a configured gross-up for true CPA/ROAS.
- Google Ads invoices in some regions already include tax; gross-up there double-counts.
- Apply platform-specific rules at daily grain per delivery unit before mixing channels.

**Optimization surface**

- Meta: heavy creative and ad-set structure effects; Advantage-style automation is optional, not mandatory.
- Google: query/intent and asset-group structure dominate; creative "hooks" transfer poorly from social playbooks.
- Other channels (organic, CRM, partners): usually lower CPA and lower ceiling — pace them in the cascade, do not pretend they replace paid volume.

**Attribution**

- Expect unattributed or cross-channel sales (S/track and cousins).
- Macro pacing includes them; tactical optimize-by-id views exclude what you cannot steer.
- Never force id-level counts to match a dashboard channel card when revenue already reconciles and the dashboard's own channel cards do not sum to its total.

**Break-even ROAS**

- Recompute on the cost base in use.
- A net-base break-even and a gross-base break-even are different numbers; do not mix them in one sentence.

---

## 11. Diagnostic order

Standard sequence; each step feeds the next:

1. **Channel pacing** — cascaded goal, gap, required run-rate; macro (includes unattributed) and tactical (steerable by id).
2. **Channel structure** — proven core vs exploration; who carries margin on aggregate MC/Inv.
3. **Winners and drains** — by delivery id, with ids in the tables.
4. **Scale behavior** — what the account tried; what held on post-change windows.
5. **Temporal patterns** — seasonality and lifecycle only after contamination exclusions.
6. **Action plan** — ordered by impact and risk; separate mandatory gates from suggestions.

Macro first so local optimization does not fight the wrong goal.

---

## 12. Report shape (when a written diagnosis is the deliverable)

Impersonal language; define concepts before conclusions; show rejected alternatives next to chosen parameters.

1. Executive summary — pacing, efficiency vs volume gap, top fronts.
2. Where we are — macro and tactical pacing; CPA/ROAS vs cascaded target.
3. What holds the channel — winners, forming winners, drains by id.
4. Bottlenecks — creative supply, structure anti-patterns, active drains, budget-motion × ROAS grids.
5. Action plan — mandatory vs suggested; copyable ids.
6. Metrics and gates — configured benches used in this run.
7. Full-funnel context — channel inside cascaded goals.
8. Next steps and method appendix — scope, definitions, statistical limits.

High CPA vs target usually means **efficiency**, not "not enough spend", until proven otherwise.

---

## 13. Statistical limits to declare

- Small winner samples make trajectory stories directional, not proof.
- Multiple budget moves inside one window confound causal reads of a single decision.
- Imperfect tracking creates unattributed sales — separate from steerable units.
- Survivorship bias: killed losers leave the live set and sweeten aggregates.
- Test bursts inflate exploration share — separate core vs exploration before calling channel decay.
- Short weekday effects often vanish as samples grow; demand robustness before operationalizing DOW rules.

---

## 14. Backtest and policy-design notes

When validating gates or training/choosing policies (including Jev-style action selection):

1. Freeze the primary-sale definition, cost base, and contamination exclusions first.
2. Build daily point-in-time feature rows per delivery unit (section 5).
3. Emit actions only from the enum in section 4.
4. Score with delayed outcomes (MC, ROAS, survival) outside the decision timestamp.
5. Separate train/calibration windows from holdout; never tune kill gates on the same days you report lift.
6. Report adherence separately from gate quality (a good gate operators ignore is an ops problem).
7. Keep client-calibrated thresholds in overlay or config, not hardcoded into shared prompts.

---

## 15. Client overlays

Account-specific material belongs in `references/client-<slug>.md` (or an external config the worker is given).
Overlays may hold:

- product and campaign scope filters
- tax/gross-up factors and effective dates
- checkout/sale field definitions
- calibrated approve/kill/winner numbers
- confirmed anti-patterns with sample evidence
- naming conventions
- dashboard reconciliation quirks

If no overlay applies, use this skill's defaults, state every numeric gate used, and flag low-confidence calibration.
