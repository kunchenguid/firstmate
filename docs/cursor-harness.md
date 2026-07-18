# Cursor Agent CLI harness notes

Status: **detect, session-lock, and provisional crewmate launch**. Not a fully verified Firstmate adapter.

Preferred spawn (provisional template in `bin/fm-spawn.sh`):

```sh
bin/fm-spawn.sh <task-id> <project-dir> cursor
```

That launches `agent --yolo --trust "$(cat <brief>)"` so the workspace trust prompt is skipped and the brief is fed as the initial prompt.

Raw escape hatch (still valid):

```sh
bin/fm-spawn.sh <task-id> <project-dir> 'agent --yolo --trust "$(cat __BRIEF__)"'
```

## Why this doc exists

Cursor CLI (`agent`) is a supported primary for this home's operating preferences, but Firstmate's verified adapters remain `claude`, `codex`, `opencode`, `pi`, and `grok`.
Without lock/ancestry recognition, a Cursor primary cannot acquire the fleet lock and stays read-only.
Without `--trust` and a brief-fed launch, crewmates stall on trust dialogs and sit idle until a human pastes the brief.

## Evidence (2026-07-18)

Observed primary process shape under Herdr:

- `comm`: `MainThread`
- `args`: `/home/dylan/.local/bin/agent --use-system-ca /home/dylan/.local/share/cursor-agent/versions/2026.07.16-899851b/index.js`
- `agent --version`: `2026.07.16-899851b`
- Herdr Cursor integration: `herdr integration status` reported `cursor: current (v1)`
- `agent --help` documents `--trust` (skip workspace trust prompt) and `--yolo` (alias for `--force`)

Commands that previously failed, then succeeded after `bin/fm-lock.sh` / `bin/fm-harness.sh` recognition:

```text
bin/fm-lock.sh
# before: error: cannot locate harness process in ancestry
# after:  lock acquired: harness pid <agent-pid>

bin/fm-harness.sh
# before: unknown
# after:  cursor
```

Hermetic coverage: `tests/fm-cursor-lock.test.sh`.

## Still unverified (do not treat as done)

- Busy signature / composer idle classification for Cursor
- Primary turn-end guard, PreToolUse seatbelt, and session-start nudge adapters
- Supervision protocol snippet under `docs/supervision-protocols/`
- Secondmate agent-process liveness classification for a Cursor secondmate

Record those empirically before promoting Cursor from provisional launch to a verified adapter in `harness-adapters`.
