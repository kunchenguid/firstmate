#!/usr/bin/env bash
# Regression: a failed spawn must not leave `treehouse get` running or leave
# its pane open. A leftover get holds git locks on pooled copies and blocks
# the next launch. The preferred path leases non-interactively and cds the
# pane into that path; abort still returns the unpublished lease and closes
# the pane. The fallback interactive get is reaped from the pane process tree.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-abort-treehouse-get)
fm_git_identity fmtest fmtest@example.invalid

make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

# Recording tmux that logs every invocation, reports a non-isolated pane path
# so the spawn aborts after acquire, and on send-keys of interactive
# `treehouse get` starts a lock-holding get whose pid is exposed as pane_pid.
make_abort_fakebin() {
  local dir=$1 start_get=${2:-0} advertise_lease=${3:-1} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_pid}"*)
    if [ -n "${FM_FAKE_TREEHOUSE_GET_PIDFILE:-}" ] && [ -f "$FM_FAKE_TREEHOUSE_GET_PIDFILE" ]; then
      cat "$FM_FAKE_TREEHOUSE_GET_PIDFILE"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|set-window-option|kill-window) exit 0 ;;
  send-keys)
    case "$*" in
      *" treehouse get "*)
        if [ "${FM_FAKE_START_TREEHOUSE_GET:-0}" = 1 ]; then
          treehouse get >/dev/null 2>&1 &
          printf '%s\n' "$!" > "${FM_FAKE_TREEHOUSE_GET_PIDFILE:?}"
        fi
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
if [ -n "\${FM_FAKE_TREEHOUSE_LOG:-}" ]; then
  printf 'treehouse %s\\n' "\$*" >> "\$FM_FAKE_TREEHOUSE_LOG"
fi
if [ "\${1:-}" = get ] && [ "\${2:-}" = --help ]; then
  if [ "$advertise_lease" = 1 ]; then
    printf '%s\\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\\n' 'Usage: treehouse get'
  fi
  exit 0
fi
if [ "\${1:-}" = get ]; then
  lease=0
  shift
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --lease) lease=1 ;;
      --lease-holder) shift ;;
    esac
    shift || true
  done
  if [ "\$lease" = 1 ]; then
    path=\${FM_FAKE_TREEHOUSE_LEASE:-\${FM_FAKE_PANE_PATH:-}}
    [ -n "\$path" ] || exit 1
    printf '%s\\n' "\$path"
    exit 0
  fi
  if [ "$start_get" = 1 ]; then
    lock=\${FM_FAKE_TREEHOUSE_LOCK:?}
    exec 9>"\$lock"
    flock 9
    /bin/sleep 30
    exit 0
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

setup_abort_home() {
  local name=$1
  home="$TMP_ROOT/$name/home"
  proj=$(make_repo "$TMP_ROOT/$name/proj")
  mkdir -p "$home/data" "$TMP_ROOT/$name/notgit-root/plain" "$proj/sub"
  printf '%s\n' "$home"
}

prepare_abort_spawn() {
  local home=$1 id=$2
  fm_test_spawn_brief "$home" "$id" "abort after treehouse get for $id"
}

test_abort_after_lease_closes_pane_and_returns_slot() {
  local home proj fakebin rec log out status
  home=$(setup_abort_home lease-abort)
  proj="$TMP_ROOT/lease-abort/proj"
  fakebin=$(make_abort_fakebin "$TMP_ROOT/lease-abort/fake" 0 1)
  rec="$TMP_ROOT/lease-abort/tmux.log"
  log="$TMP_ROOT/lease-abort/treehouse.log"
  : > "$rec"
  : > "$log"
  fm_test_fake_sleep_noop "$fakebin"
  prepare_abort_spawn "$home" abort-lease-aa1

  out=$(
    GIT_CEILING_DIRECTORIES="$TMP_ROOT/lease-abort/notgit-root" \
    FM_TMUX_REC="$rec" FM_FAKE_TREEHOUSE_LOG="$log" \
      fm_test_run_spawn "$home" "$TMP_ROOT/lease-abort/notgit-root/plain" "$fakebin" \
      abort-lease-aa1 "$proj" codex --mode no-mistakes --yolo off
  ); status=$?
  expect_code 1 "$status" "lease spawn into a non-worktree dir should abort"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "lease abort lacked the isolation error"
  assert_absent "$home/state/abort-lease-aa1.meta" "aborted lease spawn must not record meta"
  assert_grep "treehouse get --lease --lease-holder abort-lease-aa1" "$log" \
    "aborting spawn did not lease under the task id"
  assert_no_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "lease-capable abort still sent interactive treehouse get to the pane"
  assert_grep "kill-window" "$rec" "aborted lease spawn did not close the failed pane"
  assert_grep "treehouse return --force --if-lease-holder abort-lease-aa1" "$log" \
    "aborted lease spawn did not return the unpublished lease"
  pass "fm-spawn: abort after lease closes the pane and returns the slot"
}

test_abort_after_interactive_get_reaps_get_and_closes_pane() {
  local home proj fakebin rec log pidfile lock out status pid
  home=$(setup_abort_home get-abort)
  proj="$TMP_ROOT/get-abort/proj"
  fakebin=$(make_abort_fakebin "$TMP_ROOT/get-abort/fake" 1 0)
  rec="$TMP_ROOT/get-abort/tmux.log"
  log="$TMP_ROOT/get-abort/treehouse.log"
  pidfile="$TMP_ROOT/get-abort/get.pid"
  lock="$TMP_ROOT/get-abort/HEAD.lock"
  : > "$rec"
  : > "$log"
  fm_test_fake_sleep_noop "$fakebin"
  prepare_abort_spawn "$home" abort-get-bb2

  out=$(
    GIT_CEILING_DIRECTORIES="$TMP_ROOT/get-abort/notgit-root" \
    FM_TMUX_REC="$rec" FM_FAKE_TREEHOUSE_LOG="$log" \
    FM_FAKE_START_TREEHOUSE_GET=1 \
    FM_FAKE_TREEHOUSE_GET_PIDFILE="$pidfile" \
    FM_FAKE_TREEHOUSE_LOCK="$lock" \
      fm_test_run_spawn "$home" "$TMP_ROOT/get-abort/notgit-root/plain" "$fakebin" \
      abort-get-bb2 "$proj" codex --mode no-mistakes --yolo off
  ); status=$?
  expect_code 1 "$status" "interactive-get spawn into a non-worktree dir should abort"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "interactive-get abort lacked the isolation error"
  assert_absent "$home/state/abort-get-bb2.meta" "aborted interactive-get spawn must not record meta"
  assert_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "treehouse without --lease must still send interactive get to the pane"
  assert_grep "kill-window" "$rec" "aborted interactive-get spawn did not close the failed pane"
  [ -f "$pidfile" ] || fail "interactive treehouse get was never started in the pane"
  pid=$(cat "$pidfile")
  case "$pid" in
    ''|*[!0-9]*) fail "interactive treehouse get pid was not recorded" ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "interactive treehouse get $pid was still running after spawn abort"
  fi
  pass "fm-spawn: abort after interactive get reaps the get and closes the pane"
}

test_abort_after_lease_closes_pane_and_returns_slot
test_abort_after_interactive_get_reaps_get_and_closes_pane

echo "# all fm-spawn-abort-treehouse-get tests passed"
