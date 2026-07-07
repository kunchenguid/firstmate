---
name: bootstrap-diagnostics
description: >-
  Agent-only reference for handling the session-start digest's bootstrap diagnostic lines.
  Use when the bootstrap section of bin/fm-session-start.sh's digest (or a standalone bin/fm-bootstrap.sh run) prints any problem or capability line - MISSING, NEEDS_GH_AUTH, TANGLE, CREW_HARNESS_OVERRIDE, CREW_DISPATCH, FLEET_SYNC, SECONDMATE_SYNC, TASKS_AXI, NUDGE_SECONDMATES, or FMX.
  Silence in the bootstrap section means all good and needs no handling.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Bootstrap is detect, then consent, then install; never install anything the captain has not approved in this session (AGENTS.md section 3).
Handle each printed line as follows.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `tasks-axi`, this appears only when `config/backlog-backend` is absent or set to `tasks-axi`; hand-edit fallback continues until the captain approves installation, and work is never blocked on it.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; AGENTS.md section 8's worktree-tangle guard explains what this protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
  When the session does not hold the lock, the check prints read-only advisory wording without a checkout repair command; do not repair from a read-only session.
- `CREW_HARNESS_OVERRIDE: <name>` - record and use the override silently; surface a harness fact only if it actually blocks work or the captain asks.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost validation; continue with the normal fallback chain, resolve and pass the chosen fallback harness explicitly while the file remains present, fix the JSON, unverified harness name, or invalid harness/effort pair when convenient, and do not select a bad profile.
- `CREW_DISPATCH: active config/crew-dispatch.json` - bootstrap validated the file and printed its active rules as `rule: <when> -> <harness[/model[/effort]]>` lines, plus `default:` when present.
  Keep this block top-of-mind during intake: every crewmate or scout dispatch must consult the rules before spawning (AGENTS.md section 4).
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - the local-HEAD secondmate sync left a live secondmate home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing the primary target commit, or otherwise not fast-forwardable; bootstrap continued, but inspect the reason because the secondmate may be stale after a primary update.
- `TASKS_AXI: available` - a default-backend capability fact, not a problem; record it silently and use AGENTS.md section 10 for backlog mutations.
  It prints only when `config/backlog-backend` is absent or set to `tasks-axi` and the compatibility probe accepts `tasks-axi --version` as 0.1.1 or newer.
- `NUDGE_SECONDMATES: <window-targets...>` - the secondmate sweep fast-forwarded one or more RUNNING secondmate homes to firstmate's current version and their instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) actually changed; for each listed window, send a one-line re-read nudge with `bin/fm-send.sh <window-target> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'` so that secondmate picks up its new instructions.
  This mirrors `/updatefirstmate`'s `nudge-secondmates:` report: it is a gentle steer, never an interruption, and the fast-forward already landed safely.
  A secondmate that was skipped, already current, or whose advance changed no instructions is not listed and must not be disturbed.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts; follow AGENTS.md section 14 for the watcher cadence restart only when a running watcher needs the transition applied immediately.

Bootstrap's fleet refresh is bounded by `FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT` seconds, default 20; a timeout is reported as a `FLEET_SYNC` skip and does not block startup.
