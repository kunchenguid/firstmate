# Fabro DAG Integration

This document outlines the architecture, configuration, stage mapping, setup, monitoring, and fallback behavior for Fabro workflow execution alongside Firstmate and Herdr.

## Overview

Fabro enables DAG-based execution and visualization of autonomous coding workflows.
When a Firstmate coding task (`ship` or `scout`) is spawned, Firstmate makes a best-effort Fabro dry-run registration of a DAG workflow (`FirstmateCoding`) representing the lifecycle stages.

Firstmate and Herdr continue supervising the interactive agent terminal and lifecycle events.
Fabro provides an optional validated, dry-run view of the defined lifecycle phases.

## Workflow DAG Definition

The workflow definition resides at `.fabro/workflows/firstmate-coding/workflow.fabro`.

### Stages & State Transitions

1. **Start** (`Mdiamond`): Entry point when task is spawned in an isolated worktree.
2. **Planning** (`box`): Analysis of task intent, inspection of repo state, and formation of implementation plan.
3. **Implementation** (`box`): Code execution and editing within the isolated worktree.
4. **Audit & Review** (`box`): Verification of code quality, running tests, and checking safety gates.
5. **Audit Decision** (`diamond`): Evaluation of audit outcome:
   - *Passed*: Transitions to **Completion**.
   - *Issues Found*: Transitions to **Bounded Fix**.
6. **Bounded Fix** (`box`): Targeted bug fixes or remediation within bounded iterations, returning to **Audit & Review** for re-audit.
7. **Completion** (`box`): Final verification, clean status report, and preparation for landing.
8. **Exit** (`Msquare`): Task reaches terminal done/ready state.

## Setup & Configuration

- `.fabro/project.toml`: Project-level configuration pointing to Fabro version specification.
- `.fabro/workflows/firstmate-coding/workflow.toml`: Workflow metadata and graph reference.
- `.fabro/workflows/firstmate-coding/workflow.fabro`: Graphviz DOT-based DAG specification.

### Validating the Workflow

Run:
```sh
fabro validate .fabro/workflows/firstmate-coding/workflow.fabro
```

## Trigger & Fallback Behavior

When `fm-spawn.sh` launches a worker:
1. `bin/fm-fabro-trigger.sh` is invoked with `<task-id> <worktree> <harness> <kind>`.
2. The trigger checks whether `fabro` is installed on PATH. If missing, it outputs an informative diagnostic and exits cleanly with return code 0.
3. The workflow file is validated. If validation fails or the definition is absent, a diagnostic is logged and spawn continues.
4. A dry-run registration is attempted using `fabro create --dry-run` with attached metadata labels (`firstmate_task_id`, `harness`, `worktree`, `kind`); this optional hook does not gate the Firstmate launch.
5. If the Fabro server or environment is unreachable, the trigger logs the reason and exits cleanly without failing the Firstmate task.

## Cleanup & Herdr Lifecycle

When a coding worker reaches a terminal outcome (`done: ready in branch ...` or scout report completed):
1. `bin/fm-teardown.sh` handles guarded teardown under the task and session locks.
2. The Herdr pane and agent are closed via Herdr's focus-preserving projection cleanup (`fm_backend_herdr_projection_close_pane_focus_preserving` or `fm_backend_herdr_kill_serialized`).
3. Herdr confirms agent/pane removal before releasing task records.
4. Unlanded work is protected: teardown refuses if uncommitted or unmerged changes exist, unless explicit discard authority was given.
