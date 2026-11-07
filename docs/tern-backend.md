# tern runtime backend

tern is an experimental Stencil Tern session-provider backend.
It provides task sessions, tabs, and blocks while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.
The adapter header in `bin/backends/tern.sh` owns design decisions and measured CLI facts; this page is the operator-facing mirror and must not contradict it.

## Setup

Pick tern when Firstmate itself already runs inside a Tern block (or you otherwise operate against a live Tern session daemon) and accept the [active limits](#active-limits) below.

Prerequisites:

- Tern 0.9.4 or newer on `PATH` (`tern --version`); bootstrap reports a missing binary as manual install guidance at `https://stencil.so/tern` rather than an executable install command.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- A reachable Tern session daemon for scripted `tern ls` / `tern new` / `tern capture` work.
- A Tern window control endpoint only when native agent-state reads through `tern ctl` are required; without it, native state degrades rather than failing the backend.

Select tern with local `config/backend` containing `tern`, `FM_BACKEND=tern` for one launch, or an explicit request to Firstmate.
It is never runtime auto-detected; see "Selection is explicit" below.

A spawn stops with an actionable setup message when `tern` or `jq` is unavailable, and container creation version-gates at 0.9.4.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without focusing the task block.

Verify setup by spawning a small task and confirming metadata contains `backend=tern`, `tern_session_id=`, `tern_tab_id=`, `tern_block_id=`, and `window=<session-id>:<block-id>`.

### Operator and test knobs

| Variable | Role |
| --- | --- |
| `FM_TERN_SESSION` | Optional session **name** override for tests/smoke only; default is `fm-<hometag>` from `bin/fm-backend-hometag-lib.sh`. Do not use it alone for destructive cleanup. |
| `FM_BACKEND_TERN_CTL_TIMEOUT` | Seconds bounding each `tern ctl` call (default `5`). |
| `FM_BACKEND_TERN_SUBMIT_POLLS` | Native-state samples per Enter confirmation budget (default `6`). |
| `FM_BACKEND_TERN_SUBMIT_MIN_SLEEP` | Minimum per-Enter confirmation budget before polling native state after an idle baseline (default `0.6`). |

## Selection is explicit

tern is explicit-only, like zellij, orca, and Paseo: `config/backend`, `FM_BACKEND=tern`, or `--backend tern` select it, and nothing else does.
Tern stamps `TERM_PROGRAM=tern` and `TERN_PANE=<block-id>` (plus `TERN_PANE_SOCKET` and `TERN_WINDOW_KEY`) into every block its session daemon spawns.
A tmux server or Herdr client started inside a block inherits all of them, so their presence proves only that some ancestor was Tern, never that the captain chose it.
Reading them as a selection would make tern an ambient default, which "Authority is explicit and never inferred" rules out; `fm_backend_detect` therefore ignores them.

The markers are still useful once tern has been selected explicitly.
A cleared-environment launch keeps the `TERN_*` identity and, like every backend's launch floor, whatever `TERM_PROGRAM` the pane has, which is `tern` inside a Tern block (see [`configuration.md`](configuration.md#variables-retained-and-where-values-come-from)), and `tests/tern-test-safety.sh` refuses to close a session that hosts the caller's own `$TERN_PANE` block.

## Task shape and metadata

Each home-owned container is one Tern session named `fm-<hometag>` (or `FM_TERN_SESSION` in tests).
`tern new session` seeds that session with one ordinary shell tab; the adapter leaves that seed alone so the session stays alive after the last task tab closes.
Each task is one keep-open tab whose title is renamed to `fm-<hometag>-<id>` (and read back); the caller-facing label remains `fm-<id>`.

Ids are 64-bit integers that are globally unique per Tern window.
The firstmate endpoint and recorded `window=` target are `<session-id>:<block-id>` (digits only on both sides).
CLI selectors passed to tern always use the one-session form `<session-id>/<block-id>` so tern itself refuses a block outside the recorded session and cannot treat a bare numeric id as a session rename.

```text
backend=tern
window=<session-id>:<block-id>
tern_session_id=<session-id>
tern_tab_id=<tab-id>
tern_block_id=<block-id>
endpoint_task_id=<id>
```

Numeric ids must preserve full 64-bit precision end to end.
Every JSON document from tern is string-quoted on id-bearing keys (`id`, `pane`, `session`, `tab`, `block`) before jq so values above 2^53 are never rounded.

Every target operation revalidates through a fresh `tern ls --json`: the block must exist in the recorded session, and when a label is supplied the owning tab title must match the scoped title.
An inventory that cannot be read, a block that moved sessions, or a title mismatch refuses rather than guessing.

## Current operation and safety

### Capture

- History/`capture` uses `tern capture <session>/<block> --scrollback --surfaces`, then trims locally to the requested line bound.
- Viewport/`visible_capture` and composer reads use `tern capture <session>/<block> --surfaces` (no `--scrollback`), then trim to the block's `rows` from inventory when known.
- A Tern Surface Protocol (TSP) native agent surface returns empty under plain/`--ansi` capture; `--surfaces` is required for transcript text.
- `--surfaces` prints a JSON object `{"block","text"}`; both capture paths read its `.text` before any line trim, and use output that is not such an object unchanged.
- Composer capabilities are deliberately conservative with no native identity or styled-classifier proof: `styled=0`, `cursor=0`, `identity=0`, with `rows=` from `FM_COMPOSER_CAPTURE_LINES`.
  Native `program` names were not proven as harness identity, and `--ansi` of a natively drawn block is empty on the measured host, so styling and identity are not advertised and no speculative identity plumbing is claimed.
  Without styling or identity, the shared classifier degrades a glyph row carrying trailing text to `unknown` rather than treating an idle suggestion as typed input.

### Input and submit

Input splits are explicit:

- `tern send <session>/<block> text TEXT` types literal text without Enter.
- `tern send <session>/<block> keys COMBO` delivers chords; the adapter normalizes `Enter`→`enter`, `Escape`/`Esc`→`escape`, `C-c`→`ctrl+c`, `C-u`→`ctrl+u`, and otherwise passes the chord through.
- `tern run <session>/<block> TEXT` types a line and Enter in one step (`send_text_line`).

Key names, `send text` with flag-looking text, and `tern run` semantics were taken from Tern's help and the task brief and are **not** live-verified on this host.

An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through tern's submit machinery.
On the typed plane, text is typed once; Enter is separate; retries press Enter only and never retype.
Submit confirmation prefers a native idle baseline followed by a landed-turn signal of `working` or `waiting_input` when `tern ctl` agent state is available; when native state is `unknown`, submit falls through to the shared composer retry core exactly like cmux.
`waiting_input` is a landed-turn signal for submit confirmation but is not a queued-Enter busy signal.

### Native busy and agent state

Native agent state (desktop window control endpoint only) is read through bounded `tern ctl` calls (`FM_BACKEND_TERN_CTL_TIMEOUT`, default 5s):

1. `tern ctl carly lua "$FM_BACKEND_TERN_AGENTS_LUA"`, which stores the answer of this projection of the window's agent list:

   ```lua
   local out = {} for _, a in ipairs(cx.agents:list()) do table.insert(out, {pane = a.pane, state = a.state, alive = a.alive}) end return tern.json.encode(out)
   ```

2. `tern ctl state` → `.carly.last_tool.text`, stripping a leading `→` and any fresh-Lua-state banner

Carly's answer slot holds the text Carly displays for the program's result, not a JSON document the adapter controls.
In that displayed text the free text of an agent entry (`last_message`, `title`, `running.line`, `last.line`) carries raw newlines and other control characters, which a JSON string may not contain, so a single multi-line message makes the whole array unparseable.
The projection therefore asks only for the fields the adapter reads (`pane`, `state`, `alive`), and must never be extended with a field that can hold text a human or a model wrote.
The ids in the answer are quoted like every other tern id, and the displayed answer is never repaired: one that does not parse reads `unknown`.

`native_state` keeps Tern's own words: `working` | `idle` | `waiting_input` | `unknown`.
Each agent entry's `pane` equals the block id.

`busy_state` prints `busy` | `idle` | `blocked` | `unknown`:

| Native state | `busy_state` |
| --- | --- |
| `working` | `busy` |
| `idle` | `idle` |
| `waiting_input` | `blocked` (Tern's word for waiting on the human; analogue of Herdr's blocked status) |
| missing entry / `ctl` failure / unreadable | `unknown` |

Herdr's own `busy_state` folds blocked into idle; tern keeps the extra `blocked` distinction.
Shared consumers of the dispatcher `busy_state` test the exact word `busy` (`fm-busy-lib.sh` native branch, supervise-daemon `pane_is_busy`, task-inbox ring), so `blocked` is classified not-busy exactly like herdr's idle.
This adapter does not change those consumers.
A `busy` verdict is demoted to `unknown` when `tern process` shows an interactive shell in the foreground.

`agent_state` uses inventory plus `tern process <session>/<block> --json` and classifies the foreground with the shared harness process classifier:

| Situation | Verdict |
| --- | --- |
| Bad target, unreadable `ls`, or failed `process` | `unreadable` |
| Successful `ls` with the block absent | `missing` |
| Block present under a different session | `ambiguous` |
| Block exited (`live:false` or non-null `exited`) | `dead` |
| Foreground classified as an agent | `alive` |
| Foreground interactive shell with no command/script argument | `dead` |
| Shell running a command (`sh -c ...`) or other non-agent | `ambiguous` |

The adapter never prints `unverified` itself.

When `tern ctl` fails (no window, headless, remote pane without a local window, timeout), native paths return `unknown` and fall through to screen classification; they do not error the backend.
A first failing `ctl` call skips the second.
On this host, both `tern ctl state` and `tern ctl carly lua ...` fail immediately with `{"ok":false,"error":"no Tern window on this machine shows this pane"}`.
No successful `ctl` agent read was possible on this host.

### Path, kill, and test safety

`current_path` is passive: it reads `tern process` `foreground.cwd` and returns empty on failure rather than probing with shell markers.

Kill closes the task block with `tern close <session>/<block>`.
It returns 0 when the block is already gone, and returns 1 with stderr (closing nothing, so teardown keeps the task records) when inventory is unreadable, the block moved sessions, the block is still in the recorded session but its tab no longer carries the task's scoped title, or the block is still present after a failed close.

Real tests may share the captain's running Tern daemon rather than inventing an isolated window.
`tests/tern-test-safety.sh` permits cleanup only for a currently listed session whose name carries the `fm-test-` prefix and whose id the test created.
It refuses empty or non-numeric ids, name mismatches, unreadable listings, and any session that hosts the caller's own `$TERN_PANE`.
The only sanctioned teardown is `tern_safe_kill_session <session_id> <want_name>`; tests never enumerate-and-close unrelated sessions or the captain's live remote blocks.

## Active limits

- tern is experimental and has no dedicated real-backend CI lane.
- Secondmate spawns are unsupported (`fm-spawn.sh` refuses `--secondmate` on `backend=tern`).
- The away-mode `/afk` supervisor backend does not support tern; only `tmux`, `herdr`, and `rex` supervisor panes are accepted.
- Native agent state requires a Tern window control endpoint; remote-host or headless daemon access that can `ls`/`capture` may still lack `ctl`.
- Multiplexers swallow TSP: a Tern block hosting tmux or Herdr never shows native Tern agent state.
- There is no verified native push-event wait (`tern events` is not treated as an agent-transition stream; `has_push` stays herdr-only).
- On Tern 0.9.4 remote-host blocks observed here, plain and `--ansi` capture of an omp TSP surface are empty, and `--surfaces` returns transcript text without omp's composer, so composer-only submit proof is `unknown` for omp and native state is the submit path when `ctl` works.
- Creating a session or tab does not attempt focus restore; focus behaviour is not live-verified here.
- A target can disappear after structural readiness and before the operation.
- Large 64-bit ids are authoritative; tooling that coerces JSON numbers can corrupt endpoints.

## Regression entry points

```sh
tests/fm-backend-tern.test.sh
tests/fm-backend-tern-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tern) records the active source, fake-CLI, and live evidence boundaries, including what this host could and could not prove.
