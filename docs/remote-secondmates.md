# Remote second mates

Remote second mates place a whole persistent Firstmate home on another SSH-reachable host.
The primary still owns routing and supervision, while the remote home owns its own projects, backlog, and workers.
Firstmate does not support placing an individual worker remotely or failing a remote route over to a local replacement.

The remote second-mate agent itself always runs on the [Herdr backend](herdr-backend.md) in the shared `fm-remote` session, and every path that provisions or launches one refuses a host that is not ready for it.
`fm-remote` is reserved for remote fleet work and must not be used for personal work.
The user's interactive Herdr session remains `default` and is not a remote-secondmate prerequisite.
Herdr's remote-session server belongs to the host's own GUI login session rather than to the SSH connection, so the agent's endpoint survives every disconnection the primary's supervision depends on.
Local second mates are unaffected and keep their ordinary backend and session selection, as do the workers a remote second mate supervises inside its own home.

## Prerequisites

Configure an SSH alias in the primary account's normal OpenSSH configuration.
Use ordinary public-key authentication, strict host-key verification, and a dedicated remote account where practical.
Do not enable agent forwarding for Firstmate.
`fm-on.sh` also disables agent forwarding, forwarding setup, and configured `SendEnv` patterns on every call, and arms bounded SSH dead-peer detection so a vanished host (a reboot, a dropped link) fails within a bounded window instead of hanging indefinitely; its [script header](../bin/fm-on.sh) owns the keepalive defaults and environment overrides.

Clone Firstmate on the remote host at an absolute code-root path.
Expose that clone's fixed entrypoint on the account's non-interactive SSH `PATH`, for example:

```sh
mkdir -p ~/.local/bin
ln -s /absolute/path/to/firstmate/bin/fm-remote-entrypoint.sh ~/.local/bin/fm-remote-entrypoint.sh
```

The entrypoint accepts encoded argv for genuine executable `bin/fm-*.sh` files only.
It never accepts a shell command string.
The readiness-owning doctor runs over this plain SSH bootstrap so read-only mode can report worker gaps and `--fix` can install or repair the worker.
The entrypoint authorizes that bootstrap with normal git tracking when git resolves and with its pinned doctor digest when doctor must report that git itself is missing.
After setup, every other command verifies Firstmate's account-owned remote job worker, stages the encoded argv and stdin bytes, waits for its result, and relays stdout, stderr, and the exit status separately.
On macOS the worker is `dev.firstmate.remote-job`, an Aqua-scoped LaunchAgent at `~/Library/LaunchAgents/dev.firstmate.remote-job.plist` with logs under `~/Library/Logs/`.
After that bootstrap every non-doctor `fm-on.sh` target runs through that worker in the remote account's GUI session, never in the SSH process or a Herdr pane.
The worker runs one staged job at a time and preempts a running reply long-poll as soon as any command other than another reply long-poll is queued, so interactive commands and startup checks are never serialized behind a poll window.
`bin/fm-remote-job-lib.sh` owns that preemption contract and distinguishes preemption from a wait window that closes with no data, so only a genuinely quiet window proves channel freshness while either outcome can re-arm without losing data.
Linux uses the same queue and worker protocol without the Aqua-session requirement.
A worker stops itself once its configured code root stops being a Firstmate checkout, so a worker started from a worktree cannot outlive that worktree, and `bin/fm-remote-job-reap-orphans.sh` clears any worker already left behind that way without ever touching one whose checkout still exists.
The remote account must provide the required toolchain, the selected worker runtime, the selected session backend, and credentials that work on that host.
The origin URL named for each project must be reachable from the remote account because projects are cloned on that host rather than copied from the primary.

## Non-interactive tool contract

No login or interactive shell ever runs on the remote host, so `~/.profile`, `~/.bashrc`, and `~/.zshrc` never contribute to the runtime `PATH`.
`bin/fm-remote-job-lib.sh` is the single owner of the worker `PATH` and builds it by filesystem discovery rather than by evaluating shell startup files.
The authorized child sees `<remote-root>/bin` first, then a genuine account `~/.local/bin`, the nvm default version bin, asdf shims and install bins, mise shims and install bins, Nix directories, Homebrew directories, and the system tail `/usr/bin:/bin:/usr/sbin:/sbin`.
Nvm selection follows the filesystem `alias/default` chain and chooses the highest matching installed semantic version, falling back to the highest installed semantic version when the alias is absent or has no installed match.
An nvm `system` default adds no nvm version bin, so the later system directories provide Node.
The Nix and package-manager order after version-manager discovery is `~/.nix-profile/bin`, `/etc/profiles/per-user/<account>/bin`, `/run/current-system/sw/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`.
Exact repeated entries are omitted.
For the three Nix locations, a final `bin` symlink is resolved to its physical directory, while a path reached through symlinked ancestors remains in its documented position.
Other final-component symlink directories, including `~/.local/bin`, are excluded.
The entrypoint resolves `git` only from the operator portion before prepending `<remote-root>/bin` for the authorized child.
A checkout-local `bin/git` therefore cannot authorize an untracked command, and a host with no operator `git` receives an install-or-wrapper diagnostic before command execution.

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

Replace the placeholder with the remote account's selected nvm version.
For asdf or mise, use the same shape with the selected version's absolute `bin` directory, one wrapper per tool the remote home actually needs.
The wrapper must execute that absolute target rather than resolving its own name again through `~/.local/bin`.

## Readiness, repair, and the human steps

`bin/fm-remote-doctor.sh` is the single owner of what "ready for a remote second mate" means.
Check any host against it directly:

```sh
bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh
```

That run is read-only.
It prints the exact `PATH` its own entrypoint launch produced, executes its required-tool probe through the installed worker when one is available, reports where each required and optional tool resolved, then reports one line per readiness check.
Each gap is tagged `fixable:` when `--fix` can close it or `human:` when only a person at that machine can, and every gap is followed by an `action:` line naming the exact step.
Any remaining gap exits non-zero.
The script's own header owns the full line protocol.

`--fix` repairs only the automatable gaps and is safe to rerun:

```sh
bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh --fix
```

Over the plain SSH doctor bootstrap, it writes and reloads the Firstmate-owned `dev.firstmate.remote-job` and `dev.firstmate.herdr.fm-remote` launch agents on macOS, both scoped with `LimitLoadToSessionType=Aqua` and bootstrapped in `gui/<uid>`.
It starts the same workers directly on Linux, recreates the `~/.local/bin/fm-remote-entrypoint.sh` symlink when it is absent, and creates only Firstmate-owned required-tool wrappers that it can prove resolve to a version-manager target, stopping after one harness satisfies the at-least-one requirement.
It never installs packages or overwrites a non-Firstmate file at a reserved wrapper path.
The dedicated Herdr launch agent owns only the remote-secondmate `fm-remote` server and does not inspect, rewrite, start, stop, or require the user's interactive `default` session or its `dev.firstmate.herdr` launch agent.
It re-derives every check from the host afterwards, so what it prints is the state after the repair rather than the intent of one.

These steps are never automated and are always reported rather than silently attempted, because SSH cannot create a GUI session from nothing:

- The first console login on that Mac, and automatic login in System Settings > Users & Groups when the machine runs headless and must come back on its own after a reboot.
- FileVault, which holds a reboot at pre-boot authentication before any login session exists.
- Installing any missing required tool that no safe wrapper can resolve.
- The required remote tool set is `git`, `jq`, `herdr`, compatible `tasks-axi`, `treehouse`, and at least one of `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, or `kimi`.
- Each worker runtime's own `/login`, and any keychain password prompt that login needs.

Firstmate never writes an auto-login password, never changes FileVault, and never stores an account password.
A file at `~/.local/bin/fm-remote-entrypoint.sh` that is not Firstmate's own symlink is reported for the operator to inspect and is never overwritten.

## Provision a route

Create and fill the normal secondmate charter first, then run:

```sh
bin/fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
```

`<remote-root>` is the remote Firstmate code clone that supplies tracked scripts.
`<remote-home>` is a separate absolute path for the persistent secondmate home and must not overlap the code root.

Name each project's origin as `<project>=<origin-url>`.
Resolve the concrete origin from the captain, the project registry, an existing clone anywhere, the forge, or an explicit paste rather than imposing one URL template.
Seeding a project this machine has never cloned needs no clone under `projects/`, no `no-mistakes` initialization here, and no fleet sync first.
A bare `<project>` is still accepted when this machine happens to have `projects/<project>`, whose configured origin is then read instead of being retyped.
[`bin/fm-project-origin-lib.sh`](../bin/fm-project-origin-lib.sh) owns which URLs are accepted; it decides on structure and safety alone, so no forge, domain, or host is privileged and a self-hosted server works exactly as a hosted one does.
The primary validates every resolved origin before transport, and the receiving host validates it again before cloning.
The project's registered delivery mode still comes from this machine's `data/projects.md`, so an unregistered or `local-only` project is refused rather than provisioned.

The seed records `host:`, `root:`, and `home:` in `data/secondmates.md`, gates the host on readiness, sends a bounded manifest, and lets the remote host clone its own Firstmate home and project origins.
In the primary home, its durable registration effects are limited to that route and the charter brief under `data/<id>`; launch records are created only when the secondmate is launched.
Readiness starts with a read-only check; when that check reports a gap, it runs `--fix` and then a second read-only check whose verdict decides, so the operator never has to run the repair by hand and a repair is never trusted on its own word.
A host that stays red prints the doctor's remaining gaps and their operator steps, restores the registry, and creates nothing on the remote host.
It does not copy project trees or the primary process environment.
A known provisioning failure rolls back the new route, while SSH exit 255 preserves it because remote completion is unknown and must be reconciled on the same host.

Seeding also writes a durable `.fm-secondmate-parent` record next to the home's `.fm-secondmate-home` identity marker, naming this home's route to its parent as `local` or `remote`.
The promised-public-reply subsystem is same-filesystem by construction, so a remote route can never carry a delegated public-reply promise; `bin/fm-teardown.sh`'s cleanup gate reads this record to treat a remote parent as out of scope rather than an unresolved binding.

Local secondmates keep the existing route form and need no migration.
A fleet may contain local and remote routes together.
Use `bin/fm-home-seed.sh validate` to validate either form.

## Normal operation

Launch or recover the remote second mate with the same command used for a local route:

```sh
bin/fm-spawn.sh <id> --secondmate
```

The primary resolves the verified secondmate harness and optional model and effort, runs the same readiness gate the seed runs, transfers the inherited-material allowlist, and asks the remote host to launch on Herdr in `fm-remote`.
All remote secondmates on one host share `fm-remote` and retain separate `2ndmate-<id>` workspaces inside it.
An explicit request for any other backend is refused rather than honored, and the remote host refuses one too.
An existing remote endpoint recorded in another Herdr session, including `default`, is classified as unverified and left untouched; launch, liveness recovery, control, and retirement refuse it until an operator explicitly migrates it instead of attempting a live cutover.
A launch after a host has drifted out of readiness fails with the doctor's own gap text instead of leaving a half-created endpoint.
Raw launch commands are not accepted for remote secondmates.
Backends that already refuse secondmate launch, currently Orca and cmux, remain unsupported on the remote host.

Startup liveness recovery relaunches a dead or missing remote second mate through this same command, so recovery passes the same readiness gate rather than a weaker one.

Send routed requests normally:

```sh
FM_HOME=<primary-home> bin/fm-send.sh fm-<id> '<request>'
```

The [`fm-send.sh` header](../bin/fm-send.sh) owns the exact delivery-status contract.
When the verified remote endpoint accepts the text and Enter but synchronous submit confirmation remains pending, the primary reports the request as delivered rather than failed; do not resend it, because its pending-reply expectation remains armed.
`fm-peek.sh` and `fm-crew-state.sh` route remote-secondmate reads to the endpoint's host instead of consulting local worktree or backend state.
An unreachable or unreadable remote read is unknown, not evidence that the endpoint is dead.

Marked requests keep the existing correlation contract.
The remote charter appends replies to `state/parent-replies.status` in the remote home.
A process-event source performs a non-destructive, cursor-anchored delta read, fetches only referenced `data/*.md` documents through the confined reader, mirrors every content-bearing line at most once into the primary status channel, and does not carry blank separators.
The channel carries the mate's status and decision model: an uncorrelated progress line and a newly raised `needs-decision` travel the same path as a correlated answer, and reach the parent's open-decision fold identically.
Correlation is a per-line property that settles a pending request; it is never a gate on the stream, so no single line can stop or wedge the relay or hold the cursor back.
Transport normalization rewrites NUL, every other C0 control except tab and newline, and DEL to `?`, while printable ASCII and all high bytes, including UTF-8, pass through unchanged.
If the confined remote reader permanently refuses a referenced document, the mate's line is mirrored with its original pointer and the adapter appends one keyed escalation naming the gap instead of stalling the stream.
An SSH exit status of 255 while fetching a referenced document leaves the delta uncommitted for the process-event runner's normal retry because remote completion is unknown.
The process-event runner applies each captured delta through this adapter as soon as it is captured, so a mirrored reply reaches the primary status channel without depending on the wake handler running the adapter itself.
A mirrored line that carries a correlation token settles its pending-reply record and closes that request's own open escalation decision.
Because a remote reply reaches the primary only through this asynchronous mirror, the primary treats a missing correlated report as a missed report only once the mirror has been read through the end of the remote log after that turn ended.
A remote mate that did answer is therefore never asked to repost while its answer is still in flight, and a genuinely missing answer still gets exactly one repost once the mirror is known to be current.
The [process-to-event operating contract](configuration.md#process-to-event-sources-stateprocevent) owns automatic application, one-announcement replay deduplication, and the unhandled fallback path.
The source log is never truncated or consumed.
A shortened or changed prefix stops the relay and surfaces a continuity failure instead of silently resetting the cursor.

An SSH exit status of 255 always means transport failure or unknown remote completion.
The transport never retries automatically.
Semantic callers preserve the route or pending request and require same-host reconciliation rather than resending an operation that may already have happened.
An unavailable remote home is projected as unknown and is never replaced by a local second mate.

## Backlog handoff

Move already-judged queued work with the normal command:

```sh
bin/fm-backlog-handoff.sh <id> <item-key>...
```

For a remote route, `tasks-axi mv` first moves the dependency-closed set atomically from the primary backlog into `data/handoff/<id>.outbox.md`.
The outbox is then copied to the remote handoff scratch directory and `fm-backlog-receive.sh` atomically ingests every destination-absent key under the remote backlog's own lock.
Confirmed receipt removes the outbox.
An existing outbox is the complete retry record, and `--resume-pending` safely re-delivers it.
Bootstrap retries pending outboxes and emits `SECONDMATE_HANDOFF:` only when one remains.
There is no two-phase journal and no additional tasks-axi release requirement.

## Sync, update, and retirement

Locked startup convergence and `bin/fm-config-push.sh` transfer only the declared inherited-material allowlist.
Changed live routes receive a marked instruction to re-read the transferred files.
The primary records that remote nudge before delivery and retries it during locked startup convergence after a failed send.
Local secondmates retain their generation-specific local pointer contract; remote transfers do not copy those primary-local instruction paths.

`/updatefirstmate` updates each remote code root from its own origin, then guardedly fast-forwards the persistent remote home to that code-root commit.
Dirty, diverged, unavailable, or otherwise unsafe targets are reported and left untouched.

Retire a remote second mate with the normal guarded command:

```sh
bin/fm-teardown.sh <id>
```

Retirement is executed on the configured host and refuses while the remote home has child work, while the primary has an unfinished backlog outbox, or while a routed reply remains unresolved.
It closes only the retiring secondmate's panes or `2ndmate-<id>` workspace in `fm-remote`; it never stops the shared session or removes a sibling secondmate's workspace or panes.
SSH exit 255 preserves both the route and local records because completion is unknown.
`--force` remains the explicit discard path and requires the same captain authority as local secondmate discard.
No generic remote delete or write surface exists: remote writes are confined to inherited allowlist files and backlog handoff scratch files, and remote home removal is reachable only through guarded secondmate retirement.

## Verification

The portable tests use the real entrypoint protocol, real git repositories, a deterministic SSH boundary, a stateful host-local Herdr CLI fixture, and a controlled account fixture for the readiness gate.
The lifecycle test covers seeding a registered project that this machine has never cloned, asserts that the local project tree is unchanged afterwards, and carries Bitbucket, self-hosted, and scp-like origins through to the remote clone:

```sh
bin/fm-test-run.sh tests/fm-on.test.sh
bin/fm-test-run.sh tests/fm-send-remote-delivery.test.sh
bin/fm-test-run.sh tests/fm-peek-remote.test.sh
bin/fm-test-run.sh tests/fm-crew-state.test.sh
bin/fm-test-run.sh tests/fm-remote-job.test.sh
bin/fm-test-run.sh tests/fm-remote-doctor.test.sh
bin/fm-test-run.sh tests/fm-project-origin.test.sh
bin/fm-test-run.sh tests/fm-remote-reply.test.sh
bin/fm-test-run.sh tests/fm-remote-backlog-handoff.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-lifecycle-e2e.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-trace-context.test.sh
```

The account-level checks the doctor performs - a real Aqua login session, a real `launchctl` domain, and a real herdr server - are only ever exercised against fixtures here, so the readiness gate's behavior on a genuine Mac remains an operator-run smoke test.

For a real-host smoke test, provision a disposable remote account and project, run the doctor and its repair against that account, launch the second mate, send one marked request, verify its correlated reply and structured fleet projection, simulate an unreachable host to confirm unknown-without-failover behavior, then retire only after the remote queue is empty.
The deterministic suite is automated; real-host validation is still an operator-run smoke test and is not claimed by the repository tests.
