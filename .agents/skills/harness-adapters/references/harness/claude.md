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
| Autonomy | `--permission-mode auto`, so the worker runs under Claude's own classifier rather than `--dangerously-skip-permissions`, which bypassed every check. The spawn also sets `CLAUDE_CODE_DISABLE_FAST_MODE=1`; see "Auto mode" below. |

Fresh-worktree or first-machine launch may show the workspace-trust confirmation, and a first-ever auto-mode session may show Claude's auto-mode entry warning.
The bypass-permissions confirmation can no longer appear, because Firstmate no longer passes `--dangerously-skip-permissions`.
Inspect within about 20 seconds, accept the required choice with `FM_HOME=<active-home> ../../../bin/fm-send.sh <window> --key Enter` unless already bound, and verify instructions started.

## Auto mode

Auto mode is not unconditional.
On 2.1.251 the session silently falls back to the prompting `default` mode when auto mode is unavailable for the account's plan, unavailable for the session model, disabled by settings, blocked because fast mode is on, or when the classifier transcript grows too long.
An unattended crewmate has nobody to answer the permission prompt it falls back to, and the `claude-hook` busy fold keeps that pane reading as busy rather than surfacing a hold.
The spawn sets `CLAUDE_CODE_DISABLE_FAST_MODE=1` to remove the one trigger a launch command controls, so a captain's own `/fast on` cannot degrade a running crewmate.
The plan, model, and classifier-transcript triggers remain server-side and are not launch-controllable, so treat a Claude pane that stops progressing without a status write as a possible permission prompt and peek it before assuming it is working.
Firstmate threads an arbitrary `--model` from the dispatch profile into this same launch, so a model without auto-mode support is the most likely local cause.

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
