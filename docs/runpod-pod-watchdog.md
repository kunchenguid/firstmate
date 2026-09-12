# RunPod pod watchdog

`bin/fm-runpod-watchdog.sh` is a detached process that terminates a rented RunPod pod when its deletion deadline passes, including after the agent that rented it is gone.

Until it existed, pod deletion in this home ran only through the RunPod integration, which is reachable only from inside an agent session.
A run's ceiling and deadline were therefore honoured only for as long as that session stayed alive, and an in-session deadline check stopped running the moment the session was replaced.
This watchdog closes that gap and nothing else: it does not create pods, does not choose what a run may spend, and does not supervise the run's work.

The script's own header and `--help` own the exact flags and mechanics.
This page is what an operator needs in order to run it and to trust what it will and will not do.

## Setup

One prerequisite: a RunPod API key with `api.runpod.io/graphql` Read/Write scope, in the gitignored `.env` at the home root as `RUNPOD_API_KEY`.
`curl`, `jq`, and `setsid` must be on `PATH`; `arm` refuses rather than launching a watchdog that could not act.

`arm` loads the credential before it publishes anything, so a key that has gone missing or unreadable is refused there rather than discovered at the deadline.

## Arming a run

Arm once, immediately after the pod exists and the run has recorded the deadline it declared:

```
bin/fm-runpod-watchdog.sh arm \
  --task <task-id> \
  --pod <pod-id> \
  --deadline 2026-09-12T02:19:41Z \
  --ceiling-usd 20 --rate-usd-hr 3.49
```

`--deadline` is required and accepts an epoch second or any instant `date(1)` reads, including the ISO-8601 UTC form run-state records already carry.
There is no default: this watchdog enforces the deadline a run declared and refuses to invent one.

`--ceiling-usd` with `--rate-usd-hr` is optional.
When both are given, `arm` converts the ceiling into a **duration of uptime** - never into an instant - and the loop anchors that duration to the pod's own start, derived from the `runtime { uptimeInSeconds }` the pod list already returns in the request it makes to check the pod is there.
That is the only anchor source: uptime can only be read off a *running* pod, so it cannot anchor a spend ceiling to a moment the pod was not accruing.
The watchdog then enforces whichever instant comes first.
Anchoring to the pod rather than to arming is what makes the bound mean what it says: a ceiling converted at arm time would start counting when someone got round to arming, so arming an hour late, or re-arming, would quietly raise it.
Note that a derived figure is not a billing statement; the ceiling deadline bounds uptime at the rate you declared, not settled charges.

`arm` publishes one small record at `state/<task-id>.runpod-watch` by rename, then starts the loop with `setsid` in its own session and returns.

Re-arming replaces the record and the process, so a deadline the captain **extends** is picked up by arming again with the new instant.
Re-arming cannot extend the ceiling: the ceiling is measured from the pod's own start, so a second arm re-derives the same bound rather than buying more of it.

## Checking and retiring

```
bin/fm-runpod-watchdog.sh status [--task <id>]
bin/fm-runpod-watchdog.sh disarm --task <id>
```

`status` prints the instant actually in force, whether it came from the declared deadline or the ceiling, and the **anchor** that instant rests on: `pod-start` once the running loop has read the pod's start instant, `unknown` when the pod is there but its start instant is not readable, `none` when no ceiling was declared, and `unresolved` when no loop has reported yet.
The declared deadline is always printed alongside it, so a ceiling the watchdog is not enforcing can never be mistaken for one it is.
A record it cannot read is reported as unreadable rather than summarised, because such a watchdog will not terminate anything.

`disarm` stops the process and removes the record.
Disarm when the run has ended and the pod is already gone; there is no need to disarm a watchdog that has already finished, since it exits on its own once a pod it has seen leaves the account's pod list.

## What it will do

It terminates on exactly one condition: the effective deadline has passed on the wall clock.

It then verifies the result rather than trusting the call.
A successful `podTerminate` response is not evidence of anything, and neither is `pod not found to terminate`: that answer cannot tell "already gone" from "never existed", so it is recorded as a failed call, not a stop.
The loop lists the account's pods afterwards and reports the pod stopped only once it is absent from that list.
A termination the listing does not confirm raises an alarm saying the pod may still be billing, and keeps retrying; it is never reported as stopped.

Absence is proof of a stop only for a pod this watch saw alive first - see "It will not end the watch on a pod it never saw" below.

### What it writes to the status channel

Everything this watchdog appends to `state/<task-id>.status` - the channel that wakes Firstmate - carries a decision key of its own, one per condition (`runpod-watch-<task-id>-<condition>`), so it can neither take over nor clear a crewmate's decision on the same file. Alarms are rate-limited per condition so an unattended alarm cannot flood the fleet.

| Event | Line | Effect on open decisions |
| --- | --- | --- |
| A condition the watchdog cannot act through (API unreachable, record unreadable, credential unreadable, clock unreadable, pod never seen, ceiling unanchorable, termination unverified) | `blocked [key=runpod-watch-<task>-<condition>]: …` | opens that condition's decision |
| That same condition clearing | `resolved [key=runpod-watch-<task>-<condition>]: …` | closes it, and lets it open again if it recurs |
| The watch retiring - the pod leaving, a verified stop, `disarm`, a re-arm | `resolved […]` for every condition still open **except `pod-never-seen`** | closes them all but that one |
| A verified stop | `note: … has been stopped; absence confirmed by listing the account's pods` | none; the wake drain surfaces `note:` lines without opening a decision |

A completed stop is reported as an event rather than a blocker on purpose: the watchdog exits immediately afterwards, so a `blocked:` line there would leave a decision open that only this watchdog could have closed.

`pod-never-seen` is the one alarm retiring does not close, including on `disarm`.
It says a rented pod may be billing under an id this watchdog was never given, and retiring the watch does not make that untrue; only an actual sighting of the pod closes it.
If you retire such a watch after checking the account yourself, close it yourself with `resolved [key=runpod-watch-<task>-pod-never-seen]: …`.

The full trail, including every termination attempt and verification result, is `state/<task-id>.runpod-watch.log`.

## What it will not do

**It will not key liveness on GPU utilization.**
Sampled across three pods on 2026-09-11, RunPod's runtime GPU utilization read 0% on most samples while runs were demonstrably progressing, because these sweeps alternate short GPU bursts with long CPU-bound quantize and pack phases; one sample caught 60% and CPU utilization stayed 37-58% on every live pod.
A utilization-driven watchdog would terminate healthy runs mid-pack.

**It will not enforce a ceiling it cannot anchor.**
When the pod's start instant cannot be read, the ceiling is not applied at all: the declared deadline stays in force, `status` reports the anchor as `unknown`, and an alarm says the ceiling is not being enforced.
A ceiling guessed from this process's own clock would be the same silent over-count that anchoring to the pod exists to prevent.

**It will not end the watch on a pod it never saw, and will not evaluate a deadline for one.**
A pod that was listed and then disappears is the normal ending, and the loop exits.
A pod id that has never appeared in the account is the opposite: nothing is being guarded, and a real rented pod may be billing under an id this watchdog was never given.
That case alarms, says the id may be wrong or stale, and keeps watching rather than retiring quietly.
While no sighting has happened the deadline is not evaluated on any path - not when the pod is absent, not when a read fails, not once the deadline has passed.
A pod that was never sighted cannot be stopped, so a passed deadline plus a transient transport failure can never produce a `podTerminate` call, and its absence from the pod list can never be read back as "absence confirmed".

**It will not terminate when it cannot establish that a deadline passed.**
Terminating a healthy run destroys work and money already spent, which is worse than no watchdog at all.
A missing, malformed, or unreadable record, an unreadable credential, an unreadable clock, and an unreachable or erroring API all alarm and keep polling.
A failed pod-list read is never read as "the pod is gone", and a comparison that could not be evaluated is never read as "the deadline passed".

**It will not become a second source of truth for what a run may spend.**
`arm` transcribes what the run already declared into a machine-readable record and the loop enforces that record.
It never parses the run's own prose run-state file, and the loop never writes the record it was given, so it cannot race the agent that wrote it.
What the loop derives - the instant in force and the anchor behind it - it republishes separately, at `state/<task-id>.runpod-watch.observed`, which is the only thing `status` reads for those figures.

**It will not expose the credential, or execute the file holding it.**
`RUNPOD_API_KEY` is handed to `curl` through a config file on stdin, so it never appears in argv and therefore never in `ps`.
Nothing the script writes carries it, and anything it logs is scrubbed of it.
The value is *parsed* out of `.env` on the same terms as `fmx_env_get`, never sourced: `.env` is the home's shared multi-key operator file, and the loop re-reads it every poll, so an apostrophe or an unquoted space in an unrelated neighbour's value must not be able to empty this key and silently disarm a live killswitch.

## Verification

`tests/fm-runpod-watchdog.test.sh` covers both halves: a passed deadline that terminates and is verified by listing, and a record that cannot be read that terminates nothing.
It also pins the states in between - a live deadline, an accepted termination the listing does not confirm, an unreadable pod list, a pod id that was never in the account, a ceiling anchored to the pod's own start that re-arming cannot extend, a ceiling whose anchor cannot be read and is therefore not enforced, alarms that leave a crewmate's open decision intact, a verified stop that leaves no open decision at all, an alarm the watchdog raises and then closes itself once the API comes back, a shared `.env` whose neighbouring values cannot take the credential away, a corrupt pid file that cannot signal the caller's process group, the credential never reaching a written file, and the armed watchdog surviving the death of the shell that armed it.
The RunPod API is faked at the process boundary, so the suite never touches a real account and never rents anything.
