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

hc is auto-detected only on the Herdr app's own signals, never on bare `HC_TERMINAL_*` markers: hc stamps them into every process an hc terminal starts, and an app-created terminal's env is deliberately identical to any other hc terminal's - the app sends `TERM_PROGRAM=herdr` in its `terminal.run` call, but the core's `child_env` normalizes that to `ghostty` for every child, app-created or not.
What marks a terminal as the app's is its core-side record: the app stamps `herdr.space`/`herdr.tab` labels on every terminal it creates, and a non-empty `herdr.space` is the exact condition under which the app projects a terminal into its window.
`bin/fm-backend.sh` `fm_backend_detect` owns the check order; this section owns what the signals mean.

Two signals select hc, in this order, after every other surface marker has had its say:

1. `app-terminal`: this process's own `HC_TERMINAL_ID` terminal carries a non-empty `herdr.space` label in its core's record.
   The check is read-only and gated: a unix connect must first prove `HC_TERMINAL_SOCKET` live, because `hc` starts a core on contact with a missing socket and a bare `hc get` could create state; then one `hc get` reads the label through the resolved binary.
   Missing markers, a dead socket, a missing or unusable `hc`/`jq` toolchain, a `get` failure, or an empty label are all a miss, never a detection.
2. `app-window`: a live `herdr-app.sock` control socket under the resolved app home (`HERDR_APP_HOME`, else `XDG_CONFIG_HOME/herdr-app`, else `~/.config/herdr-app`).
   The probe is the app's own liveness rule, a bare unix connect: a stale socket file refuses, an absent one never binds, and the app is never launched or talked to.
   It is consulted only when no signal named this process's runtime, so a Firstmate on a plain shell on a host where the captain's window is open also opts into app presentation.

Both signals bind the core a spawn would actually reach, the `HC_SESSION` (else `default`) session, and require it to be running already, because the adapter's container ensure starts a missing core and detection must never start one.
`bin/fm-backend.sh` resolves that core's socket without calling `hc`: an `FM_HC_SOCKET` pin, else `$XDG_RUNTIME_DIR/herdr-core/<session>.sock` when `XDG_RUNTIME_DIR` is set, else `${XDG_STATE_HOME:-~/.local/state}/herdr-core/<session>/<session>.sock`, the layout measured on hc 0.1.14.
`app-terminal` additionally requires `HC_TERMINAL_SOCKET` to be that same socket, so a labeled terminal on some other core never steers a spawn.
`app-window` requires that socket to accept a connection; with no running core it does not switch and the notice names the session it would not start.
The app shows the session it bound at launch, so a captain whose app runs a session other than `default` sets the same `HC_SESSION` for Firstmate or selects hc explicitly.

An explicit `--backend`, `FM_BACKEND`, or `config/backend` always wins over detection.
Inside the classic Herdr TUI, `HERDR_ENV=1` wins before the app signals are consulted, so the `herdr` backend keeps its behavior.
A contradictory marker set (for example another surface's marker alongside the app's) keeps the earlier surface's verdict rather than switching - ambiguous input means no automatic switch.
When a live app window or a live hc terminal is present but no usable hc toolchain resolves (an executable `FM_HC_BIN`, or `herdr-core`/`hc` on `PATH` reporting `hc x.y.z`, plus `jq`), detection does not switch and a notice names the missing piece instead; a bare terminal marker set is still never a detection.
An auto-detected hc prints a stderr notice naming the winning signal and records `backend_detect=app-terminal` or `backend_detect=app-window` in the task meta, so the spawn output and task record carry the reason for the choice.

Auto-detected hc spawns carry the same `herdr.space`/`herdr.tab` labels an explicit hc spawn does, so workers appear in the captain's window without the app ever being started by Firstmate.
The app is local GUI presentation only: on a remote or headless home neither signal exists, and nothing here changes the remote `herdr` path.

Two limits apply to auto-detection specifically:

- A `--secondmate` spawn under an auto-detected hc fails the existing refusal rather than silently choosing another backend; set `config/backend` explicitly for a home that spawns secondmates.
- Supervisor-endpoint discovery (`bin/fm-supervisor-target-lib.sh`) resolves an hc terminal running Firstmate to its `<session>:<address>` target, but `bin/fm-supervise-daemon.sh` does not support hc endpoints yet and refuses the resolved backend loudly instead of steering the wrong pane.

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

`backend_detect=` is the auto-detection signal only when one selected the backend; an explicitly selected hc writes no `backend_detect=` line.

`<address>` is hc's terminal address such as `t7`.
Every adapter call sets exactly the recorded `HC_SESSION` and drops any inherited `HC_SOCKET`, which hc would otherwise prefer, so a task keeps reaching its own core even when the caller's environment names another one.
`FM_HC_SOCKET` is the deliberate socket pin tests and labs use instead of an inherited `HC_SOCKET`.
An input, capture, or close that carries the task label refuses a terminal whose `firstmate.task` or `firstmate.home` label does not match, and a close without a label still refuses a terminal that lacks this home's labels.

## Operations

| Operation | hc command |
| --- | --- |
| Container ensure | `hc server status` plus the `hello` generation handshake over `hc connect` |
| Create task | `hc run --bg --no-parent --outlive-parent --no-notify --cwd <project> --label ...` |
| Capture | `hc read --lines <n>` |
| Visible capture | `hc read --lines 0` |
| Send a line and submit | `hc send` |
| Submit with confirmation | `hc send --wait`; see submit safety under Limits |
| Named key | `hc keys` |
| Current path | `hc get`, the foreground process's `cwd` |
| Busy state | `hc get`, native `status.state` (`working` is busy) |
| Agent state | `hc get`, the foreground process and its process group, through the shared classifier |
| Close | `hc kill`, then `hc rm`, then `hc get` must answer not found |

## Limits

- `hc send` always presses Enter, so hc cannot type without submitting.
  `bin/fm-spawn.sh` pastes and submits the spawn launch line with `hc send` and consumes the Enter that follows it.
- Submitting a message uses one bounded `hc send --wait`.
  A started turn or a still-working wait confirms it natively; otherwise the adapter falls back to the composer screen, with Enter retries only for a proven pending composer.
  A blocked terminal (exit 9) returns `unknown` without typing or retrying and is never forced.
- hc reports one foreground process per terminal.
  When that process is a launcher, the adapter also reads the rest of its process group from `ps`, which works only for terminals on the local machine.
- Right after a terminal starts, `hc get` can report no foreground process yet, and agent state reads `unreadable` until the shell is up.
- `--secondmate` spawns are refused.
- A worker inherits `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, and `HC_SCOPE` from its terminal, and the `config/launch-env-allowlist` floor keeps them; whether a real harness then reports native status under Firstmate's launch is not verified.
- Naming a Herdr.app space needs the app window and is not done.
  The `herdr.space`/`herdr.tab` label contract above is the app's documented bridge (its window projects labeled terminals as spaces/tabs and keeps unlabeled ones hidden); visual confirmation inside a real window remains outstanding.
- hc has no event stream this adapter consumes; supervision polls like tmux.

## Tests

`tests/fm-backend-hc.test.sh` pins the adapter against a fake `hc`.
`tests/fm-backend-hc-liveness-live-e2e.test.sh` is the default-on live guard: it launches every installed harness bare in a private core and requires `alive`.
`tests/fm-backend-hc-smoke.test.sh` drives the real binary in an isolated lab; [`bin/fm-hc-lab.sh`](../bin/fm-hc-lab.sh) owns the isolation and metadata-tripwire contract, and [`tests/hc-test-safety.sh`](../tests/hc-test-safety.sh) owns guarded test teardown.
`tests/fm-backend-hc-appdetect-smoke.test.sh` runs real `bin/fm-spawn.sh` spawns in the same kind of lab for the app-terminal, app-window, and explicit cases, and checks that a window over a session with no running core starts nothing.
The smokes skip when no resolved Core binary or `jq` is available; provisioning and teardown failures fail the test.
For CI coverage, see [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend); the workflow requires `jq` and rejects the `hc not found` skip.
[`bin/fm-hc-ci-cleanup.sh`](../bin/fm-hc-ci-cleanup.sh) owns job-end cleanup mechanics.
