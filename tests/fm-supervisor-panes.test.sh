#!/usr/bin/env bash
# Focused tests for the zellij-only supervisor pane reconciler.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-supervisor-panes-tests)

make_zellij_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ZELLIJ_LOG:?}"
RESP="${FM_ZELLIJ_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'ZELLIJ_SESSION_NAME=%s' "${ZELLIJ_SESSION_NAME:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = list-sessions ]; then
  printf '%s\n' "${FM_ZELLIJ_SESSION_LIST:-}"
  exit 0
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$next" > "$COUNT_FILE"
[ -f "$RESP/$next.out" ] && cat "$RESP/$next.out"
exit 0
SH
  chmod +x "$fb/zellij"
  printf '%s\n' "$fb"
}

supervisor_title() {  # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_supervisor_tab_title' "$ROOT"
}

test_active_zellij_crews_create_supervisor_tab_and_panes() {
  local dir home state fb title log
  dir="$TMP_ROOT/active"; home="$dir/home"; state="$home/state"; mkdir -p "$state" "$dir/responses"
  title=$(supervisor_title "$home")
  fm_write_meta "$state/alpha.meta" \
    "window=firstmate:11" \
    "backend=zellij" \
    "kind=ship"
  fm_write_meta "$state/bravo.meta" \
    "window=firstmate:12" \
    "backend=zellij" \
    "kind=scout"
  fm_write_secondmate_meta "$state/skip-sm.meta" "$dir/secondmate-home"
  fm_write_meta "$state/skip-tmux.meta" "window=main:1"
  printf '[]\n' > "$dir/responses/1.out"
  printf '[]\n' > "$dir/responses/2.out"
  printf '21\n' > "$dir/responses/3.out"
  printf '[{"id":43,"tab_id":21,"is_plugin":false}]\n' > "$dir/responses/4.out"
  printf 'terminal_44\n' > "$dir/responses/6.out"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-supervisor-panes.sh" >/dev/null 2>&1 \
    || fail "fm-supervisor-panes should reconcile active zellij crews"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''new-tab'$'\x1f''--cwd'$'\x1f'"$ROOT"$'\x1f''--name'$'\x1f'"$title" \
    "active zellij crews should create the supervisor tab with the home-scoped title"
  assert_contains "$log" "fm-supervisor-pane-loop.sh"$'\x1f''alpha' \
    "the first active zellij crew should seed the supervisor tab"
  assert_contains "$log" $'\x1f''rename-pane'$'\x1f''-p'$'\x1f''43'$'\x1f''fm-alpha' \
    "the seed supervisor pane should carry the same fm-<id> title as the later panes"
  assert_contains "$log" $'\x1f''new-pane'$'\x1f''--tab-id'$'\x1f''21' \
    "additional active zellij crews should create more panes on the supervisor tab"
  assert_contains "$log" "fm-supervisor-pane-loop.sh"$'\x1f''bravo' \
    "the second active zellij crew should get its own supervisor pane"
  assert_not_contains "$log" "skip-sm" "secondmates must not appear in the zellij supervisor tab"
  assert_not_contains "$log" "skip-tmux" "non-zellij crews must not appear in the zellij supervisor tab"
  pass "fm-supervisor-panes: active zellij crews create the supervisor tab and one pane per crew"
}

test_zero_active_zellij_crews_close_existing_supervisor_tab() {
  local dir home state fb title log
  dir="$TMP_ROOT/cleanup"; home="$dir/home"; state="$home/state"; mkdir -p "$state" "$dir/responses"
  title=$(supervisor_title "$home")
  fm_write_meta "$state/tmux-only.meta" "window=main:1"
  printf '[{"tab_id":4,"name":"%s","active":false}]\n' "$title" > "$dir/responses/1.out"
  printf '[{"tab_id":4,"name":"%s","active":false}]\n' "$title" > "$dir/responses/2.out"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-supervisor-panes.sh" >/dev/null 2>&1 \
    || fail "fm-supervisor-panes should clean up an existing supervisor tab when no active zellij crews remain"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''close-tab-by-id'$'\x1f''4' \
    "zero active zellij crews should close the existing supervisor tab"
  assert_not_contains "$log" $'\x1f''new-tab' \
    "zero active zellij crews must not create a replacement supervisor tab"
  pass "fm-supervisor-panes: zero active zellij crews close the existing supervisor tab"
}

test_lifecycle_hooks_invoke_reconciler() {
  # shellcheck disable=SC2016 # The $FM_ROOT/$SCRIPT_DIR references are literal text in the hook scripts.
  assert_grep '"$FM_ROOT/bin/fm-supervisor-panes.sh" >/dev/null 2>&1 || true' "$ROOT/bin/fm-spawn.sh" \
    "fm-spawn should reconcile the supervisor tab after a successful spawn"
  # shellcheck disable=SC2016 # The $FM_ROOT reference is literal text in the hook script.
  assert_grep '"$FM_ROOT/bin/fm-supervisor-panes.sh" >/dev/null 2>&1 || true' "$ROOT/bin/fm-teardown.sh" \
    "fm-teardown should reconcile the supervisor tab after teardown"
  # shellcheck disable=SC2016 # The $SCRIPT_DIR reference is literal text in the hook script.
  assert_grep '"$SCRIPT_DIR/fm-supervisor-panes.sh" >/dev/null 2>&1 || true' "$ROOT/bin/fm-session-start.sh" \
    "fm-session-start should reconcile the supervisor tab on the locked path"
  pass "lifecycle hooks invoke the zellij supervisor reconciler"
}

# Stand the pane loop up against stub helpers in a throwaway bin/ so the two
# poll cadences can be measured directly: the loop resolves fm-backend.sh,
# fm-crew-state.sh, and fm-peek.sh from its own directory.
make_pane_loop_fakebin() {  # <dir> -> echoes bin dir
  local dir=$1 bin="$1/bin"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-supervisor-pane-loop.sh" "$bin/fm-supervisor-pane-loop.sh"
  cat > "$bin/fm-backend.sh" <<'SH'
fm_meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
SH
  cat > "$bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "${FM_TEST_STATE_CALLS:?}"
printf 'state: working · source: stub\n'
SH
  cat > "$bin/fm-peek.sh" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "${FM_TEST_PEEK_CALLS:?}"
printf 'stub peek output\n'
SH
  chmod +x "$bin/fm-crew-state.sh" "$bin/fm-peek.sh"
  printf '%s\n' "$bin"
}

run_pane_loop_briefly() {  # <bin> <state> <state-refresh-secs> <state-calls> <peek-calls> [render]
  local bin=$1 state=$2 state_refresh=$3 state_calls=$4 peek_calls=$5 render=${6:-/dev/null} pid
  : > "$state_calls"
  : > "$peek_calls"
  [ "$render" = /dev/null ] || : > "$render"
  fm_write_meta "$state/alpha.meta" "window=firstmate:11" "backend=zellij" "kind=ship"
  FM_ROOT_OVERRIDE="$(dirname "$bin")" \
    FM_HOME="$(dirname "$state")" \
    FM_STATE_OVERRIDE="$state" \
    FM_SUPERVISOR_REFRESH_SECS=1 \
    FM_SUPERVISOR_STATE_REFRESH_SECS="$state_refresh" \
    FM_TEST_STATE_CALLS="$state_calls" \
    FM_TEST_PEEK_CALLS="$peek_calls" \
    bash "$bin/fm-supervisor-pane-loop.sh" alpha >"$render" 2>/dev/null &
  pid=$!
  sleep 3
  rm -f "$state/alpha.meta"
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_pane_loop_polls_run_state_on_its_own_slower_cadence() {
  local dir bin state state_calls peek_calls states peeks
  dir="$TMP_ROOT/pane-loop-cadence"; state="$dir/home/state"; mkdir -p "$state"
  bin=$(make_pane_loop_fakebin "$dir")
  state_calls="$dir/state-calls"; peek_calls="$dir/peek-calls"

  run_pane_loop_briefly "$bin" "$state" 3600 "$state_calls" "$peek_calls"
  states=$(grep -c call "$state_calls" || true)
  peeks=$(grep -c call "$peek_calls" || true)
  [ "$states" = "1" ] \
    || fail "the expensive run-state lookup should run once per state interval, not once per redraw (got $states)"
  [ "$peeks" -ge 2 ] \
    || fail "the pane should keep redrawing and peeking on the refresh interval (got $peeks)"

  run_pane_loop_briefly "$bin" "$state" 1 "$state_calls" "$peek_calls"
  states=$(grep -c call "$state_calls" || true)
  [ "$states" -ge 2 ] \
    || fail "a short FM_SUPERVISOR_STATE_REFRESH_SECS should poll the run state repeatedly (got $states)"
  pass "fm-supervisor-pane-loop: run-state lookups follow their own slower cadence"
}

# The redraw stamp is recomputed every cycle while the run-state line is
# reused for a whole state interval, so the two must be stamped separately or
# a minute-old `state: working` reads as current under a live timestamp.
test_pane_loop_stamps_the_run_state_line_separately() {
  local dir bin state render distinct frames
  dir="$TMP_ROOT/pane-loop-stamps"; state="$dir/home/state"; mkdir -p "$state"
  bin=$(make_pane_loop_fakebin "$dir")
  render="$dir/render"

  run_pane_loop_briefly "$bin" "$state" 3600 "$dir/state-calls" "$dir/peek-calls" "$render"
  assert_grep 'Peek observed: ' "$render" \
    "the redraw timestamp should say it stamps the peek, not everything below it"
  assert_grep 'state: working · source: stub · run state as of ' "$render" \
    "the run-state line should carry its own refresh timestamp"
  frames=$(grep -c 'Peek observed: ' "$render" || true)
  distinct=$(grep -o 'run state as of .*' "$render" | LC_ALL=C sort -u | grep -c . || true)
  [ "$frames" -ge 2 ] \
    || fail "the pane should have rendered more than one frame to compare stamps (got $frames)"
  [ "$distinct" = "1" ] \
    || fail "a cached run-state line must keep the timestamp of the lookup that produced it (got $distinct distinct stamps)"
  pass "fm-supervisor-pane-loop: stamps the cached run-state line separately from the redraw"
}

test_pane_loop_peeks_in_guard_read_only_mode() {
  assert_grep 'FM_GUARD_READ_ONLY=1' "$ROOT/bin/fm-supervisor-pane-loop.sh" \
    "the supervisor pane loop must peek in guard read-only mode so it cannot claim the once-per-episode WATCHER DOWN banner"
  pass "fm-supervisor-pane-loop: peeks in guard read-only mode"
}

test_active_zellij_crews_create_supervisor_tab_and_panes
test_zero_active_zellij_crews_close_existing_supervisor_tab
test_lifecycle_hooks_invoke_reconciler
test_pane_loop_polls_run_state_on_its_own_slower_cadence
test_pane_loop_stamps_the_run_state_line_separately
test_pane_loop_peeks_in_guard_read_only_mode
