# supervisor-work PreToolUse seatbelt

This document is the authoritative human-readable contract for the guard that stops a firstmate SUPERVISOR session from doing a worker's job.
`bin/fm-supervisor-work-command-policy.mjs` is the single decision owner and the only place the patterns live.
`bin/fm-supervisor-work-pretool-check.sh` is the hook transport, supervisor scope, and output renderer; `bin/fm-supervisor-work-decide.mjs` is the command-line entry it calls.
The hook passes the command text on untouched and classifies nothing itself.

It belongs to the family of primary-session guards that share the same cross-harness hook machinery: the watcher-arm seatbelt (`docs/arm-pretool-check.md`), the cd-guard (`docs/cd-guard.md`), the subagent guard (`docs/subagent-guard.md`), and the turn-end supervision guard (`docs/turnend-guard.md`).

## Purpose and boundary

The written rules already forbade a supervisor from driving a crew-owned run and from waiting inside a turn; nothing enforced them.
On 2026-10-05 a secondmate lead session ran `no-mistakes axi respond --action fix` for its worker's run, then a `sleep 110; no-mistakes axi run --wait` poll loop with a 1700-second timeout, all inside one turn, while 17 watcher wakes queued unread.
On the same date a secondmate lead typed into a worker pane with `herdr pane send-text ... ; sleep 25; herdr pane send-keys Enter` instead of `bin/fm-send.sh`, so the worker never acknowledged the steer and the watcher could not see it.
The seatbelt refuses those command shapes before they run.

Three rules, each with one reason string:

| Code | Refused in a supervisor session | Rule |
| --- | --- | --- |
| `supervisor-no-mistakes-run` | `no-mistakes axi run` and `no-mistakes axi respond`, with any flags, wrappers, or backgrounding | The worker that started the run owns it, reports it, and answers its own findings. `no-mistakes axi status` is read-only supervision and stays allowed. Steer the worker with `bin/fm-send.sh`. |
| `supervisor-poll-in-turn` | `sleep` longer than 60 seconds, an unreadable `sleep` duration, or a `for`/`while`/`until` loop whose body sleeps | The watcher wakes the session when something changes; a sleep inside a turn hides queued wakes instead of acting on them. End the turn instead. |
| `supervisor-pane-typing` | `herdr pane send-text`, `herdr pane send-keys`, `tmux send-keys` | Steer a worker with `bin/fm-send.sh` and drive its lifecycle with `bin/fm-control.sh`. The primary home is exempt; only a secondmate lead owns workers whose panes this would type into. |

This is not a general sandbox.
It looks only at shell command positions; the submitted command is never evaluated, expanded, sourced or run.
Its threat model is agent drift, the same as the cd-guard: ordinary well-formed shell, not a deliberately obfuscated bypass.

## Scope: supervisor sessions only

A ship or scout worker OWNS its own no-mistakes run, may wait while that run works, and may drive its own terminal.
Refusing those in a worker would break the worker, so the guard fires only in a genuine supervisor home: a plain firstmate checkout or a home carrying a valid `.fm-secondmate-home` marker, exactly as `bin/fm-primary-scope-lib.sh` defines it for the session-start nudge, the turn-end guard, and the subagent seatbelt.
A linked task worktree - the shape `bin/fm-spawn.sh` always hands a crewmate - is a silent no-op (exit 0, no output), so the tracked hook registration is safe in the worktrees that inherit it.
Any failure to confirm the home is inert, never a block, so a broken environment never denies a command.

## Shipped mechanism

`bin/fm-supervisor-work-pretool-check.sh` reads the harness payload, extracts the exact command, skips node when no quote-stripped word names no-mistakes, sleep, herdr or tmux, and otherwise passes the command to the decider; it owns no pattern.

`install.sh` copies the hook, the decider and the policy into `${XDG_DATA_HOME:-$HOME/.local/share}/fm-supervisor-guard` and records the Firstmate home in its `home` file. The scope predicate and the shell lexer are read from that home's checkout (`bin/fm-primary-scope-lib.sh` and `bin/fm-arm-command-policy.mjs`), so the add-on copies no shell lexing and no upstream code.

The policy never evaluates the command; shell syntax the lexer cannot tokenize is an allow.
Because `for i in ...; do sleep 5; done` lexes as one node whose command word is `do`, the loop rule is a property of the whole command rather than of any single command position.

## Harness registrations

- Claude: `install.sh` merges one PreToolUse `Bash` hook into `~/.claude/settings.json`. `uninstall.sh` removes it.

The add-on registers only this Claude hook, which reads the Claude payload from stdin.

## Exit/output contract

The same contract as the other Firstmate PreToolUse seatbelts:

- ALLOW - exit 0 and no output.
- DENY - exit 2 and a Claude-shaped deny object on stderr; stdout stays empty.
- INERT - not a genuine supervisor home: exit 0 and no output.
- FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or a missing Node runtime or policy owner.

Claude requires stdout to remain empty on deny.
Codex blocks on exit 2 and displays stderr.

## Validation

`tests/fm-supervisor-work-guard.test.sh` installs into a throwaway HOME and drives the installed hook against real fixture homes: a primary checkout, a marked secondmate home, and a linked crewmate worktree, using the incident command shapes above.
It asserts the exit code, empty stdout, and the deny code on stderr for each refusal, the allowed reads, the sleep and loop thresholds, wrapped and backgrounded runs, the secondmate-only pane rule, that a worker worktree and an outside session are never refused, that a malformed payload fails open, and that uninstall leaves unrelated settings untouched.