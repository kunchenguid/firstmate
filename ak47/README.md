# ak47 hygiene

The factory box's hygiene, as a system rather than a cleanup.

On 2026-11-10 ak47's `/tmp` held **950,700 entries**, 831,000 of them the default
temp directory of a Python or shell test suite that never removed it. The disk
was 14% full, so nothing that watched bytes ever looked. The cost was paid by
every glob, every `ls`, every `find` and every test run on the box, and it
surfaced as load rather than as a disk alert.

The sweeper is the smallest part of the answer. A sweeper that runs forever is a
symptom: it means the producers are still leaking and something has to keep
paying for it. This directory is the rest of the answer.

## The six parts

| # | Part | Where |
|---|------|-------|
| 1 | A budget with numbers | `budget.conf`, rendered by `status.sh` |
| 2 | A producer census that stops growth at source | `census.sh`, `census-producers.conf`, `bin/fm-spawn.sh` |
| 3 | A deterministic tick | `tick.sh`, `units/ak47-devops.timer` |
| 4 | A guard on each producer, and an agent reclaim | `guards/guard-producers.sh`, `guards/cleanup-patterns.conf`, `guards/agent-reclaim.sh`, `units/ak47-agent-reclaim.timer` |
| 5 | Codification and self-monitoring | `hdevops/`, and the tick's own `loop_gap` |
| 6 | A weekly review that proposes diffs | `weekly-review.sh`, `units/ak47-devops-weekly.timer` |

## The commands only Aaron can run

Everything else in this file is code the tick runs as a user unit. These five
things need root, so they are here in one block rather than scattered through the
sections that explain them. Each carries its revert.

```bash
# 1. The task cap. The slice ceiling applies at once; the per-unit default is
#    read when the user manager next starts, because restarting user@1000.service
#    would restart every unit in the slice.
u=ak47/hdevops/ansible/playbooks/templates
sudo install -D -m644 "$u/60-ak47-tasksmax-slice.conf" \
  /etc/systemd/system/user@1000.service.d/60-ak47-tasksmax-slice.conf
sudo install -D -m644 "$u/60-ak47-tasksmax-user.conf" \
  /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf
sudo systemctl daemon-reload
systemctl show -p TasksMax --value user@1000.service          # expect 24576
grep -h DefaultTasksMax /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf
# revert: sudo rm /etc/systemd/system/user@1000.service.d/60-ak47-tasksmax-slice.conf \
#           /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf && sudo systemctl daemon-reload

# 2. systemd-oomd, read fresh. The Nov-10 swap drop-in postdates the running
#    manager, so restarting oomd is what makes it re-read the slice's policy.
sudo systemctl restart systemd-oomd
oomctl | sed -n '/Monitored CGroups/,$p'
# revert: nothing to revert - a restart restores the same policy it read before

# 3. Let oomd actually SEE the slice. Without this, oomctl lists no monitored
#    cgroups at all and every oomd policy on this host is decoration. This is the
#    opt-in one: with it, oomd may kill the largest cgroup under the slice after
#    20s at 50% pressure, and that cgroup can be a worker or the chair.
sudo systemctl set-property --runtime user@1000.service MemoryPressureWatch=on
oomctl | sed -n '/Memory Pressure Monitored CGroups/,$p'      # expect the slice
# persist it: printf '[Service]\nMemoryPressureWatch=on\n' | sudo tee \
#   /etc/systemd/system/user@1000.service.d/60-ak47-oomd-mem.conf && sudo systemctl daemon-reload
# revert: sudo systemctl set-property --runtime user@1000.service MemoryPressureWatch=skip \
#         && sudo rm -f /etc/systemd/system/user@1000.service.d/60-ak47-oomd-mem.conf \
#         && sudo systemctl daemon-reload

# 4. Let the reclaim unit the tick rings stop and start swap. swapoff/swapon are
#    root-only and the unit runs as this user, so today the tick can only report
#    `swap-unprivileged`.
printf 'aaron ALL=(root) NOPASSWD: /sbin/swapoff -a, /sbin/swapon -a\n' \
  | sudo tee /etc/sudoers.d/60-ak47-swap
sudo chmod 0440 /etc/sudoers.d/60-ak47-swap
sudo visudo -c                                                  # expect: parsed OK
# revert: sudo rm /etc/sudoers.d/60-ak47-swap

# 5. The two sysctls, if this box was rebuilt rather than playbooked.
sudo sysctl --system
# revert: sudo rm /etc/sysctl.d/60-ak47-{swap,inotify}.conf && sudo sysctl --system
```

## 1. The budget

`~/.local/state/ak47/status.md` is one screen. Every metric against its ceiling,
with the reason the ceiling is that number. Five seconds to read.

```
$ ak47/status.sh --print
```

| metric | ceiling | why that number |
|--------|---------|-----------------|
| `load15` | 32 | 2x the 32 threads; above it the box is not keeping up |
| `swap_pct` | 50 | the 2026-11-10 lockup ran at 99% swap with 77 GB RAM free |
| `mem_avail_gb` | 15 (floor) | one full test suite plus a browser needs ~15 GB |
| `tmp_entries` | 200,000 | 950k slowed every glob at 14% disk; 200k keeps readdir under a second |
| `tmp_gb` | 20 | a week of live scratch fits in 20 GB; 163 GB was leaked test scratch |
| `root_disk_pct` | 85 | ext4 fragments badly past 85%; 540 GB of headroom remains |
| `tmux_core_pct` | 100 | the tmux server idles at ~74% of one core with 81 panes |
| `agent_count` | 96 | 3 per thread; 2026-11-17 hit load 121 with 218-232 resident agents, because per-agent polling scales with count, not work |
| `home_children` | 6 | 2026-11-17 one secondmate home held 42 child agents and another 29; a home's `config/*-cap` file overrides |
| `pids_pct` | 80 | 2026-11-14 the uid hit 12000 of 12000 tasks and every fork failed for 5 h; 80% is where ordinary bursts still fit |

A ceiling without a reason is a number nobody can defend, so `budget.conf`
refuses to load a row that has none.

## 2. The producer census

Counting is not a census. For every class of growth, the census names the file
and line that creates it, and the fix is at that line.

```
$ ak47/census.sh                 # counts per producer, right now
$ ak47/census.sh --watch 60      # what appeared in 60s, and which pid made it
$ ak47/census.sh --check         # did any producer grow since the baseline?
```

| producer | count | created by |
|----------|-------|-----------|
| `tmp` + 8 chars | 466,233 | Python `tempfile.mkdtemp()` default |
| `tmp.` + 10 chars | 366,414 | shell `mktemp -d` default |
| `uvn-` | 46,348 | `hydra/scripts/tests/test_uvn_status.py:224` |
| `restore-test-` | 5,544 | `core-backend/src/commands/restoreRevertedApprovals.test.js:60` |
| `merge-outcome-` | 3,672 | `hydra/scripts/tests/test_merge_outcome_notify.py:109` |
| `csv-` | 3,105 | `core-backend/scripts/claim-surface-verify.test.js:26` |
| `wc-` | 2,395 | `hydra/scripts/tests/test_uvn_status.py:1683` |
| `twin-req-` | 2,237 | **unattributed** — a mock-GitHub harness, no current checkout |
| `puppeteer_dev_chrome_profile-` | 1,906 | puppeteer/playwright launches |
| `irc-` | 1,770 | `hydra/scripts/tests/test_intercom_reconcile.py:370` |
| `rmtc-` | 2,324 | `core-backend/src/commands/repairMissingTrackCredits.test.js:127` |
| `uvn-lens-` | 534 | `hydra/scripts/tests/test_fraud_lens.py:233` |
| unattributed | 51,260 | — |

The two systemic rows are the ones that matter. 41 of 59 hydra test files call
`mkdtemp` with no `rmtree`, `addCleanup` or `tearDownClass` — 126 call sites.
Fixing them one at a time is a losing game, so the source fix is one line in
`bin/fm-spawn.sh`: every task now gets `TMPDIR=${XDG_CACHE_HOME:-$HOME/.cache}/fm/<id>/tmp`,
and teardown removes that whole root. A leak that lands there is removed by the
task that caused it when the task reaches teardown. Nothing reaps
`${XDG_CACHE_HOME:-$HOME/.cache}/fm/<id>` yet, so a root left by a refused or
aborted spawn stays until removed by hand. A leak that lands in `/tmp` is
removed by nobody.
Tasks spawned before that move still record and clean up their `/tmp/fm-<id>`
root, which is what `orphan-task-scratch` below still reaps when the task record
is gone.

## 3. The tick

`units/ak47-devops.timer` runs `tick.sh --apply` every five minutes. No model, no
tokens, no network. It samples, self-heals an enumerated table of classes, and
writes **one line every run** so silence is provable:

```
2026-11-10T20:51:42Z tick mode=apply tmp_before=953742 tmp_after=953100 moved=642 deleted=0 busy=118 protected=9 failures=0 actions=642 loop_gap=300s classes=tmp-mktemp:610,tmp-producer:32 breaches=tmp_entries=953100>200000 top=tmp:466233,tmp.:366414,uvn-:46348
```

The table is bounded and every action carries its revert:

| class | action | revert |
|-------|--------|--------|
| `tmp-mktemp` | quarantine a leaked default temp dir | `mv` it back from `quarantine/<date>/` |
| `tmp-producer` | quarantine a leaked named producer dir | same |
| `orphan-task-scratch` | quarantine a `/tmp/fm-<id>` with no live task record | same |
| `quarantine-expire` | delete a quarantined entry after 7 days | none — it is already 7 days past its leak |

The four classes in the table are armed by default. `dead-pane`,
`stale-lock` and `disk` are report-only and never act. `swap-pressure` and
`fat-process` are report-only until an operator sets `swap_pressure=1` or
`fat_process=1` in `~/.config/ak47/devops.conf`; once armed, swap-pressure
rings `ak47-swap-reclaim.service` when swap is at 70% or more with 20 GB RAM free,
and fat-process renices the process to 19,
sends `SIGTERM`, and sends `SIGKILL` if it survives five minutes.

The agent wakes only for findings the table cannot settle, and at most once per
six hours per finding key.

### A bounded tick may not call an unbounded sampler

`tmp_gb` needs `du`, and on 2026-11-14 `du` over 698 GB of `/tmp` stopped
finishing at all. The value was cached, the cache went stale, and every run
blocked inside the sampler until systemd killed the unit at its start timeout:
five hours with no `devops.log` line, and nothing watching the tick's silence
closely enough to notice. The tick is the sampler, so a sampler that can hang is
a loop that can die.

The walk now runs under `timeout` (`AK47_DU_BUDGET`, default 300 s): one
whole-tree `du` is tried first, and if it does not finish the walk measures the
top-level entries in batches within half the budget, so a tree too big to finish
still yields a real lower bound with its coverage recorded in `tmp_gb_partial`
(`<entries measured>/<entries present>`) rather than nothing at all. A partial
walk caches its number but does **not** stamp `tmp_gb_ok`: only a walk that
reached every entry counts as a measurement. If the tree stays unmeasured for
longer than two refresh intervals the tick files `tmp-gb-stale` instead of
letting a stale picture drive the sweep. The rule this leaves behind: **a budget
metric whose sample is unbounded must return a number or say it could not
measure** — never block, and never invent.

That finding is one per **episode**, not one per tick. The 6 h key spaces
repeats, and the key is cleared the moment the tree is measurable again, so a
new episode reports immediately instead of waiting out the old window. The
health beat keeps its own keys in `$AK47_STATE/keys/health/` and prunes only
those: on 2026-11-15 it was pruning every key in `$AK47_STATE/keys`, which
deleted the tick's `tmp-gb-stale` key every five minutes and re-paged the same
finding 59 times in a day.

The delete path had the same shape and the same cure. `safe-delete.sh` used
`lsof -t +D` to prove nothing held a quarantined entry; that scan is recursive,
so a quarantine directory worth deleting was exactly the size at which it ran
past the unit's start timeout. The tick now builds **one** in-use set per run
(`ak47_inuse_scan`: a single pass over every process's cwd, root, exe and open
files, ~0.5 s on this box) and tests each candidate against it in constant time.
An incomplete set — one without its completion marker — answers `2` (*could not
tell*), never `1` (*free*), so the failure mode of the optimisation is a refusal
rather than a deletion. Expiry is also bounded per run by
`quarantine_expire_max`, and the tick line carries `expire_pending=` so a
deferred backlog is visible instead of looking like a stuck loop.

### The big-entry take-down

The tick only ever moves a name the producer table enumerates, behind a 24-hour
idle gate. That is the right shape for routine hygiene and it is useless once
`/tmp` has already grown to hundreds of GB: the biggest offenders are
directories no producer row names (a scratch cache, a lane's dump, an eight-GB
`chg/`), and none of them will ever shrink on their own.

`ak47/tmp-takedown.sh` exists for that state, and it is deliberately narrow:

- **size first** - it ranks `/tmp`'s top-level entries by size (one bounded `du`
  per child, never a recursive walk of the whole tree) and works from the top;
- **age, but never age alone** - an entry must be idle for the age gate *and*
  hold no open handle *and* be outside every protected pattern *and* not be a
  live task's scratch root *and* not be a mountpoint;
- **quarantine, never delete** - every entry is renamed into a dated directory
  under the ak47 state dir, and its exact `mv` revert is printed;
- **bounded** - at most `AK47_TAKEDOWN_MAX` entries (default 20) per run.

```
$ ak47/tmp-takedown.sh --dry-run
tmp-takedown: held or unprovable, leaving alone: /tmp/big (rc=0)
tmp-takedown: DRY-RUN would quarantine /tmp/old-junk 7820KB idle=72h
tmp-takedown: moved=0 skipped=4 failures=0 freed_gb=0
```

A run is a decision, not a sweep: the only reason this exists rather than a
config knob on the tick is that the entries worth moving are ones the system
cannot classify, so a human reads the plan before it happens.


## 4. The guards

```
$ ak47/guards/guard-producers.sh
pass static:uvn            test_uvn_status.py still cleans up after itself
fail static:wc             test_uvn_status.py creates wc- and never removes it
pass systemic:per-task-tmpdir  bin/fm-spawn.sh exports a per-task TMPDIR
fail dynamic:py-mkdtemp    py-mkdtemp grew 12,400 since the baseline
pass payload:hdevops       committed payload matches ak47/
```

Four independent checks:

- **static** — a file that matches a `create` pattern must also match a
  `cleanup` pattern. A file absent from the checkout is skipped, not failed.
- **systemic** — `bin/fm-spawn.sh` must still export a per-task `TMPDIR`.
- **dynamic** — `census.sh --check` against a baseline the check never moves. A
  check that rewrites its own reference can only ever see one interval.
- **payload** — the committed H-DevOps payload must match the canonical `ak47/`
  tree. The payload is generated, so a source edit that was not regenerated
  fails here instead of shipping stale code to a rebuild.

Without this, the source fix rots and the sweeper becomes load-bearing again.

### The agent reclaim

Agents are a producer too.
On 2026-11-17 the box reached load 121 on 32 threads with 218-232 resident
agents, dozens of them leftovers whose task no home still recorded or that had
not reported for a day.
The load came from per-agent polling, which scales with how many agents are
resident, not with how much work they do.

```
$ ak47/guards/agent-reclaim.sh --dry-run --print   # what the next run would stop, and why
$ ak47/guards/agent-reclaim.sh --stop-watcher <home>  # a dead home's own watcher, by its recorded pid
```

Every 15 minutes the reclaim maps each resident agent to its home and task, then
stops an orphan (no task record in any home), an idle task (no report for a
day), and the oldest excess over `agent_count` or a home's `home_children` cap,
finished work first.
A working agent, a chair, a secondmate's own agent, a task whose `*.check.sh` is
armed, a task with an unread steering message, a task whose branch has an
unfinished no-mistakes validation, and anything on `~/.config/ak47/reclaim-keep`
is never stopped.
Neither is a task that still holds unfinished work for someone: an open
decision, a last report that is waiting, paused, or awaiting a review, an open
or unreadable PR the task names in its record or its last report (or one on
another forge), or commits on no pushed branch or uncommitted changes to
tracked files.
Every task stop is marked left stopped through `bin/fm-leave-stopped.sh`, so the
fleet watchdog does not relaunch it; a mark that fails is a finding, and without
that mark the box got no lighter, because the watchdog relaunched stopped agents
within five minutes.
It never deletes a worktree, tears down a task, or sends `SIGKILL`; every stop
is one `reap.log` line with its revert, and what it cannot settle is a finding.
The script's header (`--help`) owns the exact classes, vetoes, knobs, and exit
codes.

## 5. Codification and self-monitoring

`hdevops/apply.sh` lands the system in H-DevOps as a PR: the ak47 scripts,
libraries, budget and producer table, the hygiene user timers, the on-demand
swap-reclaim unit, the two sysctls
that were hand-written on the box and recorded nowhere else, systemd-oomd
with its swap and avoid drop-ins, the two task-cap drop-ins described in §5a,
and the health beat that pages on swap and memory pressure as well as load and
the user task cap. The playbook is
`ansible/playbooks/07-ak47-hygiene.yml`, deliberately not in `site.yml` — that
targets the OVH cluster, this targets one workstation.

The payload under `hdevops/ansible/playbooks/files/ak47/` is generated from the
canonical `ak47/` tree by `apply.sh`; never edit it by hand. `apply.sh --check`
diffs the committed payload against a fresh generation, and
`apply.sh --write-payload` regenerates it. The guard's `payload` check runs the
same comparison, so CI fails when a source edit was not regenerated.

The tick watches its own log freshness. A `loop_gap` over three intervals is a
finding, because a loop that dies silently is worse than no loop. It also flags
a report-only class that has outlived its 24 h dry run, so the "then armed" step
cannot be forgotten; it never arms itself.

A finding's dedupe key is committed only after the chair-inbox note is actually
delivered. A key touched before a failed send would silence the finding for six
hours, so a failed delivery is logged as `DELIVERY-FAILED` and retried next tick.

## 5a. The task cap that stopped the box

On 2026-11-14 the uid reached `pids.max` 12000 at 02:49Z and stayed there until
08:04Z. Every `fork()` returned `EAGAIN`, so the watcher, every worker shell and
every check failed to start for five hours. Nothing paged: tasks are cheap, so
load, swap and available RAM all stayed inside their ceilings while the uid was
already unable to fork.

The tasks were in tmux child-pane scopes, not in a service. Three scopes
accounted for it (`tmux-spawn-c2f9b92f` peaked at 138,696 tasks, `-b4f3563c` at
41,025, `-457529e5` at 7,758), and the frame was only the frame: the cap was the
only bound, 12000 was barely above the ~4,600 the slice normally runs, and no
unit inside the slice was capped at anything — each inherited 140,836 and shared
nothing, so one lane could take the whole uid.

Three changes, all landed by `hdevops/ansible/playbooks/07-ak47-hygiene.yml`:

1. **A per-unit default** — `/etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf`
   sets `DefaultTasksMax=4096`. This is the change that matters: transient tmux
   pane scopes have no drop-in path, and the user manager's default is the only
   place a per-unit cap can reach them. 4096 is four times the largest
   legitimate lane measured here (the biggest real pane held ~950 tasks), and a
   sixth of the slice cap.
2. **A slice cap with room** — `/etc/systemd/system/user@1000.service.d/60-ak47-tasksmax-slice.conf`
   sets `TasksMax=24576`, six times the per-unit default. Raising it alone would
   have moved the cliff, not removed it, so both land together.
3. **An alert at 80% of the cap** — `ak47-health.sh` pages at 80% and writes
   `~/.local/state/ak47/tasks-latest.md` naming the scopes holding the tasks;
   `pids_pct` is also a budget row, so the tick samples it every five minutes
   and the weekly review can propose moving it.

### Why systemd-oomd does not watch this host, and the one line that changes it

The swap drop-in is installed and `systemctl show user@1000.service` reports
`ManagedOOMSwap=kill`, yet the 2026-11-10 lockup ran at 99% swap and oomd did
nothing, and `oomctl` lists **no** monitored cgroups. Three verified reasons:

1. **The slice is not watched.** `user@1000.service` resolves
   `MemoryPressureWatch=skip`, so the kernel collects no memory pressure (PSI)
   for it. oomd acts on pressure readings; with no reading there is nothing to
   act on. The packaged
   `/usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf`
   sets `ManagedOOMMemoryPressure=kill` and a 50% limit, which is why the policy
   looks armed — but the policy alone does not start the watch.
   Proven on this box: a transient scope started with
   `-p MemoryPressureWatch=on -p ManagedOOMMemoryPressure=kill` appears in
   `oomctl` under "Memory Pressure Monitored CGroups" with live `Avg10`; the same
   scope without the watch does not.
2. **Swap pressure does not exist on this kernel.** `/proc/pressure/` has `cpu`,
   `io` and `memory` and nothing else, so `ManagedOOMSwap=kill` can never fire
   here. oomd's `Swap Used Limit: 90%` is the only swap lever and it is not
   per-cgroup, so a slice that swaps instead of paging stays invisible.
3. **The drop-in postdates the unit.** `user@1000.service` entered active at
   2026-11-05 19:42 and the swap drop-in was installed 2026-11-10, so the running
   unit has never read it. `daemon-reload` alone does not re-apply service
   properties to a running unit.

**Swap reclamation needs root, and time.** The five-minute tick cannot do it at
all: `swapoff -a` on a full 32 GB swap has to find a home in RAM for tens of
gigabytes of pages, which takes tens of minutes, so an inline reclaim would be
killed at the tick's start timeout — halfway through, which is exactly the state
the always-restore rule exists to avoid. So the reclaim is now its own unit,
`ak47-swap-reclaim.service`, and the tick only rings it with `--no-block` and
records that it rang it. The unit owns the operation: bounded swapoff, swap back
on whatever happened, one line in `swap.log`, and a finding when it could not
finish. Both commands are root-only and the tick runs as a user unit, so it would
otherwise WARN and count a failure every tick on a full swap while swap stayed
full. It now proves the capability with `swap_privileged`
by running one of the commands the sudoers rule actually grants, and files
`swap-unprivileged` — the one line Aaron needs, not a transient error. A failed
restore after a successful `swapoff` is reported as a failure rather than
swallowed, because that leaves the box with no swap.
The 2026-11-14 reclaim was run by hand and took swap from 31.9 GB of 31.9 GB to
0 (RAM 69 GB used, 54 GB available). To let the tick's reclaim unit do it,
install the sudoers rule in item 4 of [The commands only Aaron can run](#the-commands-only-aaron-can-run).

Aaron's call, not the tick's — enabling the watch lets oomd kill the largest
cgroup under the slice after 20 s at 50% pressure, and that cgroup can be a
worker, a lane, or the chair. The runtime opt-in, the persisted drop-in, and
their reverts are item 3 of the same block.

The per-unit default is read when the user manager starts, and restarting
`user@1000.service` would restart every unit in the slice — the fleet-wide
disruption this change exists to prevent. So it applies at the next login; the
slice cap applies without one. The install and revert lines, if applying by
hand, are item 1 of [The commands only Aaron can run](#the-commands-only-aaron-can-run).
The bound returns to 12000 on the next unit start; nothing is restarted either
way.

## 6. The weekly review

`units/ak47-devops-weekly.timer` runs `weekly-review.sh` on Monday at 09:00. It
reads its own `samples.log`, computes p05/p50/p95/max per metric, and proposes a
unified diff against `budget.conf`:

- **raise** when p95 sits within 20% of a `max` ceiling, or p05 within 20% of a
  `min` floor — the ceiling is about to be the thing that pages
- **lower** when p95 is below half a `max` ceiling, or p05 is more than twice a
  `min` floor — the ceiling has drifted away from what the box does

It writes the diff to `~/.local/state/ak47/review-<date>.diff` and files it. It
never applies it, never adds a class to the tick's table, and never widens its
own authority. A new action class needs the captain's word.

### The review holds a ceiling it cannot justify

The first live review proposed `swap_pct|126` (a percentage above 100),
`tmp_gb|1` (lowered to the zero its sampler writes when the size walk fails) and
`load15|39` from 14 samples in a week — because the loop had been dead. Each of
those would have made the box worse: a ceiling at 100% pages forever, a 1 GB
`/tmp` ceiling pages every tick, and a ceiling moved on 14 samples is a number
invented. So the review now holds a row and says why, in the diff, where the
next reader sees it:

- **fewer than 168 samples** (one an hour for a week at the five-minute
  interval) — `HELD load15: only 14 sample(s), fewer than 168`;
- **a percentage whose p95 sits at its own maximum** — a raise cannot help, and
  the honest output is "sustained at ceiling", not 126%;
- **p95 of zero against a non-zero peak** — the sampler is not measuring, so the
  value is missing, not quiet;
- **a proposed raise that would sit below the observed peak** — that ceiling is
  breached again the moment the box repeats itself.

`HELD` rows and `CHANGE` rows are printed separately, and a review with only
`HELD` rows still writes its diff, so a quiet review and a suppressed one never
look the same.

## Safety

`/tmp` is load-bearing on this box. The tick refuses before it deletes:

- **Never by age alone.** A candidate must match a producer pattern *and* be
  older than its class threshold *and* be held by no live process.
- **Never a live task's scratch.** `/tmp/fm-<id>` from a pre-move task is protected while
  `state/<id>.meta` exists.
- **Never a named protected path.** `/tmp/fm-move`, `/tmp/ak47-*`, the `:8317`
  forwarder, `orcad-*`, `systemd-*`, `snap*`, X11 sockets and locks, and anything
  matching `*router*.sh`, `*forward*`, `cli-proxy*`, `*.token`.
- **Never anything a running process holds.** One `/proc` scan collects every
  top-level `/tmp` name any live process has as its cwd, root, exe, or an open
  file descriptor. That set is checked twice: once in the classifier, once again
  immediately before the move.
- **Never a mount point.** The kernel's octal-escaped mount table is decoded
  before comparison.
- **Never a path spelled two ways.** Every path comparison canonicalises *both*
  sides with `realpath -m` and prints both spellings when they differ. A safety
  check that compares paths must first prove both sides spell the path the same
  way.

Deletion is two-phase: a candidate is `mv`'d into
`~/.local/state/ak47/quarantine/<date>/` and only deleted after
`quarantine_days`. The `mv` is the revert, and it is printed on the log line.

The tick never signals the tmux server, `orca-serve`, `cli-proxy-api`,
`kube-tunnel-node1`, or the chair. It never reboots. It never runs PromQL
locally — the box has no route to cluster ClusterIPs.

### Proof that it refuses

Run against a real tree under `/tmp`, with every age gate set to `0` so nothing
is spared by time. The two holders are real processes; the two records are the
real gates.

```
$ ls /tmp/ak47-demo
drain-old  fm-livetask  fm-move  spelled-fm-move  tmpa003ltt_
           tmp.abcdefghij  uvn-abc123

# a process sitting in tmpa003ltt_, a process with a file open in
# tmp.abcdefghij, a live task record for fm-livetask, and a symlink spelled
# /tmp//ak47-demo/fm-move (two slashes) that resolves to the protected fm-move
$ ( cd /tmp/ak47-demo/tmpa003ltt_ && sleep 40 ) &
$ ( exec 3</tmp/ak47-demo/tmp.abcdefghij/open.txt; sleep 40 ) &
$ printf 'window=x:fm-livetask\n' >$FM_HOME/state/livetask.meta
$ ln -s /tmp//ak47-demo/fm-move /tmp/ak47-demo/spelled-fm-move

$ ak47/tick.sh --apply
$ ls /tmp/ak47-demo
drain-old  fm-livetask  fm-move  spelled-fm-move  tmpa003ltt_  tmp.abcdefghij
$ ls ~/.local/state/ak47/quarantine/*/
uvn-abc123

tick mode=apply tmp_before=7 tmp_after=6 moved=1 deleted=0 busy=2 \
     protected=1 failures=0 actions=1 classes=tmp-producer:1
```

It declined the directory a process was sitting in, the directory a process had
a file open in, the live task's scratch root, the protected `fm-move` name, and
the symlink whose two-slash spelling canonicalises onto it. It left `drain-old`
alone because no producer row names it: an unenumerated class is never acted on.
It quarantined the one entry nothing held. `tests/ak47-tick.test.sh` runs this as
a test, in both directions, for every protected path and every producer prefix.

### Measured so far

The loop has been armed since 2026-11-10T21:20Z. This is the trend, not a
snapshot; the 7-day acceptance gate is 2026-11-17.

| metric | first tick | latest tick | ceiling |
|--------|-----------|-------------|---------|
| `/tmp` entries | 954,210 | 117,171 | 200,000 |
| load15 | 18.03 | 17.02 | 32 |
| swap | 44% | 44% | 50% |
| `tmp_gb` | 162 | 110 | 20 |

Every entry that left `/tmp` is in `~/.local/state/ak47/quarantine/<date>/` with
its `mv` revert, deleted only after seven days. `devops.log` has one line per
run, so the trend is provable without a second source.

## Install

```
$ ak47/install.sh --dry-run     # show every action
$ ak47/install.sh               # install, run one tick and one dry-run reclaim, record the baseline
$ ak47/install.sh --uninstall   # remove the units, keep every log
```

## Configuration

`~/.config/ak47/devops.conf`, seeded by `install.sh` with every key set to its
default. Absent keys take the default in the right-hand column.

| key | default | what it does |
|-----|---------|--------------|
| `tmp_mktemp_min` | 1440 | minutes a leaked default temp dir must be idle before it is quarantined |
| `tmp_producer_min` | 1440 | the same, for a named producer prefix (`uvn-`, `wc-`, `irc-`, ...) |
| `orphan_min` | 10080 | minutes a `/tmp/fm-<id>` with no live task record must be idle |
| `quarantine_days` | 7 | days a quarantined entry is kept before it is deleted for good |
| `tmp_max_entries` | 5000 | stop working once `/tmp` is back under this many entries |
| `tmp_max_moves` | 2000 | the most entries one run may move |
| `quarantine_expire_max` | 200 | the most expired entries one run may delete; the rest wait, and the line says how many |
| `swap_pressure` | 0 | arm the swap-pressure class: reclaim swap when RAM is free |
| `fat_process` | 0 | arm the fat-process class: renice, `SIGTERM`, then `SIGKILL` after 5 min |
| `fat_process_gb` | 3 | the RSS a process must hold to count as fat |
| `fat_process_min` | 10 | minutes a fat process must hold it before it is reported |
| `interval_seconds` | 300 | the timer's period, so the tick can notice its own loop has stopped |
| `reclaim_*` | see `--help` | the agent reclaim's thresholds; `guards/agent-reclaim.sh --help` owns the list |

A fat process that ignores `SIGTERM` is `SIGKILL`ed after five minutes. The
escalation clock is `~/.local/state/ak47/fat.term`, so it survives across ticks,
and a dry run neither kills nor consumes the record.

The per-task `TMPDIR` and its `config/task-tmpdir` opt-out are firstmate
configuration, owned by [`docs/configuration.md`](../docs/configuration.md#per-task-temporary-directory-configtask-tmpdir).

## Tests

```
$ bin/fm-test-run.sh tests/ak47-*.test.sh
```

139 tests across eight files: the budget, the census, the guards, the agent
reclaim, the guarded delete, the big-entry take-down, the tick, and the weekly
review. They are
hermetic — no tmux, no network, no live fleet state — and registered as
`pure-contract-unit` in `bin/fm-test-run.sh`.

## Acceptance, after 7 days

- `/tmp` entries under 200,000 and **stable**, not merely swept
- `load15` under 32 at p95
- swap under 50%
- the producer census shows zero unexplained growth

Report the trend, not a snapshot. `weekly-review.sh` is what produces it.
