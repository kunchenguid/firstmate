# Keeping this fork current with upstream firstmate

`feat/dsh-primary-adapter` adds DeepSeek Harness as a firstmate primary. Upstream is a fast-moving
project, so this branch is deliberately shaped to be mergeable rather than merely working.

## What this branch is

| | |
| --- | --- |
| Upstream base | `7111081c` — advanced from `b430bf50` by the first sync below |
| Added files | 13 — self-contained; an upstream merge cannot conflict on them |
| Modified upstream files | 15 — this is the entire conflict surface |

## Why it is shaped this way

**Harness identity has one owner.** Every DSH launcher pattern lives in `bin/fm-dsh-lib.sh`, following
firstmate's own `bin/fm-cursor-lib.sh` and `bin/fm-gemini-lib.sh` convention: a per-harness library
sourced by its consumers, carrying the measurement evidence in its header. Before that extraction the
same three launcher shapes existed in three places across two files, in two different syntaxes
(a shell `case` glob and a POSIX ERE). Now `bin/fm-harness.sh` and `bin/fm-session-lock-lib.sh` each
gained a source line and a call site, and the regex registry composes itself from
`fm_dsh_args_ere`.

**Every upstream edit is additive.** No upstream logic was reordered, renamed, or rewritten. Each
modified file gained a case arm, a new mode, a new function, or a call site. When one of them conflicts,
the resolution is almost always "keep both".

## Update procedure

```sh
git remote add upstream https://github.com/kunchenguid/firstmate.git   # once
git fetch upstream
git log --oneline b430bf50..upstream/main      # what landed upstream
git rebase upstream/main                       # or `git merge`, your preference
```

Then re-verify with the gates below before trusting the result. A rebase that applies cleanly is not
evidence that the adapter still works: none of these upstream files is covered by an upstream test
that knows what `dsh` means.

## Conflict surface

| File | What this branch added | If it conflicts |
| --- | --- | --- |
| `bin/fm-harness.sh` | Sources `fm-dsh-lib.sh`; a `FM_DSH_HARNESS` marker arm; an interpreter-arm delegate to `fm_dsh_args_are_dsh` | Keep both. Upstream edits to `harness_marker`/`harness_process_verdict` are the most likely conflict, and the DSH arm must stay **before** the `CLAUDECODE` arm to keep its precedence |
| `bin/fm-session-lock-lib.sh` | Sources `fm-dsh-lib.sh`; `FM_HARNESS_RE` composed from `fm_dsh_args_ere`; `dsh` deliberately absent from `FM_HARNESS_NAMES` | Keep both. If upstream restructures the registry, re-point the regex at `fm_dsh_args_ere` rather than re-inlining the pattern |
| `bin/fm-turnend-guard.sh` | The `--dsh` flag, `DSH_BUDGET_FILE`/`DSH_BUDGET_LOCK` paths, the bounded-block block, `dsh_conclude`, and the alarm latch in `dsh_budget_reset` | Keep both. The DSH block must stay **before** the `--claude` cooperative path and after `block_stop`'s definition |
| `bin/fm-wake-lib.sh` | `job` in the model table and the override case; `fm_job_midturn_healthy`; the `job` branch in `fm_watcher_supervision_verdict` | Keep both. The `job` branch must stay **before** the `fm_watcher_healthy` fallthrough |
| `bin/fm-spawn.sh` | `refuse_dsh_crewmate` beside `launch_template`, called in both harness-resolution arms | Keep both. If upstream adds a third resolution arm, it needs the same call |
| `bin/fm-subagent-pretool-check.sh` | `ralph` in `DELEGATION_STEMS`; `listagents`/`interruptagent` in `OBSERVE_ONLY_TOOLS` | Keep both. Re-derive the lists against DSH's tool catalog if DSH renames tools |
| `bin/fm-supervision-instructions.sh` | `dsh` in the snippet-routing case and a `dsh)` repair arm | Keep both |
| `AGENTS.md` | §2 entries for the three DSH home-level state files | Keep both |
| `docs/configuration.md` | A Harness support paragraph | Keep both |
| `docs/sessionstart-nudge.md` | `dsh` in the Run tier and a note on its transport | Keep both |
| `docs/verification/supervision.md` | The DSH verification records | Keep both; append rather than merge if upstream restructured the file |
| `.agents/skills/harness-adapters/SKILL.md` | The routing JSON entry and a primary-only safety line | Keep both |
| `tests/fm-turnend-guard.test.sh`, `tests/fm-session-lock-ancestry.test.sh`, `tests/fm-claude-stop-autoarm.test.sh` | `cp "$ROOT/bin/fm-dsh-lib.sh"` added to each fixture's script list | Keep both. A fixture that copies a script must copy what that script SOURCES; `fm-session-lock-lib.sh` now sources `fm-dsh-lib.sh`, and a fixture missing it fails with "No such file or directory" at source time |

## Sync log

**2026-09-16 — first sync, performed to prove the path.** Upstream `main` had advanced by one commit
(`7111081c`, "report verified PR state for passed runs"), touching `fm-crew-state.sh`,
`fm-inactive-reconcile.sh`, `fm-pr-lib.sh` and `fm-crew-state.test.sh` — none of them on this
branch's conflict surface. `git rebase upstream-main` replayed all 24 commits with **zero conflicts**.

The rebase was clean and the adapter was still broken, which is the lesson worth keeping: because the
lock library gained a source dependency, three upstream test **fixtures** that copy scripts by explicit
list needed the new file. `fm-turnend-guard.test.sh` failed with
`fm-session-lock-lib.sh: line 19: .../bin/fm-dsh-lib.sh: No such file or directory`. That failure is
invisible to the adapter's own suites and appears only when the upstream suites run, so a clean rebase
must always be followed by the gates below — not by the adapter's tests alone.

## Verification gates after an update

```sh
bash tests/fm-dsh-harness.test.sh                 # portable: 30 cases, no network, no model
FM_DSH_LIVE_E2E=1 bash tests/fm-dsh-live-e2e.test.sh   # live: 4 contracts against a real DSH
bin/fm-dsh-preflight.sh --profile <name>          # the three silent-misconfiguration assertions
```

Plus the upstream suites this branch touches, so an upstream change that invalidates an assumption is
caught rather than absorbed:

```sh
for t in fm-turnend-guard fm-wake-drain-outcome-backstop fm-watcher-lock fm-guard-stale-banner \
         fm-session-lock-ancestry fm-harness-precedence fm-arm-pretool-check fm-cd-pretool-check \
         fm-subagent-pretool-check fm-spawn-dispatch-profile fm-supervision-instructions; do
  bash "tests/$t.test.sh" || echo "FAILED: $t"
done
```

`tests/fm-wake-queue.test.sh` is flaky independently of this work (reverting `bin/fm-wake-lib.sh`
entirely still fails most runs); do not read its failures as a regression from this branch.

## Upstream changes most likely to break the adapter

1. **The hooks bridge's supported events or payload fields.** The whole primary integration rests on
   `UserPromptSubmit` delivering `additionalContext` before the first request, `PreToolUse` matching on
   the harness tool name, and `Stop` forcing a bounded continuation. The live guard is the check.
2. **`fm-harness.sh`'s marker/ancestry arbitration.** DSH publishes no marker, so identity rests on the
   `FM_DSH_HARNESS` override winning over an inherited `CLAUDECODE` because a genuine dsh process is in
   the ancestry.
3. **`fm_watcher_supervision_verdict`'s model set.** The `job` model is what stops the drain crying
   `WATCHER DOWN` on every wake.
4. **`fm-spawn.sh`'s harness resolution.** A third resolution arm without the `refuse_dsh_crewmate`
   call would let a DSH crewmate spawn into work nothing could steer or stop.
5. **DSH renaming its own tools.** `bin/fm-subagent-pretool-check.sh`'s stems are matched against real
   DSH tool names, and a rename can silently disarm the delegation guard.
