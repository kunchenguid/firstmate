# agy (Anti-Gravity CLI)

Verified for crew, scout, secondmate, and primary work on tmux on 2026-07-30 with Anti-Gravity CLI 1.1.8, and re-verified end to end on 2026-09-09 with 1.1.28 through `../../../tests/fm-agy-live-e2e.test.sh`.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.
Firstmate drives Agy's persistent interactive TUI and never its one-shot `--print --output-format stream-json` surface, because a completed headless process cannot receive later `fm-send` steers in the same live session.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `agy`, a single native executable resolved from `PATH` by `../../../bin/fm-spawn.sh`. |
| Launch | Bare interactive `agy [--model <id>] [--effort <level>] --dangerously-skip-permissions` with no prompt, followed by readiness-gated absolute brief-pointer delivery; the template stays a bare `agy` literal, so the shared marker-clearing wrap never prefixes it. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `agy-regex`: the ASCII footer `esc to cancel`, read only from the live bottom nonblank row so transcript or command-output copies of the phrase never read as busy. Agy has a Stop hook but no verified semantic turn-start event, so this harness-scoped rendered fallback is its only current-state source. |
| Exit command | `/exit`, which prints `agy --conversation=<uuid>` for exact resume. |
| Interrupt | Single Escape returns the TUI to idle and prints `Interrupted · What should Antigravity CLI do instead?`; an already-started shell child may continue until it exits. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; slash autocomplete can consume the first Enter, so the shared submit retry re-sends Enter without retyping. |
| Model flag | `--model <id>`; discover ids with `agy models`, whose verified 1.1.28 listing carried Gemini 3.8, 3.7, and 3.6 Flash (each in high, medium, and low tiers), Gemini 3.1 Pro, Claude Sonnet 4.6, Claude Opus 4.6 Thinking, and GPT OSS 120B profiles; Firstmate passes no default model, so an omitted `--model` leaves Agy on its own account default. |
| Effort flag | `--effort <low\|medium\|high>`; 1.1.8 through 1.1.28 reject `xhigh` and `max`, so Firstmate records either in task metadata and omits the flag. |
| Model discovery | `agy models` lists the models available to the current installation and account. `quota-axi` has no provider row for an Antigravity account, so `../../../bin/fm-quota-choose.sh` refuses an `agy:` candidate by name. |
| Marker | `ANTIGRAVITY_AGENT=1` in tool child processes, tested before every other marker in `../../../bin/fm-harness.sh`; the parent TUI is detected by `agy` ancestry. |
| Composer | A bare `>` row between two long horizontal separators, followed by `? for shortcuts` when idle or `esc to cancel` when busy. `../../../bin/fm-composer-lib.sh` recognizes that bare `>` only inside its complete separator pair with a verified footer; a bare unstructured `>` remains an unsafe shell prompt and returns `unknown`. Agy 1.1.27 and later may render a one-time feedback survey (`How's the CLI experience so far?`) in place of the composer after a turn: the busy footer is unaffected, the composer proof reads `unknown` until the survey is answered, and `fm-send` still delivers because its advisory check skips only on visibly pending text. |
| Autonomy | `--dangerously-skip-permissions`, verified by an unattended shell tool call. |
| Trust | Fresh workspaces show `Do you trust the contents of this project?` with `Yes, I trust this folder` selected; `../../../bin/fm-spawn.sh` accepts only that exact surface with Enter. |
| Resume | `agy --continue` resumes the most recent conversation for the workspace and `agy --conversation=<uuid>` resumes the exact id printed by `/exit`; neither carries a verified pane-resume contract, so use deterministic relaunch. |

## Brief delivery

Bare launch before prompt delivery is load-bearing.
On a fresh trusted-path decision, Agy starts with zero project hooks, shows the trust dialog, then loads the project hooks after trust is accepted.
An initial `--prompt-interactive` turn can therefore finish before the newly loaded Stop hook participates.
Firstmate launches with no prompt, accepts only the exact verified trust dialog, waits for the complete empty composer, then sends `Read the brief at <absolute-path> and follow it exactly.`.
Delivery is confirmed by the task turn-end marker, or by the echoed pointer text plus either the `esc to cancel` busy footer or a returned-to-idle empty composer.
Spawn removes any `state/<id>.turn-ended` marker left by a previous incarnation right before the pointer is submitted, so a relaunch can only credit a marker written by this incarnation's hook.
The idle-composer branch is load-bearing: secondmate spawns create no task-local turn-end hook, and a brief turn that starts and finishes between two polls leaves no busy footer to observe (`agy_wait_for_delivery` in `../../../bin/fm-spawn.sh`, regression `../../../tests/fm-agy-harness.test.sh`).
Tmux, Herdr, Orca, and cmux route their composer decisions through the shared separated-composer structure.
Zellij has no cursor or ANSI composer primitive and retains its existing pane-diff submission proof, so a named Agy composer branch is not applicable there.

## Detection

`../../../bin/fm-harness.sh` tests `ANTIGRAVITY_AGENT=1` before every other marker, so a worker launched from an Agy primary would inherit its parent's identity.
Every other verified adapter's launch therefore clears the marker at its own boundary through `env -u ANTIGRAVITY_AGENT` in `../../../bin/fm-spawn.sh`, while raw unverified launch commands pass through untouched.
`../../../bin/fm-session-lock-lib.sh` and `../../../bin/backends/tmux.sh` match the exact process name `agy`, anchored like omp so an unrelated command such as `strategy` is never claimed as a live agent.

## Task turn-end hook

Agy discovers `hooks.json` in `.agents`, `.agent`, `_agents`, and `_agent`.
Firstmate selects the first root whose `hooks.json` is absent, creates one task-local Stop hook there, and refuses if every root is occupied or unsafe.
It never merges with or overwrites project hook configuration.
The generated hook calls `../../../bin/fm-agy-turnend-hook.sh` with an exact workspace, the private `state/agy-turn-end.d/` registry, and a random task token.
The script requires the Stop payload's sole `workspacePaths` entry, the worktree `.fm-agy-turnend` pointer, the expected token, and the private registry target to agree before it touches `state/<id>.turn-ended`.
An arbitrary Agy session outside that bound Firstmate worktree has no matching hook, pointer, and registry tuple and cannot write task state.
Teardown removes the generated hook, empty customization directory, pointer, private auth entry, and state token, and leaves a project-owned root or a project-authored `hooks.json` standing.
A relaunch retires that same wiring through `../../../bin/fm-control-lib.sh`'s tables before the replacement arms, so a switch away from Agy leaves no live hook and an Agy re-arm never orphans the previous customization root.

## Primary integration

The primary Firstmate checkout carries `.agents/hooks.json`.
Its Stop hook calls `../../../bin/fm-turnend-guard-agy.sh`, which invokes the shared primary predicate only for `executionNum: 0`.
When the predicate blocks, the wrapper returns `{"decision":"continue","reason":"..."}` and Agy re-enters the same live execution loop.
Every later execution number is allowed, which bounds the adapter to one forced follow-up.
The same file's `run_command` PreToolUse hook passes `.toolCall.args.CommandLine` to the watcher-arm seatbelt and consumes the same stdout `decision=deny` object as Grok; `../../../docs/arm-pretool-check.md` owns the exact shape.
Agy 1.1.28 exposes agent selection but no verified in-session delegation-shaped tool token, so its subagent guard axis remains inspected but unwired under `../../../docs/subagent-guard.md`.
Agy 1.1.28 has no SessionStart hook event, verified by inspection of its installed lifecycle-hook contract, so the native session-start nudge is not applicable.
Its primary supervision protocol (`../../../docs/supervision-protocols/agy.md`) uses the same bounded foreground checkpoint shape as Codex, because no verified Agy background task can wake the same persistent TUI turn.
Launch a primary with `agy --dangerously-skip-permissions` inside the home and accept the project trust prompt once per clone so `.agents/hooks.json` loads.
`../../../tests/fm-agy-harness.test.sh` is the portable regression, the default-on `../../../tests/fm-harness-liveness-drift-live-e2e.test.sh` covers an installed `agy` for liveness drift, and the opt-in `../../../tests/fm-agy-live-e2e.test.sh` (`FM_AGY_LIVE_E2E=1`) drives spawn, both Stop hooks, the continue bound, steer, busy, interrupt, exit, and teardown against the installed binary; run it after every Agy upgrade.
The dated commands, payloads, and outputs are recorded in [`docs/verification/agy-harness.md`](../../../../../docs/verification/agy-harness.md).
