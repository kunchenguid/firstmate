# Codex App backend

Audience: operator-current.

`codex-app` is an experimental spawn backend for Codex workers that should be visible in Codex Desktop.
It uses a leased treehouse worktree and the installed Codex CLI's app-server protocol.
The task endpoint is a durable Codex thread id, so normal Firstmate commands can create, steer, inspect, classify, interrupt, archive, and tear down the worker.

## Requirements

- Codex CLI with `codex app-server --listen` support, verified with `codex-cli 0.146.0`.
- Node.js from Firstmate's universal toolchain.
- Treehouse with durable lease support.
- A working Codex login for the installed CLI.

The adapter starts one app-server per Firstmate home on a private Unix socket under `state/.codex-app/`.
On platforms with `setsid`, the server is detached from the launching command so it survives between Firstmate operations.

## Select it

Select it for one worker:

```sh
bin/fm-spawn.sh <task-id> <project> --harness codex --backend codex-app
```

Or make it the local default for new workers:

```sh
printf 'codex-app\n' > config/backend
```

Only the `codex` harness is accepted.
Ship and scout workers are supported.
Secondmates are not supported, and `codex-app` is never auto-detected.

## Operate it

Use the normal Firstmate commands:

```sh
FM_HOME="$PWD" bin/fm-send.sh <task-id> "follow-up"
FM_HOME="$PWD" bin/fm-peek.sh <task-id> 80
FM_HOME="$PWD" bin/fm-crew-state.sh <task-id>
FM_HOME="$PWD" bin/fm-teardown.sh <task-id>
```

The brief remains responsible for the normal `state/<id>.status` lifecycle lines.
Spawn waits for a new valid lifecycle line before accepting the worker, proving that the thread can report through the required status channel.
Busy and idle come directly from the app-server thread lifecycle, not terminal text.
The client opts into the app-server's experimental API because bounded transcript paging uses `thread/turns/list`.
Transcript capture requests only a bounded page of recent turns before applying the requested line limit.
Teardown interrupts any active turn, archives the exact thread, and only then returns the leased worktree.

Task metadata records `backend=codex-app`, `window=<thread-id>`, and `codex_app_thread_id=<thread-id>`.
If the app-server stops, the next create, send, read, lifecycle, interrupt, or archive operation restarts it and resumes the durable thread.

## Current limits

- The thread is Desktop-visible, but Firstmate still owns the worktree and status lifecycle.
- Away-mode supervisor injection still targets only tmux or Herdr primary panes.
- Secondmate launch and recovery remain out of scope.

[`verification/runtime-backends.md`](verification/runtime-backends.md#codex-app) owns the live verification record.
