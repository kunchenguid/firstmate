---
name: pi-live-model-switch
description: >-
  Agent-only playbook for changing a live Pi worker's provider, model, or
  thinking level in the same session, and for choosing live-switch versus
  relaunch at a bounded checkpoint. Load before calling fm-control
  switch-model, before answering a worker checkpoint of complexity, stall,
  phase, or quota, and before a quota event on a Pi ship or scout.
user-invocable: false
metadata:
  internal: true
---

# Pi live model switch

Load this before changing a running Pi or Pi-signed ship or scout worker's provider, model, or thinking level, and before deciding whether that change is a live session switch or a harness relaunch.

`../../../bin/fm-control.sh` owns the task-addressed verb.
`../../../bin/fm-pi-switch-lib.sh` owns the request/ack protocol.
`../../../bin/fm-profile-switch.sh` owns bounded checkpoint classification, cooldown, and the retry bound.
`../../../docs/agent-control.md` owns the control-plane split from `relaunch`.

## When to load

- A Pi ship or scout reports `working: checkpoint complexity|stall|phase|quota:`.
- A quota event lands for a provider that worker is spending.
- Work has newly discovered complexity, repeated failure without progress, or an explicit phase change, and the worker is Pi.
- You are about to call `fm-control.sh <id> switch-model`.

Do not call Jev, or this selector, on every tool invocation.

## Live switch versus relaunch

A live switch keeps the same Pi process, session, task id, isolated copy, and conversation.
It is valid only for `harness=pi` or `pi-signed` ship and scout workers whose session has written the handshake file.

A harness change - native Grok, Claude, or any other adapter - is `fm-control.sh <id> relaunch --harness ... --note ...`.
That replacement inherits the isolated copy and none of the conversation; the note must record progress.

Never disguise a relaunch as a live switch, and never switch the pane to RPC mode to obtain stdin control.

## Apply a live switch

1. Reassess the matched rule against the remaining task and original `dispatch_*` snapshot; preserve its reasoning class unless the phase is explicitly routine and independently verifiable.
2. Apply `quota-array-dispatch` to every alternative in that rule, including catalog, account, context, completion horizon and spendPriority evidence; supply the chosen rule and profile using the selector's `--rule` and `--selected` arguments.
   These arguments attest your assessment; they are not inferred from model names, effort ranks or array order.
   Pass the task's `state/<id>.model-switch.log` as the required `--history`, including before its first switch when the file does not exist.
   Use `--decision` when making the bounded checkpoint decision yourself.
3. Drive the change with `FM_HOME=<home> bin/fm-control.sh <id> switch-model --model <provider/id> --effort <level>`.
   A destination whose quota is unmeasured stays eligible, but the selector holds and the direct verb refuses until you assess it and add `--confirm-unmeasured-quota` to both; the selector still applies cooldown and the retry bound first, and measured exhaustion always refuses.
4. Trust only a `switched-model` line whose model and effort came from runtime readback.
5. On `busy` deferral, wait; do not interrupt a tool operation to switch.
6. On refusal, timeout, or crash, read the task record: `model=` is the confirmed readback or `unknown` pending reconciliation, `dispatch_*` is the original intake profile, and `state/<id>.model-switch.log` is the history a later relaunch must honor.

Automatic switches among verified profiles on the existing accounts are authorized:

- Escalate when evidence shows the current profile is inadequate.
- Move across providers when quota warrants it and the replacement meets the task's capability requirements.
- Reduce effort or model capability only when the remaining phase is explicitly routine and independently verifiable (`--routine` on the selector).
- Prefer session continuity among suitable Pi choices.
- Honor the selector's cooldown and per-hour retry bound.

Pass the worker's checkpoint line as `--evidence`.
When `TYPESAFE_API_KEY` is configured and no explicit `--decision` is supplied, the selector makes at most one bounded Jev call per checkpoint, after cooldown, retry, and never-send checks, and Jev classifies only among the decisions that checkpoint allows (`escalate`, `move-provider`, `reduce` with `--routine`, `stay`).
Jev never sees or returns model IDs; `quota-array-dispatch` remains the authoritative selection procedure, and the direct control verb repeats the quota preflight against the configured destination profile.
`jev=on` means Jev's answer was used; absent, ambiguous, error, and never-send outcomes hold for firstmate judgment unless an explicit bounded `--decision` is supplied.
A pending request must reconcile before another switch or relaunch; recovery without readback requires a confirmed dead worker or the control plane's endpoint-absence proof, plus an explicit destination model and effort.
