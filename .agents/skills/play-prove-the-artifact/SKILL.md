---
name: play-prove-the-artifact
description: >-
  Play: prove the artifact with a live command, flow, record, or local verifier before declaring done; tests exist is not done.
  Loaded only when the task brief names it.
user-invocable: false
metadata:
  internal: true
---

# Prove the artifact

Tests existing is not done.
Prove the change against the real artifact: run the live command or flow, read the actual output or record, or run a local verifier that exercises the real path.
A proxy, a self-report, or "it compiles" is not proof.
When verification fails, suspect the observation method before suspecting the system.
For a fix, reproduce the bug first and show the original repro passing after the change.
Prefer a deterministic script or command a reviewer can re-run over a one-time eyeball; keep its output visible in the task report or PR evidence.
Trust artifacts, not summaries, including your own.
When a check cannot run, say so plainly in the done report instead of implying it passed.

This play governs proof, not review.
The selected delivery path still owns review, validation, and merge authority.