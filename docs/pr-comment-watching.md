# PR comment watching

Firstmate can watch PR-linked tasks for new GitHub feedback and inject that feedback into the crewmate that owns the task.
It is opt-in local state: enabling creates `state/pr-comments.check.sh`, while disabling removes or narrows that generated check shim.

## Enable / disable

```sh
bin/fm-pr-comments.sh enable all        # watch every active task with state/<id>.meta pr=<url>
bin/fm-pr-comments.sh enable <task-id>  # watch one PR-linked task
bin/fm-pr-comments.sh status
bin/fm-pr-comments.sh disable <task-id>
bin/fm-pr-comments.sh disable all
bin/fm-pr-comments.sh poll all          # manual one-shot poll
bin/fm-pr-comments.sh poll <task-id>    # manual one-shot poll for one task
```

Enabling primes currently visible comments as already seen before writing `state/pr-comments.check.sh`, which is picked up by the normal firstmate watcher check loop, so only new feedback is delivered after activation.
If priming fails, activation is left unchanged and the error is printed.
Disabling one task while `all` is enabled records that task as an exclusion; `status` lists excluded tasks.

## What is watched

`bin/fm-pr-comments-poll.sh` discovers task PRs from `state/*.meta` `pr=` entries and polls GitHub for:

- PR issue comments;
- PR review comments, including file/line context when GitHub provides it;
- PR review bodies and review state.

Seen event ids are stored under `state/.pr-comments/seen/`.
New events are marked seen only after a successful `bin/fm-send.sh fm-<task-id> ...` injection, so retries do not lose undelivered feedback.
Bot comments and comments from the authenticated GitHub user are ignored and still marked seen to avoid feedback loops.
Enabled watcher checks process a bounded round-robin batch of tasks per cycle (`FM_PR_COMMENTS_MAX_TASKS_PER_POLL`, default 4) so larger fleets keep making progress without overrunning the check timeout.

The scripts do not merge, push, edit project files, or store comment bodies in state.
They keep only ids and small error markers.

## Dependencies and tuning

The poller needs `gh` authenticated for the relevant GitHub repository and `jq` on `PATH`.
`FM_PR_COMMENTS_GH` can point at an alternate GitHub CLI command, and `FM_PR_COMMENTS_SEND` can point at an alternate sender for tests.
By default, comments by the authenticated GitHub user are ignored; set `FM_PR_COMMENTS_IGNORE_AUTH_USER=0` to inject them, or set `FM_PR_COMMENTS_SELF_LOGIN=<login>` to skip the `gh api user` lookup.
`FM_PR_COMMENTS_MAX_BODY_CHARS` and `FM_PR_COMMENTS_MAX_MESSAGE_CHARS` cap injected feedback text, and `FM_PR_COMMENTS_LOCK_STALE_SECS` controls stale per-task poll lock recovery.

## Pi interaction

No Pi-specific background process is required.
Under Pi, the existing Firstmate wake extension already owns `bin/fm-watch-arm.sh`; the PR comment check shim rides that same watcher path.
New comments are injected into the task window with `fm-send.sh`, while watcher wake behavior and away-mode ownership stay unchanged.
If Pi is not running, any harness that runs the normal watcher gets the same behavior.
