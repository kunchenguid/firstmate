---
name: revocall-e2e-teardown
description: >-
  Reverse exactly what revocall-e2e-provision started for one task's local end-to-end test: its containers, volumes, and network, verified gone.
  Use when local end-to-end testing is finished, before ending a task that provisioned a local stack, and when recovering a task whose worker died mid-test.
  Verifies ownership through the provisioning record before removing anything, and reports an unattributed container instead of removing it, because an anonymous container can be live work.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone: it must work with no firstmate home present. The firstmate-coupled half is bin/fm-e2e-stack.sh plus Fix 4 in bin/fm-teardown.sh, which runs this same removal automatically at task cleanup. -->

# revocall-e2e-teardown

Take down the local stack `revocall-e2e-provision` brought up for this task, and prove it is gone.

Run it as soon as the end-to-end test is finished, not at the end of the task.
In a firstmate checkout, task cleanup also runs the same removal automatically, so this skill and that path converge on one outcome rather than two.

## The rule this skill exists to enforce

**Removal always needs a record. Never an inference.**

An anonymous container is not evidence of abandonment.
Compose names a project after its own directory when the compose file declares no `name:`, so a live validation pipeline's database can appear as `backend-postgres-1` with nothing tying it to any task.
That shape is indistinguishable from a stray, and it has been live work in practice.
So this skill removes only what a provisioning record names, and reports everything else.

## Steps

1. **Read the record.**
   With firstmate present: `bin/fm-e2e-stack.sh read <task>`.
   Standalone: the file the provisioning run wrote beside its override.
   No record means nothing to remove: say so and stop, rather than searching for something to clean.

2. **Run the ownership gates.**
   `bin/fm-e2e-stack.sh gate <task>` runs all four and prints one verdict per gate.
   Standalone, check them by hand in this order.

   | Gate | Check | Why |
   |---|---|---|
   | 1 | Every container labelled `ai.revolab.fm.task=<task>` sits in a project the record names, and every recorded project's containers carry that label. | Labels and record disagreeing is a divergence to report, not a target to remove. |
   | 2 | Every recorded project name begins with `fm-`. | Nothing a person or another tool starts is named that way, so a hand-run or pipeline-owned stack can never be selected. |
   | 3 | No OTHER task's record names the same project or worktree. | One project claimed by two records is the collision itself, whichever record is stale. Never resolved by guessing. |
   | 4 | Every recorded external volume name contains the task id. | RevoCall's deploy stack pins six `external: true` volumes to fixed names. An unsuffixed name is the shared local development data. |

   A failed gate stops the removal.
   There is no force flag: these refusals protect OTHER work, and discarding this task's own work is never what they stand in the way of.

3. **Remove, using the recorded compose files.**

   ```bash
   docker compose -p <recorded project> -f <recorded file>... down -v --remove-orphans --timeout 20
   ```

   `-v` is required.
   A plain `down` leaves the project's volumes behind, and volume residue is where the disk actually goes: an unswept machine has been observed holding about 2.0 GB of dangling volumes.
   Use the RECORDED file list rather than re-deriving it, so a repo file edited since provisioning cannot change what comes down.

4. **Remove what compose will not.**
   `docker volume rm <name>` for each recorded external volume, only when gate 4 passed.
   Compose removes an `external: true` volume on no code path, `down -v` included.
   `docker network rm <name>` when the record says provisioning created the network and it now holds no containers.

5. **Verify, and treat residue as failure.**

   ```bash
   docker ps -aq      --filter label=com.docker.compose.project=<project>
   docker volume ls -q --filter label=com.docker.compose.project=<project>
   docker network ls -q --filter label=com.docker.compose.project=<project>
   docker volume inspect <each recorded external volume>
   ```

   All four must come back empty.
   Anything surviving is a failed removal: report it, keep the record for a retry, and do not clear it.

6. **Reap the host side.**
   A provisioned stack often has an application process pointed at it, and that process outlives the containers.
   Kill processes whose working directory is under this task's worktree or its temporary root, and any process holding a socket on a recorded port, verifying identity before signalling.
   This step is not optional bookkeeping: an orphaned application process has been observed still polling a deleted database more than 25 hours later, reattaching the moment anything bound its port again.
   Report anything it declines to kill.

7. **Clear the record**, only after step 5 passed.
   `bin/fm-e2e-stack.sh clear <task>`, or delete the standalone record file.
   `bin/fm-e2e-stack.sh down <task>` performs steps 2 through 5 and 7 as one guarded, idempotent operation, and is the preferred path when firstmate is present.

## Reporting what you did not remove

`bin/fm-e2e-stack.sh strays` lists every container with its claimed task, whether that task still has a live record, and whether the directory it was launched from still exists.

Two of those signals are for triage only and never authorize a removal.

- A launching directory that no longer exists suggests abandonment.
- A launching directory that still exists suggests live work, and it is the signal that protects a running pipeline.

Report an unattributed container with its age and launching directory so a human can decide.
Do not remove it.
Container start time from `docker inspect --format '{{.State.StartedAt}}'` is the cheap age signal; reading container logs for a last-activity timestamp is the expensive fallback, and needing it means the identity discipline was skipped upstream.

## If the record is gone but the stack is not

This is the recovery case: a worker died before recording, or the record was deleted.

Reconstruct a CANDIDATE set from `docker ps -a --filter label=ai.revolab.fm.task=<task>`, and say plainly in the report that the set was reconstructed.
Gate 1 cannot be checked in that state, so gates 2, 3, and 4 carry the whole decision: the `fm-` prefix, no competing claimant, and a task-suffixed external volume name.
If those do not hold, stop and report rather than removing.

## Refusals

- Any ownership gate failing.
- An unrecorded or unlabelled container, always. It is reported, never removed.
- An external volume whose name carries no task id, always. That is shared local data.
- `docker info` not answering. Nothing can be proved, so nothing is removed.

## Reference

`bin/fm-e2e-stack.sh --help` in a firstmate checkout owns the record format, the exact gate semantics, and the removal mechanics.
`revocall-e2e-provision` owns what gets started and what the record must contain.
