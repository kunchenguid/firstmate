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
  printf 'terminal_44\n' > "$dir/responses/4.out"
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
  assert_grep '"$FM_ROOT/bin/fm-supervisor-panes.sh" >/dev/null 2>&1 || true' "$ROOT/bin/fm-spawn.sh" \
    "fm-spawn should reconcile the supervisor tab after a successful spawn"
  assert_grep '"$FM_ROOT/bin/fm-supervisor-panes.sh" >/dev/null 2>&1 || true' "$ROOT/bin/fm-teardown.sh" \
    "fm-teardown should reconcile the supervisor tab after teardown"
  assert_grep '"$SCRIPT_DIR/fm-supervisor-panes.sh" >/dev/null 2>&1 || true' "$ROOT/bin/fm-session-start.sh" \
    "fm-session-start should reconcile the supervisor tab on the locked path"
  pass "lifecycle hooks invoke the zellij supervisor reconciler"
}

test_pane_loop_peeks_in_guard_read_only_mode() {
  assert_grep 'FM_GUARD_READ_ONLY=1' "$ROOT/bin/fm-supervisor-pane-loop.sh" \
    "the supervisor pane loop must peek in guard read-only mode so it cannot claim the once-per-episode WATCHER DOWN banner"
  pass "fm-supervisor-pane-loop: peeks in guard read-only mode"
}

test_active_zellij_crews_create_supervisor_tab_and_panes
test_zero_active_zellij_crews_close_existing_supervisor_tab
test_lifecycle_hooks_invoke_reconciler
test_pane_loop_peeks_in_guard_read_only_mode
