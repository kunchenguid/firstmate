# Claude

Busy hooks verified 2026-07-28 on Claude Code 2.1.220.

## Operating facts

| Fact | Value |
|---|---|
| Busy | Owned hooks: `UserPromptSubmit` opens while `Stop`, `StopFailure`, and `SessionEnd` close; manual interrupt emits no hook, so control reports delivered keys and live endpoint only, publishes no idle event or cancellation claim, and usually leaves `claude-hook` busy. |
| Exit | `/exit`. |
| Interrupt | Single Escape. |
| Skill | `/<skill>`, for example `/no-mistakes`. |
| Model | `--model <model>`; discover through the interactive `/model` picker, with alias or full-name shape documented by `claude --help`. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`, verified on 2.1.196. |

The first launch into any worktree of a never-trusted repository may show a workspace-trust dialog because `--dangerously-skip-permissions` bypasses permission checks only, not that separate gate.
For an authorized Claude crewmate or scout launch, pass `--accept-claude-trust` to `../../../bin/fm-spawn.sh`; this is the task's explicit project-scoped grant to accept the dialog automatically if it appears.
The grant is retained in that task's metadata across same-harness relaunches and harness switches, and without it an observed dialog is left untouched with a supervisor-visible blocker.
With that grant, `../../../bin/fm-spawn.sh` handles the dialog on launches and relaunches, but a backend must support Down when the trust option is not already focused.
After accepting, it requires both a cleared dialog and evidence that Claude resumed processing the launch brief.
The dialog is cancel-focused by default, so a bare Enter selects "No, exit" and quits Claude; never accept it with a plain `--key Enter`.
The shared detector is `fm_composer_claude_trust_dialog_state` in `../../../bin/fm-composer-lib.sh`, while the Claude launch path in `../../../bin/fm-spawn.sh` owns navigation, postcondition verification, and failure reporting.
A missing project-scoped trust grant or a backend without Down support leaves Claude alive on the dialog and records one actionable `blocked:` diagnostic in `state/<id>.status` instead of attempting an unauthorized or unsupported key.
On a capable backend, an uncleared dialog, an unconfirmed processing transition, or an unreadable settle window records a `failed:` status rather than leaving a silently idle pane.
Inspect the pane and use `stuck-crewmate-recovery` if a blocked or failed trust launch recurs.
Trust acceptance is a one-time repository cost rather than a per-worktree cost, and Firstmate never writes or pre-seeds Claude's managed trust store.
`../../../docs/verification/runtime-backends.md` owns the dated Claude version, persistence evidence, and live-refresh boundary for these facts.
A genuinely fresh isolated `CLAUDE_CONFIG_DIR` requires a human-completed OAuth login before Claude Code shows repository trust and does not inherit the machine's existing Keychain credentials.
Testing a fresh isolated store therefore needs that human login before the repository-trust check; the ordinary Firstmate deployment shares its already-onboarded and authenticated `CLAUDE_CONFIG_DIR` with Claude workers.
The first-run theme picker is outside this automatic trust handling because selecting a theme still leads to the same human login wall and cannot make a fresh isolated store unattended.

## Composer ghost

Completed turns can render dim predicted text inside an empty composer, indistinguishable in plain `tmux capture-pane`.
The spawn scopes `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` to every Claude worker and secondmate without changing global config.
CLI `--prompt-suggestions` affects print or SDK mode only and did not suppress interactive ghost text on v2.1.186.

As defense in depth, `fm_composer_strip_ghost` in `../../../bin/fm-composer-lib.sh` removes SGR-2 runs before pending classification on styled tmux, Herdr, and Zellij readers.
`../../../docs/herdr-backend.md` under "Composer and injection safety" owns dark-TRUECOLOR tradeoffs and `../../../docs/verification/runtime-backends.md` owns captures.
Styled capture stays internal to the boolean detector; `fm-peek` and model-facing captures remain plain, without escapes.

## Primary integration

Primary behavior was verified 2026-07-04 on 2.1.201, preserved 2026-07-08 on 2.1.204, and Stop auto-arm revalidated 2026-07-24 on 2.1.219.
This differs from the worker hook, which only touches a task marker through `.claude/settings.local.json`.

Primary `.claude/settings.json` registers `../../../bin/fm-turnend-guard.sh --claude` and `../../../bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
Guard exit 2 plus stderr forces continuation.
Stop payload `stop_hook_active=true` follows any hook-driven continuation, including async reawakening, so Claude mode ignores it and uses cooperative claim and epoch plus bounded re-block; default Codex mode keeps it as a one-block loop guard.

Project `.claude/settings.json` loads only when the exact project root is the session root; Claude does not search parents, so Firstmate starts at repository root.
Hooks still run through cwd-sensitive `/bin/sh`, so tracked commands anchor through `"$CLAUDE_PROJECT_DIR"/bin/...`.
`../../../docs/turnend-guard.md` owns details.

The Stop-owned watcher hook runs every Stop, foregrounds `../../../bin/fm-watch-arm.sh` only when eligible, and uses exit-2 async reawakening as notification.
The model handles notifications but never routine re-arm.
Claude's PreToolUse seatbelt blocks directly, and its deny is honored only with empty stdout; `../../../docs/arm-pretool-check.md` owns that contract.

### Delegation guard

Claude delegation, scheduling, and worktree tools can create work without `state/<id>.meta`, making guards unable to count it.
`../../../bin/fm-subagent-pretool-check.sh` denies delegation-shaped tool names.
A primary should also keep an untracked home-local `permissions.deny` for known delegation tools so they disappear from the schema.
Never track it in project `.claude/settings.json`, which is Claude-only and propagates to worker copies where it would disarm legitimate delegation.
`../../../docs/subagent-guard.md` owns the contract, recommendation, `FM_ALLOW_SUBAGENT=1`, and applicability review.

On Claude 2.1.217 the tool presents as `Agent`, and both `Agent` and `Task` worked as deny keys in an A/B with nonsense control.
`permissions.allow` pre-approves rather than controls availability, so no closed positive allowlist exists.
