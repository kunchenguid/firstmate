#!/usr/bin/env bash
# Tests for bin/fm-nm-orphan-scan.sh: the ownership-bounded scan that reports a
# no-mistakes run THIS home armed which is parked with no live task left to
# answer it, and that says nothing about any run this home did not arm.
#
# The hard boundary under test is the range guard: the machine-wide `no-mistakes
# parked` record can carry the captain's own runs and other homes' runs, and the
# scan must read past every one of them in silence, reporting only the run ids
# recorded in this home's own data/nm-armed-runs ledger.
#
# Matrix:
#   (a) a ledger run that is parked with no live task -> reported as NM_ORPHAN
#   (b) a parked run NOT in this home's ledger (the captain's own work) -> silent
#   (c) a ledger run a live task still owns via nm_watch_run -> silent
#   (d) a ledger run whose fm/<id> task is still live (re-armed watch) -> silent
#   (e) no ledger at all -> silent
#   (f) no-mistakes absent -> silent
#   (g) nothing parked (parked --json exits 1) -> silent
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SCAN="$ROOT/bin/fm-nm-orphan-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-orphan-scan-tests)

MINE=01KRUNMINE0000000000000001
THEIRS=01KRUNTHEIRS000000000000009

# A sandbox with a state dir, a data dir, and a fake no-mistakes whose `parked
# --json` reads <case>/parked.json (exit 0 when it has entries, 1 when empty,
# mirroring the real CLI). No ledger and no parked.json are written by default,
# so each test supplies exactly the ownership picture it exercises.
make_case() {  # <name> -> case dir
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin"
  printf '[]\n' > "$case_dir/parked.json"
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ -e '$case_dir/nm-broken' ]; then
  echo "no-mistakes: cannot reach state" >&2
  exit 3
fi
case "\$1 \$2" in
  "parked --json")
    cat '$case_dir/parked.json'
    grep -q '"run"' '$case_dir/parked.json' && exit 0
    exit 1
    ;;
esac
exit 2
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$case_dir"
}

# Write parked.json with one entry per given run id, each on branch fm/task-a.
# The captain's own run is always present too, so every read has something to
# wrongly report if the range guard leaks.
parked_with() {  # <case-dir> [run-id ...]
  local case_dir=$1 entries run
  shift
  entries='{"run":"'$THEIRS'","repo":"/captain/own/repo","branch":"wip","step":"review","gate":"fix_review","parked_for":"3h","findings":[{"id":"captain-private","description":"a finding in the captain'"'"'s own repo"}]}'
  for run in "$@"; do
    entries="$entries,"'{"run":"'$run'","repo":"/p","branch":"fm/task-a","step":"watch","gate":"review_threads","parked_for":"1d21h","findings":[{"id":"unresolved-thread","description":"2 unresolved review threads on the PR"}]}'
  done
  printf '[%s]\n' "$entries" > "$case_dir/parked.json"
}

ledger_line() {  # <case-dir> <run-id> [task-id] [branch]
  printf '%s %s %s %s\n' 1700000000 "$2" "${3:-task-a}" "${4:-fm/task-a}" >> "$1/data/nm-armed-runs"
}

live_meta() {  # <case-dir> <task-id> [nm_watch_run]
  local case_dir=$1 id=$2
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=fm-$id" "worktree=$case_dir/wt" "project=$case_dir/wt" "kind=ship" "mode=direct-PR"
  [ "$#" -ge 3 ] && printf 'nm_watch_run=%s\n' "$3" >> "$case_dir/state/$id.meta"
}

run_scan() {  # <case-dir>
  local case_dir=$1
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_NM_BIN="$case_dir/fakebin/no-mistakes" "$SCAN" 2>/dev/null
}

test_ledger_orphan_is_reported() {
  local dir out
  dir=$(make_case orphan)
  # This home armed MINE (its task is now gone: no meta), and MINE is parked.
  ledger_line "$dir" "$MINE"
  parked_with "$dir" "$MINE"

  out=$(run_scan "$dir")
  assert_contains "$out" "NM_ORPHAN:" "orphan: this home's own orphaned park was not reported"
  assert_contains "$out" "$MINE" "orphan: the report did not name the orphaned run"
  assert_contains "$out" "no-mistakes axi respond --run $MINE" "orphan: the report gave no way to settle the run"
  assert_not_contains "$out" "$THEIRS" "orphan: the report leaked the captain's own parked run"
  pass "a ledger run parked with no live task is reported as an orphan"
}

test_run_not_in_ledger_is_silent() {
  local dir out
  dir=$(make_case foreign)
  # The ledger records only MINE; the captain's own THEIRS is parked but was
  # never armed here, and MINE is not parked at all.
  ledger_line "$dir" "$MINE"
  parked_with "$dir"   # only THEIRS is in the record

  out=$(run_scan "$dir")
  [ -z "$out" ] || fail "foreign: a parked run this home never armed was reported: $out"
  pass "a parked run not in this home's ledger stays silent"
}

test_live_meta_owned_run_is_silent() {
  local dir out
  dir=$(make_case owned)
  ledger_line "$dir" "$MINE"
  parked_with "$dir" "$MINE"
  # A live task still records MINE as its watch run, so the armed poll owns it.
  live_meta "$dir" task-a "$MINE"

  out=$(run_scan "$dir")
  [ -z "$out" ] || fail "owned: a park a live task's poll owns was reported as an orphan: $out"
  pass "a ledger run a live task still owns via nm_watch_run stays silent"
}

test_live_branch_task_is_silent() {
  local dir out
  dir=$(make_case rearmed)
  ledger_line "$dir" "$MINE"
  parked_with "$dir" "$MINE"
  # No meta records MINE as its run, but the fm/task-a task is still live: the
  # park belongs to a re-armed or superseded watch, not an orphan.
  live_meta "$dir" task-a

  out=$(run_scan "$dir")
  [ -z "$out" ] || fail "rearmed: a park whose fm/<id> task is still live was reported: $out"
  pass "a ledger run whose fm/<id> task is still live stays silent"
}

test_no_ledger_is_silent() {
  local dir out
  dir=$(make_case noledger)
  parked_with "$dir" "$MINE"   # parked, but this home armed nothing

  out=$(run_scan "$dir")
  [ -z "$out" ] || fail "noledger: a home that armed nothing reported an orphan: $out"
  pass "a home with no ledger reports no orphan"
}

test_no_no_mistakes_is_silent() {
  local dir out
  dir=$(make_case nonm)
  ledger_line "$dir" "$MINE"
  parked_with "$dir" "$MINE"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_NM_BIN="$dir/fakebin/does-not-exist" "$SCAN" 2>/dev/null)
  [ -z "$out" ] || fail "nonm: the scan spoke with no-mistakes absent: $out"
  pass "the scan is silent when no-mistakes is absent"
}

test_nothing_parked_is_silent() {
  local dir out
  dir=$(make_case empty)
  ledger_line "$dir" "$MINE"
  parked_with "$dir"   # only THEIRS; MINE is not parked

  out=$(run_scan "$dir")
  [ -z "$out" ] || fail "empty: the scan reported a run this home armed that is not parked: $out"
  pass "a ledger run that is not currently parked is not reported"
}

test_ledger_orphan_is_reported
test_run_not_in_ledger_is_silent
test_live_meta_owned_run_is_silent
test_live_branch_task_is_silent
test_no_ledger_is_silent
test_no_no_mistakes_is_silent
test_nothing_parked_is_silent
