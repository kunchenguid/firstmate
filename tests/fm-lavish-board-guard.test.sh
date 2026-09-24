#!/usr/bin/env bash
# Behavioral coverage for bin/fm-lavish-board-guard.sh: which crew-hosted Lavish
# boards read as never armed, and how often that is reported. Also covers the
# published-listing contract in `bin/fm-procevent-lavish.sh sessions`, which is
# the URL-to-file resolution the guard depends on.
#
# Attendance is proved with a REAL registration. Each "armed" case registers a
# genuine process-event source through bin/fm-procevent.sh, under the canonical
# source id the Lavish adapter derives, and lets the guard read it back through
# the published source list. The point of the guard is that the runner's own
# ownership record - not a stub, and not a process name - is what says a board
# is being listened to.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-lavish-board-guard.sh"
ADAPTER="$ROOT/bin/fm-procevent-lavish.sh"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-board-guard)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

BOARD_URL='http://127.0.0.1:4387/session/deadbeefcafe0001'
OTHER_URL='http://127.0.0.1:4387/session/deadbeefcafe0002'

# A listener command that blocks until released, so a registered source in
# these tests is a real runner holding a real claim rather than a timing
# artifact. The wait is bounded so an escaped stub cannot outlive the suite.
BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
trigger=$1
while [ ! -e "$trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
printf 'released\n'
SH
chmod +x "$BLOCKER"

# A world is one firstmate home plus a PATH stub pair: an adapter shim that
# answers only the bare session listing and the canonical source-id command
# (the guard never polls), and a `tmux` whose pane lookup succeeds only while
# the task's endpoint marker exists, so endpoint liveness is a fixture switch
# rather than a timing artifact.
make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  HOME_DIR="$WORLD/home"
  FAKEBIN="$WORLD/fakebin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$FAKEBIN" "$WORLD/boards"
  fm_test_track_procevent_home "$HOME_DIR"
  BOARD_FILE="$WORLD/boards/board.html"
  : > "$BOARD_FILE"
  SESSIONS_FILE="$WORLD/sessions.txt"
  printf 'open\t%s\t%s\n' "$BOARD_URL" "$BOARD_FILE" > "$SESSIONS_FILE"

  cat > "$FAKEBIN/fm-lavish-sessions.sh" <<SH
#!/usr/bin/env bash
set -u
case "\${1-}" in
  sessions)
    [ -z "\${LAVISH_SESSIONS_FAIL:-}" ] || exit 1
    cat "\${LAVISH_SESSIONS_FILE:?}"
    ;;
  source-id) exec "$ADAPTER" source-id "\${2-}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$FAKEBIN/fm-lavish-sessions.sh"

  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1-}" in
  display-message)
    [ -e "${TMUX_STUB_ENDPOINT:?}" ] || exit 1
    printf '%%1\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux"

  ENDPOINT_MARKER="$WORLD/endpoint-alive"
  : > "$ENDPOINT_MARKER"
  RELEASE_MARKER="$WORLD/release"
}

write_task() { # <id> <status-line>...
  local id=$1
  shift
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$WORLD/wt-$id" 'project=alpha' \
    'harness=codex' 'kind=scout'
  : > "$HOME_DIR/state/$id.status"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$HOME_DIR/state/$id.status"
  done
}

# Arm the fixture board for real, under the canonical identity the adapter
# derives, and wait until the runner has actually recorded it.
arm_board() { # <artifact>
  local artifact=$1 id waited=0
  id=$("$ADAPTER" source-id "$artifact") || fail "could not derive the source id for $artifact"
  FM_HOME="$HOME_DIR" "$PROCEVENT" register lavish "$id" \
    -- "$BLOCKER" "$RELEASE_MARKER" >/dev/null \
    || fail "could not register a source for $artifact"
  while [ "$waited" -lt 200 ]; do
    if FM_HOME="$HOME_DIR" "$PROCEVENT" list 2>/dev/null \
      | awk -v i="$id" '$1 == i { found = 1 } END { exit found ? 0 : 1 }'; then
      printf '%s\n' "$id"
      return 0
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  fail "the fixture registration for $artifact never appeared in the source list"
}

retire_board() { # <source-id>
  FM_HOME="$HOME_DIR" "$PROCEVENT" retire "$1" >/dev/null 2>&1 || true
}

run_scan() { # [grace-seconds]
  local grace=${1:-60}
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_LAVISH_BOARD_GRACE_SECS="$grace" \
    FM_LAVISH_ADAPTER_BIN="$FAKEBIN/fm-lavish-sessions.sh" \
    LAVISH_SESSIONS_FILE="$SESSIONS_FILE" \
    TMUX_STUB_ENDPOINT="$ENDPOINT_MARKER" \
    "$GUARD" scan
}

queued_board_wakes() {
  local n
  n=$(grep -c 'lavish-board-unarmed:' "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

record_count() {
  local record n=0
  for record in "$HOME_DIR/state/".lavish-board-unarmed-*; do
    [ -f "$record" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

age_record() { # <seconds-ago>
  local record ago=$1 now
  now=$(date +%s)
  for record in "$HOME_DIR/state/".lavish-board-unarmed-*; do
    [ -f "$record" ] || continue
    sed -i.bak "s/^first_unarmed=.*/first_unarmed=$((now - ago))/" "$record"
    rm -f "$record.bak"
  done
}

# A home whose status logs name no board never reports one, and never needs the
# Lavish server or the source list at all.
test_no_board_is_silent() {
  make_world no-board
  write_task alpha 'working: building the thing' 'done: PR https://example.test/owner/repo/pull/1'
  rm -f "$FAKEBIN/fm-lavish-sessions.sh"
  local out
  out=$(run_scan) || fail "scan failed on a home with no board"
  [ -z "$out" ] || fail "a home with no board reported: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "a home with no board queued a wake"
  pass "fm-lavish-board-guard.sh: no board, no wake and no Lavish call"
}

# The board was armed, so the runner owns its listener and nothing is owed.
test_armed_board_is_silent() {
  make_world armed
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  arm_board "$BOARD_FILE" >/dev/null
  local out
  out=$(run_scan 60) || fail "scan failed with an armed board"
  [ -z "$out" ] || fail "an armed board was reported: $out"
  age_record 600 2>/dev/null || true
  out=$(run_scan 60) || fail "the second armed scan failed"
  [ -z "$out" ] || fail "an armed board was reported on a later cycle: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "an armed board queued a wake"
  [ "$(record_count)" = 0 ] || fail "an armed board left an unarmed record behind"
  pass "fm-lavish-board-guard.sh: a board with a real registration is never reported"
}

# Never armed and the grace period is spent: exactly one wake, carrying the
# task, the URL, and the file.
test_unarmed_past_grace_reports_once() {
  make_world unarmed
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  run_scan 60 >/dev/null || fail "the first scan failed"
  [ "$(queued_board_wakes)" = 0 ] || fail "a board inside its grace period was reported"
  age_record 600
  local out
  out=$(run_scan 60) || fail "the grace-expired scan failed"
  case "$out" in
    *"task=alpha"*) ;;
    *) fail "the wake did not name the task: $out" ;;
  esac
  case "$out" in
    *"url=$BOARD_URL"*) ;;
    *) fail "the wake did not carry the board URL: $out" ;;
  esac
  case "$out" in
    *"file=$BOARD_FILE"*) ;;
    *) fail "the wake did not carry the artifact file: $out" ;;
  esac
  [ "$(queued_board_wakes)" = 1 ] || fail "expected exactly one queued wake"
  pass "fm-lavish-board-guard.sh: an unarmed board past grace reports once"
}

# The same still-unarmed board on the next cycle stays quiet.
test_second_cycle_does_not_duplicate() {
  make_world no-duplicate
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  run_scan 60 >/dev/null || fail "the first scan failed"
  age_record 600
  run_scan 60 >/dev/null || fail "the reporting scan failed"
  [ "$(queued_board_wakes)" = 1 ] || fail "the reporting scan did not queue one wake"
  # Drain the queue so a second wake would be visible as a new row rather than
  # suppressed by the queue itself: the record's own marker must carry it.
  : > "$HOME_DIR/state/.wake-queue"
  local out
  out=$(run_scan 60) || fail "the repeat scan failed"
  [ -z "$out" ] || fail "the same unarmed board reported twice: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "the same unarmed board queued a second wake"
  pass "fm-lavish-board-guard.sh: a still-unarmed board is not reported twice"
}

# A task whose endpoint is gone has no worker to steer, so its board is not
# this check's business.
test_dead_task_is_not_reported() {
  make_world dead-task
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  rm -f "$ENDPOINT_MARKER"
  local out
  out=$(run_scan 60) || fail "scan failed on a dead task"
  [ -z "$out" ] || fail "a dead task's board was reported: $out"
  age_record 600 2>/dev/null || true
  out=$(run_scan 60) || fail "the second dead-task scan failed"
  [ -z "$out" ] || fail "a dead task's board was reported on a later cycle: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "a dead task's board queued a wake"
  pass "fm-lavish-board-guard.sh: a dead task's board is never reported"
}

# The board's only mention may be a terminal line the log has since moved
# past. While the task is live and the board is open, that board is still
# unarmed and still reported; a session the server no longer lists as open,
# or does not list at all, is out of scope.
test_moved_past_line_still_reports_and_closed_boards_are_skipped() {
  make_world moved-past
  write_task alpha \
    "needs-decision [key=board-review]: review the board at $BOARD_URL" \
    'working: waiting on the captain'
  run_scan 60 >/dev/null || fail "the first moved-past scan failed"
  [ "$(record_count)" = 1 ] || fail "a board named only in a moved-past line was not observed"
  age_record 600
  local out
  out=$(run_scan 60) || fail "the moved-past reporting scan failed"
  case "$out" in
    *"url=$BOARD_URL"*) ;;
    *) fail "a live, open board named only in a moved-past line was not reported: $out" ;;
  esac
  [ "$(queued_board_wakes)" = 1 ] || fail "the moved-past board did not queue exactly one wake"

  make_world closed-session
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  printf 'user-ended\t%s\t%s\n' "$BOARD_URL" "$BOARD_FILE" > "$SESSIONS_FILE"
  run_scan 60 >/dev/null || fail "scan failed on a closed session"
  age_record 600 2>/dev/null || true
  out=$(run_scan 60) || fail "the second closed-session scan failed"
  [ -z "$out" ] || fail "a session the server no longer holds open was reported: $out"

  make_world unlisted-session
  write_task alpha "needs-decision [key=board-review]: review the board at $OTHER_URL"
  out=$(run_scan 60) || fail "scan failed on an unlisted session"
  [ -z "$out" ] || fail "a session the server does not list was reported: $out"
  pass "fm-lavish-board-guard.sh: a moved-past board line still reports; closed and unlisted boards are skipped"
}

# Arming clears the record, and a board that loses its registration again rings
# again rather than staying permanently suppressed.
test_arming_clears_the_record_and_a_later_lapse_rings() {
  make_world relapse
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  run_scan 60 >/dev/null || fail "the first scan failed"
  age_record 600
  run_scan 60 >/dev/null || fail "the reporting scan failed"
  [ "$(queued_board_wakes)" = 1 ] || fail "the reporting scan did not queue one wake"
  local source_id
  source_id=$(arm_board "$BOARD_FILE")
  run_scan 60 >/dev/null || fail "the armed scan failed"
  [ "$(record_count)" = 0 ] || fail "an armed board kept its unarmed record"
  retire_board "$source_id"
  : > "$HOME_DIR/state/.wake-queue"
  run_scan 60 >/dev/null || fail "the relapse scan failed"
  age_record 600
  run_scan 60 >/dev/null || fail "the relapse reporting scan failed"
  [ "$(queued_board_wakes)" = 1 ] || fail "a later lapse did not ring again"
  pass "fm-lavish-board-guard.sh: arming clears the record and a later lapse rings"
}

# Neither evidence read may be guessed at: if the session listing or the source
# list cannot be read, nothing is reported, nothing is pruned, and the scan
# exits non-zero so the caller reports it.
test_unreadable_evidence_refuses_rather_than_guessing() {
  make_world listing-fails
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  local rc=0 out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_LAVISH_BOARD_GRACE_SECS=60 \
    FM_LAVISH_ADAPTER_BIN="$FAKEBIN/fm-lavish-sessions.sh" \
    LAVISH_SESSIONS_FILE="$SESSIONS_FILE" LAVISH_SESSIONS_FAIL=1 \
    TMUX_STUB_ENDPOINT="$ENDPOINT_MARKER" \
    "$GUARD" scan 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable session listing reported success"
  [ -z "$out" ] || fail "an unreadable session listing still reported a board: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "an unreadable session listing queued a wake"

  make_world sources-fail
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  cat > "$FAKEBIN/broken-procevent.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$FAKEBIN/broken-procevent.sh"
  rc=0
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_LAVISH_BOARD_GRACE_SECS=60 \
    FM_LAVISH_ADAPTER_BIN="$FAKEBIN/fm-lavish-sessions.sh" \
    FM_LAVISH_PROCEVENT_BIN="$FAKEBIN/broken-procevent.sh" \
    LAVISH_SESSIONS_FILE="$SESSIONS_FILE" \
    TMUX_STUB_ENDPOINT="$ENDPOINT_MARKER" \
    "$GUARD" scan 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable source list reported success"
  [ -z "$out" ] || fail "an unreadable source list still reported a board: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "an unreadable source list queued a wake"
  pass "fm-lavish-board-guard.sh: unreadable evidence refuses rather than guessing"
}

# The listing contract the guard resolves URLs through. An appended vendor
# column must be absorbed, because 0.1.77 added one; a reordered or missing
# required field must refuse, because that is what would resolve a URL to the
# WRONG artifact file.
test_sessions_absorbs_appended_columns_and_refuses_reordering() {
  local dir fakebin out rc
  dir="$TMP_ROOT/sessions-contract"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
cat "${LAVISH_LISTING:?}"
SH
  chmod +x "$fakebin/lavish-axi"

  cat > "$dir/appended.txt" <<'TXT'
sessions[1]{file,status,url,pending_prompts,listener}:
  /tmp/a,b.html,open,"http://127.0.0.1:4387/session/aa11",0,none
TXT
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" LAVISH_LISTING="$dir/appended.txt" \
    "$ADAPTER" sessions) || fail "an appended vendor column was refused"
  [ "$out" = "$(printf 'open\thttp://127.0.0.1:4387/session/aa11\t/tmp/a,b.html')" ] \
    || fail "an appended column was not absorbed cleanly, or a comma in the path was lost: $out"

  cat > "$dir/reordered.txt" <<'TXT'
sessions[1]{status,file,url,pending_prompts}:
  open,/tmp/a.html,"http://127.0.0.1:4387/session/aa11",0
TXT
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" LAVISH_LISTING="$dir/reordered.txt" \
    "$ADAPTER" sessions 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "a reordered session listing was parsed instead of refused"
  [ -z "$out" ] || fail "a reordered session listing still emitted rows: $out"
  pass "fm-procevent-lavish.sh sessions: absorbs an appended column, refuses a reordered one"
}

test_no_board_is_silent
test_armed_board_is_silent
test_unarmed_past_grace_reports_once
test_second_cycle_does_not_duplicate
test_dead_task_is_not_reported
test_moved_past_line_still_reports_and_closed_boards_are_skipped
test_arming_clears_the_record_and_a_later_lapse_rings
test_unreadable_evidence_refuses_rather_than_guessing
test_sessions_absorbs_appended_columns_and_refuses_reordering

echo "all lavish board guard tests passed"
