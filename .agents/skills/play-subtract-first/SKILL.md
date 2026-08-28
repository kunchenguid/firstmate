---
name: play-subtract-first
description: >-
  Play: before building, subtract.
  Plan the smallest logical change that solves the task, name its blast radius, and sequence removal before construction.
  Loaded only when the task brief names it.
user-invocable: false
metadata:
  internal: true
---

# Subtract first

Name the smallest logical change that solves the task before writing anything.
State its blast radius in one or two lines: the files, callers, and behavior the change can reach.
Sequence removal before construction: delete dead weight, redundant guards, and stub references first, then build on the simpler base.
Deletion gives the next addition a smaller surface, so cut before you polish.
Design for observed usage, not speculative edge cases.
No speculative validators, parsers, or abstraction layers beyond what the task demands.
If the smallest change is still large, split it into verifiable units and land each before the next.

This play sizes the change only.
It never picks work, isolates copies, or decides delivery; firstmate's lifecycle owns those.