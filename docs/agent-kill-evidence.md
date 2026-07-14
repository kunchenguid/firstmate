# Agent kill evidence

What firstmate records so a SIGKILLed agent explains itself, and what macOS actually exposes to record.
Everything below was probed on a real machine and pasted verbatim; nothing here is inferred from documentation.

Probed 2026-07-14 on macOS 26.5.2 (25F84), Darwin 25.5.0 arm64 (Mac15,7), SIP enabled, user `bytedance` (no root).

## Why

On 2026-07-14 several crewmate agents died with `signal: killed` - one at spawn, one mid no-mistakes fix run.
Firstmate told the captain the cause was memory exhaustion, citing free RAM read off a shell after the fact.
The kill was proven; the cause was not, and the postmortem (`data/nm-6951-postmortem-r6/report.md`) rejected the claim.
The fleet had no way to tell an OOM kill from any other SIGKILL, so any fix aimed at memory would have been a guess.
This is the instrumentation that closes that gap.
It collects evidence only: it does not prevent kills, cap concurrency, or tune memory.

## The pieces

| Piece | What it does |
| --- | --- |
| `bin/fm-resource-lib.sh` | memory snapshot, agent-pid resolution, sample-log trimming |
| `bin/fm-resource-sample.sh` | one sampling pass; also the death detector |
| `bin/fm-agent-postmortem.sh` | the evidence record written at a death |
| `bin/fm-watch.sh` | runs the sampler each poll; carries the recorded cause into the stale wake |
| `bin/fm-crew-state.sh` | carries the recorded cause into every state line for that task |

Per-task artifacts under `state/`: `<id>.resource` (samples), `<id>.agentpid` (live agent pid), `<id>.postmortem` (the verdict; `.prev` when an agent is relaunched).
`bin/fm-teardown.sh` removes them with the task.
Each script's header owns its own contract; this doc owns the empirical findings.

## What this machine exposes

**`kern.memorystatus_level`, `vm_stat`, `vm.swapusage` - yes, no root.**
This is what every sample records, so the memory picture at a kill is on disk before the kill, not reconstructed after it.

```
$ sysctl -n kern.memorystatus_level
69
$ sysctl -n vm.swapusage
total = 4096.00M  used = 2947.81M  free = 1148.19M  (encrypted)
```

`memorystatus_level` is the kernel's own free-memory percentage - the number jetsam thresholds are expressed against - which makes it the single most useful field for "was memory actually tight when this died".

**Jetsam reports - yes, and they are the authoritative OOM record.**
`/Library/Logs/DiagnosticReports/JetsamEvent-*.ips`, mode `rw-rw---- root:_analyticsusers`, readable because this user is in `_analyticsusers`.
Each report is a whole-machine snapshot; the killed process is the entry carrying a `reason`:

```
$ tail -n +2 /Library/Logs/DiagnosticReports/JetsamEvent-2026-07-12-235846.ips \
    | jq -c '.processes[] | select(.reason) | {name, pid, reason, rpages}'
{"name":"spotlightknowledged.updater","pid":20775,"reason":"per-process-limit","rpages":2080}
```

**A per-process `.ips` report - yes, and it NAMES the killer.**
This is the finding that mattered most, and the one the fleet was not looking at.
macOS writes a report for a *kernel-originated* SIGKILL, not only for a crash, and it carries `termination.namespace` - the killing subsystem - plus `exception.signal`.
Captured live from a real SIGKILL during this work (macOS killed a copied binary for an invalid signature):

```
$ tail -n +2 ~/Library/Logs/DiagnosticReports/fakeharness-2026-07-14-175534.ips \
    | jq -c '{pid, exception: .exception.signal, termination: .termination}'
{"pid":37930,"exception":"SIGKILL (Code Signature Invalid)",
 "termination":{"flags":66,"code":4,"namespace":"CODESIGNING","indicator":"Launch Constraint Violation"}}
```

A plain user-space `kill -9` writes **no** such report (verified in the same session, below).
So the absence of a report next to a SIGKILL is itself evidence: something in user space did it, not the kernel.

## What this machine does NOT expose

**`log show` does not work at all here.**
The unified log's persistent store is absent - `/var/db/diagnostics` does not exist - so every retrospective `log show` query fails, jetsam predicate or not:

```
$ /usr/bin/log show --last 6h --style compact \
    --predicate 'eventMessage CONTAINS "jetsam" OR eventMessage CONTAINS "memorystatus"'
log: Could not open local log store: The specified URL did not refer to a valid log archive
$ ls -ld /var/db/diagnostics
ls: /var/db/diagnostics: No such file or directory
```

`log config --status` needs root, so the reason the store is missing could not be established from this account.
`log stream` (live, prospective) does work, but it cannot answer questions about a kill that already happened, so it is not wired in.

The postmortem still runs the `log show` probe on every death and writes the exact failure into the record (`log_show=unavailable: ...`) rather than a silent blank, so a machine where the store *does* exist starts producing rows with no further change, and this machine says plainly that it cannot.

**Two quoting traps, both hit during this work.**
`log` is a shell builtin in zsh - a bare `log show ...` reports `too many arguments` and never reaches `/usr/bin/log`.
The scripts always call the absolute path.
The predicate must be one single-quoted argument; splitting it is what produces the confusing arity errors.

## Verification: a real kill, end to end

A throwaway "agent" (a symlink to `/bin/sleep`, so its `comm` basename matches the recorded harness) was run in a real tmux window, sampled, then killed with `kill -9`.

**Case A - user-space `kill -9`.** Sampled twice while alive, then killed:

```
$ cat state/killdemo.resource
1784022970  2026-07-14T17:56:10+0800  pid=40674  rss_kb=1168  free_mb=2414 compressor_mb=6352 swap_used_mb=2947 memstat_level=72
1784022972  2026-07-14T17:56:12+0800  pid=40674  rss_kb=1168  free_mb=2344 compressor_mb=6351 swap_used_mb=2947 memstat_level=72

$ kill -9 40674 && bin/fm-resource-sample.sh && cat state/killdemo.postmortem
abnormal=1
verdict=SIGKILL, killer unidentified: no jetsam report and no kernel termination report for this pid, which is what a user-space kill -9 looks like. NOT evidence of OOM. Memory at last sample: free_mb=403 compressor_mb=6378 swap_used_mb=2947 memstat_level=72
exit_signal=SIGKILL
pane_exit_line=[1]    48359 killed     fakeharness 600
jetsam=none
proc_report=none
log_show=unavailable: log: Could not open local log store: The specified URL did not refer to a valid log archive
last_rss_kb=1168
mem_at_last_sample=free_mb=403 compressor_mb=6378 swap_used_mb=2947 memstat_level=72
```

And the same cause reaches firstmate on the wake, without a manual dig - here through `fm-crew-state.sh`, while the crew's own status log still says `working:`:

```
$ bin/fm-crew-state.sh killdemo
state: working · source: status-log · pretending to work · agent died: SIGKILL, killer unidentified: no jetsam
report and no kernel termination report for this pid, which is what a user-space kill -9 looks like. NOT evidence
of OOM. Memory at last sample: free_mb=403 ... (evidence: .../state/killdemo.postmortem)
```

**Case B - a real kernel SIGKILL.** Replayed against the genuine `.ips` macOS wrote when it killed the copied binary (real report, real pid; only the `agentpid` record was hand-written to point the postmortem at that pid):

```
verdict=killed by the kernel [CODESIGNING: Launch Constraint Violation] signal=SIGKILL (Code Signature Invalid) (report: ~/Library/Logs/DiagnosticReports/fakeharness-2026-07-14-175534.ips)
proc_report_termination=CODESIGNING: Launch Constraint Violation
```

Both verdict branches are therefore proven against real kernel output, not code inspection.

## What this says about the 2026-07-14 kills

Nothing was instrumented then, so the deaths themselves cannot be re-litigated.
What can be checked is the kernel's own record, and it is empty:

```
$ ls -lt /Library/Logs/DiagnosticReports/JetsamEvent-*.ips | awk '{print $6,$7,$8,$9}'
7月 12 23:58 /Library/Logs/DiagnosticReports/JetsamEvent-2026-07-12-235846.ips
$ ls ~/Library/Logs/DiagnosticReports/ /Library/Logs/DiagnosticReports/ | grep -iE '^(claude|node)-'
(no output)
```

The only jetsam report on this machine is from 2026-07-12 - two days before the kills - and its victim was `spotlightknowledged.updater`, not an agent.
No per-process report exists for `claude` at all.
The jetsam mechanism demonstrably works here (the 07-12 report proves it fires and is readable), so had jetsam killed an agent on 07-14, a report of the same kind should have existed.
With today's instrumentation those kills would have been recorded as *SIGKILL, killer unidentified - not evidence of OOM*.
That does not prove they were not memory-related; it means the memory claim never had evidence, and the next kill will finally produce some.

## Cost

One `ps` and one `vm_stat` per pass, shared across the whole fleet, on a 30s cadence inside the watcher's existing poll loop - measured at ~40ms per pass.
No new process, nothing on the spawn path, and each sample log is trimmed to its last 2000 lines.

## Limits, stated plainly

- **tmux only.** Agent-pid resolution needs a pane pid (`#{pane_pid}`); no other backend exposes one. Tasks on herdr/zellij/orca/cmux get no samples, no death detection, and no postmortem - and the code records that rather than reporting a healthy silence.
- **The exit signal comes from the pane text**, so a pane that closed or scrolled past the shell's kill line yields `exit_signal=unknown`. The postmortem still records the memory picture and the kernel records, and says the signal is unknown.
- **A killed agent is detected within one sampling interval** (30s by default), not instantly.
- **jetsam matching is by pid and process name inside the window.** A window-matching report that killed something else is recorded as `other-victims`, never claimed as the agent's cause.
