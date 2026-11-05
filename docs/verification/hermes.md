# Hermes TUI worker verification

Verified on 2026-11-02 on Linux with `Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045` and tmux 3.6.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/hermes.md) owns operating limits; the [spawn header](../../bin/fm-spawn.sh) owns concrete launch/profile mechanics.
Primary, secondmate, non-tmux backends, desktop/web, bridges, and Hermes messaging were not exercised and remain unsupported.

## Reusable guards

Use a prepared **throwaway** Hermes root and profile for the credentialed guard.
It uses the profile's own inference model/authentication only for small synthetic prompts and sends no message to a gateway.
The guard's native first-run consent check uses a separate fresh, uncredentialed profile.
Both guards create their own private tmux servers and preserve no shared endpoint ownership.

```bash
FM_HERMES_SIGNALS_LIVE=1 \
FM_HERMES_LIVE_HOME="$throwaway_root" \
FM_HERMES_LIVE_PROFILE=worker \
bash bin/fm-test-run.sh tests/fm-hermes-signals-live-e2e.test.sh

FM_HERMES_GATEWAY_LIVE=1 \
FM_HERMES_LIVE_HOME="$throwaway_root" \
FM_HERMES_LIVE_PROFILE=worker \
bash bin/fm-test-run.sh tests/fm-hermes-gateway-coexistence-live-e2e.test.sh

FM_HERMES_PROFILE_SAFETY_LIVE=1 \
FM_HERMES_PYTHON="$installed_hermes_python" \
bash bin/fm-test-run.sh tests/fm-hermes-profile-safety-live-e2e.test.sh

bash bin/fm-test-run.sh tests/fm-hermes-harness.test.sh tests/fm-tmux-agent-liveness.test.sh
FM_TEST_STOCK_BASH=1 bash tests/fm-backend.test.sh
```

`FM_HERMES_PYTHON` must name the interpreter from the installed Hermes environment, so the native profile-safety guard imports that version's own APIs rather than substituting Firstmate implementations.
When the bare runtime interpreter cannot import the gateway modules, point `FM_HERMES_PYTHON` at a small wrapper that runs it through Hermes's own `hermes_bootstrap`.
An unavailable required tool is reported by the shared `fm_live_gate`; explicit opt-in refuses missing capabilities.

## Live worker observations

The credentialed tmux guard produced these results with the profile's configured Codex model:

```text
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: native first-run offer recognized, No thanks confirmed, TUI ready and decline persisted
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: interactive brief, native profile, tools, status, identity, busy and turn-end
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: real steering inbox read and acknowledgement
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: idle interrupt preserves process; double-Escape cancels a turn and native end settles
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: /quit and deterministic relaunch retain profile and task endpoint
```

The actual worker calculated `80235`, detected its harness as `hermes`, appended task status outside its worktree, and acknowledged the real durable steering record by moving it into `handled/`.
Allocation and initial launch staging use isolated test fixtures; the subsequent tmux processes, busy events, composer reads, steering, interrupt, exit, and relaunch are real.
The spawn's native readiness gate and the relaunch both consume the adapter's current TUI/hook facts.

### Native hooks

A harmless TUI turn emitted `pre_llm_call` and `on_session_end` with `extra.platform=tui` and the same `extra.turn_id`.
Normal completion and double-Escape interruption both fired the native end event and closed the generation-bound busy record.
The receiver filters other platforms and matches the native turn id rather than a session id, because compression can rotate the latter.
The portable guard verifies stale-generation rejection and that another turn cannot close the active one.
Hermes argv-parses shell-hook commands; dedicated executable receiver commands are used instead of shell operators.
The private managed overlay preserves existing configured hooks and refuses an existing managed scope.
No user SOUL or profile configuration is rewritten to install hooks.

### Composer and lifecycle

The real idle profile composer was `worker ❯` beneath its native status rule.
While busy, the placeholder was `Ctrl+C to interrupt…` with this captured styling:

```text
ESC[38;5;231m ESC[48;5;178m C ESC[38;5;178m ESC[49m trl+C to interrupt… ESC[39m
```

Only that synthetic cursor/hint sequence is removed; the same words in normal bright input remain a draft.
The shared rendered delivery guard also recognizes the native per-turn elapsed footer independently of the interrupt hint.
A foreground Hermes identity, the native status rule, and the prompt position are required to classify the profile composer.
The default profile's unprefixed `❯` also matches the generic cursor-anchored shape, so the tmux read checks Hermes identity first; the portable tmux liveness guard covers that prompt's idle placeholder, native busy hint, bright draft, and missing status rule.
Unrecognized themes or wrapped input defer delivery instead of claiming empty.
Double Escape cancels a running turn and preserves an idle worker; it also discards an unsent draft, so the control plane refuses interrupt unless the composer is proven empty.
`/quit` returned to the pane shell, and deterministic relaunch retained the profile, task endpoint, and local worktree.
Ctrl+C was not used because native idle handling can exit the TUI.

### Foreground process liveness

The portable tmux guard runs a real `python3 -I -c` bootstrap with a same-process-group `node --expose-gc …/ui-tui/dist/entry.js` child.
It proves both are in the pane's foreground group and neither process name identifies Hermes, then requires `alive` from the backend probe.
An unrelated Node script remains ambiguous, and the positive verdict survives losing either the kernel argv or flattened-argument path where that path is available.
The missing/unreadable-helper guard checks all five dependent backends before any adapter is sourced, including the stock-Bash entry point.
On 2026-11-02 the installed Hermes TUI also passed the token-free native profile-safety guard with the extended liveness assertion:

```text
native TUI foreground liveness: alive
```

### First-run consent and query path

The native `hermes --help`, `hermes chat --help`, and installed `hermes_cli.observability.shared_metrics_consent` define the observed startup path.
A fresh-profile offer showed all three choices, with `No thanks` already selected; submitting Enter recorded `telemetry.shared_metrics.enabled=false`, `send=false`, and `offer_version=2`, then reached the TUI.
The guard reads those values back through `hermes -p consent config get telemetry.shared_metrics --json`.
The canonical worker query normally skips that offer, and the startup guard handles the complete observed screen if it does appear.
The TUI path did not submit `--query-file` on this version, while interactive `-q` submitted the typed operational envelope and kept the TUI addressable.

## Native profile safety

The native profile-safety guard produced:

```text
native gateway runtime lock: held
native TUI beside held gateway runtime lock: ready
native TUI foreground liveness: alive
two native session-store writers: distinct sessions retained
two native memory add writers: both entries retained
native gateway runtime lock: released
```

The probe held `gateway.status.acquire_gateway_runtime_lock()` while opening the TUI in the same disposable profile.
Two separate processes then used the installed `SessionDB` and `MemoryStore.add` APIs on distinct session ids and checked both records/entries survived.
It preseeded only the throwaway profile's declined telemetry values; it had no messaging credentials and started no messaging gateway.
This proves native startup coexistence, distinct-session persistence, and the tested memory-add case, not safe operation beside a real mid-turn gateway, writes to one session, or arbitrary external memory providers.

### Idle gateway coexistence

On 2026-11-02 between 05:40:45Z and 05:43:51Z the gateway coexistence guard started a real `hermes -p worker gateway run` for the throwaway profile, then ran the full credentialed TUI guard above beside it:

```text
idle gateway before: {"pid":208120,"gateway_state":"running","active_agents":0,"active_work":null,"updated_at":"2026-11-02T05:40:47.785255+00:00","session_store":{"status":"ok"}}
ok - real idle profile gateway accepted by the read-only preflight
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: native first-run offer recognized, No thanks confirmed, TUI ready and decline persisted
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: interactive brief, native profile, tools, status, identity, busy and turn-end
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: real steering inbox read and acknowledgement
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: idle interrupt preserves process; double-Escape cancels a turn and native end settles
ok - hermes Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: /quit and deterministic relaunch retain profile and task endpoint
idle gateway after: {"pid":208120,"gateway_state":"running","active_agents":0,"active_work":null,"updated_at":"2026-11-02T05:43:49.364081+00:00","session_store":{"status":"ok"}}
native gateway status: ✓ Gateway is running (PID: 208120)
session store: integrity ok, 7 prior sessions and their messages retained, 2 new worker sessions; memory unchanged
ok - Hermes Agent v0.21.7 (2026.9.24) · stable · local 71d34bad1045: TUI worker completed beside a real idle gateway; gateway, session store and memory intact
```

Native Hermes runs a profile-owned gateway only with `gateway.standalone: true`; the guard sets it on the throwaway profile and restores the original config afterward.
The gateway ran under a cleared environment with a private `HOME`, `XDG_STATE_HOME`, and `HERMES_GATEWAY_LOCK_DIR`, so no inherited platform credential, operator Hermes root, or host gateway rendezvous was visible to it.
The profile configured no messaging platform; the guard refuses one.
Both the spawn and the relaunch preflights accepted the live idle gateway.
The same gateway process stayed running and idle, its heartbeat kept advancing, and native `gateway status` still reported it running.
The SQLite store passed `integrity_check`, every prior session kept its message count, the worker added its own sessions, and `MEMORY.md` was byte-identical.

Firstmate therefore accepts the profile's own gateway only when its native runtime status shows it running and idle at a fresh heartbeat.
This does not verify a gateway turn overlapping a worker turn, writes to one shared session, platform traffic, or external memory providers.
The gateway can begin a turn after dispatch, so the preflight is not a lifetime reservation.
The portable guard exercises idle, mid-turn, draining, stale, and malformed status; systemd activity and transitions; held versus stale native locks; default-root, other-home, and own-home rendezvous; profile validation; and pre-stop relaunch refusal.

## Model discovery and primary boundary

The tested native surfaces were `hermes -p <profile> config get model.default --json`, `config get model.provider --json`, CLI help, and the actual provider response.
Firstmate leaves model and reasoning selection with the profile rather than hardcoding that account's catalog.
No primary hook, watcher protocol, secondmate integration, or Herdr lifecycle was verified; executable primary/secondmate/backend refusals and their portable regressions enforce that boundary.
