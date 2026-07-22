---
name: milestone-integration-review
description: >-
  Agent-only procedure for the standing gap between "every issue in a milestone is individually green" and "ready for captain merge decision."
  Use before presenting any multi-PR milestone (2+ open PRs from the same milestone, same project) as ready to merge.
  Owns dispatching a dedicated integration-review pass and running fm-integration-review.sh to produce a reproducible merge-train transcript, before any individual PR's "checks green" is treated as proof the milestone composes.
user-invocable: false
metadata:
  internal: true
---

# milestone-integration-review

## Why this exists

Isolated per-crewmate gates cannot prove that independently-green PRs compose.
Each crewmate's `no-mistakes` run validates its own branch alone; it has no way to see the other PRs in the same milestone.
Two individually-correct PRs can be mutually incompatible in a way no single PR's own CI will ever catch.
A real cross-PR `NameError` shipped past four independent per-PR gates on 2026-07-21 before a dedicated review pass caught it - see the fusion-harness repo's `PROOF.md`/`BUGS_FOUND.md` for the full account.
"Checks green" on GitHub, in most projects, means the CI that project actually has ran clean, often just secret scanning, not a test suite.
It is never proof that N PRs merged together still work.

## When to load this

Before reporting any milestone as ready for the captain's merge decision, whenever that milestone has **2 or more open PRs**.
A single-PR milestone doesn't need this - there's nothing to compose.
Load it once all the milestone's individual issues have reached their own `done: PR ... checks green` state.

## Procedure

1. **Determine dependency order.**
   If the milestone's plan (a fusion-harness `/fusion` output, a design doc, or explicit dependency notes in the issues) states an order, use it.
   Otherwise default to issue-number order and flag the assumption in the report.
2. **Identify the test command.**
   Use the project's own documented test command (README, `AGENTS.md`, or ask the captain if genuinely unknown).
   Do not guess a framework.
3. **Run the merge-train check:**
   ```
   bin/fm-integration-review.sh <project> "<test-command>" <pr1> <pr2> ... <prN>
   ```
   in dependency order.
   Save its full output - `tee` to a file, not just prose in a status line.
   This transcript is the artifact; a captain-facing "N/N passing" claim needs a reproducible transcript behind it, the same discipline `verify-49-tests.txt` established in the 2026-07-21 run.
4. **On a clean run (exit 0):** the milestone's PRs compose.
   Report this to the captain alongside the transcript path, as part of the normal PR-ready escalation (AGENTS.md section 9).
5. **On a merge conflict (exit 2):** this is expected, not an error in the process.
   It means two PRs touch overlapping code, which any real merge would eventually need to resolve anyway.
   Do not resolve it inside this script's disposable worktree and call it done.
   Either dispatch this as its own scoped task - a crewmate or the captain resolves the conflict on the flagged branch, understanding what each PR intended, then a human or crewmate re-runs the full suite manually - or, if the fix is small and the ownership is unambiguous, brief the *original* PR whose merge-train position triggered the conflict to resolve it directly on its own branch and re-push.
   That second path matches how 2026-07-21's #25 was fixed - the same crewmate reworked its own branch rather than a new task being spun up.
   Either way, do not report the milestone ready until a full-suite green merge-train transcript exists.
6. **On any other failure** (test command errors, a merge itself fails for reasons other than content conflicts): treat as `blocked:` per the standard status protocol and escalate.
   Do not retry blindly.

## What this is not

This does not replace `no-mistakes` per-PR validation, and it is not itself a merge authority.
It produces evidence; the captain still makes the merge call, and nothing in this procedure pushes to any default branch or merges any PR.
It also does not decide dependency order on its own; that's either supplied by the plan that produced the milestone or made explicit and flagged if inferred.
