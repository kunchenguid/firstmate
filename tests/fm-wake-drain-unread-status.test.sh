#!/usr/bin/env bash
# tests/fm-wake-drain-unread-status.test.sh - drain must surface every still-
# unread informational status line since the last presentation, not only the
# newest line. This is a portable tests/ regression: the drain decides WHICH
# status lines to surface, so the real drain/classify functions over crafted
# status logs are sufficient (no harness). The incident this pins: a `note:`
# answer immediately followed by a routine `note:` was buried because the
# annotation kept only the newest line and `note:` never folds into OPEN
# DECISIONS.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-unread-status-tests)

# Establish the durable last-presentation cursor by draining once over a
# bootstrap line so later appends are "new since last drain".
prime_cursor() {  # <state> <status-file>
  local state=$1 status=$2
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the unread cursor"
}

test_incident_note_answer_buried_under_routine_note_surfaces_both() {
  local dir state out status
  dir=$(make_case incident-buried-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task1.status"
  register_task_fixture "$state" "task1"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on the incident shape"

  grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || fail "the incident shape produced no UNREAD STATUS section: $(cat "$out")"
  grep -F 'task1 note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the buried answer note was not surfaced: $(cat "$out")"
  grep -F 'task1 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the newest routine note was dropped while surfacing the answer: $(cat "$out")"
  pass "a note: answer buried under a later routine note: is surfaced with both lines"
}

test_already_presented_notes_are_not_replayed() {
  local dir state out status
  dir=$(make_case no-replay)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task2.status"
  register_task_fixture "$state" "task2"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain of unread notes failed"
  grep -F 'captain said use REST not RPC' "$out" >/dev/null \
    || fail "setup error: first drain did not surface the answer note"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after presentation failed"
  if grep -F 'captain said use REST not RPC' "$out" >/dev/null; then
    fail "an already-presented answer note was replayed as new: $(cat "$out")"
  fi
  if grep -F 're-read acknowledgement' "$out" >/dev/null; then
    fail "an already-presented routine note was replayed as new: $(cat "$out")"
  fi
  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "the second drain reprinted an UNREAD STATUS section with no new lines: $(cat "$out")"
  fi
  pass "already-presented note: lines are not re-surfaced on the next drain"
}

test_brand_new_note_after_presentation_is_surfaced() {
  local dir state out status
  dir=$(make_case brand-new-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task3.status"
  register_task_fixture "$state" "task3"
  prime_cursor "$state" "$status"

  printf 'note: first answer\n' >> "$status"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the first note failed"
  grep -F 'task3 note: first answer' "$out" >/dev/null \
    || fail "setup error: first note was not presented"

  printf 'note: follow-up after ack\n' >> "$status"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the brand-new note failed"
  grep -F 'task3 note: follow-up after ack' "$out" >/dev/null \
    || fail "a brand-new note after presentation was not surfaced: $(cat "$out")"
  if grep -F 'task3 note: first answer' "$out" >/dev/null; then
    fail "the already-presented first note was replayed next to the new one: $(cat "$out")"
  fi
  pass "a brand-new note: after presentation is surfaced without replaying handled lines"
}

test_signal_annotation_surfaces_every_unread_note_not_only_the_newest() {
  local dir state out err status
  dir=$(make_case signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  status="$state/task4.status"
  register_task_fixture "$state" "task4"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  append_wake "$state" signal task4.status "signal: task4.status" \
    || fail "queueing the incident-shape status signal failed"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "signal drain failed on the incident shape"

  grep -F 'unread wake-EVENT since last drain, not current state: task4.status: note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the signal annotation dropped the buried answer note: $(cat "$out")"
  grep -F 'latest wake-EVENT observed at drain, not current state: task4.status: note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the signal annotation dropped the newest routine note: $(cat "$out")"
  grep "$(printf '\tsignal\ttask4.status\t')" "$out" >/dev/null \
    || fail "surfacing unread notes hid the authoritative raw wake row"
  pass "a queued status signal annotates every unread note, not only the newest"
}

test_decision_resolution_surfaces_once() {
  local dir state out status
  dir=$(make_case decision-resolution)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task5.status"
  register_task_fixture "$state" "task5"
  prime_cursor "$state" "$status"

  printf 'blocked [key=release-approval]: approval required before shipping\n' >> "$status"
  append_wake "$state" signal task5.status "signal: task5.status" \
    || fail "queueing the decision request signal failed"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging the decision request"
  {
    printf 'resolved [key=release-approval]: approval recorded via status\n'
    printf 'note: re-read acknowledgement\n'
  } >> "$status"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a decision resolution"

  grep -F 'approval recorded via status' "$out" >/dev/null \
    || fail "the decision resolution was buried under the later note: $(cat "$out")"
  grep -F 'task5 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the trailing note was not surfaced with the decision resolution: $(cat "$out")"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the decision resolution did not close its open decision: $(cat "$out")"
  fi

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after decision presentation failed"
  if grep -F 'approval recorded via status' "$out" >/dev/null; then
    fail "an already-presented decision resolution was replayed: $(cat "$out")"
  fi
  pass "a decision resolution buried under a later note surfaces once and closes OPEN DECISIONS"
}

test_unread_output_over_cap_remains_recoverable() {
  local dir state out status i payload
  dir=$(make_case unread-over-cap)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-cap.status"
  register_task_fixture "$state" "task-cap"
  prime_cursor "$state" "$status"
  payload=$(printf '%0180d' 0)
  i=1
  while [ "$i" -le 30 ]; do
    printf 'note: overflow-%02d %s\n' "$i" "$payload" >> "$status"
    i=$((i + 1))
  done

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed for unread output over the former cap"
  grep -F 'task-cap note: overflow-01' "$out" >/dev/null \
    || fail "the first over-cap note was not surfaced"
  grep -F 'task-cap note: overflow-30' "$out" >/dev/null \
    || fail "a later note vanished behind the unread byte cap: $(cat "$out")"
  if grep -F 'more omitted' "$out" >/dev/null; then
    fail "the unread section still omitted complete lines: $(cat "$out")"
  fi
  pass "unread status over the former byte cap preserves every line"
}

test_snapshot_does_not_ack_a_later_append() {
  local dir state status first second
  dir=$(make_case snapshot-append)
  state="$dir/state"
  status="$state/task-race.status"
  register_task_fixture "$state" "task-race"
  prime_cursor "$state" "$status"
  printf 'note: included in presentation snapshot\n' >> "$status"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    snapshot=$(status_presentation_snapshot "$STATE")
    scan_unread_surface_snapshot "$STATE" "$snapshot" > "$2"
    printf "note: appended after presentation snapshot\n" >> "$STATE/task-race.status"
    scan_open_decisions_snapshot "$STATE" "$snapshot" >/dev/null
    status_commit_presentation_snapshot "$STATE" "$snapshot"
    scan_unread_surface_lines "$STATE" > "$3"
  ' _ "$ROOT" "$dir/first" "$dir/second" || fail "snapshot race exercise failed"
  first=$(cat "$dir/first")
  second=$(cat "$dir/second")
  case "$first" in *'included in presentation snapshot'*) ;; *) fail "snapshot omitted the line it captured: $first" ;; esac
  case "$first" in *'appended after presentation snapshot'*) fail "snapshot read beyond its endpoint: $first" ;; esac
  case "$second" in *'appended after presentation snapshot'*) ;; *) fail "fold advancement swallowed a post-snapshot append: $second" ;; esac
  case "$second" in *'included in presentation snapshot'*) fail "the next scan replayed a presented line: $second" ;; esac
  pass "presentation cursor advances only through its captured endpoint"
}

test_retired_task_id_starts_new_status_unread() {
  local dir state out offset event old_ident
  dir=$(make_case retired-task-reuse)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'note: old reused-task history\n' > "$state/reused.status"
  register_task_fixture "$state" "reused"
  printf 'note: stable neighboring history\n' > "$state/neighbor.status"
  register_task_fixture "$state" "neighbor"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging pre-retirement histories"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    _fm_open_decisions_file_ident "$STATE/reused.status" > "$2"
    printf "40@$(cat "$2")" > "$(status_signal_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_heartbeat_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_daemon_seen_marker_path "$STATE" reused)"
    status_retire_presentation_task "$STATE" reused || exit 1
    for marker in \
      "$(status_signal_seen_marker_path "$STATE" reused)" \
      "$(status_heartbeat_seen_marker_path "$STATE" reused)" \
      "$(status_daemon_seen_marker_path "$STATE" reused)"; do
      [ ! -e "$marker" ] && [ ! -L "$marker" ] || exit 1
    done
  ' _ "$ROOT" "$dir/old-ident" || fail "retiring the reused task presentation state failed"
  printf 'blocked: release host unavailable\nworking: routine padding after the reused task started again\nnote: first event from reused task id\n' \
    > "$state/reused.status"
  register_task_fixture "$state" "reused"
  old_ident=$(cat "$dir/old-ident")
  printf '40@%s' "$old_ident" > "$state/.seen-reused_status"
  offset=$(bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    fm_wake_signal_seen_size "$2" "$2/reused.status"
  ' _ "$ROOT" "$state")
  [ "$offset" = 0 ] || fail "a retired file identity restored a stale offset after task reuse"
  event=$(bash -c '
    . "$1/bin/fm-classify-lib.sh"
    status_span_first_actionable "$2/reused.status" "$3"
  ' _ "$ROOT" "$state" "$offset")
  [ "$event" = 'blocked: release host unavailable' ] \
    || fail "retired supervision offsets hid the replacement task blocker: $event"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after reusing a retired task id"
  grep -F 'reused note: first event from reused task id' "$out" >/dev/null \
    || fail "the retired manifest row skipped the new task prefix: $(cat "$out")"
  if grep -F 'stable neighboring history' "$out" >/dev/null; then
    fail "retiring one task replayed a neighboring task's handled history: $(cat "$out")"
  fi
  pass "a reused task id starts its replacement status log unread at byte zero"
}

test_settled_retirement_refuses_unread_and_open_status_then_removes_presented_history() {
  local dir state status err
  dir=$(make_case settled-retirement)
  state="$dir/state"
  err="$dir/retire.err"

  status="$state/unread.status"
  register_task_fixture "$state" "unread"
  prime_cursor "$state" "$status"
  printf 'note: not yet presented\n' >> "$status"
  if FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    status_retire_presentation_task "$2" unread --require-settled
  ' _ "$ROOT" "$state" 2> "$err"; then
    fail "settled retirement removed a status log with unread bytes"
  fi
  grep -F 'has unread status bytes' "$err" >/dev/null \
    || fail "unread retirement refusal was not explicit: $(cat "$err")"
  [ -f "$status" ] || fail "unread retirement refusal did not preserve the status log"

  status="$state/decision.status"
  register_task_fixture "$state" "decision"
  printf 'needs-decision [key=delivery]: choose destination\n' > "$status"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while presenting the open-decision fixture"
  if FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    status_retire_presentation_task "$2" decision --require-settled
  ' _ "$ROOT" "$state" 2> "$err"; then
    fail "settled retirement removed a status log with an open decision"
  fi
  grep -F 'has an open status decision' "$err" >/dev/null \
    || fail "open-decision retirement refusal was not explicit: $(cat "$err")"
  [ -f "$status" ] || fail "open-decision retirement refusal did not preserve the status log"

  status="$state/settled.status"
  register_task_fixture "$state" "settled"
  prime_cursor "$state" "$status"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    status_retire_presentation_task "$2" settled --require-settled
  ' _ "$ROOT" "$state" || fail "settled retirement refused fully presented status history"
  [ ! -e "$status" ] && [ ! -L "$status" ] \
    || fail "settled retirement retained fully presented status history"
  if [ -f "$state/.status-presentation-cursor" ]; then
    awk -F '\t' '$1 == "settled" { found=1 } END { exit found ? 0 : 1 }' \
      "$state/.status-presentation-cursor" >/dev/null \
      && fail "settled retirement retained the task's presentation manifest row"
  fi
  pass "settled retirement preserves unread/open status and removes only fully presented closed history"
}

test_settled_retirement_refuses_orphan_decision_cursor() {
  local dir state cursor err rc=0
  dir=$(make_case orphan-decision-cursor)
  state="$dir/state"
  cursor="$state/.orphan.open-decisions-cursor"
  err="$dir/retire.err"
  printf 'v5\t0\torphan:1:1\ndelivery\tneeds-decision\tchoose destination\n' >"$cursor"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    status_retire_presentation_task "$2" orphan --require-settled
  ' _ "$ROOT" "$state" 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'settled retirement erased a cursor whose status log was missing'
  assert_grep 'status is missing while its decision cursor remains' "$err" \
    'orphan decision-cursor refusal was not explicit'
  assert_present "$cursor" 'orphan decision cursor was removed'
  pass 'settled retirement preserves an orphan decision cursor instead of inferring settlement'
}

test_status_append_serializes_with_retirement() {
  local dir state status reader trigger i
  dir=$(make_case append-retire-race)
  state="$dir/state"
  status="$state/racing.status"
  register_task_fixture "$state" "racing"
  trigger="$dir/append-started"
  prime_cursor "$state" "$status"
  reader="$dir/size-reader"
  cat >"$reader" <<'SH'
#!/usr/bin/env bash
count_file=${FM_STATUS_RACE_COUNT:?}
count=$(cat "$count_file" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "$count" -eq 2 ]; then
  FM_STATE_OVERRIDE=${FM_STATUS_RACE_STATE:?} \
    "${FM_STATUS_RACE_ROOT:?}/bin/fm-status-append.sh" racing \
      'note: concurrent append survives retirement' \
      > /dev/null 2>"${FM_STATUS_RACE_TRIGGER:?}.err" &
  : >"${FM_STATUS_RACE_TRIGGER:?}"
  sleep 0.2
fi
wc -c <"$1"
SH
  chmod +x "$reader"
  : >"$dir/count"

  FM_STATUS_SIZE_READER="$reader" FM_STATUS_RACE_COUNT="$dir/count" \
    FM_STATUS_RACE_STATE="$state" FM_STATUS_RACE_ROOT="$ROOT" FM_STATUS_RACE_TRIGGER="$trigger" \
    FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-classify-lib.sh"
      status_retire_presentation_task "$2" racing --require-settled
    ' _ "$ROOT" "$state" || fail 'retirement failed while a serialized writer waited'
  i=0
  while ! grep -F 'concurrent append survives retirement' "$status" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  assert_present "$trigger" 'race fixture did not reach the append window'
  assert_grep 'concurrent append survives retirement' "$status" \
    'serialized append was lost when retirement removed the prior status log'
  [ "$(bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"; status_presentation_cursor_offset "$2"' _ "$ROOT" "$status")" = 0 ] \
    || fail 'replacement status inherited the retired file presentation cursor'
  pass 'status append waits for retirement and becomes a fresh unread log instead of being lost'
}

test_weak_identity_still_presents_and_advances() {
  local dir state out second reader
  dir=$(make_case weak-identity); state="$dir/state"
  out="$dir/first.out"; second="$dir/second.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nprintf "weak:7:8"\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision [key=release]: choose target\nnote: release context attached\n' > "$state/weak.status"
  register_task_fixture "$state" "weak"
  FM_STATUS_IDENTITY_READER="$reader" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed with the platform-strength fallback identity"
  grep -F 'weak [key=release] needs-decision: choose target' "$out" >/dev/null \
    || fail "weak identity omitted OPEN DECISIONS: $(cat "$out")"
  grep -F 'weak note: release context attached' "$out" >/dev/null \
    || fail "weak identity omitted unread status: $(cat "$out")"
  FM_STATUS_IDENTITY_READER="$reader" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" \
    || fail "second drain failed with the platform-strength fallback identity"
  grep -F 'release context attached' "$second" >/dev/null \
    && fail "weak identity did not advance the presented-status cursor"
  pass "fallback identity still presents and advances status state"
}

test_snapshot_failure_is_visible() {
  local dir state out reader
  dir=$(make_case snapshot-failure); state="$dir/state"; out="$dir/drain.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision: choose target\n' > "$state/fail.status"
  register_task_fixture "$state" "fail"
  FM_STATUS_IDENTITY_READER="$reader" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain aborted instead of reporting its incomplete status surface"
  grep -F 'STATUS PRESENTATION INCOMPLETE:' "$out" >/dev/null \
    || fail "snapshot failure produced a silently incomplete drain: $(cat "$out")"
  pass "snapshot failures are reported visibly"
}

test_warm_manifest_context_is_reused_per_presentation() {
  local dir state home out probe i task context_reads cursor_reads
  dir=$(make_case one-manifest-parse); state="$dir/state"; out="$dir/drain.out"; probe="$dir/manifest-reads"
  home="$dir/home"; mkdir -p "$home/data"
  i=1
  while [ "$i" -le 20 ]; do
    task=$(printf 'reuse-%02d' "$i")
    register_task_fixture "$state" "$task"
    printf 'note: bootstrap %s\n' "$task" > "$state/$task.status"
    i=$((i + 1))
  done
  HOME="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "bootstrap drain failed while creating the warm cursor manifest"
  i=1
  while [ "$i" -le 20 ]; do
    task=$(printf 'reuse-%02d' "$i")
    printf 'note: new %s\n' "$task" >> "$state/$task.status"
    i=$((i + 1))
  done

  FM_STATUS_MANIFEST_READ_PROBE="$probe" HOME="$home" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "instrumented warm-manifest drain failed"
  context_reads=$(awk -F '\t' '$1 == "context" { count++ } END { print count + 0 }' "$probe")
  cursor_reads=$(awk -F '\t' '$1 == "cursor" { count++ } END { print count + 0 }' "$probe")
  [ "$context_reads" -eq 1 ] && [ "$cursor_reads" -eq 0 ] \
    || fail "one presentation used $context_reads context reads and $cursor_reads standalone cursor reads: $(cat "$probe")"
  grep -F 'reuse-01 note: new reuse-01' "$out" >/dev/null \
    || fail "context reuse lost the first unread note: $(cat "$out")"
  grep -F 'reuse-20 note: new reuse-20' "$out" >/dev/null \
    || fail "context reuse lost the last unread note: $(cat "$out")"
  pass "one warm presentation reuses one validated cursor context and preserves fleet output"
}

test_queued_signals_reuse_the_presentation_context() {
  local dir state home out probe i task context_reads cursor_reads
  dir=$(make_case queued-signal-context); state="$dir/state"; home="$dir/home"
  out="$dir/drain.out"; probe="$dir/manifest-reads"; mkdir -p "$home/data"
  i=1
  while [ "$i" -le 12 ]; do
    task=$(printf 'queued-%02d' "$i")
    register_task_fixture "$state" "$task"
    printf 'note: bootstrap %s\n' "$task" > "$state/$task.status"
    i=$((i + 1))
  done
  HOME="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "bootstrap drain failed while creating the queued-signal manifest"
  i=1
  while [ "$i" -le 12 ]; do
    task=$(printf 'queued-%02d' "$i")
    printf 'working: queued update %s\n' "$task" >> "$state/$task.status"
    append_wake "$state" signal "$task.status" "signal: $task.status" \
      || fail "could not queue the $task signal"
    i=$((i + 1))
  done

  FM_STATUS_MANIFEST_READ_PROBE="$probe" HOME="$home" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "instrumented queued-signal drain failed"
  context_reads=$(awk -F '\t' '$1 == "context" { count++ } END { print count + 0 }' "$probe")
  cursor_reads=$(awk -F '\t' '$1 == "cursor" { count++ } END { print count + 0 }' "$probe")
  [ "$context_reads" -eq 1 ] && [ "$cursor_reads" -eq 0 ] \
    || fail "queued annotations used $context_reads context reads and $cursor_reads standalone cursor reads: $(cat "$probe")"
  grep -F 'queued-01.status: working: queued update queued-01' "$out" >/dev/null \
    || fail "queued context reuse lost the first signal annotation: $(cat "$out")"
  grep -F 'queued-12.status: working: queued update queued-12' "$out" >/dev/null \
    || fail "queued context reuse lost the last signal annotation: $(cat "$out")"
  pass "queued signal annotations reuse one validated presentation context"
}

test_queue_rows_without_a_status_snapshot_stay_valid() {
  local dir state home out err
  dir=$(make_case queued-without-status); state="$dir/state"; home="$dir/home"
  out="$dir/drain.out"; err="$dir/drain.err"; mkdir -p "$home/data"
  append_wake "$state" signal missing.status 'signal: missing.status' \
    || fail "could not queue the missing-status signal"

  HOME="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" > "$out" 2> "$err" \
    || fail "queue-only presentation failed without a status snapshot: $(cat "$err")"
  grep -F 'signal' "$out" >/dev/null \
    || fail "queue-only presentation lost its durable wake row: $(cat "$out")"
  grep -F 'unbound variable' "$err" >/dev/null \
    && fail "queue-only presentation referenced an uninitialized context: $(cat "$err")"
  pass "queue rows remain presentable when no status snapshot exists"
}

test_duplicate_manifest_row_refuses_without_advancing() {
  local dir state home out manifest original duplicate
  dir=$(make_case duplicate-manifest); state="$dir/state"; out="$dir/drain.out"
  home="$dir/home"; mkdir -p "$home/data"
  printf 'note: bootstrap duplicate fixture\n' > "$state/duplicate.status"
  register_task_fixture "$state" "duplicate"
  HOME="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "bootstrap drain failed while creating the duplicate-row fixture"
  manifest="$state/.status-presentation-cursor"
  original=$(cat "$manifest")
  duplicate=${original%%$'\n'*}
  printf '%s\n' "$duplicate" >> "$manifest"
  printf 'note: must remain unread after refusal\n' >> "$state/duplicate.status"
  register_task_fixture "$state" "duplicate"

  HOME="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "duplicate-row refusal changed the top-level empty-queue compatibility exit"
  grep -F 'STATUS PRESENTATION INCOMPLETE: status cursor manifest could not be read safely.' "$out" >/dev/null \
    || fail "duplicate cursor row did not fail closed visibly: $(cat "$out")"
  [ "$(awk -F '\t' '$1 == "duplicate" { count++ } END { print count + 0 }' "$manifest")" -eq 2 ] \
    || fail "refused duplicate manifest was unexpectedly replaced"
  pass "a duplicate cursor row refuses presentation without advancing its receipt"
}

test_legacy_three_column_manifest_migrates() {
  local dir state home out manifest task ident presented fields
  dir=$(make_case legacy-three-column); state="$dir/state"; home="$dir/home"
  out="$dir/drain.out"; manifest="$state/.status-presentation-cursor"; mkdir -p "$home/data"
  task=legacy
  register_task_fixture "$state" "$task"
  printf 'note: already presented\nnote: newly unread\n' > "$state/$task.status"
  ident=$(FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-classify-lib.sh"
    _fm_open_decisions_file_ident "$2"
  ' _ "$ROOT" "$state/$task.status") || fail "could not identify the legacy status fixture"
  presented=$(printf 'note: already presented\n' | wc -c | tr -d '[:space:]')
  printf '%s\t%s\t%s\n' "$task" "$ident" "$presented" > "$manifest"

  HOME="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" > "$out" || fail "drain rejected a legacy three-column cursor manifest"
  grep -F 'legacy note: newly unread' "$out" >/dev/null \
    || fail "legacy cursor migration lost the unread line: $(cat "$out")"
  grep -F 'already presented' "$out" >/dev/null \
    && fail "legacy cursor migration replayed an already-presented line: $(cat "$out")"
  fields=$(awk -F '\t' '$1 == "legacy" { print NF }' "$manifest")
  [ "$fields" = 4 ] \
    || fail "legacy cursor row was not migrated to the four-column format: $(cat "$manifest")"
  pass "a legacy three-column cursor is reused and migrated on commit"
}

test_open_decisions_fold_is_unchanged() {
  local dir state out
  dir=$(make_case open-decisions-regression)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task6.status"
  register_task_fixture "$state" "task6"
  printf 'working: continuing other work\n' >> "$state/task6.status"
  register_task_fixture "$state" "task6"
  printf 'note: re-read acknowledgement\n' >> "$state/task6.status"
  register_task_fixture "$state" "task6"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried needs-decision plus a note"

  grep -F 'task6 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "OPEN DECISIONS no longer surfaces a buried needs-decision: $(cat "$out")"
  grep -F 'task6 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the unread note was not surfaced alongside the still-open decision: $(cat "$out")"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "OPEN DECISIONS lost its answerer-closes hint"

  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task6.status"
  register_task_fixture "$state" "task6"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving the keyed decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  if grep -F 'pick REST or RPC' "$out" >/dev/null; then
    fail "a resolved decision leaked back through the unread surface: $(cat "$out")"
  fi
  pass "OPEN DECISIONS still folds needs-decision/blocked independently of unread notes"
}

test_empty_queue_does_not_swallow_later_signal_annotation() {
  local dir state out status
  dir=$(make_case delayed-signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-delayed.status"
  register_task_fixture "$state" "task-delayed"
  printf 'done: shipped before watcher published signal\n' > "$status"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "empty-queue drain failed before delayed signal publication"
  grep -F 'task-delayed done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the main-drain loss backstop did not surface the terminal event before its delayed signal: $(cat "$out")"

  append_wake "$state" signal task-delayed.status "signal: task-delayed.status" \
    || fail "publishing the delayed status signal failed"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after delayed signal publication"
  grep -F 'latest wake-EVENT observed at drain, not current state: task-delayed.status: done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the empty-queue drain acknowledged an event before its signal annotation: $(cat "$out")"
  pass "an empty-queue backstop presentation still preserves the status for its later signal annotation"
}

test_routine_working_and_covered_done_stay_silent_on_the_empty_queue() {
  local dir state out old
  dir=$(make_case silent-working)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task7.status"
  register_task_fixture "$state" "task7"
  printf 'done: shipped clean\n' > "$state/task8.status"
  register_task_fixture "$state" "task8"
  old=$(( $(date +%s) - 20 ))
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$old" "$state/task8.status" \
    || fail "could not age the covered done fixture"
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task8 --verdict captain --summary 'shipped clean was handled' >/dev/null \
    || fail "could not record the newer branch outcome fixture"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with routine working and covered done lines"

  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed an UNREAD STATUS section: $(cat "$out")"
  fi
  if grep -F 'STATUS OUTCOME BACKSTOP' "$out" >/dev/null; then
    fail "a covered done line printed the outcome backstop: $(cat "$out")"
  fi
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed OPEN DECISIONS: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty-queue covered routine case was not silent: $(cat "$out")"
  pass "routine working and branch-covered done lines print nothing on an empty-queue drain"
}

test_terminal_unqueued_status_is_inert_but_explicit_obligations_survive() {
  local dir state id out manifest before row
  dir=$(make_case terminal-discovery-boundary); state="$dir/state"
  for id in ended archived; do
    register_task_fixture "$state" "$id"
    prime_cursor "$state" "$state/$id.status"
  done
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" "done" ended >/dev/null || fail 'done fixture failed'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" archive archived >/dev/null || fail 'archive fixture failed'
  manifest="$state/.status-presentation-cursor"
  cp "$manifest" "$dir/before"
  for id in ended archived orphan; do printf 'note: %s unqueued historical append\n' "$id" >> "$state/$id.status"; done
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" || fail 'terminal-only empty drain failed'
  [ ! -s "$dir/out" ] || fail "terminal-only ordinary drain read historical notes: $(cat "$dir/out")"
  cmp -s "$manifest" "$dir/before" || fail 'terminal-only drain mutated its cursor manifest'
  register_task_fixture "$state" active
  printf 'note: positive current action\n' > "$state/active.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" || fail 'mixed drain failed'
  out=$(cat "$dir/out")
  assert_contains "$out" 'active note: positive current action' 'in-flight informational status disappeared'
  assert_not_contains "$out" 'unqueued historical append' 'terminal or unknown log entered ordinary discovery'
  for id in ended archived; do
    before=$(awk -F '\t' -v id="$id" '$1==id' "$dir/before")
    row=$(awk -F '\t' -v id="$id" '$1==id' "$manifest")
    [ "$before" = "$row" ] || fail 'mixed drain changed an unselected terminal receipt'
  done
  for id in ended archived orphan; do
    append_wake "$state" signal "$id.status" "signal: $state/$id.status" || fail 'explicit historical signal failed'
  done
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail 'explicit obligation drain failed'
  out=$(cat "$dir/out")
  for id in ended archived orphan; do
    assert_contains "$out" "$id.status" 'explicit raw wake was dropped'
    assert_contains "$out" "note: $id unqueued historical append" 'explicit captured answer was dropped'
  done
  assert_contains "$(cat "$dir/err")" 'WAKE_ACK_REQUIRED:' 'explicit wake lost acknowledgement'
  assert_contains "$(cat "$dir/err")" '--recovery-generation' 'explicit wake lost generation acknowledgement'
  pass 'unqueued terminal/orphan status is inert, active notes remain visible, and explicit wakes retain their byte/ack obligations'
}

test_captured_status_span_survives_subsequent_archival() {
  local dir state
  dir=$(make_case captured-terminal-boundary); state="$dir/state"
  register_task_fixture "$state" captured
  printf 'note: captured before archive\n' > "$state/captured.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    snapshot=$(status_presentation_snapshot "$STATE" captured) || exit 1
    "$1/bin/fm-tasks-axi.sh" archive captured >/dev/null || exit 1
    printf "note: unqueued after archive\n" >> "$STATE/captured.status"
    scan_unread_surface_snapshot "$STATE" "$snapshot" > "$2" || exit 1
    status_commit_presentation_snapshot "$STATE" "$snapshot" || exit 1
  ' _ "$ROOT" "$dir/captured.out" || fail 'captured span exercise failed'
  assert_grep 'captured before archive' "$dir/captured.out" 'previously captured presentation was lost'
  assert_not_contains "$(cat "$dir/captured.out")" 'unqueued after archive' 'captured span read beyond its byte endpoint'
  cp "$state/.status-presentation-cursor" "$dir/before"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/next" || fail 'post-capture terminal drain failed'
  [ ! -s "$dir/next" ] || fail 'ordinary drain read post-archive appended status'
  cmp -s "$dir/before" "$state/.status-presentation-cursor" || fail 'ordinary drain advanced post-archive cursor'
  pass 'an explicitly captured span survives archival and does not admit later historical appends'
}

test_canonical_failure_preserves_only_explicit_status_obligations() {
  local dir state out
  dir=$(make_case corrupt-owner-obligation); state="$dir/state"
  register_task_fixture "$state" broken
  printf '{broken' > "$dir/data/broken/task.json"
  printf 'note: explicit independent byte obligation\n' > "$state/orphan.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail 'owner-failure empty drain failed'
  out=$(cat "$dir/out")
  assert_contains "$out" 'canonical task inventory unavailable' 'owner failure was hidden'
  assert_not_contains "$out" 'independent byte obligation' 'owner failure fell back to orphan discovery'
  [ ! -e "$state/.status-presentation-cursor" ] || fail 'owner failure created an ordinary status cursor'
  append_wake "$state" signal orphan.status 'signal: orphan.status' || fail 'explicit signal failed'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail 'owner-failure explicit drain failed'
  out=$(cat "$dir/out")
  assert_contains "$out" 'canonical task inventory unavailable' 'explicit receipt concealed business-owner failure'
  assert_contains "$out" 'note: explicit independent byte obligation' 'business-owner failure dropped explicit queued bytes'
  assert_contains "$out" 'orphan.status' 'business-owner failure dropped raw signal'
  assert_not_contains "$out" 'STATUS OUTCOME BACKSTOP (' 'owner failure inferred automatic task outcome'
  pass 'canonical failure admits no ordinary status discovery while preserving explicit raw and byte obligations'
}

test_canonical_failure_preserves_only_explicit_status_obligations
test_terminal_unqueued_status_is_inert_but_explicit_obligations_survive
test_captured_status_span_survives_subsequent_archival
test_incident_note_answer_buried_under_routine_note_surfaces_both
test_already_presented_notes_are_not_replayed
test_brand_new_note_after_presentation_is_surfaced
test_signal_annotation_surfaces_every_unread_note_not_only_the_newest
test_decision_resolution_surfaces_once
test_unread_output_over_cap_remains_recoverable
test_snapshot_does_not_ack_a_later_append
test_retired_task_id_starts_new_status_unread
test_settled_retirement_refuses_unread_and_open_status_then_removes_presented_history
test_settled_retirement_refuses_orphan_decision_cursor
test_status_append_serializes_with_retirement
test_weak_identity_still_presents_and_advances
test_snapshot_failure_is_visible
test_warm_manifest_context_is_reused_per_presentation
test_queued_signals_reuse_the_presentation_context
test_queue_rows_without_a_status_snapshot_stay_valid
test_duplicate_manifest_row_refuses_without_advancing
test_legacy_three_column_manifest_migrates
test_open_decisions_fold_is_unchanged
test_empty_queue_does_not_swallow_later_signal_annotation
test_routine_working_and_covered_done_stay_silent_on_the_empty_queue
