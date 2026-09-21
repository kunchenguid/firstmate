# Devin CLI

Verified on 2026-09-21 with Devin CLI 3000.11.1 (cc4e349ca55e).
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/devin.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Native `UserPromptSubmit` opens, `Stop` closes normal completion, and `SessionEnd` closes shutdown through the generation-bound writer; `../../../bin/fm-busy-lib.sh` owns trust. |
| Exit command | `/quit`, with the shared slash-command settle before Enter; prints `devin -r <session-id>`. |
| Interrupt | Two Esc presses, 0.2 seconds apart; no restored draft and no clear key. |
| Skill invocation | Natural language asking Devin to load the named skill; no Firstmate-specific slash skill form has been verified. |
| Resume | `devin -r <session-id>`; `--model` may switch the resumed session's model. |
| Model flag | `--model <model-id>`, including `swe-2-medium` and account-listed `fusion-<lead>-sidekick-swe-2-medium` ids. |
| Effort flag | None; effort is encoded in the model id, and Firstmate records the independent axis without passing it. |
| Model discovery | `devin models list`; authentication preflight is `devin auth status`. |
| Marker | Firstmate sets `FM_DEVIN_HARNESS=devin`; anchored native `devin` ancestry also identifies the adapter and outranks foreign markers. |
| Trust dialogs | The launch skips workspace trust for this run; the spawn owner carries the exact flags. |

## Worker lifecycle limits

Double Esc renders `Canceled. What should Devin do?` and restores the empty composer but emits no `Stop` hook on this version.
The control plane therefore invalidates the interrupted incarnation to `unknown`, with `cancel=unconfirmed`; it never fabricates semantic idle from a delivered key.
A manual keyboard cancellation outside that control plane can leave the last busy record until the next normal completion or session exit.
Tool responses are not used as main-turn completion signals.

`../../../bin/fm-spawn.sh` owns autonomy, trust, typed brief delivery, color preservation, and the omission of the Claude permission-mode mapping.
`../../../bin/fm-devin-config.sh` owns the private user-config snapshot and appended lifecycle hooks; the user and project configs remain vendor-owned.
The config snapshot can contain private settings and has mode 600.

## Composer and steering

`../../../bin/fm-composer-lib.sh` owns the verified `❭` glyph, dim idle placeholder, active-turn composer, and interrupt hint.
The shared delivery path must preserve ANSI styling: placeholder-like text surviving a styled capture remains a draft and must not be overwritten.
The `../../../bin/fm-task-inbox-lib.sh` doorbell was read and acknowledged through real `fm-send` on both SWE-2 and Fusion.
The shared slash-command settling path also handles `/quit` autocomplete.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Devin.
Do not launch a primary or secondmate with this adapter.
ACP, quota-provider integration, and native Fusion subagent accounting remain separate follow-ups.
