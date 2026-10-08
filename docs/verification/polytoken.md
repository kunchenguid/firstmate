# Polytoken CLI worker verification

Audience: maintainer verification.

Verified 2026-10-07 on macOS arm64 with `polytoken 0.8.19` (`~/.local/bin/polytoken`).
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/polytoken.md) owns operating facts; executable owners carry launch and state mechanics.
This verification covers crewmates and scouts on the TUI-pane-plus-REST-control hybrid the captain approved the same day (pane inspection and backend parity, control verbs on the daemon's typed REST API).
Primary, secondmate, and Herdr pane placement are outside this guarantee and remain Phase 2 follow-up.

## Refresh commands

```sh
polytoken --version
polytoken print models
bash tests/fm-polytoken-harness.test.sh
FM_POLYTOKEN_SIGNALS_LIVE=1 bash tests/fm-polytoken-signals-live-e2e.test.sh
```

The credentialed guard runs the real binary on the cheap `zai/glm-5.3-flash(low)` model inside a throwaway HOME whose XDG config stages a copy of the operator's global config and whose data home stages a copy of the operator's existing license acceptance, so every daemon or TUI write - session trees, logs, even a TUI crash log - lands in the lab, never the operator's store.
It drives the real Firstmate verbs on a private tmux server: the launch is `bin/fm-spawn.sh`'s generated polytoken command, the steer is `bin/fm-send.sh`, the interrupt, relaunch, and exit are `bin/fm-control.sh`, and liveness is the tmux backend's agent-state read; only worktree allocation uses a `treehouse` stand-in.
The guard never passes `--accept-license-terms` and never answers the license dialog (the captain's 2026-10-07 decision makes it a blocker).
Failures name the installed polytoken version.

## Live guard results

On 2026-10-07 the refresh invocation completed with exit 0:

```text
ok - polytoken 0.8.19: the live model catalog still lists the cheap low-effort reference
ok - polytoken 0.8.19: fm-spawn's generated launch starts a bound, alive worker on the generated config and facet
ok - polytoken 0.8.19: the brief ran and fm-harness.sh detects polytoken from a real tool subprocess
ok - polytoken 0.8.19: the stop hook closes the busy record and touches the turn-ended marker
ok - polytoken 0.8.19: fm-send steers a real turn that opens the busy record and renders the busy row
ok - polytoken 0.8.19: fm-control interrupt cancels the real turn over REST and leaves the worker alive
ok - polytoken 0.8.19: fm-control relaunch replaces the worker through the generated launch and rebinds its session
ok - polytoken 0.8.19: fm-control exit stops the real worker and the backend reads it dead
```

The portable regression (`tests/fm-polytoken-harness.test.sh`) passed all 25 cases the same day.

## Observed vendor surfaces

Config layering, all probed in scratch `--config-dir`/`--sessions-dir` labs (the operator's global config and 13 live daemons untouched):

- A root `--config-dir` passed to a runtime command becomes the daemon's `--project-config-dir` and its `config.yaml` REPLACES the global config entirely - no `--global-config-dir` reaches the daemon - so a `version: 4`-only project config.yaml fails startup with `providers: at least one provider is required` while the operator's global config lists six.
- Hook layers load from the process cwd's `.polytoken/hooks.json` and the global config dir; hooks placed in the root `--config-dir` do not load.
- A hook handler is a single command string that receives NO argv: a handler written as `<script> <arg>` runs the script with `$*` empty, so every firstmate hook is a generated self-contained script.
- A failing hook breaks the turn: a `pre_model_turn` hook exiting 1 errors the turn with `hook exited with code 1`.
- `--sessions-dir <root>` writes the versioned sibling `<root>-v1/<session-id>/` beside the given root; `sessions --format json` (with the same `--config-dir` and `--sessions-dir` flags) lists the live session's id, pid, port, and credential path, which is how a pane-attached launch is bound into task metadata.
- `POST /turn/cancel` answers `{"status":"cancel_requested","generation":N}` and the turn then ends with no `stop` hook fired.
- `POST /terminate` on an attached session answers `{"status":"terminating"}`, wedges the TUI on an SSE reconnect error for about twenty seconds, records a TUI crash log, and only then exits; `/quit` exits cleanly, self-deletes the credential, and the daemon exits on its own shortly after.
- The daemon imposes no cap on consecutive `stop`-hook `continue` outcomes (five forced continuations all ran to the hook's own bound).
- The mid-turn busy row is ` Running for <elapsed>s` with a leading space; the turn-end rows are `Completed in <t>`, `Errored after <t>`, and `Canceled after <t>`.
- A TUI-attached daemon stayed alive minutes past idle; the license acceptance record is `${XDG_DATA_HOME:-~/.local/share}/polytoken/license-acceptance.json` keyed by revision, which is where an isolated-home lab parked on the first-start dialog until the operator's record was staged.

Ancestry, verified from a real tool subprocess inside a live session:

```text
77247 61844 /opt/homebrew/bin/bash
61844     1 polytoken
    1     0 /sbin/launchd
```

A tool subprocess's parent IS the session daemon, so the anchored `polytoken)` comm case in `bin/fm-harness.sh` reaches comm strength at hop one; foreign markers from the launching session (`AGENT=1`, `ORCA_AGENT_HOOK_ENV`, `ORCA_OPENCODE_AGENT`) were verified reaching a worker tool subprocess through the pane, which the launch command's fixed `env -u` set (including `-u AGENT`) plus ORCA_*/FM_ clearing loop removes.
