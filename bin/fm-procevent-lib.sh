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
fm_procevent_capture_reservation_dir() { printf '%s\n' "$1/procevent-capture-reservations"; }

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

fm_procevent_extension_id_valid() {
  local id=${1-}
  case "$id" in
    ''|[!a-z0-9]*|*[-.]|*[!a-z0-9.-]*|*..*|*.-*|*-.*|*--*) return 1 ;;
  esac
  [ "${#id}" -le 128 ]
}

fm_procevent_extension_version_valid() {
  local version=${1-}
  case "$version" in
    ''|*[!A-Za-z0-9.+-]*) return 1 ;;
  esac
  [ "${#version}" -le 128 ]
}

fm_procevent_digest_valid() {
  local digest=${1-} hex
  case "$digest" in sha256:*) ;; *) return 1 ;; esac
  hex=${digest#sha256:}
  [ "${#hex}" -eq 64 ] || return 1
  case "$hex" in *[!0-9a-f]*) return 1 ;; esac
}

fm_procevent_extension_config_ref_valid() {
  local ref=${1-}
  local LC_ALL=C
  [ -n "$ref" ] && [ "${#ref}" -le 512 ] || return 1
  ! printf '%s' "$ref" | grep -q '[[:cntrl:]]'
}

fm_procevent_extension_registration_token_valid() {
  fm_procevent_digest_valid "${1-}"
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

# Publish one extension-owned registration. Its identity fields and random
# registration token are immutable owner evidence; the executable argv is never
# stored because the tracked host constructs that command at run time.
fm_procevent_extension_registration_publish_locked() {  # <state> <adapter> <source-id> <extension-id> <extension-version> <capability-version> <package-digest> <binding-digest> <config-ref> <registration-token>
  local state=$1 adapter=$2 id=$3 extension_id=$4 extension_version=$5 capability_version=$6
  local package_digest=$7 binding_digest=$8 config_ref=$9 registration_token=${10} reg dest tmp
  fm_procevent_adapter_valid "$adapter" || return 1
  fm_procevent_source_id_valid "$id" || return 1
  fm_procevent_extension_id_valid "$extension_id" || return 1
  fm_procevent_extension_version_valid "$extension_version" || return 1
  [ "$capability_version" = 1 ] || return 1
  fm_procevent_digest_valid "$package_digest" || return 1
  fm_procevent_digest_valid "$binding_digest" || return 1
  fm_procevent_extension_config_ref_valid "$config_ref" || return 1
  fm_procevent_extension_registration_token_valid "$registration_token" || return 1
  reg=$(fm_procevent_registry_dir "$state")
  (umask 077; mkdir -p "$reg") || return 1
  [ -d "$reg" ] && [ ! -L "$reg" ] || return 1
  dest="$reg/$id.source"
  tmp=$(umask 077; mktemp "$reg/.source.XXXXXX") || return 1
  if {
    printf 'adapter=%s\n' "$adapter"
    printf 'owner=extension\n'
    printf 'extension_schema=fm-procevent-extension-owner.v1\n'
    printf 'extension_id=%s\n' "$extension_id"
    printf 'extension_version=%s\n' "$extension_version"
    printf 'capability_version=%s\n' "$capability_version"
    printf 'package_digest=%s\n' "$package_digest"
    printf 'binding_digest=%s\n' "$binding_digest"
    printf 'config_ref=%s\n' "$config_ref"
    printf 'registration_token=%s\n' "$registration_token"
    printf 'argc=0\n'
    printf 'argv:\n'
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Load an extension-owned registration under the caller's source lock.
# 0 = valid extension owner, 1 = ordinary built-in registration, 2 = malformed
# extension owner. Sets FM_PROCEVENT_EXTENSION_* on success.
fm_procevent_extension_registration_load_locked() {  # <state> <source-id>
  local state=$1 id=$2 file adapter_line owner_line schema_line id_line version_line capability_line
  local package_line binding_line config_line token_line argc_line argv_line extra
  file="$(fm_procevent_registry_dir "$state")/$id.source"
  [ -f "$file" ] && [ ! -L "$file" ] || return 2
  owner_line=$(sed -n '2p' "$file") || return 2
  [ "$owner_line" = owner=extension ] || return 1
  [ "$(fm_pr_file_mode "$file")" = 600 ] \
    && [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 2
  {
    IFS= read -r adapter_line \
      && IFS= read -r owner_line \
      && IFS= read -r schema_line \
      && IFS= read -r id_line \
      && IFS= read -r version_line \
      && IFS= read -r capability_line \
      && IFS= read -r package_line \
      && IFS= read -r binding_line \
      && IFS= read -r config_line \
      && IFS= read -r token_line \
      && IFS= read -r argc_line \
      && IFS= read -r argv_line \
      && ! IFS= read -r extra
  } < "$file" || return 2
  [ "$owner_line" = owner=extension ] || return 2
  [ "$schema_line" = extension_schema=fm-procevent-extension-owner.v1 ] || return 2
  [ "$capability_line" = capability_version=1 ] || return 2
  [ "$argc_line" = argc=0 ] && [ "$argv_line" = argv: ] || return 2
  FM_PROCEVENT_EXTENSION_ADAPTER=${adapter_line#adapter=}
  FM_PROCEVENT_EXTENSION_ID=${id_line#extension_id=}
  FM_PROCEVENT_EXTENSION_VERSION=${version_line#extension_version=}
  # shellcheck disable=SC2034 # Public loader output consumed by fm-procevent.sh.
  FM_PROCEVENT_EXTENSION_CAPABILITY_VERSION=${capability_line#capability_version=}
  FM_PROCEVENT_EXTENSION_PACKAGE_DIGEST=${package_line#package_digest=}
  FM_PROCEVENT_EXTENSION_BINDING_DIGEST=${binding_line#binding_digest=}
  FM_PROCEVENT_EXTENSION_CONFIG_REF=${config_line#config_ref=}
  FM_PROCEVENT_EXTENSION_REGISTRATION_TOKEN=${token_line#registration_token=}
  [ "$adapter_line" = "adapter=$FM_PROCEVENT_EXTENSION_ADAPTER" ] || return 2
  [ "$id_line" = "extension_id=$FM_PROCEVENT_EXTENSION_ID" ] || return 2
  [ "$version_line" = "extension_version=$FM_PROCEVENT_EXTENSION_VERSION" ] || return 2
  [ "$package_line" = "package_digest=$FM_PROCEVENT_EXTENSION_PACKAGE_DIGEST" ] || return 2
  [ "$binding_line" = "binding_digest=$FM_PROCEVENT_EXTENSION_BINDING_DIGEST" ] || return 2
  [ "$config_line" = "config_ref=$FM_PROCEVENT_EXTENSION_CONFIG_REF" ] || return 2
  [ "$token_line" = "registration_token=$FM_PROCEVENT_EXTENSION_REGISTRATION_TOKEN" ] || return 2
  fm_procevent_adapter_valid "$FM_PROCEVENT_EXTENSION_ADAPTER" || return 2
  fm_procevent_extension_id_valid "$FM_PROCEVENT_EXTENSION_ID" || return 2
  fm_procevent_extension_version_valid "$FM_PROCEVENT_EXTENSION_VERSION" || return 2
  fm_procevent_digest_valid "$FM_PROCEVENT_EXTENSION_PACKAGE_DIGEST" || return 2
  fm_procevent_digest_valid "$FM_PROCEVENT_EXTENSION_BINDING_DIGEST" || return 2
  fm_procevent_extension_config_ref_valid "$FM_PROCEVENT_EXTENSION_CONFIG_REF" || return 2
  fm_procevent_extension_registration_token_valid "$FM_PROCEVENT_EXTENSION_REGISTRATION_TOKEN" || return 2
}

# Exact legacy registration comparison used by conditional built-in retirement.
fm_procevent_registration_matches_locked() {  # <state> <adapter> <source-id> <argv...>
  local state=$1 adapter=$2 id=$3 reg dest tmp arg status=1
  shift 3
  fm_procevent_adapter_valid "$adapter" || return 1
  fm_procevent_source_id_valid "$id" || return 1
  [ "$#" -ge 1 ] || return 1
  for arg in "$@"; do
    case "$arg" in *$'\n'*) return 1 ;; esac
  done
  reg=$(fm_procevent_registry_dir "$state")
  [ -d "$reg" ] && [ ! -L "$reg" ] || return 1
  dest="$reg/$id.source"
  [ -f "$dest" ] && [ ! -L "$dest" ] || return 1
  tmp=$(umask 077; mktemp "$reg/.source-match.XXXXXX") || return 1
  if {
    printf 'adapter=%s\n' "$adapter"
    printf 'argc=%s\n' "$#"
    printf 'argv:\n'
    printf '%s\n' "$@"
  } > "$tmp" && cmp -s -- "$tmp" "$dest"; then
    status=0
  fi
  rm -f -- "$tmp"
  return "$status"
}

fm_procevent_claim_load_locked() {  # <source-id>
  local claim home pid token identity reg_dir reg_identity terminal state_root state_device state_inode state_owner state_mode extra
  claim=$(fm_procevent_claim_path "$1")
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  {
    IFS= read -r home \
      && IFS= read -r pid \
      && IFS= read -r token \
      && IFS= read -r identity \
      && { IFS= read -r reg_dir || reg_dir=; } \
      && { IFS= read -r reg_identity || reg_identity=; } \
      && { IFS= read -r terminal || terminal=active; }
    if IFS= read -r state_root; then
      IFS= read -r state_device \
        && IFS= read -r state_inode \
        && IFS= read -r state_owner \
        && IFS= read -r state_mode \
        && ! IFS= read -r extra
    else
      state_root=
      state_device=
      state_inode=
      state_owner=
      state_mode=
    fi
  } < "$claim" || return 1
  [ -n "$home" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$identity" ] || return 1
  case "$reg_dir" in ''|/*) ;; *) return 1 ;; esac
  case "$reg_identity" in ''|*:* ) ;; *) return 1 ;; esac
  case "$terminal" in active|terminal) ;; *) return 1 ;; esac
  if [ -n "$state_root" ]; then
    case "$state_root" in /*) ;; *) return 1 ;; esac
    fm_procevent_claim_state_root_field_valid "$state_root" || return 1
    case "$state_device" in ''|*[!0-9]*) return 1 ;; esac
    case "$state_inode" in ''|*[!0-9]*) return 1 ;; esac
    case "$state_owner" in ''|*[!0-9]*) return 1 ;; esac
    case "$state_mode" in ''|*[!0-7]*) return 1 ;; esac
    [ $((8#$state_mode & 8#022)) -eq 0 ] || return 1
  elif [ -n "$state_device$state_inode$state_owner$state_mode" ]; then
    return 1
  fi
  FM_PROCEVENT_CLAIM_HOME=$home
  FM_PROCEVENT_CLAIM_PID=$pid
  FM_PROCEVENT_CLAIM_TOKEN=$token
  FM_PROCEVENT_CLAIM_IDENTITY=$identity
  FM_PROCEVENT_CLAIM_REG_DIR=$reg_dir
  FM_PROCEVENT_CLAIM_REG_IDENTITY=$reg_identity
  FM_PROCEVENT_CLAIM_TERMINAL=$terminal
  FM_PROCEVENT_CLAIM_STATE_ROOT=$state_root
  FM_PROCEVENT_CLAIM_STATE_DEVICE=$state_device
  FM_PROCEVENT_CLAIM_STATE_INODE=$state_inode
  FM_PROCEVENT_CLAIM_STATE_OWNER=$state_owner
  FM_PROCEVENT_CLAIM_STATE_MODE=$state_mode
}

fm_procevent_claim_state_root_field_valid() {  # <canonical-state-root>
  local value=$1 LC_ALL=C
  case "$value" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

fm_procevent_claim_state_root_identity() {  # <state-root>
  local state=$1 canonical device inode owner mode
  canonical=$(fm_procevent_state_root_resolve "$state") || return 1
  fm_procevent_claim_state_root_field_valid "$canonical" || return 1
  device=$(fm_pr_file_device "$canonical") || return 1
  inode=$(fm_pr_file_inode "$canonical") || return 1
  owner=$(id -u) || return 1
  mode=$(fm_pr_file_mode "$canonical") || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$canonical" "$device" "$inode" "$owner" "$mode"
}

fm_procevent_claim_owned_by_state() {  # <state-root> <legacy-home>
  if [ -n "${FM_PROCEVENT_CLAIM_STATE_ROOT:-}" ]; then
    [ "$FM_PROCEVENT_CLAIM_STATE_ROOT" = "$1" ]
  else
    [ "$FM_PROCEVENT_CLAIM_HOME" = "$2" ]
  fi
}

fm_procevent_claim_recorded_state_root_valid() {
  local identity state_root state_device state_inode state_owner state_mode
  state_root=${FM_PROCEVENT_CLAIM_STATE_ROOT:-}
  [ -n "$state_root" ] || return 0
  identity=$(fm_procevent_claim_state_root_identity "$state_root") || return 1
  IFS=$'\t' read -r state_root state_device state_inode state_owner state_mode <<< "$identity"
  [ "$state_root" = "$FM_PROCEVENT_CLAIM_STATE_ROOT" ] \
    && [ "$state_device" = "$FM_PROCEVENT_CLAIM_STATE_DEVICE" ] \
    && [ "$state_inode" = "$FM_PROCEVENT_CLAIM_STATE_INODE" ] \
    && [ "$state_owner" = "$FM_PROCEVENT_CLAIM_STATE_OWNER" ] \
    && [ "$state_mode" = "$FM_PROCEVENT_CLAIM_STATE_MODE" ]
}

fm_procevent_claim_capture_reservation_remove_locked() {
  [ -n "${FM_PROCEVENT_CLAIM_STATE_ROOT:-}" ] || return 0
  fm_procevent_claim_recorded_state_root_valid || return 1
  fm_procevent_capture_reservation_remove_claim "$FM_PROCEVENT_CLAIM_STATE_ROOT" "$FM_PROCEVENT_CLAIM_TOKEN"
}

# fm_procevent_claim_generation_gone_locked
# True only when the loaded claim's owner is stale and the process group it led
# independently has no members left. The separate group check also covers a
# reused live pid whose identity differs while the old generation survives.
# A live matched owner (state 0), an unreadable identity (state 2), and a
# crashed leader whose owned group is still running (state 3) all return false.
fm_procevent_claim_generation_gone_locked() {
  local state=0
  fm_procevent_pid_state "${FM_PROCEVENT_CLAIM_PID:-}" "${FM_PROCEVENT_CLAIM_IDENTITY:-}" || state=$?
  [ "$state" -eq 1 ] \
    && ! fm_procevent_group_alive "${FM_PROCEVENT_CLAIM_PID:-}"
}

# Capture-reservation cleanup for a claim being reclaimed.
#
# Reservation records are keyed by CLAIM TOKEN, and every replacement claims a
# fresh token, so a dead generation's leftovers can never collide with the
# generation that replaces it. They are hygiene, not an ownership invariant -
# the runner's own successful-capture path already tidies them best-effort.
# The cleanup is still attempted and remains authoritative for a generation
# that is not provably gone; it stops being a veto only after the stale owner
# and independent group check prove the whole generation gone.
fm_procevent_claim_capture_reservation_reclaim_locked() {
  fm_procevent_claim_capture_reservation_remove_locked && return 0
  fm_procevent_claim_generation_gone_locked
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

# fm_procevent_claim_acquire_locked <source-id> <home> <pid> <registration> <state-root>
# 0 acquired, 1 error, 2 held by a live owner (possibly another home).
fm_procevent_claim_acquire_locked() {
  local id=$1 home=$2 pid=$3 registration=$4 state=$5 root claim tmp identity token status claim_state old_home old_token old_reg_dir reg_dir reg_identity stage state_root state_device state_inode state_owner state_mode
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
          if [ "$status" -eq 0 ]; then
            fm_procevent_claim_capture_reservation_reclaim_locked || status=1
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
    IFS=$'\t' read -r state_root state_device state_inode state_owner state_mode \
      < <(fm_procevent_claim_state_root_identity "$state") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    token=${tmp##*/}-$pid
    printf '%s\n%s\n%s\n%s\n%s\n%s\nactive\n%s\n%s\n%s\n%s\n%s\n' \
      "$home" "$pid" "$token" "$identity" "$reg_dir" "$reg_identity" \
      "$state_root" "$state_device" "$state_inode" "$state_owner" "$state_mode" > "$tmp" || status=1
    [ "$status" -ne 0 ] || chmod 0600 "$tmp" || status=1
    [ "$status" -ne 0 ] || mv -f -- "$tmp" "$claim" || status=1
    if [ "$status" -eq 0 ]; then
      FM_PROCEVENT_CLAIM_TOKEN=$token
      FM_PROCEVENT_CLAIM_REG_IDENTITY=$reg_identity
    fi
  fi
  [ "$status" -eq 0 ] || { [ -z "${tmp:-}" ] || rm -f -- "$tmp"; }
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
  if [ -n "$FM_PROCEVENT_CLAIM_STATE_ROOT" ]; then
    if printf '%s\n%s\n%s\n%s\n%s\n%s\nterminal\n%s\n%s\n%s\n%s\n%s\n' \
      "$FM_PROCEVENT_CLAIM_HOME" "$FM_PROCEVENT_CLAIM_PID" "$FM_PROCEVENT_CLAIM_TOKEN" \
      "$FM_PROCEVENT_CLAIM_IDENTITY" "$FM_PROCEVENT_CLAIM_REG_DIR" \
      "$FM_PROCEVENT_CLAIM_REG_IDENTITY" "$FM_PROCEVENT_CLAIM_STATE_ROOT" \
      "$FM_PROCEVENT_CLAIM_STATE_DEVICE" "$FM_PROCEVENT_CLAIM_STATE_INODE" \
      "$FM_PROCEVENT_CLAIM_STATE_OWNER" "$FM_PROCEVENT_CLAIM_STATE_MODE" > "$tmp" \
      && chmod 0600 "$tmp" \
      && mv -f -- "$tmp" "$claim"; then
      return 0
    else
      rm -f -- "$tmp"
      return 1
    fi
  fi
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
# The live owner uses this path for its own release. Reservation cleanup must
# succeed normally; stale-generation relaxation is never consulted.
fm_procevent_claim_release_locked() {
  fm_procevent_claim_release_mode_locked release "$@"
}

# fm_procevent_claim_release_terminal_self_locked <source-id> <home> <pid> <token>
# A live runner uses this only while retiring its own terminal source mid-capture.
# Its in-flight reservation is transient, so attempt cleanup without making that
# cleanup a veto; exact ownership still must match before releasing the claim.
fm_procevent_claim_release_terminal_self_locked() {
  fm_procevent_claim_release_mode_locked terminal-self "$@"
}

# fm_procevent_claim_reclaim_locked <source-id> <home> <pid> <token>
# Lifecycle commands use this only after proving or stopping a dead generation.
fm_procevent_claim_reclaim_locked() {
  fm_procevent_claim_release_mode_locked reclaim "$@"
}

fm_procevent_claim_release_mode_locked() {
  local mode=$1 id=$2 home=$3 pid=$4 token=$5 claim
  fm_procevent_source_id_valid "$id" || return 1
  claim=$(fm_procevent_claim_path "$id")
  [ -e "$claim" ] || return 0
  if fm_procevent_claim_load_locked "$id" \
    && [ "$FM_PROCEVENT_CLAIM_HOME" = "$home" ] \
    && [ "$FM_PROCEVENT_CLAIM_PID" = "$pid" ] \
    && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$token" ]; then
    case "$mode" in
      reclaim)
        fm_procevent_claim_capture_reservation_reclaim_locked || return 1
        ;;
      terminal-self)
        fm_procevent_claim_capture_reservation_remove_locked || true
        ;;
      release)
        fm_procevent_claim_capture_reservation_remove_locked || return 1
        ;;
      *) return 1 ;;
    esac
    rm -f -- "$claim"
    return $?
  fi
  return 1
}

# --- durable capture and publication ----------------------------------------

fm_procevent_path_normalize() {
  local path=${1-} part
  local -a parts normalized=()
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *) path="$(pwd -P)/$path" ;;
  esac
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) [ "${#normalized[@]}" -gt 0 ] && unset 'normalized[${#normalized[@]}-1]' ;;
      *) normalized+=("$part") ;;
    esac
  done
  printf '/%s\n' "$(IFS=/; printf '%s' "${normalized[*]}")"
}

fm_procevent_directory_owned_by_current_user() {
  local owner
  if [ "$(uname)" = Darwin ]; then
    owner=$(stat -f %u "$1" 2>/dev/null)
  else
    owner=$(stat -c %u "$1" 2>/dev/null)
  fi
  [ "$owner" = "$(id -u)" ]
}

# fm_procevent_state_root_resolve <state-root>
# Print the physical private directory this module operates on, or fail. A home
# is legitimately spelled through a symlinked ancestor - /tmp and $TMPDIR are
# symlinks on macOS - so the caller's spelling is resolved exactly once here and
# every derived path, recorded claim identity, and later confinement check uses
# the physical root instead. Resolving before validating is what makes the
# private-directory contract hold for the directory actually operated on, rather
# than only for callers that already spelled it physically.
fm_procevent_state_root_resolve() {  # <state-root>
  local state=$1 canonical
  canonical=$(CDPATH='' cd -P -- "$state" 2>/dev/null && pwd -P) || return 1
  fm_procevent_private_directory_valid "$canonical" 0 || return 1
  printf '%s\n' "$canonical"
}

fm_procevent_private_directory_valid() {
  local directory=$1 exact_mode=$2 canonical normalized mode
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  fm_procevent_directory_owned_by_current_user "$directory" || return 1
  mode=$(fm_pr_file_mode "$directory") || return 1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  if [ "$exact_mode" = 1 ]; then
    [ "$mode" = 700 ] || return 1
  elif [ $((8#$mode & 8#022)) -ne 0 ]; then
    return 1
  fi
  canonical=$(cd -P -- "$directory" && pwd -P) || return 1
  normalized=$(fm_procevent_path_normalize "$directory") || return 1
  [ "$canonical" = "$normalized" ]
}

fm_procevent_capture_inbox_prepare() {
  local state=$1 inbox
  state=$(fm_procevent_state_root_resolve "$state") || return 1
  inbox=$(fm_procevent_inbox_dir "$state")
  if [ ! -e "$inbox" ] && [ ! -L "$inbox" ]; then
    (umask 077; mkdir "$inbox") || return 1
  fi
  fm_procevent_private_directory_valid "$inbox" 1 || return 1
  printf '%s\n' "$inbox"
}

# Print the validated physical registry directory, like the inbox and
# reservation preparers beside it, so a caller that pins the boundary with
# `pwd -P` compares against the same physical path this validated.
fm_procevent_extension_staging_prepare() {
  local state=$1 registry
  state=$(fm_procevent_state_root_resolve "$state") || return 1
  registry=$(fm_procevent_registry_dir "$state")
  fm_procevent_private_directory_valid "$registry" 1 || return 1
  printf '%s\n' "$registry"
}

fm_procevent_capture_reservation_prepare() {
  local state=$1 reservation
  state=$(fm_procevent_state_root_resolve "$state") || return 1
  reservation=$(fm_procevent_capture_reservation_dir "$state")
  if [ ! -e "$reservation" ] && [ ! -L "$reservation" ]; then
    (umask 077; mkdir "$reservation") || return 1
  fi
  fm_procevent_private_directory_valid "$reservation" 1 || return 1
  printf '%s\n' "$reservation"
}

fm_procevent_capture_reservation_remove_claim() {  # <state> <claim-token>
  local state=$1 token=$2 reservation record
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  reservation=$(fm_procevent_capture_reservation_dir "$state")
  [ -d "$reservation" ] || return 0
  fm_procevent_private_directory_valid "$reservation" 1 || return 1
  for record in "$reservation"/.extension-capture-"$token".*.json \
    "$reservation"/.extension-capture-"$token".*.consumed-*; do
    [ -e "$record" ] || continue
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    rm -f -- "$record" || return 1
  done
}

# fm_procevent_capture <state> <source-id> <adapter> <output-file>
#   [<extension-id> <extension-version> <capability-version> <package-digest> <binding-digest>]
# Atomically store the completed output at 0600 and print its durable path. The
# rename is the commit point; nothing referencing this result may be published
# before it returns successfully. Extension captures retain immutable package
# identity beside the legacy adapter sidecar, so later classification cannot
# silently move to a replacement binding.
fm_procevent_capture() {
  local state=$1 id=$2 adapter=$3 src=$4 extension_id=${5-} extension_version=${6-}
  local capability_version=${7-} package_digest=${8-} binding_digest=${9-}
  local inbox seq dest tmp adapter_dest adapter_tmp extension_dest='' extension_tmp=''
  [ "$#" -eq 4 ] || [ "$#" -eq 9 ] || return 1
  fm_procevent_source_id_valid "$id" || return 1
  fm_procevent_adapter_valid "$adapter" || return 1
  if [ "$#" -eq 9 ]; then
    fm_procevent_extension_id_valid "$extension_id" || return 1
    fm_procevent_extension_version_valid "$extension_version" || return 1
    [ "$capability_version" = 1 ] || return 1
    fm_procevent_digest_valid "$package_digest" || return 1
    fm_procevent_digest_valid "$binding_digest" || return 1
  fi
  if [ "$#" -eq 9 ]; then
    if [ "${FM_PROCEVENT_CAPTURE_PINNED_INBOX:-}" != 1 ]; then
      inbox=$(fm_procevent_capture_inbox_prepare "$state") || return 1
      (
        CDPATH='' cd -- "$inbox" 2>/dev/null || exit 1
        [ "$(pwd -P)" = "$inbox" ] || exit 1
        FM_PROCEVENT_CAPTURE_PINNED_INBOX=1 \
          FM_PROCEVENT_CAPTURE_ABSOLUTE_INBOX="$inbox" \
          fm_procevent_capture "$@"
      )
      return $?
    fi
    inbox=.
  else
    inbox=$(fm_procevent_inbox_dir "$state")
    (umask 077; mkdir -p "$inbox") || return 1
  fi
  seq=1
  while [ -e "$inbox/$id.$seq.result" ]; do seq=$((seq + 1)); done
  dest="$inbox/$id.$seq.result"
  adapter_dest="$inbox/$id.$seq.adapter"
  if [ "$#" -eq 9 ]; then
    [ ! -e "$dest" ] && [ ! -L "$dest" ] \
      && [ ! -e "$adapter_dest" ] && [ ! -L "$adapter_dest" ] || return 1
  fi
  tmp=$(umask 077; mktemp "$inbox/.capture.XXXXXX") || return 1
  adapter_tmp=$(umask 077; mktemp "$inbox/.adapter.XXXXXX") || { rm -f -- "$tmp"; return 1; }
  if [ "$#" -eq 9 ]; then
    extension_dest="$inbox/$id.$seq.extension"
    [ ! -e "$extension_dest" ] && [ ! -L "$extension_dest" ] || {
      rm -f -- "$tmp" "$adapter_tmp"
      return 1
    }
    extension_tmp=$(umask 077; mktemp "$inbox/.extension.XXXXXX") \
      || { rm -f -- "$tmp" "$adapter_tmp"; return 1; }
  fi
  if ! cat "$src" > "$tmp"; then rm -f -- "$tmp" "$adapter_tmp" "$extension_tmp"; return 1; fi
  if ! printf '%s\n' "$adapter" > "$adapter_tmp"; then rm -f -- "$tmp" "$adapter_tmp" "$extension_tmp"; return 1; fi
  if [ "$#" -eq 9 ] && ! {
    printf 'schema=fm-procevent-extension-owner.v1\n'
    printf 'extension_id=%s\n' "$extension_id"
    printf 'extension_version=%s\n' "$extension_version"
    printf 'capability_version=%s\n' "$capability_version"
    printf 'package_digest=%s\n' "$package_digest"
    printf 'binding_digest=%s\n' "$binding_digest"
  } > "$extension_tmp"; then
    rm -f -- "$tmp" "$adapter_tmp" "$extension_tmp"
    return 1
  fi
  if ! chmod 0600 "$tmp" "$adapter_tmp"; then
    rm -f -- "$tmp" "$adapter_tmp" "$extension_tmp"
    return 1
  fi
  if [ "$#" -eq 9 ] && ! chmod 0600 "$extension_tmp"; then
    rm -f -- "$tmp" "$adapter_tmp" "$extension_tmp"
    return 1
  fi
  if ! mv -f -- "$adapter_tmp" "$adapter_dest"; then rm -f -- "$tmp" "$adapter_tmp" "$extension_tmp"; return 1; fi
  if [ "$#" -eq 9 ] && ! mv -f -- "$extension_tmp" "$extension_dest"; then
    rm -f -- "$tmp" "$adapter_dest" "$extension_tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" "$adapter_dest"
    [ -z "$extension_dest" ] || rm -f -- "$extension_dest"
    return 1
  fi
  if [ "$#" -eq 9 ]; then
    printf '%s\n' "$FM_PROCEVENT_CAPTURE_ABSOLUTE_INBOX/$id.$seq.result"
  else
    printf '%s\n' "$dest"
  fi
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
  if [ "${FM_PROCEVENT_CAPTURE_PINNED_INBOX:-}" = 1 ]; then
    printf './%s.%s.handled\n' "$2" "$3"
    return
  fi
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
  if [ "${FM_PROCEVENT_CAPTURE_PINNED_INBOX:-}" = 1 ]; then
    inbox=.
  else
    inbox=$(fm_procevent_inbox_dir "$state")
  fi
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

# Load immutable extension identity for one captured result.
# 0 = valid extension sidecar, 1 = built-in result (sidecar absent),
# 2 = malformed or unsafe extension sidecar.
fm_procevent_result_extension_load() {  # <result-path>
  local result=$1 file="${1%.result}.extension" schema_line id_line version_line capability_line
  local package_line binding_line extra
  [ -e "$file" ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 2
  [ "$(fm_pr_file_mode "$file")" = 600 ] \
    && [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 2
  {
    IFS= read -r schema_line \
      && IFS= read -r id_line \
      && IFS= read -r version_line \
      && IFS= read -r capability_line \
      && IFS= read -r package_line \
      && IFS= read -r binding_line \
      && ! IFS= read -r extra
  } < "$file" || return 2
  [ "$schema_line" = schema=fm-procevent-extension-owner.v1 ] || return 2
  [ "$capability_line" = capability_version=1 ] || return 2
  FM_PROCEVENT_RESULT_EXTENSION_ID=${id_line#extension_id=}
  FM_PROCEVENT_RESULT_EXTENSION_VERSION=${version_line#extension_version=}
  # shellcheck disable=SC2034 # Public loader output consumed by fm-procevent.sh.
  FM_PROCEVENT_RESULT_EXTENSION_CAPABILITY_VERSION=${capability_line#capability_version=}
  FM_PROCEVENT_RESULT_EXTENSION_PACKAGE_DIGEST=${package_line#package_digest=}
  FM_PROCEVENT_RESULT_EXTENSION_BINDING_DIGEST=${binding_line#binding_digest=}
  [ "$id_line" = "extension_id=$FM_PROCEVENT_RESULT_EXTENSION_ID" ] || return 2
  [ "$version_line" = "extension_version=$FM_PROCEVENT_RESULT_EXTENSION_VERSION" ] || return 2
  [ "$package_line" = "package_digest=$FM_PROCEVENT_RESULT_EXTENSION_PACKAGE_DIGEST" ] || return 2
  [ "$binding_line" = "binding_digest=$FM_PROCEVENT_RESULT_EXTENSION_BINDING_DIGEST" ] || return 2
  fm_procevent_extension_id_valid "$FM_PROCEVENT_RESULT_EXTENSION_ID" || return 2
  fm_procevent_extension_version_valid "$FM_PROCEVENT_RESULT_EXTENSION_VERSION" || return 2
  fm_procevent_digest_valid "$FM_PROCEVENT_RESULT_EXTENSION_PACKAGE_DIGEST" || return 2
  fm_procevent_digest_valid "$FM_PROCEVENT_RESULT_EXTENSION_BINDING_DIGEST" || return 2
}
