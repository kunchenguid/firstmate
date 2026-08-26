## cursor (VERIFIED CREWMATE/SCOUT 2026-08-11 on tmux and 2026-08-12 on Herdr, and SECONDMATE/PRIMARY 2026-08-13, Cursor Agent CLI 2026.08.11-e8db854)

Cursor Agent CLI runs crewmate, scout, secondmate, and primary work.
Its primary supervision is the stop-hook park in [`docs/supervision-protocols/cursor.md`](../../../docs/supervision-protocols/cursor.md), registered in tracked `.cursor/hooks.json`; a Cursor primary or secondmate must be launched with `--trust` or no project hook loads at all.
Do not confuse `harness=cursor` using a `cursor-grok-4.5-*` model with `harness=grok`, which is the separate xAI Grok Build CLI and credential surface.

| Fact | Value |
|---|---|
| Binary | Resolved through `fm_cursor_resolve_binary` (bin/fm-cursor-lib.sh). `cursor` is NOT the CLI: the installed names are `cursor-agent` and the legacy alias `agent`, both symlinked into `~/.local/share/cursor-agent/versions/<version>/cursor-agent`. The STABLE launcher is used, never the versioned target, which the CLI replaces on its own auto-update. |
| Launch | A positional prompt with `--trust`, `--yolo`, `--model <model>` when selected, and `--workspace <absolute-task-worktree>`, behind `env -u` of the foreign primary markers. |
| Models | Validate against `cursor-agent --list-models` for the current account rather than a fixed list; that list has already drifted once. The live catalog contains only `-high` Grok ids (`cursor-grok-4.5-high`, `cursor-grok-4.5-high-fast`) and several `xhigh` ids, so an assumed low/medium Grok id is invalid. |
| Busy state | Its own per-conversation transcript, folded on demand by `bin/fm-busy-lib.sh` (source `cursor-transcript`). Each turn is bracketed by a `role:user` open and a typed `turn_ended` close covering `success` and `aborted`, so unlike Claude's `Stop` hook this source covers manual interruption. Nothing is armed and no record is ever seeded. Backend-agnostic, and confirmed identical on tmux and Herdr. |
| Exit command | `/exit` |
| Interrupt | Single Escape. The composer returns to its placeholder rather than the cancelled prompt, so NO clear key is needed (unlike muse). `bin/fm-control-lib.sh` claims no cancellation acknowledgement: the aborted transcript close appeared within seconds in some runs and not within twenty in others. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`. Cursor discovers firstmate's user-level skills; `/no-mistakes` autocompleted with firstmate's own description and invoked the skill. |
| Slash submission | The popup is REAL and swallows the first Enter: the first closes the popup and a SECOND submits, the same hazard as grok. The submit core's retried Enter covers it. |
| Autonomy | `--yolo`, the documented alias for `--force`, whose TUI footer reads `Run Everything`. |
| Trust dialog | `--trust` suppresses it. `--yolo` does NOT, and every task gets a fresh worktree path, so without `--trust` every spawn would block on it. |
| Environment marker | `CURSOR_INVOKED_AS=cursor-agent` on the agent process and its children, plus `CURSOR_AGENT=1` on child/tool processes. Other `CURSOR_*` endpoint and credential variables are not identity markers. |
| Effort | No effort flag exists. The requested axis is recorded in task metadata and never reaches the launch command. |
| Composer | A BARE row whose prompt glyph is `→` (U+2192); no border. Idle placeholders are `Plan, search, build anything` fresh and `Add a follow-up` after a turn, drawn de-emphasised so a styled capture separates them from real typed text. |
| Primary hooks | Tracked project-scope `.cursor/hooks.json` registers `stop`, `sessionStart`, and two `preToolUse` seatbelts, all anchored through `$CURSOR_PROJECT_DIR`. Cursor ALSO loads `<project>/.claude/settings.json`, so the tracked Claude entries stand down on a Cursor-delivered payload; `docs/turnend-guard.md` owns that predicate. |
| Primary limits | `stop` does not fire in headless `cursor-agent -p`. `preCompact` is deliberately unregistered because it cannot inject context, so a Cursor primary does not re-emit its digest after a compaction; that surface is deferred to a follow-up. Project hooks need `--trust`. |

**Detection ordering is load-bearing.**
Cursor does NOT clear an inherited `CLAUDECODE`, so a cursor worker under a claude primary carries both markers and whichever is tested first wins.
`bin/fm-harness.sh` tests the cursor markers BEFORE the `CLAUDECODE` check, and the launch additionally clears the foreign markers.
Both are kept: launch sanitization only covers sessions fm-spawn started, while the ordering also covers a cursor session a human started by hand.

**The `node` process-name caveat.**
Cursor runs as a bundled node script, so tmux reports `#{pane_current_command}` as a bare `node` while `ps -o comm=` carries the cursor-agent install path.
`node` matches no harness name pattern, so identity comes from Cursor's own name or install tree in the path or argv[0] (`bin/fm-cursor-lib.sh`).
An unrelated `node` or `agent` is deliberately left `other`, which the liveness callers fold into `ambiguous` rather than `dead`.
Because the versioned install path is what identifies the alias, an auto-update changes the resolved target but not the identity rule.

**Cursor parks its terminal cursor outside its composer.**
`#{cursor_y}` pointed below the footer both when idle and with real text typed, and `#{cursor_flag}` was 0, so tmux's cursor row is not a composer locator for a Cursor pane and the cursor-ANCHORED read answers `unknown` in every state.
`bin/fm-tmux-lib.sh` therefore reclassifies a pane it can prove is Cursor the way every cursorless backend already classifies it, letting the bottom-most shape win, so the composite `fm_tmux_composer_state` now reports a real `empty` or `pending` for a Cursor pane on tmux (verified 2026-08-13).
That gate is Cursor's own structural process identity from `bin/fm-cursor-lib.sh`, never the verdict alone, so the strict blank-cursor-row posture stays in force for every other harness and a dead shell still never reads `empty`.
This is what makes away-mode escalation delivery work against a Cursor primary: `bin/fm-supervise-daemon.sh` needs an affirmatively-empty composer before it types, and it needed no Cursor-specific branch once the reader was correct.
Submission is additionally acknowledged from the idle-to-busy transition, which is why cursor's `ctrl+c to stop` token is part of the delivery busy union in `bin/fm-composer-lib.sh`.
Match that TOKEN and never the spinner verb: the same version rendered `Working` in one turn and `Running` in the next.

**Delivery confirmation is verified on tmux and Herdr only.**
Herdr reports a Cursor pane `blocked` in EVERY state - idle, mid-turn, and after - so its native idle-baseline submit path is unreachable for Cursor and the composer branch runs instead; that branch reads a mid-turn row carrying the placeholder beside `ctrl+c to stop`, which is `pending`.
`bin/backends/herdr.sh` therefore confirms a Cursor submit from a rendered-footer idle-to-busy transition, taking the baseline before the first Enter so an already-busy pane never confirms.
Zellij, cmux, and Orca share a submit core that never consults that footer, so a typed-plane Cursor send there (a harness-native invocation or an explicit backend target; ordinary text steers ride the durable inbox and exit 0 at enqueue) LANDS but `bin/fm-send.sh` reports delivery unconfirmed and exits non-zero.
Treat that as a known limitation of those three backends rather than a lost message: the text is in the pane and the worker's own recorded state still comes from its transcript fold.
Teaching the shared core the same transition is deliberately separate work, because it changes the submit path for every harness on those three backends and needs its own live validation on each.

The composer's reverse-video placeholder remnant is taught to the ONE fleet-wide screen classifier in `bin/fm-composer-lib.sh`, not to any adapter.
Herdr additionally draws the composer's rules with half-block glyphs, which the same shared classifier owns as structural edges; without them a bare composer's wrap region swallows the footer below it and an idle pane reads `pending`.
`docs/verification/runtime-backends.md` "Cursor Agent CLI" owns the dated captures, and the drift guard that refreshes them is:

```bash
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

Firstmate acquires and enters the treehouse worktree before launching Cursor, then passes that same absolute path through `--workspace`.
NEVER pass Cursor's own `-w/--worktree`: it allocates a SECOND worktree under `~/.cursor/worktrees` and would break firstmate's worktree-isolation contract.
The raw CLI accepts repeatable `--add-dir <path>` for deliberate multi-root workspaces; the adapter adds none, and the brief rides inline as the positional prompt, so the private brief directory needs no grant.

Spawn a Cursor scout with an explicit model:

```bash
bin/fm-spawn.sh <task-id> <project> --scout --harness cursor --model cursor-grok-4.5-high
```

