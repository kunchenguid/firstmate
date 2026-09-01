# agy (Antigravity CLI 1.1.22, Gemini harness; verified lean 2026-08-28, guard unification 2026-09-02)

Verified worker/scout adapter. Interactive primary sessions are supported and are hands-on-keyboard: the captain drives them directly.
AGY has NO turn-end Stop hook by design — the Stop hook blocked chat output, so it was deliberately removed from `.agents/hooks.json`; do not re-add it.
Turn-end supervision for AGY primaries is owned by the external background watcher (`bin/fm-watch.sh`), started by the primary or the captain, not by an in-process hook.
Hard Rule 1 enforcement: the former `.agents/hooks.json` `"firstmate-hardrule1"` PreToolUse hook and its `bin/fm-selfdo-*` scripts were ARCHIVED by captain order 2026-09-02 (retired as a misfiring 2-day-old local patch; scripts preserved under `data/archived-scripts/2026-09-02-selfdo/`). Do not re-register; delegation discipline is behavioral, not mechanical.

| Fact | Value |
|---|---|
| Role | Worker/scout verified; interactive primary supported. |
| Launch | `agy --model <model> -i "<brief>"` prompt-interactive (`-i`/`--prompt-interactive`). |
| Launch flags | `--dangerously-skip-permissions` parallels claude/grok unattended; model/effort flags threaded from dispatch. |
| Brief path | Space-free `TASK_TMP/brief.md` copy (`/tmp/fm-<id>/brief.md`) so the HOME space (`⭐️ Jala-firstmate`) never appears in the quoted launch-brief path. |
| Models | `--model <model>` Gemini family (`gemini-3.7-flash-medium/high`, `gemini-3.6-flash-*`, `gemini-3.1-pro-*`) plus cross-provider ids from `agy models` (live 1.1.22 listed gemini, claude-sonnet-4-6, claude-opus-4-6-thinking, gpt-oss-120b-medium). |
| Effort | `--effort low|medium|high` (verified `agy --help` on 1.1.22); no verified `xhigh`/`max` flag. |
| Herdr detection | kind `agy`, source `herdr:antigravity_cli`, `agent_status` idle/working. |
| Busy state | herdr `agent_status` (idle/working) observed live; not yet wired into `bin/fm-busy-lib.sh`, so treat as classifier evidence only. |
| Composer | Unknown — no dedicated shape probe yet (`bin/fm-composer-lib.sh` has no agy entry). |
| Turn-end supervision | External background watcher (`bin/fm-watch.sh`), never an in-process Stop hook. |
| Stop hook | None by design — the Stop hook blocked chat and was deliberately removed; do not re-add. |
| Primary style | Hands-on-keyboard: an AGY primary is a visible session the captain drives, not an autonomous supervised pane. |
| Hard Rule 1 gate | `.agents/hooks.json` `"firstmate-hardrule1"` `PreToolUse` hook (matcher `write_to_file|replace_file_content|multi_replace_file_content|run_command`, timeout 10) invokes `bin/fm-selfdo-pretool-check.sh`. |
| Hard Rule 1 output | Always one JSON decision object on stdout: `{"decision":"deny","reason":"..."}` or `{"decision":"allow"}`; always exit 0; malformed transport fails open. |
| Hard Rule 1 surface | Write-tool targets (`TargetFile`/`Filepath`/`FilePath`/`file_path` anywhere in `toolCall.args`, nested per-operation objects included) and the `run_command` working directory (`Cwd`/`cwd`/`WorkingDirectory`, else `workspacePaths[0]`). |
| Hard Rule 1 command flavor | `decisionForCommand` (bin/fm-selfdo-policy.mjs) denies only write-flavored commands touching `projects/` (`rm`, `mv`, `cp`, `tee`, redirects `>`/`>>`, `sed -i`, unknown commands); read-only commands (`grep`, `cat`, `git -C ... status`) are allowed. |
| Hard Rule 1 escape | `FM_ALLOW_PROJECTS_WRITE=1` (captain-approved escape, mirrors `FM_ALLOW_SUBAGENT=1`). |
| Session start | `.agents/hooks.json` `"firstmate-sessionstart"` `PreInvocation` hook (timeout 30) invokes `bin/fm-sessionstart-agy-nudge.sh`: on `invocationNum == 0` injects the marked session-start nudge as `{"injectSteps":[{"ephemeralMessage":"..."}]}`, otherwise prints `{}`. |
| Exit | `/exit` returns cleanly to the shell prompt (verified; `agent_status unknown` after exit). |
| Interrupt | Unverified — probe Escape and Ctrl+C on a stuck worker before trusting either; do not assume. |
| Secondmate | Not claimed — `bin/fm-spawn.sh` refuses `--secondmate` on agy. |
| Environment marker | None — detection via process ancestry `comm` name `agy` (`bin/fm-harness.sh`); no `AGY_*`/`ANTIGRAVITY_*` marker observed. |
| Session lock | AGY is not in `FM_HARNESS_RE`/`FM_HARNESS_NAMES` (`bin/fm-session-lock-lib.sh`); AGY primaries do not acquire the home session lock. |
| Skills | Same open standard (`agentskills.io`): `<workspace>/.agents/skills/<name>/SKILL.md`, global `~/.gemini/config/skills/`, `.agent/skills` back-compat, `.agents/skills.json` manifest; `user-invocable`/`metadata.internal` frontmatter behavior unverified. |
| Rules | `GEMINI.md` > `AGENTS.md` > `.agents/rules/*.md`; rule files limited to 12,000 chars each, so firstmate's full AGENTS.md may be truncated. |
| Subagents | Native `invoke_subagent`/`define_subagent`/`send_message`/`manage_subagents`; `Workspace: branch` = isolated Git worktree. Boundary: native subagents for fast inline research only; ship work stays on external workers (`bin/fm-spawn.sh`). |
| Hooks schema | `{ "<name>": { "enabled": bool, "<Type>": [ { "matcher": regex, "hooks": [ { "type": "command", "command": "...", "timeout": 30 } ] } ] } }`; `PreToolUse`/`PostToolUse` grouped, `PreInvocation`/`PostInvocation`/`Stop` flat; `PreToolUse` output `decision: allow|deny|ask|force_ask`; commands run via `sh -c` with cwd = the hooks.json directory, and stdout must be ONE JSON object. |

## Verification evidence

- `bash tests/fm-agy-harness.test.sh` → passing, exit 0: launch-shape registration, AGY payload extraction (`toolCall.name`/`toolCall.args`, camelCase `Cwd`/`WorkingDirectory`), Hard Rule 1 deny/allow matrix through `bin/fm-selfdo-pretool-check.sh` (absolute, relative, nested multi-edit, `run_command` cwd, workspace fallback, `..` normalization, fail-open, `FM_ALLOW_PROJECTS_WRITE=1`), session-start nudge (`invocationNum==0` injection, later/malformed/worktree silence), and `.agents/hooks.json` registration shape.
- `bin/fm-lint.sh` clean on the touched guard scripts under the pinned ShellCheck definition.
- Hook input/output contracts for `PreToolUse` and `PreInvocation` verified from the installed Antigravity CLI customization docs (`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`), not assumed: `toolCall.name`/`toolCall.args` with `CommandLine` for run_command, `invocationNum`, and the stdout decision/inject contracts.
- Empirical minimum 2026-08-28 isolated Herdr lab: `herdr agent start --kind agy --pane w1:p1 -- --model gemini-3.7-flash-medium -i "hello"` → `interactive_ready true`, idle; `agent prompt` accepted input (`HELLO_OK`); `/exit` returned to the shell prompt, clean.

## Live-probe checklist still owed

- [ ] Confirm `fullyIdle` semantics on a live CLI session with background tasks.
- [ ] Probe Escape and Ctrl+C interrupt behavior on a stuck worker so `bin/fm-control.sh` interrupt can be trusted (do not assume either works).
- [ ] Add `agy` to `FM_HARNESS_RE`/`FM_HARNESS_NAMES` and verify `bin/fm-lock.sh`/session-start lock acquisition on an AGY primary.
- [ ] Probe skill frontmatter (`user-invocable`, `metadata.internal`) and AGENTS.md size handling on a live session.
- [ ] Wire herdr `agent_status` (idle/working) as the semantic busy source for `harness=agy` in `bin/fm-busy-lib.sh`.