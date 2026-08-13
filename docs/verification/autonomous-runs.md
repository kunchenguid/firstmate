# Autonomous-run engine verification

Audience: maintainer verification.

This record supports the current failure and recovery guarantees in [`../autonomous-runs.md`](../autonomous-runs.md): single mutable custody across an ownership change, idempotent resume, freeze-time manifest integrity, and the governor's treatment of a lane whose quota cannot be read without attended authorization.

Operator behavior and the current limits stay in the linked guide.
The portable regressions in `tests/fm-run-engine.test.sh` and `tests/fm-run-governor.test.sh` are what CI enforces; this record holds the results that need a real environment or a live provider.

Environment for the run below, 2026-08-13: macOS 26.5.2 on arm64, GNU bash 3.2.57, jq 1.8.2, ShellCheck 0.11.0, quota-axi 0.1.24.
The suite is therefore proven under the system bash 3.2 that macOS ships, not only under a newer bash.

## Custody across an ownership change

A run driven to `supervise` under one owner, then contested by a second.

```sh
FM_RUN_OWNER=primary-b bin/fm-run.sh claim ev-1 --takeover
FM_RUN_OWNER=primary-b bin/fm-run.sh advance ev-1 decision
```

```text
fm-run: refused: run ev-1 is in state supervise; its owner must checkpoint or stop before a takeover
fm-run: refused: run ev-1 is owned by primary-a, not primary-b; a takeover needs a quiesced run
```

Both refusals exit 3.
The contested run converges on the original owner rather than on two owners.

After the original owner quiesces the run, the transfer is legal and the former owner loses its mutation rights in the same step:

```sh
FM_RUN_OWNER=primary-a bin/fm-run.sh stop ev-1 --rule health --resume-when "load below policy"
FM_RUN_OWNER=primary-b bin/fm-run.sh claim ev-1 --takeover
FM_RUN_OWNER=primary-a bin/fm-run.sh advance ev-1 report
```

```text
stop: ev-1 rule=health
claim: ev-1 owner=primary-b generation=2
fm-run: refused: run ev-1 is owned by primary-b, not primary-a; a takeover needs a quiesced run
```

## Resume is idempotent per ownership generation

```sh
FM_RUN_OWNER=primary-b bin/fm-run.sh resume ev-1
FM_RUN_OWNER=primary-b bin/fm-run.sh resume ev-1
```

```text
resume: ev-1 generation=2 state=supervise
resume: ev-1 already resumed in generation 2 (state supervise)
```

The second call exits 0 without re-entering supervision, so a replayed wake, a restarted session, or a second recovery pass cannot start a duplicate loop.

## State that survives the ownership change

`data/runs/ev-1/run.state` after the sequence above:

```text
checkpoints=1
generation=2
owner=primary-b
resume_when=load below policy
resumed_generation=2
state=supervise
stop_rule=health
updated=2026-08-13T09:39:55Z
```

`data/runs/ev-1/checkpoints/1.json`:

```json
{
  "index": 1,
  "at": "2026-08-13T09:39:54Z",
  "state": "supervise",
  "note": "3 of 7 sources read",
  "resumeWhen": "remaining sources in evidence/queue.txt"
}
```

The exact resumption condition and the partial progress survive the stop and the ownership change, which is what makes stopping safe rather than lossy.

## Freeze-time manifest integrity

A frozen manifest widened out of band, then used:

```sh
jq '.source.readRoots += ["/etc"]' manifest.json > m && mv m manifest.json
bin/fm-run.sh read-check ev-1 /etc/hosts
```

```text
fm-run: run ev-1 manifest changed after freeze (recorded d797b055…0f12be0, found 191b3446…155e39a4)
```

Exit 1.
The widened scope is not honored: the gate refuses on the integrity failure before it ever consults the new value, so tampering stops the run instead of expanding it.

## Governor against live providers

Both classifications ran against the real `quota-axi --json` output, with no `--allow-keychain-prompt` and no prompt shown.

Claude, whose quota needs an attended keychain authorization on this machine:

```sh
bin/fm-run-governor.sh classify --lane company-claude --need-seconds 3600 --no-record
```

```text
class=unknown
percent=unknown
reasons=state:auth_required
```

Codex, authenticated:

```sh
bin/fm-run-governor.sh classify --lane personal-codex --need-seconds 3600 --no-record
```

```text
class=normal
percent=99
runway=through_reset
pace=behind
day_budget_state=not-applicable
```

The unreadable lane classifies as `unknown` rather than as available, which starts no new large work and surfaces the attended requirement.
Refreshing this record means re-running the two commands above after a provider or `quota-axi` change; the synthetic-document regressions in `tests/fm-run-governor.test.sh` cover the policy arithmetic without needing either provider.

## Concurrency, symlink resolution, and resume revalidation

Captured on macOS 26.5.2 arm64, GNU bash 3.2.57, jq 1.8.2, against a scratch `FM_HOME` with two registered lanes.

### Concurrent claims resolve to one owner

Eight primaries claim the same frozen run simultaneously:

```sh
for i in 1 2 3 4 5 6 7 8; do
  ( FM_RUN_OWNER="primary-$i" bin/fm-run.sh claim evidence-run ) &
done; wait
```

```text
primary-1 exit=0 claim: evidence-run owner=primary-1 generation=1
primary-2 exit=3 refused: run evidence-run is owned by primary-1; pass --takeover from a quiesced run to transfer it
... primary-3 through primary-8 identical
```

`run.state` records `owner=primary-1 generation=1`.
Reading the owner, deciding, and writing it happens under the run lock, so the claim is one compare-and-swap.
Against the same test with the lock removed, all eight claims exit 0 and each believes it holds custody - which is the defect this closes.

### A symlinked write target is refused; a read is judged on its real target

```sh
ln -s /tmp/ev/lane-c/secret.txt "$EVIDENCE/decoy.txt"
bin/fm-run.sh write-check evidence-run "$EVIDENCE/decoy.txt"
```

```text
refused: .../evidence/decoy.txt is a symlink; a write target must be a real path inside this run's write area
```

A read follows the link and is judged on what it would actually open, so a link into the frozen read roots is allowed and one pointing at another lane is refused by that lane, not excused by the name it was reached through:

```text
read-check: /private/tmp/ev/src/paper.md allowed
refused: /private/tmp/ev/lane-c/secret.txt belongs to lane ev-company, not this run's lane ev-personal
```

The second refusal names the resolved company-lane path rather than the innocent-looking `innocent.md` it was reached by.

### Stopping writes its own durable checkpoint

```sh
bin/fm-run.sh stop evidence-run --rule deadline --note "wall-clock budget reached"
```

```text
stop: evidence-run rule=deadline checkpoint=1
```

```json
{ "index": 1, "state": "preflight", "note": "stop:deadline - wall-clock budget reached" }
```

Restart safety no longer depends on the operator remembering a separate checkpoint command.

### Resume revalidates the world it left

With the lane registration emptied while the run was stopped:

```text
fm-run: resume-revalidation failed: lane ev-personal is not registered in config/run-lanes.conf
```

```json
{"kind":"resume-revalidation","subject":"assertion","verdict":"failed","note":"lane ev-personal is not registered in config/run-lanes.conf"}
```

The refusal is recorded under its own phase, so a first-dispatch refusal and one that fired on the way back in stay distinguishable in the receipt log.
Restoring the registration lets the resume proceed, reporting `revalidated=yes`.

### prove-no-write states its own scope

```text
prove-no-write: evidence-run no outside write recorded through fm-run gates (refusals recorded: 2)
prove-no-write: scope: receipts only; a write that never called the write gate leaves no record here
```

The command reads receipts, so it speaks only for writes routed through the gates.
It is not a filesystem audit, and its output now says so rather than implying one.
