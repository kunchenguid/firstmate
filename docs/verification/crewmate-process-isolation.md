# Crewmate process isolation verification

Audience: maintainer verification.

This record supports the launch-prompt shape in `bin/fm-spawn.sh` (`BRIEF_POINTER_TEXT`), the live-agent gate in `bin/fm-task-inbox-lib.sh` (`fm_task_inbox_ring`), and the process rule in `bin/fm-brief.sh`'s scaffold.
It records only the empirical facts those guarantees rest on, all of which are harness-observable and must be re-established when a harness changes.
Incident chronology and transcript excerpts stay in the private task report and PR evidence.

The portable regressions are `tests/fm-spawn-brief-argv.test.sh`, `tests/fm-worktree-ownership.test.sh`, and the doorbell pair in `tests/fm-task-inbox.test.sh`.
They pin the logic with real processes and no credentials; the facts below are what a real harness contributes and no fixture can prove.

## A prompt passed as an argument is matchable process text

Verified 2026-08-29 against Claude Code 2.1.251, tmux 3.5a, treehouse v2.2.1 on Linux.

A command substitution's result becomes one argv element, so the pre-fix launch line put the whole brief into the agent's own `/proc/<pid>/cmdline`.

```
$ printf '  cmdline bytes for pid %s: %s\n' "$CLAUDE_PID" "$(wc -c < /proc/$CLAUDE_PID/cmdline)"
  cmdline bytes for pid 2187488: 12455
```

Any word of that brief then selects the agent itself. With a worker launched the pre-fix way from a brief naming a project script:

```
$ ps -ef | grep "[z]qreprosentinel7x" | awk '{printf "pid=%-9s cmd=%.20s\n", $2, $8}'
pid=2700663   cmd=claude
```

The only match is the agent process, not the script the pattern names.
This is why an ordinary cleanup idiom - `pkill -f <script>`, or `ps -ef | grep <script> | awk '{print $2}' | xargs -r kill` - reaches other workers' sessions rather than their child processes.
Claude Code ships a `pkill` wrapper that refuses a pattern matching its own session, but it does not see sibling sessions and does not cover the `xargs kill` form, so it is not a substitute for keeping the text out of argv.

## An externally signalled agent exits gracefully and leaves a shell

Same date and versions. `kill <pid>` (SIGTERM, exactly what `xargs -r kill` sends) against the matched agent produced no error output and this transcript tail:

```
record types at tail: ['user', 'attachment', 'assistant', 'assistant', 'system', 'bridge-session', 'cost-state', 'last-prompt', 'cost-state']
cost-state present: totalCostUSD=0.5040 totalDuration=83559ms
```

and left the pane here:

```
Resume this session with:
claude --resume b1e991a9-0857-4bed-bbea-1888b27df13f
bash-5.2$
```

Two consequences the code depends on.
A session lost this way is indistinguishable from an ordinary clean exit by its own records - no error, no limit, ample remaining context - so a graceful shutdown record is not evidence that nothing killed the agent.
And the endpoint's owner afterwards is the worker's shell at a prompt, which is what makes an unguarded doorbell delivery execute as a shell command; `fm_task_inbox_ring` refuses on the `dead`/`missing` verdicts for that reason.

## A pointer prompt removes the match and still delivers the task

Same date and versions, same lab, launching the fixed way with the brief on disk and only the pointer sentence in argv:

```
$ ps -ef | grep -c "[z]qreprosentinel7x"
0
```

The agent remained alive and working through the pattern that had killed its predecessor.
Its transcript confirms the pointer is sufficient on its own: the first prompt is the encoded pointer, and the agent read the named brief and began its first instruction without further input.

```
FIRST PROMPT (argv): ⁣FIRSTMATE_OP: v1 launch-brief: Read the brief at <lab>/briefA.md and follow it exactly. It is your enti…
read the brief file: True
bash commands it started: ['cat <lab>/briefA.md', 'sleep 240; echo done', ...]
```

## Per-harness pointer delivery

The launch templates in `bin/fm-spawn.sh` all place the prompt in the same argv slot, so the mechanism is harness-independent; what each harness contributes is whether its agent acts on a pointer rather than an inlined brief.
Verified 2026-08-29 by launching each installed harness with only the pointer sentence in argv and a brief on disk whose whole task was to create one named file.

| harness | version | outcome |
| --- | --- | --- |
| claude | 2.1.251 | read the brief and began its first instruction |
| codex | codex-cli 0.149.0 | read the brief and created the named file |
| pi | 0.84.2 | read the brief and created the named file |

`kimi` is unverified here only because it is not installed on this host; it has always been launched from a pointer, and `kimi_delivery_is_confirmed` in `bin/fm-spawn.sh` greps the sentence's leading `Read the brief at` verbatim, so the shared sentence must keep that prefix.
`opencode`, `grok`, `cursor`, and `muse` are likewise unverified for pointer delivery and should be exercised with the lab shape below when next installed.

Re-establish all sections after a harness upgrade, and extend them to any harness whose launch template changes, using the same lab shape: one worker launched from a brief containing a unique sentinel, one pattern match against that sentinel, then a kill by explicit verified PID.
