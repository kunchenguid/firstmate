# GitHub Copilot CLI

Verified for crew, scout, secondmate, and primary work on 2026-09-01 with GitHub Copilot CLI 1.0.83-0.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Resolve `copilot` from `PATH`; the native Windows process is `copilot.exe`. |
| Launch | `--allow-all --no-ask-user`, optional `--model <model>` and `--effort <low\|medium\|high\|xhigh\|max>`, then `--interactive <operational instructions>`. |
| Busy | Generated repository hooks use `userPromptSubmitted` to open and acknowledge prompt submission, while `agentStop` and `sessionEnd` close through `copilot-hook` and touch the turn-ended marker. |
| Exit | `/exit`. |
| Interrupt | Single `Ctrl+C`. |
| Skill | Use the discovered skill by name in natural language until the running version's slash-command form is verified. |
| Autonomy | `--allow-all` grants tool, path, and URL permissions, while `--no-ask-user` removes the worker's ask-user escape hatch. |
| Marker | `COPILOT_CLI=1`, `COPILOT_AGENT_SESSION_ID=<session-id>`, and `COPILOT_LOADER_PID=<native-process-pid>` on child tools. |
| Model | `--model <model>`; use `copilot --help` for the input contract and the authenticated interactive `/model` picker for current availability. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`; `none` and `minimal` remain below Firstmate's shared profile vocabulary. |

## Windows identity

Git for Windows process ancestry can terminate at `PPID=1` before reaching native `copilot.exe`.
`../../../bin/fm-session-lock-lib.sh` accepts the loader bridge only when all three Copilot markers are valid and `ps -W` proves that the recorded native PID is a live `copilot.exe`.
MSYS `kill -0` cannot establish liveness for that native PID, so the validated Windows process table is the fallback for lock ownership and competing-owner checks.
Copilot marker checks run before inherited Claude, Pi, Grok, and Cursor markers.
`../../../bin/fm-spawn.sh` clears foreign markers on Copilot launches and clears Copilot markers on non-Copilot launches.

## Hook transport and primary integration

Primary supervision is the tracked asynchronous watcher in `../../../docs/supervision-protocols/copilot.md`.
Tracked `.github/hooks/firstmate.json` registers session start, pre-tool protection, shell-completion notification, and the nonblocking `agentStop` backstop with Bash and PowerShell transports.
Unix hook entries invoke `../../../bin/fm-ghcp-hook.sh`.
Windows entries invoke `../../../bin/fm-ghcp-hook.ps1`, which resolves Git for Windows Bash through `../../../bin/fm-windows-git-bash.ps1` rather than selecting WSL.
The shared dispatcher is inert unless `COPILOT_CLI=1`, so repository hooks do not take over another consumer of `.github/hooks`.

Worker hook files are generated under `.github/hooks/zz-firstmate-<task-id>.json`, visible to Copilot's loader and excluded locally from git.
They are generated for secondmates and ordinary workers so prompt delivery can be confirmed from hook acknowledgement rather than a version-specific composer shape.

Firstmate starts `../../../bin/fm-watch-arm.sh` through Copilot's native asynchronous shell mode, or `../../../bin/fm-watch-arm.ps1` on native Windows.
The tracked notification hook translates an actionable watcher shell completion into typed Firstmate input.
`agentStop` returns `{"decision":"block","reason":"..."}` only for a missing-watcher repair continuation and never launches or waits for the watcher.
`stop_hook_active=false` resets the session-scoped continuation ledger because it proves a real captain prompt, while `true` continues the ledger.
Copilot overrides an eighth consecutive blocked stop, so Firstmate stops at seven and uses the last block for a ceiling warning.
