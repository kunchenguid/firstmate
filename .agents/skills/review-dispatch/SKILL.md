---
name: review-dispatch
description: >-
  Agent-only procedure for choosing and pinning the no-mistakes review agent from the captain's accepted list before a validation starts, and for releasing that pin when the run ends.
  Load before triggering a no-mistakes validation, on the wake that reports that validation's CI-green or terminal outcome, and before tearing down a task that may still hold the pin.
user-invocable: false
metadata:
  internal: true
---

# review-dispatch

This skill is the single owner of when firstmate runs `bin/fm-review-pin.sh` and what it does with each result.
`docs/configuration.md` "Review dispatch" owns the schema of `config/review-dispatch.json`, and the helper's header owns the selection rule, the quota matching, and the pin, restore, lock, and in-flight mechanics.
`AGENTS.md` section 7 owns the validation lifecycle this slots into; nothing here changes who drives the pipeline.

The pin is the shared no-mistakes global configuration, one file for every home and lane on the machine.
Only this helper writes it; firstmate never hand-edits it, never asks a worker to, and never adds a daemon or watcher around it.

## Before triggering a validation

1. If `config/review-dispatch.json` is absent, skip pinning, trigger validation on whatever agent the shared configuration already names, and tell the captain once that no accepted list exists; never invent one.
2. Otherwise run `bin/fm-review-pin.sh pin --task <id> --repo <worktree>` with the task's recorded worktree, and read the exit status:
   - `0`: the tuple printed on stdout is now the review agent; trigger validation through the harness invocation owned by `harness-adapters`.
     The stderr reason lines are your evidence for why earlier candidates were skipped.
   - `1` (`none`): every accepted candidate was skipped.
     Do not trigger on a guess and do not fall back to an unlisted agent; report the skipped candidates and their reasons to the captain, hold the validation, and re-run `pin` when quota clears or the captain names a route.
   - `3`: a review is in flight or another task holds the pin.
     Leave the running review alone, hold this validation, and recheck with `bin/fm-review-pin.sh status` at the next heartbeat; pin and trigger once it prints `in-flight: none` and `free`.
     A held pin with no review in flight means the holder's run ended without a restore: confirm that task is finished, run `restore --task <holder>`, then pin.
   - `2`: a configuration, snapshot, or environment error; fix the named problem or escalate it, never select around it.
3. Record the pinned tuple in the task's backlog note so the outcome can name which review agent judged the work.

## When the run ends

Run `bin/fm-review-pin.sh restore --task <id>` on the wake that reports the validation's CI-green line, its failure, or its cancellation; a run that only monitors CI is not in flight, so restore does not wait for merge.
Before tearing down a task, run `bin/fm-review-pin.sh status` and restore first when that task is the holder, so cleanup never leaves a stale pin behind.
A restore refusal is a stop-and-inspect result: a review in flight means wait and retry, while a changed live configuration means someone hand-edited the pin, so reconcile it against the saved previous bytes the helper names before removing the record.
