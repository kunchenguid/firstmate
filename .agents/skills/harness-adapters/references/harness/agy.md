# agy (Antigravity CLI)

Google's Antigravity CLI, verified end to end on 2026-09-10 with agy 1.2.0 on macOS.
Launch shape: `agy --mode accept-edits --model <model> --effort <level> --add-dir <worktree> --add-dir <state> --add-dir <brief-dir> -i "<brief>"`.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it, and the router owns that boundary.
agy self-updates aggressively and without asking - it moved 1.1.25 -> 1.1.28 -> 1.2.0 during the session that verified it - so treat every version-scoped fact here as refreshable rather than settled, and re-run the live guard after an upgrade.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, resolved once and refused if absent. A single self-updating Go binary; the installed path is the real executable, not a launcher. |
| Launch | `-i "<prompt>"` runs the opening prompt and KEEPS the interactive session. `-p` is a one-shot headless run and is never used for a worker. |
| Directory grants | `--add-dir`, repeatable, and MANDATORY - see "The worktree grant" below. |
| Approvals | No reviewed-auto mode. `--mode accept-edits` covers file edits only; shell commands always prompt. See "Approvals" below. |
| Busy state | None. agy has no working hook surface and no wired semantic source, so state comes from the runtime backend's own agent-state classifier (`bin/backends/tmux.sh`). |
| Rendered tail | Not a state source, but the running turn's footer is the one ASCII busy token: `esc to cancel` while a turn runs, `? for shortcuts` when idle. The right of the footer names the active mode and model, e.g. `accept-edits · Gemini 3.8 Flash · medium`. |
| Turn end | None. See "No turn-end hook" below. |
| Exit | `/exit` (alias `quit`), one Enter; prints `Resume with -c (or command below): agy --conversation=<uuid>`. |
| Interrupt | Single `Escape`, which prints `Interrupted · What should Antigravity CLI do instead?` and leaves the composer EMPTY, so no clear key is needed. |
| Resume | `agy -c` / `--continue` for the most recent conversation, or `agy --conversation=<uuid>` from the id printed at exit. |
| Models | `--model <model>`; `agy models` lists the account's ids. Effort is also encoded as a model-id suffix - see "Model and effort". |
| Effort | `--effort low|medium|high` ONLY; anything above is refused. See "Model and effort". |
| Marker | `JETSKI_APP_DATA_DIR=antigravity-cli` on tool subprocesses, alongside `ANTIGRAVITY_LS_VERSION=cli-<version>`, `ANTIGRAVITY_PROJECT_ID`, `ANTIGRAVITY_TRAJECTORY_ID`, `ANTIGRAVITY_LS_ADDRESS`, and `ANTIGRAVITY_SOURCE_METADATA`. agy does NOT set `GEMINI_CLI`. |
| Composer | Bordered `>` prompt. Under accept-edits it carries the ghost placeholder `Accept-edits mode: file edits auto-approved (shift+tab to cycle)`. |
| Skill | `/<skill>`; typing `/` opens a filtered command menu and ONE Enter selects and submits. |
| Config | Global user settings at `~/.gemini/antigravity-cli/settings.json`; shared customization (hooks, skills, plugins, per-project settings) under `~/.gemini/config/`. Firstmate writes none of it. |

## Not the Gemini CLI

agy shares the `~/.gemini` configuration root with Google's separate `gemini` adapter and is a different tool with a different launch, approval model, and hook story.
Detection keeps them apart on their own markers: agy publishes `JETSKI_APP_DATA_DIR=antigravity-cli` and no `GEMINI_CLI`, and the value is the CLI's exact app-data directory, which the Antigravity IDE does not share (the IDE keeps state under `~/.gemini/antigravity`).
`JETSKI_APP_DATA_DIR` is tested before the `CLAUDECODE` line because whether agy scrubs an inherited Claude marker was NOT verified; ordering it first is correct either way, and the launch clears the foreign markers as defense in depth.

## The worktree grant

Every launch must pass `--add-dir` for the task worktree, and every granted path must be PHYSICALLY RESOLVED.

Both halves are load-bearing, and each fails in its own quiet way:

- With no grant, agy does not refuse and does not prompt.
  It writes into its own scratch directory (`~/.gemini/antigravity-cli/scratch`) while the model reports success, so the worker looks productive and the task's local copy never changes.
- With an unresolved grant whose parent is a symlink, agy resolves the path before testing it against the granted workspace, decides its own worktree is outside it, and parks on `Allow creation of this file? ... Reason: outside workspace`.

A resolved grant also keeps agy's workspace-trust dialog off the launch path entirely.
That dialog is not merely an extra keystroke: accepting it appends the path to `trustedWorkspaces` in the operator's own global settings, so a launch that raises it grows a file Firstmate does not own, once per task worktree, forever.
Trust is not inherited from a parent directory, so every fresh worktree would raise it.

`../../../../../bin/fm-spawn.sh` grants the worktree, this home's state directory, and the brief's directory, each resolved.

## Approvals

agy has no equivalent of Claude's reviewed `--permission-mode auto` or Codex's `--approve-for-me`.
Its three options are the default review mode, `--mode accept-edits`, and the blanket `--dangerously-skip-permissions`.

`config/crew-permissions` therefore maps onto the middle option and never onto the blanket one:

| Setting | agy launch | Effect |
|---|---|---|
| `auto` (or absent) | `--mode accept-edits` | File edits auto-approved inside the granted directories. Shell commands still prompt. |
| `manual` | no `--mode` flag | agy's default review mode; edits prompt too. |
| anything else | refused | The launch stops; there is no fallback onto the bypass. |

`--dangerously-skip-permissions` is emitted by neither setting and is never a fallback when a worker parks.
That is deliberate and matches the captain's standing preference for reviewed permissions over unconditional bypass; it is also the first thing anyone will be tempted to add the first time an agy worker blocks, so it is pinned by test.

**`accept-edits` covers file edits, not shell commands.**
Verified: under `--mode accept-edits` a write through the file tool completed with no prompt, while `date` was still denied headless and still prompted interactively.

### Expect an agy worker to block

This is the adapter's defining operating characteristic, not a defect to route around.

The prompt is a rendered, answerable choice, so the stall is visible to a supervisor rather than silent:

```
Requesting permission for:
   <command>
Run this command?
> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with '<prefix>'
  3. Yes, and always allow for commands that start with '<prefix>' (Persist to settings.json)
  4. No, cancel
```

Option 2 grants for the rest of that conversation without touching any file; option 3 persists into the operator's global settings and should not be chosen on their behalf.
A denial is handled cleanly - the pane prints `⎿ User declined the tool call` and stays usable.

Two consequences worth planning around, both observed in a real spawn:

- The standard brief's status protocol is an `echo ... >>` shell command, so an agy worker requests approval for **every status line it appends**, including its final `done:`.
- The model chooses its own tool.
  `gemini-3.8-flash` frequently writes files with a shell heredoc rather than the edit tool, and those writes prompt even under `accept-edits`.

There is no per-session or per-project allow-list Firstmate can set to soften this.
`permissions.allow` (entries like `command(ls)`) is read only from the operator's global `settings.json`, with per-project overrides under `~/.gemini/config/projects/`; a workspace-local `.agents/settings.json` is NOT loaded, verified with the workspace trusted.
Both usable locations are the operator's own machine state, so Firstmate does not write them.
An operator who wants a quieter agy worker can add their own allow rules there deliberately.

Headless `-p` runs behave differently and are not the worker path: a tool needing approval is auto-denied with a stderr notice naming the missing rule, and the run still exits 0.

## No turn-end hook

agy's hook surface loads but does not execute.
`~/.gemini/config/hooks.json` is read and `/hooks` lists its entries as `enabled`, yet neither a `Stop` hook on completed turns nor a `PreToolUse` hook on a tool that actually ran ever fired - headless or interactive.
A workspace-local `<workspace>/.agents/hooks.json`, which agy's own release notes document, is not loaded at all.
`enable_json_hooks` appears in the binary as a feature flag, so this may be gated rather than absent.

So agy installs no hook and mints no per-task wiring: there is nothing for a relaunch to retire, and `state/<id>.turn-ended` is never written.
This is the muse precedent, minus muse's session-log fold: agy tasks have no semantic busy record at all, and their state comes from the backend's agent-state classifier.
Because that classifier is the ONLY state source for an agy task, `bin/backends/tmux.sh` must recognize the `agy` process name; without it every control verb refuses on an `ambiguous` endpoint.

The absence of a turn-end signal, together with the absence of a reviewed-auto approval mode, is why agy is refused for secondmate and primary work: both are exactly what unattended supervision depends on.
agy does keep a durable per-conversation transcript at `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`, whose records carry `step_index`, `source`, `type`, `status`, and `created_at`, with `history.jsonl` mapping workspace to conversation id.
That is a plausible future busy source in the shape of muse's and cursor's, but it is recorded here as an observation only; nothing folds it today.

## Model and effort

The captain's named model is `gemini-3.8-flash`, and `../../../../../bin/fm-spawn.sh` passes whatever model it is given rather than pinning one.

Effort is published TWICE and the two forms conflict:

- `agy models` lists effort-suffixed ids: `gemini-3.8-flash-high`, `-medium`, `-low`.
- `--effort low|medium|high` is a separate flag.

Passing both refuses the launch: `--model gemini-3.8-flash-high --effort low` exits with `--model gemini-3.8-flash-high conflicts with --effort=low`.
The unsuffixed base id is accepted even though the listing does not show it, and composes with the flag.
The adapter therefore emits at most one: a model id already carrying a level wins and no effort flag is sent.

Firstmate's `xhigh` and `max` are above agy's ceiling - `--effort xhigh` is refused with `invalid --effort "xhigh" (valid: low, medium, high)` - so both cap onto `high` rather than being dropped, per `../common/model-and-effort.md`.
The requested level stays recorded in task metadata.

## Interruptions Firstmate cannot suppress

agy periodically renders a feedback survey in the pane:

```
 How's the CLI experience so far? Help us improve:
 [1] Good  [2] Fine  [3] Bad  [0] Skip
```

It appeared mid-task during a real spawn and waits for a keypress (`0` skips).
The control is the global `showFeedbackSurvey` setting; agy exposes no launch flag or environment variable for it, so Firstmate cannot disable it per launch the way it disables Claude's feedback prompts.
Treat it as another reason an agy pane can sit idle-looking with work outstanding, and as something an operator can turn off in their own settings if it becomes a nuisance.

## Verification

`../../../../../docs/verification/runtime-backends.md` owns the dated evidence.
`tests/fm-agy-harness.test.sh` is the portable regression; `tests/fm-agy-signals-live-e2e.test.sh` is the credentialed live guard (`FM_AGY_SIGNALS_LIVE=1`) that refreshes these facts against the installed binary.
