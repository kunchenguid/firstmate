# Hermes Agent

Verified for crew, scout, secondmate, and primary work on 2026-09-26 with hermes-agent v0.21.5 (git installer, macOS), through a real pseudo-terminal: primary session start, plugin-owned watcher arm and wake delivery, and worker busy state were each exercised live.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `hermes`, resolved from `PATH` by `../../../bin/fm-spawn.sh`; the git installer's `~/.local/bin/hermes` is a shell wrapper that execs the bundled interpreter, so the live process is a bare Python interpreter (see Detection). |
| Launch | Foreign markers and Hermes's own inherited identity cleared (`HERMES_AGENT`, `HERMES_SESSION_ID`, `AI_AGENT`, plus the Claude, Pi, Grok, Gemini, Cursor, Rovo, and omp markers), the plugin wiring as environment, then `hermes chat --cli --yolo [--model <provider/model>] [--reasoning <level>] -q <encoded launch brief>`. |
| Brief | `chat -q` on a real TTY seeds an interactive session and submits the brief literally as its first turn; the typed U+2063 operational marker survives submission (verified in the session store), so no record-backed carrier is needed. A literal first turn is also why a `/skill` cannot ride `-q`. |
| Surface | `--cli` pins the classic prompt_toolkit REPL, because the captain's `display.interface` may select the Ink TUI, whose composer, keys, and `--reasoning` passthrough differ. Every worker fact here is classic CLI. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `hermes-plugin`, written by the Firstmate plugin in worker role: `pre_llm_call` opens, `on_session_end` (end of every turn, interrupted included) and `agent_loop_stopped` close, `post_tool_call` refreshes progress. |
| Turn end | The same plugin touches `state/<id>.turn-ended` at every `on_session_end`. |
| Exit command | `/quit` (`/exit` is an alias). The slash popup consumes the first Enter, and the shared submit retry sends the second; Hermes then prints `hermes --resume <session-id>`. |
| Interrupt | Single `Ctrl+C` interrupts a running turn and leaves the agent alive with its placeholder restored. A second press within two seconds force-exits, and an idle `Ctrl+C` on an empty composer exits, so `../../../bin/fm-control.sh` presses only while the busy record proves a running turn (`fm_control_interrupt_exits_idle`). No Escape interrupt exists. |
| Skill invocation | `/<skill>` typed into the composer, for any skill Hermes has loaded; a worker's project skills load only for a root listed in `skills.trusted_project_dirs`, so name the skill file in natural language when the slash form is uncertain. |
| Model flag | `--model <provider>/<id>`; an explicit model above Hermes's price or data-policy guard stops on a `[y/N]` confirmation that `--yolo` deliberately does not cover (see Launch prompts). |
| Effort flag | `--reasoning <none\|minimal\|low\|medium\|high\|xhigh\|max\|ultra>`, a superset of the shared vocabulary, so `low` through `max` map straight across. |
| Autonomy | `--yolo` (`HERMES_YOLO_MODE=1`) skips command approval for the session. |
| Trust | No workspace-trust dialog. |
| Marker | `HERMES_AGENT=true` on the Hermes process and every tool subprocess (verified live). There is no `HERMES_CLI` marker, and `AI_AGENT` is only defaulted, so an inherited launcher value survives in it. |
| Resume | `hermes --resume <session-id>` or `-c` for the latest in this workspace; no verified pane-resume contract, so recovery uses deterministic relaunch. |
| Composer | A bare `❯` row between two horizontal rules. Idle shows one of eleven rotating example prompts in dim truecolor (#545e6b), listed in `../../../bin/fm-composer-lib.sh`; a running turn replaces it with `☤ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel`, the delivery busy signature. |

## Detection

`../../../bin/fm-harness.sh` tests `HERMES_AGENT=true` before `CLAUDECODE`, because Hermes does not clear an inherited `CLAUDECODE` (verified: a tool subprocess of a Hermes session started from a Claude pane carried both).
Ancestry cannot use a command name: the live process is `python3 -I -c '<bootstrap>'` for the git installer, an interpreter running a console script named `hermes` for pip and uv, and, under the Ink TUI, a `python -m tui_gateway.entry` child of the node renderer that runs the agent, its tools, and the plugin, so that gateway is the session-lock owner there.
`../../../bin/fm-hermes-lib.sh` owns the structural rule, the inline bootstrap's `hermes_cli.main import main` or a script whose basename is exactly `hermes`, and it is shared by detection, the session lock, and liveness.
Never widen it to a `*hermes*` substring: this repository is often cloned under a hermes-named directory, which would make every Firstmate helper read as a live Hermes harness.
A Hermes brief rides argv, so the Hermes rule runs before the generic interpreter globs; a brief mentioning claude never renames a Hermes worker or extends a Claude lock chain.
Every non-Hermes launch clears `HERMES_AGENT`, and a structural ancestor of another harness still outranks a leaked marker.

## Plugin install

Hermes loads only plugins that are both discovered and listed in `plugins.enabled`.
A worker runs in a project worktree, where the project owns `.hermes/`, so the Firstmate loader must live in the Hermes home: `../../../bin/fm-hermes-plugin.sh install` copies the tracked loader from `.hermes/plugins/firstmate/`, registers the home's root, runs `hermes plugins enable firstmate`, and grants `plugins.entries.firstmate.allow_gateway_injection` for the Ink TUI.
The loader carries no behaviour; it imports the resolved checkout's tracked `.hermes/firstmate/plugin.py`, so `/updatefirstmate` updates behaviour and only a changed loader reads `stale`.
Installing writes the captain's Hermes home, so bootstrap only detects it (`MISSING: hermes-plugin`) and `../../../bin/fm-spawn.sh` refuses a Hermes launch unless `status` is `ok` or `unregistered`; never install on the captain's behalf without their word.
The loader resolves its root from its own project location, then `FM_HERMES_ROOT`, then an exact match of the working directory against its `roots` file; it never infers a root from a directory name and is inert everywhere else.

## Launch prompts

Hermes has two startup `[y/N]` prompts, and `fm_busy_hermes_launch_prompt_tail` in `../../../bin/fm-busy-lib.sh` reports either as a parked launch.
The paid-model confirmation (`Use this model for this invocation? [y/N]`) guards spend and stays a captain decision: Firstmate never answers it, and the fix is choosing a cheaper model or the captain confirming it once in person.
The shell-hook consent (`Allow this hook to run? [y/N]`) appears only for an unapproved hook in the captain's own `config.yaml`; the captain answers it once or sets `hooks_auto_accept`, and Firstmate never passes `--accept-hooks` for them.

## Primary integration

The primary is plugin-owned end to end through `../../../docs/supervision-protocols/hermes.md`, and `fm_supervision_model` classifies Hermes as `extension`.
Session start is Run tier: the plugin starts `../../../bin/fm-sessionstart-run.sh` when it loads, which is process start, and the first `pre_llm_call` returns the digest as context; `/new` re-emits as `clear`, a history that lost the digest re-emits as `compact`, and a launch with `--resume`/`-c` routes as `resume`.
`../../../docs/sessionstart-nudge.md` owns the bounded wait and the idle delivery of a digest that outlives it.
The watcher is the plugin's child (`fm_hermes_watch.py`, a port of the omp watch extension), and wakes are injected only while the session is idle, because a classic-CLI injection during a running turn would interrupt it.
The turn-end guard is passive at `on_session_end` with one bounded follow-up, plus an in-turn `pre_verify` continuation on edit turns; `../../../docs/turnend-guard.md` owns the contract.
`pre_tool_call` forwards terminal commands to the cd and watcher-arm checkers and every tool name to the delegation checker; Hermes's `delegate_task` and `cronjob_manage` tools are delegation-shaped and denied in a primary home (hermes-agent v0.21.5 tool schemas).
`fm_hermes_extension_owns_supervision` in `../../../bin/fm-wake-lib.sh` binds the two plugin markers to `state/.lock`, whose pid is the Hermes process itself.
In a home with `config/supervision-host` the plugin runs the supervision host in the arm's place ([`supervision-host.md`](../../../../../docs/supervision-host.md)).
Without the supervision host, away mode runs the daemon (`bin/fm-afk-launch.sh start`) and the plugin stands its own watcher down while `state/.afk` exists.
Launch a primary with `hermes` (or `hermes --cli`) inside the home after `bin/fm-hermes-plugin.sh install`; `HERMES_ENABLE_PROJECT_PLUGINS=1 hermes` also works without the Hermes-home loader, once `firstmate` is enabled.
`../../../bin/fm-session-start.sh` prints `HERMES_PLUGIN: not loaded` when a Hermes primary reached session start without the plugin.
A primary may run the classic CLI or the Ink TUI; both were verified live, the TUI with the injection grant `install` sets.
The Firstmate captain skills are registered as plugin slash commands (`/afk`, `/ahoy`, `/bearings`, `/quiet`, `/stow`, `/updatefirstmate`) that queue a plain invocation turn; `hermes skills trust` on the home makes every `.agents/skills` skill native instead.
A Hermes process killed with SIGKILL can orphan its arm child; the next owning session's `--restart` retires it.

## Worker wiring

A crewmate or scout launches with `FM_HERMES_ROLE=worker FM_HERMES_ROOT=<primary code root> FM_HERMES_STATE FM_HERMES_TASK FM_HERMES_BUSY_GEN FM_HERMES_TURNEND`, and a secondmate with `FM_HERMES_ROOT=<its home>` in primary role.
There is no per-task file, so relaunch and teardown clear nothing Hermes-specific; the busy incarnation is retired by the generic owner.
`../../../tests/fm-hermes-harness.test.sh` and `../../../tests/fm-hermes-plugin.test.sh` are the portable regressions; `../../../docs/verification/hermes.md` records the live evidence.
