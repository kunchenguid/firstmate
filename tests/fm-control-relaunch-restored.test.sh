#!/usr/bin/env bash
# fm-control.sh relaunch / fm-spawn.sh --relaunch on a backend with NO
# recovery-grade agent-state classifier (zellij, cmux, orca).
#
# Such a backend cannot prove the previous agent exited, so an ordinary
# relaunch is refused there. The one bounded exception is a workspace that
# bin/fm-workspace.sh restore reconstructed (meta workspace_state=restored):
#   1. restored + recorded endpoint present -> the relaunch runs, skips the
#      unprovable exit step (journal exit_result=workspace-restored-agent-absent),
#      and delivers the launch into the recorded endpoint.
#   2. restored + recorded endpoint missing -> refused, nothing launched.
#   3. not restored -> refused for want of a classifier, nothing launched.
# The verified-backend (tmux) half lives in tests/fm-control-relaunch.test.sh.
#
# Hermetic: each backend CLI is a state-modelling fake that records every
# literal it is asked to type; no real session provider or agent is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch-restored)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

restored_cleanup() {
  local d
  if [ -f "$TMP_ROOT/.tasktmps" ]; then
    while IFS= read -r d; do
      case "$d" in /tmp/fm-rr*) rm -rf "$d" ;; esac
    done < "$TMP_ROOT/.tasktmps"
  fi
  rm -rf "$TMP_ROOT"
}
trap restored_cleanup EXIT

# --- fakes -------------------------------------------------------------------
#
# Every fake reads its world from $FM_FAKE_DIR:
#   endpoint   present iff the recorded endpoint exists
#   cwd        the directory the endpoint's shell sits in
#   typed      every literal text the backend was asked to type, one per line
#   keys       every named key the backend was asked to press
#   targets    the endpoint id each typed text / key was addressed to
#   label      the title the backend reports for the endpoint (zellij, cmux)

make_common_fakes() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# zellij: session "fmz", one tab (id 3, legacy bare title fm-<id>) holding one
# terminal pane (id 7). The cwd probe fm_backend_zellij_current_path types is
# answered on the dumped screen the way a real shell would echo it.
make_zellij_fake() {  # <dir>
  cat > "$1/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  --version) printf 'zellij 0.44.0\n'; exit 0 ;;
  list-sessions) printf 'fmz\n'; exit 0 ;;
esac
[ "${1:-}" = --session ] && [ "${3:-}" = action ] || exit 0
shift 3
case "${1:-}" in
  list-panes)
    if [ -e "$D/endpoint" ]; then
      printf '[{"id":7,"tab_id":3,"is_plugin":false}]\n'
    else
      printf '[]\n'
    fi ;;
  list-tabs)
    if [ -e "$D/endpoint" ]; then
      printf '[{"tab_id":3,"name":"%s"}]\n' "$(cat "$D/label")"
    else
      printf '[]\n'
    fi ;;
  paste)
    [ -e "$D/endpoint" ] || exit 1
    printf '%s\n' "${3:-}" >> "$D/targets"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
    printf '%s\n' "${2:-}" >> "$D/typed" ;;
  send-keys)
    [ -e "$D/endpoint" ] || exit 1
    printf '%s\n' "${3:-}" >> "$D/targets"
    printf '%s\n' "${4:-}" >> "$D/keys" ;;
  dump-screen)
    [ -e "$D/endpoint" ] || exit 1
    printf '__FM_ZELLIJ_CWD_BEGIN__\n%s\n__FM_ZELLIJ_CWD_END__\n$ \n' "$(cat "$D/cwd")" ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/zellij"
}

# cmux: workspace ws1 (titled with this home's scoped task title) holding one
# surface sf1. Same marker-echo cwd probe as zellij, read back as JSON.
make_cmux_fake() {  # <dir>
  cat > "$1/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
arg_after() {  # <flag> <argv...>
  local flag=$1; shift
  while [ $# -gt 1 ]; do
    [ "$1" != "$flag" ] || { printf '%s' "$2"; return 0; }
    shift
  done
}
case "${1:-}" in
  workspace)
    if [ -e "$D/endpoint" ]; then
      jq -n --arg t "$(cat "$D/label")" '{workspaces:[{id:"ws1",title:$t}]}'
    else
      printf '{"workspaces":[]}\n'
    fi ;;
  list-panes)
    if [ -e "$D/endpoint" ] && [ "$(arg_after --workspace "$@")" = ws1 ]; then
      printf '{"panes":[{"surface_ids":["sf1"]}]}\n'
    else
      printf '{"panes":[]}\n'
    fi ;;
  send)
    [ -e "$D/endpoint" ] || exit 1
    printf '%s\n' "$(arg_after --surface "$@")" >> "$D/targets"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
    printf '%s\n' "${2:-}" >> "$D/typed" ;;
  send-key)
    [ -e "$D/endpoint" ] || exit 1
    printf '%s\n' "$(arg_after --surface "$@")" >> "$D/targets"
    while [ $# -gt 1 ]; do shift; done
    printf '%s\n' "$1" >> "$D/keys" ;;
  read-screen)
    [ -e "$D/endpoint" ] || exit 1
    jq -n --arg t "$(printf '__FM_CMUX_CWD_BEGIN__\n%s\n__FM_CMUX_CWD_END__\n$ ' "$(cat "$D/cwd")")" '{text:$t}' ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/cmux"
}

# orca: one terminal, term1. Orca's terminal API has no cwd read at all; the
# worktree it binds to the recorded id is what `worktree show` reports.
make_orca_fake() {  # <dir>
  cat > "$1/fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
if [ "${1:-}" = worktree ] && [ "${2:-}" = show ]; then
  printf '{"ok":true,"result":{"worktree":{"path":"%s"}}}\n' "$(cat "$D/cwd")"
  exit 0
fi
[ "${1:-}" = terminal ] || { printf '{"ok":true,"result":{}}\n'; exit 0; }
verb=${2:-}
shift 2
terminal= text= enter=0 has_text=0
while [ $# -gt 0 ]; do
  case "$1" in
    --terminal) terminal=${2:-}; shift 2 ;;
    --text) text=${2:-}; has_text=1; shift 2 ;;
    --enter) enter=1; shift ;;
    *) shift ;;
  esac
done
if [ ! -e "$D/endpoint" ] || [ "$terminal" != term1 ]; then
  printf '{"ok":false,"error":{"code":"terminal_not_found","message":"terminal not found"}}\n'
  exit 1
fi
case "$verb" in
  read) printf '{"ok":true,"result":{"tail":["$ "]}}\n' ;;
  send)
    printf '%s\n' "$terminal" >> "$D/targets"
    [ "$has_text" = 0 ] || [ -z "$text" ] || printf '%s\n' "$text" >> "$D/typed"
    [ "$enter" = 0 ] || printf 'Enter\n' >> "$D/keys"
    printf '{"ok":true,"result":{}}\n' ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/orca"
}

# The title this home's cmux workspace carries for a task label, asked of the
# real adapter so the fake reports exactly what a real spawn would have set.
cmux_scoped_title() {  # <home> <label>
  FM_HOME=$1 FM_ROOT_OVERRIDE=$ROOT bash -c '
    . "$1/bin/fm-backend.sh" && fm_backend_source cmux && fm_backend_cmux_scoped_title "$2"
  ' _ "$ROOT" "$2"
}

# new_case <name> <backend> <id> -> echoes a case dir holding one ship task
# whose endpoint is recorded on <backend>, present, and sitting in its worktree.
new_case() {
  local name=$1 backend=$2 id=$3 dir home proj wt
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/$id" "$dir/fake"
  : > "$dir/fake/typed"; : > "$dir/fake/keys"; : > "$dir/fake/targets"
  : > "$dir/fake/endpoint"
  printf 'fm-%s' "$id" > "$dir/fake/label"
  fm_git_worktree "$proj" "$wt" "task-$id" >/dev/null
  printf '%s' "$wt" > "$dir/fake/cwd"
  cat > "$home/data/$id/brief.md" <<BRIEF
# Task
## Captain's intent
Exercise restored-workspace relaunch for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
BRIEF
  {
    case "$backend" in
      zellij)
        echo "window=fmz:7"
        echo "zellij_session=fmz"
        echo "zellij_tab_id=3"
        echo "zellij_pane_id=7"
        ;;
      cmux)
        echo "window=ws1:sf1"
        echo "cmux_workspace_id=ws1"
        echo "cmux_surface_id=sf1"
        ;;
      orca)
        echo "window=fm-$id"
        echo "terminal=term1"
        echo "orca_worktree_id=orca1::$wt"
        ;;
    esac
    echo "backend=$backend"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "/tmp/fm-$id" >> "$TMP_ROOT/.tasktmps"
  make_common_fakes "$dir"
  case "$backend" in
    zellij) make_zellij_fake "$dir" ;;
    cmux)
      make_cmux_fake "$dir"
      cmux_scoped_title "$home" "fm-$id" > "$dir/fake/label"
      ;;
    orca) make_orca_fake "$dir" ;;
  esac
  printf '%s\n' "$dir"
}

mark_restored() {  # <case-dir> <id>
  printf 'workspace_state=restored\n' >> "$1/home/state/$2.meta"
}

run_in_case() {  # <case-dir> <script> <args...>
  local dir=$1 script=$2; shift 2
  # Throwaway HOME: a claude launch pre-registers workspace trust in the
  # launching user's own store, which must never be the developer's.
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_BACKEND='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$script" "$@" 2>&1
}
run_control() { local dir=$1; shift; run_in_case "$dir" "$CONTROL" "$@"; }
run_spawn() { local dir=$1; shift; run_in_case "$dir" "$SPAWN" "$@"; }

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" 2>/dev/null | tail -1 | cut -d= -f2-
}

assert_nothing_typed() {  # <case-dir> <msg>
  [ ! -s "$1/fake/typed" ] || fail "$2"$'\n'"--- typed ---"$'\n'"$(cat "$1/fake/typed")"
  [ ! -s "$1/fake/keys" ] || fail "$2"$'\n'"--- keys ---"$'\n'"$(cat "$1/fake/keys")"
}

# The endpoint id each backend's launch must be addressed to, and the record
# keys that carry that identity.
endpoint_id() {  # <backend>
  case "$1" in zellij) printf '7' ;; cmux) printf 'sf1' ;; orca) printf 'term1' ;; esac
}
endpoint_target() {  # <backend> <id>
  case "$1" in zellij) printf 'fmz:7' ;; cmux) printf 'ws1:sf1' ;; orca) printf 'term1' ;; esac
}
endpoint_keys() {  # <backend>
  case "$1" in
    zellij) printf 'window backend zellij_session zellij_tab_id zellij_pane_id' ;;
    cmux) printf 'window backend cmux_workspace_id cmux_surface_id' ;;
    orca) printf 'window backend terminal orca_worktree_id' ;;
  esac
}
endpoint_identity() {  # <case-dir> <id> <backend>
  local key
  for key in $(endpoint_keys "$3"); do
    printf '%s=%s\n' "$key" "$(meta_field "$1" "$2" "$key")"
  done
}

assert_launch_delivered_to_recorded_endpoint() {  # <case-dir> <backend>
  local dir=$1 backend=$2 launches
  launches=$(grep -c -- 'encode launch-brief' "$dir/fake/typed")
  [ "$launches" = 1 ] \
    || fail "$backend: exactly one replacement launch should be typed into the endpoint, saw $launches"$'\n'"--- typed ---"$'\n'"$(cat "$dir/fake/typed")"
  assert_equals "$(endpoint_id "$backend")" "$(sort -u "$dir/fake/targets")" \
    "$backend: every input must be addressed to the recorded endpoint and nothing else"
  assert_no_grep "/exit" "$dir/fake/typed" "$backend: no exit command can be proven here, so none should be typed"
}

# --- 1. restored + endpoint present -> bounded relaunch -------------------------

check_restored_relaunch_succeeds() {  # <backend> <id>
  local backend=$1 id=$2 dir out rc before
  dir=$(new_case "ok-$backend" "$backend" "$id")
  mark_restored "$dir" "$id"
  before=$(endpoint_identity "$dir" "$id" "$backend")
  out=$(run_control "$dir" "$id" relaunch --note "review fixes after restore"); rc=$?
  expect_code 0 "$rc" "$backend: a restored workspace with its endpoint present should relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched $id harness=claude from=claude" "$backend: the outcome should name the transition"
  assert_contains "$out" "backend=$backend endpoint=$(endpoint_target "$backend" "$id")" \
    "$backend: the outcome should name the reused endpoint"
  assert_launch_delivered_to_recorded_endpoint "$dir" "$backend"
  assert_equals workspace-restored-agent-absent "$(journal_field "$dir" "$id" exit_result)" \
    "$backend: the journal should record that the exit step was skipped on the restore's proof"
  assert_equals complete "$(journal_field "$dir" "$id" phase)" "$backend: the transaction should complete"
  assert_equals "$before" "$(endpoint_identity "$dir" "$id" "$backend")" \
    "$backend: the published record must keep the exact endpoint identity it was restored with"
  assert_equals "$dir/wt" "$(meta_field "$dir" "$id" worktree)" "$backend: the reconstructed worktree must be reused"
  assert_grep "review fixes after restore" "$dir/home/data/$id/brief.md" \
    "$backend: the progress note should reach the replacement's instructions"
  pass "fm-control relaunch ($backend): a restored workspace relaunches into its recorded endpoint without an exit proof"
}

check_restored_spawn_relaunch_succeeds() {  # <backend> <id>
  local backend=$1 id=$2 dir out rc before
  dir=$(new_case "spawnok-$backend" "$backend" "$id")
  mark_restored "$dir" "$id"
  before=$(endpoint_identity "$dir" "$id" "$backend")
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "$backend: fm-spawn --relaunch should accept a restored workspace with its endpoint present"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "$backend: the launch should be reported"
  assert_launch_delivered_to_recorded_endpoint "$dir" "$backend"
  assert_equals "$before" "$(endpoint_identity "$dir" "$id" "$backend")" \
    "$backend: the published record must keep the exact endpoint identity it was restored with"
  pass "fm-spawn --relaunch ($backend): a restored workspace launches into its recorded endpoint"
}

check_restored_orca_relaunch_refuses_a_rebound_worktree() {  # <id>
  local id=$1 dir out rc
  dir=$(new_case spawnrebound-orca orca "$id")
  mark_restored "$dir" "$id"
  printf '%s' "$dir/somewhere-else" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "orca: a worktree id Orca binds to another path must refuse relaunch"$'\n'"$out"
  assert_contains "$out" "not its recorded worktree" "orca: the refusal should name the recorded worktree"
  assert_nothing_typed "$dir" "orca: a refused relaunch must type nothing into the terminal"
  pass "fm-spawn --relaunch (orca): a worktree id bound to another path refuses before anything is typed"
}

# --- 2. restored + endpoint missing -> refused ----------------------------------

check_restored_relaunch_refuses_a_missing_endpoint() {  # <backend> <id>
  local backend=$1 id=$2 dir out rc before
  dir=$(new_case "gone-$backend" "$backend" "$id")
  mark_restored "$dir" "$id"
  rm -f "$dir/fake/endpoint"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_control "$dir" "$id" relaunch --note "should not launch"); rc=$?
  expect_code 1 "$rc" "$backend: a restored workspace whose endpoint is gone should refuse"$'\n'"$out"
  assert_contains "$out" "reconstructed workspace has no recorded endpoint" "$backend: the refusal should name the missing endpoint"
  assert_contains "$out" "fm-workspace.sh restore $id" "$backend: the refusal should point at the restore to re-run"
  assert_nothing_typed "$dir" "$backend: a refused relaunch must send nothing anywhere"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "$backend: a refused relaunch must leave the record untouched"
  assert_absent "$dir/home/state/$id.control-relaunch" "$backend: a refusal before the checkpoint must not open a transaction"
  assert_no_grep "should not launch" "$dir/home/data/$id/brief.md" "$backend: a refused relaunch must not rewrite the instructions"

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "$backend: fm-spawn --relaunch should refuse a missing reconstructed endpoint"$'\n'"$out"
  assert_contains "$out" "reconstructed endpoint is missing" "$backend: fm-spawn's refusal should name the missing endpoint"
  assert_nothing_typed "$dir" "$backend: a refused fm-spawn --relaunch must send nothing anywhere"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "$backend: a refused fm-spawn --relaunch must leave the record untouched"
  pass "relaunch ($backend): a restored workspace whose endpoint is missing is refused by fm-control and fm-spawn alike"
}

# --- 3. not restored -> refused for want of a classifier -------------------------

check_unrestored_relaunch_is_refused() {  # <backend> <id> [workspace_state]
  local backend=$1 id=$2 ws=${3:-} dir out rc before
  dir=$(new_case "plain-$backend" "$backend" "$id")
  [ -z "$ws" ] || printf 'workspace_state=%s\n' "$ws" >> "$dir/home/state/$id.meta"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_control "$dir" "$id" relaunch --note "should not launch"); rc=$?
  expect_code 1 "$rc" "$backend: an ordinary relaunch on an unverified backend should refuse"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" "$backend: the refusal should name the missing classifier"
  assert_nothing_typed "$dir" "$backend: a refused relaunch must send nothing anywhere"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "$backend: a refused relaunch must leave the record untouched"
  assert_absent "$dir/home/state/$id.control-relaunch" "$backend: a refusal before the checkpoint must not open a transaction"

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "$backend: fm-spawn --relaunch should refuse an unrestored task on an unverified backend"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" "$backend: fm-spawn's refusal should name the missing classifier"
  assert_nothing_typed "$dir" "$backend: a refused fm-spawn --relaunch must send nothing anywhere"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "$backend: a refused fm-spawn --relaunch must leave the record untouched"
  pass "relaunch ($backend, workspace_state=${ws:-unset}): without a restored workspace the classifier refusal stands"
}

# --- runner -----------------------------------------------------------------
#
# Each check runs in its own subshell so one backend's failure cannot hide the
# others' results; the file fails if any check failed.

FAILED=0
run_check() {
  ( "$@" ) || FAILED=1
}

n=0
for backend in zellij cmux orca; do
  n=$((n + 1))
  run_check check_unrestored_relaunch_is_refused "$backend" "rrp$n"
  run_check check_restored_relaunch_refuses_a_missing_endpoint "$backend" "rrg$n"
  run_check check_restored_relaunch_succeeds "$backend" "rrk$n"
  run_check check_restored_spawn_relaunch_succeeds "$backend" "rrs$n"
done
# Only the exact restored marker opens the exception: a live or released
# workspace record is an ordinary relaunch.
run_check check_restored_orca_relaunch_refuses_a_rebound_worktree rrb1
run_check check_unrestored_relaunch_is_refused zellij rrp4 active
run_check check_unrestored_relaunch_is_refused zellij rrp5 released

exit "$FAILED"
