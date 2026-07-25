# Primary-session delegation guard

This page is the concise human contract for the guard that stops a firstmate primary from creating untracked work through a harness delegation tool.
`bin/fm-subagent-pretool-check.sh` owns the shipped classifier and transport.
`AGENTS.md`, `task-lifecycle`, `delivery-quality`, and `harness-adapters` own when and how legitimate work is dispatched through the fleet.

## Purpose and boundary

A firstmate primary must dispatch crewmates through `bin/fm-spawn.sh` so every task has a recorded endpoint, isolated worktree, status file, brief, supervision path, and teardown path.
Harness-native delegation tools can create work that the fleet cannot see, which makes restart recovery and watcher liveness predicates structurally blind.
The guard blocks the mechanically identifiable event of the primary reaching for a work-creating delegation-shaped tool.
It does not decide whether a request should be delegated, whether a brief is good, or whether a task should be a ship or scout.

## Shipped classifier

A tool name is delegation-shaped when its normalized lowercase name contains one of these stems:

```text
agent  subagent  task  workflow  cron  schedul  worktree
delegate  spawn  dispatch  handoff  remote  sendmessage  monitor
```

Names beginning `mcp__` are excluded because MCP tools are externally named and commonly contain task or agent nouns without creating firstmate fleet work.
The exact names `taskoutput`, `taskstop`, `taskget`, `tasklist`, `cronlist`, `bashoutput`, and `killshell` are excluded because they observe or stop already-existing work rather than creating new work.
The shipped classifier stays shape-based so future delegation tools reach the guard even before a local deny list knows their exact names.

## Scope and escape hatch

The guard fires only in a genuine firstmate primary home as resolved by `bin/fm-primary-scope-lib.sh`.
Plain primary checkouts and marked secondmate homes are in scope.
Linked task worktrees and non-firstmate repositories are out of scope.
Failure to prove scope is inert so a broken environment does not block unrelated tools.

Set `FM_ALLOW_SUBAGENT=1` in the harness process environment before launch for a deliberate exception.
No other value enables the exception.
The variable is process-scoped on purpose: an agent cannot create it for the next tool call from inside the running session.

## Claude local hardening

Claude primaries should also keep an untracked per-home local `permissions.deny` list for known Claude delegation tools.
That list removes tools from the model schema before a hook can be needed, which is stronger than interception.
Do not put the deny list in tracked `.claude/settings.json`, because tracked project settings propagate into linked task worktrees and would remove legitimate crewmate tools.

Recommended local deny entries are:

```json
{
  "permissions": {
    "deny": [
      "Task",
      "Agent",
      "Workflow",
      "RemoteTrigger",
      "Monitor",
      "ScheduleWakeup",
      "SendMessage",
      "EnterWorktree",
      "ExitWorktree",
      "CronCreate",
      "CronDelete",
      "CronList",
      "TaskCreate",
      "TaskGet",
      "TaskList",
      "TaskUpdate",
      "TaskStop",
      "TaskOutput"
    ]
  }
}
```

The shipped hook deliberately remains narrower than this local list so it never strands a runaway task by blocking observe-or-stop tools.
`Task` and `Agent` are both listed because both have been valid Claude deny keys across observed builds.

## Output contract

Allow returns exit 0 with both streams empty.
Deny returns exit 2 and writes the harness-shaped denial object with a `[subagent-dispatch]` message.
Claude mode suppresses stdout because Claude Code only honors a PreToolUse deny when stdout is empty.
Default mode also writes the Grok stdout decision object.
Malformed input, missing tool names, invalid JSON, and missing optional stdin dependencies fail open.

## Harness applicability

Claude has known work-creating delegation tools, so the shipped guard is wired for Claude and the local deny list is recommended.
Codex has been verified not to expose a delegated-agent tool in the checked tool surface, so no Codex hook is wired for this guard.
Grok, OpenCode, and Pi must be wired only after their real tool-name surfaces and hook tokens are verified on a host with the corresponding binary.
Do not guess a matcher from documentation alone.

## Validation

Automated coverage lives in `tests/fm-subagent-pretool-check.test.sh`.
The focused validation command is:

```sh
tests/fm-subagent-pretool-check.test.sh
```

Run `bin/fm-lint.sh` after changing the guard, hooks, or local-hardening guidance.
Historical incident timelines, scratch-project transcripts, and one-off tool listings stay out of this maintained page after their current implementation facts are distilled here.
