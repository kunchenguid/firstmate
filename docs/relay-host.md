# Relay task hosts

How firstmate dispatches a task to another machine over a Bifrost relay while staying the single control plane, and the empirical record behind every design choice in it.

This is a verification document, not a narrative.
Every number below was measured, every refusal below was reproduced, and anything reasoned rather than run is listed under "Not verified" at the end.

Measured 2026-08-01.
Control machine: macOS 26.5.2, arm64, bifrost 0.0.167.
Task host: Debian 5.15, x86_64, bifrost 0.0.165, tmux 3.3a, Claude Code 2.1.220.
Relay: `bifrost.bytedance.net`, an internal address.

## What this is

The control machine keeps the backlog, the watcher, the wake queue, and the merge authority.
A task host runs its own firstmate and its own crewmates.
One fleet operation is one call across the link, and that call runs the host's own `bin/fm-spawn.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`, `bin/fm-peek.sh`, or `bin/fm-teardown.sh`.

Nothing sits at `bin/fm-backend.sh`'s primitive level, and that file is unchanged.
The reason is arithmetic, not taste.
One `fm-send` is at least four backend primitives - read the composer, type, Enter, verify the submit - so a per-primitive proxy costs 4 to 20 seconds streamed, or 16 to 80 seconds buffered, per steer.
As one verb call it costs one round trip.
The measured round trips are below.

A host with a real display adds a desktop host session and three checks it must pass before it may claim work; [`docs/relay-gui-host.md`](relay-gui-host.md) owns that, and a host without `gui` in its record is unaffected by all of it.

| Piece | Where it runs | What it owns |
|---|---|---|
| `bin/fm-relay-lib.sh` | control | the client: host records, verb calls, file put/get, the wake-check body, the queued-dispatch record |
| `bin/fm-relay-conn.sh` | control (+ SSH to the host) | pairing, tightening, the universal grant assertion, deploy |
| `bin/fm-relay-host.sh` | control | one subcommand per fleet operation |
| `bin/fm-relay-check-make.sh` | control | writes and registers the task's wake check |
| `control-root/verbs/fmr-verb.sh` | host | the single allowlisted entry point |
| `control-root/tighten-grants.sh` | host | the two-pass authorization repair |

`--host` on `bin/fm-spawn.sh` dispatches.
`bin/fm-send.sh`, `bin/fm-peek.sh`, `bin/fm-crew-state.sh`, and `bin/fm-teardown.sh` follow the `host=` line in `state/<id>.meta` and delegate.
Without `--host`, none of those paths change.

## Ordered procedure

1. Register the host in `config/relay-hosts.json`; [`docs/configuration.md`](configuration.md) owns that schema.
2. `bin/fm-relay-conn.sh deploy <host>` installs the verb entry point and its config over ordinary SSH.
3. `bin/fm-relay-conn.sh up <host>` pairs, tightens on the target, and asserts that no authorization binds the built-in full-access policy.
4. `bin/fm-brief.sh <id> <repo> [--scout] --host-home <host FM_HOME> --host-root <host firstmate checkout>` writes a brief whose paths are the host's.
5. `bin/fm-spawn.sh --host <host> <id> <project-name-on-host> [--scout] --harness <name>` dispatches; the second positional is a project NAME under the host's own projects directory, not a local path.
6. `bin/fm-relay-check-make.sh <id>` arms the wake path, which is a separate step because a remote crewmate's status file lives on its own machine.
7. Supervise with the ordinary `bin/fm-send.sh`, `bin/fm-peek.sh`, and `bin/fm-crew-state.sh`, which follow `host=` themselves.
8. For a scout, run `bin/fm-relay-host.sh report-pull <id>` before `bin/fm-teardown.sh <id>`; teardown refuses until this side holds a byte-identical copy.

## Layout on a task host

Three directories, and the separation between them is the security model.

```
<control-root>/            outside every file-access root; the caller cannot read or write it
  verbs/fmr-verb.sh        the ONLY thing the caller may execute
  tighten-grants.sh        pairing repair, run over SSH, never over the relay
  config                   FM_ROOT, FM_HOME, HOME_DIR, PATH, LANG, PROJECTS, FLEET_ROOT
  tasks/<id>/              claim marker, ack cursor, staged report hash
<fleet-root>/              the ONLY file-access root
  tasks/<id>/in/           briefs and steers pushed by the control machine
  tasks/<id>/out/          reports and artifacts staged for pull
<host firstmate home>/     the caller cannot reach it at all
  state/<id>.{meta,status} worktrees, panes, everything a local firstmate owns
```

Reading the verb script itself through the file channel returns `[file.out_of_scope]`, verified, so a paired caller cannot fetch, inspect, or rewrite its own verb table.
The same holds for the key directory and the host firstmate home.

## Measured round trips

Cross-machine, control to host, through the real relay.
Each row is n separate process invocations.

| Call | n | Range (s) | Median (s) |
|---|---|---|---|
| local `bifrost status` (no relay) | 3 | 0.118-0.132 | 0.125 |
| `exec --stream` (verb ping) | 10 | 0.964-1.986 | 1.066 |
| `exec` buffered (verb ping) | 10 | 3.954-5.015 | 4.970 |
| `file stat` | 5 | 1.061-2.000 | 1.957 |
| `file read` (25 B) | 10 | 0.936-1.987 | 1.955 |
| `file write` (25 B) | 5 | 1.119-2.129 | 2.010 |
| `file hash` | 5 | 0.978-2.125 | 1.116 |
| `conn status` | 3 | 4.995-5.033 | 5.021 |

Streaming is 4.7x faster than buffering at the median on the same link, so every exec in this design streams.
Whole-operation timings from the acceptance run: a remote spawn including trust handling took 13.3 to 16.2 s, a steer with submit verification took 6.4 s, and a 5 MiB download took 4.10 s.

## Behaviour that decided the design

### `--stream` hides a policy rejection

Streamed, a command the shell allowlist rejects exits 1 with `Network error: stream digest mismatch; output may be incomplete`.
Buffered, the same command exits 254 with the real reason, `shell_text does not match any allowlist rule in policy 'fm-relay-verbs'`.
A remote command's own non-zero exit passes through streaming unchanged, so only rejections are affected.

`fm_relay_exec` therefore streams, and on a failure whose output contains that digest text it repeats the call buffered once to recover the authentic message.

### No environment is inherited, and LANG is load-bearing

The policy layer sets `env_allowlist: []` and `inherit_env: false`, which overrides the profile's own `--env` list.
The complete environment a verb sees:

```
BIFROST_REMOTE=1
OLDPWD=<fleet-root>
PWD=<fleet-root>
SHLVL=1
TERM=dumb
_=/usr/bin/env
```

No `HOME`, no `PATH`, no `LANG`.
`PATH` is the obvious one, and `~/.local/bin` and `~/.npm-global/bin` are absent from a non-interactive shell on the host anyway, so the verb sets `PATH` from its own config before running anything.

`LANG` is the non-obvious one, and its absence fails silently.
Without a UTF-8 locale, tmux replaces the embedded newlines in the multi-line `-F` format that `fm_backend_tmux_target_exists` uses with `_`, collapsing the seven candidate spellings of a target into one underscore-joined line, so the exact-match lookup never matches.
The same `list-panes -a -F` produced 84 lines with `LANG=en_US.UTF-8` and 12 without.
Every live pane then reports `backend target gone` and every remote task looks dead.
The verb exports a UTF-8 locale from its config, and the registry's `lang` field overrides it.

This is not relay-specific.
Any minimal-environment invocation of firstmate, such as cron, launchd, or a bare `env -i`, hits the same thing.

### `conn up` adds a full-access grant, it does not reuse one

A second `bifrost remote conn up` against an already-paired, already-tightened host took the grant count from 1 to 2.
The new grant binds the built-in `ssh-key-full-access` policy - `allow_any_executable: true`, `allowed_shell_patterns: ["^(?s:.*)$"]`, stdin and interactive on, file access read_write over `/` - and a plain `id` executed on the host again.
The tightened grant stayed in the list looking correct throughout.

Three consequences, all enforced in `bin/fm-relay-conn.sh`:

1. The audit question must be universal - does ANY grant bind `ssh-key-full-access` - because a per-grant audit passes on a wide-open machine.
2. It must be asked on the TARGET, because `conn down --all` on the caller revokes only the connection the caller saved.
3. Pairing must be transactional: pair, tighten, re-read, assert, and unpair rather than leave a full-access grant behind on any failure path.

Tightening runs over ordinary SSH, never over the relay, because the verb table exposes no grant management at all.
A paired caller can therefore never widen its own authorization through the channel it was granted.
A host with no SSH route gets `bin/fm-relay-conn.sh tighten-local` printed for its own operator, and pairing refuses rather than reporting a pairing it could not secure.

`control-root/tighten-grants.sh` is two passes because tightening legitimately fails on a superseded grant, for which bifrost answers 409.
Pass one tightens what it can, and pass two revokes anything still bound to the full-access policy and prints every revocation.

The window between pairing and tightening cannot be closed from outside Bifrost, because `ssh-key create` still has no `--roots`, `--ops`, or `--shell-policy` on 0.0.167.

### A "permanent" grant is neither permanent nor unmetered

The grant record reads `grant_mode: permanent`, but it also carries `grant_session_expires_at` 24 hours out and `max_calls: 1000`.
The call budget decrements per remote call: after about ten minutes of this work the same grant read `use_count: 92, remaining_calls: 908`.

So a standing pairing needs periodic re-authorization, and re-authorization means another `conn up`, which means another full-access grant to tighten.
The call budget matters at scale too, because a single remote task polled every 300 s spends 288 calls a day before any spawn, steer, or state read.

### A shell-policy change invalidates the grant

A grant snapshots `shell_policy_set_version_snapshot`.
After editing the allowlist, the next call failed with `shell policy set version changed (grant=12, current=13), reconnect is required`.
Any allowlist edit therefore requires a re-pair, which requires the transactional tighten again.

### `download` is not bounded by `max_read_bytes`; `read` is

With `max_read_bytes = 4194304` and a 5242880-byte file on the host, `file read --allow-binary` returned `[binary content, 4194304 bytes]` - content truncated to the cap - while reporting the true size 5242880 and the true sha256.
A consumer that saved that content without comparing hashes would keep a silently truncated file.
`file download` returned all 5242880 bytes in 4.10 s with `sha256 3ef69aec44b83312 verified`, matching the host's own `sha256sum`.

Artifacts therefore always travel by `download`, never by `read`, and every transfer is hash-compared in both directions.

## The wake path

A remote crewmate's status file and turn-end marker live on its machine, so this home's signal scan cannot see them.
`bin/fm-relay-check-make.sh` writes `state/<id>.check.sh` and registers it through the ordinary `bin/fm-check-register.sh`, so the watcher executes it under the same hash-validated snapshot rule as any other custom check.

The generated file holds per-task parameters and one call into `fm_relay_check_emit`.
Nothing rewrites an armed check, so a judgement inlined there would be frozen at arming time, which is the same reasoning `bin/fm-poll-lib.sh` records.

Two cursors, deliberately different:

- `state/<id>.relay-seen` is what the check has already reported.
  Only the check advances it, so one batch of events produces one wake instead of one per check interval.
- `state/<id>.relay-ack`, mirroring the host's own `tasks/<id>/ack`, is what a supervisor has actually been shown.
  Only an explicit `bin/fm-relay-host.sh ack` advances it, and `events` replays from it, so nothing unpresented is ever skipped.

A read that fails advances neither cursor and prints nothing, because "the link is down" is not "nothing happened".
It is not silently swallowed forever either: after `FM_RELAY_FAIL_WAKE_AFTER` consecutive failures, default 3, the check wakes once with a diagnostic so a task cannot sit unobserved behind a dead link.

The cost, stated plainly: a remote task has no turn-end wake, so wake latency is 0 to `FM_CHECK_INTERVAL`, 300 s by default, instead of seconds.

Crew-authored status text becomes a wake reason on the control machine, so the verb strips control characters, caps each line at 200 characters, and caps the batch before that text ever crosses the link.

## Acceptance run, 2026-08-01

Three real scout tasks on the host, driven end to end from the control machine.

**1. Dispatch.**
`fm-spawn --host box151 relay-probe-a1 firstmate --scout --harness claude` returned `OK spawned=relay-probe-a1` in 13.3 to 16.2 s, and the crewmate did real work in a host worktree.

The trust dialog was exercised deliberately.
In a repository root the host's claude already trusted, the verb reported `trust=working`: no dialog, harness busy.
In a fresh clone at a path claude had never seen, the verb reported `trust=accepted`: it saw the dialog, sent Enter locally at zero relay cost, and the root afterwards appears in the host's own trust store.

An earlier revision of that detector also matched claude's permanent `bypass permissions on (shift+tab to cycle)` footer and so reported `still-showing` on a perfectly healthy launch.
A mode indicator is not a question, so the detector now matches dialog question text only.

**2. Wake.**
`bin/fm-check-register.sh` accepted the generated check, and the real `bin/fm-watch.sh`, armed through `bin/fm-watch-arm.sh`, executed it and queued:

```
1785563030	1	check	.../state/relay-probe-a1.check.sh	check: .../relay-probe-a1.check.sh: relay-probe-a1 on box151: needs-decision: bin/ inventory has 9 readers; also cover bin/backends/ (yes) or stop at bin/ (no)?
```

**3. Steer.**
`fm-send.sh relay-probe-a1 "Decision: no - ..."` returned `OK sent=relay-probe-a1` in 6.4 s.
The host's own fm-send verified the submit, and the host pane shows the line accepted and the crewmate working again.
The steer text never became a shell argument: it was written into the exchange area and the verb received only a reference.

**4. State.**
`fm-crew-state.sh relay-probe-a1` returned `state: parked · source: status-log · bin/ inventory has 9 readers; ...`, produced by the host's own copy of that script.

**5. Report and teardown gate.**
`fm-teardown.sh` refused before the report copy existed, with `error: no local report copy at .../data/relay-probe-a1/report.md; run report-pull first`.
After `report-pull`, both ends read `8075e7795214eb9cc9fbbb95576820dba3dab70b8525f09bbe1a0b3907a672d0`, 9882 bytes.
Teardown then succeeded: window killed, worktree returned to the host's pool, claim released, control-side records cleaned, and the report retained.

**6. Link break.**
With the connection revoked mid-task, four checks printed nothing except the deliberate third-failure diagnostic, `relay-seen` stayed at 99, and the host's ack stayed at 284 while events kept accumulating on the host.
After `fm-relay-conn.sh up`, one check reported the whole backlog in order and `events` replayed exactly the unacknowledged bytes:

```
OK offset=352 new=68
working: link-break probe event 1
working: link-break probe event 2
```

**7. Blind re-dispatch.**
Re-running spawn for a live id exited 1 with `ALREADY_CLAIMED` plus a liveness report carrying the claim timestamp, window, worktree, kind, and current state.
The host kept exactly one window and one claim directory.

**8. End state.**
No grant on either machine binds `ssh-key-full-access`, and every grant is `remote_shell_exec` bound to `fm-relay-verbs` with stdin and interactive off.
Both bifrost daemons kept their pre-work PIDs, 36856 and 2267286, neither opened a listening port, and system proxy stayed disabled on both.

The `RELAY:` bootstrap diagnostic was verified against a deliberately reopened host: a bare `conn up` produced `RELAY: box151: a full-access authorization is live on it; re-run bin/fm-relay-conn.sh up box151`, and the same repair command cleared it back to silence.

### Injection attempts, against the deployed verb

All twelve were rejected with `shell_text does not match any allowlist rule in policy 'fm-relay-verbs'`.

`id`; `cat /etc/passwd`; `<verb> ping; id`; `<verb> ping && id`; `<verb> $(id)`; `` `id` ``; `<verb> ping` followed by a newline and `id`; `<verb> events ../../../../etc/passwd 0`; `<verb>/../verbs/fmr-verb.sh ping`; `<verb> ping >/tmp/pwned`; `<verb> ping | id`; `bash -c id`.

The allowlist pattern is one entry point plus arguments drawn from `[A-Za-z0-9._@=+-]`, which contains no shell metacharacter and no slash.
The verb re-validates every argument itself, which is defence in depth rather than a substitute.

### File-channel boundary, both directions

| Attempt | Result |
|---|---|
| read the host's `~/.ssh/authorized_keys` | `[file.out_of_scope]` |
| read `/etc/passwd` | `[file.out_of_scope]` |
| read a `secret-*` file inside the exchange area | `[file.deny_pattern] (**/secret*)` |
| read the verb entry script | `[file.out_of_scope]` |
| read the peer key file | `[file.out_of_scope]` |
| write outside the exchange area | `[file.out_of_scope]` |

Reproduced control to host and host to control.

## Key material

Each machine generates its own target key, exports it, and hands it to the peer over the pre-existing out-of-band SSH channel.
Never over the relay being established, and never over the relay when rotating.

Where the key file lives, and what that does and does not buy:

- Outside every FileAccessPolicy root, in a mode-700 directory, mode 600.
  Reading it through the relay returns `[file.out_of_scope]`, verified.
- Outside every task worktree, every exchange directory, and the firstmate home, so it is not in any path a crewmate's work traverses and cannot be committed or pulled by accident.
- It is NOT hidden from a crewmate.
  A crewmate on the host runs as the same Unix user as bifrost, so it can read anything that user can read.
  The enforceable boundary is the relay file channel and the exchange area, not the local filesystem.
  Anyone evaluating a standing pairing should evaluate it as "that machine holds a key equivalent to this user's shell on the peer", because that is what it is.
- Deleting the caller's copy after pairing was tested, and `exec` and `file` both keep working, because the caller's saved connection holds the grant session token.
  It is not a durable answer, because that token expires in 24 hours and re-authorization needs the key file again.
  What the caller persists instead is `~/.bifrost/remote-connections.json` at mode 644, containing `grant_session_token` and `shared_secret_encrypted`, which is bifrost's own storage and outside firstmate's control.

Revocation order matters: caller `conn down --all` first, then target `ssh-key revoke`.
The reverse leaves the caller with a 401, because revoking the key already dropped the grants.

## Known warts

- Repeated pairing accumulates superseded but narrow grants on the host, three after this run.
  They are all bound to `fm-relay-verbs`, so they are not an exposure, and they age out with the 24-hour session expiry.
  Clearing one is `bifrost setting grant revoke <id>` on the host.
- `bin/fm-relay-host.sh spawn` does not update the host's backlog, and host teardown prints a `NOT_FOUND` backlog error when the control machine owns the row.
  Teardown itself still completes.
- The control side records `host=` in the task metadata but no fleet identifier.
  Cross-machine task discovery belongs to a later phase and nothing here reads it, so nothing was pre-built for it.

## Not verified

- The reverse direction as a task host, at the time this was written.
  It has since been built and partly measured: see [`docs/relay-gui-host.md`](relay-gui-host.md), which owns the desktop-session requirement, the checks a host with a screen runs before it claims, and its own list of what is still unverified.
- Control-plane handover between machines.
  Out of scope by decision; the intended mechanism is an explicit human handover, not automatic arbitration.
- Relay session-token lifetime.
  Both ends read `Authorized: true` throughout and the host's login survived across days, but nothing here waited for one to expire.
- Whether the relay is reachable from outside the corporate network.
  Public DNS is blocked on this network, so this could not be tested; the relay resolves to an RFC1918 address behind an internal load balancer.
- Push-mode wakes.
  Only the polled check is implemented and measured.
