#!/usr/bin/env bash
# Safety tests for the session-start Herdr husk sweep (bin/fm-herdr-husk-lib.sh,
# run by bin/fm-bootstrap.sh's herdr_husk_sweep), driven through the bootstrap
# executable against a scripted fake `herdr` and a fake `ps`.
#
# The fixture session holds one "firstmate" workspace whose tabs model the
# live cases: fm-x (no record, bare shell in the project: closed), fm-y (a
# task record exists: not a candidate, untouched), fm-z (an agent is running:
# kept), fm-w (a bare shell parked inside a claimed pool slot: kept), fm-v (a
# bare shell inside another task's recorded worktree: kept), a tab whose label
# is not a task label (never considered), plus the active-tab refusal, the
# journal rules, detect-only, and a stopped server.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-husk-sweep)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
REAL_JQ=$(command -v jq)

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

# Pane shell pids no real process can hold (macOS caps pids at 99998, Linux
# at 4194304), so nothing is ever signalled by mistake.
PID_X=4194310
PID_Y=4194320
PID_Z=4194330
PID_W=4194340
PID_V=4194350
PID_N=4194360

# make_fakebin <dir> builds the fake `herdr` whose panes come from
# FM_FAKE_HERDR_PANES ("<tab>|<pane>|<label>|<cwd>|<agent>|<idle>|<pid>" per
# line; agent is absent|live, idle is 1 for a lone idle shell), the fake `ps`
# that knows every listed pid, exit-0 stubs for the rest of the toolchain, the
# real jq, and a no-op sleep. Every invocation is logged to FM_FAKE_HERDR_LOG
# with its arguments joined by '|', and closed panes are recorded in
# FM_FAKE_HERDR_CLOSED. FM_FAKE_HERDR_ACTIVE_TAB and
# FM_FAKE_HERDR_FOREGROUND_REASON model the captain's viewer.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
PANES="${FM_FAKE_HERDR_PANES:?}"
LOG="${FM_FAKE_HERDR_LOG:?}"
CLOSED="${FM_FAKE_HERDR_CLOSED:?}"
args="$*"
printf '%s\n' "${args// /|}" >> "$LOG"
is_closed() { grep -qx -- "$1" "$CLOSED" 2>/dev/null; }
row() { awk -F'|' -v want="$1" -v col="$2" '$2 == want { print $col }' "$PANES"; }
row_by_tab() { awk -F'|' -v want="$1" -v col="$2" '$1 == want { print $col }' "$PANES"; }
active_tab() { printf '%s' "${FM_FAKE_HERDR_ACTIVE_TAB:-w1:t1}"; }
tab_json() { # <tab> <label>
  local focused=false
  [ "$1" != "$(active_tab)" ] || focused=true
  printf '{"tab_id":"%s","workspace_id":"w1","label":"%s","focused":%s,"pane_count":1}' "$1" "$2" "$focused"
}
pane_json() { # <pane>
  printf '{"pane_id":"%s","tab_id":"%s","workspace_id":"w1","cwd":"%s","foreground_cwd":"%s","agent_status":"unknown"}' \
    "$1" "$(row "$1" 1)" "$(row "$1" 4)" "$(row "$1" 4)"
}
list_tabs() {
  local first=1 tab pane label rest
  printf '['
  while IFS='|' read -r tab pane label rest; do
    [ -n "$tab" ] || continue
    is_closed "$pane" && continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    tab_json "$tab" "$label"
  done < "$PANES"
  printf ']'
}
list_panes() {
  local first=1 tab pane rest
  printf '['
  while IFS='|' read -r tab pane rest; do
    [ -n "$tab" ] || continue
    is_closed "$pane" && continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    pane_json "$pane"
  done < "$PANES"
  printf ']'
}
count() { list_tabs | tr -cd '{' | wc -c | tr -d ' '; }
case "${1:-} ${2:-} ${3:-}" in
  "status --json "*)
    if [ "${FM_FAKE_HERDR_SERVER_STOPPED:-0}" = 1 ]; then
      printf '{"client":{"version":"0.7.5","protocol":17},"server":{"running":false}}\n'
    else
      printf '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true,"protocol":17,"compatible":true}}\n'
    fi
    ;;
  "session list --json")
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s/herdr.sock"}]}\n' "${HERDR_SESSION:-default}" "$(dirname "$PANES")"
    ;;
  "terminal title clear")
    printf '{"result":{"reason":"%s"}}\n' "${FM_FAKE_HERDR_FOREGROUND_REASON:-no_foreground_client}"
    ;;
  "workspace list "*)
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}]}}\n' "$(active_tab)" "$(count)" "$(count)"
    ;;
  "tab list "*)
    printf '{"result":{"tabs":'; list_tabs; printf '}}\n'
    ;;
  "tab get "*)
    printf '{"result":{"tab":'; tab_json "$3" "$(row_by_tab "$3" 3)"; printf '}}\n'
    ;;
  "tab focus "*)
    : ;;
  "pane list "*)
    printf '{"result":{"panes":'; list_panes; printf '}}\n'
    ;;
  "pane get "*)
    if is_closed "$3" || [ -z "$(row "$3" 1)" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3"
      exit 1
    fi
    printf '{"result":{"pane":'; pane_json "$3"; printf '}}\n'
    ;;
  "pane process-info "*)
    pane=$4
    pid=$(row "$pane" 7)
    if [ "$(row "$pane" 6)" = 1 ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}\n' "$pane" "$pid" "$pid" "$pid"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"python3","argv0":"python3","argv":["python3","worker.py"]}]}}}\n' "$pane" "$pid" "$((pid + 1))" "$((pid + 1))"
    fi
    ;;
  "agent get "*)
    if [ "$(row "$3" 5)" = live ]; then
      printf '{"result":{"agent":{"agent":"claude","agent_status":"working"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$3"
      exit 1
    fi
    ;;
  "pane close "*)
    printf '%s\n' "$3" >> "$CLOSED"
    printf '{"result":{"type":"ok"}}\n'
    ;;
  "tab close "*|"workspace close "*)
    printf 'forbidden: %s\n' "$args" >> "$CLOSED"
    printf '{"result":{"type":"ok"}}\n'
    ;;
  *)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/fm-fake-ps" <<'SH'
#!/usr/bin/env bash
PANES="${FM_FAKE_HERDR_PANES:?}"
case "$*" in
  "-axo pid=,ppid=")
    printf '1 0\n'
    awk -F'|' 'NF { print $7 " 1"; if ($6 != 1) print ($7 + 1) " " $7 }' "$PANES"
    ;;
  "-p "*" -o stat=") printf 'S\n' ;;
  "-p "*" -o comm=")
    pid=$2
    if awk -F'|' -v p="$pid" '$7 == p { found=1 } END { exit(found ? 0 : 1) }' "$PANES"; then printf 'zsh\n'; else printf 'python3\n'; fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/fm-fake-ps"
  fm_fake_exit0 "$fakebin" tmux node git gh no-mistakes gh-axi chrome-devtools-axi tasks-axi quota-axi treehouse lavish-axi
  ln -s "$REAL_JQ" "$fakebin/jq"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> builds the home, the claimed-slot pool, the recorded
# worktree, and the default pane fixture.
make_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  POOL_DIR="$CASE_DIR/pool"
  FAKEBIN=$(make_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$PROJ_DIR" \
    "$POOL_DIR/3/repo" "$POOL_DIR/7/repo" "$POOL_DIR/9/repo"
  printf 'herdr\n' > "$HOME_DIR/config/backend"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  printf '{}\n' > "$POOL_DIR/treehouse-state.json"
  printf 'task=parked-lane\nhome=%s\n' "$HOME_DIR" > "$POOL_DIR/7/.fm-slot-owner"
  printf 'kind=scout\nworktree=%s\nbackend=herdr\nwindow=default:w1:p9\n' "$POOL_DIR/9/repo" > "$HOME_DIR/state/other-task.meta"
  printf 'kind=ship\nworktree=%s\nbackend=herdr\nwindow=default:w1:p3\n' "$POOL_DIR/3/repo" > "$HOME_DIR/state/y.meta"
  PANES="$CASE_DIR/panes.tsv"
  LOG="$CASE_DIR/herdr.log"
  CLOSED="$CASE_DIR/closed"
  : > "$LOG"; : > "$CLOSED"
  cat > "$PANES" <<EOF
w1:t1|w1:p1|1|$PROJ_DIR|absent|1|$PID_N
w1:t2|w1:p2|fm-x|$PROJ_DIR|absent|1|$PID_X
w1:t3|w1:p3|fm-y|$PROJ_DIR|absent|1|$PID_Y
w1:t4|w1:p4|fm-z|$PROJ_DIR|live|0|$PID_Z
w1:t5|w1:p5|fm-w|$POOL_DIR/7/repo|absent|1|$PID_W
w1:t6|w1:p6|fm-v|$POOL_DIR/9/repo|absent|1|$PID_V
w1:t7|w1:p7|fm-not a task|$PROJ_DIR|absent|1|$PID_N
EOF
}

run_bootstrap() {
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_BOOTSTRAP_NETWORK=skip FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_FAKE_HERDR_PANES="$PANES" FM_FAKE_HERDR_LOG="$LOG" FM_FAKE_HERDR_CLOSED="$CLOSED" \
    FM_HERDR_PS_BIN="$FAKEBIN/fm-fake-ps" "$@" "$BOOTSTRAP" 2>"$CASE_DIR/stderr" | grep '^BOOTSTRAP_INFO: herdr husk' || true
}

test_sweep_closes_only_the_orphan_bare_shell() {
  local out
  make_case sweep
  out=$(run_bootstrap env)
  assert_contains "$out" "BOOTSTRAP_INFO: herdr husk fm-x (default:w1:p2) closed" "fm-x was not reported closed"
  assert_contains "$out" "BOOTSTRAP_INFO: herdr husk fm-z (default:w1:p4) kept: its pane is not agent-free" "fm-z was not kept for its running agent"
  assert_contains "$out" "BOOTSTRAP_INFO: herdr husk fm-w (default:w1:p5) kept: its shell sits in claimed pool slot $POOL_DIR/7" "fm-w was not kept for its claimed slot"
  assert_contains "$out" "BOOTSTRAP_INFO: herdr husk fm-v (default:w1:p6) kept: its shell sits in the recorded worktree of task other-task" "fm-v was not kept for the recorded worktree"
  assert_not_contains "$out" "fm-y" "fm-y has a task record and must not be a candidate at all"
  assert_not_contains "$out" "fm-not a task" "a label that is not a task label must never be considered"
  [ "$(cat "$CLOSED")" = "w1:p2" ] || fail "expected exactly pane w1:p2 closed, got: $(cat "$CLOSED")"
  [ "$(grep -c '^pane|close|' "$LOG")" -eq 1 ] || fail "expected exactly one pane close in the runtime log"
  ! grep -q '^tab|close\|^workspace|close' "$LOG" || fail "the sweep issued a tab or workspace close"
  pass "the sweep closes exactly the orphan bare shell and names why each other candidate stays"
  out=$(run_bootstrap env)
  assert_not_contains "$out" "fm-x" "a second sweep found the closed husk again"
  [ "$(cat "$CLOSED")" = "w1:p2" ] || fail "a second sweep closed something: $(cat "$CLOSED")"
  pass "a repeat sweep is a no-op"
}

test_active_tab_refusal_keeps_the_husk() {
  local out
  make_case active
  out=$(run_bootstrap env FM_FAKE_HERDR_FOREGROUND_REASON=cleared FM_FAKE_HERDR_ACTIVE_TAB=w1:t2)
  assert_contains "$out" "BOOTSTRAP_INFO: herdr husk fm-x (default:w1:p2) kept: it is the captain's active tab" "the active tab was not kept"
  [ ! -s "$CLOSED" ] || fail "the captain's active tab was closed: $(cat "$CLOSED")"
  pass "the captain's attended active tab is never closed"
}

test_journal_rules() {
  local out token=AbCdEfGhIjKlMnOpQrStUv
  make_case journal
  # fm-x carries a version 1 journal whose token no workspace label shows: it
  # is retired with the pane. fm-w carries a version 2 journal naming a
  # DIFFERENT live pane: the tab is kept for that reason before anything else.
  printf 'version=1\ntask_id=x\nprojection_id=%s\n' "$token" > "$HOME_DIR/state/x.herdr-presentation"
  {
    printf 'version=2\ntask_id=w\nprojection_id=%s\n' "$token"
    printf 'home=%s\nsession=default\nworkspace_id=w1\ntab_id=w1:t1\npane_id=w1:p1\n' "$HOME_DIR"
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=└ w · p:%s\ntask_label=fm-w\n' "$token"
  } > "$HOME_DIR/state/w.herdr-presentation"
  out=$(run_bootstrap env)
  assert_contains "$out" "herdr husk fm-x (default:w1:p2) closed" "fm-x was not closed"
  [ ! -e "$HOME_DIR/state/x.herdr-presentation" ] || fail "the orphan version 1 journal was not retired after the close"
  assert_contains "$out" "herdr husk fm-w (default:w1:p5) kept: its presentation journal names live pane w1:p1" "fm-w was not kept for its journal"
  [ -e "$HOME_DIR/state/w.herdr-presentation" ] || fail "a journal naming a live pane was retired"
  pass "an orphan journal is retired only after its own pane is confirmed gone, and a journal naming a live pane protects the tab"
}

test_detect_only_and_stopped_server_touch_nothing() {
  local out
  make_case detect
  out=$(run_bootstrap env FM_BOOTSTRAP_DETECT_ONLY=1)
  [ -z "$out" ] || fail "detect-only printed husk lines: $out"
  [ ! -s "$CLOSED" ] || fail "detect-only closed a pane"
  pass "detect-only never sweeps"
  make_case stopped
  out=$(run_bootstrap env FM_FAKE_HERDR_SERVER_STOPPED=1)
  [ -z "$out" ] || fail "a stopped server printed husk lines: $out"
  ! grep -q '^tab|list' "$LOG" || fail "the sweep listed tabs on a stopped server"
  pass "a stopped server is left alone rather than started"
}

test_sweep_closes_only_the_orphan_bare_shell
test_active_tab_refusal_keeps_the_husk
test_journal_rules
test_detect_only_and_stopped_server_touch_nothing

echo "# all fm-herdr-husk-sweep tests passed"
