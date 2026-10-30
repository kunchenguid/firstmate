# herdr-core runtime backend

herdr-core is an experimental Herdr Core (`hc`) session-provider backend.
Herdr Core is the new flat-terminal product line from herdrdev: it is **not** an upgrade of `herdr` 0.9.x, and `backend=herdr` keeps driving the stable Herdr TUI unchanged.
A core session is an isolated state/socket domain holding a flat list of persistent terminals; labels are the discovery and ownership mechanism, and the Herdr app derives its spaces/tabs view from terminal labels rather than screen contents.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.
The adapter header in `bin/backends/herdr-core.sh` owns design decisions and measured CLI facts; this page is the operator-facing mirror and must not contradict it.

## Setup

Pick herdr-core when you want Firstmate tasks hosted on Herdr Core's persistent-terminal model and accept the [active limits](#active-limits) below.

Prerequisites:

- `herdr-core` 0.1.14 or newer on `PATH` (self-identifies as `hc x.y.z` from `herdr-core --version`). `bin/fm-install-herdr-core.sh` installs the verified pinned build (0.1.14, SHA-256 checked per platform) into `~/.local/bin`.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select herdr-core with local `config/backend` containing `herdr-core`, `FM_BACKEND=herdr-core` for one launch, or an explicit `--backend herdr-core`.
It is never runtime auto-detected in this stage; see "Selection is explicit" below.

A spawn stops with an actionable setup message when `herdr-core` or `jq` is unavailable, and container creation gates on the verified version floor and protocol generation 1.
Verify setup by spawning a small task and confirming metadata contains `backend=herdr-core`, `herdr_core_session=`, `herdr_core_terminal=`, and `window=<session>:<terminal>`.

### Operator and test knobs

| Variable | Role |
| --- | --- |
| `FM_HC_BIN` | Absolute path to the `hc`/`herdr-core` binary for tests and labs; production resolution is `herdr-core` on `PATH`. The bare `hc` name is deliberately never resolved from `PATH` (it can collide with unrelated tools). |
| `FM_HC_SESSION` | Optional core session **name** override for tests/labs only; default is `fm-<hometag>` from `bin/fm-backend-hometag-lib.sh`. The name `default` and any name outside `[a-zA-Z0-9_-]` are refused. Never use it alone for destructive cleanup. |
| `FM_HC_SOCKET` | Optional socket-path override for tests/labs; default is hc's own derivation `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/<session>/<session>.sock`. |

## Selection is explicit

herdr-core is explicit-only, like zellij, orca, Paseo, and tern: `config/backend`, `FM_BACKEND=herdr-core`, or `--backend herdr-core` select it, and nothing else does.
Every core terminal stamps `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, `HC_SCOPE`, and `HC_SESSION` into its descendants; a tmux server or Herdr client launched inside one inherits all of them, so their presence proves only that some ancestor was a core terminal, never that the captain chose the backend.
`fm_backend_detect` therefore ignores `HC_*` markers entirely, and app-vs-TUI auto-detection (opting into the Herdr app when the captain already runs inside it) is a later stage, not this adapter's business.

Once selected explicitly, every `hc` call the adapter makes pins `HC_SESSION=<session>` and `HC_SOCKET=<socket>` explicitly and strips ambient `HC_*` markers, so a call issued from inside a core terminal can never silently target the caller's own session or stamp a bogus caller on `terminal.send`.

## Task shape and metadata

Each home-owned container is ONE core session named `fm-<hometag>` (or `FM_HC_SESSION` in tests/labs). Core sessions are isolated state/socket domains - separate homes never see each other's terminals.
Each task is one persistent terminal created by `hc run --bg --json --cwd <worktree> --no-parent --no-notify`, running that machine's own shell (no argv), named `fm-<id>` when the id fits hc's 32-character name budget, and labeled:

- `fm.id=<task-id>` - the ownership claim (read back after creation; a terminal that dropped it is killed, removed, and the spawn refused);
- `fm.home=<hometag>` - this home's fleet filter for `list_live` discovery;
- `fm.project=<project basename>` - Herdr app grouping.

The firstmate endpoint and recorded `window=` target are `<session>:<terminal-address>` where the address is the terminal's own short id (`t5`, `t1b`, ...). Only local terminal addresses are accepted: a `machine/t7`-style remote address contains a slash and is refused by `parse_target`, and the session name may never contain a colon.

```text
backend=herdr-core
window=<session>:<terminal-address>
herdr_core_session=<session>
herdr_core_terminal=<terminal-address>
endpoint_task_id=<id>
```

A duplicate `fm.id` on a live terminal in this session is refused before creation, so a respawn of the same task id never produces a second endpoint.
Every target operation revalidates through `hc get`: the terminal must exist, be live, and (when a label is supplied) still carry `fm.id=<task>`.

## Current operation and safety

### Capability gate

Container provisioning (`fm_backend_herdr_core_container_ensure`) verifies tools, the `hc x.y.z` version floor, then the **hello handshake** through `hc connect`: the core must answer `{"method":"hello","params":{"generation":1}}` with `result.generation=1`. A core speaking another protocol generation is refused, not negotiated.
`hc server start` is idempotent, and any session-scoped command auto-starts a stopped core for that session - so a passive read never mistakes a stopped server for a destroyed endpoint.

### Capture

- History/`capture` uses `hc read <t> --json --lines N`, returning `{complete,how,text}` with ANSI already stripped (`how=history`).
- Viewport/`visible_capture` and composer reads use `hc read <t> --json` (`how=screen`, the viewport exactly).
- Composer capabilities: `styled=0`, `cursor=0`, `identity=0` - Core's OSC 7501 status is the native state channel, and no styled-screen identity is claimed.

### Input and submit

Core has two input verbs, and neither alone reproduces `tmux -l`:

- `hc send <t> -- <text>` pastes text and presses Enter **atomically**; flag-looking text is protected by the `--` delimiter. It is the line-send and the literal flush path.
- `hc keys <t> [--] <keys...>` presses named keys (`enter`, `esc`, `tab`, arrows, `backspace`, `delete`, `home`, `end`, `pageup`, `pagedown`, `f1`-`f12`, `space`, `ctrl+<letter>`, `alt+<letter>`, `shift+tab`) plus single literal characters from a limited set. It **cannot** type shifted punctuation (`!`, `"`, `_`, `:`, ...).

Because no verb types arbitrary text *without* submitting, unsubmitted literal input rides an adapter-local pending buffer (`state/.herdr-core-pending-<session>__<term>`): `send_literal` appends to it, and the next Enter, line send, or submit flushes it through one `hc send`. Between the literal and its flush the text is buffered, not on the terminal's screen - narrower than `tmux -l` semantics, and visible to the caller only as `composer_state` reporting `pending-unproven`-leaning behavior until delivery. `C-u` and `C-c` drop the buffer (composer-clear semantics) and pass through `hc keys`.

`send_text_submit` flushes pending text plus the new line through one `hc send --wait --timeout N`:

| Outcome | Verdict |
| --- | --- |
| `started:true` (or `wait.status=working`) - the program confirmed the turn | `empty` |
| `started:null` on a silent (non-7501) program | the shared composer classifier's screen verdict (`empty`/`pending`/`pending-unproven`) |
| exit 9 - the terminal is blocked waiting on input (never forced) | `unknown`, refusal on stderr |
| exit 3 / 11 - no such terminal, or it is finished | `send-failed` |

### Native busy and agent state

Core reports agent status through OSC 7501, never inferred from screen text. `hc get`'s `.status`/`.reported`/`.turn` carry the program's own report:

| Reported status | `busy_state` |
| --- | --- |
| `working` | `busy` (demoted to `unknown` when the foreground classifies as an interactive shell - the stale-record guard) |
| `blocked` | `blocked` (waiting on the human; classified not-busy by shared consumers exactly like herdr's fold) |
| `idle` | `idle` |
| `reported:false` / missing | `unknown` - a non-reporting program is never read as dead or idle-proven |

`agent_state` combines `state` with the shared harness-process classifier over `foreground` (or the program's own `argv` for a direct `hc run <agent>`): `live`+agent -> `alive`, `live`+bare shell -> `dead`, `finished` -> `dead`, absent -> `missing`, unreadable -> `unreadable`, present but not matching -> `ambiguous`. The adapter never prints `unverified` itself and is deliberately not registered as recovery-grade yet (see [active limits](#active-limits)).

### Path, kill, and test safety

`current_path` is passive: it reads the terminal record's `foreground.cwd`, falling back to `cwd`, and returns empty on failure rather than probing with shell markers.

Kill closes the task terminal with `hc kill` (synchronous, idempotent) then `hc rm` (a record is removable only once `finished`). It returns 0 when the terminal is already gone, and returns 1 with stderr - closing nothing, so teardown keeps the task records - when the record is unreadable, the terminal lost its `fm.id` label, it is still live after `kill`, or it is still listed after `kill`+`rm`.

Real-core tests never touch the user's sessions. `bin/fm-herdr-core-lab.sh` provisions isolated `fm-hclab-*` sessions with scratch `XDG_STATE_HOME`/`XDG_CONFIG_HOME`/`XDG_DATA_HOME`, a pinned `HC_SESSION`/`HC_SOCKET` under the short `/tmp/fm-hc-lab-$UID` socket directory (macOS `sun_path` caps a socket path at 103 bytes), and a file-inventory tripwire over the real core state taken before any lab call - because contacting a stopped core auto-starts it, the tripwire is a pure filesystem read.
Teardown requires the tripwire byte-identical, stops the server, then sweeps every process still carrying the session's `HC_SESSION` env marker (`server stop` deliberately leaves the `serve`/`hold` daemons and terminals alive so sessions are recoverable), removes the main socket and any `<name>.holder.*.sock`, and removes only the `fm-hclab-*` session directory.
`tests/herdr-core-test-safety.sh` is the fail-closed guard every real test sources first; `bin/fm-herdr-core-ci-cleanup.sh` owns best-effort job-owned lab debris (leftover `fm-hclab-*` session dirs, sockets, and `hc` binaries installed only for a job) and never touches `default` or any non-`fm-hclab-` session.

## Active limits

- herdr-core is experimental and has no dedicated real-backend CI lane; the `herdr-core` test family gate-skips the real-`hc` smoke when no binary is installed (`optional-binary`).
- **No auto-detection**: nothing opts into herdr-core on the captain's behalf. Herdr-app-vs-TUI detection, and the automatic selection it would enable, is a later stage.
- **Not recovery-grade**: `herdr-core` is deliberately absent from `fm_control_backend_state_verified` and `fm_control_backend_relaunch_supported`; relaunch refuses on this backend rather than attempting a replacement whose foreground classifier has not been proven recovery-grade.
- `--secondmate` spawns are refused; remote second mates are deferred work.
- **No push events yet**: `hc events` streams JSON-RPC records, but the normalized push-transition surface is not wired in this stage - `fm_backend_has_push` stays false and the watcher's poll loop is the event source, as for zellij/cmux/tern.
- **Pending-buffer fidelity**: `send_literal` buffers unsubmitted text adapter-side until a flush; the terminal's screen does not show it between calls, unlike `tmux -l`.
- **No remote terminals**: `machine/t7`-shaped remote addresses are refused everywhere; second-home and remote sessions are unsupported.
- `hc keys` cannot type shifted punctuation; only the `hc send` path delivers full arbitrary text.
- A target can disappear after structural readiness and before the operation; operations revalidate through `hc get` but cannot hold the terminal.

## Regression entry points

```sh
bash bin/fm-test-run.sh --family herdr-core
FM_HC_BIN=/path/to/hc bash tests/fm-backend-herdr-core-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr-core) records the active source, fake-CLI, and live evidence boundaries, including what this host could and could not prove.
