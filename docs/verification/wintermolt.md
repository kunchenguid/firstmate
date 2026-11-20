# Wintermolt TUI worker verification

Verified on 2026-11-20 on macOS arm64 with the wintermolt 0.7.0 release binary (built from upstream lupin4/wintermolt revision 8b1a8a2), tmux 3.6, and an OpenAI-compatible cloud provider through the stock `openai` backend (`WINTERMOLT_BACKEND=openai`, `WINTERMOLT_OPENAI_URL`, that backend's key variable, `WINTERMOLT_MODEL`).
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/wintermolt.md) owns operating limits; the [spawn header](../../bin/fm-spawn.sh) owns concrete launch mechanics.
Primary, secondmate, non-tmux backends, `--plain`, `-e`, `--web`, `--chat`, `--gateway`, and `--mcp-server` were not exercised and remain unsupported.
The installed binary carries the operator's local `forai` HTTP bearer patch; every fact below was re-checked against that patched binary and against upstream main's `docs/BACKENDS.md` at the fork-synced revision 954262b, and the adapter deliberately uses only the stock upstream `openai` backend surface that both share.

## Reusable guards

The token-spending guard drives the real TUI on a private tmux socket in a throwaway workspace; the backend and provider are the operator's own wintermolt environment, and `FM_WINTERMOLT_LIVE_ENV` may name a script that exports them.

```bash
FM_WINTERMOLT_SIGNALS_LIVE=1 \
FM_WINTERMOLT_LIVE_HOME="$throwaway_root" \
FM_WINTERMOLT_LIVE_ENV="$script_exporting_WINTERMOLT_BACKEND_and_its_key" \
bash bin/fm-test-run.sh tests/fm-wintermolt-signals-live-e2e.test.sh

bash bin/fm-test-run.sh tests/fm-wintermolt-harness.test.sh
```

An unavailable binary is reported by the shared `fm_live_gate`; explicit opt-in refuses missing capabilities.

## Live signal guard results (2026-11-20, wintermolt 0.7.0)

```text
ok - composer: the idle TUI reads empty through the shipped classifier
ok - identity: the anchored wintermolt process name is what detection reads
ok - busy: the pinned footer carries the busy verdict
ok - interrupt: one Escape stops the turn and leaves an empty ready composer
ok - exit: /quit exits the TUI to the pane shell
all wintermolt live signal checks passed [wintermolt 0.7.0]
```

Established in that run, on the real binary:

- The composer box is the shared rounded bordered shape; the idle placeholder `Type a message, or /help` renders as a reverse-video cursor cell on the first character plus one de-emphasized palette run (`38;5;8`), which the ghost stripper cannot reach (a palette index outside the fixed 232-255 ramp), so the pane reads `empty` only through the wintermolt-scoped rule in `bin/fm-composer-lib.sh`.
- A typed draft renders the opposite shape (default-foreground text, cursor cell after it) and reads `pending`; the busy row `working… (Esc stops, Ctrl+C quits)` shares the placeholder's cursor-cell shape and reads `pending-unproven` (the `…` defeats the ASCII geometry proof), never `empty`.
- That busy-row verdict is why a submitted steer cannot be confirmed by the composer alone: it reads `pending-unproven`, never `empty`, whatever the turn is doing. This run read the row after its own probe prompt; it did not submit through the shared submit core, so the confirmation itself is covered below, not by this run.
- The pane foreground is exactly `wintermolt`; a bash tool subprocess is its direct child and inherits no identity variable, only backend-config variables, so detection is anchored ancestry alone.
- One Escape stops a running turn; one `/quit` exits to the pane shell.

## Submit confirmation (2026-11-21, wintermolt 0.7.0, tmux 3.8)

Measured on the real TUI on a private tmux socket with a local
OpenAI-compatible chat-completions stub as the model backend (no external
provider), driving the shipped `fm_backend_send_text_submit` - the exact call
`bin/fm-spawn.sh` and `bin/fm-send.sh` make:

- One `send-keys -l` write of a whole message does not land. A 51-character
  steer reached the composer as its last 31 characters, while the same text
  written in 8- and 16-character chunks landed whole (composer text exact,
  typed state `held`) and the identical single write into a pane running `cat`
  arrived intact - so the loss is the TUI's input handling, not tmux. A
  wintermolt burst is therefore written in chunks (`FM_WINTERMOLT_TYPE_CHUNK`,
  8 characters by default, spaced `FM_WINTERMOLT_TYPE_INTERVAL`) behind tmux's
  own `--` end-of-flags marker, because a chunk can begin with `-` wherever the
  text happens to break; every other pane keeps the one-shot write.
- The composer is one row that scrolls horizontally: a wholly landed draft
  wider than the row shows only its tail. Measured on 0.7.0, 80 columns showed
  73 characters, 60 columns showed 53, and the box chrome is 7 columns, so a
  full row is `pane_width - 7` characters.
- A head-truncated write renders the same tail as a scrolled full draft, so a
  suffix is only accepted as proof when the burst was written in the
  TUI-safe chunks above and the visible run fills the row (the shipped read
  allows `pane_width - 10`, three columns of slack over the measured chrome).
  A shorter run is still refused, so a truncated short message is never read
  as the tail of a long one.
- With that, a 132-character brief pointer submitted at the first ready frame,
  and a 113-character steer and a 51-character steer submitted on a settled
  TUI, all returned `empty` at 80 columns. The stub received the whole message
  in every request, with one user message per request; the TUI's own
  empty-reply retry against the stub produced the second request, carrying the
  identical message, not a second send.
- The busy footer rendered 0.03s after Enter, far inside the 60 x 0.5s budget the
  spawn gate already grants the same verdict.
- The burst is verified against the composer's own text before Enter, because a
  literal burst typed while the TUI is still settling its input loop is dropped
  or truncated, and the composer such a burst leaves behind reads exactly like a
  submitted turn. A burst that provably landed nothing is replayed; a composer
  holding a fragment, or content that is not ours, refuses the submit.
- Not measured live here: a burst the TUI swallows whole and the replay that
  retypes it (this binary truncated a long whole-message write rather than
  swallowing it, and the chunked write lands), and the grace re-read that
  judges the last permitted burst. `tests/fm-wintermolt-harness.test.sh` covers
  both with a simulated TUI.

## Lane rehearsal results (2026-11-20, wintermolt 0.7.0)

A full lane against the real `bin/fm-spawn.sh`, real `bin/fm-control.sh`, a private tmux socket, and a scratch git project with its own treehouse pool, recorded in the task's private evidence:

```text
spawned wintermolt-lane-1 harness=wintermolt kind=ship mode=local-only yolo=off window=firstmate:fm-wintermolt-lane-1 worktree=...
=== lane: busy verdict: busy wintermolt-regex
interrupt-delivered wintermolt-lane-1 harness=wintermolt backend=tmux verified=agent-alive cancel=confirmed
=== lane: idle interrupt refused, worker untouched
stopped wintermolt-lane-1 harness=wintermolt backend=tmux endpoint=firstmate:fm-wintermolt-lane-1 worktree=...
=== LANE-OK: spawned, briefed, proved busy, interrupted, exited
```

Established in that run:

- The readiness gate passes on the pinned keybind footer; at 80 columns the trailing status cell is truncated to an ellipsis while `Esc quit` stays, so the keybind segment is the ready signal.
- The TUI swallows keys typed at its first footer frame (reproduced: a pointer typed immediately after the first ready capture never reached the composer and no turn started), so the delivery gate retypes the pointer only while nothing is echoed and the composer provably holds nothing, and reports success only on the busy verdict. An echoed pointer is never retyped, because the worker already received it.
- The interrupt verb waits - bounded by the control settle window - for the rendered busy verdict to clear and then reports `cancel=confirmed`; without that wait the working row persists for a redraw moment and an immediately following exit read a busy composer and refused.
- The interrupt verb refuses on an idle pane ("requires a proven running turn") and leaves the worker running, because the same key quits an idle wintermolt outright, draft included.
- The exit verb types `/quit` into a proven-empty composer and reports `stopped`.

Only a readable idle footer settles that cancellation claim: a pane that stays
busy reports `pane-still-working` and one whose capture fails reports
`pane-unreadable`, both unconfirmed. The lane exercised the cleared-footer case
only; `tests/fm-control.test.sh` covers the other two.

## Spawn lane re-run (2026-11-21, wintermolt 0.7.0, tmux 3.8)

Re-run of the same `bin/fm-spawn.sh` lane in a lab home against a local
OpenAI-compatible stub, on an 80-column tmux session. The backend environment
has to be present where the tmux session is started, because a new window
inherits the tmux server's environment and not the spawning process's; with
`WINTERMOLT_BACKEND`, `WINTERMOLT_OPENAI_URL`, the backend key,
`WINTERMOLT_MODEL`, and `WINTERMOLT_NO_FALLBACK` exported there, the launch, the
readiness gate, the 96-character brief-pointer submit, and the delivery gate all
passed at that width:

```text
spawned labwm1 harness=wintermolt kind=ship mode=local-only yolo=on window=primary:fm-labwm1 worktree=...
  > Read the brief at .../data/labwm1/launch-brief.md and follow it exactly.
  [openai] request: 6899 bytes (~2k tokens est)
  openai · anthropic/claude-sonnet-4  ⠴ working
  model: anthropic/claude-sonnet-4
  user: 'Read the brief at .../data/labwm1/launch-brief.md and follow it exactly.'
EXIT=0
```

The stub received the whole pointer, and the same pane showed the `Esc stop`
footer with its `working…` composer: the brief arrived. This width is the point
of the re-run: before the scroll-tail proof, the same lane at 80 columns refused
the pointer because only its tail was visible, so the earlier claim that the
lane passed held only on a pane wide enough to show the whole pointer. The same
lane against a tmux server without that backend environment starts the TUI on
its own default backend (`ollama` in its footer), so a lane run there measures
the stub, not the adapter.

## Non-interactive backend surface (2026-11-20)

Established with `wintermolt -e` on the same binary and provider:

- `WINTERMOLT_BACKEND=openai` with `WINTERMOLT_OPENAI_URL` (full chat-completions URL) and that backend's key variable answered a round trip and completed a real bash tool call, so this is the authoritative OpenAI-compatible surface; the `forai` HTTP mode of the patched binary was deliberately not used.
- A wrong model id with `WINTERMOLT_NO_FALLBACK=1` produced `[fallback] off (WINTERMOLT_NO_FALLBACK=1): OpenAI failed (HttpError)` and exit 1, never a substitute model.
- The same wrong id with fallback enabled produced `[fallback] OpenAI failed (HttpError), trying alternatives...` and `[fallback] Trying Ollama (qwen3:8b)...` with a full Ollama setup hint, which is the silent-substitution hazard the launch pin exists to prevent.
- A backend name that cannot be built (`WINTERMOLT_BACKEND=bogus`) printed its reason and exited 1 before the first request; a cloud backend without its key did the same, so an unusable backend never reaches the readiness gate.
- A provider HTTP 500 mid-session errored the turn visibly (`[openai HTTP 500] ...` then `[Error] API call failed: HttpError` in the pane) and returned the TUI to its ready footer - no fallback, no crash.

## Unverified

- No primary Stop guard, secondmate hook, Herdr lifecycle, resume, `--plain`/`-e` lane surface, or non-tmux backend was exercised.
- `config/crew-exclude-tools` is not mapped to `WINTERMOLT_TOOL_BLOCKLIST`; a home that lists exclusions refuses a wintermolt spawn.
- The launch-pinned variables were verified against the operator's environment only for the `openai` backend; the other stock backends inherit their own documented variables untested.
