# Crew-scoped deny set (defense-in-depth hardening)

This records what `bin/fm-spawn.sh` injects into every autonomous **claude crew** launch, why it lives there, exactly what it does and does not protect, and the empirical proof that it works.
It is the verification record for the change; the deny set's versioned source of truth is the heredoc in `crew_deny_settings_file()` in `bin/fm-spawn.sh`, not this doc.

Context and threat model: `data/sec-automode-scout-q3/report.md` (quick win 1 plus the npmrc-hygiene portion of quick win 3) and the captain decision `data/sec-automode-scout-q3/decision-sec-deny-rules.md`.

## What it is

Every claude crew (a ship or scout task) launches with a `--settings <file>` flag pointing at a `permissions.deny` JSON that `fm-spawn` generates per task.
Claude enforces `permissions.deny` in **every** permission mode, including `bypassPermissions` (which is what `--dangerously-skip-permissions` selects), while `allow` rules become moot under bypass.
That asymmetry is the whole reason this works: the crew stays fully autonomous, but the deny set still constrains it.

The deny set blocks:

- Network egress by the two ubiquitous CLI clients: `Bash(curl:*)`, `Bash(wget:*)`.
- Token exfiltration in one command: `Bash(gh auth token:*)`.
- Remote history rewrites: `Bash(git push --force:*)`, `Bash(git push -f:*)`, `Bash(git push --force-with-lease:*)` - a plain `git push` to a task branch is deliberately NOT denied.
- Catastrophic-delete circuit breakers: `Bash(rm -rf /:*)`, `Bash(rm -rf ~:*)`, `Bash(rm -rf $HOME:*)`.
- Secret-path reads through the **Read tool**: `Read(~/.ssh/**)`, `Read(~/.aws/**)`, `Read(~/.kube/**)`, `Read(~/.npmrc)`, `Read(~/.claude/.credentials.json)`, `Read(~/.docker/config.json)`.

## Why it lives in fm-spawn (and nowhere else)

Crews run in worktrees of the **project** repo, so the firstmate repo's own `.claude/settings.json` never reaches them.
Editing the captain's global `~/.claude/settings.json` is off-limits - that would constrain the captain's own sessions, not just crews.
The one crew-scoped, per-launch injection point is the claude launch template in `fm-spawn.sh`, the same place `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` is already injected as a crew-only control.

The generated file lives in the task's own temp root (`/tmp/fm-<id>/crew-deny.settings.json`), outside every worktree, never committed to a project, and `fm-teardown` removes it with that root.
`--settings` **merges** on top of the worktree's turn-end `settings.local.json` rather than replacing it, so the crew's Stop hook (the watcher's turn-end signal) is unaffected (verified below).

Only the claude **crew** template carries the `__CREWSETTINGS__` placeholder.
A secondmate is a firstmate instance, not an autonomous crew, so it launches without the deny set; every other harness and the raw-launch escape hatch omit it too, and none of them generate the file.

## Mechanism choice: `--settings` file over `--disallowedTools`

`--disallowedTools` and a `--settings` `permissions.deny` block are functionally equivalent and both enforced under bypass.
The deny set has 15 entries; inlining them as `--disallowedTools` flags would bloat the single-line launch command into something unreadable in pane captures and logs.
A `--settings` file keeps the launch line to one readable flag whose target path names the control, and keeps the versioned deny-set definition in one heredoc in the tracked script.

## This is a speed bump, not a hard boundary

Native Bash-argument matching is fragile and this is explicitly defense-in-depth staging, not containment:

- A crew can still read a secret with `cat`, `node -e`, `head`, etc. (only the **Read tool** is denied for those paths, not arbitrary Bash reads), and can still exfiltrate over HTTP with `python3 -c` or `node -e` instead of `curl`/`wget`.
- Prefix patterns miss trailing-flag and path-expansion forms: `git push origin main --force` (force flag last) and an already-expanded absolute home path slip the `--force:*` / `~` / `$HOME` patterns.
- Flag-order variants such as `rm -fr /` are not the same string as `rm -rf /`.

The hard boundary - an OS sandbox (macOS Seatbelt) and a deny-first PreToolUse hook that inspects the fully expanded command - is separate, captain-gated follow-up work (report sections 6.2 item 5 and 6.3; decision keys `sec-sandbox-crews`, `sec-custom-deny-hook`).

## Harness scope

Crews are always claude today (codex is banned by captain decision; `config/crew-dispatch.json`), so only the claude template is hardened.
The codex, opencode, pi, and grok templates are left unchanged; each would need its own mechanism if it were ever used for crews, because `permissions.deny` / `--settings` are claude-specific.

## Empirical verification

Date: 2026-07-17. Claude Code version: `2.1.212`. Backend: reproduced the exact launched command shape (`claude --dangerously-skip-permissions --settings <file> ...`) with the real per-task file `fm-spawn` generates.

Per the captain's hard verification limit, the destructive and exfiltration rules (rm, force-push, `gh auth token`, secret-path reads) were verified by **inspecting the generated deny config only** - never by executing the denied command, because a deny that silently failed to load would have let the command run. Only one harmless `curl https://example.com` GET was used as proof the deny mechanism fires at all, plus positive controls.

1. **Deny fires under bypass.** With `--dangerously-skip-permissions` and the deny `--settings` file, asking the agent to run `curl -sS https://example.com` returned:
   `BLOCKED: "Permission to use Bash with command curl ... has been denied."`
   The command never executed.

2. **Legitimate workflow still runs.** In the same launch shape, `git --version` -> `git version 2.54.0` and `yarn --version` -> `1.22.22` both **executed**.

3. **No turn-end regression.** With a worktree `.claude/settings.local.json` Stop hook (exactly what `fm-spawn` writes) plus the deny `--settings` file, the Stop hook still fired (its marker file was touched), confirming `--settings` merges rather than replaces and the watcher's turn-end signal is intact.

4. **Deny set complete and non-over-blocking (by inspection).** The generated file is valid JSON with all 15 required rules, and contains none of the patterns that would break a legitimate crew workflow (no bare `Bash(git push:*)`, no `kubectl`/`gh api`/`yarn`/`npm`/`helm`/`treehouse`/`tasks-axi` deny). `tests/fm-spawn-crew-deny.test.sh` pins both the required and the forbidden sets.

The `Read(~/.npmrc)` deny is Read-tool-only, so `yarn`/`npm install` in a crew worktree still read the feed credentials at the OS level; `kubectl get/list`, `gh api` POST, treehouse worktree ops, and `tasks-axi` are all unaffected.

## Maintaining this file

Keep this doc as the verification record and rationale for the crew deny set.
When the deny set in `bin/fm-spawn.sh` changes, update the rule list and re-run the verification above, refreshing the date, version, and captured output.
Do not restate the deny entries as a second source of truth - the heredoc in `crew_deny_settings_file()` owns them; this doc summarizes and justifies them.
