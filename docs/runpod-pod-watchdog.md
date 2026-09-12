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

Prove the write path before relying on it, without spending anything:

```
bin/fm-runpod-watchdog.sh probe
```

The probe asks the API to terminate a pod id that cannot exist.
A granted key answers `pod not found to terminate`; a read-only key answers with a permission error instead.
Nothing is created, and no live pod is touched.

## Arming a run

Arm once, immediately after the pod exists and the run has recorded the deadline it declared:

```
bin/fm-runpod-watchdog.sh arm \
  --task <task-id> \
  --pod <pod-id> \
  --deadline 2026-09-12T02:19:41Z \
  --ceiling-usd 20 --rate-usd-hr 3.49 \
  --progress-file /path/the/run/touches --progress-grace 1800
```

`--deadline` is required and accepts an epoch second or any instant `date(1)` reads, including the ISO-8601 UTC form run-state records already carry.
There is no default: this watchdog enforces the deadline a run declared and refuses to invent one.

`--ceiling-usd` with `--rate-usd-hr` is optional.
When both are given, `arm` converts the ceiling into a wall-clock instant once, at arm time, and the watchdog enforces whichever instant comes first.
That conversion is the same arithmetic these runs already use to state their own spend, and it is done once so the running loop still only ever compares clocks.
Note that a derived figure is not a billing statement; the ceiling deadline bounds uptime at the rate you declared, not settled charges.

`--progress-file` with `--progress-grace` is optional and is an alarm signal only.
See "What it will not do" below.

`arm` publishes one small record at `state/<task-id>.runpod-watch` by rename, then starts the loop with `setsid` in its own session and returns.
Re-arming replaces the record and the process, so a deadline the captain extends is picked up by arming again with the new instant.

## Checking and retiring

```
bin/fm-runpod-watchdog.sh status [--task <id>]
bin/fm-runpod-watchdog.sh disarm --task <id>
```

`status` prints each armed pod, its effective deadline, whether the declared deadline or the ceiling is binding, and whether the watchdog process is running.
A record it cannot read is reported as unreadable rather than summarised, because such a watchdog will not terminate anything.

`disarm` stops the process and removes the record.
Disarm when the run has ended and the pod is already gone; there is no need to disarm a watchdog that has already finished, since it exits on its own once the pod leaves the account's pod list.

## What it will do

It terminates on exactly one condition: the effective deadline has passed on the wall clock.

It then verifies the result rather than trusting the call.
A successful `podTerminate` response is not evidence of anything.
The loop lists the account's pods afterwards and reports the pod stopped only once it is absent from that list.
A termination the listing does not confirm raises an alarm saying the pod may still be billing, and keeps retrying; it is never reported as stopped.

Alarms are appended to `state/<task-id>.status`, which is the channel that wakes Firstmate, rate-limited per condition so an unattended alarm cannot flood the fleet.
The full trail, including every termination attempt and verification result, is `state/<task-id>.runpod-watch.log`.

## What it will not do

**It will not key liveness on GPU utilization.**
Sampled across three pods on 2026-09-11, RunPod's runtime GPU utilization read 0% on most samples while runs were demonstrably progressing, because these sweeps alternate short GPU bursts with long CPU-bound quantize and pack phases; one sample caught 60% and CPU utilization stayed 37-58% on every live pod.
A utilization-driven watchdog would terminate healthy runs mid-pack.

**It will not terminate on a stalled progress artifact.**
From outside the pod, a wedged run and a long pack phase look identical, so a stalled `--progress-file` alarms and the run is left to its deadline.

**It will not terminate when it cannot establish that a deadline passed.**
Terminating a healthy run destroys work and money already spent, which is worse than no watchdog at all.
A missing, malformed, or unreadable record, an unreadable credential, an unreadable clock, and an unreachable or erroring API all alarm and keep polling.
A failed pod-list read is never read as "the pod is gone".

**It will not become a second source of truth for what a run may spend.**
`arm` transcribes what the run already declared into a machine-readable record and the loop enforces that record.
It never parses the run's own prose run-state file, and the loop never writes the record it was given, so it cannot race the agent that wrote it.

**It will not expose the credential.**
`RUNPOD_API_KEY` is handed to `curl` through a config file on stdin, so it never appears in argv and therefore never in `ps`.
Nothing the script writes carries it, and anything it logs is scrubbed of it.

## Verification

`tests/fm-runpod-watchdog.test.sh` covers both halves: a passed deadline that terminates and is verified by listing, and a record that cannot be read that terminates nothing.
It also pins the states in between - a live deadline, an accepted termination the listing does not confirm, an unreadable pod list, a stalled progress artifact, the credential never reaching a written file, and the armed watchdog surviving the death of the shell that armed it.
The RunPod API is faked at the process boundary, so the suite never touches a real account and never rents anything.
