#!/usr/bin/env bash
# tests/fm-nm-review-pane.test.sh - behavior tests for bin/fm-nm-review-pane.sh,
# the one-review-pane-per-Herdr-no-mistakes-task owner, and its teardown hook.
#
# A stateful fake `herdr` (JSON state mutated with real jq) models the parts of
# Herdr the script relies on, each verified against the real binary and
# recorded in the script header: `pane split` returns the new pane in the same
# tab, `pane process-info` reports the foreground process (shell, a
# `no-mistakes attach` viewer, or the waiting loop's sleep), `send-keys q`
# detaches a viewer, `send-keys ctrl+c` interrupts the loop, `pane run`
# executes one shell string, and `pane close` makes `pane get` answer
# pane_not_found. A scripted fake `no-mistakes` answers `axi status` with the
# file $FM_FAKE_NM_STATUS. Every fake invocation is logged one line per call,
# unit-separated, so a case can assert exactly which calls happened.
#
# Matrix:
#   (a) not applicable: tmux backend, direct-PR mode, scout kind -> exit 3, no herdr call
#   (b) opt-out: config/nm-review-pane "off" -> exit 3, no herdr call; "ON",
#       empty, and garbage (with a warning) all stay enabled
#   (c) create-once: first call splits right of the worker pane in the
#       worktree, writes the record, starts the waiting loop
#   (d) reuse and no-op: same state again -> no split, no run, no keys
#   (e) re-point on a new run id: ctrl+c to the loop, attach --run <id>; the
#       same run again is a no-op; a newer run gets q then attach; one split total
#   (f) an other-branch run and a run whose branch is not the worktree's both
#       mean "no run yet" for a fresh pane, and a run: block for another branch
#       or no run at all leaves a pane already pointed at a run untouched
#   (g) a record whose pane is gone is recreated once; an ambiguous presence refuses
#   (h) teardown closes the review pane under the session lock and removes the
#       record; a pane that will not close keeps its record with a warning
#   (i) quiesce sends q once and only polls afterwards, so a viewer that exits
#       between polls never gets a stray q at its shell; a viewer that ignores
#       the first q gets it again only after several unchanged polls
#
# Fake knobs: FM_FAKE_HERDR_DETACH_LAG=<n> keeps a viewer listed by
# process-info for n reads after q (a second q in that window lands on the
# shell); FM_FAKE_HERDR_IGNORE_Q=<n> makes the viewer ignore its first n q keys.
# Any key that arrives while the shell is the foreground is appended to the
# pane's "typed" field, the observable stray-key evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

SCRIPT="$ROOT/bin/fm-nm-review-pane.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-review-pane-tests)
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

# make_case <name>: a home (state/data/config), a fakebin with the stateful
# herdr and the scripted no-mistakes, a git worktree on branch fm/<name>, and
# a herdr state holding the worker pane w1:p2 in tab w1:t2 of workspace w1.
make_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$fakebin" "$dir/project"
  git init -q -b main "$dir/wt"
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" checkout -q -b "fm/$name"
  : > "$dir/herdr.log"
  : > "$dir/nm.log"
  : > "$dir/nm-status.txt"
  cat > "$dir/herdr-state.json" <<'JSON'
{"panes":{"w1:p2":{"tab_id":"w1:t2","workspace_id":"w1","fg":"shell","run":""}},"next":3,"active_tab":"w1:t1"}
JSON
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE_FILE="${FM_FAKE_HERDR_STATE:?}"
LOG="${FM_FAKE_HERDR_LOG:?}"
{
  for a in "$@"; do printf '%s\x1f' "$a"; done
  printf '\n'
} >> "$LOG"
# Drop the trailing "--session <name>" the adapter always appends.
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  args=("${args[@]:0:$((n-2))}")
fi
set -- "${args[@]}"
state=$(cat "$STATE_FILE")
save() { printf '%s\n' "$1" > "$STATE_FILE"; }
pane_json() {  # <pane>
  printf '%s' "$state" | jq -c --arg p "$1" '.panes[$p] | select(. != null) | {pane_id:$p, tab_id, workspace_id}'
}
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true}}\n' ;;
  "session list")
    printf '{"sessions":[{"name":"%s","default":false,"running":true,"socket_path":"%s"}]}\n' "${HERDR_SESSION:-lab}" "${FM_FAKE_HERDR_SOCKET:?}" ;;
  "workspace list")
    printf '%s' "$state" | jq -c '{result:{workspaces:[{workspace_id:"w1",focused:true,active_tab_id:.active_tab}]}}' ;;
  "tab list")
    printf '%s' "$state" | jq -c '{result:{tabs:[{tab_id:.active_tab,focused:true,workspace_id:"w1"}]}}' ;;
  "pane list")
    printf '%s' "$state" | jq -c '{result:{panes:[.panes | to_entries[] | {pane_id:.key, tab_id:.value.tab_id}]}}' ;;
  "pane get")
    if [ "${FM_FAKE_HERDR_AMBIGUOUS:-0}" = 1 ]; then printf 'garbage\n'; exit 0; fi
    p=$(pane_json "$3")
    if [ -n "$p" ]; then printf '{"result":{"pane":%s}}\n' "$p"; else printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3"; exit 1; fi ;;
  "pane split")
    src=$3
    [ -n "$(pane_json "$src")" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    new="w1:p$(printf '%s' "$state" | jq -r .next)"
    state=$(printf '%s' "$state" | jq -c --arg s "$src" --arg n "$new" '.panes[$n] = {tab_id:.panes[$s].tab_id, workspace_id:"w1", fg:"shell", run:""} | .next += 1')
    save "$state"
    printf '{"result":{"pane":%s,"type":"pane_info"}}\n' "$(pane_json "$new")" ;;
  "pane process-info")
    p=$4
    if [ "$(printf '%s' "$state" | jq -r --arg p "$p" '.panes[$p].detach_after // empty')" != "" ]; then
      state=$(printf '%s' "$state" | jq -c --arg p "$p" '
        .panes[$p].detach_after -= 1
        | if .panes[$p].detach_after <= 0 then .panes[$p] |= (del(.detach_after) | .fg = "shell" | .run = "") else . end')
      save "$state"
    fi
    fg=$(printf '%s' "$state" | jq -r --arg p "$p" '.panes[$p].fg // empty')
    run=$(printf '%s' "$state" | jq -r --arg p "$p" '.panes[$p].run // empty')
    case "$fg" in
      shell) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"name":"zsh","argv":["/usr/bin/zsh"]}]}}}\n' "$p" ;;
      viewer) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"no-mistakes","argv":["no-mistakes","attach","--run","%s"]}]}}}\n' "$p" "$run" ;;
      loop) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":100,"foreground_process_group_id":300,"foreground_processes":[{"pid":300,"name":"sleep","argv":["sleep","5"]}]}}}\n' "$p" ;;
      *) printf '{"error":{"code":"pane_not_found"}}\n'; exit 1 ;;
    esac ;;
  "pane send-keys")
    p=$3; key=$4
    fg=$(printf '%s' "$state" | jq -r --arg p "$p" '.panes[$p].fg // empty')
    if [ "$fg" = shell ]; then
      state=$(printf '%s' "$state" | jq -c --arg p "$p" --arg k "$key" '.panes[$p].typed = ((.panes[$p].typed // "") + $k)')
    elif [ "$key" = q ] && [ "$fg" = viewer ]; then
      if [ "$(printf '%s' "$state" | jq -r --arg p "$p" '.panes[$p].detach_after // empty')" != "" ]; then
        state=$(printf '%s' "$state" | jq -c --arg p "$p" --arg k "$key" '.panes[$p] |= (del(.detach_after) | .fg = "shell" | .run = "" | .typed = ((.typed // "") + $k))')
      elif [ "$(printf '%s' "$state" | jq -r --arg p "$p" '.panes[$p].ignored_q // 0')" -lt "${FM_FAKE_HERDR_IGNORE_Q:-0}" ]; then
        state=$(printf '%s' "$state" | jq -c --arg p "$p" '.panes[$p].ignored_q = ((.panes[$p].ignored_q // 0) + 1)')
      elif [ "${FM_FAKE_HERDR_DETACH_LAG:-0}" -gt 0 ]; then
        state=$(printf '%s' "$state" | jq -c --arg p "$p" --argjson n "$FM_FAKE_HERDR_DETACH_LAG" '.panes[$p].detach_after = $n')
      else
        state=$(printf '%s' "$state" | jq -c --arg p "$p" '.panes[$p].fg = "shell" | .panes[$p].run = ""')
      fi
    elif [ "$key" = ctrl+c ] && [ "$fg" = loop ]; then
      state=$(printf '%s' "$state" | jq -c --arg p "$p" '.panes[$p].fg = "shell" | .panes[$p].run = ""')
    fi
    save "$state" ;;
  "pane run")
    p=$3; cmd=$4
    case "$cmd" in
      *"no-mistakes attach --run "*)
        run=${cmd##*--run }
        state=$(printf '%s' "$state" | jq -c --arg p "$p" --arg r "$run" '.panes[$p].fg = "viewer" | .panes[$p].run = $r') ;;
      *"while :; do"*) state=$(printf '%s' "$state" | jq -c --arg p "$p" '.panes[$p].fg = "loop"') ;;
    esac
    save "$state" ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_REFUSE_CLOSE:-0}" = 1 ]; then printf '{"error":{"code":"busy"}}\n'; exit 1; fi
    state=$(printf '%s' "$state" | jq -c --arg p "$3" 'del(.panes[$p])')
    save "$state"
    printf '{"result":{"type":"ok"}}\n' ;;
  *) printf '{"result":{"type":"ok"}}\n' ;;
esac
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_LOG:?}"
case "$1 $2" in
  "axi status") cat "${FM_FAKE_NM_STATUS:?}" ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/herdr" "$fakebin/no-mistakes" "$fakebin/treehouse" "$fakebin/tmux"
  printf '%s\n' "$dir"
}

write_meta() {  # <case> <id> [extra kv...]
  local dir=$1 id=$2
  shift 2
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/wt" "project=$dir/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "$@"
}

# run_script <case> <id> [args...]: run the script against the case; echoes rc.
run_script() {  # <case> <id> [args...]
  local dir=$1 id=$2 rc=0
  shift 2
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FM_FAKE_HERDR_STATE="$dir/herdr-state.json" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
    FM_FAKE_HERDR_SOCKET="$dir/herdr.sock" \
    FM_FAKE_NM_LOG="$dir/nm.log" FM_FAKE_NM_STATUS="$dir/nm-status.txt" \
    FM_NM_REVIEW_PANE_QUIESCE_SLEEP=0 \
    "$SCRIPT" "$id" "$@" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  printf '%s' "$rc"
}

herdr_calls() {  # <case> <verb> <subverb>
  tr '\037' ' ' < "$1/herdr.log" | grep -c "^$2 $3 " || true
}

pane_fg() {  # <case> <pane>
  jq -r --arg p "$2" '.panes[$p].fg // "gone"' "$1/herdr-state.json"
}

pane_run() {  # <case> <pane>
  jq -r --arg p "$2" '.panes[$p].run // ""' "$1/herdr-state.json"
}

pane_typed() {  # <case> <pane>
  jq -r --arg p "$2" '.panes[$p].typed // ""' "$1/herdr-state.json"
}

record_field() {  # <case> <id> <key>
  sed -n "s/^$3=//p" "$1/home/state/$2.nm-review-pane"
}

write_status_run() {  # <case> <run-id> <branch> [block-name]
  cat > "$1/nm-status.txt" <<EOF
current_branch: $3
${4:-run}:
  id: "$2"
  branch: $3
  status: running
  head: "abcdef12"
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,4
    review,running,0,10
branch_sync:
  state: pipeline_owned
EOF
}

write_status_none() {  # <case>
  printf 'current_branch: main\nruns_on_current_branch: 0\nruns: 0 runs yet in this repository\n' > "$1/nm-status.txt"
}

test_not_applicable_tasks_exit_silently() {
  local dir id rc
  dir=$(make_case na)
  write_status_none "$dir"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" "window=fm-$id" "worktree=$dir/wt" "kind=ship" "mode=no-mistakes"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 3 ] || fail "tmux task should be not applicable (rc=$rc): $(cat "$dir/stderr")"

  id=direct-task
  write_meta "$dir" "$id" "mode=direct-PR"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 3 ] || fail "direct-PR task should be not applicable (rc=$rc)"

  id=scout-task
  write_meta "$dir" "$id" "kind=scout"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 3 ] || fail "scout should be not applicable (rc=$rc)"

  rc=$(run_script "$dir" missing-task)
  [ "$rc" = 3 ] || fail "absent metadata should be not applicable (rc=$rc)"
  [ ! -s "$dir/herdr.log" ] || fail "not-applicable tasks must not touch herdr: $(cat "$dir/herdr.log")"
  [ ! -s "$dir/stderr" ] || fail "not-applicable exits must stay silent: $(cat "$dir/stderr")"
  pass "fm-nm-review-pane: non-herdr, non-no-mistakes, scout, and absent tasks exit 3 silently"
}

test_opt_out_disables_and_other_values_enable() {
  local dir id=optout rc
  dir=$(make_case optout)
  write_status_none "$dir"
  write_meta "$dir" "$id"

  printf ' OFF \n' > "$dir/home/config/nm-review-pane"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 3 ] || fail "opt-out should exit 3 (rc=$rc)"
  [ ! -s "$dir/herdr.log" ] || fail "opt-out must not touch herdr"
  [ ! -e "$dir/home/state/$id.nm-review-pane" ] || fail "opt-out must not write a record"

  printf 'ON\n' > "$dir/home/config/nm-review-pane"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "explicit on should run (rc=$rc): $(cat "$dir/stderr")"
  [ "$(herdr_calls "$dir" pane split)" = 1 ] || fail "explicit on should create the pane"

  dir=$(make_case optout-garbage)
  write_status_none "$dir"
  write_meta "$dir" "$id"
  printf 'maybe\n' > "$dir/home/config/nm-review-pane"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "garbage preference should stay enabled (rc=$rc): $(cat "$dir/stderr")"
  assert_contains "$(cat "$dir/stderr")" "unrecognized value" "garbage preference should warn"
  [ "$(herdr_calls "$dir" pane split)" = 1 ] || fail "garbage preference should still create the pane"

  dir=$(make_case optout-empty)
  write_status_none "$dir"
  write_meta "$dir" "$id"
  : > "$dir/home/config/nm-review-pane"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "empty preference file should stay enabled (rc=$rc)"
  [ ! -s "$dir/stderr" ] || fail "empty preference must not warn: $(cat "$dir/stderr")"
  pass "fm-nm-review-pane: config/nm-review-pane off disables; on, empty, and unrecognized values stay enabled"
}

test_create_once_reuse_and_repoint() {
  local dir id=flow rc pane split_line run_line
  dir=$(make_case flow)
  write_status_none "$dir"
  write_meta "$dir" "$id"

  # (c) create once: split right of the worker pane, in the worktree, no focus
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "first call failed (rc=$rc): $(cat "$dir/stderr")"
  split_line=$(tr '\037' ' ' < "$dir/herdr.log" | grep '^pane split ')
  assert_contains "$split_line" "pane split w1:p2 --direction right --cwd $dir/wt --no-focus --session lab " "split must target the worker pane, split right, in the worktree, without focus"
  pane=$(record_field "$dir" "$id" pane)
  [ "$pane" = "w1:p3" ] || fail "record should hold the pane id herdr returned, got '$pane'"
  [ "$(record_field "$dir" "$id" session)" = lab ] || fail "record should hold the session"
  [ -z "$(record_field "$dir" "$id" run)" ] || fail "no run yet: record run must be empty"
  [ "$(record_field "$dir" "$id" viewer)" = wait ] || fail "no run yet: viewer must be the waiting loop"
  [ "$(pane_fg "$dir" w1:p3)" = loop ] || fail "the pane should be running the waiting loop"
  run_line=$(tr '\037' ' ' < "$dir/herdr.log" | grep '^pane run ')
  assert_contains "$run_line" "waiting for the first no-mistakes run of" "waiting loop must say what it waits for"
  assert_contains "$run_line" "' $id; sleep" "waiting loop must name the task"
  assert_contains "$run_line" "cd $dir/wt && " "viewer command must run in the worktree"
  [ "$(herdr_calls "$dir" pane process-info)" = 0 ] || fail "a fresh pane needs no quiesce read"
  [ "$(herdr_calls "$dir" pane send-keys)" = 0 ] || fail "a fresh pane needs no keys"

  # (d) reuse and no-op
  : > "$dir/herdr.log"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "second call failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(herdr_calls "$dir" pane split)" = 0 ] || fail "second call must not split again"
  [ "$(herdr_calls "$dir" pane run)" = 0 ] || fail "same state must not rerun the viewer"
  [ "$(herdr_calls "$dir" pane send-keys)" = 0 ] || fail "same state must send no keys"
  [ "$(herdr_calls "$dir" pane get)" = 1 ] || fail "reuse costs exactly one presence read, got $(herdr_calls "$dir" pane get)"
  grep -q '^axi status$' "$dir/nm.log" || fail "the status call is the cost of a no-op"

  # (e) first run appears: interrupt the loop, attach
  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNAAAAAAAAAAAAAAAAAAAAA "fm/$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "re-point failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(herdr_calls "$dir" pane split)" = 0 ] || fail "re-point must reuse the pane"
  tr '\037' ' ' < "$dir/herdr.log" | grep -q '^pane send-keys w1:p3 ctrl+c ' || fail "the waiting loop must be interrupted with ctrl+c: $(cat "$dir/herdr.log")"
  tr '\037' ' ' < "$dir/herdr.log" | grep -q '^pane send-keys w1:p3 q ' && fail "no viewer was attached, so q must not be sent"
  run_line=$(tr '\037' ' ' < "$dir/herdr.log" | grep '^pane run ')
  assert_contains "$run_line" "no-mistakes attach --run 01RUNAAAAAAAAAAAAAAAAAAAAA" "viewer must attach to the run id"
  [ "$(record_field "$dir" "$id" run)" = 01RUNAAAAAAAAAAAAAAAAAAAAA ] || fail "record must hold the pointed run"
  [ "$(record_field "$dir" "$id" viewer)" = attach ] || fail "record viewer must be attach"
  [ "$(pane_fg "$dir" w1:p3)" = viewer ] || fail "the pane should now run the viewer"

  # same run again: no-op
  : > "$dir/herdr.log"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "same-run call failed (rc=$rc)"
  [ "$(herdr_calls "$dir" pane run)" = 0 ] || fail "same run must not rerun the viewer"
  [ "$(herdr_calls "$dir" pane send-keys)" = 0 ] || fail "same run must send no keys"

  # a newer run: detach with q, attach to the new id
  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNBBBBBBBBBBBBBBBBBBBBB "fm/$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "second re-point failed (rc=$rc): $(cat "$dir/stderr")"
  tr '\037' ' ' < "$dir/herdr.log" | grep -q '^pane send-keys w1:p3 q ' || fail "the previous viewer must be detached with q"
  tr '\037' ' ' < "$dir/herdr.log" | grep -q '^pane send-keys w1:p3 ctrl+c ' && fail "a detached viewer leaves a shell; ctrl+c must not be sent"
  run_line=$(tr '\037' ' ' < "$dir/herdr.log" | grep '^pane run ')
  assert_contains "$run_line" "no-mistakes attach --run 01RUNBBBBBBBBBBBBBBBBBBBBB" "viewer must follow the newer run"
  [ "$(record_field "$dir" "$id" run)" = 01RUNBBBBBBBBBBBBBBBBBBBBB ] || fail "record must advance to the newer run"
  [ "$(herdr_calls "$dir" pane split)" = 0 ] || fail "exactly one pane over the whole flow"
  [ "$(jq '.panes | length' "$dir/herdr-state.json")" = 2 ] || fail "worker pane plus exactly one review pane expected"
  pass "fm-nm-review-pane: create once, reuse as a no-op, re-point on each new run id, one pane total"
}

test_other_branch_runs_are_not_this_tasks_run() {
  local dir id=branchy rc
  dir=$(make_case branchy)
  write_meta "$dir" "$id"

  write_status_run "$dir" 01RUNOTHERAAAAAAAAAAAAAAAA fm/some-other-task other_branch_run
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "other-branch call failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(record_field "$dir" "$id" viewer)" = wait ] || fail "an other_branch_run block is not this task's run"
  [ -z "$(record_field "$dir" "$id" run)" ] || fail "record run must stay empty on an other-branch run"

  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNMISMATCHAAAAAAAAAAAAA fm/not-this-branch
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "branch-mismatch call failed (rc=$rc)"
  [ "$(herdr_calls "$dir" pane run)" = 0 ] || fail "a run: block for another branch must not re-point the pane"
  [ -z "$(record_field "$dir" "$id" run)" ] || fail "record run must stay empty on a branch mismatch"
  pass "fm-nm-review-pane: only the worktree branch's own run: block counts as the current run"
}

test_foreign_branch_run_and_missing_run_leave_pointed_pane_alone() {
  local dir id=foreign rc
  dir=$(make_case foreign)
  write_meta "$dir" "$id"
  write_status_run "$dir" 01RUNMINEAAAAAAAAAAAAAAAAA "fm/$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "setup attach failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(pane_fg "$dir" w1:p3)" = viewer ] || fail "setup: the pane should run the viewer"
  [ "$(record_field "$dir" "$id" run)" = 01RUNMINEAAAAAAAAAAAAAAAAA ] || fail "setup: record must hold the run"

  # another ship task's run is the repo-wide top-level run: block
  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNTHEIRSAAAAAAAAAAAAAAA fm/other-ship-task
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "foreign-branch call failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(herdr_calls "$dir" pane send-keys)" = 0 ] || fail "another branch's run must not detach the live viewer: $(cat "$dir/herdr.log")"
  [ "$(herdr_calls "$dir" pane run)" = 0 ] || fail "another branch's run must not re-point the pane"
  [ "$(pane_fg "$dir" w1:p3)" = viewer ] || fail "the viewer must still be attached after a foreign-branch status"
  [ "$(pane_run "$dir" w1:p3)" = 01RUNMINEAAAAAAAAAAAAAAAAA ] || fail "the viewer must still follow this task's run"
  [ "$(record_field "$dir" "$id" run)" = 01RUNMINEAAAAAAAAAAAAAAAAA ] || fail "record must keep this task's run"
  [ "$(record_field "$dir" "$id" viewer)" = attach ] || fail "record viewer must stay attach"

  # no run at all against a record that names one: a run id never disappears
  : > "$dir/herdr.log"
  write_status_none "$dir"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "no-run call failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(herdr_calls "$dir" pane send-keys)" = 0 ] || fail "a pointed pane must never be sent back to the waiting loop: $(cat "$dir/herdr.log")"
  [ "$(herdr_calls "$dir" pane run)" = 0 ] || fail "a pointed pane must not be re-pointed at the waiting loop"
  [ "$(pane_fg "$dir" w1:p3)" = viewer ] || fail "the viewer must survive a status without a run"
  [ "$(record_field "$dir" "$id" run)" = 01RUNMINEAAAAAAAAAAAAAAAAA ] || fail "record must keep the run when status shows none"

  # this task's next run still re-points
  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNMINEBBBBBBBBBBBBBBBBB "fm/$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "own next run failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(pane_run "$dir" w1:p3)" = 01RUNMINEBBBBBBBBBBBBBBBBB ] || fail "this task's next run must still re-point the pane"
  [ "$(herdr_calls "$dir" pane split)" = 0 ] || fail "the whole sequence must reuse one pane"

  # a fresh pane with only another branch's run: block still gets the waiting loop
  id=foreign-fresh
  dir=$(make_case "$id")
  write_meta "$dir" "$id"
  write_status_run "$dir" 01RUNTHEIRSAAAAAAAAAAAAAAA fm/other-ship-task
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "fresh foreign-branch call failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(herdr_calls "$dir" pane split)" = 1 ] || fail "a fresh pane must still be created under a foreign-branch status"
  [ "$(pane_fg "$dir" w1:p3)" = loop ] || fail "a fresh pane under a foreign-branch status runs the waiting loop"
  [ "$(record_field "$dir" "$id" viewer)" = wait ] || fail "fresh record viewer must be wait"
  [ -z "$(record_field "$dir" "$id" run)" ] || fail "fresh record run must be empty"
  pass "fm-nm-review-pane: another branch's run or no run leaves a pointed pane alone; a fresh pane still waits"
}

test_quiesce_sends_detach_key_once_and_resends_after_unchanged_polls() {
  local dir id=lag rc
  dir=$(make_case lag)
  write_meta "$dir" "$id"
  write_status_run "$dir" 01RUNLAGAAAAAAAAAAAAAAAAAA "fm/$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "setup attach failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(pane_fg "$dir" w1:p3)" = viewer ] || fail "setup: the pane should run the viewer"

  # the viewer is still listed for two polls after q, then gone
  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNLAGBBBBBBBBBBBBBBBBBB "fm/$id"
  rc=$(FM_FAKE_HERDR_DETACH_LAG=2 run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "lagging re-point failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(tr '\037' ' ' < "$dir/herdr.log" | grep -c '^pane send-keys w1:p3 q ')" = 1 ] || fail "q must be sent exactly once while the viewer is exiting: $(cat "$dir/herdr.log")"
  [ -z "$(pane_typed "$dir" w1:p3)" ] || fail "no key may reach the shell prompt, got typed '$(pane_typed "$dir" w1:p3)'"
  [ "$(herdr_calls "$dir" pane process-info)" -ge 3 ] || fail "the pane must be polled until the shell shows"
  [ "$(pane_fg "$dir" w1:p3)" = viewer ] || fail "the new viewer should be running"
  [ "$(pane_run "$dir" w1:p3)" = 01RUNLAGBBBBBBBBBBBBBBBBBB ] || fail "the new viewer must follow the newer run"
  [ "$(record_field "$dir" "$id" run)" = 01RUNLAGBBBBBBBBBBBBBBBBBB ] || fail "record must advance to the newer run"

  # a viewer that swallows the first q gets it again only after unchanged polls
  id=ignore
  dir=$(make_case "$id")
  write_meta "$dir" "$id"
  write_status_run "$dir" 01RUNIGNAAAAAAAAAAAAAAAAAA "fm/$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "setup attach failed (rc=$rc): $(cat "$dir/stderr")"
  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNIGNBBBBBBBBBBBBBBBBBB "fm/$id"
  rc=$(FM_FAKE_HERDR_IGNORE_Q=1 FM_NM_REVIEW_PANE_QUIESCE_RESEND_POLLS=3 run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "re-point after an ignored q failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(tr '\037' ' ' < "$dir/herdr.log" | grep -c '^pane send-keys w1:p3 q ')" = 2 ] || fail "q must be re-sent once after the unchanged polls: $(cat "$dir/herdr.log")"
  [ "$(herdr_calls "$dir" pane process-info)" -ge 5 ] || fail "three unchanged polls must pass before the re-send, got $(herdr_calls "$dir" pane process-info) polls"
  [ -z "$(pane_typed "$dir" w1:p3)" ] || fail "no key may reach the shell prompt, got typed '$(pane_typed "$dir" w1:p3)'"
  [ "$(pane_run "$dir" w1:p3)" = 01RUNIGNBBBBBBBBBBBBBBBBBB ] || fail "the new viewer must follow the newer run"

  # a viewer that never detaches within the budget refuses without a run
  id=stuck
  dir=$(make_case "$id")
  write_meta "$dir" "$id"
  write_status_run "$dir" 01RUNSTKAAAAAAAAAAAAAAAAAA "fm/$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "setup attach failed (rc=$rc): $(cat "$dir/stderr")"
  : > "$dir/herdr.log"
  write_status_run "$dir" 01RUNSTKBBBBBBBBBBBBBBBBBB "fm/$id"
  rc=$(FM_FAKE_HERDR_IGNORE_Q=99 FM_NM_REVIEW_PANE_QUIESCE_POLLS=4 run_script "$dir" "$id")
  [ "$rc" = 1 ] || fail "a viewer that will not detach must refuse with rc 1 (rc=$rc)"
  assert_contains "$(cat "$dir/stderr")" "could not be returned to its shell" "stuck viewer must warn"
  [ "$(herdr_calls "$dir" pane run)" = 0 ] || fail "nothing may be run into a busy pane"
  [ "$(record_field "$dir" "$id" run)" = 01RUNSTKAAAAAAAAAAAAAAAAAA ] || fail "record must keep the old run when the re-point is refused"
  pass "fm-nm-review-pane: quiesce sends q once, polls for the shell, re-sends only after unchanged polls, and refuses a stuck viewer"
}

test_dead_pane_recreated_and_ambiguous_presence_refuses() {
  local dir id=recreate rc
  dir=$(make_case recreate)
  write_status_none "$dir"
  write_meta "$dir" "$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "initial create failed (rc=$rc)"
  [ "$(record_field "$dir" "$id" pane)" = "w1:p3" ] || fail "expected w1:p3 first"

  # The captain closed the review pane by hand: recreate exactly once.
  state=$(jq -c 'del(.panes["w1:p3"])' "$dir/herdr-state.json")
  printf '%s\n' "$state" > "$dir/herdr-state.json"
  : > "$dir/herdr.log"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "recreate failed (rc=$rc): $(cat "$dir/stderr")"
  [ "$(herdr_calls "$dir" pane split)" = 1 ] || fail "a gone pane must be recreated once"
  [ "$(record_field "$dir" "$id" pane)" = "w1:p4" ] || fail "record must move to the recreated pane"
  [ "$(record_field "$dir" "$id" viewer)" = wait ] || fail "recreated pane starts with the waiting loop"

  # Ambiguous presence: refuse without splitting or writing.
  : > "$dir/herdr.log"
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FM_FAKE_HERDR_STATE="$dir/herdr-state.json" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
    FM_FAKE_HERDR_SOCKET="$dir/herdr.sock" FM_FAKE_HERDR_AMBIGUOUS=1 \
    FM_FAKE_NM_LOG="$dir/nm.log" FM_FAKE_NM_STATUS="$dir/nm-status.txt" \
    "$SCRIPT" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" = 1 ] || fail "ambiguous presence must refuse with rc 1 (rc=$rc)"
  assert_contains "$(cat "$dir/stderr")" "ambiguous presence" "ambiguous presence must warn"
  [ "$(herdr_calls "$dir" pane split)" = 0 ] || fail "ambiguous presence must not split"
  [ "$(record_field "$dir" "$id" pane)" = "w1:p4" ] || fail "ambiguous presence must keep the record"
  pass "fm-nm-review-pane: a gone pane is recreated once; an ambiguous presence refuses and keeps the record"
}

# run_teardown <case> <id>: force teardown of a herdr task under the fakes.
run_teardown() {  # <case> <id>
  local dir=$1 id=$2 rc
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FM_FAKE_HERDR_STATE="$dir/herdr-state.json" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
    FM_FAKE_HERDR_SOCKET="$dir/herdr.sock" \
    FM_FAKE_NM_LOG="$dir/nm.log" FM_FAKE_NM_STATUS="$dir/nm-status.txt" \
    "$TEARDOWN" "$id" --force > "$dir/td.stdout" 2> "$dir/td.stderr"
  rc=$?
  set -e
  printf '%s' "$rc"
}

test_teardown_closes_review_pane_and_removes_record() {
  local dir id=cleanup rc
  dir=$(make_case cleanup)
  write_status_none "$dir"
  write_meta "$dir" "$id"
  touch "$dir/home/state/.last-watcher-beat"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "setup create failed (rc=$rc): $(cat "$dir/stderr")"
  [ -e "$dir/home/state/$id.nm-review-pane" ] || fail "setup record missing"

  : > "$dir/herdr.log"
  rc=$(run_teardown "$dir" "$id")
  [ "$rc" = 0 ] || fail "teardown failed (rc=$rc): $(cat "$dir/td.stderr")"
  tr '\037' ' ' < "$dir/herdr.log" | grep -q '^pane close w1:p3 ' || fail "teardown must close the review pane: $(cat "$dir/herdr.log")"
  tr '\037' ' ' < "$dir/herdr.log" | grep -q '^pane close w1:p2 ' || fail "teardown must still close the task pane"
  [ ! -e "$dir/home/state/$id.nm-review-pane" ] || fail "teardown must remove the review pane record"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "teardown must remove the task record"
  [ "$(pane_fg "$dir" w1:p3)" = gone ] || fail "review pane should be gone"
  pass "fm-teardown: closes the review pane under the session lock and removes its record"
}

test_close_refusal_retains_record_and_names_rerun() {
  local dir id=retain rc
  dir=$(make_case retain)
  write_status_none "$dir"
  write_meta "$dir" "$id"
  rc=$(run_script "$dir" "$id")
  [ "$rc" = 0 ] || fail "setup create failed (rc=$rc)"

  : > "$dir/herdr.log"
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FM_FAKE_HERDR_STATE="$dir/herdr-state.json" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
    FM_FAKE_HERDR_SOCKET="$dir/herdr.sock" FM_FAKE_HERDR_REFUSE_CLOSE=1 \
    "$SCRIPT" "$id" --close > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" = 1 ] || fail "a refused close must return 1 (rc=$rc): $(cat "$dir/stderr")"
  assert_contains "$(cat "$dir/stderr")" "not confirmed gone" "refused close must warn"
  assert_contains "$(cat "$dir/stderr")" "fm-nm-review-pane.sh $id --close" "refused close must name the rerun"
  [ -e "$dir/home/state/$id.nm-review-pane" ] || fail "refused close must retain the record"
  [ "$(pane_fg "$dir" w1:p3)" = loop ] || fail "refused close must leave the pane alone"

  : > "$dir/herdr.log"
  rc=$(run_script "$dir" "$id" --close)
  [ "$rc" = 0 ] || fail "--close rerun failed (rc=$rc): $(cat "$dir/stderr")"
  tr '\037' ' ' < "$dir/herdr.log" | grep -q '^pane close w1:p3 ' || fail "--close must close the review pane"
  [ ! -e "$dir/home/state/$id.nm-review-pane" ] || fail "--close must remove the record once the pane is gone"
  rc=$(run_script "$dir" "$id" --close)
  [ "$rc" = 0 ] || fail "--close with no record must be a quiet success (rc=$rc)"
  pass "fm-nm-review-pane: a refused close retains the record and names the rerun; the rerun retires it"
}

test_not_applicable_tasks_exit_silently
test_opt_out_disables_and_other_values_enable
test_create_once_reuse_and_repoint
test_other_branch_runs_are_not_this_tasks_run
test_foreign_branch_run_and_missing_run_leave_pointed_pane_alone
test_quiesce_sends_detach_key_once_and_resends_after_unchanged_polls
test_dead_pane_recreated_and_ambiguous_presence_refuses
test_teardown_closes_review_pane_and_removes_record
test_close_refusal_retains_record_and_names_rerun
