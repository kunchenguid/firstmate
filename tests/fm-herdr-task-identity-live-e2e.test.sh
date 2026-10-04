#!/usr/bin/env bash
# Default-on live guard for the Herdr task-identity check
# (bin/backends/herdr.sh's fm_backend_herdr_task_identity) against every REAL
# harness the fleets run - kiro-cli, claude, codex, pi, and agy - under the
# REAL Herdr binary. FM_HERDR_TASK_IDENTITY_HARNESSES narrows the list for a
# quicker rerun after one harness upgrade.
#
# The check refuses to type into a task's pane when the agent there was not
# launched for that task: after a Herdr restart with agent resume on, an agent
# is resumed in the directory its pane was created in, with the server's
# environment rather than the launch marker FM_TASK_ID. The verdict reads the
# kernel's record of each process environment in the pane's tree, so the one
# vendor fact no fixture can prove is whether a real harness, started the way
# bin/fm-spawn.sh starts it (`export FM_TASK_ID=<id>` in the pane shell, then
# the launch command), still presents a process that carries the marker. A
# harness that dropped it from every process it runs would be refused by
# mistake. This guard launches each installed harness with no prompt (no model
# token is spent), proves `match` with the marker and `foreign` without it, and
# fails naming the harness and version. An absent harness is reported, and a run
# that checked no harness fails rather than passing over nothing.
#
# With the first harness that ran, it also drives the three real senders at an
# unmarked agent recorded as a ship task: bin/fm-send.sh --key and typed text
# refuse, the inbox steer records its message without typing the doorbell, and
# bin/fm-control.sh interrupt refuses.
#
# Run it after any harness or Herdr upgrade. Always runs on a private, named,
# throwaway lab session, never the default one (tests/herdr-test-safety.sh;
# bin/fm-herdr-lab.sh owns the isolation).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_TASK_IDENTITY_LIVE_E2E herdr jq
[ -r /proc/self/environ ] || { printf 'skip: live: no /proc on this host; the identity check reads unknown here by design\n'; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset FM_TASK_INBOX FM_KIRO_TASK_ID

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }

SESSION="fm-lab-task-id-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  local status=$?
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-id.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
mkdir -p "$SCRATCH/cwd"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$SCRATCH/cwd") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}

# new_pane <label>: one task tab in the lab workspace; prints "<tab> <pane>".
new_pane() {
  local ids
  ids=$(fm_backend_herdr_create_task "$CONTAINER" "$1" "$SCRATCH/cwd" "$SEEDED_TAB_ID") \
    || fail "create_task failed for $1"
  SEEDED_TAB_ID=
  printf '%s' "$ids"
}

wait_agent() {  # <pane> <tries>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$1")" = agent ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

stop_pane_tree() {  # <pane>
  local shell_pid pids
  shell_pid=$(lab pane process-info --pane "$1" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty')
  [ -n "$shell_pid" ] || return 0
  pids=$(ps -axo pid=,ppid= | awk -v root="$shell_pid" '
    { pid[NR] = $1; ppid[NR] = $2 }
    END {
      want[root] = 1; changed = 1
      while (changed) { changed = 0; for (n = 1; n <= NR; n++) if ((ppid[n] in want) && !(pid[n] in want)) { want[pid[n]] = 1; changed = 1 } }
      for (n = 1; n <= NR; n++) if (pid[n] in want && pid[n] != root) print pid[n]
    }')
  # shellcheck disable=SC2086 # One pid per word.
  [ -z "$pids" ] || kill -TERM $pids 2>/dev/null || true
  sleep 1
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -KILL $pids 2>/dev/null || true
}

harness_version() {  # <harness>
  local v
  v=$("$1" --version 2>/dev/null | head -1 | tr -d '\r')
  printf '%s' "${v:-unknown}"
}

# The launch command for each harness with no prompt, as a TUI waiting for input.
harness_launch() {  # <harness>
  case "$1" in
    kiro-cli) printf 'kiro-cli chat' ;;
    *) printf '%s' "$1" ;;
  esac
}

CHECKED=
SENDER_PANE=
SENDER_TAB=
SENDER_HARNESS=
for HARNESS in ${FM_HERDR_TASK_IDENTITY_HARNESSES:-kiro-cli claude codex pi agy}; do
  if ! command -v "$HARNESS" >/dev/null 2>&1; then
    note "$HARNESS is not installed on this host; its identity was not checked"
    continue
  fi
  VERSION=$(harness_version "$HARNESS")
  read -r TAB PANE <<EOF
$(new_pane "fm-id-$HARNESS-marked")
EOF
  fm_backend_herdr_send_text_line "$SESSION:$PANE" "export FM_TASK_ID=live-$HARNESS" \
    || fail "could not export the task marker in the $HARNESS pane"
  fm_backend_herdr_send_text_line "$SESSION:$PANE" "$(harness_launch "$HARNESS")" \
    || fail "could not launch $HARNESS"
  wait_agent "$PANE" 160 \
    || fail "$HARNESS $VERSION never read as a running harness in pane process-info (herdr $HERDR_VERSION)"
  sleep 2
  VERDICT=$(fm_backend_herdr_task_identity "$SESSION:$PANE" "live-$HARNESS")
  [ "$VERDICT" = match ] \
    || fail "$HARNESS $VERSION launched after export FM_TASK_ID=live-$HARNESS reads '$VERDICT', not 'match'; the identity check would refuse this harness by mistake (herdr $HERDR_VERSION)"
  VERDICT=$(fm_backend_herdr_task_identity "$SESSION:$PANE" "other-task")
  [ "$VERDICT" = foreign ] \
    || fail "$HARNESS $VERSION launched for live-$HARNESS reads '$VERDICT' for another task id, not 'foreign' (herdr $HERDR_VERSION)"
  stop_pane_tree "$PANE"

  read -r TAB PANE <<EOF
$(new_pane "fm-id-$HARNESS-bare")
EOF
  fm_backend_herdr_send_text_line "$SESSION:$PANE" "$(harness_launch "$HARNESS")" \
    || fail "could not launch the unmarked $HARNESS"
  wait_agent "$PANE" 160 \
    || fail "the unmarked $HARNESS $VERSION never read as a running harness (herdr $HERDR_VERSION)"
  sleep 2
  VERDICT=$(fm_backend_herdr_task_identity "$SESSION:$PANE" "live-$HARNESS")
  [ "$VERDICT" = foreign ] \
    || fail "$HARNESS $VERSION launched without FM_TASK_ID reads '$VERDICT', not 'foreign'; a resumed session would not be caught (herdr $HERDR_VERSION)"
  pass "real $HARNESS $VERSION under herdr $HERDR_VERSION: the launch marker reads match, another task foreign, and an unmarked launch foreign"
  CHECKED="$CHECKED $HARNESS"
  if [ -z "$SENDER_PANE" ]; then
    SENDER_PANE=$PANE
    SENDER_TAB=$TAB
    SENDER_HARNESS=$HARNESS
  else
    stop_pane_tree "$PANE"
  fi
done
[ -n "$CHECKED" ] || fail "no listed harness (${FM_HERDR_TASK_IDENTITY_HARNESSES:-kiro-cli claude codex pi agy}) is installed; this guard checked nothing"

# --- the real senders refuse an unmarked agent recorded as a ship task -------

HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/idlive"
printf '# Task\n' > "$HOME_DIR/data/idlive/brief.md"
WORKSPACE_ID=${CONTAINER#*:}
{
  echo "window=$SESSION:$SENDER_PANE"
  echo "endpoint_task_id=idlive"
  echo "worktree=$SCRATCH/cwd"
  echo "project=$SCRATCH/cwd"
  echo "harness=$SENDER_HARNESS"
  echo "kind=ship"
  echo "mode=direct-PR"
  echo "yolo=off"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$SENDER_TAB"
  echo "herdr_pane_id=$SENDER_PANE"
} > "$HOME_DIR/state/idlive.meta"
lab tab rename "$SENDER_TAB" fm-idlive >/dev/null 2>&1 || fail "could not label the sender tab as the task's tab"

run_home() { env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SEND_SETTLE=0 "$@" 2>&1; }

if OUT=$(run_home "$ROOT/bin/fm-send.sh" idlive --key Enter); then
  fail "fm-send --key to an unmarked $SENDER_HARNESS recorded as ship task idlive must refuse: $OUT"
fi
assert_contains "$OUT" "was not launched for task idlive" "the fm-send --key refusal did not name the foreign agent"
# A leading "/" rides the typed plane, which types into the terminal itself.
if OUT=$(run_home "$ROOT/bin/fm-send.sh" idlive /help); then
  fail "a typed fm-send to an unmarked $SENDER_HARNESS recorded as ship task idlive must refuse: $OUT"
fi
assert_contains "$OUT" "was not launched for task idlive" "the typed fm-send refusal did not name the foreign agent"
OUT=$(run_home "$ROOT/bin/fm-send.sh" idlive "hello from the live identity guard") \
  || fail "an inbox steer must still record its message for a foreign endpoint: $OUT"
assert_contains "$OUT" "doorbell not typed because the agent in" "the inbox steer typed a doorbell into a foreign agent"
ls "$HOME_DIR/state/idlive.inbox/"*.msg >/dev/null 2>&1 || fail "the inbox steer did not record its message"
if OUT=$(run_home "$ROOT/bin/fm-control.sh" idlive interrupt); then
  fail "fm-control interrupt on an unmarked $SENDER_HARNESS must refuse: $OUT"
fi
assert_contains "$OUT" "was not launched for task idlive" "the fm-control refusal did not name the foreign agent"
pass "real herdr $HERDR_VERSION + $SENDER_HARNESS: fm-send --key, typed fm-send, and fm-control refuse an unmarked agent, and an inbox steer records without a doorbell"
stop_pane_tree "$SENDER_PANE"
note "harnesses checked:$CHECKED"
