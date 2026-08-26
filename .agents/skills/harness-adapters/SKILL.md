---
name: harness-adapters
description: >-
  Pointer skill for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Names the executable owner for each question and points at the verified per-adapter facts for claude, claude-ox, codex, opencode, pi, pi-signed, grok, kimi, cursor, and muse.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This skill routes; it does not restate.
Ask the executable owner first, and read the verification record only for the facts no script can answer.

## Who owns what

- **Per-task launch mechanics** (launch command, autonomy flag, crewmate turn-end hook, model and effort flags, credential preflights): `bin/fm-spawn.sh`.
- **Agent lifecycle** (which key interrupts, how many times, whether the composer needs clearing, which command exits, which task kinds an adapter can run): `bin/fm-control-lib.sh`, delivered by `bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
  Never hand-type an interrupt key or exit command through `fm-send`: a routing-marked lifecycle command becomes chat the agent reasons about instead of executing ([`docs/agent-control.md`](../../../docs/agent-control.md)).
- **Busy state** (verdicts, source attribution, the gates that keep an unverified harness at `unknown`): `bin/fm-busy-lib.sh`.
- **Composer shapes** (every prompt glyph, border, placeholder, and the `empty`/`pending`/`pending-unproven`/`unknown` decision): `bin/fm-composer-lib.sh`, the ONE fleet-wide owner - no adapter may carry its own copy.
- **Detection** (own harness, `crew`, `secondmate`): `bin/fm-harness.sh`.
- **Turn-end and pre-arm hooks**: `docs/turnend-guard.md` and `docs/arm-pretool-check.md`; delegation-shape guard: `docs/subagent-guard.md`; session-open tiers: `docs/sessionstart-nudge.md`; watcher protocols: `docs/supervision-protocols/`.
- **Verified per-adapter facts** (exit command, interrupt, skill-invocation form, trust dialogs, quirks, launch-profile axes, model discovery surfaces, per-harness incidents): [`docs/verification/harness-adapters.md`](../../../docs/verification/harness-adapters.md), with active smoke evidence in [`docs/verification/runtime-backends.md`](../../../docs/verification/runtime-backends.md) and [`docs/verification/supervision.md`](../../../docs/verification/supervision.md).

## Which harness a worker gets

Crewmates default to firstmate's own harness unless `config/crew-harness` names an adapter; optional profiles in `config/crew-dispatch.json` override that for one dispatch by selecting concrete harness, model, and effort at intake.
A per-task captain instruction ("run this one on codex") overrides both for that dispatch only, and `default` means mirror firstmate's own harness.
When a matched rule or default resolves to a profile array, the candidate choice is the procedure recorded in `docs/scripts.md` "Resolving a crew-dispatch profile array".

Secondmates have their own knob: `config/secondmate-harness` resolves through `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own, and may pin model and effort on the same line (`secondmate-provisioning` owns that format and its inheritance).
`config/secondmate-harness` is the primary's own setting and is never inherited, because secondmates do not spawn secondmates; a secondmate's own crewmates use the primary's inherited literal `config/crew-harness` and `config/crew-dispatch.json`, so an unset or `default` crew harness leaves nothing concrete to inherit and those crewmates fall back to the secondmate's own detected harness.

## The one rule this skill enforces itself

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names one, tell the captain in plain outcomes that the requested worker runtime is not verified yet, use firstmate's own verified runtime for current work, and ask only whether to verify the requested one before future use - without pausing current work for that answer.
To verify a new harness: spawn a trivial supervised task through `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `bin/fm-spawn.sh`, the semantic busy source and trust gate in `bin/fm-busy-lib.sh`, any new composer shape or prompt glyph in `bin/fm-composer-lib.sh`, the tmux agent-process liveness classification in `bin/backends/tmux.sh` when it can launch a secondmate, and the dated evidence in `docs/verification/harness-adapters.md`.
A harness-dependent check is proven end to end against the real harness or it is not proven; `firstmate-coding-guidelines` owns that testing rule.
