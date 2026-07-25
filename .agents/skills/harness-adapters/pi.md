# harness-adapters: pi

Load this reference only when a Pi runtime is being selected, spawned, recovered, interrupted, exited, resumed, or verified.
The core [harness-adapters](SKILL.md) reference owns universal selection, dispatch, backend, and verification invariants.
Worker operation facts below were verified 2026-06-11 unless a narrower fact gives its own evidence.

## Launch profile and model discovery

| Axis | Verified support |
|---|---|
| Model flag | `--model <model>` |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>` |
| Evidence | Verified 2026-07-13 on Pi 0.80.6. |

`pi --help` advertises `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`.
`pi --print --model openai-codex/gpt-5.6-sol --thinking max 'Reply with exactly OK.'` completed successfully during verification.
Run `pi --list-models [search]` to discover available models.
Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list.
If the current authenticated environment does not establish the requested model or provider relationship, fail loudly and report the unresolved candidate.

## Worker operation facts

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...`, with a braille spinner prefix and no `esc to interrupt` text |
| Exit command | `/quit` |
| Interrupt | single Escape |
| Skill invocation | Use natural language when exact command behavior is uncertain. |
| Env marker | `PI_CODING_AGENT=true`, set for children. |

Pi has no permission system, so crewmates are always autonomous.
Keep the brief as one positional argument.
Multiple positional args become separate queued messages; `fm-spawn`'s template already does this correctly.

Project trust dialog can appear on the first Pi run in any not-yet-trusted directory, observed even on clean worktrees.
Accept with Enter.
The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same worktree slot skip it.

`fm-spawn` keeps the turn-end extension in `state/`, outside the worktree, because project-local extension files make the trust gate strictly worse and pollute the project.
The extension must listen for Pi's `turn_end` event, not `agent_end`, so the watcher wakes after each completed turn instead of only when the whole agent run exits.

## Primary integration facts

`pi` exposes passive lifecycle callbacks for the primary turn-end guard, so its tracked primary adapter forces one bounded follow-up when the shared predicate blocks.
`pi` blocks watcher-arm anti-patterns by returning `{block: true}` from `tool_call`.
Pi uses the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions Pi auto-discovers once trusted.
The model arms through `fm_watch_arm_pi`, never a foreground bash arm.
The watcher tool result and clean-exit fallback are owned by [`docs/supervision-protocols/pi.md`](../../../docs/supervision-protocols/pi.md).

`bin/fm-sessionstart-nudge.sh` is verified through native `session_start`.
The existing primary extension handles `startup`, `new`, and `resume` and uses `pi.sendMessage` to inject context without racing a positional launch prompt.

**Primary-session guard fact, verified 2026-07-09 on Pi 0.80.5.**
The firstmate primary's own `.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `bin/fm-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
Pi's primary watcher protocol also requires the tracked `.pi/extensions/fm-primary-pi-watch.ts` extension, same trust-once discovery as the turn-end guard.
`bin/fm-session-start.sh` reports when the live Pi session has not loaded both the turn-end guard and watcher extensions, and points at plain `pi` after project trust as the fix, with `-e` as a trust-free fallback.
When a secondmate is launched on Pi, `fm-spawn.sh --secondmate` launches Pi with both `-e .pi/extensions/fm-primary-turnend-guard.ts` and `-e .pi/extensions/fm-primary-pi-watch.ts`, both already present in the secondmate home's git worktree.
