---
name: lavish-repair
description: >-
  Agent-only recovery playbook for a self-contained Lavish board that fails answerability preflight, does not open in its isolated Chrome session, or submits without pickup.
  Use before touching a Lavish board's state artifacts or Chrome session during a surface incident.
  Do not use it to create or present a decision; use `lavish-decisions` for that.
user-invocable: false
metadata:
  internal: true
---

# Lavish repair

Prove the failing layer before changing state or stopping a process.
The Lavish fork has no server, session URL, live channel, listener, or poller to repair.
Never invoke upstream serve, poll, or server-lifecycle commands.

## Start from the owners

Read `bin/fm-lavish-board.sh`'s header and `--help` output for the current preflight, dedicated-browser, and pickup mechanics.
Read `tools/lavish/README.md` for the durable decision and payload protocol.
Load `lavish-decisions` before completing the normal collect and consume workflow.

Establish the exact decision id, resolved Firstmate home, helper output, and named Chrome session before diagnosing the incident.
Preserve any downloaded answer JSON, durable pickup payload, and unsubmitted captain input.
Do not edit `request.md` or `manifest.toon`, because their digest and ordered questions are immutable.

## Diagnose in route order

### 1. Answerability preflight

When the helper refuses an unanswerable board, read its named missing components.
Do not bypass the preflight, arm pickup by hand, or substitute hand-authored HTML.
Resolve checkout or installed-tool version skew against the active helper and Lavish fork before trying the helper again.

The helper has not opened Chrome or armed pickup when this check fails.
Surface the exact terminal fallback emitted by `lavish-axi create` instead of reporting that a board is open.

### 2. Browser launch

When preflight succeeds but opening Chrome fails, retain the helper's exact error and session name.
The helper removes the armed check on an open failure, so do not report that submission pickup is active.
Use current `chrome-devtools-axi` help to inspect only the helper's named isolated session.
Never attach the board to the captain's main Chrome profile.

If the isolated session cannot be restored safely, use the exact terminal fallback from the creation result.

### 3. Board interaction

When the board is open but visibly broken, inspect that page in the named isolated session before reloading or reopening it.
Protect any unsubmitted captain input before a page-level repair.
If the rendered controls or submit machinery are missing, treat that as generator or version drift and return to the answerability-preflight branch.

### 4. Submission pickup

The verified browser-profile record is the authoritative pickup route, and a matching download is optional corroboration.
Keep the helper's existing one-shot check armed so Firstmate's ordinary watcher can recover the record even after the visible browser closes.
Do not add another storage bridge, filesystem watcher, timer sweep, long poll, or resident process.

Preserve a matching download for corroboration, but do not treat it as confirmed delivery.
If the helper emits `lavish-submit: <decision-id> <payload-path>`, preserve that exact durable payload and continue through the `lavish-decisions` consume workflow.
Confirm receipt only after `lavish-axi collect` validates and saves the answer.

### 5. Collection

Treat a named `lavish-axi collect` validation error as a payload or immutable-request mismatch, not a browser failure.
Preserve the rejected payload for diagnosis and do not weaken the schema, key, option, annotation, or request-digest checks.
Do not ask the captain to answer again when the same valid answer has already been saved durably.

## Process safety gate

Prefer the helper's named Chrome-session controls over process signals.
Never use `pkill -f` or signal a process selected only by a tool-name pattern, because crewmate launch commands can contain the same text.
If an explicit process signal is genuinely required, list candidates, inspect every candidate's PID, parent, elapsed time, and full command, then signal only one PID whose isolated-session identity is proven.
Never pipe unfiltered process-search output into `kill`.
Recheck the named session after the action before considering another signal.

## Recovery boundary

A surface failure does not erase the durable decision, a downloaded payload, or a collected answer.
Use `lavish show` and `lavish inbox` with the explicit Firstmate home to distinguish pending from already answered state.
Reopen a board only when no submitted payload exists and the captain's unsubmitted input has been protected or is known to be absent.
If the browser route remains unavailable, the exact `lavish answer ... --home ...` creation fallback keeps the decision answerable without browser infrastructure.
