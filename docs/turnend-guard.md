# Primary turn-end supervision guard (reference)

A structural backstop for the "no turn ends blind" discipline (AGENTS.md section 8), scoped to the firstmate PRIMARY session on the `claude` harness only.

## The gap this closes

`bin/fm-guard.sh` is pull-based: it warns whenever some other supervision script (`fm-peek`, `fm-send`, `fm-spawn`, `fm-teardown`, `fm-pr-check`, `fm-wake-drain`, ...) happens to run, and prints nothing otherwise.
The "no turn ends blind" discipline in AGENTS.md section 8 is otherwise enforced only by the agent's own behavior: re-arm the watcher as the last action of every wake-handling turn.

On 2026-07-04, the primary ended a long merge/teardown turn without re-arming the watcher.
Nothing touched the fleet for about nine hours afterward, so `fm-guard.sh` never ran and never had a chance to warn - a parked no-mistakes gate sat unwatched all night.

`bin/fm-turnend-guard.sh` closes that gap by hooking the primary's own turn-end machinery directly, the same class of mechanism crewmates already get (`bin/fm-spawn.sh` installs a per-harness turn-end hook for every task).
Where `fm-guard.sh` is pull-based, this hook is push-based: Claude Code invokes it every time the primary is about to end a turn, whether or not anything else runs that turn.

## Verified Claude Code Stop-hook mechanism (2026-07-04, Claude Code 2.1.201)

Confirmed empirically with a scratch project and a real `claude -p` invocation (see the smoke test transcript below), not just from docs:

- **Input.** Claude Code pipes a JSON payload to the hook command's stdin on every Stop event, including a `stop_hook_active` boolean field: `false` on a normal stop attempt, `true` when the CURRENT stop was itself a forced continuation from an earlier block this same turn. This is Claude Code's own loop-guard signal - a hook does not need to track its own state across invocations to avoid looping.
- **Block mechanism.** Exiting the hook command with status `2` and writing a reason to stderr reliably blocks the stop and feeds that stderr text back to the model as if it were an instruction, forcing the turn to continue. Verified live: a hook that printed `SMOKETEST: you must say the word BANANA before stopping` and exited 2 caused the model's very next message to say "BANANA" before the turn was allowed to end.
- **Loop safety.** Claude Code itself caps consecutive blocks (documented default: 8) regardless of hook behavior, so even a buggy hook cannot wedge a session forever. This guard does not rely on that cap: it checks `stop_hook_active` itself and always allows the stop on the second consecutive fire, so it blocks at most once per turn.
- **Works in headless mode.** The block mechanism was verified both interactively and via `claude -p ... --output-format json` (print/headless mode) - no mode-specific bypass exists.
- **Settings scope.** A project-level `.claude/settings.json` at a repo's root applies once Claude Code's project root is that directory. It does not walk up from a subdirectory looking for one - launching from inside a subdirectory of the project did not trigger the hook in testing. This matches firstmate's own convention of launching the primary session from the repo root (`FM_ROOT`).
- **`CLAUDE_PROJECT_DIR` on Stop hooks (verified 2026-07-04, Claude Code 2.1.201).** Claude Code sets `CLAUDE_PROJECT_DIR` to the project directory whose settings were loaded (the repo root where `.claude/settings.json` lives) when it invokes hook commands.
  Verified empirically with a scratch `.claude/settings.json` and `claude -p` from that directory: a Stop hook that wrote `$CLAUDE_PROJECT_DIR` to a file recorded the expected absolute path.
  Hook commands themselves are executed via `/bin/sh` against the session's **current working directory**, which may differ from the project root if the operator has `cd`'d during the session - a bare relative command such as `bin/fm-turnend-guard.sh` then fails every turn end with `/bin/sh: bin/fm-turnend-guard.sh: No such file or directory`.
  The tracked hook command therefore uses the documented word-splitting-safe form `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh` so resolution is anchored to the settings-loaded project root regardless of cwd.
  `bin/fm-turnend-guard.sh` itself already resolves `FM_ROOT` and state paths from `BASH_SOURCE`, not cwd.

Smoke test transcript (trimmed), corrected hook:

```
$ cat .claude/hook.sh
#!/usr/bin/env bash
input="$(cat)"
active=$(printf '%s' "$input" | python3 -c '...stop_hook_active...')
[ "$active" = "true" ] && exit 0
echo "SMOKETEST: you must say the word BANANA before stopping" >&2
exit 2

$ claude -p "Say hi in exactly one word." --dangerously-skip-permissions --output-format json
...
hook call 1: stop_hook_active=false, last_assistant_message="Hi"   -> blocked (exit 2)
hook call 2: stop_hook_active=true,  last_assistant_message="BANANA" -> allowed (exit 0)
result: "BANANA"
```

(The first attempt at this smoke test had a bug - `python3`'s `print(bool)` emits `True`/`False`, not `true`/`false`, so a naive `[ "$active" = "true" ]` check never matched and the hook blocked three times in a row before being killed. That is itself useful confirmation that repeated blocking works and does not silently stop; the real guard script avoids the bug by using `jq -r` for a lowercase `true`/`false` string.)

## Detection predicate

`bin/fm-supervision-lib.sh` factors the exact "in-flight work exists, but no watcher has a fresh beacon" computation out of `bin/fm-guard.sh` into a shared function, `fm_supervision_unhealthy <state-dir> [grace-seconds]`.
That remains the right predicate for the pull-based guard, where a brief gap after a wake fires should stay silent inside the grace window.
It also exposes `fm_supervision_status` for callers that need the individual fields (in-flight count, beacon freshness/age, queued-wake pending) rather than just the boolean.

`bin/fm-turnend-guard.sh` deliberately uses a sharper end-of-turn predicate.
It first uses `fm_supervision_status` to count in-flight tasks, then requires `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
That shared live-watcher check is the same one used by `bin/fm-watch-arm.sh`: the recorded `state/.watch.lock/pid` must name a live process, the lock's recorded home/path/pid-identity must match the current live pid, and `state/.last-watcher-beat` must still be within `FM_GUARD_GRACE`.
This means a just-exited watcher with a fresh leftover beacon still blocks the Stop hook immediately, while a live but wedged watcher with an ancient beacon also blocks.

## Scoping to the PRIMARY only

`.claude/settings.json` is a TRACKED file at the repo root, so it is checked out into every worktree of this repo: the primary checkout, any crewmate/scout task worktree spawned to work on firstmate itself (the recursive "firstmate improving itself" case, which is how this very feature was built), and every secondmate home (whether acquired via a treehouse lease or a `git clone`, per `bin/fm-home-seed.sh`).
`bin/fm-turnend-guard.sh` must therefore be inert everywhere except the actual primary, and does so at runtime with three checks, all fast (well under a second):

1. **Not a secondmate home.** `bin/fm-home-seed.sh` writes a `.fm-secondmate-home` marker into every secondmate home's root regardless of how it was acquired. Its presence is checked first and is sufficient by itself to exclude secondmate homes.
2. **Not a linked worktree.** `bin/fm-spawn.sh` only ever hands crewmate/scout tasks a genuine linked `git worktree` (it aborts the spawn otherwise - see the worktree-tangle guard in `bin/fm-tangle-lib.sh` and its tests). A linked worktree's `git rev-parse --git-dir` differs from `--git-common-dir` (the former lives under the main repo's `.git/worktrees/<name>`); only a plain, non-worktree checkout has the two equal. This is a structural fact about how `fm-spawn.sh` provisions task worktrees, not a general property of "not being the primary": `bin/fm-brief.sh`'s own generated isolation assertion deliberately does not treat this comparison as authoritative proof for a crewmate verifying itself, precisely because a *secondmate* home acquired via `git clone` (the `ensure_home` path in `bin/fm-home-seed.sh` for an explicit, not-yet-existing home path) also has the two dirs equal. That is exactly why check 1 above is evaluated first and independently - it is what actually rules out that case here.
3. **Looks like a firstmate session.** `AGENTS.md` and `bin/` exist at the resolved root, and the effective state dir exists after the same `FM_STATE_OVERRIDE` / `FM_HOME` / repo-root fallback used by the other firstmate scripts - cheap defense in depth against the settings file somehow loading somewhere unrelated.

Both `.claude/settings.json` (tracked, this hook) and a task's own `.claude/settings.local.json` (untracked, the per-task `touch` turn-end signal `bin/fm-spawn.sh` installs) can be present simultaneously in the same crewmate task worktree; Claude Code merges the `Stop` hook arrays from both. That is fine: this hook's scoping check makes it a no-op there regardless.

This design is deliberately different from the per-task `.claude/settings.local.json` crewmate hook, and does not worsen the class of problem in GitHub issue #234 (stale Stop-hook entries accumulating in a pooled worktree's `.claude/settings.local.json` across task reuse): that issue is about a dynamically-*written*, untracked, per-task file that can accumulate stale entries across pooled-worktree reuse. `.claude/settings.json` here is a single static TRACKED file - every `git checkout` resets it to the same committed content, so there is nothing to accumulate.

## Installation path

Tracked, not local: `.claude/settings.json` ships in the repo, so every user of this repo gets the guard after a normal `git clone` and a primary session run from the repo root - no bootstrap step, no per-user local file, no manual setup.
The Stop hook command is `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh` (not a bare relative path) so Claude Code's `/bin/sh` invocation still finds the script when the session cwd is not the repo root.
This is possible (unlike the crewmate per-task hook) because the guard script is fully generic: it resolves its own root from its own location and re-derives the predicate at runtime, with no per-task specifics to bake in.

## Harness coverage

Verified and active on `claude` only, since that is what the primary runs today.
Other harnesses (`codex`, `opencode`, `pi`, `grok`) do not get this structural backstop yet; `fm-guard.sh`'s pull-based warning is still their only defense.
Extending this is future work, following the same empirical-verification-before-trusting-a-mechanism pattern used for each harness's turn-end hook in `bin/fm-spawn.sh` and documented in the `harness-adapters` skill (e.g. grok's Stop hook required a global, trust-gate-free hook location because project hooks need an explicit trust grant firstmate cannot establish at launch).
