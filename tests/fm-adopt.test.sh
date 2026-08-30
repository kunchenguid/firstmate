#!/usr/bin/env bash
# tests/fm-adopt.test.sh - bin/fm-adopt.sh (adopt an already-running cmux
# workspace as a supervised task) plus the additive kind=adopted behavior in
# bin/fm-teardown.sh, bin/fm-watch.sh, and bin/fm-backend.sh's
# fm_backend_expected_label_of_selector.
#
# Uses the same fake-cmux-CLI pattern as tests/fm-backend-cmux.test.sh (a small
# LOG-based canned-response `cmux` + real `jq`), the whole-script override
# pattern (FM_STATE_OVERRIDE/FM_ROOT_OVERRIDE), and a real fm-watch.sh subprocess
# for the stale-exemption check, mirroring tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

ADOPT="$ROOT/bin/fm-adopt.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PEEK="$ROOT/bin/fm-peek.sh"
SEND="$ROOT/bin/fm-send.sh"
WATCH="$ROOT/bin/fm-watch.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"

TMP_ROOT=$(fm_test_tmproot fm-adopt-tests)
# Keep fm-guard.sh's worktree-tangle check inert: FM_ROOT_OVERRIDE points at a
# fresh non-git dir so the guard never alarms about the test runner's own branch,
# the same trick tests/wake-helpers.sh uses. fm-guard is called `|| true` by every
# script under test, so this only keeps stderr clean.
TANGLE_ROOT=$(fm_test_tmproot fm-adopt-tangle-root)

WS_A="11111111-1111-1111-1111-111111111111"
SF_A="22222222-2222-2222-2222-222222222222"

# make_cmux_fakebin: a `cmux` stub that logs every invocation (unit-separated
# args, with the socket password prefix) to $FM_CMUX_LOG and returns the canned
# ordered response from $FM_CMUX_RESPONSES/<n>.out. version/ping are handled
# specially (not call-counted). Mirrors tests/fm-backend-cmux.test.sh.
make_cmux_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CMUX_LOG:?}"
RESP="${FM_CMUX_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'CMUX_SOCKET_PASSWORD=%s' "${CMUX_SOCKET_PASSWORD:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = version ]; then
  printf 'cmux %s (97) [abcdef1]\n' "${FM_CMUX_FAKE_VERSION:-0.64.17}"
  exit 0
fi
if [ "${1:-}" = ping ]; then
  printf '%s\n' "${FM_CMUX_FAKE_PING:-PONG}"
  exit "${FM_CMUX_FAKE_PING_EXIT:-0}"
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/cmux"
  printf '%s\n' "$fb"
}

cmux_panes_response() {  # <dir> <n> <surface_id>
  printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}' "$3" "$3" > "$1/responses/$2.out"
}

cmux_panes_empty_response() {  # <dir> <n>
  printf '{"panes":[]}' > "$1/responses/$2.out"
}

cmux_read_screen_response() {  # <dir> <n> <text>
  jq -n --arg t "$3" '{text:$t}' > "$1/responses/$2.out"
}

cmux_workspace_cwd_response() {  # <dir> <n> <ws-id> <title> <current_directory>
  jq -n --arg id "$3" --arg t "$4" --arg cwd "$5" \
    '{workspaces:[{id:$id,title:$t,current_directory:$cwd}]}' > "$1/responses/$2.out"
}

# A logging `treehouse` stub: it must NEVER be invoked for an adopt or an
# adopted teardown. Any call leaves a marker file the test then asserts absent.
add_logging_treehouse() {  # <fakebin> <marker>
  local fb=$1 marker=$2
  cat > "$fb/treehouse" <<SH
#!/usr/bin/env bash
printf 'CALLED %s\n' "\$*" >> "$marker"
exit 0
SH
  chmod +x "$fb/treehouse"
}

write_adopted_meta() {  # <state> <id> <ws> <sf> <worktree>
  fm_write_meta "$1/$2.meta" \
    "window=$3:$4" \
    "endpoint_task_id=$2" \
    "worktree=$5" \
    "project=$5" \
    "harness=adopted" \
    "kind=adopted" \
    "mode=adopted" \
    "yolo=off" \
    "model=default" \
    "effort=default" \
    "backend=cmux" \
    "cmux_workspace_id=$3" \
    "cmux_surface_id=$4"
}

seen_sig() {  # <file>
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

hash_pane_like() {  # <text> -> same digest fm-watch.sh's hash_pane produces
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q; else printf '%s' "$1" | md5sum | cut -d' ' -f1; fi
}

wait_live() {  # <pid> [ticks]
  local pid=$1 limit=${2:-20} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- 1. adopt writes the expected meta --------------------------------------

test_adopt_writes_meta() {
  local dir state wt out
  dir="$TMP_ROOT/writes-meta"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$dir/responses" "$wt"
  touch "$state/.last-watcher-beat"
  make_cmux_fakebin "$dir" >/dev/null
  # 1: target_exists -> surface_exists (list-panes) finds the surface.
  cmux_panes_response "$dir" 1 "$SF_A"
  # 2: workspace list --json for the worktree cwd probe.
  cmux_workspace_cwd_response "$dir" 2 "$WS_A" "my project shell" "$wt"

  out=$( FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" \
    FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    "$ADOPT" adopt-x --workspace "$WS_A" --surface "$SF_A" ) \
    || fail "fm-adopt.sh should succeed for a live surface"

  assert_grep "window=$WS_A:$SF_A" "$state/adopt-x.meta" "meta missing window=<ws>:<sf>"
  assert_grep "endpoint_task_id=adopt-x" "$state/adopt-x.meta" "meta missing endpoint_task_id"
  assert_grep "backend=cmux" "$state/adopt-x.meta" "meta missing backend=cmux"
  assert_grep "kind=adopted" "$state/adopt-x.meta" "meta missing kind=adopted"
  assert_grep "mode=adopted" "$state/adopt-x.meta" "meta missing mode=adopted"
  assert_grep "worktree=$wt" "$state/adopt-x.meta" "meta worktree= did not record the workspace's live cwd"
  assert_grep "cmux_workspace_id=$WS_A" "$state/adopt-x.meta" "meta missing cmux_workspace_id"
  assert_grep "cmux_surface_id=$SF_A" "$state/adopt-x.meta" "meta missing cmux_surface_id"
  assert_no_grep "tasktmp=" "$state/adopt-x.meta" "adopt must not write tasktmp="
  assert_contains "$out" "adopted adopt-x backend=cmux window=$WS_A:$SF_A worktree=$wt" \
    "adopt success line did not mirror fm-spawn's shape"
  pass "fm-adopt.sh: writes an adopted meta with window/backend/kind/worktree/cmux ids"
}

# --- 2. refuses a surface that is not live ----------------------------------

test_adopt_refuses_absent_surface() {
  local dir state out status
  dir="$TMP_ROOT/absent-surface"; state="$dir/state"
  mkdir -p "$state" "$dir/responses"
  touch "$state/.last-watcher-beat"
  make_cmux_fakebin "$dir" >/dev/null
  # 1: target_exists -> surface_exists sees no matching surface.
  cmux_panes_empty_response "$dir" 1

  out=$( FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" \
    FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    "$ADOPT" adopt-x --workspace "$WS_A" --surface "$SF_A" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-adopt.sh should refuse a non-live surface"
  assert_contains "$out" "no live cmux surface" "adopt refusal did not name the dead surface"
  assert_absent "$state/adopt-x.meta" "adopt must not write meta when the surface is not live"
  pass "fm-adopt.sh: refuses (non-zero + message) when the workspace/surface is not live"
}

# --- 3. adopt never spawns a workspace and never touches treehouse ----------

test_adopt_no_new_workspace_no_treehouse() {
  local dir state wt
  dir="$TMP_ROOT/no-spawn"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$dir/responses" "$wt"
  touch "$state/.last-watcher-beat"
  make_cmux_fakebin "$dir" >/dev/null
  add_logging_treehouse "$dir/fakebin" "$dir/treehouse-called"
  cmux_panes_response "$dir" 1 "$SF_A"
  cmux_workspace_cwd_response "$dir" 2 "$WS_A" "human shell" "$wt"

  FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" \
    FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    "$ADOPT" adopt-x --workspace "$WS_A" --surface "$SF_A" >/dev/null \
    || fail "fm-adopt.sh should succeed"

  assert_no_grep $'\x1f''new-workspace' "$dir/log" "adopt must never create a cmux workspace"
  assert_absent "$dir/treehouse-called" "adopt must never invoke treehouse (no worktree of its own)"
  pass "fm-adopt.sh: never calls new-workspace and never invokes treehouse"
}

# --- 4. teardown of an adopted task: no close-workspace, no treehouse, meta gone ---

test_teardown_adopted_leaves_workspace_removes_meta() {
  local dir state wt out rc
  dir="$TMP_ROOT/teardown-adopted"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$dir/config" "$dir/responses" "$wt"
  touch "$state/.last-watcher-beat" "$dir/log"
  make_cmux_fakebin "$dir" >/dev/null
  add_logging_treehouse "$dir/fakebin" "$dir/treehouse-called"
  write_adopted_meta "$state" adopt-x "$WS_A" "$SF_A" "$wt"

  FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    PATH="$dir/fakebin:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    "$TEARDOWN" adopt-x > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  out=$(cat "$dir/stdout")

  expect_code 0 "$rc" "teardown of an adopted task should succeed"
  ! grep -q REFUSED "$dir/stderr" || fail "teardown of an adopted task printed a REFUSED line"
  assert_no_grep $'\x1f''close-workspace' "$dir/log" "teardown must never close the human's cmux workspace"
  assert_absent "$dir/treehouse-called" "teardown of an adopted task must not invoke treehouse"
  assert_absent "$state/adopt-x.meta" "teardown must un-register the adopted task (remove its meta)"
  assert_contains "$out" "released" "teardown reminder should say the adoption was released, not prompt a PR done"
  pass "fm-teardown.sh: un-registers an adopted task without closing its workspace or running treehouse"
}

# --- 5. watcher exempts adopted windows from stale-pane wakes ----------------

test_watcher_skips_stale_for_adopted() {
  local dir state fb out capture window key pane_hash sig pid
  dir="$TMP_ROOT/watcher-adopted"; state="$dir/state"; fb="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  mkdir -p "$state" "$fb"
  window="test:fm-adopted-w"
  printf 'idle prompt, finished' > "$capture"
  # kind=adopted meta (tmux-shaped window so a broken skip WOULD capture+surface).
  printf 'window=%s\nkind=adopted\n' "$window" > "$state/adopted-w.meta"
  # A captain-relevant status with a primed .seen-* so the signal path stays quiet
  # and only the stale path could fire (it must not, for an adopted window).
  printf 'done: PR https://example.test/pr/9\n' > "$state/adopted-w.status"
  sig=$(seen_sig "$state/adopted-w.status"); printf '%s' "$sig" > "$state/.seen-adopted-w_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_pane_like "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Minimal fake tmux: recorded_windows reads the meta, but a broken skip would
  # capture via this before hashing.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"; exit 0 ;;
  capture-pane) [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # Fake fm-crew-state so a broken skip would read "not provably working" and surface.
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · fake\n'
exit 0
SH
  chmod +x "$fb/fm-crew-state.sh"

  PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fb/fm-crew-state.sh" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    reap "$pid"; fail "watcher exited for an adopted window's stale pane (should skip like a secondmate): $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "adopted stale printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "adopted stale enqueued a durable wake"; }
  reap "$pid"
  pass "fm-watch.sh: skips stale-pane wakes for kind=adopted windows (mirrors the secondmate exemption)"
}

# --- 6. peek/send target an adopted task by pure UUID (empty expected-label) --

test_peek_adopted_targets_by_uuid() {
  local dir state wt out
  dir="$TMP_ROOT/peek-adopted"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$dir/responses" "$wt"
  touch "$state/.last-watcher-beat"
  make_cmux_fakebin "$dir" >/dev/null
  write_adopted_meta "$state" adopt-x "$WS_A" "$SF_A" "$wt"
  # 1: capture's target_ready -> surface_exists (list-panes). 2: read-screen.
  cmux_panes_response "$dir" 1 "$SF_A"
  cmux_read_screen_response "$dir" 2 $'hello from the adopted surface'

  out=$( FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" \
    FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    "$PEEK" fm-adopt-x 5 ) || fail "fm-peek.sh should reach the surface for an adopted task"

  assert_contains "$out" "hello from the adopted surface" "peek did not return the adopted surface content"
  assert_grep $'\x1f''read-screen' "$dir/log" "peek did not reach cmux read-screen"
  # The empty expected-label means peek never does a scoped-title workspace-list
  # check (which would reject the human's own title).
  assert_no_grep $'\x1f''workspace'$'\x1f''list' "$dir/log" \
    "peek must target an adopted task by pure UUID, never a title check"
  pass "fm-peek.sh: reads an adopted task by pure UUID with an empty expected-label"
}

test_send_adopted_targets_by_uuid() {
  local dir state wt
  dir="$TMP_ROOT/send-adopted"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$dir/responses" "$wt"
  touch "$state/.last-watcher-beat"
  make_cmux_fakebin "$dir" >/dev/null
  write_adopted_meta "$state" adopt-x "$WS_A" "$SF_A" "$wt"
  # 1: send_literal target_ready; 2: send; 3: send_key target_ready; 4: send-key;
  # 5: composer_state capture target_ready; 6: read-screen -> empty composer.
  cmux_panes_response "$dir" 1 "$SF_A"
  cmux_panes_response "$dir" 3 "$SF_A"
  cmux_panes_response "$dir" 5 "$SF_A"
  cmux_read_screen_response "$dir" 6 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯\n\n  Enter:send'

  FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" \
    FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.01 FM_SEND_SETTLE=0 \
    "$SEND" fm-adopt-x "hello captain" || fail "fm-send.sh should submit to an adopted task"

  assert_grep $'\x1f''send'$'\x1f''--workspace'$'\x1f'"$WS_A"$'\x1f''--surface'$'\x1f'"$SF_A"$'\x1f''--'$'\x1f''hello captain' "$dir/log" \
    "send did not type the literal text to the adopted surface by UUID"
  assert_no_grep $'\x1f''workspace'$'\x1f''list' "$dir/log" \
    "send must target an adopted task by pure UUID, never a title check"
  pass "fm-send.sh: submits to an adopted task by pure UUID with an empty expected-label"
}

# --- refusal contract -------------------------------------------------------

test_adopt_refuses_non_cmux_backend() {
  local dir state out status
  dir="$TMP_ROOT/wrong-backend"; state="$dir/state"
  mkdir -p "$state"
  touch "$state/.last-watcher-beat"
  out=$( FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" \
    "$ADOPT" adopt-x --workspace "$WS_A" --backend tmux 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-adopt.sh should refuse a non-cmux backend"
  assert_contains "$out" "only the cmux backend" "adopt refusal did not name the cmux-only constraint"
  assert_absent "$state/adopt-x.meta" "adopt must not write meta on a rejected backend"
  pass "fm-adopt.sh: refuses a non-cmux backend with an actionable error"
}

test_adopt_refuses_already_registered() {
  local dir state wt out status
  dir="$TMP_ROOT/already-registered"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$wt"
  touch "$state/.last-watcher-beat"
  write_adopted_meta "$state" adopt-x "$WS_A" "$SF_A" "$wt"
  out=$( FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" \
    "$ADOPT" adopt-x --workspace "$WS_A" --surface "$SF_A" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-adopt.sh should refuse re-registering an existing task"
  assert_contains "$out" "already registered" "adopt refusal did not name the duplicate registration"
  pass "fm-adopt.sh: refuses when state/<id>.meta already exists"
}

# --- 10. refuses adopting the same live surface under a different id --------

test_adopt_refuses_duplicate_surface() {
  local dir state wt out status
  dir="$TMP_ROOT/dup-surface"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$dir/responses" "$wt"
  touch "$state/.last-watcher-beat"
  make_cmux_fakebin "$dir" >/dev/null
  # The same WS:SF is already supervised under a DIFFERENT task id.
  write_adopted_meta "$state" other-x "$WS_A" "$SF_A" "$wt"
  # 1: target_exists -> surface_exists (list-panes) finds the live surface, so
  #    the duplicate-window scan is what must reject it (not the liveness check).
  cmux_panes_response "$dir" 1 "$SF_A"

  out=$( FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" \
    FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    "$ADOPT" adopt-x --workspace "$WS_A" --surface "$SF_A" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-adopt.sh should refuse a surface already registered under another id"
  assert_contains "$out" "already registered as task 'other-x'" \
    "adopt refusal did not name the task already supervising the surface"
  assert_absent "$state/adopt-x.meta" "adopt must not write meta when the surface is a duplicate"
  pass "fm-adopt.sh: refuses adopting a surface already registered under a different task id"
}

# --- 11. crew-state liveness for a fresh adopted surface uses list-panes -----
# Regression: pane_readable for cmux must probe liveness with the structural
# list-panes existence check, NOT read-screen. read-screen fails on a genuinely
# fresh surface that has never been written to (docs/cmux-backend.md), so the old
# capture-based probe misreported a freshly-adopted, untouched surface as gone.

test_crew_state_fresh_adopted_surface_is_live() {
  local dir state wt out
  dir="$TMP_ROOT/crew-fresh"; state="$dir/state"; wt="$dir/live-cwd"
  mkdir -p "$state" "$dir/responses" "$wt"
  touch "$state/.last-watcher-beat"
  make_cmux_fakebin "$dir" >/dev/null
  write_adopted_meta "$state" adopt-x "$WS_A" "$SF_A" "$wt"
  printf 'working: implementing\n' > "$state/adopt-x.status"
  # 1: pane_readable -> surface_exists (list-panes) sees the live surface.
  cmux_panes_response "$dir" 1 "$SF_A"
  # 2: busy-check capture -> its own target_ready surface_exists (list-panes).
  cmux_panes_response "$dir" 2 "$SF_A"
  # 3: busy-check read-screen FAILS, exactly as it does on a fresh surface.
  printf '1' > "$dir/responses/3.exit"

  out=$( FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" \
    FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    "$CREW_STATE" adopt-x )

  assert_not_contains "$out" "backend target gone" \
    "crew-state misread a fresh adopted surface as gone (read-screen liveness regression)"
  assert_grep $'\x1f''list-panes' "$dir/log" "crew-state liveness did not use the structural list-panes probe"
  pass "fm-crew-state.sh: a fresh adopted cmux surface stays live via list-panes, not read-screen"
}

test_adopt_writes_meta
test_adopt_refuses_absent_surface
test_adopt_no_new_workspace_no_treehouse
test_teardown_adopted_leaves_workspace_removes_meta
test_watcher_skips_stale_for_adopted
test_peek_adopted_targets_by_uuid
test_send_adopted_targets_by_uuid
test_adopt_refuses_non_cmux_backend
test_adopt_refuses_already_registered
test_adopt_refuses_duplicate_surface
test_crew_state_fresh_adopted_surface_is_live
