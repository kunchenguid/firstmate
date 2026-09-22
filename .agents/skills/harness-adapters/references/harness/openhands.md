# OpenHands CLI

OpenHands's `openhands` TUI on OpenHands CLI 1.16.0 (SDK v1.21.0), Linux, through tmux: verified end to end on 2026-09-20, with brief delivery re-verified on 2026-09-22.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no openhands wake protocol.
`../../../../../docs/verification/openhands.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `openhands` from `PATH`, refused if absent. The installed CLI is a Python entrypoint; `ps -o comm=` on Linux still reports the live process name `openhands` (verified, CLI 1.16.0). |
| Launch | Foreign markers cleared, a writable `HOME` and `OPENHANDS_PERSISTENCE_DIR` so the profile store is not the operator's possibly root-owned `~/.openhands`, `OPENHANDS_WORK_DIR` pinned to the worktree, `LLM_MODEL` and `LLM_API_KEY` supplied through a firstmate-owned env file, then `openhands --override-with-envs --always-approve --exit-without-confirmation`. `-f`/`-t` are documented as composer seeds; spawn does not rely on them. It waits for the idle composer, then submits `Read the brief at <launch-brief> and follow it exactly.` plus Enter, and reports success only once `ESC: pause` shows the turn started. `--headless` is unused: it has no TUI for `ESC: pause` busy detection, steering, Escape interrupt, or `/exit`, and it exits when the first turn ends. |
| Busy state | No firstmate-owned hook writer, so nothing is armed and no record is seeded. `fm_busy_openhands_tail_busy` matches the pinned `ESC: pause` token in the working status line. |
| Rendered tail | A busy turn pins `Working (<n>s • ESC: pause)` above the composer, with a braille spinner. Idle replaces that row with a blank status line. `Working` alone is not a signal (Pi already owns that word). |
| Turn end | No turn-end hook or notification touch exists; completion arrives through the worker status protocol. |
| Exit | `/exit` plus Enter, with `--exit-without-confirmation` so the "Terminate session?" modal never appears. A slash-command completion popup can swallow the first Enter; the control plane already retries. Ctrl+C also exits under that flag (verified live). |
| Interrupt | Single `Escape`, which prints "Pausing conversation" and leaves the idle composer showing only its placeholder, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. `/help` lists OpenHands's own commands. |
| Autonomy | `--always-approve` (`--yolo`) auto-approves tool calls for the run. |
| Marker | None. A live TUI publishes no `OPENHANDS_*` identity variable; `OPENHANDS_PERSISTENCE_DIR` is a config path, not an identity. Inherited `GROK_AGENT=1` was observed on a live process and is cleared at launch. |
| Resume | `--resume` and `--last` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | No `--model` flag. The LiteLLM id is exported as `LLM_MODEL` with `--override-with-envs` (for example `fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash`). |
| Effort | No verified interactive effort flag; the requested axis stays in task metadata under the record-and-omit contract. |
| Composer | Bordered input whose idle placeholder is `Type your message, @mention a file, or / for commands`. |

## Credential precondition

A verified openhands worker ran with `LLM_API_KEY` and `LLM_MODEL` supplied through `--override-with-envs`.
`bin/fm-spawn.sh` takes `LLM_API_KEY` from the environment, or from `$FM_HOME/config/openhands-llm.env` when that file has an `LLM_API_KEY=` line, and refuses the spawn when neither source has a key.
`--override-with-envs` also requires `LLM_MODEL`; a spawn without `--model` and without `LLM_MODEL` in the environment is refused.
The unauthenticated TUI wizard was not used as a handled dialog: missing credentials are a fail-loud blocker.

## Writable HOME

`Path.home() / ".openhands" / "profiles"` is hardcoded in the SDK profile store and ignores `OPENHANDS_PERSISTENCE_DIR`.
A root-owned `~/.openhands` therefore crashes every launch with `PermissionError` even when persistence is redirected.
The spawn always uses a firstmate-owned per-task `HOME` under `state/<id>.openhands-home`, with identity symlinks (`.ssh`, `.gitconfig`, `.config`, `.local`, `.git-credentials`) back to the operator home so git and `gh` keep working, and sets `OPENHANDS_PERSISTENCE_DIR` and `OPENHANDS_WORK_DIR` beside it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `openhands`, never `*openhands*`.
A Python-interpreter fallback matches a script path whose last component is exactly `openhands`.
No environment marker is promoted.
openhands is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, rovo, and agy are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms no busy generation for openhands and writes no sidecar, exactly because no writer could ever clear a seeded record.
`fm_busy_openhands_tail_busy` matches the pinned `ESC: pause` token, hardcoded with no environment override, and `fm_busy_classify` reports `unknown openhands-regex` rather than idle when it is absent, because a long turn can scroll the marker out of the captured tail.
Teardown removes the per-task env file, persistence directory, and throwaway HOME.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no openhands protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
