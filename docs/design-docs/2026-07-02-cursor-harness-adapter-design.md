# Cursor agent harness adapter

Status: approved design, pending implementation plan.
Date: 2026-07-02.

## Problem and motivation

firstmate currently supports the harnesses claude, codex, opencode, pi, and grok.
The operator's organization cannot rely on direct Claude access for real work: Anthropic org usage limits make it unreliable, and the organization's Business Associate Agreement (BAA) for PHI-adjacent work is with Cursor, not with the direct Anthropic or OpenAI APIs.
The Cursor agent CLI routes to models under Cursor's BAA with zero-data-retention (ZDR) enforcement, which is the only compliant and reliable harness for this operator.

Goal: make `cursor` a first-class, verified firstmate harness so that both the orchestrator (first mate) and the crewmates run on the Cursor agent, fully off direct Claude.

## Constraints

- Compliance first: crewmates run autonomously against real repositories, so every model they use must be ZDR-safe.
  Fable 5 is explicitly excluded because it is tagged non-ZDR.
- The firstmate repository is itself behind its own `no-mistakes` validation gate and is a shared template, so the change must land as an upstream pull request through that pipeline.
- The running fleet's primary checkout must not be disturbed: all feature work happens in a dedicated git worktree on a feature branch, never by switching the primary checkout's branch (that would trip firstmate's tangle guard).

## Decisions made during brainstorming

- Scope: both the first mate and the crewmates run on Cursor.
- Persistence: land the adapter as an upstream PR through firstmate's `no-mistakes` pipeline (survives `/updatefirstmate`, reviewable, benefits everyone).
- Models: tiered via `config/crew-dispatch.json`, heavy work on `claude-opus-4-8-thinking-max`, light work on a faster ZDR-safe tier; the orchestrator runs a lighter ZDR-safe model.
- Turn-end supervision: a global guarded `stop`-hook, following the grok adapter pattern.

## Reference implementation

The grok adapter (commit `2a661da`, "feat: add grok crewmate harness support") is the closest existing template.
It already establishes the pattern this design reuses: an autonomy flag, a global firstmate-owned turn-end hook guarded to a no-op for non-firstmate sessions, and a per-task token pointer plus registry entry in the worktree.

## Adapter design

### 1. Detection (`bin/fm-harness.sh`)

Add a Cursor env-marker check to `detect_own()` placed before the `CLAUDECODE` check:

```sh
[ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
```

Ordering matters as insurance: a Cursor session running a Claude model reports `AI_AGENT=claude-code_...`, and if it ever also exported `CLAUDECODE=1` the existing claude check would win and misdetect the harness.
Empirically, `CURSOR_AGENT=1` is set for Cursor agent child and tool processes, and `CLAUDECODE` is unset, but the ordering removes the risk regardless.
Add a `*cursor*` case to the process-ancestry backstop as a secondary signal.

### 2. Launch mechanics (`bin/fm-spawn.sh`)

- Add `cursor` to the accepted adapter names.
- Launch template (positional prompt plus autonomy):

```sh
agent __MODELFLAG__--force "$(cat __BRIEF__)"
```

- `--force` is the autonomy flag, equivalent to claude's `--dangerously-skip-permissions`.
- No `--effort` flag is emitted for Cursor: effort is encoded in the model id (for example `claude-opus-4-8-thinking-max`), so dispatch passes the full model id via `--model` and firstmate records `effort=` in meta without emitting a flag.
  This reuses the existing "unsupported effort is recorded but not passed" pattern.
- Turn-end does not ride the launch command; it is delivered by the global hook below, exactly as grok does.
- The canonical binary name (`agent` versus `cursor-agent`) is confirmed during verification and the template uses whichever is canonical.

### 3. Turn-end: global guarded `stop`-hook

- firstmate owns `~/.cursor/hooks/fm-turn-end.sh` and ensures the `stop` array in `~/.cursor/hooks.json` contains it, added idempotently with `jq` and merged with the operator's existing hooks (the `sessionStart` hooks and the bell `notify-stop.sh`), never overwriting them.
- On each spawn firstmate writes `<worktree>/.fm-cursor-turnend` (a token pointer, gitignored via `git info/exclude`) and a registry entry at `~/.cursor/hooks/fm-turn-end.d/<token>` naming that task's `state/<id>.turn-ended`.
- On a `stop` event the hook reads the payload's `workspace_roots`, finds the pointer in that root, resolves the registry entry, and touches the referenced `turn-ended` file.
  It is a no-op for any non-firstmate Cursor session.
- Teardown removes the per-task pointer and registry entry; the global hook stays installed as a harmless no-op.

### 4. Busy signature and supervision (`bin/fm-watch.sh`, `bin/fm-tmux-lib.sh`)

- Add the Cursor busy-pane signature to the `FM_BUSY_REGEX` defaults; the exact string is captured during verification.
- `suggestNextPrompt` is already `false` in the operator's `cli-config.json`, so no composer ghost-text override is expected; this is confirmed during verification.

### 5. Adapter knowledge (`.agents/skills/harness-adapters/SKILL.md`)

Add a `cursor (VERIFIED <date>)` section recording the busy signature, exit command, interrupt key, trust-dialog handling, the `/no-mistakes` skill-invocation form, resume behavior (`agent resume` / `--continue`), the env marker `CURSOR_AGENT=1`, the autonomy flag `--force`, and a launch-profile row (model via full id, no effort flag).

## Configuration

All of the following are local and gitignored.

- First mate on Cursor: launch the orchestrator with a lighter ZDR-safe model, for example `agent --model claude-opus-4-8-high-fast` from the firstmate home.
- `config/crew-dispatch.json`: tiered rules, all `harness: cursor`, with ZDR-safe model ids.
  - Heavy, architecture, or multi-file work maps to `claude-opus-4-8-thinking-max`.
  - Quick or scoped fixes map to `claude-opus-4-8-thinking-high-fast`.
  - The `default` profile maps to `claude-opus-4-8-thinking-high-fast`.
- `config/crew-harness` set to `cursor` as the fallback when no dispatch rule matches.
- Model ids are tunable; the defaults above are strong but ZDR-safe, and Fable 5 is excluded everywhere.

## Verification trial

Before finalizing, a supervised throwaway task using fm-spawn's raw-launch escape hatch confirms the unknowns by observing the live Cursor TUI:

- busy-pane signature for `FM_BUSY_REGEX`
- exit command, interrupt key, and first-run trust-dialog flow
- the `/no-mistakes` skill-invocation form
- the canonical binary name (`agent` versus `cursor-agent`)
- whether `CLAUDECODE` appears when running a Claude model
- composer ghost-text behavior

The verification is driven directly from a Cursor agent, which can observe Cursor behavior firsthand.

## Landing as an upstream PR

- All work happens on the `feat/cursor-harness-adapter` branch in a dedicated worktree, leaving the fleet's primary checkout on `main`.
- Implement the adapter (sections 1 through 5) plus the configuration documentation.
- Add tests mirroring existing patterns such as `fm-secondmate-harness.test.sh`: detection (`CURSOR_AGENT` maps to `cursor`, and ordering relative to `CLAUDECODE`), the spawn launch template (autonomy flag present, model passed as a full id, no effort flag), turn-end pointer creation, and teardown cleanup.
- Run the behavior suite (`tests/*.test.sh` per `.no-mistakes.yaml`), open the PR, and the captain merges.
- Because firstmate cannot reliably run on Claude, this implementation is done directly from a Cursor agent rather than dispatched to a Claude crewmate; this is the bootstrap that makes the fleet self-hosting on Cursor afterward.

## Risks and open questions

- Binary name (`agent` versus `cursor-agent`) is resolved during verification.
- First-run trust dialog per repository is handled in spawn with a peek-and-accept, like claude, codex, and pi.
- The `hooks.json` merge must be idempotent and must preserve existing hooks.
- ZDR guardrail: dispatch rules are restricted to ZDR-safe model ids, with a comment so Fable 5 is not added later.
- Long orchestration sessions on the Cursor agent are expected to be fine but will be watched on the first real run.
