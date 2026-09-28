# Teardown hooks

Teardown hooks let a home run its own cleanup for a task once `bin/fm-teardown.sh` has finished with it.
They exist for cleanup firstmate cannot know about: resources a worker created outside its worktree, such as scratch databases, containers, or cloud sandboxes, that should go when the task goes.

## Turning them on

Create the directory `config/teardown-hooks/` in a firstmate home and put one executable file in it per hook.
The directory is local, gitignored, per home, and not inherited by second mate homes.
While it is absent, teardown performs one directory test and nothing else.

## What runs, and when

After a teardown succeeds, every regular executable file in the directory runs once, in name order.
A non-executable file, a subdirectory, or a dotfile is ignored.
A teardown that refuses, for example over unlanded work, runs no hook.

Each hook receives the task id as its only argument, stdin from `/dev/null`, and these environment variables:

| Variable                | Meaning                                                        |
| ----------------------- | -------------------------------------------------------------- |
| `FM_TEARDOWN_TASK_ID`   | The task id, the same value every worker pane saw as `FM_TASK_ID` |
| `FM_TEARDOWN_KIND`      | `ship`, `scout`, or `secondmate`                               |
| `FM_TEARDOWN_PROJECT`   | The task's project directory, empty when it has none           |
| `FM_TEARDOWN_WORKTREE`  | The task's worktree or home path, empty when it has none       |

Two teardowns pass an empty `FM_TEARDOWN_WORKTREE` on purpose.
A task whose Treehouse pool slot was reassigned to another task no longer owns that path, so teardown leaves the slot alone and tells hooks the task has no worktree.
A remote second mate's home lives on another host, so its retirement runs this home's hooks with an empty worktree and an empty project.

## Limits

Each hook runs under its own time bound, `FM_TEARDOWN_HOOK_TIMEOUT` seconds (default `120`), and is stopped with its whole process group when the bound passes.
A hook that fails or is stopped prints a warning naming the hook and the task; it never changes teardown's exit status, because the task is already gone by the time hooks run.
Hooks run with the operator's own permissions, so treat the directory like any other script you install.

## Example

A hook that drops every scratch database a task created, for projects whose test helpers stamp databases with `FM_TASK_ID`:

```sh
#!/usr/bin/env bash
cd "$HOME/firstmate/projects/my-service" && exec npm run --silent db:scratch -- drop-task "$1"
```
