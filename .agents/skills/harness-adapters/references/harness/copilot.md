# GitHub Copilot CLI

GitHub's `copilot` command, verified as a DETECTION-ONLY adapter on 2026-09-24 with GitHub Copilot CLI 1.0.88 on macOS.
`../../../../../docs/verification/copilot.md` owns the full evidence and its own explicit list of what remains unverified.
Do NOT dispatch a crewmate, scout, or secondmate on this harness: `bin/fm-spawn.sh` has no launch, busy-state, or control wiring for it, and none of the facts below were exercised end to end against a firstmate-launched pane.

## Operating facts

| Fact | Value |
|---|---|
| Marker | `COPILOT_CLI=1` on the CLI's own process and its tool subprocesses. Checked LAST among markers in `../../../../../bin/fm-harness.sh` because whether it survives being inherited across a foreign harness boundary is unverified (see Detection below). |
| Process name | `copilot`, a single native binary with no version suffix (verified, 1.0.88). Anchored exact match, never `*copilot*`. |
| Non-interactive launch (documented, unverified) | `-p/--prompt <text>` exits after completion; `-i/--interactive <prompt>` starts interactive mode and auto-executes the given prompt, keeping the session alive - the shape closer to how firstmate seeds a crewmate with an initial brief. |
| Autonomy (documented, unverified) | `--allow-all-tools` ("required for non-interactive mode"), also settable via `COPILOT_ALLOW_ALL`. |
| Model (documented, unverified) | `--model <model>`, discoverable via `/model`. |
| Effort (documented, unverified) | `--reasoning-effort <none\|minimal\|low\|medium\|high\|xhigh\|max>`, a direct top-level flag. |
| Resume (documented, unverified) | `-r/--resume [<value>]` (session/task ID, ID prefix, or exact name) and `--continue` (most recent session); `--session-id <id>` also sets a UUID for a new session. |
| Directory scoping (documented, unverified) | `-C <directory>` changes the working directory before doing anything else; `--add-dir <directory>` loads that directory's `.github/skills` and `.agents/skills` as trusted configuration. |
| Skill/instruction discovery (documented, unverified) | Reads `.github/skills/`, `.agents/skills/`, and `.claude/skills/` for project skills, and respects `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md` among its instruction sources per its own `--help`. |
| Interrupt/exit (documented, unverified) | Its own `/help` documents `ctrl+c` (cancel), `ctrl+c` twice (exit), `esc esc` ("clear input, interrupt, stop agents, or rewind"), and `ctrl+d` (shutdown). None were driven against a firstmate-launched pane. |
| Busy state / turn-end hook | None found. `copilot --help`'s command list (`app`, `login`, `help`, `init`, `update`, `version`, `sessions`, `memories`, `plugin`, `mcp`, `skill`, `instruction`, `lsp`, `completion`) has no hooks subcommand and no documented turn-end event, unlike Claude's `Stop` hook or Gemini's `BeforeAgent`/`AfterAgent` pair. `--output-format json` (a JSONL event stream) is the most likely structural alternative and is unexplored. |

## Detection

`COPILOT_CLI=1` is checked in `harness_marker` after every already-verified marker (`CURSOR_AGENT`/`CURSOR_INVOKED_AS`, `GEMINI_CLI`, `ATLASSIAN_AGENT_TYPE`/`ROVODEV_CLI`, the `FM_OMP_HARNESS` ancestry-gated arm, `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`), so an unverified survival hazard for this new marker can never outrank an already-verified one.
The comm-strength ancestry arm (`copilot) echo "comm copilot";;` in `harness_process_verdict`) is what actually guarantees identification against a foreign marker, the same role ancestry plays for every other adapter in this file.
`../../../../../tests/fm-copilot-harness.test.sh` pins the marker-alone, ancestry-alone, and combined precedence cases.

Whether `COPILOT_CLI` survives being inherited into a DIFFERENT harness's tool subprocess, or a foreign harness's marker survives into a Copilot CLI tool subprocess, is unverified: this evidence was captured on a machine with no other harness installed, so the controlled A/B other adapters ran (see `gemini.md`, `rovo.md`) was not possible here.

## Primary integration

Unsupported and unverified beyond detection.
`../../../../../docs/supervision-protocols/` carries no copilot protocol, so a Copilot CLI primary falls back to `unknown.md`'s generic bounded-wait supervision contract - correct identity (`bin/fm-harness.sh` now reports `copilot` instead of `unknown`), but no dedicated wake mechanism.
No turn-end guard adapter exists for it and none of Claude's `Stop`-hook or Gemini's `BeforeAgent`/`AfterAgent` equivalents were found in this CLI's documented surface (see Operating facts above).
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.

## Crewmate, scout, and secondmate integration

Unbuilt and unverified.
`bin/fm-spawn.sh` has no launch-command construction, busy-state wiring, or control mechanics for this harness; do not add it to a crew-dispatch profile or `config/crew-harness`/`config/secondmate-harness` until that work lands and is verified end to end the way `docs/verification/rovo.md` or `docs/verification/muse.md` verify theirs.
`docs/verification/copilot.md` enumerates exactly what that follow-up work needs to establish.
