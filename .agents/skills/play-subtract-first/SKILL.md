---
name: play-subtract-first
description: >-
  Play: make the smallest proven change that meets accepted behavior.
  Trace the real flow, fix the root cause once, and stop when the result is proven.
  Loaded only when the task brief names it.
user-invocable: false
metadata:
  internal: true
---

# Subtract first

> Keep the task smaller than the plan.

## Understand

Trace the real flow from entry point to effect before editing.
For a shared function or behavior, inspect every caller before choosing a fix.

## Plan

Write a short plan that names the goal, non-goals, acceptance criteria, and unchanged scope.

## Build

Start by removing dead code or redundant paths.
Then prefer existing project code, the standard library, native platform features, and already-installed dependencies, in that order.
Put corrective work at the root cause so every affected caller gets one fix, not local patches, alternate implementations, compatibility tracks, config layers, or speculative abstractions.
Keep corrective work needed for accepted behavior in scope.
Treat new behavior as new scope.
Keep execution lighter than planning, and stop when accepted behavior is proven.

## Test

Run existing relevant tests first.
Add a test only when behavior changed and no existing test detects the regression.
Keep a new test to one main path and at most one essential failure path.

## Before completion

Confirm the diff is the smallest one that works.
Confirm it touches no unrelated files, leaves no debug residue, and contains no construction without proof.

This play governs task-level implementation discipline.
