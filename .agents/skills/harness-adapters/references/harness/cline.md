# Cline CLI

Cline's `cline` TUI, verified end to end on 2026-09-16 with cline 3.0.62 on Linux through the tmux and Herdr backends.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no cline wake protocol.
`../../../../../docs/verification/cline.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `cline` from `PATH`, refused if absent. The installed launcher is a Node wrapper that spawns the long-lived agent as a native binary whose live process name is exactly `.cline` (verified: `ps -o comm=` reports `.cline` with `argv[0]` `.cline`). |
| Launch | `cline -i -c <worktree> --auto-approve true -m <provider>/<model> --thinking <level>`, launched BARE and given its brief only after the readiness gate below. `--model` takes the full `<provider>/<model>` id (`cline-pass/deepseek-v4-flash`); cline derives the provider from the prefix, so no separate `-P` is passed. |
| Brief delivery | Launch-then-send, the kimi/rovo shape, because cline's one-time "Introducing Cline Desktop" first-run splash consumes the first submitted line; the gate dismisses the splash with Escape, waits for cline's `Auto-approve` status row, then types the absolute brief pointer once and confirms delivery from the recorded `busy cline-hook` state (never by re-driving Enter). |
| Busy state | Workspace hook config files under `.cline/hooks` (source `cline-hook` in `../../../../../bin/fm-busy-lib.sh`): `TaskStart` opens a turn; `TaskComplete`, `TaskCancel`, `TaskError`, and `SessionShutdown` all close it. `../../../../../bin/fm-spawn.sh` arms the busy generation, writes the files before launch, and excludes `.cline/` from git's view. |
| Rendered tail | The in-transcript busy row reads `⠸ Thinking... (esc to cancel)`; when the turn ends the same row is rewritten as `▶ Thinking:` with the token gone. The bottom status row (`⏵⏵ Auto-approve all enabled (Shift+Tab)`) does NOT change between busy and idle, so it is not a signal. |
| Turn end | The `TaskComplete` hook touches `state/<id>.turn-ended` (the watcher NOTIFICATION) in addition to closing the busy record. |
| Exit | `/exit`, one Enter; the process exits. |
| Interrupt | Single `Escape`, which stops the running turn and leaves the composer at its `Ask anything...` placeholder with no prompt repollution, so no clear key follows. |
| Skill | No verified slash-skill form for injected instructions; use natural language. |
| Autonomy | `--auto-approve true` (cline's documented default, passed explicitly) auto-approves every tool call for the run. |
| Marker | None; a live TUI carries no cline-identity variable. Detected by ancestry alone. |
| Resume | `--id <session-id>` resumes an existing session and `cline history --json` lists session ids, but no verified pane-resume contract exists; use deterministic relaunch. |
| Model | `-m <provider>/<model>`; a value without `/` is refused by cline with `invalid model format. Expected format: modelType/model`. `bin/fm-spawn.sh` passes the id through unchanged. |
| Effort | `--thinking none\|low\|medium\|high\|xhigh`; `max` stays in task metadata under the record-and-omit contract. |
| Composer | A bordered composer with the bare agent glyph `❯` and a muted-truecolor idle placeholder (`Ask anything...`, or the fresh-session `What can I do for you?`). Both placeholders are in `../../../../../bin/fm-composer-lib.sh`'s fleet-wide idle set, but cline renders them at ~135.5 perceived luminance, just above the shared ghost-luma ceiling of 128, so on the styled tmux/herdr captures an idle cline composer classifies `pending`, never `empty`. This is the same known gap `../../verification/rovo.md` documents; cline readiness/delivery therefore lead with the `Auto-approve` status row and the recorded busy hook, and cline steering relies on the shared queued-Enter busy conversion. |

## Trust, dialogs, and the first-run splash

Cline was not observed to gate a fresh worktree behind a folder-trust dialog, and no launch flag or trust store was needed; `--auto-approve true` covers tool approval.
The one first-run obstacle is the "Introducing Cline Desktop" splash, which renders only until it is dismissed once per profile and, if present, swallows the first submitted line.
The readiness gate (`cline_wait_for_ready` in `../../../../../bin/fm-spawn.sh`) detects the splash text and sends one Escape before polling for the idle composer, so a fresh-profile worker cannot lose its brief.

## Credential precondition

A verified cline worker ran under a signed-in ClinePass subscription with no key export.
Authorize with `cline auth -p cline-pass` (or the positional `cline auth cline-pass`) on a TTY; the credential lands in `~/.cline/data/settings/providers.json`.
The unauthenticated failure mode was not observed, so treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `.cline` (and, as a backup for the node wrapper, the anchored script-path fragments `/bin/cline` and `@cline/cli`).
No environment marker is promoted: cline publishes none, and it does not clear an inherited `CLAUDECODE`, so `../../../../../bin/fm-spawn.sh` clears the foreign primary markers at the launch boundary for the same reason cursor and muse do.
cline is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, rovo, and agy are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms the busy generation with a seed record of `idle/fm-spawn` (the bare launch is not a submitted turn), then writes the five `.cline/hooks` files before launch.
`TaskStart` writes `busy cline-hook` when the brief pointer is submitted, so spawn delivery confirmation reads the same recorded state the supervisor later reads; the `(esc to cancel)` rendered token is only a fallback for a pane whose hook has not landed.
Teardown and relaunch retire the hook files through `fm_control_harness_wiring_paths` in `../../../../../bin/fm-control-lib.sh`.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no cline protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
