# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the optional `bin/fm-dispatch-resolve.sh` providers owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when the selected System One API or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in the private scout report.

## The API the tool depends on

Verified 2026-09-16 against `https://api.typesafe.ai`.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.
Observed end-to-end latency from a Mac was 123 to 348 ms per request, with the server's own upstream time at 4 to 60 ms.

## Canonical Laya compatibility surface

Audited 2026-09-28 against the canonical `NandhaKishorM/laya` repository and release tag `v0.3.21`.
`gh-axi api /repos/NandhaKishorM/laya/releases/latest --jq '{tag_name, published_at, html_url}'` returned `v0.3.21`, published `2026-09-27T19:41:23Z`, at `https://github.com/NandhaKishorM/laya/releases/tag/v0.3.21`.
`gh-axi api /repos/NandhaKishorM/laya/git/ref/tags/v0.3.21 --jq '.object.sha, .object.type'` returned tag object `6ab71fb4ce6bfd6f189e9b689eaadd67103ed9b6` of type `tag`.
`gh-axi api /repos/NandhaKishorM/laya/git/tags/6ab71fb4ce6bfd6f189e9b689eaadd67103ed9b6 --jq '.object.sha, .object.type'` returned release commit `9d955671415fc19f069b9cc998928075c1f255ec` of type `commit`.
`gh-axi api /repos/NandhaKishorM/laya/contents/pyproject.toml?ref=v0.3.21 --header 'Accept: application/vnd.github.raw+json' --full` confirmed package version `0.3.21`, the optional `serve` extra with FastAPI and Uvicorn, and the `laya-serve` entry point.
`gh-axi api /repos/NandhaKishorM/laya/contents/laya/serve.py?ref=v0.3.21 --header 'Accept: application/vnd.github.raw+json' --full` confirmed that the canonical HTTP server exposes `POST /v1/systemone` using Jev-compatible answer and usage shapes, with optional `LAYA_API_KEY` bearer authentication.
The same source ignores unknown Jev model IDs and lets the Router select a checkpoint, and documents a default bind of `0.0.0.0:8000`.
The retained [PR #6473 functional validation](https://github.com/kunchenguid/firstmate/pull/6473) additionally records canonical Laya v0.3.21 inference with and without bearer authentication, home-provider activation, resolver safety boundaries, and bootstrap activation.
Its resolver outputs include an ambiguous result below the default confidence floor and a clear configured medium-effort profile above a declared probability floor.
Controlled responses and quota fixtures exercised adverse boundaries; these functional scenarios are not a Firstmate dispatch-quality or latency benchmark, both of which remain unmeasured.

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
Offline tests cover the other brief-selection behaviors: a fenced heading inside a section, the boundaries of the global 0.6 confidence check with no declared floors, the probability-based floor examples, the tie case, and rejection of an out-of-range `min_confidence`.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
The shared TypeSafe helpers pin `DISPATCH_SYSTEMONE_PROVIDER=typesafe` and clear the Laya settings; separate provider cases exercise Laya selection from the environment and home `.env`, endpoint and timeout selection, optional bearer authentication, secret isolation, origin rejection, and explicit empty overrides.
A real-curl loopback fixture proves authenticated and unauthenticated Laya requests bypass inherited proxies for localhost and 127.0.0.1.
It proves firstmate can invoke the resolve path without a preflight, rules are snapshotted once from the isolated home's canonical `config/crew-dispatch.json`, and dynamic output fields are flattened to one line.
It proves the TypeSafe provider's absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a TypeSafe `.env` key turns the tool on, and the environment wins over it.
It proves the TypeSafe key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the TypeSafe request uses its fixed endpoint and Jev model, carries only the project, the brief's task sections read by the shared brief-heading parser with a scout line only for a scout brief and never a ship brief's delivery mode (or the whole brief when it has neither section), and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
It proves a declared `min_confidence` is checked against the rule's own probability both as the pick and as a runner-up, a picked rule below it falls to the most probable runner-up that clears its floor, is `ambiguous` when none does or two tie, and that a file without declared floors keeps the global 0.6 floor on confidence unchanged.
It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, schema-6 account-row binding with schema-5 compatibility, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
`tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields with TypeSafe explicitly selected and no key, validates each malformed shape when a TypeSafe key is supplied by the environment or home `.env`, and prevents that key from reaching child processes.
It also proves environment and home Laya selection activate typed validation without a TypeSafe key, while explicit empty provider and TypeSafe-key overrides disable the corresponding home activation.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live TypeSafe run needs a key and is not part of the suite; rerun the table above by pointing the tool at a brief with the TypeSafe key injected for that one command.
