# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-dispatch-resolve.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when the typesafe.ai model, its API, or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in the private scout report.

## The API the tool depends on

Verified 2026-09-16 against `https://api.typesafe.ai`.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.
Observed end-to-end latency from a Mac was 123 to 348 ms per request, with the server's own upstream time at 4 to 60 ms.

### OpenRouter Decisions transport

Verified 2026-09-25 against OpenRouter's own published OpenAPI specification, fetched unauthenticated from `https://openrouter.ai/openapi.json`.
The spec lists `POST /api/alpha/decisions` (operation `createApiAlphaDecisions`) with request schema `DecisionsRequest` (`{model, state, questions, ...}`) and response schema `DecisionsResponse`, whose worked example matches the `{choice, confidence, probabilities, type}` per-question answer shape the tool already parses; the top-level security scheme is `bearer` (an `Authorization: Bearer <key>` header), and the operation's own example request names `model: "typesafe/jev-1.13"`, consistent with the `~typesafe/jev-latest` alias this change sends.
The spec also lists a compatibility path `POST /systemone` on the same host, described as accepting bare System One model IDs onto the `typesafe/` namespace; the tool does not use this path, since `TYPESAFE_API_KEY` already reaches the same model directly at `api.typesafe.ai`.

### Live OpenRouter run (2026-09-26)

Run against a real `OPENROUTER_API_KEY` (read directly from the operator's own `.env`, exported in-process for this run only, never printed, logged, or persisted), model `~typesafe/jev-latest`, answering as `typesafe/jev-1.13-20260917`.
Rules: a fresh five-rule file mirroring the shape of the 2026-09-16/17 runs (hardest tier with `approval: captain`, routine build, root-caused bug fix, trivial mechanical edit, read-only investigation), each with one `claude` profile.
Briefs: 25 fixtures, five per rule, each written to hit exactly one rule unambiguously (no borderline cases in this pass, so this run measures transport correctness and routing agreement, not floor-boundary behavior, which the 2026-09-23 runs already cover).

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 25 of 25 |
| Confidence | 0.90 to 1.0 (23 of 25 at 1.0) |
| Outcomes: clear / ambiguous / escalate / error | 0 / 0 / 25 / 0 |
| Input tokens per brief (min / median / max) | 592 / 608 / 621 |
| Output tokens | 71 |
| Wall time per call including quota-axi and jq (min / median / max) | 2,129 / 2,391 / 3,206 ms |
| API errors | 0 |

All 25 outcomes were `escalate`, for two distinct and expected reasons, not a transport or routing fault: the five hard-tier briefs escalated on `rule requires the captain's explicit approval before dispatch` (the rule's declared `approval: captain`, independent of quota); the other 20 escalated on `no rankable eligible candidate` because this run's ambient `quota-axi` snapshot reported the `claude` provider's quota state as `stale` ("Claude quota endpoint rate limited" from the live Anthropic quota check at run time), which the resolver correctly treats as unmeasurable rather than assuming availability.
Both are the documented safe-fallback behavior working as designed: an approval-gated rule never resolves without the captain, and unmeasurable quota never resolves `clear`.
The wall-time figure is dominated by the required `quota-axi --json` snapshot (about 2.0 s standalone in this environment) rather than the OpenRouter call itself; this environment's bash is 3.2 (no `EPOCHREALTIME`), so `fm-timing-lib.sh`'s `latency_ms` field falls back to whole-second resolution here and could not isolate the OpenRouter round-trip more precisely than that.
No `TYPESAFE_API_KEY` was available in this same run to repeat the side-by-side comparison; the rule-match agreement above is against the hand labels only, not against a parallel typesafe.ai run.
This is the first live, authenticated confirmation that the `OPENROUTER_API_KEY` path reaches OpenRouter's Decisions API, parses its response, and preserves every downstream safety gate; the request/response shape match against the published OpenAPI spec (above) is now also corroborated by a real response.

## Live rule match against real briefs

Run 2026-09-16 with the key injected for the one command through the vault (`av inject +TYPESAFE_API_KEY -- ...`), model `jev-latest`, confidence floor 0.6, timeout 5 s, one `quota-axi --json` snapshot for the whole run.
Rules: the captain's five-rule file with a captain-authored none option, one `approval: captain` rule, two rule floors on `model:fable`, and declared `provider` on the Pi profiles.
Briefs: 15 real briefs from this home's recent work plus 10 synthetic ones written to hit each rule.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 20 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 18 / 1 / 6 / 0 |
| Clear results with a wrong profile | 0 |
| API latency (min / median / max) | 152 / 214 / 348 ms |
| Wall time per call including jq (min / median / max) | 198 / 261 / 396 ms |
| Input tokens per brief (min / median / max) | 1,279 / 3,114 / 4,538 |
| Output tokens | 150 to 152 |
| API errors | 0 |

Of the five disagreements, one was a wrong hand label (the brief quoted the bug-fix rule's wording verbatim), three were real briefs the model read as the approval-gated design rule at 0.66 to 0.86 confidence and escalated by design, each of which the captain had in fact dispatched at the strongest-reasoning class, and one was a synthetic tweak that came back ambiguous at 0.41 confidence and was handed back to firstmate.
A lean request that asks only the rule Choice matched the full request (rule, profile, and status) on all 25 briefs, which is why the shipped tool asks one question and keeps every gate in code.
That table records the 2026-09-16 run with the captain-authored none option.
A second live run on 2026-09-17 used the same 25 briefs, held one quota snapshot constant through a fake `quota-axi`, and exercised a copy of this branch with the shipped neutral `No listed rule applies to this task.` option and option-free interface.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 18 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 17 / 2 / 6 / 0 |
| Clear results with a profile other than the hand label | 1 |
| API latency (min / median / max) | 137 / 220 / 1,795 ms |
| Input tokens per brief (min / median / max) | 754 / 2,589 / 4,013 |
| Output tokens | 60 to 62 |
| API errors | 0 |

The maximum latency was one outlier; the next slowest request was 309 ms.
The differing clear result was a synthetic small tweak that matched the simple-bug-fix rule at 0.90 and selected `cursor-grok-4.6-medium` instead of the hand-labeled `cursor-grok-4.6-high`: the tweak exemption removed from the none-option text belongs in that rule's own `when` text.
Two default-labeled briefs became ambiguous.

## Task sections and per-rule confidence floors

Run 2026-09-23 against `jev-latest` (answering as `jev-1.13.0`), comparing the resolver before this change (whole brief as state) with the resolver after it (only `## Captain's intent` and `## Firstmate spec`).
Each fixture brief was scaffolded with `bin/fm-brief.sh` (ship `--mode no-mistakes` or `--scout`), its two placeholders filled, and both resolvers run on the same file against the same rules.

Generic rules: a hardest-tier rule that requires the brief itself to call the work unusually difficult or high-risk and excludes routine builds, ports, and installers; routine feature, port, or installer builds; bug fixes with a stated root cause; trivial mechanical edits; and read-only investigations or audits.
Sixteen fixtures: ten clear-cut briefs (two per rule) and six borderline ones (a large port with signed installers, an installer after a broken upgrade, a large file split, a table migration, an unexplained slowdown, and a retry policy).

| Measure | Whole brief | Task sections |
| --- | --- | --- |
| Top rule matched the label | 16 of 16 | 16 of 16 |
| Input tokens per ship brief | 4,327 to 4,379 | 583 to 624 |
| Input tokens per scout brief | 2,861 to 2,874 | 584 to 597 |
| Borderline top-rule confidence below 0.99 | 0.77 split, 0.72 slowdown | 0.59 split, 0.70 slowdown |

The top rule matched the label on 16 of 16 fixtures under both shapes, so on these generic briefs the change did not improve routing accuracy.
Every clear-cut fixture answered at probability 0.99 or 1.0 under both shapes, so the scaffold boilerplate neither caused nor prevented a wrong pick.
The one routing difference is a regression: the large-file-split fixture went from clear (confidence 0.77, probability 0.82 on its labeled routine-build rule) to `ambiguous` (confidence 0.59, probability 0.66, the rest going to the neutral option), just under the 0.6 floor.
The gain that holds across the set is size: about 4,350 input tokens down to about 600 per ship brief.

### A routine port the hardest tier over-claims

Run 2026-09-23 against `jev-latest` (answering as `jev-1.13.0`).
The brief was a generic scaffolded ship brief for a routine port of a macOS-only capture helper to Windows plus a Windows installer, described as a straightforward port, with a long never-do-X safety list in its spec.
The rules were the same generic five-rule set with two changes: a loosely worded top-tier rule ("Large or hard engineering work that needs the strongest model, such as a multi-platform build or anything where a mistake is costly.") and the routine rule broadened to "Implementation where the worker must design parts of the solution itself within an existing codebase."
The task-sections row is the shape this change sends: the two task sections, with no kind line because it is a ship brief.

| Shape | Runs | Input tokens | Top-tier rule probability | Confidence | Implementation rule probability |
| --- | --- | --- | --- | --- | --- |
| Whole brief | 3 | 4,436 | 0.90 to 0.93 | 0.87 to 0.92 | 0.07 to 0.10 |
| Task sections | 5 | 670 | 0.88 to 0.91 | 0.84 to 0.89 | 0.09 to 0.12 |

Extraction does not prevent the top-tier pick; a loosely worded rule is matched from the task text alone.
With `min_confidence: 0.95` declared on the top-tier rule, the task-sections shape returned `ambiguous` in 3 of 3 runs, because the pick's probability was below its floor and no other option cleared its own floor.
Additionally declaring `min_confidence: 0.05` on the implementation rule returned a `fallback:` line to that rule in 3 of 3 runs.

Two scaffolded scout briefs (592 and 605 input tokens, sent with the `Brief kind: scout (report only)` line) matched the investigation rule at probability 1.0 in 4 of 4 runs.
A free-form brief with neither task section (561 input tokens, sent whole with no kind line) matched the trivial-edit rule at probability 1.0.

Negative finding: an intermediate variant that also sent `Brief kind: ship, mode=no-mistakes` moved the same routine port brief to the top-tier rule at probability 0.96 to 0.97 in 7 of 7 runs, above a 0.95 floor.
The delivery mode is the same on most ship briefs and says nothing about difficulty, so it is deliberately not sent.

These live runs cover the scout line, the free-form whole-brief fallback, the ship-brief package, the top-tier floor turning the pick `ambiguous`, and the fallback to a runner-up.
The remaining behavior is covered only by the offline tests below: a fenced heading inside a section, the boundaries of the global 0.6 confidence check with no declared floors, the probability-based floor examples, the tie case, and rejection of an out-of-range `min_confidence`.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
It proves firstmate can invoke the resolve path without a preflight, rules are snapshotted once from the isolated home's canonical `config/crew-dispatch.json`, and dynamic output fields are flattened to one line.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a `.env` key turns the tool on, and the environment wins over it.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the request uses the fixed endpoint and model, carries only the project, the brief's task sections read by the shared brief-heading parser with a scout line only for a scout brief and never a ship brief's delivery mode (or the whole brief when it has neither section), and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
It proves `OPENROUTER_API_KEY` alone routes to `https://openrouter.ai/api/alpha/decisions` with model `~typesafe/jev-latest`, that it is preferred over `TYPESAFE_API_KEY` whenever both are present at any source (environment or `.env`, in either combination), that the OpenRouter key is likewise absent from `curl` argv and reaches only the bearer header, and that an OpenRouter HTTP failure resolves to the same structured `error` outcome as the typesafe.ai path.
It proves a declared `min_confidence` is checked against the rule's own probability both as the pick and as a runner-up, a picked rule below it falls to the most probable runner-up that clears its floor, is `ambiguous` when none does or two tie, and that a file without declared floors keeps the global 0.6 floor on confidence unchanged.
It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, schema-6 account-row binding with schema-5 compatibility, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
`tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields without the typed key, validates each malformed shape when the environment or home `.env` activates typed resolution, and prevents an environment-provided key from reaching child processes.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live run needs a key and is not part of the suite; rerun the table above by pointing the tool at a brief with the key injected for that one command, and see "OpenRouter Decisions transport" above, which now records the 2026-09-26 live `OPENROUTER_API_KEY` run.
A future holder of a `TYPESAFE_API_KEY` should still repeat that same 25-brief set once against it, to get a direct side-by-side with the OpenRouter numbers above rather than only the hand labels.
