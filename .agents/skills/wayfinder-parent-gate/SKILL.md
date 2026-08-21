---
name: wayfinder-parent-gate
description: >-
  Agent-only parent map-owner procedure for a consuming project's Wayfinder lifecycle command.
  Load before treating a named Wayfinder child as resolved or archived, and before dispatching implementation that depends on a Wayfinder map.
  Owns the Firstmate-side obligation to keep research scouts read-only, treat captain-call completion as local input, and invoke the project's public lifecycle command for accept-child and handoff.
user-invocable: false
metadata:
  internal: true
---

# Wayfinder parent map owner

Load this before treating a Firstmate child that names a Wayfinder ticket as tracker-resolved, and before dispatching implementation that depends on that map.

`captain-hold-lifecycle` remains the sole owner of captain-call inventory.
Passing its completion command, including `--none`, is local input to this parent check.
It does not resolve a Wayfinder ticket, close GitHub issues, or satisfy a project lifecycle command.

The consuming project owns the resolution policy.
Invoke that project's public `bin/wayfinder-lifecycle-gate` through `bin/fm-wayfinder-parent.sh`.
Do not restate or reimplement that policy inside Firstmate, `bin/fm-captain-hold.sh`, or `bin/fm-decision-hold.sh`.
Do not modify the upstream Wayfinder skill or globally installed skill copies.

## Parent obligation

When a Firstmate child names a Wayfinder ticket, Firstmate is the parent map owner for that child.

1. Keep a research scout read-only when its task requires that isolation.
   The scout's report plus captain-call completion is local input, not tracker resolution.
2. Record tracker resolution yourself, using the consuming project's tracker contract.
3. Before treating that child as Wayfinder-resolved or archiving it as such, run `bin/fm-wayfinder-parent.sh accept-child` against a GitHub snapshot that includes the child's local completion records.
4. Before spawning or promoting map-dependent implementation, run `bin/fm-wayfinder-parent.sh handoff` the same way.

`bin/fm-wayfinder-parent.sh --help` owns flags, snapshot merging, and exit codes.
Build the GitHub snapshot as that help describes; include local reports, captain-call completions, archives, and backlog rows so the project command can reject them as resolution.

## Dispatch enforcement

A ship spawn, scout promotion, or map-dependent ship relaunch against a project that publishes `bin/wayfinder-lifecycle-gate` requires a passing `handoff` check.
Pass `--wayfinder-state <snapshot>` to `bin/fm-spawn.sh` or `bin/fm-promote.sh`.
Pass `--wayfinder-independent` only when the work does not depend on the Wayfinder map.
A relaunch takes its fresh snapshot through `bin/fm-control.sh <task-id> relaunch --wayfinder-state <snapshot>`.
A map-independent spawn or promotion records that exemption for later relaunches.
A scout spawn stays off that handoff path so read-only research can still run.

## Operating sequence

1. Inventory the named Wayfinder ticket from the child's brief, task, or recorded identity.
2. If the worker is a research scout whose task forbids project or GitHub mutation, leave it read-only and take its report as input.
3. Complete captain-call inventory through `captain-hold-lifecycle` as local input.
4. As parent, write the project's tracker resolution, then verify `accept-child` before recording the child as Wayfinder-resolved.
5. Verify `handoff` before a map-dependent ship spawn, promotion, or relaunch.
6. Stop if either project command rejects the snapshot; repair tracker state and rerun the same command rather than archiving or dispatching on local completion alone.
