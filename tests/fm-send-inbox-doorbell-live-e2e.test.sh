#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. The
# doorbell names the inbox as "$FM_TASK_INBOX", so each worker is launched the
# way bin/fm-spawn.sh launches it, with FM_TASK_INBOX exported to its home's
# state/<task>.inbox, and receives no brief at all: it must resolve the inbox
# from the doorbell plus its own environment. A stub can only confirm the
# assumption already written into the stub, so per
# .agents/skills/firstmate-coding-guidelines this is proven against every
# INSTALLED verified harness: each is launched idle in an isolated tmux server,
# steered through the REAL fm-send (durable record + doorbell), and must both
# ACT on the instruction (create a named file) and ACKNOWLEDGE it (the mv into
# handled/), failing loudly with the harness name and version.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Codex replays the generated worker flags; optionally select its model with
# FM_SEND_INBOX_LIVE_CODEX_MODEL. Its reader is paused while fm-send queues
# the doorbell, then resumed: text and Enter must submit even as one burst,
# without a recovery re-ring hiding a missed submission.
#
# The Codex secondmate variant replays the generated secondmate launch (hooks
# on) and needs an opt-in dedicated fixture, FM_SEND_INBOX_LIVE_SECONDMATE_HOME:
# an operator-made standalone clone under ${TMPDIR:-/tmp} at this checkout's
# HEAD with an identical .codex/hooks.json, whose .git/fm-live-secondmate-fixture
# names its own canonical path (fm_live_sm_fixture_check in tests/fixtures.sh
# owns every refusal). That clone is the secondmate's own home, its launch's
# FM_HOME, and its window's cwd. Its hooks load only if the operator's normal
# native Codex review trusted them at that exact path; an untrusted fixture
# shows the real review modal and never reads as idle. Hook execution is not
# claimed unless observed. The executed command is the generated environment
# prefix, codex, --no-daemon where supported, and the generated global flags:
# no positional launch brief, so no turn starts before the doorbell (logged as
# `<positional brief present: no>`). The secondmate gets no input, not even a
# modal-dismissing key, until fm_test_wait_codex_idle reads its composer as
# empty and its Codex rollout for this fixture cwd since launch as no turn
# started or turn completed (fm_test_codex_turn_state), for 5 consecutive
# one-second polls within FM_SEND_INBOX_LIVE_IDLE_TIMEOUT (seconds, default
# 180). Otherwise it reports `inconclusive: turn active`, `inconclusive:
# composer not readable or not empty (<state>)`, `inconclusive: turn evidence
# unreadable or invalid`, or not quiet, sends nothing, and fails the run;
# that is never a pass or a negative-control result. An earlier version of
# this guard wrongly required an initial turn to finish; this launch has none.
# The guard writes only .fm-secondmate-home and data/charter.md there (the
# charter is fm-spawn's launch input; it is never delivered). Once the
# fixture's Codex processes are gone it removes them, the documented state/
# files its startup and hooks leave (FM_LIVE_SM_STATE_FILES), an empty
# state/terminal-outcomes, and any data/ or state/ it created; any other
# state/ entry fails the run, naming it, with nothing removed. Without the fixture the variant is reported untested,
# never passed; a refused fixture fails the run. Results print per variant.
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses other than the Codex secondmate launch with the repo
# root as cwd, which the operator's machine has normally already trusted; a
# trust dialog is a real unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(fm_test_tmproot fm-inbox-live)
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
IDLE_TIMEOUT=${FM_SEND_INBOX_LIVE_IDLE_TIMEOUT:-180}
CHECKED=0
FAILED=0
VERDICT=''
RESULTS=''
SM_GROUP=''
STOPPED_READER=''
STOPPED_IDENTITY=''

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  if [ -n "$STOPPED_READER" ] && \
    [ "$(fm_test_pid_identity "$STOPPED_READER" 2>/dev/null)" = "$STOPPED_IDENTITY" ]; then
    kill -CONT "$STOPPED_READER" 2>/dev/null || true
  fi
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  finish_fixture || true
  fm_test_cleanup
}
trap cleanup EXIT

# Wait (bounded) until no process remains in the secondmate pane's group or
# with its cwd in the fixture; prints the leftover PIDs on timeout.
fixture_quiet() {
  local i=0 left p c
  while :; do
    left=''
    [ -z "$SM_GROUP" ] ||
      left=$(ps -axo pid=,pgid= | awk -v g="$SM_GROUP" '$2 == g {printf " %s", $1}')
    for p in /proc/[0-9]*; do
      c=$(readlink "$p/cwd" 2>/dev/null) || continue
      case "$c" in
        "$FM_LIVE_SM_FIXTURE"|"$FM_LIVE_SM_FIXTURE"/*) left="$left ${p#/proc/}" ;;
      esac
    done
    [ -n "$left" ] || return 0
    [ "$i" -lt 30 ] || { printf '%s\n' "$left"; return 1; }
    sleep 1
    i=$((i + 1))
  done
}

# Clean the dedicated fixture only after its processes stopped; any refusal
# fails the run and leaves the fixture as found for the operator.
finish_fixture() {
  local left
  [ -n "$FM_LIVE_SM_FIXTURE" ] || return 0
  if ! left=$(fixture_quiet); then
    printf 'not ok - codex secondmate: fixture processes still running (pids:%s), nothing removed: %s\n' \
      "$left" "$FM_LIVE_SM_FIXTURE" >&2
    FM_LIVE_SM_FIXTURE=''
    return 1
  fi
  if ! fm_live_sm_fixture_cleanup >&2; then
    printf 'not ok - codex secondmate: fixture cleanup refused (see above)\n' >&2
    FM_LIVE_SM_FIXTURE=''
    return 1
  fi
}

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name> [secondmate]
  local launch flags isolated='' case_dir="$LAB/codex-launch" args
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex)
      args=(--mode no-mistakes --yolo off)
      if [ "${2:-}" = secondmate ]; then
        case_dir="$LAB/codex-secondmate-launch"
        args=("--secondmate=$FM_LIVE_SM_FIXTURE")
      fi
      [ -z "${FM_SEND_INBOX_LIVE_CODEX_MODEL:-}" ] || args+=(--model "$FM_SEND_INBOX_LIVE_CODEX_MODEL")
      launch=$(fm_test_capture_codex_launch "$case_dir" "${args[@]}") || return 1
      flags=$(fm_test_codex_global_flags "$launch")
      # Keep this private session independent of a surrounding Codex run.
      # Older CLIs have no daemon option and need only the environment reset.
      if codex --help 2>/dev/null | grep -q -- '--no-daemon'; then
        isolated='--no-daemon '
      fi
      if [ "${2:-}" = secondmate ]; then
        fm_test_codex_secondmate_cmd "$launch" "$isolated"
      else
        printf '%s' "env -u CODEX_THREAD_ID codex $isolated$flags"
      fi
      ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

# The secondmate's read-only idle evidence for fm_test_wait_codex_idle.
secondmate_idle_probe() {  # <window> <since>
  printf '%s %s\n' "$(fm_tmux_composer_state "$SESSION:$1")" \
    "$(fm_test_codex_turn_state "${CODEX_HOME:-$HOME/.codex}/sessions" "$FM_LIVE_SM_FIXTURE" "$2")"
}

check_harness_doorbell() {  # <name> [secondmate]
  local name=$1 role=${2:-} label version cmd win home task acted rec handled i ready_rc pane_pid group reader parent send_rc meta cwd=$ROOT since idle
  label=$name${role:+ $role}
  win="hx-$name${role:+-$role}"
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name" "$role") || {
    FAILED=1
    printf 'not ok - %s (%s): could not build the live launch recipe\n' "$label" "$version" >&2
    return 0
  }
  if [ "$role" = secondmate ]; then
    home="$LAB/codex-secondmate-launch/home"
    task=codex-live
    cwd=$FM_LIVE_SM_FIXTURE
    note "$label executed: $cmd <positional brief present: no>"
  else
    home="$LAB/$name-home"
    mkdir -p "$home/state"
    task="live-$name"
  fi
  acted="$LAB/acted-$name${role:+-$role}"
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$cwd" \
    -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$label" "$version" >&2; return 0; }
  tmux -L "$SOCKET" set-window-option -t "$SESSION:$win" automatic-rename off
  tmux -L "$SOCKET" set-window-option -t "$SESSION:$win" allow-rename off
  if [ "$role" = secondmate ]; then
    pane_pid=$(tmux -L "$SOCKET" display-message -p -t "$SESSION:$win" '#{pane_pid}')
    SM_GROUP=$(ps -o pgid= -p "$pane_pid" | tr -d '[:space:]')
  fi
  if [ "$role" = secondmate ]; then
    if ! idle=$(fm_test_wait_codex_idle "$IDLE_TIMEOUT" 5 secondmate_idle_probe "$win" "$since"); then
      FAILED=1
      VERDICT="$idle (no input sent; not a negative-control result)"
      printf 'not ok - %s (%s): %s within %ss; no input sent\n' "$label" "$version" "$idle" "$IDLE_TIMEOUT" >&2
      tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return 0
    fi
    pass "$label ($version): $idle before the doorbell (composer empty, rollout quiet for 5 polls)"
  else
    wait_ready "$win"; ready_rc=$?
    if [ "$ready_rc" -eq 1 ]; then
      FAILED=1
      printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$label" "$version" >&2
      tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return 0
    fi
    [ "$ready_rc" -eq 0 ] || note "$label ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  fi
  if [ "$role" = secondmate ]; then
    # Keep the spawn-recorded secondmate meta; only its window is private here.
    meta=$(sed "s/^window=.*/window=$SESSION:$win/" "$home/state/$task.meta") &&
      printf '%s\n' "$meta" > "$home/state/$task.meta"
  else
    printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  fi
  if [ "$name" = codex ]; then
    # Pause the native terminal reader, not its Node shim: stopping the whole
    # pane group did not retain a stopped state in the live pause baseline.
    # Scope discovery to this private pane's group and prove ancestry before
    # signaling; retain start identity so cleanup cannot resume a reused PID.
    pane_pid=$(tmux -L "$SOCKET" display-message -p -t "$SESSION:$win" '#{pane_pid}')
    group=$(ps -o pgid= -p "$pane_pid" | tr -d '[:space:]')
    case "$pane_pid" in
      ''|*[!0-9]*) fail "$label ($version): private pane has no valid process ID" ;;
    esac
    [ "$group" = "$pane_pid" ] || fail "$label ($version): private pane does not own its process group"
    reader=$(ps -axo pid=,pgid=,comm= | awk -v group="$group" \
      '$2 == group && $3 ~ /(^|\/)codex([_-].*)?$/ {print $1}')
    case "$reader" in
      ''|*[!0-9]*) fail "$label ($version): private pane has no unique native reader" ;;
    esac
    parent=$reader
    i=0
    while [ "$parent" != "$pane_pid" ] && [ "$i" -lt 16 ]; do
      parent=$(ps -o ppid= -p "$parent" | tr -d '[:space:]')
      [ -n "$parent" ] || break
      i=$((i + 1))
    done
    [ "$parent" = "$pane_pid" ] || fail "$label ($version): native reader is outside the private pane's ancestry"
    STOPPED_IDENTITY=$(fm_test_pid_identity "$reader") || fail "$label ($version): native reader has no start identity"
    STOPPED_READER=$reader
    [ "$(fm_test_pid_identity "$reader")" = "$STOPPED_IDENTITY" ] || fail "$label ($version): native reader changed before pause"
    kill -STOP "$STOPPED_READER" || fail "$label ($version): could not pause the private reader"
    # Signal delivery is asynchronous; wait for the observed stopped state.
    i=0
    while ! ps -o stat= -p "$reader" | grep -q T && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    ps -o stat= -p "$reader" | grep -q T || fail "$label ($version): private reader did not stop"
  fi
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    send_rc=0
  else
    send_rc=1
  fi
  if [ -n "$STOPPED_READER" ]; then
    [ "$(fm_test_pid_identity "$STOPPED_READER")" = "$STOPPED_IDENTITY" ] || fail "$label ($version): native reader changed before resume"
    kill -CONT "$STOPPED_READER" || fail "$label ($version): could not resume the private reader"
    STOPPED_READER=''
  fi
  if [ "$send_rc" -ne 0 ]; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$label" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$label" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$name" != codex ] && [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$label ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$label ($version): the doorbell reached a real worker, which acted and acked with the mv"
    [ "$name" != codex ] || pass "$label ($version): queued text and Enter submitted after reader pause without a recovery re-ring"
    [ "$role" != secondmate ] || VERDICT="pass ($idle)"
  else
    FAILED=1
    [ "$role" != secondmate ] || VERDICT="fail after $idle (discriminating)"
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$label" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

check_codex_secondmate() {
  local fixture rc
  fixture=$(fm_live_sm_fixture_check "${FM_SEND_INBOX_LIVE_SECONDMATE_HOME:-}" "$ROOT")
  rc=$?
  case "$rc" in
    0) ;;
    2)
      VERDICT='untested (no dedicated fixture)'
      note "codex secondmate: $fixture (FM_SEND_INBOX_LIVE_SECONDMATE_HOME)"
      return 0
      ;;
    *)
      FAILED=1
      VERDICT='inconclusive: fixture refused (not a negative-control result)'
      printf 'not ok - codex secondmate: inconclusive, dedicated fixture refused: %s\n' "$fixture" >&2
      return 0
      ;;
  esac
  fm_live_sm_fixture_prepare "$fixture" codex-live || {
    FAILED=1
    printf 'not ok - codex secondmate: inconclusive, could not mark the dedicated fixture: %s\n' "$fixture" >&2
    return 0
  }
  check_harness_doorbell codex secondmate
  [ -n "$VERDICT" ] || [ "$FAILED" -eq 0 ] ||
    VERDICT='fail before idle verification (not a negative-control result)'
  finish_fixture || { FAILED=1; VERDICT="${VERDICT:-pass}; fixture cleanup failed"; }
}

# Run one variant and record its own result line for the per-variant summary.
run_variant() {  # <label> <command...>
  local label=$1 before=$FAILED
  shift
  FAILED=0
  VERDICT=''
  "$@"
  if [ -z "$VERDICT" ]; then
    VERDICT=pass
    [ "$FAILED" -eq 0 ] || VERDICT=fail
  fi
  RESULTS="$RESULTS$label: $VERDICT
"
  [ "$before" -eq 0 ] || FAILED=1
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    if [ "$h" = codex ]; then
      run_variant 'codex crewmate' check_harness_doorbell codex
      run_variant 'codex secondmate' check_codex_secondmate
    else
      run_variant "$h" check_harness_doorbell "$h"
    fi
  else
    note "harness absent, not verified here: $h"
  fi
done

printf '%s' "$RESULTS" | sed 's/^/# result: /'
if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
