# Antigravity CLI (agy)

The router owns agy's task-kind boundary: it is a crewmate and scout adapter only, never a primary or secondmate.
It is selectable only by an explicit per-task choice because it has no usable `spendPriority`.
`../../../docs/verification/agy.md` owns the dated evidence, measured rationale, exact commands, and tested boundaries.

## Operating rules

- Launch with `agy --dangerously-skip-permissions -i "<brief>"`; never pass the brief positionally.
- Treat only the exact harness and process name `agy` as this verified adapter.
- Detect child processes from `ANTIGRAVITY_AGENT=1`, ahead of inherited foreign markers.
- Answer the workspace-trust dialog with one Enter, only once its question is on screen together with a line whose only letters are `Yes, I trust this folder`, and prove no readiness after it: a launch that never starts is ordinary stuck-worker territory. `../../../docs/verification/agy.md` records what that match does and does not exclude.
- Answering that dialog adds the worktree path to agy's own `trustedWorkspaces`, and teardown deliberately leaves the entry, so a reused path never shows the dialog again and the poll waits out its window there.
- Count only a `Stop` payload with `fullyIdle: true` as a turn end; false, absent, malformed, and foreign-workspace payloads are no-ops.
- Install the guarded global hook only in agy's firstmate-owned `plugins/fm-turn-end/` directory under the fixed `~/.gemini/config` root, require `jq`, and leave agy's own `config.json` and `hooks.json` and all project configuration untouched.
- Classify worker state as `unknown agy-unverified` unless Herdr's native arm positively proves streaming work.
- Use `esc to cancel` only as a delivery acknowledgement, never as semantic worker state.
- Interrupt with one Escape and no clear key.
- Exit with `/exit` plus Enter.
- Relaunch through Firstmate; native conversation forms are `agy --conversation=<id>` and `agy -c`.
- Discover models with `agy models`; pass `--model <id>`.
- Pass `--effort` only for `low`, `medium`, or `high`, omitting unsupported levels.

`../../../tests/fm-agy-surface-live-e2e.test.sh` is the opt-in guard that refreshes the empirical record.
