# Pre-arm / PreToolUse seatbelt

This is the authoritative contract for the watcher-arm PreToolUse seatbelt referenced from `bin/fm-watch-arm.sh`'s header and `docs/supervision-protocols/`.
The shared predicate lives in `bin/fm-arm-pretool-check.sh`.
Harness-specific tracked hook files only adapt each verified harness's real PreToolUse mechanism to that shared predicate.

## Gap closed

A firstmate primary must arm the watcher (`bin/fm-watch-arm.sh`) or run a Codex checkpoint (`bin/fm-watch-checkpoint.sh`) as a standalone, verified harness call - the harness's own tracked background mechanism, never a plain shell `&`.
On 2026-07-09 a Grok primary instead armed with shapes like `bin/fm-watch-arm.sh &`, `bin/fm-watch-arm.sh 2>&1 | head -2 &`, and the arm glued after another command with `&`.
Each of those backgrounds the arm with a shell operator instead of the harness's own tracked background mechanism, so the forked child is reaped the instant the tool call ends - leaving no watcher running and supervision blind.
`bin/fm-watch-arm.sh`'s header already documents this failure mode structurally (verify-after-fork, never trust a bare `&`).
This seatbelt adds a pre-execution check so a harness that supports PreToolUse-style hooks can refuse the command before it ever runs, instead of only detecting the fallout afterward through `bin/fm-guard.sh` and `bin/fm-turnend-guard.sh`.

**This is a seatbelt for known-bad command shapes, not a post-arm liveness guarantee.**
It only inspects the text of a shell command about to run and denies a handful of specific anti-patterns.
It cannot prove the watcher actually started and stayed healthy afterward - that is still `bin/fm-guard.sh` and `bin/fm-turnend-guard.sh`'s job, which run after the fact from the beacon and lock.
A command this seatbelt allows can still fail to arm the watcher for unrelated reasons, and a harness with no PreToolUse-equivalent hook gets no protection from this layer at all.

## Shared predicate

`bin/fm-arm-pretool-check.sh` reads a shell command from either a PreToolUse-style JSON payload on stdin, or `--command '<cmd>' [--background true|false]` for adapters that already extracted the command and for tests.
It only inspects commands that mention watcher arming or checkpoint supervision: `fm-watch-arm.sh`, `fm-watch.sh` (bare), `fm-watch-checkpoint.sh`, or a `pkill` pattern against `fm-watch`.
Everything else is a fast, silent allow.

For a relevant command it denies when:

1. The command backgrounds the arm/checkpoint with a shell `&` (trailing, not `&&`), or applies `nohup`/`disown`.
2. The arm/checkpoint is piped into `head`, `tail`, `timeout`, or `sed -n`, which can tear down attach-and-wait before the watcher confirms it started.
3. The command redirects watcher arm/checkpoint stdio with shell redirection, which can hide the status and wake lines the primary relies on.
4. The command uses command or process substitution inside a watcher arm/checkpoint command.
5. The arm/checkpoint is bundled with other work in a multi-statement command (separated by `;`, `&&`, `||`, or a newline) that is not the blessed shape below.
6. The command is a broad `pkill` against `fm-watch` - forbidden regardless of shape, because it matches every firstmate home's watcher and can kill a sibling's supervision (`AGENTS.md` section 8).

The **blessed shape** - always allowed - is: no pipe, no background operator, no redirection, no command/process substitution, and a final statement that is exactly `[exec] bin/fm-watch-arm.sh [--restart]` or `bin/fm-watch-checkpoint.sh [args...]`, optionally preceded by leading statements that are each `cd <path>`, `export VAR=...`, `. config/x-mode.env` / `source config/x-mode.env`, or the guarded form `[ -f config/x-mode.env ] && . config/x-mode.env`.
Leading statements are separated from the final statement by `;` or a newline, matching the documented arm recipe (`AGENTS.md` section 8, `docs/supervision-protocols/grok.md`) - a leading statement joined to the final one with `&&` (e.g. `cd X && exec bin/fm-watch-arm.sh`) is bundling, not the blessed shape, and is denied like any other multi-statement command.

`.toolInput.background` / `.tool_input.background` is read for context only.
It names the harness's **own** tracked background mechanism (for example Grok's `run_terminal_command` `background: true` tool parameter), which is the correct way to background the arm - the seatbelt never treats it as a deny signal.
The only backgrounding this seatbelt objects to is a shell-level operator inside the command text, because that bypasses the harness's own tracking entirely.

Fail-open only when the input is unparseable: empty stdin, invalid JSON, or missing `jq` all allow (exit 0).
A hook must never crash-deny everything.

## Output contract

- **Allow**: exit 0. No stdout for an irrelevant command (fast pass-through); allow is silent on both streams for a relevant-but-blessed command too.
- **Deny**: exit 2, plus:
  - stdout: `{"decision":"deny","reason":"..."}` - Grok's PreToolUse contract.
  - stderr: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"..."}` - Claude Code's PreToolUse contract.
  - Codex reads plain exit 2 and shows stderr verbatim, so the JSON there is simply displayed as text - still a clean deny.
- **`--claude`**: suppresses the stdout JSON entirely, denying with the stderr JSON alone.
  Claude Code only honors a PreToolUse deny when stdout is completely empty (verified 2026-07-09 against Claude Code 2.1.204): any content on stdout - even Grok's own `{"decision":...}` JSON, even a single object carrying both schemas at once - makes Claude Code silently allow the tool instead of falling back to stderr.
  The Claude adapter passes `--claude`; every other caller (Grok, Codex, tests, CLI use) keeps the default dual output.

## Harness integrations and audit

All five verified primary harnesses were audited for a PreToolUse-equivalent hook and wired where one exists.

| Harness | Wired? | Mechanism |
| --- | --- | --- |
| Grok | Yes | `.grok/hooks/fm-primary-pretool-check.json`, `PreToolUse` event, `matcher: "Bash"` |
| Claude | Yes | `.claude/settings.json`, `PreToolUse` hook, `matcher: "Bash"`, invoked with `--claude` |
| Codex | Yes | `.codex/hooks.json`, `PreToolUse` hook, `matcher: "Bash"` |
| OpenCode | Yes | `.opencode/plugins/fm-primary-pretool-check.js`, `tool.execute.before`, throws to block |
| Pi | Yes | `.pi/extensions/fm-primary-turnend-guard.ts`, `tool_call` handler, returns `{block: true}` |

No harness was left with a residual gap: every verified adapter supports a genuine pre-execution block for its shell tool, and all five are wired to the shared checker.

- **Grok**: project hooks require folder trust (`/hooks-trust` or launch-time `--trust`), the same gate as the turn-end guard.
  Grok's own `${VAR}`/`$VAR` expansion runs over the raw `command` string before handing it to `bash -lc`, and it requires every `$name` reference to either be a real env var or carry an inline `:-default` - see "Grok `${VAR}` regression" below.
- **Claude**: `matcher: "Bash"` scopes the hook to shell tool calls only.
  Requires `--claude` (stdout suppressed on deny) per the output contract above.
- **Codex**: the normal Codex primary supervision path is the foreground `bin/fm-watch-checkpoint.sh`, never a background arm, so this hook is a pure residual-risk backstop for an agent that shells `fm-watch-arm.sh` wrong anyway.
  The hook command mirrors the existing Stop hook's root-anchoring: it reads the payload once, resolves the executable root from the hook process's own `pwd -P` (not the payload's `cwd`), and verifies that root is firstmate-shaped and hook-bearing before invoking the checker, so it stays inert outside a genuine firstmate checkout.
- **OpenCode**: the arm mechanism itself is entirely plugin-owned (`fm-primary-watch-arm.js` spawns `bin/fm-watch-arm.sh --restart` as a real child process, never a model tool call), so this hook is a residual-risk backstop for the agent shelling the arm wrong through its own bash tool, exactly like Codex.
  `tool.execute.before` receives `{tool: "bash", ...}` / `{args: {command}}` and can block by throwing - the thrown message becomes the failed tool result shown to the model.
- **Pi**: the arm mechanism is extension-owned (`/fm-watch-arm-pi` / `fm_watch_arm_pi` spawns `bin/fm-watch-arm.sh --restart`), so again this is a residual-risk backstop.
  The `tool_call` handler is added to the **existing** `fm-primary-turnend-guard.ts` extension file rather than a new one, so no additional `-e` flag is needed at Pi launch - the primary already loads this file for the turn-end guard, and `AGENTS.md`/`docs/supervision-protocols/pi.md`'s launch instructions (`-e <turnend-ext> -e <watch-ext>`) are unchanged.

## Grok `${VAR}` regression (discovered and fixed 2026-07-09)

While validating the new Grok PreToolUse hook, the first version used the same pattern as the existing (already-shipped) `fm-primary-turnend-guard.json` Stop hook: a `bash -lc` command that assigns a local variable, `root=${GROK_WORKSPACE_ROOT:-}`, then references it bare as `$root` later in the string.
Against grok 0.2.93 (the turn-end guard was last validated against 0.2.91), this fails with `hook not executed: required env var(s) not set: ${root}` and the hook silently no-ops - the tool call proceeds unblocked, and the Stop hook never runs at all.

Root cause: Grok's own `${VAR}`/`$VAR` expansion scans the entire `command` string for every `$name` reference - including ones that are only ever meant to be bash-runtime variables assigned earlier in the same script - and requires each occurrence to be either a real env var or carry an inline `:-default`.
`root=${GROK_WORKSPACE_ROOT:-}` satisfies that for the assignment itself, but the later bare `$root` references do not, so the whole hook fails to launch.

Fix: never introduce a local variable at all - reference `${GROK_WORKSPACE_ROOT:-}` directly everywhere it's needed:

```
bash -lc '[ -n "${GROK_WORKSPACE_ROOT:-}" ] || exit 0; exec "${GROK_WORKSPACE_ROOT:-}/bin/fm-arm-pretool-check.sh"'
```

Both `.grok/hooks/fm-primary-pretool-check.json` (new) and `.grok/hooks/fm-primary-turnend-guard.json` (pre-existing, now fixed as part of this same audit since it shared the exact same broken pattern) use this form.
`tests/fm-arm-pretool-check.test.sh` asserts neither grok hook file contains a bare `$root` assignment, so this cannot silently regress again.

## Empirical validation

All harnesses were validated on 2026-07-09 in scratch repos, not against the captain's live primary fleet state.
Each test used a dummy `bin/fm-watch-arm.sh` that just echoes and exits, and drove the harness with a prompt asking it to run `bin/fm-watch-arm.sh &` verbatim (deny case) or an unrelated `echo` command (allow case).

**Grok** 0.2.93, `.grok/hooks/fm-primary-pretool-check.json` (fixed form above).
Command: `GROK_HOME=<scratch> grok --trust -p '...' --permission-mode bypassPermissions --output-format plain --leader-socket <scratch>/leader.sock`, with `RUST_LOG=debug GROK_LOG_FILE=<scratch>/debug.log` for the deny case.
Observed: `xai_grok_hooks::dispatcher: hook denied ... reason=backgrounds the watcher arm/checkpoint with a shell '&' ...` followed by `tool call denied by pre_tool_use hook tool_name=run_terminal_command`.
The allow case (an unrelated `echo`) ran normally with `hook: PreToolUse Completed` logged and no denial.
The same fixed pattern was re-verified directly against the tracked `.grok/hooks/fm-primary-pretool-check.json` file (not just an equivalent scratch copy) before considering the audit complete.

**Claude Code** 2.1.204, `.claude/settings.json` `PreToolUse` hook with `--claude`.
Command: `claude -p '...' --dangerously-skip-permissions --output-format json`.
First attempt (default dual stdout+stderr output, no `--claude`) was **not** blocked - Claude Code ran the command anyway, which is what drove the discovery of the stdout-must-be-empty requirement documented above.
After adding `--claude`, the deny case was blocked and the model self-corrected: it retried using its own `run_in_background: true` tool parameter (the harness-native mechanism `docs/supervision-protocols/claude.md` documents) instead of a shell `&`, and that retry succeeded.
The allow case ran normally.

**Codex** `codex-cli 0.143.0`, `.codex/hooks.json` `PreToolUse` hook (default, non-`--claude`, output).
Command: `codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message <path> '...'`.
Observed for deny: `hook: PreToolUse` then `ERROR codex_core::tools::router: error=Command blocked by PreToolUse hook: {...stderr JSON...}. Command: bin/fm-watch-arm.sh &` then `hook: PreToolUse Blocked`.
Observed for allow: `hook: PreToolUse Completed`, command ran normally.
A `matcher: "Bash"` scoping and a bare `PreToolUse` payload (`.tool_input.command`, `.tool_name`) were both confirmed against the real payload captured on stdin.

**OpenCode** 1.17.15, `.opencode/plugins/fm-primary-pretool-check.js`.
Command: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO '...'`.
Observed for deny: `bin/fm-watch-arm.sh & failed` / `Error: {...deny JSON...}` in the scrollback, and the model's own summary confirmed the command never ran ("The command was denied by the tool hook...").
Observed for allow: the command executed and its output appeared normally.
Payload shape confirmed empirically: `tool.execute.before` receives `input: {tool: "bash", sessionID, callID}` and `output: {args: {command}}` (lowercase `"bash"`, not `"Bash"`).

**Pi** 0.80.2, `tool_call` handler added to `.pi/extensions/fm-primary-turnend-guard.ts`.
Command: `pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session '...'`.
Observed for deny: the model reported the harness denied the exact command and did not retry a modified one.
Observed for allow: the command ran and its output was returned normally.
Payload shape confirmed from the `@earendil-works/pi-coding-agent` type definitions and matched empirically: `BashToolCallEvent` carries `input: {command: string}`, and a `ToolCallEventResult` of `{block: true, reason}` blocks execution.

## Tests

`tests/fm-arm-pretool-check.test.sh` covers the shared checker's CLI mode (all required DENY/ALLOW acceptance cases plus additional coverage for `nohup`/`disown`, `tail`, redirection, command/process substitution, `&&`-bundling, non-`-f` `pkill`, and the blessed `--restart`/`cd`/`export` leading-statement forms), stdin JSON mode for both the Grok (`toolInput.command`) and Claude/Codex (`tool_input.command`) schemas, fail-open behavior (empty stdin, unparseable JSON, missing `jq`), the `--claude` output-shaping contract, and tracked hook-file wiring for all five harnesses including a regression test for the grok `${VAR}` bug.
These tests do not invoke live harnesses; live harness validation is the empirical evidence recorded above.
