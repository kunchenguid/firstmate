#!/usr/bin/env bash
# fmr-verb.sh - the ONLY entry point a paired control machine may execute here.
#
# Deployed by bin/fm-relay-conn.sh into <control-root>/verbs/ on each task host.
# The Bifrost shell policy allows exactly this path plus arguments drawn from
# [A-Za-z0-9._@=+-], so no slash, quote, space-separated redirect, or shell
# metacharacter can reach a shell. Every long or arbitrary text - a brief, a
# steer, a report - travels through the exchange directory as a FILE and this
# script receives only a short reference to it.
#
# NO ENVIRONMENT IS INHERITED. The policy layer sets env_allowlist=[] and
# inherit_env=false, which overrides the profile's own --env list, so HOME and
# PATH do not exist when this runs (measured on both a macOS and a Linux target;
# docs/relay-host.md). Everything is resolved from BASH_SOURCE, external commands
# used before the config is loaded are absolute, and HOME/PATH/LANG for the
# firstmate scripts this drives come from <control-root>/config.
#
# LANG is not cosmetic here and its absence fails SILENTLY, which is worse than
# loudly. Without a UTF-8 locale, tmux replaces the embedded newlines in the
# multi-line -F format that fm_backend_tmux_target_exists uses with "_", so the
# seven candidate spellings of a target collapse into one underscore-joined line
# and the exact-match lookup finds nothing. Every live pane then reports as
# "backend target gone" and every remote task looks dead. Measured on 151
# (tmux 3.3a) 2026-08-01: 84 output lines with LANG=en_US.UTF-8, 12 without.
#
# Output protocol, one line first, always:
#   OK [<key>=<value> ...]      the verb succeeded; payload follows on later lines
#   ERR <code> <message>        the verb refused or failed
#   ALREADY_CLAIMED <detail>    spawn found an existing claim; a liveness report follows
# The control side reads the first token and never guesses from exit status alone.
#
# Claim atomicity is one local mkdir under <control-root>/tasks/<id>. A blind
# re-dispatch of the same id therefore loses the race on the host that owns the
# task, which is the only place the answer can be authoritative.
set -u

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$PWD/$self" ;; esac
verbs_dir=${self%/*}
control_root=${verbs_dir%/*}

emit_err() {  # <code> <message>
  printf 'ERR %s %s\n' "$1" "$2"
  exit 1
}

# ---- configuration -----------------------------------------------------------
# <control-root>/config carries only these keys. Anything else is ignored, and a
# value containing a newline cannot exist because the file is read line by line.
CFG_FM_ROOT=
CFG_FM_HOME=
CFG_HOME_DIR=
CFG_PATH=
CFG_PROJECTS=
CFG_FLEET_ROOT=
CFG_LANG=
CFG_GUI=
CFG_TMUX_SOCKET=
CFG_HOST_SESSION=
config_file="$control_root/config"
[ -f "$config_file" ] || emit_err config "no host config at $config_file"
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  key=${line%%=*}
  value=${line#*=}
  case "$key" in
    FM_ROOT) CFG_FM_ROOT=$value ;;
    FM_HOME) CFG_FM_HOME=$value ;;
    HOME_DIR) CFG_HOME_DIR=$value ;;
    PATH) CFG_PATH=$value ;;
    PROJECTS) CFG_PROJECTS=$value ;;
    FLEET_ROOT) CFG_FLEET_ROOT=$value ;;
    LANG) CFG_LANG=$value ;;
    GUI) CFG_GUI=$value ;;
    TMUX_SOCKET) CFG_TMUX_SOCKET=$value ;;
    HOST_SESSION) CFG_HOST_SESSION=$value ;;
  esac
done < "$config_file"
[ -n "$CFG_FM_ROOT" ] || emit_err config "FM_ROOT missing from host config"
[ -n "$CFG_FM_HOME" ] || emit_err config "FM_HOME missing from host config"
[ -n "$CFG_HOME_DIR" ] || emit_err config "HOME_DIR missing from host config"
[ -n "$CFG_PATH" ] || emit_err config "PATH missing from host config"
[ -n "$CFG_FLEET_ROOT" ] || emit_err config "FLEET_ROOT missing from host config"
[ -n "$CFG_PROJECTS" ] || CFG_PROJECTS="$CFG_FM_HOME/projects"
[ -n "$CFG_LANG" ] || CFG_LANG=en_US.UTF-8

export HOME=$CFG_HOME_DIR
export PATH=$CFG_PATH
export LANG=$CFG_LANG
export LC_ALL=$CFG_LANG
export FM_HOME=$CFG_FM_HOME
FLEET_ROOT=$CFG_FLEET_ROOT
TASKS="$control_root/tasks"
BIN="$CFG_FM_ROOT/bin"
STATE="$CFG_FM_HOME/state"
DATA="$CFG_FM_HOME/data"

# A GUI task host pins the session provider to the DESKTOP host session's socket
# rather than letting bin/fm-tmux-lib.sh resolve one from an environment this
# verb does not have. Without that pin, fm-spawn would find no server and create
# its own - as a descendant of the launchd-managed bifrost daemon, which is the
# one ancestry that wedges an agent forever (control-root/fmr-gui-lib.sh).
[ -z "$CFG_TMUX_SOCKET" ] || export FM_TMUX_SOCKET=$CFG_TMUX_SOCKET

# ---- GUI host preflight ------------------------------------------------------
# Sourced only when the host declares GUI=1, so a non-GUI task host neither needs
# control-root/fmr-gui-lib.sh nor changes behaviour when it is absent.
gui_required() { [ "$CFG_GUI" = 1 ]; }

gui_lib_load() {
  local lib="$control_root/fmr-gui-lib.sh"
  [ -f "$lib" ] || emit_err guilib "GUI=1 but $lib is not deployed on this host"
  # shellcheck source=control-root/fmr-gui-lib.sh
  . "$lib"
}

# The three answers a GUI host owes BEFORE it claims anything: awake, unlocked,
# and a live desktop host session.
#
# Sets GUI_REFUSAL to "<code> <sentence>" when this machine must not take work,
# and to the empty string when it may. It assigns a global rather than printing
# into a command substitution on purpose: gui_lib_load fails through emit_err,
# and inside a subshell that exit would be swallowed and its ERR line would be
# captured as if it were the refusal text.
#
# Awake needs no probe and gets none: a machine that is asleep does not run this
# verb, so reaching this line IS the awake answer. What the design asks for is
# that a sleeping host produce a readable refusal, and that belongs on the
# control side, which is the only side still running (bin/fm-relay-lib.sh).
GUI_REFUSAL=
GUI_STATE=
gui_preflight() {
  local marker='' verdict socket
  GUI_REFUSAL=; GUI_STATE=
  gui_lib_load
  case "$(fmr_gui_lock_verdict "$(fmr_gui_ioreg_text)")" in
    locked)
      GUI_REFUSAL='guilocked the screen is locked, so a dispatched agent would start work nobody can see or unblock'
      return 0 ;;
    unknown)
      GUI_REFUSAL='guilockunknown the screen lock state could not be read, so this host will not claim work'
      return 0 ;;
  esac
  [ -n "$CFG_HOST_SESSION" ] || CFG_HOST_SESSION="$control_root/host-session"
  if [ -f "$CFG_HOST_SESSION" ]; then
    marker=$(cat "$CFG_HOST_SESSION" 2>/dev/null || true)
  fi
  socket=${CFG_TMUX_SOCKET:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default}
  verdict=$(fmr_gui_session_verdict "$marker" \
    "$(fmr_gui_socket_server_pid "$socket")" "$(fmr_gui_console_asid)")
  case "$verdict" in
    ok\ *) GUI_STATE=${verdict#ok } ;;
    *)
      # The operator has to know WHAT to start, not only that something is wrong.
      GUI_REFUSAL="guisession ${verdict#* }; start it on this machine with $control_root/fmr-host-session.sh start"
      ;;
  esac
}

# ---- argument validation -----------------------------------------------------
id_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; case "$1" in .*) return 1 ;; esac; }
ref_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; case "$1" in .*) return 1 ;; esac; }
num_ok() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
hex_ok() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }

require_id() { id_ok "${1-}" || emit_err badarg "invalid task id"; }

file_size() {  # <file>
  local n
  n=$(wc -c < "$1" 2>/dev/null) || return 1
  printf '%s' "${n// /}"
}

sha256_of() {  # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  else
    return 1
  fi
}

# Crew-authored status text becomes a wake REASON on the control machine, so it
# is sanitized here at the boundary: control characters removed, each line capped,
# and the batch capped. A crewmate cannot inject newlines or escapes into the
# supervisor's queue records.
sanitize_events() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | cut -c1-200 \
    | head -n "${FMR_EVENT_LINES:-40}"
}

# A blind re-dispatch must get more than a refusal: it must get enough to decide
# whether the existing task is alive. This is the host's own answer about its own
# processes, which is the only place that question can be answered honestly.
claim_report() {  # <id>
  local tid=$1
  local meta="$STATE/$tid.meta"
  if [ -f "$TASKS/$tid/claim" ]; then
    sed 's/^/claim /' "$TASKS/$tid/claim"
  fi
  if [ -f "$meta" ]; then
    printf 'meta window=%s worktree=%s kind=%s\n' \
      "$(grep '^window=' "$meta" | cut -d= -f2- | head -1)" \
      "$(grep '^worktree=' "$meta" | cut -d= -f2- | head -1)" \
      "$(grep '^kind=' "$meta" | cut -d= -f2- | head -1)"
    printf 'state %s\n' "$("$BIN/fm-crew-state.sh" "$tid" 2>&1 | head -1)"
  else
    printf 'meta absent\n'
  fi
}

# First launch in a fresh worktree can stall on a harness directory-trust
# confirmation, and the .agents/skills/harness-adapters contract is to accept it
# with Enter after peeking the pane. Doing that HERE costs zero relay
# round-trips, which is the whole reason the verb owns it.
#
# The patterns are the dialog QUESTION text only, deliberately. An earlier
# version also matched "bypass permissions", which is claude's PERMANENT footer
# ("bypass permissions on (shift+tab to cycle)"), so every healthy launch looked
# like an unanswered dialog and got a stray Enter. A mode indicator is not a
# question; only question text may trigger a keystroke.
trust_dialog_showing() {  # <pane-text>
  case "$1" in
    *"Do you trust the files"*|*"Do you trust the contents"*|*"trust the contents of this directory"*) return 0 ;;
    *"Yes, I trust"*|*"Yes, proceed"*|*"Yes, I accept"*) return 0 ;;
  esac
  return 1
}

settle_trust_dialog() {  # <id>
  local tid=$1 pane
  for _ in 1 2 3 4 5 6; do
    sleep 3
    pane=$("$BIN/fm-peek.sh" "$tid" 40 2>/dev/null) || continue
    if trust_dialog_showing "$pane"; then
      "$BIN/fm-send.sh" "$tid" --key Enter >/dev/null 2>&1
      sleep 3
      pane=$("$BIN/fm-peek.sh" "$tid" 40 2>/dev/null) || true
      if trust_dialog_showing "$pane"; then
        printf 'still-showing'
      else
        printf 'accepted'
      fi
      return 0
    fi
    # A busy harness has already taken the brief; nothing is waiting on a key.
    case "$pane" in
      *'esc to interrupt'*|*'✻'*|*'✽'*|*'✢'*|*'✳'*|*'✶'*) printf 'working'; return 0 ;;
    esac
  done
  printf 'none'
}

# ---- verbs -------------------------------------------------------------------
verb=${1-}
[ -n "$verb" ] || emit_err badarg "no verb"
shift || true

case "$verb" in

  ping)
    printf 'OK pong host=%s proto=fmr-v1 home=%s gui=%s\n' \
      "$(hostname)" "$CFG_FM_HOME" "${CFG_GUI:-0}"
    ;;

  preflight)
    # "Can you take work right now" asked on its own, so the control side can
    # give a readable reason without staging a brief or attempting a claim. This
    # is a courtesy, never the gate: the authoritative check is the one spawn
    # runs in the same process as its claim, below.
    if ! gui_required; then
      printf 'OK preflight=ok gui=0\n'
      exit 0
    fi
    gui_preflight
    if [ -n "$GUI_REFUSAL" ]; then
      emit_err "${GUI_REFUSAL%% *}" "${GUI_REFUSAL#* }"
    fi
    printf 'OK preflight=ok gui=1 awake=yes locked=no session=ok\n'
    printf '%s\n' "$GUI_STATE"
    ;;

  task-list)
    printf 'OK\n'
    [ -d "$TASKS" ] || exit 0
    for d in "$TASKS"/*; do
      [ -d "$d" ] || continue
      tid=${d##*/}
      meta="$STATE/$tid.meta"
      if [ -f "$meta" ]; then
        printf '%s kind=%s window=%s\n' "$tid" \
          "$(grep '^kind=' "$meta" | cut -d= -f2- | head -1)" \
          "$(grep '^window=' "$meta" | cut -d= -f2- | head -1)"
      else
        printf '%s kind=? window=?\n' "$tid"
      fi
    done
    ;;

  claim-status)
    require_id "${1-}"
    tid=$1
    if [ -d "$TASKS/$tid" ]; then
      printf 'OK claimed=1\n'
      claim_report "$tid"
    else
      printf 'OK claimed=0\n'
    fi
    ;;

  spawn)
    # spawn <id> <kind> <project> <briefref> [<harness> <model> <effort>]
    require_id "${1-}"
    tid=$1; kind=${2-}; project=${3-}; briefref=${4-}
    harness=${5-default}; model=${6-default}; effort=${7-default}
    case "$kind" in ship|scout) ;; *) emit_err badarg "kind must be ship or scout" ;; esac
    ref_ok "$project" || emit_err badarg "invalid project name"
    ref_ok "$briefref" || emit_err badarg "invalid brief reference"
    proj_dir="$CFG_PROJECTS/$project"
    [ -d "$proj_dir" ] || emit_err noproject "no project directory at $proj_dir"
    brief_src="$FLEET_ROOT/tasks/$tid/in/$briefref"
    [ -f "$brief_src" ] || emit_err nobrief "no staged brief at tasks/$tid/in/$briefref"
    # BEFORE the claim, and in the same process as it. A claim tells the control
    # machine this work has an owner; claiming and then failing is worse than
    # refusing, because it stops the control side looking for anywhere else to
    # run it. Asking here rather than only through the `preflight` verb is also
    # what leaves no window between the answer and the claim.
    if gui_required; then
      gui_preflight
      [ -z "$GUI_REFUSAL" ] || emit_err "${GUI_REFUSAL%% *}" "${GUI_REFUSAL#* }"
    fi
    mkdir -p "$TASKS" || emit_err io "cannot create claim root"
    if ! mkdir "$TASKS/$tid" 2>/dev/null; then
      printf 'ALREADY_CLAIMED task %s is already claimed on this host\n' "$tid"
      claim_report "$tid"
      exit 0
    fi
    printf 'claimed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TASKS/$tid/claim"
    mkdir -p "$DATA/$tid" || emit_err io "cannot create data dir"
    cp "$brief_src" "$DATA/$tid/brief.md" || emit_err io "cannot install brief"
    spawn_args=("$tid" "$proj_dir")
    [ "$kind" = scout ] && spawn_args+=(--scout)
    [ "$harness" = default ] || spawn_args+=(--harness "$harness")
    [ "$model" = default ] || spawn_args+=(--model "$model")
    [ "$effort" = default ] || spawn_args+=(--effort "$effort")
    spawn_log="$TASKS/$tid/spawn.log"
    if ! "$BIN/fm-spawn.sh" "${spawn_args[@]}" > "$spawn_log" 2>&1; then
      # Read the log BEFORE releasing the claim. The log lives INSIDE the claim
      # directory, so removing the claim first destroyed the only diagnostic and
      # every spawn failure reported an empty reason - the control side was told
      # "it failed" and never told why.
      spawn_detail=$(tail -n 20 "$spawn_log" 2>/dev/null)
      rm -rf "${TASKS:?}/$tid"
      printf 'ERR spawnfailed fm-spawn.sh refused or failed on the host\n'
      printf '%s\n' "$spawn_detail" | sanitize_events
      exit 1
    fi
    trust_note=$(settle_trust_dialog "$tid")
    printf 'OK spawned=%s trust=%s\n' "$tid" "$trust_note"
    if [ -f "$STATE/$tid.meta" ]; then
      cat "$STATE/$tid.meta"
    fi
    ;;

  send)
    require_id "${1-}"
    tid=$1; ref=${2-}
    ref_ok "$ref" || emit_err badarg "invalid steer reference"
    src="$FLEET_ROOT/tasks/$tid/in/$ref"
    [ -f "$src" ] || emit_err nosteer "no staged steer at tasks/$tid/in/$ref"
    text=$(head -c 8192 "$src" | head -n 1)
    [ -n "$text" ] || emit_err nosteer "staged steer is empty"
    if out=$("$BIN/fm-send.sh" "$tid" "$text" 2>&1); then
      printf 'OK sent=%s\n' "$tid"
      printf '%s\n' "$out" | sanitize_events
    else
      printf 'ERR sendfailed fm-send.sh reported the steer did not land\n'
      printf '%s\n' "$out" | sanitize_events
      exit 1
    fi
    ;;

  key)
    require_id "${1-}"
    tid=$1; keyname=${2-}
    case "$keyname" in Enter|Escape|C-c) ;; *) emit_err badarg "unsupported key" ;; esac
    if out=$("$BIN/fm-send.sh" "$tid" --key "$keyname" 2>&1); then
      printf 'OK key=%s\n' "$keyname"
    else
      printf 'ERR keyfailed %s\n' "$keyname"
      printf '%s\n' "$out" | sanitize_events
      exit 1
    fi
    ;;

  crew-state)
    require_id "${1-}"
    tid=$1
    # The first token is the protocol, so a failed read has to say ERR. Printing
    # OK unconditionally made the control side treat "no such task" and a broken
    # backend as a successful state read whose text it would then have to guess at.
    if out=$("$BIN/fm-crew-state.sh" "$tid" 2>&1); then
      printf 'OK\n'
      printf '%s\n' "$out" | sanitize_events
    else
      printf 'ERR statefailed fm-crew-state.sh could not read the state of %s\n' "$tid"
      printf '%s\n' "$out" | sanitize_events
      exit 1
    fi
    ;;

  peek)
    require_id "${1-}"
    tid=$1; n=${2-40}
    num_ok "$n" || emit_err badarg "invalid line count"
    [ "$n" -gt 200 ] && n=200
    printf 'OK lines=%s\n' "$n"
    FMR_EVENT_LINES=$n "$BIN/fm-peek.sh" "$tid" "$n" 2>&1 | FMR_EVENT_LINES=$n sanitize_events
    ;;

  events)
    require_id "${1-}"
    tid=$1; off=${2-0}
    num_ok "$off" || emit_err badarg "invalid offset"
    log="$STATE/$tid.status"
    if [ ! -f "$log" ]; then
      printf 'OK offset=0 new=0\n'
      exit 0
    fi
    size=$(file_size "$log") || emit_err io "cannot size the status log"
    if [ "$off" -ge "$size" ]; then
      printf 'OK offset=%s new=0\n' "$size"
      exit 0
    fi
    printf 'OK offset=%s new=%s\n' "$size" "$((size - off))"
    tail -c "+$((off + 1))" "$log" | sanitize_events
    ;;

  ack)
    require_id "${1-}"
    tid=$1; off=${2-}
    num_ok "$off" || emit_err badarg "invalid offset"
    [ -d "$TASKS/$tid" ] || emit_err noclaim "task $tid is not claimed on this host"
    printf '%s\n' "$off" > "$TASKS/$tid/ack" || emit_err io "cannot record ack"
    printf 'OK ack=%s\n' "$off"
    ;;

  report-stage)
    require_id "${1-}"
    tid=$1
    report="$DATA/$tid/report.md"
    [ -f "$report" ] || emit_err noreport "no report at data/$tid/report.md on this host"
    mkdir -p "$FLEET_ROOT/tasks/$tid/out" || emit_err io "cannot create exchange out dir"
    cp "$report" "$FLEET_ROOT/tasks/$tid/out/report.md" || emit_err io "cannot stage report"
    h=$(sha256_of "$report") || emit_err io "cannot hash report"
    printf '%s\n' "$h" > "$TASKS/$tid/report.sha256"
    printf 'OK sha256=%s bytes=%s\n' "$h" "$(file_size "$report")"
    ;;

  teardown)
    # teardown <id> <sha256-of-the-copy-the-control-side-holds>
    require_id "${1-}"
    tid=$1; want=${2-}
    meta="$STATE/$tid.meta"
    [ -f "$meta" ] || emit_err nometa "no metadata for task $tid on this host"
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- | head -1)
    [ -n "$kind" ] || kind=ship
    if [ "$kind" = scout ]; then
      # The extra gate the design requires: a remote scout's worktree is scratch,
      # so nothing may discard it until the control machine provably holds an
      # identical copy of the only deliverable.
      report="$DATA/$tid/report.md"
      [ -f "$report" ] || emit_err noreport "scout $tid has no report on this host"
      hex_ok "$want" || emit_err reportgate "teardown needs the sha256 of the control-side report copy"
      have=$(sha256_of "$report") || emit_err io "cannot hash report"
      [ "$want" = "$have" ] || emit_err reportgate "control-side report copy does not match the host report ($want != $have)"
    fi
    if out=$("$BIN/fm-teardown.sh" "$tid" 2>&1); then
      rm -rf "${TASKS:?}/$tid"
      # The exchange area holds this task's brief, its steers, and the staged
      # copy of its report. Once teardown has succeeded the control machine
      # already holds a hash-verified copy of anything worth keeping, so leaving
      # those bytes sitting in the one directory the peer can read is pure
      # residue.
      rm -rf "${FLEET_ROOT:?}/tasks/$tid"
      printf 'OK torndown=%s\n' "$tid"
      printf '%s\n' "$out" | sanitize_events
    else
      printf 'ERR teardownrefused fm-teardown.sh refused or failed on the host\n'
      printf '%s\n' "$out" | sanitize_events
      exit 1
    fi
    ;;

  *)
    emit_err badverb "unknown verb"
    ;;
esac
