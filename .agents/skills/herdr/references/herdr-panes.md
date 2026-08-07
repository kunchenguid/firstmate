# herdr-panes — generic pane, tab, and workspace control

Reached from [`SKILL.md`](../SKILL.md) when task = pane-control. Herdr is a terminal multiplexer and runtime for coding agents. It organizes terminals into workspaces, tabs, and panes, detects agent identity and status, and exposes the running session through the `herdr` CLI.

The `herdr` binary in `PATH` talks to the running session. Use it to inspect neighboring work, create isolated terminal contexts, start agents and commands, read their output, and wait for state changes.

## Learn the current CLI

The installed binary is the authority for command syntax. Begin with:

```bash
herdr --help
```

Then print the relevant command group by running it without a subcommand:

```bash
herdr pane
herdr workspace
herdr worktree
herdr tab
herdr agent
herdr notification
herdr integration
herdr session
```

There is no top-level `herdr wait` command (confirmed against `herdr --help`, 2026-07-28) despite it appearing that way in older guidance. Status waits live under `herdr agent wait <target> --until <status> [--timeout MS]`; output waits live under `herdr pane wait-output <pane_id> (--match TEXT|--regex PATTERN) [--timeout MS]`.

Do not run bare `herdr` for discovery; it launches or attaches the TUI. Do not probe a mutating nested command by omitting arguments; some commands, including `herdr workspace create`, are valid with defaults and will execute. Use the command-group output above instead.

Most control commands print JSON. Read identifiers and state from those responses instead of predicting either one.

## Attach to a Herdr server running on another machine

`herdr --remote <ssh-target>` opens a live client here, attached over SSH to a Herdr server running on a **different host** — not a separate copy, the same live panes, tabs, and sessions that host's own local client (or any other remote client, e.g. a phone via Moshi's Herdr integration) is looking at. Confirmed live 2026-07-31: installed Herdr on `orca-ubuntu-vm` and attached to it from a laptop session with `herdr --remote adrian@orca-ubuntu-vm`.

```bash
herdr --remote <user>@<host>
herdr --remote <user>@<host> --session <name>   # jump straight into a specific named session there
```

- `--remote-keybindings <local|server>` — whose keybindings apply during the remote attach. Default `local` (your own machine's config, not the remote host's).
- `--handoff` — opt into live handoff for the remote attach (same flag used for update handoff).
- Requires the target host to have Herdr installed and reachable over plain SSH — no cloud provisioning involved. This is a different concern from spinning up a whole new isolated box (see the `agentbox-remote` skill for that); this is for reaching an existing host's own already-running Herdr server.
- All the pane/tab/workspace vocabulary below applies unchanged once attached remotely — IDs, `--current`, focus rules, everything is identical, just addressed at the remote server instead of the local one.

**CRITICAL — `herdr --remote` is interactive like `agentbox claude`/`attach`; never run it as a blocking tool call.** Confirmed live 2026-07-31: from an agent's Bash tool, `herdr --remote <target>` hangs indefinitely with zero connection reaching the remote server's log — tried both a plain redirect and a `script`-wrapped fake pty, neither got past local startup. This isn't a bug; it's a full-screen TUI client that needs a real terminal, same as every other interactive Herdr/agentbox command. Give the user the exact command to run themselves in their own terminal — don't try to shell it out and don't loop retrying it.

## Controlling a remote host's panes without `--remote` (the agent-usable path)

Everything in this section is what an agent should actually use instead of `--remote` — no TTY required anywhere. Confirmed end-to-end live 2026-07-31 against `orca-ubuntu-vm`.

**Direct control over plain SSH, no mirror plugin needed:** `herdr workspace create`, `herdr pane run`, `herdr pane read`, etc. are ordinary socket-API calls, not the TUI — they work fine run over SSH against a remote host's own `herdr` binary, as long as that host's Herdr server is running (start it headlessly if nothing's attached: `ssh <host> "nohup herdr server > /tmp/herdr-server.log 2>&1 & disown"`, confirmed live). Example, run from here:

```bash
ssh <user>@<host> "herdr workspace create --cwd /some/path --label mytask"
ssh <user>@<host> "herdr pane run <returned-pane-id> 'some command'"
ssh <user>@<host> "herdr pane read <returned-pane-id> --source visible --lines 30"
```

**If the `herdr-mirror` plugin (nikok6/herdr-mirror) is installed and configured** for that host in `~/.config/herdr-mirror/hosts.toml`, its workspaces/panes also mirror automatically into the **local** `herdr workspace list` as `<host>: <label>` with ordinary local pane IDs. Confirmed bidirectional: a `herdr pane run <mirrored-pane-id> "<cmd>"` issued locally against the mirrored ID actually executes on the real remote pane — verified by reading the real pane directly over SSH afterward and seeing the same output. This means once something is already running remotely and mirrored, no SSH command construction is needed at all — just address the mirrored pane ID like any other local pane.

`herdr pane read <mirrored-pane-id> --source recent-unwrapped` can transiently return blank right after a write lands (a scrollback-pointer timing artifact, not data loss) — retry with `--source visible` or a moment later if a read looks unexpectedly empty right after an action.

## IDs and current context

Public IDs are short stable handles:

- workspace: `w1`
- tab: `w1:t1`
- pane: `w1:p1`
- terminal: `term_...`

The encoded suffix can contain letters and can grow beyond one character. Treat every ID as an opaque string.

Closed tab and pane IDs are not reused and do not retarget later resources. A pane moved into another workspace receives a new public pane ID. Re-read create, split, move, list, or get responses after mutations; never construct an ID from a workspace or display number.

Herdr injects the caller's stable context into every managed pane:

```bash
printf '%s\n' "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID"
```

Prefer `--current` when a pane command should target the calling pane. Omitting a target can use the UI-focused pane, which may belong to the user or another client.

Discover live state with:

```bash
herdr workspace list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr pane current --current
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
```

## Control agents through panes

An agent runs inside a pane. Use the pane ID as the control target for agents, shells, servers, tests, and logs. This keeps spawning, input, reads, waits, and cleanup on one stable control surface.

Use workspace and tab commands for organization. Use worktree commands only when you intentionally want Herdr to create, open, or remove a Git checkout.

Pane records expose `agent`, `agent_status`, and native session metadata when available. Agent status is `idle`, `working`, `blocked`, `done`, or `unknown`.

`idle` and `done` are the same underlying semantic state with different attention state:

- `idle`: the agent is waiting and its result is considered seen.
- `done`: the agent finished and its result has not been seen.

An agent that first opens at its prompt reports `idle`, including in a background pane. After a working or blocked agent completes, it reports `done` when its tab or workspace is in the background. It reports `idle` when it completes in the active tab while the foreground client is focused. If the foreground client is explicitly unfocused, completion can become `done` even in the active tab.

Focusing a pane, switching to its tab, or regaining outer terminal focus marks the visible tab as seen, so `done` becomes `idle`. Switching away does not turn an existing `idle` status into `done`; `done` is created by a later completion while the pane is unseen. With no foreground client, a new completion in the globally active tab is treated as seen while completions in background tabs still become `done`.

## Start agents interactively

Default to a sibling pane in the current tab and current working directory. Do not create a workspace, tab, worktree, or different cwd unless the user explicitly requests that topology or location.

Honor a direction requested by the user. Otherwise inspect the caller pane's current rectangle:

```bash
herdr pane layout --pane "$HERDR_PANE_ID"
```

Split a wide pane to the right and a narrow or tall pane down. Avoid repeated same-direction splits that would create unusably narrow columns or short rows. Keep the user's focus in the calling pane:

```bash
herdr pane split --current --direction right --no-focus
```

Replace `right` with `down` when the layout calls for it.

Read `result.pane.pane_id` from the JSON response. Give the pane a useful label, then start the requested agent by running only its normal executable so its interactive TUI opens:

```bash
herdr pane rename <returned-pane-id> "reviewer"
herdr pane run <returned-pane-id> "codex"
```

Use the executable that belongs to the requested agent:

- Codex: `codex`
- Claude Code: `claude`
- pi: `pi`
- OpenCode: `opencode`
- OMP: `omp`

Do not pass the task as an argv prompt by default. Do not add non-interactive flags. Only change the normal interactive launch when the user explicitly asks for a different launch mode or command.

**Ground the brief with `binox-axi` before you write the task text.** `binox-axi <path>` (from `subagent-factory/tools/binox-axi`) is a read-only AXI CLI that inventories a target path — project clone, secondmate home, or task worktree — before dispatch: it lists the skills actually present (`.claude/skills/`, `.agents/skills/`, `skills/`, with name+description), scripts sitting orphaned in `tmp/`/scratch dirs, `bin/`/`package.json` tool scripts, and which known AXI tools resolve on `PATH` there. Run it against the target worktree/home right after the pane launches and before composing the task message, so the brief names the LOCAL skill path that actually exists there instead of guessing at a server copy or a different clone's path (`binox-axi --short <path>` for a fast skills+tmp_scripts-only pass). Never treats it as a substitute for reading a skill's own content — it only tells you what exists and where.

Inspect the pane after launch. If `agent_status` is not yet `idle`, wait for the idle transition. Once it is idle, submit the task with `pane run`:

```bash
herdr pane get <returned-pane-id>
herdr agent wait <returned-pane-id> --until idle --timeout 30000
herdr pane run <returned-pane-id> "Review the current diff and report only actionable findings."
```

Status waits match the current status immediately or wait for a future matching transition.

`pane run` is documented to send the text and Enter together, but confirmed unreliable in practice (2026-07-28): the text can land in the input box without the Enter actually submitting it, leaving the agent sitting idle indefinitely on an unsent message. After any `pane run`, verify it actually submitted — `herdr agent wait <id> --until working --timeout <short>` and check for a timeout, or `pane read` and look for the text still sitting after an unsent `❯ ` prompt. If it didn't submit, send the Enter explicitly: `herdr pane send-keys <id> Enter`.

For normal background work, wait for the agent to start working. If the pane remains in a background tab or workspace, wait for `done` before reading its transcript:

```bash
herdr agent wait <returned-pane-id> --until working --timeout 30000
herdr agent wait <returned-pane-id> --until done --timeout 120000
herdr pane read <returned-pane-id> --source recent-unwrapped --lines 120
```

If the user is watching that tab, completion reports `idle` instead, so wait for `idle`. Always treat either `idle` or `done` as completed when inspecting `pane get`; the difference is whether the result has been seen.

If a wait times out, inspect `herdr pane get <returned-pane-id>` and `pane read` before deciding what to do. A `blocked` agent needs input; an `unknown` pane may not yet contain a detected or integrated agent.

Submit follow-ups the same way:

```bash
herdr pane run <returned-pane-id> "Now check the failing test."
```

## Run an ordinary command in another pane

Split the calling pane using the same geometry rule without moving the user's focus:

```bash
herdr pane split --current --direction right --no-focus
```

Read the new `pane_id` from the JSON response, then run and inspect the command:

```bash
herdr pane run <returned-pane-id> "just test"
herdr pane wait-output <returned-pane-id> --match "test result" --timeout 120000
herdr pane read <returned-pane-id> --source recent-unwrapped --lines 120
```

Inspect existing output before waiting for future output. A wait timeout exits with status `1`.

Use the read source that matches the task:

- `visible`: the current rendered viewport
- `recent`: recent scrollback as rendered, including soft wraps
- `recent-unwrapped`: recent scrollback with soft wraps joined; prefer it for logs and transcripts
- `detection`: the bottom-buffer snapshot used by agent detection

Use `--format ansi` when colors and terminal styling are evidence. Otherwise use text.

**A long single assistant message can hide behind the TUI's own internal scroll boundary, independent of scrollback.** Confirmed 2026-07-28: a Claude Code pane's response was cut off mid-message with a "Jump to bottom" hint visible in the render, and increasing `--lines` all the way to 2000 on `recent-unwrapped` returned the identical truncated text every time — the terminal was genuinely rendering that boundary, not scrollback running out. If a read looks suspiciously cut off right at an interesting point (a heading with no content under it, a "jump to bottom" affordance visible in the captured text), don't trust more `--lines` to fix it. For a Claude Code pane specifically, read the session transcript directly instead: find the session id from `herdr pane list` (`agent_session.value`), then read the newest matching file under `~/.claude/projects/<escaped-cwd>/<session-id>.jsonl` and extract the last assistant message's `message.content[].text` — this bypasses terminal rendering entirely and is authoritative.

If the user explicitly asks for another tab, workspace, or worktree, discover that command group and use returned IDs. Do not infer a larger topology from a request to start an agent or command.

## Plannotator: send the workspace to browser review

Use when the user asks to "annotate this in Plannotator", "send this for review", "open in Plannotator", or wants human feedback on a plan, diff, or PR through Plannotator's browser-based review UI.

Requires the `adrian.plannotator` plugin to be linked. Check first:

```bash
herdr plugin list --json
```

If it is missing, link it (manifest lives at `~/dev/herdr/herdr-plannotator-plugin/herdr-plugin.toml`):

```bash
herdr plugin link ~/dev/herdr/herdr-plannotator-plugin
```

Invocation is fire-and-forget. `herdr plugin action invoke` returns immediately with a `log_id`; the underlying `plannotator` process opens a local server and a real browser tab, then blocks until a human closes out the review. Do not wait on it and do not poll immediately after invoking — tell the user to check their browser, and only re-check once they report the review is done or is taking unexpectedly long.

```bash
herdr plugin action invoke annotate --plugin adrian.plannotator   # annotate the current workspace's markdown/text/html files
herdr plugin action invoke review --plugin adrian.plannotator     # review the current git diff/PR
```

Check the outcome afterward with:

```bash
herdr plugin log list --plugin adrian.plannotator
```

`status` is `running` while the browser review is open, `succeeded` or `failed` once `plannotator` exits. A `failed` log whose `stderr` says "No markdown, text, or HTML files found" or reports no diff just means there was nothing to review in that workspace — not a bug in the plugin.

## Safety and coordination rules

- Use `--no-focus` for background work unless the user asked to switch context.
- Use `--current` or an explicit ID. Do not rely on another client's focused pane.
- Parse IDs from JSON responses. Do not derive them from sidebar order or examples.
- Inspect before waiting. Read current output first, then wait for the next state or output you expect.
- Do not close workspaces, tabs, panes, or sessions you did not create unless the user explicitly asked.
- Never run `herdr server stop` from an active session unless the user explicitly intends to stop the server and its pane processes.
- Never kill the main Herdr process. Use named test sessions for experiments that need an isolated server.

## Notes for future updates

- **2026-08-07**: added the `binox-axi` step before task submission in "Start agents interactively", after a session where firstmate and its secondmates repeatedly briefed a crewmate with the wrong skill path (server copy vs. local clone vs. main-home copy) with no cheap way to check first. `binox-axi <path>` (AXI-standard, read-only, `subagent-factory/tools/binox-axi`) inventories a target's actual skills, orphaned `tmp/` scripts, tool scripts, and available AXI CLIs before the brief is written. Not yet globally installed as of this note — PR https://github.com/blazingbunny/subagent-factory/pull/4 was still awaiting merge when this was written; confirm `binox-axi` resolves on `PATH` before relying on it, and fall back to manual inspection if it isn't installed yet.
- **2026-07-31**: added remote-attach coverage (`herdr --remote <ssh-target>`, confirmed against `herdr --help`) after installing Herdr on `orca-ubuntu-vm` for Moshi phone access. Not previously documented anywhere in this skill. Battle-tested the same day: confirmed `--remote` cannot be run as a blocking Bash tool call (hangs with no server-side connection, same as other interactive Herdr/agentbox commands) — must be handed to the user's own terminal, never executed directly by an agent.
- **2026-07-31**: proved the agent-usable alternative to `--remote` end-to-end: plain socket-API commands (`herdr workspace create`, `herdr pane run`, `herdr pane read`) work fine over SSH against a remote host's own headless server, and once `herdr-mirror` mirrors a remote workspace locally, running commands against the *local mirrored pane ID* actually drives the real remote pane — verified by reading the real remote pane directly afterward. This is the answer whenever a task needs an agent (not a human) to control something on a remote Herdr host.
- **2026-07-28**: three fixes confirmed live against a real installed `herdr` binary (checked with `herdr --help`, not assumed from prior doc text): no top-level `herdr wait` command exists, real syntax is `herdr agent wait <target> --until <status> [--timeout MS]`; output waits are `herdr pane wait-output`, not `herdr wait output`; `pane run` does not reliably submit (Enter can fail to register, leaving a message sitting unsent in the input box) — always verify submission and fall back to an explicit `herdr pane send-keys <id> Enter` if it didn't. Also added: a long assistant message can hide behind the TUI's own internal scroll boundary, not scrollback — reading the pane's own Claude Code session JSONL directly (`~/.claude/projects/<escaped-cwd>/<session-id>.jsonl`) is the reliable fallback.
