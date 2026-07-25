# harness-adapters: claude

Load this reference only when a Claude runtime is being selected, spawned, recovered, interrupted, exited, resumed, or verified.
The core [harness-adapters](SKILL.md) reference owns universal selection, dispatch, backend, and verification invariants.

## Launch profile and model discovery

| Axis | Verified support |
|---|---|
| Model flag | `--model <model>` |
| Effort flag | `--effort <low\|medium\|high\|xhigh\|max>` |
| Evidence | Verified on Claude Code 2.1.196. |

Open the current interactive session's `/model` picker to discover available models.
`claude --help` documents the accepted alias or full-model-name input shape.
If the current authenticated environment does not establish the requested model or provider relationship, fail loudly and report the unresolved candidate.

## Worker operation facts

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it from an active firstmate session using `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, unless `FM_HOME` is already set to the active firstmate home.
Verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim or faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print or SDK mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes dim or faint SGR 2 ghost runs before pending-input classification on both ANSI-capable readers, tmux and herdr.
Its broader dark-TRUECOLOR placeholder handling and dark-theme tradeoff are documented in [`docs/herdr-backend.md`](../../../docs/herdr-backend.md) "Composer and injection safety", with active captures in [`docs/verification/runtime-backends.md`](../../../docs/verification/runtime-backends.md).
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

## Primary integration facts

`claude` blocks directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`claude` blocks watcher-arm anti-patterns directly through PreToolUse hooks.
Claude Code only honors a PreToolUse deny when stdout is empty, so [`docs/arm-pretool-check.md`](../../../docs/arm-pretool-check.md) owns that output-shaping quirk and its validation.
The primary-session watcher protocol is Stop-owned auto-arm through `bin/fm-claude-stop-autoarm.sh`, not a routine model-run re-arm command.

Claude exposes built-in delegation, scheduling, and worktree tools that a primary session can use to create work with no `state/<id>.meta`, which makes the whole guard stack inert because every guard counts that metadata.
The shipped mechanism is `bin/fm-subagent-pretool-check.sh`, a primary-home PreToolUse guard that denies a delegation-shaped tool name.
Claude primaries should also use an untracked per-home local `permissions.deny` list as hardening for known Claude delegation tools, because it removes them from the model's schema so they are never offered.
That deny list must not ship in tracked `.claude/settings.json` because it is Claude-only rather than harness-agnostic, and because tracked project settings propagate into linked worktrees where they disarm legitimate crewmates.
[`docs/subagent-guard.md`](../../../docs/subagent-guard.md) owns the full contract, the local deny-list recommendation, the `FM_ALLOW_SUBAGENT=1` escape hatch, and the per-harness applicability review.

Two verified delegation facts are pinned here.
The subagent tool presents to the model as `Agent`, and on Claude Code 2.1.217 both `Agent` and `Task` work as `permissions.deny` keys, verified by an A/B with a nonsense-name control.
`permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist.

`bin/fm-sessionstart-nudge.sh` is verified with native `SessionStart` stdout injection.
`.claude/settings.json` matches `startup`, `resume`, and `clear`, but not `compact`.

**Primary-session guard fact, verified 2026-07-04 on Claude Code 2.1.201, preserved 2026-07-08 on Claude Code 2.1.204, and Stop-owned auto-arm revalidated 2026-07-24 on Claude Code 2.1.219.**
This is separate from the per-task crewmate turn-end hook, which just `touch`es a marker file in a task's own `.claude/settings.local.json`.
The firstmate primary's own `.claude/settings.json` registers two Stop hooks: `bin/fm-turnend-guard.sh --claude` and the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
Exiting the guard with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows any stop-hook-driven continuation, including `asyncRewake` rewakes.
The primary guard therefore ignores it in `--claude` mode and uses the cooperative claim and epoch check plus a bounded re-block budget instead, while the codex-mode default still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory.
It does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd.
Keep the tracked commands anchored through `"$CLAUDE_PROJECT_DIR"/bin/...` and see [`docs/turnend-guard.md`](../../../docs/turnend-guard.md) for the verified Stop-hook details.
Claude Code's primary watcher protocol is Stop-owned.
The auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake.
The model drains and handles wakes but never runs a routine re-arm command.
