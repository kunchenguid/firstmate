---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through classed relaunch (the bin/fm-harness.sh escalation ladder) or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
A reader scout (`access=reader` in its metadata) holds no treehouse entry by design: its recorded `worktree=` is a disposable scratch directory, so verify that directory directly.
Only a recovery-grade dead or missing result licenses relaunch; re-pass the same `--access reader` flag because the brief cross-check in `bin/fm-spawn.sh` refuses a writer relaunch.
An `unknown` liveness result preserves the recorded worktree or reader scratch, metadata, and any unlanded work and surfaces the task for targeted inspection; never relaunch under uncertainty, following `AGENTS.md` section 5's reconciliation rule and `process-event-sources`' uncertain-process-identity rule.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that its recorded writer worktree or reader scratch remains available.
Preserve a writer's uncommitted changes and commits or a reader's scratch evidence, keep the same task identity, and resume or relaunch the recorded harness in that same task environment with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded task environment is unaccounted for, because allocating another worktree or scratch root can split one task across two copies.
If the task environment or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch through the escalation ladder below, with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   A writer's worktree and commits persist; a reader's scratch persists while `fm-spawn.sh` replaces its disposable read handle at the recorded baseline.
5. If the ladder's verdict is `escalate-captain`, stop relaunching: write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.

## Escalation ladder on relaunch

Before any step-4 relaunch, classify the failure from the evidence, then resolve the relaunch tuple with `bin/fm-harness.sh escalate <id> --class <class>`; that command owns the ladder mechanics, ceilings, and attempt budget.
Retrying the same tuple after a substantive failure is the behavior this replaces; escalating on a mechanical signal burns the strongest tier on noise.

Failure classes and their signals:

- `substantive` - the evidence points at the worker's reasoning, not its environment: it produced a wrong answer or shipped a wrong fix, looped or stayed confused after a redirect, failed the same validation gate twice, or kept asking questions its brief already answers.
  The ladder raises effort one rung on relaunch.
- `injection` - the worker refused its brief citing safety or prompt-injection suspicion.
  The brief is trusted firstmate content, so the refusal is a harness behavior difference: the ladder rotates to a different verified harness at the same requested tier.
  An adapter without a flag for that tier launches at its own default while the requested effort stays on the task metadata; a later substantive failure there resolves `effort-capped` or `effort-unsupported`, never a false `effort-ceiling`.
- `mechanical` - the evidence points at the environment, not capability: worktree acquisition timeout, network or vendor API errors, a denied permission or trust dialog, backend or spawn errors, or the worker killed by machine memory pressure.
  The ladder relaunches the identical tuple; a mechanical failure that keeps recurring exhausts the attempt budget and goes to the captain, because the environment needs a human, not a stronger model.

Act on the verdict:

- `relaunch` - respawn through `bin/fm-spawn.sh` into the same recorded task environment with the emitted `--harness`, `--model`, and `--effort` values, re-pass an emitted `account_profile=` alias as `--account-profile` unchanged, and pass `--routing-source fallback` again so the task stays ladder-eligible on the respawned meta.
  When `config/crew-dispatch.json` is active, the respawn must also carry `--dispatch-override-reason "escalation-ladder relaunch <class>"`: the routing came from the ladder, not from fresh profile consultation, and the attestation backstop refuses an unattested explicit harness.
  A relaunch is an ordinary crewmate or scout spawn for the durable routing cooldowns too, so while `data/quota-cooldowns.json` exists it carries the catalog-established `--dispatch-provider` and `--dispatch-model-family` axes like any other spawn (`AGENTS.md` section 4; `docs/configuration.md` "Routing cooldowns").
- `report` (`routing-pinned` or `unknown-provenance`) - the ladder may not touch this task's routing: an explicit captain instruction or a configured dispatch profile or pin resolved the tuple, or the meta predates provenance recording.
  Relaunch the unchanged tuple by the ordinary path, re-passing an emitted `account_profile=` alias as `--account-profile` unchanged, and tell the captain at the next natural report that the failure looked substantive but routing was pinned, so the tier held.
  Never escalate through a pin.
  A report still spends an attempt, so a task that only ever reports reaches the same budget ceiling and then goes to the captain instead of relaunching forever.
- `escalate-captain` - the ladder hit a ceiling (`effort-ceiling`, `effort-capped`, `effort-unsupported`, `attempt-budget`, `harness-not-rotatable`, or `account-profile-harness-bound`): follow step 5.
  `effort-capped` and `effort-unsupported` mean the harness would launch identically at the higher rung, so a stronger tier is not available on this adapter without the captain choosing a different one.

The ladder never selects `max` effort on its own; that level requires the captain's explicit preference, as enforced by `bin/fm-harness.sh`.
