# Droid primary verification

This record separates imported live evidence from verification of the current integration.
The operating contract belongs to [the Droid adapter reference](../../.agents/skills/harness-adapters/references/harness/droid.md), [turn-end guard](../turnend-guard.md), [arm seatbelt](../arm-pretool-check.md), and [supervision protocol](../supervision-protocols/droid.md).

## Imported live evidence

The original primary verification ran on macOS arm64 with tmux and Droid 0.208.1 on 2026-08-29.
Away-mode delivery was refreshed with Droid 0.212.0 and Herdr 0.8.0 on 2026-09-04.
Approval deferral was refreshed with Droid 0.215.1 and Herdr 0.8.0 on 2026-09-09.
These historical observations are not a fresh pass for another version or for the upstream integration.

| Surface | Historical observation |
|---|---|
| Project configuration | A normal interactive invocation loaded `.factory/settings.json` without `--settings`. |
| SessionStart | Hook stdout reached model context; the payload supplied `source`, `cwd`, and project-root environment bindings. |
| Execute PreToolUse | `tool_name` was `Execute`, the command was `.tool_input.command`, and exit 2 with stderr denied execution before a sentinel file appeared. |
| Stop | Exit 2 with stderr blocked the initial Stop; the continuation supplied `stop_hook_active: true`, allowing the shared one-block guard to terminate. |
| Foreground tools | A running foreground shell call prevented the requested reasoning continuation until that call finished. |
| Busy state | A working spinner and `Press ESC to stop` were independent positive signals. |
| Composer | Idle input could park the cursor outside the composer; styled ghost text differed from actual typed input. |
| Away delivery | Same-session `UserPromptSubmit` established receipt through the shared delivery path, not a new Droid-only transport. |
| AskUser deferral | A real bound questionnaire was denied, preserved with its status owner, and followed by independently authorized work; an unbound questionnaire was denied without filing a guessed owner. |
| Return | Ordered catch-up presented the outstanding question before removing away mode; interactive AskUser then returned without selecting an answer. |

The historical Stop payloads differed in the relevant field:

```json
{"hook_event_name":"Stop","stop_hook_active":false}
{"hook_event_name":"Stop","stop_hook_active":true}
```

The approval refresh reported:

```text
ok - Droid denies interactive approval during AFK, files it with its bound owner, and continues independently authorized work
ok - a live question naming no owner is rejected without inventing or mutating one
ok - a real unmarked Droid return runs ordered catch-up and presents the outstanding question first
ok - Droid AskUser becomes available on return without an automatic approval
```

`droid exec -s <session-id>` continued durable session history but did not steer an already-running interactive pane.
It is not an away-delivery transport.
A real interactive launch also rewrote vendor-managed user settings fields, so isolated live guards must use a private HOME rather than claim whole-file stability of the operator's settings.

## Away-mode delivery under Herdr

The imported 2026-09-04 run preserved an unsent draft while buffering an escalation and emitted the max-defer alert.
After the draft was cleared, `UserPromptSubmit` recorded the operational input on the same interactive session and the buffer cleared.
A dead shell remained unknown rather than borrowing Droid's composer exception.
The scenario exited before guarded lab cleanup, leaving the named non-default lab absent.

Same-session hook receipt established delivery, but the bounded viewport did not reliably retain the submitted prompt.
The original response probes did not independently establish hook-output context for both SessionStart and UserPromptSubmit; corrected distinct hook-only nonce assertions still require a live refresh.
The five-second marker-retirement wait has portable coverage but was not rerun in that historical refresh.
The 2026-09-09 AskUser refresh established denial, durable owner filing, independent progress, and return without automatic approval as summarized above.

## Portable verification

`tests/fm-droid-primary.test.sh` executes the registered SessionStart, Execute PreToolUse, AskUser PreToolUse, and Stop commands against observable fixture owners.
`tests/fm-droid-afk-approval.test.sh` exercises question preservation, owner precedence, replay, variants, transfer, lossless return, ordinary captain-held tasks, and concurrent answers through the authoritative captain-hold interface.
`tests/fm-droid-harness.test.sh` exercises exact process identity, independent busy signals, composer safety, exact-path trust, and receipt ownership.
`tests/fm-watch-checkpoint.test.sh` exercises the tracked background completion protocol and bounded foreground fallback.

These tests establish the integration's behavior, not a vendor hook transport or rendered UI on a new CLI version.

## Live refresh

The credentialed tmux guards spend model tokens and must run in isolated temporary homes:

```sh
FM_DROID_SIGNALS_LIVE=1 bash tests/fm-droid-signals-live-e2e.test.sh
FM_DROID_PRIMARY_LIVE_E2E=1 bash tests/fm-droid-primary-live-e2e.test.sh
```

The first guard covers identity, independent busy signals, composer delivery, dynamic effort, interrupt, exit, and recovery.
The second covers real spawn trust and runtime model accounting, project hooks, SessionStart context, PreToolUse denial, Stop continuation, composer behavior, and foreground-tool blocking.
[Runtime backend verification](runtime-backends.md#droid) records dated current results and the installed versions.

The separate Herdr away-mode guard is `tests/fm-droid-afk-herdr-live-e2e.test.sh`.
It requires explicit authorization for an isolated non-default lab through its guarded helper; a portable pass or the historical run does not authorize driving a live Herdr session.
No Herdr refresh was performed during this integration.

Reliable model emission of a valid owner binding in ordinary operation is not established.
The native questionnaire permits omitted or malformed bindings, so the guard rejects those rather than guessing an owner.
Rendered viewport retention after away-mode submission and direct live AskUser parity with another harness remain unproven.
