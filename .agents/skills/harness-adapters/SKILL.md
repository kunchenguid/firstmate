---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Routes to one verified adapter file per harness for claude, codex, opencode, pi, pi-signed, grok, kimi, and muse.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

## Routing

This file is the router; the verified per-harness facts live in sibling files that are NOT loaded with it.
Read the adapter file for the ONE harness you are about to spawn, recover, steer, interrupt, exit, resume, or verify, and read only that one.
Open it with your file-reading tool at the path below, relative to this skill's base directory, which is printed to you when the skill loads.
Read a second adapter file only when you are genuinely comparing candidate harnesses, and then read exactly one per candidate.

| Harness | Adapter file |
|---|---|
| claude | `adapters/claude.md` |
| codex | `adapters/codex.md` |
| opencode | `adapters/opencode.md` |
| pi and pi-signed | `adapters/pi.md` |
| grok | `adapters/grok.md` |
| kimi | `adapters/kimi.md` |
| muse (crewmate and scout only) | `adapters/muse.md` |

Two more siblings carry cross-harness material, each read only at its own trigger:

- [`dispatch.md`](dispatch.md) - read at crewmate, scout, or secondmate intake to resolve which harness to launch and which concrete model and effort values to pass. It owns the crewmate and secondmate harness-resolution chain, the effort-precedence ladder and generic fallback, the supported launch-profile flags, and the per-harness model-discovery surfaces.
- [`primary-guards.md`](primary-guards.md) - read only when inspecting, changing, or debugging firstmate's own primary-session turn-end guard, PreToolUse seatbelts, delegation-shape guard, session-start enforcement, or watcher supervision. An ordinary spawn never needs it.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and any enabled crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The supervision knowledge lives in the adapter files: busy state, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.
Each adapter's `Busy state` row names only which semantic source that harness uses; `bin/fm-busy-lib.sh` owns the contract itself, including verdicts, source attribution, and the verification gates that keep an unverified harness at unknown.

The verified adapters are exactly the eight in the table above; muse is verified for crewmate and scout launches only.
Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain under `AGENTS.md` section 9 that the requested worker runtime is not verified yet, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime before future use.
Do not pause current work for that future-verification choice, and never launch an unverified adapter.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, its semantic busy source and trust gate in `bin/fm-busy-lib.sh`, any needed `FM_COMPOSER_IDLE_RE` empty-composer override plus any novel bare agent prompt glyph in `bin/fm-composer-lib.sh`'s shared composer classifier (the one fleet-wide owner of the empty/dead-shell/pending decision, so a new harness's own idle composer is not misread as a dead shell), the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge in a new `adapters/<harness>.md` added to the routing table above.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
Within the Pi family, only the exact launch-boundary marker `FM_PI_HARNESS=pi-signed` alongside `PI_CODING_AGENT=true` selects the signed identity; unmarked shared launcher ancestry remains `pi`.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness` (absent or `default` -> own).
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through the chain `config/secondmate-harness` -> `config/crew-harness` -> own, so an unset `config/secondmate-harness` matches the crew harness.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate/scout launch and `secondmate` mode for a `--secondmate` launch, re-resolving on every spawn so the split is durable across respawns; an explicit per-spawn harness arg overrides either.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi and pi-signed: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude). Verified end to end: grok discovers the user-level `no-mistakes` skill, `/no-mistakes` invokes it, and grok drives a real `no-mistakes axi run`. Like codex's `$`/`/` popups, typing `/<skill>` opens grok's slash-autocomplete, so a too-fast Enter selects the popup entry instead of sending, and for an argument-taking command (like `/no-mistakes`'s optional task-first argument) that first Enter only expands the popup selection into an argument-hint placeholder rather than submitting - a genuine second Enter is required (see [`adapters/grok.md`](adapters/grok.md) for the 2026-07-03 incident and fix). `fm_tmux_submit_core`'s retried Enter (used by `fm-send` on the tmux backend) handles this through the structural composer reader; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) because its prior delta-based verification false-positived on that same popup-close content change.
- kimi: `/<skill>`, for example `/no-mistakes`.

## Submission acknowledgement hazards

A send or key action reporting success is not proof that the intended action happened.
OpenCode can accept and queue an Enter while leaving text visible, Grok can consume Enter in its slash popup without submitting, and Kimi can silently drop a message sent before readiness even though the send returns success.
The shared symptom is a healthy-looking pane with no work in progress, so each adapter must verify the observable postcondition that is specific to its TUI.
