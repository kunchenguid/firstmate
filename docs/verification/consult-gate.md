# Dispatch-time consultation gate verification

Audience: maintainer verification.

The gate's contract is owned by [`bin/fm-consult-gate-lib.sh`](../../bin/fm-consult-gate-lib.sh)'s header, stated for operators in [`../configuration.md`](../configuration.md) ("ChatGPT consultation channel"), and carried by the [`chatgpt-consultation`](../../.agents/skills/chatgpt-consultation/SKILL.md) skill for the agent-side procedure.
This record carries the commands and observed output that re-establish the gate on a current checkout; the captain's ask and the task chronology stay in the private task report.

## Subject

| Field | Value |
|---|---|
| Verified | 2026-10-13 |
| Platform | macOS arm64; shellcheck 0.11.0; tasks-axi 0.2.6; jq, curl, and python3 present |
| Channel | stubbed loopback bridge (`fm_test_start_bridge_stub` in `tests/fixtures.sh`); the suite spends no live ChatGPT turn |

## Guarantee

A ship or scout launch whose `data/<task-id>/chatgpt-loop.json` holds no non-empty prompt for the stage in play refuses before any endpoint, local copy, or record exists, naming the artifact path, the `bin/fm-chatgpt-loop.sh init` and `consult --stage audit|plan` commands that create it, and `--consult-waived <reason>` as the recorded exception.
The record's phase must also prove this round's consultation ran - `audit-dispatch`/`audit-worker` for the audit prompt, `plan-dispatch`/`plan-worker`/`complete` for the plan - so a record waiting at its consult phase or holding a prompt left by a finished round refuses (and `bin/fm-chatgpt-loop.sh next-round` clears those round-scoped fields as well).
An empty, whitespace-only, or multi-line waiver reason is refused, and a reason that is accepted lands in `state/<id>.meta` as `consult_waived=` and in the task's backlog note before the launch proceeds.
A channel the probe reports unavailable - `unreachable`, `unhealthy`, `misconfigured`, `unconfigured` - refuses the same way a missing prompt does, with the probe verdict naming the real cause, and a probe that cannot run refuses too: the explicit recorded waiver is the only way past the gate, so a down channel blocks no work silently and passes none silently either.
`bin/fm-control.sh relaunch` applies the same refusal before it stops the agent it replaces, and the consultation loop's own dispatch passes through the record it already holds; a relaunch of a loop-dispatched worker with no record of its own also passes on the `consult_delivered=<stage>` field the loop wrote to that worker's own task record when its stage-prompt handoff confirmed, which names a delivered stage (`audit` or `plan`). The loop clears any earlier stage's value before a new dispatch attempt, so a successful audit handoff cannot satisfy a plan-stage relaunch and a later spawn or handoff that fails leaves no delivery evidence, leaving that worker's relaunch refused.

## Commands

```sh
bin/fm-test-run.sh tests/fm-consult-gate.test.sh
bin/fm-test-run.sh tests/fm-control-relaunch.test.sh tests/fm-chatgpt-loop.test.sh
bin/fm-lint.sh bin/fm-consult-gate-lib.sh bin/fm-spawn.sh bin/fm-control.sh bin/fm-chatgpt-loop.sh bin/fm-live-lab.sh tests/consult-gate-fixture.sh tests/lib.sh tests/fixtures.sh tests/fm-consult-gate.test.sh
bin/fm-doc-audience-check.sh
```

## Observed output (2026-10-13)

```console
$ bash tests/fm-consult-gate.test.sh
ok - fm-spawn: a healthy channel refuses a ship launch with no stored prompt
ok - fm-spawn: a stored prompt leaves the launch unchanged and never probes the channel
ok - fm-spawn: a waiver with an empty or whitespace-only reason is refused
ok - fm-spawn: a waiver reason is recorded in the task record and the backlog note
ok - fm-spawn: a scout launch is gated exactly like a ship
ok - fm-spawn: an unreachable channel refuses with the cause named, never a silent pass
ok - fm-spawn: a listening-but-broken channel refuses with the cause named
ok - fm-spawn: a finished round's prompt never satisfies the gate at the next round's consult phase
ok - fm-spawn: the consultation loop's own dispatch satisfies the gate
ok - fm-spawn: the loop marker alone never satisfies the gate
ok - fm-spawn: a loop record's worker phase alone no longer satisfies the gate
ok - fm-spawn: an ordinary relaunch passes on the worker's recorded delivery, with no waiver
ok - fm-spawn: a delivery record must name a deliverable stage
ok - fm-spawn: a loop record naming another worker or a pre-delivery phase still refuses
ok - fm-spawn: the stage in play decides which stored prompt the gate requires
# all fm-consult-gate tests passed
```

The relaunch half of the same gate, from `tests/fm-control-relaunch.test.sh`:

```console
ok - fm-control relaunch: the consultation gate refuses before the running agent is stopped
ok - fm-control relaunch: a task with a stored prompt relaunches normally
ok - fm-control relaunch: an unavailable channel refuses before the agent is stopped
ok - fm-control relaunch: an unrecordable waiver refuses before the agent is stopped
```

The loop half that writes and clears the durable field, from `tests/fm-chatgpt-loop.test.sh`:

```console
ok - a confirmed handoff records consult_delivered on the worker, and the gate passes on it
ok - a failed handoff leaves no delivery record and the gate still refuses that worker
ok - a failed later handoff clears the earlier delivery record, so the gate refuses its relaunch
ok - a failed later spawn clears the earlier delivery record, so the gate refuses its relaunch
```

The refusal the healthy-channel case asserts, as it actually prints:

```console
error: task gate-healthy-c1 cannot launch without its stored ChatGPT-generated prompt
  <home>/data/gate-healthy-c1/chatgpt-loop.json
  no consultation record exists there
  consultation channel: healthy a bounded test turn completed at http://127.0.0.1:17913/v1
Create the prompt before launching:
  bin/fm-chatgpt-loop.sh init --task gate-healthy-c1 --objective-file <objective-file>
  bin/fm-chatgpt-loop.sh consult --stage audit|plan --task gate-healthy-c1
To launch anyway, pass an explicit waiver whose reason is recorded in the task record and the backlog note: --consult-waived <reason>
```

```console
$ bin/fm-lint.sh bin/fm-consult-gate-lib.sh bin/fm-spawn.sh bin/fm-control.sh bin/fm-chatgpt-loop.sh bin/fm-live-lab.sh tests/consult-gate-fixture.sh tests/lib.sh tests/fixtures.sh tests/fm-consult-gate.test.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=123 local_links=758
```

## Limits

Every probe verdict above is exercised through the stub, never a live bridge; [`bin/fm-chatgpt-bridge-lib.sh`](../../bin/fm-chatgpt-bridge-lib.sh) owns the live-probe evidence.
Fixture launch worlds seed a stored prompt through [`tests/consult-gate-fixture.sh`](../../tests/consult-gate-fixture.sh), so the rest of the suite is indifferent to whether a bridge answers on the machine running it.
