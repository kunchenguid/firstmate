# Antigravity CLI

Antigravity's `agy` TUI, verified end to end on 2026-09-10 with agy 1.2.0 on Linux through the Herdr backend.
The turn-end hook surface below was verified on 2026-09-18 with agy 1.2.6 on macOS.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no agy wake protocol.
`../../../../../docs/verification/agy.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, refused if absent; a Go-compiled single binary, so the live process name is exactly `agy` with `argv[0]=agy`. |
| Launch | `agy --prompt-interactive "<brief>" --model <id> --effort <level> --dangerously-skip-permissions`, with the resolved absolute binary; the brief auto-submits with no extra Enter. The spawn pre-registers the worktree in agy's trust store first, then waits for a busy turn (answering the folder-trust dialog if it renders anyway) before reporting success. |
| Busy state | Armed: `../../../../../bin/fm-spawn.sh` seeds the record and agy's global hook writes it, `PreInvocation` opening a turn and `Stop` closing one, both as source `agy-hook`. The `agy-regex` rendered-tail fallback is retained for the windows in which no record exists, and on Herdr the native `working` status still classifies busy. |
| Rendered tail | Busy status row carries `esc to cancel` on the left; the idle row shows `? for shortcuts` instead, both still correct on 1.2.6. The word beside the braille spinner is free-floating output and is never a signal - it read `Generating...` on 1.2.0 and `Working...` on 1.2.6, which is why neither is matched. |
| Turn end | `Stop` fires once per completed turn, including on successive turns of one conversation, and touches the watcher's turn-end marker. It does NOT fire on a manual interrupt, and agy has no session-end event, so firstmate closes the record itself on either interrupt plane, `../../../../../bin/fm-control.sh` and the legacy `../../../../../bin/fm-send.sh --key Escape`. |
| Exit | `/quit`, one Enter; the process exits. |
| Interrupt | Single `Escape`, which prints the Interrupted row and leaves an idle composer with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--dangerously-skip-permissions` auto-approves TOOL calls for the run. It does not suppress the folder-trust dialog; see below. |
| Marker | None; a live TUI carries no `AGY_*` or `ANTIGRAVITY_*` variable. agy does inject `ANTIGRAVITY_CONVERSATION_ID` into hook subprocesses, which is not an identity for the agent process and is not promoted. |
| Resume | `--continue` and `--conversation` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>` with the bare catalog id from `agy models` (for example `gemini-3.8-flash-high`); `bin/fm-spawn.sh` refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable or hung listing launches unvalidated with a notice. |
| Effort | `--effort low\|medium\|high`; `xhigh` and `max` stay in task metadata under the record-and-omit contract. |
| Composer | Borderless bare `>` row, which the shared classifier reads as `unknown` under the dead-shell rule, never `empty`; steering confirms delivery through native agent-state and the delivery footer instead, the cursor precedent. One Enter submits a steer into an idle composer; no popup eats the first. |
| Hooks | A single global `hooks.json` in agy's customization root, shared with the captain's own sessions and the Antigravity IDE. Five events exist - `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop` - and there is NO session-start or session-end event. Named keys merge across configs rather than overriding. A hook's working directory is the directory holding `hooks.json`, not the workspace, and hooks run synchronously and block agy's own agent loop. `../../../../../bin/fm-agy-turnend-hook.sh` owns the edit and the installed script. |

## Trust, and where the decision persists

Every task worktree is a path agy has never seen, so an unregistered launch stops on `Do you trust the contents of this project?` with the safe choice `Yes, I trust this folder` preselected, and an unanswered dialog sends the turn into agy's scratch directory instead of the worktree.
There is no launch flag that suppresses the dialog, but agy honours a `trustedWorkspaces` entry in the captain's own `~/.gemini/antigravity-cli/settings.json` written ahead of launch (verified live), so `../../../../../bin/fm-spawn.sh` pre-registers the worktree through `../../../../../bin/fm-agy-trust.sh` before launch, the claude shape: the helper refuses anything but a linked worktree of the spawning project, records both the logical pane path and its resolved form because agy compares the logical cwd, and preserves every other key in the store.
The post-launch readiness gate is the backstop: it answers a dialog that renders anyway with a single Enter, then requires a busy verdict (Herdr's native `working` status or the pinned `esc to cancel` row) before the spawn reports success, and on a path that was not pre-registered it never counts a busy verdict as ready until the dialog has been answered, because Herdr's native verdict can precede the dialog.
A pane whose brief cannot be confirmed to run in the worktree fails the spawn, records the failure in the task status, and closes the endpoint.
Never steer into a pane still showing the dialog; a spawn that reported success has already cleared it.

## Credential precondition

A verified agy worker ran under a signed-in Google account with no key export and no dialog.
The unauthenticated failure mode was not observed, so treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `agy`, never `*agy*`.
No environment marker is promoted: `AGENT=1` observed on a live TUI is an inherited launcher value, not an agy identity, and agy does not clear an inherited `CLAUDECODE` - but a structural agy ancestor now outranks that retained marker, which `../../../../../bin/fm-harness.sh` decides without depending on the spawn's own launch-boundary marker clearing.
agy is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, and rovo are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

agy's hooks load only from its global customization root or a workspace's own `.agents/` directory, and it exposes no settings-path variable or flag, so there is no per-task copy to point it at the way gemini's `GEMINI_CLI_SYSTEM_SETTINGS_PATH` allows.
The hook is therefore global and `../../../../../bin/fm-agy-turnend-hook.sh` owns it: it adds or replaces one `firstmate-turn-end` key, preserves every other key, and refuses a symlinked store, a store this uid does not own, or a non-object root.
A firing is attributed to one task by a private token: the spawn mints a random entry in agy's turn-end registry carrying that task's turn-end marker, busy-state writer, state dir, id, and busy generation, and exports its name to the launched process, whose hook children inherit it.
Unlike grok and kimi there is deliberately no worktree pointer, because a hook runs with the config directory as its cwd and the environment carries the token instead, so nothing is written into the project under test.
The hook is inert for every session that token does not name, drains stdin, prints the JSON object agy requires, and always exits 0; both handlers carry an explicit 5s timeout because hooks block agy's agent loop under a 30s vendor default.
`fm_busy_agy_tail_busy` matches the pinned `esc to cancel` status row alone, hardcoded with no environment override, and is RETAINED as the no-record fallback rather than replaced: `fm_busy_classify` reaches a harness regex arm only when no record exists.
Teardown removes this task's registry entry and token sidecar but never the shared hook itself, because another live agy task may still depend on it.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no agy protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
