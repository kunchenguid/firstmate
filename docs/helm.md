# The helm: which machine is the control plane

A **fleet** is two or more machines that already dispatch work to each other over
the Bifrost relay ([`relay-host.md`](relay-host.md)).
The **helm** is the answer to a question the relay layer never had to ask: of those machines, which one is firstmate's control plane right now.
Exactly one machine holds it; every other machine of the fleet is read-only until it is handed the helm.

This layer is inert on a machine that never declared fleet membership, which is every single-machine home.
No lease, no check, no output, and no cross-machine call - see [Single-machine homes](#single-machine-homes).

## What is deliberately not here

There is **no automatic takeover**, and this is not a gap waiting to be filled.
The captain decided on 2026-08-01 that changing control machines is a human action, so none of the following exists anywhere in the code:

- a liveness probe of the other machine, or a `DEAD` / `UNREACHABLE` judgement;
- a grace period after which a machine may seize the helm;
- a heartbeat in the lease - the lease carries no `beat_at` field, because a heartbeat's only consumer was that judgement;
- a self-demotion timer in the watcher.

The reasoning is the captain's: an automatic takeover requires a machine to decide on its own that the other one is gone, and deciding that wrongly means two control planes - the same work dispatched twice, the same change merged twice.
A human running one command is a human confirming it.

What that costs, stated plainly: if the machine holding the helm dies for good, no other machine takes over by itself.
Someone runs `bin/fm-helm.sh claim --force`, which prints exactly what it could not verify.

## Why a handover still needs fencing

Handing the helm over on purpose still produces a **stale control plane**.
The machine that just gave the helm away is still running, still holds task metadata, and can still be told to do something - by a leftover session, a queued retry, or a captain who is on the wrong machine.
Two mechanisms handle that, and neither is arbitration:

**1. Epoch fencing, which is where the real safety is.**
The lease carries a monotonic `epoch`. Every verb that changes another machine's state carries the caller's epoch, and **the machine being commanded** compares it against its own lease.
A stale caller gets `ERR EPOCH_STALE ...` and nothing happens.
This does not depend on the stale machine being honest, having a correct clock, or knowing whether the link is up - the three things a stale machine is least able to supply.
`control-root/verbs/fmr-verb.sh` enforces it; `bin/fm-relay-lib.sh` attaches it in `fm_relay_exec`, the single funnel every cross-machine call goes through.

The epoch travels **on the verb token**, as `spawn@17` rather than as an argument of its own, and that is not a stylistic choice.
The deployed shell policy allowlists the verb path plus **at most eight arguments**:

```
^<control-root>/verbs/fmr-verb\.sh( [A-Za-z0-9._@=+-]{1,96}){0,8}$
```

`spawn <id> <kind> <project> <briefref> <harness> <model> <effort>` already uses all eight.
A ninth token would be refused by the policy layer before the verb ran, and widening the allowlist is not cheap either: a grant snapshots the policy version, so any edit invalidates it and forces a re-pair through another full-access window ([`relay-host.md`](relay-host.md)).
Riding on the verb token costs nothing - `@` is already in the allowed charset - and a machine in no fleet sends the bare verb exactly as before.
`tests/fm-helm.test.sh` pins that budget so a later change cannot quietly break every remote dispatch.

A missing epoch is refused exactly like a wrong one.
Treating "no token" as "not fenced" would let a stale caller opt out of the check by simply not sending one.

**2. The local gate.**
`fm_helm_assert` runs at the top of `fm-spawn.sh`, `fm-send.sh`, `fm-teardown.sh`, `fm-pr-merge.sh`, and `fm-merge-local.sh`.
A machine that is not the holder refuses to start work, steer anyone, clean anything up, or land anything - on the peer *or* on itself.
Gating the two merge paths is what removes the only irreversible failure: a machine that cannot see the fleet also cannot put a duplicate commit on a shared default branch.

## Where the truth lives

One lease per machine, at `<control-root>/helm/lease`, written only through the `helm-set` verb.
The peer cannot reach it with `remote file write`: the control root sits outside the relay's file roots, which Phase 1 measured and [`relay-host.md`](relay-host.md) records.

```
helm-v1
fleet=<fleet id>
epoch=<monotonic integer>
holder=<machine name> | none
updated_at=<utc>
by=<machine that wrote it>
forced=0|1
```

**One machine is the anchor and its copy is authoritative.**
Pick the always-on machine, not the laptop; the reason is physical, not aesthetic - the truth has to live where it can always be read.
Two rules follow and both are enforced:

- **write the anchor first**, every other machine second. An interrupted handover then leaves the anchor already moved and some other machine holding an old copy, which reads as "I am not the holder" - nobody acts. The reverse order leaves two machines each believing they hold the helm.
- **on disagreement the anchor wins.** Every other machine's copy is a cache, refreshed by `bin/fm-helm.sh status --refresh` and at session start.

Simultaneous attempts are settled by a compare-and-swap on the anchor: both sides read epoch N, both send `expect=N`, exactly one swap lands, the loser is told who won, and the epoch advances by exactly one.

### Why not the session lock

`bin/fm-lock.sh` writes a local PID and judges liveness with `kill -0` plus a process-name match.
That is only meaningful on the machine that wrote it - carried to another machine, the PID lands on some unrelated live process.
The two are orthogonal and both apply: the session lock stops two sessions on **one** machine, the helm decides which of **two** machines is the control plane.

## Handover moves supervision, not work

A crewmate is a live process, in a particular worktree, in a particular session, on a particular machine.
It cannot be carried, and rebuilding it throws away its context.
So the new control plane **discovers** what is already running rather than receiving a transfer:

- `bin/fm-helm.sh adopt` asks each fleet machine what it is running (`task-list`), reads each task's own record (`task-meta`), and writes a local mirror carrying `host=<machine>`.
- Event cursors resume from what the peer recorded as presented, so nothing is replayed from the beginning and nothing the old control plane never surfaced is skipped.
- Nothing is restarted, and the task never learns a handover happened.

The truth about a task therefore always lives on the machine running it, which is why this is steadier than packaging work up and shipping it.

**PR monitoring is a control-plane asset and does move.**
`handover` and `demote` stand down this machine's wake checks and PR polls for tasks that are remote or carry a `pr=`; `adopt` names the ones that need re-arming with `bin/fm-pr-check.sh`.
Without that step both machines poll the same change, and with routine merges delegated both might merge it.

## Setting a fleet up

Two files per machine, both LOCAL and gitignored.

**`config/fleet.json`** - this machine's own membership. Its absence is what makes everything above inert.

```json
{
  "fleet": "home",
  "machine": "mac",
  "control_root": "/Users/me/.fm-relay/control-root",
  "anchor": "box151"
}
```

| field | meaning |
|---|---|
| `fleet` | the fleet id. Every machine of one fleet must use the same string; a lease write from another fleet is refused |
| `machine` | this machine's name, which must match the name the *other* machines registered it under in `config/relay-hosts.json` |
| `control_root` | this machine's own control root, the one its peers were deployed against |
| `anchor` | the machine whose copy is authoritative. Either this machine's own name or a registered peer's |

**`config/relay-hosts.json`** - add `"fleet": "<same id>"` to each host record that is a member.
A registered host **without** that field is an ordinary Phase 1/2 task host: it never receives a lease, its fencing never switches on, and dispatch to it is unchanged.

**Point each member's deployed control root at that machine's REAL firstmate home**, and redeploy it if it is not already.
`adopt` discovers work through the peer's `task-list` verb, and that verb enumerates `<control-root>/config`'s own `FM_HOME` - not any field of `fleet.json`.
A control root left pointing at the sandboxed host home a Phase 1/2 deployment gave it answers every question correctly and lists nothing the captain is actually running, so the handover mechanism passes while the handover itself moves an empty set.
The same field decides which home a dispatch to that machine lands in, so on a machine that is both a fleet member and a GUI task host the two roles now share one home; [`relay-gui-host.md`](relay-gui-host.md) owns why that home must not share a worktree pool with the dispatching machine's own repositories.

Then, on the machine that should steer: `bin/fm-helm.sh claim`, followed by `bin/fm-helm.sh adopt`.

## Everyday use

| command | run it where | what it does |
|---|---|---|
| `status [--refresh]` | anywhere | who holds the helm; `--refresh` re-reads the anchor and corrects this machine's copy |
| `handover <machine>` | on the holder | gives the helm away. The only routine way it moves |
| `claim` | on a machine when nobody holds it | takes a free helm |
| `claim --force` | on the captain's explicit instruction | takes a held helm. See below |
| `demote` | on the holder | releases the helm so nobody holds it |
| `adopt` | on the new holder | picks up the tasks running on the other machines |
| `audit` | anywhere | reads every machine's lease and flags disagreement |

A handover is run **by the machine that holds the helm**, naming where it should go.
Pulling it from the far side is not a routine path, because the machine losing it would not be taking part - and if it were unreachable, its own copy would keep telling it that it is still in charge.

### Switching machines, and `/stow`

The captain's own words for how a switch is triggered are "through the `/stow` mechanism".
`/stow` and the handover are kept as **separate commands, run in that order**, rather than folding one into the other:

- `/stow` is routine hygiene. It runs before any context reset, on a single machine, and in secondmate homes - none of which should move a control plane. A `/stow` that handed the helm over as a side effect would relocate the fleet every time the captain compacted a conversation.
- The handover names its destination. `/stow` has no idea which machine the captain is walking to, and guessing is not a thing a control-plane move should do.
- On a machine in no fleet, coupling them would buy nothing at all: the handover is a no-op there.

So the sequence is: `/stow` puts the session's durable knowledge on disk, then `bin/fm-helm.sh handover <machine>` moves the helm, then `bin/fm-helm.sh adopt` on the machine that received it.
The `stow` skill points at this and does not perform it.

### `claim --force`

The escape hatch for a machine that is genuinely gone.
It prints what it cannot check - whether the other machine is actually stopped, and whether it is mid-merge, mid-gate, or mid-dispatch - and it does not probe, by design.
Until the forced-out machine can reach the anchor again, its own copy still tells it that it holds the helm, so **both machines can act on their own local work in that window**.
Making sure that is not true is the captain's job; the command's job is to say so rather than imply a check it did not make.
When the forced-out machine does reach the anchor, it finds the helm gone, writes `state/.helm-lost`, and refuses everything until the captain resolves it.

## Single-machine homes

The whole layer is behind one `[ -f config/fleet.json ]`:

- `fm_helm_assert` returns immediately - no `jq`, no lease read, no network, no output;
- `fm_relay_exec` attaches no epoch, so a Phase 1/2 verb call is byte-identical to what it was;
- a host with no lease file enforces no fencing, so an existing task host keeps working without being redeployed;
- the session-start digest gains no helm section, no heading, and no line.

Two tests hold that down.
`tests/fm-helm-single-machine.test.sh` re-runs `tests/fm-helm-fleetless-probe.sh` and diffs it against `tests/fixtures/fm-helm-fleetless-baseline.txt`, a transcript captured from the tree **before** the gate existed - same wording, same exit codes, same files written, no network call, and a real merge that still lands.
`tests/fm-helm.test.sh` asserts the mechanism underneath, and drives a two-machine fleet through handover, fencing, and adoption against a stub relay that runs each verb with an empty environment.

If that diff ever fails, the fix is to look at what changed for a fleetless home.
Re-capturing the baseline is only right when the difference is intended and the commit says why.

## What a handover does not carry

**A queued dispatch.** A dispatch a task host refused - asleep, screen locked, no desktop host session - is held on the *control* side, and it is the one piece of in-flight state with nothing on any other machine for `adopt` to discover.
`handover` names each one as `NOT MOVING: <id> is queued for <host>`, and the machine that gave the helm away stops retrying it rather than collecting a refusal every check.
The record stays on disk; re-queue it on the machine taking over, or come back to the first one.

**Undrained wake notifications.** They are local to the machine that queued them, so `handover` reports the count and expects them to be read before the captain leaves.
Events belonging to remote tasks are not affected: those replay from the host's own cursor.

## Verification status

Everything above is covered by the hermetic two-machine suite.
The live handover has since been run on the real pair as well.

Measured 2026-08-02, control machine macOS 26.5.2 arm64 with bifrost 0.0.167, peer Debian 5.15 x86_64 with bifrost 0.0.165, over `bifrost.bytedance.net`.
The helm moved between the two machines six times, epoch 1 to 9, with one real claude crewmate live on each machine throughout and a throwaway repository on each side.

What that run exercised:

- A planned handover with a live task on both machines: the new control plane adopted the other's task, the demoted machine refused `spawn`, `send`, `teardown`, `pr-merge`, and `merge-local`, and neither crewmate was restarted - same pane pid, same agent pid, same start time before and after all six moves.
- Event continuity: the adopted task's five unacknowledged status lines replayed from offset 0 at exactly the byte count recorded before the handover, and a `needs-decision` the old control plane never answered was answered by the new one and accepted by the still-running worker.
- Fencing, both directions of wrongness: a control plane frozen at epoch N was refused by the peer with `ERR EPOCH_STALE` on `send` and on `teardown`, a call carrying no epoch at all was refused identically, and the peer's task, metadata, worktree, and lease were byte-for-byte unchanged afterwards.
- The surprise-demotion path: `status --refresh` on the stale machine wrote `state/.helm-lost`, every mutating command then refused on that record, and `bin/fm-helm.sh claim` cleared it exactly as the refusal text says.
- Two machines claiming a free helm at the same wall-clock instant: one won, the loser was told who won, and the epoch advanced by exactly one.
- Zero impact on a fleetless home *on a machine that now holds a lease*: a clean home with no `config/fleet.json` ran all five gated commands with no helm output at all, and its session-start digest gained no `HELM` section.

What that run did **not** exercise, and what therefore remains inference:

- A handover of a real engineering task; both probes were scripted throwaways that only appended status lines.
- The PR-monitoring move. Neither probe carried a `pr=`, so the `handover`/`demote` stand-down and the `adopt` re-arm prompt were never reached.
- `claim --force` itself. The stale control plane was produced by advancing the peer's lease directly, which leaves the same state a forced claim during a link break leaves, but the command was not run.
- A real link break, a real sleep and wake cycle, and a real `bin/fm-watch.sh` executing an adopted task's notification check - that check was run by hand exactly as the watcher runs it, and it produced the wake line, but no watcher was armed.
