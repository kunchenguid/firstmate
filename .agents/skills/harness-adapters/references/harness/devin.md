# Devin CLI

Verified on 2026-09-21 and 2026-09-22 with Devin CLI 3000.11.1 (cc4e349ca55e).
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/devin.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Native `UserPromptSubmit` opens, `Stop` closes normal completion, and `SessionEnd` closes shutdown through the generation-bound writer; `../../../bin/fm-busy-lib.sh` owns trust. |
| Exit command | `/quit`, with the shared slash-command settle before Enter; prints `devin -r <session-id>`. |
| Interrupt | One Esc, then a second only after the running turn renders `esc again to interrupt` and at least 0.5 seconds later; no restored draft and no clear key. An idle agent gets one press and `cancel=not-running`, because a fast idle pair opens the `/revert` picker, where Enter reverts file changes. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Devin discovers Firstmate's user skills from `~/.agents/skills`, and `fm-send` types the slash form through its popup settle. |
| Resume | `devin -r <session-id>`; `--model` may switch the resumed session's model. |
| Model flag | `--model <model-id>`, including `swe-2-medium` and account-listed `fusion-<lead>-sidekick-swe-2-medium` ids. |
| Effort flag | None; effort is encoded in the model id, and Firstmate records the independent axis without passing it. |
| Model discovery | `devin models list`; authentication preflight is `devin auth status`. |
| Marker | None; anchored native `devin` ancestry identifies the adapter and outranks foreign inherited markers. |
| Trust dialogs | The launch skips workspace trust for this run; the spawn owner carries the exact flags. |
| Imported config | The worker config sets `read_config_from.claude` false, so no Claude Code hook, `CLAUDE.md` rule, `.claude/skills`, or Claude MCP entry is imported; `AGENTS.md` and `.agents/skills` still load. |
| Commit attribution | The worker config sets `attribution` false, Devin's switch for its `Co-Authored-By` trailer and `Generated with Devin` line. |

## Worker lifecycle limits

An armed double Esc renders `Canceled. What should Devin do?` and restores the empty composer but emits no `Stop` hook on this version.
The control plane therefore invalidates the interrupted incarnation to `unknown`, with `cancel=unconfirmed`; it never fabricates semantic idle from a delivered key.
A manual keyboard cancellation outside that control plane can leave the last busy record until the next normal completion or session exit.
An open revert picker is closed with one Esc, never Enter; the control plane does that after its own presses and refuses to type an exit command into it.
Tool responses are not used as main-turn completion signals.
Herdr identifies a Devin pane natively from its own screen-detection manifest, and interrupt and steering work there, but `exit` and therefore `relaunch` refuse on Herdr: its cursorless composer read answers `unknown` for Devin's frame.

`../../../../../bin/fm-spawn.sh` owns autonomy, trust, typed brief delivery, color preservation, and the omission of the Claude permission-mode mapping.
`../../../../../bin/fm-devin-config.sh` owns the private user-config snapshot and appended lifecycle hooks; the user and project configs remain vendor-owned.
The config snapshot can contain private settings and has mode 600.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified `❭` glyph, dim idle placeholder, active-turn composer, and interrupt hint.
The shared delivery path must preserve ANSI styling: placeholder-like text surviving a styled capture remains a draft and must not be overwritten.
The `../../../../../bin/fm-task-inbox-lib.sh` doorbell was read and acknowledged through real `fm-send` on both SWE-2 and Fusion.
The shared slash-command settling path also handles `/quit` autocomplete.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Devin.
Do not launch a primary or secondmate with this adapter.
ACP, quota-provider integration, and native Fusion subagent accounting remain separate follow-ups.
