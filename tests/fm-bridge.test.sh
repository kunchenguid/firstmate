#!/usr/bin/env bash
# Behavior tests for fm-bridge.sh, the read-only triage-ordered fleet dashboard.
# Drives the scriptable --once path against synthetic state fixtures and asserts
# each task lands in the correct triage band. Classification is driven by real
# snapshot signals (fm-fleet-snapshot.v1 + fm-classify-lib.sh), never hard-coded.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fake tmux that reports every target as an existing pane (the pane-presence
# check crew-state's fallback path requires), plus a legacy busy footer for
# targets matching FAKE_BUSY_RE. A fake no-mistakes with no runs forces
# crew-state onto the pane-presence / semantic busy-state / status-log path.
# Under the semantic busy-state contract (bin/fm-busy-lib.sh) rendered pane text
# is no longer a state source, so a "working" crew proves it through its own
# armed busy-state record (see record_claude_busy), not the capture-pane footer.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""; prev=""
for arg in "$@"; do
  [ "$prev" = "-t" ] && target=$arg
  prev=$arg
done
case "${1:-}" in
  display-message)
    # A target marked DEAD has no pane: fail like a gone tmux window so crew-state
    # reads "unknown" (backend target gone), exercising the catch-all band.
    case "$target" in *DEAD*) exit 1 ;; esac
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    if [ -n "${FAKE_BUSY_RE:-}" ] && printf '%s' "$target" | grep -qE "$FAKE_BUSY_RE"; then
      printf 'validating change\nesc to interrupt\n'
    else
      printf 'all quiet\n> \n'
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# Print the entry lines of one triage band (exclusive of the header, up to the
# next band header). Band headers render flush-left; entries are indented.
band() {  # <output> <header>
  awk -v h="$2" '
    $0 == h { grab = 1; next }
    grab && ($0 == "NEEDS YOU" || $0 == "RUNNING" || $0 == "WAITING / HELD" || $0 == "LANDED") { exit }
    grab { print }
  ' <<<"$1"
}

run_bridge() {  # <home> <fakebin> [busy-re]
  NO_COLOR=1 FAKE_BUSY_RE="${3:-}" PATH="$2:$PATH" FM_HOME="$1" "$BRIDGE" --once
}

# Record a semantic busy turn for a claude crew the way a real adapter would:
# arm the task's busy-state contract, then apply one busy lifecycle event. This
# record (bin/fm-busy-lib.sh), not rendered pane text, is what the snapshot's
# current-state read consults to classify a crew as working / RUNNING.
record_claude_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

# Record a settled (idle) turn for a claude crew the way a real Stop hook would.
# An idle busy-state verdict is narrower than turn state, so crew-state falls
# through to the status log for the crew's current state - which is how a crew
# parked at a gate, done, failed, or paused reports itself, and it keeps the
# snapshot's keyed open-decision fold from being cleared as "resumed past gate".
record_claude_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# --- Acceptance scenario ----------------------------------------------------
# A running crew, a held backlog item, landed PRs, and nothing needing the captain.
test_acceptance_bands() {
  local home fakebin out run_band hold_band land_band needs_band
  home=$(make_home acceptance)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/atlassian-axi"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] atlas-axi-scout-x7 - investigate atlassian axi (repo: atlassian-axi) (kind: ship) (since 2026-07-07)
- [ ] modular-sofas-6785-4w - fix sofa module (repo: modular-sofas) (kind: ship) (since 2026-07-07) (hold: waiting on vendor spec) (hold-kind: vendor)

## Queued
- [ ] follow-up-9z - later cleanup blocked-by: atlas-axi-scout-x7 - waits on atlas landing (repo: atlassian-axi) (kind: ship)

## Done
- [x] gitflow-bugfix-fix-3k - correct PR 1314 flow - https://github.com/dept/beno-bolia-website/pull/1314 (merged 2026-07-13)
- [x] gitflow-test-rule-7q - document test-branch flow - https://github.com/dept/beno-bolia-website/pull/1314 (merged 2026-07-13)
EOF

  fm_write_meta "$home/state/atlas-axi-scout-x7.meta" \
    "window=firstmate:fm-atlas-axi-scout-x7" \
    "worktree=$home/projects/atlassian-axi" \
    "project=$home/projects/atlassian-axi" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/emilchristensen/atlassian-axi/pull/1"
  printf 'working: reproducing the issue\n' > "$home/state/atlas-axi-scout-x7.status"
  # A busy crew proves it through its own semantic busy-state record, not the
  # rendered pane, so this is what makes it land under RUNNING.
  record_claude_busy "$home/state" atlas-axi-scout-x7

  out=$(run_bridge "$home" "$fakebin")

  run_band=$(band "$out" "RUNNING")
  hold_band=$(band "$out" "WAITING / HELD")
  land_band=$(band "$out" "LANDED")
  needs_band=$(band "$out" "NEEDS YOU")

  assert_contains "$run_band" "atlas-axi-scout-x7" "the busy crew must be under RUNNING"
  assert_contains "$run_band" "[atlassian-axi]" "RUNNING must show the project"
  # Elapsed must be a real duration (e.g. 0s, 4m, 1h3m), never a calendar-day word.
  printf '%s\n' "$run_band" | grep -qE '[0-9]+[smhd]' \
    || fail "RUNNING must show a real elapsed duration: $run_band"
  assert_not_contains "$run_band" "today" "RUNNING elapsed must not be a calendar-day word"
  assert_contains "$hold_band" "modular-sofas-6785-4w" "the held item must be under WAITING / HELD"
  assert_contains "$hold_band" "held (vendor)" "WAITING must show the hold-kind"
  assert_contains "$hold_band" "waiting on vendor spec" "WAITING must show the hold reason"
  assert_contains "$hold_band" "follow-up-9z" "a blocked-by queued item belongs in WAITING / HELD"
  assert_contains "$hold_band" "waits on atlas landing" "WAITING must show the blocked-by reason"
  assert_contains "$land_band" "PR #1314" "the merged gitflow PRs must be under LANDED"
  assert_contains "$needs_band" "nothing waiting on you" "NEEDS YOU must be empty in this scenario"

  # Placement must be exclusive: no cross-band leakage. atlas may legitimately
  # appear inside WAITING as another item's blocked-by reference, so assert it is
  # not present as its OWN indented WAITING entry (a line whose subject is atlas).
  assert_not_contains "$run_band" "modular-sofas-6785-4w" "a held item must not appear under RUNNING"
  if printf '%s\n' "$hold_band" | grep -qE '^  atlas-axi-scout-x7 '; then
    fail "a running crew must not appear as its own WAITING / HELD entry: $hold_band"
  fi
  assert_not_contains "$needs_band" "atlas-axi-scout-x7" "a working crew is not captain-actionable"

  pass "acceptance scenario places running / held / landed correctly with NEEDS YOU empty"
}

# --- NEEDS YOU classification ----------------------------------------------
# Prove the three captain-actionable signals surface, a resolved decision does
# not (fm-classify-lib.sh keyed fold), and a live crew stays out of NEEDS YOU.
test_needs_you_signals() {
  local home fakebin out needs_band run_band
  home=$(make_home needsyou)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/app"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] decide-api-4a - pick api shape (repo: app) (kind: ship) (since 2026-07-10)
- [ ] stuck-build-5b - unblock the build (repo: app) (kind: ship) (since 2026-07-10)
- [ ] merge-ready-6c - land the feature (repo: app) (kind: ship) (since 2026-07-10)
- [ ] resolved-7d - already decided (repo: app) (kind: ship) (since 2026-07-10)
- [ ] run-live-8e - active work (repo: app) (kind: ship) (since 2026-07-10)

## Done
EOF

  for id in decide-api-4a stuck-build-5b merge-ready-6c resolved-7d run-live-8e; do
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/app" \
      "project=$home/projects/app" \
      "harness=claude" "kind=ship" "mode=ship" "yolo=off"
  done
  printf 'pr=https://github.com/emilchristensen/app/pull/12\n' >> "$home/state/merge-ready-6c.meta"

  printf 'needs-decision [key=api]: rest vs graphql\n' > "$home/state/decide-api-4a.status"
  printf 'blocked: waiting on infra creds\n' > "$home/state/stuck-build-5b.status"
  printf 'done: PR https://github.com/emilchristensen/app/pull/12 checks green\n' > "$home/state/merge-ready-6c.status"
  printf 'needs-decision [key=fmt]: tabs vs spaces\nresolved [key=fmt]: spaces\n' > "$home/state/resolved-7d.status"
  printf 'working: implementing\n' > "$home/state/run-live-8e.status"

  # A crew parked at a gate, blocked, done, or resolved settles its turn (idle),
  # so crew-state reads its current state from the status log and the snapshot's
  # keyed open-decision fold survives. A busy crew (run-live-8e) proves it works
  # through its semantic busy-state record, landing under RUNNING. A busy verdict
  # is what the snapshot would treat as "resumed past the gate", so it is used
  # only for the genuinely working crew here.
  for id in decide-api-4a stuck-build-5b merge-ready-6c resolved-7d; do
    record_claude_idle "$home/state" "$id"
  done
  record_claude_busy "$home/state" run-live-8e

  out=$(run_bridge "$home" "$fakebin")
  needs_band=$(band "$out" "NEEDS YOU")
  run_band=$(band "$out" "RUNNING")

  assert_contains "$needs_band" "decide-api-4a" "an open needs-decision must surface in NEEDS YOU"
  assert_contains "$needs_band" "decision needed" "NEEDS YOU must label the decision"
  assert_contains "$needs_band" "stuck-build-5b" "an open blocked status must surface in NEEDS YOU"
  assert_contains "$needs_band" "merge-ready-6c" "a checks-green PR awaiting merge must surface in NEEDS YOU"
  assert_contains "$needs_band" "ready to merge" "NEEDS YOU must label the merge-ready PR"
  assert_not_contains "$needs_band" "resolved-7d" "a resolved decision must not resurface in NEEDS YOU"
  assert_not_contains "$needs_band" "run-live-8e" "a working crew is not captain-actionable"
  assert_contains "$run_band" "run-live-8e" "the working crew belongs under RUNNING"

  pass "NEEDS YOU surfaces open decisions, blocks, and merge-ready PRs but not resolved or working crew"
}

# --- direct-PR "done: PR <url>" awaits checks, is not merge-ready ------------
# A direct-PR crew reports "done: PR <url>" the moment it opens the PR, before CI
# runs, so a bare done-with-PR status carries no checks-green marker. It must not
# be labeled merge-ready in NEEDS YOU (that would push a premature merge onto the
# captain), and it must still be visible under WAITING / HELD awaiting checks.
test_direct_pr_awaits_checks() {
  local home fakebin out needs_band hold_band
  home=$(make_home directpr)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/app"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] pr-open-3f - opened a PR, checks pending (repo: app) (kind: ship) (since 2026-07-10)

## Done
EOF

  fm_write_meta "$home/state/pr-open-3f.meta" \
    "window=firstmate:fm-pr-open-3f" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off"
  printf 'pr=https://github.com/emilchristensen/app/pull/42\n' >> "$home/state/pr-open-3f.meta"

  # A bare direct-PR done status with NO checks-green / ready-for-review wording.
  # The crew has settled its turn (idle), so crew-state reads the status log
  # verbatim and reports done.
  printf 'done: PR https://github.com/emilchristensen/app/pull/42\n' > "$home/state/pr-open-3f.status"
  record_claude_idle "$home/state" pr-open-3f

  out=$(run_bridge "$home" "$fakebin")
  needs_band=$(band "$out" "NEEDS YOU")
  hold_band=$(band "$out" "WAITING / HELD")

  assert_not_contains "$needs_band" "pr-open-3f" "a bare done-with-open-PR status must not surface as merge-ready in NEEDS YOU"
  assert_contains "$hold_band" "pr-open-3f" "a done-with-open-PR task must remain visible under WAITING / HELD"
  assert_contains "$hold_band" "awaiting checks/review" "WAITING must label the PR-open task as awaiting checks/review"

  pass "a bare direct-PR done status awaits checks under WAITING, never merge-ready in NEEDS YOU"
}

# --- done-with-no-PR captain-actionable states + failed crews ----------------
# A done scout with a report on disk, a done local-only ship with no PR, and a
# failed crew are all captain-actionable and must surface in NEEDS YOU, driven
# by real snapshot signals (kind, mode, scout_report_present, crew-state failed).
test_needs_you_done_no_pr_and_failed() {
  local home fakebin out needs_band run_band
  home=$(make_home donenopr)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/app"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] scout-done-1b - investigate the flake (repo: app) (kind: scout) (since 2026-07-10)
- [ ] local-done-2c - ship a local fix (repo: app) (kind: ship) (since 2026-07-10)
- [ ] crashed-3d - broke mid-run (repo: app) (kind: ship) (since 2026-07-10)
- [ ] scout-local-4e - scout on a local-only project (repo: app) (kind: scout) (since 2026-07-10)

## Done
EOF

  fm_write_meta "$home/state/scout-done-1b.meta" \
    "window=firstmate:fm-scout-done-1b" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=claude" "kind=scout" "mode=ship" "yolo=off"
  fm_write_meta "$home/state/local-done-2c.meta" \
    "window=firstmate:fm-local-done-2c" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  fm_write_meta "$home/state/crashed-3d.meta" \
    "window=firstmate:fm-crashed-3d" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=claude" "kind=ship" "mode=ship" "yolo=off"
  fm_write_meta "$home/state/scout-local-4e.meta" \
    "window=firstmate:fm-scout-local-4e" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=claude" "kind=scout" "mode=local-only" "yolo=off"

  mkdir -p "$home/data/scout-done-1b"
  printf '# findings\n' > "$home/data/scout-done-1b/report.md"

  printf 'done: report at data/scout-done-1b/report.md\n' > "$home/state/scout-done-1b.status"
  printf 'done: ready in branch fm/local-done-2c\n' > "$home/state/local-done-2c.status"
  printf 'failed: build exploded\n' > "$home/state/crashed-3d.status"
  printf 'done: findings summarized in chat\n' > "$home/state/scout-local-4e.status"

  # These crews have all finished their turn (done / failed), so each settles
  # its busy-state record to idle and crew-state reports the terminal state from
  # the status log, the signal these NEEDS YOU classifications key off.
  for id in scout-done-1b local-done-2c crashed-3d scout-local-4e; do
    record_claude_idle "$home/state" "$id"
  done

  out=$(run_bridge "$home" "$fakebin")
  needs_band=$(band "$out" "NEEDS YOU")
  run_band=$(band "$out" "RUNNING")

  assert_contains "$needs_band" "scout-done-1b" "a done scout with a report must surface in NEEDS YOU"
  assert_contains "$needs_band" "report ready - review findings" "NEEDS YOU must label the scout report"
  assert_contains "$needs_band" "report.md" "the scout row must show the report basename"
  assert_not_contains "$needs_band" "data/scout-done-1b" "the data/<id>/ prefix must be dropped from the report name"
  assert_contains "$needs_band" "local-done-2c" "a done local-only ship with no PR must surface in NEEDS YOU"
  assert_contains "$needs_band" "ready for your review (local branch)" "NEEDS YOU must label the local-only review"
  assert_contains "$needs_band" "crashed-3d" "a failed crew must surface in NEEDS YOU"
  assert_contains "$needs_band" "failed - needs attention" "NEEDS YOU must label the failed crew"
  assert_not_contains "$run_band" "crashed-3d" "a failed crew must not appear under RUNNING"
  assert_not_contains "$needs_band" "scout-local-4e" "a done local-only scout with no report must not render as local-ready"

  pass "NEEDS YOU surfaces done scouts, done local-only ships, and failed crews"
}

# --- held + paused renders one WAITING row -----------------------------------
# A task that is both backlog-held and status-paused must render only the hold
# row, never a second paused row for the same id.
test_held_paused_single_row() {
  local home fakebin out hold_band rows
  home=$(make_home heldpaused)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/app"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] hold-pause-1a - wait for vendor (repo: app) (kind: ship) (since 2026-07-10) (hold: vendor api down) (hold-kind: vendor)

## Done
EOF

  fm_write_meta "$home/state/hold-pause-1a.meta" \
    "window=firstmate:fm-hold-pause-1a" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=claude" "kind=ship" "mode=ship" "yolo=off"
  printf 'paused: vendor api down, recheck tomorrow\n' > "$home/state/hold-pause-1a.status"
  record_claude_idle "$home/state" hold-pause-1a

  out=$(run_bridge "$home" "$fakebin")
  hold_band=$(band "$out" "WAITING / HELD")

  assert_contains "$hold_band" "hold-pause-1a" "the held+paused task must appear under WAITING / HELD"
  assert_contains "$hold_band" "held (vendor)" "the surviving row must be the hold row"
  rows=$(printf '%s\n' "$hold_band" | grep -c 'hold-pause-1a')
  [ "$rows" = 1 ] || fail "a held+paused task must render exactly one WAITING row, got $rows: $hold_band"

  pass "a held+paused task renders a single WAITING / HELD row"
}

# --- Frame shape ------------------------------------------------------------
test_frame_shape_and_empty_fleet() {
  local home fakebin out
  home=$(make_home emptyfleet)
  fakebin=$(make_fakebin "$home")
  out=$(run_bridge "$home" "$fakebin")

  assert_contains "$out" "THE BRIDGE" "the header must render"
  assert_contains "$out" "needs-you 0" "the header must count needs-you"
  assert_contains "$out" "NEEDS YOU" "all four band labels must render"
  assert_contains "$out" "RUNNING" "all four band labels must render"
  assert_contains "$out" "WAITING / HELD" "all four band labels must render"
  assert_contains "$out" "LANDED" "all four band labels must render"
  assert_contains "$out" "[m]erge" "the footer hint must render"
  assert_contains "$out" "no live crew" "an empty fleet must degrade gracefully"

  pass "frame renders header, four bands, and footer on an empty fleet"
}

# --- LANDED column budgeting + report compaction ---------------------------
# At a narrow width the title must absorb all truncation while the trailing PR /
# date stays fully shown, and a report artifact renders as its bare basename.
test_landed_budget_and_report_compaction() {
  local home fakebin out land_band line
  home=$(make_home landed)
  fakebin=$(make_fakebin "$home")

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
- [x] shipped-9a - a deliberately very long landed title that must be clipped hard - https://github.com/emilchristensen/app/pull/1314 (merged 2026-07-13)
- [x] scouted-8b - another long scout report title that overflows the row easily - data/scouted-8b/report.md (reported 2026-07-13)
EOF
  mkdir -p "$home/data/scouted-8b"; printf '# r\n' > "$home/data/scouted-8b/report.md"

  out=$(COLUMNS=50 run_bridge "$home" "$fakebin")
  land_band=$(band "$out" "LANDED")

  assert_contains "$land_band" "PR #1314" "LANDED must show the full PR number"
  assert_contains "$land_band" "(2026-07-13)" "LANDED must show the full trailing date, never a hard cut"
  assert_contains "$land_band" "report.md" "a report artifact must render as its compact basename"
  assert_not_contains "$land_band" "data/scouted-8b" "the data/<id>/ prefix must be dropped"
  assert_contains "$land_band" "…" "the title column must truncate with a clean ellipsis"

  # Every landed entry that carries a date must carry the WHOLE date.
  while IFS= read -r line; do
    case "$line" in
      *"2026-07-1"*) assert_contains "$line" "(2026-07-13)" "a landed date must never be partially cut: $line" ;;
    esac
  done <<<"$land_band"

  pass "LANDED budgets columns so the trailing PR/date is intact and report paths compact"
}

# --- Catch-all: no live task vanishes ---------------------------------------
# A live task whose crew-state is neither actionable, running, paused, awaiting a
# PR, nor held must still appear (here: a dead-endpoint task reads "unknown") under
# WAITING / HELD via the catch-all, never in NEEDS YOU.
test_catchall_keeps_live_tasks_visible() {
  local home fakebin out hold_band needs_band
  home=$(make_home catchall)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/app"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] stuck-crew-2u - a crew with a gone pane (repo: app) (kind: ship) (since 2026-07-10)

## Done
EOF
  fm_write_meta "$home/state/stuck-crew-2u.meta" \
    "window=fakeses:fm-stuck-crew-2u-DEAD" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  # No status line: with a dead endpoint and no run, crew-state reports unknown.

  out=$(run_bridge "$home" "$fakebin")
  hold_band=$(band "$out" "WAITING / HELD")
  needs_band=$(band "$out" "NEEDS YOU")

  assert_contains "$hold_band" "stuck-crew-2u" "an unclassified live task must surface under WAITING / HELD via the catch-all"
  assert_not_contains "$needs_band" "stuck-crew-2u" "an unknown crew is not captain-actionable"

  pass "the catch-all keeps an otherwise-unclassified live task visible"
}

# --- Catch-all: idle secondmates excluded ------------------------------------
# A kind=secondmate whose crew-state reads "unknown" is a healthy resting
# supervisor (its busy-pane read is skipped by design), not a stuck task, so it
# must not surface via the catch-all in any band.
test_catchall_excludes_idle_secondmate() {
  local home fakebin out hold_band needs_band
  home=$(make_home catchall-sm)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/app"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Done
EOF
  fm_write_meta "$home/state/sm-triage-7q.meta" \
    "window=fakeses:fm-sm-triage-7q-DEAD" \
    "worktree=$home/projects/app" \
    "project=$home/projects/app" \
    "harness=codex" "kind=secondmate" "mode=no-mistakes" "yolo=off" \
    "home=$home/state/sm-home"
  # No status line and a gone endpoint: crew-state reports unknown, which for a
  # secondmate is the healthy idle resting state.

  out=$(run_bridge "$home" "$fakebin")
  hold_band=$(band "$out" "WAITING / HELD")
  needs_band=$(band "$out" "NEEDS YOU")

  assert_not_contains "$hold_band" "sm-triage-7q" "an idle secondmate must not render as a stuck task in the catch-all"
  assert_not_contains "$needs_band" "sm-triage-7q" "an idle secondmate is not captain-actionable"

  pass "the catch-all excludes a healthy idle secondmate"
}

test_acceptance_bands
test_needs_you_signals
test_direct_pr_awaits_checks
test_needs_you_done_no_pr_and_failed
test_held_paused_single_row
test_landed_budget_and_report_compaction
test_catchall_keeps_live_tasks_visible
test_catchall_excludes_idle_secondmate
test_frame_shape_and_empty_fleet
