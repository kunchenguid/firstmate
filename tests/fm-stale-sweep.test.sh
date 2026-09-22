#!/usr/bin/env bash
# Tests for bin/fm-stale-sweep.sh - the dead-endpoint stale-claim reclaim
# sweep over the shared Beads graph.
#
# The fixture graph is driven through bd directly, because the npm-published
# tasks-axi ships the markdown backend only ("Unsupported backend \"beads\" -
# P1 ships the markdown backend only"); only beads-capable tasks-axi builds
# (the local fork this fleet runs) can perform the sweep's reclaim mutations.
# Row state and bodies are therefore read back through bd as well. The
# tasks-axi-bound coverage - the apply/reclaim path and the claim-marker ACTOR
# column - probes that capability once and skips itself with an explicit
# reason on markdown-only installs, mirroring the suite runner's optional
# binary skips; everything else (selection, true-age display, orphan evidence
# columns and guards, check gating, arm/disarm) runs everywhere bd exists.
#
# Fixture: one firstmate home whose .tasks.toml points at a scratch Beads
# graph, holding four stale in_progress rows:
#   - fm-dead-row: owned by this home, endpoint dead (missing tmux target)
#   - fm-live-row: owned by this home, endpoint live (busy semantic record)
#   - fm-orphan-row: no owning home anywhere (no meta, no provenance)
#   - fm-prov-row: provenance names a markdown home with no meta; its reclaim
#     must fall back to the graph-owning sweep home for the mutation while the
#     note still names the provenance actor
#
# The dry run must list all four with the right verdicts and reclaim nothing;
# --apply must reopen exactly the dead rows with the reclaim note appended and
# never touch the live or unowned ones, and never remove a meta file. The
# `check` mode must print one line only when rows are reclaimable, gate itself
# on the interval record, and arm/disarm must write, register, and remove the
# watcher check shim.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

SWEEP="$ROOT/bin/fm-stale-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-stale-sweep)

# A fakebin whose tmux answers every target except the dead row's window, and
# whose no-mistakes reports no run anywhere (crew-state's run lookup finds
# nothing, so verdicts come from the pane/busy-record paths).
make_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *%dead*) exit 1 ;; esac
    done
    printf '%%1\n'
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) shift; printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# A real git repo checked out on <branch> so crew-state's run attribution has a
# branch to read.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# Build the fixture: home + scratch beads graph + four rows + metas. Echoes
# "<case>|<home>|<fakebin>". The graph repo dir is named "fm" because bd
# derives the row-id prefix from the repo directory name.
make_fixture() {  # <name>
  local name=$1 case_dir home graph fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  graph="$case_dir/fm"
  mkdir -p "$home/data" "$home/state" "$graph" "$case_dir/other-home"
  fb=$(make_fakebin "$case_dir")
  git -C "$graph" init -q
  # bd init can exit non-zero while still leaving a half-usable graph behind,
  # whose symptoms later surface as unrelated empty-table assertions, so the
  # init status and its output are checked here rather than discarded.
  if ! (cd "$graph" && bd init >"$case_dir/bd-init.log" 2>&1); then
    cat "$case_dir/bd-init.log" >&2
    printf '%s\n' "$case_dir/bd-init.log" > "$TMP_ROOT/fixture-failed"
    fail "fixture bd init failed on $graph"
  fi
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  # Every fixture row creation is loud: a swallowed failure here reads later
  # as an empty sweep table on some other machine, which is exactly the CI
  # failure mode this suite once shipped with. The captured log is printed
  # by the fail below so the runner's actual error is in the log. Both
  # streams are captured and the callers must not redirect inside the sh -c:
  # tasks-axi reports its errors on stdout, so a >/dev/null there would leave
  # the log empty exactly when a diagnosis is needed (the 2026-09-04 CI
  # failure mode). make_fixture runs inside a command substitution, so its
  # fail can only kill the subshell; the marker file lets read_fixture, which
  # runs in the real test shell, abort the whole suite with the log attached.
  fxlog="$case_dir/fixture-create.log"
  : > "$fxlog"
  FX_FAILED=
  fx() {
    if [ -n "$FX_FAILED" ]; then
      return 0
    fi
    if ! "$@" >>"$fxlog" 2>&1; then
      FX_FAILED=1
      printf 'fixture mutation failed: %s\n' "$*" >&2
      cat "$fxlog" >&2
      printf '%s\n' "$fxlog" > "$TMP_ROOT/fixture-failed"
      fail "fixture row creation failed: $*"
    fi
  }
  bdrows() {
    fx env BEADS_DIR="$graph/.beads" bd update "$1" --claim
  }
  if [ "$TASKS_AXI_BEADS_OK" = 1 ]; then
    # A beads-capable tasks-axi: rows carry its claim marker, which the ACTOR
    # column decodes and --apply-orphans treats as ownership evidence.
    for id in fm-dead-row fm-live-row fm-orphan-row fm-prov-row; do
      fx sh -c "cd '$home' && tasks-axi add '$id' 'fixture $id' --kind ship"
      fx sh -c "cd '$home' && tasks-axi start '$id'"
    done
    fx sh -c "cd '$home' && tasks-axi update fm-prov-row --body \
      'Provenance: imported 2026-09-01 from secondmate home widgets ($case_dir/other-home) markdown backlog'"
  else
    # The npm tasks-axi ships markdown only; create the same rows straight
    # through bd so everything except the marker-dependent coverage still runs.
    for id in fm-dead-row fm-live-row fm-orphan-row fm-prov-row; do
      fx env BEADS_DIR="$graph/.beads" bd create "fixture $id" --id "$id"
      bdrows "$id"
    done
    fx env BEADS_DIR="$graph/.beads" bd update fm-prov-row --description \
      "Provenance: imported 2026-09-01 from secondmate home widgets ($case_dir/other-home) markdown backlog"
  fi
  # Marker-less orphans created straight through bd: no tasks-axi claim marker
  # ever touched them, which is what --apply-orphans keys on.
  fx env BEADS_DIR="$graph/.beads" bd create "bare orphan" --id fm-bare-orphan
  fx env BEADS_DIR="$graph/.beads" bd update fm-bare-orphan --claim
  fx env BEADS_DIR="$graph/.beads" bd create "url orphan" --id fm-orphan-url
  fx env BEADS_DIR="$graph/.beads" bd update fm-orphan-url --claim
  fx env BEADS_DIR="$graph/.beads" bd update fm-orphan-url --description \
    "see https://github.com/o/r/pull/9 for the landing"
  fx env BEADS_DIR="$graph/.beads" bd create "prov orphan" --id fm-orphan-prov
  fx env BEADS_DIR="$graph/.beads" bd update fm-orphan-prov --claim
  fx env BEADS_DIR="$graph/.beads" bd update fm-orphan-prov --description \
    "Provenance: imported 2026-09-01 from secondmate home ghost ($case_dir/ghost-home) markdown backlog"
  [ -z "$FX_FAILED" ] || return 1
  make_repo_on_branch "$case_dir/wt-dead" fm/dead
  make_repo_on_branch "$case_dir/wt-live" fm/live
  fm_write_meta "$home/state/fm-dead-row.meta" \
    "window=firstmate:%dead" "worktree=$case_dir/wt-dead" "kind=ship" "harness=claude"
  fm_write_meta "$home/state/fm-live-row.meta" \
    "window=firstmate:%live" "worktree=$case_dir/wt-live" "kind=ship" "harness=claude"
  # The live row's endpoint is provably working: a semantic busy record.
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" fm-live-row)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" fm-live-row busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf '%s\n' "$case_dir|$home|$fb"
}

read_fixture() {
  # A make_fixture failure can only fail its own command-substitution subshell,
  # so a leftover marker means the fixture graph is absent and every later
  # assertion would fail with confusing secondary symptoms. Abort the suite
  # here, with the captured fixture log that names the real error.
  if [ -e "$TMP_ROOT/fixture-failed" ]; then
    cat "$(cat "$TMP_ROOT/fixture-failed")" >&2
    fail "the fixture graph could not be created; the captured fixture log above names the failing command and its real error"
  fi
  IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN <<EOF
$1
EOF
}

# A background process holding one per-task record lock the way a completing
# teardown does (the wake-lib lock protocol), so the sweep's contention path
# is exercised against a real holder.
make_lock_holder() {  # <dir>
  local dir=$1
  cat > "$dir/holder.sh" <<SH
#!/usr/bin/env bash
set -u
FM_ROOT_OVERRIDE="$ROOT"
FM_STATE_OVERRIDE="$dir/holder-state"
. "$ROOT/bin/fm-wake-lib.sh"
fm_lock_try_acquire "\$1" >/dev/null 2>&1 || exit 3
sleep 20
fm_lock_release "\$1" >/dev/null 2>&1
SH
  chmod +x "$dir/holder.sh"
}

# One capability probe for the whole suite: can the installed tasks-axi
# operate on a beads-backed home? The npm-published tasks-axi cannot (its P1
# ships markdown only), and the reclaim-mutation tests must skip themselves
# with that reason instead of failing.
probe_tasks_axi_beads() {
  local probe_home="$TMP_ROOT/.probe"
  rm -rf "$probe_home" "$TMP_ROOT/.probe-graph"
  mkdir -p "$probe_home/data" "$TMP_ROOT/.probe-graph"
  git -C "$TMP_ROOT/.probe-graph" init -q
  (cd "$TMP_ROOT/.probe-graph" && bd init >/dev/null 2>&1) || return 1
  cat > "$probe_home/.tasks.toml" <<PROBEEOF
backend = "beads"

[beads]
path = "$TMP_ROOT/.probe-graph/.beads"
binary = "bd"
prefix = "fm"
PROBEEOF
  (cd "$probe_home" && tasks-axi list) >/dev/null 2>&1
}
TASKS_AXI_BEADS_OK=0
if bd --version >/dev/null 2>&1 && probe_tasks_axi_beads; then
  TASKS_AXI_BEADS_OK=1
fi

# Guard for coverage that drives the sweep's reclaim mutations through
# tasks-axi: on a markdown-only install it skips with an explicit reason.
require_tasks_axi_beads() {  # <what>
  [ "$TASKS_AXI_BEADS_OK" = 1 ] && return 0
  pass "skipped on markdown-only tasks-axi: $1"
  return 1
}

# Row reads go through bd, the tool that owns the graph, so the helpers work
# under every tasks-axi. tasks-axi states map onto bd statuses.
row_field() {  # <id> <field>
  BEADS_DIR="$CASE_DIR/fm/.beads" bd show "$1" --json 2>/dev/null \
    | jq -r --arg f "$2" '.[0][$f] // "-"'
}
row_state() {  # <id>
  case "$(row_field "$1" status)" in
    in_progress) printf 'in_flight' ;;
    open) printf 'queued' ;;
    *) row_field "$1" status ;;
  esac
}
row_body() {  # <id>
  row_field "$1" description
}


# assert_row_matches <ere> <haystack> <msg>: one table row must match the
# pattern (lib.sh's assert_grep is fixed-string against a file, and the table's
# column padding needs a regex).
assert_row_matches() {
  printf '%s\n' "$2" | grep -Eq -- "$1" || fail "$3"
}

# The sweep clock runs 50 hours ahead so the freshly created rows are 26 hours
# stale against the default 24h threshold.
sweep_clock() {
  echo $(( $(date +%s) + 50 * 3600 ))
}

run_sweep() {  # [args...]
  FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW="$(sweep_clock)" \
    PATH="$FAKEBIN:$PATH" "$SWEEP" "$@"
}


# The AGE column shows the row's true age against the sweep clock, never the
# threshold-shifted value (a 25.5h row under the default 24h must read 25h,
# not 1h), and --older-than gates the selection itself: rows younger than the
# threshold never appear in the table.
test_age_column_is_true_age_and_threshold_gates_selection() {
  local rec out
  rec=$(make_fixture age)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  out=$(run_sweep)
  assert_row_matches 'fm-dead-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+dead' "$out" \
    "age column must show the true clock age, not the threshold-shifted age"
  # Rows aged ~2h by the clock with a 3h threshold: nothing is listed at all.
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$(( $(date +%s) + 2 * 3600 )) \
    PATH="$FAKEBIN:$PATH" "$SWEEP" --older-than 3)
  assert_contains "$out" "0 stale candidates" \
    "rows younger than --older-than must not be listed"
}

# No-home rows carry the row's own ownership evidence: the ACTOR column decodes
# the tasks-axi claim marker (marker-bearing rows show kind/repo, bare bd rows
# show -) and the PROV column carries the first 40 characters of the provenance
# line. --apply-orphans reclaims a no-home row only when it is older than 48h,
# carries no marker, and has no landing URL; without the flag every orphan is
# kept even when eligible.
test_orphan_columns_and_apply_orphans_guards() {
  local rec out rc date
  rec=$(make_fixture orphan)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  out=$(run_sweep)
  if [ "$TASKS_AXI_BEADS_OK" = 1 ]; then
    assert_row_matches 'fm-orphan-row[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+keep[[:space:]]+ship/-' "$out" \
      "marker-bearing orphan must show its claim actor, and stay kept without the flag"
  else
    # Under the markdown-only npm tasks-axi the rows are bd-created and carry
    # no marker, so the ACTOR column reads "-" and nothing else changes.
    assert_row_matches 'fm-orphan-row[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+keep[[:space:]]+-[[:space:]]+-$' "$out" \
      "bd-created orphan must read keep with empty actor and provenance columns"
  fi
  assert_row_matches 'fm-orphan-prov[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+keep[[:space:]]+-[[:space:]]+Provenance: imported 2026-09-01 from sec' "$out" \
    "provenance-bearing orphan must show the first 40 characters of its provenance line"
  assert_row_matches 'fm-orphan-url[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+keep[[:space:]]+-[[:space:]]+-$' "$out" \
    "marker-less orphan with a landing URL must stay kept and carry no actor or provenance"
  out=$(run_sweep --apply-orphans)
  assert_row_matches 'fm-bare-orphan[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+would reclaim \(orphan\)' "$out" \
    "eligible bare orphan must read would reclaim (orphan) under the flag"
  assert_row_matches 'fm-orphan-url[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+keep' "$out" \
    "a landing URL keeps an orphan reclaim-ineligible even under the flag"
  if [ "$TASKS_AXI_BEADS_OK" = 1 ]; then
    assert_row_matches 'fm-orphan-row[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+keep' "$out" \
      "a claim marker keeps an orphan reclaim-ineligible even under the flag"
    assert_contains "$out" "would reclaim 4" \
      "summary must count the eligible orphans among what a flagged apply would reclaim"
  else
    # Without markers fm-orphan-row is eligible too: 2 dead + 3 orphans.
    assert_contains "$out" "would reclaim 5" \
      "summary must count every eligible orphan under a markdown-only tasks-axi"
  fi
  # The 48h gate: the same fixture at 47h by the clock selects the rows via the
  # 24h threshold but the bare orphan stays kept.
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$(( $(date +%s) + 47 * 3600 )) \
    PATH="$FAKEBIN:$PATH" "$SWEEP" --apply-orphans)
  assert_row_matches 'fm-bare-orphan[[:space:]]+-[[:space:]]+[0-9]+h[[:space:]]+no-home[[:space:]]+keep' "$out" \
    "an orphan younger than 48h must stay kept even under the flag"
  # The real flagged apply at 50h reclaims exactly the bare orphan.
  require_tasks_axi_beads "the orphan apply path" || return 0
  out=$(run_sweep --apply --apply-orphans)
  rc=$?
  expect_code 0 "$rc" "flagged apply run should succeed"
  date=$(date +%F)
  [ "$(row_state fm-bare-orphan)" = queued ] || fail "eligible orphan was not reclaimed under the flag"
  assert_contains "$(row_body fm-bare-orphan)" "reclaimed $date: endpoint dead, previous claim by unknown" \
    "reclaimed orphan must carry the note naming the unknown claimant"
  [ "$(row_state fm-orphan-url)" = in_flight ] || fail "URL-bearing orphan was reclaimed under the flag"
  [ "$(row_state fm-orphan-row)" = in_flight ] || fail "marker-bearing orphan was reclaimed under the flag"
  [ "$(row_state fm-orphan-prov)" = queued ] || fail "eligible provenance orphan was not reclaimed under the flag"
  pass "orphan columns show actor and provenance; --apply-orphans honors age, marker, and URL guards"
}

test_dry_run_lists_verdicts_and_reclaims_nothing() {
  local rec out rc
  rec=$(make_fixture dry)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  out=$(run_sweep)
  rc=$?
  expect_code 0 "$rc" "dry run should succeed"
  if ! printf '%s\n' "$out" | grep -q fm-dead-row; then
    # Ground truth for any environment where the table comes back empty: the
    # graph exactly as this machine's bd emits it, plus the sweep's cutoff, so
    # a status-spelling or timestamp difference is visible in the CI log
    # instead of only the missing-table symptom.
    printf 'diagnostic: graph rows as bd emits them here:\n' >&2
    BEADS_DIR="$CASE_DIR/fm/.beads" bd list --all --json 2>&1 | head -c 3000 >&2
    printf '\ndiagnostic: sweep clock=%s older-than=24h\n' "$(sweep_clock)" >&2
  fi
  assert_contains "$out" "fm-dead-row" "dry run table lists the dead row"
  assert_contains "$out" "fm-live-row" "dry run table lists the live row"
  assert_contains "$out" "fm-orphan-row" "dry run table lists the unowned row"
  assert_contains "$out" "fm-prov-row" "dry run table lists the provenance row"
  assert_row_matches 'fm-dead-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+dead[[:space:]]+would reclaim' "$out" \
    "dead endpoint row must read dead / would reclaim"
  assert_row_matches 'fm-live-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+live[[:space:]]+keep' "$out" \
    "live endpoint row must read live / keep"
  assert_row_matches 'fm-orphan-row[[:space:]]+-[[:space:]]+50h[[:space:]]+no-home[[:space:]]+keep' "$out" \
    "unowned row must read no-home / keep"
  assert_row_matches 'fm-prov-row[[:space:]]+widgets[[:space:]]+50h[[:space:]]+dead[[:space:]]+would reclaim' "$out" \
    "provenance row must read dead under the provenance actor"
  assert_contains "$out" "7 stale candidates: 2 dead, 1 live, 0 unproven, 4 no-home; would reclaim 2" \
    "summary must count the dry-run verdicts"
  [ "$(row_state fm-dead-row)" = in_flight ] || fail "dry run changed the dead row's state"
  [ "$(row_state fm-live-row)" = in_flight ] || fail "dry run changed the live row's state"
  [ "$(row_state fm-orphan-row)" = in_flight ] || fail "dry run changed the unowned row's state"
  [ -f "$HOME_DIR/state/fm-dead-row.meta" ] || fail "dry run removed a meta file"
  pass "dry run lists every verdict and reclaims nothing"
}

test_apply_reclaims_only_dead_rows() {
  require_tasks_axi_beads "the reclaim apply path" || return 0
  local rec out rc date
  rec=$(make_fixture apply)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  out=$(run_sweep --apply)
  rc=$?
  expect_code 0 "$rc" "apply run should succeed"
  assert_row_matches 'fm-dead-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+dead[[:space:]]+reclaimed' "$out" \
    "dead endpoint row must be reclaimed"
  assert_row_matches 'fm-live-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+live[[:space:]]+keep' "$out" \
    "live endpoint row must stay untouched"
  assert_row_matches 'fm-orphan-row[[:space:]]+-[[:space:]]+50h[[:space:]]+no-home[[:space:]]+keep' "$out" \
    "unowned row must stay untouched"
  assert_row_matches 'fm-prov-row[[:space:]]+widgets[[:space:]]+50h[[:space:]]+dead[[:space:]]+reclaimed' "$out" \
    "provenance row must be reclaimed through the sweep home"
  assert_contains "$out" "reclaimed 2" "summary must count the reclaims"
  [ "$(row_state fm-dead-row)" = queued ] || fail "dead row was not reopened to queued"
  [ "$(row_state fm-prov-row)" = queued ] || fail "provenance row was not reopened to queued"
  [ "$(row_state fm-live-row)" = in_flight ] || fail "apply touched the live row"
  [ "$(row_state fm-orphan-row)" = in_flight ] || fail "apply touched the unowned row"
  date=$(date +%F)
  assert_contains "$(row_body fm-dead-row)" "reclaimed $date: endpoint dead, previous claim by main home" \
    "dead row body must carry the reclaim note with the owning actor"
  assert_contains "$(row_body fm-prov-row)" "reclaimed $date: endpoint dead, previous claim by widgets" \
    "provenance row body must carry the reclaim note with the provenance actor"
  case "$(row_body fm-live-row)" in
    *reclaimed*) fail "apply appended a note to the live row" ;;
  esac
  [ -f "$HOME_DIR/state/fm-dead-row.meta" ] || fail "apply removed the dead row's meta file"
  [ -f "$HOME_DIR/state/fm-live-row.meta" ] || fail "apply removed the live row's meta file"
  pass "apply reclaims exactly the dead rows with the note, touching nothing else"
}

test_check_mode_gates_on_the_interval_record() {
  local rec out t0
  rec=$(make_fixture check)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  t0=$(( $(date +%s) + 50 * 3600 ))
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$t0 PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "stale-sweep: 2 dead-endpoint in_progress rows reclaimable" \
    "first check must report the reclaimable rows"
  [ -f "$HOME_DIR/state/.stale-sweep" ] || fail "first check wrote no probe record"
  # Ten minutes later: inside the interval gate, must stay silent.
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 600)) PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  [ -z "$out" ] || fail "check inside the interval gate printed: $out"
  # After a full day: the gate reopens.
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 86401)) PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "stale-sweep: 2 dead-endpoint in_progress rows reclaimable" \
    "check after the interval must report again"
  # A clean graph stays silent even past the gate. Cleaning through the
  # sweep's own apply needs a beads-capable tasks-axi; a markdown-only install
  # reclaims the two dead rows straight through bd instead.
  if [ "$TASKS_AXI_BEADS_OK" = 1 ]; then
    FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 50 * 3600)) PATH="$FAKEBIN:$PATH" "$SWEEP" --apply >/dev/null
  else
    BEADS_DIR="$CASE_DIR/fm/.beads" bd close fm-dead-row fm-prov-row >/dev/null 2>&1
  fi
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 100 * 3600)) PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  [ -z "$out" ] || fail "check on a clean graph printed: $out"
  pass "check mode reports only past the interval gate and only when rows are reclaimable"
}

test_check_mode_reports_the_budget_cut() {
  local rec out
  rec=$(make_fixture cut)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  # FM_CHECK_TIMEOUT=8 cuts the 25s budget to 5 (CHECK_TIMEOUT-3), so the
  # check must report the cut alongside its reclaimable verdict.
  out=$(FM_HOME="$HOME_DIR" FM_CHECK_TIMEOUT=8 FM_STALE_SWEEP_NOW="$(sweep_clock)" \
    PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "note: FM_STALE_SWEEP_BUDGET_SECS 25 cut to 5 to fit FM_CHECK_TIMEOUT" \
    "check mode must report the budget cut instead of swallowing it"
  printf '%s\n' "$out" | grep -q "^stale-sweep: " || fail "the cut note must not replace the reclaimable report"
  pass "check mode reports the budget cut alongside its reclaimable verdict"
}

test_apply_names_the_resolved_homes_actor_when_two_homes_hold_meta() {
  require_tasks_axi_beads "the reclaim apply path" || return 0
  local rec out date
  rec=$(make_fixture handoff)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  # A second registered home also holding the dead row's meta is the handoff
  # seam; the resolved home stays this home (listed first), so the reclaim note
  # must carry this home's actor, not the last-scanned registry home's id.
  mkdir -p "$CASE_DIR/other-home/state"
  fm_write_meta "$CASE_DIR/other-home/state/fm-dead-row.meta" \
    "window=firstmate:%dead" "worktree=$CASE_DIR/wt-dead" "kind=ship" "harness=claude"
  printf '%s\n' "- widgets2 - handoff twin (home: $CASE_DIR/other-home; repo: -)" \
    > "$HOME_DIR/data/secondmates.md"
  out=$(run_sweep --apply)
  date=$(date +%F)
  assert_contains "$(row_body fm-dead-row)" "reclaimed $date: endpoint dead, previous claim by main home" \
    "the note must name the resolved first home's actor, not the last scanned one"
  [ "$(row_state fm-dead-row)" = queued ] || fail "the dead row was not reclaimed"
  pass "a two-home handoff reclaims through the first home and names its actor"
}

# A bd that hangs: in check mode the graph read must be bounded by the budget
# so the probe fails visibly (with its record written) instead of being killed
# silently by the watcher's timeout.
test_check_mode_bounds_the_graph_read() {
  local rec out t0 bdslow="$TMP_ROOT/bdslow/fakebin"
  rec=$(make_fixture bdslow)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  mkdir -p "$bdslow"
  cat > "$bdslow/bd" <<'SH'
#!/usr/bin/env bash
sleep 5
exit 0
SH
  chmod +x "$bdslow/bd"
  t0=$(sweep_clock)
  out=$(FM_HOME="$HOME_DIR" FM_CHECK_TIMEOUT=3 FM_STALE_SWEEP_NOW=$t0 \
    PATH="$bdslow:$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "fm-stale-sweep: graph read failed" \
    "a graph read that exceeds the budget must fail visibly, not silently"
  # The probe record is still written, so the next poll inside the interval
  # stays quiet instead of retrying a doomed read every poll.
  out=$(FM_HOME="$HOME_DIR" FM_CHECK_TIMEOUT=3 FM_STALE_SWEEP_NOW=$((t0 + 600)) \
    PATH="$bdslow:$FAKEBIN:$PATH" "$SWEEP" check)
  [ -z "$out" ] || fail "check inside the interval gate printed: $out"
  pass "check mode bounds the graph read by the budget and records the failed probe"
}

test_arm_disarm_roundtrip() {
  local rec
  rec=$(make_fixture arm)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$SWEEP" arm >/dev/null \
    || fail "arm failed"
  [ -f "$HOME_DIR/state/stale-sweep.check.sh" ] || fail "arm wrote no check shim"
  [ -f "$HOME_DIR/state/stale-sweep.check-trust" ] || fail "arm registered no trust binding"
  [ "$(stat -c %a "$HOME_DIR/state/stale-sweep.check.sh")" = 700 ] \
    || fail "check shim is not mode 0700"
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$SWEEP" disarm >/dev/null \
    || fail "disarm failed"
  [ ! -e "$HOME_DIR/state/stale-sweep.check.sh" ] || fail "disarm left the shim"
  [ ! -e "$HOME_DIR/state/stale-sweep.check-trust" ] || fail "disarm left the trust binding"
  [ ! -e "$HOME_DIR/state/.stale-sweep" ] || fail "disarm left the report record"
  pass "arm writes and registers the check shim; disarm removes all of it"
}

# A record lock held by another actor: a completion (teardown's meta removal
# plus `tasks-axi done`) owns the row right now, so the sweep must refuse the
# row instead of racing the close and resurrecting finished work. After the
# holder dies, the same sweep reclaims the row, proving the lock was the gate.
test_apply_refuses_a_row_whose_record_lock_a_completion_holds() {
  require_tasks_axi_beads "the reclaim apply path" || return 0
  local rec out holder_pid lock
  rec=$(make_fixture lockheld)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  make_lock_holder "$CASE_DIR"
  lock="$HOME_DIR/state/.meta-fm-dead-row.lock"
  "$CASE_DIR/holder.sh" "$lock" >/dev/null 2>&1 &
  holder_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$lock" ] && break
    sleep 0.1
  done
  [ -e "$lock" ] || fail "fixture holder never took the record lock"
  out=$(run_sweep --apply)
  assert_row_matches \
    'fm-dead-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+dead[[:space:]]+reclaim failed: record locked by another actor' \
    "$out" "a row whose record lock a completion holds must be refused, not reopened"
  [ "$(row_state fm-dead-row)" = in_flight ] || fail "the sweep touched a row whose record lock was held"
  assert_contains "$out" "reclaimed 1" \
    "the summary must count only the row the lock did not protect"
  [ "$(row_state fm-prov-row)" = queued ] \
    || fail "a record home with no state dir must still reclaim (no lock to share)"
  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null
  out=$(run_sweep --apply)
  assert_row_matches 'fm-dead-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+dead[[:space:]]+reclaimed' "$out" \
    "once no completion holds the record lock, the same sweep must reclaim the row"
  [ "$(row_state fm-dead-row)" = queued ] || fail "the row was not reclaimed after the lock freed"
  [ ! -e "$lock" ] || fail "the sweep left the record lock behind after reclaiming"
  pass "a row whose record lock a completion holds is refused until the lock frees"
}

# A pending backlog-close replay record: a completion was recorded and is still
# owed (the teardown crash window), so the row must never be reopened.
test_apply_refuses_a_row_with_a_pending_completion_replay() {
  require_tasks_axi_beads "the reclaim apply path" || return 0
  local rec out
  rec=$(make_fixture closereplay)
  [ -n "$rec" ] || fail "fixture construction failed (see stderr above)"
  read_fixture "$rec"
  {
    printf 'id=fm-dead-row\n'
    printf 'data=%s/data\n' "$HOME_DIR"
    printf 'spawn_gen=fm-dead-row-gen\n'
    printf 'cleanup_incomplete=0\n'
  } > "$HOME_DIR/state/fm-dead-row.backlog-close"
  out=$(run_sweep --apply)
  assert_row_matches \
    'fm-dead-row[[:space:]]+main home[[:space:]]+50h[[:space:]]+dead[[:space:]]+reclaim failed: completion replay pending' \
    "$out" "a row with a pending completion replay must be refused, not reopened"
  [ "$(row_state fm-dead-row)" = in_flight ] || fail "the sweep touched a row whose completion is still owed"
  rm -f "$HOME_DIR/state/fm-dead-row.backlog-close"
  run_sweep --apply >/dev/null
  [ "$(row_state fm-dead-row)" = queued ] \
    || fail "the row was not reclaimed once no completion was pending"
  pass "a row with a pending completion replay is refused until the replay lands"
}

test_apply_refuses_unreadable_full_row() {
  require_tasks_axi_beads "full row read failure" || return 0
  local rec out before rc
  rec=$(make_fixture fullread)
  read_fixture "$rec"
  before=$(row_body fm-dead-row)
  export FM_TEST_REAL_TASKS_AXI
  FM_TEST_REAL_TASKS_AXI=$(command -v tasks-axi)
  cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = show ] && [ "${2:-}" = fm-dead-row ] && [ "${3:-}" = --full ]; then
  printf 'fixture full read failure\n' >&2
  exit 1
fi
exec "$FM_TEST_REAL_TASKS_AXI" "$@"
SH
  chmod +x "$FAKEBIN/tasks-axi"
  out=$(run_sweep --apply)
  rc=$?
  expect_code 1 "$rc" "failed full read must fail reclamation"
  assert_contains "$out" "full row unreadable" "full read failure is reported"
  [ "$(row_body fm-dead-row)" = "$before" ] || fail "failed full read changed the body"
  [ "$(row_state fm-dead-row)" = in_flight ] || fail "failed full read reopened the task"
  pass "unreadable full row preserves task state and body"
}

test_apply_refuses_unreadable_full_row

test_age_column_is_true_age_and_threshold_gates_selection
test_orphan_columns_and_apply_orphans_guards
test_dry_run_lists_verdicts_and_reclaims_nothing
test_apply_reclaims_only_dead_rows
test_apply_refuses_a_row_whose_record_lock_a_completion_holds
test_apply_refuses_a_row_with_a_pending_completion_replay
test_apply_names_the_resolved_homes_actor_when_two_homes_hold_meta
test_check_mode_gates_on_the_interval_record
test_check_mode_reports_the_budget_cut
test_check_mode_bounds_the_graph_read
test_arm_disarm_roundtrip

echo "# all fm-stale-sweep tests passed"
