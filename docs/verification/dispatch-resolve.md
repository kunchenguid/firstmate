# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-dispatch-resolve.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when a decision provider, its API, or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in the private scout report.

## The API the tool depends on

Verified 2026-09-16 against `https://api.typesafe.ai`.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.
Observed end-to-end latency from a Mac was 123 to 348 ms per request, with the server's own upstream time at 4 to 60 ms.

OpenRouter's [Jev 1.13 model catalog entry](https://openrouter.ai/typesafe/jev-1.13) listed `typesafe/jev-1.13` at $0.042 per million input tokens and $0 per million output tokens on 2026-10-12.
OpenRouter's [Decisions API guide](https://openrouter.ai/blog/insights/what-is-jev/) specifies `POST https://openrouter.ai/api/alpha/decisions` with the same `{model, state, questions}` Choice request and typed Choice answer.

OpenAI's [Decisions API guide](https://developers.openai.com/api/docs/guides/decisions) on 2026-10-22 specified `POST /v1/decisions` with `{model, input, questions}`, where a `choice` question carries `name`, `instructions`, and `choices` of `{value, description}`, and named `gpt-6-luna` as the only supported model.
Its illustrative choice answer is an `answers` array entry with `type`, `name`, `choice`, `probabilities` as `{value, probability}` pairs, and `confidence`, plus a `refusal` answer type.
The live run below returned exactly that choice shape.

## Live provider checks

Each provider needs a dated section here with real request and response captures and a calibration note.

### `systemone` against Clef on Cloudflare Workers AI

Run 2026-10-23 (21:20 UTC) with `FM_DISPATCH_PROVIDER=systemone` and model `clef`, served by Cloudflare Workers AI as `@cf/cloudflare/clef`, resolver commit `8d01fe8d`, confidence floor 0.6, timeout 10 s.
Workers AI serves the System One shape at `POST /client/v4/accounts/<account>/ai/run/@cf/cloudflare/clef` inside a `{result, success, errors, messages}` envelope rather than at `/v1/systemone`, so the run reached it through a local test-only relay on `127.0.0.1`.
The relay forwarded each request body unchanged, added the Cloudflare bearer token itself, and returned the envelope's `result` verbatim; it renamed and filled in nothing, and the resolver accepted all 25 responses without adaptation.
The resolver ran with no dispatch key, so it sent no `Authorization` header; a post-run scan found neither the token, the account id, nor a bearer header in any captured file.
A direct Workers AI option (a configurable path plus envelope unwrapping in the resolver) is out of scope for this provider and not part of this change.
Rules, briefs, hand labels, and the constant quota snapshot are the same as the `openai` run below.

| Measure | Result |
| --- | --- |
| Top rule matched the hand label | 23 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 18 / 3 / 4 / 0 |
| Clear results with a profile other than the hand label | 0 |
| Resolver latency (min / median / max) | 151 / 281 / 513 ms |
| Workers AI round trip at the relay (min / median / max) | 137 / 266 / 498 ms |
| Input tokens per brief (min / median / max) | 397 / 419 / 443 |
| Output tokens | 0 on every response |
| HTTP errors and malformed answers | 0 / 0 |

The four escalations were the hardest-tier briefs, picked at confidence 0.86 to 0.94 and escalated by the rule's `approval: captain` as designed.
All three ambiguous results fell below the 0.6 floor, and two of them had a top pick other than the label, so the floor withheld both misses.
The on-call scheduling brief, labeled `default`, led with the trivial-edit rule at probability 0.67 and confidence 0.41.
The copywriting brief, labeled `default`, led with `default` at probability 0.30 and confidence 0.11.
The large-file-split brief, labeled routine work, led with the approval-gated hardest-tier rule at probability 0.48 and confidence 0.21; had it cleared the floor, that rule would still have escalated rather than dispatched.

Calibration note: Clef's `confidence` ran 0.02 to 0.27 below the top option's probability, with the widest gaps on the three ambiguous briefs, and every clear pick had confidence 0.81 or higher.
Compared with `gpt-6-luna` on the same set, Clef was less confident on the two no-rule briefs, which `gpt-6-luna` resolved to `default` and Clef handed back to firstmate, and it put the split brief's top pick on the hardest tier instead of routine work.
On this set the 0.6 floor admitted no wrong pick; 25 synthetic briefs are a smoke test of the provider path, not a basis for per-rule `min_confidence` values.

Request for the bug-fix brief, as the resolver sent it (the relay forwarded it unchanged):

```json
{
  "model": "clef",
  "state": {
    "task": {
      "project": "web-app",
      "brief": "## Captain's intent\nFix the pagination bug on the orders list: the last page repeats the first item of the previous page. Root cause: the offset is computed with <= instead of < in orders_query.go.\n\n## Firstmate spec\nChange the comparison, add a regression test for the last page, and do not refactor the query builder.\n"
    }
  },
  "questions": {
    "rule": {
      "type": "choice",
      "instructions": "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule's own matching condition; pick `default` when no rule's condition is met, including when a rule's own exemption text excludes this task.",
      "criteria": {
        "rule_1": "Work the brief itself calls unusually difficult or high-risk, such as a security-sensitive redesign or a migration where a mistake is costly; routine builds, ports, and installers do not qualify.",
        "rule_2": "Routine feature work, a port, or an installer build inside an existing codebase.",
        "rule_3": "A bug fix whose root cause the brief states.",
        "rule_4": "A trivial mechanical edit such as a rename, typo, version bump, or wording fix.",
        "rule_5": "A read-only investigation, diagnosis, or audit whose deliverable is a written report, not a code change.",
        "default": "No listed rule applies to this task."
      }
    }
  }
}
```

Workers AI response envelope, as received (HTTP 200, 137 ms at the relay, 145 ms end to end); the resolver received exactly the `result` object:

```json
{
  "result": {
    "model": "clef",
    "answers": {
      "rule": {
        "type": "choice",
        "choice": "rule_3",
        "probabilities": {
          "rule_1": 0.0018,
          "rule_2": 0.01,
          "rule_3": 0.9682,
          "rule_4": 0.0118,
          "rule_5": 0.0014,
          "default": 0.0068
        },
        "confidence": 0.9252
      }
    },
    "usage": {
      "input_tokens": 433,
      "output_tokens": 0
    }
  },
  "success": true,
  "errors": [],
  "messages": []
}
```

The resolver mapped it to `status: clear`, `rule: rule_3` at confidence 0.9252, and the rule's `cursor-grok-4.6-medium` profile.

### `openai` against the Decisions API

Run 2026-10-23 (17:18 UTC) against `https://api.openai.com/v1/decisions` with model `gpt-6-luna`, resolver commit `29d3d159`, confidence floor 0.6, timeout 10 s.
The key came only from `OPENAI_API_KEY` in the environment and reached `curl` only on file descriptor 3; a capturing `curl` wrapper recorded each request body, response headers, and response body, and a post-run scan found neither the key nor a bearer header in any captured file.
Quota came from one constant fake `quota-axi` snapshot, as in the 2026-09-17 run.

Rules: a generic five-rule file - an `approval: captain` hardest-tier rule that excludes routine builds, ports, and installers; routine feature, port, or installer work with one `all_models` floor; bug fixes with a stated root cause; trivial mechanical edits; and read-only investigations or audits - plus the shipped neutral none option.
Briefs: 25 synthetic briefs in the scaffold's task-section shape, hand-labeled before the run: four per rule, four of them scouts carrying the scout contract line, two that match no rule, and three borderline ones (a large file split, a rounding fix, and a routine signed Linux installer).
The 25 real and synthetic briefs of the Jev run are not reproduced here, so these runs compare with it in shape only.

| Measure | Result |
| --- | --- |
| Top rule matched the hand label | 25 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 20 / 1 / 4 / 0 |
| Clear results with a profile other than the hand label | 0 |
| Resolver latency (min / median / max) | 118 / 172 / 918 ms |
| Server `openai-processing-ms` (min / median / max) | 46 / 91 / 433 ms |
| Input tokens per brief (min / median / max) | 342 / 364 / 387 |
| Output tokens | 0 on every response |
| HTTP errors, refusals, malformed answers | 0 / 0 / 0 |

The four escalations were the hardest-tier briefs, each picked at 0.99 and escalated by the rule's `approval: captain` as designed.
The one `ambiguous` result was the large-file-split brief: `rule_2` led at probability 0.56 with `default` at 0.22, and confidence 0.47 fell below the 0.6 floor, so firstmate keeps that call, as with Jev's split fixture on 2026-09-23.
The first request was the slowest (918 ms with 344 ms on the server); every other request took at most 502 ms end to end.

Calibration note: across the 25 answers `confidence` ran 0.01 to 0.09 below the top option's probability, never above it.
Every pick at confidence 0.7 or higher matched its label; the lowest-confidence correct clear picks were a one-label copy change at 0.70 and a no-code copywriting brief resolved to `default` at 0.76.
On this set the 0.6 floor withheld one correct top pick and admitted no wrong one; 25 synthetic briefs cannot show overconfidence on genuinely hard calls, so per-rule `min_confidence` values for this provider should still come from a home's own briefs.
No answer was a refusal, so the refusal path is covered only by the offline tests.

The `usage` object carried `input_tokens`, `input_tokens_details` (`cached_tokens`, `cache_write_tokens`), `output_tokens`, `output_tokens_details.reasoning_tokens`, and `total_tokens`; the resolver keeps only the two numeric counts it displays.
Responses carried `x-request-id`, `openai-processing-ms`, `server-timing-total`, and `x-ratelimit-*` request and token headers.

Request for the bug-fix brief, as sent:

```json
{
  "model": "gpt-6-luna",
  "input": "{\"task\":{\"project\":\"web-app\",\"brief\":\"## Captain's intent\\nFix the pagination bug on the orders list: the last page repeats the first item of the previous page. Root cause: the offset is computed with <= instead of < in orders_query.go.\\n\\n## Firstmate spec\\nChange the comparison, add a regression test for the last page, and do not refactor the query builder.\\n\"}}",
  "questions": [
    {
      "type": "choice",
      "name": "rule",
      "instructions": "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule's own matching condition; pick `default` when no rule's condition is met, including when a rule's own exemption text excludes this task.",
      "choices": [
        { "value": "rule_1", "description": "Work the brief itself calls unusually difficult or high-risk, such as a security-sensitive redesign or a migration where a mistake is costly; routine builds, ports, and installers do not qualify." },
        { "value": "rule_2", "description": "Routine feature work, a port, or an installer build inside an existing codebase." },
        { "value": "rule_3", "description": "A bug fix whose root cause the brief states." },
        { "value": "rule_4", "description": "A trivial mechanical edit such as a rename, typo, version bump, or wording fix." },
        { "value": "rule_5", "description": "A read-only investigation, diagnosis, or audit whose deliverable is a written report, not a code change." },
        { "value": "default", "description": "No listed rule applies to this task." }
      ]
    }
  ]
}
```

Response, as received (HTTP 200, 169 ms end to end, 91 ms on the server):

```json
{
  "model": "gpt-6-luna",
  "answers": [
    {
      "type": "choice",
      "name": "rule",
      "choice": "rule_3",
      "probabilities": [
        { "value": "rule_1", "probability": 0.0 },
        { "value": "rule_2", "probability": 0.01 },
        { "value": "rule_3", "probability": 0.95 },
        { "value": "rule_4", "probability": 0.02 },
        { "value": "rule_5", "probability": 0.01 },
        { "value": "default", "probability": 0.01 }
      ],
      "confidence": 0.94
    }
  ],
  "usage": {
    "input_tokens": 379,
    "input_tokens_details": { "cached_tokens": 0, "cache_write_tokens": 0 },
    "output_tokens": 0,
    "output_tokens_details": { "reasoning_tokens": 0 },
    "total_tokens": 379
  }
}
```

The resolver mapped it to `status: clear`, `rule: rule_3` at confidence 0.94, and the rule's `cursor-grok-4.6-medium` profile.

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
It proves the default typesafe.ai request keeps its fixed endpoint and model, carries only the project, the brief's task sections read by the shared brief-heading parser with a scout line only for a scout brief and never a ship brief's delivery mode (or the whole brief when it has neither section), and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
It also proves OpenRouter requires an explicit provider and model, accepts the environment or `.env` key, sends the same Choice request to the Decisions API, preserves clear and ambiguous output, withholds a never-send match, and handles malformed responses and HTTP errors.
The fake `curl` and `quota-axi` prove that the OpenRouter key stays out of their argv and environments.
It proves that with no provider set, other providers' settings leave the original off line unchanged byte for byte, with no network or quota call.
It proves `systemone` posts the unchanged System One request to `<base>/v1/systemone`, sends no `Authorization` header and opens no descriptor without a key, carries a key only on the descriptor, reads its settings from `.env`, exits 2 for a missing model or a missing or scheme-less base URL, withholds a never-send base URL, and returns partial responses and transport failure as `error`.
It proves `openai` is off with one line without its key, exits 2 without a model, sends the same state as JSON text `input` with one named choice question carrying every option, maps the probability array back, withholds a never-send match inside the serialized input or the model name, and rejects refusals, missing or duplicated answers and option values, missing options or confidence, and non-JSON bodies before quota is read.
It proves a declared `min_confidence` is checked against the rule's own probability both as the pick and as a runner-up, a picked rule below it falls to the most probable runner-up that clears its floor, is `ambiguous` when none does or two tie, and that a file without declared floors keeps the global 0.6 floor on confidence unchanged.
It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, schema-6 account-row binding with schema-5 compatibility, `preferred_provider` family preference across accounts with fallback only on proven ineligibility and escalation on unknown preferred quota, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
`tests/fm-bootstrap.test.sh` covers bootstrap's typesafe-key validation gate, its key-independent `preferred_provider` check, and child-environment protection; [configuration](../configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns that gate's operator contract.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live run needs a key and is not part of the suite; rerun the table above by pointing the tool at a brief with the key injected for that one command.
