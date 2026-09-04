---
name: background-work
description: >-
  Agent-only procedure for making detached non-agent work visible.
  Use before launching or adopting a detached process that should remain visible
  after its agent or worktree goes away, and before retiring that visibility.
user-invocable: false
metadata:
  internal: true
---

# background-work

Load this before launching or adopting detached non-agent work that the captain may wait on.

Tracked background work is visibility, not supervision.
It has no agent endpoint, watcher dependency, automatic wake, restart, or recovery behavior.
Use a process-event source instead when the requirement is to turn a blocking external result into a durable wake.

## Register visibility

Start the detached process through the task's authorized workflow, capture its actual PID, and then register that already-running process through the supported command:

```sh
bin/fm-background-work.sh register <id> \
  --description "<plain-language activity>" \
  --task "<owning task or investigation>" \
  --pid <pid> \
  --started-at <UTC-RFC3339> \
  [--expected-finish-at <UTC-RFC3339>] \
  [--cwd <directory>] \
  [--stale-after <seconds>] \
  [--progress-timeout <seconds>] \
  --progress <argv>...
```

Registration adopts a live process and refuses when its process identity cannot be recorded.
Give the progress probe the cheapest deterministic argv that returns one short human-readable line, such as a row count or cycle number.
Use absolute data paths or set `--cwd` explicitly when the process outlives a disposable worktree.
Never put secrets in the description, task, working directory, or progress argv because the private record is still operational state that diagnostics may expose.
The command header and `--help` own exact validation, timing, storage, and output semantics.

## Read and retire visibility

Use the supported list rather than reading private state:

```sh
bin/fm-background-work.sh list
bin/fm-background-work.sh list --json
```

Treat `dead`, `stalled`, and `unknown` as observations requiring judgment, not as automatic recovery instructions.
The first successful progress sample is `unknown` because one value alone cannot prove motion.
Retire a record only when its work no longer needs to remain visible:

```sh
bin/fm-background-work.sh retire <id>
```

Retirement removes only the visibility record and never signals the process.
