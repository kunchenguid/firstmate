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
| 4 | A guard on each producer | `guards/guard-producers.sh`, `guards/cleanup-patterns.conf` |
| 5 | Codification and self-monitoring | `hdevops/`, and the tick's own `loop_gap` |
| 6 | A weekly review that proposes diffs | `weekly-review.sh`, `units/ak47-devops-weekly.timer` |

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
| `agent_count` | 160 | 160 agents is where per-agent CPU share crosses the load ceiling |

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
`bin/fm-spawn.sh`: every task now gets `TMPDIR=/tmp/fm-<id>/tmp`, and teardown
removes that whole root. A leak that lands there is removed by the task that
caused it. A leak that lands in `/tmp` is removed by nobody.

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

Report-only classes (`dead-pane`, `swap-pressure`, `fat-process`, `stale-lock`,
`disk`) never act. `swap-pressure` and `fat-process` are armed only by an
operator setting them to `1` in `~/.config/ak47/devops.conf`.

The agent wakes only for findings the table cannot settle, and at most once per
six hours per finding key.

## 4. The guards

```
$ ak47/guards/guard-producers.sh
pass static:uvn            test_uvn_status.py still cleans up after itself
fail static:wc             test_uvn_status.py creates wc- and never removes it
pass systemic:per-task-tmpdir  bin/fm-spawn.sh exports a per-task TMPDIR
fail dynamic:py-mkdtemp    py-mkdtemp grew 12,400 since the baseline
```

Three independent checks:

- **static** — a file that matches a `create` pattern must also match a
  `cleanup` pattern. A file absent from the checkout is skipped, not failed.
- **systemic** — `bin/fm-spawn.sh` must still export a per-task `TMPDIR`.
- **dynamic** — `census.sh --check` against a baseline the check never moves. A
  check that rewrites its own reference can only ever see one interval.

Without this, the source fix rots and the sweeper becomes load-bearing again.

## 5. Codification and self-monitoring

`hdevops/apply.sh` lands the deployment in H-DevOps as a PR: the two user timers
and the two sysctls that were hand-written on the box and recorded nowhere else.
The playbook is `ansible/playbooks/07-ak47-hygiene.yml`, deliberately not in
`site.yml` — that targets the OVH cluster, this targets one workstation.

The tick watches its own log freshness. A `loop_gap` over three intervals is a
finding, because a loop that dies silently is worse than no loop.

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

## Safety

`/tmp` is load-bearing on this box. The tick refuses before it deletes:

- **Never by age alone.** A candidate must match a producer pattern *and* be
  older than its class threshold *and* be held by no live process.
- **Never a live task's scratch.** `/tmp/fm-<id>` is protected while
  `state/<id>.meta` exists.
- **Never a named protected path.** `/tmp/fm-move`, `/tmp/ak47-*`, the `:8317`
  forwarder, `orca-*`, `systemd-*`, `snap*`, X11 sockets and locks, and anything
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

A tree that is known to be live, with every age gate set to `0` so nothing is
spared by time:

```
$ ls /tmp/ak47-demo
fm-livetask  fm-orphan9  tmp.abcdefghij  tmpa003ltt_  uvn-abc123

# a process sitting in tmpa003ltt_, a process with a file open in
# tmp.abcdefghij, and a live task record for fm-livetask
$ ( cd /tmp/ak47-demo/tmpa003ltt_ && sleep 20 ) &
$ ( exec 3</tmp/ak47-demo/tmp.abcdefghij/open.txt; sleep 20 ) &
$ touch $FM_HOME/state/livetask.meta

$ ak47/tick.sh --apply
$ ls /tmp/ak47-demo
fm-livetask  tmp.abcdefghij  tmpa003ltt_
$ ls ~/.local/state/ak47/quarantine/*/
fm-orphan9  uvn-abc123
```

It declined the directory a process was sitting in, the directory a process had
a file open in, and the live task's scratch root. It quarantined the two that
nothing held. `tests/ak47-tick.test.sh` runs this as a test, in both directions,
for every protected path and every producer prefix.

## Install

```
$ ak47/install.sh --dry-run     # show every action
$ ak47/install.sh               # install, run one tick, record the baseline
$ ak47/install.sh --uninstall   # remove the units, keep every log
```

## Configuration

`~/.config/ak47/devops.conf`, seeded by `install.sh` with every key commented
out. Absent keys take the default in the right-hand column.

| key | default | what it does |
|-----|---------|--------------|
| `tmp_mktemp_min` | 1440 | minutes a leaked default temp dir must be idle before it is quarantined |
| `tmp_producer_min` | 1440 | the same, for a named producer prefix (`uvn-`, `wc-`, `irc-`, ...) |
| `orphan_min` | 10080 | minutes a `/tmp/fm-<id>` with no live task record must be idle |
| `quarantine_days` | 7 | days a quarantined entry is kept before it is deleted for good |
| `tmp_max_entries` | 5000 | stop working once `/tmp` is back under this many entries |
| `tmp_max_moves` | 2000 | the most entries one run may move |
| `swap_pressure` | 0 | arm the report-only swap-pressure class |
| `fat_process` | 0 | arm the report-only fat-process class |
| `fat_process_gb` | 3 | the RSS a process must hold to count as fat |
| `fat_process_min` | 10 | minutes a fat process must hold it before it is reported |
| `interval_seconds` | 300 | the timer's period, so the tick can notice its own loop has stopped |

`bin/fm-spawn.sh` reads one more file, `config/task-tmpdir` in the firstmate
home. It is absent by default, which means every task gets its own `TMPDIR`
under `/tmp/fm-<id>/tmp`. Write `off` into it to restore the old behaviour.

## Tests

```
$ bin/fm-test-run.sh tests/ak47-*.test.sh
```

68 tests across six files: the budget, the census, the guards, the guarded
delete, the tick, and the weekly review. They are hermetic — no tmux, no
network, no live fleet state — and registered as `pure-contract-unit` in
`bin/fm-test-run.sh`.

## Acceptance, after 7 days

- `/tmp` entries under 200,000 and **stable**, not merely swept
- `load15` under 32 at p95
- swap under 50%
- the producer census shows zero unexplained growth

Report the trend, not a snapshot. `weekly-review.sh` is what produces it.
