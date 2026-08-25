#!/usr/bin/env bash
# Behavioral coverage for opt-in completed-task Herdr views.
# Exercises the public teardown and list/dismiss commands with a stateful fake
# Herdr CLI; no test asserts implementation source text.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
VIEWS="$ROOT/bin/fm-completed-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-completed-view)

make_case() {
  local name=$1 root="$TMP_ROOT/$1" home="$TMP_ROOT/$1/home" fakebin="$TMP_ROOT/$1/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q --bare "$root/origin.git"
  git -C "$root/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$root/origin.git" "$root/seed" 2>/dev/null
  git -C "$root/seed" -c user.name=test -c user.email=test@example.invalid \
    commit -q --allow-empty -m baseline
  git -C "$root/seed" push -q origin main
  rm -rf "$root/seed"
  git clone -q "$root/origin.git" "$root/project"
  git -C "$root/project" remote set-head origin main
  git -C "$root/project" worktree add -q -b fm/task-view "$root/wt" main
  cat > "$home/state/task-view.meta" <<EOF
window=lab:wTask:pSource
endpoint_task_id=task-view
worktree=$root/wt
project=$root/project
kind=ship
mode=local-only
backend=herdr
herdr_session=lab
herdr_workspace_id=wTask
herdr_tab_id=wTask:tSource
herdr_pane_id=wTask:pSource
pr=https://github.com/example/repo/pull/42
EOF
  printf '%s\n' \
    'working: terminal output contains SECRET-RAW-SCROLLBACK' \
    'done: PR https://github.com/example/repo/pull/42 checks green' \
    > "$home/state/task-view.status"
  : > "$home/state/.last-watcher-beat"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_EXPECT_PRESTOP:-0}" = 1 ]; then
  [ -e "${FM_FAKE_SOURCE_CLOSED:?}" ] || {
    echo 'source pane was not stopped before worktree return' >&2
    exit 1
  }
  scans=$(wc -l < "${FM_FAKE_LSOF_LOG:?}" | tr -d '[:space:]')
  [ "$scans" -ge 2 ] || {
    echo 'worktree process ownership was not rechecked after endpoint stop' >&2
    exit 1
  }
fi
printf 'return\n' >> "${FM_FAKE_ORDER_LOG:?}"
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*)
    printf 'scan\n' >> "${FM_FAKE_LSOF_LOG:?}"
    printf 'scan\n' >> "${FM_FAKE_ORDER_LOG:?}"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'count: 0 (showing first 0)' 'pull_requests[]: []'
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
command="${1:-} ${2:-}"
case "$command" in
  "session list")
    printf '{"sessions":[{"name":"lab","running":true,"socket_path":"%s"}]}\n' "${FM_FAKE_SOCKET:?}"
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wAnchor","active_tab_id":"wAnchor:t1","focused":true},{"workspace_id":"wTask","active_tab_id":"wTask:tSource","focused":false}]}}'
    ;;
  "tab list")
    case " $* " in
      *" --workspace wAnchor "*)
        printf '%s\n' '{"result":{"tabs":[{"tab_id":"wAnchor:t1","workspace_id":"wAnchor","focused":true}]}}'
        ;;
      *" --workspace wTask "*)
        printf '{"result":{"tabs":['
        comma=
        if [ ! -e "${FM_FAKE_SOURCE_CLOSED:?}" ]; then
          printf '%s' '{"tab_id":"wTask:tSource","workspace_id":"wTask","label":"fm-task-view","focused":false}'
          comma=,
        fi
        if [ -e "${FM_FAKE_VIEW_CREATED:?}" ] && [ ! -e "${FM_FAKE_VIEW_CLOSED:?}" ]; then
          printf '%s' "$comma"
          printf '{"tab_id":"wTask:tDone","workspace_id":"wTask","label":"%s","focused":false}' "$(cat "${FM_FAKE_VIEW_LABEL:?}")"
        fi
        printf '%s\n' ']}}'
        ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "tab create")
    label=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --label ]; then label=$2; break; fi
      shift
    done
    printf '%s' "$label" > "${FM_FAKE_VIEW_LABEL:?}"
    : > "${FM_FAKE_VIEW_CREATED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"wTask:tDone"},"root_pane":{"pane_id":"wTask:pDone"}}}'
    ;;
  "tab get")
    if [ "${3:-}" = wTask:tDone ] && [ -e "${FM_FAKE_VIEW_CREATED:?}" ] && [ ! -e "${FM_FAKE_VIEW_CLOSED:?}" ]; then
      printf '{"result":{"tab":{"tab_id":"wTask:tDone","workspace_id":"wTask","label":"%s"}}}\n' "$(cat "${FM_FAKE_VIEW_LABEL:?}")"
    elif [ "${3:-}" = wAnchor:t1 ]; then
      printf '%s\n' '{"result":{"tab":{"tab_id":"wAnchor:t1","workspace_id":"wAnchor"}}}'
    else
      printf '%s\n' '{"error":{"code":"tab_not_found"}}'
      exit 1
    fi
    ;;
  "tab focus") exit 0 ;;
  "pane list") printf '%s\n' '{"result":{"panes":[]}}' ;;
  "pane get")
    case "${3:-}" in
      wTask:pSource)
        if [ -e "${FM_FAKE_SOURCE_CLOSED:?}" ]; then
          printf '%s\n' '{"error":{"code":"pane_not_found"}}'
          exit 1
        fi
        printf '%s\n' '{"result":{"pane":{"pane_id":"wTask:pSource","tab_id":"wTask:tSource","workspace_id":"wTask","foreground_cwd":"/task"}}}'
        ;;
      wTask:pDone)
        if [ ! -e "${FM_FAKE_VIEW_CREATED:?}" ] || [ -e "${FM_FAKE_VIEW_CLOSED:?}" ]; then
          printf '%s\n' '{"error":{"code":"pane_not_found"}}'
          exit 1
        fi
        printf '{"result":{"pane":{"pane_id":"wTask:pDone","tab_id":"wTask:tDone","workspace_id":"wTask","foreground_cwd":"%s"}}}\n' "${FM_FAKE_VIEW_DIR:?}"
        ;;
      *) printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
    esac
    ;;
  "pane run")
    [ "${3:-}" = wTask:pDone ] || exit 1
    printf '%s\n' "$*" >> "${FM_FAKE_RENDER_LOG:?}"
    ;;
  "pane close")
    case "${3:-}" in
      wTask:pSource)
        printf 'source-close\n' >> "${FM_FAKE_ORDER_LOG:?}"
        : > "${FM_FAKE_SOURCE_CLOSED:?}"
        ;;
      wTask:pDone) : > "${FM_FAKE_VIEW_CLOSED:?}" ;;
      *) exit 1 ;;
    esac
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    exit 1
    ;;
  "status --json")
    printf '%s\n' '{"client":{"protocol":19,"version":"0.8.0"},"server":{"running":true,"protocol":19,"version":"0.8.0"}}'
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/treehouse" "$fakebin/lsof" "$fakebin/no-mistakes" \
    "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/herdr"
  printf '%s\n' "$root"
}

run_teardown() {  # <case-root> [extra args]
  local root=$1 home="$1/home"; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  FM_TEARDOWN_GUARD_DONE=1 PATH="$root/fakebin:$PATH" \
  FM_FAKE_HERDR_LOG="$root/herdr.log" FM_FAKE_RENDER_LOG="$root/render.log" \
  FM_FAKE_SOCKET="$root/herdr.sock" FM_FAKE_SOURCE_CLOSED="$root/source.closed" \
  FM_FAKE_VIEW_CREATED="$root/view.created" FM_FAKE_VIEW_CLOSED="$root/view.closed" \
  FM_FAKE_VIEW_LABEL="$root/view.label" FM_FAKE_VIEW_DIR="$home/state/completed-task-views" \
  FM_FAKE_LSOF_LOG="$root/lsof.log" FM_FAKE_TREEHOUSE_LOG="$root/treehouse.log" \
  FM_FAKE_ORDER_LOG="$root/order.log" FM_FAKE_EXPECT_PRESTOP="${FM_FAKE_EXPECT_PRESTOP:-0}" \
    "$TEARDOWN" task-view "$@"
}

run_views() {  # <case-root> <args...>
  local root=$1 home="$1/home"; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  PATH="$root/fakebin:$PATH" FM_FAKE_HERDR_LOG="$root/herdr.log" \
  FM_FAKE_RENDER_LOG="$root/render.log" FM_FAKE_SOCKET="$root/herdr.sock" \
  FM_FAKE_SOURCE_CLOSED="$root/source.closed" FM_FAKE_VIEW_CREATED="$root/view.created" \
  FM_FAKE_VIEW_CLOSED="$root/view.closed" FM_FAKE_VIEW_LABEL="$root/view.label" \
  FM_FAKE_VIEW_DIR="$home/state/completed-task-views" \
    "$VIEWS" "$@"
}

test_default_off_and_unsupported_backends_fall_back() {
  local root home meta tmp
  root=$(make_case default-off)
  : > "$root/herdr.log"; : > "$root/render.log"; : > "$root/lsof.log"; : > "$root/treehouse.log"
  run_teardown "$root" > "$root/out" 2> "$root/err" || fail "default-off Herdr teardown failed: $(cat "$root/err")"
  assert_absent "$root/home/state/completed-task-views/task-view.view" "default-off teardown retained a completed view"
  assert_not_contains "$(cat "$root/herdr.log")" "tab create" "default-off teardown created a static tab"

  root=$(make_case unsupported-tmux)
  home="$root/home"
  meta="$home/state/task-view.meta"
  tmp="$meta.tmp"
  grep -vE '^backend=|^herdr_' "$meta" | sed 's#^window=.*#window=firstmate:fm-task-view#' > "$tmp"
  mv "$tmp" "$meta"
  printf 'on\n' > "$home/config/herdr-completed-task-views"
  cat > "$root/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/fakebin/tmux"
  : > "$root/herdr.log"; : > "$root/render.log"; : > "$root/lsof.log"; : > "$root/treehouse.log"
  run_teardown "$root" > "$root/out" 2> "$root/err" || fail "unsupported-backend fallback failed: $(cat "$root/err")"
  assert_grep 'completed-task views are supported only by Herdr' "$root/err" "unsupported fallback was not explicit"
  assert_absent "$home/state/completed-task-views/task-view.view" "unsupported backend retained a completed view"
  pass "completed-task views default off and an unsupported backend keeps ordinary cleanup"
}

test_opt_in_teardown_parks_sanitized_summary_then_explicit_dismisses() {
  local root home head out
  root=$(make_case opt-in)
  home="$root/home"
  printf 'on\n' > "$home/config/herdr-completed-task-views"
  : > "$root/herdr.log"; : > "$root/render.log"; : > "$root/lsof.log"; : > "$root/treehouse.log"
  head=$(git -C "$root/wt" rev-parse HEAD)

  FM_FAKE_EXPECT_PRESTOP=1 run_teardown "$root" > "$root/out" 2> "$root/err" \
    || fail "opt-in completed-view teardown failed: $(cat "$root/err")"
  assert_present "$home/state/completed-task-views/task-view.view" "opt-in teardown did not retain a view record"
  assert_present "$home/state/completed-task-views/task-view.summary" "opt-in teardown did not retain a static summary"
  assert_absent "$home/state/task-view.meta" "opt-in teardown left task metadata in active monitoring"
  assert_absent "$home/state/task-view.status" "opt-in teardown left task status in active monitoring"
  assert_contains "$(cat "$home/state/completed-task-views/task-view.view")" 'phase=parked' "view was not marked parked"
  cat > "$root/expected.summary" <<EOF
FIRSTMATE - COMPLETED TASK

Task: task-view
Outcome: Ship task completed.
PR: https://github.com/example/repo/pull/42
Delivered head: $head
Validation: Checks green.

This is a bounded static summary; terminal scrollback was not retained.
Dismiss: bin/fm-completed-view.sh dismiss task-view
EOF
  cmp -s "$root/expected.summary" "$home/state/completed-task-views/task-view.summary" \
    || fail "completed-task summary was not the expected deterministic sanitized output"
  assert_not_contains "$(cat "$home/state/completed-task-views/task-view.summary")" 'SECRET-RAW-SCROLLBACK' \
    "summary copied raw task status or terminal content"
  assert_contains "$(cat "$root/herdr.log")" 'pane close wTask:pSource --session lab' "agent pane was not closed"
  assert_not_contains "$(cat "$root/herdr.log")" 'pane read' "completed-view creation captured terminal scrollback"
  assert_contains "$(cat "$root/treehouse.log")" 'return --force ' "worktree was not returned after the endpoint stop proof"
  [ "$(wc -l < "$root/lsof.log" | tr -d '[:space:]')" -ge 2 ] \
    || fail "worktree ownership was not checked both before and after stopping the endpoint"
  [ "$(head -n 4 "$root/order.log" | tr '\n' ' ')" = 'scan source-close scan return ' ] \
    || fail "retained cleanup order was not scan, stop, re-scan, return: $(tr '\n' ' ' < "$root/order.log")"

  out=$(run_views "$root" list) || fail "completed-view list failed"
  assert_contains "$out" $'task-view\tparked\tlab\twTask\twTask:tDone\twTask:pDone\tpresent' \
    "list did not report the exact parked identity"
  run_views "$root" dismiss task-view > "$root/dismiss.out" 2> "$root/dismiss.err" \
    || fail "completed-view dismissal failed: $(cat "$root/dismiss.err")"
  assert_present "$root/view.closed" "dismiss did not close the exact parked pane"
  assert_absent "$home/state/completed-task-views/task-view.view" "dismiss retained the view record"
  assert_absent "$home/state/completed-task-views/task-view.summary" "dismiss retained the static summary"
  pass "opt-in teardown parks only a bounded sanitized summary, retires active monitoring, and supports exact list/dismiss"
}

test_retention_cap_uses_ordinary_cleanup_without_eviction() {
  local root home i
  root=$(make_case capacity)
  home="$root/home"
  printf 'on\n' > "$home/config/herdr-completed-task-views"
  mkdir -p "$home/state/completed-task-views"
  for i in 1 2 3 4 5 6 7 8; do
    printf 'occupied\n' > "$home/state/completed-task-views/old-$i.view"
  done
  : > "$root/herdr.log"; : > "$root/render.log"; : > "$root/lsof.log"; : > "$root/treehouse.log"
  run_teardown "$root" > "$root/out" 2> "$root/err" \
    || fail "capacity fallback teardown failed: $(cat "$root/err")"
  assert_grep 'completed-task view limit (8) reached' "$root/err" "capacity fallback was not explicit"
  assert_absent "$home/state/completed-task-views/task-view.view" "capacity fallback created a ninth record"
  for i in 1 2 3 4 5 6 7 8; do
    assert_present "$home/state/completed-task-views/old-$i.view" "capacity fallback evicted an existing view"
  done
  assert_not_contains "$(cat "$root/herdr.log")" "tab create" "capacity fallback created a Herdr tab"
  pass "completed-task view retention is hard-bounded without implicit eviction"
}

test_default_off_and_unsupported_backends_fall_back
test_opt_in_teardown_parks_sanitized_summary_then_explicit_dismisses
test_retention_cap_uses_ordinary_cleanup_without_eviction
