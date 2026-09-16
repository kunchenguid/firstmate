# DeepSeek Harness

Verified on 2026-09-16 with DeepSeek Harness 0.1.5-rc.1 (dsh-base 0.1.5-rc.2).

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Not applicable to the primary: DSH drives its own turn lifecycle, and the captain reads crewmate state from that crewmate's harness. No crewmate adapter exists yet, so nothing is armed as busy wiring. |
| Exit command | None verified: the session is a long-lived host process (`node .../.bin/dsh web`) closed from the DSH client, not by a typed slash command. |
| Interrupt | The client's own stop control; no verified key sequence, because there is no terminal to send keys to. |
| Skill invocation | Skills reach the model through the session skill catalog (`dsh-skill-filesystem` scans `.agents/skills` natively), loaded by the model rather than typed as a slash prefix. |
| Model flag | None on the command line. The session model comes from the `agent-default-model` settings section (`$DSH_HOME/settings.yaml`), overridden per session through the model picker. |
| Effort flag | None on the command line. `reasoningEffort` in the same settings section carries the effort axis. |
| Model discovery | The model picker, backed by the `llm-pi-ai` route catalog when that adapter is mounted. |
| Marker | None. DSH is a node process (`ps` reports `comm=node`) whose launcher name is visible only in argv, and it hands tool and hook subprocesses no identity variable. `FM_DSH_HARNESS=dsh` is a Firstmate-OWNED launch marker, honored only when a genuine dsh process is in the ancestry, and evaluated ahead of the inherited-marker arms. That ordering is what keeps identity correct: the dsh ancestry verdict is only `args` strength, so a DSH host launched from a Claude pane retains `CLAUDECODE`, which would otherwise rename the session. The marker is therefore load-bearing rather than a fast path, and it is never evidence on its own. |

## Role: primary only

DSH is a verified PRIMARY adapter and is deliberately absent from every crewmate/scout enumeration - the launch table in `../../../bin/fm-spawn.sh`, `fm_control_kind_supported` in `../../../bin/fm-control-lib.sh`, the busy-state sources in `../../../bin/fm-busy-lib.sh`, and the spawn enumerations in [`docs/architecture.md`](../../../../../docs/architecture.md) and [`docs/trace-context.md`](../../../../../docs/trace-context.md).
It exposes no endpoint, interrupt, exit or per-task busy-state control plane, so a dispatched worker could not be steered, inspected or stopped.
`refuse_dsh_crewmate` in `bin/fm-spawn.sh` enforces that on every resolution path, and the refusal is an exact harness-name match, so a raw launch command that merely mentions dsh is not caught by it.

## Sandbox requirement

Firstmate's supervision health model is built on process inspection: `bin/fm-harness.sh` ancestry, the PID-strict watcher lock in `bin/fm-wake-lib.sh`, and `fm_afk_daemon_owns_supervision`.
DSH denies `ps` under its default `workspace-write` sandbox (`/bin/ps: Operation not permitted`), which silently degrades every one of those predicates.
The captain profile therefore selects the shipped `danger-full-access` permission preset, which bundles that sandbox mode with its approval policy.
Overriding `sandbox-policy.mode` alone is NOT equivalent: the composed sandbox and approval defaults then match no preset, and `dsh-permission-presets` refuses the profile at load with "configure defaultPreset explicitly".

## Instruction budget

`dsh-agent-instructions` budgets the whole rendered instruction chain with `maxBytes`, which `dsh-base` ships as 65536.
It discovers both `AGENTS.md` and `CLAUDE.md` at the workspace root, and firstmate tracks `CLAUDE.md` only as an `@AGENTS.md` pointer, which the renderer does not expand.
When the rendered chain is over budget, DSH does not cut bytes: it omits the broadest file whole, which here is `AGENTS.md`, so the agent receives only the `CLAUDE.md` pointer and a model-visible marker (`Workspace instruction budget 65536 bytes: omitted AGENTS.md`), and the operator sees nothing.
The captain profile raises `maxBytes` to 262144, which delivers `AGENTS.md` whole.
`bin/fm-dsh-preflight.sh` reads the effective value from `dsh --profile <name> --dump-config` at every launch, so DSH's own layer composition decides it, and compares that with the live size of `AGENTS.md`. That is `AGENTS.md` alone, a few hundred bytes smaller than the rendered chain DSH budgets, so the two are not equivalent near the boundary; the 262144 raise is far from it.

## Launch boundary

DeepSeek Harness publishes no identity marker of its own, so the values that identify a DSH primary
exist only at process start — a tool call cannot set them and hook subprocesses inherit whatever the
host was given. `bin/fm-dsh-launch.sh` is that boundary: it exports `FM_DSH_HARNESS=dsh` and an
explicit `FM_HOME`, pins `LC_ALL`/`LC_CTYPE` (unset, `bin/fm-line-cap-lib.sh`'s character cap becomes
a byte cap and slices UTF-8), and clears the foreign harness markers so a session started from
another harness's pane cannot inherit its identity.

Launch the primary through it: `bin/fm-dsh-launch.sh web --port 3080`. Documentation alone is not a
launch boundary; a marker that nothing sets leaves the home identified as whatever marker leaked in.

It runs `bin/fm-dsh-preflight.sh` before exec'ing dsh, because three DSH misconfigurations are silent
and total: a hooks bridge whose version differs from the running dsh-base (every tool call then fails
with `agent.session.events is not iterable` while the guards go inert), an `agent-instructions`
`maxBytes` below the size of `AGENTS.md` (DSH then omits it whole; see Instruction budget), and a sandbox that
denies `ps` (harness ancestry, the PID-strict watcher lock and away-mode ownership read "unknown" or
"down" rather than reporting a misconfiguration). Each check names its own remedy;
`FM_DSH_SKIP_PREFLIGHT=1` is the escape hatch for a deliberately degraded home.

## Primary integration

`dsh-hooks-claude-code` runs firstmate's hook scripts unchanged, because DeepSeek Harness implements the Claude Code command-hook dialect. The registration lives in `.dsh/hooks.json`, mounted by `.dsh/profile.patch.yml`, and three facts about DSH change what that file may contain:

- **`UserPromptSubmit`, not `SessionStart`.** DSH's `SessionStart` hook runs detached and its `additionalContext` lands AFTER the first request as a user-shaped message (verified 2026-09-16), which is the wrong tier for a session-start digest. `UserPromptSubmit` fires before the model call and its `additionalContext` is part of that request, so `bin/fm-dsh-sessionstart.sh` rides it and gates delivery once per session id.
- **Lowercase `bash` matchers.** DSH's matcher subject is the harness tool name, and its shell tool is `bash`; Claude's `Bash` never matches. The catch-all `.*` group is unaffected.
- **The digest is `bin/fm-session-start.sh`'s stdout, delivered whole.** That script owns the read-only
  and STARTUP TRUNCATED banners, the read-once contract, fleet state and the single emitted operating
  block. An adapter that renders the operating block separately, or discards the run's output, hands
  the agent operating instructions without the diagnosis that governs them. The once-per-session
  gate is recorded only after a digest was produced, so a refused or empty startup retries on the
  next prompt instead of being swallowed for the session.
- **No `asyncRewake`.** DSH parses command hooks only and runs them synchronously with the configured timeout, so firstmate's Stop-owned auto-arm has no equivalent. `bin/fm-turnend-guard-dsh.sh` calls the shared guard with `--dsh`, which owns a session-scoped block budget instead of trusting `stop_hook_active`, and watcher continuity rides a background job per `docs/supervision-protocols/dsh.md`.

**PreToolUse works, but the bridge version must match the runtime.** The sub-packages' npm `latest` dist-tag is stale (`0.0.1-rc.5` against a `0.1.5-rc.2` runtime), and that old bridge reads `session.events` synchronously - a read DSH deprecated after rc.5. Under the mismatch the bridge's `lastTurn()` throws before any hook is matched and EVERY tool call fails with `Error: agent.session.events is not iterable`, so the guards are both inert and tool-breaking. Install the matching build explicitly:

```sh
dsh plugin --profile <name> add @deepseek-ai/dsh-hooks-claude-code@0.1.5-rc.2
```

With the matched build, `UserPromptSubmit`, the `bash`-matcher PreToolUse rows, and the `.*` row all fire (verified 2026-09-16), and a **deny genuinely blocks**: exit 2 with the reason on stderr produced an `isError` tool result, left the command's sentinel file uncreated, and reached the model as a refusal it must not retry.

The `--dsh` block budget is an **episode**, not a session lifetime: the ledger is discarded once it is
older than `FM_DSH_TURNEND_BUDGET_WINDOW` (default 900s), so one exhausted lapse cannot leave a
long-lived session permanently blocked, and the incremented count is written before the stop is
decided so a killed hook cannot lose a consumed continuation.

**The terminal state is one alarm turn, then allow.** DSH's bridge logs and DROPS a non-blocking
`systemMessage` ("not yet surfaced (ignored)"), so the Claude path's `terminal_fail_open` — which is
loud there — produced no operator-visible record at all on DSH. The only channel DSH surfaces is a
blocking `Stop` decision whose reason is model-visible steering, so the alarm rides that exactly once
per episode and every later stop is allowed. The block bound is therefore `budget + 1`. The alarm is
also latched durably at `state/.dsh-turnend-fail-open`, which the session-start digest prepends when
present, so a session that dies before the agent relays it still reports it; the guard's healthy-reset
owns clearing that latch, so a recovered home can alarm again on a later lapse. A budget lock that
cannot be acquired raises the same alarm rather than falling through to an unbounded block.

`--claude` is passed to the PreToolUse guards deliberately: it selects the deny-output dialect, not Claude-specific behavior, and DSH honours that dialect.
