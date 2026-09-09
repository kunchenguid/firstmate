# Antigravity CLI (agy)

Google's `agy` CLI, verified as a CREWMATE and SCOUT adapter.
Launch shape: `agy --dangerously-skip-permissions -i "$(__OPINPUT__ encode launch-brief < __BRIEF__)"`.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | `agy-hook`: Native integration, tracked via `.status` hooks like other adapters. |
| Turn end | Hook-based, similar to gemini/claude. |
| Exit | `/exit`, one Enter, exit status 0. |
| Interrupt | Single `Escape` |
| Marker | `agy` in process ancestry / detection logic. |
| Resume | `--continue` or `--conversation <id>` |
| Model | `--model <model>` |
| Effort | `--effort <low|medium|high>` |

## Detection

Detected by `bin/fm-harness.sh` natively via the `agy` process name in `detect_own`.

## Capabilities

Verified to support autonomous runs via `--dangerously-skip-permissions`.
