# Verification: the GitHub Copilot CLI harness adapter

Active empirical evidence for firstmate's `copilot` adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

This adapter is currently DETECTION-ONLY.
Firstmate itself was running as a live Copilot CLI primary when this evidence was captured, which made the marker and ancestry facts below directly observable.
Interrupt, exit, resume, busy-state hooks, and a crewmate/secondmate launch shape were deliberately NOT exercised end to end: doing so against the very process gathering this evidence would have risked killing or wedging that session, and no second machine or second installed harness was available to spawn Copilot CLI as a worker and drive it from the outside.
Do not read anything below as authorizing crewmate, scout, or secondmate dispatch on this harness; `harness-adapters`' non-negotiated safety rule still applies until that separate live verification lands.

## Subject

| Field | Value |
|---|---|
| Version | `GitHub Copilot CLI 1.0.88` (`copilot --version`) |
| Verified | 2026-09-24 |
| Platform | macOS arm64 (Darwin), installed at `/opt/homebrew/bin/copilot` |

## Process identity

A bash tool subprocess launched by an interactive `copilot` session carried these variables (`env | sort | grep -iE '^COPILOT'`):

```
COPILOT_AGENT_SESSION_ID=8e05a379-0ead-4664-ae6b-24f782850083
COPILOT_CLI=1
COPILOT_CLI_BINARY_VERSION=1.0.88
COPILOT_CLI_RESOLVED_DIST_DIR=/Users/.../Library/Caches/copilot/pkg/darwin-arm64/1.0.88
COPILOT_LOADER_PID=54850
COPILOT_MEDIAREMOTE_ADAPTER_DIR=/Users/.../Library/Caches/copilot/pkg/darwin-arm64/1.0.88/prebuilds/darwin-arm64/mediaremote-adapter
```

`COPILOT_CLI=1` is the identity marker: it names the harness unambiguously when present, the same shape as `CLAUDECODE=1` or `GROK_AGENT=1`.
Whether it survives being inherited into a DIFFERENT harness's tool subprocess (the hazard already documented for cursor/gemini/rovo in `bin/fm-harness.sh`) is UNVERIFIED: no other harness was installed on the machine this was captured from, so the two-primary A/B those adapters ran was not possible here.
`bin/fm-harness.sh` checks it last among markers for that reason, so an unverified survival hazard cannot outrank an already-verified one.

Process ancestry from the same session (`ps -o pid=,ppid=,comm=`, walking parents):

```
PID   PPID  COMM
65043 54850 /bin/bash
54850 48321 copilot
48321 16060 -zsh
16060     1 herdr
```

`ps -o comm=` reports the live process name as exactly `copilot`, a single native binary with no version suffix observed (unlike muse's `muse-bin-<version>` or gemini's node-bundle `MainThread`).
`bin/fm-harness.sh` matches it anchored (`copilot) echo "comm copilot";;`), never `*copilot*`, for the same reason every other exact-name arm in that file is anchored.

## Documented, not yet live-exercised

`copilot --help` and `copilot help environment` were read on the installed 1.0.88 binary; the facts below are the CLI's own stated behavior, not a Firstmate-driven end-to-end observation, and are recorded here only as a starting point for the still-open live verification:

- Non-interactive launch: `-p/--prompt <text>` "Execute a prompt in non-interactive mode (exits after completion)"; `-i/--interactive <prompt>` "Start interactive mode and automatically execute this prompt" is the shape closer to how firstmate launches a crewmate with an initial brief while keeping the pane alive for steering.
- Autonomy: `--allow-all-tools` ("required for non-interactive mode") and env `COPILOT_ALLOW_ALL`, analogous to Claude's `--dangerously-skip-permissions`.
- Model/effort: `--model <model>` and `--reasoning-effort <none|minimal|low|medium|high|xhigh|max>` are both direct top-level flags.
- Resume: `-r/--resume [<value>]` (session ID, task ID, ID prefix, or exact case-insensitive name) and `--continue` (most recent session); `--session-id <id>` both resumes and can set a UUID for a new session.
- Directory scoping: `-C <directory>` changes the working directory before doing anything else; `--add-dir <directory>` "load its `.github/skills` and `.agents/skills` as trusted configuration".
- Skill/instruction discovery: `copilot skill --help` lists project sources `.github/skills/`, `.agents/skills/`, and `.claude/skills/`, and the top-level help documents `AGENTS.md` (git root and cwd) among its respected instruction files, alongside `CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md`.
- No hooks subcommand and no documented turn-end/busy-state hook mechanism (nothing analogous to Claude's `Stop` hook or Gemini's `BeforeAgent`/`AfterAgent`) was found in `copilot --help`'s command list (`app`, `login`, `help`, `init`, `update`, `version`, `sessions`, `memories`, `plugin`, `mcp`, `skill`, `instruction`, `lsp`, `completion`). This is a real gap, not an oversight: it blocks a trusted busy-state source and a turn-end guard the way every other primary/crewmate integration in this repo has one.
- Documented interrupt/exit keys from `copilot`'s own `/help`: `ctrl+c` cancels, `ctrl+c` twice exits, `esc esc` "clear input, interrupt, stop agents, or rewind", `ctrl+d` shuts down. None of these were driven against a firstmate-launched pane.

## What remains before crewmate/secondmate/primary dispatch can be verified

1. A real end-to-end launch-then-brief-then-report cycle, verified against a firstmate-launched pane (not the primary session), the same way `docs/verification/rovo.md` and `docs/verification/muse.md` verify their adapters.
2. A verified interrupt and exit mechanic (`bin/fm-control.sh`), including whatever the `esc esc` menu actually does when driven programmatically rather than typed by a person.
3. A trusted busy-state source. No hook mechanism was found; `--output-format json` (JSONL event stream) is the most likely structural alternative and needs to be captured and shaped into a `fm-busy-lib.sh` source the way Muse's session log or Gemini's hooks were.
4. Whether the marker survives a nested launch from, or into, another harness (the survival-hazard question above), which needs a second installed harness to test.
5. A `docs/supervision-protocols/` entry and `references/harness/copilot.md` primary-integration section, only after 1-4 are real; until then it stays `Unsupported and unverified` there, the same disclosure gemini's own primary-integration section uses.

## Refreshing this record

Re-run the process-identity capture above after any Copilot CLI upgrade (`copilot --version`; `env | sort | grep -iE '^COPILOT'` from a tool subprocess; `ps -o pid=,ppid=,comm=` walking this process's ancestry), since the marker set and process name are vendor-controlled surfaces.
`tests/fm-copilot-harness.test.sh` pins the portable regression for the marker and ancestry precedence captured here.
