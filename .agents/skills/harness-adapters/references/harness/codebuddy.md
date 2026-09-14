# CodeBuddy Code

CodeBuddy's `codebuddy` (aliased `cbc`) CLI, wired into Firstmate's adapter sets on 2026-09-14 for codebuddy 2.150.0.
Statics were established from the installed binary's own `--help` text and process strings; the live harness behaviors below that are marked **unverified** must be confirmed by a supervised trial task before this adapter is treated as fully verified per `../../../../../AGENTS.md` section 4.
Crewmate and scout launch wiring is present in `../../../../../bin/fm-spawn.sh`; secondmate handling is wired at the spawn boundary but deliberately refused at the control plane until the trial passes.
Primary wiring is present too: the tracked `../../../../../.codebuddy/settings.json` mirrors the tracked Claude hook file, and the primary protocol is [`docs/supervision-protocols/codebuddy.md`](../../../../../docs/supervision-protocols/codebuddy.md).

## Operating facts

| Fact | Value |
|---|---|
| Binary | `codebuddy` on `PATH`, a Mach-O single binary (launcher is a symlink into `~/.local/share/codebuddy/versions/<version>/codebuddy`); alias `cbc`. |
| Launch | `codebuddy --permission-mode bypassPermissions "(--opinput encode launch-brief < brief)"` with `--model <id>` and `--effort <level>`; a positional prompt starts the supervised interactive TUI and auto-submits it, the claude/grok shape. `--permission-mode bypassPermissions` is the full unattended bypass; `-y/--dangerously-skip-permissions` still asks on HIGH/CRITICAL, so it is not used. |
| Model | `--model <id>`; the catalog listed by `codebuddy --help` in 2.150.0 includes `hy4-preview`, `hy3`, `hy3-x`, `deepseek-v4.1-flash`, `glm-5.3`, `glm-5.3-flash`, `glm-5.2`, `glm-5.1`, `glm-5v-turbo`, `minimax-m3`, `minimax-m2.7`, `kimi-k3-1`, `kimi-k2.8-preview`, `kimi-k2.7`, `kimi-k2.6`, `deepseek-v4-pro`. |
| Effort | `--effort minimal\|low\|medium\|high\|xhigh\|max`; the shared vocabulary maps low..max straight across, `minimal` is deliberately unreachable (record-and-omit). |
| Exit | `/exit` (the binary also accepts `/quit`); one Enter exits. |
| Interrupt | Single `Escape`, claude-style; **unverified** - to be confirmed by the trial, including whether an interrupt leaves the composer repolluted. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--permission-mode bypassPermissions` auto-approves tool calls for the run (full pass, unlike the `-y` shorthand). |
| Marker | None; CodeBuddy publishes no harness-identity env variable, so `../../../../../bin/fm-harness.sh` identifies it from process ancestry (`codebuddy` or `cbc`). `CODEBUDDY_CODE_*`, `CODEBUDDY_HOST`, and `CODEBUDDY_CLI_CAPABILITIES` are internal runtime variables, not identity markers, and are never promoted. |
| Resume | `--continue`/`--resume` exist, but there is no verified pane-resume contract yet; use deterministic relaunch until verified. |
| Composer | **Unverified**; whether the empty composer shape maps to `empty` or `unknown` waits on the trial. |

## Trust, and where the decision persists

Whether a fresh task worktree is gated behind a folder-trust dialog is **unverified** in this adapter.
CodeBuddy's own TUI does expose a workspace-folder manager (visible in the binary strings), so treat a fresh worktree like claude/agy until proven otherwise: if a launch wedges on a trust prompt, do not answer it with steering keys - record it under `../../../../../AGENTS.md` section 9, run the supervised trial, and only then decide whether a pre-registration helper is needed.
The trial task is the owner of this determination, exactly as `agy`'s trust behavior was established through its supervised trial.

## Credential precondition

CodeBuddy launches against the operator's own logged-in CodeBuddy account/config; a worker-reachable credential is assumed present because the spawn runs in a pane created by the operator's long-lived backend daemon under the same user.
An auth prompt or refusal at launch is a credential blocker under `../../../../../AGENTS.md` section 9: fix the environment and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process names `codebuddy` and `cbc` in `harness_process_verdict` (`comm` strength), never a wildcard, so unrelated commands cannot be misread.
No environment marker is promoted.
CodeBuddy does not clear an inherited `CLAUDECODE`/`PI_CODING_AGENT`, but a structural codebuddy ancestor outranks any retained foreign marker, the same rule that keeps opencode and agy honest.
codebuddy is in the session-lock name vocabulary (`../../../../../bin/fm-session-lock-lib.sh`), anchored as `^codebuddy$|^cbc$`, so a codebuddy primary can hold `state/.lock` and the Claude-family Stop auto-arm can prove it owns the home.

## Worker busy state and turn end

**Unverified**.
`../../../../../bin/fm-spawn.sh` arms no busy generation and writes no sidecar for codebuddy (no writer could clear a seeded record without a verified busy source), and `fm_busy_classify` in `../../../../../bin/fm-busy-lib.sh` reports the default `unknown` for it.
Do not fabricate a rendered-tail signature for codebuddy: the trial must observe a live busy/steady turn and pin down a signature (or a native Herdr `working` status) before any arm or classifier change lands, per the one-owner rule.

## Primary integration

Supported, on the Claude-compatible hook path, per `../../../../../AGENTS.md` section 4 and `../../../../../README.md` requirements.
CodeBuddy is a Claude Code clone: it fires `SessionStart`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStop`, `UserPromptSubmit`, `PreCompact`, and `Notification` with Claude's payload shape (`stop_hook_active`, `hookSpecificOutput`/`additionalContext`), honors exit-2 blocking, supports `asyncRewake`, and sets both `CLAUDE_PROJECT_DIR` and `CLAUDE_SESSION_ID`.
Its PROJECT settings come from `.codebuddy/settings.json` and `.codebuddy/settings.local.json`, NOT from `.claude/settings.json`, which is why the tracked `../../../../../.codebuddy/settings.json` exists rather than a reuse of the tracked Claude file.
That file mirrors the Claude registration: `../../../../../bin/fm-sessionstart-run.sh` on SessionStart, the arm and cd pre-tool checks plus the subagent guard on PreToolUse, and the `../../../../../bin/fm-turnend-guard.sh --codebuddy` plus `../../../../../bin/fm-claude-stop-autoarm.sh` pair (under `asyncRewake`) on Stop.
`--codebuddy` is an alias for the guard's `--claude` autoarm-cooperation mode, so a codebuddy primary shares Claude's supervision model: `fm_supervision_model` in `../../../../../bin/fm-wake-lib.sh` reports `autoarm` for it.
`../../../../../docs/supervision-protocols/codebuddy.md` owns the operating protocol.

Live-verified: a codebuddy primary running in this repo loaded the tracked `.codebuddy/settings.json` and fired the PreToolUse cd guard (`[persistent-cd]`); an isolated `codebuddy --print` probe confirmed a `SessionStart` command hook runs, sees `CLAUDE_PROJECT_DIR`, and has its stdout injected into model context; a nested codebuddy session claimed `state/.lock`, which the session-lock vocabulary change is what makes possible; and ending a turn with supervision needed ran the Stop pair for real - `bin/fm-claude-stop-autoarm.sh` armed a watcher cycle that closed on an actionable check, and its exit-2 rewake reached the session as a `Stop hook feedback` message (`check: rearm-resurface`) bound to a live codebuddy session pid.
Still unproven: the guard's own re-blocking branch, because every observed stop was allowed by a healthy watcher or an open auto-arm claim, plus CodeBuddy's worker composer and interrupt behavior; recorded in `../../../../../docs/verification/codebuddy-primary.md`.
Headless `codebuddy -p` turn-end behavior is **unverified**; run the primary session interactively, the same boundary Cursor's reference records.
