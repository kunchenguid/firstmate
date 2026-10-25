# wait-timers

The waiting-state timers — owner-alert and escalation timers for lanes that
declared a wait — moved **verbatim** out of the supervising fork into this
add-on repository. Nothing watches from here yet: the live watcher keeps
sourcing the fork's `bin/fm-wait-timers-lib.sh`, and the fork-side hook that
will source this directory instead lands in a later PR. Until that swap this
directory is dormant, and every moved byte below is identical to the fork copy
the live watcher runs today.

Step A of the fork exit: the library runs from this directory. Its sibling
libraries (`fm-parent-channel-lib.sh`, `fm-timeout-lib.sh`) are read from the
fork's `bin/` (`$SCRIPT_DIR`, else `$FM_PUSH_TRANSITION_LIB_DIR`, else
`$FM_HOME/bin`). The library body is otherwise identical to the fork copy.

## Step-B hook lines (fork)

- `bin/fm-watch.sh` and `bin/fm-push-transition-lib.sh`: replace the sourcing of
  the fork's `fm-wait-timers-lib.sh` with
  `[ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/wait-timers/bin/fm-wait-timers-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/wait-timers/bin/fm-wait-timers-lib.sh"`.
- Tick: `if declare -F fm_wait_timers_tick >/dev/null; then fm_wait_timers_tick || { echo "watcher: waiting-state timer check failed" >&2; exit 1; }; fi`.
- Push: `if [ -n "$task" ] && declare -F fm_wait_timer_push_delivered >/dev/null; then fm_wait_timer_push_delivered "$task" "$window" || exit 1; fi`.

`tests/wait-timers-hook-e2e.sh` (set `FM_TEST_FORK` to a Firstmate checkout)
uses the fork's post-step-B hook lines unchanged, copies this add-on's moved
`tests/fm-wait-timers.test.sh` journey into a private fork copy, and runs it with
this library installed; it also checks that the optional hooks are no-ops when
the add-on is absent.

## Layout

- `bin/fm-wait-timers-lib.sh` — the timer library the watcher sources once per
  poll: one durable episode per waiting lane under `state/.waiting-timers/`,
  an owner recheck once the alert threshold matures, then escalation when the
  owner has not cleared the wait. A blocked or needs-decision wake names its
  decision as `key=<key>` after the verb; paused waits carry none.
- `tests/fm-wait-timers.test.sh` — the watcher/drain journey that proves the
  timers (owner alert, escalation, deduplication, resolution, re-arm).
- `tests/fm-wait-timers-tmux-e2e.test.sh` — the live-terminal end-to-end
  journey; moved verbatim, run only against a real terminal session.

## Frozen contract (identical to the fork)

- Entry: `fm_wait_timers_tick` (no arguments; reads `FM_HOME` and `STATE`).
  Called once per watcher poll.
- `fm_wait_timer_push_delivered <task> <window>` — records that an immediate
  native push already told the owner about this blocked lane, so the poll
  timer skips its duplicate owner wake. Called from the push-transition path.
- `fm_wait_timer_save <record> <signature> <since> <owner> <parent> <key>
  <misses>`, `fm_wait_timer_report <status-line>`,
  `fm_wait_timer_owner_delivered` — episode persistence, parent reporting,
  and the post-wake hook the owner alert installs.
- Environment: `FM_WAIT_ALERT_SECS` (default 300) for the owner recheck,
  `FM_WAIT_ESCALATE_SECS` (default 900) for escalation; a declared pause
  rechecks at the pause cadence instead, never the owner-alert threshold.
- Episode record: one tab-separated line per lane at
  `state/.waiting-timers/<task>` holding signature, first-observed time,
  owner-delivery time, parent-report flag, report key, and miss count. The
  report key is the wait's identity,
  `waiting-timer-<home>-<task>-g<generation>-<source key>`: home is a short
  hash of the Firstmate home, generation is the arming second, and the source
  is the open decision key (or the pause key, `herdr-blocked`, `unkeyed`).
  Owner and escalation lines print `id=<key> source=[<declaration>]`, so the
  exact unresolved source is named; a resolution closes only the wait it
  names. The `waiting-timer-` prefix is unchanged for the fork's reserved-key fold.
- Parent lines: `blocked [key=...]: waiting-timer-overdue: ...` on
  escalation, `resolved [key=...]: waiting-timer-cleared: ...` when the wait
  ends. A top-level wait with no parent escalates as a wake to the top level
  itself, never as a parent report.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`0689b4b9d9ab3594f846cfe07c400edfa58244bf`; the sha256 manifest matched
across fork source and this directory. Treat any future diff against the fork
file as a contract change, not a refactor.

| moved file | fork source | sha256 |
|---|---|---|
| `wait-timers/bin/fm-wait-timers-lib.sh` | `bin/fm-wait-timers-lib.sh` | `5e4b399de21bdf47795dc9b0d52c12716be9b62bdb3422ad4d1f36878f0e0fd7` |
| `wait-timers/tests/fm-wait-timers.test.sh` | `tests/fm-wait-timers.test.sh` | `393b910d2bcafa41fa7b94a7f141e5c3652ab914b88b2d859545043a3938f08f` |
| `wait-timers/tests/fm-wait-timers-tmux-e2e.test.sh` | `tests/fm-wait-timers-tmux-e2e.test.sh` | `fc0f38458b02aa25efcf939bbf763bcdb01f57ce09fca888a6a68fc34c735fbf` |

## Side-by-side proof (re-run before the hook swaps the sourced path)

The acceptance proof runs the fork test and the moved test each against its
own library copy and diffs the verdicts. The library sources its two sibling
libraries from its own directory, so the moved side runs inside a throwaway
harness outside the moved files: a scratch copy of the fork tree at the
commit above whose `bin/` already holds those siblings, with only
`bin/fm-wait-timers-lib.sh` and `tests/fm-wait-timers.test.sh` replaced by
the moved bytes (verified identical first). Do not run the live-terminal
end-to-end test: it drives a real terminal session; it moves verbatim only.

1. Unpack the fork tree at the commit above into two scratch roots.
2. In the second root only, overwrite the timer library and its test with
   the moved files; `diff` both against the first root (must be empty) and
   re-check the sha256 table above.
3. Run `tests/fm-wait-timers.test.sh` in each root; both must exit 0 and
   print the same `ok` verdict lines (the harness's cycle-budget warnings
   carry process ids, so normalize digits before diffing).
4. Run the repo CI gate (the lint plus syntax check over every add-on script)
   on the PR head.

Timing note: the journey gives each watcher cycle a small single-digit
budget, so run the proof on a quiet host — under heavy load a cycle can be
terminated before it records its delivery and the run fails on timing, not
on behavior.
