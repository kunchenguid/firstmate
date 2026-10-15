# CodeBuddy CLI

Tencent CodeBuddy CLI (`codebuddy` from `@tencent-ai/codebuddy-code`), verified end to end on 2026-10-14 with codebuddy 2.164.0 on Linux.
Verified as a CREWMATE and SCOUT adapter only.
`../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no codebuddy wake protocol.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `codebuddy` from `PATH`, resolved via `resolve_pi_executable` and refused if absent. Node bundle executed via node. |
| Launch | `codebuddy -y --settings '{"trustAll":true}' "<brief>"` with optional `--model <id>` and `--effort <level>`. The brief auto-submits with no extra Enter. |
| Busy state | No hook or plugin writer, so nothing is armed and no record is seeded; on Herdr native `working` status classifies busy, and elsewhere the `codebuddy-regex` rendered-tail fallback in `../../../../../bin/fm-busy-lib.sh` does. |
| Rendered tail | Rotating spinner frames with elapsed time like `… ([0-9]+s · ` (e.g. `✶ Waking… (0s · waiting for model)`, `✹ Cleaning… (8s · waiting for model · ↑ 34 tokens)`). Completed turns print `✔ Worked for <n>s`. |
| Turn end | No turn-end hook or notification touch exists; completion arrives through the worker status protocol and, on Herdr, the native return to `idle`. |
| Exit | `/exit`, two Enters in interactive mode (first Enter selects `/exit` from the slash autocomplete popup, second Enter executes); the process exits with code 0. `/quit` does not exit interactive mode and is treated as model input. |
| Interrupt | Single `Escape`, which cancels the active turn immediately, leaving an empty composer (`>`) with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `-y` (`--dangerously-skip-permissions`) auto-approves tool execution for the run. |
| Marker | None in the TUI process itself; child tool / bash processes receive `CODEBUDDY_SESSION_ID` and `CODEBUDDY_PROJECT_DIR`. |
| Resume | `--continue` and `--conversation` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>` with catalog model id. |
| Effort | `--effort low\|medium\|high\|xhigh\|max`; the shared vocabulary maps straight across to codebuddy's supported levels (`minimal, low, medium, high, xhigh, max`). |
| Composer | Bordered bare `>` row between horizontal separators (`───`), which the shared classifier reads as `unknown` under the dead-shell rule; steering confirms delivery through the delivery footer regex instead. |

## Trust, and where the decision persists

Every task worktree is a path codebuddy has never seen, so an unconfigured launch presents a blocking trust modal: `Do you trust the files in this folder?`.
CodeBuddy accepts `--settings '{"trustAll":true}'` on the command line.
Passing this flag completely suppresses the folder-trust modal without modifying the user's `~/.codebuddy/settings.json` or project settings.
The flag is passed unconditionally in the launch template in `../../../../../bin/fm-spawn.sh`.

## Credential precondition

A verified codebuddy worker ran under an active Tencent Cloud / CodeBuddy login (`codebuddy auth status`).
Treat any authentication refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing credentials into it.

## Detection

Detected by ancestry and child environment marker.
On Linux with Node v22.22.2, `ps -o comm=` reports `node` and `ps -o args=` reports `node .../codebuddy ...`.
`../../../../../bin/fm-harness.sh` matches the anchored process name `codebuddy` at comm strength, and `*codebuddy*` in script args under the node interpreter fallback.
In child tool processes, `CODEBUDDY_SESSION_ID` is exported by CodeBuddy.
Because CodeBuddy does not strip an inherited `CLAUDECODE=1` in child processes, `../../../../../bin/fm-harness.sh` tests `CODEBUDDY_SESSION_ID` before `CLAUDECODE`.
codebuddy is deliberately absent from `../../../../../bin/fm-session-lock-lib.sh`: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms no busy generation for codebuddy and writes no sidecar, because no writer could clear a seeded record.
`fm_busy_codebuddy_tail_busy` matches the verified spinner frame with elapsed time (`…[[:space:]]*\([0-9]+[smh]`).
`fm_busy_classify` reports `unknown codebuddy-regex` rather than idle when the pattern is absent, because a long turn can scroll the spinner line out of the captured tail.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no codebuddy protocol, no turn-end hook adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
