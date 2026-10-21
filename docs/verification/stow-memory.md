# Startup-memory stow verification

Audience: maintainer verification.

This record supports the active guarantee that Pi can discover and JIT-load a user-owned local skill excluded through the clone's `.git/info/exclude` when Firstmate supplies the `.agents/skills` root through Pi's public skill interface.
The internal [`stow` skill](../../.agents/stow.md) owns tiering, curation, archival, offload, and completion-receipt behavior.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing startup-memory setting and estimate.

## Git-excluded local skill discovery and loading

The internal skill's offload destination relies on Pi discovering and JIT-loading a skill directory whose path is listed in the clone's local `.git/info/exclude` beneath the explicitly supplied `.agents/skills` root.
The current Pi guard creates a skill beneath `.agents/skills/`, excludes that directory through the disposable repository's local `.git/info/exclude`, and invokes Pi through its public `--skill` interface.
The required sentinel exists only in the skill body, so the final response proves body loading rather than only Git ignore status or catalog-description discovery.
Codex discovery remains unverified.

## 2026-09-25 local-skill verification

The live guard passed with Pi 0.87.1.

```text
$ FM_STOW_LOCAL_SKILL_LIVE_E2E=1 tests/fm-stow-local-skill-live-e2e.test.sh
ok - Pi discovers and JIT-loads a repository-local git-excluded skill body
```

## 2026-09-24 periodic coordinator verification

The focused lifecycle suite observed lock, role, session-tree, compare-and-swap, bounded delivery, fixed-cutoff promotion, prepared/readback recovery, disable, budget, no-op, and corrupt-state outcomes through the public command and durable files.
Strict no-emit checks passed against the supported Pi 0.84.4 baseline and installed Pi 0.87.1, while the real TUI guard loaded compatible `pi-openai-codex-compat` 0.0.16 in a named non-default Herdr lab and observed one stable custom follow-up.

```text
$ tests/fm-periodic-stow.test.sh
ok - budget, proven no-op, unchanged memory, full-pass clock, and corrupt-state guards are observable
ok - Pi coordinator stays default-off, waits for tools, queues, and editor input, then redelivers one run at most three times
$ FM_PI_PACKAGE_DIR=<isolated-pi-0.84.4> tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.87.1
$ # Historical rich-lifecycle live matrix removed; retain the portable periodic-stow and Pi type checks above.
```

The live guard provisions, addresses, stops, and deletes only through `bin/fm-herdr-lab.sh`; that helper verifies the default Herdr fleet before and after the run.
Installation evidence is not enablement: the repository contains no `config/periodic-stow.json`, and choosing an enabled home and frequency remains a later operator action.

## 2026-10-20 idle-reminder verification

The focused coordinator suite uses controlled clocks and canonical task records to prove the 1800-second due boundary, structural busy deferral, verified main-session lock and role binding, one reminder after prolonged busy time, repeat eligibility for an unchanged decision, completed and archived exclusion, empty-inventory silence, and successful-settlement pacing across extension reload.
It also proves that snapshot failures release existing maintenance and continuation scheduling, failed or aborted model turns retry only at a later boundary, tool-use preambles are not delivery evidence, and a cold restart retires an orphaned request before an intervening ordinary reply and reload without creating a false receipt.
The combined periodic-coordinator and turn-end-guard fixture holds the guard's asynchronous settlement claim open and observes delivery order `guard, reminder`, proving that the optional reminder cannot enter Pi's follow-up queue ahead of an existing recovery owner.
An offline deterministic provider then drives the extension through the installed Pi 1.3.0 `DefaultResourceLoader` and `AgentSession`: a real settled TUI turn reaches one hidden reminder follow-up and persisted delivery receipt, and reopening that session does not duplicate it.
The same suite reruns the pre-existing manual, pre-compaction, maintenance, fixed-cutoff, recovery, receipt, and escalation cases so the lightweight reminder cannot replace or consume maintenance custody.

```text
$ tests/fm-periodic-stow.test.sh
ok - Pi coordinator bounds heartbeat delivery and hands exhaustion to one executable main turn
ok - idle reminders defer at busy boundaries, collapse missed intervals, repeat unresolved decisions, and persist successful delivery cadence
ok - idle reminder stays quiet for an empty canonical inventory
ok - old requested maintenance keeps its custody without suppressing a due idle reminder
ok - installed Pi delivers one idle reminder and restores its successful cadence without network access
ok - idle reminder waits for the existing turn-end owner before entering the follow-up queue
ok - heartbeat retains failed duties and completes only with three unchanged bound readbacks
ok - heartbeat persists paced recovery across generations without resetting attempts or fabricating progress
```
