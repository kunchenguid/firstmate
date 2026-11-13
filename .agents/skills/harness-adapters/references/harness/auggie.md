# Auggie

Augment's `auggie` CLI, verified as a primary harness with auggie 1.2.0 on Linux.
Verified as a primary only: it has no crewmate, scout, or secondmate launch, and `../../../../../bin/fm-spawn.sh` refuses it as a worker by name, including a raw launch command whose simple command runs it directly or behind the `env`, `command`, `exec`, `nohup`, `sudo`, or `timeout` wrappers.
Compound launches are refused best-effort, and a shell `-c` string, heredoc stdin, or `eval` is not inspected; that script's `--help` owns the covered forms.
`../../../../../docs/verification/auggie.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `auggie` on `PATH`, a symlink into the published `@augmentcode/auggie` npm package (`auggie-v2.mjs`). |
| Process identity | A node bundle: `ps -o comm=` reads `node-MainThread` (a bare `MainThread` on Node 24), and only the script argument names auggie. |
| Marker | None; zero `AUGMENT_*` variables reach the commands its bash tool runs. |
| Worker | Unverified and refused; no launch template, busy source, interrupt, exit, or resume contract exists. |
| Session start | Uncovered tier: no session-open hook, so the agent runs `bin/fm-session-start.sh` itself per `../../../../../AGENTS.md` section 3. |
| Turn end | No enforced guard: auggie's Stop hook runs in the background, cannot block, and its output never reaches the model. |
| Supervision | The foreground checkpoint in `../../../../../docs/supervision-protocols/auggie.md`. |
| Bash tool timeout | Kills the whole process tree, including `&` children, so every checkpoint call passes an explicit timeout above the checkpoint bound. |

## Detection

`../../../../../bin/fm-auggie-lib.sh` owns auggie process identity: an exact `auggie` command name, or a node interpreter whose script argument resolves into the `@augmentcode/auggie` package; a script merely named `auggie` outside that package never matches.
`../../../../../bin/fm-harness.sh` reports that match at comm strength, so it outranks a retained foreign marker such as `CLAUDECODE` or `PI_CODING_AGENT`.
`../../../../../bin/fm-session-lock-lib.sh` delegates to the same owner, so an auggie session can hold a home's session lock; auggie is deliberately not in the session-lock name vocabulary, and a bare node process never matches.

## Primary integration

The tracked `.augment/settings.json` registers only a `PreToolUse` hook for the bash tool, forwarding the payload to `bin/fm-arm-pretool-check.sh` and `bin/fm-cd-pretool-check.sh`; `../../../../../docs/arm-pretool-check.md` owns that wiring.
No `SessionStart` or `Stop` hook is registered.
The supervision host is unsupported on an auggie home, so keep `config/supervision-host` absent there; `../../../../../docs/supervision-host.md` owns that limit.
Away and quiet mode run through the away daemon, launched with `bin/fm-afk-launch.sh start`, as on other foreground-checkpoint homes.
Its injection into an auggie pane is unverified: no auggie busy signature or composer shape is registered in `../../../../../bin/fm-composer-lib.sh`, so treat away-mode delivery as unproven.
