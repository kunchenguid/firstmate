# Remote second mates

This page covers how to set up, provision, run, and retire a second mate whose Firstmate home lives on another host.
It is for operators who run a remote second mate and for anyone checking its transport and safety behavior.

Remote second mates place a whole persistent Firstmate home on another SSH-reachable host.
The primary still owns routing and supervision, while the remote home owns its own projects, backlog, and workers.
Firstmate does not support placing an individual worker remotely or failing a remote route over to a local replacement.

## Find a topic

| Task | Start here |
| --- | --- |
| Prepare the primary and the remote host | [Prerequisites](#prerequisites) and [non-interactive tool contract](#non-interactive-tool-contract) |
| Check whether a host is ready, or repair it | [Readiness, repair, and the human steps](#readiness-repair-and-the-human-steps) |
| Create the route and the remote home | [Provision a route](#provision-a-route) |
| Launch, recover, message, and read a remote second mate | [Normal operation](#normal-operation) |
| Move queued work to the remote home | [Backlog handoff](#backlog-handoff) |
| Push configuration, relaunch, update, or retire | [Sync, update, and retirement](#sync-update-and-retirement) |
| Run the tests or a real-host smoke test | [Verification](#verification) |

## Where the remote agent runs

The remote second-mate agent itself always runs on the [Herdr backend](herdr-backend.md) in the shared `fm-remote` session.
Every path that provisions or launches one refuses a host that is not ready for it.

- `fm-remote` is reserved for remote fleet work and must not be used for personal work.
- The user's interactive Herdr session remains `default` and is not a remote-secondmate prerequisite.
- Herdr's remote-session server belongs to the host's own GUI login session rather than to the SSH connection.
  As a result, the agent's endpoint survives every disconnection the primary's supervision depends on.
- Local second mates are unaffected and keep their ordinary backend and session selection.
  So do the workers a remote second mate supervises inside its own home.

## Prerequisites

### SSH access from the primary

1. Configure an SSH alias in the primary account's normal OpenSSH configuration.
2. Use ordinary public-key authentication, strict host-key verification, and a dedicated remote account where practical.
3. Do not enable agent forwarding for Firstmate.

`fm-on.sh` adds its own protections:

- On every call, it also disables agent forwarding, forwarding setup, and configured `SendEnv` patterns.
- It arms bounded SSH dead-peer detection, so a vanished host (a reboot, a dropped link) fails within a bounded window instead of hanging indefinitely.

Its [script header](../bin/fm-on.sh) owns the keepalive defaults and environment overrides.

### Remote clone and entrypoint

1. Clone Firstmate on the remote host at an absolute code-root path.
2. Expose that clone's fixed entrypoint on the account's non-interactive SSH `PATH`, for example:

```sh
mkdir -p ~/.local/bin
ln -s /absolute/path/to/firstmate/bin/fm-remote-entrypoint.sh ~/.local/bin/fm-remote-entrypoint.sh
```

The entrypoint accepts encoded argv for genuine executable `bin/fm-*.sh` files only.
It never accepts a shell command string.

### Doctor bootstrap over plain SSH

The readiness-owning doctor runs over this plain SSH bootstrap.
That lets read-only mode report worker gaps and lets `--fix` install or repair the worker.
The entrypoint authorizes that bootstrap in one of two ways:

- With normal git tracking when git resolves.
- With its pinned doctor digest when doctor must report that git itself is missing.

### The remote job worker

After setup, every other command goes through Firstmate's account-owned remote job worker.
Each such command takes these steps:

1. It verifies the worker.
2. It stages the encoded argv and stdin bytes.
3. It waits for its result.
4. It relays stdout, stderr, and the exit status separately.

On macOS the worker is `dev.firstmate.remote-job`, an Aqua-scoped LaunchAgent at `~/Library/LaunchAgents/dev.firstmate.remote-job.plist` with logs under `~/Library/Logs/`.
After that bootstrap, every non-doctor `fm-on.sh` target runs through that worker in the remote account's GUI session.
It never runs in the SSH process or a Herdr pane.
Linux uses the same queue and worker protocol without the Aqua-session requirement.

### Job lanes and preemption

The worker serves one lane per staged home:

- Jobs for the same home follow the staging-order contract owned by [`bin/fm-remote-job-lib.sh`](../bin/fm-remote-job-lib.sh).
- Different homes' lanes run concurrently, so one home's long job never delays another home's commands.

Within a home's lane, the worker preempts a running reply long-poll as soon as any command other than another reply long-poll is queued for that home.
As a result, interactive commands and startup checks are never serialized behind a poll window.

`bin/fm-remote-job-lib.sh` owns that preemption contract.
It distinguishes preemption from a wait window that closes with no data:

- Only a genuinely quiet window proves channel freshness.
- Either outcome can re-arm without losing data.

### Cancelled and orphaned jobs

A caller cancels its job instead of abandoning it when, before the job completes, the caller disconnects or its caller-side wait expires:

- Cancelled queued work is skipped.
- Cancelled running work is stopped.
- The finalized record is cleaned up.

As a result, retries never convoy behind abandoned work.

A worker stops itself once its configured code root stops being a Firstmate checkout, so a worker started from a worktree cannot outlive that worktree.
`bin/fm-remote-job-reap-orphans.sh` clears any worker already left behind that way.
It never touches a worker whose checkout still exists.

### What the remote account must provide

- The remote account must provide the required toolchain, the selected worker runtime, the selected session backend, and credentials that work on that host.
- A [worker account pin](configuration.md#worker-account-pin-configclaude-account-configpi-account) for the second mate or its workers lives in the remote home's own configuration on that host.
- The origin URL named for each project must be reachable from the remote account, because projects are cloned on that host rather than copied from the primary.

## Non-interactive tool contract

Remote job execution never runs a login or interactive shell.
So `~/.profile`, `~/.bashrc`, and `~/.zshrc` never contribute to the job worker's runtime `PATH`.
`bin/fm-remote-job-lib.sh` is the single owner of the worker `PATH`.
It builds the `PATH` by filesystem discovery rather than by evaluating shell startup files.

### Worker PATH order

The authorized child sees these directories, in this order:

1. `<remote-root>/bin`.
2. A genuine account `~/.local/bin`.
3. The nvm default version bin.
4. asdf shims and install bins.
5. mise shims and install bins.
6. Nix directories.
7. Homebrew directories.
8. The system tail `/usr/bin:/bin:/usr/sbin:/sbin`.

The Nix and package-manager order after version-manager discovery is:

1. `~/.nix-profile/bin`
2. `/etc/profiles/per-user/<account>/bin`
3. `/run/current-system/sw/bin`
4. `/opt/homebrew/bin`
5. `/usr/local/bin`

Exact repeated entries are omitted.

### nvm version selection

Nvm selection follows the filesystem `alias/default` chain and chooses the highest matching installed semantic version.
When the alias is absent or has no installed match, it falls back to the highest installed semantic version.
An nvm `system` default adds no nvm version bin, so the later system directories provide Node.

### Symlinked directories

For the three Nix locations:

- A final `bin` symlink is resolved to its physical directory.
- A path reached through symlinked ancestors remains in its documented position.

Other final-component symlink directories, including `~/.local/bin`, are excluded.

### Stale Herdr clients

Because `~/.local/bin` precedes the package-manager directories, a stale self-updated `herdr` there shadows the one the account's login shell may resolve.
The Herdr adapter steps around a client the running server refuses, and `fm-remote-doctor.sh` names which client it selected ([`herdr-backend.md`](herdr-backend.md#client-selection)).

### How the entrypoint resolves git

The entrypoint resolves `git` only from the operator portion of the `PATH` (every discovered directory except `<remote-root>/bin`).
It does this before prepending `<remote-root>/bin` for the authorized child.
This has two consequences:

- A checkout-local `bin/git` cannot authorize an untracked command.
- A host with no operator `git` receives an install-or-wrapper diagnostic before command execution.

### Wrappers for version-managed tools

The filesystem discovery normally finds tools installed by nvm, asdf, or mise without starting their shell hooks.
When a required tool remains discoverable only through one of those managers, `fm-remote-doctor.sh --fix` may create a Firstmate-owned wrapper in `~/.local/bin` that executes its selected absolute target.
It never overwrites a wrapper or other file it does not own, and it never installs a package.
An operator can use the same wrapper shape when a tool needs a manual selection:

```sh
mkdir -p ~/.local/bin
cat > ~/.local/bin/tasks-axi <<'SH'
#!/usr/bin/env bash
tool_bin="$HOME/.nvm/versions/node/<selected-version>/bin"
PATH="$tool_bin:$PATH"
exec "$tool_bin/tasks-axi" "$@"
SH
chmod +x ~/.local/bin/tasks-axi
```

- Replace the placeholder with the remote account's selected nvm version.
- For asdf or mise, use the same shape with the selected version's absolute `bin` directory, one wrapper per tool the remote home actually needs.
- The wrapper must execute that absolute target rather than resolving its own name again through `~/.local/bin`.

## Readiness, repair, and the human steps

`bin/fm-remote-doctor.sh` is the single owner of what "ready for a remote second mate" means.

### Check a host

Check any host against it directly:

```sh
bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh
```

That run is read-only.
It takes these steps:

1. It prints the exact `PATH` its own entrypoint launch produced.
2. It executes its required-tool probe through the installed worker when one is available.
3. It reports where each required and optional tool resolved.
4. It then reports one line per readiness check.

Each gap carries one of two tags:

| Tag | Meaning |
| --- | --- |
| `fixable:` | `--fix` can close the gap. |
| `human:` | Only a person at that machine can close the gap. |

Every gap is followed by an `action:` line naming the exact step.
Any remaining gap exits non-zero.
The script's own header owns the full line protocol.

### Repair with --fix

`--fix` repairs only the automatable gaps and is safe to rerun:

```sh
bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh --fix
```

Over the plain SSH doctor bootstrap, it writes and reloads two Firstmate-owned launch agents on macOS:

- `dev.firstmate.remote-job`.
- `dev.firstmate.herdr.fm-remote`.

Both are scoped with `LimitLoadToSessionType=Aqua` and bootstrapped in `gui/<uid>`.

### How the Herdr launch agent starts its server

The Herdr agent runs [`bin/fm-remote-herdr-guard.sh`](../bin/fm-remote-herdr-guard.sh) through a shell in login mode with separate `-l` and `-c` arguments.
It resolves that shell in this order, so the server inherits the account's own environment:

1. The remote account's executable labeled Directory Services `UserShell`.
2. An executable `$SHELL`.
3. `/bin/sh`.

The `gui/<uid>` domain, not the login shell, is what gives that server and every pane it spawns the Aqua audit session and login-keychain access.
A server born in any other session cannot read the login keychain.
Every claude pane under such a server falls back to a stale plaintext credentials file and reports "Login expired".

### How the guard converges on one server

Herdr's own SSH remote attach starts a server born in another session when it finds none.
At boot, that server wins the `fm-remote` socket, because sshd accepts connections before the login session exists.
The guard is what makes the launch agent converge.
It acts on whichever server owns the `fm-remote` socket:

| Socket owner | Guard action |
| --- | --- |
| Nothing | Execs the server in the foreground under launchd. |
| An Aqua-born server | Exits 0. |
| Any other (foreign) server | Stops the foreign server and takes the session over, closing its panes so the parent firstmate relaunches its mates into the Aqua-born server. |

`KeepAlive={SuccessfulExit=false}` lets that exit 0 rest instead of respawning against a held socket.
The guard's header owns the decision table, and [`bin/fm-remote-herdr-owner-lib.sh`](../bin/fm-remote-herdr-owner-lib.sh) owns the birth markers it reads.

### Other repairs and limits

`--fix` also takes these actions:

- It starts the same workers directly on Linux.
- It recreates the `~/.local/bin/fm-remote-entrypoint.sh` symlink when it is absent.
- It creates only Firstmate-owned required-tool wrappers that it can prove resolve to a version-manager target.
  It stops after one harness satisfies the at-least-one requirement, which is the harness line of the [required remote tools](#required-remote-tools).

Its limits:

- It never installs packages or overwrites a non-Firstmate file at a reserved wrapper path.
- The dedicated Herdr launch agent owns only the remote-secondmate `fm-remote` server.
  It does not inspect, rewrite, start, stop, or require the user's interactive `default` session or its `dev.firstmate.herdr` launch agent.
- It re-derives every check from the host afterwards, so what it prints is the state after the repair rather than the intent of one.

### Steps only a person can take

These steps are never automated and are always reported rather than silently attempted, because SSH cannot create a GUI session from nothing:

- The first console login on that Mac, and automatic login in System Settings > Users & Groups when the machine runs headless and must come back on its own after a reboot.
- FileVault, which holds a reboot at pre-boot authentication before any login session exists.
- Installing any missing required tool that no safe wrapper can resolve.
- Each worker runtime's own `/login`, and any keychain password prompt that login needs.

Firstmate never writes an auto-login password, never changes FileVault, and never stores an account password.
A file at `~/.local/bin/fm-remote-entrypoint.sh` that is not Firstmate's own symlink is reported for the operator to inspect and is never overwritten.

### Required remote tools

| Requirement | Tools |
| --- | --- |
| Always required | `git`, `jq`, `herdr`, compatible `tasks-axi`, and `treehouse` |
| At least one of | `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, or `kimi` |
| Additionally required on macOS | `lsof`, so the doctor and guard can prove which process owns the session socket |

## Provision a route

1. Create and fill the normal secondmate charter first.
2. Then run:

```sh
bin/fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
```

| Argument | Meaning |
| --- | --- |
| `<remote-root>` | The remote Firstmate code clone that supplies tracked scripts. |
| `<remote-home>` | A separate absolute path for the persistent secondmate home that must not overlap the code root. |

### Project origins

Name each project's origin as `<project>=<origin-url>`.
Resolve the concrete origin from any of these sources rather than imposing one URL template:

- The captain.
- The project registry.
- An existing clone anywhere.
- The forge.
- An explicit paste.

Seeding a project this machine has never cloned needs no clone under `projects/`, no `no-mistakes` initialization here, and no fleet sync first.
A bare `<project>` is still accepted when this machine happens to have `projects/<project>`.
That clone's configured origin is then read instead of being retyped.

### Origin validation

[`bin/fm-project-origin-lib.sh`](../bin/fm-project-origin-lib.sh) owns which URLs are accepted.
It decides on structure and safety alone, so no forge, domain, or host is privileged and a self-hosted server works exactly as a hosted one does.
The primary validates every resolved origin before transport, and the receiving host validates it again before cloning.

### Delivery mode

The project's registered delivery mode still comes from this machine's `data/projects.md`.
So each of these projects is refused rather than provisioned:

- An unregistered project.
- A `local-only` project.
- A project whose registry entry does not resolve to a delivery posture at all.

### What the seed does

The seed takes these steps:

1. It records `host:`, `root:`, and `home:` in `data/secondmates.md`.
2. It gates the host on readiness.
3. It sends a bounded manifest.
4. It lets the remote host clone its own Firstmate home and project origins.

It does not copy project trees or the primary process environment.
In the primary home, its durable registration effects are limited to that route and the charter brief under `data/<id>`.
Launch records are created only when the secondmate is launched.

### The seed's readiness gate

The seed gates readiness in these steps:

1. The seed runs a read-only check.
2. When that check reports a gap, it runs `--fix`.
3. It then runs a second read-only check, whose verdict decides.

So the operator never has to run the repair by hand, and a repair is never trusted on its own word.
When a host stays red, the seed prints the doctor's remaining gaps and their operator steps, restores the registry, and creates nothing on the remote host.

### Failure and rollback

A known provisioning failure rolls back the new route.
A new remote home is published only after its checkout is complete, so removing the public path during cloning cannot interrupt the clone.
If a competing home appears before publication, provisioning fails and leaves that home intact.
SSH exit 255 preserves the route, because remote completion is unknown and must be reconciled on the same host.

### The parent record

Seeding also writes a durable `.fm-secondmate-parent` record next to the home's `.fm-secondmate-home` identity marker.
That record names this home's route to its parent as `local` or `remote`.
The promised-public-reply subsystem is same-filesystem by construction, so a remote route can never carry a delegated public-reply promise.
`bin/fm-teardown.sh`'s cleanup gate reads this record to treat a remote parent as out of scope rather than an unresolved binding.

### Local and remote routes together

Local secondmates keep the existing route form and need no migration.
A fleet may contain local and remote routes together.
Use `bin/fm-home-seed.sh validate` to validate either form.

## Normal operation

### Launch or recover

Launch or recover the remote second mate with the same command used for a local route:

```sh
bin/fm-spawn.sh <id> --secondmate
```

The primary then takes these steps:

1. It resolves the verified secondmate harness and optional model and effort.
2. It runs the same readiness gate the seed runs.
3. It transfers the inherited-material allowlist.
4. It asks the remote host to launch on Herdr in `fm-remote`.

All remote secondmates on one host share `fm-remote` and retain separate `2ndmate-<id>` workspaces inside it.

### Refused and unsupported launches

- An explicit request for any other backend is refused rather than honored, and the remote host refuses one too.
- An existing remote endpoint recorded in another Herdr session, including `default`, is classified as unverified and left untouched.
  Launch, liveness recovery, control, and retirement refuse it until an operator explicitly migrates it, instead of attempting a live cutover.
- A launch after a host has drifted out of readiness fails with the doctor's own gap text instead of leaving a half-created endpoint.
- Raw launch commands are not accepted for remote secondmates.
- Backends that already refuse secondmate launch, currently Orca and cmux, remain unsupported on the remote host.

### Liveness recovery

Startup liveness recovery relaunches a dead or missing remote second mate through this same command.
So recovery passes the same readiness gate rather than a weaker one.

The watcher's liveness tick applies the identical rule during ordinary supervision through the shared `bin/fm-secondmate-liveness-lib.sh`:

- The remote endpoint is probed read-only once per cadence.
- Only a positive `dead` or `missing` reply relaunches through that command.
- An unreachable transport or inconclusive state is left untouched rather than replaced locally.

### Inventory reconcile for markerless routes

A persistent remote route's parent metadata intentionally has no local spawn-generation marker.
It identifies the route by its recorded host instead.
The Bearings inventory-reconcile hook therefore handles these markerless routes as follows:

- It accepts them.
- It revalidates the sampled host at delivery.
- It refuses a route that changed hosts.

[`fm-secondmate-reconcile.sh`](../bin/fm-secondmate-reconcile.sh) owns the exact cooldown, identity, and reporting contract.

### Send a routed request

Send routed requests normally:

```sh
FM_HOME=<primary-home> bin/fm-send.sh fm-<id> '<request>'
```

The [`fm-send.sh` header](../bin/fm-send.sh) owns the exact delivery-status contract.
A routed request is delivered as a durable record in the remote home's steering inbox plus a best-effort doorbell, a constant line rung into the terminal.
It is never delivered by typing the payload into the pane.
Exit 0 means the record durably exists.

### Retries and safe resends

Every remote transport attempt is bounded by `FM_SEND_REMOTE_BUDGET`.
The `fm-send.sh` header owns the setting's default and validation contract.

| Outcome | Retry behavior |
| --- | --- |
| Unconfirmed SSH transport (exit 255) | Retried identically once. |
| Budget expiry | Not retried, because completion is unknown. |

Either outcome preserves this ordinary reply-bearing request's pending-reply expectation for the record that may have landed.

If delivery remains unconfirmed, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe to run later.
That command preserves the request body and lets the remote enqueue deduplicate onto the same record.
A plain rerun mints a different correlation and is not idempotent.
When deduplication finds that the worker already moved the matching record into `handled/`, the resend exits successfully without ringing the doorbell again.

### Swallowed doorbells

The remote host runs no doorbell re-ring ladder of its own.
A swallowed doorbell for an ordinary reply-bearing request surfaces through the parent's pending-reply recovery and escalation.
Its recovery request rings the doorbell again when it is enqueued.

### Remote reads

`fm-peek.sh` and `fm-crew-state.sh` route remote-secondmate reads to the endpoint's host instead of consulting local worktree or backend state.
An unreachable or unreadable remote read is unknown, not evidence that the endpoint is dead.

### Replies and the parent channel

Marked requests keep the existing correlation contract.
The remote charter appends replies to `state/parent-replies.status` in the remote home.
The remote home's own outcome publishers append there too, through the channel contract in `bin/fm-parent-channel-lib.sh` ([secondmate-parent-channel.md](secondmate-parent-channel.md)).
The remote charter also names its steering inbox as `state/parent-route/<id>.inbox` in the remote home.
That inbox is the record surface the routed transport writes to, so a steer never lands on a parent-home path the remote host cannot reach.

### How remote lines are mirrored

A process-event source takes these steps:

- It performs a non-destructive, cursor-anchored delta read.
- It fetches the documents a line explicitly offers through the confined reader.
- It mirrors content-bearing lines into the primary status channel.
- It does not carry blank separators.

Only a structured `report=data/....md` pointer offers a document.
A bare path inside prose is a mention.
So writing about a document, including one the mate has not created yet, never asks this channel to fetch it.

### Replay identity

Each normalized source line, before its delivered `report=` pointers are rewritten, is the replay identity.
Once committed, that identity prevents an ingestion retry or whole-log recapture from appending a second spelling when document availability changes.
Its record survives reply-adapter retirement alongside the parent status stream.

For lines mirrored before this source-line record existed, exact mirrored bytes remain the compatibility fallback.
The first whole-log recapture after upgrading can therefore append one duplicate, in the original source spelling, for a legacy line whose bare `data/*.md` mention was previously fetched and rewritten.
If that line was a since-resolved decision, the duplicate can read as reopening it.
Recording that source line prevents another duplicate on later recaptures.

### Status, decisions, and correlation

The channel carries the mate's status and decision model.
An uncorrelated progress line and a newly raised `needs-decision` travel the same path as a correlated answer, and reach the parent's open-decision fold identically.
Correlation is a per-line property that settles a pending request.
It is never a gate on the stream, so no single line can stop or wedge the relay or hold the cursor back.

### Transport normalization

| Bytes | Result |
| --- | --- |
| NUL, every other C0 control except tab and newline, and DEL | Transport normalization rewrites them to `?`. |
| Printable ASCII and all high bytes, including UTF-8 | They pass through unchanged. |

### When an offered document cannot be fetched

If the confined remote reader cannot deliver an offered document, the channel fails open instead of stalling the stream:

- The mate's line is mirrored with its original pointer.
- The cursor still advances.
- The adapter appends one unkeyed note carrying the reader's own reason.

That note never enters the open-decision fold, because the reader cannot tell a report that is still being written from one that will never exist.
A decision raised on that ambiguity could stand open describing a transfer that later succeeded.

A refused document is not re-attempted automatically.
It stays on the remote, and a later structured offer of the same path fetches it.
An SSH exit status of 255 while fetching a referenced document leaves the delta uncommitted for the process-event runner's normal retry, because remote completion is unknown.

### Reply settlement

The process-event runner applies each captured delta through this adapter as soon as it is captured.
So a mirrored reply reaches the primary status channel without depending on the wake handler running the adapter itself.
A mirrored line that carries a correlation token settles its pending-reply record and closes that request's own open escalation decision.

A remote reply reaches the primary only through this asynchronous mirror.
Because of that, the primary treats a missing correlated report as a missed report only once the mirror has been read through the end of the remote log after that turn ended.
A remote mate that did answer is therefore never asked to repost while its answer is still in flight.
A genuinely missing answer still gets exactly one repost once the mirror is known to be current.

The [process-to-event operating contract](configuration.md#process-to-event-sources-stateprocevent) owns automatic application, one-announcement replay deduplication, and the unhandled fallback path.

### Source log continuity

The source log is never truncated or consumed.
A shortened or changed prefix stops the relay and surfaces a continuity failure instead of silently resetting the cursor.

### SSH exit 255 and unavailable homes

An SSH exit status of 255 always means transport failure or unknown remote completion.
The underlying `fm-on` transport never retries automatically, but `fm-send` retries its correlation-preserving steering-inbox leg exactly once.
Semantic callers preserve the route or pending request:

- An operation that is not idempotent requires same-host reconciliation rather than a blind resend.
- An unconfirmed steer may be retried only through the correlation-preserving command described above.

An unavailable remote home is projected as unknown and is never replaced by a local second mate.

## Backlog handoff

Move already-judged queued work with the normal command:

```sh
bin/fm-backlog-handoff.sh <id> <item-key>...
```

For a remote route, the handoff takes these steps:

1. `tasks-axi mv` first moves the dependency-closed set atomically from the primary backlog into `data/handoff/<id>.outbox.md`.
2. The outbox is then copied to the remote handoff scratch directory.
3. `fm-backlog-receive.sh` atomically ingests every destination-absent key (a key the remote backlog does not already hold) under the remote backlog's own lock.

The [`bin/fm-backlog-handoff.sh`](../bin/fm-backlog-handoff.sh) header owns remote outbox release after receipt and stable wake-correlation retry behavior.
Bootstrap retries pending outboxes and wakes, and emits `SECONDMATE_HANDOFF:` only when an outbox remains.
There is no two-phase journal and no additional tasks-axi release requirement.

## Sync, update, and retirement

### Inherited-material transfer

Locked startup convergence and `bin/fm-config-push.sh` transfer only the declared inherited-material allowlist.
Changed live routes receive a marked instruction to re-read the transferred files.
The primary records that remote nudge before delivery and retries it during locked startup convergence after a failed send.
Local secondmates retain their generation-specific local pointer contract.
Remote transfers do not copy those primary-local instruction paths.

### Relaunch a live remote second mate

A live remote second mate is restarted with `relaunch`, which runs the ordinary [control plane](agent-control.md) on that host.
The endpoint record there was written by a host-local launch and carries no remote placement.
So the transaction, its checkpoint, and its postconditions are the local ones.

The primary passes `<harness> <model|default|-> <effort|default|->` explicitly, using `default` when an axis has no parent pin.
It passes them explicitly because `config/secondmate-harness` is not inherited into a second mate's home, and the file on that host belongs to a different home.
Letting the far side re-resolve it would silently move the mate onto another runtime.
SSH exit 255 leaves completion unknown and the route preserved, exactly as every other verb here.
Move a live remote second mate onto a newly pinned harness, model, or effort with [`bin/fm-remote-secondmate-relaunch.sh`](../bin/fm-remote-secondmate-relaunch.sh) rather than calling `relaunch` through `fm-on.sh` directly: the host-local relaunch it drives can only rewrite the host's own endpoint record, so this wrapper reads the confirmed identity back from that record afterward and republishes the primary's own route metadata to match, the same way launch already records a fresh route.

### Firstmate code convergence

Session start and every remote launch converge the persistent remote home on the primary's own default-branch commit rather than on the Firstmate copy that host keeps.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the guarded convergence contract, including the distinct `/updatefirstmate` behavior, and [`bin/fm-remote-secondmate-control.sh`](../bin/fm-remote-secondmate-control.sh) owns the commit-import mechanics.
Neither session start nor launch moves the host's own Firstmate copy.
An unsafe or unavailable target is reported and left untouched.
A completed sync reports which watched instruction paths its advance changed.
The primary needs that fact because it cannot diff a checkout it cannot read.
It uses the fact to decide whether the running remote agent must be replaced to actually reload.

### Retire a remote second mate

Retire a remote second mate with the normal guarded command:

```sh
bin/fm-teardown.sh <id> --retire-secondmate <id>
```

The `--retire-secondmate` value must name the exact home being retired; a remote route carries the same per-target authority as a local one, and the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns that contract.
Retirement is executed on the configured host.
It refuses while any of these holds:

- The remote home has child work.
- The primary has an unfinished backlog outbox.
- A routed reply remains unresolved.

It closes only the retiring secondmate's panes or `2ndmate-<id>` workspace in `fm-remote`.
It never stops the shared session or removes a sibling secondmate's workspace or panes.
SSH exit 255 preserves both the route and local records because completion is unknown.
`--force` remains the explicit discard path and requires the same captain authority as local secondmate discard.

No generic remote delete or write surface exists:

- Remote writes are confined to inherited allowlist files and backlog handoff scratch files.
- Remote home removal is reachable only through guarded secondmate retirement.

## Verification

### Portable tests

The portable tests use these pieces:

- The real entrypoint protocol.
- Real git repositories.
- A deterministic SSH boundary.
- A stateful host-local Herdr CLI fixture.
- A controlled account fixture for the readiness gate.

The lifecycle test covers seeding a registered project that this machine has never cloned.
It asserts that the local project tree is unchanged afterwards.
It carries Bitbucket, self-hosted, and scp-like origins through to the remote clone.
The portable tests run with these commands:

```sh
bin/fm-test-run.sh tests/fm-on.test.sh
bin/fm-test-run.sh tests/fm-send-remote-delivery.test.sh
bin/fm-test-run.sh tests/fm-secondmate-reconcile.test.sh
bin/fm-test-run.sh tests/fm-peek-remote.test.sh
bin/fm-test-run.sh tests/fm-crew-state.test.sh
bin/fm-test-run.sh tests/fm-remote-job.test.sh
bin/fm-test-run.sh tests/fm-remote-transport-lanes.test.sh
bin/fm-test-run.sh tests/fm-remote-doctor.test.sh
bin/fm-test-run.sh tests/fm-remote-herdr-guard.test.sh
bin/fm-test-run.sh tests/fm-project-origin.test.sh
bin/fm-test-run.sh tests/fm-secondmate-sync.test.sh
bin/fm-test-run.sh tests/fm-remote-reply.test.sh
bin/fm-test-run.sh tests/fm-remote-backlog-handoff.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-lifecycle-e2e.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-trace-context.test.sh
```

### What the portable tests cannot prove

The doctor performs these account-level checks, and they are only ever exercised against fixtures here:

- A real Aqua login session.
- A real `launchctl` domain.
- A real herdr server.

So the readiness gate's behavior on a genuine Mac remains an operator-run smoke test.
The audit-session facts the guard relies on are recorded with their commands in [runtime backend verification](verification/runtime-backends.md#fm-remote-server-birth-and-login-keychain-access).

### Real-host smoke test

For a real-host smoke test:

1. Provision a disposable remote account and project.
2. Run the doctor and its repair against that account.
3. Launch the second mate.
4. Send one marked request.
5. Verify its correlated reply and structured fleet projection.
6. Simulate an unreachable host to confirm unknown-without-failover behavior.
7. Retire only after the remote queue is empty.

The deterministic suite is automated.
Real-host validation is still an operator-run smoke test and is not claimed by the repository tests.
