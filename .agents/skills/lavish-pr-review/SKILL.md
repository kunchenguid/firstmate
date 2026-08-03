---
name: lavish-pr-review
description: >-
  Produce a Lavish walkthrough that explains an existing pull request with real code snippets, so the captain can understand the change and decide whether to merge it.
  Use when the captain invokes /lavish-pr-review or asks for a lavish, visual, or guided walkthrough of a specific PR, such as "make a lavish that walks me through this PR with code snippets" or "walk me through PR 42 visually".
  Do not use for judging a change's quality, for ordinary review or ship requests, or for investigation with no PR to explain.
user-invocable: true
metadata:
  internal: true
---

# lavish-pr-review

The deliverable is a Lavish artifact that orients the captain in a pull request he has not read, well enough to make a merge decision.
It is not a diff dump and not a verdict on code quality: `/code-review` judges a change, and a scout report answers an open question.
The walkthrough explains what exists on the branch and what merging it would mean.

## Dispatch

This reads project code, so it is project work: write a brief and dispatch a worker, never do it in the firstmate session.
The task is read-only on someone else's branch.
The worker checks the PR branch out in its own worktree and never commits, pushes, rebases, or comments on the PR.

## Content spine

Require these sections in the brief, in this order, adapted to the PR in hand.

1. What the feature is, and what it is easy to confuse it with; name the near neighbour early and draw the distinction.
2. The data model, with the real schema and any hand-written database constraints, plus why any deviation from project convention was accepted.
3. The read and write paths, shown through the snippets that carry the real invariants - tenancy scoping, ordering of authorization checks, soft-delete filters, caps and guards - rather than the plumbing between them.
4. The user-facing surface: where it mounts, the flows a user can start, and how state settles afterwards.
5. What changed in the most recent commits, as before/after, so review work already done is visible.
6. What is deliberately not done, so nothing surprises the captain after merge.
7. A closing risk read, plus any open product calls presented as decisions he can answer.

## Snippet discipline

Every snippet is real code copied from the branch, with a `file:line` reference.
Trim each one to what is being explained; never paste a whole file.
Prefer a diagram over prose where the request path or a type model is genuinely clearer drawn.

## Lavish mechanics

Open the relevant `lavish-axi playbook` entries before writing any HTML, and follow `lavish-axi design`.
The artifact is about the subject project, so match that project's own design system rather than the generic CDN default, and record which source was used.
Write the artifact under `.lavish/` in the worktree, open it with `lavish-axi <html-file>`, then run `lavish-axi poll <html-file>` in the FOREGROUND so the captain's feedback returns to the worker.
Never background the poll with `&` or `nohup`.

## Feedback that asks for code changes

Artifact feedback is applied to the artifact, and polling continues.
Feedback asking for changes to the project's code is out of scope for this task: the worker records it and raises it instead of making it, so firstmate routes that work as its own task.
