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

Session lock detection is separate and does not use the env marker.
`bin/fm-lock.sh` defines `HARNESS_RE` and walks process ancestry to find the session-holding harness PID.
Because the first mate itself runs on Cursor, `fm-lock.sh` must recognize the Cursor process in the ancestry, or `harness_pid()` fails with "cannot locate harness process in ancestry" and the session lock breaks.
This is ancestry-only, so `CURSOR_AGENT` does not help here; the canonical binary token (see the binary-name note below) must be added to `HARNESS_RE`.

Binary-name caution: the canonical binary name is resolved during verification, but `agent` is dangerously generic for the ancestry and lock matchers.
The design prefers a specific token (`cursor-agent`).
If only `agent` exists, the ancestry and lock matchers must use a tightened pattern rather than a bare `*agent*`, and detection should lean on the `CURSOR_AGENT` env marker wherever possible.

### 2. Launch mechanics (`bin/fm-spawn.sh`)

- Add `cursor` to every adapter-name enumeration in the script, not just one.
  There are several distinct lists that each need a `cursor` arm:
  - the `launch_template()` case that maps a harness to its command template;
  - `model_flag_for_harness()` (currently only `claude|codex|opencode|pi|grok`), which must gain a `cursor` case or `__MODELFLAG__` is left empty and the full model id is never passed, defeating the tiered-model plan;
  - the `--secondmate` bare-name-versus-path list (currently `''|claude|codex|opencode|pi|grok`);
  - the per-harness effort handling (cursor emits no effort flag).
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

Teardown (`bin/fm-teardown.sh`) needs concrete cursor branches mirroring the four grok touch points, not just a vague "remove the pointer":

- the dirty-check regex (which currently excludes `.claude/` and `.fm-grok-turnend`) must also exclude `.fm-cursor-turnend`, or a stale pointer in a pooled worktree trips the dirty guard and blocks teardown;
- the two hardcoded worktree-pointer removals (`rm -f ... .fm-grok-turnend`) need a `.fm-cursor-turnend` analog, or the pointer leaks into a reused pool worktree and can fire signals for a dead task;
- the state token cleanup: a `remove_cursor_turnend_auth()` equivalent plus removal of the `$STATE/$ID.cursor-turnend-token` file at both teardown sites (grok has `remove_grok_turnend_auth()` and two `$STATE/$ID.grok-turnend-token` removals).

The global hook itself stays installed on teardown as a harmless no-op.

### 3a. Bootstrap verified-harness allowlist (`bin/fm-bootstrap.sh`)

`fm-bootstrap.sh` hardcodes the verified-harness allowlist (`["claude","codex","opencode","pi","grok"]`) used by `crew_dispatch_validate`.
Until `cursor` is added there, any `crew-dispatch.json` rule with `harness: cursor` is rejected at bootstrap as an unverified harness, which would break the entire configuration plan below.
The `effort_ok` check has no `cursor` arm and falls through to `true`, so cursor model ids and effort are not machine-validated; this is acceptable but must be stated (the ZDR guardrail is a comment, not an enforced check).

### 4. Busy signature and supervision (`bin/fm-watch.sh`, `bin/fm-tmux-lib.sh`)

- Add the Cursor busy-pane signature to the `FM_BUSY_REGEX` defaults; the exact string is captured during verification.
- `suggestNextPrompt` is already `false` in the operator's `cli-config.json`, so no composer ghost-text override is expected; this is confirmed during verification.

### 5. Adapter knowledge (`.agents/skills/harness-adapters/SKILL.md`)

Add a `cursor (VERIFIED <date>)` section recording the busy signature, exit command, interrupt key, trust-dialog handling, the `/no-mistakes` skill-invocation form, resume behavior (`agent resume` / `--continue`), the env marker `CURSOR_AGENT=1`, the autonomy flag `--force`, and a launch-profile row (model via full id, no effort flag).

## Complete touch-point checklist

Derived from a full audit of every place the grok adapter touches the code.
Each item must gain a `cursor` arm:

- `bin/fm-harness.sh`: `CURSOR_AGENT=1` env-marker check before `CLAUDECODE`; `*cursor*` ancestry backstop case.
- `bin/fm-lock.sh`: add the canonical Cursor binary token to `HARNESS_RE` (ancestry-based; required for the first mate to hold the session lock).
- `bin/fm-spawn.sh`: `launch_template()` cursor case; `model_flag_for_harness()` cursor case; `--secondmate` bare-name list; per-harness effort handling (no flag); the global stop-hook install plus per-task pointer and registry writes.
- `bin/fm-teardown.sh`: dirty-check regex exclusion for `.fm-cursor-turnend`; the two pointer removals; `remove_cursor_turnend_auth()` plus `$STATE/$ID.cursor-turnend-token` removal at both sites.
- `bin/fm-bootstrap.sh`: add `cursor` to the verified-harness allowlist used by `crew_dispatch_validate`.
- `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`: add the Cursor busy signature to `FM_BUSY_REGEX`.
- `.agents/skills/harness-adapters/SKILL.md`: the `cursor (VERIFIED ...)` knowledge section and launch-profile row.
- New files: `~/.cursor/hooks/fm-turn-end.sh` (firstmate-owned) and the `~/.cursor/hooks/fm-turn-end.d/` registry directory; per-task `<worktree>/.fm-cursor-turnend` pointer, gitignored via `git info/exclude` (no repo `.gitignore` change needed).

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
- Add tests mirroring existing patterns, using `tests/fm-grok-harness.test.sh` as the primary template since grok is the closest adapter:
  - detection: `CURSOR_AGENT` maps to `cursor`, and ordering relative to `CLAUDECODE`;
  - spawn launch template: autonomy flag present, model passed as a full id via `--model`, no effort flag;
  - turn-end: per-task pointer and registry entry creation;
  - teardown: pointer removal, state token removal, and dirty-check exclusion (grok's test explicitly checks token removal);
  - `fm-lock` recognition: an `fm-lock` cursor-holder test (grok has `test_fm_lock_recognizes_grok_holder`);
  - bootstrap: a `crew-dispatch.json` validation test asserting `harness: cursor` is accepted (mirroring the grok case in `fm-bootstrap.test.sh`);
  - hooks.json merge: a dedicated test that adding the firstmate stop hook preserves the operator's existing `sessionStart` hooks and the bell `notify-stop.sh`, and that teardown leaves them untouched.
- Run the behavior suite (`tests/*.test.sh` per `.no-mistakes.yaml`), open the PR, and the captain merges.
- Because firstmate cannot reliably run on Claude, this implementation is done directly from a Cursor agent rather than dispatched to a Claude crewmate; this is the bootstrap that makes the fleet self-hosting on Cursor afterward.

## Risks and open questions

- Binary name (`agent` versus `cursor-agent`) is resolved during verification.
  `agent` is dangerously generic for the ancestry and lock matchers, so the design prefers `cursor-agent`; if only `agent` exists, use a tightened pattern and lean on the `CURSOR_AGENT` env marker rather than a bare `*agent*`.
- First-run trust dialog per repository is handled in spawn with a peek-and-accept, like claude, codex, and pi.
- The shared `hooks.json` merge is genuinely new risk surface, not a grok mirror: grok installs standalone files it fully owns, whereas Cursor merges into the operator's shared `~/.cursor/hooks.json`.
  The idempotent jq merge and the "leave the no-op installed on teardown" behavior must be treated as their own tested unit, verifying the operator's existing `sessionStart` hooks and `notify-stop.sh` survive both add and teardown.
- ZDR guardrail: dispatch rules are restricted to ZDR-safe model ids by convention and comment only; nothing in the pipeline enforces the allowlist (`effort_ok` has no cursor arm and falls through to `true`), so Fable 5 exclusion is a discipline, not a machine check.
- Long orchestration sessions on the Cursor agent are expected to be fine but will be watched on the first real run.
