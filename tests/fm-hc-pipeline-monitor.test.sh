#!/usr/bin/env bash
# tests/fm-hc-pipeline-monitor.test.sh - the no-mistakes pipeline monitor for hc
# tasks, driven through bin/fm-hc-pipeline-monitor.sh's public observe and close
# commands against a fake herdr-core (FM_HC_BIN) and a fake no-mistakes on PATH.
# Oracle: one monitor per task at its active run, never a second, never a worker
# label, and close touches only labels owned by this task and home.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
MON="$ROOT/bin/fm-hc-pipeline-monitor.sh"
TMP_ROOT=$(fm_test_tmproot fm-hc-pipeline-monitor-tests)
HOMEDIR="$TMP_ROOT/home"
STATE="$HOMEDIR/state"
WT="$TMP_ROOT/wt"
FB="$TMP_ROOT/fakebin"
FAKE_HC_DIR="$TMP_ROOT/hc"
FAKE_NM_STATUS="$TMP_ROOT/nm-status"
mkdir -p "$STATE" "$WT" "$FB" "$FAKE_HC_DIR/terminals" "$HOMEDIR/config"
: > "$HOMEDIR/config/hc-pipeline-monitor"

# Fake herdr-core: terminals are files of label lines under $FAKE_HC_DIR/terminals.
cat > "$FB/hc" <<'SH'
#!/usr/bin/env bash
set -u
D="${FAKE_HC_DIR:?}"
T="$D/terminals"
printf '%s\n' "$*" >> "$D/log"
cmd=${1:-}; shift || true
labels=(); cwd=''; argv=(); pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --label) labels+=("$2"); shift 2 ;;
    --cwd) cwd=$2; shift 2 ;;
    --) shift; argv=("$@"); break ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
match() { # <file> : every requested label present in file
  local want
  for want in "${labels[@]+"${labels[@]}"}"; do grep -qxF "$want" "$1" || return 1; done
}
json_labels() { # <file>
  local out='{' first=1 k v
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    [ $first -eq 1 ] || out+=','
    first=0
    out+="\"$k\":\"$v\""
  done < "$1"
  printf '%s}' "$out"
}
case "$cmd" in
  ls)
    printf '{"terminals":['
    sep=''
    for f in "$T"/*; do
      [ -e "$f" ] || continue
      match "$f" || continue
      printf '%s{"address":"%s"}' "$sep" "$(basename "$f")"
      sep=','
    done
    printf ']}\n' ;;
  get)
    addr=${pos[0]:-}
    [ -f "$T/$addr" ] || { echo '{"error":"not_found"}' >&2; exit 3; }
    printf '{"state":"live","labels":%s}\n' "$(json_labels "$T/$addr")" ;;
  run)
    n=$(cat "$D/next" 2>/dev/null || echo 1)
    echo $((n + 1)) > "$D/next"
    addr="t$n"
    { printf '%s\n' "${labels[@]}"; printf 'cwd=%s\n' "$cwd"; printf 'argv=%s\n' "${argv[*]}"; } > "$T/$addr"
    printf '{"address":"%s"}\n' "$addr" ;;
  kill|rm)
    [ "$cmd" = rm ] && rm -f "$T/${pos[0]:-}"
    exit 0 ;;
  *) exit 1 ;;
esac
SH
# Fake no-mistakes: `axi status` prints the TOON fixture named by FAKE_NM_STATUS.
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = axi ] && [ "${2:-}" = status ] || exit 1
cat "${FAKE_NM_STATUS:?}"
SH
chmod +x "$FB/hc" "$FB/no-mistakes"

export FAKE_HC_DIR FAKE_NM_STATUS
export FM_HC_BIN="$FB/hc" PATH="$FB:$PATH" FM_HOME="$HOMEDIR" FM_ROOT_OVERRIDE="$HOMEDIR"
unset HC_SESSION HC_SOCKET HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE

write_meta() {  # <task> <backend>
  fm_write_meta "$STATE/$1.meta" "window=firstmate:fm-$1" "endpoint_task_id=$1" \
    "backend=$2" "hc_session=fmtest" "worktree=$WT" "kind=ship"
}
set_run() {  # <id> <status>
  printf 'id: %s\nstatus: %s\nbranch: fm/x\n' "$1" "$2" > "$FAKE_NM_STATUS"
}
count_terminals() { find "$FAKE_HC_DIR/terminals" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }
count_runs() { grep -c '^run ' "$FAKE_HC_DIR/log" 2>/dev/null || true; }
monitor_for() {  # <task> -> addresses carrying the monitor labels
  grep -l "^firstmate.monitor=fm-$1$" "$FAKE_HC_DIR"/terminals/* 2>/dev/null | xargs -r -n1 basename
}
run_mon() { bash "$MON" "$@"; }
hometag() { FM_ROOT=$HOMEDIR FM_HOME=$HOMEDIR bash -c ". \"$ROOT/bin/fm-backend-hometag-lib.sh\"; fm_backend_hometag"; }

test_observe_opens_nothing_without_flag() {
  rm -f "$HOMEDIR/config/hc-pipeline-monitor"
  write_meta t3 hc
  set_run run-3 running
  before=$(count_terminals)
  run_mon observe t3
  assert_equals "$before" "$(count_terminals)" "without config/hc-pipeline-monitor observe opens no monitor"
  : > "$HOMEDIR/config/hc-pipeline-monitor"
  pass "observe is opt-in and opens nothing without the flag"
}

test_observe_opens_one_monitor_for_active_run() {
  write_meta t1 hc
  set_run run-1 running
  run_mon observe t1
  assert_equals 1 "$(count_terminals)" "first active run opens exactly one monitor"
  addr=$(monitor_for t1)
  grep -qx 'argv=no-mistakes attach --run run-1' "$FAKE_HC_DIR/terminals/$addr" || fail "monitor attaches to the active run"
  grep -q '^firstmate.task=' "$FAKE_HC_DIR/terminals/$addr" && fail "monitor must never carry firstmate.task"
  grep -qx "firstmate.home=$(hometag)" "$FAKE_HC_DIR/terminals/$addr" || fail "monitor carries this home's tag"
  pass "observe opens one monitor for the active run without a worker label"
}

test_observe_same_run_is_idempotent() {
  before=$(count_runs)
  run_mon observe t1
  run_mon observe t1
  assert_equals 1 "$(count_terminals)" "re-observing the same run keeps one monitor"
  assert_equals "$before" "$(count_runs)" "re-observing the same run opens nothing new"
  pass "re-observing the same run is idempotent"
}

test_newer_run_replaces_monitor() {
  set_run run-2 running
  run_mon observe t1
  assert_equals 1 "$(count_terminals)" "a newer run replaces the monitor instead of adding one"
  addr=$(monitor_for t1)
  grep -qx 'argv=no-mistakes attach --run run-2' "$FAKE_HC_DIR/terminals/$addr" || fail "replacement attaches to the newer run"
  pass "a newer run replaces the monitor"
}

test_finished_run_leaves_monitor_alone() {
  set_run run-2 completed
  run_mon observe t1
  assert_equals 1 "$(count_terminals)" "a finished run neither opens nor closes a monitor"
  pass "a finished run changes nothing"
}

test_other_backend_is_untouched() {
  write_meta t2 tmux
  set_run run-9 running
  before=$(count_runs)
  run_mon observe t2
  assert_equals "$before" "$(count_runs)" "non-hc tasks never open a monitor"
  pass "non-hc tasks are skipped"
}

test_close_removes_only_owned_monitor() {
  # A foreign worker terminal in the same home must survive close.
  printf 'firstmate.task=t1\nfirstmate.home=%s\n' "$(hometag)" > "$FAKE_HC_DIR/terminals/t77"
  run_mon close t1
  assert_equals 0 "$(monitor_for t1 | wc -l | tr -d ' ')" "close removes the task's monitor"
  [ -f "$FAKE_HC_DIR/terminals/t77" ] || fail "close must not touch a worker terminal"
  rm -f "$FAKE_HC_DIR/terminals/t77"
  pass "close removes only this task's monitor"
}

test_close_is_noop_without_monitor() {
  run_mon close t1
  pass "close with no monitor succeeds"
}

fm_test_run \
  test_observe_opens_nothing_without_flag \
  test_observe_opens_one_monitor_for_active_run \
  test_observe_same_run_is_idempotent \
  test_newer_run_replaces_monitor \
  test_finished_run_leaves_monitor_alone \
  test_other_backend_is_untouched \
  test_close_removes_only_owned_monitor \
  test_close_is_noop_without_monitor
