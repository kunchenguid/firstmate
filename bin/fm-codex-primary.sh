#!/usr/bin/env bash
# fm-codex-primary.sh - authoritative Codex primary thread binding.
#
# A Codex SessionStart payload supplies the exact live session UUID when that
# lifecycle hook runs, and a Codex-launched shell exports the same identity as
# `CODEX_THREAD_ID`. The required `fm-session-start.sh` bootstrap calls `bind`
# after that same Codex process owns this home's fleet lock and the lock has a
# generation. A supplied lifecycle UUID must agree with the shell identity.
# This avoids guessing from transcript recency, titles, or another live session
# in the same cwd.
# `validate` rechecks the home, lock generation, lock-owner pid, and live process
# identity before printing `<thread-uuid><TAB><session-generation>`.
#
# Private files (all under state/, mode 0600 unless a directory):
#   .codex-primary-binding          validated active binding
#   .codex-primary.lock/            serialization lock shared with queue delivery
# Exact record fields are intentionally owned here rather than duplicated in
# prose. Records are strict line-oriented v1 data and atomically replaced.
#
# Usage:
#   fm-codex-primary.sh bind [source] [session-start-uuid]
#   fm-codex-primary.sh validate
#   fm-codex-primary.sh invalidate
set -u

FM_CODEX_PRIMARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_CODEX_PRIMARY_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_CODEX_PRIMARY_BINDING="$STATE/.codex-primary-binding"
FM_CODEX_PRIMARY_LOCK="$STATE/.codex-primary.lock"
FM_CODEX_LOCK_GENERATION="$STATE/.lock-generation"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_CODEX_PRIMARY_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_CODEX_PRIMARY_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$FM_CODEX_PRIMARY_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$FM_CODEX_PRIMARY_DIR/fm-gate-refuse-lib.sh"

fm_codex_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_codex_home_real() {
  (cd "$FM_HOME" 2>/dev/null && pwd -P)
}

fm_codex_owner_pid() {
  if [ "${FM_CODEX_TESTING:-0}" = 1 ] && [ -n "${FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE:-}" ]; then
    case "$FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE" in
      *[!0-9]*|'') return 1 ;;
    esac
    printf '%s\n' "$FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE"
    return 0
  fi
  fm_harness_ancestry_pid
}

fm_codex_uuid_valid() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

fm_codex_record_field() { # <path> <field>
  local path=$1 field=$2 count
  count=$(grep -c "^${field}=" "$path" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^${field}=//p" "$path"
}

fm_codex_record_shape_valid() { # <path> <header> <field-count>
  local path=$1 header=$2 fields=$3 first lines
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  first=$(sed -n '1p' "$path" 2>/dev/null) || return 1
  lines=$(wc -l < "$path" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$first" = "$header" ] && [ "$lines" = "$((fields + 1))" ]
}

fm_codex_atomic_write() { # <target>, content on stdin
  local target=$1 dir tmp
  dir=${target%/*}
  mkdir -p "$dir" || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  tmp=$(mktemp "$dir/.codex-primary.pending.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod 0600 "$tmp" || ! _fm_atomic_replace "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_codex_lock_generation_read() {
  local path=$FM_CODEX_LOCK_GENERATION header owner generation identity_hash extra
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  exec 8< "$path" || return 1
  IFS= read -r header <&8 || { exec 8<&-; return 1; }
  IFS= read -r owner <&8 || { exec 8<&-; return 1; }
  IFS= read -r generation <&8 || { exec 8<&-; return 1; }
  IFS= read -r identity_hash <&8 || { exec 8<&-; return 1; }
  if IFS= read -r extra <&8; then exec 8<&-; return 1; fi
  exec 8<&-
  [ "$header" = fm-session-lock-generation-v1 ] || return 1
  case "$owner" in *[!0-9]*|'') return 1 ;; esac
  case "$generation" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  case "$identity_hash" in *[!0-9a-fA-F]*|'') return 1 ;; esac
  [ "${#identity_hash}" -eq 64 ] || return 1
  FM_CODEX_LOCK_OWNER=$owner
  FM_CODEX_LOCK_GENERATION_VALUE=$generation
  FM_CODEX_LOCK_IDENTITY_SHA256=$identity_hash
}

fm_codex_bind_diagnostic_locked() {
  local code=$1 message=$2 now old_time old_code tmp DIAGNOSTIC
  DIAGNOSTIC="$STATE/.codex-queue-diagnostic"
  now=$(date +%s)
  old_time=$(sed -n '1s/^epoch=//p' "$DIAGNOSTIC" 2>/dev/null || true)
  old_code=$(sed -n '2s/^code=//p' "$DIAGNOSTIC" 2>/dev/null || true)
  case "$old_time" in ''|*[!0-9]*) old_time=0 ;; esac
  if [ "$code" != "$old_code" ] || [ $((now - old_time)) -ge 300 ]; then
    tmp=$(mktemp "$STATE/.codex-queue-diagnostic.XXXXXX") || return 0
    if printf 'epoch=%s\ncode=%s\n' "$now" "$code" > "$tmp" && chmod 0600 "$tmp" \
      && _fm_atomic_replace "$tmp" "$DIAGNOSTIC"; then
      :
    else
      rm -f -- "$tmp"
    fi
  fi
}

fm_codex_bind() { # [source] [session-start-uuid]
  local thread source lifecycle_thread owner lock_owner identity identity_hash home_real home_hash old_binding generation
  lifecycle_thread=${2:-}
  thread=${CODEX_THREAD_ID:-}
  if [ -n "$lifecycle_thread" ]; then
    fm_codex_uuid_valid "$lifecycle_thread" || return 1
    [ -z "$thread" ] || [ "$thread" = "$lifecycle_thread" ] || return 1
    thread=$lifecycle_thread
  fi
  fm_codex_uuid_valid "$thread" || return 1
  source=${1:-bootstrap}
  case "$source" in *[!A-Za-z0-9._-]*|'') source=unknown ;; esac
  if [ "${FM_CODEX_TESTING:-0}" != 1 ]; then
    fm_is_gate_agent "$FM_ROOT" && return 1
    fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 1
  fi
  owner=$(fm_codex_owner_pid) || return 1
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  lock_owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$lock_owner" = "$owner" ] || return 1
  fm_codex_lock_generation_read || return 1
  [ "$FM_CODEX_LOCK_OWNER" = "$owner" ] || return 1
  identity=$(fm_pid_identity "$owner") || return 1
  identity_hash=$(printf '%s' "$identity" | fm_codex_sha256_text) || return 1
  [ "$FM_CODEX_LOCK_IDENTITY_SHA256" = "$identity_hash" ] || return 1
  home_real=$(fm_codex_home_real) || return 1
  home_hash=$(printf '%s' "$home_real" | fm_codex_sha256_text) || return 1
  generation=$FM_CODEX_LOCK_GENERATION_VALUE
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$FM_CODEX_PRIMARY_LOCK" || return 1
  old_binding=
  if fm_codex_record_shape_valid "$FM_CODEX_PRIMARY_BINDING" fm-codex-primary-binding-v1 6; then
    old_binding="$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" thread_uuid 2>/dev/null || true)|$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" session_generation 2>/dev/null || true)|$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" owner_identity_sha256 2>/dev/null || true)"
  fi
  if ! {
    printf 'fm-codex-primary-binding-v1\n'
    printf 'thread_uuid=%s\n' "$thread"
    printf 'home_sha256=%s\n' "$home_hash"
    printf 'owner_pid=%s\n' "$owner"
    printf 'owner_identity_sha256=%s\n' "$identity_hash"
    printf 'session_generation=%s\n' "$generation"
    printf 'source=%s\n' "$source"
  } | fm_codex_atomic_write "$FM_CODEX_PRIMARY_BINDING"; then
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  fi
  [ "$old_binding" = "$thread|$generation|$identity_hash" ] \
    || {
         rm -f -- "$STATE/.codex-queue-outstanding" "$STATE/.codex-present-fallback-outstanding"
         if [ -e "$STATE/.codex-queue-outstanding" ] || [ -e "$STATE/.codex-present-fallback-outstanding" ]; then
           fm_codex_bind_diagnostic_locked bind-rm 'primary binding changed but stale native-queue doorbell records could not be removed from state/'
           rm -f -- "$FM_CODEX_PRIMARY_BINDING"
           fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
           return 1
         fi
       }
  fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
}

fm_codex_validate_locked() {
  local thread home_hash owner identity_hash generation source current_lock current_identity current_identity_hash current_home current_home_hash
  fm_codex_record_shape_valid "$FM_CODEX_PRIMARY_BINDING" fm-codex-primary-binding-v1 6 || return 1
  thread=$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" thread_uuid) || return 1
  home_hash=$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" home_sha256) || return 1
  owner=$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" owner_pid) || return 1
  identity_hash=$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" owner_identity_sha256) || return 1
  generation=$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" session_generation) || return 1
  source=$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" source) || return 1
  fm_codex_uuid_valid "$thread" || return 1
  case "$owner" in *[!0-9]*|'') return 1 ;; esac
  case "$generation" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  case "$source" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current_lock=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current_lock" = "$owner" ] || return 1
  fm_codex_lock_generation_read || return 1
  [ "$FM_CODEX_LOCK_OWNER" = "$owner" ] && [ "$FM_CODEX_LOCK_GENERATION_VALUE" = "$generation" ] || return 1
  current_identity=$(fm_pid_identity "$owner") || return 1
  current_identity_hash=$(printf '%s' "$current_identity" | fm_codex_sha256_text) || return 1
  [ "$current_identity_hash" = "$identity_hash" ] || return 1
  [ "$FM_CODEX_LOCK_IDENTITY_SHA256" = "$identity_hash" ] || return 1
  current_home=$(fm_codex_home_real) || return 1
  current_home_hash=$(printf '%s' "$current_home" | fm_codex_sha256_text) || return 1
  [ "$current_home_hash" = "$home_hash" ] || return 1
  FM_CODEX_VALID_THREAD=$thread
  FM_CODEX_VALID_GENERATION=$generation
  FM_CODEX_VALID_OWNER=$owner
}

fm_codex_validate() {
  fm_lock_acquire_wait "$FM_CODEX_PRIMARY_LOCK" || return 1
  if ! fm_codex_validate_locked; then
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  fi
  printf '%s\t%s\n' "$FM_CODEX_VALID_THREAD" "$FM_CODEX_VALID_GENERATION"
  fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
}

fm_codex_invalidate() {
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$FM_CODEX_PRIMARY_LOCK" || return 1
  rm -f -- "$FM_CODEX_PRIMARY_BINDING" "$STATE/.codex-queue-outstanding" \
    "$STATE/.codex-present-fallback-outstanding"
  fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    bind) [ "$#" -le 3 ] || exit 2; fm_codex_bind "${2:-bootstrap}" "${3:-}" ;;
    validate) fm_codex_validate ;;
    invalidate) fm_codex_invalidate ;;
    *) printf 'usage: fm-codex-primary.sh bind [source] [session-start-uuid]|validate|invalidate\n' >&2; exit 2 ;;
  esac
fi
