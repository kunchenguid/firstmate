---
name: tdd
description: >-
  Agent-only procedure for the inner red-green build loop when implementing a feature or bugfix in a project.
  Load before writing implementation code, when a test must be written first, or when choosing test seams for new behavior.
  This skill owns only the inner build loop; no-mistakes owns validation, review, push, PR, and CI.
user-invocable: false
metadata:
  internal: true
---

# tdd

Drive the build test-first, one vertical slice at a time.
This skill owns only the inner build loop.
A green local suite is never delivery: validation, push, PR, and CI belong to the delivery path the brief selects, and this loop never pushes or opens a PR.

## Before the first test

Agree the seams first.
A seam is a public interface the tests exercise, such as a module's exported function, a command, or an endpoint.
Name the seams for the behavior before writing any test, and confirm each one can be exercised without reaching into the code under test.
If no seam exists for a behavior, that absence is itself a finding; report it rather than testing private internals.

Choose the first slice: one behavior, cut through every layer it touches, and demoable on its own.

## Red, then green

1. Write one test for the slice through an agreed seam, asserting observable behavior.
2. Run it and confirm it fails for the expected reason.
   A test that passes before any implementation exists says nothing about the slice.
3. Write the smallest implementation that makes it pass.
4. Run the relevant suite, refactor only while it is green, and move to the next slice.

Finish each slice red-then-green before starting the next.
Never write every test first and then every implementation.

## Anti-patterns

- Implementation-coupled tests assert private calls, internal structure, or call order, so a behavior-preserving refactor breaks them.
- Tautological tests recompute the expected value with the same logic as the code, so they cannot fail.
- Horizontal slicing writes all tests and then all implementation, which yields tests of imagined behavior that the implementation bends to fit.

## Relation to no-mistakes' test-quality rule

Tests written here also follow no-mistakes' test-quality rule, which owns what a test may assert.
Both rules aim at tests that prove behavior rather than implementation detail; the source-text rule is the stricter set.
