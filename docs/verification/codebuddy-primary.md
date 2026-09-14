# Verification: the CodeBuddy Code primary harness

Active empirical facts for firstmate's codebuddy primary wiring.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/codebuddy.md`](../../.agents/skills/harness-adapters/references/harness/codebuddy.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `codebuddy 2.150.0` (alias `cbc`) |
| Verified | 2026-09-14 |
| Binary | `/Users/huangjiepeng/.local/bin/codebuddy`, a Mach-O single binary symlinked into `~/.local/share/codebuddy/versions/2.150.0/codebuddy` |
| Platform | macOS x86_64 |
| Session | The primary session itself ran as codebuddy in this checkout (`/Users/huangjiepeng/github/firstmate`) |

## Hook platform contract

CodeBuddy is a Claude Code clone at the hook layer, which is what lets the primary wiring reuse the Claude-family scripts instead of inventing a wake protocol.
`strings` over the 2.150.0 binary contains `SessionStart`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStop`, `UserPromptSubmit`, `PreCompact`, `Notification`, `hookSpecificOutput`, `additionalContext`, `stop_hook_active`, and `asyncRewake`.
The hook schema the binary validates includes `timeout` (converted as `1000 * timeout`), the boolean `asyncRewake`, `once`, `shell`, `allowedEnvVars`, `statusMessage`, and `if`.
The payload builder emits Claude's field names verbatim (`hook_event_name`, `session_id`, `transcript_path`, `cwd`, `tool_name`, `tool_input`, `stop_hook_active`), so `bin/fm-turnend-guard.sh` reads it unchanged.
A live session also exports `CLAUDE_PROJECT_DIR` and `CLAUDE_SESSION_ID`, which is why the tracked hook file can address this home through `$CLAUDE_PROJECT_DIR` exactly as the tracked Claude file does.

## Where project settings come from

CodeBuddy reads project settings from `.codebuddy/settings.json` and `.codebuddy/settings.local.json`, NOT from `.claude/settings.json`.
The binary's own path strings contain `.codebuddy/settings.json` and `.codebuddy/settings.local.json` and no `.claude/settings.json`.
The live startup log records the source order:

```
[CliSettingSourcesProvider]  Setting sources initialized: user -> project -> local
```

This is why the primary wiring is a new tracked `.codebuddy/settings.json` rather than a reuse of the tracked Claude file, and why that file deliberately omits the Claude file's `GROK_AGENT` guard: codebuddy never loads the Claude settings file, so the guard would be dead noise.

Project-scope discovery was proven live on the running session: immediately after the tracked `.codebuddy/settings.json` was written into this checkout, the same session began firing the registered `PreToolUse` cd guard.

```
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[persistent-cd] a persistent top-level directory change in the primary firstmate checkout is blocked; ..."}
```

No restart and no trust prompt were involved, so project settings are read for the working directory and their hooks run.

## Hook execution, session cwd, and context injection

`tests/fm-codebuddy-primary-live-e2e.test.sh` runs a real `codebuddy --print` with an explicit `--settings` file holding one `SessionStart` command hook, and pins `--setting-sources user` so the tracked project file (and therefore this home's own digest) does not run.

```
$ FM_CODEBUDDY_PRIMARY_LIVE=1 bash tests/fm-codebuddy-primary-live-e2e.test.sh
ok - codebuddy: a SessionStart hook runs, sees CLAUDE_PROJECT_DIR, and its stdout reaches model context
```

The probe proves three things at once: the command hook runs at all, the hook process receives `CLAUDE_PROJECT_DIR` pointing at the session's working directory (it wrote `/Users/huangjiepeng/github/firstmate`), and the hook's stdout reaches model context (the model echoed the hook's marker token verbatim).
Those three are exactly what `bin/fm-sessionstart-run.sh`'s digest transport relies on.

## A codebuddy primary can hold the fleet lock

Before `bin/fm-session-lock-lib.sh` listed codebuddy, no codebuddy process could be recognized as a verified harness in the ancestry walk, so a codebuddy primary could never hold `state/.lock` and `bin/fm-claude-stop-autoarm.sh` could never arm for it.
The vocabulary now matches `^codebuddy$|^cbc$` plus the versioned install path components, and the live behavior was confirmed by running a nested `codebuddy --print` session in this checkout: the tracked `SessionStart` hook ran the real `bin/fm-sessionstart-run.sh` against the live home, and `state/.lock` moved from a stale, dead owner to the live codebuddy pid.

```
$ cat state/.lock
34080
$ ps -o pid=,ppid=,comm= -p 34080
34080 34079 codebuddy
```

The nested session was stopped mid-run, and `state/.lock` retained its now-dead pid; that is `bin/fm-lock.sh`'s ordinary stale-owner state, and reclaiming it is the same guarded recovery path every other harness relies on, so no codebuddy-specific handling was added or needed.

## Stop auto-arm and rewake, verified live

The Stop half of the tracked registration ran for real in this checkout during the same session.
Ending a turn with supervision needed produced the Claude-family pair: `bin/fm-claude-stop-autoarm.sh` (registered under `asyncRewake`) started one watcher cycle, that cycle closed on an actionable check, and the hook committed an exit-2 rewake which the harness delivered as a `Stop hook feedback` message carrying `check: rearm-resurface`.

The durable artifacts agree, and they are all Claude-family state because the codebuddy registration reuses that pair verbatim:

```
$ tail -1 state/.claude-autoarm-epoch
epoch=106 owner_pid=6467 outcome=rewake updated_at=1789386023 session_pid=29610 recovery_generation=7033.1789386022.tsg7JO
$ tail -1 state/.watch-cycle-exits.log
arm_pid=6825	watcher_pid=6840	origin=started	started_at=1789386021	ended_at=1789386023	exit_code=0	signal=none	reason=actionable-check	beacon_age=1	lock_before=pid:6840|identity:...fm-watch.sh	lock_after=pid:none|identity:none	successor=none
```

Three things are proven by that pair of lines: a real watcher process was armed at the Stop boundary and exited on its own actionable check, the auto-arm committed a `rewake` outcome rather than a failure, and the claim was bound to a live codebuddy session pid (`session_pid=29610`), which is the session-lock ownership proof that the vocabulary change is what makes possible.
The wake drained clean on the follow-up turn with no open decisions or unread status entries, and its exact `--ack-through --recovery-generation` acknowledgement was accepted.

## Offline pins

- `tests/fm-codebuddy-harness.test.sh` pins the anchored ancestry names and their longer-name rejections, the non-promotion of `CODEBUDDY_*` runtime variables, the session-lock and liveness vocabularies, the `autoarm` supervision model, the rendered codebuddy supervision protocol and its repair/ordinary-wake lines, the `--codebuddy` guard alias, and the tracked hook file's structure.
- `tests/fm-supervision-instructions.test.sh` carries the same protocol assertions through the shared renderer matrix.
- `tests/fm-turnend-guard.test.sh` continues to pin the tracked Claude file, which the codebuddy file mirrors.

## What is still unproven

The turn-end guard's own blocking path (`bin/fm-turnend-guard.sh --codebuddy` re-blocking when no watcher and no auto-arm claim exist) was not exercised: every observed Stop was allowed by a healthy watcher or by the auto-arm's open claim, which is the co-operating path and the one the protocol wants.
Its `--codebuddy` alias is pinned offline to the shared `--claude` mode, so only the live blocking branch is unobserved.
Interactive composer shape, interrupt behavior (single `Escape`, and whether an interrupt repollutes the composer), and busy-state classification for codebuddy *workers* remain unverified, so `bin/fm-spawn.sh` still arms no worker busy source for it.
codebuddy is still refused as a secondmate, and no codebuddy secondmate lifecycle has been attempted.

## Refreshing this record

Run the portable suite and the isolated live guard after any codebuddy upgrade, because the settings path, hook schema, and `CLAUDE_PROJECT_DIR` behaviour are vendor-controlled surfaces the primary wiring matches verbatim:

```
bin/fm-test-run.sh tests/fm-codebuddy-harness.test.sh
FM_CODEBUDDY_PRIMARY_LIVE=1 bin/fm-test-run.sh tests/fm-codebuddy-primary-live-e2e.test.sh
```

Close the remaining gaps by running one attended interactive codebuddy primary session in this checkout with work under way and forcing the blocking branch: arrange for supervision to be needed while no watcher is healthy and no auto-arm claim is open (for example by ending a turn with the watcher stopped and `bin/fm-claude-stop-autoarm.sh` made ineligible), then confirm `bin/fm-turnend-guard.sh --codebuddy` re-blocks with its repair banner and respects its bounded block budget.
