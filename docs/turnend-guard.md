# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work is in flight and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Shared predicate

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
The default cross-harness mode exits silently with no work in flight.
Claude's `--claude` mode also treats `state/x-watch.check.sh` as supervision need, so X-mode relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`.
A stale beacon blocks even when a watcher pid is live.
A fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- Cursor registers a fail-open `stop` hook in `.cursor/hooks.json` anchored through `CURSOR_PROJECT_DIR`.
  `bin/fm-turnend-guard-cursor.sh` maps Cursor's zero-based `loop_count` to the shared loop guard and returns the shared predicate's exit-2 reason as one `followup_message`.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and uses `bin/fm-turnend-guard-grok.sh` to resume the reported session once when the shared guard returns 2.
  The adapter intentionally omits `--permission-mode`, so a passive hook cannot grant stronger permissions than the resumed session default.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live owner, or `state/.claude-autoarm-epoch` contains a fresh rewake outcome.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override), then allows degraded with a visible `systemMessage`.
Any allow resets the budget.

Cursor, OpenCode, Pi, and Grok expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.
Cursor's stop adapter is similarly fail-open and account-gated; see Cursor empirical notes below.

If a passive adapter cannot invoke its SDK, find `grok`, or recover a Grok session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no X-mode relay poll remains healthy because it has no supervision need.
- Claude and Codex block directly, while Cursor, OpenCode, Pi, and Grok use bounded passive follow-ups.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Cursor empirical notes

Cursor Agent `2026.07.09-a3815c0` was validated on 2026-07-14 in a git-initialized scratch project.
Hook file used: `.cursor/hooks.json`.
Command run: `cursor-agent --print --trust --force --model gpt-5.6-sol-high "Reply with exactly FIRST"`.
Observed output: the project `stop` hook received `status`, `loop_count: 0`, `workspace_roots`, `conversation_id`, and `session_id`; `CURSOR_PROJECT_DIR` and hook process PWD both resolved to the scratch project; returning `{"followup_message":"CURSORHOOK: reply with exactly SECOND"}` caused one same-session continuation.
The tracked adapter sets `loop_limit: 1` and also allows any payload whose `loop_count` is already nonzero.
The local tracked-background Shell mechanism was exercised with `block_until_ms: 0`; the command returned a background-task handle immediately and later reported `CURSOR_BG_DONE` with exit code 0.
Desktop Agents Window proof remains incomplete: this environment did not expose a desktop Agents Window process tree, so the remaining check is to run `bin/fm-session-start.sh` from that window and confirm its tool subprocess either descends from `cursor-agent` or exposes a Cursor-specific marker that can be added without matching a generic `agent` process.

Task-worker hook loading was tested separately with a correctly structured plugin root containing `.cursor-plugin/plugin.json` with `"hooks":"hooks/hooks.json"` and `hooks/hooks.json` containing an absolute `stop` callback.
Commands run: `cursor-agent --print --trust --force --plugin-dir <plugin-root> --workspace <scratch> --model gpt-5.6-sol-high "Reply exactly PLUGIN"` and the equivalent interactive TUI launch.
Exact model outputs were `PLUGIN` and `PLUGININTERACTIVE`, but the callback marker remained absent in both cases.
Debug startup reported `plugin_imports_team_settings_ms: 1` and no ad hoc plugin-hook execution; user and project hooks still fired.
Firstmate therefore keeps passing the correctly structured task plugin for forward compatibility and installs one additive entry in `~/.cursor/hooks.json` as the documented fallback.
That fallback reads `workspace_roots`, requires a gitignored `.fm-cursor-turnend` token in the task worktree, validates the token against a private Firstmate registry, and no-ops for unrelated Cursor sessions.
It merges into the existing `stop` array and refuses malformed existing configuration instead of overwriting it.
`bin/fm-cursor-lib.sh` owns the shared-artifact mechanics: the hook script is written atomically (mktemp plus rename in the same directory), install and teardown serialize on a bounded mkdir lock, and the teardown that removes the last registry token also removes the shared hook script, Firstmate's own `hooks.json` stop entry, and the empty registry directory, so no Firstmate global state persists after the final Cursor task.
Every uncertain cleanup path (lock timeout, malformed `hooks.json`) skips cleanup and leaves the strict-no-op hook installed for the next teardown to retry.

Cursor Agent `2026.07.16-899851b` was revalidated on 2026-07-18 in a git-initialized scratch project on an individual Pro account, and hook execution proved to be gated server-side.
Commands run: `cursor-agent --print --output-format text --trust --force --model auto "Use the shell tool to run: printf HOOKPROBE. Then reply with exactly DONE."` (with cwd in the scratch project and again with `--workspace`), the same probe through `--plugin-dir` with the structured task plugin, and an interactive tmux TUI turn that executed a Shell tool call in a workspace whose `.cursor/projects/<hash>/.workspace-trusted` marker existed.
Observed output: the model ran the Shell tool and answered `DONE`/`TUIDONE` in every case, but no registered hook executed - not the project `.cursor/hooks.json` `preToolUse`/`stop` catch-all logger, not the plugin's `hooks/hooks.json` stop hook, and not the pre-existing user-level `~/.claude/settings.json` Stop hook that this build's config reader also discovers.
The installed bundle contains the full hook executor (event registry including `sessionStart`, `preToolUse`, `stop`; `loop_limit`, `failClosed`, and timeout handling; `CURSOR_PROJECT_DIR` and `CLAUDE_PROJECT_DIR` env injection; enterprise/team/user/project plus Claude-compat config paths) and a `claude_code_hooks_enabled` server-config field, and locally flipping that cached flag was reverted by the next server config refresh.
The 2026-07-14 record above (hooks firing on 2026.07.09-a3815c0) was collected on a different account, so hook availability varies by account rollout, not only CLI version.
Every tracked Cursor hook integration therefore stays strictly fail-open: the turn-end guard, seatbelts, nudge, and worker turn-end fallback activate only when Cursor executes hooks, and the watcher's pane-based staleness supervision plus the emitted supervision protocol carry the load when it does not.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the cooperative `--claude` claim wait, epoch allow, re-block budget, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, and Grok resume permission and recursion safety.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
`tests/fm-cursor-harness.test.sh` covers Cursor's tracked hook registration, follow-up adapter, busy signatures, and shared turn-end fallback contract.
