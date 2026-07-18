# Cursor Agent CLI harness notes

Status: **detect and session-lock only**. Not a verified Firstmate launch template.

Crewmates and scouts must still spawn with a raw launch command until a full adapter is verified, for example:

```sh
bin/fm-spawn.sh <task-id> <project-dir> 'agent'
bin/fm-spawn.sh <task-id> <project-dir> 'agent --yolo'
```

## Why this doc exists

Cursor CLI (`agent`) is a supported primary for this home's operating preferences, but Firstmate's verified adapters remain `claude`, `codex`, `opencode`, `pi`, and `grok`.
Without lock/ancestry recognition, a Cursor primary cannot acquire the fleet lock and stays read-only.

## Evidence (2026-07-18)

Observed primary process shape under Herdr:

- `comm`: `MainThread`
- `args`: `/home/dylan/.local/bin/agent --use-system-ca /home/dylan/.local/share/cursor-agent/versions/2026.07.16-899851b/index.js`
- `agent --version`: `2026.07.16-899851b`
- Herdr Cursor integration: `herdr integration status` reported `cursor: current (v1)`

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

- Launch template in `bin/fm-spawn.sh` (use raw `agent` / `agent --yolo`)
- Busy signature / composer idle classification for Cursor
- Primary turn-end guard, PreToolUse seatbelt, and session-start nudge adapters
- Supervision protocol snippet under `docs/supervision-protocols/`
- Secondmate agent-process liveness classification for a Cursor secondmate

Record those empirically before promoting Cursor from detect/lock-only to a verified adapter in `harness-adapters`.
