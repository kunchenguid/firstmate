# Crosscheck over Slack (R10)

This document owns the Slack team exposure of the crosscheck gate: the
listener `bin/fm-crosscheck-slack.py` (launched through
`bin/fm-crosscheck-slack.sh`), its configuration, its metering ledger, and
the operator recipe. The review itself is owned by `bin/fm-crosscheck.py`
and `docs/crosscheck.md`; the requirement text is R10 in
`docs/azure-requirements.md`.

## What it does

An engineer tags the crosscheck bot in an allowlisted Slack channel with a
GitHub pull-request link. The bot validates the repository against the
allowlist, checks the submitter's daily meter, acks in thread ("Review
started"), runs `bin/fm-crosscheck.sh run <task-id> <pr-url>` as a bounded
subprocess, and posts the findings as a thread reply on the engineer's own
message, naming the lane that produced the review (the cross-family primary deployment or
"pi-codex fallback (degraded)"). Tool failures are posted honestly as
failures, never as verdicts. Cursor Bugbot continues to run for engineers'
pull requests; this lane complements it.

The listener uses Slack Socket Mode over an outbound websocket, so no
public inbound endpoint is added to the private lane posture. The websocket
client is a minimal RFC 6455 implementation over the standard library; the
repo carries no third-party Python dependencies and none was added.

## Configuration: `$FM_HOME/config/crosscheck-slack.json`

```json
{
  "app_token_env": "FM_SLACK_APP_TOKEN",
  "bot_token_env": "FM_SLACK_BOT_TOKEN",
  "channel_allowlist": ["C0123ABCDEF"],
  "repo_allowlist": ["Ruby-Labs/relvino"],
  "github_token_env": "FM_GITHUB_READ_TOKEN",
  "daily_budget_usd": null,
  "daily_request_cap": null,
  "agent_branch_prefixes": ["fm/"],
  "state_dir": "$FM_HOME/state/crosscheck-slack"
}
```

- Tokens come ONLY from the environment variables named here. They are
  never stored in this file, never written to state, and never logged;
  every emitted line passes a redactor that knows every resolved secret.
- A missing token environment variable refuses startup with an exact
  message naming the variable. That is the ready-to-flip posture: the
  config and code land first, the owner supplies tokens later, nothing
  else changes.
- `repo_allowlist` is exact `owner/name` matching (case-insensitive). The
  bot's repository read credential is never pointed at a repository outside
  this list, because a review pulls untrusted content into a credentialed
  context. Out-of-allowlist links get a threaded refusal naming the
  repository and the allowlist.
- `channel_allowlist` bounds where the bot works; mentions elsewhere get a
  threaded "not enabled" refusal and no review.
- `daily_request_cap` is the metering control that BINDS TODAY: a
  per-submitter, per-UTC-day cap on started reviews, needing no cost data.
  At the cap the bot says so in the thread instead of silently dropping the
  request. Null = uncapped, still ledgered.
- `daily_budget_usd` is a forward contract, stated plainly: it binds only
  once the crosscheck ledger records per-review cost, which today's ledger
  schema does not, so a submitter's recorded day total stays 0.0 and this
  bound cannot fire until that lands. When cost data exists, a submitter at
  the bound gets the same in-thread reply. Null = unmetered pass-through,
  still ledgered.
- `agent_branch_prefixes` (optional; default `["fm/"]`) is the
  human-authorship screen described below. An empty array deliberately
  disables it; do that only if agent work never reaches the allowlisted
  repositories.
- `state_dir` supports a literal leading `$FM_HOME` and nothing else.

## THE AUTHORSHIP ASSERTION (read this before pointing the lane anywhere)

This lane stages every review's task metadata as `model=human-authored`,
which satisfies the crosscheck gate's model-separation screen for EVERY
reviewer. That is only sound because the lane asserts human authorship:
submissions come from engineers in Slack, and before any review the bot
fetches the PR's head branch (with the same read credential, only after
the repository allowlist admitted the URL) and REFUSES in thread any PR
whose branch matches an `agent_branch_prefixes` entry, directing it to the
ordinary crosscheck lane (`bin/fm-crosscheck.sh`), which carries true
author metadata. A branch-lookup failure also refuses (fail closed). The
model-separation guarantee for Slack reviews therefore rests on this
assertion plus the branch screen, not on the gate's own screen; the lane
must never be pointed at agent-authored pull requests, and an
agent-authored PR on a non-agent-prefixed branch is outside what this
screen can catch, which is exactly why the refusal message names the
ordinary lane.

`bin/fm-crosscheck-slack.sh --selftest [config-path]` validates the config
shape (and reports which token variables are set, values never shown) and
exits without touching Slack.

## The three owner inputs

The lane is built and tested; it goes live when the owner supplies exactly
these three things.

1. **Slack app (Socket Mode) and its two tokens.** Create a Slack app in
   the workspace; enable Socket Mode; create an app-level token with the
   `connections:write` scope (this is `app_token_env`, an `xapp-...`
   value). Under OAuth, grant the bot token scopes `app_mentions:read`,
   `chat:write`, `channels:history`, and `reactions:write`; subscribe the
   app to the `app_mention` bot event; install the app to the workspace
   (the `xoxb-...` value is `bot_token_env`); invite the bot to each
   allowlisted channel.
2. **The GitHub organization read credential**, exported as the variable
   named by `github_token_env`. A fine-grained PAT with read-only access to
   exactly the allowlisted repositories is the right shape; the listener
   hands it to the crosscheck subprocess (also as `GH_TOKEN`) and to
   nothing else.
3. **The two metering numbers**, both DK inputs recorded under C3:
   `daily_request_cap` (the control that binds today; a per-submitter daily
   count of started reviews) and `daily_budget_usd` (the USD bound, which
   binds only once the crosscheck ledger records per-review cost). Until
   they are set the lane runs unmetered pass-through with full ledgering.

## Run recipe

```sh
export FM_SLACK_APP_TOKEN=...   # from owner input 1
export FM_SLACK_BOT_TOKEN=...   # from owner input 1
export FM_GITHUB_READ_TOKEN=... # from owner input 2
bin/fm-crosscheck-slack.sh --selftest        # config shape check
bin/fm-crosscheck-slack.sh run               # resident listener
```

Where it runs is an operator decision recorded under C3. The v1
recommendation is the always-on local mac that already hosts the fleet:
the listener is a single low-CPU resident process whose standing cost is
the machine staying awake plus one Socket Mode connection, and colocating
it with `$FM_HOME` gives it the crosscheck gate, the reviewer roster, and
the state directory with no new credential distribution. Moving it to a
cloud VM later changes only where the three environment variables live;
that standing cost, when chosen, is booked under C3 alongside the
per-submitter metering this listener already records.

Operational bounds: reviews run one at a time off a bounded queue (depth
8; overflow gets a threaded refusal), each review subprocess has a wall
clock bound (default 5400 seconds, `FM_CROSSCHECK_SLACK_REVIEW_TIMEOUT_SECONDS`
to override) and an output ceiling, and the websocket reconnects with
capped backoff.

## Metering ledger (the C3 hook)

`<state_dir>/meter/<YYYY-MM-DD>.json` records every request: submitter, PR
URL, event id, start/finish timestamps, outcome status, the lane that
served it, token usage when the crosscheck output exposes it, and
estimated USD when derivable, else null. Writes are atomic under an
advisory lock. Honest limit, stated plainly: today's crosscheck ledger
schema does not record token usage or cost, so `estimated_usd` stays null,
recorded spend stays 0.0, and the USD bound cannot bind until the lane
records cost; `daily_request_cap` is the binding control today. The
per-request records are already durable, so C3 can attach a per-review
price or a usage-derived cost without a schema change here. A request is
metered against the UTC day it STARTED: the request id encodes the origin
day and completion finalizes the origin day's file, so a review crossing
midnight neither orphans its start record nor lands a misattributed
completion in the next day's ledger.

Event dedupe markers live in `<state_dir>/events/`; a redelivered Slack
event id never starts a second review. The rendered final reply is stored
durably BEFORE it is posted and marked delivered after the post succeeds,
so a redelivery of an event whose verdict was produced but never delivered
re-posts the stored verdict instead of being silently dropped. Retention:
a sweep at startup and daily removes event artifacts older than 14 days
and meter day-files older than 90 days; fresh files are never touched.

## Lane naming

Every thread reply names the lane that produced the review, the same
visibility R6 requires. The bot reads the `reviewer` object of the latest
ledger run: an explicit `lane` marker (with its `degraded` flag) is passed
through verbatim when present; when the run predates that marker, the lane
is derived from the reviewer profile that ran: a GLM model names
"GLM-5.2 primary" and a pi/codex profile names "pi-codex fallback
(degraded)". Coupling note: the explicit marker is being added by the R6
GLM roster work; once that lands, the derived path only serves ledgers
written before it.

## Prompt-injection posture

Slack text and PR content are data, never instructions. The only value the
bot extracts from a mention is one pull-request URL, validated against the
allowlist before any credentialed tool sees it; v1 accepts pull-request
links only, one per request. Nothing from Slack or from the PR is executed;
replies render findings as escaped plain text. The crosscheck subprocess
runs with a scrubbed environment that carries the GitHub read credential
and the FM_* configuration and never the Slack tokens. Task metadata is
staged as `harness=slack-team`, `model=human-authored`; that staging is
sound only under the authorship assertion and branch screen above.
Replies are posted with Slack `mrkdwn` disabled, so hostile finding text
cannot render fake emphasis, code spans, or links.

## Tests

`tests/fm-crosscheck-slack.test.sh` (hermetic) drives the real
event-handling core with parsed events and a fixture crosscheck binary:
link extraction, allowlist refusal text, durable dedupe, meter
accumulation and the bound-reached reply, lane naming passthrough, the
missing-token startup refusal, and a whole-artifact grep proving no token
value reaches any log or ledger. Live Slack is never contacted; live
acceptance (an engineer other than the owner, per R10) waits on the three
owner inputs.
