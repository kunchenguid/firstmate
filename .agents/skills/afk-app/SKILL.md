---
name: afk-app
description: >-
  Run an autonomous application program on one project while the captain is away, when they invoke /afk-app or ask firstmate to audit or overnight-fix an app.
  Audit is read-only discovery across journeys, frontend, API, regression, architecture, performance, accessibility, and security; fix-known implements only reproduced accepted defects in an isolated copy and stops at a reviewable branch.
user-invocable: true
metadata:
  internal: true
---

# afk-app

**Load `autonomous-run-engine` first.**
It owns the shared intake-to-report procedure.
This file owns only what is specific to working on an application.

```text
/afk-app <project> --mode audit|fix-known [--envelope <frozen-change-spec>]
                   [--evidence-dir <dir>] [--budget <wall>]
```

## Audit evidence is not fix authority

An audit finds things.
Finding a defect never authorizes fixing it, however obvious the fix looks, and however much time is left in the night.

A fix happens only when the intake granted that exact change envelope up front.
An audit that discovers something worth fixing ends by reporting it and queuing the fix, and the fix is a separate run with its own grant.

## audit

Create with `--mode afk-app --submode audit --grant read-only`.
Freeze at least one `source.projects` entry.

The run reads the project and drives a local or staging URL; it cannot write anything but its evidence directory, and the engine enforces that rather than trusting the submode's name.
Prefer deterministic tools for execution: a scanner that finds the issue costs a fraction of a model round that guesses at it, and its output is reproducible.

Every finding needs its reproduction, its evidence pointer, the intent it violates, a duplicate check, and a false-positive counter-check before it counts.
A screenshot alone is not a finding, and a passing test is not an outcome.

## fix-known

Create with `--mode afk-app --submode fix-known --grant fix-known:<envelope-hash>`, and freeze `writes.allowedPaths` to the isolated worktree the work happens in.
Preflight refuses a write path inside the firstmate home, which is where the primary checkout and the read-only project clones live.

Rules that hold for the whole submode:

- One reproduced defect at a time, one hypothesis at a time. Reproduce before the change, prove the change fixes exactly that, and run the full suite after.
- The tests and evaluators that define accepted behavior stay protected. A change that needs them relaxed is a change to the contract, which is the captain's call.
- The run stops at a reviewable branch. It never pushes to a default branch, never merges, and never deploys.
- A fix that turns out to need behavior the accepted contract does not cover stops and returns the question; load `ask-user-authority` rather than deciding it inside the run.

Turn every reproduced defect into the regression test that would have caught it.

## bounded-improvement

Specified, and deliberately not available.
The engine refuses it at preflight until the `fix-known` pilots pass and the captain authorizes enabling it.
If the captain asks for it, say plainly that it is gated on those pilots rather than starting a broad improvement pass under a different name.

## Stop conditions specific to this mode

Beyond the shared rules, stop when the baseline or evaluator is unstable, when a fix would need a new dependency, when CI goes red, when the same theme has been re-attempted without a verified delta, or when only low-value work remains.

## Deliverable

For an audit: ranked findings with evidence, impact, and confidence, plus what would be worth doing about the top few.
For a fix run: the reviewable branch with its full URL, what was reproduced, what changed, what proves it, and what was deliberately left alone.
