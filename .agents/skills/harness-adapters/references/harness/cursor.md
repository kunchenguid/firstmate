# Cursor Agent

Verified for crew and scout work on tmux on 2026-08-11 and Herdr on 2026-08-12, and for secondmate and primary work on 2026-08-13, with Cursor Agent CLI 2026.08.11-e8db854.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `fm_cursor_resolve_binary` in `../../../bin/fm-cursor-lib.sh` resolves stable launcher `cursor-agent` or legacy `agent`, never `cursor`; both symlink into `~/.local/share/cursor-agent/versions/<version>/cursor-agent`, whose target auto-update replaces. |
| Launch | Positional instructions with `--trust`, `--auto-review`, `--sandbox enabled`, optional `--model <model>`, and `--workspace <absolute-task-worktree>`, after clearing foreign primary markers. |
| Models | Use current-account `cursor-agent --list-models` or legacy `agent --list-models`; the drifting observed list had only `cursor-grok-4.5-high` and `cursor-grok-4.5-high-fast` for Grok plus several `xhigh` ids, so choose a returned reasoning id and never assume low or medium Grok. |
| Busy state | `../../../bin/fm-busy-lib.sh` folds the per-conversation transcript as `cursor-transcript`: `role:user` opens and typed `turn_ended` closes success or abort, covering manual interrupt; nothing is armed or seeded, and this backend-agnostic source was identical on tmux and Herdr. |
| Exit command | `/exit`. |
| Interrupt | Single Escape returns the placeholder with no clear key; control makes no cancellation claim because an aborted transcript close appeared within seconds in some runs and not within twenty in others. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Cursor discovers Firstmate's user skills. |
| Resume | No verified native pane resume; use deterministic relaunch. |
| Autonomy | `--auto-review --sandbox enabled`, so the worker runs under Cursor's own review and sandbox controls. This replaced `--yolo` (the documented `--force` alias, footer `Run Everything`), which switched both off. |
| Trust | `--trust` suppresses the dialog; the autonomy flags do not, and every task has a fresh path. |
| Marker | `CURSOR_INVOKED_AS=cursor-agent` on agent and children, plus `CURSOR_AGENT=1` on child or tool processes; other `CURSOR_*` variables are not identity markers. |
| Effort | No verified flag; `references/common/model-and-effort.md` owns unsupported-value handling. |
| Composer | Bare borderless row with `→` (U+2192); de-emphasized placeholders `Plan, search, build anything` when fresh and `Add a follow-up` later. |

The slash popup consumes the first Enter; that Enter closes it and a genuine second Enter submits through the shared retry.

## Detection

Cursor does not clear inherited `CLAUDECODE`, so a Cursor worker under Claude carries both markers.
`../../../bin/fm-harness.sh` tests Cursor first, and launch also clears foreign markers.
Both remain necessary: sanitization covers Firstmate launches, ordering covers hand-started sessions.

Cursor is a bundled Node script, so tmux can report bare `node` while `ps -o comm=` carries its install path.
Bare `node` matches nothing; `../../../bin/fm-cursor-lib.sh` proves identity from Cursor's name or install tree in path or argv zero.
Unrelated `node` or `agent` remains `other`, folded to ambiguous rather than dead.
Auto-update changes the target, not this rule.

## Composer and delivery

Cursor parks its terminal cursor outside the composer: `#{cursor_y}` was below the footer idle and typed, with `#{cursor_flag}` zero, so cursor-anchored reads are always unknown.
`../../../bin/fm-tmux-lib.sh` lets the bottom-most shape win only after structural Cursor proof.
The composite then reads empty or pending, verified on 2026-08-13, while every other harness keeps strict blank-cursor behavior and a dead shell never reads empty.
`../../../bin/fm-supervise-daemon.sh` can therefore require affirmatively empty before away-mode delivery without a Cursor-only branch.

Submission also uses an idle-to-busy transition.
Match stable token `ctrl+c to stop`, never spinner verbs that changed from `Working` to `Running` between turns.

Confirmation is verified only on tmux and Herdr.
Herdr reports Cursor `blocked` in every state, so its native idle path is unreachable; the composer path sees the mid-turn placeholder beside `ctrl+c to stop` as pending.
`../../../bin/backends/herdr.sh` baselines before Enter and confirms the footer transition, so an already-busy pane cannot confirm.

Zellij, cmux, and Orca do not consult that footer.
A typed-plane native invocation or explicit backend send lands but reports unconfirmed and exits nonzero; ordinary steering uses the durable inbox and exits zero at enqueue.
Treat this as confirmation failure, not loss, because text lands and busy state comes from the transcript.
Teaching those backends is separate cross-harness work requiring live checks.

Reverse-video placeholder remnants and Herdr half-block edges belong to `../../../bin/fm-composer-lib.sh`; without the edges a bare composer swallows the footer and idle reads pending.
`../../../docs/verification/runtime-backends.md` owns captures.
Refresh with `FM_HARNESS_LIVENESS_DRIFT=1 ../../../bin/fm-test-run.sh ../../../tests/fm-harness-liveness-drift-live-e2e.test.sh`.

## Worktree boundary

Firstmate enters its acquired worktree and passes the same absolute path through `--workspace`.
Never pass Cursor `-w` or `--worktree`, which allocates a second copy under `~/.cursor/worktrees` and breaks isolation.
The CLI supports repeatable `--add-dir`, but the adapter adds none; positional instructions need no grant to their private directory.
Example: `../../../bin/fm-spawn.sh <task-id> <project> --scout --harness cursor --model cursor-grok-4.5-high`.

## Primary integration

Primary supervision is the stop-hook park in `../../../docs/supervision-protocols/cursor.md` through tracked `.cursor/hooks.json`; primary and secondmate launches require `--trust` or hooks do not load.
Cursor exposes 20 project events plus a Claude-Code compatibility map that loads `.claude/settings.json`.
Tracked hooks register `stop`, `sessionStart`, and two `preToolUse` seatbelts through `$CURSOR_PROJECT_DIR`; Claude entries stand down on Cursor payloads under `../../../docs/turnend-guard.md`.

`stop` cannot block because exit 2 is a silent no-op, so `../../../bin/fm-turnend-guard-cursor.sh` parks on supervision and returns one bounded `followup_message`.
It does not fire in headless `cursor-agent -p`.
`preCompact` is unregistered because it cannot inject context, so digest re-emission after Cursor compaction remains deferred.
