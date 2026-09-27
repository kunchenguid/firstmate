# GitHub Copilot CLI

Verified 2026-09-24 on Copilot CLI 1.0.88 on macOS arm64 through the tmux backend.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no copilot wake protocol.
`../../../../../docs/verification/copilot.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `copilot` from `PATH`, refused if absent; a node loader shim (`bin/copilot` -> `@github/copilot/npm-loader.js`) that execs a native child (`@github/copilot-darwin-arm64/copilot`), so the live pane holds comm `node` plus a native process whose basename is `copilot`. |
| Launch | `copilot -i "<brief>" --model <id> --reasoning-effort <level> --yolo`, with the resolved absolute binary and `COPILOT_ALLOW_ALL=true` in the environment; the brief auto-submits with no extra Enter. The spawn requires a busy turn through the session-events fold before reporting success, answering the folder-trust dialog if it renders anyway. |
| Busy state | Durable session event log folded by `../../../../../bin/fm-busy-lib.sh`; no hook or plugin writer, arming, or seeded busy record. |
| Rendered tail | Not a state source: the running turn's status row carries `esc interrupt` beside the spinner (`Working` while modeling, `Waiting for background shells` while a backgrounded tool runs), absent when idle. The `Working` word beside it is ordinary prose a worker could echo and is never a signal alone. |
| Turn end | No turn-end hook is installed; completion arrives through the worker status protocol and the session-events fold. |
| Exit | `/exit`, submitted; the process exits and the pane returns to its shell. |
| Interrupt | Single `Ctrl+C`, which records `abort user_initiated`, reaps the running tool, and leaves an idle composer with no repollution, so no clear key follows. Escape is advertised by the footer but showed no verifiable effect on a running model or tool turn across three live trials. |
| Skill | `/<skill>`, for example `/skills`; submission shares the composer settle race below, so steering confirms delivery through the submit core's Enter-retry rather than a single send. |
| Autonomy | `--yolo` (equivalent to `--allow-all-tools --allow-all-paths --allow-all-urls`) auto-approves every tool, path, and URL grant for the run. |
| Marker | `COPILOT_CLI=1` on child and tool processes, beside `COPILOT_AGENT_SESSION_ID` and `COPILOT_CLI_BINARY_VERSION`. `AGENT=1` is NOT a copilot identity - see Detection below. |
| Resume | `--resume <session-id>` and `--continue` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>` or `--model auto`; the footer renders `Auto -> <model>` while auto routing is on. There is no `copilot models` subcommand; a requested id is passed through unvalidated. |
| Effort | `--reasoning-effort`, accepts `none\|minimal\|low\|medium\|high\|xhigh\|max`; shared values expose low through max, and `none` or `minimal` remain unreachable. |
| Composer | Bare `❯` row, a genuine empty agent composer; steering types text once and retries Enter until it clears. |

## Trust, and where the decision persists

Every task worktree is a path copilot has never seen, so an unhandled launch stops on `Confirm folder trust` / `Do you trust the files in this folder?` with the safe choice `1. Yes` preselected, and an unanswered dialog leaves the brief unprocessed.
`--yolo` does not suppress the dialog (A/B verified: identical launch with `--yolo` and no trust control still parked on it).
`COPILOT_ALLOW_ALL=true` (exactly `true`) trusts the working directory for the run without prompting - verified live, the dialog never rendered and the `-i` turn ran - so `../../../../../bin/fm-spawn.sh` carries it as an env prefix on every copilot launch, the gemini shape: per-session, with no growing global record of disposable worktree paths.
Trusting the workspace loads that directory's skills, plugins, MCP servers, and hooks, which is the same posture the other adapters already run under in a task worktree.
The post-launch readiness gate is the backstop: it answers a dialog that renders anyway with a single Enter, then requires the session-events fold to read busy before the spawn reports success.
A pane whose brief cannot be confirmed to run in the worktree fails the spawn, records the failure in the task status, and closes the endpoint.
Never steer into a pane still showing the dialog; a spawn that reported success has already cleared it.

## Composer settle race

Typed text followed by an immediate Enter does not submit: the text sits in the composer until a later Enter arrives (reproduced deterministically live).
A 4s settle between typing and Enter submitted on the first press, and a lone Enter into an empty composer is a harmless no-op, so the submit core's type-once-then-retry-Enter shape covers it with no copilot-specific tuning.
The `-i` launch brief is unaffected: it auto-submits inside the CLI, never through the composer.

## Credential precondition

A verified copilot worker ran under a signed-in GitHub account (`copilot login`) with no key export and no dialog.
The unauthenticated failure mode was not observed, so treat any auth prompt, login picker, or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

`COPILOT_CLI=1` is load-bearing rather than a fast path, so `../../../../../bin/fm-harness.sh` checks it BEFORE `CLAUDECODE`.
Copilot does not scrub an inherited `CLAUDECODE` - a non-interactive probe with `CLAUDECODE=1` exported printed the value back through the model's shell tool - so a copilot worker under a claude primary carries both markers and whichever is tested first wins; the spawn additionally clears the foreign markers at the launch boundary.

Ancestry cannot cover the gap alone.
The shipped CLI is a node loader (`bin/copilot` -> `@github/copilot/npm-loader.js`) and modern Node reports `comm` as `node` (measured on Node v24 on macOS; on Linux it reports `MainThread`), so neither the command-name arm nor the interpreter arm matches the loader shim.
`../../../../../bin/fm-copilot-lib.sh` owns the narrow structural rule that fixes it: identity comes from argv[1], the script argument, accepted only when it is named `copilot` or lives under `@github/copilot/`.
It is structural and runs no subprocess, for the same reason cursor's rule does not: probing a stranger's binary during a liveness poll is the hazard being avoided.
A bare interpreter, an unrelated node script, and a copilot name appearing later on a command line are all rejected, so a stranger's node pane is never reported as a live agent.
The native darwin-arm64 child IS named `copilot` and matches the anchored comm arm directly.

`AGENT=1` must never be promoted to a marker.
The same value is present in the launching environment, so it identifies the launcher, not the running harness.

Pane liveness has the same problem and needs its own answer, because the marker is not visible to a process scan.
`../../../../../bin/fm-copilot-lib.sh` is shared by `bin/fm-agent-process-lib.sh` (both backends) and `bin/backends/tmux.sh`'s foreground-group probe, the same split gemini uses.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` writes a firstmate-owned per-task binding file at `state/<id>.copilot-session` with the copilot home, the worktree, a binding incarnation, and every pre-existing matching session, then unique resolution pins the pane to its ONE new session directory under `$COPILOT_HOME/session-state/`.
It folds that session's `events.jsonl` while the bounded match stays unique: `user.message`, `model.turn_started`, and `assistant.turn_start` open a turn while `assistant.turn_end`, `abort`, and `session.shutdown` close it, and everything else (model calls, tool records, usage checkpoints, hook traffic) is skipped so a model-call gap cannot flicker idle.
Assistant boundaries can lag the visible turn by a minute or more (verified live: a rendered reply with `assistant.turn_end` still unflushed half a minute later, converging later through the flush or at `session.shutdown`), so a trailing open after a rendered reply stays busy until the flush lands; the lag runs only in the safe direction, never idle-while-working.
An open boundary is trusted busy and a settled log trusted idle; missing binding or match, unreadable log, or boundary-free log is unknown.
`../../../../../bin/fm-teardown.sh` removes the file, so nothing survives into a pooled worktree.

Copilot backgrounded a shell tool that ran past 30s foreground (`Waiting for background shells`) and the turn continued past it; a `Ctrl+C` abort reaped the tool and closed the turn.
The fold needs no hook, so a project's own `.github/hooks/` still run alongside firstmate's supervision untouched.
`../../../../../docs/verification/copilot.md` owns credentialed idle evidence and refresh.

## Skills

Copilot discovers project skills from `.github/skills/`, `.agents/skills/`, or `.claude/skills/` (trusted workspaces only) and personal skills from `~/.copilot/skills/` or `~/.agents/skills/`.
`~/.agents/skills/no-mistakes` is therefore discovered as a personal skill, which is what keeps firstmate's delivery path available; workspace skills need the workspace trust the launch already grants.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no copilot protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
