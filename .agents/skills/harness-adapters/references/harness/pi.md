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
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; both identities expose the same levels and completed the same model-qualified max-thinking smoke. Pi 0.85.1 cannot reach `claude-opus-5` or `claude-fable-5` on the `anthropic` provider; see the note below the table. |
| Model discovery | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |

**Pi 0.85.1 effort-level fault (reproduced 2026-09-18, OAuth credential, `pi -ne`).**
`claude-opus-5` and `claude-fable-5` both return HTTP 400 `Invalid effort level` from the Anthropic API on every request.
The requested thinking level makes no difference, and omitting `--thinking` makes no difference.
The two models fail through different branches of `buildParams` in `packages/ai/src/api/anthropic-messages.ts`: `claude-opus-5` carries `supportsMidConvoEffort: true` in Pi's catalog, so `buildParams` hardcodes `output_config = { effort: "high" }` and sends it regardless of the requested level; `claude-fable-5` carries `forceAdaptiveThinking: true` instead, so it takes the neighbouring branch that forwards `output_config = { effort: options.effort }`, which the API also rejects.
The source read covers both the `main` branch and the `v0.85.1` tag.
`claude-sonnet-4-6` succeeds on the same credential, confirming the fault is model-specific.
Behaviour on an API-key credential is untested.
`claude-fable-5-1`, `claude-sonnet-5`, `claude-opus-4-5`, and `claude-sonnet-4-5` all return HTTP 404 on that account, so their behaviour under this fault is also untested.
Use `claude-sonnet-4-6` until Pi is patched.

Native Codex sessions may request `ultra` through the native extension flag described by `../../../bin/fm-spawn.sh`; it is separate from Pi's thinking levels.
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
