# Google Antigravity CLI adapter verification

Date: 2026-09-04.

Verified executable: `/Users/cam/.local/bin/agy` at Antigravity CLI 1.1.26.

Every Herdr lifecycle experiment ran in the disposable session produced by `bin/fm-herdr-lab.sh name antigravity-adapter`.
The helper provisioned, addressed, and removed that named non-default session, and its teardown tripwire confirmed the existing default fleet session was unchanged.
No direct Herdr lifecycle command was used.
Every Antigravity model invocation selected a Gemini model explicitly; no Claude-family model was selected.

## First working milestone

The canonical worker launch is:

```sh
agy \
  --dangerously-skip-permissions \
  --add-dir <exact-isolated-project> \
  --add-dir <firstmate-owned-hook-overlay> \
  --model <gemini-model-id> \
  --effort <low|medium|high> \
  --prompt-interactive "<launch instructions>"
```

A live Gemini turn reported the selected Gemini model and requested effort in the TUI.
A terminal tool then operated in the exact directory supplied by `--add-dir`, read that copy's `AGENTS.md`, and discovered a sentinel skill under `.agents/skills/`.
Without `--add-dir`, Antigravity's terminal workspace was `~/.gemini/antigravity-cli` even though the launching shell was in the project.
This disproved the tempting assumption that inherited shell cwd was sufficient.

`--dangerously-skip-permissions` allowed unattended terminal execution and a sentinel write without a permission prompt.
The smallest counterfactual used the same kind of headless command with `--mode accept-edits` and without the dangerous flag.
Antigravity automatically denied command execution in that case, proving that accept-edits alone does not solve the captain's repeated command approvals.
The 1.1.26 changelog also records the vendor fix for repeated subagent approvals in always-proceed mode.
`fm-spawn.sh` therefore enforces that version floor and names `agy update` when an older executable is found.
It also refuses non-Gemini ids and selects a live `gemini-*` catalog entry when no model is pinned, so Antigravity cannot silently fall onto another provider family.

## Recognition and process evidence

A tool process launched by Antigravity carried `ANTIGRAVITY_AGENT=1`.
It also retained `AI_AGENT=pi` from the Pi primary that launched the experiment.
`AI_AGENT` is therefore inherited launcher data, not Antigravity identity.
Before the adapter, `bin/fm-harness.sh` returned `unknown` for the real Antigravity path.
The adapter now gives Antigravity's own marker precedence and recognizes only exact `agy` ancestry.

Herdr's native `agent get` identified the foreground process as `agent=agy` and exposed working/idle status.
The idle TUI drew one `>` prompt row between two solid separator rows.
While generating, the stable ASCII footer included `esc to cancel`.
The shared composer classifier now accepts `>` as an agent prompt only inside that separator pair and only with live Antigravity identity; a bare shell prompt remains unknown.

## Instructions, skills, and hook isolation

Antigravity 1.1.26 discovers `AGENTS.md`, `.agents/skills/`, and `.agents/hooks.json` from roots supplied with `--add-dir`.
Hook discovery worked with the project and hook overlay in either argument order.
The built-in Antigravity hook reference confirms that hook commands run from the directory containing `hooks.json`, receive camelCase JSON on stdin, and return event-specific JSON on stdout.

The tracked root `.agents/hooks.json` uses the native schema for startup and primary safety hooks.
Worker lifecycle hooks are generated in `state/<id>.antigravity-hooks/.agents/hooks.json`, supplied as a second added root, and never overwrite the project's own hook file.
`PreInvocation` opens semantic task activity.
`Stop` settles that activity, publishes the turn-end notification, and returns a non-continue decision so the completed turn may stop.

Antigravity's `PreToolUse` payload carries `.toolCall.name` and `.toolCall.args.CommandLine`.
Its native hard-block response is `{"decision":"deny","reason":"..."}`.
A live Gemini delegation probe exposed Antigravity 1.1.26's exact built-in tool names `invoke_subagent` and `send_message`; both match the existing delegation-shape policy.
Portable executable tests drive that native transport through the watcher-arm, persistent-directory-change, and exact `invoke_subagent` guard paths and require a real deny object rather than only a successful exit.
A separate live primary-shaped Gemini probe required `invoke_subagent`, observed Antigravity surface the native deny with Firstmate's exact `blocked tool: invoke_subagent` reason, and confirmed no subagent ran.

## Lifecycle and supervision

A single Escape cancelled a live Gemini turn and left the interactive Antigravity session open.
Typing `/quit` and one Enter exited the TUI.
Those mechanics are registered in `bin/fm-control-lib.sh`, so interrupt, exit, and transactional relaunch use the ordinary Firstmate control plane.

Antigravity hooks are synchronous.
No documented or live-verified interface lets a detached background process wake the model later.
Primary and second-mate sessions therefore use the explicit foreground `bin/fm-watch.sh` terminal-tool protocol in `docs/supervision-protocols/antigravity.md` rather than borrowing another harness's extension, plugin, or background-task mechanics.
Headless print mode is intentionally unsupported as a primary host because it does not preserve a conversation for later fleet notifications.

## Regressions and live guard

`tests/fm-antigravity-harness.test.sh` is the portable executable-interface suite.
It covers marker precedence and negative ancestry, process/lifecycle tables, busy matching, the identity-gated composer shape, task hook state transitions, native PreToolUse denies, and the exact generated launch command plus isolated hook schema.

`tests/fm-antigravity-live-e2e.test.sh` is the opt-in real CLI guard.
Run it only with:

```sh
FM_TEST_ANTIGRAVITY_LIVE=1 \
FM_TEST_ANTIGRAVITY_MODEL=<gemini-model-id> \
tests/fm-antigravity-live-e2e.test.sh
```

The guard refuses a non-Gemini model, an old CLI, unavailable Herdr isolation, a missing instruction/skill sentinel, a missing autonomous terminal result, a missing hook result, a wrong project path, or a missing model/effort display.
It cannot pass merely because `agy` started.

## Antigravity CLI 1.1.27 and primary watch investigation

Date: 2026-09-05.
Verified executable: `/Users/cam/.local/bin/agy` at Antigravity CLI 1.1.27.

### Observed symptom and initiating trigger

When launching Antigravity via a shortcut that runs `agy --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions` without `--add-dir`, the agent interacts normally in conversation but does not actively monitor the fleet.
The session idles after every turn, and background fleet events in `state/.wake-queue` are not processed until the captain manually sends another prompt.

### Masking condition and root cause

Antigravity CLI does not automatically adopt the launching shell's current working directory as its workspace root.
Without `--add-dir "$PWD"` (or the explicit Firstmate home path), Antigravity defaults its workspace root to `~/.gemini/antigravity-cli`.
In this default workspace, Antigravity never discovers the Firstmate home's `AGENTS.md`, `.agents/skills/`, or `.agents/hooks.json`.
Antigravity logs in `~/.gemini/antigravity-cli/log/` confirm: `hooks_manager.go:53 loaded 0 named hooks from 0 hooks.json file(s)`.
Because Antigravity successfully connects to the Gemini model and executes tools unattended under `--dangerously-skip-permissions`, the session appears completely healthy and conversational.
This masks the fact that Firstmate hooks were never loaded.

### Primary supervision failure mode

Because `.agents/hooks.json` is not discovered, the `firstmate-sessionstart` `PreInvocation` hook (`bin/fm-antigravity-hook.sh sessionstart`) never fires.
The session-start nudge is never injected into the conversation.
`bin/fm-session-start.sh` is never executed, the session lock is never acquired, and the agent is never directed to start foreground supervision via `bin/fm-watch.sh`.
Unlike Pi (which has a background extension runtime) or Claude (which has an asynchronous Stop hook), Antigravity primary supervision relies on foreground terminal calls to `bin/fm-watch.sh`.
Without `--add-dir`, foreground supervision never starts, leaving background fleet wakes unmonitored.

### Counterfactual verification

When launched with `--add-dir "$PWD"`, Antigravity CLI logs confirm discovery: `loaded 3 named hooks from 1 hooks.json file(s)`.
The `firstmate-sessionstart` `PreInvocation` hook fires on the opening turn, delivering the operational session-start nudge.
The agent then runs `bin/fm-session-start.sh`, takes the session lock, and starts foreground supervision via `bin/fm-watch.sh`, actively monitoring fleet events.
