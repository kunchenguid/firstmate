#!/usr/bin/env bash
# Focused watched-pane identity, CLI and Herdr event-policy contracts.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
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

test_watched_pane_identity_and_cli

# Production bounded wait, fake transport: verify the snapshot survives the
# wait boundary and both reconnect and streaming use the opt-in policy.
(
  # shellcheck source=/dev/null
  . "$ROOT/bin/backends/herdr.sh"
  WAIT_DIR="$TMP_ROOT/wait"; mkdir -p "$WAIT_DIR/state"
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
