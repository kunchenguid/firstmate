# Crosscheck for Slack

This is the centrally operated R10 access lane for internal engineers.

An engineer needs only Slack.
In an approved channel, tag the Crosscheck bot with exactly one GitHub pull request URL.
The bot acknowledges the exact head it admitted and posts CLEAR, BLOCKING findings, STALE, or TOOL FAILURE in the same thread.
Every admitted result names the reviewed head SHA, reviewer lane, Crosscheck task ID, and exact durable report path on the coordinator.

The direct command remains supported for Firstmate and operators:

```sh
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck.sh run <task-id> <full-pr-url>
```

The Slack lane is an access adapter around that command.
It does not implement a second reviewer, lane allocator, or evidence policy.
Do not create a Crosscheck agent skill for this lane.

## Engineer request

In an approved Slack channel:

```text
@Crosscheck https://github.com/ORG/REPOSITORY/pull/123
```

Use one pull request URL per mention.
No Firstmate checkout, `FM_HOME`, Azure configuration, GitHub login, or provider credential is needed on the engineer's machine.

The coordinator owns Slack Socket Mode, the exact channel and repository allowlists, the GitHub read credential, signed authorship provenance, the reviewer roster, Azure access, queueing, metering, reports, and restarts.

## Network and capacity shape

The listener uses Slack Socket Mode over an outbound websocket.
It opens no public inbound endpoint.

Four listener workers admit requests concurrently.
Each worker invokes the supported `fm-crosscheck.sh run` wrapper with the same central `FM_HOME` used by direct CLI callers.
Both entry paths therefore enter Crosscheck's existing four-lane durable FIFO allocator.
The Slack adapter has a bounded eight-request waiting queue in front of those workers.
When that queue is full, the bot posts a visible refusal in the request thread.

The listener never translates a queue, GitHub, reviewer, Azure, cleanup, ledger, or Slack delivery failure into CLEAR.

## Authorship provenance

The old R10 build inferred authorship from branch prefixes and staged every request as `model=human-authored`.
That was unsafe and is retired.

The active Firstmate producer uses two coordinator-signed records.
`fm-spawn` writes `firstmate.crosscheck-author-launch.v1` before the agent process starts.
That immutable launch record binds:

- Originating Firstmate task ID and task generation.
- Exact task worktree, Git directory identity, branch ref, and launch head.
- Author harness, exact model, model family, and required captured account identity for OpenAI-family agents.

`fm-pr-check` later writes `firstmate.crosscheck-authorship.v2` only when the same worktree and Git identity remain, the current head descends from the launch head, tracked files are clean, and current HEAD equals the live PR head.
That exact-head record binds:

- Exact repository and pull request number.
- Exact 40-character head SHA.
- The complete launch-bound author identity.
- The SHA-256 digest of the signed launch record.

Both records authenticate their schema and payload with the coordinator provenance key.
Mutable task metadata can only agree with the signed launch identity; it cannot replace it.
A head produced in another worktree, a changed branch identity, or uncommitted tracked source is refused.

`bin/fm-spawn.sh` creates the launch record automatically for a managed task when central Slack configuration is installed, and `bin/fm-pr-check.sh` emits the exact-head record after it resolves the live PR head.
The exact-head command below is a pipeline interface, not a way for a caller to claim a model:

```sh
bin/fm-crosscheck-slack.sh attest-task <task-id> <pr-url> <head-sha> --config <config-path>
```

The Slack listener fetches the live PR head with its read-only GitHub credential, verifies the exact-head signature, recomputes the model family through Crosscheck's own classifier, and stages the verified harness and model for the core family-separation screen.
Both signed attestations are copied into the review's durable artifact directory.
Agent attestations require a captured author account identity, which also arms the Azure adapter's same-account refusal.

Slack identity, branch names, PR text, and caller-supplied free text carry no authorship authority.
Missing, malformed, tampered, conflicting, or wrong-head provenance gets a clear threaded refusal and starts no review.
Firstmate launch records deliberately cannot claim human authorship.
A human-authored PR may be classified as human only after a separate trusted producer, such as no-mistakes, supplies verifiable exact-head evidence from its own author boundary.
No such human producer is inferred from commit metadata, Slack identity, an unsigned PR-body marker, or absence of a Firstmate record; without it, the request fails closed as unclassified.

## Exact-head response contract

The listener resolves the current PR head before admission and binds provenance to it.
After Crosscheck returns, it requires the ledger's reviewed head to equal the admitted head.
It then fetches the live head again.

If the head moved during review, the bot posts STALE with both SHAs, the lane, task ID, and durable artifact.
The older verdict does not apply to the new head and the reply never says CLEAR.

An admitted response has this shape:

```text
Crosscheck CLEAR for https://github.com/ORG/REPOSITORY/pull/123
Lane: glm-5p2 primary
Task ID: slack-0123456789ab
Reviewed head: 0123456789abcdef0123456789abcdef01234567
Summary: ...
No active findings for this head.
Durable artifact: /coordinator/fm-home/data/slack-0123456789ab/crosscheck.md
```

## Central configuration

The default path is `$FM_HOME/config/crosscheck-slack.json`.

```json
{
  "app_token_env": "FM_SLACK_APP_TOKEN",
  "bot_token_env": "FM_SLACK_BOT_TOKEN",
  "channel_allowlist": ["C0123ABCDEF"],
  "repo_allowlist": ["Ruby-Labs/relvino"],
  "github_token_env": "FM_GITHUB_READ_TOKEN",
  "keychain_services": {
    "app_token": "firstmate-crosscheck-slack-app",
    "bot_token": "firstmate-crosscheck-slack-bot",
    "github_token": "firstmate-crosscheck-github-read"
  },
  "daily_budget_usd": null,
  "daily_request_cap": 10,
  "provenance_key_file": "$FM_HOME/config/crosscheck-slack-provenance.key",
  "state_dir": "$FM_HOME/state/crosscheck-slack"
}
```

`channel_allowlist` contains exact Slack channel IDs.
`repo_allowlist` contains exact case-insensitive `owner/name` repositories.
The GitHub credential is never used before the repository allowlist admits the URL.

`daily_request_cap` is a binding per-engineer, per-UTC-day cap on started reviews.
Admission and ledger append occur under one lock, so concurrent workers cannot overrun it.
`daily_budget_usd` remains optional and binds only to cost values the Crosscheck ledger actually exposes.
Null disables that bound without disabling request logging.

The three environment variables remain supported for foreground operation.
The central macOS service requires all three `keychain_services`; environment-only credentials are supported only for foreground operation.
Only Keychain service names appear in config or launchd state.
Credential values never appear there.

The provenance key is a 32-byte random key encoded as 64 lowercase hex characters in an owner-only regular file.
It must not be a symlink and must have no group or other permission bits.
The listener logs only its nonsecret key ID.

## Credentials and app permissions

The Slack app must have Socket Mode enabled.
Its app-level token needs `connections:write`.
Its bot token needs `app_mentions:read`, `chat:write`, `channels:history`, and `reactions:write`.
Subscribe the app to `app_mention`, install it to the workspace, and invite it only to approved channels.

The GitHub credential must be a read-only GitHub App installation token or fine-grained credential limited to the repositories in `repo_allowlist`.
It needs pull request metadata and repository contents read access.
It needs no write scope.

Slack, GitHub, provider, and Azure credential values stay only on the coordinator host.
The Crosscheck child receives only the GitHub read credential and required `FM_*` runtime configuration.
Slack credentials never enter the child environment.
Every process log and Slack error path passes through the registered secret redactor.

## Durable state and metering

Slack event markers live under `<state_dir>/events`.
The first process to create an event claim owns it, so concurrent duplicate delivery starts exactly one review.
The final reply is stored before posting and marked delivered afterward.
If Slack delivery fails, a redelivery revalidates the stored reviewed head before posting without rerunning the review.
A moved head produces STALE, and an unavailable head lookup produces a tool failure.

Per-engineer request records live under `<state_dir>/meter/<YYYY-MM-DD>.json`.
Each record includes the Slack user ID, PR URL, event ID, start and finish times, state, lane, available token data, and available cost data.
Request records stay bound to the UTC day on which they started, including reviews that cross midnight.

Signed launch records live under `<state_dir>/launch-provenance`, and exact-head records live under `<state_dir>/provenance`.
Review reports and both copied attestations live under `$FM_HOME/data/<task-id>`.

Event artifacts expire after 14 days and meter files after 90 days.
Review artifacts follow the central Crosscheck retention owner.

## Install, restart, and inspect

Validate central configuration and the provenance key without contacting Slack:

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
  bin/fm-crosscheck-slack.sh --selftest
```

Check that all three central credentials can be loaded without printing them (this does not authenticate against Slack or GitHub):

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
  bin/fm-crosscheck-slack.sh preflight --keychain-only
```

Install the macOS launch agent without starting an uncredentialed listener:

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
  bin/fm-crosscheck-slack-service.sh install
```

Operate it centrally:

```sh
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck-slack-service.sh start
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck-slack-service.sh status
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck-slack-service.sh restart
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck-slack-service.sh stop
```

The launch agent is `~/Library/LaunchAgents/com.firstmate.crosscheck-slack.plist`.
Logs are `$FM_HOME/logs/crosscheck-slack.log` and `$FM_HOME/logs/crosscheck-slack.error.log`.
The launch agent contains no credential values.
The launch agent persists the resolved absolute Python interpreter, executable PATH, HOME, and service configuration.
Install and start execute selftest and credential preflight with exactly the emitted environment and require Keychain access, ignoring inherited token variables.
Installation refuses before replacing an existing plist if validation fails.
The listener also requires Keychain credentials on every launch, including launchd restarts.
Reinstall the launch agent after moving the interpreter or changing tool locations.

## Activation and live acceptance

Before activation, supply the coordinator inputs in [Central configuration](#central-configuration) and satisfy [Credentials and app permissions](#credentials-and-app-permissions).
Install the central configuration before spawning an agent whose PR must be reviewable, because provenance begins at agent launch and cannot be reconstructed later.
The launchd credential checks and lifecycle are owned by [Install, restart, and inspect](#install-restart-and-inspect).

The live acceptance request must come from an internal engineer other than Dongkeun in an approved channel.
Record the request thread, exact admitted and returned SHA, provenance task, reviewer lane, Slack task ID, durable artifact, meter row, dedupe result, and service status in the R10 evidence directory.
Never copy credential values into that evidence.
