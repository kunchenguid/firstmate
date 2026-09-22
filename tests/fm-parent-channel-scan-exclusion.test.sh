#!/usr/bin/env bash
# tests/fm-parent-channel-scan-exclusion.test.sh - a remote mate home's own
# outbound parent channel (state/parent-replies.status, resolved through
# bin/fm-parent-channel-lib.sh) must not be enumerated by the home's own status
# scans: every parent-channel append is mirrored into the parent home by the
# remote reply adapter, so folding or waking on it here spins spurious signal
# wakes and phantom "parent-replies" open decisions. The exclusion must be
# home-shape-aware: a parent-replies.status in a main home, in a local mate, or
# in any other home shape is an ordinary task log and keeps waking and folding.
#
# Covers the watcher scan (scan_signals, the heartbeat fail-safe backstop) and
# fm-classify-lib.sh's fleet-wide folds (whole-file, incremental,
# presentation snapshot, unread surface), each against a real remote mate
# fixture plus the main-home and local-mate negative cases, and the real
# fm-wake-drain.sh end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-parent-channel-scan-exclusion)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# The real drain asserts watcher liveness through fm-guard.sh, whose tangle
# check warns when FM_ROOT sits on a feature branch; point it at a fresh
# non-git dir so the banner stays inert in this disposable worktree (the same
# trick tests/wake-helpers.sh installs for the drain suites).
FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-parent-channel-scan-exclusion-root)"
export FM_ROOT_OVERRIDE
mkdir -p "$FM_ROOT_OVERRIDE"

cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

# seed_remote_mate <dir>: build a remote mate home whose state dir carries one
# genuine task log and the outbound parent channel, with one captain-facing
# decision, one reserved-key resolution, and one informational note on the
# channel - exactly the line shapes a mate home publishes mechanically.
seed_remote_mate() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  printf '%s\n' mate > "$dir/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote.example\n' \
    > "$dir/.fm-secondmate-parent"
  printf 'needs-decision [key=captain-hold-pr-7-1]: captain hold pr-7: merge the green PR?\n' \
    > "$dir/state/parent-replies.status"
  printf 'resolved [key=captain-hold-pr-5-2]: captain chose the staged rollout\n' \
    >> "$dir/state/parent-replies.status"
  printf 'note: the release branch is cut\n' >> "$dir/state/parent-replies.status"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/state/real-task.status"
  printf 'note: benchmark results are in\n' >> "$dir/state/real-task.status"
}

# seed_plain_home <dir>: a main home (no secondmate identity marker) whose
# state dir carries a parent-replies.status that merely shares the name.
seed_plain_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  printf 'needs-decision [key=name-only]: an ordinary task file that shares the name\n' \
    > "$dir/state/parent-replies.status"
  printf 'needs-decision [key=other-task]: a genuine sibling task decision\n' \
    > "$dir/state/other-task.status"
}

# seed_local_mate <dir> <parent-home>: a LOCAL mate home - its parent channel
# lives in the parent home's state/<id>.status, so a parent-replies.status in
# its own state dir is an ordinary self-home file.
seed_local_mate() {  # <dir> <parent-home>
  local dir=$1 parent_home=$2
  mkdir -p "$dir/state"
  printf '%s\n' mate > "$dir/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent_home" \
    > "$dir/.fm-secondmate-parent"
  printf 'needs-decision [key=local-shape]: still an ordinary self-home file\n' \
    > "$dir/state/parent-replies.status"
}

REMOTE="$TMP_ROOT/remote-mate"
PLAIN="$TMP_ROOT/main-home"
LOCAL_MATE="$TMP_ROOT/local-mate"
seed_remote_mate "$REMOTE"
seed_plain_home "$PLAIN"
seed_local_mate "$LOCAL_MATE" "$PLAIN"
REMOTE_STATE="$REMOTE/state"
PLAIN_STATE="$PLAIN/state"
LOCAL_STATE="$LOCAL_MATE/state"

# --- unit: the exclusion predicates -----------------------------------------

test_predicate_resolves_only_the_remote_channel() {
  local out rc
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    status_scan_parent_channel_exclude "$2"
  ' _ "$ROOT" "$REMOTE_STATE") \
    || fail "the remote mate's channel must resolve for exclusion, got rc=$?"
  [ "$out" = "$REMOTE_STATE/parent-replies.status" ] \
    || fail "the exclusion must be the resolved channel path, got: $out"
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    status_scan_parent_channel_exclude "$2"
  ' _ "$ROOT" "$PLAIN_STATE")
  [ -z "$out" ] || fail "a main home must exclude nothing, got: $out"
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    status_scan_parent_channel_exclude "$2"
  ' _ "$ROOT" "$LOCAL_STATE")
  [ -z "$out" ] || fail "a local mate must exclude nothing, got: $out"
  pass "only a remote mate home resolves its own parent channel for exclusion"
}

test_resolver_predicates_on_home_shape_not_name() {
  local out
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$1/bin/fm-parent-channel-lib.sh"
    fm_parent_channel_outbound_status "$2" "$3"
  ' _ "$ROOT" "$REMOTE" "$REMOTE_STATE") \
    || fail "the remote mate's outbound status must resolve"
  [ "$out" = "$REMOTE_STATE/parent-replies.status" ] \
    || fail "the remote route must resolve into the mate's own state dir, got: $out"
  FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$1/bin/fm-parent-channel-lib.sh"
    fm_parent_channel_outbound_status "$2" "$3"
  ' _ "$ROOT" "$PLAIN" "$PLAIN_STATE" \
    && fail "a main home has no outbound parent-channel status"
  FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$1/bin/fm-parent-channel-lib.sh"
    fm_parent_channel_outbound_status "$2" "$3"
  ' _ "$ROOT" "$LOCAL_MATE" "$LOCAL_STATE" \
    && fail "a local mate's channel lives in the parent home, not its own state dir"
  pass "fm_parent_channel_outbound_status resolves only the remote route"
}

# --- unit: the fleet-wide folds omit the channel and keep genuine tasks -----

test_remote_folds_omit_channel_and_keep_genuine_task() {
  local dir out
  dir="$TMP_ROOT/folds"
  seed_remote_mate "$dir/home"
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    echo "WHOLE:"; scan_open_decisions "$2"
    echo "SNAPSHOT:"; status_presentation_snapshot "$2"
    echo "UNREAD:"; scan_unread_surface_lines "$2"
  ' _ "$ROOT" "$dir/home/state") || fail "the remote-mate fold pass failed"
  case "$out" in *parent-replies*)
    fail "the channel leaked into the remote mate's folds: $out" ;;
  esac
  printf '%s\n' "$out" | sed -n '/^WHOLE:/,/^SNAPSHOT:/p' | grep -F 'api-shape' >/dev/null \
    || fail "the genuine task's open decision must still fold: $out"
  printf '%s\n' "$out" | sed -n '/^SNAPSHOT:/,/^UNREAD:/p' | grep -F 'real-task' >/dev/null \
    || fail "the genuine task must stay in the presentation snapshot: $out"
  printf '%s\n' "$out" | sed -n '/^UNREAD:/,$p' | grep -F 'benchmark results' >/dev/null \
    || fail "the genuine task's note must stay on the unread surface: $out"
  pass "a remote mate's folds omit its channel and keep a genuine task"
}

test_incremental_fold_omits_channel_and_keeps_genuine_task() {
  local dir out
  dir="$TMP_ROOT/folds-incremental"
  seed_remote_mate "$dir/home"
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    scan_open_decisions_incremental "$2"
  ' _ "$ROOT" "$dir/home/state") || fail "the incremental fold failed"
  case "$out" in *parent-replies*)
    fail "the channel leaked into the incremental fold: $out" ;;
  esac
  printf '%s\n' "$out" | grep -F 'api-shape' >/dev/null \
    || fail "the genuine task's decision must still fold incrementally: $out"
  pass "the cursor-backed incremental fold omits a remote mate's channel"
}

test_channel_lines_never_reach_the_remote_unread_surface() {
  local dir out
  dir="$TMP_ROOT/unread"
  seed_remote_mate "$dir/home"
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    scan_unread_surface_lines "$2"
  ' _ "$ROOT" "$dir/home/state") || fail "the unread-surface scan failed"
  case "$out" in *parent-replies*|*captain-hold*|*release\ branch*)
    fail "channel decision, resolution, or note surfaced as self-home unread status: $out" ;;
  esac
  pass "the channel's resolution and note lines stay off the remote unread surface"
}

test_name_shared_file_folds_in_a_main_home() {
  local out
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    scan_open_decisions "$2"
  ' _ "$ROOT" "$PLAIN_STATE") || fail "the main-home fold failed"
  printf '%s\n' "$out" | grep -F 'name-only' >/dev/null \
    || fail "a main home's parent-replies.status must keep folding as an ordinary task: $out"
  printf '%s\n' "$out" | grep -F 'other-task' >/dev/null \
    || fail "the sibling task decision must keep folding: $out"
  pass "a parent-replies.status in a main home still folds"
}

test_name_shared_file_folds_in_a_local_mate() {
  local out
  out=$(FM_TEST_LIB_SOURCED=1 bash -c '
    # shellcheck source=bin/fm-classify-lib.sh
    . "$1/bin/fm-classify-lib.sh"
    scan_open_decisions "$2"
  ' _ "$ROOT" "$LOCAL_STATE") || fail "the local-mate fold failed"
  printf '%s\n' "$out" | grep -F 'local-shape' >/dev/null \
    || fail "a local mate's parent-replies.status must keep folding: $out"
  pass "a parent-replies.status in a local mate still folds"
}

# --- unit: the watcher's signal scan and heartbeat backstop -----------------

# Source the watcher once with an isolated state/home; its source guard returns
# before the lock/loop, so only the functions load. scan_signals and
# heartbeat_scan_finds_actionable read STATE at call time. FM_ROOT_OVERRIDE
# stays at the inert dir set above; the unit-called functions read STATE, not
# the repo root.
WATCH_STATE="$REMOTE_STATE"
export FM_STATE_OVERRIDE="$WATCH_STATE"
export FM_HOME="$REMOTE"
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

test_watcher_scan_skips_channel_and_keeps_task_in_remote_mate() {
  local out rc
  STATE="$REMOTE_STATE"
  out=$(scan_signals) || fail "scan_signals failed over the remote mate state"
  printf '%s\n' "$out" | cut -f3 | grep -F 'parent-replies.status' >/dev/null \
    && fail "the channel must not produce a signal wake: $out"
  printf '%s\n' "$out" | cut -f3 | grep -F 'real-task.status' >/dev/null \
    || fail "the genuine task's status must still wake: $out"
  pass "scan_signals skips a remote mate's channel and still reports its tasks"
}

test_heartbeat_backstop_skips_channel_in_remote_mate() {
  local dir rc
  dir="$TMP_ROOT/heartbeat"
  seed_remote_mate "$dir/home"
  # A quiet task log keeps the first pass channel-only: the note: line is
  # informational, so only the excluded channel could make the scan actionable.
  printf 'note: benchmark results are in\n' > "$dir/home/state/real-task.status"
  STATE="$dir/home/state"
  heartbeat_scan_finds_actionable; rc=$?
  [ "$rc" -eq 1 ] || fail "the channel must not surface through the heartbeat backstop (rc=$rc): $FM_HEARTBEAT_SURFACE_ENDPOINTS"
  case "$FM_HEARTBEAT_SURFACE_ENDPOINTS" in
    *parent-replies*) fail "the channel leaked into the heartbeat backstop: $FM_HEARTBEAT_SURFACE_ENDPOINTS" ;;
  esac
  # A genuine task's captain-relevant line must keep reaching the backstop.
  printf 'blocked [key=wedge]: the crew is stuck\n' >> "$dir/home/state/real-task.status"
  heartbeat_scan_finds_actionable; rc=$?
  [ "$rc" -eq 0 ] || fail "a genuine task's decision must surface through the heartbeat backstop"
  case "$FM_HEARTBEAT_SURFACE_ENDPOINTS" in
    *real-task.status*) ;;
    *) fail "the heartbeat backstop must name the genuine task: $FM_HEARTBEAT_SURFACE_ENDPOINTS" ;;
  esac
  case "$FM_HEARTBEAT_SURFACE_ENDPOINTS" in
    *parent-replies*) fail "the channel leaked into the heartbeat backstop: $FM_HEARTBEAT_SURFACE_ENDPOINTS" ;;
  esac
  pass "the heartbeat backstop skips a remote mate's channel and keeps its tasks"
}

test_watcher_scan_keeps_name_shared_files_outside_remote_mates() {
  local out
  STATE="$PLAIN_STATE"
  out=$(scan_signals) || fail "scan_signals failed over the main-home state"
  printf '%s\n' "$out" | cut -f3 | grep -F 'parent-replies.status' >/dev/null \
    || fail "a main home's parent-replies.status must keep waking: $out"
  # shellcheck disable=SC2034 # read by the sourced watcher's scans at call time
  STATE="$LOCAL_STATE"
  out=$(scan_signals) || fail "scan_signals failed over the local-mate state"
  printf '%s\n' "$out" | cut -f3 | grep -F 'parent-replies.status' >/dev/null \
    || fail "a local mate's parent-replies.status must keep waking: $out"
  pass "scan_signals keeps parent-replies.status outside remote mate homes"
}

# --- end to end: the real drain over a remote mate home ---------------------

test_drain_presents_no_channel_content_in_remote_mate() {
  local dir out manifest
  dir="$TMP_ROOT/drain"
  seed_remote_mate "$dir/home"
  mkdir -p "$dir/home/data"
  FM_STATE_OVERRIDE="$dir/home/state" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" \
    || fail "the drain failed over a remote mate home"
  out=$(cat "$dir/drain.out")
  case "$out" in *parent-replies*)
    fail "the drain presented the remote mate's channel: $out" ;;
  esac
  printf '%s\n' "$out" | grep -F 'api-shape' >/dev/null \
    || fail "the genuine task's open decision must still surface in OPEN DECISIONS: $out"
  printf '%s\n' "$out" | grep -F 'benchmark results' >/dev/null \
    || fail "the genuine task's note must still surface under UNREAD STATUS: $out"
  # The presentation manifest is rebuilt from the excluded snapshot, so a
  # channel row an older watcher recorded must not survive the drain.
  manifest=$(cat "$dir/home/state/.status-presentation-cursor" 2>/dev/null || true)
  case "$manifest" in *parent-replies*)
    fail "the presentation manifest still tracks the channel: $manifest" ;;
  esac
  pass "the real drain presents no channel content from a remote mate home"
}

test_drain_ignores_stale_channel_records_from_an_older_watcher() {
  local dir out manifest
  dir="$TMP_ROOT/drain-stale"
  seed_remote_mate "$dir/home"
  mkdir -p "$dir/home/data"
  # An older watcher folded the channel and tracked it as a task; the fixed
  # drain must drop both rather than present or choke on them.
  printf 'needs-decision [key=old-phantom]: folded by the unfixed watcher\n' \
    > "$dir/home/state/.parent-replies.open-decisions-cursor"
  printf 'parent-replies\tstrong:1:2:3\t99\t0\n' \
    > "$dir/home/state/.status-presentation-cursor"
  FM_STATE_OVERRIDE="$dir/home/state" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" \
    || fail "the drain failed over stale channel records"
  out=$(cat "$dir/drain.out")
  case "$out" in *parent-replies*|*old-phantom*)
    fail "a stale channel fold resurfaced through the drain: $out" ;;
  esac
  manifest=$(cat "$dir/home/state/.status-presentation-cursor" 2>/dev/null || true)
  case "$manifest" in *parent-replies*)
    fail "the stale manifest row survived the drain: $manifest" ;;
  esac
  pass "stale channel records from an older watcher are dropped, not presented"
}

test_predicate_resolves_only_the_remote_channel
test_resolver_predicates_on_home_shape_not_name
test_remote_folds_omit_channel_and_keep_genuine_task
test_incremental_fold_omits_channel_and_keeps_genuine_task
test_channel_lines_never_reach_the_remote_unread_surface
test_name_shared_file_folds_in_a_main_home
test_name_shared_file_folds_in_a_local_mate
test_watcher_scan_skips_channel_and_keeps_task_in_remote_mate
test_heartbeat_backstop_skips_channel_in_remote_mate
test_watcher_scan_keeps_name_shared_files_outside_remote_mates
test_drain_presents_no_channel_content_in_remote_mate
test_drain_ignores_stale_channel_records_from_an_older_watcher
