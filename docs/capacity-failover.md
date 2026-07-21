# Capacity Failover Substrate

This document records the passive capacity/failover substrate added from the 2026-07-12 evidence pass.
It does not define a standing dispatch policy.
It does not enable automatic account rotation.
It does not change `fm-spawn.sh` or `fm-dispatch-select.sh` while `config/capacity-failover` is absent.
It does not clean disk or kill agents.

## Evidence Scope

The implemented signatures are only the observed ones.
Codex quota walls are recognized from `usage limit` text that carries an observed reset such as `resets 2:42PT` or `try again at 11:41 PM`.
Claude quota walls are recognized from `session limit` text that carries an observed reset such as `session limit, resets 10:50pm PT`.
VibeProxy auth exhaustion is recognized from `auth_unavailable: no auth available (providers=..., model=...)`.
Explicit provider rate limits are recognized from `rate limit`, `too many requests`, or HTTP 429 text.
`Retry-After: <seconds>` is treated as observed reset evidence.
Login-required output such as `Not logged in - Please run /login` is recognized as auth exhaustion.
Unknown model and transient provider throttles classify as `other`, not quota.

## Classification

`bin/fm-capacity-classify.sh` reads failure text from stdin or `--file`.
It prints key-value lines with `class=quota|auth|other` and a stable `reason=`.
When the text includes an observed reset time, it also prints `reset_at=`, `reset_epoch=`, and `cooldown_ttl_secs=`.
The helper is intentionally conservative.
It does not invent reset times or cooldown TTLs for auth failures.

## Cooldown Records

`bin/fm-capacity-cooldown.sh` writes records under `state/capacity-cooldowns/`.
The key is the tuple `(harness, account, profile)`.
`account` may be empty when the account is unknown or not exposed.
Records carry no tokens or secrets.
They store `reset_epoch=`, the classification class and reason, the selected harness/profile/account labels, and an optional source task id.
Auth exhaustion records created by `bin/fm-capacity-route.sh handle-wall` use `reset_epoch=manual` with `requires_action=interactive_auth_required`.
That is a durable manual block, not an invented TTL.

Use `mark` when the caller already has a reset epoch or explicit TTL.
Use `mark-from-text` when the observed wall text includes a parseable reset.
Use `active` to read a live cooldown and get `remaining_secs=`.
Expired records are removed by `active`.

## Route Selection

`bin/fm-capacity-route.sh` is the conservative route helper for quota/auth walls.
It is deterministic and does not change standing dispatch by itself.
Routes are read from `config/capacity-failover` unless `--routes-file` is passed.

Route lines use this format:

```text
route=<harness>|<account-or-provider>|<profile>|<model>|<effort>
```

Selection skips routes with active cooldown or manual auth-exhaustion records.
A cooldown recorded with a partial key - no account, or a `default`/empty profile - is treated as a wall on the whole harness, so it blocks every route for that harness rather than only the exactly-matching one.
Record a wall with both `--account` and a concrete `--profile` when only that one route should be skipped.
It refuses unverified harnesses.
When `config/crew-dispatch.json` exists, it refuses route selection unless the caller passes `--dispatch-approved` after consulting the dispatch rules.

`handle-wall` classifies wall text, records the current route block, then either prints a same-owner `fm-rehome-quota-wall.sh` command for the next verified route with headroom or prints an escalation.
The escalation includes the exhausted harness, account/provider, model/profile, reset epoch when known, and any required interactive auth/account action.
The helper never creates a new task id and never discards dirty work.

## Rehome Helper

`bin/fm-rehome-quota-wall.sh <task-id> --harness <verified-harness>` performs the manual same-worktree rehome procedure used for quota-wedged work.
The helper currently supports only the evidence-backed tmux path.
It refuses non-tmux task metadata instead of guessing a backend-specific recovery path.

The helper requires a clean worktree by default.
Use `--force-dirty` only when the operator intentionally accepts relaunching with uncommitted changes present.
It attempts to preserve task identity by keeping the same `state/<id>.meta`, `data/<id>/`, worktree, branch, and recorded `pr=` / `pr_head=` lines.
It writes a `data/<id>/rehome-<timestamp>.md` continuation brief and launches the new harness against that brief.
The continuation brief explicitly tells the replacement agent not to create a helper branch, helper task id, or child PR.

When the old endpoint still reports a live agent process, the helper sends `/exit` and waits for a confirmed dead agent before killing the endpoint container.
If liveness remains `alive` or is `unknown`, the helper refuses to relaunch.
This fail-closed behavior prevents duplicate task ownership.

## Dispatch Backstop

The rehome helper never chooses a harness.
The caller must pass a verified target harness explicitly.
When `config/crew-dispatch.json` exists, the helper refuses unless `--dispatch-approved` is also passed.
That flag means firstmate has already consulted the dispatch rules and is not letting the helper bypass them.

## Host Pressure Backpressure

`bin/fm-host-pressure.sh check` reports bounded memory, disk, and active-task pressure as key-value evidence.
It is passive unless `config/capacity-failover` contains `host-pressure=on`.
When that opt-in is present, `fm-spawn.sh` runs the check before creating task ownership metadata.
Warnings are surfaced and the spawn continues.
Critical pressure refuses the new spawn and leaves existing task ownership untouched.
`bin/fm-host-pressure.sh gate --kind test` gives the same disk-floor decision to validation/test launch wrappers.

The file supports these optional thresholds:

```text
host-pressure=on
min_memory_available_mb=2048
warn_memory_available_mb=4096
disk_floor_mb=10240
disk_clear_mb=20480
disk_alert_cooldown_secs=900
max_running_tasks=30
```

The default thresholds above apply only after `host-pressure=on`.
`disk_floor_mb` is the hard floor.
Once entered, disk pressure remains active until free space reaches `disk_clear_mb`; this hysteresis prevents repeated enter/exit flapping.
Absent `config/capacity-failover`, or with `host-pressure` off, spawn behavior is unchanged.
Disk pressure output reports safe transient cleanup candidates such as `/tmp/fm-*` and local firstmate logs.
The helper never deletes those candidates.
`classify-shed --command <line>` only marks restartable validation/test/lint commands as eligible restartable compute.
It does not kill those processes; callers own any stop/retry policy.
`periodic-alert` emits a bounded disk-pressure alert for supervision and applies its own cooldown marker.

## Shared GitHub Quota

`bin/fm-shared-github-quota.sh` coordinates GitHub API quota as a fleet-wide shared resource.
Its state is intentionally independent of any one `FM_HOME`.
By default it uses `${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/shared-github-quota/`; tests and unusual deployments can set `FM_SHARED_STATE_OVERRIDE`.

Cooldown records are keyed by `(provider, account, route)`.
The account comes from `--account`, `FM_GITHUB_ACCOUNT_ID`, a locally cached account, or a best-effort `gh api user` derivation.
An account id read out of a rate-limit body is evidence only: it is recorded as `observed_account=` and never keys a record or replaces the cached account.
When no account resolves, `mark-from-text` writes one account-agnostic record, and `check` consults that record in addition to the keyed one, so a cooldown observed before any account is known is still read back.
`cache-put` writes under the resolved key, and `cache-get` consults the account-agnostic entry in addition to the keyed one exactly as `check` does, so a read cached before any account was known stays reachable afterwards.
`mark` and `mark-from-text` write the cooldown.
`mark-from-text` accepts the reset forms real `gh` stderr carries: an ISO-8601 or `UTC` timestamp, a labeled `x-ratelimit-reset: <epoch>` header from a primary limit, or a labeled `Retry-After: <seconds>` from a secondary limit.
The labeled header separator is required, so prose such as `retry after 15 minutes` is not read as seconds, and a labeled header is preferred over an unlabeled timestamp that is already in the past, so a log-line timestamp cannot shadow real header evidence.
A bare number is never reset evidence, so an unlabeled id or epoch in an error body cannot create a cooldown.
`check` prints `state=allow` or `state=defer` with provider, account, route, reset time, and remaining seconds.
Because a record's path only encodes a hash of its key, a record whose own `provider=`/`account=`/`route=` fields disagree with the key it was found under is reported as `state=allow` with `mismatched_record=1` and left in place; capacity cooldowns apply the same rule to `harness=`/`account=`/`profile=`.
Expired records are removed by `check`, so polling resumes only at or after the recorded reset time.

`fm-pr-check.sh` uses this guard when it records PR metadata and in the static `fm-pr-poll.sh` poller.
Every guard call on those paths - the checks, the cached reads and writes, and the `mark-from-text` handlers in `fm-pr-check.sh`, `fm-pr-poll.sh`, `fm-pr-merge.sh`, and `fm-teardown.sh` - sets `FM_SHARED_GITHUB_QUOTA_DERIVE_ACCOUNT=0`, so the guard never spends a GitHub API call of its own and one key policy holds across the whole path.
During a shared cooldown, PR pollers do not call `gh`.
They return silence unless a cached PR state already proves `MERGED`; that preserves local ownership and avoids repeated wake spam while GitHub is cooling down.
When no cooldown is active, the poller keeps the existing live `gh pr view` behavior and refreshes the small cache after a successful read.

`fm-pr-merge.sh` refuses an explicit merge during a known shared cooldown.
That refusal is a structured escalation naming the provider, account, route, reset time, attempted operation, and required action.
`fm-teardown.sh` skips GitHub PR lookup proofs during a shared cooldown and falls back to the existing content-in-default proof; if neither proof can establish landed work, teardown still refuses fail-safe.
`fm-bearings-snapshot.sh --include-prs` reports a bounded deferred PR status during cooldown, while the default bearings path remains local-only.

## Opposite-Harness Constraint

Adversarial review lanes can add this line to their task meta:

```text
opposite_harness_must_differ_from=<harness>
```

`fm-rehome-quota-wall.sh` and future automatic failover code must refuse any candidate harness equal to that value.
This preserves the cross-harness review property that a reviewer must not collapse onto the same harness as the author lane.
