# PR comment watching

Firstmate can watch PR-linked tasks for new GitHub feedback and inject that feedback into the crewmate that owns the task.

## Enable / disable

```sh
bin/fm-pr-comments.sh enable all        # watch every active task with state/<id>.meta pr=<url>
bin/fm-pr-comments.sh enable <task-id>  # watch one PR-linked task
bin/fm-pr-comments.sh status
bin/fm-pr-comments.sh disable <task-id>
bin/fm-pr-comments.sh disable all
```

Enabling primes currently visible comments as already seen before writing `state/pr-comments.check.sh`, which is picked up by the normal firstmate watcher check loop, so only new feedback is delivered after activation. If priming fails, activation is left unchanged and the error is printed. Disabling one task while `all` is enabled records that task as an exclusion; `status` lists excluded tasks.

## What is watched

`bin/fm-pr-comments-poll.sh` discovers task PRs from `state/*.meta` `pr=` entries and polls GitHub for:

- PR issue comments;
- PR review comments, including file/line context when GitHub provides it;
- PR review bodies and review state.

Seen event ids are stored under `state/.pr-comments/seen/`. New events are marked seen only after a successful `bin/fm-send.sh fm-<task-id> ...` injection, so retries do not lose undelivered feedback. Bot comments and comments from the authenticated GitHub user are ignored and still marked seen to avoid feedback loops. Enabled watcher checks process a bounded round-robin batch of tasks per cycle (`FM_PR_COMMENTS_MAX_TASKS_PER_POLL`, default 4) so larger fleets keep making progress without overrunning the check timeout.

The scripts do not merge, push, edit project files, or store comment bodies in state. They keep only ids and small error markers.

## Pi interaction

No Pi-specific background process is required. Under Pi, the existing Firstmate wake extension already owns `bin/fm-watch-arm.sh`; the PR comment check shim rides that same watcher path. New comments are injected into the task window with `fm-send.sh`, while watcher wake behavior and away-mode ownership stay unchanged. If Pi is not running, any harness that runs the normal watcher gets the same behavior.
