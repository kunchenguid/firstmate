---
name: context-handoff
description: Agent-only playbook for handing a context-heavy crewmate's work to a fresh agent instead of /compact. Use when the watcher flags a task at >=60% of its context window (via state/<id>.context). Orchestrates the swap with existing tools - old crewmate dumps resume-context to data/<id>/handoff.md, fm-spawn --reuse-worktree relaunches a fresh agent on the same worktree/branch seeded with that dump, then the old agent is retired. Preferred over /compact for large multi-phase tasks.
user-invocable: false
metadata:
  internal: true
---

# context-handoff

Use this playbook when the watcher flags a live crewmate at **>=60%** of its context window.
The flag is harness-truth, not a model self-report: the crewmate's per-turn `Stop` hook writes `state/<id>.context` (context tokens summed from the transcript's last `usage` record), and the watcher fleet-scan reads it against the window implied by `state/<id>.meta` `model=` (1M for Opus/Sonnet, 200k for smaller-context models).

**Why a fresh agent, not `/compact`.**
`/compact` is lossy in-place summarization that degrades further on every re-compact.
A fresh agent starts at 0% context, deterministic, and is reseeded by a dump the crewmate *deliberately authored* (it chooses what matters, unlike an auto-summarizer).
One dump-and-reload turn is worth it for large, multi-phase tasks; it is overkill for small ones, so this only fires at the 60% threshold.
The in-progress diff is never discarded: the handoff reuses the crewmate's existing worktree and branch.

## Applicability by harness

- **claude** (default): full support. The `Stop` hook writes `state/<id>.context` every turn, so detection is exact.
- **codex / grok / opencode**: no equivalent transcript/hook shape. Detection falls back to the idle-pane footer scrape where available, or is skipped. Do not force a handoff on a harness with no honest context signal.

## When to execute

Flag at 60%, but **execute at the crewmate's next idle turn-boundary** - never mid no-mistakes validation run. Let an in-flight pipeline finish first; a swap during validation would strand the run.

**Auto vs ask (default auto).** Perform the handoff autonomously and send the captain a one-line FYI. Escalate to the captain *before* swapping only if the crewmate is mid-critical (e.g. a delicate uncommitted state that the dump may not fully capture). This default is captain-configurable.

## Steps

1. **Steer the old crewmate to dump (one `fm-send` line).** Instruct it to write all resume-context to `data/<id>/handoff.md`, then stop. The dump must cover:
   - task state and current goal,
   - decisions made and why,
   - files touched and why,
   - a diff summary (what is committed vs working-tree),
   - what is done and what remains,
   - repro / test commands,
   - gotchas and dead-ends already ruled out.

   `data/<id>/handoff.md` lives **outside** the worktree, so it survives the swap and never dirties the branch. Send exactly one line via `bin/fm-send.sh`; anything longer belongs in a file.

2. **Wait for the dump.** Wait for the crewmate's turn-end signal AND for `data/<id>/handoff.md` to exist and be non-trivial. If the crewmate stalls or the file is missing, fall back to `stuck-crewmate-recovery` rather than swapping on an empty dump.

3. **Relaunch a fresh agent on the same worktree.**
   ```sh
   bin/fm-spawn.sh --reuse-worktree <id>
   ```
   This skips `treehouse get`, reuses the crewmate's existing worktree from `state/<id>.meta`, keeps the same task id and `fm/<id>` branch, re-installs the turn-end/context hook, updates the meta window/pane target, and launches the harness seeded with **the original brief + `data/<id>/handoff.md` + "resume from here."** It is the agent swap; it is NOT `fm-teardown` (which destroys the worktree).

4. **Retire the old agent.** Kill only its pane (`tmux kill-pane` for tmux, or the harness's exit for others). Keep the same task id and worktree. The new agent is now the crewmate of record for `<id>`.

5. **Note the swap to the captain (FYI) and continue normal supervision.** One outcome line: the task was handed to a fresh agent to keep context healthy; work and diff are intact. Re-arm the watcher as usual.

## Guardrails

- Never discard the worktree or its uncommitted diff - the whole point is that the in-progress work carries over.
- Never swap mid no-mistakes validation; wait for the idle turn-boundary.
- If the dump is missing or empty after the crewmate stops, do not proceed - recover the crewmate instead.
- The reused worktree keeps the same branch, so the eventual PR is unaffected.
