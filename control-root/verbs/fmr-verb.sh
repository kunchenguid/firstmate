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
#
# EPOCH FENCING. Once this machine has a helm lease at <control-root>/helm/lease,
# every verb that CHANGES state here must arrive as `<verb>@<epoch>` with an
# epoch matching that lease, and answers `ERR EPOCH_STALE ...` without doing
# anything otherwise. It rides on the verb token rather than as an argument of
# its own because the shell policy caps this path at eight arguments and `spawn`
# already uses all eight; see helm_require_epoch below. The
# point is where the check runs: a control machine that has handed the helm away
# is still running and can still send commands, and refusing them HERE does not
# require it to be honest, to have a correct clock, or to know the link is up.
# The lease itself lives under the control root, which the peer cannot write with
# `remote file write` because it sits outside the file roots, so the only way to
# move it is the helm-set verb below and its compare-and-swap.
#
# No lease file means no fencing, which is what keeps a Phase 1/2 task host that
# never joined a fleet byte-identical to what it was before helm existed.
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
# The firstmate scripts this verb drives run as a TASK HOST, not as a control
# plane, so their own helm gate must stand aside: a task host is by definition
# not the holder, and asking it to be would refuse every dispatch. The authority
# question is already settled by the time any of them runs - helm_require_epoch
# below checked the caller's epoch against this machine's own lease, which is a
# stronger answer than "am I the holder" because it cannot be given by the stale
# machine about itself.
export FM_HELM_HOST_EXEC=1
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

# ---- helm lease --------------------------------------------------------------
HELM_DIR="$control_root/helm"
HELM_LEASE="$HELM_DIR/lease"

helm_field() {  # <key>
  [ -f "$HELM_LEASE" ] || return 1
  grep "^$1=" "$HELM_LEASE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

helm_epoch() {
  local e
  e=$(helm_field epoch) || return 1
  case "$e" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$e" ;; esac
}

# The fencing epoch rides on the VERB TOKEN, as `<verb>@<epoch>`, and not as an
# argument of its own. That is forced by the deployed shell policy, which
# allowlists this path plus AT MOST EIGHT arguments:
#
#   ^<path>/fmr-verb\.sh( [A-Za-z0-9._@=+-]{1,96}){0,8}$
#
# `spawn <id> <kind> <project> <briefref> <harness> <model> <effort>` already
# uses all eight. A ninth token would be rejected by the policy layer before
# this script ran - and widening the allowlist is not a small change either:
# a grant snapshots the policy version, so any edit invalidates it and forces a
# re-pair through another full-access window (docs/relay-host.md).
#
# Riding on the verb token costs nothing: `@` is already in the allowed charset,
# and a machine that is in no fleet sends the bare verb exactly as before.
# Split inline rather than through a function that prints. A command
# substitution runs in a SUBSHELL, so a function assigning HELM_GIVEN_EPOCH
# there would lose it on return and every fenced call would arrive looking like
# it carried no epoch - refused, with the caller told to check a lease that was
# perfectly correct.
HELM_GIVEN_EPOCH=

# The fence. Silent and free when this machine has no lease; otherwise the
# caller's epoch must equal this machine's, exactly.
#
# A missing token is refused as loudly as a wrong one. Treating "no epoch" as
# "not fenced" would mean a stale control plane could skip the check simply by
# being older than the code that adds it.
helm_require_epoch() {  # <verb-name>
  local mine
  [ -f "$HELM_LEASE" ] || return 0
  mine=$(helm_epoch)
  if [ -z "$HELM_GIVEN_EPOCH" ]; then
    printf 'ERR EPOCH_STALE %s carries no helm epoch; this machine is at epoch %s (holder %s) and changed nothing\n' \
      "$1" "$mine" "$(helm_field holder)"
    exit 1
  fi
  case "$HELM_GIVEN_EPOCH" in
    ''|*[!0-9]*)
      printf 'ERR EPOCH_STALE %s carried an unreadable helm epoch; this machine changed nothing\n' "$1"
      exit 1 ;;
  esac
  if [ "$HELM_GIVEN_EPOCH" != "$mine" ]; then
    printf 'ERR EPOCH_STALE %s came from helm epoch %s but this machine is at epoch %s (holder %s); nothing was changed\n' \
      "$1" "$HELM_GIVEN_EPOCH" "$mine" "$(helm_field holder)"
    exit 1
  fi
  return 0
}

# ---- verbs -------------------------------------------------------------------
verb_token=${1-}
case "$verb_token" in
  *@*) HELM_GIVEN_EPOCH=${verb_token#*@}; verb=${verb_token%%@*} ;;
  *) verb=$verb_token ;;
esac
[ -n "$verb" ] || emit_err badarg "no verb"
shift || true

# Demand the epoch for exactly the verbs that change something on this machine.
# Read-only verbs stay callable from a demoted control plane on purpose: it must
# still be able to see what is here, it just may not touch it.
case "$verb" in
  spawn|send|key|ack|teardown) helm_require_epoch "$verb" ;;
esac

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
    # THIS MACHINE'S OWN task inventory, which is a wider question than "what
    # did a control machine claim here". A machine that was the control plane
    # spawned its tasks locally and they have no claim directory at all, yet
    # after a handover they are exactly the tasks the new control plane has to
    # pick up. Enumerating state/*.meta is what makes the truth of a task live
    # on the machine running it.
    #
    # Two exclusions, both load-bearing:
    #   - kind=secondmate is a persistent domain agent, never a work item, and
    #     adopting one as a task would put an agent in a backlog.
    #   - a meta carrying host= is this machine's MIRROR of a task running
    #     somewhere else. Listing it would hand a peer its own tasks back and
    #     the two machines would adopt each other's mirrors forever.
    printf 'OK\n'
    [ -d "$STATE" ] || exit 0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      tid=${meta##*/}; tid=${tid%.meta}
      grep -q '^host=' "$meta" && continue
      kind=$(grep '^kind=' "$meta" | cut -d= -f2- | head -1)
      [ "$kind" = secondmate ] && continue
      claimed=0
      [ -d "$TASKS/$tid" ] && claimed=1
      ackv=$(cat "$TASKS/$tid/ack" 2>/dev/null || true)
      case "$ackv" in ''|*[!0-9]*) ackv=0 ;; esac
      printf '%s kind=%s window=%s claimed=%s ack=%s\n' "$tid" \
        "${kind:-?}" \
        "$(grep '^window=' "$meta" | cut -d= -f2- | head -1)" \
        "$claimed" "$ackv"
    done
    ;;

  task-meta)
    # The whole of a task's metadata, so a control machine adopting it records
    # the same fields the dispatching path records rather than a summary it
    # would then have to guess the rest of.
    require_id "${1-}"
    tid=$1
    meta="$STATE/$tid.meta"
    [ -f "$meta" ] || emit_err nometa "no metadata for task $tid on this host"
    grep -q '^host=' "$meta" \
      && emit_err notlocal "task $tid is a mirror of work running elsewhere, not a task on this host"
    printf 'OK id=%s\n' "$tid"
    cat "$meta"
    ;;

  helm-read)
    # Never fenced, and never refused for being demoted: a machine that has lost
    # the helm has to be able to find that out, and the answer is the lease.
    if [ ! -f "$HELM_LEASE" ]; then
      printf 'OK epoch=0 holder=none fleet=none present=0\n'
      exit 0
    fi
    printf 'OK epoch=%s holder=%s fleet=%s present=1\n' \
      "$(helm_epoch)" "$(helm_field holder)" "$(helm_field fleet)"
    cat "$HELM_LEASE"
    ;;

  helm-set)
    # helm-set fleet=<f> expect=<n> next=<n+1> holder=<machine|none> by=<machine> [force=1]
    #
    # `expect=` and `next=` are the compare-and-swap pair; naming the new epoch
    # `next=` rather than `epoch=` keeps it from reading like the fencing token,
    # which is a different thing that travels on the verb token.
    #
    # The compare-and-swap that makes concurrent handovers safe. Both sides read
    # the same epoch, both send the same expect=, and the ANCHOR machine's copy
    # of this verb serializes them: exactly one swap lands, the other is told
    # what it lost to, and the epoch advances by exactly one either way.
    #
    # The lock is a directory because mkdir is the one filesystem operation that
    # is atomic on every filesystem this runs on. It is held for the read and
    # the write together; splitting them is what would let two callers both see
    # the old epoch.
    hs_fleet=; hs_expect=; hs_epoch=; hs_holder=; hs_by=; hs_force=0
    for a in "$@"; do
      case "$a" in
        fleet=*) hs_fleet=${a#fleet=} ;;
        expect=*) hs_expect=${a#expect=} ;;
        next=*) hs_epoch=${a#next=} ;;
        holder=*) hs_holder=${a#holder=} ;;
        by=*) hs_by=${a#by=} ;;
        force=*) hs_force=${a#force=} ;;
        *) emit_err badarg "unknown helm-set field" ;;
      esac
    done
    ref_ok "$hs_fleet" || emit_err badarg "helm-set needs a valid fleet name"
    ref_ok "$hs_by" || emit_err badarg "helm-set needs a valid by= machine name"
    case "$hs_holder" in
      none) ;;
      *) ref_ok "$hs_holder" || emit_err badarg "helm-set needs holder=<machine> or holder=none" ;;
    esac
    num_ok "$hs_expect" || emit_err badarg "helm-set needs a numeric expect="
    num_ok "$hs_epoch" || emit_err badarg "helm-set needs a numeric next="
    mkdir -p "$HELM_DIR" || emit_err io "cannot create the helm directory"
    lock="$HELM_DIR/.lock"
    if ! mkdir "$lock" 2>/dev/null; then
      emit_err helmbusy "another helm write is in progress on this machine"
    fi
    # shellcheck disable=SC2064  # $lock is fixed at trap time on purpose
    trap "rmdir '$lock' 2>/dev/null || true" EXIT
    cur_epoch=0; cur_holder=none; cur_fleet=$hs_fleet
    if [ -f "$HELM_LEASE" ]; then
      cur_epoch=$(helm_epoch)
      cur_holder=$(helm_field holder)
      cur_fleet=$(helm_field fleet)
      [ -n "$cur_holder" ] || cur_holder=none
    fi
    if [ "$cur_fleet" != "$hs_fleet" ]; then
      printf 'ERR helmfleet this machine carries the lease of fleet %s, not %s; nothing was changed\n' \
        "$cur_fleet" "$hs_fleet"
      exit 1
    fi
    if [ "$hs_force" != 1 ] && [ "$hs_expect" != "$cur_epoch" ]; then
      printf 'ERR helmstale expected epoch %s but this machine is at epoch %s (holder %s); nothing was changed\n' \
        "$hs_expect" "$cur_epoch" "$cur_holder"
      exit 1
    fi
    # Monotonic in both directions, forced or not. An epoch that could stand
    # still or go backwards is not a fencing token any more, and every refusal
    # above rests on it only ever moving forward.
    if [ "$hs_epoch" -le "$cur_epoch" ]; then
      printf 'ERR helmepoch epoch %s does not advance past this machine current epoch %s; nothing was changed\n' \
        "$hs_epoch" "$cur_epoch"
      exit 1
    fi
    tmp="$HELM_LEASE.tmp$$"
    {
      printf 'helm-v1\n'
      printf 'fleet=%s\n' "$hs_fleet"
      printf 'epoch=%s\n' "$hs_epoch"
      printf 'holder=%s\n' "$hs_holder"
      printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'by=%s\n' "$hs_by"
      printf 'forced=%s\n' "$hs_force"
    } > "$tmp" || emit_err io "cannot stage the lease"
    mv -f "$tmp" "$HELM_LEASE" || emit_err io "cannot install the lease"
    printf 'OK epoch=%s holder=%s previous_epoch=%s previous_holder=%s\n' \
      "$hs_epoch" "$hs_holder" "$cur_epoch" "$cur_holder"
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
    # A claim directory is no longer required, only a task. After a helm
    # handover the new control plane acknowledges events for tasks this machine
    # STARTED ITSELF while it was the control plane, and those never had a
    # claim - demanding one would leave exactly the adopted tasks unable to
    # record what has been presented, which is how events get replayed forever
    # or silently skipped.
    [ -f "$STATE/$tid.meta" ] || [ -d "$TASKS/$tid" ] \
      || emit_err notask "no task $tid on this host"
    mkdir -p "$TASKS/$tid" || emit_err io "cannot create the task record"
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
