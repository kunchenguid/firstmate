#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for the default-on disposable single-task
# presentation projection, its explicit opt-out, and its best-effort
# owning-parent ordering across primary and secondmate homes.
# The test drives the real spawn and teardown scripts, a real Treehouse pool,
# and the guarded named-session lab helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

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
FOREIGN_ATTACH_CONTROL="$TMP_ROOT/foreign-attach-control"
export ACTIVE_SEEDED_CONTROL POST_CREATE_ABORT_CONTROL FOREIGN_ATTACH_CONTROL TMP_ROOT

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
worktree_path=$(arg_value --path "$@" || true)
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
  "worktree open") mutation=worktree-open; mutation_target=$worktree_path ;;
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
# Herdr reports a structured error on stderr, so capture both streams: the
# abort-pane tracking below reads the error code, and stderr is replayed
# untouched before exit so callers that merge the streams see it as before.
herdr_err=$(mktemp "$TMP_ROOT/herdr-err.XXXXXX")
if out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@" 2>"$herdr_err"); then
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
    fm-abort-resume)
      # This fixture spawns twice and only the second one is armed, so it
      # records a pane only once the control root already exists.
      if [ -d "$POST_CREATE_ABORT_CONTROL" ]; then
        mkdir -p "$POST_CREATE_ABORT_CONTROL/abort-resume"
        printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$POST_CREATE_ABORT_CONTROL/abort-resume/task-pane"
      fi
      ;;
  esac
fi
if [ "${1:-} ${2:-}" = "worktree list" ] && [ "$status" -eq 0 ] && [ -d "$FOREIGN_ATTACH_CONTROL" ]; then
  # Treehouse never hands out a slot another process occupies, so a foreign
  # workspace can reach the task worktree only between the lease and the
  # attach; stand in for that occupant by reporting the seeded foreign
  # workspace as the one open in every worktree other than the clone root.
  foreign_ws=$(cat "$FOREIGN_ATTACH_CONTROL/workspace" 2>/dev/null || true)
  foreign_clone=$(cat "$FOREIGN_ATTACH_CONTROL/clone" 2>/dev/null || true)
  if [ -n "$foreign_ws" ]; then
    out=$(printf '%s' "$out" | jq --arg ws "$foreign_ws" --arg clone "$foreign_clone" '
      if (.result.worktrees | type) == "array" then
        .result.worktrees |= map(if .path != $clone then .open_workspace_id = $ws else . end)
      else . end
    ')
    printf '%s\n' "$*" >> "$FOREIGN_ATTACH_CONTROL/hits"
  fi
fi
if [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$POST_CREATE_ABORT_CONTROL" ]; then
  for task_dir in "$POST_CREATE_ABORT_CONTROL"/abort-*; do
    [ -d "$task_dir" ] || continue
    [ "${3:-}" = "$(cat "$task_dir/task-pane" 2>/dev/null || true)" ] || continue
    if [ "$({ printf '%s\n' "$out"; cat "$herdr_err"; } | jq -r 'select(type == "object") | .error.code // empty' 2>/dev/null | grep -Fx pane_not_found || true)" = pane_not_found ]; then
      # The focus-safe emptying-close plan ends a lone idle pane shell instead
      # of issuing pane close, so the first not-found read of a tracked abort
      # pane is the cleanup evidence the abort sequence check orders.
      if mkdir "$task_dir/death-seen" 2>/dev/null; then
        death_snapshot=$(focus_snapshot || printf ambiguous/ambiguous)
        printf 'pane-death\t%s\t%s\t%s\n' "$death_snapshot" "$death_snapshot" "${3:-}" >> "$FOCUS_AUDIT_LOG"
      fi
    elif [ "$status" -eq 0 ]; then
      out=$(printf '%s' "$out" | jq --arg cwd "$POST_CREATE_ABORT_CONTROL/not-a-worktree" '.result.pane.foreground_cwd = $cwd')
    fi
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
[ ! -s "$herdr_err" ] || cat "$herdr_err" >&2
rm -f "$herdr_err"
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
LOCK_REFUSE_HOLDER_PID=
LOCK_WAIT_HOLDER_PID=
cleanup_all() {
  local wt pid
  for pid in "$LOCK_CONTENTION_OWNER_PID" "$LOCK_REFUSE_HOLDER_PID" "$LOCK_WAIT_HOLDER_PID"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  LOCK_CONTENTION_OWNER_PID=
  LOCK_REFUSE_HOLDER_PID=
  LOCK_WAIT_HOLDER_PID=
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

# A session stop and re-provision stands in for a Herdr restart. Where the
# restored session's focus lands is Herdr's own choice (0.7.x can land it on a
# task tab while 0.9.x restores the exact pre-stop tab), so every restart
# re-pins the captain's tab and records what the restore did, which keeps the
# captain-focus assertions below about Firstmate's own mutations only.
restart_lab_session() {  # <case-name>
  local case_name=$1 landed
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
    || fail "could not stop the isolated session for $case_name"
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
    || fail "could not reprovision the isolated session for $case_name"
  landed=$(focus_snapshot)
  if [ "$landed" != "$CAPTAIN_FOCUS" ]; then
    lab tab focus "$SECOND_TWO_TAB" >/dev/null \
      || fail "could not re-pin the captain tab after the $case_name restart landed focus on $landed"
  fi
  printf 'session-restart\t%s\t%s\t%s\n' "$landed" "$(focus_snapshot)" "$SECOND_TWO_TAB" >> "$FOCUS_AUDIT_LOG"
  assert_focus_is "$CAPTAIN_FOCUS" "re-pinning the captain tab after the $case_name restart"
}

assert_raw_presentation_mutations_preserved_since() {  # <line-count> <case-name>
  local start=$1 case_name=$2 changed
  changed=$(sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' '
    ($1 == "workspace-create" || $1 == "tab-create" || $1 == "workspace-move" || $1 == "pane-close" || $1 == "worktree-open") && $2 != $3 {
      print $0
    }
  ')
  [ -z "$changed" ] || fail "$case_name changed active workspace/tab inside a create, move, attach, or seeded cleanup: $changed"
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

spawn_task() {  # <id> <home> <project> [extra fm-spawn args...]; SPAWN_DEADLINE_SECONDS bounds the run
  local id=$1 home=$2 project=$3
  shift 3
  local -a deadline_cmd=()
  [ -z "${SPAWN_DEADLINE_SECONDS:-}" ] || deadline_cmd=(fm_run_timed "$SPAWN_DEADLINE_SECONDS")
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    ${deadline_cmd[@]+"${deadline_cmd[@]}"} "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" \
    --mode no-mistakes --yolo off --backend herdr "$@"
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

# Repo worktree groups (docs/herdr-backend.md "Presentation spaces") ride on the
# adapter's own capability gate, so every grouped assertion below is
# release-aware: it proves the attach on a client whose schema exposes
# worktree.open and worktree.list, and proves the flat rows with zero attach
# calls on one that does not.
grouping_capable() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_worktree_group_capable "$1"
  ' "$ROOT" "$HERDR_LAB_SESSION"
}

# record_repo_parent_retry <parent-id> <label> <clone> [<seeded-pane-id>]: records a refused
# fresh-parent removal exactly as the spawn does, through the adapter's own
# per-home record, so the next spawn's retry can be exercised without having
# to make Herdr refuse a pane close in the middle of a spawn.
record_repo_parent_retry() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_repo_parent_retry_record "$1" "$2" "$3" "$4" "$5" "${6:-}"
  ' "$ROOT" "$HOME_DIR/state" "$HERDR_LAB_SESSION" "$@"
}

realpath_of() { (cd "$1" 2>/dev/null && pwd -P); }

# assert_linked_child <workspace-id> <worktree> <clone> <case-name> [<spawn-stderr>]:
# the workspace carries Herdr's linked-worktree provenance for exactly
# <worktree> inside <clone>, and Herdr reports <worktree> open in exactly that
# workspace. A failure quotes the spawn's own warnings when its stderr is given.
assert_linked_child() {  # <workspace-id> <worktree> <clone> <case-name> [<spawn-stderr>]
  local wsid=$1 worktree=$2 clone=$3 case_name=$4 spawn_err=${5:-} info detail=
  info=$(lab workspace get "$wsid") || fail "$case_name: could not inspect workspace $wsid"
  [ -z "$spawn_err" ] || detail=" (spawn stderr: $(cat "$spawn_err" 2>/dev/null); recent worktree calls: $(grep -E $'^worktree\t' "$HERDR_CALL_LOG" | tail -3 | tr '\t' ' ' | tr '\n' ';'))"
  printf '%s' "$info" | jq -e '
    .result.workspace.worktree.is_linked_worktree == true
    and (.result.workspace.worktree.checkout_path | type) == "string"
    and (.result.workspace.worktree.repo_root | type) == "string"
  ' >/dev/null 2>&1 || fail "$case_name: workspace $wsid is not a linked-worktree child: $info$detail"
  [ "$(realpath_of "$(printf '%s' "$info" | jq -r '.result.workspace.worktree.checkout_path')")" = "$(realpath_of "$worktree")" ] \
    || fail "$case_name: linked child $wsid checks out somewhere other than its task worktree"
  [ "$(realpath_of "$(printf '%s' "$info" | jq -r '.result.workspace.worktree.repo_root')")" = "$(realpath_of "$clone")" ] \
    || fail "$case_name: linked child $wsid names a repository root other than the project clone"
  [ "$(lab worktree list --cwd "$worktree" | jq -r --arg real "$(realpath_of "$worktree")" '[.result.worktrees[] | select(.path == $real)] | select(length == 1) | .[0].open_workspace_id // empty')" = "$wsid" ] \
    || fail "$case_name: Herdr does not report the task worktree open in exactly workspace $wsid"
}

# assert_flat_row <workspace-id> <case-name>: the workspace carries no
# linked-worktree provenance at all.
assert_flat_row() {  # <workspace-id> <case-name>
  local wsid=$1 case_name=$2
  lab workspace get "$wsid" | jq -e '(.result.workspace.worktree.is_linked_worktree // false) != true' >/dev/null 2>&1 \
    || fail "$case_name: workspace $wsid unexpectedly became a linked-worktree child"
}

# repo_parent_id <label> <case-name>: the exactly-one workspace carrying
# <label> that Herdr reports as its own group source.
repo_parent_id() {  # <label> <case-name>
  local label=$1 case_name=$2 wsid
  wsid=$(lab workspace list | jq -r --arg label "$label" '[.result.workspaces[] | select(.label == $label)] | select(length == 1) | .[0].workspace_id // empty')
  [ -n "$wsid" ] || fail "$case_name: expected exactly one workspace labelled '$label': $(lab workspace list | jq -c '[.result.workspaces[].label]')"
  [ "$(lab worktree list --workspace "$wsid" | jq -r '.result.source.source_workspace_id // empty')" = "$wsid" ] \
    || fail "$case_name: repo parent '$label' ($wsid) is not its own group source"
  printf '%s' "$wsid"
}

assert_no_attach_calls_since() {  # <line-count> <case-name>
  local start=$1 name=$2
  if sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG" | grep -E $'^worktree\topen' >/dev/null 2>&1; then
    fail "$name ran worktree open"
  fi
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
RECOVERY_PROJECT_DIR="$TMP_ROOT/recovery-project"
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
write_ship_brief "$HOME_DIR" abort-resume 'Projection respawn abort fixture.'
write_ship_brief "$HOME_DIR" lock-contended 'Projection lock contention fixture.'
write_ship_brief "$HOME_DIR" default-on 'Projection default-on fixture.'
make_project "$PROJECT_DIR"
make_project "$RECOVERY_PROJECT_DIR"

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
if grouping_capable; then GROUPING_CAPABLE=1; else GROUPING_CAPABLE=0; fi
[ "$GROUPING_CAPABLE" = 1 ] || [ "$FLOOR_VERDICT" = 1 ] || [ "$FLOOR_PROTOCOL" -lt 22 ] \
  || fail "herdr $FLOOR_VERSION protocol $FLOOR_PROTOCOL is at the presentation floor yet reports no worktree grouping capability"
PROJECT_REPO_LABEL=$(basename "$PROJECT_DIR")
RECOVERY_REPO_LABEL=$(basename "$RECOVERY_PROJECT_DIR")
DEFAULT_ON_LOG_START=$(log_line_count)
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
  if [ "$GROUPING_CAPABLE" = 1 ]; then
    REPO_PARENT_WSID=$(repo_parent_id "$PROJECT_REPO_LABEL" "first grouped spawn")
    assert_linked_child "$DEFAULT_ON_WSID" "$(grep '^worktree=' "$DEFAULT_ON_META" | cut -d= -f2-)" "$PROJECT_DIR" "first grouped spawn" "$TMP_ROOT/default-on.err"
    sed -n "$((DEFAULT_ON_LOG_START + 1)),\$p" "$HERDR_CALL_LOG" \
      | grep -F $'worktree\topen\t--workspace\t'"$REPO_PARENT_WSID"$'\t--path\t'"$(grep '^worktree=' "$DEFAULT_ON_META" | cut -d= -f2-)"$'\t--no-focus' >/dev/null 2>&1 \
      || fail "first grouped spawn did not attach through the exact repo parent with --no-focus"
    [ "$(sed -n "$((DEFAULT_ON_LOG_START + 1)),\$p" "$HERDR_CALL_LOG" | grep -c $'^workspace\tcreate\t--cwd\t'"$PROJECT_DIR"$'\t--label\t'"$PROJECT_REPO_LABEL"$'\t--no-focus')" = 1 ] \
      || fail "first grouped spawn did not create exactly one repo parent with --no-focus"
    pass "real Herdr lab: the first projected task on a repository creates its home's repo parent and attaches as a linked-worktree child"
  else
    assert_no_attach_calls_since "$DEFAULT_ON_LOG_START" "projected spawn without worktree grouping"
    pass "real Herdr lab: a projected task stays a flat row with zero attach calls when herdr $FLOOR_VERSION exposes no worktree grouping"
  fi
else
  assert_no_attach_calls_since "$DEFAULT_ON_LOG_START" "flat below-floor spawn"
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
if [ "$FLOOR_VERDICT" = 0 ] && [ "$GROUPING_CAPABLE" = 1 ]; then
  lab workspace get "$REPO_PARENT_WSID" | jq -e --arg root "$(realpath_of "$PROJECT_DIR")" '
    .result.workspace.label == "'"$PROJECT_REPO_LABEL"'"
    and .result.workspace.worktree.is_linked_worktree == false
  ' >/dev/null 2>&1 || fail "the repo parent did not persist as a non-linked root after its only child was cleaned up"
  [ "$(realpath_of "$(lab workspace get "$REPO_PARENT_WSID" | jq -r '.result.workspace.worktree.checkout_path')")" = "$(realpath_of "$PROJECT_DIR")" ] \
    || fail "the persisted repo parent checks out somewhere other than the project clone"
  pass "real Herdr lab: the repo parent persists with root provenance after its only child is cleaned up"
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
SHAPE_LOG_START=$(log_line_count)
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/on.out" 2> "$TMP_ROOT/on.err" \
  || fail "projected spawn failed: $(cat "$TMP_ROOT/on.err")"
assert_focus_is "$CAPTAIN_FOCUS" "projected spawn"
assert_raw_presentation_mutations_preserved_since "$SHAPE_FOCUS_AUDIT_START" "projected spawn"
ON_META="$TMP_ROOT/on.meta"
cp "$HOME_DIR/state/shape.meta" "$ON_META"
ON_WT=$(remember_meta_worktree "$ON_META")
cmp -s "$TMP_ROOT/off-treehouse.log" "$TREEHOUSE_CALL_LOG" \
  || fail "Treehouse command sequence changed between opted-out and projected spawns"
# A Herdr spawn takes its slot as a durable lease under the task's own name and
# walks the pane's root shell into it, never through the interactive get whose
# subshell would leave the root shell in the clone (docs/herdr-backend.md
# "Watching and task containers"); the slot reads leased to fm-shape while the
# task lives and is free again once teardown's ordinary return runs.
grep -Fx $'get\t--lease\t--lease-holder\tfm-shape' "$TREEHOUSE_CALL_LOG" >/dev/null 2>&1 \
  || fail "projected spawn did not lease its Treehouse slot under the task's name: $(cat "$TREEHOUSE_CALL_LOG")"
if grep -Fx 'get' "$TREEHOUSE_CALL_LOG" >/dev/null 2>&1; then
  fail "projected spawn still ran the interactive treehouse get: $(cat "$TREEHOUSE_CALL_LOG")"
fi
(cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>/dev/null) | grep -F 'held by fm-shape' >/dev/null 2>&1 \
  || fail "Treehouse does not report the projected task's slot leased to fm-shape: $(cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>&1)"
[ "$(realpath_of "$ON_WT")" = "$(realpath_of "$(lab pane get "$(grep '^herdr_pane_id=' "$ON_META" | cut -d= -f2-)" | jq -r '.result.pane.foreground_cwd // empty')")" ] \
  || fail "the projected task pane's foreground shell is not in the recorded leased worktree"
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
if [ "$GROUPING_CAPABLE" = 1 ]; then
  [ "$(repo_parent_id "$PROJECT_REPO_LABEL" "second grouped spawn")" = "$REPO_PARENT_WSID" ] \
    || fail "a later spawn on the same repository did not adopt the existing repo parent"
  [ "$(sed -n "$((SHAPE_LOG_START + 1)),\$p" "$HERDR_CALL_LOG" | grep -c $'^workspace\tcreate\t--cwd\t'"$PROJECT_DIR"$'\t--label\t'"$PROJECT_REPO_LABEL"$'\t')" = 0 ] \
    || fail "a later spawn on the same repository created a second repo parent"
  assert_linked_child "$PROJECTED_WSID" "$ON_WT" "$PROJECT_DIR" "second grouped spawn" "$TMP_ROOT/on.err"
  grep -F "herdr repo grouping" "$TMP_ROOT/on.err" >/dev/null 2>&1 \
    && fail "a successful grouped spawn warned about grouping: $(cat "$TMP_ROOT/on.err")"
  pass "real Herdr lab: a later projected task adopts the existing repo parent without creating, renaming, or focusing anything"
else
  assert_no_attach_calls_since "$SHAPE_LOG_START" "projected spawn without worktree grouping"
fi

mkdir -p "$ACTIVE_SEEDED_CONTROL"
printf '%s\n' requested > "$ACTIVE_SEEDED_CONTROL/stage"
ACTIVE_SEEDED_START=$(log_line_count)
cp "$MOVE_CALL_LOG" "$TMP_ROOT/move-log-before-active-seeded"
if ! spawn_task active-seeded "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/active-seeded.out" 2> "$TMP_ROOT/active-seeded.err"; then
  fail "detached persisted-focus seeded prune should succeed: $(cat "$TMP_ROOT/active-seeded.err")"
fi
if grep -F "target is the captain's active tab" "$TMP_ROOT/active-seeded.err" >/dev/null 2>&1; then
  fail "detached persisted-focus seeded prune still used the live-viewer refusal"
fi
ACTIVE_SEEDED_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane")
ACTIVE_SEEDED_TASK_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/task-pane")
if lab pane get "$ACTIVE_SEEDED_PANE" >/dev/null 2>&1; then
  fail "detached persisted-focus seeded prune left the seeded pane behind"
fi
lab pane get "$ACTIVE_SEEDED_TASK_PANE" >/dev/null 2>&1 \
  || fail "detached persisted-focus seeded prune lost the task pane"
sed -n "$((ACTIVE_SEEDED_START + 1)),\$p" "$HERDR_CALL_LOG" | grep -F $'pane\tclose\t'"$ACTIVE_SEEDED_PANE" >/dev/null 2>&1 \
  || fail "detached persisted-focus seeded prune did not close the seeded pane"
lab tab focus "$SECOND_TWO_TAB" >/dev/null || fail "could not restore the captured captain tab after the active seeded-tab fixture"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture restoration"
rm -rf "$ACTIVE_SEEDED_CONTROL"
remember_meta_worktree "$HOME_DIR/state/active-seeded.meta" >/dev/null
teardown_task active-seeded "$HOME_DIR" > "$TMP_ROOT/active-seeded-teardown.out" 2> "$TMP_ROOT/active-seeded-teardown.err" \
  || fail "detached persisted-focus seeded prune leftover teardown failed: $(cat "$TMP_ROOT/active-seeded-teardown.err")"
cp "$TMP_ROOT/move-log-before-active-seeded" "$MOVE_CALL_LOG"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture cleanup"
pass "real Herdr lab: persisted-focused seeded prune proceeds when no live client is attached"

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
  || fail "flat lock-contention fixture teardown failed: $(cat "$TMP_ROOT/lock-contended-teardown.err")"
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
if [ "$GROUPING_CAPABLE" = 1 ]; then
  # The repo parent row was created right after the home workspace and is a
  # member of the home block, so the projected children follow it.
  EXPECTED_LABELS=$(printf 'firstmate\n%s\n%s\n%s\n2ndmate-alpha\n2ndmate-bravo' "$PROJECT_REPO_LABEL" "$PROJECTED_LABEL" "$CREATED_LABELS")
  EXPECTED_MOVE_INDEXES=$'2\n3\n4'
else
  EXPECTED_LABELS=$(printf 'firstmate\n%s\n%s\n2ndmate-alpha\n2ndmate-bravo' "$PROJECTED_LABEL" "$CREATED_LABELS")
  EXPECTED_MOVE_INDEXES=$'1\n2\n3'
fi
ACTUAL_LABELS=$(printf '%s' "$ORDER_LIST" | jq -r '.result.workspaces[].label')
[ "$ACTUAL_LABELS" = "$EXPECTED_LABELS" ] || fail "workspace order was not firstmate, repo parent when grouped, stable primary block, secondmates: $ACTUAL_LABELS"
PRIMARY_IDS=$(printf '%s' "$ORDER_LIST" | jq -r '
  .result.workspaces[]
  | select((.label | startswith("└ ")) or (.label | startswith("firstmate/")))
  | .workspace_id
')
MOVE_TARGETS=$(cut -f2 "$MOVE_CALL_LOG")
[ "$MOVE_TARGETS" = "$PRIMARY_IDS" ] \
  || fail "workspace.move targeted something other than each exact current projected-create id"
MOVE_INDEXES=$(cut -f3 "$MOVE_CALL_LOG")
[ "$MOVE_INDEXES" = "$EXPECTED_MOVE_INDEXES" ] \
  || fail "concurrent primary workers did not append stably to the contiguous block: $MOVE_INDEXES"
SECOND_ORDER_AFTER=$(printf '%s' "$ORDER_LIST" | jq -r '.result.workspaces[] | select(.label | startswith("2ndmate-")) | .workspace_id')
[ "$SECOND_ORDER_AFTER" = "$SECOND_ORDER_BEFORE" ] \
  || fail "primary workspace ordering changed secondmate relative order"
[ "$(lab workspace get "$SECOND_TWO_WSID" | jq -r '.result.workspace.focused')" = true ] \
  || fail "concurrent primary workspace ordering stole focus"
assert_no_ordering_lifecycle_calls_since "$PROJECTION_ORDER_START" "successful presentation ordering"
pass "real Herdr lab: concurrent primary workers form one stable contiguous block without active workspace/tab drift"
if [ "$GROUPING_CAPABLE" = 1 ]; then
  ORDER_A_WSID=$(grep '^herdr_workspace_id=' "$ORDER_A_META" | cut -d= -f2-)
  ORDER_B_WSID=$(grep '^herdr_workspace_id=' "$ORDER_B_META" | cut -d= -f2-)
  assert_linked_child "$ORDER_A_WSID" "$(grep '^worktree=' "$ORDER_A_META" | cut -d= -f2-)" "$PROJECT_DIR" "two tasks on one repository" "$TMP_ROOT/order-a.err"
  assert_linked_child "$ORDER_B_WSID" "$(grep '^worktree=' "$ORDER_B_META" | cut -d= -f2-)" "$PROJECT_DIR" "two tasks on one repository" "$TMP_ROOT/order-b.err"
  [ "$(lab workspace get "$ORDER_A_WSID" | jq -r '.result.workspace.worktree.repo_key')" = "$(lab workspace get "$ORDER_B_WSID" | jq -r '.result.workspace.worktree.repo_key')" ] \
    || fail "two tasks on one repository were attached under different repository keys"
  [ "$(lab worktree list --workspace "$REPO_PARENT_WSID" | jq -r --arg a "$ORDER_A_WSID" --arg b "$ORDER_B_WSID" '[.result.worktrees[] | select(.open_workspace_id == $a or .open_workspace_id == $b)] | length')" = 2 ] \
    || fail "the repo parent's own group listing does not carry both concurrent children"
  [ "$(repo_parent_id "$PROJECT_REPO_LABEL" "two tasks on one repository")" = "$REPO_PARENT_WSID" ] \
    || fail "concurrent grouped spawns created a second repo parent"
  pass "real Herdr lab: two concurrent tasks on one repository attach as linked children of the same single repo parent"
fi

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

# The first task on a repository creates that repository's parent, and only
# the ordering move puts the task ahead of it. When that move fails at runtime
# the spawn removes exactly the parent it just created while it is still
# childless, through its seeded pane and never a workspace close, so no parent
# without provenance is left standing, the task stays
# in the flat row, and the next task on the repository groups normally.
if [ "$GROUPING_CAPABLE" = 1 ]; then
  FRESH_PROJECT_DIR="$TMP_ROOT/fresh-project"
  make_project "$FRESH_PROJECT_DIR"
  FRESH_REPO_LABEL=$(basename "$FRESH_PROJECT_DIR")
  mkdir -p "$HOME_DIR/data/fresh-fail" "$HOME_DIR/data/fresh-ok"
  write_ship_brief "$HOME_DIR" fresh-fail 'Fresh repository ordering failure fixture.'
  write_ship_brief "$HOME_DIR" fresh-ok 'Fresh repository regrouping fixture.'
  FRESH_FAIL_START=$(log_line_count)
  FRESH_FAIL_FOCUS_START=$(focus_audit_line_count)
  FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAIL_MOVER" \
    spawn_task fresh-fail "$HOME_DIR" "$FRESH_PROJECT_DIR" > "$TMP_ROOT/fresh-fail.out" 2> "$TMP_ROOT/fresh-fail.err" \
    || fail "fresh-repository move-failure spawn should still succeed: $(cat "$TMP_ROOT/fresh-fail.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository move failure"
  assert_raw_presentation_mutations_preserved_since "$FRESH_FAIL_FOCUS_START" "fresh-repository move failure"
  grep -F "workspace move failed or had an ambiguous response" "$TMP_ROOT/fresh-fail.err" >/dev/null 2>&1 \
    || fail "fresh-repository move failure did not report the best-effort ordering warning: $(cat "$TMP_ROOT/fresh-fail.err")"
  grep -F "closed the repo parent" "$TMP_ROOT/fresh-fail.err" >/dev/null 2>&1 \
    || fail "fresh-repository move failure did not report removing the parent it created: $(cat "$TMP_ROOT/fresh-fail.err")"
  FRESH_FAIL_META="$HOME_DIR/state/fresh-fail.meta"
  remember_meta_worktree "$FRESH_FAIL_META" >/dev/null
  FRESH_FAIL_WSID=$(grep '^herdr_workspace_id=' "$FRESH_FAIL_META" | cut -d= -f2-)
  FRESH_FAIL_PANE=$(grep '^herdr_pane_id=' "$FRESH_FAIL_META" | cut -d= -f2-)
  FRESH_LIST=$(lab workspace list) || fail "could not inspect the fresh-repository fallback"
  [ "$(printf '%s' "$FRESH_LIST" | jq -r --arg label "$FRESH_REPO_LABEL" '[.result.workspaces[] | select(.label == $label)] | length')" = 0 ] \
    || fail "fresh-repository move failure left a repo parent standing: $(printf '%s' "$FRESH_LIST" | jq -c '[.result.workspaces[].label]')"
  [ "$(printf '%s' "$FRESH_LIST" | jq -r '.result.workspaces[-1].workspace_id')" = "$FRESH_FAIL_WSID" ] \
    || fail "fresh-repository move failure did not leave the task in Herdr's default appended order"
  assert_flat_row "$FRESH_FAIL_WSID" "fresh-repository move failure"
  lab pane get "$FRESH_FAIL_PANE" >/dev/null 2>&1 \
    || fail "fresh-repository move failure cleaned up the task pane"
  FRESH_CALLS=$(sed -n "$((FRESH_FAIL_START + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$FRESH_CALLS" | awk -F '\t' '$1 == "workspace" && $2 == "close" { found = 1 } END { exit !found }'; then
    fail "fresh-repository move failure used a workspace close instead of the focus-preserving pane path"
  fi
  FRESH_PARENT_PANE_CLOSES=$(printf '%s\n' "$FRESH_CALLS" | awk -F '\t' '$1 == "pane" && $2 == "close" && $3 != "'"$FRESH_FAIL_PANE"'" { print $3 }')
  [ "$(printf '%s\n' "$FRESH_PARENT_PANE_CLOSES" | awk 'NF { n += 1 } END { print n + 0 }')" = 1 ] \
    || fail "fresh-repository move failure closed these panes instead of exactly the parent's seeded pane: $FRESH_PARENT_PANE_CLOSES"
  assert_cleanup_focus_preserved "$FRESH_FAIL_FOCUS_START" "$FRESH_PARENT_PANE_CLOSES" "$CAPTAIN_FOCUS"
  if sed -n "$((FRESH_FAIL_START + 1)),\$p" "$HERDR_CALL_LOG" | grep -E $'^(tab\tclose|workspace\trename|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "fresh-repository move failure performed a tab close, rename, or session lifecycle call"
  fi
  pass "real Herdr lab: a runtime move failure on a repository's first task removes the fresh childless parent through its pane and leaves the task flat"

  FRESH_OK_FOCUS_START=$(focus_audit_line_count)
  spawn_task fresh-ok "$HOME_DIR" "$FRESH_PROJECT_DIR" > "$TMP_ROOT/fresh-ok.out" 2> "$TMP_ROOT/fresh-ok.err" \
    || fail "spawn after the fresh-repository move failure failed: $(cat "$TMP_ROOT/fresh-ok.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "spawn after the fresh-repository move failure"
  assert_raw_presentation_mutations_preserved_since "$FRESH_OK_FOCUS_START" "spawn after the fresh-repository move failure"
  if grep -E 'workspace move failed|closed the repo parent|leaving this task.s space flat' "$TMP_ROOT/fresh-ok.err" >/dev/null 2>&1; then
    fail "spawn after the fresh-repository move failure fell back to the flat row or closed a parent: $(cat "$TMP_ROOT/fresh-ok.err")"
  fi
  FRESH_OK_META="$HOME_DIR/state/fresh-ok.meta"
  remember_meta_worktree "$FRESH_OK_META" >/dev/null
  FRESH_OK_WSID=$(grep '^herdr_workspace_id=' "$FRESH_OK_META" | cut -d= -f2-)
  FRESH_PARENT_WSID=$(repo_parent_id "$FRESH_REPO_LABEL" "spawn after the fresh-repository move failure")
  assert_linked_child "$FRESH_OK_WSID" "$(grep '^worktree=' "$FRESH_OK_META" | cut -d= -f2-)" "$FRESH_PROJECT_DIR" "spawn after the fresh-repository move failure" "$TMP_ROOT/fresh-ok.err"
  [ "$(grep '^version=' "$HOME_DIR/state/fresh-ok.herdr-presentation")" = version=2 ] \
    || fail "spawn after the fresh-repository move failure did not publish an exact restart binding"
  FRESH_OK_LIST=$(lab workspace list) || fail "could not inspect the layout after the fresh-repository regrouping"
  printf '%s' "$FRESH_OK_LIST" | jq -e --arg child "$FRESH_OK_WSID" --arg parent "$FRESH_PARENT_WSID" --arg flat "$FRESH_FAIL_WSID" --arg alpha "$SECOND_ONE_WSID" '
    [.result.workspaces[].workspace_id] as $ids
    | ($ids | index($child)) < ($ids | index($alpha))
    and ($ids | index($flat)) > ($ids | index($alpha))
    and ($ids | index($parent)) == (($ids | length) - 1)
  ' >/dev/null 2>&1 \
    || fail "the task after the fresh-repository move failure did not land in the primary block ahead of its newly created parent: $(printf '%s' "$FRESH_OK_LIST" | jq -c '[.result.workspaces[].label]')"
  pass "real Herdr lab: the next task on that repository creates the parent again, lands ahead of it, attaches, and binds"
  teardown_task fresh-fail "$HOME_DIR" > "$TMP_ROOT/fresh-fail-teardown.out" 2> "$TMP_ROOT/fresh-fail-teardown.err" \
    || fail "fresh-repository move-failure teardown failed: $(cat "$TMP_ROOT/fresh-fail-teardown.err")"
  teardown_task fresh-ok "$HOME_DIR" > "$TMP_ROOT/fresh-ok-teardown.out" 2> "$TMP_ROOT/fresh-ok-teardown.err" \
    || fail "fresh-repository regrouping teardown failed: $(cat "$TMP_ROOT/fresh-ok-teardown.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository teardowns"

  # A refused removal of a fresh parent is recorded per home and retried by
  # the next spawn on that repository. The fixture records the now-childless
  # parent the regrouping spawn created, exactly as a spawn does after a
  # refused removal, and proves the next spawn removes it through its seeded
  # pane, forgets the record, and then groups normally under a new parent.
  RETRY_RECORD="$HOME_DIR/state/.herdr-repo-parent-retry"
  FRESH_PARENT_PANE=$(lab pane list --workspace "$FRESH_PARENT_WSID" | jq -r '[.result.panes[]?] | select(length == 1) | .[0].pane_id // empty')
  [ -n "$FRESH_PARENT_PANE" ] || fail "the fresh-repository fixture parent does not hold exactly one seeded pane"
  record_repo_parent_retry "$FRESH_PARENT_WSID" "$FRESH_REPO_LABEL" "$FRESH_PROJECT_DIR" "$FRESH_PARENT_PANE" \
    || fail "could not record the fresh-repository parent for retry"
  grep -F "$FRESH_PARENT_WSID" "$RETRY_RECORD" >/dev/null 2>&1 \
    || fail "the fresh-repository retry record does not name the parent: $(cat "$RETRY_RECORD" 2>/dev/null)"
  mkdir -p "$HOME_DIR/data/fresh-retry" "$HOME_DIR/data/fresh-stuck"
  write_ship_brief "$HOME_DIR" fresh-retry 'Fresh repository retried parent removal fixture.'
  write_ship_brief "$HOME_DIR" fresh-stuck 'Fresh repository refused retry fixture.'
  FRESH_RETRY_START=$(log_line_count)
  FRESH_RETRY_FOCUS_START=$(focus_audit_line_count)
  spawn_task fresh-retry "$HOME_DIR" "$FRESH_PROJECT_DIR" > "$TMP_ROOT/fresh-retry.out" 2> "$TMP_ROOT/fresh-retry.err" \
    || fail "spawn retrying the fresh-repository parent removal failed: $(cat "$TMP_ROOT/fresh-retry.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository retried removal"
  assert_raw_presentation_mutations_preserved_since "$FRESH_RETRY_FOCUS_START" "fresh-repository retried removal"
  grep -F "removed the repo parent $FRESH_PARENT_WSID an earlier spawn left standing" "$TMP_ROOT/fresh-retry.err" >/dev/null 2>&1 \
    || fail "fresh-repository retried removal did not report removing the recorded parent: $(cat "$TMP_ROOT/fresh-retry.err")"
  if grep -E 'workspace move failed|closed the repo parent|leaving this task.s space flat|stays flat' "$TMP_ROOT/fresh-retry.err" >/dev/null 2>&1; then
    fail "fresh-repository retried removal fell back to the flat row: $(cat "$TMP_ROOT/fresh-retry.err")"
  fi
  [ ! -e "$RETRY_RECORD" ] \
    || fail "fresh-repository retried removal kept the retry record: $(cat "$RETRY_RECORD")"
  FRESH_RETRY_LIST=$(lab workspace list) || fail "could not inspect the layout after the fresh-repository retried removal"
  [ "$(printf '%s' "$FRESH_RETRY_LIST" | jq -r --arg id "$FRESH_PARENT_WSID" '[.result.workspaces[] | select(.workspace_id == $id)] | length')" = 0 ] \
    || fail "fresh-repository retried removal left the recorded parent $FRESH_PARENT_WSID standing"
  FRESH_RETRY_META="$HOME_DIR/state/fresh-retry.meta"
  remember_meta_worktree "$FRESH_RETRY_META" >/dev/null
  FRESH_RETRY_WSID=$(grep '^herdr_workspace_id=' "$FRESH_RETRY_META" | cut -d= -f2-)
  FRESH_PARENT2_WSID=$(repo_parent_id "$FRESH_REPO_LABEL" "fresh-repository retried removal")
  [ "$FRESH_PARENT2_WSID" != "$FRESH_PARENT_WSID" ] \
    || fail "fresh-repository retried removal reused the parent it should have removed"
  assert_linked_child "$FRESH_RETRY_WSID" "$(grep '^worktree=' "$FRESH_RETRY_META" | cut -d= -f2-)" "$FRESH_PROJECT_DIR" "fresh-repository retried removal" "$TMP_ROOT/fresh-retry.err"
  # The recorded parent leaves through the focus-preserving pane-death path
  # only: its lone idle shell is ended so Herdr removes the emptied workspace
  # itself, never through a plain pane close, and the spawn prunes its own
  # task workspace's seeded pane as always. Nothing else may be closed or
  # renamed, and never through a workspace close.
  FRESH_RETRY_CALLS=$(sed -n "$((FRESH_RETRY_START + 1)),\$p" "$HERDR_CALL_LOG")
  FRESH_RETRY_FOREIGN_MUTATIONS=$(printf '%s\n' "$FRESH_RETRY_CALLS" | awk -F '\t' -v own="$FRESH_RETRY_WSID:" -v parent_pane="$FRESH_PARENT_PANE" '
    ($1 == "pane" && $2 == "close" && index($3, own) != 1 && $3 != parent_pane) || ($1 == "tab" && $2 == "close") || ($1 == "workspace" && ($2 == "close" || $2 == "rename")) || ($1 == "session" && ($2 == "stop" || $2 == "delete")) || $1 == "server" { print $1 " " $2 " " $3 }
  ')
  [ -z "$FRESH_RETRY_FOREIGN_MUTATIONS" ] \
    || fail "fresh-repository retried removal closed or renamed something other than the recorded parent's seeded pane: $(printf '%s\n' "$FRESH_RETRY_FOREIGN_MUTATIONS" | tr '\n' ';')"
  if lab pane get "$FRESH_PARENT_PANE" >/dev/null 2>&1; then
    fail "fresh-repository retried removal left the recorded parent's seeded pane $FRESH_PARENT_PANE alive"
  fi
  pass "real Herdr lab: the next spawn on a repository retries a recorded refused parent removal through the pane path, forgets the record, and groups under a new parent"
  teardown_task fresh-retry "$HOME_DIR" > "$TMP_ROOT/fresh-retry-teardown.out" 2> "$TMP_ROOT/fresh-retry-teardown.err" \
    || fail "fresh-repository retried-removal teardown failed: $(cat "$TMP_ROOT/fresh-retry-teardown.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository retried-removal teardown"

  # A recorded parent whose seeded pane the captain has since started using
  # is never closed by the retry: a long-running command in that pane makes
  # the lone-idle-shell proof fail, which is a lasting refusal that forgets
  # the record with one warning and adopts the parent, so the task groups
  # under it and the busy pane keeps running.
  FRESH_BUSY_PANE=$(lab pane list --workspace "$FRESH_PARENT2_WSID" | jq -r '[.result.panes[]?] | select(length == 1) | .[0].pane_id // empty')
  [ -n "$FRESH_BUSY_PANE" ] || fail "the fresh-repository standing parent does not hold exactly one seeded pane"
  lab pane run "$FRESH_BUSY_PANE" 'sleep 600' >/dev/null \
    || fail "could not start a long-running command in the standing parent's seeded pane"
  record_repo_parent_retry "$FRESH_PARENT2_WSID" "$FRESH_REPO_LABEL" "$FRESH_PROJECT_DIR" "$FRESH_BUSY_PANE" \
    || fail "could not record the busy fresh-repository parent for retry"
  mkdir -p "$HOME_DIR/data/fresh-busy"
  write_ship_brief "$HOME_DIR" fresh-busy 'Fresh repository used-parent retry fixture.'
  FRESH_BUSY_START=$(log_line_count)
  FRESH_BUSY_FOCUS_START=$(focus_audit_line_count)
  spawn_task fresh-busy "$HOME_DIR" "$FRESH_PROJECT_DIR" > "$TMP_ROOT/fresh-busy.out" 2> "$TMP_ROOT/fresh-busy.err" \
    || fail "spawn after a retry refused for a used parent should still succeed: $(cat "$TMP_ROOT/fresh-busy.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository used parent"
  assert_raw_presentation_mutations_preserved_since "$FRESH_BUSY_FOCUS_START" "fresh-repository used parent"
  grep -F "the parent $FRESH_PARENT2_WSID an earlier spawn left standing" "$TMP_ROOT/fresh-busy.err" | grep -F "adopting it" >/dev/null 2>&1 \
    || fail "fresh-repository used parent did not warn that the parent is left standing and adopted: $(cat "$TMP_ROOT/fresh-busy.err")"
  [ "$(grep -c 'an earlier spawn left standing' "$TMP_ROOT/fresh-busy.err")" = 1 ] \
    || fail "fresh-repository used parent warned more than once: $(cat "$TMP_ROOT/fresh-busy.err")"
  [ ! -e "$RETRY_RECORD" ] || ! grep -F "$FRESH_PARENT2_WSID" "$RETRY_RECORD" >/dev/null 2>&1 \
    || fail "fresh-repository used parent kept the retry record"
  FRESH_BUSY_META="$HOME_DIR/state/fresh-busy.meta"
  FRESH_BUSY_WT=$(remember_meta_worktree "$FRESH_BUSY_META")
  FRESH_BUSY_WSID=$(grep '^herdr_workspace_id=' "$FRESH_BUSY_META" | cut -d= -f2-)
  assert_linked_child "$FRESH_BUSY_WSID" "$FRESH_BUSY_WT" "$FRESH_PROJECT_DIR" "fresh-repository used parent" "$TMP_ROOT/fresh-busy.err"
  [ "$(lab worktree list --workspace "$FRESH_PARENT2_WSID" | jq -r --arg id "$FRESH_BUSY_WSID" '[.result.worktrees[]? | select(.open_workspace_id == $id)] | length')" = 1 ] \
    || fail "fresh-repository used parent did not group the task under exactly the recorded parent $FRESH_PARENT2_WSID"
  lab pane get "$FRESH_BUSY_PANE" >/dev/null 2>&1 \
    || fail "fresh-repository used parent lost the busy seeded pane $FRESH_BUSY_PANE"
  lab pane process-info --pane "$FRESH_BUSY_PANE" | jq -e '[.result.process_info.foreground_processes[]?.name] | index("sleep") != null' >/dev/null 2>&1 \
    || fail "fresh-repository used parent's command is no longer running in $FRESH_BUSY_PANE"
  FRESH_BUSY_FOREIGN_MUTATIONS=$(sed -n "$((FRESH_BUSY_START + 1)),\$p" "$HERDR_CALL_LOG" | awk -F '\t' -v own="$FRESH_BUSY_WSID:" '
    ($1 == "pane" && $2 == "close" && index($3, own) != 1) || ($1 == "tab" && $2 == "close") || ($1 == "workspace" && ($2 == "close" || $2 == "rename")) || ($1 == "session" && ($2 == "stop" || $2 == "delete")) || $1 == "server" { print $1 " " $2 " " $3 }
  ')
  [ -z "$FRESH_BUSY_FOREIGN_MUTATIONS" ] \
    || fail "fresh-repository used parent closed or renamed something outside its own task workspace: $(printf '%s\n' "$FRESH_BUSY_FOREIGN_MUTATIONS" | tr '\n' ';')"
  pass "real Herdr lab: a retry never closes a standing parent whose seeded pane is busy; it forgets the record with one warning and groups the task under that parent"
  teardown_task fresh-busy "$HOME_DIR" > "$TMP_ROOT/fresh-busy-teardown.out" 2> "$TMP_ROOT/fresh-busy-teardown.err" \
    || fail "fresh-repository used-parent teardown failed: $(cat "$TMP_ROOT/fresh-busy-teardown.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository used-parent teardown"

  # A lasting refusal (an extra tab on the recorded parent makes the
  # childless guard refuse the removal for good) forgets the record with one
  # warning, leaves the parent standing, and the ordinary parent ensure adopts
  # that exact parent so the task groups under it.
  lab tab create --workspace "$FRESH_PARENT2_WSID" --cwd "$FRESH_PROJECT_DIR" --label fm-fresh-extra-tab --no-focus >/dev/null \
    || fail "could not give the fresh-repository parent an extra tab"
  record_repo_parent_retry "$FRESH_PARENT2_WSID" "$FRESH_REPO_LABEL" "$FRESH_PROJECT_DIR" \
    || fail "could not record the fresh-repository parent for a refused retry"
  FRESH_STUCK_START=$(log_line_count)
  FRESH_STUCK_FOCUS_START=$(focus_audit_line_count)
  spawn_task fresh-stuck "$HOME_DIR" "$FRESH_PROJECT_DIR" > "$TMP_ROOT/fresh-stuck.out" 2> "$TMP_ROOT/fresh-stuck.err" \
    || fail "spawn after a refused fresh-repository retry should still succeed: $(cat "$TMP_ROOT/fresh-stuck.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository refused retry"
  assert_raw_presentation_mutations_preserved_since "$FRESH_STUCK_FOCUS_START" "fresh-repository refused retry"
  grep -F "the parent $FRESH_PARENT2_WSID an earlier spawn left standing" "$TMP_ROOT/fresh-stuck.err" | grep -F "adopting it" >/dev/null 2>&1 \
    || fail "fresh-repository lasting refusal did not warn that the parent is left standing and adopted: $(cat "$TMP_ROOT/fresh-stuck.err")"
  [ "$(grep -c 'an earlier spawn left standing' "$TMP_ROOT/fresh-stuck.err")" = 1 ] \
    || fail "fresh-repository lasting refusal warned more than once: $(cat "$TMP_ROOT/fresh-stuck.err")"
  [ ! -e "$RETRY_RECORD" ] || ! grep -F "$FRESH_PARENT2_WSID" "$RETRY_RECORD" >/dev/null 2>&1 \
    || fail "fresh-repository lasting refusal kept the retry record"
  FRESH_STUCK_META="$HOME_DIR/state/fresh-stuck.meta"
  FRESH_STUCK_WT=$(remember_meta_worktree "$FRESH_STUCK_META")
  FRESH_STUCK_WSID=$(grep '^herdr_workspace_id=' "$FRESH_STUCK_META" | cut -d= -f2-)
  assert_linked_child "$FRESH_STUCK_WSID" "$FRESH_STUCK_WT" "$FRESH_PROJECT_DIR" "fresh-repository lasting refusal" "$TMP_ROOT/fresh-stuck.err"
  [ "$(lab worktree list --workspace "$FRESH_PARENT2_WSID" | jq -r --arg id "$FRESH_STUCK_WSID" '[.result.worktrees[]? | select(.open_workspace_id == $id)] | length')" = 1 ] \
    || fail "fresh-repository lasting refusal did not group the task under exactly the recorded parent $FRESH_PARENT2_WSID"
  [ "$(lab workspace list | jq -r --arg id "$FRESH_PARENT2_WSID" '[.result.workspaces[] | select(.workspace_id == $id)] | length')" = 1 ] \
    || fail "fresh-repository lasting refusal removed the parent it should have left standing"
  [ "$(lab tab list --workspace "$FRESH_PARENT2_WSID" | jq -r '[.result.tabs[]?] | length')" = 2 ] \
    || fail "fresh-repository lasting refusal changed the parent's tabs"
  # The spawn still prunes its own task workspace's seeded pane; nothing
  # outside that workspace may be closed or renamed.
  FRESH_STUCK_CALLS=$(sed -n "$((FRESH_STUCK_START + 1)),\$p" "$HERDR_CALL_LOG")
  FRESH_STUCK_FOREIGN_MUTATIONS=$(printf '%s\n' "$FRESH_STUCK_CALLS" | awk -F '\t' -v own="$FRESH_STUCK_WSID:" '
    ($1 == "pane" && $2 == "close" && index($3, own) != 1) || ($1 == "tab" && $2 == "close") || ($1 == "workspace" && ($2 == "close" || $2 == "rename")) || ($1 == "session" && ($2 == "stop" || $2 == "delete")) || $1 == "server" { print $1 " " $2 " " $3 }
  ')
  [ -z "$FRESH_STUCK_FOREIGN_MUTATIONS" ] \
    || fail "fresh-repository lasting refusal closed or renamed something outside its own task workspace: $(printf '%s\n' "$FRESH_STUCK_FOREIGN_MUTATIONS" | tr '\n' ';')"
  pass "real Herdr lab: a retry refused for a lasting reason forgets the record with one warning, leaves the parent standing, and groups the task under it"
  teardown_task fresh-stuck "$HOME_DIR" > "$TMP_ROOT/fresh-stuck-teardown.out" 2> "$TMP_ROOT/fresh-stuck-teardown.err" \
    || fail "fresh-repository refused-retry teardown failed: $(cat "$TMP_ROOT/fresh-stuck-teardown.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository refused-retry teardown"
  # Parents persist by design; this fixture removes its own now-childless one
  # and the retry record it seeded through the lab so the cases below see the
  # layout they already expect.
  lab workspace close "$FRESH_PARENT2_WSID" >/dev/null \
    || fail "could not remove the fresh-repository fixture's childless parent"
  rm -f "$RETRY_RECORD"
  assert_focus_is "$CAPTAIN_FOCUS" "fresh-repository fixture parent removal"
fi

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
# poll screens out on every read rather than adopting, so the armed failure
# arrives as the poll's own deadline refusal naming that path - after the
# spawn has already leased its slot, which the abort must give back.
grep -F "did not enter an isolated worktree" "$TMP_ROOT/abort-a.err" >/dev/null 2>&1 \
  || fail "post-create abort fixture A did not reach the armed validation failure"
grep -F "did not enter an isolated worktree" "$TMP_ROOT/abort-b.err" >/dev/null 2>&1 \
  || fail "post-create abort fixture B did not reach the armed validation failure"
for ABORT_TASK in abort-a abort-b; do
  grep -Fx "get	--lease	--lease-holder	fm-$ABORT_TASK" "$TREEHOUSE_CALL_LOG" >/dev/null 2>&1 \
    || fail "post-create abort fixture $ABORT_TASK did not lease its slot before the armed failure: $(cat "$TREEHOUSE_CALL_LOG")"
done
if (cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>/dev/null) | grep -E 'held by fm-abort-(a|b)' >/dev/null 2>&1; then
  fail "post-create abort left a Treehouse slot leased to a task no record describes: $(cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>&1)"
fi
if grep -F 'leaving task abort-' "$TMP_ROOT/abort-a.err" "$TMP_ROOT/abort-b.err" >/dev/null 2>&1; then
  fail "post-create abort could not return a leased slot: $(cat "$TMP_ROOT/abort-a.err" "$TMP_ROOT/abort-b.err")"
fi
ABORT_A_PANE=$(cat "$POST_CREATE_ABORT_CONTROL/abort-a/task-pane")
ABORT_B_PANE=$(cat "$POST_CREATE_ABORT_CONTROL/abort-b/task-pane")
# Each abort pane holds a lone idle root shell sitting in its leased worktree,
# so cleanup normally removes it through the pane-death path (the fake herdr's
# pane-death row) and falls back to an explicit pane close only when that
# proof fails; either row is the close evidence whose order matters here.
ABORT_SEQUENCE=$(sed -n "$((ABORT_FOCUS_START + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v a="$ABORT_A_PANE" -v b="$ABORT_B_PANE" '
  $1 == "workspace-create" && $4 ~ /^└ abort-a · p:/ { print "create-a" }
  $1 == "workspace-create" && $4 ~ /^└ abort-b · p:/ { print "create-b" }
  ($1 == "pane-close" || $1 == "pane-death") && $4 == a { print "close-a" }
  ($1 == "pane-close" || $1 == "pane-death") && $4 == b { print "close-b" }
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
if (cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>/dev/null) | grep -F 'held by fm-shape' >/dev/null 2>&1; then
  fail "projected teardown left the task's Treehouse lease held: $(cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>&1)"
fi
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
  if [ "$GROUPING_CAPABLE" = 1 ]; then
    WAVE_REMAINING_EXPECTED=$(printf 'firstmate\n%s\n2ndmate-alpha\n2ndmate-bravo' "$PROJECT_REPO_LABEL")
  else
    WAVE_REMAINING_EXPECTED=$'firstmate\n2ndmate-alpha\n2ndmate-bravo'
  fi
  [ "$WAVE_REMAINING" = "$WAVE_REMAINING_EXPECTED" ] \
    || fail "focus wave $ROUND cleanup left a projected workspace behind: $WAVE_REMAINING"
done
pass "real Herdr lab: three repeated concurrent create/order/cleanup waves have zero active workspace or tab drift"

# A foreign workspace whose root shell sits in the task worktree is the one
# Herdr would nest under the repo parent, so the attach must skip with one
# warning, run no worktree open at all, and leave both workspaces exactly as
# they were. Treehouse never hands out a slot another process occupies (an
# available slot holding a foreign shell reads in-use and the next slot is
# leased instead), so that occupant can only arrive between the lease and the
# attach; the fake herdr stands in for it there by reporting the seeded
# foreign workspace as the one open in the task worktree, while the real
# answer after the spawn names the task's own workspace.
if [ "$GROUPING_CAPABLE" = 1 ]; then
  FOREIGN_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label foreign-human --no-focus) \
    || fail "could not seed a foreign workspace"
  FOREIGN_WSID=$(printf '%s' "$FOREIGN_OUT" | jq -r '.result.workspace.workspace_id // empty')
  [ -n "$FOREIGN_WSID" ] || fail "foreign workspace seed returned no id"
  mkdir -p "$FOREIGN_ATTACH_CONTROL" "$HOME_DIR/data/foreign-skip"
  printf '%s\n' "$FOREIGN_WSID" > "$FOREIGN_ATTACH_CONTROL/workspace"
  realpath_of "$PROJECT_DIR" > "$FOREIGN_ATTACH_CONTROL/clone"
  write_ship_brief "$HOME_DIR" foreign-skip 'Foreign workspace attach-skip fixture.'
  FOREIGN_LOG_START=$(log_line_count)
  FOREIGN_FOCUS_START=$(focus_audit_line_count)
  spawn_task foreign-skip "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/foreign-skip.out" 2> "$TMP_ROOT/foreign-skip.err" \
    || fail "foreign-workspace spawn failed: $(cat "$TMP_ROOT/foreign-skip.err")"
  [ -s "$FOREIGN_ATTACH_CONTROL/hits" ] \
    || fail "the foreign-workspace fixture never answered a worktree list read, so the case is inconclusive"
  rm -rf "$FOREIGN_ATTACH_CONTROL"
  FOREIGN_META="$HOME_DIR/state/foreign-skip.meta"
  FOREIGN_WT=$(remember_meta_worktree "$FOREIGN_META")
  FOREIGN_TASK_WSID=$(grep '^herdr_workspace_id=' "$FOREIGN_META" | cut -d= -f2-)
  grep -F "open in $FOREIGN_WSID rather than this task's space $FOREIGN_TASK_WSID; leaving this task's space flat" "$TMP_ROOT/foreign-skip.err" >/dev/null 2>&1 \
    || fail "a foreign workspace in the task worktree did not warn once and leave the task flat: $(cat "$TMP_ROOT/foreign-skip.err")"
  [ "$(grep -cE 'herdr repo grouping|herdr reports worktree' "$TMP_ROOT/foreign-skip.err")" = 1 ] \
    || fail "the foreign-workspace skip warned more than once: $(cat "$TMP_ROOT/foreign-skip.err")"
  assert_no_attach_calls_since "$FOREIGN_LOG_START" "foreign-workspace skip"
  assert_flat_row "$FOREIGN_TASK_WSID" "foreign-workspace skip"
  assert_flat_row "$FOREIGN_WSID" "foreign-workspace skip"
  [ "$(lab workspace get "$FOREIGN_WSID" | jq -r '.result.workspace.label')" = foreign-human ] \
    || fail "the foreign workspace was renamed or replaced"
  [ "$(lab worktree list --cwd "$FOREIGN_WT" | jq -r --arg real "$(realpath_of "$FOREIGN_WT")" '[.result.worktrees[] | select(.path == $real)] | .[0].open_workspace_id // empty')" = "$FOREIGN_TASK_WSID" ] \
    || fail "Herdr does not report the task's own workspace as the one open in its leased worktree"
  assert_focus_is "$CAPTAIN_FOCUS" "foreign-workspace skip"
  assert_raw_presentation_mutations_preserved_since "$FOREIGN_FOCUS_START" "foreign-workspace skip"
  lab workspace close "$FOREIGN_WSID" >/dev/null \
    || fail "could not remove the seeded foreign workspace"
  teardown_task foreign-skip "$HOME_DIR" > "$TMP_ROOT/foreign-skip-teardown.out" 2> "$TMP_ROOT/foreign-skip-teardown.err" \
    || fail "foreign-workspace fixture teardown failed: $(cat "$TMP_ROOT/foreign-skip-teardown.err")"
  assert_focus_is "$CAPTAIN_FOCUS" "foreign-workspace fixture cleanup"
  pass "real Herdr lab: a foreign workspace reported open in the task worktree makes the attach skip with one warning and zero worktree open calls"
fi

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
if [ "$GROUPING_CAPABLE" = 1 ]; then
  ALPHA_REPO_PARENT_WSID=$(repo_parent_id "2ndmate-alpha · $PROJECT_REPO_LABEL" "secondmate repo parents")
  BRAVO_REPO_PARENT_WSID=$(repo_parent_id "2ndmate-bravo · $PROJECT_REPO_LABEL" "secondmate repo parents")
  [ "$(repo_parent_id "$PROJECT_REPO_LABEL" "secondmate repo parents")" = "$REPO_PARENT_WSID" ] \
    || fail "secondmate spawns disturbed the primary's repo parent"
  [ "$ALPHA_REPO_PARENT_WSID" != "$BRAVO_REPO_PARENT_WSID" ] && [ "$ALPHA_REPO_PARENT_WSID" != "$REPO_PARENT_WSID" ] \
    || fail "secondmate homes did not get their own distinct repo parents"
  for META_X in p1 p2 a1 a2 b1 b2; do
    case "$META_X" in
      p*) META_PATH="$HOME_DIR/state/$META_X.meta" ;;
      a*) META_PATH="$SECOND_HOME_A/state/$META_X.meta" ;;
      b*) META_PATH="$SECOND_HOME_B/state/$META_X.meta" ;;
    esac
    assert_linked_child "$(grep '^herdr_workspace_id=' "$META_PATH" | cut -d= -f2-)" "$(grep '^worktree=' "$META_PATH" | cut -d= -f2-)" "$PROJECT_DIR" "multi-home grouped children ($META_X)" "$TMP_ROOT/$META_X.err"
  done
  pass "real Herdr lab: each secondmate home groups its tasks under its own home-qualified repo parent while the primary keeps its own"
fi

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
# original projected workspace. These full-session restarts also stop the
# earlier multi-home workers whose restored panes are retained for the final
# exact-pane cleanup assertions. Keep the recovery fixtures in their own
# Treehouse pool so those intentionally retained records cannot claim a slot
# that a recovery fixture legitimately acquires after their processes stop.
# Exercise both the leading fm- identity style seen in Hi Bit work and the
# project-name identity style used by Wheelhouse work.
for RESTART_ID in fm-hibit-resume-r1 wheelhouse-healing-r1; do
  spawn_task "$RESTART_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/$RESTART_ID-first.out" 2> "$TMP_ROOT/$RESTART_ID-first.err" \
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
  restart_lab_session "$RESTART_ID validation"
  # Stopping the whole Herdr session also ends the anchor's agent. Its restored
  # shell remains useful as the durable layout anchor, but its task record no
  # longer represents a live slot owner and must not poison later slot reuse.
  rm -f "$ANCHOR_META"
  lab pane get "$OLD_RESTART_PANE" >/dev/null 2>&1 \
    || fail "$RESTART_ID restart did not preserve the projected pane structurally"
  if lab agent get "$OLD_RESTART_PANE" >/dev/null 2>&1; then
    fail "$RESTART_ID restart fixture unexpectedly retained a registered agent"
  fi
  if [ "$GROUPING_CAPABLE" = 1 ]; then
    RECOVERY_REPO_PARENT_WSID=$(repo_parent_id "$RECOVERY_REPO_LABEL" "$RESTART_ID restart provenance")
    assert_linked_child "$OLD_RESTART_WSID" "$OLD_RESTART_WT" "$RECOVERY_PROJECT_DIR" "$RESTART_ID restart provenance" "$TMP_ROOT/$RESTART_ID-first.err"
    lab workspace get "$RECOVERY_REPO_PARENT_WSID" | jq -e '.result.workspace.worktree.is_linked_worktree == false' >/dev/null 2>&1 \
      || fail "$RESTART_ID restart lost the repo parent's root provenance"
  fi
  RECLAIM_FOCUS=$(focus_snapshot)
  spawn_task "$RESTART_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/$RESTART_ID-reclaim.out" 2> "$TMP_ROOT/$RESTART_ID-reclaim.err" \
    || fail "$RESTART_ID same-identity reclaim failed: $(cat "$TMP_ROOT/$RESTART_ID-reclaim.err")"
  NEW_RESTART_WT=$(remember_meta_worktree "$RESTART_META")
  # The reclaim re-enters the copy its surviving record names rather than
  # leasing a second one. A fresh lease here would strand the recorded copy,
  # which still holds the previous incarnation's work and which teardown is
  # the only thing that ever releases.
  [ "$NEW_RESTART_WT" = "$OLD_RESTART_WT" ] \
    || fail "$RESTART_ID same-identity reclaim moved to a different copy instead of re-entering its recorded one ($OLD_RESTART_WT -> $NEW_RESTART_WT)"
  RESTART_LEASES=$(grep -Fxc $'get\t--lease\t--lease-holder\tfm-'"$RESTART_ID" "$TREEHOUSE_CALL_LOG" || true)
  [ "$RESTART_LEASES" = 1 ] \
    || fail "$RESTART_ID holds $RESTART_LEASES Treehouse leases across its restart; only the first spawn's lease is expected"
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
  if [ "$GROUPING_CAPABLE" = 1 ]; then
    lab workspace get "$NEW_RESTART_WSID" | jq -e '.result.workspace.worktree.is_linked_worktree == true' >/dev/null 2>&1 \
      || fail "$RESTART_ID reclaim detached the reclaimed workspace from its repo parent"
    [ "$(repo_parent_id "$RECOVERY_REPO_LABEL" "$RESTART_ID reclaim")" = "$RECOVERY_REPO_PARENT_WSID" ] \
      || fail "$RESTART_ID reclaim created or replaced the repo parent"
    RESTART_PROVENANCE_CHECKED=1
  fi

  if [ "$RESTART_ID" = fm-hibit-resume-r1 ]; then
    restart_lab_session "idempotent reclaim"
    PRIOR_RESTART_WT=$NEW_RESTART_WT
    PRIOR_RESTART_PANE=$NEW_RESTART_PANE
    spawn_task "$RESTART_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/$RESTART_ID-idempotent.out" 2> "$TMP_ROOT/$RESTART_ID-idempotent.err" \
      || fail "$RESTART_ID repeated reclaim failed: $(cat "$TMP_ROOT/$RESTART_ID-idempotent.err")"
    NEW_RESTART_WT=$(remember_meta_worktree "$RESTART_META")
    NEW_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
    NEW_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
    [ "$NEW_RESTART_WSID" = "$OLD_RESTART_WSID" ] \
      || fail "$RESTART_ID repeated reclaim changed workspace identity"
    [ "$NEW_RESTART_PANE" != "$PRIOR_RESTART_PANE" ] \
      || fail "$RESTART_ID repeated reclaim reused the prior husk pane"
    [ "$NEW_RESTART_WT" = "$PRIOR_RESTART_WT" ] \
      || fail "$RESTART_ID repeated reclaim moved to a different copy instead of re-entering its recorded one"
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
if [ "${RESTART_PROVENANCE_CHECKED:-0}" = 1 ]; then
  pass "real Herdr lab: linked-worktree children and their repo parent keep their provenance across stop and provision, and reclaim leaves both untouched"
fi

# A secondmate child binds and reclaims only inside its own home and parent.
CROSS_RESTART_ID=wheel-child-resume
mkdir -p "$SECOND_HOME_A/data/$CROSS_RESTART_ID"
write_ship_brief "$SECOND_HOME_A" "$CROSS_RESTART_ID" 'Cross-home restart fixture.'
spawn_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/cross-restart-first.out" 2> "$TMP_ROOT/cross-restart-first.err" \
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
restart_lab_session "cross-home restart"
spawn_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/cross-restart-resume.out" 2> "$TMP_ROOT/cross-restart-resume.err" \
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

# A same-identity respawn whose recorded copy is gone cannot re-enter it, so it
# leases a fresh slot - and an abort after that lease must give exactly that
# slot back. The surviving record names the vanished copy, so nothing else
# would ever release the new one.
RESPAWN_ABORT_ID=abort-resume
spawn_task "$RESPAWN_ABORT_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/abort-resume-first.out" 2> "$TMP_ROOT/abort-resume-first.err" \
  || fail "respawn-abort fixture's first projected spawn failed: $(cat "$TMP_ROOT/abort-resume-first.err")"
RESPAWN_ABORT_META="$HOME_DIR/state/$RESPAWN_ABORT_ID.meta"
RESPAWN_ABORT_FIRST_WT=$(remember_meta_worktree "$RESPAWN_ABORT_META")
restart_lab_session "the respawn-abort fixture"
# Stand in for a recorded copy that is gone: give the real slot back and point
# the surviving record at a path that no longer exists.
"$REAL_TREEHOUSE" return --force "$RESPAWN_ABORT_FIRST_WT" >/dev/null 2>&1 || true
sed -i.bak "s|^worktree=.*|worktree=$TMP_ROOT/abort-resume-removed-copy|" "$RESPAWN_ABORT_META"
rm -f "$RESPAWN_ABORT_META.bak"
mkdir -p "$POST_CREATE_ABORT_CONTROL"
if spawn_task "$RESPAWN_ABORT_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/abort-resume-retry.out" 2> "$TMP_ROOT/abort-resume-retry.err"; then
  fail "respawn-abort fixture unexpectedly succeeded: $(cat "$TMP_ROOT/abort-resume-retry.out")"
fi
grep -F "did not enter an isolated worktree" "$TMP_ROOT/abort-resume-retry.err" >/dev/null 2>&1 \
  || fail "respawn-abort fixture did not reach the armed validation failure: $(cat "$TMP_ROOT/abort-resume-retry.err")"
RESPAWN_ABORT_LEASES=$(grep -Fxc $'get\t--lease\t--lease-holder\tfm-'"$RESPAWN_ABORT_ID" "$TREEHOUSE_CALL_LOG" || true)
[ "$RESPAWN_ABORT_LEASES" = 2 ] \
  || fail "respawn-abort fixture took $RESPAWN_ABORT_LEASES leases; the vanished recorded copy should have forced exactly one fresh lease after the first spawn's"
if (cd "$RECOVERY_PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>/dev/null) | grep -F "held by fm-$RESPAWN_ABORT_ID" >/dev/null 2>&1; then
  fail "the aborted respawn kept the slot it leased while the surviving record named a different copy: $(cd "$RECOVERY_PROJECT_DIR" && "$REAL_TREEHOUSE" status 2>&1)"
fi
if grep -F "leaving task $RESPAWN_ABORT_ID's leased worktree" "$TMP_ROOT/abort-resume-retry.err" >/dev/null 2>&1; then
  fail "the aborted respawn could not return the slot it leased: $(cat "$TMP_ROOT/abort-resume-retry.err")"
fi
[ -e "$RESPAWN_ABORT_META" ] \
  || fail "the aborted respawn erased the surviving task record"
rm -rf "$POST_CREATE_ABORT_CONTROL"
rm -f "$RESPAWN_ABORT_META" "$HOME_DIR/state/$RESPAWN_ABORT_ID.herdr-presentation"
pass "real Herdr lab: an aborted respawn returns the slot it leased even though an older record survives"

# Two homes recovering concurrently serialize on the named session lock and
# each replace only their own exact husk.
PRIMARY_WAVE_ID=resume-wave-primary
BRAVO_WAVE_ID=resume-wave-bravo
mkdir -p "$HOME_DIR/data/$PRIMARY_WAVE_ID" "$SECOND_HOME_B/data/$BRAVO_WAVE_ID"
write_ship_brief "$HOME_DIR" "$PRIMARY_WAVE_ID" 'Concurrent primary recovery fixture.'
write_ship_brief "$SECOND_HOME_B" "$BRAVO_WAVE_ID" 'Concurrent secondmate recovery fixture.'
spawn_task "$PRIMARY_WAVE_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/primary-wave-first.out" 2> "$TMP_ROOT/primary-wave-first.err" \
  || fail "primary recovery-wave fixture failed: $(cat "$TMP_ROOT/primary-wave-first.err")"
spawn_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/bravo-wave-first.out" 2> "$TMP_ROOT/bravo-wave-first.err" \
  || fail "secondmate recovery-wave fixture failed: $(cat "$TMP_ROOT/bravo-wave-first.err")"
PRIMARY_WAVE_META="$HOME_DIR/state/$PRIMARY_WAVE_ID.meta"
BRAVO_WAVE_META="$SECOND_HOME_B/state/$BRAVO_WAVE_ID.meta"
PRIMARY_WAVE_OLD_WT=$(remember_meta_worktree "$PRIMARY_WAVE_META")
BRAVO_WAVE_OLD_WT=$(remember_meta_worktree "$BRAVO_WAVE_META")
PRIMARY_WAVE_WSID=$(grep '^herdr_workspace_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_WSID=$(grep '^herdr_workspace_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
PRIMARY_WAVE_OLD_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_OLD_PANE=$(grep '^herdr_pane_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
restart_lab_session "concurrent recovery"
CONCURRENT_RECOVERY_FOCUS=$(focus_snapshot)
spawn_task "$PRIMARY_WAVE_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/primary-wave-resume.out" 2> "$TMP_ROOT/primary-wave-resume.err" &
PRIMARY_WAVE_PID=$!
spawn_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/bravo-wave-resume.out" 2> "$TMP_ROOT/bravo-wave-resume.err" &
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

# Exact-resume presentation-lock contention refuses by default. Hold the
# shared session lock from an unrelated process past the bounded-retry window
# and assert the default resume hard-refuses without the opt-in flag.
LOCK_REFUSE_ID=lock-refuse-resume-r1
mkdir -p "$HOME_DIR/data/$LOCK_REFUSE_ID"
write_ship_brief "$HOME_DIR" "$LOCK_REFUSE_ID" 'Resume lock-refuse fixture.'
spawn_task "$LOCK_REFUSE_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/lock-refuse-first.out" 2> "$TMP_ROOT/lock-refuse-first.err" \
  || fail "lock-refuse recovery fixture failed: $(cat "$TMP_ROOT/lock-refuse-first.err")"
LOCK_REFUSE_META="$HOME_DIR/state/$LOCK_REFUSE_ID.meta"
LOCK_REFUSE_OLD_WT=$(remember_meta_worktree "$LOCK_REFUSE_META")
LOCK_REFUSE_OLD_PANE=$(grep '^herdr_pane_id=' "$LOCK_REFUSE_META" | cut -d= -f2-)
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for resume lock-refuse"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session for resume lock-refuse"

LOCK_REFUSE_READY="$TMP_ROOT/lock-refuse-ready"
LOCK_REFUSE_HOLD_SECONDS=15
LOCK_REFUSE_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve session lock for resume lock-refuse"
ROOT="$ROOT" READY="$LOCK_REFUSE_READY" HOLD="$LOCK_REFUSE_HOLD_SECONDS" LOCK="$LOCK_REFUSE_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  sleep "$HOLD"
  fm_lock_release "$LOCK"
' &
LOCK_REFUSE_HOLDER_PID=$!
while [ ! -e "$LOCK_REFUSE_READY" ] && kill -0 "$LOCK_REFUSE_HOLDER_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$LOCK_REFUSE_READY" ] || fail "could not hold the session presentation lock for resume lock-refuse"

LOCK_REFUSE_FOCUS=$(focus_snapshot)
if spawn_task "$LOCK_REFUSE_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" \
    > "$TMP_ROOT/lock-refuse-resume.out" 2> "$TMP_ROOT/lock-refuse-resume.err"; then
  LOCK_REFUSE_STATUS=0
else
  LOCK_REFUSE_STATUS=$?
fi
if [ "$LOCK_REFUSE_STATUS" -eq 0 ]; then
  kill "$LOCK_REFUSE_HOLDER_PID" 2>/dev/null || true
  wait "$LOCK_REFUSE_HOLDER_PID" 2>/dev/null || true
  fail "default resumed identity succeeded under session lock contention instead of refusing: $(cat "$TMP_ROOT/lock-refuse-resume.out")"
fi
wait "$LOCK_REFUSE_HOLDER_PID" || fail "resume lock-refuse lock holder failed"
LOCK_REFUSE_HOLDER_PID=
[ "$LOCK_REFUSE_STATUS" -ne 0 ] \
  || fail "default resumed identity returned success under contention"
grep -F "refusing a concurrent resume" "$TMP_ROOT/lock-refuse-resume.err" >/dev/null 2>&1 \
  || fail "default resume under contention did not refuse with the concurrent-resume message: $(cat "$TMP_ROOT/lock-refuse-resume.err")"
# Fixture metadata and husk must be unchanged after the refused resume.
[ "$(grep '^herdr_pane_id=' "$LOCK_REFUSE_META" | cut -d= -f2-)" = "$LOCK_REFUSE_OLD_PANE" ] \
  || fail "refused resume mutated the recorded pane id"
assert_focus_is "$LOCK_REFUSE_FOCUS" "resume lock-refuse"
# Leave the journal/meta in place so the opt-in wait path below can resume the
# same identity after another stop/reprovision cycle.
pass "real Herdr lab: default resumed identity refuses session lock contention"

# With --herdr-resume-lock-wait, the same exact resume WAITS for session lock
# contention rather than treating a short bounded window as fatal. Hold the
# shared session lock from an unrelated process for a duration well past any
# plausible bounded-retry window so the assertion below is deterministic
# rather than a race that could pass by luck on a fast machine.
LOCK_WAIT_ID=$LOCK_REFUSE_ID
LOCK_WAIT_META=$LOCK_REFUSE_META
LOCK_WAIT_OLD_WT=$LOCK_REFUSE_OLD_WT
LOCK_WAIT_WSID=$(grep '^herdr_workspace_id=' "$LOCK_WAIT_META" | cut -d= -f2-)
LOCK_WAIT_OLD_PANE=$LOCK_REFUSE_OLD_PANE
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for resume lock-wait"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session for resume lock-wait"

LOCK_WAIT_READY="$TMP_ROOT/lock-wait-ready"
LOCK_WAIT_HOLD_SECONDS=30
LOCK_WAIT_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve session lock for resume lock-wait"
ROOT="$ROOT" READY="$LOCK_WAIT_READY" HOLD="$LOCK_WAIT_HOLD_SECONDS" LOCK="$LOCK_WAIT_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  sleep "$HOLD"
  fm_lock_release "$LOCK"
' &
LOCK_WAIT_HOLDER_PID=$!
while [ ! -e "$LOCK_WAIT_READY" ] && kill -0 "$LOCK_WAIT_HOLDER_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$LOCK_WAIT_READY" ] || fail "could not hold the session presentation lock for resume lock-wait"

LOCK_WAIT_DEADLINE_SECONDS=$((LOCK_WAIT_HOLD_SECONDS + 60))
LOCK_WAIT_FOCUS=$(focus_snapshot)
LOCK_WAIT_START=$(date +%s)
if SPAWN_DEADLINE_SECONDS=$LOCK_WAIT_DEADLINE_SECONDS \
    spawn_task "$LOCK_WAIT_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" --herdr-resume-lock-wait \
    > "$TMP_ROOT/lock-wait-resume.out" 2> "$TMP_ROOT/lock-wait-resume.err"; then
  LOCK_WAIT_STATUS=0
else
  LOCK_WAIT_STATUS=$?
fi
LOCK_WAIT_ELAPSED=$(( $(date +%s) - LOCK_WAIT_START ))
wait "$LOCK_WAIT_HOLDER_PID" || fail "resume lock-wait lock holder failed"
LOCK_WAIT_HOLDER_PID=
if [ "$LOCK_WAIT_STATUS" -eq 124 ]; then
  fail "opt-in resumed recovery hung for over ${LOCK_WAIT_DEADLINE_SECONDS}s instead of waiting out a ${LOCK_WAIT_HOLD_SECONDS}s session lock hold"
fi
[ "$LOCK_WAIT_STATUS" -eq 0 ] \
  || fail "opt-in resumed identity refused instead of waiting out session lock contention: $(cat "$TMP_ROOT/lock-wait-resume.err")"
[ "$LOCK_WAIT_ELAPSED" -ge $((LOCK_WAIT_HOLD_SECONDS - 5)) ] \
  || fail "opt-in resumed recovery returned after ${LOCK_WAIT_ELAPSED}s, too soon to have genuinely waited out a ${LOCK_WAIT_HOLD_SECONDS}s hold"
LOCK_WAIT_NEW_WT=$(remember_meta_worktree "$LOCK_WAIT_META")
[ "$(grep '^herdr_workspace_id=' "$LOCK_WAIT_META" | cut -d= -f2-)" = "$LOCK_WAIT_WSID" ] \
  || fail "opt-in resume lock-wait flattened the task into a different workspace"
LOCK_WAIT_NEW_PANE=$(grep '^herdr_pane_id=' "$LOCK_WAIT_META" | cut -d= -f2-)
[ "$LOCK_WAIT_NEW_PANE" != "$LOCK_WAIT_OLD_PANE" ] \
  || fail "opt-in resume lock-wait reused the old husk pane"
if lab pane get "$LOCK_WAIT_OLD_PANE" >/dev/null 2>&1; then
  fail "opt-in resume lock-wait left the old husk pane behind"
fi
assert_focus_is "$LOCK_WAIT_FOCUS" "resume lock-wait"
teardown_task "$LOCK_WAIT_ID" "$HOME_DIR" > "$TMP_ROOT/lock-wait-teardown.out" 2> "$TMP_ROOT/lock-wait-teardown.err" \
  || fail "resume lock-wait fixture teardown failed: $(cat "$TMP_ROOT/lock-wait-teardown.err")"
"$REAL_TREEHOUSE" return --force "$LOCK_WAIT_OLD_WT" >/dev/null 2>&1 || true
"$REAL_TREEHOUSE" return --force "$LOCK_WAIT_NEW_WT" >/dev/null 2>&1 || true
pass "real Herdr lab: --herdr-resume-lock-wait waits out session lock contention instead of refusing"

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
