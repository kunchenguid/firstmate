---
name: herdr-recovery
description: >-
  Agent-only playbook for the fleet-wide post-restart Herdr seat sweep.
  Use after a Herdr server or firstmate harness update restart, or whenever many recorded seats show "[ ! ] Action Required" panes at once, to bring every blocked codex seat back to processing with one command under the approval-boundary safety contract.
  Per-seat judgment beyond pane input belongs to stuck-crewmate-recovery.
user-invocable: false
metadata:
  internal: true
---

# herdr-recovery

Run this after a Herdr server restart or a firstmate harness update that
interrupted live workers, or whenever many seats sit on "[ ! ] Action Required"
panes at the same time. It is the one-command fleet sweep for the mass
trust-dialog and command-approval re-presentation that follows every such
restart; run it instead of hand-sending Enter pane by pane.

## The command

```
FM_HOME=<this home> bin/fm-herdr-recovery.sh [--dry-run] [--max-rounds N]
```

`bin/fm-herdr-recovery.sh`'s own header is the single owner of the mechanics:
seat inventory from `state/<id>.meta`, per-pane classification, the
prompt classifier, the recovery-read allowlist, the round cap, and the exit
codes. Run `--dry-run` first when you want the report without any keystrokes.

## Safety contract

- The tool drives only the invoking home's recorded seats and only ever sends
  Enter; it never types 'p' (don't-ask-again).
- It approves only file-read prompts inside the allowlist, refuses any command
  touching credentials, git, installs, network, or mutation, and leaves every
  prompt it cannot classify untouched as needs-human.
- The tool is idempotent and safe to re-run during an update window; a second
  run reports no-op on recovered seats.
- Never kill or restart Herdr processes as part of recovery.

## Relationship to stuck-crewmate-recovery

This tool owns the fleet-wide post-restart sweep only. A seat it reports as
`needs-human`, `no-pane`, or otherwise not recovered needs per-seat judgment:
load `stuck-crewmate-recovery` for those seats and reconcile each one through
its recorded endpoint before any relaunch decision. A seat the tool reports
`recovered` needs nothing further; supervision resumes normally.
