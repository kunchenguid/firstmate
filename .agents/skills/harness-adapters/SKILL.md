---
name: harness-adapters
description: >-
  Agent-only reference for verified firstmate harness operations.
  Load before spawning or recovering a crewmate or secondmate, handling a trust or permission dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new adapter.
  Covers concise operational facts for claude, codex, opencode, pi, and grok while scripts and harness docs own mechanics and evidence.
user-invocable: false
metadata:
  internal: true
---

# Harness adapters

Use only the verified adapters `claude`, `codex`, `opencode`, `pi`, and `grok`.
Never guess an adapter or dispatch on an unverified one.
If configuration names an unverified adapter, tell the captain and use firstmate's own verified adapter until the new one is empirically verified.

## Owners and selection

`bin/fm-harness.sh` owns detection and static fallback.
`docs/configuration.md` owns dispatch-profile schema, account routing, and profile precedence.
`bin/fm-dispatch-select.sh` owns quota-balanced profile selection.
`bin/fm-spawn.sh` owns launch commands, autonomy flags, model and effort translation, per-task hooks, and recorded metadata.
`docs/supervision-protocols/` owns primary wait recipes.
`docs/turnend-guard.md` and `docs/arm-pretool-check.md` own primary hook behavior and verification.
`docs/permission-stall-detection.md` owns permission evidence.
The relevant backend doc owns transport-specific evidence and incidents.

Crewmates use the explicit task override, then the selected dispatch profile, then `config/crew-harness`, then firstmate's adapter.
Secondmate launches use `config/secondmate-harness`, then `config/crew-harness`, then firstmate's adapter.
`secondmate-provisioning` owns config inheritance; do not duplicate its list here.
Use the task's recorded `harness=` value for recovery, interrupt, exit, resume, and skill invocation.
On `unknown`, ask rather than guessing.

## Live ownership during adapter operations

A spawn is not complete until the endpoint is running and processing its brief.
A successful text-send command is not proof that the agent received or acted on the message; verify the resulting state or pane change.
After interrupt, exit, or resume, keep ownership until the same task has either resumed useful work or produced an evidence-backed terminal result.
Do not convert a trust popup, permission prompt, dead endpoint, or send failure into passive waiting; follow the matching recovery owner immediately.

## Trust and permission boundary

A recognized startup trust dialog may be accepted only during the post-spawn check before the brief begins.
Once work has begun, any trust, command, network, directory, tool, or system permission request is a security-sensitive mid-run decision.
Do not approve, deny, interrupt, exit, or relaunch around a mid-run permission request.
Load `stuck-crewmate-recovery`, preserve the evidence, and route the decision to the captain.

- Claude startup may require workspace trust, bypass confirmation, or `Hooks need review`; use the displayed safe startup choice and verify the brief begins.
- Codex startup may require directory trust; accept only before work begins and verify processing.
- Pi launches carry `--approve`; a remaining trust dialog is a launch-path defect, and machine-wide trust settings must not be changed.
- OpenCode and Grok need no normal post-spawn trust keystroke in a correctly launched project worktree.

## Primary supervision

Always use the exact primary block emitted by `bin/fm-session-start.sh`.
Never substitute another adapter's wait shape.

| Adapter | Primary supervision shape |
| --- | --- |
| Claude | A tracked background-notify cycle around `bin/fm-watch-arm.sh`. |
| Codex | A bounded foreground `bin/fm-watch-checkpoint.sh` cycle. |
| OpenCode | The tracked primary watch plugin and its async TUI follow-up. |
| Pi | The tracked primary extensions and the `fm_watch_arm_pi` tool, never a foreground Bash arm. |
| Grok | A tracked background-notify cycle around `bin/fm-watch-arm.sh`. |

The emitted block, not this summary, owns exact commands and repair behavior.
Changing any primary adapter requires live scratch verification and updates to its owning docs and tests.

## Launch profile axes

Firstmate chooses concrete profile values; shell scripts never interpret natural-language rules.

| Adapter | Model | Effort accepted by the interactive launch |
| --- | --- | --- |
| Claude | `--model <model>` | `low`, `medium`, `high`, `xhigh`, `max` |
| Codex | `--model <model>` | `low`, `medium`, `high`, `xhigh` through its config axis |
| OpenCode | `--model <provider/model>` | No verified interactive effort flag |
| Pi | `--model <model>` | `low`, `medium`, `high`, `xhigh` |
| Grok | `--model <model>` | `low`, `medium`, `high` |

`bin/fm-spawn.sh` owns omission of unsupported values and the current command syntax.

## Skill invocation

Use the target adapter's form and verify the command submitted rather than remaining in an autocomplete popup.
Natural language is the safe fallback when no distinct invocation form is verified.

| Adapter | Invocation |
| --- | --- |
| Claude | `/<skill>` |
| Codex | `$<skill>` |
| OpenCode | Natural language unless current verified slash behavior is known |
| Pi | Natural language unless current verified command behavior is known |
| Grok | `/<skill>` |

`fm-send` owns popup settling and submission retry.
Do not manually reproduce backend-specific timing.

## Recovery facts

| Adapter | Busy signal | Interrupt | Exit | Resume or relaunch note |
| --- | --- | --- | --- | --- |
| Claude | `esc to interrupt` | Escape once | `/exit` | Relaunch through the task's recorded spawn path. |
| Codex | `esc to interrupt` | Escape once | `/quit` | `codex resume <session-id>` when a recorded session is available. |
| OpenCode | `esc interrupt` | Escape twice | `/exit` | Relaunch with `--continue`; send follow-up after the TUI starts. |
| Pi | `Working...` | Escape once | `/quit` | Relaunch through the recorded task path with the same brief and task extensions. |
| Grok | `Ctrl+c:cancel` | Ctrl+C once | Ctrl+Q twice | `grok --resume <session-id>` or the recorded continue path. |

Use `stuck-crewmate-recovery` for the full escalation ladder.
A low context indicator is not evidence of a stuck agent.
Do not change shared daemon lifecycle while recovering a no-mistakes task.

## Verifying a new adapter

Use a trivial isolated supervised task and verify detection, launch autonomy, worktree placement, busy and idle signals, text submission, trust and permission behavior, interrupt, exit, resume, skill invocation, turn-end signaling, primary supervision, and cleanup.
Record mechanics in scripts, empirical evidence in the relevant doc, and only the concise operational facts here.
Do not declare support from help text or a neighboring adapter alone.
