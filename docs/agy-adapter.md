# Agy (Antigravity CLI) adapter verification

Verification date: 2026-07-21.
Version: Agy CLI 1.1.4 (`agy --version`).
Binary: `/Users/hsuan/.local/bin/agy`.
Host: macOS aarch64.

## Empirical facts

### Launch

Correct worktree launch requires `--new-project`.
Without it the tool cwd falls back to `~/.gemini/antigravity-cli/scratch` instead of the worktree directory.
Interactive initial prompt flag: `--prompt-interactive`.
Combined launch for a crewmate (see `bin/fm-spawn.sh` `launch_template` for the exact template):

```
agy --dangerously-skip-permissions --new-project --prompt-interactive "$(cat <brief>)"
```

`--dangerously-skip-permissions` auto-approves all tool permission requests without prompting.
Verified: both a `read_file` call and a `run_command` call completed without any per-call permission gate in print mode.

### Trust prompt

First launch in a fresh worktree shows a trust prompt.
Accepting it: Enter on "Yes, I trust this folder".
The decision is persisted per project root and subsequent launches in the same worktree skip the prompt.

### Busy signature

`esc to cancel` (verified from supervisor pane observation during `sleep 8` probe, Agy CLI 1.1.4, 2026-07-21).
This is the mid-turn cancel hint Agy renders while a tool call or agent turn is running.
Added to `FM_TMUX_BUSY_REGEX_DEFAULT` in `bin/fm-tmux-lib.sh` and `bin/fm-watch.sh` as `esc (to )?(interrupt|cancel)`.
The `(to )?` is shared with `esc interrupt` (opencode) and `esc to interrupt` (claude/codex), so the combined pattern matches all three without a separate agy branch.

### Idle composer

Bare `>` between horizontal separators.
Footer shows `? for shortcuts`.
The `>` prompt glyph inside a bordered composer box is already classified as `empty` by `fm_composer_classify_content` in `bin/fm-composer-lib.sh` (the `bordered=1` path).
No `FM_COMPOSER_IDLE_RE` override is needed.

### Interrupt

One Escape.
Empirically interrupted `sleep 30` and returned to idle.

### Exit

`/exit`.
Prints `Resume with -c` plus `agy --conversation=<id>`.
fm-send's universal slash-command settle (1.2 s) handles the `/exit` popup correctly on both tmux and herdr paths.

### Resume

```
agy --dangerously-skip-permissions --conversation=<id>
```

Empirically returned to the same idle conversation.

### Child environment marker

`ANTIGRAVITY_AGENT=1` is set for all child and tool processes.
Added to `bin/fm-harness.sh` Layer 1 (env-marker detection) and Layer 2 (process ancestry walk for the binary name `agy`).

### Model flag

`--model <MODEL>`.
No separate effort flag has been verified for the interactive `--prompt-interactive` launch path.
`bin/fm-spawn.sh` threads `--model` through `model_flag_for_harness` and omits an effort flag for agy (no verified equivalent).

### Autonomy

`--dangerously-skip-permissions` is the verified autonomy flag.
Confirmed: tool calls ran fully unattended in non-interactive (`--print`) mode.

## Turn-end hook

No verified crewmate or primary turn-end hook mechanism was found for Agy CLI 1.1.4.
Agy does not expose a documented Stop hook, a per-session notify flag, or a plugin extension point analogous to claude/codex Stop hooks, grok's global hook, opencode's `session.idle`, or pi's `turn_end`.
`bin/fm-spawn.sh` installs no turn-end hook for `agy*` crewmate spawns.
Stale-pane detection in `bin/fm-watch.sh` (the `stale:` wake path) is the supervision fall-back.

Consequence for primary and secondmate:
Because no verified turn-end hook contract exists, agy cannot safely serve as a primary firstmate session (the "no turn ends blind" guard has no verified adapter) or as a secondmate.
`bin/fm-spawn.sh` refuses `--secondmate` spawns with `harness=agy` with a targeted error.
`bin/fm-harness.sh` does detect `ANTIGRAVITY_AGENT=1` as a valid env marker so firstmate running inside Agy knows its own harness, but no `.agy/hooks/` or equivalent path is wired.

If Agy exposes a hook or plugin API in a future release, verify it empirically and record the findings here before wiring it into `bin/fm-spawn.sh` and `docs/turnend-guard.md`.

## Scope

Crewmate and scout spawns only.
`bin/fm-spawn.sh` template: `launch_template() agy`.
Supported axes: `--model`.
No effort flag.
Secondmate spawns: refused (see above).
Primary session guard: not wired.

## Known gaps

- The residual tmux cursor-row quirk documented in the grok section of `.agents/skills/harness-adapters/SKILL.md` for grok's pristine-placeholder state may apply to agy as well if its composer also renders a placeholder before any real typing starts.
  Agy's `--prompt-interactive` always delivers the initial brief before the interactive pane becomes visible to firstmate, so in practice a live task's composer is never observed in this pristine pre-typing state.
  The gap is theoretical for the current launch path.
- `agy models` returned empty output in the scout probe (possibly auth-gated for listing); the default model name is not surfaceable from `agy --version` or `agy --help` alone.
  The model is set at spawn time via `--model` when firstmate specifies one; otherwise agy uses its own default.
