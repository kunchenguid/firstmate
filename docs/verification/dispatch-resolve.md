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

## Live rule match against real briefs (one-question request)

Both tables below were produced by the earlier request that asked only the rule Choice.
They remain the record for rule-match accuracy; the shipped request also carries the router axes and is measured in its own section, "Live router-axis run (shipped request shape)".

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
A lean request that asks only the rule Choice matched the full request (rule, profile, and status) on all 25 briefs.
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

## Live router-axis run (shipped request shape)

Run 2026-09-19 with the key read from the home `.env` for the run, model `jev-latest`, a fake `quota-axi` holding one snapshot constant, and the shipped request: the rule Choice plus the six router axes (`intent`, `domain`, `difficulty`, `risk`, `model_class`, `escalation`).
Briefs: one short bug-fix brief and two documentation excerpts of 6 KB and 18 KB, chosen to span the input range the earlier runs recorded.

| Measure | Result |
| --- | --- |
| Calls | 40 |
| Outcomes: clear / ambiguous / escalate / error | 40 / 0 / 0 / 0 |
| Wall time per call including jq (min / median / p90 / max) | 637 / 710 / 903 / 930 ms |
| Input tokens per brief (short / medium / long) | 1,412 / 2,649 / 5,207 |
| Output tokens | 386 to 387 |
| API errors | 0 |

Output tokens rose from 60-62 on the one-question request to 386-387 here, and the slowest of the 40 calls was 930 ms.
The one outlier the 2026-09-17 table recorded was 8.2 times that run's median; applied to this run's 710 ms median that projects a worst case near 5.8 s, above the 5 s `--max-time` the tool used before this run, so the timeout is now 10 seconds: above the projected outlier with margin, and still an order of magnitude below the intake turn the tool replaces.

Per-axis confidence on six of those calls, showing why the evidence-only axes do not gate the route:

| Brief | rule | intent | domain | difficulty | risk | model_class | escalation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| short | 1.00 | 0.86 | 0.43 | 1.00 | 0.93 | 0.68 | 1.00 |
| short | 1.00 | 0.83 | 0.53 | 1.00 | 0.94 | 0.76 | 1.00 |
| medium | 0.94 | 0.36 | 0.79 | 0.53 | 0.12 | 0.41 | 0.80 |
| medium | 0.92 | 0.41 | 0.75 | 0.46 | 0.11 | 0.41 | 0.82 |
| long | 0.90 | 0.22 | 0.81 | 0.29 | 0.61 | 0.45 | 0.52 |
| long | 0.89 | 0.30 | 0.78 | 0.29 | 0.62 | 0.44 | 0.55 |

The rule answer stayed at 0.89 or above on every one, while at least one evidence-only axis sat below 0.6 on all six: a 0.6 floor across the axes would have turned every one of these confident rule matches into `ambiguous`, which is why classifier confidence is published beside the route and never gates it.
Escalation confidence itself reached only 0.52 and 0.55 on the two long briefs, which is why the escalation gate clears the same 0.6 floor the rule answer does: a near-coin-flip `yes` in that regime is published as evidence rather than spending the intake the tool exists to save, while every declared local gate still escalates on its own authority at any classifier confidence.
The same run also answered `risk: sensitive` at 0.12 and 0.60 confidence on the two documentation briefs while answering `escalation: no` on both, so reading the risk label as a second escalation trigger would have stopped two routine dispatches on a judgment the dedicated axis contradicted; risk stays evidence and `escalation` is the only classifier axis that gates.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
It proves firstmate can invoke the resolve path without a preflight, rules are snapshotted once from the isolated home's canonical `config/crew-dispatch.json`, and dynamic output fields are flattened to one line.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a `.env` key turns the tool on, and the environment wins over it.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the request uses the fixed endpoint and model, carries only the project, brief, rule Choice with one option per rule plus the fixed neutral none option, and the fixed router classifier axes, and never carries `why`, `use`, or quota.
It proves the classifier evidence line is emitted, low confidence on an evidence-only axis still resolves to the matched profile, a `sensitive` risk classification alone does not stop dispatch, an `escalation` answer of `yes` above the floor returns `escalate` with no `profile:` line while one below the floor stays evidence and still resolves a profile, a declared captain-approval gate is reported ahead of that classifier recommendation at any classifier confidence, and a classifier choice outside its offered options, like a missing classifier axis, is an `error` outcome rather than a silently ignored escalation.
It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, classifier escalation, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
`tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields without the typed key, validates each malformed shape when the environment or home `.env` activates typed resolution, and prevents an environment-provided key from reaching child processes.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live run needs a key and is not part of the suite; rerun the table above by pointing the tool at a brief with the key injected for that one command.
