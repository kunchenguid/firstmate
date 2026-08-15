# Project worktree acquisition — end-to-end proof

Real `bin/fm-spawn.sh` and `bin/fm-teardown.sh`, a real tmux server on a private
socket, a disposable `FM_HOME`, and Mathpath's own unmodified
`scripts/worktree-new.sh` + `scripts/sync-main.sh` (copied read-only out of
/home/parsu/firstmate/projects/mathpath) driving a disposable clone named `mathpath`
under /tmp. Mathpath's real checkout was never written to.
`origin/main` was advanced after the primary clone, so the primary starts stale and
the task worktree can only reach the current tip by being freshened.

## The local config — gitignored, one line, literal `<slug>`

```
$ cat "$FM_HOME/config/worktree-acquire/mathpath"
scripts/worktree-new.sh <slug> && cd ../mathpath-worktrees/<slug>
```

## 1. Fresh ship spawn

```
$ fm-spawn.sh fm-worktree-proof-c3 <project> --mode local-only --yolo off
spawned fm-worktree-proof-c3 harness=codex kind=ship mode=local-only yolo=off window=firstmate:fm-fm-worktree-proof-c3 worktree=/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3
```

The task window itself (real tmux `capture-pane`): the already-validated slug is
single-quoted at every placeholder, and Mathpath's own script runs and reports.

```
__fm_worktree_acquire() { scripts/worktree-new.sh 'fm-worktree-proof-c3' && cd ../mathpath-worktrees/'fm-worktree-proof-c3'; }; if __fm_worktree_acquire; then __fm_worktree_acquire_rc=0; else __fm_worktree_acquire_rc=$?; fi; unset -f __fm_worktree_acquire; printf '%s\n' "$__fm_worktree_acquire_rc" > '/tmp/fm-e2e-mathpath-worktree/fm-home/state/.worktree-acquire-fm-worktree-proof-c3.1350875.status.partial' && mv -f -- '/tmp/fm-e2e-mathpath-worktree/fm-home/state/.worktree-acquire-fm-worktree-proof-c3.1350875.status.partial' '/tmp/fm-e2e-mathpath-worktree/fm-home/state/.worktree-acquire-fm-worktree-proof-c3.1350875.status'; unset __fm_worktree_acquire_rc
parsu@LAPTOP-67VJT5A2:/tmp/fm-e2e-mathpath-worktree/mathpath$ __fm_worktree_acquire() { scripts/worktree-new.sh 'fm-worktree-proof-c3' && cd ../mathpath-worktrees/'fm-worktree-proof-c3'; }; if __fm_worktree_acquire; then __fm_worktree_acquire_rc=0; else __fm_worktree_acquire_rc=$?; fi; unset -f __fm_worktree_acquire; printf '%s\n' "$__fm_worktree_acquire_rc" > '/tmp/fm-e2e-mathpath-worktree/fm-home/state/.worktree-acquire-fm-worktree-proof-c3.1350875.status.partial' && mv -f -- '/tmp/fm-e2e-mathpath-worktree/fm-home/state/.worktree-acquire-fm-worktree-proof-c3.1350875.status.partial' '/tmp/fm-e2e-mathpath-worktree/fm-home/state/.worktree-acquire-fm-worktree-proof-c3.1350875.status'; unset __fm_worktree_acquire_rc
  local main fast-forwarded to 9738c17
Preparing worktree (new branch 'fm-worktree-proof-c3')
branch 'fm-worktree-proof-c3' set up to track 'origin/main'.
HEAD is now at 9738c17 advance origin/main after the primary clone
  copied .env.local
  linked node_modules -> primary checkout
✓ worktree ready: /tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3
  branch 'fm-worktree-proof-c3' based on origin/main
  cd "/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3"
  npm run dev -- -p 3000      # run this branch alongside your other instance(s)
  # or open a new Claude session in this directory
  note: shares the primary's node_modules + .env (same DATABASE_URL/DB).
        if this branch changes deps: rm node_modules && npm install
parsu@LAPTOP-67VJT5A2:/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3$ export GOTMPDIR=/tmp/fm-fm-worktree-proof-c3/gotmp
parsu@LAPTOP-67VJT5A2:/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3$ env -u CURSOR_AGENT -u CURSOR_INVOKED_AS codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch '/tmp/fm-e2e-mathpath-worktree/fm-home/state/fm-worktree-proof-c3.turn-ended'\"]" "$('/home/parsu/.no-mistakes/worktrees/3ec255a4fab4/01M01HXJXW8V3T2RJCV8FVZ3N0/bin/fm-operational-input.sh' encode launch-brief < '/tmp/fm-e2e-mathpath-worktree/fm-home/data/fm-worktree-proof-c3/brief.md')"
```

## 2. Resulting state

```
=== state/fm-worktree-proof-c3.meta (task record) ===
window=firstmate:fm-fm-worktree-proof-c3
worktree=/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3
project=/tmp/fm-e2e-mathpath-worktree/mathpath
worktree_provider=project-command
harness=codex
kind=ship
mode=local-only

=== git registration in the primary checkout ===
/tmp/fm-e2e-mathpath-worktree/mathpath                                9738c17 [main]
/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-b2 9738c17 [fm-worktree-proof-b2]
/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3 9738c17 [fm-worktree-proof-c3]

=== task branch identity and freshness ===
attached branch:       fm-worktree-proof-c3
worktree HEAD:         9738c1711f90255e7b8896104a4fe68ac87fece4
fetched origin/main:   9738c1711f90255e7b8896104a4fe68ac87fece4
detached:              no
working tree changes:  0

=== gitignored local material carried in by Mathpath's script ===
.env.local present:    yes   (contents never read or printed)
node_modules:          symlink -> /tmp/fm-e2e-mathpath-worktree/mathpath/node_modules

=== Treehouse never involved ===
treehouse invocations: 0
=== private acquisition-status artifacts left behind ===
leftovers:             0
```

## 3. A retry whose target already exists

A separate task whose target directory was pre-created with unlanded work.

```
=== fm-spawn output on a retry whose target already exists (exit 1 after 1s, poll timeout is 60s) ===
error: project worktree acquisition for '/tmp/fm-e2e-mathpath-worktree/mathpath' exited with status 1 before entering an isolated worktree; any existing or partly-created target is preserved. Inspect window firstmate:fm-fm-worktree-proof-b2, land or deliberately remove that target, then retry

=== nothing was published, nothing was destroyed ===
task record published:  no (none)
existing target kept:   yes
unlanded work intact:   unlanded work that must survive the refusal
treehouse fallback:     0 invocations
status artifacts left:  0
```

## 4. Guarded, provider-aware cleanup

```
$ fm-teardown.sh fm-worktree-proof-c3
teardown: reaping leaked worktree process(es) for fm-worktree-proof-c3: 1350971 1351919
teardown: force-killing leaked worktree process(es) for fm-worktree-proof-c3: 1350971
teardown fm-worktree-proof-c3 complete (window firstmate:fm-fm-worktree-proof-c3, worktree /tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-c3)

=== after guarded teardown of the project-command worktree ===
worktree directory:    removed
task record:           removed
treehouse invocations: 0   (native Git removal; Treehouse never asked)
remaining registrations in the primary checkout:
/tmp/fm-e2e-mathpath-worktree/mathpath                                9738c17 [main]
/tmp/fm-e2e-mathpath-worktree/mathpath-worktrees/fm-worktree-proof-b2 9738c17 [fm-worktree-proof-b2]
primary checkout:      ## main...origin/main
```

_(`fm-worktree-proof-b2` is the deliberately-preserved refusal fixture from step 3;
the entire /tmp sandbox was deleted after this evidence was captured.)_
