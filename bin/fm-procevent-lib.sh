# shellcheck shell=bash
# Shared identity, ownership, capture, and publication rules for the generic
# process-to-event runner.
# Usage: . bin/fm-procevent-lib.sh   (requires fm-pr-lib.sh and fm-wake-lib.sh)
#
# The runner lets firstmate learn that a registered long-polling source produced
# a result without holding that blocking process in its conversational turn. It
# is domain-neutral: a thin adapter supplies source identity, the argv to run,
# and how to classify a completed result. Everything else - ownership, durable
# capture, publication, and restart recovery - lives here.
#
# It adds no second notification control plane: a completed result is published
# as an ordinary `check` wake through the existing durable wake queue, which is
# the same mechanism merge polls and X mode already use.
#
# DURABILITY BOUNDARY, stated precisely. This runner proves exactly one thing:
# once a child process has exited and its output has been read, that output is
# stored atomically at mode 0600 BEFORE any event referencing it is published,
# and a captured result with no durable handled acknowledgement remains eligible
# for bounded re-announcement - including across a restart between publication
# and handling - until `fm-procevent.sh handled` records it. It proves nothing
# about the source side of the handoff. In particular the currently published
# `lavish-axi poll` destructively clears feedback before returning it, so a
# result lost between that clearing and this runner reading the process output
# is unrecoverable. A Firstmate wrapper cannot close that window, and marking a
# result handled says nothing about whether a paired external effect performed
# before that call actually completed: a crash between the effect and the
# acknowledgement can still repeat the effect on replay. Never describe this
# runner as at-least-once, no-loss, or lossless, and never claim generic
# exactly-once effects from the handled acknowledgement alone.

# Machine-wide claim root. Homes can share one underlying source store, so the
# "one owner per canonical source" rule cannot live inside a single home.
fm_procevent_claim_root() {
  printf '%s\n' "${FM_PROCEVENT_CLAIM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/procevent-claims}"
}

fm_procevent_registry_dir() { printf '%s\n' "$1/procevent"; }
fm_procevent_inbox_dir()    { printf '%s\n' "$1/procevent-inbox"; }

# A source id names a private file and a bounded wake slug, so it is held to the
# same path-safe shape as a task id. Adapters derive it from canonical source
# identity, never from a caller-supplied display string.
fm_procevent_source_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id" || return 1
  [ "${#id}" -le 64 ]
}

fm_procevent_adapter_valid() {
  local a=${1-}
  case "$a" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#a}" -le 32 ]
}

# fm_procevent_any_registered <state>
fm_procevent_any_registered() {
  local reg rec
  reg=$(fm_procevent_registry_dir "$1")
  [ -d "$reg" ] || return 1
  for rec in "$reg"/*.source; do
    [ -e "$rec" ] || continue
    return 0
  done
  return 1
}

# --- ownership --------------------------------------------------------------
# A claim is a private file recording the home, runner pid, claim generation,
# and process identity. Registration and every ownership transition are
# serialized at one source boundary.

fm_procevent_claim_path() {
  printf '%s/%s.claim\n' "$(fm_procevent_claim_root)" "$1"
}

fm_procevent_source_lock_path() {
  printf '%s/%s.lock\n' "$(fm_procevent_claim_root)" "$1"
}

fm_procevent_source_lock_acquire() {
  local id=$1 root
  fm_procevent_source_id_valid "$id" || return 1
  root=$(fm_procevent_claim_root)
  (umask 077; mkdir -p "$root") || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  fm_lock_acquire_wait "$(fm_procevent_source_lock_path "$id")"
}

fm_procevent_source_lock_release() {
  fm_lock_release "$(fm_procevent_source_lock_path "$1")"
}

fm_procevent_registration_publish_locked() {  # <state> <adapter> <source-id> <argv...>
  local state=$1 adapter=$2 id=$3 reg dest tmp arg
  shift 3
  fm_procevent_adapter_valid "$adapter" || return 1
  fm_procevent_source_id_valid "$id" || return 1
  [ "$#" -ge 1 ] || return 1
  for arg in "$@"; do
    case "$arg" in *$'\n'*) return 1 ;; esac
  done
  reg=$(fm_procevent_registry_dir "$state")
  (umask 077; mkdir -p "$reg") || return 1
  [ -d "$reg" ] && [ ! -L "$reg" ] || return 1
  dest="$reg/$id.source"
  tmp=$(umask 077; mktemp "$reg/.source.XXXXXX") || return 1
  if {
    printf 'adapter=%s\n' "$adapter"
    printf 'argc=%s\n' "$#"
    printf 'argv:\n'
    printf '%s\n' "$@"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

fm_procevent_claim_load_locked() {  # <source-id>
  local claim home pid token identity reg_dir reg_identity terminal extra
  claim=$(fm_procevent_claim_path "$1")
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  {
    IFS= read -r home \
      && IFS= read -r pid \
      && IFS= read -r token \
      && IFS= read -r identity \
      && { IFS= read -r reg_dir || reg_dir=; } \
      && { IFS= read -r reg_identity || reg_identity=; } \
      && { IFS= read -r terminal || terminal=active; } \
      && ! IFS= read -r extra
  } < "$claim" || return 1
  [ -n "$home" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$identity" ] || return 1
  case "$reg_dir" in ''|/*) ;; *) return 1 ;; esac
  case "$reg_identity" in ''|*:* ) ;; *) return 1 ;; esac
  case "$terminal" in active|terminal) ;; *) return 1 ;; esac
  FM_PROCEVENT_CLAIM_HOME=$home
  FM_PROCEVENT_CLAIM_PID=$pid
  FM_PROCEVENT_CLAIM_TOKEN=$token
  FM_PROCEVENT_CLAIM_IDENTITY=$identity
  FM_PROCEVENT_CLAIM_REG_DIR=$reg_dir
  FM_PROCEVENT_CLAIM_REG_IDENTITY=$reg_identity
  FM_PROCEVENT_CLAIM_TERMINAL=$terminal
}

# fm_procevent_group_alive <pid>
# True while any process remains in the process group a runner leads. A runner
# started by reconcile is its own group leader, so this is what distinguishes a
# generation that is really gone from one whose leader died while its blocking
# source child kept running.
fm_procevent_group_alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 -"$1" 2>/dev/null
}

# fm_procevent_pid_state <pid> <identity>
# 0 live match, 1 stale, 2 uncertain, 3 orphaned group.
#
# State 3 is the crash cut: the runner leader is gone, but its owned process
# group still has members, so the old generation can still be consuming the
# source. Treating that as stale would release ownership and let a second
# poller start against one canonical source. Only the leader being absent
# reaches state 3, which is also what makes signalling that group safe: if this
# pid had been reused by an unrelated process the leader would be alive, so the
# identity comparison below would classify it stale or uncertain and no group
# signal would ever follow.
fm_procevent_pid_state() {
  local pid=$1 expected=$2 actual
  if ! fm_pid_alive "$pid"; then
    fm_procevent_group_alive "$pid" && return 3
    return 1
  fi
  if actual=$(fm_pid_identity "$pid" 2>/dev/null); then
    [ "$actual" = "$expected" ] && return 0
    return 1
  fi
  fm_pid_alive "$pid" || { fm_procevent_group_alive "$pid" && return 3; return 1; }
  return 2
}

# <source-id>: 0 live, 1 stale/absent, 2 uncertain, 3 leader gone with its owned
# process group still alive, 4 terminal retirement pending.
fm_procevent_claim_state_locked() {
  local claim registration current_identity
  claim=$(fm_procevent_claim_path "$1")
  [ -e "$claim" ] || return 1
  fm_procevent_claim_load_locked "$1" || return 2
  if [ "$FM_PROCEVENT_CLAIM_TERMINAL" = terminal ] && [ -n "$FM_PROCEVENT_CLAIM_REG_IDENTITY" ]; then
    registration="$FM_PROCEVENT_CLAIM_REG_DIR/$1.source"
    current_identity=$(fm_pr_file_identity "$registration" 2>/dev/null || true)
    [ "$current_identity" = "$FM_PROCEVENT_CLAIM_REG_IDENTITY" ] && return 4
  fi
  fm_procevent_pid_state "$FM_PROCEVENT_CLAIM_PID" "$FM_PROCEVENT_CLAIM_IDENTITY"
}

# fm_procevent_claim_acquire_locked <source-id> <home> <pid> <registration>
# 0 acquired, 1 error, 2 held by a live owner (possibly another home).
fm_procevent_claim_acquire_locked() {
  local id=$1 home=$2 pid=$3 registration=$4 root claim tmp identity token status claim_state old_home old_token old_reg_dir reg_dir reg_identity stage
  fm_procevent_source_id_valid "$id" || return 1
  [ -f "$registration" ] && [ ! -L "$registration" ] || return 1
  reg_dir=${registration%/*}
  case "$reg_dir" in /*) ;; *) return 1 ;; esac
  reg_identity=$(fm_pr_file_identity "$registration" 2>/dev/null) || return 1
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  root=$(fm_procevent_claim_root)
  claim=$(fm_procevent_claim_path "$id")
  status=0
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    fm_procevent_claim_state_locked "$id"
    claim_state=$?
    case "$claim_state" in
      0|2|3|4) status=2 ;;
      1)
        if [ -f "$claim" ] && [ ! -L "$claim" ]; then
          old_home=$FM_PROCEVENT_CLAIM_HOME
          old_token=$FM_PROCEVENT_CLAIM_TOKEN
          old_reg_dir=$FM_PROCEVENT_CLAIM_REG_DIR
          if [ -z "$old_reg_dir" ]; then
            if [ "$old_home" = "$home" ]; then
              old_reg_dir=$reg_dir
            else
              old_reg_dir="$old_home/state/procevent"
            fi
          fi
          if [ -L "$old_reg_dir" ] || { [ -e "$old_reg_dir" ] && [ ! -d "$old_reg_dir" ]; }; then
            status=1
          else
            stage="$old_reg_dir/.$id.$old_token.output"
            if { [ -e "$stage" ] || [ -L "$stage" ]; } && ! rm -f -- "$stage"; then
              status=1
            fi
          fi
          [ "$status" -ne 0 ] || rm -f -- "$claim" || status=1
        else
          status=1
        fi
        ;;
      *) status=1 ;;
    esac
    if [ "$status" -eq 0 ] && { [ ! -f "$registration" ] || [ -L "$registration" ]; }; then
      status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    tmp=$(umask 077; mktemp "$root/.claim.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    token=${tmp##*/}-$pid
    printf '%s\n%s\n%s\n%s\n%s\n%s\nactive\n' \
      "$home" "$pid" "$token" "$identity" "$reg_dir" "$reg_identity" > "$tmp" || status=1
    [ "$status" -ne 0 ] || chmod 0600 "$tmp" || status=1
    [ "$status" -ne 0 ] || mv -f -- "$tmp" "$claim" || status=1
    if [ "$status" -eq 0 ]; then
      FM_PROCEVENT_CLAIM_TOKEN=$token
      FM_PROCEVENT_CLAIM_REG_IDENTITY=$reg_identity
    else
      rm -f -- "$tmp"
    fi
  fi
  return "$status"
}

fm_procevent_claim_mark_terminal_locked() {
  local id=$1 home=$2 pid=$3 token=$4 claim root tmp
  claim=$(fm_procevent_claim_path "$id")
  fm_procevent_claim_load_locked "$id" \
    && [ "$FM_PROCEVENT_CLAIM_HOME" = "$home" ] \
    && [ "$FM_PROCEVENT_CLAIM_PID" = "$pid" ] \
    && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$token" ] \
    && [ -n "$FM_PROCEVENT_CLAIM_REG_IDENTITY" ] || return 1
  root=$(fm_procevent_claim_root)
  tmp=$(umask 077; mktemp "$root/.claim.XXXXXX") || return 1
  if printf '%s\n%s\n%s\n%s\n%s\n%s\nterminal\n' \
    "$FM_PROCEVENT_CLAIM_HOME" "$FM_PROCEVENT_CLAIM_PID" "$FM_PROCEVENT_CLAIM_TOKEN" \
    "$FM_PROCEVENT_CLAIM_IDENTITY" "$FM_PROCEVENT_CLAIM_REG_DIR" \
    "$FM_PROCEVENT_CLAIM_REG_IDENTITY" > "$tmp" \
    && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$claim"; then
    return 0
  else
    rm -f -- "$tmp"
    return 1
  fi
}

# fm_procevent_claim_release_locked <source-id> <home> <pid> <token>
fm_procevent_claim_release_locked() {
  local id=$1 home=$2 pid=$3 token=$4 claim
  fm_procevent_source_id_valid "$id" || return 1
  claim=$(fm_procevent_claim_path "$id")
  [ -e "$claim" ] || return 0
  if fm_procevent_claim_load_locked "$id" \
    && [ "$FM_PROCEVENT_CLAIM_HOME" = "$home" ] \
    && [ "$FM_PROCEVENT_CLAIM_PID" = "$pid" ] \
    && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$token" ]; then
    rm -f -- "$claim"
    return $?
  fi
  return 1
}

# --- durable capture and publication ----------------------------------------

# fm_procevent_capture <state> <source-id> <adapter> <output-file>
# Atomically store the completed output at 0600 and print its durable path. The
# rename is the commit point; nothing referencing this result may be published
# before it returns successfully.
fm_procevent_capture() {
  local state=$1 id=$2 adapter=$3 src=$4 inbox seq dest tmp adapter_dest adapter_tmp
  fm_procevent_source_id_valid "$id" || return 1
  fm_procevent_adapter_valid "$adapter" || return 1
  inbox=$(fm_procevent_inbox_dir "$state")
  (umask 077; mkdir -p "$inbox") || return 1
  seq=1
  while [ -e "$inbox/$id.$seq.result" ]; do seq=$((seq + 1)); done
  dest="$inbox/$id.$seq.result"
  adapter_dest="$inbox/$id.$seq.adapter"
  tmp=$(umask 077; mktemp "$inbox/.capture.XXXXXX") || return 1
  adapter_tmp=$(umask 077; mktemp "$inbox/.adapter.XXXXXX") || { rm -f -- "$tmp"; return 1; }
  if ! cat "$src" > "$tmp"; then rm -f -- "$tmp" "$adapter_tmp"; return 1; fi
  if ! printf '%s\n' "$adapter" > "$adapter_tmp"; then rm -f -- "$tmp" "$adapter_tmp"; return 1; fi
  if ! chmod 0600 "$tmp" "$adapter_tmp"; then rm -f -- "$tmp" "$adapter_tmp"; return 1; fi
  if ! mv -f -- "$adapter_tmp" "$adapter_dest"; then rm -f -- "$tmp" "$adapter_tmp"; return 1; fi
  if ! mv -f -- "$tmp" "$dest"; then rm -f -- "$tmp" "$adapter_dest"; return 1; fi
  printf '%s\n' "$dest"
}

# fm_procevent_pending <state>
# Print every durably captured result that has no durable handled
# acknowledgement yet, oldest first. A result stays here - and so remains
# eligible for repeat publication on the existing durable wake queue - across
# any number of restarts and drains until `fm_procevent_mark_handled` records
# it; this is what makes a restart between publication and handling recover
# instead of silently losing the result.
fm_procevent_pending() {
  local state=$1 inbox result base seq
  inbox=$(fm_procevent_inbox_dir "$state")
  [ -d "$inbox" ] || return 0
  for result in "$inbox"/*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    [ -e "${result%.result}.handled" ] && continue
    base=${result%.result}
    seq=${base##*.}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    printf '%s\t%s\n' "$seq" "$result"
  done | sort -n -k1,1 -k2,2 | cut -f2-
}

# fm_procevent_event_line <adapter> <source-id> <sequence>
# The complete normalized event. Bounded by construction: a fixed verb, a
# validated adapter name, and a validated id. No source output, path, or
# caller-supplied text can appear here.
fm_procevent_event_line() {
  local adapter=$1 id=$2 seq=$3
  fm_procevent_adapter_valid "$adapter" || return 1
  fm_procevent_source_id_valid "$id" || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  printf 'procevent %s %s %s\n' "$adapter" "$id" "$seq"
}

# fm_procevent_handled_marker <state> <source-id> <sequence>
fm_procevent_handled_marker() {
  printf '%s/%s.%s.handled\n' "$(fm_procevent_inbox_dir "$1")" "$2" "$3"
}

# fm_procevent_is_handled <state> <source-id> <sequence>
fm_procevent_is_handled() {
  local marker; marker=$(fm_procevent_handled_marker "$1" "$2" "$3")
  [ -f "$marker" ] && [ ! -L "$marker" ]
}

# fm_procevent_mark_handled <state> <source-id> <sequence>
# The one durable handled acknowledgement per captured generation: keyed by the
# exact source id and sequence, private at mode 0600, and path-safe through the
# same validation as every other source-id use. Atomically check-and-set - the
# create uses O_EXCL so two concurrent callers can never both win - so a caller
# pairing this with an external effect can trust the return code to authorize
# that effect at most once per generation. This is the only terminal state:
# announcing a result never blocks it from being re-announced, only this does.
# 0 = newly recorded (first-ever handling for this generation, safe to perform
# a paired effect that has not yet run), 1 = already recorded (repeat call; do
# not repeat a paired effect), 2 = error.
fm_procevent_mark_handled() {
  local state=$1 id=$2 seq=$3 inbox result adapter_file marker tmp
  fm_procevent_source_id_valid "$id" || return 2
  case "$seq" in ''|*[!0-9]*) return 2 ;; esac
  inbox=$(fm_procevent_inbox_dir "$state")
  result="$inbox/$id.$seq.result"
  adapter_file="$inbox/$id.$seq.adapter"
  [ -f "$result" ] && [ ! -L "$result" ] || return 2
  [ -f "$adapter_file" ] && [ ! -L "$adapter_file" ] || return 2
  marker=$(fm_procevent_handled_marker "$state" "$id" "$seq")
  [ ! -L "$marker" ] || return 2
  tmp=$(umask 077; mktemp "$inbox/.handled.XXXXXX") || return 2
  if ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 2
  fi
  if ln "$tmp" "$marker" 2>/dev/null; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  [ -f "$marker" ] && [ ! -L "$marker" ] && return 1
  return 2
}

# fm_procevent_result_source_id <result-path>
fm_procevent_result_source_id() {
  local base=${1##*/}
  base=${base%.result}
  printf '%s\n' "${base%.*}"
}

fm_procevent_result_sequence() {
  local base=${1##*/}
  base=${base%.result}
  printf '%s\n' "${base##*.}"
}

fm_procevent_result_adapter() {
  local result=$1 adapter_file="${1%.result}.adapter" adapter extra
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  [ -f "$adapter_file" ] && [ ! -L "$adapter_file" ] || return 1
  {
    IFS= read -r adapter \
      && ! IFS= read -r extra
  } < "$adapter_file" || return 1
  [ -z "$extra" ] || return 1
  fm_procevent_adapter_valid "$adapter" || return 1
  printf '%s\n' "$adapter"
}
