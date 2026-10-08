#!/usr/bin/env bash
# tests/fm-restored-recover-live-e2e.test.sh - default-on live guard proving
# that the INSTALLED Claude Code's startup gates are still recognized
# (fm_composer_startup_dialog in bin/fm-composer-lib.sh) and that
# bin/fm-control.sh exit still stops a Claude parked on one without answering
# it.
#
# Why this file exists: a restored worker parked on a startup gate is found and
# stopped by reading the gate off the rendered viewport, which is a surface
# Claude Code controls and changes without notice. The portable counterpart,
# tests/fm-restored-recover.test.sh, can only replay the viewport recorded in
# docs/verification/runtime-backends.md "Claude startup gates"; this guard is
# what notices a release that redraws it.
#
# Claude is launched bare in a disposable project and never receives a prompt,
# so this consumes no model tokens. It uses the launching user's own Claude
# configuration because the gates appear only before a session can start: the
# first launch meets the folder-trust gate; the second, after the lab's task
# worktree is trusted through bin/fm-claude-trust.sh exactly as a spawn would
# trust it, meets the external CLAUDE.md imports gate. Neither gate is answered,
# and the guard asserts the store records no consent for either.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_RESTORED_RECOVER_LIVE claude tmux jq

fail() { printf 'not ok - %s [claude %s]\n' "$1" "${CLAUDE_VERSION:-unknown}" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
CLAUDE_VERSION=${CLAUDE_VERSION%% *}
REAL_TMUX=$(command -v tmux)
SOCKET="fm-restored-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-restored-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SESSION=gates
STORE="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && fm_test_remove_tree "$LAB"
  fm_test_cleanup
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/home/data"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -u -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
fm_git_worktree "$LAB/proj" "$LAB/wt" task-gates || fail "could not build the lab worktree"
printf 'Outside notes.\n' > "$LAB/outside.md"

# A Claude started from inside another Claude session inherits that session's
# CLAUDE* variables, which change how it starts; the lab Claude must see none.
CLAUDE_UNSET=()
for var in $(env | sed -n 's/^\(CLAUDE[A-Z0-9_]*\)=.*/\1/p'); do
  [ "$var" = CLAUDE_CONFIG_DIR ] || CLAUDE_UNSET+=(-u "$var")
done

env ${CLAUDE_UNSET[@]+"${CLAUDE_UNSET[@]}"} "$REAL_TMUX" -u -L "$SOCKET" new-session -d -s "$SESSION" -n idle -x 200 -y 50 -c "$LAB" -- /bin/sh \
  || fail "could not start the private tmux server"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
PATH="$LAB/shim:$PATH"
export PATH

consent() {  # <path> <key> -> the store's value, or empty
  jq -r --arg p "$1" --arg k "$2" '.projects[$p][$k] // empty' "$STORE" 2>/dev/null
}

# meet_gate <id> <expected gate>: launch Claude in the worktree, wait for the
# gate, and require that it is recognized by name.
meet_gate() {  # <id> <gate>
  local id=$1 want=$2 i=0 screen got
  fm_write_meta "$LAB/home/state/$id.meta" \
    "window=$SESSION:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/wt" \
    "project=$LAB/proj" harness=claude kind=ship mode=no-mistakes yolo=off \
    model=default effort=default backend=tmux
  tmux new-window -d -t "$SESSION:" -n "fm-$id" -c "$LAB/wt" -- /bin/sh -c 'claude; exec /bin/sh' \
    || fail "could not open the $id window"
  while [ "$i" -lt 120 ]; do
    screen=$(fm_backend_visible_capture tmux "$SESSION:fm-$id" 2>/dev/null) || screen=
    if got=$(fm_composer_startup_dialog "$screen"); then
      [ "$got" = "$want" ] || fail "Claude drew the $got where the $want was expected"
      [ "$(fm_backend_agent_state tmux "$SESSION:fm-$id")" = alive ] \
        || fail "Claude parked on the $want does not read alive"
      return 0
    fi
    i=$((i + 1))
    sleep 0.5
  done
  fail "the $want never appeared or is no longer recognized; last viewport:
$screen"
}

stop_at_gate() {  # <id> <gate>
  local out
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID FM_HOME="$LAB/home" FM_CONTROL_EXIT_WAIT=10 \
    "$ROOT/bin/fm-control.sh" "$1" exit 2>&1) \
    || fail "fm-control exit refused a Claude parked on the $2: $out"
  case "$out" in
    *stopped-at-startup-gate*) : ;;
    *) fail "fm-control exit on the $2 reported '$out' rather than stopped-at-startup-gate" ;;
  esac
  [ "$(fm_backend_agent_state tmux "$SESSION:fm-$1")" = dead ] \
    || fail "Claude parked on the $2 is still running after exit"
}

meet_gate trust "Claude folder-trust prompt"
stop_at_gate trust "Claude folder-trust prompt"
[ "$(consent "$LAB/wt" hasTrustDialogAccepted)" != true ] \
  || fail "stopping Claude at the folder-trust prompt recorded trust"
pass "real claude $CLAUDE_VERSION: the folder-trust prompt is recognized and fm-control exit stops Claude without trusting the folder"

printf '# Lab\n@../outside.md\n' > "$LAB/wt/CLAUDE.md"
"$ROOT/bin/fm-claude-trust.sh" "$LAB/wt" "$LAB/proj" >/dev/null \
  || fail "could not trust the lab worktree the way a spawn does"
meet_gate imports "Claude external CLAUDE.md imports prompt"
stop_at_gate imports "Claude external CLAUDE.md imports prompt"
[ "$(consent "$LAB/wt" hasClaudeMdExternalIncludesApproved)" != true ] \
  || fail "stopping Claude at the external imports prompt approved the imports"
pass "real claude $CLAUDE_VERSION: the external CLAUDE.md imports prompt is recognized and fm-control exit stops Claude without approving the imports"
