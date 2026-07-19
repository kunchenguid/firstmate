---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for agy, claude, codex, grok, opencode, pi, and the supported glm launch profile.
user-invocable: false
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
The captain may override that file at bootstrap or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Each adapter splits into mechanics and knowledge.
The mechanics, including launch command, autonomy flag, and turn-end hook, live in `bin/fm-spawn.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` names an unverified adapter, tell the captain and fall back to firstmate's own harness until that adapter is verified.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `fm-tmux-lib.sh` defaults, any needed `FM_COMPOSER_IDLE_RE` empty-composer override, and the verified knowledge here.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness`.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude/minimax: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- grok: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it with `bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, and verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the pane reader in `bin/fm-tmux-lib.sh` captures only the composer line with ANSI styling, drops dim/faint SGR 2 runs, and ignores them, so only normal-intensity typed text counts as pending input.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; `fm-send` handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

A `$<skill>` invocation opens a `$`-autocomplete (skill) popup, the same hazard as the `/` slash popup: submitting too fast lets the popup swallow the Enter, so the invocation never lands.
`fm-send` handles it the same way it handles `/` - it gives the popup a longer settle (1.2s) between typing and the first Enter, with `fm_tmux_submit_core`'s retried Enter as the safety net - but the `$` settle is scoped to `harness=codex`, read from the target's `state/<id>.meta`.
That scope matters because, unlike `/`, a leading `$` commonly starts ordinary text (`$5/month`, `$HOME`), so a universal `$` rule would needlessly slow plain steers to claude/opencode/pi; only a codex target receiving a `$...` message gets the popup-settle.
An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex (the safe fast-path default).
This is why the validation trigger (`$no-mistakes`) to a codex crew now lands on the first Enter instead of biting the popup.

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

Resume after exit with `codex resume <session-id>`.
The session id is printed on quit.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.3)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

## grok (VERIFIED 2026-07-01, grok 0.2.77)

| Fact | Value |
|---|---|
| Busy-pane signature | `Esc:cancel` or `[stop]` in the footer during a running turn/tool |
| Exit command | `/exit` |
| Interrupt | single Escape cancels the current operation |
| Skill invocation | no separate verified form; use natural language if uncertain |

Authentication is stored by the Grok CLI under `~/.grok/`; Firstmate does not store Grok credentials.

Verified facts:

- `grok -p "Responde exactamente: GROK_OK"` returned `GROK_OK`.
- `grok models` reported login via `grok.com` with default `grok-composer-2.5-fast` and available `grok-build`.
- A supervised `fm-spawn` raw-launch smoke in `projects/fleet-smoke` entered an isolated treehouse worktree and returned `PASS_GROK_CREWMATE cwd=...`.
- `/exit` exits the TUI and prints a `grok --resume <session-id>` command.
- A live tool run showed `Esc:cancel` and `[stop]` while busy.

Launch template currently used by firstmate:

- `grok --no-alt-screen --always-approve "$(cat __BRIEF__)"`

No adapter-specific project trust dialog was observed in the verified smoke after `grok inspect` reported the project and bridge trusted.

No turn-end hook integration has been verified yet for Grok. Supervision can still inspect the pane and use status files, but a future adapter pass should investigate Grok hooks before treating it as equivalent to the harnesses with explicit turn-end signals.

## pi (VERIFIED 2026-06-11)

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...` (braille spinner prefix; no `esc to interrupt` text) |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so crewmates are always autonomous.
Keep the brief as one positional argument.
Multiple positional args become separate queued messages; `fm-spawn`'s template already does this correctly.

Project trust dialog can appear on the first pi run in any not-yet-trusted directory, observed even on clean worktrees.
Accept with Enter.
The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same worktree slot skip it.

`fm-spawn` keeps the turn-end extension in `state/`, outside the worktree, because project-local extension files make the trust gate strictly worse and pollute the project.
The extension must listen for pi's `turn_end` event, not `agent_end`, so the watcher wakes after each completed turn instead of only when the whole agent run exits.
Pi sets `PI_CODING_AGENT=true` for its children; this is its harness-detection env marker.

## agy (VERIFIED 2026-07-07, Antigravity CLI 1.0.16)

`agy` is the firstmate agent CLI installed at `~/.local/bin/agy`.

| Fact | Value |
|---|---|
| Busy-pane signature | `Press esc to interrupt generation.` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | no separate verified form; use natural language if uncertain |

What is verified:

- `agy --help` works and reports:
  - `--dangerously-skip-permissions`
  - `--print` / `--prompt`
  - `--prompt-interactive` / `-i`
  - `--continue` / `-c`
  - `--conversation`
  - `--model`
  - `--sandbox`
- `agy --print "say hi"` responds non-interactively.
- `agy --prompt-interactive "say hi"` opens an interactive session.
- The binary's visible busy text includes `Press esc to interrupt generation.`
- A supervised `fm-spawn` smoke in `projects/fleet-smoke` returned `PASS_AGY_CREWMATE cwd=...` from the actual treehouse worktree after launching with `--new-project --add-dir "$PWD"` from a non-hidden symlink alias to the worktree.
- `/exit` cleanly returns to the shell and prints the resume hints.

What is not yet verified:

- whether resume via `--continue` or `--conversation` is reliable enough to encode as a recovery path

Model list observed from `agy models`:

- Gemini 3.5 Flash (Medium/High/Low)
- Gemini 3.1 Pro (Low/High)
- Claude Sonnet 4.6 (Thinking)
- Claude Opus 4.6 (Thinking)
- GPT-OSS 120B (Medium)

Launch template currently used by firstmate:

- `agy --dangerously-skip-permissions --new-project --add-dir "$PWD" --prompt-interactive "$(cat __BRIEF__)"`

First-use trust dialog was observed:

- `Do you trust the contents of this project?`
- Accept with Enter.

Important quirk:

- agy rejects hidden workspace roots such as `~/.treehouse/...` (`Failed to add workspace folder ... is hidden: ignore uri`) and then falls back to `default-cli-project`, which makes tool commands run from `~/.gemini/antigravity-cli` or its `scratch/` directory instead of the intended repo.
- Firstmate works around this by launching agy from a non-hidden symlink alias under `state/agy-workspaces/<id>` that points at the real isolated worktree/home. Do not remove that aliasing without re-verifying cwd and write-through behavior.

## glm (SUPPORTED 2026-06-28 via Claude Code on Z.AI GLM Coding Plan)

This is the Z.AI-backed Claude Code launch profile firstmate uses when `config/crew-harness` is set to `glm` or `zai`.
It uses the same interaction model as `claude`:

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (same as claude) |

Launch profile:

- `claude --dangerously-skip-permissions`
- `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`
- `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`
- `ANTHROPIC_AUTH_TOKEN` from `ZAI_API_KEY` if set, otherwise any existing `ANTHROPIC_AUTH_TOKEN`
- `API_TIMEOUT_MS=3000000`
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
- `ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2`
- `ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7`

Use the same `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` suppression if you want the same ghost-text defense as the regular claude harness.

## deepseek (VERIFIED 2026-07-01 via Claude Code on DeepSeek Anthropic API)

This is the DeepSeek-backed Claude Code launch profile firstmate uses when
`config/crew-harness` is set to `deepseek`, or when `fm-spawn.sh` receives
`deepseek` as the per-task harness override.
It uses the same interaction model as `claude`:

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (same as claude) |

Launch profile:

- `bin/fm-claude-deepseek.sh`
- `claude --dangerously-skip-permissions`
- `FIRSTMATE_HARNESS=deepseek`
- `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`
- `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`
- `ANTHROPIC_AUTH_TOKEN` from the local `config/deepseek-api-key` file, scoped to the wrapper process
- `ANTHROPIC_MODEL=deepseek-v4-pro[1m]`
- `ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]`
- `ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash`
- `CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash`
- `CLAUDE_CODE_EFFORT_LEVEL=max`

Verification:

- `bin/fm-claude-deepseek.sh "Responde solo: DeepSeek directo OK"` returned exactly `DeepSeek directo OK`.

Do not set global `ANTHROPIC_*` variables for this profile. The wrapper deliberately
overrides them only for the launched process so it does not disturb the existing GLM
profile or any captain shell configuration.

## minimax (VERIFIED 2026-07-04 via Claude Code on MiniMax Anthropic API)

This is the MiniMax-backed Claude Code launch profile firstmate uses when
`config/crew-harness` is set to `minimax`, or when `fm-spawn.sh` receives
`minimax` as the per-task harness override.
It uses the same interaction model as `claude`:

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (same as claude) |

Launch profile:

- `config/minimax`
- `claude --dangerously-skip-permissions`
- `FIRSTMATE_HARNESS=minimax`
- `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
- `ANTHROPIC_BASE_URL=https://api.minimax.io/anthropic`
- `ANTHROPIC_AUTH_TOKEN` from the local `config/minimax-api-key` file, scoped to the wrapper process
- `ANTHROPIC_MODEL=MiniMax-M3`
- `ANTHROPIC_DEFAULT_OPUS_MODEL=MiniMax-M3`
- `ANTHROPIC_DEFAULT_SONNET_MODEL=MiniMax-M3`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL=MiniMax-M3`

Verification:

- `config/minimax -p "Responde exactamente: MINIMAX_M3_OK"` returned exactly `MINIMAX_M3_OK`.

Do not set global `ANTHROPIC_*` variables for this profile. The wrapper deliberately
overrides them only for the launched process so it does not disturb the existing GLM
profile or any captain shell configuration.
