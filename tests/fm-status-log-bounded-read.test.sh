#!/usr/bin/env bash
# tests/fm-status-log-bounded-read.test.sh - bounded-cost proof for the per-task
# status-log reads in the supervision path.
#
# A long-lived monitoring lane legitimately produces a multi-megabyte
# append-only status log. The 2026-09 incident: several lanes crossed 2-5 MB and
# every per-task read that walked the whole file made the watcher's first poll,
# the wake drain, the fleet snapshot, and session start take minutes - windows
# where a firstmate turn could end with supervision off. The captain's standing
# rule is that firstmate's own monitoring never goes down, so every per-task
# read must be bounded by the bytes it actually needs, never by the log's
# lifetime size, without loosening a deadline or dropping a wake.
#
# The deterministic assertions here are the byte-count read probes the production
# code publishes (FM_STATUS_TAIL_READ_PROBE, FM_OPEN_DECISIONS_READ_PROBE), so a
# regression that re-reads the whole log fails on the recorded byte count rather
# than on a wall-clock sample. The wall-clock bounds exist only to fail a
# pathological regression loudly; each is env-overridable so a loaded box cannot
# turn them into a false failure.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-log-bounded-read-tests)

SYNTHETIC_TARGET_BYTES=${SYNTHETIC_TARGET_BYTES:-5242880}
LATEST_LINE_BOUND_SECS=${LATEST_LINE_BOUND_SECS:-1}
CREW_STATE_BOUND_SECS=${CREW_STATE_BOUND_SECS:-10}
FOLD_WARM_BOUND_SECS=${FOLD_WARM_BOUND_SECS:-1}
FOLD_COLD_BOUND_SECS=${FOLD_COLD_BOUND_SECS:-120}
# The real drain over a 5 MB log is a shell-side fold, so its wall time tracks
# the host's I/O rather than the code's complexity. Measured basis: 16.4s on a
# clean 2-CPU container (GNU coreutils) and 17.4s on the same container with
# uutils coreutils, but 90.4s on a 2-core GitHub runner, whose filesystem is
# roughly 5x slower for this workload. The bound is a regression tripwire, not a
# machine-speed certificate: a fold that fell back to re-reading the whole log
# per task would be orders of magnitude past this, not 2x. 180s keeps that
# tripwire meaningful while tolerating the slowest runner measured.
DRAIN_BOUND_SECS=${DRAIN_BOUND_SECS:-180}
# The bounded readers inspect at most the final 64 KiB; a regression that falls
# back to a whole-file scan records the whole log instead.
BOUNDED_READ_CEILING=${BOUNDED_READ_CEILING:-131072}

now_secs() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

under_bound() {  # <elapsed> <bound> <message>
  perl -e 'exit(($ARGV[0] < $ARGV[1]) ? 0 : 1)' -- "$1" "$2" || fail "$3"
}

# Smaller of two elapsed values, so a timing assertion can take the best of
# several rounds and stay honest under a concurrently loaded box.
min_secs() { perl -e 'printf "%.3f", ($ARGV[0] < $ARGV[1]) ? $ARGV[0] : $ARGV[1]' "$1" "$2"; }

file_bytes() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

# The byte count a probe recorded for <file> on its MOST RECENT call.
last_probe_bytes() {  # <probe-file> <file>
  awk -F '\t' -v f="$2" '$1 == f { b = $2 } END { print b + 0 }' "$1"
}

# Build a multi-megabyte append-only log of routine `working:` lines and one
# trailing captain-relevant line. The filler lines are long on purpose: the byte
# volume is what a whole-file scan must pay for, while folding a few hundred long
# lines stays cheap, so a correct bounded reader is fast and a regressed one is
# visibly slow without making the fixture itself expensive to fold.
build_big_status_log() {  # <file> <target-bytes> <trailing-line>
  local file=$1 target=$2 trailing=$3
  awk -v target="$target" -v trailing="$trailing" '
    BEGIN {
      unit = ""
      for (i = 0; i < 100; i++) unit = unit "routine-lane-progress-padding-"
      per = length(unit) + 1
      n = int(target / per) + 1
      for (j = 0; j < n; j++) printf "working: %s%06d\n", unit, j
      print trailing
    }
  ' > "$file"
}

test_latest_status_line_is_bounded_and_exact() {
  local dir status probe size line bytes elapsed best round

  dir=$(make_case latest-line)
  status="$dir/state/lane.status"
  probe="$dir/tail-probe.tsv"
  : > "$probe"

  build_big_status_log "$status" "$SYNTHETIC_TARGET_BYTES" \
    'paused [key=bounded-read]: idle until next tick at 22:00Z'
  size=$(file_bytes "$status")
  [ "$size" -ge 5000000 ] \
    || fail "test setup error: synthetic log is only $size bytes, not the intended multi-megabyte shape"

  best=999
  for round in 1 2 3; do
    elapsed=$(now_secs)
    line=$(FM_STATUS_TAIL_READ_PROBE="$probe" last_status_line "$status")
    elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
    best=$(min_secs "$best" "$elapsed")
  done

  [ "$line" = 'paused [key=bounded-read]: idle until next tick at 22:00Z' ] \
    || fail "the bounded latest-line read returned the wrong line: $line"
  under_bound "$best" "$LATEST_LINE_BOUND_SECS" \
    "the latest-line read of a $size-byte log took ${best}s, over the ${LATEST_LINE_BOUND_SECS}s bound"

  bytes=$(last_probe_bytes "$probe" "$status")
  [ "$bytes" -gt 0 ] || fail "the latest-line read recorded no bounded read at all"
  [ "$bytes" -le "$BOUNDED_READ_CEILING" ] \
    || fail "the latest-line read touched $bytes bytes of a $size-byte log (not bounded)"
  [ "$bytes" -lt "$size" ] \
    || fail "test setup error: the bounded read ($bytes) is not smaller than the log ($size)"

  pass "the latest status line is read from a bounded tail, under a stated bound, never the whole log"
}

test_crew_state_status_read_is_bounded() {
  local dir state id worktree status probe bytes elapsed out best round
  local small_status small_elapsed small_best big_elapsed delta

  dir=$(make_case crew-state-bounded)
  state="$dir/state"
  id=bounded-read-task
  worktree="$dir/worktree"
  mkdir -p "$worktree"
  git -C "$worktree" init -q
  git -C "$worktree" commit -q --allow-empty -m init

  status="$state/$id.status"
  small_status="$dir/small.status"
  build_big_status_log "$status" "$SYNTHETIC_TARGET_BYTES" \
    'paused [key=bounded-read]: idle until next tick at 22:00Z'
  printf 'paused [key=bounded-read]: idle until next tick at 22:00Z\n' > "$small_status"
  printf 'worktree=%s\nkind=scout\nharness=claude\nbackend=tmux\ntarget=fm-%s\n' \
    "$worktree" "$id" > "$state/$id.meta"

  probe="$dir/tail-probe.tsv"
  : > "$probe"

  # The absolute wall bound is deliberately generous: the process pays its own
  # startup and unrelated backend probes, and a concurrently loaded box must not
  # fail it. The DETERMINISTIC proof is the recorded read-probe byte count below,
  # and the log-size-independence proof is the delta against a tiny-log run.
  best=999
  for round in 1 2 3; do
    elapsed=$(now_secs)
    out=$(FM_STATE_OVERRIDE="$state" FM_STATUS_TAIL_READ_PROBE="$probe" \
      "$CREW_STATE" "$id" 2>/dev/null)
    elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
    best=$(min_secs "$best" "$elapsed")
  done

  [ -n "$out" ] || fail "fm-crew-state.sh produced no state line for a task with a large status log"
  case "$out" in
    'state: '*" · source: "*) ;;
    *) fail "fm-crew-state.sh produced a malformed state line: $out" ;;
  esac
  under_bound "$best" "$CREW_STATE_BOUND_SECS" \
    "fm-crew-state.sh over a $(file_bytes "$status")-byte status log took ${best}s, over the ${CREW_STATE_BOUND_SECS}s bound"

  bytes=$(last_probe_bytes "$probe" "$status")
  [ "$bytes" -gt 0 ] \
    || fail "fm-crew-state.sh did not read the status log through the bounded tail reader"
  [ "$bytes" -le "$BOUNDED_READ_CEILING" ] \
    || fail "fm-crew-state.sh read $bytes bytes of a $(file_bytes "$status")-byte status log (not bounded)"

  # The same invocation over a tiny log must not be materially faster: if the
  # status-log size drove the cost, the 5 MB run would be seconds slower. This is
  # the log-size-independence proof, robust to a loaded box because both runs
  # carry the same unrelated startup cost.
  small_best=999
  for round in 1 2 3; do
    elapsed=$(now_secs)
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_STATUS_OVERRIDE="$small_status" \
      "$CREW_STATE" "$id" >/dev/null 2>&1
    elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
    small_best=$(min_secs "$small_best" "$elapsed")
  done
  big_elapsed=$best
  small_elapsed=$small_best
  delta=$(perl -e 'printf "%.3f", $ARGV[0] - $ARGV[1]' "$big_elapsed" "$small_elapsed")
  under_bound "$delta" "$CREW_STATE_BOUND_SECS" \
    "a 5 MB status log added ${delta}s to fm-crew-state.sh over a tiny log (status-log size is driving the cost)"

  pass "fm-crew-state.sh reads the status log through a bounded tail that does not scale with log size"
}

# The drain's durable open-decision fold is the cursor-backed
# scan_open_decisions_incremental. Two properties must hold at multi-megabyte
# volume: the cold fold still surfaces a buried decision, and the warm fold reads
# only the bytes appended since its cursor.
test_drain_open_decision_fold_reads_only_appended_bytes() {
  local dir state status probe cold_open appended warm_open cold_bytes warm_bytes elapsed size round best

  dir=$(make_case drain-fold-bounded)
  state="$dir/state"
  status="$state/lane.status"
  probe="$dir/probe.tsv"
  : > "$probe"

  build_big_status_log "$status" "$SYNTHETIC_TARGET_BYTES" \
    'needs-decision [key=buried]: pick the bounded path'
  size=$(file_bytes "$status")
  [ "$size" -ge 5000000 ] \
    || fail "test setup error: synthetic log is only $size bytes, not the intended multi-megabyte shape"

  # Cold: no cursor exists, so the fold reads the whole log once and must
  # surface the buried decision.
  elapsed=$(now_secs)
  cold_open=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_open_decisions_incremental "$status")
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
  under_bound "$elapsed" "$FOLD_COLD_BOUND_SECS" \
    "the cold fold over a $size-byte log took ${elapsed}s, over the ${FOLD_COLD_BOUND_SECS}s bound"
  case "$cold_open" in
    *"buried"*"needs-decision"*) ;;
    *) fail "the cold fold did not surface the buried decision: $cold_open" ;;
  esac
  cold_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$cold_bytes" -ge "$size" ] \
    || fail "the cold fold recorded a $cold_bytes-byte read, not the whole $size-byte log"

  # Warm: one small append per round, so each round's fold does real bounded
  # work. Best-of-three defeats transient load on a concurrently busy box; the
  # recorded read-probe byte count is the deterministic proof either way.
  best=999
  for round in 1 2 3; do
    appended=$(printf 'needs-decision [key=late-%s]: appended round %s after the cold fold\n' "$round" "$round" \
      | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
    elapsed=$(now_secs)
    warm_open=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_open_decisions_incremental "$status")
    elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
    best=$(min_secs "$best" "$elapsed")
    warm_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$warm_bytes" = "$appended" ] \
      || fail "round $round read $warm_bytes bytes instead of only the $appended-byte append"
    case "$warm_open" in
      *"late-$round"*"needs-decision"*) ;;
      *) fail "round $round did not surface the appended decision: $warm_open" ;;
    esac
    case "$warm_open" in
      *"buried"*) ;;
      *) fail "round $round dropped the still-open buried decision" ;;
    esac
  done
  under_bound "$best" "$FOLD_WARM_BOUND_SECS" \
    "the warm fold over a $size-byte log took ${best}s, over the ${FOLD_WARM_BOUND_SECS}s bound"

  pass "the drain's open-decision fold is bounded by appended bytes at multi-megabyte volume"
}

# End-to-end: the real drain, over a multi-megabyte log, must surface the buried
# decision on its first run and stay bounded per task on the next.
test_real_drain_presents_a_buried_decision_from_a_multi_megabyte_log() {
  local dir state status probe out elapsed size

  dir=$(make_case drain-big-log)
  state="$dir/state"
  status="$state/lane.status"
  probe="$dir/probe.tsv"
  out="$dir/drain.out"
  : > "$probe"

  build_big_status_log "$status" "$SYNTHETIC_TARGET_BYTES" \
    'needs-decision [key=buried]: pick the bounded path'
  size=$(file_bytes "$status")
  : > "$state/.wake-queue"

  elapsed=$(now_secs)
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "the first drain over a $size-byte log failed"
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
  under_bound "$elapsed" "$DRAIN_BOUND_SECS" \
    "the first drain over a $size-byte log took ${elapsed}s, over the ${DRAIN_BOUND_SECS}s bound"
  grep -F 'lane' "$out" | grep -F '[key=buried]' | grep -F 'pick the bounded path' >/dev/null \
    || fail "the first drain did not present the buried decision: $(command cat "$out")"

  # A second drain, with the cursors warm and only one small append, must read
  # only that append and stay under the per-task bound.
  appended=$(printf 'needs-decision [key=late]: one late decision after the first drain\n' \
    | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  : > "$probe"
  elapsed=$(now_secs)
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "the second drain over a $size-byte log failed"
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
  under_bound "$elapsed" "$DRAIN_BOUND_SECS" \
    "the second drain over a $size-byte log took ${elapsed}s, over the ${DRAIN_BOUND_SECS}s bound"
  grep -F 'lane' "$out" | grep -F '[key=late]' >/dev/null \
    || fail "the second drain did not present the appended decision"
  [ "$(last_probe_bytes "$probe" "$status")" = "$appended" ] \
    || fail "the second drain folded $(last_probe_bytes "$probe" "$status") bytes instead of only the $appended-byte append"

  pass "the real drain presents a buried decision from a multi-megabyte log with a bounded per-task fold"
}

# The fleet snapshot folds each task's open set read-only against the live
# status log, and the watcher runs that snapshot under a timed bound that
# kills the whole process group at the deadline. A fold killed mid-read must
# not leave its scratch chunk in the drain-owned state dir, so the read-only
# caller points the fold at a scratch dir it owns and cleans.
test_read_only_fold_keeps_scratch_out_of_state_dir() {
  local dir state status scratch reader cursor open pid waited leaked

  dir=$(make_case readonly-fold-scratch)
  state="$dir/state"
  status="$state/lane.status"
  scratch="$dir/scratch"
  cursor="$state/.lane.open-decisions-cursor"
  mkdir -p "$scratch"
  printf 'needs-decision [key=buried]: pick the bounded path\n' > "$status"

  # A completed read-only fold returns the open set and leaves the state dir
  # holding nothing but the status log: no cursor, no scratch.
  open=$(FM_OPEN_DECISIONS_READONLY=1 FM_OPEN_DECISIONS_SCRATCH_DIR="$scratch" \
    status_open_decisions_incremental "$status")
  case "$open" in
    *"buried"*"needs-decision"*) ;;
    *) fail "the read-only fold did not surface the open decision: $open" ;;
  esac
  [ ! -e "$cursor" ] || fail "the read-only fold wrote the drain-owned cursor"
  leaked=$(find "$state" -mindepth 1 ! -name lane.status)
  [ -z "$leaked" ] || fail "a completed read-only fold left files in the state dir: $leaked"
  leaked=$(find "$scratch" -mindepth 1)
  [ -z "$leaked" ] || fail "a completed read-only fold left its scratch chunk behind: $leaked"

  # A span reader that never finishes stands in for a fold caught mid-read at
  # the snapshot's deadline; the scratch chunk it is writing must already be
  # in the caller-owned scratch dir, not beside the cursor.
  reader="$dir/slow-reader.sh"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf 'needs-decision [key=partial]: a fold caught mid-read\n'
exec sleep 600
SH
  chmod +x "$reader"
  FM_STATUS_SPAN_READER="$reader" FM_OPEN_DECISIONS_READONLY=1 \
    FM_OPEN_DECISIONS_SCRATCH_DIR="$scratch" \
    status_open_decisions_incremental "$status" > /dev/null 2>&1 &
  pid=$!
  # The chunk appears as soon as the fold opens its span read, but a loaded
  # host can delay that background subshell by well over ten seconds; wait on a
  # generous wall-clock deadline (the stub reader sleeps longer than this) so
  # host load cannot expire the wait before the chunk exists.
  waited=$SECONDS
  while [ -z "$(find "$scratch" -name '*.read.*' 2>/dev/null)" ] \
    && [ -z "$(find "$state" -name '*.read.*' 2>/dev/null)" ] \
    && [ $((SECONDS - waited)) -lt 120 ]; do
    sleep 0.2
  done
  leaked=$(find "$state" -name '*.read.*')
  pkill -P "$pid" 2>/dev/null || :
  kill -KILL "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  [ -z "$leaked" ] \
    || fail "the read-only fold wrote its scratch chunk into the drain-owned state dir: $leaked"
  [ -n "$(find "$scratch" -name '*.read.*')" ] \
    || fail "the read-only fold never wrote its scratch chunk into the caller-owned scratch dir"
  [ ! -e "$cursor" ] || fail "the killed read-only fold wrote the drain-owned cursor"

  pass "the snapshot's read-only fold keeps its scratch chunk out of the drain-owned state dir"
}

# The snapshot bounds its read-only fold at the byte size of the status copy it
# captured, while the drain's cursor may already have folded the live log past
# that point. A cursor ahead of the capture must never lend the snapshot a
# transition the task appended after the capture, in either direction: a new
# decision must not appear, and a post-capture close must not hide a decision
# that was open in the captured observation.
test_captured_end_fold_refolds_when_cursor_is_ahead_of_capture() {
  local dir state status scratch cursor captured_end open cursor_before cursor_after

  dir=$(make_case captured-end-refold)
  state="$dir/state"
  status="$state/lane.status"
  scratch="$dir/scratch"
  cursor="$state/.lane.open-decisions-cursor"
  mkdir -p "$scratch"

  # Direction 1: the capture saw no decision; one lands after it, and the drain
  # folds the whole live log, moving its cursor past the captured end.
  printf 'working: captured state\n' > "$status"
  captured_end=$(file_bytes "$status")
  printf 'needs-decision [key=late]: appended after capture\n' >> "$status"
  status_open_decisions_incremental "$status" > /dev/null \
    || fail "the drain fold did not complete"
  [ -f "$cursor" ] || fail "the drain fold did not persist its cursor"
  cursor_before=$(cat "$cursor")
  open=$(FM_OPEN_DECISIONS_READONLY=1 FM_OPEN_DECISIONS_SCRATCH_DIR="$scratch" \
    status_open_decisions_incremental "$status" "$captured_end")
  [ -z "$open" ] \
    || fail "a cursor ahead of the capture leaked a post-capture decision into the captured fold: $open"
  cursor_after=$(cat "$cursor")
  [ "$cursor_after" = "$cursor_before" ] \
    || fail "the read-only captured fold moved the drain-owned cursor"

  # Direction 2: the capture saw an open decision; the task resolves it after
  # the capture and the drain folds that close. The captured observation still
  # holds the decision open.
  printf 'needs-decision [key=held]: pick the bounded path\n' > "$status"
  rm -f "$cursor"
  captured_end=$(file_bytes "$status")
  printf 'resolved [key=held]: picked after capture\n' >> "$status"
  open=$(status_open_decisions_incremental "$status") \
    || fail "the drain fold did not complete"
  [ -z "$open" ] || fail "the drain fold did not fold the post-capture close: $open"
  open=$(FM_OPEN_DECISIONS_READONLY=1 FM_OPEN_DECISIONS_SCRATCH_DIR="$scratch" \
    status_open_decisions_incremental "$status" "$captured_end")
  case "$open" in
    "held"$'\t'"needs-decision"$'\t'*) ;;
    *) fail "a cursor ahead of the capture hid a decision that was open at capture: '$open'" ;;
  esac
  [ -z "$(find "$scratch" -mindepth 1)" ] \
    || fail "the captured fold left its scratch chunk behind: $(find "$scratch" -mindepth 1)"

  pass "a captured-end fold refolds the captured prefix when the drain cursor is ahead of the capture"
}

test_latest_status_line_is_bounded_and_exact
test_crew_state_status_read_is_bounded
test_read_only_fold_keeps_scratch_out_of_state_dir
test_captured_end_fold_refolds_when_cursor_is_ahead_of_capture
test_drain_open_decision_fold_reads_only_appended_bytes
test_real_drain_presents_a_buried_decision_from_a_multi_megabyte_log
