---
name: midtask-fallback
description: >-
  Load when config/crew-dispatch.json sets mid_task_fallback and a matched profile array must be recorded after spawn, and when a worker stops on a rate limit or exhausted credits or a quota process event reports exhausted_now for a live task.
user-invocable: false
metadata:
  internal: true
---

# midtask-fallback

`docs/configuration.md` (Crew dispatch profiles) owns the `mid_task_fallback` setting.
`bin/fm-midtask-fallback.sh` owns the record, the detection, the next profile, and the relaunch.
Its header owns the commands, the exit codes, and the limit-message adapter contract.

After spawn, while the setting is on, record the array that was matched.
Use `bin/fm-midtask-fallback.sh bind <task-id> --rule <index>` for a rule array.
Use `--default` for the top-level default array.
Run bind only after the task record exists.
A fresh spawn rewrites that record, so bind again after a spawn that replaces it.
The recorded array stays the original match.
Later edits to the dispatch file do not replace it.
Turning the setting off stops further switches.

When `bin/fm-procevent-quota.sh` reports `exhausted_now` for a live task, or a task with a recorded array stops on exhausted credits and no quota wake is armed, run `bin/fm-midtask-fallback.sh consider <task-id> --snapshot <quota-json>`.
The wake carries no quota document.
In that turn, write the output of `quota-axi --json` to a file and pass that path as `--snapshot`.
Do this for each live task that has a recorded array.
Consider skips a task whose last status verb is `done`, `failed`, `needs-decision`, or `blocked`, unless that line is its own `midtask-fallback` report.
Run that consider before `stuck-crewmate-recovery` relaunches the same profile.
Status line text is not a signal.
Pass `--pane-text-file` only when pane text was already captured and a limit-message adapter exists.
Do not launch a harness to read a limit message.
The script relaunches through `bin/fm-control.sh` and keeps the local copy.
Relay the printed outcome to the captain.
No eligible next profile is a decision.
It is not a relaunch of the same profile.
