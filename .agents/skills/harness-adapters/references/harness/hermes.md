# Hermes Agent

Hermes is a spawned worker/Investigator TUI adapter on tmux only.
Primary and Project Director supervision, other runtime backends, desktop/web surfaces, and messaging bridges are unsupported and refused.
[Hermes verification](../../../../../docs/verification/hermes.md) owns dated vendor evidence and the live guard.

## Operating facts

| Fact | Value |
|---|---|
| Launch and profile | The interactive `hermes` CLI TUI, with native per-spawn profile selection; [`fm-spawn.sh`](../../../../../bin/fm-spawn.sh)'s header owns flags, omission, and relaunch mechanics. |
| Model and effort | The selected profile owns both axes. Firstmate refuses a non-default model override and records but omits effort. Native profile discovery is `hermes -p <profile> config get model --json` and `config get agent.reasoning_effort --json`; `/model` is the native interactive selection surface. No provider or catalog membership is inferred from a model name. |
| Busy and turn end | Native `pre_llm_call` and `on_session_end`, through [`fm-hermes-hook.sh`](../../../../../bin/fm-hermes-hook.sh) and the generation-bound busy writer; only the native `tui` platform is accepted, and the turn id binds the close across session-id rotation. |
| Hook carrier | A private native managed-scope overlay staged by [`fm-hermes-lib.sh`](../../../../../bin/fm-hermes-lib.sh); existing profile hooks are preserved, existing managed policy is refused, and no profile SOUL or configuration is edited. |
| Autonomy and hooks | The launch grants native tool autonomy and native shell-hook acceptance, including existing configured hooks. The startup guard confirms only a complete visible telemetry offer with `No thanks` already selected; native Hermes records that decline. Other first-run setup still requires a prepared profile. |
| Interrupt | Double Escape, only with a proven empty composer because the same chord discards drafts; idle double Escape preserves the worker. Ctrl+C is not used because it can exit an idle TUI. |
| Exit and relaunch | `/quit` exits to the pane shell. Relaunch starts from the stored task brief with the recorded profile and home; it does not attach to a gateway or resume an unrelated native session. |
| Identity | `FM_HERMES_HARNESS=hermes` at the launch boundary plus structural Hermes ancestry; [`fm-hermes-process-lib.sh`](../../../../../bin/fm-hermes-process-lib.sh) owns anchored Node TUI / Python module process identity. |
| Composer | Native `❯`, profile-prefixed or the default profile's unprefixed prompt, beneath a status rule; on tmux a pane showing `❯` is checked for Hermes identity before the generic cursor read, so only the Hermes classifier answers for Hermes panes; synthetic busy-hint cursor and bright drafts are distinguished by [`fm-composer-lib.sh`](../../../../../bin/fm-composer-lib.sh). Unrecognized themes, wraps, dialogs, or unreadable identity defer delivery. |
| Skills | Use ordinary text pointing at the installed skill's `SKILL.md`; native slash skill invocation has not been verified. |

## Profile safety

The selected profile's own running gateway is accepted only while idle: its native `gateway_state.json` must name the live gateway process, report `gateway_state: running` with no restart requested, `active_agents: 0` and no active work, and carry a heartbeat no older than Hermes's own 120-second staleness bound.
A mid-turn, starting, draining, or transitional gateway is refused, as is a live gateway, held native runtime lock, or active systemd unit without that idle status, and any unreadable or malformed gateway state.
A live default-root gateway, or a multiplexer launched from another home that serves the profile, is refused because its activity cannot be attributed to this profile.
An existing managed scope is refused before hooks are staged.
Firstmate does not stop, restart, or message the gateway.
The [verification record](../../../../../docs/verification/hermes.md) owns the idle-coexistence evidence and its limits.
The check is a launch preflight, not a lifetime reservation: the gateway may begin a turn after dispatch, and overlapping turns on one profile were not verified.

## Limits

The TUI's `--query-file` path did not submit the initial prompt on the verified version; the spawn uses the native interactive query path instead.
Early provider/build errors can leave the spawn-owned busy record open when the native end hook does not run; inspect the visible pane and use the ordinary recovery procedure.
User profile settings, plugins, tools, and inference credentials remain native Hermes concerns.
No primary Stop guard, pre-tool protection, watcher protocol, Project Director hook, or Herdr lifecycle was verified.
