# Verification: the cursor (Cursor Agent CLI) crewmate adapter

Active empirical evidence for firstmate's cursor adapter.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `2026.08.04-aaa8809` (`cursor-agent --version`) |
| Verified | 2026-08-10 |
| Binary | `cursor-agent` from PATH (`~/.local/bin/cursor-agent` -> versioned install under `~/.local/share/cursor-agent/versions/...`) |
| Platform | macOS arm64 (Darwin 25.6.0) |
| Account | authenticated Cursor account via `cursor-agent status` (credentials never copied into this record) |

Refresh command for the live signal guard:

```
FM_CURSOR_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-cursor-signals-live-e2e.test.sh
```

Portable regressions: `tests/fm-cursor-harness.test.sh`.

## Verified facts

### Process identity

The launcher is a bash wrapper that `exec -a "$0"`s the bundled Node binary, so the live process basename remains `cursor-agent`.
Detection uses `CURSOR_AGENT=1` (observed on the live process environment) as a fast path and exact `cursor-agent` ancestry as the guarantee.
A bare `cursor` basename is deliberately rejected so IDE helpers cannot be misread as this adapter.

### Launch and autonomy

```
cursor-agent --yolo --trust [--model <id>] "$(encode launch-brief < brief)"
```

- `--yolo` (alias of `--force`) produces the `Run Everything` footer and auto-approves tool use.
- `--trust` skips the workspace trust prompt on a fresh worktree.
- The brief is a positional prompt.
- Foreign markers `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` are cleared at launch.

### Model and effort

`--model <id>` is verified.
There is no standalone `--effort` flag (`cursor-agent --help` rejects `--effort`).
Effort is encoded in catalog model ids from `cursor-agent --list-models` / `cursor-agent models`.
Help documents bracket overrides such as `'claude-opus-4-8[effort=high]'`, but those forms were rejected by the live available-model list for this account on 2026-08-10, so firstmate records requested effort in task metadata only and never synthesizes a bracket override.

### Busy state and turn-end

Project hooks under `.cursor/hooks.json` (gitignored via git info/exclude):

| Event | Observed | Firstmate action |
|---|---|---|
| `beforeSubmitPrompt` | fires for positional launch briefs and interactive submits | busy via `cursor-hook` |
| `stop` | fires with `status=completed` on normal end, and `aborted`/`error` on Ctrl+C interrupt | idle + touch turn-ended |
| `sessionEnd` | fires on `/exit` | idle |

Busy source name: `cursor-hook`.
Unlike Claude, Cursor's `stop` hook fires on interrupt.

### Interrupt and exit

| Fact | Value |
|---|---|
| Interrupt | single `Ctrl+C` (footer shows `ctrl+c to stop` mid-turn) |
| Exit | `/exit` (slash popup also lists `/quit`) |
| Composer clear after interrupt | none required |

### Composer

Idle placeholder is plain text `→ Add a follow-up` (U+2192), with no dark-truecolor ghost styling observed.
`bin/fm-composer-lib.sh` treats `→` as an agent prompt glyph; idle regex defaults also match `Add a follow-up`.

### Secondmate / primary boundary

cursor is crewmate/scout only.
There is no `docs/supervision-protocols/cursor.md`, so a primary detected as cursor falls through to `unknown`.
`bin/fm-spawn.sh` and `fm_control_harness_supports_kind` refuse `--secondmate` on cursor.

## Runtime backend review

| Backend | Applicability | Evidence |
|---|---|---|
| tmux | Supported | Live TUI probes and process classification of exact `cursor-agent` |
| herdr | Supported for spawn/send when selected | Shared composer idle default includes `Add a follow-up`; Ctrl+C and Enter are deliverable |
| zellij | N/A for proof in this change | No cursor-specific key requirement beyond Ctrl+C/Enter already mapped |
| cmux | N/A for proof in this change | Same as zellij; idle default updated |
| orca | Interrupt-capable only | Orca can deliver `C-c` and Enter; Escape-only harnesses remain refused |

## Still unproven / out of scope

- Primary turn-end guard, PreToolUse seatbelt, and watcher supervision protocol for a cursor primary.
- Secondmate launch and remote secondmate recovery.
- Bracket-form effort overrides on every parameterized model id.
- Credential/login automation (`cursor-agent login` is never invoked by firstmate).
