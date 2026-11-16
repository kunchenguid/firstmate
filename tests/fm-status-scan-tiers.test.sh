#!/usr/bin/env bash
# tests/fm-status-scan-tiers.test.sh - the drain's status scan reads every
# status file with a fixed number of processes, and the opt-in
# config/status-scan-tiers file limits an ordinary drain to hot files without
# ever losing an open decision or unread line. Portable: real drain and
# classify functions over crafted status logs, no harness.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-scan-tiers-tests)

# A home that does not run the supervision host keeps BRANCH OUTCOMES out of
# the drain (bin/fm-supervision-engine-lib.sh owns the gate).
mkdir -p "$TMP_ROOT/config-off" "$TMP_ROOT/config-on" "$TMP_ROOT/config-bad"
: > "$TMP_ROOT/config-off/supervision-host-off"
: > "$TMP_ROOT/config-on/supervision-host-off"
: > "$TMP_ROOT/config-bad/supervision-host-off"
printf '# tiered scanning\nhot-seconds=600\n' > "$TMP_ROOT/config-on/status-scan-tiers"
printf 'hot-seconds=abc\nhot-seconds=0\nunknown-key=1\nnonsense line\n' > "$TMP_ROOT/config-bad/status-scan-tiers"

age_file() {  # <seconds-ago> <file>...
  local ago=$1
  shift
  perl -e 'my $t = time - shift; utime $t, $t, @ARGV or exit 1' "$ago" "$@" \
    || fail "could not age fixture files"
}

drain() {  # <state> <config> [drain args...] -> stdout of the drain
  local state=$1 config=$2
  shift 2
  FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" "$DRAIN" "$@" 2>/dev/null
}

# The per-file snapshot reader the batched one replaced, kept here as the
# behavioural oracle for the byte-identical comparison.
reference_snapshot() {  # <state>
  local state=$1
  bash -c '
    . "$1"
    state=$2
    exclude=$(status_scan_parent_channel_exclude "$state")
    for f in "$state"/*.status; do
      [ -e "$f" ] || continue
      [ "$f" = "$exclude" ] && continue
      [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
      task=$(basename "$f"); task="${task%.status}"
      size=$(_fm_status_file_size "$f") || exit 1
      size=${size//[[:space:]]/}
      ident=$(_fm_open_decisions_file_ident "$f") || exit 1
      case "$size" in ""|*[!0-9]*) exit 1 ;; esac
      [ -n "$ident" ] || exit 1
      printf "%s\t%s\t%s\n" "$task" "$size" "$ident" || exit 1
    done
  ' _ "$CLASSIFY" "$state"
}

new_snapshot() {  # <state>
  bash -c '. "$1"; status_presentation_snapshot "$2"' _ "$CLASSIFY" "$1"
}

test_batched_snapshot_matches_the_per_file_reader() {
  local dir state ref new
  dir=$(make_case snapshot-equivalence)
  state="$dir/state"

  ref=$(reference_snapshot "$state") || fail "reference snapshot failed on an empty state"
  new=$(new_snapshot "$state") || fail "batched snapshot failed on an empty state"
  [ -z "$ref" ] && [ -z "$new" ] || fail "an empty state produced snapshot rows: ref=[$ref] new=[$new]"

  printf 'working: a\n' > "$state/alpha.status"
  printf 'needs-decision [key=k]: b\nnote: c\n' > "$state/beta-2.status"
  : > "$state/empty.status"
  printf 'x\n' > "$state/target"
  ln -s "$state/target" "$state/linked.status"
  ln -s "$state/missing" "$state/dangling.status"
  mkdir "$state/dir.status"
  printf 'working: d\n' > "$state/.hidden.status"
  printf 'working: e\n' > "$state/task.with.dots.status"

  ref=$(reference_snapshot "$state") || fail "reference snapshot failed on the fixture"
  new=$(new_snapshot "$state") || fail "batched snapshot failed on the fixture"
  [ -n "$ref" ] || fail "setup error: the reference snapshot is empty"
  [ "$ref" = "$new" ] || fail "batched snapshot differs from the per-file reader:
ref:
$ref
new:
$new"
  pass "the batched snapshot is byte-identical to the per-file reader, row for row"
}

test_cursor_path_matches_dirname_and_basename() {
  local path ref new
  for path in /a/b/task.status a/task.status task.status /task.status '/a//b/task.status' './task.status'; do
    ref="$(dirname "$path")/.$(basename "$path" .status).open-decisions-cursor"
    new=$(bash -c '. "$1"; _fm_open_decisions_cursor_path "$2"' _ "$CLASSIFY" "$path")
    [ "$ref" = "$new" ] || fail "cursor path for $path: expected $ref, got $new"
  done
  pass "the cursor path from parameter expansion matches dirname and basename"
}

# A cold fixture: an old open decision whose bytes the first full drain
# presented, so its manifest row covers the whole file. The priming drain is a
# session-start full scan, so the tiered drains that follow are within the
# heartbeat sweep interval.
make_cold_decision_case() {  # <name> -> case dir
  local dir state
  dir=$(make_case "$1")
  state="$dir/state"
  printf 'needs-decision [key=pick]: choose the cold option\nnote: waiting\n' > "$state/cold.status"
  printf 'working: started\nnote: hot ping\n' > "$state/hot.status"
  drain "$state" "$TMP_ROOT/config-on" --full-status-scan > "$dir/prime.out" || fail "priming drain failed"
  grep -F 'cold [key=pick]' "$dir/prime.out" >/dev/null \
    || fail "setup error: the priming drain did not present the open decision: $(cat "$dir/prime.out")"
  age_file 7200 "$state/cold.status"
  printf '%s\n' "$dir"
}

test_off_path_scans_every_file() {
  local dir state out
  dir=$(make_cold_decision_case off-path)
  state="$dir/state"
  out="$dir/drain.out"
  drain "$state" "$TMP_ROOT/config-off" > "$out" || fail "off-path drain failed"
  grep -F 'cold [key=pick] needs-decision: choose the cold option' "$out" >/dev/null \
    || fail "without the config file an old open decision was not presented: $(cat "$out")"
  if grep -F 'STATUS SCAN' "$out" >/dev/null; then
    fail "without the config file the drain reported skipped files: $(cat "$out")"
  fi
  drain "$state" "$TMP_ROOT/config-off" --full-status-scan > "$dir/full.out" \
    || fail "off-path full drain failed"
  cmp -s "$out" "$dir/full.out" \
    || fail "without the config file --full-status-scan changed the output: $(diff "$out" "$dir/full.out")"
  pass "without config/status-scan-tiers every drain scans every file and --full-status-scan changes nothing"
}

test_on_path_skips_cold_until_heartbeat() {
  local dir state out
  dir=$(make_cold_decision_case on-path)
  state="$dir/state"
  out="$dir/drain.out"

  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "tiered drain failed"
  if grep -F 'cold [key=pick]' "$out" >/dev/null; then
    fail "an ordinary tiered drain rescanned a cold file: $(cat "$out")"
  fi
  grep -Fx 'STATUS SCAN: skipped 1 cold status file(s) on this wake; a drain scans every file at least every 600 s, and on a heartbeat wake or session start.' "$out" >/dev/null \
    || fail "a tiered drain that skipped a cold file did not say so: $(cat "$out")"

  append_wake "$state" heartbeat heartbeat "fleet review" || fail "could not queue a heartbeat"
  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "heartbeat drain failed"
  grep -F 'cold [key=pick] needs-decision: choose the cold option' "$out" >/dev/null \
    || fail "a heartbeat drain did not present the cold file's old open decision: $(cat "$out")"
  if grep -F 'STATUS SCAN' "$out" >/dev/null; then
    fail "a heartbeat drain reported skipped files: $(cat "$out")"
  fi

  drain "$state" "$TMP_ROOT/config-on" --full-status-scan > "$out" || fail "session-start drain failed"
  grep -F 'cold [key=pick] needs-decision: choose the cold option' "$out" >/dev/null \
    || fail "a session-start drain did not present the cold file's old open decision: $(cat "$out")"
  if grep -F 'note: waiting' "$out" >/dev/null; then
    fail "a full sweep after skipped drains replayed an already-presented note: $(cat "$out")"
  fi
  pass "a cold file's old open decision is skipped on ordinary wakes and presented on heartbeat and session start"
}

test_cold_file_that_gains_a_line_is_hot_next_drain() {
  local dir state out
  dir=$(make_cold_decision_case gains-line)
  state="$dir/state"
  out="$dir/drain.out"
  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "first tiered drain failed"
  grep -F 'STATUS SCAN: skipped 1' "$out" >/dev/null || fail "setup error: the file was not cold: $(cat "$out")"

  printf 'note: captain answered\n' >> "$state/cold.status"
  age_file 7200 "$state/cold.status"
  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "tiered drain after the append failed"
  grep -F 'cold note: captain answered' "$out" >/dev/null \
    || fail "an aged file with unpresented bytes was not scanned: $(cat "$out")"
  grep -F 'cold [key=pick] needs-decision: choose the cold option' "$out" >/dev/null \
    || fail "a file that became hot did not present its open decision: $(cat "$out")"
  if grep -F 'STATUS SCAN' "$out" >/dev/null; then
    fail "the drain reported a skipped file after the cold file became hot: $(cat "$out")"
  fi
  pass "a cold file that gains a line is hot on the next drain, whatever its age"
}

# Record the last full scan as <seconds-ago> old; state/.status-full-sweep-at
# is the drain's persisted sweep-time state (docs/configuration.md).
age_full_sweep() {  # <state> <seconds-ago>
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$1/.status-full-sweep-at" \
    || fail "could not age the recorded full sweep"
}

test_cold_file_is_rescanned_at_heartbeat_cadence() {
  local dir state out
  dir=$(make_cold_decision_case sweep-cadence)
  state="$dir/state"
  out="$dir/drain.out"

  age_full_sweep "$state" 500
  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "drain inside the sweep interval failed"
  if grep -F 'cold [key=pick]' "$out" >/dev/null; then
    fail "a drain 500 s after the last full scan rescanned a cold file: $(cat "$out")"
  fi
  grep -F 'STATUS SCAN: skipped 1' "$out" >/dev/null \
    || fail "a drain inside the sweep interval did not skip the cold file: $(cat "$out")"

  FM_HEARTBEAT=400 drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "drain with FM_HEARTBEAT=400 failed"
  grep -F 'cold [key=pick] needs-decision: choose the cold option' "$out" >/dev/null \
    || fail "with FM_HEARTBEAT=400 a drain 500 s after the last full scan hid the open decision: $(cat "$out")"

  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "drain after the sweep failed"
  grep -F 'STATUS SCAN: skipped 1' "$out" >/dev/null \
    || fail "the full scan did not record its time, so the next drain swept again: $(cat "$out")"

  age_full_sweep "$state" 700
  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "drain past the default interval failed"
  grep -F 'cold [key=pick] needs-decision: choose the cold option' "$out" >/dev/null \
    || fail "a drain 700 s after the last full scan hid the open decision: $(cat "$out")"
  if grep -F 'STATUS SCAN' "$out" >/dev/null; then
    fail "a drain past the sweep interval reported skipped files: $(cat "$out")"
  fi
  if grep -F 'note: waiting' "$out" >/dev/null; then
    fail "a timed full scan replayed an already-presented note: $(cat "$out")"
  fi
  pass "with no heartbeat wake a cold open decision is presented again once FM_HEARTBEAT seconds pass since the last full scan, and not before"
}

test_signal_wake_task_is_always_scanned() {
  local dir state out
  dir=$(make_cold_decision_case signal-forced)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" signal cold.status "status changed" || fail "could not queue a signal"
  drain "$state" "$TMP_ROOT/config-on" > "$out" || fail "signal drain failed"
  grep -F 'cold [key=pick] needs-decision: choose the cold option' "$out" >/dev/null \
    || fail "a task named by a presented signal wake was skipped: $(cat "$out")"
  pass "a task that a presented signal wake names is scanned even when cold"
}

test_malformed_config_keeps_the_defaults() {
  local dir state out
  dir=$(make_cold_decision_case malformed)
  state="$dir/state"
  out="$dir/drain.out"
  # 7200 s old is cold under the 3600 s default; 1800 s old is hot.
  drain "$state" "$TMP_ROOT/config-bad" > "$out" || fail "drain with a malformed config failed"
  grep -F 'STATUS SCAN: skipped 1' "$out" >/dev/null \
    || fail "a malformed config did not keep the default window and sweep: $(cat "$out")"
  age_file 1800 "$state/cold.status"
  drain "$state" "$TMP_ROOT/config-bad" > "$out" || fail "second drain with a malformed config failed"
  grep -F 'cold [key=pick]' "$out" >/dev/null \
    || fail "a file inside the default 3600 s window was treated as cold: $(cat "$out")"
  pass "a malformed config keeps hot-seconds=3600"
}

# Count every external command a drain starts, through PATH shims.
make_exec_shims() {  # <dir> <log>
  local dir=$1 log=$2 name real
  mkdir -p "$dir"
  for name in stat cat basename dirname perl awk wc tail head od tr rm mv cp ln mktemp date sed grep \
    sort uniq cut uname readlink ps kill chmod touch mkdir rmdir sleep env flock python3 jq git tmux \
    id hostname tee xargs find ls comm timeout gtimeout nohup mkfifo sha256sum shasum; do
    real=$(command -v "$name" 2>/dev/null) || continue
    case "$real" in /*) ;; *) continue ;; esac
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$name" "$log" "$real" > "$dir/$name"
    chmod +x "$dir/$name"
  done
}

make_fleet() {  # <state> <count> <hot-count>
  local state=$1 count=$2 hot=$3 i
  i=1
  while [ "$i" -le "$count" ]; do
    printf 'working: started %s\nnote: ping %s\n' "$i" "$i" > "$state/task$i.status"
    i=$((i + 1))
  done
  drain "$state" "$TMP_ROOT/config-on" --full-status-scan > /dev/null || fail "priming drain for the fleet failed"
  age_file 7200 "$state"/task*.status
  i=1
  while [ "$i" -le "$hot" ]; do
    printf 'note: fresh %s\n' "$i" >> "$state/task$i.status"
    i=$((i + 1))
  done
}

count_drain_execs() {  # <state> <config> -> exec count
  local state=$1 config=$2 shims log
  shims="$state/../shims"
  log="$state/../execs.log"
  make_exec_shims "$shims" "$log"
  : > "$log"
  PATH="$shims:$PATH" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" "$DRAIN" > /dev/null 2>&1 \
    || fail "counted drain failed"
  awk 'END { print NR }' "$log"
}

test_hot_drain_process_count_is_independent_of_file_count() {
  local small big small_count big_count off_small off_big
  small=$(make_case fleet-71)
  big=$(make_case fleet-81)
  make_fleet "$small/state" 71 10
  make_fleet "$big/state" 81 10
  small_count=$(count_drain_execs "$small/state" "$TMP_ROOT/config-on")
  big_count=$(count_drain_execs "$big/state" "$TMP_ROOT/config-on")
  [ "$small_count" -gt 0 ] || fail "setup error: the exec shims recorded nothing"
  [ "$small_count" -eq "$big_count" ] \
    || fail "a tiered drain started $small_count processes for 71 files and $big_count for 81, both with 10 hot"

  # The off path still scans every file, so its count grows with the fleet;
  # that divergence on two small fleets proves the shims see the per-file work
  # the tiered drain skips, without paying for a full scan of the large ones.
  small=$(make_case fleet-off-2)
  big=$(make_case fleet-off-6)
  make_fleet "$small/state" 2 0
  make_fleet "$big/state" 6 0
  off_small=$(count_drain_execs "$small/state" "$TMP_ROOT/config-off")
  off_big=$(count_drain_execs "$big/state" "$TMP_ROOT/config-off")
  [ "$off_big" -gt "$off_small" ] \
    || fail "setup error: the off path did not grow with the fleet ($off_small vs $off_big); the shims see no per-file work"
  pass "with 10 hot files a tiered drain starts $small_count processes for 71 or 81 files (full scan: $off_small for 2 files, $off_big for 6)"
}

test_batched_snapshot_matches_the_per_file_reader
test_cursor_path_matches_dirname_and_basename
test_off_path_scans_every_file
test_on_path_skips_cold_until_heartbeat
test_cold_file_that_gains_a_line_is_hot_next_drain
test_cold_file_is_rescanned_at_heartbeat_cadence
test_signal_wake_task_is_always_scanned
test_malformed_config_keeps_the_defaults
test_hot_drain_process_count_is_independent_of_file_count
