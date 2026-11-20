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
- The pane foreground is exactly `wintermolt`; a bash tool subprocess is its direct child and inherits no identity variable, only backend-config variables, so detection is anchored ancestry alone.
- One Escape stops a running turn; one `/quit` exits to the pane shell.

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
