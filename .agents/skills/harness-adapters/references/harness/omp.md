# omp (Oh My Pi)

Verified for crew, scout, secondmate, and primary work on Herdr on 2026-09-05 with omp 18.1.11, building on the 2026-09-02 adapter investigation against 18.1.2.
omp is a Pi fork, so `references/harness/pi.md` is the nearest relative; every difference from Pi is stated here.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `omp`, a single Bun-compiled executable resolved from `PATH` by `../../../bin/fm-spawn.sh`; a missing binary refuses the spawn. |
| Launch | Foreign markers cleared (`CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `GEMINI_CLI`, Cursor's), `FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1`, then `omp --config <.omp/fm-worker-overlay.yml> --auto-approve --cwd <worktree> [--model] [--thinking] -e state/<id>.omp-ext.ts <one positional brief>`; a secondmate passes no `-e` and relies on auto-discovery. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `omp-ext`: the per-task extension marks busy at `agent_start` and idle at `agent_end` only when `willContinue` is not true; `ctx.isIdle()` is deliberately not consulted because it reads false at a natural TUI `agent_end` (`session_stop` is awaited before settle). |
| Exit command | `/quit` (`/exit` and `/q` are aliases). |
| Interrupt | Single Escape; the composer is left empty, no clear key. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <provider>/<id>` (fuzzy patterns are accepted by omp but bypass Firstmate's pre-launch check). |
| Effort flag | `--thinking <off\|minimal\|low\|medium\|high\|xhigh\|max\|auto>`, a superset of the shared vocabulary, so every level including `max` maps straight across. |
| Model discovery | `omp models [--json]` lists built-in and auto-discovered providers only; extension-registered providers such as `claude-bridge` never appear, so those models pass through the spawn unvalidated with a stderr notice. `omp usage` shows provider windows; `quota-axi` covers the `claude` provider when the bridge is in use. |
| Marker | None of omp's own (verified: `PI_CODING_AGENT` absent from the binary, no `PI_CODING_AGENT_DIR` or `OMP_PROFILE` in the default profile). `FM_OMP_HARNESS=omp` is Firstmate's launch marker; ancestry matches the exact process name `omp`. |
| Composer | Pinned to `composer.shape: borderless` by the overlay, a bare `❯` (U+276F) row the shared classifier already reads; busy text is `Working…` (U+2026), the only spelling the omp busy regex accepts (the three-dot form its headless `-p` mode writes never reaches a supervised pane), with the status row's braille spinner plus elapsed cell as the second signal. |
| Autonomy | `--auto-approve` owns approval (omp forces `tools.approvalMode: yolo` for the session under it); the overlay pins `plan.defaultOnStartup: false`, `prewalk.enabled: false`, `retry.usageReservePolicy: auto`. |
| Trust | No project-trust gate at all; a fresh profile shows a provider-login wizard instead, suppressed by `OMP_SKIP_SETUP=1`. |
| Resume | `-c/--continue` and `-r/--resume` exist but carry no verified pane-resume contract; use deterministic relaunch. |

Keep the instructions as one positional argument; a second positional never surfaced as a submitted message.
The openai-codex models reach an extension-registered tool through omp's `xd://` virtual-file bridge: the model reads `xd://fm_watch_arm_omp` for the description and writes `xd://fm_watch_arm_omp` to invoke it, so a transcript or rpc stream shows a `write` to that path rather than a direct `fm_watch_arm_omp` call; both are the same invocation (verified 18.1.11).
omp cold start is roughly twenty seconds to the first agent turn, paid once per worker.

## Detection

`../../../bin/fm-harness.sh` tests `FM_OMP_HARNESS=omp` before `CLAUDECODE`, like Cursor's markers, and its ancestry walk matches the anchored process name `omp` above the interpreter fallback.
Every non-omp launch template in `../../../bin/fm-spawn.sh` clears `FM_OMP_HARNESS`, and the omp template clears every foreign marker, so an omp secondmate's workers keep their own identity and an inherited `CLAUDECODE` cannot outrank a worker that omp launched.
`../../../bin/fm-session-lock-lib.sh` matches the same anchored name for session-lock ownership, and `../../../bin/backends/tmux.sh` classifies it `agent` for liveness.
The optional claude-bridge extension runs a nested executable literally named `claude` as a sibling of tool execution, never an ancestor of it, so omp's own tool calls detect as omp; that subtree is never walked by a Firstmate script.

## Worker posture overlay

The captain's own `~/.omp/agent/config.yml` is never written; the tracked `.omp/fm-worker-overlay.yml` is passed with `--config` for the one session and pins only the settings whose captain-level values would park an unattended worker on a prompt, change its pinned model, or make its composer unreadable.
`../../../bin/fm-spawn.sh`'s header owns the exact list and the reason for each pin.

## Extension loading

omp auto-discovers `<cwd>/.omp/extensions/*.ts` (top level only, cwd only, no ancestor walk, no trust dialog) and the active profile's `agent/extensions/`; `.pi/extensions/` is not a discovery root.
A file that is both auto-discovered and named with `-e` loads twice, so the per-task worker extension lives in `state/` and a secondmate launch names no `-e` at all.
There is no `agent_settled` event; `agent_end` plus `willContinue` replaces it.

## Primary integration

The omp primary follows the Pi extension-owned watcher model through `../../../docs/supervision-protocols/omp.md`: `.omp/extensions/fm-primary-omp-watch.ts` arms `bin/fm-watch-arm.sh --restart` through the `fm_watch_arm_omp` tool and owns every successor, and `.omp/extensions/fm-primary-turnend-guard.ts` answers omp's blocking `session_stop` hook by forcing one continuation when `../../../bin/fm-turnend-guard.sh` returns 2, bounded per turn by omp's `stop_hook_active` flag.
The same file ports the `tool_call` seatbelts and delivers the session-start digest through `before_agent_start` on the Run tier; omp's `session_start` carries no reason, so the source is derived (first start `startup` or `resume` from the launch line, later in-process starts `clear`, `session_compact` as `compact`).
omp has no asynchronous Stop-hook equivalent, so the Claude auto-arm model does not apply; `fm_supervision_model` classifies omp as `extension`, and `fm_omp_extension_owns_supervision` in `../../../bin/fm-wake-lib.sh` is the ownership proof that tolerates the extension's own watcher hand-off.
The Pi supervision branch is out of scope for omp; every actionable wake is delivered to main.
Launch a primary with plain `omp` inside the home (`FM_OMP_HARNESS=omp omp` when starting from a Claude pane); `../../../bin/fm-session-start.sh` prints `OMP_WATCH_EXTENSION: not loaded` when the running session has not loaded both tracked extensions.
`FM_OMP_LIVE_E2E=1 ../../../tests/fm-omp-primary-live-e2e.test.sh` is the opt-in live guard; `../../../tests/fm-omp-harness.test.sh` is the portable regression.
Remote secondmate routes (`../../../bin/fm-spawn.sh --remote` and `../../../bin/fm-remote-secondmate-control.sh`) refuse omp until a remote host verifies it.
