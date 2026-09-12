# Dispatch authentication verification

Audience: maintainer verification.

This record supports the dispatch judgment rules in `.agents/skills/quota-array-dispatch/SKILL.md`, the bounded vendor probe in `bin/fm-vendor-auth-probe.sh`, and the account-pin check in `bin/fm-account-pin-lib.sh`.
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

## Account-pin preflight

Verified on 2026-09-10 with Pi 0.85.1 and quota-axi 0.1.30 on macOS, against throwaway roots holding no real credential.
`bin/fm-account-pin-lib.sh` refuses a spawn unless the runner's own check says the pinned root can authenticate, and these are the answers it reads.
The keyed Pi root holds `{"anthropic":{"type":"api_key","key":"<fake>"}}` in `auth.json`, and the filed Claude root holds a `.credentials.json` whose `claudeAiOauth.expiresAt` is one day ahead.

```sh
env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR=<empty> pi auth check --provider anthropic --json --no-refresh
env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR=<keyed> pi auth check --provider anthropic --json --no-refresh
env -i HOME="$HOME" PATH="$PATH" ANTHROPIC_API_KEY=<fake> PI_CODING_AGENT_DIR=<empty> pi auth check --provider anthropic --json --no-refresh
env -i HOME="$HOME" PATH="$PATH" CLAUDE_CONFIG_DIR=<empty> quota-axi auth --json --provider claude | jq -c '[.auth[].sources[] | {source,status}]'
env -i HOME="$HOME" PATH="$PATH" CLAUDE_CONFIG_DIR=<filed> quota-axi auth --json --provider claude | jq -c '[.auth[].sources[] | {source,status}]'
```

```text
{"status":"not_ready","provider":"anthropic","reason":"credentials_not_configured"}
{"status":"ready","provider":"anthropic","authType":"api_key"}
{"status":"ready","provider":"anthropic","authType":"api_key"}
[{"source":"oauth-file","status":"missing"},{"source":"keychain","status":"missing"}]
[{"source":"oauth-file","status":"available"},{"source":"keychain","status":"missing"}]
```

The three Pi checks exited 1, 0, and 0.
Against a real logged-in root, the same check answered `{"status":"invalid","provider":"codex-native/gpt-6-astra","reason":"invalid_state"}` for `--model codex-native/gpt-6-astra` and `{"status":"not_ready","provider":"codex-native","reason":"provider_not_found"}` for `--provider codex-native`, because `pi auth check` does not load the `pi-codex-native` extension that registers that provider; the library therefore skips the check for that provider.
The third answer is why the check runs with a scrubbed environment: Pi counts `ANTHROPIC_API_KEY` as a ready credential for a root that holds none.
Against real logged-in roots, each check answered in under one second.
`tests/fm-account-pin-preflight-live-e2e.test.sh` re-runs these checks through the library on any host with pi, quota-axi, and jq, and fails naming the version whose answer changed.

### quota-axi keychain reporting on 0.1.41

Observed on 2026-09-11 with quota-axi 0.1.41 on macOS.
The `keychain` answers recorded above were taken on 0.1.30 and no longer hold, so the Claude half of the live guard fails on this version.
A root with a real login still answers determinately: one account root reports `{"source":"keychain","status":"available"}` and another `{"source":"keychain","status":"expired"}`.
Two other roots answer `{"source":"keychain","status":"skipped","error":"keychain_prompt_required","credentialPresent":true}` and `{"source":"keychain","status":"skipped","error":"keychain_presence_check_failed","credentialPresent":true}`.
A throwaway root holding nothing at all gets that same `keychain_presence_check_failed` answer, so on this version `credentialPresent` is not evidence when the presence check did not complete, and an empty Claude root passes the preflight.
The library's Claude branch is deliberately unchanged: the two cases are indistinguishable in this output, so tightening the rule would also refuse a root whose only credential lives in the keychain.
What should count as ready when the presence check cannot run is its own call.

### Extension-registered Pi providers

Verified on 2026-09-11 with Pi 0.85.1 on macOS.
An extension can register a second ChatGPT login under its own provider id; `pi-codex-accounts` 0.1.1 does it from `<root>/codex-accounts.json`.
`pi auth check` loads no extensions, so it cannot answer for such a provider at all, which is why the preflight needs a second reading for exactly one answer.
Every command below ran under `env -i HOME=... PATH=... TMPDIR=... PI_CODING_AGENT_DIR=...`, the same scrubbed environment the preflight uses.

```sh
pi auth check --provider openai-codex-work --json --no-refresh   # root registering that provider, logged in
pi auth check --provider openai-codex      --json --no-refresh   # built-in provider, logged in
pi auth check --provider openai-codex      --json --no-refresh   # same root minus auth.json
pi auth check --model    openai-codex-work/gpt-6-astra --json --no-refresh
pi auth check --model    openai-codex/nonexistent-model --json --no-refresh
```

```text
{"status":"not_ready","provider":"openai-codex-work","reason":"provider_not_found"}
{"status":"ready","provider":"openai-codex","authType":"oauth"}
{"status":"not_ready","provider":"openai-codex","reason":"credentials_not_configured"}
{"status":"invalid","provider":"openai-codex-work/gpt-6-astra","reason":"invalid_state"}
{"status":"ready","provider":"openai-codex","authType":"oauth"}
```

Three facts the preflight rests on, in order.
A logged-out provider Pi does know answers `credentials_not_configured`, not `provider_not_found`, so only a provider Pi cannot see at all reaches the second reading.
The `--model` form is no stronger than the `--provider` form - it answered `ready` for a model id that does not exist - and it rejects an extension provider's model outright, so the preflight resolves the provider itself and asks with `--provider`.

`pi --list-models` does load extensions, and it is the second reading:

```sh
pi --list-models openai-codex-work            # root registering that provider, logged in
pi --list-models openai-codex-work            # same root minus auth.json
pi --list-models definitely-not-a-provider
pi --list-models openai-codex                 # logged in
```

```text
provider           model                context  max-out  thinking  images
openai-codex-work  gpt-5.3-codex-spark  128K     128K     yes       no
... 8 rows, all with provider column "openai-codex-work"

No models matching "openai-codex-work"

No models matching "definitely-not-a-provider"

provider           model                context  max-out  thinking  images
openai-codex       gpt-5.3-codex-spark  128K     128K     yes       no
... 16 rows: 8 for "openai-codex" and 8 for "openai-codex-work"
```

All four exited 0, so the exit status carries no verdict and the rows are the answer.
Removing the root's `auth.json` is what makes the provider's rows disappear, which is why a listing is read as evidence of a usable login rather than of a registered provider.
The search is fuzzy and matches across providers - `openai-codex` returned `openai-codex-work` rows too - so the preflight compares the provider and model columns exactly and skips the header row.
`pi --list-models <provider>/<id>` also works and returns that single row, but the preflight searches by provider so a `:<thinking>` suffix on a model pattern cannot change what is searched.
Under a directory it cannot write, `pi` exits 1 with an `EACCES` trace rather than an empty listing, and the preflight's bound and non-zero handling both refuse.

The limit worth stating: this reading proves the provider is registered and can serve the model in this root, not that a credential sits in the root's `auth.json`.
`pi-cursor-sdk`'s `cursor` provider lists its models with no entry in the root's `auth.json` at all, because it bridges a login the Cursor CLI holds elsewhere.
That is still a usable login, and no stronger check exists for a provider `pi auth check` cannot see, but an extension that registered a static catalog with no credential behind it would list models the launch could not use.
The work/personal side guard, not this reading, is what decides which account a launch may spend.

## Regression coverage

`tests/fm-vendor-auth-probe.test.sh` drives the real script against a fake vendor CLI that records every invocation's argv and anything readable on stdin.
It asserts that the script accepts no harness, model, or provider input, never calls `quota-axi`, exits alike for every probe result because it renders no verdict, invokes only the two fixed non-destructive argv forms with stdin closed, holds a real bound even when the configured bound is zero or malformed, and never echoes raw vendor output.
`tests/fm-spawn-dispatch-profile.test.sh` owns spawn's deterministic profile, harness, and account-pin refusals, including a caller key that must not vouch for an unauthenticated pin, and the Claude launch's credential shed.
`tests/fm-quota-snapshot.test.sh` owns the per-pin quota read, and `tests/fm-quota-choose.test.sh` owns the helper's refusal to rank across pins.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic.
`tests/fm-quota-array-dispatch-live-e2e.test.sh` drives the public Pi skill-loading interface against one fake schema-5 snapshot per case, served as quota-axi's default TOON.
It covers TOON-first `spendPriority` ranking among candidates that pass eligibility, reasoning-class, and runway-feasibility gates, explicit accounting for unmeasurable runway, the strongest-reasoning constraint, and the runway feasibility floor over a higher `spendPriority`.
The skill's primary path is that default TOON; `--json` is the documented defensive fallback, and this section records the producer `--json` shape that fallback consumes.
