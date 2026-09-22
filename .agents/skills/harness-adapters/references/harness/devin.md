# Devin

Verified 2026-09-10 on Devin 3000.10.21.
The router owns Devin's task-kind boundary: crewmate and scout on Herdr only, never a primary or secondmate.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Stable `devin` from `PATH`, falling back to `~/.local/bin/devin`, without pinning the versioned symlink target. |
| Launch | Direct interactive pane launch with `--prompt-file`, selected `--model`, and `--permission-mode` rather than single-turn `-p`. Owned by `../../../bin/fm-spawn.sh` and `../../../bin/fm-devin-lib.sh`. |
| Trust | `--respect-workspace-trust false` skips the directory prompt for each fresh disposable worker path without changing a global trust setting. |
| Permissions | Defaults to `dangerous` for unattended tool use; explicit `auto`, `accept-edits`, and `smart` can stop for approval, and a permission wait must not be interpreted as progress. |
| Detection | Exact native process basename `devin` in tool ancestry; no Devin identity environment marker was observed, and inherited `PI_CODING_AGENT` requires clearing foreign markers before the stable binary runs. |
| Busy | Herdr native `agent get <pane>` is Devin's only worker-state source: `working` is busy and `idle`, `done`, or `blocked` reads `idle herdr-native`, so a stopped worker surfaces instead of sitting at `unknown` (verified 2026-09-22). A natively stopped worker whose pane keeps animating its Thinking footer escalates through the watcher's bound/wedge path. No custom spinner classifier, lifecycle hook, or seeded busy record. |
| Composer | A bare `❭` row closed by one solid rule; empty placeholders are `Ask Devin to build features, fix bugs, or work on your code`, `Guide Devin while it works`, and `Press Enter to send queued messages now` under a `── N queued ──` banner (verified 2026-09-22). The Herdr adapter derives the harness hint from `agent get` whenever the caller's expected-label argument cannot name one. |
| Interrupt | Double Escape 0.2 seconds apart: first press offers `esc again to interrupt`, second displays `Canceled. What should Devin do?` with an empty composer. Tool subprocess cancellation and acknowledgement remain unproven. |
| Exit | `/exit`; verified through `fm-control` to leave an agent-free pane. |
| Steer | `fm-send` is verified on Herdr, including a follow-up after interruption, with native transition confirmation and shared composer recognition of `❭` and Devin placeholders. |
| Relaunch | `fm-control`/`fm-spawn --relaunch` start a fresh conversation from the durable instructions in the same local copy and retain the recorded permission mode. |
| Resume | CLI help advertises `-c` and `-r <id>` and `/exit` prints a resume command; this adapter neither automates nor independently live-verifies private-session continuation. |
| Skill | No slash-skill invocation is verified; send natural language naming the installed skill file and require the worker to read it. |
| Effort | None as a separate flag; reasoning class is encoded in model ids such as `swe-2-high` and `swe-2-max`. |

## Limits and recovery

Herdr native `agent start` intermittently loses its named-agent terminal binding, so use the direct path rather than retrying native startup or creating a second pane.
Direct launch exposes native pane identity but does not publish the `interactive_ready` field belonging to native start registration.
An identity match proves the agent exists, not that it processed its instructions; require the normal processing receipt.
If identity verification fails, preserve the recorded pane and inspect it before any retry.
Other backends are refused rather than inheriting unverified steering or control behavior.
The active proof and refresh command are in [runtime backend verification](../../../../../docs/verification/runtime-backends.md#devin-cli).
