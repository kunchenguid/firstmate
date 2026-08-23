# T3 primary supervision

Make a Firstmate **captain** session that lives inside **T3 Code** (Cursor as the T3 provider) receive proactive follow-up turns when the fleet has work, without depending on Cursor Desktop `.cursor/hooks.json` `stop` hooks.

This is **not** a spawn backend for workers.
A future worker `--backend t3` design is separate and must not be conflated with this primary-host path.

## Problem

Cursor Desktop primary supervision parks on `bin/fm-turnend-guard-cursor.sh` through `.cursor/hooks.json`.
Inside T3 Code, that stop hook does not provide a reliable follow-up channel (`CURSOR_PROJECT_DIR` is typically unset).
An external process can still start a new agent turn with `t3cli send --thread <id> …` while the thread is `ready`.

## Opt-in and binding

- Local gitignored `config/t3-primary` enables the host path for this home.
  An optional first non-comment line may be a thread uuid or `thread_id=<uuid>`.
- Session start runs `bin/fm-t3-primary-bind.sh`, which resolves the captain thread by matching the Cursor conversation / `--resume` id to a unique `assistantMessageId` from `t3cli list`, or uses the explicit thread id.
- Durable record: `state/.t3-primary-binding` (`thread_id`, `cursor_session_id`, optional `project_id`, `bound_at`, `bound_by`, `seq`).
- Preflight requires `t3cli` on `PATH`, authenticated `t3cli auth status`, and a successful `t3cli show` for the bound thread.

## Park

`bin/fm-t3-primary-park.sh ensure` starts the home-local park loop when a binding is active.
The park:

1. Runs `bin/fm-watch-arm.sh` as a tracked child.
2. On an actionable close, starts a successor arm first (Option B; see [`watcher-continuity.md`](watcher-continuity.md)).
3. Waits until `t3cli show` reports `session.status=ready` (never blind-sends while `running`, because mid-turn send queues a second turn).
4. Injects one operational-input `watcher` (or bounded `turn-end-guard`) message via `t3cli send` without `--force`.
5. Stands down on AFK, binding loss, park baton supersession, or a captain turn that leaves the thread `running`.

Loop ceilings and repair nags use T3-specific state files (`.t3-primary-loop`, `.turnend-t3-blocks`), not `.cursor-park-owner`.

While the binding is active, Desktop `bin/fm-turnend-guard-cursor.sh` exits inert, and `fm_supervision_model` classifies the home as `persistent` rather than Cursor `autoarm`.

## Setup

1. T3 Code desktop (or local server) running.
2. `t3cli` on `PATH` (verified against v0.14.2).
3. `t3cli auth local` once per machine/user.
4. Create local `config/t3-primary` in the Firstmate home (optionally with a thread id).
5. Open the Firstmate primary inside that T3 Cursor thread and run session start so bind + ensure can run.

## Related

- Protocol: [`supervision-protocols/t3.md`](supervision-protocols/t3.md)
- Desktop Cursor park: [`turnend-guard.md`](turnend-guard.md), [`supervision-protocols/cursor.md`](supervision-protocols/cursor.md)
- Continuity ordering: [`watcher-continuity.md`](watcher-continuity.md)
