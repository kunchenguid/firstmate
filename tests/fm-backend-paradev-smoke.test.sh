#!/usr/bin/env bash
# tests/fm-backend-paradev-smoke.test.sh - real Paradev smoke test for the
# paradev session-provider adapter (bin/backends/paradev.sh). Every other
# Paradev suite fakes the `superset` CLI; this one drives the REAL Paradev host
# service through the dispatcher (bin/fm-backend.sh) and the adapter's spawn
# primitives, the same calls bin/fm-spawn.sh and bin/fm-teardown.sh make:
#
#   spawn two crewmates   -> two workspaces (own branch + worktree) + one shell
#                            terminal each, created exactly as bin/fm-spawn.sh does
#   peek                  -> fm_backend_capture on each terminal
#   send                  -> text line, literal + Enter, keys, verified submit
#   teardown              -> fm_backend_kill (proved by inventory re-read), the
#                            recorded id/path gate, then fm_backend_remove_worktree
#
# Paradev has no throwaway instance: its workspaces live in the captain's real
# app and its branches in a real project clone. So the test is opt-in and keeps
# to a fenced corner of that app:
#   - it runs only when FM_PARADEV_SMOKE_PROJECT names a Paradev project id on
#     this host (the project whose clone gets the throwaway branches);
#   - every workspace it creates is tagged `fm-spike` (FM_PARADEV_TAG), named
#     `fm-spike-smoke-<run>-<a|b>`, on branch `spike/fm-smoke-<run>-<a|b>`;
#   - it archives and deletes ONLY ids and branches this run created (the
#     cleanup re-reads each workspace and refuses one whose name or branch is
#     not this run's), never enumerates-and-archives, and never touches a
#     workspace it did not create, tagged or not;
#   - an EXIT/INT/TERM trap runs that cleanup, so a failed or interrupted run
#     still leaves nothing behind.
#
# It never starts an agent: the crew terminals are plain shells, so nothing is
# ever sent to an agent, let alone one still in `starting`.
#
# Skips cleanly (exit 0, "skip: ...") unless EVERYTHING it needs is present:
# FM_PARADEV_SMOKE_PROJECT, superset, jq, git, a Paradev host that answers a
# real `projects list` (never `superset status`, which can report a stale
# daemon while every call works), and that project id on this host.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TAG=fm-spike
RUN="$$-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6)"
NAME_PREFIX="fm-spike-smoke-$RUN"
BRANCH_PREFIX="spike/fm-smoke-$RUN"

# Created ids, appended the moment Paradev returns them, so cleanup_all can
# reach every workspace even when a later assertion fails mid-step.
CREATED_WS=""
CLEANED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ -n "${FM_PARADEV_SMOKE_PROJECT:-}" ] || {
  echo "skip: FM_PARADEV_SMOKE_PROJECT is not set (opt-in: a Paradev project id whose clone may receive throwaway spike/ branches)"
  exit 0
}
command -v superset >/dev/null 2>&1 || { echo "skip: superset not found (ships with the Paradev desktop app)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the paradev adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

# Every superset call this run makes - its own and the adapter's create, get,
# terminals create/send/read/close, archive, and the cleanup trap's - goes
# through this bound, so a host that stops answering fails that one step (and
# still reaches cleanup) instead of hanging the run.
SUPERSET_BIN=$(type -P superset) || { echo "skip: superset is not an executable on PATH"; exit 0; }
superset() { fm_run_timed 30 "$SUPERSET_BIN" "$@"; }

# Bounded probe: a wedged host service must skip, not hang the lane.
PROJECTS=$(superset projects list --local --json 2>/dev/null) \
  || { echo "skip: no reachable Paradev host (superset projects list --local --json failed)"; exit 0; }
PROJECT_ID=$FM_PARADEV_SMOKE_PROJECT
PROJECT_PATH=$(printf '%s' "$PROJECTS" | jq -r --arg id "$PROJECT_ID" '.[]? | select(.id == $id) | .path | strings' 2>/dev/null)
[ -n "$PROJECT_PATH" ] || { echo "skip: Paradev project $PROJECT_ID is not on this host"; exit 0; }
[ -d "$PROJECT_PATH" ] || { echo "skip: Paradev project $PROJECT_ID points at a missing clone $PROJECT_PATH"; exit 0; }
git -C "$PROJECT_PATH" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "skip: Paradev project path $PROJECT_PATH is not a git repository"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source paradev || { echo "skip: could not source the paradev adapter"; exit 0; }
export FM_PARADEV_TAG="$TAG"

# --- guarded cleanup -----------------------------------------------------------

# paradev_smoke_owned <workspace-id>: 0 only when Paradev still lists the
# workspace AND its name and branch are this run's. 1 when it is already gone.
# 2 (refuse) when it is listed under any other name or branch, or the read is
# ambiguous: a false refusal leaks one spike workspace, a false accept could
# archive someone's real worktree.
paradev_smoke_owned() {  # <workspace-id>
  local ws=$1 out err name branch
  case "$ws" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  err=$(mktemp "${TMPDIR:-/tmp}/fm-paradev-smoke.XXXXXX") || return 2
  if ! out=$(superset workspaces get "$ws" --local --json 2>"$err"); then
    case "$(cat "$err")" in
      *"not found"*|*"Not found"*|*"is not on this host"*) rm -f "$err"; return 1 ;;
    esac
    rm -f "$err"
    return 2
  fi
  rm -f "$err"
  name=$(printf '%s' "$out" | jq -r --arg w "$ws" 'select(.id == $w and .archivedAt == null) | .name | strings' 2>/dev/null)
  branch=$(printf '%s' "$out" | jq -r --arg w "$ws" 'select(.id == $w and .archivedAt == null) | .branch | strings' 2>/dev/null)
  [ -n "$name$branch" ] || return 1
  case "$name" in "$NAME_PREFIX"-?) : ;; *) return 2 ;; esac
  case "$branch" in "$BRANCH_PREFIX"-?) : ;; *) return 2 ;; esac
  return 0
}

# cleanup_all: the ONLY teardown. Archives each workspace this run recorded
# (after proving it is still ours), then any workspace in the fm-spike folder
# that carries this run's exact unique names (a create whose reply was lost),
# then deletes this run's own spike/ branches. Idempotent.
cleanup_all() {
  local ws rc found branch
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  found=$(superset workspaces list --local --tag "$TAG" --json 2>/dev/null \
    | jq -r --arg p "$NAME_PREFIX-" '.[]? | select((.name // "") | startswith($p)) | .id | strings' 2>/dev/null) || found=
  for ws in $CREATED_WS $found; do
    rc=0
    paradev_smoke_owned "$ws" || rc=$?
    case "$rc" in
      0) superset workspaces archive "$ws" --local --json >/dev/null 2>&1 \
           || printf 'warning: could not archive smoke workspace %s\n' "$ws" >&2 ;;
      1) : ;;
      *) printf 'warning: refusing to archive workspace %s: not provably this run'"'"'s\n' "$ws" >&2 ;;
    esac
  done
  for branch in "$BRANCH_PREFIX-a" "$BRANCH_PREFIX-b"; do
    git -C "$PROJECT_PATH" show-ref --verify --quiet "refs/heads/$branch" || continue
    git -C "$PROJECT_PATH" branch -D "$branch" >/dev/null 2>&1 \
      || printf 'warning: could not delete smoke branch %s\n' "$branch" >&2
  done
}
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- helpers --------------------------------------------------------------------

# wait_screen <target> <needle> <seconds>: poll the live screen until it shows
# <needle>; prints the last screen read. 1 on timeout.
wait_screen() {  # <target> <needle> <seconds>
  local target=$1 needle=$2 secs=$3 deadline screen=
  deadline=$(( $(date +%s) + secs ))
  while :; do
    screen=$(fm_backend_capture paradev "$target" 60 2>/dev/null) || screen=
    case "$screen" in *"$needle"*) printf '%s' "$screen"; return 0 ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || { printf '%s' "$screen"; return 1; }
    sleep 0.3
  done
}

spawn_crewmate() {  # <suffix> -> sets SPAWN_WS SPAWN_PATH SPAWN_TARGET
  local suffix=$1 raw rc=0
  SPAWN_WS='' SPAWN_PATH='' SPAWN_TARGET=''
  raw=$(fm_backend_paradev_worktree_create "$PROJECT_ID" "$NAME_PREFIX-$suffix" "$BRANCH_PREFIX-$suffix") || rc=$?
  SPAWN_WS=${raw%%$'\t'*}
  [ -z "$SPAWN_WS" ] || CREATED_WS="$CREATED_WS $SPAWN_WS"
  [ "$rc" -eq 0 ] || fail "worktree_create for crewmate $suffix failed (exit $rc)"
  SPAWN_PATH=${raw#*$'\t'}
  SPAWN_TARGET=$(fm_backend_paradev_terminal_create "$SPAWN_WS" "$NAME_PREFIX-$suffix") \
    || fail "terminal_create for crewmate $suffix failed"
}

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# --- preflight --------------------------------------------------------------------

fm_backend_runtime_check paradev || fail "runtime_check refused a host that answers projects list"
resolved=$(fm_backend_paradev_project_id "$PROJECT_PATH") || fail "project_id could not resolve $PROJECT_PATH"
[ "$resolved" = "$PROJECT_ID" ] || fail "project_id resolved $PROJECT_PATH to '$resolved', not $PROJECT_ID"
for branch in "$BRANCH_PREFIX-a" "$BRANCH_PREFIX-b"; do
  if git -C "$PROJECT_PATH" show-ref --verify --quiet "refs/heads/$branch"; then
    CLEANED=1
    echo "skip: branch $branch already exists in $PROJECT_PATH and is not this run's"
    exit 0
  fi
done
pass "real paradev: runtime_check passes and project_id resolves the clone path to $PROJECT_ID"

# --- spawn two crewmates ------------------------------------------------------------

t0=$(date +%s)
spawn_crewmate a
WS_A=$SPAWN_WS PATH_A=$SPAWN_PATH T_A=$SPAWN_TARGET
# The first send goes out right after terminals create, as bin/fm-spawn.sh's
# launch does, so a shell that is not ready yet would show here.
mark_a="fm-smoke-a-$RUN"
fm_backend_paradev_send_text_line "$T_A" "echo $mark_a-\$((40+2))" >/dev/null \
  || fail "send_text_line right after terminals create failed"
screen=$(wait_screen "$T_A" "$mark_a-42" 20) \
  || fail "a send issued right after terminals create never ran in the new shell: $screen"
first_send_s=$(( $(date +%s) - t0 ))
spawn_crewmate b
WS_B=$SPAWN_WS PATH_B=$SPAWN_PATH T_B=$SPAWN_TARGET
[ "$WS_A" != "$WS_B" ] || fail "two spawns returned the same workspace id $WS_A"
pass "real paradev: two crewmates spawned (workspace + shell terminal each); a send issued right after create ran (create-to-output ${first_send_s}s)"

check_worktree() {  # <suffix> <workspace-id> <worktree>
  [ -d "$3" ] || fail "crewmate $1's worktree $3 does not exist"
  [ "$(real_dir "$3")" != "$(real_dir "$PROJECT_PATH")" ] || fail "crewmate $1's worktree is the project clone itself"
  [ "$(git -C "$3" rev-parse --show-toplevel 2>/dev/null)" = "$(real_dir "$3")" ] \
    || fail "crewmate $1's worktree $3 is not its own git worktree root"
  [ "$(git -C "$3" symbolic-ref --short HEAD 2>/dev/null)" = "$BRANCH_PREFIX-$1" ] \
    || fail "crewmate $1's worktree is not on $BRANCH_PREFIX-$1"
  [ "$(fm_backend_worktree_path paradev "$2")" = "$3" ] \
    || fail "worktree_path for crewmate $1's workspace does not read back $3"
}
check_worktree a "$WS_A" "$PATH_A"
check_worktree b "$WS_B" "$PATH_B"
[ "$(real_dir "$PATH_A")" != "$(real_dir "$PATH_B")" ] || fail "both crewmates share one worktree"
pass "real paradev: each crewmate owns its own isolated worktree on its spike/ branch, and worktree_path reads it back by id"

tagged=$(superset workspaces list --local --tag "$TAG" --json) || fail "workspaces list --tag $TAG failed"
for ws in "$WS_A" "$WS_B"; do
  printf '%s' "$tagged" | jq -e --arg w "$ws" 'any(.[]; .id == $w)' >/dev/null \
    || fail "workspace $ws is missing from the $TAG sidebar folder"
done
pass "real paradev: both crewmates file into one $TAG sidebar folder"

# A second create on a live crewmate's branch must refuse and leave that
# crewmate alone (the adapter never adopts or archives a workspace it did not
# just create).
dup_rc=0
dup_err=$(mktemp "${TMPDIR:-/tmp}/fm-paradev-smoke-dup.XXXXXX") || fail "mktemp failed"
dup=$(fm_backend_paradev_worktree_create "$PROJECT_ID" "$NAME_PREFIX-a" "$BRANCH_PREFIX-a" 2>"$dup_err") || dup_rc=$?
dup_reason=$(head -1 "$dup_err")
rm -f "$dup_err"
dup_ws=${dup%%$'\t'*}
if [ -n "$dup_ws" ] && [ "$dup_ws" != "$WS_A" ]; then CREATED_WS="$CREATED_WS $dup_ws"; fi
[ "$dup_rc" -ne 0 ] || fail "a second create on $BRANCH_PREFIX-a was accepted (returned '$dup')"
fm_backend_target_exists paradev "$T_A" || fail "the refused duplicate create disturbed crewmate a's terminal"
[ "$(fm_backend_worktree_path paradev "$WS_A")" = "$PATH_A" ] || fail "the refused duplicate create disturbed crewmate a's workspace"
pass "real paradev: a duplicate create on a live crewmate's branch refuses and leaves that crewmate intact ($dup_reason)"

# --- metadata the spawn would record ---------------------------------------------------

META_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-paradev-smoke-meta.XXXXXX") || fail "mktemp failed"
write_meta() {  # <file> <id> <target> <workspace> <worktree>
  printf '%s\n' "window=fm-$2" "endpoint_task_id=$2" "terminal=$3" "worktree=$5" \
    "project=$PROJECT_PATH" "backend=paradev" "paradev_workspace_id=$4" \
    "paradev_project_id=$PROJECT_ID" "kind=ship" "mode=no-mistakes" > "$1"
}
write_meta "$META_DIR/smoke-a.meta" smoke-a "$T_A" "$WS_A" "$PATH_A"
fm_backend_validate_task_endpoint "$META_DIR/smoke-a.meta" smoke-a || fail "a record of the live crewmate a was refused"
[ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "paradev:$T_A" ] \
  || fail "validated endpoint was '$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET', not paradev:$T_A"
write_meta "$META_DIR/smoke-x.meta" smoke-x "$WS_B:${T_A#*:}" "$WS_A" "$PATH_A"
if fm_backend_validate_task_endpoint "$META_DIR/smoke-x.meta" smoke-x 2>/dev/null; then
  fail "a record whose terminal names crewmate b's workspace but whose workspace is a's was accepted"
fi
rm -rf "$META_DIR"
pass "real paradev: the recorded live ids validate as the task endpoint, and a cross-workspace record refuses"

# --- peek and send ---------------------------------------------------------------------

check_shell_cwd() {  # <suffix> <target> <worktree>
  local screen
  fm_backend_paradev_send_text_line "$2" "pwd" >/dev/null || fail "send_text_line pwd to crewmate $1 failed"
  screen=$(wait_screen "$2" "$3" 15) || fail "crewmate $1's shell did not start in its worktree $3: $screen"
}
check_shell_cwd a "$T_A" "$PATH_A"
check_shell_cwd b "$T_B" "$PATH_B"
pass "real paradev: each crewmate's shell starts in its own worktree"

mark_b="fm-smoke-b-$RUN"
fm_backend_paradev_send_literal "$T_B" "echo $mark_b-\$((6*7))" >/dev/null || fail "send_literal to crewmate b failed"
sleep 0.5
screen=$(fm_backend_capture paradev "$T_B" 60) || fail "capture of crewmate b failed"
case "$screen" in *"$mark_b-42"*) fail "send_literal submitted without an Enter: $screen" ;; esac
fm_backend_send_key paradev "$T_B" Enter || fail "send_key Enter to crewmate b failed"
screen=$(wait_screen "$T_B" "$mark_b-42" 15) || fail "send_literal + Enter did not run on crewmate b: $screen"
pass "real paradev: send_literal types without submitting and send_key Enter submits it"

screen=$(fm_backend_capture paradev "$T_A" 60) || fail "capture of crewmate a failed"
case "$screen" in *"$mark_b"*) fail "crewmate a's screen shows crewmate b's input: $screen" ;; esac
case "$screen" in *"$mark_a-42"*) : ;; *) fail "crewmate a's screen lost its own earlier output: $screen" ;; esac
pass "real paradev: peek reads each crewmate's own screen, with no cross-talk"

fm_backend_paradev_send_text_line "$T_A" "printf '%s\\n' --dash-arg 'a=b=c'" >/dev/null \
  || fail "send_text_line with dash and equals characters failed"
wait_screen "$T_A" "--dash-arg" 15 >/dev/null || fail "dash-leading text did not arrive literally"
pass "real paradev: send_text_line carries dash-leading and = text literally"

verdict=$(fm_backend_send_text_submit paradev "$T_B" "echo submit-$RUN-\$((50+5))" 3 0.4 0.4) \
  || fail "send_text_submit to crewmate b failed"
[ "$verdict" != send-failed ] || fail "send_text_submit reported send-failed"
wait_screen "$T_B" "submit-$RUN-55" 15 >/dev/null || fail "send_text_submit did not run the line (verdict $verdict)"
pass "real paradev: send_text_submit types once and submits (composer verdict on a shell: $verdict)"

fm_backend_paradev_send_text_line "$T_A" "sleep 300" >/dev/null || fail "send_text_line sleep failed"
sleep 1
fm_backend_send_key paradev "$T_A" C-c || fail "send_key C-c failed"
fm_backend_paradev_send_text_line "$T_A" "echo after-ctrl-c-$RUN-\$((1+1))" >/dev/null || fail "send after C-c failed"
wait_screen "$T_A" "after-ctrl-c-$RUN-2" 15 >/dev/null || fail "C-c did not interrupt the foreground command"
for key in Escape C-u; do
  fm_backend_send_key paradev "$T_A" "$key" || fail "send_key $key was rejected by the real CLI"
done
pass "real paradev: send_key C-c interrupts a running command, and Escape and C-u are accepted"

bs=$(fm_backend_busy_state paradev "$T_A")
[ "$bs" = unknown ] || fail "a plain shell terminal must read busy_state unknown (no agent), got '$bs'"
fm_backend_target_exists paradev "$T_A" || fail "target_exists is false for live crewmate a"
fm_backend_target_exists paradev "$WS_A:fm-smoke-no-such-terminal" \
  && fail "target_exists is true for a terminal id that does not exist"
pass "real paradev: busy_state is unknown for a shell, and target_exists tells a live terminal from an unknown id"

# --- teardown ----------------------------------------------------------------------------

# Crewmate a, in bin/fm-teardown.sh's order: close and prove the terminal gone,
# check the recorded id still resolves to the recorded path, then archive.
fm_backend_kill paradev "$T_A" || fail "kill of crewmate a's terminal failed"
fm_backend_target_exists paradev "$T_A" && fail "crewmate a's terminal is still listed after kill"
fm_backend_kill paradev "$T_A" || fail "a repeat kill of an already-closed terminal must stay a success"
[ -d "$PATH_A" ] || fail "closing crewmate a's terminal removed its worktree"
[ "$(fm_backend_worktree_path paradev "$WS_A")" = "$PATH_A" ] \
  || fail "the recorded id no longer resolves to the recorded path before archive"
fm_backend_remove_worktree paradev "$WS_A" || fail "archive of crewmate a's workspace failed"
[ ! -e "$PATH_A" ] || fail "archive left crewmate a's worktree folder at $PATH_A"
fm_backend_worktree_path paradev "$WS_A" >/dev/null 2>&1 && fail "worktree_path still resolves an archived workspace"
fm_backend_remove_worktree paradev "$WS_A" || fail "a repeat archive of an already-archived workspace must stay a success"
pass "real paradev: teardown closes crewmate a's terminal (proved gone), archives the exact workspace and its folder, and both steps are idempotent"

screen=$(fm_backend_capture paradev "$T_B" 60) || fail "crewmate b became unreadable after a's teardown"
case "$screen" in *"submit-$RUN-55"*) : ;; *) fail "crewmate b's screen changed after a's teardown: $screen" ;; esac
fm_backend_paradev_send_text_line "$T_B" "echo still-b-$RUN-\$((3*3))" >/dev/null || fail "send to crewmate b after a's teardown failed"
wait_screen "$T_B" "still-b-$RUN-9" 15 >/dev/null || fail "crewmate b stopped answering after a's teardown"
pass "real paradev: tearing down crewmate a leaves crewmate b live and answering"

fm_backend_kill paradev "$T_B" || fail "kill of crewmate b's terminal failed"
[ "$(fm_backend_worktree_path paradev "$WS_B")" = "$PATH_B" ] || fail "crewmate b's recorded id/path gate failed"
fm_backend_remove_worktree paradev "$WS_B" || fail "archive of crewmate b's workspace failed"
[ ! -e "$PATH_B" ] || fail "archive left crewmate b's worktree folder at $PATH_B"
pass "real paradev: crewmate b tears down the same way"

# --- the guarded cleanup leaves nothing ----------------------------------------------------

cleanup_all
left=$(superset workspaces list --local --tag "$TAG" --json \
  | jq -r --arg p "$NAME_PREFIX-" '[.[]? | select((.name // "") | startswith($p))] | length') \
  || fail "could not re-read the $TAG folder after cleanup"
[ "$left" = 0 ] || fail "cleanup left $left smoke workspace(s) in the $TAG folder"
for branch in "$BRANCH_PREFIX-a" "$BRANCH_PREFIX-b"; do
  git -C "$PROJECT_PATH" show-ref --verify --quiet "refs/heads/$branch" \
    && fail "cleanup left branch $branch in $PROJECT_PATH"
done
pass "real paradev: cleanup leaves no smoke workspace in $TAG and no smoke branch in the project"
