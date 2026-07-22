# Codex App backend contract

Status: blocked for Firstmate as a selectable shell backend.
The Codex Desktop host-tool loop works, including status-file writes, but Firstmate does not yet have a supported shell-callable bridge to those host tools.

This document replaces the earlier passive visible-thread ledger shape.
A manual ledger is not a backend.

## Backend acceptance contract

A Codex App backend must satisfy the same lifecycle contract as the terminal-backed adapters:

1. Firstmate creates the task endpoint and receives a durable thread id.
2. Firstmate sends the initial prompt and later operator messages to that endpoint.
3. Firstmate observes enough live thread state or transcript to supervise the task.
4. Firstmate can archive, kill, or otherwise stop supervising the endpoint.
5. The Codex thread can report back through Firstmate's normal `state/<id>.status` lifecycle.

The final point is mandatory.
If a Desktop-owned thread cannot write Firstmate status files, the backend cannot be treated as complete.

## Verified Desktop host-tool smoke

Latest verified host-tool smoke date: 2026-07-06.
Environment: Codex Desktop host tools, local host, saved project `<FIRSTMATE_HOME>/projects/sift`, Desktop-owned worktree `<CODEX_DESKTOP_WORKTREE>`, Firstmate home `<FIRSTMATE_HOME>`.
Local absolute path prefixes are redacted as `<FIRSTMATE_HOME>` and `<CODEX_DESKTOP_WORKTREE>`; file names, host-tool ids, thread ids, status lines, and report values are otherwise exact.

Codex Desktop/OpenAI local bundle metadata from the smoke machine:

```text
$ /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Codex.app/Contents/Info.plist
26.623.101652

$ /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Codex.app/Contents/Info.plist
4674

$ /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Codex.app/Contents/Info.plist
com.openai.codex

$ stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S %z' /Applications/Codex.app/Contents/Info.plist
2026-07-02 21:55:53 -0400 /Applications/Codex.app/Contents/Info.plist
```

Smoke target files:

```text
<FIRSTMATE_HOME>/state/codex-app-host-smoke-20260706-live.status
<FIRSTMATE_HOME>/data/codex-app-host-smoke-20260706-live/report.md
```

Host-tool operation sequence:

1. `list_projects` confirmed the saved project target.
2. `create_thread` requested a new Codex Desktop project worktree thread.
3. `list_threads` recovered the created thread id after queued worktree setup.
4. `read_thread` observed the active and completed initial turn.
5. Shell reads verified the status/report files under the Firstmate home.
6. `send_message_to_thread` delivered a follow-up to the same thread.
7. `read_thread` observed the completed follow-up turn.
8. `set_thread_archived` archived the thread.
9. A final `read_thread` still returned the transcript and showed `status.type=notLoaded`.

Exact host-tool requests and relevant output:

```text
list_projects:
  projectId=<FIRSTMATE_HOME>/projects/sift
  projectKind=local
  label=sift
  path=<FIRSTMATE_HOME>/projects/sift

create_thread request:
  target.type=project
  target.projectId=<FIRSTMATE_HOME>/projects/sift
  target.environment.type=worktree
  prompt smoke_id=codex-app-host-smoke-20260706-live
  prompt status_file=<FIRSTMATE_HOME>/state/codex-app-host-smoke-20260706-live.status
  prompt report_file=<FIRSTMATE_HOME>/data/codex-app-host-smoke-20260706-live/report.md
  prompt required status line: working: Codex Desktop thread started
  prompt required sentinel: FM_CODEX_APP_HOST_TOOL_SMOKE_20260706_LIVE_OK

create_thread response:
  pendingWorktreeId=local:a4a96438-a0ed-4305-b83c-5a47336f5abf

list_threads query=codex-app-host-smoke-20260706-live:
  id=019f39ea-5cca-7031-bfb0-f8054a2b253a
  hostId=local
  status=active
  cwd=<CODEX_DESKTOP_WORKTREE>

read_thread initial turn while active:
  thread.id=019f39ea-5cca-7031-bfb0-f8054a2b253a
  thread.status.type=active
  cwd=<CODEX_DESKTOP_WORKTREE>
  agentMessage: Running the smoke exactly as delegated: repo identity first, then the Firstmate status/report writes, then the requested `sed` checks.

read_thread initial turn after completion:
  thread.status.type=idle
  turn.status=completed
  durationMs=54923

$ pwd
<CODEX_DESKTOP_WORKTREE>

$ git rev-parse --show-toplevel
<CODEX_DESKTOP_WORKTREE>

$ git branch --show-current

$ sed -n '1,20p' <FIRSTMATE_HOME>/state/codex-app-host-smoke-20260706-live.status
working: Codex Desktop thread started

$ sed -n '1,40p' <FIRSTMATE_HOME>/data/codex-app-host-smoke-20260706-live/report.md
smoke_id=codex-app-host-smoke-20260706-live
cwd=<CODEX_DESKTOP_WORKTREE>
git_root=<CODEX_DESKTOP_WORKTREE>
branch=
status_file=<FIRSTMATE_HOME>/state/codex-app-host-smoke-20260706-live.status
status_file_write=ok
sentinel=FM_CODEX_APP_HOST_TOOL_SMOKE_20260706_LIVE_OK

send_message_to_thread request:
  threadId=019f39ea-5cca-7031-bfb0-f8054a2b253a
  prompt required status line: done: follow-up delivered through send_message_to_thread

send_message_to_thread response:
  threadId=019f39ea-5cca-7031-bfb0-f8054a2b253a

read_thread follow-up turn:
  turn.status=completed
  durationMs=7118

$ sed -n '1,20p' <FIRSTMATE_HOME>/state/codex-app-host-smoke-20260706-live.status
working: Codex Desktop thread started
done: follow-up delivered through send_message_to_thread

set_thread_archived request:
  threadId=019f39ea-5cca-7031-bfb0-f8054a2b253a
  archived=true

set_thread_archived response:
  threadId=019f39ea-5cca-7031-bfb0-f8054a2b253a
  archived=true

read_thread after archive:
  thread.id=019f39ea-5cca-7031-bfb0-f8054a2b253a
  thread.status.type=notLoaded
  thread.cwd=<CODEX_DESKTOP_WORKTREE>
  transcript still included the initial and follow-up completed turns.
```

Result: a Desktop-owned Codex thread can write Firstmate status files when the prompt gives it the absolute status path and the Desktop permission context can write that checkout.
The return channel is real at the Codex Desktop host-tool layer.

## Codex Desktop API blocker

Firstmate's backend scripts are Bash entry points.
They can call `tmux`, `herdr`, `zellij`, primitive Orca CLI surfaces, and `cmux` directly.
The Codex Desktop host tools verified above are available to the Codex Desktop conversation, not to arbitrary Firstmate subprocesses.
The missing piece is therefore a supported Codex Desktop transport that a Bash backend can call, not another Firstmate-local ledger.

The available Codex CLI and app-server probes found useful pieces but not a supported visible-thread backend transport:

- `codex app-server --stdio` exposes JSON-RPC methods such as `thread/start`, `turn/start`, `thread/read`, and `thread/archive`.
- A one-shot stdio probe could create a thread record, and `thread/archive` worked through that same stdio process.
- The managed daemon path was unavailable in this Desktop install.
- A raw proxy attempt against the Desktop control socket did not accept plain JSON-RPC framing.

That is not enough to add `codex-app` to `FM_BACKEND_KNOWN` or `FM_BACKEND_SPAWN`.
A Firstmate backend must be able to create a thread, start or continue turns, read live state while turns run, and archive/stop the same endpoint through a Codex Desktop-supported shell-callable API.
Shipping a local ledger would only record intentions; it would not supervise the actual Desktop thread.

## Required Codex Desktop bridge

Firstmate should implement a Codex App adapter only after Codex Desktop exposes one of these supported interfaces:

- A supported CLI wrapper around the Desktop host tools: create thread, send message, read transcript/state, archive thread.
- A documented JSON-RPC or MCP transport that Firstmate can call from Bash with stable request/response framing.
- A small maintained helper binary/script that speaks the supported transport and returns plain JSON to `bin/backends/codex-app.sh`.

Minimum command semantics:

```text
create:
  input: task id, cwd/worktree request, initial prompt
  output: thread id, Desktop-owned cwd if different, initial status

send:
  input: thread id, text
  output: accepted/rejected delivery result

capture/read:
  input: thread id, bounded transcript or status cursor
  output: enough text/state for fm-peek.sh, fm-watch.sh, and fm-crew-state.sh

archive/kill:
  input: thread id
  output: archived/stopped result

status return channel:
  the thread must be able to append Firstmate status lines to state/<id>.status
```

Once that bridge exists, the implementation should add a real `bin/backends/codex-app.sh`, persist `backend=codex-app` and `codex_app_thread_id=` in `state/<id>.meta`, and wire spawn/send/peek/watch/teardown through the same dispatcher paths used by the existing adapters.

## Rollout clause

After a supported shell-callable Codex Desktop/OpenAI bridge exists, Firstmate should implement Codex App for ship and scout tasks first.
Secondmate support remains out of scope until ship/scout supervision, status return, send/read, and archive/teardown are proven through the normal backend dispatcher.

Until then, Codex App support remains a verified host-tool smoke plus this blocked backend contract, not a selectable backend.
