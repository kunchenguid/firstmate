# Primary-session delegation guard

This document is the authoritative human-readable contract for the guard that stops a firstmate primary from delegating work outside the fleet.

The shipped mechanism is `bin/fm-subagent-pretool-check.sh`, a PreToolUse guard that denies a delegation-SHAPED tool name in a genuine primary home.
Claude primaries should also use an untracked per-home local `permissions.deny` list as hardening for known Claude delegation tools, because it removes them from the model's schema entirely.
That deny list must not ship in tracked `.claude/settings.json` because it is Claude-only rather than harness-agnostic, and because tracked project settings propagate into linked worktrees where they disarm legitimate crewmates.

## Why this exists

On 2026-07-22 a firstmate primary ran four workers through Claude Code's built-in subagent tool instead of `bin/fm-spawn.sh`.
Three consequences were observed, not hypothesized.

- The fleet view showed zero work under way for the whole run, because no `state/<id>.meta` and no `data/<id>/brief.md` were ever created.
- When the primary session restarted, two of those workers died mid-flight and their work was lost.
  A real crewmate lives in its own backend session with durable state and survives a primary restart.
- The supervision cycle then stayed down for 73 minutes unnoticed, which silently killed the captain's Workflowy intake channel, since that channel only fires while a watch cycle runs.

The deeper defect is that the bypass did not merely skip dispatch, it made the guard stack structurally inert.
Only `bin/fm-spawn.sh` writes `state/<id>.meta`, and every guard keys off that record: `bin/fm-supervision-lib.sh` counts `state/*.meta`, and `bin/fm-turnend-guard.sh` exits silently when that count is zero.
Work started through the harness's own delegation tool writes no metadata, so the in-flight count stayed at zero, the turn-end guard never blocked a blind turn end, and the continuity gate was inert.

That is the reason the fence has to sit on the harness tool surface, before the primary can create untracked work.
No additional guard keyed on task metadata can catch this class of failure, because the failure is precisely the absence of that metadata.

## Purpose and boundary

The guard addresses one concrete, mechanically identifiable event: the primary session reaching for a tool that creates work the fleet will not know about.

It deliberately does **not** address the broader question of whether a given piece of work should be delegated at all.
That question is a judgment boundary over read-and-think work, it has no tool-shape signal, and a hook that tried to police it would degrade into an advisory nag.
The scope line is therefore: wrong tool reached for, deny; wrong amount of thinking done before reaching for a tool, out of scope.

The guard is also not a dispatch-quality check.
It says nothing about whether the resulting brief, project, or delivery mode is correct.

## Shipped mechanism

`bin/fm-subagent-pretool-check.sh` is the shipped layer.
It classifies the tool NAME by shape rather than against a fixed list.
The tracked Claude PreToolUse matcher is `.*`, so every Claude tool name reaches the script and the script is the single owner of classification.
A stem-enumerating matcher would reintroduce the fail-open-by-enumeration problem this guard exists to solve, because any future tool name outside the matcher would be silently missed before the script could inspect it.
A tool is delegation-shaped when its normalized lowercase name contains one of these stems:

```text
agent  subagent  task  workflow  cron  schedul  worktree
delegate  spawn  dispatch  handoff  remote  sendmessage  monitor
```

Two exclusions keep the shape test from producing false positives.

- A name beginning `mcp__` is never classified.
  An MCP server chooses its own tool names, a task or agent noun there is common, and it has no bearing on fleet dispatch.
- The exact names `taskoutput`, `taskstop`, `taskget`, `tasklist`, `cronlist`, `bashoutput`, and `killshell` are allowed.
  These observe or stop work that already exists rather than creating it, and denying them at this layer could strand already-running work with no way to inspect or end it.
  A Claude primary's optional local deny list may still remove them from the schema.
  The shipped guard stays narrower on purpose so it can never be the reason a runaway task cannot be stopped.

The shipped guard fires on every delegation-shaped name that reaches it, including future names that no deny list knows about yet.
That future-name behavior is the reason the tracked matcher must match all tools and let the script filter.

## Recommended Local Claude Deny List

Claude primaries should add this deny list in untracked per-home local settings, never in tracked `.claude/settings.json`:

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

A denied name is removed from the model's schema entirely.
The model is never offered the tool, so there is no call to intercept, no matcher to get wrong, no fail-open path, and no dependence on the model's cooperation.
This is removal, not interception, and it is strictly stronger than any hook.

This list is recommended local hardening because it closes the known Claude surface before the hook is needed.
It is not tracked for two reasons.

- It is Claude-only, so it can never be the harness-agnostic shipped fix.
- A tracked `.claude/settings.json` propagates into linked worktrees and disarms legitimate crewmates.
  This was verified when a Claude session in a task worktree of this repo lost its `Agent` tool.

The width of the list remains a captain-owned decision, because denying some of these changes how the captain works with the primary session.
Keep it as one flat local array that is reviewable at a glance and narrowable in one line.
In particular `TaskOutput`, `TaskStop`, `TaskGet`, `TaskList`, and `CronList` only observe or stop work that already exists, but the recommended local deny list still removes them by default.
The hook deliberately allows those names, so the shipped guard can never strand a runaway task with no way to inspect or end it.

`permissions.allow` is a pre-approval list, not an availability list, so there is no fail-closed positive allowlist available.
That is why any fixed deny list is fail-open against future tools and why the shape-based guard still exists.
The hook cannot re-enable a tool removed from the schema; it only handles a tool name that still reaches PreToolUse.

### Both `Task` and `Agent` are valid deny keys

The tool presents to the model as `Agent`.
A prior investigation recorded that the deny key must be `Task` and that using `Agent` "silently does nothing at all".
That is not what this machine shows.

A five-way A/B with a control, each run in its own directory to rule out settings caching, found that `Task` and `Agent` each independently remove the tool, and that a nonsense name leaves it present.
The full evidence is in the validation record below.

Pinning both names in the recommended local deny list is correct regardless of which build is running.
It costs one line and removes the failure mode where a rename or a rollback silently reopens the surface.

## Scope

The shipped hook fires only in a genuine firstmate primary home, using the shared predicate `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh`.
This is the same predicate `bin/fm-sessionstart-nudge.sh` and `bin/fm-turnend-guard.sh` use, so the three tracked primary-scoped hooks cannot drift apart.

A home is in scope when it has `AGENTS.md`, a `bin/` directory, an existing state directory, and either a plain checkout where git-dir equals git-common-dir or a valid `.fm-secondmate-home` marker.
A marked secondmate home is in scope on purpose: it operates its own fleet and must dispatch through it for the same durability reasons.

A crewmate's disposable task worktree is a linked git worktree, which is the shape `bin/fm-spawn.sh` always hands out, so it is out of scope.
A crewmate using delegation tools inside its own task worktree is legitimate and stays allowed.
A non-firstmate repo is out of scope.
Any failure to confirm the home is inert, never a block, so a broken environment can never deny a tool call.

A local Claude deny list is upstream of hook scope and removes known Claude delegation tools wherever Claude applies it.
Do not put that list in tracked project settings, because linked worktrees inherit those settings and would lose legitimate delegation tools.
The hook scope is the shipped enforcement boundary, and the linked-worktree negative case proves the script itself does not block legitimate crewmate delegation.

## Escape hatch

`FM_ALLOW_SUBAGENT=1` in the session environment allows the call at the shipped hook.
This is the only escape hatch and the guard fails closed on every other value, including empty, `0`, `yes`, and `true`.

It is an environment variable rather than a flag, a config file, or a state file because that makes it unforgeable in-session.
The variable must be present when the harness process is launched, so no tool call the agent makes can enable it for the call that follows.
A deliberate use therefore requires restarting the session with the variable set, which is a conscious act, while an accidental use is impossible.

The escape hatch does not affect any local Claude deny list.
A tool removed from the schema stays removed, so a genuinely intended use of a locally denied tool also requires narrowing or removing that local entry before launch.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[subagent-dispatch] ..."}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[subagent-dispatch] ..."}` to stdout for Grok.
- `--claude` suppresses stdout completely, because Claude Code ignores a PreToolUse deny when stdout is nonempty.
  This is the same verified quirk recorded in [`arm-pretool-check.md`](arm-pretool-check.md), and the tracked Claude hook therefore passes `--claude`.
- Malformed or empty stdin, invalid JSON, a payload with no tool name, and missing `jq` for stdin transport all fail open with exit 0 and no output.

The deny message names the real dispatch path.
When `bin/fm-scout.sh` exists in the home it routes investigation and diagnosis there and ship work to `bin/fm-brief.sh` then `bin/fm-spawn.sh`.
When that script is absent the message degrades to naming `bin/fm-brief.sh` then `bin/fm-spawn.sh` for both, rather than pointing at a script that is not there.

## Harness wiring

Every supported primary harness was reviewed.
Applicability turns on one question: does the harness expose built-in delegation tools that a primary session could use instead of `bin/fm-spawn.sh`?

| Harness | Delegation surface | Status |
| --- | --- | --- |
| Claude | 18 known tools, listed above | Scoped guard wired and live-verified; untracked local deny list verified and recommended. |
| Codex | none | Not applicable, verified empirically below. Codex 0.144.1 exposes no subagent, sub-task, or delegated-agent tool, so there is nothing to remove or intercept. `.codex/hooks.json` is unchanged. |
| Grok | present, exact tokens unconfirmed | Not wired pending live verification. See below. |
| OpenCode | present, exact tokens unconfirmed | Not wired pending live verification. See below. |
| Pi | none reported | Not wired pending live verification. See below. |

### Codex, verified not applicable

Codex 0.144.1 was asked to enumerate its own tools in a scratch git repo on 2026-07-22.

```sh
codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
  "List the exact names of every tool available to you in this session, one per line, nothing else. Then state on a final line whether you have any tool that spawns a subagent, sub-task, or delegated agent: answer SUBAGENT_TOOL=yes or SUBAGENT_TOOL=no."
```

Exact reported tool set and verdict:

```text
web.run
functions.exec_command
functions.write_stdin
functions.list_mcp_resources
functions.list_mcp_resource_templates
functions.read_mcp_resource
functions.update_plan
functions.request_user_input
functions.request_plugin_install
functions.view_image
functions.get_goal
functions.create_goal
functions.update_goal
functions.apply_patch
image_gen.imagegen
tool_search.tool_search_tool
multi_tool_use.parallel
SUBAGENT_TOOL=no
```

`multi_tool_use.parallel` batches calls to the tools above; it does not spawn an agent.
Codex is therefore not applicable today, and this table row is the tripwire: if a future Codex release adds a delegated-agent tool, wire `.codex/hooks.json` the same way its `Bash` PreToolUse entries already forward stdin to a checker.

### Grok, OpenCode, and Pi, inspected but not wired

The integration surface of each was inspected and each is structurally wireable for the shipped guard.

- Grok's tracked hooks (`.grok/hooks/fm-primary-pretool-check.json`, `.grok/hooks/fm-primary-cd-check.json`) use a `PreToolUse` matcher, currently `Bash`, and pipe stdin to a checker.
  The checker already reads Grok's `.toolName` field, so only the matcher token is missing.
  Grok does expose a delegation surface: `docs/supervision-protocols/grok.md` documents `get_command_or_subagent_output(<task_id>)`, which implies a corresponding dispatch tool.
- OpenCode's tracked plugins gate on `input?.tool !== "bash"` inside `tool.execute.before`, and block by throwing.
  Swapping that comparison for a call into this checker with `--tool` is the whole change.
- Pi's tracked extension gates on `event.toolName !== "bash"` inside `pi.on("tool_call", ...)` and blocks by returning `{block: true}`.
  The same change applies. A parallel evaluation reports that Pi exposes no delegation tool at all, which would make it not applicable, but that was not verified here.

None of the three is wired in this change because none of the three binaries is installed on the host where this work was done, so the exact tool-name tokens could not be confirmed and the wiring could not be validated against the real harness.
This repo's rule in the `firstmate-coding-guidelines` skill is that a harness hook must be validated in a scratch project before it is trusted, and `arm-pretool-check.md` records the concrete cost of guessing: a Grok hook whose `command` string is even slightly wrong fails to launch the hook at all.
Wiring an unvalidated matcher would trade a known gap for an unknown breakage.

The bounded follow-up for each is identical to the Codex procedure above.
On a host with the binary installed, ask the harness to enumerate its tools, then wire the matcher and re-run the live matrix below.
`bin/fm-subagent-pretool-check.sh` needs no change for any of them: it already accepts Grok's stdin shape and the `--tool` CLI form OpenCode and Pi use, and it already emits the Grok stdout decision object by default.

## Live validation record, 2026-07-22

Harness version:

```text
2.1.217 (Claude Code)
```

Every run used a scratch project under this task worktree.
No modified file was installed into the primary checkout or a live harness configuration, and no live watcher, fleet state, or task metadata was used.
The launch command throughout was:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
```

### Tool name and matcher mechanics

The tool name delivered to PreToolUse hooks was established before any matcher was written, using a throwaway project whose only hook appended `.tool_name` to a log for matcher `.*`.
It logged `Agent` and `Bash`.
A second project using matcher `^(Task|Agent)$` logged `Agent` only, confirming both the live tool name and that Claude Code honors regex anchors in a PreToolUse matcher.
The tracked matcher is now `.*`, matching the throwaway-project evidence above so any future tool name reaches the script classifier.

### Deny-key A/B, with control

Prompt: `List the exact names of every tool available to you, comma-separated on one line, nothing else.`
Each variant ran in its own fresh directory to rule out settings caching.

| `.claude/settings.json` | `Agent` in tool list? |
| --- | --- |
| `{}` | Yes |
| `{"permissions":{"deny":["Task"]}}` | No |
| `{"permissions":{"deny":["Agent"]}}` | No |
| `{"permissions":{"deny":["ZzzNotARealTool"]}}` | Yes |
| `{"permissions":{"deny":["Task","Agent"]}}` | No |

The nonsense-name control is what makes this conclusive: the tool disappears only when a real name is denied, so the removal is caused by the deny entry rather than by run-to-run variation.
Both `Task` and `Agent` are therefore working deny keys on this build, correcting the earlier claim that only `Task` works.

The observed baseline surface was 29 tools:

```text
Agent, Bash, Edit, Read, ReportFindings, ScheduleWakeup, Skill, ToolSearch, Workflow, Write,
CronCreate*, CronDelete*, CronList*, DesignSync*, EnterWorktree*, ExitWorktree*, Monitor*,
NotebookEdit*, PushNotification*, RemoteTrigger*, SendMessage*, TaskCreate*, TaskGet*,
TaskList*, TaskOutput*, TaskStop*, TaskUpdate*, WebFetch*, WebSearch*
```

A `*` marks a deferred tool, which is lazy-loaded through `ToolSearch` and does not appear in a plain tool list unless the prompt asks for deferred entries.
This distinction matters when reading the next result: a tool absent from a plain listing is not necessarily denied.

### Local deny-list hardening

Run in a scratch firstmate-shaped project containing `AGENTS.md`, `state/`, a full copy of `bin/`, and a Claude settings file containing the recommended local deny-list JSON above.
The result validates the recommended local deny-list JSON above, not tracked repo state.
Asking for deferred entries explicitly returned:

```text
Bash, Edit, Read, ReportFindings, Skill, ToolSearch, Write,
DesignSync*, NotebookEdit*, PushNotification*, WebFetch*, WebSearch*
```

All 18 locally denied names are gone and every ordinary working tool remains, including the five deferred ones.
Comparing against the 29-tool baseline confirms the removal set is exactly the deny list and nothing else.

### Shipped guard, the case a fixed deny list cannot cover

To reproduce a future tool that ships before a local deny list is updated, `Workflow` was removed from the deny list in the same scratch project while the guard stayed wired.

Prompt: `Call the Workflow tool to run any trivial workflow. You must actually attempt the Workflow tool call.`

Claude reported:

```text
I attempted the Workflow tool call as requested. It was blocked by a PreToolUse hook in this repo:

> [subagent-dispatch] the firstmate primary dispatches through the fleet, not the harness's own
> delegation tools... (blocked tool: Workflow). Launch the session with FM_ALLOW_SUBAGENT=1 for a
> deliberate exception.
```

This is the load-bearing result: the shipped guard denied a delegation tool that the deny list did not cover, which is the future-name case the shape classifier exists for.

### Shipped guard scope, the negative case

The same `Workflow` prompt was then run in a `git worktree add` linked worktree of that scratch project, carrying the identical tracked hook and checker bytes, with no escape hatch.

```text
The Workflow tool call was not blocked by a hook. It executed normally: launched, ran 1 agent,
and completed successfully returning {"result":"ok"}.
```

Same hook, same bytes, deny in the primary home and allow in a crewmate-shaped worktree.
This is the scoping contract working end to end rather than a hook that simply never fires.

### Escape hatch

The same `Workflow` prompt in the scratch primary home, launched as `FM_ALLOW_SUBAGENT=1 claude -p ...`:

```text
Result: the Workflow tool call was NOT blocked by a hook. It launched and ran to completion.
```

### Empty-stdout requirement

A Claude deny is honored only when the hook's stdout is empty.
`tests/fm-subagent-pretool-check.test.sh` asserts stdout is empty on every `--claude` deny and that default mode still emits the Grok object on stdout.
The live consequence is confirmed by the shipped-guard result above: Claude honored the deny and reported the reason text.

## Automated validation

`tests/fm-subagent-pretool-check.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
It covers the tracked Claude settings boundary that forbids a `permissions` key; the match-all Claude hook registration; denial of every work-creating delegation tool by shape; denial of twelve hypothetical future tool names that appear on no list; the observe-or-stop and MCP exclusions; the scout-present and scout-absent message variants; the escape hatch including its fail-closed values; inertness in a linked task worktree and in a non-firstmate repo; in-scope enforcement for a marked secondmate home; both stdin transports; the empty-stdout requirement; fail-open transport behavior; and the preserved `Bash` seatbelts and `Stop` guard.

Run:

```sh
bash -n bin/fm-subagent-pretool-check.sh
bin/fm-lint.sh
tests/fm-subagent-pretool-check.test.sh
```

## Known residual gap

This change does not close the deeper harness-agnostic defect.
Every firstmate guard keys off `state/<id>.meta`, and only `bin/fm-spawn.sh` writes that record.
`bin/fm-supervision-lib.sh` counts `state/*.meta`, and `bin/fm-turnend-guard.sh` exits silently at zero.
Unaccounted primary work therefore reads as idle rather than suspicious.

The durable fix for that class is to make the guards treat "the primary is doing project-shaped work with zero `state/*.meta` files" as a suspicious state rather than an idle one.
That would catch this class on any harness, including work created through `Bash`.
This change fences only the Claude tool surface.
That is a separate change to `bin/fm-supervision-lib.sh` and `bin/fm-turnend-guard.sh` and is out of scope here.
