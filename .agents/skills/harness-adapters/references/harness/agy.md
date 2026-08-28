# Agy (Antigravity CLI)

Verified crewmate/scout 2026-08-28 on Antigravity CLI 1.1.22.
Antigravity CLI is a CREWMATE and SCOUT adapter only.
`../../../bin/fm-spawn.sh` refuses `--secondmate` on agy, and agy has no supervision protocol under `../../../docs/supervision-protocols/`, so a firstmate primary detected as agy falls back to the `unknown` protocol.
The refusal rests on stronger evidence than Muse's: agy 1.1.22 has no lifecycle-hook surface at all (`agy plugin`, `agy mcp`, and `agy agents` were each checked), so there is nothing a primary turn-end supervision cycle could be armed on.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Executable `agy` resolved from `PATH`; spawning refuses if it does not exist. |
| Launch | Interactive TUI with the brief delivered through `-i/--prompt-interactive`; agy accepts no positional prompt. |
| Models | `agy models` lists the account's catalog. Pass bare base names (`gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash`, `gemini-3.1-pro`) plus a separate `--effort`; the listed ids already bake in an effort suffix (`gemini-3.6-flash-medium`), and passing `--effort` alongside one of those is rejected as a conflict. `--effort` is unsupported outright on the `claude-*` and `gpt-oss-*` catalog entries, so firstmate omits it there. |
| Busy | Its own per-conversation SQLite step table, bound by the per-task `--log-file`. A pull source with no writer, like Muse's session log and Cursor's transcript. |
| Exit | `/exit` |
| Interrupt | Single Escape or single Ctrl+C; the composer is left clean and needs no follow-up clear key, and the cancelled step settles to the ordinary finished status. |
| Skill | None usable. An unmatched slash command is intercepted client-side and never reaches the model; use natural language. |
| Autonomy | `--dangerously-skip-permissions`, which suppresses BOTH edit and shell-command approvals. `--mode accept-edits` covers edits only and stalls on every new shell command. |
| Trust | Exact-path workspace trust that NO flag suppresses; firstmate pre-writes the grant. See below. |
| Slash submission | The popup swallows the first Enter, and an unmatched command is dropped entirely rather than submitted as text. |
| Marker | `ANTIGRAVITY_AGENT=1` on child/tool processes; ancestry matches the exact process name `agy`. |
| Composer | The `separated` shape: content between two dim-gray horizontal rules, with a bright-blue `>` prompt glyph and no idle ghost or placeholder text. |
| Effort | `--effort <low\|medium\|high>`, conditional on the model; see the Models row above for the suffix conflict. Verified 2026-08-28 on Antigravity CLI 1.1.22: the ceiling is `high`, `xhigh` and `max` are rejected explicitly, so firstmate omits them. |

## Trust is exact-path and must be pre-established on every worktree

agy gates a workspace behind a trust dialog whose matching is EXACT, not by prefix: launching in a fresh subdirectory of an already-trusted parent still raises it.
Every new task worktree therefore hits it, every time, and no CLI flag suppresses it - `--dangerously-skip-permissions` covers tool approvals only and leaves this dialog untouched.
`../../../bin/fm-spawn.sh` handles it by writing the exact worktree path into the `trustedWorkspaces` array of `~/.gemini/antigravity-cli/settings.json` BEFORE the pane is created, because agy reads that array at startup.

That file is the captain's own live settings, shared with their interactive use, so the write only ever appends, never reorders or removes an entry, refuses outright rather than rewriting a file that is not valid JSON, and replaces atomically under a firstmate-owned lock.
The path is stored verbatim rather than canonicalized: agy normalizes redundant separators but does NOT resolve symlinks, and the grant and the pane's working directory both come from the same recorded worktree, so canonicalizing one side would break a symlinked worktree.
Trust grants are retired at teardown: `../../../bin/fm-teardown.sh` reclaims the `trustedWorkspaces` entry so a torn-down worktree path does not stay trusted for whatever later recreates that path.

## Busy state is the conversation database, not the screen

agy persists one SQLite database per conversation under `~/.gemini/antigravity-cli/conversations/<id>.db`, whose `steps` table carries a `status` that is 3 exactly when that step has finished.
The busy predicate is "ANY row is not status 3", never "the highest-idx row is not status 3".
Those are not equivalent: a step that finishes AFTER the enclosing step that owns a running shell command leaves a settled row at the highest idx while the turn is still in flight, so the last-row form reads a FALSE IDLE mid-turn.
An interrupted step settles to 3 as well, so cancelling a turn leaves no permanent non-3 row that would pin the fold at busy; the only non-3 values observed are 2 and 8, both meaning a step is running.
`../../../bin/fm-busy-lib.sh` owns the fold and the two read-only open modes it needs.

The binding is by LOG FILE.
`fm-spawn` gives each task its own `--log-file`, removes any predecessor's copy first, and agy writes a `Created conversation <id>` line into it.
Do not bind by grepping the database blobs for the worktree path: that path appears only because agy happens to mention its cwd in first-turn reasoning, which nothing guarantees.
Pre-assigning the id does not work either - `--conversation <unknown-id>` warns `not found` and mints a fresh id anyway, and a pre-set `ANTIGRAVITY_CONVERSATION_ID` in the launch environment is ignored.

agy's rendered `esc to cancel` footer is a DELIVERY guard only and could not be a state source: agy auto-promotes a long shell command to its own background-task tracker and restores the idle footer while that turn is still running.

## Interrupt does not kill a backgrounded shell command

Escape and Ctrl+C both cancel agy's current model turn on a single press.
Neither kills a shell command agy has already promoted to its background-task tracker: the command runs to completion and agy resumes reporting on it afterwards.
A hard stop of in-flight shell work needs the pane or process tree killed, which is `exit` or `relaunch`, not the interrupt key.

## Resume and eager reading

`--continue`/`-c` and `--conversation <id>` both genuinely restore prior conversation state.
`relaunch` remains the deterministic path for every adapter, because the brief on disk is the durable instruction.

agy treats project instructions as live orders: on its first turn, unprompted, it read this repo's `AGENTS.md` and ran `../../../bin/fm-session-start.sh` on its own initiative.
A crewmate brief for an agy worker in a firstmate checkout should say plainly that the worker is a crewmate and must not run primary-session commands.

## Secondmate refusal

`fm_control_harness_supports_kind` refuses agy for a secondmate before any stop is attempted, the same pre-stop guard Muse uses, so `fm-control relaunch <secondmate> --harness agy` is refused before the running secondmate is stopped rather than after.
`../../../bin/fm-spawn.sh`'s secondmate positional arm also recognizes agy explicitly rather than falling to the catch-all, which previously misreported the refusal as "not a valid firstmate home".

Refresh every fact above with `FM_AGY_SIGNALS_LIVE=1 tests/fm-agy-signals-live-e2e.test.sh` after an agy upgrade.
