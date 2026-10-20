# kilo (Kilo Code CLI)

Verified on 2026-10-10 with Kilo Code 7.8.8.

Kilo Code is an OpenCode fork: its CLI embeds OpenCode internals and its TUI reuses OpenCode's composer and footer shapes.
Where a fact below is inherited from OpenCode rather than independently re-verified on kilo, it says so.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Rendered-tail fallback only: the TUI pins `esc interrupt` to its footer row while a turn runs (verified live on 7.8.8; the idle footer shows no such token), owned by `fm_busy_kilo_tail_busy` in `../../../bin/fm-busy-lib.sh`. Kilo exposes no hook surface for a semantic busy record, so this is a best-effort `unknown`-unless-busy source, not a recorded state writer. |
| Exit command | `/exit` (verified live). |
| Interrupt | Escape, sent TWICE: the first press changes the footer to `esc again to interrupt` (verified live on 7.8.8), the same double-Escape as OpenCode. Known to be flaky while a long shell command runs; use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | None verified for a Firstmate pane. `--continue`/`-c` and `--session`/`-s` exist (inherited from OpenCode), but Firstmate's relaunch does not use them for kilo. |
| Model flag | `--model <provider/model>` (also `-m`). |
| Effort flag | None for the base TUI: only the separate `kilo run` subcommand exposes `--variant`. The shared effort axis is recorded in task metadata and omitted from the launch (record-and-omit), like agy, gemini, and cursor. |
| Trust dialog | None observed (launched in a plain directory). |
| Marker | None. Kilo publishes no identity marker on its CLI process tree and exports `OPENCODE=1` from its fork lineage, which is deliberately NOT registered as a marker. `FM_KILO_HARNESS=kilo` is Firstmate's launch marker and the anchored process name `kilo` is its ancestry evidence. |

kilo can auto-upgrade in the background; the version in this record is the one verified.

## Launch

The worker launch template in `../../../bin/fm-spawn.sh` is `kilo --auto --prompt "<operational-input brief>" [--model <m>]`.
`--prompt` starts the supervised interactive TUI with the brief already submitted, so no delivery gate is needed.
`--auto` auto-approves every non-denied permission, which an unattended crewmate needs.
The launch clears inherited foreign harness markers and sets `FM_KILO_HARNESS=kilo`.
`--worktree` is deliberately never passed, because kilo would create its own git worktree and break Firstmate's isolation.
The base TUI exposes no reasoning-effort flag, so no `--variant`/effort flag is emitted.

## Primary integration

`.kilo/plugin/fm-primary-turnend-guard.js`, `fm-primary-watch-arm.js`, `fm-primary-pretool-check.js`, `fm-primary-cd-check.js`, and `fm-primary-sessionstart-nudge.js` mirror the OpenCode plugin stack, loaded from the tracked `.kilo/plugin/` directory with the module shape `export default { id, server }`.
Interaction facts (module shape, `session.idle`/`session.created`/`session.status` events, `tool.execute.before` blocking by throwing, and the `client.session.promptAsync` injection call) are taken from the Kilo plugin documentation and its OpenCode lineage.
The opt-in live gate `FM_KILO_PRIMARY_LIVE_E2E=1 tests/fm-kilo-primary-live-e2e.test.sh` is the command that proves them against a real kilo; `docs/verification/kilo.md` owns the recorded result and the parity caveat until it passes.
The watch-arm coordinator key is `__firstmateKiloWatchArm`.
Where the plugins arm and where they stay silent is owned by `docs/supervision-protocols/kilo.md`.

Kilo is NOT a verified supervision-host engine: a kilo primary always runs the plain watcher arm and never spawns the supervision host, even when `config/supervision-host` exists.
Host support is a deferred follow-up.

## Readiness-gated start

The launch brief rides `--prompt`, so there is no separate typed delivery or trust dialog to handle.
Trust handling is complete when inspection proves the target started processing its brief.
