# Hermes Agent verification

Audience: maintainer verification.

Verified 2026-09-26 on macOS arm64 with `Hermes Agent v0.21.5+2453.gd0288be (2026.9.24)`, git installer, bundled Python 3.14.7.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/hermes.md) owns operating facts; `bin/fm-hermes-lib.sh`, `bin/fm-hermes-plugin.sh`, `bin/fm-spawn.sh`, and the plugin under `.hermes/` own their mechanics.
Every live check below drove a real interactive `hermes chat --cli` in a pseudo-terminal rendered by a terminal emulator (no multiplexer was installed on the verification host), against a disposable standalone copy of a Firstmate home.
The Firstmate plugin was enabled for those sessions through a per-process Hermes managed-scope overlay (`HERMES_MANAGED_DIR` with `plugins.enabled: [firstmate]`) plus `HERMES_ENABLE_PROJECT_PLUGINS=1`, so the captain's own Hermes config was never edited.

## Refresh commands

```sh
hermes --version
hermes chat --help
bin/fm-hermes-plugin.sh status
bin/fm-test-run.sh tests/fm-hermes-harness.test.sh tests/fm-hermes-plugin.test.sh
```

## Source-verified facts

Read from the installed source tree (`~/.hermes/hermes-agent`):

- Plugin discovery: bundled, `$HERMES_HOME/plugins`, and `<cwd>/.hermes/plugins` only when `HERMES_ENABLE_PROJECT_PLUGINS` is truthy; non-bundled plugins load only when named in `plugins.enabled` (`hermes_cli/plugins_discovery.py`).
- `pre_llm_call` fires once per user turn and its `{"context": ...}` is appended to that turn's user message, never the system prompt; context over `hooks.output_spill.max_chars` (default 10000) is spilled to a file with a preview (`agent/turn_context.py`, `tools/hook_output_spill.py`).
- `on_session_start` fires lazily on the first turn and is skipped for a resumed session; `on_session_end` fires at the end of every turn (`agent/conversation_loop.py`, `agent/turn_finalizer.py`).
- `pre_verify` fires only for a turn that landed a `write_file` or `patch` edit and is capped by `agent.max_verify_nudges` (`agent/turn_stop_gates.py`).
- `pre_llm_call`, `pre_verify`, `on_session_start`, and `on_session_end` are bounded by `plugins.hook_callback_timeout` (default 30s); a timed-out or raising `pre_tool_call` blocks the tool (`hermes_cli/plugins_dispatch.py`).
- `PluginContext.inject_message` queues onto the classic CLI's interrupt queue while the agent runs and onto its pending input otherwise; the Ink TUI needs `plugins.entries.<id>.allow_gateway_injection` (`hermes_cli/plugins.py`).
- No compaction plugin hook exists; in-place compaction keeps the session id (`agent/conversation_compression.py`).
- The paid-model confirmation is deliberately independent of `--yolo` (`hermes_cli/main.py` `_confirm_startup_expensive_model_override`).
- `AGENTS.md` of this repository passes Hermes's context-file injection scanner (`agent/prompt_builder.py` `_scan_context_content`); a failing scan would replace the whole file with a `[BLOCKED: ...]` marker, so re-check after large `AGENTS.md` edits.

## Live results

- **Markers.** A terminal-tool child of a Hermes session started from a Claude Code pane carried `HERMES_AGENT=true`, `HERMES_SESSION_ID`, and the inherited `CLAUDECODE=1`, while `AI_AGENT` kept the Claude launcher's value; no `HERMES_CLI` variable exists.
- **Operational marker survival.** A `-z` prompt beginning with U+2063 was stored with its leading `E281A3` bytes intact in the session store, so the typed launch-brief envelope reaches the model.
- **Process identity.** The live session is `python3 -I -c '<bootstrap>'` with `from hermes_cli.main import main` in the inline program; `ps -o comm=` per pid reports the full interpreter path.
- **Composer.** Idle: a `❯` row between two rules showing a rotating placeholder in `#545e6b`; typed text renders in the default foreground. Busy: `☤ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel`.
- **Interrupt and exit.** One `Ctrl+C` during a running terminal-tool call interrupted the turn and restored the idle placeholder with the agent alive; `/quit` plus Enter left `/quit` in the composer (slash popup), and a second Enter exited, printing `hermes --resume <id>`.
- **Primary session start.** With the plugin loaded in a fresh home, `state/.session-start-complete` and `state/.lock` named the Hermes process, both plugin markers recorded the current module digests with that pid, and the model answered, with no tool call, that it had received the injected digest and that its supervision block names `hermes`.
- **Plugin-owned watcher.** The plugin started `bin/fm-watch-arm.sh --restart` itself after the digest; a startup `check` wake closed the cycle, `state/.watch-cycle-exits.log` recorded `reason=actionable-check successor=started`, and the plugin injected a `watcher` operational turn that ran `bin/fm-wake-drain.sh`.
  A captain message typed while that wake turn was running was folded in by Hermes's own mid-turn redirect, and both were answered.
- **Ink TUI primary.** With `plugins.entries.firstmate.allow_gateway_injection` granted, `hermes --tui` ran the agent in a `python -m tui_gateway.entry` child of its node renderer; `state/.lock` and the watch marker both named that gateway pid, the model answered from the injected digest that the header names `hermes`, and a plugin-delivered wake ran `bin/fm-wake-drain.sh` through the TUI injector.
- **Worker busy state.** A worker-role session against an armed incarnation advanced the record from the `fm-spawn` seed to `state=busy source=hermes-plugin` and then `state=idle source=hermes-plugin event=turn-end`, touched `<id>.progress` during the tool call and `<id>.turn-ended` at the end, and started no watcher.

## Known limits

- A Hermes process killed with SIGKILL leaves its arm child running, because the arm and watcher deliberately survive hangups; the next owning session's `--restart` retires it.
- An inbox note's `check` wake surfaces on the watcher's check cadence (`FM_CHECK_INTERVAL`, default 300s), not immediately.
- The launch-prompt signatures, the in-turn `pre_verify` continuation, and compaction re-emit are verified against source and the portable plugin test, not a live compaction.
- No terminal multiplexer was available on the verification host, so fleet spawn into a tmux or Herdr pane, `fm-send` delivery confirmation against the Hermes busy row, and away-mode daemon injection into a Hermes primary pane rest on the composer and busy signatures captured here and the portable spawn test, not a live multiplexer run.
