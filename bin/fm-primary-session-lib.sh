#!/usr/bin/env bash
# Shared primary-session owner descriptor and handoff-receipt helpers.
#
# This library does not acquire, replace, release, suspend, or restore anything.
# bin/fm-lock.sh calls fm_primary_owner_publish only after the numeric session
# lock has been claimed and verified through its canonical path.
# bin/fm-primary-session.sh owns the Paseo lifecycle transaction and uses the
# receipt helpers while holding state/.lock.acquire.
# This file is sourced by scripts and has no side effects on source.

FM_PRIMARY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_PRIMARY_LIB_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_PRIMARY_LIB_DIR/.." && pwd)}"
FM_PRIMARY_LIB_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_PRIMARY_LIB_ROOT}}"
FM_PRIMARY_LIB_DATA="${FM_DATA_OVERRIDE:-$FM_PRIMARY_LIB_HOME/data}"

fm_primary_atom_valid() {
  local value=$1
  [ -n "$value" ] && [ "${#value}" -le 255 ] \
    && LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:@+_-]*$' <<< "$value"
}

fm_primary_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_primary_home_fingerprint() {
  local resolved
  resolved=$(cd "$FM_PRIMARY_LIB_HOME" 2>/dev/null && pwd -P) || return 1
  printf '%s' "$resolved" | fm_primary_sha256_text
}

fm_primary_now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

fm_primary_receipt_last_value() {
  local receipt=$1 key=$2
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  sed -n "s/^${key}=//p" "$receipt" | tail -1
}

fm_primary_receipt_append_state() {
  local receipt=$1 state=$2 at_key=$3 at_value=$4
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  fm_primary_atom_valid "$state" || return 1
  fm_primary_atom_valid "$at_key" || return 1
  [ -n "$at_value" ] && LC_ALL=C grep -Eq '^[A-Za-z0-9:TZ.+-]+$' <<< "$at_value" || return 1
  {
    printf '%s=%s\n' "$at_key" "$at_value"
    printf 'state=%s\n' "$state"
  } >> "$receipt"
}

fm_primary_receipt_append_resolution() {
  local receipt=$1 now
  now=$(fm_primary_now_utc) || return 1
  fm_primary_receipt_append_state "$receipt" suspend-resolved suspend_resolved_at "$now"
}

fm_primary_paseo_home() {
  if [ -n "${PASEO_HOME:-}" ]; then
    printf '%s\n' "$PASEO_HOME"
  else
    printf '%s/.paseo\n' "${HOME:?HOME is required to resolve the local Paseo home}"
  fi
}

fm_primary_paseo_agent_file() {
  local agent_id=$1 paseo_home direct candidate match='' count=0
  fm_primary_atom_valid "$agent_id" || return 1
  paseo_home=$(fm_primary_paseo_home) || return 1
  direct="$paseo_home/agents/$agent_id.json"
  if [ -f "$direct" ] && [ ! -L "$direct" ]; then
    printf '%s\n' "$direct"
    return 0
  fi
  for candidate in "$paseo_home"/agents/*/"$agent_id.json"; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    match=$candidate
    count=$(( count + 1 ))
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$match"
}

fm_primary_provider_session_from_paseo_state() {
  local agent_id=$1 agent_file value
  command -v jq >/dev/null 2>&1 || return 1
  agent_file=$(fm_primary_paseo_agent_file "$agent_id") || return 1
  [ -f "$agent_file" ] && [ ! -L "$agent_file" ] || return 1
  value=$(jq -r '.persistence.sessionId // .runtimeInfo.sessionId // empty' "$agent_file" 2>/dev/null) || return 1
  [ -z "$value" ] || fm_primary_atom_valid "$value" || return 1
  printf '%s\n' "$value"
}

fm_primary_owner_descriptor_value() {
  local state=$1 key=$2 descriptor
  descriptor="$state/.lock.owner"
  [ -f "$descriptor" ] && [ ! -L "$descriptor" ] || return 1
  sed -n "s/^${key}=//p" "$descriptor" | tail -1
}

fm_primary_mark_reacquired_receipts() {
  local external_id=$1 owner_pid=$2 fingerprint receipt receipt_external receipt_home receipt_state now
  [ -d "$FM_PRIMARY_LIB_DATA/primary-session-handoffs" ] || return 0
  fingerprint=$(fm_primary_home_fingerprint) || return 1
  now=$(fm_primary_now_utc) || return 1
  for receipt in "$FM_PRIMARY_LIB_DATA"/primary-session-handoffs/*.receipt; do
    [ -e "$receipt" ] || continue
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
    [ "$(fm_primary_receipt_last_value "$receipt" schema 2>/dev/null || true)" = "fm-primary-session-handoff.v1" ] || continue
    receipt_external=$(fm_primary_receipt_last_value "$receipt" external_session_id 2>/dev/null || true)
    receipt_home=$(fm_primary_receipt_last_value "$receipt" home_fingerprint 2>/dev/null || true)
    receipt_state=$(fm_primary_receipt_last_value "$receipt" state 2>/dev/null || true)
    [ "$receipt_external" = "$external_id" ] || continue
    [ "$receipt_home" = "$fingerprint" ] || continue
    [ "$receipt_state" = "restore-requested" ] || continue
    {
      printf 'reacquired_at=%s\n' "$now"
      printf 'restored_owner_pid=%s\n' "$owner_pid"
      printf 'state=restored\n'
    } >> "$receipt" || return 1
  done
}

fm_primary_suspend_incomplete_clear() {
  local fingerprint receipt receipt_home receipt_state remaining token pid live_pids blocked=0 resolved=0
  local block_reason=
  local -a tokens
  [ -d "$FM_PRIMARY_LIB_DATA/primary-session-handoffs" ] || return 0
  fingerprint=$(fm_primary_home_fingerprint) || return 1
  for receipt in "$FM_PRIMARY_LIB_DATA"/primary-session-handoffs/*.receipt; do
    [ -e "$receipt" ] || continue
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
    [ "$(fm_primary_receipt_last_value "$receipt" schema 2>/dev/null || true)" = "fm-primary-session-handoff.v1" ] || continue
    receipt_home=$(fm_primary_receipt_last_value "$receipt" home_fingerprint 2>/dev/null || true)
    [ "$receipt_home" = "$fingerprint" ] || continue
    receipt_state=$(fm_primary_receipt_last_value "$receipt" state 2>/dev/null || true)
    [ "$receipt_state" = suspend-incomplete ] || continue
    remaining=$(fm_primary_receipt_last_value "$receipt" remaining_pids 2>/dev/null || true)
    if [ -z "$remaining" ]; then
      block_reason="unresolved suspend-incomplete primary-session receipt lacks a provable remaining process set: $receipt"
      blocked=1
      continue
    fi
    live_pids=
    IFS=, read -r -a tokens <<< "$remaining"
    for token in "${tokens[@]}"; do
      pid=${token%%:*}
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      if fm_process_pid_running "$pid"; then
        live_pids="${live_pids}${live_pids:+,}${pid}"
      fi
    done
    if [ -n "$live_pids" ]; then
      block_reason="unresolved suspend-incomplete primary-session receipt still has live captured pids ($live_pids): $receipt"
      blocked=1
      continue
    fi
    fm_primary_receipt_append_resolution "$receipt" || {
      block_reason="unresolved suspend-incomplete primary-session receipt could not be safely resolved: $receipt"
      blocked=1
      continue
    }
    resolved=1
  done
  if [ "$blocked" -ne 0 ]; then
    printf '%s\n' "$block_reason"
    return 1
  fi
  [ "$resolved" -eq 0 ] || return 0
  return 0
}

fm_primary_lock_rollback_if_exact_owner() {
  local state=$1 owner_pid=$2 lock current
  lock="$state/.lock"
  case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  current=$(cat "$lock" 2>/dev/null) || return 1
  [ "$current" = "$owner_pid" ] || return 1
  rm -f "$lock" || return 1
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 1
}

fm_primary_owner_publish() {
  local state=$1 owner_pid=$2 descriptor tmp harness manager external_id provider_session recorded_at
  local agent_file state_provider owner_identity owner_identity_hash
  descriptor="$state/.lock.owner"
  harness=$(fm_harness_pid_kind "$owner_pid") || return 1
  owner_identity=$(fm_pid_identity "$owner_pid") || return 1
  owner_identity_hash=$(printf '%s' "$owner_identity" | fm_primary_sha256_text) || return 1
  manager=unmanaged
  # fm-lock proves that its caller descends from owner_pid before publishing.
  # Prefer the inherited launch identity because macOS does not reliably expose
  # another process's environment through ps, then retain /proc as a fallback.
  external_id=${PASEO_AGENT_ID:-}
  [ -n "$external_id" ] \
    || external_id=$(fm_process_env_value "$owner_pid" PASEO_AGENT_ID 2>/dev/null || true)
  provider_session=
  if [ -n "$external_id" ]; then
    fm_primary_atom_valid "$external_id" || return 1
    manager=paseo
    agent_file=$(fm_primary_paseo_agent_file "$external_id" 2>/dev/null || true)
    if [ -n "$agent_file" ] && command -v jq >/dev/null 2>&1; then
      state_provider=$(jq -r '.provider // empty' "$agent_file" 2>/dev/null) || return 1
      [ "$state_provider" = "$harness" ] || return 1
    fi
    provider_session=$(fm_primary_provider_session_from_paseo_state "$external_id" 2>/dev/null || true)
  fi
  recorded_at=$(fm_primary_now_utc) || return 1
  umask 077
  tmp=$(mktemp "$state/.lock.owner.write.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'schema=fm-primary-lock-owner.v1\n'
    printf 'owner_pid=%s\n' "$owner_pid"
    printf 'owner_identity_sha256=%s\n' "$owner_identity_hash"
    printf 'harness=%s\n' "$harness"
    printf 'manager=%s\n' "$manager"
    printf 'external_session_id=%s\n' "$external_id"
    printf 'provider_session_id=%s\n' "$provider_session"
    printf 'recorded_at=%s\n' "$recorded_at"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$descriptor" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  [ -f "$descriptor" ] && [ ! -L "$descriptor" ] || return 1
  [ "$(fm_primary_owner_descriptor_value "$state" schema 2>/dev/null || true)" = "fm-primary-lock-owner.v1" ] || return 1
  [ "$(fm_primary_owner_descriptor_value "$state" owner_pid 2>/dev/null || true)" = "$owner_pid" ] || return 1
  [ "$(fm_primary_owner_descriptor_value "$state" owner_identity_sha256 2>/dev/null || true)" = "$owner_identity_hash" ] || return 1
  [ "$(fm_primary_owner_descriptor_value "$state" harness 2>/dev/null || true)" = "$harness" ] || return 1
  [ "$(fm_primary_owner_descriptor_value "$state" manager 2>/dev/null || true)" = "$manager" ] || return 1
  [ "$(fm_primary_owner_descriptor_value "$state" external_session_id 2>/dev/null || true)" = "$external_id" ] || return 1
  if [ "$manager" = paseo ]; then
    fm_primary_mark_reacquired_receipts "$external_id" "$owner_pid" || return 1
  fi
  return 0
}
