# Dispatch authentication verification

Audience: maintainer verification.

This record supports the dispatch judgment rules in `.agents/skills/quota-array-dispatch/SKILL.md` and the bounded vendor probe in `bin/fm-vendor-auth-probe.sh`.
It records only facts that must be re-established when a producer or vendor version changes.
Task chronology, incident transcripts, and credential metadata stay in private reports or PR evidence.

Firstmate resolves a candidate's provider family, credential surface, and applicable quota by reading the evidence below and reasoning in the open.
No script maps a model to a provider, a provider to a credential store, or a name prefix to a family, so the facts here are what that reasoning rests on.
Credential paths below are shown with the home directory replaced by `<home>`.

## Quota granularity the judgment depends on

Verified 2026-07-30 against quota-axi 0.1.16 for the provider and model-scope relationships below.
That release's captured default output included `quotaSemantics.description`; the current default TOON and JSON fallback field placement are verified against 0.1.29 in the next section.
Current dispatch reads the TOON scope and `limitedBy` fields; the JSON fallback's corresponding `scope` and `boundedBy` fields preserve the same provider/model applicability without relying on the `--full`-only description.

```json
{
  "provider": "codex",
  "state": { "status": "fresh", "stale": false },
  "quotaSemantics": {
    "status": "known",
    "description": "Codex base account windows bound every model. Named model windows add bounds for that model; code-review windows describe a separate workload and are not included in model availability.",
    "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly"] },
      { "scope": "model:codex_bengalfox", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly", "model:codex_bengalfox:7d"] }
    ]
  }
}
```

Three properties follow and are load-bearing for dispatch:

- An `all_models` (or `all_products`) scope is real evidence for every model in that provider family, including a model with no window of its own.
- A `model:`-scoped entry is an additional bound for that one model. `model:codex_bengalfox` is the GPT-5.3-Codex-Spark window and bounds nothing else.
- A named-model window can be tighter than the account bound, so it must not be read across models. In the same snapshot Claude reported `all_models` with `effectivePercentRemaining` 10 while `model:fable` reported 4, limited by the `model:fable` window itself. A non-Fable Claude model reads 10, not 4.

`quotaSemantics.status` is `unknown` with no `effectiveAvailability` entries at all for providers whose vendor exposes no window (observed for `cursor` and `copilot`).
`state.authStatus` is present only for some providers (observed for `grok` alone), so its absence is missing evidence, not a credential fault.

## Completion-runway and selection shape the judgment depends on

Verified 2026-08-18 against quota-axi 0.1.29 schema 5, captured from an isolated `quota-axi@0.1.29` install.
The default TOON exposed these table headers, with row counts normalized to `N`:

```text
quota[N]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
exhaustion[N]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
attention[N]{provider,scope,kind,detail,remedy}:
```

`exhaustion[]` and `attention[]` are sparse, so an empty table is rendered with count zero and no row fields.
The command below records the JSON fallback shape without persisting account-specific quota values:

```sh
quota-axi --json | jq '{schemaVersion, effectiveAvailabilityFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]? | keys] | unique), runwayFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.runway? | select(type == "object") | keys] | unique), selectionFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.selection? | select(type == "object") | keys] | unique), paceFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.pace? | select(type == "object") | keys] | unique), windowPaceFields: ([.providers[]?.windows[]?.pace? | select(type == "object") | keys] | unique)}'
```

```json
{
  "schemaVersion": 5,
  "effectiveAvailabilityFields": [
    [
      "boundedBy",
      "effectivePercentRemaining",
      "limitingWindowIds",
      "pace",
      "runway",
      "scope",
      "selection",
      "status"
    ]
  ],
  "runwayFields": [
    [
      "projectionConfidence",
      "status"
    ]
  ],
  "selectionFields": [
    [
      "spendPriority",
      "status"
    ]
  ],
  "paceFields": [
    [
      "status",
      "worstReservePercentPoints",
      "worstReserveWindowId"
    ]
  ],
  "windowPaceFields": [
    [
      "burnMultiple",
      "reservePercentPoints",
      "status"
    ]
  ]
}
```

This live snapshot was all `through_reset`, so finite-runway fields were omitted.
`usableRunwaySeconds`, `projectedExhaustedAt`, and `limitingWindowId` remain in default `--json` when `runway.status` is `projected_exhaustion` or `exhausted_now`.
`selection.unmeasurableWindowIds`, scope `aheadWindowIds`/`unknownWindowIds`, and window `pace.reason` likewise remain in default `--json` when they apply.
`quotaSemantics.description`, `behindWindowIds`, `onPaceWindowIds`, and per-window cycle-progress internals are `--full` only.
There is no `projectionBasis` field; its absence means `cycle_average`.
`runway` and `selection` are nested under each effective-availability scope, so the same provider/model applicability rules govern headroom, runway, and `spendPriority`.
Projection confidence is not present on every known runway, so selection must preserve that absence as uncertainty rather than fabricate it.
The older-schema fallback contract is owned by `quota-array-dispatch`; this evidence does not reinterpret an absent runway, pace, or selection field.

## Provider-family counterfactual that this producer schema supports

Verified 2026-07-30 on Pi 0.82.0 and quota-axi 0.1.16.

```sh
pi --list-models terra
```

```text
provider      model          context  max-out  thinking  images
openai-codex  gpt-5.6-terra  272K     128K     yes       yes
```

The Pi catalog is authoritative for Pi model support and reports the provider family in its own column.
For `harness=pi`, `model=openai-codex/gpt-5.6-terra` the catalog establishes the model is supported and belongs to the `openai-codex` family, and the Codex `all_models` scope above supplies fresh, known 64 effective remaining for every model in that family.
No Terra-specific window exists in the snapshot, and `quota-axi auth --json` lists no `pi:openai-codex` source.
Both absences are missing model-level and source-level detail, not contradictory evidence, so this candidate is dispatchable with the model-level uncertainty disclosed.

```sh
pi --list-models gpt-9.9-nonexistent
```

```text
No models matching "gpt-9.9-nonexistent"
```

A listing that reaches the account and returns no row is the authoritative negative that does block a candidate.

## Credential sources are independent per provider

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi auth --json` reports each provider's credential sources separately, which is what lets a candidate be scoped to the one surface it actually authenticates through:

```json
[
  { "provider": "claude", "sources": [
      { "source": "oauth-file", "path": "<home>/.claude/.credentials.json", "status": "missing" },
      { "source": "keychain", "status": "available" } ] },
  { "provider": "codex", "sources": [
      { "source": "auth-json", "path": "<home>/.codex/auth.json", "status": "available" },
      { "source": "cli-rpc", "path": "<path-to>/codex", "status": "available" } ] },
  { "provider": "grok", "sources": [
      { "source": "auth-json", "path": "<home>/.grok/auth.json", "status": "available" },
      { "source": "pi:xai", "status": "available" } ] },
  { "provider": "kimi", "sources": [
      { "source": "pi:kimi-coding", "status": "available" },
      { "source": "kimi-code-cli", "status": "expired", "error": "kimi_code_cli_credential_expired" } ] }
]
```

Observed source statuses are `available`, `expired` (with an `error` slug), and `missing`.

- A provider can carry a healthy source beside a missing or expired one, so a provider must not be collapsed to a single status. Claude's `oauth-file` is missing while its keychain source is available, and Kimi's standalone CLI credential is expired while its Pi source is available.
- A `pi:`-prefixed source exists only where Pi holds its own credential for that family (`pi:xai`, `pi:kimi-coding`). Pi's `openai-codex` family has none, because it authenticates through the Codex store that the `codex` provider already lists. A missing `pi:` source is therefore never evidence against a Pi candidate.

Neither this per-source shape nor `state.authStatus` exists before quota-axi 0.1.16.
`bin/fm-bootstrap.sh` enforces the current compatibility floor through `bin/fm-quota-axi-lib.sh`.

Grok also reports `credits.remaining: 0` alongside `percentRemaining: 41` on a healthy account.
That zero is a prepaid balance, not the subscription window, and is never headroom.

## Standalone Grok discovery probe

Verified 2026-07-30 on `grok 0.2.117 (f1c06093089f) [stable]`.

```sh
grok --version
grok models   # stdin closed, single attempt, hard-bounded
```

Observed:

- `grok models` exits `0` and its first stdout line is `You are logged in with grok.com.` for an authenticated session.
- With a home directory holding no Grok credential, the first stdout line is `You are not authenticated.`, also with exit status `0`.
- Because the status is `0` in both cases, the exit status is not a verdict; only the literal first stdout line is examined, and a blank first line does not authenticate.
- `<home>/.grok/auth.json` was byte-identical across the authenticated run (`mtime`, `size`, and mode `0600` unchanged), so the probe is a read in that path.

These discriminator strings are un-owned vendor UI text.
`bin/fm-vendor-auth-probe.sh` pins the verified version, reports `versionVerified=no` when the running CLI differs, and classifies any unrecognized first line as `indeterminate` rather than authenticated.
Re-run the two commands above and update this section and the pinned version together when the vendor CLI changes.

## Regression coverage

`tests/fm-vendor-auth-probe.test.sh` drives the real script against a fake vendor CLI that records every invocation's argv and anything readable on stdin.
It asserts that the script accepts no harness, model, or provider input, never calls `quota-axi`, exits alike for every probe result because it renders no verdict, invokes only the two fixed non-destructive argv forms with stdin closed, holds a real bound even when the configured bound is zero or malformed, and never echoes raw vendor output.
`tests/fm-spawn-dispatch-profile.test.sh` owns spawn's deterministic profile and harness refusals.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic.
`tests/fm-quota-array-dispatch-live-e2e.test.sh` drives the public Pi skill-loading interface against one fake schema-5 snapshot per case, served as quota-axi's default TOON.
It covers TOON-first `spendPriority` ranking among candidates that pass eligibility, reasoning-class, and runway-feasibility gates, explicit accounting for unmeasurable runway, the strongest-reasoning constraint, and the runway feasibility floor over a higher `spendPriority`.
The skill's primary path is that default TOON; `--json` is the documented defensive fallback, and this section records the producer `--json` shape that fallback consumes.
