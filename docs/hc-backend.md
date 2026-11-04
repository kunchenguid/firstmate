# hc runtime backend

hc is an experimental session-provider backend for herdr-core, the terminal core under Herdr.app.
It provides task terminals while Treehouse continues to provide git worktrees, the same split tmux uses.
herdr-core is not Herdr 1: the `herdr` backend ([`herdr-backend.md`](herdr-backend.md)) talks to the `herdr` multiplexer, and the two share no socket, id space, or CLI.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.
This page owns operator setup and supported limits; the adapter header in `bin/backends/hc.sh` explains implementation decisions.
[`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records what was exercised against a real core.

## Setup

Prerequisites:

- Herdr Core at version 0.1.14 or later, self-identifying as `hc x.y.z`, and a core speaking protocol generation 1.
  Binary resolution uses an executable `FM_HC_BIN` override first, then `herdr-core` on `PATH`, then the `hc` alias.
  `hc` starts its own core on first use.
  [`bin/fm-install-hc.sh`](../bin/fm-install-hc.sh) owns installation usage and the checksum-verified release pin; updates remain operator-run.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select hc explicitly with local `config/backend` containing `hc`, `FM_BACKEND=hc` for one launch, or an explicit request to Firstmate.
An explicit setting always wins; see "Runtime auto-detection" below for when hc is also selected automatically.

The core a task lands on is the one `HC_SESSION` names when the task is spawned, or hc's `default` session when it is unset.
The Herdr app shows the terminals of the session it bound at launch, `default` unless the app was started with a different `HC_SESSION`.

## Runtime auto-detection

hc is auto-detected only on the Herdr app's terminal-level signal, never on bare `HC_TERMINAL_*` markers: hc stamps them into every process an hc terminal starts, and an app-created terminal's env is deliberately identical to any other hc terminal's - the app sends `TERM_PROGRAM=herdr` in its `terminal.run` call, but the core's `child_env` normalizes that to `ghostty` for every child, app-created or not.
What marks a terminal as the app's is its core-side record: the app stamps `herdr.space`/`herdr.tab` labels on every terminal it creates, and a non-empty `herdr.space` is the exact condition under which the app projects a terminal into its window.
[Backend selection order](configuration.md#backend-selection-order) owns precedence; this section owns the app-terminal signal.

Exactly one signal selects hc, after every other surface marker has had its say:

- `app-terminal`: this process's own `HC_TERMINAL_ID` terminal carries a non-empty `herdr.space` label in its core's record.
  The check is read-only and gated: a unix connect must first prove `HC_TERMINAL_SOCKET` live, because `hc` starts a core on contact with a missing socket and a bare `hc get` could create state; then one `hc get` reads the label through the resolved binary.
  Missing markers, a dead socket, a missing or unusable `hc`/`jq` toolchain, a `get` failure, or an empty label are all a miss, never a detection.

A live `herdr-app.sock` or an open window is deliberately not a signal: every process on the host can see it, so it cannot tell a Firstmate inside an app terminal from one on a bare shell while the window happens to be open elsewhere.
Live testing against the real app confirmed the ambiguity - marker-less processes selected hc solely because a window existed - so only the terminal-level claim above can auto-select hc.
A captain who wants a shell outside the app to spawn hc workers sets `config/backend`, `FM_BACKEND`, or `--backend` explicitly.

The signal binds the core a spawn would actually reach, the `HC_SESSION` (else `default`) session, and requires it to be running already, because the adapter's container ensure starts a missing core and detection must never start one.
`bin/fm-backend.sh` resolves that core's socket without calling `hc`: an `FM_HC_SOCKET` pin, else `$XDG_RUNTIME_DIR/herdr-core/<session>.sock` when `XDG_RUNTIME_DIR` is set, else `${XDG_STATE_HOME:-~/.local/state}/herdr-core/<session>/<session>.sock`, the layout measured on hc 0.1.14.
`app-terminal` additionally requires `HC_TERMINAL_SOCKET` to be that same socket, so a labeled terminal on some other core never steers a spawn.
The app shows the session it bound at launch, so a captain whose app runs a session other than `default` sets the same `HC_SESSION` for Firstmate or selects hc explicitly.

An explicit `--backend`, `FM_BACKEND`, or `config/backend` always wins over detection.
Inside the classic Herdr TUI, `HERDR_ENV=1` wins before the app signal is consulted, so the `herdr` backend keeps its behavior; inside tmux, `$TMUX` wins the same way, so a marker-less or contradictory process on either surface never sees the app check at all.
A contradictory marker set (for example another surface's marker alongside the app's) keeps the earlier surface's verdict rather than switching - ambiguous input means no automatic switch.
When a live hc terminal is present but no usable hc toolchain resolves (an executable `FM_HC_BIN`, or `herdr-core`/`hc` on `PATH` reporting `hc x.y.z` at or above the adapter's verified minimum, plus `jq` - the same version gate the spawn's container check applies), detection does not switch and a notice names the missing piece instead; a bare terminal marker set is still never a detection.
An auto-detected hc prints a stderr notice naming the winning signal and how to opt out; [Task shape and metadata](#task-shape-and-metadata) owns its task record.

Auto-detected hc spawns carry the same `herdr.space`/`herdr.tab` labels an explicit hc spawn does, so workers appear in the captain's window without the app ever being started by Firstmate.
The app is local GUI presentation only; detection reads the terminal's core-side label without requiring a live app window, so a surviving labeled terminal can still select hc after the GUI closes.
Nothing here changes the remote `herdr` path.

Two limits apply to auto-detection specifically:

- A `--secondmate` spawn under an auto-detected hc fails the existing refusal rather than silently choosing another backend; set `config/backend` explicitly for a home that spawns secondmates.
- Away-mode supervisor discovery and hc refusal are owned by [Away-mode supervisor backend](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target).

## Task shape and metadata

Each task is one hc terminal running the user's login shell in the project directory, started with `--no-parent --outlive-parent --no-notify` so it is independent of whichever hc terminal Firstmate itself runs in.
The terminal carries these labels:

| Label | Value | Purpose |
| --- | --- | --- |
| `firstmate.task` | `fm-<id>` | Task identity checked before input or close. |
| `firstmate.home` | `<hometag>` from `bin/fm-backend-hometag-lib.sh` | Keeps two homes with the same task id apart. |
| `herdr.space` | `FM_HC_SPACE`, default `fm-<hometag>` | Groups a home's tasks in one Herdr.app space. |
| `herdr.tab` | `<hometag>-fm-<id>` | One Herdr.app tab per task. |

```text
backend=hc
backend_detect=app-terminal
window=<session>:<address>
hc_session=<session>
hc_terminal=<address>
```

`backend_detect=` is `app-terminal` only when that signal automatically selected hc; an explicitly selected hc writes no `backend_detect=` line.

`<address>` is hc's terminal address such as `t7`, or `<machine>/t7` for a worker placed on another machine.
A placed task also records `hc_machine=<machine>`, `hc_firstmate_as=<name>`, `hc_clone=<clone path there>`, and `hc_launch_file=<launch file path there>`, and its `worktree=` is a path on that machine; the endpoint check accepts a machine-qualified terminal only with the matching `hc_machine=`.
Every adapter call sets exactly the recorded `HC_SESSION` and drops any inherited `HC_SOCKET`, which hc would otherwise prefer, so a task keeps reaching its own core even when the caller's environment names another one.
`FM_HC_SOCKET` is the deliberate socket pin tests and labs use instead of an inherited `HC_SOCKET`.
An input, capture, or close that carries the task label refuses a terminal whose `firstmate.task` or `firstmate.home` label does not match, and a close without a label still refuses a terminal that lacks this home's labels.

## Operations

| Operation | hc command |
| --- | --- |
| Container ensure | `hc server status` plus the `hello` generation handshake over `hc connect` |
| Create task | `hc run --bg --no-parent --outlive-parent --no-notify --cwd <project> --label ...`, with `--on <machine>` for a placed worker |
| Capture | `hc read --lines <n>` |
| Visible capture | `hc read --lines 0` |
| Send a line and submit | `hc send` |
| Submit with confirmation | `hc send --wait`; see submit safety under Limits |
| Named key | `hc keys` |
| Current path | `hc get`, the foreground process's `cwd` |
| Busy state | `hc get`, native `status.state` (`working` is busy) |
| Agent state | `hc get`, the foreground process and its process group, through the shared classifier; a placed worker's group is read with `hc exec --on` |
| Close | `hc kill`, then `hc rm`, then `hc get` must answer not found |

## Limits

- `hc send` always presses Enter, so hc cannot type without submitting.
  `bin/fm-spawn.sh` pastes and submits the spawn launch line with `hc send` and consumes the Enter that follows it.
- Submitting a message uses one bounded `hc send --wait`.
  A started turn or a still-working wait confirms it natively; otherwise the adapter falls back to the composer screen, with Enter retries only for a proven pending composer.
  A blocked terminal (exit 9) returns `unknown` without typing or retrying and is never forced.
- hc reports one foreground process per terminal.
  When that process is a launcher, the adapter also reads the rest of its process group from `ps`: here for a local terminal, and on its own machine through `hc exec --on` for a placed one, where a scan that cannot run reads `unreadable`, never `dead`.
- Right after a terminal starts, `hc get` can report no foreground process yet, and agent state reads `unreadable` until the shell is up.
- `--secondmate` spawns are refused.
- A worker inherits `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, and `HC_SCOPE` from its terminal, and the `config/launch-env-allowlist` floor keeps them; whether a real harness then reports native status under Firstmate's launch is not verified.
- Naming a Herdr.app space needs the app window and is not done.
  The `herdr.space`/`herdr.tab` label contract above is the app's documented bridge (its window projects labeled terminals as spaces/tabs and keeps unlabeled ones hidden), verified against a real window: [`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records the live exercise.
- hc has no event stream this adapter consumes; supervision polls like tmux.

## Workers on another machine

A home can start its hc ship and scout workers on another machine its hc core already reaches (`hc machine add`), so the work runs there while Firstmate stays here.
[`configuration.md`](configuration.md#hc-worker-placement-confighc-machine) owns the `config/hc-machine` file and the `--hc-machine` flag that select it; without either, nothing here applies.

### What the other machine needs

- It is added to this core's session and connected (`hc machine ls`), this machine's hc is 0.1.16 or later, and the other machine's is 0.1.18 or later.
- A clone of the project at `<projects>/<project name>` whose origin is the same remote as this machine's clone.
- Its own hc reaches this machine back, under the name `firstmate-as` gives (`hc machine add <ssh target> --name <that name>` there).
  The worker reads its instructions and reports through that route, which lets programs on that machine run commands here as this machine's user, so place workers only on a machine you already trust that far.
- Claude Code installed and logged in, on the PATH of the non-interactive login shell there (`$SHELL -lc 'claude --version'` must succeed, with `CLAUDE_CONFIG_DIR` set as below when configured; for zsh, set that PATH in `.zprofile`, since `.zshrc` is read only by interactive shells), and the clone already trusted there (open `claude` in it once).
  The default Claude login there may be kept for another use, such as a supervisor.
  In that case `claude-config` in `config/hc-machine` names a separate Claude config directory there for workers; the launch pins it with `CLAUDE_CONFIG_DIR`, and the trust check reads that directory's store.
  A placed worker uses that machine's own login, so `--account` is refused.
- The tools its brief uses, such as `gh` and, for a no-mistakes ship, `no-mistakes`, since the worker pushes and validates from there.

The spawn proves every item before it creates anything, and refuses with the missing item named; it never falls back to starting the worker here.
The route back is proved by reading back a one-time value written here, and Claude's trust is read, never written, from the store a worker there uses.

### How a placed worker runs

The worktree is a linked worktree of that clone at `<projects>/.fm-hc/<hometag>/<task-id>`, created there through `hc exec --on` from freshly fetched `origin/<base>`, where the default base is origin's current default branch as `git ls-remote --symref origin HEAD` reports it there; no Treehouse runs on either machine.
A creation that fails after it began removes what it made there, or names the path it could not remove.
The terminal starts in it with `hc run --on`, carries the usual labels, and lives in that machine's core, so a Herdr.app bound to that machine's session shows it like any other hc terminal.
The launch command is staged beside the worktree there and removes itself as it runs.
A spawn that aborts removes it there once the terminal is closed, and teardown removes it after closing the terminal; a failed removal is a warning that names the path.

The brief, status file, steering inbox, and task data stay on this machine, where supervision reads them exactly as for a local worker.
The launch brief is prefixed with a placement section telling the worker to run each command the brief gives for a Firstmate path through `hc exec --on <firstmate-as>`, and to read or write those files with `hc file read`/`hc file write --on <firstmate-as>`; `FM_TASK_INBOX` names the inbox's path here.

Every later step reaches the worker through hc and never through this machine's filesystem or process table: send, keys, capture, current path, and close use the `<machine>/t7` address through this core, and the agent-state group scan, the done gate's head check, and teardown's landed-work proof run their commands there with `hc exec --on`.
Teardown applies the same landed-work proof it applies to a local worktree, refuses when that machine cannot be reached, and closes the terminal before proving again.
Before the close it aborts the ship's own no-mistakes run parked at a gate on that machine's daemon, through `hc exec --on` in the worktree: only a run on the worktree's branch whose head is its HEAD or a descendant of it, and it refuses when the run is still parked afterwards.
Between the close and the second proof it stops every process left with its current directory under the worktree there (`lsof -a -d cwd`, or a `/proc` scan where that machine has no `lsof`; TERM, then KILL, then a recheck; each signal goes only to a process whose start identity still matches the one its scan read, so a reused pid is never signalled), as it does for a local worktree, and refuses with every record kept when that scan cannot run there or a process survives.
Only then does it remove the worktree and its branch there; `--force` keeps its usual meaning.

### Limits of a placed worker

- Only the `claude` harness is placed, and a `local-only`, `forge=gerrit`, or `forge=external` ship refuses placement, because each is checked against a worktree on this machine.
- No Firstmate hooks are installed there, since their scripts live in this machine's checkout, so a placed worker has no busy record, turn-end notification, commit-trailer strip, or push guard.
- Its busy and idle state come from hc's native `status.state` and read as `hc-native`; the fake-hc unit tests cover this, but whether a real Claude worker started there reports `status.state` was not verified live, because the live run's Claude was logged out.
- `bin/fm-control.sh` interrupts a placed worker, but its `exit` and `relaunch` refuse it, as they refuse every hc task, because that script has no recovery-grade hc agent-state classifier; `fm-spawn.sh --relaunch` refuses a placed task too, and nothing there is stopped or changed.
- Reads that look inside a worktree on this machine report nothing for a placed one: the no-mistakes run state in the fleet view, the review diff, and worktree write activity as stall evidence.
- A spawn claims the worktree path there only by proving it absent before `git worktree add`, so two Firstmate installs at the same absolute path that place the same task id on one machine can race for it. The loser's add fails and leaves the winner's worktree alone: a failed spawn removes only a worktree its own `git worktree add` created.
- Teardown, even with `--force`, refuses while the machine cannot be reached, because it can neither stop the worker there nor remove its worktree; a machine that never returns leaves the task's record in place.
- `config/claude-account` and `config/claude-accounts` do not apply to a placed worker, which uses that machine's Claude login; the spawn prints a note when it skips one.
- That the app shows a placed terminal is inferred from the label contract above; no Herdr.app window bound to the other machine's session was observed.
  Whether Claude, started on a fresh `claude-config` directory, stops at its Bypass Permissions warning there was not verified either.

## Tests

`tests/fm-backend-hc.test.sh` pins the adapter against a fake `hc`.
`tests/fm-backend-hc-placement.test.sh` pins placement against a fake core whose other machine is reachable only through hc: the config, the machine, `claude`, and route-back gates, a real placed spawn and its abort cleanup, and a real teardown that refuses unlanded or unreachable work there, aborts the ship's parked no-mistakes run there, and stops processes left in the worktree there.
`tests/fm-backend-hc-liveness-live-e2e.test.sh` is the default-on live guard: it launches every installed harness bare in a private core and requires `alive`.
`tests/fm-backend-hc-smoke.test.sh` drives the real binary in an isolated lab; [`bin/fm-hc-lab.sh`](../bin/fm-hc-lab.sh) owns the isolation and metadata-tripwire contract, and [`tests/hc-test-safety.sh`](../tests/hc-test-safety.sh) owns guarded test teardown.
`tests/fm-backend-hc-appdetect-smoke.test.sh` runs a real `bin/fm-spawn.sh` spawn in the same kind of lab for the app-terminal and explicit cases, and checks that a live app window never selects hc for a marker-less process and starts nothing for a session with no running core.
The smokes skip when no resolved Core binary or `jq` is available; provisioning and teardown failures fail the test.
For CI coverage, see [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend); the workflow requires `jq` and rejects the `hc not found` skip.
[`bin/fm-hc-ci-cleanup.sh`](../bin/fm-hc-ci-cleanup.sh) owns job-end cleanup mechanics.
