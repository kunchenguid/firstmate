# Droid primary verification

This is the maintainer-verification record for Droid's primary-session adapter.
The reusable contract lives in [the harness-adapters skill](../../.agents/skills/harness-adapters/SKILL.md), [the turn-end guard](../turnend-guard.md), [the arm seatbelt](../arm-pretool-check.md), and [the Droid supervision protocol](../supervision-protocols/droid.md).

## Environment

Date: 2026-08-29.
Platform: macOS arm64, tmux.
The installed CLI advanced from 0.205.1 to 0.208.1 during the verification window.
Every primary guarantee below was established or re-established on the final 0.208.1 binary.

```sh
command -v droid
droid --version
```

```text
/Users/dela/.local/bin/droid
0.208.1
```

All scratch settings used the same project-level hook schema now tracked in `.factory/settings.json`.
The live probes ran in a disposable task worktree and a nested scratch Git repository.

## Stop blocking and loop guard

The probe command was:

```sh
tmux new-session -d -s fm-droid-primary-stopfinal -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-stop-loop-guard.json' --auto high 'Reply with exactly LOOP_READY, then end your turn.'"
```

The Stop command appended stdin, returned 2 with `DROID_STOP_INITIAL_BLOCK` when `stop_hook_active` was false, and returned 0 with `DROID_STOP_ACTIVE_ALLOW` when it was true.
The exact relevant pane output was:

```text
⛬  LOOP_READY

   DROID_STOP_INITIAL_BLOCK

⛬  Captain, shipshape.

   Hooks Stop
    └─ bash .droid-primary-lab/stop-loop-guard... : Exit code 0
      └─ DROID_STOP_ACTIVE_ALLOW
```

The exact payload log was:

```json
{"session_id":"5974f925-4ac8-4f28-9ed7-3aeda2c73d57","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/5974f925-4ac8-4f28-9ed7-3aeda2c73d57.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-high","hook_event_name":"Stop","message_id":"mcp-auth-status-4f68e43e-4372-4088-9a61-145f0c368426","stop_hook_active":false,"tool_execution_count":0,"elapsed_time":0}
{"session_id":"5974f925-4ac8-4f28-9ed7-3aeda2c73d57","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/5974f925-4ac8-4f28-9ed7-3aeda2c73d57.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-high","hook_event_name":"Stop","message_id":"596f3bba-992e-41c7-9cdb-4c3d5f7e45c6","stop_hook_active":true,"tool_execution_count":0,"elapsed_time":0}
```

Result: exit 2 plus stderr blocks the first Stop, forces a continuation, and the forced continuation carries `stop_hook_active: true`.
The shared default one-block guard is therefore the verified loop bound.

## PreToolUse denial

An allow probe first established Droid's native tool name and payload.

```sh
tmux new-session -d -s fm-droid-primary-prelog -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-pretool-log.json' --auto high 'Use a shell tool to run exactly: touch .droid-primary-lab/pretool-allowed-sentinel. Then report DONE.'"
```

```json
{"session_id":"8d9dc6ac-89f0-4fee-99a2-08484dfb3355","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/8d9dc6ac-89f0-4fee-99a2-08484dfb3355.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-medium","hook_event_name":"PreToolUse","tool_name":"Execute","tool_input":{"command":"touch .droid-primary-lab/pretool-allowed-sentinel","summary":"Create requested sentinel file","riskLevelReason":"This command creates or updates one explicitly requested sentinel file inside the workspace and does not affect other files.","riskLevel":"medium"}}
```

The allowed sentinel was `PRESENT`.
A plain-stderr exit-2 probe produced:

```text
Hooks PreToolUse → 1 failed
 DROID_PLAIN_STDERR_DENY
Execute touch .droid-primary-lab/pretool-plain-sentinel
 ↳ Error: DROID_PLAIN_STDERR_DENY

Captain, exact denial: DROID_PLAIN_STDERR_DENY

--- sentinel ---
ABSENT
```

The production checker was then exercised unchanged:

```sh
tmux new-session -d -s fm-droid-primary-prereal -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-pretool-real.json' --auto high 'Use a shell tool to run exactly: bin/fm-watch-arm.sh &. Do not alter the command. Report whether the tool ran or was denied.'"
pgrep -fl '/Users/dela/.treehouse/firstmate-395343/1/firstmate/bin/fm-watch.sh' || printf '%s\n' NONE
```

```text
Hooks PreToolUse → 1 failed
 {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDeci...
Execute bin/fm-watch-arm.sh &
 ↳ Error: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permi...

Captain, the command was denied by a safety hook because it backgrounds a
protected watcher command.

--- watcher processes scoped to this root ---
NONE
```

Result: `.tool_input.command` under tool name `Execute` is the verified transport.
Exit 2 plus nonempty stderr is sufficient to deny before execution.
The unchanged checker is honored even though its default mode also emits the Grok decision object on stdout.

## Persistent project settings and SessionStart

A nested scratch Git repository carried `.factory/settings.json` and was launched without `--settings`:

```sh
git init .droid-primary-lab/project-settings
tmux new-session -d -s fm-droid-primary-project \
  -c "$PWD/.droid-primary-lab/project-settings" \
  "droid --auto high 'Reply with exactly PROJECT_OK and end your turn.'"
```

```text
⛬  PROJECT_OK

   Hooks Stop
    └─ bash .factory/project-stop.sh : Exit code 0
      └─ PROJECT_SETTINGS_STOP_FIRED
```

The exact payload began:

```json
{"session_id":"230f215c-29ef-4974-bdbc-20f230ad45f2","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate-.droid-primary-lab-project-settings/230f215c-29ef-4974-bdbc-20f230ad45f2.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate/.droid-primary-lab/project-settings","permission_mode":"auto-medium","hook_event_name":"Stop","message_id":"1ebb0f0a-120a-4bcd-9346-1c242be6ec11","stop_hook_active":false,"tool_execution_count":0,"elapsed_time":0}
```

SessionStart context delivery was tested with:

```sh
tmux new-session -d -s fm-droid-primary-sessionstart -c "$PWD" \
  "droid --settings '$PWD/.droid-primary-lab/settings-sessionstart.json' --auto high 'Before doing anything else, repeat any DROID_SESSIONSTART_CONTEXT_TOKEN value already injected into your context. If none exists, say NONE.'"
```

```text
⛬  Captain, DROID_SESSIONSTART_CONTEXT_TOKEN_8291
```

```json
{"session_id":"0e618d00-adba-49b1-bc71-fe62f22a370b","transcript_path":"/Users/dela/.factory/sessions/-Users-dela-.treehouse-firstmate-395343-1-firstmate/0e618d00-adba-49b1-bc71-fe62f22a370b.jsonl","cwd":"/Users/dela/.treehouse/firstmate-395343/1/firstmate","permission_mode":"auto-high","hook_event_name":"SessionStart","source":"startup","CLAUDE_ENV_FILE":"/Users/dela/.factory/temp/env/droid-env-0e618d00-adba-49b1-bc71-fe62f22a370b.sh"}
```

Result: `.factory/settings.json` is persistent project configuration for a normal invocation, and SessionStart stdout is injected into model context.
The hook environment included these exact root bindings:

```text
CLAUDE_PROJECT_DIR=/Users/dela/.treehouse/firstmate-395343/1/firstmate
DROID_PROJECT_DIR=/Users/dela/.treehouse/firstmate-395343/1/firstmate
FACTORY_PROJECT_DIR=/Users/dela/.treehouse/firstmate-395343/1/firstmate
PWD=/Users/dela/.treehouse/firstmate-395343/1/firstmate
```

## Foreground tool behavior

The final 0.208.1 refresh used a new nested scratch Git repository and this exact launch command:

```sh
mktemp -d .droid-primary-refresh.XXXXXX
git init -q .droid-primary-refresh.lNozC3
tmux -L fm-droid-primary-doc-20260829 new-session -d \
  -s droid-primary-doc -n foreground \
  -c /Users/dela/.no-mistakes/worktrees/51f31747dab7/01M1833BFEWKKS7G30HE3K7VET/.droid-primary-refresh.lNozC3 -- \
  droid --auto high \
  "Run this exact foreground shell command: bash -lc 'touch foreground-running; sleep 30; rm foreground-running; echo DROID_DOC_TOOL_DONE'. While it is still running, visibly publish the concatenation of DROID_DOC_MIDCALL_ and UPDATE. After it completes, publish the concatenation of DROID_DOC_FOREGROUND_ and FINISHED."
```

`mktemp` returned `.droid-primary-refresh.lNozC3`.
While `foreground-running` still existed, the exact capture command was:

```sh
test -e .droid-primary-refresh.lNozC3/foreground-running
tmux -L fm-droid-primary-doc-20260829 capture-pane -p \
  -t droid-primary-doc:foreground -S -100
```

The relevant exact active-tool output was:

```text
   Execute bash -lc 'touch foreground-running; sleep 30; rm foreground...

 ⠇ Executing...  (Press ESC to stop)

 Auto (Med) · allow reversible commands                      GPT-5.6 Sol [BYOK]
╭───────────────────────────────────────────────────────────────────────────────╮
│ > Enter to steer · Ctrl+Enter to queue                                       │
╰───────────────────────────────────────────────────────────────────────────────╯
[⏱ 20s] 1 config issue — /diagnostics                             MCP ✗ | TMUX ⧉
~/.n/w/5/0/.droid-primary-refresh.lNozC3   main
```

The requested `DROID_DOC_MIDCALL_UPDATE` response is absent from that capture.
After the foreground command completed, the same capture command returned:

```text
   Execute bash -lc 'touch foreground-running; sleep 30; rm foreground...
    ↳ DROID_DOC_TOOL_DONE

⛬  DROID_DOC_FOREGROUND_FINISHED

 Auto (Med) · allow reversible commands                      GPT-5.6 Sol [BYOK]
╭───────────────────────────────────────────────────────────────────────────────╮
│ >                                                                            │
╰────────────────────────────────────────────────────────────────────────────────╯
[⏱ 46s] 1 config issue — /diagnostics                             MCP ✗ | TMUX ⧉
~/.n/w/5/0/.droid-primary-refresh.lNozC3   main
```

Result: no new reasoning appeared in the running capture; the requested model output appeared only after `DROID_DOC_TOOL_DONE`.
Droid therefore uses bounded foreground watcher checkpoints.

## Busy and composer signatures

The busy capture contained:

```text
⠘ Executing...  (Press ESC to stop)
```

Thinking used the same stable token:

```text
⢠ Thinking...  (Press ESC to stop)
```

The active-tool and post-tool captures above established the busy placeholder and empty idle composer:

```text
╭──────────────────────────────────────────────────────────────────────────────╮
│ >                                                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
```

```text
╭──────────────────────────────────────────────────────────────────────────────╮
│ > Enter to steer · Ctrl+Enter to queue                                       │
╰──────────────────────────────────────────────────────────────────────────────╯
```

Tmux reported:

```sh
tmux -L fm-droid-primary-doc-20260829 display-message -p \
  -t droid-primary-doc:foreground \
  'cursor_y=#{cursor_y} cursor_x=#{cursor_x} cursor_flag=#{cursor_flag} pane_tty=#{pane_tty} pane_pid=#{pane_pid} pane_current_command=#{pane_current_command}'
```

```text
cursor_y=23 cursor_x=0 cursor_flag=0 pane_tty=/dev/ttys017 pane_pid=56362 pane_current_command=droid
```

The exact typed-input and capture commands were:

```sh
tmux -L fm-droid-primary-doc-20260829 send-keys \
  -t droid-primary-doc:foreground -l DROID_DOC_TYPED
tmux -L fm-droid-primary-doc-20260829 capture-pane -p \
  -t droid-primary-doc:foreground -S -30
```

The exact composer output was:

```text
╭────────────────────────────────────────────────────────────────────────────────╮
│ > DROID_DOC_TYPED                                                            │
╰───────────────────────────────────────────────────────────────────────────────╯
```

The exact styled-capture command was:

```sh
tmux -L fm-droid-primary-doc-20260829 capture-pane -p -e \
  -t droid-primary-doc:foreground -S -8 | \
  perl -pe 's/\e/\\e/g' | tail -n 8
```

Its relevant exact output rendered the placeholder as `\e[7m\e[39mE\e[0;2mnter to steer · Ctrl+Enter to queue\e[0m`.
The reverse-video `E` is the parked cursor and `\e[0;2m` de-emphasizes the remaining ghost text, while the typed capture contains no dim styling around `DROID_DOC_TYPED`.
No other idle ghost or placeholder was observed.

## Refresh

Run the opt-in guard after a Droid upgrade:

```sh
FM_DROID_PRIMARY_LIVE_E2E=1 tests/fm-droid-primary-live-e2e.test.sh
```

The final credentialed refresh returned:

```text
ok - Droid live primary hooks: project settings, SessionStart, PreToolUse, Stop blocking, and loop guard
ok - Droid live composer: detached cursor remains safe for idle and typed input
ok - Droid live foreground tool: no reasoning continuation until tool completion
ok - Droid 0.208.1 primary live verification complete
```

If any required fact cannot be reproduced, leave Droid's primary status unverified rather than substituting another harness's behavior.
