#!/usr/bin/env bash
# Focused watched-pane identity, CLI and Herdr event-policy contracts.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-pane)

make_herdr_fakebin() {
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "$1 $2" in
  'workspace list') cat "$FM_HERDR_RESPONSES/1.out" ;;
  'tab list') cat "$FM_HERDR_RESPONSES/2.out" ;;
  'pane list') cat "$FM_HERDR_RESPONSES/3.out" ;;
  *) echo "unexpected Herdr command: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$fb/herdr"
  printf '%s' "$fb"
}

test_watched_pane_identity_and_cli() {
  local dir fb resp log state out rc mode
  dir="$TMP_ROOT/watched-pane"; resp="$dir/responses"; state="$dir/home/state"; log="$dir/log"
  mkdir -p "$resp" "$state"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  for mode in unique refreshed missing-workspace duplicate-workspace duplicate-tab split missing-pane; do
    rm -f "$resp/.count"
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"ops"}]}}' > "$resp/1.out"
    printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"design"}]}}' > "$resp/2.out"
    printf '{"result":{"panes":[{"tab_id":"w1:t1","pane_id":"w1:p1"}]}}' > "$resp/3.out"
    case "$mode" in
      refreshed) printf '{"result":{"panes":[{"tab_id":"w1:t1","pane_id":"w1:p9"}]}}' > "$resp/3.out" ;;
      missing-workspace) printf '{"result":{"workspaces":[]}}' > "$resp/1.out" ;;
      duplicate-workspace) printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"ops"},{"workspace_id":"w2","label":"ops"}]}}' > "$resp/1.out" ;;
      duplicate-tab) printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"design"},{"tab_id":"w1:t2","label":"design"}]}}' > "$resp/2.out" ;;
      split) printf '{"result":{"panes":[{"tab_id":"w1:t1","pane_id":"w1:p1"},{"tab_id":"w1:t1","pane_id":"w1:p2"}]}}' > "$resp/3.out" ;;
      missing-pane) printf '{"result":{"panes":[]}}' > "$resp/3.out" ;;
    esac
    rc=0
    out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_resolve_watched_pane watch-session ops design' "$ROOT" 2>"$dir/error") || rc=$?
    case "$mode" in
      unique) [ "$rc:$out" = '0:watch-session:w1:p1' ] || fail "exact identity resolution: $rc:$out" ;;
      refreshed) [ "$rc:$out" = '0:watch-session:w1:p9' ] || fail "identity did not refresh: $rc:$out" ;;
      *) [ "$rc" -ne 0 ] && [ -z "$out" ] || fail "must refuse $mode: $out" ;;
    esac
  done
  pass "watched identity resolves current IDs and refuses missing or ambiguous workspaces/tabs/panes"

  printf '{"result":{"panes":[{"tab_id":"w1:t1","pane_id":"w1:p1"}]}}' > "$resp/3.out"
  rm -f "$resp/.count"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' --notify-done || fail "CLI add"
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-watch-pane.sh" list) || fail "CLI list"
  [ "$out" = $'watch-session\tops\tdesign\tDesign review\t1' ] || fail "registry row: $out"
  # Re-add/upsert must preserve one entry, including an opt-out update.
  rm -f "$resp/.count"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' || fail "CLI replace"
  [ "$(wc -l < "$state/watched-panes" | tr -d ' ')" = 1 ] || fail "upsert duplicated row"
  grep -q $'Design review\t0$' "$state/watched-panes" || fail "upsert did not disable done"
  cp "$state/watched-panes" "$dir/before"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design Another 2>"$dir/error" \
    && fail "duplicate identity must fail"
  cmp -s "$state/watched-panes" "$dir/before" || fail "failed add must not change registry"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops $'bad\ttab' Bad 2>"$dir/error" \
    && fail "control character must fail"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-watch-pane.sh" remove 'Design review' || fail "CLI remove"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-watch-pane.sh" remove 'Design review' || fail "remove absent must be idempotent"
  [ ! -s "$state/watched-panes" ] || fail "remove left row"
  env -u FM_HOME bash "$ROOT/bin/fm-watch-pane.sh" list 2>"$dir/error" && fail "explicit home required"
  printf 'malformed\n' > "$state/watched-panes"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-watch-pane.sh" list 2>"$dir/error" && fail "malformed registry must fail"
  pass "watch CLI validates, atomically upserts, lists and idempotently removes without lifecycle calls"
}

test_watched_pane_supervision_need() {
  local state="$TMP_ROOT/supervision/state" mode
  mkdir -p "$state"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervision-lib.sh"
  for mode in absent empty malformed duplicate valid blocked-only; do
    rm -f "$state/watched-panes"
    case "$mode" in
      empty) : > "$state/watched-panes" ;;
      malformed) printf 'malformed\n' > "$state/watched-panes" ;;
      duplicate) printf 'sess\tops\tdesign\tDesign\t1\nsess\tops\tdesign\tDesign\t1\n' > "$state/watched-panes" ;;
      valid) printf 'sess\tops\tdesign\tDesign\t1\n' > "$state/watched-panes" ;;
      blocked-only) printf 'sess\tops\tdesign\tDesign\t0\n' > "$state/watched-panes" ;;
    esac
    case "$mode" in
      valid|blocked-only)
        fm_supervision_needed "$state" || fail "$mode watch-only home must need supervision"
        [ "$FM_SUP_IN_FLIGHT:$FM_SUP_SOURCES:$FM_SUP_CHECKS" = '0:0:0' ] || fail "watch counted as another kind of work"
        fm_supervision_unhealthy "$state" || fail "watch-only home without beacon must be unhealthy"
        touch "$state/.last-watcher-beat"
        if fm_supervision_unhealthy "$state"; then fail "fresh beacon must satisfy watch-only supervision"; fi
        rm "$state/.last-watcher-beat"
        ;;
      *) if fm_supervision_needed "$state"; then fail "$mode registry must not arm supervision"; fi ;;
    esac
  done
  rm "$state/watched-panes"
  if fm_supervision_needed "$state"; then fail "removing the last watch must remove supervision need"; fi
  pass "valid nonempty pane watches need supervision independently of tasks and done policy"
}

test_watched_pane_locked_read_bound() {
  local dir fb hangfb resp state pid rc i
  dir="$TMP_ROOT/locked-read-bound"; resp="$dir/responses"; state="$dir/home/state"
  mkdir -p "$resp" "$state"; : > "$dir/log"
  fb=$(make_herdr_fakebin "$dir")
  hangfb="$dir/fakebin-hang"; mkdir -p "$hangfb"
  cat > "$hangfb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "$1 $2" in
  'workspace list') printf '%s\n' $$ > "$FM_HERDR_PID_FILE"; exec sleep 300 ;;
  *) echo "unexpected Herdr command: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$hangfb/herdr"

  # A hung session must not hold .watched-panes.lock across an unbounded wait:
  # remove still finishes at the read bound, drops the row, frees the lock and
  # leaves no read child behind. The outer bound only keeps a regression from
  # hanging the suite; the fixed code answers in ~FM_WATCHED_PANE_READ_SECS.
  printf 'hung-sess\tops\tdesign\tHung\t1\n' > "$state/watched-panes"
  rc=0
  fm_run_timed 12 env FM_WATCHED_PANE_READ_SECS=2 PATH="$hangfb:$PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$dir/log" FM_HERDR_PID_FILE="$dir/hung-remove.pid" \
    bash "$ROOT/bin/fm-watch-pane.sh" remove Hung 2>"$dir/error" || rc=$?
  [ "$rc" -eq 0 ] || fail "remove of a hung-session watch must finish at the read bound: rc=$rc $(cat "$dir/error")"
  [ ! -s "$state/watched-panes" ] || fail "hung-session row survived removal"
  pid=$(cat "$dir/hung-remove.pid")
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && fail "bounded read's child outlived the lock release"
  # The freed lock serves the next mutation immediately, so other sessions'
  # healthy watches are not starved by the hung one.
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"ops"}]}}' > "$resp/1.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"design"}]}}' > "$resp/2.out"
  printf '{"result":{"panes":[{"tab_id":"w1:t1","pane_id":"w1:p1"}]}}' > "$resp/3.out"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$dir/log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design Healthy \
    || fail "registry lock still held after the bounded remove"
  # A hung session's registration read fails the add at the same bound and
  # changes nothing.
  rc=0
  fm_run_timed 12 env FM_WATCHED_PANE_READ_SECS=2 PATH="$hangfb:$PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$dir/log" FM_HERDR_PID_FILE="$dir/hung-add.pid" \
    bash "$ROOT/bin/fm-watch-pane.sh" add hung-sess ops design 'Hung add' 2>"$dir/error" || rc=$?
  [ "$rc" -ne 0 ] || fail "hung-session add must fail at the read bound"
  grep -q 'exceeded the 2s bound' "$dir/error" || fail "hung add did not report the read bound: $(cat "$dir/error")"
  pid=$(cat "$dir/hung-add.pid")
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && fail "hung add's read child outlived the lock release"
  grep -q Healthy "$state/watched-panes" || fail "healthy row lost to the failed add"
  ! grep -q 'Hung add' "$state/watched-panes" || fail "failed add changed the registry"
  pass "locked registry reads die at FM_WATCHED_PANE_READ_SECS, free the lock, and leave no child"
}

test_watched_pane_marker_retire() {
  local dir fb resp log state marker
  dir="$TMP_ROOT/marker-retire"; resp="$dir/responses"; state="$dir/home/state"; log="$dir/log"
  mkdir -p "$resp" "$state"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"ops"}]}}' > "$resp/1.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"design"}]}}' > "$resp/2.out"
  printf '{"result":{"panes":[{"tab_id":"w1:t1","pane_id":"w1:p1"}]}}' > "$resp/3.out"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' || fail "CLI add"
  marker="$state/.herdr-escalated-watch-session_w1_p1"
  # remove retires the watch-owned escalation marker so a re-registered pane
  # cannot inherit it and stay silent on its next blocked.
  printf 'blocked' > "$marker"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" remove 'Design review' || fail "CLI remove"
  [ ! -e "$marker" ] || fail "remove must retire the pane's watch-owned escalation marker"
  # Replacing a label retires the old row's marker the same way.
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' --notify-done || fail "CLI re-add"
  printf 'blocked' > "$marker"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' || fail "CLI replace"
  [ ! -e "$marker" ] || fail "replace must retire the pane's watch-owned escalation marker"
  # A pane a task metadata record owns is task-owned: its marker survives.
  fm_write_meta "$state/tk1.meta" "window=watch-session:w1:p1" "backend=herdr" "kind=ship"
  printf 'blocked' > "$marker"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" remove 'Design review' || fail "CLI remove task-owned"
  [ -e "$marker" ] || fail "remove must not clear a task-owned pane's escalation marker"
  rm -f "$state/tk1.meta" "$marker"
  # A pane that no longer resolves clears nothing but never blocks removal.
  printf '{"result":{"panes":[]}}' > "$resp/3.out"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Gone pane' 2>/dev/null && fail "add of a missing pane must fail"
  printf 'watch-session\tops\tdesign\tGone pane\t0\n' > "$state/watched-panes"
  printf 'blocked' > "$marker"
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash "$ROOT/bin/fm-watch-pane.sh" remove 'Gone pane' || fail "remove must stay idempotent when the pane is unresolvable"
  (
    export PATH="$fb:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp"
    . "$ROOT/bin/fm-push-transition-lib.sh"
    fm_backend_source herdr || fail "load watched transition backend"
    wake() { printf '%s\n' "$1" >> "$dir/wakes"; }
    printf '{"result":{"panes":[{"tab_id":"w1:t1","pane_id":"w1:p1"}]}}' > "$resp/3.out"
    rm -f "$marker"
    : > "$dir/wakes"
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' --notify-done || fail "race add"
    FM_WATCHED_PANES=$'watch-session:w1:p1\tDesign review\t1'
    FM_WATCHED_PANES_IDENTITY=$(fm_watch_pane_registry_identity "$state")
    OLD_IDENTITY=$FM_WATCHED_PANES_IDENTITY
    REC=$(fm_transition_record w1:p1 '' '' blocked claude)
    bash "$ROOT/bin/fm-watch-pane.sh" remove 'Design review' || fail "race remove"
    handle_push_transition herdr watch-session "$REC"
    [ ! -e "$marker" ] && [ ! -s "$dir/wakes" ] || fail "retired subscription recreated a marker or wake"
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' --notify-done || fail "race re-add"
    handle_push_transition herdr watch-session "$REC"
    [ ! -e "$marker" ] && [ ! -s "$dir/wakes" ] || fail "old snapshot survived identical re-registration"
    FM_WATCHED_PANES_IDENTITY=$(fm_watch_pane_registry_identity "$state")
    fm_backend_herdr_apply_transition "$state" watch-session "$REC" >/dev/null || fail "re-registered blocked must be actionable"
    handle_push_transition herdr watch-session "$REC"
    [ -s "$marker" ] && [ -s "$dir/wakes" ] || fail "fresh registration missed blocked"
    CURRENT_IDENTITY=$FM_WATCHED_PANES_IDENTITY
    FM_WATCHED_PANES_IDENTITY=$OLD_IDENTITY
    WORKING=$(fm_transition_record w1:p1 '' '' working claude)
    fm_backend_herdr_apply_transition "$state" watch-session "$WORKING" >/dev/null || true
    [ -s "$marker" ] || fail "old working edge cleared the new registration marker"
    FM_WATCHED_PANES_IDENTITY=$CURRENT_IDENTITY
    fm_backend_herdr_apply_transition "$state" watch-session "$WORKING" >/dev/null || true
    [ ! -e "$marker" ] || fail "fresh working edge must rearm the registration"
    eval "$(declare -f fm_wake_append | sed '1s/fm_wake_append/original_wake_append/')"
    fm_wake_append() {
      if bash "$ROOT/bin/fm-watch-pane.sh" remove 'Design review' 2>"$dir/busy"; then
        fail "registry mutation overlapped notification commit"
      fi
      original_wake_append "$@"
    }
    handle_push_transition herdr watch-session "$REC"
    [ -s "$marker" ] || fail "serialized notification did not commit"
    bash "$ROOT/bin/fm-watch-pane.sh" add watch-session ops design 'Design review' || fail "replace after notification"
    handle_push_transition herdr watch-session "$REC"
    [ ! -e "$marker" ] || fail "retired snapshot recreated replacement marker"
    FM_WATCHED_PANES_IDENTITY=$(fm_watch_pane_registry_identity "$state")
    FM_WATCHED_PANES=$'watch-session:w1:p1\tDesign review\t0'
    DONE=$(fm_transition_record w1:p1 '' '' 'done' claude)
    if fm_backend_herdr_apply_transition "$state" watch-session "$DONE" >/dev/null; then fail "replacement retained old done policy"; fi
    bash "$ROOT/bin/fm-watch-pane.sh" remove 'Design review' || fail "notification leaked the registry lock"
  ) || fail "retired snapshot and notification serialization contracts"
  pass "remove/replace retire watch-owned escalation markers, keep task-owned state, and stay idempotent"
}

test_watched_pane_supervision_need
test_watched_pane_identity_and_cli
test_watched_pane_marker_retire
test_watched_pane_locked_read_bound

# Production bounded wait, fake transport: verify the snapshot survives the
# wait boundary and both reconnect and streaming use the opt-in policy.
(
  # shellcheck source=/dev/null
  . "$ROOT/bin/backends/herdr.sh"
  WAIT_DIR="$TMP_ROOT/wait"; mkdir -p "$WAIT_DIR/state"
  FM_STATE_OVERRIDE="$WAIT_DIR/state" . "$ROOT/bin/fm-wake-lib.sh"
  printf 'sess\tops\tdesign\tOperator design\t1\n' > "$WAIT_DIR/state/watched-panes"
  FM_WATCHED_PANES_IDENTITY=$(fm_watch_pane_registry_identity "$WAIT_DIR/state")
  cat > "$WAIT_DIR/reader" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_WATCH_TEST_ARGS"
printf '@subscribed\n'
cat "$FM_WATCH_TEST_EVENTS"
SH
  chmod +x "$WAIT_DIR/reader"
  export FM_BACKEND_HERDR_EVENT_READER="$WAIT_DIR/reader"
  export FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1
  export FM_WATCH_TEST_ARGS="$WAIT_DIR/args"
  export FM_WATCH_TEST_EVENTS="$WAIT_DIR/events"
  : > "$FM_WATCH_TEST_EVENTS"
  # shellcheck disable=SC2329 # Runtime backend read fixtures.
  fm_backend_herdr_socket_path() { printf fake-socket; }
  # shellcheck disable=SC2329 # Runtime backend read fixtures.
  fm_backend_herdr_agent_status_raw() { printf '%s' "$TEST_LEVEL"; }
  FM_WATCHED_PANES=$'sess:p1\tOperator design\t1'
  TEST_LEVEL=blocked
  REC=$(fm_backend_herdr_wait_transition sess 1 "$WAIT_DIR/state" sess:p1 other:p2) || fail "watched reconcile blocked"
  [ "$(fm_transition_to_status "$REC")" = blocked ] || fail "wrong blocked reconcile"
  fm_backend_herdr_commit_transition "$WAIT_DIR/state" sess "$REC"
  assert_contains "$(cat "$WAIT_DIR/args")" 'fake-socket 1 p1' "explicit pane list missing"
  assert_not_contains "$(cat "$WAIT_DIR/args")" p2 "foreign session entered subscription"
  RC=0; fm_backend_herdr_wait_transition sess 1 "$WAIT_DIR/state" sess:p1 >/dev/null || RC=$?
  [ "$RC" = 1 ] || fail "watched reconnect must dedupe blocked"
  TEST_LEVEL='done'
  REC=$(fm_backend_herdr_wait_transition sess 1 "$WAIT_DIR/state" sess:p1) || fail "watched reconcile done after blocked"
  [ "$(fm_transition_to_status "$REC")" = 'done' ] || fail "wrong done reconcile"
  fm_backend_herdr_commit_transition "$WAIT_DIR/state" sess "$REC"
  RC=0; fm_backend_herdr_wait_transition sess 1 "$WAIT_DIR/state" sess:p1 >/dev/null || RC=$?
  [ "$RC" = 1 ] || fail "watched reconnect must dedupe done"
  FM_WATCHED_PANES=
  fm_backend_herdr_clear_transition "$WAIT_DIR/state" sess:p1
  RC=0; fm_backend_herdr_wait_transition sess 1 "$WAIT_DIR/state" sess:p1 >/dev/null || RC=$?
  [ "$RC" = 1 ] || fail "ordinary task done must remain deferred"
  FM_WATCHED_PANES=$'sess:p1\tOperator design\t1'
  TEST_LEVEL=working
  printf 'unrequested\tw1\tblocked\tagent\np1\tw1\tdone\tagent\n' > "$FM_WATCH_TEST_EVENTS"
  REC=$(fm_backend_herdr_wait_transition sess 1 "$WAIT_DIR/state" sess:p1) || fail "watched streaming done"
  [ "$(fm_transition_pane_id "$REC")" = p1 ] || fail "unrequested pane escaped explicit list"
  [ "$(fm_transition_to_status "$REC")" = 'done' ] || fail "stream done policy lost"
) || fail "watched bounded event-wait contracts"
pass "bounded Herdr wait retains explicit pane/session list, opt-in stream/reconnect policy and dedupe"
