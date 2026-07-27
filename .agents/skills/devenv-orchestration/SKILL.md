---
name: devenv-orchestration
description: Use when the resolved backend is devenv or the captain asks to inspect, queue, or claim work across Expanly devenv VMs.
user-invocable: false
metadata:
  internal: true
---

# Devenv orchestration

Translate the captain's request into the narrow controller surface owned by `bin/fm-devenv-controller.sh`.
Read that script's header before the first call because it owns exact arguments.

## Conversational translation

- "Status" or "ahoy" means `bin/fm-devenv-controller.sh status --json`, then summarize the fleet and queue in captain language.
- "What is queued?" means `bin/fm-devenv-controller.sh queue`.
- "Is an environment safe?" means `bin/fm-devenv-controller.sh inspect`.
- "Queue this" means create the self-contained task packet first, retain its durable packet path, then call `enqueue`.
- "Claim the next task" means call `claim` only for the queue head and report a no-capacity result without selecting around it.

An explicit "use reviews" is strict: pass `reviews` as `preferred_environment`, and accept queuing when it is unsafe.
"reviews if safe" is soft: retain the suggestion in the task packet, pass `-` for `preferred_environment`, and let automatic safe selection choose any eligible environment.
A request for priority 10 changes ordering against the durable queue; it does not guarantee the next claim because higher priorities and earlier equal-priority entries still win.

## Current boundary

`status --json`, `queue`, and `inspect` are read-only observations.
`enqueue` mutates the durable queue and requires the durable packet path.
`claim` may start a stopped VM and write lease or quarantine records, but this control-plane release cannot prepare a checkout or perform an agent launch.
`release` mutates matching control-plane test leases only.

Production inspection currently publishes `pipeline_active:null` and `unknown_checkout_process:null`.
Those unreadable facts make real environments ineligible, so a real claim stops with no safe capacity until resident execution supplies them.

Stop before agent launch and report that resident execution is not installed.
Keep `devenv` selected; tmux fallback is outside this backend contract.
