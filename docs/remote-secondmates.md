# Remote second mates

Remote second mates place a whole persistent Firstmate home on another SSH-reachable host.
The primary still owns routing and supervision, while the remote home owns its own projects, backlog, workers, and local session backend.
Remote placement is a separate dimension from that host-local backend: a route can target one SSH host while the remote home uses tmux, Herdr, or another secondmate-capable backend.
Firstmate does not support placing an individual worker remotely or failing a remote route over to a local replacement.

## Prerequisites

Configure an SSH alias in the primary account's normal OpenSSH configuration.
Use ordinary public-key authentication, strict host-key verification, and a dedicated remote account where practical.
Do not enable agent forwarding for Firstmate.
`fm-on.sh` also disables agent forwarding, forwarding setup, and configured `SendEnv` patterns on every call.

Clone Firstmate on the remote host at an absolute code-root path.
Expose that clone's fixed entrypoint on the account's non-interactive SSH `PATH`, for example:

```sh
mkdir -p ~/.local/bin
ln -s /absolute/path/to/firstmate/bin/fm-remote-entrypoint.sh ~/.local/bin/fm-remote-entrypoint.sh
```

The entrypoint accepts encoded argv for genuine executable `bin/fm-*.sh` files only.
It never accepts a shell command string and starts the selected script with a minimal environment containing only fixed `PATH`, `HOME`, `FM_HOME`, and `FM_ROOT_OVERRIDE` values.
The remote account must provide Firstmate's universal toolchain, the selected worker runtime, the selected session backend, and credentials that work on that host.
Project origin URLs recorded by the primary must be reachable from the remote account because projects are cloned on that host rather than copied from the primary.

## Non-interactive tool contract

No login or interactive shell ever runs on the remote host, so `~/.profile`, `~/.bashrc`, and `~/.zshrc` never contribute to the runtime `PATH`.
`bin/fm-remote-entrypoint.sh` is the single owner of the `PATH` its children receive and composes it in this order:

1. `<remote-root>/bin`.
2. The account's `~/.local/bin`, always included so an account can add tools without changing this contract.
3. Each of `~/.nix-profile/bin`, `/etc/profiles/per-user/<account>/bin`, `/run/current-system/sw/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`, in that order, and only when the directory exists on the host.
4. The system tail `/usr/bin:/bin:/usr/sbin:/sbin`.

Repeated directories are collapsed to their first position, so the order above is exactly what a remote command sees.
The entrypoint resolves `git` from the operator directories in steps 2 through 4 for tracked-command authorization, then prepends `<remote-root>/bin` only for the authorized child.
A checkout-local `bin/git` therefore cannot authorize an untracked command, and a host with no operator `git` receives an install-or-wrapper diagnostic before command execution.

A tool that only exists inside a version manager - nvm, asdf, or mise - never resolves under that contract, because those managers publish their shims through shell initialization.
The supported escape hatch is a wrapper in `~/.local/bin` rather than special-casing a version manager inside the entrypoint:

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

Check any host against the real contract:

```sh
bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh
```

The doctor is read-only.
It prints the exact `PATH` its own entrypoint launch produced, then reports where each required and optional tool resolved.
It exits non-zero and names every required tool that did not resolve, so the output is the install-or-shim list for that host.

## Provision a route

Create and fill the normal secondmate charter first, then run:

```sh
bin/fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>...|--no-projects}
```

`<remote-root>` is the remote Firstmate code clone that supplies tracked scripts.
`<remote-home>` is a separate absolute path for the persistent secondmate home and must not overlap the code root.
The seed records `host:`, `root:`, and `home:` in `data/secondmates.md`, preflights the host with `fm-remote-doctor.sh`, sends a bounded manifest, and lets the remote host clone its own Firstmate home and project origins.
A failing preflight prints the doctor's missing-tool list, restores the registry, and creates nothing on the remote host.
It does not copy project trees or the primary process environment.
A known provisioning failure rolls back the new route, while SSH exit 255 preserves it because remote completion is unknown and must be reconciled on the same host.

Local secondmates keep the existing route form and need no migration.
A fleet may contain local and remote routes together.
Use `bin/fm-home-seed.sh validate` to validate either form.

## Normal operation

Launch or recover the remote second mate with the same command used for a local route:

```sh
bin/fm-spawn.sh <id> --secondmate
```

The primary resolves the verified secondmate harness and optional model and effort, transfers the inherited-material allowlist, and asks the remote host to launch through that home's ordinary backend selection.
Raw launch commands are not accepted for remote secondmates.
Backends that already refuse secondmate launch, currently Orca and cmux, remain unsupported on the remote host.

Send routed requests normally:

```sh
FM_HOME=<primary-home> bin/fm-send.sh fm-<id> '<request>'
```

Marked requests keep the existing correlation contract.
The remote charter appends replies to `state/parent-replies.status` in the remote home.
A process-event source performs a non-destructive, cursor-anchored delta read, validates bounded correlated status lines, fetches only referenced `data/*.md` documents through the confined reader, and appends each accepted line at most once to the primary status channel.
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
SSH exit 255 preserves both the route and local records because completion is unknown.
`--force` remains the explicit discard path and requires the same captain authority as local secondmate discard.
No generic remote delete or write surface exists: remote writes are confined to inherited allowlist files and backlog handoff scratch files, and remote home removal is reachable only through guarded secondmate retirement.

## Verification

The portable tests use the real entrypoint protocol, real git repositories, a deterministic SSH boundary, and a host-local backend fixture:

```sh
bin/fm-test-run.sh tests/fm-on.test.sh
bin/fm-test-run.sh tests/fm-remote-reply.test.sh
bin/fm-test-run.sh tests/fm-remote-backlog-handoff.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-lifecycle-e2e.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-trace-context.test.sh
```

For a real-host smoke test, provision a disposable remote account and project, launch the second mate, send one marked request, verify its correlated reply and structured fleet projection, simulate an unreachable host to confirm unknown-without-failover behavior, then retire only after the remote queue is empty.
The deterministic suite is automated; real-host validation is still an operator-run smoke test and is not claimed by the repository tests.
