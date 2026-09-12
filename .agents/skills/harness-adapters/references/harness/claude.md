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
| Permissions | `--dangerously-skip-permissions` by default, or `--permission-mode auto` when `config/claude-permission-mode` is `auto`; the `auto` shape verified on 2.1.269, and `../../../../../docs/configuration.md` "Claude permission mode" owns the file. |

## Workspace trust

Claude gates a folder it has never seen behind an interactive workspace-trust dialog, so every fresh task worktree would hit it, and so would every secondmate home no operator has opened by hand.
`--dangerously-skip-permissions` does not cover that gate: `claude --help` records that the dialog is skipped only in non-interactive mode, through `-p` or a non-TTY stdout, and a spawned pane is interactive.
Every claude spawn therefore pre-registers the directory its pane starts in before launch, and the dialog does not appear: the task worktree for a ship or scout, and the home itself for a `--secondmate` spawn, in either seeded shape (a leased worktree or a standalone clone).
`../../../bin/fm-claude-trust.sh` records `hasTrustDialogAccepted` for that path in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` and owns the structural scope test each shape must pass, and `../../../bin/fm-spawn.sh` refuses the spawn when the registration fails rather than launching an agent that would wedge.

Never try to answer the trust dialog with a key.
Firstmate's key plane carries only Enter, Escape, and C-c with no arrow navigation, so it cannot move a dialog's selection at all, and the observed rendering starts on `No, exit`, which means a sent Enter ends the session instead of accepting.
A visible trust dialog means pre-registration did not take effect, so inspect the store and the spawn's error output rather than sending keys.

The once-per-machine bypass-permissions confirmation is a separate dialog, scoped to the machine rather than the path, and pre-registration does not address it.
Never send Enter to that one either: it was observed rendering in the same shape as the trust dialog, with the selection on `No, exit` and the footer `Enter to confirm . Esc to cancel`, so Enter ends the session rather than accepting.
Firstmate cannot move a selection with Enter, Escape, and C-c alone, so it cannot accept this dialog at all, and an operator accepts it once per machine instead.
Inspect the pane to identify which dialog is on screen, and report it rather than answering it.
A launch under `config/claude-permission-mode=auto` never meets the bypass confirmation, because it does not request bypass mode: on 2.1.269 `claude --permission-mode auto` reached the composer directly with the footer `⏵⏵ auto mode on (shift+tab to cycle)`, so a captain who refuses the bypass dialog selects `auto` there instead of accepting it.
The workspace-trust dialog is unaffected by the permission mode and still needs the pre-registration above.

Inspect, and inspect again after each confirmation, because clearing one gate can reveal the next.
`../../../bin/fm-crew-state.sh` reporting `harness busy` is not proof the agent started: `../../../bin/fm-spawn.sh` arms a busy record at launch, so a Claude task reads `harness busy (fm-spawn)` from the moment it is spawned, and a worker parked on either dialog keeps reading that indefinitely.
Read the source token in the parenthesis rather than the word `busy`: only `harness busy (claude-hook)` is a real Claude turn.
Prove the start by reading the pane for real tool calls before reporting the task as under way.

## Composer ghost

Completed turns can render dim predicted text inside an empty composer, indistinguishable in plain `tmux capture-pane`.
The spawn scopes `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` to every Claude worker and secondmate without changing global config.
CLI `--prompt-suggestions` affects print or SDK mode only and did not suppress interactive ghost text on v2.1.186.

As defense in depth, `fm_composer_strip_ghost` in `../../../bin/fm-composer-lib.sh` removes SGR-2 runs before pending classification on styled tmux, Herdr, and Zellij readers.
`../../../docs/herdr-backend.md` under "Composer and injection safety" owns dark-TRUECOLOR tradeoffs and `../../../docs/verification/runtime-backends.md` owns captures.
Styled capture stays internal to the boolean detector; `fm-peek` and model-facing captures remain plain, without escapes.

## Feedback drafts

The spawn disables Claude's `/bug` and `/feedback` model-drafted feedback flow for every Claude worker and secondmate, preventing a fleet-launched agent from queuing or submitting a bug report on the captain's behalf.
The controls are scoped to the launched process and never modify the captain's global Claude settings; `launch_template()` in `../../../../../bin/fm-spawn.sh` owns their exact mechanics and defense-in-depth rationale.

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
