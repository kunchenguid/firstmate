# Pi and Pi-signed

The combined contract is genuine: Pi and the signed wrapper expose the same verified CLI and TUI behavior.
Verified on 2026-07-27 with Pi and Pi-signed 0.82.0 unless a fact gives another version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned extension's `agent_start` marks busy and `agent_settled`, confirmed by `ctx.isIdle()`, marks idle; this covers retries, compaction, tool loops, and queued continuations. |
| Exit command | `/quit`. |
| Resume | `--session <path-or-id>` resumes that exact session, and creates it at that path when the file is gone. `--session-id <id>` uses an exact project session id, creating it if missing - verified live on this host with Pi 0.87.1 on 2026-09-27: the id persists the session across process exits, and a later same-id, same-cwd process recalls prior turns verbatim. The 0.82.0 baseline named above does not advertise the flag, which is why the launch probes the resolved executable's help before passing it. When the resolved executable's help advertises the flag - version-probed exactly like `--tui-mode` - a FRESH `../../../bin/fm-spawn.sh` ship or scout spawn always passes `--session-id <task-id>.<spawn-gen>` and records that same value as `pi_session_id=` in `state/<id>.meta`. The spawn-gen component scopes the session to one incarnation, so a task torn down and re-spawned under the same id, even into the same copy path, CREATES a new session instead of recalling the abandoned attempt's turns. A RELAUNCH is the opposite and is where continuity lives: it passes the id the prior record names, and only when it names one, so the conversation continues; relaunching a record that predates the field, or one that recorded none, runs a fresh session while the republished record gains a new incarnation's `pi_session_id=` for its next relaunch. An older Pi, or a `--help` that exits non-zero (a signed-out wrapper), degrades the launch to a fresh session too: a fresh spawn then records no id, while a RELAUNCH keeps the id the previous incarnation recorded, so a later relaunch on a supporting Pi still resumes that conversation. On a relaunch a Herdr pane's already-bound status authority still wins when it reports a readable Pi session (`../../../bin/fm-control-lib.sh`'s `fm_control_relaunch_resume_flag`; `../../../docs/herdr-backend.md` "Agent status authority and relaunch"), the republished record names that reference so a later relaunch resumes the session this one ran, and the recorded value is the fallback when the runtime reports nothing - passed as `--session` when it is such a path and as `--session-id` when it is an id. There is still no `resume` control verb. |
| Interrupt | Single Escape. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <model>`; under a home's worker account pin the model must be `<provider>/<id>` and Firstmate also passes `--provider <provider>` (`../../../docs/configuration.md` "Worker account pin"). |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; both identities expose the same levels and completed the same model-qualified max-thinking smoke. |
| Model discovery | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |

Native Codex sessions may request `ultra` through the native extension flag described by `../../../bin/fm-spawn.sh`; it is separate from Pi's thinking levels.
Pi has no permission system, so workers are always autonomous.
Fullscreen can bury steering messages by rewriting scrollback, so Firstmate avoids it when the installed CLI supports the override.
`../../../bin/fm-spawn.sh --help` owns the executable-pinning and version-safe launch mechanics.

Pi-signed is the signed wrapper identity verified on version 0.82.0.
Firstmate records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.
The observed signed process tree has an exact `pi-signed` wrapper parent with the Pi application as its child, while tmux reports the foreground command as the exact `pi-launcher` name for either selected executable.
The installed plain `pi` command also execs that signed launcher.
The router's Detection section owns how launch markers and ancestry select between the identities.

Keep the instructions as one positional argument.
Multiple positional arguments become separate queued messages; the spawn template already preserves the one-argument shape.

A project trust dialog can appear on the first Pi run in any not-yet-trusted directory that holds a trust-requiring resource such as `.pi/extensions/`, including a clean worktree and a freshly seeded secondmate home.
Accept it with Enter and verify the instructions begin processing.
The decision persists per path in `~/.pi/agent/trust.json`, or in the pinned root's `trust.json` under a worker account pin, so later spawns in the same pooled slot under that root skip it.
For unattended seeded-secondmate launches, `../../../bin/fm-spawn.sh --help` owns the capability-gated project-trust approval mechanics; [runtime verification](../../../../../docs/verification/runtime-backends.md#pi-seeded-secondmate-project-trust) owns the regression evidence.

## Worker turn-end extension

`../../../bin/fm-spawn.sh` keeps the worker turn-end extension in `state/`, outside the worktree, because project-local extension files worsen the trust gate and pollute the project.
The extension listens for Pi's `turn_end` event, not `agent_end`, so supervision is notified after each completed turn rather than only when the whole run exits.
Native-harness progress uses the separate generation-bound marker owned by `../../../bin/fm-busy-event.sh`; it never fabricates Pi turn completion.
Pi sets `PI_CODING_AGENT=true` for its children as its harness-detection marker.

## Primary integration

The primary turn-end behavior was verified on 2026-07-09 with Pi 0.80.5.
`.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `../../../bin/fm-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
On native Windows, the extension runs its session-start, both PreToolUse, turn-end, and operational-input Bash helpers through `bash`; macOS and Linux invoke those helpers directly.

The primary watcher protocol also requires `.pi/extensions/fm-primary-pi-watch.ts`.
The Pi engine auto-discovers both tracked project-local extensions once the project is trusted.
The model arms through the `fm_watch_arm_pi` tool, never through a foreground shell arm.
Native-harness adapters can discover the same guarded FirstMate tools and operational message allowlist through the public Pi event-bus contract in `.pi/extensions/lib/fm-native-contract.ts`; no Pi built-in tools cross that contract.
The tool result and clean-exit fallback are owned by `../../../docs/supervision-protocols/pi.md`.
`../../../bin/fm-session-start.sh` reports when the live Pi-family session has not loaded both extensions and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.

When a secondmate is launched on Pi or Pi-signed, `../../../bin/fm-spawn.sh --secondmate` launches the selected executable with both `-e .pi/extensions/fm-primary-turnend-guard.ts` and `-e .pi/extensions/fm-primary-pi-watch.ts`.
Both files already exist in the secondmate home's git worktree.
The PreToolUse-equivalent watcher-arm seatbelt returns `{block: true}` from the `tool_call` event.
