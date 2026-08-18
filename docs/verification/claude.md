# Verification: the claude (Claude Code) autonomous launch

Active empirical evidence for the `--permission-mode auto` launch in `bin/fm-spawn.sh`'s claude template.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `2.1.234 (Claude Code)` |
| Verified | 2026-08-18 |
| Platform | Linux x86_64, effective UID 0, herdr and tmux panes |
| Account | Claude Max, Anthropic API path |

Every command below ran as root on the same host, either from the firstmate crewmate's own pane or inside a throwaway tmux server, so no fleet home or captain configuration was touched.

## Verified facts

### The bypass flag is refused under root

Claude Code refuses to start with `--dangerously-skip-permissions` when the effective UID is 0, before any model call:

```
$ id -u
0
$ claude --version
2.1.234 (Claude Code)
$ claude --dangerously-skip-permissions -p 'reply with the single word OK' --model claude-haiku-4-5-20251001
--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons
```

`--permission-mode bypassPermissions` is documented as the equivalent spelling and carries the same refusal.

### `--permission-mode auto` launches as root and reports auto mode

Two idle interactive sessions were started in a scratch tmux server from a trusted worktree, with the crewmate's own `CLAUDECODE`, `CLAUDE_CODE_*`, `CLAUDE_PID`, and `HERDR_*` variables unset so each probe was an ordinary top-level launch:

```
$ tmux -L fmprobe new-session -d -s probe -n fable -x 170 -y 45 -c "$WT" \
    'env -u CLAUDECODE ... CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --permission-mode auto --model claude-fable-5'
$ tmux -L fmprobe new-window -d -t probe: -n haiku -c "$WT" \
    'env -u CLAUDECODE ... CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --permission-mode auto --model claude-haiku-4-5-20251001'
$ sleep 12; tmux -L fmprobe capture-pane -p -t probe:fable; tmux -L fmprobe capture-pane -p -t probe:haiku
```

Observed footers, trimmed to the mode indicator:

```text
fable:  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents                    ◈ max · /effort
haiku:  ⏸ manual mode on · ? for shortcuts · ← for agents          auto mode unavailable for this model
```

Neither probe showed a trust dialog or an acceptance dialog in that trusted worktree.
The Fable session honored the flag; the Haiku session started in Manual mode with no error, which is the documented silent fallback when auto mode is unavailable for the model.
Both were exited with `/exit` and the scratch server was killed.

### Ordinary crewmate work runs unattended under auto mode

The crewmate that produced this record ran as root in a herdr pane under `claude --permission-mode auto --model claude-fable-5 --effort high <brief>` and completed its task without a single refused tool call: shell reads and greps, in-worktree edits through heredocs and short scripts, appends to the fleet status file outside the worktree, `git checkout -b`, `git add`, and `git commit`, `bin/fm-test-run.sh`, `bin/fm-lint.sh`, `no-mistakes doctor`, a read-only `curl` fetch, a nested `claude -p` launch, one subagent, scratch files under `/tmp`, and a scratch tmux server driven with `send-keys`.
Two documented default-block shapes were probed deliberately against session-created scratch state and were both allowed, which shows the classifier judges context rather than matching a fixed denylist:

```
$ git init -q -b main . && git commit -q -m 'probe: initial' && echo two >> f.txt
$ git reset --hard HEAD
HEAD is now at caa60ed probe: initial
$ rm -rf automode-probe* && echo 'wildcard rm ran'
wildcard rm ran
```

### Documented reference

Claude Code's [permission-modes reference](https://code.claude.com/docs/en/permission-modes) is the current owner of what auto mode blocks and allows by default, of the model and plan requirements, and of the repeated-block fallback (3 consecutive or 20 total blocks pause auto mode and resume prompting).
`claude auto-mode defaults` prints the installed version's rule lists as JSON.

## Still unproven

- The repeated-block park in an unattended crewmate pane: its exact rendering, and whether `bin/fm-send.sh <window> --key Enter` resumes it the way it accepts a trust dialog.
- A claude secondmate's own `bin/fm-spawn.sh`, `bin/fm-pr-merge.sh`, and `fm-send` steers under the classifier, whose documented defaults name unapproved PR merges and unsandboxed agent loops.
- The one-time terminal notice Claude Code shows the first time a session starts in auto mode on a machine that has never seen it; this host had already recorded it, so the post-spawn peek in the harness-adapters skill remains the guard.

## Refresh procedure

Rerun the three verified-fact blocks above after upgrading Claude Code or changing the claude launch template, and update the version, date, and footers here.
The launch string itself is pinned by `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-secondmate-harness.test.sh`, and `tests/fm-backend-orca.test.sh`.
