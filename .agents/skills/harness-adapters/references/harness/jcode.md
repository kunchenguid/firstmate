# jcode

Facts verified 2026-09-09 on jcode v0.84.0 (57d587899), Linux x86_64, WSL2 Ubuntu.

jcode is a Rust harness with a client/server split: a persistent `jcode ... serve`
daemon plus a thin per-session TUI client. Measured idle on the verification
machine: 63 MB RSS per session over a 128 MB shared daemon, against 193 MB for
claude and 115 MB for pi under identical conditions.

## Operating facts

| Fact | Value |
|---|---|
| Busy | `jcode-debug`, written by `bin/fm-jcode-busy-bridge.sh`. jcode exposes no lifecycle hook or extension of the kind `claude-hook`/`pi-ext` use, but its daemon publishes per-session turn state: `jcode debug sessions` returns `working_dir`, `is_processing`, and `status`. Firstmate gives every crewmate its own worktree, so `working_dir` is the task<->session key. Verified across a real turn: `ready -> running -> ready` with `is_processing` tracking it exactly, so the boundary is READ, never inferred. The bridge polls (1s default) and publishes only on transition. `bin/fm-busy-event.sh` remains the sole writer. |
| Exit | `/quit`. `/exit` does not exist; the palette returns no match for it. |
| Interrupt | `Ctrl+C` (or `Ctrl+D`). **NOT Escape** - Escape only closes overlays. Every other verified adapter interrupts with Escape, so the shared default is wrong for jcode. |
| Interrupt hazard | jcode's own hotkey listing reads `Ctrl+C, Ctrl+D -> interrupt (or quit when idle)`. A C-c delivered to an IDLE jcode ENDS THE SESSION. The control plane must never interrupt a jcode task that is not positively classified busy, which is why the busy source above is a PREREQUISITE of registration rather than a nicety. A task at `unknown` must be left alone. |
| Skill | `/skills` lists loaded skills. Invocation form beyond normal command behaviour is unverified; prefer natural language. |
| Model | `-m, --model <MODEL>` at launch (`claude-opus-4-6`, `gpt-5.5`); in-session `/model [name]`; `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle. |
| Effort | `/effort <none\|minimal\|low\|medium\|high\|xhigh\|max>` **as a slash command only** - there is no launch flag. `bin/fm-jcode-seed.sh` submits it as its own line before the brief, so a dispatch profile's effort axis is still honoured. jcode also exposes swarm and swarm-deep levels, which are deliberately NOT offered - see Firstmate owns dispatch. |
| Brief | NOT deliverable on the command line: a positional parses as a SUBCOMMAND (`error: unrecognized subcommand`) and there is no `--prompt`. `jcode run <MSG>` is headless single-shot and exits. The brief is typed as a one-line pointer by `bin/fm-jcode-seed.sh`, the same shape kimi and rovo already use in `bin/fm-spawn.sh`. |
| Resume | `--resume [<ID>]` resumes by session id, or lists sessions when the id is omitted. Unlike claude/pi/omp/kimi a pane-resume contract plausibly EXISTS, but it is unverified end-to-end and nothing relies on it. |
| Scripting | `--quiet` suppresses non-error output. `jcode run` executes a single message and exits. |
| Provider | `-p/--provider claude` selects Anthropic OAuth. `jcode usage` reports live plan windows. |

## Billing

Verified against a Claude Max account: `jcode usage` reported rolling `5-hour
window` and `7-day window` plan meters with `Extra usage (long context):
disabled`. jcode draws on the Claude SUBSCRIPTION rather than per-token extra
usage, and `jcode auth import` adopts an existing Claude Code OAuth login.

This is why `bin/fm-quota-choose.sh` maps jcode onto the **claude** quota family:
a jcode crewmate spends the same windows a claude crewmate does, so accounting
them separately would silently double-spend the plan. The launch command pins
`--provider claude` for the same reason - change one and the other must change
with it.

## Registration

Registered as a crewmate/scout adapter and verified as a primary
(`docs/supervision-protocols/jcode.md`). `fm_control_harness_supports_kind`
refuses a `--secondmate` launch, matching muse/gemini/rovo: the secondmate role
has not been verified. `bin/fm-spawn.sh` refuses it again at launch so the
refusal cannot be bypassed by a raw harness argument.

| Site | Value |
|---|---|
| `fm-control-lib.sh` supported / family | `jcode` |
| interrupt key / repeat / clear | `C-c` / `1` / none |
| interrupt ack source | `none` (see below) |
| exit command | `/quit` |
| per-task wiring | `state/<id>.jcode-bridge.pid` |
| `fm-busy-lib.sh` source | `jcode-debug` |
| `fm-composer-lib.sh` delivery guard | `FM_DELIVERY_JCODE_BUSY_REGEX_DEFAULT` |
| `fm-composer-lib.sh` composer shape | `fm_composer_jcode_normalize_screen` (see Composer) |
| `fm-quota-choose.sh` family | `claude` |
| `fm-harness.sh` detection | anchored `jcode` |
| `fm-bootstrap.sh` effort set | `none minimal low medium high xhigh max` (swarm levels excluded) |
| `fm-teardown.sh` | `stop_jcode_bridge` (main and child paths) |
| tests | `tests/fm-jcode-harness.test.sh` |

## Per-task wiring is a PROCESS

Every other adapter's wiring is a file the harness reads (a hook settings file,
an extension, a plugin). jcode's is a background process, so two rules follow
that do not apply elsewhere:

- `bin/fm-teardown.sh` must STOP it (`stop_jcode_bridge`), or an orphaned bridge
  keeps polling forever and could publish against a task id a later spawn reuses.
  It is stopped BEFORE `retire_busy_state` so it cannot write back after
  retirement, and it only ever signals a pid whose `args` still name the bridge,
  so a recycled pid belonging to something else is never killed. A
  `fm-spawn.sh --relaunch` stops the superseded bridge the same way
  (`fm_control_stop_jcode_bridge`) before arming a new one, and a bridge removes
  the pidfile on exit only while it still names its own pid, so a late-exiting
  predecessor cannot delete its replacement's pidfile.
- The bridge seeds its in-memory `last` from the record it already owns (gen
  matched), so a restart after a crash or daemon reload does not republish a
  state that is already recorded.

## Composer

jcode numbers its composer prompt (`1>` empty, `1> typed`, `1<>` submitted) and
draws furniture at the row's far right: a context meter and a private-use-area
status glyph, both present on an empty composer and unchanged by typing.

Firstmate's leading-glyph resolvers cannot anchor on that shape, so a jcode
composer classified `unknown` in every state until 2026-09-23. That is NOT
merely untidy: `bin/fm-control.sh` refuses to type an exit command unless the
composer is proven empty, and `fm-spawn.sh --relaunch` then refuses because the
endpoint still reads alive, so a stalled jcode worker could not be stopped
through the guarded path at all. Two were recoverable only by terminating the
agent processes directly.

The row is therefore normalized before classification - furniture tail first,
then the turn index rewritten to the shared agent prompt glyph - and ONLY for a
pane whose foreground process is structurally identified as jcode, mirroring
the Cursor process-identity gate. The shared resolvers are untouched, so no
other harness's dead-shell rule is weakened; an earlier attempt that made them
strip a turn index generally is what regressed
`tests/fm-control-relaunch.test.sh`, and that remains the wrong fix.

The leading DIGITS are what make this safe. A dead shell prompt is `>`, `$`,
`%`, or `#` alone and is never `1>`, so a numbered prompt is positive proof of
jcode's composer, while a bare prompt on a jcode pane still reads `unknown` and
still refuses the lifecycle action - which is correct, because that is what an
exited agent leaves behind.

Delivery is unaffected and still does not depend on this: `bin/fm-jcode-seed.sh`
proves a brief landed from the daemon's own `is_processing`, which is stronger
evidence than any composer read.

See `docs/verification/runtime-backends.md` ("2026-09-23 jcode ... numbered
composer prompt") for the live evidence and the refresh command.

## Firstmate owns dispatch

jcode ships autonomy that firstmate cannot see. Left on, a crewmate can start
work with no task record, no worktree, and no supervision - agents firstmate
cannot steer, interrupt, or tear down, and which no `fm-teardown` will ever
reach.

| Surface | What it does | Required value |
|---|---|---|
| `swarm` tool | "Coordinate agents: spawn workers with a prompt, message them, and manage swarm plans" | denied in `[tools] disabled` |
| `[features] swarm` | master switch; `[agents] swarm_max_concurrent_agents` defaults to **32** | `false` |
| `schedule` tool | "Schedule, list, or cancel future tasks" - queues runs after the turn ends | denied |
| `initiative` tool | "Manage durable initiatives" - durable self-directed work | denied |
| `[ambient] enabled` | unattended turns on a timer, committing to `ambient/` branches | `false` |
| `/effort swarm`, `/effort swarm-deep` | put the agent straight into swarm mode | not offered |

`bin/fm-jcode-preflight.sh` REFUSES a spawn unless all of the above hold, and
`bin/fm-spawn.sh` runs it in two halves. The static checks (onboarding, provider,
`debug_socket`, and every row above) run with `--static` BEFORE the pane
launches, so a bad home never reaches a pane. The live `jcode debug sessions`
probe runs AFTER the launch, with its bounded `FM_JCODE_DEBUG_WAIT` retry,
because only a launched client starts the daemon: `jcode debug` against a
machine with no running server fails and starts nothing. Moving the live probe
before the launch was tried and reverted - it refused the first jcode spawn
after every reboot. The refusal is deliberate: silently rewriting a captain's
jcode config would change their own interactive sessions too, so the adapter
reports what is wrong and stops.

The effort axis is enforced twice. `bin/fm-bootstrap.sh` does not offer `swarm`
or `swarm-deep` as dispatch-profile levels, and `bin/fm-jcode-seed.sh` refuses
them again at delivery, because a profile edited by hand would otherwise reach
the composer as a `/effort swarm` line.

`bg` is deliberately LEFT ENABLED. It manages background work inside a turn
(builds, test runs) rather than spawning agents, and denying it would break
ordinary tooling. Note the consequence: a bg task can outlive the turn that
started it, so `is_processing` going false means the TURN ended, not that every
background command has finished - the same property claude's background bash has.

## Token burn

Verified on the same machine. Most of the burn-relevant settings were already
correct; only MCP exposure was changed.

| Setting | Value | Effect |
|---|---|---|
| `memory_embedding_backend` | `local` | retrieval by cosine similarity against a local graph |
| `memory_sidecar_enabled` | `true` | hits are INJECTED, so the agent never spends turns calling memory tools |
| `persist_memory_injections` | `false` | injections do not accumulate in context |
| `agentgrep` tool | enabled | returns structure and offsets with matches, so whole files are not read |
| `show_agentgrep_output` | `false` | its output is not re-rendered into context |
| `kv_cache_miss_notices` | `true` | warns when Anthropic's prompt cache goes cold (~5 min idle) |
| `mcp_tools` | `deferred` (was `auto`) | MCP tool schemas are never sent eagerly, rather than only above 8000 tokens |

The local embedding model is about **87 MB** of artifacts, loaded on demand.
That is a real RAM cost against the token saving, which matters on a 16 GB host
running several crewmates: it is roughly one and a half extra jcode sessions.

Two things are NOT configurable here and should not be claimed as tuned: skills
load on semantic hit by jcode's own default with no config key, and the
cache-cold behaviour is a notice, not a setting. The way to stop paying for cold
caches is behavioural - do not idle mid-task and resume.

## First-run gates

A fresh jcode home shows an onboarding wizard, and a fresh working directory
shows a `How would you like to begin?` chooser. Both put their options on a
horizontal row and need ARROW navigation, which Firstmate's key plane (Enter,
Escape, C-c only) cannot supply - the same class of blocker as Claude's
workspace-trust dialog.

Unlike Claude's, jcode's gates are per-HOME, not per-worktree, so there is
nothing to pre-register per task: once a human has completed onboarding once, no
fresh worktree reopens it. `bin/fm-jcode-preflight.sh` therefore CHECKS rather
than fixes, and refuses the spawn when onboarding is incomplete, no provider is
connected, or debug control is off. Its one repair (`--fix`) is setting
`display.debug_socket`, which is documented and reversible.

Never try to answer either gate with a key.

## Known gaps

- The bridge POLLS; no streaming subscription was found on this surface.
  `--debug-socket` advertises that it broadcasts TUI state changes and
  `servers.json` records a `debug_socket` path per server, so a push-based v2 is
  plausible but unverified.
- It reads the DEBUG surface, which requires debug control on the DAEMON.
  `jcode api-bridge` is the documented-stable API (the socket
  `@1jehuang/jcode-sdk` speaks to) and would be the more durable long-term
  source; its event schema is not in `--help` and was not read here.
- `fm_control_interrupt_ack_source` is `none`. jcode COULD confirm a
  cancellation - `is_processing` going false after the key is a recorded state
  change, not a rendered string - which would make it the first adapter with a
  real ack. Left unclaimed until that transition is verified for INTERRUPTS
  specifically rather than for normal turn ends.
- `jcode debug -S <id> cancel` is a programmatic, session-targeted interrupt that
  would remove the C-c-quits-when-idle hazard entirely, but
  `fm_control_interrupt_key` returns a KEY for the backend to send; using a
  command instead means extending that interface.
- `--resume` is unverified end-to-end (see Operating facts).
