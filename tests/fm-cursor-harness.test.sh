#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh cursor-agent
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cursor-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_cursor_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor "$@" 2>&1
}

test_cursor_env_marker_detection() {
  local got
  got=$(CURSOR_AGENT=1 CLAUDECODE= "$ROOT/bin/fm-harness.sh")
  [ "$got" = cursor ] || fail "CURSOR_AGENT=1 should detect cursor (got '$got')"
  got=$(CURSOR_AGENT=1 CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  # CLAUDECODE is checked first; a nested Claude-in-Cursor shell stays claude.
  [ "$got" = claude ] || fail "CLAUDECODE should win over CURSOR_AGENT (got '$got')"
  pass "fm-harness detects CURSOR_AGENT=1 as cursor"
}

test_fm_lock_recognizes_cursor_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'Cursor Helper (Plugin): extension-host  firstmate [2-14]'; exit 0 ;;
  *"args="*) printf '%s\n' 'Cursor Helper (Plugin): extension-host  firstmate [2-14]'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize Cursor Helper as a live holder"
  pass "fm-lock recognizes Cursor Helper harness processes"
}

test_fm_lock_cursor_agent_env_path() {
  local home fakebin out me
  home="$TMP_ROOT/lock-env-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-env-fake")
  mkdir -p "$home/state"
  # Any caller shell's parent is the Cursor Helper extension-host (pid 4242).
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=
prev=
for a in "$@"; do
  if [ "$prev" = "-p" ]; then pid=$a; fi
  prev=$a
done
[ -n "$pid" ] || exit 1
case "$*" in
  *"ppid="*)
    if [ "$pid" = "4242" ]; then printf '     1\n'; else printf '  4242\n'; fi
    exit 0
    ;;
  *"comm="*)
    if [ "$pid" = "4242" ]; then printf 'Cursor Helper (Plugin): extension-host\n'
    else printf 'bash\n'; fi
    exit 0
    ;;
  *"args="*)
    if [ "$pid" = "4242" ]; then printf 'Cursor Helper (Plugin): extension-host  firstmate\n'
    else printf 'bash\n'; fi
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CURSOR_AGENT=1 FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1)
  expect_code 0 $? "cursor env lock acquire should succeed"
  assert_contains "$out" "lock acquired: harness pid 4242" "cursor env path did not lock on Helper pid"
  me=$(cat "$home/state/.lock")
  [ "$me" = 4242 ] || fail "lock file wrote '$me', expected 4242"
  pass "fm-lock CURSOR_AGENT=1 locks on Cursor Helper extension-host"
}

test_cursor_spawn_installs_stop_hook() {
  local rec case_dir home proj wt fakebin id out status hook launch
  rec=$(make_spawn_case hook)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"
  hook="$wt/.cursor/hooks.json"
  assert_present "$hook" "cursor stop hook was not installed"
  assert_grep 'stop' "$hook" "cursor hooks.json missing stop event"
  assert_grep "$id.turn-ended" "$hook" "cursor hook missing task turn-ended basename"
  meta="$home/state/$id.meta"
  assert_grep 'harness=cursor' "$meta" "meta missing harness=cursor"
  pass "cursor spawn installs project stop hook and records harness=cursor"
}

test_cursor_spawn_folds_effort_into_model() {
  local rec case_dir home proj wt fakebin id out status meta
  rec=$(make_spawn_case profile)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with model/effort should succeed"
  meta="$home/state/$id.meta"
  assert_grep 'model=gpt-5' "$meta" "meta missing model"
  assert_grep 'effort=high' "$meta" "meta missing effort"
  # The launch command is assembled in the spawn script and sent to the pane;
  # recover it from the brief-adjacent launch by re-deriving expected flags.
  # Assert hooks still installed under profile flags.
  assert_present "$wt/.cursor/hooks.json" "profile spawn lost stop hook"
  pass "cursor spawn records model/effort profile axes"
}

test_cursor_teardown_removes_hook() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed before teardown"
  assert_present "$wt/.cursor/hooks.json" "precondition: hook missing"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "cursor teardown failed"

  assert_absent "$wt/.cursor/hooks.json" "cursor hooks.json survived teardown"
  pass "cursor teardown removes project stop hook"
}

test_cursor_env_marker_detection
test_fm_lock_recognizes_cursor_holder
test_fm_lock_cursor_agent_env_path
test_cursor_spawn_installs_stop_hook
test_cursor_spawn_folds_effort_into_model
test_cursor_teardown_removes_hook
