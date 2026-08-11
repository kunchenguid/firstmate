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

Portable adapter regressions: `tests/fm-cursor-harness.test.sh`.
Cross-cutting primary-lock, relaunch, composer/delivery, liveness, bootstrap, and teardown safeguards are pinned by `tests/fm-session-lock-ancestry.test.sh`, `tests/fm-control-relaunch.test.sh`, `tests/fm-composer-lib.test.sh`, `tests/fm-send-strict.test.sh`, `tests/fm-tmux-agent-liveness.test.sh`, `tests/fm-bootstrap.test.sh`, and `tests/fm-teardown.test.sh`.

## Verified facts

### Process identity

The launcher is a bash wrapper that `exec -a "$0"`s the bundled Node binary.
The macOS live process reports `cursor-agent` directly, while Linux procps can report `node` in `comm` and retain the full `cursor-agent` launcher path only in `argv[0]`.
Firstmate therefore accepts either the exact process name or an exact `cursor-agent` executable-path component in ancestry.
The adapter does not use `CURSOR_AGENT` as identity evidence because the verified CLI does not export it and an inherited value can outlive the process that set it.
A bare `cursor` basename is deliberately rejected so IDE helpers cannot be misread as this adapter.
[`runtime-backends.md`](runtime-backends.md#agent-liveness-name-sources) owns the resulting tmux liveness verdict and its portable regression.

### Launch and autonomy

```
cursor-agent --yolo --trust [--model <id>] "$(encode launch-brief < brief)"
```

- `--yolo` (alias of `--force`) produces the `Run Everything` footer and auto-approves tool use.
- `--trust` skips the workspace trust prompt on a fresh worktree.
- The brief is a positional prompt.
- Foreign markers `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, and `CURSOR_AGENT` are cleared at launch.

### Model and effort

`--model <id>` is verified.
There is no standalone `--effort` flag (`cursor-agent --help` rejects `--effort`).
Effort is encoded in catalog model ids from `cursor-agent --list-models` / `cursor-agent models`.
Help documents bracket overrides such as `'claude-opus-4-8[effort=high]'`, but those forms were rejected by the live available-model list for this account on 2026-08-10, so firstmate records requested effort in task metadata only and never synthesizes a bracket override.

### Busy state and turn-end

Project hooks under `.cursor/hooks.json` remain visible to Git safety checks, which exempt only exact transaction-owned generated snapshots:

| Event | Observed | Firstmate action |
|---|---|---|
| `beforeSubmitPrompt` | fires for positional launch briefs and interactive submits | busy via `cursor-hook` |
| `stop` | fires with `status=completed` on normal end, and `aborted`/`error` on Ctrl+C interrupt | idle + touch turn-ended |
| `sessionEnd` | fires on `/exit` | idle |

Busy source name: `cursor-hook`.
Unlike Claude, Cursor's `stop` hook fires on interrupt.
Firstmate records the original state of both hook paths, merges its entries with existing regular files, and records the exact generated snapshots before replacement.
On a failed spawn or teardown, an unchanged generated path returns to its original state, while a safely divergent `hooks.json` loses only Firstmate's exact entries and keeps unrelated edits.
Symlinked paths, malformed JSON, ambiguous ownership, or unexpected hook-script divergence fail closed instead of overwriting work.
The dirty-worktree check exempts only exact transaction-owned generated snapshots or an exact committed baseline, and teardown restores the hook transaction before returning the worktree lease.
The transactional hook merge and divergent restore require `python3`; bootstrap reports the missing runtime when Cursor is selected by static or dispatch configuration, and spawn refuses before task setup if it is unavailable.

### Interrupt and exit

| Fact | Value |
|---|---|
| Interrupt | single `Ctrl+C` (footer shows `ctrl+c to stop` mid-turn) |
| Exit | `/exit` (slash popup also lists `/quit`) |
| Composer clear after interrupt | none required |

### Composer

Idle placeholder is plain text `→ Add a follow-up` (U+2192), with no dark-truecolor ghost styling observed.
The `→` glyph is container-only evidence: a bare arrow remains `unknown`, while the Cursor-specific send path accepts the exact placeholder only inside a structurally proven composer for a recorded Cursor target.
When the submitted message itself equals a Cursor placeholder, delivery still needs independent busy-transition evidence instead of treating the unchanged text as acknowledgement.

### Secondmate / primary boundary

cursor is crewmate/scout only.
`bin/fm-spawn.sh` and `fm_control_harness_supports_kind` refuse `--secondmate` on cursor.
The session-lock identity layer rejects Cursor as a primary lock owner and stops its ancestry walk at Cursor, so a nested worker cannot claim an outer primary's lock.
There is no `docs/supervision-protocols/cursor.md` because Cursor primary operation is unsupported rather than routed through the `unknown` protocol.

## Runtime backend review

| Backend | Applicability | Evidence |
|---|---|---|
| tmux | Supported | Live TUI probes and process classification of exact `cursor-agent` |
| herdr | Unverified / refused | Product spawn fails closed; the corrected response-only live guard remains evidence-only until a passing dated result is recorded |
| zellij | Unverified / refused | No Cursor-specific live spawn, send, or composer evidence |
| cmux | Unverified / refused | No Cursor-specific live spawn, send, or composer evidence |
| orca | Unverified / refused | Orca can deliver `C-c` and Enter, but Cursor product spawn remains refused |

### Herdr evidence-only live guard

Command: FM_CURSOR_HERDR_LIVE=1 bin/fm-test-run.sh tests/fm-cursor-herdr-live-e2e.test.sh.
Product Cursor spawn on Herdr remains refused.
The opt-in guard creates an isolated Herdr lab pane directly and tests the real Cursor CLI plus Herdr submission transport without enabling the product spawn path.
The guard requires exact assistant response rows for both the launch brief and the follow-up, so echoed prompt text cannot satisfy it.
A passing run is necessary evidence only; support still requires a dated result and an explicit allowlist change.
The 2026-08-10 run used substring matching and does not support a Herdr compatibility claim.

## Still unproven / out of scope

- Primary turn-end guard, PreToolUse seatbelt, and watcher supervision protocol for a cursor primary.
- Secondmate launch and remote secondmate recovery.
- Bracket-form effort overrides on every parameterized model id.
- Credential/login automation (`cursor-agent login` is never invoked by firstmate).
