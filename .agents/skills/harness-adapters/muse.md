## muse (VERIFIED 2026-08-05, Muse Code 0.1.0-R708.1, build sha 427a430436)

Muse Code is a CREWMATE and SCOUT adapter only.
`bin/fm-spawn.sh` refuses `--secondmate` on muse, and muse has no supervision protocol under `docs/supervision-protocols/`, so a firstmate primary detected as muse falls back to the `unknown` protocol.

| Fact | Value |
|---|---|
| Binary | Executable `muse` from `PATH`, resolved to an absolute path; spawning refuses if it is absent. The installed launcher `~/.local/bin/muse` `exec`s `~/.local/bin/muse-bin-<version>`, so the LIVE process name carries the version and changes on every auto-update. |
| Launch | Positional prompt, the Grok/Pi shape, so the brief rides the launch command. |
| Models | `--model <model>`; the only provider is `meta`. |
| Busy state | Its own durable session event log, folded on demand by `bin/fm-busy-lib.sh`. There is no hook or plugin writer, so nothing is armed and no busy record is ever seeded. |
| Exit command | `/exit` (the popup shows `/exit  Quit when idle`); one Enter submits it, and the pane prints `To continue this session, run muse resume <session-uuid>`. |
| Interrupt | Single Escape, which closes the run with `terminal: cancelled` AND restores the interrupted prompt into the composer as real bright text, so `fm-control` follows Escape with `C-u` to clear it; `fm-send`'s legacy key path reads the same composer-clear table. |
| Skill invocation | `/<skill>`, the claude/grok form. |
| Autonomy | `--yolo`, which disables approval, disables the sandbox, and trusts the workspace for the run. |
| Trust dialog | `Do you trust this workspace?` with `1 Trust and continue` preselected, accepted by Enter. `--yolo` suppresses it entirely, which is what firstmate relies on because every task gets a fresh worktree path. |
| Environment marker | None. Detection is process ancestry on the anchored prefix `muse-bin-*`. The launch clears foreign primary markers before Muse starts so their higher detection precedence cannot override that ancestry. `MUSE_CURRENT_SESSION_LOG` is a session-log PATH rather than an identity, and its export to tool subprocesses is unverified. |
| Composer | Bordered box whose prompt glyph is `⟩` (U+27E9) in truecolor `38;2;90;160;255`, luminance ~149.9 - the narrowest margin over the 128 ghost threshold in the fleet. Typed text is `38;2;204;211;219` (~209.8). No idle placeholder or ghost text was observed. |
| Effort | `--reasoning-effort`, default `high`; see the launch-profile table above for the mapping. |
| Resume | `muse resume --last` or `muse resume <session-uuid>`; bare `muse resume` opens a picker. |

### Credentials are a spawn preflight, not a screen check

muse reads `META_API_KEY` (which always wins) or a stored credential at `${XDG_CONFIG_HOME:-$HOME/.config}/muse/auth.json`, written by `muse login` (an OIDC device-code flow) or `muse auth set --api-key-stdin`.
`bin/fm-spawn.sh` accepts `META_API_KEY` only when it can prove the backend worker already has it, because a command-scoped caller variable does not cross a long-lived backend daemon and the secret must never enter launch argv.
The supported fleet path is the stored credential, and `fm-spawn` resolves the non-secret `XDG_CONFIG_HOME` and `XDG_DATA_HOME` roots to absolute paths before preflight and forwarding to keep authentication and session-log binding aligned with the worker.
`bin/fm-spawn.sh` refuses the launch when neither worker-reachable path is present, because an unauthenticated pane does NOT exit: it sits on `Sign in at this page: https://auth.meta.com/oauth/device/?code=XXXX-XXXX` / `Waiting for approval…` indefinitely, which supervision would read as a wedged worker rather than a missing credential.
Escalate that refusal to the captain as a needed credential.

### Foreign personal context is a real privacy boundary

muse loads the OPERATOR's foreign personal rules from `~/.claude` into every run and ships them to Meta-hosted inference, printing a first-launch notice that names the included Claude Code personal rules and `/settings` control.
An isolated `XDG_CONFIG_HOME` does NOT prevent this, and the notice is shown only once per config (`tui.foreign_context_notice_shown` in `settings.json`), so a silent later launch is still loading them.
`--no-foreign-personal-context` is `muse exec` ONLY: the interactive TUI rejects it with `unexpected argument`.
The control that reaches a pane worker is `MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on`, which `fm-spawn` sets on every muse launch.
It was verified to drop the foreign `rules_file` context block while KEEPING a project's own `AGENTS.md` rules, which the crewmate contract depends on.

### Session event log and the busy fold

Sessions persist to `${XDG_DATA_HOME:-$HOME/.local/share}/muse/sessions/YYYY/MM/DD/<session-uuid>/session.jsonl`, and `fm-spawn` writes `state/<id>.muse-session` pinning that root, the task worktree, its binding incarnation, and every pre-existing matching main log so the classifier binds a pane to its one new log.
After unique resolution, the classifier persists the exact main log in `state/<id>.muse-session-current`, folds that path directly while the bounded current-day main-session namespace is unchanged, and requires unique resolution again when that namespace changes, the path disappears, or a new spawn binding supersedes the incarnation.
Each submitted turn is bracketed by `{"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"started"` and a matching `"event":{"kind":"terminal"`, whose `terminal` value was observed as `completed` and `cancelled`.
Because the interrupt path produces a real terminal, this source covers interruption, which Claude's `Stop` hook does not.
Never use `--no-session-log` for a crewmate: it disables the only busy source muse has.

Two traps the fold already handles, which any change here must preserve.
muse also emits nested `"record":{"kind":"terminal"}` cleanup-effect payloads that are NOT run terminals, so the match is anchored on the full structural prefix rather than a `"kind":"terminal"` search.
muse's own native sub-agents write independent run lifecycles one directory deeper under `subagent/<child-session-id>/session.jsonl`, so the resolver is depth-bounded and folds only the main log.

The recorded sessions root is the resolved `XDG_DATA_HOME` that `fm-spawn` also forwards to the worker launch, so the binding and pane remain aligned across a long-lived backend daemon.

Both halves of the fold are trusted with no opt-in: an open run reads `busy`, a settled log reads `idle`, and only a resolution failure - no binding, no matching log, an unreadable or run-free log - reads `unknown`.
[`docs/verification/muse.md`](../../../docs/verification/muse.md) owns the credentialed evidence for trusting idle and the post-upgrade refresh procedure.

### Native sub-agents and worktrees

muse fans out to its own sub-agents, but worktree isolation is per-child and opt-in: `--subagent-worktree-isolation` is a compatibility flag whose capability "defaults on" while "omission stays shared", and no nested git worktree appeared in any verified lab run.
Firstmate deliberately does NOT exclude any muse path from `fm-teardown.sh`'s uncommitted-work check.
Firstmate writes `.claude/settings.local.json` itself, which is why that path is excluded for claude; it does not write muse's, so a nested muse worktree or leftover scratch is the agent's own work product and MUST be able to refuse teardown.
A teardown refusal naming muse scratch is therefore correct behavior: inspect it rather than forcing past it.

### Maturity caveats

muse is a day-0 `0.1.0` beta whose launcher polls a release channel hourly and can replace the running binary underneath the fleet, changing the process name with it.
The captain accepted that risk, so firstmate does NOT set `MUSE_NO_AUTO_UPDATE=1`; a fleet that later wants stability can set it in the launch environment without any adapter change.
Its plugin/hook engine reports `plugins are not available in this build` unless `MUSE_EXPERIMENTAL_PLUGINS=on`, which is why the busy source reads the session log instead of installing a hook.
