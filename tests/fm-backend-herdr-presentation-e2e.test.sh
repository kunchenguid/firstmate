#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for the default-on disposable single-task
# presentation projection, its explicit opt-out, and its best-effort
# owning-parent ordering across primary and secondmate homes.
# The test drives the real spawn and teardown scripts, a real Treehouse pool,
# and the guarded named-session lab helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-presentation.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
TREEHOUSE_CALL_LOG="$TMP_ROOT/treehouse-calls.log"
TREEHOUSE_LOCK_DIR="$TMP_ROOT/treehouse-call.lock"
MOVE_CALL_LOG="$TMP_ROOT/workspace-move-calls.log"
FOCUS_AUDIT_LOG="$TMP_ROOT/focus-audit.log"
ACTIVE_SEEDED_CONTROL="$TMP_ROOT/active-seeded-control"
POST_CREATE_ABORT_CONTROL="$TMP_ROOT/post-create-abort-control"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
: > "$TREEHOUSE_CALL_LOG"
: > "$MOVE_CALL_LOG"
: > "$FOCUS_AUDIT_LOG"
REAL_MOVER="$ROOT/bin/backends/herdr-workspace-move.py"
export REAL_HERDR REAL_TREEHOUSE REAL_MOVER HERDR_CALL_LOG TREEHOUSE_CALL_LOG TREEHOUSE_LOCK_DIR MOVE_CALL_LOG FOCUS_AUDIT_LOG HERDR_ORIGINAL_PATH HERDR_LAB_HELPER
export ACTIVE_SEEDED_CONTROL POST_CREATE_ABORT_CONTROL TMP_ROOT

# Log every production-adapter call, remove its already-validated trailing
# session flag, and send the operation through the lab helper so that helper
# remains the sole process which appends the real trailing session flag.
# The adapter's deliberately session-independent version read cannot pass the
# helper's leading-option guard, so the wrapper sends only that read straight
# to the absolute real binary with the same explicit trailing lab session.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last_index=$((${#args[@]} - 1))
flag_index=$((last_index - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag_index]}" = --session ] \
   && [ "${args[$last_index]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last_index]" "args[$flag_index]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}

arg_value() {
  local want=$1 previous= arg
  shift
  for arg in "$@"; do
    if [ "$previous" = "$want" ]; then
      printf '%s' "$arg"
      return 0
    fi
    previous=$arg
  done
  return 1
}

label=$(arg_value --label "$@" || true)
if [ "${1:-} ${2:-}" = "workspace list" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ]; then
  stage=$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)
  if [ "$stage" = task-created ]; then
    printf '%s\n' post-task-snapshot > "$ACTIVE_SEEDED_CONTROL/stage"
  elif [ "$stage" = post-task-snapshot ]; then
    seeded_tab=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-tab")
    inject_before=$(focus_snapshot || printf ambiguous/ambiguous)
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab focus "$seeded_tab" >/dev/null
    inject_after=$(focus_snapshot || printf ambiguous/ambiguous)
    printf 'active-seeded-inject\t%s\t%s\t%s\n' "$inject_before" "$inject_after" "$seeded_tab" >> "$FOCUS_AUDIT_LOG"
    printf '%s\n' injected > "$ACTIVE_SEEDED_CONTROL/stage"
  fi
fi

mutation=
mutation_target=${3:-}
case "${1:-} ${2:-}" in
  "workspace create") mutation=workspace-create; mutation_target=$label ;;
  "tab create") mutation=tab-create; mutation_target=$label ;;
  "pane close") mutation=pane-close ;;
  "tab focus") mutation=tab-focus ;;
esac
refusal_probe=0
if [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ] \
   && [ "$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)" = injected ] \
   && [ "${3:-}" = "$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane" 2>/dev/null || true)" ]; then
  refusal_probe=1
  refusal_before=$(focus_snapshot || printf ambiguous/ambiguous)
fi
before=
[ -z "$mutation" ] || before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"); then
  status=0
else
  status=$?
fi
if [ "$status" -eq 0 ] && [ "$mutation" = workspace-create ]; then
  case "$label" in
    $'└ active-seeded · p:'*)
      mkdir -p "$ACTIVE_SEEDED_CONTROL"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$ACTIVE_SEEDED_CONTROL/workspace"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-tab"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-pane"
      ;;
    $'└ abort-a · p:'*|$'└ abort-b · p:'*)
      task=${label#$'└ '}; task=${task%% *}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$POST_CREATE_ABORT_CONTROL/$task/workspace"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "$mutation" = tab-create ]; then
  case "$label" in
    fm-active-seeded)
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/task-pane"
      printf '%s\n' task-created > "$ACTIVE_SEEDED_CONTROL/stage"
      ;;
    fm-abort-a|fm-abort-b)
      task=${label#fm-}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$POST_CREATE_ABORT_CONTROL/$task/task-pane"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$POST_CREATE_ABORT_CONTROL" ]; then
  for task_dir in "$POST_CREATE_ABORT_CONTROL"/abort-*; do
    [ -d "$task_dir" ] || continue
    [ "${3:-}" = "$(cat "$task_dir/task-pane" 2>/dev/null || true)" ] || continue
    out=$(printf '%s' "$out" | jq --arg cwd "$POST_CREATE_ABORT_CONTROL/not-a-worktree" '.result.pane.foreground_cwd = $cwd')
    break
  done
fi
if [ -n "$mutation" ]; then
  after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf '%s\t%s\t%s\t%s\n' "$mutation" "$before" "$after" "$mutation_target" >> "$FOCUS_AUDIT_LOG"
fi
if [ "$refusal_probe" -eq 1 ]; then
  refusal_after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf 'seeded-prune-refusal\t%s\t%s\t%s\n' "$refusal_before" "$refusal_after" "${3:-}" >> "$FOCUS_AUDIT_LOG"
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$TREEHOUSE_CALL_LOG"
if [ -d "$POST_CREATE_ABORT_CONTROL" ] && [ "${1:-}" = get ]; then
  exit 0
fi
# Treehouse's pool allocator is outside the Herdr concurrency contract under
# test. Serialize its calls so simultaneous recovery spawns cannot race for
# one pool slot before reaching the Herdr session lock exercised below.
while ! mkdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null; do
  sleep 0.01
done
release_treehouse_lock() { rmdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null || true; }
trap release_treehouse_lock EXIT
trap 'exit 1' HUP INT TERM
"$REAL_TREEHOUSE" "$@"
exit $?
SH

cat > "$FAKEBIN/herdr-workspace-mover" <<'SH'
#!/usr/bin/env bash
set -u
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MOVE_CALL_LOG"
before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$("$REAL_MOVER" "$@"); then
  status=0
else
  status=$?
fi
after=$(focus_snapshot || printf ambiguous/ambiguous)
printf 'workspace-move\t%s\t%s\t%s\n' "$before" "$after" "$2" >> "$FOCUS_AUDIT_LOG"
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN/herdr-workspace-mover"
export PATH="$FAKEBIN:$PATH"
export FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAKEBIN/herdr-workspace-mover"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity. Every projection below is anchored on the
# parent this suite sets up, not on the developer's own workspace.
herdr_forget_inherited_pane

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" name fm-herdr-presentation-projection)
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
LAB_READY=0
RECORDED_WORKTREES=""
LOCK_CONTENTION_OWNER_PID=
cleanup_all() {
  local wt
  if [ -n "$LOCK_CONTENTION_OWNER_PID" ]; then
    kill "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    wait "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    LOCK_CONTENTION_OWNER_PID=
  fi
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" \
      "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

focus_snapshot() {
  local list row workspace tab tabs
  list=$(lab workspace list) || fail "could not read the active workspace for focus instrumentation"
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || fail "could not parse the active workspace and tab"
  [ -n "$row" ] || fail "focus instrumentation found an ambiguous active workspace"
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(lab tab list --workspace "$workspace") || fail "could not verify the active tab"
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || fail "workspace active_tab_id disagreed with the focused tab"
  printf '%s/%s' "$workspace" "$tab"
}

assert_focus_is() {  # <expected> <case-name>
  local expected=$1 case_name=$2 actual
  actual=$(focus_snapshot)
  [ "$actual" = "$expected" ] || fail "$case_name changed active workspace/tab from $expected to $actual"
}

focus_audit_line_count() { wc -l < "$FOCUS_AUDIT_LOG" | tr -d '[:space:]'; }

assert_raw_presentation_mutations_preserved_since() {  # <line-count> <case-name>
  local start=$1 case_name=$2 changed
  changed=$(sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' '
    ($1 == "workspace-create" || $1 == "tab-create" || $1 == "workspace-move" || $1 == "pane-close") && $2 != $3 {
      print $0
    }
  ')
  [ -z "$changed" ] || fail "$case_name changed active workspace/tab inside a create, move, or seeded cleanup: $changed"
}

# The focus-safe emptying-close plan removes a last pane through Herdr's
# pane-death path with no pane.close mutation at all (the raw explicit-close
# defect is demonstrated by tests/fm-backend-herdr-focus-flash-e2e.test.sh);
# a fallback plain close must preserve or immediately restore exact focus.
assert_cleanup_focus_preserved() {  # <line-count> <pane-id> <expected-focus>
  local start=$1 pane_id=$2 expected=$3
  sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v pane="$pane_id" -v expected="$expected" '
    $1 == "pane-close" && $4 == pane {
      saw_close = 1
      if ($2 != expected) { bad = 1 }
      else if ($3 == expected) { preserved = 1 }
      else { drift = $3 }
      next
    }
    saw_close && drift != "" && $1 == "tab-focus" && $2 == drift && $3 == expected {
      preserved = 1
    }
    END { exit(bad || (saw_close && !preserved) ? 1 : 0) }
  ' || fail "projected pane close did not preserve or restore the exact active workspace and tab"
  if lab pane get "$pane_id" >/dev/null 2>&1; then
    fail "projected cleanup left exact pane $pane_id alive"
  fi
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" | cut -d= -f2-)
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
  printf '%s' "$wt"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr projection E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {  # <home> <id> [description]
  local home=$1 id=$2 description=${3:-Herdr presentation fixture $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$description

## Firstmate spec
Verify projected workspace behavior for $id.
EOF
}

spawn_task() {  # <id> <home> <project>
  local id=$1 home=$2 project=$3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}

finish_concurrent_spawn() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  grep -F "task set is locked" "$err" >/dev/null 2>&1 \
    || fail "concurrent projected spawn $id failed unexpectedly: $(cat "$err")"
  spawn_task "$id" "$HOME_DIR" "$PROJECT_DIR" > "$out" 2> "$err" \
    || fail "projected spawn $id retry failed after task-set publication completed: $(cat "$err")"
}

finish_concurrent_expected_abort() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || fail "post-create abort fixture $id unexpectedly succeeded"
  if grep -F "task set is locked" "$err" >/dev/null 2>&1; then
    if spawn_task "$id" "$HOME_DIR" "$PROJECT_DIR" > "$out" 2> "$err"; then
      fail "post-create abort fixture $id unexpectedly succeeded after task-set publication completed"
    fi
  fi
}

spawn_secondmate_task() {
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "sh -c 'while :; do sleep 60; done'" --secondmate --backend herdr
}

teardown_task() {  # <id> <home>
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

finish_concurrent_teardown() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  if ! grep -F "session presentation lock is contended" "$err" >/dev/null 2>&1 \
     && ! grep -F "another Treehouse slot allocation or return is in progress" "$err" >/dev/null 2>&1; then
    fail "projected teardown $id failed unexpectedly: $(cat "$err")"
  fi
  teardown_task "$id" "$HOME_DIR" > "$out" 2> "$err" \
    || fail "projected teardown $id retry failed after presentation cleanup completed: $(cat "$err")"
}

normalize_meta() {  # <meta>
  sed -E \
    -e 's|^window=.*$|window=<herdr-container-id>|' \
    -e 's|^herdr_workspace_id=.*$|herdr_workspace_id=<herdr-container-id>|' \
    -e 's|^herdr_tab_id=.*$|herdr_tab_id=<herdr-container-id>|' \
    -e 's|^herdr_pane_id=.*$|herdr_pane_id=<herdr-container-id>|' \
    -e 's|^spawn_gen=.*$|spawn_gen=<spawn-incarnation>|' \
    "$1"
}

log_line_count() { wc -l < "$HERDR_CALL_LOG" | tr -d '[:space:]'; }

projection_labels_from_log() {  # <start-line>
  local start=$1
  sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG" | awk -F '\t' '
    $1 == "workspace" && $2 == "create" {
      for (i = 1; i < NF; i += 1) {
        if ($i == "--label" && $(i + 1) ~ /^└ /) {
          print $(i + 1)
        }
      }
    }
  '
}

session_presentation_lock_path() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_presentation_session_lock_path "$1"
  ' "$ROOT" "$HERDR_LAB_SESSION"
}

assert_no_ordering_lifecycle_calls_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(close|rename)|tab\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name introduced a workspace/tab/session lifecycle or label mutation call"
  fi
}

assert_no_projection_mutation_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(create|close|rename)|tab\t(create|close)|pane\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name performed a create, close, delete, rename, or lifecycle call during recovery inspection"
  fi
}

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/data/anchor" "$HOME_DIR/data/shape" \
  "$HOME_DIR/data/order-a" "$HOME_DIR/data/order-b" \
  "$HOME_DIR/data/order-fail" "$HOME_DIR/data/fm-hibit-resume-r1" \
  "$HOME_DIR/data/wheelhouse-healing-r1"
mkdir -p "$HOME_DIR/data/active-seeded" "$HOME_DIR/data/abort-a" "$HOME_DIR/data/abort-b" \
  "$HOME_DIR/data/lock-contended" "$HOME_DIR/data/default-on"
touch "$HOME_DIR/state/.last-watcher-beat"
# Presentation spaces are on by default, so the flat baseline below opts out
# explicitly; the projected cases each restate the setting they exercise.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
write_ship_brief "$HOME_DIR" anchor 'Projection anchor fixture.'
write_ship_brief "$HOME_DIR" shape 'Projection E2E fixture.'
write_ship_brief "$HOME_DIR" order-a 'Projection ordering fixture A.'
write_ship_brief "$HOME_DIR" order-b 'Projection ordering fixture B.'
write_ship_brief "$HOME_DIR" order-fail 'Projection ordering failure fixture.'
write_ship_brief "$HOME_DIR" fm-hibit-resume-r1 'Hi Bit-style projection restart fixture.'
write_ship_brief "$HOME_DIR" wheelhouse-healing-r1 'Wheelhouse-style projection restart fixture.'
write_ship_brief "$HOME_DIR" active-seeded 'Projection active seeded fixture.'
write_ship_brief "$HOME_DIR" abort-a 'Projection abort fixture A.'
write_ship_brief "$HOME_DIR" abort-b 'Projection abort fixture B.'
write_ship_brief "$HOME_DIR" lock-contended 'Projection lock contention fixture.'
write_ship_brief "$HOME_DIR" default-on 'Projection default-on fixture.'
make_project "$PROJECT_DIR"

# Keep one ordinary primary task live so the durable firstmate workspace is
# first and remains present while disposable workers are projected around it.
spawn_task anchor "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/anchor.out" 2> "$TMP_ROOT/anchor.err" \
  || fail "opted-out anchor spawn failed: $(cat "$TMP_ROOT/anchor.err")"
ANCHOR_META="$HOME_DIR/state/anchor.meta"
remember_meta_worktree "$ANCHOR_META" >/dev/null
FIRSTMATE_WSID=$(grep '^herdr_workspace_id=' "$ANCHOR_META" | cut -d= -f2-)
[ -n "$FIRSTMATE_WSID" ] || fail "anchor metadata did not record the firstmate workspace"

# The same task id and project run once opted out and once projected, so
# Treehouse commands and metadata can be compared after normalizing endpoint
# IDs and the deliberately fresh per-spawn incarnation.
: > "$TREEHOUSE_CALL_LOG"
OFF_HERDR_START=$(log_line_count)
OFF_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/off.out" 2> "$TMP_ROOT/off.err" \
  || fail "opted-out spawn failed: $(cat "$TMP_ROOT/off.err")"
OFF_HERDR_END=$(log_line_count)
OFF_META="$TMP_ROOT/off.meta"
cp "$HOME_DIR/state/shape.meta" "$OFF_META"
OFF_WT=$(remember_meta_worktree "$OFF_META")
cp "$TREEHOUSE_CALL_LOG" "$TMP_ROOT/off-treehouse.log"
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$OFF_MOVE_START" ] \
  || fail "opted-out spawn invoked the presentation-only workspace mover"
OFF_HERDR_CALLS=$(sed -n "$((OFF_HERDR_START + 1)),${OFF_HERDR_END}p" "$HERDR_CALL_LOG")
if printf '%s\n' "$OFF_HERDR_CALLS" | grep -E $'^(api\tschema|session\tlist)' >/dev/null 2>&1; then
  fail "opted-out spawn added presentation-ordering capability or socket calls"
fi
pass "real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls"
teardown_task shape "$HOME_DIR" > "$TMP_ROOT/off-teardown.out" 2> "$TMP_ROOT/off-teardown.err" \
  || fail "opted-out teardown failed: $(cat "$TMP_ROOT/off-teardown.err")"

# A home that configured nothing at all follows the version floor: it is
# projected on a release at or above it, and takes the ordinary flat layout with
# one naming warning below it. The only difference from the opted-out spawn
# above is the removed file, so this case is the floor's live end-user proof on
# whichever Herdr this lab is running.
rm -f "$HOME_DIR/config/herdr-presentation-spaces"
FLOOR_STATUS=$(lab status --json) || fail 'could not read the lab release for the presentation floor'
FLOOR_VERSION=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.version else .client.version end')
FLOOR_PROTOCOL=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.protocol else .client.protocol end')
FLOOR_VERDICT=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$FLOOR_PROTOCOL" "$FLOOR_VERSION")
[ "$FLOOR_VERDICT" = 0 ] || [ "$FLOOR_VERDICT" = 1 ] \
  || fail "herdr $FLOOR_VERSION protocol $FLOOR_PROTOCOL could not be classified against the presentation floor"
spawn_task default-on "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/default-on.out" 2> "$TMP_ROOT/default-on.err" \
  || fail "default-on spawn failed: $(cat "$TMP_ROOT/default-on.err")"
DEFAULT_ON_META="$HOME_DIR/state/default-on.meta"
remember_meta_worktree "$DEFAULT_ON_META" >/dev/null
DEFAULT_ON_JOURNAL="$HOME_DIR/state/default-on.herdr-presentation"
DEFAULT_ON_WSID=$(grep '^herdr_workspace_id=' "$DEFAULT_ON_META" | cut -d= -f2-)
if [ "$FLOOR_VERDICT" = 0 ]; then
  [ -f "$DEFAULT_ON_JOURNAL" ] \
    || fail "an unconfigured home did not publish a presentation journal on supported herdr $FLOOR_VERSION"
  DEFAULT_ON_TOKEN=$(grep '^projection_id=' "$DEFAULT_ON_JOURNAL" | cut -d= -f2-)
  [ -n "$DEFAULT_ON_WSID" ] && [ "$DEFAULT_ON_WSID" != "$FIRSTMATE_WSID" ] \
    || fail "an unconfigured home reused the flat firstmate workspace instead of projecting"
  DEFAULT_ON_LABEL=$(lab workspace get "$DEFAULT_ON_WSID" | jq -r '.result.workspace.label // empty')
  [ "$DEFAULT_ON_LABEL" = "└ default-on · p:$DEFAULT_ON_TOKEN" ] \
    || fail "default-on projection used an unexpected workspace label: $DEFAULT_ON_LABEL"
  pass "real Herdr lab: a home that configured nothing is projected by default on herdr $FLOOR_VERSION"
else
  [ ! -e "$DEFAULT_ON_JOURNAL" ] \
    || fail "an unconfigured home published a presentation journal on below-floor herdr $FLOOR_VERSION"
  [ "$DEFAULT_ON_WSID" = "$FIRSTMATE_WSID" ] \
    || fail "an unconfigured home did not land in the flat firstmate workspace on below-floor herdr $FLOOR_VERSION (got '${DEFAULT_ON_WSID:-<empty>}')"
  grep -q "$FLOOR_VERSION" "$TMP_ROOT/default-on.err" \
    || fail "the below-floor fallback did not name herdr $FLOOR_VERSION: $(cat "$TMP_ROOT/default-on.err")"
  pass "real Herdr lab: a home that configured nothing falls back flat on below-floor herdr $FLOOR_VERSION with one naming warning"
fi
teardown_task default-on "$HOME_DIR" > "$TMP_ROOT/default-on-teardown.out" 2> "$TMP_ROOT/default-on-teardown.err" \
  || fail "default-on teardown failed: $(cat "$TMP_ROOT/default-on-teardown.err")"
if [ "$FLOOR_VERDICT" = 0 ] && lab workspace get "$DEFAULT_ON_WSID" >/dev/null 2>&1; then
  fail "default-on teardown left its disposable workspace behind"
fi
# The ordering scenarios below read the whole move log cumulatively against the
# projected workspaces that are still live, so this retired one starts them clean.
: > "$MOVE_CALL_LOG"

SECOND_ONE_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-alpha --no-focus) \
  || fail "could not create the first secondmate presentation fixture"
SECOND_TWO_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-bravo --focus) \
  || fail "could not create the focused secondmate presentation fixture"
SECOND_ONE_WSID=$(printf '%s' "$SECOND_ONE_OUT" | jq -r '.result.workspace.workspace_id // empty')
SECOND_TWO_WSID=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.workspace.workspace_id // empty')
SECOND_TWO_TAB=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.tab.tab_id // empty')
SECOND_TWO_PANE=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$SECOND_ONE_WSID" ] && [ -n "$SECOND_TWO_WSID" ] && [ -n "$SECOND_TWO_TAB" ] && [ -n "$SECOND_TWO_PANE" ] \
  || fail "secondmate presentation fixtures returned incomplete IDs"
SECOND_ORDER_BEFORE=$(printf '%s\n%s\n' "$SECOND_ONE_WSID" "$SECOND_TWO_WSID")
CAPTAIN_FOCUS="$SECOND_TWO_WSID/$SECOND_TWO_TAB"
assert_focus_is "$CAPTAIN_FOCUS" "focused secondmate fixture"

: > "$TREEHOUSE_CALL_LOG"
# The historical presence-based opt-in was an empty file; it must still project,
# so no home that had already enabled the projection is turned off by the default.
: > "$HOME_DIR/config/herdr-presentation-spaces"
SHAPE_FOCUS_AUDIT_START=$(focus_audit_line_count)
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/on.out" 2> "$TMP_ROOT/on.err" \
  || fail "projected spawn failed: $(cat "$TMP_ROOT/on.err")"
assert_focus_is "$CAPTAIN_FOCUS" "projected spawn"
assert_raw_presentation_mutations_preserved_since "$SHAPE_FOCUS_AUDIT_START" "projected spawn"
ON_META="$TMP_ROOT/on.meta"
cp "$HOME_DIR/state/shape.meta" "$ON_META"
ON_WT=$(remember_meta_worktree "$ON_META")
cmp -s "$TMP_ROOT/off-treehouse.log" "$TREEHOUSE_CALL_LOG" \
  || fail "Treehouse command sequence changed between opted-out and projected spawns"
JOURNAL="$HOME_DIR/state/shape.herdr-presentation"
[ -f "$JOURNAL" ] || fail "projected spawn did not publish its presentation journal"
TOKEN=$(grep '^projection_id=' "$JOURNAL" | cut -d= -f2-)
[ "${#TOKEN}" -eq 22 ] || fail "projection id is not the compact 22-character encoding of 128 bits"
PROJECTED_WSID=$(grep '^herdr_workspace_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_TAB=$(grep '^herdr_tab_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_PANE=$(grep '^herdr_pane_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_INFO=$(lab workspace get "$PROJECTED_WSID") || fail "could not inspect the projected workspace"
PROJECTED_LABEL=$(printf '%s' "$PROJECTED_INFO" | jq -r '.result.workspace.label // empty')
[ "$PROJECTED_LABEL" = "└ shape · p:$TOKEN" ] \
  || fail "projected workspace label did not use the corner format with full token: $PROJECTED_LABEL"
PROJECTED_TABS=$(lab tab list --workspace "$PROJECTED_WSID")
PROJECTED_PANES=$(lab pane list --workspace "$PROJECTED_WSID")
[ "$(printf '%s' "$PROJECTED_TABS" | jq -r '.result.tabs | length')" = 1 ] \
  || fail "projected workspace retained a seeded or placeholder tab"
[ "$(printf '%s' "$PROJECTED_PANES" | jq -r '.result.panes | length')" = 1 ] \
  || fail "projected workspace did not contain exactly one task pane"
printf '%s' "$PROJECTED_TABS" | jq -e --arg tab "$PROJECTED_TAB" \
  '.result.tabs[0].tab_id == $tab and .result.tabs[0].label == "fm-shape"' >/dev/null 2>&1 \
  || fail "projected workspace's only tab was not the normal fm-shape task tab"
printf '%s' "$PROJECTED_PANES" | jq -e --arg pane "$PROJECTED_PANE" \
  '.result.panes[0].pane_id == $pane' >/dev/null 2>&1 \
  || fail "projected workspace's only pane was not the exact recorded task pane"
SECOND_TWO_INFO=$(lab workspace get "$SECOND_TWO_WSID") || fail "focused secondmate disappeared during projected create"
[ "$(printf '%s' "$SECOND_TWO_INFO" | jq -r '.result.workspace.focused')" = true ] \
  || fail "projected create or workspace.move stole focus from the captain's current space"
pass "real Herdr lab: every projected create, task-tab create, seeded prune, and move preserves active workspace and tab"

mkdir -p "$ACTIVE_SEEDED_CONTROL"
printf '%s\n' requested > "$ACTIVE_SEEDED_CONTROL/stage"
ACTIVE_SEEDED_START=$(log_line_count)
ACTIVE_SEEDED_FOCUS_START=$(focus_audit_line_count)
if spawn_task active-seeded "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/active-seeded.out" 2> "$TMP_ROOT/active-seeded.err"; then
  fail "active seeded-tab projection should refuse the prune"
fi
grep -F "target is the captain's active tab" "$TMP_ROOT/active-seeded.err" >/dev/null 2>&1 \
  || fail "active seeded-tab projection did not report its exact refusal"
ACTIVE_SEEDED_WSID=$(cat "$ACTIVE_SEEDED_CONTROL/workspace")
ACTIVE_SEEDED_TAB=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-tab")
ACTIVE_SEEDED_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane")
ACTIVE_SEEDED_TASK_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/task-pane")
ACTIVE_SEEDED_FOCUS="$ACTIVE_SEEDED_WSID/$ACTIVE_SEEDED_TAB"
assert_focus_is "$ACTIVE_SEEDED_FOCUS" "active seeded-tab prune refusal"
assert_raw_presentation_mutations_preserved_since "$ACTIVE_SEEDED_FOCUS_START" "active seeded-tab prune refusal"
lab pane get "$ACTIVE_SEEDED_PANE" >/dev/null 2>&1 \
  || fail "active seeded-tab refusal removed the exact seeded pane"
if lab pane get "$ACTIVE_SEEDED_TASK_PANE" >/dev/null 2>&1; then
  fail "active seeded-tab failure did not abort-clean the non-active task pane"
fi
sed -n "$((ACTIVE_SEEDED_FOCUS_START + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v focus="$ACTIVE_SEEDED_FOCUS" -v pane="$ACTIVE_SEEDED_PANE" '
  $1 == "seeded-prune-refusal" && $2 == focus && $3 == focus && $4 == pane { found = 1 }
  END { exit(found ? 0 : 1) }
' || fail "guarded lab did not observe exact focus across the active seeded-tab refusal"
if sed -n "$((ACTIVE_SEEDED_START + 1)),\$p" "$HERDR_CALL_LOG" | grep -F $'pane\tclose\t'"$ACTIVE_SEEDED_PANE" >/dev/null 2>&1; then
  fail "active seeded-tab refusal closed the exact active pane"
fi
lab tab focus "$SECOND_TWO_TAB" >/dev/null || fail "could not restore the captured captain tab after the active seeded-tab fixture"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture restoration"
rm -rf "$ACTIVE_SEEDED_CONTROL"
ACTIVE_SEEDED_CLEANUP_FOCUS_START=$(focus_audit_line_count)
ACTIVE_SEEDED_LOCK=$(session_presentation_lock_path) \
  || fail "could not resolve the session presentation lock for active-seeded cleanup"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" bash -c '
  . "$0/bin/fm-wake-lib.sh"
  . "$0/bin/backends/herdr.sh"
  lock=$1
  fm_lock_acquire_wait "$lock"
  fm_backend_herdr_projection_cleanup_exact "$2" "$3" "$4"
  fm_lock_release "$lock"
' "$ROOT" "$ACTIVE_SEEDED_LOCK" "$HERDR_LAB_SESSION" "$ACTIVE_SEEDED_TASK_PANE" "$ACTIVE_SEEDED_PANE"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture cleanup"
assert_cleanup_focus_preserved "$ACTIVE_SEEDED_CLEANUP_FOCUS_START" "$ACTIVE_SEEDED_PANE" "$CAPTAIN_FOCUS"
rm -f "$HOME_DIR/state/active-seeded.herdr-presentation"
pass "real Herdr lab: active seeded-tab pruning refuses the exact pane and preserves exact focus"

LOCK_CONTENTION_READY="$TMP_ROOT/lock-contention-ready"
LOCK_CONTENTION_RELEASE="$TMP_ROOT/lock-contention-release"
LOCK_CONTENTION_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve the session presentation lock for contention"
ROOT="$ROOT" READY="$LOCK_CONTENTION_READY" RELEASE="$LOCK_CONTENTION_RELEASE" \
  LOCK="$LOCK_CONTENTION_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK"
' &
LOCK_CONTENTION_OWNER_PID=$!
while [ ! -e "$LOCK_CONTENTION_READY" ] && kill -0 "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$LOCK_CONTENTION_READY" ] || fail "could not hold the guarded lab presentation lock"
LOCK_CONTENTION_START=$(log_line_count)
LOCK_CONTENTION_FOCUS_START=$(focus_audit_line_count)
LOCK_CONTENTION_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
if spawn_task lock-contended "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/lock-contended.out" 2> "$TMP_ROOT/lock-contended.err"; then
  LOCK_CONTENTION_STATUS=0
else
  LOCK_CONTENTION_STATUS=$?
fi
: > "$LOCK_CONTENTION_RELEASE"
wait "$LOCK_CONTENTION_OWNER_PID" || fail "guarded lab presentation lock owner failed"
LOCK_CONTENTION_OWNER_PID=
[ "$LOCK_CONTENTION_STATUS" -eq 0 ] \
  || fail "bounded presentation lock contention did not fall back to a successful flat spawn: $(cat "$TMP_ROOT/lock-contended.err")"
grep -F "presentation focus lock unavailable; using the ordinary flat layout without projection" "$TMP_ROOT/lock-contended.err" >/dev/null 2>&1 \
  || fail "bounded presentation lock contention did not warn about flat fallback"
LOCK_CONTENTION_META="$HOME_DIR/state/lock-contended.meta"
remember_meta_worktree "$LOCK_CONTENTION_META" >/dev/null
LOCK_CONTENTION_WSID=$(grep '^herdr_workspace_id=' "$LOCK_CONTENTION_META" | cut -d= -f2-)
[ "$LOCK_CONTENTION_WSID" = "$FIRSTMATE_WSID" ] \
  || fail "bounded lock contention did not use the ordinary flat firstmate workspace"
[ ! -e "$HOME_DIR/state/lock-contended.herdr-presentation" ] \
  || fail "bounded lock contention published a projection journal"
LOCK_CONTENTION_CALLS=$(sed -n "$((LOCK_CONTENTION_START + 1)),\$p" "$HERDR_CALL_LOG")
# session list is required to resolve the shared session lock path before the
# bounded acquire attempt; it must not unlock projection create or move.
if printf '%s\n' "$LOCK_CONTENTION_CALLS" | grep -E $'^(workspace\tcreate|pane\tclose|api\tschema)' >/dev/null 2>&1; then
  fail "bounded lock contention performed an unlocked projection mutation or ordering capability call"
fi
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$LOCK_CONTENTION_MOVE_START" ] \
  || fail "bounded lock contention invoked workspace.move"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback"
assert_raw_presentation_mutations_preserved_since "$LOCK_CONTENTION_FOCUS_START" "bounded presentation lock flat fallback"
teardown_task lock-contended "$HOME_DIR" > "$TMP_ROOT/lock-contended-teardown.out" 2> "$TMP_ROOT/lock-contended-teardown.err" \
  || fail "flat lock-contention fixture teardown failed"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback teardown"
pass "real Herdr lab: bounded lock contention warns and falls back flat without projection or focus drift"
PROJECTION_ORDER_START=$(log_line_count)

[ "$OFF_WT" = "$ON_WT" ] || fail "Treehouse did not reuse the same fixture worktree, so byte comparison is inconclusive"
normalize_meta "$OFF_META" > "$TMP_ROOT/off.meta.normalized"
normalize_meta "$ON_META" > "$TMP_ROOT/on.meta.normalized"
cmp -s "$TMP_ROOT/off.meta.normalized" "$TMP_ROOT/on.meta.normalized" \
  || fail "metadata changed beyond Herdr container IDs between opted-out and projected paths"

# Two real primary spawns begin concurrently.
# The fresh-spawn task-set lock may fail closed for one while the other
# publishes, in which case retry it only after the lock owner has completed.
# Their final relative order must match Herdr's actual serialized create order,
# rather than a task-name or priority guess.
CONCURRENT_FOCUS_AUDIT_START=$(focus_audit_line_count)
spawn_task order-a "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/order-a.out" 2> "$TMP_ROOT/order-a.err" &
ORDER_A_PID=$!
spawn_task order-b "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/order-b.out" 2> "$TMP_ROOT/order-b.err" &
ORDER_B_PID=$!
if wait "$ORDER_A_PID"; then ORDER_A_STATUS=0; else ORDER_A_STATUS=$?; fi
if wait "$ORDER_B_PID"; then ORDER_B_STATUS=0; else ORDER_B_STATUS=$?; fi
finish_concurrent_spawn order-a "$ORDER_A_STATUS" "$TMP_ROOT/order-a.out" "$TMP_ROOT/order-a.err"
finish_concurrent_spawn order-b "$ORDER_B_STATUS" "$TMP_ROOT/order-b.out" "$TMP_ROOT/order-b.err"
assert_focus_is "$CAPTAIN_FOCUS" "concurrent projected spawns"
assert_raw_presentation_mutations_preserved_since "$CONCURRENT_FOCUS_AUDIT_START" "concurrent projected spawns"
ORDER_A_META="$HOME_DIR/state/order-a.meta"
ORDER_B_META="$HOME_DIR/state/order-b.meta"
remember_meta_worktree "$ORDER_A_META" >/dev/null
remember_meta_worktree "$ORDER_B_META" >/dev/null

ORDER_LIST=$(lab workspace list) || fail "could not inspect concurrent presentation ordering"
CREATED_LABELS=$(projection_labels_from_log "$PROJECTION_ORDER_START")
EXPECTED_LABELS=$(printf 'firstmate\n%s\n%s\n2ndmate-alpha\n2ndmate-bravo' "$PROJECTED_LABEL" "$CREATED_LABELS")
ACTUAL_LABELS=$(printf '%s' "$ORDER_LIST" | jq -r '.result.workspaces[].label')
[ "$ACTUAL_LABELS" = "$EXPECTED_LABELS" ] || fail "workspace order was not firstmate, stable primary block, secondmates: $ACTUAL_LABELS"
PRIMARY_IDS=$(printf '%s' "$ORDER_LIST" | jq -r '
  .result.workspaces[]
  | select((.label | startswith("└ ")) or (.label | startswith("firstmate/")))
  | .workspace_id
')
MOVE_TARGETS=$(cut -f2 "$MOVE_CALL_LOG")
[ "$MOVE_TARGETS" = "$PRIMARY_IDS" ] \
  || fail "workspace.move targeted something other than each exact current projected-create id"
MOVE_INDEXES=$(cut -f3 "$MOVE_CALL_LOG")
[ "$MOVE_INDEXES" = $'1\n2\n3' ] \
  || fail "concurrent primary workers did not append stably to the contiguous block: $MOVE_INDEXES"
SECOND_ORDER_AFTER=$(printf '%s' "$ORDER_LIST" | jq -r '.result.workspaces[] | select(.label | startswith("2ndmate-")) | .workspace_id')
[ "$SECOND_ORDER_AFTER" = "$SECOND_ORDER_BEFORE" ] \
  || fail "primary workspace ordering changed secondmate relative order"
[ "$(lab workspace get "$SECOND_TWO_WSID" | jq -r '.result.workspace.focused')" = true ] \
  || fail "concurrent primary workspace ordering stole focus"
assert_no_ordering_lifecycle_calls_since "$PROJECTION_ORDER_START" "successful presentation ordering"
pass "real Herdr lab: concurrent primary workers form one stable contiguous block without active workspace/tab drift"

# Force only the raw move transport to fail after a safe projected create.
# The spawn must remain successful in Herdr's default appended order, with its
# exact task pane alive and no ordering-triggered cleanup.
FAIL_MOVER="$TMP_ROOT/fail-workspace-mover"
cat > "$FAIL_MOVER" <<'SH'
#!/usr/bin/env bash
exit 9
SH
chmod +x "$FAIL_MOVER"
FAIL_START=$(log_line_count)
FAIL_FOCUS_AUDIT_START=$(focus_audit_line_count)
FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAIL_MOVER" \
  spawn_task order-fail "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/order-fail.out" 2> "$TMP_ROOT/order-fail.err" \
  || fail "move-failure projected spawn should still succeed: $(cat "$TMP_ROOT/order-fail.err")"
assert_focus_is "$CAPTAIN_FOCUS" "failed presentation ordering"
assert_raw_presentation_mutations_preserved_since "$FAIL_FOCUS_AUDIT_START" "failed presentation ordering"
grep -F "workspace move failed or had an ambiguous response" "$TMP_ROOT/order-fail.err" >/dev/null 2>&1 \
  || fail "forced workspace.move failure did not report only the best-effort warning"
ORDER_FAIL_META="$HOME_DIR/state/order-fail.meta"
remember_meta_worktree "$ORDER_FAIL_META" >/dev/null
ORDER_FAIL_WSID=$(grep '^herdr_workspace_id=' "$ORDER_FAIL_META" | cut -d= -f2-)
ORDER_FAIL_PANE=$(grep '^herdr_pane_id=' "$ORDER_FAIL_META" | cut -d= -f2-)
FAIL_LIST=$(lab workspace list) || fail "could not inspect the move-failure fallback"
[ "$(printf '%s' "$FAIL_LIST" | jq -r '.result.workspaces[-1].workspace_id')" = "$ORDER_FAIL_WSID" ] \
  || fail "workspace.move failure did not leave the safe worker in Herdr's default appended order"
lab pane get "$ORDER_FAIL_PANE" >/dev/null 2>&1 \
  || fail "workspace.move failure cleaned up the safely-created task pane"
FAIL_CLOSED_PANES=$(sed -n "$((FAIL_START + 1)),\$p" "$HERDR_CALL_LOG" | awk -F '\t' '$1 == "pane" && $2 == "close" { print $3 }')
[ "$(printf '%s\n' "$FAIL_CLOSED_PANES" | awk 'NF { n += 1 } END { print n + 0 }')" = 1 ] \
  || fail "move-failure spawn performed a pane close beyond the normal seeded-pane prune"
[ "$FAIL_CLOSED_PANES" != "$ORDER_FAIL_PANE" ] \
  || fail "move-failure spawn closed its exact task pane"
assert_no_ordering_lifecycle_calls_since "$FAIL_START" "failed presentation ordering"
pass "real Herdr lab: forced workspace.move failure leaves a successful worker in default order with a warning and no cleanup"

mkdir -p "$POST_CREATE_ABORT_CONTROL"
ABORT_START=$(log_line_count)
ABORT_FOCUS_START=$(focus_audit_line_count)
spawn_task abort-a "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/abort-a.out" 2> "$TMP_ROOT/abort-a.err" &
ABORT_A_PID=$!
spawn_task abort-b "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/abort-b.out" 2> "$TMP_ROOT/abort-b.err" &
ABORT_B_PID=$!
if wait "$ABORT_A_PID"; then ABORT_A_STATUS=0; else ABORT_A_STATUS=$?; fi
if wait "$ABORT_B_PID"; then ABORT_B_STATUS=0; else ABORT_B_STATUS=$?; fi
finish_concurrent_expected_abort abort-a "$ABORT_A_STATUS" "$TMP_ROOT/abort-a.out" "$TMP_ROOT/abort-a.err"
finish_concurrent_expected_abort abort-b "$ABORT_B_STATUS" "$TMP_ROOT/abort-b.out" "$TMP_ROOT/abort-b.err"
# The forced foreground_cwd is a plain non-git directory, which the discovery
# poll now screens out on every read rather than adopting, so the armed failure
# arrives as the poll's own deadline refusal naming that path.
grep -F "did not enter an isolated worktree" "$TMP_ROOT/abort-a.err" >/dev/null 2>&1 \
  || fail "post-create abort fixture A did not reach the armed validation failure"
grep -F "did not enter an isolated worktree" "$TMP_ROOT/abort-b.err" >/dev/null 2>&1 \
  || fail "post-create abort fixture B did not reach the armed validation failure"
ABORT_A_PANE=$(cat "$POST_CREATE_ABORT_CONTROL/abort-a/task-pane")
ABORT_B_PANE=$(cat "$POST_CREATE_ABORT_CONTROL/abort-b/task-pane")
ABORT_SEQUENCE=$(sed -n "$((ABORT_FOCUS_START + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v a="$ABORT_A_PANE" -v b="$ABORT_B_PANE" '
  $1 == "workspace-create" && $4 ~ /^└ abort-a · p:/ { print "create-a" }
  $1 == "workspace-create" && $4 ~ /^└ abort-b · p:/ { print "create-b" }
  $1 == "pane-close" && $4 == a { print "close-a" }
  $1 == "pane-close" && $4 == b { print "close-b" }
')
case "$ABORT_SEQUENCE" in
  $'create-a\nclose-a\ncreate-b\nclose-b'|$'create-b\nclose-b\ncreate-a\nclose-a') ;;
  *) fail "concurrent post-create abort cleanup interleaved outside the presentation lock: $ABORT_SEQUENCE" ;;
esac
ABORT_UNRESTORED=$(sed -n "$((ABORT_FOCUS_START + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v a="$ABORT_A_PANE" -v b="$ABORT_B_PANE" '
  ($1 == "workspace-create" || $1 == "tab-create" || $1 == "workspace-move" || ($1 == "pane-close" && $4 != a && $4 != b)) && $2 != $3 { print }
')
[ -z "$ABORT_UNRESTORED" ] \
  || fail "post-create abort create, prune, or move changed exact focus: $ABORT_UNRESTORED"
assert_focus_is "$CAPTAIN_FOCUS" "concurrent post-create abort cleanup"
assert_cleanup_focus_preserved "$ABORT_FOCUS_START" "$ABORT_A_PANE" "$CAPTAIN_FOCUS"
assert_cleanup_focus_preserved "$ABORT_FOCUS_START" "$ABORT_B_PANE" "$CAPTAIN_FOCUS"
assert_no_ordering_lifecycle_calls_since "$ABORT_START" "concurrent post-create abort cleanup"
for ABORT_PANE in "$ABORT_A_PANE" "$ABORT_B_PANE"; do
  if lab pane get "$ABORT_PANE" >/dev/null 2>&1; then
    fail "serialized post-create abort cleanup left exact task pane $ABORT_PANE alive"
  fi
done
[ ! -e "$HOME_DIR/state/abort-a.meta" ] && [ ! -e "$HOME_DIR/state/abort-b.meta" ] \
  || fail "post-create abort fixtures published task metadata before launch"
rm -rf "$POST_CREATE_ABORT_CONTROL"
rm -f "$HOME_DIR/state/abort-a.herdr-presentation" "$HOME_DIR/state/abort-b.herdr-presentation"
pass "real Herdr lab: concurrent post-create abort cleanup stays serialized with exact focus restoration"

SHAPE_CLEANUP_AUDIT_START=$(focus_audit_line_count)
teardown_task shape "$HOME_DIR" > "$TMP_ROOT/on-teardown.out" 2> "$TMP_ROOT/on-teardown.err" \
  || fail "projected teardown failed: $(cat "$TMP_ROOT/on-teardown.err")"
assert_focus_is "$CAPTAIN_FOCUS" "projected teardown"
assert_cleanup_focus_preserved "$SHAPE_CLEANUP_AUDIT_START" "$PROJECTED_PANE" "$CAPTAIN_FOCUS"
pass "real Herdr lab: Treehouse commands and metadata shape are byte-identical except for endpoint IDs and spawn incarnation"
if lab workspace get "$PROJECTED_WSID" >/dev/null 2>&1; then
  fail "closing the exact projected task pane did not remove its last-tab workspace"
fi
lab pane get "$SECOND_TWO_PANE" >/dev/null 2>&1 \
  || fail "projected teardown affected the focused secondmate workspace"
[ ! -e "$JOURNAL" ] || fail "confirmed projected teardown did not retire its presentation journal"
pass "real Herdr lab: exact task-pane close removes the projected workspace with no unrestored wrong-focus interval"

teardown_task order-a "$HOME_DIR" > "$TMP_ROOT/order-a-teardown.out" 2> "$TMP_ROOT/order-a-teardown.err" &
ORDER_A_TEARDOWN_PID=$!
teardown_task order-b "$HOME_DIR" > "$TMP_ROOT/order-b-teardown.out" 2> "$TMP_ROOT/order-b-teardown.err" &
ORDER_B_TEARDOWN_PID=$!
if wait "$ORDER_A_TEARDOWN_PID"; then ORDER_A_TEARDOWN_STATUS=0; else ORDER_A_TEARDOWN_STATUS=$?; fi
if wait "$ORDER_B_TEARDOWN_PID"; then ORDER_B_TEARDOWN_STATUS=0; else ORDER_B_TEARDOWN_STATUS=$?; fi
finish_concurrent_teardown order-a "$ORDER_A_TEARDOWN_STATUS" "$TMP_ROOT/order-a-teardown.out" "$TMP_ROOT/order-a-teardown.err"
finish_concurrent_teardown order-b "$ORDER_B_TEARDOWN_STATUS" "$TMP_ROOT/order-b-teardown.out" "$TMP_ROOT/order-b-teardown.err"
assert_focus_is "$CAPTAIN_FOCUS" "concurrent projected teardowns"
teardown_task order-fail "$HOME_DIR" > "$TMP_ROOT/order-fail-teardown.out" 2> "$TMP_ROOT/order-fail-teardown.err" \
  || fail "projected ordering failure fixture teardown failed"
assert_focus_is "$CAPTAIN_FOCUS" "failed-order projection teardown"
pass "real Herdr lab: concurrent projected cleanup is serialized and leaves active workspace/tab unchanged"

# Repeat full two-worker create, order, and cleanup waves.
# This exercises the focus guard after the original regression sequence and
# proves the shared presentation lock keeps concurrent operations composable.
for ROUND in 1 2 3; do
  mkdir -p "$HOME_DIR/data/focus-$ROUND-a" "$HOME_DIR/data/focus-$ROUND-b"
  write_ship_brief "$HOME_DIR" "focus-$ROUND-a" "Projection focus wave $ROUND fixture A."
  write_ship_brief "$HOME_DIR" "focus-$ROUND-b" "Projection focus wave $ROUND fixture B."
  WAVE_LOG_START=$(log_line_count)
  WAVE_FOCUS_START=$(focus_audit_line_count)
  spawn_task "focus-$ROUND-a" "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/focus-$ROUND-a.out" 2> "$TMP_ROOT/focus-$ROUND-a.err" &
  WAVE_A_PID=$!
  spawn_task "focus-$ROUND-b" "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/focus-$ROUND-b.out" 2> "$TMP_ROOT/focus-$ROUND-b.err" &
  WAVE_B_PID=$!
  if wait "$WAVE_A_PID"; then WAVE_A_STATUS=0; else WAVE_A_STATUS=$?; fi
  if wait "$WAVE_B_PID"; then WAVE_B_STATUS=0; else WAVE_B_STATUS=$?; fi
  finish_concurrent_spawn "focus-$ROUND-a" "$WAVE_A_STATUS" "$TMP_ROOT/focus-$ROUND-a.out" "$TMP_ROOT/focus-$ROUND-a.err"
  finish_concurrent_spawn "focus-$ROUND-b" "$WAVE_B_STATUS" "$TMP_ROOT/focus-$ROUND-b.out" "$TMP_ROOT/focus-$ROUND-b.err"
  remember_meta_worktree "$HOME_DIR/state/focus-$ROUND-a.meta" >/dev/null
  remember_meta_worktree "$HOME_DIR/state/focus-$ROUND-b.meta" >/dev/null
  assert_focus_is "$CAPTAIN_FOCUS" "focus wave $ROUND concurrent spawns"
  assert_raw_presentation_mutations_preserved_since "$WAVE_FOCUS_START" "focus wave $ROUND concurrent spawns"
  WAVE_LABELS=$(projection_labels_from_log "$WAVE_LOG_START")
  WAVE_EXPECTED=$(printf 'firstmate\n%s\n2ndmate-alpha\n2ndmate-bravo' "$WAVE_LABELS")
  WAVE_ACTUAL=$(lab workspace list | jq -r '.result.workspaces[] | select(.label == "firstmate" or (.label | startswith("└ ")) or (.label | startswith("2ndmate-"))) | .label')
  [ "$WAVE_ACTUAL" = "$WAVE_EXPECTED" ] \
    || fail "focus wave $ROUND lost stable contiguous ordering: $WAVE_ACTUAL"
  WAVE_SECOND_ORDER=$(lab workspace list | jq -r '.result.workspaces[] | select(.label | startswith("2ndmate-")) | .workspace_id')
  [ "$WAVE_SECOND_ORDER" = "$SECOND_ORDER_BEFORE" ] \
    || fail "focus wave $ROUND changed secondmate relative order"

  teardown_task "focus-$ROUND-a" "$HOME_DIR" > "$TMP_ROOT/focus-$ROUND-a-teardown.out" 2> "$TMP_ROOT/focus-$ROUND-a-teardown.err" &
  WAVE_A_TEARDOWN_PID=$!
  teardown_task "focus-$ROUND-b" "$HOME_DIR" > "$TMP_ROOT/focus-$ROUND-b-teardown.out" 2> "$TMP_ROOT/focus-$ROUND-b-teardown.err" &
  WAVE_B_TEARDOWN_PID=$!
  if wait "$WAVE_A_TEARDOWN_PID"; then WAVE_A_TEARDOWN_STATUS=0; else WAVE_A_TEARDOWN_STATUS=$?; fi
  if wait "$WAVE_B_TEARDOWN_PID"; then WAVE_B_TEARDOWN_STATUS=0; else WAVE_B_TEARDOWN_STATUS=$?; fi
  finish_concurrent_teardown "focus-$ROUND-a" "$WAVE_A_TEARDOWN_STATUS" "$TMP_ROOT/focus-$ROUND-a-teardown.out" "$TMP_ROOT/focus-$ROUND-a-teardown.err"
  finish_concurrent_teardown "focus-$ROUND-b" "$WAVE_B_TEARDOWN_STATUS" "$TMP_ROOT/focus-$ROUND-b-teardown.out" "$TMP_ROOT/focus-$ROUND-b-teardown.err"
  assert_focus_is "$CAPTAIN_FOCUS" "focus wave $ROUND concurrent teardowns"
  WAVE_REMAINING=$(lab workspace list | jq -r '.result.workspaces[].label')
  [ "$WAVE_REMAINING" = $'firstmate\n2ndmate-alpha\n2ndmate-bravo' ] \
    || fail "focus wave $ROUND cleanup left a projected workspace behind: $WAVE_REMAINING"
done
pass "real Herdr lab: three repeated concurrent create/order/cleanup waves have zero active workspace or tab drift"

# ------------------------------------------------------------------
# Multi-home topology: real secondmate FM_HOME spawn paths, inheritance,
# concurrent cross-home waves, and session-scoped lock contention.
# ------------------------------------------------------------------
SECOND_HOME_A="$TMP_ROOT/home-2ndmate-alpha"
SECOND_HOME_B="$TMP_ROOT/home-2ndmate-bravo"
mkdir -p "$SECOND_HOME_A/state" "$SECOND_HOME_A/config" "$SECOND_HOME_A/data" \
  "$SECOND_HOME_B/state" "$SECOND_HOME_B/config" "$SECOND_HOME_B/data"
printf 'alpha\n' > "$SECOND_HOME_A/.fm-secondmate-home"
printf 'bravo\n' > "$SECOND_HOME_B/.fm-secondmate-home"
touch "$SECOND_HOME_A/state/.last-watcher-beat" "$SECOND_HOME_B/state/.last-watcher-beat"
# Ensure the secondmate homes look like gitignored firstmate homes so inheritance
# may write config/herdr-presentation-spaces.
git -C "$SECOND_HOME_A" init -q
git -C "$SECOND_HOME_B" init -q
printf 'config/herdr-presentation-spaces\nconfig/crew-harness\nconfig/crew-dispatch.json\nconfig/backlog-backend\nconfig/backend\nconfig/startup-memory-budget\n' \
  > "$SECOND_HOME_A/.gitignore"
cp "$SECOND_HOME_A/.gitignore" "$SECOND_HOME_B/.gitignore"
git -C "$SECOND_HOME_A" add .gitignore
git -C "$SECOND_HOME_B" add .gitignore
git -C "$SECOND_HOME_A" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
git -C "$SECOND_HOME_B" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
mkdir -p "$SECOND_HOME_A/bin"
printf '# Firstmate secondmate fixture\n' > "$SECOND_HOME_A/AGENTS.md"
printf 'Secondmate alpha charter.\n' > "$SECOND_HOME_A/data/charter.md"

# Primary setting only; real inheritance must push it into both secondmate homes.
[ -f "$HOME_DIR/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting disappeared before multi-home inheritance"
[ ! -e "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate A unexpectedly had a local presentation setting before inheritance"
[ ! -e "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "secondmate B unexpectedly had a local presentation setting before inheritance"
SECOND_SPAWN_LOG_START=$(log_line_count)
spawn_secondmate_task alpha "$SECOND_HOME_A" > "$TMP_ROOT/alpha.out" 2> "$TMP_ROOT/alpha.err" \
  || fail "secondmate alpha spawn failed: $(cat "$TMP_ROOT/alpha.err")"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate spawn did not inherit the presentation setting"
[ ! -e "$HOME_DIR/state/alpha.herdr-presentation" ] \
  || fail "secondmate spawn published a presentation journal"
SECOND_META="$HOME_DIR/state/alpha.meta"
[ "$(grep '^kind=' "$SECOND_META" | cut -d= -f2-)" = secondmate ] \
  || fail "secondmate spawn did not record kind=secondmate"
SECOND_WSID=$(grep '^herdr_workspace_id=' "$SECOND_META" | cut -d= -f2-)
SECOND_LABEL=$(lab workspace get "$SECOND_WSID" | jq -r '.result.workspace.label')
[ "$SECOND_LABEL" = 2ndmate-alpha ] \
  || fail "secondmate spawn did not use its flat parent workspace: $SECOND_LABEL"
[ -z "$(projection_labels_from_log "$SECOND_SPAWN_LOG_START")" ] \
  || fail "secondmate spawn created a corner projection workspace"
if sed -n "$((SECOND_SPAWN_LOG_START + 1)),\$p" "$HERDR_CALL_LOG" \
  | grep -E $'^(workspace\tmove|session\tlist)' >/dev/null 2>&1; then
  fail "secondmate spawn attempted presentation ordering"
fi
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_A/config" \
  || fail "inheritance into secondmate A failed"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_B/config" \
  || fail "inheritance into secondmate B failed"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate A"
[ -f "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate B"
pass "real Herdr lab: the primary presentation setting inherits into real secondmate homes"

# Keep the pre-existing 2ndmate-alpha/bravo workspaces as owning parents and captain focus.
assert_focus_is "$CAPTAIN_FOCUS" "multi-home captain focus"

mkdir -p "$SECOND_HOME_A/data/a1" "$SECOND_HOME_A/data/a2" \
  "$SECOND_HOME_B/data/b1" "$SECOND_HOME_B/data/b2" \
  "$HOME_DIR/data/p1" "$HOME_DIR/data/p2"
write_ship_brief "$HOME_DIR" p1 'Primary multi-home fixture 1.'
write_ship_brief "$HOME_DIR" p2 'Primary multi-home fixture 2.'
write_ship_brief "$SECOND_HOME_A" a1 'Secondmate A fixture 1.'
write_ship_brief "$SECOND_HOME_A" a2 'Secondmate A fixture 2.'
write_ship_brief "$SECOND_HOME_B" b1 'Secondmate B fixture 1.'
write_ship_brief "$SECOND_HOME_B" b2 'Secondmate B fixture 2.'

MULTI_FOCUS_START=$(focus_audit_line_count)
spawn_task p1 "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/p1.out" 2> "$TMP_ROOT/p1.err" \
  || fail "multi-home primary p1 failed: $(cat "$TMP_ROOT/p1.err")"
spawn_task p2 "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/p2.out" 2> "$TMP_ROOT/p2.err" \
  || fail "multi-home primary p2 failed: $(cat "$TMP_ROOT/p2.err")"
spawn_task a1 "$SECOND_HOME_A" "$PROJECT_DIR" > "$TMP_ROOT/a1.out" 2> "$TMP_ROOT/a1.err" \
  || fail "multi-home secondmate A a1 failed: $(cat "$TMP_ROOT/a1.err")"
spawn_task a2 "$SECOND_HOME_A" "$PROJECT_DIR" > "$TMP_ROOT/a2.out" 2> "$TMP_ROOT/a2.err" \
  || fail "multi-home secondmate A a2 failed: $(cat "$TMP_ROOT/a2.err")"
spawn_task b1 "$SECOND_HOME_B" "$PROJECT_DIR" > "$TMP_ROOT/b1.out" 2> "$TMP_ROOT/b1.err" \
  || fail "multi-home secondmate B b1 failed: $(cat "$TMP_ROOT/b1.err")"
spawn_task b2 "$SECOND_HOME_B" "$PROJECT_DIR" > "$TMP_ROOT/b2.out" 2> "$TMP_ROOT/b2.err" \
  || fail "multi-home secondmate B b2 failed: $(cat "$TMP_ROOT/b2.err")"
for META_X in p1 p2 a1 a2 b1 b2; do
  case "$META_X" in
    p*) remember_meta_worktree "$HOME_DIR/state/$META_X.meta" >/dev/null ;;
    a*) remember_meta_worktree "$SECOND_HOME_A/state/$META_X.meta" >/dev/null ;;
    b*) remember_meta_worktree "$SECOND_HOME_B/state/$META_X.meta" >/dev/null ;;
  esac
done
assert_focus_is "$CAPTAIN_FOCUS" "multi-home sequential spawns"
assert_raw_presentation_mutations_preserved_since "$MULTI_FOCUS_START" "multi-home sequential spawns"

P1_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/p1.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
P2_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/p2.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
A1_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/a1.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
A2_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/a2.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
B1_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_B/state/b1.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
B2_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_B/state/b2.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
case "$P1_LABEL" in $'└ p1 · p:'*) ;; *) fail "primary p1 label wrong: $P1_LABEL" ;; esac
case "$P2_LABEL" in $'└ p2 · p:'*) ;; *) fail "primary p2 label wrong: $P2_LABEL" ;; esac
case "$A1_LABEL" in $'└ a1 · p:'*) ;; *) fail "secondmate A a1 label wrong: $A1_LABEL" ;; esac
case "$A2_LABEL" in $'└ a2 · p:'*) ;; *) fail "secondmate A a2 label wrong: $A2_LABEL" ;; esac
case "$B1_LABEL" in $'└ b1 · p:'*) ;; *) fail "secondmate B b1 label wrong: $B1_LABEL" ;; esac
case "$B2_LABEL" in $'└ b2 · p:'*) ;; *) fail "secondmate B b2 label wrong: $B2_LABEL" ;; esac

MULTI_LIST=$(lab workspace list) || fail "could not list multi-home topology"
MULTI_LABELS=$(printf '%s' "$MULTI_LIST" | jq -r '
  .result.workspaces[]
  | select(
      .label == "firstmate"
      or .label == "2ndmate-alpha"
      or .label == "2ndmate-bravo"
      or (.label | startswith("└ "))
    )
  | .label
')
MULTI_EXPECTED=$(printf '%s\n' \
  firstmate "$P1_LABEL" "$P2_LABEL" \
  2ndmate-alpha "$A1_LABEL" "$A2_LABEL" \
  2ndmate-bravo "$B1_LABEL" "$B2_LABEL")
[ "$MULTI_LABELS" = "$MULTI_EXPECTED" ] \
  || fail "multi-home topology was not owning-parent grouped: $MULTI_LABELS"
pass "real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block"

# Concurrent cross-home wave under the one session lock.
mkdir -p "$HOME_DIR/data/pcw" "$SECOND_HOME_A/data/acw" "$SECOND_HOME_B/data/bcw"
write_ship_brief "$HOME_DIR" pcw 'Cross-home concurrent primary.'
write_ship_brief "$SECOND_HOME_A" acw 'Cross-home concurrent A.'
write_ship_brief "$SECOND_HOME_B" bcw 'Cross-home concurrent B.'
WAVE_CROSS_FOCUS=$(focus_audit_line_count)
spawn_task pcw "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/pcw.out" 2> "$TMP_ROOT/pcw.err" &
PCW_PID=$!
spawn_task acw "$SECOND_HOME_A" "$PROJECT_DIR" > "$TMP_ROOT/acw.out" 2> "$TMP_ROOT/acw.err" &
ACW_PID=$!
spawn_task bcw "$SECOND_HOME_B" "$PROJECT_DIR" > "$TMP_ROOT/bcw.out" 2> "$TMP_ROOT/bcw.err" &
BCW_PID=$!
wait "$PCW_PID" || fail "cross-home concurrent primary failed: $(cat "$TMP_ROOT/pcw.err")"
wait "$ACW_PID" || fail "cross-home concurrent A failed: $(cat "$TMP_ROOT/acw.err")"
wait "$BCW_PID" || fail "cross-home concurrent B failed: $(cat "$TMP_ROOT/bcw.err")"
remember_meta_worktree "$HOME_DIR/state/pcw.meta" >/dev/null
remember_meta_worktree "$SECOND_HOME_A/state/acw.meta" >/dev/null
remember_meta_worktree "$SECOND_HOME_B/state/bcw.meta" >/dev/null
assert_focus_is "$CAPTAIN_FOCUS" "cross-home concurrent wave"
assert_raw_presentation_mutations_preserved_since "$WAVE_CROSS_FOCUS" "cross-home concurrent wave"
CROSS_LIST=$(lab workspace list)
printf '%s' "$CROSS_LIST" | jq -e '
  ([.result.workspaces[].label] | index("firstmate")) as $fm
  | ([.result.workspaces[].label] | index("2ndmate-alpha")) as $a
  | ([.result.workspaces[].label] | index("2ndmate-bravo")) as $b
  | $fm != null and $a != null and $b != null
  and $fm < $a and $a < $b
' >/dev/null 2>&1 || fail "cross-home concurrent wave reordered parents"
PCW_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/pcw.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
ACW_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/acw.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
BCW_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_B/state/bcw.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
case "$PCW_LABEL" in $'└ pcw · p:'*|firstmate) ;; *) fail "cross-home primary label wrong: $PCW_LABEL" ;; esac
case "$ACW_LABEL" in $'└ acw · p:'*|2ndmate-alpha) ;; *) fail "cross-home A label wrong: $ACW_LABEL" ;; esac
case "$BCW_LABEL" in $'└ bcw · p:'*|2ndmate-bravo) ;; *) fail "cross-home B label wrong: $BCW_LABEL" ;; esac
pass "real Herdr lab: concurrent primary/A/B spawns preserve parent order and exact focus"

# Hold the shared session lock from a different home and force flat fallback.
CROSS_LOCK_READY="$TMP_ROOT/cross-lock-ready"
CROSS_LOCK_RELEASE="$TMP_ROOT/cross-lock-release"
CROSS_LOCK_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve session lock for cross-home contention"
ROOT="$ROOT" READY="$CROSS_LOCK_READY" RELEASE="$CROSS_LOCK_RELEASE" LOCK="$CROSS_LOCK_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK"
' &
CROSS_LOCK_PID=$!
while [ ! -e "$CROSS_LOCK_READY" ] && kill -0 "$CROSS_LOCK_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$CROSS_LOCK_READY" ] || fail "could not hold the cross-home session presentation lock"
mkdir -p "$SECOND_HOME_A/data/aflat"
write_ship_brief "$SECOND_HOME_A" aflat 'Flat fallback under session lock contention.'
if spawn_task aflat "$SECOND_HOME_A" "$PROJECT_DIR" > "$TMP_ROOT/aflat.out" 2> "$TMP_ROOT/aflat.err"; then
  AFLAT_STATUS=0
else
  AFLAT_STATUS=$?
fi
: > "$CROSS_LOCK_RELEASE"
wait "$CROSS_LOCK_PID" || fail "cross-home session lock owner failed"
[ "$AFLAT_STATUS" -eq 0 ] \
  || fail "cross-home lock contention did not fall back flat: $(cat "$TMP_ROOT/aflat.err")"
grep -F "presentation focus lock unavailable; using the ordinary flat layout without projection" "$TMP_ROOT/aflat.err" >/dev/null 2>&1 \
  || fail "cross-home lock contention did not warn about flat fallback"
remember_meta_worktree "$SECOND_HOME_A/state/aflat.meta" >/dev/null
AFLAT_WSID=$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/aflat.meta" | cut -d= -f2-)
AFLAT_LABEL=$(lab workspace get "$AFLAT_WSID" | jq -r '.result.workspace.label')
[ "$AFLAT_LABEL" = 2ndmate-alpha ] \
  || fail "cross-home lock contention did not use the ordinary secondmate home workspace: $AFLAT_LABEL"
[ ! -e "$SECOND_HOME_A/state/aflat.herdr-presentation" ] \
  || fail "cross-home lock contention published a projection journal"
assert_focus_is "$CAPTAIN_FOCUS" "cross-home lock contention flat fallback"
teardown_task aflat "$SECOND_HOME_A" > "$TMP_ROOT/aflat-teardown.out" 2> "$TMP_ROOT/aflat-teardown.err" \
  || fail "flat cross-home contention fixture teardown failed"
pass "real Herdr lab: session lock contention from a secondmate home falls back flat with no journal"

# Same-identity recovery replaces only one exact agent-free husk in its
# original projected workspace.
# Exercise both the leading fm- identity style seen in Hi Bit work and the
# project-name identity style used by Wheelhouse work.
for RESTART_ID in fm-hibit-resume-r1 wheelhouse-healing-r1; do
  spawn_task "$RESTART_ID" "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/$RESTART_ID-first.out" 2> "$TMP_ROOT/$RESTART_ID-first.err" \
    || fail "$RESTART_ID fixture's projected spawn failed: $(cat "$TMP_ROOT/$RESTART_ID-first.err")"
  RESTART_META="$HOME_DIR/state/$RESTART_ID.meta"
  OLD_RESTART_WT=$(remember_meta_worktree "$RESTART_META")
  OLD_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
  OLD_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
  OLD_RESTART_LABEL=$(lab workspace get "$OLD_RESTART_WSID" | jq -r '.result.workspace.label')
  [ "$(grep '^version=' "$HOME_DIR/state/$RESTART_ID.herdr-presentation")" = version=2 ] \
    || fail "$RESTART_ID fresh projection did not publish an exact restart binding"
  EXPECTED_CONCISE=${RESTART_ID#fm-}
  case "$OLD_RESTART_LABEL" in
    "└ $EXPECTED_CONCISE · p:"*) ;;
    *) fail "$RESTART_ID fresh projection label did not apply concise prefix handling: $OLD_RESTART_LABEL" ;;
  esac
  PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
    || fail "could not stop the isolated session for $RESTART_ID validation"
  PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
    || fail "could not reprovision the isolated session for $RESTART_ID validation"
  # Stopping the whole Herdr session also ends the anchor's agent. Its restored
  # shell remains useful as the durable layout anchor, but its task record no
  # longer represents a live slot owner and must not poison later slot reuse.
  rm -f "$ANCHOR_META"
  lab pane get "$OLD_RESTART_PANE" >/dev/null 2>&1 \
    || fail "$RESTART_ID restart did not preserve the projected pane structurally"
  if lab agent get "$OLD_RESTART_PANE" >/dev/null 2>&1; then
    fail "$RESTART_ID restart fixture unexpectedly retained a registered agent"
  fi
  RECLAIM_FOCUS=$(focus_snapshot)
  spawn_task "$RESTART_ID" "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/$RESTART_ID-reclaim.out" 2> "$TMP_ROOT/$RESTART_ID-reclaim.err" \
    || fail "$RESTART_ID same-identity reclaim failed: $(cat "$TMP_ROOT/$RESTART_ID-reclaim.err")"
  NEW_RESTART_WT=$(remember_meta_worktree "$RESTART_META")
  NEW_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
  NEW_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
  [ "$NEW_RESTART_WSID" = "$OLD_RESTART_WSID" ] \
    || fail "$RESTART_ID reclaim flattened into a different workspace"
  [ "$NEW_RESTART_PANE" != "$OLD_RESTART_PANE" ] \
    || fail "$RESTART_ID reclaim reused the old husk pane"
  [ "$(lab workspace get "$NEW_RESTART_WSID" | jq -r '.result.workspace.label')" = "$OLD_RESTART_LABEL" ] \
    || fail "$RESTART_ID reclaim renamed or replaced the projected workspace"
  if lab pane get "$OLD_RESTART_PANE" >/dev/null 2>&1; then
    fail "$RESTART_ID reclaim did not close the exact old husk pane"
  fi
  [ "$(grep '^pane_id=' "$HOME_DIR/state/$RESTART_ID.herdr-presentation" | cut -d= -f2-)" = "$NEW_RESTART_PANE" ] \
    || fail "$RESTART_ID reclaim did not advance the exact journal binding"
  assert_focus_is "$RECLAIM_FOCUS" "$RESTART_ID same-identity reclaim"

  if [ "$RESTART_ID" = fm-hibit-resume-r1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
      || fail "could not stop the isolated session for idempotent reclaim"
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
      || fail "could not reprovision the isolated session for idempotent reclaim"
    PRIOR_RESTART_WT=$NEW_RESTART_WT
    PRIOR_RESTART_PANE=$NEW_RESTART_PANE
    spawn_task "$RESTART_ID" "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/$RESTART_ID-idempotent.out" 2> "$TMP_ROOT/$RESTART_ID-idempotent.err" \
      || fail "$RESTART_ID repeated reclaim failed: $(cat "$TMP_ROOT/$RESTART_ID-idempotent.err")"
    NEW_RESTART_WT=$(remember_meta_worktree "$RESTART_META")
    NEW_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
    NEW_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
    [ "$NEW_RESTART_WSID" = "$OLD_RESTART_WSID" ] \
      || fail "$RESTART_ID repeated reclaim changed workspace identity"
    [ "$NEW_RESTART_PANE" != "$PRIOR_RESTART_PANE" ] \
      || fail "$RESTART_ID repeated reclaim reused the prior husk pane"
    if [ "$PRIOR_RESTART_WT" != "$NEW_RESTART_WT" ]; then
      "$REAL_TREEHOUSE" return --force "$PRIOR_RESTART_WT" >/dev/null 2>&1 || true
    fi
  fi

  teardown_task "$RESTART_ID" "$HOME_DIR" > "$TMP_ROOT/$RESTART_ID-teardown.out" 2> "$TMP_ROOT/$RESTART_ID-teardown.err" \
    || fail "$RESTART_ID teardown after reclaim failed: $(cat "$TMP_ROOT/$RESTART_ID-teardown.err")"
  [ ! -e "$HOME_DIR/state/$RESTART_ID.herdr-presentation" ] \
    || fail "$RESTART_ID exact reclaimed teardown did not retire its journal"
  "$REAL_TREEHOUSE" return --force "$OLD_RESTART_WT" >/dev/null 2>&1 || true
  "$REAL_TREEHOUSE" return --force "$NEW_RESTART_WT" >/dev/null 2>&1 || true
done
pass "real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence"

# A secondmate child binds and reclaims only inside its own home and parent.
CROSS_RESTART_ID=wheel-child-resume
mkdir -p "$SECOND_HOME_A/data/$CROSS_RESTART_ID"
write_ship_brief "$SECOND_HOME_A" "$CROSS_RESTART_ID" 'Cross-home restart fixture.'
spawn_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" "$PROJECT_DIR" > "$TMP_ROOT/cross-restart-first.out" 2> "$TMP_ROOT/cross-restart-first.err" \
  || fail "cross-home restart fixture failed: $(cat "$TMP_ROOT/cross-restart-first.err")"
CROSS_RESTART_META="$SECOND_HOME_A/state/$CROSS_RESTART_ID.meta"
CROSS_OLD_WT=$(remember_meta_worktree "$CROSS_RESTART_META")
CROSS_OLD_WSID=$(grep '^herdr_workspace_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
CROSS_OLD_PANE=$(grep '^herdr_pane_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
CROSS_OLD_LABEL=$(lab workspace get "$CROSS_OLD_WSID" | jq -r '.result.workspace.label')
CROSS_BOUND_HOME=$(grep '^home=' "$SECOND_HOME_A/state/$CROSS_RESTART_ID.herdr-presentation" | cut -d= -f2-)
[ "$CROSS_BOUND_HOME" = "$(cd "$SECOND_HOME_A" && pwd -P)" ] \
  || fail "cross-home restart journal did not bind the secondmate's exact home"
[ ! -e "$HOME_DIR/state/$CROSS_RESTART_ID.herdr-presentation" ] \
  || fail "cross-home restart published a journal in the primary home"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for cross-home restart"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session for cross-home restart"
spawn_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" "$PROJECT_DIR" > "$TMP_ROOT/cross-restart-resume.out" 2> "$TMP_ROOT/cross-restart-resume.err" \
  || fail "cross-home same-identity reclaim failed: $(cat "$TMP_ROOT/cross-restart-resume.err")"
CROSS_NEW_WT=$(remember_meta_worktree "$CROSS_RESTART_META")
CROSS_NEW_WSID=$(grep '^herdr_workspace_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
CROSS_NEW_PANE=$(grep '^herdr_pane_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
[ "$CROSS_NEW_WSID" = "$CROSS_OLD_WSID" ] && [ "$CROSS_NEW_PANE" != "$CROSS_OLD_PANE" ] \
  || fail "cross-home reclaim did not replace one pane inside the same secondmate child workspace"
[ "$(lab workspace get "$CROSS_NEW_WSID" | jq -r '.result.workspace.label')" = "$CROSS_OLD_LABEL" ] \
  || fail "cross-home reclaim changed the secondmate child's presentation label"
teardown_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" > "$TMP_ROOT/cross-restart-teardown.out" 2> "$TMP_ROOT/cross-restart-teardown.err" \
  || fail "cross-home reclaimed teardown failed: $(cat "$TMP_ROOT/cross-restart-teardown.err")"
"$REAL_TREEHOUSE" return --force "$CROSS_OLD_WT" >/dev/null 2>&1 || true
"$REAL_TREEHOUSE" return --force "$CROSS_NEW_WT" >/dev/null 2>&1 || true
pass "real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent"

# Two homes recovering concurrently serialize on the named session lock and
# each replace only their own exact husk.
PRIMARY_WAVE_ID=resume-wave-primary
BRAVO_WAVE_ID=resume-wave-bravo
mkdir -p "$HOME_DIR/data/$PRIMARY_WAVE_ID" "$SECOND_HOME_B/data/$BRAVO_WAVE_ID"
write_ship_brief "$HOME_DIR" "$PRIMARY_WAVE_ID" 'Concurrent primary recovery fixture.'
write_ship_brief "$SECOND_HOME_B" "$BRAVO_WAVE_ID" 'Concurrent secondmate recovery fixture.'
spawn_task "$PRIMARY_WAVE_ID" "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/primary-wave-first.out" 2> "$TMP_ROOT/primary-wave-first.err" \
  || fail "primary recovery-wave fixture failed: $(cat "$TMP_ROOT/primary-wave-first.err")"
spawn_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" "$PROJECT_DIR" > "$TMP_ROOT/bravo-wave-first.out" 2> "$TMP_ROOT/bravo-wave-first.err" \
  || fail "secondmate recovery-wave fixture failed: $(cat "$TMP_ROOT/bravo-wave-first.err")"
PRIMARY_WAVE_META="$HOME_DIR/state/$PRIMARY_WAVE_ID.meta"
BRAVO_WAVE_META="$SECOND_HOME_B/state/$BRAVO_WAVE_ID.meta"
PRIMARY_WAVE_OLD_WT=$(remember_meta_worktree "$PRIMARY_WAVE_META")
BRAVO_WAVE_OLD_WT=$(remember_meta_worktree "$BRAVO_WAVE_META")
PRIMARY_WAVE_WSID=$(grep '^herdr_workspace_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_WSID=$(grep '^herdr_workspace_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
PRIMARY_WAVE_OLD_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_OLD_PANE=$(grep '^herdr_pane_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for concurrent recovery"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session for concurrent recovery"
CONCURRENT_RECOVERY_FOCUS=$(focus_snapshot)
spawn_task "$PRIMARY_WAVE_ID" "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/primary-wave-resume.out" 2> "$TMP_ROOT/primary-wave-resume.err" &
PRIMARY_WAVE_PID=$!
spawn_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" "$PROJECT_DIR" > "$TMP_ROOT/bravo-wave-resume.out" 2> "$TMP_ROOT/bravo-wave-resume.err" &
BRAVO_WAVE_PID=$!
wait "$PRIMARY_WAVE_PID" || fail "concurrent primary recovery failed: $(cat "$TMP_ROOT/primary-wave-resume.err")"
wait "$BRAVO_WAVE_PID" || fail "concurrent secondmate recovery failed: $(cat "$TMP_ROOT/bravo-wave-resume.err")"
PRIMARY_WAVE_NEW_WT=$(remember_meta_worktree "$PRIMARY_WAVE_META")
BRAVO_WAVE_NEW_WT=$(remember_meta_worktree "$BRAVO_WAVE_META")
PRIMARY_WAVE_NEW_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_NEW_PANE=$(grep '^herdr_pane_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
[ "$(grep '^herdr_workspace_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)" = "$PRIMARY_WAVE_WSID" ] \
  && [ "$(grep '^herdr_workspace_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)" = "$BRAVO_WAVE_WSID" ] \
  || fail "concurrent recovery flattened one task into a different workspace"
[ "$PRIMARY_WAVE_NEW_PANE" != "$PRIMARY_WAVE_OLD_PANE" ] \
  && [ "$BRAVO_WAVE_NEW_PANE" != "$BRAVO_WAVE_OLD_PANE" ] \
  || fail "concurrent recovery reused an old husk pane"
if lab pane get "$PRIMARY_WAVE_OLD_PANE" >/dev/null 2>&1 \
   || lab pane get "$BRAVO_WAVE_OLD_PANE" >/dev/null 2>&1; then
  fail "concurrent recovery left an old husk pane behind"
fi
assert_focus_is "$CONCURRENT_RECOVERY_FOCUS" "concurrent cross-home recovery"
teardown_task "$PRIMARY_WAVE_ID" "$HOME_DIR" > "$TMP_ROOT/primary-wave-teardown.out" 2> "$TMP_ROOT/primary-wave-teardown.err" \
  || fail "concurrent primary recovery teardown failed: $(cat "$TMP_ROOT/primary-wave-teardown.err")"
teardown_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" > "$TMP_ROOT/bravo-wave-teardown.out" 2> "$TMP_ROOT/bravo-wave-teardown.err" \
  || fail "concurrent secondmate recovery teardown failed: $(cat "$TMP_ROOT/bravo-wave-teardown.err")"
"$REAL_TREEHOUSE" return --force "$PRIMARY_WAVE_OLD_WT" >/dev/null 2>&1 || true
"$REAL_TREEHOUSE" return --force "$BRAVO_WAVE_OLD_WT" >/dev/null 2>&1 || true
"$REAL_TREEHOUSE" return --force "$PRIMARY_WAVE_NEW_WT" >/dev/null 2>&1 || true
"$REAL_TREEHOUSE" return --force "$BRAVO_WAVE_NEW_WT" >/dev/null 2>&1 || true
pass "real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift"

# Seed a legacy old-format primary projection and a flat secondmate tab; correction must not migrate them.
LEGACY_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/legacy-seed · p:AbCdEfGhIjKlMnOpQrStUv" --no-focus) \
  || fail "could not seed a legacy old-format presentation space"
LEGACY_WSID=$(printf '%s' "$LEGACY_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$LEGACY_WSID" ] || fail "legacy seed returned no workspace id"
FLAT_TAB_OUT=$(lab tab create --workspace "$(lab workspace list | jq -r '.result.workspaces[] | select(.label == "2ndmate-alpha") | .workspace_id' | head -1)" --cwd "$PROJECT_DIR" --label fm-flat-legacy-tab --no-focus) \
  || fail "could not seed a flat secondmate child tab"
FLAT_TAB_ID=$(printf '%s' "$FLAT_TAB_OUT" | jq -r '.result.tab.tab_id // empty')
mkdir -p "$HOME_DIR/data/post-legacy"
write_ship_brief "$HOME_DIR" post-legacy 'Post-legacy primary child.'
spawn_task post-legacy "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/post-legacy.out" 2> "$TMP_ROOT/post-legacy.err" \
  || fail "post-legacy projected spawn failed: $(cat "$TMP_ROOT/post-legacy.err")"
remember_meta_worktree "$HOME_DIR/state/post-legacy.meta" >/dev/null
[ "$(lab workspace get "$LEGACY_WSID" | jq -r '.result.workspace.label')" = "firstmate/legacy-seed · p:AbCdEfGhIjKlMnOpQrStUv" ] \
  || fail "correction renamed or moved the seeded legacy projection"
lab tab get "$FLAT_TAB_ID" >/dev/null 2>&1 \
  || fail "correction removed the seeded flat secondmate child tab"
pass "real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated"

# Teardown multi-home projected tasks by exact pane only.
for META_HOME_PAIR in \
  "p1:$HOME_DIR" "p2:$HOME_DIR" "pcw:$HOME_DIR" "post-legacy:$HOME_DIR" \
  "a1:$SECOND_HOME_A" "a2:$SECOND_HOME_A" "acw:$SECOND_HOME_A" \
  "alpha:$HOME_DIR" \
  "b1:$SECOND_HOME_B" "b2:$SECOND_HOME_B" "bcw:$SECOND_HOME_B"
do
  TASK_ID=${META_HOME_PAIR%%:*}
  TASK_HOME=${META_HOME_PAIR#*:}
  teardown_task "$TASK_ID" "$TASK_HOME" > "$TMP_ROOT/td-$TASK_ID.out" 2> "$TMP_ROOT/td-$TASK_ID.err" \
    || fail "multi-home teardown of $TASK_ID failed: $(cat "$TMP_ROOT/td-$TASK_ID.err")"
done
assert_focus_is "$CAPTAIN_FOCUS" "multi-home teardown"
pass "real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority"

# Missing, renamed, and duplicate tokens are read-only recovery diagnostics.
# The duplicate case allows flat fallback only when every matching pane is
# positively agent-free.
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

MISSING_STATE="$TMP_ROOT/missing-state"; mkdir -p "$MISSING_STATE"
fm_backend_herdr_projection_journal_create "$MISSING_STATE" missing1 >/dev/null
MISSING_JOURNAL=$(fm_backend_herdr_projection_journal_path "$MISSING_STATE" missing1)
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$MISSING_JOURNAL" missing1 \
  || fail "missing token match should degrade to flat"
assert_no_projection_mutation_since "$START" "missing-token recovery"

RENAMED_STATE="$TMP_ROOT/renamed-state"; mkdir -p "$RENAMED_STATE"
RENAMED_TOKEN=$(fm_backend_herdr_projection_journal_create "$RENAMED_STATE" renamed1)
RENAMED_JOURNAL=$(fm_backend_herdr_projection_journal_path "$RENAMED_STATE" renamed1)
RENAMED_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/renamed1 · p:$RENAMED_TOKEN" --no-focus)
RENAMED_WSID=$(printf '%s' "$RENAMED_OUT" | jq -r '.result.workspace.workspace_id')
lab workspace rename "$RENAMED_WSID" renamed-without-token >/dev/null
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$RENAMED_JOURNAL" renamed1 \
  || fail "renamed token match should degrade to flat"
assert_no_projection_mutation_since "$START" "renamed-token recovery"
lab workspace get "$RENAMED_WSID" >/dev/null 2>&1 || fail "renamed-token recovery removed or adopted the old workspace"

DUP_STATE="$TMP_ROOT/duplicate-state"; mkdir -p "$DUP_STATE"
DUP_TOKEN=$(fm_backend_herdr_projection_journal_create "$DUP_STATE" duplicate1)
DUP_JOURNAL=$(fm_backend_herdr_projection_journal_path "$DUP_STATE" duplicate1)
DUP1=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/duplicate1 · p:$DUP_TOKEN" --no-focus)
DUP2=$(lab workspace create --cwd "$PROJECT_DIR" --label "copy/duplicate1 · p:$DUP_TOKEN" --no-focus)
DUP1_WSID=$(printf '%s' "$DUP1" | jq -r '.result.workspace.workspace_id')
DUP2_WSID=$(printf '%s' "$DUP2" | jq -r '.result.workspace.workspace_id')
DUP1_PANE=$(printf '%s' "$DUP1" | jq -r '.result.root_pane.pane_id')
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1 \
  || fail "agent-free duplicate token matches should permit flat fallback"
assert_no_projection_mutation_since "$START" "agent-free duplicate-token recovery"
lab workspace get "$DUP1_WSID" >/dev/null 2>&1 || fail "duplicate-token recovery removed the first quarantined workspace"
lab workspace get "$DUP2_WSID" >/dev/null 2>&1 || fail "duplicate-token recovery removed the second quarantined workspace"

lab pane report-agent "$DUP1_PANE" --source fm-projection-e2e --agent test-agent --state idle >/dev/null \
  || fail "could not register the duplicate-live-agent risk fixture"
START=$(log_line_count)
if fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1; then
  fail "a duplicate token match with a registered agent should refuse fallback"
fi
assert_no_projection_mutation_since "$START" "live duplicate-token recovery"
lab workspace get "$DUP1_WSID" >/dev/null 2>&1 || fail "live duplicate refusal removed the first workspace"
lab workspace get "$DUP2_WSID" >/dev/null 2>&1 || fail "live duplicate refusal removed the second workspace"
pass "real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch"

STATUS_JSON=$(lab status --json)
HERDR_VERSION=$(printf '%s' "$STATUS_JSON" | jq -r '.client.version // "unknown"')
PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail "guarded Herdr lab teardown or default-session tripwire verification failed"
LAB_READY=0
pass "real Herdr lab validation completed on Herdr $HERDR_VERSION with the default-session tripwire intact"

cleanup_all
trap - EXIT
