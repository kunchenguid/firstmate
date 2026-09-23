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
A lean request that asked only the rule Choice matched the full request (rule, profile, and status) on all 25 briefs, so rule matching remains one question with every gate in code.
The shipped tool now also asks the effort Choice in that same request.
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

## Margin gate and rule precedence calibration

Run 2026-09-22 on the TypeSafe route, model `jev-latest`, compact intent state, with the home's 13-rule file (14 options with the neutral none option), 56 live requests in total.
The labeled set is 14 real briefs from the firstmate home, screened for private personal data, each labeled with the rule or rules a supervisor would accept; 6 predate the captain's-intent brief section and are sent as the first 800 characters of the whole brief.
Every live row came from `bin/fm-dispatch-replay.sh run --cases <cases> --out <jsonl> --max-calls 14 --rules <candidate>`, once with the home's rules unchanged and three times with candidate `beats`, and every table below from `bin/fm-dispatch-replay.sh score --margin <list> <jsonl>...`.

Home rules unchanged, 14 rows:

```console
  gate: confidence>=0.6 ambiguous=9 pass=5 wrong=0
  gate: margin>=0.25 ambiguous=4 pass=10 wrong=1
  gate: margin>=0.3 ambiguous=4 pass=10 wrong=1
  gate: margin>=0.4 ambiguous=6 pass=8 wrong=0
```

The one wrong pick at every margin below 0.4 is a short build brief answered with the none option at margin 0.35 and derived confidence 0.59.

The three `beats` variants pooled, 42 rows:

```console
  gate: confidence>=0.6 ambiguous=15 pass=27 wrong=0
  gate: margin>=0.15 ambiguous=5 pass=37 wrong=2
  gate: margin>=0.2 ambiguous=8 pass=34 wrong=1
  gate: margin>=0.25 ambiguous=9 pass=33 wrong=0
  gate: margin>=0.3 ambiguous=12 pass=30 wrong=0
```

0.4 is the lowest tested threshold with no wrong pick under unchanged rules, which is why it is the default.
0.25 is the lowest threshold with no wrong pick across the pooled precedence rows, so it becomes valid only once `beats` are applied and a replay re-verifies it at `wrong=0`.
The best variant, the conditional `beats` proposed for rules 8 through 13, measured 2 of 14 ambiguous at 0.25 with no wrong pick; both remaining rows are short German briefs split between a rule and the none option.
Margins moved by up to 0.17 between variants on a brief whose contested pair neither variant's `beats` named, so one run per brief cannot certify a threshold finer than that.

The 41-row shadow history recorded under the home rules, scored without a network call:

```console
$ bin/fm-dispatch-replay.sh score --margin 0.25,0.3,0.45 state/jev-dispatch-shadow.jsonl
replay-score: rows=41 labeled=0 skipped=0
  gate: confidence>=0.6 ambiguous=18 pass=23 wrong=0
  gate: margin>=0.25 ambiguous=11 pass=30 wrong=0
  gate: margin>=0.3 ambiguous=12 pass=29 wrong=0
  gate: margin>=0.45 ambiguous=15 pass=26 wrong=0
```

The history carries no brief identity, so it measures the ambiguous rate only; the gate changes no pick, since the clear rule is always the most probable option.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
It proves firstmate can invoke the resolve path without a preflight, rules are snapshotted once from the isolated home's canonical `config/crew-dispatch.json`, and dynamic output fields are flattened to one line.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a `.env` key turns the tool on, and the environment wins over it.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the request uses the default TypeSafe endpoint, model, and 25-second timeout, that `JEV_URL` is used verbatim without appending `/v1/systemone`, and that model, URL, and timeout overrides come from the environment or `.env`.
It proves the request carries the project, brief, the rule Choice with one option per rule plus the fixed neutral none option, and the effort Choice, and never carries `why`, `use`, or quota.
It proves the clear, margin-gated ambiguous with candidate evidence (inclusive threshold, a low derived confidence still clearing on a wide margin, `FM_JEV_DISPATCH_MARGIN` from the environment then `.env`, and invalid values refused before any request), a returned rule choice below the probability leader remaining ambiguous with candidate evidence and no profile line, `beats` tie-break sentences on both options with an unchanged question when no rule declares them, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
It proves malformed `beats` (empty, out of range, self, fractional, duplicate target, empty `when`, unconditional mutual, and cycles of three or more rules including conditional edges) exit 2 before any request, while conditional pairs and non-cyclic chains remain accepted.
`tests/fm-dispatch-replay.test.sh` drives the replay harness through the real resolver with a queued fake transport: one call per case, a hard budget that stops before the call that would exceed it, candidate rules that leave the home's rules unchanged, output alias and writability checks before live requests, and resolver failure and opt-out propagation; it also proves the resolver's shadow log is forced off and the offline score compares both gates and counts wrong labeled picks.
`tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields without the typed key, validates each malformed shape when the environment or home `.env` activates typed resolution, and prevents an environment-provided key from reaching child processes.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live run needs a key and is not part of the suite; rerun the table above by pointing the tool at a brief with the key injected for that one command.
