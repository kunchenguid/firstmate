# Antigravity CLI

Google's `agy` TUI, verified end to end on 2026-09-09 with agy 1.1.28 on Linux.
Launch shape: `agy --dangerously-skip-permissions --model <model> --effort <low|medium|high> --prompt-interactive "$(...brief...)"`.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no agy wake protocol.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Semantic `agy-hook`: `PreInvocation` opens a turn, `PostInvocation` and `Stop` both close it. Neither closer fires on a manual Escape interrupt, so a cancelled turn is closed by this plane's own interrupt-idle record instead of by a hook. |
| Rendered tail | Not a state source, but the running turn's footer is the one ASCII busy token: `esc to cancel`, absent when idle. The spinner is braille and the phase text (`Running command...`) varies per turn; neither is ever a signal. |
| Turn end | `Stop` fires once per turn after the final response, carrying `conversationId`, `workspacePaths`, `transcriptPath`, `executionNum`, and `terminationReason`. The `Stop` hook keeps the `state/<id>.turn-ended` touch as the watcher NOTIFICATION. |
| Exit | `/exit`, one Enter; prints `Resume with -c (or command below): agy --conversation=<id>`. |
| Interrupt | Single `Escape`, which prints `Interrupted` and leaves the agent running. The composer does not repollute; it returns to its empty `>` prompt. |
| Skill | `/<skill>`, for example `/help`; ONE Enter submits, with no popup swallow observed. |
| Autonomy | `--dangerously-skip-permissions`, verified unattended on a real Bash tool call with no approval gate. |
| Marker | None; detect the anchored `agy` ancestry after clearing foreign primary markers, the same ancestry-only posture as codex, opencode, and kimi. |
| Resume | `agy --conversation=<id>` restores full history; `--continue` resumes the most recent conversation. Resume re-resolves the model from stored defaults, so a relaunch must re-pass `--model`/`--effort`. |
| Model | `--model <model>`; discover through `agy models`, which lists `gemini-3.8-flash-low/medium/high` and the rest of the account's catalog. |
| Effort | `--effort <low\|medium\|high>`; `xhigh` and `max` stay in task metadata per the record-and-omit contract. |
| Trust | Dialog `Do you trust the contents of this project?` with `Yes, I trust this folder` preselected for Enter. Neither approval flag covers it, so the spawn pre-registers the worktree in agy's own `trustedWorkspaces` store through `bin/fm-agy-trust.sh`. |

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` installs a firstmate-owned `fm-busy-state` hook into the worktree's `.agents/hooks.json` with `PreInvocation` opening the minted busy generation and `PostInvocation`/`Stop` closing it, and `../../../../../bin/fm-teardown.sh` retires it.
This wiring belongs only to the canonical exact `agy` adapter template, which receives busy-state wiring, the turn-end hook, and trusted busy state together.
A raw agy-shaped launch is an unverified escape hatch: it receives no busy-state wiring or turn-end hook and therefore has no trusted busy state.
The install is create-or-merge because that path may be the project's own committed file: a missing file is created and removed at teardown, while an existing file is byte-backed-up to `state/<id>.agy-hooks-backup` and restored byte-exact, so a tracked project file is never deleted and never blocks teardown's dirty check.
`../../../../../bin/fm-agy-lib.sh` owns both directions, and the duplicate idle from the two closers is idempotent and deliberately not de-duplicated.
Each hook command prints the empty JSON object agy's hook contract requires and tolerates a refused event, so a stale-generation writer can never break agy's own lifecycle.

## Detection

agy publishes no harness-identity marker: no `AGY_*` variable was observed in a live worker's environment (agy 1.1.28), so `../../../../../bin/fm-harness.sh` detects it by the anchored `agy` ancestry arm alone.
The shipped CLI is a natively compiled ELF (`ps -o comm=` reports `agy`), so unlike the node-bundled gemini CLI no interpreter fallback is needed.
The inherited-marker hazard is shared with codex, opencode, and kimi: an agy worker under a claude primary still carries the launcher's `CLAUDECODE`, and the spawn clears the foreign markers at the launch boundary for the same reason cursor's and gemini's templates do.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no agy protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
agy's `Stop` hook and its `--conversation` resume make a future primary integration plausible, but it remains unbuilt work, not a fact to rely on.
