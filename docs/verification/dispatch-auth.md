# Dispatch authentication verification

Audience: maintainer verification.

This record supports the dispatch judgment rules in `.agents/skills/quota-array-dispatch/SKILL.md` and the bounded vendor probe in `bin/fm-vendor-auth-probe.sh`.
It records only facts that must be re-established when a producer or vendor version changes.
Task chronology, incident transcripts, and credential metadata stay in private reports or PR evidence.

Firstmate resolves a candidate's provider family, credential surface, and applicable quota by reading the evidence below and reasoning in the open.
The [worker helper](../../bin/fm-quota-choose.sh) and [typed resolver](../configuration.md#typed-dispatch-resolution-env-typesafe_api_key) document their deterministic mapping boundaries; the [eligibility procedure](../../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility) owns the remaining catalog and credential judgments.
Credential paths below are shown with the home directory replaced by `<home>`.

## Quota granularity the judgment depends on

Verified 2026-07-30 against quota-axi 0.1.16 for the provider and model-scope relationships below.
That release's captured default output included `quotaSemantics.description`; the schema-5 default TOON and JSON fallback field placement are verified against 0.1.29 in the next section.
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

The [eligibility procedure](../../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility) owns account and scope applicability; this capture illustrates those scope bounds:

- The captured Codex account reports an `all_models` bound of 64% even for models without their own window.
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
The schema compatibility and account-matching contract is owned by [`quota-array-dispatch`](../../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility); this schema-5 evidence does not reinterpret an absent runway, pace, or selection field.

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
In this capture, the catalog lists `openai-codex/gpt-5.6-terra`, and the Codex row above reports 64% remaining at `all_models`.
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
- In this captured setup, only `pi:xai` and `pi:kimi-coding` have `pi:`-prefixed sources.
  The Pi `openai-codex` candidate used the Codex store listed above; this observation does not establish the credential source for another account or setup.
  The [eligibility procedure](../../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility) owns how missing authentication evidence affects dispatch.

Neither this per-source shape nor `state.authStatus` exists before quota-axi 0.1.16.
`bin/fm-bootstrap.sh` enforces the current compatibility floor through `bin/fm-quota-axi-lib.sh`.

Grok also reports `credits.remaining: 0` alongside `percentRemaining: 41` on a healthy account.
That zero is a prepaid balance, not the subscription window, and is never headroom.

## Claude Code auth probe

Verified 2026-09-20 on Claude Code 2.1.276, on Linux.

```sh
claude --version
claude auth status   # stdin closed, single attempt, hard-bounded
```

`claude --version` prints the semver at the start of its only line, with no leading command name:

```
2.1.276 (Claude Code)
```

`claude auth status` prints a JSON document. With a usable Claude session (exit 0):

```
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  ...
}
```

With no usable session in the scoped `CLAUDE_CONFIG_DIR` and keychain context (exit 1):

```
{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty",
  ...
}
```

Observed:

- The `loggedIn` member alone discriminates; `authMethod` is `claude.ai` for a logged-in claude.ai session and `none` otherwise, and neither value is read.
- The elided members carry the account email, org id, and store paths, so `bin/fm-vendor-auth-probe.sh` classifies the document and never prints, logs, or forwards any of it.
- The probe strips whitespace before matching `"loggedIn":true` / `"loggedIn":false`, so the discriminator survives a change in the vendor's indentation; any unrecognized document is `indeterminate`, never authenticated.
- The exit status tracks the verdict here (0 logged in, 1 not), and is still never read as one, per this file's standing rule.
- The probe is run with the caller-selected `CLAUDE_CONFIG_DIR` in the environment, so named Claude profile pools can be checked without printing token values or launching the interactive TUI.

This JSON shape is un-owned vendor output.
`bin/fm-vendor-auth-probe.sh` pins the verified version, reports `versionVerified=no` when the running CLI differs, and classifies unrecognized output as `indeterminate` rather than authenticated.
Re-run the two commands above and update this section and the pinned version together when the vendor CLI changes.

### Account separation by CLAUDE_CONFIG_DIR

Verified on Linux only, on the same date and version.
The probe was run with the caller-selected `CLAUDE_CONFIG_DIR` and answered for that directory: the ambient store reported `"loggedIn": true`, and a scratch directory reported `"loggedIn": false` in the same shell, so on this platform the config directory alone decides which account answers.
`$HOME/.claude` is a plain directory here and no credential keychain is involved.

That measurement has NOT been repeated on macOS, and this repository's own record argues against assuming it carries over: [runtime-backends.md](runtime-backends.md) records that the login keychain is authoritative there, that the item is addressed per user with no config-directory component, and that `~/.claude/.credentials.json` is only the fallback Claude reads when keychain access fails.
If that one keychain item answers regardless of `CLAUDE_CONFIG_DIR`, a named pool would report authenticated from a different account than it names and the worker would spend that account.

`bin/fm-claude-auth.sh` therefore reports `unsupported:pool-separation-unverified` for any named (non-`default`) profile on a platform other than Linux, and every caller refuses on it.
The `default` profile is unaffected on every platform: it names the ambient store an ordinary launch uses (no `CLAUDE_CONFIG_DIR` at all when firstmate has none), so no account-separation claim is being made about it.
To enable named pools on another platform, measure `claude auth status` under a second `CLAUDE_CONFIG_DIR` on a host of that platform, record the result in this section, and extend `POOL_SEPARATION_VERIFIED_PLATFORM` in `bin/fm-claude-auth.sh` to match.
Do not infer the outcome from the keychain's design, and do not read or move credential values to find out.

## Claude first-run onboarding

Verified 2026-09-21 on Claude Code 2.1.276, on Linux.

Two scratch config stores holding no credentials, no copied consent, and no other Claude-owned keys were launched interactively in detached tmux panes, with the environment cleared so neither the ambient store nor an inherited token could answer:

```sh
printf '{"hasCompletedOnboarding":true}\n' > <scratch>/present/.claude.json   # <scratch>/absent has no .claude.json
env -i PATH=<path> HOME=<scratch>/home TERM=xterm-256color CLAUDE_CONFIG_DIR=<scratch>/<arm> claude
```

Each pane was captured after about 15 seconds without sending a key, then killed, and the scratch tree was deleted.

- `absent`: `Welcome to Claude Code v2.1.276`, `Let's get started.`, `Choose the text style that looks best with your terminal`, and the theme picker.
- `present`: no welcome or theme screen; the pane went straight to the `Accessing workspace:` folder-trust dialog, the next first-run step (owned by `bin/fm-claude-trust.sh`, not by this key).
- Claude created `.claude.json` in the `absent` store during the run without setting `hasCompletedOnboarding`, so an abandoned first run still reads as unonboarded.

So `hasCompletedOnboarding: true` in the store's `.claude.json` alone decides whether the text-style/theme screen opens, and `bin/fm-claude-auth.sh` reads exactly that key.
It does not check that the store is logged in or that later dialogs are settled; those have their own checks above and below.
This key is un-owned vendor state: re-run the two arms above and update this section when the vendor CLI changes.
No executable live guard is registered, because detecting the screen means scraping a timed TUI capture, which is not deterministic.

## Claude Bypass Permissions acceptance

Attempted 2026-09-20 on Claude Code 2.1.276; no probe registered.

Claude records acceptance of the machine-scoped Bypass Permissions disclaimer under the settings key `skipDangerousModePermissionPrompt` (user, local, flag, or policy scope), having migrated it out of the legacy `bypassPermissionsModeAccepted` field of `.claude.json`.
Neither is present anywhere on this host, yet the treatment arm in [runtime-backends.md](runtime-backends.md) records an interactive bypass worker against this same store meeting no dialog, so reading either one would report `absent` for a machine whose acceptance is in effect and would refuse every Claude launch.
There is also no non-interactive vendor command that reports the effective value, so nothing here satisfies the first-hand discriminator rule in `bin/fm-vendor-auth-probe.sh`.
The preflight therefore measures login state only and does not claim to prevent that dialog; [configuration.md](../configuration.md#claude-profiles-configclaude-profilesjson) carries the one-time per-pool operator step instead.
Re-check when the vendor exposes a readable acceptance state.

## Named pool first-run consent

Attempted 2026-09-21 on Claude Code 2.1.276, on Linux; no probe registered.

Claude's `Allow external CLAUDE.md file imports?` dialog renders when a loaded CLAUDE.md chain reaches outside the project tree, and its consent is stored per project entry in `<store>/.claude.json` (`bin/fm-claude-trust.sh` owns that contract).
A named pool launches against its own store, so that store holds neither the consent nor, necessarily, the same user-scope memory chain as the ambient store.
Whether the dialog applies to a pool at all therefore depends on where Claude resolves user-scope `CLAUDE.md` when `CLAUDE_CONFIG_DIR` is pinned - the pool store, or `$HOME/.claude` regardless - and that is **not measured here**.

What was measured today: a scratch `CLAUDE_CONFIG_DIR` does scope `.claude.json` (running `claude doctor` under one creates that store), and `claude --debug -p` in an unauthenticated scratch store exits at `Not logged in` before it loads or reports any memory file, so the question cannot be settled without a second logged-in store.

Bounded procedure to settle it, on a host that already has a second pool logged in:

```sh
printf '# POOL-MEMORY-MARKER\n@%s/outside.md\n' "$HOME" > <pool-config-dir>/CLAUDE.md
printf 'OUTSIDE-IMPORT-MARKER\n' > "$HOME/outside.md"
CLAUDE_CONFIG_DIR=<pool-config-dir> claude --debug -p 'reply with the word ok'   # records loaded memory paths
```

Record whether the debug output lists `<pool-config-dir>/CLAUDE.md` (the pool store owns user memory, so a fresh pool with no CLAUDE.md loads none and the dialog cannot fire) or `$HOME/.claude/CLAUDE.md` (the ambient chain reaches every pool, so the dialog applies to all of them), along with the platform and CLI version, then delete both scratch files.
Update this section and the per-pool operator step in [configuration.md](../configuration.md#one-time-setup-for-a-named-pool) together with the result.

Until that measurement exists, `bin/fm-claude-auth.sh` does not decide the question either way: it refuses a named pool whose operator attestation is absent or stale, which covers the prompt-applicable case without claiming the prompt applies.

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
`tests/fm-dispatch-resolve.test.sh`, `tests/fm-quota-choose.test.sh`, and `tests/fm-procevent-quota.test.sh` cover schema-6 account-row binding, account separation, and schema-5 compatibility through the public script interfaces.
The skill's primary path is that default TOON; `--json` is the documented defensive fallback, and this section records the producer `--json` shape that fallback consumes.
