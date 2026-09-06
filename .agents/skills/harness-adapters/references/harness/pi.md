# Pi and Pi-signed

The combined contract is genuine: Pi and the signed wrapper expose the same verified CLI and TUI behavior.
Verified on 2026-07-27 with Pi and Pi-signed 0.82.0 unless a fact gives another version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned extension's `agent_start` marks busy and `agent_settled`, confirmed by `ctx.isIdle()`, marks idle; this covers retries, compaction, tool loops, and queued continuations. |
| Exit command | `/quit`. |
| Interrupt | Single Escape. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <model>`. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; both identities expose the same levels and completed the same model-qualified max-thinking smoke. |
| Model discovery | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |

Pi has no permission system, so workers are always autonomous.
Pi's installed `packages/coding-agent/docs/settings.md` UI and display section documents `regular` as the `tuiMode` default and `fullscreen` as experimental.
Fullscreen can bury steering messages by rewriting scrollback, so Firstmate avoids it when the installed CLI supports the override.
`../../../bin/fm-spawn.sh --help` owns the executable-pinning and version-safe launch mechanics.

Pi-signed is the signed wrapper identity verified on version 0.82.0.
Firstmate records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.
The observed signed process tree has an exact `pi-signed` wrapper parent with the Pi application as its child, while tmux reports the foreground command as the exact `pi-launcher` name for either selected executable.
The installed plain `pi` command also execs that signed launcher.
The router's Detection section owns how launch markers and ancestry select between the identities.

Keep the instructions as one positional argument.
Multiple positional arguments become separate queued messages; the spawn template already preserves the one-argument shape.

A project trust dialog can appear on the first Pi run in any not-yet-trusted directory, including a clean worktree.
Accept it with Enter and verify the instructions begin processing.
The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same pooled slot skip it.

## Worker turn-end extension

`../../../bin/fm-spawn.sh` keeps the worker turn-end extension in `state/`, outside the worktree, because project-local extension files worsen the trust gate and pollute the project.
The extension listens for Pi's `turn_end` event, not `agent_end`, so supervision is notified after each completed turn rather than only when the whole run exits.
Pi sets `PI_CODING_AGENT=true` for its children as its harness-detection marker.

## Primary integration

The primary turn-end behavior was verified on 2026-07-09 with Pi 0.80.5.
`.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `../../../bin/fm-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.

The primary watcher protocol also requires `.pi/extensions/fm-primary-pi-watch.ts`.
The Pi engine auto-discovers both tracked project-local extensions once the project is trusted.
The model arms through the `fm_watch_arm_pi` tool, never through a foreground shell arm.
The tool result and clean-exit fallback are owned by `../../../docs/supervision-protocols/pi.md`.
`../../../bin/fm-session-start.sh` reports when the live Pi-family session has not loaded both extensions and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.

When a secondmate is launched on Pi or Pi-signed, `../../../bin/fm-spawn.sh --secondmate` launches the selected executable with both `-e .pi/extensions/fm-primary-turnend-guard.ts` and `-e .pi/extensions/fm-primary-pi-watch.ts`.
Both files already exist in the secondmate home's git worktree.
The PreToolUse-equivalent watcher-arm seatbelt returns `{block: true}` from the `tool_call` event.
