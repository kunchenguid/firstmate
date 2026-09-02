#!/usr/bin/env bash
# Shared owner for per-task temporary-root allocation, validation, transfer,
# reconciliation, and removal.
#
# A fresh allocation publishes state/<id>.tasktmp-claim before it creates
# anything in the public temporary parent.
# The claim format is version=1, id, nonce, path, phase, and created, one key per line.
# The stable claim is mode 0600 and remains authoritative until matching task
# metadata or Orca recovery metadata records the same tasktmp value.
#
# Callers must hold state/.spawn-<id>.lock while creating or reconciling a
# claim.
# A recorded root is accepted only when its spelling is bound to the exact task
# id, its root and gotmp child are real directories owned by the effective uid,
# and neither is writable by group or other.
# New random roots must additionally be mode 0700.
# Validation failures are refusals: this library never chmods, enters,
# canonicalizes, traverses, or removes an untrusted task root.
# Missing tasktmp fields and recognized roots that are already absent remain
# compatible no-ops for lifecycle cleanup.
# A refusal outlives the task record that named the path: teardown writes
# state/<id>.tasktmp-refused, and every later startup re-reports it until the
# refused path is gone.
#
# Trust is a FOUR-state answer, so no caller may reduce it to a boolean.
# fm_tasktmp_trust is the only interface call sites use; it sets
# FM_TASKTMP_TRUST to exactly one of:
#   trusted    - the root, and unless the root-only scope is asked for its
#                gotmp child, is present, task-owned, and private; it may be
#                used, scanned, and removed.
#   incomplete - the root itself passed every trust check but its gotmp child
#                is absent. The path is proven ours and private, so this is a
#                recoverable own-root state, never a refusal: reuse restores
#                the child inside the root it already owns, and scanning and
#                removal treat it exactly like trusted. Only the default
#                gotmp scope can report it.
#   unsafe     - the path exists and failed a trust check; refuse it, report
#                FM_TASKTMP_ERROR, and neither chmod, enter, canonicalize,
#                traverse, adopt, nor delete it.
#   absent     - the recognized root does not exist; a compatible no-op that
#                is never a refusal.
# fm_tasktmp_validate and fm_tasktmp_validate_root stay the underlying
# primitives (0 trusted, 1 unsafe, 2 absent, 3 incomplete) and must never be
# called as `if ! fm_tasktmp_validate ...`, which silently merges unsafe with
# absent and incomplete and turns a vanished or repairable root into a refusal.

FM_TASKTMP_ERROR=
FM_TASKTMP_TRUST=
FM_TASKTMP_KIND=
FM_TASKTMP_EUID=
FM_TASKTMP_PARENT=
FM_TASKTMP_STAT_UID=
FM_TASKTMP_STAT_MODE=
FM_TASKTMP_STAT_TYPE=
FM_TASKTMP_CLAIM_ID=
FM_TASKTMP_CLAIM_NONCE=
FM_TASKTMP_CLAIM_PATH=
FM_TASKTMP_CLAIM_PHASE=
FM_TASKTMP_REFUSED_PATH=
FM_TASKTMP_REFUSED_REASON=

fm_tasktmp_error() {  # <message>
  FM_TASKTMP_ERROR=$1
  printf 'tasktmp: %s\n' "$FM_TASKTMP_ERROR" >&2
  return 1
}

# The effective uid cannot change inside one process, so resolve it once and
# reuse it for every ownership check in this shell.
fm_tasktmp_euid() {
  [ -z "$FM_TASKTMP_EUID" ] || return 0
  local euid
  euid=$(id -u) || {
    fm_tasktmp_error "effective uid cannot be determined"
    return 1
  }
  case "$euid" in
    ''|*[!0-9]*)
      fm_tasktmp_error "effective uid could not be read as a number"
      return 1
      ;;
  esac
  FM_TASKTMP_EUID=$euid
}

# The trusted temporary parent resolves once per process, exactly like the
# effective uid, so no call site pays a subshell to re-derive it.
# Callers inside this library read FM_TASKTMP_PARENT after the resolver returns;
# fm_tasktmp_parent stays the printing form for anything outside it.
fm_tasktmp_resolve_parent() {
  [ -z "$FM_TASKTMP_PARENT" ] || return 0
  local parent
  parent=$(CDPATH='' cd -- /tmp 2>/dev/null && pwd -P) || {
    fm_tasktmp_error "trusted temporary parent /tmp cannot be resolved"
    return 1
  }
  case "$parent" in
    /*) ;;
    *)
      fm_tasktmp_error "trusted temporary parent resolved to a non-absolute path"
      return 1
      ;;
  esac
  FM_TASKTMP_PARENT=$parent
}

fm_tasktmp_parent() {
  fm_tasktmp_resolve_parent || return 1
  printf '%s\n' "$FM_TASKTMP_PARENT"
}

fm_tasktmp_lstat() {  # <path>
  local path=$1 raw uid mode type
  if raw=$(LC_ALL=C stat -c '%u|%a|%F' -- "$path" 2>/dev/null); then
    :
  elif raw=$(LC_ALL=C stat -f '%u|%Lp|%HT' "$path" 2>/dev/null); then
    :
  else
    fm_tasktmp_error "cannot inspect $path without following or entering it"
    return 1
  fi
  uid=${raw%%|*}
  raw=${raw#*|}
  mode=${raw%%|*}
  type=${raw#*|}
  case "$uid" in ''|*[!0-9]*) fm_tasktmp_error "invalid owner result for $path"; return 1 ;; esac
  case "$mode" in ''|*[!0-7]*) fm_tasktmp_error "invalid mode result for $path"; return 1 ;; esac
  FM_TASKTMP_STAT_UID=$uid
  FM_TASKTMP_STAT_MODE=$mode
  FM_TASKTMP_STAT_TYPE=$type
}

fm_tasktmp_mode_private() {  # <octal-mode>
  local mode=$1 value
  value=$((8#$mode))
  [ $((value & 0022)) -eq 0 ]
}

fm_tasktmp_mode_exact_private() {  # <octal-mode>
  local mode=$1 value
  value=$((8#$mode))
  (( (value & 0777) == 0700 ))
}

fm_tasktmp_directory_stat_valid() {  # <path> <new|legacy>
  local path=$1 kind=$2
  fm_tasktmp_lstat "$path" || return 1
  case "$FM_TASKTMP_STAT_TYPE" in
    directory|Directory) ;;
    *) fm_tasktmp_error "$path is not a real directory"; return 1 ;;
  esac
  fm_tasktmp_euid || return 1
  [ "$FM_TASKTMP_STAT_UID" = "$FM_TASKTMP_EUID" ] || {
    fm_tasktmp_error "$path is owned by uid $FM_TASKTMP_STAT_UID, not effective uid $FM_TASKTMP_EUID"
    return 1
  }
  fm_tasktmp_mode_private "$FM_TASKTMP_STAT_MODE" || {
    fm_tasktmp_error "$path mode $FM_TASKTMP_STAT_MODE is writable by group or other"
    return 1
  }
  if [ "$kind" = new ]; then
    fm_tasktmp_mode_exact_private "$FM_TASKTMP_STAT_MODE" || {
      fm_tasktmp_error "$path mode $FM_TASKTMP_STAT_MODE is not the required 0700"
      return 1
    }
  fi
}

fm_tasktmp_classify_path() {  # <task-id> <path>
  local id=$1 path=$2 parent prefix nonce
  fm_tasktmp_resolve_parent || return 1
  parent=$FM_TASKTMP_PARENT
  FM_TASKTMP_KIND=
  if [ "$path" = "$parent/fm-$id" ] || [ "$path" = "/tmp/fm-$id" ]; then
    FM_TASKTMP_KIND=legacy
    return 0
  fi
  for prefix in "$parent/fm-$id." "/tmp/fm-$id."; do
    case "$path" in
      "$prefix"*)
        nonce=${path#"$prefix"}
        case "$nonce" in
          ''|*[!A-Za-z0-9]*) continue ;;
        esac
        [ "${#nonce}" -ge 8 ] || continue
        FM_TASKTMP_KIND=new
        return 0
        ;;
    esac
  done
  fm_tasktmp_error "task temporary root '$path' is not recognized for task $id"
}

fm_tasktmp_path_absent() {  # <path>
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

fm_tasktmp_validate_root() {  # <task-id> <path>
  local id=$1 path=$2 kind
  fm_tasktmp_classify_path "$id" "$path" || return 1
  kind=$FM_TASKTMP_KIND
  if fm_tasktmp_path_absent "$path"; then
    FM_TASKTMP_ERROR="task temporary root $path is missing"
    return 2
  fi
  fm_tasktmp_directory_stat_valid "$path" "$kind"
}

fm_tasktmp_validate() {  # <task-id> <path>
  local id=$1 path=$2 kind gotmp
  fm_tasktmp_classify_path "$id" "$path" || return 1
  kind=$FM_TASKTMP_KIND
  if fm_tasktmp_path_absent "$path"; then
    FM_TASKTMP_ERROR="task temporary root $path is missing"
    return 2
  fi
  fm_tasktmp_directory_stat_valid "$path" "$kind" || return 1
  gotmp=$path/gotmp
  if fm_tasktmp_path_absent "$gotmp"; then
    FM_TASKTMP_ERROR="task temporary root $path is task-owned but its gotmp child is missing"
    return 3
  fi
  fm_tasktmp_directory_stat_valid "$gotmp" "$kind" || return 1
}

fm_tasktmp_trust() {  # <task-id> <path> [root]
  local id=$1 path=$2 scope=${3:-gotmp} rc=0
  if [ "$scope" = root ]; then
    fm_tasktmp_validate_root "$id" "$path" || rc=$?
  else
    fm_tasktmp_validate "$id" "$path" || rc=$?
  fi
  case "$rc" in
    0) FM_TASKTMP_TRUST=trusted ;;
    2) FM_TASKTMP_TRUST=absent ;;
    3) FM_TASKTMP_TRUST=incomplete ;;
    *) FM_TASKTMP_TRUST=unsafe ;;
  esac
  return 0
}

fm_tasktmp_recorded_prepare() {  # <state> <task-id> <recorded-path>
  local state=$1 id=$2 path=$3
  if [ -z "$path" ]; then
    fm_tasktmp_claim_create "$state" "$id"
    return
  fi
  fm_tasktmp_trust "$id" "$path"
  case "$FM_TASKTMP_TRUST" in
    trusted)
      printf '%s\n' "$path"
      return 0
      ;;
    absent)
      fm_tasktmp_claim_create "$state" "$id"
      return
      ;;
    incomplete)
      # The root is already proven task-owned and private, so restoring the
      # child Go cannot create for itself stays inside a directory no other
      # user can write, and the restored pair is validated before it is used.
      (umask 077; mkdir -- "$path/gotmp") 2>/dev/null || true
      fm_tasktmp_trust "$id" "$path"
      if [ "$FM_TASKTMP_TRUST" = trusted ]; then
        printf '%s\n' "$path"
        return 0
      fi
      fm_tasktmp_error "task temporary root $path is task-owned but its gotmp child could not be restored: $FM_TASKTMP_ERROR"
      return 1
      ;;
  esac
  return 1
}

fm_tasktmp_claim_path() {  # <state> <task-id>
  printf '%s/%s.tasktmp-claim\n' "$1" "$2"
}

fm_tasktmp_claim_read() {  # <state> <task-id>
  local state=$1 id=$2 claim line key value seen_version=0 seen_id=0 seen_nonce=0 seen_path=0 seen_phase=0 seen_created=0
  claim=$(fm_tasktmp_claim_path "$state" "$id")
  if fm_tasktmp_path_absent "$claim"; then
    FM_TASKTMP_ERROR="no pending task temporary claim for $id"
    return 2
  fi
  fm_tasktmp_lstat "$claim" || return 1
  case "$FM_TASKTMP_STAT_TYPE" in
    regular\ file|Regular\ File|regular) ;;
    *) fm_tasktmp_error "task temporary claim $claim is not a regular file"; return 1 ;;
  esac
  fm_tasktmp_euid || return 1
  [ "$FM_TASKTMP_STAT_UID" = "$FM_TASKTMP_EUID" ] || {
    fm_tasktmp_error "task temporary claim $claim is not owned by the effective uid"
    return 1
  }
  fm_tasktmp_mode_private "$FM_TASKTMP_STAT_MODE" || {
    fm_tasktmp_error "task temporary claim $claim has unsafe mode $FM_TASKTMP_STAT_MODE"
    return 1
  }
  FM_TASKTMP_CLAIM_ID=
  FM_TASKTMP_CLAIM_NONCE=
  FM_TASKTMP_CLAIM_PATH=
  FM_TASKTMP_CLAIM_PHASE=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) fm_tasktmp_error "task temporary claim $claim is malformed"; return 1 ;;
    esac
    case "$key" in
      version) [ "$seen_version" -eq 0 ] && [ "$value" = 1 ] || { fm_tasktmp_error "task temporary claim $claim has an invalid version"; return 1; }; seen_version=1 ;;
      id) [ "$seen_id" -eq 0 ] || { fm_tasktmp_error "task temporary claim $claim repeats id"; return 1; }; FM_TASKTMP_CLAIM_ID=$value; seen_id=1 ;;
      nonce) [ "$seen_nonce" -eq 0 ] || { fm_tasktmp_error "task temporary claim $claim repeats nonce"; return 1; }; FM_TASKTMP_CLAIM_NONCE=$value; seen_nonce=1 ;;
      path) [ "$seen_path" -eq 0 ] || { fm_tasktmp_error "task temporary claim $claim repeats path"; return 1; }; FM_TASKTMP_CLAIM_PATH=$value; seen_path=1 ;;
      phase) [ "$seen_phase" -eq 0 ] || { fm_tasktmp_error "task temporary claim $claim repeats phase"; return 1; }; FM_TASKTMP_CLAIM_PHASE=$value; seen_phase=1 ;;
      created) [ "$seen_created" -eq 0 ] || { fm_tasktmp_error "task temporary claim $claim repeats created"; return 1; }; seen_created=1 ;;
      *) fm_tasktmp_error "task temporary claim $claim has unknown field '$key'"; return 1 ;;
    esac
  done < "$claim"
  [ "$seen_version$seen_id$seen_nonce$seen_path$seen_phase$seen_created" = 111111 ] || {
    fm_tasktmp_error "task temporary claim $claim is incomplete"
    return 1
  }
  [ "$FM_TASKTMP_CLAIM_ID" = "$id" ] || {
    fm_tasktmp_error "task temporary claim $claim belongs to '$FM_TASKTMP_CLAIM_ID', not '$id'"
    return 1
  }
  case "$FM_TASKTMP_CLAIM_NONCE" in ''|*[!A-Za-z0-9]*) fm_tasktmp_error "task temporary claim $claim has an invalid nonce"; return 1 ;; esac
  case "$FM_TASKTMP_CLAIM_PHASE" in pending|committed) ;; *) fm_tasktmp_error "task temporary claim $claim has invalid phase '$FM_TASKTMP_CLAIM_PHASE'"; return 1 ;; esac
  fm_tasktmp_classify_path "$id" "$FM_TASKTMP_CLAIM_PATH" || return 1
  [ "$FM_TASKTMP_KIND" = new ] || {
    fm_tasktmp_error "task temporary claim $claim does not name a random root"
    return 1
  }
  [ "${FM_TASKTMP_CLAIM_PATH##*.}" = "$FM_TASKTMP_CLAIM_NONCE" ] || {
    fm_tasktmp_error "task temporary claim $claim nonce does not match its path"
    return 1
  }
}

fm_tasktmp_claim_retire() {  # <state> <task-id>
  local state=$1 id=$2 claim
  fm_tasktmp_claim_read "$state" "$id" || return $?
  claim=$(fm_tasktmp_claim_path "$state" "$id")
  rm -f -- "$claim" || fm_tasktmp_error "task temporary claim $claim could not be retired"
}

fm_tasktmp_meta_tasktmp() {  # <meta>
  awk -F= '$1 == "tasktmp" { value = substr($0, index($0, "=") + 1); found += 1 } END { if (found == 1) print value; else if (found > 1) exit 2 }' "$1"
}

fm_tasktmp_claim_mark_committed() {  # <state> <task-id>
  local state=$1 id=$2 claim temp
  fm_tasktmp_claim_read "$state" "$id" || return $?
  [ "$FM_TASKTMP_CLAIM_PHASE" = pending ] || return 0
  claim=$(fm_tasktmp_claim_path "$state" "$id")
  temp=$state/.$id.tasktmp-claim.commit.${BASHPID:-$$}
  if ! (
    umask 077
    awk '$0 == "phase=pending" { print "phase=committed"; changed += 1; next } { print } END { if (changed != 1) exit 1 }' \
      "$claim" > "$temp" \
      && chmod 600 -- "$temp" \
      && mv -- "$temp" "$claim"
  ); then
    rm -f -- "$temp" 2>/dev/null || true
    fm_tasktmp_error "task temporary claim $claim could not record its commit point"
    return 1
  fi
  fm_tasktmp_claim_read "$state" "$id" || return 1
  [ "$FM_TASKTMP_CLAIM_PHASE" = committed ] || fm_tasktmp_error "task temporary claim $claim did not retain its commit point"
}

fm_tasktmp_claim_transfer() {  # <state> <task-id> <meta>
  local state=$1 id=$2 meta=$3 recorded
  fm_tasktmp_claim_read "$state" "$id" || return $?
  [ "$FM_TASKTMP_CLAIM_PHASE" = committed ] || {
    fm_tasktmp_error "task temporary claim for $id has not reached its commit point"
    return 1
  }
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    fm_tasktmp_error "task temporary claim for $id has no safe metadata owner at $meta"
    return 1
  }
  recorded=$(fm_tasktmp_meta_tasktmp "$meta") || {
    fm_tasktmp_error "task metadata $meta has an ambiguous tasktmp field"
    return 1
  }
  [ "$recorded" = "$FM_TASKTMP_CLAIM_PATH" ] || {
    fm_tasktmp_error "task metadata $meta does not own claimed root $FM_TASKTMP_CLAIM_PATH"
    return 1
  }
  fm_tasktmp_claim_retire "$state" "$id"
}

fm_tasktmp_remove() {  # <task-id> <path>
  local id=$1 path=$2
  [ -n "$path" ] || return 0
  fm_tasktmp_trust "$id" "$path"
  case "$FM_TASKTMP_TRUST" in
    absent) return 0 ;;
    unsafe) return 1 ;;
  esac
  rm -rf -- "$path" || fm_tasktmp_error "trusted task temporary root $path could not be removed"
}

fm_tasktmp_claim_cleanup_root() {  # <task-id> <claimed-path>
  local id=$1 path=$2 gotmp
  fm_tasktmp_trust "$id" "$path" root
  case "$FM_TASKTMP_TRUST" in
    absent) return 0 ;;
    unsafe) return 1 ;;
  esac
  [ "$FM_TASKTMP_KIND" = new ] || {
    fm_tasktmp_error "claimed task temporary root $path is not a random root"
    return 1
  }
  gotmp=$path/gotmp
  if fm_tasktmp_path_absent "$gotmp"; then
    rmdir -- "$path" || fm_tasktmp_error "partially created task temporary root $path is not empty and was preserved"
    return
  fi
  fm_tasktmp_directory_stat_valid "$gotmp" new || return 1
  rm -rf -- "$path" || fm_tasktmp_error "claimed task temporary root $path could not be removed"
}

fm_tasktmp_claim_reconcile_one() {  # <state> <task-id>
  local state=$1 id=$2 meta="$1/$2.meta" rc recorded
  if fm_tasktmp_claim_read "$state" "$id"; then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] && return 0
    return "$rc"
  fi
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    # Ownership that cannot be read is ownership that cannot be disproven, so
    # an ambiguous or unreadable tasktmp field preserves and reports exactly
    # like the sibling readers rather than falling through to cleanup.
    if ! recorded=$(fm_tasktmp_meta_tasktmp "$meta" 2>/dev/null); then
      fm_tasktmp_error "task metadata $meta has duplicate or unreadable tasktmp fields, so ownership of $FM_TASKTMP_CLAIM_PATH could not be established; the root and claim for $id were preserved"
      return 1
    fi
    if [ "$recorded" = "$FM_TASKTMP_CLAIM_PATH" ]; then
      # Durable metadata naming the identical root is the completed transfer,
      # even when a crash lost the commit point.
      # An already-absent root leaves nothing to own, clean, or leak, so only a
      # path that still exists and stopped being trusted is preserved.
      if [ "$FM_TASKTMP_CLAIM_PHASE" != committed ]; then
        fm_tasktmp_trust "$id" "$FM_TASKTMP_CLAIM_PATH"
        if [ "$FM_TASKTMP_TRUST" = unsafe ]; then
          fm_tasktmp_error "matching task metadata for $id was published before its temporary-root commit point and $FM_TASKTMP_CLAIM_PATH is no longer trusted: $FM_TASKTMP_ERROR; the root and claim were preserved"
          return 1
        fi
      fi
      fm_tasktmp_claim_retire "$state" "$id"
      return
    fi
  fi
  fm_tasktmp_claim_cleanup_root "$id" "$FM_TASKTMP_CLAIM_PATH" || return 1
  fm_tasktmp_claim_retire "$state" "$id"
}

# The candidate nonce is drawn independently of every filename this library
# creates, so the not-yet-created root's name never exists as a listable entry
# in a state directory that carries only the ambient umask.
fm_tasktmp_nonce() {
  local raw
  raw=$(head -c 4096 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' 2>/dev/null) || raw=
  raw=${raw:0:12}
  case "$raw" in
    ''|*[!A-Za-z0-9]*) return 1 ;;
  esac
  [ "${#raw}" -ge 12 ] || return 1
  printf '%s\n' "$raw"
}

fm_tasktmp_claim_create() {  # <state> <task-id>
  local state=$1 id=$2 parent stable temp nonce candidate attempt max created
  fm_tasktmp_resolve_parent || return 1
  parent=$FM_TASKTMP_PARENT
  stable=$(fm_tasktmp_claim_path "$state" "$id")
  max=${FM_TASKTMP_CLAIM_ATTEMPTS:-8}
  case "$max" in ''|*[!0-9]*|0) max=8 ;; esac
  fm_tasktmp_claim_reconcile_one "$state" "$id" || return 1
  attempt=1
  while [ "$attempt" -le "$max" ]; do
    temp=$(umask 077; mktemp "$state/.$id.tasktmp-claim.XXXXXXXXXXXX") || {
      fm_tasktmp_error "could not create a private random task temporary claim for $id"
      return 1
    }
    nonce=$(fm_tasktmp_nonce) || {
      rm -f -- "$temp"
      fm_tasktmp_error "temporary claim generator returned an invalid nonce"
      return 1
    }
    candidate=$parent/fm-$id.$nonce
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ) || created=
    # One subshell so the private umask cannot outlive this publication, and one
    # && chain so a short write, a failed chmod, or a failed rename never
    # publishes a partial claim at the stable path.
    if [ -z "$created" ] || ! (
      umask 077
      printf 'version=1\nid=%s\nnonce=%s\npath=%s\nphase=pending\ncreated=%s\n' \
        "$id" "$nonce" "$candidate" "$created" > "$temp" \
        && chmod 600 -- "$temp" \
        && mv -- "$temp" "$stable"
    ); then
      rm -f -- "$temp"
      fm_tasktmp_error "could not publish the private task temporary claim for $id"
      return 1
    fi
    if (umask 077; mkdir -- "$candidate") 2>/dev/null; then
      fm_tasktmp_directory_stat_valid "$candidate" new || return 1
      if ! (umask 077; mkdir -- "$candidate/gotmp") 2>/dev/null; then
        fm_tasktmp_error "could not create gotmp in claimed task temporary root $candidate; the claim was retained"
        return 1
      fi
      fm_tasktmp_directory_stat_valid "$candidate/gotmp" new || return 1
      printf '%s\n' "$candidate"
      return 0
    fi
    # A failed exact mkdir never authorizes inspection or adoption of the
    # candidate.
    # Retire only the private claim and try another independently random name.
    fm_tasktmp_claim_retire "$state" "$id" || return 1
    attempt=$((attempt + 1))
  done
  fm_tasktmp_error "could not create a collision-free task temporary root for $id after $max attempts"
  return 1
}

fm_tasktmp_audit_meta() {  # <meta>
  local meta=$1 id path
  id=${meta##*/}
  id=${id%.meta}
  path=$(fm_tasktmp_meta_tasktmp "$meta" 2>/dev/null) || {
    printf 'TASKTMP_RECONCILE: %s: task metadata has duplicate or unreadable tasktmp fields; nothing was touched\n' "$id"
    return 1
  }
  [ -n "$path" ] || return 0
  fm_tasktmp_trust "$id" "$path"
  [ "$FM_TASKTMP_TRUST" = unsafe ] || return 0
  printf 'TASKTMP_RECONCILE: %s: unsafe recorded task temporary root refused: %s; nothing was touched\n' "$id" "$FM_TASKTMP_ERROR"
  return 1
}

# A refused root outlives the task record that named it, so the refusal itself
# must be durable: teardown removes state/<id>.meta, and without this record no
# later session could name the path it left untouched.
# The record is version=1, id, path, reason, and refused, one key per line, mode
# 0600, and is retired only once the refused path is gone.
fm_tasktmp_refusal_path() {  # <state> <task-id>
  printf '%s/%s.tasktmp-refused\n' "$1" "$2"
}

fm_tasktmp_refusal_record() {  # <state> <task-id> <refused-path> <reason>
  local state=$1 id=$2 path=$3 reason=$4 record temp refused
  record=$(fm_tasktmp_refusal_path "$state" "$id")
  temp=$state/.$id.tasktmp-refused.${BASHPID:-$$}
  reason=${reason//$'\n'/ }
  [ -n "$reason" ] || reason="no detail was recorded"
  refused=$(date -u +%Y-%m-%dT%H:%M:%SZ) || refused=
  if [ -z "$refused" ] || ! (
    umask 077
    printf 'version=1\nid=%s\npath=%s\nreason=%s\nrefused=%s\n' \
      "$id" "$path" "$reason" "$refused" > "$temp" \
      && chmod 600 -- "$temp" \
      && mv -- "$temp" "$record"
  ); then
    rm -f -- "$temp" 2>/dev/null || true
    fm_tasktmp_error "refused task temporary root $path for $id could not be recorded for re-reporting"
    return 1
  fi
}

fm_tasktmp_refusal_read() {  # <state> <task-id>
  local state=$1 id=$2 record line key value seen_version=0 seen_id=0 seen_path=0 seen_reason=0 seen_refused=0 recorded_id=
  record=$(fm_tasktmp_refusal_path "$state" "$id")
  if fm_tasktmp_path_absent "$record"; then
    FM_TASKTMP_ERROR="no refused task temporary root recorded for $id"
    return 2
  fi
  fm_tasktmp_lstat "$record" || return 1
  case "$FM_TASKTMP_STAT_TYPE" in
    regular\ file|Regular\ File|regular) ;;
    *) fm_tasktmp_error "refused-root record $record is not a regular file"; return 1 ;;
  esac
  fm_tasktmp_euid || return 1
  [ "$FM_TASKTMP_STAT_UID" = "$FM_TASKTMP_EUID" ] || {
    fm_tasktmp_error "refused-root record $record is not owned by the effective uid"
    return 1
  }
  fm_tasktmp_mode_private "$FM_TASKTMP_STAT_MODE" || {
    fm_tasktmp_error "refused-root record $record has unsafe mode $FM_TASKTMP_STAT_MODE"
    return 1
  }
  FM_TASKTMP_REFUSED_PATH=
  FM_TASKTMP_REFUSED_REASON=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) fm_tasktmp_error "refused-root record $record is malformed"; return 1 ;;
    esac
    case "$key" in
      version) [ "$seen_version" -eq 0 ] && [ "$value" = 1 ] || { fm_tasktmp_error "refused-root record $record has an invalid version"; return 1; }; seen_version=1 ;;
      id) [ "$seen_id" -eq 0 ] || { fm_tasktmp_error "refused-root record $record repeats id"; return 1; }; recorded_id=$value; seen_id=1 ;;
      path) [ "$seen_path" -eq 0 ] || { fm_tasktmp_error "refused-root record $record repeats path"; return 1; }; FM_TASKTMP_REFUSED_PATH=$value; seen_path=1 ;;
      reason) [ "$seen_reason" -eq 0 ] || { fm_tasktmp_error "refused-root record $record repeats reason"; return 1; }; FM_TASKTMP_REFUSED_REASON=$value; seen_reason=1 ;;
      refused) [ "$seen_refused" -eq 0 ] || { fm_tasktmp_error "refused-root record $record repeats refused"; return 1; }; seen_refused=1 ;;
      *) fm_tasktmp_error "refused-root record $record has unknown field '$key'"; return 1 ;;
    esac
  done < "$record"
  [ "$seen_version$seen_id$seen_path$seen_reason$seen_refused" = 11111 ] || {
    fm_tasktmp_error "refused-root record $record is incomplete"
    return 1
  }
  [ "$recorded_id" = "$id" ] || {
    fm_tasktmp_error "refused-root record $record belongs to '$recorded_id', not '$id'"
    return 1
  }
  [ -n "$FM_TASKTMP_REFUSED_PATH" ] || {
    fm_tasktmp_error "refused-root record $record names no path"
    return 1
  }
}

# Read-only liveness answer for the same per-task spawn lock the locked branch
# takes, without creating, stealing, or removing anything.
# Self-contained on purpose: a read-only startup must not have to load the wake
# queue's lock machinery to tell an ordinary in-flight spawn from a remnant.
fm_tasktmp_spawn_lock_live() {  # <state> <task-id>
  local lock=$1/.spawn-$2.lock pid
  [ -e "$lock" ] || [ -L "$lock" ] || return 1
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

fm_tasktmp_startup_sweep() {  # <state-dir> <locked|read-only>
  local state=$1 mode=$2 claim id lock meta record rc result=0
  [ -d "$state" ] || return 0
  for claim in "$state"/*.tasktmp-claim; do
    [ -e "$claim" ] || [ -L "$claim" ] || continue
    id=${claim##*/}
    id=${id%.tasktmp-claim}
    case "$id" in ''|*[!A-Za-z0-9._-]*)
      printf 'TASKTMP_RECONCILE: unknown: malformed pending claim name %s; nothing was touched\n' "$claim"
      result=1
      continue
      ;;
    esac
    if [ "$mode" = read-only ]; then
      if fm_tasktmp_claim_read "$state" "$id"; then
        if fm_tasktmp_spawn_lock_live "$state" "$id"; then
          # An ordinary in-flight spawn owns its own claim, so this is a fact
          # about live work rather than a remnant anyone must reconcile.
          printf 'BOOTSTRAP_INFO: %s: pending task temporary claim for %s is still owned by an active spawn; read-only startup left it untouched\n' "$id" "$FM_TASKTMP_CLAIM_PATH"
          continue
        fi
        printf 'TASKTMP_RECONCILE: %s: pending task temporary claim for %s requires locked reconciliation; read-only startup left it untouched\n' "$id" "$FM_TASKTMP_CLAIM_PATH"
      else
        printf 'TASKTMP_RECONCILE: %s: unsafe pending task temporary claim refused: %s; read-only startup left it untouched\n' "$id" "$FM_TASKTMP_ERROR"
      fi
      result=1
      continue
    fi
    lock=$state/.spawn-$id.lock
    if ! fm_lock_try_acquire "$lock"; then
      printf 'TASKTMP_RECONCILE: %s: pending task temporary claim is still owned by an active spawn; nothing was touched\n' "$id"
      result=1
      continue
    fi
    if ! fm_tasktmp_claim_reconcile_one "$state" "$id"; then
      printf 'TASKTMP_RECONCILE: %s: pending task temporary claim was preserved: %s\n' "$id" "$FM_TASKTMP_ERROR"
      result=1
    fi
    fm_lock_release "$lock" || {
      printf 'TASKTMP_RECONCILE: %s: task temporary reconciliation lock could not be released\n' "$id"
      result=1
    }
  done
  # A teardown that refused an unsafe root left this record behind precisely so
  # a later session can name the path again after the task record is gone.
  # It is re-reported for as long as the refused path still exists, and only a
  # locked startup retires it once that path is gone.
  for record in "$state"/*.tasktmp-refused; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    id=${record##*/}
    id=${id%.tasktmp-refused}
    case "$id" in ''|*[!A-Za-z0-9._-]*)
      printf 'TASKTMP_RECONCILE: unknown: malformed refused-root record name %s; nothing was touched\n' "$record"
      result=1
      continue
      ;;
    esac
    if ! fm_tasktmp_refusal_read "$state" "$id"; then
      printf 'TASKTMP_RECONCILE: %s: refused task temporary root recorded at %s could not be read: %s; nothing was touched\n' "$id" "$record" "$FM_TASKTMP_ERROR"
      result=1
      continue
    fi
    if fm_tasktmp_path_absent "$FM_TASKTMP_REFUSED_PATH"; then
      if [ "$mode" = read-only ]; then
        printf 'BOOTSTRAP_INFO: %s: previously refused task temporary root %s is gone; a locked startup will retire its record\n' "$id" "$FM_TASKTMP_REFUSED_PATH"
        continue
      fi
      if rm -f -- "$record"; then
        printf 'BOOTSTRAP_INFO: %s: previously refused task temporary root %s is gone; its refusal record was retired\n' "$id" "$FM_TASKTMP_REFUSED_PATH"
      else
        printf 'TASKTMP_RECONCILE: %s: refusal record %s could not be retired\n' "$id" "$record"
        result=1
      fi
      continue
    fi
    printf 'TASKTMP_RECONCILE: %s: refused task temporary root %s is still present and still untouched: %s\n' "$id" "$FM_TASKTMP_REFUSED_PATH" "$FM_TASKTMP_REFUSED_REASON"
    result=1
  done
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      continue
    fi
    fm_tasktmp_audit_meta "$meta" || result=1
  done
  return "$result"
}

# A remote-routed secondmate runs its whole claim, metadata, and refusal
# lifecycle in a nested state/<route>/ directory of the same home, with its
# spawn lock there too, so the home's startup owns those records exactly as it
# owns its own.
# One level is the whole production nesting; a symlinked child is never
# followed, because reconciliation deletes and must stay inside this home.
fm_tasktmp_startup() {  # <state> <locked|read-only>
  local state=$1 mode=$2 route result=0
  [ -d "$state" ] || return 0
  fm_tasktmp_startup_sweep "$state" "$mode" || result=1
  for route in "$state"/*/; do
    route=${route%/}
    [ -d "$route" ] || continue
    if [ -L "$route" ]; then
      continue
    fi
    fm_tasktmp_startup_sweep "$route" "$mode" || result=1
  done
  return "$result"
}
